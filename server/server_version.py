"""Ask a Modded Online server which build it is running.

The server is half of this mod and a SEPARATE process, so updating your pack does
not update a server running somewhere else. Every server-side fix is then simply
absent while the client looks fine — which is exactly the kind of thing that
wastes an evening. This answers the question directly.

It opens a throwaway room (the only reply that carries the server's version is
`joined`), reads the version, and leaves again immediately so nothing is left
behind. It declares relay mode, so it needs no inbound port forward.

Usage:
    py server_version.py                      # the official server
    py server_version.py 127.0.0.1            # your own local one
    py server_version.py <host> 26000        # any other host and port

Exit code 0 means the server matches this copy of the mod, 1 means it does not
(or did not answer) — so it can be used in a script.
"""

from __future__ import annotations

import json
import random
import socket
import sys

sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
try:
    from server import SERVER_VERSION as LOCAL_VERSION
except Exception:                                   # pragma: no cover
    LOCAL_VERSION = None

PUBLIC_HOST = "129.213.14.228"      # keep in sync with PUBLIC_HOST in netCore.lua
DEFAULT_PORT = 26000


def ask(host: str, port: int, timeout: float = 3.0):
    """Open a room, read the server's version out of `joined`, then leave."""
    cid = f"vercheck-{random.getrandbits(32):08x}"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    # port 0 = relay mode: the server answers whatever source address it sees, so
    # this works from behind NAT exactly like the game's bridge does
    hello = {"t": "create", "cid": cid, "name": "version check", "port": 0,
             "mod": "Modded Online", "modv": "version-check", "pv": 1}
    room = None
    try:
        for attempt in range(1, 4):
            sock.sendto(json.dumps(hello).encode(), (host, port))
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                print(f"  attempt {attempt}: no reply after {timeout:.0f}s")
                continue
            try:
                reply = json.loads(data.decode())
            except ValueError:
                continue
            if reply.get("t") != "joined":
                print(f"  unexpected reply: {reply}")
                continue
            room = reply.get("room")
            return reply.get("srv"), reply.get("pv"), room
        return None, None, None
    finally:
        if room is not None:
            # tidy up: don't leave a stray room sitting on a public server
            for _ in range(3):
                sock.sendto(json.dumps({"t": "leave", "room": room,
                                        "cid": cid}).encode(), (host, port))
        sock.close()


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else PUBLIC_HOST
    port = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_PORT
    print(f"asking {host}:{port} which build it is running ...")
    version, protocol, room = ask(host, port)

    if version is None and room is None:
        print("\n[FAIL] no usable reply.")
        print("  - is the server running, and reachable on that UDP port?")
        print("  - py probe.py <ip> tests plain connectivity separately")
        return 1

    print(f"\n  server build : {version if version else 'older than 1.0.63 (does not report one)'}")
    print(f"  protocol     : {protocol}")
    print(f"  this pack    : {LOCAL_VERSION or 'unknown'}")

    if version is None:
        print("\n[STALE] That server predates version reporting, so it is definitely")
        print("        NOT running your updated server.py. Deploy it and restart the")
        print("        server process — editing the file is not enough on its own.")
        return 1
    if LOCAL_VERSION is not None and version != LOCAL_VERSION:
        print(f"\n[STALE] The server is on {version}, this pack ships {LOCAL_VERSION}.")
        print("        Server-side fixes in this pack are NOT active there.")
        print("        Copy server/server.py over and RESTART the server process.")
        return 1
    print("\n[OK] The server is running the same build as this pack.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
