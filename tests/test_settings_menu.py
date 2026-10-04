"""The MODDED ONLINE menu's SETTINGS page (src/menuUI.lua).

The root page is the four actions, SETTINGS and CLOSE. HIDE ROOM CODE, TEST
PLAYERS and SYNC SAVE DATA moved to SETTINGS, which also holds the two new
switches, AUTOMATICALLY SEND LOGS and AUTOMATICALLY SYNC DATA. Both are saved in
config.json like the others.

These run the shipped menu against a stubbed engine: keys are pressed, a GUI
frame runs, and what the menu drew is read back.

Run:  python -m pytest tests/test_settings_menu.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
MENU_UI = (PACK / "src" / "menuUI.lua").read_text(encoding="utf-8")

ENV = """
function rgba(r, g, b, a) return (r << 24) | (g << 16) | (b << 8) | a end
KEY = { O = 79, UP = 38, DOWN = 40, Z = 90, RETURN = 13, ESCAPE = 27, BACKSPACE = 8,
        A = 65, PERIOD = 190, MINUS = 189, OL_MOD_SHIFT = 0x200 }
down = {}
function get_io()
    return { keypressed = function(code, _allowRepeat) return down[code] == true end }
end
ON = { GUIFRAME = 100 }
guiframe = nil
function set_callback(fn, id) if id == ON.GUIFRAME then guiframe = fn end return 1 end
function SafeCall(_, f, ...) return f(...) end
SCREEN = { TITLE = 3, MENU = 4, CHARACTER_SELECT = 9, CAMP = 11, LEVEL = 12, TRANSITION = 13 }
FADE = { NONE = 0 }
function get_local_state() return { screen = SCREEN.MENU, loading = FADE.NONE } end
function get_ms() return 100000 end
saves, launched, stopped, synced = 0, 0, 0, 0
Network = {
    -- firstRunDone: past the first-run popups (tests/test_first_run.py covers those)
    config = { hideRoomCode = false, testPlayer = 0, autoSendLogs = false, autoSyncSave = false,
               firstRunDone = true },
    saveConfig = function() saves = saves + 1 end,
    MAX_TEST_PLAYERS = 3,
    launchTestPlayer = function() launched = launched + 1 end,
    stopTestPlayers = function() stopped = stopped + 1 end,
    isInRun = function() return false end,
    isActive = function() return false end,
    phase = 0,
    PHASE = { CONNECTING = 1 },
    lastError = nil,
}
syncResult = nil
SaveShare = {
    lastResult = function() return syncResult end,
    syncToMod = function() synced = synced + 1 syncResult = "2 file(s) synced" return syncResult end,
}
-- As in the real script API: a GLOBAL, width then height, the height negative.
-- Deliberately not menuUI's own fallback estimate (0.0009 per character per point).
function draw_text_size(size, text) return #text * size * 0.00035, -(size * 0.00185) end
drawn = {}
-- The draw context has no draw_text_size, exactly as in the game.
ctx = {
    draw_rect_filled = function() end,
    draw_rect = function() end,
    draw_line = function() end,
    draw_text = function(_self, x, y, size, text, _color)
        drawn[#drawn + 1] = { x = x, y = y, size = size, text = text }
    end,
}
"""

ROW_SIZES = (28, 30)   # an unselected row, the selected one
FOOTER_SIZE = 18


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(MENU_UI)
    return rt


def frame(rt, *keys):
    """One GUI frame with `keys` pressed; returns what was drawn, in order."""
    rt.execute("drawn = {} down = {}")
    for key in keys:
        rt.execute("down[KEY.%s] = true" % key)
    rt.execute("guiframe(ctx)")
    rt.execute("down = {}")
    out = []
    for i in range(1, int(rt.eval("#drawn")) + 1):
        out.append({k: rt.eval("drawn[%d].%s" % (i, k)) for k in ("x", "y", "size", "text")})
    return out


def rows(drawn):
    return [str(d["text"]) for d in drawn if d["size"] in ROW_SIZES]


def texts(drawn):
    return [str(d["text"]) for d in drawn]


def config(rt, key):
    return rt.eval("Network.config.%s" % key)


def open_settings(rt):
    frame(rt, "O")                      # opens the menu on its root page
    for _ in range(4):
        frame(rt, "DOWN")               # HOST -> JOIN -> MATCHMAKING -> DISCORD -> SETTINGS
    return frame(rt, "Z")


def test_the_root_page_is_the_actions_settings_and_close():
    rt = runtime()
    frame(rt, "O")
    assert rows(frame(rt)) == ["> HOST", "JOIN", "MATCHMAKING", "DISCORD", "SETTINGS", "CLOSE"]


def test_settings_holds_the_three_moved_settings_and_the_two_new_ones():
    rt = runtime()
    drawn = open_settings(rt)
    assert "- SETTINGS -" in texts(drawn)
    assert rows(drawn) == [
        "> HIDE ROOM CODE  [OFF]",
        "TEST PLAYERS  [OFF]",
        "SYNC SAVE DATA",
        "AUTOMATICALLY SEND LOGS  [OFF]",
        "AUTOMATICALLY SYNC DATA  [OFF]",
        "BACK",
    ]


def test_automatically_send_logs_flips_and_is_saved():
    rt = runtime()
    open_settings(rt)
    for _ in range(3):
        frame(rt, "DOWN")
    drawn = frame(rt, "Z")
    assert config(rt, "autoSendLogs") is True and int(rt.eval("saves")) == 1
    assert "> AUTOMATICALLY SEND LOGS  [ON]" in rows(drawn)
    drawn = frame(rt, "Z")
    assert config(rt, "autoSendLogs") is False and int(rt.eval("saves")) == 2
    assert "> AUTOMATICALLY SEND LOGS  [OFF]" in rows(drawn)


def test_automatically_sync_data_flips_and_is_saved():
    rt = runtime()
    open_settings(rt)
    for _ in range(4):
        frame(rt, "DOWN")
    drawn = frame(rt, "Z")
    assert config(rt, "autoSyncSave") is True and int(rt.eval("saves")) == 1
    assert "> AUTOMATICALLY SYNC DATA  [ON]" in rows(drawn)
    assert config(rt, "autoSendLogs") is False, "flipped the other switch too"


def test_the_moved_settings_still_do_what_they_did():
    rt = runtime()
    open_settings(rt)
    frame(rt, "Z")
    assert config(rt, "hideRoomCode") is True
    frame(rt, "DOWN")
    frame(rt, "Z")
    assert int(config(rt, "testPlayer")) == 1 and int(rt.eval("launched")) == 1
    frame(rt, "DOWN")
    drawn = frame(rt, "Z")
    assert int(rt.eval("synced")) == 1
    assert "> SYNC SAVE DATA  [2 file(s) synced]" in rows(drawn)
    assert int(rt.eval("saves")) == 2, "HIDE ROOM CODE and TEST PLAYERS each save once"


def test_back_returns_to_the_root_page_on_settings():
    rt = runtime()
    open_settings(rt)
    frame(rt, "UP")                     # wraps to BACK
    drawn = frame(rt, "Z")
    assert rows(drawn) == ["HOST", "JOIN", "MATCHMAKING", "DISCORD", "> SETTINGS", "CLOSE"]


def test_escape_from_settings_goes_back_to_the_root_page():
    rt = runtime()
    open_settings(rt)
    drawn = frame(rt, "ESCAPE")
    assert rows(drawn)[0] == "> HOST" and "SETTINGS" in rows(drawn)
    assert "- SETTINGS -" not in texts(drawn)


def test_every_row_clears_the_footer():
    """Six rows on a page with a subtitle: the last one's highlight bar must end
    above the footer line."""
    rt = runtime()
    for drawn in (open_settings(rt), frame(rt, "ESCAPE")):
        row_ys = [float(d["y"]) for d in drawn if d["size"] in ROW_SIZES]
        footer_y = [float(d["y"]) for d in drawn if d["size"] == FOOTER_SIZE][0]
        assert len(row_ys) == 6
        assert min(row_ys) - 0.06 > footer_y, (min(row_ys), footer_y)


def test_the_title_and_subtitle_are_centred():
    """Measured with the script API's global draw_text_size. This used to ask the
    draw context, which has no such method, so every centred label fell back to an
    estimate that put it left of centre."""
    rt = runtime()
    drawn = open_settings(rt)
    for text, size in (("MODDED  ONLINE", 40), ("- SETTINGS -", 22)):
        d = [d for d in drawn if str(d["text"]) == text][0]
        assert float(d["size"]) == size
        width = len(text) * size * 0.00035
        assert abs(float(d["x"]) + width / 2) < 1e-9, (text, float(d["x"]), -width / 2)
