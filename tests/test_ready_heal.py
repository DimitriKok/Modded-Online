"""The client puts its readiness back when the server's copy no longer matches.

At the end of hdmod's tutorial both players reach the camp on the same frame, and
each machine sends `endrun` then `ready`. The server interleaves the two machines,
so the first finisher's ready landed BEFORE the last finisher's endrun reopened the
room, and the reopen (before server 1.0.12) cleared every ready. The client
announces readiness once per camp visit, so it never sent it again: the lobby
showed "1 / 2 READY" for good and the host's door said "Waiting for everyone to
pick a character..." with both characters picked. The server half is in
server/test_server.py; this is the client half, which also covers a ready datagram
that is simply lost, and a server that has not been redeployed.

Run:  python -m pytest tests/test_ready_heal.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")

NL = "\n"


def heal_source() -> str:
    start = "function module.pollReadyHeal()"
    assert start in EVENT_SYNC, "pollReadyHeal not found in src/eventSync.lua"
    i = EVENT_SYNC.index(start)
    end = NL + "end" + NL
    j = EVENT_SYNC.index(end, i)
    return EVENT_SYNC[i:j] + end


ENV = """
now = 50000
function get_ms() return now end
module = { readyHealMs = 0 }
DesyncLog = nil
sends = {}
Network = {
    PHASE = { IDLE = 0, LOBBY = 1, INGAME = 2 },
    phase = 1,
    slot = 2,
    roomStarted = false,
    lobbyPlayers = {
        { slot = 1, name = "host", ready = true },
        { slot = 2, name = "peer", ready = false },
    },
    isInRun = function() return false end,
    setReady = function(ready, char, dest)
        sends[#sends + 1] = { ready = ready, char = char, dest = dest }
    end,
}
sentReady = true
myReady = true
myPickedChar = 195
myReadyDest = nil
"""


def lua():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(heal_source())
    return rt


def poll(rt):
    rt.execute("module.pollReadyHeal()")


def sends(rt) -> int:
    return int(rt.eval("#sends"))


def test_the_session_the_ready_wiped_by_the_reopen_is_sent_again():
    rt = lua()
    poll(rt)
    assert sends(rt) == 1, "the server lost our ready and we never sent it again"
    assert rt.eval("sends[1].ready") is True
    assert int(rt.eval("sends[1].char")) == 195, "resent without the character we picked"


def test_rate_limited_until_the_lobby_push_agrees():
    rt = lua()
    poll(rt)
    rt.execute("now = now + 200")
    poll(rt)
    assert sends(rt) == 1
    rt.execute("now = now + 1000")
    poll(rt)
    assert sends(rt) == 2, "a resend that was itself lost must be retried"
    rt.execute("Network.lobbyPlayers[2].ready = true; now = now + 5000")
    poll(rt)
    assert sends(rt) == 2, "kept sending after the server agreed"


def test_never_into_a_started_room():
    """Readying while a run is in progress asks to be folded back INTO that run."""
    rt = lua()
    rt.execute("Network.roomStarted = true")
    poll(rt)
    rt.execute("Network.roomStarted = nil")  # not yet told either way
    poll(rt)
    assert sends(rt) == 0


def test_not_before_this_camp_visit_announced():
    rt = lua()
    rt.execute("sentReady = false")
    poll(rt)
    assert sends(rt) == 0


def test_not_outside_the_lobby():
    rt = lua()
    rt.execute("Network.phase = Network.PHASE.INGAME")
    poll(rt)
    rt.execute("Network.phase = Network.PHASE.LOBBY; Network.isInRun = function() return true end")
    poll(rt)
    assert sends(rt) == 0


def test_a_public_room_not_ready_is_left_alone():
    """Public rooms ready at the door: our own NOT ready matching the server's is no work."""
    rt = lua()
    rt.execute("myReady = false")
    poll(rt)
    assert sends(rt) == 0


def test_a_public_door_vote_the_server_lost_is_resent_with_its_door():
    rt = lua()
    rt.execute("myReadyDest = { 2, 1, 5 }")
    poll(rt)
    assert sends(rt) == 1
    assert list(rt.eval("sends[1].dest").values()) == [2, 1, 5]


def test_quiet_when_we_are_not_in_the_list_yet():
    rt = lua()
    rt.execute("Network.lobbyPlayers = { { slot = 1, ready = true } }")
    poll(rt)
    rt.execute("Network.lobbyPlayers = 7")  # off the wire: never index a non-table
    poll(rt)
    assert sends(rt) == 0


def test_announcing_counts_as_a_send():
    """The announcement stamps the limiter, so the first lobby push after it (still
    showing the pre-announce state) does not trigger an immediate duplicate."""
    src = EVENT_SYNC
    i = src.index("function announceLobbyReady()")
    j = src.index(NL + "end" + NL, i)
    body = src[i:j]
    assert "Network.setReady(myReady, myPickedChar, nil)" in body
    assert body.index("module.readyHealMs = get_ms()") > body.index(
        "Network.setReady(myReady, myPickedChar, nil)")


def test_it_is_polled():
    assert 'SafeCall("eventSync:pollReadyHeal", module.pollReadyHeal)' in EVENT_SYNC
