"""The position checksum, compared whichever side arrives second, and explained.

Two dev78 changes, both detection-only:

* The machine BEHIND used to throw the other's checksum away. sendChecksum stored
  `checksums[key] = { mine = hash }`, overwriting a `theirs` that had already
  arrived, so only the machine ahead ever compared. Now both do.
* A mismatch is logged with what went into the hash on BOTH machines, for the same
  simulated frame: each player's position, health, layer and mount, the level's
  frame, and which engine PRNG streams differ. Until now a desync left a pair of
  hashes and positions printed at the alarm, 240 frames later and at a different
  frame on each machine (room VOYY: 23:3000 on the host, 23:3120 on the peer).

And at the alarm -- the "Desync detected" popup -- the log goes to Discord at once
(LogShip.desyncNow; see tests/test_log_ship.py for that half).

Run:  python -m pytest tests/test_checksum_detail.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")
NL = chr(10)


def _block() -> str:
    start = INPUT_SYNC.index("-- What a checksum stands for, sent along with it.")
    on = INPUT_SYNC.index("local function onChecksum(payload, originSlot)")
    end = INPUT_SYNC.index(NL + "end" + NL, on) + len(NL + "end" + NL)
    return INPUT_SYNC[start:end]


ENV = """
module = {}
seq, offset = 23, 2760
coopSlots = { [1] = 1, [2] = 2 }
goneSlots = {}
checksums = {}
desyncStreak, desyncReported, mismatchLines = 0, false, 0
DESYNC_STREAK_ALARM = 3
players = {
    [1] = { x = 3.43, y = 109.05, health = 2, layer = 0 },
    [2] = { x = 4.21, y = 109.05, health = 3, layer = 0 },
}
function get_player(i) return players[i] end
streamsBase = 0
prng = { get_pair = function(_, c) return c + streamsBase, c * 7 end }
function get_local_state() return { time_level = 2762 } end
wire = {}
Network = { slot = 1, sendWorld = function(m) wire[#wire + 1] = m end }
lines, errors, toasts, shipped, alarms = {}, {}, {}, {}, 0
function errorf(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
function toast(t) toasts[#toasts + 1] = t end
DesyncLog = {
    event = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end,
    positionDesync = function() alarms = alarms + 1 end,
}
LogShip = { desyncNow = function(reason, key) shipped[#shipped + 1] = { reason = reason, key = key } end }
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(_block() + "\nT = { onChecksum = onChecksum }\n")
    return rt


def send(rt):
    rt.eval("module.sendChecksum")()
    return rt.eval("wire[#wire]")


def theirs(rt, sent, *, h=None, p2=None, streams=None):
    """The other machine's checksum for the same frame: `sent` with changes."""
    payload = rt.eval("{}")
    payload["s"], payload["f"] = sent["s"], sent["f"]
    payload["h"] = sent["h"] if h is None else h
    payload["t"] = sent["t"]
    payload["p"] = sent["p"] if p2 is None else p2
    payload["r"] = sent["r"] if streams is None else streams
    return payload


def lines(rt):
    return [str(l) for l in rt.eval("lines").values()]


def test_the_checksum_carries_what_went_into_it():
    rt = runtime()
    sent = send(rt)
    rows = [list(r.values()) for r in sent["p"].values()]
    assert rows == [[1, 343, 10905, 2, 0, 0], [2, 421, 10905, 3, 0, 0]]
    assert int(sent["t"]) == 2762
    assert len(list(sent["r"].values())) == 10


def test_a_match_is_quiet():
    rt = runtime()
    sent = send(rt)
    rt.eval("T.onChecksum")(theirs(rt, sent), 2)
    assert lines(rt) == [] and int(rt.eval("desyncStreak")) == 0


def test_the_machine_behind_compares_too():
    """Theirs arrives before ours is computed: the old code overwrote it and never
    compared. Same mismatch, seen from the machine that was behind."""
    rt = runtime()
    # what the other machine sent for 23:2760, before we got there
    other = rt.eval("{ s = 23, f = 2760, h = 12345, t = 2762, p = {}, r = {} }")
    rt.eval("T.onChecksum")(other, 2)
    assert int(rt.eval("desyncStreak")) == 0, "compared before ours existed"
    send(rt)
    assert int(rt.eval("desyncStreak")) == 1, "the machine behind never compared"
    assert lines(rt) and "CHECKSUM MISMATCH at 23:2760 (streak 1)" in lines(rt)[0]


def test_a_mismatch_shows_both_machines_at_the_same_frame():
    rt = runtime()
    sent = send(rt)
    p2 = rt.eval("{ { 1, 343, 10905, 2, 0, 0 }, { 2, 279, 10805, 0, 0, 0 } }")
    streams = rt.eval("{}")
    for i, v in enumerate(list(sent["r"].values()), start=1):
        streams[i] = v
    streams[4] = 999  # PRNG_CLASS 3 parted
    rt.eval("T.onChecksum")(theirs(rt, sent, h=1, p2=p2, streams=streams), 2)
    line = lines(rt)[0]
    assert "here t=2762 p1 3.43,109.05 hp2 L0; p2 4.21,109.05 hp3 L0" in line, line
    assert "there t=2762 p1 3.43,109.05 hp2 L0; p2 2.79,108.05 hp0 L0" in line, line
    assert line.endswith("prng streams differ: c3"), line


def test_only_the_first_mismatches_of_a_floor_are_spelled_out():
    rt = runtime()
    for f in range(2760, 2760 + 120 * 6, 120):
        rt.execute(f"offset = {f}")
        sent = send(rt)
        rt.eval("T.onChecksum")(theirs(rt, sent, h=1), 2)
    assert len([l for l in lines(rt) if l.startswith("CHECKSUM MISMATCH")]) == 3


def test_the_alarm_sends_the_log_at_the_popup():
    rt = runtime()
    for f in (2760, 2880, 3000):
        rt.execute(f"offset = {f}")
        sent = send(rt)
        rt.eval("T.onChecksum")(theirs(rt, sent, h=1), 2)
    assert list(rt.eval("toasts").values()) == ["Desync detected — a mod is behaving non-deterministically"]
    assert int(rt.eval("alarms")) == 1
    shipped = [dict(s) for s in rt.eval("shipped").values()]
    assert shipped == [{"reason": "POSITION DESYNC at 23:3000", "key": 23}]


def test_one_agreement_resets_the_streak():
    rt = runtime()
    rt.execute("offset = 2760")
    rt.eval("T.onChecksum")(theirs(rt, send(rt), h=1), 2)
    rt.execute("offset = 2880")
    rt.eval("T.onChecksum")(theirs(rt, send(rt)), 2)
    assert int(rt.eval("desyncStreak")) == 0


def test_our_own_checksum_echoed_back_is_ignored():
    rt = runtime()
    sent = send(rt)
    rt.eval("T.onChecksum")(theirs(rt, sent, h=1), 1)
    assert int(rt.eval("desyncStreak")) == 0


def test_a_departed_player_past_the_cutoff_is_left_out_of_both():
    rt = runtime()
    rt.execute("goneSlots[2] = { seq = 22, upto = 0 }")
    sent = send(rt)
    rows = [list(r.values()) for r in sent["p"].values()]
    assert [r[0] for r in rows] == [1]


def test_a_floor_spells_out_three_mismatches_however_its_streaks_go():
    """Mismatch, match, mismatch... must not log a line every four seconds."""
    rt = runtime()
    for i, f in enumerate(range(2760, 2760 + 120 * 10, 120)):
        rt.execute(f"offset = {f}")
        sent = send(rt)
        rt.eval("T.onChecksum")(theirs(rt, sent, h=None if i % 2 else 1), 2)
    assert len([l for l in lines(rt) if l.startswith("CHECKSUM MISMATCH")]) == 3


def test_every_reset_of_the_streak_resets_the_lines_too():
    # the session reset, the resync rebase and the LEVEL engage
    import re
    streak = re.findall(r"\n[ \t]+desyncStreak = 0\n", INPUT_SYNC)
    lines_ = re.findall(r"\n[ \t]+mismatchLines = 0\n", INPUT_SYNC)
    assert len(streak) == len(lines_) == 3
