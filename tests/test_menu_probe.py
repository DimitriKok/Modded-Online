"""The menu probe (src/menuProbe.lua), armed by mo_menuprobe.on.

It measures in the game what the vanilla-styled menu needs: which API pieces exist,
the MENU_* textures, the main menu's state and input as the engine filled them, and
the OPTIONS screen's panels. Without the flag it must cost nothing; with it, the log
must be bounded and every failed read must say why.

Run:  python -m pytest tests/test_menu_probe.py -q
"""

from __future__ import annotations

import pytest

from menu_stub import Engine

LOG = "mo_menuprobe.txt"


def lines(tmp_path):
    path = tmp_path / LOG
    if not path.exists():
        return []
    return [l.split("] ", 1)[1] for l in path.read_text(encoding="utf-8").splitlines()]


def armed(tmp_path, contents="", **kwargs):
    (tmp_path / "mo_menuprobe.on").write_text(contents, encoding="utf-8")
    return Engine(tmp_path, modules=("menuProbe",), **kwargs)


def test_without_the_flag_it_does_nothing(tmp_path):
    engine = Engine(tmp_path, modules=("menuProbe",))
    assert engine.eval("MenuProbe.armed()") is False
    engine.lua('MenuProbe.note("anything %d", 1)')
    assert not (tmp_path / LOG).exists()
    assert int(engine.eval("#(callbacks[ON.PRE_UPDATE] or {})")) == 0
    assert int(engine.eval("#(callbacks[ON.GUIFRAME] or {})")) == 0


def test_the_name_windows_gives_the_flag_arms_it_too(tmp_path):
    """Explorer's New > Text Document, extensions hidden, makes mo_menuprobe.on.txt:
    the first attempt to arm the probe in game was exactly that file."""
    (tmp_path / "mo_menuprobe.on.txt").write_text("draw", encoding="utf-8")
    engine = Engine(tmp_path, modules=("menuProbe",))
    assert engine.eval("MenuProbe.armed()") is True
    assert "modes=draw" in lines(tmp_path)[0]


def test_armed_it_says_so_first_and_names_its_modes(tmp_path):
    armed(tmp_path, "draw capture")
    first = lines(tmp_path)[0]
    assert first.startswith("=== menu probe armed") and "modes=capture,draw" in first


def test_each_launch_starts_a_fresh_file(tmp_path):
    (tmp_path / LOG).write_text("[00:00:00] an old line\n", encoding="utf-8")
    armed(tmp_path)
    assert "an old line" not in lines(tmp_path)


def test_it_reports_which_api_pieces_exist(tmp_path):
    armed(tmp_path)
    text = "\n".join(lines(tmp_path))
    assert "change_string=function" in text
    assert "get_game_manager=nil" in text            # not in the stub
    assert "PRE_UPDATE=142" in text


def test_a_failed_read_says_why(tmp_path):
    engine = armed(tmp_path, before="game_manager.screen_menu = nil")
    engine.update()
    menu = [l for l in lines(tmp_path) if l.startswith("menu id=") or "menu." in l]
    assert menu and all("ERR(" in l for l in menu), menu


def test_the_main_menu_state_is_logged_as_it_changes(tmp_path):
    engine = armed(tmp_path)
    engine.update()
    engine.update()
    engine.lua("game_manager.screen_menu.selected_menu_index = 2")
    engine.update()
    menu = [l for l in lines(tmp_path) if l.startswith("menu id=")]
    assert len(menu) == 2, menu
    assert "index=1" in menu[0] and "index=2" in menu[1]


def test_the_input_is_logged_with_its_bit_names(tmp_path):
    engine = armed(tmp_path)
    engine.update("SELECT", "DOWN")
    engine.update()
    inputs = [l for l in lines(tmp_path) if l.startswith("input ")]
    assert inputs[0].startswith("input now=SELECT+DOWN prev=-"), inputs
    assert inputs[1].startswith("input now=- prev=SELECT+DOWN"), inputs


def test_the_options_panels_are_dumped_on_entry_and_a_second_in(tmp_path):
    engine = armed(tmp_path, before="""
        local function tri(l, t, r, b)
            return { x = 0.1, y = 0.2,
                source_get_quad = function() return { top_left_x = l, top_left_y = t,
                    top_right_x = r, top_right_y = t, bottom_left_x = l, bottom_left_y = b,
                    bottom_right_x = r, bottom_right_y = b } end,
                dest_get_quad = function() return { top_left_x = -1, top_left_y = 1,
                    top_right_x = 1, top_right_y = 1, bottom_left_x = -1, bottom_left_y = -1,
                    bottom_right_x = 1, bottom_right_y = -1 } end }
        end
        game_manager.screen_options = { selected_item_scarab = tri(0.1, 0.2, 0.3, 0.4),
            screen_panels = { scroll = tri(0.5, 0.5, 1.0, 0.9) } }
        lstate.screen = SCREEN.OPTIONS
    """)
    for _ in range(70):
        engine.update()
    text = lines(tmp_path)
    assert sum(1 for l in text if l.startswith("options panels (")) == 2
    scarab = [l for l in text if "options.selected_item_scarab:" in l][0]
    assert "src TL(0.1000,0.2000)" in scarab and "BR(0.3000,0.4000)" in scarab
    assert any("panels.scroll:" in l and "TL(0.5000,0.5000)" in l for l in text)
    assert any("options.brick_background:" in l and "nil" in l for l in text)


def test_the_log_is_bounded(tmp_path):
    engine = armed(tmp_path)
    engine.lua('for i = 1, 1000 do MenuProbe.note("line %d", i) end')
    assert len(lines(tmp_path)) == 400


def test_a_repeated_line_is_written_once_with_a_count(tmp_path):
    engine = armed(tmp_path)
    engine.lua('for i = 1, 50 do MenuProbe.note("the same") end MenuProbe.note("then another")')
    text = lines(tmp_path)
    at = text.index("the same")
    assert text[at + 1] == "  ... and 49 more of the line above"
    assert text[at + 2] == "then another"


@pytest.mark.parametrize("order, between", [
    ("frame_start", ("GUIFRAME", "POST_PROCESS_INPUT")),
    ("after_input", ("POST_PROCESS_INPUT", "PRE_UPDATE")),
    ("inside", ("PRE_UPDATE", "POST_UPDATE")),
    ("after_post", ("POST_UPDATE", "GUIFRAME")),
])
def test_it_says_where_in_the_frame_the_menu_moves(tmp_path, order, between):
    """The question dev68 got wrong: where the main menu reads its input."""
    engine = armed(tmp_path, order=order)
    engine.lua("game_manager.screen_menu.selected_menu_index = 0")   # PLAY, not ours
    engine.update()
    engine.gui()
    engine.update("SELECT")
    engine.gui()
    engine.update()
    engine.gui()
    moved = [l for l in lines(tmp_path) if l.startswith("menu moved between")]
    assert moved, lines(tmp_path)
    assert moved[0].startswith("menu moved between %s and %s:" % between), moved[0]
    assert "state=7 transfer=0 -> " in moved[0] and "state=8 transfer=1" in moved[0]


def test_it_writes_down_the_callback_order_once(tmp_path):
    engine = armed(tmp_path)
    for _ in range(10):
        engine.update()
        engine.gui()
    order = [l for l in lines(tmp_path) if l.startswith("callback order on the main menu:")]
    assert len(order) == 1
    assert "POST_PROCESS_INPUT PRE_UPDATE POST_UPDATE GUIFRAME" in order[0]


def test_screen_changes_are_summarised(tmp_path):
    engine = armed(tmp_path)
    for _ in range(3):
        engine.update()
        engine.gui()
    engine.lua("lstate.screen = SCREEN.CAMP")
    engine.update()
    summary = [l for l in lines(tmp_path) if l.startswith("screen MENU -> CAMP")]
    assert summary and "updates=3 gui=3" in summary[0], summary
