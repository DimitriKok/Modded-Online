"""Tests the leaked-entity sweep's cadence -- the part that is lockstep-critical.

The sweep walks every MONSTER|ITEM|ACTIVEFLOOR|DECORATION|FX|EXPLOSION|ROPE entity
on the floor and destroys the ones parked outside it. A profile capture showed it
taking 25-34ms in a single frame -- twice a 60fps budget -- while destroying nothing
all session, so the interval went from 30 simulated frames to 150.

That is only safe because of an arithmetic property, which is what these tests pin:
an entity is destroyed at the first sweep where `now - since >= SWEEP_GRACE`, and
both `since` and `now` are multiples of SWEEP_EVERY. While SWEEP_EVERY divides
SWEEP_GRACE, destruction happens EXACTLY SWEEP_GRACE frames after first sighting --
the same frame the old interval gave. If someone later picks an interval that does
not divide the grace, the latency silently grows and every machine must still agree.

Run:  python -m pytest tests/test_leak_sweep.py -q
"""

from __future__ import annotations

import pathlib
import re

EVENT_SYNC = (pathlib.Path(__file__).resolve().parent.parent
              / "src" / "eventSync.lua").read_text(encoding="utf-8")


def _const(name):
    m = re.search(r"^local %s = (\d+)" % name, EVENT_SYNC, re.M)
    assert m is not None, "%s is gone" % name
    return int(m.group(1))


def test_the_interval_divides_the_grace_period():
    """Otherwise the interval change quietly costs destruction latency."""
    every, grace = _const("SWEEP_EVERY"), _const("SWEEP_GRACE")
    assert grace % every == 0, (
        "SWEEP_EVERY=%d does not divide SWEEP_GRACE=%d, so an entity is destroyed "
        "later than the grace period promises" % (every, grace))


def test_destruction_lands_exactly_one_grace_period_after_first_sighting():
    """The whole argument for the cheaper interval, simulated."""
    every, grace = _const("SWEEP_EVERY"), _const("SWEEP_GRACE")
    for appeared in range(0, 3 * every):
        sweeps = [f for f in range(0, 20 * every) if f % every == 0]
        since = next(f for f in sweeps if f >= appeared)
        destroyed = next(f for f in sweeps if f - since >= grace)
        assert destroyed - since == grace, (
            "entity appearing at frame %d is destroyed %d frames after it was first "
            "seen, not %d" % (appeared, destroyed - since, grace))


def test_a_stalled_simulation_cannot_re_sweep_the_same_frame():
    """POST_UPDATE fires per RENDERED frame. While the lockstep gate holds the sim
    still, time_level stops advancing -- and if it stops on a multiple of the
    interval, the scan would run again on every rendered frame of the stall."""
    assert "now == lastSweptFrame" in EVENT_SYNC
    assert "lastSweptFrame = now" in EVENT_SYNC


def test_the_sweep_still_destroys_from_post_update():
    """GAMEFRAME fires from inside the engine's update, so destroying there frees
    entities while the engine may still be walking its own list."""
    at = EVENT_SYNC.index("pollSweepParked)")
    assert "ON.POST_UPDATE" in EVENT_SYNC[at:at + 200]
