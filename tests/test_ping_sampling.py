"""Tests that a level load can't be mistaken for a slow network link.

The client times its ping in Lua: it stamps a `ping` and measures the wall clock
when the `pong` comes back. That only means "network round trip" if our frame
loop kept running the whole time — and during a level load the game runs NO
script at all, so a reply spanning one measures the LOAD, not the link. A rejoin
IS a level load.

That mattered because the sample is reported to the server, which sizes the
room's shared lockstep input delay from the two worst pings — and does so ONCE,
at run start. A single contaminated sample therefore pinned the whole party at
MAX_INPUT_DELAY (20 frames, ~333 ms of input lag) for the rest of the run, felt
by everyone, which is the "very laggy after rejoining on both ends" report.

The fix belongs on the client, because it is the only side that knows whether it
was running. The server deliberately still CAPS a genuinely awful link rather
than ignoring it (see test_server.py's "absurd ping is capped") — under-sizing
the delay for a real 2 s link would stall the lockstep constantly, which is worse
than input lag.

Run:  python -m pytest tests/test_ping_sampling.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
NET_CORE = (PACK / "src" / "netCore.lua").read_text(encoding="utf-8")

NL = chr(10)


def pong_branch() -> str:
    """The shipped pong-handling branch, verbatim, as a callable."""
    start = NET_CORE.index('elseif msgType == "pong" then')
    end = NET_CORE.index('elseif msgType == "error" then', start)
    body = NET_CORE[start:end]
    body = body.replace('elseif msgType == "pong" then', "function onPong(msg)", 1)
    return body + NL + "end" + NL


ENV = """
module = { pingMs = 0, pingStale = false }
STALL_MS = 250
pingStalled = false
clock = 0
function nowMs() return clock end
function tonumber_(x) return x end

-- the shipped tick logic for arming/detecting a stall, mirrored here
lastTickMs = 0
function tick(now)
    if lastTickMs > 0 and now - lastTickMs > STALL_MS then
        pingStalled = true
    end
    lastTickMs = now
    clock = now
end
function sendPing() pingStalled = false end
"""


def lua():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(pong_branch())
    return rt


def test_a_normal_round_trip_is_recorded():
    rt = lua()
    rt.eval("tick")(0)
    rt.eval("sendPing")()
    rt.eval("tick")(16)
    rt.eval("tick")(32)
    rt.eval("onPong")({"at": 0})
    assert int(rt.eval("module.pingMs")) == 32
    assert not rt.eval("module.pingStale")


def test_a_reply_spanning_a_level_load_is_discarded():
    """The frame loop stopped for two seconds: that is a load, not the network."""
    rt = lua()
    rt.eval("tick")(0)
    rt.eval("sendPing")()
    rt.execute("module.pingMs = 25")  # a good earlier sample
    rt.eval("tick")(2000)             # the game was blocked the whole time
    rt.eval("onPong")({"at": 0})
    assert int(rt.eval("module.pingMs")) == 25, "a load stall was reported as ping"
    assert rt.eval("module.pingStale"), "the sample was not flagged as unusable"


def test_an_implausible_round_trip_is_discarded_even_without_a_detected_gap():
    rt = lua()
    rt.eval("tick")(0)
    rt.eval("sendPing")()
    rt.execute("module.pingMs = 30")
    rt.execute("clock = 5000")  # reply came back absurdly late
    rt.eval("onPong")({"at": 0})
    assert int(rt.eval("module.pingMs")) == 30
    assert rt.eval("module.pingStale")


def test_sampling_recovers_on_the_next_clean_window():
    """A stall must not poison every later sample — only its own window."""
    rt = lua()
    rt.eval("tick")(0)
    rt.eval("sendPing")()
    rt.eval("tick")(2000)
    rt.eval("onPong")({"at": 0})
    assert rt.eval("module.pingStale")
    # next heartbeat: fresh window, frames running normally again
    rt.eval("sendPing")()
    rt.eval("tick")(2016)
    rt.eval("tick")(2040)
    rt.eval("onPong")({"at": 2000})
    assert int(rt.eval("module.pingMs")) == 40
    assert not rt.eval("module.pingStale")
