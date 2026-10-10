"""A hosted mod's ON.LEVEL callbacks run in the order it registered them, on every machine.

Overlunky keeps a script's callbacks in a std::unordered_map keyed by callback id and
fires them in the order that map iterates. The ids come from one counter per script --
hosted, the mod's and ours -- and two machines never reach a floor having registered
exactly the same things, so the same mod's callbacks ran in a different order on each.
Room FVJF's 2-1 showed it: 2.5 asked twice for water surfaces at ON.LEVEL, and the two
machines' answers came the other way round.

The engine here does what Overlunky's does where it matters: it reaches callbacks in
an order of its own (a hash of the id, salted per machine), tracks which callback it is
running for a bare clear_callback(), skips one cleared during the pass, and reaches
one registered mid-pass if the hash puts it ahead.

Run:  python -m pytest tests/test_level_order.py -q
"""

from __future__ import annotations

import pathlib
import textwrap

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")
CALLBACKS = (PACK / "src" / "callbacks.lua").read_text(encoding="utf-8")
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")

ENGINE = """
ON = {
    FRAME = 1, GAMEFRAME = 2, LOADING = 3, LEVEL = 4,
    PRE_LEVEL_GENERATION = 5, POST_LEVEL_GENERATION = 6,
    PRE_LOAD_LEVEL_FILES = 7, PRE_LOAD_SCREEN = 8,
    PRE_UPDATE = 9, POST_UPDATE = 10, GUIFRAME = 11,
}
frameNo = 100
function get_frame() return frameNo end
function get_adventure_seed() return 0x5EEDF00D, 0xD125E0C4 end
function get_local_state() return { world = 2, level = 1, theme = 2, time_total = 900 } end
function seed_prng() end
prng = { get_pair = function(_, c) return c, c end, set_pair = function() end }

-- the engine's callback map: id -> { fn, kind }
callbacks, nextId, cleared, current = {}, 0, {}, nil
engineErrors, reached = {}, {}
salt = 0
function set_callback(fn, kind)
    nextId = nextId + 1
    callbacks[nextId] = { fn = fn, kind = kind }
    return nextId
end
function clear_callback(id)
    if id == nil then id = current end
    if id ~= nil then cleared[id] = true end
end
local function rank(id) return ((id * 2654435761) ~ (salt * 2246822519)) % 1000003 end
--- One event: callbacks of `kind` in this machine's hash order, each once, including
--- any registered mid-pass that hash ahead of the ones still to come. The engine
--- catches each callback's error, as Overlunky's handle_function does.
function fire(kind, ...)
    reached[kind] = {}
    local visited = {}
    while true do
        local pick = nil
        for id, cb in pairs(callbacks) do
            if cb.kind == kind and not visited[id] and not cleared[id]
                and (pick == nil or rank(id) < rank(pick)) then
                pick = id
            end
        end
        if pick == nil then break end
        visited[pick] = true
        reached[kind][#reached[kind] + 1] = pick
        local outer = current
        current = pick
        local ok, err = pcall(callbacks[pick].fn, ...)
        current = outer
        if not ok then engineErrors[#engineErrors + 1] = tostring(err) end
    end
end
--- The engine calling back into Lua from inside an API call (a spawn setting off an
--- entity hook): a C function on the stack, and its own current callback.
function engineCallsHook(hook)
    local outer = current
    current = "hook"
    string.gsub("x", "x", function() hook() end)
    current = outer
end
--- A floor: generation, then its one ON.LEVEL pass.
function floor()
    frameNo = frameNo + 50
    fire(ON.POST_LEVEL_GENERATION)
    fire(ON.LEVEL)
end
"""


def machine(salt=0, active=True):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(f"salt = {salt}")
    rt.execute(DETERMINISM)
    rt.execute("""
        env = setmetatable({}, {__index = _G})
        -- the host's two wrappers, as modHost puts them in the sandbox: straight through
        env.set_callback = function(fn, kind) return set_callback(fn, kind) end
        env.clear_callback = function(id)
            if id == nil then return clear_callback() end
            return clear_callback(id)
        end
    """)
    rt.execute(f"activeFlag = {str(active).lower()}")
    rt.eval("Determinism.install")(rt.eval("env"), rt.eval("{ active = function() return activeFlag end }"))
    return rt


def register(rt, n, body=""):
    """`n` ON.LEVEL callbacks, each in a file of its own and running in the sandbox, as
    a mod's are. Each notes its number; `{n}` in `body` stands for that number."""
    rt.execute("ran = ran or {}; ids = ids or {}")
    for i in range(1, n + 1):
        src = f"return function() ran[#ran + 1] = {i}; {body.replace('{n}', str(i))} end"
        rt.execute(f'ids[{i}] = env.set_callback(load({src!r}, "@hooks/h{i}.lua", "t", env)(),'
                   ' ON.LEVEL)')


def ran(rt):
    return [int(v) for v in rt.eval("ran").values()]


def engine_order(rt):
    """The mod's callbacks in the order the engine reached them on the last pass."""
    by_id = {int(v): k for k, v in rt.eval("ids").items()}
    return [by_id[int(i)] for i in rt.eval("reached[ON.LEVEL]").values() if int(i) in by_id]


# --------------------------------------------------------------------- the order

def test_two_machines_whose_engines_disagree_run_them_in_one_order():
    host, peer = machine(salt=0), machine(salt=7919)
    register(host, 6)
    register(peer, 6)
    host.execute("floor()")
    peer.execute("floor()")
    assert engine_order(host) != engine_order(peer), "the model's two engines agree; no test"
    assert ran(host) == ran(peer) == [1, 2, 3, 4, 5, 6]


def test_each_runs_once_a_floor_however_many_times_the_engine_calls():
    rt = machine(salt=31)
    register(rt, 5)
    rt.execute("floor(); floor(); floor()")
    assert ran(rt) == [1, 2, 3, 4, 5] * 3


def test_alone_each_runs_at_the_engines_own_turn():
    """Solo play is not lockstep: the engine's order, untouched."""
    rt = machine(salt=7919, active=False)
    register(rt, 6)
    rt.execute("floor()")
    assert ran(rt) == engine_order(rt)
    assert sorted(ran(rt)) == [1, 2, 3, 4, 5, 6]


def test_the_probe_looks_before_any_of_them_wherever_the_engine_puts_its_own():
    """The probe's ON.LEVEL look is ours, registered first -- which says nothing about
    when the engine reaches it. The batch takes the look before the first mod callback."""
    rt = machine(salt=7919)
    rt.execute("""
        world = { surfaces = 0 }
        ENT_TYPE = { FX_WATER_SURFACE = 680 }
        MASK = { FX = 64, LIQUID = 24576 }
        LAYER = { BOTH = -128 }
        function get_entities_by(types)
            local out = {}
            if types == ENT_TYPE.FX_WATER_SURFACE then
                for i = 1, world.surfaces do out[i] = 1000 + i end
            end
            return out
        end
        function get_position(uid) return uid, 5, 0 end
    """)
    register(rt, 4, body="world.surfaces = world.surfaces + 1")
    rt.execute("floor()")
    mods = {int(v) for v in rt.eval("ids").values()}
    order = [int(i) for i in rt.eval("reached[ON.LEVEL]").values()]
    probe_at = next(n for n, cb in enumerate(order) if cb not in mods)
    assert probe_at > 0, "pick a salt where the engine reaches a mod callback before the probe"
    assert int(rt.eval("world.surfaces")) == 4
    assert int(rt.eval("Determinism.waterReport().wire.fn")) == 0, \
        "the probe looked after a mod callback had already changed the floor"


# ------------------------------------------------------------------- the clears

def test_a_bare_clear_clears_the_callback_that_made_it():
    """In a batch the engine is running the pass from whichever callback it reached
    first. A callback's own clear_callback() must still clear that callback."""
    rt = machine(salt=7919)
    register(rt, 5, body="if {n} == 3 then clear_callback() end")
    rt.execute("floor()")
    first = engine_order(rt)[0]
    assert first != 3, "pick a salt where the engine does not start the pass on #3"
    rt.execute("floor()")
    assert ran(rt) == [1, 2, 3, 4, 5, 1, 2, 4, 5]
    assert [int(k) for k in rt.eval("cleared").keys()] == [int(rt.eval("ids[3]"))]


def test_a_bare_clear_inside_an_engine_callback_nested_in_one_is_the_engines():
    """A spawn inside an ON.LEVEL callback can set off an entity hook, and a bare clear
    in THAT hook clears the hook, not the ON.LEVEL callback around it."""
    rt = machine(salt=7919)
    register(rt, 4, body="if {n} == 2 then engineCallsHook(function() clear_callback() end) end")
    rt.execute("floor(); floor()")
    assert ran(rt) == [1, 2, 3, 4, 1, 2, 3, 4], "the ON.LEVEL callback was cleared instead"
    assert [k for k in rt.eval("cleared").keys()] == ["hook"]


def test_a_bare_clear_through_the_mods_own_pcall_still_counts_as_its_own():
    rt = machine(salt=7919)
    register(rt, 3, body="if {n} == 1 then pcall(clear_callback) end")
    rt.execute("floor(); floor()")
    assert ran(rt) == [1, 2, 3, 2, 3]


def test_a_callback_cleared_by_an_earlier_one_does_not_run():
    rt = machine(salt=7919)
    register(rt, 5, body="if {n} == 1 then clear_callback(ids[4]) end")
    rt.execute("floor()")
    assert ran(rt) == [1, 2, 3, 5]


def test_clearing_by_id_still_works_between_floors():
    rt = machine(salt=31)
    register(rt, 3)
    rt.execute("floor(); env.clear_callback(ids[2]); floor()")
    assert ran(rt) == [1, 2, 3, 1, 3]


# --------------------------------------------------------------- the other edges

def test_one_registered_during_the_pass_first_runs_on_the_next_floor():
    """The engine may or may not reach a callback inserted mid-iteration, by where its
    id hashes. Every machine gives the same answer instead: next floor."""
    for salt in (0, 31, 7919, 104729):
        rt = machine(salt=salt)
        register(rt, 3, body=(
            "if {n} == 2 and not grew then grew = true;"
            " env.set_callback(function() ran[#ran + 1] = 9 end, ON.LEVEL) end"))
        rt.execute("floor()")
        assert ran(rt) == [1, 2, 3], f"salt {salt}"
        rt.execute("floor()")
        assert ran(rt) == [1, 2, 3, 1, 2, 3, 9], f"salt {salt}"


def test_an_error_stops_nothing_else_and_is_raised_at_its_own_turn():
    rt = machine(salt=7919)
    register(rt, 5, body="if {n} == 3 then error('boom') end")
    rt.execute("floor()")
    assert ran(rt) == [1, 2, 3, 4, 5]
    errors = list(rt.eval("engineErrors").values())
    assert len(errors) == 1 and "boom" in errors[0], errors


def test_the_engine_still_gets_each_callbacks_return_value():
    rt = machine(salt=7919)
    rt.execute("""
        returned = {}
        local realFire = fire
        for i = 1, 3 do
            ids = ids or {}
            ids[i] = env.set_callback(function() return 'r' .. i end, ON.LEVEL)
        end
        -- the engine, noting what each of the three hands back at its own turn
        for i = 1, 3 do
            local entry = callbacks[ids[i]]
            local fn = entry.fn
            entry.fn = function(...) returned[i] = fn(...) end
        end
        floor()
    """)
    assert [str(v) for v in rt.eval("returned").values()] == ["r1", "r2", "r3"]


def test_something_that_cannot_be_called_goes_to_the_engine_as_it_came():
    """Wrapping a number in a function hid it until the event fired, then raised the
    error from inside our wrapper. Unhosted, the engine is handed the number itself."""
    rt = machine()
    rt.execute("""
        env.set_callback(5, ON.LEVEL); env.set_callback(7, ON.POST_UPDATE)
        raw = {}
        for _, cb in pairs(callbacks) do
            if type(cb.fn) ~= 'function' then raw[#raw + 1] = cb.fn end
        end
        table.sort(raw)
    """)
    assert [int(v) for v in rt.eval("raw").values()] == [5, 7]


def test_each_one_is_named_in_the_crash_trace_while_it_runs():
    rt = machine(salt=7919)
    rt.execute("""
        marks = {}
        DesyncLog = {
            tracing = function() return true end,
            frameMark = function(name) marks[#marks + 1] = 'IN ' .. name end,
            frameDone = function(name) marks[#marks + 1] = 'OUT ' .. name end,
        }
    """)
    register(rt, 2)
    rt.execute("floor()")
    assert list(rt.eval("marks").values()) == [
        "IN mod h1.lua:1", "OUT mod h1.lua:1", "IN mod h2.lua:1", "OUT mod h2.lua:1"]


def test_the_floors_order_is_reported_for_the_probe():
    host, peer = machine(salt=0), machine(salt=7919)
    register(host, 3)
    register(peer, 3)
    host.execute("floor()")
    peer.execute("floor()")
    a = host.eval("Determinism.waterReport()")
    b = peer.eval("Determinism.waterReport()")
    assert int(a["wire"]["oc"]) == int(b["wire"]["oc"]) == 3
    assert int(a["wire"]["oh"]) == int(b["wire"]["oh"])
    line = list(a["lines"].values())[-1]
    assert line.startswith("level order: 3 hosted ON.LEVEL callback(s) #")
    assert line.endswith(": h1.lua:1 h2.lua:1 h3.lua:1"), line


# ------------------------------------------------- through the real host and registry

@pytest.fixture
def hosted(tmp_path, monkeypatch):
    """callbacks.lua, modHost.lua and determinism.lua together, as main.lua loads
    them, over the engine above: a bare clear goes through the ownership guard."""
    (tmp_path / "Mods" / "Packs" / "fake.mod").mkdir(parents=True)
    monkeypatch.chdir(tmp_path)
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute("salt = 7919")
    rt.execute(textwrap.dedent("""
        printed = {}
        function errorf(fmt, ...) printed[#printed + 1] = tostring(fmt) end
        function dbg() end
        function get_ms() return 0 end
        packRoot = "."
        function PackPath(n) return packRoot .. "/" .. n end
        Network = { isInRun = function() return true end }
    """))
    rt.execute(CALLBACKS)
    rt.execute(DETERMINISM)
    rt.execute(MOD_HOST)
    rt.execute("""report = { ok = false, modules = {}, callbacks = {}, missing = {}, files = 0,
        refused = 0, missingModules = {}, missingTextures = {}, skippedTextures = {} }""")
    rt.execute("env = ModHost.newSandbox(report, {inert = false})")
    return rt


def test_through_the_host_a_bare_clear_still_lands_on_the_right_callback(hosted):
    rt = hosted
    rt.execute("""
        ran, ids = {}, {}
        for i = 1, 4 do
            ids[i] = env.set_callback(load("return function() ran[#ran + 1] = " .. i
                .. "; if " .. i .. " == 3 then clear_callback() end end",
                "@hooks/h" .. i .. ".lua", "t", env)(), ON.LEVEL)
        end
        floor(); floor()
    """)
    assert ran(rt) == [1, 2, 3, 4, 1, 2, 4]
    assert [int(k) for k in rt.eval("cleared").keys()] == [int(rt.eval("ids[3]"))]
    assert int(rt.eval("report.refused")) == 0
    assert rt.eval("report.refusedBare") is None
