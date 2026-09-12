"""Modded Online client bridge — play WITHOUT port forwarding (clients only).

The game's scripting API sends UDP from throwaway sockets, so the server
cannot push data back through your router unless you forward a port. This
bridge fixes that with one persistent socket:

    game  <-- localhost -->  bridge  <-- one outbound UDP flow -->  server

Your router sees a normal outgoing connection and lets the replies back in,
exactly like a web browser — no port forwarding, no VPN.

Usage (on each PLAYER's machine, not the server):
    py client_bridge.py <server_ip> [server_port]

Then in the game's MODDED ONLINE window, enable "No port forwarding" mode
(it makes the game talk to this bridge on localhost automatically).
Leave this window open while you play.
"""

import json
import select
import socket
import sys
import time

GAME_LISTEN_PORT = 26010   # the game's udp_listen port (receives pushes)
BRIDGE_LOCAL_PORT = 26011  # where the game sends its outbound traffic

server_ip = sys.argv[1] if len(sys.argv) > 1 else None
server_port = int(sys.argv[2]) if len(sys.argv) > 2 else 26000
if server_ip is None:
    print(__doc__)
    sys.exit(1)

# one persistent socket to the server: its NAT mapping stays open as long as
# traffic flows (the game heartbeats every 2 seconds). IPv6 server addresses
# (CGNAT-friendly hosting) are supported transparently.
info = socket.getaddrinfo(server_ip, server_port, type=socket.SOCK_DGRAM)[0]
server_addr = info[4]
upstream = socket.socket(info[0], socket.SOCK_DGRAM)
upstream.bind(("::" if info[0] == socket.AF_INET6 else "0.0.0.0", 0))

# A bridge is pinned to ONE server address for its whole life, so a leftover
# one is not harmless: the game talks to whatever holds this port, and an old
# bridge silently relays to the server the PREVIOUS session picked. That looks
# exactly like "could not reach the server" with nothing wrong anywhere.
#
# The game does try to clear leftovers first, but on Windows `py.exe` launches
# `python.exe` as a CHILD: killing the window's process leaves the real
# interpreter alive, still holding this port. So the new bridge asks the old one
# to stand down over the port itself, which works no matter how it was started.
QUIT_TOKEN = "__mo_bridge_quit__"


def bind_local():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", BRIDGE_LOCAL_PORT))
    return sock


# local side: the game sends here instead of to the server directly
try:
    local = bind_local()
except OSError:
    print(f"port {BRIDGE_LOCAL_PORT} is busy — asking the previous bridge to stand down")
    nudge = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    nudge.sendto(json.dumps({"t": QUIT_TOKEN}).encode("utf-8"),
                 ("127.0.0.1", BRIDGE_LOCAL_PORT))
    nudge.close()
    local = None
    deadline = time.monotonic() + 5.0
    while local is None and time.monotonic() < deadline:
        time.sleep(0.25)
        try:
            local = bind_local()
        except OSError:
            pass
    if local is None:
        # An older build that predates QUIT_TOKEN will not let go. Say which
        # server it is stuck on so the fix is obvious.
        print(f"the bridge already on port {BRIDGE_LOCAL_PORT} will not release it.")
        print("It is probably an older copy. Close its window, or end the")
        print("python.exe running client_bridge.py in Task Manager, then retry.")
        time.sleep(8)
        sys.exit(1)
    print("took over from a previous bridge")

upstream.setblocking(False)
local.setblocking(False)

print(f"bridge up: game(127.0.0.1:{BRIDGE_LOCAL_PORT}) <-> {server_ip}:{server_port}")
print("closes itself when you leave the session; Ctrl+C to stop early")

# auto-close: the bridge is only useful while the game is in a session. When
# the game announces it is leaving (a relayed {"t":"leave"}), exit a moment
# later (after forwarding it); if the game simply goes silent — crashed,
# closed, or the player abandoned the session — exit after an idle timeout.
# The timeout is generous because heavily modded loading screens can stall
# the game's Lua VM (and therefore its heartbeats) for a long while.
GAME_IDLE_TIMEOUT_S = 60.0
STARTUP_TIMEOUT_S = 300.0  # never heard from the game at all: give up eventually
seen_game_traffic = False
started_at = time.monotonic()
last_game_traffic = time.monotonic()
close_at = None

sent = received = 0
last_report = time.monotonic()
while True:
    readable, _, _ = select.select([local, upstream], [], [], 1.0)
    for sock in readable:
        while True:  # drain everything ready on this socket
            try:
                data, src = sock.recvfrom(65535)
            except (BlockingIOError, ConnectionResetError):
                break
            if sock is local:
                kind = None
                try:
                    kind = json.loads(data.decode("utf-8")).get("t")
                except (UnicodeDecodeError, ValueError):
                    pass
                if kind == QUIT_TOKEN:
                    # a newer bridge wants this port; it may be aimed at a
                    # different server, and it is the one the game will use
                    print("a newer bridge is taking over this port — closing")
                    local.close()
                    sys.exit(0)
                seen_game_traffic = True
                last_game_traffic = time.monotonic()
                if kind == "leave":
                    close_at = time.monotonic() + 1.0
                try:
                    upstream.sendto(data, server_addr)
                    sent += 1
                except OSError as exc:
                    print(f"  cannot reach {server_addr[0]}: {exc}")
                    print("  (wrong address, or this PC has no route to it — "
                          "for IPv6 targets this PC needs IPv6 internet)")
            elif src[0] == server_addr[0]:  # only the server talks to this socket
                local.sendto(data, ("127.0.0.1", GAME_LISTEN_PORT))
                received += 1
    now = time.monotonic()
    if close_at is not None and now >= close_at:
        print("game left the session — bridge closing")
        break
    if seen_game_traffic and now - last_game_traffic > GAME_IDLE_TIMEOUT_S:
        print(f"no traffic from the game for {GAME_IDLE_TIMEOUT_S:.0f}s — bridge closing")
        break
    if not seen_game_traffic and now - started_at > STARTUP_TIMEOUT_S:
        print("the game never connected — bridge closing")
        break
    if now - last_report > 30 and (sent or received):
        print(f"  relaying: {sent} out / {received} in")
        last_report = now
