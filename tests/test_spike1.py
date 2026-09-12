"""Tests the two things Spike 1's harness has to get right, both of which it got
wrong first.

A measurement tool that is quietly wrong is worse than no tool, because its output
looks like a finding. The first run of `tools/spike1.py` reported eight globals the
host had supposedly failed to provide. Three of them were real engine names the stub
extractor had skipped, and one — `is_liquid_at` — was not 2.5 asking at all: it was
Modded Online's own determinism payload, which is prepended to the very `main.lua`
the tool was reading.

Run:  python -m pytest tests/test_spike1.py -q
"""

from __future__ import annotations

import importlib.util
import pathlib

PACK = pathlib.Path(__file__).resolve().parent.parent


def load_tool():
    spec = importlib.util.spec_from_file_location("spike1", PACK / "tools" / "spike1.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


spike1 = load_tool()


# ------------------------------------------------------------- the API extractor

def test_it_reads_mixed_case_engine_globals(tmp_path):
    """`Color = {}` is declared exactly like `ON = {}` but was excluded by a regex
    that demanded an ALL-CAPS name, so Color showed up as a missing global."""
    pack = tmp_path / "pack"
    (pack / "src" / "apiFiles").mkdir(parents=True)
    (pack / "src" / "apiFiles" / "spel2-part1.lua").write_text(
        "ON = {}\n"
        "Color = {} --- @type Color\n"
        "function spawn_entity(a, b) end\n"
        "    --- @class TextureDefinition\n",
        encoding="utf-8")
    functions, tables = spike1.api_names(pack)
    assert "spawn_entity" in functions
    assert {"ON", "Color"} <= tables
    assert "TextureDefinition" in tables, "annotation-only classes are engine names too"


def test_a_missing_definition_file_is_not_fatal(tmp_path):
    pack = tmp_path / "pack"
    (pack / "src" / "apiFiles").mkdir(parents=True)
    assert spike1.api_names(pack) == (set(), set())


# ------------------------------------------------------ hosting the mod, not ours

