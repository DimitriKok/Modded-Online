--- Modded Online — desync diagnostic logger (writes a plain-text timeline).
---
--- Writes to  Mods/Packs/Modded Online/desync_log.txt  on EVERY machine. Every
--- line is stamped with the shared SIM clock `seq:offset` (the lockstep frame
--- counter), which is IDENTICAL on all peers — the wall clock is not (pings
--- differ). So the two machines' logs align exactly on `seq:offset`.
---
--- The point: when a floor generates differently, each machine dumps its full
--- sorted entity list + the run-state that drives generation, for that floor.
--- Collect BOTH machines' desync_log.txt, diff them, and the first differing
--- entity or state field is the ORIGIN of the divergence. Entity uids are NEVER
--- logged (they differ per machine and would create false diffs) — only type +
--- rounded position + layer, sorted deterministically so the two files line up.
---
--- Nothing here touches the simulation. Disable with `MO_LOG = false`.

local module = {}

local PRIMARY_PATH = PackPath("desync_log.txt")
local FALLBACK_PATH = "modded_online_desync_log.txt"

local logPath = nil     -- the path we actually opened (nil = logging off/failed)
--- Lines raised before any run session opened the file, held until one does.
--- See module.earlyEvent for why this has to exist.
local early = {}
local EARLY_MAX = 60    -- a player who never starts a run must not accumulate forever
local everInit = false  -- first run of a game launch truncates; later runs append
local entNameById = nil -- lazy reverse map of ENT_TYPE: id -> "NAME"

-- the SAME mask the world digest fingerprints (inputSync WORLD_HASH_MASKS), so the
-- dump always explains the digest — MOUNT and PLAYER included, or a divergent mount
-- / a duplicated player entity would be missing from the very dump meant to find it
local DUMP_MASKS = MASK.FLOOR | MASK.ACTIVEFLOOR | MASK.MONSTER | MASK.ITEM
    | MASK.MOUNT | MASK.PLAYER

--- Master switch. Default ON so the first desync is captured; set `MO_LOG=false`
--- in the console to silence it.
if MO_LOG == nil then MO_LOG = true end

--- Wall-clock stamp (best effort — `os` may be sandboxed; fall back to ms).
---
--- Cached for the current engine frame. This is called once per log line and
--- TWICE per traced callback, so with the frame trace on it ran ~26 times a frame
--- — 26 closure allocations and 26 `os.date` calls for 26 copies of the same
--- second. `pcall(os.date, fmt)` rather than `pcall(function() ... end)`: same
--- guard, no closure. The value is identical within a frame, so nothing about the
--- output changes.
local stampFrame = -1
local stampText = "--:--:--"
local function nowStamp()
    -- pcall(get_frame), never pcall(function() ... end): a closure that captures a
    -- local is allocated fresh on every call, which is the cost being removed here
    local ok, frame = pcall(get_frame)
    if not ok then
        frame = -1
    end
    if frame == stampFrame then
        return stampText
    end
    stampFrame = frame
    local ok, text = pcall(os.date, "%H:%M:%S")
    if ok and type(text) == "string" then
        stampText = text
    else
        stampText = tostring(math.floor(get_ms()))
    end
    return stampText
end

--- The shared lockstep clock `seq:offset` — the anchor that aligns two logs.
--- Cached per engine frame for the same reason as nowStamp: the lockstep clock
--- cannot advance twice inside one frame, so recomputing it per traced callback
--- only burned pcalls and string.format.
local clockFrame = -1
local clockText = "-:-"
local function simClock()
    local ok, frame = pcall(get_frame)
    if not ok then
        frame = -1
    end
    if frame == clockFrame then
        return clockText
    end
    clockFrame = frame
    clockText = "-:-"
    if InputSync ~= nil and InputSync.simClock ~= nil then
        local ok, s = pcall(InputSync.simClock)
        if ok and type(s) == "string" then
            clockText = s
        end
    end
    return clockText
end

--- Look up an entity type name from its id (built once, lazily).
local function entName(id)
    if entNameById == nil then
        entNameById = {}
        pcall(function()
            for name, v in pairs(ENT_TYPE) do
                if type(v) == "number" then
                    entNameById[v] = name
                end
            end
        end)
    end
    return entNameById[id] or ("ID_" .. tostring(id))
end

--- Append one already-formatted line, stamped with wall clock + sim clock.
---
--- The handle is kept OPEN and flushed after each line, rather than
--- opened/written/closed per line. The crash guarantee is what it was — every
--- line is on the OS's side of the fence the moment it is written, so the tail of
--- the log still records the last thing that happened before a native crash — but
--- an append-open is a directory lookup plus a metadata write, and this dropped
--- that per line for the cost of holding one descriptor. `fopen` on Windows
--- shares reads, so the file can still be copied while the game runs.
local writeHandle = nil
local function write(text)
    if not MO_LOG or logPath == nil then
        return
    end
    pcall(function()
        if writeHandle == nil then
            writeHandle = io.open(logPath, "a")
            if writeHandle == nil then
                return
            end
        end
        writeHandle:write("[", nowStamp(), " ", simClock(), "] ", text, "\n")
        writeHandle:flush()
    end)
end

--- Append text that already carries its own stamps (the per-floor block builds
--- them into its first line, so `write`'s prefix would duplicate them). Same
--- kept-open handle as `write`, so a floor block no longer costs an open/close
--- of its own on top of everything else it does.
--- @param text string
local function writeRaw(text)
    if not MO_LOG or logPath == nil then
        return
    end
    pcall(function()
        if writeHandle == nil then
            writeHandle = io.open(logPath, "a")
            if writeHandle == nil then
                return
            end
        end
        writeHandle:write(text, "\n")
        writeHandle:flush()
    end)
end

--- Drop the append handle so the next `write` reopens `logPath`. Called when the
--- log is (re)opened, which is the only thing that can move the path.
local function writeReset()
    pcall(function()
        if writeHandle ~= nil then
            writeHandle:close()
        end
    end)
    writeHandle = nil
end

-- ------------------------------------------------------------ crash breadcrumbs
--
-- A native crash kills the process with no Lua error to catch, so the only
-- evidence is what already reached disk. `write` opens/appends/closes per line,
-- so EVERY line here is flushed the moment it is written — the tail of the log is
-- therefore a faithful record of the last thing that happened.
--
-- The scheme: our riskiest operations (the ones that reach into engine internals
-- — level-seed/roster enforcement, warps, the entity sweep, coffin hooks, shim
-- injection) are bracketed with `>> name` on entry and `<< name` on exit, and a
-- periodic `.. alive` heartbeat runs otherwise. That makes the two cases
-- distinguishable after the fact:
--
--   * last line is an UNMATCHED `>> name`  -> the process died INSIDE Modded
--     Online, in `name`. That one is ours.
--   * last line is `<< ...`, `.. alive`, or anything else -> Modded Online was
--     NOT executing. A crash there belongs to another mod or the engine.
--
-- Only coarse, per-floor operations are bracketed; per-frame callbacks are not,
-- because a file write per frame would cost more than it is worth. So a crash
-- inside our per-frame code reads as "not ours" — the heartbeat's timestamp is
-- what bounds how long ago we last ran.
local HEARTBEAT_MS = 10000
local lastHeartbeatMs = 0

--- Enter a risky operation. Pair with `leave` (use `guard` to be sure).
--- @param name string
function module.enter(name)
    write(">> " .. tostring(name))
end

--- Leave a risky operation.
--- @param name string
function module.leave(name)
    write("<< " .. tostring(name))
end

-- ------------------------------------------------- opt-in per-FRAME attribution
--
-- The breadcrumbs above only bracket per-FLOOR work, so a crash inside our
-- per-frame callbacks (the lockstep gate, camera tick, HUD/GUI work) reads as
-- "idle" — indistinguishable from a crash in another mod. Closing that gap needs
-- a marker written every frame, which is a file write per frame: far too costly
-- to leave on for everyone.
--
-- So it is OPT-IN and OFF by default. It is enabled by DROPPING A FILE, not from
-- the console: each Playlunky pack runs in its OWN Lua VM, and the in-game
-- console executes in a DIFFERENT state, so `MO_TRACE = true` typed there never
-- reached this global (the first attempt to use it produced no file at all).
-- A file has no such problem — every VM can see the disk. The crashing player
-- creates an empty file named `mo_trace.on` in this pack's folder (next to
-- config.json), relaunches, reproduces the crash, and sends `crash_frame.txt`.
-- Unlike the desync log that file is OVERWRITTEN (mode "w") every frame, so it
-- stays one line long no matter how long the session runs.
--
-- The MO_TRACE global is still honoured as an override, for the rare setup where
-- the console does share our state.
--
-- Each callback writes `IN <name>` on entry and `OUT <name>` on exit, so the
-- verdict is order-independent — which matters, because our per-frame callbacks
-- are spread over five modules and run in require order, so no single one of
-- them is reliably "last in the frame":
--
--   crash_frame.txt says `IN  guiframe:guiTick`  -> died INSIDE that callback
--   crash_frame.txt says `OUT guiframe:guiTick`  -> that one finished; not ours
local TRACE_PATH = PackPath("crash_frame.txt")
local TRACE_FLAG_PATH = PackPath("mo_trace.on")
-- Master off-switch, by file, to test whether OUR logging is behind a crash.
-- Drop an empty `mo_log.off` in the pack folder and Modded Online writes NOTHING
-- to disk for the session — no desync log, no breadcrumbs, no heartbeat, no
-- frame trace. If a crash still happens with this present, our file I/O is not
-- the cause. (The console can't toggle MO_LOG: each pack is a separate Lua VM.)
local LOG_OFF_FLAG_PATH = PackPath("mo_log.off")
-- Opt-in for the FULL per-floor entity list (see module.floorSnapshot). Off by
-- default: it is ~4000 lines and ~190 KB per floor, 99% of the log, and it is only
-- of use when two machines' captures are actually being diffed.
local DUMP_FLAG_PATH = PackPath("mo_dump.on")
local dumpFileOn = false

--- @return boolean # whether to write the full sorted entity list per floor
local function dumpActive()
    return MO_DUMP == true or dumpFileOn
end
if MO_TRACE == nil then MO_TRACE = false end

--- Whether per-frame tracing is on. Checked once, when the log is opened for a
--- run (init), and cached — probing the disk every frame would defeat the point.
--- So the flag file must exist BEFORE the run starts (i.e. create it, then play).
local traceFileOn = false
-- The trace file is opened ONCE and kept open for the session. The first version
-- did a full io.open(mode="w")/write/close on EVERY mark and done — ~20 file
-- CREATIONS per frame (mode "w" truncates, a filesystem metadata write each
-- time), which made the game crawl AND, by slowing the frame loop, hid the very
-- crash the trace was meant to catch. A single kept-open handle turns each mark
-- into a seek+write+flush (a couple of syscalls, no metadata), which is cheap
-- enough that it barely perturbs timing.
local traceHandle = nil
-- Every record is padded to this width so overwriting from offset 0 fully
-- covers a longer previous line (no leftover tail). The file stays one line.
local TRACE_WIDTH = 180

--- @return boolean
local function traceActive()
    return MO_TRACE == true or traceFileOn
end

--- Open the crash-trace file once (idempotent). "w+" truncates any stale file
--- from a previous session — the previous marker is read before this runs.
local function traceOpen()
    if traceHandle ~= nil then
        return
    end
    pcall(function()
        traceHandle = io.open(TRACE_PATH, "w+")
    end)
end

--- @param prefix string
--- @param name string
-- Built ONCE. This was `string.rep(" ", TRACE_WIDTH - #line)` per mark, i.e. an
-- allocation for every traced callback on every frame.
local TRACE_PAD = string.rep(" ", TRACE_WIDTH)

--- The body, lifted out of the `pcall(function() ... end)` it used to sit in. That
--- closure captured `prefix` and `name`, so Lua allocated a new one per mark --
--- ~26 a frame, and the GUIFRAME ones run at DISPLAY rate, uncapped on borderless.
--- @param prefix string
--- @param name string
local function traceWriteBody(prefix, name)
    local line = string.format("%s %s | sim %s | %s",
        prefix, tostring(name), simClock(), nowStamp())
    if #line >= TRACE_WIDTH then
        line = line:sub(1, TRACE_WIDTH)
    else
        line = line .. TRACE_PAD:sub(1, TRACE_WIDTH - #line)
    end
    traceHandle:seek("set", 0)
    -- two arguments rather than `line .. "\n"`: the concat was a second string per mark
    traceHandle:write(line, "\n")
    -- Still flushed. Lua's write goes into a userspace stdio buffer, and a native
    -- crash takes the process down with that buffer unwritten -- which would leave
    -- exactly the evidence this file exists to preserve on the floor.
    traceHandle:flush()
end

local function traceWrite(prefix, name)
    if traceHandle == nil then
        return
    end
    pcall(traceWriteBody, prefix, name)
end

--- One of our per-frame callbacks is STARTING. No-op unless tracing is active.
--- @param name string
function module.frameMark(name)
    if not traceActive() then
        return
    end
    if traceHandle == nil then
        traceOpen() -- covers MO_TRACE set from the console AFTER init
    end
    traceWrite("IN ", name)
end

--- ...and it FINISHED without taking the process down.
--- @param name string
function module.frameDone(name)
    if not traceActive() then
        return
    end
    traceWrite("OUT", name)
end

--- What `crash_frame.txt` was left holding by the previous session, or nil when
--- tracing was off / the file is absent. Read once at init, then cleared so a
--- stale marker cannot be misread as this session's.
--- @return string?
local function previousFrameMark()
    local line = nil
    pcall(function()
        for l in io.lines(TRACE_PATH) do
            local trimmed = l:gsub("%s+$", "") -- records are space-padded
            if trimmed ~= "" then
                line = trimmed
            end
        end
    end)
    -- Not truncated here: traceOpen re-opens with "w+" which truncates anyway,
    -- and if tracing is OFF this session, leaving the marker lets it still be
    -- reported next launch rather than being silently erased.
    return line
end

--- Periodic "Modded Online is loaded and idle" mark. Cheap enough at one line
--- per HEARTBEAT_MS, and it is what proves we were NOT running when a crash
--- happened. Safe to call every frame.
function module.heartbeat()
    if not MO_LOG or logPath == nil then
        return
    end
    local now = get_ms()
    if now - lastHeartbeatMs < HEARTBEAT_MS then
        return
    end
    lastHeartbeatMs = now
    write(".. alive")
end

--- How did the PREVIOUS game session's log end? Must be read BEFORE this launch
--- truncates the file. Returns a verdict line, or nil when there is nothing to
--- report (no previous log, or it ended cleanly).
--- @return string?
local function previousSessionVerdict()
    local last, lastEnter, depth, sawAny = nil, nil, 0, false
    local ok = pcall(function()
        for line in io.lines(PRIMARY_PATH) do
            if line ~= "" then
                last = line
                local op = line:match("^%[[^%]]*%] >> (.+)$")
                if op ~= nil then
                    depth = depth + 1
                    lastEnter = op
                    sawAny = true
                elseif line:match("^%[[^%]]*%] << ") ~= nil then
                    depth = depth > 0 and depth - 1 or 0
                    sawAny = true
                elseif line:match("%.%. alive") ~= nil then
                    sawAny = true
                end
            end
        end
    end)
    if not ok or last == nil then
        return nil -- no readable previous log (first launch)
    end
    if not sawAny then
        -- No breadcrumbs anywhere in that log, so it predates them. Saying
        -- "Modded Online was idle" here would be an unearned verdict — the
        -- evidence simply is not in the file.
        return "*** PREVIOUS SESSION's log has no breadcrumbs (written before v1.0.3):"
            .. " a crash there cannot be attributed either way"
    end
    if depth > 0 and lastEnter ~= nil then
        return string.format(
            "*** PREVIOUS SESSION CRASHED INSIDE MODDED ONLINE, in: %s"
            .. "  (entered and never left -- this one is ours)", lastEnter)
    end
    if last:match("run end") ~= nil then
        return nil -- clean run end; whatever happened after was outside a run
    end
    return string.format(
        "*** PREVIOUS SESSION ENDED WITHOUT A CLEAN RUN END while Modded Online was"
        .. " IDLE -- a crash here is NOT ours (another mod or the engine). Last line: %s",
        last)
end

--- Public printf-style single line.
function module.line(fmt, ...)
    -- `logPath` as well as MO_LOG: the log is only opened once a session begins, so
    -- on the menu, in single player and in the lobby this used to run a pcall and a
    -- full string.format for a line that `write` then dropped on the floor.
    if not MO_LOG or logPath == nil then
        return
    end
    local ok, s = pcall(string.format, fmt, ...)
    write(ok and s or tostring(fmt))
end

--- Alias — a general timeline event (money reconcile, resync, join, ...).
function module.event(fmt, ...)
    module.line(fmt, ...)
end

--- An event that happens BEFORE a run session exists.
---
--- `line` drops everything while `logPath` is nil, and for the hot per-frame paths
--- that is right — on the menu there is nothing there worth a `string.format`. But
--- the save-share exchange runs ENTIRELY IN THE LOBBY: the host publishes, every
--- peer adopts, and a peer that backs out restores, all before any run has opened
--- the file. Every one of those lines has always gone in the bin.
---
--- That is why four rounds of fixes for one bug could each be, in the dev53
--- post-mortem's own words, "correct and invisible". The `saveshare=` header line
--- added to answer it is a snapshot taken at run start — it says what the pack holds
--- once a run begins, never what leaving the lobby actually did. Two captures from a
--- failing session contain the string "save share" exactly zero times, on both
--- machines, for this reason and not because nothing ran.
---
--- So: write it now if the file is open, and otherwise hold it until one opens.
--- Bounded, and stamped `lobby` because the seq:offset columns mean nothing there.
function module.earlyEvent(fmt, ...)
    if not MO_LOG then
        return
    end
    if logPath ~= nil then
        module.line(fmt, ...)
        return
    end
    local ok, s = pcall(string.format, fmt, ...)
    if #early >= EARLY_MAX then
        table.remove(early, 1)
    end
    early[#early + 1] = "[" .. nowStamp() .. " lobby] " .. (ok and s or tostring(fmt))
end

--- Open the log for a new run. Truncates on the first run of a game launch,
--- appends (with a banner) on later runs, so all runs of one launch are kept
--- but the file never grows across launches. Called from beginSession.
--- Does a file exist? (open-for-read probe; io.exists isn't available here.)
--- @param path string
--- @return boolean
local function fileExists(path)
    local found = false
    pcall(function()
        local probe = io.open(path, "r")
        if probe ~= nil then
            probe:close()
            found = true
        end
    end)
    return found
end

function module.init()
    if not MO_LOG then
        logPath = nil
        writeReset()
        return
    end
    -- Master off-switch for the "is our logging causing the crash?" test: no log,
    -- no breadcrumbs, no heartbeat, no trace this session (see LOG_OFF_FLAG_PATH).
    if fileExists(LOG_OFF_FLAG_PATH) then
        logPath = nil
        writeReset()
        traceFileOn = false
        dbg("Modded Online logging DISABLED by mo_log.off")
        return
    end
    logPath = nil
    -- the append handle belongs to the OLD path; make the next write reopen
    writeReset()
    local mode = everInit and "a" or "w"
    -- Detect the per-frame trace flag file (see traceActive). Checked here rather
    -- than every frame; a truthy result is cached for the session.
    traceFileOn = fileExists(TRACE_FLAG_PATH)
    dumpFileOn = fileExists(DUMP_FLAG_PATH)
    -- Read how the last session ended BEFORE the first run of this launch
    -- truncates the file, then report it in the new header. Only on the first
    -- run: later runs of the same launch append, and their own breadcrumbs are
    -- already in this file.
    local verdict = nil
    local frameMark = nil
    if not everInit then
        verdict = previousSessionVerdict()
        frameMark = previousFrameMark()
    end
    -- Open the trace handle now (after the previous marker was read, so "w+"
    -- doesn't truncate it first). Idempotent: a no-op on later runs.
    if traceActive() then
        traceOpen()
    end
    -- Roll the previous SESSION's log aside before "w" truncates it. A crash or a
    -- broken restart is always followed by a relaunch, and that relaunch was
    -- destroying the only record of what went wrong — several debugging rounds
    -- were lost to exactly that, chasing a session whose log no longer existed.
    -- One generation deep is enough, and it costs a single copy at startup.
    if not everInit then
        pcall(function()
            local src = io.open(PRIMARY_PATH, "r")
            if src == nil then
                return
            end
            local data = src:read("*a")
            src:close()
            if data == nil or #data == 0 then
                return
            end
            local dst = io.open(PackPath("desync_log.prev.txt"), "w")
            if dst == nil then
                return
            end
            dst:write(data)
            dst:close()
        end)
    end
    for _, p in ipairs({ PRIMARY_PATH, FALLBACK_PATH }) do
        local f = io.open(p, mode)
        if f ~= nil then
            logPath = p
            everInit = true
            pcall(function()
                local seedStr = "?"
                local a, b = get_adventure_seed(false)
                seedStr = string.format("%08X-%08X",
                    math.floor(a) & 0xFFFFFFFF, math.floor(b) & 0xFFFFFFFF)
                local host = "?"
                pcall(function()
                    host = tostring(Network.isWorldHost())
                end)
                f:write("\n=== Modded Online " .. tostring(meta and meta.version)
                    .. " — run start " .. nowStamp() .. " ===\n")
                f:write(string.format(
                    "slot=%s  worldHost=%s  room=%s  seed=%s\n",
                    tostring(Network and Network.slot), host,
                    tostring(Network and Network.room), seedStr))
                -- The LIVE injected shim version per content pack. An injected shim
                -- only takes effect on the NEXT launch, so two machines on the same
                -- mod version can still run DIFFERENT shims (one updated but did not
                -- restart) and diverge on every floor a mod rolls dice. Logging it
                -- makes that mismatch obvious instead of invisible.
                local shims = "?"
                pcall(function() shims = Network.shimVersions() end)
                f:write("shims=" .. tostring(shims) .. "\n")
                -- The exact string the server matches a room on. Two captures put
                -- side by side then show WHICH pack differs and in which field,
                -- instead of two digests that merely disagree.
                local mods = "?"
                pcall(function() mods = Network.modSignature() end)
                f:write("mods=" .. tostring(mods) .. "\n")
                -- Each pack's persisted OPTIONS hash. A mod whose level generator
                -- reads its own options (the HD mod's does) builds a DIFFERENT world
                -- from the same seed when the two players' settings differ, which
                -- otherwise looks like an unexplained generation desync.
                --
                -- Differing hashes mean the two machines' settings differ
                -- SOMEWHERE. That is not proof of a generation mismatch on its
                -- own: a hosted mod registers its options into OUR pack, next to
                -- the mod-picker checkboxes, and those legitimately differ
                -- between two players with different mods installed. Compare the
                -- option LISTS before blaming this.
                local opts = "?"
                pcall(function() opts = Network.packOptionHashes() end)
                f:write("packopts=" .. tostring(opts) .. "\n")
                -- The lockstep input delay this run is playing on. It is sized
                -- once, at run start, from the two worst pings in the room, so a
                -- single bad sample is felt by EVERYONE for the whole run -- and
                -- until now it appeared nowhere in the log, which made "it went
                -- laggy after X" impossible to confirm from a capture.
                local delayFrames = "?"
                pcall(function()
                    if InputSync ~= nil and InputSync.inputDelay ~= nil then
                        delayFrames = tostring(InputSync.inputDelay())
                    end
                end)
                f:write("inputdelay=" .. delayFrames .. " frames\n")
                -- Each pack's whole persisted save (progress: unlocks, achievements,
                -- tutorial flags). A mod that branches on its OWN progress builds a
                -- different world per machine — the HD mod's unlock system did — and
                -- some mods keep no "options" at all, so this covers what packopts
                -- cannot. Differing hashes = different mod progress.
                local saves = "?"
                pcall(function() saves = Network.packSaveHashes() end)
                f:write("packsave=" .. tostring(saves) .. "\n")
                -- Whose save data this session is playing on. A peer that
                -- kept the room host's progression after leaving showed up
                -- nowhere at all before this line existed.
                local share = "off"
                pcall(function()
                    if SaveShare ~= nil and SaveShare.status ~= nil then
                        share = SaveShare.status()
                    end
                end)
                f:write("saveshare=" .. share .. "\n")
                f:write("lines are [wallclock seq:offset]; align two machines' logs on seq:offset\n")
                f:write(">> name / << name bracket Modded Online's risky operations;"
                    .. " '.. alive' means loaded and idle (see crash breadcrumbs)\n")
                -- Confirms in the log itself whether per-frame tracing is armed,
                -- so we never again wonder why crash_frame.txt is empty.
                f:write("floordump=" .. (dumpActive()
                    and "ON (mo_dump.on present; ~190 KB per floor)"
                    or "off (create mo_dump.on for the full entity list)") .. "\n")
                -- say whether the profiler is on: a log with no PROFILE lines
                -- means either it is off or the session was too short, and those
                -- are different problems
                local profiling = "off (mo_profile.off is present, or get_ms is missing)"
                if Callbacks ~= nil and Callbacks.profiling ~= nil
                    and Callbacks.profiling() then
                    profiling = "ON (default; reports every 10s -- mo_profile.off disables)"
                end
                f:write("profile=" .. profiling .. "\n")
                f:write("frametrace=" .. (traceActive() and "ON" or "off")
                    .. (traceFileOn and " (mo_trace.on present)" or "") .. "\n")
                -- Whether the in-level layer doors were disabled this session, so
                -- a crash test (mo_nolayerdoors.on) is unambiguous in the capture.
                local layerDoors = "on"
                pcall(function()
                    if EventSync ~= nil and EventSync.layerDoorsDisabled then
                        layerDoors = "OFF (mo_nolayerdoors.on present)"
                    end
                end)
                f:write("layerdoors=" .. layerDoors .. "\n")
                -- Whether we are clearing up entities another mod parked outside
                -- the level and never destroyed (see pollSweepParked): with this
                -- off, a long boss fight ends in an engine-side crash, so a
                -- capture has to say which way it was running.
                local sweep = "on"
                pcall(function()
                    if EventSync ~= nil and EventSync.sweepDisabled then
                        sweep = "OFF (mo_nosweep.on present)"
                    end
                end)
                f:write("leaksweep=" .. sweep .. "\n")
                -- WHICH server, and what it is running. Half of this mod is that
                -- separate process, and hosting on a remote one (the official
                -- server, a friend's) means server-side fixes may simply be absent
                -- — a capture that does not say so cannot be read correctly.
                local server = "unknown"
                pcall(function()
                    if Network ~= nil and Network.serverDescribe ~= nil then
                        server = Network.serverDescribe()
                    end
                end)
                f:write("server=" .. server .. "\n")
                if verdict ~= nil then
                    f:write(verdict .. "\n")
                end
                if frameMark ~= nil then
                    -- MO_TRACE was on last session: this names the per-frame
                    -- callback that was executing when it ended (see frameMark)
                    f:write("*** PREVIOUS SESSION's last per-frame callback: "
                        .. frameMark .. "\n")
                end
                -- Everything that happened in the LOBBY, where there was no file to
                -- put it in: the save-share exchange in full. Directly under the
                -- header, because that is where `saveshare=` is and the two are read
                -- together. See module.earlyEvent.
                for i = 1, #early do
                    f:write(early[i] .. "\n")
                end
                early = {}
            end)
            f:close()
            break
        end
    end
    if logPath == nil then
        errorf("DesyncLog: could not open a log file (tried %s / %s)",
            PRIMARY_PATH, FALLBACK_PATH)
    else
        dbg("desync log -> " .. logPath)
    end
end

function module.close()
    module.line("run end")
    -- Disarm the frame trace with the run. It was armed in init() and never
    -- cleared, so after one networked session the GUIFRAME marks -- registered at
    -- load and never removed -- kept writing on the MAIN MENU, where the frame
    -- rate is uncapped. The flag file is re-read by the next init(), so a session
    -- that wants tracing still gets it.
    traceFileOn = false
    pcall(function()
        if traceHandle ~= nil then
            traceHandle:close()
        end
    end)
    traceHandle = nil
end

--- Dump the freshly generated floor on EVERY machine: the run-state that gates
--- generation, each player's money/hp/position, a per-type histogram, and -- when
--- `mo_dump.on` exists -- the full sorted entity list (type + rounded position +
--- layer, NO uids), which is the artifact you diff between the two machines.
---
--- The entity list is OPT-IN because it cost a frame. It swept every entity a
--- SECOND time (computeFloorDigest already swept them), allocated a table per
--- entity, sorted ~4000 of them through a Lua comparator, formatted ~4000 strings
--- and wrote ~190 KB -- all inside the frame the floor engaged on, which is
--- exactly the hitch felt on entering a level. What stays is what detection and
--- diagnosis actually need: the digest, the gate state and the histogram.
---
--- `counts` is the per-type tally the digest sweep already built, so the histogram
--- costs nothing extra. Without it (an older caller) the histogram is skipped
--- rather than a sweep being run for it.
--- @param s integer      lockstep seq of this floor
--- @param seedHash integer
--- @param entHash integer
--- @param counts table<integer, integer>? # entity type id -> count, from the digest
function module.floorSnapshot(s, seedHash, entHash, counts)
    if not MO_LOG or logPath == nil then
        return
    end
    pcall(function()
        local st = get_local_state()
        local out = {}
        local function add(line) out[#out + 1] = line end

        local a, b = get_adventure_seed(false)
        add(string.format(
            "[%s %s] ---- FLOOR seq=%d  world=%d level=%d theme=%d  digest seed=%d ent=%d",
            nowStamp(), simClock(), s,
            st.world or -1, st.level or -1, st.theme or -1, seedHash, entHash))
        add(string.format(
            "  state: level_count=%d time_total=%d time_level=%d adv_seed=%08X-%08X",
            st.level_count or -1, st.time_total or -1, st.time_level or -1,
            math.floor(a) & 0xFFFFFFFF, math.floor(b) & 0xFFFFFFFF))
        add(string.format(
            "  gate: shoppie=%d shoppie_next=%d merchant=%d | kali favor=%d status=%d altars=%d | quest_flags=0x%X presence_flags=0x%X",
            st.shoppie_aggro or -1, st.shoppie_aggro_next or -1, st.merchant_aggro or -1,
            st.kali_favor or -1, st.kali_status or -1, st.kali_altars_destroyed or -1,
            st.quest_flags or 0, st.presence_flags or 0))

        for coopIndex = 1, 4 do
            local inv = st.items and st.items.player_inventory
                and st.items.player_inventory[coopIndex] or nil
            local p = get_player(coopIndex, false)
            if inv ~= nil or p ~= nil then
                local hp = (p and p.health) or (inv and inv.health) or -1
                local mo = (p and p.inventory and p.inventory.money)
                    or (inv and inv.money) or -1
                -- ABSOLUTE position: a player attached to something (riding a mount,
                -- held) reports coordinates RELATIVE to that parent, which reads as a
                -- nonsense spot like 0.00,-0.16 in the log.
                local pos = "(no entity)"
                if p ~= nil then
                    local px, py = p.x, p.y
                    pcall(function()
                        local abs = p:get_absolute_position()
                        px, py = abs.x, abs.y
                    end)
                    pos = string.format("%.2f,%.2f", px, py)
                end
                -- kit + the two fields that silently diverged in real captures:
                -- `ovl` (what the player is attached to, i.e. the mount) and `tod`
                -- (time_of_death, which decides who a revival coffin puts back and
                -- so whether a coffin clones an already-alive player)
                local bo = (inv and inv.bombs) or -1
                local ro = (inv and inv.ropes) or -1
                local mt = (inv and inv.mount_type) or -1
                local tod = (inv and inv.time_of_death) or -1
                local ovl = "none"
                if p ~= nil then
                    pcall(function()
                        local ov = p.overlay
                        if ov ~= nil then
                            ovl = entName(math.floor(ov.type.id))
                        end
                    end)
                end
                add(string.format(
                    "  player %d: hp=%s money=%s bombs=%s ropes=%s mount=%s ovl=%s tod=%s pos=%s",
                    coopIndex, tostring(hp), tostring(mo), tostring(bo), tostring(ro),
                    tostring(mt), ovl, tostring(tod), pos))
            end
        end

        -- The histogram, from the tally the digest sweep already made. Sorted by
        -- type id so two machines' lines match; that sort is over the number of
        -- DISTINCT types (a few dozen), not over every entity.
        local full = dumpActive()
        if counts ~= nil then
            local ids = {}
            local total = 0
            for id, n in pairs(counts) do
                ids[#ids + 1] = id
                total = total + n
            end
            table.sort(ids)
            local hist = {}
            for _, id in ipairs(ids) do
                hist[#hist + 1] = string.format("%s=%d", entName(id), counts[id])
            end
            add(string.format("  entities: %d total | %s", total, table.concat(hist, " ")))
        end

        if full then
            -- collect gen-placed entities, sort deterministically (uid order differs
            -- across machines — sorting makes the two files diff line-for-line)
            local list = {}
            for _, uid in ipairs(get_entities_by(0, DUMP_MASKS, LAYER.BOTH)) do
                local e = get_entity(uid)
                if e ~= nil then
                    list[#list + 1] = {
                        id = math.floor(e.type.id), x = e.x, y = e.y, layer = e.layer or 0,
                    }
                end
            end
            table.sort(list, function(p, q)
                if p.id ~= q.id then return p.id < q.id end
                if p.x ~= q.x then return p.x < q.x end
                if p.y ~= q.y then return p.y < q.y end
                return p.layer < q.layer
            end)
            for _, e in ipairs(list) do
                add(string.format("    %-28s x=%.2f y=%.2f L=%d",
                    entName(e.id), e.x, e.y, e.layer))
            end
        end

        writeRaw(table.concat(out, "\n"))
    end)
end

--- Snapshot the exact generation INPUTS at a named phase of a floor's build, so a
--- generation divergence can be localized instead of guessed at.
---
--- Logs the adventure seed plus the game PRNG's per-stream state (`prng:get_pair`).
--- Those two ARE the generation inputs: with the same seed and the same stream
--- state, any generator — the engine's or a content mod's own Lua one — must
--- produce the same level. So comparing two machines' logs:
---   * inputs DIFFER at "pre" -> the divergence was inherited from an earlier
---     floor (seed application or drift during the previous floor's play), not
---     from this floor's generator;
---   * inputs MATCH at "pre" but the worlds differ -> the content mod's generator
---     consumed a DIFFERENT NUMBER of draws, i.e. it branched on state of its own
---     that we cannot see (the HD mod owns its level generation, so this is the
---     expected signature there);
---   * "post" shows how much the floor's generation consumed, which pins the
---     divergence to generation vs. gameplay.
--- @param label string # "pre" or "post"
function module.genPhase(label)
    if not MO_LOG or logPath == nil then
        return
    end
    pcall(function()
        local a, b = get_adventure_seed(false)
        -- PET_STYLE decides which pet (dog/cat/hamster) generation spawns, and it is
        -- a PER-MACHINE setting: if it differs the worlds differ. Synced from the
        -- room host during a run, logged so a mismatch is provable at a glance.
        local pet = "?"
        pcall(function() pet = tostring(get_setting(GAME_SETTING.PET_STYLE)) end)
        local parts = {}
        -- EVERY stream (PRNG_CLASS 0..9), not a sample of three. This used to log
        -- 0, 3 and 8 on the assumption that 0 was the level-generation stream, and
        -- a real capture then showed all three MATCHING at "pre" on the floor that
        -- desynced -- which proves nothing about the stream the mod actually drew
        -- from (the HD mod names PRNG_CLASS.LEVEL_GEN explicitly, and that is not
        -- one of the three). Ten pairs is one longer line per floor, and it is the
        -- difference between "the inputs matched" and "the inputs we happened to
        -- look at matched".
        for class = 0, 9 do
            local ok, p1, p2 = pcall(function()
                return prng:get_pair(class)
            end)
            if ok and p1 ~= nil then
                parts[#parts + 1] = string.format("c%d=%08X:%08X", class,
                    math.floor(p1) & 0xFFFFFFFF, math.floor(p2 or 0) & 0xFFFFFFFF)
            end
        end
        local st = get_local_state()
        -- Is the engine being told this is a SEEDED run? Modded Online no longer
        -- sets the flag (removed in 2.0.0-dev46 by request), so this now reports
        -- what the engine and other mods did rather than echoing what we did --
        -- which is why it is worth MORE than before, not less.
        --
        -- It matters because the HD mod branches on it: unseeded, it picks a
        -- per-floor character unlock from the LOCAL player's own unlocked roster
        -- and draws from the level-generation PRNG to do it, so two players with
        -- different unlocks consume a different number of draws and build
        -- different floors from the same seed. If a run desyncs at the first
        -- eligible floor of a world -- 1-2 in Dwelling, 2-1 in Jungle -- and this
        -- reads 0 on both machines, that is the cause.
        local seeded = "?"
        pcall(function()
            local bit = 7 -- QUEST_FLAG.SEEDED is a 1-based bit INDEX, not a mask
            if QUEST_FLAG ~= nil and type(QUEST_FLAG.SEEDED) == "number" then
                bit = math.floor(QUEST_FLAG.SEEDED)
            end
            seeded = test_flag(st.quest_flags, bit) and "1" or "0"
        end)
        module.line("gen[%s] w%d-%d th%d lc=%d pet=%s seeded=%s adv=%08X-%08X prng %s",
            label, st.world or -1, st.level or -1, st.theme or -1,
            st.level_count or -1, pet, seeded,
            math.floor(a) & 0xFFFFFFFF, math.floor(b) & 0xFFFFFFFF,
            table.concat(parts, " "))
    end)
end

--- A world-gen mismatch was detected for floor `s` (non-host only). Points you
--- straight at that floor's entity dump in both logs.
--- @param s integer
--- @param mine { seed: integer, ent: integer }
--- @param host { seed: integer, ent: integer }
function module.floorMismatch(s, mine, host)
    module.line(
        "*** FLOOR DESYNC seq=%d  seed %s (mine=%d host=%d)  entities %s (mine=%d host=%d)  -> diff this floor's entity dump between the two logs",
        s,
        (mine.seed ~= host.seed) and "DIFFER" or "ok", mine.seed, host.seed,
        (mine.ent ~= host.ent) and "DIFFER" or "ok", mine.ent, host.ent)
end

--- Player positions drifted out of sync (position checksum). Dumps live spots.
function module.positionDesync(key, mineHash, theirHash, streak)
    module.line(
        "*** POSITION DESYNC at %s: local hash %d vs remote %d (streak %d) — a mod moved a player non-deterministically",
        key, mineHash, theirHash, streak)
    pcall(function()
        for coopIndex = 1, 4 do
            local p = get_player(coopIndex, false)
            if p ~= nil then
                -- LAYER included: a divergent layer is the tell for a layer-door
                -- travel that fired on one machine only — same inputs, different
                -- collision, so the player walks to a different spot (see
                -- eventSync layer travel). It is otherwise invisible here.
                module.line("    player %d live pos=%.2f,%.2f hp=%s layer=%s",
                    coopIndex, p.x, p.y, tostring(p.health), tostring(p.layer))
            end
        end
    end)
end

DesyncLog = module
return module
