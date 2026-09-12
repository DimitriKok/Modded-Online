--- Modded Online — network session core.
--- Talks to the self-hosted Python server (see Documents/Modded online/server)
--- over UDP using the script API's udp_listen/udp_send (requires meta.unsafe).
---
--- Sync model: the server is authoritative for the lobby, the adventure seed
--- and the globally ordered event channel; identical mods + identical seed
--- give identical world generation on every client, so only player state and
--- world-affecting interactions travel over the wire.
---
--- All datagrams are JSON. Incoming data is queued by the udp callback and
--- only processed on the GUI frame, so game state is never touched from
--- outside the main update loop.

local PROTOCOL_VERSION = 1

local PHASE = {
    IDLE = "idle",
    CONNECTING = "connecting",
    LOBBY = "lobby",
    INGAME = "ingame",
    ERROR = "error",
}

-- How often we tell the server we are alive. Kept SHORT relative to the server's
-- in-run drop timer (RUN_TIMEOUT_S) on purpose: input datagrams stop completely
-- while a level generates, and what the server actually measures is the gap since
-- our LAST packet -- so a slow heartbeat spends most of that budget before the
-- freeze even begins. At 2000 ms the remaining margin averaged half the timer and
-- could be nearly zero, which is how a restart's regeneration got players dropped
-- mid-run (see RUN_TIMEOUT_S in server/server.py). Frequent enough that a freeze
-- gets very nearly the whole budget; one tiny datagram, so the cost is nothing.
local HEARTBEAT_MS = 500
local RESEND_MS = 250
-- generous: modded loading screens can stall the whole Lua VM for a while
local TIMEOUT_MS = 30000

--- @class MoNetConfig
--- @field serverHost string
--- @field serverPort integer
--- @field listenPort integer
--- @field playerName string

--- @class MoNetLobbyPlayer
--- @field slot integer
--- @field name string
--- @field ready boolean

local module = {
    PHASE = PHASE,
    --- @type MoNetConfig
    config = {
        serverHost = "127.0.0.1",
        serverPort = 26000,
        listenPort = 26010,
        playerName = "Spelunker",
        -- true: talk through a MANUALLY started client_bridge.py (advanced;
        -- joining by a friend's IP launches the bridge automatically)
        relayMode = false,
        -- the friend's/server's address used by "Join game"
        joinHost = "",
        -- streamer-friendly: mask the room code everywhere it shows (menu field,
        -- camp plaque, in-run status) so viewers can't read it off the stream
        hideRoomCode = false,
        -- TESTING ONLY: how many stand-in players to put in our room (0 = off).
        -- Each is a real client on the real server — see launchTestPlayer.
        testPlayer = 0,
    },
    phase = PHASE.IDLE,
    lastError = nil,     --- @type string?
    room = nil,          --- @type string?
    slot = 0,            -- our server-assigned network slot (1..4)
    --- @type MoNetLobbyPlayer[]
    lobbyPlayers = {},
    --- slot (as string) -> player name, filled at run start
    playerNames = {},
    pingMs = 0,
    --- server's view of "a run is in progress" from lobby broadcasts; nil
    --- until the first one arrives. Used to notice the run ending elsewhere.
    roomStarted = nil,
    --- is this a PUBLIC (matchmaking) room? A guess is set at connect time from
    --- how we joined; the server's lobby broadcast then confirms it. Public
    --- lobbies ready up per-player via the main door and auto-start when all are
    --- ready; private lobbies auto-ready and the host starts via the door.
    roomPublic = nil,
}

local CONFIG_PATH = PackPath("config.json")
local LOAD_ORDER_PATH = "Mods/Packs/load_order.txt"
local SERVER_SCRIPT = PackPathWin("server/server.py")
local HELLO_RETRY_MS = 1000   -- resend create/join while connecting
local CONNECT_TIMEOUT_MS = 12000

--- The local player's Steam persona name, read from the engine's online
--- subsystem (`online.local_player.player_name`). This is populated from the
--- signed-in Steam account and is available even when NOT in an official online
--- session, so it works for our self-hosted rooms. Trimmed and capped to 24
--- chars (matching the old name field). Returns nil if the subsystem isn't ready.
--- @return string?
function module.steamName()
    local name = nil
    pcall(function()
        if online ~= nil and online.local_player ~= nil then
            local n = online.local_player.player_name
            if type(n) == "string" then
                n = n:gsub("^%s+", ""):gsub("%s+$", "")
                if n ~= "" then
                    name = n:sub(1, 24)
                end
            end
        end
    end)
    return name
end

--- Adopt the Steam name as this player's name. Called while the menu is open
--- and again right before connecting, so the shown name always matches what is
--- sent. If the Steam name isn't available yet, the previous value is kept (a
--- graceful fallback to the persisted/default name).
function module.refreshSteamName()
    local n = module.steamName()
    if n ~= nil then
        module.config.playerName = n
    end
end

-- transport / channel internals
local udpHandle = nil          -- keep the UdpServer handle referenced or the socket closes
local boundPort = nil          -- the listen port we ACTUALLY bound (may differ from config
                               -- if it was taken, e.g. a second game instance on this PC)
local rxQueue = {}             -- raw datagram strings, drained each GUI frame
local cid = nil                -- random client id, survives reconnects within a game launch
local nextCseq = 1             -- next outgoing reliable event seq
local pendingOut = {}          -- cseq -> { msg = table, sentAt = ms }
local appliedSeq = 0           -- highest contiguous server event seq we've applied
local bufferedIn = {}          -- seq -> event table waiting for its predecessors
local gapSinceMs = 0           -- when the inbound channel first stalled on a gap
local gapNoticeMs = 0          -- rate limit for the stalled-channel notice
local lastRxMs = 0
local lastPingMs = 0
local guiFrameSeenMs = 0       -- when a GUI frame last reached us (see the watchdog)
local guiFrameNoticeMs = 0
local rxSeen = {}              -- inbound message type -> count, for the notice below
local lastAppliedSeen = -1     -- appliedSeq when it last moved
local lastAppliedMs = 0
local silentNoticeMs = 0
-- A ping is measured in Lua, so it only means "network round trip" if our frame
-- loop kept running the whole time. During a level load the game runs NO script
-- at all, so a pong that spans one measures the LOAD, not the link -- and a
-- rejoin is a level load. That inflated sample is then reported to the server,
-- which sizes the room's shared lockstep input delay from the two worst pings
-- and only ever does so at run start. One contaminated sample therefore pinned
-- the whole party at MAX_INPUT_DELAY (~333 ms of input lag) for the rest of the
-- run -- felt by EVERYONE, which is exactly the "very laggy after rejoining on
-- both ends" report. Discard any sample whose window contains a stall.
local lastTickMs = 0
local pingStalled = false  -- a stall happened since the last ping went out
local STALL_MS = 250       -- far longer than any real frame; a load is seconds
local serverVersionWarned = false  -- one warning per session, not per reconnect
-- The server build this client needs. Deliberately its OWN constant rather than
-- meta.version: most releases fix client-side Lua only, and comparing against the
-- mod version told everyone to "update the server" every time -- for a server that
-- was already correct. Bump this ONLY when server/server.py actually changes, and
-- keep it equal to SERVER_VERSION there.
local EXPECTED_SERVER_VERSION = "1.0.10"
local lastLoadingNoticeMs = 0
-- how often the "I am about to load" warning may repeat while a load is pending
local LOADING_NOTICE_MS = 500
local pendingHello = nil       -- resent while CONNECTING (covers server boot time)
local helloSentMs = 0
local connectStartMs = 0
local eventHandlers = {}       -- kind -> fun(payload, originSlot)
local stateHandler = nil       -- fun(slot, data)
local worldHandler = nil       -- fun(slot, data), the host's world stream
local modSignature = nil       --- @type string?

local function nowMs()
    return get_ms()
end

--- @return string
local function newCid()
    math.randomseed(nowMs())
    return string.format("%08x%08x", math.random(0, 0x7FFFFFFF), math.random(0, 0x7FFFFFFF))
end

--- Fingerprint of the enabled SCRIPT packs, so the server can refuse
--- mismatched lobbies: same seed only gives the same world when everyone
--- simulates it with the same scripts. Two deliberate exclusions keep the
--- gate from rejecting compatible players:
---   * data-only packs (skins, sprites, sounds — no main.lua) never touch
---     the simulation, so they are free to differ between players;
---   * the order of the packs in load_order.txt is ignored (names are
---     sorted) — Modlunky reorders freely and order differences were locking
---     players with identical mods out of each other's lobbies.
--- @return string
--- Collect a script pack's .lua file paths RELATIVE to Mods/Packs (so the
--- install location doesn't matter), lower-cased. Different VERSIONS of a mod
--- add/remove/rename files, so this set fingerprints the version — and it's
--- immune to our shim (the shim edits main.lua's CONTENTS but never adds/removes
--- files, so the path set is identical whether or not the shim has been applied).
--- @param packName string
--- @param out string[]
local function collectPackLuaPaths(packName, out)
    pcall(function()
        local pipe = io.popen(string.format('dir /s /b "Mods\\Packs\\%s\\*.lua" 2>nul', packName))
        if pipe == nil then
            return
        end
        for f in pipe:lines() do
            local low = f:lower():gsub("/", "\\")
            local idx = low:find("\\packs\\", 1, true)
            if idx ~= nil then -- keep only "packname\...\file.lua" (machine-independent)
                out[#out + 1] = low:sub(idx + 7)
            end
        end
        pipe:close()
    end)
end

--- LEFTOVER Modded Online blocks still sitting in a pack's main.lua
--- ("v19+opt1", or "none" for a clean pack). Nothing writes these any more --
--- injection was replaced by hosting in 2.0.0-dev42 and the injector deleted --
--- but packs installed by older versions still carry them on disk, and such a
--- pack runs an old determinism payload of its own the moment it is enabled.
--- Two machines carrying different leftovers handle the mod's PRNG differently,
--- so folding the marker into the key keeps that pairing out of a room.
--- (modHost refuses to HOST a marked pack outright; this covers the other
--- case, where the pack is enabled in Playlunky and running on its own.)
---
--- This matters because an injected shim only takes effect on the NEXT launch: a
--- player who updates Modded Online and plays WITHOUT restarting runs the PREVIOUS
--- shim while reporting the NEW mod version. The two machines then handle the
--- content mod's PRNG differently, so every floor where that mod draws diverges
--- (observed: a vault-sac reward rolled an elixir on one machine and a jetpack on
--- the other). The file-path fingerprint cannot catch it — the shim rewrites
--- main.lua's CONTENTS without adding or removing files — so fold the live marker
--- in and block the pairing at connect instead of desyncing mid-run.
--- @param packName string
--- @return string
local function packShimVersion(packName)
    local marker = "none"
    pcall(function()
        local f = io.open("Mods/Packs/" .. packName .. "/main.lua", "r")
        if f == nil then
            return
        end
        -- Both blocks are PREPENDED, so they sit at the top of the file -- but the
        -- determinism shim alone is ~25 KB, so the option-sync marker behind it is
        -- far past the 4 KB this used to read. Read enough to cover both.
        local head = f:read(262144) or ""
        f:close()
        local v = head:match("%[ModdedOnline%-DeterminismShim%-(v%d+)%]")
        if v ~= nil then
            marker = v
        end
        local o = head:match("%[ModdedOnline%-OptionSync%-(v%d+)%]")
        if o ~= nil then
            marker = marker .. "+opt" .. o
        end
    end)
    return marker
end

-- Content mods that get the FULL determinism treatment: the engine-prng shim
-- variant AND our engine-internal coffin fixes. Everything else is touched as
-- little as possible — a mod that owns its own LEVEL GENERATION (the HD mod
-- builds levels in Lua and swaps state.theme_info every level via
-- force_custom_theme) desyncs when we hook engine internals underneath it, and
-- ran correctly on Modded Online 0.14.5, which did none of this.
-- KEEP IN SYNC with FULL_SHIM_PATTERNS in src/shimInjector.lua.
local FULL_TREATMENT_PATTERNS = { "spelunky%-?25", "spelunky%-?2%.5", "spelunky 2%.5" }
local fullTreatment = nil

--- True when Spelunky 2.5 is one of the enabled script packs, i.e. when the
--- engine-internal fixes that only IT needs should be applied. Cached; the load
--- order cannot change while the game is running.
--- @return boolean
function module.fullTreatmentMod()
    if fullTreatment ~= nil then
        return fullTreatment
    end
    fullTreatment = false
    pcall(function()
        for rawLine in io.lines(LOAD_ORDER_PATH) do
            local line = rawLine:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1, 2) ~= "--" then
                local low = line:lower()
                for _, pattern in ipairs(FULL_TREATMENT_PATTERNS) do
                    if low:find(pattern) ~= nil then
                        fullTreatment = true
                        return
                    end
                end
            end
        end
    end)
    return fullTreatment
end

--- The enabled SCRIPT packs (a pack with a main.lua), excluding our own, in load
--- order. Several places walked load_order.txt with this exact filter inline.
--- @return string[]
function module.enabledScriptPacks()
    local names = {}
    pcall(function()
        local ownPack = PackDir()
        for rawLine in io.lines(LOAD_ORDER_PATH) do
            local line = rawLine:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1, 2) ~= "--" and line ~= ownPack then
                local script = io.open("Mods/Packs/" .. line .. "/main.lua", "r")
                if script ~= nil then
                    script:close()
                    names[#names + 1] = line
                end
            end
        end
    end)
    return names
end

--- The packs we HOST: content mods running inside our own Lua state rather than
--- loaded by Playlunky. They are disabled in load_order.txt by necessity — that is
--- what stops Playlunky running them a second time — so nothing that walks that file
--- can see them.
--- @return string[]
function module.hostedScriptPacks()
    local names = {}
    pcall(function()
        -- ModHost loads after this module, so this is a runtime lookup, not an upvalue
        local host = rawget(_G, "ModHost")
        if type(host) == "table" and type(host.hostedPacks) == "function" then
            names = host.hostedPacks()
        end
    end)
    return names
end

--- Every content mod in play, however it got there: enabled script packs plus hosted
--- ones. This is the list that matters for compatibility and for options — both are
--- questions about what code is RUNNING, not about what load_order.txt says.
--- @return string[] names, table<string, boolean> hostedByName
function module.syncedScriptPacks()
    local names, seen, isHosted = {}, {}, {}
    for _, name in ipairs(module.enabledScriptPacks()) do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(module.hostedScriptPacks()) do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
        isHosted[name] = true
    end
    return names, isHosted
end

--- One script pack's persisted OPTIONS, straight out of its `save.dat`.
--- Playlunky writes `{"options": {...}}` there for every pack that declares
--- script options, and the pack reads them LIVE, so this is the table whose
--- values decide how that mod behaves this run.
---
--- Deliberately only `options`. A pack's save.dat also holds PROGRESS —
--- `journal`, `cameos_interactions_done`, `tutorial_records` in the HD mod's case
--- — and nothing here reads or returns those.
--- @param packName string
--- @return table<string, any>?
function module.packOptions(packName)
    local opts = nil
    pcall(function()
        local f = io.open("Mods/Packs/" .. packName .. "/save.dat", "r")
        if f == nil then
            return
        end
        local data = f:read("*a")
        f:close()
        if data == nil or data == "" then
            return
        end
        local parsed = NetJson.decode(data)
        if type(parsed) == "table" and type(parsed.options) == "table" then
            opts = parsed.options
        end
    end)
    return opts
end

--- Every enabled script pack's persisted OPTIONS, flattened into one key -> value
--- table. Used to sync a joiner's mod settings to the host's (see eventSync's
--- option sync) so people with different settings can still play together.
---
--- Flattening is safe because Playlunky's option names are already globally
--- unique in practice — every pack prefixes them (`hd_`, `pos_`, ...) because
--- they share one settings UI — and the override is applied per-pack anyway.
---
--- Deliberately only `options`. A pack's save.dat also holds PROGRESS —
--- `journal`, `cameos_interactions_done`, `tutorial_records` in the HD mod's case
--- — and nothing here reads or writes those. Combined with never writing save.dat
--- at all (Playlunky owns that file), a player's progress cannot be touched by
--- this feature even in principle.
--- @return table<string, any>
function module.allPackOptions()
    local all = {}
    for _, packName in ipairs(module.syncedScriptPacks()) do
        local opts = module.packOptions(packName)
        if opts ~= nil then
            for k, v in pairs(opts) do
                all[k] = v
            end
        end
    end
    return all
end

--- @param text string
--- @return string # 8 hex digits
local function djb2(text)
    local hash = 5381
    for i = 1, #text do
        hash = ((hash << 5) + hash + text:byte(i)) & 0xFFFFFFFF
    end
    return string.format("%08x", hash)
end

--- Fingerprint the enabled SCRIPT packs so two players who differ — a different
--- mod list, different VERSIONS of the same mods, or a different INJECTED SHIM
--- (see packShimVersion) — can't silently connect and desync every floor.
--- Data-only packs (no main.lua — skins, textures) don't affect the simulation,
--- so they're ignored.
---
--- One `name:files:hash:shim` entry per pack, `|`-separated (neither character is
--- legal in a Windows folder name, so no pack name can forge an entry boundary).
--- It is DELIBERATELY not one opaque digest: a single hash can only ever say "you
--- two differ", and a real report of this was two players with the same mod, the
--- same 199 files, and no way for either of them — or for me — to find out which
--- of the four things had moved. Every field can now be diffed on its own, which
--- is what describeModMismatch turns into a sentence that names the problem.
---
--- The FILE HASH covers each .lua path with the pack's own folder name stripped,
--- so installing the same mod under a different folder name shows up as a NAME
--- difference with a matching hash — a rename, not a different mod, and fixable
--- in ten seconds once it says so.
--- @return string
local function loadOrderSignature()
    if modSignature ~= nil then
        return modSignature
    end
    local entries = {}
    -- OUR OWN pack is deliberately left out. The signature exists to prove the
    -- CONTENT mods match, and our own build is already carried beside it as
    -- meta.version. Folding ourselves in made the FOLDER NAME (and every one of
    -- our own file paths) part of the compatibility key -- so the moment the
    -- pack was published and installed as `fyi.modded-online` instead of
    -- `Modded Online`, two players on an identical build were rejected as
    -- running different mods, with nothing on screen to say why.
    pcall(function()
        -- syncedScriptPacks, NOT the load_order walk this used to do: a hosted mod is
        -- disabled in that file, so walking it left the mod we are actually running
        -- out of the very key that proves we are running the same mods.
        local names, isHosted = module.syncedScriptPacks()
        for _, name in ipairs(names) do
            local script = io.open("Mods/Packs/" .. name .. "/main.lua", "r")
            if script ~= nil then
                script:close()
                local paths = {}
                collectPackLuaPaths(name, paths)
                -- drop the pack folder from the front of every path, so the hash
                -- describes the mod's CONTENTS and not where it lives
                local prefix = name:lower() .. "\\"
                for i = 1, #paths do
                    if paths[i]:sub(1, #prefix) == prefix then
                        paths[i] = paths[i]:sub(#prefix + 1)
                    end
                end
                table.sort(paths)
                -- "hosted" where the shim version would go. A machine RUNNING a mod
                -- inside our state and a machine letting Playlunky run it with an
                -- injected payload are not the same execution model, and should not
                -- be treated as compatible just because the files match.
                local how = isHosted[name] and "hosted" or packShimVersion(name)
                entries[#entries + 1] = string.format("%s:%d:%s:%s",
                    name, #paths, djb2(table.concat(paths, "\0")), how)
            end
        end
    end)
    table.sort(entries)
    -- Options are NOT part of this key, and since the shim was removed nothing
    -- synchronises them either -- so two players whose HOSTED MOD settings differ
    -- generate different worlds from the same seed and desync, with only the
    -- `packopts=` line in the desync log to say why. THIS IS A KNOWN GAP.
    --
    -- It is left open rather than closed carelessly: gating on the raw option set
    -- would keep compatible players out for nothing, because window positions and
    -- debug-overlay toggles are persisted options too, and a hosted mod registers
    -- its options into OUR pack beside the per-pack mod-picker checkboxes -- which
    -- differ the moment two players have different mods installed. Closing it
    -- properly means gating on a FILTERED subset, which is a design decision and
    -- not a tidy-up.
    modSignature = #entries > 0 and table.concat(entries, "|") or "no script mods"
    return modSignature
end

--- Our own mod-compatibility signature — the exact string the server matches a
--- room on. Exposed so the desync log can record it and so a rejection can print
--- both sides side by side.
--- @return string
function module.modSignature()
    return loadOrderSignature()
end

--- Say, in words, what actually differs between our mods and the room's. The
--- server hands back the room's whole `modv` on a rejection, and both sides are
--- structured (see loadOrderSignature), so this is a field-by-field diff rather
--- than a shrug.
--- @param theirsFull string # the room's "<version> + <signature>"
--- @return string # one short line for the menu
--- @return string[] # the detail, one line per difference
function module.describeModMismatch(theirsFull)
    local function split(full)
        local version, sig = tostring(full):match("^(.-) %+ (.*)$")
        local packs, order = {}, {}
        for entry in tostring(sig or ""):gmatch("[^|]+") do
            local name, files, hash, shim = entry:match("^(.*):(%d+):(%x+):(.*)$")
            if name ~= nil then
                packs[name] = { files = tonumber(files), hash = hash, shim = shim }
                order[#order + 1] = name
            end
        end
        return version or "?", packs, order
    end

    local myVersion, mine, myOrder = split(meta.version .. " + " .. loadOrderSignature())
    local theirVersion, theirs, theirOrder = split(theirsFull)
    local detail = {}

    if myVersion ~= theirVersion then
        detail[#detail + 1] = string.format(
            "Modded Online itself differs: you have %s, the room has %s.", myVersion, theirVersion)
        return "Your Modded Online version differs from the room's", detail
    end

    -- A pack missing on one side whose CONTENTS match a pack missing on the other
    -- is the same mod in a differently named folder -- by far the easiest of these
    -- to fix, and completely invisible without saying so.
    local renames = {}
    for _, name in ipairs(myOrder) do
        if theirs[name] == nil then
            for _, other in ipairs(theirOrder) do
                if mine[other] == nil and theirs[other].hash == mine[name].hash then
                    renames[name] = other
                end
            end
        end
    end

    for _, name in ipairs(myOrder) do
        local ours, room = mine[name], theirs[name]
        if renames[name] ~= nil then
            detail[#detail + 1] = string.format(
                "'%s' is the same mod as the room's '%s', just a differently named folder"
                .. " — rename your Mods/Packs folder to '%s' (and the line in load_order.txt).",
                name, renames[name], renames[name])
        elseif room == nil then
            detail[#detail + 1] = string.format(
                "You have '%s' enabled and the room does not — disable it in load_order.txt.", name)
        elseif ours.files ~= room.files then
            detail[#detail + 1] = string.format(
                "'%s' is a different VERSION: yours has %d .lua files, the room's has %d.",
                name, ours.files, room.files)
        elseif ours.hash ~= room.hash then
            detail[#detail + 1] = string.format(
                "'%s' has the same %d files but they are not the same files — one of you has"
                .. " an edited or differently packaged build. Reinstall it from the same download.",
                name, ours.files)
        elseif ours.shim ~= room.shim then
            detail[#detail + 1] = string.format(
                "'%s' is patched differently: yours is %s, the room's is %s. Modded Online"
                .. " patches mods at launch and the patch only takes effect NEXT launch —"
                .. " whoever is behind should start the game once more and rejoin.",
                name, ours.shim, room.shim)
        end
    end
    for _, name in ipairs(theirOrder) do
        if mine[name] == nil and renames[name] == nil then
            local isRename = false
            for _, to in pairs(renames) do
                isRename = isRename or to == name
            end
            if not isRename then
                detail[#detail + 1] = string.format(
                    "The room has '%s' enabled and you do not — enable it in load_order.txt.", name)
            end
        end
    end

    if #detail == 0 then
        detail[#detail + 1] = string.format("yours: %s", loadOrderSignature())
        detail[#detail + 1] = string.format("room's: %s", theirsFull)
        return "Mods don't match the room", detail
    end
    return detail[1]:gsub("%s+$", ""), detail
end

--- The live injected shim versions ("pack=v7, other=none"), for the desync log
--- header — a shim mismatch between two machines is otherwise invisible.
--- @return string
function module.shimVersions()
    local out = {}
    pcall(function()
        local names, isHosted = module.syncedScriptPacks()
        for _, name in ipairs(names) do
            local script = io.open("Mods/Packs/" .. name .. "/main.lua", "r")
            if script ~= nil then
                script:close()
                out[#out + 1] = name .. "="
                    .. (isHosted[name] and "hosted" or packShimVersion(name))
            end
        end
    end)
    table.sort(out)
    return #out > 0 and table.concat(out, ", ") or "none"
end

--- Canonical hash of a pack's ENTIRE persisted save (Mods/Packs/<pack>/save.dat).
---
--- Mods keep PROGRESS there — unlocks, achievements, tutorial flags — and a mod
--- that branches on its own progress builds a different world on each machine.
--- That is precisely how the HD mod's unlock system diverged, and it is invisible
--- from our side, so the desync log records it: two machines showing different
--- hashes for the same pack have different mod progress.
---
--- Keys are sorted RECURSIVELY before hashing, so identical state hashes
--- identically no matter what order the mod happened to serialise its JSON in
--- (raw file bytes would false-alarm on ordering alone).
--- @param packName string
--- @return string
function module.packSaveHash(packName)
    local out = "none"
    pcall(function()
        local f = io.open("Mods/Packs/" .. packName .. "/save.dat", "r")
        if f == nil then
            return
        end
        local data = f:read("*a")
        f:close()
        local parsed = NetJson.decode(data)
        if type(parsed) ~= "table" then
            return
        end
        local parts = {}
        local function canon(value, depth)
            if depth > 12 or type(value) ~= "table" then
                parts[#parts + 1] = tostring(value)
                return
            end
            local keys = {}
            for k in pairs(value) do
                keys[#keys + 1] = k
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            parts[#parts + 1] = "{"
            for _, k in ipairs(keys) do
                parts[#parts + 1] = tostring(k) .. "="
                canon(value[k], depth + 1)
                parts[#parts + 1] = ","
            end
            parts[#parts + 1] = "}"
        end
        canon(parsed, 0)
        local joined = table.concat(parts)
        local hash = 5381
        for i = 1, #joined do
            hash = ((hash << 5) + hash + joined:byte(i)) & 0xFFFFFFFF
        end
        out = string.format("%08x", hash)
    end)
    return out
end

--- Every enabled script pack's save hash (see packSaveHash), for the log header.
--- @return string
function module.packSaveHashes()
    local out = {}
    pcall(function()
        for rawLine in io.lines(LOAD_ORDER_PATH) do
            local line = rawLine:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1, 2) ~= "--" then
                local script = io.open("Mods/Packs/" .. line .. "/main.lua", "r")
                if script ~= nil then
                    script:close()
                    local h = module.packSaveHash(line)
                    if h ~= "none" then
                        out[#out + 1] = line .. "=" .. h
                    end
                end
            end
        end
    end)
    table.sort(out)
    return #out > 0 and table.concat(out, ", ") or "none"
end

--- Each enabled script pack's persisted-OPTIONS hash (see packOptionsHash), for
--- the desync log header. Two machines showing DIFFERENT hashes for the same pack
--- have different mod settings — and a mod whose generator reads its own options
--- will then build different worlds from the same seed.
--- @return string
function module.packOptionHashes()
    local out = {}
    pcall(function()
        for rawLine in io.lines(LOAD_ORDER_PATH) do
            local line = rawLine:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1, 2) ~= "--" then
                local script = io.open("Mods/Packs/" .. line .. "/main.lua", "r")
                if script ~= nil then
                    script:close()
                    local h = module.packOptionsHash(line)
                    if h ~= "none" then
                        out[#out + 1] = line .. "=" .. h
                    end
                end
            end
        end
    end)
    table.sort(out)
    return #out > 0 and table.concat(out, ", ") or "none"
end

-- -------------------------------------------------------------- config

function module.loadConfig()
    local ok, content = pcall(function()
        local f = io.open(CONFIG_PATH, "r")
        if f == nil then
            return nil
        end
        local data = f:read("*a")
        f:close()
        return data
    end)
    if not ok or content == nil then
        return
    end
    local parsed = NetJson.decode(content)
    if type(parsed) == "table" then
        for key, value in pairs(module.config) do
            if parsed[key] ~= nil and type(parsed[key]) == type(value) then
                module.config[key] = parsed[key]
            end
        end
        -- testPlayer used to be a boolean and is now a COUNT, so the type check
        -- above skips an older config's value. Carry it over rather than silently
        -- switching the option off for anyone who had it on.
        if type(parsed.testPlayer) == "boolean" then
            module.config.testPlayer = parsed.testPlayer and 1 or 0
        end
        dbg("config loaded")
    end
end

function module.saveConfig()
    local ok = pcall(function()
        local f = assert(io.open(CONFIG_PATH, "w"))
        f:write(NetJson.encode(module.config))
        f:close()
    end)
    if not ok then
        dbg("could not persist config")
    end
end

--- A hash of a pack's PERSISTED OPTIONS (Playlunky writes each pack's script
--- options to `<pack>/save.dat`, e.g. `{"options":{...}}`). Mod options can feed
--- LEVEL GENERATION — the HD mod's own Lua generator reads
--- `hd_debug_scripted_levelgen_disable`, `hd_og_cursepot_enable` and others to pick
--- ROOM POOLS — so two players with different settings build different worlds from
--- the same seed. Logged in the desync-log header so an options mismatch is
--- visible instead of showing up as an unexplained generation desync.
--- @param packName string
--- @return string
function module.packOptionsHash(packName)
    local out = "none"
    pcall(function()
        local f = io.open("Mods/Packs/" .. packName .. "/save.dat", "r")
        if f == nil then
            return
        end
        local data = f:read("*a")
        f:close()
        local parsed = NetJson.decode(data)
        if type(parsed) ~= "table" or type(parsed.options) ~= "table" then
            return
        end
        -- hash the option KEYS AND VALUES in sorted order, so the digest is stable
        -- regardless of the order the mod happened to serialise them in
        local keys = {}
        for k in pairs(parsed.options) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        local joined = ""
        for _, k in ipairs(keys) do
            joined = joined .. k .. "=" .. tostring(parsed.options[k]) .. "\0"
        end
        local hash = 5381
        for i = 1, #joined do
            hash = ((hash << 5) + hash + joined:byte(i)) & 0xFFFFFFFF
        end
        out = string.format("%d opts/%08x", #keys, hash)
    end)
    return out
end

-- -------------------------------------------------------------- transport

-- the local client_bridge.py listens here and relays to the real server
local BRIDGE_PORT = 26011
local BRIDGE_SCRIPT = PackPathWin("server/client_bridge.py")
local TEST_PLAYER_SCRIPT = PackPathWin("server/fake_player.py")

-- Default public matchmaking server for "Randoms" (quick match). Open public
-- rooms live here; picking a mod finds one (or opens a new one). It's a remote
-- host, so matchmaking routes through the bridge like joining a friend. Run
-- this server with `py server.py --dedicated` so it stays up between sessions.
local PUBLIC_HOST = "129.213.14.228"
local PUBLIC_PORT = 26000

--- Where this session's traffic goes and which listen port the hello
--- declares (0 = relay mode: server replies to the observed source).
--- @type { host: string, port: integer, helloPort: integer }?
local route = nil

--- The address of the REAL server, which is not always where `route` points: a
--- remote server is reached through the local bridge, so `route` is 127.0.0.1.
--- The test player is its own process with its own socket, so it dials the real
--- server directly (it declares relay mode, so it needs no port forward either).
--- @type { host: string, port: integer }?
local serverEndpoint = nil

local function defaultRoute()
    if module.config.relayMode then
        return { host = "127.0.0.1", port = BRIDGE_PORT, helloPort = 0 }
    end
    return {
        host = module.config.serverHost,
        port = module.config.serverPort,
        helloPort = module.config.listenPort,
    }
end

--- @param msg table
local function sendToServer(msg)
    msg.room = module.room
    msg.cid = cid
    local r = route or defaultRoute()
    udp_send(r.host, r.port, NetJson.encode(msg))
end

local function openSocket()
    if udpHandle ~= nil then
        return true
    end
    -- Bind our configured listen port; if it's taken (another game instance on
    -- this PC, or a stale socket) fall back to the next few ports so two clients
    -- on one machine don't fight over one port. We declare the port we ACTUALLY
    -- bound to the server (see connect), so its pushes reach the right instance.
    local base = module.config.listenPort
    for offset = 0, 8 do
        local port = base + offset
        local ok, handleOrErr = pcall(udp_listen, "0.0.0.0", port, function(data)
            -- may be invoked outside the game update loop: only queue, never touch game state
            rxQueue[#rxQueue + 1] = data
        end)
        if ok then
            udpHandle = handleOrErr
            boundPort = port
            if offset > 0 then
                dbgf("listen port %d busy — bound %d instead (another instance on this PC?)", base, port)
            end
            return true
        end
    end
    module.lastError = "Could not open a UDP port near " .. tostring(base)
    errorf("udp_listen failed on ports %d..%d", base, base + 8)
    return false
end

local function resetChannel()
    nextCseq = 1
    pendingOut = {}
    appliedSeq = 0
    bufferedIn = {}
    rxQueue = {}
end

-- -------------------------------------------------------------- public api

--- True while connected to a lobby or in a networked run.
--- @return boolean
function module.isActive()
    return module.phase == PHASE.LOBBY or module.phase == PHASE.INGAME
end

--- @return boolean
function module.isInRun()
    return module.phase == PHASE.INGAME
end

--- Register a handler for a reliable event kind. Handlers receive
--- (payload, originSlot); originSlot 0 means the server itself.
--- @param kind string
--- @param handler fun(payload: any, originSlot: integer)
function module.onEvent(kind, handler)
    eventHandlers[kind] = handler
end

--- Register the unreliable player-state handler (one consumer: playerSync).
--- @param handler fun(slot: integer, data: any)
function module.onState(handler)
    stateHandler = handler
end

--- Register the unreliable world-stream handler (one consumer: worldSync).
--- @param handler fun(slot: integer, data: any)
function module.onWorld(handler)
    worldHandler = handler
end

--- Send an unreliable authoritative-world datagram (host's game only).
--- @param data table
function module.sendWorld(data)
    if not module.isActive() then
        return
    end
    sendToServer({ t = "world", d = data })
end

--- The network slot whose game is the authoritative world simulation.
--- Fixed at run start; 0 when no run is active.
--- @return integer
function module.hostSlot()
    return module.runHostSlot or 0
end

--- Is this client the authoritative world simulation?
--- @return boolean
function module.isWorldHost()
    return module.isInRun() and module.slot == module.hostSlot()
end

--- Send a world-affecting interaction through the server's ordered reliable
--- channel. It comes back to every client (including this one) in `event`
--- handlers, stamped with our slot.
--- @param kind string
--- @param payload any
function module.sendEvent(kind, payload)
    if not module.isActive() then
        return
    end
    pendingOut[nextCseq] = { msg = { t = "event", cseq = nextCseq, k = kind, p = payload }, sentAt = 0 }
    nextCseq = nextCseq + 1
end

--- Warn the server that we are about to block on a screen load.
---
--- While the game builds a level our Lua callbacks do not run at all, so we send
--- nothing however healthy we are — and silence is the only liveness signal the
--- server has. On a heavy floor a single blocked frame can last tens of seconds,
--- which the in-run drop timer read as a dead client: walking into an exit door
--- on a laggy level got the player evicted mid-run, and because they were the
--- host that closed the room. Saying so BEFORE we block is the only fix that
--- works, because during the block we cannot say anything at all.
---
--- Cheap and idempotent (one small datagram, throttled), and the grace it buys
--- ends the moment we send an input again.
function module.sendLoadingNotice()
    if not module.isInRun() then
        return
    end
    sendToServer({ t = "loading" })
end

--- Send unreliable, latest-wins player state (position etc).
--- @param data table
function module.sendState(data)
    if not module.isActive() then
        return
    end
    sendToServer({ t = "state", d = data })
end

--- @param host string
--- @return boolean
local function isLocalAddress(host)
    return host == "127.0.0.1" or host == "localhost" or host == "::1"
end

-- ------------------------------------------------------------------ python
--
-- The server, the client bridge and the test players are Python scripts. Without
-- Python installed, `start ... py script.py` produced a bare Windows "not
-- recognised" box from a console nobody asked for, and the game just sat there
-- failing to connect — a player with no reason to know this mod needs Python at
-- all has no way to work that out.
local PYTHON_DOWNLOAD_URL = "https://www.python.org/downloads/"
-- `py` (the official launcher) first: it ships with python.org installs and is
-- what every doc here assumes. The others cover installs that omit it.
local PYTHON_CANDIDATES = { "py", "python", "python3" }
local pythonCmd = nil
local pythonChecked = false
local pythonNoticeShown = false

--- Detect a usable interpreter ONCE, and remember it.
---
--- Uses `where`, NOT `<cmd> --version`. On Windows a machine with no Python still
--- has `python.exe` on PATH as an App Execution Alias, and RUNNING it opens the
--- Microsoft Store — a wildly surprising thing for a silent capability check to
--- do. `where` only resolves the name. Those same stubs live under WindowsApps,
--- so a hit there is ignored: it is the Store placeholder, not an interpreter.
--- @return string? # the command to launch with, or nil if there is no Python
local function detectPython()
    if pythonChecked then
        return pythonCmd
    end
    pythonChecked = true
    for _, cmd in ipairs(PYTHON_CANDIDATES) do
        pcall(function()
            local pipe = io.popen(string.format("where %s 2>nul", cmd))
            if pipe == nil then
                return
            end
            for line in pipe:lines() do
                local path = line:gsub("^%s+", ""):gsub("%s+$", "")
                if path ~= "" and path:lower():find("windowsapps", 1, true) == nil then
                    pythonCmd = cmd
                    break
                end
            end
            pipe:close()
        end)
        if pythonCmd ~= nil then
            break
        end
    end
    if pythonCmd ~= nil then
        dbgf("using '%s' to run the helper scripts", pythonCmd)
    end
    return pythonCmd
end

--- The interpreter to launch helper scripts with, or nil — in which case the
--- player has already been told what to do and the caller must NOT launch.
--- Says it once per session, in the game, and opens the download page, because
--- a silent failure here looks exactly like the mod being broken.
--- @param what string # what needed Python, for the message
--- @return string?
function module.requirePython(what)
    local cmd = detectPython()
    if cmd ~= nil then
        return cmd
    end
    module.lastError = "Python is required — see the page that just opened"
    if not pythonNoticeShown then
        pythonNoticeShown = true
        errorf("Python is not installed, so %s cannot start. Modded Online's server, "
            .. "bridge and test players are Python scripts. Install Python from %s "
            .. "(tick \"Add python.exe to PATH\"), then restart Spelunky 2.", what, PYTHON_DOWNLOAD_URL)
        pcall(toast, "Python is required to play online — opening the download page")
        pcall(function()
            os.execute(string.format('start "" "%s"', PYTHON_DOWNLOAD_URL))
        end)
    end
    return nil
end

local launchedServer = false
local launchedBridge = false
-- the room our test players were started for, or nil when none are running: the
-- `joined` reply can repeat (resends, reconnects) and must not stack up windows
local testPlayerRoom = nil
local testPlayerCount = 0
-- A room holds 4 players (MAX_PLAYERS_PER_ROOM on the server) and one of them is
-- us, so three stand-ins is a full house.
local MAX_TEST_PLAYERS = 3
module.MAX_TEST_PLAYERS = MAX_TEST_PLAYERS
-- one character each, so they are distinguishable in the lobby and the co-op HUD
-- (194 is the usual host pick, so the stand-ins start above it)
local TEST_PLAYER_CHARS = { 195, 196, 197 }

--- Launch the bundled server in a background window. Safe to call when a
--- server is already running (the second instance notices and exits).
function module.launchLocalServer()
    local py = module.requirePython("the game server")
    if py == nil then
        return false
    end
    local ok, err = pcall(function()
        -- REPLACE any server still running, don't just start alongside it. A
        -- second instance politely exits when the port is taken, which means a
        -- server left over from an earlier session keeps serving -- running
        -- whatever code it was launched with. Every server-side fix then appears
        -- not to work until the machine is rebooted, and the symptom is always
        -- "I updated and nothing changed" (a pinned seed that a restart re-rolled
        -- was exactly this). Killing it first makes the running server always the
        -- shipped one. Matches by our own window title, so a `--dedicated` server
        -- someone started by hand in their own console is untouched.
        os.execute('taskkill /F /FI "WINDOWTITLE eq Modded Online Server*" >nul 2>&1')
        os.execute(string.format('start "Modded Online Server" /min %s "%s" --verbose',
            py, SERVER_SCRIPT))
    end)
    if ok then
        launchedServer = true
        dbg("starting the local server...")
    else
        errorf("could not launch the local server: %s", tostring(err))
    end
    return ok
end

--- Launch the client bridge towards a friend's server, replacing any bridge
--- left over from an earlier session (which might target a stale address).
--- @param host string
--- @param port integer
function module.launchBridge(host, port)
    local py = module.requirePython("the connection bridge")
    if py == nil then
        return false
    end
    local ok, err = pcall(function()
        os.execute('taskkill /F /FI "WINDOWTITLE eq Modded Online Bridge*" >nul 2>&1')
        os.execute(string.format('start "Modded Online Bridge" /min %s "%s" "%s" %d',
            py, BRIDGE_SCRIPT, host, port))
    end)
    if ok then
        launchedBridge = true
        dbgf("starting the bridge to %s...", host)
    else
        errorf("could not launch the bridge: %s", tostring(err))
    end
    return ok
end

--- TESTING AID: put stand-in players in this room so the mod's multiplayer paths
--- can be exercised without other people. Each is a REAL client — its own
--- process, its own socket, a real slot on the real server — so the roster, the
--- lockstep, the co-op HUD and every "is there anyone else here" branch behave
--- exactly as they do with humans. They stand still and simulate nothing, so they
--- cannot tell you whether two machines AGREE (that still takes two machines).
---
--- They dial the real server directly rather than following our route: they
--- declare relay mode, so they work from behind the same NAT with no port forward,
--- and they must NOT share our listen port — two clients on one port cross the
--- server's pushes over and scramble slot assignment (see inputSync's roster
--- guard). Each gets its own ephemeral port for the same reason.
function module.launchTestPlayer()
    local count = math.floor(tonumber(module.config.testPlayer) or 0)
    if count > MAX_TEST_PLAYERS then
        count = MAX_TEST_PLAYERS
    end
    if count <= 0 then
        return
    end
    -- re-launch when the COUNT changes too, not just the room
    if testPlayerRoom == module.room and testPlayerCount == count then
        return
    end
    local endpoint = serverEndpoint
    if endpoint == nil or module.room == nil then
        return
    end
    local py = module.requirePython("the test players")
    if py == nil then
        return
    end
    local ok, err = pcall(function()
        -- the wildcard covers every numbered window, so this clears any previous
        -- set before starting the new one
        os.execute('taskkill /F /FI "WINDOWTITLE eq Modded Online Test Player*" >nul 2>&1')
        for i = 1, count do
            -- Distinct name and character per bot so they are told apart at a
            -- glance in the lobby and the co-op HUD. Names are deliberately
            -- single-token: they are passed through `start`, which already treats
            -- the first quoted argument as the window title.
            os.execute(string.format(
                'start "Modded Online Test Player %d" /min %s "%s" "%s" %d "%s" --name Dummy%d --char %d',
                i, py, TEST_PLAYER_SCRIPT, endpoint.host, endpoint.port, module.room,
                i, TEST_PLAYER_CHARS[i] or 195))
        end
    end)
    if ok then
        testPlayerRoom = module.room
        testPlayerCount = count
        dbgf("%d test player(s) joining room %s...", count, tostring(module.room))
        -- Never silent: this puts extra bodies in the lobby, and the setting is
        -- persisted, so someone who left it on and then joined a friend's room
        -- needs to be told why there are strangers in it.
        pcall(toast, string.format("%d test player%s joining (turn TEST PLAYERS off in the menu)",
            count, count == 1 and "" or "s"))
    else
        errorf("could not launch the test player: %s", tostring(err))
    end
end

--- Send every stand-in player home. Safe to call when none are running; also the
--- path the menu takes when the count is turned back to OFF mid-session, so they
--- leave the lobby immediately instead of at the next room change.
function module.stopTestPlayers()
    if testPlayerRoom == nil then
        return
    end
    testPlayerRoom = nil
    testPlayerCount = 0
    pcall(function()
        os.execute('taskkill /F /FI "WINDOWTITLE eq Modded Online Test Player*" >nul 2>&1')
    end)
    dbg("test players stopped")
end

--- Close background helpers this session started (server/bridge windows).
local function stopLaunchedProcesses()
    module.stopTestPlayers()
    if launchedServer then
        launchedServer = false
        pcall(function()
            os.execute('taskkill /F /FI "WINDOWTITLE eq Modded Online Server*" >nul 2>&1')
        end)
        dbg("local server stopped")
    end
    if launchedBridge then
        launchedBridge = false
        pcall(function()
            os.execute('taskkill /F /FI "WINDOWTITLE eq Modded Online Bridge*" >nul 2>&1')
        end)
    end
end

--- Host a new room.
---   * Server IP is this machine (127.0.0.1 / empty): the bundled server is
---     started automatically and we talk to it directly (the connect retries
---     cover its boot time).
---   * Server IP is ANOTHER machine (a LAN box, or a server you run on your
---     desktop/a VPS): we go through the client bridge — exactly like joining a
---     friend's room — so the server's replies get back to us with no inbound
---     port forward on THIS machine. Start server.py on that machine yourself.
---   * relayMode: talk through a MANUALLY started bridge (advanced).
function module.hostGame()
    local target = (module.config.serverHost or ""):gsub("%s", "")
    -- the real server, whichever way our own traffic gets there (see serverEndpoint)
    serverEndpoint = { host = target ~= "" and target or "127.0.0.1",
                       port = module.config.serverPort }
    if module.config.relayMode then
        route = defaultRoute()
    elseif target == "" or isLocalAddress(target) then
        route = {
            host = target ~= "" and target or "127.0.0.1",
            port = module.config.serverPort,
            helloPort = module.config.listenPort,
        }
        if not module.launchLocalServer() then
            return -- no Python: requirePython has already explained why
        end
    else
        if not module.launchBridge(target, module.config.serverPort) then
            return
        end
        route = { host = "127.0.0.1", port = BRIDGE_PORT, helloPort = 0 }
    end
    module.connect({ t = "create" })
end

--- Join a friend's room: their address plus the room code. Non-local
--- addresses automatically go through the client bridge (no port
--- forwarding needed on this machine).
--- @param roomCode string
function module.joinGame(roomCode)
    local target = (module.config.joinHost or ""):gsub("%s", "")
    serverEndpoint = { host = target ~= "" and target or module.config.serverHost,
                       port = module.config.serverPort }
    if target == "" or isLocalAddress(target) then
        -- same machine / LAN testing: connect directly
        route = {
            host = target ~= "" and target or module.config.serverHost,
            port = module.config.serverPort,
            helloPort = module.config.listenPort,
        }
    else
        if not module.launchBridge(target, module.config.serverPort) then
            return
        end
        route = { host = "127.0.0.1", port = BRIDGE_PORT, helloPort = 0 }
    end
    module.room = roomCode:upper():gsub("%s", "")
    module.connect({ t = "join" })
end

--- Point this session at the public matchmaking server. It's a remote host, so
--- traffic goes through the bridge (like joining a friend) — no inbound port
--- forward needed on this machine.
--- @return boolean # false when the bridge could not start (no Python)
local function routeToPublic()
    serverEndpoint = { host = PUBLIC_HOST, port = PUBLIC_PORT }
    if isLocalAddress(PUBLIC_HOST) then
        route = { host = PUBLIC_HOST, port = PUBLIC_PORT, helloPort = module.config.listenPort }
        return true
    end
    if not module.launchBridge(PUBLIC_HOST, PUBLIC_PORT) then
        return false
    end
    route = { host = "127.0.0.1", port = BRIDGE_PORT, helloPort = 0 }
    return true
end

--- Matchmaking: connect to the public server and ask for an open room with our
--- exact mod list — it drops us into a waiting one or opens a fresh public room
--- if there are none. The match is on our mod fingerprint (modv), so we don't
--- name a mod. No room code needed: the `joined` reply carries it, so from
--- there the flow is identical to a normal join.
--- @param mode string? # nil/"new" = find OR open an unstarted lobby (Start New
---   Game); "find" = find an unstarted lobby but do NOT open one — errors
---   `no_unstarted_game` if none (the Start Queue probe); "started" = drop into a
---   game already in progress (late-join).
function module.matchmake(mode)
    if not routeToPublic() then
        return -- no Python for the bridge; requirePython has already said so
    end
    module.room = nil -- the server assigns/creates the room and returns its code
    local hello = { t = "matchmake" }
    if mode == "started" then
        hello.started = 1
    elseif mode == "find" then
        hello.find = 1
    end
    module.connect(hello)
end

--- Host a room on the public server — no need to run your own. The room is
--- PRIVATE (code-only) just like dedicated hosting: matchmaking never hands it
--- out. Share the code with friends, who join via Join -> Friend -> Official.
function module.hostOfficial()
    if not routeToPublic() then
        return
    end
    module.room = nil
    module.connect({ t = "create" })
end

--- Join a friend's room on the public server by code alone — the server
--- address is known (the official one), so no IP to type. Works for a room
--- your friend opened via HOST -> Official server (public) as well as any
--- matchmaking room whose code they shared.
--- @param roomCode string
function module.joinOfficial(roomCode)
    if not routeToPublic() then
        return
    end
    module.room = roomCode:upper():gsub("%s", "")
    module.connect({ t = "join" })
end

--- @param helloMsg table
function module.connect(helloMsg)
    if not openSocket() then
        module.phase = PHASE.ERROR
        return
    end
    cid = cid or newCid()
    resetChannel()
    module.lastError = nil
    module.lastErrorCode = nil
    -- initial guess (the server's lobby broadcast confirms it): only matchmaking
    -- opens/joins a public room; hosting and joining-by-code are private.
    module.roomPublic = (helloMsg.t == "matchmake")
    module.phase = PHASE.CONNECTING
    module.refreshSteamName() -- use the current Steam persona name for this run
    helloMsg.name = module.config.playerName
    -- helloPort 0 tells the server to reply to the observed source address
    -- (the bridge's NAT mapping) instead of pushing to a forwarded port; a
    -- direct route declares the port we ACTUALLY bound (openSocket ran above),
    -- which may differ from config if another instance took the default.
    local r = route or defaultRoute()
    helloMsg.port = (r.helloPort == 0) and 0 or (boundPort or module.config.listenPort)
    helloMsg.mod = meta.name
    helloMsg.modv = meta.version .. " + " .. loadOrderSignature()
    helloMsg.pv = PROTOCOL_VERSION
    lastRxMs = nowMs()
    -- the hello is resent while CONNECTING: it covers a lost datagram AND
    -- the boot time of an auto-launched local server
    pendingHello = helloMsg
    helloSentMs = nowMs()
    connectStartMs = nowMs()
    sendToServer(helloMsg)
    module.saveConfig()
end

--- @param ready boolean
--- @param char integer? # chosen character (ENT_TYPE), shown to everyone at run start
--- Announce readiness. `dest` is the camp door being stood at as {world, level,
--- theme} (nil = the main door / a normal 1-1 start); the server stores it, the
--- lobby list shows it, and everyone must agree on it before a public run starts.
--- @param ready boolean
--- @param char integer?
--- @param dest integer[]?
function module.setReady(ready, char, dest)
    sendToServer({ t = "ready", ready = ready, char = char, dest = dest })
end

--- Host only: ask the server to start the run for everyone.
--- Ask the server to start the run. `dest` is the camp door it starts from as
--- {world, level, theme} (nil = main door / 1-1); the server remembers it on the
--- room so an instant restart returns to the same shortcut.
--- @param dest integer[]?
--- "129.213.14.228:26000 (v1.0.63)" — which server this session is actually on
--- and what it is running. In the desync-log header because a capture that does
--- not say WHICH server it used cannot be read: the same client symptom means
--- different things against an updated server and a stale one.
--- @return string
function module.serverDescribe()
    local ep = serverEndpoint
    local where = ep ~= nil and (ep.host .. ":" .. tostring(ep.port)) or "(not connected)"
    return where .. " (v" .. tostring(module.serverVersion or "unknown") .. ")"
end



function module.requestStart(dest)
    local msg = { t = "start", dest = dest }
    sendToServer(msg)
end

--- Host only: instant restart — the server re-rolls a seed and broadcasts a
--- fresh run_start to the whole party. The nonce deduplicates resends (the
--- caller repeats the request until run_start arrives, in case UDP eats one).
--- @param nonce string?
function module.requestRestart(nonce)
    sendToServer({ t = "restart", n = nonce })
end

--- The run host asks the server to fold a readied late-joiner into the run at
--- the party's CURRENT floor (a mid-run join): the server re-runs the roster at
--- this floor on the host's seed, so everyone keeps their progress.
--- @param floor { w: integer, l: integer, t: integer }
--- @param seed { [1]: integer, [2]: integer }
--- @param ord integer
--- @param stateSync table? # host's run/player snapshot (level_count etc.) so the
---   joiner generates the SAME world — without it they'd use level_count 0
function module.requestJoinFloor(floor, seed, ord, stateSync)
    -- theme goes in `th`, NOT `t` — `t` is the message type ("joinfloor")
    sendToServer({ t = "joinfloor", w = floor.w, l = floor.l, th = floor.t,
                   a = seed[1], b = seed[2], ord = ord, st = stateSync })
end

--- @param handoff boolean? # true = ask the server to keep the room open for the
---   players still in the run (End Adventure give-up): a private room hands its
---   host role to the next player instead of closing. Default closes a private
---   room when its host leaves, as before.
function module.leave(handoff)
    if module.phase ~= PHASE.IDLE then
        pcall(sendToServer, { t = "leave", ho = handoff and 1 or nil })
    end
    -- ...and the player's own save data, if they were borrowing the host's.
    -- Here rather than on a timer: leaving is the moment the loan ends, and a
    -- borrowed save left in place would be written to on the next launch.
    if SaveShare ~= nil and SaveShare.restoreOwn ~= nil then
        SafeCall("netCore:restoreOwnSave", SaveShare.restoreOwn)
    end
    module.phase = PHASE.IDLE
    module.room = nil
    module.slot = 0
    module.lobbyPlayers = {}
    module.playerNames = {}
    module.roomStarted = nil
    module.roomPublic = nil
    resetChannel()
    stopLaunchedProcesses()
    route = nil
    serverEndpoint = nil
end

--- The run ended but the party stays together: reopen the room on the
--- server and drop back into the same lobby to ready up for another run.
function module.backToLobby()
    if not module.isInRun() then
        return
    end
    sendToServer({ t = "reset" })
    module.phase = PHASE.LOBBY
    module.playerNames = {}
end

--- End MY adventure: I leave the run back to the lobby, but the OTHERS keep
--- playing (the server stands my slot still for them). The run is over for
--- everyone only once all players have ended. Unlike backToLobby this never
--- reopens the room out from under the players still in the run.
function module.endMyRun()
    if not module.isInRun() then
        return
    end
    sendToServer({ t = "endrun" })
    module.phase = PHASE.LOBBY
    module.playerNames = {}
end

--- Are we the lobby host (lowest occupied slot)?
--- @return boolean
function module.isHost()
    for _, player in ipairs(module.lobbyPlayers) do
        return player.slot == module.slot
    end
    return module.slot == 1
end

--- Is this a PUBLIC (matchmaking) room? Public lobbies ready up via the main
--- door and auto-start; private lobbies auto-ready and the host starts.
--- @return boolean
function module.isPublicRoom()
    return module.roomPublic == true
end

-- -------------------------------------------------------------- inbound

local function applyReadyEvents()
    while bufferedIn[appliedSeq + 1] ~= nil do
        local event = bufferedIn[appliedSeq + 1]
        bufferedIn[appliedSeq + 1] = nil
        appliedSeq = appliedSeq + 1
        local handler = eventHandlers[event.k]
        if handler ~= nil then
            SafeCall("netCore:event." .. tostring(event.k), handler, event.p, event.slot or 0)
        else
            dbgf("no handler for event kind %s", tostring(event.k))
        end
    end
    -- A GAP HERE STOPS THE WHOLE CHANNEL. Events are applied strictly in order, so
    -- one we never received holds back every later one indefinitely, and nothing
    -- about that is visible from the game: the unreliable state channel keeps
    -- flowing, so play continues perfectly while every world event is silently
    -- ignored (this is what made instant restart do nothing -- the vote came back
    -- and landed in this buffer). The server re-sends until we ack, so this
    -- resolves itself; say so anyway, because a gap that does NOT resolve is
    -- otherwise indistinguishable from nothing having been sent at all.
    if next(bufferedIn) ~= nil and DesyncLog ~= nil then
        if gapSinceMs == 0 then
            gapSinceMs = nowMs()
        elseif nowMs() - gapSinceMs >= 2000 and nowMs() >= gapNoticeMs then
            gapNoticeMs = nowMs() + 5000
            local held, lowest = 0, nil
            for seq in pairs(bufferedIn) do
                held = held + 1
                if lowest == nil or seq < lowest then lowest = seq end
            end
            DesyncLog.event(
                "inbound events STALLED %.1fs: waiting on event %d, %d later one(s) held back"
                .. " (every world event is on hold until it arrives)",
                (nowMs() - gapSinceMs) / 1000, appliedSeq + 1, held)
        end
    else
        gapSinceMs = 0
    end
    sendToServer({ t = "ack", seq = appliedSeq })
end

--- @param msg table
local function handleMessage(msg)
    lastRxMs = nowMs()
    local msgType = msg.t
    rxSeen[tostring(msgType)] = (rxSeen[tostring(msgType)] or 0) + 1
    if msgType == "event" then
        local seq = math.floor(tonumber(msg.seq) or 0)
        if seq <= appliedSeq then
            sendToServer({ t = "ack", seq = appliedSeq }) -- our previous ack was lost
        else
            bufferedIn[seq] = msg
            applyReadyEvents()
        end
    elseif msgType == "state" then
        if stateHandler ~= nil and msg.slot ~= module.slot then
            SafeCall("netCore:stateHandler", stateHandler, msg.slot, msg.d)
        end
    elseif msgType == "world" then
        if worldHandler ~= nil and msg.slot ~= module.slot then
            SafeCall("netCore:worldHandler", worldHandler, msg.slot, msg.d)
        end
    elseif msgType == "event_ack" then
        pendingOut[math.floor(tonumber(msg.cseq) or 0)] = nil
    elseif msgType == "joined" then
        module.room = msg.room
        module.slot = math.floor(tonumber(msg.slot) or 0)
        pendingHello = nil
        -- late-join baseline: when dropping into a game already in progress the
        -- server starts our reliable channel at `base` so we don't replay the
        -- whole run's event backlog. Adopt it (once, on the initial join) and
        -- drain anything that arrived ahead of this reply.
        local base = math.floor(tonumber(msg.base) or 0)
        if base > appliedSeq then
            appliedSeq = base
            applyReadyEvents()
        end
        if module.phase == PHASE.CONNECTING then
            module.phase = PHASE.LOBBY
        end
        -- WHICH SERVER ARE WE ACTUALLY TALKING TO? Half of this mod runs in a
        -- separate process, and hosting on a REMOTE server (the official one, or
        -- a friend's) means that half is whatever is deployed there — not what
        -- you just updated. Every server-side fix is then simply missing, and it
        -- surfaces as a client-side mystery. Say so plainly instead: a stale
        -- server is otherwise indistinguishable from a bug in the game.
        module.serverVersion = type(msg.srv) == "string" and msg.srv or nil
        if module.serverVersion ~= EXPECTED_SERVER_VERSION and not serverVersionWarned then
            serverVersionWarned = true
            local shown = module.serverVersion or "older than 1.0.63"
            errorf("server is running %s but this mod needs server %s — server-side fixes are NOT active",
                shown, EXPECTED_SERVER_VERSION)
            toast(string.format("Server is v%s, needs v%s — update the server",
                shown, EXPECTED_SERVER_VERSION))
            if DesyncLog ~= nil then
                DesyncLog.event("SERVER VERSION MISMATCH: server %s vs mod %s (server-side fixes absent)",
                    shown, meta.version)
            end
        end
        -- testing on your own: now that the room code exists, put a second
        -- player in it (no-op unless the option is on; idempotent per room)
        -- explicit > 0: this is a COUNT now, and 0 is truthy in Lua
        if (tonumber(module.config.testPlayer) or 0) > 0 then
            module.launchTestPlayer()
        end
    elseif msgType == "lobby" then
        module.lobbyPlayers = msg.players or {}
        if msg.started ~= nil then
            module.roomStarted = msg.started and true or false
        end
        if msg.public ~= nil then -- authoritative: overrides the connect-time guess
            module.roomPublic = msg.public and true or false
        end
    elseif msgType == "pong" then
        local sentAt = tonumber(msg.at)
        if sentAt ~= nil then
            local rtt = math.floor(nowMs() - sentAt)
            -- Keep the previous value rather than believe a stalled measurement:
            -- reporting nothing new is far better than telling the server this
            -- link is a second slow when it is not.
            if pingStalled or rtt > STALL_MS then
                module.pingStale = true
            else
                module.pingMs = rtt
                module.pingStale = false
            end
        end
    elseif msgType == "error" then
        pendingHello = nil
        module.lastErrorCode = tostring(msg.err) -- raw code, for the menu's flow logic
        module.lastError = tostring(msg.err)
        if msg.err == "mod_mismatch" then
            -- Say WHAT differs, not just THAT something does. Both signatures are
            -- structured per pack, so this is a real diff (see describeModMismatch);
            -- the full lines go to the log because the menu only shows one.
            local short, detail = "Mods don't match the room", nil
            pcall(function()
                short, detail = module.describeModMismatch(tostring(msg.modv))
            end)
            module.lastError = short
            errorf("MODS DON'T MATCH THE ROOM:")
            if detail ~= nil then
                for _, line in ipairs(detail) do
                    errorf("  %s", line)
                end
            end
            errorf("  (yours: %s + %s)", meta.version, loadOrderSignature())
        elseif msg.err == "no_such_room" then
            module.lastError = "No room with that code on this server"
        elseif msg.err == "room_full" then
            module.lastError = "That room is full"
        elseif msg.err == "already_started" then
            module.lastError = "That run already started"
        elseif msg.err == "no_started_game" then
            module.lastError = "No games in progress to join right now"
        elseif msg.err == "host_left" then
            module.lastError = "The host closed the room"
        end
        if module.phase == PHASE.CONNECTING then
            module.phase = PHASE.IDLE
        end
        errorf("server error: %s", module.lastError)
        if msg.err == "host_left" and module.isActive() then
            -- the session is gone: leave cleanly (this also closes the
            -- auto-launched bridge); eventSync notices and cleans up the run
            module.leave()
        end
    end
end

-- -------------------------------------------------------------- tick

--- Runs every GUI frame (menus included): drains the receive queue, resends
--- unacknowledged events, heartbeats, and detects a dead server.
--- What has arrived from the wire, by message type, since the session began.
---
--- Exposed so the input stall can report it. A stall says "the other player's input
--- for this frame is missing"; only this says whether ANY packet is still arriving,
--- which is the difference between a transport that has stopped and a packet that is
--- arriving and being discarded.
--- @return table<string, integer>
function module.rxCounts()
    local out = {}
    for kind, count in pairs(rxSeen) do
        out[tostring(kind)] = count
    end
    return out
end

--- Is the reliable channel delivering anything at all?
---
--- This lives HERE, in the per-frame tick, and that placement is the entire point.
--- It was first written inside applyReadyEvents, which handleMessage only calls when
--- an event ARRIVES -- so a channel delivering nothing never reached the check meant
--- to notice that. The gap notice in applyReadyEvents has the same shape of blind
--- spot: it keys off a non-empty buffer, so it sees an event arriving out of order
--- and stays quiet when none arrive.
---
--- The message-type tally is the useful half. It says whether `event` messages reach
--- this client at all, which separates a server that is not relaying from a client
--- that is not dispatching -- one line instead of another whole session.
local function reportChannelSilence()
    if appliedSeq ~= lastAppliedSeen then
        lastAppliedSeen = appliedSeq
        lastAppliedMs = nowMs()
        return
    end
    if lastAppliedMs == 0 then
        lastAppliedMs = nowMs()
        return
    end
    -- 4s, not 10s: the last capture ended six seconds into a freeze, before the
    -- notice could fire. A diagnostic that needs more patience than the person
    -- watching the frozen screen is not a diagnostic.
    if not module.isInRun() or nowMs() - lastAppliedMs < 4000 then
        return
    end
    if nowMs() < silentNoticeMs or DesyncLog == nil or DesyncLog.event == nil then
        return
    end
    silentNoticeMs = nowMs() + 10000
    local types = {}
    for kind, count in pairs(rxSeen) do
        types[#types + 1] = string.format("%s=%d", tostring(kind), count)
    end
    table.sort(types)
    local held = 0
    for _ in pairs(bufferedIn) do
        held = held + 1
    end
    DesyncLog.event(
        "inbound events SILENT %.0fs: applied to %d, %d buffered, next cseq out %d."
        .. " Received: %s",
        (nowMs() - lastAppliedMs) / 1000, appliedSeq, held, nextCseq,
        #types > 0 and table.concat(types, " ") or "NOTHING AT ALL")
end

local function tick()
    if module.phase == PHASE.IDLE or module.phase == PHASE.ERROR then
        if #rxQueue > 0 then
            rxQueue = {}
        end
        return
    end
    -- swap the queue first so the udp callback can keep appending while we work
    local batch = rxQueue
    rxQueue = {}
    for _, raw in ipairs(batch) do
        local msg = NetJson.decode(raw)
        if type(msg) == "table" then
            SafeCall("netCore:handleMessage", handleMessage, msg)
        end
    end

    local now = nowMs()
    reportChannelSilence()
    -- Gap since the previous tick. The frame loop runs every ~16 ms, so anything
    -- past STALL_MS means we were not running: a level load, an alt-tab, a hitch.
    if lastTickMs > 0 and now - lastTickMs > STALL_MS then
        pingStalled = true
    end
    lastTickMs = now
    if module.phase == PHASE.CONNECTING and pendingHello ~= nil then
        if now - connectStartMs > CONNECT_TIMEOUT_MS then
            pendingHello = nil
            module.lastError = "Could not reach the server"
            module.phase = PHASE.IDLE
        elseif now - helloSentMs >= HELLO_RETRY_MS then
            helloSentMs = now
            sendToServer(pendingHello)
        end
    end
    -- ASCENDING cseq, never pairs(): the server takes our reliable events in
    -- strict order and will not apply one that leaves a gap, so sending them in
    -- Lua's hash order routinely put the later one on the wire first and made the
    -- server wait (and us re-send) for no reason. Sorted, the common case needs
    -- no recovery at all -- and if the wire reorders them anyway, the server now
    -- declines to ack the gapped one so it is re-sent rather than lost.
    -- `next` first: in the steady state nothing is pending, and this used to
    -- allocate a table and run a sort every GUI frame -- i.e. at display rate -- to
    -- find that out. The ascending-cseq order inside is untouched; the server
    -- stalls if resends arrive in hash order.
    if next(pendingOut) ~= nil then
        local waiting = {}
        for cseq in pairs(pendingOut) do
            waiting[#waiting + 1] = cseq
        end
        -- The reliable stream's depth, said out loud on a slow cadence. An event
        -- that is never acknowledged sits here forever and every event behind it
        -- waits, which is invisible from the outside: the symptom is a peer
        -- reporting a MISSING event while the sender believes it was sent. If this
        -- number climbs and never falls, that is the answer.
        -- No notice here. This queue drains normally even when the channel is
        -- broken -- it only proves the SERVER acknowledged us, which it does. The
        -- half that stalls is inbound, and it is watched below.
        table.sort(waiting)
        for _, cseq in ipairs(waiting) do
            local pending = pendingOut[cseq]
            if pending ~= nil and now - pending.sentAt >= RESEND_MS then
                pending.sentAt = now
                sendToServer(pending.msg)
            end
        end
    end
    if now - lastPingMs >= HEARTBEAT_MS then
        lastPingMs = now
        pingStalled = false -- fresh window: judge the reply on its own merits
        -- report our latest measured round-trip so the server can size the
        -- run's lockstep input delay to the lobby's worst connection
        sendToServer({ t = "ping", at = now, ping = module.pingMs })
    end
    -- A screen change is pending or a fade is in flight: the heavy, callback-free
    -- part is about to start, so warn the server now — afterwards we cannot.
    -- Throttled, and sent from here (a GUI-frame tick) so it goes out on the last
    -- frame that still runs rather than from inside the stall.
    if module.isInRun() and now - lastLoadingNoticeMs >= LOADING_NOTICE_MS then
        local pending = false
        pcall(function()
            local st = get_local_state()
            pending = st.loading ~= FADE.NONE or st.screen_next ~= st.screen
        end)
        if pending then
            lastLoadingNoticeMs = now
            module.sendLoadingNotice()
        end
    end
    if module.isActive() and now - lastRxMs > TIMEOUT_MS then
        module.lastError = "Connection to server lost"
        errorf("server timed out")
        module.leave()
        module.phase = PHASE.ERROR
    end
end

-- Global infrastructure callback: registered once for the whole game session,
-- never cleared on level transitions.
set_callback(function()
    if DesyncLog ~= nil then
        DesyncLog.frameMark("guiframe:netCore")
    end
    SafeCall("netCore:tick", tick)
    guiFrameSeenMs = nowMs()
    if DesyncLog ~= nil then
        DesyncLog.frameDone("guiframe:netCore")
    end
end, ON.GUIFRAME)

-- ...and again on PRE_UPDATE, because GUI frames are not guaranteed to keep coming.
--
-- Hosting a content mod puts its callbacks and ours in ONE Playlunky script, and the
-- mod tears its own hooks down on every floor. Something in that teardown takes our
-- GUIFRAME callbacks with it, and when it does, this tick stops -- so nothing drains
-- the receive queue. A capture shows exactly that: both machines frozen at the same
-- frame with every rx counter, `pong` included, unchanged for 54 seconds, on a host
-- whose server is on 127.0.0.1 where a packet cannot be lost. The `.. alive`
-- heartbeat (GUIFRAME) stops at the same instant the STALL lines (PRE_UPDATE) keep
-- printing, which is what named the difference.
--
-- Rather than depend on winning that fight, pump the network from both. PRE_UPDATE
-- survives, and `tick` is safe to call twice in a frame: the queue drain is
-- idempotent and every send inside it is already gated on elapsed time.
--
-- This does not repair the callback loss -- see the watchdog below, which says when
-- it happens -- it stops the loss from taking the connection down with it.
set_callback(function()
    -- Only when the GUI frame tick is NOT keeping up.
    --
    -- This exists because a hosted mod's teardown can take our GUIFRAME callback
    -- away, and then nothing drains the receive queue. That is worth guarding, but
    -- it does not mean doing the work twice on every frame of a healthy session --
    -- and a healthy session is nearly all of them.
    if nowMs() - guiFrameSeenMs < 100 then
        return
    end
    SafeCall("netCore:tick", tick)
end, ON.PRE_UPDATE)

--- Report when THIS module's GUI callback stops running.
---
--- The first version of this said "GUI FRAMES STOPPED", which the next capture
--- disproved: inputSync's own GUIFRAME callback kept firing its heartbeat throughout,
--- so GUI frames were arriving fine. What had been destroyed was a SUBSET of our
--- callbacks -- this one, the lockstep gate and the floor digest -- by a hosted mod's
--- bare `clear_callback()`. See src/callbacks.lua, which now refuses those and
--- revives anything that slips past. This stays as the report that it happened.
set_callback(function()
    if guiFrameSeenMs == 0 then
        guiFrameSeenMs = nowMs()
        return
    end
    local gap = nowMs() - guiFrameSeenMs
    if gap < 2000 or nowMs() < guiFrameNoticeMs then
        return
    end
    guiFrameNoticeMs = nowMs() + 5000
    if DesyncLog ~= nil and DesyncLog.event ~= nil then
        DesyncLog.event(
            "netCore's GUI callback has not run for %.0fs while the sim is still"
            .. " running -- a hosted mod's teardown cleared it. Callbacks revives it"
            .. " within %ds and the network is pumped from PRE_UPDATE meanwhile.",
            gap / 1000, 5)
    end
end, ON.PRE_UPDATE)

module.loadConfig()

Network = module
return module
