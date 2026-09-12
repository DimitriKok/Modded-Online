"""Tests that the authoritative world host moves when its holder leaves.

`Network.runHostSlot` is chosen once, at run start (the lowest slot in the
roster), and used to be left there for the rest of the run. When the player
holding it departed, every remaining machine kept pointing at a slot that was no
longer in the game, so `isWorldHost()` — which is `slot == runHostSlot` — was
false EVERYWHERE.

Everything only the world host does then stopped: publishing the authoritative
world/seed, and folding a late joiner in (`pollJoinAtTransition` returns at its
first line unless you are the world host). So a rejoin worked when a NON-host had
left, and hung forever when the HOST had left — the returning player sat in the
lobby and was never put into the game.

Run:  python -m pytest tests/test_world_host_handoff.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8")
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")

NL = chr(10)


def _slice(text: str, start: str, end: str, what: str) -> str:
    assert start in text, f"{what} not found"
    i = text.index(start)
    j = text.index(end, i)
    return text[i:j] + end


def lowest_active() -> str:
    return _slice(INPUT_SYNC, "function module.lowestActiveSlot()",
                  NL + "end" + NL, "lowestActiveSlot")


def on_player_left() -> str:
    return _slice(EVENT_SYNC, "local function onPlayerLeft(payload)",
                  NL + "end" + NL, "onPlayerLeft")


ENV = """
coopSlots = {}
goneSlots = {}
module = {}
runActive = true
Network = { runHostSlot = 1, isInRun = function() return true end }
DesyncLog = { event = function() end }
restartVotes = {}
notices = {}
function toast(s) notices[#notices + 1] = s end
function tallyRestartVotes() end

InputSync = {
    markGone = function(slot) goneSlots[slot] = {} end,
    lowestActiveSlot = function() return module.lowestActiveSlot() end,
}

function setRoster(t) coopSlots = {} for k, v in pairs(t) do coopSlots[k] = v end end
function leave(slot) onPlayerLeftG({ slot = slot, name = "P" .. slot }) end
"""


def lua():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(lowest_active())
    # a chunk-local: export it from INSIDE its own chunk or nothing can call it
    rt.execute(on_player_left() + NL + "onPlayerLeftG = onPlayerLeft" + NL)
    return rt


def test_lowest_active_slot_ignores_departed_players():
    rt = lua()
    rt.execute("setRoster({[1] = 1, [2] = 2, [3] = 5}); goneSlots = {}")
    assert int(rt.eval("module.lowestActiveSlot()")) == 1
    rt.execute("goneSlots[1] = {}")
    assert int(rt.eval("module.lowestActiveSlot()")) == 2
    rt.execute("goneSlots[2] = {}")
    assert int(rt.eval("module.lowestActiveSlot()")) == 5


def test_lowest_active_slot_is_nil_when_everyone_left():
    rt = lua()
    rt.execute("setRoster({[1] = 1, [2] = 2}); goneSlots = {[1] = {}, [2] = {}}")
    assert rt.eval("module.lowestActiveSlot()") is None


def test_the_world_host_leaving_promotes_the_next_player():
    """The reported bug: slot 1 was the world host, left, and nobody took over."""
    rt = lua()
    rt.execute("setRoster({[1] = 1, [2] = 2}); Network.runHostSlot = 1")
    rt.eval("leave")(1)
    assert int(rt.eval("Network.runHostSlot")) == 2, (
        "world host stayed on a slot that had left, so no machine was the world "
        "host and a late joiner could never be folded in"
    )


def test_a_non_host_leaving_does_not_move_the_world_host():
    """This case already worked; it must keep working."""
    rt = lua()
    rt.execute("setRoster({[1] = 1, [2] = 2}); Network.runHostSlot = 1")
    rt.eval("leave")(2)
    assert int(rt.eval("Network.runHostSlot")) == 1


def test_promotion_walks_down_the_roster_as_hosts_keep_leaving():
    rt = lua()
    rt.execute("setRoster({[1] = 1, [2] = 2, [3] = 3}); Network.runHostSlot = 1")
    rt.eval("leave")(1)
    assert int(rt.eval("Network.runHostSlot")) == 2
    rt.eval("leave")(2)
    assert int(rt.eval("Network.runHostSlot")) == 3


def test_the_last_player_leaving_keeps_the_slot_rather_than_clearing_it():
    """Nobody is left to promote: leave the value alone rather than blank it."""
    rt = lua()
    rt.execute("setRoster({[1] = 1}); Network.runHostSlot = 1")
    rt.eval("leave")(1)
    assert int(rt.eval("Network.runHostSlot")) == 1
