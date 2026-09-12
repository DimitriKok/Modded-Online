--- Picking which mods to play online, from Playlunky's own options panel.
---
--- Before this, hosting a mod meant running `tools/spike2.py --setup` from a terminal:
--- junction three asset trees and three converted ones, edit `load_order.txt` by hand,
--- write a flag file, and know the pack's exact folder name. It also only ever knew
--- about one mod, because the pack name was a constant in the script.
---
--- Now every installed script pack gets a checkbox under Modded Online, and ticking
--- one does the whole arrangement. See src/packSetup.lua for what that arrangement is.
---
--- The one thing no amount of UI can hide: **Playlunky reads `load_order.txt` and
--- mounts asset trees once, at startup.** A mod ticked now is set up on disk now and
--- hosted on the next launch. Every message here says so, because a player who ticks
--- a box and sees nothing change will otherwise conclude it is broken.

local module = {}

--- How often to look at the checkboxes. They can only change while the player is in
--- Playlunky's options panel, so this is idle almost always; a quarter of a second is
--- far below noticing and far above the cost of a few table lookups.
local POLL_FRAMES = 15

local packs = {}        -- option key -> pack name
local order = {}        -- pack names, in the order they were registered
local frames = 0
local appliedSignature = nil
local deferred = nil    -- a selection waiting for the run to end

--- @param list string[]
--- @return string
local function signature(list)
    local copy = {}
    for index = 1, #list do
        copy[index] = list[index]
    end
    table.sort(copy)
    return table.concat(copy, "|")
end

--- @param fmt string
local function say(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[ModdedOnline] " .. line)
    if DesyncLog ~= nil and DesyncLog.line ~= nil then
        pcall(DesyncLog.line, "setup: %s", line)
    end
end

--- What the checkboxes currently say, in registration order.
--- @return string[]
function module.wanted()
    local chosen = {}
    for _, name in ipairs(order) do
        local key = PackSetup.optionKey(name)
        if rawget(_G, "options") ~= nil and options[key] == true then
            chosen[#chosen + 1] = name
        end
    end
    return chosen
end

--- Put a selection into effect and report what happened.
--- @param wanted string[]
--- @return nil
local function applyNow(wanted)
    local report = PackSetup.apply(wanted)
    -- The REQUEST, not what was accepted. A selection containing a second
    -- asset-bearing mod comes back one short, and remembering the short version
    -- would leave the poll below permanently seeing a difference -- re-running the
    -- whole arrangement, and spawning a handful of processes, four times a second.
    appliedSignature = signature(wanted)

    for _, note in ipairs(report.notes) do
        say(note)
    end
    for _, change in ipairs(report.changed) do
        say("load_order.txt: %s", change)
    end
    for _, step in ipairs(report.steps) do
        say("  %s", step)
    end
    if report.deferred then
        -- the swap could not happen: the running game holds the previous mod's
        -- files open. Nothing was changed, so the next launch retries it cleanly.
        say("NOTHING CHANGED YET. Close Spelunky and start it again -- the swap"
            .. " finishes on the next launch, before anything is mounted.")
        return
    end
    if #report.accepted == 0 then
        say("no mod is set up for online play. Modded Online will run on its own.")
    else
        say("set up for online play: %s", table.concat(report.accepted, ", "))
    end
    say("RESTART Playlunky for this to take effect -- the load order and the asset"
        .. " mounts are both read once, at startup.")
end

--- Apply if it is safe to, and remember it for later if it is not.
---
--- Never mid-run: applying deletes and re-creates the junctions the running game has
--- its textures mounted through, and rewrites the load order underneath a session
--- that is already using it.
--- @param wanted string[]
--- @return nil
local function requestApply(wanted)
    local inRun = false
    pcall(function()
        inRun = Network ~= nil and Network.isInRun ~= nil and Network.isInRun()
    end)
    if inRun then
        if deferred == nil or signature(deferred) ~= signature(wanted) then
            deferred = wanted
            say("selection noted -- it will be set up when you leave the run.")
        end
        return
    end
    deferred = nil
    applyNow(wanted)
end

--- @return nil
local function poll()
    frames = frames + 1
    if frames < POLL_FRAMES then
        return
    end
    frames = 0
    if deferred ~= nil then
        requestApply(deferred)
        return
    end
    local wanted = module.wanted()
    if signature(wanted) ~= appliedSignature then
        requestApply(wanted)
    end
end

--- Register a checkbox per installed script pack.
---
--- The default is whatever is armed on disk right now, so a player who set things up
--- with the old script sees the boxes already ticked rather than an empty panel that
--- disagrees with their game. Playlunky remembers the ticks after that.
--- @return nil
function module.install()
    if rawget(_G, "PackSetup") == nil then
        return
    end
    local armed = {}
    for _, name in ipairs(PackSetup.selection()) do
        armed[name] = true
    end
    order = PackSetup.installedScriptPacks()
    for _, name in ipairs(order) do
        local key = PackSetup.optionKey(name)
        packs[key] = name
        register_option_bool(key, "Play " .. name .. " online",
            "Host this mod inside Modded Online so everyone in the room runs the same"
            .. " code from the same seed. Ticking it disables the mod in load_order.txt"
            .. " (Modded Online runs it instead) and links its assets in."
            .. " Takes effect when you restart Playlunky.",
            armed[name] == true)
    end
    -- The escape hatch. A hosted mod defines its textures at load, and on at least
    -- one machine that call kills the process outright -- no Lua error, nothing in
    -- any log, and no way to catch it from Lua. Everything else here depends on
    -- having survived a boot to learn something; this does not.
    register_option_bool("mo_skip_textures",
        "Skip hosted mods' custom textures",
        "Tick this if the game crashes on startup while loading a hosted mod. The"
        .. " mod runs with the vanilla sprites instead of its own, which is a good"
        .. " deal better than a game that will not start. Everything else about the"
        .. " mod, including world generation, is unaffected.",
        false)

    register_option_button("mo_setup_clear", "Undo Modded Online's setup",
        "Unlink every hosted mod's assets and put back the load_order.txt lines"
        .. " Modded Online commented out. Use this if something goes wrong -- it"
        .. " leaves your mods exactly as they were.",
        function()
            for _, name in ipairs(order) do
                local key = PackSetup.optionKey(name)
                if rawget(_G, "options") ~= nil then
                    options[key] = false
                end
            end
            local report = PackSetup.clear()
            for _, change in ipairs(report.changed) do
                say("load_order.txt: %s", change)
            end
            for _, step in ipairs(report.steps) do
                say("  %s", step)
            end
            appliedSignature = ""
            say("setup undone. RESTART Playlunky to go back to playing the mods"
                .. " normally. Do this BEFORE disabling Modded Online in Modlunky --"
                .. " with it disabled we cannot run, and the assets would stay here"
                .. " and clash with the mod you re-enable.")
        end)

    -- Whatever an older version left in OUR pack, cleared on sight.
    --
    -- Both machines have this on disk: assets and Playlunky's converted output in
    -- the pack that also holds our code. Playlunky serves what is in a pack folder
    -- and keys the converted tree to the folder, not the load order, so both
    -- survived a switch AND being disabled -- one mod's textures turning up in
    -- another with Modded Online switched off entirely. The assets live in a
    -- teardown below removes them on sight; nothing of a mod outlives its hosting.
    local migrated = PackSetup.migrate()
    if #migrated > 0 then
        say("clearing what an earlier version left in this pack:")
        for _, step in ipairs(migrated) do
            say("  %s", step)
        end
    end

    -- Nothing hosted, but a mod's assets are still sitting about.
    --
    -- They must not outlive the hosting that needed them. Playlunky serves what is
    -- in a pack folder, so a mod re-enabled normally while our copy of its textures
    -- is still here means two packs supplying the same files -- which on one machine
    -- stopped the game booting at all, and on another booted it with the wrong
    -- textures and Modded Online switched off entirely.
    if #PackSetup.selection() == 0 and PackSetup.hasLeftovers() then
        say("nothing is hosted, but this pack still holds a mod's assets."
            .. " Clearing them -- left alone they would apply to your mods even"
            .. " with Modded Online switched off.")
        local report = PackSetup.clear()
        for _, step in ipairs(report.steps) do
            say("  %s", step)
        end
    end

    -- The state on disk IS the applied state; only a disagreement needs work.
    appliedSignature = signature(PackSetup.selection())

    -- A tick made in the last session that never got applied (the player quit from
    -- the options panel) is caught here, at the next boot, rather than being lost.
    local wanted = module.wanted()
    if signature(wanted) ~= appliedSignature then
        say("the mod selection changed since the last launch; setting it up now.")
        applyNow(wanted)
    else
        -- The selection can match while the arrangement is still incomplete: an
        -- update that starts carrying a new file across would otherwise wait for
        -- the player to toggle something. Nothing is unlinked here -- the mod
        -- owning the assets has not changed, so this only adds what is missing.
        local problems = {}
        for _, name in ipairs(PackSetup.selection()) do
            for _, problem in ipairs(PackSetup.setupProblems(name)) do
                problems[#problems + 1] = problem
            end
        end
        if #problems > 0 then
            say("the setup is incomplete (%s) -- rebuilding it now.",
                table.concat(problems, "; "))
            applyNow(wanted)
        end
    end

    set_callback(poll, ON.GUIFRAME)
end

SetupUI = module
return module
