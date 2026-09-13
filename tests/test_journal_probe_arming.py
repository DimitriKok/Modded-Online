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
