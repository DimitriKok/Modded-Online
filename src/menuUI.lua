--- Modded Online — the ONLINE MODDED menu.
---
--- A game-styled fullscreen menu drawn over the main menu (no Playlunky
--- options tab involved). A hint on the main menu shows the open key; while
--- the menu is open the game's own keyboard input is suppressed
--- (io.wantkeyboard), so navigation can use the normal keys.
---
---   ONLINE MODDED
---     HOST  -> Name / Server IP / Server Port / HOST NEW GAME
---     JOIN  -> Server IP / Room Code / JOIN GAME
---
--- Hosting/joining connects and launches the game's play flow: pick your
--- character, land in the camp (that marks you READY), and the host starts
--- the run by entering the camp's main door.

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

--- Width of a text run in draw-space, for centering. Falls back to a rough
--- estimate if the size query is unavailable on this build.
--- @param ctx GuiDrawContext
--- @return number
local function textWidth(ctx, size, text)
    -- draw_text_size returns two dimensions and, on some builds, not width-first
    -- (which shifted every centered label). Menu strings are multi-character, so
    -- width is the LARGER dimension — taking the max centers correctly whatever
    -- the pair's order. Falls back to a rough estimate if the query is missing.
    local ok, a, b = pcall(function() return ctx:draw_text_size(size, text) end)
    if ok and type(a) == "number" then
        local w = math.abs(a)
        if type(b) == "number" then
            w = math.max(w, math.abs(b))
        end
        return w
    end
    return #text * size * 0.0009
end

--- Draw text horizontally centered on `cx`.
--- @param ctx GuiDrawContext
local function drawCentered(ctx, cx, y, size, text, color)
    ctx:draw_text(cx - textWidth(ctx, size, text) / 2, y, size, text, color)
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

-- nil=closed. Pages: root | host | hostdedi | matchtype | matchsearch |
-- matchnone | friendtype | joinofficial | joindedi
local page = nil        --- @type string?
local cursor = 1
local editing = nil     --- @type string? # label of the field being typed into
local editBuffer = ""
local roomCode = ""

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
    open = KEY.O,
    up = KEY.UP,
    down = KEY.DOWN,
    select = KEY.Z,          -- menu confirm, like the game's jump button
    commit = KEY.RETURN,     -- finish typing in a text field
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
    page = nil
    editing = nil
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

local function doHost()
    Network.saveConfig()
    Network.hostGame()
    closeMenu()
end

local function doHostOfficial()
    Network.saveConfig()
    Network.hostOfficial()
    closeMenu()
end

local function doJoin()
    Network.saveConfig()
    Network.joinGame(roomCode)
    closeMenu()
end

local function doJoinOfficial()
    Network.saveConfig()
    Network.joinOfficial(roomCode)
    closeMenu()
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
    closeMenu()
end

--- JOIN EXISTING GAME: drop into a public game already in progress (late-join).
local function doMatchmakeStarted()
    Network.saveConfig()
    Network.matchmake("started")
    closeMenu()
end

-- ESC / the open key steps one page back up this tree (root closes the menu).
local PARENT = {
    host = "root", hostdedi = "host",
    friendtype = "root",
    joinofficial = "friendtype", joindedi = "friendtype",
    matchtype = "root", matchsearch = "matchtype", matchnone = "matchtype",
}

--- Streamer toggle: mask the room code everywhere it's shown. A Z-select action
--- whose label reflects the current state (pageItems runs each frame).
local function hideCodeToggle()
    return {
        label = "HIDE ROOM CODE  [" .. (Network.config.hideRoomCode and "ON" or "OFF") .. "]",
        action = function()
            Network.config.hideRoomCode = not Network.config.hideRoomCode
            Network.saveConfig()
        end,
    }
end

--- Solo testing: put stand-in players in whatever room we open next, so the
--- multiplayer paths can be exercised with nobody else online. Cycles
--- OFF -> 1 -> 2 -> 3 -> OFF; three is a full room, since we are the fourth.
--- Off by default, and the label always states the current count.
local function testPlayerToggle()
    local count = math.floor(tonumber(Network.config.testPlayer) or 0)
    return {
        label = "TEST PLAYERS  [" .. (count > 0 and tostring(count) or "OFF") .. "]",
        action = function()
            local next_ = math.floor(tonumber(Network.config.testPlayer) or 0) + 1
            if next_ > Network.MAX_TEST_PLAYERS then
                next_ = 0
            end
            Network.config.testPlayer = next_
            Network.saveConfig()
            -- changing the count mid-session should affect the room we are in
            -- now, not only the next one (launchTestPlayer replaces the old set)
            if next_ > 0 then
                Network.launchTestPlayer()
            else
                Network.stopTestPlayers()
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
        action = function()
            if SaveShare ~= nil and SaveShare.syncToMod ~= nil then
                SafeCall("menuUI:syncSaveData", SaveShare.syncToMod)
            end
        end,
    }
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
    end
    return {
        { label = "HOST", action = function() page = "host"; cursor = 1 end },
        { label = "JOIN", action = function() page = "friendtype"; cursor = 1 end },
        { label = "MATCHMAKING", action = function() page = "matchtype"; cursor = 1 end },
        { label = "DISCORD", action = doDiscord },
        hideCodeToggle(),
        testPlayerToggle(),
        syncSaveItem(),
        { label = "CLOSE", action = closeMenu },
    }
end

local function handleInput(items)
    if editing ~= nil then
        pollTypedInput()
        if pressed(KEYS.commit) then
            for _, item in ipairs(items) do
                if item.label == editing and item.set ~= nil then
                    item.set(editBuffer)
                end
            end
            editing = nil
        elseif pressed(KEYS.back) then
            editing = nil -- cancel, keep the old value
        end
        return
    end
    if pressed(KEYS.up) then
        cursor = cursor > 1 and cursor - 1 or #items
    end
    if pressed(KEYS.down) then
        cursor = cursor < #items and cursor + 1 or 1
    end
    if pressed(KEYS.select) then
        local item = items[cursor]
        if item.action ~= nil then
            item.action()
        else
            editing = item.label
            editBuffer = item.get()
            capsMode = false
        end
    elseif pressed(KEYS.back) or pressed(KEYS.open) then
        if page == "root" then
            closeMenu()
        else
            if page == "matchsearch" then
                Network.leave() -- backing out of the search aborts the in-flight queue
            end
            page = PARENT[page] or "root"
            cursor = 1
        end
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
    local stripB = T - 0.17
    ctx:draw_rect_filled(L + 0.014, T - 0.018, R - 0.014, stripB, 0.02, COLOR_STRIP)
    ctx:draw_line(L + 0.03, stripB, R - 0.03, stripB, 2.0, COLOR_BORDER)
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
    })[page]
    if subtitle ~= nil then
        drawCentered(ctx, 0, stripB - 0.055, 22, subtitle, COLOR_DIM)
    end

    -- menu rows
    local y = stripB - (page == "root" and 0.115 or 0.15)
    local rowH = 0.12
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
        if selected then
            ctx:draw_rect_filled(L + 0.03, y + 0.05, R - 0.03, y - 0.06, 0.015, COLOR_HILITE)
            ctx:draw_text(L + 0.055, y, 30, "> " .. text, COLOR_SELECTED)
        else
            ctx:draw_text(L + 0.075, y, 28, text, COLOR_ITEM)
        end
        y = y - rowH
    end

    -- footer + connection status
    local footer = editing ~= nil
        and string.format("TYPE to edit    SHIFT caps    CAPSLOCK toggle%s    ENTER save    ESC cancel",
            capsMode and " (ON)" or "")
        or "ARROWS move     Z select     ESC back"
    drawCentered(ctx, 0, B + 0.11, 18, footer, COLOR_DIM)
    if Network.phase == Network.PHASE.CONNECTING then
        local status = (page == "matchsearch") and "Searching for an open game..."
            or "Connecting to the server..."
        drawCentered(ctx, 0, B + 0.055, 20, status, COLOR_TITLE)
    elseif Network.lastError ~= nil then
        drawCentered(ctx, 0, B + 0.055, 20, "! " .. Network.lastError, COLOR_ERROR)
    end
end

--- Camp status: who is ready, and how the run starts. Drawn in a small
--- framed stone plaque in the top-left so it reads over the camp.
--- @param ctx GuiDrawContext
local function drawCampStatus(ctx)
    local ready, total = 0, 0
    for _, player in ipairs(Network.lobbyPlayers) do
        total = total + 1
        if player.ready then
            ready = ready + 1
        end
    end
    local L, R, T = -0.98, -0.44, 0.98
    local B = 0.72 - math.max(0, total - 1) * 0.06
    drawPanel(ctx, L, T, R, B)
    ctx:draw_text(L + 0.03, T - 0.05, 22, string.format(
        "ROOM %s  %s   %d / %d READY", shownCode(Network.room),
        Network.isPublicRoom() and "[PUBLIC]" or "[PRIVATE]", ready, total), COLOR_TITLE)
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
    ctx:draw_text(L + 0.03, T - 0.11, 17, hint, COLOR_DIM)
    for index, player in ipairs(Network.lobbyPlayers) do
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
        ctx:draw_text(L + 0.03, T - 0.17 - (index - 1) * 0.06, 18,
            string.format("%s  %s%s", player.ready and "[READY]" or "[ ... ]",
                player.name, where),
            player.ready and COLOR_ITEM or COLOR_DIM)
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
        closeMenu() -- in a lobby now: character select launches from here
    elseif Network.lastErrorCode == "no_unstarted_game" then
        Network.lastError = nil
        Network.lastErrorCode = nil
        page = "matchnone"
        cursor = 1
    end
end

--- World-desync notice: this floor generated differently from the host's. A brief
--- In-run heads-up: room, player count and ping, top-left over the game.
--- @param ctx GuiDrawContext
local statusText = nil
local statusRoom, statusPlayers, statusPing, statusHidden = nil, nil, nil, nil

local function drawRunStatus(ctx)
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
    ctx:draw_text(-0.99, 0.99, 0, statusText, COLOR_DIM)
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

-- ---------------------------------------------------------------- frame

--- @param ctx GuiDrawContext
local function guiFrame(ctx)
    local screen = get_local_state().screen
    if Network.isInRun() then
        if screen == SCREEN.LEVEL or screen == SCREEN.TRANSITION then
            -- Held on a transition waiting for the other players to finish with
            -- it reads exactly the same to the player as a lockstep stall, and
            -- without this the screen simply ignores them for no stated reason.
            local holding = EventSync ~= nil and EventSync.transitionHolding ~= nil
                and EventSync.transitionHolding()
            if InputSync.isStalled() or holding then
                drawWaitingPanel(ctx) -- stalled: the framed plaque replaces the status line
            else
                drawRunStatus(ctx)
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
    if screen == SCREEN.CAMP and Network.isActive() then
        drawCampStatus(ctx)
        return
    end
    if screen == SCREEN.CHARACTER_SELECT then
        if page ~= nil then
            closeMenu() -- the play flow launched; our menu has no business here
        end
        -- Show the room code while the player is still CHOOSING; hide it the moment
        -- they confirm and the screen begins fading out (loading leaves NONE).
        if Network.isActive() and get_local_state().loading == FADE.NONE then
            drawCharSelectCode(ctx)
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
        -- a small bronze "chip" advertising the open key, bottom-left
        ctx:draw_rect_filled(-0.99, -0.845, -0.63, -0.925, 0.02, COLOR_PANEL)
        ctx:draw_rect(-0.99, -0.845, -0.63, -0.925, 0.02, 1.5, COLOR_BORDER)
        ctx:draw_text(-0.965, -0.87, 24, "[O]  MODDED ONLINE", COLOR_TITLE)
        editing = nil
        -- A freshly injected shim only takes effect on the NEXT launch, so say so
        -- plainly instead of leaving it to a console line nobody reads. There is
        -- deliberately NO restart hotkey: the game can't relaunch itself without
        -- dropping the Playlunky-injected mods, so the player restarts it.
        if pressed(KEYS.open) then
            page = "root"
            cursor = 1
        end
        return
    end
    -- menu open: keep the game's own menu from reacting to our keys
    pcall(function()
        get_io().wantkeyboard = true
    end)
    if page == "matchsearch" then
        pollMatchSearch() -- may switch pages or close the menu on the queue result
    end
    if page ~= nil then
        handleInput(pageItems())
    end
    if page ~= nil then
        drawMenu(ctx)
    end
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
