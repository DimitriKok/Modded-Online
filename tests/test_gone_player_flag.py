"""No white flag left flying where a player crashed or left.

In local co-op, which is how Modded Online runs every machine, the engine flies a
white flag (FX_LEADER_FLAG) over the LEADER, the player its camera follows, and
hands it on only when that player dies. A player who crashes or leaves mid-run is
kept in the party alive and hidden, frozen where they were, so the simulation stays
the same on every machine. When that player was the leader, the flag stayed behind
over nothing at the spot they were last -- and the game looked as if it still had
two players. The flag is now hidden there, and hidden altogether once one player is
left (a party of one is a single-player game, which has no flag), alongside the
off-screen indicators the same pass already hid.

Run:  python -m pytest tests/test_gone_player_flag.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")


def chunk(start: str, end: str) -> str:
    i = INPUT_SYNC.index(start)
    return INPUT_SYNC[i:INPUT_SYNC.index(end, i)]


def extract(start: str) -> str:
    i = INPUT_SYNC.index(start)
    return INPUT_SYNC[i:INPUT_SYNC.index("\nend\n", i) + len("\nend\n")]


ENGINE = """
ENT_TYPE = { FX_LEADER_FLAG = 684, FX_PLAYERINDICATOR = 680, FX_PLAYERINDICATORPORTRAIT = 681 }
ENT_FLAG = { INVISIBLE = 1 }
function set_flag(flags, bit) return flags | (1 << (bit - 1)) end
function test_flag(flags, bit) return flags & (1 << (bit - 1)) ~= 0 end
entities, nextUid = {}, 100
function spawn(kind, x, y, layer, overlay)
    nextUid = nextUid + 1
    local e = { uid = nextUid, kind = kind, x = x, y = y, layer = layer or 0, flags = 0,
                overlay = overlay }
    entities[nextUid] = e
    return e
end
function get_entity(uid) return entities[uid] end
function get_entities_by_type(...)
    local want, out = {}, {}
    for _, t in ipairs({ ... }) do want[t] = true end
    for uid = 101, nextUid do
        local e = entities[uid]
        if e ~= nil and want[e.kind] then out[#out + 1] = uid end
    end
    return out
end
function get_position(uid)
    local e = entities[uid]
    local x, y = e.x, e.y
    if e.overlay ~= nil then x, y = x + e.overlay.x, y + e.overlay.y end
    return x, y, e.layer
end
players = {}
function get_player(i) return players[i] end
module = {}
active = true
coopSlots, goneSlots = {}, {}
Network = { isInRun = function() return true end }
"""


def runtime(slots=(1, 2)):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(extract("function module.activePlayers()"))
    rt.execute(chunk("local LEADER_FLAG = ENT_TYPE.FX_LEADER_FLAG",
                     "--- The unreliable world channel carries traffic")
               + "\nhideGoneIndicatorsG = hideGoneIndicators\n")
    for i, slot in enumerate(slots, start=1):
        rt.execute(f"coopSlots[{i}] = {slot}; players[{i}] = spawn('player', {10 * i}, 100)")
    return rt


def gone(rt, coop_index):
    rt.execute(f"goneSlots[coopSlots[{coop_index}]] = {{ seq = 3, upto = 9 }}")


def flag_on(rt, coop_index):
    return rt.eval(f"spawn(ENT_TYPE.FX_LEADER_FLAG, 0, 1, 0, players[{coop_index}])")


def hidden(rt, ent) -> bool:
    return bool(rt.eval("test_flag")(ent["flags"], 1))


def tick(rt):
    rt.eval("hideGoneIndicatorsG")()


def test_the_leaders_flag_is_not_left_where_they_crashed():
    rt = runtime()
    flag = flag_on(rt, 1)
    gone(rt, 1)
    tick(rt)
    assert hidden(rt, flag)


def test_one_player_left_has_no_flag_at_all():
    """The second player left: the one still playing holds the flag, and a party of
    one is single player."""
    rt = runtime()
    flag = flag_on(rt, 1)
    gone(rt, 2)
    tick(rt)
    assert hidden(rt, flag)


def test_with_two_still_playing_the_leaders_flag_stays():
    rt = runtime(slots=(1, 2, 3))
    flag = flag_on(rt, 1)
    gone(rt, 3)
    tick(rt)
    assert not hidden(rt, flag)


def test_with_two_still_playing_a_departed_leaders_flag_goes():
    rt = runtime(slots=(1, 2, 3))
    flag = flag_on(rt, 2)
    gone(rt, 2)
    tick(rt)
    assert hidden(rt, flag)


def test_a_flag_riding_on_something_the_departed_player_carries_goes_too():
    rt = runtime(slots=(1, 2, 3))
    held = rt.eval("spawn('held', 0, 0, 0, players[2])")
    flag = rt.eval("spawn(ENT_TYPE.FX_LEADER_FLAG, 0, 1, 0, nil)")
    flag["overlay"] = held
    gone(rt, 2)
    tick(rt)
    assert hidden(rt, flag)


@pytest.mark.parametrize("over,expect_hidden", [(2, True), (1, False)])
def test_an_unattached_flag_belongs_to_whoever_it_floats_over(over, expect_hidden):
    rt = runtime(slots=(1, 2, 3))
    flag = rt.eval(f"spawn(ENT_TYPE.FX_LEADER_FLAG, {10 * over}, 101, 0, nil)")
    gone(rt, 2)
    tick(rt)
    assert hidden(rt, flag) is expect_hidden


def test_the_departed_players_indicators_are_still_hidden():
    rt = runtime(slots=(1, 2, 3))
    gone(rt, 2)
    ind = rt.eval("spawn(ENT_TYPE.FX_PLAYERINDICATOR, 0, 0, 0, nil)")
    ind["attached_to"] = rt.eval("players[2].uid")
    mine = rt.eval("spawn(ENT_TYPE.FX_PLAYERINDICATOR, 0, 0, 0, nil)")
    mine["attached_to"] = rt.eval("players[1].uid")
    tick(rt)
    assert hidden(rt, ind) and not hidden(rt, mine)


def test_nothing_is_touched_while_everyone_is_here():
    rt = runtime()
    flag = flag_on(rt, 1)
    tick(rt)
    assert not hidden(rt, flag)


def test_an_api_without_the_flag_skips_it():
    src = chunk("local LEADER_FLAG = ENT_TYPE.FX_LEADER_FLAG",
                "--- The unreliable world channel carries traffic")
    rt2 = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt2.execute(ENGINE.replace("FX_LEADER_FLAG = 684, ", ""))
    rt2.execute(extract("function module.activePlayers()"))
    rt2.execute(src + "\nhideGoneIndicatorsG = hideGoneIndicators\n")
    rt2.execute("coopSlots[1], coopSlots[2] = 1, 2; players[1] = spawn('player', 10, 100)"
                "; players[2] = spawn('player', 20, 100)")
    rt2.execute("goneSlots[1] = { seq = 3, upto = 9 }")
    rt2.eval("hideGoneIndicatorsG")()  # no error


def test_it_runs_every_frame():
    assert 'SafeCall("inputSync:hideGoneIndicators", hideGoneIndicators)' in INPUT_SYNC
