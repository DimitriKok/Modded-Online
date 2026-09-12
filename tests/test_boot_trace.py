"""The boot trace must survive the crash it exists to describe.

The failure it is for: the game dies during boot with no Lua error and nothing in
spelunky.log. A player on the far end of that cannot tell whether the crash was in our
code, in a hosted mod, or in Playlunky before either of us ran -- and every round of
guessing costs them a launch.

These are structural checks on main.lua, because the trace runs before any module
exists and cannot be exercised in isolation.

Run:  python -m pytest tests/test_boot_trace.py -q
"""

from __future__ import annotations

import pathlib
import re

PACK = pathlib.Path(__file__).resolve().parent.parent
MAIN = (PACK / "main.lua").read_text(encoding="utf-8")
STEPS = re.findall(r'bootStep\((.*)', MAIN)


def test_the_previous_boot_is_read_before_this_one_truncates_it():
    """Opening for write first would erase the only record of what went wrong."""
    read_at = MAIN.index('io.open(BOOT_LOG, "r")')
    write_at = MAIN.index('io.open(BOOT_LOG, "w")')
    assert read_at < write_at, "the trace file is truncated before it is read"


def test_every_step_is_flushed():
    """A crash takes the buffer with it, so a buffered trace records nothing at all."""
    assert "handle:flush()" in MAIN


def test_the_trace_opens_before_the_first_module():
    """`src.util` is where PackDir lives; a trace that needed it could not report a
    failure to load it."""
    assert MAIN.index("local BOOT_LOG") < MAIN.index('require("src.util")')


def test_the_trace_never_breaks_the_boot_it_reports_on():
    """`io` is absent unless Playlunky granted unsafe mode."""
    opening = MAIN[MAIN.index("local BOOT_LOG"):MAIN.index('require("src.util")')]
    for call in re.findall(r"io\.open\(", opening):
        pass
    assert opening.count("pcall(") >= 3, "the trace setup is not fully guarded"
    assert "if handle == nil then" in MAIN, "writing to a nil handle would throw"


def test_each_phase_of_the_boot_is_named():
    joined = " ".join(STEPS)
    for phase in ("require src.util", "require ", "all modules loaded",
                  "setupUI", "hosting ", "READY"):
        assert phase in joined, f"the boot trace never names {phase!r}"


def test_hosted_packs_are_named_one_at_a_time():
    """Hosting runs someone else's code; if that is what dies, the last line of the
    trace has to say whose."""
    assert any("hosting " in step and "packDir" in step for step in STEPS), STEPS


def test_ready_is_the_last_thing_written():
    """Everything hangs off this: a file not ending in READY is an unfinished boot."""
    assert "READY" in STEPS[-1], STEPS[-1]
    assert MAIN.index('bootStep("READY")') > MAIN.index("ModHost.requestedPacks()")


def test_a_missing_module_does_not_take_the_boot_down_with_it():
    """Indexing a module that failed to load would kill the boot while reporting a
    boot problem, and blame the wrong line."""
    for name in ("SetupUI", "ModHost"):
        assert f"if {name} == nil then" in MAIN or f"if {name} ~= nil then" in MAIN, \
            f"{name} is indexed at load without a guard"
