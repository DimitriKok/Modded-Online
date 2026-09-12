"""End-to-end test for the Modded Online server using two simulated game clients.

Each fake client behaves like the Lua mod does: it runs its own UDP listener
(declared in `hello`/`join`), sends events with client sequence numbers, and
acks server-sequenced events.

Run:  py test_server.py
"""

from __future__ import annotations

import asyncio
import json
import math
import random
import sys

import server as srv

HOST = "127.0.0.1"
SERVER_PORT = 26900


class FakeClient(asyncio.DatagramProtocol):
    def __init__(self, name: str, listen_port: int):
        self.name = name
        self.listen_port = listen_port
        self.cid = f"cid-{name}-{random.getrandbits(32):08x}"
        self.room = None
        self.slot = None
        self.inbox: asyncio.Queue = asyncio.Queue()
        self.applied_events: list[dict] = []
        self.states_seen: list[dict] = []
        self.next_cseq = 1
        self.acked_cseqs = []
        self.deaf = False
        self.mute = False
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        msg = json.loads(data.decode("utf-8"))
        if self.deaf and msg.get("t") == "event":
            return   # simulate a dropped datagram / a client that stopped hearing
        if msg.get("t") == "event":
            seq = msg["seq"]
            already = any(e["seq"] == seq for e in self.applied_events)
            if not already:
                self.applied_events.append(msg)
            # ack cumulative highest contiguous seq
            self.applied_events.sort(key=lambda e: e["seq"])
            high = 0
            for e in self.applied_events:
                if e["seq"] == high + 1:
                    high = e["seq"]
            self.send({"t": "ack", "seq": high})
            return
        if msg.get("t") == "state":
            self.states_seen.append(msg)
            return
        if msg.get("t") == "event_ack":
            self.acked_cseqs.append(msg.get("cseq"))
            return
        self.inbox.put_nowait(msg)

    def send(self, msg: dict):
        if self.mute:
            return   # the game's Lua VM is blocked: no callbacks, nothing sent
        base = {"room": self.room, "cid": self.cid}
        base.update(msg)
        self.transport.sendto(json.dumps(base).encode("utf-8"), (HOST, SERVER_PORT))

    async def expect(self, msg_type: str, timeout: float = 3.0) -> dict:
        while True:
            msg = await asyncio.wait_for(self.inbox.get(), timeout)
            if msg.get("t") == msg_type:
                return msg

    async def create_room(self, mod="Spelunky 2.5", modv="2025.12-dev0"):
        self.send({"t": "create", "name": self.name, "port": self.listen_port,
                   "mod": mod, "modv": modv})
        joined = await self.expect("joined")
        self.room, self.slot = joined["room"], joined["slot"]
        return joined

    async def join_room(self, code: str, mod="Spelunky 2.5", modv="2025.12-dev0"):
        self.room = code
        self.send({"t": "join", "name": self.name, "port": self.listen_port,
                   "mod": mod, "modv": modv})
        joined = await self.expect("joined")
        self.slot = joined["slot"]
        return joined

    async def matchmake(self, mod="Spelunky 2.5", modv="2025.12-dev0", started=False, find=False):
        self.room = None  # the server assigns/creates the room and returns it
        msg = {"t": "matchmake", "name": self.name, "port": self.listen_port,
               "mod": mod, "modv": modv}
        if started:
            msg["started"] = 1  # drop into a game already in progress (late-join)
        if find:
            msg["find"] = 1     # find an open lobby but DON'T open one (Start Queue)
        self.send(msg)
        joined = await self.expect("joined")
        self.room, self.slot = joined["room"], joined["slot"]
        return joined

    def send_event(self, kind: str, payload):
        self.send({"t": "event", "cseq": self.next_cseq, "k": kind, "p": payload})
        self.next_cseq += 1


async def start_fake_client(name: str, port: int) -> FakeClient:
    loop = asyncio.get_running_loop()
    client = FakeClient(name, port)
    await loop.create_datagram_endpoint(lambda: client, local_addr=(HOST, port))
    return client


checks_failed = 0


def check(cond, label):
    global checks_failed
    status = "PASS" if cond else "FAIL"
    if not cond:
        checks_failed += 1
    print(f"  [{status}] {label}")


async def run_tests():
    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_datagram_endpoint(
        srv.ModdedOnlineServer, local_addr=(HOST, SERVER_PORT))
    ticker = asyncio.ensure_future(protocol.tick())

    alice = await start_fake_client("Alice", 26901)
    bob = await start_fake_client("Bob", 26902)

    print("lobby flow:")
    joined = await alice.create_room()
    check(joined["slot"] == 1, "host gets slot 1")
    code = alice.room

    await bob.join_room(code)
    check(bob.slot == 2, "second player gets slot 2")
    lobby = await alice.expect("lobby")
    while len(lobby["players"]) < 2:
        lobby = await alice.expect("lobby")
    check([p["name"] for p in lobby["players"]] == ["Alice", "Bob"],
          "host sees both players in lobby broadcast")
    check(lobby.get("public") is False,
          "a hosted room's lobby broadcast is flagged private (public=False)")

    check(joined.get("srv") == srv.SERVER_VERSION,
          "the joined reply names the server's build, so a client can spot a stale server")

    print("mod compatibility gate:")
    eve = await start_fake_client("Eve", 26903)
    eve.room = code
    eve.send({"t": "join", "name": "Eve", "port": eve.listen_port,
              "mod": "Spelunky 2.5", "modv": "9.9-other"})
    err = await eve.expect("error")
    check(err["err"] == "mod_mismatch", "client with wrong mod version is rejected")

    print("run start / seed authority:")
    alice.send({"t": "start"})
    err = await alice.expect("error")
    check(err["err"] == "not_all_ready", "start refused while players unready")

    alice.send({"t": "ready", "ready": True})
    bob.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    bob.send({"t": "start"})
    err = await bob.expect("error")
    check(err["err"] == "not_host", "non-host cannot start the run")

    alice.send({"t": "start"})
    await asyncio.sleep(0.5)
    a_start = [e for e in alice.applied_events if e["k"] == "run_start"]
    b_start = [e for e in bob.applied_events if e["k"] == "run_start"]
    check(a_start and b_start, "run_start event reaches both clients")
    check(a_start and b_start and a_start[0]["p"]["seed"] == b_start[0]["p"]["seed"],
          "both clients receive the same adventure seed")
    check(a_start and b_start and a_start[0]["p"].get("delay") == b_start[0]["p"].get("delay"),
          "both clients receive the same negotiated input delay")
    check(a_start and a_start[0]["p"].get("delay") == srv.MIN_INPUT_DELAY,
          "no ping reported yet -> input delay is the floor")

    print("event channel ordering and dedup:")
    alice.send_event("perk", {"key": "bloodMoney", "value": True})
    bob.send_event("kill", {"netId": 17})
    alice.send_event("transition", {"toWorld": "SP25-JUNGLE"})
    # duplicate resend of alice's first event (same cseq) must not duplicate
    alice.send({"t": "event", "cseq": 1, "k": "perk", "p": {"key": "bloodMoney", "value": True}})
    await asyncio.sleep(0.8)

    a_seqs = [e["seq"] for e in alice.applied_events]
    b_seqs = [e["seq"] for e in bob.applied_events]
    check(a_seqs == sorted(a_seqs) and b_seqs == sorted(b_seqs),
          "events applied in global sequence order on both clients")
    check(a_seqs == b_seqs, "both clients saw the identical event sequence")
    perk_events = [e for e in bob.applied_events if e["k"] == "perk"]
    check(len(perk_events) == 1, "duplicate client resend is deduplicated")
    check(perk_events and perk_events[0]["slot"] == 1, "event stamped with origin slot")

    # A GAP must never be acked. The client drops an event the moment it is acked,
    # so acking one it cannot yet apply loses it permanently -- that is how a
    # `restart vote CAST` ended up never coming back (votes 0/2, instant restart
    # doing nothing), and the same hole eats any world-affecting event silently.
    gap_before = len(bob.applied_events)
    ahead = alice.next_cseq + 1          # skip one: arrives before its predecessor
    alice.send({"t": "event", "cseq": ahead, "k": "gapped", "p": {"n": 1}})
    await asyncio.sleep(0.4)
    check(not any(e["k"] == "gapped" for e in bob.applied_events),
          "an event that arrives ahead of its predecessor is not applied yet")
    check(not any(a == ahead for a in alice.acked_cseqs),
          "…and is NOT acked, so the real client keeps re-sending it")
    # now the missing one lands, and the client re-sends the one it never saw acked
    alice.send({"t": "event", "cseq": alice.next_cseq, "k": "filler", "p": {}})
    alice.next_cseq += 2
    await asyncio.sleep(0.3)
    alice.send({"t": "event", "cseq": ahead, "k": "gapped", "p": {"n": 1}})
    await asyncio.sleep(0.4)
    check(any(e["k"] == "gapped" for e in bob.applied_events),
          "…and it is applied once the gap is filled, instead of being lost")
    check(len(bob.applied_events) == gap_before + 2, "both events arrive, exactly once each")

    print("a client that misses one event still recovers:")
    # Bob goes deaf for longer than the old give-up window (EVENT_RESEND_MAX was
    # 40 retries = 10 s). He applies events strictly in order, so the one he misses
    # holds back every later one; if the server ever stops re-sending it, his
    # reliable channel is dead for the rest of the run and he silently ignores
    # every world event from then on -- which is exactly how instant restart came
    # to do nothing while the game itself played on perfectly.
    bob_before = len(bob.applied_events)
    bob.deaf = True
    alice.send_event("missed", {"n": 1})
    for _ in range(24):                # 12 s, past the old 10 s give-up
        bob.send({"t": "ping", "ping": 0, "at": 0})   # still alive, just not hearing
        alice.send({"t": "ping", "ping": 0, "at": 0})
        await asyncio.sleep(0.5)
    check(len(bob.applied_events) == bob_before, "…he misses it while deaf, as set up")
    alice.send_event("after", {"n": 2})
    bob.deaf = False
    ok = False
    for _ in range(40):
        await asyncio.sleep(0.25)
        kinds = [e["k"] for e in bob.applied_events]
        if "missed" in kinds and "after" in kinds:
            ok = True
            break
    check(ok, "the server keeps re-sending, so he catches up instead of wedging forever")
    check([e["seq"] for e in bob.applied_events] == sorted(e["seq"] for e in bob.applied_events),
          "and everything is still applied in order")

    print("pinned adventure seed:")

    print("a loading client is not mistaken for a dead one:")
    # While a level generates, a client's Lua callbacks do not run at all, so it
    # sends nothing however healthy it is. Silence alone therefore cannot tell
    # "loading" from "crashed": at RUN_TIMEOUT_S a heavy floor got the player
    # evicted for walking into an exit door, and an evicted host closes the room.
    # The client warns us before it blocks; that has to actually buy it time.
    check(srv.LOADING_GRACE_S > srv.RUN_TIMEOUT_S,
          "the loading grace is longer than the in-run drop timer")
    quiet = srv.RUN_TIMEOUT_S + 4.0
    bob.send({"t": "loading"})
    await asyncio.sleep(0.2)
    bob.mute = True                     # the Lua VM is blocked: nothing goes out
    for _ in range(int(quiet / 0.5)):
        alice.send({"t": "ping", "ping": 0, "at": 0})   # the other player plays on
        await asyncio.sleep(0.5)
    bob.mute = False
    room_now = protocol.rooms.get(code)
    check(room_now is not None and bob.cid in room_now.clients,
          f"survives {quiet:.0f}s of silence ({srv.RUN_TIMEOUT_S:.0f}s would have "
          "dropped it) after announcing the load")
    # …and the grace ends as soon as it is simulating again, so a client that
    # dies later is still dropped promptly rather than lingering for a minute
    bob.send({"t": "state", "d": {"s": 1, "f": 0, "i": [0]}})
    await asyncio.sleep(0.3)
    client_now = protocol.rooms[code].clients[bob.cid]
    check(client_now.loading_until == 0.0,
          "an input datagram cancels the grace immediately")
    # that state datagram was relayed to Alice; don't let it count against the
    # relay checks below, which start from zero
    alice.states_seen.clear()
    bob.states_seen.clear()

    print("state relay:")
    alice.send({"t": "state", "d": {"x": 10.5, "y": 80.25, "vx": 0.1}})
    await asyncio.sleep(0.3)
    check(len(bob.states_seen) == 1 and bob.states_seen[0]["slot"] == 1,
          "state datagram relayed to the other client with origin slot")
    check(len(alice.states_seen) == 0, "state not echoed back to sender")

    print("reliability (dropped datagram recovery):")
    # simulate bob missing an event: stop acking, ensure resend arrives
    before = len(bob.applied_events)
    alice.send_event("chat", {"text": "hello"})
    await asyncio.sleep(1.0)
    check(len(bob.applied_events) == before + 1, "event eventually delivered via resend loop")

    print("disconnect handling:")
    # bob sends a lockstep input datagram, then drops: the server must hand the
    # survivor bob's last input tail so the departure resolves deterministically
    bob_tail = {"s": 1, "f": 3, "i": [11, 22, 33]}
    bob.send({"t": "state", "d": bob_tail})
    await asyncio.sleep(0.1)
    bob.send({"t": "leave"})
    await asyncio.sleep(0.5)
    left = [e for e in alice.applied_events if e["k"] == "player_left"]
    check(left and left[0]["p"]["slot"] == 2, "remaining client told that slot 2 left")
    check(left and left[0]["p"].get("last") == bob_tail,
          "player_left carries the leaver's last input tail for deterministic drop")

    print("run reset (same lobby plays again):")
    alice.send({"t": "reset"})
    lobby = await alice.expect("lobby")
    check(lobby["started"] is False, "room reopened after the run ended")
    alice.send({"t": "ready", "ready": True})
    await alice.expect("lobby")
    # bob has left, so this run is solo: even with a high reported ping there's
    # no peer to wait on, so the delay stays at the floor
    alice.send({"t": "ping", "at": 0, "ping": 180})
    await asyncio.sleep(0.1)
    alice.send({"t": "start"})
    await asyncio.sleep(0.5)
    starts = [e for e in alice.applied_events if e["k"] == "run_start"]
    check(len(starts) == 2, "the same room can start a second run")

    check(starts[0]["p"]["seed"] != starts[1]["p"]["seed"], "the second run gets a fresh seed")
    check(len(starts) == 2 and starts[1]["p"].get("delay") == srv.MIN_INPUT_DELAY,
          "solo run (no peer) keeps the input delay at the floor")

    print("a seed sent by an older client is ignored:")
    # Pinning was a test aid for reproducing a bad floor, and it never worked
    # properly -- an instant restart re-rolled the seed it was meant to replay.
    # It is gone. A client from before the removal still puts a `seed` field on
    # start and restart, and the public server sees both old and new clients, so
    # what matters now is that the field cannot steer a run.
    pin = [0x057AF45C, 0x68CB3C2B]
    alice.send({"t": "reset"})
    await alice.expect("lobby")
    alice.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    alice.send({"t": "start", "seed": pin})
    await asyncio.sleep(0.5)
    starts = [e for e in alice.applied_events if e["k"] == "run_start"]
    check(starts[-1]["p"]["seed"] != pin, "a seed on 'start' does not pin the run")
    await asyncio.sleep(srv.RESTART_DEDUP_S + 0.3)
    alice.send({"t": "restart", "n": "pin-1", "seed": pin})
    await asyncio.sleep(0.5)
    starts = [e for e in alice.applied_events if e["k"] == "run_start"]
    check(starts[-1]["p"]["seed"] != pin, "a seed on 'restart' does not pin it either")

    print("input-delay negotiation (one-way latency, not RTT):")
    fm = srv.FRAME_MS
    m = srv.INPUT_DELAY_MARGIN

    def delay_for(*pings):
        room = srv.Room("TEST", "m", "v")
        for i, p in enumerate(pings, start=1):
            c = srv.Client(("127.0.0.1", 100 + i), 100 + i, f"p{i}", f"cid{i}")
            c.slot = i
            c.ping_ms = p
            room.clients[c.client_id] = c
        return protocol.negotiate_input_delay(room)

    check(delay_for(300) == srv.MIN_INPUT_DELAY, "solo player -> floor")
    check(delay_for(10, 10) == max(srv.MIN_INPUT_DELAY, math.ceil(10 / fm) + m),
          "two low-ping players -> near the floor")
    # one 300 ms player among a 20 ms player: budget is the one-way (300+20)/2,
    # NOT 300 — so meaningfully lower input lag than charging the full RTT
    one_way = math.ceil(((300 + 20) / 2) / fm) + m
    check(delay_for(300, 20) == one_way, "asymmetric lobby budgets the one-way c2c latency")
    check(one_way < math.ceil(300 / fm) + m, "one-way budget beats the old full-RTT budget")
    check(delay_for(2000, 2000) == srv.MAX_INPUT_DELAY, "absurd ping is capped")

    print("relay mode (declared port 0 -> replies to observed source):")
    rita = await start_fake_client("Rita", 26905)
    rita.send({"t": "create", "name": "Rita", "port": 0,
               "mod": "Spelunky 2.5", "modv": "2025.12-dev0"})
    joined = await rita.expect("joined")
    rita.room = joined["room"]
    check(joined["slot"] == 1,
          "port-0 client receives pushes at its source address (no forwarding)")

    print("instant restart (host only, fresh seed, ready state irrelevant):")
    carol = await start_fake_client("Carol", 26906)
    dave = await start_fake_client("Dave", 26907)
    await carol.create_room()
    await dave.join_room(carol.room)

    # Many checks below reuse alice/rita/carol/dave after seconds of sleeps in other
    # sections. A client goes silent = dropped (RUN_TIMEOUT_S mid-run, CLIENT_TIMEOUT_S
    # in a lobby). Heartbeat these long-lived witnesses so the final host-departure /
    # shutdown checks reflect real semantics, not who aged out first. Cancelled just
    # before those checks so the rooms can actually close.
    async def witness_heartbeat():
        while True:
            await asyncio.sleep(1.0)
            for c in (alice, rita, carol, dave):
                c.send({"t": "ping"})
    keepalive = asyncio.ensure_future(witness_heartbeat())
    carol.send({"t": "ready", "ready": True})
    dave.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    carol.send({"t": "start"})
    await asyncio.sleep(0.5)
    dave.send({"t": "restart"})
    err = await dave.expect("error")
    check(err["err"] == "not_host", "non-host restart is refused")
    dave.send({"t": "ready", "ready": False})  # unready mid-run
    await asyncio.sleep(0.2)
    carol.send({"t": "restart", "n": "nonce-1"})
    await asyncio.sleep(0.5)
    c_starts = [e for e in carol.applied_events if e["k"] == "run_start"]
    d_starts = [e for e in dave.applied_events if e["k"] == "run_start"]
    check(len(c_starts) == 2 and len(d_starts) == 2,
          "host restart re-broadcasts run_start even with an unready player")
    check(len(c_starts) == 2 and c_starts[0]["p"]["seed"] != c_starts[1]["p"]["seed"],
          "the restarted run gets a fresh seed")
    carol.send({"t": "restart", "n": "nonce-1"})  # resend of the same request
    await asyncio.sleep(0.5)
    c_starts = [e for e in carol.applied_events if e["k"] == "run_start"]
    check(len(c_starts) == 2, "a resent restart (same nonce) is served once")
    carol.send({"t": "reset"})
    await asyncio.sleep(0.2)
    carol.send({"t": "restart", "n": "nonce-2"})
    await asyncio.sleep(0.5)
    c_starts = [e for e in carol.applied_events if e["k"] == "run_start"]
    check(len(c_starts) == 3, "host restart also starts a run from the post-wipe lobby")

    print("matchmaking (find-or-create a public room with the same mod list):")
    mm1 = await start_fake_client("MM1", 26910)
    mm2 = await start_fake_client("MM2", 26911)
    mm3 = await start_fake_client("MM3", 26912)
    j1 = await mm1.matchmake()
    check(j1["slot"] == 1, "first matchmaker opens a new public room as slot 1")
    mm1_lobby = await mm1.expect("lobby")
    check(mm1_lobby.get("public") is True,
          "a matchmaking room's lobby broadcast is flagged public (public=True)")
    j2 = await mm2.matchmake()
    check(mm2.room == mm1.room, "second matchmaker with the same mod list joins the same room")
    check(j2["slot"] == 2, "second matchmaker gets slot 2 in that room")
    await mm3.matchmake(modv="other-modlist")
    check(mm3.room != mm1.room, "a different mod list opens a separate room")

    prev_room = mm1.room
    await mm1.matchmake()  # resend / re-request from a client already placed
    check(mm1.room == prev_room, "a matchmake resend keeps the client in its existing room")
    default_public = [r for r in protocol.rooms.values()
                      if r.public and r.mod_version == "2025.12-dev0"]
    check(len(default_public) == 1 and len(default_public[0].clients) == 2,
          "the resend created no duplicate room and no duplicate membership")

    mm4 = await start_fake_client("MM4", 26913)
    mm5 = await start_fake_client("MM5", 26914)
    await mm4.create_room()  # a private (friend / dedicated) room, same mod list
    await mm5.matchmake()
    check(mm5.room != mm4.room,
          "matchmaking never hands out a private room - it uses/opens a public one")
    check(mm5.room == mm1.room, "matchmaking filled the existing open public room")

    print("hosting makes a PRIVATE room matchmaking never hands out:")
    hoster = await start_fake_client("Hoster", 26915)
    finder = await start_fake_client("Finder", 26916)
    fjoin = await start_fake_client("FJoin", 26917)
    await hoster.create_room(modv="hostmods")  # hosting is always private
    check(not any(r.code == hoster.room and r.public for r in protocol.rooms.values()),
          "a hosted room is private, not public")
    await finder.matchmake(modv="hostmods")
    check(finder.room != hoster.room,
          "matchmaking never joins a hosted room - it opens its own public room")
    check(any(r.code == finder.room and r.public for r in protocol.rooms.values()),
          "the matchmaker's own room is public")
    await fjoin.join_room(hoster.room, modv="hostmods")
    check(fjoin.room == hoster.room, "a friend can still join the hosted room by its code")
    rooms_before = len(protocol.rooms)
    hoster.send({"t": "create", "name": "Hoster", "port": hoster.listen_port,
                 "mod": "Spelunky 2.5", "modv": "hostmods"})  # create resend
    await asyncio.sleep(0.2)
    check(len(protocol.rooms) == rooms_before, "a create resend does not spawn a duplicate room")

    print("public room: any player may instant-restart; simultaneous presses coalesce:")
    pubA = await start_fake_client("PubA", 26918)
    pubB = await start_fake_client("PubB", 26919)
    await pubA.matchmake(modv="restart-test")
    await pubB.matchmake(modv="restart-test")
    check(pubA.room == pubB.room, "the two restart-test matchmakers share one public room")
    pubA.send({"t": "ready", "ready": True})
    pubB.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    pubA.send({"t": "start"})
    await asyncio.sleep(0.5)
    base = len([e for e in pubB.applied_events if e["k"] == "run_start"])
    pubB.send({"t": "restart", "n": "pub-1"})  # a NON-host restart
    await asyncio.sleep(0.5)
    after = len([e for e in pubB.applied_events if e["k"] == "run_start"])
    check(after == base + 1, "a non-host CAN restart a public room (everyone gets run_start)")
    pubA.send({"t": "reset"})  # wipe reopens the room -> a fresh restart opportunity
    await asyncio.sleep(0.2)
    pubA.send({"t": "restart", "n": "pub-2a"})
    pubB.send({"t": "restart", "n": "pub-2b"})  # simultaneous, different nonce
    await asyncio.sleep(0.5)
    after2 = len([e for e in pubB.applied_events if e["k"] == "run_start"])
    check(after2 == after + 1, "simultaneous public restart presses coalesce into one run")

    print("late-join: matchmake into a STARTED game, added on the next run:")
    lj1 = await start_fake_client("LJ1", 26930)
    lj2 = await start_fake_client("LJ2", 26931)
    lj3 = await start_fake_client("LJ3", 26932)
    await lj1.matchmake(modv="latejoin-test")
    await lj2.matchmake(modv="latejoin-test")
    check(lj1.room == lj2.room, "the two latejoin-test matchmakers share a public room")
    lj1.send({"t": "ready", "ready": True})
    lj2.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    lj1.send({"t": "start"})
    await asyncio.sleep(0.5)
    starts0 = [e for e in lj1.applied_events if e["k"] == "run_start"]
    check(len(starts0) == 1 and len(starts0[0]["p"]["slots"]) == 2,
          "the run starts with the 2 original players")
    # a third player drops into the STARTED game
    joined = await lj3.matchmake(modv="latejoin-test", started=True)
    check(lj3.room == lj1.room, "matchmake(started) drops the late-joiner into the running room")
    check(int(joined.get("base", 0)) > 0,
          "a late-joiner's reliable channel is baselined past the backlog")
    await asyncio.sleep(0.3)
    starts_run = [e for e in lj1.applied_events if e["k"] == "run_start"]
    check(len(starts_run) == 1, "a late-joiner does NOT restart the running game")
    # they ready up, then the party restarts -> now the late-joiner is included
    lj3.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    lj1.send({"t": "restart", "n": "lj-1"})
    await asyncio.sleep(0.5)
    starts2 = [e for e in lj1.applied_events if e["k"] == "run_start"]
    lj3_starts = [e for e in lj3.applied_events if e["k"] == "run_start"]
    check(len(starts2) == 2 and len(starts2[-1]["p"]["slots"]) == 3,
          "the next run includes the readied late-joiner (3 players)")
    check(len(lj3_starts) == 1,
          "the late-joiner gets run_start for the run they join (not the backlog)")

    print("late-join by CODE: drop into a private game already in progress:")
    cj1 = await start_fake_client("CJ1", 26940)
    cj2 = await start_fake_client("CJ2", 26941)
    cj3 = await start_fake_client("CJ3", 26942)
    await cj1.create_room(modv="codejoin-test")  # a private (code-only) room
    await cj2.join_room(cj1.room, modv="codejoin-test")
    cj1.send({"t": "ready", "ready": True})
    cj2.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    cj1.send({"t": "start"})
    await asyncio.sleep(0.5)
    joined = await cj3.join_room(cj1.room, modv="codejoin-test")  # by CODE, mid-run
    check(int(joined.get("base", 0)) > 0,
          "joining a STARTED room by code is a late-join (channel baselined, not refused)")
    await asyncio.sleep(0.3)
    cj1_starts = [e for e in cj1.applied_events if e["k"] == "run_start"]
    check(len(cj1_starts) == 1, "a code late-join does NOT restart the running game")
    cj3.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    cj1.send({"t": "restart", "n": "cj-1"})  # host restart (private room)
    await asyncio.sleep(0.5)
    cj1_starts2 = [e for e in cj1.applied_events if e["k"] == "run_start"]
    check(len(cj1_starts2) == 2 and len(cj1_starts2[-1]["p"]["slots"]) == 3,
          "the next run includes the code late-joiner (3 players)")

    print("Phase 2 mid-run join: join_pending signal + joinfloor resync:")
    pj1 = await start_fake_client("PJ1", 26950)
    pj2 = await start_fake_client("PJ2", 26951)
    pj3 = await start_fake_client("PJ3", 26952)
    await pj1.create_room(modv="phase2-test")
    await pj2.join_room(pj1.room, modv="phase2-test")
    pj1.send({"t": "ready", "ready": True})
    pj2.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    pj1.send({"t": "start"})
    await asyncio.sleep(0.5)
    await pj3.join_room(pj1.room, modv="phase2-test")  # late-join by code, mid-run
    pj3.send({"t": "ready", "ready": True})             # readying -> join_pending to the party
    await asyncio.sleep(0.3)
    jp = [e for e in pj1.applied_events if e["k"] == "join_pending"]
    check(len(jp) == 1 and jp[0]["p"]["slot"] == pj3.slot,
          "a readied mid-run late-joiner emits a join_pending to the party")
    starts_before = len([e for e in pj1.applied_events if e["k"] == "run_start"])
    # the host folds them in at the party's CURRENT floor (2-1), keeping progress.
    # the evolved floor seed EXCEEDS 32 bits — it must pass through verbatim (a
    # 32-bit mask / re-randomize here is what put the joiner on a different world).
    big_seed = [5_000_000_000, 222]  # 5e9 > 2**32
    snap = {"meta": {"lc": 7}, "pl": {"1": {"hp": 4, "bo": 2}}}  # host state (level_count etc.)
    pj1.send({"t": "joinfloor", "w": 2, "l": 1, "th": 6,
              "a": big_seed[0], "b": big_seed[1], "ord": 4, "st": snap})
    await asyncio.sleep(0.5)
    p2_starts = [e for e in pj1.applied_events if e["k"] == "run_start"]
    check(len(p2_starts) == starts_before + 1, "joinfloor produces one run_start")
    last = p2_starts[-1]["p"]
    check(last.get("floor") == {"w": 2, "l": 1, "t": 6} and last.get("ord") == 4,
          "the join run_start carries the party's floor + ordinal (progress kept, not 1-1)")
    check(len(last["slots"]) == 3, "the join run_start roster includes the late-joiner (3 players)")
    check(last["seed"] == big_seed,
          "the join run_start passes the host's >32-bit floor seed through EXACTLY (same world)")
    check(last.get("st") == snap,
          "the join run_start carries the host's state snapshot (level_count etc. — same world)")

    print("rejoin after leaving mid-run: a returning leaver is baselined + folds back in:")
    rj1 = await start_fake_client("RJ1", 26960)
    rj2 = await start_fake_client("RJ2", 26961)
    await rj1.create_room(modv="rejoin-test")
    await rj2.join_room(rj1.room, modv="rejoin-test")
    rj1.send({"t": "ready", "ready": True})
    rj2.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    rj1.send({"t": "start"})
    await asyncio.sleep(0.5)
    rj_room = rj1.room
    # RJ2 sends a couple of reliable events while in the run, advancing the server's
    # per-client receive sequence (next_client_seq) past 1.
    rj2.send_event("kill", {"netId": 1})
    rj2.send_event("kill", {"netId": 2})
    await asyncio.sleep(0.2)
    check(protocol.rooms[rj_room].clients[rj2.cid].next_client_seq == 3,
          "the server tracks the in-run player's outbound event sequence")
    # RJ2 ends their adventure (soft leave): out of the run, still in the room. The
    # give-up leave that would drop them fully hasn't fired (or their leave datagram
    # was lost / they briefly disconnected) — so their cid is still present and a
    # rejoin is a RECONNECT, not a fresh late-join.
    rj2.send({"t": "endrun"})
    await asyncio.sleep(0.3)
    check(rj_room in protocol.rooms and protocol.rooms[rj_room].clients[rj2.cid].left_run,
          "the leaver is out of the run (left_run) but still in the room")
    # RJ2 comes back mid-run with the SAME cid (reconnect branch of join_room)
    rejoined = await rj2.join_room(rj_room, modv="rejoin-test")
    check(int(rejoined.get("base", 0)) > 0,
          "a returning leaver's reliable channel is baselined past the running backlog")
    check(protocol.rooms[rj_room].clients[rj2.cid].late_pending,
          "a returning leaver is marked late_pending (so the next run start includes them)")
    check(protocol.rooms[rj_room].clients[rj2.cid].next_client_seq == 1,
          "a reconnect resets the receive sequence so the returning client's events aren't dropped")
    starts_before = len([e for e in rj1.applied_events if e["k"] == "run_start"])
    # readying up while out of the run tells the party to fold them in at the next floor
    rj2.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.3)
    jp = [e for e in rj1.applied_events
          if e["k"] == "join_pending" and e["p"]["slot"] == rj2.slot]
    check(len(jp) >= 1, "a returning leaver readying up emits a join_pending to the party")
    check(len([e for e in rj1.applied_events if e["k"] == "run_start"]) == starts_before,
          "the returning leaver does NOT restart the running game")
    # The returning client restarted its own outbound sequence at cseq=1 (resetChannel
    # on connect); its events must now actually reach the party, not be acked-and-dropped.
    rj2.next_cseq = 1  # mirror the real client's resetChannel
    rj2.send_event("perk", {"key": "backAndPlaying"})
    await asyncio.sleep(0.3)
    got = [e for e in rj1.applied_events
           if e["k"] == "perk" and e["p"].get("key") == "backAndPlaying"]
    check(len(got) == 1, "the returning client's reliable events propagate again after reconnect")
    for client in (rj1, rj2):
        client.send({"t": "leave"})
    await asyncio.sleep(0.3)

    print("matchmake START QUEUE (find-only): errors when nothing open, then fills a lobby:")
    mq1 = await start_fake_client("MQ1", 26970)
    mq2 = await start_fake_client("MQ2", 26971)
    mq3 = await start_fake_client("MQ3", 26972)
    # Start Queue with nothing open must NOT open a room — it reports back so the
    # client can offer "start new" vs "join in progress".
    mq1.send({"t": "matchmake", "name": mq1.name, "port": mq1.listen_port,
              "mod": "Spelunky 2.5", "modv": "queue-test", "find": 1})
    err = await mq1.expect("error")
    check(err["err"] == "no_unstarted_game",
          "find-only queue with nothing open errors (no_unstarted_game)")
    check(not any(r.mod_version == "queue-test" for r in protocol.rooms.values()),
          "a find-only queue does NOT open a room")
    # START NEW GAME: a default matchmake opens a public lobby
    await mq2.matchmake(modv="queue-test")
    check(mq2.room is not None, "START NEW GAME opens a public lobby")
    # now a find-only queue DOES join that open lobby
    await mq3.matchmake(modv="queue-test", find=True)
    check(mq3.room == mq2.room, "a find-only queue joins the now-open lobby")
    for client in (mq1, mq2, mq3):
        client.send({"t": "leave"})
    await asyncio.sleep(0.3)

    print("matchmaking picks the LOWEST-PING room:")
    # Synthetic candidate rooms, the way delay_for / make_server_with_lone_host build
    # objects directly. Their members all push to ONE real drain socket: a push to a
    # dead address makes Windows drop later replies on the server's own socket.
    sink = await start_fake_client("Sink", 26979)

    def seed_public_room(code, modv, pings, started=False):
        room = srv.Room(code, "Spelunky 2.5", modv)
        room.public = True
        room.started = started
        for i, p in enumerate(pings, start=1):
            c = srv.Client((HOST, sink.listen_port), sink.listen_port,
                           f"{code}{i}", f"cid-{code}-{i}")
            c.slot = i
            c.ping_ms = p
            room.clients[c.client_id] = c
        protocol.rooms[code] = room
        return room

    def score(*pings):
        room = srv.Room("SCOR", "m", "v")
        for i, p in enumerate(pings, start=1):
            c = srv.Client(("127.0.0.1", 200 + i), 200 + i, f"s{i}", f"scid{i}")
            c.slot = i
            c.ping_ms = p
            room.clients[c.client_id] = c
        return protocol.room_ping_score(room)

    check(score(60, 55)[0] == 115, "room score leads with the two pings the input delay is built from")
    check(score(80)[0] == 80, "a one-player room scores its single ping")
    check(score()[0] == srv.UNKNOWN_PING_MS, "an empty room scores the unknown-ping constant")
    check(score(0, 0)[0] == srv.UNKNOWN_PING_MS, "members that never reported a ping count as unknown")
    check(score(200, 30)[0] == score(180, 50)[0] and score(200, 30) > score(180, 50),
          "equal top-two sums fall through to the worst single ping")
    check(score(60, 55) < score(60, 56), "a lower ping sorts first")
    check(score(50, 50)[3] == "SCOR", "the score ends in the room code, so ties are deterministic")

    seed_public_room("PGHI", "ping-pick", [200, 30])   # oldest candidate, top-two 230
    seed_public_room("PDEF", "ping-pick", [60, 55])    # top-two 115 -> should win
    seed_public_room("PABC", "ping-pick", [90, 80])    # lowest room code, top-two 170
    picker = await start_fake_client("Picker", 26980)
    await picker.matchmake(modv="ping-pick")
    check(picker.room == "PDEF",
          "the lowest-ping room wins (not the oldest candidate, not the lowest room code)")
    picker.send({"t": "leave"})
    for code in ("PGHI", "PDEF", "PABC"):
        protocol.rooms.pop(code, None)

    # lockstep runs at the WORST link, so the worst pings beat the better average
    seed_public_room("AVGB", "ping-avg", [250, 10, 10])   # mean 90, top-two 260
    seed_public_room("WRST", "ping-avg", [95, 95, 95])    # mean 95, top-two 190
    avg_p = await start_fake_client("AvgPick", 26981)
    await avg_p.matchmake(modv="ping-avg")
    check(avg_p.room == "WRST",
          "a room with the better WORST pings wins over one with the better average")
    check(protocol.negotiate_input_delay(protocol.rooms["WRST"])
          < protocol.negotiate_input_delay(protocol.rooms["AVGB"]),
          "and that really is the lower negotiated input delay")
    avg_p.send({"t": "leave"})
    for code in ("AVGB", "WRST"):
        protocol.rooms.pop(code, None)

    # the delay comes from the top TWO pings, so lowest-max alone is the wrong rank
    seed_public_room("TWOA", "ping-two", [100, 10])   # max 100, top-two 110
    seed_public_room("TWOB", "ping-two", [90, 90])    # max 90,  top-two 180
    two = await start_fake_client("TwoPick", 26982)
    await two.matchmake(modv="ping-two")
    check(two.room == "TWOA", "one laggy peer beside a fast one beats two middling peers")
    check(protocol.negotiate_input_delay(protocol.rooms["TWOA"])
          < protocol.negotiate_input_delay(protocol.rooms["TWOB"]),
          "the chosen room negotiates the lower input delay")
    two.send({"t": "leave"})
    for code in ("TWOA", "TWOB"):
        protocol.rooms.pop(code, None)

    seed_public_room("UZZZ", "ping-none", [0])
    seed_public_room("UAAA", "ping-none", [0])
    u1 = await start_fake_client("Unk1", 26983)
    await u1.matchmake(modv="ping-none")
    check(u1.room == "UAAA", "with no ping data anywhere the pick is deterministic (lowest room code)")
    u1.send({"t": "leave"})
    for code in ("UZZZ", "UAAA"):
        protocol.rooms.pop(code, None)

    seed_public_room("KUNK", "ping-mixed", [0])
    seed_public_room("KGUD", "ping-mixed", [40, 40])
    u2 = await start_fake_client("Unk2", 26984)
    await u2.matchmake(modv="ping-mixed")
    check(u2.room == "KGUD", "a measured low-ping room beats a room with no ping data")
    u2.send({"t": "leave"})
    for code in ("KUNK", "KGUD"):
        protocol.rooms.pop(code, None)

    seed_public_room("BUNK", "ping-bad", [0])
    seed_public_room("BBAD", "ping-bad", [400, 400])
    u3 = await start_fake_client("Unk3", 26985)
    await u3.matchmake(modv="ping-bad")
    check(u3.room == "BUNK", "a room with no ping data beats a measured terrible one")
    u3.send({"t": "leave"})
    for code in ("BUNK", "BBAD"):
        protocol.rooms.pop(code, None)

    print("ping ranking does not change matchmaking eligibility:")
    seed_public_room("EFUL", "ping-full", [5, 5, 5, 5])
    seed_public_room("EOPN", "ping-full", [200, 190])
    full = await start_fake_client("FullPick", 26986)
    await full.matchmake(modv="ping-full")
    check(full.room == "EOPN", "a full room is skipped even with the best ping")
    full.send({"t": "leave"})
    for code in ("EFUL", "EOPN"):
        protocol.rooms.pop(code, None)

    seed_public_room("GRUN", "ping-elig", [10], started=True)
    priv = seed_public_room("GPRV", "ping-elig", [10])
    priv.public = False
    elig = await start_fake_client("EligPick", 26987)
    elig.send({"t": "matchmake", "name": elig.name, "port": elig.listen_port,
               "mod": "Spelunky 2.5", "modv": "ping-elig", "find": 1})
    err = await elig.expect("error")
    check(err["err"] == "no_unstarted_game",
          "find-only still errors: a started or private room is not matchmakable at any ping")
    check(not any(r.mod_version == "ping-elig" and r.code not in ("GRUN", "GPRV")
                  for r in protocol.rooms.values()),
          "and the find-only queue still opens no room")
    for code in ("GRUN", "GPRV"):
        protocol.rooms.pop(code, None)

    seed_public_room("LSLO", "ping-started", [300, 300], started=True)
    seed_public_room("LFST", "ping-started", [25, 25], started=True)
    late = await start_fake_client("LatePick", 26988)
    await late.matchmake(modv="ping-started", started=True)
    check(late.room == "LFST", "matchmake(started) late-joins the lowest-ping running room")
    late.send({"t": "leave"})
    for code in ("LSLO", "LFST"):
        protocol.rooms.pop(code, None)

    # the already-placed guard must stay AHEAD of the ping ranking
    rp = await start_fake_client("Resend", 26989)
    await rp.matchmake(modv="ping-resend")
    rp_room = rp.room
    protocol.rooms[rp_room].clients[rp.cid].ping_ms = 250
    seed_public_room("RBST", "ping-resend", [10, 10])
    await rp.matchmake(modv="ping-resend")
    check(rp.room == rp_room,
          "a matchmake resend keeps a placed client in its room even if a faster one exists")
    rp.send({"t": "leave"})
    protocol.rooms.pop("RBST", None)
    await asyncio.sleep(0.3)

    print("camp shortcut doors carry the start destination:")
    check(srv.parse_start_dest([2, 1, 2]) == [2, 1, 2], "a shortcut destination survives validation")
    check(srv.parse_start_dest([1, 1, 1]) is None, "the main door (1-1) carries no destination")
    check(srv.parse_start_dest(None) is None, "a missing destination is the main door")
    check(srv.parse_start_dest([2, 1]) is None, "a malformed destination is rejected")
    check(srv.parse_start_dest(["a", 1, 2]) is None, "a non-integer destination is rejected")
    check(srv.parse_start_dest([99, 1, 2]) is None, "an out-of-range world is rejected")
    check(srv.parse_start_dest([2, 1, 99]) is None, "an out-of-range theme is rejected")

    sc1 = await start_fake_client("Short1", 26991)
    sc2 = await start_fake_client("Short2", 26992)
    await sc1.create_room(modv="shortcut-test")
    await sc2.join_room(sc1.room, modv="shortcut-test")
    # both ready at the SAME shortcut door (world 2), as the client requires
    sc1.send({"t": "ready", "ready": True, "dest": [2, 1, 2]})
    sc2.send({"t": "ready", "ready": True, "dest": [2, 1, 2]})
    await asyncio.sleep(0.3)
    room = protocol.rooms[sc1.room]
    check(all(c.start_dest == [2, 1, 2] for c in room.clients.values()),
          "the server records which door each player readied at")
    lobby = None
    for _ in range(6):
        lobby = await sc1.expect("lobby")
        if all(p.get("dest") for p in lobby["players"]):
            break
    check(lobby is not None and all(p.get("dest") == [2, 1, 2] for p in lobby["players"]),
          "the lobby broadcast shows each player's door so peers can compare it")

    sc1.send({"t": "start", "dest": [2, 1, 2]})
    await asyncio.sleep(0.4)
    starts = [e for e in sc2.applied_events if e["k"] == "run_start"]
    check(starts and starts[-1]["p"].get("start") == [2, 1, 2],
          "run_start carries the shortcut so every machine warps to the same world")
    check(room.start_dest == [2, 1, 2], "the room remembers the door the run began at")

    # an instant restart must return to the SAME shortcut, not 1-1
    sc1.send({"t": "restart", "nonce": "sc-restart-1"})
    await asyncio.sleep(0.4)
    restarts = [e for e in sc2.applied_events if e["k"] == "run_start"]
    check(len(restarts) > len(starts) and restarts[-1]["p"].get("start") == [2, 1, 2],
          "a restart puts the party back at the same shortcut")
    for c in (sc1, sc2):
        c.send({"t": "leave"})
    await asyncio.sleep(0.3)

    print("a normal main-door start carries no destination:")
    md1 = await start_fake_client("Main1", 26993)
    md2 = await start_fake_client("Main2", 26994)
    await md1.create_room(modv="maindoor-test")
    await md2.join_room(md1.room, modv="maindoor-test")
    md1.send({"t": "ready", "ready": True})
    md2.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.3)
    md1.send({"t": "start"})
    await asyncio.sleep(0.4)
    mstarts = [e for e in md2.applied_events if e["k"] == "run_start"]
    check(mstarts and "start" not in mstarts[-1]["p"],
          "no shortcut -> run_start omits it and clients use the usual 1-1")
    for c in (md1, md2):
        c.send({"t": "leave"})
    await asyncio.sleep(0.3)

    print("late-join: nothing in progress -> error:")
    lj4 = await start_fake_client("LJ4", 26933)
    lj4.send({"t": "matchmake", "name": lj4.name, "port": lj4.listen_port,
              "mod": "Spelunky 2.5", "modv": "latejoin-none", "started": 1})
    errlj = await lj4.expect("error")
    check(errlj["err"] == "no_started_game", "matchmake(started) with no game in progress errors")

    for client in (mm1, mm2, mm3, mm4, mm5, hoster, finder, fjoin, pubA, pubB,
                   lj1, lj2, lj3, lj4, cj1, cj2, cj3, pj1, pj2, pj3):  # tidy up for the shutdown check
        client.send({"t": "leave"})
    await asyncio.sleep(0.3)

    print("end adventure (soft leave: others play on; all-leave reopens lobby):")
    ea1 = await start_fake_client("EA1", 26922)
    ea2 = await start_fake_client("EA2", 26923)
    await ea1.create_room()
    await ea2.join_room(ea1.room)
    ea1.send({"t": "ready", "ready": True})
    ea2.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    ea1.send({"t": "start"})
    await asyncio.sleep(0.4)
    ea_room = ea1.room
    ea1.send({"t": "endrun"})  # EA1 ends their adventure, EA2 plays on
    await asyncio.sleep(0.4)
    ea_left = [e for e in ea2.applied_events if e["k"] == "player_left" and e["p"]["slot"] == 1]
    check(len(ea_left) >= 1, "a soft leaver triggers player_left so others stand its slot still")
    check(ea_room in protocol.rooms and protocol.rooms[ea_room].started,
          "the run continues for the rest after one player ends their adventure")
    check(ea_room in protocol.rooms and len(protocol.rooms[ea_room].clients) == 2,
          "the soft leaver stays in the room (not removed)")
    ea2.send({"t": "endrun"})  # everyone has now ended
    await asyncio.sleep(0.4)
    check(ea_room in protocol.rooms and not protocol.rooms[ea_room].started,
          "once everyone ends their adventure the room reopens as a lobby")
    for client in (ea1, ea2):
        client.send({"t": "leave"})
    await asyncio.sleep(0.3)

    print("host give-up hand-off (End Adventure) keeps a private room open:")
    gh = await start_fake_client("GiveUpHost", 26924)
    gp = await start_fake_client("GiveUpPeer", 26925)
    await gh.create_room()  # a PRIVATE room; gh is the host (slot 1)
    await gp.join_room(gh.room)
    gh.send({"t": "ready", "ready": True})
    gp.send({"t": "ready", "ready": True})
    await asyncio.sleep(0.2)
    gh.send({"t": "start"})
    await asyncio.sleep(0.4)
    gu_room = gh.room
    gh.send({"t": "leave", "ho": 1})  # the HOST ends their adventure (hand-off leave)
    await asyncio.sleep(0.4)
    check(gu_room in protocol.rooms,
          "a hand-off leave keeps the private room open (host give-up)")
    check(gu_room in protocol.rooms and len(protocol.rooms[gu_room].clients) == 1,
          "only the give-up host was removed")
    gu_left = [e for e in gp.applied_events if e["k"] == "player_left" and e["p"]["slot"] == 1]
    check(len(gu_left) >= 1, "the remaining player is told the host gave up (player_left)")
    check(gu_room in protocol.rooms and protocol.rooms[gu_room].started,
          "the run keeps going for the remaining player after the host gives up")
    gp.send({"t": "leave"})  # a PLAIN leave by the new host still closes the private room
    await asyncio.sleep(0.3)
    check(gu_room not in protocol.rooms,
          "a plain host leave still closes the private room")

    print("public rooms outlive their host (close only when empty):")
    p1 = await start_fake_client("P1", 26920)
    p2 = await start_fake_client("P2", 26921)
    await p1.matchmake(modv="pubtest")  # p1 opens a public room and is host (slot 1)
    await p2.matchmake(modv="pubtest")  # p2 joins the same public room
    check(p1.room == p2.room and p2.room is not None, "both matchmakers land in one public room")
    pub_code = p1.room
    p1.send({"t": "leave"})  # the HOST leaves
    await asyncio.sleep(0.3)
    check(pub_code in protocol.rooms, "public room stays open after its host leaves")
    check(len(protocol.rooms[pub_code].clients) == 1, "only the departed host was removed")
    left = [e for e in p2.applied_events if e["k"] == "player_left" and e["p"]["slot"] == 1]
    check(len(left) >= 1, "the remaining player is told the host left (player_left)")
    p2.send({"t": "leave"})  # the last player leaves
    await asyncio.sleep(0.3)
    check(pub_code not in protocol.rooms, "public room closes once it is empty")

    keepalive.cancel()  # stop the witness heartbeat; the shutdown checks need rooms to close
    await asyncio.sleep(0.05)
    print("host departure closes the room (and the server once idle):")
    carol.send({"t": "leave"})
    err = await dave.expect("error")
    check(err["err"] == "host_left", "remaining clients are told the host left")
    check(carol.room not in protocol.rooms, "the host's room is gone")
    check(protocol.shutdown is False,
          "server stays up while other rooms are still open")
    rita.send({"t": "leave"})
    alice.send({"t": "leave"})
    await asyncio.sleep(0.2)
    check(not protocol.rooms, "all rooms closed after their hosts left")
    check(protocol.shutdown is True,
          "server shuts down once the last host leaves")

    print("dedicated server (--dedicated) stays up across sessions:")
    # drop_client only touches in-memory room state and (best-effort) sends,
    # so it exercises the shutdown decision without any real sockets.
    def make_server_with_lone_host(dedicated: bool):
        server = srv.ModdedOnlineServer(dedicated=dedicated)
        room = srv.Room("ROOM", "m", "v")
        server.rooms["ROOM"] = room
        host = srv.Client(("127.0.0.1", 26010), 26010, "Host", "cid-host")
        host.slot = 1
        room.clients["cid-host"] = host
        server.drop_client(room, host, "left")
        return server

    ded = make_server_with_lone_host(dedicated=True)
    check(ded.shutdown is False,
          "dedicated server does NOT exit when the last host leaves")
    check("ROOM" not in ded.rooms, "dedicated server still closes the emptied room")
    plain = make_server_with_lone_host(dedicated=False)
    check(plain.shutdown is True,
          "default (auto-launched) server still exits when the last host leaves")

    ticker.cancel()
    transport.close()

    print()
    if checks_failed:
        print(f"{checks_failed} check(s) FAILED")
        sys.exit(1)
    print("All checks passed.")


if __name__ == "__main__":
    asyncio.run(run_tests())
