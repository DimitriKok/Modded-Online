"""Every error that reaches Playlunky under our name also reaches the desync log.

A hosted mod runs in OUR script, so Playlunky reports its Lua errors as ours --
"Mod: fyi.modded-online-loader / Error: ..." -- and until dev77 nothing wrote them
into desync_log.txt. Room FVJF's peer got one on 4-1, `attempt to call a number value`,
and the only record of it was spelunky.log, with an empty stack. The same went for
every `errorf` line: printed for the player only with ENABLE DEBUG MESSAGES on, and
never in the log, so a capture could not say whether a teardown had been refused or a
texture skipped.

Run:  python -m pytest tests/test_error_lines.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

import test_trace_arming as trace

PACK = pathlib.Path(__file__).resolve().parent.parent
UTIL = (PACK / "src" / "util.lua").read_text(encoding="utf-8")
CALLBACKS = (PACK / "src" / "callbacks.lua").read_text(encoding="utf-8")
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")

LOG_STUB = """
logged = {}
DesyncLog = {
    earlyEvent = function(fmt, ...) logged[#logged + 1] = 'early ' .. string.format(fmt, ...) end,
    event = function(fmt, ...) logged[#logged + 1] = 'event ' .. string.format(fmt, ...) end,
    line = function(fmt, ...) logged[#logged + 1] = 'line ' .. string.format(fmt, ...) end,
}
"""


def lines(rt):
    return [str(v) for v in rt.eval("logged").values()]


# ------------------------------------------------------------------- errorf, SafeCall

def util_runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("printed = {}; function print(s) printed[#printed + 1] = s end")
    rt.execute("nowValue = 0; function get_ms() return nowValue end")
    rt.execute(UTIL)
    rt.execute(LOG_STUB)
    return rt


def test_errorf_is_printed_and_logged():
    rt = util_runtime()
    rt.execute('errorf("mod host: refused a request to clear callback %s", 11)')
    assert list(rt.eval("printed").values()) == [
        "[ModdedOnline ERROR] mod host: refused a request to clear callback 11"]
    assert lines(rt) == ["early *** ERROR: mod host: refused a request to clear callback 11"]


def test_errorf_with_bad_arguments_still_says_something():
    rt = util_runtime()
    rt.execute('errorf("%d things", "not a number")')
    assert lines(rt) == ["early *** ERROR: %d things"]


def test_errorf_before_the_log_exists_is_only_printed():
    rt = util_runtime()
    rt.execute("DesyncLog = nil; errorf('early boot problem')")
    assert list(rt.eval("printed").values()) == ["[ModdedOnline ERROR] early boot problem"]


def test_a_safecall_failure_is_logged_once_not_twice():
    """SafeCall writes its own `*** LUA ERROR` line with the stack; going through
    errorf as well would put the same failure in the log twice."""
    rt = util_runtime()
    rt.execute("SafeCall('guiTick', function() error('kaput') end)")
    logged = lines(rt)
    assert len(logged) == 1 and logged[0].startswith("line *** LUA ERROR in guiTick:"), logged
    assert "kaput" in logged[0]
    printed = [str(v) for v in rt.eval("printed").values()]
    assert len(printed) == 1 and printed[0].startswith("[ModdedOnline ERROR] guiTick failed:")


# --------------------------------------------------------- a hosted callback's error

def callbacks_runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        ON = {PRE_UPDATE = 1, POST_UPDATE = 2, GAMEFRAME = 3, GUIFRAME = 4}
        nowValue = 0
        function get_ms() return nowValue end
        function set_callback() return 1 end
        function clear_callback() end
        function errorf() end
        function dbg() end
        function PackPath(n) return "./" .. n end
    """)
    rt.execute(CALLBACKS)
    rt.execute(LOG_STUB)
    return rt


def hosted_thrower(rt, message="boom", chunk="@hooks/water.lua"):
    rt.execute(f'thrower = load([[return function() error("{message}") end]], "{chunk}")()')
    return rt.eval("Callbacks.hosted")(rt.eval("thrower"))


def test_a_hosted_callbacks_error_is_logged_under_its_own_name_and_still_raised():
    rt = callbacks_runtime()
    wrapped = hosted_thrower(rt)
    with pytest.raises(lupa.LuaError, match="boom"):
        wrapped()
    logged = lines(rt)
    assert len(logged) == 1, logged
    assert logged[0].startswith("early *** HOSTED MOD ERROR in water.lua:1: "), logged
    assert "boom" in logged[0] and "stack traceback" in logged[0]


def test_the_error_the_engine_gets_is_the_one_the_mod_raised():
    rt = callbacks_runtime()
    rt.execute("""
        token = setmetatable({}, { __tostring = function() return 'a table error' end })
        thrower = function() error(token) end
    """)
    wrapped = rt.eval("Callbacks.hosted")(rt.eval("thrower"))
    rt.execute("caught = nil")
    rt.eval("function(f) local ok, err = pcall(f); caught = err end")(wrapped)
    assert rt.eval("caught == token") is True, "the error value was replaced on the way out"


def test_the_same_callback_failing_every_frame_is_one_line_then_one_every_few_seconds():
    rt = callbacks_runtime()
    wrapped = hosted_thrower(rt)
    for now in (0, 16, 33, 1000, 4999, 5000, 6000, 10001):
        rt.execute(f"nowValue = {now}")
        with pytest.raises(lupa.LuaError):
            wrapped()
    logged = lines(rt)
    assert len(logged) == 3, logged
    assert logged[1].startswith("event *** HOSTED MOD ERROR again in water.lua:1: ")
    assert "\n" not in logged[1], "a repeat carries the first line only"


def test_an_error_its_source_already_logged_is_not_logged_again():
    """The ordered ON.LEVEL batch catches a callback's error, logs it under that
    callback's name, and raises it when the engine reaches that callback."""
    rt = callbacks_runtime()
    rt.execute("Callbacks.noteHostedError('water.lua:1 (ON.LEVEL)', 'boom!', 'the stack')")
    rt.execute("thrower = function() error('boom!', 0) end")
    wrapped = rt.eval("Callbacks.hosted")(rt.eval("thrower"))
    with pytest.raises(lupa.LuaError, match="boom!"):
        wrapped()
    assert lines(rt) == ["early *** HOSTED MOD ERROR in water.lua:1 (ON.LEVEL): the stack"]
    with pytest.raises(lupa.LuaError):
        wrapped()  # not noted this time: its own name, logged
    assert len(lines(rt)) == 2


def test_a_callback_inside_a_determinism_wrapper_is_named_by_the_mods_function():
    """A real crash trace ended `OUT mod determinism.lua:1042`: the held-frame wrapper
    around one of the mod's ~200 update callbacks, and no way to say which."""
    rt = callbacks_runtime()
    rt.execute("""
        Determinism = { innerOf = setmetatable({}, { __mode = 'k' }) }
        modUpdate = load('return function() error("in the update") end', '@hooks/wheelOfFortune.lua')()
        wrapper = function(...) return modUpdate(...) end
        Determinism.innerOf[wrapper] = modUpdate
    """)
    wrapped = rt.eval("Callbacks.hosted")(rt.eval("wrapper"))
    with pytest.raises(lupa.LuaError):
        wrapped()
    assert lines(rt)[0].startswith("early *** HOSTED MOD ERROR in wheelOfFortune.lua:1: ")


def test_the_trace_names_the_mods_function_too(tmp_path):
    rt = trace.host_runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("""
        Determinism = { innerOf = setmetatable({}, { __mode = 'k' }) }
        seenDuringCall = nil
        modUpdate = load([[return function()
            local f = io.open(packRoot .. "/crash_frame.txt", "r")
            seenDuringCall = f:read("*a")
            f:close()
        end]], '@hooks/tonicEffects.lua')()
        wrapper = function(...) return modUpdate(...) end
        Determinism.innerOf[wrapper] = modUpdate
    """)
    rt.eval("Callbacks.hosted")(rt.eval("wrapper"))()
    assert str(rt.eval("seenDuringCall")).startswith("IN  mod tonicEffects.lua:1 ")


def test_reading_what_a_hosted_callback_returned_cannot_raise(tmp_path):
    """With the trace on, a returned table is read for crash_notes.txt -- and reading
    it runs the mod's metamethods. One that throws must not become our error."""
    rt = trace.host_runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("""
        weird = setmetatable({}, { __len = function() error('no length') end })
        returner = function() return weird end
    """)
    result = rt.eval("Callbacks.hosted")(rt.eval("returner"))()
    assert rt.eval("function(r) return r == weird end")(result) is True


# ------------------------------------------------------ the crash trace, across a relaunch

PRIOR = "OUT mod determinism.lua:1042 | sim 21:115 | 14:16:36"


def test_the_previous_sessions_last_mark_survives_this_sessions_first(tmp_path):
    """The FVJF peer's header said `IN  guiframe:netCore | sim 0:0 | 14:05:36` -- this
    session's own first mark, at its own start. The previous session's line was gone
    before anything read it."""
    (tmp_path / "crash_frame.txt").write_text(PRIOR + " " * 40 + "\n", encoding="utf-8")
    (tmp_path / "crash_notes.txt").write_text("[14:05:36] a note\n", encoding="utf-8")
    rt = trace.runtime(tmp_path, flags=["mo_trace.on"])
    rt.eval("DesyncLog.frameMark")("guiframe:netCore")  # truncates crash_frame.txt
    assert PRIOR not in (tmp_path / "crash_frame.txt").read_text(encoding="utf-8")
    rt.execute("DesyncLog.init()")
    header = (tmp_path / "desync_log.txt").read_text(encoding="utf-8")
    assert "*** PREVIOUS SESSION's last per-frame callback: " + PRIOR in header, header
    assert (tmp_path / "crash_frame.prev.txt").read_text(encoding="utf-8").startswith(PRIOR)
    assert (tmp_path / "crash_notes.prev.txt").read_text(encoding="utf-8") == "[14:05:36] a note\n"


def test_a_session_that_does_not_trace_leaves_the_files_alone(tmp_path):
    (tmp_path / "crash_frame.txt").write_text(PRIOR + "\n", encoding="utf-8")
    rt = trace.runtime(tmp_path)
    rt.execute("DesyncLog.init()")
    header = (tmp_path / "desync_log.txt").read_text(encoding="utf-8")
    assert "*** PREVIOUS SESSION's last per-frame callback: " + PRIOR in header
    assert not (tmp_path / "crash_frame.prev.txt").exists()
    assert (tmp_path / "crash_frame.txt").read_text(encoding="utf-8") == PRIOR + "\n"


def test_no_trace_file_no_line(tmp_path):
    rt = trace.runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("DesyncLog.init()")
    header = (tmp_path / "desync_log.txt").read_text(encoding="utf-8")
    assert "PREVIOUS SESSION's last per-frame callback" not in header


# ------------------------------------------------------------------- the mod host

@pytest.fixture
def sandbox(tmp_path, monkeypatch):
    (tmp_path / "Mods" / "Packs" / "fake.mod").mkdir(parents=True)
    monkeypatch.chdir(tmp_path)
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        ON = {PRE_UPDATE = 1, POST_UPDATE = 2, GAMEFRAME = 3, GUIFRAME = 4, LEVEL = 5}
        nextId, cleared, said = 0, {}, {}
        function set_callback(fn, kind) nextId = nextId + 1; return nextId end
        function set_timeout(fn, frames) nextId = nextId + 1; return nextId end
        function set_global_timeout(fn, frames) nextId = nextId + 1; return nextId end
        function clear_callback(id) cleared[#cleared + 1] = id or 'current' end
        function errorf(fmt, ...) said[#said + 1] = string.format(fmt, ...) end
        function dbg() end
        function get_ms() return 0 end
        function PackPath(n) return "./" .. n end
    """)
    rt.execute(CALLBACKS)
    rt.execute(MOD_HOST)
    rt.execute("""report = { ok = false, modules = {}, callbacks = {}, missing = {}, files = 0,
        refused = 0, missingModules = {}, missingTextures = {}, skippedTextures = {} }""")
    rt.execute("env = ModHost.newSandbox(report, {inert = false, determinism = false, packDir = 'fyi.spelunky-25-2'})")
    return rt


def test_a_mod_can_clear_its_own_global_timeout(sandbox):
    """set_global_timeout was missing from the APIs the sandbox counts as the mod's,
    so a mod clearing its own was refused and the timeout fired anyway."""
    rt = sandbox
    rt.execute("id = env.set_global_timeout(function() end, 60); env.clear_callback(id)")
    assert [int(v) for v in rt.eval("cleared").values()] == [int(rt.eval("id"))]
    assert int(rt.eval("report.refused")) == 0


def test_a_callback_the_engine_cannot_call_is_named_once(sandbox):
    rt = sandbox
    rt.execute("env.set_timeout(5, 30); env.set_timeout(6, 30); env.set_callback(function() end, ON.LEVEL)")
    said = [str(v) for v in rt.eval("said").values() if "not a function" in str(v)]
    assert len(said) == 1, said
    assert "fyi.spelunky-25-2 passed a number, not a function, as the callback to set_timeout(5, 30)" in said[0]
    assert 'attempt to call a number value' in said[0]


def test_a_callable_table_is_not_complained_about(sandbox):
    rt = sandbox
    rt.execute("env.set_timeout(setmetatable({}, { __call = function() end }), 30)")
    assert not any("not a function" in str(v) for v in rt.eval("said").values())


def test_the_floor_block_says_what_kinds_of_callback_the_mod_registered(sandbox):
    rt = sandbox
    rt.execute("""
        env.set_callback(function() end, ON.LEVEL)
        env.set_callback(function() end, ON.GUIFRAME)
        env.set_global_timeout(function() end, 30)
    """)
    first = rt.eval("ModHost.registrationsSinceLastFloor()")
    assert first == "set_callback +2, set_global_timeout +1"
    assert rt.eval("ModHost.registrationsSinceLastFloor()") is None, "counted twice"
    rt.execute("env.set_timeout(function() end, 5)")
    assert rt.eval("ModHost.registrationsSinceLastFloor()") == "set_timeout +1"


def test_a_hosted_timer_runs_through_the_hosted_wrapper(sandbox):
    """Named in the crash trace and the profile, and at our depth zero -- the FVJF
    crash trace could see only the mod's set_callback callbacks."""
    rt = sandbox
    rt.execute("""
        engineGot, depthInside = nil, nil
        function set_timeout(fn, frames) engineGot = fn; return 77 end
        env = ModHost.newSandbox(report, {inert = false, determinism = false})
        timer = function() depthInside = Callbacks.depth() end
        id = env.set_timeout(timer, 10)
    """)
    assert int(rt.eval("id")) == 77
    assert rt.eval("engineGot ~= timer") is True, "the engine was handed the mod's function raw"
    rt.execute("engineGot()")
    assert int(rt.eval("depthInside")) == 0


def test_the_hosting_summary_is_held_for_the_first_runs_log():
    """It runs at boot, before any log is open: a plain DesyncLog.line went nowhere.
    It is the one place every texture the mod asked for and did not get is named."""
    body = MOD_HOST[MOD_HOST.index("function module.hostOne("):]
    body = body[:body.index("\nend\n")]
    loop = body[body.index("for _, line in ipairs(module.summarize(report)) do"):]
    assert "DesyncLog.earlyEvent" in loop[:loop.index("\n    end\n")]
