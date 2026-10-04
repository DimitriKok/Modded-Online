"""The popups (src/menuUI.lua): the first-run sequence and the restart notice.

The first time Modded Online starts, four popups come up over the title screen and
main menu, in the menu's own style:

1. "Modded Online 2": how to set mods up, answered with I UNDERSTAND.
2. "Modded Online 2": a notice about the mod itself, answered with I UNDERSTAND.
3. "Automatically Send Desync Errors": YES switches on AUTOMATICALLY SEND LOGS, NO
   leaves it off.
4. "Automatically Sync Data": the same for AUTOMATICALLY SYNC DATA.

They come once. Each answer is saved as it is given; `firstRunDone` is saved only
after the last, so closing the game half way through shows them again.

"Restart Required" follows any change to the mods played online (setupUI asks for
it). It waits for the first-run popups, and never covers a level.

These run the shipped menu against a stubbed engine: keys are pressed, a GUI frame
runs, and what was drawn is read back.

Run:  python -m pytest tests/test_first_run.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
MENU_UI = (PACK / "src" / "menuUI.lua").read_text(encoding="utf-8")

# The words exactly as they were asked for.
TEXT_0 = ("To use modded online, ensure all script mods (other than modded online) are "
          "disabled. To play a mod, please enable it under playlunky options and restart "
          "the game.")
TEXT_1 = ("This mod has used ai heavily in the development in it; thus, it will contain "
          "bugs and issues. The old version of the mod would corrupt any mods you used it "
          "with. Please reinstall any mods you used the original modded online with. If you "
          "face any bugs or errors, please join the modded online discord server and send "
          "them there. Do not report any bugs to other mod creators if you have modded "
          "online enabled.")
TEXT_2 = ("Desyncs and Crashes are prone to happen. Do we have permission to automatically "
          "send any errors into the community discord server. No personal information is "
          "shared.")
TEXT_3 = ("Some mods use custom save data. Right now, we do not interfere with any mods "
          "files; thus, any progress you make in modded online does not transfer to the "
          "mod. There is a sync data button in modded online setting or you can opt to "
          "enable automatic save syncing. Do you want to enable Automatic Syncing?")
RESTART_TEXT = ("Restart the game for this change to take effect. Playlunky only loads mods "
                "when the game starts.")

ENV = """
function rgba(r, g, b, a) return (r << 24) | (g << 16) | (b << 8) | a end
KEY = { O = 79, UP = 38, DOWN = 40, Z = 90, RETURN = 13, ESCAPE = 27, BACKSPACE = 8,
        A = 65, PERIOD = 190, MINUS = 189, OL_MOD_SHIFT = 0x200 }
down = {}
ioState = { wantkeyboard = false }
ioState.keypressed = function(code, _allowRepeat) return down[code] == true end
function get_io() return ioState end
now = 100000
function get_ms() return now end
ON = { GUIFRAME = 100 }
guiframe = nil
function set_callback(fn, id) if id == ON.GUIFRAME then guiframe = fn end return 1 end
function SafeCall(_, f, ...) return f(...) end
SCREEN = { TITLE = 3, MENU = 4, CHARACTER_SELECT = 9, CAMP = 11, LEVEL = 12, TRANSITION = 13 }
FADE = { NONE = 0 }
screenNow = SCREEN.MENU
function get_local_state() return { screen = screenNow, loading = FADE.NONE } end
saved = {}
inRun = false
Network = {
    config = { hideRoomCode = false, testPlayer = 0, autoSendLogs = false, autoSyncSave = false,
               firstRunDone = false },
    saveConfig = function()
        local c = Network.config
        saved[#saved + 1] = { autoSendLogs = c.autoSendLogs, autoSyncSave = c.autoSyncSave,
                              firstRunDone = c.firstRunDone }
    end,
    MAX_TEST_PLAYERS = 3,
    launchTestPlayer = function() end,
    stopTestPlayers = function() end,
    isInRun = function() return inRun end,
    isActive = function() return false end,
    phase = 0,
    PHASE = { CONNECTING = 1 },
    lastError = nil,
}
SaveShare = { lastResult = function() return nil end, syncToMod = function() end }
-- As in the real script API: a GLOBAL, width then height, the height negative.
-- About 1080p for this font; deliberately not menuUI's own fallback estimate
-- (0.0009), so a test can tell which of the two did the measuring.
charW = 0.00035
function draw_text_size(size, text) return #text * size * charW, -(size * 0.00185) end
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

PAUSE_MS = 600          # POPUP_INPUT_DELAY_MS: presses before this are ignored
RELEASE_MS = 300        # POPUP_RELEASE_MS: the keyboard stays ours this long after
TEXT_X = -0.385         # POPUP_TEXT_X: the menu's left edge plus its margin
TEXT_WIDTH = 0.77       # POPUP_TEXT_W
CHAR = 0.00035          # the stub's width per character per point (charW)
FALLBACK_CHAR = 0.0009  # menuUI's estimate when there is no draw_text_size
CHIP = ["[O]  MODDED ONLINE"]
BUTTONS = (1, 1, 2, 2)  # how many buttons each first-run popup has


def runtime(**config):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    for key, value in config.items():
        rt.execute("Network.config.%s = %s" % (key, "true" if value else "false"))
    rt.execute(MENU_UI)
    return rt


def frame(rt, *keys, ms=16):
    """One GUI frame, `ms` after the last, with `keys` pressed. Returns what was drawn."""
    rt.execute("now = now + %d; drawn = {}; down = {}; ioState.wantkeyboard = false" % ms)
    for key in keys:
        rt.execute("down[KEY.%s] = true" % key)
    rt.execute("guiframe(ctx)")
    rt.execute("down = {}")
    out = []
    for i in range(1, int(rt.eval("#drawn")) + 1):
        out.append({k: rt.eval("drawn[%d].%s" % (i, k)) for k in ("x", "y", "size", "text")})
    return out


def popup(drawn, buttons):
    """Split one popup's text into its parts, in the order they are drawn."""
    texts = [str(d["text"]) for d in drawn]
    return {
        "title": texts[0],
        "lines": texts[1:-1 - buttons],
        "rows": texts[-1 - buttons:-1],
        "footer": texts[-1],
    }


def answer(rt, *keys):
    """Wait out the pause, then press `keys` one frame each."""
    frame(rt, ms=PAUSE_MS)
    drawn = None
    for key in keys:
        drawn = frame(rt, key)
    return drawn


def through_the_notices(rt):
    """Answer the two notices; returns the frame that shows the third popup."""
    frame(rt)
    answer(rt, "Z")
    return answer(rt, "Z")


def config(rt, key):
    return rt.eval("Network.config.%s" % key)


def texts(drawn):
    return [str(d["text"]) for d in drawn]


# -------------------------------------------------------------- the four popups

def test_the_first_popup_says_how_to_set_mods_up():
    rt = runtime()
    shown = popup(frame(rt), 1)
    assert shown["title"] == "MODDED ONLINE 2"
    assert " ".join(shown["lines"]) == TEXT_0
    assert shown["rows"] == ["> I UNDERSTAND"]
    assert shown["footer"] == "Z / ENTER select"
    assert rt.eval("ioState.wantkeyboard") is True, "the game's own menu saw the keys"


def test_the_second_popup_is_the_notice_about_the_mod():
    rt = runtime()
    frame(rt)
    shown = popup(answer(rt, "Z"), 1)
    assert shown["title"] == "MODDED ONLINE 2"
    assert " ".join(shown["lines"]) == TEXT_1
    assert shown["rows"] == ["> I UNDERSTAND"]


def test_the_third_popup_asks_about_sending_logs():
    rt = runtime()
    shown = popup(through_the_notices(rt), 2)
    assert shown["title"] == "AUTOMATICALLY SEND DESYNC ERRORS"
    assert " ".join(shown["lines"]) == TEXT_2
    assert shown["rows"] == ["> YES", "NO"]
    assert shown["footer"] == "ARROWS move     Z / ENTER select"


def test_the_fourth_popup_asks_about_syncing():
    rt = runtime()
    through_the_notices(rt)
    shown = popup(answer(rt, "Z"), 2)
    assert shown["title"] == "AUTOMATICALLY SYNC DATA"
    assert " ".join(shown["lines"]) == TEXT_3
    assert shown["rows"] == ["> YES", "NO"]


def test_yes_switches_a_setting_on_and_no_leaves_it_off():
    rt = runtime()
    through_the_notices(rt)
    answer(rt, "Z")                      # YES: send logs
    assert config(rt, "autoSendLogs") is True
    answer(rt, "DOWN", "Z")              # NO: sync
    assert config(rt, "autoSyncSave") is False
    assert config(rt, "firstRunDone") is True


def test_no_then_yes():
    rt = runtime()
    through_the_notices(rt)
    answer(rt, "DOWN", "Z")              # NO: send logs
    answer(rt, "Z")                      # YES: sync
    assert config(rt, "autoSendLogs") is False
    assert config(rt, "autoSyncSave") is True


def test_no_switches_off_what_an_earlier_build_had_on():
    """dev66 had both switches in SETTINGS already. The answer given here is the
    player's answer, whatever the switch said before."""
    rt = runtime(autoSendLogs=True, autoSyncSave=True)
    through_the_notices(rt)
    answer(rt, "DOWN", "Z")
    answer(rt, "DOWN", "Z")
    assert config(rt, "autoSendLogs") is False
    assert config(rt, "autoSyncSave") is False


def test_every_answer_is_saved_as_it_is_given():
    rt = runtime()
    through_the_notices(rt)
    answer(rt, "Z")
    answer(rt, "Z")
    saved = [dict(rt.eval("saved[%d]" % i)) for i in range(1, int(rt.eval("#saved")) + 1)]
    for entry in saved:
        for key in ("autoSendLogs", "autoSyncSave", "firstRunDone"):
            entry.setdefault(key, None)
    assert [e["autoSendLogs"] for e in saved] == [False, False, True, True]
    assert [e["autoSyncSave"] for e in saved] == [False, False, False, True]
    assert [e["firstRunDone"] for e in saved] == [False, False, False, True], (
        "firstRunDone was saved before the last popup was answered")


def test_enter_answers_like_z():
    rt = runtime()
    frame(rt)
    for _ in range(4):
        answer(rt, "RETURN")
    assert config(rt, "firstRunDone") is True
    assert config(rt, "autoSendLogs") is True and config(rt, "autoSyncSave") is True


def test_a_press_the_moment_a_popup_appears_is_ignored():
    """Mashing through one notice must not answer the next one unread."""
    rt = runtime()
    frame(rt, "Z")                       # the first notice has only just appeared
    assert " ".join(popup(frame(rt), 1)["lines"]) == TEXT_0
    answer(rt, "Z")                      # now it counts
    frame(rt, "Z")                       # ...and this one lands on the second too soon
    frame(rt, "Z", ms=100)
    assert " ".join(popup(frame(rt), 1)["lines"]) == TEXT_1


def test_up_and_down_wrap_round_like_the_menu():
    rt = runtime()
    through_the_notices(rt)
    assert popup(frame(rt, "UP"), 2)["rows"] == ["YES", "> NO"]
    assert popup(frame(rt, "DOWN"), 2)["rows"] == ["> YES", "NO"]


def test_escape_and_the_menu_key_do_nothing_while_they_are_up():
    rt = runtime()
    frame(rt)
    frame(rt, "ESCAPE", ms=PAUSE_MS)
    shown = popup(frame(rt, "O"), 1)
    assert " ".join(shown["lines"]) == TEXT_0, "the popup was skipped or the menu opened"
    assert config(rt, "firstRunDone") is False


def test_afterwards_the_main_menu_is_back_and_they_do_not_return():
    rt = runtime()
    frame(rt)
    for _ in range(4):
        answer(rt, "Z")
    # the key that answered must not reach the game's menu underneath
    assert frame(rt) == [] and rt.eval("ioState.wantkeyboard") is True
    assert texts(frame(rt, ms=RELEASE_MS)) == CHIP
    for _ in range(5):
        assert texts(frame(rt, ms=1000)) == CHIP


def test_once_answered_they_are_never_shown_again():
    rt = runtime(firstRunDone=True)
    assert texts(frame(rt)) == CHIP


def test_closing_the_game_half_way_shows_them_again():
    """The answers given so far are kept; the popups start again from the first."""
    rt = runtime()
    through_the_notices(rt)
    answer(rt, "Z")                      # YES to logs, then the game is closed
    relaunch = runtime(autoSendLogs=bool(config(rt, "autoSendLogs")),
                       firstRunDone=bool(config(rt, "firstRunDone")))
    assert " ".join(popup(frame(relaunch), 1)["lines"]) == TEXT_0
    assert config(relaunch, "autoSendLogs") is True


def test_they_also_cover_the_title_screen_and_nothing_else():
    rt = runtime()
    rt.execute("screenNow = SCREEN.TITLE")
    assert popup(frame(rt), 1)["title"] == "MODDED ONLINE 2"
    rt.execute("screenNow = SCREEN.CAMP")
    assert frame(rt, ms=1000) == []      # away for longer than the pause
    rt.execute("screenNow = SCREEN.MENU")
    frame(rt, "Z")                       # back on the menu: the pause applies again
    assert " ".join(popup(frame(rt), 1)["lines"]) == TEXT_0


def test_a_config_without_the_flag_shows_them():
    """Anything but an explicit true counts as not answered yet."""
    rt = runtime()
    rt.execute("Network.config.firstRunDone = nil")
    assert popup(frame(rt), 1)["title"] == "MODDED ONLINE 2"


def test_the_flag_starts_false():
    net = (PACK / "src" / "netCore.lua").read_text(encoding="utf-8")
    at = net.index("    config = {")
    block = net[at:net.index("\n    },", at)]
    assert "firstRunDone = false," in block


# ------------------------------------------------------------------- layout

def each_first_run_popup(rt):
    """The drawn frame of each first-run popup in turn."""
    drawn = frame(rt)
    for step, buttons in enumerate(BUTTONS):
        yield step, buttons, drawn
        if step < len(BUTTONS) - 1:
            drawn = answer(rt, "Z")


def test_the_text_is_wrapped_inside_the_panel():
    rt = runtime()
    for step, buttons, drawn in each_first_run_popup(rt):
        lines = drawn[1:-1 - buttons]
        assert len(lines) > 1, "the paragraph was drawn as one line"
        for d in lines:
            width = len(str(d["text"])) * float(d["size"]) * CHAR
            assert abs(float(d["x"]) - TEXT_X) < 1e-9
            assert width <= TEXT_WIDTH + 1e-9, (step, str(d["text"]))


def test_the_text_fills_the_panel_rather_than_a_column_of_it():
    """What the first in-game screenshot showed: every line wrapped at about a third
    of the panel, because the width it measured with was the fallback estimate."""
    rt = runtime()
    for step, buttons, drawn in each_first_run_popup(rt):
        for d in drawn[1:-1 - buttons][:-1]:   # the last line of a paragraph may be short
            width = len(str(d["text"])) * float(d["size"]) * CHAR
            assert width >= 0.7 * TEXT_WIDTH, (step, round(width / TEXT_WIDTH, 2), str(d["text"]))


def test_the_layout_reads_top_to_bottom_and_stays_on_screen():
    rt = runtime()
    for _step, _buttons, drawn in each_first_run_popup(rt):
        ys = [float(d["y"]) for d in drawn]
        assert all(-1 <= y <= 1 for y in ys), ys
        assert ys == sorted(ys, reverse=True), "title, text, buttons and footer out of order"


def test_the_title_and_footer_are_centred():
    rt = runtime()
    drawn = frame(rt)
    for d in (drawn[0], drawn[-1]):
        width = len(str(d["text"])) * float(d["size"]) * CHAR
        assert abs(float(d["x"]) + width / 2) < 1e-9, (str(d["text"]), float(d["x"]), -width / 2)


def test_without_draw_text_size_it_still_draws_from_the_estimate():
    rt = runtime()
    rt.execute("draw_text_size = nil")
    title = frame(rt)[0]
    width = len(str(title["text"])) * float(title["size"]) * FALLBACK_CHAR
    assert str(title["text"]) == "MODDED ONLINE 2"
    assert abs(float(title["x"]) + width / 2) < 1e-9


def test_a_long_title_is_shrunk_to_stay_inside_the_banner():
    """At 1080p it fits at full size. On a screen where text runs wider (charW
    raised), it steps down rather than running past the banner."""
    rt = runtime()
    assert float(through_the_notices(rt)[0]["size"]) == 40
    rt.execute("charW = 0.0009")
    title = frame(rt)[0]
    assert str(title["text"]) == "AUTOMATICALLY SEND DESYNC ERRORS"
    assert 24 <= float(title["size"]) < 40
    assert len(str(title["text"])) * float(title["size"]) * 0.0009 <= 0.92 - 0.12


# ---------------------------------------------------------- the restart notice

def ask_for_restart(rt):
    rt.execute("NetMenuUI.showRestartNotice()")


def test_a_change_to_the_mods_asks_for_a_restart():
    rt = runtime(firstRunDone=True)
    ask_for_restart(rt)
    shown = popup(frame(rt), 1)
    assert shown["title"] == "RESTART REQUIRED"
    assert " ".join(shown["lines"]) == RESTART_TEXT
    assert shown["rows"] == ["> OK"]
    assert rt.eval("ioState.wantkeyboard") is True


def test_ok_dismisses_it_and_nothing_is_saved():
    rt = runtime(firstRunDone=True)
    ask_for_restart(rt)
    frame(rt)
    assert answer(rt, "Z") == []
    assert texts(frame(rt, ms=RELEASE_MS)) == CHIP
    assert int(rt.eval("#saved")) == 0, "the notice changed a setting"


def test_two_changes_ask_once():
    rt = runtime(firstRunDone=True)
    ask_for_restart(rt)
    ask_for_restart(rt)
    frame(rt)
    answer(rt, "RETURN")
    assert texts(frame(rt, ms=RELEASE_MS)) == CHIP


def test_a_press_the_moment_it_appears_is_ignored():
    rt = runtime(firstRunDone=True)
    ask_for_restart(rt)
    frame(rt, "Z")
    assert popup(frame(rt), 1)["title"] == "RESTART REQUIRED"


def test_it_waits_for_the_first_run_popups():
    """At a first launch both can be due (a mod ticked before the popups were
    answered). The first-run popups come first, then the notice."""
    rt = runtime()
    ask_for_restart(rt)
    assert " ".join(popup(frame(rt), 1)["lines"]) == TEXT_0
    for _ in range(4):
        answer(rt, "Z")
    frame(rt, ms=RELEASE_MS)
    assert popup(frame(rt), 1)["title"] == "RESTART REQUIRED"


def test_it_shows_in_the_camp_and_on_character_select():
    for screen in ("CAMP", "CHARACTER_SELECT", "TITLE"):
        rt = runtime(firstRunDone=True)
        rt.execute("screenNow = SCREEN." + screen)
        ask_for_restart(rt)
        assert popup(frame(rt), 1)["title"] == "RESTART REQUIRED", screen


def test_it_never_covers_a_level_and_waits_for_the_next_screen():
    rt = runtime(firstRunDone=True)
    ask_for_restart(rt)
    for screen in ("LEVEL", "TRANSITION"):
        rt.execute("screenNow = SCREEN." + screen)
        assert frame(rt) == [] and rt.eval("ioState.wantkeyboard") is False, screen
    rt.execute("screenNow = SCREEN.CAMP")
    assert popup(frame(rt), 1)["title"] == "RESTART REQUIRED"


def test_not_during_an_online_run():
    rt = runtime(firstRunDone=True)
    ask_for_restart(rt)
    rt.execute("inRun = true")
    assert frame(rt) == []
    rt.execute("inRun = false")
    assert popup(frame(rt), 1)["title"] == "RESTART REQUIRED"
