--- Modded Online — lockstep input synchronization.
---
--- Every machine runs the SAME local co-op simulation (all players exist as
--- real co-op players) and only controller inputs travel over the network.
--- Each simulated frame is gated: it only runs once every player's input for
--- that frame has arrived, and every machine feeds identical inputs into the
--- identical simulation.
---
--- Frames are keyed per level: when a level starts, the gate engages with a
--- new sequence number and counts offsets from zero. This self-rebases every
--- level, so nothing about engine clocks, pauses, loading hitches or how
--- long each player lingers on the transition screen can skew the mapping.
--- Transition screens run free (press Z whenever you like); the next level
--- waits for everyone at offset zero.

local module = {}

-- Frames of local input delay = the latency budget before the lockstep gate
-- has to stall (and stall = the whole sim runs in slow motion for EVERYONE).
-- This is negotiated per run: the server sizes it to the lobby's worst ping
-- and hands every client the SAME value in the run_start payload, because the
-- delay is baked into the recorded input stream (which future frame each press
-- lands on, and how many neutral frames prefill every level) — it MUST match
-- on all machines or the worlds diverge. Falls back to DEFAULT when the server
-- sends nothing (older server / local play). Clamped so a bad ping reading
-- can't produce an absurd value.
local DEFAULT_INPUT_DELAY = 5   -- ~83 ms budget, fine for LAN / low ping
local MIN_INPUT_DELAY = 4
local MAX_INPUT_DELAY = 20      -- ~333 ms; beyond this the game is unplayable anyway
local INPUT_DELAY = DEFAULT_INPUT_DELAY
-- how many recent frames each input packet carries. Must comfortably exceed
-- how far ahead any machine can get (bounded by ~2*INPUT_DELAY under lockstep),
-- or a lost frame can slide out of every resend window before it's recovered —
-- a permanent stall. Also the window the disconnect handler relies on to
-- back-fill a departed player's inputs, so it scales WITH the delay.
local REDUNDANCY = INPUT_DELAY * 2 + 4
local CHECK_EVERY = 120    -- desync checksum cadence (frames within a level)
-- inputs are held neutral for the first second of every transition screen:
-- it prevents racing to the next level before everyone's simulation has
-- engaged, and gives both players a beat to see the tally. These are
-- SIMULATION frames (always 60/s) — display framerate does not affect it
local TRANSITION_HOLD = 60
-- cutscene pause flag: engine keeps running, timers pause; skip prompts live
local PAUSE_CUTSCENE = 4
-- minimum real time between redundant input resends. Resends used to fire
-- once per RENDERED frame, which at uncapped framerates meant hundreds of
-- throwaway UDP sockets per second — a crash risk, not a sync improvement
local RESEND_INTERVAL_MS = 40
-- pause flags that stop the engine (menu=1, loading=2, unknown=8/16, ankh=32).
-- cutscene (4) keeps the engine running, so it stays gated and synced.
local ENGINE_PAUSE_MASK = 1 | 2 | 8 | 16 | 32

-- was a CONTENT MOD freezing the game for its own UI last frame? Only used to
-- log the transition, so a desync around such a menu can be lined up between two
-- machines (see DesyncLog).
local modUiPauseWas = false

-- --------------------------------------------------- shared mod-UI menu cursor
-- A content mod that freezes the game for its OWN menu reads
-- player_slots[1].buttons directly, and the simulation is stopped while it is
-- up — so the lockstep gate never runs and each machine's menu would be driven
-- by its own pad. For the Darkside / Pit of 100 Trials level-up screen that is
-- not survivable: the mod keeps ONE stat block and applies every pick to
-- players[1] (rpg.lua:344-349), so two different picks cannot both exist. A real
-- capture had one machine's player 1 on 3 health and the other's on 2, and the
-- LUCK pick is worse — it widens a generation-time PRNG range (main.lua:717,
-- ON.POST_ROOM_GENERATION), which eventually spawns a different world. So while
-- such a menu is up, nobody's pad drives their own menu directly: every
-- machine's button EDGES are published on the server's ordered reliable channel
-- and replayed, in that one global order, into slot 1 on EVERY machine. Both
-- cursors land on the same item and confirm the same upgrade. Latency does not
-- affect correctness here — nothing is simulating, so only the ORDER of the
-- applied edges matters, and the channel makes that order identical.
-- MENU (64) and JOURNAL (128) are deliberately excluded: those open engine
-- screens, and replaying one onto a peer would change screens behind their back.
local MENU_EDGE_MASK = 1 | 2 | 4 | 8 | 16 | 32 | 256 | 512 | 1024 | 2048
-- The injection goes in from PRE_UPDATE like every other input write here: the
-- engine refills `buttons` from the device just BEFORE that callback and does
-- not touch it again for the rest of the frame, so a value written there is
-- what the mod's render callbacks read (v0.41.0 drove this very menu that way).
-- PRE_UPDATE keeps firing while the mod holds the pause — that is how the flag-1
-- clear above survives an alt-tab.
local MENU_PRESS_FRAMES = 8 -- hold a replayed press this many update frames...
local MENU_GAP_FRAMES = 6   -- ...then force a release, so the mod's own
                            -- press/release latch registers exactly one edge
-- Arming has to be counted in RENDER frames: the mod ignores input for its first
-- 60 of those (rpg.lua:241 decrements the cooldown once per render) and render
-- rate differs per machine, so an edge landing inside that window would be eaten
-- on one machine and taken on the other. Every machine QUEUES every edge and
-- only starts draining once ITS OWN count is past the cooldown — same clock as
-- the mod's countdown, so the margin over 60 holds at any framerate. Nothing is
-- lost, a slower machine just applies the same edge a moment later, and because
-- this is a purely local gate there is nothing to wait on a peer for. (v0.44.0
-- announced arming to the party and held every edge until all players had
-- announced; if any part of that handshake failed the queue stayed empty
-- forever, which meant we sat writing a neutral pad into a menu nobody could
-- then interact with. A gate that can deadlock is not worth its precision.)
local MENU_ARM_FRAMES = 90
-- ...with a wall-clock backstop in case the render counter never ticks: 2.5s is
-- past a 60-frame cooldown for anything down to 24fps
local MENU_ARM_MS = 2500
-- A menu that never closes is the hard freeze this whole path exists to prevent,
-- so it always loses to one that is merely wrong. Two escape hatches, both
-- ending in the same place: stop driving, hand the pad straight back, and let
-- the menu behave as it did before the shared cursor existed (each player
-- picking their own, and diverging — wrong, but playable and visible in the
-- log). The first fires when we have published presses and NONE of them ever
-- came back to be applied, which is the loop being broken rather than the
-- player thinking; the second is an absolute cap covering anything else,
-- including a pad we cannot read at all.
local MENU_DEAD_MS = 4000
local MENU_STUCK_MS = 20000
-- the mod re-raises its pause from a RENDER callback, so an update frame can
-- land in between and briefly see it clear; require a real run of clear frames
-- before tearing the shared cursor down, or a flicker would wipe the queue
local MENU_OFF_FRAMES = 8
local menuSyncOn = false
local menuSyncAbandoned = false
local menuOpenedMs = 0
local menuFrames = 0       -- render frames since this menu opened (arming)
local menuOffFrames = 0    -- consecutive update frames with the pause clear
local menuEdgesApplied = 0 -- replayed edges, logged so two logs can be compared
local menuEdgesSent = 0    -- edges WE published, logged next to the above
local menuFirstSentMs = 0  -- when the first of them went out (dead-loop timer)
local menuPadChanges = 0   -- times the pad read changed (proves reads are live)
local menuPrevRaw = 0      -- local pad last frame, for edge detection
local menuQueue = {}       -- agreed edges awaiting replay, in server order
local menuPress = 0        -- the edge currently being held down
local menuHold = 0         -- frames left holding it
local menuGap = 0          -- frames left in the forced release after it
local menuLastWrite = nil  -- what we wrote into slot 1 last frame

local active = false       -- session running (from run start until leave)
local engaged = false      -- gate currently engaged (inside a gated screen)
local engagedScreen = nil  -- which screen the current sequence belongs to
local seq = 0              -- level sequence number, increments per engagement
local offset = 0           -- next frame offset to simulate within this level
local coopSlots = {}       -- coopIndex -> network slot
local myCoopIndex = 1
local goneSlots = {}       -- network slot -> true (left mid-run; feed neutral input)
-- Slots whose spelunker WE made invisible/weightless/non-colliding, and HUD rows
-- WE blanked. Both are undo lists: a departure used to be a one-way door, because
-- every hide path bails on `next(goneSlots) == nil`, so the moment a slot stopped
-- being gone nothing ran to put it back. The entity flags outlived the departure
-- and the returning player was invisible, fell through the floor and could not be
-- seen by anyone -- the reported "they get glitched out on rejoin". Only ever
-- clear a flag we set ourselves: another mod (or an item) may legitimately want a
-- player invisible or weightless, and blanket-clearing would fight it.
local hiddenSlots = {}     -- network slot -> true (we applied the hide flags)
local hudBlanked = {}      -- coop index -> true (we blanked this HUD row)
local droppedKit = {}      -- netSlot -> true (their bombs/ropes/powerups already dropped, once)
local inputBuf = {}        -- netSlot -> { [seq] = { [offset] = INPUTS } }
local remoteLastSeq = {}   -- netSlot -> seq carried by their latest input packet
local remoteLastRxMs = {}  -- netSlot -> when that packet arrived (get_ms)
local myRecorded = -1      -- highest offset recorded locally in current seq
local playersSpawned = false
local stallStartMs = nil
local stallReportedMs = nil    -- rate limit for the stall line (see reportStall)
local sendNoticeMs = 0         -- rate limit for the send-while-stalled line
local sendSilentNoticeMs = 0
local STALL_REPORT_MS = 3000
-- a session reset/rebase is always followed by a warp: hold the simulation
-- until that warp's load boundary actually arrives, so the gate can't
-- re-engage on the abandoned screen for a machine-dependent extra sequence
local awaitLoadBoundary = false
-- mod-menu input suppression (e.g. noita-perks' book zeroes buttons_gameplay
-- while open, locally): the late guard folds a mod's changes to OUR slot
-- into the shared stream and reverts its changes to other slots. Injections
-- carry an unused sentinel bit so a mod overwrite is detectable even when it
-- writes the same value the stream already carries (a plain value compare
-- oscillates once the synced stream itself becomes the suppressed value).
-- buttons_gameplay is a 16-bit field (INPUTS uses bits 0-11): the sentinel
-- must be bit 15 — a wider bit gets truncated on write, which made the
-- guard treat every frame as mod-suppressed and froze all input. A runtime
-- self-test verifies the bit survives; if not, the guard degrades to value
-- comparison instead of ever risking that freeze again.
local SENTINEL = 1 << 15
local sentinelSupported = false
local lateGuardRegistered = false
local lastInjected = nil   -- coopIndex -> value written at the last injection
local myModValue = nil     -- mod-modified value of our slot, recorded instead of the device
local checksums = {}       -- "seq:offset" -> { mine = h?, theirs = h? }
local desyncReported = false
-- how many checksum comparisons in a row must disagree before we alarm. A SINGLE
-- transient mismatch is expected and harmless when a player leaves or ends their
-- adventure (their party dies locally for an instant before the departure /
-- run-end resolves) — only a PERSISTENT mismatch means a mod is misbehaving.
local DESYNC_STREAK_ALARM = 3
local desyncStreak = 0
-- Per-FLOOR world verification. The lockstep sim keeps players in sync, but the
-- WORLD is generated locally on every machine from the shared seed — and a content
-- mod that draws a machine-dependent number of PRNG values during generation (or a
-- seed that arrived late on a laggy link) makes a floor generate differently while
-- the players still line up, so the position checksum never notices. Each floor we
-- fingerprint the generated world (the evolved adventure seed + an order-independent
-- hash of the gen-placed floor/enemy/item entities), keyed by the lockstep sequence,
-- and the world host's fingerprint is authoritative: a non-host whose floor differs
-- asks to be resynced onto the host's floor (see EventSync.requestFloorRegen).
local myFloorDigest = nil        -- { seq, seed, ent } for the floor we're on
local hostFloorDigests = {}      -- seq -> { seed, ent } from the world host
local floorMismatchSeq = nil     -- seq we've already logged (once per floor)
local floorDesyncUntil = 0       -- show the small "resyncing world" notice until (get_ms)

-- -------------------------------------------------------------- session

--- Called at run start with the slot->name table from the server.
--- Coop player indices are assigned by ascending network slot on every
--- machine identically: lowest slot is co-op player 1, and so on.
--- @param slots table<string, string>
--- @param delay integer? # server-negotiated input delay (frames); identical on every client
function module.beginSession(slots, delay)
    -- Adopt the run's agreed input delay. Everyone gets the same number from
    -- the server, so this stays deterministic; clamp defends against a junk
    -- value. Redundancy scales with it so lost frames and departed-player
    -- back-fill always stay inside the resend window.
    if type(delay) == "number" and delay >= MIN_INPUT_DELAY then
        INPUT_DELAY = math.min(MAX_INPUT_DELAY, math.floor(delay))
    else
        INPUT_DELAY = DEFAULT_INPUT_DELAY
    end
    REDUNDANCY = INPUT_DELAY * 2 + 4
    coopSlots = {}
    inputBuf = {}
    local netSlots = {}
    for slotStr in pairs(slots) do
        netSlots[#netSlots + 1] = math.floor(tonumber(slotStr) or 0)
    end
    table.sort(netSlots)
    for coopIndex, netSlot in ipairs(netSlots) do
        coopSlots[coopIndex] = netSlot
        if netSlot == Network.slot then
            myCoopIndex = coopIndex
        end
        inputBuf[netSlot] = {}
    end
    goneSlots = {}
    hiddenSlots = {}
    hudBlanked = {}
    droppedKit = {}
    remoteLastSeq = {}
    remoteLastRxMs = {}
    checksums = {}
    desyncReported = false
    desyncStreak = 0
    menuSyncOn = false
    menuSyncAbandoned = false
    menuOffFrames = 0
    menuQueue = {}
    menuPress, menuHold, menuGap = 0, 0, 0
    menuPrevRaw = 0
    menuLastWrite = nil
    lastInjected = nil
    myModValue = nil
    myFloorDigest = nil
    hostFloorDigests = {}
    floorMismatchSeq = nil
    floorDesyncUntil = 0
    engaged = false
    seq = 0
    offset = 0
    myRecorded = -1
    playersSpawned = false
    awaitLoadBoundary = true -- run_start's warp is coming; don't engage before it
    active = true
    -- the engine forces the CAMERA layer to the leader player's layer (that's
    -- co-op player 1 = the host, on every machine!) whenever someone uses a
    -- back-layer door — which is why nobody could travel alone: their own
    -- screen kept showing the host's layer. Take camera-layer control for the
    -- session; cameraTick follows OUR OWN spelunker's layer instead.
    pcall(set_camera_layer_control_enabled, false)
    Network.myCoopIndex = myCoopIndex
    Network.coopSlots = coopSlots
    if DesyncLog ~= nil then
        SafeCall("inputSync:desyncLogInit", DesyncLog.init)
    end
    dbgf("lockstep session: %d players, I am co-op player %d, input delay %d frames",
        #netSlots, myCoopIndex, INPUT_DELAY)
end

function module.endSession()
    if active and DesyncLog ~= nil then
        SafeCall("inputSync:desyncLogClose", DesyncLog.close)
    end
    active = false
    engaged = false
    awaitLoadBoundary = false
    menuSyncOn = false
    menuQueue = {}
    menuPress, menuHold, menuGap = 0, 0, 0
    menuLastWrite = nil
    coopSlots = {}
    inputBuf = {}
    goneSlots = {}
    hiddenSlots = {}
    hudBlanked = {}
    pcall(set_camera_layer_control_enabled, true) -- back to vanilla camera rules
    -- Restore a clean SINGLE-player roster. The run inflates player_count to the
    -- co-op size (see engage); if that leaks past the run, the next character
    -- select still thinks it's a multi-player game and renders a phantom, empty
    -- player preview — the leftover-world "book" on CHOOSE ADVENTURER. run_start
    -- re-applies the real co-op roster via enforceRoster, so this only affects
    -- the solo lobby / menu / character select in between.
    pcall(function()
        local items = get_local_state().items
        items.player_count = 1
        for i = 1, 4 do
            local sel = items.player_select[i]
            if sel ~= nil then
                sel.activated = (i == 1)
            end
        end
    end)
end

--- True once the first level's gate has engaged (the run properly began).
--- @return boolean
function module.hasStarted()
    return active and seq > 0
end

--- A player left mid-run (quit, or timed out after a lag spike — far more
--- likely on a flaky high-ping connection). Making every surviving machine
--- feed the SAME inputs for this slot is the whole game here: UDP loss is
--- independent per client, so at the moment of departure each machine has
--- received a different amount of the leaver's input. If each simply zeroed
--- the frames it happens to be missing, the machines would feed different
--- inputs for the same frames and the worlds would diverge.
---
--- The server relays every input datagram, so its LAST relayed one from the
--- leaver is an upper bound on what any client received. It hands us that tail
--- (`lastInput`) here. We back-fill it — recovering any frames we personally
--- lost — and record a shared cutoff (its final frame). From the gate: every
--- machine now holds identical real inputs for this slot up to the cutoff, and
--- everyone stands the leaver still (neutral) beyond it. Same everywhere.
--- @param netSlot integer
--- @param lastInput { s: integer, f: integer, i: integer[] }? # leaver's last relayed input tail
function module.markGone(netSlot, lastInput)
    local cutoffSeq, cutoffUpto = 0, -1 -- default: nothing agreed (leaver never sent input)
    if type(lastInput) == "table" and type(lastInput.i) == "table" and #lastInput.i > 0 then
        cutoffSeq = math.floor(tonumber(lastInput.s) or 0)
        local base = math.floor(tonumber(lastInput.f) or 0)
        local perSlot = inputBuf[netSlot]
        if perSlot ~= nil then
            perSlot[cutoffSeq] = perSlot[cutoffSeq] or {}
            for k, buttons in ipairs(lastInput.i) do
                local f = base + k - 1
                if perSlot[cutoffSeq][f] == nil then -- fill only the frames we lost
                    perSlot[cutoffSeq][f] = math.floor(tonumber(buttons) or 0)
                end
            end
            cutoffUpto = base + #lastInput.i - 1
        end
    end
    goneSlots[netSlot] = { seq = cutoffSeq, upto = cutoffUpto }
end

--- The lockstep input delay this run negotiated, in 60 Hz sim frames. Recorded in
--- the desync-log header: it is sized once at run start from the room's two worst
--- pings, so a single bad sample is felt by everyone for the whole run, and it
--- appeared in no capture until now.
--- @return integer
function module.inputDelay()
    return INPUT_DELAY
end

function module.playerCount()
    local count = 0
    for _ in pairs(coopSlots) do
        count = count + 1
    end
    return count
end

--- The lowest network slot still IN the run (not departed), or nil if nobody is.
--- The authoritative world host is chosen by this: it is fixed at run start, and
--- when the player holding it leaves it has to move, or every remaining machine
--- keeps pointing at a slot that is no longer playing.
--- @return integer? # lowest surviving slot
function module.lowestActiveSlot()
    local lowest = nil
    for _, netSlot in pairs(coopSlots) do
        if goneSlots[netSlot] == nil and (lowest == nil or netSlot < lowest) then
            lowest = netSlot
        end
    end
    return lowest
end

--- Players still present (not departed) — the denominator for a unanimous
--- restart vote, so a player who has left isn't waited on.
--- @return integer
function module.activePlayers()
    local count = 0
    for _, netSlot in pairs(coopSlots) do
        if goneSlots[netSlot] == nil then
            count = count + 1
        end
    end
    return count
end

--- Current level sequence and frame offset (diagnostics/tests).
--- @return integer, integer
function module.position()
    return seq, offset
end

--- The shared lockstep clock as "seq:offset" — identical on every peer, so it
--- anchors the desync log lines that align two machines' logs.
--- @return string
function module.simClock()
    return string.format("%d:%d", seq, offset)
end

--- The immutable recorded local input for a frame offset (diagnostics/tests).
--- @param frameOffset integer
--- @return integer?
function module.recordedInput(frameOffset)
    local mine = (inputBuf[Network.slot] or {})[seq]
    return mine and mine[frameOffset] or nil
end

--- Hard-realign the lockstep sequence for a floor resync. Machines that have
--- drifted onto different screens (one entered the exit door in ITS world,
--- the other never saw that) hold different sequence numbers and deadlock
--- waiting for each other; the resync warp hands every machine the SAME
--- number (picked above everyone's current one), so the regenerated floor
--- engages as one agreed sequence everywhere. Old input history is dropped —
--- it belongs to abandoned, divergent timelines.
--- @param newSeq integer
function module.rebase(newSeq)
    if not active then
        return
    end
    seq = math.floor(newSeq)
    engaged = false
    awaitLoadBoundary = true -- the resync warp is coming; don't engage before it
    offset = 0
    myRecorded = -1
    stallStartMs = nil
    checksums = {}
    desyncReported = false
    desyncStreak = 0
    lastInjected = nil
    myModValue = nil
    -- the floor we're resyncing away from is abandoned; its digests are stale
    myFloorDigest = nil
    hostFloorDigests = {}
    floorMismatchSeq = nil
    floorDesyncUntil = 0
    for netSlot in pairs(inputBuf) do
        inputBuf[netSlot] = {}
    end
    -- Drop every peer's last-known sequence: it belongs to the abandoned,
    -- divergent timeline we're warping away from. Left stale, stallDesyncRole
    -- would read those old numbers against the fresh rebased seq the instant
    -- the next stall timer trips and fire a SECOND resync on top of this one
    -- (or misclassify ahead/behind), turning one recovery into a warp loop.
    remoteLastSeq = {}
    remoteLastRxMs = {}
    dbgf("lockstep rebased to sequence %d", seq)
end

--- Classify a long stall. nil = ordinary latency. "behind" = a live peer is
--- running on a HIGHER sequence (they advanced through a door we never saw).
--- "ahead" = live peers are stuck below ours (WE advanced; we know where the
--- stuck floor's exit leads). A peer that is merely loading is silent, and a
--- peer on our own sequence is just lag — neither classifies.
--- @return "ahead"|"behind"|nil
function module.stallDesyncRole()
    if stallStartMs == nil or get_ms() - stallStartMs < 4000 then
        return nil
    end
    local anyAhead, anyBehind = false, false
    for _, netSlot in pairs(coopSlots) do
        if netSlot ~= Network.slot and goneSlots[netSlot] == nil then
            local theirSeq = remoteLastSeq[netSlot]
            local lastRx = remoteLastRxMs[netSlot]
            if theirSeq ~= nil and theirSeq ~= seq
                and lastRx ~= nil and get_ms() - lastRx < 2000 then
                if theirSeq > seq then
                    anyBehind = true -- someone is past us
                else
                    anyAhead = true -- someone is stuck below us
                end
            end
        end
    end
    if anyBehind then
        return "behind"
    end
    if anyAhead then
        return "ahead"
    end
    return nil
end

-- -------------------------------------------------------------- input wire

local function sendRecentInputs()
    local mine = (inputBuf[Network.slot] or {})[seq]
    if mine == nil or myRecorded < 0 then
        -- Worth saying while stalled: if we are not sending, the other machine can
        -- never be unblocked, and the two starve each other by construction.
        if stallStartMs ~= nil and DesyncLog ~= nil and DesyncLog.event ~= nil
            and get_ms() >= sendSilentNoticeMs then
            sendSilentNoticeMs = get_ms() + 3000
            DesyncLog.event("SEND SKIPPED while stalled: seq %d has %s buffer, myRecorded %d",
                seq, mine == nil and "no" or "a", myRecorded)
        end
        return
    end
    local base = math.max(0, myRecorded - REDUNDANCY + 1)
    local list = {}
    for f = base, myRecorded do
        list[#list + 1] = mine[f] or 0
    end
    Network.sendState({ s = seq, f = base, i = list })
    -- While stalled, prove we are still putting the frames the peer is waiting on
    -- back on the wire. If this says we resend offsets covering theirs and their rx
    -- counter never moves, the packets are not crossing and it is not lockstep.
    if stallStartMs ~= nil and DesyncLog ~= nil and DesyncLog.event ~= nil
        and get_ms() >= sendNoticeMs then
        sendNoticeMs = get_ms() + 3000
        DesyncLog.event("SEND while stalled: seq %d offsets %d..%d (%d frames)",
            seq, base, myRecorded, #list)
    end
end

--- rx diagnostics, visible from the console (MO_DEBUG etc)
module.rxCount = 0
module.lastRx = ""

--- @param netSlot integer
--- @param data { s: integer, f: integer, i: integer[] }
local function onRemoteInputs(netSlot, data)
    if type(data) ~= "table" or type(data.i) ~= "table" then
        return
    end
    local perSlot = inputBuf[netSlot]
    if perSlot == nil then
        return
    end
    module.rxCount = module.rxCount + 1
    module.lastRx = string.format("slot%s s%s f%s n%d",
        tostring(netSlot), tostring(data.s), tostring(data.f), #data.i)
    local theirSeq = math.floor(tonumber(data.s) or 0)
    -- latest-wins record of which sequence (= which screen) the peer is on,
    -- and that they are alive: the stall-desync detector reads these
    remoteLastSeq[netSlot] = theirSeq
    remoteLastRxMs[netSlot] = get_ms()
    perSlot[theirSeq] = perSlot[theirSeq] or {}
    local base = math.floor(tonumber(data.f) or 0)
    for k, buttons in ipairs(data.i) do
        perSlot[theirSeq][base + k - 1] = math.floor(tonumber(buttons) or 0)
    end
    perSlot[theirSeq - 2] = nil -- levels long past can be dropped
end

-- -------------------------------------------------------------- the gate

--- Runs after every mod's frame callbacks (registered at run time, so it is
--- last in every hook's order). If a mod rewrote the input the simulation is
--- about to consume — mod menus like noita-perks' perk book zero it while
--- open — fold the rewrite of OUR slot into the recorded stream (everyone
--- freezes with us) and undo rewrites of other slots (mods assume
--- single-player and wrongly poke slot 1 on every machine).
local function lateInputGuard()
    if not active or not engaged or not Network.isInRun() or lastInjected == nil then
        return
    end
    -- Walked as a raw chain (state.player_inputs.player_slots) until now. Every
    -- link is engine memory, and a null one there is a native access violation,
    -- which SafeCall's pcall CANNOT catch -- it takes the process down with no Lua
    -- error and no traceback. Cheap to check, and it costs one frame of guarding at
    -- most when it does trip.
    local st = get_local_state()
    local inputs = st ~= nil and st.player_inputs or nil
    local slots = inputs ~= nil and inputs.player_slots or nil
    if slots == nil then
        return
    end
    local mine = nil
    for coopIndex in pairs(coopSlots) do
        local agreed = lastInjected[coopIndex]
        local observed = slots[coopIndex].buttons_gameplay
        if agreed ~= nil then
            local modWrote
            if sentinelSupported then
                modWrote = (observed & SENTINEL) == 0
            else
                modWrote = observed ~= agreed -- degraded mode
            end
            if modWrote and coopIndex == myCoopIndex then
                mine = observed & ~SENTINEL -- a mod overwrote our input: sync its value
            end
            -- strip the sentinel / undo mod writes: the stream is the only
            -- authority over what the simulation consumes
            slots[coopIndex].buttons_gameplay = agreed
        end
    end
    myModValue = mine
end

--- First gated frame of a level: bump the sequence, prefill the input-delay
--- window with neutral input, and make sure the co-op roster is intact.
--- Every machine executes this at the identical simulation state.
local function engage()
    if not lateGuardRegistered then
        -- registered here (run time) so it lands AFTER all mods' load-time
        -- registrations and therefore runs after them on every frame
        lateGuardRegistered = true
        set_callback(function()
            -- Bracketed like every other per-frame callback of ours. It was the ONE
            -- that was not, and because ON.GAMEFRAME runs between our PRE_UPDATE and
            -- POST_UPDATE marks, a crash in here left crash_frame.txt reading
            -- `IN engineUpdate` -- indistinguishable from a crash in the engine or a
            -- content mod. It writes into engine memory every frame, so it is
            -- exactly the callback that most needs to be tellable apart.
            if DesyncLog ~= nil then
                DesyncLog.frameMark("gameframe:lateInputGuard")
            end
            SafeCall("inputSync:lateInputGuard", lateInputGuard)
            if DesyncLog ~= nil then
                DesyncLog.frameDone("gameframe:lateInputGuard")
            end
        end, ON.GAMEFRAME)
        -- verify the sentinel bit survives a real write to the input field
        pcall(function()
            local slot = get_local_state().player_inputs.player_slots[myCoopIndex]
            local original = slot.buttons_gameplay
            slot.buttons_gameplay = SENTINEL
            sentinelSupported = (slot.buttons_gameplay & SENTINEL) ~= 0
            slot.buttons_gameplay = original
        end)
        if not sentinelSupported then
            errorf("input sentinel unsupported on this build; mod-menu sync degraded to value comparison")
        end
    end
    engaged = true
    myModValue = nil -- last screen's mod-menu suppression doesn't carry over
    engagedScreen = get_local_state().screen
    -- Desync is now recovered per floor (the world host reseeds the next level),
    -- so report it per floor too: clear the latch and stale checksums when a new
    -- LEVEL engages. A floor that resynced won't keep re-alarming.
    if engagedScreen == SCREEN.LEVEL then
        desyncReported = false
        desyncStreak = 0
        checksums = {}
    end
    seq = seq + 1
    offset = 0
    myRecorded = INPUT_DELAY - 1
    for _, netSlot in pairs(coopSlots) do
        inputBuf[netSlot][seq] = inputBuf[netSlot][seq] or {}
        for f = 0, INPUT_DELAY - 1 do
            if inputBuf[netSlot][seq][f] == nil then
                inputBuf[netSlot][seq][f] = 0
            end
        end
    end

    -- The engine rebuilds the party from this roster at every level load; keep it
    -- authoritative so nobody's character reverts or disappears. Departed players
    -- are cut from the TAIL of the roster so the engine stops treating them as
    -- party members at all — no re-spawn/ghost next floor, no off-screen cursor,
    -- no transition-screen panel. (The party is contiguous from slot 1, so a
    -- departed player in the MIDDLE of a 3-4 player party can't be cut; it stays
    -- in the roster but is kept hidden.) Deterministic: the gate stalls at a
    -- leaver's cutoff until player_left arrives, so by any later level/transition
    -- every machine shares goneSlots and rebuilds the exact same roster.
    local levelState = get_local_state()
    local count = 0
    for coopIndex = 1, 4 do
        local netSlot = coopSlots[coopIndex]
        if netSlot ~= nil and goneSlots[netSlot] == nil then
            count = coopIndex -- highest still-present co-op slot
        end
    end
    if count == 0 then
        count = module.playerCount() -- safety: never empty the party
    end
    levelState.items.player_count = count
    for coopIndex = 1, 4 do
        local select = levelState.items.player_select[coopIndex]
        if select ~= nil then
            select.activated = coopIndex <= count
        end
    end
    if not playersSpawned then
        playersSpawned = true
        -- FIXED iteration order: spawn order assigns entity uids, and pairs()
        -- order is not guaranteed identical across machines — spawning in a
        -- different order would fork the worlds on the very first frame. Skip
        -- slots past the roster count (a departed trailing player) so our backup
        -- spawn never re-creates one the engine correctly left out.
        for coopIndex = 1, 4 do
            -- NEVER back-spawn a slot that is DEAD in the synced roster: the engine
            -- revives dead players ITSELF at the next AREA boundary (e.g. Dwelling
            -- -> Jungle 2-1). spawn_player on a slot the engine is about to revive
            -- CLONES the player into a second live body (per the API: "if player of
            -- that slot already exist it will spawn clone"). That race is why a live
            -- player sometimes got a duplicate right after the first area — the
            -- backup re-arms on a mid-run JOIN's run_start, whose fold-in floor is
            -- an area boundary, exactly where the engine is reviving the dead. The
            -- engine owns dead-player revival; our backup only fills a genuinely
            -- MISSING *alive* slot (fresh 1-1 co-op players, a fresh joiner).
            -- player_inventory[].health is synced sim state read at engage before
            -- any gameplay tick, so this skip is identical on every machine.
            local inv = get_local_state().items.player_inventory[coopIndex]
            local aliveInRoster = inv == nil or inv.health == nil or inv.health > 0
            if coopSlots[coopIndex] ~= nil and coopIndex <= count
                and aliveInRoster
                and get_player(coopIndex, false) == nil then
                local ok, err = pcall(spawn_player, coopIndex)
                if not ok then
                    errorf("spawn_player(%d) failed: %s", coopIndex, tostring(err))
                end
            end
        end
    end
    -- Fingerprint the generated world every FLOOR (not just the first): the
    -- players staying in sync does not prove the LEVELS did, and per-floor drift
    -- is otherwise invisible. Runs at LEVEL engage, when the freshly generated
    -- world is settled and no gameplay frame has ticked yet, so it reads the same
    -- state on every machine.
    if engagedScreen == SCREEN.LEVEL then
        module.sendWorldDigest()
    end
    -- paint every spelunker with its owner's chosen character skin. The
    -- select-screen roster covers players the engine spawns fresh, but the
    -- live entities themselves need the texture applied (the off-screen
    -- cursor reads the roster; the sprite reads the entity's texture).
    if engagedScreen == SCREEN.LEVEL and EventSync ~= nil and EventSync.characterFor ~= nil then
        for coopIndex = 1, 4 do
            local netSlot = coopSlots[coopIndex]
            local char = netSlot ~= nil and EventSync.characterFor(netSlot) or nil
            local player = char ~= nil and get_player(coopIndex, false) or nil
            if player ~= nil then
                pcall(function()
                    player:set_texture(get_type(char).texture)
                end)
            end
        end
    end
    if EventSync ~= nil and EventSync.onGateEngaged ~= nil then
        SafeCall("inputSync:onGateEngaged", EventSync.onGateEngaged, engagedScreen)
    end
    dbgf("lockstep engaged (level %d)", seq)
end

-- Powerup -> the pickup that grants it, so a departed player's powerups drop for
-- the others to grab. Built defensively via ENT_TYPE[name] so a name missing in
-- some Overlunky build is simply skipped (never a nil-key error at load).
local POWERUP_TO_PICKUP = {}
do
    local map = {
        { "ITEM_POWERUP_CLIMBING_GLOVES", "ITEM_PICKUP_CLIMBINGGLOVES" },
        { "ITEM_POWERUP_SPIKE_SHOES", "ITEM_PICKUP_SPIKESHOES" },
        { "ITEM_POWERUP_SPRING_SHOES", "ITEM_PICKUP_SPRINGSHOES" },
        { "ITEM_POWERUP_SPECTACLES", "ITEM_PICKUP_SPECTACLES" },
        { "ITEM_POWERUP_PITCHERSMITT", "ITEM_PICKUP_PITCHERSMITT" },
        { "ITEM_POWERUP_PASTE", "ITEM_PICKUP_PASTE" },
        { "ITEM_POWERUP_COMPASS", "ITEM_PICKUP_COMPASS" },
        { "ITEM_POWERUP_SPECIALCOMPASS", "ITEM_PICKUP_SPECIALCOMPASS" },
        { "ITEM_POWERUP_PARACHUTE", "ITEM_PICKUP_PARACHUTE" },
        { "ITEM_POWERUP_SKELETON_KEY", "ITEM_PICKUP_SKELETON_KEY" },
        { "ITEM_POWERUP_KAPALA", "ITEM_PICKUP_KAPALA" },
        { "ITEM_POWERUP_HEDJET", "ITEM_PICKUP_HEDJET" },
        { "ITEM_POWERUP_CROWN", "ITEM_PICKUP_CROWN" },
        { "ITEM_POWERUP_TRUECROWN", "ITEM_PICKUP_TRUECROWN" },
        { "ITEM_POWERUP_EGGPLANTCROWN", "ITEM_PICKUP_EGGPLANTCROWN" },
        { "ITEM_POWERUP_UDJATEYE", "ITEM_PICKUP_UDJATEYE" },
        { "ITEM_POWERUP_ANKH", "ITEM_PICKUP_ANKH" },
        { "ITEM_POWERUP_TABLETOFDESTINY", "ITEM_PICKUP_TABLETOFDESTINY" },
    }
    for _, pair in ipairs(map) do
        local powerup = ENT_TYPE[pair[1]]
        local pickup = ENT_TYPE[pair[2]]
        if powerup ~= nil and pickup ~= nil then
            POWERUP_TO_PICKUP[powerup] = pickup
        end
    end
end

--- Drop a departed player's carried resources ONCE, so the others can grab them:
--- a player bag holding their exact bombs + ropes (the game's own co-op death
--- drop), and a pickup for each powerup they had (climbing gloves, spike shoes,
--- spectacles, …). Called only at the shared markGone cutoff frame (see the hide
--- pass), spawning in a fixed, sorted order at deterministic positions — so every
--- machine spawns the same entities with the same uids and it can't desync.
--- @param coopIndex integer
--- @param player Player
local function dropGoneKit(coopIndex, player)
    local state = get_local_state()
    local x, y, layer = player.x, player.y, player.layer
    -- bombs + ropes: a PLAYERBAG carries exactly those counts to whoever grabs it
    local inv = state.items.player_inventory[coopIndex]
    local bombs = inv ~= nil and math.floor(tonumber(inv.bombs) or 0) or 0
    local ropes = inv ~= nil and math.floor(tonumber(inv.ropes) or 0) or 0
    if bombs > 0 or ropes > 0 then
        local uid = spawn_entity(ENT_TYPE.ITEM_PICKUP_PLAYERBAG, x, y, layer, 0, 0)
        local bag = uid ~= nil and get_entity(uid) or nil
        if bag ~= nil then
            pcall(function()
                bag.bombs = bombs
                bag.ropes = ropes
            end)
        end
    end
    -- powerups: one matching pickup each, sorted for a deterministic spawn order
    -- (identical uids everywhere) and spread out so they don't stack on one spot
    local powerups = nil
    pcall(function() powerups = player:get_powerups() end)
    if type(powerups) == "table" and #powerups > 0 then
        table.sort(powerups)
        local n = #powerups
        for i = 1, n do
            local pickup = POWERUP_TO_PICKUP[powerups[i]]
            if pickup ~= nil then
                local ox = x + (i - (n + 1) / 2) * 0.3
                spawn_entity(pickup, ox, y, layer, 0, 0)
            end
        end
    end
end

--- Make a departed player's spelunker invisible, weightless and non-colliding.
--- INVISIBLE is cosmetic; the collision/gravity flags affect physics but are
--- applied on the shared cutoff frame (and before the first tick of a new level,
--- from POST_LEVEL_GENERATION), so every machine matches. Safe to re-run.
--- @param player Player
--- @param netSlot integer? # recorded so the hide can be undone if they return
local function hidePlayerEntity(player, netSlot)
    pcall(function()
        player.flags = set_flag(player.flags, ENT_FLAG.INVISIBLE)
        player.flags = set_flag(player.flags, ENT_FLAG.PASSES_THROUGH_EVERYTHING)
        player.flags = set_flag(player.flags, ENT_FLAG.NO_GRAVITY)
        player.velocityx = 0
        player.velocityy = 0
    end)
    if netSlot ~= nil then
        hiddenSlots[netSlot] = true
    end
end

--- Undo hidePlayerEntity. Clears ONLY the three flags we set, so a player made
--- invisible or weightless by anything else is left alone.
--- @param player Player
local function showPlayerEntity(player)
    pcall(function()
        player.flags = clr_flag(player.flags, ENT_FLAG.INVISIBLE)
        player.flags = clr_flag(player.flags, ENT_FLAG.PASSES_THROUGH_EVERYTHING)
        player.flags = clr_flag(player.flags, ENT_FLAG.NO_GRAVITY)
    end)
end

--- A slot we hid is no longer gone: give the spelunker its body back. Runs every
--- frame and, unlike every other hide path, is NOT gated on `goneSlots` being
--- non-empty -- the whole point is to run once it has been emptied (beginSession
--- clears it wholesale on the run_start that carries a rejoin). Driven purely by
--- the synced roster, so every machine restores on the same frame.
local function restoreReturnedPlayers()
    if not active or next(hiddenSlots) == nil then
        return
    end
    for coopIndex = 1, 4 do
        local netSlot = coopSlots[coopIndex]
        if netSlot ~= nil and hiddenSlots[netSlot] ~= nil and goneSlots[netSlot] == nil then
            local player = get_player(coopIndex, false)
            if player ~= nil then
                showPlayerEntity(player)
            end
            -- forget it either way: if the entity is gone the flags went with it
            hiddenSlots[netSlot] = nil
        end
    end
    -- a slot that left the roster entirely can never be restored through it
    for netSlot in pairs(hiddenSlots) do
        local stillRostered = false
        for coopIndex = 1, 4 do
            if coopSlots[coopIndex] == netSlot then
                stillRostered = true
            end
        end
        if not stillRostered and goneSlots[netSlot] == nil then
            hiddenSlots[netSlot] = nil
        end
    end
end

--- Every player STILL in the party (not departed) is dead. The gate keeps a
--- departed player's spelunker alive-but-hidden so the departure can't desync;
--- the side effect is the engine counts it as a living player and never fires its
--- own party wipe (ON.DEATH) when the LAST remaining player dies — so the run
--- hangs on the level forever ("everyone dies but nothing ever resets"). Detect
--- the true wipe so the gate can finish it off. Reads only synced player health,
--- so on a given tick it returns the same answer on every machine.
--- @return boolean
local function allRealPlayersDead()
    if next(goneSlots) == nil then
        return false -- nobody left: the engine handles wipes on its own
    end
    local anyReal = false
    for coopIndex = 1, 4 do
        local netSlot = coopSlots[coopIndex]
        if netSlot ~= nil and goneSlots[netSlot] == nil then
            anyReal = true
            local p = get_player(coopIndex, false)
            if p ~= nil and (p.health == nil or p.health > 0) then
                return false -- someone still in the party is alive
            end
        end
    end
    return anyReal
end

--- Stop driving a mod's menu and give the local pad straight back. We do not
--- write the slot here: the engine refills `buttons` from the device every
--- frame, so simply not writing it IS the handover.
local function menuSyncStop()
    if menuSyncOn and DesyncLog ~= nil then
        -- Every machine replays the SAME edges, so `applied` matching across a
        -- pair of logs is the proof the cursors agreed. The rest is there to
        -- name the broken stage if they ever do not: `sent` 0 with `padmoves` 0
        -- means we could not read the pad, `sent` 0 with `padmoves` high means
        -- nobody pressed anything, and `applied` far below the two machines'
        -- combined `sent` means edges are not coming back off the channel.
        DesyncLog.event("mod UI menu sync ended: applied=%d sent=%d padmoves=%d render frames=%d",
            menuEdgesApplied, menuEdgesSent, menuPadChanges, menuFrames)
    end
    menuSyncOn = false
    menuOffFrames = 0
    menuQueue = {}
    menuPress, menuHold, menuGap = 0, 0, 0
    menuLastWrite = nil
end

--- Give up on the shared cursor for the rest of the session. Only reached when
--- continuing to drive the menu could hang it, which is strictly worse than the
--- divergence the shared cursor prevents: a stuck menu is unrecoverable, a
--- divergent upgrade is at least playable and shows up in the log.
--- @param why string
local function menuAbandon(why)
    menuSyncAbandoned = true
    menuSyncStop()
    dbgf("mod menu sync disabled (%s) - upgrades may now differ between players", why)
    if DesyncLog ~= nil then
        DesyncLog.event("mod UI menu sync ABANDONED: %s", why)
    end
end

--- Drive a content mod's own menu from ONE globally ordered stream of button
--- edges, so every machine's cursor lands on the same item and confirms the
--- same thing. Runs in place of the lockstep gate, which cannot run while the
--- menu is up: the simulation is frozen, so there are no frames to be in step
--- about. See MENU_EDGE_MASK above for why this is necessary at all.
--- @param levelState StateMemory
local function menuSyncTick(levelState)
    if menuSyncAbandoned or module.activePlayers() <= 1 then
        return -- solo: the pad can drive the menu directly, nothing to agree on
    end
    if not menuSyncOn then
        menuSyncOn = true
        menuOpenedMs = get_ms()
        menuFrames = 0
        menuEdgesApplied = 0
        menuEdgesSent = 0
        menuFirstSentMs = 0
        menuPadChanges = 0
        menuPrevRaw = 0
        menuQueue = {}
        menuPress, menuHold, menuGap = 0, 0, 0
        menuLastWrite = nil
    end
    menuOffFrames = 0
    local menuOpenMs = get_ms() - menuOpenedMs
    if menuOpenMs > MENU_STUCK_MS then
        menuAbandon("menu open too long")
        return
    end
    if menuEdgesSent > 0 and menuEdgesApplied == 0
        and get_ms() - menuFirstSentMs > MENU_DEAD_MS then
        menuAbandon("presses published but none came back")
        return
    end
    local slot1 = levelState.player_inputs.player_slots[1]
    local observed = math.floor(tonumber(slot1.buttons) or 0)
    -- The field should be a fresh device read here (the engine refills it just
    -- before this callback), but tag every injection with the unused sentinel
    -- bit anyway — no device can set it, so if our own write ever comes back we
    -- know the frame carries no new information about the pad and skip edge
    -- detection rather than mistake the echo for a press. Without the sentinel,
    -- fall back to comparing against our last NON-ZERO write: ambiguous only
    -- when the player happens to hold exactly what we injected, which can miss
    -- an edge but never invent one. Our zero writes are never treated as an
    -- echo, so a release is always seen and the same button can be pressed
    -- twice in a row.
    local tag = sentinelSupported and SENTINEL or 0
    local echo = false
    if menuLastWrite ~= nil then
        if tag ~= 0 then
            echo = (observed & tag) ~= 0
        else
            echo = menuLastWrite ~= 0 and observed == menuLastWrite
        end
    end
    local raw = echo and menuPrevRaw or (observed & MENU_EDGE_MASK)
    if raw ~= menuPrevRaw then
        menuPadChanges = menuPadChanges + 1
    end
    -- Publish every edge immediately; the arming gate below decides when each
    -- machine starts APPLYING them, so nothing has to be held back here.
    local pressed = raw & ~menuPrevRaw
    if pressed ~= 0 then
        if menuEdgesSent == 0 then
            menuFirstSentMs = get_ms()
        end
        menuEdgesSent = menuEdgesSent + 1
        Network.sendEvent("menu", { b = pressed })
    end
    menuPrevRaw = raw
    -- Replay the agreed edges one at a time as a clean press-then-release pulse.
    -- The mod latches on the transition, so it needs to see at least one
    -- rendered frame of each half; the pulse is measured in update frames and is
    -- wide enough to survive any playable render rate.
    local armed = menuFrames >= MENU_ARM_FRAMES or menuOpenMs >= MENU_ARM_MS
    local write = 0
    if menuHold > 0 then
        menuHold = menuHold - 1
        write = menuPress
        if menuHold == 0 then
            menuGap = MENU_GAP_FRAMES
        end
    elseif menuGap > 0 then
        menuGap = menuGap - 1
    elseif armed and menuQueue[1] ~= nil then
        menuPress = table.remove(menuQueue, 1)
        menuEdgesApplied = menuEdgesApplied + 1
        menuHold = MENU_PRESS_FRAMES - 1
        write = menuPress
        if menuHold == 0 then
            menuGap = MENU_GAP_FRAMES
        end
    end
    menuLastWrite = write | tag
    pcall(function() slot1.buttons = menuLastWrite end)
end

--- One button edge to replay, delivered in the server's order on every machine.
--- @param payload { b: integer? }?
--- @param originSlot integer
local function onMenuEvent(payload, originSlot)
    if type(payload) ~= "table" then
        return
    end
    local pressed = math.floor(tonumber(payload.b) or 0) & MENU_EDGE_MASK
    if pressed ~= 0 and menuSyncOn and not menuSyncAbandoned then
        menuQueue[#menuQueue + 1] = pressed
    end
end
--- Say WHO the world is waiting on, and for which frame.
---
--- A stall used to be entirely silent: stallStartMs was set, the sim was held, and
--- nothing reached the log. Two machines froze on 1-4 with "waiting for other
--- players" and both logs simply STOPPED at the last floor digest — no way to tell
--- which slot was missing, on which sequence, or whether each was waiting on the
--- other. Rate-limited, since this is reached on every frame of a stall.
--- @param netSlot integer # the slot whose input has not arrived
--- @param seq integer
--- @param offset integer
local function reportStall(netSlot, seq, offset)
    if DesyncLog == nil or DesyncLog.event == nil then
        return
    end
    local now = get_ms()
    if stallReportedMs ~= nil and now - stallReportedMs < STALL_REPORT_MS then
        return
    end
    stallReportedMs = now
    local held = stallStartMs ~= nil and (now - stallStartMs) or 0

    -- What we actually have from that slot for this floor. A stall names one
    -- missing frame; this says whether the frames AROUND it arrived, which is the
    -- difference between "their packets stopped" and "their packets arrive and we
    -- reject this one". The captures so far show inputs present up to exactly the
    -- input delay and nothing past it -- the transition's neutral hold -- so no real
    -- input for the floor ever crossed. That distinction is the whole question.
    local have, lowest, highest = 0, nil, nil
    local perSeq = inputBuf[netSlot] ~= nil and inputBuf[netSlot][seq] or nil
    if perSeq ~= nil then
        for off in pairs(perSeq) do
            have = have + 1
            if lowest == nil or off < lowest then lowest = off end
            if highest == nil or off > highest then highest = off end
        end
    end

    -- and whether anything at all is still arriving from the wire
    local rx = "?"
    pcall(function()
        local counts = Network.rxCounts()
        local parts = {}
        for kind, count in pairs(counts) do
            parts[#parts + 1] = string.format("%s=%d", kind, count)
        end
        table.sort(parts)
        rx = #parts > 0 and table.concat(parts, " ") or "NOTHING"
    end)

    DesyncLog.event(
        "STALL: waiting on slot %d for seq %d offset %d (%d ms; mine recorded to %d)"
        .. " | theirs for this seq: %d frames, offsets %s..%s | rx %s",
        netSlot, seq, offset, math.floor(held), myRecorded,
        have, tostring(lowest), tostring(highest), rx)
end



--- Runs before every simulation tick. Returning true SKIPS the tick — that
--- is the lockstep gate: the world only advances when every player's input
--- for this frame is known, so all machines simulate identical histories.
--- @return boolean? # true to hold the simulation this render frame
local function preUpdate()
    if not active or not Network.isInRun() then
        return
    end
    local levelState = get_local_state()
    -- Kill a player-triggered instant restart BEFORE the fade check below can
    -- disengage the gate. This runs in PRE_UPDATE, which fires every frame
    -- DURING the restart's fade (GAMEFRAME does not), so the fade is cancelled
    -- on its first frame — the gate never drops, we keep feeding inputs, and a
    -- lone restart can no longer freeze the party or drag everyone to 1-1. Our
    -- own synchronized warps (run_start / resync) are exempt and proceed.
    if EventSync ~= nil and EventSync.suppressRestartFade ~= nil then
        SafeCall("inputSync:suppressRestartFade", EventSync.suppressRestartFade)
    end
    -- Same trick for a local-only MENU screen (pause -> OPTIONS): refuse the
    -- screen change before the fade check below can disengage the gate, so one
    -- player opening settings can't freeze the party (and can't trip the stall
    -- recovery's floor warp). PRE_UPDATE for the same reason as above: it is the
    -- only callback that fires during the fade.
    if EventSync ~= nil and EventSync.suppressMenuScreens ~= nil then
        SafeCall("inputSync:suppressMenuScreens", EventSync.suppressMenuScreens)
    end
    -- ...and hold this machine on a TRANSITION until every player is finished
    -- with it. Same callback for the same reason: PRE_UPDATE is the only one
    -- that fires during the fade, which is when the engine commits to leaving.
    -- Entering a transition is lockstepped; LEAVING one was not, and a peer that
    -- walked out while the host was still reading Mama Tunnel's dialogue
    -- generated the next floor alone -- then generated it a second time when the
    -- resync warp arrived, which is what made the two worlds differ.
    if EventSync ~= nil and EventSync.holdTransitionExit ~= nil then
        SafeCall("inputSync:holdTransitionExit", EventSync.holdTransitionExit)
    end
    -- transitions are part of the shared simulation (players walk, carry
    -- items, press to continue) and MUST be gated too: un-gated, the local
    -- device would drive player 1 on every machine, silently diverging the
    -- worlds. Each screen gets its own sequence, so the numbering re-bases
    -- at every level/transition boundary.
    if (levelState.screen ~= SCREEN.LEVEL and levelState.screen ~= SCREEN.TRANSITION)
        or levelState.loading ~= FADE.NONE then
        -- while fading/loading between screens the gate is disengaged and the
        -- local device would otherwise write freely into the input slots. The
        -- engine buffers presses made here into the next screen's first
        -- frames — that is exactly how a buffered jump skipped the level
        -- cutscene on one machine only (a guaranteed desync). Hold every
        -- input slot neutral until the gate re-engages and owns the inputs.
        if levelState.loading ~= FADE.NONE then
            local fadeSlots = levelState.player_inputs.player_slots
            for coopIndex = 1, 4 do
                fadeSlots[coopIndex].buttons = 0
                fadeSlots[coopIndex].buttons_gameplay = 0
            end
        end
        awaitLoadBoundary = false -- the awaited boundary is here
        engaged = false -- re-engage with a fresh sequence on the next screen
        return
    end
    -- The menu pause (flag 1) fires when a player opens the pause menu OR the
    -- window loses focus (alt-tab). In lockstep that used to freeze EVERYONE:
    -- the paused player stopped feeding inputs, so every other machine stalled
    -- waiting for them. Clear it so the shared world keeps running — a paused or
    -- tabbed-out player just stops driving their spelunker (it stands still on
    -- neutral input) until they come back. Real engine pauses below (loading,
    -- ankh revive, etc.) are genuine engine states and still gate the sim.
    if (levelState.pause & 1) ~= 0 then
        pcall(function() levelState.pause = levelState.pause & ~1 end)
    end
    -- A content mod freezing the game for its OWN UI raises the loading pause (2)
    -- while NO load is in flight — the Darkside / Pit of 100 Trials level-up screen
    -- does exactly this. LET THAT PAUSE STAND. Because the simulation stops:
    --   * the menu opens on every machine (the mod raises it from synced state),
    --   * pressing a button drives the MENU and cannot move anyone's spelunker,
    --   * whoever chooses first resumes, stops receiving the other's inputs and
    --     simply waits on the normal lockstep stall ("WAITING FOR PLAYERS") until
    --     they close their menu too.
    -- The one thing we must NOT do is blank the input slots: the menu reads
    -- player_slots[].buttons directly, and zeroing them left it unable to register
    -- a press — the menu never closed and re-raised the pause every frame, a hard
    -- freeze. Instead menuSyncTick owns slot 1 for the duration and feeds the menu
    -- ONE agreed stream of button edges, so two machines cannot resolve the same
    -- menu differently (see MENU_EDGE_MASK).
    local modUiPause = (levelState.pause & 2) ~= 0 and levelState.loading == FADE.NONE
    if modUiPause ~= modUiPauseWas then
        modUiPauseWas = modUiPause
        if DesyncLog ~= nil then
            DesyncLog.event("mod UI pause %s", modUiPause and "OPENED" or "CLOSED")
        end
    end
    if modUiPause then
        SafeCall("inputSync:menuSyncTick", menuSyncTick, levelState)
    elseif menuSyncOn then
        -- not on the first clear frame: see MENU_OFF_FRAMES
        menuOffFrames = menuOffFrames + 1
        if menuOffFrames >= MENU_OFF_FRAMES then
            menuSyncStop()
        end
    end
    if (levelState.pause & ENGINE_PAUSE_MASK) ~= 0 then
        -- Hold inputs neutral for the engine's REAL loading pause only: that is the
        -- buffering window where a press would leak into the next screen. A mod's
        -- own UI pause keeps its inputs (see above).
        if (levelState.pause & 2) ~= 0 and not modUiPause then
            local pauseSlots = levelState.player_inputs.player_slots
            for coopIndex = 1, 4 do
                pauseSlots[coopIndex].buttons = 0
                pauseSlots[coopIndex].buttons_gameplay = 0
            end
        end
        return -- a real engine pause: the sim won't tick, don't advance anything
    end
    if awaitLoadBoundary then
        return true -- a reset/rebase warp is in flight: hold until it loads
    end
    if engaged and levelState.screen ~= engagedScreen then
        engaged = false -- level <-> transition boundary: fresh sequence
    end
    if not engaged then
        engage()
    end

    -- record the local device's input (the hardware always writes into
    -- slot 1) for INPUT_DELAY frames in the future. Record-once: a frame's
    -- input is IMMUTABLE after first write — while the gate stalls we must
    -- never overwrite a value that may already have been sent, or the two
    -- machines would simulate the same frame with different inputs (desync).
    -- When a mod-menu is suppressing our input (late guard), record the
    -- mod's value instead of the device so the suppression syncs to everyone
    local slots = levelState.player_inputs.player_slots
    local raw = myModValue or slots[1].buttons_gameplay or 0
    -- typing in chat: record neutral so our keystrokes drive the chat box, not
    -- the spelunker. Applied to the synced stream, so every machine sees us idle.
    if Chat ~= nil and Chat.isTyping ~= nil and Chat.isTyping() then
        raw = 0
    end
    local target = offset + INPUT_DELAY
    -- our own slot must be in this run's roster to record into. If it isn't
    -- (a botched / mismatched join — e.g. two game instances on ONE PC sharing a
    -- listen port so the server's pushes cross over and scramble slots), don't
    -- crash-spam here: hold the sim and let the session recover or the player
    -- back out. engage() only sets up inputBuf[slot][seq] for roster slots.
    local myBuf = inputBuf[Network.slot]
    if myBuf == nil then
        stallStartMs = stallStartMs or get_ms()
        return true
    end
    myBuf[seq] = myBuf[seq] or {}
    if myBuf[seq][target] == nil then
        myBuf[seq][target] = raw
    end
    if target > myRecorded then
        myRecorded = target
        sendRecentInputs()
    end

    -- everyone's input for THIS frame must be present, or the world waits
    for _, netSlot in pairs(coopSlots) do
        local perSeq = inputBuf[netSlot][seq]
        if perSeq == nil or perSeq[offset] == nil then
            local gone = goneSlots[netSlot]
            -- A departed player stands still only PAST the shared cutoff the
            -- server pinned down (a later level, or a frame beyond their last
            -- relayed input). Up to the cutoff we still require their real
            -- inputs — markGone back-filled them, so they're present on every
            -- machine, keeping the substitution identical everywhere.
            if gone ~= nil and (seq ~= gone.seq or offset > gone.upto) then
                inputBuf[netSlot][seq] = perSeq or {}
                inputBuf[netSlot][seq][offset] = 0
            else
                stallStartMs = stallStartMs or get_ms()
                reportStall(netSlot, seq, offset)
                return true
            end
        end
    end
    stallReportedMs = nil -- recovered; the next stall reports immediately
    stallStartMs = nil

    -- feed the agreed inputs into the co-op player slots. During the first
    -- second of a transition everyone's input is held neutral — applied to
    -- the agreed values identically on every machine, so it cannot desync.
    -- Transition-continue and cutscene-skip prompts read the raw input path
    -- (buttons), not buttons_gameplay — on those screens/frames BOTH fields
    -- are driven with the agreed values, otherwise a buffered or fast press
    -- acts locally on one machine only and forks the simulations. Levels
    -- leave the raw path alone so local menus (journal) keep working.
    local inTransition = engagedScreen == SCREEN.TRANSITION
    local inCutscene = (levelState.pause & PAUSE_CUTSCENE) ~= 0
    local hold = inTransition and offset < TRANSITION_HOLD
    lastInjected = {}
    local tag = sentinelSupported and SENTINEL or 0
    -- FIXED coopIndex order (1..4), never pairs(coopSlots): pairs() order is not
    -- guaranteed identical across machines, and filterGameplayInput carries
    -- per-player state (door-hold edges, layer-travel bookings) — the same reason
    -- sendChecksum abandoned pairs(). Injecting in a machine-dependent order is a
    -- latent divergence source, so we make it deterministic.
    for coopIndex = 1, 4 do
        local netSlot = coopSlots[coopIndex]
        if netSlot ~= nil then
            local value = hold and 0 or inputBuf[netSlot][seq][offset]
            -- deterministic input filter (e.g. layer-door presses become custom
            -- teleports): a pure function of the synced stream and synced world,
            -- so it transforms the input identically on every machine
            if EventSync ~= nil and EventSync.filterGameplayInput ~= nil then
                value = EventSync.filterGameplayInput(coopIndex, value)
            end
            -- sentinel-tagged: the late guard strips it before the sim consumes
            slots[coopIndex].buttons_gameplay = value | tag
            lastInjected[coopIndex] = value
            if inTransition or inCutscene then
                slots[coopIndex].buttons = value
            end
        end
    end

    -- Take a departed player's spelunker out of the world on every remaining
    -- machine, so the others aren't left with an idle body. We must NOT destroy
    -- the entity: the engine keeps hard references to co-op players (the player
    -- array, HUD, camera), so freeing one out from under it is a native access
    -- violation — a hard crash that pcall can't catch. Instead we neutralise it:
    -- drop whatever it was carrying (the others can grab it), then make it
    -- invisible, weightless and non-colliding so it can't be seen, block anyone,
    -- or fall to its death. This fires only once the shared cutoff has passed
    -- (the SAME deterministic condition the neutral-input substitution above
    -- uses), so collision is switched off on the same simulated frame on every
    -- machine and the rest of the party's physics stays identical; the checksum
    -- already drops this slot past the cutoff, so it can't desync. Re-applied
    -- every frame because the engine rebuilds the party (and its flags) at each
    -- level load.
    -- When everyone still in the party is dead but a departed player's spelunker
    -- is being held alive-and-hidden, the engine never registers the wipe and the
    -- run hangs on this level forever. Finish the wipe ourselves: kill the frozen
    -- departed spelunker(s) so the engine sees a full party wipe and runs its
    -- normal game-over -> back-to-lobby flow (via our ON.DEATH handler). Only on a
    -- LEVEL (a party can't die mid-transition) and only inside this gated tick, so
    -- setting health lands on the same simulated frame on every machine.
    local finishWipe = levelState.screen == SCREEN.LEVEL and allRealPlayersDead()
    for coopIndex = 1, 4 do
        local netSlot = coopSlots[coopIndex]
        local gone = netSlot ~= nil and goneSlots[netSlot] or nil
        if gone ~= nil and (seq ~= gone.seq or offset > gone.upto) then
            local player = get_player(coopIndex, false)
            if player ~= nil then
                if finishWipe then
                    -- Complete the party wipe so the engine registers all players
                    -- dead and shows its game-over/death screen (which is what our
                    -- ON.DEATH handler needs to fire). Setting health alone is not
                    -- enough: the engine's "all players dead or missing" check
                    -- wants the entity in the DEAD STATE, so we kill() it. kill()
                    -- runs the normal death — NOT destroy(), which access-violates
                    -- on co-op players — and destroy_corpse=false so we never try
                    -- to free the player entity itself.
                    pcall(function() player.health = 0 end)
                    pcall(function() player:kill(false, nil) end)
                end
                -- One-time: drop their bombs, ropes and powerups (climbing gloves,
                -- spike shoes, …) for the others to grab. Fires exactly once, on
                -- the shared cutoff frame — the gate stalls here until player_left
                -- sets goneSlots, so every machine's FIRST past-cutoff frame is
                -- the same (seq, offset), giving identical, deterministic spawns.
                if not droppedKit[netSlot] then
                    droppedKit[netSlot] = true
                    pcall(dropGoneKit, coopIndex, player)
                end
                -- Drop everything they were carrying so the others can grab it.
                -- Unequip the worn backpack (jetpack/cape/…) first — unequipping
                -- can briefly turn it into the held item, which the held-drop
                -- then puts on the floor. Both self-limit: once detached there is
                -- nothing left, so re-running every frame is a no-op. Separate
                -- pcalls so an unsupported backitem call can't block the held
                -- drop. Detaching existing entities assigns no new uids, and it
                -- happens on the shared cutoff frame, so it stays deterministic.
                pcall(function()
                    if player:worn_backitem() >= 0 then
                        player:unequip_backitem()
                    end
                end)
                pcall(function()
                    if player.holding_uid ~= nil and player.holding_uid >= 0 then
                        player:drop()
                    end
                end)
                hidePlayerEntity(player, netSlot)
            end
        end
    end

    -- occasionally cross-check that the simulations agree
    if offset > 0 and offset % CHECK_EVERY == 0 then
        module.sendChecksum()
    end

    -- prune history we can never need again
    for _, netSlot in pairs(coopSlots) do
        local perSeq = inputBuf[netSlot][seq]
        if perSeq ~= nil then
            perSeq[offset - REDUNDANCY * 2] = nil
        end
    end
    offset = offset + 1
end

-- -------------------------------------------------------------- world check

-- MOUNT and PLAYER are included deliberately: without them a divergent MOUNT (they
-- are re-created every floor from the synced inventory) or a DUPLICATED player
-- entity (a coffin clone) was completely invisible to the digest, so "byte-identical
-- entity lists" did not actually rule either out. Both are settled and identical at
-- LEVEL engage on machines that are in sync, and the digest is detection-only, so
-- the worst case for a false hit is one extra log line.
local WORLD_HASH_MASKS = MASK.FLOOR | MASK.ACTIVEFLOOR | MASK.MONSTER | MASK.ITEM
    | MASK.MOUNT | MASK.PLAYER

--- Fingerprint the current floor: the evolved adventure seed (catches a seed that
--- failed to apply — a totally different world) plus an order-INDEPENDENT summed
--- hash of every gen-placed floor/enemy/item entity's type and grid position
--- (catches "same layout, entities/traps slightly off"). Summing makes it immune
--- to entity iteration order, which is not guaranteed identical across machines.
--- @return integer, integer # seedHash, entHash
local function computeFloorDigest()
    local seedHash = 0
    pcall(function()
        local a, b = get_adventure_seed(false)
        seedHash = ((math.floor(a) & 0x7FFFFFFF) * 31 + (math.floor(b) & 0x7FFFFFFF)) % 2147483647
    end)
    local entHash = 0
    -- The per-type tally comes out of THIS sweep. The floor log used to run a
    -- second full sweep of its own (same masks) purely to count and list entities;
    -- counting here costs one increment per entity and lets that one go.
    local counts = {}
    pcall(function()
        for _, uid in ipairs(get_entities_by(0, WORLD_HASH_MASKS, LAYER.BOTH)) do
            local e = get_entity(uid)
            if e ~= nil then
                local id = math.floor(e.type.id)
                local h = (id * 2654435761
                    + (math.floor(e.x * 10) & 0xFFFF) * 40503
                    + (math.floor(e.y * 10) & 0xFFFF) * 92821) % 2147483647
                entHash = (entHash + h) % 2147483647
                counts[id] = (counts[id] or 0) + 1
            end
        end
    end)
    return seedHash, entHash, counts
end

--- Non-host only: compare our floor `s` against the world host's authoritative
--- fingerprint. DETECTION ONLY — it surfaces a divergence (a brief top-right
--- notice + a log line) but does NOT auto-warp. Auto-warping every floor
--- double-generated the level (advancing run progress, e.g. wiping shopkeeper
--- aggro) and, when the underlying cause was a content mod's own non-determinism
--- (which a game-state resync can't heal — see the mod-lua run-state note), it
--- churned pointlessly. Genuine gameplay desyncs (players stuck / diverged
--- positions) are still recovered by the position-checksum stall resync, which
--- advances FORWARD rather than regenerating in place.
--- @param s integer
function module.checkFloorDigest(s)
    if Network.isWorldHost() then
        return -- our own world is the reference; nothing to check against
    end
    local mine, host = myFloorDigest, hostFloorDigests[s]
    if mine == nil or mine.seq ~= s or host == nil then
        return -- need both fingerprints for the same floor
    end
    -- Compare ONLY the entity fingerprint. The seed fingerprint (the evolved
    -- adventure seed's second value) drifts BENIGNLY: the world host advances it
    -- one extra time at the first level transition, after which every machine
    -- stays in lockstep. The logs prove the entities are byte-identical while
    -- that value differs, so it does NOT feed level generation — comparing it
    -- raised a false "FLOOR DESYNC" (and the top-right notice) on every single
    -- floor for non-hosts. A differing ENTITY fingerprint is the only real
    -- world divergence, so that alone is what we surface now (detection only).
    if mine.ent == host.ent then
        return
    end
    if floorMismatchSeq ~= s then
        floorMismatchSeq = s
        errorf("FLOOR DESYNC seq %d: entities DIFFER (seed %s)", s,
            mine.seed ~= host.seed and "differ" or "ok")
        if DesyncLog ~= nil then
            DesyncLog.floorMismatch(s, mine, host)
        end
    end
end

--- Broadcast our fingerprint for the floor that just engaged and check it against
--- the host's (if already received). Every machine sends; only non-hosts check.
function module.sendWorldDigest()
    if not active or not Network.isInRun() then
        return
    end
    -- bracketed: computeFloorDigest and the dump below sweep EVERY entity in the
    -- level through get_entity, which is where a stale uid would crash natively
    if DesyncLog ~= nil then
        DesyncLog.enter("floorDigest+dump")
    end
    local seedHash, entHash, counts = computeFloorDigest()
    myFloorDigest = { seq = seq, seed = seedHash, ent = entHash }
    Network.sendEvent("worldchk", { s = seq, sd = seedHash, e = entHash })
    if DesyncLog ~= nil then
        DesyncLog.floorSnapshot(seq, seedHash, entHash, counts)
        DesyncLog.leave("floorDigest+dump")
    end
    module.checkFloorDigest(seq)
end

--- @param payload { s: integer, sd: integer, e: integer }
--- @param originSlot integer
local function onWorldChk(payload, originSlot)
    -- only the world host's fingerprint is authoritative
    if originSlot == Network.slot or originSlot ~= Network.hostSlot() then
        return
    end
    local s = math.floor(tonumber(payload.s) or -1)
    if s < 0 then
        return
    end
    hostFloorDigests[s] = {
        seed = math.floor(tonumber(payload.sd) or 0),
        ent = math.floor(tonumber(payload.e) or 0),
    }
    hostFloorDigests[s - 3] = nil -- floors long past can be dropped
    module.checkFloorDigest(s)
end

-- -------------------------------------------------------------- desync check

function module.sendChecksum()
    -- Iterate co-op indices in a FIXED order (1..4), not pairs(): the hash is
    -- an order-dependent polynomial, and pairs() order is not guaranteed
    -- identical across machines — folding in a different order produced a
    -- different hash from identical positions and raised a false "desync".
    local hash = 0
    for coopIndex = 1, 4 do
        local netSlot = coopSlots[coopIndex]
        if netSlot ~= nil then
            -- Skip a departed player past the shared cutoff: their spelunker is
            -- destroyed on every remaining machine at that same frame, so it is
            -- absent from the hash everywhere. Keying off the deterministic
            -- cutoff (not the wall-clock arrival of player_left) keeps the
            -- exclusion identical across machines — folding it by presence alone
            -- could differ for a frame and raise a false desync.
            local gone = goneSlots[netSlot]
            local pastCutoff = gone ~= nil and (seq ~= gone.seq or offset > gone.upto)
            if not pastCutoff then
                local player = get_player(coopIndex, false)
                if player ~= nil then
                    -- ABSOLUTE position. Entity.x/.y are RELATIVE to the overlay
                    -- whenever a player is attached to something (riding a mount,
                    -- being held), so a mounted player used to hash its ~(0,-0.16)
                    -- offset instead of where it actually is: blind to a mounted
                    -- player's real position, AND a guaranteed false alarm the
                    -- moment one machine has a player mounted and the other does
                    -- not (the whole coordinate space flips).
                    local px, py = player.x, player.y
                    pcall(function()
                        local abs = player:get_absolute_position()
                        px, py = abs.x, abs.y
                    end)
                    hash = (hash * 31 + math.floor(px * 10) + math.floor(py * 10) * 1000) % 2147483647
                    -- Fold in the player state that could diverge while positions
                    -- still matched — a captured desync had a player DEAD on one
                    -- machine and alive-and-mounted on the other, which a
                    -- position-only hash can only notice by accident. health and
                    -- the ridden mount are synced sim state, so this stays
                    -- deterministic; mounts are re-created each floor from the
                    -- synced inventory, so they can diverge on their own.
                    local hp = math.floor(tonumber(player.health) or 0)
                    local mount = 0
                    pcall(function()
                        local ov = player.overlay
                        if ov ~= nil then
                            mount = math.floor(ov.type.id)
                        end
                    end)
                    -- LAYER folded in: this mod does its OWN layer-door travel
                    -- (eventSync), and a travel that fired on one machine only
                    -- leaves a player in the wrong layer — same inputs, different
                    -- collision, so they walk apart. Position-only, that showed up
                    -- ~360 frames late as drifted x; hashing the layer catches it
                    -- on the very next sample. layer is synced sim state (both
                    -- machines set_layer on the same simulated frame), so this
                    -- stays deterministic and adds no false alarms.
                    local layer = 0
                    pcall(function() layer = math.floor(player.layer) end)
                    hash = (hash * 31 + hp * 7 + mount * 13 + layer * 17) % 2147483647
                end
            end
        end
    end
    local key = seq .. ":" .. offset
    checksums[key] = { mine = hash }
    -- Sent on the UNRELIABLE world channel, NOT the reliable event channel.
    -- Position checksums fire every CHECK_EVERY frames — by far the highest-rate
    -- traffic we produce — and the server refuses a client's events unless they
    -- arrive in strict cseq order (on_event drops any gap and waits for the
    -- resend). So a SINGLE dropped checksum datagram used to stall that client's
    -- ENTIRE reliable stream until it was resent, and the per-floor `levelseed`
    -- the non-host needs to generate the next floor was stuck behind it. When
    -- that seed arrived late the non-host built the floor from its own un-rebased
    -- seed — a guaranteed world divergence (observed: identical floors 1-2, then
    -- a wholesale-different floor 3). Checksums are detection-only and
    -- loss-tolerant: a lost sample just skips one comparison, so they belong on
    -- the unreliable channel where they can never block a critical event.
    Network.sendWorld({ k = "chk", s = seq, f = offset, h = hash })
end

--- @param payload { s: integer, f: integer, h: integer }
--- @param originSlot integer
local function onChecksum(payload, originSlot)
    if originSlot == Network.slot then
        return
    end
    if type(payload) ~= "table" then
        return
    end
    local key = math.floor(tonumber(payload.s) or 0) .. ":" .. math.floor(tonumber(payload.f) or 0)
    checksums[key] = checksums[key] or {}
    checksums[key].theirs = math.floor(tonumber(payload.h) or 0)
    local entry = checksums[key]
    if entry.mine ~= nil and entry.theirs ~= nil then
        if entry.mine ~= entry.theirs then
            -- Count consecutive disagreements. A one-off mismatch is expected and
            -- harmless when a player ends their adventure or leaves (their party
            -- dies locally for a moment before the run-end / departure resolves) —
            -- only a PERSISTENT disagreement means a mod is behaving
            -- non-deterministically, so hold the alarm until the streak is met.
            desyncStreak = desyncStreak + 1
            if desyncStreak >= DESYNC_STREAK_ALARM and not desyncReported then
                desyncReported = true
                errorf("DESYNC detected at %s (local %d vs remote %d, streak %d)",
                    key, entry.mine, entry.theirs, desyncStreak)
                toast("Desync detected — a mod is behaving non-deterministically")
                if DesyncLog ~= nil then
                    DesyncLog.positionDesync(key, entry.mine, entry.theirs, desyncStreak)
                end
            end
        else
            desyncStreak = 0 -- back in agreement
        end
        checksums[key] = nil
    end
end

-- -------------------------------------------------------------- presentation

--- Every machine's camera follows its OWN spelunker — and when that
--- spelunker is dead, the first living player instead, so nobody stares at
--- their corpse until the next level. Only touched during actual levels:
--- transition and cutscene cameras are the engine's business.
local function cameraTick()
    if not active or not module.hasStarted() or not Network.isInRun() then
        return
    end
    local levelState = get_local_state()
    if levelState.screen ~= SCREEN.LEVEL then
        return
    end
    if levelState.loading ~= FADE.NONE then
        -- the level is ending: hand the engine a front-layer camera for the
        -- transition. Vanilla can never end a level with the camera in the
        -- back layer (its transition drags everyone to the front first), and
        -- leaving it there while the level tears down is asking for trouble.
        pcall(function()
            if levelState.camera_layer ~= LAYER.FRONT then
                levelState.camera_layer = LAYER.FRONT
            end
        end)
        return
    end
    -- SafePlayer: this line threw "attempt to index a number value" when the
    -- engine returned a NUMBER, which passes the `== nil` test below. Only this
    -- site and pollBackLayerLights are wrapped; see the note there.
    local focus = SafePlayer(myCoopIndex, false)
    if focus == nil or (focus.health ~= nil and focus.health <= 0) then
        for coopIndex = 1, 4 do
            local ns = coopSlots[coopIndex]
            -- never fall back onto a departed player: their spelunker is hidden
            -- and weightless, so the camera would drift off to an empty spot
            if ns == nil or goneSlots[ns] == nil then
                local player = get_player(coopIndex, false)
                if player ~= nil and (player.health == nil or player.health > 0) then
                    focus = player
                    break
                end
            end
        end
    end
    if focus ~= nil then
        levelState.camera.focused_entity_uid = focus.uid
        -- render whatever layer our spelunker is in (camera-layer control is
        -- ours for the session), so anyone can take a back-layer door alone
        pcall(function()
            if levelState.camera_layer ~= focus.layer then
                levelState.camera_layer = focus.layer
            end
        end)
    end
end

local lastResendMs = 0

--- True once the lockstep sim has been waiting on a peer's inputs long enough to
--- warrant the on-screen "waiting for players" notice (menuUI draws it in the
--- lobby-plaque style). Matches the 1s threshold the stall's recovery uses.
--- @return boolean
function module.isStalled()
    return active and stallStartMs ~= nil and (get_ms() - stallStartMs) > 1000
end

--- True while a floor that generated differently from the host is being resynced
--- — menuUI draws a small top-right plaque for it (see drawResyncNotice).
--- @return boolean
function module.floorDesyncActive()
    return active and get_ms() < floorDesyncUntil
end

-- Helpers for the two reads the name-tag loop protects, each of which used to be a
-- `pcall(function() ... end)` — an allocation per remote player per display frame.
-- They live HERE, above guiTick, and that placement is the whole point: put below
-- it, as they first were, the names inside guiTick resolve as GLOBALS and come back
-- nil. `measureName` then threw on every frame a remote player was on screen, and
-- `readCameraLayer` failed silently inside its pcall so name tags stopped being
-- filtered by layer. Same shape as the shim bug that registered a callback above
-- its own declaration and handed Playlunky a nil.

--- @return integer
local function readCameraLayer()
    return get_local_state().camera_layer
end

--- Measured text width per name string. draw_text_size is a pure function of the
--- text and the font, and a name is fixed for the run, so this was re-measuring the
--- same string every display frame. Keyed by the string itself, so a rename simply
--- measures once more.
local nameWidth = {}

--- @param ctx GuiDrawContext
--- @param name string
--- @return number
local function measureName(ctx, name)
    local cached = nameWidth[name]
    if cached ~= nil then
        return cached
    end
    local ok, w = pcall(ctx.draw_text_size, ctx, 0, name)
    if not ok or type(w) ~= "number" then
        return 0 -- unchanged fallback: draw from the raw position
    end
    nameWidth[name] = w
    return w
end

--- Name tags over the other players, and a stall notice when waiting.
--- @param ctx GuiDrawContext
local function guiTick(ctx)
    if not active or not Network.isInRun() then
        return
    end
    -- Proof-of-life for crash attribution: a crash whose last log line is a
    -- heartbeat (rather than an unmatched '>>') did NOT happen in our code.
    if DesyncLog ~= nil then
        DesyncLog.heartbeat()
    end
    -- Arming the shared cursor for a mod's own menu is counted in RENDER frames,
    -- because that is the clock the mod's input cooldown counts on and it is the
    -- one that differs between machines (see MENU_ARM_FRAMES).
    if menuSyncOn then
        menuFrames = menuFrames + 1
    end
    -- redundant resend keepalive, throttled in real time (GUI frames run at
    -- display rate, which is uncapped on borderless fullscreen)
    local now = get_ms()
    if now - lastResendMs >= RESEND_INTERVAL_MS then
        lastResendMs = now
        sendRecentInputs()
    end
    if stallStartMs ~= nil and get_ms() - stallStartMs > 1000 then
        -- the on-screen notice is drawn by menuUI (in the lobby plaque style) off
        -- module.isStalled(); here we only handle recovery
        -- a stall against a live peer on a different sequence is a hard
        -- desync (they took a door we never saw): ask for a floor resync
        -- instead of hanging forever on "waiting for all players"
        if module.stallDesyncRole() ~= nil and EventSync ~= nil
            and EventSync.requestFloorResync ~= nil then
            EventSync.requestFloorResync()
        end
    end
    if get_local_state().screen ~= SCREEN.LEVEL then
        return
    end
    -- type-checked, not just nil-checked: this is the only thing guiTick indexes
    -- that comes from off the wire (run_start's slot->name map), and indexing it
    -- when it is not a table is exactly the "attempt to index a number value"
    -- this callback was seen to throw
    local names = Network.playerNames
    if type(names) ~= "table" then
        names = {}
    end
    local shownLayer = nil
    local okLayer, layer = pcall(readCameraLayer)
    if okLayer then
        shownLayer = layer
    end
    for coopIndex, netSlot in pairs(coopSlots) do
        -- skip a departed player: their spelunker is hidden, so a name tag
        -- floating over the empty spot would just be confusing
        if coopIndex ~= myCoopIndex and goneSlots[netSlot] == nil then
            local player = get_player(coopIndex, false)
            if player ~= nil and (shownLayer == nil or player.layer == shownLayer) then
                local name = names[tostring(netSlot)] or ("Player " .. netSlot)
                -- centered over the spelunker's head, hugging it closely
                local sx, sy = screen_position(player.x, player.y + 0.85)
                local width = measureName(ctx, name)
                ctx:draw_text(sx - width / 2, sy, 0, name, rgba(255, 255, 255, 200))
            end
        end
    end
end

--- Blank a departed player's row from the co-op HUD. Their entity still exists
--- (we only hid its sprite), so the engine keeps drawing its HUD row; every HUD
--- frame we fade that player's element to zero — `hud.data.players[slot].opacity`
--- is the field the game itself uses for the per-player HUD fade — and disable
--- its inventory slot. We modify the `hud` the render is about to use (passed to
--- the callback). Purely cosmetic and per-machine local — never touches the sim.
--- @param hud Hud
local function hideGoneHud(hud)
    if not active or not Network.isInRun() then
        return
    end
    -- also runs while nothing is gone but a row is still blanked, so a returning
    -- player gets their row back
    if next(goneSlots) == nil and next(hudBlanked) == nil then
        return
    end
    pcall(function()
        if hud == nil then
            hud = get_hud()
        end
        local data = hud ~= nil and hud.data or nil
        if data == nil then
            return
        end
        for coopIndex, netSlot in pairs(coopSlots) do
            if goneSlots[netSlot] ~= nil then
                -- `opacity` alone left FRAGMENTS: the API documents it as
                -- "Background will be drawn if this is not 0.5", i.e. it controls
                -- the row's BACKGROUND, not its contents -- so the departed
                -- player's hearts, bombs and ropes kept drawing over an empty
                -- slot. Zero the counts the row renders as well.
                if data.players ~= nil and data.players[coopIndex] ~= nil then
                    local row = data.players[coopIndex]
                    row.opacity = 0
                    row.health = 0
                    row.bombs = 0
                    row.ropes = 0
                end
                if data.inventory ~= nil and data.inventory[coopIndex] ~= nil then
                    data.inventory[coopIndex].enabled = false
                end
                hudBlanked[coopIndex] = true
            elseif hudBlanked[coopIndex] ~= nil then
                -- back in the room: hand the row back. `enabled` is ours to undo --
                -- the engine does not re-enable a slot we switched off, so without
                -- this a rejoining player had no inventory row at all.
                if data.inventory ~= nil and data.inventory[coopIndex] ~= nil then
                    data.inventory[coopIndex].enabled = true
                end
                hudBlanked[coopIndex] = nil
            end
        end
    end)
end

--- Hide departed players the instant a new floor is generated, BEFORE it fades
--- in. The engine rebuilds the party from the roster each level, so a gone
--- player is re-spawned visible; without this early hide they flash into view
--- for the frames before the sim's per-tick hide re-applies. Deterministic-safe:
--- the flags are re-asserted every sim tick anyway, and this only runs before
--- the first tick, so no machine's physics can diverge.
local function hideGoneOnNewLevel()
    if not active or not Network.isInRun() or next(goneSlots) == nil then
        return
    end
    for coopIndex = 1, 4 do
        local netSlot = coopSlots[coopIndex]
        if netSlot ~= nil and goneSlots[netSlot] ~= nil then
            local player = get_player(coopIndex, false)
            if player ~= nil then
                hidePlayerEntity(player, netSlot)
            end
        end
    end
end

--- The engine shows an off-screen indicator (a floating character bubble +
--- arrow) for every co-op player who is off the edge of the screen. A departed
--- player that stays in the party (a middle/leading slot the contiguous roster
--- can't cut, e.g. the host leaving while a friend plays on) is hidden and
--- frozen off-screen, so its indicator lingers. Hide the indicator FX attached
--- to any gone player every frame. These are cosmetic, camera-derived, per-
--- machine entities, so hiding them never touches the shared simulation.
local function hideGoneIndicators()
    if not active or not Network.isInRun() or next(goneSlots) == nil then
        return
    end
    local goneUids = {}
    local any = false
    for coopIndex = 1, 4 do
        local netSlot = coopSlots[coopIndex]
        if netSlot ~= nil and goneSlots[netSlot] ~= nil then
            local player = get_player(coopIndex, false)
            if player ~= nil then
                goneUids[player.uid] = true
                any = true
            end
        end
    end
    if not any then
        return
    end
    pcall(function()
        local fx = get_entities_by_type(ENT_TYPE.FX_PLAYERINDICATOR,
            ENT_TYPE.FX_PLAYERINDICATORPORTRAIT)
        for _, uid in ipairs(fx) do
            local ent = get_entity(uid)
            if ent ~= nil then
                -- hide it if it points at a gone player directly, or if it's the
                -- portrait mounted on such an indicator (its overlay/parent)
                local hide = false
                pcall(function()
                    if ent.attached_to ~= nil and goneUids[ent.attached_to] then
                        hide = true
                    end
                end)
                if not hide then
                    pcall(function()
                        local parent = ent.overlay
                        if parent ~= nil and parent.attached_to ~= nil
                            and goneUids[parent.attached_to] then
                            hide = true
                        end
                    end)
                end
                if hide then
                    ent.flags = set_flag(ent.flags, ENT_FLAG.INVISIBLE)
                end
            end
        end
    end)
end

--- The unreliable world channel carries traffic that must never be able to block
--- a reliable event: the position checksum (detection), and a REDUNDANT copy of
--- the host's per-floor seed — the reliable levelseed can head-of-line-stall a
--- client into generating a floor from its own drifted seed, so the host also
--- pushes it here where nothing can stall (see eventSync pollRebroadcastSeed).
--- Dispatch by `k`.
--- @param slot integer
--- @param data any
local function onWorldMsg(slot, data)
    if type(data) ~= "table" then
        return
    end
    if data.k == "chk" then
        onChecksum(data, slot)
    elseif data.k == "seed" then
        if EventSync ~= nil and EventSync.applyHostSeed ~= nil then
            EventSync.applyHostSeed(data, slot)
        end
    end
end

Network.onState(onRemoteInputs)
Network.onWorld(onWorldMsg)
Network.onEvent("worldchk", onWorldChk)
Network.onEvent("menu", onMenuEvent)

-- Global infrastructure callbacks: no-ops unless a networked run is active.
set_callback(function()
    -- The resend keepalive, which normally lives in guiTick (ON.GUIFRAME).
    --
    -- It has to run from here as well. While the lockstep gate is holding, our own
    -- `myRecorded` stops advancing, so the ONLY thing putting our inputs back on the
    -- wire is that keepalive -- and hosting a content mod has been observed to take
    -- our GUIFRAME callbacks out entirely (see the watchdog in netCore). When that
    -- happens neither machine resends, so neither can ever unblock the other, and a
    -- recoverable stall becomes a permanent freeze. Same throttle, so on a healthy
    -- frame this is a no-op that the timer swallows.
    if active and Network.isInRun() then
        local resendNow = get_ms()
        if resendNow - lastResendMs >= RESEND_INTERVAL_MS then
            lastResendMs = resendNow
            SafeCall("inputSync:resendFromPreUpdate", sendRecentInputs)
        end
    end
    if DesyncLog ~= nil then
        DesyncLog.frameMark("preUpdate")
    end
    -- Normalise to EXACTLY `true` or no value at all. This hook takes an
    -- optional boolean (true = skip the sim tick), and forwarding SafeCall's
    -- result raw meant whatever preUpdate happened to return -- or an explicit
    -- nil from SafeCall's failure path -- went straight into that conversion.
    -- Playlunky logged `Mod: fyi.modded-online / Error: Unexpected return type
    -- from function...` with no accompanying Lua error of ours, i.e. it rejected
    -- a value we RETURNED rather than anything that threw. This is the only
    -- callback we forward a return through, so it is the only candidate.
    local hold = SafeCall("inputSync:preUpdate", preUpdate)
    if DesyncLog ~= nil then
        DesyncLog.frameDone("preUpdate")
    end
    if hold == true then
        return true
    end
    -- anything else: return NOTHING (not nil) and let the tick proceed
end, ON.PRE_UPDATE)
set_callback(function()
    if DesyncLog ~= nil then
        DesyncLog.frameMark("gameframe:camera+hideGone")
    end
    SafeCall("inputSync:cameraTick", cameraTick)
    SafeCall("inputSync:hideGoneIndicators", hideGoneIndicators)
    SafeCall("inputSync:restoreReturnedPlayers", restoreReturnedPlayers)
    if DesyncLog ~= nil then
        DesyncLog.frameDone("gameframe:camera+hideGone")
    end
end, ON.GAMEFRAME)
set_callback(function(ctx)
    if DesyncLog ~= nil then
        DesyncLog.frameMark("guiframe:guiTick")
    end
    SafeCall("inputSync:guiTick", guiTick, ctx)
    if DesyncLog ~= nil then
        DesyncLog.frameDone("guiframe:guiTick")
    end
end, ON.GUIFRAME)
-- The co-op HUD draws every player's inventory row; blank a departed player's
-- right before it renders (the callback hands us the hud to modify). Guarded in
-- case this Overlunky build lacks the hook.
if ON.RENDER_PRE_HUD ~= nil then
    set_callback(function(_, hud)
        if DesyncLog ~= nil then
            DesyncLog.frameMark("renderPreHud:hideGoneHud")
        end
        SafeCall("inputSync:hideGoneHud", hideGoneHud, hud)
        if DesyncLog ~= nil then
            DesyncLog.frameDone("renderPreHud:hideGoneHud")
        end
    end, ON.RENDER_PRE_HUD)
end
-- Re-hide departed players the moment each floor is generated, before it fades
-- in, so they never flash into view at the start of a level.
if ON.POST_UPDATE ~= nil then
    set_callback(function()
        if DesyncLog ~= nil then
            DesyncLog.frameDone("engineUpdate")
        end
    end, ON.POST_UPDATE)
end
if ON.POST_LEVEL_GENERATION ~= nil then
    set_callback(function()
        SafeCall("inputSync:hideGoneOnNewLevel", hideGoneOnNewLevel)
    end, ON.POST_LEVEL_GENERATION)
end

InputSync = module
return module
