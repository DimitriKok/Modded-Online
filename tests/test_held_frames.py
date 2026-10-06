"""A hosted mod's update callbacks run once per SIMULATED frame.

ON.PRE_UPDATE and ON.POST_UPDATE fire once per rendered frame -- including every
frame the lockstep gate holds the world still while it waits for another machine's
inputs (dev44 watched the leak sweep re-run on every frame of a stall). The engine
does not tick on a held frame, but a hosted mod's update callbacks still ran on it,
and how many held frames a machine sees is decided by its network.

Found reading the code behind the BGNY capture, not in the capture itself: 2.5's
Wheel of Fortune turns one step per POST_UPDATE (motion.update), so on the machine
that stalled more the wheel would stop -- and pay out, or open the prize cubby -- on
an earlier simulated frame than on the other. Its swamp water-poison count, the push
its monkey propeller adds before physics and every everyNthFrame wrapper have the
same shape.

Also here: the gate's half (InputSync.heldFrame) and the local menu pause, which a
tabbed-out player would still have up on the frame a level finishes fading in -- the
frame whose POST_UPDATE is where the wheel decides its shop.

Run:  python -m pytest tests/test_held_frames.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")

NL = chr(10)

ENGINE = """
registered = {}
function get_adventure_seed() return 0x1EAF9223, 0xCA8F7F71 end
function get_local_state() return { world = 2, level = 1, theme = 2, time_total = 0 } end
function seed_prng() end
prng = { get_pair = function(_, c) return c, c end, set_pair = function() end }
ON = {
    FRAME = 1, GAMEFRAME = 2, LOADING = 3, LEVEL = 4,
    PRE_LEVEL_GENERATION = 5, POST_LEVEL_GENERATION = 6,
    PRE_LOAD_LEVEL_FILES = 7, PRE_LOAD_SCREEN = 8,
    PRE_UPDATE = 9, POST_UPDATE = 10, GUIFRAME = 11,
}
function set_callback(fn, id)
    registered[#registered + 1] = { fn = fn, id = id }
    return #registered
end
function fire(id, ...)
    local result
    for _, entry in ipairs(registered) do
        if entry.id == id then
            local r = entry.fn(...)
            if r ~= nil then result = r end
        end
    end
    return result
end
held = false
-- one rendered frame: the gate decides, then the engine ticks (or not), then POST
function frame(isHeld)
    held = isHeld
    fire(ON.PRE_UPDATE)
    if not isHeld then fire(ON.GAMEFRAME) end
    fire(ON.POST_UPDATE)
    fire(ON.GUIFRAME)
end
"""

# 2.5's wheel, in its own shape: one step of the spin per POST_UPDATE, settling
# (add_money, the prize) on the step that reaches the end
WHEEL = """
steps, settledOnSim, simFrame = 0, nil, 0
env.set_callback(function() simFrame = simFrame + 1 end, ON.GAMEFRAME)
env.set_callback(function()
    steps = steps + 1
    if steps == 6 and settledOnSim == nil then settledOnSim = simFrame end
end, ON.POST_UPDATE)
"""


def install(rt, opts="{ heldFrame = function() return held end }"):
    rt.execute(DETERMINISM)
    rt.execute("env = setmetatable({}, {__index = _G})")
    return rt.eval("Determinism.install")(rt.eval("env"), rt.eval(opts))


def runtime(opts="{ heldFrame = function() return held end }"):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    control = install(rt, opts)
    return rt, control


def play(rt, pattern):
    """'r' a simulated frame, 'h' a frame the gate held."""
    for c in pattern:
        rt.execute(f"frame({'true' if c == 'h' else 'false'})")


def test_a_machine_that_stalled_spins_the_wheel_no_further_than_one_that_did_not():
    """The capture's shape: the same eight simulated frames, one machine with stalls
    between them. The wheel must stop on the same simulated frame on both."""
    pattern = "rhrhhhrrhrrhhrr"
    assert pattern.count("r") == 8
    calm, _ = runtime()
    calm.execute(WHEEL)
    play(calm, "r" * 8)
    stalled, control = runtime()
    stalled.execute(WHEEL)
    play(stalled, pattern)
    assert int(calm.eval("steps")) == int(stalled.eval("steps")) == 8
    assert calm.eval("settledOnSim") == stalled.eval("settledOnSim") == 6
    assert int(control["stats"]()["heldSkips"]) == pattern.count("h")


def test_without_it_the_stalled_machine_would_have_paid_out_sooner():
    """The premise: counting rendered frames, the stalled machine settles early."""
    rt, _ = runtime("{ heldFrame = function() return false end }")
    rt.execute(WHEEL)
    play(rt, "rhrhhhrr")
    assert int(rt.eval("settledOnSim")) == 2, "the wheel stopped on simulated frame 2, not 6"


def test_the_mods_pre_update_is_skipped_too_and_keeps_its_return_otherwise():
    """A PRE_UPDATE that pushes before physics must not push on a frame with no physics;
    on a real frame its return (true = skip the tick) still reaches the engine."""
    rt, _ = runtime()
    rt.execute("""
        pushes = 0
        env.set_callback(function() pushes = pushes + 1; return 'skip' end, ON.PRE_UPDATE)
    """)
    play(rt, "rhhr")
    assert int(rt.eval("pushes")) == 2
    rt.execute("held = false")
    assert rt.eval("fire(ON.PRE_UPDATE)") == "skip"
    rt.execute("held = true")
    assert rt.eval("fire(ON.PRE_UPDATE)") is None


def test_every_other_event_is_left_alone():
    rt, _ = runtime()
    rt.execute("""
        gui, level = 0, 0
        env.set_callback(function() gui = gui + 1 end, ON.GUIFRAME)
        env.set_callback(function() level = level + 1 end, ON.LEVEL)
    """)
    play(rt, "rhhr")
    rt.execute("held = true; fire(ON.LEVEL)")
    assert int(rt.eval("gui")) == 4, "the mod's own UI keeps drawing through a stall"
    assert int(rt.eval("level")) == 1


def test_the_gate_is_asked_through_InputSync_by_default():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute("InputSync = { heldFrame = function() return held end }")
    install(rt, "{}")
    rt.execute(WHEEL)
    play(rt, "rhhr")
    assert int(rt.eval("steps")) == 2


def test_without_InputSync_nothing_is_skipped():
    """The tests' world, and a build whose gate failed to load: nothing to ask."""
    rt, _ = runtime("{}")
    rt.execute(WHEEL)
    play(rt, "rhhr")
    assert int(rt.eval("steps")) == 4


# ------------------------------------------------------------- the gate's half

def _slice(start: str, end: str) -> str:
    assert start in INPUT_SYNC, f"{start!r} not found in src/inputSync.lua"
    i = INPUT_SYNC.index(start)
    j = INPUT_SYNC.index(end, i)
    return INPUT_SYNC[i:j + len(end)]


def extract(start: str) -> str:
    """One top-level function, verbatim: from its header to the first column-0 `end`."""
    return _slice(start, NL + "end" + NL)


GATE_ENV = """
module = {}
active = true
Network = { isInRun = function() return true end }
lastResendMs, RESEND_INTERVAL_MS = 0, 1000000
function get_ms() return 0 end
function sendRecentInputs() end
DesyncLog = nil
function SafeCall(_, f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end
gateSays = nil
function preUpdate()
    if gateSays == 'throw' then error('broken gate') end
    return gateSays
end
ON = { PRE_UPDATE = 9 }
registered = nil
function set_callback(fn) registered = fn; return 1 end
"""


def gate():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(GATE_ENV)
    assert "local heldNow = false" in INPUT_SYNC
    registration = _slice("set_callback(function()\n    -- The resend keepalive",
                          "end, ON.PRE_UPDATE)")
    rt.execute("local heldNow = false" + NL + extract("function module.heldFrame()")
               + registration + NL)
    return rt


def test_the_gate_reports_the_frame_it_held_and_only_that_frame():
    rt = gate()
    rt.execute("gateSays = true")
    assert rt.eval("registered()") is True
    assert rt.eval("module.heldFrame()") is True
    rt.execute("gateSays = nil")
    assert rt.eval("registered()") is None
    assert rt.eval("module.heldFrame()") is False


def test_a_gate_tick_that_failed_is_not_a_held_frame():
    """The tick proceeds when the gate throws, so the mod must run on it too."""
    rt = gate()
    rt.execute("gateSays = true; registered()")
    rt.execute("gateSays = 'throw'")
    assert rt.eval("registered()") is None
    assert rt.eval("module.heldFrame()") is False


PRE_UPDATE_ENV = """
SCREEN = { CAMP = 11, LEVEL = 12, TRANSITION = 13, DEATH = 14 }
FADE = { NONE = 0, OUT = 1, LOAD = 2, IN = 3 }
ENGINE_PAUSE_MASK = 1 | 2 | 8 | 16 | 32
MENU_OFF_FRAMES = 8
active = true
Network = { isInRun = function() return true end }
EventSync = nil
DesyncLog = nil
function SafeCall(_, f, ...) return f(...) end
function menuSyncTick() end
function menuSyncStop() end
modUiPauseWas = false
menuSyncOn = false
menuOffFrames = 0
awaitLoadBoundary = true -- returns right after the held decision
engaged = false
localHeld = nil
slots = {}
for i = 1, 4 do slots[i] = { buttons = 0, buttons_gameplay = 0 } end
st = { screen = SCREEN.LEVEL, loading = FADE.NONE, pause = 0,
       player_inputs = { player_slots = slots } }
function get_local_state() return st end
"""


def pause_after(screen="LEVEL", loading="NONE", pause=0):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(PRE_UPDATE_ENV)
    rt.execute(extract("local function preUpdate()") + "preUpdateG = preUpdate" + NL)
    rt.execute(f"st.screen = SCREEN.{screen}; st.loading = FADE.{loading}; st.pause = {pause}")
    rt.execute("preUpdateG()")
    return int(rt.eval("st.pause"))


def test_the_menu_pause_does_not_stand_while_a_level_fades_in():
    """A tabbed-out player at the moment 2-1 loads: flag 1 is down by the time the
    fade finishes, as it is on every gated frame."""
    assert pause_after(loading="IN", pause=1) == 0


def test_only_the_menu_flag_is_cleared_during_a_fade():
    """The fade/loading pause (2) is the engine's own and must stand."""
    assert pause_after(loading="IN", pause=1 | 2) == 2
    assert pause_after(loading="OUT", pause=2) == 2


def test_a_run_screen_outside_the_gate_keeps_its_menu_pause():
    """The death screen with no fade in flight: not ours to unpause."""
    assert pause_after(screen="DEATH", pause=1) == 1


def test_a_gated_frame_still_clears_it_as_before():
    assert pause_after(pause=1) == 0
