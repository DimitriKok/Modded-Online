"""Modded Online — self-hosted UDP server for Spelunky 2 script mods (Spelunky 2.5).

The server is the authority for:
  * lobby membership and player slots (rooms joined by 4-letter code)
  * the adventure seed for each run (identical seed + identical mods
    => identical deterministic world generation on every client)
  * the ordered, reliable event channel (perk purchases, kills,
    level transitions, mod-defined events)

Player movement state is relayed unreliably at whatever rate clients send
(latest datagram wins). Events are sequenced globally per room and re-sent
until every client acknowledges them, so world-affecting interactions apply
in the same order everywhere.

Transport notes: the Spelunky script API (Playlunky/Overlunky) exposes
udp_send / udp_listen only, and udp_send uses a fresh ephemeral socket per
datagram. Clients therefore declare the port their own udp_listen runs on
in their `hello` message; the server pushes datagrams to
(observed source IP, declared listen port).

Run:  py server.py [--port 26000] [--verbose]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import math
import random
import socket
import string
import time

PROTOCOL_VERSION = 1
# This server's build, reported to every client so it can tell whether the server
# it is talking to is the one that shipped with it.
#
# KEEP IN SYNC with meta.version in main.lua. It exists because the two halves of
# this mod can silently diverge: the server is a separate process, and when you
# host on a REMOTE server (the official one, or a friend's) it runs whatever code
# is deployed there, not what you just updated. Every server-side fix — the
# loading grace, the reliable-event repairs, replaying a pinned seed on restart —
# is then simply absent, and the symptom is a client-side mystery. That cost
# several rounds of debugging a "waiting for other players" hang that had already
# been fixed, on a server that did not have the fix.
SERVER_VERSION = "1.0.10"
DEFAULT_PORT = 26000
MAX_PLAYERS_PER_ROOM = 4
# how long a silent client stays in the room before being dropped. Kept
# short so the party isn't stuck waiting on someone who closed their game
# (the lockstep sim stalls until the drop resolves the departure). Trade-off:
# a modded loading screen that stalls the game's Lua VM (no heartbeats)
# longer than this gets that player dropped mid-run.
CLIENT_TIMEOUT_S = 15.0
# A player who is ACTIVELY in a run resends inputs constantly, so prolonged
# silence means it has quit / crashed / closed the game — drop it faster than
# CLIENT_TIMEOUT_S so the lockstep doesn't freeze everyone else on "Waiting for
# other players". Only applies to clients in a started run and still playing (not
# soft-leavers, who merely heartbeat).
#
# MUST STAY WELL CLEAR OF A LEGITIMATE PAUSE IN A CLIENT'S TRAFFIC. Input
# datagrams stop entirely while a level generates: the game's Lua callbacks do
# not run, so nothing is sent, and the client's heartbeat cannot cover the gap
# either. At 2.0 s this dropped players mid-run for doing nothing worse than
# loading a floor -- an instant restart (fresh-run reset + full regeneration) hit
# it almost every time. The victim's game keeps the roster it was given at
# run_start and waits forever on a slot the server has already evicted, which is
# the "we restarted and I'm stuck on WAITING FOR PLAYERS" report. Worse, a
# dropped HOST closes a private room out from under everyone.
# Being wrongly evicted ends the run; waiting a few extra seconds for a genuine
# crash does not. So this is sized for the slowest plausible level generation.
RUN_TIMEOUT_S = 8.0
# A client that has told us it is LOADING gets this long instead.
#
# Silence is the only liveness signal we have, and it cannot tell "crashed" from
# "blocked": while the game builds a level its Lua callbacks do not run at all, so
# it sends nothing no matter how healthy it is. On a heavy floor -- thousands of
# entities, a content mod's transition hooks -- a single blocked frame can run for
# tens of seconds. At 8 s that read as a dead client, and the player was evicted
# for the crime of walking into an exit door; being the host, the eviction closed
# the room, and their game sat on WAITING FOR PLAYERS until it noticed the server
# had gone. A capture shows it exactly: the sim ran on for the ~79 frames of peer
# input it still had buffered, then froze for good.
# So the client now says "I am about to load" BEFORE it blocks (see netCore's
# loading notice), and that buys this much grace. The cost is only paid when a
# client genuinely dies mid-load, which is the one case worth waiting out.
LOADING_GRACE_S = 60.0
# In a PUBLIC room anyone may press "Quick Restart" on the death screen, so
# several restart requests (different nonces) can land at once. Serve the first
# and coalesce any others within this window into that single run — comfortably
# longer than simultaneous presses, far shorter than a real play+wipe cycle so a
# genuine next-death restart is never blocked.
RESTART_DEDUP_S = 3.0
EVENT_RESEND_INTERVAL_S = 0.25
# Reliable events are re-sent until acked, with NO give-up (see flush_events for
# why giving up permanently kills a client's event channel). This is only how many
# retries pass before we say so in the log, so a peer that is genuinely not acking
# is visible instead of silent.
EVENT_RESEND_STUCK_NOTICE = 40  # ~10 s
TICK_INTERVAL_S = 0.05

# Lockstep input-delay negotiation. The clients run a lockstep simulation that
# stalls (slow motion for EVERYONE) whenever a player's inputs arrive later
# than the input-delay budget. We hand every client the SAME value (it must be
# identical on all machines to stay deterministic) sized to the worst latency,
# so high-latency lobbies play at normal speed. Delay is in 60 Hz sim frames.
#
# The budget only needs to cover the worst ONE-WAY latency between two players,
# not a round trip: a player's input for frame F is sent one delay-window early
# and just has to arrive before the peer reaches F. For a relayed game that
# one-way path is (sender -> server) + (server -> receiver) ~= half the sender's
# ping plus half the receiver's ping. So it's set by the two highest pings, and
# a single very-laggy player no longer taxes everyone with their whole RTT.
FRAME_MS = 1000.0 / 60.0
MIN_INPUT_DELAY = 4
MAX_INPUT_DELAY = 20        # ~333 ms; past this the game is unplayable regardless
INPUT_DELAY_MARGIN = 3      # frames of jitter headroom on top of the estimate

# Matchmaking: a room whose members haven't reported a ping yet (they all joined
# less than one heartbeat ago) has no measurable quality. Score it as this many
# ms so it neither always wins (an unreported ping reads as 0) nor never wins —
# roughly a typical cross-country round trip.
UNKNOWN_PING_MS = 120

def parse_start_dest(value):
    """Validate a camp-door destination from the wire: [world, level, theme].

    Returns a clean list of ints, or None for "the main door / 1-1". Bounds keep
    a malformed or hostile packet from warping a party somewhere nonsensical.
    """
    if not (isinstance(value, list) and len(value) == 3):
        return None
    if not all(isinstance(v, int) for v in value):
        return None
    world, level, theme = value
    if not (1 <= world <= 16 and 1 <= level <= 99 and 0 <= theme <= 32):
        return None
    if world == 1 and level == 1:
        return None  # the main door: the default start, nothing to carry
    return [world, level, theme]


log = logging.getLogger("modded-online")


def now() -> float:
    return time.monotonic()


class Client:
    """One connected game client."""

    def __init__(self, addr, listen_port: int, name: str, client_id: str):
        self.ip = addr[0]
        self.listen_port = listen_port
        # listen_port 0 => relay mode: the client sits behind a NAT with no
        # forwarding and talks through a persistent bridge socket; replies go
        # to the observed source address of its datagrams
        self.reply_to_source = listen_port == 0
        self.source_addr = addr
        self.name = name
        self.client_id = client_id  # random id chosen by the client, survives IP changes
        self.slot = 0  # 1..4, assigned by the room
        self.ready = False
        self.char = 194  # chosen character (ENT_TYPE), sent with the ready message
        # Which camp door this player readied at, as [world, level, theme], or
        # None for the main door (a normal 1-1 start). The camp's shortcut doors
        # start the run deeper in, and EVERY player has to be readied at the SAME
        # one — the client compares these and the lobby list shows them.
        self.start_dest = None
        self.in_level = False
        # ended their adventure this run (returned to the lobby); others keep
        # playing with this slot stood still, and the run is over once everyone
        # has. Reset at each run start.
        self.left_run = False
        # a matchmaker who dropped into a game ALREADY in progress and hasn't yet
        # readied to join it. They sit in the room (in the camp) but stay OUT of
        # the run's roster until they ready up; then the next run start includes
        # them. Never true for a normal join.
        self.late_pending = False
        self.last_seen = now()
        # while this is in the future the client has warned us it is loading a
        # screen and cannot send anything; see LOADING_GRACE_S
        self.loading_until = 0.0
        self.ping_ms = 0          # latest round-trip the client reported (heartbeat)
        # the last input datagram we relayed from this client. On a mid-run
        # departure it's handed to the survivors so they converge on identical
        # inputs for the departed slot instead of each guessing (which desyncs).
        self.last_input = None
        # reliable channel bookkeeping
        self.next_client_seq = 1  # next unduplicated event seq expected from this client
        self.acked_up_to = 0      # highest server event seq this client has acked

    @property
    def push_addr(self):
        if self.reply_to_source:
            return self.source_addr
        return (self.ip, self.listen_port)

    def to_lobby_entry(self) -> dict:
        return {"slot": self.slot, "name": self.name, "ready": self.ready,
                "dest": self.start_dest}


class Room:
    """A lobby / game session identified by a join code."""

    def __init__(self, code: str, mod_name: str, mod_version: str):
        self.code = code
        self.mod_name = mod_name
        self.mod_version = mod_version
        self.clients: dict[str, Client] = {}  # client_id -> Client
        # [world, level, theme] the run starts at (a camp shortcut), or None for
        # 1-1. Kept on the ROOM so an instant restart returns to the same door.
        self.start_dest = None
        self.started = False
        self.seed = None
        self.last_restart_nonce = None  # dedup for a client's resent restart requests
        self.last_restart_at = 0.0      # coalesce simultaneous restart presses (public rooms)
        self.event_seq = 0
        self.event_log: list[dict] = []  # all sequenced events for late resend
        self.created_at = now()
        # matchmaking: public rooms are the ones Matchmaking (and hosting on the
        # official server) find-or-create; private (friend / dedicated-hosted)
        # rooms stay False and are never handed out by matchmake. Rooms are
        # matched purely on the mod fingerprint (mod_version) — i.e. an identical
        # enabled-script list, which is what deterministic lockstep requires.
        self.public = False
        # The slot whose game is the authoritative world simulation for the run in
        # progress. NOT the same thing as host() below, and conflating the two is
        # what made a host unable to rejoin: host() is "lowest occupied slot", and
        # a departed host reclaims its low slot the moment it comes back — so it
        # became host() again WHILE STILL WAITING to be folded in, and the peer
        # actually driving the run had its joinfloor request rejected. Mirrors the
        # client's Network.runHostSlot, including promotion when the holder leaves.
        self.run_host_slot = 0

    def in_run(self):
        """Clients that are part of the run in progress.

        Two kinds of client are deliberately excluded, because both sit in the
        room without simulating the run and neither may be treated as the one
        driving it:
          * a late-joiner, which may even hold the lowest slot; and
          * someone who ended their adventure (left_run) -- leaving the RUN does
            not leave the ROOM, which is exactly why the in-game header still
            counted them and why the run host was never handed on."""
        return [c for c in self.clients.values()
                if not c.late_pending and not c.left_run]

    def promote_run_host(self) -> int:
        """Hand the run host to the lowest slot still IN the run. Returns it."""
        playing = self.in_run()
        self.run_host_slot = min((c.slot for c in playing), default=0)
        return self.run_host_slot

    def free_slot(self) -> int:
        used = {c.slot for c in self.clients.values()}
        for slot in range(1, MAX_PLAYERS_PER_ROOM + 1):
            if slot not in used:
                return slot
        return 0

    def host(self) -> Client | None:
        # host = lowest occupied slot (slot 1 unless they left)
        occupied = sorted(self.clients.values(), key=lambda c: c.slot)
        return occupied[0] if occupied else None

    def others(self, client_id: str):
        return [c for c in self.clients.values() if c.client_id != client_id]


class ModdedOnlineServer(asyncio.DatagramProtocol):
    def __init__(self, dedicated: bool = False):
        # dual-stack: one transport per address family (IPv4 + IPv6). IPv6
        # lets players host on CGNAT connections (5G home internet) where
        # IPv4 port forwarding is impossible.
        self.transports: list = []
        self.rooms: dict[str, Room] = {}
        self.addr_index: dict[tuple, tuple[str, str]] = {}  # (ip, listen_port) -> (room_code, client_id)
        # set when a room's host leaves and no rooms remain: the self-hosted
        # session is over, so the server process exits (the tick loop watches)
        self.shutdown = False
        # dedicated (--dedicated): run this server on a separate machine that
        # stays up across sessions. It NEVER exits on its own when a host
        # leaves — rooms just close and it waits for the next one. Auto-launched
        # local servers leave this off so they clean themselves up when done.
        self.dedicated = dedicated

    # ---------------------------------------------------------------- plumbing

    def connection_made(self, transport):
        self.transports.append(transport)

    def transport_for(self, addr):
        want_v6 = ":" in addr[0]
        for transport in self.transports:
            sock = transport.get_extra_info("socket")
            if sock is not None and (sock.family == socket.AF_INET6) == want_v6:
                return transport
        return self.transports[0] if self.transports else None

    def send(self, addr, msg: dict):
        transport = self.transport_for(addr)
        if transport is None:
            return
        try:
            transport.sendto(json.dumps(msg, separators=(",", ":")).encode("utf-8"), addr)
        except OSError as exc:
            log.warning("send to %s failed: %s", addr, exc)

    def broadcast(self, room: Room, msg: dict, exclude_id: str | None = None):
        for client in room.clients.values():
            if client.client_id != exclude_id:
                self.send(client.push_addr, msg)

    def datagram_received(self, data, addr):
        try:
            msg = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            log.debug("undecodable datagram from %s", addr)
            return
        if not isinstance(msg, dict) or "t" not in msg:
            return
        handler = getattr(self, "on_" + str(msg["t"]), None)
        if handler is None:
            log.debug("unknown message type %r from %s", msg.get("t"), addr)
            return
        try:
            handler(msg, addr)
        except Exception:
            log.exception("error handling %r from %s", msg.get("t"), addr)

    def find_client(self, msg, addr) -> tuple[Room, Client] | tuple[None, None]:
        room = self.rooms.get(str(msg.get("room", "")).upper())
        if room is None:
            return None, None
        client = room.clients.get(str(msg.get("cid", "")))
        if client is None:
            return None, None
        client.last_seen = now()
        client.ip = addr[0]      # follow IP changes, keep declared listen port
        client.source_addr = addr  # relay-mode replies chase the live NAT mapping
        return room, client

    # ---------------------------------------------------------------- lobby

    def on_create(self, msg, addr):
        """{"t":"create","cid":..,"name":..,"port":..,"mod":..,"modv":..}
        Hosting ALWAYS opens a private (code-only) room. Matchmaking never hands
        these out — only rooms it opened itself (see on_matchmake) are public —
        so a hosted game can only be joined by someone with its room code."""
        cid = str(msg.get("cid", ""))
        # resend of a create whose `joined` reply was lost: this client is already
        # hosting a room — hand that one back instead of spawning a duplicate.
        for room in self.rooms.values():
            if cid and cid in room.clients:
                self.join_room(room, msg, addr)
                return
        code = self.new_room_code()
        room = Room(code, str(msg.get("mod", "?")), str(msg.get("modv", "?")))
        # room.public stays False (Room default): hosted rooms are never public
        self.rooms[code] = room
        self.join_room(room, msg, addr)
        log.info("room %s created by %s (%s)", code, msg.get("name"), addr[0])

    def on_join(self, msg, addr):
        """{"t":"join","room":..,"cid":..,"name":..,"port":..,"mod":..,"modv":..}"""
        code = str(msg.get("room", "")).upper()
        room = self.rooms.get(code)
        reply_addr = (addr[0], int(msg.get("port", 0)) or addr[1])
        log.info("join attempt: %s (%s) from %s -> room %s, replies go to %s",
                 msg.get("name"), msg.get("modv"), addr, code, reply_addr)
        if room is None:
            log.info("join rejected: no room %s", code)
            self.send(reply_addr, {"t": "error", "err": "no_such_room", "room": code})
            return
        if str(msg.get("mod", "?")) != room.mod_name or str(msg.get("modv", "?")) != room.mod_version:
            log.info("join rejected: mod mismatch (client %s %s vs room %s %s)",
                     msg.get("mod"), msg.get("modv"), room.mod_name, room.mod_version)
            self.send(reply_addr, {
                "t": "error", "err": "mod_mismatch", "room": code,
                "mod": room.mod_name, "modv": room.mod_version,
            })
            return
        # Joining by code works even mid-run: an already-started room takes the
        # player as a LATE-JOINER (they pick a character, wait in the camp, and
        # join at the next run) — this is how you drop into a private game in
        # progress. A not-yet-started room is a normal join.
        self.join_room(room, msg, addr, late=room.started)

    def join_room(self, room: Room, msg, addr, late: bool = False):
        cid = str(msg.get("cid", ""))
        listen_port = int(msg.get("port", 0))  # 0 = relay mode (reply to source)
        name = str(msg.get("name", "Spelunker"))[:24]
        if not cid:
            return
        base = 0
        existing = room.clients.get(cid)
        if existing is not None:  # reconnect
            existing.ip, existing.listen_port, existing.last_seen = addr[0], listen_port, now()
            existing.reply_to_source = listen_port == 0
            existing.source_addr = addr
            client = existing
            # A reconnect always follows the client's connect() -> resetChannel(),
            # which restarts its outbound event sequence at cseq=1. Mirror that here
            # or on_event silently drops every one of the returning client's reliable
            # events (it ACKs them, so the client advances happily, but ignores any
            # cseq != next_client_seq) — the rejoiner's kills/perks/interactions never
            # propagate and the run desyncs. Flaky in practice: only bites when the
            # cid is still present (reconnect) rather than dropped (fresh late-join).
            existing.next_client_seq = 1
            # Rejoining a run you'd LEFT (End Adventure / disconnect) — you're still
            # in room.clients but out of the run (left_run). Come back as a LATE-JOINER:
            # a manual rejoin reset the client's reliable channel to 0, so baseline it
            # past the running game's backlog (or it gets stuck waiting on events the
            # server won't resend from the start), and mark it pending so readying up
            # folds it back in at the next run start. An ACTIVE participant reconnect
            # (left_run False) is left untouched — it must keep its place in the run.
            if room.started and existing.left_run:
                existing.acked_up_to = room.event_seq
                existing.late_pending = True
                base = room.event_seq
        else:
            if len(room.clients) >= MAX_PLAYERS_PER_ROOM:
                self.send((addr[0], listen_port), {"t": "error", "err": "room_full", "room": room.code})
                return
            client = Client(addr, listen_port, name, cid)
            client.slot = room.free_slot()
            if late and room.started:
                # dropping into a game in progress: DON'T replay the running
                # game's event backlog (start the reliable channel at "now"), and
                # stay OUT of the current run's roster/lockstep until readied and
                # swept into the next run start.
                client.acked_up_to = room.event_seq
                client.left_run = True
                client.late_pending = True
                base = room.event_seq
            room.clients[cid] = client
        self.addr_index[client.push_addr] = (room.code, cid)
        log.info("room %s: %s joined as slot %d%s, pushing to %s",
                 room.code, client.name, client.slot,
                 " (late-join)" if base else "", client.push_addr)
        self.send(client.push_addr, {
            "t": "joined", "room": room.code, "slot": client.slot,
            "pv": PROTOCOL_VERSION, "srv": SERVER_VERSION,
            "mod": room.mod_name, "modv": room.mod_version,
            # reliable-channel baseline for a late-joiner: skip the backlog
            "base": base,
        })
        self.push_lobby(room)

    def on_matchmake(self, msg, addr):
        """Matchmaking: {"t":"matchmake","cid":..,"name":..,"port":..,"mod":..,"modv":..}.
        Drop the caller into an open PUBLIC room with the same mod list (matched
        on the mod fingerprint), opening a fresh public one if none are waiting.
        No room code is needed — the reply is a normal `joined`, so the client
        flow is identical to a create/join from there on."""
        cid = str(msg.get("cid", ""))
        if not cid:
            return
        mod_name = str(msg.get("mod", "?"))
        mod_version = str(msg.get("modv", "?"))
        want_started = bool(msg.get("started"))
        find_only = bool(msg.get("find"))  # find an open lobby but DON'T open a new one

        # Resend / already placed: if this client is already in a room, rejoin
        # THAT one. A lost `joined` reply makes the client resend its matchmake;
        # without this it could be matched into a second room and end up in two.
        for room in self.rooms.values():
            if cid in room.clients:
                self.join_room(room, msg, addr)
                return

        if want_started:
            # Drop into a game ALREADY in progress: a started public room with the
            # same mod list and a free slot. Join as a late-joiner (out of the
            # current run until readied — see join_room).
            running = self.matchmake_candidates(mod_name, mod_version, started=True)
            if running:
                room = min(running, key=self.room_ping_score)
                log.info("matchmake(started): %s late-joins running room %s "
                         "(best of %d by ping, score %s)",
                         msg.get("name"), room.code, len(running), self.room_ping_score(room))
                self.join_room(room, msg, addr, late=True)
                return
            # nothing in progress to drop into
            reply_addr = (addr[0], int(msg.get("port", 0)) or addr[1])
            self.send(reply_addr, {"t": "error", "err": "no_started_game"})
            return

        # Of the open, public, not-yet-started rooms with our mod list, take the one
        # with the LOWEST OVERALL PING (room_ping_score) rather than just the oldest
        # — that is the room whose lockstep input delay will be smallest.
        open_rooms = self.matchmake_candidates(mod_name, mod_version, started=False)
        if open_rooms:
            room = min(open_rooms, key=self.room_ping_score)
            log.info("matchmake: %s joins open public room %s (best of %d by ping, score %s)",
                     msg.get("name"), room.code, len(open_rooms), self.room_ping_score(room))
            self.join_room(room, msg, addr)
            return

        # None waiting. A plain "Start Queue" (find_only) does NOT open one — it
        # reports back so the client can offer "start a new game" vs "join a game
        # in progress". START NEW GAME comes back without find_only and opens one.
        if find_only:
            reply_addr = (addr[0], int(msg.get("port", 0)) or addr[1])
            self.send(reply_addr, {"t": "error", "err": "no_unstarted_game"})
            return

        # Open a fresh public room with this mod list.
        code = self.new_room_code()
        room = Room(code, mod_name, mod_version)
        room.public = True
        self.rooms[code] = room
        log.info("matchmake: no open room — %s opened public room %s", msg.get("name"), code)
        self.join_room(room, msg, addr)

    def on_ready(self, msg, addr):
        """{"t":"ready","room":..,"cid":..,"ready":true/false,"char":ENT_TYPE}"""
        room, client = self.find_client(msg, addr)
        if client is None:
            return
        client.ready = bool(msg.get("ready"))
        char = msg.get("char")
        if isinstance(char, int) and 0 < char < 10000:
            client.char = char
        # which camp door they are standing at (None = main door / 1-1)
        client.start_dest = parse_start_dest(msg.get("dest"))
        # A player readying up while a run they are NOT part of is in progress commits
        # to (re)joining it: a fresh late-joiner, OR someone who left the run (End
        # Adventure / disconnect) and came back to the camp. Both carry left_run=True.
        # Clear late_pending so the next run start includes them, and tell the party so
        # the host folds them in at its next floor transition (a MID-RUN join, no wipe).
        if client.ready and room.started and client.left_run:
            client.late_pending = False
            log.info("room %s: %s readied to (re)join the run", room.code, client.name)
            self.sequence_event(room, origin_slot=0, kind="join_pending",
                                payload={"slot": client.slot, "name": client.name})
        self.push_lobby(room)

    def on_start(self, msg, addr):
        """Host requests run start: {"t":"start","room":..,"cid":..,"seed":optional}"""
        room, client = self.find_client(msg, addr)
        if client is None or room.started:
            return
        if client is not room.host():
            self.send(client.push_addr, {"t": "error", "err": "not_host"})
            return
        if not all(c.ready for c in room.clients.values()):
            self.send(client.push_addr, {"t": "error", "err": "not_all_ready"})
            return
        # the door the run is starting from; remembered on the ROOM so an instant
        # restart drops everyone back at the same shortcut instead of 1-1
        room.start_dest = parse_start_dest(msg.get("dest"))
        self.start_run(room)

    def on_restart(self, msg, addr):
        """Instant restart: {"t":"restart","room":..,"cid":..,"n":nonce}
        Starts a fresh run (new seed, same party) for everyone immediately —
        mid-run or from the post-wipe death screen. In a PRIVATE room only the
        host may (their restart IS the decision). In a PUBLIC (matchmade) room
        ANY player may, since there is no meaningful owner; simultaneous presses
        are coalesced into one run. The client resends under one nonce until
        run_start arrives; duplicates (same nonce) are ignored."""
        room, client = self.find_client(msg, addr)
        if client is None:
            return
        # While a run is in progress the driver is the RUN host, not host() (=
        # lowest occupied slot). A departed player keeps their slot in a room, and a
        # rejoining one reclaims it, so host() names someone who may not be playing
        # at all -- the peer actually running the game then got `not_host` and its
        # restart was refused. Same fault as the joinfloor gate above; observed in a
        # capture as "server error: not_host" right after a host left.
        driver_slot = room.run_host_slot if room.started else 0
        if driver_slot:
            if client.slot != driver_slot and not room.public:
                self.send(client.push_addr, {"t": "error", "err": "not_host"})
                return
        elif client is not room.host() and not room.public:
            self.send(client.push_addr, {"t": "error", "err": "not_host"})
            return
        nonce = str(msg.get("n") or "")
        if nonce and nonce == room.last_restart_nonce:
            return  # a resend of a restart we already served
        # coalesce simultaneous presses (public: several players may hit Quick
        # Restart at once, each with its own nonce) into a single run
        if now() - room.last_restart_at < RESTART_DEDUP_S:
            return
        room.last_restart_at = now()
        room.last_restart_nonce = nonce or None
        log.info("room %s: %s restarted the run", room.code, client.name)
        self.start_run(room)

    def on_joinfloor(self, msg, addr):
        """The run host folds a readied late-joiner in at the party's CURRENT
        floor: {t:"joinfloor", w,l,t, a,b, ord}. Re-runs start_run at that floor
        on the host's seed, which grows the roster to the readied late-joiner
        while everyone keeps their progress (no reset to 1-1)."""
        room, client = self.find_client(msg, addr)
        if client is None or not room.started:
            return
        # The RUN host, not host() (= lowest occupied slot). A rejoining host
        # reclaims its low slot before it is folded in, so host() named the very
        # player waiting to join and this dropped the real driver's request on the
        # floor, silently, leaving the joiner in the lobby for good.
        if room.run_host_slot and client.slot != room.run_host_slot:
            log.info("room %s: ignoring joinfloor from slot %d (run host is slot %d)",
                     room.code, client.slot, room.run_host_slot)
            return
        try:
            # theme is `th` — `t` is the message type ("joinfloor")
            floor = {"w": int(msg["w"]), "l": int(msg["l"]), "t": int(msg["th"])}
            # the host's EVOLVED adventure seed for this floor: pass it through
            # EXACTLY (it changes every level and exceeds 32 bits — masking or
            # re-randomizing it drops the joiner onto a different world)
            seed = [int(msg["a"]), int(msg["b"])]
            ordn = int(msg.get("ord", 0))
        except (KeyError, ValueError, TypeError):
            return
        # host's run/player snapshot (level_count etc.) — relayed opaquely so the
        # joiner regenerates the same world
        st = msg.get("st") if isinstance(msg.get("st"), dict) else None
        # coalesce a resent request (host resends until run_start echoes back)
        if now() - room.last_restart_at < RESTART_DEDUP_S:
            return
        room.last_restart_at = now()
        log.info("room %s: host folds late-joiner(s) in at floor %d-%d",
                 room.code, floor["w"], floor["l"])
        self.start_run(room, seed=seed, floor=floor, ord=ordn, st=st)

    def start_run(self, room: Room, seed=None, floor=None, ord=None, st=None):
        """Send everyone a run_start. Normally a FRESH run (warps to 1-1). If
        `floor` ({w,l,t}) is given it's a MID-RUN JOIN instead: the party resyncs
        to that floor (its `ord`, host `seed`, and host snapshot `st`) with the
        roster grown to include a readied late-joiner, keeping their progress."""
        room.started = True
        # Everyone in the room joins the run EXCEPT late-joiners who haven't
        # readied yet — they keep waiting in the camp for a later run start.
        participants = [c for c in room.clients.values() if not c.late_pending]
        # Who is being FOLDED IN by this run_start, i.e. was out of the run and is
        # coming back. Sent to every client so the kit rule for a rejoining player
        # (no bombs, no ropes, the health they left with) is applied identically on
        # all machines — it is simulation state, so it cannot be decided locally:
        # the returning player's own machine no longer knows it had left.
        rejoining = sorted(c.slot for c in participants if c.left_run)
        for c in participants:
            c.left_run = False  # fresh run: everyone (incl. a readied late-joiner) is back in

        # The Spelunky adventure seed is a pair of ints (set_adventure_seed(first, second)).
        # A fresh run gets a random 31-bit pair (comfortably integer-typed in every Lua
        # runtime). A MID-RUN JOIN instead carries the host's EVOLVED floor seed, which
        # must be applied VERBATIM (it changes every level and can exceed 32 bits) — never
        # validate/re-randomize it, or the joiner regenerates a different world.
        if isinstance(floor, dict):
            room.seed = seed
        else:
            if not (isinstance(seed, list) and len(seed) == 2
                    and all(isinstance(v, int) and 0 <= v < 2**32 for v in seed)):
                # 32 bits, matching the range validated on the line above. This read
                # getrandbits(31) for its whole life, so bit 31 of the FIRST value was
                # ALWAYS zero — and that first value is the run constant world
                # generation is derived from (see moPrngFloorBase in the shim). Half of
                # Spelunky 2's seed space, and every world only reachable from it, was
                # therefore unreachable online: across 317 recorded adventure seeds,
                # exactly 0 had bit 31 set where ~158 were expected. It showed up in
                # play as layouts that never appear — notably 1-4 lair bosses turning
                # up far less often than in 2.5 on its own.
                seed = [random.getrandbits(32), random.getrandbits(32)]
            room.seed = seed
        # the run host is the lowest slot actually taking part, which is also how
        # the client derives Network.runHostSlot from this same roster
        room.run_host_slot = min((c.slot for c in participants), default=0)
        delay = self.negotiate_input_delay(room)
        log.info("room %s %s, seed=%08x:%08x, players=%d, input delay=%d frames (worst ping=%d ms)",
                 room.code, "mid-run join" if floor else "starting", seed[0], seed[1],
                 len(participants), delay, max((c.ping_ms for c in room.clients.values()), default=0))
        payload = {"seed": room.seed,
                   "slots": {str(c.slot): c.name for c in participants},
                   "chars": {str(c.slot): c.char for c in participants},
                   "delay": delay}
        if room.start_dest is not None and not isinstance(floor, dict):
            # fresh run from a camp SHORTCUT door: everyone warps here, not 1-1
            payload["start"] = room.start_dest
        if isinstance(floor, dict):
            payload["floor"] = floor        # {w,l,t}: resync HERE, keep progress
            payload["ord"] = int(ord or 0)  # the floor's level ordinal
            # only meaningful for a mid-run join; a fresh run resets the kit anyway
            payload["join"] = rejoining
            if isinstance(st, dict):
                payload["st"] = st          # host snapshot so worlds match
        self.sequence_event(room, origin_slot=0, kind="run_start", payload=payload)

    def negotiate_input_delay(self, room: Room) -> int:
        """Size the lockstep input-delay budget to the worst ONE-WAY latency
        between any two players so a high-latency player doesn't force the whole
        run into slow motion — without over-charging everyone their full RTT.

        The worst client-to-client path is (sender->server)+(server->receiver)
        ~= (ping_sender + ping_receiver) / 2, maximised by the two highest pings.
        A single laggy player therefore costs everyone only ~half its ping, not
        the whole round trip."""
        pings = sorted((c.ping_ms for c in room.clients.values()), reverse=True)
        if len(pings) < 2:
            return MIN_INPUT_DELAY  # solo / no peer to wait on
        worst_oneway_ms = (pings[0] + pings[1]) / 2.0
        delay = math.ceil(worst_oneway_ms / FRAME_MS) + INPUT_DELAY_MARGIN
        return max(MIN_INPUT_DELAY, min(MAX_INPUT_DELAY, delay))

    def room_ping_score(self, room: Room) -> tuple:
        """Matchmaking rank for a candidate room — LOWER IS BETTER.

        "Overall ping" for a lockstep party is NOT the average: the whole run
        moves at the speed of its worst links, and negotiate_input_delay above
        sizes the party's shared input-delay budget from exactly the TWO highest
        pings. So rank by that same quantity, then by the single worst ping, then
        by the mean, then by room code so the choice is deterministic (and
        testable). Ranking by the average would pick (250,10,10) — a great mean
        but a terrible run — over (95,95,95); ranking by the single worst ping
        would pick (90,90) over (100,10), which negotiates a WORSE delay.

        A ping of 0 means "not reported yet" (Client.ping_ms starts at 0 and a
        client's first heartbeat carries its pre-connection value), so those
        members are skipped and a room with no reports at all scores
        UNKNOWN_PING_MS. Tolerates a missing/None ping without raising.
        """
        pings = sorted((c.ping_ms for c in room.clients.values() if (c.ping_ms or 0) > 0),
                       reverse=True)
        if not pings:
            pings = [UNKNOWN_PING_MS]
        top_two = pings[0] + (pings[1] if len(pings) > 1 else 0)
        return (top_two, pings[0], sum(pings) / len(pings), room.code)

    def matchmake_candidates(self, mod_name: str, mod_version: str, started: bool) -> list:
        """Every public room with a free slot and the SAME mod list (identical
        scripts => identical deterministic world), in whichever run state the
        caller asked for. Includes rooms opened by an official host, so
        matchmakers fill hosted public games too."""
        return [room for room in self.rooms.values()
                if (room.public and room.started == started
                    and room.mod_name == mod_name and room.mod_version == mod_version
                    and len(room.clients) < MAX_PLAYERS_PER_ROOM)]

    def push_lobby(self, room: Room):
        self.broadcast(room, {
            "t": "lobby", "room": room.code,
            "players": sorted((c.to_lobby_entry() for c in room.clients.values()),
                              key=lambda e: e["slot"]),
            "started": room.started,
            "public": room.public,
        })

    # ---------------------------------------------------------------- in-run

    def on_state(self, msg, addr):
        """Unreliable player state: {"t":"state","room":..,"cid":..,"d":<opaque>}
        Relayed immediately to everyone else, stamped with the sender's slot."""
        room, client = self.find_client(msg, addr)
        if client is None:
            return
        d = msg.get("d")
        # remember the latest lockstep input tail (seq/base/list) so a departure
        # can be resolved deterministically for the remaining players
        if isinstance(d, dict) and "i" in d:
            client.last_input = d
            # simulating again, so whatever it was loading is done: give up the
            # grace immediately rather than letting it run its full length
            client.loading_until = 0.0
        self.broadcast(room, {"t": "state", "slot": client.slot, "d": d},
                       exclude_id=client.client_id)

    def on_loading(self, msg, addr):
        """{"t":"loading"} — the client is about to block on a screen load and
        will go quiet. Hold off the in-run drop timer until it comes back."""
        room, client = self.find_client(msg, addr)
        if client is None:
            return
        client.loading_until = now() + LOADING_GRACE_S

    def on_world(self, msg, addr):
        """Unreliable authoritative-world stream from the host's game (entity
        positions etc). Same relay semantics as player state."""
        room, client = self.find_client(msg, addr)
        if client is None:
            return
        self.broadcast(room, {"t": "world", "slot": client.slot, "d": msg.get("d")},
                       exclude_id=client.client_id)

    def on_event(self, msg, addr):
        """Reliable client event: {"t":"event","room":..,"cid":..,"cseq":n,"k":kind,"p":payload}
        Deduplicated by per-client seq, then globally sequenced and broadcast."""
        room, client = self.find_client(msg, addr)
        if client is None:
            return
        cseq = int(msg.get("cseq", 0))
        # NEVER ack an event we are not going to apply. This used to ack first and
        # validate second, on the assumption noted here that "the client resends in
        # order" -- it does not. The client keeps every unacked event in a table and
        # re-sends the whole table on a timer, in Lua hash order, dropping each one
        # the moment it is acked. So if event N is lost in flight and N+1 arrives
        # first, the old code ACKED N+1 (client: "delivered", forgets it) and then
        # dropped it for being out of order. N is resent and accepted; N+1 is gone
        # for good, with nothing anywhere to say so.
        # Seen in a capture as `restart vote CAST` followed by a vote that never
        # came back -- votes 0/2 forever, instant restart doing nothing -- but the
        # same hole silently eats ANY world-affecting event, which is a desync.
        # Leaving a gapped event UNACKED is what makes the client keep re-sending
        # it until the missing one lands and it can be taken in order.
        if cseq > client.next_client_seq:
            # Dropped on purpose (see above) -- but say so. This return was silent,
            # and a silent drop here is indistinguishable from the client never
            # sending: the client keeps the event queued and re-sends forever, the
            # server keeps discarding it, and every later event on that client's
            # reliable channel waits behind it. Four two-machine sessions could not
            # tell this apart from a relay failure, because neither end said a word.
            now = time.time()
            if now - getattr(client, "_gap_logged_at", 0.0) >= 2.0:
                client._gap_logged_at = now
                log.warning(
                    "room %s: slot %s sent event cseq=%s but next expected is %s "
                    "(kind=%s) -- holding for the gap to arrive",
                    room.code, client.slot, cseq, client.next_client_seq,
                    msg.get("k", "?"))
            return
        self.send(client.push_addr, {"t": "event_ack", "cseq": cseq})
        if cseq < client.next_client_seq:
            return  # already applied; the ack above stops the client re-sending
        client.next_client_seq += 1
        self.sequence_event(room, origin_slot=client.slot,
                            kind=str(msg.get("k", "?")), payload=msg.get("p"))

    def sequence_event(self, room: Room, origin_slot: int, kind: str, payload):
        room.event_seq += 1
        event = {"t": "event", "seq": room.event_seq, "slot": origin_slot,
                 "k": kind, "p": payload, "_sent_at": 0.0, "_resends": 0}
        room.event_log.append(event)
        self.flush_events(room)

    def flush_events(self, room: Room):
        """(Re)send any events not yet acked by every client.

        RESENDS NEVER GIVE UP WHILE THE CLIENT IS STILL HERE. They used to stop
        after EVENT_RESEND_MAX attempts, which sounds harmless and is not: the
        client applies this channel STRICTLY IN ORDER (netCore.applyReadyEvents
        walks appliedSeq+1 upward), so a client that misses one event buffers
        every later one and applies NONE of them. If the server has also stopped
        re-sending the one it is missing, there is no path back -- that client's
        reliable channel is dead for the rest of the run while the unreliable
        state channel carries on, so the game plays on perfectly normally and
        merely ignores every world event from then on.
        That is what "instant restart does nothing" was: the vote left, the
        server sequenced it, and the reply landed in a buffer that would never be
        drained. `restart vote CAST` with no `restart vote from slot 1` after it,
        forever, in two separate captures.
        A client that is genuinely gone is removed by the timeout sweep in tick(),
        which is the right mechanism for that -- and once it is gone it is no
        longer in room.clients, so nothing here is sent to it anyway.
        """
        min_acked = min((c.acked_up_to for c in room.clients.values()), default=0)
        for event in room.event_log:
            if event["seq"] <= min_acked:
                continue
            if now() - event["_sent_at"] < EVENT_RESEND_INTERVAL_S:
                continue
            event["_sent_at"] = now()
            event["_resends"] += 1
            if event["_resends"] == EVENT_RESEND_STUCK_NOTICE:
                behind = [c.name for c in room.clients.values()
                          if c.acked_up_to < event["seq"]]
                log.warning("room %s: event %d (%s) still unacked by %s after %.0fs "
                            "— still re-sending", room.code, event["seq"], event["k"],
                            ", ".join(behind) or "?",
                            EVENT_RESEND_STUCK_NOTICE * EVENT_RESEND_INTERVAL_S)
            wire = {k: v for k, v in event.items() if not k.startswith("_")}
            for client in room.clients.values():
                if client.acked_up_to < event["seq"]:
                    self.send(client.push_addr, wire)

    def on_ack(self, msg, addr):
        """{"t":"ack","room":..,"cid":..,"seq":n} — client has applied events up to seq."""
        room, client = self.find_client(msg, addr)
        if client is None:
            return
        client.acked_up_to = max(client.acked_up_to, int(msg.get("seq", 0)))

    def on_reset(self, msg, addr):
        """The run ended (party death): reopen the room so the same lobby can
        ready up and start another run. Idempotent — every client sends it."""
        room, client = self.find_client(msg, addr)
        if client is None or not room.started:
            return
        room.started = False
        room.seed = None
        room.last_restart_at = 0.0  # a reopened room is a fresh restart opportunity
        for member in room.clients.values():
            member.ready = False
            member.left_run = False
        log.info("room %s: run over, lobby reopened", room.code)
        self.push_lobby(room)

    def on_endrun(self, msg, addr):
        """A client ended their adventure mid-run and returned to the lobby
        ({"t":"endrun"}). The rest keep playing — the leaver's slot is stood
        still on their machines via a player_left (deterministic markGone), same
        as a disconnect, except the client STAYS in the room / lobby. Once every
        player has ended, the run is over and the room reopens as a lobby."""
        room, client = self.find_client(msg, addr)
        if client is None or not room.started or client.left_run:
            return
        client.left_run = True
        log.info("room %s: %s ended their adventure (slot %d)", room.code, client.name, client.slot)
        # Ending your adventure leaves the RUN but not the ROOM, so drop_client
        # never runs and its promotion never fired. The room went on naming a run
        # host that had stopped playing, so the peer still simulating could not
        # fold a rejoiner in -- its joinfloor was rejected for not being the run
        # host. This is the path a player actually takes when they "leave the
        # game", which is why the earlier promotion (drop only) did not help.
        if client.slot == room.run_host_slot:
            promoted = room.promote_run_host()
            log.info("room %s: run host slot %d ended their adventure -> promoted slot %d",
                     room.code, client.slot, promoted)
        # hand the others the leaver's last relayed input tail so they converge
        # on identical inputs for this slot before standing it still
        self.sequence_event(room, origin_slot=0, kind="player_left",
                            payload={"slot": client.slot, "name": client.name,
                                     "last": client.last_input})
        if all(c.left_run for c in room.clients.values()):
            room.started = False
            room.seed = None
            room.last_restart_at = 0.0  # a reopened room is a fresh restart opportunity
            for c in room.clients.values():
                c.left_run = False
                c.ready = False
            log.info("room %s: everyone ended the adventure, lobby reopened", room.code)
        self.push_lobby(room)

    def on_ping(self, msg, addr):
        room, client = self.find_client(msg, addr)
        if client is None:
            return
        ping = msg.get("ping")
        if isinstance(ping, (int, float)) and 0 <= ping < 60000:
            client.ping_ms = int(ping)
        self.send(client.push_addr, {"t": "pong", "at": msg.get("at")})

    def on_leave(self, msg, addr):
        room, client = self.find_client(msg, addr)
        if client is None:
            return
        # {"t":"leave","ho":1} is a hand-off leave (End Adventure): the player
        # exits the room but the players still mid-run keep going — a private
        # room passes its host role on instead of closing.
        self.drop_client(room, client, "left", handoff=bool(msg.get("ho")))

    # ---------------------------------------------------------------- upkeep

    def maybe_shutdown(self):
        """A default (auto-launched) server exits once it holds no rooms; a
        --dedicated server stays up for the next session."""
        if self.rooms:
            return
        if self.dedicated:
            log.info("no rooms remain; dedicated server staying up for the next session")
        else:
            log.info("no rooms remain — shutting down")
            self.shutdown = True

    def drop_client(self, room: Room, client: Client, why: str, handoff: bool = False):
        was_host = room.host() is client
        room.clients.pop(client.client_id, None)
        self.addr_index.pop(client.push_addr, None)
        log.info("room %s: %s (slot %d) %s", room.code, client.name, client.slot, why)
        if was_host and not room.public and not handoff:
            # a PRIVATE (friend / dedicated-hosted) room belongs to its host:
            # closing it kicks everyone, and a non-dedicated server exits once
            # idle. A hand-off leave skips this so an End-Adventure give-up by
            # the host doesn't boot the players still in the run.
            for other in room.clients.values():
                self.addr_index.pop(other.push_addr, None)
                for _ in range(3):  # plain datagrams; duplicates are harmless
                    self.send(other.push_addr, {"t": "error", "err": "host_left"})
            room.clients.clear()
            self.rooms.pop(room.code, None)
            log.info("room %s closed (host left)", room.code)
            self.maybe_shutdown()
            return
        if not room.clients:
            self.rooms.pop(room.code, None)
            log.info("room %s closed (empty)", room.code)
            self.maybe_shutdown()
            return
        # The run host left: hand the role to the lowest slot still playing. Without
        # this the room kept pointing at a slot that had gone, and once that player
        # rejoined they reclaimed it while still waiting to be folded in — so the
        # peer driving the run could not fold anyone in and the rejoiner was stuck.
        if client.slot == room.run_host_slot:
            promoted = room.promote_run_host()
            log.info("room %s: run host slot %d left -> promoted slot %d",
                     room.code, client.slot, promoted)
        # A public room outlives its host: a host departure is just a normal
        # departure (the host role passes to the lowest remaining slot). Hand the
        # survivors the leaver's last relayed input tail so they can converge on
        # identical inputs for this slot before standing it still.
        self.sequence_event(room, origin_slot=0, kind="player_left",
                            payload={"slot": client.slot, "name": client.name,
                                     "last": client.last_input})
        self.push_lobby(room)

    async def tick(self):
        while not self.shutdown:
            await asyncio.sleep(TICK_INTERVAL_S)
            for room in list(self.rooms.values()):
                for client in list(room.clients.values()):
                    # a client actively in the run streams inputs constantly, so a
                    # brief silence means it's gone — drop it fast so the others
                    # don't freeze. Soft-leavers / lobby clients only heartbeat, so
                    # they keep the long timeout.
                    playing = room.started and not client.left_run
                    timeout = RUN_TIMEOUT_S if playing else CLIENT_TIMEOUT_S
                    if now() < client.loading_until:
                        # it warned us it was going quiet to load a screen
                        timeout = max(timeout, LOADING_GRACE_S)
                    if now() - client.last_seen > timeout:
                        self.drop_client(room, client, "timed out")
                self.flush_events(room)
        log.info("server stopped (the host closed the session)")

    def new_room_code(self) -> str:
        while True:
            code = "".join(random.choices(string.ascii_uppercase, k=4))
            if code not in self.rooms:
                return code


async def main():
    parser = argparse.ArgumentParser(description="Modded Online server for Spelunky 2 script mods")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--dedicated", action="store_true",
                        help="stay running across sessions (don't exit when the host leaves) — "
                             "use this when running the server on its own machine")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    loop = asyncio.get_running_loop()
    protocol = ModdedOnlineServer(dedicated=args.dedicated)
    try:
        transport4, _ = await loop.create_datagram_endpoint(
            lambda: protocol, local_addr=(args.host, args.port))
    except OSError:
        # the game auto-launches this script on "Host new game"; a second
        # launch while a server is already running is a harmless no-op
        log.info("port %d is already in use — server already running, exiting", args.port)
        await asyncio.sleep(3)
        return
    log.info("Modded Online server listening on %s:%d (IPv4, protocol v%d)%s",
             args.host, args.port, PROTOCOL_VERSION,
             " [dedicated: stays up across sessions]" if args.dedicated else "")
    transport6 = None
    if args.host == "0.0.0.0":  # also listen on IPv6 for CGNAT-friendly hosting
        try:
            transport6, _ = await loop.create_datagram_endpoint(
                lambda: protocol, local_addr=("::", args.port))
            log.info("Modded Online server listening on [::]:%d (IPv6)", args.port)
        except OSError as exc:
            log.warning("IPv6 listener unavailable: %s", exc)
    try:
        await protocol.tick()
    finally:
        transport4.close()
        if transport6 is not None:
            transport6.close()


if __name__ == "__main__":
    asyncio.run(main())
