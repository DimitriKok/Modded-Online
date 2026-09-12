"""Guards the two version constants that must agree, and the ones that must not drift.

The mod warns in-game when the server it is talking to is not the build it was
shipped with. That check is only as good as the constant behind it, and the
constant silently fell three server bumps behind: `SERVER_VERSION` went
1.0.5 -> 1.0.6 -> 1.0.7 -> 1.0.8 while `EXPECTED_SERVER_VERSION` stayed at 1.0.5.
The result was the exact opposite of the feature's purpose — a correctly updated
server was reported as "server-side fixes are NOT active", which sends you looking
for a deployment problem that isn't there.

Run:  python -m pytest tests/test_version_sync.py -q
"""

from __future__ import annotations

import pathlib
import re

PACK = pathlib.Path(__file__).resolve().parent.parent
NET_CORE = (PACK / "src" / "netCore.lua").read_text(encoding="utf-8")
SERVER = (PACK / "server" / "server.py").read_text(encoding="utf-8")
MAIN = (PACK / "main.lua").read_text(encoding="utf-8")
CHANGELOG = (PACK / "CHANGELOG.md").read_text(encoding="utf-8")


def expected_server() -> str:
    m = re.search(r'local EXPECTED_SERVER_VERSION = "([^"]+)"', NET_CORE)
    assert m, "EXPECTED_SERVER_VERSION not found in src/netCore.lua"
    return m.group(1)


def server_version() -> str:
    m = re.search(r'^SERVER_VERSION = "([^"]+)"', SERVER, re.M)
    assert m, "SERVER_VERSION not found in server/server.py"
    return m.group(1)


def mod_version() -> str:
    m = re.search(r'version = "([^"]+)"', MAIN)
    assert m, "version not found in main.lua"
    return m.group(1)


def test_the_client_expects_the_server_build_that_ships_with_it():
    assert expected_server() == server_version(), (
        f"the mod expects server {expected_server()} but this repo ships "
        f"{server_version()}: every client would report a correctly updated "
        f"server as out of date"
    )


def test_both_versions_look_like_versions():
    # The two server versions are compared for equality by the client, so they stay
    # strictly x.y.z. The mod version carries a pre-release suffix on this build
    # (2.0.0-dev0) because it is a fork in progress, not something anyone should
    # install — that is legal semver and nothing compares it for equality.
    for name, value in (("EXPECTED_SERVER_VERSION", expected_server()),
                        ("SERVER_VERSION", server_version())):
        assert re.fullmatch(r"\d+\.\d+\.\d+", value), f"{name} is not x.y.z: {value!r}"
    assert re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?", mod_version()),         f"meta.version is not x.y.z[-pre]: {mod_version()!r}"


def test_the_changelog_leads_with_the_current_mod_version():
    """A release whose changelog does not mention it is a release nobody can read."""
    first = next(l for l in CHANGELOG.splitlines() if l.startswith("## "))
    assert first.strip() == f"## {mod_version()}", (
        f"changelog leads with {first.strip()!r} but main.lua says {mod_version()}"
    )
