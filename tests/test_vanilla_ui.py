"""The game's own look for the menu, popups and plaques (src/vanillaUI.lua).

The menu is drawn like the game's OPTIONS screen: the brick walls, the wood panels,
the parchment title scroll, the red highlight bar, all from the game's own sprite
sheets. Its text is in the main menu's font (the game's italic style) and casing
(Title Case: Host, Join, Vanilla Online), the scroll's title in capitals. The ImGui look stays as the fallback, and must take over
whenever the game's look is not actually drawing.

These run vanillaUI with menuInput, mainMenuHook and menuUI (and chat) against the
stubbed engine in tests/menu_stub.py. Its renderer records every texture and line of
text, so a test reads back what reached the screen.

Run:  python -m pytest tests/test_vanilla_ui.py -q
"""

from __future__ import annotations

import pytest

from menu_stub import Engine, open_menu

MODULES = ("menuInput", "mainMenuHook", "vanillaUI", "menuUI")
GUI_TITLE = "MODDED  ONLINE"   # the ImGui menu's banner


@pytest.fixture
def engine(tmp_path):
    return Engine(tmp_path, modules=MODULES)


def texts(drawn):
    return [d["text"] for d in drawn if d["kind"] == "text"]


def textures(drawn):
    return [d for d in drawn if d["kind"] == "tex"]


def open_vanilla(engine):
    """Open the menu and run frames until the game's look is drawing it."""
    open_menu(engine)
    vanilla, gui = engine.frame()
    vanilla, gui = engine.frame()
    return vanilla, gui


# ----------------------------------------------------------------- the page

def test_the_menu_is_drawn_with_the_games_sprites_and_font(engine):
    vanilla, gui = open_vanilla(engine)
    assert GUI_TITLE not in gui, "the ImGui menu was drawn as well"
    words = texts(vanilla)
    assert words[0] == "MODDED ONLINE"
    for row in ("Host", "Join", "Matchmaking", "Discord", "Settings", "Vanilla Online"):
        assert row in words
    assert "ESC / B  Back" in words and "Z / A  Select" in words
    used = {d["tex"] for d in textures(vanilla)}
    assert used == {36, 40, 39, 32, 41}, used    # the walls, the panels, the bar


ITALIC, BOLD = 1, 2


def test_the_menu_is_in_the_main_menus_font(engine):
    """The main menu's PLAY, ONLINE, OPTIONS are the game's italic style."""
    vanilla, _ = open_vanilla(engine)
    styles = {d["text"]: d["style"] for d in vanilla if d["kind"] == "text"}
    for text in ("MODDED ONLINE", "Host", "Vanilla Online", "ESC / B  Back", "Z / A  Select"):
        assert styles[text] == ITALIC, text


def test_popups_are_in_it_too(tmp_path):
    engine = Engine(tmp_path, modules=MODULES, firstRunDone=False)
    engine.gui()
    engine.frame()
    vanilla, _ = engine.frame()
    assert {d["style"] for d in vanilla if d["kind"] == "text"} == {ITALIC}


@pytest.mark.parametrize("label, shown", [
    ("HOST", "Host"),
    ("VANILLA ONLINE", "Vanilla Online"),
    ("AUTOMATICALLY SEND LOGS", "Automatically Send Logs"),
    ("SERVER IP", "Server IP"),
    ("OK", "OK"),
    ("OFF", "Off"),
    ("3", "3"),
    ("1 file(s) synced", "1 file(s) synced"),
])
def test_labels_are_written_the_way_the_main_menu_writes_its_own(engine, label, shown):
    assert engine.eval('NetMenuUI.titleCase("%s")' % label) == shown


def test_the_walls_come_first_and_the_panels_over_them(engine):
    vanilla, _ = open_vanilla(engine)
    order = [d["tex"] for d in textures(vanilla)]
    assert order[:3] == [36, 40, 39], "the wall layers out of order"
    assert order[3] == 32, "the top panel is not over the walls"


def test_the_selected_row_gets_the_red_bar_and_moves_with_it(engine):
    vanilla, _ = open_vanilla(engine)
    bar = [d for d in textures(vanilla) if d["src"][0] == pytest.approx(832 / 1280)]
    assert len(bar) == 1
    host = [d for d in vanilla if d.get("text") == "Host"][0]
    first_bar_y = bar[0]["dst"][1]
    engine.update("DOWN")
    engine.update()
    engine.gui()
    vanilla, _ = engine.frame()
    bar = [d for d in textures(vanilla) if d["src"][0] == pytest.approx(832 / 1280)]
    assert bar[0]["dst"][1] < first_bar_y, "the bar did not move down to JOIN"
    assert host["x"] == pytest.approx(600 / 960 - 1)


def test_settings_show_their_values_with_arrows_on_the_selected_one(engine):
    open_vanilla(engine)
    for _ in range(4):
        engine.update("DOWN")
        engine.update()
    engine.update("SELECT")
    engine.update()
    engine.gui(ms=50)
    vanilla, _ = engine.frame()
    words = texts(vanilla)
    assert words[0] == "SETTINGS"
    assert "Hide Room Code" in words and "Off" in words
    assert "LEFT / RIGHT  Change" in words
    arrows = [d for d in textures(vanilla) if d["src"][1] == pytest.approx(45 / 1280)]
    assert len(arrows) == 2
    assert arrows[0]["src"][0] > arrows[0]["src"][2], "the left arrow is not flipped"


def test_sprites_are_cut_from_the_measured_rectangles(engine):
    vanilla, _ = open_vanilla(engine)
    top_panel = [d for d in textures(vanilla) if d["tex"] == 32][0]
    assert top_panel["src"] == pytest.approx([1 / 1408, 256 / 768, 1408 / 1408, 508 / 768])


def test_text_is_centred_on_its_line_whatever_the_font_does(engine):
    """The stub's glyphs hang below the y they are drawn at; measured, the text is
    moved so the middle of its glyphs is where the layout asked."""
    vanilla, _ = open_vanilla(engine)
    title = [d for d in vanilla if d.get("text") == "MODDED ONLINE"][0]
    cell = 0.06 * title["scale"] / 0.001
    middle = title["y"] - cell / 2
    assert middle == pytest.approx(1 - 200 / 540)


def open_settings(engine):
    open_vanilla(engine)
    for _ in range(4):
        engine.update("DOWN")
        engine.update()
    engine.update("SELECT")
    engine.update()
    engine.gui(ms=50)
    vanilla, _ = engine.frame()
    return vanilla


def cap_px(d):
    """The capital height a draw asked for, in 1080p pixels (the stub's capitals are
    GLYPH_CELL tall per 0.001 of scale)."""
    return d["scale"] / 0.001 * 0.06 * 540


def test_sizes_are_the_height_of_a_capital(engine):
    """dev70 sized for whole glyph cells and drew everything 1.7 times too big: asked
    for 44, MATCHMAKING had 45 px capitals."""
    vanilla, _ = open_vanilla(engine)
    by_text = {d["text"]: d for d in vanilla if d["kind"] == "text"}
    assert cap_px(by_text["Join"]) == pytest.approx(24)
    assert cap_px(by_text["Host"]) == pytest.approx(25), "the selected row"
    assert cap_px(by_text["MODDED ONLINE"]) == pytest.approx(44)
    assert cap_px(by_text["Z / A  Select"]) == pytest.approx(22)


def test_a_long_label_is_shrunk_to_fit(engine):
    engine.lua("GLYPH_WIDTH = 0.05")            # a wide font: the long labels overflow
    vanilla = open_settings(engine)
    by_text = {d["text"]: d for d in vanilla if d["kind"] == "text"}
    long_ = by_text["Automatically Send Logs"]
    short = by_text["Test Players"]
    assert long_["scale"] < short["scale"]
    width_px = len("Automatically Send Logs") * long_["scale"] * 50 * 960
    assert width_px <= 470 + 1e-6


def test_the_middle_hint_never_runs_into_the_others(engine):
    """In dev70 "LEFT / RIGHT  Change" was drawn over both of the other hints."""
    engine.lua("GLYPH_WIDTH = 0.05")
    vanilla = open_settings(engine)
    by_text = {d["text"]: d for d in vanilla if d["kind"] == "text"}

    def span(text):
        d = by_text[text]
        w = len(text) * d["scale"] * 50 * 960
        x = (d["x"] + 1) * 960
        return {0: (x, x + w), 1: (x - w / 2, x + w / 2), 2: (x - w, x)}[d["align"]]

    left, middle, right = span("ESC / B  Back"), span("LEFT / RIGHT  Change"), span("Z / A  Select")
    assert left[1] < middle[0] and middle[1] < right[0], (left, middle, right)


def test_arrows_only_on_a_row_left_and_right_change(engine):
    """SYNC SAVE DATA has a result to show, but nothing to step through."""
    engine.lua('SaveShare.lastResult = function() return "2 file(s) synced" end')
    open_settings(engine)
    for _ in range(2):
        engine.update("DOWN")
        engine.update()
    engine.gui(ms=50)
    vanilla, _ = engine.frame()
    assert "2 file(s) synced" in texts(vanilla), "the row has no value to test with"
    arrows = [d for d in textures(vanilla) if d["src"][1] == pytest.approx(45 / 1280)]
    assert arrows == []
    assert "LEFT / RIGHT  Change" not in texts(vanilla)


# --------------------------------------------------------------- fallback

def test_until_the_render_calls_run_the_imgui_menu_is_drawn(engine):
    open_menu(engine)
    gui = engine.gui()                      # no render has happened in this test yet
    assert GUI_TITLE in gui


def test_if_the_render_calls_stop_the_imgui_menu_comes_back(engine):
    open_vanilla(engine)
    for _ in range(3):
        engine.update()
        gui = engine.gui()
    assert GUI_TITLE in gui


def test_a_layer_that_fails_falls_back_and_stays_back(engine):
    open_vanilla(engine)
    engine.lua("vctx.draw_screen_texture = function() error('no such texture') end")
    engine.frame()
    _, gui = engine.frame()
    assert GUI_TITLE in gui
    assert engine.eval("VanillaUI.serving('menu')") is False
    engine.lua("vctx.draw_screen_texture = function() end")
    _, gui = engine.frame()
    assert GUI_TITLE in gui, "a failed layer came back by itself"


def test_the_flag_file_keeps_the_imgui_look(tmp_path):
    engine = Engine(tmp_path, modules=MODULES, flags=("mo_novanillaui.on",))
    open_menu(engine)
    vanilla, gui = engine.frame()
    _, gui = engine.frame()
    assert GUI_TITLE in gui and texts(vanilla) == []
    assert "mo_novanillaui.on" in str(engine.eval("VanillaUI.why()"))


def test_a_sheet_of_another_size_keeps_the_imgui_look(tmp_path):
    """A texture mod with a different layout would put the wrong part on screen."""
    engine = Engine(tmp_path, modules=MODULES, before="texdefs[41] = { width = 2048, height = 2048 }")
    open_menu(engine)
    engine.frame()
    _, gui = engine.frame()
    assert GUI_TITLE in gui
    assert "2048x2048" in str(engine.eval("VanillaUI.why()"))


def test_the_first_draw_is_bracketed_by_a_breadcrumb(tmp_path):
    engine = Engine(tmp_path, modules=MODULES)
    open_vanilla(engine)
    assert (tmp_path / "mo_vanillaui.txt").read_text().strip() == "ok"


def test_a_session_that_died_in_its_first_draw_keeps_the_next_one_on_imgui(tmp_path):
    (tmp_path / "mo_vanillaui.txt").write_text("drawing\n")
    engine = Engine(tmp_path, modules=MODULES)
    open_menu(engine)
    engine.frame()
    _, gui = engine.frame()
    assert GUI_TITLE in gui
    assert "died" in str(engine.eval("VanillaUI.why()"))
    assert (tmp_path / "mo_vanillaui.txt").read_text().strip() == "crashed"


# ------------------------------------------------------------------ popups

def test_popups_are_drawn_in_the_wood_frame(tmp_path):
    engine = Engine(tmp_path, modules=MODULES, firstRunDone=False)
    engine.gui()
    vanilla, gui = engine.frame()
    vanilla, gui = engine.frame()
    words = texts(vanilla)
    assert words[0] == "Modded Online 2"
    assert "I Understand" in words
    assert not [t for t in gui if t == "MODDED ONLINE 2"], "the ImGui popup was drawn too"
    frame_pieces = [d for d in textures(vanilla) if d["src"][0] >= 12 / 1280 - 1e-9
                    and d["src"][2] <= 639 / 1280 + 1e-9 and d["tex"] == 41]
    assert len(frame_pieces) == 9, "the frame was not drawn in nine pieces"


def test_popup_text_is_wrapped_to_the_frame(tmp_path):
    engine = Engine(tmp_path, modules=MODULES, firstRunDone=False)
    engine.gui()
    engine.frame()
    vanilla, _ = engine.frame()
    body = [d for d in vanilla if d["kind"] == "text" and d["text"] not in
            ("Modded Online 2", "I Understand", "Z / A  Select")]
    assert len(body) > 1
    for d in body:
        assert len(d["text"]) * d["scale"] * 20 * 960 <= 760 + 1e-6, d["text"]


def test_the_popups_keep_their_text(tmp_path):
    """Drawn differently, worded the same: the first-run text is the one asked for."""
    engine = Engine(tmp_path, modules=MODULES, firstRunDone=False)
    engine.gui()
    engine.frame()
    vanilla, _ = engine.frame()
    body = " ".join(d["text"] for d in vanilla if d["kind"] == "text"
                    and d["text"] not in ("Modded Online 2", "I Understand", "Z / A  Select"))
    assert body.startswith("To use modded online, ensure all script mods")
    assert body.endswith("and restart the game.")


# ---------------------------------------------------------------- plaques

def test_a_plaque_is_as_wide_as_its_text(tmp_path):
    engine = Engine(tmp_path, modules=MODULES)
    engine.lua('lstate.screen = SCREEN.CAMP; Network.phase = Network.PHASE.LOBBY;'
               ' Network.room = "ABCD"; Network.lobbyPlayers = {}')
    engine.gui()
    engine.frame(screen="CAMP")
    narrow, _ = engine.frame(screen="CAMP")
    engine.lua('Network.lobbyPlayers = { { slot = 1, name = string.rep("W", 40), ready = true } }')
    engine.gui()
    wide, _ = engine.frame(screen="CAMP")

    def box_right(drawn):
        return max(d["dst"][2] for d in textures(drawn))

    assert box_right(wide) > box_right(narrow)


def test_the_camp_plaque(tmp_path):
    engine = Engine(tmp_path, modules=MODULES)
    engine.lua('lstate.screen = SCREEN.CAMP; Network.phase = Network.PHASE.LOBBY;'
               ' Network.room = "ABCD"; Network.lobbyPlayers = { { slot = 1, name = "Ana",'
               ' ready = true } }')
    engine.gui()
    vanilla, gui = engine.frame(screen="CAMP")
    vanilla, gui = engine.frame(screen="CAMP")
    words = texts(vanilla)
    assert words[0].startswith("ROOM ABCD") and "1 / 1 READY" in words[0]
    assert any("Ana" in w for w in words)
    assert not [t for t in gui if "ROOM ABCD" in t], "drawn twice"


def test_the_run_status_line(tmp_path):
    engine = Engine(tmp_path, modules=MODULES, before="""
        InputSync = { isStalled = function() return false end, activePlayers = function() return 2 end }
    """)
    engine.lua('lstate.screen = SCREEN.LEVEL; Network.phase = Network.PHASE.INGAME;'
               ' Network.room = "WXYZ"; Network.pingMs = 40')
    engine.gui()
    vanilla, gui = engine.frame(screen="LEVEL")
    vanilla, gui = engine.frame(screen="LEVEL")
    line = "MODDED ONLINE   room WXYZ   2 players   40 ms"
    assert texts(vanilla).count(line) == 2, "the line and its shadow"
    assert {d["style"] for d in vanilla if d["kind"] == "text"} == {BOLD}, \
        "the in-level text is the game's bold, not the menu's italic"
    assert line not in gui


def test_chat_in_the_games_font(tmp_path):
    engine = Engine(tmp_path, modules=MODULES + ("chat",))
    engine.lua("lstate.screen = SCREEN.CAMP; Network.phase = Network.PHASE.LOBBY")
    engine.gui()
    engine.frame(screen="CAMP")
    vanilla, gui = engine.frame(screen="CAMP")
    assert "[T] chat" in texts(vanilla)
    assert "[T] chat" not in gui
