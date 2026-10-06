"""The per-floor block says what every PRNG stream held when the gate engaged.

The gen[pre] and gen[post] lines prove generation drew the same on both machines.
On the BGNY capture's 2-1 they matched, and the floors still differed at the first
frame: what moved the streams happened AFTER generation, in a hosted mod's ON.LEVEL
pass (2.5's swamp lily pads). Nothing in the log said so; it took the entity
histogram and the mod's source to find. The streams at engage, beside gen[post],
show it at a glance: matching there and differing here is a divergence between
generation and the first gated frame.

Run:  python -m pytest tests/test_floor_block.py -q
"""

from __future__ import annotations

import test_trace_arming as trace

STATE = """
st = { world = 2, level = 1, theme = 2, level_count = 4, time_total = 15169, time_level = 2,
       quest_flags = 0, presence_flags = 0, items = { player_inventory = {} } }
function get_local_state() return st end
function get_player() return nil end
prng = { get_pair = function(_, c) return 0x1000 + c, 0x2000 + c end }
"""


def floor_block(tmp_path, extra=""):
    rt = trace.runtime(tmp_path)
    rt.execute(STATE + extra)
    rt.execute("DesyncLog.init()")
    rt.execute("DesyncLog.floorSnapshot(9, 1, 2, { [388] = 7 })")
    rt.execute("DesyncLog.genPhase('post')")
    return (tmp_path / "desync_log.txt").read_text(encoding="utf-8").splitlines()


def test_the_floor_block_carries_every_stream_at_engage(tmp_path):
    lines = floor_block(tmp_path)
    head = next(i for i, line in enumerate(lines) if "---- FLOOR seq=9" in line)
    block = lines[head:head + 6]
    prng = [line for line in block if line.startswith("  prng: ")]
    assert len(prng) == 1, block
    streams = prng[0][len("  prng: "):].split()
    assert streams == [f"c{c}={0x1000 + c:08X}:{0x2000 + c:08X}" for c in range(10)]
    order = [line.split(":")[0].strip() for line in block[1:]]
    assert order.index("gate") < order.index("prng") < order.index("entities")


def test_it_reads_exactly_like_the_gen_lines(tmp_path):
    """Same form, so the two can be compared by eye or by script."""
    lines = floor_block(tmp_path)
    engage = next(line for line in lines if line.startswith("  prng: "))[len("  prng: "):]
    gen = next(line for line in lines if "gen[post]" in line)
    assert gen.endswith("prng " + engage)


def test_a_build_whose_prng_cannot_be_read_still_writes_the_block(tmp_path):
    lines = floor_block(tmp_path, "prng = nil")
    assert any("entities: 7 total" in line for line in lines)
    assert any(line.rstrip() == "  prng:" for line in lines)
