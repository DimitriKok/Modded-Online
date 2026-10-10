"""What the lockstep needs of a hosted callback on its way to the engine (dev78).

modHost hands every hosted registration to the engine. Two of them now get one more
wrapper there, outside Callbacks.hosted:

* A hosted PRE_UPDATE callback goes through InputSync.gateFirst, so the lockstep
  gate has decided the update before the mod's code runs -- whatever order the
  engine's hash map puts them in (see "one decision per update" in inputSync.lua).
* A hosted global timer (set_global_interval / set_global_timeout) counts only the
  frames the world moved. The engine counts its frame counter, which moves on a frame
  the gate holds: room VOYY's profile counted ~40 more GAMEFRAMEs than POST_UPDATEs
  per ten seconds of 4-2 on the machine that stalled, so a mod's global timer came
  due earlier, in simulated time, there.

Neither applies with the determinism layer off (mo_nodeterminism.on), which runs a
mod on the raw engine for bisecting a crash.

Run:  python -m pytest tests/test_lockstep_hosting.py -q
"""

from __future__ import annotations

import pathlib
import textwrap

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")
CALLBACKS = (PACK / "src" / "callbacks.lua").read_text(encoding="utf-8")
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")

ENGINE = """
ON = {
    FRAME = 1, GAMEFRAME = 2, LOADING = 3, LEVEL = 4,
    PRE_LEVEL_GENERATION = 5, POST_LEVEL_GENERATION = 6,
    PRE_LOAD_LEVEL_FILES = 7, PRE_LOAD_SCREEN = 8,
    PRE_UPDATE = 9, POST_UPDATE = 10, GUIFRAME = 11,
}
frameNo = 1000
function get_frame() return frameNo end
function get_adventure_seed() return 0x5EEDF00D, 0xD125E0C4 end
function get_local_state() return { world = 2, level = 1, theme = 2, time_total = 900 } end
function seed_prng() end
prng = { get_pair = function(_, c) return c, c end, set_pair = function() end }

callbacks, nextId, cleared, current = {}, 0, {}, nil
spawnArgs = nil
function set_callback(fn, kind)
    nextId = nextId + 1
    callbacks[nextId] = { fn = fn, kind = kind }
    return nextId
end
function set_post_entity_spawn(fn, flags, mask, ...)
    nextId = nextId + 1
    spawnArgs = { flags = flags, mask = mask, types = { ... } }
    return nextId
end
function clear_callback(id)
    if id == nil then id = current end
    if id ~= nil then cleared[id] = true end
end
function fire(kind, ...)
    local result
    for id, cb in pairs(callbacks) do
        if cb.kind == kind and not cleared[id] then
            local outer = current
            current = id
            local r = cb.fn(...)
            current = outer
            if r ~= nil then result = r end
        end
    end
    return result
end

-- the engine's global timers, as Overlunky keeps them: an interval runs at once
-- (lastRan = -1) and then whenever the frame counter is `interval` past its last
-- run; a timeout once the counter reaches registration + frames
globalTimers = {}
function set_global_interval(fn, frames)
    nextId = nextId + 1
    globalTimers[nextId] = { fn = fn, interval = frames, lastRan = -1 }
    return nextId
end
function set_global_timeout(fn, frames)
    nextId = nextId + 1
    globalTimers[nextId] = { fn = fn, timeout = frameNo + frames }
    return nextId
end
held = false
--- One engine update. The frame counter moves whether or not the gate held it.
function update(isHeld)
    held = isHeld
    frameNo = frameNo + 1
    local ids = {}
    for id in pairs(globalTimers) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local t = globalTimers[id]
        if t ~= nil and not cleared[id] then
            if t.interval ~= nil then
                if frameNo >= t.lastRan + t.interval then
                    local keep = t.fn()
                    t.lastRan = frameNo
                    if keep == false then globalTimers[id] = nil end
                end
            elseif frameNo >= t.timeout then
                t.fn()
                globalTimers[id] = nil
            end
        end
    end
end

gateWrapped, gateCalls = 0, 0
InputSync = {
    heldFrame = function() return held end,
    gateFirst = function(fn)
        gateWrapped = gateWrapped + 1
        return function(...)
            gateCalls = gateCalls + 1
            return fn(...)
        end
    end,
}
"""


def _host(tmp_path, monkeypatch, *, nodeterminism=False, sandbox_opts="{inert = false}"):
    (tmp_path / "Mods" / "Packs" / "fake.mod").mkdir(parents=True, exist_ok=True)
    if nodeterminism:
        (tmp_path / "mo_nodeterminism.on").write_text("")
    monkeypatch.chdir(tmp_path)
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(textwrap.dedent("""
        printed = {}
        function errorf(fmt, ...) printed[#printed + 1] = tostring(fmt) end
        function dbg() end
        function get_ms() return 0 end
        packRoot = "."
        function PackPath(n) return packRoot .. "/" .. n end
        Network = { isInRun = function() return true end }
    """))
    rt.execute(CALLBACKS)
    rt.execute(DETERMINISM)
    rt.execute(MOD_HOST)
    rt.execute("""report = { ok = false, modules = {}, callbacks = {}, missing = {}, files = 0,
        refused = 0, missingModules = {}, missingTextures = {}, skippedTextures = {} }""")
    rt.execute(f"env = ModHost.newSandbox(report, {sandbox_opts})")
    return rt


@pytest.fixture
def hosted(tmp_path, monkeypatch):
    return _host(tmp_path, monkeypatch)


def play(rt, pattern):
    """'r' an update the world moved on, 'h' one the gate held."""
    for c in pattern:
        rt.execute(f"update({'true' if c == 'h' else 'false'})")


# ------------------------------------------------------------------- gateFirst

def test_a_hosted_pre_update_callback_goes_through_the_gate_first(hosted):
    rt = hosted
    rt.execute("""
        ran = 0
        env.set_callback(function() ran = ran + 1 end, ON.PRE_UPDATE)
    """)
    assert int(rt.eval("gateWrapped")) == 1
    rt.execute("held = false; fire(ON.PRE_UPDATE)")
    assert int(rt.eval("gateCalls")) == 1 and int(rt.eval("ran")) == 1


def test_no_other_event_is_wrapped(hosted):
    rt = hosted
    rt.execute("""
        for _, kind in ipairs({ ON.POST_UPDATE, ON.GAMEFRAME, ON.GUIFRAME, ON.LEVEL, ON.FRAME }) do
            env.set_callback(function() end, kind)
        end
    """)
    assert int(rt.eval("gateWrapped")) == 0


def test_a_pre_update_that_blocks_the_update_still_does(hosted):
    rt = hosted
    rt.execute("env.set_callback(function() return true end, ON.PRE_UPDATE)")
    rt.execute("held = false")
    assert rt.eval("fire(ON.PRE_UPDATE)") is True


def test_the_spawn_hooks_still_get_every_argument(hosted):
    """The callback is re-wrapped on its way through; what follows it must not be cut
    to one argument -- a spawn hook's mask and entity types come after the flags."""
    rt = hosted
    rt.execute("env.set_post_entity_spawn(function() end, 1, 4, 101, 102, 103)")
    assert int(rt.eval("spawnArgs.flags")) == 1
    assert int(rt.eval("spawnArgs.mask")) == 4
    assert [int(v) for v in rt.eval("spawnArgs.types").values()] == [101, 102, 103]


def test_with_the_determinism_layer_off_nothing_is_added(tmp_path, monkeypatch):
    rt = _host(tmp_path, monkeypatch, nodeterminism=True)
    rt.execute("""
        ticks = 0
        env.set_callback(function() end, ON.PRE_UPDATE)
        env.set_global_interval(function() ticks = ticks + 1 end, 3)
    """)
    assert int(rt.eval("gateWrapped")) == 0
    play(rt, "rhhhhh")
    assert int(rt.eval("ticks")) == 2, "the raw engine's own counting, held frames and all"


# --------------------------------------------------------------- global timers

def test_in_solo_an_interval_fires_where_the_engines_would(hosted):
    """At once, then every `frames`: what Overlunky does with lastRan = -1."""
    rt = hosted
    rt.execute("""
        firedAt = {}
        env.set_global_interval(function() firedAt[#firedAt + 1] = frameNo end, 3)
    """)
    play(rt, "r" * 10)
    assert [int(v) for v in rt.eval("firedAt").values()] == [1001, 1004, 1007, 1010]


def test_an_interval_counts_only_the_frames_the_world_moved(hosted):
    rt = hosted
    rt.execute("""
        firedOnSim, sim = {}, 0
        env.set_global_interval(function() firedOnSim[#firedOnSim + 1] = sim end, 3)
    """)
    for c in "rhhrhrhhhrrhrr":
        if c == "r":
            rt.execute("sim = sim + 1")
        rt.execute(f"update({'true' if c == 'h' else 'false'})")
    assert [int(v) for v in rt.eval("firedOnSim").values()] == [1, 4, 7], (
        "the interval came due on a frame count that includes held frames")


def test_two_machines_with_different_stalls_agree_on_an_interval(tmp_path, monkeypatch):
    calm = _host(tmp_path / "a", monkeypatch)
    stalled = _host(tmp_path / "b", monkeypatch)
    for rt in (calm, stalled):
        rt.execute("""
            firedOnSim, sim = {}, 0
            env.set_global_interval(function() firedOnSim[#firedOnSim + 1] = sim end, 4)
        """)
    for rt, pattern in ((calm, "r" * 12), (stalled, "rhrhhrrhhhrrrhrrrrh")):
        for c in pattern:
            if c == "r":
                rt.execute("sim = sim + 1")
            rt.execute(f"update({'true' if c == 'h' else 'false'})")
    a = [int(v) for v in calm.eval("firedOnSim").values()]
    b = [int(v) for v in stalled.eval("firedOnSim").values()]
    assert a == b[:len(a)] and a[:3] == [1, 5, 9]


def test_a_timeout_fires_once_after_its_frames_of_world(hosted):
    rt = hosted
    rt.execute("""
        firedOnSim, sim = {}, 0
        env.set_global_timeout(function() firedOnSim[#firedOnSim + 1] = sim end, 3)
    """)
    for c in "hhrhrhhrrrrr":
        if c == "r":
            rt.execute("sim = sim + 1")
        rt.execute(f"update({'true' if c == 'h' else 'false'})")
    assert [int(v) for v in rt.eval("firedOnSim").values()] == [3]
    assert len(list(rt.eval("globalTimers").keys())) == 0, "the poll outlived its timeout"


def test_in_solo_a_timeout_fires_where_the_engines_would(hosted):
    rt = hosted
    rt.execute("""
        firedAt = nil
        env.set_global_timeout(function() firedAt = frameNo end, 5)
    """)
    play(rt, "r" * 8)
    assert int(rt.eval("firedAt")) == 1005


def test_clearing_a_timer_by_its_id_still_works(hosted):
    rt = hosted
    rt.execute("""
        fired = 0
        local id = env.set_global_timeout(function() fired = fired + 1 end, 3)
        env.clear_callback(id)
    """)
    play(rt, "r" * 6)
    assert int(rt.eval("fired")) == 0
    assert int(rt.eval("report.refused")) == 0, "the mod's own timer id was refused"


def test_an_interval_that_returns_false_stops(hosted):
    rt = hosted
    rt.execute("""
        fired = 0
        env.set_global_interval(function() fired = fired + 1; if fired == 2 then return false end end, 2)
    """)
    play(rt, "r" * 12)
    assert int(rt.eval("fired")) == 2


def test_the_floor_block_still_names_the_api_the_mod_called(hosted):
    rt = hosted
    rt.execute("""
        env.set_global_timeout(function() end, 30)
        env.set_global_interval(function() end, 30)
    """)
    line = str(rt.eval("ModHost.registrationsSinceLastFloor()"))
    assert "set_global_interval +1" in line and "set_global_timeout +1" in line, line


def test_a_timer_with_no_frame_count_goes_to_the_engine_as_it_is(hosted):
    """Whatever the engine makes of a bad argument, it makes of it hosted too."""
    rt = hosted
    rt.execute("env.set_global_interval(function() end, 'soon')")
    timers = rt.eval("globalTimers")
    assert any(str(t["interval"]) == "soon" for t in timers.values())


def test_a_timeout_that_throws_still_runs_only_once(hosted):
    """The engine keeps a poll whose callback raised, as it keeps any interval; its
    own timeout would be gone after one try. So is ours."""
    rt = hosted
    rt.execute("""
        tries = 0
        env.set_global_timeout(function() tries = tries + 1; error('boom') end, 2)
        -- the engine catches a callback's error (handle_function) and carries on
        realUpdate = update
        function update(isHeld) pcall(realUpdate, isHeld) end
    """)
    play(rt, "r" * 8)
    assert int(rt.eval("tries")) == 1
