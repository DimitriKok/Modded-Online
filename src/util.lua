--- Modded Online — logging and error-safety helpers (global, used by all modules).

local module = {}

--- Flip to true (or set from the console) for verbose network logging.
MO_DEBUG = MO_DEBUG or false

--- @param msg string
function dbg(msg)
    if MO_DEBUG then
        print("[ModdedOnline] " .. tostring(msg))
    end
end

--- @param fmt string
function dbgf(fmt, ...)
    if MO_DEBUG then
        print("[ModdedOnline] " .. string.format(fmt, ...))
    end
end

--- get_player() normalised. It has been observed returning a NUMBER instead of a
--- Player or nil — Spelunky 2.5's crownHud blew up on the same thing in the same
--- frame, so it is the engine's player array in a bad state, not one mod's misuse.
--- A number defeats every `~= nil` / `== nil` guard we have: the guard passes and
--- the next field access throws "attempt to index a number value", which is
--- exactly how cameraTick and pollBackLayerLights failed. Funnel every lookup
--- through here so a bad return is nil everywhere, once.
--- @param coopIndex integer
--- @param orGhost boolean?
--- @return userdata? # the player, or nil if the engine handed back anything else
function SafePlayer(coopIndex, orGhost)
    local ok, p = pcall(get_player, coopIndex, orGhost == true)
    if not ok or p == nil or type(p) == "number" then
        return nil
    end
    return p
end

--- Always prints, for real problems the player should see in the console.
--- @param fmt string
function errorf(fmt, ...)
    print("[ModdedOnline ERROR] " .. string.format(fmt, ...))
end

-- One entry per failing call site: the FIRST failure gets the full traceback
-- (printed and written to the desync log), and after that the same site is
-- reported at most every REPEAT_MS as a one-liner. Without this a per-frame
-- callback that starts erroring would print a stack every frame and drown both
-- the console and the log.
local errSeen = {}
local errLastMs = {}
local ERR_REPEAT_MS = 5000

--- Protected call that logs failures instead of killing the host callback
--- chain. Returns whatever fn returns on success, nil on failure.
---
--- Uses xpcall, NOT pcall: pcall discards the stack, and "guiTick failed:
--- attempt to index a number value" with no file or line is not actionable —
--- that exact message cost a debugging round trip. The message handler runs
--- BEFORE the stack unwinds, so debug.traceback still sees the frame that
--- actually failed. `debug` may be sandboxed, so its absence is tolerated.
--- The message handler, hoisted. It used to be written inline, which meant a new
--- closure for it on every SafeCall -- and SafeCall is the wrapper around all ~37
--- per-frame callbacks in the mod.
--- @param err any
--- @return string
local function safeCallTraceback(err)
    local msg = tostring(err)
    if debug ~= nil and debug.traceback ~= nil then
        -- level 2 is still the frame that raised: hoisting the handler out of the
        -- xpcall call does not change the stack depth it is invoked at, and the
        -- fast path below calls fn directly rather than through a forwarding
        -- closure, so level 2 lands on fn either way.
        local tbOk, tb = pcall(debug.traceback, msg, 2)
        if tbOk and type(tb) == "string" then
            return tb
        end
    end
    return msg
end

--- @param callerName string
--- @param fn function
function SafeCall(callerName, fn, ...)
    local detail
    -- The zero-argument fast path, which is what almost every call site is: the
    -- mod makes ~37 SafeCalls per frame and only three of them pass an argument.
    -- The general path below allocates three heap objects per call (the `args`
    -- table, the forwarding closure, the table.pack result), so at display rate
    -- this was ~6,600 allocations a second of pure bookkeeping -- enough GC churn
    -- to show up as microstutter. xpcall with no extra arguments allocates none.
    if select("#", ...) == 0 then
        local ok, result = xpcall(fn, safeCallTraceback)
        if ok then
            return result
        end
        detail = tostring(result)
    else
        local argc = select("#", ...)
        local args = { ... }
        local results = table.pack(xpcall(function()
            return fn(table.unpack(args, 1, argc))
        end, safeCallTraceback))
        -- table.pack/unpack with an explicit n: preserves the exact number of return
        -- values, including trailing nils, the way the old table.unpack(results, 2) did
        if results[1] then
            return table.unpack(results, 2, results.n)
        end
        detail = tostring(results[2])
    end
    if not errSeen[callerName] then
        errSeen[callerName] = true
        errLastMs[callerName] = get_ms()
        errorf("%s failed: %s", callerName, detail)
        -- into the log too, so the next report is a file rather than a screenshot
        if DesyncLog ~= nil and DesyncLog.line ~= nil then
            pcall(DesyncLog.line, "*** LUA ERROR in %s: %s", callerName, detail)
        end
    else
        local now = get_ms()
        if now - (errLastMs[callerName] or 0) >= ERR_REPEAT_MS then
            errLastMs[callerName] = now
            -- first line only: the full stack is already above, in the log
            errorf("%s failed again: %s", callerName, detail:match("^[^\n]*") or detail)
        end
    end
    return nil
end

--- Our own pack FOLDER, resolved at runtime. NEVER assume what it is called:
--- publishing to spelunky.fyi renames the pack (Modded Online ->
--- fyi.modded-online), and a user may rename it themselves. Every path that was
--- hardcoded to "Mods/Packs/Modded Online/..." silently pointed at a folder that
--- does not exist on a fresh install — settings could not be saved and, worse,
--- the client bridge never launched, so joining ANY remote room just timed out
--- with nothing to show for it (`start` succeeds even when the script is
--- missing, so there was no error either).
---
--- Found by looking through the ENABLED packs for the one that actually
--- contains this mod. A disabled leftover copy is never picked, because
--- load_order.txt comments it out.
--- @return string # pack folder name, e.g. "fyi.modded-online"
local PACK_FINGERPRINT = "/src/modHost.lua" -- a file no other pack has
-- NOT shimInjector.lua: the parent pack ships that too, so it would match either
-- folder and this build could end up writing into the shipping mod's directory.
local FALLBACK_PACK_DIR = "fyi.modded-online-loader"
local packDir = nil
function PackDir()
    if packDir ~= nil then
        return packDir
    end
    packDir = FALLBACK_PACK_DIR
    pcall(function()
        -- `rawLine` then a local copy, matching netCore.shimVersions: assigning to a
        -- for-loop variable is legal in 5.4 but an error in later Lua, and this file
        -- is the one every other module loads first
        for rawLine in io.lines("Mods/Packs/load_order.txt") do
            local line = rawLine:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1, 2) ~= "--" then
                local probe = io.open("Mods/Packs/" .. line .. PACK_FINGERPRINT, "r")
                if probe ~= nil then
                    probe:close()
                    packDir = line
                    return
                end
            end
        end
    end)
    return packDir
end

--- A path inside our own pack, in the forward-slash form io.open wants.
--- @param rest string # e.g. "config.json"
--- @return string
function PackPath(rest)
    return "Mods/Packs/" .. PackDir() .. "/" .. rest
end

--- The same path in the backslash form `start`/`py` want on Windows.
--- @param rest string # e.g. "server/server.py"
--- @return string
function PackPathWin(rest)
    return (PackPath(rest):gsub("/", "\\"))
end

-- ------------------------------------------------------- the journal UI object

--- Which accessor actually worked, once we know. "" = not tried yet.
local gmVia = ""

--- The engine's GameManager, however this Playlunky build exposes it.
---
--- `get_game_manager()` is an Overlunky API that IS NOT PRESENT ON EVERY BUILD. On
--- the one this was found on it is not even a global: a capture of the journal probe
--- read back `attempt to call a nil value (global 'get_game_manager')`.
---
--- That mattered far beyond the probe. Two real features called it inside a bare
--- `pcall` and took the failure as "no journal open":
---
---   * `pollPlayFlow` waits for the death-recap book to finish animating before
---     launching character select. It never waited, which is the wedged
---     endless page-turn on CHOOSE ADVENTURER that the wait was added to stop.
---   * `pollCloseStrayJournal` force-closes a journal drawn over the character
---     select. It never closed one.
---
--- Both had been silently inert for the whole life of the build, because a `pcall`
--- around a missing global is indistinguishable from a legitimate "nothing here".
--- @return userdata?
function GameManager()
    if gmVia == "none" then
        return nil
    end
    local ok, gm = pcall(function()
        if type(rawget(_G, "get_game_manager")) == "function" then
            local m = get_game_manager()
            if m ~= nil then
                gmVia = "get_game_manager()"
                return m
            end
        end
        local m = rawget(_G, "game_manager")
        if m ~= nil then
            gmVia = "game_manager"
            return m
        end
        return nil
    end)
    if not ok or gm == nil then
        -- Latch the miss: this is called per frame from the journal polls, and a
        -- failing global lookup every frame for the life of the session is a cost
        -- with no information in it. Whichever accessor exists, exists at boot.
        if gmVia == "" then
            gmVia = "none"
        end
        return nil
    end
    return gm
end

--- The journal UI, or nil on a build that does not expose the GameManager.
--- @return userdata?
function JournalUI()
    local gm = GameManager()
    if gm == nil then
        return nil
    end
    local ok, ui = pcall(function() return gm.journal_ui end)
    if not ok then
        return nil
    end
    return ui
end

--- How the GameManager was reached, for the log: the accessor's name, "none" if no
--- accessor on this build works, or "untried".
--- @return string
function GameManagerVia()
    return gmVia ~= "" and gmVia or "untried"
end

MoUtil = module
return module
