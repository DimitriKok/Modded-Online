"""Tests the callback registry — what keeps our own callbacks alive in a shared script.

Hosting a content mod puts its registrations and ours in one Playlunky script, so we
share a callback id space with it. 2.5 makes 38 bare `clear_callback()` calls, the
form that names no id and means "clear whatever is running right now". Under the shim
that could only reach the mod's own callbacks; hosted, it can reach ours, and a
two-machine capture showed it doing exactly that — the network tick, the lockstep gate
and the floor digest all died at one floor transition and the machines walked onto
different floors.

Two guarantees are tested here, because the fix has two halves:

  * a bare clear raised while one of OUR callbacks is running must be refused, while
    the same call inside the mod's own callback must still work;
  * a per-frame callback of ours that stops firing must come back — exactly once,
    never twice, because two lockstep gates would advance the frame counter twice.

Run:  python -m pytest tests/test_callbacks.py -q
"""

from __future__ import annotations

import pathlib
import textwrap

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
CALLBACKS = (PACK / "src" / "callbacks.lua").read_text(encoding="utf-8")
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")

ENGINE = """
ON = {PRE_UPDATE = 1, POST_UPDATE = 2, GAMEFRAME = 3, GUIFRAME = 4,
      PRE_LEVEL_GENERATION = 5, LEVEL = 6}
nowValue = 0
function get_ms() return nowValue end

registry = {}
nextId = 0
cleared = {}

function set_callback(fn, kind)
    nextId = nextId + 1
    registry[nextId] = {fn = fn, kind = kind}
    return nextId
end

function clear_callback(id)
    cleared[#cleared + 1] = id or "current"
    if id ~= nil then registry[id] = nil end
end

--- Fire every callback of a kind, over a snapshot: a callback may re-register
--- during the sweep, and mutating the table we are iterating is undefined.
function fire(kind, ...)
    local live = {}
    for _, entry in pairs(registry) do
        if entry.kind == kind then live[#live + 1] = entry end
    end
    for index = 1, #live do live[index].fn(...) end
    return #live
end

--- How many callbacks of a kind are registered right now.
function countKind(kind)
    local n = 0
    for _, entry in pairs(registry) do
        if entry.kind == kind then n = n + 1 end
    end
    return n
end

printed = {}
function errorf(fmt, ...) printed[#printed + 1] = tostring(fmt) end
function dbg() end
function SafeCall(name, fn, ...) local ok, r = pcall(fn, ...); return ok and r or nil end
"""

NL = chr(10)


def runtime():
    """Our Lua state with a drivable fake engine, then the registry loaded over it."""
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    # how many callbacks the module registers for its own sweeper, before ours
    rt.execute("sweeperBaseline = 0")
    rt.execute(CALLBACKS)
    return rt


# --------------------------------------------------------------------------- depth


def test_our_own_callback_is_visible_as_depth_while_it_runs():
    rt = runtime()
    rt.execute("""
seen = nil
set_callback(function() seen = Callbacks.depth() end, ON.GAMEFRAME)
fire(ON.GAMEFRAME)
""")
    assert int(rt.eval("seen")) == 1, "our callback did not register as ours"
    assert int(rt.eval("Callbacks.depth()")) == 0, "the depth did not unwind"


def test_a_hosted_callback_runs_at_depth_zero_even_from_inside_ours():
    """The mod's own bare clears must keep working exactly as they did unhosted."""
    rt = runtime()
    rt.execute("""
insideHosted, afterHosted = nil, nil
local hosted = Callbacks.hosted(function() insideHosted = Callbacks.depth() end)
set_callback(function()
    hosted()
    afterHosted = Callbacks.depth()
end, ON.GAMEFRAME)
fire(ON.GAMEFRAME)
""")
    assert int(rt.eval("insideHosted")) == 0, "the mod's callback still looked like ours"
    assert int(rt.eval("afterHosted")) == 1, "our own depth was not restored"


def test_the_lockstep_gates_return_value_survives_the_wrapper():
    """PRE_UPDATE tells 'skip this frame' by returning a value: it must come through."""
    rt = runtime()
    rt.execute("""
set_callback(function() return true end, ON.PRE_UPDATE)
held = nil
for _, entry in pairs(registry) do
    if entry.kind == ON.PRE_UPDATE and held == nil then held = entry.fn() end
end
""")
    assert rt.eval("held") is True


def test_a_callback_that_returns_nothing_still_returns_nothing():
    """Not the same as returning nil: PRE_UPDATE reads any value as 'hold the frame'."""
    rt = runtime()
    rt.execute("""
local id = set_callback(function() return end, ON.PRE_UPDATE)
returnCount = select("#", registry[id].fn())
""")
    assert int(rt.eval("returnCount")) == 0, "the wrapper turned 'nothing' into a nil"


def test_an_error_inside_our_callback_propagates_and_unwinds_the_depth():
    rt = runtime()
    rt.execute("""
local id = set_callback(function() error("boom") end, ON.GAMEFRAME)
ok, err = pcall(registry[id].fn)
""")
    assert rt.eval("ok") is False, "the wrapper swallowed an error"
    assert "boom" in str(rt.eval("err"))
    assert int(rt.eval("Callbacks.depth()")) == 0, "an error left the depth stuck high"


# -------------------------------------------------------------------------- revival


def test_a_per_frame_callback_that_stops_firing_comes_back():
    rt = runtime()
    rt.execute("""
runs = 0
nowValue = 1000
oldId = set_callback(function() runs = runs + 1 end, ON.GAMEFRAME)
fire(ON.GAMEFRAME)
registry[oldId] = nil          -- what a hosted mod's bare clear does to us
nowValue = 7000
healed, names = Callbacks.sweep()
fire(ON.GAMEFRAME)
""")
    assert int(rt.eval("healed")) == 1
    assert "GAMEFRAME" in str(rt.eval("names"))
    assert int(rt.eval("runs")) == 2, "the revived callback did not run again"


def test_reviving_never_leaves_two_registrations():
    """Two lockstep gates would advance the frame counter twice: a guaranteed desync."""
    rt = runtime()
    rt.execute("""
runs = 0
nowValue = 1000
set_callback(function() runs = runs + 1 end, ON.PRE_UPDATE)
fire(ON.PRE_UPDATE)
nowValue = 7000                -- still registered, merely idle
Callbacks.sweep()
ours = countKind(ON.PRE_UPDATE)
runs = 0
fire(ON.PRE_UPDATE)
""")
    # the sweeper's own PRE_UPDATE registration is there too, hence 2 not 1
    assert int(rt.eval("ours")) == 2, "a revive left a duplicate registration"
    assert int(rt.eval("runs")) == 1, "the callback ran twice after a revive"
    assert "current" not in [str(v) for v in rt.eval("cleared").values()], \
        "the revive cleared by 'currently running' instead of by id"


def test_a_dead_gate_is_caught_in_a_third_of_a_second_not_five():
    """Five seconds of ungated simulation is ~300 frames of each machine driving only
    its own player -- which is the desync that was reported as 'one player moved
    before the other loaded in'."""
    rt = runtime()
    rt.execute("""
runs = 0
nowValue = 1000
gateId = set_callback(function() runs = runs + 1 end, ON.PRE_UPDATE)
fire(ON.PRE_UPDATE)
Callbacks.sweep()              -- baseline the sweeper's own clock
registry[gateId] = nil         -- the gate dies
nowValue = 1200
Callbacks.sweep()              -- 200ms: too soon, and the sweeper is keeping up
tooSoon = Callbacks.sweep()
nowValue = 1400
healed, names = Callbacks.sweep()
""")
    assert int(rt.eval("tooSoon")) == 0, "revived a callback that was 200ms quiet"
    assert int(rt.eval("healed")) == 1, "the gate was not revived inside 400ms"
    assert "PRE_UPDATE" in str(rt.eval("names"))


def test_a_kind_that_legitimately_pauses_keeps_its_loose_budget():
    """GAMEFRAME stops whenever the simulation does -- a held gate, a fade."""
    rt = runtime()
    rt.execute("""
nowValue = 1000
local id = set_callback(function() end, ON.GAMEFRAME)
fire(ON.GAMEFRAME)
Callbacks.sweep()
nowValue = 1200
Callbacks.sweep()
nowValue = 1400
healed = Callbacks.sweep()
""")
    assert int(rt.eval("healed")) == 0, "revived GAMEFRAME on a 400ms pause"


def test_the_sweepers_own_absence_is_never_read_as_a_callback_dying():
    """A 4,000-entity level generation blocks every callback, ours included. Judging
    on that evidence would revive live callbacks on every floor."""
    rt = runtime()
    rt.execute("""
nowValue = 1000
set_callback(function() end, ON.PRE_UPDATE)
fire(ON.PRE_UPDATE)
Callbacks.sweep()
nowValue = 9000                -- eight seconds inside level generation
duringLoad = Callbacks.sweep()
nowValue = 9100                -- and the pass right after it
afterLoad = Callbacks.sweep()
""")
    assert int(rt.eval("duringLoad")) == 0, "our own absence was read as a death"
    assert int(rt.eval("afterLoad")) == 0, "the fresh window was not granted"


def test_a_revived_callback_is_named_by_where_it_was_defined():
    """Six of our registrations are PRE_UPDATE; 'PRE_UPDATE' alone names none of them."""
    rt = runtime()
    rt.execute("""
nowValue = 1000
local id = set_callback(function() end, ON.PRE_UPDATE)
fire(ON.PRE_UPDATE)
Callbacks.sweep()
registry[id] = nil
nowValue = 1200
Callbacks.sweep()
nowValue = 1400
healed, names = Callbacks.sweep()
""")
    names = str(rt.eval("names"))
    assert names.startswith("PRE_UPDATE "), names
    assert ":" in names.split("PRE_UPDATE ", 1)[1],         "no source location, so the log cannot tell the gate from a breadcrumb"


def test_an_occasional_callback_is_never_swept():
    """Level generation fires per floor; silence there proves nothing."""
    rt = runtime()
    rt.execute("""
nowValue = 1000
set_callback(function() end, ON.PRE_LEVEL_GENERATION)
fire(ON.PRE_LEVEL_GENERATION)
nowValue = 999000
healed = Callbacks.sweep()
""")
    assert int(rt.eval("healed")) == 0


def test_a_callback_that_has_never_run_is_not_revived():
    """At load nothing has fired yet; that is not evidence of a teardown."""
    rt = runtime()
    rt.execute("""
set_callback(function() end, ON.GAMEFRAME)
nowValue = 999000
healed = Callbacks.sweep()
""")
    assert int(rt.eval("healed")) == 0


def test_the_sweeper_holds_off_until_a_run_is_live():
    rt = runtime()
    rt.execute("""
nowValue = 1000
runs = 0
set_callback(function() runs = runs + 1 end, ON.GAMEFRAME)
fire(ON.GAMEFRAME)
registry[999] = nil
nowValue = 7000
fire(ON.GUIFRAME)              -- drives sweepTick; no Network global yet
sweptWhileIdle = #cleared
Network = { isInRun = function() return true end }
fire(ON.GUIFRAME)
""")
    assert int(rt.eval("sweptWhileIdle")) == 0, "the sweeper ran outside a run"


# ------------------------------------------------------------------ with the host


@pytest.fixture
def hosted_runtime(tmp_path, monkeypatch):
    """The registry and the mod host together — where the bare-clear rule lives."""
    root = tmp_path / "Mods" / "Packs" / "fake.mod"
    (root / "src").mkdir(parents=True)
    monkeypatch.chdir(tmp_path)
    (root / "main.lua").write_text(textwrap.dedent("""
        MOD_LOADED = true
    """), encoding="utf-8")

    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(CALLBACKS)
    rt.execute('packRoot = "."')
    rt.execute('function PackPath(n) return packRoot .. "/" .. n end')
    rt.execute(MOD_HOST)
    rt.execute("report = {callbacks = {}}")
    rt.execute("env = ModHost.newSandbox(report, {inert = false, determinism = false})")
    return rt


def test_a_bare_clear_from_the_mod_reaches_the_engine_normally(hosted_runtime):
    rt = hosted_runtime
    rt.execute("env.clear_callback()")
    assert [str(v) for v in rt.eval("cleared").values()] == ["current"]
    assert rt.eval("report.refusedBare") is None


def test_a_bare_clear_raised_while_our_callback_runs_is_refused(hosted_runtime):
    """The exact failure: a floor transition destroying the gate and the net tick."""
    rt = hosted_runtime
    rt.execute("""
set_callback(function() env.clear_callback() end, ON.GAMEFRAME)
fire(ON.GAMEFRAME)
""")
    assert len(rt.eval("cleared")) == 0, "a bare clear from the mod destroyed ours"
    assert int(rt.eval("report.refusedBare")) == 1
    assert any("refused a bare" in str(v) for v in rt.eval("printed").values()), \
        "the refusal was silent"


def test_the_mods_own_callback_may_still_clear_itself_bare(hosted_runtime):
    """Refusing that too would break the mod's own teardown."""
    rt = hosted_runtime
    rt.execute("""
env.set_callback(function() env.clear_callback() end, ON.GAMEFRAME)
fire(ON.GAMEFRAME)
""")
    assert [str(v) for v in rt.eval("cleared").values()] == ["current"]
    assert rt.eval("report.refusedBare") is None


def test_the_mods_registrations_are_not_in_our_revival_book(hosted_runtime):
    """Reviving the mod's callbacks behind its back would undo its own teardown."""
    rt = hosted_runtime
    rt.execute("""
nowValue = 1000
modRuns = 0
local id = env.set_callback(function() modRuns = modRuns + 1 end, ON.GAMEFRAME)
fire(ON.GAMEFRAME)
registry[id] = nil             -- the mod tears its own hook down
nowValue = 7000
healed = Callbacks.sweep()
fire(ON.GAMEFRAME)
""")
    assert int(rt.eval("healed")) == 0, "we revived a callback the mod had retired"
    assert int(rt.eval("modRuns")) == 1

def test_the_wrapper_still_calls_through_with_profiling_on():
    """Profiling is on by default now, so this path is the one every callback takes
    on every frame -- not the cheap one it used to be."""
    rt = runtime()
    rt.execute("""
ran = 0
set_callback(function() ran = ran + 1 end, ON.GAMEFRAME)
fire(ON.GAMEFRAME)
""")
    assert int(rt.eval("ran")) == 1, "the wrapper stopped calling through"


def test_the_wrapper_costs_little_enough_to_leave_in():
    """Measured rather than assumed: 12 per-frame callbacks over 20,000 frames is
    about five minutes of play, and the wrapper has to disappear into the noise."""
    import time
    rt = runtime()
    rt.execute("""
for i = 1, 12 do set_callback(function() end, ON.GAMEFRAME) end
wrapped = {}
for _, e in pairs(registry) do wrapped[#wrapped + 1] = e.fn end
bare = function() end
function benchWrapped(n)
    for i = 1, n do for j = 1, #wrapped do wrapped[j]() end end
end
function benchBare(n)
    for i = 1, n do for j = 1, 12 do bare() end end
end
""")
    frames = 20000
    t = time.perf_counter(); rt.eval("benchBare")(frames)
    bare = time.perf_counter() - t
    t = time.perf_counter(); rt.eval("benchWrapped")(frames)
    wrapped = time.perf_counter() - t
    per_frame_ms = (wrapped - bare) / frames * 1000
    assert per_frame_ms < 0.05, (
        "the wrapper costs %.4f ms per frame, which is no longer negligible"
        % per_frame_ms)


# ------------------------------------------------------------------- profiling
#
# It was behind `mo_profile.on` and three sessions running came back with
# `profile=off`: the flag lives in the pack folder, so installing a new build takes
# it with it. And what it reported -- share of wall time -- is blind to the symptom
# it exists for. A callback costing 25ms once a second is 0.25% of the window and
# ranks below everything, while being exactly what a player feels as a stutter.


def test_profiling_needs_nobody_to_arm_it():
    assert runtime().eval("Callbacks.profiling()") is True


def test_the_off_switch_still_works(tmp_path):
    (tmp_path / "mo_profile.off").write_text("", encoding="utf-8")
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute("sweeperBaseline = 0")
    rt.globals()["PACK_DIR"] = str(tmp_path).replace("\\", "/") + "/"
    rt.execute("function PackPath(name) return PACK_DIR .. name end")
    rt.execute(CALLBACKS)
    assert rt.eval("Callbacks.profiling()") is False


def test_profiling_stays_quiet_with_no_clock_rather_than_reporting_zeros():
    """Without `get_ms` every measurement is 0, and a report of all zeros reads as
    "nothing costs anything" when it means "nothing was measured"."""
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute("sweeperBaseline = 0")
    rt.execute("get_ms = nil")
    rt.execute(CALLBACKS)
    assert rt.eval("Callbacks.profiling()") is False


def _profiled_report(rt):
    """Drive enough frames to cross one ten-second reporting window."""
    rt.execute("""
lines = {}
DesyncLog = { event = function(fmt, ...)
    lines[#lines + 1] = string.format(fmt, ...)
end }

-- Six callbacks that are steadily expensive: 1ms each, every frame. These fill the
-- top of the ranking, which is the whole point -- the spiky one must be found
-- WITHOUT being in it. On six separate lines on purpose: callbacks are named by
-- where they were defined, so a loop would make these ONE entry of six calls.
set_callback(function() nowValue = nowValue + 1 end, ON.GAMEFRAME)
set_callback(function() nowValue = nowValue + 1 end, ON.GAMEFRAME)
set_callback(function() nowValue = nowValue + 1 end, ON.GAMEFRAME)
set_callback(function() nowValue = nowValue + 1 end, ON.GAMEFRAME)
set_callback(function() nowValue = nowValue + 1 end, ON.GAMEFRAME)
set_callback(function() nowValue = nowValue + 1 end, ON.GAMEFRAME)

-- ...and one that is free almost always and ruinous occasionally.
hits = 0
set_callback(function()
    hits = hits + 1
    if hits % 300 == 0 then nowValue = nowValue + 25 end
end, ON.GAMEFRAME)

for _ = 1, 1200 do
    nowValue = nowValue + 8
    fire(ON.GAMEFRAME)
end
""")
    return list(rt.eval("lines").values())


def test_the_frame_line_says_whether_frames_are_hitching_at_all():
    lines = [l for l in _profiled_report(runtime()) if l.startswith("PROFILE frames=")]
    assert lines, "no frame-timing line was ever emitted"
    # the spike frame is 8ms of engine + 6ms of steady callbacks + 25ms = 39ms
    assert "over-33ms=0" not in lines[0], (
        "a 39ms frame was not counted as a hitch: %s" % lines[0])


def test_a_rare_expensive_callback_is_surfaced_though_its_average_is_tiny():
    spikes = [l for l in _profiled_report(runtime()) if l.startswith("PROFILE SPIKE")]
    assert spikes, (
        "the callback that costs 25ms once every 300 frames was never reported -- "
        "it is 0.25% of the window, so ranking by average buries it")
    assert "worst   25ms" in spikes[0], spikes[0]
