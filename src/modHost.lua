--- Modded Online — content-mod host.
---
--- Runs another pack's Lua inside OUR Lua state, against an environment we build,
--- instead of prepending a determinism payload into that pack's `main.lua` on disk.
--- See LOADER.md for why; the short version is that Playlunky gives every pack its
--- own state with no channel between them, so patching a mod's environment from
--- outside is impossible and injection was the only way in. Owning the state
--- removes the need for either.
---
--- Nothing here runs on its own. `module.host()` is called deliberately, and in the
--- default (inert) mode every registration API is a recorder, so a hosted mod
--- cannot reach the engine at all. That is what makes Spike 1 safe to run in a live
--- game: it answers "does the module graph load, and what does it ask for" without
--- installing anything.
---
--- @class ModHostReport
--- @field ok boolean               # did the mod's main chunk run to completion
--- @field err string?              # first error, with the mod's own file and line
--- @field modules string[]         # module paths, in the order they were imported
--- @field callbacks table[]        # { api, event } for every registration attempted
--- @field missing string[]         # globals read that neither we nor the engine had
--- @field files integer            # chunks compiled
--- @field refused integer          # teardown calls for callbacks the mod did not own

local module = {}

--- ON.LOAD's id, for spotting the hosted mod's save-loading callback as it
--- registers. Read once through a pcall: `ON` is the engine's, and a build
--- without it must not take the boot down here.
local ON_LOAD = nil
pcall(function() ON_LOAD = ON.LOAD end)

--- Every ON.LOAD handler a hosted mod registered, in registration order.
--- @type function[]
module.loadHandlers = {}

--- The sandbox each hosted pack is running in, by pack folder name.
---
--- A mod's globals live here, not in `_G` -- `worldlib = require("lib.worldstate")`
--- in hdmod's main.lua is a WRITE, so it lands in the sandbox. Nothing outside could
--- read them, which is the gap LOADER.md flags for the 2.5 adapter ("the mod's world
--- counter is a value in its own module table, in our state, readable directly") and
--- which nothing actually provided.
--- @type table<string, table>
module.envs = {}

--- The determinism control for each hosted pack, which is what knows the adapters
--- that pack matched.
--- @type table<string, table>
module.controls = {}

--- @param packDir string
--- @return table? # the sandbox, or nil if that pack is not hosted
function module.envFor(packDir)
    return module.envs[packDir]
end

--- The adapters that recognised the door this run began at: { env, adapter, packDir }.
--- Rebuilt by every runStartedFromDoor, which is once per run start.
--- @type table[]
module.startDoorHits = {}

--- Say, in one line, what happened the last time a run start was dispatched.
--- Read by the desync log; kept as a plain string so nothing has to be recomputed.
--- @type string?
module.startDoorNote = nil

--- A start destination as one readable token for the log: "1-1(theme 1)", or
--- "none (the main exit)". `nil` and `{1,1,1}` are DIFFERENT things here and the log has to
--- show which one arrived -- confusing the two is the bug this whole path exists for.
--- @param dest table?
--- @return string
local function describeDest(dest)
    if type(dest) ~= "table" or dest[1] == nil then
        return "none (the main exit)"
    end
    return string.format("%s-%s(theme %s)", tostring(dest[1]), tostring(dest[2]),
        tostring(dest[3]))
end

--- Tell every hosted mod which camp door the run was started from.
---
--- Online a camp door is inert: Modded Online detects the press and starts the run
--- for the whole party rather than letting one player walk through, because one
--- player walking through would start a solo run. A mod that keys behaviour off a
--- player physically ENTERING a particular door therefore never sees it happen --
--- hdmod's tutorial is exactly that, and walking into its door online produced an
--- ordinary 1-1 instead of the tutorial.
---
--- Called on EVERY machine, so each one sets the mod's state for itself and the
--- world still generates identically everywhere.
---
--- EVERY outcome is logged, not just a hit. This ran silent for a whole debugging
--- session: the door was being dispatched correctly and the destination never
--- arrived (the server discarded a 1-1 door as "the main exit"), and from the
--- outside that is indistinguishable from a dispatch that never happened or an
--- adapter that never matched. A miss now says which of those it was.
--- @param dest table? # { world, level, theme } of the door, or nil for the main exit
--- @return integer # how many adapters recognised it
function module.runStartedFromDoor(dest)
    local applied = 0
    local hits = {}
    local notes = {}
    for packDir, control in pairs(module.controls) do
        local env = module.envs[packDir]
        if env == nil or control == nil or control.matched == nil then
            notes[#notes + 1] = string.format("%s: not hosted", tostring(packDir))
        else
            local ok, matched = pcall(control.matched)
            if not ok or type(matched) ~= "table" then
                notes[#notes + 1] = string.format("%s: no adapters matched this mod",
                    tostring(packDir))
            else
                local asked = 0
                for _, adapter in ipairs(matched) do
                    if adapter.startDoor ~= nil then
                        asked = asked + 1
                        local fired, hit, why = pcall(adapter.startDoor, env, dest)
                        if fired and hit then
                            applied = applied + 1
                            hits[#hits + 1] =
                                { env = env, adapter = adapter, packDir = packDir }
                            notes[#notes + 1] = string.format("%s/%s: RECOGNISED",
                                tostring(packDir), tostring(adapter.name))
                            dbg(string.format(
                                "mod host: %s recognised the start door (%s)",
                                packDir, tostring(adapter.name)))
                        else
                            notes[#notes + 1] = string.format("%s/%s: no (%s)",
                                tostring(packDir), tostring(adapter.name),
                                fired and tostring(why or "did not match")
                                    or "ERROR: " .. tostring(hit))
                        end
                    end
                end
                if asked == 0 then
                    notes[#notes + 1] = string.format(
                        "%s: none of this mod's adapters cares about start doors",
                        tostring(packDir))
                end
            end
        end
    end
    module.startDoorHits = hits
    module.startDoorNote = string.format("start door %s -> %d recognised | %s",
        describeDest(dest), applied,
        #notes > 0 and table.concat(notes, "; ") or "no mods are hosted")
    if DesyncLog ~= nil then
        pcall(DesyncLog.earlyEvent, "mod host: %s", module.startDoorNote)
        pcall(DesyncLog.traceNote, "mod host: %s", module.startDoorNote)
    end
    return applied
end

--- Re-apply what the recognised adapters did, at the last moment before the world
--- is built.
---
--- `runStartedFromDoor` has to run at run_start: it matches on the camp door, which
--- only exists until the warp. But the mod's own load and reset callbacks run
--- between that and generation, and hdmod's camp setup sets HD_WORLDSTATE_STATE
--- back to NORMAL -- so recognising the door was never enough on its own to
--- guarantee the state was still set when generation read it. Splitting it in two
--- means the recognition happens where the evidence is and the consequence happens
--- where it counts.
---
--- Identical on every machine (the hit list was built from the same ordered
--- run_start event everywhere), so it cannot desync generation.
--- @return integer # how many adapters re-applied
function module.reassertStartDoor()
    local applied = 0
    local notes = {}
    for _, hit in ipairs(module.startDoorHits) do
        if hit.adapter.reassert ~= nil then
            local ok, note = pcall(hit.adapter.reassert, hit.env)
            if ok then
                applied = applied + 1
                notes[#notes + 1] = string.format("%s/%s: %s", tostring(hit.packDir),
                    tostring(hit.adapter.name), tostring(note or "re-applied"))
            else
                notes[#notes + 1] = string.format("%s/%s: ERROR %s",
                    tostring(hit.packDir), tostring(hit.adapter.name), tostring(note))
            end
        end
    end
    if #notes > 0 and DesyncLog ~= nil then
        pcall(DesyncLog.earlyEvent, "mod host: start door re-asserted | %s",
            table.concat(notes, "; "))
        pcall(DesyncLog.traceNote, "mod host: start door re-asserted | %s",
            table.concat(notes, "; "))
    end
    return applied
end

--- Drop the recognised adapters. The run is over, so nothing may re-apply into the
--- next one -- a tutorial that leaked into the following run would be this bug
--- again with the sign flipped.
function module.forgetStartDoor()
    module.startDoorHits = {}
    module.startDoorNote = nil
end

--- Record the engine state a hosted mod's journal-chapter decision reads.
---
--- DIAGNOSTIC ONLY, and only while `mo_trace.on` is armed. It changes nothing and
--- returns nothing, so it cannot alter what the engine does with the chapter.
---
--- The crash this exists for: hdmod returns a 20-entry page list from
--- ON.POST_LOAD_JOURNAL_CHAPTER and the engine dies consuming it. Its own code
--- clamps that list to the pages revealed so far, but only when all four of
--- `chapter == STORY`, `is_prologue_active()`, `state.screen == SCREEN.LEVEL` and
--- `HD_WORLDSTATE_STATE == TUTORIAL` hold. Hosted, the clamp is skipped. Three of
--- those four are the mod's own state, which is why `module.envs` had to exist
--- before this could be asked at all.
---
--- Naming a specific mod's globals in the host is exactly what the adapter system in
--- determinism.lua is for, and this deliberately is NOT that: it is a probe with a
--- flag on it, reading values and writing a log line. Every read is pcall'd, because
--- a diagnostic that breaks the thing it is diagnosing is worse than none.
--- Write one line where a NATIVE CRASH OUTSIDE A RUN cannot take it with us.
---
--- The desync log is opened by `DesyncLog.init`, which runs from
--- `InputSync.beginSession` -- i.e. only when a networked RUN starts. This crash
--- happens in the lobby camp, before any run: `DesyncLog.line` drops everything
--- while `logPath` is nil, and `earlyEvent` buffers for "the next run's header"
--- that never comes. So the one sink the measurement needs is the one sink it
--- did not have.
---
--- Opened and CLOSED per line, so it is flushed to disk before the process dies --
--- an unflushed buffer is exactly how the last capture came back empty. Journal
--- CHAPTER loads are rare, so a file handle per line costs nothing.
---
--- Also `print`ed, which Playlunky captures into spelunky.log: two independent
--- sinks, because the whole point is surviving a process that is about to die.
--- One JournalUI field, or the reason it could not be read.
---
--- Every read here is pcall'd because a diagnostic that breaks the thing it is
--- diagnosing is worse than none -- but swallowing the error and printing "?" left
--- the first real capture saying two fields were unreadable and nothing about why.
--- The message distinguishes "no such field on this build" from "journal_ui is nil
--- at this point in the load", which are different findings.
--- @param field string
--- @return string
local function journalField(field)
    -- rawget, not a bare call: src.util defines JournalUI and this module must not
    -- assume it is loaded. A missing helper is a "cannot read", not an error --
    -- diagnosing the journal must never be the thing that breaks the boot.
    local resolve = rawget(_G, "JournalUI")
    local ui = type(resolve) == "function" and resolve() or nil
    if ui == nil then
        -- Not an error worth three identical copies per line: the capture that found
        -- this printed the same "attempt to call a nil value (global
        -- 'get_game_manager')" for every field, twice a line. Say it once, and say
        -- which accessor was tried.
        local via = rawget(_G, "GameManagerVia")
        return "n/a(GameManager via "
            .. (type(via) == "function" and tostring(via()) or "no helper") .. ")"
    end
    local ok, v = pcall(function()
        return tostring(ui[field])
    end)
    if ok then
        return v
    end
    -- The first capture of this printed "ERR(Mods/Packs/Modded Online DEV/src/
    -- modHost.lua:245: attempt to" -- sixty characters of which fifty-two were the
    -- path to this very file. Strip Lua's "file:line: " prefix and keep the part
    -- that says what actually went wrong.
    local msg = tostring(v):gsub("%s+", " ")
    msg = msg:match("^.-%.lua:%d+:%s*(.+)$") or msg
    return "ERR(" .. msg:sub(1, 90) .. ")"
end

--- @type integer
local journalNotesWritten = 0
local JOURNAL_NOTES_MAX = 400

--- @param fmt string
local function journalNote(fmt, ...)
    if journalNotesWritten >= JOURNAL_NOTES_MAX then
        return -- bounded like traceNote's own cap: a long session must not fill a disk
    end
    journalNotesWritten = journalNotesWritten + 1
    local ok, line = pcall(string.format, fmt, ...)
    line = ok and line or tostring(fmt)
    pcall(function()
        local h = io.open(PackPath("mo_journal.txt"), "a")
        if h ~= nil then
            h:write(os.date("[%H:%M:%S] ") .. line .. "\n")
            h:close()
        end
    end)
    pcall(print, "[ModdedOnline] " .. line)
end

--- @param name string # a flag file in the pack folder
--- @return boolean
local function flagPresent(name)
    local there = false
    pcall(function()
        -- PackPath(), not one of the *_FLAG locals: several of them are declared
        -- BELOW this point, so the name would resolve to a nil global and
        -- io.open(nil) would fail inside this very pcall -- a check that silently
        -- always says no.
        local h = io.open(PackPath(name), "r")
        if h ~= nil then
            h:close()
            there = true
        end
    end)
    return there
end

function module.installJournalProbe()
    -- ARMED BY ANY OF THREE, not by the tracer alone.
    --
    -- This used to require mo_trace.on, and the page OVERRIDE lives inside the
    -- callback it gates -- so `mo_nojournalpages.on` on its own installed nothing
    -- and the documented crash workaround silently did nothing. The one flag a
    -- player is told to create to stop the crash was inert without a second,
    -- undocumented flag that writes a file every frame.
    --
    -- mo_journalprobe.on is the cheap half on its own: it logs what the engine
    -- offered and what the mod returned, and overrides nothing. That is the
    -- measurement HANDOFF.md calls the missing one ("does the engine offer 8 pages
    -- standalone too?"), and needing the per-frame tracer to take it is why nobody
    -- has. This callback runs when a journal CHAPTER loads -- not per frame -- so
    -- it costs nothing to leave armed.
    local tracing, override, probe = false, false, false
    pcall(function()
        tracing = DesyncLog ~= nil and DesyncLog.tracing ~= nil and DesyncLog.tracing()
    end)
    override = flagPresent("mo_nojournalpages.on")
    probe = flagPresent("mo_journalprobe.on")
    if not (tracing or override or probe)
        or rawget(_G, "ON") == nil or ON.POST_LOAD_JOURNAL_CHAPTER == nil then
        return false
    end
    -- First line in the file, so "the probe never armed" and "the probe armed and
    -- the journal was never opened" are distinguishable. Without it an empty
    -- mo_journal.txt means both.
    journalNote("journal probe armed: trace=%s override=%s probe=%s",
        tostring(tracing), tostring(override), tostring(probe))
    set_callback(function(chapter, pages)
        -- `pages` is what the ENGINE had before the mod replaced it. Never looked at
        -- until now, and it is the one input to this whole sequence that comes from
        -- the engine rather than the mod -- so if hosting changes anything the
        -- engine knows about this journal, it shows up here.
        local incoming = "nil"
        pcall(function()
            if pages ~= nil then
                local n = #pages
                local head = {}
                for i = 1, (n < 8 and n or 8) do
                    head[#head + 1] = tostring(pages[i])
                end
                incoming = string.format("#%d { %s%s }", n,
                    table.concat(head, ", "), n > 8 and ", ..." or "")
            end
        end)
        pcall(function()
            local st = get_local_state()
            local bits = {}
            for _, packDir in ipairs(module.requestedPacks()) do
                local env = module.envs[packDir]
                if env ~= nil then
                    local prologue, worldState, tutorial = "?", "?", "?"
                    pcall(function()
                        prologue = tostring(env.camplib.is_prologue_active())
                    end)
                    pcall(function()
                        worldState = tostring(env.worldlib.HD_WORLDSTATE_STATE)
                        tutorial = tostring(env.worldlib.HD_WORLDSTATE_STATUS.TUTORIAL)
                    end)
                    bits[#bits + 1] = string.format(
                        "%s: prologue=%s worldstate=%s tutorial=%s",
                        packDir, prologue, worldState, tutorial)
                end
            end
            -- Built once and sent to BOTH sinks. traceNote only writes while the
            -- per-frame tracer is armed, so the one measurement this probe exists to
            -- take was only obtainable at the cost of a file write every frame --
            -- which is why it has never been taken. earlyEvent puts it in the desync
            -- log, where it survives the lobby and costs nothing.
            local line = string.format(
                "journal chapter %s | engine pages in: %s | screen=%s (LEVEL=%s"
                .. " CAMP=%s) level=%s theme=%s loading=%s | journal_ui state=%s"
                .. " page_shown=%s max_page_count=%s | %s",
                tostring(chapter), incoming, tostring(st.screen),
                tostring(SCREEN.LEVEL), tostring(SCREEN.CAMP), tostring(st.level),
                tostring(st.theme), tostring(st.loading),
                -- These came back "?" in the first real capture, which says the read
                -- FAILED and not what it failed on -- a diagnostic that cannot be
                -- debugged. Report the error instead of hiding it.
                journalField("state"), journalField("page_shown"),
                -- THE LEADING HYPOTHESIS for the mechanism. The engine offers 8 pages
                -- and hdmod returns 20; returning 8 with the mod's own ids does not
                -- crash, so it is the GROWTH that kills it, which means something
                -- downstream is sized for the count the engine passed in.
                -- `max_page_count` is the one writable field on JournalUI that could
                -- BE that size, and HANDOFF.md has flagged it unread for two
                -- sessions. If it reads 8 here, the fix is to raise it before
                -- returning a longer list rather than to truncate the journal.
                journalField("max_page_count"),
                #bits > 0 and table.concat(bits, " ; ") or "no hosted env")
            pcall(DesyncLog.traceNote, "%s", line)
            pcall(DesyncLog.earlyEvent, "%s", line)
            journalNote("%s", line)
        end)
        -- Normally returns NOTHING: a probe must not become a second opinion on the
        -- page list. Under the flag it deliberately does become one -- see
        -- NO_JOURNAL_PAGES_FLAG.
        if pages ~= nil then
            local restore = false
            pcall(function()
                -- PackPath() rather than the NO_JOURNAL_PAGES_FLAG local: this
                -- function is defined ABOVE that declaration, so the name would
                -- resolve to a nil GLOBAL and io.open(nil) would fail inside this
                -- very pcall -- an experiment that silently does not run.
                local h = io.open(PackPath("mo_nojournalpages.on"), "r")
                if h ~= nil then
                    h:close()
                    restore = true
                end
            end)
            if restore then
                -- The flag file's CONTENTS pick which property of the mod's
                -- substitution to reproduce, so one launch answers one question:
                --
                --   (empty)/restore  the engine's own list, unchanged -- the known
                --                    non-crashing control
                --   sameids          the engine's COUNT, but ids from 601 up: if
                --                    this crashes, the ID RANGE is what kills it
                --   grow             the mod's COUNT (20), but ids in the engine's
                --                    own range: if this crashes, GROWING the page
                --                    vector is what kills it
                --
                -- Exactly one of those two should crash. Both crashing means the
                -- two interact; neither means the substitution is innocent after all
                -- and something else about the mod's own return value matters.
                -- DEFAULT IS `sameids`, the mode that both stops the crash AND
                -- leaves the mod's own content on the page. It used to be `restore`
                -- (the engine's own list) -- which is the non-crashing CONTROL for an
                -- experiment, not the thing a player wants: the journal opens showing
                -- VANILLA pages instead of hdmod's. A capture of exactly that is what
                -- prompted this: the flag file was created empty, the crash stopped,
                -- and the content was silently wrong. `restore` is still available by
                -- writing it in the file.
                local mode = "sameids"
                pcall(function()
                    local h = io.open(PackPath("mo_nojournalpages.on"), "r")
                    if h ~= nil then
                        local body = h:read("*a") or ""
                        h:close()
                        body = body:gsub("%s+", "")
                        if body ~= "" then
                            mode = body
                        end
                    end
                end)
                local copy = {}
                pcall(function()
                    local n = #pages
                    if mode == "sameids" then
                        for i = 1, n do
                            copy[i] = 600 + i
                        end
                    elseif mode == "grow" then
                        for i = 1, 20 do
                            copy[i] = pages[((i - 1) % n) + 1]
                        end
                    else
                        for i = 1, n do
                            copy[i] = pages[i]
                        end
                    end
                end)
                local head = {}
                for i = 1, (#copy < 6 and #copy or 6) do
                    head[#head + 1] = tostring(copy[i])
                end
                local said = string.format(
                    "journal chapter %s: OVERRIDING the page list, mode=%s ->"
                    .. " #%d { %s%s } (mo_nojournalpages.on)", tostring(chapter),
                    mode, #copy, table.concat(head, ", "), #copy > 6 and ", ..." or "")
                pcall(DesyncLog.traceNote, "%s", said)
                pcall(DesyncLog.earlyEvent, "%s", said)
                journalNote("%s", said)
                return copy
            end
        end
    end, ON.POST_LOAD_JOURNAL_CHAPTER)

    -- Collapse state for the page-render probe below: one line per DISTINCT shape,
    -- with a count for the repeats. Declared here so both branches close over them.
    local lastRenderShape, renderRepeats = nil, 0

    -- ...and bracket the window the process actually dies in.
    --
    -- The chapter callback returns, and the engine is dead before the hosted mod's
    -- own RENDER_POST_JOURNAL_PAGE hook runs -- which is wrapped and marked, so the
    -- trace would name it otherwise. That leaves the engine's own page setup and its
    -- first page render, and nothing currently says which.
    --
    -- Marked as well as noted: if the process dies INSIDE a page render,
    -- crash_frame.txt says `IN journalPageProbe` instead of blaming the chapter
    -- callback that finished several steps earlier. Bounded by traceNote's own cap.
    if ON.RENDER_PRE_JOURNAL_PAGE ~= nil then
        set_callback(function(...)
            DesyncLog.frameMark("journalPageProbe")
            -- Built HERE, in the vararg function itself: `...` cannot be used inside
            -- a nested closure, and a pcall body is one.
            local bits = {}
            for i = 1, select("#", ...) do
                local v = select(i, ...)
                bits[#bits + 1] = type(v) == "userdata" and "<userdata>" or tostring(v)
            end
            pcall(DesyncLog.traceNote, "journal page render (%s)",
                table.concat(bits, ", "))
            -- The crash kills the process before hdmod's own RENDER_POST hook ever
            -- runs, so whether ANY page render was attempted is a fact the capture
            -- has to carry out of a dying process -- not one the desync log can hold.
            --
            -- COLLAPSED, because this fires every frame the journal is open. The
            -- first capture of a non-crashing journal spent all 400 lines on the
            -- identical line repeated -- roughly a second of rendering -- which is
            -- both useless and actively harmful: a crash after that point would have
            -- had nowhere left to write. What matters is THAT a render happened and
            -- with what arguments, not that it happened six hundred times.
            local shape = table.concat(bits, ", ")
            if shape ~= lastRenderShape then
                if renderRepeats > 0 then
                    journalNote("  ... and %d more identical page renders",
                        renderRepeats)
                end
                lastRenderShape = shape
                renderRepeats = 0
                journalNote("journal page render (%s)", shape)
                -- journal_ui is unreadable at POST_LOAD_JOURNAL_CHAPTER (every field
                -- came back "attempt to index a nil value" -- the UI does not exist
                -- yet at chapter-load time). Here it demonstrably does, because it is
                -- drawing. This is the one place max_page_count CAN be read, and it
                -- is the leading candidate for the size the grown list overflows.
                journalNote("  journal_ui at render: state=%s page_shown=%s"
                    .. " max_page_count=%s", journalField("state"),
                    journalField("page_shown"), journalField("max_page_count"))
            else
                renderRepeats = renderRepeats + 1
            end
            DesyncLog.frameDone("journalPageProbe")
            -- NOTHING returned: an explicit nil is what Playlunky rejects as
            -- "Unexpected return type from function", and `true` would skip the draw
        end, ON.RENDER_PRE_JOURNAL_PAGE)
    end
    return true
end

--- Hand a hosted mod its save data again, WITHOUT restarting the game.
---
--- Playlunky reads a pack's `save.dat` once, at script load, and passes it to
--- ON.LOAD. That is why a save arriving mid-session used to need a restart to
--- mean anything -- and a restart is not a thing you can ask of somebody who
--- just matchmade into a lobby.
---
--- Hosting removes the problem. The mod's ON.LOAD handler is an ordinary Lua
--- function in OUR state, so it can simply be called again. The context it
--- receives only has to answer `:load()`; the HD mod's handler (lib/save.lua)
--- calls exactly that, decodes the JSON, and re-runs its own migration, load and
--- post-load callbacks -- which is a full reload of its save state in place.
--- @param text string # the save.dat contents to load, or "" for an empty save
--- @return integer # how many handlers ran
function module.reloadSaveData(text)
    local context = { load = function() return text end }
    local ran = 0
    for _, handler in ipairs(module.loadHandlers) do
        -- pcall each: one mod's loader throwing must not strand the rest, and
        -- this runs on a peer that has just joined somebody else's room.
        if pcall(handler, context) then
            ran = ran + 1
        end
    end
    return ran
end

--- Registration APIs a Playlunky script can call. In inert mode each is replaced
--- with a recorder; in live mode they pass through to the engine. Recording rather
--- than erroring matters: a mod that fails to register keeps running, so one report
--- lists everything it wanted rather than stopping at the first call.
local REGISTRATION_APIS = {
    "set_callback",
    "set_pre_tile_code_callback",
    "set_post_tile_code_callback",
    "set_pre_entity_spawn",
    "set_post_entity_spawn",
    "set_vanilla_sound_callback",
    "set_global_interval",
    "set_interval",
    "set_timeout",
    "register_option_bool",
    "register_option_int",
    "register_option_float",
    "register_option_string",
    "register_option_combo",
    "register_option_button",
    "register_console_command",
}

--- Called with (moduleName, path) as each hosted module is about to run.
---
--- main.lua points this at the boot trace while hosting, so a mod that crashes the
--- process natively still leaves the name of the file that did it.
--- @type fun(key: string, path: string)?
module.onProgress = nil

--- The last line the previous boot managed to write, set by main.lua.
--- @type string?
module.lastFatalStep = nil

--- Stub every hosted texture definition, for a machine that crashes on one.
--- Set from a Playlunky checkbox, or by the flag file below.
--- @type boolean
module.skipTextures = false

--- The same thing as a FILE, which is the only form that helps here.
---
--- A checkbox has to be reached, ticked and SAVED through Playlunky's options
--- panel -- on a machine that crashes during boot, before the panel exists. Two
--- escape hatches were shipped that both needed the player to survive a boot
--- first, and neither engaged: the logs show no "previous boot stopped after"
--- line and no "option is on" line. Creating an empty file needs no game at all.
---
--- The same reasoning as `mo_host.on` itself, and for the same reason.
local NO_TEXTURES_FLAG = PackPath("mo_notextures.on")

--- Run a hosted mod against the RAW primitives: real `pairs`, real `math.random`,
--- the engine's own `get_frame`/`get_ms`, and no ON.FRAME remap.
---
--- This is a bisection tool, not a mode anyone should play in -- a networked run
--- with it on desyncs exactly as it did before any of this existed. It is here
--- because the sandbox rewrites four primitives under every hosted mod, and when
--- one of them breaks a mod there is otherwise no way to tell that apart from the
--- host plumbing (callback ownership, the import path, the teardown guards) without
--- editing source and relaunching four times.
---
--- A FILE, for the same reason `mo_host.on` is one: a mod that takes the game down
--- has to be recoverable without the game starting.
local NO_DETERMINISM_FLAG = PackPath("mo_nodeterminism.on")

--- Register a hosted mod's callbacks RAW, with no wrapper of ours around them.
---
--- Normally every hosted callback goes to the engine as `Callbacks.hosted(fn)` --
--- an extra Lua frame, a `pcall`, depth bookkeeping, profiling, and (while tracing)
--- a frame mark. That wrapper is the single largest thing hosting does that
--- Playlunky does not, and hdmod's journal story sequence is a nested storm of
--- callbacks registering and clearing each other from inside one another.
---
--- Dropping it is safe to TEST with: `depth` is only raised inside our OWN
--- callbacks, so when the engine dispatches a mod callback directly we are not
--- inside one and a bare `clear_callback()` still passes the guard in the teardown
--- wrapper below. What is lost is the crash trace naming the mod's callbacks, the
--- per-mod profile lines, and the re-raise of a Lua error as our own -- all
--- diagnostics, none of them behaviour the mod can see.
local NO_WRAP_FLAG = PackPath("mo_nowrap.on")

--- Put the ENGINE's own journal page list back, undoing a hosted mod's substitution.
---
--- hdmod replaces the story chapter's 8 real pages (ids 2..9) with 20 fabricated
--- ones (601..620) and draws them itself. That substitution is the last thing in
--- this path never tested rather than assumed, and the engine dies immediately after
--- accepting it. Our probe is registered after the mod's, so returning the original
--- list here overrides it -- IF Overlunky takes the last non-nil return rather than
--- the first, which this run also settles: a journal showing vanilla story pages
--- means ours won, hdmod's custom pages means it did not and the test is void.
---
--- Diagnostic. With it on the mod's journal is wrong on purpose.
local NO_JOURNAL_PAGES_FLAG = PackPath("mo_nojournalpages.on")

--- Calls known to kill this machine, remembered ACROSS boots.
---
--- The boot trace is truncated every launch, so reading the previous run's last
--- line only works if that run was the crash. One successful boot in between --
--- or moving the file somewhere to send it -- and the record is gone, which is
--- exactly what happened: a dev22 log with no "previous boot stopped after" line
--- and the same crash. A list that only grows does not have that problem.
local FATAL_CALLS_PATH = PackPath("mo_fatal_calls.txt")
local fatalCalls = nil

--- @return table<string, boolean>
local function knownFatalCalls()
    if fatalCalls ~= nil then
        return fatalCalls
    end
    fatalCalls = {}
    pcall(function()
        local handle = io.open(FATAL_CALLS_PATH, "r")
        if handle == nil then
            return
        end
        for line in handle:lines() do
            local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then
                fatalCalls[trimmed] = true
            end
        end
        handle:close()
    end)
    -- fold in whatever the last boot died on, and keep it for good this time
    if type(module.lastFatalStep) == "string" then
        local texture = module.lastFatalStep:match("define_texture%s+(%S+)")
        if texture ~= nil and not fatalCalls[texture] then
            fatalCalls[texture] = true
            pcall(function()
                local handle = io.open(FATAL_CALLS_PATH, "a")
                if handle == nil then
                    return
                end
                handle:write(texture .. "\n")
                handle:close()
            end)
        end
    end
    return fatalCalls
end

--- Are hosted texture definitions switched off, by any route?
---
--- Once ANY `define_texture` has been seen to kill this machine, none are attempted
--- again. Skipping only the exact call that died converges one launch at a time, and
--- hdmod defines around twenty cameo textures the same way -- a boot each. The first
--- crash is enough evidence: this engine build does not survive the call, and a mod
--- with vanilla sprites beats twenty more launches.
--- @return boolean
function module.texturesDisabled()
    if module.skipTextures then
        return true
    end
    if next(knownFatalCalls()) ~= nil then
        return true
    end
    local handle = io.open(NO_TEXTURES_FLAG, "r")
    if handle == nil then
        return false
    end
    handle:close()
    return true
end


--- Is the determinism layer switched off for hosted mods?
---
--- Reported in the desync-log header (`determinism=`) so a capture can never be read
--- as though the guarantees were in force when they were not.
--- @return boolean
function module.determinismDisabled()
    local handle = io.open(NO_DETERMINISM_FLAG, "r")
    if handle == nil then
        return false
    end
    handle:close()
    return true
end

--- Are hosted callbacks going to the engine unwrapped? See NO_WRAP_FLAG.
--- @return boolean
function module.wrapDisabled()
    local handle = io.open(NO_WRAP_FLAG, "r")
    if handle == nil then
        return false
    end
    handle:close()
    return true
end

--- Bare `clear_callback()` calls refused across every sandbox, for the revival log.
---
--- If callbacks of ours keep dying while this stays at zero, the bare form is NOT how
--- they are being reached and the guard below is guarding the wrong door.
local refusedBare = 0

--- @return integer
function module.refusedBareCount()
    return refusedBare
end

--- An option registration with no nils where a string belongs.
---
--- Only the two description slots are touched. The value that follows them may
--- legitimately be false, nil or a function depending on which option API this is,
--- and is passed through untouched.
--- @param id any
--- @param label any
--- @param longDesc any
--- @return any, any, any, ...
local function withOptionStrings(id, label, longDesc, ...)
    return id, label or "", longDesc or "", ...
end
--- Teardown APIs. A hosted mod shares OUR script, so these need mediating exactly
--- like registration does — see the note on `clear_callback` below.
local TEARDOWN_APIS = {
    "clear_callback",
    "clear_vanilla_sound_callback",
}

-- ---------------------------------------------------------------- module paths

--- Resolve a module path the way a Playlunky pack expects: dots are directories,
--- relative to the pack root. 2.5 imports `"src.game"` and also root-level modules
--- like `"sp25debug1"`, so both shapes have to work.
--- @param packDir string # pack folder name, e.g. "fyi.spelunky-25-2"
--- @param modulePath string
--- @return string
function module.resolve(packDir, modulePath)
    local rel = tostring(modulePath):gsub("%.", "/")
    return "Mods/Packs/" .. packDir .. "/" .. rel .. ".lua"
end

--- @param path string
--- @return string? source, string? err
local function readFile(path)
    local f, openErr = io.open(path, "r")
    if f == nil then
        return nil, tostring(openErr or ("cannot open " .. path))
    end
    local src = f:read("*a")
    f:close()
    if src == nil then
        return nil, "empty read: " .. path
    end
    return src, nil
end

-- ------------------------------------------------------------------ the sandbox

--- Build the environment a hosted mod runs in.
---
--- Writes land in the sandbox table, so the mod's globals (Sp25GameClass,
--- SP25_OPTIONS, CustomEntities, ...) never touch ours. Reads fall through to the
--- real `_G`, which is where the engine API lives. A read that finds nothing is
--- recorded rather than treated as an error, because mods legitimately probe for
--- optional globals — `POSTTILE_STARTBOOL ~= nil` is exactly that shape.
---
--- @param report ModHostReport
--- @param opts table? # { inert = boolean, overrides = table }
--- @return table
function module.newSandbox(report, opts)
    opts = opts or {}
    local inert = opts.inert ~= false -- inert unless explicitly told otherwise
    local env = {}

    -- Deliberately NOT a copy of _G. The mod gets its own table and reads what it
    -- does not define from the engine, so nothing it assigns can shadow ours.
    local seen = {}
    setmetatable(env, {
        __index = function(_, key)
            local v = rawget(_G, key)
            if v == nil and not seen[key] then
                seen[key] = true
                report.missing[#report.missing + 1] = tostring(key)
            end
            return v
        end,
    })

    env._G = env -- a mod that reaches for _G should get its own, not ours

    -- `meta` has to be the mod's OWN table, and this is the one global where the
    -- sandbox's read-through leaks.
    --
    -- Both Playlunky idioms look the same from here and are not. `meta = { ... }`
    -- is a write, so it lands in the sandbox and never reaches us. `meta.name =
    -- "HDMod"` is a READ of `meta` -- which __index answers with the real _G.meta
    -- -- followed by a field write on that table, which mutates OURS in place.
    -- hdmod (main.lua:67-70) and crossoverlunky (main.lua:1-4) both use the second
    -- form, and the proof is in the log header: a session hosting crossoverlunky
    -- opens `=== Modded Online 1.0 ===`, which is crossoverlunky's version written
    -- over ours.
    --
    -- It is not cosmetic. netCore builds the lobby compatibility handshake out of
    -- these two fields (`helloMsg.mod = meta.name`, `helloMsg.modv = meta.version
    -- .. " + " .. loadOrderSignature()`), so a hosted mod rewriting them disables
    -- the check that stops two DIFFERENT Modded Online builds sharing a room --
    -- every build reports the hosted mod's version instead of its own. And the
    -- desync-log header, which is how every save and desync fix in this build has
    -- been verified, then names the wrong version.
    --
    -- Seeded with the pack name so a mod that reads `meta.name` before setting it
    -- gets something true rather than "Modded Online (loader build)".
    env.meta = { name = tostring(opts.packDir or "hosted mod") }

    -- Which callback ids this mod registered. Under Playlunky a script can only
    -- ever clear its own callbacks, because a script IS the unit of ownership.
    -- Hosting breaks that: the mod's callbacks and ours now live in one script, and
    -- `Hooks.unhookAll()` runs on every floor.
    --
    -- That is not hypothetical. It cost a two-machine run: our
    -- ON.POST_LEVEL_GENERATION handler stopped firing after the first floor (4 of 14
    -- brackets in the log, against 18 of 18 under the old injected payload), which
    -- is where the per-floor seed is captured. The seed was never published, the
    -- reliable event stream head-of-line stalled behind it, and both machines
    -- eventually froze on 1-4 waiting for inputs that were never going to arrive.
    --
    -- So the sandbox tracks what the mod owns and refuses the rest. A bare
    -- `clear_callback()` with no id is passed straight through: it means "clear the
    -- callback currently running", and the only callbacks running the mod's code are
    -- the mod's own.
    local owned = {}

    for _, name in ipairs(REGISTRATION_APIS) do
        if inert then
            env[name] = function(...)
                report.callbacks[#report.callbacks + 1] = {
                    api = name,
                    event = select(2, ...),
                }
                return #report.callbacks -- callbacks return an id; hand back a plausible one
            end
        else
            -- Live: forward to the engine, but keep the tally. Registration happens
            -- per floor as well as at load (2.5 tears down and reinstalls its hooks
            -- in newLevelHooks), so this count is how you tell a mod that registered
            -- once at boot from one that is actually running.
            local real = rawget(_G, name)
            -- `set_callback` is the one global we have replaced: Callbacks records
            -- every registration WE make so a cleared one can be revived. The mod's
            -- registrations must NOT go in that book -- reviving the mod's callbacks
            -- behind its back would undo its own teardown -- and they must run with
            -- our callback depth zeroed, so that a bare `clear_callback()` inside one
            -- still reaches the engine and still clears the mod's own.
            local hostedWrap = nil
            if name == "set_callback" and Callbacks ~= nil then
                real = Callbacks.rawSetCallback
                if not module.wrapDisabled() then
                    hostedWrap = Callbacks.hosted
                end
            end
            -- Playlunky's option APIs take (id, label, long_desc, value). hdmod
            -- passes `nil` for long_desc, and a nil arriving where the binding
            -- wants a string is a native crash on some builds -- no Lua error, no
            -- log, nothing a pcall of ours can see. It costs nothing to hand over
            -- an empty string instead, and the option reads identically.
            local isOption = name:sub(1, 16) == "register_option_"
            if type(real) == "function" then
                env[name] = function(...)
                    report.callbacks[#report.callbacks + 1] = {
                        api = name,
                        event = select(2, ...),
                    }
                    -- named before the call, not after: if this is what kills the
                    -- process, the trace has to already say so
                    if module.onProgress ~= nil then
                        pcall(module.onProgress, name,
                            name .. " " .. tostring((select(1, ...))))
                    end
                    local first = ...
                    -- Keep the mod's ON.LOAD handler. Because the mod runs in
                    -- OUR state, this is an ordinary Lua function we hold a
                    -- reference to -- which is what makes reloading its save
                    -- data mid-session possible at all (see reloadSaveData).
                    if name == "set_callback" and type(first) == "function"
                        and ON_LOAD ~= nil and select(2, ...) == ON_LOAD then
                        module.loadHandlers[#module.loadHandlers + 1] = first
                    end
                    local id
                    if hostedWrap ~= nil and type(first) == "function" then
                        id = real(hostedWrap(first), select(2, ...))
                    elseif isOption then
                        id = real(withOptionStrings(...))
                    else
                        id = real(...)
                    end
                    if type(id) == "number" then
                        owned[id] = true
                    end
                    return id
                end
            end
        end
    end

    for _, name in ipairs(TEARDOWN_APIS) do
        local real = rawget(_G, name)
        if type(real) == "function" then
            env[name] = function(id, ...)
                -- An id that cannot exist is a no-op, not a refusal. hdmod clears
                -- `-1`, its stand-in for "no callback", and the engine ignores it.
                -- Refusing it changes nothing but did put an alarming ERROR line in
                -- the log at the exact moment of an unrelated crash.
                if type(id) == "number" and id <= 0 then
                    return nil
                end
                if id == nil then
                    -- "clear whichever callback is running right now". The comment
                    -- that used to sit here said "which is the mod's". That was true
                    -- under the shim, where the mod was a separate script with a
                    -- separate id space. Hosted, it shares ours, and if one of OUR
                    -- callbacks is on the stack this call destroys it: that is how a
                    -- single floor transition took out the network tick, the lockstep
                    -- gate and the floor digest at once and left the two machines on
                    -- different floors. 2.5 makes 38 of these calls.
                    --
                    -- Inside the mod's own callbacks our depth is zero (see
                    -- Callbacks.hosted), so the mod's own bare clears are unaffected.
                    if Callbacks ~= nil and Callbacks.depth() > 0 then
                        refusedBare = refusedBare + 1
                        report.refusedBare = (report.refusedBare or 0) + 1
                        if report.refusedBare == 1 then
                            errorf("mod host: refused a bare %s() raised while one of"
                                .. " Modded Online's own callbacks was running -- it"
                                .. " would have cleared ours, not the mod's", name)
                        end
                        return nil
                    end
                    return real()
                end
                if owned[id] then
                    owned[id] = nil
                    return real(id, ...)
                end
                report.refused = (report.refused or 0) + 1
                if report.refused == 1 then
                    -- once: a mod that tears down on every floor would say this
                    -- hundreds of times, and the first one is the informative one
                    errorf("mod host: refused a request to clear callback %s, which "
                        .. "the hosted mod did not register", tostring(id))
                end
                return nil
            end
        end
    end

    -- `define_texture` is the one engine call known to take the process down.
    --
    -- Overlunky resolves a relative `texture_path` against the pack root of the
    -- script that asks -- and hosted, that is OURS, not the mod's. If the file is
    -- not there the call dies in native code: no Lua error, no log line, nothing a
    -- pcall can catch. A boot trace ending inside `feats.lua`, whose only load-time
    -- act is `define_texture("res/locked_feat.png")`, is what led here.
    --
    -- So: check first, and refuse rather than crash. -1 is the value hdmod itself
    -- initialises its texture handles to, so a mod that reads one back gets
    -- something it already understands as "none".
    local realDefineTexture = rawget(_G, "define_texture")
    if not inert and type(realDefineTexture) == "function" then
        env.define_texture = function(tdef, ...)
            local texturePath = nil
            pcall(function()
                texturePath = tdef.texture_path
            end)
            if module.onProgress ~= nil then
                pcall(module.onProgress, "define_texture",
                    "define_texture " .. tostring(texturePath))
            end
            -- If the last boot died on THIS call, do not make it again.
            --
            -- A native crash cannot be caught, only avoided. The boot trace records
            -- each call before it is made, so the previous run's last line names
            -- the one that did not return -- and a mod missing one texture is a
            -- great deal better than a game that will not start.
            if module.texturesDisabled() then
                -- SKIPPED on purpose, which is not the same as missing. Filing these
                -- as "not found -- assets not linked in" sent the last diagnosis
                -- chasing an asset problem that did not exist: every one of them was
                -- present, hard-linked, and reported absent by this line.
                report.skippedTextures[#report.skippedTextures + 1] =
                    tostring(texturePath)
                if #report.missingTextures == 1 then
                    errorf("mod host: not defining %s's textures. A define_texture call"
                        .. " has crashed this machine before, so none are attempted --"
                        .. " the mod runs with vanilla sprites and everything else"
                        .. " intact. Delete mo_fatal_calls.txt in this pack to try"
                        .. " again.", tostring(opts.packDir or "the hosted mod"))
                end
                return -1
            end

            -- absolute paths are the engine's business, not ours
            if type(texturePath) == "string" and texturePath ~= ""
                and texturePath:match("^%a:") == nil then
                local probe = io.open(PackPath(texturePath), "rb")
                if probe == nil then
                    report.missingTextures[#report.missingTextures + 1] = texturePath
                    if #report.missingTextures == 1 then
                        errorf("mod host: %s asked for the texture %s, which is not"
                            .. " at %s. Its assets are not linked into this pack, or"
                            .. " are linked to a different mod. Skipping it --"
                            .. " letting the call through crashes the game.",
                            tostring(opts.packDir or "the hosted mod"),
                            texturePath, PackPath(texturePath))
                    end
                    return -1
                end
                probe:close()
            end
            return realDefineTexture(tdef, ...)
        end
    end

    -- Determinism goes on LAST of the built-ins, so it chains the host's own
    -- set_callback wrapper rather than being replaced by it. Explicit overrides
    -- still win, because a test that wants a stub generator has to be able to say so.
    if module.wrapDisabled() then
        -- Say it, for the same reason the determinism flag says it: a bisection
        -- switch left on silently is one that explains the next mystery wrongly.
        errorf("mod host: mo_nowrap.on is present -- %s's callbacks go to the engine"
            .. " RAW. The crash trace can no longer name them and the profile loses"
            .. " its `mod` lines. Delete the file when you are done.",
            tostring(opts.packDir or "the hosted mod"))
    end
    if module.determinismDisabled() then
        -- Say it out loud. A silent bisection switch is a switch that gets left on
        -- and then explains a desync nobody can account for.
        errorf("mod host: mo_nodeterminism.on is present -- %s runs on the RAW"
            .. " primitives (real pairs, real math.random, engine get_frame). This"
            .. " is for isolating a crash; a networked run WILL desync. Delete the"
            .. " file when you are done.", tostring(opts.packDir or "the hosted mod"))
    elseif opts.determinism ~= false and Determinism ~= nil then
        -- only while a room is actually running: see the note in determinism.lua.
        -- Forcing it in single-player gave every 1-1 the same level feeling.
        if opts.active == nil then
            opts.active = function()
                local net = rawget(_G, "Network")
                return net ~= nil and net.isInRun ~= nil and net.isInRun() == true
            end
        end
        report.determinism = Determinism.install(env, opts)
    end

    for key, value in pairs(opts.overrides or {}) do
        env[key] = value
    end
    return env
end

--- Does this source still carry a Modded Online block?
---
--- The shipping build used to prepend a determinism payload into other packs'
--- `main.lua`, and this used to hold a verbatim copy of all 27 versions so an
--- old block could be matched and removed by exact text. That is gone: hosting
--- replaced injection, nothing writes those blocks any more, and a mod still
--- carrying one is refused with an explanation rather than quietly repaired.
---
--- Exact-text matching had barely worked in any case -- only nine of the
--- twenty-seven versions were reachable, so a v21 block sailed through and ran
--- our own determinism a second time inside ours, which is a game that will not
--- boot. Detecting the marker needs none of that.
--- @param source string
--- @return string? marker
function module.ourBlockIn(source)
    return source:match("(%[ModdedOnline%-[^%]]+%])")
end

-- -------------------------------------------------------------- the import path

--- Give the sandbox the import functions a pack expects, sharing one module cache
--- so a module imported twice executes once — the same contract `require` has, and
--- what 2.5's SafeImport relies on.
---
--- @param env table
--- @param packDir string
--- @param report ModHostReport
--- @param sources table<string, string>? # module path -> source, tried before disk
local function installImports(env, packDir, report, sources)
    local loaded = {}   -- resolved FILE PATH -> { value }, not module name
    local dirStack = {} -- directories of the modules currently being loaded
    local absent = {}   -- module names with no file, so the disk is scanned once
    sources = sources or {}

    --- Where a module name might live, best guess first.
    ---
    --- A pack-root path is the documented shape and covers almost everything. But a
    --- module may also name a sibling: hdmod's `lib/journal/hdmod_journal.lua` does
    --- `require("journal_data")` for `lib/journal/journal_data.lua`, and elsewhere
    --- the SAME file is required as `lib.journal.journal_data`. Resolving only from
    --- the pack root failed the first spelling, which took the whole host down after
    --- six modules -- and hdmod's options never registered, so its own options GUI
    --- then indexed a nil and threw every frame.
    --- @param key string
    --- @return string[]
    local function candidatePaths(key)
        local rel = key:gsub("%.", "/") .. ".lua"
        local list = { "Mods/Packs/" .. packDir .. "/" .. rel }
        local dir = dirStack[#dirStack]
        if dir ~= nil and dir ~= "" then
            list[#list + 1] = dir .. "/" .. rel
        end
        return list
    end

    --- @param modulePath string
    --- @return any
    local function importModule(modulePath)
        local key = tostring(modulePath)
        -- An in-memory source wins over the file. The caller uses this to host a
        -- pack's own code when the file on disk carries something else as well --
        -- a Modded Online shim block, for instance, which would otherwise be
        -- measured as though it were part of the mod.
        local src, path = sources[key], nil
        if src ~= nil then
            path = module.resolve(packDir, key)
        elseif absent[key] then
            return nil
        else
            local tried = {}
            for _, candidate in ipairs(candidatePaths(key)) do
                tried[#tried + 1] = candidate
                local body = readFile(candidate)
                if body ~= nil then
                    src, path = body, candidate
                    break
                end
            end
            if src == nil then
                -- A module with no file is nil, NOT an error.
                --
                -- Both mods hosted so far ship a `require` for a file they do not
                -- include: 2.5 asks for `src.texture` and hdmod for
                -- `lib.entities.hdtype`, and neither file exists anywhere. Both run
                -- fine under Playlunky, and hdmod's is a bare `require` on line 42
                -- of its main.lua with nothing to catch a throw -- so Playlunky
                -- must hand back nil rather than raising. Raising instead took the
                -- host down seven modules in, before hdmod had registered its
                -- options, and its own options GUI then indexed a nil every frame.
                --
                -- A module that EXISTS and then fails to compile or throws is still
                -- an error. Only "there is no such file" is tolerated.
                absent[key] = true
                report.missingModules[#report.missingModules + 1] = key
                return nil
            end
        end
        -- Keyed on the resolved PATH, so the two spellings of one file share an
        -- instance. Keyed on the name they would not: hdmod would build its journal
        -- data twice and the second copy would be the one its GUI closed over.
        if loaded[path] ~= nil then
            return loaded[path].value
        end
        -- "@path" so a traceback names the MOD's file and line, not a chunk index
        local chunk, compileErr = load(src, "@" .. path, "t", env)
        if chunk == nil then
            error(string.format("compile '%s': %s", key, tostring(compileErr)), 0)
        end
        report.files = report.files + 1
        report.modules[#report.modules + 1] = key
        -- Say which file is about to run. A mod's code can take the game down in
        -- native code, where no pcall of ours will ever see it -- and then the only
        -- record of where it happened is whatever was written before the process
        -- died. Set by main.lua to the boot trace.
        if module.onProgress ~= nil then
            pcall(module.onProgress, key, path)
        end
        loaded[path] = { value = true } -- cached BEFORE running, so a cycle terminates
        dirStack[#dirStack + 1] = path:match("^(.*)/[^/]+$") or ""
        local ok, value = pcall(chunk)
        dirStack[#dirStack] = nil
        if module.onProgress ~= nil then
            -- so a trace ending on a module tells us whether it died INSIDE that
            -- file or in whatever ran next in the file that required it
            pcall(module.onProgress, key, path .. " [done]")
        end
        if not ok then
            loaded[path] = nil -- a module that threw is not a loaded module
            error(value, 0)
        end
        loaded[path] = { value = value }
        return value
    end

    env.import = importModule
    env.require = importModule

    --- 2.5's own wrapper: `SafeImport({ path = "src.game", debugLocation = ... })`.
    --- It swallows failures and records the module as skipped, so a hosted mod
    --- behaves the way it does under Playlunky rather than dying on the first gap.
    --- @param arg table|string
    env.SafeImport = function(arg)
        local path = type(arg) == "table" and arg.path or arg
        local ok, result = pcall(importModule, path)
        if ok then
            return result
        end
        report.skipped = report.skipped or {}
        report.skipped[#report.skipped + 1] = { path = tostring(path), err = tostring(result) }
        return nil
    end
end

-- ------------------------------------------------------------------- the report

--- Load a content mod's Lua into a sandbox and report what happened.
---
--- @param packDir string # pack folder name, e.g. "fyi.spelunky-25-2"
--- @param opts table? # { inert, entry, overrides, sources = {[path] = source} }
--- @return ModHostReport
function module.host(packDir, opts)
    opts = opts or {}
    --- @type ModHostReport
    local report = {
        ok = false, err = nil, modules = {}, callbacks = {}, missing = {}, files = 0,
        refused = 0, missingModules = {}, missingTextures = {},
        skippedTextures = {},
    }
    opts.packDir = packDir -- so the sandbox can name the mod in its own messages
    local env = module.newSandbox(report, opts)
    -- Kept so anything outside can read the mod's own globals: they are writes, so
    -- they land HERE and not in _G. See module.envs.
    module.envs[packDir] = env
    report.env = env
    installImports(env, packDir, report, opts.sources)

    local entry = opts.entry or "main"
    local ok, err = pcall(function()
        return env.require(entry)
    end)
    -- Adapters match on globals the mod defines, so they can only be looked for once
    -- its chunk has run.
    if report.determinism ~= nil then
        pcall(report.determinism.detectAdapters)
        -- kept so the adapters this mod matched can be reached later, from the run
        -- lifecycle rather than from generation -- see module.runStartedFromDoor
        module.controls[packDir] = report.determinism
    end
    report.ok = ok
    if not ok then
        report.err = tostring(err)
    end
    return report
end

--- One-line-per-fact summary for the console. Spike 1 is read, not asserted, so the
--- output has to be legible on its own.
--- @param report ModHostReport
--- @return string[]
function module.summarize(report)
    local out = {}
    out[#out + 1] = string.format(
        "mod host: %s | %d modules, %d chunks, %d registrations, %d unknown globals%s",
        report.ok and "LOADED" or "FAILED",
        #report.modules, report.files, #report.callbacks, #report.missing,
        (report.refused or 0) > 0
            and string.format(", %d foreign teardowns refused", report.refused) or "")
    if report.err ~= nil then
        out[#out + 1] = "  first error: " .. report.err
    end
    -- Modules the mod asked for that it does not ship. Not errors -- Playlunky
    -- hands back nil for these too -- but worth naming, because a mod quietly
    -- running without one of its own libraries is worth knowing about.
    if #(report.missingTextures or {}) > 0 then
        out[#out + 1] = "  TEXTURES NOT FOUND under this pack -- its assets are not"
            .. " linked in, or are linked to another mod: "
            .. table.concat(report.missingTextures, ", ")
    end
    if #(report.skippedTextures or {}) > 0 then
        out[#out + 1] = string.format(
            "  %d texture definitions skipped on purpose (see the line above); the"
            .. " files themselves are present", #report.skippedTextures)
    end
    if #(report.missingModules or {}) > 0 then
        out[#out + 1] = "  modules the mod asks for but does not ship: "
            .. table.concat(report.missingModules, ", ")
    end
    for _, entry in ipairs(report.skipped or {}) do
        out[#out + 1] = string.format("  skipped %s: %s", entry.path, entry.err)
    end
    if #report.missing > 0 then
        -- these are the Playlunky per-pack APIs we have not emulated, which is the
        -- entire point of the spike
        local shown = {}
        for i = 1, math.min(#report.missing, 24) do
            shown[i] = report.missing[i]
        end
        out[#out + 1] = "  globals not found: " .. table.concat(shown, ", ")
            .. (#report.missing > 24 and (" (+" .. (#report.missing - 24) .. " more)") or "")
    end
    return out
end

--- Run the spike and print it. Deliberately not called from anywhere: this is a
--- development entry point, invoked by hand.
--- @param packDir string?
function module.spike(packDir)
    local report = module.host(packDir or "fyi.spelunky-25-2", { inert = true })
    for _, line in ipairs(module.summarize(report)) do
        print("[ModdedOnline] " .. line)
    end
    return report
end

-- ------------------------------------------------------------------ Spike 3

local HOST_FLAG_PATH = PackPath("mo_host.on")
local DEFAULT_PACK = "fyi.spelunky-25-2"

--- Packs this session actually loaded and is running. Read by netCore: a hosted mod
--- is DISABLED in load_order.txt, so every check that walks that file for "the
--- content mods in play" would otherwise miss it entirely — including the
--- compatibility signature, whose whole job is proving both machines run the same
--- mods. Two players on different builds of a hosted mod would have matched.
---
--- Only packs that loaded are listed. If hosting failed here and succeeded there,
--- the signatures SHOULD differ: one machine is running that mod and the other is not.
local hosted = {}

--- @return string[]
function module.hostedPacks()
    local out = {}
    for i = 1, #hosted do
        out[i] = hosted[i]
    end
    return out
end

--- Which pack to host this session, or nil for none.
---
--- A flag FILE rather than a setting, and deliberately so: if hosting a mod takes
--- the game down before a menu can be drawn, deleting a file is the only recovery
--- that does not need the game to start. Its contents name the pack; an empty file
--- means the default.
--- @return string?
function module.requestedPack()
    local names = module.requestedPacks()
    return names[1]
end

--- Every pack to host this session, one per line in the flag file.
---
--- It held a single name until the options panel arrived, and the old reader stripped
--- ALL whitespace -- which would have welded two lines into one nonexistent pack name
--- rather than failing visibly. Splitting is the whole difference.
---
--- Several mods can be hosted together as long as at most one of them ships assets;
--- PackSetup.plan is what enforces that, because the asset folders are junctioned
--- into our pack under their own names and two mods cannot both own "Data".
--- @return string[]
function module.requestedPacks()
    local names = {}
    pcall(function()
        local f = io.open(HOST_FLAG_PATH, "r")
        if f == nil then
            return
        end
        local body = f:read("*a") or ""
        f:close()
        for raw in body:gmatch("[^\r\n,]+") do
            local name = raw:gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then
                names[#names + 1] = name
            end
        end
        if #names == 0 then
            names[1] = DEFAULT_PACK -- an empty file means "the usual one"
        end
    end)
    return names
end

--- Host the requested pack for real: registrations reach the engine.
---
--- Called once from main.lua. Wrapped so that a mod which fails to load takes
--- itself down and not Modded Online's networking with it -- the whole point of
--- hosting is that we are in a position to contain the failure, which is more than
--- the injected payload could ever do.
--- @return ModHostReport? # the LAST pack's report, or nil if nothing was hosted
function module.autoHost()
    local reports = nil
    for _, packDir in ipairs(module.requestedPacks()) do
        reports = module.hostOne(packDir) or reports
    end
    return reports
end

--- @param packDir string
--- @return ModHostReport?
function module.hostOne(packDir)
    if packDir == nil then
        return nil -- no flag file; this build behaves exactly like the shipping one
    end
    local mainSrc = nil
    pcall(function()
        local f = io.open("Mods/Packs/" .. packDir .. "/main.lua", "r")
        if f == nil then
            return
        end
        mainSrc = f:read("*a")
        f:close()
    end)
    if mainSrc == nil then
        errorf("mod host: %s has no readable main.lua", packDir)
        return nil
    end
    -- Never host a pack Playlunky is ALSO running.
    --
    -- Hosting requires the mod disabled in load_order.txt. If that edit did not
    -- take -- the file was read-only, the name did not match, the player re-enabled
    -- it in Modlunky afterwards -- the mod runs twice: once as its own script and
    -- once inside ours. Every callback fires twice and every texture is defined
    -- twice, and the second `define_texture` of the same texture is not something
    -- the engine survives.
    if Network ~= nil and Network.enabledScriptPacks ~= nil then
        for _, enabled in ipairs(Network.enabledScriptPacks()) do
            if enabled == packDir then
                errorf("mod host: NOT hosting %s -- it is still ENABLED in"
                    .. " load_order.txt, so Playlunky is running it too. Running it"
                    .. " twice defines every texture twice and crashes the game."
                    .. " Disable %s in Modlunky, leaving Modded Online enabled.",
                    packDir, packDir)
                return nil
            end
        end
    end

    if PackSetup ~= nil and PackSetup.setupProblems ~= nil then
        local problems = PackSetup.setupProblems(packDir)
        if #problems > 0 then
            errorf("mod host: NOT hosting %s -- its setup is incomplete: %s."
                .. " Untick it under Modded Online, restart, tick it again and"
                .. " restart once more. Hosting it in this state crashes the game"
                .. " with nothing in any log.", packDir, table.concat(problems, "; "))
            return nil
        end
    end

    local residual = module.ourBlockIn(mainSrc)
    if residual ~= nil then
        errorf("mod host: NOT hosting %s -- its main.lua still contains a Modded"
            .. " Online block, %s. Running it would load that block's determinism"
            .. " logic a second time, inside ours, and the game will not boot."
            .. " Reinstall %s to get a clean main.lua.", packDir, residual, packDir)
        return nil
    end

    local report = SafeCall("modHost:autoHost", module.host, packDir, {
        inert = false,
        sources = { main = mainSrc },
    })
    if report == nil then
        errorf("mod host: %s did not load -- see the traceback above", packDir)
        return nil
    end
    if report.ok then
        hosted[#hosted + 1] = packDir
    end
    for _, line in ipairs(module.summarize(report)) do
        print("[ModdedOnline] " .. line)
    end
    if DesyncLog ~= nil and DesyncLog.line ~= nil then
        pcall(DesyncLog.line, "mod host: %s %s with %d modules and %d registrations",
            packDir, report.ok and "loaded" or "FAILED", #report.modules, #report.callbacks)
    end
    return report
end

ModHost = module
return module
