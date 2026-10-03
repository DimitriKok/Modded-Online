"""A fresh run's QUEST_FLAG.RESET reaches the hosted mods, and only them.

In the game a new run reaches its first level with QUEST_FLAG.RESET raised, and hdmod
does its run setup on it (`lib/flags.lua`, PRE_LEVEL_GENERATION): it raises quest
flags 17, 18 and 19 -- Udjat eye, black market and drill "already spawned" -- so the
game never places its OWN Udjat key and chest on top of the mod's.

applyFreshRunReset zeroes quest_flags in PRE_LOAD_SCREEN and PRE_LEVEL_GENERATION,
and our callbacks run before the hosted mod's, so hdmod never saw the flag. The game
then placed its own Udjat key and chest as well as hdmod's: the reported keys and
chests on both 1-2 and 1-3, sometimes two keys. The capture's floor dumps show it --
quest flag 17 raised by the game itself on the floor it placed them, 18 never at all.

Now the flag is raised again after our reset, for the hosted mods' callbacks, and
taken down by a callback registered after them, before the engine acts on the load.

Run:  python -m pytest tests/test_run_reset_window.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")
MAIN = (PACK / "main.lua").read_text(encoding="utf-8").replace("\r\n", "\n")
HD_FLAGS = PACK.parent / "fyi.hdmod" / "lib" / "flags.lua"

NL = "\n"
RESET = 1
UDJAT, BLACK_MARKET, DRILL = 1 << 16, 1 << 17, 1 << 18  # quest flags 17, 18, 19


def extract(start: str) -> str:
    assert start in EVENT_SYNC, f"{start!r} not found in src/eventSync.lua"
    i = EVENT_SYNC.index(start)
    j = EVENT_SYNC.index(NL + "end" + NL, i)
    return EVENT_SYNC[i:j] + NL + "end" + NL


ENV = """
SCREEN = { CAMP = 11, LEVEL = 12, TRANSITION = 13 }
ON = { PRE_LOAD_SCREEN = 135, PRE_LEVEL_GENERATION = 110 }
QUEST_RESET = 1
module = { runResetShown = false, runResetWindow = false }
levelOrdinal = 0
runActive = true
awaitingRestartUntil = 0
now = 1000
function get_ms() return now end
Network = { isInRun = function() return true end }
st = { quest_flags = 0, screen_next = SCREEN.LEVEL, world = 1, level = 1, theme = 1 }
function get_local_state() return st end
function SafeCall(_, f, ...) return f(...) end

-- the engine's dispatch: every callback for an event, in registration order
callbacks = {}
function set_callback(cb, id)
    callbacks[id] = callbacks[id] or {}
    table.insert(callbacks[id], cb)
    return #callbacks[id]
end
function dispatch(id)
    for _, cb in ipairs(callbacks[id] or {}) do cb() end
end

-- 1. ours, registered when eventSync loads: reset, then show
set_callback(function()
    st.quest_flags = 0                -- applyFreshRunReset
    module.showRunReset()
end, ON.PRE_LEVEL_GENERATION)
set_callback(function()
    st.quest_flags = 0
    module.showRunReset()
end, ON.PRE_LOAD_SCREEN)

-- 2. the hosted mod, registered when it is hosted: hdmod's run setup
-- (lib/flags.lua: "Enable S2 udjat eye, S2 black market, and drill spawns to prevent
-- them from spawning", gated on QUEST_FLAG.RESET)
modSawReset = false
set_callback(function()
    if (st.quest_flags & 1) == 0 then return end
    modSawReset = true
    st.quest_flags = st.quest_flags | (1 << 16) | (1 << 17) | (1 << 18)
end, ON.PRE_LEVEL_GENERATION)
modSawResetAtLoad = false
set_callback(function()
    modSawResetAtLoad = (st.quest_flags & 1) ~= 0
end, ON.PRE_LOAD_SCREEN)
"""


def runtime(install: bool = True):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(extract("function module.showRunReset()"))
    rt.execute(extract("function module.hideRunReset()"))
    rt.execute(extract("function module.installRunResetWindow()"))
    if install:
        # 3. ours again, registered from main.lua after hosting: hide
        rt.execute("module.installRunResetWindow()")
    return rt


def flags(rt) -> int:
    return int(rt.eval("st.quest_flags"))


def test_the_mod_sees_the_run_start_and_switches_the_games_udjat_off():
    rt = runtime()
    rt.execute("dispatch(ON.PRE_LEVEL_GENERATION)")
    assert rt.eval("modSawReset") is True, "the hosted mod never saw the run start"
    f = flags(rt)
    assert f & UDJAT and f & BLACK_MARKET and f & DRILL, (
        "hdmod's run setup did not stick: the game will place its own Udjat key and chest"
    )
    assert f & RESET == 0, "the engine must not see the flag it never saw before"


def test_the_load_callbacks_see_it_too():
    """hdmod resets its character-unlock coffins and custom-entity carry-over on the
    flag in PRE_LOAD_SCREEN."""
    rt = runtime()
    rt.execute("dispatch(ON.PRE_LOAD_SCREEN)")
    assert rt.eval("modSawResetAtLoad") is True
    assert flags(rt) & RESET == 0


def test_only_on_the_runs_first_load():
    rt = runtime()
    rt.execute("levelOrdinal = 1")
    rt.execute("dispatch(ON.PRE_LEVEL_GENERATION)")
    assert rt.eval("modSawReset") is False, "a later floor is not a run start"


def test_not_for_a_load_that_is_not_a_level():
    rt = runtime()
    rt.execute("st.screen_next = SCREEN.TRANSITION")
    rt.execute("dispatch(ON.PRE_LEVEL_GENERATION)")
    assert rt.eval("modSawReset") is False


def test_not_outside_a_run_or_during_a_pending_restart():
    rt = runtime()
    rt.execute("runActive = false")
    rt.execute("dispatch(ON.PRE_LEVEL_GENERATION)")
    assert rt.eval("modSawReset") is False
    rt = runtime()
    rt.execute("awaitingRestartUntil = now + 5000")
    rt.execute("dispatch(ON.PRE_LEVEL_GENERATION)")
    assert rt.eval("modSawReset") is False


def test_never_raised_without_the_callback_that_lowers_it():
    """Without the late callback the flag would outlive the hosted mods' callbacks
    and reach the engine. Better to show nothing than that."""
    rt = runtime(install=False)
    rt.execute("dispatch(ON.PRE_LEVEL_GENERATION)")
    assert rt.eval("modSawReset") is False
    assert flags(rt) & RESET == 0


def test_hide_only_lowers_a_flag_we_raised():
    """A reset the engine raised itself (a player's restart) belongs to the restart
    guards, not to this window."""
    rt = runtime()
    rt.execute("st.quest_flags = 1 | (1 << 4)")
    rt.execute("module.hideRunReset()")
    assert flags(rt) == 1 | (1 << 4)
    rt.execute("module.showRunReset()")
    rt.execute("module.hideRunReset()")
    assert flags(rt) == (1 << 4), "only the RESET bit is lowered, nothing else"


def test_installing_twice_registers_once():
    rt = runtime()
    rt.execute("module.installRunResetWindow()")
    assert int(rt.eval("#callbacks[ON.PRE_LEVEL_GENERATION]")) == 3


def test_it_is_wired_in():
    """Shown last in our own early callbacks, lowered by callbacks main.lua registers
    after the hosted mods, with a POST_LEVEL_GENERATION backstop."""
    load = EVENT_SYNC.index('SafeCall("eventSync:onPreLoadScreen", onPreLoadScreen)')
    assert EVENT_SYNC.index('SafeCall("eventSync:showRunReset", module.showRunReset)', load) > load
    gen = EVENT_SYNC.index('SafeCall("eventSync:onPreLevelGeneration", onPreLevelGeneration)')
    assert EVENT_SYNC.index('SafeCall("eventSync:showRunReset", module.showRunReset)', gen) > gen
    post = EVENT_SYNC.index('DesyncLog.enter("postLevelGeneration")')
    backstop = EVENT_SYNC.index('SafeCall("eventSync:hideRunReset", module.hideRunReset)', post)
    assert backstop < EVENT_SYNC.index("onPostLevelGeneration)", post)
    hosting = MAIN.index("ModHost.hostOne")
    assert MAIN.index("EventSync.installRunResetWindow") > hosting, (
        "registered before the hosted mods, it would run before their callbacks"
    )


def test_hdmods_run_setup_is_still_gated_on_the_reset_flag():
    """The premise, checked against the installed hdmod when it is there."""
    if not HD_FLAGS.exists():
        return
    text = HD_FLAGS.read_text(encoding="utf-8")
    i = text.index("-- Enable S2 udjat eye")
    block = text[text.rindex("set_callback(function()", 0, i):text.index("end, ON.PRE_LEVEL_GENERATION)", i)]
    assert "QUEST_FLAG.RESET" in block and "{ 17, 18, 19 }" in block
