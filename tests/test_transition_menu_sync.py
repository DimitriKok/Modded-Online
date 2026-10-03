"""A transition's menu input is lockstepped, so Mama Tunnel's dialogue runs the same
on every machine.

Her dialogue on a TRANSITION, and hdmod's shortcut donations that ride on it
(`lib/shortcut.lua`), are driven by the engine's MENU input,
`game_manager.game_props.input_menu`, read from each machine's own devices. The gate
fed the player slots and never touched it, so the dialogue advanced only on the
machine whose player pressed. hdmod's donation takes the bombs from player 1 first, so
one machine took the host's bomb and the other never did: a bomb count that never
agreed again, plus a POSITION DESYNC on that transition while one machine's party
stood frozen in the dialogue.

Now the menu input rides in the same per-frame record as the gameplay input, and on
every simulated transition frame the engine (and hdmod, whose PRE_UPDATE runs after
ours) reads the PARTY's menu input. The device's own value goes back at POST_UPDATE
for the journal and pause menu, which read it after the update.

These tests run the shipped `preUpdate`, extracted verbatim, on two simulated
machines that exchange their records like the network does.

Run:  python -m pytest tests/test_transition_menu_sync.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")

NL = "\n"
SELECT, BACK, JOURNAL, LEFT, RIGHT, UP, DOWN = 1, 2, 16, 32, 64, 128, 256
SEQ = 5
INPUT_DELAY = 7
HOLD = 10  # the harness's transition hold, shorter than the shipped 60 to keep runs small


def extract(start: str) -> str:
    assert start in INPUT_SYNC, f"{start!r} not found in src/inputSync.lua"
    i = INPUT_SYNC.index(start)
    j = INPUT_SYNC.index(NL + "end" + NL, i)
    return INPUT_SYNC[i:j] + NL + "end" + NL


def constants() -> str:
    start = "local MENU_SHIFT = 16"
    end = "local menuRestorePrev = 0" + NL
    assert start in INPUT_SYNC and end in INPUT_SYNC
    i = INPUT_SYNC.index(start)
    j = INPUT_SYNC.index(end, i) + len(end)
    return INPUT_SYNC[i:j]


# One chunk, so the helpers' locals are the upvalues preUpdate really closes over.
CHUNK = (
    constants()
    + extract("local function readMenuFields(gm)")
    + extract("local function localMenuField(typing)")
    + extract("local function packRecord(gameplay, menuField)")
    + extract("local function writeMenuFields(props, now, prev)")
    + extract("local function applyAgreedMenu(field)")
    + extract("local function restoreDeviceMenu()")
    + extract("local function preUpdate()")
    + """
preUpdateG = preUpdate
restoreG = restoreDeviceMenu
localMenuFieldG = localMenuField
packRecordG = packRecord
applyAgreedMenuG = applyAgreedMenu
function menuStateG() return menuLatch, menuAgreedPrev, menuRestorePending, menuSyncBroken end
MENU = { SHIFT = MENU_SHIFT, SYNC = MENU_SYNC_MASK, UI = MENU_UI_OPEN, GAMEPLAY = GAMEPLAY_MASK }
"""
)

ENV = """
SCREEN = { CAMP = 11, LEVEL = 12, TRANSITION = 13, DEATH = 14 }
FADE = { NONE = 0, OUT = 1, LOAD = 2, IN = 3 }
ENGINE_PAUSE_MASK = 1 | 2 | 8 | 16 | 32
PAUSE_CUTSCENE = 4
TRANSITION_HOLD = %(hold)d
INPUT_DELAY = %(delay)d
REDUNDANCY = 18
CHECK_EVERY = 120
SENTINEL = 1 << 15
sentinelSupported = true
MENU_OFF_FRAMES = 8
active = true
EventSync = nil
DesyncLog = nil
Chat = nil
myModValue = nil
modUiPauseWas = false
menuSyncOn = false
menuOffFrames = 0
awaitLoadBoundary = false
engaged = true
engagedScreen = SCREEN.TRANSITION
seq = %(seq)d
offset = 0
myRecorded = INPUT_DELAY - 1
coopSlots = { 1, 2 }
goneSlots = {}
droppedKit = {}
lastInjected = nil
stallStartMs = nil
stallReportedMs = nil
localHeld = false
module = { sendChecksum = function() end }
function SafeCall(_, f, ...) return f(...) end
errors = {}
function errorf(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
function get_ms() return 0 end
function sendRecentInputs() end
stalls = 0
function reportStall() stalls = stalls + 1 end
function menuSyncTick() end
function menuSyncStop() end
function get_player() return nil end
function allRealPlayersDead() return false end
function hidePlayerEntity() end
function dropGoneKit() end
function engage() error("the harness engages by hand") end
Network = { slot = %(slot)d, isInRun = function() return true end }
slots = {}
for i = 1, 4 do slots[i] = { buttons = 0, buttons_gameplay = 0 } end
st = { screen = SCREEN.TRANSITION, screen_next = SCREEN.TRANSITION, loading = FADE.NONE,
       pause = 0, player_inputs = { player_slots = slots } }
function get_local_state() return st end
gm = { game_props = { input_menu = 0, input_menu_previous = 0 },
       pause_ui = { visibility = 0 }, journal_ui = { state = 0 } }
function GameManager() return gm end
inputBuf = { [1] = { [seq] = {} }, [2] = { [seq] = {} } }
for f = 0, INPUT_DELAY - 1 do inputBuf[1][seq][f] = 0; inputBuf[2][seq][f] = 0 end
"""


def machine(slot: int, hold: int = HOLD):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV % {"hold": hold, "delay": INPUT_DELAY, "seq": SEQ, "slot": slot})
    rt.execute(CHUNK)
    return rt


def device(rt, now: int, prev: int):
    """What the engine's input processing leaves in the field before PRE_UPDATE."""
    rt.execute(f"gm.game_props.input_menu = {now}; gm.game_props.input_menu_previous = {prev}")


def seen(rt):
    return int(rt.eval("gm.game_props.input_menu")), int(rt.eval("gm.game_props.input_menu_previous"))


def record_at(rt, slot: int, frame: int):
    v = rt.eval(f"inputBuf[{slot}][{SEQ}][{frame}]")
    return None if v is None else int(v)


def deliver(src, dst, slot: int, frame: int):
    v = record_at(src, slot, frame)
    if v is not None:
        dst.execute(f"inputBuf[{slot}][{SEQ}][{frame}] = {v}")


def run(press_a, press_b, frames=40, hold=HOLD, b_late_until=None, extra_a=0):
    """Both machines step together. `press_x(frame)` is that machine's device menu
    input on that render frame. Returns, per machine, the (input_menu,
    input_menu_previous) the engine and hdmod saw on each SIMULATED frame, keyed by
    the gate offset, plus what POST_UPDATE left behind.

    `b_late_until`: B's records do not reach A until that render frame, so A stalls
    in between -- the case the menu latch exists for."""
    a, b = machine(1, hold), machine(2, hold)
    out = {"a": {}, "b": {}, "a_after": {}, "b_after": {}}
    prev = {"a": 0, "b": 0}
    pending_b = []
    for frame in range(frames):
        for name, rt, press, extra in (("a", a, press_a, extra_a), ("b", b, press_b, 0)):
            now = press(frame) | extra
            device(rt, now, prev[name])
            prev[name] = now
            offset = int(rt.eval("offset"))
            held = rt.eval("preUpdateG()")
            if held is not True:
                out[name][offset] = seen(rt)
                rt.eval("restoreG()")  # POST_UPDATE
                out[name + "_after"][offset] = seen(rt)
        # the network: each machine's newest record reaches the other
        for f in range(frames + INPUT_DELAY + 1):
            deliver(a, b, 1, f)
            if b_late_until is not None and frame < b_late_until:
                if record_at(b, 2, f) is not None and f not in pending_b:
                    pending_b.append(f)
            else:
                deliver(b, a, 2, f)
    return out, a, b


def edges(seen_by_offset):
    """Offsets at which hdmod's donation check fires: SELECT rising (lib/shortcut.lua)."""
    return [o for o, (now, prev) in sorted(seen_by_offset.items())
            if (prev & SELECT) == 0 and (now & SELECT) != 0]


def nothing(_frame):
    return 0


# ----------------------------------------------------------------- end to end

def test_one_players_press_reaches_both_machines_on_the_same_frame():
    """The reported bug: one player presses, the dialogue advances on every machine."""
    out, _, _ = run(lambda f: SELECT if f in (20, 21, 22) else 0, nothing)
    assert edges(out["a"]) == edges(out["b"]) == [20 + INPUT_DELAY], (
        "the press reached the dialogue on one machine only, or on different frames"
    )


def test_every_simulated_frame_sees_the_same_menu_input_everywhere():
    out, _, _ = run(lambda f: SELECT if f in (12, 13) else (DOWN if f in (25, 26, 27) else 0),
                    lambda f: LEFT if f in (18, 19) else 0)
    sync = SELECT | BACK | LEFT | RIGHT | UP | DOWN
    a = {o: (n & sync, p & sync) for o, (n, p) in out["a"].items()}
    b = {o: (n & sync, p & sync) for o, (n, p) in out["b"].items()}
    assert a == b
    assert any(n & DOWN for n, _ in a.values()), "DOWN (the yes/no choice) must be synced too"
    assert any(n & LEFT for n, _ in a.values())


def test_the_transition_hold_keeps_menu_input_neutral_too():
    """The first second of a transition holds everyone's input neutral; a press then
    must not slip through on the menu path either."""
    out, _, _ = run(lambda f: SELECT if f == 1 else 0, nothing, hold=HOLD)
    assert edges(out["a"]) == edges(out["b"]) == []


def test_a_tap_during_a_stall_is_latched_not_lost():
    """The gate records each frame once. A tap that comes and goes while it is
    stalled used to be lost for good; now it lands in the next frame recorded."""
    # B's records reach A late, so A stalls from about frame 14 on; A's player taps
    # SELECT for exactly one render frame inside that stall.
    out, a, b = run(lambda f: SELECT if f == 16 else 0, nothing, frames=60, b_late_until=24)
    assert int(a.eval("stalls")) > 0, "the harness did not make A stall"
    assert len(edges(out["a"])) == 1, "the tap was lost (or doubled)"
    assert edges(out["a"]) == edges(out["b"])


def test_the_device_value_is_back_after_the_update():
    """The journal and pause menu read the field after the update: they must get this
    player's own input, exactly as the device left it."""
    out, _, _ = run(lambda f: SELECT if f in (20, 21) else 0, lambda f: RIGHT if f == 30 else 0)
    for frame, (now, prev) in out["a_after"].items():
        device_now = SELECT if frame in (20, 21) else 0
        device_prev = SELECT if frame in (21, 22) else 0
        assert (now, prev) == (device_now, device_prev), frame


def test_a_local_journal_press_stays_local():
    """JOURNAL is not synced: opening a journal is this player's own business."""
    out, _, _ = run(nothing, nothing, extra_a=JOURNAL)
    assert all(n & JOURNAL for n, _ in out["a"].values())
    assert not any(n & JOURNAL for n, _ in out["b"].values())


# ----------------------------------------------------------------- the pieces

def test_off_a_transition_the_record_is_exactly_what_it_was():
    rt = machine(1)
    rt.execute("engagedScreen = SCREEN.LEVEL")
    device(rt, SELECT | DOWN, 0)
    assert int(rt.eval("localMenuFieldG(false)")) == 0
    for raw in (0, 1, 2048, 4095, 1 << 15):
        assert int(rt.eval(f"packRecordG({raw}, 0)")) == raw


def test_the_record_layout_never_touches_the_gameplay_bits():
    rt = machine(1)
    shift = int(rt.eval("MENU.SHIFT"))
    sync = int(rt.eval("MENU.SYNC"))
    ui = int(rt.eval("MENU.UI"))
    gameplay = int(rt.eval("MENU.GAMEPLAY"))
    assert gameplay == 0xFFFF and shift >= 16, "INPUTS (bits 0-11) and the sentinel (bit 15)"
    assert ((sync | ui) << shift) & gameplay == 0
    assert ((sync | ui) << shift) < 2 ** 53, "must survive the JSON wire as an exact number"
    assert sync & JOURNAL == 0 and sync & ui == 0
    packed = int(rt.eval(f"packRecordG(2048 + 1, {SELECT | DOWN})"))
    assert packed & gameplay == 2049 and packed >> shift == SELECT | DOWN


def test_presses_into_this_players_own_menus_are_not_recorded():
    rt = machine(1)
    device(rt, SELECT, 0)
    rt.execute("gm.journal_ui.state = 2")
    assert int(rt.eval("localMenuFieldG(false)")) == 0
    rt.execute("gm.journal_ui.state = 0")
    device(rt, SELECT, SELECT)
    assert int(rt.eval("localMenuFieldG(true)")) == 0, "typing in chat"
    rt.execute("gm.pause_ui.visibility = 2")
    device(rt, SELECT, SELECT)
    assert int(rt.eval("localMenuFieldG(false)")) == int(rt.eval("MENU.UI")), (
        "an open pause menu is flagged, and its presses are not recorded"
    )


def test_an_open_pause_menu_anywhere_mutes_that_frame_for_everyone():
    """hdmod only handles a donation while pause_ui.visibility == 0 on its own
    machine, so a press must not reach a frame where somebody's pause menu is up."""
    rt = machine(1)
    ui = int(rt.eval("MENU.UI"))
    device(rt, 0, 0)
    rt.eval(f"applyAgreedMenuG({SELECT | ui})")
    assert seen(rt)[0] & SELECT == 0


def test_the_previous_frame_is_the_agreed_one():
    rt = machine(1)
    device(rt, 0, 0)
    rt.eval(f"applyAgreedMenuG({SELECT})")
    rt.eval("restoreG()")
    device(rt, SELECT, 0)  # the device says SELECT is newly pressed...
    rt.eval(f"applyAgreedMenuG({SELECT})")
    now, prev = seen(rt)
    assert now & SELECT and prev & SELECT, "...but the party has held it since last frame"


def test_a_restore_left_over_from_a_skipped_post_update_is_dropped():
    rt = machine(1)
    device(rt, 0, 0)
    rt.eval(f"applyAgreedMenuG({SELECT})")
    assert rt.eval("(select(3, menuStateG()))") is True
    rt.execute("active = false")  # preUpdate's very first line still runs
    rt.eval("preUpdateG()")
    assert rt.eval("(select(3, menuStateG()))") is False


def test_it_is_wired_into_the_gate():
    pre = extract("local function preUpdate()")
    assert pre.index("menuRestorePending = false") < pre.index("if not active")
    assert pre.index("localMenuField(") < pre.index("if myBuf[seq][target] == nil then"), (
        "read every frame, stalled or not, or a tap during a stall is never latched"
    )
    assert "myBuf[seq][target] = packRecord(raw, menuField)" in pre
    assert "local value = packed & GAMEPLAY_MASK" in pre
    assert 'if inTransition then\n        SafeCall("inputSync:applyAgreedMenu"' in pre
    assert 'SafeCall("inputSync:restoreDeviceMenu", restoreDeviceMenu)' in INPUT_SYNC


def test_a_build_that_refuses_the_write_is_left_exactly_as_it_was():
    """The pair is written previous-first: the current input overridden without its
    previous one would read a held press as a new one every frame. If either write is
    refused the sync switches itself off and the device's values stay put."""
    rt = machine(1)
    rt.execute("""
        local real = { input_menu = 0, input_menu_previous = 0 }
        gm.game_props = setmetatable({}, {
            __index = real,
            __newindex = function(_, k, v)
                if k == "input_menu_previous" then error("read-only field") end
                real[k] = v
            end,
        })
    """)
    rt.eval(f"applyAgreedMenuG({SELECT})")
    assert int(rt.eval("gm.game_props.input_menu")) == 0, "half of the pair was overridden"
    assert rt.eval("(select(4, menuStateG()))") is True
    assert rt.eval("(select(3, menuStateG()))") is False, "nothing to restore"
    assert int(rt.eval("#errors")) == 1
    rt.eval(f"applyAgreedMenuG({SELECT})")
    assert int(rt.eval("#errors")) == 1, "said once, not every frame"

