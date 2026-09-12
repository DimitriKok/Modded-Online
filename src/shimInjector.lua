--- Modded Online — universal mod-determinism shim injector.
---
--- Script mods that roll math.random desync networked runs: math.random is
--- seeded per game process, so every machine rolls different dice. A live
--- server round-trip per roll is impossible (rolls happen synchronously
--- mid-frame), but the equivalent guarantee comes from seeding: re-seed
--- math.random from the SHARED adventure seed at every level generation and
--- the lockstep simulations draw identical values in identical order — the
--- server effectively controls every mod's randomness through the seed it
--- already distributes.
---
--- Each mod runs in its own isolated Lua VM, so the re-seeding has to run
--- INSIDE each mod. This module automates that: it scans enabled packs for
--- math.random usage and appends a small, clearly marked, idempotent shim
--- to their main.lua. Delete the marked block (or disable autoShim in the
--- config) to undo. Shims added this boot take effect on the NEXT launch,
--- because mods have already loaded by the time this runs.

local module = {}

local MARKER_V1 = "[ModdedOnline-DeterminismShim-v1]"
local MARKER_V2 = "[ModdedOnline-DeterminismShim-v2]"
local MARKER_V3 = "[ModdedOnline-DeterminismShim-v3]"
local MARKER_V4 = "[ModdedOnline-DeterminismShim-v4]"
local MARKER_V5 = "[ModdedOnline-DeterminismShim-v5]"
local MARKER_V6 = "[ModdedOnline-DeterminismShim-v6]"
local MARKER_V7 = "[ModdedOnline-DeterminismShim-v7]"
local MARKER_V8 = "[ModdedOnline-DeterminismShim-v8]"
local MARKER_V9 = "[ModdedOnline-DeterminismShim-v9]"
local MARKER_V10 = "[ModdedOnline-DeterminismShim-v10]"
local MARKER_V11 = "[ModdedOnline-DeterminismShim-v11]"
local MARKER_V12 = "[ModdedOnline-DeterminismShim-v12]"
local MARKER_V13 = "[ModdedOnline-DeterminismShim-v13]"
local MARKER_V14 = "[ModdedOnline-DeterminismShim-v14]"
local MARKER_V15 = "[ModdedOnline-DeterminismShim-v15]"
local MARKER_V16 = "[ModdedOnline-DeterminismShim-v16]"
local MARKER_V17 = "[ModdedOnline-DeterminismShim-v17]"
local MARKER_V18 = "[ModdedOnline-DeterminismShim-v18]"
local MARKER_V19 = "[ModdedOnline-DeterminismShim-v19]"
local MARKER_V20 = "[ModdedOnline-DeterminismShim-v20]"
local MARKER_V21 = "[ModdedOnline-DeterminismShim-v21]"
local MARKER_V22 = "[ModdedOnline-DeterminismShim-v22]"
local MARKER_V23 = "[ModdedOnline-DeterminismShim-v23]"
local MARKER_V24 = "[ModdedOnline-DeterminismShim-v24]"
local MARKER_V25 = "[ModdedOnline-DeterminismShim-v25]"
local MARKER_V26 = "[ModdedOnline-DeterminismShim-v26]"
local MARKER_V27 = "[ModdedOnline-DeterminismShim-v27]"
local MARKER = "[ModdedOnline-DeterminismShim-v28]"
local OPT_MARKER = "[ModdedOnline-OptionSync-v1]"
local PACKS_DIR = "Mods/Packs/"
-- never touched: ourselves, and packs the user maintains by hand
local SKIP = { [PackDir()] = true }

-- a pack needs the shim if it rolls its own dice, consumes the game PRNG,
-- runs logic at the machine-dependent engine-frame rate, or anchors timers
-- to the machine-dependent engine frame counter
local NEEDS_SHIM_PATTERNS = {
    "math%.random", "ON%.FRAME", "get_local_prng",
    "get_frame%s*%(", "get_ms%s*%(",
    -- mod menus that suppress player input by rewriting the input slots
    -- (handled by the late input guard, but they need the FRAME remap so
    -- their writes land on the deterministic gameplay hook)
    "buttons_gameplay%s*=",
}

-- a pack needs the OPTION-SYNC block if it has settings of its own: those feed
-- what it generates, so two players who differ build different worlds from the
-- same seed (see src/optionSync.lua). Both Playlunky's own option API and a
-- mod's home-grown one (the HD mod has its own lib/options.lua) match.
local NEEDS_OPTIONS_PATTERNS = { "register_option" }

-- PREPENDED (must run before the mod registers callbacks):
--  * remaps ON.FRAME -> ON.GAMEFRAME: engine frames tick at display rate
--    (machine-dependent, uncapped borderless especially), gameplay frames
--    tick exactly once per simulated frame — lockstep-identical everywhere.
--    This is what made per-frame perk effects (and their PRNG consumption)
--    diverge between machines.
--  * re-seeds math.random from the shared adventure seed each level, and
--    re-anchors it every SIMULATED frame so draws taken off the sim path
--    (render callbacks, frames rendered during a stall) cannot drift it.
--  * replaces get_frame with a per-SIMULATED-frame counter: the real one
--    ticks with the engine loop, which advances through loading screens,
--    pause menus and lockstep stalls by a different amount on every machine
--    — mod cooldowns anchored to it (mimic attacks etc.) fired on different
--    simulated frames per machine and silently desynced whole worlds.
-- the exact v19 payload (prepended in 1.0.38-1.0.5), removed on upgrade to
-- v20. v19 cleared a RANDOMIZER-class run plan on a new run but knew nothing
-- about the HD mod's own run plan, which a peer therefore never rebuilt.
local SHIM_V19 = "-- " .. MARKER_V19 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so ordered iteration is in place
                -- before the plan is built, and moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v23 payload (prepended in 1.0.17 only), removed on upgrade to v24.
-- v23 searched package.loaded by shape; Playlunky provides no package table.
local SHIM_V23 = "-- " .. MARKER_V23 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    -- Ordered iteration is switched on SEPARATELY from moRunPlan. They used to be
    -- the same switch, which meant a mod could only get deterministic `pairs` by
    -- also taking the prng anchors -- and those are what broke Spelunky 2.5's 1-4,
    -- so the whole package stayed off for every mod without a `level_order`. The HD
    -- mod is one of those: it builds its levels in Lua, and Lua seeds its STRING
    -- HASH per process, so every `pairs` over string keys in that generator walks a
    -- different order on each machine -- a coin flip, every floor, that no amount of
    -- seed agreement can fix.
    local moOrderedIter = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end


    -- Deterministic liquid for the ON.LEVEL pass.
    --
    -- Spelunky 2 simulates liquid across worker threads, so two machines two
    -- frames into a level do NOT agree on the exact tiles at the waterline. That
    -- would be harmless if mods only drew water; the HD mod instead makes SPAWN
    -- decisions from it, at ON.LEVEL, like this:
    --
    --   if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
    --
    -- Lua's `and` short-circuits, so the roll only happens when the liquid test
    -- passes. One tile of disagreement anywhere along a shoreline therefore
    -- changes HOW MANY times the shared prng is drawn, and every draw after it
    -- lands somewhere else -- for the rest of the floor, and into the next one.
    -- A real capture: identical seed, identical options, all ten prng streams
    -- identical at both gen[pre] AND gen[post], and then 16 vs 9 anchovies, 39 vs
    -- 38 lilypads and 2 vs 3 frogs at ON.LEVEL -- followed by every later Jungle
    -- floor differing, while every Dwelling and Ice Caves floor matched exactly
    -- (this pass returns immediately unless the theme is Jungle).
    --
    -- So answer from a snapshot taken at POST_LEVEL_GENERATION instead: zero
    -- physics updates have run at that point, which makes it a pure function of
    -- the shared seed and layout. Only ON.LEVEL callbacks see the snapshot --
    -- gameplay liquid checks (piranhas, drowning, bomb-displaced water) go
    -- straight through to the engine as before -- and only for mods that generate
    -- their own levels, so Spelunky 2.5 is untouched.
    local moLiquidSnap = nil
    local moLiquidWindow = false
    local moRealIsLiquidAt = is_liquid_at

    local function moSnapshotLiquid()
        moLiquidSnap = nil
        if not moOrderedIter or type(moRealIsLiquidAt) ~= "function" then
            return
        end
        pcall(function()
            local moLeft, moTop, moRight, moBottom = get_bounds()
            -- generous whole-tile bounds; y runs downward, so top > bottom
            moLeft, moRight = math.floor(moLeft) - 1, math.ceil(moRight) + 1
            moBottom, moTop = math.floor(moBottom) - 1, math.ceil(moTop) + 1
            local moSnap, moWet = {}, false
            for moY = moBottom, moTop do
                for moX = moLeft, moRight do
                    if moRealIsLiquidAt(moX, moY) then
                        moSnap[moX * 4096 + moY] = true
                        moWet = true
                    end
                end
            end
            -- A dry floor keeps the engine's own answer: if this level has no
            -- generated liquid at all, there is nothing to make deterministic, and
            -- falling through means a mod that adds water of its own after
            -- generation is not told the level is dry.
            if moWet then
                moLiquidSnap = moSnap
            end
        end)
    end

    is_liquid_at = function(x, y, ...)
        if moLiquidWindow and moLiquidSnap ~= nil then
            local moOk, moHit = pcall(function()
                return moLiquidSnap[math.floor(x + 0.5) * 4096 + math.floor(y + 0.5)] == true
            end)
            if moOk then
                return moHit
            end
        end
        return moRealIsLiquidAt(x, y, ...)
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LEVEL then
            -- Everything the mod does at ON.LEVEL sees the snapshot, so a spawn
            -- decision made from the waterline is the same on every machine.
            local moInner = cb
            cb = function(...)
                local moWas = moLiquidWindow
                moLiquidWindow = true
                local moRet = moInner(...)
                moLiquidWindow = moWas
                return moRet
            end
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)

    -- ------------------------------------------------ content-mod world state
    --
    -- Read-only exposure of Spelunky 2.5's own world state, for mods that keep it.
    --
    -- 2.5 advances its world ONLY when a door is taken (DoorLib ->
    -- onSp25WorldTransition) and resets it to DWELLING in resetGame(). A player
    -- folded back into a run is WARPED in, never through a door, so its copy stays
    -- on whatever resetGame left -- which is why a rejoiner hears 1-1 music on a
    -- later floor, and why its generation decisions diverge from the party's from
    -- that floor on. The engine-side state we transfer (level_count, aggro, quest
    -- and presence flags) is all correct; this is the mod's private bookkeeping,
    -- and nothing outside its Lua state could see it.
    --
    -- It is reachable without editing the mod: 2.5 imports through `require`, so
    -- every module sits in package.loaded, and 2.5 itself hands the live game
    -- instance to one of them (CrashDiagnostics.setGame -> module.game). This block
    -- runs inside the same Lua state, so that is a legitimate handle.
    --
    -- Deliberately READ-ONLY. Realigning it means choosing the right sp25World for
    -- an engine world/theme, and 2.5's custom worlds do not map onto those one to
    -- one (two different sp25 worlds both appear as a JUNGLE-themed engine world),
    -- so a write here could corrupt the route worse than leaving it stale. The
    -- report below is what a correct realignment needs first.
    -- Discovery is deliberately KEY-AGNOSTIC. v22 hard-coded
    -- package.loaded["src.crashDiagnostics"] and, when that came back empty, it
    -- returned quietly -- so a run produced no line at all and there was no way to
    -- tell "the mod keeps no such state" from "we looked in the wrong place".
    -- Playlunky is free to cache a pack's modules under whatever key it likes, so
    -- search for the SHAPE instead: a table carrying both sp25World and
    -- spelunky2World, either directly or one level down under `game` (which is
    -- where 2.5 publishes it, via CrashDiagnostics.setGame).
    local moWorldObj = nil
    local moWorldWhere = nil
    local moWorldReported = false

    local function moLooksLikeWorld(t)
        return type(t) == "table" and t.sp25World ~= nil and t.spelunky2World ~= nil
    end

    local function moFindContentWorld()
        if moWorldObj ~= nil then
            return moWorldObj
        end
        pcall(function()
            local loaded = package ~= nil and package.loaded or nil
            if type(loaded) ~= "table" then
                return
            end
            for key, mod in pairs(loaded) do
                if moLooksLikeWorld(mod) then
                    moWorldObj, moWorldWhere = mod, tostring(key)
                    return
                end
                if type(mod) == "table" and moLooksLikeWorld(mod.game) then
                    moWorldObj, moWorldWhere = mod.game, tostring(key) .. ".game"
                    return
                end
            end
        end)
        return moWorldObj
    end

    --- Read-only snapshot, or nil for a mod that keeps no such state.
    local function moContentWorldState()
        local g = moFindContentWorld()
        if g == nil then
            return nil
        end
        local snap = nil
        pcall(function()
            snap = {
                sp25 = g.sp25World,
                s2 = g.spelunky2World,
                from = g.transitionFromSp25World,
                to = g.transitionToSp25World,
                where = moWorldWhere,
            }
        end)
        return snap
    end

    --- Say ONCE what we could and could not see. A silent miss is indistinguishable
    --- from a mod that simply has no world state, and that ambiguity has cost real
    --- debugging rounds.
    local function moReportWorldSearch()
        if moWorldReported then
            return
        end
        moWorldReported = true
        pcall(function()
            local loaded = package ~= nil and package.loaded or nil
            local n, sample = 0, {}
            if type(loaded) == "table" then
                for key in pairs(loaded) do
                    n = n + 1
                    if #sample < 6 then
                        sample[#sample + 1] = tostring(key)
                    end
                end
            end
            print(string.format(
                "[ModdedOnline] content world state: NOT FOUND | package=%s loaded=%s"
                .. " modules=%d keys=[%s] Sp25GameClass=%s GameLib=%s",
                tostring(package ~= nil), tostring(type(loaded)), n,
                table.concat(sample, ","),
                tostring(rawget(_G or {}, "Sp25GameClass") ~= nil),
                tostring(rawget(_G or {}, "GameLib") ~= nil)))
        end)
    end

    MO_CONTENT_WORLD = moContentWorldState

    -- One line per floor into the Playlunky log, where a capture can be compared
    -- against the other machine's. Costs nothing for a mod without the handle.
    moRealSetCallback(function()
        pcall(function()
            local snap = moContentWorldState()
            if snap == nil then
                moReportWorldSearch()
                return
            end
            local st = get_local_state()
            print(string.format(
                "[ModdedOnline] content world state: sp25=%s s2world=%s route=%s->%s"
                .. " via %s | engine w%d-%d th%d lc=%d",
                tostring(snap.sp25), tostring(snap.s2),
                tostring(snap.from), tostring(snap.to), tostring(snap.where),
                math.floor(st.world), math.floor(st.level), math.floor(st.theme),
                math.floor(st.level_count)))
        end)
    end, ON.PRE_LEVEL_GENERATION)
    -- Registered from the prepended block, so it runs before every POST callback
    -- the mod registers -- and, more to the point, before its ON.LEVEL pass.
    moRealSetCallback(moSnapshotLiquid, ON.POST_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
            end
            -- Ordered iteration goes to run-plan mods AND to mods that generate
            -- their own levels. POSTTILE_STARTBOOL is the HD mod's own global and
            -- exists nowhere else, so this is an exact test, not a heuristic --
            -- Spelunky 2.5 has neither global and is left on precisely the
            -- behaviour it has been playing on. Switched on HERE, at ON.LOADING,
            -- which is before the first PRE_LEVEL_GENERATION on every floor.
            if not moOrderedIter and (moRunPlan or POSTTILE_STARTBOOL ~= nil) then
                moOrderedIter = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
                -- The HD mod keeps a RUN PLAN of its own: which level each
                -- "feeling" loads on (tiki village, hive, restless, rushing water,
                -- the vault, the black market entrance), whether the worm has been
                -- visited, whether the mothership has. It rebuilds the whole thing
                -- when POSTTILE_STARTBOOL is false, and the ONLY thing that clears
                -- that flag is its own ON.RESET callback -- which the machine that
                -- pressed instant restart receives and a peer warped by our ordered
                -- run_start does not. The peer then carried the DEAD run's plan into
                -- the new one, so the first floor whose theme has feelings rolled a
                -- different set on each machine and generated a completely different
                -- world from the same seed. Clear it on the new-run signal every
                -- machine agrees on, exactly like level_order above. A plain global,
                -- so mods without it are untouched.
                if POSTTILE_STARTBOOL ~= nil then
                    POSTTILE_STARTBOOL = false
                end
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v22 payload (prepended in 1.0.16 only), removed on upgrade to v23.
-- v22 looked for the content mod world state under one hard-coded
-- package.loaded key and said nothing when it was not there.
local SHIM_V22 = "-- " .. MARKER_V22 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    -- Ordered iteration is switched on SEPARATELY from moRunPlan. They used to be
    -- the same switch, which meant a mod could only get deterministic `pairs` by
    -- also taking the prng anchors -- and those are what broke Spelunky 2.5's 1-4,
    -- so the whole package stayed off for every mod without a `level_order`. The HD
    -- mod is one of those: it builds its levels in Lua, and Lua seeds its STRING
    -- HASH per process, so every `pairs` over string keys in that generator walks a
    -- different order on each machine -- a coin flip, every floor, that no amount of
    -- seed agreement can fix.
    local moOrderedIter = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end


    -- Deterministic liquid for the ON.LEVEL pass.
    --
    -- Spelunky 2 simulates liquid across worker threads, so two machines two
    -- frames into a level do NOT agree on the exact tiles at the waterline. That
    -- would be harmless if mods only drew water; the HD mod instead makes SPAWN
    -- decisions from it, at ON.LEVEL, like this:
    --
    --   if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
    --
    -- Lua's `and` short-circuits, so the roll only happens when the liquid test
    -- passes. One tile of disagreement anywhere along a shoreline therefore
    -- changes HOW MANY times the shared prng is drawn, and every draw after it
    -- lands somewhere else -- for the rest of the floor, and into the next one.
    -- A real capture: identical seed, identical options, all ten prng streams
    -- identical at both gen[pre] AND gen[post], and then 16 vs 9 anchovies, 39 vs
    -- 38 lilypads and 2 vs 3 frogs at ON.LEVEL -- followed by every later Jungle
    -- floor differing, while every Dwelling and Ice Caves floor matched exactly
    -- (this pass returns immediately unless the theme is Jungle).
    --
    -- So answer from a snapshot taken at POST_LEVEL_GENERATION instead: zero
    -- physics updates have run at that point, which makes it a pure function of
    -- the shared seed and layout. Only ON.LEVEL callbacks see the snapshot --
    -- gameplay liquid checks (piranhas, drowning, bomb-displaced water) go
    -- straight through to the engine as before -- and only for mods that generate
    -- their own levels, so Spelunky 2.5 is untouched.
    local moLiquidSnap = nil
    local moLiquidWindow = false
    local moRealIsLiquidAt = is_liquid_at

    local function moSnapshotLiquid()
        moLiquidSnap = nil
        if not moOrderedIter or type(moRealIsLiquidAt) ~= "function" then
            return
        end
        pcall(function()
            local moLeft, moTop, moRight, moBottom = get_bounds()
            -- generous whole-tile bounds; y runs downward, so top > bottom
            moLeft, moRight = math.floor(moLeft) - 1, math.ceil(moRight) + 1
            moBottom, moTop = math.floor(moBottom) - 1, math.ceil(moTop) + 1
            local moSnap, moWet = {}, false
            for moY = moBottom, moTop do
                for moX = moLeft, moRight do
                    if moRealIsLiquidAt(moX, moY) then
                        moSnap[moX * 4096 + moY] = true
                        moWet = true
                    end
                end
            end
            -- A dry floor keeps the engine's own answer: if this level has no
            -- generated liquid at all, there is nothing to make deterministic, and
            -- falling through means a mod that adds water of its own after
            -- generation is not told the level is dry.
            if moWet then
                moLiquidSnap = moSnap
            end
        end)
    end

    is_liquid_at = function(x, y, ...)
        if moLiquidWindow and moLiquidSnap ~= nil then
            local moOk, moHit = pcall(function()
                return moLiquidSnap[math.floor(x + 0.5) * 4096 + math.floor(y + 0.5)] == true
            end)
            if moOk then
                return moHit
            end
        end
        return moRealIsLiquidAt(x, y, ...)
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LEVEL then
            -- Everything the mod does at ON.LEVEL sees the snapshot, so a spawn
            -- decision made from the waterline is the same on every machine.
            local moInner = cb
            cb = function(...)
                local moWas = moLiquidWindow
                moLiquidWindow = true
                local moRet = moInner(...)
                moLiquidWindow = moWas
                return moRet
            end
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)

    -- ------------------------------------------------ content-mod world state
    --
    -- Read-only exposure of Spelunky 2.5's own world state, for mods that keep it.
    --
    -- 2.5 advances its world ONLY when a door is taken (DoorLib ->
    -- onSp25WorldTransition) and resets it to DWELLING in resetGame(). A player
    -- folded back into a run is WARPED in, never through a door, so its copy stays
    -- on whatever resetGame left -- which is why a rejoiner hears 1-1 music on a
    -- later floor, and why its generation decisions diverge from the party's from
    -- that floor on. The engine-side state we transfer (level_count, aggro, quest
    -- and presence flags) is all correct; this is the mod's private bookkeeping,
    -- and nothing outside its Lua state could see it.
    --
    -- It is reachable without editing the mod: 2.5 imports through `require`, so
    -- every module sits in package.loaded, and 2.5 itself hands the live game
    -- instance to one of them (CrashDiagnostics.setGame -> module.game). This block
    -- runs inside the same Lua state, so that is a legitimate handle.
    --
    -- Deliberately READ-ONLY. Realigning it means choosing the right sp25World for
    -- an engine world/theme, and 2.5's custom worlds do not map onto those one to
    -- one (two different sp25 worlds both appear as a JUNGLE-themed engine world),
    -- so a write here could corrupt the route worse than leaving it stale. The
    -- report below is what a correct realignment needs first.
    local function moContentWorldState()
        local ok, snap = pcall(function()
            local mod = package.loaded["src.crashDiagnostics"]
            local g = mod ~= nil and mod.game or nil
            if g == nil then
                return nil
            end
            return {
                sp25 = g.sp25World,
                s2 = g.spelunky2World,
                from = g.transitionFromSp25World,
                to = g.transitionToSp25World,
            }
        end)
        if ok then
            return snap
        end
        return nil
    end

    -- Published so anything else in this state can read it, and so a future
    -- realignment has one place to go through rather than reaching in again.
    MO_CONTENT_WORLD = moContentWorldState

    -- One line per floor into the Playlunky log, where a capture can be compared
    -- against the other machine's. Costs nothing for a mod without the handle.
    moRealSetCallback(function()
        pcall(function()
            local snap = moContentWorldState()
            if snap == nil then
                return
            end
            local st = get_local_state()
            print(string.format(
                "[ModdedOnline] content world state: sp25=%s s2world=%s route=%s->%s"
                .. " | engine w%d-%d th%d lc=%d",
                tostring(snap.sp25), tostring(snap.s2),
                tostring(snap.from), tostring(snap.to),
                math.floor(st.world), math.floor(st.level), math.floor(st.theme),
                math.floor(st.level_count)))
        end)
    end, ON.PRE_LEVEL_GENERATION)
    -- Registered from the prepended block, so it runs before every POST callback
    -- the mod registers -- and, more to the point, before its ON.LEVEL pass.
    moRealSetCallback(moSnapshotLiquid, ON.POST_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
            end
            -- Ordered iteration goes to run-plan mods AND to mods that generate
            -- their own levels. POSTTILE_STARTBOOL is the HD mod's own global and
            -- exists nowhere else, so this is an exact test, not a heuristic --
            -- Spelunky 2.5 has neither global and is left on precisely the
            -- behaviour it has been playing on. Switched on HERE, at ON.LOADING,
            -- which is before the first PRE_LEVEL_GENERATION on every floor.
            if not moOrderedIter and (moRunPlan or POSTTILE_STARTBOOL ~= nil) then
                moOrderedIter = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
                -- The HD mod keeps a RUN PLAN of its own: which level each
                -- "feeling" loads on (tiki village, hive, restless, rushing water,
                -- the vault, the black market entrance), whether the worm has been
                -- visited, whether the mothership has. It rebuilds the whole thing
                -- when POSTTILE_STARTBOOL is false, and the ONLY thing that clears
                -- that flag is its own ON.RESET callback -- which the machine that
                -- pressed instant restart receives and a peer warped by our ordered
                -- run_start does not. The peer then carried the DEAD run's plan into
                -- the new one, so the first floor whose theme has feelings rolled a
                -- different set on each machine and generated a completely different
                -- world from the same seed. Clear it on the new-run signal every
                -- machine agrees on, exactly like level_order above. A plain global,
                -- so mods without it are untouched.
                if POSTTILE_STARTBOOL ~= nil then
                    POSTTILE_STARTBOOL = false
                end
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v21 payload (prepended in 1.0.7-1.0.15), removed on upgrade to v22.
local SHIM_V21 = "-- " .. MARKER_V21 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    -- Ordered iteration is switched on SEPARATELY from moRunPlan. They used to be
    -- the same switch, which meant a mod could only get deterministic `pairs` by
    -- also taking the prng anchors -- and those are what broke Spelunky 2.5's 1-4,
    -- so the whole package stayed off for every mod without a `level_order`. The HD
    -- mod is one of those: it builds its levels in Lua, and Lua seeds its STRING
    -- HASH per process, so every `pairs` over string keys in that generator walks a
    -- different order on each machine -- a coin flip, every floor, that no amount of
    -- seed agreement can fix.
    local moOrderedIter = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end


    -- Deterministic liquid for the ON.LEVEL pass.
    --
    -- Spelunky 2 simulates liquid across worker threads, so two machines two
    -- frames into a level do NOT agree on the exact tiles at the waterline. That
    -- would be harmless if mods only drew water; the HD mod instead makes SPAWN
    -- decisions from it, at ON.LEVEL, like this:
    --
    --   if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
    --
    -- Lua's `and` short-circuits, so the roll only happens when the liquid test
    -- passes. One tile of disagreement anywhere along a shoreline therefore
    -- changes HOW MANY times the shared prng is drawn, and every draw after it
    -- lands somewhere else -- for the rest of the floor, and into the next one.
    -- A real capture: identical seed, identical options, all ten prng streams
    -- identical at both gen[pre] AND gen[post], and then 16 vs 9 anchovies, 39 vs
    -- 38 lilypads and 2 vs 3 frogs at ON.LEVEL -- followed by every later Jungle
    -- floor differing, while every Dwelling and Ice Caves floor matched exactly
    -- (this pass returns immediately unless the theme is Jungle).
    --
    -- So answer from a snapshot taken at POST_LEVEL_GENERATION instead: zero
    -- physics updates have run at that point, which makes it a pure function of
    -- the shared seed and layout. Only ON.LEVEL callbacks see the snapshot --
    -- gameplay liquid checks (piranhas, drowning, bomb-displaced water) go
    -- straight through to the engine as before -- and only for mods that generate
    -- their own levels, so Spelunky 2.5 is untouched.
    local moLiquidSnap = nil
    local moLiquidWindow = false
    local moRealIsLiquidAt = is_liquid_at

    local function moSnapshotLiquid()
        moLiquidSnap = nil
        if not moOrderedIter or type(moRealIsLiquidAt) ~= "function" then
            return
        end
        pcall(function()
            local moLeft, moTop, moRight, moBottom = get_bounds()
            -- generous whole-tile bounds; y runs downward, so top > bottom
            moLeft, moRight = math.floor(moLeft) - 1, math.ceil(moRight) + 1
            moBottom, moTop = math.floor(moBottom) - 1, math.ceil(moTop) + 1
            local moSnap, moWet = {}, false
            for moY = moBottom, moTop do
                for moX = moLeft, moRight do
                    if moRealIsLiquidAt(moX, moY) then
                        moSnap[moX * 4096 + moY] = true
                        moWet = true
                    end
                end
            end
            -- A dry floor keeps the engine's own answer: if this level has no
            -- generated liquid at all, there is nothing to make deterministic, and
            -- falling through means a mod that adds water of its own after
            -- generation is not told the level is dry.
            if moWet then
                moLiquidSnap = moSnap
            end
        end)
    end

    is_liquid_at = function(x, y, ...)
        if moLiquidWindow and moLiquidSnap ~= nil then
            local moOk, moHit = pcall(function()
                return moLiquidSnap[math.floor(x + 0.5) * 4096 + math.floor(y + 0.5)] == true
            end)
            if moOk then
                return moHit
            end
        end
        return moRealIsLiquidAt(x, y, ...)
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LEVEL then
            -- Everything the mod does at ON.LEVEL sees the snapshot, so a spawn
            -- decision made from the waterline is the same on every machine.
            local moInner = cb
            cb = function(...)
                local moWas = moLiquidWindow
                moLiquidWindow = true
                local moRet = moInner(...)
                moLiquidWindow = moWas
                return moRet
            end
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    -- Registered from the prepended block, so it runs before every POST callback
    -- the mod registers -- and, more to the point, before its ON.LEVEL pass.
    moRealSetCallback(moSnapshotLiquid, ON.POST_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
            end
            -- Ordered iteration goes to run-plan mods AND to mods that generate
            -- their own levels. POSTTILE_STARTBOOL is the HD mod's own global and
            -- exists nowhere else, so this is an exact test, not a heuristic --
            -- Spelunky 2.5 has neither global and is left on precisely the
            -- behaviour it has been playing on. Switched on HERE, at ON.LOADING,
            -- which is before the first PRE_LEVEL_GENERATION on every floor.
            if not moOrderedIter and (moRunPlan or POSTTILE_STARTBOOL ~= nil) then
                moOrderedIter = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
                -- The HD mod keeps a RUN PLAN of its own: which level each
                -- "feeling" loads on (tiki village, hive, restless, rushing water,
                -- the vault, the black market entrance), whether the worm has been
                -- visited, whether the mothership has. It rebuilds the whole thing
                -- when POSTTILE_STARTBOOL is false, and the ONLY thing that clears
                -- that flag is its own ON.RESET callback -- which the machine that
                -- pressed instant restart receives and a peer warped by our ordered
                -- run_start does not. The peer then carried the DEAD run's plan into
                -- the new one, so the first floor whose theme has feelings rolled a
                -- different set on each machine and generated a completely different
                -- world from the same seed. Clear it on the new-run signal every
                -- machine agrees on, exactly like level_order above. A plain global,
                -- so mods without it are untouched.
                if POSTTILE_STARTBOOL ~= nil then
                    POSTTILE_STARTBOOL = false
                end
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v20 payload (prepended in 1.0.6), removed on upgrade to v21. v20
-- made iteration deterministic but still let mods make spawn decisions from
-- the engine's multithreaded liquid, which is not the same on two machines.
local SHIM_V20 = "-- " .. MARKER_V20 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    -- Ordered iteration is switched on SEPARATELY from moRunPlan. They used to be
    -- the same switch, which meant a mod could only get deterministic `pairs` by
    -- also taking the prng anchors -- and those are what broke Spelunky 2.5's 1-4,
    -- so the whole package stayed off for every mod without a `level_order`. The HD
    -- mod is one of those: it builds its levels in Lua, and Lua seeds its STRING
    -- HASH per process, so every `pairs` over string keys in that generator walks a
    -- different order on each machine -- a coin flip, every floor, that no amount of
    -- seed agreement can fix.
    local moOrderedIter = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
            end
            -- Ordered iteration goes to run-plan mods AND to mods that generate
            -- their own levels. POSTTILE_STARTBOOL is the HD mod's own global and
            -- exists nowhere else, so this is an exact test, not a heuristic --
            -- Spelunky 2.5 has neither global and is left on precisely the
            -- behaviour it has been playing on. Switched on HERE, at ON.LOADING,
            -- which is before the first PRE_LEVEL_GENERATION on every floor.
            if not moOrderedIter and (moRunPlan or POSTTILE_STARTBOOL ~= nil) then
                moOrderedIter = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
                -- The HD mod keeps a RUN PLAN of its own: which level each
                -- "feeling" loads on (tiki village, hive, restless, rushing water,
                -- the vault, the black market entrance), whether the worm has been
                -- visited, whether the mothership has. It rebuilds the whole thing
                -- when POSTTILE_STARTBOOL is false, and the ONLY thing that clears
                -- that flag is its own ON.RESET callback -- which the machine that
                -- pressed instant restart receives and a peer warped by our ordered
                -- run_start does not. The peer then carried the DEAD run's plan into
                -- the new one, so the first floor whose theme has feelings rolled a
                -- different set on each machine and generated a completely different
                -- world from the same seed. Clear it on the new-run signal every
                -- machine agrees on, exactly like level_order above. A plain global,
                -- so mods without it are untouched.
                if POSTTILE_STARTBOOL ~= nil then
                    POSTTILE_STARTBOOL = false
                end
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v24 payload (prepended in 1.0.18 only), removed on upgrade to v25.
-- v24 exposed 2.5's world state but never acted on it.
local SHIM_V24 = "-- " .. MARKER_V24 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    -- Ordered iteration is switched on SEPARATELY from moRunPlan. They used to be
    -- the same switch, which meant a mod could only get deterministic `pairs` by
    -- also taking the prng anchors -- and those are what broke Spelunky 2.5's 1-4,
    -- so the whole package stayed off for every mod without a `level_order`. The HD
    -- mod is one of those: it builds its levels in Lua, and Lua seeds its STRING
    -- HASH per process, so every `pairs` over string keys in that generator walks a
    -- different order on each machine -- a coin flip, every floor, that no amount of
    -- seed agreement can fix.
    local moOrderedIter = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end


    -- Deterministic liquid for the ON.LEVEL pass.
    --
    -- Spelunky 2 simulates liquid across worker threads, so two machines two
    -- frames into a level do NOT agree on the exact tiles at the waterline. That
    -- would be harmless if mods only drew water; the HD mod instead makes SPAWN
    -- decisions from it, at ON.LEVEL, like this:
    --
    --   if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
    --
    -- Lua's `and` short-circuits, so the roll only happens when the liquid test
    -- passes. One tile of disagreement anywhere along a shoreline therefore
    -- changes HOW MANY times the shared prng is drawn, and every draw after it
    -- lands somewhere else -- for the rest of the floor, and into the next one.
    -- A real capture: identical seed, identical options, all ten prng streams
    -- identical at both gen[pre] AND gen[post], and then 16 vs 9 anchovies, 39 vs
    -- 38 lilypads and 2 vs 3 frogs at ON.LEVEL -- followed by every later Jungle
    -- floor differing, while every Dwelling and Ice Caves floor matched exactly
    -- (this pass returns immediately unless the theme is Jungle).
    --
    -- So answer from a snapshot taken at POST_LEVEL_GENERATION instead: zero
    -- physics updates have run at that point, which makes it a pure function of
    -- the shared seed and layout. Only ON.LEVEL callbacks see the snapshot --
    -- gameplay liquid checks (piranhas, drowning, bomb-displaced water) go
    -- straight through to the engine as before -- and only for mods that generate
    -- their own levels, so Spelunky 2.5 is untouched.
    local moLiquidSnap = nil
    local moLiquidWindow = false
    local moRealIsLiquidAt = is_liquid_at

    local function moSnapshotLiquid()
        moLiquidSnap = nil
        if not moOrderedIter or type(moRealIsLiquidAt) ~= "function" then
            return
        end
        pcall(function()
            local moLeft, moTop, moRight, moBottom = get_bounds()
            -- generous whole-tile bounds; y runs downward, so top > bottom
            moLeft, moRight = math.floor(moLeft) - 1, math.ceil(moRight) + 1
            moBottom, moTop = math.floor(moBottom) - 1, math.ceil(moTop) + 1
            local moSnap, moWet = {}, false
            for moY = moBottom, moTop do
                for moX = moLeft, moRight do
                    if moRealIsLiquidAt(moX, moY) then
                        moSnap[moX * 4096 + moY] = true
                        moWet = true
                    end
                end
            end
            -- A dry floor keeps the engine's own answer: if this level has no
            -- generated liquid at all, there is nothing to make deterministic, and
            -- falling through means a mod that adds water of its own after
            -- generation is not told the level is dry.
            if moWet then
                moLiquidSnap = moSnap
            end
        end)
    end

    is_liquid_at = function(x, y, ...)
        if moLiquidWindow and moLiquidSnap ~= nil then
            local moOk, moHit = pcall(function()
                return moLiquidSnap[math.floor(x + 0.5) * 4096 + math.floor(y + 0.5)] == true
            end)
            if moOk then
                return moHit
            end
        end
        return moRealIsLiquidAt(x, y, ...)
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LEVEL then
            -- Everything the mod does at ON.LEVEL sees the snapshot, so a spawn
            -- decision made from the waterline is the same on every machine.
            local moInner = cb
            cb = function(...)
                local moWas = moLiquidWindow
                moLiquidWindow = true
                local moRet = moInner(...)
                moLiquidWindow = moWas
                return moRet
            end
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moRealSetCallback(moHookWorldCapture, ON.PRE_LEVEL_GENERATION)
    moRealSetCallback(moHookWorldCapture, ON.LOADING)

    -- ------------------------------------------------ content-mod world state
    --
    -- Read-only exposure of Spelunky 2.5's own world state, for mods that keep it.
    --
    -- 2.5 advances its world ONLY when a door is taken (DoorLib ->
    -- onSp25WorldTransition) and resets it to DWELLING in resetGame(). A player
    -- folded back into a run is WARPED in, never through a door, so its copy stays
    -- on whatever resetGame left -- which is why a rejoiner hears 1-1 music on a
    -- later floor, and why its generation decisions diverge from the party's from
    -- that floor on. The engine-side state we transfer (level_count, aggro, quest
    -- and presence flags) is all correct; this is the mod's private bookkeeping,
    -- and nothing outside its Lua state could see it.
    --
    -- Playlunky gives a pack NO `package` table at all -- the v23 probe reported
    -- exactly that: `package=false loaded=nil modules=0`. So a module-registry
    -- lookup was never going to work, and both earlier attempts were built on a
    -- premise that does not hold here.
    --
    -- What the same probe did confirm is that 2.5 publishes its CLASS as a global
    -- (Sp25GameClass=true). Every instance is `setmetatable({}, gameClass)`, so the
    -- class is the __index of the live object: wrapping one of its per-floor methods
    -- hands us `self`, the instance itself, without editing the mod. newLevelHooks
    -- is called once per floor from 2.5's own PRE_LEVEL_GENERATION, which is the
    -- earliest reliable point.
    --
    -- Still READ-ONLY: this captures a reference and reports it. Realigning 2.5's
    -- world means choosing the right sp25 world for an engine world/theme, and its
    -- custom worlds do not map one-to-one onto those.
    local moWorldObj = nil
    local moWorldWhere = nil
    local moWorldHooked = false
    local moWorldReported = false

    local function moHookWorldCapture()
        if moWorldHooked then
            return
        end
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            if type(cls) ~= "table" or type(cls.newLevelHooks) ~= "function" then
                return -- not loaded yet, or a mod without this shape
            end
            local moRealNewLevelHooks = cls.newLevelHooks
            cls.newLevelHooks = function(self, ...)
                moWorldObj = self
                moWorldWhere = "Sp25GameClass:newLevelHooks"
                return moRealNewLevelHooks(self, ...)
            end
            moWorldHooked = true
        end)
    end

    --- Read-only snapshot, or nil until the instance has been seen.
    local function moContentWorldState()
        local g = moWorldObj
        if g == nil then
            return nil
        end
        local snap = nil
        pcall(function()
            snap = {
                sp25 = g.sp25World,
                s2 = g.spelunky2World,
                from = g.transitionFromSp25World,
                to = g.transitionToSp25World,
                where = moWorldWhere,
            }
        end)
        return snap
    end

    --- Say ONCE why nothing was found. A silent miss is indistinguishable from a mod
    --- that keeps no world state, and that ambiguity has cost real debugging rounds.
    local function moReportWorldSearch()
        if moWorldReported then
            return
        end
        moWorldReported = true
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            print(string.format(
                "[ModdedOnline] content world state: NOT FOUND | class=%s newLevelHooks=%s"
                .. " hooked=%s package=%s",
                tostring(cls ~= nil),
                tostring(type(cls) == "table" and type(cls.newLevelHooks) or "n/a"),
                tostring(moWorldHooked), tostring(package ~= nil)))
        end)
    end

    MO_CONTENT_WORLD = moContentWorldState

    -- One line per floor into the Playlunky log, where a capture can be compared
    -- against the other machine's. Costs nothing for a mod without the handle.
    moRealSetCallback(function()
        pcall(function()
            local snap = moContentWorldState()
            if snap == nil then
                moReportWorldSearch()
                return
            end
            local st = get_local_state()
            print(string.format(
                "[ModdedOnline] content world state: sp25=%s s2world=%s route=%s->%s"
                .. " via %s | engine w%d-%d th%d lc=%d",
                tostring(snap.sp25), tostring(snap.s2),
                tostring(snap.from), tostring(snap.to), tostring(snap.where),
                math.floor(st.world), math.floor(st.level), math.floor(st.theme),
                math.floor(st.level_count)))
        end)
    end, ON.POST_LEVEL_GENERATION)
    -- Registered from the prepended block, so it runs before every POST callback
    -- the mod registers -- and, more to the point, before its ON.LEVEL pass.
    moRealSetCallback(moSnapshotLiquid, ON.POST_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
            end
            -- Ordered iteration goes to run-plan mods AND to mods that generate
            -- their own levels. POSTTILE_STARTBOOL is the HD mod's own global and
            -- exists nowhere else, so this is an exact test, not a heuristic --
            -- Spelunky 2.5 has neither global and is left on precisely the
            -- behaviour it has been playing on. Switched on HERE, at ON.LOADING,
            -- which is before the first PRE_LEVEL_GENERATION on every floor.
            if not moOrderedIter and (moRunPlan or POSTTILE_STARTBOOL ~= nil) then
                moOrderedIter = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
                -- The HD mod keeps a RUN PLAN of its own: which level each
                -- "feeling" loads on (tiki village, hive, restless, rushing water,
                -- the vault, the black market entrance), whether the worm has been
                -- visited, whether the mothership has. It rebuilds the whole thing
                -- when POSTTILE_STARTBOOL is false, and the ONLY thing that clears
                -- that flag is its own ON.RESET callback -- which the machine that
                -- pressed instant restart receives and a peer warped by our ordered
                -- run_start does not. The peer then carried the DEAD run's plan into
                -- the new one, so the first floor whose theme has feelings rolled a
                -- different set on each machine and generated a completely different
                -- world from the same seed. Clear it on the new-run signal every
                -- machine agrees on, exactly like level_order above. A plain global,
                -- so mods without it are untouched.
                if POSTTILE_STARTBOOL ~= nil then
                    POSTTILE_STARTBOOL = false
                end
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v25 payload (prepended in 1.0.19 only), removed on upgrade to v26.
-- v25 registered moHookWorldCapture BEFORE declaring it, so Playlunky got a nil
-- callback: a boot-time Lua error, and the capture never ran.
local SHIM_V25 = "-- " .. MARKER_V25 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    -- Ordered iteration is switched on SEPARATELY from moRunPlan. They used to be
    -- the same switch, which meant a mod could only get deterministic `pairs` by
    -- also taking the prng anchors -- and those are what broke Spelunky 2.5's 1-4,
    -- so the whole package stayed off for every mod without a `level_order`. The HD
    -- mod is one of those: it builds its levels in Lua, and Lua seeds its STRING
    -- HASH per process, so every `pairs` over string keys in that generator walks a
    -- different order on each machine -- a coin flip, every floor, that no amount of
    -- seed agreement can fix.
    local moOrderedIter = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end


    -- Deterministic liquid for the ON.LEVEL pass.
    --
    -- Spelunky 2 simulates liquid across worker threads, so two machines two
    -- frames into a level do NOT agree on the exact tiles at the waterline. That
    -- would be harmless if mods only drew water; the HD mod instead makes SPAWN
    -- decisions from it, at ON.LEVEL, like this:
    --
    --   if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
    --
    -- Lua's `and` short-circuits, so the roll only happens when the liquid test
    -- passes. One tile of disagreement anywhere along a shoreline therefore
    -- changes HOW MANY times the shared prng is drawn, and every draw after it
    -- lands somewhere else -- for the rest of the floor, and into the next one.
    -- A real capture: identical seed, identical options, all ten prng streams
    -- identical at both gen[pre] AND gen[post], and then 16 vs 9 anchovies, 39 vs
    -- 38 lilypads and 2 vs 3 frogs at ON.LEVEL -- followed by every later Jungle
    -- floor differing, while every Dwelling and Ice Caves floor matched exactly
    -- (this pass returns immediately unless the theme is Jungle).
    --
    -- So answer from a snapshot taken at POST_LEVEL_GENERATION instead: zero
    -- physics updates have run at that point, which makes it a pure function of
    -- the shared seed and layout. Only ON.LEVEL callbacks see the snapshot --
    -- gameplay liquid checks (piranhas, drowning, bomb-displaced water) go
    -- straight through to the engine as before -- and only for mods that generate
    -- their own levels, so Spelunky 2.5 is untouched.
    local moLiquidSnap = nil
    local moLiquidWindow = false
    local moRealIsLiquidAt = is_liquid_at

    local function moSnapshotLiquid()
        moLiquidSnap = nil
        if not moOrderedIter or type(moRealIsLiquidAt) ~= "function" then
            return
        end
        pcall(function()
            local moLeft, moTop, moRight, moBottom = get_bounds()
            -- generous whole-tile bounds; y runs downward, so top > bottom
            moLeft, moRight = math.floor(moLeft) - 1, math.ceil(moRight) + 1
            moBottom, moTop = math.floor(moBottom) - 1, math.ceil(moTop) + 1
            local moSnap, moWet = {}, false
            for moY = moBottom, moTop do
                for moX = moLeft, moRight do
                    if moRealIsLiquidAt(moX, moY) then
                        moSnap[moX * 4096 + moY] = true
                        moWet = true
                    end
                end
            end
            -- A dry floor keeps the engine's own answer: if this level has no
            -- generated liquid at all, there is nothing to make deterministic, and
            -- falling through means a mod that adds water of its own after
            -- generation is not told the level is dry.
            if moWet then
                moLiquidSnap = moSnap
            end
        end)
    end

    is_liquid_at = function(x, y, ...)
        if moLiquidWindow and moLiquidSnap ~= nil then
            local moOk, moHit = pcall(function()
                return moLiquidSnap[math.floor(x + 0.5) * 4096 + math.floor(y + 0.5)] == true
            end)
            if moOk then
                return moHit
            end
        end
        return moRealIsLiquidAt(x, y, ...)
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LEVEL then
            -- Everything the mod does at ON.LEVEL sees the snapshot, so a spawn
            -- decision made from the waterline is the same on every machine.
            local moInner = cb
            cb = function(...)
                local moWas = moLiquidWindow
                moLiquidWindow = true
                local moRet = moInner(...)
                moLiquidWindow = moWas
                return moRet
            end
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moRealSetCallback(moHookWorldCapture, ON.PRE_LEVEL_GENERATION)
    moRealSetCallback(moHookWorldCapture, ON.LOADING)

    -- ------------------------------------------------ content-mod world state
    --
    -- Read-only exposure of Spelunky 2.5's own world state, for mods that keep it.
    --
    -- 2.5 advances its world ONLY when a door is taken (DoorLib ->
    -- onSp25WorldTransition) and resets it to DWELLING in resetGame(). A player
    -- folded back into a run is WARPED in, never through a door, so its copy stays
    -- on whatever resetGame left -- which is why a rejoiner hears 1-1 music on a
    -- later floor, and why its generation decisions diverge from the party's from
    -- that floor on. The engine-side state we transfer (level_count, aggro, quest
    -- and presence flags) is all correct; this is the mod's private bookkeeping,
    -- and nothing outside its Lua state could see it.
    --
    -- Playlunky gives a pack NO `package` table at all -- the v23 probe reported
    -- exactly that: `package=false loaded=nil modules=0`. So a module-registry
    -- lookup was never going to work, and both earlier attempts were built on a
    -- premise that does not hold here.
    --
    -- What the same probe did confirm is that 2.5 publishes its CLASS as a global
    -- (Sp25GameClass=true). Every instance is `setmetatable({}, gameClass)`, so the
    -- class is the __index of the live object: wrapping one of its per-floor methods
    -- hands us `self`, the instance itself, without editing the mod. newLevelHooks
    -- is called once per floor from 2.5's own PRE_LEVEL_GENERATION, which is the
    -- earliest reliable point.
    --
    -- v25 ACTS on it, but only on the new-run signal every machine agrees on (the
    -- ON.LOADING block further down) and only through the mod's own resetGame().
    -- Realigning it MID-RUN is still not attempted: that would mean choosing the
    -- right sp25 world for an engine world/theme, and 2.5's custom worlds do not
    -- map one-to-one onto those.
    local moWorldObj = nil
    local moWorldResets = 0
    local moWorldWhere = nil
    local moWorldHooked = false
    local moWorldReported = false

    local function moHookWorldCapture()
        if moWorldHooked then
            return
        end
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            if type(cls) ~= "table" or type(cls.newLevelHooks) ~= "function" then
                return -- not loaded yet, or a mod without this shape
            end
            local moRealNewLevelHooks = cls.newLevelHooks
            cls.newLevelHooks = function(self, ...)
                moWorldObj = self
                moWorldWhere = "Sp25GameClass:newLevelHooks"
                return moRealNewLevelHooks(self, ...)
            end
            moWorldHooked = true
        end)
    end

    --- Read-only snapshot, or nil until the instance has been seen.
    local function moContentWorldState()
        local g = moWorldObj
        if g == nil then
            return nil
        end
        local snap = nil
        pcall(function()
            snap = {
                sp25 = g.sp25World,
                s2 = g.spelunky2World,
                from = g.transitionFromSp25World,
                to = g.transitionToSp25World,
                where = moWorldWhere,
                resets = moWorldResets,
            }
        end)
        return snap
    end

    --- Say ONCE why nothing was found. A silent miss is indistinguishable from a mod
    --- that keeps no world state, and that ambiguity has cost real debugging rounds.
    local function moReportWorldSearch()
        if moWorldReported then
            return
        end
        moWorldReported = true
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            print(string.format(
                "[ModdedOnline] content world state: NOT FOUND | class=%s newLevelHooks=%s"
                .. " hooked=%s package=%s",
                tostring(cls ~= nil),
                tostring(type(cls) == "table" and type(cls.newLevelHooks) or "n/a"),
                tostring(moWorldHooked), tostring(package ~= nil)))
        end)
    end

    --- Spelunky 2.5 keeps ONE game object for the whole launch (its main.lua does
    --- `local game = Sp25GameClass:construct()` once), so its world bookkeeping, the
    --- hooks it installs and its entity-DB tuning all outlive a run. Its own resets
    --- hang off ON.RESET / ON.CAMP / death / a QUEST_FLAGS.RESET seen at
    --- PRE_LOAD_SCREEN -- and a machine that Modded Online WARPS into a run receives
    --- none of those. A player who has already played this launch therefore starts
    --- the shared run carrying the previous run's world, hooks and tuning, and
    --- generates a different floor from the same seed than a player who just booted
    --- the game. In singleplayer the same leak is what makes the textures wrong after
    --- title -> new run.
    ---
    --- The repair is the mod's OWN new-run reset -- unhookAll, restoreEntityDb, back
    --- to world one -- invoked on the new-run signal every machine sees on the same
    --- lockstep frame. It runs on EVERY machine, not only the stale one: an equaliser
    --- that runs in one place just moves the difference somewhere else.
    ---
    --- resetGame() picks WARPZONE over DWELLING when it is called from a level and
    --- 2.5's "Warp Zone (after first restart)" option is on. Both inputs are the same
    --- on every machine at this point (peers transition together, and the option is
    --- synced), so the branch resolves identically -- and it can only ever be reached
    --- from the second run of a launch onward, which is what that option says.
    local function moResetContentWorld(seedFirst)
        local g = moWorldObj
        if g == nil or type(g.resetGame) ~= "function" then
            return -- nothing captured, or a mod without this shape
        end
        local carried = nil
        pcall(function() carried = g.spelunky2World end)
        local ok, err = pcall(function() g:resetGame() end)
        if ok then
            moWorldResets = moWorldResets + 1
            pcall(function()
                print(string.format(
                    "[ModdedOnline] new run %08X: ran 2.5's own resetGame() -- carried"
                    .. " s2world=%s, now sp25=%s s2world=%s (reset #%d)",
                    math.floor(seedFirst or 0), tostring(carried),
                    tostring(g.sp25World), tostring(g.spelunky2World), moWorldResets))
            end)
        else
            pcall(function()
                print(string.format(
                    "[ModdedOnline] 2.5 resetGame() failed, world state left as it was: %s",
                    tostring(err)))
            end)
        end
    end

    MO_CONTENT_WORLD = moContentWorldState

    -- One line per floor into the Playlunky log, where a capture can be compared
    -- against the other machine's. Costs nothing for a mod without the handle.
    moRealSetCallback(function()
        pcall(function()
            local snap = moContentWorldState()
            if snap == nil then
                moReportWorldSearch()
                return
            end
            local st = get_local_state()
            print(string.format(
                "[ModdedOnline] content world state: sp25=%s s2world=%s route=%s->%s"
                .. " via %s | engine w%d-%d th%d lc=%d resets=%d",
                tostring(snap.sp25), tostring(snap.s2),
                tostring(snap.from), tostring(snap.to), tostring(snap.where),
                math.floor(st.world), math.floor(st.level), math.floor(st.theme),
                math.floor(st.level_count), snap.resets or 0))
        end)
    end, ON.POST_LEVEL_GENERATION)
    -- Registered from the prepended block, so it runs before every POST callback
    -- the mod registers -- and, more to the point, before its ON.LEVEL pass.
    moRealSetCallback(moSnapshotLiquid, ON.POST_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
            end
            -- Ordered iteration goes to run-plan mods AND to mods that generate
            -- their own levels. POSTTILE_STARTBOOL is the HD mod's own global and
            -- exists nowhere else, so this is an exact test, not a heuristic --
            -- Spelunky 2.5 has neither global and is left on precisely the
            -- behaviour it has been playing on. Switched on HERE, at ON.LOADING,
            -- which is before the first PRE_LEVEL_GENERATION on every floor.
            if not moOrderedIter and (moRunPlan or POSTTILE_STARTBOOL ~= nil) then
                moOrderedIter = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
                -- The HD mod keeps a RUN PLAN of its own: which level each
                -- "feeling" loads on (tiki village, hive, restless, rushing water,
                -- the vault, the black market entrance), whether the worm has been
                -- visited, whether the mothership has. It rebuilds the whole thing
                -- when POSTTILE_STARTBOOL is false, and the ONLY thing that clears
                -- that flag is its own ON.RESET callback -- which the machine that
                -- pressed instant restart receives and a peer warped by our ordered
                -- run_start does not. The peer then carried the DEAD run's plan into
                -- the new one, so the first floor whose theme has feelings rolled a
                -- different set on each machine and generated a completely different
                -- world from the same seed. Clear it on the new-run signal every
                -- machine agrees on, exactly like level_order above. A plain global,
                -- so mods without it are untouched.
                if POSTTILE_STARTBOOL ~= nil then
                    POSTTILE_STARTBOOL = false
                end
                -- Spelunky 2.5's carried-over game object: the same class of bug as
                -- the two above, and the one that made a player who had already
                -- played this launch desync from a player who had just booted.
                moResetContentWorld(first)
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v26 payload (prepended in 1.0.20 only), removed on upgrade to v27.
-- v26 could read 2.5's world but had no way to receive one from another machine.
local SHIM_V26 = "-- " .. MARKER_V26 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    -- Ordered iteration is switched on SEPARATELY from moRunPlan. They used to be
    -- the same switch, which meant a mod could only get deterministic `pairs` by
    -- also taking the prng anchors -- and those are what broke Spelunky 2.5's 1-4,
    -- so the whole package stayed off for every mod without a `level_order`. The HD
    -- mod is one of those: it builds its levels in Lua, and Lua seeds its STRING
    -- HASH per process, so every `pairs` over string keys in that generator walks a
    -- different order on each machine -- a coin flip, every floor, that no amount of
    -- seed agreement can fix.
    local moOrderedIter = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end


    -- Deterministic liquid for the ON.LEVEL pass.
    --
    -- Spelunky 2 simulates liquid across worker threads, so two machines two
    -- frames into a level do NOT agree on the exact tiles at the waterline. That
    -- would be harmless if mods only drew water; the HD mod instead makes SPAWN
    -- decisions from it, at ON.LEVEL, like this:
    --
    --   if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
    --
    -- Lua's `and` short-circuits, so the roll only happens when the liquid test
    -- passes. One tile of disagreement anywhere along a shoreline therefore
    -- changes HOW MANY times the shared prng is drawn, and every draw after it
    -- lands somewhere else -- for the rest of the floor, and into the next one.
    -- A real capture: identical seed, identical options, all ten prng streams
    -- identical at both gen[pre] AND gen[post], and then 16 vs 9 anchovies, 39 vs
    -- 38 lilypads and 2 vs 3 frogs at ON.LEVEL -- followed by every later Jungle
    -- floor differing, while every Dwelling and Ice Caves floor matched exactly
    -- (this pass returns immediately unless the theme is Jungle).
    --
    -- So answer from a snapshot taken at POST_LEVEL_GENERATION instead: zero
    -- physics updates have run at that point, which makes it a pure function of
    -- the shared seed and layout. Only ON.LEVEL callbacks see the snapshot --
    -- gameplay liquid checks (piranhas, drowning, bomb-displaced water) go
    -- straight through to the engine as before -- and only for mods that generate
    -- their own levels, so Spelunky 2.5 is untouched.
    local moLiquidSnap = nil
    local moLiquidWindow = false
    local moRealIsLiquidAt = is_liquid_at

    local function moSnapshotLiquid()
        moLiquidSnap = nil
        if not moOrderedIter or type(moRealIsLiquidAt) ~= "function" then
            return
        end
        pcall(function()
            local moLeft, moTop, moRight, moBottom = get_bounds()
            -- generous whole-tile bounds; y runs downward, so top > bottom
            moLeft, moRight = math.floor(moLeft) - 1, math.ceil(moRight) + 1
            moBottom, moTop = math.floor(moBottom) - 1, math.ceil(moTop) + 1
            local moSnap, moWet = {}, false
            for moY = moBottom, moTop do
                for moX = moLeft, moRight do
                    if moRealIsLiquidAt(moX, moY) then
                        moSnap[moX * 4096 + moY] = true
                        moWet = true
                    end
                end
            end
            -- A dry floor keeps the engine's own answer: if this level has no
            -- generated liquid at all, there is nothing to make deterministic, and
            -- falling through means a mod that adds water of its own after
            -- generation is not told the level is dry.
            if moWet then
                moLiquidSnap = moSnap
            end
        end)
    end

    is_liquid_at = function(x, y, ...)
        if moLiquidWindow and moLiquidSnap ~= nil then
            local moOk, moHit = pcall(function()
                return moLiquidSnap[math.floor(x + 0.5) * 4096 + math.floor(y + 0.5)] == true
            end)
            if moOk then
                return moHit
            end
        end
        return moRealIsLiquidAt(x, y, ...)
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LEVEL then
            -- Everything the mod does at ON.LEVEL sees the snapshot, so a spawn
            -- decision made from the waterline is the same on every machine.
            local moInner = cb
            cb = function(...)
                local moWas = moLiquidWindow
                moLiquidWindow = true
                local moRet = moInner(...)
                moLiquidWindow = moWas
                return moRet
            end
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)

    -- ------------------------------------------------ content-mod world state
    --
    -- Read-only exposure of Spelunky 2.5's own world state, for mods that keep it.
    --
    -- 2.5 advances its world ONLY when a door is taken (DoorLib ->
    -- onSp25WorldTransition) and resets it to DWELLING in resetGame(). A player
    -- folded back into a run is WARPED in, never through a door, so its copy stays
    -- on whatever resetGame left -- which is why a rejoiner hears 1-1 music on a
    -- later floor, and why its generation decisions diverge from the party's from
    -- that floor on. The engine-side state we transfer (level_count, aggro, quest
    -- and presence flags) is all correct; this is the mod's private bookkeeping,
    -- and nothing outside its Lua state could see it.
    --
    -- Playlunky gives a pack NO `package` table at all -- the v23 probe reported
    -- exactly that: `package=false loaded=nil modules=0`. So a module-registry
    -- lookup was never going to work, and both earlier attempts were built on a
    -- premise that does not hold here.
    --
    -- What the same probe did confirm is that 2.5 publishes its CLASS as a global
    -- (Sp25GameClass=true). Every instance is `setmetatable({}, gameClass)`, so the
    -- class is the __index of the live object: wrapping one of its per-floor methods
    -- hands us `self`, the instance itself, without editing the mod. newLevelHooks
    -- is called once per floor from 2.5's own PRE_LEVEL_GENERATION, which is the
    -- earliest reliable point.
    --
    -- v25 ACTS on it, but only on the new-run signal every machine agrees on (the
    -- ON.LOADING block further down) and only through the mod's own resetGame().
    -- Realigning it MID-RUN is still not attempted: that would mean choosing the
    -- right sp25 world for an engine world/theme, and 2.5's custom worlds do not
    -- map one-to-one onto those.
    local moWorldObj = nil
    local moWorldResets = 0
    local moWorldWhere = nil
    local moWorldHooked = false
    local moWorldReported = false

    local function moHookWorldCapture()
        if moWorldHooked then
            return
        end
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            if type(cls) ~= "table" or type(cls.newLevelHooks) ~= "function" then
                return -- not loaded yet, or a mod without this shape
            end
            local moRealNewLevelHooks = cls.newLevelHooks
            cls.newLevelHooks = function(self, ...)
                moWorldObj = self
                moWorldWhere = "Sp25GameClass:newLevelHooks"
                return moRealNewLevelHooks(self, ...)
            end
            moWorldHooked = true
        end)
    end

    --- Read-only snapshot, or nil until the instance has been seen.
    local function moContentWorldState()
        local g = moWorldObj
        if g == nil then
            return nil
        end
        local snap = nil
        pcall(function()
            snap = {
                sp25 = g.sp25World,
                s2 = g.spelunky2World,
                from = g.transitionFromSp25World,
                to = g.transitionToSp25World,
                where = moWorldWhere,
                resets = moWorldResets,
            }
        end)
        return snap
    end

    --- Say ONCE why nothing was found. A silent miss is indistinguishable from a mod
    --- that keeps no world state, and that ambiguity has cost real debugging rounds.
    local function moReportWorldSearch()
        if moWorldReported then
            return
        end
        moWorldReported = true
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            print(string.format(
                "[ModdedOnline] content world state: NOT FOUND | class=%s newLevelHooks=%s"
                .. " hooked=%s package=%s",
                tostring(cls ~= nil),
                tostring(type(cls) == "table" and type(cls.newLevelHooks) or "n/a"),
                tostring(moWorldHooked), tostring(package ~= nil)))
        end)
    end

    --- Spelunky 2.5 keeps ONE game object for the whole launch (its main.lua does
    --- `local game = Sp25GameClass:construct()` once), so its world bookkeeping, the
    --- hooks it installs and its entity-DB tuning all outlive a run. Its own resets
    --- hang off ON.RESET / ON.CAMP / death / a QUEST_FLAGS.RESET seen at
    --- PRE_LOAD_SCREEN -- and a machine that Modded Online WARPS into a run receives
    --- none of those. A player who has already played this launch therefore starts
    --- the shared run carrying the previous run's world, hooks and tuning, and
    --- generates a different floor from the same seed than a player who just booted
    --- the game. In singleplayer the same leak is what makes the textures wrong after
    --- title -> new run.
    ---
    --- The repair is the mod's OWN new-run reset -- unhookAll, restoreEntityDb, back
    --- to world one -- invoked on the new-run signal every machine sees on the same
    --- lockstep frame. It runs on EVERY machine, not only the stale one: an equaliser
    --- that runs in one place just moves the difference somewhere else.
    ---
    --- resetGame() picks WARPZONE over DWELLING when it is called from a level and
    --- 2.5's "Warp Zone (after first restart)" option is on. Both inputs are the same
    --- on every machine at this point (peers transition together, and the option is
    --- synced), so the branch resolves identically -- and it can only ever be reached
    --- from the second run of a launch onward, which is what that option says.
    local function moResetContentWorld(seedFirst)
        local g = moWorldObj
        if g == nil or type(g.resetGame) ~= "function" then
            return -- nothing captured, or a mod without this shape
        end
        local carried = nil
        pcall(function() carried = g.spelunky2World end)
        local ok, err = pcall(function() g:resetGame() end)
        if ok then
            moWorldResets = moWorldResets + 1
            pcall(function()
                print(string.format(
                    "[ModdedOnline] new run %08X: ran 2.5's own resetGame() -- carried"
                    .. " s2world=%s, now sp25=%s s2world=%s (reset #%d)",
                    math.floor(seedFirst or 0), tostring(carried),
                    tostring(g.sp25World), tostring(g.spelunky2World), moWorldResets))
            end)
        else
            pcall(function()
                print(string.format(
                    "[ModdedOnline] 2.5 resetGame() failed, world state left as it was: %s",
                    tostring(err)))
            end)
        end
    end

    MO_CONTENT_WORLD = moContentWorldState

    -- Registered HERE, below the declarations. In v25 these two sat forty lines
    -- higher, above `local function moHookWorldCapture`, so the name resolved as a
    -- global and Playlunky was handed `nil` -- which it accepted and then raised
    -- "attempt to call a nil value" (with an empty traceback, because the call comes
    -- from the host, not from Lua) the first time it fired. The capture never ran, so
    -- the reset below it never had an instance to reset either. Anywhere inside this
    -- block is still ahead of every callback the mod registers: the whole thing is
    -- prepended to its main.lua.
    moRealSetCallback(moHookWorldCapture, ON.PRE_LEVEL_GENERATION)
    moRealSetCallback(moHookWorldCapture, ON.LOADING)

    -- One line per floor into the Playlunky log, where a capture can be compared
    -- against the other machine's. Costs nothing for a mod without the handle.
    moRealSetCallback(function()
        pcall(function()
            local snap = moContentWorldState()
            if snap == nil then
                moReportWorldSearch()
                return
            end
            local st = get_local_state()
            print(string.format(
                "[ModdedOnline] content world state: sp25=%s s2world=%s route=%s->%s"
                .. " via %s | engine w%d-%d th%d lc=%d resets=%d",
                tostring(snap.sp25), tostring(snap.s2),
                tostring(snap.from), tostring(snap.to), tostring(snap.where),
                math.floor(st.world), math.floor(st.level), math.floor(st.theme),
                math.floor(st.level_count), snap.resets or 0))
        end)
    end, ON.POST_LEVEL_GENERATION)
    -- Registered from the prepended block, so it runs before every POST callback
    -- the mod registers -- and, more to the point, before its ON.LEVEL pass.
    moRealSetCallback(moSnapshotLiquid, ON.POST_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
            end
            -- Ordered iteration goes to run-plan mods AND to mods that generate
            -- their own levels. POSTTILE_STARTBOOL is the HD mod's own global and
            -- exists nowhere else, so this is an exact test, not a heuristic --
            -- Spelunky 2.5 has neither global and is left on precisely the
            -- behaviour it has been playing on. Switched on HERE, at ON.LOADING,
            -- which is before the first PRE_LEVEL_GENERATION on every floor.
            if not moOrderedIter and (moRunPlan or POSTTILE_STARTBOOL ~= nil) then
                moOrderedIter = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
                -- The HD mod keeps a RUN PLAN of its own: which level each
                -- "feeling" loads on (tiki village, hive, restless, rushing water,
                -- the vault, the black market entrance), whether the worm has been
                -- visited, whether the mothership has. It rebuilds the whole thing
                -- when POSTTILE_STARTBOOL is false, and the ONLY thing that clears
                -- that flag is its own ON.RESET callback -- which the machine that
                -- pressed instant restart receives and a peer warped by our ordered
                -- run_start does not. The peer then carried the DEAD run's plan into
                -- the new one, so the first floor whose theme has feelings rolled a
                -- different set on each machine and generated a completely different
                -- world from the same seed. Clear it on the new-run signal every
                -- machine agrees on, exactly like level_order above. A plain global,
                -- so mods without it are untouched.
                if POSTTILE_STARTBOOL ~= nil then
                    POSTTILE_STARTBOOL = false
                end
                -- Spelunky 2.5's carried-over game object: the same class of bug as
                -- the two above, and the one that made a player who had already
                -- played this launch desync from a player who had just booted.
                moResetContentWorld(first)
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v27 payload (prepended in 1.0.21 only), removed on upgrade to v28.
-- v28 is v27 with the per-frame allocations and indirections taken out; the
-- values it produces are identical, which is the whole point of that change.
local SHIM_V27 = "-- " .. MARKER_V27 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    -- Ordered iteration is switched on SEPARATELY from moRunPlan. They used to be
    -- the same switch, which meant a mod could only get deterministic `pairs` by
    -- also taking the prng anchors -- and those are what broke Spelunky 2.5's 1-4,
    -- so the whole package stayed off for every mod without a `level_order`. The HD
    -- mod is one of those: it builds its levels in Lua, and Lua seeds its STRING
    -- HASH per process, so every `pairs` over string keys in that generator walks a
    -- different order on each machine -- a coin flip, every floor, that no amount of
    -- seed agreement can fix.
    local moOrderedIter = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end


    -- Deterministic liquid for the ON.LEVEL pass.
    --
    -- Spelunky 2 simulates liquid across worker threads, so two machines two
    -- frames into a level do NOT agree on the exact tiles at the waterline. That
    -- would be harmless if mods only drew water; the HD mod instead makes SPAWN
    -- decisions from it, at ON.LEVEL, like this:
    --
    --   if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
    --
    -- Lua's `and` short-circuits, so the roll only happens when the liquid test
    -- passes. One tile of disagreement anywhere along a shoreline therefore
    -- changes HOW MANY times the shared prng is drawn, and every draw after it
    -- lands somewhere else -- for the rest of the floor, and into the next one.
    -- A real capture: identical seed, identical options, all ten prng streams
    -- identical at both gen[pre] AND gen[post], and then 16 vs 9 anchovies, 39 vs
    -- 38 lilypads and 2 vs 3 frogs at ON.LEVEL -- followed by every later Jungle
    -- floor differing, while every Dwelling and Ice Caves floor matched exactly
    -- (this pass returns immediately unless the theme is Jungle).
    --
    -- So answer from a snapshot taken at POST_LEVEL_GENERATION instead: zero
    -- physics updates have run at that point, which makes it a pure function of
    -- the shared seed and layout. Only ON.LEVEL callbacks see the snapshot --
    -- gameplay liquid checks (piranhas, drowning, bomb-displaced water) go
    -- straight through to the engine as before -- and only for mods that generate
    -- their own levels, so Spelunky 2.5 is untouched.
    local moLiquidSnap = nil
    local moLiquidWindow = false
    local moRealIsLiquidAt = is_liquid_at

    local function moSnapshotLiquid()
        moLiquidSnap = nil
        if not moOrderedIter or type(moRealIsLiquidAt) ~= "function" then
            return
        end
        pcall(function()
            local moLeft, moTop, moRight, moBottom = get_bounds()
            -- generous whole-tile bounds; y runs downward, so top > bottom
            moLeft, moRight = math.floor(moLeft) - 1, math.ceil(moRight) + 1
            moBottom, moTop = math.floor(moBottom) - 1, math.ceil(moTop) + 1
            local moSnap, moWet = {}, false
            for moY = moBottom, moTop do
                for moX = moLeft, moRight do
                    if moRealIsLiquidAt(moX, moY) then
                        moSnap[moX * 4096 + moY] = true
                        moWet = true
                    end
                end
            end
            -- A dry floor keeps the engine's own answer: if this level has no
            -- generated liquid at all, there is nothing to make deterministic, and
            -- falling through means a mod that adds water of its own after
            -- generation is not told the level is dry.
            if moWet then
                moLiquidSnap = moSnap
            end
        end)
    end

    is_liquid_at = function(x, y, ...)
        if moLiquidWindow and moLiquidSnap ~= nil then
            local moOk, moHit = pcall(function()
                return moLiquidSnap[math.floor(x + 0.5) * 4096 + math.floor(y + 0.5)] == true
            end)
            if moOk then
                return moHit
            end
        end
        return moRealIsLiquidAt(x, y, ...)
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LEVEL then
            -- Everything the mod does at ON.LEVEL sees the snapshot, so a spawn
            -- decision made from the waterline is the same on every machine.
            local moInner = cb
            cb = function(...)
                local moWas = moLiquidWindow
                moLiquidWindow = true
                local moRet = moInner(...)
                moLiquidWindow = moWas
                return moRet
            end
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)

    -- ------------------------------------------------ content-mod world state
    --
    -- Read-only exposure of Spelunky 2.5's own world state, for mods that keep it.
    --
    -- 2.5 advances its world ONLY when a door is taken (DoorLib ->
    -- onSp25WorldTransition) and resets it to DWELLING in resetGame(). A player
    -- folded back into a run is WARPED in, never through a door, so its copy stays
    -- on whatever resetGame left -- which is why a rejoiner hears 1-1 music on a
    -- later floor, and why its generation decisions diverge from the party's from
    -- that floor on. The engine-side state we transfer (level_count, aggro, quest
    -- and presence flags) is all correct; this is the mod's private bookkeeping,
    -- and nothing outside its Lua state could see it.
    --
    -- Playlunky gives a pack NO `package` table at all -- the v23 probe reported
    -- exactly that: `package=false loaded=nil modules=0`. So a module-registry
    -- lookup was never going to work, and both earlier attempts were built on a
    -- premise that does not hold here.
    --
    -- What the same probe did confirm is that 2.5 publishes its CLASS as a global
    -- (Sp25GameClass=true). Every instance is `setmetatable({}, gameClass)`, so the
    -- class is the __index of the live object: wrapping one of its per-floor methods
    -- hands us `self`, the instance itself, without editing the mod. newLevelHooks
    -- is called once per floor from 2.5's own PRE_LEVEL_GENERATION, which is the
    -- earliest reliable point.
    --
    -- v25 ACTS on it, but only on the new-run signal every machine agrees on (the
    -- ON.LOADING block further down) and only through the mod's own resetGame().
    -- Realigning it MID-RUN is still not attempted: that would mean choosing the
    -- right sp25 world for an engine world/theme, and 2.5's custom worlds do not
    -- map one-to-one onto those.
    local moWorldObj = nil
    local moWorldResets = 0
    local moWorldAdopts = 0
    local moSyncWorldMailbox -- defined below; the capture wrapper calls it
    local moWorldWhere = nil
    local moWorldHooked = false
    local moWorldReported = false

    local function moHookWorldCapture()
        if moWorldHooked then
            return
        end
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            if type(cls) ~= "table" or type(cls.newLevelHooks) ~= "function" then
                return -- not loaded yet, or a mod without this shape
            end
            local moRealNewLevelHooks = cls.newLevelHooks
            cls.newLevelHooks = function(self, ...)
                moWorldObj = self
                moWorldWhere = "Sp25GameClass:newLevelHooks"
                -- newLevelHooks restores the entity db, drops every hook and installs
                -- the set for self.sp25World. Adopting HERE, before delegating, is the
                -- last moment at which a fold-in can still get the party's hooks.
                moSyncWorldMailbox()
                return moRealNewLevelHooks(self, ...)
            end
            moWorldHooked = true
        end)
    end

    --- Read-only snapshot, or nil until the instance has been seen.
    local function moContentWorldState()
        local g = moWorldObj
        if g == nil then
            return nil
        end
        local snap = nil
        pcall(function()
            snap = {
                sp25 = g.sp25World,
                s2 = g.spelunky2World,
                from = g.transitionFromSp25World,
                to = g.transitionToSp25World,
                where = moWorldWhere,
                resets = moWorldResets,
                adopts = moWorldAdopts,
            }
        end)
        return snap
    end

    --- Say ONCE why nothing was found. A silent miss is indistinguishable from a mod
    --- that keeps no world state, and that ambiguity has cost real debugging rounds.
    local function moReportWorldSearch()
        if moWorldReported then
            return
        end
        moWorldReported = true
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            print(string.format(
                "[ModdedOnline] content world state: NOT FOUND | class=%s newLevelHooks=%s"
                .. " hooked=%s package=%s",
                tostring(cls ~= nil),
                tostring(type(cls) == "table" and type(cls.newLevelHooks) or "n/a"),
                tostring(moWorldHooked), tostring(package ~= nil)))
        end)
    end

    --- Spelunky 2.5 keeps ONE game object for the whole launch (its main.lua does
    --- `local game = Sp25GameClass:construct()` once), so its world bookkeeping, the
    --- hooks it installs and its entity-DB tuning all outlive a run. Its own resets
    --- hang off ON.RESET / ON.CAMP / death / a QUEST_FLAGS.RESET seen at
    --- PRE_LOAD_SCREEN -- and a machine that Modded Online WARPS into a run receives
    --- none of those. A player who has already played this launch therefore starts
    --- the shared run carrying the previous run's world, hooks and tuning, and
    --- generates a different floor from the same seed than a player who just booted
    --- the game. In singleplayer the same leak is what makes the textures wrong after
    --- title -> new run.
    ---
    --- The repair is the mod's OWN new-run reset -- unhookAll, restoreEntityDb, back
    --- to world one -- invoked on the new-run signal every machine sees on the same
    --- lockstep frame. It runs on EVERY machine, not only the stale one: an equaliser
    --- that runs in one place just moves the difference somewhere else.
    ---
    --- resetGame() picks WARPZONE over DWELLING when it is called from a level and
    --- 2.5's "Warp Zone (after first restart)" option is on. Both inputs are the same
    --- on every machine at this point (peers transition together, and the option is
    --- synced), so the branch resolves identically -- and it can only ever be reached
    --- from the second run of a launch onward, which is what that option says.
    local function moResetContentWorld(seedFirst)
        local g = moWorldObj
        if g == nil or type(g.resetGame) ~= "function" then
            return -- nothing captured, or a mod without this shape
        end
        local carried = nil
        pcall(function() carried = g.spelunky2World end)
        local ok, err = pcall(function() g:resetGame() end)
        if ok then
            moWorldResets = moWorldResets + 1
            pcall(function()
                print(string.format(
                    "[ModdedOnline] new run %08X: ran 2.5's own resetGame() -- carried"
                    .. " s2world=%s, now sp25=%s s2world=%s (reset #%d)",
                    math.floor(seedFirst or 0), tostring(carried),
                    tostring(g.sp25World), tostring(g.spelunky2World), moWorldResets))
            end)
        else
            pcall(function()
                print(string.format(
                    "[ModdedOnline] 2.5 resetGame() failed, world state left as it was: %s",
                    tostring(err)))
            end)
        end
    end

    -- ---------------------------------------------------------- world mailbox
    --
    -- A mid-run fold-in is the case the reset above deliberately does not touch.
    -- 2.5 advances its world only when a door is taken, and a player warped into a
    -- run in progress never takes one -- so their copy stays on the world they left
    -- while the party's has moved on, and the two machines then install different
    -- world hooks over one seed. That is the "1-1 music on 2-1" desync.
    --
    -- It cannot be worked out locally: 2.5's SP25_WORLD table does not invert (several
    -- of its custom worlds share one engine theme inside a tier), so the only fix is
    -- to be TOLD, by the machine that walked through the door. Playlunky gives two
    -- packs no channel at all -- no `package`, no `io` unless a mod is `unsafe`, and
    -- `user_data` belongs to the script that wrote it. Engine state is the one thing
    -- both Lua states can see.
    --
    -- state.arena.player_lives is four uint8s of arena-match scratch: lives left in a
    -- deathmatch. It means nothing during an adventure run, an arena match resets it
    -- on start, and nothing persists it. Four bytes is enough --
    --
    --   [1] tag: 0xA5 "this is the world I hold" / 0x5A "adopt this one"
    --   [2] index into the SORTED list of Sp25WorldId strings (same on every machine)
    --   [3] 2.5's own world counter
    --   [4] (index + counter * 31) % 256, so foreign bytes are not read as ours
    --
    local MO_BOX_PUB = 0xA5
    local MO_BOX_REQ = 0x5A
    local moWorldIds = nil
    local moWorldIdx = nil

    --- Number the world ids identically on every machine. `pairs` order is not stable
    --- across Lua states -- that is exactly what desynced randomizer -- so sort.
    local function moBuildWorldIndex()
        if moWorldIds ~= nil then
            return true
        end
        pcall(function()
            local ids = rawget(_G or {}, "SP25_WORLD_ID")
            if type(ids) ~= "table" then
                return
            end
            local list = {}
            for _, v in pairs(ids) do
                if type(v) == "string" then
                    list[#list + 1] = v
                end
            end
            if #list == 0 then
                return
            end
            table.sort(list)
            local rev = {}
            for n, v in ipairs(list) do
                rev[v] = n
            end
            moWorldIds, moWorldIdx = list, rev
        end)
        return moWorldIds ~= nil
    end

    local function moBox()
        local m = nil
        pcall(function() m = get_local_state().arena.player_lives end)
        return m
    end

    --- Adopt a world the other machine sent, then publish whatever we hold now.
    --- Adopt FIRST: publishing first would overwrite the request with our own stale
    --- world before we ever read it.
    function moSyncWorldMailbox()
        local g = moWorldObj
        if g == nil or not moBuildWorldIndex() then
            return
        end
        pcall(function()
            local m = moBox()
            if m == nil then
                return
            end
            if math.floor(m[1]) == MO_BOX_REQ then
                local idx, s2 = math.floor(m[2]), math.floor(m[3])
                if (idx + s2 * 31) % 256 == math.floor(m[4]) and moWorldIds[idx] ~= nil then
                    local had, hadS2 = g.sp25World, g.spelunky2World
                    -- A direct write, unlike everything else in this block -- but the
                    -- value is not a guess, it is the world the machine that took the
                    -- door is standing in. onSp25WorldTransition is deliberately NOT
                    -- used: it advances the counter, and we are copying one.
                    g.sp25World = moWorldIds[idx]
                    g.spelunky2World = s2
                    if type(g.clearTransitionRoute) == "function" then
                        g:clearTransitionRoute()
                    end
                    m[1] = MO_BOX_PUB -- consumed, so it is never adopted twice
                    if had ~= g.sp25World or hadS2 ~= g.spelunky2World then
                        moWorldAdopts = moWorldAdopts + 1
                        pcall(function()
                            print(string.format(
                                "[ModdedOnline] adopted world %s (counter %d) from the"
                                .. " party; was %s (counter %s) (adopt #%d)",
                                tostring(g.sp25World), s2, tostring(had),
                                tostring(hadS2), moWorldAdopts))
                        end)
                    end
                end
            end
            local idx = moWorldIdx[g.sp25World]
            if idx == nil then
                return
            end
            local s2 = math.floor(tonumber(g.spelunky2World) or 0) % 256
            m[1], m[2], m[3], m[4] = MO_BOX_PUB, idx, s2, (idx + s2 * 31) % 256
        end)
    end

    MO_CONTENT_WORLD = moContentWorldState

    -- Registered HERE, below the declarations. In v25 these two sat forty lines
    -- higher, above `local function moHookWorldCapture`, so the name resolved as a
    -- global and Playlunky was handed `nil` -- which it accepted and then raised
    -- "attempt to call a nil value" (with an empty traceback, because the call comes
    -- from the host, not from Lua) the first time it fired. The capture never ran, so
    -- the reset below it never had an instance to reset either. Anywhere inside this
    -- block is still ahead of every callback the mod registers: the whole thing is
    -- prepended to its main.lua.
    moRealSetCallback(moHookWorldCapture, ON.PRE_LEVEL_GENERATION)
    moRealSetCallback(moHookWorldCapture, ON.LOADING)
    -- Every point in a floor's pipeline where the world can have moved or a request
    -- can have landed. ON.LOADING is the one that matters for correctness: it runs
    -- ahead of PRE_LOAD_LEVEL_FILES, so an adopted world still themes the floor.
    moRealSetCallback(moSyncWorldMailbox, ON.PRE_LOAD_SCREEN)
    moRealSetCallback(moSyncWorldMailbox, ON.LOADING)
    moRealSetCallback(moSyncWorldMailbox, ON.PRE_LEVEL_GENERATION)
    moRealSetCallback(moSyncWorldMailbox, ON.POST_LEVEL_GENERATION)

    -- One line per floor into the Playlunky log, where a capture can be compared
    -- against the other machine's. Costs nothing for a mod without the handle.
    moRealSetCallback(function()
        pcall(function()
            local snap = moContentWorldState()
            if snap == nil then
                moReportWorldSearch()
                return
            end
            local st = get_local_state()
            print(string.format(
                "[ModdedOnline] content world state: sp25=%s s2world=%s route=%s->%s"
                .. " via %s | engine w%d-%d th%d lc=%d resets=%d adopts=%d",
                tostring(snap.sp25), tostring(snap.s2),
                tostring(snap.from), tostring(snap.to), tostring(snap.where),
                math.floor(st.world), math.floor(st.level), math.floor(st.theme),
                math.floor(st.level_count), snap.resets or 0, snap.adopts or 0))
        end)
    end, ON.POST_LEVEL_GENERATION)
    -- Registered from the prepended block, so it runs before every POST callback
    -- the mod registers -- and, more to the point, before its ON.LEVEL pass.
    moRealSetCallback(moSnapshotLiquid, ON.POST_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
            end
            -- Ordered iteration goes to run-plan mods AND to mods that generate
            -- their own levels. POSTTILE_STARTBOOL is the HD mod's own global and
            -- exists nowhere else, so this is an exact test, not a heuristic --
            -- Spelunky 2.5 has neither global and is left on precisely the
            -- behaviour it has been playing on. Switched on HERE, at ON.LOADING,
            -- which is before the first PRE_LEVEL_GENERATION on every floor.
            if not moOrderedIter and (moRunPlan or POSTTILE_STARTBOOL ~= nil) then
                moOrderedIter = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
                -- The HD mod keeps a RUN PLAN of its own: which level each
                -- "feeling" loads on (tiki village, hive, restless, rushing water,
                -- the vault, the black market entrance), whether the worm has been
                -- visited, whether the mothership has. It rebuilds the whole thing
                -- when POSTTILE_STARTBOOL is false, and the ONLY thing that clears
                -- that flag is its own ON.RESET callback -- which the machine that
                -- pressed instant restart receives and a peer warped by our ordered
                -- run_start does not. The peer then carried the DEAD run's plan into
                -- the new one, so the first floor whose theme has feelings rolled a
                -- different set on each machine and generated a completely different
                -- world from the same seed. Clear it on the new-run signal every
                -- machine agrees on, exactly like level_order above. A plain global,
                -- so mods without it are untouched.
                if POSTTILE_STARTBOOL ~= nil then
                    POSTTILE_STARTBOOL = false
                end
                -- Spelunky 2.5's carried-over game object: the same class of bug as
                -- the two above, and the one that made a player who had already
                -- played this launch desync from a player who had just booted.
                moResetContentWorld(first)
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

local SHIM = "-- " .. MARKER .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    -- Ordered iteration is switched on SEPARATELY from moRunPlan. They used to be
    -- the same switch, which meant a mod could only get deterministic `pairs` by
    -- also taking the prng anchors -- and those are what broke Spelunky 2.5's 1-4,
    -- so the whole package stayed off for every mod without a `level_order`. The HD
    -- mod is one of those: it builds its levels in Lua, and Lua seeds its STRING
    -- HASH per process, so every `pairs` over string keys in that generator walks a
    -- different order on each machine -- a coin flip, every floor, that no amount of
    -- seed agreement can fix.
    local moOrderedIter = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Which basis ON.LOADING anchors on. It is ALWAYS anchored -- that is v14
    -- behaviour, and v14 is the build Spelunky 2.5 demonstrably worked under: layer
    -- travel executed, 1-4 was cleared repeatedly, no desyncs, no crash. v11 (no
    -- anchor here at all) is the build where a layer-door press booked a travel that
    -- never fired, so gating this off entirely took the back layer away again.
    -- Only the BASIS differs: a run-plan mod needs the run-scoped one, because
    -- during a synchronized restart the machines disagree on world/level/theme at
    -- exactly the moment it lays out its run. A mod without a run plan gets the
    -- per-floor basis v14 used.
    local function moPrngLoadBase()
        if moRunPlan then
            return moPrngRunBase()
        end
        return moPrngFloorBase()
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    -- `pcall(prng.get_pair, prng, c)` rather than `pcall(function() ... end)`: a
    -- closure that captures a loop variable is allocated fresh on every iteration,
    -- so these two loops used to build 21 of them per anchored hook. Same
    -- protection, same calls, same values -- one allocation fewer each.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(prng.get_pair, prng, c)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(prng.set_pair, prng, e[1], e[2], e[3])
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    -- `base()` stays INSIDE the protected call (it reads engine state and can
    -- throw), so error behaviour is unchanged -- but this is one shared function
    -- now instead of a closure built per hook invocation.
    local function moSeedFromBase(base)
        seed_prng(base())
    end
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(moSeedFromBase, base)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end


    -- Deterministic liquid for the ON.LEVEL pass.
    --
    -- Spelunky 2 simulates liquid across worker threads, so two machines two
    -- frames into a level do NOT agree on the exact tiles at the waterline. That
    -- would be harmless if mods only drew water; the HD mod instead makes SPAWN
    -- decisions from it, at ON.LEVEL, like this:
    --
    --   if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
    --
    -- Lua's `and` short-circuits, so the roll only happens when the liquid test
    -- passes. One tile of disagreement anywhere along a shoreline therefore
    -- changes HOW MANY times the shared prng is drawn, and every draw after it
    -- lands somewhere else -- for the rest of the floor, and into the next one.
    -- A real capture: identical seed, identical options, all ten prng streams
    -- identical at both gen[pre] AND gen[post], and then 16 vs 9 anchovies, 39 vs
    -- 38 lilypads and 2 vs 3 frogs at ON.LEVEL -- followed by every later Jungle
    -- floor differing, while every Dwelling and Ice Caves floor matched exactly
    -- (this pass returns immediately unless the theme is Jungle).
    --
    -- So answer from a snapshot taken at POST_LEVEL_GENERATION instead: zero
    -- physics updates have run at that point, which makes it a pure function of
    -- the shared seed and layout. Only ON.LEVEL callbacks see the snapshot --
    -- gameplay liquid checks (piranhas, drowning, bomb-displaced water) go
    -- straight through to the engine as before -- and only for mods that generate
    -- their own levels, so Spelunky 2.5 is untouched.
    local moLiquidSnap = nil
    local moLiquidWindow = false
    local moRealIsLiquidAt = is_liquid_at

    local function moSnapshotLiquid()
        moLiquidSnap = nil
        if not moOrderedIter or type(moRealIsLiquidAt) ~= "function" then
            return
        end
        pcall(function()
            local moLeft, moTop, moRight, moBottom = get_bounds()
            -- generous whole-tile bounds; y runs downward, so top > bottom
            moLeft, moRight = math.floor(moLeft) - 1, math.ceil(moRight) + 1
            moBottom, moTop = math.floor(moBottom) - 1, math.ceil(moTop) + 1
            local moSnap, moWet = {}, false
            for moY = moBottom, moTop do
                for moX = moLeft, moRight do
                    if moRealIsLiquidAt(moX, moY) then
                        moSnap[moX * 4096 + moY] = true
                        moWet = true
                    end
                end
            end
            -- A dry floor keeps the engine's own answer: if this level has no
            -- generated liquid at all, there is nothing to make deterministic, and
            -- falling through means a mod that adds water of its own after
            -- generation is not told the level is dry.
            if moWet then
                moLiquidSnap = moSnap
            end
        end)
    end

    local function moLiquidLookup(snap, x, y)
        return snap[math.floor(x + 0.5) * 4096 + math.floor(y + 0.5)] == true
    end
    is_liquid_at = function(x, y, ...)
        if moLiquidWindow and moLiquidSnap ~= nil then
            -- hoisted out of a per-call `pcall(function() ... end)`; inside the
            -- window this runs once per candidate tile of a floor's spawn pass
            local moOk, moHit = pcall(moLiquidLookup, moLiquidSnap, x, y)
            if moOk then
                return moHit
            end
        end
        return moRealIsLiquidAt(x, y, ...)
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LEVEL then
            -- Everything the mod does at ON.LEVEL sees the snapshot, so a spawn
            -- decision made from the waterline is the same on every machine.
            local moInner = cb
            cb = function(...)
                local moWas = moLiquidWindow
                moLiquidWindow = true
                local moRet = moInner(...)
                moLiquidWindow = moWas
                return moRet
            end
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngLoadBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)

    -- ------------------------------------------------ content-mod world state
    --
    -- Read-only exposure of Spelunky 2.5's own world state, for mods that keep it.
    --
    -- 2.5 advances its world ONLY when a door is taken (DoorLib ->
    -- onSp25WorldTransition) and resets it to DWELLING in resetGame(). A player
    -- folded back into a run is WARPED in, never through a door, so its copy stays
    -- on whatever resetGame left -- which is why a rejoiner hears 1-1 music on a
    -- later floor, and why its generation decisions diverge from the party's from
    -- that floor on. The engine-side state we transfer (level_count, aggro, quest
    -- and presence flags) is all correct; this is the mod's private bookkeeping,
    -- and nothing outside its Lua state could see it.
    --
    -- Playlunky gives a pack NO `package` table at all -- the v23 probe reported
    -- exactly that: `package=false loaded=nil modules=0`. So a module-registry
    -- lookup was never going to work, and both earlier attempts were built on a
    -- premise that does not hold here.
    --
    -- What the same probe did confirm is that 2.5 publishes its CLASS as a global
    -- (Sp25GameClass=true). Every instance is `setmetatable({}, gameClass)`, so the
    -- class is the __index of the live object: wrapping one of its per-floor methods
    -- hands us `self`, the instance itself, without editing the mod. newLevelHooks
    -- is called once per floor from 2.5's own PRE_LEVEL_GENERATION, which is the
    -- earliest reliable point.
    --
    -- v25 ACTS on it, but only on the new-run signal every machine agrees on (the
    -- ON.LOADING block further down) and only through the mod's own resetGame().
    -- Realigning it MID-RUN is still not attempted: that would mean choosing the
    -- right sp25 world for an engine world/theme, and 2.5's custom worlds do not
    -- map one-to-one onto those.
    local moWorldObj = nil
    local moWorldResets = 0
    local moWorldAdopts = 0
    local moSyncWorldMailbox -- defined below; the capture wrapper calls it
    local moWorldWhere = nil
    local moWorldHooked = false
    local moWorldReported = false

    local function moHookWorldCapture()
        if moWorldHooked then
            return
        end
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            if type(cls) ~= "table" or type(cls.newLevelHooks) ~= "function" then
                return -- not loaded yet, or a mod without this shape
            end
            local moRealNewLevelHooks = cls.newLevelHooks
            cls.newLevelHooks = function(self, ...)
                moWorldObj = self
                moWorldWhere = "Sp25GameClass:newLevelHooks"
                -- newLevelHooks restores the entity db, drops every hook and installs
                -- the set for self.sp25World. Adopting HERE, before delegating, is the
                -- last moment at which a fold-in can still get the party's hooks.
                moSyncWorldMailbox()
                return moRealNewLevelHooks(self, ...)
            end
            moWorldHooked = true
        end)
    end

    --- Read-only snapshot, or nil until the instance has been seen.
    local function moContentWorldState()
        local g = moWorldObj
        if g == nil then
            return nil
        end
        local snap = nil
        pcall(function()
            snap = {
                sp25 = g.sp25World,
                s2 = g.spelunky2World,
                from = g.transitionFromSp25World,
                to = g.transitionToSp25World,
                where = moWorldWhere,
                resets = moWorldResets,
                adopts = moWorldAdopts,
            }
        end)
        return snap
    end

    --- Say ONCE why nothing was found. A silent miss is indistinguishable from a mod
    --- that keeps no world state, and that ambiguity has cost real debugging rounds.
    local function moReportWorldSearch()
        if moWorldReported then
            return
        end
        moWorldReported = true
        pcall(function()
            local cls = rawget(_G or {}, "Sp25GameClass")
            print(string.format(
                "[ModdedOnline] content world state: NOT FOUND | class=%s newLevelHooks=%s"
                .. " hooked=%s package=%s",
                tostring(cls ~= nil),
                tostring(type(cls) == "table" and type(cls.newLevelHooks) or "n/a"),
                tostring(moWorldHooked), tostring(package ~= nil)))
        end)
    end

    --- Spelunky 2.5 keeps ONE game object for the whole launch (its main.lua does
    --- `local game = Sp25GameClass:construct()` once), so its world bookkeeping, the
    --- hooks it installs and its entity-DB tuning all outlive a run. Its own resets
    --- hang off ON.RESET / ON.CAMP / death / a QUEST_FLAGS.RESET seen at
    --- PRE_LOAD_SCREEN -- and a machine that Modded Online WARPS into a run receives
    --- none of those. A player who has already played this launch therefore starts
    --- the shared run carrying the previous run's world, hooks and tuning, and
    --- generates a different floor from the same seed than a player who just booted
    --- the game. In singleplayer the same leak is what makes the textures wrong after
    --- title -> new run.
    ---
    --- The repair is the mod's OWN new-run reset -- unhookAll, restoreEntityDb, back
    --- to world one -- invoked on the new-run signal every machine sees on the same
    --- lockstep frame. It runs on EVERY machine, not only the stale one: an equaliser
    --- that runs in one place just moves the difference somewhere else.
    ---
    --- resetGame() picks WARPZONE over DWELLING when it is called from a level and
    --- 2.5's "Warp Zone (after first restart)" option is on. Both inputs are the same
    --- on every machine at this point (peers transition together, and the option is
    --- synced), so the branch resolves identically -- and it can only ever be reached
    --- from the second run of a launch onward, which is what that option says.
    local function moResetContentWorld(seedFirst)
        local g = moWorldObj
        if g == nil or type(g.resetGame) ~= "function" then
            return -- nothing captured, or a mod without this shape
        end
        local carried = nil
        pcall(function() carried = g.spelunky2World end)
        local ok, err = pcall(function() g:resetGame() end)
        if ok then
            moWorldResets = moWorldResets + 1
            pcall(function()
                print(string.format(
                    "[ModdedOnline] new run %08X: ran 2.5's own resetGame() -- carried"
                    .. " s2world=%s, now sp25=%s s2world=%s (reset #%d)",
                    math.floor(seedFirst or 0), tostring(carried),
                    tostring(g.sp25World), tostring(g.spelunky2World), moWorldResets))
            end)
        else
            pcall(function()
                print(string.format(
                    "[ModdedOnline] 2.5 resetGame() failed, world state left as it was: %s",
                    tostring(err)))
            end)
        end
    end

    -- ---------------------------------------------------------- world mailbox
    --
    -- A mid-run fold-in is the case the reset above deliberately does not touch.
    -- 2.5 advances its world only when a door is taken, and a player warped into a
    -- run in progress never takes one -- so their copy stays on the world they left
    -- while the party's has moved on, and the two machines then install different
    -- world hooks over one seed. That is the "1-1 music on 2-1" desync.
    --
    -- It cannot be worked out locally: 2.5's SP25_WORLD table does not invert (several
    -- of its custom worlds share one engine theme inside a tier), so the only fix is
    -- to be TOLD, by the machine that walked through the door. Playlunky gives two
    -- packs no channel at all -- no `package`, no `io` unless a mod is `unsafe`, and
    -- `user_data` belongs to the script that wrote it. Engine state is the one thing
    -- both Lua states can see.
    --
    -- state.arena.player_lives is four uint8s of arena-match scratch: lives left in a
    -- deathmatch. It means nothing during an adventure run, an arena match resets it
    -- on start, and nothing persists it. Four bytes is enough --
    --
    --   [1] tag: 0xA5 "this is the world I hold" / 0x5A "adopt this one"
    --   [2] index into the SORTED list of Sp25WorldId strings (same on every machine)
    --   [3] 2.5's own world counter
    --   [4] (index + counter * 31) % 256, so foreign bytes are not read as ours
    --
    local MO_BOX_PUB = 0xA5
    local MO_BOX_REQ = 0x5A
    local moWorldIds = nil
    local moWorldIdx = nil

    --- Number the world ids identically on every machine. `pairs` order is not stable
    --- across Lua states -- that is exactly what desynced randomizer -- so sort.
    local function moBuildWorldIndex()
        if moWorldIds ~= nil then
            return true
        end
        pcall(function()
            local ids = rawget(_G or {}, "SP25_WORLD_ID")
            if type(ids) ~= "table" then
                return
            end
            local list = {}
            for _, v in pairs(ids) do
                if type(v) == "string" then
                    list[#list + 1] = v
                end
            end
            if #list == 0 then
                return
            end
            table.sort(list)
            local rev = {}
            for n, v in ipairs(list) do
                rev[v] = n
            end
            moWorldIds, moWorldIdx = list, rev
        end)
        return moWorldIds ~= nil
    end

    local function moBox()
        local m = nil
        pcall(function() m = get_local_state().arena.player_lives end)
        return m
    end

    --- Adopt a world the other machine sent, then publish whatever we hold now.
    --- Adopt FIRST: publishing first would overwrite the request with our own stale
    --- world before we ever read it.
    function moSyncWorldMailbox()
        local g = moWorldObj
        if g == nil or not moBuildWorldIndex() then
            return
        end
        pcall(function()
            local m = moBox()
            if m == nil then
                return
            end
            if math.floor(m[1]) == MO_BOX_REQ then
                local idx, s2 = math.floor(m[2]), math.floor(m[3])
                if (idx + s2 * 31) % 256 == math.floor(m[4]) and moWorldIds[idx] ~= nil then
                    local had, hadS2 = g.sp25World, g.spelunky2World
                    -- A direct write, unlike everything else in this block -- but the
                    -- value is not a guess, it is the world the machine that took the
                    -- door is standing in. onSp25WorldTransition is deliberately NOT
                    -- used: it advances the counter, and we are copying one.
                    g.sp25World = moWorldIds[idx]
                    g.spelunky2World = s2
                    if type(g.clearTransitionRoute) == "function" then
                        g:clearTransitionRoute()
                    end
                    m[1] = MO_BOX_PUB -- consumed, so it is never adopted twice
                    if had ~= g.sp25World or hadS2 ~= g.spelunky2World then
                        moWorldAdopts = moWorldAdopts + 1
                        pcall(function()
                            print(string.format(
                                "[ModdedOnline] adopted world %s (counter %d) from the"
                                .. " party; was %s (counter %s) (adopt #%d)",
                                tostring(g.sp25World), s2, tostring(had),
                                tostring(hadS2), moWorldAdopts))
                        end)
                    end
                end
            end
            local idx = moWorldIdx[g.sp25World]
            if idx == nil then
                return
            end
            local s2 = math.floor(tonumber(g.spelunky2World) or 0) % 256
            m[1], m[2], m[3], m[4] = MO_BOX_PUB, idx, s2, (idx + s2 * 31) % 256
        end)
    end

    MO_CONTENT_WORLD = moContentWorldState

    -- Registered HERE, below the declarations. In v25 these two sat forty lines
    -- higher, above `local function moHookWorldCapture`, so the name resolved as a
    -- global and Playlunky was handed `nil` -- which it accepted and then raised
    -- "attempt to call a nil value" (with an empty traceback, because the call comes
    -- from the host, not from Lua) the first time it fired. The capture never ran, so
    -- the reset below it never had an instance to reset either. Anywhere inside this
    -- block is still ahead of every callback the mod registers: the whole thing is
    -- prepended to its main.lua.
    moRealSetCallback(moHookWorldCapture, ON.PRE_LEVEL_GENERATION)
    moRealSetCallback(moHookWorldCapture, ON.LOADING)
    -- Every point in a floor's pipeline where the world can have moved or a request
    -- can have landed. ON.LOADING is the one that matters for correctness: it runs
    -- ahead of PRE_LOAD_LEVEL_FILES, so an adopted world still themes the floor.
    moRealSetCallback(moSyncWorldMailbox, ON.PRE_LOAD_SCREEN)
    moRealSetCallback(moSyncWorldMailbox, ON.LOADING)
    moRealSetCallback(moSyncWorldMailbox, ON.PRE_LEVEL_GENERATION)
    moRealSetCallback(moSyncWorldMailbox, ON.POST_LEVEL_GENERATION)

    -- One line per floor into the Playlunky log, where a capture can be compared
    -- against the other machine's. Costs nothing for a mod without the handle.
    moRealSetCallback(function()
        pcall(function()
            local snap = moContentWorldState()
            if snap == nil then
                moReportWorldSearch()
                return
            end
            local st = get_local_state()
            print(string.format(
                "[ModdedOnline] content world state: sp25=%s s2world=%s route=%s->%s"
                .. " via %s | engine w%d-%d th%d lc=%d resets=%d adopts=%d",
                tostring(snap.sp25), tostring(snap.s2),
                tostring(snap.from), tostring(snap.to), tostring(snap.where),
                math.floor(st.world), math.floor(st.level), math.floor(st.theme),
                math.floor(st.level_count), snap.resets or 0, snap.adopts or 0))
        end)
    end, ON.POST_LEVEL_GENERATION)
    -- Registered from the prepended block, so it runs before every POST callback
    -- the mod registers -- and, more to the point, before its ON.LEVEL pass.
    moRealSetCallback(moSnapshotLiquid, ON.POST_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
            end
            -- Ordered iteration goes to run-plan mods AND to mods that generate
            -- their own levels. POSTTILE_STARTBOOL is the HD mod's own global and
            -- exists nowhere else, so this is an exact test, not a heuristic --
            -- Spelunky 2.5 has neither global and is left on precisely the
            -- behaviour it has been playing on. Switched on HERE, at ON.LOADING,
            -- which is before the first PRE_LEVEL_GENERATION on every floor.
            if not moOrderedIter and (moRunPlan or POSTTILE_STARTBOOL ~= nil) then
                moOrderedIter = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
                -- The HD mod keeps a RUN PLAN of its own: which level each
                -- "feeling" loads on (tiki village, hive, restless, rushing water,
                -- the vault, the black market entrance), whether the worm has been
                -- visited, whether the mothership has. It rebuilds the whole thing
                -- when POSTTILE_STARTBOOL is false, and the ONLY thing that clears
                -- that flag is its own ON.RESET callback -- which the machine that
                -- pressed instant restart receives and a peer warped by our ordered
                -- run_start does not. The peer then carried the DEAD run's plan into
                -- the new one, so the first floor whose theme has feelings rolled a
                -- different set on each machine and generated a completely different
                -- world from the same seed. Clear it on the new-run signal every
                -- machine agrees on, exactly like level_order above. A plain global,
                -- so mods without it are untouched.
                if POSTTILE_STARTBOOL ~= nil then
                    POSTTILE_STARTBOOL = false
                end
                -- Spelunky 2.5's carried-over game object: the same class of bug as
                -- the two above, and the one that made a player who had already
                -- played this launch desync from a player who had just booted.
                moResetContentWorld(first)
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    -- registered below, together with the rest of the per-frame work
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    -- Memoized for the current simulated frame. This is the mod's get_frame() and
    -- get_ms(), and Spelunky 2.5 calls those from per-entity update paths -- mimics,
    -- repair drones, the spinning ball trap, the axolotl shield -- so it ran once
    -- per live custom entity per frame, each time paying a pcall and a
    -- get_local_state() boundary crossing to read a number that cannot change
    -- within the frame.
    --
    -- The cache is dropped by moFrameTick on ON.GAMEFRAME (registered from this
    -- prepended block, so ahead of every callback the mod registers) and at the
    -- three load events, which is where time_total can move without a simulated
    -- frame of ours in between -- a restart zeroes it. time_total advances only on
    -- a simulated frame, so every value returned is the value the uncached version
    -- would have returned, epoch bump included.
    local moClockValid = false
    local moClockValue = 0
    local function moSimFrame()
        if moClockValid then
            return moClockValue
        end
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        moClockValue = moBase + moTotal
        moClockValid = true
        return moClockValue
    end
    local function moClockInvalidate()
        moClockValid = false
    end
    local function moGetMs()
        return moSimFrame() * (1000.0 / 60.0)
    end
    get_frame = moSimFrame -- no forwarding closure: same arity, same one return
    get_ms = moGetMs

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    --
    -- Named, not `pcall(function() ... end)`: the anonymous form allocated a fresh
    -- closure every simulated frame.
    local function moFrameSeed()
        math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
    end

    -- ONE registration doing what two used to. The counter is bumped FIRST, exactly
    -- as it was when it had its own callback: it is moRawSimFrame's out-of-run
    -- fallback, so that order decides which value the seed is built from.
    local function moFrameTick()
        moFrame = moFrame + 1
        moClockInvalidate()
        pcall(moFrameSeed)
    end
    moRealSetCallback(moFrameTick, ON.GAMEFRAME)
    -- Registered HERE, below the declarations. Naming a callback before its `local`
    -- is what handed Playlunky a nil in v25.
    moRealSetCallback(moClockInvalidate, ON.PRE_LOAD_SCREEN)
    moRealSetCallback(moClockInvalidate, ON.LOADING)
    moRealSetCallback(moClockInvalidate, ON.PRE_LEVEL_GENERATION)
end

]]

-- PREPENDED, as a SEPARATE block from the determinism shim above and versioned
-- separately: it is injected into a different set of packs (anything with
-- settings of its own, shim-worthy or not) and it has to be able to change
-- without churning 25 KB of unrelated prng code in every mod's main.lua.
--
-- What it does: applies the room host's mod settings, which Modded Online drops
-- in Mods/Packs/mo_options.txt (see src/optionSync.lua), to this mod's live
-- `options` table. Mod settings feed level generation, so two players whose
-- settings differ build different worlds from the same seed.
--
-- Why it can't change anything on disk: it captures this mod's own values before
-- it writes a single one, it puts them BACK before the mod's own ON.SAVE
-- callback runs (that is why it must be PREPENDED -- our wrapper has to be in
-- place before the mod registers ON.SAVE, so our restore runs before its save),
-- and it re-applies the host's afterwards. The mod therefore serialises its own
-- settings every time it saves; the host's values never leave memory. If the
-- backup file cannot be written, nothing is overridden at all.
local OPT_SHIM = "-- " .. OPT_MARKER .. [[ auto-added by Modded Online; safe to delete this block.
-- Applies the ROOM HOST's mod settings while you are in their online room, so
-- players with different settings still build the same world. Your own settings
-- are captured first and put back before this mod ever saves -- nothing here
-- changes anything on disk. See Mods/Packs/mo_options_backup.txt.
do
    local moOptSetCallback = set_callback
    local moOptFile = "Mods/Packs/mo_options.txt"
    local moOptGen = nil       -- generation of the override currently applied
    local moOptValues = nil    -- the host's values we are holding
    local moOptBackup = nil    -- key -> OUR value, captured before the first write
    local moOptStale = false   -- backup file outlived the override; drop it after the next save
    local moOptTick = 0

    -- Our own backup file is per-pack, so several shimmed mods never share one.
    -- meta.name is set by the mod's own chunk, which has not run yet at this
    -- point -- hence read lazily, never at load.
    local function moOptBackupPath()
        local moName = "pack"
        pcall(function()
            if type(meta) == "table" and type(meta.name) == "string" and meta.name ~= "" then
                moName = meta.name
            end
        end)
        return "Mods/Packs/mo_options_backup_" .. (moName:gsub("[^%w%-%._ ]", "_")) .. ".txt"
    end

    -- The live values we are about to overwrite, written out BEFORE the first
    -- override lands. Nothing reads it back: the restore below works from memory
    -- and the mod's save file never holds the host's values, so this is a record
    -- for the player, not a repair mechanism.
    local function moOptWriteBackup()
        return (pcall(function()
            local f = assert(io.open(moOptBackupPath(), "w"))
            f:write("# Modded Online: YOUR settings for this mod, saved before the room\n")
            f:write("# host's were applied. They are put back in memory before this mod\n")
            f:write("# saves, so its save file never held the host's values. Safe to delete.\n")
            local moKeys = {}
            for k in pairs(moOptBackup) do
                moKeys[#moKeys + 1] = tostring(k)
            end
            table.sort(moKeys)
            for i = 1, #moKeys do
                local moKey = moKeys[i]
                f:write(moKey .. " = " .. tostring(moOptBackup[moKey]) .. "\n")
            end
            f:close()
        end))
    end

    -- os.remove reports failure by RETURN VALUE rather than by raising, so check
    -- the file is really gone; an EMPTY file is an equally clear "nothing here".
    local function moOptDropBackup()
        local moPath = moOptBackupPath()
        pcall(function() os.remove(moPath) end)
        local moLeft = nil
        pcall(function() moLeft = io.open(moPath, "r") end)
        if moLeft ~= nil then
            moLeft:close()
            pcall(function()
                local f = assert(io.open(moPath, "w"))
                f:close()
            end)
        end
    end

    -- Only keys this mod ALREADY has are ever touched: an option it never
    -- registered means nothing here, and inventing one could feed its own
    -- iteration over the table.
    local function moOptWrite(vals)
        if type(options) ~= "table" then
            return
        end
        for k, v in pairs(vals) do
            local moCur = options[k]
            if moCur ~= nil and type(moCur) == type(v) then
                options[k] = v
            end
        end
    end

    local function moOptRestore()
        if moOptBackup == nil or type(options) ~= "table" then
            return
        end
        for k, v in pairs(moOptBackup) do
            options[k] = v
        end
    end

    local function moOptApply(vals)
        if type(options) ~= "table" then
            return false
        end
        -- Everything we are about to CHANGE, as it stands right now. Keys already
        -- in the backup are left alone: their entry is the player's own value and
        -- must not be overwritten with a value we ourselves put there.
        local moNew, moCount = {}, 0
        for k, v in pairs(vals) do
            local moCur = options[k]
            if moCur ~= nil and type(moCur) == type(v) and moCur ~= v then
                if moOptBackup == nil or moOptBackup[k] == nil then
                    moNew[k] = moCur
                    moCount = moCount + 1
                end
            end
        end
        if moOptBackup == nil then
            if moCount == 0 then
                moOptValues = vals -- identical settings: nothing to restore later
                return true
            end
            moOptBackup = moNew
            if not moOptWriteBackup() then
                moOptBackup = nil -- fail CLOSED: no backup on disk, no override
                return false
            end
        elseif moCount > 0 then
            for k, v in pairs(moNew) do
                moOptBackup[k] = v
            end
            if not moOptWriteBackup() then
                return false
            end
        end
        moOptValues = vals
        moOptStale = false
        moOptWrite(vals)
        return true
    end

    local function moOptRelease()
        moOptRestore()
        moOptGen = nil
        moOptValues = nil
        if moOptBackup ~= nil then
            moOptBackup = nil
            -- Keep the file until the mod has SAVED with our values back in
            -- place. Until then it is the only on-disk record of them.
            moOptStale = true
        end
    end

    local function moOptUnescape(s)
        return (s:gsub("\\(.)", function(c)
            if c == "t" then return "\t" end
            if c == "n" then return "\n" end
            if c == "r" then return "\r" end
            return c
        end))
    end

    -- key<TAB>type<TAB>value lines; the file's own "gen" line and its comments
    -- carry no type tag and so never match.
    local function moOptParse(data)
        local out = {}
        for line in data:gmatch("[^\r\n]+") do
            local k, t, v = line:match("^([^\t]+)\t([bns])\t(.*)$")
            if k ~= nil then
                if t == "b" then
                    out[k] = (v == "1")
                elseif t == "n" then
                    out[k] = tonumber(v)
                else
                    out[k] = moOptUnescape(v)
                end
            end
        end
        return out
    end

    local function moOptCheck()
        local moData = nil
        pcall(function()
            local f = io.open(moOptFile, "r")
            if f == nil then
                return
            end
            moData = f:read("*a")
            f:close()
        end)
        local moGen = nil
        if moData ~= nil then
            moGen = tonumber(moData:match("gen\t(%d+)"))
        end
        if moGen == nil then
            -- no override in force (left the room, or never in one)
            if moOptGen ~= nil then
                moOptRelease()
            end
            return
        end
        if moGen ~= moOptGen then
            if moOptApply(moOptParse(moData)) then
                moOptGen = moGen
            end
        elseif moOptValues ~= nil then
            -- Re-assert every poll rather than only on change: the mod rebuilds
            -- its own options table on ON.LOAD and on a reset-to-defaults, and
            -- either would silently drop the room's settings mid-run.
            moOptWrite(moOptValues)
        end
    end

    set_callback = function(cb, id)
        if id == ON.SAVE then
            local moInner = cb
            cb = function(...)
                -- The mod is about to serialise its options. Put the player's own
                -- values back FIRST, so the host's can never reach the disk, then
                -- take the room's settings up again.
                moOptRestore()
                local moRet = moInner(...)
                if moOptValues ~= nil then
                    moOptWrite(moOptValues)
                elseif moOptStale then
                    -- our own values are now written back out; the on-disk record
                    -- of them has done its job
                    moOptStale = false
                    moOptDropBackup()
                end
                return moRet
            end
        end
        return moOptSetCallback(cb, id)
    end

    moOptSetCallback(function()
        moOptTick = moOptTick + 1
        if moOptTick % 20 == 0 then
            pcall(moOptCheck)
        end
    end, ON.GUIFRAME)
    -- Synchronous re-check at the two points where the run is about to be laid
    -- out, so settings that arrived a moment ago are always in force before this
    -- mod generates anything. Registered here, in the prepended block, so it runs
    -- before every callback the mod itself registers.
    moOptSetCallback(function() pcall(moOptCheck) end, ON.PRE_LEVEL_GENERATION)
    moOptSetCallback(function() pcall(moOptCheck) end, ON.LOADING)
end

]]

-- the exact v18 payload (prepended in 1.0.36-1.0.37), removed on upgrade to
-- v19. v18 gated the ON.LOADING anchor off for mods without a run plan, which
-- dropped Spelunky 2.5 all the way back to v11 -- the build where a booked
-- layer travel never fired and the back layer was unreachable.
local SHIM_V18 = "-- " .. MARKER_V18 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    -- Everything gated on moRunPlan below exists for RANDOMIZER-CLASS mods --
    -- ordered iteration, the ON.LOADING and PRE_LEVEL_GENERATION anchors, the
    -- new-run plan reset. Each of them changes what a content mod COMPUTES, so
    -- forcing them on a mod that never needed them is not neutral: Spelunky 2.5
    -- ran correctly for months on the v11 shim, and switching these on reordered
    -- its hook iteration and moved its generation draws. Its most hook-dense floor
    -- (Dwelling 1-4: three boss variants, back-layer-specific spawners, on-spawn
    -- entity replacement) started crashing. So `pairs` is prepared here but NOT
    -- installed; a mod that shows no run plan keeps the stock iterator and sees
    -- exactly the v11 shim it worked under.
    local moRunPlan = false
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    local moOrderedPairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    -- Anchor only for run-plan mods. Checked at CALL time, not registration time:
    -- the signal cannot exist until the mod's own chunk has run, and callbacks are
    -- registered from inside that chunk.
    local function moAnchorPrngIfRunPlan(cb, base)
        local moWrapped = moAnchorPrng(cb, base)
        return function(...)
            if moRunPlan then
                return moWrapped(...)
            end
            return cb(...)
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- gated: v11 did not touch these, and 2.5 generates correctly without
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrngIfRunPlan(cb, moPrngFloorBase)
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrngIfRunPlan(cb, moPrngRunBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local plan = level_order
            if not moRunPlan and type(plan) == "table" then
                -- This mod keeps a run plan, so it is the class all of this was
                -- built for. Switch it on HERE: our ON.LOADING runs before the
                -- mod's (we register first), so ordered iteration is in place
                -- before the plan is built, and moRunPlan is set before any
                -- anchored hook can fire.
                moRunPlan = true
                pairs = moOrderedPairs
            end
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v17 payload (prepended in 1.0.32-1.0.35), removed on upgrade to
-- v18. v17 forced the randomizer-class behaviour (ordered pairs, the loading
-- and pre-generation prng anchors) on EVERY content mod, which changed what
-- Spelunky 2.5 computed and made its 1-4 crash.
local SHIM_V17 = "-- " .. MARKER_V17 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    pairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Run-scoped basis, for hooks that fire while the FLOOR identity is still in
    -- flux. During a synchronized restart the two machines demonstrably disagree on
    -- world/level/theme, level_count AND quest_flags at ON.LOADING -- the host's
    -- engine is mid-reset while a peer is only being warped -- so folding any of
    -- those in would hand the machines different bases at exactly the moment a mod
    -- lays out its run. The adventure seed's FIRST value is the one thing our
    -- ordered run_start guarantees is already equal. (Its SECOND value is not: it
    -- drifts a Weyl step between world host and peers, see moReseed.) The cost is
    -- that ON.LOADING draws no longer vary per floor; that is the right trade,
    -- since the floor is not even generated yet when it fires.
    local function moPrngRunBase()
        local first = get_adventure_seed(false)
        return math.floor(first) ~ 0x4C4F4144
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb, base)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(base()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrng(cb, moPrngFloorBase)
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb, moPrngRunBase)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)

    -- A synchronized RESTART is a new run, but only the machine whose player
    -- actually pressed restart sees the engine raise QUEST_FLAG.RESET; every peer
    -- is simply warped by our ordered run_start. Randomizer 2.0 rebuilds its whole
    -- run plan on `#level_order == 0 or test_flag(state.quest_flags, 1)`, so the
    -- presser rebuilt while the peers silently kept the DEAD run's plan -- the peer
    -- regenerated the exact floor it had just restarted away from, and the two
    -- machines then played different runs from identical seeds.
    --
    -- Detect a new run from the adventure seed's FIRST value instead (our run_start
    -- sets it on every machine at the same lockstep point, so all of them notice on
    -- the same frame) and empty the plan, which makes every machine take the SAME
    -- rebuild branch. Combined with the run-scoped anchor on ON.LOADING above, they
    -- rebuild it identically. On a normal camp start the engine raises RESET anyway
    -- and the mod would rebuild regardless, so this only ever removes a difference.
    -- Written as a plain global so it resolves through the MOD's environment (this
    -- block is prepended into its chunk); mods without that global are untouched.
    local moLastRunSeed = nil
    moRealSetCallback(function()
        pcall(function()
            local first = math.floor(get_adventure_seed(false))
            if moLastRunSeed ~= nil and moLastRunSeed ~= first then
                local plan = level_order
                if type(plan) == "table" and #plan > 0 then
                    level_order = {}
                end
            end
            moLastRunSeed = first
        end)
    end, ON.LOADING)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v16 payload (prepended in 1.0.31 only), removed on upgrade to v17.
-- v16 anchored ON.LOADING to the FLOOR, which is not agreed across machines
-- mid-restart, and carried an io-based fingerprint that could never run (a
-- content mod is not `unsafe`, so it has no io).
local SHIM_V16 = "-- " .. MARKER_V16 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    pairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(moPrngFloorBase()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- Both fire exactly ONCE per floor, before the engine draws the layout,
            -- and a content mod decides per-floor things here (Randomizer 2.0 picks
            -- the level dimensions in PRE_LEVEL_GENERATION). Anchoring makes those
            -- decisions a pure function of the floor instead of depending on
            -- whatever the stream carried in from the previous floor's gameplay.
            -- The engine's own layout draw is NOT affected: moAnchorPrng restores
            -- every stream when the hook returns, so this is not the blanket
            -- `seed_prng` at PRE_LEVEL_GENERATION that the note below warns about.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM: those fire once per ROOM, and a constant
            -- per-floor anchor would hand every room identical rolls.
            cb = moAnchorPrng(cb)
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    -- Diagnostic: fingerprint the mod's own run layout once per floor. Randomizer
    -- 2.0 keeps its whole run plan in a GLOBAL named level_order, and generation
    -- reads the NEXT-next entry to theme the exit -- so the two machines can agree
    -- on the floor they are standing on and still generate it differently if the
    -- TAIL of that list diverges. Only a global can be read from here (a mod's
    -- locals are invisible), which is exactly what level_order is. Writes one line
    -- per floor to mo_shimstate.txt in the game folder; diff it between machines.
    -- Costs nothing when the global is absent, which is the case for every mod
    -- that does not use that name.
    moRealSetCallback(function()
        pcall(function()
            local plan = rawget(_G, "level_order")
            if type(plan) ~= "table" then return end
            local hash = 2166136261
            local n = #plan
            for idx = 1, n do
                local e = plan[idx]
                if type(e) == "table" then
                    local w = tonumber(e.w) or -1
                    local l = tonumber(e.l) or -1
                    local t = tonumber(e.t) or -1
                    hash = (hash * 31 + w * 7919 + l * 131 + t) % 2147483647
                end
            end
            local st = get_local_state()
            local f = io.open("mo_shimstate.txt", "a")
            if f == nil then return end
            f:write(string.format("floor w%d-%d th%d lc=%d | level_order n=%d hash=%d\n",
                math.floor(st.world), math.floor(st.level), math.floor(st.theme),
                math.floor(st.level_count), n, hash))
            f:close()
        end)
    end, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v15 payload (prepended in 1.0.30 only), removed on upgrade to v16.
-- v15 left the once-per-floor generation hooks unanchored, so a mod could carry
-- the previous floor's stream state into this floor's decisions.
local SHIM_V15 = "-- " .. MARKER_V15 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Deterministic table iteration. Lua seeds its STRING HASH per process, so
    -- `pairs` walks string keys in a different order on every machine and every
    -- launch. Any loop that draws prng (or spawns) while iterating therefore
    -- produces a different result per machine, from identical inputs. Randomizer
    -- 2.0's shuffle_tile_codes does exactly that: it rolls inside
    -- `for k in pairs(floor_tilecodes)`, and the number of rolls per key varies
    -- (`prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing k), so each
    -- machine mapped different floor types to the same 16 tile codes -- same seed,
    -- same level, identical gen[pre] prng, different tiles and enemies.
    -- Iterating in a SORTED order costs nothing in determinism terms (no correct
    -- mod can depend on hash order, since it is already random per launch) and
    -- makes every such loop agree across machines.
    local moRawPairs = pairs
    local moRank = { number = 1, string = 2, boolean = 3 }
    pairs = function(t)
        if type(t) ~= "table" then return moRawPairs(t) end
        local mt = getmetatable(t)
        if mt ~= nil and rawget(mt, "__pairs") ~= nil then
            return moRawPairs(t) -- respect a custom iterator; not ours to reorder
        end
        local keys, count = {}, 0
        for k in moRawPairs(t) do
            count = count + 1
            keys[count] = k
        end
        local n = rawlen(t)
        if count == n then
            -- Pure sequence: the keys are exactly 1..n, an order every machine
            -- already agrees on, so skip the sort. This is the hot path -- every
            -- get_entities_* result and every per-frame list lands here. Iterate
            -- numerically rather than replaying `keys`, so ascending order does not
            -- depend on how `next` happens to walk the array part.
            -- The count is what makes this test sound: `next(t, n) == nil` only
            -- proves key n is LAST in hash order, and a table holding both t[1] and
            -- string keys can satisfy it -- that dropped every hash key.
            local i = 0
            return function()
                repeat
                    i = i + 1
                    if i > n then return nil end
                until t[i] ~= nil
                return i, t[i]
            end
        end
        local seen = {}
        for idx = 1, count do
            -- discovery index: a total-order tiebreak for keys that cannot be
            -- compared (tables, functions, userdata)
            local sk = keys[idx]
            seen[sk] = idx
        end
        table.sort(keys, function(a, b)
            local ra = moRank[type(a)] or 4
            local rb = moRank[type(b)] or 4
            if ra ~= rb then return ra < rb end
            if ra == 1 or ra == 2 then return a < b end
            if ra == 3 then return b and not a end -- false before true
            return seen[a] < seen[b]
        end)
        local i = 0
        return function()
            while true do
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                local v = t[k]
                -- a key deleted mid-iteration is skipped: pairs never yields nil
                if v ~= nil then return k, v end
            end
        end
    end

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(moPrngFloorBase()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb)
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v14 payload (prepended in 1.0.29 only), removed on upgrade to v15.
-- v14 left `pairs` on Lua's per-process string-hash order, so a mod that rolled
-- prng while iterating a string-keyed table (Randomizer 2.0) got a different
-- result on each machine.
local SHIM_V14 = "-- " .. MARKER_V14 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    -- Run a callback body from a lockstep-identical prng base, then put the
    -- engine's own streams back exactly as they were. The anchor exists so the
    -- body's rolls depend ONLY on the floor -- never on how many values earlier
    -- callbacks drew, and never on HOW MANY callbacks ran (a mid-run join leaves
    -- the joiner's content-mod lua state fresh, which can gate a different set).
    -- Restoring keeps the anchor invisible outside the body: leaving the streams
    -- reseeded leaked our value into everything the mod did for the rest of the
    -- floor, and a mod that owns its own level generation draws from these same
    -- streams, so that leak changed its world.
    local function moAnchorPrng(cb)
        return function(...)
            local moSaved = moSavePrng()
            pcall(function() seed_prng(moPrngFloorBase()) end)
            local moRet = cb(...)
            moRestorePrng(moSaved)
            return moRet
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            cb = moAnchorPrng(cb)
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold
            -- -- which is not lockstep-identical. Randomizer 2.0 lays out the WHOLE
            -- RUN in this callback (init_run: level_order, boss placement, the
            -- chain_items shuffle) and only anchors itself on SEEDED runs
            -- (quest_flags bit 7), so on an adventure run the two machines built
            -- different runs. It showed up as identical gen[pre] prng and an
            -- identical level seed but different tiles, enemies and areas: the
            -- generator reads level_order[level_count+2].t to theme the exit, so a
            -- divergent run ORDER changes the CURRENT floor too.
            cb = moAnchorPrng(cb)
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v13 payload (prepended in 1.0.28 only), removed on upgrade to v14.
-- v13 left ON.LOADING unanchored, so a mod that builds its run layout there
-- (Randomizer 2.0) built a DIFFERENT run on each machine.
local SHIM_V13 = "-- " .. MARKER_V13 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            local moRealCb = cb
            cb = function(...)
                -- SAVE the engine's stream state, anchor it for this hook, then PUT
                -- IT BACK. The anchor exists so each post-gen hook rolls from a
                -- lockstep-identical base (that is what fixed 2.5's mimic and
                -- vault-sac desyncs), but leaving the streams reseeded leaked our
                -- value into everything the mod did for the rest of the floor. A mod
                -- that owns its own level generation draws from these same streams,
                -- so that leak changed its world. Restoring makes the anchor
                -- invisible outside the hook body -- as non-invasive as the old
                -- shim, which never touched the engine prng at all.
                local moSaved = moSavePrng()
                pcall(function() seed_prng(moPrngFloorBase()) end)
                local moRet = moRealCb(...)
                moRestorePrng(moSaved)
                return moRet
            end
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- Carry the elapsed time forward rather than jumping to a fresh epoch, so the
    -- clock is CONTINUOUS -- it must not move discontinuously in EITHER direction.
    -- Both failure modes have been seen for real, and they are symmetric:
    --   backwards (v11, raw time_total) -> pending deadlines land minutes in the
    --     future, so the mod waits them out and the track fades forever;
    --   forwards (v12, +1e6 per restart) -> every pending deadline is instantly
    --     overdue, so the whole queue fires at once and the songs overlap.
    -- Adding exactly the time that was on the clock means a deadline scheduled
    -- before the restart still arrives at the same DISTANCE ahead, which is what
    -- an absolute-timestamp scheduler like the HD mod's music engine assumes. The
    -- +1 keeps it strictly increasing, so per-frame logic never sees a repeat.
    local moBase = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moBase = moBase + moLastTotal + 1 -- restart zeroed time_total
        end
        moLastTotal = moTotal
        return moBase + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v12 payload (prepended in 1.0.27 only), removed on upgrade to v13.
-- v12 added a fixed 1e6-frame epoch at every restart, which overshot: the
-- clock leapt ~4.6 simulated hours forward and the HD mod's queued sounds all
-- came due at once, overlapping. v13 carries the elapsed time instead.
local SHIM_V12 = "-- " .. MARKER_V12 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            local moRealCb = cb
            cb = function(...)
                -- SAVE the engine's stream state, anchor it for this hook, then PUT
                -- IT BACK. The anchor exists so each post-gen hook rolls from a
                -- lockstep-identical base (that is what fixed 2.5's mimic and
                -- vault-sac desyncs), but leaving the streams reseeded leaked our
                -- value into everything the mod did for the rest of the floor. A mod
                -- that owns its own level generation draws from these same streams,
                -- so that leak changed its world. Restoring makes the anchor
                -- invisible outside the hook body -- as non-invasive as the old
                -- shim, which never touched the engine prng at all.
                local moSaved = moSavePrng()
                pcall(function() seed_prng(moPrngFloorBase()) end)
                local moRet = moRealCb(...)
                moRestorePrng(moSaved)
                return moRet
            end
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    -- A synchronized RESTART sets state.time_total back to 0 (Modded Online wipes
    -- the run's progress so every machine's generator agrees on it). Taken raw,
    -- that makes the clock below jump BACKWARDS by the length of the whole
    -- previous run, and any mod scheduling with ABSOLUTE get_ms() timestamps then
    -- sits waiting for a deadline that is suddenly minutes in the future. The HD
    -- mod's music engine does exactly that (next_sound_start_time), which is why
    -- its audio faded out for a long time after an instant restart.
    --
    -- So count the resets and carry a fixed epoch, making the CLOCK monotonic.
    -- Keep that strictly separate from the prng anchor further down, which must
    -- stay a pure function of SYNCED state: the epoch counts resets seen by THIS
    -- process since it launched, so a peer joining a host who has already
    -- restarted once holds epoch 0 while the host holds 1. That is harmless for a
    -- clock (each machine only compares it against itself) and would be fatal for
    -- a shared seed. Hence two accessors -- moRawSimFrame for seeding,
    -- moSimFrame for get_frame/get_ms.
    local function moRawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    -- The step is deliberately larger than any plausible run (1e6 frames is ~4.6
    -- hours of simulated time) so the clock can never fold back on itself. Note
    -- the epoch only advances on a reset this process actually OBSERVES; if the
    -- mod stops calling get_ms across a restart the clock simply carries on from
    -- where it was, which is still monotonic and still safe for a scheduler.
    local MO_EPOCH_STEP = 1000000
    local moEpoch = 0
    local moLastTotal = 0
    local function moSimFrame()
        local moTotal = moRawSimFrame()
        if moTotal < moLastTotal then
            moEpoch = moEpoch + 1 -- time_total went backwards: start a new epoch
        end
        moLastTotal = moTotal
        return moEpoch * MO_EPOCH_STEP + moTotal
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's. This uses the RAW
    -- frame, NOT the monotonic clock above -- see the epoch note.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moRawSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v11 payload (prepended in 0.45.0-1.0.26), removed on upgrade to
-- v12. v11 read state.time_total RAW, so a restart (which zeroes it) sent the
-- mod's clock backwards -- see the epoch comment in the v12 block.
local SHIM_V11 = "-- " .. MARKER_V11 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            local moRealCb = cb
            cb = function(...)
                -- SAVE the engine's stream state, anchor it for this hook, then PUT
                -- IT BACK. The anchor exists so each post-gen hook rolls from a
                -- lockstep-identical base (that is what fixed 2.5's mimic and
                -- vault-sac desyncs), but leaving the streams reseeded leaked our
                -- value into everything the mod did for the rest of the floor. A mod
                -- that owns its own level generation draws from these same streams,
                -- so that leak changed its world. Restoring makes the anchor
                -- invisible outside the hook body -- as non-invasive as the old
                -- shim, which never touched the engine prng at all.
                local moSaved = moSavePrng()
                pcall(function() seed_prng(moPrngFloorBase()) end)
                local moRet = moRealCb(...)
                moRestorePrng(moSaved)
                return moRet
            end
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    local function moSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end

    -- math.random is the MOD'S OWN generator, not the engine prng, and Lua seeds
    -- it per process. Seeding it once per floor (moReseed above) only guarantees
    -- the machines START each floor aligned: any draw taken off the simulated
    -- path -- a render callback, a frame rendered during a lockstep stall or
    -- while a mod holds its own menu pause -- shifts that machine's stream, and
    -- it never comes back for the rest of the floor. The Pit of 100 Trials rolls
    -- math.random for the NUMBER of XP orbs an enemy drops and for each orb's
    -- velocity (rpg.lua:81,108), so a shifted stream shows up as the two players
    -- holding different amounts of XP. Re-anchor at the top of every SIMULATED
    -- frame instead, from the lockstep clock: that makes the stream a pure
    -- function of synced state, so drift accumulated between two sim frames is
    -- wiped before any gameplay logic draws from it. Registered here inside the
    -- prepended block, so it runs BEFORE every callback the mod registers (and
    -- before every ON.FRAME the remap above folds into this same hook). Level
    -- GENERATION is untouched: it runs between PRE_LEVEL_GENERATION and the
    -- first gameplay frame, still on moReseed's per-floor seed.
    -- The odd multiplier keeps consecutive frames' seeds far apart, so the first
    -- draw of a frame is not a near neighbour of the last one's.
    moRealSetCallback(function()
        pcall(function()
            math.randomseed(moPrngFloorBase() ~ (moSimFrame() * 2654435761))
        end)
    end, ON.GAMEFRAME)
end

]]

-- the exact v10 payload (prepended in 0.38.0-0.44.0), removed on upgrade to
-- v11. v10 seeded math.random once per floor, which only guaranteed the two
-- machines STARTED each floor aligned (see the v11 block).
local SHIM_V10 = "-- " .. MARKER_V10 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Snapshot/restore of every engine prng stream (PRNG_CLASS 0..9), so the
    -- per-hook anchor below cannot leak past the hook it is meant to pin.
    local function moSavePrng()
        local saved = {}
        for c = 0, 9 do
            local ok, a, b = pcall(function() return prng:get_pair(c) end)
            if ok and a ~= nil and b ~= nil then
                saved[#saved + 1] = { c, a, b }
            end
        end
        return saved
    end
    local function moRestorePrng(saved)
        for i = 1, #saved do
            local e = saved[i]
            pcall(function() prng:set_pair(e[1], e[2], e[3]) end)
        end
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            local moRealCb = cb
            cb = function(...)
                -- SAVE the engine's stream state, anchor it for this hook, then PUT
                -- IT BACK. The anchor exists so each post-gen hook rolls from a
                -- lockstep-identical base (that is what fixed 2.5's mimic and
                -- vault-sac desyncs), but leaving the streams reseeded leaked our
                -- value into everything the mod did for the rest of the floor. A mod
                -- that owns its own level generation draws from these same streams,
                -- so that leak changed its world. Restoring makes the anchor
                -- invisible outside the hook body -- as non-invasive as the old
                -- shim, which never touched the engine prng at all.
                local moSaved = moSavePrng()
                pcall(function() seed_prng(moPrngFloorBase()) end)
                local moRet = moRealCb(...)
                moRestorePrng(moSaved)
                return moRet
            end
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    local function moSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end
end

]]

-- the exact v9 payload (prepended in 0.37.x), removed on upgrade to v10. v9
-- reseeded the engine prng and LEFT it reseeded, which leaks into everything a
-- content mod does afterwards; v10 restores the streams (see the v10 block).
local SHIM_V9 = "-- " .. MARKER_V9 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            local moRealCb = cb
            cb = function(...)
                pcall(function() seed_prng(moPrngFloorBase()) end)
                return moRealCb(...)
            end
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    local function moReseedPrng()
        pcall(function() seed_prng(moPrngFloorBase()) end)
    end
    moRealSetCallback(moReseedPrng, ON.POST_LEVEL_GENERATION)
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    local function moSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines exactly like the old level_count/time_level pair, but
            -- CONTINUOUS. The old formula (level_count * 10000000 + time_level)
            -- jumped ten million frames at every level boundary, so get_ms() leapt
            -- ~46 HOURS forward -- which wrecks any content mod that schedules with
            -- ABSOLUTE get_ms() timestamps. The HD mod's music engine does exactly
            -- that (next_sound_start_time, psounds_last_clean_time + 10000), so on
            -- finishing a level every queued sound was already overdue and the
            -- track kept restarting instead of ending with the level.
            return math.floor(s.time_total)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end
end

]]

-- the exact v8 payload (prepended in 0.34.0-0.36.x), removed on upgrade to v9.
-- v8 derived the deterministic clock from level_count*10000000 + time_level,
-- which leapt ~46 hours of get_ms() at every level boundary and broke content
-- mods that schedule audio with absolute get_ms() timestamps (see the v9 block).
local SHIM_V8 = "-- " .. MARKER_V8 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng to the SAME per-floor base before EVERY
            -- post-gen hook, so a hook's rolls depend ONLY on the floor -- never on
            -- how many values earlier hooks drew, and never on HOW MANY hooks ran.
            -- v7 mixed in a run-ORDER index, which silently broke whenever the two
            -- machines registered a different NUMBER of post-gen hooks (a mid-run
            -- join leaves the joiner's content-mod lua state fresh, which can gate
            -- a different hook set): every later hook then got a different seed --
            -- e.g. a vault-sac reward rolled an elixir on one machine, a jetpack on
            -- the other. A constant per-floor base has no such dependency. Hooks do
            -- draw correlated first values now, which is a cosmetic variety
            -- trade-off for absolute cross-machine agreement. Layout is final at
            -- POST, so none of this can change the generated world.
            local moRealCb = cb
            cb = function(...)
                pcall(function() seed_prng(moPrngFloorBase()) end)
                return moRealCb(...)
            end
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua), vault-sac rewards
    -- (hooks/vaultsac.lua) and many *feeling/quest post-gen hooks, all on the one
    -- shared stream. This callback owns the lowest POST id so it runs FIRST and
    -- lays down the per-floor base for any consumer that is not a wrapped hook;
    -- the set_callback wrapper above then re-anchors before EVERY post-gen hook.
    -- NEVER reseed prng at PRE_LEVEL_GENERATION: that would reseed the layout draw
    -- and change the generated world.
    local function moReseedPrng()
        pcall(function() seed_prng(moPrngFloorBase()) end)
    end
    moRealSetCallback(moReseedPrng, ON.POST_LEVEL_GENERATION)
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    local function moSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- level_count*BIG keeps it monotonic across floors; the per-level
            -- counter (time_level) is the synced within-level frame number
            return math.floor(s.level_count) * 10000000 + math.floor(s.time_level)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end
end

]]

-- the exact v7 payload (prepended in 0.33.0), removed on upgrade to v8. v7 mixed a
-- run-ORDER index into the per-post-gen-hook prng seed, which diverged when the two
-- machines ran a different NUMBER of post-gen hooks (see the v8 block above).
local SHIM_V7 = "-- " .. MARKER_V7 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback

    -- Per-floor prng basis: lockstep-identical (run-seed FIRST value XOR floor id).
    local function moPrngFloorBase()
        local first = get_adventure_seed(false)
        local nonce = 0
        local sok, s = pcall(get_local_state)
        if sok and s ~= nil then
            nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
        end
        return (math.floor(first) ~ nonce) ~ 0x50524e47
    end

    -- Counts post-gen hooks AS THEY RUN within one POST_LEVEL_GENERATION dispatch
    -- (moReseedPrng resets it to 0 first -- it owns the lowest callback id). 2.5
    -- registers the same post-gen hooks in the same order on every machine, so
    -- they run in the same order and each gets the same tick -> the same seed.
    local moPostGenTick = 0

    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor the whole prng the instant BEFORE this hook runs, so each
            -- post-gen roll (the mimic roll included) is independent of how many
            -- values earlier post-gen hooks drew. A single up-front reseed (v6)
            -- could not stop an earlier hook (hunterfeeling) whose draw count keys
            -- on 2.5's NON-synced faction/crime lua from shifting the shared stream
            -- before the mimic hook. Layout is final at POST, so this cannot change
            -- the generated world.
            local moRealCb = cb
            cb = function(...)
                moPostGenTick = moPostGenTick + 1
                pcall(function()
                    seed_prng(moPrngFloorBase() + moPostGenTick * 0x9E3779B1)
                end)
                return moRealCb(...)
            end
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua) and many *feeling/
    -- quest post-gen hooks, all on the shared stream. A single up-front reseed
    -- (v6) was defeated when an earlier post-gen hook (hunterfeeling) drew a
    -- data-dependent count and shifted the stream before the mimic roll. The
    -- set_callback wrapper above now re-anchors the prng before EVERY post-gen
    -- hook; moReseedPrng owns the lowest POST callback id so it runs FIRST and
    -- resets the per-hook tick to 0 each dispatch (identical order -> identical
    -- per-hook seeds on every machine). Generation is FINISHED at POST, so none
    -- of this changes the layout. NEVER reseed prng at PRE_LEVEL_GENERATION: that
    -- would reseed the layout draw and change the generated world.
    local function moReseedPrng()
        moPostGenTick = 0
        pcall(function() seed_prng(moPrngFloorBase()) end)
    end
    moRealSetCallback(moReseedPrng, ON.POST_LEVEL_GENERATION)
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    local function moSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- level_count*BIG keeps it monotonic across floors; the per-level
            -- counter (time_level) is the synced within-level frame number
            return math.floor(s.level_count) * 10000000 + math.floor(s.time_level)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end
end

]]

-- the exact v6 payload (prepended in 0.30.0-0.32.x), removed on upgrade to v7. v6
-- re-anchored the engine prng ONCE at POST_LEVEL_GENERATION; v7 re-anchors before
-- EVERY post-gen hook (see the v7 block above).
local SHIM_V6 = "-- " .. MARKER_V6 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback
    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value (the run
            -- constant, byte-identical on every machine). The SECOND value drifts
            -- one Weyl step between the world host and peers and does NOT feed
            -- world gen; folding it in (v4) reseeded math.random differently per
            -- machine, diverging 2.5's bare draws and flipping a shopkeeper-hunter
            -- flag on one machine only. Mix in the lockstep-identical floor
            -- identity (world/level/theme) so each floor still varies with no drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Engine PRNG (the shared `prng` object -- NOT math.random). 2.5 draws it
    -- AFTER generation: mimic rolls (hooks/mimicsSpawner.lua) and many *feeling/
    -- quest post-gen hooks. Those draws are not online-safe -- an engine-frame-
    -- coupled consumer (set_interval/set_global_interval, which the ON.FRAME ->
    -- ON.GAMEFRAME remap does NOT cover) that fires a machine-dependent number of
    -- times drifts the shared prng stream, so a post-gen roll lands differently
    -- per machine (a chest becomes a mimic on one side only). Re-anchor the whole
    -- prng here from the SAME lockstep-identical basis as math.random above.
    -- Generation is FINISHED at POST_LEVEL_GENERATION, so this cannot change the
    -- layout -- it only makes post-gen prng consumers deterministic. Registered
    -- via the raw set_callback so it runs BEFORE 2.5's post-gen hooks (lowest
    -- callback id runs first). NEVER at PRE_LEVEL_GENERATION: that would reseed
    -- the layout draw and change the generated world.
    local function moReseedPrng()
        pcall(function()
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            seed_prng((math.floor(first) ~ nonce) ~ 0x50524e47)
        end)
    end
    moRealSetCallback(moReseedPrng, ON.POST_LEVEL_GENERATION)
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    local function moSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- level_count*BIG keeps it monotonic across floors; the per-level
            -- counter (time_level) is the synced within-level frame number
            return math.floor(s.level_count) * 10000000 + math.floor(s.time_level)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end
end

]]

-- the exact v5 payload (prepended in 0.29.0), removed on upgrade to v6. v5 added
-- the FIRST-value-only math.random reseed; v6 also re-anchors the engine prng at
-- POST_LEVEL_GENERATION (see the v6 block above).
local SHIM_V5 = "-- " .. MARKER_V5 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback
    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            -- Seed math.random ONLY from the adventure seed's FIRST value: it is
            -- the run CONSTANT, byte-identical on every machine all run. The
            -- SECOND value drifts by one Weyl step between the world host and its
            -- peers (a benign artifact of host-authoritative per-floor seed
            -- forcing -- the host runs one extra generation at run start) and
            -- does NOT feed world generation. Folding it into the seed (v4 did)
            -- reseeded math.random DIFFERENTLY per machine every floor after the
            -- first -- the exact desync this shim exists to prevent: it diverged
            -- 2.5's bare math.random draws and flipped a shopkeeper-hunter faction
            -- flag on one machine only, spawning a hunter on the host's floor.
            -- Mix in the lockstep-identical floor identity (world/level/theme, the
            -- same basis the engine uses for the world) so each floor still gets
            -- its own stream with zero cross-machine drift.
            local first = get_adventure_seed(false)
            local nonce = 0
            local sok, s = pcall(get_local_state)
            if sok and s ~= nil then
                nonce = math.floor(s.world) * 4096 + math.floor(s.level) * 64 + math.floor(s.theme)
            end
            math.randomseed(math.floor(first) ~ nonce)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them --
    -- cooldowns, get_frame() % N effects, math.randomseed(get_ms()) -- fired on
    -- different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so % N was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    local function moSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- level_count*BIG keeps it monotonic across floors; the per-level
            -- counter (time_level) is the synced within-level frame number
            return math.floor(s.level_count) * 10000000 + math.floor(s.time_level)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end
end

]]

-- the exact v4 payload (prepended through 0.28.x), removed on upgrade to v5.
-- v4 folded get_adventure_seed's drifting SECOND value into the math.random
-- seed, desyncing it across machines; see the v5 block above.
local SHIM_V4 = "-- " .. MARKER_V4 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback
    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            local first, second = get_adventure_seed(false)
            -- floor BEFORE the bitwise XOR: on some builds the seed pair comes
            -- back as floats, and `float ~ float` throws — which the pcall would
            -- swallow, silently SKIPPING the reseed and letting math.random run
            -- free (a hidden, guaranteed desync). Flooring keeps it integer-safe.
            math.randomseed(math.floor(first) ~ math.floor(second))
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    -- Deterministic clocks. The engine's get_frame/get_ms advance with the
    -- RENDER loop (uncapped on borderless, and it keeps ticking through loading
    -- screens, pauses and lockstep stalls), so any mod logic keyed to them —
    -- cooldowns, `get_frame() % N` effects, `math.randomseed(get_ms())` — fired
    -- on different frames per machine and desynced whole worlds. get_frame's
    -- ABSOLUTE value is even worse: it starts from however many frames this
    -- machine happened to render before the mod loaded, so `% N` was already out
    -- of phase between machines on frame one. Re-derive both purely from
    -- lockstep-synced simulation state (level_count + per-level frame counter),
    -- which is identical on every machine, frame for frame.
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    local function moSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- level_count*BIG keeps it monotonic across floors; the per-level
            -- counter (time_level) is the synced within-level frame number
            return math.floor(s.level_count) * 10000000 + math.floor(s.time_level)
        end
        return moFrame -- outside a run (menus/camp): a monotonic local fallback
    end
    get_frame = function() return moSimFrame() end
    get_ms = function() return moSimFrame() * (1000.0 / 60.0) end
end

]]

-- the exact v2 payload (prepended in 0.13.0), removed on upgrade
local SHIM_V2 = "-- " .. MARKER_V2 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback
    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            local first, second = get_adventure_seed(false)
            math.randomseed(first ~ second)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
end

]]

-- the exact v3 payload (prepended in 0.13.x), removed on upgrade
local SHIM_V3 = "-- " .. MARKER_V3 .. [[ auto-added by Modded Online; safe to delete this block.
do
    local moRealSetCallback = set_callback
    set_callback = function(cb, id)
        if id == ON.FRAME then
            id = ON.GAMEFRAME -- engine-frame rate is machine-dependent; gameplay rate is deterministic
        end
        return moRealSetCallback(cb, id)
    end
    local function moReseed()
        pcall(function()
            local first, second = get_adventure_seed(false)
            math.randomseed(first ~ second)
        end)
    end
    moRealSetCallback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
    local moRealGetFrame = get_frame
    local moFrame = 0
    pcall(function() moFrame = moRealGetFrame() end)
    moRealSetCallback(function() moFrame = moFrame + 1 end, ON.GAMEFRAME)
    get_frame = function() return moFrame end -- ticks once per SIMULATED frame
end

]]

-- the exact v1 payload (appended in 0.10.0), removed on upgrade
local SHIM_V1 = [[

-- ]] .. MARKER_V1 .. [[ auto-added by Modded Online; safe to delete.
-- Re-seeds math.random from the shared adventure seed each level so that
-- networked lockstep runs roll identical dice on every machine. Offline
-- runs are unaffected (the adventure seed changes every level and run).
do
    local function moReseed()
        pcall(function()
            local first, second = get_adventure_seed(false)
            math.randomseed(first ~ second)
        end)
    end
    set_callback(moReseed, ON.PRE_LEVEL_GENERATION)
    moReseed()
end
]]

-- ------------------------------------------------ which shim each pack gets
--
-- EVERY pack gets the SAME shim (the current one). An A/B test isolated the HD
-- mod's desync to our ENGINE-INTERNAL COFFIN FIXES, not to the shim: with the
-- coffin work disabled, the HD mod runs correctly on the full shim. Those fixes
-- are what is scoped to Spelunky 2.5 now — see Network.fullTreatmentMod() in
-- src/netCore.lua — so the shim can stay universal, and every mod keeps the
-- prng anchoring (with its save/restore) and the continuous clock.
--
-- every payload we have ever written, so injectInto can clear whichever one a
-- pack is carrying (a per-pack variant from an earlier build included) before
-- writing the current one
local ALL_SHIMS = {
    SHIM, SHIM_V27, SHIM_V26, SHIM_V25, SHIM_V24, SHIM_V23, SHIM_V22, SHIM_V21, SHIM_V20, SHIM_V19, SHIM_V18, SHIM_V17, SHIM_V16, SHIM_V15, SHIM_V14, SHIM_V13, SHIM_V12, SHIM_V11, SHIM_V10, SHIM_V9, SHIM_V8, SHIM_V7, SHIM_V6,
    SHIM_V5, SHIM_V4, SHIM_V3, SHIM_V2, SHIM_V1,
}

-- the same, for the option-sync block (only one version so far)
local ALL_OPT_SHIMS = { OPT_SHIM }

--- @param path string
--- @return string?
local function readFile(path)
    local ok, content = pcall(function()
        local f = io.open(path, "r")
        if f == nil then
            return nil
        end
        local data = f:read("*a")
        f:close()
        return data
    end)
    return ok and content or nil
end

--- Enabled pack names from the load order (lines not starting with --).
--- @return string[]
local function enabledPacks()
    local names = {}
    local content = readFile(PACKS_DIR .. "load_order.txt")
    if content == nil then
        return names
    end
    for rawLine in content:gmatch("[^\r\n]+") do
        local line = rawLine:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 2) ~= "--" and not SKIP[line] then
            names[#names + 1] = line
        end
    end
    return names
end

--- Which blocks does this pack need? One walk of its .lua files answers both
--- questions, and they are independent: a mod can roll no dice at all and still
--- have settings that decide what it generates.
--- @param packName string
--- @return boolean # needs the determinism shim
--- @return boolean # needs the option-sync block
local function packNeeds(packName)
    local listing = nil
    pcall(function()
        local pipe = io.popen(string.format('dir /s /b "%s%s\\*.lua" 2>nul',
            PACKS_DIR:gsub("/", "\\"), packName))
        if pipe ~= nil then
            listing = pipe:read("*a")
            pipe:close()
        end
    end)
    if listing == nil then
        return false, false
    end
    local needShim, needOpts = false, false
    for filePath in listing:gmatch("[^\r\n]+") do
        local content = readFile(filePath)
        if content ~= nil then
            if not needShim then
                for _, pattern in ipairs(NEEDS_SHIM_PATTERNS) do
                    if content:find(pattern) ~= nil then
                        needShim = true
                        break
                    end
                end
            end
            if not needOpts then
                for _, pattern in ipairs(NEEDS_OPTIONS_PATTERNS) do
                    if content:find(pattern) ~= nil then
                        needOpts = true
                        break
                    end
                end
            end
            if needShim and needOpts then
                return true, true
            end
        end
    end
    return needShim, needOpts
end

--- Add (or upgrade) Modded Online's blocks in one pack's main.lua. Both are
--- PREPENDED so their set_callback wrappers are in place before the mod
--- registers anything. Idempotent via the markers; older payloads of either
--- block are removed on upgrade.
--- @param packName string
--- @param needShim boolean
--- @param needOpts boolean
--- @return boolean # true if anything was newly added or upgraded
local function injectInto(packName, needShim, needOpts)
    local mainPath = PACKS_DIR .. packName .. "/main.lua"
    local content = readFile(mainPath)
    if content == nil then
        return false -- not a script pack (data-only mods have no main.lua)
    end
    local hasShim = content:find(MARKER, 1, true) ~= nil
    local hasOpts = content:find(OPT_MARKER, 1, true) ~= nil
    if (hasShim or not needShim) and (hasOpts or not needOpts) then
        return false -- already carries everything this build wants
    end
    -- A block already present is KEPT even if this build would not add it: the
    -- patterns above are a heuristic, and silently taking determinism work back
    -- out of a mod that has been playing fine with it is not this function's call.
    local wantShim = needShim or hasShim
    local wantOpts = needOpts or hasOpts
    -- clear every payload we know of, so upgrading (or coming back from a
    -- per-pack variant an earlier build wrote) can never leave two blocks stacked
    for _, old in ipairs(ALL_SHIMS) do
        content = content:gsub(old:gsub("[%[%]%(%)%.%%%+%-%*%?%^%$]", "%%%0"), "")
    end
    for _, old in ipairs(ALL_OPT_SHIMS) do
        content = content:gsub(old:gsub("[%[%]%(%)%.%%%+%-%*%?%^%$]", "%%%0"), "")
    end
    -- determinism shim FIRST: netCore's packShimVersion reads the head of this
    -- file to fingerprint both markers, and this keeps their order stable
    local prefix = (wantShim and SHIM or "") .. (wantOpts and OPT_SHIM or "")
    local ok = pcall(function()
        local f = assert(io.open(mainPath, "w"))
        f:write(prefix .. content)
        f:close()
    end)
    return ok
end

--- Scan and shim everything that needs it. Returns the newly shimmed names.
--- @return string[]
function module.run()
    local added = {}
    for _, packName in ipairs(enabledPacks()) do
        local ok, result = pcall(function()
            local needShim, needOpts = packNeeds(packName)
            return (needShim or needOpts) and injectInto(packName, needShim, needOpts)
        end)
        if ok and result == true then
            added[#added + 1] = packName
            dbgf("Modded Online blocks added to '%s'", packName)
        end
    end
    if #added > 0 then
        dbg("RESTART the game so the shimmed mods reload!")
        module.pendingRestart = true
    end
    return added
end

--- true when shims were added this boot and a restart is needed
module.pendingRestart = false
-- exposed for diagnostics and tests
module.SHIM = SHIM
module.SHIM_V1 = SHIM_V1
module.SHIM_V2 = SHIM_V2
module.SHIM_V3 = SHIM_V3
module.SHIM_V4 = SHIM_V4
module.SHIM_V5 = SHIM_V5
module.SHIM_V6 = SHIM_V6
module.SHIM_V7 = SHIM_V7
module.SHIM_V8 = SHIM_V8
module.SHIM_V9 = SHIM_V9
module.OPT_SHIM = OPT_SHIM
module.MARKER = MARKER
module.OPT_MARKER = OPT_MARKER
module.MARKER_V4 = MARKER_V4
module.MARKER_V5 = MARKER_V5
module.MARKER_V6 = MARKER_V6
module.MARKER_V7 = MARKER_V7
module.MARKER_V8 = MARKER_V8
module.MARKER_V9 = MARKER_V9

-- OPT IN, not out. The shipping build injects unless told otherwise; this one is
-- the build whose entire purpose is not to, and it keeps the module loaded only so
-- that modHost.stripPayloads can recognise a block a previous build left behind.
-- Set autoShim = true in config.json if you need the old behaviour back for a
-- comparison run.
if Network ~= nil and Network.config ~= nil and Network.config.autoShim == true then
    SafeCall("shimInjector:run", module.run)
end

ShimInjector = module
return module
