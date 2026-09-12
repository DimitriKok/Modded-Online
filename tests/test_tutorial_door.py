"""Tests entering a hosted mod's custom camp door online.

A camp door is INERT in a networked lobby: Modded Online detects the press and
starts the run for the whole party, because letting one player walk through would
start a solo run. A mod that keys behaviour off a player physically ENTERING a
particular door therefore never sees it happen.

hdmod's tutorial is exactly that. `lib/camp/camp.lua` installs `entrance_tutorial`
as a per-frame interval watching for a player overlapping DOOR_TUTORIAL_UID in
CHAR_STATE.ENTERING, and only then sets `HD_WORLDSTATE_STATE = TUTORIAL`. Room
generation, spikes, flags and touchups all branch on that value. Online the interval
never fired, the state stayed NORMAL, and walking into the tutorial door produced an
ordinary 1-1 -- the reported "it just took us into a run".

The door's destination already travels in run_start, so each machine can match it
against ITS OWN tutorial door and set the state the mod would have set itself.

Run:  python -m pytest tests/test_tutorial_door.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")
NL = chr(10)

ENV = """
doors = {}
function get_entity(uid) return doors[uid] end
function newDoor(uid, w, l, t)
    doors[uid] = { get_target = function() return w, l, t end }
end
ON = setmetatable({}, {__index = function() return 0 end})
function set_callback() return 1 end
function seed_prng() end
function get_adventure_seed() return 1, 2 end
function get_local_state() return {world = 1, level = 1, theme = 1, time_total = 0} end
prng = {get_pair = function() return 0, 0 end, set_pair = function() end}
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(DETERMINISM)
    return rt


def adapter(rt):
    for a in rt.eval("Determinism.adapters").values():
        if str(a["name"]) == "hd-tutorial-door":
            return a
    raise AssertionError("the hd-tutorial-door adapter is not registered")


def hdmod_env(rt, door_uid=77, target=(1, 1, 1)):
    rt.execute("newDoor(%d, %d, %d, %d)" % (door_uid, *target))
    return rt.eval("""
(function(uid)
    return {
        worldlib = {
            HD_WORLDSTATE_STATUS = {NORMAL = 1, TUTORIAL = 2, TESTING = 3},
            HD_WORLDSTATE_STATE = 1,
        },
        camplib = { DOOR_TUTORIAL_UID = uid },
    }
end)""")(door_uid)


def test_the_adapter_recognises_a_mod_with_a_camp_world_state():
    rt = runtime()
    env = hdmod_env(rt)
    assert adapter(rt)["detect"](env) is True


def test_a_mod_without_that_shape_is_not_matched():
    rt = runtime()
    plain = rt.eval("(function() return {} end)")()
    assert adapter(rt)["detect"](plain) is not True


def test_entering_the_tutorial_door_sets_the_mods_world_state():
    """The whole bug: the state stays NORMAL online, so 1-1 generates as an ordinary
    level instead of the tutorial."""
    rt = runtime()
    env = hdmod_env(rt, door_uid=77, target=(1, 1, 1))
    dest = rt.eval("(function() return {1, 1, 1} end)")()
    assert adapter(rt)["startDoor"](env, dest) is True
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 2


def test_the_main_exit_does_not_start_the_tutorial():
    """The main exit sends no destination at all. Starting a normal run must never
    be mistaken for the tutorial door."""
    rt = runtime()
    env = hdmod_env(rt)
    assert adapter(rt)["startDoor"](env, None) is False
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 1


def test_a_different_camp_door_does_not_start_the_tutorial():
    """A real shortcut door goes deeper; it must be left alone."""
    rt = runtime()
    env = hdmod_env(rt, door_uid=77, target=(1, 1, 1))
    dest = rt.eval("(function() return {4, 1, 8} end)")()
    assert adapter(rt)["startDoor"](env, dest) is False
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 1


def test_a_camp_with_no_tutorial_door_is_left_alone():
    """DOOR_TUTORIAL_UID is set when the camp generates; before that there is none."""
    rt = runtime()
    env = hdmod_env(rt)
    env["camplib"]["DOOR_TUTORIAL_UID"] = None
    dest = rt.eval("(function() return {1, 1, 1} end)")()
    assert adapter(rt)["startDoor"](env, dest) is False


def test_a_door_entity_that_has_gone_is_survived():
    """Nothing here may throw during run_start."""
    rt = runtime()
    env = hdmod_env(rt, door_uid=77)
    rt.execute("doors[77] = nil")
    dest = rt.eval("(function() return {1, 1, 1} end)")()
    assert adapter(rt)["startDoor"](env, dest) is False


# ------------------------------------------------------------------ the wiring


def test_the_host_dispatches_the_door_to_matched_adapters_only():
    assert "function module.runStartedFromDoor(dest)" in MOD_HOST
    assert "adapter.startDoor" in MOD_HOST
    assert "module.controls[packDir] = report.determinism" in MOD_HOST


def test_run_start_tells_the_mods_before_it_warps():
    """The state has to be set before anything generates, or 1-1 is already built as
    an ordinary level by the time the mod is told."""
    at = EVENT_SYNC.index("ModHost.runStartedFromDoor")
    warp = EVENT_SYNC.index("moWarp(1, 1, THEME.DWELLING)", at - 4000)
    assert at < warp, "the mods are told about the door after the warp is booked"


def test_every_machine_is_told_not_just_the_host():
    """run_start is the ordered event every machine applies, which is what keeps the
    world identical -- doing this only on the host would desync generation."""
    at = EVENT_SYNC.index("ModHost.runStartedFromDoor")
    window = EVENT_SYNC[at - 1200:at]
    assert "Network.isHost" not in window
