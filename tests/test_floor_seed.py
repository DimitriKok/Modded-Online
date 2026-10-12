"""A peer builds each floor from the world host's seed, whenever that seed arrives.

The world host publishes the adventure seed its floor was generated from, captured at
its PRE_LEVEL_GENERATION. The engine takes the floor's step during the load, between
PRE_LOAD_SCREEN and PRE_LEVEL_GENERATION: second += first (Overlunky's
get_adventure_seed undoes exactly that to find a run's first seed). Room MGVG's peer
got the host's 1-2 seed before it began loading -- a 168 ms transition hold put it
seven frames behind -- set it as-is at PRE_LOAD_SCREEN, and the engine stepped it once
more: every engine stream different at generation, a different 1-2, a POSITION
DESYNC. In every earlier capture the seed came too late, the peer used its own, and
every floor matched.

The engine here is the step and nothing else, which is all a seed has to agree on.

Run:  python -m pytest tests/test_floor_seed.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")


def extract(start: str) -> str:
    i = EVENT_SYNC.index(start)
    return EVENT_SYNC[i:EVENT_SYNC.index("\nend\n", i) + len("\nend\n")]


ENV = """
pendingRunSeed, hostSeeds, levelOrdinal, amHost = nil, {}, 0, false
Network = { isWorldHost = function() return amHost end }
lines, sets = {}, 0
DesyncLog = { event = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end }
engine = { first = 0, second = 0 }
function get_adventure_seed() return engine.first, engine.second end
function set_adventure_seed(a, b) engine.first, engine.second = a, b; sets = sets + 1 end
--- One floor's load: PRE_LOAD_SCREEN, the engine's step, PRE_LEVEL_GENERATION. Returns
--- the seed the engine stepped to, which is what the floor is built from.
function loadFloor()
    enforceLevelSeed(true)
    engine.second = engine.second + engine.first
    local builtFrom = engine.second
    enforceLevelSeed()
    return builtFrom
end
"""

FIRST = 0x00000000D29E34C0      # room MGVG's run constant (its low 32 bits)
AFTER_1_1 = 0x000000009E2D6480  # what 1-1 left: 1-2's load steps from here


def machine(host: bool):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    # a local of the file: handed out as a global from the same chunk
    rt.execute(extract("local function enforceLevelSeed(beforeLoad)")
               + "_G.enforceLevelSeed = enforceLevelSeed\n")
    rt.execute(f"amHost = {str(host).lower()}")
    rt.execute(f"engine.first, engine.second = {FIRST}, {AFTER_1_1}; levelOrdinal = 1")
    return rt


def host_floor():
    host = machine(True)
    built = host.eval("loadFloor()")
    return int(host.eval("engine.first")), int(built)


def lines(rt):
    return [str(v) for v in rt.eval("lines").values()]


def test_the_step_is_what_mgvg_shows():
    _, built = host_floor()
    assert built & 0xFFFFFFFF == 0x70CB9940  # 1-2's second, in both MGVG logs


def test_a_seed_that_arrives_before_the_load_builds_the_hosts_floor():
    """MGVG's 1-2: the old code built it from one step too far."""
    first, seed = host_floor()
    peer = machine(False)
    peer.eval("function(a, b) hostSeeds[1] = { a, b } end")(first, seed)
    assert int(peer.eval("loadFloor()")) == seed
    assert int(peer.eval("sets")) == 0, "a seed already in step was set"
    assert lines(peer) == []


def test_a_seed_that_arrives_too_late_changes_nothing():
    """Every floor before MGVG: the peer's own seed, which is the host's."""
    _, seed = host_floor()
    peer = machine(False)
    assert int(peer.eval("loadFloor()")) == seed
    assert int(peer.eval("sets")) == 0
    assert lines(peer) == ["no host seed yet for ordinal 1 -> using our own evolved seed"] * 2


def test_a_seed_that_arrives_during_the_load_changes_nothing():
    first, seed = host_floor()
    peer = machine(False)
    peer.execute("enforceLevelSeed(true); engine.second = engine.second + engine.first")
    peer.eval("function(a, b) hostSeeds[1] = { a, b } end")(first, seed)
    peer.execute("enforceLevelSeed()")
    assert int(peer.eval("engine.second")) == seed and int(peer.eval("sets")) == 0


def test_a_peer_out_of_step_is_put_back_before_the_load():
    first, seed = host_floor()
    peer = machine(False)
    peer.execute("engine.second = engine.second + 12345")  # drifted, somehow
    peer.eval("function(a, b) hostSeeds[1] = { a, b } end")(first, seed)
    assert int(peer.eval("loadFloor()")) == seed
    assert int(peer.eval("sets")) == 1
    said = lines(peer)
    assert len(said) == 1 and said[0].startswith("levelseed ord=1 before the load: ours was D29E34C0-")
    assert said[0].endswith("so this floor is the host's D29E34C0-70CB9940")


def test_a_peer_out_of_step_found_at_generation_is_put_right_for_the_next_floor():
    first, seed = host_floor()
    peer = machine(False)
    peer.execute("enforceLevelSeed(true); engine.second = engine.second + engine.first + 7")
    peer.eval("function(a, b) hostSeeds[1] = { a, b } end")(first, seed)
    peer.execute("enforceLevelSeed()")
    assert int(peer.eval("engine.second")) == seed
    assert lines(peer)[-1].startswith("levelseed ord=1 at generation: ours was")


def test_a_load_that_takes_no_step_is_left_alone():
    """Already at the host's seed before the load: nothing to undo."""
    first, seed = host_floor()
    peer = machine(False)
    peer.eval("function(a, b) engine.first, engine.second = a, b; hostSeeds[1] = { a, b } end")(first, seed)
    peer.execute("enforceLevelSeed(true)")
    assert int(peer.eval("sets")) == 0


@pytest.mark.parametrize("first,before", [
    (0x7FFFFFFFFFFFFFF0, 0x7FFFFFFFFFFFFFF0),    # the step overflows
    (-0x123456789ABCDEF, -0x7FFFFFFFFFFFFFF0),   # and underflows
])
def test_the_step_back_wraps_exactly_as_the_engines_step(first, before):
    host = machine(True)
    host.execute(f"engine.first, engine.second = {first}, {before}")
    seed = int(host.eval("loadFloor()"))
    peer = machine(False)
    peer.execute(f"engine.first, engine.second = {first}, {before} + 99")  # out of step
    peer.eval("function(a, b) hostSeeds[1] = { a, b } end")(first, seed)
    assert int(peer.eval("loadFloor()")) == seed


def test_a_seed_that_is_not_a_whole_number_is_not_used():
    peer = machine(False)
    peer.execute("hostSeeds[1] = { 3.5, 7 }")
    peer.execute("loadFloor()")
    assert int(peer.eval("sets")) == 0


def test_the_host_never_rebases_onto_itself():
    host = machine(True)
    host.execute("hostSeeds[1] = { 1, 2 }")
    host.execute("loadFloor()")
    assert int(host.eval("sets")) == 0


def test_the_agreed_run_seed_is_still_forced_everywhere():
    for host in (True, False):
        rt = machine(host)
        rt.execute("pendingRunSeed = { 11, 22 }")
        rt.execute("enforceLevelSeed(true)")
        assert int(rt.eval("engine.first")) == 11 and int(rt.eval("engine.second")) == 22


def test_the_load_screen_call_says_it_is_before_the_load():
    src = EVENT_SYNC[EVENT_SYNC.index("local function onPreLoadScreen()"):]
    src = src[:src.index("\nend\n")]
    assert "enforceLevelSeed(true)" in src
    gen = EVENT_SYNC[EVENT_SYNC.index("local function onPreLevelGeneration()"):]
    gen = gen[:gen.index("\nend\n")]
    assert "enforceLevelSeed()" in gen and "enforceLevelSeed(true)" not in gen


def test_a_seed_we_cannot_read_is_replaced_and_said_without_failing():
    first, seed = host_floor()
    peer = machine(False)
    peer.execute("function get_adventure_seed() return 0.5, 0.25 end")
    peer.eval("function(a, b) hostSeeds[1] = { a, b } end")(first, seed)
    peer.execute("enforceLevelSeed(true)")
    assert int(peer.eval("sets")) == 1
    assert "ours was ?" in lines(peer)[0]
