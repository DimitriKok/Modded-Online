"""The client bridge must survive a dead console, and say how far it got.

On Linux the game runs under Proton, and so does the bridge it starts. Under Wine, a
helper whose console has no window has a dead stdout: the old bridge's first print()
raised OSError [Errno 9] and it died a moment after it started, and the game said
only "Could not reach the server". The bridge now writes everything to
server/client_bridge.log as well, never dies of its console, and marks its stages;
when a connection through it never comes up, the game reads that log back and says
which stage was the last one reached.

Run:  python -m pytest tests/test_bridge_report.py -q
"""

from __future__ import annotations

import json
import pathlib
import socket
import subprocess
import sys
import time

import lupa
import pytest

import test_python_detect as detect

PACK = pathlib.Path(__file__).resolve().parent.parent
BRIDGE = PACK / "server" / "client_bridge.py"

UP = "bridge up: game(127.0.0.1:26011) <-> 129.213.14.228:26000"
CLOSES = "closes itself when you leave the session; Ctrl+C to stop early"
HEARD = "the game reached the bridge; waiting for the server at 129.213.14.228:26000"
ANSWERED = "the server answered; passing it to the game on 127.0.0.1:26010"


# ------------------------------------------------------------- the game's side

@pytest.fixture
def game(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "Mods" / "Packs" / "fyi.modded-online" / "server").mkdir(parents=True)
    (tmp_path / "Mods" / "Packs" / "fyi.modded-online" / "server" / "client_bridge.py").write_text(
        "# stand-in\n", encoding="utf-8")
    (tmp_path / "Mods" / "Packs" / "load_order.txt").write_text("fyi.modded-online\n", encoding="utf-8")
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(detect.ENV)
    rt.execute("""
        now = 0
        function get_ms() return now end
        callbacks = {}
        function set_callback(fn, event) callbacks[#callbacks + 1] = { fn = fn, event = event } end
        sent = {}
        function udp_listen() return {} end
        function udp_send(host, port, data) sent[#sent + 1] = host .. ":" .. port end
    """)
    rt.execute((PACK / "src" / "json.lua").read_text(encoding="utf-8"))
    rt.execute((PACK / "src" / "netCore.lua").read_text(encoding="utf-8"))
    rt.execute(detect.MACHINE)
    rt.eval("function(k, v) envVars[k] = v end")("WINDIR", "C:\\windows")
    rt.eval("function(p) files[p] = true end")("C:\\windows\\py.exe")
    log = tmp_path / "Mods" / "Packs" / "fyi.modded-online" / "server" / "client_bridge.log"
    return rt, log


def report(rt):
    short, detail = rt.eval("Network.bridgeReport")()
    return str(short), str(detail)


def write(log, *lines):
    log.write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_no_log_means_the_bridge_never_started(game):
    rt, _ = game
    assert report(rt)[0] == "the bridge did not start"


def test_up_but_never_heard_from_the_game(game):
    rt, log = game
    write(log, UP, CLOSES)
    assert report(rt)[0] == "the game's messages never reached the bridge"


def test_the_game_got_through_and_the_server_did_not_answer(game):
    rt, log = game
    write(log, UP, CLOSES, HEARD)
    assert report(rt)[0] == "the server did not answer"


def test_the_server_answered_and_the_game_never_heard_it(game):
    rt, log = game
    write(log, UP, CLOSES, HEARD, ANSWERED)
    assert report(rt)[0] == "the server's reply never reached the game"


def test_a_crash_names_its_error(game):
    rt, log = game
    write(log, "Traceback (most recent call last):", '  File "client_bridge.py", line 91',
          "OSError: [Errno 9] Bad file descriptor")
    short, detail = report(rt)
    assert short == "the bridge stopped (OSError: [Errno 9] Bad file descriptor)"
    assert detail == "its log ends: OSError: [Errno 9] Bad file descriptor"


def test_a_bridge_that_cannot_send_says_so(game):
    rt, log = game
    write(log, UP, CLOSES, HEARD, "  cannot reach 129.213.14.228: [WinError 10051] unreachable",
          "  (wrong address, or this PC has no route to it — for IPv6 targets this PC needs IPv6 internet)")
    short, detail = report(rt)
    assert short == "the bridge cannot send to the server"
    assert "WinError 10051" in detail


def test_the_timeout_says_why_and_logs_it(game):
    rt, log = game
    rt.execute("Network.joinOfficial('ABCD')")
    assert not log.exists(), "the last session's log was not cleared before the launch"
    assert any(c.startswith('start "Modded Online Bridge"') for c in detect.ran(rt))
    write(log, UP, CLOSES, HEARD)
    rt.execute("now = 13000")
    rt.execute("for _, c in ipairs(callbacks) do if c.event == ON.GUIFRAME then c.fn() end end")
    assert rt.eval("Network.lastError") == "Could not reach the server: the server did not answer"
    said = detect.said(rt)
    assert any("could not reach the server through the bridge: the server did not answer"
               " -- its log ends: " + HEARD in s for s in said), said


def test_a_stale_log_is_removed_before_the_bridge_starts(game):
    rt, log = game
    write(log, UP, CLOSES, HEARD, ANSWERED)
    rt.execute("Network.joinOfficial('ABCD')")
    assert not log.exists()


# ------------------------------------------------------------ the bridge itself

def free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def test_the_bridge_relays_with_its_console_gone(tmp_path):
    """stdout is a pipe nobody reads and that is closed at once: every write fails,
    as a dead Wine console's did. The old bridge died at its first print."""
    copy = tmp_path / "client_bridge.py"
    copy.write_text(BRIDGE.read_text(encoding="utf-8"), encoding="utf-8")
    server_port = free_port()
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("127.0.0.1", server_port))
    server.settimeout(0.5)
    game_in = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        game_in.bind(("127.0.0.1", 26010))
    except OSError:
        pytest.skip("port 26010 is in use on this machine")
    game_in.settimeout(0.5)
    proc = subprocess.Popen([sys.executable, str(copy), "127.0.0.1", str(server_port)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    proc.stdout.close()
    try:
        got = None
        deadline = time.time() + 15
        while got is None and time.time() < deadline and proc.poll() is None:
            out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            out.sendto(json.dumps({"t": "hello"}).encode(), ("127.0.0.1", 26011))
            out.close()
            try:
                data, src = server.recvfrom(65535)
                server.sendto(b'{"t":"joined"}', src)
                got, _ = game_in.recvfrom(65535)
            except socket.timeout:
                pass
        assert proc.poll() is None, "the bridge died"
        assert got == b'{"t":"joined"}'
        log = (tmp_path / "client_bridge.log").read_text(encoding="utf-8").splitlines()
        assert log[0].startswith("bridge up: game(127.0.0.1:26011) <-> 127.0.0.1:")
        assert any(l.startswith("the game reached the bridge") for l in log), log
        assert any(l.startswith("the server answered") for l in log), log
    finally:
        proc.kill()
        proc.wait()
        server.close()
        game_in.close()
