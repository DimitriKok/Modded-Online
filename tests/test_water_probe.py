"""The water probe: which of four things differs between two machines' water.

dev75 hides FX_WATER_SURFACE from a hosted mod's ON.LEVEL in a room, so the swamp's
lily pads (and the HD mod's lily pads and frogs) are gone online. Whether they can
come back depends on what actually differs when the mods look:

  * MATCH     -- nothing: the anchor alone was the fix, the hiding can go;
  * ORDER     -- the same surfaces, listed in another order: sort them;
  * SETTLING  -- different at ON.LEVEL, the same by the first frame: wait;
  * DIFFERENT -- still different then: only the world host's waterline will do.

dev76 measures it and changes nothing else. These tests hold it to both halves:
the four verdicts come out right, and the probe itself only reads.

Run:  python -m pytest tests/test_water_probe.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")

NL = chr(10)

ENGINE = """
registered, events, queries = {}, {}, 0
frameNo, simNo = 1000, 15169
draws = 0
function get_adventure_seed() return 0x5EEDF00D, 0xD125E0C4 end
function get_local_state()
    return { world = 2, level = 1, theme = 2, time_total = simNo }
end
function get_frame() return frameNo end
function seed_prng() end
prng = {
    get_pair = function(_, c) return c, c end,
    set_pair = function() end,
    random_int = function() draws = draws + 1; return 0 end,
}
ON = {
    FRAME = 1, GAMEFRAME = 2, LOADING = 3, LEVEL = 4,
    PRE_LEVEL_GENERATION = 5, POST_LEVEL_GENERATION = 6,
    PRE_LOAD_LEVEL_FILES = 7, PRE_LOAD_SCREEN = 8,
    PRE_UPDATE = 9, POST_UPDATE = 10, GUIFRAME = 11,
}
ENT_TYPE = { FX_WATER_SURFACE = 680, LIQUID_WATER = 1100, ITEM_LEAF = 388 }
MASK = { ANY = 0, ITEM = 8, FX = 64, WATER = 8192, LAVA = 16384, LIQUID = 24576 }
LAYER = { FRONT = 0, BACK = 1, BOTH = -128 }

entities, nextUid = {}, 100
function spawnEntity(t, mask, layer, x, y)
    nextUid = nextUid + 1
    entities[nextUid] = { type = t, mask = mask, layer = layer, x = x, y = y }
    return nextUid
end
function water(x, y) return spawnEntity(ENT_TYPE.LIQUID_WATER, MASK.WATER, LAYER.FRONT, x, y) end
function surface(x, y) return spawnEntity(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT, x, y) end
local function typeMatches(types, t)
    if type(types) == "table" then
        for _, want in ipairs(types) do
            if want == 0 or want == t then return true end
        end
        return #types == 0
    end
    return types == nil or types == 0 or types == t
end
function get_entities_by(types, mask, layer)
    queries = queries + 1
    local out = {}
    for uid = 101, nextUid do
        local e = entities[uid]
        if e ~= nil and typeMatches(types, e.type)
            and (mask == nil or mask == 0 or (e.mask & mask) ~= 0)
            and (layer == nil or layer == LAYER.BOTH or e.layer == layer) then
            out[#out + 1] = uid
        end
    end
    return out
end
function get_entity_type(uid) return entities[uid] and entities[uid].type end
function get_entity(uid)
    local e = entities[uid]
    return e and { uid = uid, type = { id = e.type } }
end
function get_position(uid)
    local e = entities[uid]
    if e == nil then return 0, 0, 0 end
    return e.x, e.y, e.layer
end
function set_callback(fn, id)
    registered[#registered + 1] = { fn = fn, id = id }
    return #registered
end
function fire(id, ...)
    for _, entry in ipairs(registered) do
        if entry.id == id then entry.fn(...) end
    end
end
DesyncLog = { event = function(fmt, ...) events[#events + 1] = string.format(fmt, ...) end }
"""

# 2.5's lily pads, in their shape: one query for every surface effect at ON.LEVEL
LILY_PADS = """
seenByMod = -1
env.set_callback(function()
    seenByMod = #env.get_entities_by(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT)
end, ON.LEVEL)
"""


def machine(active=True, mod=True):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(DETERMINISM)
    rt.execute("env = setmetatable({}, {__index = _G})")
    rt.execute(f"activeFlag = {str(active).lower()}")
    rt.eval("Determinism.install")(rt.eval("env"), rt.eval("{ active = function() return activeFlag end }"))
    if mod:
        rt.execute(LILY_PADS)
    return rt


def floor(rt, *, at_level, at_engage=None, pool=((2, 3), (3, 3), (4, 3)), back=()):
    """Generation (the pool's water), then the surfaces the liquid made by ON.LEVEL
    (`back` in the back layer), then any it made before the gate engaged. Returns
    the engage report."""
    rt.execute("for uid in pairs(entities) do entities[uid] = nil end")
    for x, y in pool:
        rt.execute(f"water({x}, {y})")
    rt.execute("fire(ON.POST_LEVEL_GENERATION)")
    for x, y in at_level:
        rt.execute(f"surface({x}, {y})")
    for x, y in back:
        rt.execute(f"spawnEntity(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.BACK, {x}, {y})")
    rt.execute("frameNo = frameNo + 1; fire(ON.LEVEL)")
    for x, y in at_engage or ():
        rt.execute(f"surface({x}, {y})")
    rt.execute("frameNo = frameNo + 2; simNo = simNo + 2")
    return rt.eval("Determinism.waterReport()")


def verdict(host_rt, peer_rt, host_report, peer_report):
    """The peer's verdict. The host's wire crosses over as the network would carry
    it: as plain values, rebuilt in the peer's own Lua state."""
    host_wire = peer_rt.table_from({k: v for k, v in host_report["wire"].items()})
    return peer_rt.eval("Determinism.waterVerdict")(peer_report["wire"], host_wire, 9)


SURFACES = ((2, 3.6), (3, 3.6), (4, 3.6))


# ------------------------------------------------------------------ the verdicts

def test_identical_water_is_a_match():
    host, peer = machine(), machine()
    line = verdict(host, peer, floor(host, at_level=SURFACES), floor(peer, at_level=SURFACES))
    assert line.startswith("WATER PROBE seq=9: MATCH"), line
    assert "what the mod saw: MATCH" in line


def test_the_same_surfaces_in_another_order_is_order():
    """The engine lists by uid; one machine's liquid made them in another order."""
    host, peer = machine(), machine()
    line = verdict(host, peer, floor(host, at_level=SURFACES),
                   floor(peer, at_level=tuple(reversed(SURFACES))))
    assert line.startswith("WATER PROBE seq=9: ORDER"), line
    assert "other order" in line


def test_different_when_the_mod_looked_but_the_same_by_the_first_frame_is_settling():
    host, peer = machine(), machine()
    host_report = floor(host, at_level=SURFACES)
    peer_report = floor(peer, at_level=SURFACES[:2], at_engage=SURFACES[2:])  # one late
    line = verdict(host, peer, host_report, peer_report)
    assert line.startswith("WATER PROBE seq=9: SETTLING"), line
    assert "(2 here, 3 on the host" in line


def test_still_different_at_the_first_frame_is_different():
    host, peer = machine(), machine()
    line = verdict(host, peer, floor(host, at_level=SURFACES),
                   floor(peer, at_level=((2, 3.6), (3, 3.6), (4, 3.75))))
    assert line.startswith("WATER PROBE seq=9: DIFFERENT"), line
    assert "same tiles, moved within them" in line


def test_a_surface_in_another_tile_is_simply_different():
    host, peer = machine(), machine()
    line = verdict(host, peer, floor(host, at_level=SURFACES),
                   floor(peer, at_level=((2, 3.6), (3, 3.6), (4, 3.4))))
    assert line.startswith("WATER PROBE seq=9: DIFFERENT"), line
    assert "on the host: different)" in line


def test_the_verdict_is_about_what_the_mod_asked_for():
    """2.5 asks for the FRONT layer only. A back-layer surface that differs changes the
    probe's own whole-level list, not the lily pads: that floor is still a MATCH."""
    host, peer = machine(), machine()
    line = verdict(host, peer, floor(host, at_level=SURFACES, back=((9, 9.6),)),
                   floor(peer, at_level=SURFACES))
    assert line.startswith("WATER PROBE seq=9: MATCH"), line
    assert "surfaces DIFFER (3 here, 4 on the host" in line


def test_a_floor_the_mod_never_asked_about_is_judged_on_the_engines_list():
    host, peer = machine(mod=False), machine(mod=False)
    line = verdict(host, peer, floor(host, at_level=SURFACES),
                   floor(peer, at_level=tuple(reversed(SURFACES))))
    assert "ORDER" in line and "(the mod did not ask on this floor)" in line
    assert "what the mod saw: n/a" in line


def test_a_dry_floor_says_nothing():
    host, peer = machine(), machine()
    host_report = floor(host, at_level=(), pool=())
    peer_report = floor(peer, at_level=(), pool=())
    assert verdict(host, peer, host_report, peer_report) is None
    assert host_report["lines"] is None


# ------------------------------------------------------------- what it records

def test_every_point_of_the_floor_is_recorded():
    rt = machine()
    report = floor(rt, at_level=SURFACES, at_engage=((5, 3.6),))
    wire = report["wire"]
    assert int(wire["gn"]) == 3, "the generated pool"
    assert int(wire["fn"]) == 3, "the surfaces at ON.LEVEL"
    assert int(wire["mq"]) == 1 and int(wire["mn"]) == 3, "what the mod's query would have got"
    assert int(wire["ef"]) == 4, "the surfaces at engage"
    lines = list(report["lines"].values())
    assert lines[0].startswith("water: generated liquid 3 ")
    assert "+1 frames" in lines[0] and "the mod asked 1 time(s): 3 hidden" in lines[0]
    assert lines[1].endswith("2.00,3.60,0 3.00,3.60,0 4.00,3.60,0")


def test_the_mod_still_sees_nothing():
    """Measurement only: dev75's hiding is exactly as it was."""
    rt = machine()
    floor(rt, at_level=SURFACES)
    assert int(rt.eval("seenByMod")) == 0


def test_it_looks_before_the_mod_does():
    """Registered at install, ahead of every callback the mod registers: a surface the
    mod's own ON.LEVEL work makes is not in the 'about to see' sample."""
    rt = machine(mod=False)
    rt.execute("env.set_callback(function() surface(9, 9) end, ON.LEVEL)")
    rt.execute(LILY_PADS)
    report = floor(rt, at_level=SURFACES)
    assert int(report["wire"]["fn"]) == 3
    assert int(report["wire"]["mn"]) == 4


def test_an_empty_answer_counts_as_a_query():
    """One machine finding a surface where the other finds none is the difference."""
    rt = machine()
    report = floor(rt, at_level=())
    assert int(report["wire"]["mq"]) == 1 and int(report["wire"]["mn"]) == 0


def test_water_moving_while_the_mods_look_is_caught():
    """A clock that ticks while another thread moves a surface: the second look differs."""
    rt = machine()
    rt.execute("""
        clockNow, mover = 0, nil
        os.clock = function()
            clockNow = clockNow + 0.001
            if mover ~= nil then entities[mover].y = entities[mover].y - 0.05 end
            return clockNow
        end
    """)
    rt.execute("for uid in pairs(entities) do entities[uid] = nil end; water(2, 3)")
    rt.execute("fire(ON.POST_LEVEL_GENERATION); mover = surface(2, 3.6); fire(ON.LEVEL)")
    report = rt.eval("Determinism.waterReport()")
    assert int(report["wire"]["mv"]) == 1
    assert "moving YES" in list(report["lines"].values())[0]


def test_still_water_is_not_moving():
    rt = machine()
    report = floor(rt, at_level=SURFACES)
    assert int(report["wire"]["mv"]) == 0


def test_a_clock_that_never_advances_cannot_hang_the_load():
    rt = machine()
    rt.execute("os.clock = function() return 7 end")
    report = floor(rt, at_level=SURFACES)
    assert int(report["wire"]["fn"]) == 3


def test_each_floor_starts_afresh():
    rt = machine()
    floor(rt, at_level=SURFACES)
    rt.execute("fire(ON.POST_LEVEL_GENERATION)")  # the next floor, before its ON.LEVEL
    report = rt.eval("Determinism.waterReport()")
    assert int(report["wire"]["mq"]) == 0 and int(report["wire"]["fn"]) == 0


# --------------------------------------------------------- it only reads, in a room

def test_alone_nothing_is_measured():
    rt = machine(active=False, mod=False)
    rt.execute("queries = 0")
    assert floor(rt, at_level=SURFACES) is None
    assert int(rt.eval("queries")) == 0


def test_it_draws_nothing_and_changes_nothing():
    rt = machine()
    before = rt.eval("draws")
    floor(rt, at_level=SURFACES)
    assert rt.eval("draws") == before
    positions = sorted((float(e["x"]), float(e["y"])) for e in rt.eval("entities").values())
    assert positions == sorted([(2, 3), (3, 3), (4, 3), (2, 3.6), (3, 3.6), (4, 3.6)])
    assert int(rt.eval("nextUid")) == 106, "spawned something"


def test_two_hosted_mods_share_one_probe():
    rt = machine()
    rt.execute("env2 = setmetatable({}, {__index = _G})")
    rt.eval("Determinism.install")(rt.eval("env2"), rt.eval("{ active = function() return true end }"))
    rt.execute("""
        env2.set_callback(function()
            env2.get_entities_by(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT)
        end, ON.LEVEL)
    """)
    probes = [e for e in rt.eval("registered").values() if int(e["id"]) == 6]
    assert len(probes) == 3, "two liquid snapshots and ONE probe at POST_LEVEL_GENERATION"
    report = floor(rt, at_level=SURFACES)
    assert int(report["wire"]["mq"]) == 2, "both mods' queries, in the order they ran"


# --------------------------------------------------- inputSync: send, compare, say

def _slice(start: str, end: str) -> str:
    assert start in INPUT_SYNC, f"{start!r} not found in src/inputSync.lua"
    i = INPUT_SYNC.index(start)
    j = INPUT_SYNC.index(end, i)
    return INPUT_SYNC[i:j + len(end)]


def extract(start: str) -> str:
    return _slice(start, NL + "end" + NL)


GATE_ENV = """
module, sent, events = {}, {}, {}
active, seq, amHost = true, 9, false
myFloorDigest, hostFloorDigests, floorMismatchSeq = nil, {}, nil
Network = {
    slot = 2,
    isInRun = function() return true end,
    isWorldHost = function() return amHost end,
    hostSlot = function() return 1 end,
    sendEvent = function(kind, payload) sent[#sent + 1] = { kind = kind, payload = payload } end,
}
function errorf() end
function computeFloorDigest() return 111, 222, { [388] = 7 } end
snapshotExtra = nil
DesyncLog = {
    enter = function() end, leave = function() end, floorMismatch = function() end,
    floorSnapshot = function(_, _, _, _, extra) snapshotExtra = extra end,
    event = function(fmt, ...) events[#events + 1] = string.format(fmt, ...) end,
}
myWire = { x = 1 }
Determinism = {
    waterReport = function()
        if myWire == nil then return nil end
        return { wire = myWire, lines = { "water: here" } }
    end,
    waterVerdict = function(mine, host, s)
        return "WATER PROBE seq=" .. s .. ": " .. (mine.x == host.x and "MATCH" or "DIFFERENT")
    end,
}
"""


def gate():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(GATE_ENV)
    rt.execute(extract("function module.checkFloorDigest(s)"))
    rt.execute(extract("function module.checkWaterProbe(s)"))
    rt.execute(extract("function module.sendWorldDigest()"))
    rt.execute(extract("local function onWorldChk(payload, originSlot)") + "onWorldChkG = onWorldChk" + NL)
    return rt


def probe_lines(rt):
    return [str(v) for v in rt.eval("events").values() if str(v).startswith("WATER PROBE")]


def test_the_digest_carries_the_water_and_the_block_shows_it():
    rt = gate()
    rt.execute("module.sendWorldDigest()")
    payload = rt.eval("sent[1].payload")
    assert rt.eval("sent[1].kind") == "worldchk" and int(payload["w"]["x"]) == 1
    assert list(rt.eval("snapshotExtra").values()) == ["water: here"]


def test_a_peer_says_it_once_whichever_report_lands_first():
    late = gate()
    late.execute("module.sendWorldDigest()")
    late.execute("onWorldChkG({ s = 9, sd = 111, e = 222, w = { x = 1 } }, 1)")
    late.execute("onWorldChkG({ s = 9, sd = 111, e = 222, w = { x = 1 } }, 1)")  # a resend
    assert probe_lines(late) == ["WATER PROBE seq=9: MATCH"]
    early = gate()
    early.execute("onWorldChkG({ s = 9, sd = 111, e = 222, w = { x = 2 } }, 1)")
    assert probe_lines(early) == []
    early.execute("module.sendWorldDigest()")
    assert probe_lines(early) == ["WATER PROBE seq=9: DIFFERENT"]


def test_the_world_host_never_judges_itself():
    rt = gate()
    rt.execute("amHost = true; module.sendWorldDigest()")
    rt.execute("onWorldChkG({ s = 9, sd = 111, e = 222, w = { x = 2 } }, 1)")
    assert probe_lines(rt) == []


def test_no_probe_no_water_on_the_wire():
    rt = gate()
    rt.execute("myWire = nil; module.sendWorldDigest()")
    assert rt.eval("sent[1].payload.w") is None
    rt.execute("onWorldChkG({ s = 9, sd = 111, e = 222, w = { x = 1 } }, 1)")
    assert probe_lines(rt) == []


def test_a_host_report_without_water_is_not_judged():
    """A host on an older build sends no `w`: nothing to compare, nothing said."""
    rt = gate()
    rt.execute("module.sendWorldDigest()")
    rt.execute("onWorldChkG({ s = 9, sd = 111, e = 222 }, 1)")
    assert probe_lines(rt) == []
