"""The GameManager accessor must tolerate a build that does not expose it.

`get_game_manager()` is an Overlunky API that IS NOT ON EVERY PLAYLUNKY BUILD. A real
capture of the journal probe read back, for every field it tried:

    attempt to call a nil value (global 'get_game_manager')

Not "journal_ui is nil" -- the function itself is not a global. Two real features
called it inside a bare `pcall` and read the failure as "no journal is open":

  * pollPlayFlow waits for the death-recap book to finish animating before launching
    character select. It never waited -- which is the wedged endless page-turn on
    CHOOSE ADVENTURER that the wait was added to stop.
  * pollCloseStrayJournal force-closes a journal drawn over the character select. It
    never closed one.

Both were silently inert for the life of the build. A pcall around a missing global
is indistinguishable from a legitimate "nothing here", which is exactly why this went
unnoticed until a probe printed the message instead of swallowing it.

Run:  python -m pytest tests/test_game_manager_access.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
UTIL = (PACK / "src" / "util.lua").read_text(encoding="utf-8")
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")


def runtime(expose: str = "") -> lupa.LuaRuntime:
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("function print() end")
    rt.execute(expose)
    rt.execute(UTIL)
    return rt


def test_a_build_without_the_api_degrades_instead_of_erroring():
    rt = runtime()
    assert rt.eval("GameManager()") is None
    assert rt.eval("JournalUI()") is None
    assert str(rt.eval("GameManagerVia()")) == "none"


def test_the_modern_accessor_is_used_when_present():
    rt = runtime("""
    function get_game_manager() return { journal_ui = { state = 3 } } end
    """)
    assert int(rt.eval("JournalUI().state")) == 3
    assert str(rt.eval("GameManagerVia()")) == "get_game_manager()"


def test_the_global_is_used_when_the_function_is_absent():
    """The whole point: a build that exposes one and not the other still works."""
    rt = runtime("game_manager = { journal_ui = { state = 5 } }")
    assert int(rt.eval("JournalUI().state")) == 5
    assert str(rt.eval("GameManagerVia()")) == "game_manager"


def test_a_missing_journal_ui_is_not_an_error():
    rt = runtime("function get_game_manager() return {} end")
    assert rt.eval("JournalUI()") is None


def test_the_miss_is_latched_rather_than_retried_every_frame():
    """The journal polls call this per frame. A failing global lookup every frame for
    the life of the session is a cost with no information in it."""
    at = UTIL.index("function GameManager()")
    body = UTIL[at:UTIL.index(chr(10) + "end", at)]
    assert 'gmVia == "none"' in body


def code_only(source: str) -> str:
    """Source with comment lines dropped -- the name legitimately appears in prose
    explaining why it is no longer called."""
    return chr(10).join(l for l in source.split(chr(10))
                        if not l.lstrip().startswith("--"))


def test_both_silently_inert_callers_were_converted():
    assert "get_game_manager()" not in code_only(EVENT_SYNC), (
        "eventSync still calls the API directly; a build without it goes quiet again"
    )
    assert "JournalUI()" in EVENT_SYNC


def test_the_probe_does_not_hard_depend_on_util_being_loaded():
    """Diagnosing the journal must never be the thing that breaks the boot."""
    assert "get_game_manager()" not in code_only(MOD_HOST)
    at = MOD_HOST.index("local function journalField(field)")
    body = MOD_HOST[at:MOD_HOST.index(chr(10) + "end", at)]
    assert 'rawget(_G, "JournalUI")' in body
