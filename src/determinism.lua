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

-- ------------------------------------------------------ what a wrapper stands for

--- Each of our wrappers, mapped to the mod's own function inside it.
---
--- Every hosted callback we wrap (an anchor, the held-frame skip, the ON.LEVEL
--- order) reaches the engine as a closure defined in THIS file, and the crash trace
--- and the profile name a callback by where its function was defined. So they named
--- all of them `determinism.lua:<line>`. A real crash trace (room FVJF, 4-2) ended
--- `OUT mod determinism.lua:1042`: one of the hosted mod's update callbacks, with no
--- way to say which. Callbacks.hosted looks through this table instead.
---
--- Weak keys, so a wrapper the engine has let go of can still be collected.
--- @type table<function, function>
module.innerOf = setmetatable({}, { __mode = "k" })

--- Record what `wrapper` wraps: the innermost mod function, however many of our
--- layers are already around it.
--- @param wrapper function
--- @param cb any
--- @return function wrapper
local function wraps(wrapper, cb)
    if type(cb) == "function" then
        module.innerOf[wrapper] = module.innerOf[cb] or cb
    end
    return wrapper
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
---
--- The streams go back even when the body throws. A throwing callback used to skip
--- the restore and leave our seed in force for the rest of the floor, which is the
--- exact leak the restore exists to prevent. The error is raised again unchanged.
--- @param cb function
--- @param base fun(): integer
--- @return function
function module.anchor(cb, base)
    return wraps(function(...)
        local saved = module.savePrng()
        pcall(seedFromBase, base)
        local ok, ret = pcall(cb, ...)
        module.restorePrng(saved)
        if not ok then
            error(ret, 0)
        end
        return ret
    end, cb)
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

-- ------------------------------------------------------------- the water probe
--
-- MEASUREMENT ONLY: nothing here changes what any mod sees or does.
--
-- dev75 hid FX_WATER_SURFACE from a hosted mod's ON.LEVEL in a room, at the price
-- of 2.5's swamp lily pads and the HD mod's lily pads and frogs. dev76 added this
-- probe to find out WHAT differs between the machines' water when the mods look.
-- Its first capture (room FVJF, 2-1 to 4-2) answered: nothing. On every wet floor
-- the liquid and the surfaces were identical on both machines, to a hundredth of a
-- tile and in the same order, at generation, at ON.LEVEL and at the first frame.
-- The one difference was on 2-1, and it was not the water: the mod asked twice, and
-- the two machines' answers came the other way round, because its ON.LEVEL
-- callbacks ran in a different order (see "the order of ON.LEVEL" below).
--
-- So dev77 shows the surfaces again, and keeps the probe: it still fingerprints the
-- liquid and the surface effects at generation; as ON.LEVEL begins, twice a few ms
-- apart to see whether anything moves while Lua holds the main thread; as the mod's
-- own queries see them; and as the gate engages. inputSync sends the result with
-- the floor digest, and a non-host logs one verdict line per floor against the world
-- host's. Reads only: no PRNG draw, no spawn, no write to any entity.

local PROBE_SPIN_MS = 4
local PROBE_SPIN_CAP = 1000000 -- a timer that does not advance must not hang the load
local PROBE_LIST_MAX = 300
local PROBE_HASH_MOD = 2147483647

--- This floor's measurements: made at POST_LEVEL_GENERATION in a room, nil otherwise.
local probe = nil

--- What the probe looks for, read when it runs (the tests load us without an API).
--- @return integer?, integer, integer, integer # FX_WATER_SURFACE, MASK.LIQUID, MASK.FX, LAYER.BOTH
local function probeKinds()
    local fxType, liquidMask, fxMask, both = nil, 24576, 64, -128
    pcall(function() fxType = ENT_TYPE.FX_WATER_SURFACE end)
    pcall(function() liquidMask = math.floor(MASK.LIQUID) end)
    pcall(function() fxMask = math.floor(MASK.FX) end)
    pcall(function() both = LAYER.BOTH end)
    return fxType, liquidMask, fxMask, both
end

--- A position as one sortable integer: layer, then x, then y. `scale` 100 keeps
--- hundredths of a tile; 1 keeps whole tiles (the coarse key).
--- @return integer
local function positionKey(x, y, layer, scale)
    local qx = math.floor(x * scale + 0.5) + 0x100000
    local qy = math.floor(y * scale + 0.5) + 0x100000
    local l = (layer == 1) and 1 or 0
    return (l << 42) | ((qx & 0x1FFFFF) << 21) | (qy & 0x1FFFFF)
end

--- @param keys integer[]
--- @return integer
local function hashKeys(keys)
    local h = #keys % PROBE_HASH_MOD
    for i = 1, #keys do
        h = (h * 1000003 + keys[i] % PROBE_HASH_MOD) % PROBE_HASH_MOD
    end
    return h
end

--- The same, whatever order the keys came in.
--- @param keys integer[]
--- @return integer
local function hashSorted(keys)
    local copy = {}
    for i = 1, #keys do
        copy[i] = keys[i]
    end
    table.sort(copy)
    return hashKeys(copy)
end

--- Fine and coarse keys of these entities' positions, in the order given.
--- @param uids any
--- @return integer[] fine
--- @return integer[] coarse
local function positionKeys(uids)
    local fine, coarse = {}, {}
    local okLen, len = pcall(function() return #uids end)
    if not okLen or type(len) ~= "number" then
        return fine, coarse
    end
    for i = 1, len do
        local ok, x, y, l = pcall(get_position, uids[i])
        if ok and type(x) == "number" and type(y) == "number" then
            fine[#fine + 1] = positionKey(x, y, l, 100)
            coarse[#coarse + 1] = positionKey(x, y, l, 1)
        end
    end
    return fine, coarse
end

--- Fingerprint whatever the ENGINE's own query returns (never the sandbox's).
--- @return table # { n, ord, set, tiles, keys }
local function probeSample(types, mask)
    local fp = { n = 0, ord = 0, set = 0, tiles = 0, keys = {} }
    if types == nil then
        return fp
    end
    local _, _, _, both = probeKinds()
    local ok, uids = pcall(get_entities_by, types, mask, both)
    if not ok or uids == nil then
        return fp
    end
    local fine, coarse = positionKeys(uids)
    fp.n, fp.keys = #fine, fine
    fp.ord, fp.set, fp.tiles = hashKeys(fine), hashSorted(fine), hashSorted(coarse)
    return fp
end

--- The engine frame and the run's simulated frame, for "did anything tick between".
--- @return integer, integer
local function probeClock()
    local frame, sim = -1, -1
    pcall(function() frame = math.floor(get_frame()) end)
    pcall(function() sim = math.floor(get_local_state().time_total) end)
    return frame, sim
end

--- Hold the main thread a few ms: anything that changes meanwhile was changed by
--- another thread. os.clock first, get_ms if it is missing, and a bound on both,
--- because a timer that never advances inside one callback would otherwise hang
--- the load forever.
local function probeSpin()
    local timer, scale = nil, 1
    if os ~= nil and type(os.clock) == "function" then
        timer, scale = os.clock, 1000
    elseif type(get_ms) == "function" then
        timer = get_ms
    end
    if timer == nil then
        return
    end
    local ok, started = pcall(timer)
    if not ok or type(started) ~= "number" then
        return
    end
    for _ = 1, PROBE_SPIN_CAP do
        local okNow, now = pcall(timer)
        if not okNow or type(now) ~= "number" or (now - started) * scale >= PROBE_SPIN_MS then
            return
        end
    end
end

--- POST_LEVEL_GENERATION: a new floor. The liquid as generated, before any of the
--- mod's own post-generation hooks (2.5 adds its rushing water in one).
--- @param active fun(): boolean
local function probeGeneration(active)
    probe = nil
    if not active() then
        return
    end
    local fxType, liquidMask, fxMask = probeKinds()
    local frame, sim = probeClock()
    probe = {
        gen = probeSample(0, liquidMask),
        genFx = probeSample(fxType, fxMask).n,
        genFrame = frame, genSim = sim,
        mod = { queries = 0, seen = 0, ord = 0, set = 0, any = 0 },
    }
end

--- ON.LEVEL, ahead of every callback the mod registers: what it is about to see.
--- @param active fun(): boolean
local function probeLevel(active)
    if probe == nil or probe.level ~= nil or not active() then
        return
    end
    local fxType, liquidMask, fxMask = probeKinds()
    local frame, sim = probeClock()
    local liquid, fx = probeSample(0, liquidMask), probeSample(fxType, fxMask)
    local moving = false
    if liquid.n + fx.n > 0 then
        probeSpin()
        local liquid2, fx2 = probeSample(0, liquidMask), probeSample(fxType, fxMask)
        moving = liquid2.n ~= liquid.n or liquid2.set ~= liquid.set
            or fx2.n ~= fx.n or fx2.ord ~= fx.ord
    end
    probe.level = { liquid = liquid, fx = fx, moving = moving, frame = frame, sim = sim }
end

--- The surface effects one of the mod's ON.LEVEL queries was given, in the order
--- the engine gave them. Three running fingerprints: `ord` and `set` compare query
--- by query (the order the engine listed each answer in, and not), and `any` sums
--- the answers, so it matches whatever order the queries came in. On FVJF's 2-1 the
--- first two differed and the third would have matched: the same two answers, the
--- other way round, which is what callbacks running in another order look like.
--- @param uids integer[]
local function probeModView(uids)
    if probe == nil then
        return
    end
    local keys = positionKeys(uids)
    local mod = probe.mod
    local h = hashKeys(keys)
    mod.queries = mod.queries + 1
    mod.seen = mod.seen + #keys
    mod.ord = (mod.ord * 1000003 + h) % PROBE_HASH_MOD
    mod.set = (mod.set * 1000003 + hashSorted(keys)) % PROBE_HASH_MOD
    mod.any = (mod.any + h + 1) % PROBE_HASH_MOD
end

--- @param keys integer[]
--- @return string
local function probeList(keys)
    local parts = {}
    for i = 1, math.min(#keys, PROBE_LIST_MAX) do
        local key = keys[i]
        parts[#parts + 1] = string.format("%.2f,%.2f,%d",
            (((key >> 21) & 0x1FFFFF) - 0x100000) / 100,
            ((key & 0x1FFFFF) - 0x100000) / 100, key >> 42)
    end
    if #keys > PROBE_LIST_MAX then
        parts[#parts + 1] = string.format("(+%d more)", #keys - PROBE_LIST_MAX)
    end
    return table.concat(parts, " ")
end

-- ---------------------------------------------- the order hosted callbacks run in
--
-- Overlunky keeps a script's callbacks in a std::unordered_map keyed by callback id
-- (lua_backend.hpp) and fires an event's callbacks in the order that map iterates.
-- Microsoft's unordered_map is a list with a bucket index over it: a new callback goes
-- at the END of the list when its bucket is empty, and next to the one already in its
-- bucket when not, and a rehash moves callbacks up to join their bucket. So the order
-- is the order of registration, except where two ids happened to share a bucket --
-- and which ids do depends on the ids, which come from one counter per script:
-- hosted, the mod's and ours. Two machines never reach a floor having registered
-- exactly the same things (one sat in the camp twice, one joined fresh, and the mod
-- re-registers its hooks every floor), so the same mod's callbacks run in a slightly
-- different order on each.
--
-- The FVJF capture shows it. On 2-1, 2.5 asked twice for water surfaces at ON.LEVEL.
-- The surfaces were identical on both machines and so were the answers, the other
-- way round: the host's first query got all 117 and its second none, the peer's
-- first got none and its second all 117. Two of the mod's callbacks had swapped. A
-- player folded back into a run under way has a history shorter by the whole run,
-- so there every hook 2.5 registers gets a different id from the host's: every
-- event, every frame.
--
-- So in a room the hosted mods' callbacks for every event in ORDER_KIND run in the
-- order they were registered, on every machine: whichever of them the engine reaches
-- first runs them all, in that order, and the rest hand the engine what they
-- returned when it reaches them. Ours that must come before the mod's (heads: our
-- state sync before a level loads, the mod's random generator reseeded) run first,
-- and ours that must come after (tails) run last. Alone, every callback runs at the
-- engine's own turn, as it always did; and with no hosted callback for an event,
-- ours run at their own turn too, so nothing changes without a hosted mod.
--
-- What the engine does with a callback's answer is kept, event by event:
--   * "stop" (PRE_LOAD_SCREEN, PRE_LEVEL_CREATION, PRE_LEVEL_DESTRUCTION): the
--     engine stops at the first callback that returns true. The batch stops at the
--     first that does in ITS order; the ones after it do not run, and its true
--     reaches the engine at its own turn, which stops the engine there;
--   * "any" (PRE_LEVEL_GENERATION, PRE_UPDATE): every callback runs, and a true
--     from any of them blocks; each hands back its own answer;
--   * "all": every callback runs, and their answers are not used.
-- Only a real boolean true counts, as in the engine, which converts strictly
-- (handle_function: anything else is an "Unexpected return type").
--
-- Where the engine's own behaviour depends on the map, the batch picks one answer
-- and gives it on every machine:
--   * a callback cleared during the pass, by one that ran before it, does not run;
--   * a callback registered during the pass runs in it, after all the others: where
--     the engine nearly always puts it, at the end of the list;
--   * a bare clear_callback() made by a callback itself clears that callback, not
--     the one the engine happens to be running the pass from. One made inside an
--     engine callback nested in it (an entity hook a spawn set off) is left alone,
--     and the engine clears the callback it is running, as it always did;
--   * an error in one callback does not stop the rest. It is raised when the engine
--     reaches the callback that threw, so Playlunky still reports it.
--
-- A pass is one firing of one event. A new one starts when the engine frame has
-- moved on, when an event that always comes between two firings has fired (the
-- update's end between two PRE_UPDATEs, the next update between two loads), or when
-- a callback that already had its turn is reached again after every callback of the
-- pass has had one (or the one that stopped it has): an event firing twice in one
-- frame is two passes. A callback registered during a pass and reached after the
-- others is still in that pass, and is not run twice.

local LEVEL_NAMES_MAX = 64 -- names in a floor block's `level order` line
-- Places named in a floor report's census of them (`og`), most callbacks first, and
-- how much of each place's name goes on the wire.
local LEVEL_CENSUS_MAX = 10
local LEVEL_CENSUS_NAME = 40
--- The most callbacks one pass runs. One that registers another every time it runs
--- would keep a pass going for ever, here as in the engine.
local ORDER_PASS_MAX = 4096

--- The events ordered in a room, and what the engine does with their answers.
local ORDER_KINDS = {
    PRE_LOAD_SCREEN = "stop", POST_LOAD_SCREEN = "all",
    PRE_LOAD_LEVEL_FILES = "all",
    PRE_LEVEL_GENERATION = "any", POST_ROOM_GENERATION = "all",
    POST_LEVEL_GENERATION = "all",
    PRE_LEVEL_CREATION = "stop", POST_LEVEL_CREATION = "all",
    PRE_LEVEL_DESTRUCTION = "stop", POST_LEVEL_DESTRUCTION = "all",
    PRE_UPDATE = "any", POST_UPDATE = "all",
    GAMEFRAME = "all", LEVEL = "all", LOADING = "all", SCREEN = "all",
    TRANSITION = "all", CAMP = "all", START = "all", RESET = "all",
    DEATH = "all", WIN = "all",
}
--- Events that always fire between two firings of the one on the left, in the
--- engine's update (StateUpdate: PRE_UPDATE, the update with any level load inside
--- it, POST_UPDATE or BLOCKED_UPDATE, then every script's update -- LEVEL, GAMEFRAME,
--- the screens). One of them firing ends the pass of the event on the left.
local ORDER_CLOSERS = {
    PRE_UPDATE = { "POST_UPDATE", "BLOCKED_UPDATE" },
    POST_UPDATE = { "PRE_UPDATE" },
    PRE_LOAD_SCREEN = { "POST_LOAD_SCREEN", "PRE_UPDATE" },
    POST_LOAD_SCREEN = { "PRE_LOAD_SCREEN", "PRE_UPDATE" },
    PRE_LOAD_LEVEL_FILES = { "POST_LOAD_SCREEN", "PRE_UPDATE" },
    PRE_LEVEL_GENERATION = { "POST_LEVEL_GENERATION", "PRE_UPDATE" },
    POST_ROOM_GENERATION = { "POST_LEVEL_GENERATION", "PRE_UPDATE" },
    POST_LEVEL_GENERATION = { "PRE_LEVEL_GENERATION", "PRE_UPDATE" },
    PRE_LEVEL_CREATION = { "POST_LEVEL_CREATION", "PRE_UPDATE" },
    POST_LEVEL_CREATION = { "PRE_LEVEL_CREATION", "PRE_UPDATE" },
    PRE_LEVEL_DESTRUCTION = { "POST_LEVEL_DESTRUCTION", "PRE_UPDATE" },
    POST_LEVEL_DESTRUCTION = { "PRE_LEVEL_DESTRUCTION", "PRE_UPDATE" },
    GAMEFRAME = { "PRE_UPDATE" }, LEVEL = { "PRE_UPDATE" }, LOADING = { "PRE_UPDATE" },
    SCREEN = { "PRE_UPDATE" }, TRANSITION = { "PRE_UPDATE" }, CAMP = { "PRE_UPDATE" },
    START = { "PRE_UPDATE" }, RESET = { "PRE_UPDATE" }, DEATH = { "PRE_UPDATE" },
    WIN = { "PRE_UPDATE" },
}

--- event value -> its kind, and its name for the trace and the log
local ORDER_KIND, ORDER_NAME = {}, {}
do
    local on = rawget(_G, "ON")
    if type(on) == "table" then
        for name, kind in rawPairs(ORDER_KINDS) do
            local value = rawget(on, name)
            if type(value) == "number" and ORDER_KIND[value] == nil then
                ORDER_KIND[value], ORDER_NAME[value] = kind, name
            end
        end
    end
end

local order = {}         -- event -> the state of its passes (see orderOf)
local closerFor = {}     -- event -> the passes its firing ends (see ORDER_CLOSERS)
local orderSeq = 0       -- registrations so far, across every event: the order itself
local orderById = {}     -- engine callback id -> the hosted entry it was registered for
local orderRunning = nil -- the entry being run right now

--- What the batch ran on this floor, for the probe: how many, a running hash of
--- where each one was defined, in order, the names in that order (as runs of one
--- place: room PTHP's 32 hooks from one line of 2.5 read as one name 32 times), how
--- many there were from each place, and how many ran past the names kept.
local levelRan = { n = 0, hash = 0, runs = {}, byWhere = {}, more = 0 }

--- Where a function was defined, as `file.lua:line`: the form Callbacks uses to name
--- a hosted callback in the crash trace and the profile.
--- @param fn any
--- @return string
local function whereDefined(fn)
    local dbg = rawget(_G, "debug")
    if type(dbg) ~= "table" or type(dbg.getinfo) ~= "function" then
        return "?"
    end
    local ok, info = pcall(dbg.getinfo, fn, "S")
    if not ok or type(info) ~= "table" then
        return "?"
    end
    local src = tostring(info.short_src or info.source or "?")
    local leaf = src:match("([^/\\]+)$")
    return (leaf or src) .. ":" .. tostring(info.linedefined or "?")
end

--- @param text string
--- @return integer
local function textHash(text)
    local h = #text
    for i = 1, #text do
        h = (h * 31 + text:byte(i)) % PROBE_HASH_MOD
    end
    return h
end

--- A new ON.LEVEL pass, with nothing run in it yet.
local function resetLevelRan()
    levelRan.n, levelRan.hash, levelRan.more = 0, 0, 0
    levelRan.runs, levelRan.byWhere = {}, {}
end

--- One more callback the batch ran, into the floor's record.
--- @param where string
local function noteLevelRan(where)
    levelRan.n = levelRan.n + 1
    levelRan.hash = (levelRan.hash * 1000003 + textHash(where)) % PROBE_HASH_MOD
    levelRan.byWhere[where] = (levelRan.byWhere[where] or 0) + 1
    local runs = levelRan.runs
    local last = runs[#runs]
    if levelRan.more > 0 then
        levelRan.more = levelRan.more + 1 -- past the names kept: none after it is shown
    elseif last ~= nil and last.where == where then
        last.n = last.n + 1
    elseif #runs < LEVEL_NAMES_MAX then
        runs[#runs + 1] = { where = where, n = 1 }
    else
        levelRan.more = 1
    end
end

--- How many of this pass's callbacks came from each place, most first, as the flat
--- list a floor report carries: { "entityContext.lua:1381", 32, "helpers2.lua:430",
--- 32 }. A list, not a map, so the wire keeps its order. Past LEVEL_CENSUS_MAX places
--- the rest are one last pair, "" and how many callbacks they had between them.
--- @return table
local function levelCensus()
    local rows = {}
    for where, n in rawPairs(levelRan.byWhere) do
        rows[#rows + 1] = { where = where, n = n }
    end
    table.sort(rows, function(a, b)
        if a.n ~= b.n then
            return a.n > b.n
        end
        return a.where < b.where
    end)
    local out, rest = {}, 0
    for i = 1, #rows do
        if i <= LEVEL_CENSUS_MAX then
            out[#out + 1] = rows[i].where:sub(1, LEVEL_CENSUS_NAME)
            out[#out + 1] = rows[i].n
        else
            rest = rest + rows[i].n
        end
    end
    if rest > 0 then
        out[#out + 1] = ""
        out[#out + 1] = rest
    end
    return out
end

--- The engine frame, which moves on between two firings of an event in all but the
--- rare case of one firing twice in a frame (see "A pass is one firing" above).
--- @return integer
local function enginePassFrame()
    local getFrame = rawget(_G, "get_frame") -- the engine's: the mod's is our clock
    if type(getFrame) == "function" then
        local ok, f = pcall(getFrame)
        if ok and type(f) == "number" then
            return math.floor(f)
        end
    end
    return -1
end

--- Can the batch tell a callback's own bare clear from one made inside an engine
--- callback nested in it? It needs `debug.getinfo` to look. Without it there is no
--- batch, and every callback runs at the engine's turn.
--- @return boolean
local function canBatch()
    local dbg = rawget(_G, "debug")
    return type(dbg) == "table" and type(dbg.getinfo) == "function"
end

--- Have the events that end a pass of `ord`'s event end it. One callback of ours per
--- such event, registered the first time an ordered event needs it.
--- @param ord table
local function ensureClosers(ord)
    local names = ORDER_CLOSERS[ord.name]
    local on = rawget(_G, "ON")
    if names == nil or type(on) ~= "table" then
        return
    end
    for _, name in ipairs(names) do
        local value = rawget(on, name)
        if type(value) == "number" then
            local list = closerFor[value]
            if list == nil then
                list = {}
                closerFor[value] = list
                set_callback(function()
                    for i = 1, #list do
                        list[i].closed = true
                    end
                end, value)
            end
            list[#list + 1] = ord
        end
    end
end

--- The state of one event's passes, made on first use.
--- @param event integer
--- @return table
local function orderOf(event)
    local ord = order[event]
    if ord == nil then
        ord = {
            event = event, kind = ORDER_KIND[event], name = ORDER_NAME[event] or tostring(event),
            entries = {},      -- every live entry for the event, in registration order
            mods = 0,          -- how many of them are a hosted mod's
            active = nil,      -- whether the hosted mods are in a room
            pass = 0,          -- passes begun
            frame = nil,       -- the engine frame the current pass began on
            complete = true,   -- every entry the current pass expected has had its turn
            closed = false,    -- an event that ends this event's passes fired since
            expect = 0,        -- entries the current pass expects the engine to reach
            seen = 0,          -- of those, how many it has
            stopper = nil,     -- the entry whose true stops the engine this pass
            batching = false,
            dirty = false,     -- entries cleared but still in `entries`
        }
        if ord.name == "LEVEL" then
            -- the floor's census of what ran, for the probe (waterReport)
            ord.onBatch = resetLevelRan
            ord.onRan = function(entry)
                noteLevelRan(entry.where)
            end
        end
        order[event] = ord
        ensureClosers(ord)
    end
    return ord
end

--- Batch this event now? Only in a room, and only with one of the mod's callbacks for
--- it: ours alone are left to the engine, exactly as they always were.
--- @param ord table
--- @return boolean
local function batchMode(ord)
    if ord.mods <= 0 or ord.active == nil or not canBatch() then
        return false
    end
    local ok, active = pcall(ord.active)
    return ok and active == true
end

--- Drop cleared entries. Never during a batch, which is walking the list.
--- @param ord table
local function compactOrder(ord)
    if not ord.dirty or ord.batching then
        return
    end
    local kept = {}
    for i = 1, #ord.entries do
        local e = ord.entries[i]
        if not e.cleared then
            kept[#kept + 1] = e
        end
    end
    ord.entries = kept
    ord.dirty = false
end

--- Has every entry this pass expected had its turn? Then the next call the engine
--- makes for this event is a new pass. Never decided inside the batch: the engine
--- has reached nothing of the pass yet but the callback that started it.
--- @param ord table
local function checkComplete(ord)
    if not ord.batching and ord.expect > 0 and ord.seen >= ord.expect then
        ord.complete = true
    end
end

--- A hosted entry its mod cleared.
--- @param entry table
local function forgetOrdered(entry)
    if entry.cleared then
        return
    end
    entry.cleared = true
    local ord = entry.ord
    if entry.engineId ~= nil and orderById[entry.engineId] == entry then
        orderById[entry.engineId] = nil
    end
    if entry.mod then
        ord.mods = ord.mods - 1
    end
    -- one the pass was still waiting for: the engine will not reach it now
    if entry.expected == ord.pass and entry.seenPass ~= ord.pass then
        entry.expected = nil
        ord.expect = ord.expect - 1
        checkComplete(ord)
    end
    ord.dirty = true
    compactOrder(ord)
end

--- The bottom of one entry's run, as a frame of its own. Never a tail call: the
--- wrappers inside it tail-call each other away, and this frame is what a bare
--- clear_callback() looks for on the stack (clearIsEntrysOwn).
--- @param entry table
--- @return any # the entry's first return value
local function orderBoundary(entry, ...)
    local ret = entry.run(...)
    return ret
end

--- Was this bare clear_callback() made by the running entry itself, rather than by
--- an engine callback nested inside it? Walks up from the caller until it reaches
--- the entry's boundary (yes) or a C function that is not a pcall (no: that is the
--- engine calling back into Lua, from a spawn, a kill or anything else that sets off
--- a hook).
--- @param entry table
--- @return boolean
local function clearIsEntrysOwn(entry)
    local dbg = rawget(_G, "debug")
    if type(dbg) ~= "table" or type(dbg.getinfo) ~= "function" then
        return false
    end
    -- Inside a coroutine the walk cannot reach the entry, and an engine callback is
    -- never what is running there: the engine calls back on the main thread.
    local co = rawget(_G, "coroutine")
    if type(co) == "table" and type(co.running) == "function" then
        local _, isMain = co.running()
        if isMain == false then
            return true
        end
    end
    local getinfo = dbg.getinfo
    -- 1 is this function, 2 the sandbox's clear_callback, 3 whoever called it
    for depth = 3, 200 do
        local info = getinfo(depth, "fS")
        if type(info) ~= "table" then
            return false
        end
        if info.func == orderBoundary then
            return true
        end
        if info.what == "C" and info.func ~= pcall and info.func ~= xpcall then
            return false
        end
    end
    return false
end

--- The traceback of the error being raised, kept for the log. The value itself goes
--- back unchanged, so the mod's error reads exactly as it would have.
local orderErrTrace = nil

--- @param v any
--- @return string
local function safeText(v)
    local ok, text = pcall(tostring, v)
    return ok and text or "?"
end

--- @param err any
--- @return any err
local function orderErrHandler(err)
    orderErrTrace = nil
    local dbg = rawget(_G, "debug")
    if type(dbg) == "table" and type(dbg.traceback) == "function" then
        local ok, tb = pcall(dbg.traceback, safeText(err), 2)
        if ok and type(tb) == "string" then
            orderErrTrace = tb
        end
    end
    return err
end

--- Put a hosted callback's error in the desync log, under its own name.
--- @param entry table
--- @param err any
--- @param trace string?
local function noteOrderedError(entry, err, trace)
    local where = entry.where .. " (ON." .. entry.ord.name .. ")"
    local callbacks = rawget(_G, "Callbacks")
    if callbacks ~= nil and type(callbacks.noteHostedError) == "function" then
        pcall(callbacks.noteHostedError, where, err, trace)
        return
    end
    local log = rawget(_G, "DesyncLog")
    if log ~= nil and type(log.earlyEvent) == "function" then
        pcall(log.earlyEvent, "*** HOSTED MOD ERROR in %s: %s", where, trace or safeText(err))
    end
end

--- What a hosted entry is called in the crash trace and the profile: what Callbacks
--- calls any hosted callback (the mod's own function, and the name the mod's wrapper
--- gives it), worked out once, the first time it is wanted.
--- @param entry table
--- @return string
local function entryLabel(entry)
    if entry.label == nil then
        local name = entry.where
        local callbacks = rawget(_G, "Callbacks")
        if callbacks ~= nil and type(callbacks.hostedName) == "function" and entry.own ~= nil then
            local ok, rich = pcall(callbacks.hostedName, entry.own)
            if ok and type(rich) == "string" then
                name = rich
            end
        end
        entry.label = name
    end
    return entry.label
end

--- ...and its line in the crash trace while it runs: the event after it, as
--- Callbacks.hosted marks every hosted callback.
--- @param entry table
--- @return string
local function entryMark(entry)
    if entry.mark == nil then
        entry.mark = "mod " .. entryLabel(entry) .. " " .. entry.ord.name
    end
    return entry.mark
end

--- Run one entry. A hosted one runs as Callbacks.hosted would run it, whichever
--- callback the engine started the pass from: our depth zero, its time on its own
--- name in the profile, and named in the crash trace while it runs.
--- @param entry table
--- @return boolean ok, any result # its first return value, or what it threw
--- @return string? trace
local function runOrderedEntry(entry, ...)
    local outer = orderRunning
    orderRunning = entry
    local log, mark = nil, nil
    local callbacks = nil
    if entry.mod then
        log = rawget(_G, "DesyncLog")
        if log ~= nil and type(log.tracing) == "function" and type(log.frameMark) == "function" then
            local okT, on = pcall(log.tracing)
            if okT and on == true then
                mark = entryMark(entry)
                pcall(log.frameMark, mark)
            end
        end
        callbacks = rawget(_G, "Callbacks")
        if callbacks ~= nil and type(callbacks.asHosted) ~= "function" then
            callbacks = nil
        end
    end
    orderErrTrace = nil
    local startedAt = callbacks ~= nil and type(callbacks.batchClock) == "function"
        and callbacks.batchClock() or nil
    local ok, err
    if callbacks ~= nil then
        ok, err = callbacks.asHosted(xpcall, orderBoundary, orderErrHandler, entry, ...)
    else
        ok, err = xpcall(orderBoundary, orderErrHandler, entry, ...)
    end
    local trace = orderErrTrace
    if startedAt ~= nil and type(callbacks.chargeBatched) == "function" then
        pcall(callbacks.chargeBatched, entryLabel(entry), startedAt)
    end
    if mark ~= nil and type(log.frameDone) == "function" then
        pcall(log.frameDone, mark)
    end
    orderRunning = outer
    return ok, err, trace
end

--- A new pass of `ord`'s event: every live entry is one the engine should reach.
--- @param ord table
--- @param now integer
local function beginPass(ord, now)
    compactOrder(ord)
    ord.pass = ord.pass + 1
    ord.frame = now
    ord.complete = false
    ord.closed = false
    ord.stopper = nil
    local expect = 0
    for i = 1, #ord.entries do
        local e = ord.entries[i]
        if not e.cleared then
            e.expected = ord.pass
            expect = expect + 1
        end
    end
    ord.expect, ord.seen = expect, 0
end

--- The whole pass, in order: our heads, the mod's callbacks, our tails, each in the
--- order registered, including any registered while the pass runs.
--- @param ord table
local function runPass(ord, ...)
    local pass = ord.pass
    local stopKind = ord.kind == "stop"
    local stopped = false
    if ord.onBatch ~= nil then
        pcall(ord.onBatch)
    end
    ord.batching = true
    for phase = 1, 3 do
        local list = ord.entries
        local i, ran = 1, 0
        while i <= #list and ran < ORDER_PASS_MAX do
            local e = list[i]
            if e.phase == phase and not e.cleared and not (stopped and phase < 3) then
                ran = ran + 1
                local ok, ret, trace = runOrderedEntry(e, ...)
                e.donePass = pass
                if ok then
                    e.ret, e.err = ret, nil
                    if stopKind and phase < 3 and ret == true then
                        stopped = true
                        ord.stopper = e
                    end
                else
                    e.ret, e.err = nil, ret
                    if e.mod then
                        noteOrderedError(e, ret, trace)
                    end
                end
                if e.mod and ord.onRan ~= nil then
                    pcall(ord.onRan, e)
                end
            end
            i = i + 1
        end
    end
    ord.batching = false
    compactOrder(ord)
end

--- An entry's own turn in the pass: count it, and hand the engine what it returned
--- in the batch -- or raise what it threw, once.
--- @param ord table
--- @param entry table
local function turnOf(ord, entry)
    local pass = ord.pass
    entry.turnPass = pass
    if entry.expected == pass and entry.seenPass ~= pass then
        entry.seenPass = pass
        ord.seen = ord.seen + 1
        checkComplete(ord)
    end
    if ord.stopper == entry then
        ord.complete = true -- the engine stops here: the pass is over
    end
    if entry.donePass ~= pass then
        return -- it did not run in this pass: registered after it, or stopped before it
    end
    entry.donePass = nil
    local err = entry.err
    if err ~= nil then
        entry.ret, entry.err = nil, nil
        error(err, 0)
    end
    local ret = entry.ret
    entry.ret = nil
    if ret == nil then
        return -- nothing, not nil: what the engine got when it ran alone
    end
    return ret
end

--- What the engine calls for every ordered callback, ours and the mod's.
--- @param entry table
local function orderedDispatch(entry, ...)
    if entry.cleared then
        return
    end
    local ord = entry.ord
    if not batchMode(ord) then
        -- alone, or no hosted callback for this event: this one, at the engine's own
        -- turn, exactly as it always ran
        if not entry.mod then
            return entry.run(...)
        end
        local ok, ret, trace = runOrderedEntry(entry, ...)
        if not ok then
            noteOrderedError(entry, ret, trace)
            error(ret, 0)
        end
        if ret == nil then
            return
        end
        return ret
    end
    if not ord.batching then
        local now = enginePassFrame()
        if ord.frame ~= now or ord.closed or (ord.complete and entry.turnPass == ord.pass) then
            -- the first of this pass the engine reached: run them all, in order
            beginPass(ord, now)
            runPass(ord, ...)
        end
    end
    return turnOf(ord, entry)
end

--- One of OURS for an ordered event, as a head (phase 1) or a tail (phase 3).
--- @param event any
--- @param name string
--- @param fn any
--- @param phase integer
--- @return any # the engine's callback id
local function ownOrdered(event, name, fn, phase)
    if event == nil then
        -- an event this build of the API does not have: set_callback(fn, nil) would
        -- abort the whole chunk (see main.lua), and there is nothing to run it for
        return nil
    end
    if ORDER_KIND[event] == nil or type(fn) ~= "function" then
        return set_callback(fn, event) -- not an ordered event: as it always was
    end
    local ord = orderOf(event)
    orderSeq = orderSeq + 1
    local entry = {
        ord = ord, seq = orderSeq, phase = phase, run = fn, where = name, mod = false,
        cleared = false,
    }
    -- listed before the engine has it: a pass it starts must find it there
    ord.entries[#ord.entries + 1] = entry
    entry.engineId = set_callback(function(...)
        return orderedDispatch(entry, ...)
    end, event)
    return entry.engineId
end

--- Register one of ours that must run before every hosted callback of `event` in a
--- room (see "the order hosted callbacks run in"). Alone, or with no hosted callback
--- for the event, it is an ordinary callback at the engine's own turn.
--- @param event any # an ON value
--- @param name string # for the log
--- @param fn function
--- @return any # the engine's callback id
function module.head(event, name, fn)
    return ownOrdered(event, name, fn, 1)
end

--- ...and one that must run after them all.
--- @param event any
--- @param name string
--- @param fn function
--- @return any
function module.tail(event, name, fn)
    return ownOrdered(event, name, fn, 3)
end

--- Is this event one whose hosted callbacks are ordered in a room?
--- @param event any
--- @return boolean
function module.isOrdered(event)
    return ORDER_KIND[event] ~= nil
end

--- Called by inputSync as the gate engages a floor: one more look, then the whole
--- floor's measurements. nil outside a room.
--- @return { wire: table, lines: string[]? }?
function module.waterReport()
    if probe == nil then
        return nil
    end
    local fxType, liquidMask, fxMask = probeKinds()
    local frame, sim = probeClock()
    local liquid, fx = probeSample(0, liquidMask), probeSample(fxType, fxMask)
    local lvl = probe.level or {
        liquid = probeSample(nil), fx = probeSample(nil), moving = false, frame = -1, sim = -1,
    }
    local gen, mod = probe.gen, probe.mod
    local wire = {
        gn = gen.n, gh = gen.set,
        ln = lvl.liquid.n, lh = lvl.liquid.set,
        fn = lvl.fx.n, fo = lvl.fx.ord, fs = lvl.fx.set, ft = lvl.fx.tiles,
        mv = lvl.moving and 1 or 0,
        mq = mod.queries, mn = mod.seen, mo = mod.ord, ms = mod.set, mx = mod.any,
        en = liquid.n, eh = liquid.set, ef = fx.n, es = fx.set,
        oc = levelRan.n, oh = levelRan.hash,
        og = levelRan.n > 0 and levelCensus() or nil,
    }
    local lines = {}
    if gen.n + lvl.liquid.n + lvl.fx.n + liquid.n + fx.n > 0 then
        lines[#lines + 1] = string.format("water: generated liquid %d #%08X, surfaces %d"
            .. " | at ON.LEVEL (%+d frames, %+d sim) liquid %d #%08X, surfaces %d ord #%08X"
            .. " set #%08X tiles #%08X, moving %s | the mod asked %d time(s): %d seen ord"
            .. " #%08X set #%08X any #%08X | at engage (%+d frames, %+d sim) liquid %d #%08X,"
            .. " surfaces %d set #%08X",
            gen.n, gen.set, probe.genFx,
            lvl.frame - probe.genFrame, lvl.sim - probe.genSim,
            lvl.liquid.n, lvl.liquid.set, lvl.fx.n, lvl.fx.ord, lvl.fx.set, lvl.fx.tiles,
            lvl.moving and "YES" or "no",
            mod.queries, mod.seen, mod.ord, mod.set, mod.any,
            frame - probe.genFrame, sim - probe.genSim,
            liquid.n, liquid.set, fx.n, fx.set)
        lines[#lines + 1] = "water surfaces at ON.LEVEL, as the engine listed them (x,y,layer): "
            .. probeList(lvl.fx.keys)
    end
    if levelRan.n > 0 then
        local names = {}
        for i, run in ipairs(levelRan.runs) do
            names[i] = run.n > 1 and string.format("%s x%d", run.where, run.n) or run.where
        end
        lines[#lines + 1] = string.format("level order: %d hosted ON.LEVEL callback(s) #%08X: %s%s",
            levelRan.n, levelRan.hash, table.concat(names, " "),
            levelRan.more > 0 and string.format(" (+%d more)", levelRan.more) or "")
    end
    return { wire = wire, lines = #lines > 0 and lines or nil }
end

--- @param t table
--- @param k string
--- @return integer # -1 when absent
local function probeField(t, k)
    return math.floor(tonumber(t[k]) or -1)
end

--- A non-host's verdict for one floor, from its own report and the world host's.
--- nil on a floor with no water on either machine.
--- @param mine table
--- @param host table
--- @param s integer
--- @return string?
function module.waterVerdict(mine, host, s)
    local function probeWet(t)
        return probeField(t, "gn") > 0 or probeField(t, "ln") > 0 or probeField(t, "fn") > 0
            or probeField(t, "en") > 0 or probeField(t, "ef") > 0
    end
    if not probeWet(mine) and not probeWet(host) then
        return nil
    end
    local function probeSame(...)
        for _, k in ipairs({ ... }) do
            if probeField(mine, k) ~= probeField(host, k) then
                return false
            end
        end
        return true
    end
    local function probeWord(b)
        return b and "MATCH" or "DIFFER"
    end
    local asked = probeField(mine, "mq") > 0 or probeField(host, "mq") > 0
    local fxOrd, fxSet = probeSame("fn", "fo"), probeSame("fn", "fs")
    local modOrd, modSet = probeSame("mq", "mn", "mo"), probeSame("mq", "mn", "ms")
    local modAny = probeSame("mq", "mn", "mx")
    local engage = probeSame("en", "eh", "ef", "es")
    local verdict
    if (asked and modOrd) or (not asked and fxOrd) then
        verdict = "MATCH: the mod saw the same surfaces on both machines"
    elseif (asked and modSet) or (not asked and fxSet) then
        verdict = "ORDER: the same surfaces, listed in a different order"
    elseif asked and modAny then
        verdict = "QUERY ORDER: the same answers, but the mod's queries came in a different"
            .. " order -- its ON.LEVEL callbacks ran in a different order"
    elseif asked and fxOrd then
        verdict = "QUERIES: the water was the same, and the mod asked for different things"
    elseif engage then
        verdict = "SETTLING: different when the mod looked, the same by the first frame"
    else
        verdict = "DIFFERENT: the water was still different at the first frame"
    end
    local fxHow = fxOrd and "same order" or (fxSet and "other order"
        or (probeSame("fn", "ft") and "same tiles, moved within them" or "different"))
    local seen = "n/a"
    if asked then
        seen = modOrd and "MATCH" or (modSet and "same set, other order"
            or (modAny and "same answers, other query order" or "DIFFER"))
    end
    local order = "n/a"
    if probeField(mine, "oc") >= 0 and probeField(host, "oc") >= 0 then
        order = probeWord(probeSame("oc", "oh"))
    end
    return string.format("WATER PROBE seq=%d: %s%s | generated liquid %s | at ON.LEVEL:"
        .. " liquid %s, surfaces %s (%d here, %d on the host: %s) | what the mod saw: %s"
        .. " | at engage: %s | moving during ON.LEVEL: here %s, host %s | ON.LEVEL order: %s",
        s, verdict, asked and "" or " (the mod did not ask on this floor)",
        probeWord(probeSame("gn", "gh")), probeWord(probeSame("ln", "lh")), probeWord(fxOrd),
        probeField(mine, "fn"), probeField(host, "fn"), fxHow, seen,
        probeWord(engage), probeField(mine, "mv") == 1 and "YES" or "no",
        probeField(host, "mv") == 1 and "YES" or "no", order)
end

--- The places whose callback counts differ between two floor reports' censuses
--- (`og`, see levelCensus), the biggest difference first, and whether either census
--- left places out. nil when either report has no census: an older build's.
--- @param mine any
--- @param host any
--- @return { w: string, m: integer, h: integer }[]? diff
--- @return boolean cut
local function levelCensusDiff(mine, host)
    if type(mine) ~= "table" or type(host) ~= "table" then
        return nil, false
    end
    local function counts(list)
        local out, cut = {}, false
        for i = 1, #list - 1, 2 do
            local where, n = list[i], tonumber(list[i + 1])
            if where == "" then
                cut = true -- the places this census left out
            elseif type(where) == "string" and n ~= nil then
                out[where] = (out[where] or 0) + math.floor(n)
            end
        end
        return out, cut
    end
    local a, cutA = counts(mine)
    local b, cutB = counts(host)
    local diff = {}
    -- a place missing from a census that left places out may be one of those: its
    -- count there is not known, so it is not called a difference
    for where, n in rawPairs(a) do
        if b[where] ~= nil or not cutB then
            if (b[where] or 0) ~= n then
                diff[#diff + 1] = { w = where, m = n, h = b[where] or 0 }
            end
        end
    end
    for where, n in rawPairs(b) do
        if a[where] == nil and not cutA then
            diff[#diff + 1] = { w = where, m = 0, h = n }
        end
    end
    table.sort(diff, function(x, y)
        local dx, dy = math.abs(x.m - x.h), math.abs(y.m - y.h)
        if dx ~= dy then
            return dx > dy
        end
        return x.w < y.w
    end)
    while #diff > 4 do
        table.remove(diff)
    end
    return diff, cutA or cutB
end

--- Two floor reports' hosted ON.LEVEL callbacks, compared: nil when either side
--- has no record of them, else whether they are the same, how many ran on each
--- side, and which places had a different number (`diff`: nil without a census on
--- both sides; `cut` when a census left places out, so `diff` may not be all).
--- @param mine table
--- @param host table
--- @return { same: boolean, here: integer, host: integer, diff: table?, cut: boolean }?
function module.levelOrderJudged(mine, host)
    local mineCount, hostCount = probeField(mine, "oc"), probeField(host, "oc")
    if mineCount < 0 or hostCount < 0 then
        return nil
    end
    if mineCount == hostCount and probeField(mine, "oh") == probeField(host, "oh") then
        return { same = true, here = mineCount, host = hostCount, diff = {}, cut = false }
    end
    local diff, cut = levelCensusDiff(mine.og, host.og)
    return { same = false, here = mineCount, host = hostCount, diff = diff, cut = cut }
end

--- A census difference in words, "entityContext.lua:1381: 6 here, 32 on the host".
--- Also reads one that came over the wire, so nothing in it is trusted to be a number.
--- @param diff table?
--- @param mineWord string  # "here", "on slot 2"
--- @param hostWord string  # "on the host", "here"
--- @return string
function module.levelDiffText(diff, mineWord, hostWord)
    local parts = {}
    for _, d in ipairs(type(diff) == "table" and diff or {}) do
        if type(d) == "table" then
            parts[#parts + 1] = string.format("%s: %d %s, %d %s", tostring(d.w),
                math.floor(tonumber(d.m) or 0), mineWord, math.floor(tonumber(d.h) or 0), hostWord)
        end
    end
    return table.concat(parts, "; ")
end

--- A non-host's line for a floor whose hosted ON.LEVEL callbacks ran in a different
--- order from the world host's. nil when they match, or when either side has no
--- record of it.
---
--- dev77 runs them in the order they were registered, so this can only differ if
--- the mods REGISTERED them in a different order on the two machines -- something
--- the batch cannot fix. The line names the places that registered a different
--- number of them (dev84); the two logs' `level order` lines show the whole order.
--- @param mine table
--- @param host table
--- @param s integer
--- @return string?
function module.levelOrderVerdict(mine, host, s)
    local judged = module.levelOrderJudged(mine, host)
    if judged == nil or judged.same then
        return nil
    end
    local which = ", not in the same order"
    if judged.diff ~= nil and #judged.diff > 0 then
        which = " (" .. module.levelDiffText(judged.diff, "here", "on the host") .. ")"
    elseif judged.diff ~= nil and not judged.cut and judged.here == judged.host then
        which = ": the same callbacks, registered in a different order"
    end
    return string.format("ON.LEVEL ORDER seq=%d: DIFFERENT -- %d hosted ON.LEVEL callback(s)"
        .. " here, %d on the host%s. The mods registered them differently; compare the two"
        .. " logs' 'level order' lines", s, judged.here, judged.host, which)
end

local probeInstalled = false

-- --------------------------------------------------------------------- install

--- Give a hosted mod's environment every guarantee above.
---
--- Called once per hosted mod, after the host has put its own wrappers in place, so
--- the `set_callback` chained here is whatever the host installed and both layers
--- compose. Our own callbacks are registered with the ENGINE's `set_callback`, not
--- the sandbox one, and this runs before the mod's chunk does.
---
--- Registering first does NOT mean running first. Overlunky keeps a script's
--- callbacks in an unordered_map and runs them in its own order (see "the order
--- hosted callbacks run in"), so nothing of ours that has to come before the mod may
--- rely on being registered earlier: those are heads (module.head), run first in the
--- ordered pass.
---
--- @param env table            # the sandbox the mod will run in
--- @param opts table?          # { orderedPairs = boolean, active = fun(): boolean,
---                               #   heldFrame = fun(): boolean }
--- @return DeterminismControl
function module.install(env, opts)
    opts = opts or {}
    local clock = module.newClock()
    local gen = module.newGenerator(module.floorBase())
    local matched = {}
    local runPlan = false
    local lastRunSeed = nil
    local stats = {
        reseeds = 0, newRuns = 0, anchored = 0, liquidTiles = 0,
        levelAnchored = 0, waterFxSeen = 0, heldSkips = 0,
    }
    local control -- forward: checkNewRun hands it to adapters

    -- Determinism is for AGREEING WITH ANOTHER MACHINE. Outside a room there is no
    -- other machine, and forcing it there is not neutral -- it is a bug the player
    -- sees: seeding the mod's `math.random` from the floor base every floor made
    -- every single 1-1 come out with the same level feeling, run after run, in
    -- ordinary single-player. Hosting a mod must not change how it plays alone.
    --
    -- Defaults to always-on so the tests, which have no network, keep exercising it.
    local isActive = opts.active or function() return true end

    -- True on a frame the lockstep gate held the simulation still (see
    -- simulatedOnly). Looked up per call rather than captured: InputSync is a
    -- global of its own module, and the tests install without it.
    local heldFrame = opts.heldFrame or function()
        local sync = rawget(_G, "InputSync")
        return sync ~= nil and sync.heldFrame ~= nil and sync.heldFrame() == true
    end

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

    -- ------------------------------------------- deterministic water at ON.LEVEL
    --
    -- Spelunky 2 simulates liquid across worker threads, so two machines two frames
    -- into a level do NOT agree on the exact tiles at a waterline. That would be
    -- harmless if mods only drew water; the HD mod instead makes SPAWN decisions
    -- from it at ON.LEVEL -- lily pads, the frogs sitting on them, kelp, anchovy
    -- flocks -- in the form
    --
    --   if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
    --
    -- and `and` short-circuits, so one tile of disagreement along a shoreline
    -- changes HOW MANY times the shared PRNG is drawn and every draw after it lands
    -- elsewhere. So the mod's ON.LEVEL callbacks get their answers from a snapshot
    -- taken at POST_LEVEL_GENERATION, where no physics update has run yet and the
    -- water is a pure function of the shared seed and layout. Gameplay checks --
    -- piranhas, drowning, water a bomb displaced -- still reach the engine.
    --
    -- The injected shim has done this since v21. Hosting a mod instead of injecting
    -- into it left it behind, and the capture showed exactly the old symptom again:
    -- every PRNG stream identical at gen[pre] and gen[post] on 2-4, then one extra
    -- frog on one extra lily pad on one machine at the first frame (+1 crab, +1
    -- leaf), the party split by 15:720 and every floor after it differed.
    --
    -- Only for a mod that builds its own levels (see detectAdapters), as the shim
    -- had it, and only in a room: alone, the mod gets the engine's own answer.
    local liquidSnap = nil     -- tile key -> true, this floor's generated water
    local liquidWindow = false -- inside one of the mod's ON.LEVEL callbacks
    local ownLevels = false    -- the mod generates its own levels
    local realIsLiquidAt = env.is_liquid_at -- the engine's, through the sandbox

    local function liquidLookup(x, y)
        return liquidSnap[math.floor(x + 0.5) * 4096 + math.floor(y + 0.5)] == true
    end

    if type(realIsLiquidAt) == "function" then
        env.is_liquid_at = function(x, y, ...)
            if liquidWindow and liquidSnap ~= nil then
                local ok, hit = pcall(liquidLookup, x, y)
                if ok then
                    return hit
                end
            end
            return realIsLiquidAt(x, y, ...)
        end
    end

    --- Run one of the mod's ON.LEVEL callbacks with the snapshot answering. The
    --- window is closed again even if the callback throws: left open, every later
    --- gameplay liquid check would read the snapshot.
    local function liquidWindowed(cb)
        return wraps(function(...)
            local was = liquidWindow
            liquidWindow = true
            local ok, ret = pcall(cb, ...)
            liquidWindow = was
            if not ok then
                error(ret, 0)
            end
            return ret
        end, cb)
    end

    -- ---------------------------------- the water's surface effects at ON.LEVEL
    --
    -- FX_WATER_SURFACE is the engine's drawn waterline. The liquid system creates it
    -- between ON.POST_LEVEL_GENERATION and ON.LEVEL, as the HD mod's own author
    -- narrowed it down (lib/entities/jungle_deco.lua). 2.5's swamp stands its lily
    -- pads on exactly these (hooks/swamp/water.lua), and the HD mod's procedural lily
    -- pads, and the frogs on them, read them too.
    --
    -- dev75 hid them from a hosted mod's ON.LEVEL in a room, on the belief that two
    -- machines do not hold the same set of them: the BGNY capture's 2-1 had one more
    -- lily pad on the peer and a different shop. dev76 measured, and that belief was
    -- wrong. In room FVJF the surfaces were identical on both machines on every wet
    -- floor, to a hundredth of a tile and in the same order, at ON.LEVEL and at the
    -- first frame. What BGNY's extra pad really came from was the ON.LEVEL callbacks
    -- running in a different order on each machine (see "the order of ON.LEVEL"),
    -- with nothing to stop one callback's draws moving the next one's. The anchor
    -- (levelAnchored, below) and the registration order now stop both.
    --
    -- So the mod gets the engine's own answer again, and the lily pads and frogs are
    -- back. The probe still watches what each of the mod's ON.LEVEL queries returns,
    -- so the next capture says whether both machines' mods saw the same surfaces.
    local waterFx = nil
    pcall(function() waterFx = ENT_TYPE.FX_WATER_SURFACE end)
    local fxMask = 64 -- MASK.FX
    pcall(function() fxMask = math.floor(MASK.FX) end)

    --- Could a query for these types return a water surface effect? 0, nothing, and
    --- an empty list all mean every type.
    --- @param types any
    --- @return boolean
    local function typesMayHoldWaterFx(types)
        if type(types) == "table" then
            local n = 0
            for _, t in ipairs(types) do
                n = n + 1
                if t == waterFx or t == 0 then
                    return true
                end
            end
            return n == 0
        end
        return types == nil or types == 0 or types == waterFx
    end

    --- ...and could this mask? 0 is MASK.ANY.
    --- @param mask any
    --- @return boolean
    local function maskMayHoldFx(mask)
        local m = tonumber(mask)
        if m == nil or m == 0 then
            return true
        end
        return (math.floor(m) & fxMask) ~= 0
    end

    --- @param uid integer
    --- @return integer?
    local function entityTypeOf(uid)
        local ok, t = pcall(get_entity_type, uid)
        if ok and type(t) == "number" then
            return t
        end
        local ok2, t2 = pcall(function() return get_entity(uid).type.id end)
        if ok2 then
            return t2
        end
        return nil
    end

    --- The water surface effects in one answer, in the order the engine listed them.
    --- Read by length and index rather than tested for `type(list) == "table"`: a
    --- build whose binding hands back an indexable container must still be read.
    --- @param list any
    --- @return integer[]
    local function surfacesIn(list)
        local found = {}
        for i = 1, #list do
            local uid = list[i]
            if entityTypeOf(uid) == waterFx then
                found[#found + 1] = uid
            end
        end
        return found
    end

    --- One of the mod's ON.LEVEL queries, for the probe: what it was given goes back
    --- to it exactly as the engine gave it. Every query counts, an empty one too --
    --- one machine finding a surface where the other finds none is exactly the
    --- difference the probe looks for.
    --- @param list any
    --- @return any
    local function watched(list)
        if list == nil then
            return list
        end
        local ok, found = pcall(surfacesIn, list)
        if ok then
            stats.waterFxSeen = stats.waterFxSeen + #found
            pcall(probeModView, found)
        end
        return list
    end

    --- Is a query made right now one the probe should look at? The callers test
    --- `liquidWindow` first: these wrap queries 2.5 makes many times a frame, and
    --- outside ON.LEVEL that one upvalue is all they should cost.
    --- @return boolean
    local function watchingWaterFx()
        return liquidWindow and probe ~= nil and waterFx ~= nil and isActive()
    end

    --- The engine's function the mod would otherwise get. rawget, both times: the
    --- sandbox's read-through counts every name it cannot find as an unknown global
    --- the mod asked for, and a build without one of these is ours to probe for,
    --- not the mod's.
    --- @param name string
    --- @return function?
    local function engineQuery(name)
        local f = rawget(env, name)
        if f == nil then
            f = rawget(_G, name)
        end
        if type(f) == "function" then
            return f
        end
        return nil
    end

    --- Watch one of the engine's entity queries. `typeAt` and `maskAt` are the
    --- positions of its type and mask arguments. Feature-detected: a build without
    --- the function simply has nothing to watch.
    --- @param name string
    --- @param typeAt integer
    --- @param maskAt integer
    local function watchQuery(name, typeAt, maskAt)
        local real = engineQuery(name)
        if real == nil then
            return
        end
        env[name] = function(...)
            if liquidWindow and watchingWaterFx() then
                local types = (select(typeAt, ...))
                local mask = (select(maskAt, ...))
                if typesMayHoldWaterFx(types) and maskMayHoldFx(mask) then
                    return watched(real(...))
                end
            end
            return real(...)
        end
    end
    watchQuery("get_entities_by", 1, 2)
    watchQuery("get_entities_at", 1, 2)
    watchQuery("get_entities_overlapping_hitbox", 1, 2)
    watchQuery("get_entities_overlapping", 1, 2)

    -- get_entities_by_type takes its types as the arguments themselves, or as one
    -- table of them, and has no mask
    local realByType = engineQuery("get_entities_by_type")
    if realByType ~= nil then
        env.get_entities_by_type = function(...)
            if liquidWindow and watchingWaterFx() then
                local first = ...
                local types = type(first) == "table" and first or { ... }
                if typesMayHoldWaterFx(types) then
                    return watched(realByType(...))
                end
            end
            return realByType(...)
        end
    end

    --- ...and whatever a hosted mod DRAWS at ON.LEVEL stays there.
    ---
    --- POST_LEVEL_GENERATION is anchored (below) and ON.LEVEL was not, though it too
    --- fires once per floor at the same state on every machine, and it is where mods
    --- decorate the level they were given. On BGNY's 2-1 the swamp's lily pads drew
    --- the shared streams after a different set of callbacks on each machine, and
    --- every roll after it, the engine's own included, landed somewhere else. The
    --- Wheel of Fortune's coin was one of them, flipped frames later in POST_UPDATE
    --- by a hook that had read nothing machine-dependent at all.
    ---
    --- Anchored, each callback starts from the floor's lockstep-identical base and
    --- the engine's streams are put back afterwards, so whatever one callback draws,
    --- nothing after it can tell. In a room only: alone, the mod's rolls carry on
    --- from the engine's streams exactly as they always did.
    --- @param cb function
    --- @return function
    local function levelAnchored(cb)
        local anchored = module.anchor(cb, floorBase)
        return wraps(function(...)
            if not isActive() then
                return cb(...)
            end
            stats.levelAnchored = stats.levelAnchored + 1
            return anchored(...)
        end, cb)
    end

    -- Whatever the host installed as the sandbox's set_callback, captured here --
    -- above registerOrdered, which needs it: a `local` declared after a function is a
    -- global inside it, and comes back nil.
    local hostSetCallback = rawget(env, "set_callback") or set_callback

    --- A hosted callback for an ordered event, into that event's list (see "the order
    --- hosted callbacks run in"). The engine still gets one registration per callback,
    --- with the id the mod is handed back, so clearing it by id works exactly as it did.
    --- @param run any # the callback as it is to be run: windowed, anchored, held-skipping
    --- @param cb any  # the mod's own function, for its name
    --- @param id any  # the event
    --- @return any # the engine's callback id
    local function registerOrdered(run, cb, id)
        local ord = orderOf(id)
        orderSeq = orderSeq + 1
        local entry = {
            ord = ord, seq = orderSeq, phase = 2, run = run, own = cb, env = env,
            mod = true, isActive = isActive, where = whereDefined(cb), cleared = false,
        }
        local engineId = hostSetCallback(wraps(function(...)
            return orderedDispatch(entry, ...)
        end, run), id)
        if type(engineId) == "number" then
            entry.engineId = engineId
            ord.entries[#ord.entries + 1] = entry
            ord.mods = ord.mods + 1
            ord.active = isActive
            orderById[engineId] = entry
        end
        return engineId
    end

    --- A hosted mod's update callbacks run once per SIMULATED frame.
    ---
    --- ON.PRE_UPDATE and ON.POST_UPDATE fire once per rendered frame, and that
    --- includes every frame the lockstep gate holds the world still while it waits
    --- for another machine's inputs: dev44's leak sweep was seen re-running on every
    --- frame of a stall. The engine does not tick on those frames, so for the mod's
    --- own logic they do not exist -- yet its callbacks ran on them, and how many
    --- there are is a property of the network, different on every machine. 2.5's
    --- Wheel of Fortune turns one step per POST_UPDATE, so on the machine that
    --- stalled more the wheel would stop, and pay out, on an earlier frame. The same
    --- shape is in its swamp water-poison count, in the push its monkey propeller
    --- adds before physics, and in every everyNthFrame wrapper it has.
    ---
    --- So on a held frame the mod's update callbacks are not called at all. Every
    --- other frame is untouched, including the engine's own pauses, which the mod
    --- sees and handles itself.
    ---
    --- ON.GAMEFRAME too, since dev78, and with it every ON.FRAME callback, which is
    --- moved to GAMEFRAME below. GAMEFRAME was thought to pause with the simulation;
    --- room VOYY's profile says otherwise. Over ten seconds of 4-2 the host's own
    --- POST_UPDATE callback ran 563 times -- once per simulated frame, the lockstep
    --- clock advanced 563 -- and its GAMEFRAME profiler 600: the engine's frame
    --- counter moves on a frame the gate holds, and GAMEFRAME fires on any frame it
    --- moved. The mod's GAMEFRAME callbacks ran at that rate as well (2.5's
    --- custom_entities.lua:599, 600 calls in the same window), about forty times
    --- more than the world moved on the host and twenty-five on the slower peer,
    --- which stalled less. Whatever they changed, they changed a different number
    --- of times on each machine. Its PRE_UPDATE wrapper is reached after the gate
    --- has decided the frame (InputSync.gateFirst, through modHost), so it reads
    --- THIS frame's decision rather than the last one's.
    --- @param cb function
    --- @return function
    local function simulatedOnly(cb)
        return wraps(function(...)
            if heldFrame() then
                stats.heldSkips = stats.heldSkips + 1
                return
            end
            return cb(...)
        end, cb)
    end

    --- Can the engine call this? A function, or a table or userdata with __call.
    --- @param v any
    --- @return boolean
    local function callable(v)
        local t = type(v)
        if t == "function" then
            return true
        end
        if t ~= "table" and t ~= "userdata" then
            return false
        end
        local ok, mt = pcall(getmetatable, v)
        return ok and type(mt) == "table" and rawget(mt, "__call") ~= nil
    end

    env.set_callback = function(cb, id)
        if not callable(cb) then
            -- Nothing to wrap: whatever the engine makes of a callback that cannot
            -- be called, it makes of it unhosted too. Wrapping one hid that until
            -- the event fired, and then raised the error from inside our wrapper.
            return hostSetCallback(cb, id)
        end
        local own = cb -- the mod's own function, before anything of ours is around it
        if id == ON.FRAME then
            -- moved to GAMEFRAME, as it always has been; once per SIMULATED frame
            -- there too (see simulatedOnly)
            id = ON.GAMEFRAME
            cb = simulatedOnly(cb)
        elseif ON.GAMEFRAME ~= nil and id == ON.GAMEFRAME then
            -- fires on the frames the gate holds as well (see simulatedOnly)
            cb = simulatedOnly(cb)
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
        elseif ON.LEVEL ~= nil and id == ON.LEVEL then
            -- whatever the mod decides at ON.LEVEL from the water, it decides from
            -- the same water on every machine (see liquidSnap), and whatever it draws
            -- there stays there (see levelAnchored)
            cb = levelAnchored(liquidWindowed(cb))
        elseif (ON.PRE_UPDATE ~= nil and id == ON.PRE_UPDATE)
            or (ON.POST_UPDATE ~= nil and id == ON.POST_UPDATE) then
            -- once per SIMULATED frame, like GAMEFRAME above (see simulatedOnly)
            cb = simulatedOnly(cb)
        end
        if ORDER_KIND[id] ~= nil then
            -- in a room every machine runs the mod's callbacks for this event in the
            -- order it registered them (see "the order hosted callbacks run in")
            return registerOrdered(cb, own, id)
        end
        return hostSetCallback(cb, id)
    end

    -- The sandbox's clear_callback, chained the same way: the host's ownership guard
    -- still decides, and this only keeps the ordered lists in step.
    local hostClear = rawget(env, "clear_callback")
    if type(hostClear) == "function" then
        env.clear_callback = function(id, ...)
            if id == nil then
                local running = orderRunning
                if running ~= nil and running.env == env and running.engineId ~= nil
                    and clearIsEntrysOwn(running) then
                    -- "clear the callback I am": the one running, which in a batch is
                    -- not the one the engine is running the pass from
                    forgetOrdered(running)
                    return hostClear(running.engineId)
                end
                return hostClear()
            end
            local entry = orderById[id]
            if entry ~= nil and entry.env == env then
                forgetOrdered(entry)
            end
            return hostClear(id, ...)
        end
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

    --- POST_LEVEL_GENERATION, before the mod's own: snapshot this floor's water for
    --- the mod's ON.LEVEL pass. Registered here, ahead of every callback the mod
    --- registers, so it is in place before anything of the mod's can read it.
    local function snapshotLiquid()
        liquidSnap = nil
        stats.liquidTiles = 0
        if not ownLevels or not isActive() or type(realIsLiquidAt) ~= "function" then
            return
        end
        pcall(function()
            local left, top, right, bottom = get_bounds()
            -- generous whole-tile bounds; y runs downward, so top > bottom
            left, right = math.floor(left) - 1, math.ceil(right) + 1
            bottom, top = math.floor(bottom) - 1, math.ceil(top) + 1
            local snap, wet = {}, 0
            for y = bottom, top do
                for x = left, right do
                    if realIsLiquidAt(x, y) then
                        snap[x * 4096 + y] = true
                        wet = wet + 1
                    end
                end
            end
            -- A dry floor keeps the engine's own answer: there is nothing to make
            -- deterministic, and a mod that adds water of its own after generation
            -- must not be told the level is dry.
            if wet > 0 then
                liquidSnap = snap
            end
            stats.liquidTiles = wet
        end)
        -- One line per wet floor, so a capture shows the snapshot was in force: the
        -- two machines must print the SAME count here, or generation already differed.
        local desyncLog = rawget(_G, "DesyncLog")
        if stats.liquidTiles > 0 and desyncLog ~= nil and desyncLog.event ~= nil then
            pcall(desyncLog.event, "liquid snapshot for the hosted mod's ON.LEVEL: %d wet tiles",
                stats.liquidTiles)
        end
    end

    --- PRE_UPDATE and POST_UPDATE, ahead of the mod's: its generator reseeded for this
    --- update, from the floor and the simulated frame alone. GAMEFRAME already is
    --- (onFrame); between GAMEFRAME and the next PRE_UPDATE come the render callbacks,
    --- which run as often as this machine draws, so anything they drew moved the
    --- stream the mod's next update read.
    --- @param salt integer # one per event, so the two never draw the same numbers
    --- @return function
    local function reseedFor(salt)
        return function()
            if not isActive() then
                return -- solo: leave the mod's own randomness alone
            end
            gen.randomseed(module.floorBase() ~ (clock.rawSimFrame() * 2654435761) ~ salt)
        end
    end

    -- Ours, ahead of the mod's in every pass: what the mod's callbacks for each event
    -- see, they see on every machine (see "the order hosted callbacks run in").
    module.head(ON.LOADING, "determinism:onLoading", onLoading)
    module.head(ON.PRE_LEVEL_GENERATION, "determinism:onFloor", onFloor)
    module.head(ON.GAMEFRAME, "determinism:onFrame", onFrame)
    module.head(ON.PRE_UPDATE, "determinism:reseed", reseedFor(0x50524555))
    module.head(ON.POST_UPDATE, "determinism:reseed", reseedFor(0x504F5355))
    module.head(ON.PRE_LOAD_SCREEN, "determinism:clock", clock.invalidate)
    module.head(ON.POST_LEVEL_GENERATION, "determinism:snapshotLiquid", snapshotLiquid)

    -- The water probe (measurement only, see above): once, however many mods are
    -- hosted, since it looks at the engine's water and not at any one mod. Both its
    -- looks come before the first of the mod's callbacks runs.
    if not probeInstalled then
        probeInstalled = true
        module.head(ON.POST_LEVEL_GENERATION, "determinism:probeGeneration", function()
            -- a new floor: a new ON.LEVEL pass to come, and nothing run in it yet
            resetLevelRan()
            pcall(probeGeneration, isActive)
        end)
        module.head(ON.LEVEL, "determinism:probeLevel", function()
            pcall(probeLevel, isActive)
        end)
    end

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
                    -- the two kinds of mod that build their own levels, which is
                    -- exactly the set the shim gave the water snapshot to
                    if adapter.name == "run-plan" or adapter.name == "posttile-start" then
                        ownLevels = true
                    end
                end
            end
            return matched
        end,
        matched = function() return matched end,
        --- This mod's run state for a player folded back into the run (see "a hosted
        --- mod's run state"): an adapter's, as one string, or nil and why not.
        captureRun = function()
            return module.captureRunFor(env, matched)
        end,
        --- ...put into a returning player's mod, at the head and the tail of the
        --- fold-in floor's load.
        applyRun = function(blob)
            return module.applyRunFor(env, matched, blob)
        end,
        runSupported = function()
            return module.runSupportedFor(env, matched)
        end,
        runDigest = function()
            return module.runDigestFor(env, matched)
        end,
    }
    return control
end

-- ---------------------------------------------------------- a hosted mod's run state
--
-- A player folded back into a run under way rebuilds the party's next floor from the
-- host's snapshot of the ENGINE's state (eventSync's captureStateSync). A content mod
-- keeps the run's history in its own memory as well, and a game that rejoins mid-run
-- has none of it: room QZUX's returning player warped in from the camp, where
-- Overlunky's warp() raises the reset flag, and Spelunky 2.5 reset its whole run --
-- then rolled a new Dwelling plan at the next floor's level files, and built a
-- different 1-4 from the same seed.
--
-- So an adapter that knows where a mod keeps its run can hand it over: the world host
-- that folds the player in takes it at the end of its own PRE_LOAD_SCREEN for that
-- floor, once the mod's load callbacks have read the transition screen it is leaving,
-- and the returning player's machine puts it in at the head of its own load and again
-- at its tail (eventSync, "bringing a player back"). Nobody else's mod is touched.
--
-- Only plain data travels: numbers, strings, booleans and tables of them. Functions,
-- userdata and threads stay where they are, and so does anything an adapter names as
-- this machine's own (an engine callback id, say).

--- The longest a run state may be, in characters. It rides one UDP datagram with the
--- rest of the run_start (the client reads 32 KB at most), so the snapshot stays well
--- inside that; a bigger one is refused, and the player waits for the next run.
local RUN_STATE_MAX = 16000
local RUN_STATE_DEPTH = 32

--- @param text string
--- @return string
local function escapeRunText(text)
    -- `"` and `\` too: JSON would escape them, and the state must not grow on the wire
    return (text:gsub("[%c%%;\"\\\128-\255]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

--- @param a any
--- @param b any
--- @return boolean
local function runKeyLess(a, b)
    local ra, rb = RANK[type(a)], RANK[type(b)]
    if ra ~= rb then
        return ra < rb
    end
    if ra == 3 then
        return b and not a -- false before true
    end
    return a < b
end

--- @param k any
--- @return boolean
local function runKey(k)
    local kind = type(k)
    return (kind == "number" and k == k) or kind == "string" or kind == "boolean"
end

--- @param v any
--- @return boolean
local function runCarried(v)
    local kind = type(v)
    return kind ~= "function" and kind ~= "userdata" and kind ~= "thread"
end

--- @param v any
--- @param out string[]
--- @param ctx table # { seen, tables, len, skipped, cut, limit, skip }
--- @param depth integer
local function encodeRunValue(v, out, ctx, depth)
    local piece
    local kind = type(v)
    if kind == "boolean" then
        piece = v and "T" or "F"
    elseif kind == "number" then
        if math.type(v) == "integer" then
            piece = string.format("i%d;", v)
        elseif v ~= v then
            piece = "fnan;"
        elseif v == math.huge then
            piece = "f+inf;"
        elseif v == -math.huge then
            piece = "f-inf;"
        else
            piece = "f" .. string.format("%a", v) .. ";"
        end
    elseif kind == "string" then
        piece = "s" .. escapeRunText(v) .. ";"
    elseif kind == "table" then
        local ref = ctx.seen[v]
        if ref ~= nil then
            piece = string.format("r%d;", ref)
        elseif depth >= RUN_STATE_DEPTH then
            ctx.cut = ctx.cut + 1
            piece = "n"
        else
            ctx.tables = ctx.tables + 1
            ctx.seen[v] = ctx.tables
            local keys = {}
            for k, val in next, v do
                if runKey(k) and runCarried(val) and not (ctx.skip ~= nil and ctx.skip[k]) then
                    keys[#keys + 1] = k
                else
                    ctx.skipped = ctx.skipped + 1
                end
            end
            table.sort(keys, runKeyLess)
            out[#out + 1] = "t"
            ctx.len = ctx.len + 1
            for i = 1, #keys do
                local k = keys[i]
                encodeRunValue(k, out, ctx, depth + 1)
                encodeRunValue(rawget(v, k), out, ctx, depth + 1)
                if ctx.len > ctx.limit then
                    return
                end
            end
            piece = "e"
        end
    else
        piece = "n" -- nil, and anything that does not travel
        if kind ~= "nil" then
            ctx.skipped = ctx.skipped + 1
        end
    end
    out[#out + 1] = piece
    ctx.len = ctx.len + #piece
end

--- A run state as text that survives JSON unchanged -- printable ASCII, no quote or
--- backslash -- and
--- reads back exactly: integers and floats apart (floats in hex, %a), strings
--- escaped, a table's keys in one fixed order, a table met twice written once.
--- Values that do not travel, and keys in `skip`, are left out.
--- @param value any
--- @param limit integer?
--- @param skip table<string, boolean>?
--- @return string? text
--- @return table|string info # { tables, skipped, cut } or why not
function module.encodeRun(value, limit, skip)
    local ctx = {
        seen = {}, tables = 0, len = 0, skipped = 0, cut = 0,
        limit = limit or RUN_STATE_MAX, skip = skip,
    }
    local out = {}
    local ok, err = pcall(encodeRunValue, value, out, ctx, 0)
    if not ok then
        return nil, "it could not be written: " .. tostring(err)
    end
    if ctx.len > ctx.limit then
        return nil, string.format("it is too big to send (over %d characters)", ctx.limit)
    end
    return table.concat(out), { tables = ctx.tables, skipped = ctx.skipped, cut = ctx.cut }
end

--- The run state encodeRun wrote, back as Lua values.
--- @param text string
--- @return any value, string? why # value nil and why on anything malformed
function module.decodeRun(text)
    if type(text) ~= "string" then
        return nil, "not text"
    end
    local pos, tables = 1, {}
    local function fail(why)
        error({ runDecode = why }, 0)
    end
    local function field()
        local stop = text:find(";", pos, true)
        if stop == nil then
            fail("unterminated value")
        end
        local s = text:sub(pos, stop - 1)
        pos = stop + 1
        return s
    end
    local value
    function value(depth)
        if depth > RUN_STATE_DEPTH + 1 then
            fail("too deep")
        end
        local c = text:sub(pos, pos)
        pos = pos + 1
        if c == "n" then
            return nil
        elseif c == "T" then
            return true
        elseif c == "F" then
            return false
        elseif c == "i" then
            local n = math.tointeger(tonumber(field()))
            if n == nil then
                fail("bad integer")
            end
            return n
        elseif c == "f" then
            local s = field()
            if s == "nan" then
                return 0 / 0
            elseif s == "+inf" then
                return math.huge
            elseif s == "-inf" then
                return -math.huge
            end
            local n = tonumber(s)
            if n == nil then
                fail("bad float")
            end
            return n + 0.0
        elseif c == "s" then
            local raw = field()
            if raw:gsub("%%%x%x", ""):find("%", 1, true) ~= nil then
                fail("bad escape") -- the encoder writes every % as %25
            end
            return (raw:gsub("%%(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end))
        elseif c == "r" then
            local i = math.tointeger(tonumber(field()))
            local t = i ~= nil and tables[i] or nil
            if t == nil then
                fail("bad reference")
            end
            return t
        elseif c == "t" then
            local t = {}
            tables[#tables + 1] = t
            while true do
                if pos > #text then
                    fail("unterminated table")
                end
                if text:sub(pos, pos) == "e" then
                    pos = pos + 1
                    return t
                end
                local k = value(depth + 1)
                local v = value(depth + 1)
                if k == nil then
                    fail("a table key that is not a value")
                end
                rawset(t, k, v)
            end
        end
        fail("unknown mark " .. string.format("%q", c))
    end
    local ok, result = pcall(value, 0)
    if not ok then
        return nil, type(result) == "table" and result.runDecode or tostring(result)
    end
    if pos ~= #text + 1 then
        return nil, "more after the end"
    end
    return result, nil
end

--- Make `target` hold what `source` holds, in place: the tables already there stay
--- the same tables (whoever holds one keeps seeing it), with what they keep that
--- does not travel -- a function, an engine object -- left alone.
--- @param target table
--- @param source table
--- @param depth integer?
function module.assignRun(target, source, depth)
    depth = depth or 0
    local drop = {}
    for k, v in next, target do
        if runKey(k) and runCarried(v) and rawget(source, k) == nil then
            drop[#drop + 1] = k
        end
    end
    for i = 1, #drop do
        rawset(target, drop[i], nil)
    end
    for k, v in next, source do
        if type(v) == "table" and depth < RUN_STATE_DEPTH then
            local here = rawget(target, k)
            if type(here) ~= "table" then
                here = {}
                rawset(target, k, here)
            end
            module.assignRun(here, v, depth + 1)
        else
            rawset(target, k, v)
        end
    end
end

--- Visit every upvalue of every function reachable from `roots` through upvalues, at
--- most `depth` steps in, until `visit(fn, index, name, value)` returns true.
--- Reading an upvalue runs nothing of the mod's.
--- @param roots function[]
--- @param depth integer
--- @param visit fun(fn: function, index: integer, name: string, value: any): boolean?
--- @param accept (fun(fn: function): boolean)? # which functions to look into
--- @return boolean found
local function walkUpvalues(roots, depth, visit, accept)
    local dbg = rawget(_G, "debug")
    if type(dbg) ~= "table" or type(dbg.getupvalue) ~= "function" then
        return false
    end
    local seen, frontier, steps = {}, {}, 0
    for i = 1, #roots do
        local fn = roots[i]
        if type(fn) == "function" and not seen[fn] then
            seen[fn] = true
            frontier[#frontier + 1] = fn
        end
    end
    for _ = 0, depth do
        local nextFrontier = {}
        for _, fn in ipairs(frontier) do
            if accept == nil or accept(fn) then
                for i = 1, 255 do
                    local ok, name, value = pcall(dbg.getupvalue, fn, i)
                    if not ok or name == nil then
                        break
                    end
                    steps = steps + 1
                    if steps > 100000 then
                        return false
                    end
                    if visit(fn, i, name, value) then
                        return true
                    end
                    if type(value) == "function" and not seen[value] then
                        seen[value] = true
                        nextFrontier[#nextFrontier + 1] = value
                    end
                end
            end
        end
        frontier = nextFrontier
        if #frontier == 0 then
            break
        end
    end
    return false
end

--- The mod's own callbacks, as registered with us: where its functions begin.
--- @param env table
--- @return function[]
local function hostedRoots(env)
    local roots = {}
    for _, ord in rawPairs(order) do
        for _, e in ipairs(ord.entries) do
            if e.env == env and not e.cleared and type(e.own) == "function" then
                roots[#roots + 1] = e.own
            end
        end
    end
    return roots
end

--- Is this function defined in a file whose name ends `suffix`?
--- @param fn function
--- @param suffix string
--- @return boolean
local function definedIn(fn, suffix)
    local dbg = rawget(_G, "debug")
    if type(dbg) ~= "table" or type(dbg.getinfo) ~= "function" then
        return false
    end
    local ok, info = pcall(dbg.getinfo, fn, "S")
    if not ok or type(info) ~= "table" then
        return false
    end
    -- either slash: the host names a file with forward ones, but a path is a path
    local src = tostring(info.source or ""):gsub("\\", "/")
    return src:sub(-#suffix) == suffix
end

module.runStateMax = RUN_STATE_MAX
module.walkUpvalues = walkUpvalues
module.hostedRoots = hostedRoots
module.definedIn = definedIn

--- This mod's run state, from the first matched adapter that keeps one: the adapter's
--- name and the encoded state, as one string. nil and why not otherwise.
--- @param env table
--- @param matched table[]
--- @return string? blob, string|table info
function module.captureRunFor(env, matched)
    for _, adapter in ipairs(matched or {}) do
        if type(adapter.captureRun) == "function" then
            local ok, data, why = pcall(adapter.captureRun, env)
            if not ok then
                return nil, "its run state could not be read: " .. safeText(data)
            end
            if data == nil then
                return nil, tostring(why or "it gave no run state")
            end
            local text, info = module.encodeRun(data, RUN_STATE_MAX, adapter.runSkipKeys)
            if text == nil then
                return nil, info
            end
            return tostring(adapter.name) .. ";" .. text, info
        end
    end
    return nil, "nothing here knows where this mod keeps its run"
end

--- Can this mod's run state be handed over? The same question captureRunFor answers,
--- without keeping the answer.
--- @param env table
--- @param matched table[]
--- @return boolean, string?
function module.runSupportedFor(env, matched)
    local blob, why = module.captureRunFor(env, matched)
    if blob == nil then
        return false, why
    end
    return true
end

--- Put a run state captureRunFor wrote into this mod.
--- @param env table
--- @param matched table[]
--- @param blob string
--- @return boolean ok, string what
function module.applyRunFor(env, matched, blob)
    if type(blob) ~= "string" then
        return false, "no run state arrived"
    end
    local name, text = blob:match("^([^;]*);(.*)$")
    if name == nil then
        return false, "the run state is not one this build wrote"
    end
    local adapter = nil
    for _, a in ipairs(matched or {}) do
        if tostring(a.name) == name and type(a.applyRun) == "function" then
            adapter = a
        end
    end
    if adapter == nil then
        return false, "this machine's copy of the mod is not one " .. name .. " recognised"
    end
    local data, why = module.decodeRun(text)
    if data == nil then
        return false, "the run state did not read back: " .. tostring(why)
    end
    local ok, applied, what = pcall(adapter.applyRun, env, data)
    if not ok then
        return false, "putting it back failed: " .. safeText(applied)
    end
    return applied == true, tostring(what or "")
end

--- A fingerprint of this mod's run state as an adapter reads it, or nil: the same
--- number on two machines whose mods are in the same run. An adapter's `digestRun`
--- picks what is compared -- what every machine in the run holds alike, not what one
--- of them is in the middle of carrying across a load -- and without one it is the
--- whole of what captureRun hands over.
--- @param env table
--- @param matched table[]
--- @return integer?
function module.runDigestFor(env, matched)
    for _, adapter in ipairs(matched or {}) do
        if type(adapter.captureRun) == "function" then
            local pick = type(adapter.digestRun) == "function" and adapter.digestRun
                or adapter.captureRun
            local ok, data = pcall(pick, env)
            if not ok or data == nil then
                return nil
            end
            local text = module.encodeRun(data, RUN_STATE_MAX, adapter.runSkipKeys)
            if text == nil then
                return nil
            end
            return textHash(tostring(adapter.name) .. ";" .. text)
        end
    end
    return nil
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

--- The engine's own prologue progress, `savegame.tutorial_state`: 0 nothing, 1
--- journal got, 2 key spawned, 3 door unlocked, 4 complete.
--- @return integer?
local function prologueState()
    local save = rawget(_G, "savegame")
    if save == nil then
        return nil
    end
    local ok, value = pcall(function() return save.tutorial_state end)
    if not ok or tonumber(value) == nil then
        return nil
    end
    return math.floor(tonumber(value))
end

--- How many tutorial runs hdmod has on record. Its records are written the moment the
--- tutorial's last level is finished, and kept in its save.
--- @param env table
--- @return integer
local function tutorialRecordCount(env)
    local records = rawget(env, "tutorialrecordslib")
    if type(records) ~= "table" or type(rawget(records, "get_tutorial_records")) ~= "function" then
        return 0
    end
    local ok, list = pcall(records.get_tutorial_records)
    if not ok or type(list) ~= "table" then
        return 0
    end
    return #list
end

--- The HD mod's prologue ends when the camp's main exit is unlocked with the key the
--- mod hands the party after its tutorial -- and online, that door is inert.
---
--- The engine keeps the prologue in `savegame.tutorial_state` and hdmod only reads
--- it: `camplib.is_prologue_active()` is `tutorial_state <= 2`. The engine moves it
--- to 3 when the key unlocks the main exit and to 4 when the first adventure starts
--- through it. Online the main exit is inert (`can_enter` is false, see
--- eventSync's hookMainDoor), so neither happens -- the party's run starts from
--- the ready-up instead -- and the state stays at 2. The prologue then never ends:
--- every camp after that run replays the rope entry, drops the journal again and
--- keeps the main door locked, so the party is sent back through the tutorial. That
--- is the reported "it still tried to give the tutorial journal and make the player
--- do the tutorial".
---
--- So a run started from the main exit completes the prologue as walking through
--- that door would have: state 4. Only where the door could have opened. At 3 it
--- already has. At 2 the key has to be in the party's hands, which hdmod arranges in
--- exactly one place -- the camp right after its tutorial (`is_post_tutorial`, the
--- condition it spawns the key on) -- or the tutorial has been finished before (its
--- record list is not empty), which is what rescues a save that went through this
--- once already and lost the key with that camp. A prologue that has not reached the
--- key (0 or 1) is left alone, and so is a party that never finished the tutorial:
--- in the game itself the door would still be locked.
---
--- Every input is identical on every machine -- the start door rides on run_start,
--- the tutorial ran in lockstep and set `is_post_tutorial` and its record on all of
--- them, and a peer plays on the host's `savegame` fields -- so every machine makes
--- the same decision. Matched on `worldlib` for the same reason the tutorial door
--- adapter is: detection happens once, right after the mod's main chunk.
module.register({
    name = "hd-prologue-exit",
    detect = function(env)
        local world = rawget(env, "worldlib")
        return type(world) == "table"
            and type(rawget(world, "HD_WORLDSTATE_STATUS")) == "table"
    end,
    --- @return boolean # recognised, and a reason string when it was not
    startDoor = function(env, dest)
        if type(dest) == "table" and dest[1] ~= nil then
            return false, "a camp door, not the main exit"
        end
        local was = prologueState()
        if was == nil then
            return false, "no savegame to read the prologue from"
        end
        if was >= 4 then
            return false, "the prologue is already complete"
        end
        if was < 2 then
            return false, string.format("prologue at %d: the key is not reachable yet", was)
        end
        local why
        if was == 3 then
            why = "the door was already unlocked"
        else
            local camp = rawget(env, "camplib")
            if type(camp) == "table" and rawget(camp, "is_post_tutorial") == true then
                why = "the camp right after the tutorial, where the party holds the key"
            elseif tutorialRecordCount(env) > 0 then
                why = string.format("the tutorial has been finished %d time(s) before",
                    tutorialRecordCount(env))
            else
                return false, "prologue at 2 and the tutorial was never finished:"
                    .. " the door would still be locked"
            end
        end
        rawget(_G, "savegame").tutorial_state = 4
        local DesyncLog = rawget(_G, "DesyncLog")
        if DesyncLog ~= nil and DesyncLog.earlyEvent ~= nil then
            pcall(DesyncLog.earlyEvent,
                "mod host: hd-prologue-exit: the run left through the main exit,"
                .. " prologue %d -> 4 (%s)", was, why)
        end
        return true
    end,
})

-- ------------------------------------------------------- Spelunky 2.5's run state
--
-- 2.5 keeps its run in one object, the game (src/game.lua): the run's plan and quests
-- in `globalState` (src/gameState.lua: "A collection of state variables which are
-- reset on game reset. These are preserved through the entire game." -- plain data,
-- every field of it), and which of its worlds the run is in (sp25World,
-- spelunky2World, the route of the transition being crossed, gameRestarted). The
-- game is a local of its main.lua that the callbacks it registers hold, so it is
-- found through their upvalues, once.
--
-- The custom items a player carries from floor to floor are remembered by its Custom
-- Entities library (SereneRuby12's) in four lists the library's functions share:
-- taken at the load INTO a transition, read back at the load out of it. They travel
-- too -- without the ids of the entity hooks the library installed on this machine
-- (`_lib_callbacks`), which are this machine's own; the library reads a record
-- without them as it reads one for an item taken out of storage, and installs its
-- hooks afresh.
--
-- And a few of 2.5's own files keep, in locals of their own, what their load
-- callbacks read off the screen being left (SP25_LOCALS): a held ray gun's charge, a
-- ridden Qilin's health and the rapid-fire Qilin itself, whether the Qilin quest's egg,
-- the crystal Udjat or the worm meat was being carried. Those callbacks find nothing
-- in a camp, so the returning player gets the host's values, read through the
-- function each file hands back to the `require` that loaded it. One quest keeps its
-- progress in its initialize's locals so that it outlives each floor's callbacks: the
-- Summit climbers' chain, read through the handler of a hook 2.5 registered for it.

local SP25_CARRY = {
    t = "custom_entities_t_info", hh = "custom_entities_t_info_hh",
    st = "custom_entities_t_info_storage", cog = "custom_entities_t_info_cog_ankh",
}
local SP25_RUN_VERSION = 2
local sp25Games = setmetatable({}, { __mode = "k" }) -- sandbox -> its game, once found

--- The file-scope locals 2.5's load callbacks set from the screen being left, by the
--- end of the file's path. Every one must be found, or the run is not handed over.
local SP25_LOCALS = {
    { file = "/src/items/rayGun.lua", names = { "transitionRestoreBySlot" } },
    { file = "/src/items/qilinQuest.lua", names = { "questRockWasHeld", "rapidQilinStates",
        "rapidQilinUid", "rapidQilinHealth", "rapidQilinTransitionPending",
        "rapidQilinRestoreFrames" } },
    { file = "/src/items/crystalUdjatQuest.lua", names = { "crystalUdjatWasHeld" } },
    { file = "/src/items/wormMeat.lua", names = { "wormMeatWasHeld" } },
    -- "These variables intentionally live outside the per-level hook callbacks so the
    -- chain can persist across Summit-2, Summit-3, and Summit-4." Reached through the
    -- hook that clears them off the Summit, whose handler holds every one.
    { file = "/src/hooks/summit/climbersquest.lua", hook = "cleanup-climberchainquest@NOT-Summit",
        names = { "quest_active", "quest_failed", "saved_count", "active_fly_uid",
            "active_fly_level", "level_is_ending", "pending_rescued_climber",
            "pending_fly_level", "pending_fly_attempts" } },
}
local sp25Locals = setmetatable({}, { __mode = "k" }) -- sandbox -> its SP25_LOCALS, found

--- 2.5's game object, found through the upvalues of the callbacks it registered.
--- @param env table
--- @return table?
local function sp25Game(env)
    local game = sp25Games[env]
    if game ~= nil then
        return game
    end
    local class = rawget(env, "Sp25GameClass")
    if type(class) ~= "table" then
        return nil
    end
    walkUpvalues(hostedRoots(env), 4, function(_, _, _, value)
        if type(value) == "table" then
            local ok, mt = pcall(getmetatable, value)
            if ok and rawequal(mt, class) then
                game = value
                return true
            end
        end
        return false
    end)
    if game ~= nil then
        sp25Games[env] = game
    end
    return game
end

--- Where the Custom Entities library keeps its four carry lists: key -> { fn, index }
--- of an upvalue holding it, read through the library's own functions only.
--- @param env table
--- @return table<string, { fn: function, index: integer }>?
local function sp25CarrySlots(env)
    local lib = rawget(env, "CustomEntities")
    if type(lib) ~= "table" then
        return nil
    end
    local roots = {}
    for _, v in next, lib do
        if type(v) == "function" then
            roots[#roots + 1] = v
        end
    end
    local want = {}
    for key, name in rawPairs(SP25_CARRY) do
        want[name] = key
    end
    local slots, found = {}, 0
    walkUpvalues(roots, 2, function(fn, index, name)
        local key = want[name]
        if key ~= nil and slots[key] == nil then
            slots[key] = { fn = fn, index = index }
            found = found + 1
            return found == 4
        end
        return false
    end, function(fn)
        return definedIn(fn, "custom_entities.lua")
    end)
    if found < 4 then
        return nil
    end
    return slots
end

--- The handler 2.5 gave Hooks.runWhen under `name`, from its registry (a hook context
--- keeps `name` and `handler`), or nil.
--- @param env table
--- @param name string
--- @return function?
local function sp25HookHandler(env, name)
    local hooks = rawget(env, "Hooks")
    if type(hooks) ~= "table" then
        return nil
    end
    local lists = { rawget(hooks, "alwaysHooks"), rawget(hooks, "alwaysCheckHooks") }
    local byKey = rawget(hooks, "hooks")
    if type(byKey) == "table" then
        for _, list in next, byKey do
            lists[#lists + 1] = list
        end
    end
    for _, list in ipairs(lists) do
        if type(list) == "table" then
            for _, ctx in ipairs(list) do
                if type(ctx) == "table" and rawget(ctx, "name") == name
                    and type(rawget(ctx, "handler")) == "function" then
                    return rawget(ctx, "handler")
                end
            end
        end
    end
    return nil
end

--- Where SP25_LOCALS live: "file:name" -> { fn, index, name } of an upvalue holding
--- each, found from the value the file returned to `require` (2.5's item files return
--- their initialize function, whose upvalues reach every local its callbacks use), or
--- from a hook's handler. nil and why when any is missing, or a name could mean two
--- different locals.
--- @param env table
--- @return table<string, { fn: function, index: integer, name: string }>?, string?
local function sp25LocalSlots(env)
    local cached = sp25Locals[env]
    if cached ~= nil then
        return cached
    end
    local mh = rawget(_G, "ModHost")
    local dbg = rawget(_G, "debug")
    if type(mh) ~= "table" or type(mh.loadedModuleValue) ~= "function"
        or type(dbg) ~= "table" or type(dbg.upvalueid) ~= "function" then
        return nil, "this build cannot read a file's own locals"
    end
    local slots = {}
    for _, spec in ipairs(SP25_LOCALS) do
        local root
        if spec.hook ~= nil then
            root = sp25HookHandler(env, spec.hook)
            if root == nil then
                return nil, "the hook " .. spec.hook .. " was not found"
            end
        else
            local ok, value = pcall(mh.loadedModuleValue, env, spec.file)
            if not ok or type(value) ~= "function" then
                return nil, spec.file .. " was not loaded"
            end
            root = value
        end
        local wanted, ids = {}, {}
        for _, name in ipairs(spec.names) do
            wanted[name] = true
        end
        local twice = nil
        walkUpvalues({ root }, 3, function(fn, index, name)
            if wanted[name] then
                local okId, id = pcall(dbg.upvalueid, fn, index)
                local key = spec.file .. ":" .. name
                if not okId then
                    twice = key
                elseif ids[name] == nil then
                    ids[name] = id
                    slots[key] = { fn = fn, index = index, name = name }
                elseif ids[name] ~= id then
                    twice = key -- two locals of that name: which one is meant?
                end
            end
            return false
        end, function(fn)
            return definedIn(fn, spec.file)
        end)
        if twice ~= nil then
            return nil, twice .. " is not one local"
        end
        for _, name in ipairs(spec.names) do
            if slots[spec.file .. ":" .. name] == nil then
                return nil, spec.file .. ":" .. name .. " was not found"
            end
        end
    end
    sp25Locals[env] = slots
    return slots
end

--- 2.5's run state and which of its worlds the run is in: what captureRun hands over
--- and the run's fingerprint compares.
--- @param game table
--- @return table
local function sp25World(game)
    return {
        sp25World = rawget(game, "sp25World"),
        spelunky2World = rawget(game, "spelunky2World"),
        gameRestarted = rawget(game, "gameRestarted"),
        from = rawget(game, "transitionFromSp25World"),
        to = rawget(game, "transitionToSp25World"),
    }
end

module.register({
    name = "spelunky-2.5",
    detect = function(env)
        return type(rawget(env, "Sp25GameClass")) == "table"
            and type(rawget(env, "Sp25GameStateClass")) == "table"
    end,
    newRun = function() end,
    -- this machine's own: the entity hooks the Custom Entities library installed
    runSkipKeys = { _lib_callbacks = true },
    --- @param env table
    --- @return table? data, string? why
    captureRun = function(env)
        local game = sp25Game(env)
        if game == nil then
            return nil, "its game was not found"
        end
        local gs = rawget(game, "globalState")
        if type(gs) ~= "table" then
            return nil, "it has no run state yet"
        end
        local slots = sp25CarrySlots(env)
        if slots == nil then
            return nil, "its custom item lists were not found"
        end
        local locals, whyNot = sp25LocalSlots(env)
        if locals == nil then
            return nil, whyNot
        end
        local dbg = rawget(_G, "debug")
        local carry = {}
        for key, slot in rawPairs(slots) do
            local ok, _, value = pcall(dbg.getupvalue, slot.fn, slot.index)
            if ok and type(value) == "table" then
                carry[key] = value
            end
        end
        local own = {}
        for key, slot in rawPairs(locals) do
            local ok, name, value = pcall(dbg.getupvalue, slot.fn, slot.index)
            if not ok or name ~= slot.name then
                return nil, key .. " moved"
            end
            own[key] = { v = value } -- a box, so a nil travels as one
        end
        return {
            v = SP25_RUN_VERSION,
            gs = gs,
            w = sp25World(game),
            ce = carry,
            ml = own,
        }
    end,
    --- What two machines in the same run hold alike: the run state and the world,
    --- not the items and values in the middle of being carried across a load.
    --- @param env table
    --- @return table?
    digestRun = function(env)
        local game = sp25Game(env)
        if game == nil then
            return nil
        end
        local gs = rawget(game, "globalState")
        if type(gs) ~= "table" then
            return nil
        end
        return { v = SP25_RUN_VERSION, gs = gs, w = sp25World(game) }
    end,
    --- @param env table
    --- @param data table
    --- @return boolean ok, string what
    applyRun = function(env, data)
        if type(data) ~= "table" or data.v ~= SP25_RUN_VERSION or type(data.gs) ~= "table"
            or type(data.w) ~= "table" or type(data.ce) ~= "table"
            or type(data.ml) ~= "table" then
            return false, "it is not a run state this build reads"
        end
        local game = sp25Game(env)
        if game == nil then
            return false, "its game was not found"
        end
        local slots = sp25CarrySlots(env)
        if slots == nil then
            return false, "its custom item lists were not found"
        end
        local locals, whyNot = sp25LocalSlots(env)
        if locals == nil then
            return false, whyNot
        end
        for key in rawPairs(locals) do
            if type(data.ml[key]) ~= "table" then
                return false, key .. " did not come with it"
            end
        end
        local dbg = rawget(_G, "debug")
        if type(dbg) ~= "table" or type(dbg.setupvalue) ~= "function" then
            return false, "debug.setupvalue is not available"
        end
        local gs = rawget(game, "globalState")
        if type(gs) ~= "table" then
            gs = {}
            local class = rawget(env, "Sp25GameStateClass")
            if type(class) == "table" then
                setmetatable(gs, class)
            end
            rawset(game, "globalState", gs)
        end
        module.assignRun(gs, data.gs)
        rawset(game, "sp25World", data.w.sp25World)
        rawset(game, "spelunky2World", data.w.spelunky2World)
        rawset(game, "gameRestarted", data.w.gameRestarted)
        rawset(game, "transitionFromSp25World", data.w.from)
        rawset(game, "transitionToSp25World", data.w.to)
        local carried = 0
        for key, name in rawPairs(SP25_CARRY) do
            local slot = slots[key]
            local list = data.ce[key]
            if type(list) ~= "table" then
                list = {}
            end
            carried = carried + #list
            local set = dbg.setupvalue(slot.fn, slot.index, list)
            if set ~= name then
                return false, "the custom item list " .. name .. " moved"
            end
        end
        local own = 0
        for key, slot in rawPairs(locals) do
            local set = dbg.setupvalue(slot.fn, slot.index, data.ml[key].v)
            if set ~= slot.name then
                return false, key .. " moved"
            end
            own = own + 1
        end
        local fields = 0
        for _ in next, gs do
            fields = fields + 1
        end
        return true, string.format("world %s, %d run values, %d carried custom item(s),"
            .. " %d of its own", tostring(rawget(game, "sp25World")), fields, carried, own)
    end,
})

Determinism = module
return module
