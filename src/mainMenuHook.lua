--- Modded Online — MODDED ONLINE as a row of the game's own main menu.
---
--- The main menu's rows live in a list the script API does not expose (ScreenMenu's
--- `menu_tree`, each row a string and a native select function), so no row can be
--- added. Instead the ONLINE row is taken over:
---
---   * its label (string hash 0xa1023681, "Online", used nowhere else) reads MODDED
---     ONLINE while the main menu is up, and the game's own text everywhere else;
---   * a SELECT press on it is swallowed before the game sees it (menuInput hides the
---     menu input), and the MODDED ONLINE menu opens instead;
---   * VANILLA ONLINE, inside our menu, gives the game's Online menu back: the label is
---     restored and one SELECT press is handed to the game on that row.
---
--- The row order is Play, Online, Options, Leaderboards, Player Profile, Quit Game
--- (strings00 lines 85-90, and the hanging icons on menu_basic in the same order), so
--- ONLINE is `selected_menu_index` 1. If a press on another row ever opens the
--- game's Online menu, that row is ONLINE on this build and is used from then on.
---
--- Nothing here installs at load. The first input call on the title screen or main
--- menu checks that every piece it needs exists and answers; if any does not,
--- `active()` is false, the reason is logged once, and menuUI shows its [O] chip
--- instead, as before. A self-check stands the takeover down the same way if the game
--- opens its Online menu despite a press we swallowed, and says in the log where the
--- press was swallowed and what the menu did next.
---
--- Times are on the clock (get_ms), not in calls: menuInput calls this from the input
--- callback, and how often that runs is not something to bet a time-out on.

local module = {}

local ONLINE_HASH = 0xa1023681
local MENU_MAIN, MENU_ONLINE = 0, 2
local STATE_INTRO_MAX = 4      -- 0..4: the Cthulhu intro and the move into the menu
local STATE_IDLE = 7
local STATE_TO_SUBMENU = 8
local INJECT_TIMEOUT_MS = 1000 -- for the handed-over press to open Online
local FAIL_WINDOW_MS = 700     -- after a press, in which a submenu opening is its result
local LANG_CHECK_MS = 1000     -- between label checks while on the main menu
local PENDING_MAX_MS = 3000    -- longer than this without an install means none is coming
local FLAG = "mo_nomenuhook.on"

module.ONLINE_HASH = ONLINE_HASH
module.INJECT_TIMEOUT_MS = INJECT_TIMEOUT_MS
module.FAIL_WINDOW_MS = FAIL_WINDOW_MS

local SELECT = 1
pcall(function()
    if type(MENU_INPUT) == "table" and type(MENU_INPUT.SELECT) == "number" then
        SELECT = MENU_INPUT.SELECT
    end
end)

local installed = nil       --- @type boolean? # nil until the first input call on a menu
local whyNot = nil          --- @type string?
local pendingSinceMs = nil  --- @type number?

--- What decide() remembers between calls.
local st = {
    onlineRow = 1,          -- selected_menu_index of the ONLINE row
    stage = nil,            --- @type string? # the VANILLA ONLINE hand-over: release|inject|injected|vanilla
    stageMs = 0,
    swallowMs = nil,        --- @type number? # when we last swallowed a press on ONLINE
    swallowState = nil,     --- @type integer? # the menu's state at that press
    selectMs = nil,         --- @type number? # when a press on another row went through
    selectIndex = nil,      --- @type integer?
}
module.state = st

-- ------------------------------------------------------------------- decide

--- What to do now. Pure apart from `stt` (the state above, passed in so the tests can
--- drive it) and `out`, which it fills:
---
---   out.label   want the MODDED ONLINE label now
---   out.swallow hide this frame's menu input from the game
---   out.open    open the MODDED ONLINE menu
---   out.inject  hand the game one SELECT press (VANILLA ONLINE)
---   out.fail    the takeover did not hold: why
---   out.relearn the ONLINE row is really this index
---   out.note    something worth a log line
---
--- `s` is this call's snapshot: screen, menuId, state, index, transferTo, the game's
--- `now`/`prev` input bits, `ms` (the clock), `capturing` (our UI is up) and `via`
--- (which callback hides the input, for the failure's log line).
--- @return table
function module.decide(s, stt, out)
    out.label, out.swallow, out.open, out.inject = false, false, false, false
    out.fail, out.relearn, out.note = nil, nil, nil
    if s.screen ~= SCREEN.MENU then
        stt.stage, stt.swallowMs, stt.selectMs = nil, nil, nil
        return out
    end
    local main = s.menuId == MENU_MAIN
    local onlineOpening = s.menuId == MENU_ONLINE
        or (s.state == STATE_TO_SUBMENU and s.transferTo == MENU_ONLINE)

    -- VANILLA ONLINE: the game's own label, until its Online menu has come and gone
    if stt.stage == "release" then
        out.swallow = true
        if s.now == 0 then
            stt.stage, stt.stageMs = "inject", s.ms
        end
        return out
    elseif stt.stage == "inject" then
        if main and s.state == STATE_IDLE and s.index == stt.onlineRow then
            out.inject = true
            stt.stage, stt.stageMs = "injected", s.ms
        elseif not main or s.index ~= stt.onlineRow then
            stt.stage = nil
            out.note = "VANILLA ONLINE abandoned: the menu moved off the ONLINE row"
        elseif s.ms - stt.stageMs > INJECT_TIMEOUT_MS then
            stt.stage = nil
            out.note = "VANILLA ONLINE abandoned: the menu never settled"
        end
        return out
    elseif stt.stage == "injected" then
        if onlineOpening then
            stt.stage = "vanilla"
        elseif s.ms - stt.stageMs > INJECT_TIMEOUT_MS then
            stt.stage = nil
            out.note = "VANILLA ONLINE: the game's Online menu did not open"
        end
        return out
    elseif stt.stage == "vanilla" then
        if main and s.state == STATE_IDLE then
            stt.stage = nil
        else
            return out
        end
    end

    out.label = main

    -- Did a submenu that just opened come from a press we let through, or from one
    -- we swallowed? The first teaches us which row is ONLINE; the second means
    -- swallowing does not work here.
    if stt.swallowMs ~= nil then
        if s.ms - stt.swallowMs > FAIL_WINDOW_MS then
            stt.swallowMs = nil
        elseif onlineOpening then
            out.fail = module.failReason(s, stt)
            stt.swallowMs = nil
            return out
        end
    end
    if stt.selectMs ~= nil then
        if s.ms - stt.selectMs > FAIL_WINDOW_MS then
            stt.selectMs = nil
        elseif onlineOpening then
            if stt.selectIndex ~= stt.onlineRow then
                out.relearn = stt.selectIndex
            end
            stt.selectMs = nil
        end
    end

    local edge = (s.now & SELECT) ~= 0 and (s.prev & SELECT) == 0
    if main and edge and not s.capturing then
        if s.index == stt.onlineRow and s.state == STATE_TO_SUBMENU
            and s.transferTo == MENU_ONLINE then
            -- The menu is already on its way to Online with the very press we are
            -- looking at: it read the input before this callback ran, and nothing
            -- written here can reach it in time.
            out.fail = string.format("the game took the press before %s ran (the menu"
                .. " was already moving to Online)", tostring(s.via))
            return out
        elseif s.index == stt.onlineRow and s.state > STATE_INTRO_MAX
            and s.state <= STATE_IDLE then
            -- 5 and 6 can still take a press; swallow it there, but only open on idle
            out.swallow = true
            stt.swallowMs, stt.swallowState = s.ms, s.state
            out.open = s.state == STATE_IDLE
        elseif s.state == STATE_IDLE then
            stt.selectMs, stt.selectIndex = s.ms, s.index
        end
    end
    return out
end

--- The self-check's log line: where the press was swallowed, and what the menu was
--- doing when it turned out the game had taken it anyway.
--- @return string
function module.failReason(s, stt)
    return string.format("the game opened its own Online menu after a press that was"
        .. " swallowed (in %s, at menu state %s; %d ms later the menu was id %s, state %s,"
        .. " moving to %s)", tostring(s.via), tostring(stt.swallowState),
        math.floor(s.ms - (stt.swallowMs or s.ms)), tostring(s.menuId), tostring(s.state),
        tostring(s.transferTo))
end

-- -------------------------------------------------------------------- label

local labelText = nil      --- @type string? # what we wrote
local originalText = nil   --- @type string? # the game's own text, for putting back
local labelOn = false
local lastLabelCheckMs = -1000000

--- MODDED ONLINE in the casing the game uses for the row: capitals unless the game's
--- own text has a lowercase letter. Not `original:upper()`: that is the C locale's
--- toupper, which under a non-C locale rewrites the bytes of UTF-8 text, so a
--- Japanese label would never compare equal to itself.
--- @param original string
--- @return string
function module.labelFor(original)
    if original:find("[a-z]") ~= nil then
        return "Modded Online"
    end
    return "MODDED ONLINE"
end

--- @param text string?
--- @return boolean
local function isOurLabel(text)
    return text == "MODDED ONLINE" or text == "Modded Online"
end

--- @return integer
local function onlineId()
    return hash_to_stringid(ONLINE_HASH)
end

local function applyLabelUnsafe()
    local now = get_ms()
    if labelOn and now - lastLabelCheckMs < LANG_CHECK_MS then
        return
    end
    lastLabelCheckMs = now
    local id = onlineId()
    local current = get_string(id)
    if labelText ~= nil and current == labelText then
        labelOn = true
        return
    end
    if isOurLabel(current) then
        -- written by an earlier copy of this script in the same game (a reload)
        originalText = originalText or (current == "MODDED ONLINE" and "ONLINE" or "Online")
    elseif type(current) == "string" and current ~= "" then
        -- the game's own text: the first time, or the table was reloaded by a
        -- language change, which wipes every edit
        originalText = current
    end
    labelText = module.labelFor(originalText or "Online")
    change_string(id, labelText)
    labelOn = true
end

local function restoreLabelUnsafe()
    if not labelOn then
        return
    end
    labelOn = false
    local id = onlineId()
    -- only while our label is still there: after a language change the game's own
    -- (new) text is back already, and writing the old language over it would be wrong
    if originalText ~= nil and get_string(id) == labelText then
        change_string(id, originalText)
    end
end

-- ------------------------------------------------------------------ install

--- @param reason string
local function report(reason)
    if DesyncLog ~= nil and DesyncLog.earlyEvent ~= nil then
        DesyncLog.earlyEvent("main menu takeover: %s", reason)
    end
    if MenuProbe ~= nil and MenuProbe.note ~= nil then
        MenuProbe.note("mainMenuHook: %s", reason)
    end
    dbg("main menu takeover: " .. reason)
end

--- Stand the takeover down: the game's own label back, our menu closed (with the
--- game's menu answering the same presses underneath, it could only fight it), and
--- menuUI's [O] chip.
--- @param reason string
function module.disable(reason)
    pcall(restoreLabelUnsafe)
    if installed == false then
        return
    end
    installed = false
    whyNot = reason
    st.stage = nil
    if NetMenuUI ~= nil and NetMenuUI.isOpen ~= nil and NetMenuUI.isOpen() then
        NetMenuUI.close()
    end
    errorf("MODDED ONLINE is not in the main menu on this build (%s); press O on the"
        .. " main menu instead", reason)
    report("OFF -- " .. reason)
end

--- @param path string
--- @return boolean
local function flagPresent(path)
    local there = false
    pcall(function()
        local h = io.open(PackPath(path), "r")
        if h ~= nil then
            h:close()
            there = true
        end
    end)
    return there
end

--- @param gm userdata
--- @return integer, integer, integer, integer
local function readMenu(gm)
    local m = gm.screen_menu
    return math.floor(m.state), math.floor(m.menu_id), math.floor(m.selected_menu_index),
        math.floor(m.transfer_to_menu_id)
end

--- @return string?
local function via()
    return MenuInput ~= nil and MenuInput.via ~= nil and MenuInput.via() or nil
end

--- @param gm userdata
--- @return string? # why not, or nil when everything is here
local function checkInstall(gm)
    -- `.on.txt` too: what Windows Explorer makes of "mo_nomenuhook.on" with
    -- extensions hidden
    if flagPresent(FLAG) or flagPresent(FLAG .. ".txt") then
        return FLAG .. " is present"
    end
    if MenuInput == nil or not MenuInput.available() then
        return "the menu input can't be read or written ("
            .. tostring(MenuInput ~= nil and MenuInput.why() or "module missing") .. ")"
    end
    for _, name in ipairs({ "change_string", "get_string", "hash_to_stringid" }) do
        if type(rawget(_G, name)) ~= "function" then
            return name .. " is missing"
        end
    end
    local ok, text = pcall(function() return get_string(onlineId()) end)
    if not ok then
        return "the ONLINE label can't be read: " .. tostring(text)
    end
    if type(text) ~= "string" or text == "" then
        return "the ONLINE label is empty"
    end
    local okMenu, err = pcall(readMenu, gm)
    if not okMenu then
        return "the main menu can't be read: " .. tostring(err)
    end
    return nil
end

--- @param gm userdata
local function install(gm)
    local reason = checkInstall(gm)
    if reason ~= nil then
        installed = false
        whyNot = reason
        report("OFF -- " .. reason)
        return
    end
    installed = true
    report(string.format("ON -- the ONLINE row (index %d) opens MODDED ONLINE; input hidden"
        .. " in %s", st.onlineRow, tostring(via())))
end

--- Is the takeover in place? nil while it has not been tried yet (the first input
--- call on a menu installs it), then true or false. A build where that call never
--- comes is a false after a few seconds, so the menu can never be left unreachable.
--- @return boolean?
function module.active()
    if installed ~= nil then
        return installed
    end
    if MenuInput ~= nil and MenuInput.via ~= nil and MenuInput.via() == nil then
        installed = false
        whyNot = "this build has no callback to read the menu input from"
        report("OFF -- " .. whyNot)
        return false
    end
    local now = get_ms()
    pendingSinceMs = pendingSinceMs or now
    if now - pendingSinceMs > PENDING_MAX_MS then
        installed = false
        whyNot = "the input callback never ran to install it"
        report("OFF -- " .. whyNot)
    end
    return installed
end

--- Why it is not in place, for the log and the tests.
--- @return string?
function module.why()
    return whyNot
end

-- --------------------------------------------------------------------- calls

local snap = { screen = nil, menuId = -1, state = -1, index = -1, transferTo = -1,
               now = 0, prev = 0, ms = 0, capturing = false, via = nil }
local out = {}

--- One input call while none of our UI is up (menuInput calls this). Returns the
--- input pair to write -- 0, 0 to hide it -- or nothing to leave the game's own.
--- @param gm userdata
--- @param now integer # the game's input_menu
--- @param prev integer # its input_menu_previous
--- @return integer?, integer?
function module.onInput(gm, now, prev)
    local okState, ls = pcall(get_local_state)
    if not okState or ls == nil then
        return nil
    end
    snap.screen = ls.screen
    if installed == nil then
        -- Not during the logos and the intro: the label is read to prove the string
        -- table answers, and a read before the game has it would switch the takeover
        -- off for the whole session.
        if snap.screen ~= SCREEN.TITLE and snap.screen ~= SCREEN.MENU then
            return nil
        end
        install(gm)
    end
    if installed ~= true then
        return nil
    end
    if snap.screen == SCREEN.MENU then
        local ok, state, menuId, index, transferTo = pcall(readMenu, gm)
        if not ok then
            module.disable("the main menu stopped answering: " .. tostring(state))
            return nil
        end
        snap.state, snap.menuId, snap.index, snap.transferTo = state, menuId, index, transferTo
    end
    snap.now, snap.prev, snap.ms = now, prev, get_ms()
    snap.capturing = NetMenuUI ~= nil and NetMenuUI.capturing ~= nil and NetMenuUI.capturing()
    snap.via = via()
    module.decide(snap, st, out)

    if out.fail ~= nil then
        module.disable(out.fail)
        return nil
    end
    if out.relearn ~= nil then
        report(string.format("the ONLINE row is index %d, not %d -- using %d from now on",
            out.relearn, st.onlineRow, out.relearn))
        st.onlineRow = out.relearn
    end
    if out.note ~= nil then
        report(out.note)
    end

    local okLabel, err
    if out.label then
        okLabel, err = pcall(applyLabelUnsafe)
    else
        okLabel, err = pcall(restoreLabelUnsafe)
    end
    if not okLabel then
        module.disable("the ONLINE label can't be changed: " .. tostring(err))
        return nil
    end

    if out.open then
        if MenuProbe ~= nil and MenuProbe.note ~= nil then
            MenuProbe.note("mainMenuHook: SELECT on ONLINE swallowed, opening MODDED ONLINE")
        end
        if NetMenuUI ~= nil and NetMenuUI.open ~= nil then
            NetMenuUI.open("main menu")
        end
    end
    if out.inject then
        if MenuProbe ~= nil and MenuProbe.note ~= nil then
            MenuProbe.note("mainMenuHook: handing SELECT on ONLINE to the game (VANILLA ONLINE)")
        end
        return now | SELECT, prev & ~SELECT
    end
    if out.swallow then
        return 0, 0
    end
    return nil
end

--- One input call while our UI is up. menuInput hides the input itself then, so the
--- only job left here is the self-check: the press that opened our menu was
--- swallowed, and if the game opens its Online menu anyway, swallowing does not work
--- on this build -- both menus would answer every press from then on.
--- @param gm userdata
function module.watch(gm)
    if installed ~= true or st.swallowMs == nil then
        return
    end
    local now = get_ms()
    if now - st.swallowMs > FAIL_WINDOW_MS then
        st.swallowMs = nil
        return
    end
    local okState, ls = pcall(get_local_state)
    if not okState or ls == nil or ls.screen ~= SCREEN.MENU then
        return
    end
    local ok, state, menuId, _, transferTo = pcall(readMenu, gm)
    if ok and (menuId == MENU_ONLINE or (state == STATE_TO_SUBMENU and transferTo == MENU_ONLINE)) then
        snap.ms, snap.via = now, via()
        snap.state, snap.menuId, snap.transferTo = state, menuId, transferTo
        local reason = module.failReason(snap, st)
        st.swallowMs = nil
        module.disable(reason)
    end
end

--- VANILLA ONLINE: close our menu and let the game open its own Online menu.
function module.requestVanillaOnline()
    if Network ~= nil and Network.isActive ~= nil and Network.isActive() then
        pcall(Network.leave)
        pcall(toast, "Left the Modded Online room")
    end
    pcall(restoreLabelUnsafe)
    st.stage, st.stageMs = "release", get_ms()
    st.swallowMs, st.selectMs = nil, nil
    if NetMenuUI ~= nil and NetMenuUI.close ~= nil then
        NetMenuUI.close()
    end
end

-- The label is the game's own text everywhere but the main menu, and when this
-- script is switched off.
if ON ~= nil and ON.SCREEN ~= nil then
    set_callback(function()
        local ok, ls = pcall(get_local_state)
        if ok and ls ~= nil and ls.screen ~= SCREEN.MENU then
            pcall(restoreLabelUnsafe)
        end
    end, ON.SCREEN)
end
if ON ~= nil and ON.SCRIPT_DISABLE ~= nil then
    set_callback(function()
        pcall(restoreLabelUnsafe)
        st.stage = nil
    end, ON.SCRIPT_DISABLE)
end

MainMenuHook = module
return module
