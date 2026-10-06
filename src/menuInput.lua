--- Modded Online — the game's own menu input, for our menus and popups.
---
--- `game_manager.game_props.input_menu` is what drives every vanilla menu: one set of
--- bits (SELECT, BACK, LEFT, RIGHT, UP, DOWN, ...) filled from whichever device the
--- player uses, keyboard bindings and controllers alike. Reading it is how the
--- MODDED ONLINE menu answers a controller the way the game's own menus do.
---
--- While one of our menus or popups is up, the field is read and then ZEROED, so the
--- vanilla menu underneath sees nothing and stays exactly where it was (highlighted
--- on the row that opened us).
---
--- WHERE that happens is the whole difficulty, and dev68 got it wrong. It zeroed the
--- field in PRE_UPDATE -- the point inputSync uses for a transition's menu input --
--- and put the device's value back at POST_UPDATE. The main menu does not read its
--- input between those two: the first press on MODDED ONLINE still opened the game's
--- own Online menu, and the self-check stood the takeover down (desync log, 16:47:25:
--- "the game opened its own Online menu after a press that was swallowed"). Either it
--- reads before PRE_UPDATE, or after POST_UPDATE, where the put-back value handed it
--- the very press we had hidden.
---
--- So now: the work happens in ON.POST_PROCESS_INPUT, straight after the game builds
--- the field (the script API names it as the place to edit menu input), and nothing
--- is ever put back. Whatever reads the field after that, wherever it sits in the
--- frame, reads our zero. PRE_UPDATE zeroes it again in case anything refilled it in
--- between. On a build without POST_PROCESS_INPUT, PRE_UPDATE does all of it, still
--- without the put-back. A button still held when we let go is not a new press for the
--- game either way: the release latch keeps swallowing until it is let go.
---
--- inputSync writes the field only during a run and this module never does, so the
--- two never share a frame. This module is the only writer of `input_menu` outside a
--- run: mainMenuHook decides what to do with the main menu's input and hands the
--- write back here.
---
--- Keyboard: while our UI is up menuUI sets `get_io().wantkeyboard`, which takes the
--- keyboard away from the game, so `input_menu` then carries the controller only and
--- the keyboard is read through get_io() as before. Nothing is counted twice.
--- `KEYBOARD_IN_MENU_INPUT` is for a build where that turns out not to hold (the menu
--- probe's capture mode measures it).

local module = {}

--- true: keyboard presses still reach `input_menu` while the keyboard is captured, so
--- navigation is read from it alone and get_io() is used only for typing.
module.KEYBOARD_IN_MENU_INPUT = false

--- MENU_INPUT, from the engine's enum where it has one. These literals are the same
--- values inputSync uses for MENU_SYNC_MASK.
local BIT = { SELECT = 1, BACK = 2, DELETE = 4, RANDOM = 8, JOURNAL = 16,
              LEFT = 32, RIGHT = 64, UP = 128, DOWN = 256 }
pcall(function()
    if type(MENU_INPUT) == "table" then
        for name in pairs(BIT) do
            if type(MENU_INPUT[name]) == "number" then
                BIT[name] = MENU_INPUT[name]
            end
        end
    end
end)
module.BIT = BIT

--- Directions repeat while held: the first press, then after REPEAT_DELAY_MS, every
--- REPEAT_EVERY_MS. Counted on the clock, not in calls, because how often the input
--- callback runs (per engine update, or per display frame) is not something to bet
--- the feel of the menu on.
local REPEAT_DELAY_MS = 300
local REPEAT_EVERY_MS = 70
module.REPEAT_DELAY_MS = REPEAT_DELAY_MS
module.REPEAT_EVERY_MS = REPEAT_EVERY_MS

local DIRS = {
    { bit = BIT.UP, name = "up" },
    { bit = BIT.DOWN, name = "down" },
    { bit = BIT.LEFT, name = "left" },
    { bit = BIT.RIGHT, name = "right" },
}

--- Actions waiting for the next GUI frame. The input callback can run several times
--- between two GUI frames (or not at all), so presses are queued rather than flagged.
local QUEUE_MAX = 16
local queue, queueRepeat, queueLen = {}, {}, 0

--- After our UI closes, keep swallowing until the buttons are let go: the BACK that
--- closed the menu must not reach the vanilla menu, which would leave for the title.
local RELEASE_MAX_MS = 1000
local RELEASE_MIN_CALLS = 2

--- Per direction: 0 not held, -1 held since before capture (silent until let go),
--- otherwise the clock time of its next repeat.
local timers = { up = 0, down = 0, left = 0, right = 0 }
local prevDevice = 0         -- the device's bits at the last call, for our own edges
local broken = nil           --- @type string? # why this module stood down
local latchUntilMs = nil     --- @type number?
local latchCalls = 0
local zeroedThisFrame = false -- the input callback hid the field; PRE_UPDATE keeps it hidden

--- Which callback reads and hides the input on this build.
local VIA = (ON ~= nil and ON.POST_PROCESS_INPUT ~= nil) and "POST_PROCESS_INPUT"
    or ((ON ~= nil and ON.PRE_UPDATE ~= nil) and "PRE_UPDATE" or nil)

--- @return string? # "POST_PROCESS_INPUT", "PRE_UPDATE", or nil when neither exists
function module.via()
    return VIA
end

--- One call's actions from the device's bits. Pure: `timersT` carries the hold state
--- between calls, and `emit(action, isRepeat)` receives each action.
--- @param held integer # the device's bits now
--- @param prev integer # the device's bits at the last call (ours, not the engine's field)
--- @param timersT table
--- @param emit fun(action: string, isRepeat: boolean)
--- @param nowMs number
function module.step(held, prev, timersT, emit, nowMs)
    for i = 1, #DIRS do
        local dir = DIRS[i]
        local t = timersT[dir.name] or 0
        if (held & dir.bit) ~= 0 then
            if t == 0 then
                emit(dir.name, false)
                t = nowMs + REPEAT_DELAY_MS
            elseif t > 0 and nowMs >= t then
                emit(dir.name, true)
                t = nowMs + REPEAT_EVERY_MS
            end
        else
            t = 0
        end
        timersT[dir.name] = t
    end
    local pressed = held & ~prev
    if (pressed & BIT.SELECT) ~= 0 then
        emit("select", false)
    end
    if (pressed & BIT.BACK) ~= 0 then
        emit("back", false)
    end
end

--- @param action string
--- @param isRepeat boolean
local function push(action, isRepeat)
    if queueLen >= QUEUE_MAX then
        return
    end
    queueLen = queueLen + 1
    queue[queueLen] = action
    queueRepeat[queueLen] = isRepeat
end

--- Hand every queued action to `fn(action, isRepeat)`, oldest first, and empty the
--- queue. Called from the GUI frame.
--- @param fn fun(action: string, isRepeat: boolean)
function module.drain(fn)
    local n = queueLen
    queueLen = 0
    for i = 1, n do
        fn(queue[i], queueRepeat[i])
    end
end

--- Drop anything queued (our UI closed with presses still waiting).
function module.clear()
    queueLen = 0
end

--- Our UI just opened. The press that opened it is still held, and is not a press for
--- the new page: our edges are already measured from it, and any direction held now
--- stays silent until released.
function module.beginCapture()
    queueLen = 0
    for i = 1, #DIRS do
        local dir = DIRS[i]
        timers[dir.name] = ((prevDevice & dir.bit) ~= 0) and -1 or 0
    end
end

--- Our UI just closed: keep the vanilla menu blind until the buttons are released.
function module.releaseLatch()
    latchUntilMs = get_ms() + RELEASE_MAX_MS
    latchCalls = 0
end

--- Can this module read and write the menu input on this build?
--- @return boolean
function module.available()
    return broken == nil and VIA ~= nil
end

--- Why not, for the log.
--- @return string?
function module.why()
    if broken ~= nil then
        return broken
    end
    if VIA == nil then
        return "this build has neither ON.POST_PROCESS_INPUT nor ON.PRE_UPDATE"
    end
    return nil
end

--- @param reason string
local function markBroken(reason)
    if broken ~= nil then
        return
    end
    broken = reason
    errorf("menu input unavailable on this build (%s); MODDED ONLINE falls back to the"
        .. " [O] key", reason)
    if DesyncLog ~= nil and DesyncLog.earlyEvent ~= nil then
        DesyncLog.earlyEvent("menu input DISABLED: %s", reason)
    end
    if MenuProbe ~= nil and MenuProbe.note ~= nil then
        MenuProbe.note("menuInput: DISABLED: %s", reason)
    end
    if MainMenuHook ~= nil and MainMenuHook.disable ~= nil then
        MainMenuHook.disable("menu input: " .. reason)
    end
end

--- A named function rather than a closure, so the per-call pcall allocates nothing
--- (the same reason as inputSync's readMenuFields).
--- @param gm userdata
--- @return userdata, integer, integer
local function readPair(gm)
    local props = gm.game_props
    return props, math.floor(tonumber(props.input_menu) or 0),
        math.floor(tonumber(props.input_menu_previous) or 0)
end

--- `previous` FIRST, like inputSync's writeMenuFields: the engine finds a press by
--- comparing the two, and the current value written without its previous one would
--- read a held press as a new one.
--- @param props userdata
--- @param now integer
--- @param prev integer
local function writePair(props, now, prev)
    props.input_menu_previous = prev
    props.input_menu = now
end

--- Write the pair, putting the device's own values back if either write is refused.
--- @return boolean
local function write(props, newNow, newPrev, oldNow, oldPrev)
    local ok, err = pcall(writePair, props, newNow, newPrev)
    if not ok then
        pcall(writePair, props, oldNow, oldPrev)
        markBroken("writing game_props.input_menu: " .. tostring(err))
        return false
    end
    return true
end

--- @param gm userdata
local function clearControls(gm)
    local c = gm.screen_menu.controls
    c.up, c.down, c.left, c.right = false, false, false, false
    c.direction_input = -1
end

--- @return boolean
local function popupUp()
    return NetMenuUI ~= nil and NetMenuUI.popupVisible ~= nil and NetMenuUI.popupVisible()
end

--- A popup over the camp or character select: the spelunker must not walk while the
--- player answers it. The same write chat makes while its box is open.
local function zeroPlayerInputs()
    local ok, ls = pcall(get_local_state)
    if not ok or ls == nil then
        return
    end
    pcall(function()
        local slots = ls.player_inputs.player_slots
        for coopIndex = 1, 4 do
            slots[coopIndex].buttons = 0
            slots[coopIndex].buttons_gameplay = 0
        end
    end)
end

--- @return integer?
local function currentScreen()
    local ok, ls = pcall(get_local_state)
    if ok and ls ~= nil then
        return ls.screen
    end
    return nil
end

--- @param screen integer?
--- @return boolean
local function isMenuScreen(screen)
    return screen ~= nil and (screen == SCREEN.MENU or screen == SCREEN.TITLE)
end

--- Hide this frame's menu input from everything that reads it after us. On the main
--- menu its own direction flags go too: a menu that keeps its controls between frames
--- must not walk on what it took before we zeroed the field.
local function hide(gm, props, now, prev, screen)
    if not write(props, 0, 0, now, prev) then
        return
    end
    zeroedThisFrame = true
    if screen == SCREEN.MENU then
        pcall(clearControls, gm)
    end
end

--- @return boolean
local function capturingNow()
    return NetMenuUI ~= nil and NetMenuUI.capturing ~= nil and NetMenuUI.capturing() == true
end

--- The input, once per frame, right after the game built it: our menu's actions, the
--- swallow, and the main menu's decisions (mainMenuHook).
local function inputCall()
    zeroedThisFrame = false
    if broken ~= nil then
        return
    end
    if Network ~= nil and Network.isInRun ~= nil and Network.isInRun() then
        -- a run: inputSync owns this field
        latchUntilMs = nil
        queueLen = 0
        return
    end
    local gm = GameManager ~= nil and GameManager() or nil
    if gm == nil then
        return
    end
    local ok, props, now, prev = pcall(readPair, gm)
    if not ok then
        markBroken("reading game_props.input_menu: " .. tostring(props))
        return
    end

    local capturing = capturingNow()
    local latched = false
    if latchUntilMs ~= nil then
        latchCalls = latchCalls + 1
        if (now == 0 and latchCalls >= RELEASE_MIN_CALLS) or get_ms() >= latchUntilMs then
            latchUntilMs = nil
        else
            latched = true
        end
    end

    if capturing then
        module.step(now, prevDevice, timers, push, get_ms())
    end
    prevDevice = now

    if capturing or latched then
        local screen = currentScreen()
        hide(gm, props, now, prev, screen)
        if capturing and not isMenuScreen(screen) and popupUp() then
            zeroPlayerInputs()
        end
        if MainMenuHook ~= nil and MainMenuHook.watch ~= nil then
            MainMenuHook.watch(gm)
        end
        return
    end

    if MainMenuHook ~= nil and MainMenuHook.onInput ~= nil then
        local newNow, newPrev = MainMenuHook.onInput(gm, now, prev)
        if newNow == 0 and newPrev == 0 then
            hide(gm, props, now, prev, currentScreen())
        elseif newNow ~= nil then
            write(props, newNow, newPrev, now, prev)
        end
    end
end

--- PRE_UPDATE, when the input callback carried the work: if it hid the field this
--- frame and anything refilled it since, hide it again before the update.
local function keepHidden()
    if not zeroedThisFrame or broken ~= nil then
        return
    end
    local gm = GameManager ~= nil and GameManager() or nil
    if gm == nil then
        return
    end
    local ok, props, now, prev = pcall(readPair, gm)
    if not ok then
        return
    end
    if now ~= 0 or prev ~= 0 then
        write(props, 0, 0, now, prev)
    end
    if capturingNow() and popupUp() and not isMenuScreen(currentScreen()) then
        zeroPlayerInputs()
    end
end

-- Registered after inputSync's and eventSync's (module order in main.lua), and before
-- every hosted mod's: a mod reading the menu input in its own callbacks sees what the
-- vanilla menu sees. No `return` in the wrappers: a value returned from PRE_UPDATE
-- skips the engine's update.
if VIA == "POST_PROCESS_INPUT" then
    set_callback(function()
        if DesyncLog ~= nil then
            DesyncLog.frameMark("postProcessInput:menuInput")
        end
        SafeCall("menuInput:input", inputCall)
        if DesyncLog ~= nil then
            DesyncLog.frameDone("postProcessInput:menuInput")
        end
    end, ON.POST_PROCESS_INPUT)
    if ON.PRE_UPDATE ~= nil then
        set_callback(function()
            if zeroedThisFrame then
                SafeCall("menuInput:keepHidden", keepHidden)
            end
        end, ON.PRE_UPDATE)
    end
elseif VIA == "PRE_UPDATE" then
    set_callback(function()
        if DesyncLog ~= nil then
            DesyncLog.frameMark("preUpdate:menuInput")
        end
        SafeCall("menuInput:input", inputCall)
        if DesyncLog ~= nil then
            DesyncLog.frameDone("preUpdate:menuInput")
        end
    end, ON.PRE_UPDATE)
end

MenuInput = module
return module
