"""The room host's pet style, kept for as long as we stay in the room.

The level's pet (dog / cat / hamster) comes from GAME_SETTING.PET_STYLE, a setting
of each machine's own, so every peer adopts the room host's for the run. Until dev78
a run ending put the peer's own back AND forgot the host's -- and the next run in
the same room started without it. The host re-broadcasts every two seconds, and a
restart builds its first floor sooner than that.

Room VOYY: the first run ended at 15:23:31 and the next 1-1 was generated at
15:23:32 -- `gen[pre] ... pet=0` on the peer, `pet=2` on the host, a MONS_PET_DOG
against a MONS_PET_HAMSTER, and a FLOOR DESYNC on the very first floor.

Run:  python -m pytest tests/test_pet_style.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")


def _block() -> str:
    start = EVENT_SYNC.index("-- ------------------------------------------------------------------ pet style")
    end = EVENT_SYNC.index("-- ------------------------------------------ save-derived generation state")
    return EVENT_SYNC[start:end]


ENV = """
module = {}
GAME_SETTING = { PET_STYLE = 7 }
setting = 0 -- this player's own: the dog
function get_setting(which) if which == GAME_SETTING.PET_STYLE then return setting end end
function set_setting(which, v) if which == GAME_SETTING.PET_STYLE then setting = v end end
now = 0
function get_ms() return now end
sent = {}
Network = {
    active = true, host = false, room = "VOYY", slot = 2,
    isActive = function() return Network.active end,
    isHost = function() return Network.host end,
    hostSlot = function() return 1 end,
    lobbyPlayers = { { slot = 1 } },
    sendEvent = function(k, p) sent[#sent + 1] = { k = k, p = p } end,
}
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    # the block's local functions, reachable from the test
    rt.execute(_block() + "\nT = { poll = pollPetStyle, onPet = onPetStyle,"
               " enforce = enforcePetStyle }\n")
    return rt


def setting(rt) -> int:
    return int(rt.eval("setting"))


def hosts_hamster(rt):
    rt.eval("T.onPet")(rt.eval("{ p = 2 }"), 1)


def test_the_host_pet_is_adopted():
    rt = runtime()
    rt.eval("T.poll")()
    hosts_hamster(rt)
    assert setting(rt) == 2


def test_a_quick_restart_in_the_same_room_still_builds_with_the_host_pet():
    """VOYY's second 1-1: the run ends, the next floor generates a second later."""
    rt = runtime()
    rt.eval("T.poll")()
    hosts_hamster(rt)
    rt.eval("module.restorePetStyle")()   # the run ended (clearRunState)
    rt.execute("setting = 0")             # anything at all that put ours back
    rt.eval("T.enforce")()                # the next run's PRE_LEVEL_GENERATION
    assert setting(rt) == 2, "the next run's first floor spawned this player's own pet"


def test_leaving_the_room_gives_the_player_their_own_pet_back():
    rt = runtime()
    rt.eval("T.poll")()
    hosts_hamster(rt)
    rt.execute("Network.active = false")
    rt.eval("T.poll")()
    assert setting(rt) == 0
    rt.eval("T.enforce")()
    assert setting(rt) == 0, "the old room's pet came back"


def test_a_run_ending_after_the_room_is_gone_gives_it_back_too():
    rt = runtime()
    rt.eval("T.poll")()
    hosts_hamster(rt)
    rt.execute("Network.active = false")
    rt.eval("module.restorePetStyle")()
    assert setting(rt) == 0


def test_another_rooms_host_is_not_followed():
    rt = runtime()
    rt.eval("T.poll")()
    hosts_hamster(rt)
    rt.execute("Network.room = 'ABCD'; setting = 0")
    rt.eval("T.enforce")()
    assert setting(rt) == 0, "followed the pet of a room we are no longer in"


def test_the_host_never_follows_anyone():
    rt = runtime()
    rt.execute("Network.host = true")
    rt.eval("T.poll")()
    hosts_hamster(rt)
    assert setting(rt) == 0


def test_the_host_still_broadcasts_on_its_cadence():
    rt = runtime()
    rt.execute("Network.host = true; setting = 1; now = 5000")
    rt.eval("T.poll")()
    rt.execute("now = 6000")
    rt.eval("T.poll")()
    rt.execute("now = 7100")
    rt.eval("T.poll")()
    kinds = [str(e["k"]) for e in rt.eval("sent").values()]
    assert kinds == ["petstyle", "petstyle"]
    assert int(rt.eval("sent[1].p.p")) == 1


def test_it_is_still_enforced_before_the_floor_is_built():
    at = EVENT_SYNC.index("local function onPreLevelGeneration()")
    body = EVENT_SYNC[at:EVENT_SYNC.index("\nend\n", at)]
    assert "enforcePetStyle()" in body
    assert body.index("enforcePetStyle()") < body.index("holdSaveSync()")
