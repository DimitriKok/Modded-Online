--- Modded Online — determinism core for hosted content mods.
---
--- Everything here exists because a networked run generates its world locally on
--- every machine from one shared seed, and only inputs travel. That only works if
--- every machine's Lua behaves identically, and mods are full of things that do not.
--- Each mechanism below has a real desync behind it; the comments say which, because
--- that is the only reason any of it is worth the complexity.
---
--- This is the same feature set the injected determinism payload provided, lifted
--- into the host. Three things change by moving it here, and all three are
--- improvements:
---
---  * It is **mod-agnostic**. The payload grew `if POSTTILE_STARTBOOL ~= nil` and
---    `Sp25GameClass` tests inline, so its universal parts and its per-mod parts were
---    tangled. Here the core applies to every hosted mod and per-mod behaviour lives
---    in adapters that feature-detect, so a mod nobody has heard of is covered.
---  * We own callback ordering. The payload had to be *prepended* to the mod's file
---    to register ahead of it, which is where the v25 nil-callback bug came from.
---  * The hosted mod gets its **own** generator (see below), rather than sharing the
---    Lua state's one.
---
--- @class DeterminismControl
--- @field newRun fun() # called when a new run is detected; adapters hook here
--- @field floorBase fun(): integer
--- @field simFrame fun(): integer
--- @field stats fun(): table

local module = {}

-- ------------------------------------------------------------ ordered iteration

local rawPairs = pairs
local RANK = { number = 1, string = 2, boolean = 3 }

--- `pairs` with an order every machine agrees on.
---
--- Not cosmetic. Lua seeds its string hashing per state, so two machines walk the
--- same table in different orders — and iteration order decides how many times the
--- shared PRNG is drawn, which decides the world. This is what desynced Randomizer
--- 2.0: `prng:random() < 0.05 and k ~= "floor"` draws BEFORE testing the key, so a
--- different order is a different number of draws and every draw after it shifts.
--- @param t table
function module.orderedPairs(t)
    if type(t) ~= "table" then
        return rawPairs(t)
    end
    local mt = getmetatable(t)
    if mt ~= nil and rawget(mt, "__pairs") ~= nil then
        return rawPairs(t) -- respect a custom iterator; not ours to reorder
    end
    local keys, count = {}, 0
    for k in rawPairs(t) do
        count = count + 1
        keys[count] = k
    end
    local n = rawlen(t)
    if count == n then
        -- Pure sequence: the keys are exactly 1..n, an order every machine already
        -- agrees on, so skip the sort. This is the hot path — every get_entities_*
        -- result and every per-frame list lands here. Iterate numerically rather
        -- than replaying `keys`, so ascending order does not depend on how `next`
        -- happens to walk the array part.
        -- The COUNT is what makes this test sound: `next(t, n) == nil` only proves
        -- key n is last in hash order, and a table holding both t[1] and string keys
        -- can satisfy that — which silently dropped every hash key.
        local i = 0
        return function()
            repeat
                i = i + 1
                if i > n then
                    return nil
                end
            until t[i] ~= nil
            return i, t[i]
        end
    end
    local seen = {}
    for idx = 1, count do
        -- discovery index: a total-order tiebreak for keys that cannot be compared
        -- against each other (tables, functions, userdata)
        seen[keys[idx]] = idx
    end
    table.sort(keys, function(a, b)
        local ra = RANK[type(a)] or 4
        local rb = RANK[type(b)] or 4
        if ra ~= rb then
            return ra < rb
        end
        if ra == 1 or ra == 2 then
            return a < b
        end
        if ra == 3 then
            return b and not a -- false before true
        end
        return seen[a] < seen[b]
    end)
    local i = 0
    return function()
        while true do
            i = i + 1
            local k = keys[i]
            if k == nil then
                return nil
            end
            local v = t[k]
            -- a key deleted mid-iteration is skipped: pairs never yields nil
            if v ~= nil then
                return k, v
            end
        end
    end
end

-- --------------------------------------------------------- the mod's own generator

--- A hosted mod must NOT be given Lua's `math.random`.
---
--- Under the old injected payload each pack had its own Lua state, so reseeding the
--- mod's generator was contained. Hosting puts the mod in OUR state, where
--- `math.randomseed` would reach Modded Online's own generator —
--- `netCore.lua:183` seeds it from the wall clock to build a client id, which is
--- exactly the kind of unsynced value that must never touch a mod's stream.
---
--- So each hosted mod gets a private xorshift64*. It does not need to match Lua's
--- xoshiro256\*\*; it needs both machines to produce the same sequence from the same
--- seed, which a fixed algorithm in pure Lua guarantees across Lua builds too.
--- @param seed integer
--- @return table # { random = fun, randomseed = fun }
function module.newGenerator(seed)
    local state = 0

    --- xorshift64*, on the full 64 bits.
    ---
    --- Lua 5.4 integers ARE 64-bit and both multiply and shift-left wrap, so the
    --- algorithm needs no masking — and masking is not harmless. Clamping the state
    --- to 63 bits cost the top bit of every output, which made `random()` return
    --- values only in [0, 0.5): half the range never appeared. A bucket test caught
    --- it, which is why there is one in the suite.
    local function step()
        state = state ~ (state >> 12)
        state = state ~ (state << 25)
        state = state ~ (state >> 27)
        return state * 0x2545F4914F6CDD1D
    end

    local function reseed(x)
        -- 0 is a fixed point of xorshift, so the state must never be zero
        state = math.floor(tonumber(x) or 0) ~ 0x9E3779B97F4A7C15
        if state == 0 then
            state = 0x9E3779B97F4A7C15
        end
        -- discard a few, so seeds differing only in low bits diverge immediately
        for _ = 1, 8 do
            step()
        end
    end

    reseed(seed)

    --- Lua's own contract: no args -> [0,1); one arg m -> 1..m; two -> m..n.
    local function random(m, n)
        if m == nil then
            -- `>>` is logical in Lua, so this is 53 non-negative bits whatever the
            -- sign of the step output, and 2^53 is the exact float mantissa limit
            return (step() >> 11) * (1.0 / 9007199254740992.0)
        end
        m = math.floor(m)
        if n == nil then
            n = m
            m = 1
        else
            n = math.floor(n)
        end
        if m > n then
            error("bad argument to 'random' (interval is empty)", 2)
        end
        -- >> 1 first: a negative step output would make % return a negative index.
        -- The modulo bias is identical on every machine, which is what matters here.
        return m + (step() >> 1) % (n - m + 1)
    end

    return { random = random, randomseed = reseed }
end

-- ------------------------------------------------------------------- engine PRNG

--- The run's shared basis: the adventure seed's FIRST value, which every machine in
--- a run holds identically. The second value evolves per floor and drifts benignly.
--- @return integer
function module.runBase()
    local first = 0
    pcall(function()
        first = math.floor(get_adventure_seed(false))
    end)
    return first
end

--- Per-floor basis: lockstep-identical, and different on every floor so a mod that
--- draws from it does not repeat itself. world/level/theme are part of the synced
--- state, so this is the same number on every machine at the same floor.
--- @return integer
function module.floorBase()
    local base = module.runBase()
    pcall(function()
        local st = get_local_state()
        base = base ~ (math.floor(st.world) * 4096
            + math.floor(st.level) * 64 + math.floor(st.theme))
    end)
    return base
end

--- Snapshot every engine PRNG stream (PRNG_CLASS 0..9).
---
--- `pcall(prng.get_pair, prng, c)` rather than a closure per iteration: this runs
--- around every anchored hook and the closures were a measurable allocation.
--- @return table
function module.savePrng()
    local saved = {}
    for c = 0, 9 do
        local ok, a, b = pcall(prng.get_pair, prng, c)
        if ok and a ~= nil and b ~= nil then
            saved[#saved + 1] = { c, a, b }
        end
    end
    return saved
end

--- @param saved table
function module.restorePrng(saved)
    for i = 1, #saved do
        local e = saved[i]
        pcall(prng.set_pair, prng, e[1], e[2], e[3])
    end
end

local function seedFromBase(base)
    seed_prng(base())
end

--- Run a callback from a lockstep-identical PRNG base, then put the engine's own
--- streams back exactly as they were.
---
--- The anchor makes the body's rolls depend ONLY on the floor — never on how many
--- values earlier callbacks drew, and never on HOW MANY callbacks ran, which matters
--- because a mid-run join leaves the joiner's mod state fresh and can gate a
--- different set. Restoring keeps the anchor invisible outside the body: leaving the
--- streams reseeded leaked our value into everything the mod did for the rest of the
--- floor, and a mod that owns its own generation draws from those same streams.
--- @param cb function
--- @param base fun(): integer
--- @return function
function module.anchor(cb, base)
    return function(...)
        local saved = module.savePrng()
        pcall(seedFromBase, base)
        local ret = cb(...)
        module.restorePrng(saved)
        return ret
    end
end

-- ------------------------------------------------------------------- the clock

--- `get_frame` and `get_ms` for a hosted mod, derived from simulated state.
---
--- The engine's own advance with the RENDER loop — uncapped on borderless, still
--- ticking through loading screens, pauses and lockstep stalls — so any mod logic
--- keyed to them fires on different frames per machine. The absolute value is worse
--- still: it starts from however many frames this machine happened to render before
--- the mod loaded, so `get_frame() % N` is out of phase on frame one.
--- @return table # { frame, ms, invalidate, tick, newRun }
function module.newClock()
    local base, lastTotal = 0, 0
    local localFrame = 0
    local valid, value = false, 0

    local function rawSimFrame()
        local ok, s = pcall(get_local_state)
        if ok and s ~= nil then
            -- time_total is the run's TOTAL simulated frame count: synced across
            -- machines, and CONTINUOUS. The older level_count*1e7 + time_level form
            -- jumped ten million frames at every boundary, so get_ms() leapt ~46
            -- hours forward and any mod scheduling on absolute timestamps broke.
            return math.floor(s.time_total)
        end
        return localFrame -- outside a run (menus/camp): a monotonic local fallback
    end

    --- Memoized per simulated frame. Mods call get_frame from per-entity update
    --- paths, so this ran once per live entity per frame to read a number that
    --- cannot change within the frame.
    local function simFrame()
        if valid then
            return value
        end
        local total = rawSimFrame()
        if total < lastTotal then
            -- A restart zeroes time_total. Carry the elapsed time FORWARD rather
            -- than jumping: the clock must not move discontinuously in either
            -- direction. Backwards leaves pending deadlines minutes in the future
            -- (a track fades forever); forwards makes every deadline instantly
            -- overdue (the whole queue fires at once and songs overlap). Both have
            -- been seen for real. +1 keeps it strictly increasing.
            base = base + lastTotal + 1
        end
        lastTotal = total
        value = base + total
        valid = true
        return value
    end

    return {
        rawSimFrame = rawSimFrame,
        frame = simFrame,
        ms = function() return simFrame() * (1000.0 / 60.0) end,
        invalidate = function() valid = false end,
        tickLocal = function() localFrame = localFrame + 1 end,
    }
end

-- --------------------------------------------------------------------- install

--- Give a hosted mod's environment every guarantee above.
---
--- Called once per hosted mod, after the host has put its own wrappers in place, so
--- the `set_callback` chained here is whatever the host installed and both layers
--- compose. Our own callbacks are registered with the ENGINE's `set_callback`, not
--- the sandbox one, and this runs before the mod's chunk does — so ours are ahead of
--- every callback the mod registers. The injected payload had to be prepended to the
--- mod's file to achieve that, and got it wrong once.
---
--- @param env table            # the sandbox the mod will run in
--- @param opts table?          # { orderedPairs = boolean }
--- @return DeterminismControl
function module.install(env, opts)
    opts = opts or {}
    local clock = module.newClock()
    local gen = module.newGenerator(module.floorBase())
    local matched = {}
    local runPlan = false
    local lastRunSeed = nil
    local stats = { reseeds = 0, newRuns = 0, anchored = 0 }
    local control -- forward: checkNewRun hands it to adapters

    -- ---------------------------------------------------------------- primitives

    -- A COPY of math, so the mod's randomseed cannot reach the generator Modded
    -- Online itself uses. Under the injected payload each pack had its own Lua
    -- state and this was free; hosting makes it something we have to do on purpose.
    local mathCopy = {}
    for k, v in rawPairs(math) do
        mathCopy[k] = v
    end
    mathCopy.random = gen.random
    mathCopy.randomseed = gen.randomseed
    env.math = mathCopy

    -- Default ON for every hosted mod. The payload switched this on only for mods
    -- it had already watched desync, which is no help to a mod nobody has tested.
    -- It costs iteration speed on tables with non-sequence keys; that is the right
    -- trade for a guarantee, and `orderedPairs = false` is there for a mod that
    -- measurably cannot afford it.
    if opts.orderedPairs ~= false then
        env.pairs = module.orderedPairs
    end

    env.get_frame = clock.frame
    env.get_ms = clock.ms

    -- ------------------------------------------------------- per-floor anchoring

    local function floorBase()
        return module.floorBase()
    end

    --- Which basis ON.LOADING anchors on. It is ALWAYS anchored. Only the basis
    --- differs: a run-plan mod needs the run-scoped one, because during a
    --- synchronized restart the machines demonstrably disagree on world/level/theme
    --- and quest_flags at ON.LOADING — the host's engine is mid-reset while a peer
    --- is only being warped — at exactly the moment such a mod lays out its run.
    local function loadBase()
        if runPlan then
            return module.runBase()
        end
        return module.floorBase()
    end

    local hostSetCallback = rawget(env, "set_callback") or set_callback

    env.set_callback = function(cb, id)
        if id == ON.FRAME then
            -- engine-frame rate is machine-dependent; the gameplay rate is not
            id = ON.GAMEFRAME
        elseif id == ON.POST_LEVEL_GENERATION then
            -- Re-anchor to the SAME per-floor base before EVERY post-gen hook, so a
            -- hook's rolls depend only on the floor — never on how many values
            -- earlier hooks drew, and never on HOW MANY hooks ran. A mid-run join
            -- leaves the joiner's mod state fresh and can gate a different hook set,
            -- which is what made a vault sacrifice roll an elixir on one machine and
            -- a jetpack on the other. Layout is final at POST, so this cannot change
            -- the generated world.
            stats.anchored = stats.anchored + 1
            cb = module.anchor(cb, floorBase)
        elseif id == ON.PRE_LEVEL_GENERATION or id == ON.PRE_LOAD_LEVEL_FILES then
            -- Both fire once per floor, before the engine draws the layout, and a
            -- mod decides per-floor things here. Anchored only for a run-plan mod:
            -- gating this off entirely is v11 behaviour, which is the build where a
            -- layer-door press booked a travel that never fired.
            -- Deliberately NOT applied to POST_ROOM_GENERATION or
            -- PRE_GET_RANDOM_ROOM, which fire once per ROOM — a constant per-floor
            -- anchor would hand every room identical rolls.
            if runPlan then
                stats.anchored = stats.anchored + 1
                cb = module.anchor(cb, floorBase)
            end
        elseif id == ON.LOADING then
            -- ON.LOADING fires BEFORE the engine seeds the prng from the level seed,
            -- so anything drawn here comes off whatever the stream happened to hold,
            -- which is not lockstep-identical. A run-plan mod lays out its WHOLE RUN
            -- in this callback, so the two machines built different runs from the
            -- same seed: identical level seed, different tiles, enemies and areas.
            stats.anchored = stats.anchored + 1
            cb = module.anchor(cb, loadBase)
        end
        return hostSetCallback(cb, id)
    end

    -- ------------------------------------------------------------------ our own

    --- A new run, detected from the one signal every machine sees on the same
    --- lockstep frame: the adventure seed's first value changing. Only the machine
    --- whose player pressed restart sees the engine raise QUEST_FLAG.RESET; every
    --- peer is warped by our ordered run_start, so keying off the flag desyncs.
    local function checkNewRun()
        local first = module.runBase()
        if lastRunSeed ~= nil and lastRunSeed ~= first then
            stats.newRuns = stats.newRuns + 1
            for _, adapter in ipairs(matched) do
                pcall(adapter.newRun, env, control)
            end
        end
        lastRunSeed = first
    end

    -- Determinism is for AGREEING WITH ANOTHER MACHINE. Outside a room there is no
    -- other machine, and forcing it there is not neutral -- it is a bug the player
    -- sees: seeding the mod's `math.random` from the floor base every floor made
    -- every single 1-1 come out with the same level feeling, run after run, in
    -- ordinary single-player. Hosting a mod must not change how it plays alone.
    --
    -- Defaults to always-on so the tests, which have no network, keep exercising it.
    local isActive = opts.active or function() return true end

    local function onLoading()
        clock.invalidate()
        if not isActive() then
            return
        end
        checkNewRun()
    end

    local function onFloor()
        clock.invalidate()
        if not isActive() then
            return -- solo: leave the mod's own randomness alone
        end
        -- math.random is the MOD's generator, and seeding it once per floor is what
        -- makes the machines START each floor aligned.
        stats.reseeds = stats.reseeds + 1
        gen.randomseed(module.floorBase())
    end

    local function onFrame()
        clock.tickLocal()
        clock.invalidate()
        -- Re-anchor every SIMULATED frame. Seeding once per floor only aligns the
        -- start: any draw taken off the simulated path — a render callback, a frame
        -- rendered during a lockstep stall or while a mod holds its own pause —
        -- shifts that machine's stream and it never comes back. The Pit of 100
        -- Trials rolls for the NUMBER of xp orbs an enemy drops, so a shifted stream
        -- showed up as the two players holding different amounts of xp.
        gen.randomseed(module.floorBase() ~ (clock.rawSimFrame() * 2654435761))
    end

    set_callback(onLoading, ON.LOADING)
    set_callback(onFloor, ON.PRE_LEVEL_GENERATION)
    set_callback(onFrame, ON.GAMEFRAME)
    set_callback(clock.invalidate, ON.PRE_LOAD_SCREEN)

    control = {
        newRun = checkNewRun,
        floorBase = module.floorBase,
        simFrame = clock.frame,
        stats = function() return stats end,
        --- Adapters are matched AFTER the mod's chunk has run: the globals they look
        --- for cannot exist before it. The host calls this.
        detectAdapters = function()
            for _, adapter in ipairs(module.adapters) do
                local ok, hit = pcall(adapter.detect, env)
                if ok and hit then
                    matched[#matched + 1] = adapter
                    if adapter.name == "run-plan" then
                        runPlan = true
                    end
                end
            end
            return matched
        end,
        matched = function() return matched end,
    }
    return control
end

-- ------------------------------------------------------------------- adapters

--- Per-mod behaviour, kept OUT of the core.
---
--- The injected payload tested for `level_order` and `POSTTILE_STARTBOOL` inline,
--- which made its universal parts unreadable and meant a mod nobody had written an
--- `if` for got nothing. An adapter declares what it recognises and what to do about
--- it; the core calls every adapter that matches, and a mod matching none still gets
--- the full core.
--- @type table[]
module.adapters = {}

--- @param adapter table # { name, detect(env) -> boolean, newRun(env, ctx),
---   startDoor(env, dest) -> boolean, reassert(env) -> string? }
---
--- `startDoor` is called on EVERY machine when a run begins, with the camp door's
--- destination the run was started from (`{world, level, theme}`, or nil for the
--- main exit). It exists because a camp door online is inert: Modded Online detects
--- the press and starts the run for the party instead of letting one player walk
--- through, so a mod that keys behaviour off a player physically entering a specific
--- door never sees it happen. Returning true means the adapter recognised the door.
---
--- `reassert` is called again on the run's FIRST level generation, only for adapters
--- whose `startDoor` returned true. `startDoor` has to run at run_start -- before
--- the warp is booked, while the camp door it matches on still exists -- but the mod
--- gets its own load and reset callbacks in between, and those may put the state
--- back. So the recognition happens once, at the only moment the evidence is there,
--- and the *consequence* is re-applied at the last moment before the world is built.
--- It must NOT re-run the door match: by then the camp is gone and the door's uid
--- may have been recycled by another entity. Return a short string describing what
--- it found for the log -- that is what says whether anything clobbered the state.
function module.register(adapter)
    module.adapters[#module.adapters + 1] = adapter
end

--- Run-plan mods rebuild their whole route when they see the engine raise
--- QUEST_FLAG.RESET — but only the machine whose player pressed restart sees it;
--- every peer is warped by our ordered run_start. The presser rebuilt while the
--- peers silently kept the DEAD run's plan, so the peer regenerated the floor it had
--- just restarted away from. Clearing the plan makes every machine take the same
--- rebuild branch.
module.register({
    name = "run-plan",
    detect = function(env)
        return type(rawget(env, "level_order")) == "table"
    end,
    newRun = function(env)
        if #rawget(env, "level_order") > 0 then
            rawset(env, "level_order", {})
        end
    end,
})

--- The HD mod keeps its own run plan — which level each "feeling" loads on, whether
--- the worm has been visited — and rebuilds it when POSTTILE_STARTBOOL is false. The
--- only thing that clears that flag is its own ON.RESET, which a warped peer never
--- receives.
module.register({
    name = "posttile-start",
    detect = function(env)
        return rawget(env, "POSTTILE_STARTBOOL") ~= nil
    end,
    newRun = function(env)
        rawset(env, "POSTTILE_STARTBOOL", false)
    end,
})

--- Where each hosted mod's tutorial door LED, remembered from the last camp.
---
--- An instant restart re-sends the door the run began at (the server keeps it on the
--- room so a restart returns to the same shortcut), but by then the camp is gone and
--- `DOOR_TUTORIAL_UID` names a dead entity -- so restarting inside the tutorial read
--- as "not the tutorial door" and dropped the party into an ordinary run. Reading it
--- is only possible while the camp is up; comparing against it is not, so the read
--- and the comparison are separated.
---
--- Keyed by sandbox, so two hosted packs cannot collide, and deliberately NOT stored
--- in the mod's own globals: `pairs` is determinized over that table and a key we
--- invented would be handed to the mod's own iteration.
---
--- Every machine fills this from its own camp at the same run start, so it holds the
--- same value everywhere -- it cannot make one machine generate a different world
--- than another.
--- @type table<table, integer[]>
local tutorialTarget = setmetatable({}, { __mode = "k" })

--- The HD mod's tutorial is entered through a camp door, and online that door is
--- inert -- so the thing that starts the tutorial never happens.
---
--- hdmod watches for a player physically overlapping DOOR_TUTORIAL_UID in
--- CHAR_STATE.ENTERING and only then sets `HD_WORLDSTATE_STATE = TUTORIAL`
--- (`lib/camp/camp.lua:104-120`, installed as a per-frame interval at camp setup).
--- Everything downstream branches on that value: room generation, spikes, flags,
--- touchups. Online, Modded Online makes every camp door inert on purpose -- one
--- player walking through would start a solo run -- so the interval never fires, the
--- state stays NORMAL, and walking into the tutorial door generates an ordinary 1-1.
--- That is the reported "it just took us into a run".
---
--- The destination already travels: `pollCampDoor` reads `door:get_target()` for
--- every FLOOR_DOOR_STARTING_EXIT, the host's door rides along in `run_start`, and
--- the tutorial door is one (hdmod spawns it with `spawn_door(x, y, l, 1, 1,
--- THEME.DWELLING)`). So each machine can match that destination against ITS OWN
--- tutorial door and set the state the mod would have set itself.
---
--- Matching on the door rather than on the literal 1-1 matters: the main exit sends
--- no destination at all, so starting a normal run can never be mistaken for this.
---
--- `detect` deliberately asks only for `worldlib`. It used to require `camplib` in
--- the same breath, and detection happens ONCE -- immediately after the mod's main
--- chunk runs (`ModHost.host`) -- so a global the mod assigns any later than that
--- made the adapter invisible for the rest of the session, silently and with no way
--- to tell that from "this mod is not hdmod". `worldlib.HD_WORLDSTATE_STATUS` is
--- already specific enough to name this mod; `camplib` is what the adapter WORKS on,
--- not what identifies it, so it is looked up when it is used instead.
module.register({
    name = "hd-tutorial-door",
    detect = function(env)
        local world = rawget(env, "worldlib")
        return type(world) == "table"
            and type(rawget(world, "HD_WORLDSTATE_STATUS")) == "table"
    end,
    --- @return boolean # recognised, and a reason string when it was not
    startDoor = function(env, dest)
        if type(dest) ~= "table" or dest[1] == nil then
            return false, "no door (the main exit)"
        end
        local world = rawget(env, "worldlib")
        local camp = rawget(env, "camplib")
        if type(camp) ~= "table" then
            return false, "the mod has no camplib global yet"
        end
        local uid = rawget(camp, "DOOR_TUTORIAL_UID")
        local target, why = tutorialTarget[env], nil
        if uid ~= nil then
            pcall(function()
                -- the door is still there: the run starts from the camp we are
                -- leaving, which is the only time this can be read at all
                local door = get_entity(math.floor(uid))
                if door == nil then
                    return
                end
                local w, l, t = door:get_target()
                if w ~= nil then
                    target = { math.floor(w), math.floor(l or -1), math.floor(t or -1) }
                    tutorialTarget[env] = target
                end
            end)
        end
        if target == nil then
            return false, uid == nil and "this camp has no tutorial door"
                or string.format("door uid %s is gone and was never read", tostring(uid))
        end
        local matched = target[1] == math.floor(dest[1])
            and target[2] == math.floor(dest[2] or -1)
            and target[3] == math.floor(dest[3] or -1)
        if not matched then
            why = string.format("tutorial door is %d-%d(%d), run started at %d-%d(%d)",
                target[1], target[2], target[3], math.floor(dest[1]),
                math.floor(dest[2] or -1), math.floor(dest[3] or -1))
            return false, why
        end
        world.HD_WORLDSTATE_STATE = world.HD_WORLDSTATE_STATUS.TUTORIAL
        return true
    end,
    --- Put the state back if anything cleared it between run_start and generation.
    --- hdmod sets HD_WORLDSTATE_STATE = NORMAL at camp setup and has its own reset
    --- handlers, and this is the last point before the world is built, so whatever
    --- ran in between loses. Idempotent, identical on every machine, and it reports
    --- what it found so a capture says whether the re-apply was needed at all.
    --- @return string?
    reassert = function(env)
        local world = rawget(env, "worldlib")
        if type(world) ~= "table" then
            return nil
        end
        local status = rawget(world, "HD_WORLDSTATE_STATUS")
        if type(status) ~= "table" or status.TUTORIAL == nil then
            return nil
        end
        local was = rawget(world, "HD_WORLDSTATE_STATE")
        world.HD_WORLDSTATE_STATE = status.TUTORIAL
        return string.format("worldstate %s -> %s%s", tostring(was),
            tostring(status.TUTORIAL),
            was == status.TUTORIAL and " (already set)" or " (IT HAD BEEN CLEARED)")
    end,
})

Determinism = module
return module
