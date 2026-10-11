"""Finding Python on Windows, and under Proton (Spelunky 2 on Linux).

The server, the client bridge and the test players are Python scripts, and the mod
looks for an interpreter with `where`, the way Windows finds a command. Under Proton
the game is a Windows program inside a Wine prefix. It cannot see Linux's python3,
and up to Proton 9 Wine's `where` is a stub that prints nothing (Wine implements it
from 10.0), so even a Windows Python installed inside the prefix read as "not
installed". The mod now also looks where a Windows install puts the interpreter,
and says what to do in Proton's terms when there is none.

Run:  python -m pytest tests/test_python_detect.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent

ENV = """
meta = { version = "1.0.5" }
ON = { GUIFRAME = 1 }
function set_callback() end
function dbg() end
function dbgf() end
said, toasts, ran = {}, {}, {}
function errorf(fmt, ...) said[#said + 1] = string.format(fmt, ...) end
function SafeCall(_, fn, ...) return fn(...) end
function get_ms() return 0 end
function toast(text) toasts[#toasts + 1] = text end
function PackDir() return "fyi.modded-online" end
function PackPath(rest) return "Mods/Packs/fyi.modded-online/" .. rest end
function PackPathWin(rest) return (PackPath(rest):gsub("/", "\\\\")) end
function PackRootPath() return "Mods/Packs/fyi.modded-online" end
"""

# The machine: what `where <cmd>` prints, which files exist, and the environment.
MACHINE = """
local realOpen = io.open
whereSays, files, envVars, probed = {}, {}, {}, {}
versionSays, asked = {}, {}
io.popen = function(command)
    local out
    local version = command:match('^"(.+) %-V 2>&1"$')
    if version ~= nil then
        asked[#asked + 1] = version
        out = versionSays[version] or { "Python 3.13.16" }
    else
        out = whereSays[command:match("^where (%S+)")] or {}
    end
    local i = 0
    return {
        lines = function() return function() i = i + 1; return out[i] end end,
        close = function() end,
    }
end
io.open = function(path, mode)
    if type(path) == "string" and path:match("^%a:\\\\") then
        probed[#probed + 1] = path
        if files[path] then return { close = function() end } end
        return nil
    end
    return realOpen(path, mode)
end
os.getenv = function(name) return envVars[name] end
os.execute = function(command) ran[#ran + 1] = command; return true end
"""

WINDOWS = {
    "WINDIR": "C:\\Windows",
    "LOCALAPPDATA": "C:\\Users\\Ana\\AppData\\Local",
    "ProgramFiles": "C:\\Program Files",
    "ProgramFiles(x86)": "C:\\Program Files (x86)",
}

PROTON = {
    "WINDIR": "C:\\windows",
    "LOCALAPPDATA": "C:\\users\\steamuser\\AppData\\Local",
    "ProgramFiles": "C:\\Program Files",
    "WINECONFIGDIR": "\\??\\Z:\\home\\ana\\.local\\share\\Steam\\steamapps\\compatdata\\418530\\pfx",
    "WINEHOMEDIR": "\\??\\Z:\\home\\ana",
}


@pytest.fixture
def machine(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "Mods" / "Packs").mkdir(parents=True)
    (tmp_path / "Mods" / "Packs" / "load_order.txt").write_text("fyi.modded-online\n", encoding="utf-8")
    helpers = tmp_path / "Mods" / "Packs" / "fyi.modded-online" / "server"
    helpers.mkdir(parents=True)
    for script in ("client_bridge.py", "server.py", "fake_player.py"):
        (helpers / script).write_text("# stand-in\n", encoding="utf-8")
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute((PACK / "src" / "json.lua").read_text(encoding="utf-8"))
    rt.execute((PACK / "src" / "netCore.lua").read_text(encoding="utf-8"))
    rt.execute(MACHINE)

    def setup(env, where=None, present=()):
        for key, value in env.items():
            rt.eval("function(k, v) envVars[k] = v end")(key, value)
        for cmd, lines in (where or {}).items():
            rt.eval("function(c) whereSays[c] = {} end")(cmd)
            for line in lines:
                rt.eval("function(c, l) table.insert(whereSays[c], l) end")(cmd, line)
        for path in present:
            rt.eval("function(p) files[p] = true end")(path)
        return rt

    return setup


def said(rt):
    return [str(v) for v in rt.eval("said").values()]


def toasts(rt):
    return [str(v) for v in rt.eval("toasts").values()]


def ran(rt):
    return [str(v) for v in rt.eval("ran").values()]


def require(rt):
    return rt.eval("Network.requirePython")("the connection bridge")


# ------------------------------------------------------------------- Windows

def test_a_python_on_the_path_is_used_by_name_as_before(machine):
    rt = machine(WINDOWS, where={"py": ["C:\\Windows\\py.exe"]})
    assert require(rt) == "py"
    assert list(rt.eval("probed").values()) == [], "the disk was searched with `where` working"


def test_the_store_placeholder_is_still_not_python(machine):
    store = "C:\\Users\\Ana\\AppData\\Local\\Microsoft\\WindowsApps\\python.exe"
    rt = machine(WINDOWS, where={"python": [store], "python3": [store]})
    assert require(rt) is None
    assert len(said(rt)) == 1
    assert 'tick "Add python.exe to PATH"' in said(rt)[0]
    assert "Proton" not in said(rt)[0]
    assert toasts(rt) == ["Python is required to play online — opening the download page"]
    assert ran(rt) == ['start "" "https://www.python.org/downloads/"']


def test_an_install_left_off_the_path_is_found_where_it_was_installed(machine):
    path = "C:\\Users\\Ana\\AppData\\Local\\Programs\\Python\\Python313\\python.exe"
    rt = machine(WINDOWS, present=[path])
    assert require(rt) == f'"{path}"'
    assert said(rt) == [], "a found Python must not be complained about"


def test_the_newest_install_is_taken_first(machine):
    old = "C:\\Program Files\\Python311\\python.exe"
    new = "C:\\Program Files\\Python313\\python.exe"
    rt = machine(WINDOWS, present=[old, new])
    assert require(rt) == f'"{new}"'


def test_the_launcher_is_preferred_to_any_one_interpreter(machine):
    launcher = "C:\\Users\\Ana\\AppData\\Local\\Programs\\Python\\Launcher\\py.exe"
    rt = machine(WINDOWS, present=[launcher, "C:\\Program Files\\Python313\\python.exe"])
    assert require(rt) == f'"{launcher}"'


def test_it_is_worked_out_once_a_session(machine):
    rt = machine(WINDOWS, where={"py": ["C:\\Windows\\py.exe"]})
    assert require(rt) == "py"
    rt.execute("whereSays = {}")
    assert require(rt) == "py"


# -------------------------------------------------------------------- Proton

def test_proton_9_finds_a_python_installed_in_the_prefix(machine):
    """Wine's `where` up to Proton 9 prints nothing, whatever is installed."""
    rt = machine(PROTON, present=["C:\\windows\\py.exe"])
    assert require(rt) == '"C:\\windows\\py.exe"'
    assert said(rt) == []


def test_proton_10_finds_it_through_where_as_windows_does(machine):
    rt = machine(PROTON, where={"py": ["C:\\windows\\py.exe"]})
    assert require(rt) == "py"


def test_proton_with_no_windows_python_says_what_to_install_and_where(machine):
    rt = machine(PROTON)
    assert rt.eval("Network.underWine()") is True
    assert require(rt) is None
    assert len(said(rt)) == 1
    message = said(rt)[0]
    assert "Python for Windows is not installed in Spelunky 2's Proton prefix" in message
    assert "cannot use Linux's python3" in message
    assert "protontricks-launch --appid 418530" in message
    assert "Playing on Linux" in message
    assert toasts(rt) == ["Python for Windows is needed inside Proton — see README.md"]
    assert "Proton" in str(rt.eval("Network.lastError"))


def test_proton_skips_a_launcher_that_does_not_run(machine):
    """dev82's report: Python there, the bridge script there, and the bridge never ran."""
    rt = with_log(machine(PROTON, present=[
        "C:\\windows\\py.exe",
        "C:\\users\\steamuser\\AppData\\Local\\Programs\\Python\\Python313\\python.exe"]))
    rt.eval("function(c, l) versionSays[c] = { l } end")('"C:\\windows\\py.exe"', "No suitable Python runtime found")
    assert require(rt) == '"C:\\users\\steamuser\\AppData\\Local\\Programs\\Python\\Python313\\python.exe"'
    assert said(rt) == []
    assert 'did not run: "C:\\windows\\py.exe" said No suitable Python runtime found' in logged(rt)[0]


def test_proton_with_only_a_broken_python_says_what_it_said(machine):
    rt = machine(PROTON, present=["C:\\windows\\py.exe"])
    rt.eval("function(c, l) versionSays[c] = { l } end")('"C:\\windows\\py.exe"', "No suitable Python runtime found")
    assert require(rt) is None
    assert len(said(rt)) == 1
    assert "in Spelunky 2's Proton prefix, but it does not run" in said(rt)[0]
    assert "No suitable Python runtime found" in said(rt)[0]
    assert "does not run" in str(rt.eval("Network.lastError"))


def test_proton_10_checks_a_name_where_found_too(machine):
    rt = machine(PROTON, where={"py": ["C:\\windows\\py.exe"], "python": ["C:\\x\\python.exe"]})
    rt.eval("function(c, l) versionSays[c] = { l } end")("py", "Unable to create process")
    assert require(rt) == "python"


def test_windows_never_runs_anything_to_look(machine):
    """A Store placeholder opens the Microsoft Store when it is run."""
    rt = machine(WINDOWS, where={"py": ["C:\\Windows\\py.exe"]},
                 present=["C:\\Program Files\\Python313\\python.exe"])
    require(rt)
    rt2 = machine(WINDOWS)
    require(rt2)
    assert list(rt.eval("asked").values()) == [] and list(rt2.eval("asked").values()) == []


def test_windows_is_not_taken_for_wine(machine):
    rt = machine(WINDOWS)
    assert rt.eval("Network.underWine()") is False


# ------------------------------------------------------------------ the log

def logged(rt):
    return [str(v) for v in rt.eval("logged").values()]


def with_log(rt):
    rt.execute("""
        logged = {}
        DesyncLog = { earlyEvent = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end }
    """)
    return rt


def test_the_log_says_which_python_and_how_it_was_found(machine):
    rt = with_log(machine(PROTON, present=["C:\\windows\\py.exe"]))
    require(rt)
    assert logged(rt) == [
        'python: "C:\\windows\\py.exe" (found where it was installed, Python 3.13.16)'
        " | under Wine (Proton)"]


def test_the_log_says_when_there_is_none(machine):
    rt = with_log(machine(WINDOWS))
    require(rt)
    require(rt)
    assert logged(rt) == ["python: none found"], "said more than once a session"


def test_the_log_names_a_python_found_by_where(machine):
    rt = with_log(machine(WINDOWS, where={"py": ["C:\\Windows\\py.exe"]}))
    require(rt)
    assert logged(rt) == ["python: py (found by where)"]


# ------------------------------------------------------------ the launch itself

def test_a_found_path_is_launched_quoted(machine):
    """`start` takes the first quoted argument as the window title, so the title has to
    come first and the interpreter's path, which can hold spaces, after it."""
    path = "C:\\Program Files\\Python313\\python.exe"
    rt = machine(WINDOWS, present=[path])
    assert rt.eval("Network.launchBridge")("203.0.113.7", 26000) is True
    launch = [c for c in ran(rt) if c.startswith("start ")]
    assert launch == [
        f'start "Modded Online Bridge" /min "{path}" '
        '"Mods\\Packs\\fyi.modded-online\\server\\client_bridge.py" "203.0.113.7" 26000'
    ], launch
