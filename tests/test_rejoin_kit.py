"""Tests the kit a player is folded back into a run with.

A departed player's spelunker is stood still rather than removed — that is what
keeps the simulation deterministic — so the host's snapshot of it still holds the
full kit they walked away with. Handing that straight back let a player bank
consumables by leaving and rejoining. A rejoiner should come in with no bombs and
no ropes, keeping the health they left with (which the idle body already holds).

The edit is applied to the SNAPSHOT before it is written, so every machine
performs the identical edit to the identical payload — this is simulation state
and cannot be decided locally. In particular the returning player's own machine
cleared its departed-player state when its run ended, so it does not know it was
the one who left; the server names the folded-in slots in the run_start.

Run:  python -m pytest tests/test_rejoin_kit.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")
SERVER = (PACK / "server" / "server.py").read_text(encoding="utf-8")

NL = chr(10)


def kit_source() -> str:
    start = "local function applyRejoinKit(joinSlots)"
    end = NL + "end" + NL
    assert start in EVENT_SYNC, "applyRejoinKit not found in src/eventSync.lua"
    i = EVENT_SYNC.index(start)
    j = EVENT_SYNC.index(end, i)
    return EVENT_SYNC[i:j] + end + NL + "applyRejoinKitG = applyRejoinKit" + NL


ENV = """
DesyncLog = { event = function() end }
Network = { coopSlots = { [1] = 1, [2] = 2 } }
pendingStateSync = nil

function setSnapshot(t) pendingStateSync = t end
function entry(coop) return pendingStateSync.pl[tostring(coop)] end
function slots(...) return { ... } end
"""


def lua():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(kit_source())
    return rt


def snapshot(rt, players):
    """players: {coopIndex: (hp, bombs, ropes)}"""
    rows = []
    for coop, (hp, bo, ro) in players.items():
        rows.append(f'["{coop}"] = {{ hp = {hp}, bo = {bo}, ro = {ro} }}')
    rt.execute("setSnapshot({ pl = { " + ", ".join(rows) + " } })")


def get(rt, coop, field):
    v = rt.eval(f'pendingStateSync.pl["{coop}"].{field}')
    return int(v)


def test_a_rejoining_player_loses_bombs_and_ropes_but_keeps_health():
    rt = lua()
    snapshot(rt, {1: (3, 7, 5), 2: (4, 2, 2)})
    rt.eval("applyRejoinKitG")(rt.eval("slots")(1))
    assert get(rt, 1, "bo") == 0, "rejoiner kept their bombs"
    assert get(rt, 1, "ro") == 0, "rejoiner kept their ropes"
    assert get(rt, 1, "hp") == 3, "health should be what they left with"


def test_the_players_who_stayed_are_untouched():
    rt = lua()
    snapshot(rt, {1: (3, 7, 5), 2: (4, 2, 2)})
    rt.eval("applyRejoinKitG")(rt.eval("slots")(1))
    assert get(rt, 2, "bo") == 2, "a player who never left lost their bombs"
    assert get(rt, 2, "ro") == 2
    assert get(rt, 2, "hp") == 4


def test_several_rejoiners_at_once():
    rt = lua()
    snapshot(rt, {1: (1, 9, 9), 2: (2, 9, 9)})
    rt.eval("applyRejoinKitG")(rt.eval("slots")(1, 2))
    for coop, hp in ((1, 1), (2, 2)):
        assert get(rt, coop, "bo") == 0
        assert get(rt, coop, "ro") == 0
        assert get(rt, coop, "hp") == hp


def test_no_join_list_changes_nothing():
    """A resync, or a fresh run: nobody is being folded in."""
    rt = lua()
    snapshot(rt, {1: (3, 7, 5)})
    rt.eval("applyRejoinKitG")(None)
    assert get(rt, 1, "bo") == 7
    assert get(rt, 1, "ro") == 5


def test_a_slot_outside_the_roster_is_ignored():
    rt = lua()
    snapshot(rt, {1: (3, 7, 5)})
    rt.eval("applyRejoinKitG")(rt.eval("slots")(4))
    assert get(rt, 1, "bo") == 7


def test_no_snapshot_is_harmless():
    rt = lua()
    rt.execute("pendingStateSync = nil")
    rt.eval("applyRejoinKitG")(rt.eval("slots")(1))  # must not raise


def test_the_server_names_the_folded_in_slots_only_for_a_midrun_join():
    """The list is authoritative and must not be sent for a fresh run."""
    assert "rejoining = sorted(c.slot for c in participants if c.left_run)" in SERVER
    i = SERVER.index('payload["join"] = rejoining')
    j = SERVER.index('if isinstance(floor, dict):')
    assert j < i, "the join list must sit inside the mid-run-join branch"
