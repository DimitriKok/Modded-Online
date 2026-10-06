"""The game's own menu input, for our menus and popups (src/menuInput.lua).

`game_props.input_menu` drives every vanilla menu, from the keyboard bindings and
controllers alike. While one of our menus or popups is up it is read, turned into
menu actions, and zeroed right after the game builds it (ON.POST_PROCESS_INPUT), so
the vanilla menu underneath stays where it was -- wherever in the frame it reads.

dev68 zeroed it in PRE_UPDATE and put it back at POST_UPDATE, which only holds if the
menu reads between the two. In the game it does not: the first press on MODDED
ONLINE still opened the game's Online menu. The stub's menu can read at any of four
points in a frame (menu_stub.ORDERS), and the swallow is tested at every one.

`step` is pure and is tested directly. The rest runs against the stubbed engine in
tests/menu_stub.py, which records what the game's menu read when it read.

Run:  python -m pytest tests/test_menu_input.py -q
"""

from __future__ import annotations

import pytest

from menu_stub import BITS, ORDERS, Engine, open_menu


@pytest.fixture
def engine(tmp_path):
    return Engine(tmp_path)


STEP = """
timers = { up = 0, down = 0, left = 0, right = 0 }
emitted = {}
function emitTo(action, isRepeat) emitted[#emitted + 1] = action .. (isRepeat and "+" or "") end
prevBits = 0
clock = 100000
-- one call, `ms` after the last
function stepWith(bits, ms)
    emitted = {}
    clock = clock + ms
    MenuInput.step(bits, prevBits, timers, emitTo, clock)
    prevBits = bits
    local out = {}
    for i = 1, #emitted do out[i] = emitted[i] end
    return table.concat(out, ",")
end
"""


@pytest.fixture
def step(tmp_path):
    engine = Engine(tmp_path, modules=("menuInput",))
    engine.lua(STEP)

    def run(*bits, ms=16):
        mask = 0
        for bit in bits:
            mask |= BITS[bit]
        return str(engine.eval("stepWith(%d, %d)" % (mask, ms)))

    run.engine = engine
    return run


# ------------------------------------------------------------------------ step

def test_a_press_is_one_action(step):
    assert step("DOWN") == "down"
    assert step("DOWN") == ""
    assert step() == ""
    assert step("SELECT") == "select"
    assert step("SELECT") == "", "a held SELECT is not a second press"
    assert step("BACK") == "back"


def test_a_held_direction_repeats_after_a_delay(step):
    """On the clock, so it feels the same whatever rate the input callback runs at."""
    delay = int(step.engine.eval("MenuInput.REPEAT_DELAY_MS"))
    every = int(step.engine.eval("MenuInput.REPEAT_EVERY_MS"))
    fired = [step("DOWN", ms=10) for _ in range(100)]   # a second, in 10 ms calls
    assert fired[0] == "down"
    repeats = [i * 10 for i, f in enumerate(fired) if f == "down+"]
    assert delay <= repeats[0] < delay + 10, repeats
    gaps = [b - a for a, b in zip(repeats, repeats[1:])]
    assert gaps and all(every <= g < every + 10 for g in gaps), gaps


def test_the_repeat_rate_does_not_follow_the_call_rate(step):
    slow = [step("DOWN", ms=16) for _ in range(63)]       # ~1 s at 60 calls a second
    step()
    fast = [step("DOWN", ms=4) for _ in range(250)]       # ~1 s at 250 calls a second
    assert abs(slow.count("down+") - fast.count("down+")) <= 1


def test_select_and_back_never_repeat(step):
    fired = [step("SELECT", "BACK") for _ in range(60)]
    assert fired[0] == "select,back"
    assert set(fired[1:]) == {""}


def test_letting_go_starts_the_count_again(step):
    for _ in range(30):
        step("UP", ms=50)
    step()
    assert step("UP") == "up"


def test_a_direction_marked_held_is_silent_until_let_go(step):
    step.engine.lua("prevBits = 256; timers = { up = 0, down = -1, left = 0, right = 0 }")
    assert all(step("DOWN") == "" for _ in range(40))
    step()
    assert step("DOWN") == "down"


def test_a_direction_held_when_our_menu_opens_is_not_a_press_in_it(tmp_path):
    engine = Engine(tmp_path)
    engine.update()
    engine.gui()
    engine.update("DOWN")               # held on the pad as the menu opens
    engine.lua('NetMenuUI.open("a test", true)')
    # under a second: any longer and a cursor wrongly moving could wrap round the six
    # rows and land on HOST again
    for _ in range(8):
        engine.update("DOWN")
        engine.gui(ms=50)
    assert engine.rows()[0] == "> HOST", "the held DOWN moved the cursor"
    engine.update()
    engine.update("DOWN")
    assert engine.rows()[1] == "> JOIN", "a fresh DOWN did nothing"


# --------------------------------------------------------------- swallowing

def test_while_our_menu_is_up_the_engine_sees_nothing(engine):
    open_menu(engine)
    for bits in (("DOWN",), ("SELECT",), ("BACK",), ("JOURNAL",), ("LEFT", "UP")):
        engine.update(*bits)
        assert engine.seen == (0, 0), bits
        engine.update()
    assert engine.menu["selected_menu_index"] == 1, "the vanilla highlight moved"
    assert engine.eval("wentToTitle") is False


@pytest.mark.parametrize("order", ORDERS)
def test_wherever_the_menu_reads_it_sees_nothing_while_ours_is_up(tmp_path, order):
    engine = Engine(tmp_path, order=order)
    open_menu(engine)
    for bits in (("DOWN",), ("SELECT",), ("BACK",), ("UP", "LEFT")):
        for _ in range(3):
            engine.update(*bits)
            engine.gui()
            assert engine.seen == (0, 0), (order, bits)
        engine.update()
        engine.gui()
    assert engine.menu["selected_menu_index"] == 1, "the vanilla highlight moved"
    assert engine.menu["state"] == 7 and engine.eval("wentToTitle") is False


def test_nothing_is_ever_put_back(engine):
    """dev68 put the device's value back at POST_UPDATE. A menu that reads after
    POST_UPDATE, or at the start of the next frame, was handed the very press we hid."""
    open_menu(engine)
    engine.update("SELECT")
    assert int(engine.eval("game_manager.game_props.input_menu")) == 0
    assert int(engine.eval("game_manager.game_props.input_menu_previous")) == 0


def test_the_main_menus_own_direction_flags_are_cleared_too(engine):
    engine.lua("game_manager.screen_menu.controls = { up = true, down = true, left = false,"
               " right = false, direction_input = 1 }")
    open_menu(engine)
    engine.update("DOWN")
    controls = engine.eval("game_manager.screen_menu.controls")
    assert controls.down is False and controls.direction_input == -1


@pytest.mark.parametrize("order", ("frame_start", "inside", "after_post"))
def test_without_post_process_input_pre_update_still_hides_it(tmp_path, order):
    """A build without the callback: PRE_UPDATE does it all, and since nothing is put
    back, a menu reading after POST_UPDATE or at the next frame's start is covered too.
    (One reading between the input and PRE_UPDATE cannot be reached from PRE_UPDATE.)"""
    engine = Engine(tmp_path, order=order, before="ON.POST_PROCESS_INPUT = nil")
    assert engine.eval("MenuInput.via()") == "PRE_UPDATE"
    open_menu(engine)
    for _ in range(3):
        engine.update("SELECT")
        engine.gui()
        assert engine.seen == (0, 0), order
    assert engine.menu["menu_id"] == 0 and engine.menu["state"] == 7


def test_a_refill_before_the_update_is_hidden_again(tmp_path):
    """If anything fills the field again after POST_PROCESS_INPUT, PRE_UPDATE hides it
    once more before the update reads it."""
    engine = Engine(tmp_path, order="inside", before="engineRefills = true")
    open_menu(engine)
    for bits in (("DOWN",), ("SELECT",), ("BACK",)):
        engine.update(*bits)
        engine.gui()
        assert engine.seen == (0, 0), bits


def test_with_post_process_input_it_is_the_one_used(engine):
    assert engine.eval("MenuInput.via()") == "POST_PROCESS_INPUT"


def test_never_in_a_run(engine):
    """inputSync owns the field during a run (a transition's synced menu input)."""
    open_menu(engine)
    engine.lua("Network.phase = Network.PHASE.INGAME")
    engine.update("SELECT")
    assert engine.seen == (BITS["SELECT"], 0)
    engine.update("DOWN")
    assert engine.seen == (BITS["DOWN"], BITS["SELECT"])


def test_every_pre_update_returns_nothing(engine):
    """A value returned from PRE_UPDATE skips the engine's update."""
    open_menu(engine)
    for bits in ((), ("SELECT",), ("BACK",)):
        engine.update(*bits)
        assert int(engine.eval("preUpdateValues")) == 0


def test_closing_keeps_the_engine_blind_until_the_button_is_let_go(engine):
    open_menu(engine)
    engine.update("BACK")
    engine.gui()
    assert not engine.is_open()
    for _ in range(30):                 # BACK still held, well past the release window
        engine.update("BACK")
        engine.gui()
    assert engine.seen == (0, 0)
    assert engine.eval("wentToTitle") is False, "the BACK that closed us reached the menu"
    engine.update()
    engine.gui()
    engine.update("DOWN")
    assert engine.seen[0] == BITS["DOWN"], "the game never got its input back"


def test_the_release_latch_gives_up_after_a_second(engine):
    open_menu(engine)
    engine.update("BACK")
    engine.gui()
    for _ in range(80):                 # held for over a second
        engine.update("BACK")
        engine.gui()
    assert engine.seen[0] == BITS["BACK"]


def test_the_press_that_opened_the_menu_is_not_a_press_in_it(engine):
    engine.update()
    engine.update("SELECT")             # opens our menu
    engine.gui()
    for _ in range(20):                 # still held
        engine.update("SELECT")
        engine.gui(ms=50)
    assert engine.rows()[0] == "> HOST", "the held SELECT picked HOST"


def test_with_nothing_of_ours_up_the_input_is_untouched(engine):
    engine.update()
    engine.lua("game_manager.screen_menu.selected_menu_index = 3")
    engine.update("DOWN")
    assert engine.seen == (BITS["DOWN"], 0)


def test_a_popup_in_the_camp_stops_the_spelunker_and_is_not_put_back(engine):
    """The pause menu and journal read the field after the update, so on the camp
    the swallowed press is not restored for them."""
    engine.lua("lstate.screen = SCREEN.CAMP")
    engine.lua("NetMenuUI.showRestartNotice()")
    engine.gui()
    engine.lua("for i = 1, 4 do lstate.player_inputs.player_slots[i].buttons = 513 end")
    engine.update("SELECT")
    assert engine.seen == (0, 0)
    assert int(engine.eval("lstate.player_inputs.player_slots[1].buttons")) == 0
    assert int(engine.eval("game_manager.game_props.input_menu")) == 0


def test_a_build_that_refuses_the_write_stands_down(tmp_path):
    engine = Engine(tmp_path)
    open_menu(engine)
    engine.lua("""
        local real = game_manager.game_props
        engineProps = real
        game_manager.game_props = setmetatable({}, {
            __index = real,
            __newindex = function() error("read-only field") end,
        })
    """)
    engine.update("DOWN")
    assert engine.eval("MenuInput.available()") is False
    assert "read-only" in str(engine.eval("MenuInput.why()"))
    assert engine.active() is False, "the takeover kept going without its input"
