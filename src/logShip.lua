--- Modded Online — desync logs to the Discord channel the room's server posts to,
--- for players who switched that on.
---
--- The game has no HTTP of its own, only UDP to the Modded Online server, so the
--- server is the courier: it reassembles the log and posts it with its Discord bot
--- (server.py `on_logup`, DISCORD.md). A run counts as desynced when this machine
--- saw a FLOOR DESYNC, a POSITION DESYNC or a resync warp, or another player in the
--- room reported one -- the host never sees a FLOOR DESYNC, only the peers do, and
--- the reason a pair of logs is worth anything is that it is a PAIR.
---
--- WHEN it goes: the moment the "Desync detected" popup appears (a POSITION DESYNC),
--- this run's log so far goes at once, and the room is asked for theirs, which follow
--- within a few seconds (desyncNow). Anything else that desyncs a run -- a FLOOR
--- DESYNC, which only the peers see and which has no popup, or a report from the
--- room that never became one here -- goes when the run ends, as it always did. A
--- resync warp after a popup does not send the run a second time: it is how the
--- incident already sent ends. Either way it is this run's own section of
--- desync_log.txt.
---
--- Nothing is sent unless the player switched on AUTOMATICALLY SEND LOGS (Modded
--- Online's SETTINGS page, `Network.config.autoSendLogs`), and nothing is sent to a
--- server that does not say it forwards logs. The server takes IP addresses and the
--- Windows account name out before it posts.

local module = {}

-- 675 raw bytes is exactly 900 base64 characters with no padding, so every part
-- but the last encodes on its own and the server can simply join them.
local PART_BYTES = 675
local WINDOW = 32               -- parts sent ahead of the server's ack
local PER_FRAME = 8             -- parts put on the wire per GUI frame, at most
local PART_RESEND_MS = 1500     -- an unacknowledged part goes again after this
local BEGIN_RESEND_MS = 1500    -- the opening message, until the server answers
local POKE_MS = 5000            -- all parts in: nudge if Discord's answer is slow
local STALL_GIVE_UP_MS = 20000  -- no progress at all for this long: drop it
local DONE_WAIT_MS = 90000      -- all parts in, still no answer from Discord
local PENDING_MAX_MS = 30 * 60 * 1000 -- a log waiting for a server to send it to
local MAX_PENDING = 2
-- The server takes 4 MB. A longer run keeps its head (the header says what it was)
-- and its tail (where the trouble is), and says what it cut.
local MAX_BYTES = 4 * 1024 * 1024 - 4096
local KEEP_HEAD = 64 * 1024
-- A log sent at the popup goes while the run carries on, over the same connection
-- as the lockstep inputs. So while the run lasts it is paced -- one part at a time,
-- about thirty a second (some 30 KB/s), few in flight -- where a log sent after the
-- run goes as fast as the window allows.
local RUN_PART_GAP_MS = 33
local RUN_WINDOW = 8
-- How long a machine asked for its log by another's popup waits for its OWN popup,
-- which usually follows within a couple of seconds: its log then holds its own
-- POSITION DESYNC block too. Room VOYY's two alarms were 2 s apart.
local ROOM_ASK_WAIT_MS = 5000

local runNote = nil      -- why this run counts as desynced: the first reason seen
local unsent = nil       -- a desync noted since the last log was queued, if any
local snapKey = nil      -- the lockstep seq whose popup log is already queued
local deferred = nil     -- { atMs, reason, key }: the room asked for our log
local announced = false  -- told the room already, this run
local pending = {}       -- { text, info, queuedMs, midRun } waiting for a server
local current = nil      -- the upload in progress
local noForwardNoticeShown = false

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64CHARS = {}
for i = 1, 64 do
    B64CHARS[i - 1] = B64:sub(i, i)
end

--- Standard base64 (RFC 4648, with padding).
--- @param data string
--- @return string
function module.base64(data)
    local out, o = {}, 0
    local n = #data
    for i = 1, n - 2, 3 do
        local a, b, c = data:byte(i, i + 2)
        local v = (a << 16) | (b << 8) | c
        o = o + 1
        out[o] = B64CHARS[v >> 18] .. B64CHARS[(v >> 12) & 63]
            .. B64CHARS[(v >> 6) & 63] .. B64CHARS[v & 63]
    end
    local rest = n % 3
    if rest == 1 then
        local v = data:byte(n) << 16
        o = o + 1
        out[o] = B64CHARS[v >> 18] .. B64CHARS[(v >> 12) & 63] .. "=="
    elseif rest == 2 then
        local a, b = data:byte(n - 1, n)
        local v = (a << 16) | (b << 8)
        o = o + 1
        out[o] = B64CHARS[v >> 18] .. B64CHARS[(v >> 12) & 63] .. B64CHARS[(v >> 6) & 63] .. "="
    end
    return table.concat(out)
end

--- Is AUTOMATICALLY SEND LOGS on? Read live: switching it off mid-upload stops
--- the upload.
--- @return boolean
function module.enabled()
    return Network ~= nil and Network.config ~= nil and Network.config.autoSendLogs == true
end

local function say(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    if ok and rawget(_G, "dbg") ~= nil then
        pcall(dbg, "logShip: " .. text)
    end
end

local function notify(text)
    if rawget(_G, "toast") ~= nil then
        pcall(toast, text)
    end
end

-- -------------------------------------------------------------- the run

--- A new run: nothing has desynced in it yet.
function module.runStarted()
    runNote = nil
    unsent = nil
    snapKey = nil
    deferred = nil
    announced = false
end

--- Something desynced. Kept as the run's reason if it is the first, and announced
--- to the room once, so every player who opted in sends their side of it.
--- @param reason string
--- @param fromRoom boolean? # another player reported it: do not echo it back
--- @param followUp boolean? # what follows an incident already sent (a resync warp):
---                          # no reason to send the run again by itself
function module.noteDesync(reason, fromRoom, followUp)
    if runNote == nil then
        runNote = tostring(reason)
    end
    if unsent == nil and not (followUp and snapKey ~= nil) then
        unsent = tostring(reason)
    end
    if fromRoom or announced then
        return
    end
    if Network ~= nil and Network.isInRun ~= nil and Network.isInRun() then
        announced = true
        Network.sendEvent("desyncseen", { r = tostring(reason):sub(1, 120) })
    end
end

--- @param text string
--- @param reason string
--- @param midRun boolean
local function queue(text, reason, midRun)
    if #pending >= MAX_PENDING then
        table.remove(pending, 1)
    end
    pending[#pending + 1] = {
        text = module.fit(text), info = module.describeRun(reason), queuedMs = get_ms(),
        midRun = midRun,
    }
    say("queued %s log (%s, %d bytes)", midRun and "this desync's" or "this run's",
        reason, #text)
    if Network ~= nil and Network.serverForwardsLogs ~= true and not noForwardNoticeShown then
        noForwardNoticeShown = true
        notify("This server isn't set up to post desync logs — yours will go when you're on one that is")
    end
end

--- This run's log so far, queued now, once per desynced floor.
--- @param reason string
--- @param key integer? # the lockstep seq of the floor that desynced
local function snapshot(reason, key)
    deferred = nil
    if key ~= nil and key == snapKey then
        return -- this floor's is already on its way
    end
    if not module.enabled() then
        return
    end
    local text = nil
    if DesyncLog ~= nil and DesyncLog.currentRunText ~= nil then
        text = DesyncLog.currentRunText()
    end
    if type(text) ~= "string" or text == "" then
        say("desync (%s) but its log could not be read", tostring(reason))
        return
    end
    snapKey = key
    unsent = nil
    queue(text, reason, true)
end

--- The "Desync detected" popup, on this machine: the log goes NOW, and the room is
--- asked for theirs (ROOM_ASK_WAIT_MS).
--- @param reason string
--- @param key integer? # the lockstep seq of the floor
function module.desyncNow(reason, key)
    reason = tostring(reason)
    module.noteDesync(reason, true)
    if Network ~= nil and Network.isInRun ~= nil and Network.isInRun() then
        announced = true
        Network.sendEvent("desyncseen", { r = reason:sub(1, 120), now = 1, s = key })
    end
    snapshot(reason, key)
end

--- @param payload { r: string?, now: integer?, s: integer? }
--- @param originSlot integer
local function onDesyncSeen(payload, originSlot)
    if Network == nil or not Network.isInRun() then
        return -- a report that outlived its run must not mark the next one
    end
    if originSlot == Network.slot then
        return -- our own report: the server sends every event to everyone, us too
    end
    local why = type(payload) == "table" and tostring(payload.r or "desync") or "desync"
    local reason = string.format("slot %s reported %s", tostring(originSlot), why)
    module.noteDesync(reason, true)
    if type(payload) == "table" and tonumber(payload.now) == 1 then
        -- their popup: ours goes too, once our own has had a moment to come up
        local key = tonumber(payload.s)
        key = key ~= nil and math.floor(key) or nil
        if (key == nil or key ~= snapKey) and deferred == nil then
            deferred = { atMs = get_ms() + ROOM_ASK_WAIT_MS, reason = reason, key = key }
        end
    end
end

--- This run's log, trimmed to what the server accepts.
--- @param text string
--- @return string
function module.fit(text)
    if #text <= MAX_BYTES then
        return text
    end
    local tailBytes = MAX_BYTES - KEEP_HEAD - 128
    local cut = #text - KEEP_HEAD - tailBytes
    return text:sub(1, KEEP_HEAD)
        .. string.format("\n[... %d bytes cut from the middle to fit the upload ...]\n", cut)
        .. text:sub(#text - tailBytes + 1)
end

--- @param reason string
--- @return table
function module.describeRun(reason)
    local seed = "?"
    pcall(function()
        local a, b = get_adventure_seed(false)
        seed = string.format("%08X-%08X", math.floor(a) & 0xFFFFFFFF, math.floor(b) & 0xFFFFFFFF)
    end)
    local mods = ""
    pcall(function()
        mods = tostring(Network.modSignature()):sub(1, 300)
    end)
    local version = "?"
    pcall(function()
        version = tostring(meta.version)
    end)
    return { reason = tostring(reason):sub(1, 200), version = version, seed = seed, mods = mods }
end

--- The run is over (DesyncLog.close, which every way a run ends goes through).
--- If it desynced and the player opted in, this run's log is queued to go.
function module.runEnded()
    local note, fresh, sentOne = runNote, unsent, snapKey ~= nil
    runNote = nil
    unsent = nil
    snapKey = nil
    deferred = nil -- the room asked and the run ended first: the run's log covers it
    announced = false
    if note == nil or fresh == nil or not module.enabled() then
        return -- clean, or nothing since the log already sent at the popup
    end
    local text = nil
    if DesyncLog ~= nil and DesyncLog.currentRunText ~= nil then
        text = DesyncLog.currentRunText()
    end
    if type(text) ~= "string" or text == "" then
        say("run desynced (%s) but its log could not be read", note)
        return
    end
    local reason = note
    if sentOne and fresh ~= note then
        reason = fresh .. " (after " .. note .. ")"
    end
    queue(text, reason, false)
end

-- -------------------------------------------------------------- the upload

local function partData(upload, index)
    local cached = upload.encoded[index]
    if cached == nil then
        local first = (index - 1) * PART_BYTES + 1
        cached = module.base64(upload.text:sub(first, first + PART_BYTES - 1))
        upload.encoded[index] = cached
    end
    return cached
end

local function sendPart(upload, index, now)
    upload.sentAt[index] = now
    upload.lastPartMs = now
    Network.sendServer({ t = "logup", op = "part", u = upload.id, i = index,
        d = partData(upload, index) })
end

local function sendBegin(upload, now)
    upload.lastBeginMs = now
    Network.sendServer({ t = "logup", op = "begin", u = upload.id, n = upload.parts,
        bytes = #upload.text, meta = upload.info })
end

local function finish(ok, why)
    if current == nil then
        return
    end
    say("upload %s %s: %s", current.id, ok and "POSTED" or "FAILED", tostring(why))
    if ok then
        notify("Desync log sent to Discord — thank you!")
    else
        notify("Desync log not sent: " .. tostring(why))
    end
    current = nil
end

local function start(entry, now)
    local slot = Network ~= nil and Network.slot or 0
    return {
        id = string.format("s%s-%x", tostring(slot), math.floor(now)),
        text = entry.text,
        info = entry.info,
        queuedMs = entry.queuedMs,
        midRun = entry.midRun == true,
        lastPartMs = 0,
        parts = math.max(1, math.ceil(#entry.text / PART_BYTES)),
        phase = "begin",
        acked = 0,
        sentAt = {},
        encoded = {},
        lastBeginMs = 0,
        lastPokeMs = 0,
        progressMs = now,
    }
end

local function sendParts(upload, now)
    -- a log sent at the popup, while the run it came from is still going: paced
    local paced = upload.midRun and Network.isInRun ~= nil and Network.isInRun()
    local budget = PER_FRAME
    local window = WINDOW
    if paced then
        if now - upload.lastPartMs < RUN_PART_GAP_MS then
            return
        end
        budget = 1
        window = RUN_WINDOW
    end
    local last = math.min(upload.parts, upload.acked + window)
    for index = upload.acked + 1, last do
        if budget == 0 then
            return
        end
        local sent = upload.sentAt[index]
        if sent == nil or now - sent >= PART_RESEND_MS then
            sendPart(upload, index, now)
            budget = budget - 1
        end
    end
end

--- A server reply: {"t":"logup","op":..,"u":id,...}.
--- @param msg table
function module.onReply(msg)
    if current == nil or type(msg) ~= "table" or msg.u ~= current.id then
        return
    end
    local now = get_ms()
    local op = msg.op
    if op == "ready" or op == "ack" then
        if current.phase == "begin" then
            current.phase = "send"
            current.progressMs = now
        end
        local upto = math.floor(tonumber(msg.upto) or 0)
        if upto > current.acked then
            current.acked = math.min(upto, current.parts)
            current.progressMs = now
        end
        if current.acked >= current.parts and current.phase ~= "wait" then
            current.phase = "wait"
            current.progressMs = now
            current.lastPokeMs = now
        end
    elseif op == "refused" then
        finish(false, tostring(msg.why or "the server refused it"))
    elseif op == "done" then
        finish(msg.ok == true, tostring(msg.why or ""))
    end
end

--- Every GUI frame: start a queued log when there is a server to send it to, and
--- move the one in progress along.
function module.poll()
    local now = get_ms()
    if deferred ~= nil and now >= deferred.atMs then
        local ask = deferred
        deferred = nil
        if Network ~= nil and Network.isInRun ~= nil and Network.isInRun() then
            snapshot(ask.reason, ask.key)
        end
    end
    if current ~= nil and not module.enabled() then
        current = nil -- the player changed their mind: stop, send nothing more
        pending = {}
        return
    end
    if current == nil then
        while #pending > 0 and now - pending[1].queuedMs > PENDING_MAX_MS do
            table.remove(pending, 1)
        end
        if #pending > 0 and Network ~= nil and Network.isActive() and Network.serverForwardsLogs == true then
            current = start(table.remove(pending, 1), now)
            sendBegin(current, now)
        end
        return
    end
    if not Network.isActive() then
        -- The room is gone, and the server only takes logs from a room's members.
        -- Keep it and send it from the start next time.
        table.insert(pending, 1, { text = current.text, info = current.info,
            queuedMs = current.queuedMs, midRun = current.midRun })
        current = nil
        return
    end
    if current.phase == "begin" then
        if now - current.lastBeginMs >= BEGIN_RESEND_MS then
            sendBegin(current, now)
        end
        if now - current.progressMs > STALL_GIVE_UP_MS then
            finish(false, "the server did not answer")
        end
    elseif current.phase == "send" then
        sendParts(current, now)
        if now - current.progressMs > STALL_GIVE_UP_MS then
            finish(false, "the upload stopped getting through")
        end
    elseif current.phase == "wait" then
        -- Every part is in and the server is posting. If its answer was lost, a
        -- repeated part gets the answer again.
        if now - current.lastPokeMs >= POKE_MS then
            current.lastPokeMs = now
            sendPart(current, current.parts, now)
        end
        if now - current.progressMs > DONE_WAIT_MS then
            finish(false, "no answer from Discord")
        end
    end
end

--- For the tests and the log: what is queued and what is moving.
--- @return table
function module.status()
    return {
        pending = #pending,
        uploading = current ~= nil and current.id or nil,
        phase = current ~= nil and current.phase or nil,
        acked = current ~= nil and current.acked or 0,
        parts = current ~= nil and current.parts or 0,
        runNote = runNote,
        unsent = unsent,
        snapKey = snapKey,
        deferred = deferred ~= nil,
        midRun = current ~= nil and current.midRun or false,
    }
end

-- -------------------------------------------------------------- wiring

if Network ~= nil then
    if Network.onEvent ~= nil then
        Network.onEvent("desyncseen", onDesyncSeen)
    end
    if Network.onServerMessage ~= nil then
        Network.onServerMessage("logup", module.onReply)
    end
end

set_callback(function()
    if DesyncLog ~= nil then
        DesyncLog.frameMark("guiframe:logShip")
    end
    SafeCall("logShip:poll", module.poll)
    if DesyncLog ~= nil then
        DesyncLog.frameDone("guiframe:logShip")
    end
end, ON.GUIFRAME)

LogShip = module
return module
