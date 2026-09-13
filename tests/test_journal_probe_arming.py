"""The journal probe must arm on its own flag, not only on the per-frame tracer.

`mo_nojournalpages.on` is the documented workaround for the crash in HANDOFF.md #2:
opening hdmod's journal while hosted kills the game natively, and clamping the page
list stops it. The override lives INSIDE the callback `installJournalProbe`
registers -- and that registration was gated on `DesyncLog.tracing()` alone. So a
player who created the one flag they were told to create got nothing: no callback, no
override, same crash, and no way to tell that from "the workaround does not work".
It needed a second, undocumented flag (`mo_trace.on`) that writes a file every frame.

The same gate is why the measurement HANDOFF.md calls the missing one -- what page
count the engine offers standalone -- has never been taken: it cost per-frame
tracing. `mo_journalprobe.on` arms the logging half on its own, and the line now goes
to the desync log as well as the trace.

Run:  python -m pytest tests/test_journal_probe_arming.py -q
"""

from __future__ import annotations

import pathlib

PACK = pathlib.Path(__file__).resolve().parent.parent
NL = chr(10)
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")
MAIN = (PACK / "main.lua").read_text(encoding="utf-8")


def arming_block() -> str:
    at = MOD_HOST.index("function module.installJournalProbe()")
    return MOD_HOST[at:at + 2200]


def test_the_override_flag_arms_the_probe_by_itself():
    """THE BUG: mo_nojournalpages.on installed nothing without mo_trace.on."""
    block = arming_block()
    assert 'flagPresent("mo_nojournalpages.on")' in block


def test_a_log_only_flag_arms_it_without_the_per_frame_tracer():
    block = arming_block()
    assert 'flagPresent("mo_journalprobe.on")' in block


def test_the_tracer_still_arms_it():
    """Existing captures must keep working exactly as before."""
    block = arming_block()
    assert "DesyncLog.tracing()" in block


def test_no_flag_and_no_tracer_still_installs_nothing():
    """The probe registers a POST_LOAD_JOURNAL_CHAPTER callback. Leaving that on for
    everyone changes the very code path the crash lives in, so it stays opt-in."""
    block = arming_block()
    assert "if not (tracing or override or probe)" in block
    assert "return false" in block


def test_the_measurement_reaches_the_desync_log_not_only_the_trace():
    """traceNote writes nothing unless the per-frame tracer is armed. That is why the
    page-count measurement was only ever obtainable at the cost of a file write every
    frame -- and so was never taken."""
    at = MOD_HOST.index("journal chapter %s | engine pages in")
    body = MOD_HOST[at - 600:at + 1600]
    assert "DesyncLog.earlyEvent" in body


def test_the_override_says_so_in_the_desync_log_too():
    at = MOD_HOST.index("OVERRIDING the page list")
    body = MOD_HOST[at - 400:at + 700]
    assert "DesyncLog.earlyEvent" in body


def test_the_boot_line_names_every_flag_that_arms_it():
    """The boot step said "mo_trace.on only", which was the misleading half of this."""
    at = MAIN.index("installJournalProbe")
    body = MAIN[at - 700:at + 300]
    assert "mo_journalprobe.on" in body
    assert "mo_nojournalpages.on" in body
    assert "mo_trace.on only" not in body


# ------------------------------- surviving a crash that happens outside a run


def test_the_measurement_has_a_sink_that_survives_a_crash_outside_a_run():
    """THE REASON TWO CAPTURES CAME BACK EMPTY. `DesyncLog.init` runs from
    `InputSync.beginSession`, i.e. only when a networked RUN starts. This crash
    happens in the lobby camp, before any run -- so `DesyncLog.line` drops
    everything (logPath is nil) and `earlyEvent` buffers for a run header that never
    arrives. Both sinks are empty by construction, and the stale desync log sitting
    in the pack folder reads exactly like a real capture."""
    assert "local function journalNote(" in MOD_HOST
    at = MOD_HOST.index("local function journalNote(")
    body = MOD_HOST[at:at + 1200]
    assert 'io.open(PackPath("mo_journal.txt"), "a")' in body
    assert "h:close()" in body, "an unflushed buffer dies with the process"
    assert "pcall(print," in body, "spelunky.log is the second, independent sink"


def test_the_sink_is_bounded():
    at = MOD_HOST.index("local function journalNote(")
    body = MOD_HOST[at - 300:at + 600]
    assert "JOURNAL_NOTES_MAX" in body


def test_arming_itself_is_recorded():
    """An empty file must not mean both "never armed" and "armed, never opened"."""
    assert "journal probe armed: trace=%s override=%s probe=%s" in MOD_HOST


def render_probe() -> str:
    """The RENDER_PRE_JOURNAL_PAGE block. Located by its callback rather than by a
    byte offset -- the offsets in these tests broke the moment the block grew."""
    at = MOD_HOST.index("if ON.RENDER_PRE_JOURNAL_PAGE ~= nil then")
    return MOD_HOST[at:MOD_HOST.index("ON.RENDER_PRE_JOURNAL_PAGE)", at)]


def test_the_page_render_probe_writes_there_too():
    """Whether any page render was attempted is the fact that separates engine page
    SETUP from the first page DRAW, and it has to leave a dying process."""
    assert "journalNote(" in render_probe()


def test_the_stale_desync_logs_are_not_shipped_in_git():
    """They are in .gitignore AND were tracked anyway -- which .gitignore does not
    undo -- so every clone shipped somebody else's old capture into the pack folder,
    where it reads as a real one. That cost two rounds of this exact bug."""
    import subprocess
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                         cwd=str(PACK)).stdout.split(chr(10))
    assert "desync_log.txt" not in out
    assert "desync_log.prev.txt" not in out


# ------------------------------------- what the first real capture left unanswered


def test_an_unreadable_journal_field_says_why():
    """The first real capture read `journal_ui state=? page_shown=?`. A "?" says the
    read failed and not what it failed on, which is a diagnostic that cannot itself
    be debugged: "no such field on this build" and "journal_ui is nil at this point
    in the load" are different findings and both printed "?"."""
    at = MOD_HOST.index("local function journalField(field)")
    body = MOD_HOST[at:MOD_HOST.index(NL + "end", at)]
    assert 'return "ERR(" .. msg' in body


def test_max_page_count_is_read():
    """The leading hypothesis for the mechanism. The engine offers 8 pages, hdmod
    returns 20, and returning 8 with the mod's own ids does not crash -- so the
    GROWTH is fatal and something downstream is sized for the incoming count.
    max_page_count is the one writable JournalUI field that could be that size, and
    HANDOFF.md has flagged it unread for two sessions."""
    assert 'journalField("max_page_count")' in MOD_HOST
    assert "max_page_count=%s" in MOD_HOST


# ------------------------------------ what the second real capture forced (dev59)


def test_the_page_render_probe_collapses_repeats():
    """It fires every frame the journal is open. A capture of a NON-crashing journal
    spent all 400 lines on one identical line repeated -- about a second of
    rendering. That is useless on its own and actively harmful: a crash after that
    point would have had nowhere left to write."""
    body = render_probe()
    assert "lastRenderShape" in body
    assert "more identical page renders" in body


def test_max_page_count_is_read_where_journal_ui_actually_exists():
    """Every journal_ui field came back "attempt to index a nil value" at
    POST_LOAD_JOURNAL_CHAPTER -- the UI does not exist yet at chapter-load time. At
    render time it demonstrably does, because it is drawing."""
    assert 'journalField("max_page_count")' in render_probe()


def test_an_empty_override_flag_picks_the_useful_mode_not_the_control():
    """A player creating the flag to stop a crash got `restore` -- the engine's own
    list, which is the non-crashing CONTROL for an experiment. The crash stopped and
    the journal silently showed VANILLA pages instead of the mod's."""
    assert 'local mode = "sameids"' in MOD_HOST
    assert 'local mode = "restore"' not in MOD_HOST


def test_a_failed_field_read_reports_the_message_not_the_path():
    """The first capture printed sixty characters of which fifty-two were the path to
    modHost.lua itself, leaving "attempt to"."""
    at = MOD_HOST.index("local function journalField(field)")
    body = MOD_HOST[at:MOD_HOST.index(NL + "end", at)]
    assert '%.lua:%d+:' in body, "Lua's file:line prefix has to be stripped"
