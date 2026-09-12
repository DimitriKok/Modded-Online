-- Modded Online (LOADER BUILD) — self-hosted online play for scriptable mods.
--
-- Forked from 1.0.22 / determinism shim v28 to build one change: stop injecting a
-- determinism payload into other packs' main.lua, and run their Lua inside THIS
-- state instead, against an environment we construct. Read LOADER.md first — it is
-- the whole brief, including the facts the approach rests on and what must not
-- regress. src/modHost.lua is the path; the injector it replaced was deleted in
-- 2.0.0-dev42, once the loader had carried real runs.
--
-- This build is listed in load_order.txt as DISABLED on purpose. Two enabled copies
-- would both bind the UDP port, both register every callback, and PackDir() would
-- resolve to whichever the load order reached first.

meta = {
    name = "Modded Online (loader build)",
    version = "2.0.0-dev54",
    description = "Play scriptable mods together via a self-hosted server",
    author = "EatYoCake + DoctorPuppy",
    online_safe = false, -- not for the *official* online — that's the point
    unsafe = true,       -- udp_listen/udp_send and settings persistence need unsafe mode
}

-- ------------------------------------------------------------------ boot trace
--
-- A breadcrumb file, written and FLUSHED at every step of loading, for the failure
-- mode that leaves nothing else behind: the game dying during boot with no Lua error
-- and nothing in spelunky.log. A player on the far end of that cannot tell whether
-- the crash was in our code, in a hosted mod, or in Playlunky before either ran.
--
-- It lives in the GAME ROOT rather than in the pack, on purpose: it has to be
-- openable before `src.util`, which is where PackDir lives, so it cannot ask which
-- pack it belongs to. Being easy to find and send is a second reason.
--
-- Everything here is pcall'd and degrades to a no-op. `io` is absent unless
-- Playlunky granted unsafe mode, and a diagnostic that breaks the boot in order to
-- report a boot problem would be worse than no diagnostic.
local BOOT_LOG = "modded_online_boot.log"
local bootStep

--- The last line the previous boot managed to write, if it never reached READY.
--- Handed to modHost below so a native crash can be stepped around rather than
--- merely described: a call that did not return last time is not made again.
local unfinished = nil

do
    -- what last time managed before it stopped, read BEFORE this run truncates it
    pcall(function()
        local previous = io.open(BOOT_LOG, "r")
        if previous == nil then
            return
        end
        local body = previous:read("*a") or ""
        previous:close()
        local last = nil
        for line in body:gmatch("[^\r\n]+") do
            last = line
        end
        if last ~= nil and last:find("READY", 1, true) == nil then
            unfinished = last
        end
    end)

    local handle = nil
    pcall(function()
        handle = io.open(BOOT_LOG, "w")
    end)

    bootStep = function(step)
        if handle == nil then
            return
        end
        pcall(function()
            handle:write(step .. "\n")
            handle:flush() -- every step: a crash would take a buffer with it
        end)
    end

    bootStep("Modded Online " .. tostring(meta.version) .. " boot")
    if unfinished ~= nil then
        -- say it where the player will see it, not only in a file they must be told
        -- to look for
        pcall(print, "[ModdedOnline] THE PREVIOUS BOOT DID NOT FINISH. It stopped"
            .. " after: " .. unfinished .. "  --  see " .. BOOT_LOG
            .. " in your Spelunky 2 folder.")
        bootStep("previous boot stopped after: " .. unfinished)
    end
end

bootStep("require src.util")
require("src.util")

local MODULES = {
    -- FIRST, and it has to stay first: it replaces the global `set_callback` so that
    -- every registration the modules below make is recorded and can be revived. A
    -- hosted mod shares our callback id space and can destroy ours by accident.
    "src.callbacks",
    "src.json",
    "src.netCore",
    "src.desyncLog",
    -- Before packSetup, which seeds through it, and before modHost, whose
    -- requestedPacks() the SYNC SAVE DATA button reads.
    "src.saveShare",
    "src.inputSync",
    "src.eventSync",
    "src.menuUI",
    "src.chat",
    -- The determinism guarantees a hosted mod runs under. Loaded before modHost,
    -- which installs them into every sandbox it builds.
    "src.determinism",
    -- Choosing which mods to host, and arranging the disk so they can be. Loaded
    -- before modHost because modHost reads the flag file this maintains.
    "src.packSetup",
    "src.setupUI",
    -- The replacement for the one above. Hosting still does not happen at load: it
    -- happens below, and only when mo_host.on exists.
    "src.modHost",
}

for _, path in ipairs(MODULES) do
    bootStep("require " .. path)
    SafeCall("main/require " .. path, require, path)
end
bootStep("all modules loaded")

-- Two enabled copies of Modded Online is a configuration nothing downstream can
-- survive: both bind the UDP port, both register every callback, and PackDir()
-- resolves to whichever the load order reached first. It is an easy state to end up
-- in -- install the loader build without disabling the one already there -- and it
-- looks from the outside like the new build simply crashing on boot.
bootStep("checking for a second Modded Online")
if Network ~= nil and Network.enabledScriptPacks ~= nil then
    for _, name in ipairs(Network.enabledScriptPacks()) do
        if name:lower():find("modded", 1, true) ~= nil
            and name:lower():find("online", 1, true) ~= nil then
            pcall(print, "[ModdedOnline] '" .. name .. "' is ALSO enabled. Two copies"
                .. " of Modded Online cannot run together -- both bind the same UDP"
                .. " port and register every callback twice. Disable one in Modlunky.")
            bootStep("WARNING: a second Modded Online is enabled: " .. name)
        end
    end
end

-- Crash-trace: mark the start of the ENGINE's simulation update. Registered HERE,
-- after every module, so it is the LAST ON.PRE_UPDATE callback to run — the first
-- attempt marked this inside inputSync's PRE_UPDATE and chat's PRE_UPDATE (which
-- registers later) promptly overwrote it, so every crash still read
-- `OUT preUpdate:chat` and the marker taught us nothing. From here until
-- ON.POST_UPDATE the engine + every content mod's per-entity update runs, so a
-- crash showing `IN engineUpdate` is provably NOT in Modded Online's own code.
set_callback(function()
    if DesyncLog ~= nil then
        DesyncLog.frameMark("engineUpdate")
    end
end, ON.PRE_UPDATE)

-- The mod picker: a checkbox per installed script pack in Playlunky's options
-- panel. Runs BEFORE autoHost so that a selection made last session, but never
-- applied because the player quit straight from the options panel, is arranged now
-- rather than lost.
-- `SetupUI.install` rather than SetupUI.install: if that module failed to load,
-- indexing nil here would take the boot down while REPORTING a boot problem, and the
-- trace would stop on a line blaming the picker for someone else's fault.
bootStep("setupUI: registering the mod picker")
if SetupUI ~= nil then
    SafeCall("setupUI:install", SetupUI.install)
else
    bootStep("setupUI: MODULE MISSING, skipped")
end

-- Run each selected content mod's Lua inside THIS state, with its registrations
-- reaching the engine, instead of prepending a determinism payload into its
-- main.lua. Does nothing unless mo_host.on names a pack -- see src/modHost.lua for
-- why that is a file and not a setting.
-- Named one at a time: hosting a mod runs someone else's code, and if that is what
-- takes the game down, the last line of the trace should say whose.
if ModHost == nil then
    bootStep("modHost: MODULE MISSING, nothing can be hosted")
else
    ModHost.lastFatalStep = unfinished
    -- read straight from the option rather than through SetupUI, so it still works
    -- if the picker itself failed to load
    if rawget(_G, "options") ~= nil and options.mo_skip_textures == true then
        ModHost.skipTextures = true
        bootStep("skipping hosted textures (option is on)")
    end
    -- say it in the trace, so a log answers "was the switch actually on?" without
    -- anyone having to ask
    bootStep("hosted textures: "
        .. (ModHost.texturesDisabled() and "DISABLED (mo_notextures.on)" or "on"))
    for _, packDir in ipairs(ModHost.requestedPacks()) do
        bootStep("hosting " .. packDir)
        -- name each of the mod's own files as it runs. 2.5 is 56 modules and hdmod
        -- 199; if one of them takes the process down natively, this is the only
        -- thing that will have recorded which.
        ModHost.onProgress = function(_, path)
            bootStep("  " .. packDir .. ": " .. tostring(path))
        end
        SafeCall("modHost:hostOne", ModHost.hostOne, packDir)
        ModHost.onProgress = nil
        bootStep("hosted " .. packDir)
    end
end

-- A probe, armed only by mo_trace.on, over the journal-chapter load. Registered
-- AFTER hosting, because it reads the hosted mods' own globals out of their
-- sandboxes -- which do not exist until they have run.
if ModHost ~= nil and ModHost.installJournalProbe ~= nil then
    bootStep("modHost: journal probe (mo_trace.on only)")
    SafeCall("main/installJournalProbe", ModHost.installJournalProbe)
end

-- If the last session ended while borrowing a room host's save -- left cleanly,
-- crashed, or simply closed -- the files were put back when src.saveShare loaded,
-- but the MOD was handed its save data by Playlunky before any of our Lua ran and
-- is still holding the host's state. Re-run its loader from the restored file,
-- here, because this is the first moment the mod exists to be re-run.
if SaveShare ~= nil and SaveShare.finishStartupRestore ~= nil then
    bootStep("saveShare: finishing any restore from the last session")
    SafeCall("main/finishStartupRestore", SaveShare.finishStartupRestore)
end

-- ...and seed anything the pack is simply missing. packSetup only seeds when it
-- APPLIES, so a mod armed under an older build never got its save files at all --
-- which is how a peer came to borrow with nothing of its own to give back.
if SaveShare ~= nil and SaveShare.seedHosted ~= nil then
    bootStep("saveShare: seeding any missing save files")
    SafeCall("main/seedHosted", SaveShare.seedHosted)
end

bootStep("READY")
dbg("Modded Online " .. meta.version .. " loaded — open the main menu to host or join")
