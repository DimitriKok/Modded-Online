"""Tests the leaked-entity sweep's cadence -- the part that is lockstep-critical.

The sweep walks every MONSTER|ITEM|DECORATION|FX|EXPLOSION|ROPE entity on the floor
(ACTIVEFLOOR too, until dev79) and destroys the ones parked outside it once they pile
up (since dev79; see the tests at the end). A profile capture showed it
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


# ------------------------------------------------- what it touches (dev79)
#
# Room UVLQ: on both summit floors 2.5 parked ~360 entities as the floor began, the
# sweep destroyed them at frame 450, and the host crashed in 2-2's teardown just
# after one of 2.5's PRE_LEVEL_DESTRUCTION callbacks returned. Solo 2.5 never
# destroys what it parks: its own destroy never runs out there, and the teardown
# takes them with the level. So the sweep now leaves them alone until they pile up
# past SWEEP.LIMIT -- the lair boss's thousands of claws, which is what it was built
# for -- and never touches an ACTIVEFLOOR, which can be a grid entity.

import lupa

DESYNC_LOG = (pathlib.Path(__file__).resolve().parent.parent
              / "src" / "desyncLog.lua").read_text(encoding="utf-8").replace("\r\n", "\n")
NL = chr(10)


def _sweep_block() -> str:
    start = EVENT_SYNC.index("local PARKED_X = -900")
    fn = EVENT_SYNC.index("local function pollSweepParked()")
    end = EVENT_SYNC.index(NL + "end" + NL, fn) + len(NL + "end" + NL)
    return EVENT_SYNC[start:end]


def _type_counts() -> str:
    start = DESYNC_LOG.index("function module.typeCounts(counts, max)")
    end = DESYNC_LOG.index(NL + "end" + NL, start) + len(NL + "end" + NL)
    return DESYNC_LOG[start:end]


SWEEP_ENV = """
MASK = { MONSTER = 4, ITEM = 8, ACTIVEFLOOR = 128, DECORATION = 512, FX = 64,
         EXPLOSION = 32, ROPE = 16 }
LAYER = { BOTH = -128 }
SCREEN = { LEVEL = 12 }
FADE = { NONE = 0 }
ENT_TYPE = { ITEM_ROCK = 365, DECORATION_X = 700, MONS_SNAKE = 220 }
function PackPath(n) return "nonexistent/" .. n end
module = {}
runActive = true
Network = { isInRun = function() return true end }
state = { screen = 12, loading = 0, time_level = 0 }
function get_local_state() return state end
entities = {}      -- uid -> { x = ..., kind = ..., destroyed = false }
destroyedOrder = {}
askedMask = nil
function get_entities_by(_, mask, _)
    askedMask = mask
    local uids = {}
    for uid, e in pairs(entities) do
        if not e.destroyed then uids[#uids + 1] = uid end
    end
    table.sort(uids)
    return uids
end
function get_entity(uid)
    local e = entities[uid]
    if e == nil or e.destroyed then return nil end
    return {
        x = e.x, type = { id = e.kind },
        destroy = function() e.destroyed = true; destroyedOrder[#destroyedOrder + 1] = uid end,
    }
end
lines = {}
DesyncLog = { event = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end }
"""


def sweep_runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(SWEEP_ENV)
    rt.execute("do local entNameById = nil\n"
               "local function entName(id) for k, v in pairs(ENT_TYPE) do if v == id then return k end end"
               " return 'ID_' .. tostring(id) end\n"
               + _type_counts() + "DesyncLog.typeCounts = module.typeCounts end")
    rt.execute(_sweep_block() + "\nT = { poll = pollSweepParked, SWEEP = SWEEP, masks = SWEEP_MASKS }\n")
    return rt


def park(rt, first_uid, n, kind="ENT_TYPE.ITEM_ROCK"):
    rt.execute(f"for i = {first_uid}, {first_uid + n - 1} do "
               f"entities[i] = {{ x = -1000, kind = {kind} }} end")


def frames(rt, *at):
    for f in at:
        rt.execute(f"state.time_level = {f}")
        rt.eval("T.poll")()


def destroyed(rt):
    return [int(u) for u in rt.eval("destroyedOrder").values()]


def test_a_floor_like_the_summits_is_left_as_unhosted_25_leaves_it():
    """~360 parked at the start of the floor: none destroyed, at any point."""
    rt = sweep_runtime()
    park(rt, 100, 300)
    park(rt, 400, 60, kind="ENT_TYPE.DECORATION_X")
    frames(rt, 150, 300, 450, 600, 3000)
    assert destroyed(rt) == [], "the sweep destroyed what solo 2.5 would have kept"
    lines = [str(l) for l in rt.eval("lines").values()]
    assert len(lines) == 1, "the census goes in the log once a floor"
    assert "parked outside the level by the mod: 360 at frame 150" in lines[0]
    assert "ITEM_ROCK 300, DECORATION_X 60" in lines[0]
    assert "left where the mod put them" in lines[0]


def test_a_pile_up_past_the_limit_is_still_swept():
    """The lair boss's claws: thousands, which is what the sweep was built for."""
    rt = sweep_runtime()
    limit = int(rt.eval("T.SWEEP.LIMIT"))
    park(rt, 1, limit + 200)
    frames(rt, 150, 300)
    assert destroyed(rt) == [], "swept before the grace period"
    frames(rt, 450)
    assert destroyed(rt) == list(range(1, limit + 201)), "not every eligible one, or not in uid order"
    lines = [str(l) for l in rt.eval("lines").values()]
    assert any(l.startswith("swept %d leaked" % (limit + 200)) and "ITEM_ROCK" in l for l in lines), lines


def test_only_the_entities_parked_long_enough_go():
    rt = sweep_runtime()
    limit = int(rt.eval("T.SWEEP.LIMIT"))
    park(rt, 1, limit)            # since frame 150
    frames(rt, 150)
    park(rt, 5000, 50)            # since frame 300
    frames(rt, 300, 450)
    gone = destroyed(rt)
    assert gone == list(range(1, limit + 1)), "the newly parked went before their grace was up"


def test_an_activefloor_is_never_swept():
    """It can be a grid entity; a plain destroy() leaves the grid pointing at it."""
    rt = sweep_runtime()
    mask = int(rt.eval("T.masks"))
    assert mask & int(rt.eval("MASK.ACTIVEFLOOR")) == 0
    frames(rt, 150)  # and it is what the scan asks the engine for
    assert int(rt.eval("askedMask")) & int(rt.eval("MASK.ACTIVEFLOOR")) == 0


def test_the_census_resets_with_the_floor():
    assert "SWEEP.censusLogged = false" in EVENT_SYNC
    at = EVENT_SYNC.index("sweptTotal = 0\n        SWEEP.censusLogged = false")
    assert "parkedSince = {}" in EVENT_SYNC[at - 200:at]
