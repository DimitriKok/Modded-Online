"""A player folded back into a run gets the run as the hosted mod remembers it.

The world host's snapshot of the ENGINE's state already rebuilds the party's next
floor on every machine. Spelunky 2.5 keeps the run's history in its own memory as
well, and a game that rejoins mid-run has none of it: room QZUX's returning player
warped in from the camp, where Overlunky's warp() raises the reset flag, and 2.5 reset
its whole run -- then rolled a new Dwelling plan and built a different 1-4 from the
same seed. Now an adapter hands that memory over: 2.5's game object (its globalState,
the plan and every quest, and which of its worlds the run is in), the custom items its
Custom Entities library carries from floor to floor, and what four of its item files
keep in locals of their own after reading the screen being left (a ray gun's charge, a
ridden Qilin, the quest items being carried).

Here 2.5 is a stand-in shaped like the real one where it matters: the game is a local
its callbacks hold (main.lua's `game`, reached through Helpers2.onCallback's wrapper),
globalState is a Sp25GameStateClass instance, the library's functions share four
carry lists defined in a file named custom_entities.lua, and each item file returns
its initialize function to the `require` that loaded it.

Run:  python -m pytest tests/test_run_state.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
DETERMINISM = (PACK / "src" / "determinism.lua").read_text(encoding="utf-8")
JSON = (PACK / "src" / "json.lua").read_text(encoding="utf-8")

ENGINE = """
ON = { FRAME = 1, GAMEFRAME = 2, LOADING = 3, LEVEL = 4, PRE_LEVEL_GENERATION = 5,
       POST_LEVEL_GENERATION = 6, PRE_LOAD_LEVEL_FILES = 7, PRE_LOAD_SCREEN = 8,
       PRE_UPDATE = 9, POST_UPDATE = 10, RESET = 15, CAMP = 16 }
frameNo = 100
function get_frame() return frameNo end
function get_adventure_seed() return 0x5EEDF00D, 0xD125E0C4 end
function get_local_state() return { world = 2, level = 1, theme = 2, time_total = 900 } end
function seed_prng() end
prng = { get_pair = function(_, c) return c, c end, set_pair = function() end }
callbacks, nextId = {}, 0
function set_callback(fn, kind) nextId = nextId + 1; callbacks[nextId] = { fn = fn, kind = kind }; return nextId end
function clear_callback() end
"""

# 2.5, as far as this needs it. Each piece in a file of its own name, run in the sandbox.
SP25_STATE = """
Sp25GameStateClass = {}
Sp25GameStateClass.__index = Sp25GameStateClass
function Sp25GameStateClass:construct()
    return setmetatable({
        challengeWorlds = {}, challengeWorldRolls = {}, crownPowerupsBySlot = {},
        anubisFavor = 0, quetzalcoatlFavor = 0, necronomiconBySlot = {},
        summitSpecialLevel = 0, summitSpecialVisitWorld = -1,
    }, self)
end
"""
SP25_GAME = """
local gameClass = { sp25World = 0, spelunky2World = 0 }
gameClass.__index = gameClass
Sp25GameClass = gameClass
function gameClass:resetGame()
    self.sp25World = 1      -- DWELLING
    self.spelunky2World = 1
    self.globalState = Sp25GameStateClass:construct()
    self.gameRestarted = true
end
"""
SP25_HELPERS = """
Helpers2 = {}
function Helpers2.onCallback(debugName, callback, event)
    local callbackName = "onCallback-" .. debugName
    return set_callback(function(...)
        local ok, result = pcall(callback, ...)
        return result
    end, event)
end
"""
SP25_MAIN = """
local function sp25ModStart()
    local game = setmetatable({}, Sp25GameClass)
    game:resetGame()
    Helpers2.onCallback("game:init(RESET)", function() game:resetGame() end, ON.RESET)
    Helpers2.onCallback("game:init(CAMP)", function() game:resetGame() end, ON.CAMP)
    sp25 = { probeGame = function() return game end } -- for the test to look at, only
end
sp25ModStart()
"""
# 2.5's item files that keep, in locals, what their load callbacks read off the screen
# being left. Each returns its initialize function, as the real ones do; `*Probe`
# globals are for the test to look and to play the transition, only.
RAY_GUN = """
local transitionRestoreBySlot = {}
local function rememberHeldRayGunsForTransition()
    for slot, shots in pairs(rayGunsOnScreen or {}) do
        transitionRestoreBySlot[slot] = { shots_left = shots }
    end
end
local function initialize(game)
    set_callback(function()
        if resetRequested then
            transitionRestoreBySlot = {}
            return
        end
        rememberHeldRayGunsForTransition()
    end, ON.PRE_LOAD_SCREEN)
end
rayGunProbe = {
    leave = rememberHeldRayGunsForTransition,
    get = function() return transitionRestoreBySlot end,
}
return initialize
"""
QILIN = """
local questRockWasHeld = false
local rapidQilinUid = -1
local rapidQilinHealth = nil
local rapidQilinTransitionPending = false
local rapidQilinRestoreFrames = 0
local rapidQilinStates = {}
local function captureRapidQilinBeforeScreenChange()
    local riding = qilinOnScreen
    rapidQilinStates = {}
    rapidQilinUid = -1
    if riding == nil then
        rapidQilinTransitionPending = false
        rapidQilinRestoreFrames = 0
        return
    end
    rapidQilinHealth = riding
    rapidQilinTransitionPending = true
    rapidQilinRestoreFrames = 120
end
local function captureQuestCarryBeforeScreenChange()
    captureRapidQilinBeforeScreenChange()
    if rockOnScreen ~= nil then
        questRockWasHeld = rockOnScreen
    end
end
local function initialize(game)
    set_callback(captureQuestCarryBeforeScreenChange, ON.PRE_LOAD_SCREEN)
end
qilinProbe = {
    leave = captureQuestCarryBeforeScreenChange,
    track = function(uid) rapidQilinStates[uid] = { warmupFrames = 8, health = 7 }; rapidQilinUid = uid end,
    get = function()
        return { questRockWasHeld = questRockWasHeld, rapidQilinUid = rapidQilinUid,
            rapidQilinHealth = rapidQilinHealth, pending = rapidQilinTransitionPending,
            restoreFrames = rapidQilinRestoreFrames, states = rapidQilinStates }
    end,
    setHealth = function(h) rapidQilinHealth = h end,
}
return initialize
"""
CRYSTAL_UDJAT = """
local crystalUdjatWasHeld = false
local function captureBeforeScreenChange()
    if udjatOnScreen ~= nil then
        crystalUdjatWasHeld = udjatOnScreen
    end
end
local function initialize(game)
    set_callback(function() captureBeforeScreenChange() end, ON.PRE_LOAD_SCREEN)
end
udjatProbe = { get = function() return crystalUdjatWasHeld end }
return initialize
"""
WORM_MEAT = """
local wormMeatWasHeld = false
local function capture_before_screen_change()
    if meatOnScreen ~= nil then
        wormMeatWasHeld = meatOnScreen
    end
end
local function initialize(game)
    set_callback(capture_before_screen_change, ON.PRE_LOAD_SCREEN)
end
meatProbe = { get = function() return wormMeatWasHeld end }
return initialize
"""
# 2.5's hook registry, as far as this needs it: a context per runWhen, with its name
# and its handler.
HOOKS = """
local contextClass = {}
contextClass.__index = contextClass
Hooks = { hooks = {}, alwaysHooks = {}, alwaysCheckHooks = {} }
function Hooks.runWhen(name, condition, handler)
    local ctx = setmetatable({ name = name, handler = handler }, contextClass)
    if condition.exceptWorld ~= nil then
        table.insert(Hooks.alwaysCheckHooks, ctx)
    else
        local key = tostring(condition.world)
        Hooks.hooks[key] = Hooks.hooks[key] or {}
        table.insert(Hooks.hooks[key], ctx)
    end
end
"""
# The Summit climbers' chain, kept in initialize's locals so that it outlives each
# floor's callbacks, as 2.5's own comment says.
CLIMBERS = """
local function initialize(game)
    local quest_active = false
    local quest_failed = false
    local saved_count = 0
    local active_fly_uid = -1
    local active_fly_level = -1
    local level_is_ending = false
    local pending_rescued_climber = nil
    local pending_fly_level = -1
    local pending_fly_attempts = 0
    Hooks.runWhen("climberchainquest@Summit", { world = 9 }, function(hook)
        level_is_ending = false
        if quest_active and not quest_failed then
            saved_count = saved_count + 1
        end
    end)
    Hooks.runWhen("cleanup-climberchainquest@NOT-Summit", { exceptWorld = 9 }, function(hook)
        quest_active = false
        quest_failed = false
        saved_count = 0
        active_fly_uid = -1
        active_fly_level = -1
        level_is_ending = false
        pending_rescued_climber = nil
        pending_fly_level = -1
        pending_fly_attempts = 0
    end)
    climbersProbe = {
        start = function()
            quest_active, saved_count, active_fly_uid, active_fly_level = true, 1, 411, 2
            level_is_ending, pending_fly_level, pending_fly_attempts = true, 3, 2
            pending_rescued_climber = { level = 2, x = 10.5, y = 80, layer = 0 }
        end,
        get = function()
            return { quest_active = quest_active, quest_failed = quest_failed,
                saved_count = saved_count, active_fly_uid = active_fly_uid,
                active_fly_level = active_fly_level, level_is_ending = level_is_ending,
                pending = pending_rescued_climber, pending_fly_level = pending_fly_level,
                attempts = pending_fly_attempts }
        end,
    }
end
return initialize
"""
ITEMS = "Mods/Packs/fyi.spelunky-25-2/src/items/"
CLIMBERS_FILE = "Mods/Packs/fyi.spelunky-25-2/src/hooks/summit/climbersquest.lua"
ITEM_FILES = {
    ITEMS + "rayGun.lua": RAY_GUN,
    ITEMS + "qilinQuest.lua": QILIN,
    ITEMS + "crystalUdjatQuest.lua": CRYSTAL_UDJAT,
    ITEMS + "wormMeat.lua": WORM_MEAT,
    CLIMBERS_FILE: CLIMBERS,
}

CUSTOM_ENTITIES = """
local module = {}
local custom_entities_t_info = {}
local custom_entities_t_info_hh = {}
local custom_entities_t_info_storage = {}
local custom_entities_t_info_cog_ankh = {}
local function set_transition_info(c_type_id, data, slot, carry_type)
    table.insert(custom_entities_t_info, { custom_type_id = c_type_id, data = data,
        slot = slot, carry_type = carry_type })
end
function module.carry(c_type_id, data, slot, carry_type)
    set_transition_info(c_type_id, data, slot, carry_type)
end
function module.carried() return custom_entities_t_info end
function module.custom_init()
    -- the library's PRE_LOAD_SCREEN reset, shape only
    return function()
        custom_entities_t_info = {}
        custom_entities_t_info_hh = {}
        custom_entities_t_info_storage = {}
        custom_entities_t_info_cog_ankh = {}
    end
end
function module.hired() return custom_entities_t_info_hh, custom_entities_t_info_storage,
    custom_entities_t_info_cog_ankh end
CustomEntities = module
"""


MOD_HOST = """
loadedModules = {}
-- modHost's own, as far as the adapter uses it: what a file returned to `require`
ModHost = {
    loadedModuleValue = function(e, suffix)
        for path, value in pairs(loadedModules) do
            if path:sub(-#suffix) == suffix then
                return value
            end
        end
        return nil
    end,
}
"""


def chunk(rt, src, name):
    rt.eval("function(src, name) loadedModules[name] = assert(load(src, '@' .. name, 't', env))()"
            " end")(src, name)


def machine(items=None):
    """One machine's Modded Online with 2.5 hosted, freshly loaded."""
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(MOD_HOST)
    rt.execute(DETERMINISM)
    rt.globals().Json = rt.execute(JSON)
    rt.execute("""
        env = setmetatable({}, {__index = _G})
        env.set_callback = function(fn, kind) return set_callback(fn, kind) end
        env.clear_callback = function() end
        control = Determinism.install(env, { active = function() return true end })
    """)
    chunk(rt, SP25_STATE, "Mods/Packs/fyi.spelunky-25-2/src/gameState.lua")
    chunk(rt, SP25_GAME, "Mods/Packs/fyi.spelunky-25-2/src/game.lua")
    chunk(rt, SP25_HELPERS, "Mods/Packs/fyi.spelunky-25-2/src/helpers2.lua")
    chunk(rt, HOOKS, "Mods/Packs/fyi.spelunky-25-2/src/hooks.lua")
    chunk(rt, CUSTOM_ENTITIES,
          "Mods/Packs/fyi.spelunky-25-2/src/thirdParty/SereneRuby12/customEnt/custom_entities.lua")
    chunk(rt, SP25_MAIN, "Mods/Packs/fyi.spelunky-25-2/main.lua")
    for name, src in (ITEM_FILES if items is None else items).items():
        chunk(rt, src, name)
        rt.eval("function(name) loadedModules[name](env.sp25.probeGame()) end")(name)
    rt.execute("control.detectAdapters()")
    return rt


def host_in_a_run():
    """The world host, three worlds in: a plan rolled, quests under way, a custom item
    carried into the transition, with this machine's own hook ids on it."""
    rt = machine()
    rt.execute("""
        local game = env.sp25.probeGame()
        game.sp25World = 7
        game.spelunky2World = 3
        game.gameRestarted = false
        game.transitionFromSp25World = 7
        game.transitionToSp25World = 9
        local gs = game.globalState
        gs.dwellingQuestLevel = 3
        gs.dwellingQuestKind = "cook"
        gs.dwellingChallengeKind = false
        gs.challengeWorlds[4] = true
        gs.challengeWorldRolls[4] = "comet"
        gs.crownPowerupsBySlot[1] = { crownOfPower = true }
        gs.anubisFavor = 2
        gs.tonicColors = { speed = "red", luck = "teal" }
        gs.summitSpecialLevel = 3
        gs.ratio = 0.1
        gs.note = "50%; done\\n"
        env.CustomEntities.carry(12, { ammo = 3, _lib_callbacks = { 4711, 4712 },
            last_holder = io and io.stdout or newproxy and newproxy() or nil }, 1, 1)
        env.CustomEntities.carry(31, { charge = 0.75 }, 2, 3)
    """)
    return rt


def host_leaving_the_transition():
    """...and its load of the next floor has read the transition it is leaving: player 1
    holds a ray gun with two shots and the quest's egg, player 2 rides the rapid Qilin."""
    rt = host_in_a_run()
    rt.execute("""
        env.qilinProbe.track(77)
        env.rayGunsOnScreen = { [1] = 2 }
        env.qilinOnScreen = 5
        env.rockOnScreen = true
        env.udjatOnScreen = false
        env.meatOnScreen = true
        env.rayGunProbe.leave()
        env.qilinProbe.leave()
        env.climbersProbe.start()
    """)
    rt.execute("for _, cb in pairs(callbacks) do if cb.kind == ON.PRE_LOAD_SCREEN then cb.fn() end end")
    return rt


def returning_player():
    """The player coming back: a fresh game, reset by the camp, carrying nothing."""
    return machine()


def game_of(rt):
    return rt.eval("env.sp25.probeGame()")


def to_py(v):
    if type(v).__name__ == "_LuaTable":
        return {(int(k) if isinstance(k, float) and k.is_integer() else k): to_py(x)
                for k, x in v.items()}
    return v


def capture(rt):
    blob, info = rt.eval("control.captureRun()")
    assert blob is not None, info
    return blob


def apply(rt, blob):
    ok, what = rt.eval("control.applyRun")(blob)
    assert ok is True, what
    return what


# ------------------------------------------------------------------- the handover

def test_the_returning_players_2_5_is_in_the_hosts_run_after_the_handover():
    host, back = host_in_a_run(), returning_player()
    assert to_py(game_of(back)["globalState"]) != to_py(game_of(host)["globalState"])
    apply(back, capture(host))
    hg, bg = game_of(host), game_of(back)
    assert to_py(bg["globalState"]) == to_py(hg["globalState"])
    for field in ("sp25World", "spelunky2World", "gameRestarted",
                  "transitionFromSp25World", "transitionToSp25World"):
        assert bg[field] == hg[field], field


def test_after_it_both_machines_read_the_same_run_state():
    host, back = host_in_a_run(), returning_player()
    apply(back, capture(host))
    assert capture(back) == capture(host)
    assert host.eval("control.runDigest()") == back.eval("control.runDigest()")


def test_the_carried_custom_items_come_across_without_this_machines_hook_ids():
    host, back = host_in_a_run(), returning_player()
    apply(back, capture(host))
    carried = to_py(back.eval("env.CustomEntities.carried()"))
    assert carried == {
        1: {"custom_type_id": 12, "data": {"ammo": 3}, "slot": 1, "carry_type": 1},
        2: {"custom_type_id": 31, "data": {"charge": 0.75}, "slot": 2, "carry_type": 3},
    }


def test_the_library_reads_the_lists_it_was_given():
    """The four lists are locals its functions share: every one of them sees them."""
    host, back = host_in_a_run(), returning_player()
    apply(back, capture(host))
    back.execute("env.CustomEntities.carry(5, { x = 1 }, 3, 1)")
    assert len(back.eval("env.CustomEntities.carried()")) == 3


def test_the_game_keeps_its_own_tables_where_anyone_holds_one():
    """globalState is updated in place: a module that kept a reference to it, or to a
    table inside it, sees the host's run there too."""
    host, back = host_in_a_run(), returning_player()
    back.execute("keptState = env.sp25.probeGame().globalState;"
                 " keptCrowns = keptState.crownPowerupsBySlot")
    apply(back, capture(host))
    assert back.eval("keptState == env.sp25.probeGame().globalState") is True
    assert back.eval("keptCrowns == keptState.crownPowerupsBySlot") is True
    assert back.eval("getmetatable(keptState) == env.Sp25GameStateClass") is True
    assert back.eval("keptCrowns[1].crownOfPower") is True


def test_putting_the_same_state_in_twice_changes_nothing():
    """The returning player puts it in at the head of their load and again at its tail."""
    host, back = host_leaving_the_transition(), returning_player()
    blob = capture(host)
    apply(back, blob)
    once = capture(back)
    apply(back, blob)
    assert capture(back) == once == blob


def test_what_the_host_does_not_have_the_returning_player_does_not_keep():
    host, back = host_in_a_run(), returning_player()
    back.execute("env.sp25.probeGame().globalState.leftOver = 9")
    apply(back, capture(host))
    assert back.eval("env.sp25.probeGame().globalState.leftOver") is None


def test_a_function_or_an_engine_object_in_its_state_stays_where_it_is():
    host, back = host_in_a_run(), returning_player()
    host.execute("env.sp25.probeGame().globalState.cached = function() return 1 end")
    back.execute("mine = function() return 2 end; env.sp25.probeGame().globalState.cached = mine")
    apply(back, capture(host))
    assert back.eval("env.sp25.probeGame().globalState.cached == mine") is True


# --------------------------------------------- what 2.5's own files carry across

def test_what_2_5_read_off_the_transition_comes_across():
    host, back = host_leaving_the_transition(), returning_player()
    what = apply(back, capture(host))
    assert what.endswith("2 carried custom item(s), 18 of its own")
    assert to_py(back.eval("env.rayGunProbe.get()")) == {1: {"shots_left": 2}}
    qilin = to_py(back.eval("env.qilinProbe.get()"))
    assert qilin == {"questRockWasHeld": True, "rapidQilinUid": -1, "rapidQilinHealth": 5,
                     "pending": True, "restoreFrames": 120, "states": {}}
    assert back.eval("env.udjatProbe.get()") is False
    assert back.eval("env.meatProbe.get()") is True


def test_the_climbers_chain_comes_across_from_summit_2_to_3():
    host, back = host_leaving_the_transition(), returning_player()
    apply(back, capture(host))
    assert to_py(back.eval("env.climbersProbe.get()")) == {
        "quest_active": True, "quest_failed": False, "saved_count": 1, "active_fly_uid": 411,
        "active_fly_level": 2, "level_is_ending": True,
        "pending": {"level": 2, "x": 10.5, "y": 80, "layer": 0},
        "pending_fly_level": 3, "attempts": 2,
    }
    # ...and the quest's own per-floor callback, which 2.5 rebuilds every floor, sees it
    back.execute("for _, ctx in ipairs(env.Hooks.hooks['9']) do ctx.handler({}) end")
    assert back.eval("env.climbersProbe.get().saved_count") == 2


def test_without_the_climbers_hook_nothing_is_handed_over():
    items = dict(ITEM_FILES)
    items[CLIMBERS_FILE] = CLIMBERS.replace("cleanup-climberchainquest@NOT-Summit", "cleanup-renamed")
    rt = machine(items)
    blob, why = rt.eval("control.captureRun()")
    assert blob is None and why == "the hook cleanup-climberchainquest@NOT-Summit was not found"


def test_the_values_are_the_files_own_and_every_function_there_sees_them():
    """The locals are shared by every function of the file: the callback the mod
    registered sees what was put in, not only the function it was read through."""
    host, back = host_leaving_the_transition(), returning_player()
    apply(back, capture(host))
    back.execute("env.rayGunsOnScreen = { [3] = 1 }")
    back.execute("for _, cb in pairs(callbacks) do if cb.kind == ON.PRE_LOAD_SCREEN then cb.fn() end end")
    assert to_py(back.eval("env.rayGunProbe.get()")) == {1: {"shots_left": 2}, 3: {"shots_left": 1}}


def test_a_value_the_host_holds_as_nil_comes_across_as_nil():
    host, back = host_leaving_the_transition(), returning_player()
    host.execute("env.qilinProbe.setHealth(nil)")
    back.execute("env.qilinProbe.setHealth(9)")
    apply(back, capture(host))
    assert back.eval("env.qilinProbe.get().rapidQilinHealth") is None


def test_one_of_them_missing_means_nothing_is_handed_over():
    items = dict(ITEM_FILES)
    items[ITEMS + "wormMeat.lua"] = WORM_MEAT.replace("wormMeatWasHeld", "wormMeatHeld")
    rt = machine(items)
    blob, why = rt.eval("control.captureRun()")
    assert blob is None and why == "/src/items/wormMeat.lua:wormMeatWasHeld was not found"


def test_a_file_that_was_not_loaded_means_nothing_is_handed_over():
    items = dict(ITEM_FILES)
    del items[ITEMS + "crystalUdjatQuest.lua"]
    rt = machine(items)
    blob, why = rt.eval("control.captureRun()")
    assert blob is None and why == "/src/items/crystalUdjatQuest.lua was not loaded"


def test_a_name_that_could_mean_two_locals_is_refused():
    items = dict(ITEM_FILES)
    items[ITEMS + "qilinQuest.lua"] = QILIN.replace("local function initialize(game)", """
local function holder(questRockWasHeld) return function() return questRockWasHeld end end
local held = holder(true)
local function initialize(game)
    held()""")
    rt = machine(items)
    blob, why = rt.eval("control.captureRun()")
    assert blob is None and why == "/src/items/qilinQuest.lua:questRockWasHeld is not one local"


def test_another_file_of_the_same_name_is_not_it():
    """2.5 has hooks/temple/qilinQuest.lua as well as items/qilinQuest.lua."""
    items = dict(ITEM_FILES)
    del items[ITEMS + "qilinQuest.lua"]
    items["Mods/Packs/fyi.spelunky-25-2/src/hooks/temple/qilinQuest.lua"] = QILIN
    rt = machine(items)
    blob, why = rt.eval("control.captureRun()")
    assert blob is None and why == "/src/items/qilinQuest.lua was not loaded"


def test_a_run_state_this_build_did_not_write_is_not_applied():
    host, back = host_leaving_the_transition(), returning_player()
    name, text = capture(host).split(";", 1)
    data = host.eval("Determinism.decodeRun")(text)[0]
    data["v"] = 1
    old = name + ";" + host.eval("Determinism.encodeRun")(data)[0]
    ok, why = back.eval("control.applyRun")(old)
    assert ok is False and why == "it is not a run state this build reads"


# --------------------------------------------------------------- the fingerprint

def test_the_fingerprint_is_the_run_and_its_world_not_what_is_being_carried():
    """Two machines in the same run hold the same run state and world; what one of them
    is carrying across a load -- items, a ray gun's charge -- is not compared."""
    a, b = host_in_a_run(), host_leaving_the_transition()
    assert capture(a) != capture(b)
    assert a.eval("control.runDigest()") == b.eval("control.runDigest()")
    b.execute("env.sp25.probeGame().globalState.anubisFavor = 3")
    assert a.eval("control.runDigest()") != b.eval("control.runDigest()")
    b.execute("env.sp25.probeGame().globalState.anubisFavor = 2;"
              " env.sp25.probeGame().sp25World = 8")
    assert a.eval("control.runDigest()") != b.eval("control.runDigest()")


def test_after_the_handover_the_fingerprints_agree():
    host, back = host_leaving_the_transition(), returning_player()
    assert host.eval("control.runDigest()") != back.eval("control.runDigest()")
    apply(back, capture(host))
    assert host.eval("control.runDigest()") == back.eval("control.runDigest()")


# ------------------------------------------------------------------- refusals

def test_without_the_game_there_is_nothing_to_hand_over():
    rt = machine()
    rt.execute("for id in pairs(callbacks) do callbacks[id] = nil end")
    rt2 = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt2.execute(ENGINE)
    rt2.execute(DETERMINISM)
    rt2.execute("""
        env = setmetatable({}, {__index = _G})
        env.set_callback = function(fn, kind) return set_callback(fn, kind) end
        control = Determinism.install(env, { active = function() return true end })
    """)
    rt2.execute(MOD_HOST)
    chunk(rt2, SP25_STATE, "src/gameState.lua")
    chunk(rt2, SP25_GAME, "src/game.lua")
    chunk(rt2, CUSTOM_ENTITIES, "custom_entities.lua")
    rt2.execute("control.detectAdapters()")
    blob, why = rt2.eval("control.captureRun()")
    assert blob is None and "game was not found" in why


def test_without_the_item_lists_it_is_refused_rather_than_half_done():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(DETERMINISM)
    rt.execute("""
        env = setmetatable({}, {__index = _G})
        env.set_callback = function(fn, kind) return set_callback(fn, kind) end
        control = Determinism.install(env, { active = function() return true end })
    """)
    rt.execute(MOD_HOST)
    chunk(rt, SP25_STATE, "src/gameState.lua")
    chunk(rt, SP25_GAME, "src/game.lua")
    chunk(rt, SP25_HELPERS, "src/helpers2.lua")
    chunk(rt, CUSTOM_ENTITIES, "src/someOtherLib.lua")  # not the library's file
    chunk(rt, SP25_MAIN, "main.lua")
    rt.execute("control.detectAdapters()")
    blob, why = rt.eval("control.captureRun()")
    assert blob is None and "custom item lists were not found" in why


def test_a_mod_no_adapter_knows_is_not_handed_over():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENGINE)
    rt.execute(DETERMINISM)
    rt.execute("""
        env = setmetatable({}, {__index = _G})
        env.set_callback = function(fn, kind) return set_callback(fn, kind) end
        control = Determinism.install(env, { active = function() return true end })
        control.detectAdapters()
    """)
    blob, why = rt.eval("control.captureRun()")
    assert blob is None and "keeps its run" in why
    assert rt.eval("control.runSupported()")[0] is False


def test_a_run_state_too_big_for_one_datagram_is_refused():
    host = host_in_a_run()
    host.execute("""
        local gs = env.sp25.probeGame().globalState
        gs.huge = {}
        for i = 1, 4000 do gs.huge[i] = "value number " .. i end
    """)
    blob, why = host.eval("control.captureRun()")
    assert blob is None and "too big" in why


def test_a_run_state_from_another_build_is_not_applied():
    host, back = host_in_a_run(), returning_player()
    blob = capture(host)
    ok, why = back.eval("control.applyRun")("someone-else;" + blob.split(";", 1)[1])
    assert ok is False and "recognised" in why
    ok, why = back.eval("control.applyRun")("spelunky-2.5;tbroken")
    assert ok is False and "did not read back" in why
    # ...and nothing was changed by either
    assert back.eval("env.sp25.probeGame().sp25World") == 1


# ------------------------------------------------------------------- the encoding

def roundtrip(rt, lua_value_src):
    rt.execute(f"value = {lua_value_src}")
    text, info = rt.eval("Determinism.encodeRun(value)")
    assert text is not None, info
    back, why = rt.eval("Determinism.decodeRun")(text)
    assert why is None, why
    rt.globals().back = back
    return text


def test_numbers_come_back_exactly_integers_and_floats_apart():
    rt = machine()
    roundtrip(rt, "{ 1, 2.0, -7, 0.1, 1e300, -0.0, 2^53 + 1, math.mininteger, math.maxinteger,"
                  " 1/0, -1/0 }")
    for i in range(1, 12):
        assert rt.eval(f"math.type(value[{i}]) == math.type(back[{i}])") is True, i
        assert rt.eval(f"value[{i}] == back[{i}]") is True, i
    roundtrip(rt, "{ 0/0 }")
    assert rt.eval("back[1] ~= back[1]") is True


def test_strings_of_any_bytes_survive_and_the_text_is_plain_ascii():
    rt = machine()
    text = roundtrip(rt, '{ "a;b%c\\n\\0\\255 é", ["key;with%"] = "v" }')
    assert rt.eval("back[1] == value[1] and back['key;with%'] == 'v'") is True
    assert all(32 <= ord(c) <= 126 for c in text), text


def test_quotes_and_backslashes_do_not_grow_on_the_wire():
    rt = machine()
    text = roundtrip(rt, '{ [\'say "hi"\'] = "C:\\\\Mods\\\\Packs" }')
    assert '"' not in text and "\\" not in text, text
    assert rt.eval("back['say \"hi\"'] == value['say \"hi\"']") is True


def test_it_survives_the_wire():
    """The state rides the host's foldstate event as a string inside JSON, through the
    server."""
    host = host_in_a_run()
    blob = capture(host)
    wire = host.eval("Json.encode")(host.eval("function(b) return { st = { mod = { p = b } } } end")(blob))
    import json
    relayed = json.dumps(json.loads(wire))
    back = host.eval("Json.decode")(relayed)
    if isinstance(back, tuple):
        back = back[0]
    assert back["st"]["mod"]["p"] == blob


def test_the_same_state_built_in_another_order_is_the_same_text():
    rt = machine()
    rt.execute("""
        a = {}; a.x = 1; a.y = { 3, 4 }; a[5] = true; a[false] = "f"; a.z = "q"
        b = {}; b.z = "q"; b[false] = "f"; b[5] = true; b.y = { 3, 4 }; b.x = 1
    """)
    assert rt.eval("Determinism.encodeRun(a)")[0] == rt.eval("Determinism.encodeRun(b)")[0]


def test_a_table_met_twice_is_one_table_again():
    rt = machine()
    rt.execute("shared = { 1 }; value = { a = shared, b = shared }; value.self = value")
    text, _ = rt.eval("Determinism.encodeRun(value)")
    rt.globals().back = rt.eval("Determinism.decodeRun")(text)[0]
    assert rt.eval("back.a == back.b and back.self == back") is True


def test_what_does_not_travel_is_left_out_and_counted():
    rt = machine()
    rt.execute("value = { f = print, n = 1, [print] = 2, co = coroutine.create(print) }")
    text, info = rt.eval("Determinism.encodeRun(value)")
    rt.globals().back = rt.eval("Determinism.decodeRun")(text)[0]
    assert to_py(rt.eval("back")) == {"n": 1}
    assert int(info["skipped"]) == 3


@pytest.mark.parametrize("bad", ["", "x", "t", "i12", "tsa;", "r9;", "s%ZZ;", "Tjunk", "i1.5;"])
def test_anything_malformed_is_refused(bad):
    rt = machine()
    value, why = rt.eval("Determinism.decodeRun")(bad)
    assert why is not None, bad
