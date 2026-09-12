"""Tests for marking a networked run as SEEDED.

A networked run IS a seeded run — the server hands out the adventure seed — but
the engine was never told, so `state.quest_flags` said "adventure run" and mods
took the branch meant for a solo player building their own save. The HD mod does
exactly that in the one place it reads the flag: it picks a per-floor character
unlock from `savegame.characters` (how many HD characters THIS player has
unlocked) and draws from PRNG_CLASS.LEVEL_GEN to choose one, so two players with
different unlocks consumed a different number of generation draws and every
later draw landed elsewhere.

The subtle part is the flag itself: QUEST_FLAG holds 1-BASED BIT INDICES, not
masks, and the two coincide only for bit 1 — which is the one this file already
had (QUEST_RESET), so nothing existing would have caught a mask/index mix-up.
These tests run the shipped source of the helpers against the same
set_flag/clr_flag/test_flag helpers the HD mod reads the flag with.

Run:  python -m pytest tests/test_seeded_run.py -q
"""

from __future__ import annotations

import re
import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")


def seeded_helpers() -> str:
    """The shipped source of the seeded-run helpers, verbatim."""
    m = re.search(
        r"(local QUEST_SEEDED_BIT = 7.*?\nlocal function clearRunSeeded\(\).*?\nend\n)",
        EVENT_SYNC,
        re.S,
    )
    assert m, "seeded-run helpers not found in src/eventSync.lua"
    # they are file-locals; expose them so the test can drive them
    return m.group(1) + "\nmark = markRunSeeded\nclear = clearRunSeeded\n"


# The engine's flag helpers, with Overlunky's 1-based-bit-index convention, and
# QUEST_FLAG as the game defines it.
ENV = """
function set_flag(flags, bit) return flags | (1 << (bit - 1)) end
function clr_flag(flags, bit) return flags & ~(1 << (bit - 1)) end
function test_flag(flags, bit) return (flags & (1 << (bit - 1))) ~= 0 end
QUEST_FLAG = { RESET = 1, SEEDED = 7 }

quest_flags = 0
function get_local_state() return state end
state = setmetatable({}, {
    __index = function(_, k) if k == "quest_flags" then return quest_flags end end,
    __newindex = function(_, k, v) if k == "quest_flags" then quest_flags = v end end,
})
in_run = true
Network = { isInRun = function() return in_run end }
"""


def runtime(quest_flags: int = 0, in_run: bool = True):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(ENV)
    lua.execute("quest_flags = %d; in_run = %s" % (quest_flags, "true" if in_run else "false"))
    lua.execute(seeded_helpers())
    return lua


def is_seeded(lua) -> bool:
    """Read it back exactly the way the HD mod does."""
    return lua.eval("test_flag(quest_flags, QUEST_FLAG.SEEDED)")


def test_a_networked_run_is_marked_seeded():
    lua = runtime()
    assert is_seeded(lua) is False
    lua.execute("mark()")
    assert is_seeded(lua) is True


def test_the_flag_is_a_bit_index_not_a_mask():
    """1 << (7-1) = 64. Treating the enum value as a mask would set bit 64."""
    lua = runtime()
    lua.execute("mark()")
    assert lua.eval("quest_flags") == 64


def test_other_quest_flags_are_preserved():
    lua = runtime(quest_flags=0x3050210)
    lua.execute("mark()")
    assert lua.eval("quest_flags") == 0x3050210 | 64
    assert is_seeded(lua) is True
    lua.execute("clear()")
    assert lua.eval("quest_flags") == 0x3050210


def test_the_reset_bit_is_untouched():
    """QUEST_RESET is bit 1 and drives instant restart; setting SEEDED must not
    look like a reset, and clearing SEEDED must not cancel one."""
    lua = runtime(quest_flags=1)
    lua.execute("mark()")
    assert lua.eval("test_flag(quest_flags, QUEST_FLAG.RESET)") is True
    lua.execute("clear()")
    assert lua.eval("test_flag(quest_flags, QUEST_FLAG.RESET)") is True
    assert is_seeded(lua) is False


def test_marking_is_idempotent():
    lua = runtime()
    lua.execute("mark(); mark(); mark()")
    assert lua.eval("quest_flags") == 64


def test_solo_play_is_never_marked():
    lua = runtime(in_run=False)
    lua.execute("mark()")
    assert is_seeded(lua) is False


def test_clearing_works_even_after_the_run_ended():
    """clearRunSeeded runs from clearRunState, by which point isInRun() is already
    false — so it must NOT be gated on being in a run."""
    lua = runtime()
    lua.execute("mark(); in_run = false; clear()")
    assert is_seeded(lua) is False


def test_the_hd_mods_unlock_branch_is_skipped_when_seeded():
    """The exact gate from fyi.hdmod/lib/unlocks.lua select_character_unlock: with
    the flag set it selects nothing and — the part that matters — draws nothing,
    so no machine's generation stream can drift from anyone else's."""
    lua = runtime()
    lua.execute("""
        draws = 0
        prng = { random_index = function() draws = draws + 1; return 1 end }
        QUEST_FLAG.DAILY = 8
        function select_character_unlock()
            local unlock = nil
            if not test_flag(quest_flags, QUEST_FLAG.SEEDED)
                and not test_flag(quest_flags, QUEST_FLAG.DAILY) then
                unlock = prng.random_index(prng, 4)
            end
            return unlock
        end
    """)
    assert lua.eval("select_character_unlock()") == 1
    assert lua.eval("draws") == 1
    lua.execute("mark(); draws = 0")
    assert lua.eval("select_character_unlock()") is None
    assert lua.eval("draws") == 0
