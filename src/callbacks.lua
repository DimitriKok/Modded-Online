--- Keeping Modded Online's own callbacks alive inside a shared script.
---
--- Hosting a content mod puts its registrations and ours in ONE Playlunky script, so
--- we share a callback id space with it. 2.5 contains 38 bare `clear_callback()`
--- calls -- the form that means "clear whichever callback is running right now"
--- rather than naming an id. Under the old shim that was harmless: the mod was a
--- separate script with a separate id space, so the worst a bare clear could reach
--- was one of the mod's own. Hosted, it can reach ours.
---
--- A capture shows exactly that. At the 1-2 -> 1-3 transition our network tick, our
--- lockstep gate and our floor digest all stopped together, while the mod kept
--- running and the mod's own callbacks kept firing. With the gate gone there was no
--- lockstep at all: the host walked on to 1-4 alone, the other machine stayed on
--- 1-3, and the name tags and door handling that live in the same callbacks went
--- with them. `clear_callback(id)` was already mediated by the ownership guard in
--- modHost; the bare form was waved straight through, and it is the only teardown
--- call that never names what it is destroying.
---
--- This module owns both halves of the answer:
---
---   * **Depth.** It knows when one of OUR callbacks is on the stack, so modHost can
---     refuse a bare clear that would land on us. Inside the mod's own callbacks the
---     depth is zeroed, so the mod's bare clears keep working as they always did.
---   * **Revival.** It re-registers per-frame callbacks that stop firing. If anything
---     gets through anyway -- another mod, another teardown idiom, an id the engine
---     recycles -- the run repairs itself in a few seconds instead of silently
---     drifting onto two different floors.
---
--- Loaded before every other module so that every registration we make is recorded.
--- The mod's registrations deliberately are not: modHost sends those to
--- `rawSetCallback`, below.

local module = {}

--- The engine's own functions, captured before the global is replaced.
local rawSetCallback = set_callback
local rawClearCallback = clear_callback
module.rawSetCallback = rawSetCallback
module.rawClearCallback = rawClearCallback

--- How long each kind may go quiet before we treat it as gone.
---
--- One flat five-second budget was far too loose. A capture showed the lockstep gate
--- revived five seconds after it died -- and five seconds is ~300 frames in which the
--- gate is not holding inputs neutral, so each machine drove its own player and
--- nobody else's. That is precisely the reported desync: one player moved before the
--- other had loaded in. The floor digest for 1-4 was taken at time_level 256 on one
--- machine and 247 on the other, where every earlier floor read 2 on both.
---
--- So the two kinds that fire on EVERY frame, including during fades and while the
--- gate is holding, get a tight budget. GAMEFRAME and POST_UPDATE legitimately pause
--- whenever the simulation does, so they keep a loose one.
local STALE_MS = {
    PRE_UPDATE = 300,
    GUIFRAME = 600,
    GAMEFRAME = 5000,
    POST_UPDATE = 5000,
}

--- If the sweeper ITSELF has not run for this long, the whole process was away --
--- generating a 4,000-entity level, or alt-tabbed. Nothing is stale in that case; we
--- simply were not running, and judging callbacks on that evidence would revive live
--- ones every floor. This is what makes the tight budgets above safe.
local REBASE_MS = 250

local clockMs = rawget(_G, "get_ms")
local onTable = rawget(_G, "ON")

--- Where a callback was defined, for the revival log.
---
--- Six of our registrations are ON.PRE_UPDATE -- the lockstep gate, the crash-trace
--- marker, two network pumps, chat and eventSync. A log line saying only "PRE_UPDATE"
--- cannot distinguish the gate dying (a desync) from a breadcrumb dying (harmless),
--- and that was exactly the question the last capture could not answer.
--- @param fn function
--- @return string
local function describe(fn)
    local dbg = rawget(_G, "debug")
    if type(dbg) ~= "table" or type(dbg.getinfo) ~= "function" then
        return "?"
    end
    local ok, info = pcall(dbg.getinfo, fn, "S")
    if not ok or type(info) ~= "table" then
        return "?"
    end
    local src = tostring(info.short_src or info.source or "?")
    local leaf = src:match("([^/\\]+)$")
    return (leaf or src) .. ":" .. tostring(info.linedefined or "?")
end

local depth = 0     -- how many of OUR callbacks are currently on the stack
local entries = {}  -- every callback we registered, so it can be revived
local perFrame = {} -- ON value -> name, for the kinds that must fire every frame
local lastSweepLogMs = 0
local lastSweepMs = 0

if type(onTable) == "table" then
    for _, name in ipairs({ "PRE_UPDATE", "POST_UPDATE", "GAMEFRAME", "GUIFRAME" }) do
        local value = onTable[name]
        if value ~= nil then
            perFrame[value] = name
        end
    end
end

--- @return integer
local function nowMs()
    if clockMs == nil then
        return 0
    end
    return clockMs()
end

--- Per-callback timing, for "it feels stuttery" -- which the crash breadcrumb cannot
--- answer.
---
--- `mo_trace.on` writes a line to a file for every marked callback on every frame. It
--- exists to say what was running when the process died, and it only reports frames
--- over a spike threshold -- so a session of many small hitches produces a trace with
--- nothing in it at all, which is exactly what came back.
---
--- This measures instead of narrating: every callback we wrap is timed, ours and the
--- hosted mod's alike, and a summary goes to the desync log every ten seconds. Off
--- ON by default. It used to need `mo_profile.on`, and three sessions running came
--- back with `profile=off` in the header: the flag file lives in the pack folder, so
--- installing a new build replaces the folder and takes the flag with it. A
--- diagnostic that is only armed when someone remembers to arm it is not armed.
--- `mo_profile.off` turns it off.
---
--- What it costs: OUR callbacks add no clock reads at all -- the registry already
--- stamps `lastRanMs` for the revival sweep, so the start time is a value we were
--- recording anyway. A hosted mod's callbacks add one `get_ms` each. Everything else
--- is a table lookup and four additions.
local profiling = true
pcall(function()
    local probe = io.open(PackPath("mo_profile.off"), "r")
    if probe ~= nil then
        probe:close()
        profiling = false
    end
end)
-- No clock -> every measurement is 0 -> a report of all zeros, which reads as
-- "nothing costs anything" when it means "nothing was measured". Stay quiet instead.
if clockMs == nil then
    profiling = false
end

--- One call this long is a visible hitch: a frame at 60fps is 16.7ms.
local SPIKE_MS = 8

local profile = {}      -- name -> { ms, calls, worst, spikes }
local lastReportMs = 0

--- @param name string
--- @param startMs number
local function chargeTo(name, startMs)
    local entry = profile[name]
    if entry == nil then
        entry = { ms = 0, calls = 0, worst = 0, spikes = 0 }
        profile[name] = entry
    end
    local took = nowMs() - startMs
    entry.ms = entry.ms + took
    entry.calls = entry.calls + 1
    -- The average was all the first version reported, and an average cannot see a
    -- stutter: a callback costing 25ms once a second is 2.5% of wall time and ranks
    -- near the BOTTOM of the list while being the thing the player actually feels.
    if took > entry.worst then
        entry.worst = took
    end
    if took >= SPIKE_MS then
        entry.spikes = entry.spikes + 1
    end
end

--- Are we inside one of Modded Online's own callbacks right now?
---
--- modHost asks this before letting a hosted mod's bare `clear_callback()` reach the
--- engine. Non-zero means the callback the engine would destroy is one of ours.
--- @return integer
--- Is per-callback timing on? Reported in the desync log header, because a log
--- with no PROFILE lines might mean the flag is missing OR that the session was
--- shorter than one report interval, and those need different advice.
--- @return boolean
function module.profiling()
    return profiling
end

function module.depth()
    return depth
end

local hostedTraceback -- the message handler, below with the hosted errors
local logOurError     -- below too
--- The error a hosted callback raised on its way up through one of ours, which called
--- into the mod (the ordered ON.LEVEL batch, the world capture): the mod's, logged as
--- such already, and not to be logged again as ours. Cleared as each of ours starts.
local raisedByMod = nil

--- Wrap one of OUR callbacks: mark it live, and count it on the stack.
---
--- Only the first return value is forwarded, which is all any of our callbacks
--- produces. `nil` is returned as NOTHING rather than as an explicit nil, because
--- ON.PRE_UPDATE distinguishes the two: a value returned there means "skip the
--- engine's update this frame", and that is the lockstep gate's whole mechanism.
---
--- An error is logged on its way out (logOurError), like a hosted callback's: until
--- dev79 one raised by a callback of OURS reached spelunky.log only, under the same
--- "Mod: fyi.modded-online-loader" a hosted mod's errors carry, so a capture could not
--- say whose it was.
--- @param entry table
--- @param fn function
--- @return function
local function record(entry, fn)
    return function(...)
        entry.lastRanMs = nowMs()
        raisedByMod = nil
        depth = depth + 1
        local startedAt = profiling and entry.lastRanMs or 0
        local ok, value = xpcall(fn, hostedTraceback, ...)
        depth = depth - 1
        if profiling then
            chargeTo("ours " .. tostring(entry.where), startedAt)
        end
        if ok ~= true then
            pcall(logOurError, entry, value)
            error(value, 0)
        end
        if value == nil then
            return
        end
        return value
    end
end

-- --------------------------------------------------- a hosted callback's errors
--
-- A hosted mod runs in OUR script, so Playlunky reports its Lua errors under our
-- name ("Mod: fyi.modded-online-loader / Error: ...") -- and until dev77 nothing put
-- them in the desync log. Room FVJF's peer saw one on 4-1, `attempt to call a number
-- value`, and the only record of it was spelunky.log, with an empty traceback.
--
-- Every error a hosted callback raises now goes to the desync log too, under the
-- name of the mod's own function: the first from each one in full, with its stack,
-- and after that one line every few seconds. The error itself still goes on to the
-- engine unchanged, so what Playlunky shows is what it showed before.

local HOSTED_ERR_REPEAT_MS = 5000
local hostedErrSeen = {}   -- where -> true once its first error is in the log
local hostedErrLast = {}   -- where -> when it was last repeated
local hostedErrTrace = nil -- the stack of the error being raised right now

--- Errors their own source has already logged (the ordered ON.LEVEL batch, which
--- knows which of the mod's callbacks threw), waiting to be raised again through a
--- wrapper here. Raising one is not a second error.
local noted = {}
local notedCount = 0

--- @param v any
--- @return string
local function safeText(v)
    local ok, text = pcall(tostring, v)
    return ok and text or "?"
end

--- The message handler for a hosted callback: keeps the stack for the log, hands the
--- error value back exactly as it was raised. It must not raise itself -- an error in
--- a message handler replaces the original one -- so every step is protected.
--- @param err any
--- @return any err
function hostedTraceback(err)
    hostedErrTrace = nil
    local dbg = rawget(_G, "debug")
    if type(dbg) == "table" and type(dbg.traceback) == "function" then
        local ok, tb = pcall(dbg.traceback, safeText(err), 2)
        if ok and type(tb) == "string" then
            hostedErrTrace = tb
        end
    end
    return err
end

--- @param where string
--- @param value any
--- @param trace string?
--- @param whose string? # "HOSTED MOD ERROR" unless it is one of ours
local function logHostedError(where, value, trace, whose)
    local log = rawget(_G, "DesyncLog")
    if log == nil then
        return
    end
    whose = whose or "HOSTED MOD ERROR"
    local key = whose .. " " .. where
    local now = nowMs()
    if not hostedErrSeen[key] then
        hostedErrSeen[key] = true
        hostedErrLast[key] = now
        -- the first, in full, even from the lobby: held until a run opens the log
        if type(log.earlyEvent) == "function" then
            pcall(log.earlyEvent, "*** %s in %s: %s", whose, where,
                trace or safeText(value))
        end
        return
    end
    if now - (hostedErrLast[key] or 0) >= HOSTED_ERR_REPEAT_MS then
        hostedErrLast[key] = now
        if type(log.event) == "function" then
            local text = safeText(value)
            pcall(log.event, "*** %s again in %s: %s", whose, where,
                text:match("^[^\n]*") or text)
        end
    end
end

--- @param entry table
--- @param value any
function logOurError(entry, value)
    local mod = raisedByMod
    raisedByMod = nil
    if mod ~= nil and rawequal(mod, value) then
        return
    end
    logHostedError(tostring(entry.where), value, hostedErrTrace, "MODDED ONLINE ERROR")
end

--- For a hosted callback's error caught somewhere other than the wrapper below: log
--- it under `where`, and let the wrapper know it is already logged when it is raised
--- through it.
--- @param where string
--- @param value any
--- @param trace string?
function module.noteHostedError(where, value, trace)
    raisedByMod = value
    logHostedError(where, value, trace)
    if type(value) == "string" and noted[value] == nil then
        if notedCount >= 32 then
            noted, notedCount = {}, 0 -- raised nowhere after all; do not keep them
        end
        noted[value] = true
        notedCount = notedCount + 1
    end
end

--- @param value any
--- @return boolean # it was noted, and is now forgotten
local function takeNoted(value)
    if type(value) == "string" and noted[value] then
        noted[value] = nil
        notedCount = notedCount - 1
        return true
    end
    return false
end

--- The mod's own function behind one of determinism's wrappers, if `fn` is one: an
--- anchored, held-frame-skipping or ON.LEVEL-ordered callback otherwise names itself
--- `determinism.lua:<line>`, which is what a real crash trace said.
--- @param fn function
--- @return function
local function innermost(fn)
    local det = rawget(_G, "Determinism")
    if type(det) == "table" and type(det.innerOf) == "table" then
        local inner = det.innerOf[fn]
        if type(inner) == "function" then
            return inner
        end
    end
    return fn
end

-- What a hosted mod calls its own callback, where the mod's wrapper keeps that.
--
-- 2.5 registers nearly every callback through one of Helpers2's protected wrappers,
-- one wrapper function per kind of event, so each of them named every callback of its
-- kind alike: all of 2.5's PRE_LEVEL_DESTRUCTION callbacks are `helpers2.lua:533`,
-- which is the whole of what room UVLQ's crash trace could say. Each wrapper closes
-- over the name 2.5 logs that callback under (`callbackName`, else `debugName`) and the
-- function it protects (`callback`, else `wrappedCallback`), so both can be read, once,
-- at registration: `helpers2.lua:533 (<its name> @ <file>.lua:<line>)`. Reading an
-- upvalue runs nothing of the mod's.
local OWN_LABELS = { "callbackName", "debugName" }
local OWN_CALLEES = { "callback", "wrappedCallback" }
local OWN_MAX = 72 -- the trace line is 180 wide, and the clock comes after the name

--- @param fn function
--- @return table<string, any>
local function upvaluesOf(fn)
    local found = {}
    local dbg = rawget(_G, "debug")
    if type(dbg) ~= "table" or type(dbg.getupvalue) ~= "function" then
        return found
    end
    for i = 1, 64 do
        local ok, key, value = pcall(dbg.getupvalue, fn, i)
        if not ok or key == nil then
            break
        end
        if found[key] == nil then
            found[key] = value
        end
    end
    return found
end

--- @param fn function
--- @return string?
local function ownName(fn)
    local label, callee, at = nil, nil, fn
    -- A wrapper can wrap a wrapper (2.5's every-Nth-frame counter): a few steps in.
    for _ = 1, 3 do
        local up = upvaluesOf(at)
        for _, key in ipairs(OWN_LABELS) do
            if label == nil and type(up[key]) == "string" and up[key] ~= "" then
                label = up[key]
            end
        end
        local nextFn = nil
        for _, key in ipairs(OWN_CALLEES) do
            if nextFn == nil and type(up[key]) == "function" then
                nextFn = up[key]
            end
        end
        if nextFn == nil or nextFn == at then
            break
        end
        callee, at = nextFn, nextFn
    end
    if label == nil and callee == nil then
        return nil
    end
    local text = label or ""
    if callee ~= nil then
        text = (label ~= nil and (label .. " ") or "") .. "@ " .. describe(callee)
    end
    if #text > OWN_MAX then
        text = text:sub(1, OWN_MAX - 3) .. "..."
    end
    return text
end

--- A hosted callback's name: the mod's own function, and what the mod calls it.
--- @param fn function
--- @return string
local function hostedName(fn)
    local inner = innermost(fn)
    local where = describe(inner)
    local ok, own = pcall(ownName, inner)
    if ok and own ~= nil then
        where = where .. " (" .. own .. ")"
    end
    return where
end

--- What a hosted callback handed back, for crash_notes.txt. Its own function so the
--- wrapper does not build a closure per call, and called protected: the table is the
--- mod's, and reading it runs the mod's metamethods.
--- @param where string
--- @param firstArg any
--- @param value table
local function noteTableReturn(where, firstArg, value)
    local n = #value
    local head = {}
    for i = 1, (n < 8 and n or 8) do
        head[#head + 1] = safeText(value[i])
    end
    DesyncLog.traceNote("%s(%s) -> table #%d { %s%s }", where,
        safeText(firstArg), n, table.concat(head, ", "),
        n > 8 and ", ..." or "")
end

--- Wrap a HOSTED mod's callback: while it runs, our depth is zero.
---
--- So a bare `clear_callback()` from inside the mod's own callback still reaches the
--- engine and still clears the mod's own callback, exactly as it did before hosting.
--- The depth is saved and restored rather than simply cleared, because a hosted
--- callback can be reached from inside one of ours -- our level-generation hooks
--- call into the mod's world capture -- and the frames above it are still ours.
--- @param fn function
--- @param label string? # what it was registered for: the ON event or the API
--- @param offThread boolean? # the engine calls it from another thread: no trace marks
--- @return function
function module.hosted(fn, label, offThread)
    -- Tracing needs the name as much as profiling does, and for a better reason.
    --
    -- The frame trace marks OUR callbacks only, so a crash inside the engine's
    -- update reads as "after gameframe:eventSync returned, before POST_UPDATE" --
    -- which correctly proves the death is not in Modded Online's own code, and then
    -- says nothing at all about WHICH of a hosted mod's 203 registrations was
    -- running. hdmod's journal alone registers and tears down eight callbacks in a
    -- nested storm, so "somewhere in the mod" is not a location.
    --
    -- `hostedName` is a `debug.getinfo` and a read of the function's upvalues per
    -- REGISTRATION (not per call), and only when a diagnostic that wants it is armed.
    -- It describes the mod's own function, not the determinism wrapper it may be
    -- registered inside, and the name the mod's own wrapper gives it (ownName).
    local tracing = false
    pcall(function()
        tracing = DesyncLog ~= nil and DesyncLog.tracing ~= nil and DesyncLog.tracing()
    end)
    local where = (profiling or tracing) and hostedName(fn) or "?"
    -- ...and the trace names what the callback was registered FOR. Room UVLQ's crash
    -- trace read `OUT mod helpers2.lua:533`: a function of 2.5's, with nothing to say
    -- whether the engine had called it at PRE_LOAD_SCREEN, at the level's teardown or
    -- on the frame before. Both are known here, at registration, for free.
    local suffix = type(label) == "string" and label ~= "" and (" " .. label) or ""
    -- ...except one the engine calls from another thread (a vanilla sound callback,
    -- on FMOD's). The trace is a single line, and a sound playing while the main
    -- thread is deep in native code would overwrite the one mark that says where.
    local mark = (tracing and offThread ~= true) and ("mod " .. where .. suffix) or nil
    return function(...)
        local saved = depth
        depth = 0
        local startedAt = profiling and nowMs() or 0
        if mark ~= nil then
            DesyncLog.frameMark(mark)
        end
        local firstArg = mark ~= nil and (...) or nil
        local ok, value = xpcall(fn, hostedTraceback, ...)
        if mark ~= nil then
            DesyncLog.frameDone(mark)
            -- A hosted callback returning a TABLE is handing the engine a structure
            -- to consume, and the engine consumes it the instant we return. When the
            -- process dies immediately after such a callback -- which is exactly what
            -- crash_frame.txt showed for hdmod's ON.POST_LOAD_JOURNAL_CHAPTER -- the
            -- contents of that table are the only thing left worth knowing, and they
            -- are gone by the time anything else could look.
            --
            -- Tables are rare as callback returns (most are nil or a boolean), so
            -- this is not the per-frame firehose it looks like.
            if ok and type(value) == "table" and DesyncLog.traceNote ~= nil then
                pcall(noteTableReturn, where, firstArg, value)
            end
        end
        depth = saved
        if profiling then
            chargeTo("mod  " .. where, startedAt)
        end
        if ok ~= true then
            if not takeNoted(value) then
                if where == "?" then
                    where = hostedName(fn) -- named on its first error, not before
                end
                logHostedError(where .. suffix, value, hostedErrTrace)
            end
            raisedByMod = value
            error(value, 0)
        end
        if value == nil then
            return
        end
        return value
    end
end

--- Register one of ours, and remember it.
--- @param fn function
--- @param kind any # an ON.* value
--- @return integer? id
local function register(fn, kind)
    if type(fn) ~= "function" then
        return rawSetCallback(fn, kind)
    end
    local entry = { kind = kind, lastRanMs = 0, where = describe(fn) }
    entry.wrapped = record(entry, fn)
    entry.id = rawSetCallback(entry.wrapped, kind)
    entries[#entries + 1] = entry
    return entry.id
end

--- Revive any per-frame callback of ours that has stopped firing.
---
--- Cadence is the only honest test available: a callback that should run every frame
--- and has not run in five seconds is gone. The occasional kinds (level generation,
--- load screens) cannot be checked this way and are not touched -- the depth guard
--- above is what protects those.
--- @return integer healed, string names
function module.sweep()
    local now = nowMs()
    local gap = lastSweepMs > 0 and (now - lastSweepMs) or 0
    lastSweepMs = now
    if gap > REBASE_MS then
        -- We were not running. Re-baseline every callback that had been firing and
        -- judge nothing this pass: silence during a level load is our absence, not
        -- theirs, and reviving on that evidence would churn every floor.
        for index = 1, #entries do
            local entry = entries[index]
            if entry.lastRanMs > 0 then
                entry.lastRanMs = now
            end
        end
        return 0, ""
    end
    local healed, names = 0, {}
    for index = 1, #entries do
        local entry = entries[index]
        local kindName = perFrame[entry.kind]
        if kindName ~= nil and entry.lastRanMs > 0
            and now - entry.lastRanMs > (STALE_MS[kindName] or 5000) then
            -- Clear FIRST. If the callback turns out to have been alive and merely
            -- idle, this is what stops us ending up with two of it. The id could in
            -- principle have been recycled onto one of the mod's callbacks by now, in
            -- which case we cost the mod a hook -- survivable, and 2.5 reinstalls its
            -- hooks every floor. Two lockstep gates would not be survivable.
            rawClearCallback(entry.id)
            entry.id = rawSetCallback(entry.wrapped, entry.kind)
            entry.lastRanMs = now
            healed = healed + 1
            names[#names + 1] = kindName .. " " .. tostring(entry.where)
        end
    end
    return healed, table.concat(names, ", ")
end

--- @return nil
local lastScanMs = 0

--- @return nil
local function sweepTick()
    local net = rawget(_G, "Network")
    if net == nil or net.isInRun == nil or not net.isInRun() then
        return
    end
    -- Registered on three callback kinds so that losing any one of them still leaves
    -- a survivor to revive the rest -- which meant scanning three times a frame. The
    -- tightest budget below is 300ms, so a scan every 250ms detects everything just
    -- as fast and does a fraction of the work.
    local scanAt = nowMs()
    if scanAt - lastScanMs < 250 then
        return
    end
    lastScanMs = scanAt

    local healed, names = module.sweep()
    if healed == 0 then
        return
    end
    local log = rawget(_G, "DesyncLog")
    local now = nowMs()
    if log ~= nil and log.event ~= nil and now - lastSweepLogMs > 2000 then
        lastSweepLogMs = now
        local host = rawget(_G, "ModHost")
        local refused = 0
        if host ~= nil and host.refusedBareCount ~= nil then
            refused = host.refusedBareCount()
        end
        log.event(
            "REVIVED %d of our callbacks that had stopped firing (%s) -- a hosted"
            .. " mod's teardown reached them; lockstep continues"
            .. " [bare clears refused so far: %d]",
            healed, names, refused)
    end
end

set_callback = register

-- ------------------------------------------------------------- frame timing
--
-- Which callback is expensive is only half of "it feels stuttery". The other half is
-- whether the frames are hitching at all and by how much -- and if our callbacks
-- account for none of it, that IS the answer: the cost is in the engine or in the
-- hosted mod's own per-entity updates, where a callback profiler cannot see it. Three
-- rounds of this have now been spent narrowing by argument; this measures instead.
local lastFrameMs = 0
local frames, worstFrameMs, over20, over33 = 0, 0, 0, 0

--- Longer than this is not a hitch. It is a level generating, or the window being
--- alt-tabbed away from. Counting those would put a 4,000ms "worst frame" at the top
--- of every report and bury the 30ms one somebody actually felt.
local FRAME_CEILING_MS = 250

--- Registered on GAMEFRAME ONLY -- unlike the sweeper, which is on three kinds so any
--- survivor can revive the rest. This one must run EXACTLY once per frame or the
--- frame deltas are meaningless, and a profiler is not worth defending the way the
--- lockstep gate is.
--- @return nil
local function profileTick()
    if not profiling then
        return
    end
    local now = nowMs()

    if lastFrameMs ~= 0 then
        local delta = now - lastFrameMs
        if delta >= 0 and delta < FRAME_CEILING_MS then
            frames = frames + 1
            if delta > worstFrameMs then
                worstFrameMs = delta
            end
            if delta >= 33 then
                over33 = over33 + 1
            elseif delta >= 20 then
                over20 = over20 + 1
            end
        end
    end
    lastFrameMs = now

    -- Deliberately NOT gated on being in a run, unlike the sweeper: a session that
    -- never got far enough to start one is exactly the session that came back with
    -- nothing in it, and "no data" has been the outcome three times running.
    if lastReportMs == 0 then
        lastReportMs = now
        return
    end
    if now - lastReportMs < 10000 then
        return
    end
    local window = now - lastReportMs
    lastReportMs = now

    local log = rawget(_G, "DesyncLog")
    local ranked = {}
    for name, entry in pairs(profile) do
        ranked[#ranked + 1] = {
            name = name, ms = entry.ms, calls = entry.calls,
            worst = entry.worst, spikes = entry.spikes,
        }
    end
    profile = {}

    if log ~= nil and log.event ~= nil then
        -- Frames first, because it says whether there is anything to explain.
        log.event("PROFILE frames=%d in %.1fs  worst=%.0fms  over-20ms=%d  over-33ms=%d",
            frames, window / 1000, worstFrameMs, over20, over33)

        table.sort(ranked, function(a, b) return a.ms > b.ms end)
        local shown = {}
        for index = 1, math.min(#ranked, 6) do
            local row = ranked[index]
            shown[row.name] = true
            log.event("PROFILE %5.1f%% of window, %7d calls, worst %4.0fms, spikes %3d  %s",
                row.ms / window * 100, row.calls, row.worst, row.spikes, row.name)
        end

        -- ...then anything that SPIKES without being expensive on average. That is
        -- the shape a stutter has, and the reason it never showed up in the ranking
        -- above: it is cheap almost every frame and ruinous on one of them.
        table.sort(ranked, function(a, b) return a.worst > b.worst end)
        local extra = 0
        for index = 1, #ranked do
            local row = ranked[index]
            if extra >= 3 or row.worst < SPIKE_MS then
                break
            end
            if shown[row.name] ~= true then
                extra = extra + 1
                log.event("PROFILE SPIKE worst %4.0fms, %3d over %dms, %7d calls  %s",
                    row.worst, row.spikes, SPIKE_MS, row.calls, row.name)
            end
        end
    end

    frames, worstFrameMs, over20, over33 = 0, 0, 0, 0
end

-- The sweeper itself is registered with the ENGINE's set_callback, so it is not in
-- the book and never sweeps itself -- and on three kinds, because the whole premise
-- is that any one of them can be taken away. Any survivor revives the rest.
if type(onTable) == "table" then
    for _, name in ipairs({ "PRE_UPDATE", "GUIFRAME", "GAMEFRAME" }) do
        if onTable[name] ~= nil then
            rawSetCallback(sweepTick, onTable[name])
        end
    end
end

-- The frame-time profiler, once per frame. Also with the engine's set_callback, for
-- the same reason: it must not appear in the book it is measuring.
if type(onTable) == "table" and onTable.GAMEFRAME ~= nil then
    rawSetCallback(profileTick, onTable.GAMEFRAME)
end

Callbacks = module
return module
