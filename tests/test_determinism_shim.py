"""Tests for the v20 determinism shim's per-mod switches.

Two switches used to be one. `moRunPlan` turned on ordered `pairs` AND the prng
anchors together, and the anchors are what broke Spelunky 2.5's 1-4 — so the
whole package stayed off for every mod without a `level_order` global. The HD mod
is one of those and it builds its levels in Lua, which is the exact case that
needs deterministic iteration: Lua seeds its string hash per process, so `pairs`
over string keys walks a different order on every machine.

These lock down that the switches are now independent and that each mod class
gets what it should:

  * a run-plan mod (Randomizer)  -> ordered pairs + anchors   (unchanged)
  * a level-generating mod (HD)  -> ordered pairs only        (new)
  * neither (Spelunky 2.5)       -> neither                   (unchanged)

Run:  python -m pytest tests/test_determinism_shim.py -q
"""

from __future__ import annotations

import re
import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
SHIM_SRC = (PACK / "src" / "shimInjector.lua").read_text(encoding="utf-8")


def payload(var: str, marker: str) -> str:
    m = re.search(
        r'local %s = "-- " \.\. %s \.\. \[\[(.*?)\n\]\]\n' % (var, marker), SHIM_SRC, re.S
    )
    assert m, "%s payload not found" % var
    return "-- shim" + m.group(1)


ENV = """
ON = {
    FRAME = 1, GAMEFRAME = 2, LOADING = 3, POST_LEVEL_GENERATION = 4,
    PRE_LEVEL_GENERATION = 5, PRE_LOAD_LEVEL_FILES = 6, SAVE = 7, GUIFRAME = 8,
    PRE_LOAD_SCREEN = 9,
}
callbacks = {}
function set_callback(cb, id)
    callbacks[id] = callbacks[id] or {}
    table.insert(callbacks[id], cb)
    return #callbacks[id]
end
function fire(id, ...) for _, cb in ipairs(callbacks[id] or {}) do cb(...) end end

adventure_seed = 1000
function get_adventure_seed() return adventure_seed, 55 end
function get_local_state()
    return { world = 1, level = 1, theme = 1, time_total = 10 }
end
seeded = 0
function seed_prng() seeded = seeded + 1 end
prng = { get_pair = function(_, _) return 1, 2 end, set_pair = function() end }
function get_frame() return 3 end
function get_ms() return 50 end
raw_pairs = pairs
function ordered_pairs_installed() return pairs ~= raw_pairs end
"""


def state(mod_globals: str = ""):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(ENV)
    lua.execute(payload("SHIM", "MARKER"))
    lua.execute(mod_globals)  # the content mod's own chunk
    return lua


HD_MOD = "POSTTILE_STARTBOOL = false"
RUN_PLAN_MOD = "level_order = { { t = 1 } }"
PLAIN_MOD = "some_other_global = 1"


def anchored(lua) -> bool:
    """Did a PRE_LEVEL_GENERATION callback get wrapped in the prng anchor?
    The anchor calls seed_prng around the body; an unwrapped one does not."""
    lua.execute("""
        seeded = 0
        set_callback(function() end, ON.PRE_LEVEL_GENERATION)
        fire(ON.PRE_LEVEL_GENERATION)
    """)
    return lua.eval("seeded") > 0


def test_level_generating_mod_gets_ordered_pairs_but_not_the_anchors():
    lua = state(HD_MOD)
    assert lua.eval("ordered_pairs_installed()") is False
    lua.execute("fire(ON.LOADING)")
    assert lua.eval("ordered_pairs_installed()") is True
    assert anchored(lua) is False


def test_run_plan_mod_still_gets_both():
    lua = state(RUN_PLAN_MOD)
    lua.execute("fire(ON.LOADING)")
    assert lua.eval("ordered_pairs_installed()") is True
    assert anchored(lua) is True


def test_a_mod_with_neither_global_is_left_alone():
    """Spelunky 2.5's case: it played correctly under exactly this behaviour."""
    lua = state(PLAIN_MOD)
    lua.execute("fire(ON.LOADING); fire(ON.LOADING)")
    assert lua.eval("ordered_pairs_installed()") is False
    assert anchored(lua) is False


def test_ordered_pairs_agrees_across_string_hash_orders():
    """The property the whole switch exists for: iteration order of a string-keyed
    table must not depend on which order the host VM happens to walk it in."""
    lua = state(HD_MOD)
    lua.execute("fire(ON.LOADING)")
    lua.execute("""
        local t = { zebra = 1, apple = 2, mango = 3, kiwi = 4, cherry = 5 }
        seen = {}
        for k in pairs(t) do seen[#seen + 1] = k end
    """)
    seen = lua.eval("seen")
    assert [seen[i] for i in range(1, len(seen) + 1)] == [
        "apple", "cherry", "kiwi", "mango", "zebra"
    ]


def test_sequences_keep_their_natural_order():
    lua = state(HD_MOD)
    lua.execute("fire(ON.LOADING)")
    lua.execute("""
        local t = { "a", "b", "c", "d" }
        seen = {}
        for _, v in pairs(t) do seen[#seen + 1] = v end
    """)
    seen = lua.eval("seen")
    assert [seen[i] for i in range(1, len(seen) + 1)] == ["a", "b", "c", "d"]


def test_new_run_clears_the_hd_mods_run_plan():
    """A peer warped by our ordered run_start never receives ON.RESET, so the HD
    mod would otherwise carry the dead run's feelings into the new one."""
    lua = state(HD_MOD)
    lua.execute("POSTTILE_STARTBOOL = true; fire(ON.LOADING)")
    assert lua.eval("POSTTILE_STARTBOOL") is True  # same run: left alone
    lua.execute("adventure_seed = 2000; fire(ON.LOADING)")
    assert lua.eval("POSTTILE_STARTBOOL") is False  # new run: rebuilt


def test_new_run_still_clears_a_run_plan_mods_level_order():
    lua = state(RUN_PLAN_MOD)
    lua.execute("fire(ON.LOADING)")
    assert lua.eval("#level_order") == 1
    lua.execute("adventure_seed = 2000; fire(ON.LOADING)")
    assert lua.eval("#level_order") == 0


def test_a_mod_without_the_globals_is_not_given_them():
    lua = state(PLAIN_MOD)
    lua.execute("adventure_seed = 2000; fire(ON.LOADING); adventure_seed = 3000; fire(ON.LOADING)")
    assert lua.eval("POSTTILE_STARTBOOL") is None
    assert lua.eval("level_order") is None


def current_marker_version() -> int:
    m = re.search(r'local MARKER = "\[ModdedOnline-DeterminismShim-v(\d+)\]"', SHIM_SRC)
    assert m, "current MARKER not found"
    return int(m.group(1))


def test_archived_payloads_are_kept_verbatim_for_stripping():
    """injectInto removes old payloads by EXACT TEXT, so every past payload has to be
    archived byte-for-byte or an upgrade leaves two stacked blocks in a mod's
    main.lua.

    Written against whatever the CURRENT marker is, rather than naming this
    release's version: pinning the version here meant the test had to be edited on
    every shim bump, and it twice failed for that reason alone rather than for a
    real fault.
    """
    current = current_marker_version()

    # every version below the current one is archived and findable. v1 predates the
    # `"-- " .. MARKER` prefix every later payload carries, so it is checked for
    # existence only rather than parsed the same way.
    assert re.search(r"local SHIM_V1 = \[\[", SHIM_SRC), "the v1 archive is missing"
    archived = {}
    for v in range(2, current):
        archived[v] = payload("SHIM_V%d" % v, "MARKER_V%d" % v)
    live = payload("SHIM", "MARKER")

    # Deliberately NOT asserting that each release is larger than the last. It is
    # not true and never was: v8 is smaller than v7 because it REPLACED v7's
    # run-order index (which the block itself records as having silently broken)
    # with a shorter per-floor base. What matters for stripping is that every
    # payload is present, distinct and substantial -- not that it grew.
    for v, text in archived.items():
        assert len(text) > 200, "the v%d archive looks truncated (%d bytes)" % (v, len(text))
    assert len(set(archived.values())) == len(archived), "two archives are identical"
    assert live not in archived.values(), "the live payload duplicates an archive"
    assert len(live) > 200, "the live payload looks truncated"


def test_each_shim_version_is_pinned_by_the_feature_it_introduced():
    """Guards against an archive being silently swapped for a different build."""
    v19 = payload("SHIM_V19", "MARKER_V19")
    v20 = payload("SHIM_V20", "MARKER_V20")
    v21 = payload("SHIM_V21", "MARKER_V21")
    v22 = payload("SHIM_V22", "MARKER_V22")
    live = payload("SHIM", "MARKER")

    # v20: the run-plan reset and the separate ordered-iteration switch
    assert "POSTTILE_STARTBOOL" not in v19 and "moOrderedIter" not in v19
    assert "POSTTILE_STARTBOOL" in v20 and "moOrderedIter" in v20
    # v21: deterministic liquid for the ON.LEVEL pass
    assert "moLiquidSnap" not in v20
    assert "moLiquidSnap" in v21 and "moSnapshotLiquid" in v21
    # v22: the read-only handle on a content mod's own world state
    assert "moContentWorldState" not in v21
    assert "moContentWorldState" in v22
    # v23: discovery by shape rather than by a hard-coded module key, and a loud miss
    v23 = payload("SHIM_V23", "MARKER_V23")
    assert "moFindContentWorld" not in v22
    assert "moFindContentWorld" in v23 and "moReportWorldSearch" in v23
    # v24: capture via the global class, because Playlunky provides no package table
    v24 = payload("SHIM_V24", "MARKER_V24")
    assert "moHookWorldCapture" not in v23
    assert "moHookWorldCapture" in v24 and "Sp25GameClass" in v24
    assert "package.loaded" not in v24, "v24 must not rely on a registry that does not exist"
    # v25: act on the capture, through 2.5's own reset, on the shared new-run signal
    v25 = payload("SHIM_V25", "MARKER_V25")
    assert "moResetContentWorld" not in v24
    assert "moResetContentWorld" in v25 and "resetGame" in v25
    # v26: v24 and v25 both registered the capture above its own declaration, so
    # Playlunky was handed nil. Fixed by registering below it -- see test_shim_boot.
    for broken in (v24, v25):
        i = broken.index("moRealSetCallback(moHookWorldCapture,")
        assert i < broken.index("local function moHookWorldCapture")
    v26 = payload("SHIM_V26", "MARKER_V26")
    i = v26.index("moRealSetCallback(moHookWorldCapture,")
    assert i > v26.index("local function moHookWorldCapture")
    assert "moResetContentWorld" in v26
    # v27: receive a world from the machine that took the door (see test_world_mailbox)
    v27 = payload("SHIM_V27", "MARKER_V27")
    assert "moSyncWorldMailbox" not in v26
    assert "moSyncWorldMailbox" in v27 and "MO_BOX_REQ" in v27
    # v28: same values, fewer allocations -- the clock is memoized per simulated
    # frame and the per-frame/per-hook closures are gone (see test_shim_clock)
    assert "moClockInvalidate" not in v27
    assert "moClockInvalidate" in live and "moFrameTick" in live
    assert "pcall(function() return prng:get_pair(c) end)" in v27
    assert "pcall(prng.get_pair, prng, c)" in live
    assert "pcall(function()" not in live[live.index("local function moSavePrng"):
                                          live.index("local function moAnchorPrngIfRunPlan")]
    i = live.index("moRealSetCallback(moHookWorldCapture,")
    assert i > live.index("local function moHookWorldCapture")


# ------------------------------------------- deterministic liquid (v21)

LIQUID_ENV = """
ON.LEVEL = 14
-- A pool of water. `wobble` is the tile that the engine's multithreaded liquid
-- simulation disagrees about between two machines two frames into a level.
wobble = false
function is_liquid_at(x, y)
    if x == 5 and y == 3 then return wobble end
    return x >= 2 and x <= 8 and y <= 2
end
function get_bounds() return 0, 6, 10, 0 end
"""

# The HD mod's jungle-deco pass, reduced to the construction that matters: a
# liquid test short-circuiting a prng draw, once per tile.
DECO_MOD = """
draws = 0
spawned = {}
prng = { random_chance = function(_, _, _) draws = draws + 1; return draws % 3 == 0 end }
set_callback(function()
    for y = 0, 6 do
        for x = 0, 10 do
            if is_liquid_at(x, y) and prng:random_chance(prng, 7, 1) then
                spawned[#spawned + 1] = x .. "," .. y
            end
        end
    end
end, ON.LEVEL)
"""


def liquid_state(wobble: bool, mod_globals: str = HD_MOD):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(ENV)
    lua.execute(LIQUID_ENV)
    lua.execute(payload("SHIM", "MARKER"))
    lua.execute(mod_globals)
    lua.execute(DECO_MOD)
    lua.execute("fire(ON.LOADING)")  # switches the mod class on
    # POST_LEVEL_GENERATION: zero physics updates have run, so both machines
    # agree here — this is what makes the snapshot a shared reference.
    lua.execute("wobble = false")
    lua.execute("fire(ON.POST_LEVEL_GENERATION)")
    # ON.LEVEL: two frames of multithreaded liquid later, they no longer do.
    lua.execute("wobble = %s" % ("true" if wobble else "false"))
    lua.execute("fire(ON.LEVEL)")
    return lua


def outcome(lua):
    s = lua.eval("spawned")
    return lua.eval("draws"), [s[i] for i in range(1, len(s) + 1)]


def test_one_wobbling_tile_no_longer_changes_the_whole_floor():
    """Two machines that disagree about a single waterline tile must still draw
    the same number of times and spawn the same things."""
    a = outcome(liquid_state(wobble=False))
    b = outcome(liquid_state(wobble=True))
    assert a == b, "%r != %r" % (a, b)
    assert a[0] > 0 and len(a[1]) > 0, "the test itself must actually spawn things"


def test_without_the_snapshot_that_tile_desyncs_everything():
    """The failure this fixes: with the engine's live answer, one tile shifts the
    draw count and every later decision on the floor lands elsewhere."""
    lua_a, lua_b = liquid_state(wobble=False), liquid_state(wobble=True)
    for lua in (lua_a, lua_b):
        # take the snapshot away to model pre-v21 behaviour
        lua.execute("draws = 0; spawned = {}")
    lua_a.execute("wobble = false; is_liquid_at_orig = is_liquid_at")
    # drive the mod's pass directly against the live function, bypassing our window
    for lua, wob in ((lua_a, "false"), (lua_b, "true")):
        lua.execute("""
            wobble = %s
            draws = 0; spawned = {}
            for y = 0, 6 do
                for x = 0, 10 do
                    if (x == 5 and y == 3 and wobble) or (x >= 2 and x <= 8 and y <= 2) then
                        if prng:random_chance(prng, 7, 1) then spawned[#spawned + 1] = x .. "," .. y end
                    end
                end
            end
        """ % wob)
    assert outcome(lua_a) != outcome(lua_b), "the scenario must diverge without the fix"


def test_gameplay_liquid_checks_are_untouched():
    """Only ON.LEVEL sees the snapshot; everything else gets the engine's answer."""
    lua = liquid_state(wobble=True)
    lua.execute("wobble = true")
    assert lua.eval("is_liquid_at(5, 3)") is True
    lua.execute("wobble = false")
    assert lua.eval("is_liquid_at(5, 3)") is False


def test_a_mod_that_does_not_generate_levels_is_untouched():
    """Spelunky 2.5's case: no snapshot, always the engine's live answer."""
    lua = liquid_state(wobble=True, mod_globals=PLAIN_MOD)
    lua.execute("wobble = true; inside = nil")
    lua.execute("set_callback(function() inside = is_liquid_at(5, 3) end, ON.LEVEL); fire(ON.LEVEL)")
    assert lua.eval("inside") is True
    lua.execute("wobble = false; fire(ON.LEVEL)")
    assert lua.eval("inside") is False


def test_a_dry_level_keeps_the_engines_answer():
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(ENV)
    lua.execute(LIQUID_ENV)
    lua.execute("function is_liquid_at() return false end")  # nothing wet anywhere
    lua.execute(payload("SHIM", "MARKER"))
    lua.execute(HD_MOD)
    lua.execute("fire(ON.LOADING); fire(ON.POST_LEVEL_GENERATION)")
    lua.execute("""
        wet = nil
        function is_liquid_at_real() return true end
        set_callback(function() wet = is_liquid_at(1, 1) end, ON.LEVEL)
        fire(ON.LEVEL)
    """)
    assert lua.eval("wet") is False  # fell through, no snapshot taken
