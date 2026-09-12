--- Modded Online — sharing the hosted mod's save data across a room.
---
--- A hosted mod keeps its own progression. The HD mod has both halves: `save.dat`
--- (its Lua state, written through Playlunky's ON.SAVE) and `savegame.sav` (the
--- engine save it reads unlocks out of). Two players never have the same one, and a
--- mod that branches on its own progress therefore builds a different world from the
--- same seed -- which is the whole family of desyncs this build keeps meeting.
---
--- The rule, and it is deliberately simple: WHILE YOU ARE IN A ROOM, EVERYONE PLAYS
--- ON THE ROOM HOST'S SAVE. The host publishes both files, every peer borrows them,
--- and a peer's own copies come back the moment it leaves. The host's own progress
--- is never touched, so it accumulates normally.
---
--- WHAT IS AND IS NOT TOUCHED ON DISK
---
--- Only files inside MODDED ONLINE's own pack are written by the sync. The mod's own
--- folder is never written except by `module.syncToMod`, which is the SYNC SAVE DATA
--- button and only runs when a player presses it. That boundary is deliberate: a
--- loader that quietly edits other packs is exactly the bug that stopped those packs
--- booting on their own.
---
--- Before a peer's files are replaced they are copied aside, and the replacement is
--- ABANDONED if that copy cannot be written -- it fails closed, because the failure
--- it guards against is somebody else's progression sitting permanently in this
--- player's save.
---
--- GETTING IT BACK SURVIVES ANYTHING, including simply closing the game. The parked
--- copies are put back at load as well as on leaving, they are verified by reading
--- them back, and they are NOT retired until the mod's own loader has been re-run
--- from the restored file (see finishStartupRestore). That last part matters more
--- than it looks: Playlunky hands the mod its save.dat before any of our Lua runs,
--- so restoring only the FILE leaves the mod still holding the host's state -- and
--- its next ON.SAVE writes that straight back over the file we just fixed.
---
--- IT TAKES EFFECT IMMEDIATELY, WITHOUT A RESTART
---
--- The files alone would not do that. The engine parses `savegame.sav` at launch and
--- then works from memory, and Playlunky hands `save.dat` to ON.LOAD once, at script
--- load -- so a file arriving mid-session used to mean nothing until the next
--- launch. Asking somebody who just matchmaked into a lobby to restart is not a
--- solution, so the swap has three parts and the files are only one:
---
---  1. THE FILES, so the borrow persists and can be handed back exactly.
---  2. THE LIVE `savegame` FIELDS (SAVEGAME_FIELDS below), written straight into the
---     engine's in-memory save where a running mod actually reads them.
---  3. THE MOD'S OWN LOADER, re-run. Because the mod runs in OUR Lua state its
---     ON.LOAD handler is an ordinary function we hold a reference to, so it can be
---     called again with the new save.dat -- see ModHost.reloadSaveData. For the HD
---     mod that re-runs its migration, load and post-load callbacks, which is a full
---     reload of its save state in place.
---
--- Leaving undoes all three, in the same order.
---
--- What is NOT live: the journal arrays (`places`, `people`, `items`, `bestiary`).
--- They are per-entry bitfields that change what the journal DISPLAYS and nothing
--- that generates, so they ride the file and land at the next launch.

local module = {}

--- The two files, in our own pack.
local FILES = { "save.dat", "savegame.sav" }

--- The `savegame` fields shared live.
---
--- Writing savegame.sav does not help the session in progress: the engine parsed it
--- at launch and works from memory. These are the same values, in memory, where a
--- mod actually reads them -- the HD mod takes `shortcuts` (Mama Tunnel), `characters`
--- and `players` (its unlock rolls), `tutorial_state` and `deepest_area`.
---
--- Scalars only. The journal arrays (`places`, `people`, `items`, `bestiary`) are
--- per-entry bitfields that affect what the journal DISPLAYS and nothing that
--- generates, so they are left to the file and the next launch.
local SAVEGAME_FIELDS = {
    "shortcuts", "characters", "players", "tutorial_state", "deepest_area",
    "seeded_unlocked", "wins_normal", "wins_hard", "wins_special",
    "completed_normal", "completed_ironman", "completed_hard",
}

local ownFields = nil      -- our own values, captured before the first override
local pendingReload = false -- a load-time restore still waiting for the mod

--- Our own `savegame` values, parked on DISK as well as in memory.
---
--- The engine writes savegame.sav from its own memory whenever it saves, including
--- on the way out. So a player who simply closes the game while borrowing leaves the
--- host's field values written into their savegame.sav -- and the next launch loads
--- them back into engine memory before we can restore the file, which would make the
--- borrow permanent. Restoring the file is not enough; the VALUES have to be put back
--- in memory too, and after a restart the only place they can have come from is here.
local FIELDS_FILE = "mo_own_fields.txt"

--- Base64 characters per event. The wire is UDP through the relay, so a chunk plus
--- its JSON envelope has to stay comfortably inside one datagram.
local CHUNK = 800

--- Chunks pushed per frame. The HD mod's two files come to about 17 KB, roughly 24
--- chunks; posting them all in one frame would hand the reliable channel a burst
--- that it then has to resend as a burst.
local PER_FRAME = 4

local outbox = {}          -- chunks still to send (host)
local generation = 0       -- bumped per publish, so a stale chunk cannot be mixed in
local incoming = nil       -- { g, count, parts = { name -> { n, got, [i] = text } } }
local borrowed = false     -- are the host's files currently in place of ours?
local asked = false        -- have we asked this room for its save yet?
local lastResult = nil     -- what the SYNC SAVE DATA button did last

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64DEC = {}
for i = 1, 64 do
    B64DEC[B64:sub(i, i)] = i - 1
end

--- @param data string
--- @return string
local function b64encode(data)
    local out, i, n = {}, 1, #data
    while i <= n do
        local a = data:byte(i)
        local b = data:byte(i + 1)
        local c = data:byte(i + 2)
        local v = a << 16 | (b or 0) << 8 | (c or 0)
        out[#out + 1] = B64:sub((v >> 18 & 63) + 1, (v >> 18 & 63) + 1)
            .. B64:sub((v >> 12 & 63) + 1, (v >> 12 & 63) + 1)
            .. (b ~= nil and B64:sub((v >> 6 & 63) + 1, (v >> 6 & 63) + 1) or "=")
            .. (c ~= nil and B64:sub((v & 63) + 1, (v & 63) + 1) or "=")
        i = i + 3
    end
    return table.concat(out)
end

--- @param text string
--- @return string
local function b64decode(text)
    local out, acc, bits = {}, 0, 0
    for ch in text:gmatch("[^=%s]") do
        local v = B64DEC[ch]
        if v ~= nil then
            acc = (acc << 6 | v) & 0xFFFFFF
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                out[#out + 1] = string.char(acc >> bits & 255)
            end
        end
    end
    return table.concat(out)
end

--- @param path string
--- @return string? # nil when the file is absent or unreadable
local function readBinary(path)
    local data = nil
    pcall(function()
        local f = io.open(path, "rb")
        if f == nil then
            return
        end
        data = f:read("*a")
        f:close()
    end)
    return data
end

--- @param path string
--- @param data string
--- @return boolean
local function writeBinary(path, data)
    local ok = false
    pcall(function()
        local f = io.open(path, "wb")
        if f == nil then
            return
        end
        f:write(data)
        f:close()
        ok = true
    end)
    return ok
end

--- @param path string
--- @return boolean
local function fileExists(path)
    local f = io.open(path, "rb")
    if f == nil then
        return false
    end
    f:close()
    return true
end

--- @return table # field -> number (booleans as 0/1)
local function readFields()
    local out = {}
    for _, name in ipairs(SAVEGAME_FIELDS) do
        local v = nil
        pcall(function() v = savegame[name] end)
        if type(v) == "number" then
            out[name] = math.floor(v)
        elseif type(v) == "boolean" then
            out[name] = v and 1 or 0
        end
    end
    return out
end

--- @param values table
--- @return integer # how many were written
local function writeFields(values)
    local written = 0
    for _, name in ipairs(SAVEGAME_FIELDS) do
        local v = values[name]
        if v ~= nil then
            pcall(function()
                -- match the field's own type: some of these are booleans engine-side
                -- and assigning a number to one is a native type error
                if type(savegame[name]) == "boolean" then
                    savegame[name] = v ~= 0
                else
                    savegame[name] = v
                end
                written = written + 1
            end)
        end
    end
    return written
end

--- Where a peer's own copy waits while it is borrowing the host's.
--- @param name string
--- @return string
local function backupPath(name)
    return PackPath(name .. ".mo_mine")
end

--- Marks a file that DID NOT EXIST before the borrow.
---
--- Putting such a file back means DELETING it, and nothing else records that: a
--- parked copy cannot exist for a file that was never there. Without this the
--- host's save simply stayed, which is what a peer who had not played the mod
--- before ended up with permanently -- and the packaged zip deliberately ships
--- neither save file, so a freshly installed loader is exactly that case.
--- @param name string
--- @return string
local function absentPath(name)
    return PackPath(name .. ".mo_absent")
end

--- The slot everyone borrows from. Mirrors the pet style's choice of host: the RUN
--- host is only known once a run starts, and this has to work in the LOBBY, which is
--- the whole point -- a peer must be holding the host's save before the run begins.
--- @return integer
local function hostSlot()
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

--- @return boolean # are we currently playing on somebody else's save?
function module.borrowing()
    return borrowed
end

--- What the SYNC SAVE DATA button did last, for its label.
--- @return string?
function module.lastResult()
    return lastResult
end

-- ------------------------------------------------------------------ host side

--- Queue both of our files for the room. Cheap to call again: a new generation
--- supersedes whatever was still in flight.
function module.publish()
    if not Network.isActive() or not Network.isHost() then
        return
    end
    local snapshot = {}
    local count = 0
    for _, name in ipairs(FILES) do
        local data = readBinary(PackPath(name))
        if data ~= nil and #data > 0 then
            snapshot[name] = b64encode(data)
            count = count + 1
        end
    end
    if count == 0 then
        return
    end
    generation = generation + 1
    outbox = {}
    for name, text in pairs(snapshot) do
        local total = math.max(1, math.ceil(#text / CHUNK))
        for i = 1, total do
            outbox[#outbox + 1] = {
                g = generation, f = name, c = count, i = i, n = total,
                d = text:sub((i - 1) * CHUNK + 1, i * CHUNK),
            }
        end
    end
    -- The live half, and small enough to go in one event: the same values the
    -- files carry, but where a mod reads them THIS session.
    Network.sendEvent("savefields", readFields())
    if DesyncLog ~= nil then
        DesyncLog.event("save share: publishing %d file(s) as %d chunk(s), generation %d",
            count, #outbox, generation)
    end
end

--- A peer that has just arrived asks for the room's save.
--- @param _payload table
--- @param _originSlot integer
function module.onSaveAsk(_payload, _originSlot)
    if Network.isHost() then
        module.publish()
    end
end

-- ------------------------------------------------------------------ peer side

--- Put our own copies aside and write the host's in their place. Fails closed: if a
--- copy cannot be set aside, NOTHING is overwritten.
--- @param files table # name -> raw file contents
--- @return boolean
local function adopt(files)
    for _, name in ipairs(FILES) do
        local mine = PackPath(name)
        local kept = backupPath(name)
        if fileExists(mine) then
            if not fileExists(kept) then
                local data = readBinary(mine)
                if data == nil or not writeBinary(kept, data) then
                    if DesyncLog ~= nil then
                        DesyncLog.event("save share: REFUSED -- could not set %s"
                            .. " aside, so it was left alone", name)
                    end
                    return false
                end
            end
        elseif not fileExists(absentPath(name)) then
            -- nothing to park, so remember that there was nothing
            writeBinary(absentPath(name), "")
        end
    end
    local written = 0
    for name, data in pairs(files) do
        if writeBinary(PackPath(name), data) then
            written = written + 1
        end
    end
    borrowed = true
    -- ...and hand the mod its new save data WITHOUT a restart. Playlunky reads
    -- save.dat once at script load; because the mod runs in our state, its ON.LOAD
    -- handler is a function we can simply call again. See ModHost.reloadSaveData.
    local ran = 0
    if ModHost ~= nil and ModHost.reloadSaveData ~= nil then
        ran = ModHost.reloadSaveData(files["save.dat"] or "")
    end
    if DesyncLog ~= nil then
        DesyncLog.event("save share: now on the room host's save (%d file(s) adopted,"
            .. " %d mod loader(s) re-run; yours comes back when you leave)",
            written, ran)
    end
    return true
end

--- The host's progression, applied where the running game reads it. This is what
--- makes a mid-session join work: no restart, and it lands before the run starts.
--- @param payload table
--- @param originSlot integer
function module.onSaveFields(payload, originSlot)
    if Network.isHost() or math.floor(originSlot or 0) ~= hostSlot() then
        return
    end
    local values = {}
    for _, name in ipairs(SAVEGAME_FIELDS) do
        local v = tonumber(payload[name])
        if v ~= nil then
            values[name] = math.floor(v)
        end
    end
    if next(values) == nil then
        return
    end
    -- ONCE, and before the first override: after it, "ours" would be the host's
    if ownFields == nil then
        ownFields = readFields()
        local lines = {}
        for name, v in pairs(ownFields) do
            lines[#lines + 1] = name .. "=" .. tostring(v)
        end
        table.sort(lines) -- stable, so the file diffs cleanly if anyone looks
        -- string.char(10) rather than an escape: this file has been through
        -- enough generators that a literal backslash-n is not worth the risk.
        writeBinary(PackPath(FIELDS_FILE), table.concat(lines, string.char(10)))
    end
    local written = writeFields(values)
    borrowed = true
    if DesyncLog ~= nil then
        DesyncLog.event("save share: adopted %d of the host's savegame field(s) live",
            written)
    end
end

--- @param payload table
--- @param originSlot integer
function module.onSaveData(payload, originSlot)
    if Network.isHost() or math.floor(originSlot or 0) ~= hostSlot() then
        return -- only the room host is authoritative, and our own never echoes back
    end
    local gen = math.floor(tonumber(payload.g) or -1)
    local name = tostring(payload.f or "")
    local index = math.floor(tonumber(payload.i) or 0)
    local total = math.floor(tonumber(payload.n) or 0)
    local count = math.floor(tonumber(payload.c) or 0)
    if gen < 0 or index < 1 or total < 1 or count < 1 or payload.d == nil then
        return
    end
    if incoming == nil or incoming.g ~= gen then
        incoming = { g = gen, count = count, parts = {} }
    end
    local part = incoming.parts[name]
    if part == nil then
        part = { n = total, got = 0 }
        incoming.parts[name] = part
    end
    if part[index] == nil then
        part[index] = tostring(payload.d)
        part.got = part.got + 1
    end

    local ready, files = 0, {}
    for fileName, entry in pairs(incoming.parts) do
        if entry.got == entry.n then
            local pieces = {}
            for i = 1, entry.n do
                pieces[i] = entry[i]
            end
            files[fileName] = b64decode(table.concat(pieces))
            ready = ready + 1
        end
    end
    if ready < incoming.count then
        return -- still arriving
    end
    incoming = nil
    adopt(files)
end

--- Put the parked copies back, and CHECK they went back.
--- @return integer, integer # restored, failed
local function restoreFiles()
    local restored, failed = 0, 0
    for _, name in ipairs(FILES) do
        if fileExists(absentPath(name)) then
            -- there was no file here before the borrow: putting it back is a
            -- deletion, not a copy
            pcall(os.remove, PackPath(name))
            if fileExists(PackPath(name)) then
                failed = failed + 1
            else
                restored = restored + 1
            end
        end
        local data = readBinary(backupPath(name))
        if data ~= nil then
            if writeBinary(PackPath(name), data)
                and readBinary(PackPath(name)) == data then
                restored = restored + 1
            else
                -- the file is open, or the write was short. Leave the parked copy
                -- alone and try again next launch rather than lose it.
                failed = failed + 1
            end
        end
    end
    return restored, failed
end

local function clearParked()
    for _, name in ipairs(FILES) do
        pcall(os.remove, backupPath(name))
        pcall(os.remove, absentPath(name))
    end
    pcall(os.remove, PackPath(FIELDS_FILE))
end

--- Finish a restore that began at LOAD, once the mod is hosted.
---
--- This is the half that makes "they just closed the game" work. Playlunky reads a
--- pack's save.dat and hands it to ON.LOAD BEFORE our Lua runs, so a restore done at
--- module load fixes the file while the mod in memory still holds the host's state --
--- and the mod's next ON.SAVE writes that straight back over the file we just fixed.
--- Re-running its loader from the restored file is what makes the restore stick.
---
--- The parked copies are deliberately NOT retired until this has run, so a crash in
--- between just means the next launch does it again. It is idempotent by design.
--- @return boolean # whether there was anything to finish
function module.finishStartupRestore()
    if not pendingReload then
        return false
    end
    pendingReload = false
    module.seedHosted()
    local ran = 0
    if ModHost ~= nil and ModHost.reloadSaveData ~= nil then
        ran = ModHost.reloadSaveData(readBinary(PackPath("save.dat")) or "")
    end
    clearParked()
    if DesyncLog ~= nil then
        DesyncLog.event("save share: finished restoring your own save from the last"
            .. " session (%d mod loader(s) re-run)", ran)
    end
    return true
end

--- Our own save back, exactly as it was: the files, the live `savegame` fields, and
--- the mod's own save state. Called when the room is left, and again at load, so a
--- session that ended in a crash -- or by simply closing the game -- cannot leave
--- the host's progression behind.
function module.restoreOwn()
    local restored, failed = restoreFiles()
    -- After a restart `ownFields` is empty and the parked copy on disk is the
    -- only record of what this player's values were.
    if ownFields == nil then
        local text = readBinary(PackPath(FIELDS_FILE))
        if text ~= nil then
            local parsed = {}
            for name, value in text:gmatch("([%a_]+)=(-?%d+)") do
                parsed[name] = math.floor(tonumber(value) or 0)
            end
            if next(parsed) ~= nil then
                ownFields = parsed
                restored = restored + 1
            end
        end
    end
    incoming = nil
    asked = false
    outbox = {}

    local fieldsBack = 0
    if ownFields ~= nil then
        fieldsBack = writeFields(ownFields)
        ownFields = nil
    end

    -- Is the mod hosted yet? At LOAD it is not -- saveShare is required before
    -- modHost -- so the loader has to be re-run later, from main.lua.
    -- Whether modHost has LOADED, not whether the mod registered a loader: a mod
    -- with no ON.LOAD would otherwise defer forever and never retire the parked
    -- copies. src.saveShare is required before src.modHost, so this is nil at
    -- load and set every time afterwards, which is exactly the distinction.
    local hosted = ModHost ~= nil and ModHost.reloadSaveData ~= nil
    local ran = 0
    if failed > 0 then
        pendingReload = restored > 0
        if DesyncLog ~= nil then
            DesyncLog.event("save share: %d file(s) could NOT be put back and are still"
                .. " parked -- they will be restored on the next launch", failed)
        end
    elseif hosted then
        -- A file we just DELETED (it did not exist before the borrow) leaves the
        -- pack without something the mod needs. Put the mod's own copy back
        -- first, so the reload below reads that rather than nothing.
        module.seedHosted()
        if borrowed or restored > 0 then
            ran = ModHost.reloadSaveData(readBinary(PackPath("save.dat")) or "")
        end
        clearParked()
    elseif restored > 0 then
        pendingReload = true -- finishStartupRestore picks this up after hosting
    else
        clearParked()
    end

    if borrowed or restored > 0 then
        borrowed = false
        if DesyncLog ~= nil then
            DesyncLog.event("save share: your own save is back (%d file(s), %d field(s),"
                .. " %d mod loader(s) re-run)", restored, fieldsBack, ran)
        end
    end
end

-- ---------------------------------------------------------------- per frame

--- Pushes queued chunks, and asks once per room for the host's save. Both are
--- deliberately here rather than on an event: joining is not a single moment we are
--- told about, and asking twice is harmless while never asking is not.
function module.poll()
    if not Network.isActive() then
        if borrowed or asked then
            module.restoreOwn()
        end
        return
    end
    if Network.isHost() then
        for _ = 1, PER_FRAME do
            local chunk = table.remove(outbox, 1)
            if chunk == nil then
                break
            end
            Network.sendEvent("savedata", chunk)
        end
        return
    end
    if not asked then
        asked = true
        Network.sendEvent("saveask", {})
    end
end

-- ----------------------------------------------------------------- the button

--- Copy Modded Online's save data into the mod it belongs to. This is the ONE place
--- that writes another pack's folder, and it only runs when a player presses the
--- button -- see the note at the top of this file.
--- @return string # what happened, for the menu label and the log
function module.syncToMod()
    if borrowed then
        -- what is on disk right now is the ROOM HOST's progression, not this
        -- player's; writing it into their mod is the one thing this must never do
        lastResult = "not while borrowing the host's save"
        return lastResult
    end
    local packs = {}
    if ModHost ~= nil and ModHost.requestedPacks ~= nil then
        packs = ModHost.requestedPacks() or {}
    end
    if #packs == 0 then
        lastResult = "no mod is enabled"
        return lastResult
    end
    local copied = 0
    for _, packName in ipairs(packs) do
        for _, name in ipairs(FILES) do
            local data = readBinary(PackPath(name))
            if data ~= nil and #data > 0 then
                local dest = "Mods/Packs/" .. packName .. "/" .. name
                -- the mod's own copy is kept ONCE, so this is undoable by hand
                if fileExists(dest) and not fileExists(dest .. ".before_mo") then
                    local existing = readBinary(dest)
                    if existing ~= nil then
                        writeBinary(dest .. ".before_mo", existing)
                    end
                end
                if writeBinary(dest, data) then
                    copied = copied + 1
                end
            end
        end
    end
    lastResult = copied > 0 and (copied .. " file(s) synced") or "nothing to sync"
    if DesyncLog ~= nil then
        DesyncLog.event("save share: SYNC SAVE DATA -> %s", lastResult)
    end
    return lastResult
end

--- Seed our copy from the mod's, for a mod being armed. Never overwrites: once
--- Modded Online has its own copy, that copy IS the progression, and re-arming the
--- same mod must not throw it away.
--- @param packName string
--- @return integer # files seeded
function module.seedFrom(packName)
    local seeded = 0
    for _, name in ipairs(FILES) do
        if not fileExists(PackPath(name)) then
            local data = readBinary("Mods/Packs/" .. packName .. "/" .. name)
            if data ~= nil and #data > 0 and writeBinary(PackPath(name), data) then
                seeded = seeded + 1
            end
        end
    end
    return seeded
end

--- One line for the desync log header, because this failing is otherwise SILENT.
---
--- When nothing was parked there was nothing to restore, so the restore path logged
--- nothing at all and a peer left holding the host's save with no trace of why. This
--- says what the pack actually holds, every session, before anyone has to ask.
--- @return string
function module.status()
    local have, parked, absent = 0, 0, 0
    for _, name in ipairs(FILES) do
        if fileExists(PackPath(name)) then
            have = have + 1
        end
        if fileExists(backupPath(name)) then
            parked = parked + 1
        end
        if fileExists(absentPath(name)) then
            absent = absent + 1
        end
    end
    return string.format("%s | %d/%d file(s) present, %d parked, %d marked absent",
        borrowed and "BORROWING the room host's save" or "on your own save",
        have, #FILES, parked, absent)
end

--- Seed whatever is missing from every mod currently hosted.
---
--- packSetup only seeds when it APPLIES, i.e. when the armed selection changes. A
--- player who armed a mod under an older build therefore never got seeded, and the
--- capture showed exactly that: `0 parked, 2 marked absent` -- a pack holding neither
--- file, on a peer about to borrow. hdmod NEEDS its savegame.sav (without it the game
--- hands it the player's real save and the HD campaign opens fully unlocked), so
--- leaving the pack empty is not a state worth returning to.
---
--- Copy-if-missing, so it is safe to call at boot and after every restore.
--- @return integer # files seeded
function module.seedHosted()
    local packs = {}
    if ModHost ~= nil and ModHost.requestedPacks ~= nil then
        packs = ModHost.requestedPacks() or {}
    end
    local seeded = 0
    for _, packName in ipairs(packs) do
        seeded = seeded + module.seedFrom(packName)
    end
    if seeded > 0 and DesyncLog ~= nil then
        DesyncLog.event("save share: seeded %d save file(s) the pack was missing", seeded)
    end
    return seeded
end

--- @return string[] # the file names, for packSetup's teardown list
function module.files()
    return FILES
end

--- Everything per-machine this module can leave in the pack: the save files, the
--- parked copies, and the parked field values. Used by packSetup's teardown and
--- by --package, so neither can drift from this list.
--- @return string[]
function module.artifacts()
    local out = {}
    for _, name in ipairs(FILES) do
        out[#out + 1] = name
        out[#out + 1] = name .. ".mo_mine"
        out[#out + 1] = name .. ".mo_absent"
    end
    out[#out + 1] = FIELDS_FILE
    return out
end

-- A backup on disk at load means the last session ended while borrowing. Put the
-- player's own save back before anything reads it.
module.restoreOwn()

Network.onEvent("savedata", module.onSaveData)
Network.onEvent("savefields", module.onSaveFields)
Network.onEvent("saveask", module.onSaveAsk)

set_callback(function()
    SafeCall("saveShare:poll", module.poll)
end, ON.GUIFRAME)

SaveShare = module
return module
