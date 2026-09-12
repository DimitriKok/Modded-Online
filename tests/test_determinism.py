"""Tests the determinism core a hosted mod runs under.

This is the whole reason the project exists. A networked run generates its world
locally on every machine from one shared seed and sends only inputs, so if any of
these guarantees slips, two machines play different games from identical data.

Every mechanism here has a real desync behind it, and the tests are written to fail
the way those desyncs failed rather than to restate the implementation:

  * unordered iteration changed how many times the shared PRNG was drawn
  * a wall-clock-derived frame number put mods out of phase on frame one
  * a restart that zeroed `time_total` made every pending deadline either minutes
    away or instantly overdue, depending on which direction the clock jumped
  * a per-hook anchor keyed to hook ORDER broke when a mid-run joiner registered a
    different number of hooks

Run:  python -m pytest tests/test_determinism.py -q
"""

from __future__ import annotations

import collections
import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")

NL = chr(10)

ENGINE = """
timeTotal, seedFirst, worldNo, levelNo, themeNo = 0, 0x1EAF9223, 1, 1, 1
inRun = true
registered = {}
prngPairs = {}
seeded = {}
function get_adventure_seed() return seedFirst, 0xCA8F7F71 end
function get_local_state()
    if not inRun then return nil end
    return {world = worldNo, level = levelNo, theme = themeNo, time_total = timeTotal}
end
function seed_prng(v) seeded[#seeded + 1] = v end
prng = {
    get_pair = function(_, c) return 100 + c, 200 + c end,
    set_pair = function(_, c, a, b) prngPairs[#prngPairs + 1] = {c, a, b} end,
}
ON = {
    FRAME = 1, GAMEFRAME = 2, LOADING = 3, LEVEL = 4,
    PRE_LEVEL_GENERATION = 5, POST_LEVEL_GENERATION = 6,
    PRE_LOAD_LEVEL_FILES = 7, PRE_LOAD_SCREEN = 8,
}
function set_callback(fn, id)
    registered[#registered + 1] = {fn = fn, id = id}
    return #registered
end
function fire(id, ...)
    for _, entry in ipairs(registered) do
        if entry.id == id then entry.fn(...) end
    end
end
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(DETERMINISM)
    return rt


def sandbox(rt, **opts):
    rt.execute("env = setmetatable({}, {__index = _G})")
    lua_opts = rt.table_from(opts) if opts else rt.eval("{}")
    return rt.eval("Determinism.install")(rt.eval("env"), lua_opts)


# ------------------------------------------------------------ ordered iteration

def test_iteration_order_is_the_same_whatever_the_hash_order():
    """Lua seeds string hashing per state, so two machines walk a table differently
    — and order decides how many times the shared PRNG is drawn."""
    a, b = runtime(), runtime()
    keys = ["floor", "jungle", "temple", "ice", "sunken", "eggplant", "olmec"]
    orders = []
    for rt, seq in ((a, keys), (b, list(reversed(keys)))):
        rt.execute("t = {}")
        setter = rt.eval("function(k, v) t[k] = v end")
        for i, k in enumerate(seq):
            setter(k, i)
        got = rt.eval("""
function()
    local out = {}
    for k in Determinism.orderedPairs(t) do out[#out + 1] = k end
    return out
end""")()
        orders.append([str(v) for v in got.values()])
    assert orders[0] == orders[1] == sorted(keys)


def test_a_sequence_iterates_in_index_order_without_sorting():
    rt = runtime()
    rt.execute("t = {'a', 'b', 'c', 'd'}")
    got = rt.eval("""
function()
    local ks, vs = {}, {}
    for k, v in Determinism.orderedPairs(t) do ks[#ks+1] = k; vs[#vs+1] = v end
    return {ks = ks, vs = vs}
end""")()
    assert [int(v) for v in got["ks"].values()] == [1, 2, 3, 4]
    assert [str(v) for v in got["vs"].values()] == ["a", "b", "c", "d"]


def test_mixed_keys_do_not_lose_the_hash_half():
    """The bug this replaced: `next(t, n) == nil` only proves key n is last in hash
    order, and a table holding both t[1] and string keys satisfies that — which
    silently dropped every string key."""
    rt = runtime()
    rt.execute("t = {'one', 'two'}; t.alpha = 'a'; t.beta = 'b'; t[10] = 'ten'")
    n = rt.eval("""
function()
    local c = 0
    for _ in Determinism.orderedPairs(t) do c = c + 1 end
    return c
end""")()
    assert int(n) == 5, f"expected all 5 keys, iterated {int(n)}"


def test_exotic_key_types_still_all_appear():
    rt = runtime()
    rt.execute("""
t = {}
t[1] = 'n'; t['s'] = 's'; t[true] = 'b'; t[false] = 'b2'
t[{}] = 'table'; t[print] = 'function'
""")
    n = rt.eval("""
function()
    local c = 0
    for _ in Determinism.orderedPairs(t) do c = c + 1 end
    return c
end""")()
    assert int(n) == 6, f"exotic key types: {int(n)} (expect 6)"


def test_a_custom_iterator_is_left_alone():
    rt = runtime()
    rt.execute("""
t = setmetatable({}, {__pairs = function(tt) return function() return nil end, tt, nil end})
""")
    n = rt.eval("""
function()
    local c = 0
    for _ in Determinism.orderedPairs(t) do c = c + 1 end
    return c
end""")()
    assert int(n) == 0, "a mod's own __pairs was overridden"


# ------------------------------------------------------ the mod's own generator

def test_the_same_seed_gives_the_same_stream_on_two_machines():
    a, b = runtime(), runtime()
    draws = []
    for rt in (a, b):
        g = rt.eval("Determinism.newGenerator")(20260825)
        draws.append([int(g.random(1, 10 ** 6)) for _ in range(5000)])
    assert draws[0] == draws[1]


def test_different_seeds_diverge():
    rt = runtime()
    one = [int(rt.eval("Determinism.newGenerator")(1).random(1, 10 ** 9)) for _ in range(200)]
    two = [int(rt.eval("Determinism.newGenerator")(2).random(1, 10 ** 9)) for _ in range(200)]
    assert one != two


def test_random_covers_the_whole_unit_interval():
    """It did not, once: masking the state to 63 bits cost the top bit of every
    output and `random()` only ever returned [0, 0.5)."""
    rt = runtime()
    g = rt.eval("Determinism.newGenerator")(7)
    vals = [float(g.random()) for _ in range(40000)]
    assert all(0.0 <= v < 1.0 for v in vals)
    buckets = collections.Counter(int(v * 10) for v in vals)
    assert set(buckets) == set(range(10)), f"empty deciles: {sorted(set(range(10)) - set(buckets))}"
    assert min(buckets.values()) > 3000, dict(sorted(buckets.items()))


def test_the_integer_forms_match_lua_s_contract():
    rt = runtime()
    g = rt.eval("Determinism.newGenerator")(99)
    assert set(int(g.random(6)) for _ in range(4000)) == {1, 2, 3, 4, 5, 6}
    assert set(int(g.random(5, 7)) for _ in range(4000)) == {5, 6, 7}
    assert int(g.random(3, 3)) == 3


def test_an_empty_interval_raises_like_lua_does():
    rt = runtime()
    g = rt.eval("Determinism.newGenerator")(1)
    with pytest.raises(lupa.LuaError):
        g.random(7, 2)


def test_the_mods_generator_cannot_reach_ours():
    """Hosting puts the mod in OUR Lua state. netCore seeds math.random from the wall
    clock to build a client id, so a shared generator would let an unsynced value
    into the mod's stream — and let the mod's reseeds perturb ours."""
    rt = runtime()
    sandbox(rt)
    rt.execute("beforeOurs = {}; for i = 1, 5 do beforeOurs[i] = math.random(1, 10^9) end")
    rt.execute("math.randomseed(4242)")
    ours_before = [int(v) for v in rt.eval("beforeOurs").values()]
    # the mod reseeds hard, repeatedly
    rt.execute("for i = 1, 50 do env.math.randomseed(i * 1000) end")
    rt.execute("math.randomseed(4242)")
    ours_after = [int(rt.eval("math.random")(1, 10 ** 9)) for _ in range(5)]
    rt.execute("math.randomseed(4242)")
    ours_control = [int(rt.eval("math.random")(1, 10 ** 9)) for _ in range(5)]
    assert ours_after == ours_control, "the hosted mod moved our generator"
    # compared IN Lua: lupa hands back a fresh wrapper per eval, so `is not` between
    # two eval calls is vacuously true and tests nothing
    assert rt.eval("env.math ~= math") is True
    assert rt.eval("env.math.random ~= math.random") is True


def test_the_mod_still_gets_the_rest_of_math():
    rt = runtime()
    sandbox(rt)
    assert float(rt.eval("env.math.floor")(3.7)) == 3.0
    assert float(rt.eval("env.math.pi")) == pytest.approx(3.14159, rel=1e-4)


# --------------------------------------------------------------------- the clock

def test_the_clock_follows_simulated_time_not_the_render_loop():
    rt = runtime()
    sandbox(rt)
    rt.execute("timeTotal = 0")
    rt.eval("fire")(rt.eval("ON.GAMEFRAME"))
    first = int(rt.eval("env.get_frame()"))
    # many render frames, no simulated ones: the clock must not move
    for _ in range(50):
        assert int(rt.eval("env.get_frame()")) == first
    rt.execute("timeTotal = 1")
    rt.eval("fire")(rt.eval("ON.GAMEFRAME"))
    assert int(rt.eval("env.get_frame()")) == first + 1


def test_a_restart_carries_the_clock_forward_never_backward():
    """Both directions have been shipped and both broke the HD mod's music: back
    left every deadline minutes away, forward made the whole queue fire at once."""
    rt = runtime()
    sandbox(rt)
    for t in range(1, 400):
        rt.execute(f"timeTotal = {t}")
        rt.eval("fire")(rt.eval("ON.GAMEFRAME"))
    before = int(rt.eval("env.get_frame()"))
    rt.execute("timeTotal = 0")                       # the restart
    rt.eval("fire")(rt.eval("ON.LOADING"))
    after = int(rt.eval("env.get_frame()"))
    assert after > before, f"clock went backwards: {before} -> {after}"


def test_get_ms_tracks_get_frame():
    rt = runtime()
    sandbox(rt)
    rt.execute("timeTotal = 120")
    rt.eval("fire")(rt.eval("ON.GAMEFRAME"))
    assert float(rt.eval("env.get_ms()")) == pytest.approx(
        int(rt.eval("env.get_frame()")) * (1000.0 / 60.0))


def test_outside_a_run_the_clock_still_advances():
    rt = runtime()
    sandbox(rt)
    rt.execute("inRun = false")
    seen = []
    for _ in range(10):
        rt.eval("fire")(rt.eval("ON.GAMEFRAME"))
        seen.append(int(rt.eval("env.get_frame()")))
    assert seen == sorted(seen) and seen[-1] > seen[0]


# ----------------------------------------------------------------- the callbacks

def test_render_rate_callbacks_are_moved_to_the_simulated_rate():
    rt = runtime()
    sandbox(rt)
    rt.execute("env.set_callback(function() end, ON.FRAME)")
    ids = [int(e["id"]) for e in rt.eval("registered").values()]
    assert int(rt.eval("ON.FRAME")) not in ids
    assert ids.count(int(rt.eval("ON.GAMEFRAME"))) >= 1


def test_post_generation_hooks_are_anchored_to_the_floor_not_to_hook_order():
    """v7 keyed the anchor to a run-ORDER index, which broke whenever the machines
    registered a different NUMBER of hooks — a mid-run joiner does exactly that."""
    rt = runtime()
    sandbox(rt)
    rt.execute("""
seedsSeen = {}
for i = 1, 4 do
    env.set_callback(function() seedsSeen[#seedsSeen + 1] = seeded[#seeded] end,
                     ON.POST_LEVEL_GENERATION)
end
""")
    rt.eval("fire")(rt.eval("ON.POST_LEVEL_GENERATION"))
    seeds = [int(v) for v in rt.eval("seedsSeen").values()]
    assert len(seeds) == 4
    assert len(set(seeds)) == 1, f"hooks got different bases: {seeds}"


def test_the_anchor_puts_every_prng_stream_back():
    """Leaving the streams reseeded leaked our value into everything the mod did for
    the rest of the floor — and a mod that owns its own generation draws from them."""
    rt = runtime()
    sandbox(rt)
    rt.execute("env.set_callback(function() end, ON.POST_LEVEL_GENERATION)")
    rt.eval("fire")(rt.eval("ON.POST_LEVEL_GENERATION"))
    restored = [(int(p[1]), int(p[2]), int(p[3])) for p in rt.eval("prngPairs").values()]
    assert [c for c, _, _ in restored] == list(range(10)), "not every stream restored"
    assert all(a == 100 + c and b == 200 + c for c, a, b in restored)


def test_loading_is_always_anchored():
    """v11 did not anchor here and a layer-door press booked a travel that never
    fired; v14 did, and is the build 2.5 demonstrably worked under."""
    rt = runtime()
    sandbox(rt)
    rt.execute("sawSeed = nil; env.set_callback(function() sawSeed = seeded[#seeded] end, ON.LOADING)")
    rt.eval("fire")(rt.eval("ON.LOADING"))
    assert rt.eval("sawSeed") is not None


def test_pre_generation_is_not_anchored_for_a_mod_without_a_run_plan():
    rt = runtime()
    sandbox(rt)
    rt.execute("""
sawSeed = nil
env.set_callback(function() sawSeed = #seeded end, ON.PRE_LEVEL_GENERATION)
""")
    rt.execute("seeded = {}")
    rt.eval("fire")(rt.eval("ON.PRE_LEVEL_GENERATION"))
    assert int(rt.eval("sawSeed")) == 0, "anchored a mod that does not need it"


# -------------------------------------------------------------------- adapters

def test_a_run_plan_mod_is_recognised_and_cleared_on_a_new_run():
    """Only the machine whose player pressed restart sees QUEST_FLAG.RESET; peers are
    warped, so they kept the DEAD run's plan and regenerated the floor they had just
    restarted away from."""
    rt = runtime()
    control = sandbox(rt)
    rt.execute("env.level_order = {'dwelling', 'jungle', 'temple'}")
    names = [str(a["name"]) for a in control.detectAdapters().values()]
    assert "run-plan" in names
    rt.eval("fire")(rt.eval("ON.LOADING"))          # establishes the baseline seed
    rt.execute("seedFirst = 0x5EED0001")            # a new run
    rt.eval("fire")(rt.eval("ON.LOADING"))
    assert int(rt.eval("#env.level_order")) == 0, "the dead run's plan survived"


def test_the_hd_mods_flag_is_recognised_and_cleared():
    rt = runtime()
    control = sandbox(rt)
    rt.execute("env.POSTTILE_STARTBOOL = true")
    names = [str(a["name"]) for a in control.detectAdapters().values()]
    assert "posttile-start" in names
    rt.eval("fire")(rt.eval("ON.LOADING"))
    rt.execute("seedFirst = 0x5EED0002")
    rt.eval("fire")(rt.eval("ON.LOADING"))
    assert rt.eval("env.POSTTILE_STARTBOOL") is False


def test_a_mod_matching_no_adapter_still_gets_the_whole_core():
    """The point of the rewrite: the injected payload tested for specific mods
    inline, so a mod nobody had written an `if` for got nothing."""
    rt = runtime()
    control = sandbox(rt)
    assert len(control.detectAdapters()) == 0
    assert rt.eval("env.pairs == Determinism.orderedPairs") is True
    assert rt.eval("env.math.random ~= math.random") is True
    rt.execute("timeTotal = 5")
    rt.eval("fire")(rt.eval("ON.GAMEFRAME"))
    assert int(rt.eval("env.get_frame()")) > 0


def test_ordered_pairs_can_be_switched_off_for_a_mod_that_cannot_afford_it():
    rt = runtime()
    sandbox(rt, orderedPairs=False)
    # nothing written into the sandbox, so the mod reads the stock `pairs` through
    # the environment's fallthrough
    assert rt.eval('rawget(env, "pairs") == nil') is True
    assert rt.eval("env.pairs == pairs") is True


def test_a_new_run_is_detected_from_the_seed_not_the_reset_flag():
    rt = runtime()
    control = sandbox(rt)
    rt.eval("fire")(rt.eval("ON.LOADING"))
    assert int(control.stats()["newRuns"]) == 0, "first sighting is not a new run"
    rt.eval("fire")(rt.eval("ON.LOADING"))
    assert int(control.stats()["newRuns"]) == 0, "same seed is not a new run"
    rt.execute("seedFirst = 0xFEEDFACE")
    rt.eval("fire")(rt.eval("ON.LOADING"))
    assert int(control.stats()["newRuns"]) == 1


def test_the_generator_is_reseeded_every_floor_and_every_frame():
    rt = runtime()
    control = sandbox(rt)
    before = int(control.stats()["reseeds"])
    rt.eval("fire")(rt.eval("ON.PRE_LEVEL_GENERATION"))
    assert int(control.stats()["reseeds"]) == before + 1
    # and two machines on the same floor agree, whatever they drew before
    a, b = runtime(), runtime()
    draws = []
    for rt2, junk in ((a, 0), (b, 500)):
        sandbox(rt2)
        g = rt2.eval("env.math")
        for _ in range(junk):
            g.random()
        rt2.eval("fire")(rt2.eval("ON.PRE_LEVEL_GENERATION"))
        draws.append([int(g.random(1, 10 ** 6)) for _ in range(50)])
    assert draws[0] == draws[1], "a floor's stream depended on earlier gameplay draws"

def test_the_mods_generator_is_not_reseeded_outside_a_run():
    """Determinism is for agreeing with another machine. Outside a room there is no
    other machine, and forcing it there is a bug the player sees: seeding the mod's
    math.random from the floor base on every floor gave every single 1-1 the same
    level feeling, run after run, in ordinary single-player. Hosting a mod must not
    change how it plays alone."""
    rt = runtime()
    rt.execute("""
env = {}
live = false
report = Determinism.install(env, { active = function() return live end })
local function fireFloor() fire(ON.PRE_LEVEL_GENERATION) end
fireFloor(); fireFloor(); fireFloor()
soloReseeds = report.stats().reseeds
live = true
fireFloor(); fireFloor()
roomReseeds = report.stats().reseeds
""")
    assert int(rt.eval("soloReseeds")) == 0, "solo play was reseeded -- every floor comes out feeling identical"
    assert int(rt.eval("roomReseeds")) == 2, "in a room the floor anchor must still reseed"
