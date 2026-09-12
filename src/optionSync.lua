--- Modded Online — mod-SETTINGS sync.
---
--- Script mods read their own options while they build the world. The HD mod's
--- Lua generator picks room pools from `hd_debug_scripted_levelgen_disable`,
--- `hd_og_floorstyle_temple` and others, so two players with the same mods and
--- the same seed still generate DIFFERENT worlds when their settings differ —
--- which is what the reported HD mod desyncs were.
---
--- Rather than refuse the pairing (settings are buried in Playlunky's mod-options
--- UI and nobody knows which of forty toggles differs), everyone borrows the ROOM
--- HOST's settings for as long as they are in the room, exactly like the pet style.
--- Mod options live in each mod's OWN Lua VM though, so this side can only publish
--- the values and drop them in a file; the small option-sync block that
--- src/shimInjector.lua prepends to each pack applies them in that pack's VM.
---
--- NOTHING HERE CAN CHANGE A PLAYER'S SETTINGS OR PROGRESS ON DISK. Three
--- independent reasons, in order of how much they'd have to fail for it to matter:
---
---  1. Modded Online never writes any pack's `save.dat`. That file is the mod's
---     own, and it holds PROGRESS as well as options (the HD mod keeps `journal`,
---     `cameos_interactions_done` and `tutorial_records` in it). We only ever
---     read it.
---  2. The injected block puts the player's own values BACK before the mod's
---     ON.SAVE callback runs, and re-applies the host's afterwards, so the mod
---     serialises its own settings every time. The host's values exist only in
---     memory, and only while the room lasts.
---  3. Before the first value is overridden, the player's own settings are
---     written to `Mods/Packs/mo_options_backup.txt` (and, from inside the pack,
---     to a per-pack backup of the LIVE values). If the backup cannot be written,
---     the override is not applied at all — it fails closed.

local module = {}

-- Where the joiner leaves the host's values for the injected blocks to pick up.
-- A single fixed path, deliberately: the block runs inside another pack's VM and
-- has no way to know which folder Modded Online is installed in.
local OVERRIDE_PATH = "Mods/Packs/mo_options.txt"
local BACKUP_PATH = "Mods/Packs/mo_options_backup.txt"

-- Host republish cadence. The CHANGE check runs every tick (cheap: one save.dat
-- read per pack); the unconditional resend is the backstop that covers a peer
-- who joined between two changes.
local POLL_MS = 2000
local RESEND_MS = 5000
-- Split across several events: the flattened option set is ~1.7 KB, well past a
-- comfortable UDP datagram once it is JSON-encoded. The reliable channel is
-- ordered, so reassembly is just "collect n pieces".
local CHUNK_CHARS = 600
local MAX_CHUNKS = 24 -- a sanity cap; ~14 KB of settings is not a real mod

--- Option names that are NEVER synced: per-machine window geometry and
--- dev-panel state, which two players differ on the moment one drags a panel and
--- which cannot affect what the world generates. Everything else is synced —
--- erring towards syncing is the safe direction here, since an unsynced option
--- that feeds generation is precisely the bug being fixed.
local LOCAL_ONLY = {
    "^pos_", "^dialog_pos_", "^size$", "^hd_ui_", "^entity_spawner_",
    "^dev_tools$", "^show_feat$",
}

--- @param key string
--- @return boolean
local function isLocalOnly(key)
    for _, pattern in ipairs(LOCAL_ONLY) do
        if key:find(pattern) ~= nil then
            return true
        end
    end
    return false
end

-- host state
local lastPublished = nil  --- @type string?
local lastPublishMs = 0
local lastRoster = -1
local pollMs = 0

-- joiner state
local inbox = nil          --- @type table? { gen, n, parts }
local appliedText = nil    --- @type string? what is currently in OVERRIDE_PATH
local backupWritten = false
local noticeShown = false

--- Is an override file currently ours and in force? Read by the desync log.
--- @return boolean
function module.overrideActive()
    return appliedText ~= nil
end

-- ------------------------------------------------------------- serialisation
--
-- One `key<TAB>type<TAB>value` line per option, sorted by key, preceded by a
-- `gen<TAB>N` line. Deliberately NOT json: the injected block has to parse this
-- inside a content mod's VM, where it has no json decoder of ours to call, and a
-- three-field line split is four lines of Lua there.

--- @param s string
--- @return string
local function escapeValue(s)
    return (s:gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\n", "\\n"):gsub("\r", "\\r"))
end

--- @param v any
--- @return string? # type tag ("b", "n" or "s"), nil for a value we don't carry
--- @return string? # the encoded value
local function encodeValue(v)
    local t = type(v)
    if t == "boolean" then
        return "b", v and "1" or "0"
    elseif t == "number" then
        -- Integral values MUST print without a decimal point: an option the mod
        -- registered as an int (olmec_orb_chance_denominator, the yama timings)
        -- has to come back out of tonumber as an integer, not 2.0.
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return "n", string.format("%d", v)
        end
        return "n", string.format("%.17g", v)
    elseif t == "string" then
        return "s", escapeValue(v)
    end
    return nil, nil -- tables/functions: not a setting we can carry, skip it
end

--- Flatten an option table to the wire/file form (sorted, so identical settings
--- always produce an identical string and the change check is exact).
--- @param opts table<string, any>
--- @return string
function module.serialise(opts)
    local keys = {}
    for k in pairs(opts) do
        if type(k) == "string" and not isLocalOnly(k) then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local lines = {}
    for _, k in ipairs(keys) do
        local tag, value = encodeValue(opts[k])
        if tag ~= nil then
            lines[#lines + 1] = k .. "\t" .. tag .. "\t" .. value
        end
    end
    return table.concat(lines, "\n")
end

--- @param text string
--- @return integer # a stable generation number for this exact settings text
local function generation(text)
    local hash = 5381
    for i = 1, #text do
        hash = ((hash << 5) + hash + text:byte(i)) & 0x7FFFFFFF
    end
    return hash
end

-- --------------------------------------------------------------- host: publish

--- Host: keep the room's settings on the reliable channel. Runs in the LOBBY as
--- well, so joiners hold the values well before the first floor is generated —
--- a run can only start from the lobby, and the injected block re-reads the file
--- at every PRE_LEVEL_GENERATION, so by the time anything is built it is applied.
local function pollPublish()
    if not Network.isHost() then
        return
    end
    local now = get_ms()
    local text = module.serialise(Network.allPackOptions())
    if text == "" then
        return -- no pack in this room has settings; nothing to sync
    end
    local roster = #Network.lobbyPlayers
    -- Resend on ANY of: the settings changed (the host toggled something, or the
    -- mod finally wrote its save file), someone joined or left, or the backstop
    -- expired. The roster check is what covers a late joiner, who never saw the
    -- earlier sends -- the event channel is reliable, not replayed.
    if text == lastPublished and roster == lastRoster and now - lastPublishMs < RESEND_MS then
        return
    end
    if lastPublished ~= nil and text ~= lastPublished then
        dbg("mod settings changed — republishing to the room")
    end
    lastPublished = text
    lastRoster = roster
    lastPublishMs = now
    local gen = generation(text)
    local total = math.max(1, math.ceil(#text / CHUNK_CHARS))
    if total > MAX_CHUNKS then
        dbgf("mod settings too large to sync (%d bytes) — not publishing", #text)
        return
    end
    for i = 1, total do
        local part = text:sub((i - 1) * CHUNK_CHARS + 1, i * CHUNK_CHARS)
        Network.sendEvent("modopts", { g = gen, i = i, n = total, d = part })
    end
end

-- -------------------------------------------------------------- joiner: apply

--- The slot whose settings everyone adopts. `Network.hostSlot()` is the RUN host
--- and is 0 until a run starts, so fall back to the lobby host — the same
--- reasoning (and the same fallback) as the pet-style sync in eventSync.
--- @return integer
local function settingsHostSlot()
    local s = Network.hostSlot()
    if s ~= nil and s > 0 then
        return s
    end
    local lobby = Network.lobbyPlayers
    if lobby ~= nil and lobby[1] ~= nil and lobby[1].slot ~= nil then
        return math.floor(lobby[1].slot)
    end
    return 1
end

--- Write OUR OWN settings out before a single value is overridden, one section
--- per pack, as plain readable text. Nothing reads this back automatically —
--- the injected block restores from memory, and a mod's save file never holds
--- the host's values in the first place — so this exists purely so a player can
--- always see, and if they ever needed to, retype exactly what they had.
--- @return boolean # false if it could not be written, in which case NOTHING is overridden
local function writeBackup()
    local ok = pcall(function()
        local f = assert(io.open(BACKUP_PATH, "w"))
        f:write("# Modded Online — YOUR mod settings, saved before the room host's were applied.\n")
        f:write("# Modded Online never writes any mod's save.dat, and the values below are put\n")
        f:write("# back before each mod saves, so this is a record and not a repair: your own\n")
        f:write("# settings and progress on disk were never changed. Safe to delete.\n")
        for _, packName in ipairs(Network.syncedScriptPacks()) do
            local opts = Network.packOptions(packName)
            if opts ~= nil then
                f:write("\n[" .. packName .. "]\n")
                local keys = {}
                for k in pairs(opts) do
                    keys[#keys + 1] = tostring(k)
                end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    f:write(k .. " = " .. tostring(opts[k]) .. "\n")
                end
            end
        end
        f:close()
    end)
    if not ok then
        dbg("could not write the settings backup — NOT applying the host's settings")
    end
    return ok
end

--- @param text string the host's settings
--- @param gen integer
local function writeOverride(text, gen)
    if appliedText == text then
        return -- already in force; don't churn the file (the blocks poll it)
    end
    if not backupWritten then
        if not writeBackup() then
            return -- fail CLOSED: no backup on disk, no override
        end
        backupWritten = true
    end
    local ok = pcall(function()
        local f = assert(io.open(OVERRIDE_PATH, "w"))
        f:write("# Modded Online — the room host's mod settings, in force while you are in\n")
        f:write("# their room. Your own settings are in mo_options_backup.txt and are put back\n")
        f:write("# before any mod saves, so nothing on disk is changed. Deleted when you leave.\n")
        f:write("gen\t" .. tostring(gen) .. "\n")
        f:write(text)
        f:write("\n")
        f:close()
    end)
    if not ok then
        dbg("could not write the host's mod settings — settings are NOT synced")
        return
    end
    appliedText = text
    if DesyncLog ~= nil then
        DesyncLog.event("mod settings synced from host (gen %d, %d bytes)", gen, #text)
    end
    if not noticeShown then
        noticeShown = true
        toast("Using the host's mod settings — yours are restored when you leave")
    end
end

--- @param payload { g: integer, i: integer, n: integer, d: string }
--- @param originSlot integer
local function onModOpts(payload, originSlot)
    if Network.isHost() or originSlot ~= settingsHostSlot() then
        return -- only the room host is authoritative; never apply our own echo
    end
    local gen = math.floor(tonumber(payload.g) or -1)
    local idx = math.floor(tonumber(payload.i) or 0)
    local total = math.floor(tonumber(payload.n) or 0)
    local part = payload.d
    if gen < 0 or idx < 1 or total < 1 or total > MAX_CHUNKS or idx > total or type(part) ~= "string" then
        return
    end
    if inbox == nil or inbox.gen ~= gen or inbox.n ~= total then
        inbox = { gen = gen, n = total, parts = {}, have = 0 }
    end
    if inbox.parts[idx] == nil then
        inbox.parts[idx] = part
        inbox.have = inbox.have + 1
    end
    if inbox.have < total then
        return
    end
    local text = table.concat(inbox.parts, "", 1, total)
    inbox = nil
    -- The generation is a hash of the text, so a truncated or scrambled
    -- reassembly can never be mistaken for the host's settings.
    if generation(text) ~= gen then
        dbg("host's mod settings failed their checksum — ignoring")
        return
    end
    writeOverride(text, gen)
end

-- ------------------------------------------------------------------ lifecycle

--- Take the override file away. Checked rather than assumed: `os.remove` reports
--- failure by RETURN VALUE, not by raising, so a file we could not delete would
--- otherwise be left standing and go on being applied. An EMPTY file means "no
--- override" to the injected blocks exactly as a missing one does, so that is the
--- fallback — and it is only reached when the file is genuinely still there.
local function removeOverride()
    pcall(function() os.remove(OVERRIDE_PATH) end)
    local left = nil
    pcall(function() left = io.open(OVERRIDE_PATH, "r") end)
    if left == nil then
        return
    end
    left:close()
    pcall(function()
        local f = assert(io.open(OVERRIDE_PATH, "w"))
        f:close()
    end)
end

--- Drop the override: delete the file, and the injected blocks put the player's
--- own values back the next time they poll it (within a second) — or at the next
--- level generation, whichever comes first.
---
--- Called when the room is left by ANY route (leave, kick, timeout, error, the
--- server going away), because it is driven off `Network.isActive()` rather than
--- off any one of them. Also called once at load, which is what cleans up after
--- a crash: a leftover file from a previous session is gone before the injected
--- blocks have run a single frame.
function module.release()
    inbox = nil
    lastPublished = nil
    lastRoster = -1
    if appliedText == nil and not backupWritten then
        -- still remove any stale file: this is also the at-load cleanup path
        removeOverride()
        return
    end
    appliedText = nil
    backupWritten = false
    noticeShown = false
    removeOverride()
    if DesyncLog ~= nil then
        DesyncLog.event("mod settings override released — your own settings are back")
    end
end

--- Per-frame driver. Host side publishes; every side releases the moment the
--- room is gone.
function module.poll()
    if not Network.isActive() then
        if appliedText ~= nil or backupWritten or lastPublished ~= nil then
            module.release()
        end
        return
    end
    local now = get_ms()
    if now - pollMs < POLL_MS then
        return
    end
    pollMs = now
    pollPublish()
end

Network.onEvent("modopts", onModOpts)

-- A leftover override from a session that ended in a crash must never survive
-- into a solo game. Our pack loads before the content packs poll for the file,
-- so this always wins the race.
module.release()

set_callback(function()
    SafeCall("optionSync:poll", module.poll)
end, ON.GUIFRAME)

OptionSync = module
return module
