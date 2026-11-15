"""The run log's header says how this machine's Playlunky hands out the engine's
globals (dev88).

Playlunky's 2026-11 update serves `state` and `prng` on every read instead of keeping
them as plain globals, and dropped `players`. Two machines on builds either side of a
change like that run a hosted mod differently, and nothing else in a pair of logs
would say so.

Run:  python -m pytest tests/test_log_header.py -q
"""

from __future__ import annotations

from test_trace_arming import runtime


def header(tmp_path, engine):
    rt = runtime(tmp_path, engine="MO_LOG = true; " + engine)
    rt.execute("DesyncLog.init()")
    return (tmp_path / "desync_log.txt").read_text(encoding="utf-8").splitlines()


def test_the_header_names_how_the_engine_hands_out_its_globals(tmp_path):
    lines = header(tmp_path, 'ModHost = { engineApi = function()'
                   ' return "state=served prng=served players=none get_local_players=yes" end }')
    assert "engineapi=state=served prng=served players=none get_local_players=yes" in lines
    at = lines.index("engineapi=state=served prng=served players=none get_local_players=yes")
    assert lines[at - 1].startswith("packopts="), "with the other per-machine lines"


def test_without_the_host_the_header_still_has_the_line(tmp_path):
    assert "engineapi=?" in header(tmp_path, "")
    broken = tmp_path / "broken"
    broken.mkdir()
    assert "engineapi=?" in header(broken, 'ModHost = { engineApi = function()'
                                   ' error("broken") end }')
