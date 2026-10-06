"""MODDED ONLINE as the main menu's ONLINE row (src/mainMenuHook.lua).

The rows of the main menu are not reachable from the script API, so the ONLINE row
is taken over: relabelled MODDED ONLINE, its SELECT swallowed and our menu opened,
and handed back (VANILLA ONLINE) by restoring the label and giving the engine one
SELECT on that row.

These drive `decide` -- the whole policy, as a pure function of the main menu's
state and the input -- and the label handling, against the stubbed engine in
tests/menu_stub.py. tests/test_menu_takeover.py runs the modules together.

Run:  python -m pytest tests/test_main_menu_hook.py -q
"""

from __future__ import annotations

import pytest

from menu_stub import Engine

IDLE, HIGHLIGHT, TO_SUBMENU = 7, 6, 8
ONLINE = 1


@pytest.fixture
def hook(tmp_path):
    return Engine(tmp_path, modules=("mainMenuHook",))


def decide(hook, screen="MENU", menu_id=0, state=IDLE, index=ONLINE, transfer=0, now=0,
           prev=0, ms=1000, capturing=False):
    """One call of decide, `ms` on the clock."""
    hook.lua("""
        snap = { screen = SCREEN.%s, menuId = %d, state = %d, index = %d, transferTo = %d,
                 now = %d, prev = %d, ms = %d, capturing = %s, via = "POST_PROCESS_INPUT" }
        out = MainMenuHook.decide(snap, MainMenuHook.state, {})
    """ % (screen, menu_id, state, index, transfer, now, prev, ms,
           "true" if capturing else "false"))
    return {k: hook.eval("out.%s" % k) for k in
            ("label", "swallow", "open", "inject", "fail", "relearn", "note")}


# ------------------------------------------------------------------ intercept

def test_a_select_on_online_at_idle_is_swallowed_and_opens_the_menu(hook):
    out = decide(hook, now=1)
    assert out["swallow"] and out["open"] and out["label"]


def test_a_held_select_is_not_a_press(hook):
    out = decide(hook, now=1, prev=1)
    assert not out["swallow"] and not out["open"]


def test_other_rows_are_left_alone(hook):
    for index in (0, 2, 3, 4, 5):
        out = decide(hook, index=index, now=1)
        assert not out["swallow"] and not out["open"], index


def test_never_during_the_intro(hook):
    for state in (0, 1, 2, 3, 4):
        out = decide(hook, state=state, now=1)
        assert not out["swallow"] and not out["open"], state


def test_swallowed_but_not_opened_while_the_menu_is_still_settling(hook):
    for state in (5, HIGHLIGHT):
        out = decide(hook, state=state, now=1)
        assert out["swallow"] and not out["open"], state


def test_not_in_the_states_past_idle(hook):
    for state in (TO_SUBMENU, 9, 10):
        out = decide(hook, state=state, now=1)
        assert not out["swallow"] and not out["open"], state


def test_not_in_a_submenu(hook):
    for menu_id in (1, 2):
        out = decide(hook, menu_id=menu_id, now=1)
        assert not out["swallow"] and not out["open"] and not out["label"], menu_id


def test_not_while_our_menu_is_up(hook):
    out = decide(hook, now=1, capturing=True)
    assert not out["swallow"] and not out["open"]


def test_not_off_the_main_menu(hook):
    out = decide(hook, screen="OPTIONS", now=1)
    assert out == {"label": False, "swallow": False, "open": False, "inject": False,
                   "fail": None, "relearn": None, "note": None}


# ---------------------------------------------------------------------- label

def test_the_label_is_wanted_on_the_main_menu_only(hook):
    assert decide(hook)["label"] is True
    assert decide(hook, menu_id=2)["label"] is False
    assert decide(hook, screen="CAMP")["label"] is False


@pytest.mark.parametrize("original, label", [
    ("Online", "Modded Online"),
    ("ONLINE", "MODDED ONLINE"),
    ("En ligne", "Modded Online"),
    ("オンライン", "MODDED ONLINE"),
])
def test_the_label_follows_the_games_casing(hook, original, label):
    assert hook.eval('MainMenuHook.labelFor("%s")' % original) == label


# ---------------------------------------------------------- the self-checks

def test_the_engine_opening_online_after_our_swallow_is_a_failure(hook):
    decide(hook, now=1, ms=1000)
    out = decide(hook, state=TO_SUBMENU, transfer=2, ms=1032)
    assert out["fail"] is not None


def test_the_failure_says_where_the_press_was_swallowed_and_what_followed(hook):
    """So the next capture answers the next question without a probe session."""
    decide(hook, now=1, ms=1000)
    fail = str(decide(hook, state=TO_SUBMENU, transfer=2, ms=1032)["fail"])
    assert "in POST_PROCESS_INPUT" in fail and "at menu state 7" in fail
    assert "32 ms later" in fail and "state 8" in fail and "moving to 2" in fail


def test_entering_online_some_other_way_is_not_a_failure(hook):
    """Coming back from the online lobby lands on the Online menu with no press of
    ours swallowed."""
    out = decide(hook, menu_id=2, ms=50000)
    assert out["fail"] is None


def test_a_swallow_long_ago_does_not_count(hook):
    decide(hook, now=1, ms=1000)
    out = decide(hook, menu_id=2, ms=1000 + int(hook.eval("MainMenuHook.FAIL_WINDOW_MS")) + 1)
    assert out["fail"] is None


def test_a_press_that_went_through_and_opened_online_names_the_real_row(hook):
    decide(hook, index=2, now=1, ms=1000)
    out = decide(hook, index=2, state=TO_SUBMENU, transfer=2, ms=1016)
    assert out["relearn"] == 2


def test_play_opening_its_own_menu_teaches_nothing(hook):
    decide(hook, index=0, now=1, ms=1000)
    out = decide(hook, index=0, state=TO_SUBMENU, transfer=1, ms=1016)
    assert out["relearn"] is None and out["fail"] is None


# ------------------------------------------------------------ VANILLA ONLINE

def start_hand_over(hook, ms=1000):
    hook.lua('MainMenuHook.state.stage = "release"; MainMenuHook.state.stageMs = %d' % ms)


def test_the_hand_over_waits_for_the_buttons_to_be_let_go(hook):
    start_hand_over(hook)
    out = decide(hook, now=1, prev=1, ms=1016)
    assert out["swallow"] and not out["inject"] and not out["label"]
    out = decide(hook, now=0, prev=1, ms=1032)
    assert hook.eval("MainMenuHook.state.stage") == "inject"


def test_then_one_select_goes_to_the_engine_on_the_online_row(hook):
    start_hand_over(hook)
    decide(hook, ms=1016)
    out = decide(hook, ms=1032)
    assert out["inject"] and not out["label"]
    assert hook.eval("MainMenuHook.state.stage") == "injected"
    assert decide(hook, ms=1048)["inject"] is False, "handed over twice"


def test_the_game_label_stays_until_its_online_menu_has_come_and_gone(hook):
    start_hand_over(hook)
    decide(hook, ms=1016)
    decide(hook, ms=1032)
    assert decide(hook, state=TO_SUBMENU, transfer=2, ms=1048)["label"] is False
    assert decide(hook, menu_id=2, ms=1064)["label"] is False
    assert decide(hook, menu_id=2, state=TO_SUBMENU, transfer=0, ms=5000)["label"] is False
    out = decide(hook, ms=5016)
    assert out["label"] is True and hook.eval("MainMenuHook.state.stage") is None


def test_a_hand_over_that_opens_nothing_gives_up(hook):
    start_hand_over(hook)
    decide(hook, ms=1016)
    decide(hook, ms=1032)
    timeout = int(hook.eval("MainMenuHook.INJECT_TIMEOUT_MS"))
    out = decide(hook, ms=1033 + timeout)
    assert hook.eval("MainMenuHook.state.stage") is None
    assert "did not open" in str(out["note"])


def test_a_hand_over_abandons_if_the_menu_moved_off_the_row(hook):
    start_hand_over(hook)
    decide(hook, ms=1016)
    out = decide(hook, index=3, ms=1032)
    assert not out["inject"] and hook.eval("MainMenuHook.state.stage") is None


def test_leaving_the_main_menu_ends_a_hand_over(hook):
    start_hand_over(hook)
    decide(hook, screen="OPTIONS", ms=1016)
    assert hook.eval("MainMenuHook.state.stage") is None


# ------------------------------------------------------------------ install

def test_it_does_not_install_during_the_logos(tmp_path):
    """The label is read to prove the string table answers; before the title screen
    it may not, and a failure then would switch the takeover off for good."""
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"))
    engine.lua("lstate.screen = SCREEN.LOGO")
    engine.update()
    assert engine.active() is None, "installed during the logos"
    assert engine.label == "Online"
    engine.lua("lstate.screen = SCREEN.TITLE")
    engine.update()
    assert engine.active() is True


def test_it_says_why_when_a_piece_is_missing(tmp_path):
    for missing in ("change_string", "get_string", "hash_to_stringid"):
        engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"),
                        before="%s = nil" % missing)
        engine.update()
        assert engine.active() is False, missing
        assert missing in str(engine.eval("MainMenuHook.why()"))


def test_an_empty_label_means_no_string_table(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"),
                    before="strings[0xa1023681] = ''")
    engine.update()
    assert engine.active() is False


def test_the_flag_file_switches_it_off(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"),
                    flags=("mo_nomenuhook.on",))
    engine.update()
    assert engine.active() is False
    assert "mo_nomenuhook.on" in str(engine.eval("MainMenuHook.why()"))
    assert engine.label == "Online"


def test_the_name_windows_gives_the_flag_works_too(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"),
                    flags=("mo_nomenuhook.on.txt",))
    engine.update()
    assert engine.active() is False


def test_without_the_menu_input_module_it_stays_off(tmp_path):
    engine = Engine(tmp_path, modules=("mainMenuHook",))
    engine.lua("MainMenuHook.onInput(game_manager, 0, 0)")
    assert engine.active() is False


def test_a_build_with_no_input_callback_is_off_at_once(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"),
                    before="ON.PRE_UPDATE = nil; ON.POST_PROCESS_INPUT = nil")
    assert engine.active() is False
    assert "no callback" in str(engine.eval("MainMenuHook.why()"))


def test_a_takeover_that_never_installs_gives_up_after_a_few_seconds(tmp_path):
    """So the [O] chip comes back on a build where the update never runs."""
    engine = Engine(tmp_path, modules=("mainMenuHook",))
    assert engine.active() is None
    engine.lua("now = now + 5000")
    assert engine.active() is False


# --------------------------------------------------------------- the string

def test_a_reload_finds_our_own_label_and_still_restores_the_games(tmp_path):
    """The script reloaded in the same game: the table already says MODDED ONLINE."""
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"),
                    before='strings[0xa1023681] = "Modded Online"')
    engine.update()
    engine.lua("lstate.screen = SCREEN.OPTIONS")
    engine.update()
    assert engine.label == "Online"


def test_a_language_change_is_followed(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"))
    engine.update()
    assert engine.label == "Modded Online"
    engine.lua('strings[0xa1023681] = "En ligne"')  # the table reloaded in French
    engine.update()
    engine.lua("now = now + 1100")              # the next label check
    engine.update()
    assert engine.label == "Modded Online"
    engine.lua("lstate.screen = SCREEN.OPTIONS")
    engine.update()
    assert engine.label == "En ligne", "put the old language's text back"


def test_restore_leaves_a_reloaded_table_alone(tmp_path):
    """After a language change our edit is gone already: writing the old text over the
    new language would be wrong."""
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"))
    engine.update()
    engine.lua('strings[0xa1023681] = "Online (new)"')
    engine.lua("lstate.screen = SCREEN.OPTIONS")
    engine.update()
    assert engine.label == "Online (new)"


def test_the_label_is_written_once_not_every_update(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"))
    for _ in range(200):
        engine.update()
    assert int(engine.eval("#changes")) == 1


def test_script_disable_puts_the_games_label_back(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"))
    engine.update()
    engine.lua("runCallbacks(ON.SCRIPT_DISABLE)")
    assert engine.label == "Online"


def test_disable_puts_the_games_label_back(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput", "mainMenuHook"))
    engine.update()
    engine.lua('MainMenuHook.disable("a test")')
    assert engine.label == "Online" and engine.active() is False
