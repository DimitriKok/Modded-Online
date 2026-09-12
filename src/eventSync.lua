--- Modded Online — run lifecycle for lockstep co-op.
---
--- Flow: hosting or joining connects to the room and immediately launches
--- the game's own play flow — each player picks their character in the
--- vanilla character select and lands in their local base camp. Arriving in
--- camp marks the player READY (with their chosen character). The run
--- starts when the HOST walks into the camp's main door; everyone else's
--- door refuses entry. The server then broadcasts the seed and the full
--- character roster, and every machine warps into the same 1-1 where the
--- lockstep gate (src/inputSync.lua) takes over.

local module = {}

local runActive = false
--- @type integer[]? # exact seed to force on every level generation until the
--- run's (or a resync warp's) first level actually ENGAGES — kept alive across
--- overlapping loads so a stray in-flight load can't consume it early
local pendingRunSeed = nil
--- @type table<string, integer>? # slot -> chosen character, fixed at run start
local rosterChars = nil
local launchedPlayFlow = false -- play_adventure() fired for this lobby visit
local sentReady = false        -- ready announced for this camp visit
local announceLobbyReady       -- fwd: defined after onScreenChange, called by it
local startRequested = false   -- host: door start requested once
local doorHookPending = false  -- camp reached, main door not hooked yet
local myReady = false          -- public lobby: our ready state, toggled at the door
local lastReadyToggleMs = 0    -- debounce for the public door ready toggle
local lastAutoStartMs = 0      -- public lobby: throttle the host's auto-start
local mainDoorUid = nil        -- camp main exit entity (inert online; used for ready detection)
-- Every camp door we made inert this visit: uid -> {world, level, theme} for a
-- SHORTCUT door, or false for the main exit (a normal 1-1 start).
local campDoors = {}
-- the door WE are readied at ({w,l,t}), or nil for the main exit
local myReadyDest = nil
local doorReadyHeld = false    -- was the door input held last frame (rising-edge ready press)

-- Per-level seed rebase. The adventure seed evolves deterministically with each
-- level's generation, so a mid-floor desync (a mod drawing RNG differently on
-- one machine) makes the seed — and therefore every following floor — diverge.
-- To bound that: the fixed world host broadcasts its adventure seed after it
-- generates each level, and every other client re-applies that seed just before
-- generating the NEXT level. So a desync only corrupts the floor it happened on;
-- the next floor is regenerated from the host's authoritative seed and everyone
-- snaps back onto the same world. When already in sync the host's seed equals a
-- client's own, so it's a harmless no-op.
--
-- levelOrdinal counts levels the lockstep gate has ENGAGED this run (not raw
-- generations: an instant restart or resync warp can generate a level twice on
-- one machine but only ever engages it once, and engagement happens at the
-- identical simulation state everywhere). It keys which broadcast seed belongs
-- to which upcoming level, guarding against late/stale packets.
local levelOrdinal = 0
local hostSeeds = {}   -- ordinal -> { first, second } captured from the world host

-- Floor resync. When worlds hard-diverge, one machine takes the exit door in
-- ITS world while the others never see that: the machines end up on different
-- input sequences and deadlock on "Waiting for other players". Recovery: the
-- world host broadcasts a floor_warp (destination + the seed that generates it
-- + an agreed fresh sequence number) through the ordered event channel, and
-- every machine — host included — warps into an identical generation of it.
-- The destination is always the floor PAST the stuck one (the ahead machine
-- reports where its exit led): regenerating the stuck floor proved to be a
-- trap, because the player-state divergence that caused the desync survives
-- the regeneration and immediately re-desyncs the same floor, forever.
local currentFloorSeed = nil   -- seed captured just before this floor generated
local currentFloorOrd = 0      -- levelOrdinal at that same moment
local currentFloor = nil       -- { w, l, t } of the floor being played
local nextFloorSeed = nil      -- evolved seed after this floor generated (= next floor's)
local pendingWarp = nil        -- floor_warp payload waiting for loading to end
local pendingStateSync = nil   -- host's run/player snapshot riding that warp
--- last world index we asked the content mod to adopt, so a snapshot applied at
--- both PRE_LOAD_SCREEN and PRE_LEVEL_GENERATION only logs the handoff once
local lastResyncMs = 0         -- rate limit for requesting/broadcasting resyncs
local digestResyncStreak = 0   -- consecutive per-floor-digest resyncs w/o a clean floor
local MAX_DIGEST_RESYNCS = 2   -- after this, stop auto-warping and leave the notice up
local digestResyncTimes = {}   -- get_ms of recent digest resyncs (circuit-breaker window)
local digestGaveUp = false     -- too many resyncs: an unhealable divergence, stop warping
local DIGEST_GIVEUP_WINDOW = 300000 -- 5 min
local DIGEST_GIVEUP_COUNT = 6  -- >this many resyncs in the window = a persistent desync
local joinPending = false      -- a readied late-joiner is waiting to be folded in
                               -- at the next floor (mid-run join; host triggers it)
local joinInit = false         -- one-shot: give a just-added late-joiner a living
                               -- body on the next floor generation
local moneyBaseline = {}       -- coopIndex -> money at this floor's engage (per-floor money reconcile)
local moneyBaselineSeq = -1    -- lockstep seq the baseline belongs to (ignore stale packets)
local trackedMoney = {}        -- coopIndex -> last live money seen IN a level; survives the
                               -- transition (where the live player is gone and the inventory
                               -- struct is a STALE floor-start value) so a mid-run join snapshot
                               -- carries the money earned on the floor just finished

-- Instant-restart plumbing. QUEST reset flag bit (QUEST_FLAG.RESET).
local QUEST_RESET = 1

local suppressWarpUntil = 0    -- our own warps also raise the reset flag: ignore them
-- Set ONLY while a camp warp WE issued is in flight. The death-screen restart
-- guard used to ask "is the pending destination the camp?", but the ENGINE's own
-- post-death transition heads for the camp too, so that question answered "yes"
-- for an ordinary death and the guard let the local Quick Restart through -- every
-- machine then reloaded on its own seed and the party split into separate runs.
local campWarpUntil = 0
local awaitingRestartUntil = 0 -- host asked the server to restart; run_start is coming
-- The seed the world host publishes for the NEXT floor, captured at THIS floor's
-- post-generation and tagged with the ordinal it generates. Kept separate from
-- nextFloorSeed (which the join/resync paths reuse and which therefore survives
-- across floors) so it can NEVER be stale: publishing a previous floor's seed
-- would be worse than publishing none.
-- forward declaration: onRunStart is defined ABOVE the implementation but must be
-- able to call it (see the run_start call site for why that call site is required)
local applyFreshRunReset
local floorSeedForOrd = nil    -- { ord = integer, seed = { integer, integer } }
local publishedSeedOrd = nil   -- highest ordinal already broadcast (idempotence)
local restartNonce = nil       -- id of the pending restart request (resent until answered)
local restartResendMs = 0
-- Mid-run instant restart is a VOTE (a lone non-host restart used to crash by
-- redirecting the level load to the camp). Pressing it cancels the local
-- restart and casts a vote; the run only restarts once every present player has
-- voted, via the host's run_start (which reloads all machines together).
local RESTART_VOTE_TTL = 20000 -- an incomplete vote expires after this
local restartVotes = {}        -- netSlot -> true (who has voted this round)
local restartVoted = false     -- have WE voted this round (one cast per round)
local restartVoteDeadline = nil -- get_ms() by which the vote must complete
local unhandledRestartNoticeMs = 0
local restartProbeMs = 0       -- rate-limit for the restart decision probe
local lobbyRestartAttempts = 0 -- bounded retries for a restart pressed outside a run -- rate-limit for the "restart NOT intercepted" notice
-- while this window is open we keep squashing the restart's fade each frame, in
-- case the engine re-drives it for a frame or two after the flag is cleared
local restartSuppressUntil = 0
local restartSeenNoticeMs = 0  -- rate limit for the "restart flag SEEN" probe
local runEndedNoticeMs = nil   -- server says the run ended but we're still playing
local myPickedChar = nil       -- character from the last REAL character select
local menuSinceMs = nil        -- lobby member idling on the main menu since (get_ms)
-- client party wipe: hold the death screen and ask the host for a floor
-- rescue until this deadline; only then declare the run over locally
local deathRecoveryUntil = nil
local deathResendMs = 0
-- After a whole-party death (real wipe OR End Adventure) we soft-leave to the
-- lobby immediately, then wait to see whether the room reopens (everyone died
-- => a real wipe, we stay to restart together) or keeps running for the others
-- (a solo End Adventure => we leave the room entirely). Set to get_ms() when the
-- decision is pending; pollGiveUpLeave resolves it.
local decideLeaveAtMs = nil
local GIVEUP_DECIDE_MS = 3000

-- -------------------------------------------------------------- helpers

local function myChosenChar()
    local select = get_local_state().items.player_select[1]
    local char = select ~= nil and select.character or 0
    if type(char) ~= "number" or char < 194 or char > 216 then
        char = 194 -- Ana, if the pick is unreadable
    end
    return math.floor(char)
end

--- A camp door's destination as a short comparable label ("1-1", "2-1", ...).
--- nil/absent means the main exit, i.e. a normal 1-1 start.
--- @param dest integer[]?
--- @return string
local function destLabel(dest)
    if type(dest) ~= "table" or dest[1] == nil then
        return "1-1"
    end
    return string.format("%d-%d", math.floor(dest[1]), math.floor(dest[2] or 1))
end

--- PUBLIC lobby: everyone has to be readied at the SAME camp door. Without this
--- one player could ready at the main exit and another at a shortcut, and the
--- run would begin in a different world for different people.
--- @return boolean
local function everyoneSameDest()
    local want = nil
    for _, player in ipairs(Network.lobbyPlayers) do
        local label = destLabel(player.dest)
        if want == nil then
            want = label
        elseif want ~= label then
            return false
        end
    end
    return true
end

local function everyoneReady()
    local players = Network.lobbyPlayers
    if #players == 0 then
        return false
    end
    for _, player in ipairs(players) do
        if not player.ready then
            return false
        end
    end
    return true
end

--- Every warp this mod performs goes through here, and is DEFERRED until no
--- load fade is in flight: warp() while another screen load is mid-flight
--- tears the level down around the load — a native crash, and the prime
--- suspect for "crashed right when the run ended elsewhere". warp() also
--- raises the same QUEST reset flag an instant restart does, so the flag
--- suppression happens at execution time, not at booking time.
local pendingMoWarp = nil

local function moWarp(world, level, theme)
    pendingMoWarp = { w = world, l = level, t = theme }
end

local function pollMoWarp()
    if pendingMoWarp == nil then
        return
    end
    if get_local_state().loading ~= FADE.NONE then
        return -- wait out the in-flight load, then warp
    end
    local dest = pendingMoWarp
    pendingMoWarp = nil
    suppressWarpUntil = get_ms() + 3000
    if dest.t == THEME.BASE_CAMP then
        -- stamp the provenance the death-screen guard needs: THIS camp trip is ours
        campWarpUntil = get_ms() + 3000
    end
    warp(dest.w, dest.l, dest.t)
end

--- The character the given network slot picked for this run (ENT_TYPE).
--- @param netSlot integer
--- @return integer?
function module.characterFor(netSlot)
    if rosterChars == nil then
        return nil
    end
    local char = rosterChars[tostring(netSlot)]
    return char ~= nil and math.floor(char) or nil
end

--- Reset all per-run state (shared by every way a run can end).
--- @param reason string? why the run is ending, recorded in the log. `run end`
--- with no reason cost a full debugging round: the log showed the run being torn
--- down immediately before a stray level generation, with nothing to say which of
--- the five teardown paths did it.
local function clearRunState(reason)
    if runActive and DesyncLog ~= nil then
        DesyncLog.event("run ending: %s", tostring(reason or "unspecified"))
    end
    runActive = false
    -- hand the player their own pet preference back (defined later in this file)
    if module.restorePetStyle ~= nil then
        module.restorePetStyle()
    end
    -- ...and their own save values, if a load was in flight when the run ended.
    if module.releaseSaveSync ~= nil then
        module.releaseSaveSync()
    end
    -- Forget whose values those WERE, as well as putting ours back. Releasing
    -- without clearing left the previous host's `shortcuts`/`characters` sitting in
    -- `saveSyncHost` for the rest of the session, so the first load of the NEXT run
    -- -- in a different room, before that host's first broadcast arrives -- held a
    -- player who has left to the progression of a player they are no longer playing
    -- with. There is no version of that which is correct.
    if module.forgetSaveSync ~= nil then
        module.forgetSaveSync()
    end
    pendingRunSeed = nil
    rosterChars = nil
    hostSeeds = {}
    levelOrdinal = 0
    launchedPlayFlow = false
    sentReady = false
    startRequested = false
    myReady = false
    doorHookPending = false
    mainDoorUid = nil
    campDoors = {}
    myReadyDest = nil
    doorReadyHeld = false
    currentFloorSeed = nil
    currentFloor = nil
    nextFloorSeed = nil
    pendingWarp = nil
    pendingStateSync = nil
    lastResyncMs = 0
    digestResyncStreak = 0
    digestResyncTimes = {}
    digestGaveUp = false
    awaitingRestartUntil = 0
    floorSeedForOrd = nil
    publishedSeedOrd = nil
    restartNonce = nil
    restartVotes = {}
    restartVoteDeadline = nil
    restartVoted = false
    restartSuppressUntil = 0
    runEndedNoticeMs = nil
    menuSinceMs = nil
    deathRecoveryUntil = nil
    pendingMoWarp = nil
    joinPending = false
    joinInit = false
    moneyBaseline = {}
    moneyBaselineSeq = -1
    trackedMoney = {}
end

-- -------------------------------------------------------------- state sync

--- Host-authoritative snapshot riding a floor_warp: the run counters that
--- shape future floors (level count, shopkeeper aggro, Kali) plus every
--- player's inventory. The engine rebuilds spelunkers at level load from
--- state.items.player_inventory, so syncing THAT (rather than performing
--- surgery on live entities) makes everyone spawn with identical health,
--- bombs, ropes, money, powerups, held item and mount — and, critically,
--- keeps entity uids deterministic (a held shotgun spawning on one machine
--- but not another would fork the uid sequence and re-desync instantly).
--- Every field is pcall-guarded so an API difference degrades that field
--- instead of the whole snapshot; identical degradation on every machine
--- keeps it deterministic regardless.
--- @param withRunFlags boolean? # include quest/presence flags. ONLY a fresh
---   camp joiner needs them (they lack the run's progress). A resync participant
---   already has them, so the desync-resync path leaves them out — it was proven
---   without these, and overriding them there risks perturbing recovery.
local function captureStateSync(withRunFlags)
    local state = get_local_state()
    local snap = { meta = {}, pl = {} }
    pcall(function()
        snap.meta.lc = state.level_count
        snap.meta.tt = state.time_total
        snap.meta.sa = state.shoppie_aggro
        snap.meta.sn = state.shoppie_aggro_next
        snap.meta.ma = state.merchant_aggro
        snap.meta.kf = state.kali_favor
        snap.meta.ks = state.kali_status
        snap.meta.ka = state.kali_altars_destroyed
        -- run-progress flags that DRIVE generation (which quest NPCs / special
        -- rooms have appeared, presence of outposts etc.). A mid-run JOINER (fresh
        -- from the camp) lacks these so their floor generates differently — but
        -- ONLY carry them for a join, never a resync (see the note above).
        if withRunFlags then
            snap.meta.qf = state.quest_flags
            snap.meta.pf = state.presence_flags
        end
    end)
    local coopSlots = Network.coopSlots or {}
    for coopIndex = 1, 4 do
        if coopSlots[coopIndex] ~= nil then
            local entry = {}
            pcall(function()
                local inv = state.items.player_inventory[coopIndex]
                entry.hp = inv.health
                entry.bo = inv.bombs
                entry.ro = inv.ropes
                -- prefer the last live money we tracked over the struct: at a
                -- transition the struct is a stale floor-start value (missing the
                -- floor just finished). The live override below still wins when a
                -- live player is present (in-level resync).
                entry.mo = trackedMoney[coopIndex] or inv.money
                entry.po = inv.poison_tick_timer
                -- coffin revival ORDER: unsynced, two machines can revive DIFFERENT
                -- slots from the same coffin (see normalizeCoffinTargets)
                entry.td = inv.time_of_death
                entry.cu = inv.cursed and 1 or 0
                entry.eb = inv.elixir_buff
                entry.kb = inv.kapala_blood_amount
                entry.hi = inv.held_item
                entry.hm = inv.held_item_metadata
                entry.mt = inv.mount_type
                entry.mm = inv.mount_metadata
                local ups = {}
                for k = 1, 30 do
                    ups[k] = math.floor(tonumber(inv.acquired_powerups[k]) or 0)
                end
                entry.up = ups
            end)
            -- the engine only refreshes that snapshot at level boundaries;
            -- live entities carry anything gained or lost since — let them
            -- overrule the stale copy where they exist
            local player = get_player(coopIndex, false)
            if player ~= nil then
                pcall(function() entry.hp = player.health end)
                pcall(function() entry.po = player.poison_tick_timer end)
                pcall(function()
                    entry.bo = player.inventory.bombs
                    entry.ro = player.inventory.ropes
                    entry.mo = player.inventory.money
                end)
                pcall(function()
                    local held = player.holding_uid >= 0
                        and get_entity(player.holding_uid) or nil
                    if held ~= nil then
                        if held.type.id ~= entry.hi then
                            entry.hi = held.type.id
                            entry.hm = 0
                        end
                    else
                        entry.hi = 0
                        entry.hm = 0
                    end
                end)
                pcall(function()
                    local mount = player.overlay
                    if mount ~= nil and (mount.type.search_flags & MASK.MOUNT) ~= 0 then
                        if mount.type.id ~= entry.mt then
                            entry.mt = mount.type.id
                            entry.mm = 0
                        end
                    else
                        entry.mt = 0
                        entry.mm = 0
                    end
                end)
                pcall(function()
                    local ups = {}
                    for _, powerupType in ipairs(player:get_powerups()) do
                        ups[#ups + 1] = math.floor(powerupType)
                    end
                    for k = #ups + 1, 30 do
                        ups[k] = 0
                    end
                    entry.up = ups
                end)
            end
            snap.pl[tostring(coopIndex)] = entry
        end
    end
    return snap
end

--- Write the host's snapshot into our run state and player-rebuild data.
--- Runs at PRE_LOAD_SCREEN and PRE_LEVEL_GENERATION (both before players
--- spawn; idempotent) while a resync warp's snapshot is pending.
local function applyStateSync()
    if pendingStateSync == nil then
        return
    end
    local state = get_local_state()
    local meta = pendingStateSync.meta or {}
    pcall(function()
        if meta.lc ~= nil then state.level_count = math.floor(meta.lc) end
        if meta.tt ~= nil then state.time_total = math.floor(meta.tt) end
        if meta.sa ~= nil then state.shoppie_aggro = math.floor(meta.sa) end
        if meta.sn ~= nil then state.shoppie_aggro_next = math.floor(meta.sn) end
        if meta.ma ~= nil then state.merchant_aggro = math.floor(meta.ma) end
        if meta.kf ~= nil then state.kali_favor = math.floor(meta.kf) end
        if meta.ks ~= nil then state.kali_status = math.floor(meta.ks) end
        if meta.ka ~= nil then state.kali_altars_destroyed = math.floor(meta.ka) end
        -- run-progress flags that drive generation. NEVER carry the RESET bit
        -- (bit 1) — it would trigger a run reset on the next level load.
        if meta.qf ~= nil then state.quest_flags = math.floor(meta.qf) & ~QUEST_RESET end
        if meta.pf ~= nil then state.presence_flags = math.floor(meta.pf) end
    end)
    for coopIndex = 1, 4 do
        local entry = (pendingStateSync.pl or {})[tostring(coopIndex)]
        if entry ~= nil then
            pcall(function()
                local inv = state.items.player_inventory[coopIndex]
                if entry.hp ~= nil then
                    -- Sync the host's ACTUAL health, dead included. The host's world
                    -- is authoritative, so a player dead there must be dead here too
                    -- — the old "revive to 4 HP" resurrected legitimately-dead
                    -- players on every resync ("all come back alive"). Aligning to
                    -- the host can't re-desync (both machines end up with the host's
                    -- state); a player who LEFT is handled separately (goneSlots).
                    inv.health = math.floor(entry.hp)
                end
                if entry.bo ~= nil then inv.bombs = math.floor(entry.bo) end
                if entry.ro ~= nil then inv.ropes = math.floor(entry.ro) end
                if entry.mo ~= nil then inv.money = math.floor(entry.mo) end
                if entry.po ~= nil then inv.poison_tick_timer = math.floor(entry.po) end
                if entry.td ~= nil then inv.time_of_death = math.floor(entry.td) end
                if entry.cu ~= nil then inv.cursed = entry.cu == 1 end
                if entry.eb ~= nil then inv.elixir_buff = math.floor(entry.eb) end
                if entry.kb ~= nil then inv.kapala_blood_amount = math.floor(entry.kb) end
                if entry.hi ~= nil then inv.held_item = math.floor(entry.hi) end
                if entry.hm ~= nil then inv.held_item_metadata = math.floor(entry.hm) end
                if entry.mt ~= nil then inv.mount_type = math.floor(entry.mt) end
                if entry.mm ~= nil then inv.mount_metadata = math.floor(entry.mm) end
                if entry.up ~= nil then
                    for k = 1, 30 do
                        inv.acquired_powerups[k] = math.floor(tonumber(entry.up[k]) or 0)
                    end
                end
            end)
        end
    end
end

-- ------------------------------------------------------------------ pet style
-- The level's PET (dog / cat / hamster) is spawned from `GAME_SETTING.PET_STYLE`,
-- a PER-MACHINE game setting — there is exactly ONE pet entity per floor, so two
-- players with different preferences generate different worlds from the same seed.
-- A real capture had floors 1-1 and 1-2 identical EXCEPT the host holding a
-- MONS_PET_DOG where the peer held a MONS_PET_HAMSTER; the pets then behave
-- differently (different AI and physics), which cascaded into a wholly different
-- 1-3 and a position desync. Fix: everyone adopts the ROOM HOST's pet style for
-- the duration of a networked run. `set_setting` is documented as TEMPORARY and
-- NOT saved, so a player's real preference is never rewritten (and the options
-- menu that could reset it is already blocked mid-run by suppressMenuScreens).
local PET_BROADCAST_MS = 2000
local petBroadcastMs = 0
local petStyleLocal = nil -- our own real setting, captured once
local petStyleHost = nil  -- the host's value, once known

local function petStyleSetting()
    local v = nil
    pcall(function() v = get_setting(GAME_SETTING.PET_STYLE) end)
    return v
end

--- Host: publish our pet style on a slow cadence. Runs in the LOBBY too, so peers
--- already hold the value well before the first floor is generated (a run can only
--- start from the lobby), which is what keeps floor 1-1 in sync.
local function pollPetStyle()
    if not Network.isActive() then
        return
    end
    if petStyleLocal == nil then
        petStyleLocal = petStyleSetting()
    end
    if not Network.isHost() then
        return
    end
    local now = get_ms()
    if now - petBroadcastMs < PET_BROADCAST_MS then
        return
    end
    petBroadcastMs = now
    local v = petStyleSetting()
    if v ~= nil then
        Network.sendEvent("petstyle", { p = math.floor(v) })
    end
end

--- The slot whose pet style everyone adopts. `Network.hostSlot()` is the RUN host,
--- but it reads `runHostSlot`, which is only set once a run starts — in the LOBBY
--- it is 0, so a lobby broadcast used to be rejected and the value only landed
--- after floor 1-1 had already generated with the wrong pet. Fall back to the
--- lobby's host (the first lobby entry, the same one Network.isHost() compares
--- against) so the pet is agreed BEFORE the first floor is built.
--- @return integer
local function petHostSlot()
    local s = Network.hostSlot()
    if s ~= nil and s > 0 then
        return s
    end
    local lobby = Network.lobbyPlayers
    if lobby ~= nil and lobby[1] ~= nil and lobby[1].slot ~= nil then
        return math.floor(lobby[1].slot)
    end
    return 1
end

--- @param payload { p: integer }
--- @param originSlot integer
local function onPetStyle(payload, originSlot)
    if originSlot ~= petHostSlot() or Network.isHost() then
        return -- only the room host is authoritative; never apply our own echo
    end
    local v = math.floor(tonumber(payload.p) or -1)
    if v < 0 then
        return
    end
    if petStyleLocal == nil then
        petStyleLocal = petStyleSetting()
    end
    petStyleHost = v
    pcall(function() set_setting(GAME_SETTING.PET_STYLE, v) end)
end

--- Re-assert the host's pet style (cheap; called at each floor's generation). The
--- setting is temporary, so anything that resets it — or a value that arrived after
--- we had already adopted one — can't leave us spawning the wrong pet.
local function enforcePetStyle()
    if petStyleHost == nil or Network.isHost() then
        return
    end
    if petStyleSetting() ~= petStyleHost then
        pcall(function() set_setting(GAME_SETTING.PET_STYLE, petStyleHost) end)
    end
end

--- Put our own pet preference back when the run/room ends. `set_setting` never
--- persists, but restoring keeps the rest of the session honest. Exposed on the
--- module because clearRunState is defined earlier in the file than this.
function module.restorePetStyle()
    if petStyleHost == nil then
        return
    end
    petStyleHost = nil
    if petStyleLocal ~= nil then
        pcall(function() set_setting(GAME_SETTING.PET_STYLE, petStyleLocal) end)
    end
end

-- ------------------------------------------ save-derived generation state
--
-- Mods branch on the LOCAL player's save, and two players never have the same one.
-- The HD mod reads `savegame.shortcuts` thirteen times in lib/shortcut.lua and
-- `savegame.characters` seven times in lib/unlocks.lua, both while a floor is being
-- built:
--
--   * `shortcuts` drives the MAMA TUNNEL encounter at a world transition (1 = met
--     Terra, 4 = Jungle, 7 = Ice Caves, 10 = Temple). One player gets the cutscene
--     and the other walks straight through, so the two machines are on different
--     screens holding different entities. That is the 1-4 -> 2-1 desync in the
--     capture: 34 lockstep stalls, a resync warp, and a position desync on the
--     floor after it.
--   * `characters` drives the per-floor CHARACTER UNLOCK, and that choice draws
--     from the level-generation PRNG -- so two players with different unlocks
--     consume a different number of draws and everything after lands elsewhere.
--
-- QUEST_FLAG.SEEDED used to neutralise all of this for free, because a seeded run
-- has neither a shortcut flow nor an unlock branch. It was removed by request in
-- 2.0.0-dev46 and the very next session desynced, so this replaces it with
-- something narrower that leaves shortcuts and progression working.
--
-- Same shape as the pet style above -- the room host publishes, everyone else
-- adopts -- with one critical difference. `set_setting` is documented as temporary
-- and never persists. `savegame` is EXACTLY what the game serialises into
-- savegame.sav, so an override left standing is one the game can write to somebody
-- else's disk.
--
-- It is therefore held only across a load, and released the moment the screen
-- settles. That is the same technique the HD mod uses on this very field:
-- `prevent_shortcut_encounter` in lib/shortcut.lua sets `savegame.shortcuts`, then
-- puts the original back on the next ON.POST_UPDATE. No save can happen inside that
-- window, and if the process dies while the override is in force the file on disk
-- was never touched -- we only ever wrote memory.
local SAVE_SYNC_FIELDS = { "shortcuts", "characters" }
local SAVE_BROADCAST_MS = 2000
local saveBroadcastMs = 0
local saveSyncHost = nil   -- the host's values, once known
local saveSyncOwn = nil    -- OUR values, parked here only while the override is up
local saveSyncHeldMs = 0

--- @param name string
--- @return integer?
local function readSaveField(name)
    local v = nil
    pcall(function() v = savegame[name] end)
    if type(v) ~= "number" then
        return nil
    end
    return math.floor(v)
end

--- @param name string
--- @param value integer
local function writeSaveField(name, value)
    pcall(function() savegame[name] = value end)
end

--- Host: publish on the same slow cadence as the pet style, and in the LOBBY too,
--- so every peer holds the values before floor 1-1 is ever built.
local function pollSaveSync()
    -- Release first, and unconditionally: this runs every frame, so an override
    -- that outlived its load cannot survive here. `loading == FADE.NONE` means the
    -- screen has settled -- every load-screen and generation callback has already
    -- run, including the ON.POST_LOAD_SCREEN the HD mod reads `shortcuts` from.
    if saveSyncOwn ~= nil then
        local settled = false
        pcall(function()
            settled = get_local_state().loading == FADE.NONE
        end)
        -- ...and a watchdog, because "released when the screen settles" is only
        -- true if the screen ever settles. Five seconds is far longer than any
        -- generation and still far shorter than a player reaching a save point.
        if settled or get_ms() - saveSyncHeldMs > 5000 then
            module.releaseSaveSync()
        end
    end
    if not Network.isActive() or not Network.isHost() then
        return
    end
    local now = get_ms()
    if now - saveBroadcastMs < SAVE_BROADCAST_MS then
        return
    end
    saveBroadcastMs = now
    local payload = {}
    for _, name in ipairs(SAVE_SYNC_FIELDS) do
        local v = readSaveField(name)
        if v ~= nil then
            payload[name] = v
        end
    end
    if next(payload) ~= nil then
        Network.sendEvent("savesync", payload)
    end
end

--- @param payload table
--- @param originSlot integer
local function onSaveSync(payload, originSlot)
    if originSlot ~= petHostSlot() or Network.isHost() then
        return -- only the room host is authoritative; never apply our own echo
    end
    local values = nil
    for _, name in ipairs(SAVE_SYNC_FIELDS) do
        local v = math.floor(tonumber(payload[name]) or -1)
        if v >= 0 then
            values = values or {}
            values[name] = v
        end
    end
    saveSyncHost = values
end

--- Put the host's values in place for the moment a mod reads them. ALWAYS paired
--- with a release -- see pollSaveSync, which runs every frame and owns that.
local function holdSaveSync()
    if saveSyncHost == nil or Network.isHost() or saveSyncOwn ~= nil then
        return
    end
    -- Nothing to do while saveShare is borrowing: it holds the host's values
    -- in `savegame` for the whole room rather than just across a load, and two
    -- mechanisms taking turns to own one field is how they end up fighting.
    if SaveShare ~= nil and SaveShare.borrowing ~= nil and SaveShare.borrowing() then
        return
    end
    local own = {}
    for name, hostValue in pairs(saveSyncHost) do
        local mine = readSaveField(name)
        if mine ~= nil and mine ~= hostValue then
            own[name] = mine
            writeSaveField(name, hostValue)
        end
    end
    saveSyncOwn = own
    saveSyncHeldMs = get_ms()
end

--- Our own values back, immediately. Exposed on the module because clearRunState is
--- defined earlier in this file, and because leaving this to one call site would be
--- exactly the mistake that writes the host's progress into a peer's save.
---
--- Anything a mod changed WHILE the override was up is discarded with it. That is
--- the right way round: the held window is a load, and a donation to Mama Tunnel
--- happens on the settled transition screen afterwards, by which point the player's
--- own value is back and the progress they earn is genuinely theirs.
function module.releaseSaveSync()
    if saveSyncOwn == nil then
        return
    end
    for name, mine in pairs(saveSyncOwn) do
        writeSaveField(name, mine)
    end
    saveSyncOwn = nil
end

--- Drop the host's values entirely. Separate from releaseSaveSync because the two
--- answer different questions: release is "give this player their own values back
--- NOW", forget is "there is no host any more, so there is nothing to hold". A run
--- ending is both. Declared on the module for the same reason releaseSaveSync is --
--- clearRunState is defined above it.
function module.forgetSaveSync()
    saveSyncHost = nil
end

--- Keep `player_inventory[].time_of_death` consistent with `.health`.
---
--- The engine picks WHO comes out of a co-op revival coffin from
--- `Inventory.time_of_death` ("set to state.time_total when player dies in coop, to
--- determinate who should be first to re-spawn from coffin"), NOT from health alone
--- — reviving needs health > 0 AND time_of_death == 0 (see the spawn_player docs).
--- Three places here force a slot back to ALIVE by writing `.health` directly:
--- applyStateSync (host snapshot), the fresh-run kit reset and joinInit. None of
--- them cleared time_of_death, so an ALIVE slot stayed a coffin candidate: the next
--- coffin — spawned legitimately for a genuinely dead teammate — got filled with
--- THAT slot's character, and spawn_player on an already-occupied slot "will spawn
--- clone" => a duplicate of a player who is already alive. This is the reported
--- "coffin spawns the alive player" bug, and the wipe-restart makes it certain: the
--- restart sets every slot health=4 and zeroes state.time_total while every slot
--- still carries the DEAD run's time_of_death.
---
--- Only ALIVE slots are touched, so a genuinely dead slot keeps its coffin and is
--- still revived normally. All FOUR slots are covered, not just the roster: an
--- unused slot 3/4 reads health>0 with no entity, so a stale time_of_death there
--- spawns a whole out-of-roster spelunker.
---
--- Deterministic: player_inventory health is synced state the engine does not update
--- mid-level, and this runs at PRE_LEVEL_GENERATION (the point the API documents for
--- editing these fields) before any gameplay tick — so every machine reads the same
--- healths and clears the same slots.
local function normalizeCoffinTargets()
    -- Same scoping as suppressUnlockCoffins: this rewrites engine inventory state
    -- (time_of_death) to steer the engine's coffin-revival choice. Only the mod
    -- that needed the fix gets it; other mods keep the untouched engine behaviour
    -- they were verified working with.
    if not Network.fullTreatmentMod() then
        return
    end
    pcall(function()
        local inv = get_local_state().items.player_inventory
        if inv == nil then
            return
        end
        for coopIndex = 1, 4 do
            local pi = inv[coopIndex]
            if pi ~= nil and pi.health ~= nil and pi.health > 0
                and pi.time_of_death ~= nil and pi.time_of_death ~= 0 then
                pi.time_of_death = 0
            end
        end
    end)
end

-- ------------------------------------------------------ per-floor money sync

-- Money can drift between machines (a mis-synced gold pickup or shop purchase)
-- without ever moving a player's x/y, so the lockstep POSITION checksum never
-- catches it. Each floor we reconcile it: every machine snapshots each player's
-- money at the floor's engage, the world host broadcasts its values, and the
-- others apply the DIFFERENCE to their live money (a delta — so gold grabbed in
-- the first frames of the floor, before the packet arrives, isn't discarded).
-- (moneyBaseline is declared with the other run state up top so clearRunState resets it.)

--- @param coopIndex integer
--- @return integer?
local function readPlayerMoney(coopIndex)
    local money = nil
    pcall(function()
        local player = get_player(coopIndex, false)
        if player ~= nil then
            money = math.floor(player.inventory.money) -- live value
        else
            local inv = get_local_state().items.player_inventory[coopIndex]
            if inv ~= nil then money = math.floor(inv.money) end
        end
    end)
    return money
end

--- Remember each present player's LIVE money every simulated frame while IN a
--- level, so a snapshot taken during a transition (join capture — the live player
--- is gone and the inventory struct is stale) still reflects the floor's earnings.
local function pollTrackMoney()
    if not runActive or not Network.isInRun() then
        return
    end
    if get_local_state().screen ~= SCREEN.LEVEL then
        return -- only a live level has current money; keep the last in-level value
    end
    local coopSlots = Network.coopSlots or {}
    for coopIndex = 1, 4 do
        if coopSlots[coopIndex] ~= nil then
            pcall(function()
                local player = get_player(coopIndex, false)
                if player ~= nil then
                    trackedMoney[coopIndex] = math.floor(player.inventory.money)
                end
            end)
        end
    end
end

--- At every floor's engage: snapshot each player's money (the baseline the host's
--- broadcast is reconciled against) and, if we are the world host, broadcast it.
local function syncFloorMoney()
    if not runActive or not Network.isInRun() then
        return
    end
    local coopSlots = Network.coopSlots or {}
    moneyBaseline = {}
    moneyBaselineSeq = InputSync.position() -- this floor's lockstep sequence
    local money = {}
    local any = false
    for coopIndex = 1, 4 do
        if coopSlots[coopIndex] ~= nil then
            local m = readPlayerMoney(coopIndex)
            if m ~= nil then
                moneyBaseline[coopIndex] = m
                money[tostring(coopIndex)] = m
                any = true
            end
        end
    end
    if any and Network.isWorldHost() then
        Network.sendEvent("money", { s = moneyBaselineSeq, m = money })
    end
end

--- Non-host: reconcile our money against the world host's floor-start snapshot.
--- @param payload { m: table<string, integer> }
--- @param originSlot integer
local function onMoney(payload, originSlot)
    if originSlot ~= Network.hostSlot() or Network.isWorldHost() then
        return -- only the world host's tally is authoritative; ignore our own echo
    end
    if not runActive or not Network.isInRun() then
        return
    end
    local money = type(payload) == "table" and payload.m or nil
    if type(money) ~= "table" then
        return
    end
    -- only reconcile against OUR current floor's snapshot: a money packet that
    -- arrives after we've left that floor is stale and must be dropped, or its
    -- delta lands on the wrong floor's money
    if math.floor(tonumber(payload.s) or -2) ~= moneyBaselineSeq then
        return
    end
    for coopIndex = 1, 4 do
        local target = money[tostring(coopIndex)]
        local mine = moneyBaseline[coopIndex]
        if target ~= nil and mine ~= nil then
            target = math.floor(tonumber(target) or 0)
            local delta = target - mine
            if delta ~= 0 then
                -- apply the floor-start DIFFERENCE to the live money, so anything
                -- picked up since engage is preserved and both machines converge
                errorf("money desync: player %d floor-start %d vs host %d (%+d) — syncing",
                    coopIndex, mine, target, delta)
                if DesyncLog ~= nil then
                    DesyncLog.event("money reconcile: player %d floor-start %d vs host %d (%+d) — correcting live money",
                        coopIndex, mine, target, delta)
                end
                moneyBaseline[coopIndex] = target
                pcall(function()
                    local player = get_player(coopIndex, false)
                    if player ~= nil then
                        player.inventory.money = math.floor(player.inventory.money) + delta
                    else
                        local inv = get_local_state().items.player_inventory[coopIndex]
                        if inv ~= nil then inv.money = math.floor(inv.money) + delta end
                    end
                end)
            end
        end
    end
end

-- -------------------------------------------------------------- layer doors

-- Vanilla layer travel is a whole-party affair wired to the camera leader
-- (= co-op player 1 = the HOST on every machine): entering a back-layer door
-- runs a transition that drags everyone along. With camera-layer control
-- taken away from the engine (so each machine can render its own player's
-- layer), that transition half-runs into a broken state — the music cut out
-- for the whole lobby and nobody moved. So online, the vanilla enter is
-- swallowed entirely and the entering player (plus mount) is simply moved to
-- the paired door in the other layer. This runs inside the lockstep
-- simulation, so every machine performs the identical move on the identical
-- frame; the other players are not involved at all.

-- door types that travel between layers (the locked quest doors all lead to
-- back-layer rooms too); a missing constant on an older API just drops out
local LAYER_DOOR_TYPES = {}
local LOCKED_LAYER_DOOR = {} -- ENT_TYPE -> true: opens only with a key
local DROP_HELD_DOOR = nil   -- crawl-hole door: entering drops the held item
for _, doorName in ipairs({ "FLOOR_DOOR_LAYER", "FLOOR_DOOR_LAYER_DROP_HELD",
                            "FLOOR_DOOR_LOCKED", "FLOOR_DOOR_LOCKED_PEN" }) do
    pcall(function()
        local entType = ENT_TYPE[doorName]
        if type(entType) == "number" then
            LAYER_DOOR_TYPES[#LAYER_DOOR_TYPES + 1] = entType
            if doorName == "FLOOR_DOOR_LOCKED" or doorName == "FLOOR_DOOR_LOCKED_PEN" then
                LOCKED_LAYER_DOOR[entType] = true
            elseif doorName == "FLOOR_DOOR_LAYER_DROP_HELD" then
                DROP_HELD_DOOR = entType
            end
        end
    end)
end

-- The vanilla enter sequence is driven by the PLAYER's state machine reading
-- the DOOR button — not by the door entity — so no door-side hook can stop
-- it (every hook-based attempt still animated and bounced the traveler
-- back). But this mod owns the input pipeline: the lockstep gate injects
-- every input the simulation consumes. So the DOOR press is simply STRIPPED
-- from the injected input while a player stands at a layer door (the vanilla
-- sequence never begins at all), and the press books our own teleport
-- instead. Both the filter and the teleport are pure functions of synced
-- inputs and synced world state, so every machine does the identical thing
-- on the identical simulated frame.
local INPUT_DOOR = 0x20 -- INPUTS.DOOR
pcall(function()
    if type(INPUTS.DOOR) == "number" then
        INPUT_DOOR = INPUTS.DOOR
    end
end)

-- A layer door can be a SPECIAL transition rather than a plain same-tile layer
-- swap: the Black Market entrance and portals are FLOOR_DOOR_LAYER entities with
-- a co-located LOGICAL marker that makes the vanilla sequence load a whole
-- different area (THEME.BLACK_MARKET is its own level theme). Our interception
-- replaced that with an instant set_layer at the SAME coordinates, which dropped
-- the player into the empty back layer with the HUD still reading 2-2 — the
-- reported "black market took us to a completely empty backlayer". Those doors
-- must run the VANILLA sequence, so they are never intercepted.
-- Deliberately NOT including LOGICAL_DOOR / LOGICAL_DOOR_AMBIENT_SOUND: those sit
-- on ordinary doors too, and excluding them would switch normal layer doors back
-- to the broken-online vanilla transition.
local SPECIAL_DOOR_MARKERS = {}
for _, markerName in ipairs({ "LOGICAL_BLACKMARKET_DOOR", "LOGICAL_PORTAL" }) do
    pcall(function()
        local entType = ENT_TYPE[markerName]
        if type(entType) == "number" then
            SPECIAL_DOOR_MARKERS[#SPECIAL_DOOR_MARKERS + 1] = entType
        end
    end)
end

local layerDoorUids = {}      -- this level's layer doors
local doorHeldLast = {}       -- coopIndex -> DOOR button held on the previous frame
local pendingLayerTravel = {} -- traveler uid -> { at = time_level to flip, drop = leave held item }
local layerPollNoticeAt = 0   -- simulated-frame rate limit for the pending-booking notice
local layerCooldown = {}      -- traveler uid -> no re-travel before (time_level)
local LAYER_COOLDOWN_FRAMES = 30
-- How long a booked travel may wait for a transient fade before we give up on it.
-- Simulated frames, so every machine expires a booking on the same frame.
local LAYER_TRAVEL_STALE_FRAMES = 120
-- OFF-SWITCH for our in-level layer-door travel, by file (the console can't reach
-- our VM). Drop `mo_nolayerdoors.on` in the pack folder to make in-level layer
-- doors INERT — no set_layer, so co-op players can never be SPLIT across the two
-- layers at once. That split (one player in back while the camera on another
-- machine is in front) is the leading suspect for the random one-machine 1-4
-- crash: it is a state vanilla/2.5 never produces, and 2.5's per-entity update
-- runs in the sim tick exactly where the crash lands. This is the decisive test:
-- if the crash stops with this present, our layer doors are the trigger.
-- (Camp/world shortcut doors are unaffected — this is only the in-level layer
-- doors handled by filterGameplayInput.)
local layerDoorsOff = false
-- accept a couple of easy misspellings so a typo can't silently leave the test
-- running with the doors still ON
for _, name in ipairs({ "mo_nolayerdoors.on", "mo_nolayerdors.on", "mo_no_layer_doors.on" }) do
    pcall(function()
        local probe = io.open(PackPath(name), "r")
        if probe ~= nil then
            probe:close()
            layerDoorsOff = true
        end
    end)
end
-- surfaced in the desync-log header (see DesyncLog.init) so a capture always
-- states whether in-level layer doors were disabled for that session
module.layerDoorsDisabled = layerDoorsOff
-- Vanilla grants a brief invincibility window on a back-layer door transition;
-- we travel with Entity:set_layer, which does NOT emulate a door transition, so
-- those i-frames were lost. Re-grant this many frames on ANY layer travel.
-- (uint8 field, so keep well under 255.)
local BACK_LAYER_IFRAMES = 45
-- Local-only cosmetic screen fade over the instant layer swap (mimics vanilla's
-- door transition). Wall-clock ms via get_ms(); a render effect only.
local LAYER_FADE_MS = 740
local LAYER_FADE_MAX_ALPHA = 230
local layerFadeUntil = 0 -- get_ms() until which the local fade overlay draws
-- Suppress the engine's character-UNLOCK coffin during networked runs (see
-- suppressUnlockCoffins). RE-INSTALLED EVERY FLOOR: 2.5 calls force_custom_theme
-- per level, which swaps state.theme_info for a per-world CustomTheme, so a hook
-- memoized per theme id would silently sit on a stale object and stop suppressing.
--
-- THE ID BELONGS TO THE OBJECT, NOT TO THE SCRIPT. `ti:set_pre_coffin` returns a
-- VIRTUAL-HOOK id, counted by the engine's hook registry -- a completely separate
-- namespace from the CallbackIds `set_callback` hands out. Releasing it with
-- `clear_callback(id)` therefore did not touch the coffin hook at all: it looked
-- that number up in the SCRIPT-CALLBACK table and deleted whichever of OUR
-- registered callbacks happened to hold the same number. Silently, with no Lua
-- error, once per floor. The capture reads exactly like that -- `>> preLoadScreen`
-- stops appearing after 1-2, `>> postLevelGeneration` after 1-3, and by 1-4 the
-- ON.GAMEFRAME callback that executes layer travel is gone too, so every layer
-- door logged `layer-travel BOOKED` and nothing ever ran the flip: THE BACK LAYER
-- WAS UNREACHABLE. A virtual hook is released through the object it was installed
-- on (`ThemeInfo:clear_virtual`), so the object is kept alongside the id and
-- clear_callback is never used on one of these again.
local coffinHook = nil            -- { theme = ThemeInfo, id = hook id } while installed
local coffinReleaseWarned = false -- the "cannot release" notice: one line, not one per floor

local function scanLayerDoors()
    layerDoorUids = {}
    if #LAYER_DOOR_TYPES == 0 then
        return
    end
    pcall(function()
        layerDoorUids = get_entities_by(LAYER_DOOR_TYPES, MASK.FLOOR, LAYER.BOTH)
    end)
end

--- The layer door the player is standing at, if any. The range must cover
--- the engine's own door-interaction range with margin: any DOOR press that
--- the engine would accept but this check misses reaches the vanilla layer
--- transition — which is broken online (it half-runs, replays the enter
--- animation and drags the camera) — so err on the wide side.
--- @param player any
--- @return any?
--- Does this door lead somewhere else (black market / portal / an ExitDoor with
--- its own target) rather than simply swapping layers in place? Such a door must
--- keep its vanilla behaviour — see SPECIAL_DOOR_MARKERS.
--- @param door any
--- @return boolean
local function isSpecialTransitionDoor(door)
    -- an ExitDoor carrying an explicit world/level/theme target (`special_door`
    -- is documented as "use provided world/level/theme"). pcall'd because plain
    -- Doors have no such field.
    local special = false
    pcall(function() special = door.special_door == true end)
    if special then
        return true
    end
    if #SPECIAL_DOOR_MARKERS == 0 then
        return false
    end
    -- ...or a logical marker sitting on the same tile that turns entering this
    -- door into an area transition
    local marked = false
    pcall(function()
        local found = get_entities_at(SPECIAL_DOOR_MARKERS, MASK.LOGICAL,
            door.x, door.y, door.layer, 1.0)
        marked = found ~= nil and #found > 0
    end)
    return marked
end

local function overlappingLayerDoor(player)
    for _, uid in ipairs(layerDoorUids) do
        local door = get_entity(uid)
        if door ~= nil and door.layer == player.layer
            and math.abs(door.x - player.x) < 0.9
            and math.abs(door.y - player.y) < 0.8 then
            return door
        end
    end
    return nil
end

--- The door's twin on the given layer: layer doors come in same-tile pairs,
--- one entity per layer (mods often pair a locked front door with a PLAIN
--- layer door as its back side, so lock state must be read off the twin).
--- @param door any
--- @param layer integer
--- @return any?
local function doorTwin(door, layer)
    for _, uid in ipairs(layerDoorUids) do
        local other = get_entity(uid)
        if other ~= nil and other.layer == layer and other.uid ~= door.uid
            and math.abs(other.x - door.x) < 0.5
            and math.abs(other.y - door.y) < 0.5 then
            return other
        end
    end
    return nil
end

--- @param door any? # nil counts as not locked
--- @return boolean
local function doorIsLocked(door)
    if door == nil then
        return false
    end
    local lockedType = false
    pcall(function() lockedType = LOCKED_LAYER_DOOR[door.type.id] == true end)
    if not lockedType then
        return false
    end
    local unlocked = false
    pcall(function() unlocked = door.unlocked == true end)
    return not unlocked
end

local function unlockDoor(door)
    pcall(function() door.unlocked = true end)
    pcall(function() door:unlock(true) end)
end

--- Whether a layer door opens for this player, replicating the vanilla lock
--- rules our input interception bypasses: plain layer doors always open;
--- locked doors need the door already unlocked, a key in hand (consumed,
--- like vanilla) or the skeleton key pickup (kept). The keyhole is on the
--- FRONT: a door pair that is still locked NEVER opens from inside the back
--- layer, keys or not. Pure function of synced state, so every machine
--- decides identically.
--- @param door any
--- @param player any
--- @return boolean
local function layerDoorEnterable(door, player)
    if door.layer == LAYER.BACK then
        -- the lock guarding a pair may live on either entity (mods pair a
        -- locked front door with a plain back-side door): check both
        return not doorIsLocked(door)
            and not doorIsLocked(doorTwin(door, LAYER.FRONT))
    end
    if not doorIsLocked(door) then
        return true
    end
    local unlocked = false
    pcall(function()
        -- has_powerup checks the POWERUP type the pickup grants, not the pickup
        -- entity itself: picking up ITEM_PICKUP_SKELETON_KEY (541) adds the
        -- ITEM_POWERUP_SKELETON_KEY (562) powerup. Checking the pickup id never
        -- matched, so skeleton keys never opened layer doors.
        if player:has_powerup(ENT_TYPE.ITEM_POWERUP_SKELETON_KEY) then
            unlocked = true -- skeleton key opens everything and is kept
        end
    end)
    if not unlocked then
        pcall(function()
            local held = player.holding_uid >= 0
                and get_entity(player.holding_uid) or nil
            if held ~= nil and held.type.id == ENT_TYPE.ITEM_KEY then
                player:drop()
                held:destroy() -- the key is used up, like vanilla
                unlocked = true
            end
        end)
    end
    if unlocked then
        unlockDoor(door)
        -- open the whole pair, so the way back out opens with the front
        local twin = doorTwin(door, LAYER.BACK)
        if twin ~= nil then
            unlockDoor(twin)
        end
    end
    return unlocked
end

--- Are we on a live level rather than mid-fade or on another screen? Named so a
--- caller can protect the read without allocating a closure to do it.
--- @return boolean
local function readOnLevel()
    local st = get_local_state()
    return st.screen == SCREEN.LEVEL and st.loading == FADE.NONE
end

--- Called by the lockstep gate for every input it injects. Returns the
--- (possibly filtered) input; MUST never error and always return a number.
--- @param coopIndex integer
--- @param value integer
--- @return integer
function module.filterGameplayInput(coopIndex, value)
    if not runActive or #layerDoorUids == 0 then
        return value
    end
    -- IN-LEVEL ONLY. `layerDoorUids` is THIS LEVEL's door list and is rescanned
    -- only while a level is running (onGateEngaged, and pollLayerTravel's cadence,
    -- both of which require SCREEN.LEVEL). On a TRANSITION the gate still injects
    -- input and still called this, with the PREVIOUS level's uids -- and uids are
    -- recycled between screens, so `get_entity` on them returns whatever entity
    -- now holds that number.
    --
    -- On a transition the player stands right next to the exit door, so a recycled
    -- uid landing within a tile of them is entirely plausible. When it does, this
    -- STRIPS the DOOR press (believing it is a layer door) and books a travel that
    -- pollLayerTravel then discards for not being on a level -- so the press is
    -- simply eaten and the player cannot take the transition at all. A transition
    -- offering a SHORTCUT has more doors clustered around the players, which is
    -- exactly the case it was reported on.
    --
    -- The screen is part of the lockstep state, so this decision is identical on
    -- every machine and cannot itself desync.
    -- pcall(fn) rather than pcall(closure): this runs once per co-op index on every
    -- simulated frame. Same read, same guard, no allocation. (The larger protected
    -- body below is left exactly as it is -- that one is the input transformation.)
    local okLevel, onLevel = pcall(readOnLevel)
    if not okLevel or not onLevel then
        return value
    end
    local ok, filtered = pcall(function()
        local pressed = (value & INPUT_DOOR) ~= 0
        local wasHeld = doorHeldLast[coopIndex] == true
        doorHeldLast[coopIndex] = pressed
        if not pressed then
            return value
        end
        local player = get_player(coopIndex, false)
        if player == nil then
            return value
        end
        local now = get_local_state().time_level
        local uid = player.uid
        -- freshly traveled: mute DOOR outright for the cooldown window, so a
        -- held-over or re-buffered press can neither instantly re-enter the
        -- paired door nor leak through to the vanilla enter sequence
        if layerCooldown[uid] ~= nil and now < layerCooldown[uid] then
            return value & ~INPUT_DOOR
        end
        local door = overlappingLayerDoor(player)
        if door == nil then
            return value -- exit doors and everything else stay vanilla
        end
        if isSpecialTransitionDoor(door) then
            -- black market / portal / targeted exit door: it loads a different
            -- area, so the vanilla sequence must run untouched. Returning the
            -- input UNCHANGED (not muted) is the point — muting it here is what
            -- turned the black market into an empty back layer.
            if DesyncLog ~= nil and not wasHeld then
                DesyncLog.event("special transition door at %.1f,%.1f -> left to vanilla (not a layer swap)",
                    door.x, door.y)
            end
            return value
        end
        -- from here on the simulation NEVER sees the press: whether the door
        -- opens or refuses is decided here, because the vanilla layer
        -- transition is broken online whichever way it would resolve
        if layerDoorsOff then
            -- test/off mode: the door is INERT — still mute DOOR so the broken
            -- vanilla layer transition never runs, but book no travel, so no
            -- set_layer and no split-layer state (see layerDoorsOff).
            return value & ~INPUT_DOOR
        end
        if layerDoorEnterable(door, player) then
            -- a fresh press books the teleport; held-over presses stay muted
            if not wasHeld then
                layerCooldown[uid] = now + LAYER_COOLDOWN_FRAMES
                pendingLayerTravel[uid] = {
                    at = now + 1,
                    drop = DROP_HELD_DOOR ~= nil and door.type.id == DROP_HELD_DOOR,
                }
                -- Booking must be identical on every machine (synced input +
                -- synced world). If two logs differ HERE, the divergence is the
                -- booking; if they agree here but the layer ends up different, it
                -- is the execution (pollLayerTravel). Layer travel is the leading
                -- suspect for a same-world position desync (see the layer hash in
                -- inputSync.sendChecksum).
                if DesyncLog ~= nil then
                    DesyncLog.event("layer-travel BOOKED coop=%d door=%.1f,%.1f at time_level=%d",
                        coopIndex, door.x, door.y, now + 1)
                end
            end
        elseif not wasHeld and coopIndex == Network.myCoopIndex then
            -- local UI only, no sim effect
            if player.layer == LAYER.BACK then
                toast("It's locked from the other side!")
            else
                toast("It's locked — you need a key!")
            end
        end
        return value & ~INPUT_DOOR
    end)
    if ok and type(filtered) == "number" then
        return filtered
    end
    return value
end

-- The light aura players normally get in the back layer is created by the
-- vanilla layer transition — which our travel bypasses — so back layers were
-- pitch dark. Maintain the aura ourselves: every player standing in the back
-- layer gets a light that we MOVE to follow them each frame.
-- Done identically on every machine (pure function of synced player layers).
--
-- POSITION-BASED, never entity-attached (this is the v1.0.13 crash fix). An
-- entity-attached illumination (create_illumination(color,size,UID)) makes the
-- engine read the entity's position from `entity_uid` every RENDERED frame; that
-- is a native access violation the instant the entity is gone, and the engine
-- only renders a back-layer light when THAT machine's camera is in the back
-- layer — a different player per machine, which is exactly why the 1-4 crash was
-- random about who died. A position light (create_illumination(color,size,x,y),
-- entity_uid = -1) follows no entity: we set light_pos_x/light_pos_y ourselves,
-- so there is nothing for the engine to dangle on.
--
-- Illumination objects are still owned by the LEVEL: touching one after the
-- level starts tearing down is a native crash. So nothing here runs while a
-- load/unload fade is in flight, and every reference is dropped at
-- PRE_LEVEL_DESTRUCTION and level engage.
local playerLights = {} -- coopIndex -> Illumination (valid for current level only)
local LIGHT_SIZE = 15.0
-- default brightness gets washed out by the level's global illumination and
-- reads as pitch black (see Overlunky illumination.lua); 2.0 cut through it
-- but was overbright — 1.0 is plenty against the dark back layer
local LIGHT_BRIGHTNESS = 1.0

-- OFF-SWITCH for the back-layer lights, by file (the console can't reach our VM;
-- see desyncLog). Drop an empty `mo_nolights.on` in the pack folder to disable
-- them entirely. The lights are now position-based (see above) so this should no
-- longer be needed to avoid the crash — it stays as a definitive fallback test.
local backLayerLightsOff = false
pcall(function()
    local probe = io.open(PackPath("mo_nolights.on"), "r")
    if probe ~= nil then
        probe:close()
        backLayerLightsOff = true
    end
end)

--- The player's world position, unwrapping a mount/hold overlay (a rider's
--- x/y are relative to what it stands on).
--- @param player Entity
--- @return number, number
local function playerWorldPos(player)
    local px, py = player.x, player.y
    pcall(function()
        local abs = player:get_absolute_position()
        px, py = abs.x, abs.y
    end)
    return px, py
end

local function pollBackLayerLights()
    if backLayerLightsOff then
        return
    end
    local state = get_local_state()
    if not runActive or not Network.isInRun()
        or state.screen ~= SCREEN.LEVEL or state.loading ~= FADE.NONE then
        -- position lights own no entity, so just drop our refs; they fade out
        playerLights = {}
        return
    end
    local coopSlots = Network.coopSlots or {}
    for coopIndex = 1, 4 do
        -- SafePlayer, not get_player: this exact line threw "attempt to index a
        -- number value" because the engine handed back a NUMBER, which sails
        -- through the `~= nil` test below. Guarded HERE and in cameraTick only --
        -- routing every call site through the wrapper broke layer travel (17
        -- bookings, zero travels), so the blanket change was reverted.
        local player = coopSlots[coopIndex] ~= nil and SafePlayer(coopIndex, false) or nil
        if player ~= nil and player.layer == LAYER.BACK then
            local px, py = playerWorldPos(player)
            if playerLights[coopIndex] == nil then
                pcall(function()
                    local fresh = create_illumination(Color:white(), LIGHT_SIZE, px, py)
                    fresh.brightness = LIGHT_BRIGHTNESS
                    playerLights[coopIndex] = fresh
                end)
            end
            local current = playerLights[coopIndex]
            if current ~= nil then
                pcall(function()
                    -- move the light onto the player ourselves (no entity link)
                    current.light_pos_x = px
                    current.light_pos_y = py
                    current.layer = player.layer
                    current.brightness = LIGHT_BRIGHTNESS -- decays whenever a refresh is missed
                    refresh_illumination(current)
                end)
            end
        else
            playerLights[coopIndex] = nil -- left the back layer: drop, it fades
        end
    end
end

-- ------------------------------------------------- leaked-entity safety net
--
-- Spelunky 2.5 disposes of transient entities (the Dwelling lair boss's claws,
-- replaced pickups, cleared crates) with `Helpers2.sweepUnderTheRug`, which does:
--
--     move_entity(ent.uid, -1000, -1000, 0, 0)
--     ent:set_post_update_state_machine(function(e) clear_callback(); e:destroy() end)
--
-- i.e. park the entity a thousand tiles outside the level, then destroy it on its
-- NEXT state-machine update. An entity that far outside the level never gets one,
-- so the destroy never runs and EVERY swept entity leaks, permanently.
--
-- Standing on a lair boss makes that visible: the claws it throws are swept on
-- every hit, thousands pile up out there, the run degrades from 60 to ~45
-- simulated fps (the "known 2.5 lag"), and eventually the process dies inside the
-- engine's own update. A capture shows exactly that -- `IN engineUpdate` in
-- crash_frame.txt, which by construction means the crash was NOT in Modded
-- Online's code -- after the sim rate had decayed for two minutes.
--
-- We cannot repair 2.5's helper from here, so we finish the job it started.
-- Anything parked out there is already logically dead: 2.5 asked for it to be
-- destroyed and the request was simply never delivered.
--
-- SAFETY, in order of importance:
--   * players and mounts are never touched (destroying a co-op player is a native
--     access violation -- see the notes on the departed-player path);
--   * only entities at the sentinel X are eligible. The level spans x 0..~86, so
--     anything at -900 or beyond is unambiguously parked, not merely off-screen;
--   * an entity must have been parked for GRACE frames before we touch it, so we
--     can never race a destroy that 2.5 is about to perform itself;
--   * it runs on GAMEFRAME on a fixed simulated-frame cadence and destroys in
--     sorted uid order, so every machine destroys the identical set in the
--     identical order on the identical frame. Freed uids are recycled by the
--     engine, so an order that differed between machines would fork later spawns.
local PARKED_X = -900           -- 2.5 parks at -1000; the level starts at 0
-- Simulated frames between sweeps. Was 30 (twice a second), which measured as
-- the single most expensive thing Modded Online does: the scan walks every
-- MONSTER|ITEM|ACTIVEFLOOR|DECORATION|FX|EXPLOSION|ROPE entity on the floor,
-- calling get_entity and a pcall for each, and it allocates a uid list plus two
-- tables every time. A capture showed this callback taking 25-34ms in a single
-- frame -- twice a 60fps budget -- while destroying nothing all session.
--
-- 150 costs NO destruction latency. An entity is destroyed at the first sweep
-- where `now - since >= SWEEP_GRACE` (300), and both `since` and `now` are
-- multiples of this interval: first seen at sweep 150, destroyed at sweep 450,
-- exactly 300 frames later, which is what 30 gave too. It only changes how long
-- an entity can sit unnoticed BEFORE its first sighting -- at most 2.5s, against
-- a grace period deliberately set to 5s.
--
-- LOCKSTEP-CRITICAL: every machine must use the same value or they destroy
-- different sets on different frames. It is fixed in the build, and the
-- compatibility signature keeps mismatched builds out of the same room.
local SWEEP_EVERY = 150
-- Parked this long before we touch it. Deliberately generous (5 s): the entity is
-- inert out there, so waiting costs nothing but memory, while destroying one that
-- something still holds a pointer to is a native access violation we cannot catch.
-- A leak that only matters over a minutes-long boss fight drains fine at this rate.
local SWEEP_GRACE = 300
-- What 2.5 actually sweeps: ITEM_CRABMAN_CLAW and crates/pickups (ITEM), boss
-- rubble and DECORATION_GUTS (DECORATION), replaced monsters (MONSTER), plus
-- generic `sweepUnderTheRug(ent)` calls in entityContext/hookContext that can be
-- any of those. PLAYER and MOUNT are deliberately absent — destroying a co-op
-- player is a native access violation, and a mount can be carrying one. LOGICAL,
-- FLOOR and BG are absent too: those are the engine's own furniture, and nothing
-- 2.5 sweeps is one.
local SWEEP_MASKS = MASK.MONSTER | MASK.ITEM | MASK.ACTIVEFLOOR
    | MASK.DECORATION | MASK.FX | MASK.EXPLOSION | MASK.ROPE
local parkedSince = {}          -- uid -> time_level it was first seen parked
-- The last simulated frame actually swept. POST_UPDATE fires per RENDERED frame,
-- so while the lockstep gate holds the simulation still, `state.time_level` stops
-- advancing -- and if it stops on a multiple of SWEEP_EVERY the scan below runs
-- again on every rendered frame of the stall. Harmless (the second scan of a
-- frame sees the same entities and a destroyed uid reads back nil) but it is
-- most of the work in the worst frames we have measured, and a stall is exactly
-- when the game can least afford it.
local lastSweptFrame = -1
local sweptTotal = 0            -- this floor, for the log
local sweepNoticeAt = 0
-- OFF-SWITCH by file, matching the other engine-facing behaviours: drop an empty
-- `mo_nosweep.on` in the pack folder to leave 2.5's leak alone.
local sweepOff = false
pcall(function()
    local probe = io.open(PackPath("mo_nosweep.on"), "r")
    if probe ~= nil then
        probe:close()
        sweepOff = true
    end
end)
module.sweepDisabled = sweepOff

--- Read one field through a pcall without allocating a closure to do it. A freed
--- uid can still come back from get_entities_by and touching a dead entity is a
--- native access violation, so the read must be protected -- but it does not have
--- to allocate, and the sweep below does it for every entity on the floor.
--- @param e Entity
--- @return number
local function readEntityX(e)
    return e.x
end

local function pollSweepParked()
    if sweepOff or not runActive or not Network.isInRun() then
        return
    end
    local state = get_local_state()
    if state.screen ~= SCREEN.LEVEL or state.loading ~= FADE.NONE then
        return
    end
    local now = state.time_level
    if now % SWEEP_EVERY ~= 0 or now == lastSweptFrame then
        return
    end
    lastSweptFrame = now
    local parkedNow, victims = {}, {}
    pcall(function()
        for _, uid in ipairs(get_entities_by(0, SWEEP_MASKS, LAYER.BOTH)) do
            local e = get_entity(uid)
            local x = nil
            if e ~= nil then
                local okX, ex = pcall(readEntityX, e)
                if okX then
                    x = ex
                end
            end
            if x ~= nil and x <= PARKED_X then
                local since = parkedSince[uid] or now
                parkedNow[uid] = since
                if now - since >= SWEEP_GRACE then
                    victims[#victims + 1] = uid
                end
            end
        end
    end)
    -- forget uids that are no longer parked (2.5 got to them, or the uid was
    -- recycled onto a live entity), so this table cannot grow without bound
    parkedSince = parkedNow
    if #victims == 0 then
        return
    end
    table.sort(victims) -- identical destruction order on every machine
    local destroyed = 0
    for _, uid in ipairs(victims) do
        parkedSince[uid] = nil
        local e = get_entity(uid)
        if e ~= nil then
            local ok = pcall(function() e:destroy() end)
            if ok then
                destroyed = destroyed + 1
            end
        end
    end
    local firstOfFloor = sweptTotal == 0
    sweptTotal = sweptTotal + destroyed
    -- The FIRST sweep of every floor is always reported, then a slow cadence. The
    -- first one is what makes a capture conclusive: it is the difference between
    -- "this never touched anything" and "we have no idea", and a crash report
    -- needs to be able to tell those apart.
    if DesyncLog ~= nil and destroyed > 0 and (firstOfFloor or now >= sweepNoticeAt) then
        sweepNoticeAt = now + 600
        DesyncLog.event("swept %d leaked entity(s) parked outside the level (%d this floor, at frame %d)",
            destroyed, sweptTotal, now)
    end
end

--- The aura decays engine-side per RENDERED frame, but pollBackLayerLights
--- only runs on simulated frames — during a lockstep stall the sim holds
--- still while rendering continues, and the light would fade to black.
--- Refresh at render rate too; brightness is cosmetic, so this cannot
--- desync anything.
local function refreshBackLayerLightsRender()
    if backLayerLightsOff or next(playerLights) == nil then
        return
    end
    local state = get_local_state()
    if state.screen ~= SCREEN.LEVEL or state.loading ~= FADE.NONE then
        return
    end
    for _, light in pairs(playerLights) do
        pcall(refresh_illumination, light)
    end
end

--- Performs the scheduled flips. Runs on GAMEFRAME (= once per simulated
--- frame, lockstep-identical everywhere); uids are processed in sorted
--- order so multiple simultaneous travelers flip in the same order on
--- every machine.
local function pollLayerTravel()
    local state = get_local_state()
    -- Reported BEFORE every guard, so the three remaining explanations become
    -- distinguishable instead of all looking like silence:
    --   no line at all  -> this poll is not running (the GAMEFRAME callback is not
    --                      reaching us at all)
    --   line, pending=0 -> the poll runs but the bookings are being wiped between
    --                      the press and this frame
    --   line, pending>0 -> the poll runs and holds the booking; the printed guard
    --                      values then say which test refuses to execute it
    -- Rate-limited on SIMULATED frames (once a second), so it cannot spam and it
    -- costs nothing on machines that never touch a layer door.
    if DesyncLog ~= nil and state.time_level >= layerPollNoticeAt then
        layerPollNoticeAt = state.time_level + 60
        local pending, soonest = 0, nil
        for _, t in pairs(pendingLayerTravel) do
            pending = pending + 1
            if soonest == nil or t.at < soonest then
                soonest = t.at
            end
        end
        if pending > 0 then
            DesyncLog.event(
                "layer-travel POLL pending=%d now=%d soonest_at=%s loading=%s screen=%s inRun=%s doors=%d",
                pending, state.time_level, tostring(soonest),
                tostring(state.loading), tostring(state.screen),
                tostring(Network.isInRun()), #layerDoorUids)
        end
    end
    -- Only a level that is genuinely OVER may discard bookings. The old form also
    -- discarded them whenever state.loading was mid-fade, and it did so SILENTLY --
    -- so a booking made one frame before any fade was destroyed before the next
    -- frame could execute it. That is exactly the "cannot get into the back layer
    -- at all" report: the log fills with BOOKED and never shows one ATTEMPT, with
    -- no error, because every discard path was mute. A transient fade now DEFERS
    -- (see below) instead of cancelling, and every discard says why.
    if not Network.isInRun() or state.screen ~= SCREEN.LEVEL then
        if next(pendingLayerTravel) ~= nil then
            local n = 0
            for _ in pairs(pendingLayerTravel) do
                n = n + 1
            end
            if DesyncLog ~= nil then
                DesyncLog.event("layer-travel DROPPED %d booking(s): level over (inRun=%s screen=%s loading=%s)",
                    n, tostring(Network.isInRun()), tostring(state.screen),
                    tostring(state.loading))
            end
            pendingLayerTravel = {}
        end
        return
    end
    -- mods spawn layer doors mid-level (conditional quest doors): rescan on
    -- a fixed simulated-time cadence, identical on every machine
    if state.time_level % 60 == 0 then
        scanLayerDoors()
    end
    if next(pendingLayerTravel) == nil then
        return
    end
    local now = state.time_level
    if state.loading ~= FADE.NONE then
        return -- transient fade: WAIT for it, do not cancel the traveller
    end
    local uids = {}
    for uid in pairs(pendingLayerTravel) do
        uids[#uids + 1] = uid
    end
    table.sort(uids)
    for _, uid in ipairs(uids) do
        local travel = pendingLayerTravel[uid]
        if now > travel.at + LAYER_TRAVEL_STALE_FRAMES then
            -- waited out a fade far longer than any transition takes: the press no
            -- longer belongs to this moment. Bounded by simulated frames, so every
            -- machine expires it together.
            pendingLayerTravel[uid] = nil
            if DesyncLog ~= nil then
                DesyncLog.event("layer-travel DROPPED: booking for %d went stale (at=%d now=%d)",
                    uid, travel.at, now)
            end
        elseif now >= travel.at then
            pendingLayerTravel[uid] = nil
            local who = get_entity(uid)
            if who == nil and DesyncLog ~= nil then
                DesyncLog.event("layer-travel SKIPPED: traveler entity %d is gone", uid)
            end
            if who ~= nil then
                -- logged BEFORE the flip, so a failure below is visible as an
                -- ATTEMPT with no EXEC rather than silence
                if DesyncLog ~= nil then
                    DesyncLog.event("layer-travel ATTEMPT uid-local at time_level=%d", now)
                end
                -- SafeCall, not a bare pcall: a bare pcall swallowed the error and
                -- produced 13 BOOKED lines with no EXEC and no explanation, which
                -- cost a whole debugging round. SafeCall reports the message AND a
                -- traceback into this same log.
                SafeCall("eventSync:layerTravelExec", function()
                    -- the crawl-hole door forces you to leave held items
                    -- behind, exactly like its vanilla enter does
                    if travel.drop and who.holding_uid >= 0 then
                        who:drop()
                    end
                    local fromLayer = who.layer
                    local target = who.layer == LAYER.FRONT and LAYER.BACK or LAYER.FRONT
                    -- RIDING A MOUNT: move the MOUNT and let the attachment carry
                    -- the rider — never move both. `set_layer` moves an entity
                    -- "with all it's items", and a rider IS attached to the mount
                    -- (the player's `overlay` is the mount), so moving the mount
                    -- already brings the player. Calling set_layer on the rider
                    -- afterwards was a SECOND layer-move on an already-moved,
                    -- ATTACHED entity, which corrupts the rider/mount linkage. That
                    -- corruption OUTLIVES the floor (a mount is re-created on the
                    -- next floor from the synced inventory, `mount_type`), which is
                    -- why the crash landed a floor LATER — on 1-4, with both
                    -- players back in the FRONT layer and riding rockdogs, long
                    -- after the 1-3 travel that actually broke it.
                    local mount = nil
                    pcall(function()
                        local ov = who.overlay
                        if ov ~= nil and (ov.type.search_flags & MASK.MOUNT) ~= 0 then
                            mount = ov
                        end
                    end)
                    -- Move the mount first, best-effort and INDIVIDUALLY guarded:
                    -- if anything about the mount fails it must not abort the whole
                    -- flip and strand the player in the old layer (a bare pcall
                    -- around the entire block did exactly that — 13 bookings, zero
                    -- travels, and no way to enter the back layer at all).
                    if mount ~= nil then
                        pcall(function() mount:set_layer(target) end)
                    end
                    -- Then move the player only if they did NOT already come along
                    -- with the mount: exactly one layer-move per entity, never two
                    -- (moving an already-moved attached rider corrupts the linkage).
                    -- Distinguish "the read said no" from "the read FAILED". The old
                    -- form left `moved` false in BOTH cases, so an unreadable entity
                    -- fell through to the move branch -- calling set_layer on the very
                    -- entity we had just failed to read, which is the riskiest possible
                    -- response to that failure and cannot be caught (a native fault in
                    -- set_layer takes the process down with no Lua error). Skipping
                    -- instead can at worst fork the layers, which shows up as a logged
                    -- desync rather than a crash.
                    local readOk, alreadyThere = pcall(function() return who.layer == target end)
                    if not readOk then
                        if DesyncLog ~= nil then
                            DesyncLog.event("layer-travel SKIPPED exec: player layer unreadable")
                        end
                    elseif not alreadyThere then
                        who:set_layer(target) -- on foot: brings held items along
                    end
                    -- Executed identically on every machine (same simulated
                    -- frame, same from/to). A differing line between two logs
                    -- pinpoints the exact frame the layers forked.
                    if DesyncLog ~= nil then
                        DesyncLog.event("layer-travel EXEC uid-local layer %s->%s at time_level=%d pos=%.1f,%.1f mounted=%s",
                            tostring(fromLayer), tostring(target), now, who.x, who.y,
                            mount ~= nil and "yes" or "no")
                    end
                    -- Restore vanilla's layer-transition i-frames (set_layer skips
                    -- the door transition that normally grants them). Vanilla gives
                    -- them ENTERING AND LEAVING a back layer, so grant on BOTH
                    -- directions (not just target == LAYER.BACK). Runs on GAMEFRAME
                    -- and the timer is a sim field the engine counts down in
                    -- lockstep, so grant + countdown stay deterministic. math.max so
                    -- we never shorten i-frames the traveler already has.
                    who.invincibility_frames_timer =
                        math.max(who.invincibility_frames_timer or 0, BACK_LAYER_IFRAMES)
                    -- Local-only cosmetic screen fade over the instant layer swap,
                    -- to mimic vanilla's door transition. Only for OUR OWN spelunker
                    -- (the camera follows it); purely a render effect, never touches
                    -- the simulation, so it is safe to key off the local machine.
                    if Network.myCoopIndex ~= nil then
                        local mine = get_player(Network.myCoopIndex, false)
                        if mine ~= nil and mine.uid == uid then
                            layerFadeUntil = get_ms() + LAYER_FADE_MS
                        end
                    end
                end)
            end
        end
    end
end

--- Local cosmetic layer-travel fade alpha (0-255) for menuUI to draw a black
--- fullscreen overlay over the instant layer swap. Purely a render effect keyed
--- to wall-clock ms; never affects the simulation.
--- @return integer
function module.layerFadeAlpha()
    local remaining = layerFadeUntil - get_ms()
    if remaining <= 0 then
        return 0
    end
    if remaining > LAYER_FADE_MS then
        remaining = LAYER_FADE_MS
    end
    return math.floor(LAYER_FADE_MAX_ALPHA * remaining / LAYER_FADE_MS)
end

--- A player folded back into a run comes in with NO bombs and NO ropes, keeping
--- the health they left with.
---
--- Their spelunker is stood still rather than removed while they are away, so the
--- host's snapshot of it still holds the full kit they walked away with -- and
--- handing that straight back let a player bank consumables by leaving and
--- rejoining. Health is already right in the snapshot for the same reason: the
--- idle body keeps it.
---
--- Applied to the SNAPSHOT before it is written, so every machine performs the
--- identical edit to the identical payload. It cannot be decided locally: the
--- returning player's own machine cleared its departed-player state when its run
--- ended, so it does not know it was the one who left -- the server names them.
--- @param joinSlots integer[]? # network slots being folded in, from the server
local function applyRejoinKit(joinSlots)
    if type(joinSlots) ~= "table" or pendingStateSync == nil then
        return
    end
    local byNetSlot = {}
    for coopIndex, netSlot in pairs(Network.coopSlots or {}) do
        byNetSlot[netSlot] = coopIndex
    end
    for _, netSlot in ipairs(joinSlots) do
        local coopIndex = byNetSlot[math.floor(tonumber(netSlot) or 0)]
        local entry = coopIndex ~= nil and (pendingStateSync.pl or {})[tostring(coopIndex)] or nil
        if entry ~= nil then
            entry.bo = 0
            entry.ro = 0
            if DesyncLog ~= nil then
                DesyncLog.event("rejoin kit: slot %s (coop %d) folded in with hp=%s, 0 bombs, 0 ropes",
                    tostring(netSlot), coopIndex, tostring(entry.hp))
            end
        end
    end
end

-- -------------------------------------------------------------- run start

--- @param payload { seed: integer[], slots: table<string, string>, chars: table<string, integer>, delay: integer? }
local function onRunStart(payload)
    Network.playerNames = payload.slots or {}
    local hostSlot = nil
    for slotStr in pairs(Network.playerNames) do
        local slot = math.floor(tonumber(slotStr) or 99)
        if hostSlot == nil or slot < hostSlot then
            hostSlot = slot
        end
    end
    Network.runHostSlot = hostSlot or 1
    Network.phase = Network.PHASE.INGAME
    Network.roomStarted = true
    runActive = true
    lobbyRestartAttempts = 0 -- a run started: the bounded retries above are spent
    levelOrdinal = 0
    hostSeeds = {}
    -- clear any stale mid-run-join state from the previous run: a run_start
    -- (restart included) is a clean slate. The join branch below re-arms joinInit
    -- when THIS run_start is itself a join. Without this a leftover joinPending
    -- fired a spurious join warp at the first transition after a restart.
    joinPending = false
    joinInit = false
    currentFloorSeed = nil
    currentFloor = nil
    nextFloorSeed = nil
    pendingWarp = nil
    pendingStateSync = nil
    lastResyncMs = 0
    digestResyncStreak = 0
    digestResyncTimes = {}
    digestGaveUp = false
    awaitingRestartUntil = 0
    floorSeedForOrd = nil
    publishedSeedOrd = nil
    restartNonce = nil
    restartVotes = {}
    restartVoteDeadline = nil
    restartVoted = false
    restartSuppressUntil = 0
    runEndedNoticeMs = nil
    decideLeaveAtMs = nil
    -- Re-arm per-floor installation for this run; suppressUnlockCoffins re-adds
    -- the hook at each floor's PRE_LEVEL_GENERATION. The reference is DROPPED, not
    -- released: the previous run's ThemeInfo is torn down with its level, and
    -- calling a method on a freed engine object is a native access violation that
    -- no pcall can catch. Leaving a hook behind on an object that may still be
    -- alive is harmless -- its body re-checks isInRun, and in a fresh networked run
    -- suppressing the unlock coffin is what we want anyway.
    coffinHook = nil
    pendingRunSeed = payload.seed
    rosterChars = payload.chars or {}
    set_adventure_seed(payload.seed[1], payload.seed[2])

    InputSync.beginSession(Network.playerNames, payload.delay)
    module.enforceRoster()
    -- A MID-RUN JOIN carries the party's current floor: resync everyone THERE
    -- (host seed) with the roster grown to the readied late-joiner, keeping
    -- progress instead of resetting to 1-1. levelOrdinal is the floor's (not 0),
    -- so the wipe-restart kit reset is skipped and the party's inventory carries;
    -- joinInit gives the newly-added spelunker a living body next generation.
    if type(payload.floor) == "table" then
        joinPending = false
        joinInit = true
        levelOrdinal = math.floor(tonumber(payload.ord) or 0)
        -- the host's snapshot rides along so this floor generates identically
        -- (level_count etc.) — without it the joiner would use level_count 0
        pendingStateSync = type(payload.st) == "table" and payload.st or nil
            applyRejoinKit(payload.join)
        toast("A player is joining — resyncing this floor!")
        moWarp(math.floor(tonumber(payload.floor.w) or 1),
            math.floor(tonumber(payload.floor.l) or 1),
            math.floor(tonumber(payload.floor.t) or THEME.DWELLING))
    else
        -- GUARANTEED fresh-run reset. The load callbacks it normally runs from
        -- (PRE_LOAD_SCREEN / PRE_LEVEL_GENERATION) DO NOT FIRE on many restarts —
        -- a capture showed the reset running on only ONE of six runs. When it is
        -- skipped, level_count/time_total keep the DEAD run's values and, crucially,
        -- differ between machines (10757 vs 10763). The determinism shim seeds
        -- math.random per simulated frame from time_total, so unequal clocks give
        -- 2.5's generator a different random stream on each machine -> the SAME
        -- adventure seed builds DIFFERENT worlds (observed: identical seed + floor
        -- id, divergent gen[post] prng and a wholly different 1-1). Doing it here,
        -- on the ordered run_start event, is the one point guaranteed to run on
        -- every restart. Idempotent and gated to levelOrdinal == 0, so the later
        -- call sites remain harmless; JOINs never reach this branch and keep their
        -- host-synced progress.
        applyFreshRunReset()
        toast("Here we go — good luck!")
        -- a camp SHORTCUT start rides along on run_start, so every machine warps
        -- to the same world; absent (or the main exit) means the usual 1-1
        local startAt = payload.start
        if type(startAt) == "table" and startAt[1] ~= nil then
            moWarp(math.floor(tonumber(startAt[1]) or 1),
                math.floor(tonumber(startAt[2]) or 1),
                math.floor(tonumber(startAt[3]) or THEME.DWELLING))
        else
            moWarp(1, 1, THEME.DWELLING)
        end
    end
end

--- Apply the agreed roster: player count, active slots and the characters
--- everyone picked. Identical on every machine. Both the character AND its
--- texture are set: the engine derives UI (off-screen cursors, hearts) from
--- the character field but skins the spawned spelunker from the texture
--- field — setting only one leaves the other showing the wrong character.
function module.enforceRoster()
    if rosterChars == nil then
        return -- pre-run: the local character select owns player_select
    end
    local levelState = get_local_state()
    local count = InputSync.playerCount()
    levelState.items.player_count = count
    local coopSlots = Network.coopSlots or {}
    for coopIndex = 1, 4 do
        local select = levelState.items.player_select[coopIndex]
        if select ~= nil then
            select.activated = coopIndex <= count
            local netSlot = coopSlots[coopIndex]
            local char = netSlot ~= nil and rosterChars[tostring(netSlot)] or nil
            if select.activated and char ~= nil then
                select.character = math.floor(char)
                pcall(function()
                    select.texture = get_type(math.floor(char)).texture
                end)
            end
        end
    end
end

--- Force the adventure seed for the level about to generate. Until the run's
--- (or a resync warp's) first level engages, that's the exact agreed seed
--- (`pendingRunSeed`); after that, non-host clients rebase onto the world
--- host's seed for this level ordinal (the host itself is authoritative and
--- leaves its own seed alone). Missing host seed for this ordinal (packet not
--- here yet) => leave the local seed; the desync self-corrects a floor later.
local function enforceLevelSeed()
    if pendingRunSeed ~= nil then
        set_adventure_seed(pendingRunSeed[1], pendingRunSeed[2])
    elseif not Network.isWorldHost() then
        local seed = hostSeeds[levelOrdinal]
        if seed ~= nil then
            set_adventure_seed(seed[1], seed[2])
        elseif DesyncLog ~= nil then
            -- The host's authoritative seed for this floor has NOT arrived yet, so
            -- we are about to generate it from our own (un-rebased) seed — a
            -- guaranteed world divergence. This is the fingerprint of a stalled
            -- reliable channel (see the checksum note in inputSync). We can't
            -- pause a load in flight, so the floor digest check will catch the
            -- mismatch and drive a resync; this line makes the cause unambiguous
            -- in a capture instead of looking like a random 2.5 non-determinism.
            -- Not necessarily a problem any more: the host now publishes this
            -- floor's seed at its own PRE_LEVEL_GENERATION, which can land after
            -- we start loading. Both machines evolve the adventure seed
            -- identically, so our own value is normally already correct — this is
            -- informational, and only matters if the floor digest also differs.
            DesyncLog.event("no host seed yet for ordinal %d -> using our own evolved seed", levelOrdinal)
        end
    end
end

--- Broadcast the world host's adventure seed for the floor with `ord`, i.e. the
--- seed every non-host must generate that floor from. Only the world host
--- publishes, and only once per ordinal, so it is safe to call from more than one
--- place.
---
--- It IS called from more than one place, deliberately. Publishing only from
--- post-generation turned out to be unreliable: `onPostLevelGeneration` sits
--- behind a screen check and a restart-pending check, and a real capture had the
--- host bail out of it for THREE WHOLE RUNS in a row (no `gen[post]` line for any
--- floor of runs 2-4 of that session). With nothing published, every non-host
--- generated floor 2 onward from its own un-rebased seed — a byte-different world
--- on every run after the first in a session. `onGateEngaged` is the one per-floor
--- moment guaranteed to run on every machine on every run (it is what advances the
--- lockstep ordinal at all), so it is the belt to post-generation's braces.
--- @param ord integer
local function publishLevelSeed(ord)
    -- Instrumented because the logs could not tell two very different failures
    -- apart: a host that never publishes, and a host that publishes into a
    -- reliable stream the peer never drains. The peer's "no host seed yet for
    -- ordinal N" looks identical either way.
    if not Network.isWorldHost() or type(ord) ~= "number" or ord < 0 then
        return
    end
    if publishedSeedOrd == ord then
        if DesyncLog ~= nil then
            DesyncLog.event("levelseed ord=%s SKIPPED (already published)", tostring(ord))
        end
        return -- already sent for this floor
    end
    local seed = nil
    if floorSeedForOrd ~= nil and floorSeedForOrd.ord == ord then
        seed = floorSeedForOrd.seed
    else
        -- post-generation never captured this floor's seed (its guards bailed).
        -- Read the live seed: at gate-engage the engine still holds the state left
        -- by this floor's generation, which is exactly what generates the next
        -- one. Log it, because a fallback here means post-generation is being
        -- skipped and that is worth knowing.
        local ok, a, b = pcall(get_adventure_seed, false)
        if not ok or a == nil or b == nil then
            return
        end
        seed = { math.floor(a), math.floor(b) }
        if DesyncLog ~= nil then
            DesyncLog.event("levelseed ord=%d published from a LIVE read (post-gen did not capture it)", ord)
        end
    end
    publishedSeedOrd = ord
    -- the FULL evolved seed, not the 31-bit fingerprint the world check uses:
    -- it has to reproduce the host's world exactly when applied
    Network.sendEvent("levelseed", { n = ord, a = seed[1], b = seed[2] })
    if DesyncLog ~= nil then
        DesyncLog.event("levelseed ord=%d SENT", ord)
    end
end

--- The lockstep gate engaged a fresh screen: the synchronized moment every
--- machine reaches at the identical simulation state. A LEVEL engagement is
--- what "we are now playing floor N" means, so the ordinal counts here (not
--- at generation time, which can run twice on one machine during overlapping
--- loads), and the forced run seed has served its purpose.
--- @param screenKind integer
function module.onGateEngaged(screenKind)
    if not runActive then
        return
    end
    if screenKind == SCREEN.LEVEL then
        pendingRunSeed = nil
        pendingStateSync = nil -- consumed by this level's player rebuild
            levelOrdinal = levelOrdinal + 1
        -- Deliberately does NOT publish a seed. At gate-engage the adventure seed
        -- is still the one that generated the floor just engaged, NOT the next
        -- floor's, so publishing here (as this used to) broadcast a stale value
        -- under the wrong ordinal. Publishing now happens once, at
        -- PRE_LEVEL_GENERATION, where the value is provably correct.
        pendingLayerTravel = {} -- uids recycle between levels
        layerCooldown = {}
        doorHeldLast = {}
        parkedSince = {}        -- same reason: a new level reuses the uid space
        sweptTotal = 0
        -- MUST be reset with them. time_level restarts at 0 every floor but this
        -- did not, so a leftover deadline from a long previous floor silenced the
        -- sweep notice for the whole start of the next one -- and a capture that
        -- says nothing was swept then means nothing at all. That cost a wrong
        -- "the sweep wasn't running" call on a real crash report.
        sweepNoticeAt = 0
        playerLights = {} -- Illumination objects die with the previous level
        scanLayerDoors()
        syncFloorMoney() -- snapshot + (host) broadcast money for per-floor reconcile
    else
        -- Leaving a level (a transition, the death screen): the door list belongs
        -- to the level we just left and nothing rescans it off-level, so drop it
        -- rather than leave stale uids lying around for filterGameplayInput to
        -- resolve against recycled entities. Belt to that function's own screen
        -- guard: with the list empty it short-circuits on its very first line.
        layerDoorUids = {}
        pendingLayerTravel = {}
        doorHeldLast = {}
    end
end

--- The run's FIRST level is starting: scrub every trace of the PREVIOUS run out
--- of the state the engine carries across a warp.
---
--- MUST NOT be hooked to level GENERATION. A capture proved why: on a restart
--- after a whole-party wipe, `ON.PRE_LEVEL_GENERATION` DOES NOT FIRE AT ALL (the
--- breadcrumbs show preLoadScreen, then straight to the floor engaging — no
--- preLevelGeneration, no postLevelGeneration). So this reset never ran, every
--- roster slot kept `health = 0` from the wipe, and the engine spawned NOBODY:
--- three players with `hp=0 pos=(no entity)`, a camera with nothing to follow,
--- and an instant death. It also broke 2.5, whose POST_LOAD_SCREEN hook does
--- `get_position(players[1].uid)` and threw `attempt to index a nil value`
--- because `players[1]` did not exist. The leftover run progress in the same
--- block (level_count=3, time_total=9512, quest_flags=0x10010 on a "fresh" 1-1)
--- is a determinism hazard on top of that.
---
--- So it runs from PRE_LOAD_SCREEN, which always fires and is early enough that
--- health is right BEFORE the engine rebuilds the party. One-shot per run, so
--- calling it from more than one hook is safe.
function applyFreshRunReset()
    -- Gated on levelOrdinal == 0 ONLY: the window between run_start and the first
    -- floor ENGAGING (onGateEngaged increments the ordinal), during which no
    -- gameplay/pickups happen, so re-applying is always safe. It used to be
    -- one-shot (freshResetDone), but a restart fires PRE_LOAD_SCREEN /
    -- PRE_LEVEL_GENERATION more than once and the engine can re-init the spawn
    -- inventory AFTER our single reset ran, leaving players as 0-HP COFFINS that
    -- die instantly (the reported "restart kills everyone; next run is fine").
    -- Now it re-applies at every such callback until the floor engages, so the
    -- LAST write before the spawn is always health=4.
    if levelOrdinal ~= 0 then
        return
    end
    local ok, inv = pcall(function() return get_local_state().items.player_inventory end)
    if DesyncLog ~= nil then
        local hp = "?"
        pcall(function()
            if inv ~= nil then
                hp = string.format("%s/%s/%s/%s",
                    tostring(inv[1] and inv[1].health), tostring(inv[2] and inv[2].health),
                    tostring(inv[3] and inv[3].health), tostring(inv[4] and inv[4].health))
            end
        end)
        DesyncLog.event("applyFreshRunReset count=%d inv_hp_before=%s",
            InputSync.playerCount(), hp)
    end
    if ok and inv ~= nil then
        -- the party's starting kit is 4 bombs + 4 ropes TOTAL, split evenly
        -- across the players (any leftover goes to the earliest slots): e.g.
        -- 2 players -> 2 each, 4 players -> 1 each, 3 players -> 2/1/1.
        local count = InputSync.playerCount()
        if count < 1 then count = 1 end
        local base = math.floor(4 / count)
        local rem = 4 - base * count
        for i = 1, 4 do
            pcall(function()
                local pi = inv[i]
                -- Reset EVERY player in the roster to the clean fresh-run kit,
                -- not just dead ones. A MID-RUN restart leaves the players ALIVE
                -- (health>0), and a health<=0 gate skipped them so they kept an
                -- uneven pre-restart kit (one had all 4 bombs, another none).
                -- Keyed on the roster index i (identical on every machine), so
                -- the even split can't desync.
                if pi ~= nil and i <= count then
                    pi.health = 4 -- fresh run: full HP, not a coffin
                    -- ...and NOT a coffin's occupant either: a stale
                    -- time_of_death makes the next coffin revive this ALIVE
                    -- slot, cloning it (see normalizeCoffinTargets)
                    pi.time_of_death = 0
                    local share = base + ((i <= rem) and 1 or 0)
                    pi.bombs = share
                    pi.ropes = share
                    -- Money is NOT zeroed by our warp-restart (we suppress the
                    -- engine's Quick-Restart on every machine, so its fresh-run
                    -- zeroing never runs). The HUD total is
                    --   Σ(inventory.money + inventory.collected_money_total)
                    --      + state.money_shop_total,
                    -- so the dead run's money survived into the next run. Zero
                    -- all the inventory pieces here (money_shop_total below).
                    pi.money = 0
                    pi.collected_money_total = 0 -- gold banked on previous levels
                    pi.collected_money_count = 0 -- clear the transition gold list
                    pi.poison_tick_timer = -1 -- -1 CURES poison (0 = a tick is due!)
                    pi.cursed = false
                    pi.elixir_buff = false
                    pi.kapala_blood_amount = 0
                    pi.held_item = 0
                    pi.held_item_metadata = 0
                    pi.mount_type = 0
                    pi.mount_metadata = 0
                    pi.companion_count = 0
                    for k = 1, 30 do
                        pi.acquired_powerups[k] = 0
                    end
                end
            end)
        end
    end
    -- Also reset ALL the run-progress state that DRIVES world generation and the
    -- determinism shim's clock (get_frame/get_ms = level_count*BIG + time_level).
    -- An instant restart warps everyone to a fresh 1-1 via moWarp, but warp()
    -- does NOT reset these — it carries them forward. Two ways this desyncs a
    -- restart that FOLLOWS a mid-run join:
    --   * the continuous players carry their elevated level_count / aggro / kali,
    --     so the shim clock's baseline drifts and gen-state differs;
    --   * the just-rejoined player warps in from the CAMP with CAMP quest/presence
    --     flags while everyone else carries the run's flags — a real per-machine
    --     mismatch. Level 1 still matched off the shared seed, but gen branches on
    --     these flags, forking PRNG consumption, so floor 2's generic enemies
    --     (skeletons/bats) landed differently and desynced.
    -- Every one of these is 0 on a genuinely fresh run, so this is a no-op on a
    -- normal run start and only clears residue on a restart. quest_flags=0 also
    -- CLEARS the QUEST_RESET bit, which is safe (SETTING it triggers a reset; the
    -- restart-suppression logic has already cleared it by floor-1 generation).
    -- Skipped for a JOIN (levelOrdinal is the join floor's ordinal, not 0), which
    -- must KEEP the host-synced flags/level_count.
    pcall(function()
        local st = get_local_state()
        st.level_count = 0
        st.time_total = 0
        st.shoppie_aggro = 0
        st.shoppie_aggro_next = 0
        st.merchant_aggro = 0
        st.kali_favor = 0
        st.kali_status = 0
        st.kali_altars_destroyed = 0
        st.money_shop_total = 0 -- shop-spend/idol-sale tally: also part of the HUD money total
        st.quest_flags = 0
        st.presence_flags = 0
    end)
end
--- Enforce the shared seed and roster BEFORE a level starts loading — by
--- generation time the engine may already have derived the layout, and it
--- rebuilds the party from the roster at every level load.
local function onPreLoadScreen()
    if not runActive or not Network.isInRun() then
        return
    end
    -- ABOVE the screen_next check on purpose: a Mama Tunnel encounter is a
    -- SCREEN.TRANSITION, so everything below this line is skipped for exactly
    -- the screen whose contents depend on `savegame.shortcuts`.
    holdSaveSync()
    if get_local_state().screen_next ~= SCREEN.LEVEL then
        return
    end
    -- BEFORE enforceRoster: the engine rebuilds the party from player_inventory
    -- during this load, so the previous run's health must already be gone or it
    -- spawns coffins — or, when every slot is dead, nobody at all
    applyFreshRunReset()
    module.enforceRoster()
    enforceLevelSeed()
    applyStateSync()
    -- AFTER applyStateSync, so a stale time_of_death carried in the host's snapshot
    -- is normalized too (an alive slot must never be a coffin candidate)
    normalizeCoffinTargets()
end

local function onPreLevelGeneration()
    if not runActive or not Network.isInRun() then
        return
    end
    -- BEFORE the level is built: the pet is spawned during generation, so the
    -- host's pet style has to be in force by now or this floor spawns the wrong
    -- one and the world differs (see the pet-style block above)
    enforcePetStyle()
    -- Same deadline, same reason: the HD mod picks its per-floor character
    -- unlock during generation and reads `savegame.characters` to do it.
    holdSaveSync()
    if get_local_state().screen_next ~= SCREEN.LEVEL then
        return
    end
    -- A restart after a whole-party wipe warps everyone to a fresh 1-1, but the
    -- transferred inventory (state.items.player_inventory — health, kit, powerups)
    -- still holds the DEAD run's state. So a non-host restarting via run_start ->
    -- moWarp spawns as a coffin (0 health) and the level instantly re-wipes: a
    -- death -> restart -> death loop. The host escapes it because its own Quick
    -- Restart resets the run. On the run's FIRST level only (levelOrdinal 0 — never
    -- a legit mid-run coffin revive on a later floor), reset EVERY roster player's
    -- transferred inventory to a clean fresh-run start so every machine spawns
    -- identical, LIVING spelunkers with an even kit (the same reset the host's
    -- Quick Restart already applied).
    applyFreshRunReset()
    -- MID-RUN JOIN: give the just-added late-joiner a clean, IDENTICAL body on
    -- every machine — alive but EMPTY-HANDED. Identify the joiner the same way
    -- everywhere: the roster slot with NO entry in the host's snapshot (they
    -- weren't in the run when it was captured). Do NOT gate on local health — the
    -- joiner's OWN game has them alive from the camp while the host's slot is a
    -- stale fresh spawn, so a health<=0 gate reset them on the host (4 bombs) but
    -- not on the joiner (0 bombs), which desynced. One-shot on the join floor.
    if joinInit then
        joinInit = false
        local sync = pendingStateSync
        local hasSync = type(sync) == "table" and type(sync.pl) == "table"
        local coopSlots = Network.coopSlots or {}
        local ok, inv = pcall(function() return get_local_state().items.player_inventory end)
        if ok and inv ~= nil then
            for coopIndex = 1, 4 do
                pcall(function()
                    local pi = inv[coopIndex]
                    if pi == nil then
                        return
                    end
                    local isJoiner
                    if hasSync then
                        isJoiner = coopSlots[coopIndex] ~= nil
                            and sync.pl[tostring(coopIndex)] == nil
                    else
                        isJoiner = (pi.health == nil or pi.health <= 0)
                    end
                    if isJoiner then
                        pi.health = 4 -- alive, not a coffin
                        pi.time_of_death = 0 -- ...nor a coffin's occupant
                        pi.bombs = 0  -- a mid-run joiner arrives EMPTY-HANDED
                        pi.ropes = 0
                        pi.money = 0  -- and broke — otherwise a stale camp value
                                      -- lingers (machine-dependent) and desyncs money
                        pi.poison_tick_timer = -1
                        pi.cursed = false
                        pi.elixir_buff = false
                        pi.kapala_blood_amount = 0
                        pi.held_item = 0
                        pi.held_item_metadata = 0
                        pi.mount_type = 0
                        pi.mount_metadata = 0
                        pi.companion_count = 0
                        for k = 1, 30 do
                            pi.acquired_powerups[k] = 0
                        end
                    end
                end)
            end
        end
    end
    enforceLevelSeed()
    applyStateSync()
    -- AFTER applyStateSync (see the other call site): an ALIVE slot must never be
    -- left as a coffin candidate, or the next coffin clones it
    normalizeCoffinTargets()
    -- record the generation INPUTS (seed + prng stream state) now that the floor's
    -- seed is applied: if two machines differ HERE the divergence was inherited,
    -- and if they match here but build different worlds it came from the content
    -- mod's own generator (see DesyncLog.genPhase)
    if DesyncLog ~= nil then
        DesyncLog.genPhase("pre")
    end
    -- Publish the seed that ACTUALLY generates this floor, captured HERE.
    --
    -- It used to be captured at POST_LEVEL_GENERATION on the assumption that the
    -- adventure seed had already evolved to the next floor's value. It has not:
    -- the engine evolves it during the NEXT level's load, so the post-gen capture
    -- was the CURRENT floor's seed published under the NEXT floor's ordinal —
    -- always exactly one floor stale. A non-host applied it and generated floor
    -- N with floor N-1's seed, then evolved from there, leaving it permanently
    -- one step behind the host (capture: peer's seq-15 adv_seed was byte-for-byte
    -- the host's seq-5 value, entities diverged from 1-3 on). The rebase meant to
    -- PREVENT drift was the thing creating it.
    --
    -- `levelOrdinal` here is the same value a non-host holds at this floor's
    -- PRE_LOAD_SCREEN (it only increments at gate-engage, after generation), so
    -- this tag matches the lookup in enforceLevelSeed exactly. Both machines
    -- evolve the seed identically, so when this arrives in time it is a no-op,
    -- and when it is late the non-host's own value is already correct — either
    -- way it can no longer force a stale seed.
    pcall(function()
        local a, b = get_adventure_seed(false)
        floorSeedForOrd = { ord = levelOrdinal, seed = { math.floor(a), math.floor(b) } }
    end)
    publishLevelSeed(levelOrdinal)
    -- remember what generates THIS floor: it's the payload a floor resync
    -- rebroadcasts so every machine can regenerate the identical level. Not
    -- captured during an instant-restart limbo (that generation is a local
    -- artifact, not a shared floor).
    if get_ms() >= awaitingRestartUntil then
        local first, second = get_adventure_seed(false)
        currentFloorSeed = { math.floor(first), math.floor(second) }
        currentFloorOrd = levelOrdinal
    end
end

--- Just after a level finishes generating, the adventure seed holds the state
--- that will generate the NEXT level. The world host publishes it (tagged with
--- that upcoming level's ordinal) so every client can rebase the next floor
--- onto it.
local function onPostLevelGeneration()
    if not runActive or not Network.isInRun() then
        return
    end
    local state = get_local_state()
    -- Both bail-outs below are logged: skipping post-generation means no level
    -- seed is captured here, and a capture where the host skipped it for three
    -- consecutive runs is exactly how the "every run after the first desyncs"
    -- bug hid. Naming the guard makes the cause unambiguous next time.
    if state.screen ~= SCREEN.LEVEL then
        -- A TRANSITION generating its own little world is normal and happens at
        -- EVERY floor boundary. Logging that buried the real signal: one capture
        -- had 19 of these, all benign, sitting next to the lines that mattered.
        -- Only a screen that is neither LEVEL nor TRANSITION is worth a line.
        if state.screen ~= SCREEN.TRANSITION and DesyncLog ~= nil then
            DesyncLog.event("post-gen SKIPPED: screen=%s is neither LEVEL nor TRANSITION (no seed captured here)",
                tostring(state.screen))
        end
        return -- transitions/cutscenes don't generate a shared floor
    end
    if get_ms() < awaitingRestartUntil then
        if DesyncLog ~= nil then
            DesyncLog.event("post-gen SKIPPED: restart pending for %d more ms (no seed captured here)",
                math.floor(awaitingRestartUntil - get_ms()))
        end
        return -- host's local reload during an instant restart: not a shared floor
    end
    currentFloor = { w = state.world, l = state.level, t = state.theme }
    -- how much this floor's generation actually consumed: comparing "pre" to
    -- "post" across two machines separates a generator that drew a different
    -- NUMBER of values from inputs that were already different
    if DesyncLog ~= nil then
        DesyncLog.genPhase("post")
    end
    -- the evolved seed is what generates the NEXT floor: the per-floor rebase
    -- broadcasts it, and a floor resync uses it to advance everyone past a
    -- desynced floor (only the world host's copy is ever sent anywhere)
    local first, second = get_adventure_seed(false)
    nextFloorSeed = { math.floor(first), math.floor(second) }
    -- NOTE: deliberately does NOT publish. At this point the adventure seed has
    -- NOT yet evolved to the next floor's value (the engine does that during the
    -- next level's load), so publishing here sent a one-floor-stale seed under a
    -- future ordinal — the desync described at the pre-generation capture above.
    -- nextFloorSeed is still kept: the join / floor-resync paths use it as "the
    -- seed this machine would carry forward", which is a different question.
end

--- Release this floor's coffin hook through the ThemeInfo it was installed on.
--- ONLY safe while that object is still alive, which is why the single caller is
--- POST_LEVEL_GENERATION: the engine is still mid-load and provably holding the
--- theme it just generated from. `add_coffin` is a GENERATION virtual, so the hook
--- has already done its whole job by then and nothing is lost by dropping it here.
--- NEVER clear_callback: that id is not a CallbackId (see the note at coffinHook).
local function releaseCoffinHook()
    local hook = coffinHook
    coffinHook = nil
    if hook == nil or hook.theme == nil or hook.id == nil then
        return
    end
    local released = false
    pcall(function()
        hook.theme:clear_virtual(hook.id)
        released = true
    end)
    if not released and not coffinReleaseWarned then
        -- an Overlunky build without clear_virtual: the hook simply stays on that
        -- ThemeInfo. Bounded (one per floor), inert outside a networked run, and
        -- strictly better than reaching into the wrong registry to remove it.
        coffinReleaseWarned = true
        if DesyncLog ~= nil then
            DesyncLog.event("coffin hook %s could not be released (ThemeInfo:clear_virtual unavailable);"
                .. " left installed -- harmless, but reported once", tostring(hook.id))
        end
    end
end

--- Suppress ONLY the engine's character-UNLOCK coffin (`ThemeInfo:add_coffin`)
--- during networked runs. That coffin's contents come from THIS machine's LOCAL
--- SAVE (the unlocked-characters bitmask), and in our fixed roster OPENING one
--- makes the engine `spawn_player` into a FREE slot (3-4) -> an out-of-roster
--- spelunker we never re-skin (the "duplicate of a live player" + extra HUD row);
--- it is also save-driven, a latent gen divergence. `set_pre_coffin` hooks that
--- ONE virtual and returning true skips it, so the coffin room is never generated.
--- CRUCIALLY it does NOT touch the player-REVIVAL coffin (`add_player_coffin`) or
--- the Dirk coffin (`add_dirk_coffin`) — those are SEPARATE virtuals — so a dead
--- player still gets a revival coffin. (An earlier version destroyed coffins by
--- entity, which wrongly removed revival coffins too — that broke reviving.)
---
--- Must run at PRE_LEVEL_GENERATION, before the engine calls add_coffin. Hooked
--- once per theme id per run (state.theme_info is the current theme's persistent
--- info); the hook body re-checks isInRun so it self-disables outside a networked
--- run (solo keeps its unlock coffins). The hook is released again as soon as
--- generation finishes, by releaseCoffinHook at POST_LEVEL_GENERATION.
local function suppressUnlockCoffins()
    if not Network.isInRun() then
        return
    end
    -- ONLY for the content mod that needs it. This hooks a ThemeInfo virtual and
    -- SKIPS a room the engine adds DURING LEVEL GENERATION. A mod that owns its
    -- own generation and rebuilds state.theme_info every level (force_custom_theme)
    -- has engine internals pulled out from under it, which is exactly what the
    -- known-good 0.14.5 build never did. See Network.fullTreatmentMod.
    if not Network.fullTreatmentMod() then
        return
    end
    local ti = get_local_state().theme_info
    if ti == nil then
        return
    end
    -- A hook still outstanding here means POST_LEVEL_GENERATION did not fire for
    -- the previous floor (it does not, on a post-wipe restart). Its ThemeInfo may
    -- already be freed, so the reference is dropped rather than released -- see the
    -- run-start note. One inert hook is leaked in that rare case; a use-after-free
    -- would take the process down with no Lua error at all.
    coffinHook = nil
    local ok, id = pcall(function()
        return ti:set_pre_coffin(function()
            -- SafeCall for the same reason as doorCanEnter: engine-invoked across
            -- the C++ boundary, so an uncaught error here has no traceback. On the
            -- (currently impossible) error path SafeCall returns nil = falsy = let
            -- the coffin spawn, the safe solo-like default.
            -- exactly `true` (skip the unlock coffin) or NO value (let it spawn)
            local skip = SafeCall("eventSync:preCoffin", function()
                return Network ~= nil and Network.isInRun()
            end)
            if skip == true then
                return true
            end
        end)
    end)
    if ok and id ~= nil then
        coffinHook = { theme = ti, id = id }
    else
        -- never fail silently: if this stops working the character-unlock coffin
        -- comes back and clones a player into a free roster slot
        errorf("suppressUnlockCoffins: set_pre_coffin failed (%s)", tostring(id))
    end
end

--- The world host's seed for an upcoming floor. Only the fixed run host is
--- authoritative; ignore anyone else (and our own echo when we are the host).
--- Storing a seed twice (reliable + the unreliable rebroadcast) is idempotent —
--- the value is the same — so both channels feed this safely.
--- @param payload { n: integer, a: integer, b: integer }
--- @param originSlot integer
local function onLevelSeed(payload, originSlot)
    if type(payload) ~= "table"
        or originSlot ~= Network.hostSlot() or Network.isWorldHost() then
        return
    end
    local ord = math.floor(tonumber(payload.n) or -1)
    if ord >= 0 then
        hostSeeds[ord] = { math.floor(tonumber(payload.a) or 0),
                           math.floor(tonumber(payload.b) or 0) }
    end
end
-- The UNRELIABLE world channel delivers the same seed too (see the rebroadcast
-- below); inputSync's world-message dispatch routes a {k="seed"} datagram here.
module.applyHostSeed = onLevelSeed

-- The per-floor levelseed rides the reliable ordered event channel, and a single
-- lost datagram there stalls that ENTIRE channel for one client until it is
-- resent — long enough that the client generates the next floor from its own
-- (drifted) seed, a whole-world divergence (observed: slot 3 built a different
-- 1-3 while the host and slot 2 agreed). Because the seed only has to REPRODUCE
-- the host's value, not be ordered, the host ALSO rebroadcasts the upcoming
-- floor's seed on the UNRELIABLE world channel a few times a second while it is
-- on the current floor. That channel cannot head-of-line-stall, so a non-host
-- that missed the reliable copy still has the seed cached before it gets there.
local SEED_REBROADCAST_MS = 300
local lastSeedRebroadcastMs = 0
local function pollRebroadcastSeed()
    if not runActive or not Network.isInRun() or not Network.isWorldHost() then
        return
    end
    if floorSeedForOrd == nil then
        return
    end
    local now = get_ms()
    if now - lastSeedRebroadcastMs < SEED_REBROADCAST_MS then
        return
    end
    lastSeedRebroadcastMs = now
    Network.sendWorld({
        k = "seed",
        n = floorSeedForOrd.ord,
        a = floorSeedForOrd.seed[1],
        b = floorSeedForOrd.seed[2],
    })
end

--- A late-joiner readied while we're mid-run — they'll be folded in at the next
--- floor. Flag it (every machine, ordered with the sim) so the world host asks
--- for the join warp at its next floor generation (see onPostLevelGeneration).
--- @param payload { slot: integer, name: string }
local function onJoinPending(payload)
    if not runActive or not Network.isInRun() then
        return
    end
    joinPending = true
    toast(string.format("%s is joining next floor...",
        tostring(type(payload) == "table" and payload.name or "A player")))
end

--- Fold a readied late-joiner into the run at the NEXT floor. The world host does
--- it DURING the screen transition — BEFORE the next floor generates — so the
--- floor loads exactly ONCE and the joiner rides the identical generation (the
--- earlier post-generation trigger regenerated the floor a second time, and the
--- determinism shim's per-floor RNG reseed diverged on that repeat → different
--- layout even with a matching seed). Mirrors the resync's advance-to-next-floor
--- warp (nextFloorSeed, currentFloorOrd+1) but rides run_start so the not-yet-in-
--- run joiner can apply it too. If no transition comes (e.g. a wipe first), the
--- joiner still comes in via the next run_start (Phase 1).
local function pollJoinAtTransition()
    if not joinPending or not runActive or not Network.isInRun() then
        return
    end
    if not Network.isWorldHost() or nextFloorSeed == nil then
        return
    end
    local state = get_local_state()
    if state.screen ~= SCREEN.TRANSITION or state.loading ~= FADE.NONE then
        return -- only on the settled transition screen, before the next floor loads
    end
    joinPending = false
    local dest = { w = state.world_next, l = state.level_next, t = state.theme_next }
    Network.requestJoinFloor(dest, nextFloorSeed, currentFloorOrd + 1, captureStateSync(true))
end

-- -------------------------------------------------------------- floor resync
--- Where the stalled party should advance to, from OUR local vantage. Only
--- meaningful on a machine that already advanced past the stuck floor (it
--- watched the exit door resolve, so it knows the destination even under
--- modded progression). Machines left behind return nil and rely on the
--- ahead machine to report the way.
local function myAdvanceDestination()
    if InputSync.stallDesyncRole() ~= "ahead" then
        return nil
    end
    local state = get_local_state()
    if state.screen == SCREEN.TRANSITION then
        -- between floors: the engine holds where the transition leads
        return { w = state.world_next, l = state.level_next, t = state.theme_next }
    elseif state.screen == SCREEN.LEVEL then
        -- already playing the next floor: this is the destination
        return { w = state.world, l = state.level, t = state.theme }
    end
    -- Transient window (a load fade is in flight, so the screen is momentarily
    -- neither LEVEL nor TRANSITION): fall back to the last floor we finished
    -- generating. Without this, a resync request that happens to fire during
    -- the fade carried NO destination, the host couldn't build a warp, and the
    -- whole party stayed frozen until the next detection cycle (often reading
    -- as "the resync just doesn't work").
    if currentFloor ~= nil then
        return { w = currentFloor.w, l = currentFloor.l, t = currentFloor.t }
    end
    return nil
end

--- Host only: send everyone (host included) to `dest`, generated from the
--- host's authoritative seed, on an agreed fresh input sequence safely above
--- anything any machine has reached. Returns true when actually sent.
--- @param dest { w: integer, l: integer, t: integer }?
--- @param withRunFlags boolean? # also sync quest/presence flags. A STALL resync
---   leaves them out (peers already share them — the proven path). A per-floor
---   DIGEST resync sets it: a mid-run JOINER (or any client whose flags drifted)
---   needs them or its floor never converges to the host's and it stays lost.
--- @return boolean
local function broadcastFloorWarp(dest, withRunFlags)
    if dest == nil then
        return false
    end
    -- pick the seed that generates the destination in the host's world: the
    -- floor we're already standing on has its own captured generator seed;
    -- a floor past ours is generated by our evolved (post-generation) seed
    local seed, ord
    if currentFloor ~= nil and currentFloorSeed ~= nil
        and dest.w == currentFloor.w and dest.l == currentFloor.l
        and dest.t == currentFloor.t then
        seed, ord = currentFloorSeed, currentFloorOrd
    elseif nextFloorSeed ~= nil then
        seed, ord = nextFloorSeed, currentFloorOrd + 1
    else
        return false
    end
    local mySeq = InputSync.position()
    Network.sendEvent("floor_warp", {
        w = dest.w, l = dest.l, t = dest.t,
        a = seed[1], b = seed[2], ord = ord, q = mySeq + 8,
        st = captureStateSync(withRunFlags),
    })
    return true
end

--- The per-floor world digest agreed with the host: clear the resync loop guard
--- so the next genuine mismatch is allowed to auto-correct again.
function module.onFloorClean()
    digestResyncStreak = 0
end

--- Non-host only: our freshly generated floor's fingerprint differs from the world
--- host's (InputSync.checkFloorDigest). Ask the host to re-broadcast THIS floor on
--- its authoritative seed + state so we regenerate its exact world in place (never
--- an advance — we haven't gone anywhere, the floor is just wrong). Rate-limited
--- like every resync, and bounded by MAX_DIGEST_RESYNCS so a divergence the state
--- snapshot can't heal leaves the on-screen notice up instead of warp-looping.
function module.requestFloorRegen()
    if not runActive or not Network.isInRun() or not InputSync.hasStarted() then
        return
    end
    if Network.isWorldHost() then
        return -- the host's world is the reference; it never regenerates to itself
    end
    local now = get_ms()
    if now < awaitingRestartUntil or now - lastResyncMs < 8000 then
        return
    end
    if digestResyncStreak >= MAX_DIGEST_RESYNCS then
        return -- gave up on THIS floor: repeated resyncs didn't converge, don't warp-loop
    end
    if digestGaveUp then
        return -- persistent whole-run divergence: stop, notice stays up
    end
    if currentFloor == nil then
        return
    end
    -- Circuit breaker: resyncing this OFTEN across a run means something keeps
    -- diverging that a floor resync can't heal (a mod behaving non-deterministically,
    -- or run state kept in mod-lua a game-state snapshot can't touch). Stop warping —
    -- every regen double-generates the floor, which advances run progress (it's what
    -- wiped the "robbed a shopkeeper" aggro) — and tell the players once.
    local recent = {}
    for _, t in ipairs(digestResyncTimes) do
        if now - t < DIGEST_GIVEUP_WINDOW then
            recent[#recent + 1] = t
        end
    end
    digestResyncTimes = recent
    if #digestResyncTimes >= DIGEST_GIVEUP_COUNT then
        digestGaveUp = true
        errorf("persistent world divergence — giving up auto-resync for this run")
        toast("Worlds keep diverging — a mod is non-deterministic here. Restart the run; if it keeps happening, confirm BOTH players run the exact same mod versions.")
        return
    end
    digestResyncTimes[#digestResyncTimes + 1] = now
    digestResyncStreak = digestResyncStreak + 1
    lastResyncMs = now
    Network.sendEvent("resync_req",
        { regen = 1, w = currentFloor.w, l = currentFloor.l, t = currentFloor.t })
end

--- Called (rate-limited) when the lockstep gate has been stalled against a
--- live peer on a different sequence — the "waiting for all players" freeze.
--- The resync always moves the party FORWARD, never back onto the desynced
--- floor (advancing is the only escape that can't loop).
function module.requestFloorResync()
    if not runActive or not Network.isInRun() or not InputSync.hasStarted() then
        return
    end
    local now = get_ms()
    if now < awaitingRestartUntil or now - lastResyncMs < 8000 then
        return
    end
    local dest = myAdvanceDestination()
    if Network.isWorldHost() then
        -- a host left behind doesn't know the way; it waits for the ahead
        -- machine's resync_req (which carries the destination) instead —
        -- don't burn the rate limit on a broadcast we cannot make
        if broadcastFloorWarp(dest) then
            lastResyncMs = now
        end
    else
        lastResyncMs = now
        Network.sendEvent("resync_req", dest or {})
    end
end

--- A non-host machine detected the deadlock; only the world host answers.
--- The request carries the destination when the requester is the machine
--- that advanced; an empty request is just a nudge (useful when the HOST is
--- the one that advanced and its own detector hasn't fired yet).
local function onResyncReq(payload, originSlot)
    if not Network.isWorldHost() or originSlot == Network.slot then
        return
    end
    if not runActive or not Network.isInRun() then
        return
    end
    local now = get_ms()
    if now < awaitingRestartUntil or now - lastResyncMs < 8000 then
        return
    end
    -- A per-floor world-digest mismatch (regen=1): a client's copy of THIS floor
    -- generated differently. Re-broadcast the floor we are standing on, on our
    -- authoritative seed + state, so the client regenerates our exact world in
    -- place. Guarded so a stale request can't warp anyone off their floor: only
    -- when we are still ON a level and it is the exact floor the client named.
    if type(payload) == "table" and tonumber(payload.regen) == 1 then
        if currentFloor ~= nil and currentFloorSeed ~= nil
            and math.floor(tonumber(payload.w) or -1) == currentFloor.w
            and math.floor(tonumber(payload.l) or -1) == currentFloor.l
            and get_local_state().screen == SCREEN.LEVEL
            and get_local_state().loading == FADE.NONE
            and broadcastFloorWarp(currentFloor, true) then -- WITH run flags: converge a joiner
            lastResyncMs = now
        end
        return
    end
    local dest = nil
    if type(payload) == "table" and tonumber(payload.w) ~= nil then
        dest = {
            w = math.floor(tonumber(payload.w)),
            l = math.floor(tonumber(payload.l) or 1),
            t = math.floor(tonumber(payload.t) or 1),
        }
    end
    -- ONLY a death plea may fall back to regenerating the CURRENT floor
    -- (the requester's whole party died in ITS diverged world — there is no
    -- forward destination, and a fresh start with the host's authoritative
    -- state beats letting the run collapse). A generic stall nudge must
    -- NEVER take that fallback: it can arrive while this machine is mid
    -- transition — before its own stall detector classifies anything — and
    -- currentFloor still points at the floor everyone just LEFT, so the
    -- fallback would warp the party backwards and undo the advance.
    local deathPlea = type(payload) == "table" and tonumber(payload.death) == 1
    if broadcastFloorWarp(dest or myAdvanceDestination()
        or (deathPlea and currentFloor or nil)) then
        lastResyncMs = now
    end
end

--- Every machine (host included, via its own echo) applies the resync warp.
--- Deferred while a load is in flight: warping mid-fade is asking for trouble.
--- @param payload { w:integer, l:integer, t:integer, a:integer, b:integer, ord:integer, q:integer }
--- @param originSlot integer
local function onFloorWarp(payload, originSlot)
    if originSlot ~= Network.hostSlot() then
        return
    end
    if not runActive or not Network.isInRun() then
        return
    end
    pendingWarp = payload
end

local function applyPendingWarp()
    if pendingWarp == nil then
        return
    end
    if not runActive or not Network.isInRun() then
        pendingWarp = nil
        return
    end
    if get_local_state().loading ~= FADE.NONE then
        return -- wait out the in-flight load, then warp
    end
    local p = pendingWarp
    pendingWarp = nil
    pendingRunSeed = { math.floor(tonumber(p.a) or 0), math.floor(tonumber(p.b) or 0) }
    pendingStateSync = type(p.st) == "table" and p.st or nil
    levelOrdinal = math.floor(tonumber(p.ord) or 0)
    hostSeeds = {}
    -- a rebase can move the ordinal BACKWARDS, so forget what we published or the
    -- idempotence guard would suppress a seed the party now needs again
    floorSeedForOrd = nil
    publishedSeedOrd = nil
    runEndedNoticeMs = nil
    InputSync.rebase(math.floor(tonumber(p.q) or 0))
    errorf("floor resync: warping to %s-%s on the host's seed",
        tostring(p.w), tostring(p.l))
    if DesyncLog ~= nil then
        DesyncLog.event("RESYNC WARP -> %s-%s (theme %s) on host seed, rebase seq=%s ord=%d",
            tostring(p.w), tostring(p.l), tostring(p.t), tostring(p.q), levelOrdinal)
    end
    toast(string.format("Players desynced — resyncing to floor %s-%s!",
        tostring(p.w), tostring(p.l)))
    moWarp(math.floor(tonumber(p.w) or 1), math.floor(tonumber(p.l) or 1),
        math.floor(tonumber(p.t) or 1))
end

-- -------------------------------------------------------------- instant restart

--- The host asks the server to re-roll a seed and broadcast a fresh run_start
--- to everyone. Resent under one nonce until run_start arrives, so a lost
--- datagram can't strand the request.
local function hostBeginRestart()
    if DesyncLog ~= nil then
        DesyncLog.event("hostBeginRestart -> requesting run_start")
    end
    awaitingRestartUntil = get_ms() + 10000
    lastResyncMs = get_ms() -- keep the stall detector quiet meanwhile
    restartNonce = string.format("r%d", get_ms())
    restartResendMs = get_ms()
    Network.requestRestart(restartNonce)
end

--- @return integer # how many players have voted this round
local function countRestartVotes()
    local votes = 0
    for _ in pairs(restartVotes) do
        votes = votes + 1
    end
    return votes
end

--- Count votes and, once every present player has voted, restart. Every machine
--- clears its tally in lockstep; only the lobby host actually asks the server
--- (which dedups the request), and run_start then reloads everyone together.
local function tallyRestartVotes()
    if not runActive or not Network.isInRun() then
        return
    end
    local total = InputSync.activePlayers()
    if total <= 0 then
        return
    end
    local votes = countRestartVotes()
    if votes >= total then
        restartVotes = {}
        restartVoteDeadline = nil
        restartVoted = false
        if DesyncLog ~= nil then
            DesyncLog.event("restart vote PASSED (%d/%d) host=%s", votes, total, tostring(Network.isHost()))
        end
        if Network.isHost() then
            hostBeginRestart()
        end
    end
end

--- Broadcast our restart vote (comes back to everyone, including us, stamped
--- with our slot).
local function castRestartVote()
    restartVoteDeadline = get_ms() + RESTART_VOTE_TTL
    if DesyncLog ~= nil then
        DesyncLog.event("restart vote CAST (my slot %s)", tostring(Network.slot))
    end
    Network.sendEvent("restart_vote", {})
end

--- @param payload any
--- @param originSlot integer
local function onRestartVote(payload, originSlot)
    if not runActive or not Network.isInRun() or originSlot == 0 then
        return
    end
    restartVotes[originSlot] = true
    restartVoteDeadline = restartVoteDeadline or (get_ms() + RESTART_VOTE_TTL)
    local votes = countRestartVotes()
    if DesyncLog ~= nil then
        DesyncLog.event("restart vote from slot %d -> %d/%d", originSlot, votes, InputSync.activePlayers())
    end
    toast(string.format("Restart vote: %d/%d — everyone must press instant restart",
        votes, InputSync.activePlayers()))
    tallyRestartVotes()
end

--- Expire an incomplete vote so a single stray press doesn't linger forever.
local function pollRestartVote()
    if restartVoteDeadline ~= nil and get_ms() >= restartVoteDeadline then
        restartVoteDeadline = nil
        restartVoted = false
        if next(restartVotes) ~= nil then
            restartVotes = {}
            toast("Restart vote expired")
        end
    end
end

--- The state, but only when the engine has raised the run-reset flag -- i.e. the
--- probe below, named so it can be protected without allocating a closure.
--- @return StateMemory?
local function readQuestResetState()
    local st = get_local_state()
    if (st.quest_flags & QUEST_RESET) ~= 0 then
        return st
    end
    return nil
end

--- Called from inputSync's PRE_UPDATE every frame. If the player triggered an
--- instant restart mid-run, squash its fade before it can disengage the
--- lockstep gate — otherwise the presser stops feeding inputs (freezing the
--- party) and re-engages on a bumped sequence (dragging everyone to 1-1 via a
--- floor resync). We clear the reset flag AND cancel the pending transition
--- (screen_next / loading) each frame for a short window, keep the gate engaged,
--- and cast one vote. The run only restarts once everyone votes, via run_start.
---
--- Runs in PRE_UPDATE specifically because it fires DURING the restart's fade
--- (GAMEFRAME does not), so the fade is killed on its very first frame. Our own
--- synchronized warps set suppressWarpUntil and are left alone, so real
--- restarts still happen for the whole party together.
function module.suppressRestartFade()
    -- EVERY guard below used to bounce a press in total silence, so "I pressed
    -- restart and nothing happened" left no evidence anywhere -- the only line the
    -- whole path could produce was `restart vote CAST`, which by definition is
    -- absent in exactly the case worth diagnosing. Report the flag WHENEVER it is
    -- set, before anything can decline it, naming the guard that did. Rate-limited
    -- because the flag stays raised for several frames per press.
    -- pcall(fn) rather than pcall(closure): PRE_UPDATE, so once per simulated
    -- frame. The flag read stays INSIDE the protected call, exactly as it was --
    -- pulling it out would turn a silently skipped frame into a logged error.
    local okProbe, probeState = pcall(readQuestResetState)
    local probe = nil
    if okProbe then
        probe = probeState
    end
    if probe ~= nil and DesyncLog ~= nil and get_ms() >= restartSeenNoticeMs then
        restartSeenNoticeMs = get_ms() + 400
        local why = "claimed"
        if not runActive or not Network.isInRun() then
            why = "IGNORED: not in a run (runActive=" .. tostring(runActive)
                .. " inRun=" .. tostring(Network.isInRun()) .. ")"
        elseif get_ms() < suppressWarpUntil then
            why = string.format("IGNORED: inside our own warp window (%d ms left)",
                math.floor(suppressWarpUntil - get_ms()))
        elseif probe.screen ~= SCREEN.LEVEL and probe.screen ~= SCREEN.TRANSITION then
            why = "IGNORED: screen is not a level/transition"
        elseif restartVoted then
            why = "already voted this round; waiting on the others"
        end
        DesyncLog.event(
            "restart flag SEEN on %s-%s: %s | screen=%s screen_next=%s loading=%s voted=%s votes=%d/%d",
            tostring(probe.world), tostring(probe.level), why,
            tostring(probe.screen), tostring(probe.screen_next), tostring(probe.loading),
            tostring(restartVoted), countRestartVotes(), InputSync.activePlayers())
    end
    if not runActive or not Network.isInRun() then
        return
    end
    local state = get_local_state()
    if get_ms() < suppressWarpUntil then
        return -- our own synchronized warp (run_start / resync): let it proceed
    end
    local screen = state.screen
    if screen ~= SCREEN.LEVEL and screen ~= SCREEN.TRANSITION then
        return -- the post-wipe death screen is handled at PRE_LOAD_SCREEN
    end
    if (state.quest_flags & QUEST_RESET) ~= 0 then
        -- the player just pressed instant restart: open/refresh the squash
        -- window and count one vote for this round
        restartSuppressUntil = get_ms() + 500
        if not restartVoted then
            restartVoted = true
            castRestartVote()
        end
    end
    if get_ms() < restartSuppressUntil then
        pcall(function()
            state.quest_flags = state.quest_flags & ~QUEST_RESET
            -- Undo the restart transition if a fade toward it is in flight. This
            -- used to also require screen_next == SCREEN.LEVEL, i.e. it assumed a
            -- quick restart always heads for a LEVEL. Spelunky 2.5 breaks that: it
            -- redirects a restart to its WARP ZONE, so screen_next is something
            -- else, the cancel never ran, and the machine rode the fade into its
            -- own private warp zone while everyone else stayed put — the reported
            -- "restart puts you in your own game". Whatever the destination, a
            -- suppressed restart must go NOWHERE; the fade being in flight is the
            -- only condition that matters.
            if state.loading ~= FADE.NONE then
                state.screen_next = state.screen
                state.world_next = state.world
                state.level_next = state.level
                state.theme_next = state.theme
                state.loading = FADE.NONE
            end
        end)
    end
end

-- Local-only screens reachable from the in-run pause menu. Opening one starts a
-- REAL screen load, which takes that machine out of the shared simulation.
-- Deliberately NOT MENU/TITLE: quitting to the menu is the leave path, owned by
-- pollQuitLeave.
local MENU_SCREENS = {}
pcall(function()
    MENU_SCREENS[SCREEN.OPTIONS] = true
    MENU_SCREENS[SCREEN.PLAYER_PROFILE] = true
    MENU_SCREENS[SCREEN.LEADERBOARD] = true
end)
-- the destination the engine legitimately wanted, so cancelling a menu load can
-- never clobber a real next-floor target
local lastGoodScreenNext = nil
local menuScreenNoticeMs = 0

-- ------------------------------------------------- transition exit barrier
--
-- Two machines enter a transition on the same frame and leave it on different
-- ones. From the two-machine capture: both logged the transition at seq:offset
-- 7:873 -- perfect lockstep -- and then the peer left at 8:259 while the host was
-- still standing there, stalling at 8:265 on inputs that were never coming.
--
-- ENTERING is lockstepped. LEAVING IS NOT: each machine walks out when its own
-- player finishes with Mama Tunnel and takes the door, and a dialogue takes as long
-- as the person reading it. 2.0.0-dev47 synchronised her STATE so both machines get
-- the same encounter, which was necessary and not sufficient -- the same encounter
-- still takes two different amounts of time to dismiss.
--
-- What that cost, in order: the peer generated 2-1 alone on its own evolved seed;
-- the stall detector resync-warped the party to 2-1 on the host's seed; and the peer
-- generated 2-1 A SECOND TIME. The HD mod builds its levels in Lua and advances its
-- own state while doing it, so the peer's second 2-1 was a different world entirely
-- -- `FLOOR DESYNC seq=17` with the seed matching and the entities not (Jungle frogs
-- on one machine, jiangshi and an eggplant altar on the other).
--
-- So nobody leaves a transition until everybody is ready to. Held exactly the way
-- suppressMenuScreens holds the settings screen: refuse the screen change on the
-- frame the engine commits to it. That keeps the gate engaged and keeps this machine
-- recording and sending input, so holding cannot itself cause the stall it prevents
-- -- the party sees a player standing on the transition, which is what they are.
--
-- Every piece of state below lives on ONE table on purpose. eventSync's main chunk
-- is within a handful of locals of Lua's hard limit of 200 per chunk, and the first
-- draft of this block -- eleven separate locals -- did not compile at all.
local tbar = {
    HOLD_MAX_MS = 20000,  -- never hang forever, whatever happens to the other machine
    RESEND_MS = 1000,     -- re-announce while waiting, for a peer that joined late
    ready = {},           -- netSlot -> true, for the transition named by `key`
    key = nil,            -- which transition those readies belong to
    holding = false,      -- are we holding this machine on the transition?
    heldMs = 0,           -- ...and since when. A separate flag rather than
                          -- `heldMs ~= 0`, because get_ms() really is 0 for the
                          -- first millisecond after launch.
    sentMs = nil,         -- nil = never announced. NOT 0, which reads as
                          -- 'announced at time zero' and skips the first send.
    gaveUp = false,
}

--- Identifies THIS transition, so a readiness signal for the previous one cannot
--- release the next. `level_count` advances once per floor and both machines agree
--- on it -- it is part of the state the floor digest already compares.
--- @param key integer
local function tbarReset(key)
    tbar.ready = {}
    tbar.key = key
    tbar.holding = false
    tbar.heldMs = 0
    tbar.sentMs = nil
    tbar.gaveUp = false
    tbar.wantNext = nil
    tbar.wantLoading = nil
end

--- Everyone still IN THE RUN is someone to wait for. A player who left mid-
--- transition is not, and `coopSlots` is the same roster the rest of this file
--- gates on.
--- @return boolean
local function tbarEveryoneReady()
    for _, netSlot in pairs(Network.coopSlots or {}) do
        if netSlot ~= nil and tbar.ready[math.floor(netSlot)] ~= true then
            return false
        end
    end
    return true
end

--- True while we are holding this machine on a transition, so menuUI can say so
--- rather than leave the player looking at a screen that ignores them.
--- @return boolean
function module.transitionHolding()
    return tbar.holding and not tbar.gaveUp
end

--- @param payload { k: integer }
--- @param originSlot integer
function module.onTransitionReady(payload, originSlot)
    local key = math.floor(tonumber(payload.k) or -1)
    if key < 0 then
        return
    end
    if tbar.key ~= key then
        tbarReset(key)
    end
    tbar.ready[math.floor(originSlot)] = true
end

--- Called from inputSync's PRE_UPDATE, beside suppressMenuScreens and for the same
--- reason: it is the only callback that fires during a fade, which is when the
--- engine commits to leaving a screen.
function module.holdTransitionExit()
    if not runActive or not Network.isInRun() then
        return
    end
    local state = get_local_state()
    if state.screen ~= SCREEN.TRANSITION then
        return
    end
    local key = math.floor(state.level_count or 0)
    if tbar.key ~= key then
        tbarReset(key)
    end
    if tbar.gaveUp then
        return -- already stopped waiting for this transition; never re-hold it
    end
    -- `and not tbar.holding` is load-bearing. The hold at the bottom sets
    -- screen_next BACK to TRANSITION, so without it this returns here on the very
    -- next frame and the barrier evaluates exactly ONCE: readiness is never
    -- re-checked, the resend never fires and the give-up timer never runs. Two
    -- machines then hold each other forever. Both dev48 logs show exactly that --
    -- the pair announcing the hold on the identical frame (2:75 and 2:75) and
    -- neither ever releasing, with `next cseq out 3` proving the resend never ran.
    if state.screen_next == SCREEN.TRANSITION and not tbar.holding then
        return -- still on it and not trying to leave: nothing to decide yet
    end

    -- We are trying to leave, so we are done with this transition. Say so, and
    -- count ourselves: our own events never come back to us.
    tbar.ready[math.floor(Network.slot or 0)] = true
    local now = get_ms()
    if tbar.sentMs == nil or now - tbar.sentMs > tbar.RESEND_MS then
        tbar.sentMs = now
        Network.sendEvent("tready", { k = key })
    end

    local letGo, why = false, nil
    if tbarEveryoneReady() then
        letGo = true
        why = "released after %d ms -- everyone is done with transition %d"
    elseif tbar.holding and now - tbar.heldMs > tbar.HOLD_MAX_MS then
        -- A player who crashed or alt-F4'd will never signal. The stall detector's
        -- resync is a worse outcome than this hold, and a far better one than a
        -- party frozen on a transition with no way out at all.
        letGo = true
        tbar.gaveUp = true
        why = "gave up after %d ms waiting for the other players (transition %d)"
    end

    if letGo then
        if tbar.holding then
            tbar.holding = false
            -- Put the screen change back EXACTLY as the engine had it when we paused
            -- it. Dropping the override is not enough: we overwrote the engine's own
            -- screen_next and loading, so without this the transition it had already
            -- committed to simply never happens and the player has to walk into the
            -- door a second time to start a new one. That is what the one release in
            -- the dev48 capture was -- 99130 ms, i.e. whenever the player next
            -- happened to poke the door.
            if tbar.wantNext ~= nil then
                pcall(function()
                    state.screen_next = tbar.wantNext
                    state.loading = tbar.wantLoading
                end)
            end
            if DesyncLog ~= nil then
                DesyncLog.event("transition hold: " .. why, now - tbar.heldMs, key)
            end
        end
        return
    end

    if not tbar.holding then
        tbar.holding = true
        tbar.heldMs = now
        -- captured ONCE, before the override below overwrites them
        tbar.wantNext = state.screen_next
        tbar.wantLoading = state.loading
        if DesyncLog ~= nil then
            DesyncLog.event("transition hold: finished transition %d, waiting for"
                .. " the other players before leaving", key)
        end
    end
    pcall(function()
        state.screen_next = SCREEN.TRANSITION
        state.loading = FADE.NONE
    end)
end

--- Called from inputSync's PRE_UPDATE right after suppressRestartFade. The pause
--- menu's OPTIONS entry starts a REAL screen load (SCREEN.OPTIONS), and a lone
--- mid-run screen change is the classic party freeze: this machine stops feeding
--- inputs while it sits on the settings screen (every peer stalls on "waiting for
--- players"), and on the way back the level screen RE-loads and the gate
--- re-engages on a bumped sequence — which the stall detector reads as a hard
--- desync and "recovers" by warping the WHOLE PARTY onto a freshly generated
--- floor. That is the reported bug.
---
--- Kill it exactly the way the menu PAUSE is killed in inputSync's gate (pause
--- flag 1, cleared every frame so alt-tab and the pause menu can't stop the shared
--- world): refuse the screen change on its FIRST frame, before the gate reads
--- `loading`. The gate never drops, we keep recording and sending this machine's
--- input, and the party plays on exactly like a tabbed-out player standing still.
--- Settings stay fully available from the main menu, outside a run.
function module.suppressMenuScreens()
    if not runActive or not Network.isInRun() then
        return
    end
    local state = get_local_state()
    local screen = state.screen
    if screen ~= SCREEN.LEVEL and screen ~= SCREEN.TRANSITION then
        return
    end
    if not MENU_SCREENS[state.screen_next] then
        lastGoodScreenNext = state.screen_next
        return
    end
    pcall(function()
        state.screen_next = lastGoodScreenNext or screen
        state.loading = FADE.NONE
    end)
    -- tell the player why, at most once every 5s so a held button can't spam it
    if get_ms() - menuScreenNoticeMs > 5000 then
        menuScreenNoticeMs = get_ms()
        toast("Settings are locked during an online run")
    end
end

--- The post-wipe DEATH screen gets no PRE_UPDATE gate, but its restart still
--- routes through the screen loader: the host starts the next run, everyone else
--- cancels their reload. Also a safety net if a mid-run restart load somehow
--- reaches load time — skip it rather than let one machine reload to 1-1 alone.
--- @return boolean? # true to SKIP the pending restart load
local function interceptInstantRestart()
    local sessionActive = Network.isActive()
    local state = get_local_state()
    local resetFlag = 0
    pcall(function() resetFlag = state.quest_flags & QUEST_RESET end)
    -- This runs at PRE_LOAD_SCREEN, i.e. only when a screen load is actually
    -- starting, so recording the decision inputs here is cheap (a few lines per
    -- load) and it is the ONLY way to see why a restart was not claimed. Both
    -- early returns below were silent, so a restart that reached none of the
    -- branches left no trace at all: after a wipe the log went completely quiet
    -- and the machine started a solo run with nothing to explain it.
    -- NOT gated on sessionActive: that was a blind spot of its own. isActive() is
    -- only LOBBY or INGAME, so the moment the phase left those the probe fell
    -- silent — which is precisely the window a post-wipe restart happens in, and
    -- why the log showed nothing at all after `run end`. Log the PHASE too, so a
    -- silent branch can never again be mistaken for a branch that did not run.
    if get_ms() >= restartProbeMs then
        restartProbeMs = get_ms() + 400
        if DesyncLog ~= nil then
            DesyncLog.event(
                "restart probe: phase=%s inRun=%s reset=%s screen=%s screen_next=%s theme_next=%s loading=%s host=%s",
                tostring(Network.phase), tostring(Network.isInRun()),
                tostring(resetFlag ~= 0),
                tostring(state.screen), tostring(state.screen_next),
                tostring(state.theme_next), tostring(state.loading),
                tostring(Network.isHost()))
        end
    end
    if not sessionActive then
        return
    end
    if resetFlag == 0 then
        return
    end
    local screen = state.screen
    -- The DEATH screen is handled BEFORE the suppressWarpUntil guard below.
    -- After a party wipe we warp everyone back to the camp, and that warp sets
    -- suppressWarpUntil for 3 seconds. A Quick Restart pressed inside that window
    -- used to hit the guard and return early, so the local reload was NEVER
    -- suppressed and every machine restarted on its OWN — the reported "we each
    -- ended up in our own individual run". Our own camp warp raises QUEST_RESET on
    -- this screen too, so the two are told apart by DESTINATION, which is exact:
    -- a camp warp targets THEME.BASE_CAMP, a player's Quick Restart targets 1-1.
    if screen == SCREEN.DEATH then
        -- Tell the two apart by PROVENANCE, not by destination. Destination alone
        -- was ambiguous: the engine's own post-death transition also targets the
        -- camp, so `theme_next == BASE_CAMP` was true for an ordinary death and
        -- this returned early on essentially every Quick Restart pressed from the
        -- death screen -- leaving the local reload unsuppressed, which is exactly
        -- the "we each ended up in our own individual run" report. campWarpUntil is
        -- stamped only by pollMoWarp, so it means OUR warp and nothing else.
        local toCamp = false
        pcall(function() toCamp = state.theme_next == THEME.BASE_CAMP end)
        if toCamp and get_ms() < campWarpUntil then
            return -- our own post-wipe return to camp: let it through
        end
        -- ANY player's press restarts the party here, with no vote. Voting cannot
        -- work on this screen by construction: a party wipe ends the run, so
        -- onRestartVote and tallyRestartVotes both bail on their
        -- `not runActive or not Network.isInRun()` guard and DISCARD every vote —
        -- while castRestartVote has no such guard and sends anyway. The result was
        -- a press that logged "restart vote CAST", was dropped by every machine
        -- including the sender, and surfaced 20s later as "restart vote expired".
        -- Gating on the host had the same effect for everyone else: their press
        -- vanished silently.
        --
        -- A vote exists to stop one player aborting a run the others are still
        -- playing. After a wipe there is no run left to protect, so consensus is
        -- meaningless and a single press is the behaviour players expect. The
        -- server coalesces simultaneous requests into one run_start.
        hostBeginRestart() -- ask the server for a synchronized restart
        -- Suppress the LOCAL quick-restart reload on EVERY machine, the host
        -- included, and drive the restart for everyone through the one run_start
        -- path so all machines regenerate 1-1 on the SAME agreed seed. Previously
        -- the host's own reload ran on the game's restart seed while the others
        -- used the run_start seed → different worlds (mismatched level feelings,
        -- desync artefacts). run_start's warp brings the host back in too.
        pcall(function()
            state.quest_flags = state.quest_flags & ~QUEST_RESET
            if state.screen_next == SCREEN.LEVEL then
                state.screen_next = state.screen
            end
        end)
        return true
    end
    if get_ms() < suppressWarpUntil then
        return -- our own warp raised the flag
    end
    -- Restart pressed while still in the session but NO LONGER in a run. After a
    -- party wipe onDeath ends the run, and from then on NO branch claimed a
    -- restart: the DEATH branch needs SCREEN.DEATH (you are in the camp by then)
    -- and the branch below needs a live run. So the press fell through every case
    -- and the engine started a private run — the reported "it sets us in our own
    -- runs". Ask the server to restart the party instead, and skip the local load
    -- so this machine does not fork off while waiting.
    --
    -- Bounded on purpose: if the server never answers, giving up and letting the
    -- load through is far better than trapping the player on a screen that will
    -- not advance.
    if not Network.isInRun() then
        if get_ms() < awaitingRestartUntil then
            pcall(function()
                state.quest_flags = state.quest_flags & ~QUEST_RESET
            end)
            return true -- a request is already in flight; keep waiting for run_start
        end
        if lobbyRestartAttempts >= 2 then
            toast("Restart did not reach the party — starting a local run")
            return -- let it through rather than strand them
        end
        lobbyRestartAttempts = lobbyRestartAttempts + 1
        hostBeginRestart()
        pcall(function()
            state.quest_flags = state.quest_flags & ~QUEST_RESET
        end)
        return true
    end
    if Network.isInRun() and (screen == SCREEN.LEVEL or screen == SCREEN.TRANSITION) then
        -- Backup only (suppressRestartFade should have caught this already). The
        -- `state.screen_next == SCREEN.LEVEL` requirement was dropped here for the
        -- same reason as in suppressRestartFade: a content mod may point the
        -- restart somewhere that is not a LEVEL (2.5 sends it to a warp zone), and
        -- this backup then declined to fire on the exact restarts that most needed
        -- it. Pressing restart while PLAYING is the trigger; where the game wanted
        -- to send us afterwards is irrelevant, because we are cancelling it.
        pcall(function()
            state.quest_flags = state.quest_flags & ~QUEST_RESET
            state.screen_next = state.screen
            state.world_next = state.world
            state.level_next = state.level
            state.theme_next = state.theme
        end)
        restartSuppressUntil = get_ms() + 500
        if not restartVoted then
            restartVoted = true
            castRestartVote()
        end
        return true
    end
    -- Reaching here means the player asked for a restart (QUEST_RESET is set) and
    -- NO branch above claimed it, so the local reload is about to run unsuppressed
    -- and this machine will split off into its own run. Every screen we know about
    -- is handled, so this should be unreachable — say so loudly rather than let it
    -- fail silently the way the screen_next assumption above did for months.
    if Network.isInRun() and get_ms() >= unhandledRestartNoticeMs then
        unhandledRestartNoticeMs = get_ms() + 3000
        if DesyncLog ~= nil then
            DesyncLog.event(
                "restart NOT intercepted: screen=%s screen_next=%s theme_next=%s loading=%s host=%s",
                tostring(screen), tostring(state.screen_next),
                tostring(state.theme_next), tostring(state.loading),
                tostring(Network.isHost()))
        end
    end
end

--- Resend a pending restart request until the server's run_start answers it.
local function pollRestartResend()
    if restartNonce == nil then
        return
    end
    local now = get_ms()
    if now >= awaitingRestartUntil then
        restartNonce = nil -- unanswered for 10s: give up
        return
    end
    if now - restartResendMs >= 1500 then
        restartResendMs = now
        Network.requestRestart(restartNonce)
    end
end

-- -------------------------------------------------------------- camp / door

--- The camp's main door. Online it must NEVER actually open — the run always
--- begins via the synchronized run_start warp, never a lone camp exit. Every
--- attempt to intercept the enter after the fact failed: letting it enter dropped
--- the player into a solo run, cancelling the fade froze on black (the player's
--- own door-enter state kept re-driving it), and skipping the `enter` left the
--- player in the no-collision "entering" state so they fell through the floor.
--- So we make the door simply un-enterable (`can_enter -> false`, exactly like a
--- locked door: no entering state, no fade, no collision loss) and drive readying
--- up ourselves from pollReadyDoor, which watches for the door press.
--- @param door Door
local function hookMainDoor(door)
    pcall(function()
        -- Wrapped in SafeCall: this is invoked by the engine across the C++
        -- boundary, where an uncaught Lua error surfaces with NO traceback (that
        -- is the fingerprint of the rare "attempt to call a number value" seen in
        -- the Playlunky log). Routing it through SafeCall means any future error
        -- here is CAUGHT and reported WITH a traceback + this call-site name,
        -- instead of a bare unlocatable message. Returning nil on the (currently
        -- impossible) error path leaves the door vanilla — the safe default.
        door:set_pre_can_enter(function()
            -- exactly `false` (inert door) or NO value (vanilla) — never a raw
            -- SafeCall passthrough, which can hand the engine an explicit nil
            local block = SafeCall("eventSync:doorCanEnter", function()
                return Network.isActive() and not Network.isInRun()
            end)
            if block == true then
                return false -- online lobby: inert door; ready up via pollReadyDoor
            end
        end)
    end)
end

--- PUBLIC lobby only: the host starts the run automatically once every player
--- is ready. Retried on a throttle so a dropped start datagram still lands, and
--- harmless once running (the server ignores a start on an already-started room)
--- or if someone un-readies (everyoneReady goes false again).
local function pollAutoStart()
    if not Network.isActive() or Network.isInRun()
        or Network.phase ~= Network.PHASE.LOBBY then
        return
    end
    if not Network.isPublicRoom() or not Network.isHost() then
        return
    end
    if #Network.lobbyPlayers < 2 then
        -- a public match needs at least one other player: readying up alone must
        -- keep you waiting in the lobby, not drop you straight into a solo run
        return
    end
    if not everyoneReady() or not everyoneSameDest() then
        return
    end
    if get_ms() - lastAutoStartMs < 1000 then
        return
    end
    lastAutoStartMs = get_ms()
    -- everyone agrees on the door by now, so ours is the agreed destination
    Network.requestStart(myReadyDest)
end

local function pollCampDoor()
    if not doorHookPending then
        return
    end
    -- The main exit AND every camp SHORTCUT door (FLOOR_DOOR_STARTING_EXIT — the
    -- Terra doors that start a run deeper in). All of them are made inert online
    -- and drive readying up instead, so a shortcut follows exactly the same rules
    -- as a normal start rather than dropping one player into a solo run.
    local hooked = false
    for _, doorType in ipairs({ ENT_TYPE.FLOOR_DOOR_MAIN_EXIT, ENT_TYPE.FLOOR_DOOR_STARTING_EXIT }) do
        for _, uid in ipairs(get_entities_by(doorType, MASK.FLOOR, LAYER.BOTH)) do
            local door = get_entity(uid)
            if door ~= nil then
                hookMainDoor(door)
                local dest = false -- main exit: the normal 1-1 start
                if doorType == ENT_TYPE.FLOOR_DOOR_STARTING_EXIT then
                    pcall(function()
                        local w, l, t = door:get_target()
                        if w ~= nil and math.floor(w) > 0 then
                            dest = { math.floor(w), math.floor(l or 1), math.floor(t or 0) }
                        end
                    end)
                else
                    mainDoorUid = uid
                end
                campDoors[uid] = dest
                hooked = true
            end
        end
    end
    if hooked then
        doorReadyHeld = false
        doorHookPending = false
    end
end

--- Ready up in a networked lobby by pressing UP at the main door. The door is
--- inert online (can_enter -> false), so it never opens; we detect the press
--- here and do what entering used to — toggle ready (public) or ask the host to
--- start (private). Rising-edge on INPUT_DOOR (so a held press acts once) and
--- gated to the local player standing at the door. Purely local: readiness is
--- announced over the reliable channel (setReady), never the world sim.
local function pollReadyDoor()
    if not Network.isActive() or Network.isInRun()
        or Network.phase ~= Network.PHASE.LOBBY then
        doorReadyHeld = false
        return
    end
    local state = get_local_state()
    if state.screen ~= SCREEN.CAMP or next(campDoors) == nil then
        doorReadyHeld = false
        return
    end
    local player = get_player(1, false)
    if player == nil then
        doorReadyHeld = false
        return
    end
    -- which camp door are we standing at, and where does it lead? Sorted so the
    -- answer is stable if two doors ever overlap (purely local UI logic).
    local uids = {}
    for uid in pairs(campDoors) do
        uids[#uids + 1] = uid
    end
    table.sort(uids)
    local atDoor, atDest = false, nil
    for _, uid in ipairs(uids) do
        local door = get_entity(uid)
        if door ~= nil and math.abs(player.x - door.x) <= 1.0
            and math.abs(player.y - door.y) <= 1.5 then
            atDoor = true
            local dest = campDoors[uid]
            atDest = (type(dest) == "table") and dest or nil
            break
        end
    end
    local slots = state.player_inputs and state.player_inputs.player_slots or nil
    local slot = slots and slots[1] or nil
    local pressing = atDoor and slot ~= nil
        and (slot.buttons_gameplay & INPUT_DOOR) ~= 0
    if pressing and not doorReadyHeld then
        if Network.isPublicRoom() then
            -- pressing the door you are already readied at un-readies you;
            -- pressing a DIFFERENT one moves your vote to that door in one press
            if myReady and destLabel(myReadyDest) == destLabel(atDest) then
                myReady = false
                myReadyDest = nil
            else
                myReady = true
                myReadyDest = atDest
            end
            Network.setReady(myReady, myPickedChar, myReadyDest)
            toast(myReady and "Ready! The run starts once everyone is ready"
                or "Not ready — walk through the door again when you're set")
        elseif not Network.isHost() then
            toast("Only the host can start the run!")
        elseif not everyoneReady() then
            toast("Waiting for everyone to pick a character...")
        elseif not startRequested then
            startRequested = true
            toast("Starting the run!")
            -- private lobby: the host's door decides where the run begins
            myReadyDest = atDest
            Network.requestStart(myReadyDest)
        end
    end
    doorReadyHeld = pressing
end

--- After connecting, run the game's own play flow (character select, then
--- the camp). Also brings everyone back around after a party wipe.
local playFlowReadyMs = nil -- menu clean and settled since (get_ms)

--- Catch the case a screen change cannot: we are in the camp AND in a lobby, but
--- readiness was never announced because the two became true in the wrong order
--- (see announceLobbyReady). Cheap: three field reads, and it latches on sentReady
--- the moment it succeeds.
local function pollLobbyReady()
    if Network.phase ~= Network.PHASE.LOBBY or sentReady then
        return
    end
    local screen = nil
    pcall(function() screen = get_local_state().screen end)
    if screen ~= SCREEN.CAMP then
        return
    end
    announceLobbyReady()
    doorHookPending = true
end

local function pollPlayFlow()
    if launchedPlayFlow or Network.phase ~= Network.PHASE.LOBBY then
        playFlowReadyMs = nil
        return
    end
    if decideLeaveAtMs ~= nil then
        -- a give-up leave may be about to disconnect us: don't launch character
        -- select underneath it (pollGiveUpLeave decides within a few seconds)
        playFlowReadyMs = nil
        return
    end
    local state = get_local_state()
    -- Launch the play flow ONLY from the main menu, never the TITLE screen.
    -- Reaching the title means the player exited (handled in onScreenChange by a
    -- full leave); launching character select there re-used the old session's
    -- torn-down world and wedged a book on the character select.
    if state.screen ~= SCREEN.MENU or state.loading ~= FADE.NONE then
        playFlowReadyMs = nil
        return
    end
    -- coming back from a party wipe via "Exit to Menu", the death-recap book
    -- can still be animating over the menu: starting the play flow underneath
    -- it wedged the journal in an endless page-turn loop on the character
    -- select. Wait for the journal to close, then let the menu settle a beat.
    local journalOpen = false
    pcall(function()
        journalOpen = get_game_manager().journal_ui.state ~= 0
    end)
    if journalOpen then
        playFlowReadyMs = nil
        return
    end
    playFlowReadyMs = playFlowReadyMs or get_ms()
    if get_ms() - playFlowReadyMs < 1000 then
        return
    end
    playFlowReadyMs = nil
    launchedPlayFlow = true
    -- Start a clean SINGLE-player character select. A co-op player_count left over
    -- from a previous run makes the game render a phantom, empty player preview
    -- (the leftover-world "book" on CHOOSE ADVENTURER). endSession already
    -- restores this on the way out; do it again here so re-entering is always
    -- clean regardless of how we got back to the menu.
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
    toast("Pick your character!")
    play_adventure()
end

--- The death-recap journal — the stats "book" that opens when you die — can get
--- stuck open and render over the character select after: die/End Adventure ->
--- Exit to Title -> re-enter. It's a SEPARATE object from the character-select
--- screen (state.journal_ui vs state.screen_character_select), and is only ever
--- legitimately shown IN a run (LEVEL pause), in the camp lobby, or on the death
--- screen. Anywhere else in a networked session — the character select, the menu
--- during the play flow — it's the stray book and must not show.
--- @return boolean
local function journalShouldBeHidden()
    if not Network.isActive() then
        return false -- offline: leave the journal alone
    end
    local screen = get_local_state().screen
    return screen ~= SCREEN.LEVEL
        and screen ~= SCREEN.CAMP
        and screen ~= SCREEN.DEATH
end

--- Force the stray journal shut (belt: state/opacity) — the render is also
--- skipped in the RENDER_PRE_JOURNAL_PAGE hook below (suspenders), since setting
--- state alone did not stop it from drawing over CHOOSE ADVENTURER.
local function pollCloseStrayJournal()
    if not journalShouldBeHidden() then
        return
    end
    pcall(function()
        local j = get_game_manager().journal_ui
        if j == nil then
            return
        end
        j.state = 0
        j.opacity = 0
        j.fade_timer = 0
    end)
end

-- -------------------------------------------------------------- leaving

--- @param handoff boolean? # true = leave the room but keep it open for the
---   players still in the run (End Adventure); the server hands the host role on
---   instead of closing a private room. Default (nil/false) closes a private
---   room when its host backs out, as before.
local function leaveRun(handoff)
    clearRunState("leaveRun")
    InputSync.endSession()
    Network.leave(handoff)
end

--- End MY adventure mid-run: leave the run back to the lobby WITHOUT leaving the
--- session. The others keep playing (the server stands my slot still for them
--- via player_left); the run is over for everyone only once all have ended.
--- clearRunState resets launchedPlayFlow, so the normal play flow (character
--- select -> camp) brings me back to the lobby. No simulation is cancelled here,
--- so this can't desync — it reuses the proven disconnect/markGone path.
--- @param notice string|false|nil # toast to show; false = stay silent (the
---   caller will toast once it knows the outcome — see onDeath/pollGiveUpLeave)
local function endMyAdventure(notice)
    clearRunState("endMyAdventure (ON.DEATH / End Adventure)")
    InputSync.endSession()
    Network.endMyRun()
    if notice ~= false then
        toast(notice or "You ended your adventure — back to the lobby (others play on)")
    end
end

--- @param payload { slot: integer, name: string, last: { s: integer, f: integer, i: integer[] }? }
local function onPlayerLeft(payload)
    if not Network.isInRun() then
        return
    end
    local slot = math.floor(tonumber(payload.slot) or 0)
    toast(string.format("%s left — their spelunker is idling", tostring(payload.name)))
    -- payload.last is the server's final relayed input from the leaver: it lets
    -- every surviving machine converge on identical inputs for this slot before
    -- standing them still, so the departure can't fork the simulations.
    InputSync.markGone(slot, payload.last)
    -- The WORLD HOST left: hand the role to the lowest slot still playing.
    --
    -- runHostSlot is chosen once, at run start, and used to be left there for the
    -- rest of the run. When the player holding it departed, every remaining
    -- machine kept pointing at a slot that was no longer in the game, so
    -- isWorldHost() was false EVERYWHERE. Nothing that only the world host does
    -- got done: the authoritative world/seed stopped being published, and -- the
    -- reported symptom -- pollJoinAtTransition returned at its first line, so a
    -- late joiner was never folded in. A rejoin therefore worked when a non-host
    -- had left (the host was still there to pull them in) and hung forever when
    -- the HOST had left, with the returning player sat in the lobby.
    --
    -- Deterministic on every machine: player_left is an ordered reliable event and
    -- the roster it is computed from is identical everywhere.
    if slot == Network.runHostSlot then
        local promoted = InputSync.lowestActiveSlot()
        if promoted ~= nil then
            Network.runHostSlot = promoted
            if DesyncLog ~= nil then
                DesyncLog.event("world host slot %d left -> promoted slot %d", slot, promoted)
            end
        end
    end
    -- a departed player can't vote: drop their vote and re-check, so those who
    -- remain can still reach a unanimous restart
    restartVotes[slot] = nil
    tallyRestartVotes()
end

local function endRunToLobby()
    clearRunState("endRunToLobby (death recovery timed out)")
    InputSync.endSession()
    Network.backToLobby()
    toast("Run over — pick your character for the next one!")
end

local function onDeath()
    if not Network.isInRun() then
        return
    end
    -- A QUICK RESTART kills the party to do its work, so ON.DEATH fires for a
    -- restart just as it does for a real wipe. Tearing the run down here made the
    -- restart unrecoverable: `run end` runs first, runActive goes false, and every
    -- path that could have caught the restart -- suppressRestartFade,
    -- interceptInstantRestart, even the "restart NOT intercepted" notice -- is
    -- gated on still being in a run, so all of them returned at their first line.
    -- The local reload then ran unsuppressed and the player dropped into a SOLO
    -- game while the session stayed in the room. That is exactly the reported
    -- "it put me in my own game, and when I went back to camp I was still in the
    -- room", and it is why not one restart line ever reached the log.
    --
    -- Tell the two apart by the RESET flag, which only a restart raises, plus the
    -- suppression window for the case where we already consumed the flag this
    -- frame. A real wipe has neither and still ends the run below.
    local isRestart = false
    pcall(function()
        isRestart = (get_local_state().quest_flags & QUEST_RESET) ~= 0
    end)
    if isRestart or get_ms() < restartSuppressUntil then
        return -- the restart paths own this death; leave the run intact for them
    end
    -- ON.DEATH means OUR whole party is dead. That happens on a real party wipe
    -- AND when a player uses "End Adventure", which gives up by killing the
    -- party on this machine. First soft-leave immediately: the OTHERS keep
    -- playing — the server stands our slot still for them (player_left /
    -- markGone) and their machines despawn our spelunker, exactly like a
    -- disconnect. This never stalls or desyncs them (no sim is cancelled; the
    -- brief local divergence before markGone is a one-shot the checksum alarm
    -- ignores). We do NOT ask the host for a floor rescue anymore — for End
    -- Adventure that rescue relaunched/desynced the run and couldn't be told
    -- apart from a give-up.
    endMyAdventure(false) -- stay silent: pollGiveUpLeave toasts once it knows
    -- Now decide what this death meant. A real party wipe fires on EVERY
    -- machine, so all soft-leave and the server reopens the room (we stay in the
    -- lobby to restart together). A solo End Adventure fires only here, so the
    -- room keeps running for the others — in that case we leave it entirely.
    -- pollGiveUpLeave watches Network.roomStarted and resolves this.
    decideLeaveAtMs = get_ms()
end

--- Waits out a client party wipe: cleared by a rescue warp (the wipe was our
--- diverged world's artifact), by the run ending for real (host died too →
--- pollRunOver), or by the deadline — then the run is over locally as well.
local function pollDeathRecovery()
    if deathRecoveryUntil == nil then
        return
    end
    if not runActive or not Network.isInRun() then
        deathRecoveryUntil = nil
        return
    end
    if pendingWarp ~= nil or pendingMoWarp ~= nil then
        deathRecoveryUntil = nil -- a rescue warp is here; it takes over
        return
    end
    local now = get_ms()
    if now >= deathRecoveryUntil then
        deathRecoveryUntil = nil
        endRunToLobby()
        return
    end
    -- the host may still be inside its own resync rate-limit window when the
    -- first plea lands: repeat it until something answers
    if now >= deathResendMs then
        deathResendMs = now + 2500
        Network.sendEvent("resync_req", { death = 1 })
    end
end

--- "Return to Main Menu" from the lobby/camp never passed through the mid-run
--- leave path, so the session (and with it the bridge/server helpers) lived
--- on as a zombie. A lobby member who has already been through the play flow
--- and is sitting on the main menu has backed out: leave properly. The grace
--- period skips the menu moments the play flow itself passes through.
local function pollMenuExit()
    if Network.phase ~= Network.PHASE.LOBBY or not launchedPlayFlow then
        menuSinceMs = nil
        return
    end
    local screen = get_local_state().screen
    if screen ~= SCREEN.MENU and screen ~= SCREEN.TITLE then
        menuSinceMs = nil
        return
    end
    menuSinceMs = menuSinceMs or get_ms()
    if get_ms() - menuSinceMs < 3000 then
        return
    end
    menuSinceMs = nil
    toast("Left the online session")
    leaveRun()
end

--- The network session died underneath a live run (server gone, host left,
--- timeout): finish the run locally and put the player somewhere sane.
local function pollSessionAlive()
    if not runActive or Network.phase == Network.PHASE.INGAME then
        return
    end
    local wasStarted = InputSync.hasStarted()
    clearRunState("pollSessionAlive (network session gone)")
    InputSync.endSession()
    toast("Session ended — returning to camp")
    local screen = get_local_state().screen
    if wasStarted and (screen == SCREEN.LEVEL or screen == SCREEN.TRANSITION) then
        moWarp(1, 1, THEME.BASE_CAMP)
    end
end

--- The server reopened the room (someone's whole party died and reset it)
--- while WE are still mid-run: our world diverged from the one that ended.
--- Give the real party-death event a moment to arrive; if we're still playing
--- after that, follow everyone back to the lobby for the next run.
local function pollRunOver()
    if not runActive or Network.phase ~= Network.PHASE.INGAME
        or Network.roomStarted ~= false then
        runEndedNoticeMs = nil
        return
    end
    runEndedNoticeMs = runEndedNoticeMs or get_ms()
    if get_ms() - runEndedNoticeMs < 3000 then
        return
    end
    runEndedNoticeMs = nil
    toast("The run ended on another player's screen — back to camp!")
    clearRunState("pollRunOver (room reopened)")
    InputSync.endSession()
    Network.backToLobby()
    moWarp(1, 1, THEME.BASE_CAMP)
end

--- After a whole-party death we soft-left to the lobby (onDeath). Now tell the
--- two cases apart:
---   * Real party wipe — everyone died, so the server reopened the room
---     (roomStarted == false). Stay put: the group restarts together from the
---     lobby, exactly as before.
---   * Solo End Adventure — the room is still running for the others
---     (roomStarted stays true past the decision window). Leave the room
---     entirely, handing off so the players still going aren't kicked. Their
---     machines already removed our spelunker (markGone + despawn).
local function pollGiveUpLeave()
    if decideLeaveAtMs == nil then
        return
    end
    if Network.phase ~= Network.PHASE.LOBBY then
        decideLeaveAtMs = nil -- already left the session, or never reached the lobby
        return
    end
    if Network.roomStarted == false then
        -- the room reopened: everyone's party died, so it's a real wipe. Stay in
        -- the lobby and ready up — the group restarts together.
        decideLeaveAtMs = nil
        toast("Run over — pick your character for the next one!")
        return
    end
    if get_ms() - decideLeaveAtMs >= GIVEUP_DECIDE_MS then
        decideLeaveAtMs = nil
        leaveRun(true) -- hand off: the others keep playing
        toast("You left the room")
    end
end

--- Quitting to the menu mid-run (pause -> Quit/Exit) starts a fade toward MENU.
--- The moment that fade begins we STOP feeding lockstep inputs, so if we wait for
--- the fade to finish before telling the server we left (onScreenChange fires
--- only once MENU is actually reached), everyone else stalls for the whole fade
--- on "Waiting for other players...". Catch the fade at its FIRST frame (via
--- screen_next) and LEAVE right away, so the others get our player_left and
--- markGone us almost immediately — they keep playing without a freeze.
---
--- We fully leave (not a soft-leave back to the lobby): "Exit Game" means the
--- player wants out, so we disconnect (hand-off so the others keep playing) and
--- ride the fade out to the main menu, rather than getting re-launched into
--- character select. Once we're leaving, phase is IDLE so nothing pulls us back.
local function pollQuitLeave()
    if not Network.isInRun() then
        return
    end
    local state = get_local_state()
    if (state.screen == SCREEN.LEVEL or state.screen == SCREEN.TRANSITION)
        and (state.screen_next == SCREEN.MENU or state.screen_next == SCREEN.TITLE) then
        leaveRun(true) -- full leave, hand off so the rest of the lobby plays on
    end
end

local function onScreenChange()
    local screen = get_local_state().screen
    -- Reaching the TITLE screen while in a session means the player used "Exit to
    -- Title": they've quit the online game entirely. Fully leave and tear down the
    -- session (network, bridge, run state) so NOTHING leaks into the next game.
    -- This must run before the in-run/lobby handling below — without it a soft-left
    -- player (phase LOBBY after a death / End Adventure) stayed in the session at
    -- the title, and pollPlayFlow would re-launch character select over the old,
    -- torn-down world (the "book on the character select" bug that then
    -- destabilised the mod and eventually crashed it).
    if screen == SCREEN.TITLE and Network.isActive() then
        leaveRun(true) -- hand off so a public lobby carries on without us
        return
    end
    if Network.isInRun() then
        -- End Adventure mid-run: leave THIS run back to the lobby, but stay in
        -- the session and let the others keep playing (the server stands our
        -- slot still for them). The run ends for everyone only once all have
        -- ended. Falls through so a quit-to-camp still marks us ready below.
        if screen == SCREEN.MENU or screen == SCREEN.TITLE then
            endMyAdventure()
        elseif screen == SCREEN.CAMP and InputSync.hasStarted() then
            endMyAdventure()
        else
            return -- still in the run (normal level change): nothing to do
        end
    end
    if Network.phase == Network.PHASE.LOBBY and screen == SCREEN.CAMP then
        announceLobbyReady()
        doorHookPending = true
        startRequested = false
    end
end

--- Tell the server we are ready, for a camp visit that has not announced it yet.
---
--- This used to live inline in onScreenChange, which meant it could only ever run
--- ON A SCREEN CHANGE, and only if we were already in a LOBBY at that instant.
--- A player rejoining mid-run satisfies neither: leaveRun drops the phase to IDLE
--- FIRST and the warp back to the camp happens while it is still IDLE, so that
--- screen change is skipped -- and by the time they re-enter the room the phase
--- becomes LOBBY while they are ALREADY STANDING IN THE CAMP, so no further screen
--- change ever comes. The result was a player who never announced readiness at
--- all: the server's join_pending is gated on `client.ready`, so the world host
--- was never told to fold them in and they sat in the camp indefinitely. That is
--- the "they were never set into the game" report.
---
--- Now driven from a poll as well, so entering the lobby is enough on its own.
function announceLobbyReady()
        if not sentReady then
            sentReady = true
            -- trust player_select[1] only when a REAL character select ran on
            -- the way here (launchedPlayFlow). Otherwise it still holds the
            -- roster's player 1 — the HOST's character, enforced during the
            -- last run — and re-reading it turned everyone into the host on
            -- the next run (the instant-restart-to-camp path skips the
            -- character select entirely).
            if launchedPlayFlow or myPickedChar == nil then
                myPickedChar = myChosenChar()
            end
            -- PUBLIC lobby: NOT ready yet — you ready up by walking through the
            -- main door (send the char now so the roster has it either way).
            -- PRIVATE lobby: ready as soon as you reach the camp, as before.
            myReady = not Network.isPublicRoom()
            myReadyDest = nil -- back in camp: readied at the main exit again
            Network.setReady(myReady, myPickedChar, nil)
            if DesyncLog ~= nil then
                DesyncLog.event("lobby ready announced: ready=%s public=%s roomStarted=%s",
                    tostring(myReady), tostring(Network.isPublicRoom()),
                    tostring(Network.roomStarted))
            end
        end
end

Network.onEvent("run_start", onRunStart)
Network.onEvent("join_pending", onJoinPending)
Network.onEvent("player_left", onPlayerLeft)
Network.onEvent("levelseed", onLevelSeed)
Network.onEvent("resync_req", onResyncReq)
Network.onEvent("floor_warp", onFloorWarp)
Network.onEvent("restart_vote", onRestartVote)
Network.onEvent("money", onMoney)
Network.onEvent("petstyle", onPetStyle)
Network.onEvent("savesync", onSaveSync)
Network.onEvent("tready", module.onTransitionReady)

-- Global infrastructure callbacks, registered once and never cleared: they all
-- no-op unless a networked session is active.
set_callback(function()
    -- a mid-run instant-restart vote returns true to SKIP the restart load, so
    -- the presser keeps playing; that also means skipping the seed/roster setup
    local skip = SafeCall("eventSync:interceptInstantRestart", interceptInstantRestart)
    if skip == true then
        return true
    end
    -- Backstop for a local-only menu screen (settings/profile/leaderboard) that
    -- PRE_UPDATE never saw: skip the load rather than let this machine drop out of
    -- the shared simulation on its own (see suppressMenuScreens).
    local menuSkip = false
    pcall(function()
        local st = get_local_state()
        if Network.isInRun() and MENU_SCREENS[st.screen_next] then
            st.screen_next = st.screen
            menuSkip = true
        end
    end)
    if menuSkip then
        return true
    end
    -- LAST THING BEFORE THE ENGINE BLOCKS. Level generation runs no Lua of ours,
    -- so this is the final chance to tell the server we are alive but about to go
    -- quiet; without it a slow floor gets us dropped mid-run (see
    -- Network.sendLoadingNotice). Sent unconditionally and before the bracketed
    -- work below, so even a crash in that work leaves the warning already on the
    -- wire.
    pcall(Network.sendLoadingNotice)
    -- bracketed: enforceRoster rebuilds the party (spawn_player) and
    -- applyStateSync writes inventories -- native calls that can hard-crash
    if DesyncLog ~= nil then
        DesyncLog.enter("preLoadScreen")
    end
    SafeCall("eventSync:onPreLoadScreen", onPreLoadScreen)
    if DesyncLog ~= nil then
        DesyncLog.leave("preLoadScreen")
    end
end, ON.PRE_LOAD_SCREEN)

-- Out-of-run restart guard, running EVERY frame for as long as the session is
-- alive. Between a run ending and the next one starting we had no hook that could
-- see a restart at all: inputSync's PRE_UPDATE (which owns suppressRestartFade)
-- returns at `not Network.isInRun()`, and ON.PRE_LOAD_SCREEN simply does not fire
-- for the regeneration a post-wipe restart performs — the log shows
-- `>> preLevelGeneration` with no preceding `>> preLoadScreen` and no probe line.
-- So every branch added to interceptInstantRestart for this case was unreachable,
-- and the press fell straight through into a private run.
--
-- Guarded on ON.PRE_UPDATE existing: some Playlunky builds do not define it, and
-- an unguarded set_callback(fn, nil) aborts the whole chunk (see main.lua).
if ON.PRE_UPDATE ~= nil then
    set_callback(function()
        if not Network.isActive() or Network.isInRun() then
            return
        end
        local st = get_local_state()
        local reset = 0
        pcall(function() reset = st.quest_flags & QUEST_RESET end)
        if reset == 0 then
            return
        end
        if DesyncLog ~= nil and get_ms() >= restartProbeMs then
            restartProbeMs = get_ms() + 400
            DesyncLog.event(
                "out-of-run restart caught: phase=%s screen=%s screen_next=%s loading=%s",
                tostring(Network.phase), tostring(st.screen),
                tostring(st.screen_next), tostring(st.loading))
        end
        if get_ms() >= awaitingRestartUntil then
            if lobbyRestartAttempts >= 2 then
                return -- gave up asking; let the local restart run rather than strand them
            end
            lobbyRestartAttempts = lobbyRestartAttempts + 1
            hostBeginRestart()
        end
        -- Cancel the local restart itself, exactly as suppressRestartFade does for
        -- the in-run case: clear the flag and undo any fade already in flight.
        pcall(function()
            st.quest_flags = st.quest_flags & ~QUEST_RESET
            if st.loading ~= FADE.NONE then
                st.screen_next = st.screen
                st.world_next = st.world
                st.level_next = st.level
                st.theme_next = st.theme
                st.loading = FADE.NONE
            end
        end)
    end, ON.PRE_UPDATE)
end
set_callback(function()
    -- bracketed: set_pre_coffin hooks a ThemeInfo virtual and the seed/roster
    -- enforcement below writes engine state mid-load
    if DesyncLog ~= nil then
        DesyncLog.enter("preLevelGeneration")
    end
    -- install the unlock-coffin suppression BEFORE generation runs add_coffin
    SafeCall("eventSync:suppressUnlockCoffins", suppressUnlockCoffins)
    SafeCall("eventSync:onPreLevelGeneration", onPreLevelGeneration)
    if DesyncLog ~= nil then
        DesyncLog.leave("preLevelGeneration")
    end
end, ON.PRE_LEVEL_GENERATION)
set_callback(function()
    if DesyncLog ~= nil then
        DesyncLog.enter("postLevelGeneration")
    end
    SafeCall("eventSync:onPostLevelGeneration", onPostLevelGeneration)
    -- generation is over, so the unlock-coffin hook has served its purpose; release
    -- it here, the one place the ThemeInfo it sits on is guaranteed still alive
    -- (unconditional: onPostLevelGeneration has early returns, this must not)
    SafeCall("eventSync:releaseCoffinHook", releaseCoffinHook)
    if DesyncLog ~= nil then
        DesyncLog.leave("postLevelGeneration")
    end
end, ON.POST_LEVEL_GENERATION)
-- Skip rendering the journal's pages when the stray death-recap book would show
-- over a menu/character-select in a networked session. Returning true skips the
-- vanilla page render, which is what actually removes the book (forcing the
-- journal's state/opacity shut wasn't enough on its own). Guarded in case this
-- Overlunky build lacks the hook.
if ON.RENDER_PRE_JOURNAL_PAGE ~= nil then
    set_callback(function()
        -- SafeCall: engine-invoked render hook (C++ boundary → no traceback on an
        -- uncaught error). NEVER return the SafeCall result raw: on its error path
        -- it yields an explicit nil, and a raw passthrough is what Playlunky
        -- rejects as "Unexpected return type from function". Normalise to exactly
        -- `true` (skip this page) or NO value at all.
        local hide = SafeCall("eventSync:journalPreRender", journalShouldBeHidden)
        if hide == true then
            return true -- do not draw this journal page
        end
    end, ON.RENDER_PRE_JOURNAL_PAGE)
end
set_callback(function()
    if DesyncLog ~= nil then
        DesyncLog.frameMark("guiframe:eventSync")
    end
    SafeCall("eventSync:pollLobbyReady", pollLobbyReady)
    SafeCall("eventSync:pollPlayFlow", pollPlayFlow)
    SafeCall("eventSync:pollCloseStrayJournal", pollCloseStrayJournal)
    SafeCall("eventSync:pollCampDoor", pollCampDoor)
    SafeCall("eventSync:pollReadyDoor", pollReadyDoor)
    SafeCall("eventSync:pollAutoStart", pollAutoStart)
    -- death recovery reads pendingWarp, so it must observe it BEFORE
    -- applyPendingWarp consumes it on the same frame
    SafeCall("eventSync:pollDeathRecovery", pollDeathRecovery)
    SafeCall("eventSync:pollJoinAtTransition", pollJoinAtTransition)
    SafeCall("eventSync:applyPendingWarp", applyPendingWarp)
    SafeCall("eventSync:pollRestartResend", pollRestartResend)
    SafeCall("eventSync:pollRestartVote", pollRestartVote)
    SafeCall("eventSync:pollMenuExit", pollMenuExit)
    SafeCall("eventSync:pollQuitLeave", pollQuitLeave)
    SafeCall("eventSync:pollSessionAlive", pollSessionAlive)
    SafeCall("eventSync:pollRunOver", pollRunOver)
    SafeCall("eventSync:pollGiveUpLeave", pollGiveUpLeave)
    -- host keeps the next floor's seed flowing on the unreliable channel so a
    -- stalled reliable channel can't starve a non-host of it (see pollRebroadcastSeed)
    SafeCall("eventSync:pollRebroadcastSeed", pollRebroadcastSeed)
    SafeCall("eventSync:refreshBackLayerLights", refreshBackLayerLightsRender)
    -- last: execute any warp booked by the polls above (unless a load fade
    -- is in flight, in which case it waits — never warp mid-fade)
    -- host publishes its pet style (lobby included, so peers hold it before 1-1)
    SafeCall("eventSync:pollPetStyle", pollPetStyle)
    -- Owns the RELEASE as well as the broadcast, so an override cannot outlive
    -- the load it was taken for.
    SafeCall("eventSync:pollSaveSync", pollSaveSync)
    SafeCall("eventSync:pollMoWarp", pollMoWarp)
    if DesyncLog ~= nil then
        DesyncLog.frameDone("guiframe:eventSync")
    end
end, ON.GUIFRAME)
set_callback(function()
    if DesyncLog ~= nil then
        DesyncLog.frameMark("gameframe:eventSync")
    end
    SafeCall("eventSync:pollLayerTravel", pollLayerTravel)
    SafeCall("eventSync:pollBackLayerLights", pollBackLayerLights)
    SafeCall("eventSync:pollTrackMoney", pollTrackMoney)
    if DesyncLog ~= nil then
        DesyncLog.frameDone("gameframe:eventSync")
    end
end, ON.GAMEFRAME)
-- The leaked-entity sweep runs at POST_UPDATE, NOT on GAMEFRAME with the other
-- per-frame polls. GAMEFRAME fires from inside the engine's update — that is why a
-- crash there reads `IN engineUpdate` — so destroying entities from it means
-- freeing them while the engine may still be walking its own entity list. 2.5 does
-- its own destroys from inside `post_update_state_machine`, i.e. a point the
-- engine has finished with; POST_UPDATE is the equivalent for us. It fires once
-- per simulated update, exactly like GAMEFRAME, so the lockstep determinism the
-- sweep depends on is unchanged.
--
-- Bracketed with its own frame mark: this destroys engine objects, so if it ever
-- IS the thing that dies, crash_frame.txt must say so by name instead of leaving
-- it indistinguishable from the engine's own update.
if ON.POST_UPDATE ~= nil then
    set_callback(function()
        if DesyncLog ~= nil then
            DesyncLog.frameMark("postupdate:sweepParked")
        end
        SafeCall("eventSync:pollSweepParked", pollSweepParked)
        if DesyncLog ~= nil then
            DesyncLog.frameDone("postupdate:sweepParked")
        end
    end, ON.POST_UPDATE)
end
-- Illumination objects die with the level: drop every reference the moment
-- the level starts tearing down, so nothing ever touches freed engine memory
-- (that's a native access violation, not a catchable Lua error).
set_callback(function()
    -- SafeCall for consistency (engine-invoked; only assignments, but this keeps
    -- every callback body on the caught+traceable path so an uncaught,
    -- unlocatable error can no longer originate from our registered callbacks).
    SafeCall("eventSync:preLevelDestruction", function()
        -- Position lights follow no entity, so there is nothing to decouple — just
        -- drop our references before the level frees the illuminations.
        playerLights = {}
        pendingLayerTravel = {}
    end)
end, ON.PRE_LEVEL_DESTRUCTION)
set_callback(function()
    SafeCall("eventSync:onDeath", onDeath)
end, ON.DEATH)
set_callback(function()
    SafeCall("eventSync:onScreenChange", onScreenChange)
end, ON.SCREEN)

EventSync = module
return module
