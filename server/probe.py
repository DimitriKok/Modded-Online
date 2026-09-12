"""Connectivity probe for Modded Online players.

Run this on a PLAYER's machine (game closed, so port 26010 is free) to test
the exact network path the game uses:

  1. outbound:  this PC  ->  server UDP port   (like joining a room)
  2. inbound:   server   ->  this PC's listen port  (like lobby/game updates)

Usage:  py probe.py <server_ip> [server_port] [listen_port]
Example: py probe.py 129.213.14.228
"""

import json
import socket
import sys
import time

server_ip = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
server_port = int(sys.argv[2]) if len(sys.argv) > 2 else 26000
listen_port = int(sys.argv[3]) if len(sys.argv) > 3 else 26010

print(f"probing server {server_ip}:{server_port}, expecting replies on local UDP {listen_port}")

try:
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("0.0.0.0", listen_port))
    rx.settimeout(2.0)
except OSError as exc:
    print(f"[FAIL] could not bind local UDP {listen_port}: {exc}")
    print("       close the game (it holds this port) or pick another port")
    sys.exit(1)

tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
# join a room that can't exist; the server replies 'error: no_such_room'
# to (our public IP as it sees it, our declared listen port) — the same
# push path the real game uses
msg = {"t": "join", "room": "????", "cid": "probe", "name": "probe",
       "port": listen_port, "mod": "probe", "modv": "probe"}

ok = False
for attempt in range(1, 4):
    tx.sendto(json.dumps(msg).encode(), (server_ip, server_port))
    try:
        data, addr = rx.recvfrom(2048)
        reply = json.loads(data.decode())
        if reply.get("err") == "no_such_room":
            ok = True
            break
        print(f"  unexpected reply from {addr}: {reply}")
    except socket.timeout:
        print(f"  attempt {attempt}: no reply after 2s")
    time.sleep(0.5)

if ok:
    print("[PASS] full round trip works — this PC can play on that server")
else:
    print("[FAIL] no reply from the server. In order of likelihood:")
    print(f"  - this PC's router doesn't forward UDP {listen_port} inbound (server's reply is dropped)")
    print(f"  - this PC's firewall blocks inbound UDP {listen_port}")
    print(f"  - the packet never reached the server (wrong IP, server not running,")
    print(f"    server-side forward/firewall for UDP {server_port} missing)")
    print("  Ask the host to run the server with --verbose: if a 'join' shows up in")
    print("  the server log, outbound works and the problem is this PC's inbound.")
    sys.exit(1)
