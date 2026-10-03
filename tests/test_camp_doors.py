"""A camp's door table names that camp's doors and nothing else.

`campDoors` was emptied when a run ended, not when a camp was rebuilt without one --
back to the menu and character select, then the camp again -- so the previous camp's
door uids stayed in it. Uids are recycled with every level, so one of those could name
any entity in the new camp, and pressing UP beside it would have readied or started the
run. A capture logged exactly that: `camp doors hooked: 1561=1-1(theme 1), 1567=main
exit, 1587=1-1(theme 1), 1593=main exit` -- two camps' doors at once.

Run:  python -m pytest tests/test_camp_doors.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")
NL = "\n"


def poll_source() -> str:
    start = "local function pollCampDoor()"
    i = EVENT_SYNC.index(start)
    j = EVENT_SYNC.index(NL + "end" + NL, i)
    return EVENT_SYNC[i:j] + NL + "end" + NL + "pollG = pollCampDoor" + NL


ENV = """
ENT_TYPE = { FLOOR_DOOR_MAIN_EXIT = 1, FLOOR_DOOR_STARTING_EXIT = 2 }
MASK = { FLOOR = 1 }
LAYER = { BOTH = -128 }
DesyncLog = nil
campDoors = {}
mainDoorUid = nil
doorHookPending = false
doorReadyHeld = false
hooked = {}
function hookMainDoor(door) hooked[#hooked + 1] = door end
camp = {}   -- type -> { uid, ... }
doors = {}  -- uid -> door
function get_entities_by(t) return camp[t] or {} end
function get_entity(uid) return doors[uid] end
function build(mainUid, shortcutUid)
    doors = {}
    camp = { [1] = { mainUid }, [2] = { shortcutUid } }
    doors[mainUid] = { get_target = function() return 1, 1, 1 end }
    doors[shortcutUid] = { get_target = function() return 1, 1, 1 end }
    doorHookPending = true
end
"""


def test_a_rebuilt_camp_drops_the_previous_camps_doors():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(poll_source())
    rt.execute("build(1593, 1587); pollG()")
    assert sorted(int(k) for k in rt.eval("campDoors").keys()) == [1587, 1593]
    # back to the menu and character select, then the camp again: no run ended
    rt.execute("build(1567, 1561); pollG()")
    assert sorted(int(k) for k in rt.eval("campDoors").keys()) == [1561, 1567], (
        "the previous camp's door uids are still being treated as doors"
    )
    assert int(rt.eval("mainDoorUid")) == 1567
    assert rt.eval("campDoors[1567]") is False, "the main exit"
    assert list(rt.eval("campDoors[1561]").values()) == [1, 1, 1], "the tutorial door"
