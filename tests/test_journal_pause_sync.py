"""A content mod's own pause must not read as a desync, and a resync warp must not
land inside one.

hdmod's tutorial opens a story journal at the start of every floor and freezes the
game (the fade pause, 2, with no load in flight) until that player closes it. Each
player closes theirs on their own time. In the session these tests come from:

  * the peer closed first and waited on the host's inputs for its new sequence;
  * the host, still reading, kept resending its OLD sequence (its gate cannot
    engage while its sim is held), so after 4 s the peer's stall detector read
    "live peer on a different sequence" and asked for a resync warp;
  * the warp reached the host while its journal was still open. hdmod resumes its
    fade on close with `state.loading = FADE.IN`, which overwrote the FADE.OUT that
    warp() had started: the host never regenerated the floor, the gate took hdmod's
    fade as the warp's load boundary, and engaged the rebased sequence on the OLD
    floor while the peer regenerated it. FLOOR DESYNC on 1-2 and every floor after.

Both halves are exercised here against the shipped functions, extracted verbatim.

Run:  python -m pytest tests/test_journal_pause_sync.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8")
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")

NL = chr(10)


def extract(source: str, start: str) -> str:
    """One top-level function, verbatim: from its header to the first column-0 `end`."""
    source = source.replace("\r\n", NL)
    assert start in source, f"{start!r} not found"
    i = source.index(start)
    end = NL + "end" + NL
    j = source.index(end, i)
    return source[i:j] + end


# ---------------------------------------------------------------- inputSync

INPUT_ENV = """
now = 100000
function get_ms() return now end
module = { rxCount = 0, lastRx = "" }
Network = { slot = 2 }
seq = 2
stallStartMs = nil
coopSlots = { 1, 2 }
goneSlots = {}
inputBuf = { [1] = {}, [2] = {} }
remoteLastSeq = {}
remoteLastRxMs = {}
remoteHeldMs = {}
HELD_GRACE_MS = 3000
"""


def input_lua():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(INPUT_ENV)
    assert "local remoteHeldMs = {}" in INPUT_SYNC
    assert "local HELD_GRACE_MS = 3000" in INPUT_SYNC
    rt.execute(extract(INPUT_SYNC, "function module.stallDesyncRole()"))
    rt.execute(extract(INPUT_SYNC, "local function onRemoteInputs(netSlot, data)")
               + "onRemoteInputsG = onRemoteInputs" + NL)
    return rt


def receive(rt, s, held=False):
    """An input packet from the host (slot 1) carrying sequence `s`."""
    rt.execute(f"onRemoteInputsG(1, {{ s = {s}, f = 0, i = {{ 0 }}, h = {1 if held else 'nil'} }})")


def role(rt):
    return rt.eval("module.stallDesyncRole()")


def stalled_for(rt, ms):
    rt.execute(f"stallStartMs = now - {ms}")


def test_a_live_peer_on_an_older_sequence_still_classifies():
    """The detector's real job is unchanged: a peer that is RUNNING on another sequence."""
    rt = input_lua()
    receive(rt, 1)
    stalled_for(rt, 5000)
    assert role(rt) == "ahead"


def test_a_peer_held_in_a_mod_pause_does_not_classify():
    """The session: host reading hdmod's journal, still on seq 1, peer on seq 2."""
    rt = input_lua()
    receive(rt, 1, held=True)
    stalled_for(rt, 5000)
    assert role(rt) is None, (
        "a peer whose sim is held by a mod's own pause was read as a desync -- "
        "this is the resync warp that broke the tutorial's floor 2"
    )


def test_the_hold_outlives_a_few_packets_without_the_flag():
    """hdmod resumes its fade after the journal closes; a packet or two can go out
    on the old sequence before the gate engages the new one. The grace covers it."""
    rt = input_lua()
    receive(rt, 1, held=True)
    stalled_for(rt, 5000)
    rt.execute("now = now + 1500")
    receive(rt, 1, held=False)
    assert role(rt) is None


def test_the_hold_expires():
    """A peer that STAYS on an old sequence after it stopped being held is a real
    divergence again: detection is delayed by the grace, never switched off."""
    rt = input_lua()
    receive(rt, 1, held=True)
    stalled_for(rt, 5000)
    rt.execute("now = now + 3001")
    receive(rt, 1, held=False)
    assert role(rt) == "ahead"


def test_a_peer_on_a_higher_sequence_still_reads_as_behind():
    rt = input_lua()
    receive(rt, 3)
    stalled_for(rt, 5000)
    assert role(rt) == "behind"


def test_the_flag_goes_on_the_wire_only_when_held():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        sent = nil
        Network = { slot = 1, sendState = function(d) sent = d end }
        inputBuf = { [1] = { [4] = { [0] = 5, [1] = 6 } } }
        seq = 4
        myRecorded = 1
        REDUNDANCY = 14
        stallStartMs = nil
        localHeld = false
        function get_ms() return 0 end
    """)
    rt.execute(extract(INPUT_SYNC, "local function sendRecentInputs()")
               + "sendG = sendRecentInputs" + NL)
    rt.execute("sendG()")
    assert rt.eval("sent.h") is None, "a running machine must send exactly what it always did"
    assert int(rt.eval("sent.s")) == 4
    rt.execute("localHeld = true; sendG()")
    assert int(rt.eval("sent.h")) == 1


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


def pre_update(screen="LEVEL", loading="NONE", pause=0):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(PRE_UPDATE_ENV)
    rt.execute(extract(INPUT_SYNC, "local function preUpdate()") + "preUpdateG = preUpdate" + NL)
    rt.execute(f"st.screen = SCREEN.{screen}; st.loading = FADE.{loading}; st.pause = {pause}")
    rt.execute("preUpdateG()")
    return rt.eval("localHeld")


def test_held_while_a_mod_holds_its_own_pause():
    """hdmod's journal: the fade pause (2) up with no load in flight."""
    assert pre_update(pause=2) is True


def test_held_while_loading():
    assert pre_update(loading="IN", pause=2) is True


def test_not_held_while_the_sim_runs():
    assert pre_update() is False


def test_not_held_on_a_run_screen_outside_the_gate():
    """The death screen is not a pause; it must classify exactly as before."""
    assert pre_update(screen="DEATH") is False


# ---------------------------------------------------------------- eventSync

WARP_ENV = """
FADE = { NONE = 0, OUT = 1, LOAD = 2, IN = 3 }
runActive = true
Network = { isInRun = function() return true end }
st = { loading = FADE.NONE, pause = 0 }
function get_local_state() return st end
rebasedTo = nil
warpedTo = nil
InputSync = { rebase = function(q) rebasedTo = q end }
function moWarp(w, l, t) warpedTo = { w, l, t } end
function errorf() end
function toast() end
DesyncLog = nil
pendingWarp = { w = 1, l = 2, t = 1, a = 11, b = 22, ord = 1, q = 9 }
"""


def warp_lua():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(WARP_ENV)
    rt.execute(extract(EVENT_SYNC, "local function applyPendingWarp()")
               + "applyG = applyPendingWarp" + NL)
    return rt


def test_the_warp_waits_while_a_mod_holds_its_own_pause():
    rt = warp_lua()
    rt.execute("st.pause = 2")  # hdmod's story journal is open
    rt.execute("applyG()")
    assert rt.eval("warpedTo") is None, (
        "warped inside hdmod's open journal: closing it overwrites the warp's "
        "FADE.OUT with FADE.IN and the floor is never regenerated on this machine"
    )
    assert rt.eval("rebasedTo") is None, "rebased without warping: the sequence and the floor split"
    assert rt.eval("pendingWarp") is not None, "the warp was dropped instead of held"


def test_the_held_warp_runs_once_the_pause_and_its_fade_are_over():
    rt = warp_lua()
    rt.execute("st.pause = 2; applyG()")
    # journal closed: hdmod resumes its fade-in
    rt.execute("st.pause = 2; st.loading = FADE.IN; applyG()")
    assert rt.eval("warpedTo") is None
    rt.execute("st.pause = 0; st.loading = FADE.NONE; applyG()")
    assert int(rt.eval("rebasedTo")) == 9
    assert list(rt.eval("warpedTo").values()) == [1, 2, 1]
    assert rt.eval("pendingWarp") is None


def test_an_ordinary_warp_is_unchanged():
    rt = warp_lua()
    rt.execute("applyG()")
    assert int(rt.eval("rebasedTo")) == 9
    assert rt.eval("warpedTo") is not None
