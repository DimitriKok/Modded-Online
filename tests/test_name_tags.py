"""The name tags over the other players during a run (src/inputSync.lua, guiTick).

Each tag is meant to be centred over its spelunker's head. It was measured by
calling `draw_text_size` as a method of the draw context, which has no such method;
in the script API it is a global (width, then height). Every measurement failed, the
width came back 0, and every tag was drawn starting at the player instead of centred
over them. The tags are now drawn and measured at the same explicit size (18, the
API's documented default that size 0 stood for), so the width measured is the width
drawn.

These run the shipped `guiTick`, `measureName` and `readCameraLayer`, extracted
verbatim, against a stubbed engine.

Run:  python -m pytest tests/test_name_tags.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")
NL = "\n"


def extract(start: str) -> str:
    assert start in INPUT_SYNC, f"{start!r} not found in src/inputSync.lua"
    i = INPUT_SYNC.index(start)
    j = INPUT_SYNC.index(NL + "end" + NL, i)
    return INPUT_SYNC[i:j] + NL + "end" + NL


def measuring() -> str:
    """From the width cache down to the end of measureName, NAME_SIZE included."""
    start = "local nameWidth = {}"
    assert start in INPUT_SYNC
    i = INPUT_SYNC.index(start)
    j = INPUT_SYNC.index(NL + "end" + NL, INPUT_SYNC.index("local function measureName(name)", i))
    return INPUT_SYNC[i:j] + NL + "end" + NL


ENV = """
CHAR = 0.00035                       -- width per character per point, about 1080p
measured = {}
function draw_text_size(size, text)
    measured[#measured + 1] = { size = size, text = text }
    return #text * size * CHAR, -(size * 0.00185)
end
function rgba(r, g, b, a) return (r << 24) | (g << 16) | (b << 8) | a end
now = 0
function get_ms() return now end
SCREEN = { LEVEL = 12 }
function get_local_state() return { screen = SCREEN.LEVEL, camera_layer = 0 } end
-- two players: we are co-op 1, the other is co-op 2 standing at (10, 20)
players = { [1] = { x = 0, y = 0, layer = 0 }, [2] = { x = 10, y = 20, layer = 0 } }
function get_player(index, _) return players[index] end
function screen_position(x, y) return x / 100, y / 100 end   -- simply scaled
active, menuSyncOn, menuFrames = true, false, 0
lastResendMs, RESEND_INTERVAL_MS = 0, 1000000
function sendRecentInputs() end
stallStartMs = nil
module = { stallDesyncRole = function() return nil end }
EventSync, DesyncLog = nil, nil
coopSlots = { [1] = 1, [2] = 2 }
myCoopIndex = 1
goneSlots = {}
Network = { isInRun = function() return true end, playerNames = { ["2"] = "DoctorPuppy" } }
drawn = {}
-- The draw context has no draw_text_size, exactly as in the game.
ctx = {
    draw_text = function(_self, x, y, size, text, _color)
        drawn[#drawn + 1] = { x = x, y = y, size = size, text = text }
    end,
}
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(measuring() + extract("local function readCameraLayer()")
               + extract("local function guiTick(ctx)") + "tick = guiTick" + NL)
    return rt


def tags(rt):
    rt.execute("drawn = {}; tick(ctx)")
    return [{k: rt.eval("drawn[%d].%s" % (i, k)) for k in ("x", "y", "size", "text")}
            for i in range(1, int(rt.eval("#drawn")) + 1)]


def test_the_tag_is_centred_over_the_player():
    rt = runtime()
    [tag] = tags(rt)
    width = len("DoctorPuppy") * 18 * 0.00035
    sx = 10 / 100                        # screen_position of the player's x
    assert str(tag["text"]) == "DoctorPuppy"
    assert abs(float(tag["x"]) - (sx - width / 2)) < 1e-12, (float(tag["x"]), sx - width / 2)
    assert abs(float(tag["y"]) - (20 + 0.85) / 100) < 1e-12


def test_it_is_measured_at_the_size_it_is_drawn():
    rt = runtime()
    [tag] = tags(rt)
    assert float(tag["size"]) == 18
    assert [float(m["size"]) for m in rt.eval("measured").values()] == [18]


def test_a_name_is_measured_once():
    rt = runtime()
    for _ in range(5):
        tags(rt)
    assert int(rt.eval("#measured")) == 1


def test_without_draw_text_size_it_still_draws_from_the_player():
    rt = runtime()
    rt.execute("draw_text_size = nil")
    [tag] = tags(rt)
    assert abs(float(tag["x"]) - 10 / 100) < 1e-12
    assert str(tag["text"]) == "DoctorPuppy"


def test_our_own_and_a_departed_player_get_no_tag():
    rt = runtime()
    rt.execute("goneSlots = { [2] = true }")
    assert tags(rt) == []
