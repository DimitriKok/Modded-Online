"""Tests the transition exit barrier -- nobody leaves a transition alone.

Two machines enter a transition on the same frame and leave it on different ones.
From the two-machine capture: both logged the transition at seq:offset 7:873, then
the peer left at 8:259 while the host was still standing there, stalling at 8:265 on
inputs that were never coming. Entering is lockstepped; LEAVING was not, because
each machine walks out when its own player finishes with Mama Tunnel.

The cost was not the gap itself. The peer generated 2-1 alone, the stall detector
resync-warped the party to 2-1, and the peer generated 2-1 A SECOND TIME -- and the
HD mod builds levels in Lua and advances its own state doing it, so the peer's
second 2-1 was a different world (FLOOR DESYNC seq=17: seed matching, entities not).

Run:  python -m pytest tests/test_transition_barrier.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")
NL = chr(10)


def _block():
    start = EVENT_SYNC.index("local tbar = {")
    marker = "function module.holdTransitionExit()"
    end = EVENT_SYNC.index(NL + "end" + NL, EVENT_SYNC.index(marker)) + len(NL + "end" + NL)
    return EVENT_SYNC[start:end]


ENV = """
runActive = true
SCREEN = {TRANSITION = 13, LEVEL = 12}
FADE = {NONE = 0}
nowValue = 0
sent = {}
logLines = {}
stateTable = {screen = 13, screen_next = 12, level_count = 4, loading = 2}
function get_ms() return nowValue end
function get_local_state() return stateTable end
module = {}
DesyncLog = {event = function(fmt) logLines[#logLines + 1] = fmt end}
Network = {
    isInRun = function() return true end,
    slot = 1,
    coopSlots = {1, 2},
    sendEvent = function(k, p) sent[#sent + 1] = {k = k, p = p} end,
}
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(_block())
    return rt


def frame(rt):
    """One more engine frame, changing nothing else.

    The tests that shipped dev48 called `leaving()` repeatedly, which re-set
    screen_next to LEVEL every time -- and that is precisely what hid the deadlock,
    because it papered over the barrier's own early return. Real frames do not do
    that, so these do not either.
    """
    rt.execute("module.holdTransitionExit()")


def leaving(rt):
    """The engine commits to leaving the transition."""
    rt.execute("stateTable.screen = SCREEN.TRANSITION")
    rt.execute("stateTable.screen_next = SCREEN.LEVEL")
    rt.execute("stateTable.loading = 2")
    frame(rt)


def held(rt):
    return int(rt.eval("stateTable.screen_next")) == int(rt.eval("SCREEN.TRANSITION"))


def test_a_machine_that_finishes_first_is_held():
    rt = runtime()
    leaving(rt)
    assert held(rt), (
        "the peer walked out of the transition alone -- it will generate the next "
        "floor by itself and then a second time when the resync warp lands")
    assert int(rt.eval("stateTable.loading")) == 0, "the fade was left running"
    assert rt.eval("module.transitionHolding()") is True


def test_the_barrier_keeps_evaluating_while_it_holds():
    """dev48's deadlock, pinned.

    The hold sets screen_next back to TRANSITION, and the early return at the top
    then matched on the very next frame -- so the barrier ran ONCE. Readiness was
    never re-checked, the resend never fired, the give-up timer never ran, and two
    machines held each other forever. Both logs showed the pair announcing the hold
    on the identical frame and neither ever releasing.
    """
    rt = runtime()
    leaving(rt)
    frame(rt)
    frame(rt)
    assert held(rt), "released with nobody else ready"
    rt.execute("module.onTransitionReady({k = 4}, 2)")
    frame(rt)
    assert not held(rt), (
        "the barrier evaluated once and deadlocked: readiness arrived and the hold "
        "was never reconsidered")


def test_releasing_puts_back_the_screen_change_it_paused():
    """Dropping the override is not enough. We overwrote the engine's screen_next
    and loading, so without restoring them the transition it had already committed
    to never happens and the player must walk into the door a second time."""
    rt = runtime()
    leaving(rt)
    rt.execute("module.onTransitionReady({k = 4}, 2)")
    frame(rt)
    assert int(rt.eval("stateTable.screen_next")) == int(rt.eval("SCREEN.LEVEL")), (
        "the engine's destination was not restored")
    assert int(rt.eval("stateTable.loading")) == 2, "the load fade was not restored"


def test_it_is_released_once_the_other_player_is_ready_too():
    rt = runtime()
    leaving(rt)
    rt.execute("module.onTransitionReady({k = 4}, 2)")
    frame(rt)
    assert not held(rt), "everyone was ready and the machine was still held"
    assert rt.eval("module.transitionHolding()") is False


def test_a_machine_not_trying_to_leave_is_never_touched():
    rt = runtime()
    rt.execute("stateTable.screen = SCREEN.TRANSITION")
    rt.execute("stateTable.screen_next = SCREEN.TRANSITION")
    rt.execute("stateTable.loading = 2")
    frame(rt)
    assert int(rt.eval("stateTable.loading")) == 2, "a settling transition was disturbed"
    assert int(rt.eval("#sent")) == 0, "announced readiness before being ready"


def test_readiness_for_a_different_transition_does_not_release_this_one():
    """Otherwise the NEXT transition is released by the previous one's signal, and
    the barrier silently stops existing after the first floor."""
    rt = runtime()
    rt.execute("module.onTransitionReady({k = 3}, 2)")  # the previous transition
    leaving(rt)
    assert held(rt)


def test_the_hold_gives_up_rather_than_freezing_the_party_forever():
    """A player who crashed or alt-F4'd will never signal. Driven by plain frames,
    because that is what the real thing gets."""
    rt = runtime()
    leaving(rt)
    assert held(rt)
    rt.execute("nowValue = 19000")
    frame(rt)
    assert held(rt), "gave up too early"
    rt.execute("nowValue = 21000")
    frame(rt)
    assert not held(rt), "the party is frozen on the transition with no way out"
    lines = list(rt.eval("logLines").values())
    assert any("gave up" in l for l in lines), (
        "gave up without saying so in the log: %r" % lines)
    assert rt.eval("module.transitionHolding()") is False
    assert int(rt.eval("stateTable.screen_next")) == int(rt.eval("SCREEN.LEVEL")), (
        "gave up without putting the engine's screen change back")


def test_giving_up_does_not_immediately_re_hold():
    rt = runtime()
    leaving(rt)
    rt.execute("nowValue = 21000")
    frame(rt)
    assert not held(rt)
    rt.execute("nowValue = 22000")
    frame(rt)
    frame(rt)
    assert not held(rt), "re-held the transition it had already given up on"


def test_a_player_who_left_the_run_is_not_waited_for():
    rt = runtime()
    rt.execute("Network.coopSlots = {1}")
    leaving(rt)
    assert not held(rt), "held for a slot that is no longer in the run"


def test_readiness_is_re_announced_while_waiting():
    """Once, then on a slow cadence -- for a peer that joined the roster late. The
    dev48 capture showed `next cseq out 3` for a whole session, i.e. it never
    re-announced at all."""
    rt = runtime()
    leaving(rt)
    frame(rt)
    frame(rt)
    assert int(rt.eval("#sent")) == 1, "spammed the event channel"
    assert rt.eval("sent[1].k") == "tready"
    assert int(rt.eval("sent[1].p.k")) == 4
    rt.execute("nowValue = 2000")
    frame(rt)
    assert int(rt.eval("#sent")) == 2, "never re-announced while holding"


def test_it_runs_from_pre_update_the_only_callback_that_fires_during_a_fade():
    input_sync = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8")
    assert 'SafeCall("inputSync:holdTransitionExit", EventSync.holdTransitionExit)' in input_sync


def test_the_player_is_told_they_are_waiting():
    menu = (PACK / "src" / "menuUI.lua").read_text(encoding="utf-8")
    assert "EventSync.transitionHolding()" in menu
    assert "InputSync.isStalled() or holding" in menu
