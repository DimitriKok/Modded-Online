--- Modded Online — the MODDED ONLINE menu.
---
--- A game-styled fullscreen menu drawn over the main menu (no Playlunky options tab
--- involved). It opens from the game's own main menu: mainMenuHook relabels the
--- ONLINE row MODDED ONLINE and hands its SELECT here (`module.open`). On a build
--- where that can't install, a hint on the main menu shows the [O] key instead.
---
--- While the menu is open the game's own keyboard input is suppressed
--- (io.wantkeyboard) and its menu input is swallowed (menuInput), so the vanilla menu
--- underneath stays put. The keyboard is read here; a controller arrives through
--- menuInput, as the game's own MENU input.
---
---   MODDED ONLINE
---     HOST  -> Server IP / Server Port / HOST NEW GAME
---     JOIN  -> Server IP / Room Code / JOIN GAME
---     MATCHMAKING, DISCORD
---     SETTINGS -> HIDE ROOM CODE / TEST PLAYERS / SYNC SAVE DATA /
---                 AUTOMATICALLY SEND LOGS / AUTOMATICALLY SYNC DATA /
---                 ENABLE DEBUG MESSAGES
---     VANILLA ONLINE -> the game's own Online menu (with the takeover only)
---
--- Hosting/joining waits on a CONNECTING page, then launches the game's play flow:
--- pick your character, land in the camp (that marks you READY), and the host
--- starts the run by entering the camp's main door. The menu stays up until the
--- screen fades out for character select.
---
--- The first time Modded Online starts, four popups come first, in the same style
--- (FIRST_RUN below): two notices, then whether to switch on AUTOMATICALLY SEND
--- LOGS and AUTOMATICALLY SYNC DATA. A RESTART notice follows any change to the
--- mods played online.

local module = {}

-- Spelunky 2 palette: torch-lit gold on carved cave stone, bronze frames.
local COLOR_TITLE = rgba(255, 206, 92, 255)    -- torch gold
local COLOR_ITEM = rgba(230, 216, 192, 240)    -- bone / parchment
local COLOR_SELECTED = rgba(255, 240, 150, 255) -- lit gold
local COLOR_DIM = rgba(178, 158, 128, 195)     -- dim amber
local COLOR_ERROR = rgba(232, 104, 84, 245)    -- ember red
local COLOR_OVERLAY = rgba(0, 0, 0, 175)       -- dims the menu behind the panel
local COLOR_PANEL = rgba(26, 19, 15, 247)      -- dark cave stone
local COLOR_STRIP = rgba(48, 32, 20, 255)      -- title-banner stone
local COLOR_BORDER = rgba(150, 96, 40, 255)    -- bronze frame
local COLOR_BORDER_HI = rgba(206, 154, 74, 235) -- lit bronze inner frame
local COLOR_HILITE = rgba(150, 96, 40, 150)    -- selection torch-glow bar

--- Width and height of a run of text in draw space.
---
--- `draw_text_size(size, text)` is a GLOBAL in the script API: width, then height,
--- in screen distance, the height negative because draw-space y points up. This
--- used to call it as a method of the draw context, which has no such method, so
--- every call failed into the estimate below. That estimate is two to three times
--- too wide at 1440p: centred labels sat left of centre and the first-run text
--- wrapped at a third of its panel. The estimate is now only for a build without
--- the function.
--- @return number, number
local function measureText(size, text)
    local ok, w, h = pcall(draw_text_size, size, text)
    if ok and type(w) == "number" and type(h) == "number" then
        return math.abs(w), math.abs(h)
    end
    return #text * size * 0.0009, size * 0.0019
end

--- @return number
local function textWidth(size, text)
    return (measureText(size, text))
end

--- Height of one line of text at `size`.
--- @return number
local function textHeight(size)
    local _, h = measureText(size, "Modded Online")
    return h
end

--- Draw text horizontally centered on `cx`.
--- @param ctx GuiDrawContext
local function drawCentered(ctx, cx, y, size, text, color)
    ctx:draw_text(cx - textWidth(size, text) / 2, y, size, text, color)
end

--- Room code for display: masked to same-length asterisks when the streamer
--- "hide room code" option is on, so it never shows on a stream. The player
--- already knows their own code; this only affects what's drawn.
--- @param code any
--- @return string
local function shownCode(code)
    code = tostring(code or "")
    if Network.config.hideRoomCode and code ~= "" then
        return string.rep("*", #code)
    end
    return code
end

--- A framed cave-stone panel: fill, bronze outer frame, lit inner frame.
--- @param ctx GuiDrawContext
local function drawPanel(ctx, left, top, right, bottom)
    ctx:draw_rect_filled(left, top, right, bottom, 0.03, COLOR_PANEL)
    ctx:draw_rect(left, top, right, bottom, 0.03, 3.0, COLOR_BORDER)
    ctx:draw_rect(left + 0.014, top - 0.018, right - 0.014, bottom + 0.018, 0.02, 1.5, COLOR_BORDER_HI)
end

--- The title banner across the top of a panel. Returns where it ends.
--- @param ctx GuiDrawContext
--- @return number
local function drawBanner(ctx, left, top, right)
    local stripB = top - 0.17
    ctx:draw_rect_filled(left + 0.014, top - 0.018, right - 0.014, stripB, 0.02, COLOR_STRIP)
    ctx:draw_line(left + 0.03, stripB, right - 0.03, stripB, 2.0, COLOR_BORDER)
    return stripB
end

--- One menu row: the torch-glow bar and a "> " when it is the selected one.
--- @param ctx GuiDrawContext
local function drawRow(ctx, left, right, y, text, selected)
    if selected then
        ctx:draw_rect_filled(left + 0.03, y + 0.05, right - 0.03, y - 0.06, 0.015, COLOR_HILITE)
        ctx:draw_text(left + 0.055, y, 30, "> " .. text, COLOR_SELECTED)
    else
        ctx:draw_text(left + 0.075, y, 28, text, COLOR_ITEM)
    end
end

-- nil=closed. Pages: root | host | hostdedi | matchtype | matchsearch |
-- matchnone | friendtype | joinofficial | joindedi | settings | connecting | joined
local page = nil        --- @type string?
local cursor = 1
local editing = nil     --- @type string? # label of the field being typed into
local editBuffer = ""
local roomCode = ""
local openedMs = nil    --- @type number? # when the menu last opened
local releaseUntilMs = nil --- @type number? # the keyboard stays ours until then
local lastGuiMs = nil   --- @type number? # the last GUI frame, for capturing()

--- SELECT and BACK are ignored this long after the menu opens. The press that opened
--- it (ENTER or Z on the main menu's row) is still down on the GUI frame that
--- follows, and would otherwise pick HOST at once.
local ARM_MS = 150
--- After the menu closes the keyboard stays ours this long, so the key that closed it
--- does not land on the game's menu underneath (the popups have the same window).
local MENU_RELEASE_MS = 300
--- With no GUI frame for this long, nothing of ours is on screen: stop swallowing the
--- game's input rather than leave the main menu deaf behind an invisible menu.
local GUI_STALE_MS = 2000

-- ---------------------------------------------------------------- keyboard

--- Numeric KEY constants only: the string lookup resolves by first letter on
--- this build ("UpArrow" fired on U, "Enter" on E), which made the controls
--- miserable. VK codes are unambiguous.
--- @param keycode integer
--- @param allowRepeat boolean?
--- @return boolean
local function rawKeyPressed(keycode, allowRepeat)
    return get_io().keypressed(keycode, allowRepeat)
end

local function pressed(keycode, allowRepeat)
    -- pcall(fn, args) rather than pcall(closure): this is polled several times per
    -- display frame while the menu is up, and the closure was the only allocation
    local ok, hit = pcall(rawKeyPressed, keycode, allowRepeat == true)
    return ok and hit == true
end

local KEYS = {
    open = KEY.O,            -- only when the main menu takeover is not in place
    up = KEY.UP,
    down = KEY.DOWN,
    left = 37,               -- VK_LEFT / VK_RIGHT: change a setting's value
    right = 39,
    select = KEY.Z,          -- menu confirm, like the game's jump button
    commit = KEY.RETURN,     -- finish typing in a text field; also confirms
    back = KEY.ESCAPE,
    backspace = KEY.BACKSPACE,
}

--- Uppercase toggle for the text fields (flipped with CAPS LOCK or TAB).
local capsMode = false

-- The script API's key functions use CHORD semantics: while shift is held, a
-- plain keypressed(KEY.A) never fires at all — the press only registers as
-- the chord KEY.OL_MOD_SHIFT | KEY.A. (This is why "holding shift" typed
-- nothing: the letters went dead, not the shift detection.) So every typing
-- key is polled twice: bare, and with the shift-modifier flag.
local SHIFT_MOD = 0x200 -- OL_KEY_SHIFT; the KEY table calls it OL_MOD_SHIFT
pcall(function()
    if type(KEY.OL_MOD_SHIFT) == "number" then
        SHIFT_MOD = KEY.OL_MOD_SHIFT
    end
end)

--- Was `code` typed this frame? Returns hit, shifted.
--- @param code integer
--- @return boolean, boolean
local function typedKey(code)
    if pressed(code, true) then
        return true, false
    end
    if pressed(SHIFT_MOD | code, true) then
        return true, true
    end
    return false, false
end

--- Collect typed characters for the active text field.
local function pollTypedInput()
    if pressed(20) or pressed(9) then -- CAPS LOCK or TAB toggles capitals
        capsMode = not capsMode
    end
    for code = KEY.A, KEY.Z do -- letters (Z types a z here; select is nav-only)
        local hit, shifted = typedKey(code)
        if hit then
            local ch = string.char(code)
            editBuffer = editBuffer .. ((shifted ~= capsMode) and ch or ch:lower())
        end
    end
    for code = 48, 57 do -- top-row digits (shift chord forgiven: still a digit)
        if typedKey(code) then
            editBuffer = editBuffer .. string.char(code)
        end
    end
    for code = 96, 105 do -- numpad digits
        if pressed(code, true) then
            editBuffer = editBuffer .. string.char(code - 48)
        end
    end
    if typedKey(KEY.PERIOD) then
        editBuffer = editBuffer .. "."
    end
    do
        local hit, shifted = typedKey(KEY.MINUS)
        if hit then
            editBuffer = editBuffer .. (shifted and "_" or "-")
        end
    end
    if typedKey(186) then -- OEM ;: key -> colon (IPv6 addresses), shifted or not
        editBuffer = editBuffer .. ":"
    end
    do
        local hit = typedKey(KEYS.backspace)
        if hit then
            editBuffer = editBuffer:sub(1, -2)
        end
    end
end

-- ---------------------------------------------------------------- pages

local function closeMenu()
    editing = nil
    if page == nil then
        return
    end
    page = nil
    openedMs = nil
    releaseUntilMs = get_ms() + MENU_RELEASE_MS
    if MenuInput ~= nil then
        MenuInput.releaseLatch() -- the button that closed it must not reach the game
        MenuInput.clear()
    end
end

--- Is MODDED ONLINE a row of the game's own main menu (mainMenuHook)?
--- @return boolean
local function takeoverActive()
    return MainMenuHook ~= nil and MainMenuHook.active ~= nil and MainMenuHook.active() == true
end

--- The [O] chip and key: when the takeover could not install, or on a build without
--- mainMenuHook at all. Not in the moment it is still being tried.
--- @return boolean
local function fallbackKeys()
    if MainMenuHook == nil or MainMenuHook.active == nil then
        return true
    end
    return MainMenuHook.active() == false
end

-- The community Discord. `start ""` hands the URL to the OS default browser; the
-- empty first argument is the window TITLE `start` expects when the target is
-- quoted, without it `start "https://..."` would treat the URL as the title and
-- open nothing. Wrapped in pcall so a locked-down machine can't error the menu.
local DISCORD_URL = "https://discord.gg/P92bRa8s3m"
local function doDiscord()
    pcall(function()
        os.execute(string.format('start "" "%s"', DISCORD_URL))
    end)
end

-- Where BACK goes from the CONNECTING and JOINED pages: the page that connected.
local connectBackPage, connectBackCursor = "root", 1

--- Wait on the server on a page of our own rather than closing: the outcome (an
--- error, or the room) shows here, and the menu stays up until the play flow fades
--- the screen out for character select.
--- @param fromPage string
--- @param fromCursor integer
local function enterConnecting(fromPage, fromCursor)
    connectBackPage, connectBackCursor = fromPage, fromCursor
    page = "connecting"
    cursor = 1
end

local function doHost()
    Network.saveConfig()
    Network.hostGame()
    enterConnecting("hostdedi", 3)
end

local function doHostOfficial()
    Network.saveConfig()
    Network.hostOfficial()
    enterConnecting("host", 1)
end

local function doJoin()
    Network.saveConfig()
    Network.joinGame(roomCode)
    enterConnecting("joindedi", 3)
end

local function doJoinOfficial()
    Network.saveConfig()
    Network.joinOfficial(roomCode)
    enterConnecting("joinofficial", 2)
end

--- START QUEUE: probe for an OPEN (unstarted) lobby without opening one. The menu
--- stays open on the search page; pollMatchSearch resolves the outcome — dropped
--- into a lobby (the play flow takes over) or none found (offer the choices below).
local function doStartQueue()
    Network.saveConfig()
    Network.matchmake("find")
    page = "matchsearch"
    cursor = 1
end

--- START NEW GAME: no open lobby existed, so open a fresh public one and wait.
local function doMatchmakeNew()
    Network.saveConfig()
    Network.matchmake() -- find-or-open an unstarted lobby (opens one, since none exist)
    enterConnecting("matchnone", 1)
end

--- JOIN EXISTING GAME: drop into a public game already in progress (late-join).
local function doMatchmakeStarted()
    Network.saveConfig()
    Network.matchmake("started")
    enterConnecting("matchnone", 2)
end

--- VANILLA ONLINE: the game's own Online menu, from the row we took over.
local function doVanillaOnline()
    if MainMenuHook ~= nil and MainMenuHook.requestVanillaOnline ~= nil then
        MainMenuHook.requestVanillaOnline()
    end
end

-- ESC / BACK steps one page back up this tree (root closes the menu). CONNECTING and
-- JOINED go back to whichever page connected (connectBackPage).
local PARENT = {
    host = "root", hostdedi = "host",
    friendtype = "root",
    joinofficial = "friendtype", joindedi = "friendtype",
    matchtype = "root", matchsearch = "matchtype", matchnone = "matchtype",
    settings = "root",
}

--- An ON/OFF setting. SELECT flips it, and so do LEFT and RIGHT, like a vanilla
--- options row (a held LEFT or RIGHT does not keep flipping it). The label always
--- states the current value, since pageItems runs each frame.
--- @param label string
--- @param key string # its Network.config key
--- @return table
local function switchRow(label, key)
    local function flip()
        Network.config[key] = not Network.config[key]
        Network.saveConfig()
    end
    local value = Network.config[key] and "ON" or "OFF"
    return {
        label = label .. "  [" .. value .. "]",
        name = label,
        value = value,
        action = flip,
        change = function(_, isRepeat)
            if not isRepeat then
                flip()
            end
        end,
    }
end

--- Streamer toggle: mask the room code everywhere it's shown.
local function hideCodeToggle()
    return switchRow("HIDE ROOM CODE", "hideRoomCode")
end

--- @param count integer
local function setTestPlayers(count)
    Network.config.testPlayer = count
    Network.saveConfig()
    -- changing the count mid-session should affect the room we are in
    -- now, not only the next one (launchTestPlayer replaces the old set)
    if count > 0 then
        Network.launchTestPlayer()
    else
        Network.stopTestPlayers()
    end
end

--- Solo testing: put stand-in players in whatever room we open next, so the
--- multiplayer paths can be exercised with nobody else online. SELECT and RIGHT
--- cycle OFF -> 1 -> 2 -> 3 -> OFF, LEFT the other way; three is a full room, since
--- we are the fourth. Off by default, and the label always states the current count.
local function testPlayerToggle()
    local count = math.floor(tonumber(Network.config.testPlayer) or 0)
    local function cycle(dir)
        local next_ = math.floor(tonumber(Network.config.testPlayer) or 0) + dir
        if next_ > Network.MAX_TEST_PLAYERS then
            next_ = 0
        elseif next_ < 0 then
            next_ = Network.MAX_TEST_PLAYERS
        end
        setTestPlayers(next_)
    end
    local value = count > 0 and tostring(count) or "OFF"
    return {
        label = "TEST PLAYERS  [" .. value .. "]",
        name = "TEST PLAYERS",
        value = value,
        action = function() cycle(1) end,
        -- not on a held key: each step starts or stops a test player's process
        change = function(dir, isRepeat)
            if not isRepeat then
                cycle(dir)
            end
        end,
    }
end


--- Push Modded Online's save data into the mod it belongs to.
---
--- Everything played under Modded Online writes to OUR pack, not the mod's, so the
--- mod on its own never sees that progress. This is how a player claims it. The
--- label carries the last result because a disk copy has no other feedback, and
--- saveShare refuses while the host's save is borrowed -- that progress is not
--- this player's to keep.
local function syncSaveItem()
    local note = nil
    if SaveShare ~= nil and SaveShare.lastResult ~= nil then
        note = SaveShare.lastResult()
    end
    return {
        label = "SYNC SAVE DATA" .. (note ~= nil and ("  [" .. note .. "]") or ""),
        name = "SYNC SAVE DATA",
        value = note,
        action = function()
            if SaveShare ~= nil and SaveShare.syncToMod ~= nil then
                SafeCall("menuUI:syncSaveData", SaveShare.syncToMod)
            end
        end,
    }
end

--- A run that desynced sends its log to the Discord channel the room's server
--- posts to (LogShip). Off by default; switching it off stops an upload already
--- under way.
local function autoSendLogsToggle()
    return switchRow("AUTOMATICALLY SEND LOGS", "autoSendLogs")
end

--- SYNC SAVE DATA, done for the player every time the game's main menu comes up
--- (SaveShare.pollAutoSync). Off by default. Its result shows on the SYNC SAVE DATA
--- row, since both are the same copy.
local function autoSyncToggle()
    return switchRow("AUTOMATICALLY SYNC DATA", "autoSyncSave")
end

--- The print() lines at the top left of the screen: ours and the hosted mods'
--- (main.lua gates them). Off by default; on for anyone chasing a problem.
local function debugMessagesToggle()
    return switchRow("ENABLE DEBUG MESSAGES", "debugMessages")
end

--- BACK from CONNECTING or JOINED: give the room up and return to the page that
--- connected.
local function leaveConnect()
    if Network.phase ~= nil and Network.PHASE ~= nil and Network.phase ~= Network.PHASE.IDLE
        and Network.leave ~= nil then
        Network.leave()
    end
    page = connectBackPage or "root"
    cursor = connectBackCursor or 1
end

local function pageItems()
    if page == "host" then
        -- pick WHERE to host: the always-on official (public) server, or a
        -- dedicated server you run yourself
        return {
            { label = "OFFICIAL SERVER", action = doHostOfficial },
            { label = "DEDICATED SERVER", action = function() page = "hostdedi"; cursor = 1 end },
            { label = "BACK", action = function() page = "root"; cursor = 1 end },
        }
    elseif page == "hostdedi" then
        return {
            { label = "SERVER IP", get = function() return Network.config.serverHost end,
              set = function(v) if v ~= "" then Network.config.serverHost = v end end },
            { label = "SERVER PORT", get = function() return tostring(Network.config.serverPort) end,
              set = function(v)
                  local port = math.floor(tonumber(v) or 0)
                  if port > 0 and port < 65536 then Network.config.serverPort = port end
              end },
            { label = "HOST NEW GAME", action = doHost },
            { label = "BACK", action = function() page = "host"; cursor = 2 end },
        }
    elseif page == "matchtype" then
        -- START QUEUE probes for an open lobby to fill; the result page (matchnone)
        -- appears only if there's nothing open to join.
        return {
            { label = "START QUEUE", action = doStartQueue },
            { label = "BACK", action = function() page = "root"; cursor = 3 end },
        }
    elseif page == "matchsearch" then
        -- transient: waiting on the server's answer to START QUEUE (see pollMatchSearch)
        return {
            { label = "CANCEL", action = function() Network.leave(); page = "matchtype"; cursor = 1 end },
        }
    elseif page == "matchnone" then
        -- no open lobby was found: start a fresh one, or drop into a running game
        return {
            { label = "START NEW GAME", action = doMatchmakeNew },
            { label = "JOIN EXISTING GAME", action = doMatchmakeStarted },
            { label = "BACK", action = function() page = "matchtype"; cursor = 1 end },
        }
    elseif page == "friendtype" then
        -- where your friend's room lives: the official server (code only) or a
        -- dedicated server they run (their IP + code)
        return {
            { label = "OFFICIAL SERVER", action = function() page = "joinofficial"; cursor = 1 end },
            { label = "DEDICATED SERVER", action = function() page = "joindedi"; cursor = 1 end },
            { label = "BACK", action = function() page = "root"; cursor = 2 end },
        }
    elseif page == "joinofficial" then
        return {
            { label = "ROOM CODE", secret = true, get = function() return roomCode end,
              set = function(v) roomCode = v:upper():sub(1, 4) end },
            { label = "JOIN GAME", action = doJoinOfficial },
            { label = "BACK", action = function() page = "friendtype"; cursor = 1 end },
        }
    elseif page == "joindedi" then
        return {
            { label = "SERVER IP", get = function() return Network.config.joinHost end,
              set = function(v) Network.config.joinHost = v end },
            { label = "ROOM CODE", secret = true, get = function() return roomCode end,
              set = function(v) roomCode = v:upper():sub(1, 4) end },
            { label = "JOIN GAME", action = doJoin },
            { label = "BACK", action = function() page = "friendtype"; cursor = 2 end },
        }
    elseif page == "settings" then
        return {
            hideCodeToggle(),
            testPlayerToggle(),
            syncSaveItem(),
            autoSendLogsToggle(),
            autoSyncToggle(),
            debugMessagesToggle(),
            { label = "BACK", action = function() page = "root"; cursor = 5 end },
        }
    elseif page == "connecting" then
        -- transient: waiting on the server; an error stays on this page (drawMenu)
        local waiting = Network.PHASE ~= nil and Network.phase == Network.PHASE.CONNECTING
        return {
            { label = waiting and "CANCEL" or "BACK", action = leaveConnect },
        }
    elseif page == "joined" then
        -- in the room; the play flow takes over from the main menu in a moment
        return {
            { label = "LEAVE ROOM", action = leaveConnect },
        }
    end
    local root = {
        { label = "HOST", action = function() page = "host"; cursor = 1 end },
        { label = "JOIN", action = function() page = "friendtype"; cursor = 1 end },
        { label = "MATCHMAKING", action = function() page = "matchtype"; cursor = 1 end },
        { label = "DISCORD", action = doDiscord },
        { label = "SETTINGS", action = function() page = "settings"; cursor = 1 end },
    }
    -- BACK closes the menu, so there is no CLOSE row. VANILLA ONLINE only exists
    -- while the ONLINE row is ours to give back.
    if takeoverActive() then
        root[#root + 1] = { label = "VANILLA ONLINE", action = doVanillaOnline }
    end
    return root
end

--- Is the menu armed for SELECT and BACK yet (ARM_MS)?
--- @return boolean
local function armed()
    return openedMs == nil or get_ms() - openedMs >= ARM_MS
end

--- One step up the page tree.
local function goBack()
    if page == "root" then
        closeMenu()
    elseif page == "connecting" or page == "joined" then
        leaveConnect()
    else
        if page == "matchsearch" then
            Network.leave() -- backing out of the search aborts the in-flight queue
        end
        page = PARENT[page] or "root"
        cursor = 1
    end
end

--- One menu action, from the keyboard or the game's menu input alike:
--- up | down | left | right | select | back. `isRepeat`: a held direction repeating.
--- @param action string
--- @param isRepeat boolean
local function dispatch(action, isRepeat)
    local items = pageItems()
    if #items == 0 then
        return
    end
    if cursor > #items then
        cursor = #items
    end
    if action == "up" then
        cursor = cursor > 1 and cursor - 1 or #items
    elseif action == "down" then
        cursor = cursor < #items and cursor + 1 or 1
    elseif action == "left" or action == "right" then
        local item = items[cursor]
        if item.change ~= nil then
            item.change(action == "left" and -1 or 1, isRepeat)
        end
    elseif action == "select" then
        if not armed() then
            return
        end
        local item = items[cursor]
        if item.action ~= nil then
            item.action()
        elseif item.get ~= nil then
            editing = item.label
            editBuffer = item.get()
            capsMode = false
        end
    elseif action == "back" then
        if armed() then
            goBack()
        end
    end
end

--- Finish typing: hand the buffer to the field being edited.
local function commitEdit()
    for _, item in ipairs(pageItems()) do
        if item.label == editing and item.set ~= nil then
            item.set(editBuffer)
        end
    end
    editing = nil
end

--- The keyboard's menu keys. Up and down repeat while held, as the game's do.
local function pollKeyboard()
    if pressed(KEYS.up, true) then
        dispatch("up", false)
    end
    if pressed(KEYS.down, true) then
        dispatch("down", false)
    end
    if pressed(KEYS.left, true) then
        dispatch("left", not pressed(KEYS.left))
    end
    if pressed(KEYS.right, true) then
        dispatch("right", not pressed(KEYS.right))
    end
    if pressed(KEYS.select) or pressed(KEYS.commit) then
        dispatch("select", false)
    elseif pressed(KEYS.back) or (fallbackKeys() and pressed(KEYS.open)) then
        dispatch("back", false)
    end
end

--- One action from the game's menu input (a controller; see menuInput).
--- @param action string
--- @param isRepeat boolean
local function dispatchPad(action, isRepeat)
    if page == nil then
        return
    end
    if editing ~= nil then
        -- typing belongs to the keyboard; the pad can only finish or cancel it, and
        -- not even that where keyboard presses would arrive here as well
        if MenuInput ~= nil and MenuInput.KEYBOARD_IN_MENU_INPUT then
            return
        end
        if action == "select" then
            commitEdit()
        elseif action == "back" then
            editing = nil
        end
        return
    end
    dispatch(action, isRepeat)
end

--- The open menu's input for one GUI frame: typing, or the keyboard's menu keys,
--- then whatever the controller pressed since the last frame.
local function handleInput()
    if editing ~= nil then
        pollTypedInput()
        if pressed(KEYS.commit) then
            commitEdit()
        elseif pressed(KEYS.back) then
            editing = nil -- cancel, keep the old value
        end
    elseif not (MenuInput ~= nil and MenuInput.KEYBOARD_IN_MENU_INPUT and takeoverActive()) then
        pollKeyboard()
    end
    if MenuInput ~= nil then
        MenuInput.drain(dispatchPad)
    end
end

-- ---------------------------------------------------------------- drawing

--- @param ctx GuiDrawContext
local function drawMenu(ctx)
    local items = pageItems()
    if cursor > #items then
        cursor = #items
    end

    -- dim the main menu behind the panel so the window reads clearly
    ctx:draw_rect_filled(-1, 1, 1, -1, 0, COLOR_OVERLAY)

    local L, R, T, B = -0.46, 0.46, 0.66, -0.52
    drawPanel(ctx, L, T, R, B)

    -- title banner
    local stripB = drawBanner(ctx, L, T, R)
    drawCentered(ctx, 0, T - 0.075, 40, "MODDED  ONLINE", COLOR_TITLE)
    local subtitle = ({
        host = "- HOST GAME -",
        hostdedi = "- DEDICATED SERVER -",
        matchtype = "- MATCHMAKING -",
        matchsearch = "- MATCHMAKING -",
        matchnone = "- NO OPEN GAMES -",
        friendtype = "- JOIN A FRIEND -",
        joinofficial = "- OFFICIAL SERVER -",
        joindedi = "- DEDICATED SERVER -",
        settings = "- SETTINGS -",
        connecting = "- CONNECTING -",
    })[page]
    if page == "joined" then
        subtitle = "- ROOM " .. shownCode(Network.room) .. " -"
    end
    if subtitle ~= nil then
        drawCentered(ctx, 0, stripB - 0.055, 22, subtitle, COLOR_DIM)
    end

    -- menu rows: 0.12 apart, closer on a page with too many of them to clear the
    -- footer (SETTINGS, at seven). The last bar ends above the footer line.
    local y = stripB - (page == "root" and 0.115 or 0.15)
    local rowH = 0.12
    if #items > 1 then
        rowH = math.min(rowH, (y - (B + 0.20)) / (#items - 1))
    end
    for index, item in ipairs(items) do
        local selected = index == cursor
        local text = item.label
        if item.get ~= nil then
            local raw = (editing == item.label) and editBuffer or item.get()
            local shown = (item.secret and Network.config.hideRoomCode and raw ~= "")
                and string.rep("*", #raw) or raw
            if editing == item.label then
                shown = shown .. "_"
            end
            if shown == "" then
                shown = "..."
            end
            text = string.format("%-13s %s", item.label, shown)
        end
        drawRow(ctx, L, R, y, text, selected)
        y = y - rowH
    end

    -- footer + connection status
    local footer = editing ~= nil
        and string.format("TYPE to edit    SHIFT caps    CAPSLOCK toggle%s    ENTER save    ESC cancel",
            capsMode and " (ON)" or "")
        or "ARROWS move     Z / ENTER select     ESC back"
    drawCentered(ctx, 0, B + 0.11, 18, footer, COLOR_DIM)
    if Network.phase == Network.PHASE.CONNECTING then
        local status = (page == "matchsearch") and "Searching for an open game..."
            or "Connecting to the server..."
        drawCentered(ctx, 0, B + 0.055, 20, status, COLOR_TITLE)
    elseif page == "joined" then
        drawCentered(ctx, 0, B + 0.055, 20, "Joined! Starting the game...", COLOR_TITLE)
    elseif Network.lastError ~= nil then
        drawCentered(ctx, 0, B + 0.055, 20, "! " .. Network.lastError, COLOR_ERROR)
    end
end

--- What the camp plaque says: the room and how many are ready, how the run starts,
--- and one line per player. Both looks draw from this.
--- @return string, string, table # header, hint, { { text, ready } }
local function campView()
    local ready, total = 0, 0
    for _, player in ipairs(Network.lobbyPlayers) do
        total = total + 1
        if player.ready then
            ready = ready + 1
        end
    end
    local header = string.format("ROOM %s  %s   %d / %d READY", shownCode(Network.room),
        Network.isPublicRoom() and "[PUBLIC]" or "[PRIVATE]", ready, total)
    local hint
    if Network.isPublicRoom() then
        -- public: everyone readies at the door; it auto-starts when all are ready,
        -- but never with just one player — wait for someone else to matchmake in
        if total < 2 then
            hint = "Waiting for more players to join..."
        else
            hint = "Enter a DOOR to ready up (all must pick the same one)"
        end
    elseif Network.isHost() then
        hint = "Host: enter a DOOR to begin (shortcuts work too)"
    else
        hint = "Waiting for the host to start..."
    end
    local players = {}
    for _, player in ipairs(Network.lobbyPlayers) do
        -- show WHICH camp door each player is readied at, so a mismatched
        -- shortcut is obvious instead of silently blocking the start
        local where = ""
        if player.ready then
            local dest = player.dest
            if type(dest) == "table" and dest[1] ~= nil then
                where = string.format("  -> %d-%d", math.floor(dest[1]), math.floor(dest[2] or 1))
            else
                where = "  -> 1-1"
            end
        end
        players[#players + 1] = {
            string.format("%s  %s%s", player.ready and "[READY]" or "[ ... ]", player.name, where),
            player.ready == true,
        }
    end
    return header, hint, players
end

--- Camp status: who is ready, and how the run starts. Drawn in a small
--- framed stone plaque in the top-left so it reads over the camp.
--- @param ctx GuiDrawContext
local function drawCampStatus(ctx)
    local header, hint, players = campView()
    local L, R, T = -0.98, -0.44, 0.98
    local B = 0.72 - math.max(0, #players - 1) * 0.06
    drawPanel(ctx, L, T, R, B)
    ctx:draw_text(L + 0.03, T - 0.05, 22, header, COLOR_TITLE)
    ctx:draw_text(L + 0.03, T - 0.11, 17, hint, COLOR_DIM)
    for index, player in ipairs(players) do
        ctx:draw_text(L + 0.03, T - 0.17 - (index - 1) * 0.06, 18, player[1],
            player[2] and COLOR_ITEM or COLOR_DIM)
    end
end

--- The room code, shown in a small framed stone plaque in the BOTTOM-RIGHT of the
--- character-select screen so a player can read/share it before the run. This one
--- shows the REAL code even when the streamer "hide room code" toggle is on: the
--- character select is the pre-run moment to grab and share your code, and it
--- disappears before the run itself (which is what a stream shows) begins. guiFrame
--- only calls this while the player is still choosing; it vanishes the moment they
--- confirm their character (the screen starts fading out).
--- @param ctx GuiDrawContext
local function drawCharSelectCode(ctx)
    local code = tostring(Network.room or "") -- raw, NOT shownCode: always visible here
    if code == "" then
        return
    end
    local L, R, T, B = 0.52, 0.98, -0.80, -0.98
    drawPanel(ctx, L, T, R, B)
    local cx = (L + R) / 2
    drawCentered(ctx, cx, T - 0.06, 26, "ROOM  " .. code, COLOR_TITLE)
    drawCentered(ctx, cx, T - 0.125, 15, "invite friends with this code", COLOR_DIM)
end

--- Resolve the outcome of a START QUEUE probe (page == "matchsearch"): dropped
--- into an open lobby (let the play flow take over), or none open (offer START NEW
--- GAME / JOIN EXISTING GAME). Any other error stays on-screen via drawMenu.
local function pollMatchSearch()
    if Network.phase == Network.PHASE.LOBBY then
        -- in a lobby now: character select launches from here
        connectBackPage, connectBackCursor = "matchtype", 1
        page = "joined"
        cursor = 1
    elseif Network.lastErrorCode == "no_unstarted_game" then
        Network.lastError = nil
        Network.lastErrorCode = nil
        page = "matchnone"
        cursor = 1
    end
end

--- The pages that wait on the server: move on when the room is reached or lost, and
--- close as the play flow fades the main menu out for character select.
local function pollConnect()
    if page == "matchsearch" then
        pollMatchSearch()
    end
    if page == "connecting" and Network.isActive() then
        page = "joined"
        cursor = 1
    elseif page == "joined" and not Network.isActive() then
        -- the room went away before the run began; lastError says why
        page = connectBackPage or "root"
        cursor = connectBackCursor or 1
    end
    if page == "connecting" or page == "joined" then
        local ok, ls = pcall(get_local_state)
        if ok and ls ~= nil and ls.loading ~= nil and ls.loading ~= FADE.NONE then
            closeMenu()
        end
    end
end

--- World-desync notice: this floor generated differently from the host's. A brief
--- In-run heads-up: room, player count and ping, top-left over the game.
--- @param ctx GuiDrawContext
local statusText = nil
local statusRoom, statusPlayers, statusPing, statusHidden = nil, nil, nil, nil

--- The run status line's text, rebuilt only when what it says changes.
--- @return string
local function runStatusLine()
    -- activePlayers, NOT playerCount: a departed player keeps their slot in the
    -- roster (their spelunker is stood still rather than removed, which is what
    -- keeps the simulation deterministic), so playerCount still counted them and
    -- the header read "2 players" after one had left.
    local room = Network.room
    local players = InputSync.activePlayers()
    local ping = Network.pingMs
    -- `hideRoomCode` is in the key as well: it is a menu toggle the player can flip
    -- mid-run, and shownCode reads it, so leaving it out would show the old form
    -- until the ping happened to move.
    local hidden = Network.config.hideRoomCode
    -- Rebuilt only when one of the four actually moves. This is drawn at display
    -- rate, which is uncapped on borderless, while the room code and player count
    -- change once a run and the ping about once a second.
    if statusText == nil or room ~= statusRoom or players ~= statusPlayers
        or ping ~= statusPing or hidden ~= statusHidden
    then
        statusRoom, statusPlayers, statusPing, statusHidden = room, players, ping, hidden
        statusText = string.format("MODDED ONLINE   room %s   %d players   %d ms",
            shownCode(room), players, ping)
    end
    return statusText
end

--- @param ctx GuiDrawContext
local function drawRunStatus(ctx)
    ctx:draw_text(-0.99, 0.99, 0, runStatusLine(), COLOR_DIM)
end

--- Lockstep stall notice, drawn while the sim waits on a peer's inputs. Styled
--- as the same framed cave-stone plaque as the lobby player list (drawCampStatus)
--- and pinned to the same top-left corner, so it reads as part of the mod's UI.
--- @param ctx GuiDrawContext
local function drawWaitingPanel(ctx)
    local L, R, T = -0.98, -0.44, 0.98
    local B = 0.82
    drawPanel(ctx, L, T, R, B)
    ctx:draw_text(L + 0.03, T - 0.05, 22, "WAITING FOR PLAYERS", COLOR_TITLE)
    ctx:draw_text(L + 0.03, T - 0.11, 17, "Syncing with the other players...", COLOR_DIM)
end

-- ---------------------------------------------------------------- popups

--- The popups shown the first time Modded Online starts, in order, over the title
--- screen and main menu in the menu's own style. Titles and buttons are drawn in
--- capitals like every other label in it; the text is drawn as written. A popup
--- with a `setting` writes the chosen button's `value` to that config key.
---
--- Each answer is saved as it is given, and `firstRunDone` only once the last one
--- is: closing the game half way through shows them all again next time.
local FIRST_RUN = {
    {
        title = "Modded Online 2",
        text = "To use modded online, ensure all script mods (other than modded online)"
            .. " are disabled. To play a mod, please enable it under playlunky options"
            .. " and restart the game.",
        buttons = { { label = "I Understand" } },
    },
    {
        title = "Modded Online 2",
        text = "This mod has used ai heavily in the development in it; thus, it will"
            .. " contain bugs and issues. The old version of the mod would corrupt any"
            .. " mods you used it with. Please reinstall any mods you used the original"
            .. " modded online with. If you face any bugs or errors, please join the"
            .. " modded online discord server and send them there. Do not report any"
            .. " bugs to other mod creators if you have modded online enabled.",
        buttons = { { label = "I Understand" } },
    },
    {
        title = "Automatically Send Desync Errors",
        text = "Desyncs and Crashes are prone to happen. Do we have permission to"
            .. " automatically send any errors into the community discord server. No"
            .. " personal information is shared.",
        setting = "autoSendLogs",
        buttons = { { label = "Yes", value = true }, { label = "No", value = false } },
    },
    {
        title = "Automatically Sync Data",
        text = "Some mods use custom save data. Right now, we do not interfere with any"
            .. " mods files; thus, any progress you make in modded online does not"
            .. " transfer to the mod. There is a sync data button in modded online"
            .. " setting or you can opt to enable automatic save syncing. Do you want"
            .. " to enable Automatic Syncing?",
        setting = "autoSyncSave",
        buttons = { { label = "Yes", value = true }, { label = "No", value = false } },
    },
}

--- Shown when the mods played online change: a box ticked or unticked in
--- Playlunky's options, or the setup undone (setupUI). None of it takes effect
--- until the game restarts, and a player who sees nothing change concludes it is
--- broken.
local RESTART = {
    {
        title = "Restart Required",
        text = "Restart the game for this change to take effect. Playlunky only loads"
            .. " mods when the game starts.",
        buttons = { { label = "OK" } },
    },
}

--- A press is ignored for this long after a popup appears, so a key mashed
--- through one popup cannot answer the next before it has been read.
local POPUP_INPUT_DELAY_MS = 600
--- The keyboard stays ours this long after the last answer, so the press that
--- gave it cannot fall through to the game's own menu underneath.
local POPUP_RELEASE_MS = 300

-- The menu's own width; the text is wrapped to fit inside it.
local POPUP_L, POPUP_R = -0.46, 0.46
local POPUP_TEXT_X = POPUP_L + 0.075
local POPUP_TEXT_W = (POPUP_R - 0.075) - POPUP_TEXT_X
local POPUP_ROW_H = 0.12

local popupSeq = nil         -- the sequence on screen: FIRST_RUN or RESTART
local popupStep = 1          -- which of its popups is up
local popupChoice = 1        -- which of its buttons is highlighted
local popupShownMs = nil     -- when it appeared; presses before the pause is over are ignored
local popupDrawn = false     -- drawn on the last GUI frame; one that was not re-arms the pause
local popupClosedMs = nil    -- when the last answer was given
local popupLayout = nil      -- the measured layout, kept until the popup or screen changes
local restartPending = false -- a RESTART notice is due

--- `text` broken into lines no wider than `width` at `size`. A word longer than
--- the whole width gets a line of its own rather than being cut.
--- @return string[]
local function wrapText(size, text, width)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if line ~= "" and textWidth(size, candidate) > width then
            lines[#lines + 1] = line
            line = word
        else
            line = candidate
        end
    end
    if line ~= "" then
        lines[#lines + 1] = line
    end
    return lines
end

--- Where everything in a popup goes, measured rather than assumed: the text is
--- wrapped to the panel, and the panel is as tall as its content and centred. The
--- text steps down a size if it would not fit the screen, and a long title steps
--- down so it stays inside the banner.
--- @return table
local function measurePopup(popup)
    local title = popup.title:upper()
    local titleSize = 40
    while titleSize > 24 and textWidth(titleSize, title) > (POPUP_R - POPUP_L) - 0.12 do
        titleSize = titleSize - 2
    end
    local textSize, lines, lineH, height
    for _, size in ipairs({ 24, 22, 20, 18 }) do
        textSize = size
        lines = wrapText(size, popup.text, POPUP_TEXT_W)
        lineH = textHeight(size) * 1.25
        -- From the top edge down: the banner and a gap, the text, a gap to the first
        -- button, the rest of the buttons, then the last one's bar and the footer.
        height = (0.17 + 0.07) + #lines * lineH + 0.12 + (#popup.buttons - 1) * POPUP_ROW_H + 0.18
        if height <= 1.9 then
            break
        end
    end
    local T = math.min(0.95, height / 2)
    local textY = T - (0.17 + 0.07)
    local rowY = textY - #lines * lineH - 0.12
    return {
        title = title,
        titleSize = titleSize,
        -- where the menu draws its 40-point title, lowered by half of any shrink
        titleY = T - 0.075 - (textHeight(40) - textHeight(titleSize)) / 2,
        lines = lines,
        textSize = textSize,
        lineH = lineH,
        textY = textY,
        rowY = rowY,
        T = T,
        B = T - height,
    }
end

--- @param ctx GuiDrawContext
local function drawPopup(ctx, popup, layout)
    ctx:draw_rect_filled(-1, 1, 1, -1, 0, COLOR_OVERLAY)
    drawPanel(ctx, POPUP_L, layout.T, POPUP_R, layout.B)
    drawBanner(ctx, POPUP_L, layout.T, POPUP_R)
    drawCentered(ctx, 0, layout.titleY, layout.titleSize, layout.title, COLOR_TITLE)
    for index, line in ipairs(layout.lines) do
        ctx:draw_text(POPUP_TEXT_X, layout.textY - (index - 1) * layout.lineH,
            layout.textSize, line, COLOR_ITEM)
    end
    for index, button in ipairs(popup.buttons) do
        drawRow(ctx, POPUP_L, POPUP_R, layout.rowY - (index - 1) * POPUP_ROW_H,
            button.label:upper(), index == popupChoice)
    end
    local footer = #popup.buttons > 1 and "ARROWS move     Z / ENTER select" or "Z / ENTER select"
    drawCentered(ctx, 0, layout.B + 0.075, 18, footer, COLOR_DIM)
end

--- Are the first-run popups still to be answered?
--- @return boolean
local function firstRunPending()
    return Network.config.firstRunDone ~= true
end

--- Which popups are due on this screen. The first-run ones come first, on the
--- title screen and main menu. A restart notice shows anywhere but over a level,
--- where it would take the keyboard from the game: it waits for the camp or a menu.
--- @return table?
local function duePopups(screen)
    if firstRunPending() and (screen == SCREEN.MENU or screen == SCREEN.TITLE) then
        return FIRST_RUN
    end
    if restartPending and screen ~= SCREEN.LEVEL and screen ~= SCREEN.TRANSITION then
        return RESTART
    end
    return nil
end

--- The mods played online changed and need a restart (setupUI).
function module.showRestartNotice()
    restartPending = true
end

-- The controller's presses for this GUI frame's popup, counted from menuInput's
-- queue. A popup answers to UP, DOWN and SELECT; BACK does nothing, like ESC.
local padUp, padDown, padSelect = 0, 0, 0

--- @param action string
local function countPopupPad(action, _isRepeat)
    if action == "up" then
        padUp = padUp + 1
    elseif action == "down" then
        padDown = padDown + 1
    elseif action == "select" then
        padSelect = padSelect + 1
    end
end

--- One frame of a popup sequence: the keys, then the drawing.
--- @param ctx GuiDrawContext
--- @param seq table # FIRST_RUN or RESTART
--- @param wasDrawn boolean # a popup was on screen last frame
local function popupFrame(ctx, seq, wasDrawn)
    -- the game's own menu is underneath and must not see these keys
    pcall(function()
        get_io().wantkeyboard = true
    end)
    local now = get_ms()
    if popupSeq ~= seq or not wasDrawn or popupShownMs == nil then
        -- a direction already held on the controller is not a press for this popup
        if MenuInput ~= nil then
            MenuInput.beginCapture()
        end
    end
    if popupSeq ~= seq then
        popupSeq, popupStep, popupChoice, popupLayout = seq, 1, 1, nil
        popupShownMs = now
    elseif not wasDrawn or popupShownMs == nil then
        popupShownMs = now -- back on screen after time away: the pause applies again
    end
    local popup = seq[popupStep]
    padUp, padDown, padSelect = 0, 0, 0
    if MenuInput ~= nil then
        MenuInput.drain(countPopupPad)
    end
    if pressed(KEYS.up) or padUp > 0 then
        popupChoice = popupChoice > 1 and popupChoice - 1 or #popup.buttons
    end
    if pressed(KEYS.down) or padDown > 0 then
        popupChoice = popupChoice < #popup.buttons and popupChoice + 1 or 1
    end
    if now - popupShownMs >= POPUP_INPUT_DELAY_MS
        and (pressed(KEYS.select) or pressed(KEYS.commit) or padSelect > 0)
    then
        if popup.setting ~= nil then
            Network.config[popup.setting] = popup.buttons[popupChoice].value == true
        end
        local last = popupStep >= #seq
        if not last then
            popupStep = popupStep + 1
            popupChoice = 1
            popupShownMs = now
            popupLayout = nil
        else
            popupSeq = nil
            popupClosedMs = now
            if seq == FIRST_RUN then
                Network.config.firstRunDone = true
            else
                restartPending = false
            end
        end
        if seq == FIRST_RUN then
            Network.saveConfig()
        end
        if last then
            return
        end
        popup = seq[popupStep]
    end
    -- Measuring wraps the whole paragraph, so it is kept; this one width changes
    -- with the window size, which is the only other thing the layout depends on.
    local metric = textWidth(22, "MODDED ONLINE")
    if popupLayout == nil or popupLayout.seq ~= seq or popupLayout.step ~= popupStep
        or popupLayout.metric ~= metric
    then
        popupLayout = measurePopup(popup)
        popupLayout.seq = seq
        popupLayout.step = popupStep
        popupLayout.metric = metric
    end
    if not (VanillaUI ~= nil and VanillaUI.serving("popup")) then
        drawPopup(ctx, popup, popupLayout)
    end
end

-- ---------------------------------------------------------------- api

--- Open the menu on its root page: the ONLINE row's SELECT (mainMenuHook), or the
--- [O] key where the takeover is not in place.
--- @param source string? # for the probe log
--- @param unarmed boolean? # no ARM_MS pause: the key that opened it is not a menu key
function module.open(source, unarmed)
    if page ~= nil then
        return
    end
    page = "root"
    cursor = 1
    editing = nil
    openedMs = (unarmed ~= true) and get_ms() or nil
    releaseUntilMs = nil
    if MenuInput ~= nil then
        MenuInput.beginCapture()
    end
    if MenuProbe ~= nil and MenuProbe.note ~= nil then
        MenuProbe.note("menuUI: opened (%s)", tostring(source))
    end
end

--- Close the menu (VANILLA ONLINE hands the main menu back).
function module.close()
    closeMenu()
end

--- @return boolean
function module.isOpen()
    return page ~= nil
end

--- Was a popup on screen at the last GUI frame?
--- @return boolean
function module.popupVisible()
    return popupDrawn
end

--- When capturing() was last asked. It is asked every engine update, so a long gap
--- means the whole game was stopped (a process launch, a load), not just its GUI.
local lastAskedMs = nil
--- Longer than this between two asks is the whole game stopping, not the GUI.
local STALL_MS = 250

--- Should the game's menu input be ours right now (menuInput asks every update)?
--- The menu or a popup is up, or one just closed and its key may still be down.
---
--- Only while GUI frames are arriving: if they stop, nothing of ours is on screen,
--- and a menu still open would leave the main menu deaf for no visible reason. It
--- is closed instead, and the game gets its input back.
---
--- Not when the WHOLE game stopped: dev69's first session closed the menu with "no
--- GUI frame for 7698 ms" right after HOST, because the game itself had frozen for
--- 7.7 s (the bridge launching) and the first update after it ran before the first
--- GUI frame. A gap in the asking itself is that: the GUI clock starts again.
--- @return boolean
function module.capturing()
    if lastGuiMs == nil then
        return false
    end
    local now = get_ms()
    if lastAskedMs ~= nil and now - lastAskedMs > STALL_MS then
        lastGuiMs = now
    end
    lastAskedMs = now
    if now - lastGuiMs > GUI_STALE_MS then
        if page ~= nil then
            page, editing, openedMs = nil, nil, nil
            if MenuProbe ~= nil and MenuProbe.note ~= nil then
                MenuProbe.note("menuUI: closed -- no GUI frame for %d ms", now - lastGuiMs)
            end
        end
        return false
    end
    if page ~= nil or popupDrawn then
        return true
    end
    if releaseUntilMs ~= nil and now < releaseUntilMs then
        return true
    end
    return popupClosedMs ~= nil and now - popupClosedMs < POPUP_RELEASE_MS
end

-- ---------------------------------------------------------------- frame

--- What is on screen, as of the last GUI frame: the game's look draws these (see
--- "the game's look" below), and the ImGui version only where it is not.
local show = { menu = false, popup = false, camp = false, code = false, waiting = false,
               status = false }

--- Is the game's look drawing `name` (src/vanillaUI.lua)? Then the ImGui version stays
--- out of the way.
--- @param name string
--- @return boolean
local function vanillaServing(name)
    return VanillaUI ~= nil and VanillaUI.serving(name)
end

--- @param ctx GuiDrawContext
local function guiFrame(ctx)
    lastGuiMs = get_ms()
    local screen = get_local_state().screen
    local wasDrawn = popupDrawn
    popupDrawn = false
    show.menu, show.popup, show.camp, show.code, show.waiting, show.status =
        false, false, false, false, false, false
    if Network.isInRun() then
        if screen == SCREEN.LEVEL or screen == SCREEN.TRANSITION then
            -- Held on a transition waiting for the other players to finish with
            -- it reads exactly the same to the player as a lockstep stall, and
            -- without this the screen simply ignores them for no stated reason.
            local holding = EventSync ~= nil and EventSync.transitionHolding ~= nil
                and EventSync.transitionHolding()
            if InputSync.isStalled() or holding then
                -- stalled: the framed plaque replaces the status line
                show.waiting = true
                if not vanillaServing("waiting") then
                    drawWaitingPanel(ctx)
                end
            else
                show.status = true
                if not vanillaServing("status") then
                    drawRunStatus(ctx)
                end
            end
        end
        -- local cosmetic fade over a back-layer swap (mimics the vanilla door
        -- transition); drawn last so it dims everything, on our own view only
        local fade = EventSync ~= nil and EventSync.layerFadeAlpha ~= nil
            and EventSync.layerFadeAlpha() or 0
        if fade > 0 then
            ctx:draw_rect_filled(-1, 1, 1, -1, 0, rgba(0, 0, 0, fade))
        end
        return
    end
    -- Popups come before anything else outside a run, the MODDED ONLINE menu
    -- included.
    local seq = duePopups(screen)
    if seq ~= nil then
        if page ~= nil then
            closeMenu()
        end
        popupDrawn = true
        show.popup = true
        popupFrame(ctx, seq, wasDrawn)
        return
    end
    if (popupClosedMs ~= nil and get_ms() - popupClosedMs < POPUP_RELEASE_MS)
        or (releaseUntilMs ~= nil and get_ms() < releaseUntilMs)
    then
        pcall(function()
            get_io().wantkeyboard = true
        end)
        if MenuInput ~= nil then
            MenuInput.clear()
        end
        return
    end
    if screen == SCREEN.CAMP and Network.isActive() then
        show.camp = true
        if not vanillaServing("camp") then
            drawCampStatus(ctx)
        end
        return
    end
    if screen == SCREEN.CHARACTER_SELECT then
        if page ~= nil then
            closeMenu() -- the play flow launched; our menu has no business here
        end
        -- Show the room code while the player is still CHOOSING; hide it the moment
        -- they confirm and the screen begins fading out (loading leaves NONE).
        if Network.isActive() and get_local_state().loading == FADE.NONE
            and tostring(Network.room or "") ~= ""
        then
            show.code = true
            if not vanillaServing("code") then
                drawCharSelectCode(ctx)
            end
        end
        return
    end
    if screen ~= SCREEN.MENU and screen ~= SCREEN.TITLE then
        if page ~= nil then
            closeMenu()
        end
        return
    end
    if page == nil then
        editing = nil
        if MenuInput ~= nil then
            MenuInput.clear()
        end
        -- The main menu's own ONLINE row opens us (mainMenuHook). Only where that
        -- could not install does a small bronze "chip" advertise the open key,
        -- bottom-left.
        if fallbackKeys() then
            ctx:draw_rect_filled(-0.99, -0.845, -0.63, -0.925, 0.02, COLOR_PANEL)
            ctx:draw_rect(-0.99, -0.845, -0.63, -0.925, 0.02, 1.5, COLOR_BORDER)
            ctx:draw_text(-0.965, -0.87, 24, "[O]  MODDED ONLINE", COLOR_TITLE)
            if pressed(KEYS.open) then
                module.open("the O key", true)
            end
        end
        return
    end
    -- menu open: keep the game's own menu from reacting to our keys
    pcall(function()
        get_io().wantkeyboard = true
    end)
    pollConnect() -- may switch pages, or close the menu as the play flow begins
    if page ~= nil then
        handleInput()
    end
    if page ~= nil then
        show.menu = true
        if not vanillaServing("menu") then
            drawMenu(ctx)
        end
    end
end

-- ---------------------------------------------------------------- the game's look
--
-- The same menu, popups and plaques, drawn with the game's renderer, its font and
-- its own menu sprites (src/vanillaUI.lua). These run from the game's render
-- callbacks and draw whatever the last GUI frame decided is on screen (`show`); the
-- ImGui versions above are the fallback while these are not running.

--- The title on the scroll, per page: what the vanilla Options screen does with its
--- own sections.
local PAGE_TITLES = {
    root = "MODDED ONLINE", host = "HOST GAME", hostdedi = "DEDICATED SERVER",
    matchtype = "MATCHMAKING", matchsearch = "MATCHMAKING", matchnone = "NO OPEN GAMES",
    friendtype = "JOIN A FRIEND", joinofficial = "OFFICIAL SERVER", joindedi = "DEDICATED SERVER",
    settings = "SETTINGS", connecting = "CONNECTING",
}
--- Words that stay in capitals in Title Case.
local KEEP_CAPS = { IP = true, OK = true }

--- "HIDE ROOM CODE" as the main menu would write it: "Hide Room Code". The labels are
--- capitals for the ImGui look (and its tests); the game's own menus are in Title Case
--- (Play, Online, Player Profile), so this look writes them that way. A word with any
--- lowercase in it is left as it is ("1 file(s) synced").
--- @param s string
--- @return string
local function titleCase(s)
    return (s:gsub("%S+", function(word)
        if word:find("[a-z]") ~= nil or KEEP_CAPS[word] or #word < 2 then
            return word
        end
        return word:sub(1, 1) .. word:sub(2):lower()
    end))
end
module.titleCase = titleCase

--- The page fades in over this long when it opens.
local FADE_IN_MS = 150
local shownSinceMs = nil

--- @return table
local function menuModel()
    local items = pageItems()
    -- drawMenu clamps this too, and does not run while this look is drawing (a page
    -- can lose a row: VANILLA ONLINE goes when the takeover stands down)
    if cursor > #items then
        cursor = #items
    end
    local rows = {}
    local selectedChanges = false
    for i, item in ipairs(items) do
        local row = { name = titleCase(item.name or item.label),
                      value = item.value ~= nil and titleCase(item.value) or nil,
                      selected = i == cursor, changes = item.change ~= nil }
        if item.get ~= nil then
            local isEditing = editing == item.label
            local raw = isEditing and editBuffer or tostring(item.get() or "")
            if item.secret and Network.config.hideRoomCode and raw ~= "" then
                raw = string.rep("*", #raw)
            end
            row.field = (raw ~= "" or isEditing) and raw or "..."
            row.editing = isEditing
        end
        if i == cursor and item.change ~= nil then
            selectedChanges = true
        end
        rows[i] = row
    end
    local m = {
        title = page == "joined" and ("ROOM " .. shownCode(Network.room))
            or (PAGE_TITLES[page] or "MODDED ONLINE"),
        rows = rows,
        hintLeft = editing ~= nil and "ESC  Cancel" or "ESC / B  Back",
        hintRight = editing ~= nil and "ENTER  Save" or "Z / A  Select",
    }
    if editing ~= nil then
        m.middle = capsMode and "TYPE  (CAPS ON)" or "TYPE  -  SHIFT for capitals"
    elseif Network.PHASE ~= nil and Network.phase == Network.PHASE.CONNECTING then
        m.middle = page == "matchsearch" and "Searching for an open game..."
            or "Connecting to the server..."
    elseif page == "joined" then
        m.middle = "Joined! Starting the game..."
    elseif Network.lastError ~= nil then
        m.middle, m.middleError = "! " .. tostring(Network.lastError), true
    elseif selectedChanges then
        m.middle = "LEFT / RIGHT  Change"
    end
    local now = get_ms()
    shownSinceMs = shownSinceMs or now
    m.alpha = math.min(1, (now - shownSinceMs) / FADE_IN_MS)
    return m
end

local function vanillaMenu(ctx, screen)
    if not show.menu or page == nil or (screen ~= SCREEN.MENU and screen ~= SCREEN.TITLE) then
        shownSinceMs = nil
        return false
    end
    VanillaUI.page(ctx, menuModel())
    return true
end

local function vanillaPopup(ctx, _screen)
    if not show.popup or popupSeq == nil then
        return false
    end
    local popup = popupSeq[popupStep]
    if popup == nil then
        return false
    end
    -- as written: the popups' titles and buttons are already in the main menu's Title
    -- Case (the ImGui look is what puts them in capitals)
    local buttons = {}
    for i, button in ipairs(popup.buttons) do
        buttons[i] = button.label
    end
    VanillaUI.dialog(ctx, {
        title = popup.title,
        text = popup.text,
        buttons = buttons,
        choice = popupChoice,
        footer = #buttons > 1 and "ARROWS move     Z / A  Select" or "Z / A  Select",
    })
    return true
end

local function vanillaCamp(ctx, _screen)
    if not show.camp then
        return false
    end
    local header, hint, players = campView()
    local lines = { { header, "gold", 20 }, { hint, "dim", 15 } }
    for _, player in ipairs(players) do
        lines[#lines + 1] = { player[1], player[2] and "row" or "dim", 17 }
    end
    VanillaUI.plaque(ctx, 24, 18, VanillaUI.plaqueWidth(ctx, lines, 360, 720), lines)
    return true
end

local function vanillaCode(ctx, _screen)
    local code = tostring(Network.room or "") -- raw: always visible here (drawCharSelectCode)
    if not show.code or code == "" then
        return false
    end
    local lines = { { "ROOM  " .. code, "gold", 30 }, { "invite friends with this code", "dim", 14 } }
    local w = VanillaUI.plaqueWidth(ctx, lines, 300, 560)
    local h = VanillaUI.plaqueHeight(lines)
    VanillaUI.plaque(ctx, 1920 - 24 - w, 1080 - 24 - h, w, lines)
    return true
end

local WAITING_LINES = { { "WAITING FOR PLAYERS", "gold", 20 },
                        { "Syncing with the other players...", "dim", 15 } }

local function vanillaWaiting(ctx, _screen)
    if not show.waiting then
        return false
    end
    VanillaUI.plaque(ctx, 24, 18, VanillaUI.plaqueWidth(ctx, WAITING_LINES, 360, 600),
        WAITING_LINES)
    return true
end

local function vanillaStatus(ctx, _screen)
    if not show.status then
        return false
    end
    VanillaUI.shadowText(ctx, runStatusLine(), 14, 14, 15, "dim", "left", "bold")
    return true
end

if VanillaUI ~= nil and VanillaUI.layer ~= nil then
    VanillaUI.layer("menu", 10, vanillaMenu)
    VanillaUI.layer("camp", 20, vanillaCamp)
    VanillaUI.layer("code", 20, vanillaCode)
    VanillaUI.layer("waiting", 20, vanillaWaiting)
    VanillaUI.layer("status", 20, vanillaStatus)
    VanillaUI.layer("popup", 40, vanillaPopup)
end

-- Global infrastructure callback (menu UI must exist outside any level).
set_callback(function(ctx)
    if DesyncLog ~= nil then
        DesyncLog.frameMark("guiframe:menuUI")
    end
    SafeCall("menuUI:guiFrame", guiFrame, ctx)
    if DesyncLog ~= nil then
        DesyncLog.frameDone("guiframe:menuUI")
    end
end, ON.GUIFRAME)

NetMenuUI = module
return module
