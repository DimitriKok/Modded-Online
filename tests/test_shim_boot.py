"""Runs every determinism-shim payload the way Playlunky does, and checks what it
hands the host.

This exists because of a real regression. v25 registered its world-capture callback
forty lines ABOVE the `local function` that defines it, so the name resolved as a
global, `set_callback` was handed `nil`, and Playlunky accepted it — then raised

    Mod: fyi.spelunky-25-2
    Error: attempt to call a nil value
    stack traceback:                      <- empty: the call comes from the host

the first time that callback fired, on boot. Nothing in the pack's own test suite
noticed, because a nil callback is perfectly valid Lua. Worse, the failure was
silent in the direction that mattered: the capture never ran, so the world reset
built on top of it could never fire, and the desync it was written for stayed.

The payload is executed here in a stub environment that deliberately has NO
catch-all `__index`. That is the whole point: a name that has fallen out of scope
must come back nil, exactly as it does in the game, instead of being papered over.

Run:  python -m pytest tests/test_shim_boot.py -q
"""

from __future__ import annotations

import pathlib
import re

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
INJECTOR = (PACK / "src" / "shimInjector.lua").read_text(encoding="utf-8")

# Everything the game gives a pack, and nothing else.
ENGINE = """
registered = {}
intervals = {}
local ids = 0
local function enum()
    return setmetatable({}, {__index = function(t, k)
        ids = ids + 1; t[k] = ids; return ids
    end})
end
ON, SCREEN, THEME, PRNG_CLASS, LAYER, ENT_TYPE, QUEST_FLAG = enum(), enum(), enum(), enum(), enum(), enum(), enum()
CONST, DROP, ENT_FLAG, MASK, RECURSIVE_MODE, SPAWN_TYPE, VANILLA_SOUND = enum(), enum(), enum(), enum(), enum(), enum(), enum()

function set_callback(fn, cb)
    registered[#registered + 1] = {fn = fn, cb = cb, kind = type(fn)}
    return #registered
end
function set_global_interval(fn, n)
    intervals[#intervals + 1] = {fn = fn, kind = type(fn)}
    return #intervals
end
function clear_callback() end
function clear_vanilla_sound_callback() end

function get_local_state()
    return {
        world = 1, level = 1, theme = 1, level_count = 0, screen = 12,
        screen_next = 12, world_next = 1, level_next = 1, theme_next = 1,
        quest_flags = 0, time_total = 0, time_level = 0, loading = 0,
        liquid = nil, level_gen = {themes = {}},
        -- the four arena-scratch bytes the world mailbox rides on
        arena = {player_lives = {0, 0, 0, 0}},
    }
end
state = get_local_state()
function get_state() return state end
function get_adventure_seed() return 0x1EAF9223, 0xCA8F7F71 end
function set_adventure_seed() end
function seed_prng() end
function get_frame() return 0 end
function get_ms() return 0 end
function get_players() return {} end
function get_entities_by() return {} end
function get_entity() return nil end
function get_setting() return nil end
function read_prng() return {} end
function liquid_get_settings() return {} end
function liquid_set_settings() end
function get_liquids() return {} end
function test_flag() return false end
function set_flag(f) return f end
function clr_flag(f) return f end
function message() end
function toast() end
prng = {
    random = function() return 0.5 end,
    random_int = function() return 1 end,
    random_chance = function() return false end,
    get_pair = function() return 1, 2 end,
    set_pair = function() end,
}
players = {}
"""


def payloads() -> list[tuple[str, str]]:
    """(label, source) for the live payload and every archived one."""
    out = []
    archived = sorted(
        (int(v) for v in re.findall(r"^local SHIM_V(\d+) = ", INJECTOR, re.M)),
        reverse=True,
    )
    for var, marker in [("SHIM", "MARKER")] + [
        (f"SHIM_V{v}", f"MARKER_V{v}") for v in archived
    ]:
        m = re.search(
            r'local %s = "-- " \.\. %s \.\. \[\[(.*?)\n\]\]\n' % (var, marker),
            INJECTOR, re.S,
        )
        if m is None:
            continue  # v1 predates this declaration shape
        mk = re.search(r'local %s = "(\[[^"]+\])"' % marker, INJECTOR).group(1)
        out.append((mk, "-- " + mk + m.group(1)))
    return out


ALL = payloads()
LIVE = ALL[0]

# v24 and v25 shipped with the bug. They are archived VERBATIM on purpose — the
# injector strips an old block by exact text, so "fixing" an archive would leave the
# broken copy sitting in every installed pack forever. They are pinned below instead.
BROKEN = ("[ModdedOnline-DeterminismShim-v24]", "[ModdedOnline-DeterminismShim-v25]")
SOUND = [(m, s) for m, s in ALL if m not in BROKEN]


def run(source: str):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(source)
    return rt


def registrations(rt) -> list[tuple[str, object]]:
    out = []
    for tbl in (rt.eval("registered"), rt.eval("intervals")):
        for entry in (tbl.values() if tbl else []):
            out.append((entry["kind"], entry["cb"] if "cb" in entry else None))
    return out


def test_the_live_payload_loads_the_way_playlunky_loads_it():
    rt = run(LIVE[1])
    assert len(registrations(rt)) > 0, "the payload registered nothing at all"


@pytest.mark.parametrize("marker,source", SOUND, ids=[m for m, _ in SOUND])
def test_no_payload_hands_the_host_a_nil_callback(marker, source):
    """The v25 boot error, pinned for the live payload and every sound archive."""
    rt = run(source)
    nils = [cb for kind, cb in registrations(rt) if kind != "function"]
    assert not nils, (
        f"{marker} registers {len(nils)} callback(s) that are not functions - "
        "Playlunky accepts this and then raises 'attempt to call a nil value' "
        "with an empty traceback when it fires"
    )


@pytest.mark.parametrize("marker", BROKEN)
def test_the_two_broken_versions_are_kept_exactly_as_they_shipped(marker):
    """Archives are evidence, not code: they must still reproduce the fault."""
    source = dict(ALL)[marker]
    rt = run(source)
    nils = [cb for kind, cb in registrations(rt) if kind != "function"]
    assert len(nils) == 2, (
        f"{marker} no longer reproduces the nil-callback bug it shipped with - "
        "if it was edited, the copy in an installed pack will never be stripped"
    )

def test_every_registration_names_a_callback_declared_above_it():
    """The static form of the same rule, so a failure points at the line."""
    lines = LIVE[1].split(chr(10))
    declared: dict[str, int] = {}
    for n, line in enumerate(lines, 1):
        m = re.match("^ *local (?:function )?(mo[A-Za-z0-9_]+)", line)
        if m and m.group(1) not in declared:
            declared[m.group(1)] = n
    late = []
    for n, line in enumerate(lines, 1):
        for m in re.finditer("(?:moRealSetCallback|set_global_interval)[(](mo[A-Za-z0-9_]+),", line):
            at = declared.get(m.group(1))
            if at is None or at > n:
                late.append((m.group(1), n, at))
    assert not late, f"registered before being declared: {late}"


def test_the_world_capture_is_actually_installed_now():
    """The regression in one line: v25 shipped with this hook never installed."""
    rt = run(LIVE[1])
    kinds = [kind for kind, _ in registrations(rt)]
    assert kinds and all(k == "function" for k in kinds)
    assert LIVE[1].count("moRealSetCallback(moHookWorldCapture,") == 2
