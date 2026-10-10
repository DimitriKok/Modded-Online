"""The callbacks the ENGINE calls, named: what each was registered for, and where.

Room UVLQ's host crashed leaving 2-2 with crash_frame.txt reading
`OUT mod helpers2.lua:533` -- 2.5's PRE_LEVEL_DESTRUCTION wrapper had returned, and
the mark could not say so: it named the function, not the event, and a level's
teardown runs none of our callbacks, so nothing marked how far it got after that.

A couple of floors earlier the same host had a Lua error "with very little
information", and none of it reached our log: four of the global APIs that store a
callback for the engine to call later -- the vanilla sound callbacks, console
commands, render-screen hooks and the instagib hook -- handed theirs over unwrapped
and unchecked. A value that cannot be called reaches Playlunky as `attempt to call a
number value` with an empty stack.

Run:  python -m pytest tests/test_engine_called_callbacks.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

import test_trace_arming as trace

PACK = pathlib.Path(__file__).resolve().parent.parent
CALLBACKS = (PACK / "src" / "callbacks.lua").read_text(encoding="utf-8")
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")

# The engine, as far as these APIs go. Each hands back what Overlunky's does: the
# sound manager and each screen keep counts of their own, from 1; the instagib hook
# takes its id from the script's callback count; a console command returns nothing.
ENGINE = """
    ON = {PRE_UPDATE = 1, POST_UPDATE = 2, GAMEFRAME = 3, GUIFRAME = 4, LEVEL = 5,
          PRE_LEVEL_DESTRUCTION = 6, ONLINE_LOBBY = 7, ONLINE_LOADING = 7}
    nextId, cleared, said, handed = 0, {}, {}, {}
    function set_callback(fn, kind) nextId = nextId + 1; handed[nextId] = fn; return nextId end
    function clear_callback(id) cleared[#cleared + 1] = id or 'current' end
    soundId, soundCleared = 0, {}
    function set_vanilla_sound_callback(name, types, cb)
        soundId = soundId + 1
        sound = {name = name, types = types, cb = cb}
        return soundId
    end
    function clear_vanilla_sound_callback(id) soundCleared[#soundCleared + 1] = id end
    function register_console_command(name, cmd) command = {name = name, cmd = cmd} end
    screenId = 0
    function set_pre_render_screen(screen, fn)
        if screen ~= 12 then return nil end
        screenId = screenId + 1
        screenHook = {screen = screen, fn = fn}
        return screenId
    end
    set_post_render_screen = set_pre_render_screen
    function set_on_player_instagib(uid, fn)
        nextId = nextId + 1
        instagib = {uid = uid, fn = fn}
        return nextId
    end
    function errorf(fmt, ...) said[#said + 1] = string.format(fmt, ...) end
    function dbg() end
    function get_ms() return 0 end
    function PackPath(n) return "./" .. n end
"""

LOG_STUB = """
    logged = {}
    DesyncLog = {
        earlyEvent = function(fmt, ...) logged[#logged + 1] = 'early ' .. string.format(fmt, ...) end,
        event = function(fmt, ...) logged[#logged + 1] = 'event ' .. string.format(fmt, ...) end,
    }
"""

REPORT = """report = { ok = false, modules = {}, callbacks = {}, missing = {}, files = 0,
    refused = 0, missingModules = {}, missingTextures = {}, skippedTextures = {} }"""

SANDBOX = ("env = ModHost.newSandbox(report, {inert = false, determinism = false,"
           " packDir = 'fyi.spelunky-25-2'})")


@pytest.fixture
def sandbox(tmp_path, monkeypatch):
    (tmp_path / "Mods" / "Packs" / "fake.mod").mkdir(parents=True)
    monkeypatch.chdir(tmp_path)
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(CALLBACKS)
    rt.execute(LOG_STUB)
    rt.execute(MOD_HOST)
    rt.execute(REPORT)
    rt.execute(SANDBOX)
    return rt


def logged(rt):
    return [str(v) for v in rt.eval("logged").values()]


def complaints(rt):
    return [str(v) for v in rt.eval("said").values() if "not a function" in str(v)]


def run_inside_ours(rt, call):
    """Run `call` from inside one of OUR callbacks, where our depth is one."""
    rt.execute(f"oursId = set_callback(function() depthOutside = Callbacks.depth(); {call} end,"
               " ON.GAMEFRAME)")
    rt.execute("handed[oursId]()")
    assert int(rt.eval("depthOutside")) == 1


# ------------------------------------------------------------ vanilla sound callbacks

def test_a_sound_callback_goes_to_the_engine_wrapped_and_in_its_place(sandbox):
    """It is the THIRD argument. The two before it reach the engine untouched."""
    rt = sandbox
    rt.execute("""
        depthInside, heard = nil, nil
        mine = function(s) depthInside = Callbacks.depth(); heard = s end
        id = env.set_vanilla_sound_callback('Player/Ouch', 3, mine)
    """)
    assert rt.eval("sound.name") == "Player/Ouch"
    assert rt.eval("sound.types") == 3
    assert rt.eval("type(sound.cb) == 'function' and sound.cb ~= mine") is True, (
        "the engine was handed the mod's function raw")
    run_inside_ours(rt, "sound.cb('a playing sound')")
    assert rt.eval("heard") == "a playing sound"
    assert int(rt.eval("depthInside")) == 0, "the mod's own code ran at our depth"


def test_the_mod_can_still_clear_its_own_sound_callback(sandbox):
    rt = sandbox
    rt.execute("id = env.set_vanilla_sound_callback('Player/Ouch', 3, function() end)"
               "; env.clear_vanilla_sound_callback(id)")
    assert [int(v) for v in rt.eval("soundCleared").values()] == [int(rt.eval("id"))]
    assert int(rt.eval("report.refused")) == 0


def test_a_sound_callback_the_engine_cannot_call_is_named_once(sandbox):
    rt = sandbox
    rt.execute("env.set_vanilla_sound_callback('Player/Ouch', 3, 7)"
               "; env.set_vanilla_sound_callback('Player/Ouch', 3, 8)")
    said = complaints(rt)
    assert len(said) == 1, said
    assert ("fyi.spelunky-25-2 passed a number, not a function, as the callback to"
            " set_vanilla_sound_callback(Player/Ouch, 3, 7)") in said[0]
    assert "attempt to call a number value" in said[0]
    assert rt.eval("sound.cb") == 8, "what the mod passed must still reach the engine"


def test_a_sound_callbacks_error_names_the_sound(sandbox):
    rt = sandbox
    rt.execute("""
        thrower = load([[return function() error("no such field") end]], "@sounds.lua")()
        env.set_vanilla_sound_callback('Player/Ouch', 3, thrower)
    """)
    with pytest.raises(lupa.LuaError, match="no such field"):
        rt.execute("sound.cb('a playing sound')")
    first = logged(rt)[0]
    assert first.startswith(
        "early *** HOSTED MOD ERROR in sounds.lua:1 set_vanilla_sound_callback Player/Ouch: "), first


def test_naming_what_the_mod_passed_never_raises(sandbox):
    """A table's __tostring is the mod's code; the registration must still go through."""
    rt = sandbox
    rt.execute("""
        ModHost.onProgress = function() end
        weird = setmetatable({}, { __tostring = function() error('no text for you') end })
        env.set_vanilla_sound_callback(weird, 3, 7)
    """)
    said = complaints(rt)
    assert len(said) == 1 and "set_vanilla_sound_callback(?, 3, 7)" in said[0], said
    assert rt.eval("sound.cb") == 7


# ------------------------------------------------- console, render screens, instagib

def test_a_console_command_is_wrapped_and_its_answer_comes_back(sandbox):
    rt = sandbox
    rt.execute("""
        answer = function(a, b) return 'ran ' .. tostring(a) .. ' ' .. tostring(b) end
        env.register_console_command('boom', answer)
    """)
    assert rt.eval("command.name") == "boom"
    assert rt.eval("command.cmd ~= answer") is True
    assert rt.eval("command.cmd(1, 2)") == "ran 1 2"


def test_a_render_screen_hook_still_skips_the_default_rendering(sandbox):
    """`return true` from a pre-render hook is how a mod draws a screen its own way."""
    rt = sandbox
    rt.execute("skip = function(screen, ctx) return true end; id = env.set_pre_render_screen(12, skip)")
    assert int(rt.eval("id")) == 1
    assert rt.eval("screenHook.screen") == 12
    assert rt.eval("screenHook.fn ~= skip") is True
    assert rt.eval("screenHook.fn('the screen', 'its render context')") is True


def test_a_render_screen_id_is_not_taken_for_one_of_ours(sandbox):
    """A screen counts its own hooks, from 1, and they are cleared with
    clear_screen_callback(screen, id). As a callback id, 1 is one of OURS."""
    rt = sandbox
    rt.execute("id = env.set_post_render_screen(12, function() end); env.clear_callback(id)")
    assert list(rt.eval("cleared").values()) == []
    assert int(rt.eval("report.refused")) == 1


def test_a_screen_that_does_not_exist_hands_back_nothing(sandbox):
    rt = sandbox
    rt.execute("id = env.set_pre_render_screen(99, function() end)")
    assert rt.eval("id") is None
    assert complaints(rt) == []


def test_an_instagib_hook_is_the_mods_to_clear(sandbox):
    """Its id comes from the script's own callback count, and clear_callback clears it."""
    rt = sandbox
    rt.execute("""
        spare = function(self) return true end
        id = env.set_on_player_instagib(1234, spare)
    """)
    assert rt.eval("instagib.uid") == 1234
    assert rt.eval("instagib.fn ~= spare") is True
    assert rt.eval("instagib.fn('a player')") is True, "true skips the crush, still"
    rt.execute("env.clear_callback(id)")
    assert [int(v) for v in rt.eval("cleared").values()] == [int(rt.eval("id"))]
    assert int(rt.eval("report.refused")) == 0


def test_a_hook_the_engine_cannot_call_is_named_for_each_api(sandbox):
    rt = sandbox
    rt.execute("""
        env.register_console_command('boom', 'not a function')
        env.set_on_player_instagib(1234, 5)
        env.set_pre_render_screen(12, nil)
    """)
    said = complaints(rt)
    assert len(said) == 3, said
    assert "a string, not a function, as the callback to register_console_command(boom, not a function)" in said[0]
    assert "a number, not a function, as the callback to set_on_player_instagib(1234, 5)" in said[1]
    assert "a nil, not a function, as the callback to set_pre_render_screen(12, nil)" in said[2]


def test_a_callback_for_an_event_that_does_not_exist_is_named_once(sandbox):
    """2.5's Helpers2.gameFrame registers for ON.GAME_FRAME; the engine's is GAMEFRAME."""
    rt = sandbox
    rt.execute("""
        before = nextId
        wrapper = load([[return function() end]], "@helpers2.lua")()
        env.set_callback(wrapper, ON.GAME_FRAME)
        env.set_callback(wrapper, ON.GAME_FRAME)
        env.set_callback(function() end, ON.LEVEL)
    """)
    said = [str(v) for v in rt.eval("said").values() if "does not exist" in str(v)]
    assert len(said) == 1, said
    assert ("fyi.spelunky-25-2 registered a callback (helpers2.lua:1) for an event that"
            " does not exist (nil)") in said[0]
    assert int(rt.eval("nextId - before")) == 3, "the registrations must still reach the engine"


# ------------------------------------------------------------- what it was FOR

def throw_from(rt, register):
    rt.execute(f"""
        thrower = load([[return function() error("boom") end]], "@helpers2.lua")()
        id = {register}
    """)
    with pytest.raises(lupa.LuaError, match="boom"):
        rt.execute("handed[id]()")
    return logged(rt)[0]


def test_an_error_says_which_event_it_was_registered_for(sandbox):
    first = throw_from(sandbox, "env.set_callback(thrower, ON.PRE_LEVEL_DESTRUCTION)")
    assert first.startswith("early *** HOSTED MOD ERROR in helpers2.lua:1 PRE_LEVEL_DESTRUCTION: "), first


def test_two_names_for_one_event_read_as_the_first_alphabetically(sandbox):
    first = throw_from(sandbox, "env.set_callback(thrower, ON.ONLINE_LOBBY)")
    assert "helpers2.lua:1 ONLINE_LOADING: " in first, first


def test_an_event_with_no_name_is_still_said(sandbox):
    first = throw_from(sandbox, "env.set_callback(thrower, 999)")
    assert "helpers2.lua:1 ON 999: " in first, first


def test_a_timer_is_labelled_by_its_api(sandbox):
    rt = sandbox
    rt.execute("function set_timeout(fn, frames) nextId = nextId + 1; handed[nextId] = fn; return nextId end")
    rt.execute(SANDBOX)
    first = throw_from(rt, "env.set_timeout(thrower, 30)")
    assert "helpers2.lua:1 set_timeout: " in first, first


def test_the_same_function_on_two_events_is_two_first_errors(sandbox):
    """Keyed by function AND event: the second is not a repeat of the first."""
    rt = sandbox
    throw_from(rt, "env.set_callback(thrower, ON.PRE_LEVEL_DESTRUCTION)")
    rt.execute("id = env.set_callback(thrower, ON.LEVEL)")
    with pytest.raises(lupa.LuaError):
        rt.execute("handed[id]()")
    assert logged(rt)[1].startswith("early *** HOSTED MOD ERROR in helpers2.lua:1 LEVEL: ")


# ------------------------------------------------------------------ the crash trace

@pytest.fixture
def traced(tmp_path, monkeypatch):
    (tmp_path / "Mods" / "Packs" / "fake.mod").mkdir(parents=True)
    monkeypatch.chdir(tmp_path)
    rt = trace.host_runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("""
        ON.PRE_LEVEL_DESTRUCTION = 140
        handed = {}
        Callbacks.rawSetCallback = function(fn, kind) nextId = nextId + 1; handed[nextId] = fn; return nextId end
        function set_vanilla_sound_callback(name, types, cb) sound = {cb = cb}; return 1 end
    """)
    rt.execute(MOD_HOST)
    rt.execute(REPORT)
    rt.execute(SANDBOX)
    return rt


def frame_line(tmp_path):
    return (tmp_path / "crash_frame.txt").read_text(encoding="utf-8")


def test_the_trace_says_which_event_was_running(traced, tmp_path):
    """What helpers2.lua:533 was called for is what the UVLQ trace could not say."""
    rt = traced
    rt.execute("""
        seen = nil
        probe = load([[return function()
            local f = io.open(packRoot .. "/crash_frame.txt", "r")
            seen = f:read("*a")
            f:close()
        end]], "@helpers2.lua")()
        id = env.set_callback(probe, ON.PRE_LEVEL_DESTRUCTION)
        handed[id]()
    """)
    assert str(rt.eval("seen")).startswith("IN  mod helpers2.lua:1 PRE_LEVEL_DESTRUCTION | ")
    assert frame_line(tmp_path).startswith("OUT mod helpers2.lua:1 PRE_LEVEL_DESTRUCTION | ")


def test_a_sound_callback_leaves_the_trace_alone(traced, tmp_path):
    """The engine calls these from FMOD's thread, whenever a sound plays. The trace is
    one line: a sound playing while the main thread is in native code would have
    overwritten the very mark that says where it was."""
    rt = traced
    rt.execute("""
        DesyncLog.frameMark('engine:update')
        heard = nil
        env.set_vanilla_sound_callback('Player/Ouch', 3, function(s) heard = s end)
        sound.cb('a playing sound')
    """)
    assert rt.eval("heard") == "a playing sound"
    assert frame_line(tmp_path).startswith("IN  engine:update | ")


# ------------------------------------------------------- the load, phase by phase

PHASES = """
    ON.PRE_LEVEL_DESTRUCTION = 140
    ON.PRE_LAYER_DESTRUCTION = 141
    ON.POST_LAYER_DESTRUCTION = 142
    ON.POST_LEVEL_DESTRUCTION = 143
    ON.POST_LOAD_SCREEN = 144
    registered, order = {}, {}
    function set_callback(fn, event)
        registered[event] = fn
        order[#order + 1] = event
        return #order
    end
    function get_local_state() return { screen = 12, screen_next = 13 } end
    ENT_TYPE = { ITEM_ROCK = 365, FX_SPARK = 99, DECORATION_GUTS = 7 }
"""


def phase(rt, name, *args):
    return rt.eval(f"registered[ON.{name}]")(*args)


def test_a_teardown_leaves_a_mark_per_phase(tmp_path):
    """After `OUT mod helpers2.lua:533` the UVLQ trace had nothing: the teardown that
    followed runs none of our per-frame callbacks."""
    rt = trace.runtime(tmp_path, flags=["mo_trace.on"], engine=PHASES)
    phase(rt, "PRE_LEVEL_DESTRUCTION")
    assert frame_line(tmp_path).startswith("OUT load:PRE_LEVEL_DESTRUCTION | ")
    phase(rt, "PRE_LAYER_DESTRUCTION", 1)
    assert frame_line(tmp_path).startswith("OUT load:PRE_LAYER_DESTRUCTION 1 | ")
    phase(rt, "POST_LEVEL_DESTRUCTION")
    assert frame_line(tmp_path).startswith("OUT load:POST_LEVEL_DESTRUCTION | ")


def test_a_load_screen_mark_never_skips_the_load(tmp_path):
    """PRE_LOAD_SCREEN reads a true as "do not load this screen"."""
    for where, flags in (("traced", ["mo_trace.on"]), ("plain", [])):
        (tmp_path / where).mkdir()  # a flag file is the pack folder's, so one each
        rt = trace.runtime(tmp_path / where, flags=flags, engine=PHASES)
        assert phase(rt, "PRE_LOAD_SCREEN") is None
        assert phase(rt, "POST_LOAD_SCREEN") is None


def test_a_screen_change_is_noted(tmp_path):
    rt = trace.runtime(tmp_path, flags=["mo_trace.on"], engine=PHASES)
    phase(rt, "PRE_LOAD_SCREEN")
    notes = (tmp_path / "crash_notes.txt").read_text(encoding="utf-8")
    assert "load: screen 12 -> 13 | sim " in notes, notes


def test_without_the_trace_the_phases_write_nothing(tmp_path):
    rt = trace.runtime(tmp_path, engine=PHASES)
    phase(rt, "PRE_LOAD_SCREEN")
    phase(rt, "PRE_LAYER_DESTRUCTION", 0)
    assert not (tmp_path / "crash_frame.txt").exists()
    assert not (tmp_path / "crash_notes.txt").exists()


def test_the_phases_are_registered_whatever_the_flags(tmp_path):
    """Callback ids are handed out in order, and the engine runs an event's callbacks
    in an order that depends on them (HANDOFF section 17). A registration made on one
    machine and not the other would shift every id after it -- the hosted mod's too."""
    (tmp_path / "traced").mkdir()
    (tmp_path / "plain").mkdir()
    traced_rt = trace.runtime(tmp_path / "traced", flags=["mo_trace.on"], engine=PHASES)
    plain_rt = trace.runtime(tmp_path / "plain", engine=PHASES)
    assert traced_rt.eval("DesyncLog.tracing()") is True
    assert plain_rt.eval("DesyncLog.tracing()") is False
    traced_order = list(traced_rt.eval("order").values())
    plain_order = list(plain_rt.eval("order").values())
    assert traced_order == plain_order
    assert len(plain_order) == 6, "one per phase this engine has, and only those"


def test_a_census_reads_most_common_first(tmp_path):
    rt = trace.runtime(tmp_path, engine=PHASES)
    counts = rt.eval("function() return { [365] = 5, [99] = 9, [7] = 5, [1234] = 1 } end")()
    assert rt.eval("DesyncLog.typeCounts")(counts, 2) == "FX_SPARK 9, DECORATION_GUTS 5, +2 more kind(s)"
    assert rt.eval("DesyncLog.typeCounts")(counts, 9) == (
        "FX_SPARK 9, DECORATION_GUTS 5, ITEM_ROCK 5, ID_1234 1")
    assert rt.eval("DesyncLog.typeCounts")(rt.eval("{}"), 6) == "none"


# ------------------------------------------------- what the mod calls its callback

HELPERS2 = """local module = {}
function module.preLevelDestruction(debugName, callback)
    return set_callback(function(...)
        local _, result = SafeCall("preLevelDestruction-" .. (debugName or ""), callback, ...)
        return result
    end, ON.PRE_LEVEL_DESTRUCTION)
end
local function createEveryNthFrameWrapper(debugName, callback, everyNthFrame)
    local counter = 0
    local callbackName = debugName and debugName .. ".callback"
    return function(...)
        counter = counter + 1
        if counter >= everyNthFrame then
            counter = 0
            SafeCall(callbackName or debugName .. ".callback", callback, ...)
        end
    end
end
function module.preUpdate(debugName, callback, maxUpdates, everyNthFrame)
    local callbackName = "onPreUpdate.callWrapper" .. (debugName or "")
    local wrappedCallback = createEveryNthFrameWrapper(debugName, callback, everyNthFrame)
    return set_callback(function(...)
        local _, result = SafeCall(callbackName, wrappedCallback, ...)
        return result
    end, ON.PRE_UPDATE, maxUpdates)
end
return module
"""


# the lines the two wrappers are defined on, as debug.getinfo reports them
DESTRUCTION_AT, PRE_UPDATE_AT = [i + 1 for i, line in enumerate(HELPERS2.splitlines())
                                 if "return set_callback(function(...)" in line]

PEEK = """return function()
    local f = io.open(packRoot .. "/crash_frame.txt", "r")
    seen = f:read("*a")
    f:close()
end"""


def load_helpers2(rt):
    rt.execute("function SafeCall(_n, fn, ...) return true, fn(...) end")
    rt.eval("function(src) helpers = load(src, '@helpers2.lua', 't', env)() end")(HELPERS2)


def test_a_helpers2_callback_is_named_by_what_2_5_calls_it(traced, tmp_path):
    """Every PRE_LEVEL_DESTRUCTION callback of 2.5's is the same function of
    helpers2.lua's; the name 2.5 gave each one is what tells them apart."""
    rt = traced
    load_helpers2(rt)
    rt.eval("function(src) peek = load(src, '@levelExit.lua')() end")(PEEK)
    rt.execute("id = helpers.preLevelDestruction('exitBlocker', peek); handed[id]()")
    assert str(rt.eval("seen")).startswith(
        f"IN  mod helpers2.lua:{DESTRUCTION_AT} (exitBlocker @ levelExit.lua:1) PRE_LEVEL_DESTRUCTION | ")


def test_a_wrapper_inside_a_wrapper_is_followed_to_the_mods_own_function(traced, tmp_path):
    """2.5's every-Nth-frame counter sits between its PRE_UPDATE wrapper and the
    callback it was given."""
    rt = traced
    load_helpers2(rt)
    rt.eval("function(src) peek = load(src, '@spinner.lua')() end")(PEEK)
    rt.execute("id = helpers.preUpdate('spin', peek, nil, 1); handed[id]()")
    assert str(rt.eval("seen")).startswith(
        f"IN  mod helpers2.lua:{PRE_UPDATE_AT} (onPreUpdate.callWrapperspin @ spinner.lua:1) PRE_UPDATE | ")


def test_a_long_name_leaves_room_for_the_clock(traced, tmp_path):
    rt = traced
    load_helpers2(rt)
    rt.eval("function(src) peek = load(src, '@levelExit.lua')() end")(PEEK)
    rt.execute("id = helpers.preLevelDestruction(string.rep('x', 300), peek); handed[id]()")
    seen = str(rt.eval("seen"))
    assert "x..." in seen and " PRE_LEVEL_DESTRUCTION | sim " in seen, seen


def test_an_error_carries_the_mods_name_too(sandbox):
    rt = sandbox
    rt.execute("function SafeCall(_n, fn, ...) return true, fn(...) end")
    rt.eval("function(src) helpers = load(src, '@helpers2.lua', 't', env)() end")(HELPERS2)
    rt.execute("""
        thrower = load([[return function() error("boom") end]], "@levelExit.lua")()
        id = helpers.preLevelDestruction('exitBlocker', thrower)
    """)
    with pytest.raises(lupa.LuaError, match="boom"):
        rt.execute("handed[id]()")
    assert logged(rt)[0].startswith(
        f"early *** HOSTED MOD ERROR in helpers2.lua:{DESTRUCTION_AT} (exitBlocker @ levelExit.lua:1)"
        " PRE_LEVEL_DESTRUCTION: ")


# ------------------------------------------------------------- and our own errors

def test_an_error_in_one_of_our_callbacks_is_logged_as_ours(sandbox):
    """Until dev79 one of OUR errors reached spelunky.log only, under the same
    "Mod: fyi.modded-online-loader" a hosted mod's errors carry."""
    rt = sandbox
    rt.execute("""
        ours = load([[return function() local t = nil; return t.x end]], "@eventSync.lua")()
        oursId = set_callback(ours, ON.GAMEFRAME)
    """)
    with pytest.raises(lupa.LuaError, match="attempt to index"):
        rt.execute("handed[oursId]()")
    lines = logged(rt)
    assert len(lines) == 1, lines
    assert lines[0].startswith("early *** MODDED ONLINE ERROR in eventSync.lua:1: "), lines[0]
    assert "stack traceback" in lines[0]
    assert int(rt.eval("Callbacks.depth()")) == 0, "the depth was not put back"


def test_the_error_the_engine_gets_from_ours_is_the_one_raised(sandbox):
    rt = sandbox
    rt.execute("""
        token = setmetatable({}, { __tostring = function() return 'a table error' end })
        oursId = set_callback(function() error(token) end, ON.GAMEFRAME)
        caught = select(2, pcall(handed[oursId]))
    """)
    assert rt.eval("caught == token") is True


def test_the_mods_error_through_one_of_ours_is_logged_once_as_the_mods(sandbox):
    """Ours can call into the mod (the ordered ON.LEVEL batch, the world capture)."""
    rt = sandbox
    rt.execute("""
        thrower = load([[return function() error("the mod's") end]], "@helpers2.lua")()
        id = env.set_callback(thrower, ON.LEVEL)
        oursId = set_callback(function() handed[id]() end, ON.GAMEFRAME)
    """)
    with pytest.raises(lupa.LuaError, match="the mod's"):
        rt.execute("handed[oursId]()")
    lines = logged(rt)
    assert len(lines) == 1, lines
    assert lines[0].startswith("early *** HOSTED MOD ERROR in helpers2.lua:1 LEVEL: "), lines[0]


def test_an_old_mod_error_does_not_hide_one_of_ours(sandbox):
    rt = sandbox
    rt.execute("""
        id = env.set_callback(function() error("same words", 0) end, ON.LEVEL)
        pcall(handed[id])  -- the mod's, raised to the engine and done with
        oursId = set_callback(function() error("same words", 0) end, ON.GAMEFRAME)
    """)
    with pytest.raises(lupa.LuaError, match="same words"):
        rt.execute("handed[oursId]()")
    assert any(l.startswith("early *** MODDED ONLINE ERROR in ") for l in logged(rt)), logged(rt)
