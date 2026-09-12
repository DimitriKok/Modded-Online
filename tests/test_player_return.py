"""Tests for restoring a player who leaves and comes back.

A departure was a one-way door. `hidePlayerEntity` set INVISIBLE,
PASSES_THROUGH_EVERYTHING and NO_GRAVITY on the leaver's spelunker, and every
path that could have undone it bails on `next(goneSlots) == nil` — so the moment
a slot stopped being gone, nothing ran to put it back. The flags outlived the
departure: a returning player was invisible, fell through the floor, and could
not be seen by anyone. The same held for the HUD, where the row was blanked with
`opacity` (documented as controlling only the row's BACKGROUND) while the hearts,
bombs and ropes kept drawing over an empty slot.

These drive the shipped source of the hide/restore helpers against the engine's
real flag helpers, so a regression in either direction is caught: failing to
restore what we hid, or clobbering a flag we never set.

Run:  python -m pytest tests/test_player_return.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8")

NL = chr(10)


def _slice(start_marker: str, end_marker: str, what: str) -> str:
    """The shipped source between two literal markers, verbatim."""
    assert start_marker in INPUT_SYNC, f"{what} not found in src/inputSync.lua"
    i = INPUT_SYNC.index(start_marker)
    j = INPUT_SYNC.index(end_marker, i)
    return INPUT_SYNC[i:j] + end_marker


def helpers() -> str:
    hide = _slice("local function hidePlayerEntity(player, netSlot)",
                  NL + "end" + NL, "hidePlayerEntity")
    show = _slice("local function showPlayerEntity(player)",
                  NL + "end" + NL, "showPlayerEntity")
    restore = _slice("local function restoreReturnedPlayers()",
                     NL + "    end" + NL + "end" + NL, "restoreReturnedPlayers")
    return hide + show + restore + NL.join([
        "", "hide = hidePlayerEntity", "show = showPlayerEntity",
        "restore = restoreReturnedPlayers", "",
    ])


ENV = """
-- Overlunky's 1-based bit indices, as the engine defines them
function set_flag(flags, bit) return flags | (1 << (bit - 1)) end
function clr_flag(flags, bit) return flags & ~(1 << (bit - 1)) end
function test_flag(flags, bit) return (flags & (1 << (bit - 1))) ~= 0 end
ENT_FLAG = { INVISIBLE = 1, PASSES_THROUGH_EVERYTHING = 3, NO_GRAVITY = 11, TAKE_NO_DAMAGE = 5 }

active = true  -- globals: the helpers load as a separate chunk
coopSlots = {}
goneSlots = {}
hiddenSlots = {}

players = {}
function get_player(coopIndex) return players[coopIndex] end
function newPlayer() return { flags = 0, velocityx = 5, velocityy = 5 } end

function setRoster(t) coopSlots = {} for k, v in pairs(t) do coopSlots[k] = v end end
function setGone(t) goneSlots = {} for k, v in pairs(t) do goneSlots[k] = v end end
function hiddenCount() local n = 0 for _ in pairs(hiddenSlots) do n = n + 1 end return n end
function isHidden(slot) return hiddenSlots[slot] ~= nil end
"""


def lua():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(helpers())
    return rt


def flags_of(rt, coop_index):
    return int(rt.eval("players[%d].flags" % coop_index))


def test_hiding_sets_the_three_flags_and_records_the_slot():
    rt = lua()
    rt.execute("players[1] = newPlayer()")
    rt.eval("hide")(rt.eval("players[1]"), 7)
    f = flags_of(rt, 1)
    assert rt.eval("test_flag")(f, 1), "INVISIBLE not set"
    assert rt.eval("test_flag")(f, 3), "PASSES_THROUGH_EVERYTHING not set"
    assert rt.eval("test_flag")(f, 11), "NO_GRAVITY not set"
    assert rt.eval("isHidden")(7), "slot not recorded for later restore"
    assert int(rt.eval("players[1].velocityx")) == 0


def test_a_returning_player_gets_their_body_back():
    rt = lua()
    rt.execute("players[1] = newPlayer(); setRoster({[1] = 7}); setGone({[7] = {}})")
    rt.eval("hide")(rt.eval("players[1]"), 7)
    rt.execute("setGone({})")  # the run_start carrying the rejoin clears it wholesale
    rt.eval("restore")()
    f = flags_of(rt, 1)
    assert not rt.eval("test_flag")(f, 1), "still INVISIBLE after returning"
    assert not rt.eval("test_flag")(f, 3), "still non-colliding after returning"
    assert not rt.eval("test_flag")(f, 11), "still weightless after returning"
    assert not rt.eval("isHidden")(7), "slot still on the undo list"


def test_restore_leaves_a_still_departed_player_hidden():
    rt = lua()
    rt.execute("players[1] = newPlayer(); setRoster({[1] = 7}); setGone({[7] = {}})")
    rt.eval("hide")(rt.eval("players[1]"), 7)
    rt.eval("restore")()
    assert rt.eval("test_flag")(flags_of(rt, 1), 1), "unhid a player who is still gone"
    assert rt.eval("isHidden")(7)


def test_restore_never_clears_a_flag_we_did_not_set():
    """Another mod, or an item, may legitimately want a player invisible."""
    rt = lua()
    rt.execute("players[1] = newPlayer(); setRoster({[1] = 7}); setGone({})")
    rt.execute("players[1].flags = set_flag(players[1].flags, ENT_FLAG.INVISIBLE)")
    rt.execute("players[1].flags = set_flag(players[1].flags, ENT_FLAG.TAKE_NO_DAMAGE)")
    rt.eval("restore")()
    f = flags_of(rt, 1)
    assert rt.eval("test_flag")(f, 1), "cleared INVISIBLE that we never set"
    assert rt.eval("test_flag")(f, 5), "clobbered an unrelated flag"


def test_a_slot_that_leaves_the_roster_is_forgotten():
    rt = lua()
    rt.execute("players[1] = newPlayer(); setRoster({[1] = 7}); setGone({[7] = {}})")
    rt.eval("hide")(rt.eval("players[1]"), 7)
    rt.execute("setRoster({[1] = 2}); setGone({})")
    rt.eval("restore")()
    assert rt.eval("hiddenCount")() == 0, "undo list leaks slots that left the roster"


def test_restore_is_idempotent():
    rt = lua()
    rt.execute("players[1] = newPlayer(); setRoster({[1] = 7}); setGone({[7] = {}})")
    rt.eval("hide")(rt.eval("players[1]"), 7)
    rt.execute("setGone({})")
    for _ in range(3):
        rt.eval("restore")()
    assert flags_of(rt, 1) == 0
    assert rt.eval("hiddenCount")() == 0
