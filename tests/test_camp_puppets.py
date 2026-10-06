"""The other players in the camp lobby, as puppets (src/campPuppets.lua).

Each machine in the camp sends where its spelunker is and how it is posed; every
other machine in the camp draws that player there, as a picture: an item wearing the
player's character sheet, frozen and untouchable, in no player list. It must never
reach a run: puppets exist only in the camp, outside a run, and are forgotten when the
camp is torn down.

These run campPuppets (with the menu modules) against the stubbed engine in
tests/menu_stub.py, plus the entity stubs below.

Run:  python -m pytest tests/test_camp_puppets.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

from menu_stub import Engine

PACK = pathlib.Path(__file__).resolve().parent.parent
MODULES = ("menuInput", "mainMenuHook", "vanillaUI", "menuUI", "campPuppets")
ROCK = 400

PUPPET_ENV = """
ON.PRE_LEVEL_DESTRUCTION = 149
ENT_TYPE = { ITEM_ROCK = 400 }
sentWorld = {}
function Network.sendWorld(d) sentWorld[#sentWorld + 1] = d end
worldKinds = {}
function Network.onWorldKind(kind, fn) worldKinds[kind] = fn end
Network.lobbyPlayers = { { slot = 1, name = "Me" }, { slot = 2, name = "Ana" } }

entities = {}
spawned = {}
nextUid = 100
function makeEntity(uid, typeId, x, y, layer)
    return {
        uid = uid, type = { id = typeId }, x = x, y = y, layer = layer, flags = 0,
        animation_frame = 0, width = 1, height = 1, draw_depth = 0, velocityx = 0, velocityy = 0,
        set_texture = function(self, tex) self.texture = tex end,
        set_draw_depth = function(self, d) self.draw_depth = d end,
        set_pre_update_state_machine = function(self, fn) self.stateMachineHook = fn end,
        destroy = function(self) self.destroyed = true; entities[self.uid] = nil end,
        get_absolute_position = function(self) return self.x, self.y end,
    }
end
function spawn_entity_nonreplaceable(typeId, x, y, layer, _vx, _vy)
    local uid = nextUid
    nextUid = nextUid + 1
    entities[uid] = makeEntity(uid, typeId, x, y, layer)
    spawned[#spawned + 1] = uid
    return uid
end
function get_entity(uid) return entities[uid] end
function get_type(id) return { texture = 1000 + id } end
function set_flag(f, bit) return f | (1 << (bit - 1)) end
function clr_flag(f, bit) return f & ~(1 << (bit - 1)) end
function test_flag(f, bit) return (f & (1 << (bit - 1))) ~= 0 end
function screen_position(x, y) return x / 20 - 1, y / 20 - 1 end

me = makeEntity(1, 196, 10.0, 20.0, 0)
me.animation_frame, me.width, me.height, me.draw_depth = 5, 1.25, 1.25, 12
function get_player(i) if i == 1 then return me end return nil end
function SafePlayer(i) return get_player(i) end

lstate.screen = SCREEN.CAMP
Network.phase = Network.PHASE.LOBBY
"""

FLAG = {"INVISIBLE": 1, "PASSES_THROUGH_EVERYTHING": 5, "TAKE_NO_DAMAGE": 6, "NO_GRAVITY": 10,
        "COLLIDES_WALLS": 13, "FACING_LEFT": 17, "PICKUPABLE": 18, "PAUSE_AI_AND_PHYSICS": 28}


def has(flags, name):
    return (int(flags) >> (FLAG[name] - 1)) & 1 == 1


@pytest.fixture
def engine(tmp_path):
    return Engine(tmp_path, modules=MODULES, before=PUPPET_ENV)


def sample(engine, slot=2, x=12.0, y=20.0, a=7, f=0, l=0, c=194):
    engine.lua("worldKinds.pp(%d, { k = 'pp', x = %r, y = %r, a = %d, f = %d, l = %d, c = %d })"
               % (slot, x, y, a, f, l, c))


def sent(engine):
    out = []
    for i in range(1, int(engine.eval("#sentWorld")) + 1):
        d = engine.eval("sentWorld[%d]" % i)
        out.append({k: d[k] for k in ("k", "x", "y", "a", "f", "l", "c", "g") if d[k] is not None})
    return out


def puppet(engine):
    """The one puppet entity alive, or None."""
    alive = [engine.eval("entities[%d]" % uid) for uid in
             [engine.eval("spawned[%d]" % i) for i in range(1, int(engine.eval("#spawned")) + 1)]]
    alive = [e for e in alive if e is not None]
    assert len(alive) <= 1, "more than one puppet"
    return alive[0] if alive else None


# --------------------------------------------------------------- sending

def test_in_the_camp_our_spelunker_is_sent(engine):
    engine.gui()
    assert sent(engine) == [{"k": "pp", "x": 10.0, "y": 20.0, "a": 5, "f": 0, "l": 0, "c": 196}]


def test_no_faster_than_twenty_a_second(engine):
    for i in range(10):
        engine.lua("me.x = me.x + 0.1")
        engine.gui(ms=10)                   # 100 ms of display frames
    assert len(sent(engine)) == 2


def test_standing_still_only_keeps_it_alive(engine):
    for _ in range(60):
        engine.gui(ms=16)                   # about a second, nothing changing
    assert 2 <= len(sent(engine)) <= 4


def test_facing_left_is_sent(engine):
    engine.lua("me.flags = set_flag(me.flags, 17)")
    engine.gui()
    assert sent(engine)[0]["f"] == 1


@pytest.mark.parametrize("setup", [
    "lstate.screen = SCREEN.LEVEL",
    "Network.phase = Network.PHASE.INGAME",
    "Network.phase = Network.PHASE.IDLE",
])
def test_nothing_is_sent_outside_the_camp_lobby(engine, setup):
    engine.lua(setup)
    engine.gui()
    assert sent(engine) == []


def test_leaving_the_camp_says_so(engine):
    engine.gui()
    engine.lua("lstate.screen = SCREEN.LEVEL")
    engine.gui()
    assert sent(engine)[-1] == {"k": "pp", "g": 1}


# ------------------------------------------------------------- receiving

def test_a_player_heard_from_is_drawn_as_a_puppet(engine):
    sample(engine, x=12.0, y=21.0, a=9, c=198)
    engine.update()
    p = puppet(engine)
    assert p is not None and int(p.type.id) == ROCK
    assert (p.x, p.y) == (12.0, 21.0)
    assert int(p.animation_frame) == 9
    assert int(p.texture) == 1000 + 198, "not in the player's character sheet"
    assert float(p.width) == 1.25 and int(p.draw_depth) == 12, "not the size and depth of a player"


def test_a_puppet_touches_nothing(engine):
    sample(engine)
    engine.update()
    p = puppet(engine)
    for name in ("PASSES_THROUGH_EVERYTHING", "TAKE_NO_DAMAGE", "NO_GRAVITY", "PAUSE_AI_AND_PHYSICS"):
        assert has(p.flags, name), name
    for name in ("PICKUPABLE", "COLLIDES_WALLS"):
        assert not has(p.flags, name), name
    assert p.stateMachineHook() is True, "its own update still runs"


def test_it_follows_smoothly_and_snaps_across_a_teleport(engine):
    sample(engine, x=12.0)
    engine.update()
    sample(engine, x=13.0)
    engine.update()
    assert puppet(engine).x == pytest.approx(12.5)
    for _ in range(10):
        engine.update()
    assert puppet(engine).x == pytest.approx(13.0, abs=0.01)
    sample(engine, x=30.0)
    engine.update()
    assert puppet(engine).x == pytest.approx(30.0)


def test_it_faces_the_way_its_player_does(engine):
    sample(engine, f=1)
    engine.update()
    assert has(puppet(engine).flags, "FACING_LEFT")
    sample(engine, f=0)
    engine.update()
    assert not has(puppet(engine).flags, "FACING_LEFT")


def test_in_the_other_layer_it_is_out_of_sight(engine):
    sample(engine, l=1)
    engine.update()
    assert has(puppet(engine).flags, "INVISIBLE")


def test_a_player_not_heard_from_goes(engine):
    sample(engine)
    engine.update()
    engine.lua("now = now + 3100")
    engine.update()
    assert puppet(engine) is None


def test_a_player_who_left_the_room_goes(engine):
    sample(engine)
    engine.update()
    engine.lua("Network.lobbyPlayers = { { slot = 1, name = 'Me' } }")
    engine.update()
    assert puppet(engine) is None


def test_a_player_who_left_the_camp_goes_at_once(engine):
    sample(engine)
    engine.update()
    engine.lua("worldKinds.pp(2, { k = 'pp', g = 1 })")
    engine.update()
    assert puppet(engine) is None


def test_never_a_puppet_of_ourselves(engine):
    sample(engine, slot=1)
    engine.update()
    assert puppet(engine) is None


def test_an_unknown_character_is_drawn_as_ana(engine):
    sample(engine, c=9999)
    engine.update()
    assert int(puppet(engine).texture) == 1000 + 194


# --------------------------------------------------------- never in a run

def test_no_puppet_outside_the_camp(engine):
    engine.lua("lstate.screen = SCREEN.LEVEL")
    sample(engine)
    engine.update()
    assert int(engine.eval("#spawned")) == 0


def test_the_run_starting_takes_the_puppets_away_first(engine):
    """The phase goes INGAME while the camp is still up: they are destroyed there, before
    the run's first level exists."""
    sample(engine)
    engine.update()
    engine.lua("Network.phase = Network.PHASE.INGAME")
    engine.update()
    assert puppet(engine) is None


def test_no_puppet_spawns_while_the_camp_fades(engine):
    engine.lua("lstate.loading = FADE.OUT")
    sample(engine)
    engine.update()
    assert int(engine.eval("#spawned")) == 0


def test_a_torn_down_camp_leaves_no_handle_on_its_uids(engine):
    """After the level goes, a freed uid is the next level's: nothing may be written
    to whatever gets it."""
    sample(engine)
    engine.update()
    uid = int(engine.eval("spawned[1]"))
    engine.lua("runCallbacks(ON.PRE_LEVEL_DESTRUCTION)")
    engine.lua("entities[%d] = makeEntity(%d, 555, 1.0, 1.0, 0)" % (uid, uid))   # recycled
    engine.lua("lstate.screen = SCREEN.LEVEL")
    engine.update()
    recycled = engine.eval("entities[%d]" % uid)
    assert (recycled.x, recycled.y) == (1.0, 1.0) and not recycled.destroyed


def test_a_recycled_uid_is_never_mistaken_for_a_puppet(engine):
    sample(engine)
    engine.update()
    uid = int(engine.eval("spawned[1]"))
    engine.lua("entities[%d] = makeEntity(%d, 555, 1.0, 1.0, 0)" % (uid, uid))
    sample(engine, x=15.0)
    engine.update()
    recycled = engine.eval("entities[%d]" % uid)
    assert (recycled.x, recycled.y) == (1.0, 1.0), "wrote into somebody else's entity"
    assert int(engine.eval("#spawned")) == 2, "the puppet was not put back"


# -------------------------------------------------------------- name tags

def test_each_puppet_has_its_players_name_above_it(engine):
    sample(engine, x=12.0, y=20.0)
    engine.update()
    engine.gui()
    vanilla = engine.render("CAMP")
    vanilla = engine.render("CAMP")
    tags = [d for d in vanilla if d["kind"] == "text" and d["text"] == "Ana"]
    assert tags, [d.get("text") for d in vanilla]
    assert tags[-1]["y"] > (20.0 / 20 - 1), "the tag is not above the puppet"


# ------------------------------------------------------------- the wire

NET_CORE = (PACK / "src" / "netCore.lua").read_text(encoding="utf-8")


def world_branch() -> str:
    """netCore's shipped `world` branch, verbatim, as a function."""
    start = NET_CORE.index('elseif msgType == "world" then')
    end = NET_CORE.index('elseif msgType == "event_ack" then', start)
    body = NET_CORE[start:end].replace('elseif msgType == "world" then', "function onWorld(msg)", 1)
    return body + "\nend\n"


def test_a_puppet_datagram_goes_to_its_own_handler_and_the_rest_as_before():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        module = { slot = 1 }
        got = {}
        function SafeCall(_, f, ...) return f(...) end
        worldHandler = function(slot, d) got[#got + 1] = "general:" .. tostring(d.k) end
        worldKindHandlers = { pp = function(slot, d) got[#got + 1] = "pp:" .. slot end }
    """)
    rt.execute(world_branch())
    rt.execute("onWorld({ slot = 2, d = { k = 'pp' } })")
    rt.execute("onWorld({ slot = 2, d = { k = 'chk' } })")
    rt.execute("onWorld({ slot = 1, d = { k = 'pp' } })")   # our own: never
    got = [rt.eval("got[%d]" % i) for i in range(1, int(rt.eval("#got")) + 1)]
    assert got == ["pp:2", "general:chk"]
