--- Modded Online — text chat (lobby camp + in-run).
---
--- Press T while in the camp lobby or during a run to open the chat box,
--- type a message, ENTER to send (ESC cancels). Messages travel on the
--- server's reliable ordered event channel (kind "chat"), so everyone — sender
--- included — sees them in the same order. A lightweight "someone is typing"
--- notice rides a second event kind ("chat_typing").
---
--- Chat never touches the lockstep world simulation. While the box is open the
--- local spelunker is held still: during a run inputSync records neutral input
--- whenever Chat.isTyping() is true; in the camp (no lockstep) this module
--- zeroes the local input directly. So typing "wasd" never moves you.

local module = {}

local MAX_STORED = 30        -- messages kept in the log
local MAX_VISIBLE = 6        -- lines drawn on screen at once
local MESSAGE_TTL_MS = 12000 -- idle messages fade out after this; typing shows them all
local FADE_MS = 1500         -- last stretch of the TTL is a fade
local MAX_LEN = 120          -- longest message we send
local TYPING_REFRESH_MS = 4000  -- resend "I'm typing" this often while composing
local TYPING_TIMEOUT_MS = 10000 -- drop a remote "typing" notice if no refresh arrives

local messages = {}     -- { { slot, text, at }, ... } oldest first
local remoteTyping = {} -- slot -> expiry ms (someone else composing)
local typing = false
local buffer = ""
local capsMode = false
local lastTypingPingMs = 0

-- layout (normalized screen space, y up)
local MSG_BASE_Y = -0.60
local MSG_LINE_H = 0.052
local INDICATOR_Y = -0.655
local INPUT_Y = -0.73

-- ---------------------------------------------------------------- keyboard

-- Numeric VK codes only (the string KEY lookup resolves by first letter on this
-- build). CHORD semantics: while shift is held a bare keypressed(code) never
-- fires — the press only registers as SHIFT_MOD | code — so typing keys are
-- polled bare AND with the shift flag. Mirrors the menu's input handling.
local SHIFT_MOD = 0x200
pcall(function()
    if type(KEY.OL_MOD_SHIFT) == "number" then
        SHIFT_MOD = KEY.OL_MOD_SHIFT
    end
end)

local KEY_SPACE = 0x20
pcall(function()
    if type(KEY.SPACE) == "number" then
        KEY_SPACE = KEY.SPACE
    end
end)

-- The key that OPENS the chat box. Derived from KEY.A rather than written as
-- KEY.T on purpose: the string lookup resolves by first letter on this build (see
-- above), so KEY.T can come back as TAB — which is also the capitals toggle, and
-- would have been an unusually confusing bug. The letter codes are contiguous and
-- ASCII (pollTyping turns them straight into characters with string.char), so
-- offsetting from A is exact. 0x54 is 'T' if even KEY.A is unavailable.
local KEY_CHAT_OPEN = 0x54
pcall(function()
    if type(KEY.A) == "number" then
        KEY_CHAT_OPEN = KEY.A + (string.byte("T") - string.byte("A"))
    end
end)

--- @param code integer
--- @param allowRepeat boolean?
--- @return boolean
local function pressed(code, allowRepeat)
    local ok, hit = pcall(function()
        return get_io().keypressed(code, allowRepeat == true)
    end)
    return ok and hit == true
end

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

local SHIFT_DIGITS = {
    ["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%",
    ["6"] = "^", ["7"] = "&", ["8"] = "*", ["9"] = "(", ["0"] = ")",
}

local function append(ch)
    if #buffer < MAX_LEN then
        buffer = buffer .. ch
    end
end

--- Collect typed characters into the chat buffer.
local function pollTyping()
    if pressed(20) or pressed(9) then -- CAPS LOCK or TAB toggles capitals
        capsMode = not capsMode
    end
    for code = KEY.A, KEY.Z do
        local hit, shifted = typedKey(code)
        if hit then
            local ch = string.char(code)
            append((shifted ~= capsMode) and ch or ch:lower())
        end
    end
    for code = 48, 57 do -- top-row digits (shifted -> punctuation)
        local hit, shifted = typedKey(code)
        if hit then
            local d = string.char(code)
            append(shifted and (SHIFT_DIGITS[d] or d) or d)
        end
    end
    for code = 96, 105 do -- numpad digits
        if pressed(code, true) then
            append(string.char(code - 48))
        end
    end
    if typedKey(KEY_SPACE) then append(" ") end
    if typedKey(KEY.PERIOD) then append(".") end
    if typedKey(KEY.COMMA) then append(",") end
    do
        local hit, shifted = typedKey(KEY.MINUS)
        if hit then append(shifted and "_" or "-") end
    end
    do  -- OEM /? key -> ? shifted, / otherwise
        local hit, shifted = typedKey(191)
        if hit then append(shifted and "?" or "/") end
    end
    do  -- OEM '" key -> " shifted, ' otherwise
        local hit, shifted = typedKey(222)
        if hit then append(shifted and "\"" or "'") end
    end
    if pressed(KEY.BACKSPACE, true) then
        buffer = buffer:sub(1, -2)
    end
end

-- ---------------------------------------------------------------- state

--- True while the LOCAL player is composing. inputSync reads this to hold the
--- spelunker still during a run.
--- @return boolean
function module.isTyping()
    return typing
end

--- Flip local typing state and tell the room (start/stop notice). Guarded so a
--- disconnected client just goes quiet.
--- @param on boolean
local function setTyping(on)
    if on == typing then
        return
    end
    typing = on
    if not on then
        buffer = ""
    end
    lastTypingPingMs = get_ms()
    if Network ~= nil and Network.isActive() then
        pcall(function() Network.sendEvent("chat_typing", { on = on }) end)
    end
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- @param slot integer
--- @return string
local function nameOf(slot)
    local names = Network.playerNames or {}
    local name = names[tostring(slot)]
    if name ~= nil then
        return name
    end
    for _, player in ipairs(Network.lobbyPlayers or {}) do
        if player.slot == slot then
            return player.name
        end
    end
    return "Player " .. tostring(slot)
end

--- A chat message arrived (from anyone, including our own echo).
--- @param payload { text: string }
--- @param originSlot integer
local function onChat(payload, originSlot)
    if type(payload) ~= "table" or type(payload.text) ~= "string" then
        return
    end
    local slot = math.floor(tonumber(originSlot) or 0)
    remoteTyping[slot] = nil -- they just sent: no longer typing
    messages[#messages + 1] = {
        slot = slot,
        text = payload.text:sub(1, MAX_LEN),
        at = get_ms(),
    }
    while #messages > MAX_STORED do
        table.remove(messages, 1)
    end
end

--- A typing start/stop notice arrived.
--- @param payload { on: boolean }
--- @param originSlot integer
local function onChatTyping(payload, originSlot)
    if type(payload) ~= "table" then
        return
    end
    local slot = math.floor(tonumber(originSlot) or 0)
    if slot == Network.slot then
        return -- our own echo
    end
    if payload.on then
        remoteTyping[slot] = get_ms() + TYPING_TIMEOUT_MS
    else
        remoteTyping[slot] = nil
    end
end

-- ---------------------------------------------------------------- frame

--- Which other players are currently shown as typing (names), pruning expired.
--- @return string[]
-- Returned when nobody is typing, so the notice below costs no allocation in the
-- case that holds almost every frame. NEVER written to.
local NO_TYPERS = {}

local function currentTypers()
    local now = get_ms()
    local out = {}
    for slot, expiry in pairs(remoteTyping) do
        if now >= expiry then
            remoteTyping[slot] = nil
        elseif slot ~= Network.slot then
            out[#out + 1] = nameOf(slot)
        end
    end
    table.sort(out) -- stable presentation order (cosmetic)
    return out
end

--- @param ctx GuiDrawContext
local function guiFrame(ctx)
    if Network == nil or not Network.isActive() then
        if typing then
            typing = false
            buffer = ""
        end
        remoteTyping = {}
        return
    end
    local screen = get_local_state().screen
    local canChat = screen == SCREEN.LEVEL or screen == SCREEN.TRANSITION
        or screen == SCREEN.CAMP
    if not canChat then
        setTyping(false) -- leaving a chattable screen closes the box (and notifies)
        return
    end

    -- input
    if typing then
        pcall(function() get_io().wantkeyboard = true end) -- keep the game off our keys
        pollTyping()
        if pressed(KEY.RETURN) then
            local text = trim(buffer)
            setTyping(false)
            if text ~= "" then
                Network.sendEvent("chat", { text = text:sub(1, MAX_LEN) })
            end
        elseif pressed(KEY.ESCAPE) then
            setTyping(false)
        elseif get_ms() - lastTypingPingMs > TYPING_REFRESH_MS then
            -- keep the remote "typing" notice alive through a long compose
            lastTypingPingMs = get_ms()
            pcall(function() Network.sendEvent("chat_typing", { on = true }) end)
        end
    elseif pressed(KEY_CHAT_OPEN) then
        -- Edge-triggered (no repeat): holding T opens the box once, and the same
        -- physical press cannot also land in the buffer, because pollTyping only
        -- runs on later frames — by which point this is no longer a fresh press.
        setTyping(true)
        capsMode = false
    end

    -- messages: newest at the bottom, older stacked above
    local now = get_ms()
    local shown = {}
    for i = #messages, 1, -1 do
        local m = messages[i]
        if typing or now - m.at < MESSAGE_TTL_MS then
            shown[#shown + 1] = m -- newest first
            if #shown >= MAX_VISIBLE then break end
        end
    end
    for idx, m in ipairs(shown) do
        local y = MSG_BASE_Y + (idx - 1) * MSG_LINE_H -- idx 1 (newest) at the bottom
        local alpha = 255
        if not typing then
            local remaining = MESSAGE_TTL_MS - (now - m.at)
            if remaining < FADE_MS then
                alpha = math.max(0, math.floor(255 * remaining / FADE_MS))
            end
        end
        local name = nameOf(m.slot)
        -- draw the whole line, then overdraw just the name in gold at the SAME
        -- spot. No width measurement (draw_text_size was unreliable here and put
        -- the message on top of the name), so the message always follows it.
        ctx:draw_text(-0.98, y, 18, name .. ": " .. m.text, rgba(235, 235, 235, alpha))
        ctx:draw_text(-0.98, y, 18, name .. ":", rgba(255, 206, 92, alpha))
    end

    -- "someone is typing" notice. currentTypers allocates a table and sorts it;
    -- with nothing to prune and nobody typing there is nothing for it to do.
    local typers = NO_TYPERS
    if next(remoteTyping) ~= nil then
        typers = currentTypers()
    end
    if #typers > 0 then
        local text
        if #typers == 1 then
            text = typers[1] .. " is typing..."
        elseif #typers == 2 then
            text = typers[1] .. " and " .. typers[2] .. " are typing..."
        else
            text = "Several players are typing..."
        end
        ctx:draw_text(-0.98, INDICATOR_Y, 16, text, rgba(178, 158, 128, 210))
    end

    -- input line while composing, else a faint discovery hint
    if typing then
        ctx:draw_rect_filled(-0.99, INPUT_Y + 0.025, 0.4, INPUT_Y - 0.03, 0.01, rgba(20, 14, 10, 210))
        ctx:draw_rect(-0.99, INPUT_Y + 0.025, 0.4, INPUT_Y - 0.03, 0.01, 1.5, rgba(150, 96, 40, 235))
        -- full line in gold, then overdraw the "Say:" prompt dim (no measuring)
        ctx:draw_text(-0.975, INPUT_Y, 20, "Say: " .. buffer .. "_", rgba(255, 240, 150, 255))
        ctx:draw_text(-0.975, INPUT_Y, 20, "Say:", rgba(178, 158, 128, 220))
    elseif #shown == 0 and #typers == 0 then
        ctx:draw_text(-0.98, INPUT_Y, 16, "[T] chat", rgba(178, 158, 128, 90))
    end
end

--- In the camp/lobby there is no lockstep to feed neutral input for us, so
--- while typing we zero the local input directly. During a run inputSync owns
--- the input slots and handles this (via Chat.isTyping()), so we stay out.
local function suppressCampInput()
    if not typing or Network == nil or not Network.isActive() or Network.isInRun() then
        return
    end
    local ok, state = pcall(get_local_state)
    if ok and state ~= nil then
        pcall(function()
            local slots = state.player_inputs.player_slots
            for coopIndex = 1, 4 do
                slots[coopIndex].buttons = 0
                slots[coopIndex].buttons_gameplay = 0
            end
        end)
    end
end

Network.onEvent("chat", onChat)
Network.onEvent("chat_typing", onChatTyping)

-- Global infrastructure callbacks: no-ops unless a networked session is active.
set_callback(function(ctx)
    if DesyncLog ~= nil then
        DesyncLog.frameMark("guiframe:chat")
    end
    SafeCall("chat:guiFrame", guiFrame, ctx)
    if DesyncLog ~= nil then
        DesyncLog.frameDone("guiframe:chat")
    end
end, ON.GUIFRAME)
set_callback(function()
    if DesyncLog ~= nil then
        DesyncLog.frameMark("preUpdate:chat")
    end
    SafeCall("chat:suppressCampInput", suppressCampInput)
    if DesyncLog ~= nil then
        DesyncLog.frameDone("preUpdate:chat")
    end
end, ON.PRE_UPDATE)

Chat = module
return module
