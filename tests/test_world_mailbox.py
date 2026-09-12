"""Tests the four bytes of engine state that carry Spelunky 2.5's own world from
the machine that walked through the door to the machine that was warped in.

Why a mailbox at all: 2.5 advances its world ONLY on a door (DoorLib ->
onSp25WorldTransition), and a player folded into a run in progress is warped, never
walks through one. Their copy stays on the world they left, the party's has moved
on, and the two machines install different world hooks over one seed — 1-1's music
playing on 2-1, and `gen[post]` diverging while `gen[pre]` matches.

It cannot be derived locally (2.5's SP25_WORLD table does not invert — several of its
custom worlds share one engine theme inside a tier) and Playlunky gives two packs no
channel: no `package`, no `io` for a mod that is not `unsafe`, and `user_data`
belongs to the script that wrote it. `state.arena.player_lives` is arena-match
scratch that means nothing during an adventure run, so it carries the handoff.

The halves live in different Lua states and different files, so the first test here
is the one that matters most: they must agree on the bytes.

Run:  python -m pytest tests/test_world_mailbox.py -q
"""

from __future__ import annotations

import pathlib
import re

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
INJECTOR = (PACK / "src" / "shimInjector.lua").read_text(encoding="utf-8")
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")

NL = chr(10)


def live_payload() -> str:
    head = 'local SHIM = "-- " .. MARKER .. [['
    i = INJECTOR.index(head)
    return INJECTOR[i + len(head):INJECTOR.index(NL + "]]" + NL, i)]


LIVE = live_payload()


def shim_side() -> str:
    """The mailbox half that runs inside the mod's Lua state, with its locals out."""
    a = LIVE.index("    local MO_BOX_PUB")
    b = LIVE.index("    MO_CONTENT_WORLD = moContentWorldState")
    body = LIVE[a:b]
    # moSyncWorldMailbox is assigned to a forward-declared local up in the block
    body = "    local moWorldObj, moWorldAdopts = nil, 0" + NL + body
    return body + NL.join([
        "", "sync = moSyncWorldMailbox", "buildIndex = moBuildWorldIndex",
        "worldIds = function() return moWorldIds end",
        "adopts = function() return moWorldAdopts end",
        "setGame = function(g) moWorldObj = g end",
        "PUB, REQ = MO_BOX_PUB, MO_BOX_REQ", "",
    ])


def pack_side() -> str:
    """The mailbox half that runs in our own pack."""
    a = EVENT_SYNC.index("local MAILBOX_PUB")
    b = EVENT_SYNC.index("-- ------------------------------------------------------"
                         "-------- state sync")
    return EVENT_SYNC[a:b] + NL.join([
        "", "read = mailboxRead", "write = mailboxWrite",
        "PUB, REQ = MAILBOX_PUB, MAILBOX_REQ", "",
    ])


ARENA = """
arena_bytes = {0, 0, 0, 0}
function get_local_state()
    return {arena = {player_lives = arena_bytes}}
end
"""

# 2.5's own shape: a global id table of strings, and one game object per launch
MOD = """
SP25_WORLD_ID = {
    ANY = "*", NONE = "NO-WORLD-VALUE", DWELLING = "SP25-DWELL",
    JUNGLE = "SP25-JUNG", VOLCANA = "SP25-VOLC", TEMPLE = "SP25-TEMPL",
    SWAMP = "SP25-SWAMP", TIDE_POOL = "SP25-TIDEPOOL",
}
function game(world, counter)
    return {
        sp25World = world, spelunky2World = counter,
        clearTransitionRoute = function(self)
            self.transitionFromSp25World = nil
            self.transitionToSp25World = nil
            self.cleared = (self.cleared or 0) + 1
        end,
    }
end
"""


def mod_state(world="SP25-DWELL", counter=1):
    """A runtime holding the shim half, standing in a given world."""
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("printed = {}; function print(s) printed[#printed+1] = s end")
    rt.execute(ARENA)
    rt.execute(MOD)
    rt.execute(shim_side())
    rt.execute(f'g = game("{world}", {counter}); setGame(g)')
    return rt


def pack_state(rt=None):
    """The pack half. Share `rt` to put both halves on one machine's arena bytes."""
    if rt is None:
        rt = lupa.LuaRuntime(unpack_returned_tuples=True)
        rt.execute(ARENA)
    rt.execute(pack_side())
    return rt


def bytes_of(rt):
    return [int(v) for v in rt.eval("arena_bytes").values()]


def test_both_halves_agree_on_the_bytes():
    """They live in different Lua states; nothing but this test couples them."""
    shim, pack = mod_state(), pack_state()
    assert int(shim.eval("PUB")) == int(pack.eval("PUB")) == 0xA5
    assert int(shim.eval("REQ")) == int(pack.eval("REQ")) == 0x5A
    # and on the guard byte, spelled out independently in each file
    assert "(index + counter * 31) % 256" in EVENT_SYNC
    assert "(idx + s2 * 31) % 256" in LIVE


def test_the_mod_publishes_the_world_it_holds():
    rt = mod_state("SP25-JUNG", 2)
    rt.eval("sync")()
    tag, index, counter, guard = bytes_of(rt)
    assert tag == 0xA5
    assert counter == 2
    assert guard == (index + 2 * 31) % 256
    ids = [str(v) for v in rt.eval("worldIds()").values()]
    assert ids[index - 1] == "SP25-JUNG"


def test_every_machine_numbers_the_worlds_the_same_way():
    """pairs order is not stable across Lua states - that is what desynced randomizer."""
    a, b = mod_state("SP25-JUNG", 2), mod_state("SP25-JUNG", 2)
    b.execute("""
-- same ids, rebuilt in a different insertion order
SP25_WORLD_ID = {}
for _, v in ipairs({"SP25-TIDEPOOL", "*", "SP25-VOLC", "SP25-TEMPL",
                    "NO-WORLD-VALUE", "SP25-SWAMP", "SP25-JUNG", "SP25-DWELL"}) do
    SP25_WORLD_ID[v] = v
end
""")
    a.eval("sync")()
    b.eval("sync")()
    assert bytes_of(a) == bytes_of(b)


def test_the_party_world_is_adopted():
    """The fix: a folded-in player takes the world of the machine that took the door."""
    party = mod_state("SP25-JUNG", 2)
    party.eval("sync")()
    _, index, counter, _ = bytes_of(party)

    joiner = mod_state("SP25-DWELL", 1)                 # left in world one
    pack_state(joiner)
    joiner.eval("write")(joiner.eval("REQ"), index, counter)
    joiner.eval("sync")()
    assert str(joiner.eval("g.sp25World")) == "SP25-JUNG"
    assert int(joiner.eval("g.spelunky2World")) == 2
    assert int(joiner.eval("adopts()")) == 1
    assert int(joiner.eval("g.cleared or 0")) == 1, "the stale transition route was kept"


def test_the_request_is_consumed_so_it_cannot_be_adopted_twice():
    joiner = mod_state("SP25-DWELL", 1)
    pack_state(joiner)
    joiner.eval("write")(joiner.eval("REQ"), 3, 2)
    joiner.eval("sync")()
    assert bytes_of(joiner)[0] == 0xA5, "the request was left standing"
    before = int(joiner.eval("adopts()"))
    joiner.eval("sync")()
    joiner.eval("sync")()
    assert int(joiner.eval("adopts()")) == before


def test_a_machine_already_there_adopts_nothing():
    """Every machine writes the request, including the one that sent the value."""
    host = mod_state("SP25-JUNG", 2)
    pack_state(host)
    host.eval("sync")()
    _, index, counter, _ = bytes_of(host)
    host.eval("write")(host.eval("REQ"), index, counter)
    host.eval("sync")()
    assert int(host.eval("adopts()")) == 0
    assert str(host.eval("g.sp25World")) == "SP25-JUNG"
    assert list(host.eval("printed").values()) == []


def test_foreign_bytes_are_not_read_as_a_request():
    """An arena match, or anything else, may leave numbers in those four bytes."""
    joiner = mod_state("SP25-DWELL", 1)
    joiner.execute("arena_bytes = {0x5A, 4, 2, 99}")     # guard byte does not match
    joiner.eval("sync")()
    assert str(joiner.eval("g.sp25World")) == "SP25-DWELL"
    assert int(joiner.eval("adopts()")) == 0


def test_an_index_outside_the_list_is_refused():
    joiner = mod_state("SP25-DWELL", 1)
    pack_state(joiner)
    joiner.eval("write")(joiner.eval("REQ"), 200, 2)     # correct guard, silly index
    joiner.eval("sync")()
    assert str(joiner.eval("g.sp25World")) == "SP25-DWELL"
    assert int(joiner.eval("adopts()")) == 0


def test_the_pack_only_relays_a_published_value():
    """It must never interpret index bytes, or forward a request it wrote itself."""
    rt = pack_state()
    rt.execute("arena_bytes = {0x5A, 4, 2, (4 + 2 * 31) % 256}")
    box = rt.eval("read()")
    assert int(box[1]) == 0x5A, "read is not reporting the tag it found"
    # the capture side gates on the PUB tag, spelled out in eventSync
    assert "box[1] == MAILBOX_PUB and box[2] > 0" in EVENT_SYNC
    assert "snap.meta.cw = { box[2], box[3] }" in EVENT_SYNC


def test_a_build_without_arena_state_degrades_instead_of_erroring():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("function get_local_state() return {} end")
    pack_state(rt)
    assert rt.eval("read()") is None
    assert rt.eval("write")(0xA5, 1, 1) is False


def test_the_mod_half_does_nothing_before_an_instance_is_captured():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("printed = {}; function print(s) printed[#printed+1] = s end")
    rt.execute(ARENA)
    rt.execute(MOD)
    rt.execute(shim_side())
    rt.eval("sync")()
    assert bytes_of(rt) == [0, 0, 0, 0]


def test_a_mod_with_no_world_ids_is_left_alone():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("printed = {}; function print(s) printed[#printed+1] = s end")
    rt.execute(ARENA)
    rt.execute(shim_side())
    rt.execute("setGame({sp25World = 1, spelunky2World = 1})")
    rt.eval("sync")()
    assert rt.eval("buildIndex()") is False
    assert bytes_of(rt) == [0, 0, 0, 0]


def test_the_handoff_is_written_on_every_machine_and_logged_once():
    """Both properties are structural, in the apply path in eventSync."""
    i = EVENT_SYNC.index("if type(meta.cw) == \"table\" then")
    block = EVENT_SYNC[i:i + 900]
    assert "mailboxWrite(MAILBOX_REQ, index, counter)" in block
    assert "worldHandoffLogged ~= index" in block
    # and the guard is dropped whenever a new snapshot lands
    assert len(re.findall(r"worldHandoffLogged = nil", EVENT_SYNC)) >= 5


def test_the_adopt_happens_before_the_mod_installs_its_hooks():
    """newLevelHooks drops every hook and installs the set for sp25World, so the
    wrapper has to adopt before delegating or the floor gets the wrong hooks."""
    i = LIVE.index("cls.newLevelHooks = function(self, ...)")
    body = LIVE[i:LIVE.index("moWorldHooked = true", i)]
    assert body.index("moSyncWorldMailbox()") < body.index("return moRealNewLevelHooks")


def test_it_is_wired_to_every_stage_of_a_floor():
    for event in ("ON.PRE_LOAD_SCREEN", "ON.LOADING", "ON.PRE_LEVEL_GENERATION",
                  "ON.POST_LEVEL_GENERATION"):
        assert f"moRealSetCallback(moSyncWorldMailbox, {event})" in LIVE
