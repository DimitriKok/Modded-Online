"""The client half of sending desync logs to the server's Discord (src/logShip.lua).

A run that desynced is uploaded when it ends -- only for a player who switched on
AUTOMATICALLY SEND LOGS (Modded Online's SETTINGS page), and only to a server that
says it forwards logs. The game has no HTTP, so
the log goes to the Modded Online server in base64 parts over UDP, acknowledged
cumulatively and resent when lost; the server posts it (see tests/test_discord_logs.py
and server/test_server.py for that half).

These run the shipped module against a stubbed engine and network, and play the
server's side of the protocol.

Run:  python -m pytest tests/test_log_ship.py -q
"""

from __future__ import annotations

import base64
import os
import pathlib
import random

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
LOG_SHIP = (PACK / "src" / "logShip.lua").read_text(encoding="utf-8")
DESYNC_LOG = (PACK / "src" / "desyncLog.lua").read_text(encoding="utf-8").replace("\r\n", "\n")

ENV = """
now = 100000
function get_ms() return now end
registeredOptions = {}
function register_option_bool(name, desc, long, default)
    registeredOptions[name] = { desc = desc, long = long, default = default }
end
ON = { GUIFRAME = 100 }
guiframe = nil
function set_callback(fn, id) if id == ON.GUIFRAME then guiframe = fn end return 1 end
function SafeCall(_, f, ...) return f(...) end
toasts = {}
function toast(text) toasts[#toasts + 1] = text end
function dbg() end
function get_adventure_seed() return 0x036AEAA9, 0xD53A4E4B end
meta = { version = "2.0.0-test" }
sent, events = {}, {}
eventHandlers, serverHandlers = {}, {}
Network = {
    slot = 2, active = true, inRun = true, serverForwardsLogs = true,
    config = { autoSendLogs = true },
    isActive = function() return Network.active end,
    isInRun = function() return Network.inRun end,
    sendServer = function(msg) sent[#sent + 1] = msg end,
    sendEvent = function(kind, payload) events[#events + 1] = { kind = kind, payload = payload } end,
    onEvent = function(kind, fn) eventHandlers[kind] = fn end,
    onServerMessage = function(kind, fn) serverHandlers[kind] = fn end,
    modSignature = function() return "fyi.hdmod:200:27cb75e3:hosted" end,
}
runText = nil
DesyncLog = {
    currentRunText = function() return runText end,
    frameMark = function() end,
    frameDone = function() end,
}
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(LOG_SHIP)
    return rt


def sent(rt):
    return [dict(m) for m in rt.eval("sent").values()]


def clear_sent(rt):
    rt.execute("sent = {}")


def reply(rt, **fields):
    msg = rt.eval("{}")
    msg["t"] = "logup"
    for k, v in fields.items():
        msg[k] = v
    rt.eval("serverHandlers.logup")(msg)


def frame(rt, ms=16):
    rt.execute(f"now = now + {ms}")
    rt.eval("guiframe()")


def end_run_with(rt, text, reason="FLOOR DESYNC seq 15"):
    rt.eval("LogShip.runStarted")()
    rt.eval("LogShip.noteDesync")(reason)
    rt.eval("function(t) runText = t end")(text)
    rt.eval("LogShip.runEnded")()


def toasts(rt):
    return [str(t) for t in rt.eval("toasts").values()]


def status(rt):
    """LogShip.status() as a dict. A Lua table has no nil fields, so absent = None."""
    got = dict(rt.eval("LogShip.status()"))
    for key in ("pending", "uploading", "phase", "acked", "parts", "runNote"):
        got.setdefault(key, None)
    return got


# ------------------------------------------------------------------- base64

def test_base64_matches_the_standard():
    rt = runtime()
    enc = rt.eval("LogShip.base64")
    rng = random.Random(1)
    samples = [b"", b"f", b"fo", b"foo", b"foob", b"fooba", b"foobar", bytes(range(256))]
    samples += [bytes(rng.randrange(256) for _ in range(n)) for n in (1, 2, 3, 674, 675, 676, 1350, 2001)]
    for data in samples:
        got = enc(data.decode("latin-1").encode("latin-1"))
        assert str(got) == base64.b64encode(data).decode(), data[:10]


# ------------------------------------------------------------------- triggers

def test_a_clean_run_sends_nothing():
    rt = runtime()
    rt.eval("LogShip.runStarted")()
    rt.execute("runText = 'a clean run'")
    rt.eval("LogShip.runEnded")()
    frame(rt)
    assert sent(rt) == []


def test_nothing_is_sent_without_the_setting():
    rt = runtime()
    rt.execute("Network.config.autoSendLogs = false")
    end_run_with(rt, "log text")
    frame(rt)
    assert sent(rt) == [] and status(rt)["pending"] == 0


def test_the_setting_is_off_by_default():
    """The log names the players in the room and the mods everyone runs, so it only
    goes for a player who switched it on."""
    net = (PACK / "src" / "netCore.lua").read_text(encoding="utf-8")
    at = net.index("    config = {")
    block = net[at:net.index("\n    },", at)]
    assert "autoSendLogs = false," in block


def test_a_missing_setting_counts_as_off():
    """A config.json from before the setting existed has no such key."""
    rt = runtime()
    rt.execute("Network.config = {}")
    end_run_with(rt, "log text")
    frame(rt)
    assert sent(rt) == [] and status(rt)["pending"] == 0


def test_the_old_playlunky_option_is_gone():
    """dev65 put the switch in Playlunky's options. It is on the SETTINGS page now,
    and a second switch in a second place would only ever disagree with it."""
    rt = runtime()
    assert len(list(rt.eval("registeredOptions").keys())) == 0
    assert "register_option_bool" not in LOG_SHIP


def test_a_desync_is_announced_to_the_room_once_per_run():
    """The host never sees a FLOOR DESYNC; the room report is what makes it send
    its half of the pair."""
    rt = runtime()
    rt.eval("LogShip.noteDesync")("FLOOR DESYNC seq 15")
    rt.eval("LogShip.noteDesync")("POSITION DESYNC at 15:720")
    events = [dict(e) for e in rt.eval("events").values()]
    assert len(events) == 1 and str(events[0]["kind"]) == "desyncseen"
    assert str(status(rt)["runNote"]) == "FLOOR DESYNC seq 15", "the first reason is the run's"


def test_another_players_report_marks_this_run_without_echoing():
    rt = runtime()
    payload = rt.eval("{ r = 'FLOOR DESYNC seq 15' }")
    rt.eval("eventHandlers.desyncseen")(payload, 2)
    assert "slot 2 reported FLOOR DESYNC seq 15" == str(status(rt)["runNote"])
    assert list(rt.eval("events").values()) == []


def test_a_report_that_arrives_after_the_run_does_not_mark_the_next():
    rt = runtime()
    rt.execute("Network.inRun = false")
    rt.eval("eventHandlers.desyncseen")(rt.eval("{ r = 'x' }"), 2)
    assert status(rt)["runNote"] is None


def test_a_new_run_starts_clean():
    rt = runtime()
    rt.eval("LogShip.noteDesync")("x")
    rt.eval("LogShip.runStarted")()
    assert status(rt)["runNote"] is None


# ------------------------------------------------------------------- upload

def run_upload(rt, text, drop=frozenset(), max_frames=2000):
    """Drive the upload against a well-behaved server. `drop`: part indexes whose
    FIRST copy is lost. Returns the bytes the server reassembled."""
    end_run_with(rt, text)
    held, seen = {}, set()
    begin = None
    for _ in range(max_frames):
        frame(rt)
        for msg in sent(rt):
            op = str(msg["op"])
            if op == "begin":
                begin = msg
                reply(rt, op="ready", u=msg["u"], upto=0)
            elif op == "part":
                i = int(msg["i"])
                if i in drop and i not in seen:
                    seen.add(i)
                    continue
                held[i] = str(msg["d"])
                upto = 0
                while upto + 1 in held:
                    upto += 1
                reply(rt, op="ack", u=msg["u"], upto=upto)
                if upto == int(begin["n"]):
                    reply(rt, op="done", u=msg["u"], ok=True, why="posted")
        clear_sent(rt)
        if status(rt)["uploading"] is None and begin is not None:
            break
    assert begin is not None, "never started"
    # lupa hands Lua a Python str as its UTF-8 bytes
    assert int(begin["bytes"]) == len(text.encode("utf-8"))
    joined = "".join(held[i] for i in range(1, int(begin["n"]) + 1))
    return base64.b64decode(joined), begin


def test_a_desynced_run_reaches_the_server_intact():
    rt = runtime()
    text = "=== Modded Online 2.0.0-test — run start ===\n" + "".join(
        f"[20:25:58 15:{i}] line {i} with some text\n" for i in range(3000))
    data, begin = run_upload(rt, text)
    assert data == text.encode("utf-8")
    meta = begin["meta"]
    assert str(meta["reason"]) == "FLOOR DESYNC seq 15"
    assert str(meta["version"]) == "2.0.0-test"
    assert str(meta["seed"]) == "036AEAA9-D53A4E4B"
    assert any("sent to Discord" in t for t in toasts(rt))


def test_lost_parts_are_sent_again():
    rt = runtime()
    text = "x" * (675 * 40 + 11)
    data, _ = run_upload(rt, text, drop={1, 7, 33, 41})
    assert data == text.encode()


def test_at_most_a_window_of_parts_is_in_flight_and_a_few_per_frame():
    rt = runtime()
    end_run_with(rt, "y" * (675 * 100))
    frame(rt)  # begin
    begin = [m for m in sent(rt) if str(m["op"]) == "begin"][0]
    reply(rt, op="ready", u=begin["u"], upto=0)
    clear_sent(rt)
    frame(rt)
    first = [int(m["i"]) for m in sent(rt) if str(m["op"]) == "part"]
    assert first == list(range(1, 9)), "eight parts per frame"
    for _ in range(10):
        frame(rt)
    parts = [int(m["i"]) for m in sent(rt) if str(m["op"]) == "part"]
    assert max(parts) == 32, "never beyond the window without an ack"


def test_a_refusal_is_said_and_the_upload_dropped():
    rt = runtime()
    end_run_with(rt, "log")
    frame(rt)
    begin = sent(rt)[0]
    reply(rt, op="refused", u=begin["u"], why="too many desync logs from you this hour")
    assert status(rt)["uploading"] is None
    assert any("too many desync logs" in t for t in toasts(rt))


def test_a_reply_for_another_upload_is_ignored():
    rt = runtime()
    end_run_with(rt, "log")
    frame(rt)
    reply(rt, op="refused", u="someone-else", why="no")
    assert status(rt)["uploading"] is not None


def test_a_server_that_does_not_forward_keeps_the_log_for_one_that_does():
    rt = runtime()
    rt.execute("Network.serverForwardsLogs = false")
    end_run_with(rt, "log")
    frame(rt)
    assert sent(rt) == [] and status(rt)["pending"] == 1
    assert any("isn't set up to post desync logs" in t for t in toasts(rt))
    rt.execute("Network.serverForwardsLogs = true")
    frame(rt)
    assert str(sent(rt)[0]["op"]) == "begin"


def test_leaving_the_room_mid_upload_keeps_the_log_to_send_again():
    rt = runtime()
    end_run_with(rt, "z" * 5000)
    frame(rt)
    begin = sent(rt)[0]
    reply(rt, op="ready", u=begin["u"], upto=0)
    frame(rt)
    rt.execute("Network.active = false")
    frame(rt)
    assert status(rt)["uploading"] is None and status(rt)["pending"] == 1


def test_switching_the_setting_off_stops_an_upload():
    rt = runtime()
    end_run_with(rt, "z" * 5000)
    frame(rt)
    rt.execute("Network.config.autoSendLogs = false")
    clear_sent(rt)
    frame(rt)
    frame(rt)
    assert sent(rt) == [] and status(rt)["uploading"] is None and status(rt)["pending"] == 0


def test_a_server_that_stops_answering_is_given_up_on():
    rt = runtime()
    end_run_with(rt, "log")
    for _ in range(30):
        frame(rt, ms=1000)
    assert status(rt)["uploading"] is None
    assert any("did not answer" in t for t in toasts(rt))


def test_a_lost_done_is_asked_for_again():
    """Every part acknowledged, the done lost: a repeated last part gets it back."""
    rt = runtime()
    end_run_with(rt, "q" * 700)
    frame(rt)
    begin = sent(rt)[0]
    reply(rt, op="ready", u=begin["u"], upto=0)
    reply(rt, op="ack", u=begin["u"], upto=2)
    clear_sent(rt)
    frame(rt, ms=6000)
    pokes = [m for m in sent(rt) if str(m["op"]) == "part"]
    assert pokes and int(pokes[0]["i"]) == 2


def test_a_long_run_keeps_its_head_and_tail():
    rt = runtime()
    fit = rt.eval("LogShip.fit")
    text = "HEAD" + ("m" * (5 * 1024 * 1024)) + "TAIL"
    out = str(fit(text))
    assert len(out) <= 4 * 1024 * 1024 - 4096
    assert out.startswith("HEAD") and out.endswith("TAIL") and "bytes cut from the middle" in out


# ------------------------------------------------------------- desyncLog side

def test_the_log_sent_is_this_runs_own_section(tmp_path):
    start = "function module.currentRunText()"
    i = DESYNC_LOG.index(start)
    j = DESYNC_LOG.index("\nend\n", i)
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("module = {}")
    log = tmp_path / "desync_log.txt"
    # bytes: write_text would turn every \n into \r\n on Windows
    log.write_bytes(("\n=== Modded Online 2.0.0 — run start 19:00 ===\nfirst run\nrun end\n"
                     "\n=== Modded Online 2.0.0 — run start 20:00 ===\nsecond run\n").encode("utf-8"))
    rt.execute(f"logPath = {str(log)!r}".replace("\\", "/"))
    rt.execute(DESYNC_LOG[i:j] + "\nend\n")
    got = str(rt.eval("module.currentRunText()"))
    assert got.startswith("=== Modded Online 2.0.0 — run start 20:00 ===")
    assert "first run" not in got and got.endswith("second run\n")
    rt.execute("logPath = nil")
    assert rt.eval("module.currentRunText()") is None


def test_every_desync_kind_is_noted():
    assert 'LogShip.noteDesync, string.format("FLOOR DESYNC seq %d", s)' in DESYNC_LOG
    assert 'LogShip.noteDesync, "POSITION DESYNC at "' in DESYNC_LOG
    event_sync = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")
    assert 'LogShip.noteDesync, string.format("RESYNC WARP to %s-%s"' in event_sync
    assert "SafeCall(\"desyncLog:logShip\", LogShip.runEnded)" in DESYNC_LOG
    main = (PACK / "main.lua").read_text(encoding="utf-8")
    assert '"src.logShip"' in main
