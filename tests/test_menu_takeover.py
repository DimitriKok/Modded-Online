"""MODDED ONLINE inside the game's main menu: menuInput, mainMenuHook and menuUI together.

The ONLINE row reads MODDED ONLINE and opens our menu. The controller drives it
through the game's menu input, the keyboard as before, and the vanilla menu
underneath never moves. VANILLA ONLINE hands the row back. Where the takeover
cannot install, the [O] chip and key come back.

These run the three shipped modules against the stubbed engine in
tests/menu_stub.py, whose vanilla main menu answers whatever input its update
actually read.

Run:  python -m pytest tests/test_menu_takeover.py -q
"""

from __future__ import annotations

import pathlib

import pytest

from menu_stub import ORDERS, Engine, open_menu

PACK = pathlib.Path(__file__).resolve().parent.parent
CHIP = "[O]  MODDED ONLINE"
ROOT = ["HOST", "JOIN", "MATCHMAKING", "DISCORD", "SETTINGS", "VANILLA ONLINE"]


@pytest.fixture
def engine(tmp_path):
    return Engine(tmp_path)


def plain(rows):
    return [r[2:] if r.startswith("> ") else r for r in rows]


def selected(rows):
    return [r[2:] for r in rows if r.startswith("> ")]


def pad(engine, *bits):
    """Press and release on the controller, then a GUI frame."""
    engine.update(*bits)
    engine.update()
    return engine.rows()


# ------------------------------------------------------------ the main menu

def test_the_online_row_reads_modded_online(engine):
    engine.update()
    assert engine.active() is True
    assert engine.label == "Modded Online"


def test_select_on_it_opens_our_menu_and_the_game_never_sees_the_press(engine):
    engine.update()
    engine.update("SELECT")
    assert engine.seen == (0, 0)
    assert engine.is_open()
    assert engine.menu["state"] == 7 and engine.menu["menu_id"] == 0, "vanilla Online opened"
    rows = engine.rows()
    assert plain(rows) == ROOT and selected(rows) == ["HOST"]


def test_the_other_rows_still_work(engine):
    engine.update()
    engine.lua("game_manager.screen_menu.selected_menu_index = 0")
    engine.update("SELECT")
    assert not engine.is_open()
    engine.update()
    assert engine.menu["menu_id"] == 1, "PLAY did not open its menu"


def test_no_chip_and_no_o_key_with_the_takeover(engine):
    engine.update()
    assert CHIP not in engine.gui()
    engine.gui("O")
    assert not engine.is_open()


def test_the_controller_drives_our_menu_and_the_vanilla_menu_stays_put(engine):
    open_menu(engine)
    assert selected(pad(engine, "DOWN")) == ["JOIN"]
    assert selected(pad(engine, "DOWN")) == ["MATCHMAKING"]
    assert selected(pad(engine, "UP")) == ["JOIN"]
    rows = pad(engine, "SELECT")
    assert "OFFICIAL SERVER" in plain(rows), rows
    assert engine.menu["selected_menu_index"] == 1 and engine.menu["menu_id"] == 0


def test_the_keyboard_still_works(engine):
    open_menu(engine)
    assert selected(engine.rows("DOWN")) == ["JOIN"]
    assert "OFFICIAL SERVER" in plain(engine.rows("RETURN"))
    assert selected(engine.rows("ESCAPE")) == ["HOST"]


def test_a_press_in_the_moment_after_opening_is_ignored(engine):
    """ENTER or Z on the main menu is still down on the next GUI frame."""
    engine.update()
    engine.update("SELECT")
    engine.update()
    rows = engine.rows("RETURN")
    assert plain(rows) == ROOT, "the key that opened the menu picked HOST"


def test_back_closes_it_and_the_game_menu_is_as_it_was(engine):
    open_menu(engine)
    pad(engine, "BACK")
    assert not engine.is_open()
    assert engine.eval("wentToTitle") is False
    assert engine.menu == {"state": 7, "menu_id": 0, "selected_menu_index": 1,
                           "transfer_to_menu_id": 0}
    engine.wait(400)
    assert engine.label == "Modded Online"
    engine.update("SELECT")             # and it opens again
    assert engine.is_open()


# ----------------------------------------------- wherever the menu reads its input
#
# dev68 hid the input in PRE_UPDATE and put it back at POST_UPDATE. In the game the
# first press still opened the game's Online menu (desync log: "the game opened its
# own Online menu after a press that was swallowed"), so the menu reads somewhere
# else. The stub's menu can read at any of four points, and linger in its highlight
# state first or not; the takeover must hold in every combination.

@pytest.mark.parametrize("highlight", (0, 6))
@pytest.mark.parametrize("order", ORDERS)
def test_select_opens_ours_and_never_the_games_wherever_it_reads(tmp_path, order, highlight):
    engine = Engine(tmp_path, order=order, highlight=highlight)
    engine.update()
    engine.gui()
    engine.update("SELECT")
    for _ in range(12):
        engine.gui()
        engine.update()
    assert engine.active() is True, engine.eval("MainMenuHook.why()")
    assert engine.is_open()
    assert engine.menu["menu_id"] == 0 and engine.menu["state"] == 7


@pytest.mark.parametrize("order", ORDERS)
def test_back_never_reaches_the_games_menu_wherever_it_reads(tmp_path, order):
    engine = Engine(tmp_path, order=order)
    open_menu(engine)
    for _ in range(3):
        engine.update("BACK")
        engine.gui()
    engine.wait(500)
    assert not engine.is_open()
    assert engine.eval("wentToTitle") is False, order


@pytest.mark.parametrize("highlight", (0, 6))
@pytest.mark.parametrize("order", ORDERS)
def test_vanilla_online_reaches_the_game_wherever_it_reads(tmp_path, order, highlight):
    engine = Engine(tmp_path, order=order, highlight=highlight)
    choose_vanilla_online(engine)
    for _ in range(60):
        engine.update()
        engine.gui()
    assert engine.menu["menu_id"] == 2, (order, highlight)
    assert engine.active() is True, engine.eval("MainMenuHook.why()")


def test_a_build_that_reads_before_our_callback_says_so_and_falls_back(tmp_path):
    """No POST_PROCESS_INPUT, and the menu reads before PRE_UPDATE: nothing written
    from PRE_UPDATE can reach it. The takeover must notice, not fail silently."""
    engine = Engine(tmp_path, order="after_input", before="ON.POST_PROCESS_INPUT = nil")
    engine.update()
    engine.gui()
    engine.update("SELECT")
    assert engine.active() is False
    assert "took the press before PRE_UPDATE ran" in str(engine.eval("MainMenuHook.why()"))
    engine.lua("game_manager.screen_menu.menu_id = 0")
    engine.wait(400)
    assert CHIP in engine.gui()


# ------------------------------------------------------------ VANILLA ONLINE

def choose_vanilla_online(engine):
    open_menu(engine)
    for _ in range(5):
        pad(engine, "DOWN")
    assert selected(engine.rows()) == ["VANILLA ONLINE"]
    pad(engine, "SELECT")


def test_vanilla_online_opens_the_games_own_online_menu(engine):
    choose_vanilla_online(engine)
    assert not engine.is_open()
    assert engine.label == "Online", "the game's own label was not put back first"
    for _ in range(40):
        engine.update()
        engine.gui()
        if engine.menu["menu_id"] == 2:
            break
    assert engine.menu["menu_id"] == 2, "the game's Online menu never opened"
    assert engine.label == "Online"


def test_backing_out_of_vanilla_online_brings_the_label_back(engine):
    choose_vanilla_online(engine)
    engine.wait(600)
    assert engine.menu["menu_id"] == 2
    engine.update("BACK")
    engine.update()
    engine.update()
    assert engine.menu["menu_id"] == 0
    assert engine.label == "Modded Online"
    engine.update("SELECT")
    assert engine.is_open(), "the row did not come back to us"


def test_vanilla_online_leaves_a_room_first(engine):
    open_menu(engine)
    engine.lua('Network.phase = Network.PHASE.LOBBY')
    for _ in range(5):
        pad(engine, "DOWN")
    pad(engine, "SELECT")
    assert int(engine.eval("Network.left")) == 1
    assert int(engine.eval("#toasts")) == 1


# ------------------------------------------------------------ leaving MENU

def test_other_screens_show_the_games_own_label(engine):
    engine.update()
    engine.lua("lstate.screen = SCREEN.OPTIONS")
    engine.update()
    assert engine.label == "Online"
    engine.lua("lstate.screen = SCREEN.MENU")
    engine.update()
    assert engine.label == "Modded Online"


# ------------------------------------------------------------ the fallback

def test_the_chip_and_o_key_come_back_when_it_cannot_install(tmp_path):
    engine = Engine(tmp_path, before="change_string = nil")
    engine.update()
    assert engine.active() is False
    assert CHIP in engine.gui()
    engine.gui("O")
    assert engine.is_open()
    assert "VANILLA ONLINE" not in plain(engine.rows())
    assert engine.label == "Online"


def test_the_flag_file_brings_the_chip_back(tmp_path):
    engine = Engine(tmp_path, flags=("mo_nomenuhook.on",))
    engine.update()
    assert CHIP in engine.gui()


def test_if_the_game_opens_online_despite_the_swallow_it_stands_down(engine):
    """With our menu already open, as it is by then: GUI frames between the updates."""
    engine.lua("engineIgnoresSwallow = true")
    engine.update()
    engine.gui()
    engine.update("SELECT")
    assert engine.is_open()
    for _ in range(3):
        engine.gui()
        engine.update()
    assert engine.active() is False
    assert not engine.is_open(), "our menu stayed up over the game's Online menu"
    assert engine.label == "Online"
    engine.lua("game_manager.screen_menu.menu_id = 0")
    engine.wait(400)
    assert CHIP in engine.gui()


def test_a_build_where_online_is_another_row_learns_it(engine):
    engine.lua("engineOnlineRow = 2; game_manager.screen_menu.selected_menu_index = 2")
    engine.update()
    engine.update("SELECT")             # not ours yet: the game's Online opens
    assert not engine.is_open()
    for _ in range(3):
        engine.update()
    assert engine.menu["menu_id"] == 2
    assert int(engine.eval("MainMenuHook.state.onlineRow")) == 2
    engine.lua("game_manager.screen_menu.menu_id = 0")
    engine.update()
    engine.update("SELECT")
    assert engine.is_open(), "the learned row did not open our menu"


# ------------------------------------------------------------ popups

def test_the_controller_answers_the_first_run_popups(tmp_path):
    engine = Engine(tmp_path, firstRunDone=False)
    engine.gui()
    for _ in range(3):                   # the two notices, then YES to sending logs
        engine.wait(700)
        pad(engine, "SELECT")
    engine.wait(700)
    pad(engine, "DOWN")
    pad(engine, "SELECT")                # NO to syncing
    assert engine.eval("Network.config.firstRunDone") is True
    assert engine.eval("Network.config.autoSendLogs") is True
    assert engine.eval("Network.config.autoSyncSave") is False
    assert engine.seen == (0, 0), "a popup's press reached the main menu"


def test_a_popup_press_before_the_pause_is_ignored(tmp_path):
    engine = Engine(tmp_path, firstRunDone=False)
    engine.gui()
    pad(engine, "SELECT")
    assert engine.eval("Network.config.firstRunDone") is False
    assert engine.eval("Network.config.autoSendLogs") is False


# ------------------------------------------------------------ chat

def chat_in_camp(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook", "menuUI", "chat"))
    engine.lua("lstate.screen = SCREEN.CAMP; Network.phase = Network.PHASE.LOBBY")
    return engine


def test_chat_does_not_open_behind_a_popup(tmp_path):
    engine = chat_in_camp(tmp_path)
    engine.lua("NetMenuUI.showRestartNotice()")
    engine.gui()
    engine.lua("down[0x54] = true; runCallbacks(ON.GUIFRAME, ctx); down = {}")  # T
    assert engine.eval("Chat.isTyping()") is False


def test_enter_answers_the_popup_without_sending_the_chat_line(tmp_path):
    """RESTART REQUIRED can come up in the camp while the player is typing."""
    engine = chat_in_camp(tmp_path)
    engine.lua("down[0x54] = true; runCallbacks(ON.GUIFRAME, ctx); down = {}")  # T
    assert engine.eval("Chat.isTyping()") is True
    engine.gui("A")
    engine.lua("NetMenuUI.showRestartNotice()")
    engine.gui()
    engine.gui(ms=700)
    engine.gui("RETURN")
    kinds = [str(engine.eval("sent[%d]" % i)) for i in range(1, int(engine.eval("#sent")) + 1)]
    assert "chat" not in kinds, "the line was sent with the popup's ENTER"
    engine.gui()
    assert engine.eval("NetMenuUI.popupVisible()") is False, "ENTER did not answer the popup"
    assert engine.eval("Chat.isTyping()") is True, "the chat box lost what was typed"


# ------------------------------------------------------------ settings

def open_settings(engine):
    open_menu(engine)
    for _ in range(4):
        pad(engine, "DOWN")
    return pad(engine, "SELECT")


def test_left_and_right_change_a_setting(engine):
    rows = open_settings(engine)
    assert selected(rows) == ["HIDE ROOM CODE  [OFF]"]
    assert selected(pad(engine, "RIGHT")) == ["HIDE ROOM CODE  [ON]"]
    assert selected(pad(engine, "LEFT")) == ["HIDE ROOM CODE  [OFF]"]
    pad(engine, "DOWN")
    assert selected(pad(engine, "RIGHT")) == ["TEST PLAYERS  [1]"]
    assert selected(pad(engine, "LEFT")) == ["TEST PLAYERS  [OFF]"]
    assert selected(pad(engine, "LEFT")) == ["TEST PLAYERS  [3]"], "LEFT did not wrap"


def test_a_held_right_flips_a_switch_once(engine):
    open_settings(engine)
    for _ in range(60):
        engine.update("RIGHT")
        engine.gui()
    assert engine.eval("Network.config.hideRoomCode") is True
    assert int(engine.eval("Network.saves")) == 1


def test_the_keyboard_arrows_change_a_setting_too(engine):
    open_settings(engine)
    assert selected(engine.rows("RIGHT")) == ["HIDE ROOM CODE  [ON]"]


# ------------------------------------------------------------ connecting

def host_official(engine):
    open_menu(engine)
    pad(engine, "SELECT")                # HOST
    return pad(engine, "SELECT")         # OFFICIAL SERVER


def test_hosting_waits_on_a_connecting_page(engine):
    drawn_rows = host_official(engine)
    assert plain(drawn_rows) == ["CANCEL"]
    texts = engine.gui()
    assert "- CONNECTING -" in texts and "Connecting to the server..." in texts


def test_the_room_shows_and_the_menu_fades_with_the_game(engine):
    host_official(engine)
    engine.lua('Network.phase = Network.PHASE.LOBBY; Network.room = "ABCD"')
    texts = engine.gui()
    assert "- ROOM ABCD -" in texts and "Joined! Starting the game..." in texts
    assert engine.is_open()
    engine.lua("lstate.loading = FADE.OUT")    # the play flow starts its fade
    engine.gui()
    assert not engine.is_open()


def test_an_error_stays_on_the_page_and_back_returns(engine):
    engine.lua('connectResult = "Could not reach the server"')
    rows = host_official(engine)
    assert plain(rows) == ["BACK"]
    assert "! Could not reach the server" in engine.gui()
    rows = pad(engine, "BACK")
    assert "OFFICIAL SERVER" in plain(rows)


def test_cancel_leaves_the_room(engine):
    host_official(engine)
    pad(engine, "SELECT")
    assert int(engine.eval("Network.left")) == 1


# ------------------------------------------------------------ the watchdog

def test_with_no_gui_frames_the_game_gets_its_input_back(engine):
    """Nothing of ours can be on screen without GUI frames: a menu still open must not
    leave the main menu deaf. The game keeps updating; only the GUI has stopped."""
    open_menu(engine)
    for _ in range(150):                 # 2.4 s of updates, no GUI frame
        engine.lua("now = now + 16")
        engine.update()
    engine.update("DOWN")
    assert engine.seen[0] != 0
    assert not engine.is_open()


def test_the_whole_game_freezing_is_not_the_gui_stopping(engine):
    """dev69: HOST froze the game for 7.7 s (the bridge launching), and the first
    update after it closed the menu, "no GUI frame for 7698 ms". With the updates
    stopped too, it is the game that was away, and the menu stays."""
    open_menu(engine)
    engine.lua("now = now + 7700")       # nothing at all ran
    engine.update("DOWN")
    assert engine.is_open()
    assert engine.seen == (0, 0)


# ------------------------------------------------------------ structure

def test_the_modules_load_in_the_order_they_depend_on():
    main = (PACK / "main.lua").read_text(encoding="utf-8")
    order = ["src.inputSync", "src.eventSync", "src.menuProbe", "src.menuInput",
             "src.mainMenuHook", "src.menuUI", "src.chat"]
    at = [main.index('"%s"' % name) for name in order]
    assert at == sorted(at), order


def test_the_engine_update_marker_is_still_the_last_pre_update_of_ours():
    main = (PACK / "main.lua").read_text(encoding="utf-8")
    marker = main.index('DesyncLog.frameMark("engineUpdate")')
    assert main.index("for _, path in ipairs(MODULES) do") < marker
