"""Tests that the journal page-render hook is only installed during a session.

The hook exists for exactly one job: skipping the vanilla page render so the stray
death-recap book cannot show over a menu or the character select in a NETWORKED
session. `journalShouldBeHidden` returns false on its first line when the session is
inactive, so outside one the hook can never do anything at all.

Registering it anyway is not harmless. A Lua pre-render hook makes the engine build
and hand over a page context for EVERY journal page it draws -- including the
fabricated page ids a content mod substitutes for its own journal. hdmod returns
601..620 from ON.POST_LOAD_JOURNAL_CHAPTER (captured verbatim in crash_notes.txt:
`hdmod_journal.lua:965(8) -> table #20 { 601, 602, ... }`), and none of those back a
real journal entry. hdmod has no such hook of its own, which is why its tutorial
journal works under Playlunky and died the instant it was hosted here -- this
registration was the only difference in that entire code path.

Run:  python -m pytest tests/test_journal_hook.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")
NL = chr(10)


def _block():
    """The journal-hook section, lifted out so it can run standalone."""
    start = EVENT_SYNC.index("--- The journal page-render hook, INSTALLED ONLY")
    marker = "function module.pollJournalHook()"
    end = EVENT_SYNC.index(NL + "end" + NL, EVENT_SYNC.index(marker)) + len(NL + "end" + NL)
    return EVENT_SYNC[start:end]


ENV = """
activeValue = false
hiddenValue = false
registered = {}
cleared = {}
nextId = 70
module = {}
ON = {RENDER_PRE_JOURNAL_PAGE = 145}
function set_callback(fn, kind)
    nextId = nextId + 1
    registered[#registered + 1] = {fn = fn, kind = kind, id = nextId}
    return nextId
end
function clear_callback(id) cleared[#cleared + 1] = id end
function SafeCall(_n, fn, ...) local ok, r = pcall(fn, ...); if ok then return r end end
function journalShouldBeHidden() return hiddenValue end
Network = {isActive = function() return activeValue end}
function liveHooks()
    local n = 0
    for _, e in ipairs(registered) do
        local gone = false
        for _, c in ipairs(cleared) do if c == e.id then gone = true end end
        if not gone then n = n + 1 end
    end
    return n
end
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(_block())
    return rt


def test_no_hook_is_installed_outside_a_session():
    """The whole bug. Offline the hook can do nothing, and its mere presence made
    the engine construct a page context for hdmod's fabricated page ids."""
    rt = runtime()
    for _ in range(5):
        rt.eval("module.pollJournalHook")()
    assert int(rt.eval("liveHooks()")) == 0, (
        "a journal render hook was installed with no session running")


def test_the_hook_goes_in_when_a_session_starts():
    rt = runtime()
    rt.globals()["activeValue"] = True
    rt.eval("module.pollJournalHook")()
    assert int(rt.eval("liveHooks()")) == 1
    assert int(rt.eval("registered[1].kind")) == 145


def test_it_is_installed_once_not_once_per_frame():
    """pollJournalHook runs every GUI frame."""
    rt = runtime()
    rt.globals()["activeValue"] = True
    for _ in range(200):
        rt.eval("module.pollJournalHook")()
    assert int(rt.eval("#registered")) == 1


def test_the_hook_comes_out_when_the_session_ends():
    rt = runtime()
    rt.globals()["activeValue"] = True
    rt.eval("module.pollJournalHook")()
    rt.globals()["activeValue"] = False
    rt.eval("module.pollJournalHook")()
    assert int(rt.eval("liveHooks()")) == 0, "the hook outlived the session"
    assert int(rt.eval("#cleared")) == 1


def test_it_can_be_reinstalled_for_a_second_session():
    rt = runtime()
    for _ in range(2):
        rt.globals()["activeValue"] = True
        rt.eval("module.pollJournalHook")()
        rt.globals()["activeValue"] = False
        rt.eval("module.pollJournalHook")()
    assert int(rt.eval("#registered")) == 2
    assert int(rt.eval("liveHooks()")) == 0


def test_a_build_without_the_hook_degrades_quietly():
    rt = runtime()
    rt.execute("ON.RENDER_PRE_JOURNAL_PAGE = nil; activeValue = true")
    rt.eval("module.pollJournalHook")()
    assert int(rt.eval("#registered")) == 0


def test_the_hook_skips_the_page_only_when_it_should_be_hidden():
    """Never return the SafeCall result raw: its error path yields an explicit nil,
    which Playlunky rejects as "Unexpected return type from function"."""
    rt = runtime()
    rt.globals()["hiddenValue"] = True
    assert rt.eval("module.journalPreRender")() is True
    rt.globals()["hiddenValue"] = False
    assert rt.eval("module.journalPreRender")() is None


def test_the_poll_is_wired_into_the_gui_frame():
    assert 'SafeCall("eventSync:pollJournalHook", module.pollJournalHook)' in EVENT_SYNC


def test_the_hook_is_not_registered_at_module_load():
    """The registration used to sit at the bottom of the file, unconditional, for the
    whole run of the game. Nothing may put it back."""
    tail = EVENT_SYNC[EVENT_SYNC.index("function module.pollJournalHook"):]
    tail = tail[tail.index(NL + "end" + NL):]
    assert "ON.RENDER_PRE_JOURNAL_PAGE)" not in tail, (
        "the journal hook is registered somewhere outside pollJournalHook again")
