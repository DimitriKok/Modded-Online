"""SETTINGS > ENABLE DEBUG MESSAGES: the print() lines at the top left of the screen.

Overlunky draws every print() at the top left. Ours are diagnostics (setup reports,
hosting summaries, error traces), and a hosted mod's own debug prints come the same
way, because it runs in our Lua state. main.lua gates all five on-screen printers
(print, message, printf, prinspect, messpect) behind `Network.config.debugMessages`,
off by default, or MO_DEBUG from the console.

The setting is unknown until netCore has read config.json, so lines printed before
then are held, and shown or dropped once it is known. One message is never gated: a
second enabled copy of Modded Online, which nothing else survives.

These run the gate extracted verbatim from main.lua against recording printers.

Run:  python -m pytest tests/test_debug_messages.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
MAIN = (PACK / "main.lua").read_text(encoding="utf-8").replace("\r\n", "\n")


def gate_block() -> str:
    start = "local alwaysPrint = print\n"
    end = "-- ------------------------------------------------------------------ boot trace"
    assert start in MAIN and end in MAIN
    return MAIN[MAIN.index(start):MAIN.index(end)] + "\nALWAYS = alwaysPrint\n"


ENV = """
shown = {}
local function recorder(name)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        shown[#shown + 1] = name .. ": " .. table.concat(parts, " ")
    end
end
print = recorder("print")
message = recorder("message")
printf = recorder("printf")
prinspect = recorder("prinspect")
messpect = recorder("messpect")
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(gate_block())
    return rt


def shown(rt):
    return [str(v) for v in rt.eval("shown").values()]


def set_config(rt, debug):
    rt.execute("Network = { config = { debugMessages = %s } }" % ("true" if debug else "false"))


def test_off_shows_nothing():
    rt = runtime()
    set_config(rt, False)
    rt.execute('print("[ModdedOnline] hosting fyi.hdmod")')
    rt.execute('message("APPLIED IDOL OWNER 5")')
    assert shown(rt) == []


def test_on_shows_everything():
    rt = runtime()
    set_config(rt, True)
    rt.execute('print("a")')
    rt.execute('message("b")')
    rt.execute('printf("c")')
    rt.execute('prinspect("d")')
    rt.execute('messpect("e")')
    assert shown(rt) == ["print: a", "message: b", "printf: c", "prinspect: d", "messpect: e"]


def test_the_switch_is_read_live():
    rt = runtime()
    set_config(rt, False)
    rt.execute('print("hidden")')
    rt.execute("Network.config.debugMessages = true")
    rt.execute('print("shown")')
    rt.execute("Network.config.debugMessages = false")
    rt.execute('print("hidden again")')
    assert shown(rt) == ["print: shown"]


def test_mo_debug_shows_them_whatever_the_setting():
    rt = runtime()
    set_config(rt, False)
    rt.execute("MO_DEBUG = true")
    rt.execute('print("verbose")')
    assert shown(rt) == ["print: verbose"]


def test_lines_before_the_setting_is_known_are_held_then_shown():
    rt = runtime()
    rt.execute('print("[ModdedOnline] THE PREVIOUS BOOT DID NOT FINISH")')
    assert shown(rt) == [], "printed before the setting could be read"
    set_config(rt, True)
    rt.execute("FlushHeldMessages()")
    assert shown(rt) == ["print: [ModdedOnline] THE PREVIOUS BOOT DID NOT FINISH"]


def test_lines_before_the_setting_is_known_are_dropped_when_it_is_off():
    rt = runtime()
    rt.execute('print("early")')
    set_config(rt, False)
    rt.execute("FlushHeldMessages()")
    rt.execute('print("later")')
    assert shown(rt) == []


def test_held_lines_come_out_in_order_before_the_next_one():
    """No explicit flush: the next print after the setting is known releases them."""
    rt = runtime()
    rt.execute('print("one")')
    rt.execute('message("two")')
    set_config(rt, True)
    rt.execute('print("three")')
    assert shown(rt) == ["print: one", "message: two", "print: three"]


def test_a_boot_where_netcore_never_loaded_shows_what_was_held():
    """Something is badly broken; hiding the lines that say what would be worse."""
    rt = runtime()
    rt.execute('print("[ModdedOnline ERROR] main/require src.netCore failed")')
    rt.execute("FlushHeldMessages()")
    assert shown(rt) == ["print: [ModdedOnline ERROR] main/require src.netCore failed"]


def test_only_so_many_lines_are_held():
    rt = runtime()
    rt.execute('for i = 1, 500 do print("line " .. i) end')
    set_config(rt, True)
    rt.execute("FlushHeldMessages()")
    assert len(shown(rt)) == 64


def test_a_hosted_mods_prints_go_through_it_too():
    """A hosted mod runs in our Lua state: its `print` resolves to ours."""
    rt = runtime()
    set_config(rt, False)
    rt.execute("""
local env = setmetatable({}, { __index = function(_, k) return rawget(_G, k) end })
load('print("hdmod debug"); message("APPLIED IDOL OWNER 5")', "=mod", "t", env)()
""")
    assert shown(rt) == []
    rt.execute("Network.config.debugMessages = true")
    rt.execute("""
local env = setmetatable({}, { __index = function(_, k) return rawget(_G, k) end })
load('print("hdmod debug")', "=mod", "t", env)()
""")
    assert shown(rt) == ["print: hdmod debug"]


def test_always_print_is_the_engines_own():
    rt = runtime()
    set_config(rt, False)
    rt.execute('ALWAYS("[ModdedOnline] a second copy is enabled")')
    assert shown(rt) == ["print: [ModdedOnline] a second copy is enabled"]


def test_the_second_copy_warning_always_shows():
    at = MAIN.index("is ALSO enabled. Two copies")
    assert "pcall(alwaysPrint, " in MAIN[at - 120:at]


def test_the_gate_is_installed_before_anything_can_print():
    first_print = min(i for i in (MAIN.find("pcall(print,"), MAIN.find("print(\"")) if i != -1)
    assert MAIN.index("local alwaysPrint = print") < first_print
    assert MAIN.index("local alwaysPrint = print") < MAIN.index('require("src.util")')


def test_the_held_lines_are_released_once_the_modules_are_loaded():
    loaded = MAIN.index('bootStep("all modules loaded")')
    assert MAIN.index("FlushHeldMessages()", loaded) < MAIN.index("SetupUI.install", loaded)
