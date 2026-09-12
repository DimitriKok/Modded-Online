"""Tests that the per-frame crash tracer can arm OUTSIDE a networked run.

`mo_trace.on` exists for the failure mode that leaves nothing else behind: the game
dying in native code with no Lua error. It was armed only inside `init`, which runs
when the log is opened for a NETWORKED RUN -- so for a crash on the main menu, in the
camp lobby, or in single-player with a mod hosted, `traceActive()` was false, every
`frameMark` returned immediately, and `crash_frame.txt` was never created.

That is not a small gap: a hosted mod crashing in single-player is exactly the case
where nothing else records anything, and the flag silently did nothing. It cost a
whole round trip -- flag created, game relaunched, crash reproduced, no file.

Run:  python -m pytest tests/test_trace_arming.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
DESYNC_LOG = (PACK / "src" / "desyncLog.lua").read_text(encoding="utf-8")
NL = chr(10)


def runtime(tmp_path, flags=()):
    for name in flags:
        (tmp_path / name).write_text("", encoding="utf-8")
    root = str(tmp_path).replace(chr(92), "/")
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute('packRoot = "%s"' % root)
    rt.execute("""
function PackPath(rest) return packRoot .. "/" .. rest end
function PackPathWin(rest) return PackPath(rest) end
function dbg() end
function errorf() end
function SafeCall(_n, fn, ...) if fn then return fn(...) end end
ON = {GUIFRAME = 100, PRE_UPDATE = 102, POST_UPDATE = 103, GAMEFRAME = 108,
      LOADING = 104, SCREEN = 21, PRE_LOAD_SCREEN = 105}
function set_callback() return 1 end
function get_ms() return 0 end
function get_frame() return 0 end
function get_local_state() return nil end
function get_adventure_seed() return 0, 0 end
prng = {get_pair = function() return 0, 0 end}
MASK = {FLOOR = 1, ACTIVEFLOOR = 2, MONSTER = 4, ITEM = 8, MOUNT = 16, PLAYER = 32,
        LIQUID = 64, EXPLOSION = 128, FX = 256, BG = 512, SHADOW = 1024, LOGICAL = 2048,
        WATER = 4096, LAVA = 8192}
ENT_TYPE = setmetatable({}, {__index = function() return 0 end})
THEME = setmetatable({}, {__index = function() return 0 end})
SCREEN = setmetatable({}, {__index = function() return 0 end})
FADE = {NONE = 0}
LAYER = {BOTH = -128, FRONT = 0}
QUEST_FLAG = setmetatable({}, {__index = function() return 0 end})
function get_entities_by() return {} end
function get_entity() return nil end
function test_flag() return false end
function get_game_manager() return nil end
function get_type() return nil end
Network = {isInRun = function() return false end, isActive = function() return false end}
""")
    rt.execute(DESYNC_LOG)
    return rt


def test_the_tracer_arms_at_load_not_only_in_a_run(tmp_path):
    """No run has started, and none will. The flag must still take effect."""
    rt = runtime(tmp_path, flags=["mo_trace.on"])
    rt.eval("DesyncLog.frameMark")("guiframe:probe")
    trace = tmp_path / "crash_frame.txt"
    assert trace.exists(), (
        "mo_trace.on produced no crash_frame.txt outside a run -- the flag looks "
        "like it did nothing, which is how a single-player crash went untraced")
    assert "guiframe:probe" in trace.read_text(encoding="utf-8")


def test_without_the_flag_nothing_is_written(tmp_path):
    """It is a file write per callback per frame; it must stay strictly opt-in."""
    rt = runtime(tmp_path)
    rt.eval("DesyncLog.frameMark")("guiframe:probe")
    assert not (tmp_path / "crash_frame.txt").exists()


def test_the_master_off_switch_still_wins(tmp_path):
    """mo_log.off means Modded Online writes NOTHING to disk this session -- that is
    the whole point of it, and the trace is a disk write."""
    rt = runtime(tmp_path, flags=["mo_trace.on", "mo_log.off"])
    rt.eval("DesyncLog.frameMark")("guiframe:probe")
    assert not (tmp_path / "crash_frame.txt").exists(), (
        "mo_log.off did not suppress the frame trace")


def test_the_mark_says_whether_the_callback_finished(tmp_path):
    """IN means the process died inside it; OUT means that one returned."""
    rt = runtime(tmp_path, flags=["mo_trace.on"])
    rt.eval("DesyncLog.frameMark")("preUpdate")
    assert "IN" in (tmp_path / "crash_frame.txt").read_text(encoding="utf-8")
    rt.eval("DesyncLog.frameDone")("preUpdate")
    assert "OUT" in (tmp_path / "crash_frame.txt").read_text(encoding="utf-8")


# ------------------------------------------ naming the HOSTED mod's callback


CALLBACKS = (PACK / "src" / "callbacks.lua").read_text(encoding="utf-8")


def host_runtime(tmp_path, flags=()):
    """callbacks.lua + desyncLog.lua together, the way main.lua loads them."""
    rt = runtime(tmp_path, flags=flags)
    rt.execute("""
-- desyncLog.lua replaced `set_callback` for its own marks; callbacks.lua captures
-- whatever is there when IT loads, which is main.lua's order (callbacks first).
nextId = 500
function set_callback(fn, id) nextId = nextId + 1 return nextId end
function clear_callback() end
debug = debug
PackPath = PackPath
""")
    rt.execute(CALLBACKS)
    return rt


def test_a_hosted_callback_is_named_in_the_trace(tmp_path):
    """The trace marks OUR callbacks only, so a crash inside the engine's update
    reads as "after gameframe:eventSync, before POST_UPDATE" -- correct, and silent
    about which of a hosted mod's 203 registrations was running. hdmod's journal
    alone registers eight in a nested storm.

    A native crash dies INSIDE the call, so what matters is what the file says
    while the mod's callback is on the stack -- which is what this reads.
    """
    rt = host_runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("""
seenDuringCall = nil
function modCallback()
    local f = io.open(packRoot .. "/crash_frame.txt", "r")
    if f ~= nil then
        seenDuringCall = f:read("*a")
        f:close()
    end
end
""")
    rt.eval("Callbacks.hosted")(rt.eval("modCallback"))()
    seen = str(rt.eval("seenDuringCall") or "")
    assert seen.startswith("IN "), (
        "while the mod's callback was running the trace did not name it, so a "
        "native crash inside it would be attributed to whatever ran before: %r" % seen)
    assert "mod " in seen, seen


def test_a_hosted_callback_that_returns_is_marked_done(tmp_path):
    rt = host_runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("function modCallback() return nil end")
    rt.eval("Callbacks.hosted")(rt.eval("modCallback"))()
    text = (tmp_path / "crash_frame.txt").read_text(encoding="utf-8")
    assert "OUT" in text, text


def test_no_trace_flag_means_no_per_call_cost(tmp_path):
    """It is a file write per hosted callback per frame. hdmod registers 203."""
    rt = host_runtime(tmp_path)
    rt.execute("function modCallback() return nil end")
    rt.eval("Callbacks.hosted")(rt.eval("modCallback"))()
    assert not (tmp_path / "crash_frame.txt").exists()


def test_the_hosted_wrapper_still_forwards_and_reraises(tmp_path):
    """The marks must not change what the engine sees: a nil return stays NOTHING
    (ON.PRE_UPDATE distinguishes the two) and an error still propagates."""
    rt = host_runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("function truthy() return true end")
    assert rt.eval("Callbacks.hosted")(rt.eval("truthy"))() is True
    rt.execute("function thrower() error('nope', 0) end")
    raised = False
    try:
        rt.eval("Callbacks.hosted")(rt.eval("thrower"))()
    except Exception:
        raised = True
    assert raised, "an erroring hosted callback stopped propagating"


# ------------------------------------------- what a hosted callback handed back


def test_a_table_return_from_a_hosted_callback_is_recorded(tmp_path):
    """crash_frame.txt is one line, so it says WHERE the process died and nothing
    about what led there. When a hosted callback returns a table the engine consumes
    it the instant we return -- and if that is what kills the process, the contents
    are the only thing left worth knowing. hdmod's ON.POST_LOAD_JOURNAL_CHAPTER
    returns exactly such a table."""
    rt = host_runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("function pages(chapter) return {601, 602, 603} end")
    rt.eval("Callbacks.hosted")(rt.eval("pages"))(5)
    notes = (tmp_path / "crash_notes.txt").read_text(encoding="utf-8")
    assert "table #3" in notes, notes
    assert "601, 602, 603" in notes, notes
    assert "(5)" in notes, "the callback's first argument (the chapter) was not recorded"


def test_a_long_table_is_truncated(tmp_path):
    """Bounded output: a note is a diagnostic, not a dump."""
    rt = host_runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("function many() local t = {} for i = 1, 50 do t[i] = i end return t end")
    rt.eval("Callbacks.hosted")(rt.eval("many"))()
    notes = (tmp_path / "crash_notes.txt").read_text(encoding="utf-8")
    assert "table #50" in notes and "..." in notes, notes


def test_nothing_is_written_without_the_trace_flag(tmp_path):
    rt = host_runtime(tmp_path)
    rt.execute("function pages() return {1, 2} end")
    rt.eval("Callbacks.hosted")(rt.eval("pages"))()
    assert not (tmp_path / "crash_notes.txt").exists()


def test_a_non_table_return_is_not_noted(tmp_path):
    """Most callbacks return nil or a boolean; noting those would bury the signal."""
    rt = host_runtime(tmp_path, flags=["mo_trace.on"])
    rt.execute("function yes() return true end")
    rt.eval("Callbacks.hosted")(rt.eval("yes"))()
    assert not (tmp_path / "crash_notes.txt").exists()
