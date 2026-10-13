"""A player coming back mid-run is folded in at the next floor again, hosted mod and all.

dev85 made a returning player wait for the next run whenever a content mod was hosted:
the fold-in rebuilt the party from the ENGINE's state, and Spelunky 2.5's own memory of
the run did not come across (room QZUX built a different 1-4 at once). dev86 brings
them back again when every hosted mod's adapter can hand its run over.

When the run is taken matters as much as what is in it: the others load the floor from
the transition screen and the returning player from the camp, and 2.5's load callbacks
read the screen being left. So the world host that folds them in takes the mod's run at
the END of its own PRE_LOAD_SCREEN for that floor and sends it with the floor that load
goes to; the returning player waits in the camp for it, warps there, and puts it in at
the head of their load and again at its tail. Nobody else's game is touched.

That floor and the next are their probation: should theirs come out different from the
host's -- the entities, the mod's run, or their positions on it -- they go back to the
camp and join the next run, and the others play on as if they had stayed away. A hosted
mod nothing can hand over still means the next run, and the world host says so to all.

Run:  python -m pytest tests/test_fold_in.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")
NET_CORE = (PACK / "src" / "netCore.lua").read_text(encoding="utf-8").replace("\r\n", "\n")


def extract(start: str, src: str = EVENT_SYNC) -> str:
    assert start in src, start
    i = src.index(start)
    return src[i:src.index("\nend\n", i) + len("\nend\n")]


def between(start: str, last_function: str) -> str:
    i = EVENT_SYNC.index(start)
    j = EVENT_SYNC.index(last_function, i)
    return EVENT_SYNC[i:EVENT_SYNC.index("\nend\n", j) + len("\nend\n")]


ENV = """
module = {}
runActive, joinPending, joinInit, levelOrdinal = true, false, false, 4
nextFloorSeed, currentFloorOrd = { 11, 22 }, 4
pendingStateSync = nil
clock = 1000
function get_ms() return clock end
toasts, lines, sent, warps = {}, {}, {}, {}
flushes = 0
function toast(t) toasts[#toasts + 1] = t end
function errorf(fmt, ...) lines[#lines + 1] = "ERROR " .. string.format(fmt, ...) end
DesyncLog = { event = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end }
Network = {
    slot = 1, host = 1, PHASE = { INGAME = 3 },
    playerNames = { ["1"] = "EatYoCake", ["2"] = "DoctorPuppy", ["3"] = "Third" },
    isInRun = function() return runActive end,
    isWorldHost = function() return Network.slot == Network.host end,
    hostSlot = function() return Network.host end,
    sendEvent = function(kind, payload) sent[#sent + 1] = { kind = kind, payload = payload } end,
    flushEvents = function() flushes = flushes + 1 end,
    endMyRun = function() endedRun = true end,
    requestJoinFloor = function(dest, seed, ord, st)
        requested = { dest = dest, seed = seed, ord = ord, st = st }
    end,
}
InputSync = {
    hostedModName = function() return "Spelunky 2.5" end,
    endSession = function() sessionEnded = true end,
    beginSession = function() sessionBegun = true end,
}
packs = { "fyi.spelunky-25-2" }
supported, unsupportedWhy = true, nil
captured, captureWhy = { ["fyi.spelunky-25-2"] = "spelunky-2.5;t...e" }, nil
applyLines, applyOk = { "fyi.spelunky-25-2: world 7, 63 run values, 1 carried custom item(s),"
    .. " 18 of its own" }, true
applied = {}
ModHost = {
    hostedPacks = function() return packs end,
    runStateSupported = function() return supported, unsupportedWhy end,
    captureRunState = function() return captured, captureWhy end,
    applyRunState = function(states) applied[#applied + 1] = states; return applyLines, applyOk end,
}
function PackPath(rest) return "no/such/folder/" .. rest end
function clearRunState(reason) clearedFor = reason; runActive = false end
function moWarp(w, l, t) warps[#warps + 1] = { w, l, t } end
function set_adventure_seed() end
function applyRejoinKit() end
function applyFreshRunReset() end
function module.enforceRoster() end
THEME = { BASE_CAMP = 17, DWELLING = 1 }
SCREEN = { TRANSITION = 13, LEVEL = 12 }
FADE = { NONE = 0 }
transition = { screen = 13, loading = 0, world_next = 2, level_next = 2, theme_next = 2,
    screen_next = 12 }
function get_local_state() return transition end
function captureStateSync(withRunFlags) return { meta = { lc = 4 }, pl = {}, flags = withRunFlags } end
"""


def runtime(slot=1, host=1, in_run=True):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(between("-- ------------------------------------------------- bringing a player back",
                       "function module.onFoldTail()"))
    rt.execute(extract("function module.hostedModName()"))
    rt.execute(extract("local function onJoinPending(payload)") + "onJoinPendingG = onJoinPending\n")
    rt.execute(extract("local function pollJoinAtTransition()")
               + "pollJoinAtTransitionG = pollJoinAtTransition\n")
    rt.execute(extract("local function onRunStart(payload)") + "onRunStartG = onRunStart\n")
    rt.execute(f"Network.slot, Network.host = {slot}, {host}; runActive = {str(in_run).lower()}")
    return rt


def table(rt, **fields):
    t = rt.eval("{}")
    for k, v in fields.items():
        t[k] = v
    return t


def lua_list(rt, items):
    t = rt.eval("{}")
    for i, v in enumerate(items, start=1):
        t[i] = v
    return t


def pending(rt, slot=2, name="DoctorPuppy"):
    rt.eval("onJoinPendingG")(table(rt, slot=slot, name=name))


def toasts(rt):
    return [str(v) for v in rt.eval("toasts").values()]


def lines(rt):
    return [str(v) for v in rt.eval("lines").values()]


def warps(rt):
    return [list(w.values()) for w in rt.eval("warps").values()]


def sent(rt, kind=None):
    out = []
    for e in rt.eval("sent").values():
        if kind is None or e["kind"] == kind:
            out.append(e)
    return out


# ---------------------------------------------------------------- the decision

def test_with_the_mods_run_handed_over_the_returning_player_is_folded_in():
    rt = runtime()
    pending(rt)
    assert rt.eval("joinPending") is True
    assert toasts(rt) == ["DoctorPuppy is joining next floor..."]
    assert sent(rt, "joindefer") == []


def test_a_mod_that_cannot_hand_its_run_over_still_means_the_next_run():
    rt = runtime()
    rt.execute('supported, unsupportedWhy = false, "fyi.spelunky-25-2: its game was not found"')
    pending(rt)
    assert rt.eval("joinPending") is False
    [event] = sent(rt, "joindefer")
    assert [int(v) for v in event["payload"]["slots"].values()] == [2]
    assert event["payload"]["names"]["2"] == "DoctorPuppy"
    assert event["payload"]["why"] == ("Spelunky 2.5 can't hand its run over"
                                       " (fyi.spelunky-25-2: its game was not found)")


def test_only_the_world_host_says_so():
    rt = runtime(slot=3, host=1)
    rt.execute('supported = false')
    pending(rt)
    assert sent(rt) == [] and rt.eval("joinPending") is False


def test_without_a_hosted_mod_nothing_changes():
    rt = runtime()
    rt.execute("packs = {}; supported = false")
    pending(rt)
    assert rt.eval("joinPending") is True


def test_the_flag_file_folds_them_in_regardless():
    rt = runtime()
    rt.execute("module.midRunJoinAllowed = true; supported = false")
    pending(rt)
    assert rt.eval("joinPending") is True


def test_one_whose_fold_in_failed_waits_for_the_next_run_whatever_else():
    rt = runtime()
    rt.execute("module.midRunJoinAllowed = true; module.foldFailed[2] = true")
    pending(rt)
    assert rt.eval("joinPending") is False
    [event] = sent(rt, "joindefer")
    assert event["payload"]["why"] == "bringing them back already failed once this run"


def test_a_host_api_that_fails_is_a_reason_to_wait_not_an_error():
    rt = runtime()
    rt.execute("ModHost.runStateSupported = function() error('boom') end")
    pending(rt)
    assert rt.eval("joinPending") is False
    assert "boom" in sent(rt, "joindefer")[0]["payload"]["why"]


def test_the_player_coming_back_hears_nothing_until_the_host_decides():
    rt = runtime(slot=2, in_run=False)
    pending(rt)
    assert toasts(rt) == [] and sent(rt) == []


# ------------------------------------------------------- everyone hears why

def defer_payload(rt, why="Spelunky 2.5 can't hand its run over (x)"):
    names = rt.eval("{}")
    names["2"] = "DoctorPuppy"
    return table(rt, slots=lua_list(rt, [2]), names=names, why=why)


def test_the_returning_player_is_told_they_join_the_next_run():
    rt = runtime(slot=2, in_run=False)
    rt.eval("module.onJoinDefer")(defer_payload(rt))
    assert toasts(rt) == ["You'll join the next run: Spelunky 2.5 can't hand its run over (x)"]


def test_the_others_are_told_and_drop_the_fold_in():
    rt = runtime(slot=3, host=1)
    rt.execute("joinPending = true; module.joinWaiting[2] = 'DoctorPuppy'")
    rt.eval("module.onJoinDefer")(defer_payload(rt))
    assert rt.eval("joinPending") is False, "a later world host would fold them in after all"
    assert rt.eval("next(module.joinWaiting)") is None
    assert toasts(rt) == ["DoctorPuppy is back, and will join the next run:"
                          " Spelunky 2.5 can't hand its run over (x)"]
    assert any(line.startswith("rejoin DEFERRED: DoctorPuppy") for line in lines(rt))


def test_someone_in_the_camp_who_is_not_coming_back_hears_nothing():
    rt = runtime(slot=3, in_run=False)
    rt.eval("module.onJoinDefer")(defer_payload(rt))
    assert toasts(rt) == []


# ------------------------------------------------- at the transition, the host

def at_transition(rt):
    rt.execute("joinPending = true; module.joinWaiting[2] = 'DoctorPuppy'")
    rt.eval("pollJoinAtTransitionG")()


def test_the_host_says_it_will_send_the_mods_run_itself():
    rt = runtime()
    at_transition(rt)
    st = rt.eval("requested.st")
    assert st["flags"] is True, "the engine's snapshot, with the run flags a joiner needs"
    assert st["cap"] == 1, "the run comes from this machine's own load of the floor"
    assert st["mod"] is None, "not taken here: the mod has not read the transition yet"
    assert rt.eval("next(module.joinWaiting)") is None


def test_if_the_run_cannot_be_handed_over_the_player_waits():
    rt = runtime()
    rt.execute('supported, unsupportedWhy = false, "fyi.spelunky-25-2: it is too big to send"')
    at_transition(rt)
    assert rt.eval("requested") is None
    [event] = sent(rt, "joindefer")
    assert "too big to send" in event["payload"]["why"]


def test_with_the_flag_file_they_come_anyway_without_the_mods_run():
    rt = runtime()
    rt.execute("module.midRunJoinAllowed = true; supported = false")
    at_transition(rt)
    assert rt.eval("requested") is not None
    assert rt.eval("requested.st.cap") is None


def test_without_a_hosted_mod_the_fold_in_is_as_it_was():
    rt = runtime()
    rt.execute("packs = {}")
    at_transition(rt)
    assert rt.eval("requested.st.cap") is None


# ------------------------------------------------------------------ run_start

def join_start(rt, cap=1, join=(2,)):
    st = table(rt, meta=table(rt, lc=4), pl=rt.eval("{}"))
    if cap is not None:
        st["cap"] = cap
    payload = table(rt, slots=rt.eval("Network.playerNames"), seed=lua_list(rt, [1, 2]),
                    chars=rt.eval("{}"), delay=4, ord=5, st=st,
                    floor=table(rt, w=2, l=2, t=2), join=lua_list(rt, list(join)))
    rt.eval("onRunStartG")(payload)


def test_the_returning_player_waits_in_the_camp_for_the_run():
    rt = runtime(slot=2, host=1)
    join_start(rt)
    assert warps(rt) == [], "not before the host's own load has read its transition"
    assert toasts(rt) == ["Bringing you back into the run..."]
    wait = rt.eval("module.foldWait")
    assert wait["untilMs"] == 1000 + rt.eval("module.FOLD_WAIT_MS")
    fold = rt.eval("module.foldIn")
    assert [int(v) for v in fold["slots"].values()] == [2]
    assert fold["ord"] == 5 and fold["cap"] == 1 and fold["decided"] is False
    assert rt.eval("module.foldSendTail") is False


def test_the_host_that_took_the_snapshot_warps_and_will_send_the_run_from_its_load():
    rt = runtime(slot=1, host=1)
    join_start(rt)
    assert warps(rt) == [[2, 2, 2]]
    assert rt.eval("module.foldSendTail") is True and rt.eval("module.foldWait") is None


def test_everyone_else_warps_as_before():
    rt = runtime(slot=3, host=1)
    join_start(rt)
    assert warps(rt) == [[2, 2, 2]]
    assert toasts(rt) == ["A player is joining — resyncing this floor!"]
    assert rt.eval("module.foldSendTail") is False and rt.eval("module.foldWait") is None
    assert rt.eval("module.foldIn") is not None, "they judge the probation too"


def test_a_fold_in_with_no_run_coming_is_as_it_was():
    rt = runtime(slot=2, host=1)
    join_start(rt, cap=None)
    assert warps(rt) == [[2, 2, 2]]
    assert rt.eval("module.foldIn") is None and rt.eval("module.foldWait") is None


def test_a_fresh_run_start_forgets_a_fold_in():
    rt = runtime(slot=2, host=1)
    rt.execute("module.foldIn = {}; module.foldFailed[2] = true; module.foldWait = {};"
               " module.foldTail = {}; module.foldSendTail = true")
    payload = table(rt, slots=rt.eval("Network.playerNames"), seed=lua_list(rt, [1, 2]),
                    chars=rt.eval("{}"), delay=4)
    rt.eval("onRunStartG")(payload)
    assert rt.eval("module.foldIn") is None and rt.eval("module.foldWait") is None
    assert rt.eval("module.foldTail") is None and rt.eval("module.foldSendTail") is False
    assert rt.eval("next(module.foldFailed)") is None


# ------------------------------------------ the host's load: the run it sends

def test_the_host_sends_the_run_as_its_load_left_it_and_where_that_load_goes():
    rt = runtime(slot=1, host=1)
    join_start(rt)
    rt.execute("transition.world_next, transition.level_next, transition.theme_next = 5, 2, 14")
    rt.eval("module.onFoldTail")()
    [event] = sent(rt, "foldstate")
    payload = event["payload"]
    assert [int(v) for v in payload["slots"].values()] == [2] and payload["ord"] == 5
    assert (payload["dest"]["w"], payload["dest"]["l"], payload["dest"]["t"]) == (5, 2, 14)
    assert payload["mod"]["fyi.spelunky-25-2"] == "spelunky-2.5;t...e"
    assert rt.eval("flushes") == 1, "out now: the engine builds the floor next"
    rt.eval("module.onFoldTail")()
    assert len(sent(rt, "foldstate")) == 1, "once"


def test_a_run_that_cannot_be_taken_at_the_load_sends_them_back():
    rt = runtime(slot=1, host=1)
    join_start(rt)
    rt.execute('captured, captureWhy = nil, "fyi.spelunky-25-2: it is too big to send"')
    rt.eval("module.onFoldTail")()
    [event] = sent(rt, "foldfail")
    assert event["payload"]["why"] == "run"
    assert sent(rt, "foldstate") == [] and rt.eval("module.foldIn.decided") is True
    assert any("could not be taken at the load" in line for line in lines(rt))


def test_only_a_load_into_a_level_sends_it():
    rt = runtime(slot=1, host=1)
    join_start(rt)
    rt.execute("transition.screen_next = 13")
    rt.eval("module.onFoldTail")()
    assert sent(rt) == [] and rt.eval("module.foldSendTail") is True


# --------------------------------------------- the returning player takes it

def fold_state(rt, slots=(2,), dest=(5, 2, 14)):
    payload = table(rt, slots=lua_list(rt, list(slots)), ord=5, mod=rt.eval("captured"))
    if dest is not None:
        payload["dest"] = table(rt, w=dest[0], l=dest[1], t=dest[2])
    rt.eval("module.onFoldState")(payload)


def test_the_returning_player_takes_the_run_and_goes_where_the_hosts_load_went():
    rt = runtime(slot=2, host=1)
    join_start(rt)
    fold_state(rt)
    assert warps(rt) == [[5, 2, 14]], "the floor the host's own load is going to"
    assert rt.eval("module.foldWait") is None
    assert rt.eval("rawequal(module.pendingRunState, captured)") is True
    assert rt.eval("rawequal(module.foldTail, captured)") is True


def test_with_no_destination_they_go_to_the_floor_the_fold_in_named():
    rt = runtime(slot=2, host=1)
    join_start(rt)
    fold_state(rt, dest=None)
    assert warps(rt) == [[2, 2, 2]]


def test_a_run_for_someone_else_or_for_nobody_waiting_is_not_ours():
    rt = runtime(slot=2, host=1)
    join_start(rt)
    fold_state(rt, slots=(3,))
    assert warps(rt) == [] and rt.eval("module.pendingRunState") is None
    rt = runtime(slot=3, host=1)
    join_start(rt)
    fold_state(rt)
    assert warps(rt) == [[2, 2, 2]], "the warp they made at run_start, and no second one"


def test_at_the_tail_of_their_load_they_put_it_in_again():
    rt = runtime(slot=2, host=1)
    join_start(rt)
    fold_state(rt)
    rt.execute("module.pendingRunState = nil")  # the head of the load took it
    rt.eval("module.onFoldTail")()
    assert len(rt.eval("applied")) == 1 and rt.eval("module.foldTail") is None
    assert ("hosted run state from the world host (again, at the end of the load):"
            " fyi.spelunky-25-2: world 7, 63 run values, 1 carried custom item(s),"
            " 18 of its own") in lines(rt)
    assert sent(rt) == [], "it is not theirs to send"


def test_waiting_too_long_sends_them_back_to_the_camp():
    rt = runtime(slot=2, host=1)
    join_start(rt)
    rt.eval("module.pollFoldWait")()
    assert sent(rt) == []
    rt.execute("clock = clock + module.FOLD_WAIT_MS")
    rt.eval("module.pollFoldWait")()
    [event] = sent(rt, "foldfail")
    assert event["payload"]["why"] == "late"
    assert [int(v) for v in event["payload"]["slots"].values()] == [2]
    assert toasts(rt)[-1] == ("Couldn't bring you back into this run: the host's game did not"
                              " send the run in time. You'll join the next one.")
    assert str(rt.eval("clearedFor")) == "fold-in failed (late)"
    assert rt.eval("sessionEnded") is True and rt.eval("endedRun") is True
    assert warps(rt) == [[1, 1, 17]]
    assert rt.eval("module.foldWait") is None


def test_out_of_the_run_the_wait_is_simply_dropped():
    rt = runtime(slot=2, host=1)
    join_start(rt)
    rt.execute("runActive = false; clock = clock + module.FOLD_WAIT_MS")
    rt.eval("module.pollFoldWait")()
    assert sent(rt) == [] and rt.eval("module.foldWait") is None


# ---------------------------------------------------------------- probation

def on_probation(rt, slots=(2,), ord=4, floor_now=5):
    rt.execute(f"module.foldIn = {{ slots = {{ {', '.join(map(str, slots))} }}, ord = {ord},"
               f" decided = false }}; levelOrdinal = {floor_now}")


@pytest.mark.parametrize("problem", ["floor", "run", "positions"])
@pytest.mark.parametrize("floor_now", [5, 6])
def test_the_returning_player_finding_their_floor_different_fails_the_fold_in(problem, floor_now):
    rt = runtime(slot=2, host=1)
    on_probation(rt, floor_now=floor_now)
    rt.eval("module.foldVerdict")(problem)
    rt.eval("module.foldVerdict")(problem)
    [event] = sent(rt, "foldfail")
    assert [int(v) for v in event["payload"]["slots"].values()] == [2]
    assert event["payload"]["why"] == problem


def test_a_returning_world_host_is_found_out_by_the_others():
    rt = runtime(slot=3, host=2)
    on_probation(rt, slots=(2,))
    rt.eval("module.foldVerdict")("floor")
    assert len(sent(rt, "foldfail")) == 1


def test_two_players_who_were_there_all_along_disagreeing_is_not_the_fold_in():
    rt = runtime(slot=3, host=1)
    on_probation(rt, slots=(2,))
    rt.eval("module.foldVerdict")("floor")
    assert sent(rt) == []


def test_two_floors_on_the_probation_is_over():
    rt = runtime(slot=2, host=1)
    on_probation(rt, floor_now=7)
    rt.eval("module.foldVerdict")("positions")
    assert sent(rt) == [] and rt.eval("module.foldIn") is None


def test_a_clean_comparison_changes_nothing():
    rt = runtime(slot=2, host=1)
    on_probation(rt)
    rt.eval("module.foldVerdict")(None)
    assert sent(rt) == [] and rt.eval("module.foldIn") is not None


def test_a_failed_fold_in_sends_the_returning_player_back_to_the_camp():
    rt = runtime(slot=2, host=1)
    on_probation(rt)
    rt.eval("module.onFoldFail")(table(rt, slots=lua_list(rt, [2]), why="floor"))
    assert rt.eval("module.foldFailed[2]") is True
    assert toasts(rt) == ["Couldn't bring you back into this run: your floor came out different"
                          " from the host's. You'll join the next one."]
    assert str(rt.eval("clearedFor")) == "fold-in failed (floor)"
    assert rt.eval("sessionEnded") is True and rt.eval("endedRun") is True
    assert warps(rt) == [[1, 1, 17]]


def test_the_others_play_on_and_will_not_try_again_this_run():
    rt = runtime(slot=1, host=1)
    on_probation(rt)
    rt.eval("module.onFoldFail")(table(rt, slots=lua_list(rt, [2]), why="positions"))
    assert rt.eval("module.foldFailed[2]") is True and rt.eval("module.foldIn") is None
    assert toasts(rt) == ["DoctorPuppy couldn't be brought back into this run, and will join the"
                          " next one"]
    assert rt.eval("warps[1]") is None and rt.eval("runActive") is True


def test_the_same_failure_heard_twice_is_said_once():
    """A returning world host is found out by every other player at once."""
    rt = runtime(slot=1, host=2)
    on_probation(rt, slots=(2,))
    rt.eval("module.onFoldFail")(table(rt, slots=lua_list(rt, [2]), why="floor"))
    rt.eval("module.onFoldFail")(table(rt, slots=lua_list(rt, [2]), why="floor"))
    assert len(toasts(rt)) == 1
    assert len([line for line in lines(rt) if line.startswith("fold-in FAILED")]) == 1


def test_a_run_state_that_did_not_go_back_in_fails_the_returning_players_fold_in_at_once():
    rt = runtime(slot=2, host=1)
    on_probation(rt, floor_now=4)
    rt.execute('applyLines, applyOk = { "fyi.spelunky-25-2: NOT applied, its game was not found" }, false')
    rt.eval("module.applyHostedRunState")(rt.eval("captured"))
    assert ("hosted run state from the world host: fyi.spelunky-25-2: NOT applied, its game was"
            " not found") in lines(rt)
    [event] = sent(rt, "foldfail")
    assert event["payload"]["why"] == "run"


def test_one_that_went_back_in_is_logged_and_nothing_else():
    rt = runtime(slot=2, host=1)
    on_probation(rt, floor_now=4)
    rt.eval("module.applyHostedRunState")(rt.eval("captured"))
    assert sent(rt) == []
    assert ("hosted run state from the world host: fyi.spelunky-25-2: world 7, 63 run values,"
            " 1 carried custom item(s), 18 of its own") in lines(rt)


def test_the_mods_run_as_this_machine_has_it_is_logged_once_on_probation():
    rt = runtime(slot=2, host=1)
    on_probation(rt)
    rt.eval("module.logRunState")("it differs from the host's")
    rt.eval("module.logRunState")("it differs from the host's")
    said = [line for line in lines(rt) if "hosted run state here" in line]
    assert said == ["hosted run state here (it differs from the host's), fyi.spelunky-25-2:"
                    " spelunky-2.5;t...e"]


def test_off_probation_it_is_not_logged():
    rt = runtime(slot=2, host=1)
    rt.eval("module.logRunState")("it differs from the host's")
    assert lines(rt) == []


# ------------------------------------------------------------- wired in where

def test_only_the_returning_players_machine_puts_the_run_in_at_the_head_of_its_load():
    head = EVENT_SYNC.index('module.ordered(ON.PRE_LOAD_SCREEN, "eventSync:preLoadScreen"')
    assert EVENT_SYNC.index('SafeCall("eventSync:onPreLoadScreen", onPreLoadScreen)', head) > head
    body = extract("local function onPreLoadScreen()")
    assert body.index("applyStateSync()") < body.index("module.applyHostedRunState(states)")
    # pendingRunState is set in one place: a returning player taking the host's run
    assert EVENT_SYNC.count("module.pendingRunState = payload.mod") == 1
    assert "module.pendingRunState = pendingStateSync" not in EVENT_SYNC


def test_the_tail_comes_after_the_mods_own_load_callbacks():
    body = extract("function module.installRunResetWindow()")
    assert 'module.ordered(ON.PRE_LOAD_SCREEN, "eventSync:foldTail", function()' in body
    assert 'SafeCall("eventSync:foldTail", module.onFoldTail)\n    end, true)' in body


def test_the_wait_is_polled_every_gui_frame_and_the_run_is_heard():
    poll = EVENT_SYNC.index('SafeCall("eventSync:pollJoinAtTransition", pollJoinAtTransition)')
    assert EVENT_SYNC.index('SafeCall("eventSync:pollFoldWait", module.pollFoldWait)', poll) - poll < 120
    assert 'Network.onEvent("foldstate", module.onFoldState)' in EVENT_SYNC
    assert 'Network.onEvent("foldfail", module.onFoldFail)' in EVENT_SYNC
    assert 'Network.onEvent("joindefer", module.onJoinDefer)' in EVENT_SYNC


def test_the_floor_check_and_the_desync_alarm_report_to_the_probation():
    check = extract("function module.checkFloorDigest(s)", INPUT_SYNC)
    assert 'pcall(EventSync.foldVerdict, "floor")' in check
    assert 'pcall(EventSync.foldVerdict, runDiffers and "run" or nil)' in check
    assert 'pcall(EventSync.logRunState, "it differs from the host\'s")' in check
    assert 'pcall(EventSync.logRunState, "the floor differs from the host\'s")' in check
    assert 'pcall(EventSync.foldVerdict, "positions")' in INPUT_SYNC


def test_a_run_reset_flag_is_never_shown_on_a_fold_in_load():
    # 2.5 wipes its run on QUEST_FLAG.RESET; a fold-in load must not show it
    body = extract("function module.showRunReset()")
    assert "levelOrdinal ~= 0" in body


# ------------------------------------------------------- the event goes out now

FLUSH_ENV = """
module = {}
RESEND_MS = 250
clock = 1000
function nowMs() return clock end
wire = {}
function sendToServer(msg) wire[#wire + 1] = msg.cseq end
pendingOut = {}
"""


def flush_runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(FLUSH_ENV)
    rt.execute(extract("function module.flushEvents(now)", NET_CORE))
    return rt


def test_flushing_sends_what_is_due_in_ascending_order():
    rt = flush_runtime()
    rt.execute("for _, c in ipairs({ 9, 3, 7 }) do pendingOut[c] = { msg = { cseq = c }, sentAt = 0 } end"
               "; pendingOut[5] = { msg = { cseq = 5 }, sentAt = 900 }")
    rt.eval("module.flushEvents")()
    assert list(rt.eval("wire").values()) == [3, 7, 9], "5 went out 100 ms ago"
    rt.execute("clock = 1150")
    rt.eval("module.flushEvents")()
    assert list(rt.eval("wire").values()) == [3, 7, 9, 5]


def test_the_gui_frame_tick_flushes_the_same_way():
    tick = NET_CORE[NET_CORE.index("local function tick()"):]
    assert "module.flushEvents(now)" in tick[:tick.index("\nend\n")]
