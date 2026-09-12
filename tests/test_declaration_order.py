"""Catches a local being used above the line that declares it.

This has now shipped twice, in different files, from the same hand:

  * determinism shim v25 registered `moHookWorldCapture` forty lines above its own
    `local function`. The name resolved as a global, Playlunky was handed `nil`,
    and it raised "attempt to call a nil value" — with an empty traceback, because
    the call came from the host. The capture never ran, so the world reset built on
    top of it silently did nothing.
  * `measureName` and `readCameraLayer` were defined below `guiTick` and called
    inside it. `measureName` threw on every frame a remote player was on screen, and
    `readCameraLayer` failed *silently* inside its own pcall, so name tags stopped
    being filtered by camera layer and nobody could tell.

Lua does not warn. The name is simply a global lookup, and a global lookup that
finds nothing is `nil` — which is a perfectly ordinary value right up until it is
called. Both bugs reached a real machine.

Forward declaration is the legitimate way to do this and is not flagged:

    local helper            -- declared here
    ...
    function helper() end   -- defined later, assigned to the local

Run:  python -m pytest tests/test_declaration_order.py -q
"""

from __future__ import annotations

import pathlib
import re

import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
LUA_FILES = sorted((PACK / "src").glob("*.lua")) + [PACK / "main.lua"]

DECL = re.compile(r"^(\s*)local function ([A-Za-z_][A-Za-z0-9_]*)\s*\(")
FORWARD = re.compile(r"^\s*local ([A-Za-z_][A-Za-z0-9_]*)\s*(?:--.*)?$")
FORWARD_LIST = re.compile(r"^\s*local ([A-Za-z_][A-Za-z0-9_,\s]*?)\s*(?:=|--|$)")


def offenders(source: str) -> list[tuple[str, int, int]]:
    """(name, line it is used on, line it is declared on) for each use-before-decl."""
    lines = source.split(chr(10))

    declared: dict[str, int] = {}
    forward: set[str] = set()
    for n, line in enumerate(lines, 1):
        m = DECL.match(line)
        if m and m.group(2) not in declared:
            declared[m.group(2)] = n
        f = FORWARD.match(line)
        if f:
            forward.add(f.group(1))
        fl = FORWARD_LIST.match(line)
        if fl and "=" not in line:
            for part in fl.group(1).split(","):
                part = part.strip()
                if part:
                    forward.add(part)

    found = []
    for name, decl_line in declared.items():
        if name in forward:
            continue  # forward-declared on purpose
        call = re.compile(r"(?<![A-Za-z0-9_.:])" + re.escape(name) + r"\s*[(,)]")
        for n, line in enumerate(lines[: decl_line - 1], 1):
            if line.lstrip().startswith("--"):
                continue
            hit = call.search(line)
            if hit is None:
                continue
            # A trailing comment is not a use. eventSync declares a forward with
            # `-- fwd: defined after onScreenChange, called by it` on the same line,
            # and the name inside that sentence is not code.
            comment_at = line.find("--")
            if comment_at != -1 and hit.start() > comment_at:
                continue
            found.append((name, n, decl_line))
            break
    return found


def code_of(path: pathlib.Path) -> str:
    """The file's own code, plus the LIVE shim payload but not the archived ones.

    `shimInjector.lua` keeps every previous payload verbatim so an old block can be
    stripped from an installed pack by exact text. Two of those archives contain the
    v25 bug this checker exists to find, and they must keep containing it — editing
    one would leave the broken copy in a player's mod folder forever. The live
    payload is checked, and it is exactly where the bug would matter next.
    """
    source = path.read_text(encoding="utf-8")
    archive = (r'local SHIM_V\d+ = "-- " \.\. MARKER_V\d+ \.\. \[\[.*?'
               + chr(10) + r'\]\]' + chr(10))
    return re.sub(archive, "", source, flags=re.S)


@pytest.mark.parametrize("path", LUA_FILES, ids=[p.name for p in LUA_FILES])
def test_no_local_is_used_above_its_own_declaration(path):
    bad = offenders(code_of(path))
    assert not bad, chr(10).join(
        f"{path.name}: '{name}' used on line {used} but declared on line {decl}"
        for name, used, decl in bad
    )


def test_the_checker_actually_catches_the_two_bugs_that_shipped():
    """A checker nobody has seen fail is a checker nobody should trust."""
    measure_name = chr(10).join([
        "local function guiTick(ctx)",
        "    local width = measureName(ctx, name)",
        "end",
        "local function measureName(ctx, name)",
        "    return 0",
        "end",
    ])
    found = offenders(measure_name)
    assert [(n, u, d) for n, u, d in found] == [("measureName", 2, 4)]

    shim = chr(10).join([
        "    moRealSetCallback(moHookWorldCapture, ON.LOADING)",
        "    local function moHookWorldCapture()",
        "    end",
    ])
    assert [n for n, _, _ in offenders(shim)] == ["moHookWorldCapture"]


def test_a_forward_declaration_is_not_flagged():
    """The legitimate pattern, used by the shim's own mailbox sync."""
    source = chr(10).join([
        "local moSyncWorldMailbox -- defined below; the capture wrapper calls it",
        "local function wrapper()",
        "    moSyncWorldMailbox()",
        "end",
        "function moSyncWorldMailbox()",
        "end",
    ])
    assert offenders(source) == []


def test_a_normal_call_after_the_declaration_is_not_flagged():
    source = chr(10).join([
        "local function helper()",
        "    return 1",
        "end",
        "local function caller()",
        "    return helper()",
        "end",
    ])
    assert offenders(source) == []


def test_a_mention_in_a_comment_is_not_a_use():
    source = chr(10).join([
        "-- helper(x) is defined below and called from caller()",
        "local function helper()",
        "end",
    ])
    assert offenders(source) == []
