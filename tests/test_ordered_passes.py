"""In a room, a hosted mod's callbacks run in the order it registered them, for every
event they can interact in -- on every machine, whatever order the engine keeps.

Overlunky keeps a script's callbacks in a std::unordered_map, which on Microsoft's
library is a list in registration order but for the callbacks whose ids happened to
share a bucket: those sit next to each other, out of turn. Which ids share one depends
on the ids, and the ids on everything the script ever registered, so two machines keep
the same mod's callbacks in slightly different orders -- and a player who comes back
into a run under way, whose whole history is shorter, in a different order on every
floor. dev77 ran the mod's ON.LEVEL callbacks in registration order (test_level_order).
dev86 does the same for every event a floor is built in and every per-frame event, and
runs ours that must come first (heads) before them and ours that must come last
(tails) after, and keeps what each event does with an answer: PRE_LOAD_SCREEN stops at
the first true, PRE_UPDATE and PRE_LEVEL_GENERATION block on any, the rest ignore it.
dev88 adds the events fired once a room or a layer, a pass for each firing, and no
longer takes a callback the engine reaches twice in one walk -- its map rehashing under
the walk -- for the event firing again.

The engine here reaches an event's callbacks in an order of its own: a salted hash of
the id (two "machines" that disagree), registration order with new ones last (what
Microsoft's map mostly does), or a list a test spells out.

Run:  python -m pytest tests/test_ordered_passes.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")
CALLBACKS = (PACK / "src" / "callbacks.lua").read_text(encoding="utf-8")

ENGINE = """
ON = {
    FRAME = 1, GAMEFRAME = 2, LOADING = 3, LEVEL = 4,
    PRE_LEVEL_GENERATION = 5, POST_LEVEL_GENERATION = 6,
    PRE_LOAD_LEVEL_FILES = 7, PRE_LOAD_SCREEN = 8,
    PRE_UPDATE = 9, POST_UPDATE = 10, GUIFRAME = 11, BLOCKED_UPDATE = 12,
    POST_LOAD_SCREEN = 13, TRANSITION = 14, RESET = 15,
    PRE_GET_RANDOM_ROOM = 16, PRE_HANDLE_ROOM_TILES = 17,
    PRE_LAYER_CREATION = 18, POST_LAYER_CREATION = 19,
}
STOPS = { [ON.PRE_LOAD_SCREEN] = true, [ON.PRE_HANDLE_ROOM_TILES] = true,
    [ON.PRE_LAYER_CREATION] = true }
FIRSTS = { [ON.PRE_GET_RANDOM_ROOM] = true } -- the first room, a string not empty, wins
frameNo = 100
function get_frame() return frameNo end
function get_adventure_seed() return 0x5EEDF00D, 0xD125E0C4 end
st = { world = 2, level = 1, theme = 2, time_total = 900 }
function get_local_state() return st end
function seed_prng() end
prng = { get_pair = function(_, c) return c, c end, set_pair = function() end }

callbacks, nextId, cleared, current = {}, 0, {}, nil
engineErrors, reached, answers = {}, {}, {}
salt = 0
mode = "hash"     -- "hash": a salted order; "append": registration order, new ones last
script = nil      -- a list of ids: the order the engine reaches them in, once
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
local function nextPick(kind, visited)
    if script ~= nil then
        while #script > 0 do
            local id = table.remove(script, 1)
            if callbacks[id] ~= nil and callbacks[id].kind == kind and not cleared[id] then
                return id
            end
        end
        return nil
    end
    local pick = nil
    if mode == "append" then
        for id = 1, nextId do
            local cb = callbacks[id]
            if cb ~= nil and cb.kind == kind and not visited[id] and not cleared[id] then
                return id
            end
        end
        return nil
    end
    for id, cb in pairs(callbacks) do
        if cb.kind == kind and not visited[id] and not cleared[id]
            and (pick == nil or rank(id) < rank(pick)) then
            pick = id
        end
    end
    return pick
end
--- One firing of `kind`: the engine reaches its callbacks in this machine's order,
--- converts each answer strictly, as handle_function does, and stops at the first
--- true where the event does. Returns what the engine decided.
function fire(kind, ...)
    reached[kind] = {}
    answers[kind] = {}
    local visited, blocked = {}, false
    while true do
        local pick = nextPick(kind, visited)
        if pick == nil then break end
        visited[pick] = true
        reached[kind][#reached[kind] + 1] = pick
        local outer = current
        current = pick
        local ok, ret = pcall(callbacks[pick].fn, ...)
        current = outer
        answers[kind][pick] = ret
        if not ok then
            engineErrors[#engineErrors + 1] = tostring(ret)
        elseif FIRSTS[kind] then
            if ret ~= nil and type(ret) ~= "string" then
                engineErrors[#engineErrors + 1] = "Unexpected return type from function..."
            elseif ret ~= nil and ret ~= "" then
                script = nil
                return ret
            end
        elseif ret ~= nil and type(ret) ~= "boolean" then
            engineErrors[#engineErrors + 1] = "Unexpected return type from function..."
        elseif ret == true then
            blocked = true
            if STOPS[kind] then
                return true
            end
        end
    end
    script = nil
    return blocked
end
--- One update, as StateUpdate runs it: PRE_UPDATE, the update, POST_UPDATE (or
--- BLOCKED_UPDATE when PRE_UPDATE blocked it), then the scripts' own update.
function frame()
    frameNo = frameNo + 1
    if fire(ON.PRE_UPDATE) then
        fire(ON.BLOCKED_UPDATE)
    else
        st.time_total = st.time_total + 1
        fire(ON.POST_UPDATE)
    end
    fire(ON.GAMEFRAME)
end
--- One level load, inside one update.
function levelLoad()
    frameNo = frameNo + 1
    if fire(ON.PRE_LOAD_SCREEN) then return "blocked" end
    fire(ON.PRE_LOAD_LEVEL_FILES)
    fire(ON.PRE_LEVEL_GENERATION)
    fire(ON.POST_LEVEL_GENERATION)
    fire(ON.POST_LOAD_SCREEN)
    return "loaded"
end
"""


def machine(salt=0, active=True, mode="hash", callbacks_module=False, now="nil"):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(f'salt = {salt}; mode = "{mode}"')
    if callbacks_module:
        rt.execute(f"nowValue = 0; get_ms = function() return nowValue end")
        rt.execute(CALLBACKS)
    rt.execute(DETERMINISM)
    rt.execute("""
        env = setmetatable({}, {__index = _G})
        -- the host's two wrappers, as modHost puts them in the sandbox: straight through
        env.set_callback = function(fn, kind) return set_callback(fn, kind) end
        env.clear_callback = function(id)
            if id == nil then return clear_callback() end
            return clear_callback(id)
        end
        if Callbacks ~= nil then
            -- ...and as modHost does it with the registry loaded: the engine's own
            -- set_callback, the callback wrapped as a hosted one
            env.set_callback = function(fn, kind)
                return Callbacks.rawSetCallback(Callbacks.hosted(fn, "ON " .. kind), kind)
            end
            env.clear_callback = function(id)
                if id == nil then return Callbacks.rawClearCallback() end
                return Callbacks.rawClearCallback(id)
            end
        end
    """)
    rt.execute(f"activeFlag = {str(active).lower()}; held = false")
    rt.eval("Determinism.install")(rt.eval("env"), rt.eval(
        "{ active = function() return activeFlag end, heldFrame = function() return held end }"))
    rt.execute("ran = {}; ids = {}")
    return rt


def register(rt, n, kind, body="", tag=None):
    """`n` callbacks of the mod for `kind`, each in a file of its own and run in the
    sandbox, as a mod's are. Each notes its tag; `{n}` in `body` is its number."""
    for i in range(1, n + 1):
        label = f"{tag or ''}{i}"
        src = (f"return function(...) ran[#ran + 1] = {label!r}; "
               f"{body.replace('{n}', str(i))} end")
        rt.execute(f'ids[{label!r}] = env.set_callback(load({src!r}, "@hooks/{kind}{i}.lua",'
                   f' "t", env)(), ON.{kind})')


def ran(rt):
    return [str(v) for v in rt.eval("ran").values()]


def clear_ran(rt):
    rt.execute("ran = {}")


def mod_ids(rt):
    return {int(v) for v in rt.eval("ids").values()}


def engine_order(rt, kind):
    ids = {int(v): str(k) for k, v in rt.eval("ids").items()}
    return [ids[int(i)] for i in rt.eval(f"reached[ON.{kind}]").values() if int(i) in ids]


# ----------------------------------------------------------------------- the order

@pytest.mark.parametrize("kind", ["POST_UPDATE", "PRE_UPDATE", "GAMEFRAME"])
def test_two_machines_whose_engines_disagree_run_a_frame_in_one_order(kind):
    host, peer = machine(salt=0), machine(salt=7919)
    for rt in (host, peer):
        register(rt, 6, kind)
        rt.execute("frame(); frame()")
    assert engine_order(host, kind) != engine_order(peer, kind), "the two engines agree; no test"
    assert ran(host) == ran(peer) == ["1", "2", "3", "4", "5", "6"] * 2


@pytest.mark.parametrize("kind", ["PRE_LOAD_SCREEN", "PRE_LOAD_LEVEL_FILES",
                                  "PRE_LEVEL_GENERATION", "POST_LEVEL_GENERATION",
                                  "POST_LOAD_SCREEN"])
def test_two_machines_build_a_floor_in_one_order(kind):
    host, peer = machine(salt=0), machine(salt=104729)
    for rt in (host, peer):
        register(rt, 5, kind)
        rt.execute("levelLoad(); levelLoad()")
    assert ran(host) == ran(peer) == ["1", "2", "3", "4", "5"] * 2


def test_alone_each_runs_at_the_engines_own_turn():
    """Solo play is not lockstep: the engine's order, untouched."""
    rt = machine(salt=7919, active=False)
    register(rt, 6, "POST_UPDATE")
    rt.execute("frame()")
    assert ran(rt) == engine_order(rt, "POST_UPDATE")


def test_each_runs_once_a_frame_however_the_engine_calls():
    rt = machine(salt=31)
    register(rt, 4, "POST_UPDATE")
    rt.execute("for _ = 1, 5 do frame() end")
    assert ran(rt) == ["1", "2", "3", "4"] * 5


def test_two_updates_in_one_engine_frame_are_two_passes():
    """The update's own end, POST_UPDATE, closes a PRE_UPDATE pass: a second update
    on the same frame counter is a second pass, not a repeat of the first."""
    rt = machine(salt=31)
    register(rt, 3, "PRE_UPDATE")
    rt.execute("fire(ON.PRE_UPDATE); fire(ON.POST_UPDATE); fire(ON.PRE_UPDATE)")
    assert ran(rt) == ["1", "2", "3"] * 2


@pytest.mark.parametrize("registry", [False, True])
def test_the_engine_walking_its_callbacks_again_in_one_frame_runs_them_once(registry):
    """Overlunky walks its callback map with a range-for while set_callback inserts
    into it; a rehash under the walk carries it on through the new order, and it
    reaches callbacks it already ran. dev86 took that for the event firing again and
    could run every callback a second time, on one machine only (rooms HVRT and EIAS
    ran different numbers of 2.5's ON.LEVEL callbacks on 1-1). Reached again in the
    same frame with nothing between, it is the same pass -- whatever counts the
    registrations: a load event never fires twice without its closer between."""
    rt = machine(mode="append", callbacks_module=registry)
    register(rt, 3, "PRE_LOAD_LEVEL_FILES")
    a, b, c = (int(rt.eval(f"ids['{i}']")) for i in "123")
    rt.execute(f"frameNo = frameNo + 1; script = {{ {a}, {b}, {c}, {a}, {b}, {c} }};"
               " fire(ON.PRE_LOAD_LEVEL_FILES)")
    assert ran(rt) == ["1", "2", "3"]
    rt.execute("fire(ON.PRE_LOAD_LEVEL_FILES)")
    assert ran(rt) == ["1", "2", "3"], "and again, still in that frame: still that pass"


def test_the_same_event_with_its_closer_between_is_two_passes():
    """Within one frame a load event fires again only after an event that always
    comes between two of its firings -- the load's end, or the next update."""
    rt = machine(salt=31)
    register(rt, 3, "PRE_LOAD_LEVEL_FILES")
    rt.execute("fire(ON.PRE_LOAD_LEVEL_FILES); fire(ON.POST_LOAD_SCREEN);"
               " fire(ON.PRE_LOAD_LEVEL_FILES)")
    assert ran(rt) == ["1", "2", "3"] * 2


@pytest.mark.parametrize("walk", ["straight", "again", "skipping"])
def test_a_floor_set_up_while_one_engines_map_rehashes_is_set_up_once(walk):
    """2.5's PRE_LEVEL_GENERATION clears its level hooks and registers new ones, about
    four hundred of them. Two machines' maps rehash at different moments, so one
    engine's walk reaches every callback for the event, ours included, and then some
    of them again ("again"), or never reaches some ("skipping"). Both set the floor
    up once, the same way, as the machine whose walk went straight through."""
    rt = machine(mode="append")
    register(rt, 4, "PRE_LEVEL_GENERATION", body=(
        "if {n} == 1 then for _ = 1, 400 do"
        " env.set_callback(function() end, ON.POST_LEVEL_GENERATION) end end"))
    every = sorted(int(i) for i, cb in rt.eval("callbacks").items()
                   if cb["kind"] == rt.eval("ON.PRE_LEVEL_GENERATION"))
    mods = [int(rt.eval(f"ids['{i}']")) for i in "1234"]
    assert len(every) > len(mods), "our own heads are reached too"
    route = {
        "straight": every,
        "again": every + [mods[1], mods[0], every[0]],
        "skipping": [i for i in every if i != mods[3]][:3] + [mods[0]]
        + [i for i in every if i != mods[3]][3:],
    }[walk]
    rt.execute("frameNo = frameNo + 1; script = { " + ", ".join(map(str, route))
               + " }; fire(ON.PRE_LEVEL_GENERATION)")
    assert ran(rt) == ["1", "2", "3", "4"]


def test_one_the_engine_reaches_twice_in_a_pass_runs_once():
    rt = machine(mode="append")
    register(rt, 3, "POST_UPDATE")
    a, b, c = (int(rt.eval(f"ids['{i}']")) for i in "123")
    rt.execute(f"frameNo = frameNo + 1; script = {{ {a}, {b}, {a}, {c} }}; fire(ON.POST_UPDATE)")
    assert ran(rt) == ["1", "2", "3"]


# ---------------------------------------------------- one registered during a pass

@pytest.mark.parametrize("mode", ["append", "hash"])
def test_one_registered_during_the_pass_runs_in_it_after_the_others(mode):
    """The engine nearly always reaches a callback added mid-pass, at the end of its
    list, after every other: it is the pass's, and it runs once, not twice."""
    rt = machine(salt=31, mode=mode)
    register(rt, 3, "POST_UPDATE", body=(
        "if {n} == 2 and not grew then grew = true;"
        " env.set_callback(function() ran[#ran + 1] = 'new' end, ON.POST_UPDATE) end"))
    rt.execute("frame()")
    assert ran(rt) == ["1", "2", "3", "new"]
    clear_ran(rt)
    rt.execute("frame()")
    assert ran(rt) == ["1", "2", "3", "new"]


def test_a_callback_cleared_by_an_earlier_one_does_not_run():
    rt = machine(salt=7919)
    register(rt, 4, "PRE_LEVEL_GENERATION", body="if {n} == 1 then clear_callback(ids['3']) end")
    rt.execute("levelLoad()")
    assert ran(rt) == ["1", "2", "4"]


def test_a_bare_clear_clears_the_callback_that_made_it():
    rt = machine(salt=7919)
    register(rt, 4, "POST_UPDATE", body="if {n} == 3 then clear_callback() end")
    rt.execute("frame(); frame()")
    assert ran(rt) == ["1", "2", "3", "4", "1", "2", "4"]
    assert [int(k) for k in rt.eval("cleared").keys()] == [int(rt.eval("ids['3']"))]


# ------------------------------------------------------------ what an answer does

def test_a_load_screen_stops_at_the_first_true_in_registration_order():
    """PRE_LOAD_SCREEN: the engine stops at the first callback returning true. In the
    batch that is the first in the mod's order, the ones after it do not run, and the
    engine stops when it reaches that one -- the load is blocked, on every machine."""
    for salt in (0, 31, 7919):
        rt = machine(salt=salt)
        register(rt, 4, "PRE_LOAD_SCREEN", body="if {n} == 2 then return true end")
        assert rt.eval("levelLoad()") == "blocked", f"salt {salt}"
        assert ran(rt) == ["1", "2"], f"salt {salt}"


def test_only_a_real_true_stops_it():
    """The engine converts strictly: a 1 is an "Unexpected return type", not a true."""
    rt = machine(salt=31)
    register(rt, 3, "PRE_LOAD_SCREEN", body="if {n} == 1 then return 1 end")
    assert rt.eval("levelLoad()") == "loaded"
    assert ran(rt)[:3] == ["1", "2", "3"]
    assert "Unexpected return type from function..." in list(rt.eval("engineErrors").values())


def test_pre_update_runs_them_all_and_any_true_blocks_the_update():
    for salt in (0, 31, 7919):
        rt = machine(salt=salt)
        register(rt, 4, "PRE_UPDATE", body="if {n} == 1 then return true end")
        rt.execute("blocked = fire(ON.PRE_UPDATE)")
        assert rt.eval("blocked") is True, f"salt {salt}"
        assert ran(rt) == ["1", "2", "3", "4"], f"salt {salt}"


def test_the_engine_gets_each_callbacks_own_answer_at_its_turn():
    rt = machine(salt=7919)
    register(rt, 3, "PRE_LEVEL_GENERATION", body="return {n} == 2")
    rt.execute("levelLoad()")
    by_id = {int(rt.eval(f"ids['{i}']")): i for i in "123"}
    got = {by_id[int(k)]: v for k, v in rt.eval("answers[ON.PRE_LEVEL_GENERATION]").items()
           if int(k) in by_id}
    assert got == {"1": False, "2": True, "3": False}


def test_an_error_stops_nothing_else_and_is_raised_at_its_own_turn():
    rt = machine(salt=7919)
    register(rt, 4, "POST_UPDATE", body="if {n} == 2 then error('boom') end")
    rt.execute("frame()")
    assert ran(rt) == ["1", "2", "3", "4"]
    errors = list(rt.eval("engineErrors").values())
    assert len(errors) == 1 and "boom" in errors[0], errors


# ------------------------------------------------------------ ours, first and last

def own(rt, kind, phase, name):
    rt.execute(f'Determinism.{phase}(ON.{kind}, "{name}", function() ran[#ran + 1] = "{name}" end)')


@pytest.mark.parametrize("salt", [0, 31, 7919, 104729])
def test_our_heads_run_before_the_mod_and_our_tails_after(salt):
    rt = machine(salt=salt)
    own(rt, "PRE_LOAD_SCREEN", "head", "sync")
    register(rt, 3, "PRE_LOAD_SCREEN")
    own(rt, "PRE_LOAD_SCREEN", "tail", "hide")
    rt.execute("levelLoad()")
    assert ran(rt) == ["sync", "1", "2", "3", "hide"]


def test_without_a_hosted_callback_ours_run_at_their_own_turn():
    """Nothing changes without a hosted mod: no batch, the engine's own order."""
    rt = machine(salt=7919)
    rt.execute("""
        own = {}
        for _, name in ipairs({ "a", "b", "z" }) do
            local register = name == "z" and Determinism.tail or Determinism.head
            own[register(ON.POST_LOAD_SCREEN, name, function() ran[#ran + 1] = name end)] = name
        end
    """)
    rt.execute("levelLoad()")
    engine = [str(rt.eval(f"own[{int(i)}]")) for i in rt.eval("reached[ON.POST_LOAD_SCREEN]").values()
              if rt.eval(f"own[{int(i)}]") is not None]
    assert sorted(engine) == ["a", "b", "z"]
    assert ran(rt) == engine
    assert engine != ["a", "b", "z"], "pick a salt where the engine's order is not ours; no test"


def test_a_head_that_blocks_the_load_keeps_the_mods_callbacks_out_of_it():
    """Our PRE_LOAD_SCREEN returns true to skip a load (an instant restart being
    voted on, a menu screen): the mod's callbacks are for a load that is not happening
    and do not run. Our tail still does."""
    for salt in (0, 31, 7919):
        rt = machine(salt=salt)
        rt.execute('Determinism.head(ON.PRE_LOAD_SCREEN, "skip", function()'
                   ' ran[#ran + 1] = "skip"; return true end)')
        register(rt, 3, "PRE_LOAD_SCREEN")
        own(rt, "PRE_LOAD_SCREEN", "tail", "hide")
        assert rt.eval("levelLoad()") == "blocked", f"salt {salt}"
        assert ran(rt) == ["skip", "hide"], f"salt {salt}"


def test_a_heads_error_is_raised_at_its_own_turn_and_stops_nothing():
    rt = machine(salt=7919)
    rt.execute('Determinism.head(ON.POST_UPDATE, "boom", function() error("head boom") end)')
    register(rt, 2, "POST_UPDATE")
    rt.execute("frame()")
    assert ran(rt) == ["1", "2"]
    assert any("head boom" in e for e in rt.eval("engineErrors").values())


# --------------------------------------------------------- the mod's random numbers

def test_the_mods_update_draws_depend_on_the_frame_not_on_what_ran_between():
    """GAMEFRAME reseeds the mod's generator; between it and the next PRE_UPDATE come
    the render callbacks, which run as often as a machine draws. A draw there moved
    the stream the mod's next update read."""
    def draws(renders):
        rt = machine(salt=31)
        rt.execute("got = {}")
        rt.execute("""
            env.set_callback(load("return function() got[#got + 1] = math.random(1, 1000000) end",
                "@hooks/pre.lua", "t", env)(), ON.PRE_UPDATE)
            env.set_callback(load("return function() got[#got + 1] = math.random(1, 1000000) end",
                "@hooks/post.lua", "t", env)(), ON.POST_UPDATE)
            renderDraw = load("return function() math.random() end", "@hooks/render.lua", "t", env)()
        """)
        for n in renders:
            rt.execute(f"for _ = 1, {n} do renderDraw() end; frame()")
        return [int(v) for v in rt.eval("got").values()]
    assert draws([0, 3, 1]) == draws([5, 0, 2])


def test_alone_the_mods_update_draws_are_left_alone():
    rt = machine(active=False)
    rt.execute("""
        env.set_callback(load("return function() got = math.random(1, 1000000) end",
            "@hooks/pre.lua", "t", env)(), ON.PRE_UPDATE)
        math_state = env.math.random(1, 1000000)
    """)
    rt.execute("env.math.randomseed(42); expect = env.math.random(1, 1000000)")
    rt.execute("env.math.randomseed(42); fire(ON.PRE_UPDATE)")
    assert int(rt.eval("env.got")) == int(rt.eval("expect"))


# --------------------------------------------------- run as Callbacks would run them

def test_through_one_of_ours_the_mod_still_runs_at_depth_zero():
    """The engine can start a batch from one of OUR callbacks, where our depth is
    one: the mod's bare clear_callback() would then be refused as one of ours. Each
    of the mod's runs at depth zero, as inside Callbacks.hosted."""
    rt = machine(salt=0, mode="append", callbacks_module=True)
    rt.execute('Determinism.head(ON.POST_UPDATE, "ours", function() end)')
    rt.execute("depths = {}")
    register(rt, 2, "POST_UPDATE", body="depths[#depths + 1] = Callbacks.depth()")
    rt.execute("frame()")
    assert [int(v) for v in rt.eval("depths").values()] == [0, 0]


def test_a_batch_charges_each_callback_on_its_own_name():
    """The profile names the callback that costs the time: each of the mod's, not the
    one the engine happened to start the batch from."""
    rt = machine(salt=0, mode="append", callbacks_module=True)
    rt.execute("""
        lines = {}
        DesyncLog = { event = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end }
    """)
    rt.execute('Determinism.head(ON.POST_UPDATE, "ours", function() end)')
    # the mod's chunk writes its globals into the sandbox: the clock is the engine's
    register(rt, 3, "POST_UPDATE", body="_G.nowValue = _G.nowValue + 2 * {n}")
    rt.execute("for _ = 1, 1500 do nowValue = nowValue + 8; frame() end")
    rows = [str(v) for v in rt.eval("lines").values() if "% of window" in str(v)]
    share = {}
    for row in rows:
        pct = float(row.split("PROFILE")[1].split("%")[0])
        name = row.split("spikes")[1].split(None, 1)[1]
        share[name] = max(pct, share.get(name, 0.0))
    mods = {n: v for n, v in share.items() if "POST_UPDATE" in n and n.startswith("mod")}
    assert len(mods) == 3, rows
    third = [v for n, v in mods.items() if "POST_UPDATE3.lua" in n][0]
    first = [v for n, v in mods.items() if "POST_UPDATE1.lua" in n][0]
    assert third > first * 2, ("each of the mod's callbacks should carry its own time", rows)
    for name, pct in share.items():
        if name.startswith("ours"):
            assert pct < 1.0, ("the batch's time was charged again to the callback of"
                               " ours it ran inside", name, rows)


# ----------------------------------------------- events fired once a room, a layer

def rooms(rt, n=3):
    """A floor's rooms, asked one after another in one frame with nothing between,
    as the engine's generation does: each gets the room the engine settled on."""
    rt.execute("frameNo = frameNo + 1; picked = {}")
    for i in range(1, n + 1):
        rt.execute(f"picked[{i}] = fire(ON.PRE_GET_RANDOM_ROOM, {i}, 2, 0, 5)")
    return [rt.eval(f"picked[{i}]") for i in range(1, n + 1)]


ROOM_HOOKS = (
    # two of the mod's room callbacks can answer for room 2: the first registered wins
    "draws[#draws + 1] = {n}; if select(1, ...) == 2 and {n} >= 2 then return 'room{n}' end"
)


def test_a_room_two_callbacks_can_answer_for_gets_the_same_one_on_every_machine():
    host, peer = machine(salt=0), machine(salt=104729)
    for rt in (host, peer):
        rt.execute("draws = {}")
        register(rt, 4, "PRE_GET_RANDOM_ROOM", body=ROOM_HOOKS)
    picked = [rooms(rt) for rt in (host, peer)]
    assert picked[0] == picked[1] == [False, "room2", False]  # False: no room picked
    assert draws(host) == draws(peer) == [1, 2, 3, 4, 1, 2, 1, 2, 3, 4]
    # ...where left to themselves the two engines would not have agreed
    assert engine_order(host, "PRE_GET_RANDOM_ROOM") != engine_order(peer, "PRE_GET_RANDOM_ROOM")


def test_every_room_is_a_pass_of_its_own():
    rt = machine(salt=31)
    register(rt, 3, "PRE_GET_RANDOM_ROOM")
    rooms(rt, n=4)
    assert ran(rt) == ["1", "2", "3"] * 4


def draws(rt):
    return [int(v) for v in rt.eval("draws").values()]


def test_reached_again_within_one_room_it_runs_once():
    """A room callback that registers one: the insert can rehash the engine's map
    under its walk, which then reaches callbacks it already ran. They do not run
    again."""
    rt = machine(mode="append", callbacks_module=True)
    register(rt, 3, "PRE_GET_RANDOM_ROOM", body=(
        "if {n} == 1 then env.set_callback(function() end, ON.POST_LEVEL_GENERATION) end"))
    a, b, c = (int(rt.eval(f"ids['{i}']")) for i in "123")
    rt.execute(f"frameNo = frameNo + 1; script = {{ {a}, {b}, {c}, {b}, {a} }};"
               " fire(ON.PRE_GET_RANDOM_ROOM, 1, 1, 0, 5)")
    assert ran(rt) == ["1", "2", "3"]


def test_with_nothing_counting_registrations_a_room_reached_again_is_that_room():
    """Unsure whether the engine asked again or its map rehashed, nothing runs twice."""
    rt = machine(mode="append")
    register(rt, 3, "PRE_GET_RANDOM_ROOM")
    a, b, c = (int(rt.eval(f"ids['{i}']")) for i in "123")
    rt.execute(f"frameNo = frameNo + 1; script = {{ {a}, {b}, {c}, {b}, {a} }};"
               " fire(ON.PRE_GET_RANDOM_ROOM, 1, 1, 0, 5)")
    assert ran(rt) == ["1", "2", "3"]


def test_a_room_asked_about_twice_in_a_row_is_answered_twice():
    """Should the engine ask about one room twice in a row, handing over the same room
    both times, both are answered, the same way on every machine: with no set_callback
    made since the first, a callback reached again can only be the second asking."""
    host, peer = (machine(salt=s, callbacks_module=True) for s in (0, 104729))
    for rt in (host, peer):
        rt.execute("draws = {}")
        register(rt, 4, "PRE_GET_RANDOM_ROOM", body=ROOM_HOOKS)
        rt.execute("frameNo = frameNo + 1; first = fire(ON.PRE_GET_RANDOM_ROOM, 2, 2, 0, 5);"
                   " second = fire(ON.PRE_GET_RANDOM_ROOM, 2, 2, 0, 5)")
        assert rt.eval("first") == rt.eval("second") == "room2"
    assert draws(host) == draws(peer) == [1, 2, 1, 2]


def test_the_room_tiles_callbacks_share_the_engines_context_and_stop_at_a_true():
    rt = machine(salt=7919)
    rt.execute("ctx = { tiles = {} }")
    register(rt, 3, "PRE_HANDLE_ROOM_TILES", body=(
        "local ctx = select(4, ...); ctx.tiles[#ctx.tiles + 1] = {n};"
        " if {n} == 2 then return true end"))
    rt.execute("frameNo = frameNo + 1; stoppedAt = fire(ON.PRE_HANDLE_ROOM_TILES, 1, 2, 5, ctx)")
    assert rt.eval("stoppedAt") is True
    assert [int(v) for v in rt.eval("ctx.tiles").values()] == [1, 2]
    clear_ran(rt)
    rt.execute("fire(ON.PRE_HANDLE_ROOM_TILES, 2, 2, 5, ctx)")
    assert ran(rt) == ["1", "2"], "the next room is the next pass"


def test_each_layer_made_in_one_load_is_a_pass_of_its_own():
    host, peer = machine(salt=0), machine(salt=7919)
    for rt in (host, peer):
        register(rt, 3, "POST_LAYER_CREATION")
        rt.execute("frameNo = frameNo + 1; fire(ON.POST_LAYER_CREATION, 0);"
                   " fire(ON.POST_LAYER_CREATION, 1)")
    assert ran(host) == ran(peer) == ["1", "2", "3"] * 2


def test_a_room_callback_that_answers_with_something_else_is_left_to_the_engine():
    """The engine takes only a string for a room, and says so for anything else; a
    callback returning a number does not win the room in the batch either."""
    rt = machine(salt=31)
    register(rt, 2, "PRE_GET_RANDOM_ROOM", body="if {n} == 1 then return 7 end; return 'r{n}'")
    assert rooms(rt, n=1) == ["r2"]


def test_a_floor_block_names_the_mods_callbacks_by_ordered_event():
    """How many of the mod's callbacks each event has, and how often the room ones
    fired since the last floor block: two of them for one room event can both answer
    for a room, and the same floor fires them as often on every machine."""
    host, peer = machine(salt=0), machine(salt=104729)
    for rt in (host, peer):
        assert rt.eval("Determinism.orderedCensus()") is None
        register(rt, 3, "PRE_GET_RANDOM_ROOM")
        register(rt, 2, "POST_UPDATE", tag="u")
        rooms(rt, n=4)
        rt.execute("frame(); frame()")
    lines = [rt.eval("Determinism.orderedCensus()") for rt in (host, peer)]
    assert lines[0] == lines[1] == "POST_UPDATE 2, PRE_GET_RANDOM_ROOM 3 (fired 4)"
    assert host.eval("Determinism.orderedCensus()") == \
        "POST_UPDATE 2, PRE_GET_RANDOM_ROOM 3 (fired 0)", "counted from the last block"
