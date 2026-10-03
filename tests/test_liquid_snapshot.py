"""A hosted mod's ON.LEVEL pass reads the floor's GENERATED water, on every machine.

Spelunky 2 simulates liquid across worker threads, so two machines two frames into
a level do not agree on the exact tiles at a waterline. hdmod decides its lily pads,
the frogs on them, kelp and anchovy flocks from that water at ON.LEVEL, and only
rolls the shared PRNG when the water test passes -- so one tile of disagreement
changes how many times it is drawn, and everything after it lands elsewhere.

The injected shim answered `is_liquid_at` from a POST_LEVEL_GENERATION snapshot
during ON.LEVEL since v21; hosting the mod instead of injecting into it left that
behind. The capture (room BITO, 2-4): every PRNG stream identical at gen[pre] and
gen[post], then one extra frog on one extra lily pad on the peer at the first frame
(+1 MONS_CRITTERCRAB, +1 ITEM_LEAF), the party split by 15:720, and every floor
after it differed.

Run:  python -m pytest tests/test_liquid_snapshot.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")

ENGINE = """
timeTotal, seedFirst, worldNo, levelNo, themeNo = 0, 0x1EAF9223, 2, 4, 2
registered = {}
function get_adventure_seed() return seedFirst, 0xCA8F7F71 end
function get_local_state()
    return {world = worldNo, level = levelNo, theme = themeNo, time_total = timeTotal}
end
function seed_prng() end
prng = { get_pair = function(_, c) return c, c end, set_pair = function() end }
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
-- the engine's water, which the worker threads keep changing
water = {}
liveCalls = 0
function is_liquid_at(x, y)
    liveCalls = liveCalls + 1
    return water[x * 4096 + y] == true
end
function get_bounds() return 0.5, 20.5, 10.5, 0.5 end
function wet(x, y) water[x * 4096 + y] = true end
function dry(x, y) water[x * 4096 + y] = nil end
"""


def machine(own_levels=True, active=True):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(DETERMINISM)
    rt.execute("env = setmetatable({}, {__index = _G})")
    rt.execute(f"activeFlag = {'true' if active else 'false'}")
    control = rt.eval("Determinism.install")(
        rt.eval("env"), rt.eval("{ active = function() return activeFlag end }"))
    if own_levels:
        rt.execute("env.POSTTILE_STARTBOOL = false")  # the HD mod's own global
    control["detectAdapters"]()
    # A shoreline: a pool at y = 3..5, x = 2..6, its surface at y = 5.
    rt.execute("for x = 2, 6 do for y = 3, 5 do wet(x, y) end end")
    # The mod's ON.LEVEL pass, in hdmod's shape (lib/entities/jungle_deco.lua):
    # roll only where the open water surface is.
    rt.execute("""
        rolls, spawned = 0, {}
        env.set_callback(function()
            for y = 1, 8 do
                for x = 1, 8 do
                    local surface = env.is_liquid_at(x, y) and not env.is_liquid_at(x, y + 1)
                    if surface then
                        rolls = rolls + 1
                        spawned[#spawned + 1] = x .. ',' .. y
                    end
                end
            end
        end, ON.LEVEL)
    """)
    return rt, control


def generate_then_settle(rt, settle_lua):
    rt.execute("fire(ON.POST_LEVEL_GENERATION)")  # the snapshot
    rt.execute(settle_lua)                       # the threads move the water
    rt.execute("fire(ON.LEVEL)")


def test_two_machines_whose_water_settled_differently_roll_the_same():
    a, _ = machine()
    b, _ = machine()
    generate_then_settle(a, "dry(6, 5)")                 # one tile drained here...
    generate_then_settle(b, "wet(7, 5); wet(7, 4)")      # ...and spread there
    assert int(a.eval("rolls")) == int(b.eval("rolls")) == 5
    assert list(a.eval("spawned").values()) == list(b.eval("spawned").values())


def test_without_the_snapshot_they_would_not():
    """The premise: answering from the live water forks the roll count."""
    a, _ = machine(own_levels=False)
    b, _ = machine(own_levels=False)
    generate_then_settle(a, "dry(6, 5)")
    generate_then_settle(b, "wet(7, 5); wet(7, 4)")
    assert int(a.eval("rolls")) != int(b.eval("rolls"))


def test_gameplay_outside_on_level_still_sees_the_real_water():
    rt, _ = machine()
    generate_then_settle(rt, "dry(6, 5); wet(9, 9)")
    assert rt.eval("env.is_liquid_at(9, 9)") is True, "the live water, not the snapshot"
    assert rt.eval("env.is_liquid_at(6, 5)") is False


def test_alone_the_mod_gets_the_engines_own_answer():
    """Determinism is for agreeing with another machine; solo play is untouched."""
    rt, _ = machine(active=False)
    generate_then_settle(rt, "dry(6, 5); dry(6, 4); dry(6, 3)")  # a column drained
    assert int(rt.eval("rolls")) == 4


def test_a_mod_that_does_not_build_its_own_levels_is_left_alone():
    rt, _ = machine(own_levels=False)
    generate_then_settle(rt, "dry(6, 5); dry(6, 4); dry(6, 3)")  # a column drained
    assert int(rt.eval("rolls")) == 4


def test_a_dry_floor_keeps_the_engines_answer():
    """A mod that adds water after generation must not be told the level is dry."""
    rt, control = machine()
    rt.execute("water = {}")
    generate_then_settle(rt, "wet(3, 3)")
    assert int(rt.eval("rolls")) == 1
    assert int(control["stats"]()["liquidTiles"]) == 0


def test_the_window_closes_even_when_the_mods_callback_throws():
    rt, _ = machine()
    rt.execute("""
        env.set_callback(function() error('boom') end, ON.LEVEL)
    """)
    rt.execute("fire(ON.POST_LEVEL_GENERATION)")
    rt.execute("dry(6, 5)")
    with pytest.raises(lupa.LuaError, match="boom"):
        rt.execute("fire(ON.LEVEL)")
    assert rt.eval("env.is_liquid_at(6, 5)") is False, "the snapshot leaked into gameplay"


def test_each_floor_gets_its_own_snapshot():
    rt, control = machine()
    rt.execute("fire(ON.POST_LEVEL_GENERATION)")
    assert int(control["stats"]()["liquidTiles"]) == 15
    rt.execute("water = {}; wet(1, 1)")
    rt.execute("fire(ON.POST_LEVEL_GENERATION)")
    assert int(control["stats"]()["liquidTiles"]) == 1


def test_the_hd_mod_is_one_of_the_mods_it_applies_to():
    """The posttile-start adapter names the HD mod by its own global."""
    det = DETERMINISM
    assert 'adapter.name == "run-plan" or adapter.name == "posttile-start"' in det
    assert "set_callback(snapshotLiquid, ON.POST_LEVEL_GENERATION)" in det
