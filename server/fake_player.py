"""Modded Online — a fake player, for testing the mod on your own.

This is a real client. It opens its own UDP socket, joins your room through the
real server, takes a real slot, readies up, and takes part in the real lockstep
input exchange. From your game's point of view there is simply another player in
the lobby: the roster grows, a second spelunker spawns, the co-op HUD gains a
row, and every synced system (layer travel, checksums, transitions, restarts)
runs its two-player path. Nothing in the mod knows or cares that the player on
the other end is a script.

WHAT IT DOES NOT DO: it runs no simulation. It never generates a world, so it
cannot verify that your world matches anyone else's — it sends no floor digests
and no position checksums, so a real desync between two real machines is still
something only two real machines can find. What it tests is everything that
depends on a second player EXISTING.

HOW IT KEEPS UP WITHOUT SIMULATING
The lockstep gate stalls until every slot's input for the current frame has
arrived, so the fake player has to produce inputs on the right frames or the
game freezes on "WAITING FOR PLAYERS". Your game stamps every input datagram
with the screen sequence and frame range it is on (`{s, f, i}`), which tells us
where it is without our having to simulate anything.

The trick is that we do NOT answer frame-for-frame. A real player cannot say what
they will press in a second's time, so their inputs can only ever arrive one
round trip late -- which is why the server negotiates an input delay big enough
to cover it. This player's input is a CONSTANT, so it is knowable arbitrarily far
in advance: we send a long run of it, LEAD_FRAMES ahead of wherever your game
currently is, and top the runway up before it drains. Your game therefore never
once waits on us, no matter what the round trip does.

Answering frame-for-frame instead is what made the game stutter: on a local
server the negotiated delay is the 4-frame floor (~66 ms), and a reply that has
to cross game -> server -> here -> server -> game inside that budget will miss it
often enough to be felt. Running ahead removes the round trip from the loop
entirely, and as a bonus cuts the datagrams your game has to decode from ~85/s to
about 5/s.

We stay inside the CURRENT sequence and never guess the next one: your game reads
a peer on a different sequence as "they went through a door we never saw" and
asks for a floor resync, so running ahead into seq+1 would trip a false alarm.
A level transition therefore costs one round trip, once, which the gate's own
input-delay prefill absorbs.

By default the fake player stands still (input 0). --hold makes it hold buttons.

It also votes yes on an instant restart, so pressing restart is all it takes on
your own -- the mod needs EVERY player to press it, and a dummy that never voted
would leave the tally stuck forever. Exactly one vote per press, so several of
these in one room answer a press once each rather than answering each other.

RUN AS MANY AS YOU LIKE, up to a full room of four. Give each its own --name and
--char so you can tell them apart; they take separate slots and each one is
another real player as far as your game is concerned.

USAGE
    py fake_player.py <server-ip> <server-port> <ROOM>

    py fake_player.py 127.0.0.1 26000 ABCD
    py fake_player.py 127.0.0.1 26000 ABCD --name Tester --char 196
    py fake_player.py 127.0.0.1 26000 ABCD --hold 512      # walks right forever

The mod can also start and stop these for you: set TEST PLAYERS to 1-3 in the
Modded Online menu before you host, and that many join your room automatically.

Stop it with Ctrl-C (or close its window); it says goodbye to the server so your
game sees a clean departure rather than a timeout.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import random
import signal
import sys
import time

# Spelunky 2 input bits, for --hold. Combine with +.
INPUTS = {
    "jump": 1, "whip": 2, "bomb": 4, "rope": 8, "run": 16, "door": 32,
    "menu": 64, "journal": 128, "left": 256, "right": 512, "up": 1024, "down": 2048,
}

# How far ahead of your game we keep our inputs committed, in 60 Hz sim frames.
# This is the entire anti-stutter mechanism: as long as the runway is longer than
# the round trip, your game never blocks on us. Two seconds is far more than any
# local round trip and still only a few hundred bytes per datagram.
LEAD_FRAMES = 120
# Top the runway up once it drops below this. The gap between the two is how
# often we send at all (~75 frames, so roughly once a second).
MIN_LEAD_FRAMES = 45
# Also re-cover this much ground BEHIND your game each time, so a single lost
# datagram heals on the next send instead of leaving a hole in the frames -- a
# hole is exactly where the lockstep would stall.
LOOKBACK_FRAMES = 60
# Re-send the current window this often. Loss recovery, and it doubles as the
# in-run keepalive (the server drops a client in a started run after 2 s quiet).
RESEND_INTERVAL_S = 0.25
# Lobby-rate keepalive: refreshes our last_seen and reports a ping, which is what
# the server sizes the shared input delay from.
PING_INTERVAL_S = 0.5
# Re-assert readiness at this rate while sitting in the lobby, so a dropped
# `ready` datagram can't leave the host unable to start.
READY_INTERVAL_S = 1.0
# Backstop only: how long a restart-vote round may stay open before we re-arm
# anyway. Longer than the mod's own 20 s vote TTL, because the roster check in
# on_restart_vote is what normally settles a round.
ROUND_BACKSTOP_S = 25.0
# How long the game may go quiet before we say so in the log. Longer than any
# ordinary level load, short enough to bracket a real hang.
SILENCE_NOTICE_S = 4.0


# Where this dummy's own log goes. The mod starts these in a minimised console
# window, so everything they printed died with that window — when one stopped
# feeding the game and the run hung on WAITING FOR PLAYERS there was simply no
# record of what it had been doing. A file next to the desync log makes the two
# readable side by side, which is the whole point.
LOG_PATH = None


def log(msg: str) -> None:
    line = f"[fake-player] {msg}"
    print(line, flush=True)
    if LOG_PATH is not None:
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(f"[{time.strftime('%H:%M:%S')}] {line}\n")
        except OSError:
            pass   # a dummy must never die because its log could not be written


class FakePlayer(asyncio.DatagramProtocol):
    def __init__(self, args):
        self.args = args
        self.server = (args.host, args.port)
        self.room = args.room.upper()
        self.cid = f"fake-{random.getrandbits(48):012x}"
        self.transport = None
        self.slot = None
        self.joined = False
        self.started = False
        # the room's mod fingerprint. Unknown until the server tells us -- see
        # handshake(): a deliberately-empty first join is answered with a
        # mod_mismatch that carries the room's real values, which is how this
        # stays correct no matter which content mods you are running.
        self.mod_name = args.mod
        self.mod_version = args.modv

        # reliable channel: cumulative ack of the highest contiguous seq applied
        self.applied = set()
        self.ack_high = 0

        # lockstep state: where your game is, and how far we have committed
        self.seq = 0          # the screen sequence your game is on
        self.host_high = -1   # the highest frame it has recorded for itself
        self.win_base = 0     # first frame our committed window covers
        self.sent_high = -1   # the highest frame WE have committed input for
        self.window = None    # the datagram we last sent, re-sent verbatim

        # reliable events we have sent and not yet seen acked (cseq -> message).
        # Only ever holds a restart vote; the server wants them strictly in order.
        self.outbox = {}
        self.next_cseq = 1

        # restart voting: one vote per round, tracked by who has voted
        self.roster = set()            # slots in the room, from the lobby push
        self.round_voters = set()      # who has voted in the round under way
        self.voted_this_round = False
        self.round_started_at = 0.0

        self.ready_sent_at = 0.0
        self.last_peer_state_at = 0.0   # when the game last told us where it was
        self.silence_reported = False
        self.am_ready = False  # as last confirmed by the server's lobby push
        self.dest = None       # camp door we ready at; mirrored from the host
        self.stop = asyncio.Event()

    # ------------------------------------------------------------- transport

    def connection_made(self, transport):
        self.transport = transport

    def send(self, msg: dict) -> None:
        if self.transport is None:
            return
        base = {"room": self.room, "cid": self.cid}
        base.update(msg)
        self.transport.sendto(json.dumps(base).encode("utf-8"), self.server)

    def send_join(self) -> None:
        # port 0 = relay mode: the server replies to whatever source address our
        # datagrams come from. That is what lets this run on the SAME machine as
        # the game without colliding with its listen port -- two clients sharing
        # one listen port is exactly the case the mod warns scrambles slots.
        self.send({"t": "join", "name": self.args.name, "port": 0,
                   "mod": self.mod_name, "modv": self.mod_version})

    # -------------------------------------------------------------- receive

    def datagram_received(self, data, addr):
        try:
            msg = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return
        kind = msg.get("t")
        if kind == "state":
            self.on_peer_state(msg.get("d"))
        elif kind == "event":
            self.on_event(msg)
        elif kind == "joined":
            self.on_joined(msg)
        elif kind == "lobby":
            self.on_lobby(msg)
        elif kind == "event_ack":
            self.outbox.pop(msg.get("cseq"), None)
        elif kind == "error":
            self.on_error(msg)

    def on_joined(self, msg):
        self.slot = msg.get("slot")
        self.room = msg.get("room", self.room)
        # ADOPT THE RELIABLE-CHANNEL BASELINE. Joining a room that is already
        # running makes us a late joiner, and the server starts our channel at
        # `base` rather than replaying the whole backlog -- so events 1..base are
        # ones we will never be sent. Without taking it, our contiguous ack walk
        # below waits for event 1 for ever, we ack 0 for ever, and the server
        # (which now correctly never gives up re-sending unacked events) re-sends
        # the entire log to us every 250 ms until it drops us. The real client
        # does exactly this in netCore's `joined` handler.
        base = msg.get("base")
        if isinstance(base, int) and not isinstance(base, bool) and base > self.ack_high:
            self.ack_high = base
            self.send({"t": "ack", "seq": self.ack_high})
        if not self.joined:
            self.joined = True
            log(f"joined room {self.room} as slot {self.slot} "
                f"(\"{self.args.name}\", character {self.args.char})")

    def on_lobby(self, msg):
        # Only the run ENDING is taken from here; the start is taken from the
        # run_start event, which is the reliable, ordered announcement of it.
        if self.started and not bool(msg.get("started")):
            self.started = False
            log("run ended — back in the lobby")
        # Ready at the SAME camp door as the host, or the mod's lobby check
        # ("everyone must ready at the same door") never passes and the run
        # cannot start. Slot order is join order, so the lowest slot is the host.
        players = msg.get("players") or []
        self.roster = {p["slot"] for p in players
                       if isinstance(p, dict) and isinstance(p.get("slot"), int)}
        host = min((p for p in players if isinstance(p, dict) and "slot" in p),
                   key=lambda p: p["slot"], default=None)
        if host is not None and host.get("slot") != self.slot:
            self.dest = host.get("dest")
        mine = next((p for p in players
                     if isinstance(p, dict) and p.get("slot") == self.slot), None)
        if mine is not None:
            self.am_ready = bool(mine.get("ready"))
            if not self.am_ready:
                # Deliberately NOT gated on the run being unstarted. Readying up
                # while a run is in progress is exactly how the server folds a
                # late-joiner into the party at the host's next floor, and it is
                # also how we get back in after the host ends an adventure.
                self.send_ready()

    def on_error(self, msg):
        err = str(msg.get("err", "?"))
        if err == "mod_mismatch":
            # The server told us what this room actually runs. Adopt it and
            # re-join: the fingerprint is a hash of YOUR enabled content mods,
            # which this script has no way to compute and no reason to police.
            room_mod = str(msg.get("mod", ""))
            room_modv = str(msg.get("modv", ""))
            if room_mod and (room_mod, room_modv) != (self.mod_name, self.mod_version):
                self.mod_name, self.mod_version = room_mod, room_modv
                log(f"adopting the room's mod fingerprint: {room_mod} / {room_modv}")
                self.send_join()
                return
        if err == "no_such_room":
            log(f"no room {self.room} on {self.args.host}:{self.args.port} — "
                "is the server up, and did you type the code right?")
        elif err == "room_full":
            log("that room is full")
        else:
            log(f"server error: {err}")
        if err in ("no_such_room", "room_full", "version_mismatch"):
            self.stop.set()

    def on_event(self, msg):
        """Reliable, server-sequenced events. We apply almost none of them — we
        have to ACK, or the server resends each one 40 times and then drops us."""
        seq = msg.get("seq")
        if not isinstance(seq, int):
            return
        first_time = seq not in self.applied
        self.applied.add(seq)
        while (self.ack_high + 1) in self.applied:
            self.ack_high += 1
        self.send({"t": "ack", "seq": self.ack_high})
        kind = str(msg.get("k"))
        if kind == "restart_vote" and first_time:
            self.on_restart_vote(msg.get("slot"))
        if kind == "run_start" and first_time:
            # The authoritative "a run begins now". The host's frame sequence
            # counter restarts here, so the mirror must forget where it was.
            self.reset_mirror()
            # NOT clearing the outbox: the server accepts client events strictly
            # in order and silently drops anything that leaves a gap, so
            # abandoning an unacked cseq wedges the channel and EVERY later vote
            # of ours is thrown away -- which looks exactly like a dummy that
            # refuses to vote. Keep re-sending until it is acked; a duplicate is
            # harmless (the server dedups by cseq and acks again).
            self.round_voters.clear()
            self.voted_this_round = False
            self.round_started_at = 0.0
            self.started = True
            log("run started — feeding the lockstep input stream")

    # --------------------------------------------------------- the lockstep

    def reset_mirror(self):
        self.seq = 0
        self.host_high = -1
        self.win_base = 0
        self.sent_high = -1
        self.window = None

    def on_peer_state(self, d):
        """Your game's input datagram: {s: screen sequence, f: first frame,
        i: [buttons...]}. It tells us where the simulation has got to."""
        if not isinstance(d, dict):
            return
        buttons, seq, base = d.get("i"), d.get("s"), d.get("f")
        if not isinstance(buttons, list) or not isinstance(seq, int) or not isinstance(base, int):
            return
        if isinstance(seq, bool) or isinstance(base, bool):
            return
        high = base + len(buttons) - 1
        # A RESTART REUSES THE SEQUENCE NUMBER. Every run's first level is
        # lockstep sequence 1 (beginSession resets to 0, the first engage makes it
        # 1), so "same seq" does NOT mean "same run" and the frame counter can
        # legitimately jump backwards to zero. Meanwhile the game keeps re-sending
        # its OLD window from its network keepalive all through the regeneration
        # freeze -- arriving after run_start has already reset us -- so we latch
        # onto the old run's high-water mark and then refuse to come back down,
        # because a lower `high` is not "greater" and our lead is still full. The
        # new run then asks for frame 4 while we are committed to frames 183-363
        # and the gate waits for input that will never be sent: WAITING FOR
        # PLAYERS, for good, every time the timing lines up.
        #
        # The exact test is coverage, not magnitude: if the game is asking about
        # frames BELOW the window we committed, our window belongs to something
        # else and has to be rebuilt from where the game actually is. No slack
        # constant to tune, and an out-of-order datagram costs one extra send.
        behind_window = self.window is not None and base < self.win_base
        self.last_peer_state_at = time.monotonic()
        if seq != self.seq or behind_window:
            log(f"following screen sequence {seq} from frame {high} "
                f"(was {self.seq})")
            self.seq, self.host_high, self.sent_high = seq, high, -1
        elif high > self.host_high:
            self.host_high = high
        # Top the runway up before it drains. Between refills this sends nothing
        # at all, which is the point -- your game is already holding our input for
        # every frame it is about to reach.
        if self.sent_high - self.host_high < MIN_LEAD_FRAMES:
            self.extend_inputs()

    def extend_inputs(self):
        """Commit our (constant) input from just behind your game to well ahead.

        RUNNING AHEAD IS ONLY SOUND BECAUSE THE INPUT IS CONSTANT. Your game
        overwrites whatever it already held for a frame when a later datagram
        covers it again, and by then it may already have SIMULATED that frame --
        so re-sending a frame with a DIFFERENT value would fork the two worlds.
        Every frame we send carries the same `--hold` value, so a re-send can
        never change a decision. Anything that varies the input over time has to
        stop running ahead and go back to committing one frame at a time.
        """
        if self.host_high < 0:
            return
        base = max(0, self.host_high - LOOKBACK_FRAMES)
        top = self.host_high + LEAD_FRAMES
        self.window = {"t": "state", "d": {"s": self.seq, "f": base,
                                           "i": [self.args.hold] * (top - base + 1)}}
        self.win_base = base
        self.sent_high = top
        self.send(self.window)

    # ------------------------------------------------------------ outgoing

    def on_restart_vote(self, from_slot):
        """An instant restart needs EVERY player to press it, so a dummy that
        never voted would leave the tally stuck and restart would do nothing. Vote
        yes — pressing restart once is then all it takes.

        EXACTLY ONE VOTE PER ROUND, and the round is tracked by WHO has voted
        rather than by a clock. Both of the obvious shortcuts are wrong:

        * "vote on every vote event we see from someone else" cascades once there
          is more than one dummy — each answers the others' answers, and three
          dummies turn one press into a flood of events.
        * "vote at most once every N seconds" locks the dummy out of the NEXT
          press whenever a round fails to complete (the server coalesces restarts
          inside RESTART_DEDUP_S, or a datagram is lost), so restart silently does
          nothing for the rest of the window. That shipped once already.

        A round is over when everyone in the room has voted — which is true
        whether or not the restart itself then goes through — so this re-arms
        immediately either way. The timeout below is only a backstop for a round
        that never completes at all; it is longer than the mod's own vote TTL, so
        in practice the roster check is what re-arms us.
        """
        now = time.monotonic()
        if self.round_started_at and now - self.round_started_at > ROUND_BACKSTOP_S:
            self.round_voters.clear()
            self.voted_this_round = False
        if not self.round_voters:
            self.round_started_at = now
        if from_slot is not None:
            self.round_voters.add(from_slot)
        if from_slot != self.slot and not self.voted_this_round:
            self.voted_this_round = True
            self.round_voters.add(self.slot)
            self.cast_restart_vote()
        # everyone has now voted: the round is settled, so be ready for the next
        # press straight away rather than waiting on any timer
        if self.roster and self.round_voters >= self.roster:
            self.round_voters.clear()
            self.voted_this_round = False
            self.round_started_at = 0.0

    def cast_restart_vote(self):
        cseq = self.next_cseq
        self.next_cseq += 1
        # The server requires client events strictly in order and drops any gap,
        # so this is held in the outbox and re-sent until it is acked.
        self.outbox[cseq] = {"t": "event", "cseq": cseq, "k": "restart_vote", "p": {}}
        self.send(self.outbox[cseq])
        log("restart vote seen — voting yes")

    def send_ready(self):
        self.ready_sent_at = time.monotonic()
        self.send({"t": "ready", "ready": True, "char": self.args.char,
                   "dest": self.dest})

    async def keepalive(self):
        """Ping keeps us from timing out and reports the latency the server
        sizes everyone's shared input delay from."""
        while not self.stop.is_set():
            self.send({"t": "ping", "ping": 0, "at": int(time.monotonic() * 1000)})
            if self.joined and not self.am_ready \
                    and time.monotonic() - self.ready_sent_at >= READY_INTERVAL_S:
                self.send_ready()
            await asyncio.sleep(PING_INTERVAL_S)

    async def resend(self):
        """Re-send the current input window (and any unacked event), covering a
        dropped datagram without waiting for your game to notice it. Deliberately
        NOT gated on a "run is active" flag: the whole point is to keep sending
        when the normal path is the thing that broke."""
        while not self.stop.is_set():
            if self.window is not None:
                self.send(self.window)
            for msg in list(self.outbox.values()):
                self.send(msg)
            # WHICH SIDE WENT QUIET. If the game hangs on WAITING FOR PLAYERS the
            # question is always the same: did this dummy stop sending, or stop
            # HEARING? Only one of those is our bug, and without this line the two
            # are indistinguishable after the fact — which is exactly what left a
            # run-hang unexplained once already.
            if self.started and self.last_peer_state_at:
                quiet = time.monotonic() - self.last_peer_state_at
                if quiet > SILENCE_NOTICE_S and not self.silence_reported:
                    self.silence_reported = True
                    log(f"no input from the game for {quiet:.1f}s — still sending "
                        f"seq {self.seq} frames {self.win_base}-{self.sent_high}")
                elif quiet <= SILENCE_NOTICE_S and self.silence_reported:
                    self.silence_reported = False
                    log("hearing the game again")
            await asyncio.sleep(RESEND_INTERVAL_S)

    async def handshake(self):
        """Re-send the join until the server answers. Also covers starting up
        before the game has finished opening its room."""
        while not self.stop.is_set() and not self.joined:
            self.send_join()
            await asyncio.sleep(0.5)

    def farewell(self):
        # a clean leave, so your game sees a departure instead of stalling on a
        # silent slot until the server's timeout resolves it
        for _ in range(3):
            self.send({"t": "leave"})


# Set from a signal handler, which on Windows runs on the main thread between
# bytecodes rather than inside the event loop -- so a plain flag polled by a task
# is the portable way to get out. (loop.add_signal_handler is POSIX-only, and
# waking the proactor loop from a Windows handler is not reliable.)
_interrupted = False


def _on_signal(_signum, _frame):
    global _interrupted
    _interrupted = True


def install_signal_handlers() -> None:
    # SIGBREAK is Windows-only (Ctrl-Break, and what a parent process can send to
    # a new process group); SIGTERM is absent on some Windows builds.
    for name in ("SIGINT", "SIGTERM", "SIGBREAK"):
        sig = getattr(signal, name, None)
        if sig is None:
            continue
        try:
            signal.signal(sig, _on_signal)
        except (ValueError, OSError):
            pass


async def run(args) -> int:
    loop = asyncio.get_running_loop()
    player = FakePlayer(args)
    await loop.create_datagram_endpoint(lambda: player, local_addr=("0.0.0.0", 0))
    log(f"joining room {player.room} on {args.host}:{args.port} ...")
    install_signal_handlers()

    async def watchdog():
        while not _interrupted:
            await asyncio.sleep(0.05)
        player.stop.set()

    tasks = [asyncio.ensure_future(c) for c in
             (player.handshake(), player.keepalive(), player.resend(), watchdog())]
    try:
        await player.stop.wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        for t in tasks:
            t.cancel()
        player.farewell()
        await asyncio.sleep(0.05)  # let the goodbye reach the wire
    log("left the room")
    return 0


def parse_hold(value: str) -> int:
    """--hold accepts a number (512) or names (right+jump)."""
    value = value.strip().lower()
    if not value:
        return 0
    try:
        return int(value, 0)
    except ValueError:
        pass
    total = 0
    for part in value.replace(",", "+").split("+"):
        part = part.strip()
        if not part:
            continue
        if part not in INPUTS:
            raise argparse.ArgumentTypeError(
                f"unknown button {part!r}; pick from {', '.join(sorted(INPUTS))}")
        total |= INPUTS[part]
    return total


def main() -> int:
    p = argparse.ArgumentParser(
        description="Join a Modded Online room as a fake second player, for solo testing.")
    p.add_argument("host", help="server IP (127.0.0.1 for the auto-launched local server)")
    p.add_argument("port", type=int, help="server port (26000 by default)")
    p.add_argument("room", help="4-letter room code shown in your lobby")
    p.add_argument("--name", default="Test Dummy", help="name shown in the lobby")
    p.add_argument("--log", default=None,
                   help="file to append this dummy's log to (default: "
                        "test_player_<name>.log in the pack folder)")
    p.add_argument("--char", type=int, default=195,
                   help="character ENT_TYPE (194-213); defaults to one that is not "
                        "the usual host pick, so the two are easy to tell apart")
    p.add_argument("--hold", type=parse_hold, default=0,
                   help="buttons to hold every frame: a number, or names like "
                        "'right' / 'right+jump'. Default: stand still.")
    p.add_argument("--mod", default="Modded Online",
                   help="mod name to present (normally learned from the server)")
    p.add_argument("--modv", default="",
                   help="mod fingerprint to present (normally learned from the server)")
    args = p.parse_args()
    if not (194 <= args.char <= 213):
        p.error("--char must be a character ENT_TYPE in 194-213")
    global LOG_PATH
    if args.log:
        LOG_PATH = args.log
    else:
        # the pack folder (one level up from server/), beside desync_log.txt
        safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in args.name)
        pack = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        LOG_PATH = os.path.join(pack, f"test_player_{safe}.log")
    try:
        # fresh file per launch, so it is always this session's
        with open(LOG_PATH, "w", encoding="utf-8") as f:
            f.write(f"=== test player {args.name} — {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")
    except OSError:
        LOG_PATH = None
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
