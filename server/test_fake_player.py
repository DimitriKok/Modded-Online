"""End-to-end test for the fake player (server/fake_player.py).

The stand-in here is not a stub: it models the LOCKSTEP GATE the way
src/inputSync.lua actually behaves. It only advances a simulated frame once the
dummy's input for that frame has genuinely arrived, it re-sends its own window
while it waits (guiTick's keepalive), it wipes its input buffer on run_start
(beginSession), and every run's first level re-uses lockstep sequence 1. So a
dummy that stops feeding it stalls this exactly as it stalls the game, and the
failure names the frame it died on instead of just timing out.

That fidelity is the point — each of these covers a bug that shipped:
  * the dummy latching onto the PREVIOUS run's frame counter after a restart
    (both runs are sequence 1), then refusing to come back down: the classic
    "every other instant restart hangs on WAITING FOR PLAYERS"
  * a time-based "one vote per round" lockout that made restart do nothing at
    all for 20 s after any round that failed to complete
  * committing input only as far as the game had already reached, so every
    frame cost a network round trip and the game stuttered

Run:  py test_fake_player.py
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import signal
import subprocess
import sys

import server as srv

logging.basicConfig(level=logging.WARNING)

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = "127.0.0.1"
PORT = 26911
INPUT_DELAY = 4
REDUNDANCY = INPUT_DELAY * 2 + 4     # inputSync: INPUT_DELAY * 2 + 4
KEEPALIVE_S = 0.1
NEW_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
CTRL_BREAK = getattr(signal, "CTRL_BREAK_EVENT", signal.SIGTERM)

failures = []


def check(cond, label):
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}")
    if not cond:
        failures.append(label)


class Game(asyncio.DatagramProtocol):
    """Stands in for the Lua client, gate and all."""

    def __init__(self):
        self.cid = f"cid-game-{random.getrandbits(32):08x}"
        self.room = None
        self.slot = None
        self.transport = None
        self.inbox = asyncio.Queue()
        self.lobby = None
        self.run_starts = 0
        self.votes_from_peer = 0
        self.ack_high = 0
        self.peer_datagrams = 0
        self.have = set()        # (seq, frame) the dummy has committed to
        self.committed = {}      # seq -> highest frame it has committed
        self.seq = 0
        self.offset = 0
        self.my_recorded = -1

    # ------------------------------------------------------------- transport

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        msg = json.loads(data.decode())
        t = msg.get("t")
        if t == "state":
            d = msg.get("d") or {}
            s, f, i = d.get("s"), d.get("f"), d.get("i")
            if isinstance(i, list):
                self.peer_datagrams += 1
                for n in range(len(i)):
                    self.have.add((s, f + n))
                top = f + len(i) - 1
                self.committed[s] = max(self.committed.get(s, -1), top)
        elif t == "event":
            self.ack_high = max(self.ack_high, msg["seq"])
            self.send({"t": "ack", "seq": self.ack_high})
            if msg.get("k") == "run_start":
                self.run_starts += 1
            if msg.get("k") == "restart_vote" and msg.get("slot") != self.slot:
                self.votes_from_peer += 1
        elif t == "lobby":
            self.lobby = msg
        else:
            self.inbox.put_nowait(msg)

    def send(self, msg):
        base = {"room": self.room, "cid": self.cid}
        base.update(msg)
        self.transport.sendto(json.dumps(base).encode(), (HOST, PORT))

    async def expect(self, kind, timeout=5.0):
        while True:
            msg = await asyncio.wait_for(self.inbox.get(), timeout)
            if msg.get("t") == kind:
                return msg

    async def heartbeat(self):
        while True:
            self.send({"t": "ping", "ping": 0, "at": 0})
            await asyncio.sleep(0.4)

    # -------------------------------------------------------------- lockstep

    def send_recent_inputs(self):
        """inputSync.sendRecentInputs: the last REDUNDANCY frames we recorded."""
        if self.my_recorded < 0:
            return
        base = max(0, self.my_recorded - REDUNDANCY + 1)
        self.send({"t": "state", "d": {"s": self.seq, "f": base,
                                       "i": [0] * (self.my_recorded - base + 1)}})

    def engage(self, seq):
        """inputSync.engage: new screen -> next sequence, prefill the delay window."""
        self.seq, self.offset, self.my_recorded = seq, 0, INPUT_DELAY - 1
        for f in range(INPUT_DELAY):
            self.have.add((seq, f))   # engage() prefills every roster slot locally

    async def run_frames(self, count, label):
        """Advance `count` simulated frames, stalling exactly like the real gate."""
        loop = asyncio.get_running_loop()
        last_keepalive = 0.0
        for _ in range(count):
            target = self.offset + INPUT_DELAY
            if target > self.my_recorded:
                self.my_recorded = target
                self.send_recent_inputs()
            waited = 0.0
            while (self.seq, self.offset) not in self.have:
                if loop.time() - last_keepalive > KEEPALIVE_S:
                    last_keepalive = loop.time()
                    self.send_recent_inputs()
                await asyncio.sleep(0.005)
                waited += 0.005
                if waited > 8.0:
                    print(f"       stalled at seq {self.seq} frame {self.offset}; "
                          f"dummy had committed {self.committed}")
                    check(False, f"{label} ran without stalling")
                    return False
            self.offset += 1
            await asyncio.sleep(1 / 240)
        return True


async def wait_for(pred, timeout=15.0):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        if pred():
            return True
        await asyncio.sleep(0.05)
    return False


def spawn(room, name, char):
    return subprocess.Popen(
        [sys.executable, os.path.join(HERE, "fake_player.py"),
         HOST, str(PORT), room, "--name", name, "--char", str(char)],
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, creationflags=NEW_GROUP)


def kill(procs):
    for p in procs:
        if p is not None and p.poll() is None:
            p.send_signal(CTRL_BREAK)
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()


async def full_room_test():
    """Three dummies plus you — the way the mod actually starts them: all in the
    LOBBY, before the run. Each must answer your restart press exactly once and
    ignore the other dummies' answers; answering every vote it sees turns one
    press into a flood (three replies, then each replying to the other two…)."""
    loop = asyncio.get_running_loop()
    game = Game()
    await loop.create_datagram_endpoint(lambda: game, local_addr=(HOST, 0))
    game.send({"t": "create", "name": "Host", "port": 0,
               "mod": "Modded Online", "modv": "test-fingerprint"})
    joined = await game.expect("joined")
    game.room, game.slot = joined["room"], joined["slot"]
    alive = asyncio.ensure_future(game.heartbeat())
    bots = [spawn(game.room, f"Dummy{n}", 194 + n) for n in (1, 2, 3)]
    try:
        ok = await wait_for(lambda: game.lobby and len(game.lobby["players"]) == 4, 20.0)
        check(ok, "a full room of four (you plus three stand-ins)")
        if not ok:
            return
        game.send({"t": "ready", "ready": True, "char": 194})
        ok = await wait_for(lambda: all(p["ready"] for p in game.lobby["players"]), 10.0)
        check(ok, "all three ready up so the run can start")
        game.send({"t": "start"})
        check(await wait_for(lambda: game.run_starts == 1), "the run starts with four in the roster")

        cseq = 1
        for press in (1, 2, 3):
            votes = game.votes_from_peer
            game.send({"t": "event", "cseq": cseq, "k": "restart_vote", "p": {}})
            cseq += 1
            await asyncio.sleep(2.5)
            cast = game.votes_from_peer - votes
            check(cast == 3, f"press {press}: exactly one vote per dummy "
                             f"(3 expected, saw {cast})")
    finally:
        kill(bots)
        alive.cancel()


async def main():
    loop = asyncio.get_running_loop()
    _, server = await loop.create_datagram_endpoint(
        lambda: srv.ModdedOnlineServer(dedicated=True), local_addr=("0.0.0.0", PORT))
    tick = asyncio.ensure_future(server.tick())

    game = Game()
    await loop.create_datagram_endpoint(lambda: game, local_addr=(HOST, 0))
    game.send({"t": "create", "name": "Host", "port": 0,
               "mod": "Modded Online", "modv": "test-fingerprint"})
    joined = await game.expect("joined")
    game.room, game.slot = joined["room"], joined["slot"]
    alive = asyncio.ensure_future(game.heartbeat())

    bot = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "fake_player.py"),
         HOST, str(PORT), game.room, "--name", "Test Dummy"],
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
        creationflags=NEW_GROUP)
    try:
        print("\n[1] it joins and readies up")
        ok = await wait_for(lambda: game.lobby and len(game.lobby["players"]) == 2)
        check(ok, "appears in the lobby as a second player")
        if not ok:
            return 1
        entry = [p for p in game.lobby["players"] if p["slot"] != game.slot][0]
        check(entry["slot"] == 2, "takes slot 2 (the game keeps slot 1 / world host)")
        # it learns the room's mod fingerprint from the server, so it can join a
        # room running any content mods without being told what they are
        check(entry["name"] == "Test Dummy", "adopts the room's mod fingerprint and joins")
        ok = await wait_for(lambda: any(p["ready"] for p in game.lobby["players"]
                                        if p["slot"] != game.slot))
        check(ok, "readies up so the host can start")

        game.send({"t": "ready", "ready": True, "char": 194})
        await wait_for(lambda: all(p["ready"] for p in game.lobby["players"]))
        game.send({"t": "start"})
        check(await wait_for(lambda: game.run_starts == 1),
              "the run starts with both players in the roster")

        print("\n[2] it feeds the lockstep, and runs AHEAD so the game never waits")
        game.peer_datagrams = 0
        game.engage(1)
        ok = await game.run_frames(240, "the first level")
        if ok:
            lead = game.committed.get(1, -1) - game.offset
            check(lead >= 45, f"stays well ahead of the game (lead {lead} frames)")
            check(game.peer_datagrams <= 30,
                  f"is quiet: {game.peer_datagrams} datagrams for 240 frames "
                  "(answering frame-for-frame is what caused the stutter)")

        print("\n[3] a level transition (a new sequence)")
        game.engage(2)
        ok = await game.run_frames(60, "the transition")
        game.engage(3)
        ok = ok and await game.run_frames(120, "the next level")

        print("\n[4] REPEATED instant restarts — every run re-uses sequence 1")
        cseq = 1
        for attempt in range(1, 4):
            before, votes = game.run_starts, game.votes_from_peer
            game.send({"t": "event", "cseq": cseq, "k": "restart_vote", "p": {}})
            cseq += 1
            check(await wait_for(lambda v=votes: game.votes_from_peer > v, 5.0),
                  f"restart {attempt}: the dummy votes yes, so one press is enough")
            game.send({"t": "restart", "n": f"r{attempt}"})
            check(await wait_for(lambda b=before: game.run_starts > b, 5.0),
                  f"restart {attempt}: the run restarts")
            # the regeneration freeze: the sim is stopped, but the network
            # keepalive keeps re-sending the OLD run's window the whole time —
            # this is what used to make the dummy latch onto a stale frame count
            for _ in range(10):
                game.send_recent_inputs()
                await asyncio.sleep(0.1)
            game.have.clear()        # beginSession wipes inputBuf
            game.engage(1)           # every run's first level is sequence 1
            if not await game.run_frames(240, f"1-1 after restart {attempt}"):
                break
            check(True, f"restart {attempt}: the new run plays on without stalling")
            await asyncio.sleep(3.2)  # clear the server's restart dedup window

        pass
    finally:
        if bot.poll() is None:
            bot.send_signal(CTRL_BREAK)
            try:
                bot.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bot.kill()
        alive.cancel()
        tick.cancel()

    print("\n[5] a FULL ROOM: three dummies, started from the lobby")
    await full_room_test()

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
