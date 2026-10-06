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
---
--- The streams go back even when the body throws. A throwing callback used to skip
--- the restore and leave our seed in force for the rest of the floor, which is the
--- exact leak the restore exists to prevent. The error is raised again unchanged.
--- @param cb function
--- @param base fun(): integer
--- @return function
function module.anchor(cb, base)
    return function(...)
        local saved = module.savePrng()
        pcall(seedFromBase, base)
        local ok, ret = pcall(cb, ...)
        module.restorePrng(saved)
        if not ok then
            error(ret, 0)
        end
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

-- ------------------------------------------------------------- the water probe
--
-- MEASUREMENT ONLY (dev76): nothing here changes what any mod sees or does.
--
-- dev75 hides FX_WATER_SURFACE from a hosted mod's ON.LEVEL in a room. That keeps
-- the machines in sync, at the price of 2.5's swamp lily pads and the HD mod's lily
-- pads and frogs. Whether they can come back depends on WHAT differs between the
-- machines' water when the mods look, and no log so far records the water at all:
--
--   * nothing: the 2-1 difference came from the streams the dev75 anchor sealed;
--   * the same surfaces, listed in another order: a sort brings the pads back;
--   * surfaces that differ at ON.LEVEL and agree a frame or two later: the water is
--     still settling, and waiting for it brings them back;
--   * water that stays different: only the world host's waterline can fix it.
--
-- So in a room every machine fingerprints the liquid and the surface effects: at
-- generation; as ON.LEVEL begins, twice a few ms apart to see whether anything
-- moves while Lua holds the main thread; as the mod's own queries see them; and as
-- the gate engages. inputSync sends the result with the floor digest, and a
-- non-host logs one verdict line per floor against the world host's. Reads only: no
-- PRNG draw, no spawn, no write to any entity.

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
        mod = { queries = 0, hidden = 0, ord = 0, set = 0 },
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

--- The surface effects one of the mod's ON.LEVEL queries was about to be given, in
--- the order the engine gave them. Queries run in the same order on every machine,
--- so the running hashes compare query by query.
--- @param uids integer[]
local function probeModView(uids)
    if probe == nil then
        return
    end
    local keys = positionKeys(uids)
    local mod = probe.mod
    mod.queries = mod.queries + 1
    mod.hidden = mod.hidden + #keys
    mod.ord = (mod.ord * 1000003 + hashKeys(keys)) % PROBE_HASH_MOD
    mod.set = (mod.set * 1000003 + hashSorted(keys)) % PROBE_HASH_MOD
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
        mq = mod.queries, mn = mod.hidden, mo = mod.ord, ms = mod.set,
        en = liquid.n, eh = liquid.set, ef = fx.n, es = fx.set,
    }
    local lines = nil
    if gen.n + lvl.liquid.n + lvl.fx.n + liquid.n + fx.n > 0 then
        lines = {
            string.format("water: generated liquid %d #%08X, surfaces %d | at ON.LEVEL"
                .. " (%+d frames, %+d sim) liquid %d #%08X, surfaces %d ord #%08X set #%08X"
                .. " tiles #%08X, moving %s | the mod asked %d time(s): %d hidden ord #%08X"
                .. " set #%08X | at engage (%+d frames, %+d sim) liquid %d #%08X, surfaces"
                .. " %d set #%08X",
                gen.n, gen.set, probe.genFx,
                lvl.frame - probe.genFrame, lvl.sim - probe.genSim,
                lvl.liquid.n, lvl.liquid.set, lvl.fx.n, lvl.fx.ord, lvl.fx.set, lvl.fx.tiles,
                lvl.moving and "YES" or "no",
                mod.queries, mod.hidden, mod.ord, mod.set,
                frame - probe.genFrame, sim - probe.genSim,
                liquid.n, liquid.set, fx.n, fx.set),
            "water surfaces at ON.LEVEL, as the engine listed them (x,y,layer): "
                .. probeList(lvl.fx.keys),
        }
    end
    return { wire = wire, lines = lines }
end

--- A non-host's verdict for one floor, from its own report and the world host's.
--- nil on a floor with no water on either machine.
--- @param mine table
--- @param host table
--- @param s integer
--- @return string?
function module.waterVerdict(mine, host, s)
    local function probeField(t, k)
        return math.floor(tonumber(t[k]) or -1)
    end
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
    local engage = probeSame("en", "eh", "ef", "es")
    local seenSame, seenSet = fxOrd, fxSet
    if asked then
        seenSame, seenSet = modOrd, modSet
    end
    local verdict
    if seenSame then
        verdict = "MATCH: the mod would have seen the same surfaces on both machines"
    elseif seenSet then
        verdict = "ORDER: the same surfaces, listed in a different order"
    elseif engage then
        verdict = "SETTLING: different when the mod looked, the same by the first frame"
    else
        verdict = "DIFFERENT: the water was still different at the first frame"
    end
    local fxHow = fxOrd and "same order" or (fxSet and "other order"
        or (probeSame("fn", "ft") and "same tiles, moved within them" or "different"))
    return string.format("WATER PROBE seq=%d: %s%s | generated liquid %s | at ON.LEVEL:"
        .. " liquid %s, surfaces %s (%d here, %d on the host: %s) | what the mod saw: %s"
        .. " | at engage: %s | moving during ON.LEVEL: here %s, host %s",
        s, verdict, asked and "" or " (the mod did not ask on this floor)",
        probeWord(probeSame("gn", "gh")), probeWord(probeSame("ln", "lh")), probeWord(fxOrd),
        probeField(mine, "fn"), probeField(host, "fn"), fxHow,
        asked and (modOrd and "MATCH" or (modSet and "same set, other order" or "DIFFER"))
            or "n/a",
        probeWord(engage), probeField(mine, "mv") == 1 and "YES" or "no",
        probeField(host, "mv") == 1 and "YES" or "no")
end

local probeInstalled = false

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
        levelAnchored = 0, waterFxHidden = 0, heldSkips = 0,
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
        return function(...)
            local was = liquidWindow
            liquidWindow = true
            local ok, ret = pcall(cb, ...)
            liquidWindow = was
            if not ok then
                error(ret, 0)
            end
            return ret
        end
    end

    -- ---------------------------------- the water's surface effects at ON.LEVEL
    --
    -- FX_WATER_SURFACE is the engine's drawn waterline, and it is not part of the
    -- generated world. The liquid system creates it after generation -- "somewhere
    -- between ON.POST_LEVEL_GENERATION and ON.LEVEL", as the HD mod's own author
    -- narrowed it down (lib/entities/jungle_deco.lua) -- out of water the worker
    -- threads are already moving. So at ON.LEVEL two machines do not hold the same
    -- set of them, and the snapshot above cannot help: it answers is_liquid_at, and
    -- these are entities.
    --
    -- 2.5's swamp stands its lily pads on exactly these (hooks/swamp/water.lua). It
    -- shuffles every surface effect with the shared PRNG, one draw each, and rolls
    -- again for each well-spaced one. The BGNY capture was that: 2-1 generated
    -- identically, every stream equal at gen[post], and at the first frame the peer
    -- had one more lily pad (ITEM_LEAF 8 against 7). The PROCEDURAL_SPAWNS stream had
    -- moved with it, and that is the stream the Wheel of Fortune then flipped its
    -- coin on: one machine kept the dice house and the other built a Wheel House.
    -- The HD mod's procedural lily pads, and the frogs on them, read the same effects.
    --
    -- So inside a hosted mod's ON.LEVEL callbacks, in a room, there are none. Every
    -- query leaves them out and every machine builds the same floor, without the
    -- decorative pads that would have stood on them. Outside ON.LEVEL, and alone,
    -- the mod sees the engine's own answer.
    local waterFx = nil
    pcall(function() waterFx = ENT_TYPE.FX_WATER_SURFACE end)
    local fxMask = 64 -- MASK.FX
    pcall(function() fxMask = math.floor(MASK.FX) end)
    local waterFxLogged = false -- this floor's first hide has been logged

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

    --- @param list any
    --- @return table kept
    --- @return integer hidden
    --- @return integer[] hiddenUids # in the order the engine listed them
    local function splitWaterFx(list)
        local kept, hidden, hiddenUids = {}, 0, {}
        for i = 1, #list do
            local uid = list[i]
            if entityTypeOf(uid) == waterFx then
                hidden = hidden + 1
                hiddenUids[hidden] = uid
            else
                kept[#kept + 1] = uid
            end
        end
        return kept, hidden, hiddenUids
    end

    --- The query's own answer, without the water surface effects.
    ---
    --- Read by length and index rather than tested for `type(list) == "table"`:
    --- these come back as plain tables (2.5 table.sort()s one), but a build whose
    --- binding handed back an indexable container instead must still be filtered,
    --- not waved through. Anything that cannot be read that way is returned as the
    --- engine gave it.
    --- @param list any
    --- @return any
    local function withoutWaterFx(list)
        if list == nil then
            return list
        end
        local ok, kept, hidden, hiddenUids = pcall(splitWaterFx, list)
        -- The water probe (measurement only): what this query would have given the
        -- mod. Every query counts, an empty one too -- one machine finding a surface
        -- where the other finds none is exactly the difference being looked for.
        if ok and probe ~= nil then
            pcall(probeModView, hiddenUids)
        end
        if not ok or hidden == 0 then
            return list
        end
        stats.waterFxHidden = stats.waterFxHidden + hidden
        if not waterFxLogged then
            -- Once a floor, so a capture shows it was in force. The two machines may
            -- well print DIFFERENT counts here, and that difference is the reason.
            waterFxLogged = true
            local desyncLog = rawget(_G, "DesyncLog")
            if desyncLog ~= nil and desyncLog.event ~= nil then
                pcall(desyncLog.event, "hid %d water-surface effect(s) from the hosted"
                    .. " mod's ON.LEVEL: the liquid makes them after generation, and not"
                    .. " the same on every machine", hidden)
            end
        end
        return kept
    end

    --- Is a query made right now one whose answer must leave them out? The callers
    --- test `liquidWindow` first: these wrap queries 2.5 makes many times a frame,
    --- and outside ON.LEVEL that one upvalue is all they should cost.
    --- @return boolean
    local function hidingWaterFx()
        return liquidWindow and waterFx ~= nil and isActive()
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

    --- Wrap one of the engine's entity queries. `typeAt` and `maskAt` are the
    --- positions of its type and mask arguments. Feature-detected: a build without
    --- the function simply has nothing to wrap.
    --- @param name string
    --- @param typeAt integer
    --- @param maskAt integer
    local function hideWaterFxFrom(name, typeAt, maskAt)
        local real = engineQuery(name)
        if real == nil then
            return
        end
        env[name] = function(...)
            if liquidWindow and hidingWaterFx() then
                local types = (select(typeAt, ...))
                local mask = (select(maskAt, ...))
                if typesMayHoldWaterFx(types) and maskMayHoldFx(mask) then
                    return withoutWaterFx(real(...))
                end
            end
            return real(...)
        end
    end
    hideWaterFxFrom("get_entities_by", 1, 2)
    hideWaterFxFrom("get_entities_at", 1, 2)
    hideWaterFxFrom("get_entities_overlapping_hitbox", 1, 2)
    hideWaterFxFrom("get_entities_overlapping", 1, 2)

    -- get_entities_by_type takes its types as the arguments themselves, or as one
    -- table of them, and has no mask
    local realByType = engineQuery("get_entities_by_type")
    if realByType ~= nil then
        env.get_entities_by_type = function(...)
            if liquidWindow and hidingWaterFx() then
                local first = ...
                local types = type(first) == "table" and first or { ... }
                if typesMayHoldWaterFx(types) then
                    return withoutWaterFx(realByType(...))
                end
            end
            return realByType(...)
        end
    end

    --- ...and whatever a hosted mod DRAWS at ON.LEVEL stays there.
    ---
    --- POST_LEVEL_GENERATION is anchored (below) and ON.LEVEL was not, though it too
    --- fires once per floor at the same state on every machine, and it is where mods
    --- decorate the level they were given. One callback there that reads anything
    --- machine-dependent and rolls on it -- the swamp's lily pads, above -- drew the
    --- shared streams a different number of times on each machine, and every roll
    --- after it, the engine's own included, landed somewhere else. The Wheel of
    --- Fortune's coin was one of them, and it was flipped frames later, in
    --- POST_UPDATE, by a hook that had read nothing machine-dependent at all.
    ---
    --- Anchored, each callback starts from the floor's lockstep-identical base and
    --- the engine's streams are put back afterwards, so whatever one callback draws,
    --- nothing after it can tell. In a room only: alone, the mod's rolls carry on
    --- from the engine's streams exactly as they always did.
    --- @param cb function
    --- @return function
    local function levelAnchored(cb)
        local anchored = module.anchor(cb, floorBase)
        return function(...)
            if not isActive() then
                return cb(...)
            end
            stats.levelAnchored = stats.levelAnchored + 1
            return anchored(...)
        end
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
    --- So on a held frame the mod's update callbacks are not called at all, for the
    --- reason ON.FRAME is moved to ON.GAMEFRAME. Every other frame is untouched,
    --- including the engine's own pauses, which the mod sees and handles itself.
    --- @param cb function
    --- @return function
    local function simulatedOnly(cb)
        return function(...)
            if heldFrame() then
                stats.heldSkips = stats.heldSkips + 1
                return
            end
            return cb(...)
        end
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
        elseif id == ON.LEVEL then
            -- whatever the mod decides at ON.LEVEL from the water, it decides from
            -- the same water on every machine (see liquidSnap and waterFx), and
            -- whatever it draws there stays there (see levelAnchored)
            cb = levelAnchored(liquidWindowed(cb))
        elseif (ON.PRE_UPDATE ~= nil and id == ON.PRE_UPDATE)
            or (ON.POST_UPDATE ~= nil and id == ON.POST_UPDATE) then
            -- once per SIMULATED frame, like ON.FRAME above (see simulatedOnly)
            cb = simulatedOnly(cb)
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
        waterFxLogged = false -- a new floor: say it again the first time it happens
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

    set_callback(onLoading, ON.LOADING)
    set_callback(onFloor, ON.PRE_LEVEL_GENERATION)
    set_callback(onFrame, ON.GAMEFRAME)
    set_callback(clock.invalidate, ON.PRE_LOAD_SCREEN)
    set_callback(snapshotLiquid, ON.POST_LEVEL_GENERATION)

    -- The water probe (measurement only, see above): once, however many mods are
    -- hosted, since it looks at the engine's water and not at any one mod. Here, so
    -- its ON.LEVEL look comes before every callback the mod registers.
    if not probeInstalled then
        probeInstalled = true
        set_callback(function()
            pcall(probeGeneration, isActive)
        end, ON.POST_LEVEL_GENERATION)
        set_callback(function()
            pcall(probeLevel, isActive)
        end, ON.LEVEL)
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

Determinism = module
return module
