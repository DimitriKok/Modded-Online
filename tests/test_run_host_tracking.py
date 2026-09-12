"""Tests that the server knows who is DRIVING the run, not just who holds slot 1.

Folding a rejoining player in is gated on the request coming from the run host,
and the server used to answer that question with `room.host()` — "lowest occupied
slot". Those are not the same thing, and the difference is exactly why a host
could leave but never rejoin:

  1. player 1 (slot 1) leaves; player 2 (slot 2) carries the run on
  2. player 1 comes back and `free_slot()` hands them slot 1 again
  3. `room.host()` is therefore player 1 — the player still WAITING to be folded in
  4. player 2, which really is driving the run, sends `joinfloor`
  5. the server sees `client is not room.host()` and drops it, silently
  6. player 2 walks through the door alone; player 1 sits in the lobby for good

A late-joiner must never count as the run host, however low its slot. The room now
tracks `run_host_slot` explicitly and promotes it on departure, mirroring the
client's `Network.runHostSlot`.

Run:  python -m pytest tests/test_run_host_tracking.py -q
"""

from __future__ import annotations

import pathlib
import sys

SERVER_DIR = pathlib.Path(__file__).resolve().parent.parent / "server"
sys.path.insert(0, str(SERVER_DIR))

import server as srv  # noqa: E402


def make_room(*slots, late=(), left=()):
    room = srv.Room("TEST", "m", "v")
    for slot in slots:
        c = srv.Client(("127.0.0.1", 100 + slot), 100 + slot, f"p{slot}", f"cid{slot}")
        c.slot = slot
        c.late_pending = slot in late
        c.left_run = slot in left
        room.clients[c.client_id] = c
    return room


def client_at(room, slot):
    return next(c for c in room.clients.values() if c.slot == slot)


def test_in_run_excludes_a_late_joiner():
    room = make_room(1, 2, late=(1,))
    assert [c.slot for c in room.in_run()] == [2]


def test_promote_picks_the_lowest_slot_actually_playing():
    room = make_room(2, 3)
    assert room.promote_run_host() == 2


def test_promote_ignores_a_late_joiner_holding_the_lowest_slot():
    """The whole bug: the returning player reclaims slot 1 before being folded in."""
    room = make_room(1, 2, late=(1,))
    assert room.promote_run_host() == 2, (
        "a player waiting to be folded in was treated as the one driving the run"
    )


def test_promote_is_zero_when_nobody_is_playing():
    room = make_room(1, late=(1,))
    assert room.promote_run_host() == 0


def test_the_reported_sequence_end_to_end():
    """host leaves -> peer drives -> host returns and reclaims slot 1."""
    room = make_room(1, 2)
    room.run_host_slot = 1                      # as start_run would set it

    # player 1 leaves: the room drops them and promotes
    departing = client_at(room, 1)
    room.clients.pop(departing.client_id)
    assert departing.slot == room.run_host_slot  # this is what triggers promotion
    assert room.promote_run_host() == 2

    # player 1 comes back, gets slot 1 again, and is waiting to be folded in
    assert room.free_slot() == 1
    back = srv.Client(("127.0.0.1", 111), 111, "p1", "cid1b")
    back.slot = room.free_slot()
    back.late_pending = True
    room.clients[back.client_id] = back

    assert room.host() is back, "sanity: lowest occupied slot really is the rejoiner"
    assert room.run_host_slot == 2, (
        "the rejoiner became the run host again, so the peer's joinfloor would be "
        "rejected and the rejoiner would never be folded in"
    )


def test_a_non_host_leaving_does_not_move_the_run_host():
    """The case that already worked must keep working."""
    room = make_room(1, 2)
    room.run_host_slot = 1
    leaving = client_at(room, 2)
    room.clients.pop(leaving.client_id)
    assert leaving.slot != room.run_host_slot   # so no promotion happens
    assert room.run_host_slot == 1


def test_folding_in_makes_the_returning_player_a_participant_again():
    """After the join run_start, both are participants and the roster's lowest leads."""
    room = make_room(1, 2, late=(1,))
    room.run_host_slot = 2
    client_at(room, 1).late_pending = False     # readied, then folded in
    participants = [c for c in room.clients.values() if not c.late_pending]
    assert min(c.slot for c in participants) == 1


def test_in_run_excludes_someone_who_ended_their_adventure():
    """Leaving the RUN does not leave the ROOM — that is why the header still
    counted them, and why the run host was never handed on."""
    room = make_room(1, 2, left=(1,))
    assert [c.slot for c in room.in_run()] == [2]


def test_ending_your_adventure_hands_the_run_host_on():
    """The path a player actually takes when they "leave the game".

    drop_client never runs here (they stay in room.clients), so a promotion that
    only lived there could not help — which is why the previous fix did nothing
    for this repro.
    """
    room = make_room(1, 2)
    room.run_host_slot = 1
    client_at(room, 1).left_run = True           # what on_endrun sets
    assert room.promote_run_host() == 2, (
        "the room still named a run host that had stopped playing, so the peer "
        "actually simulating could not fold a rejoiner in"
    )


def test_the_full_end_adventure_rejoin_sequence():
    """1-1 starts, player 1 ends their adventure, comes back and readies."""
    room = make_room(1, 2)
    room.run_host_slot = 1

    # player 1 leaves the RUN but stays in the ROOM
    p1 = client_at(room, 1)
    p1.left_run = True
    assert room.promote_run_host() == 2

    # they rejoin: same cid, so they are marked as a late-joiner in place
    p1.late_pending = True
    assert room.run_host_slot == 2, "the rejoiner reclaimed the run host"

    # they ready up -> the server clears late_pending and emits join_pending
    p1.late_pending = False
    assert room.run_host_slot == 2, (
        "readying up must not make the joiner the run host; the peer driving the "
        "run has to stay the one whose joinfloor is accepted"
    )

    # the fold-in run_start puts them back in the run
    participants = [c for c in room.clients.values() if not c.late_pending]
    for c in participants:
        c.left_run = False
    assert sorted(c.slot for c in room.in_run()) == [1, 2]
