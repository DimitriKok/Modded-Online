"""Tests that the memoized `get_frame` / `get_ms` the shim installs returns exactly
what the unmemoized version returned.

The shim replaces those two engine functions so that content-mod logic keyed to a
clock ticks on the *simulated* frame count, which is identical on every machine,
rather than on the render loop, which is not. Spelunky 2.5 calls them from
per-entity update paths, so they ran once per live custom entity per frame — each
time a `pcall` and a `get_local_state()` boundary crossing to read a number that
cannot change inside a frame.

Caching that is only safe if the sequence of values is unchanged, and the hard case
is the restart: `time_total` goes back to zero, and the clock has to carry the old
elapsed time forward instead of jumping backwards (v11 shipped the jump, and the HD
mod's music faded for minutes because every pending deadline landed in the future).
So the reference implementation below is the pre-cache logic, and the test drives
both through a run, a restart and a second run.

Run:  python -m pytest tests/test_shim_clock.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
INJECTOR = (PACK / "src" / "shimInjector.lua").read_text(encoding="utf-8")

NL = chr(10)


def live_payload() -> str:
    head = 'local SHIM = "-- " .. MARKER .. [['
    i = INJECTOR.index(head)
    return INJECTOR[i + len(head):INJECTOR.index(NL + "]]" + NL, i)]


LIVE = live_payload()

ENGINE = """
timeTotal = 0
inRun = true
reads = 0
function get_local_state()
    reads = reads + 1
    if not inRun then
        return nil
    end
    return {time_total = timeTotal}
end
"""

# the clock exactly as it was before the cache, to compare against
REFERENCE = """
local refBase = 0
local refLast = 0
function refFrame(moFrame)
    local total
    local ok, s = pcall(get_local_state)
    if ok and s ~= nil then
        total = math.floor(s.time_total)
    else
        total = moFrame
    end
    if total < refLast then
        refBase = refBase + refLast + 1
    end
    refLast = total
    return refBase + total
end
"""


def clock_block() -> str:
    """The shipped clock, with the pieces it needs and its locals exposed."""
    a = LIVE.index("    local function moRawSimFrame()")
    b = LIVE.index("    get_ms = moGetMs") + len("    get_ms = moGetMs")
    body = LIVE[a:b]
    return NL.join([
        "local moFrame = 0",
        "function bumpFrame() moFrame = moFrame + 1 end",
        "function currentMoFrame() return moFrame end",
        body,
        "invalidate = moClockInvalidate",
        "",
    ])


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(REFERENCE)
    rt.execute(clock_block())
    return rt


def tick(rt, frames: int, results: list) -> None:
    """Advance `frames` simulated frames, sampling the clock several times each."""
    for _ in range(frames):
        rt.execute("timeTotal = timeTotal + 1")
        rt.execute("bumpFrame()")
        rt.eval("invalidate")()                      # what ON.GAMEFRAME does
        got = [int(rt.eval("get_frame()")) for _ in range(5)]
        assert len(set(got)) == 1, f"the clock moved inside one frame: {got}"
        want = int(rt.eval("refFrame")(rt.eval("currentMoFrame()")))
        results.append((got[0], want))


def test_the_clock_matches_the_uncached_logic_frame_for_frame():
    rt = runtime()
    seen: list = []
    tick(rt, 40, seen)
    assert all(a == b for a, b in seen), [p for p in seen if p[0] != p[1]][:5]
    assert seen[0][0] == 1 and seen[-1][0] == 40


def test_it_still_carries_forward_across_a_restart():
    """time_total goes back to zero; the clock must not."""
    rt = runtime()
    seen: list = []
    tick(rt, 30, seen)
    before = int(rt.eval("get_frame()"))

    rt.execute("timeTotal = 0")                      # the restart
    rt.eval("invalidate")()                          # PRE_LOAD_SCREEN / LOADING
    after = int(rt.eval("get_frame()"))
    assert int(rt.eval("refFrame")(rt.eval("currentMoFrame()"))) == after
    assert after > before, f"the clock went backwards: {before} -> {after}"

    tick(rt, 30, seen)
    assert all(a == b for a, b in seen), [p for p in seen if p[0] != p[1]][:5]


def test_two_restarts_stay_strictly_increasing():
    rt = runtime()
    seen: list = []
    values = []
    for _ in range(3):
        tick(rt, 15, seen)
        values.append(int(rt.eval("get_frame()")))
        rt.execute("timeTotal = 0")
        rt.eval("invalidate")()
        values.append(int(rt.eval("get_frame()")))
    assert values == sorted(values) and len(set(values)) == len(values), values
    assert all(a == b for a, b in seen)


def test_a_frame_is_read_from_the_engine_once_however_often_it_is_asked():
    """The point of the change: 2.5 asks per entity, not per frame."""
    rt = runtime()
    rt.execute("timeTotal = 100")
    rt.eval("invalidate")()
    rt.execute("reads = 0")
    for _ in range(200):
        rt.eval("get_frame()")
        rt.eval("get_ms()")
    assert int(rt.eval("reads")) == 1, (
        f"{rt.eval('reads')} engine state reads for 400 clock calls in one frame"
    )


def test_the_cache_is_dropped_at_the_events_that_can_move_it():
    """A load can change time_total with no simulated frame in between."""
    live = LIVE
    for event in ("ON.PRE_LOAD_SCREEN", "ON.LOADING", "ON.PRE_LEVEL_GENERATION"):
        assert f"moRealSetCallback(moClockInvalidate, {event})" in live, event
    # and every simulated frame, from the one merged tick
    i = live.index("local function moFrameTick()")
    body = live[i:live.index("end", i)]
    assert "moClockInvalidate()" in body
    # the counter is still bumped before the seed is taken from it
    assert body.index("moFrame = moFrame + 1") < body.index("pcall(moFrameSeed)")


def test_get_ms_stays_locked_to_get_frame():
    rt = runtime()
    rt.execute("timeTotal = 60")
    rt.eval("invalidate")()
    frame = int(rt.eval("get_frame()"))
    ms = float(rt.eval("get_ms()"))
    assert abs(ms - frame * (1000.0 / 60.0)) < 1e-9


def test_outside_a_run_it_falls_back_to_the_local_counter():
    rt = runtime()
    rt.execute("inRun = false")
    seen = []
    for _ in range(10):
        rt.execute("bumpFrame()")
        rt.eval("invalidate")()
        seen.append(int(rt.eval("get_frame()")))
    assert seen == sorted(seen), seen
    assert seen[-1] > seen[0], "the menu clock stopped advancing"
