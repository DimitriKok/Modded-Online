"""Leaving the camp through its main exit ends hdmod's prologue, online too.

hdmod's prologue lives in the engine's `savegame.tutorial_state` (0 nothing, 1 journal
got, 2 key spawned, 3 door unlocked, 4 complete), and `camplib.is_prologue_active()`
is `tutorial_state <= 2`. hdmod never writes it: the engine moves it on when the key
unlocks the camp's main exit and the first adventure starts through it. Online that
door is inert, so neither happens and the state stayed at 2 -- every camp after the
run replayed the rope entry, dropped the journal again and kept the main door locked,
sending the party back through the tutorial. That is the reported "it still tried to
give the tutorial journal and make the player do the tutorial", and the capture shows
`prologue=true ... tutorial=2` on the death screen after a full run.

Run:  python -m pytest tests/test_prologue_exit.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")

ENV = """
ON = setmetatable({}, {__index = function() return 0 end})
function set_callback() return 1 end
function seed_prng() end
function get_adventure_seed() return 1, 2 end
function get_local_state() return {world = 1, level = 1, theme = 1, time_total = 0} end
prng = {get_pair = function() return 0, 0 end, set_pair = function() end}
function get_entity() return nil end
savegame = { tutorial_state = 2 }
logged = {}
DesyncLog = { earlyEvent = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end }
"""


def runtime(state=2):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(DETERMINISM)
    rt.execute(f"savegame.tutorial_state = {state}")
    return rt


def adapter(rt):
    for a in rt.eval("Determinism.adapters").values():
        if str(a["name"]) == "hd-prologue-exit":
            return a
    raise AssertionError("the hd-prologue-exit adapter is not registered")


def hdmod(rt, post_tutorial=False, records=0):
    return rt.eval("""
(function(post, records)
    local list = {}
    for i = 1, records do list[i] = { score = 0 } end
    return {
        worldlib = { HD_WORLDSTATE_STATUS = {NORMAL = 1, TUTORIAL = 2, TESTING = 3},
                     HD_WORLDSTATE_STATE = 1 },
        camplib = { is_post_tutorial = post, DOOR_TUTORIAL_UID = -1 },
        tutorialrecordslib = { get_tutorial_records = function() return list end },
    }
end)""")(post_tutorial, records)


def start(rt, env, dest=None):
    out = adapter(rt)["startDoor"](env, dest)
    return out if isinstance(out, tuple) else (out, None)


def state(rt) -> int:
    return int(rt.eval("savegame.tutorial_state"))


def test_the_reported_case_the_run_right_after_the_tutorial_ends_the_prologue():
    rt = runtime(2)
    hit, _ = start(rt, hdmod(rt, post_tutorial=True))
    assert hit is True
    assert state(rt) == 4, "the prologue is still active: the next camp sends them back"
    assert any("prologue 2 -> 4" in str(line) for line in rt.eval("logged").values())


def test_a_save_that_already_lost_the_key_once_is_rescued():
    """The user's save today: tutorial finished, key gone with that camp, state 2."""
    rt = runtime(2)
    hit, _ = start(rt, hdmod(rt, post_tutorial=False, records=1))
    assert hit is True and state(rt) == 4


def test_without_the_key_the_door_stays_locked():
    """Never finished the tutorial: in the game itself the main exit is still locked,
    so the prologue must carry on."""
    rt = runtime(2)
    hit, why = start(rt, hdmod(rt, post_tutorial=False, records=0))
    assert hit is False and state(rt) == 2
    assert "locked" in str(why)


def test_an_unlocked_door_completes_without_the_key():
    rt = runtime(3)
    hit, _ = start(rt, hdmod(rt))
    assert hit is True and state(rt) == 4


def test_a_prologue_before_the_key_is_left_alone():
    for early in (0, 1):
        rt = runtime(early)
        hit, why = start(rt, hdmod(rt, post_tutorial=True, records=1))
        assert hit is False and state(rt) == early
        assert "not reachable" in str(why)


def test_a_finished_prologue_is_left_alone():
    rt = runtime(4)
    hit, _ = start(rt, hdmod(rt, post_tutorial=True))
    assert hit is False and state(rt) == 4


def test_a_camp_door_is_not_the_main_exit():
    """The tutorial door (or a shortcut) starting a run must never end the prologue."""
    rt = runtime(2)
    door = rt.eval("(function() return {1, 1, 1} end)")()
    hit, why = start(rt, hdmod(rt, post_tutorial=True, records=1), door)
    assert hit is False and state(rt) == 2
    assert "main exit" in str(why)


def test_no_savegame_no_change():
    rt = runtime(2)
    rt.execute("savegame = nil")
    hit, _ = start(rt, hdmod(rt, post_tutorial=True))
    assert hit is False


def test_it_matches_hdmod_only():
    rt = runtime(2)
    assert adapter(rt)["detect"](hdmod(rt)) is True
    assert adapter(rt)["detect"](rt.eval("(function() return {} end)")()) is not True


def test_a_mod_without_tutorial_records_is_survived():
    rt = runtime(2)
    env = hdmod(rt, post_tutorial=False)
    env["tutorialrecordslib"] = None
    hit, _ = start(rt, env)
    assert hit is False and state(rt) == 2
