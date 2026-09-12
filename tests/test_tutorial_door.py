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
import sys

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


def started(rt, env, dest):
    """startDoor returns `recognised` plus, when it is false, WHY -- lupa gives that
    back as a tuple. The reason is the whole point of the second value: a silent
    `false` is what made this bug cost an evening."""
    out = adapter(rt)["startDoor"](env, dest)
    return out if isinstance(out, tuple) else (out, None)


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
    assert started(rt, env, dest)[0] is True
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 2


def test_the_main_exit_does_not_start_the_tutorial():
    """The main exit sends no destination at all. Starting a normal run must never
    be mistaken for the tutorial door."""
    rt = runtime()
    env = hdmod_env(rt)
    hit, why = started(rt, env, None)
    assert hit is False
    assert "main exit" in str(why)
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 1


def test_a_different_camp_door_does_not_start_the_tutorial():
    """A real shortcut door goes deeper; it must be left alone."""
    rt = runtime()
    env = hdmod_env(rt, door_uid=77, target=(1, 1, 1))
    dest = rt.eval("(function() return {4, 1, 8} end)")()
    hit, why = started(rt, env, dest)
    assert hit is False
    assert "4-1" in str(why), "the reason has to name both doors to be worth logging"
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 1


def test_a_camp_with_no_tutorial_door_is_left_alone():
    """DOOR_TUTORIAL_UID is set when the camp generates; before that there is none."""
    rt = runtime()
    env = hdmod_env(rt)
    env["camplib"]["DOOR_TUTORIAL_UID"] = None
    dest = rt.eval("(function() return {1, 1, 1} end)")()
    assert started(rt, env, dest)[0] is False


def test_restarting_inside_the_tutorial_stays_in_the_tutorial():
    """An instant restart re-sends the door the run began at -- the server keeps it on
    the room -- but by then the camp is gone and DOOR_TUTORIAL_UID names a dead
    entity. Reading the target is only possible while the camp is up; comparing
    against it is not, so the two are separated."""
    rt = runtime()
    env = hdmod_env(rt, door_uid=77, target=(1, 1, 1))
    dest = rt.eval("(function() return {1, 1, 1} end)")()
    assert started(rt, env, dest)[0] is True          # from the camp
    env["worldlib"]["HD_WORLDSTATE_STATE"] = 1
    rt.execute("doors[77] = nil")                     # ...the camp is torn down
    assert started(rt, env, dest)[0] is True, "a restart fell out of the tutorial"
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 2


def test_a_remembered_door_still_does_not_match_a_different_destination():
    """The remembered target is a target, not a licence: a normal run restarted after
    a tutorial must not be dragged back into it."""
    rt = runtime()
    env = hdmod_env(rt, door_uid=77, target=(1, 1, 1))
    tutorial = rt.eval("(function() return {1, 1, 1} end)")()
    assert started(rt, env, tutorial)[0] is True
    env["worldlib"]["HD_WORLDSTATE_STATE"] = 1
    rt.execute("doors[77] = nil")
    assert started(rt, env, None)[0] is False
    assert started(rt, env, rt.eval("(function() return {4, 1, 8} end)")())[0] is False
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 1


def test_a_door_entity_that_has_gone_is_survived():
    """Nothing here may throw during run_start. No camp was ever read here, so there
    is nothing remembered to fall back on either."""
    rt = runtime()
    env = hdmod_env(rt, door_uid=77)
    rt.execute("doors[77] = nil")
    dest = rt.eval("(function() return {1, 1, 1} end)")()
    assert started(rt, env, dest)[0] is False


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


# ------------------------------------------- what made this invisible for a session


def test_the_adapter_is_detected_before_the_mod_has_a_camplib():
    """Detection runs ONCE, right after the mod's main chunk (`ModHost.host`). It used
    to demand `camplib` in the same breath as `worldlib`, so a global assigned any
    later than that made the adapter invisible for the whole session -- and an
    adapter that never matched looks exactly like one that matched and did nothing."""
    rt = runtime()
    env = hdmod_env(rt)
    env["camplib"] = None
    assert adapter(rt)["detect"](env) is True


def test_a_mod_with_no_camplib_yet_says_so_instead_of_failing_silently():
    rt = runtime()
    env = hdmod_env(rt)
    env["camplib"] = None
    dest = rt.eval("(function() return {1, 1, 1} end)")()
    hit, why = started(rt, env, dest)
    assert hit is False
    assert "camplib" in str(why)


def test_reassert_puts_the_state_back_after_something_clears_it():
    """startDoor has to run at run_start, while the camp door still exists. The mod's
    own load and reset callbacks run between that and generation -- hdmod's camp
    setup writes HD_WORLDSTATE_STATE = NORMAL -- so the state has to be re-applied at
    the last point before the world is built."""
    rt = runtime()
    env = hdmod_env(rt)
    dest = rt.eval("(function() return {1, 1, 1} end)")()
    assert started(rt, env, dest)[0] is True
    env["worldlib"]["HD_WORLDSTATE_STATE"] = 1     # hdmod's camp setup, after us
    note = adapter(rt)["reassert"](env)
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 2
    assert "CLEARED" in str(note), "a capture has to say the re-apply was needed"


def test_reassert_reports_when_nothing_had_touched_the_state():
    """The other half of the measurement: if it was still set, hypothesis 2 is dead
    and the next person need not chase it."""
    rt = runtime()
    env = hdmod_env(rt)
    dest = rt.eval("(function() return {1, 1, 1} end)")()
    assert started(rt, env, dest)[0] is True
    note = adapter(rt)["reassert"](env)
    assert "already set" in str(note)
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 2


def test_reassert_never_invents_a_tutorial_on_a_mod_it_cannot_read():
    rt = runtime()
    plain = rt.eval("(function() return {} end)")()
    assert adapter(rt)["reassert"](plain) is None


# ------------------------------------------------------------------ the wiring


def test_the_host_remembers_which_adapters_recognised_the_door():
    assert "module.startDoorHits = hits" in MOD_HOST
    assert "function module.reassertStartDoor()" in MOD_HOST
    assert "function module.forgetStartDoor()" in MOD_HOST


def test_every_dispatch_outcome_is_logged_not_just_a_hit():
    """This ran silent for a whole debugging session. A dispatch that happened and
    found nothing has to be distinguishable from one that never happened."""
    at = MOD_HOST.index("function module.runStartedFromDoor(dest)")
    body = MOD_HOST[at:at + 4000]
    assert "module.startDoorNote" in body
    assert "DesyncLog" in body, "the evidence has to reach the desync log"


def test_the_reassert_runs_before_the_level_is_built():
    at = EVENT_SYNC.index("ModHost.reassertStartDoor")
    gen = EVENT_SYNC.index("ON.PRE_LEVEL_GENERATION", at)
    assert at < gen


def test_the_reassert_is_confined_to_the_runs_first_floor():
    """levelOrdinal 0 is the window between run_start and the first floor engaging.
    Re-applying a tutorial on floor 3 would be a bug of its own."""
    at = EVENT_SYNC.index("ModHost.reassertStartDoor")
    line = EVENT_SYNC[EVENT_SYNC.rindex(NL, 0, at):at]
    assert "levelOrdinal == 0" in line


def test_a_recognised_door_does_not_survive_into_the_next_run():
    """The hits re-apply on every generation while levelOrdinal is 0, so one left
    behind would drop the NEXT run into the tutorial."""
    at = EVENT_SYNC.index("local function clearRunState(reason)")
    body = EVENT_SYNC[at:at + 3000]
    assert "ModHost.forgetStartDoor" in body


def test_the_main_exit_and_a_door_to_1_1_are_different_choices():
    """They shared the "1-1" label, so everyoneSameDest called them agreement and
    pressing one while readied at the other read as un-readying."""
    at = EVENT_SYNC.index("local function destLabel(dest)")
    body = EVENT_SYNC[at:at + 400]
    assert 'return "main"' in body


def test_an_out_of_date_server_is_named_rather_than_left_to_look_like_the_bug():
    """Servers before 1.0.11 discard a 1-1 door as the main exit, which is exactly
    this bug's symptom with none of this code at fault."""
    at = EVENT_SYNC.index("local startAt = payload.start")
    body = EVENT_SYNC[at:at + 2000]
    assert "out of date" in body
    assert "1.0.11" in body


# ---------------------------------------------------------------- the wire itself


def server_module():
    """The server is a separate process, and every test above passes without it. That
    is exactly how this bug survived: the adapter was correct, the dispatch was
    correct, and the destination never arrived."""
    sys.path.insert(0, str(PACK / "server"))
    try:
        import server
    finally:
        sys.path.pop(0)
    return server


def test_the_server_carries_a_door_that_leads_to_1_1():
    """THE BUG. hdmod spawns its tutorial door with
    `spawn_door(x, y, l, 1, 1, THEME.DWELLING)`, so its destination IS 1-1. The
    server discarded that as "the main door: the default start, nothing to carry" --
    so run_start carried no `start`, every machine's adapter was handed nil and
    correctly did nothing, and the tutorial door built an ordinary run."""
    assert server_module().parse_start_dest([1, 1, 1]) == [1, 1, 1]


def test_the_main_exit_is_still_distinguishable_on_the_wire():
    """What made dropping the collapse safe: the client sends NO destination for the
    main exit. pollCampDoor records `false` for FLOOR_DOOR_MAIN_EXIT and only reads
    get_target() for FLOOR_DOOR_STARTING_EXIT, so the main door arrives as an absent
    field -- never as [1, 1, theme]."""
    assert server_module().parse_start_dest(None) is None
    at = EVENT_SYNC.index("local function pollCampDoor()")
    body = EVENT_SYNC[at:at + 1800]
    assert "local dest = false" in body, "the main exit must carry no destination"
    assert "FLOOR_DOOR_STARTING_EXIT then" in body


def test_a_hostile_destination_is_still_rejected():
    """Loosening the rule must not loosen the bounds."""
    srv = server_module()
    assert srv.parse_start_dest([99, 1, 2]) is None
    assert srv.parse_start_dest([2, 1, 99]) is None
    assert srv.parse_start_dest(["a", 1, 2]) is None
    assert srv.parse_start_dest([2, 1]) is None


def test_both_halves_of_the_mod_were_bumped_together():
    """A client fix that needs a server fix is not shipped until the version says so:
    a peer on the old build would not set the tutorial state and the party would
    generate different worlds."""
    srv = (PACK / "server" / "server.py").read_text(encoding="utf-8")
    net = (PACK / "src" / "netCore.lua").read_text(encoding="utf-8")
    assert 'SERVER_VERSION = "1.0.11"' in srv
    assert 'local EXPECTED_SERVER_VERSION = "1.0.11"' in net
