"""Tests that a player rejoining mid-run actually announces readiness.

Readiness used to be announced only from `onScreenChange`, behind two conditions
that a rejoining player satisfies in the wrong order:

    if Network.phase == PHASE.LOBBY and screen == SCREEN.CAMP then

`leaveRun` drops the phase to IDLE *first*, and the warp back to the camp happens
while it is still IDLE — so that screen change is skipped. By the time they
re-enter the room the phase becomes LOBBY while they are ALREADY STANDING IN THE
CAMP, so no further screen change ever arrives and the announcement never runs.

The server gates `join_pending` on `client.ready`, so the world host is never told
to fold them in: the player sits in the camp indefinitely, which is the "they were
never set into the game" report. A poll now covers the ordering the screen change
cannot see.

Run:  python -m pytest tests/test_lobby_ready.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")

NL = chr(10)


def poll_source() -> str:
    """The shipped poll, verbatim."""
    start = "local function pollLobbyReady()"
    end = NL + "end" + NL
    assert start in EVENT_SYNC, "pollLobbyReady not found in src/eventSync.lua"
    i = EVENT_SYNC.index(start)
    j = EVENT_SYNC.index(end, i)
    return EVENT_SYNC[i:j] + end + NL + "pollLobbyReadyG = pollLobbyReady" + NL


ENV = """
SCREEN = { CAMP = 11, LEVEL = 12, TRANSITION = 13, MENU = 4 }
Network = { PHASE = { IDLE = 0, LOBBY = 1, INGAME = 2 }, phase = 1 }
sentReady = false
doorHookPending = false
announced = 0
screen = SCREEN.CAMP
function get_local_state() return { screen = screen } end
-- stands in for the real announcement; the real one latches sentReady the same way
function announceLobbyReady()
    if not sentReady then
        sentReady = true
        announced = announced + 1
    end
end
"""


def lua():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(poll_source())
    return rt


def run(rt):
    rt.eval("pollLobbyReadyG")()


def test_announces_when_in_the_camp_and_in_a_lobby():
    rt = lua()
    run(rt)
    assert int(rt.eval("announced")) == 1
    assert rt.eval("doorHookPending"), "the camp door was not re-armed"


def test_the_rejoin_ordering_that_the_screen_change_cannot_see():
    """Camp reached while IDLE (no announce), room joined later with no new screen change."""
    rt = lua()
    rt.execute("Network.phase = Network.PHASE.IDLE")
    run(rt)
    assert int(rt.eval("announced")) == 0, "announced while not in a room"
    # now they re-enter the room, still standing in the camp: no screen change comes
    rt.execute("Network.phase = Network.PHASE.LOBBY")
    run(rt)
    assert int(rt.eval("announced")) == 1, (
        "a player who joined the room while already in the camp never announced "
        "readiness, so the host was never told to fold them in"
    )


def test_it_announces_only_once():
    rt = lua()
    for _ in range(5):
        run(rt)
    assert int(rt.eval("announced")) == 1


def test_it_stays_quiet_outside_the_camp():
    rt = lua()
    rt.execute("screen = SCREEN.LEVEL")
    run(rt)
    assert int(rt.eval("announced")) == 0


def test_it_stays_quiet_while_in_a_run():
    rt = lua()
    rt.execute("Network.phase = Network.PHASE.INGAME")
    run(rt)
    assert int(rt.eval("announced")) == 0


def test_a_fresh_camp_visit_can_announce_again():
    """sentReady is cleared when the run state is torn down, so the next visit re-announces."""
    rt = lua()
    run(rt)
    assert int(rt.eval("announced")) == 1
    rt.execute("sentReady = false")  # what clearRunState does
    run(rt)
    assert int(rt.eval("announced")) == 2
