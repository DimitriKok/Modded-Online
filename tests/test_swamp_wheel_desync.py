"""2.5's swamp: two machines must build the same shop from the same 2-1.

The BGNY capture (dev73, 2.5, two players). 1-1 to 1-4 matched; 2-1 generated
identically -- seed and all ten PRNG streams equal at gen[pre] and gen[post] -- and
still, at the first frame, the floors differed in exactly four entity types:

    host (slot 1):  ITEM_LEAF=7  ITEM_DIE=2  ITEM_DICE_BET=1  ITEM_CONSTRUCTION_SIGN=1
    peer (slot 2):  ITEM_LEAF=8  ITEM_DIE=0  ITEM_DICE_BET=0  ITEM_CONSTRUCTION_SIGN=2

The host kept the dice house; the peer had turned it into 2.5's new Wheel of
Fortune (hooks/wheelOfFortune.lua removes the bet machine and both dice and adds an
invisible construction sign). That conversion is a coin, `prng:random_int(0, 1,
PROCEDURAL_SPAWNS)`, flipped on the first playable POST_UPDATE. Its inputs were
identical; the stream it drew from was not. The extra ITEM_LEAF is why: 2.5's swamp
lily pads (hooks/swamp/water.lua) are ITEM_LEAF, placed at ON.LEVEL on the engine's
FX_WATER_SURFACE effects, which the liquid system creates after generation from
water its worker threads are already moving. One more surface effect is one more
shuffle draw and one more chance roll on PROCEDURAL_SPAWNS -- one more pad, and a
moved stream for the coin.

dev75 answered that by hiding the surface effects from a hosted mod's ON.LEVEL, at
the price of the pads. dev76 measured the water (room FVJF, 2-1 to 4-2): the surfaces
were identical on both machines on every wet floor. What differed on 2-1 was the
ORDER the mod's ON.LEVEL callbacks ran in (Overlunky keeps them in an unordered_map),
which is the other way BGNY's stream could have moved. dev77 shows the surfaces
again: the ON.LEVEL anchor keeps one callback's draws out of the next one's, and the
registration order (tests/test_level_order.py) keeps what they spawn in step.

The model here is that, on a PRNG that really has state.

Run:  python -m pytest tests/test_swamp_wheel_desync.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")

ENGINE = """
seedFirst, worldNo, levelNo, themeNo, timeTotal = 0x5EEDF00D, 2, 1, 2, 15169
registered = {}
seeded = {}
events = {}
typeLookups = 0
function get_adventure_seed() return seedFirst, 0xD125E0C4 end
function get_local_state()
    return { world = worldNo, level = levelNo, theme = themeNo, time_total = timeTotal }
end
ON = {
    FRAME = 1, GAMEFRAME = 2, LOADING = 3, LEVEL = 4,
    PRE_LEVEL_GENERATION = 5, POST_LEVEL_GENERATION = 6,
    PRE_LOAD_LEVEL_FILES = 7, PRE_LOAD_SCREEN = 8,
    PRE_UPDATE = 9, POST_UPDATE = 10, GUIFRAME = 11,
}
ENT_TYPE = { FX_WATER_SURFACE = 1050, FX_WATER_DROP = 1049, ITEM_LEAF = 388, ITEM_DIE = 470 }
MASK = { ANY = 0, ITEM = 8, FX = 64, WATER = 8192 }
LAYER = { FRONT = 0, BACK = 1, BOTH = -128 }
PRNG_CLASS = { PROCEDURAL_SPAWNS = 0, PARTICLES = 2, ENTITY_VARIATION = 3, LEVEL_DECO = 8 }

-- ten independent streams, as the engine keeps them (PRNG_CLASS 0..9)
streams = {}
function seed_prng(seed)
    seeded[#seeded + 1] = seed
    for c = 0, 9 do
        streams[c] = { a = ((seed ~ (c * 0x9E3779B9)) & 0xFFFFFFFF) | 1, b = c }
    end
end
local function draw(c)
    local s = streams[c]
    local x = s.a
    x = x ~ ((x << 13) & 0xFFFFFFFF)
    x = x ~ (x >> 17)
    x = x ~ ((x << 5) & 0xFFFFFFFF)
    s.a, s.b = x & 0xFFFFFFFF, s.b + 1
    return s.a
end
prng = {
    get_pair = function(_, c) return streams[c].a, streams[c].b end,
    set_pair = function(_, c, a, b) streams[c] = { a = a, b = b } end,
    random_int = function(_, lo, hi, c) return lo + draw(c) % (hi - lo + 1) end,
    random_index = function(_, n, c) if n <= 0 then return nil end return 1 + draw(c) % n end,
    random_chance = function(_, inverse, c) return draw(c) % inverse == 0 end,
}
seed_prng(0)
function stream(c) return string.format("%08X:%d", streams[c].a, streams[c].b) end

-- the world's entities, by uid
entities, nextUid = {}, 100
function spawnEntity(t, mask, layer, x, y)
    nextUid = nextUid + 1
    entities[nextUid] = { type = t, mask = mask, layer = layer, x = x, y = y }
    return nextUid
end
local function typeMatches(types, t)
    if type(types) == "table" then
        if #types == 0 then return true end
        for _, want in ipairs(types) do
            if want == 0 or want == t then return true end
        end
        return false
    end
    return types == nil or types == 0 or types == t
end
local function query(types, mask, layer, near)
    local out = {}
    for uid = 101, nextUid do
        local e = entities[uid]
        if e ~= nil and typeMatches(types, e.type)
            and (mask == nil or mask == 0 or (e.mask & mask) ~= 0)
            and (layer == nil or layer == LAYER.BOTH or e.layer == layer)
            and (near == nil or near(e)) then
            out[#out + 1] = uid
        end
    end
    return out
end
function get_entities_by(types, mask, layer) return query(types, mask, layer) end
function get_entities_by_type(...)
    local first = ...
    return query(type(first) == "table" and first or { ... }, 0, LAYER.BOTH)
end
function get_entities_at(types, mask, x, y, layer, radius)
    return query(types, mask, layer, function(e)
        return (e.x - x) ^ 2 + (e.y - y) ^ 2 <= radius ^ 2
    end)
end
function get_entities_overlapping_hitbox(types, mask, box, layer)
    return query(types, mask, layer, function(e)
        return e.x >= box.left and e.x <= box.right and e.y <= box.top and e.y >= box.bottom
    end)
end
function get_entity_type(uid)
    typeLookups = typeLookups + 1
    return entities[uid] and entities[uid].type
end
function get_entity(uid)
    local e = entities[uid]
    return e and { uid = uid, type = { id = e.type } }
end

function set_callback(fn, id)
    registered[#registered + 1] = { fn = fn, id = id }
    return #registered
end
function fire(id, ...)
    local result
    for _, entry in ipairs(registered) do
        if entry.id == id then
            local r = entry.fn(...)
            if r ~= nil then result = r end
        end
    end
    return result
end
DesyncLog = { event = function(fmt, ...) events[#events + 1] = string.format(fmt, ...) end }
"""

# The two 2.5 hooks, in their own shape. The lily pads: hooks/swamp/water.lua
# collectLilyPadCandidates / shuffleLilyPadCandidates / spawnLilyPads. The coin:
# hooks/wheelOfFortune.lua convertShop, then one step of motion.update per POST_UPDATE.
MOD = """
lilyPads, candidatesSeen, coin, steps = 0, -1, nil, 0
env.set_callback(function()
    local candidates = {}
    for _, uid in ipairs(env.get_entities_by(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT)) do
        candidates[#candidates + 1] = uid
    end
    candidatesSeen = #candidates
    for index = #candidates, 2, -1 do
        local swap = prng:random_index(index, PRNG_CLASS.PROCEDURAL_SPAWNS) or index
        candidates[index], candidates[swap] = candidates[swap], candidates[index]
    end
    for _ = 1, #candidates do
        if prng:random_chance(5, PRNG_CLASS.PROCEDURAL_SPAWNS) then
            lilyPads = lilyPads + 1
        end
    end
end, ON.LEVEL)
env.set_callback(function()
    if coin == nil then
        coin = prng:random_int(0, 1, PRNG_CLASS.PROCEDURAL_SPAWNS)
    end
    steps = steps + 1
end, ON.POST_UPDATE)
"""


def install(active=True, held=False, extra_opts=""):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(DETERMINISM)
    rt.execute("env = setmetatable({}, {__index = _G})")
    rt.execute(f"activeFlag, heldFlag = {str(active).lower()}, {str(held).lower()}")
    control = rt.eval("Determinism.install")(rt.eval("env"), rt.eval(
        "{ active = function() return activeFlag end,"
        "  heldFrame = function() return heldFlag end" + extra_opts + " }"))
    control["detectAdapters"]()
    return rt, control


def floor_2_1(water_surfaces, active=True, level_seed=1234, with_mod=True):
    """One machine's 2-1: generation, the waterline its liquid made, ON.LEVEL."""
    rt, control = install(active=active)
    if with_mod:
        rt.execute(MOD)
    # generation, identical everywhere: the engine seeds and draws the layout
    rt.execute(f"seed_prng({level_seed})")
    rt.execute("for _ = 1, 25 do prng:random_int(0, 9, PRNG_CLASS.PROCEDURAL_SPAWNS) end")
    rt.execute("fire(ON.POST_LEVEL_GENERATION)")
    rt.execute("afterGeneration = stream(0)")
    # the liquid system makes the waterline's surface effects after generation
    rt.execute(f"for i = 1, {water_surfaces} do"
               " spawnEntity(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT, i, 5) end")
    rt.execute("fire(ON.LEVEL)")
    rt.execute("afterLevel = stream(0)")
    return rt, control


def first_frame(rt):
    rt.execute("fire(ON.PRE_UPDATE); fire(ON.POST_UPDATE)")


# ------------------------------------------------------------- the 2-1 capture

def test_two_machines_with_the_same_water_build_the_same_floor_lily_pads_and_all():
    """What dev76 measured: the same surfaces on both machines. Every seed: the same
    lily pads, the same coin, and the pads are really there."""
    grew = 0
    for seed in range(1, 121):
        host, _ = floor_2_1(water_surfaces=4, level_seed=seed)
        peer, _ = floor_2_1(water_surfaces=4, level_seed=seed)
        first_frame(host)
        first_frame(peer)
        assert host.eval("coin") == peer.eval("coin"), f"seed {seed}: dice house vs Wheel House"
        assert host.eval("lilyPads") == peer.eval("lilyPads"), f"seed {seed}"
        assert host.eval("afterLevel") == peer.eval("afterLevel"), f"seed {seed}"
        grew += int(host.eval("lilyPads"))
    assert grew > 0, "no lily pads grew online -- they are still being hidden"


def test_even_a_different_waterline_could_not_move_the_coin():
    """BGNY's mechanism, which the anchor alone shuts: whatever the pads draw is put
    back, so the coin is flipped from the stream generation left on every machine."""
    for seed in range(1, 121):
        host, _ = floor_2_1(water_surfaces=3, level_seed=seed)
        peer, _ = floor_2_1(water_surfaces=4, level_seed=seed)
        first_frame(host)
        first_frame(peer)
        assert host.eval("coin") == peer.eval("coin"), f"seed {seed}: dice house vs Wheel House"
        assert host.eval("afterLevel") == peer.eval("afterLevel"), f"seed {seed}"


def test_without_it_the_coin_lands_differently_on_some_floors():
    """The premise, which is the capture: alone, nothing is changed, and the machines'
    one-effect difference in the waterline decides the shop on a share of floors."""
    flipped = 0
    for seed in range(1, 121):
        host, _ = floor_2_1(water_surfaces=3, level_seed=seed, active=False)
        peer, _ = floor_2_1(water_surfaces=4, level_seed=seed, active=False)
        assert host.eval("afterLevel") != peer.eval("afterLevel"), "the stream must have moved"
        first_frame(host)
        first_frame(peer)
        flipped += host.eval("coin") != peer.eval("coin")
    assert flipped > 20, f"only {flipped} of 120 floors flipped -- the model is not the capture"


def test_after_on_level_the_streams_are_exactly_what_generation_left():
    """Whatever the mod's ON.LEVEL pass draws, the engine cannot tell: the coin is
    flipped from the stream generation finished on, as if the pass had not run."""
    rt, _ = floor_2_1(water_surfaces=4)
    assert rt.eval("afterLevel") == rt.eval("afterGeneration")
    bare, _ = floor_2_1(water_surfaces=0, with_mod=False)
    rt.execute("fire(ON.POST_UPDATE)")
    assert bare.eval("prng:random_int(0, 1, PRNG_CLASS.PROCEDURAL_SPAWNS)") == rt.eval("coin")


# ------------------------------------------------------ the water surface effects

def test_in_a_room_the_mods_on_level_sees_the_water_surface_effects_again():
    rt, control = floor_2_1(water_surfaces=4)
    assert int(rt.eval("candidatesSeen")) == 4
    assert int(control["stats"]()["waterFxSeen"]) == 4, "the probe stopped watching"


def test_outside_on_level_the_mod_sees_them_all():
    """Gameplay keeps the engine's answer: only the ON.LEVEL pass is shielded."""
    rt, _ = floor_2_1(water_surfaces=4)
    seen = rt.eval("#env.get_entities_by(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT)")
    assert int(seen) == 4


def test_alone_the_lily_pads_grow_as_they_always_did():
    grew = 0
    for seed in range(1, 41):
        rt, control = floor_2_1(water_surfaces=4, level_seed=seed, active=False)
        assert int(rt.eval("candidatesSeen")) == 4
        assert int(control["stats"]()["waterFxSeen"]) == 0, "watched in solo play"
        grew += int(rt.eval("lilyPads"))
    assert grew > 0


# three surface effects (FX), one water drop (FX), one leaf (ITEM): what each way of
# asking returns inside the mod's ON.LEVEL is what it returns outside it
@pytest.mark.parametrize("call, count", [
    ("env.get_entities_by(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT)", 3),
    ("env.get_entities_by({ ENT_TYPE.FX_WATER_SURFACE, ENT_TYPE.ITEM_LEAF }, MASK.ANY, LAYER.BOTH)", 4),
    ("env.get_entities_by(0, MASK.FX, LAYER.FRONT)", 4),
    ("env.get_entities_by(0, MASK.ANY, LAYER.BOTH)", 5),
    ("env.get_entities_by({}, 0, LAYER.BOTH)", 5),
    ("env.get_entities_by_type(ENT_TYPE.FX_WATER_SURFACE)", 3),
    ("env.get_entities_by_type(ENT_TYPE.ITEM_LEAF, ENT_TYPE.FX_WATER_SURFACE)", 4),
    ("env.get_entities_by_type({ ENT_TYPE.FX_WATER_SURFACE, ENT_TYPE.FX_WATER_DROP })", 4),
    ("env.get_entities_at(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, 2, 5, LAYER.FRONT, 10)", 3),
    ("env.get_entities_overlapping_hitbox(ENT_TYPE.FX_WATER_SURFACE, MASK.FX,"
     " { left = 0, right = 9, top = 9, bottom = 0 }, LAYER.FRONT)", 3),
])
def test_every_way_of_asking_gets_the_engines_whole_answer_and_is_watched(call, count):
    rt, control = install()
    rt.execute("""
        for i = 1, 3 do spawnEntity(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT, i, 5) end
        spawnEntity(ENT_TYPE.FX_WATER_DROP, MASK.FX, LAYER.FRONT, 2, 5)
        spawnEntity(ENT_TYPE.ITEM_LEAF, MASK.ITEM, LAYER.FRONT, 2, 5)
    """)
    rt.execute("found = nil; env.set_callback(function() found = " + call + " end, ON.LEVEL)")
    rt.execute("fire(ON.POST_LEVEL_GENERATION); fire(ON.LEVEL)")
    assert len(list(rt.eval("found").values())) == count
    assert int(rt.eval("#(" + call + ")")) == count  # the same call outside ON.LEVEL
    assert int(control["stats"]()["waterFxSeen"]) == 3, "the probe did not see the surfaces"


def test_a_query_that_cannot_hold_them_is_not_touched():
    """Only queries that could return them pay for the watching: an ITEM sweep or
    another type entirely is answered straight from the engine."""
    rt, _ = install()
    rt.execute("fire(ON.POST_LEVEL_GENERATION)")  # a floor, so the probe is watching
    rt.execute("""
        for i = 1, 3 do spawnEntity(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT, i, 5) end
        for i = 1, 5 do spawnEntity(ENT_TYPE.ITEM_LEAF, MASK.ITEM, LAYER.FRONT, i, 5) end
        for i = 1, 2 do spawnEntity(ENT_TYPE.ITEM_DIE, MASK.ITEM, LAYER.FRONT, i, 6) end
        for i = 1, 2 do spawnEntity(ENT_TYPE.FX_WATER_DROP, MASK.FX, LAYER.FRONT, i, 7) end
        env.set_callback(function()
            items = #env.get_entities_by(0, MASK.ITEM, LAYER.BOTH)
            dice = #env.get_entities_by(ENT_TYPE.ITEM_DIE, MASK.ANY, LAYER.BOTH)
            drops = #env.get_entities_by_type(ENT_TYPE.FX_WATER_DROP)
            dropsToo = #env.get_entities_by({ ENT_TYPE.FX_WATER_DROP }, MASK.FX, LAYER.FRONT)
        end, ON.LEVEL)
        fire(ON.LEVEL)
    """)
    assert int(rt.eval("items")) == 7
    assert int(rt.eval("dice")) == 2
    assert int(rt.eval("drops")) == int(rt.eval("dropsToo")) == 2
    assert int(rt.eval("typeLookups")) == 0, "filtered a query that could never hold them"


def test_an_answer_that_is_a_container_not_a_table_is_still_watched_and_untouched():
    """These come back as plain tables (2.5 table.sort()s one). A binding that
    returned a sol2-style container -- userdata with a length and an index -- must
    still be read for the probe, and handed to the mod exactly as it came."""
    rt, _ = install()
    rt.execute("""
        for i = 1, 3 do spawnEntity(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT, i, 5) end
        spawnEntity(ENT_TYPE.FX_WATER_DROP, MASK.FX, LAYER.FRONT, 2, 5)
        -- a genuine userdata, made to index like a container
        function container(items)
            local ud = io.tmpfile()
            debug.setmetatable(ud, {
                __len = function() return #items end,
                __index = function(_, i) return items[i] end,
            })
            return ud
        end
        local tableAnswer = get_entities_by
        get_entities_by = function(...) return container(tableAnswer(...)) end
    """)
    # install again, now that the engine's query hands back containers
    rt.execute("env = setmetatable({}, {__index = _G})")
    control = rt.eval("Determinism.install")(
        rt.eval("env"), rt.eval("{ active = function() return true end }"))
    rt.execute("""
        found = nil
        env.set_callback(function() found = env.get_entities_by(0, MASK.FX, LAYER.FRONT) end, ON.LEVEL)
        fire(ON.POST_LEVEL_GENERATION); fire(ON.LEVEL)
    """)
    assert rt.eval("type(found)") == "userdata", "the mod was not given the engine's own answer"
    assert int(rt.eval("#found")) == 4
    assert int(control["stats"]()["waterFxSeen"]) == 3


def test_an_answer_that_cannot_be_read_is_returned_as_given():
    rt, _ = install()
    rt.execute("""
        weird = setmetatable({}, { __len = function() error('no length here') end })
        get_entities_by = function() return weird end
        env = setmetatable({}, {__index = _G})
    """)
    rt.eval("Determinism.install")(rt.eval("env"), rt.eval("{ active = function() return true end }"))
    rt.execute("""
        same = nil
        env.set_callback(function() same = env.get_entities_by(0, MASK.FX, LAYER.FRONT) == weird end, ON.LEVEL)
        fire(ON.POST_LEVEL_GENERATION); fire(ON.LEVEL)
    """)
    assert rt.eval("same") is True


def test_probing_for_the_queries_is_not_the_mod_asking_for_them():
    """The sandbox counts every name its read-through cannot find as an unknown
    global the mod asked for (modHost's newSandbox). A query this build lacks --
    get_entities_overlapping is gone from current Overlunky -- is ours to probe
    for, and must not show up in the mod's report."""
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute("function is_liquid_at() return false end")  # the engine has it; ENGINE does not
    rt.execute(DETERMINISM)
    rt.execute("""
        misses = {}
        env = setmetatable({}, { __index = function(_, key)
            local v = rawget(_G, key)
            if v == nil then misses[#misses + 1] = tostring(key) end
            return v
        end })
        Determinism.install(env, { active = function() return true end })
    """)
    assert list(rt.eval("misses").values()) == []
    assert rt.eval("rawget(env, 'get_entities_overlapping')") is None, "wrapped a function that is not there"
    assert rt.eval("type(rawget(env, 'get_entities_by'))") == "function"


def test_nothing_is_hidden_and_nothing_says_it_was():
    """dev75's once-a-floor `hid N water-surface effect(s)` line is gone with the
    hiding: a capture that still prints it is running an old build."""
    rt, _ = floor_2_1(water_surfaces=4)
    lines = [str(v) for v in rt.eval("events").values() if "water-surface" in str(v)]
    assert lines == [], lines


def test_a_throwing_on_level_callback_closes_the_window_and_restores_the_streams():
    rt, _ = install()
    rt.execute("""
        for i = 1, 3 do spawnEntity(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT, i, 5) end
        seed_prng(77)
        before = stream(0)
        env.set_callback(function()
            prng:random_int(0, 9, PRNG_CLASS.PROCEDURAL_SPAWNS)
            error('boom')
        end, ON.LEVEL)
    """)
    with pytest.raises(lupa.LuaError, match="boom"):
        rt.execute("fire(ON.LEVEL)")
    assert rt.eval("stream(0)") == rt.eval("before"), "the anchor's seed leaked out of a throw"
    seen = rt.eval("#env.get_entities_by(ENT_TYPE.FX_WATER_SURFACE, MASK.FX, LAYER.FRONT)")
    assert int(seen) == 3, "the window stayed open after the throw"


# --------------------------------------------------------------- the ON.LEVEL anchor

def test_on_level_is_anchored_only_in_a_room():
    rt, control = install(active=True)
    rt.execute("env.set_callback(function() end, ON.LEVEL); seeded = {}; fire(ON.LEVEL)")
    assert len(list(rt.eval("seeded").values())) == 1
    assert int(control["stats"]()["levelAnchored"]) == 1
    solo, control = install(active=False)
    solo.execute("env.set_callback(function() end, ON.LEVEL); seeded = {}; fire(ON.LEVEL)")
    assert list(solo.eval("seeded").values()) == [], "solo play must keep the engine's streams"
    assert int(control["stats"]()["levelAnchored"]) == 0


def test_every_on_level_callback_starts_from_the_floor_not_from_its_place_in_line():
    """The POST_LEVEL_GENERATION rule, for the same reason: a mid-run joiner can
    register a different set, so a callback's rolls must not depend on how many ran
    before it."""
    rt, _ = install()
    rt.execute("""
        firsts = {}
        for i = 1, 3 do
            env.set_callback(function()
                firsts[#firsts + 1] = prng:random_int(0, 1000000, PRNG_CLASS.PROCEDURAL_SPAWNS)
                for _ = 1, i * 7 do prng:random_int(0, 9, PRNG_CLASS.PROCEDURAL_SPAWNS) end
            end, ON.LEVEL)
        end
        fire(ON.LEVEL)
    """)
    firsts = list(rt.eval("firsts").values())
    assert len(firsts) == 3 and len(set(firsts)) == 1, firsts


def test_post_generation_anchor_restores_even_when_the_hook_throws():
    rt, _ = install()
    rt.execute("""
        seed_prng(5)
        before = stream(0)
        env.set_callback(function()
            prng:random_int(0, 9, PRNG_CLASS.PROCEDURAL_SPAWNS)
            error('kaput')
        end, ON.POST_LEVEL_GENERATION)
    """)
    with pytest.raises(lupa.LuaError, match="kaput"):
        rt.execute("fire(ON.POST_LEVEL_GENERATION)")
    assert rt.eval("stream(0)") == rt.eval("before")


def test_the_mods_on_level_return_value_still_reaches_the_engine():
    rt, _ = install()
    rt.execute("env.set_callback(function() return 'kept' end, ON.LEVEL)")
    assert rt.eval("fire(ON.LEVEL)") == "kept"
