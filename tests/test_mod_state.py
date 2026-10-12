"""Every player is told at 1-1 when the hosted mod is not in the same state on each machine.

Room PTHP desynced on 1-2: the two machines generated different floors from the same
seed, one with a turkey back room the other did not have. The logs showed why on the
very first floor. Spelunky 2.5 keeps some of its ON.LEVEL hooks from earlier play
(entityContext.lua:1381 -- 0 when the game starts, 6 by 1-4, carried into every later
run), and the host had been playing for longer: 64 hosted ON.LEVEL callbacks there, 38
on the peer, 32 of that one kind against 6. The ON.LEVEL ORDER line said DIFFERENT at
seq 1, and nobody saw it until the desync.

Nothing within a run brings two such games back together; restarting Spelunky 2 on
every machine does. So the first floor both machines report is judged once a run, and
when the hosted mods' callbacks differ, everyone gets a toast saying so, and why, and
the log names the hooks that differ (dev84).

Run:  python -m pytest tests/test_mod_state.py -q
"""

from __future__ import annotations

import pathlib
import re

import test_level_order as lo
import test_water_probe as wp

PACK = pathlib.Path(__file__).resolve().parent.parent
INPUT_SYNC = (PACK / "src" / "inputSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")

STUBS = """
module = module or {}
said, toasts, sent, events = {}, {}, {}, {}
function errorf(fmt, ...) said[#said + 1] = string.format(fmt, ...) end
function toast(text) toasts[#toasts + 1] = text end
modStateJudged, modStateWarned = false, false
myFloorDigest, hostFloorDigests = nil, {}
Network = {
    slot = %d,
    isInRun = function() return true end,
    isWorldHost = function() return Network.slot == 1 end,
    hostSlot = function() return 1 end,
    sendEvent = function(kind, payload) sent[#sent + 1] = { kind = kind, payload = payload } end,
}
DesyncLog = { event = function(fmt, ...) events[#events + 1] = string.format(fmt, ...) end }
ModHost = {
    hostedPacks = function() return { "fyi.spelunky-25-2" } end,
    envs = { ["fyi.spelunky-25-2"] = { meta = { name = "Spelunky 2.5" } } },
}
"""

# the warning and what calls it, in one chunk: hostedModName is a local of the file
WARNING = "".join(wp.extract(start) for start in (
    "function module.checkWaterProbe(s)",
    "local function hostedModName()",
    "function module.warnModState(",
    "function module.judgeModState(",
    "local function onModState(",
)) + "onModStateG = onModState\n"


def machine(slot):
    rt = lo.machine(salt=7919 if slot != 1 else 0)
    rt.execute(STUBS % slot)
    rt.execute(WARNING)
    return rt


def play_until(rt, leftovers, fresh=32):
    """2.5 as room PTHP had it: `leftovers` hooks of one kind kept from earlier play,
    then the 32 its helpers install for the floor. Then the floor itself."""
    rt.execute(f"""
        local keep = load("return function() return function() end end",
            "@Mods/Packs/fyi.spelunky-25-2/entityContext.lua", "t", env)()
        local install = load("return function() return function() end end",
            "@Mods/Packs/fyi.spelunky-25-2/helpers2.lua", "t", env)()
        for i = 1, {leftovers} do env.set_callback(keep(), ON.LEVEL) end
        for i = 1, {fresh} do env.set_callback(install(), ON.LEVEL) end
        floor()
    """)
    return rt.eval("Determinism.waterReport()")


def compare(peer, peer_report, host_report, s=1):
    """The peer's floor `s` against the host's, as checkWaterProbe sees them."""
    peer.eval("function(w, s) myFloorDigest = { seq = s, water = w } end")(peer_report["wire"], s)
    peer.eval("function(w, s) hostFloorDigests[s] = { water = w } end")(
        wp.crossed(peer, host_report["wire"]), s)
    peer.eval("module.checkWaterProbe")(s)


def deliver(sender, receiver):
    for e in sender.eval("sent").values():
        if str(e["kind"]) == "modstate":
            receiver.eval("onModStateG")(wp.crossed(receiver, e["payload"]),
                                         int(sender.eval("Network.slot")))


def said(rt):
    return [str(v) for v in rt.eval("said").values()]


def toasts(rt):
    return [str(v) for v in rt.eval("toasts").values()]


def lines(rt):
    return [str(v) for v in rt.eval("events").values()]


# ------------------------------------------------------------ what a floor reports

def test_a_floor_counts_its_callbacks_by_where_they_come_from():
    report = play_until(machine(1), leftovers=32)
    wire = report["wire"]
    assert int(wire["oc"]) == 64
    census = list(wire["og"].values())
    assert census == ["entityContext.lua:1", 32, "helpers2.lua:1", 32], census


def test_the_order_line_reads_as_runs():
    """64 names in a row were one line of 2.5's, twice over."""
    report = play_until(machine(1), leftovers=32)
    line = list(report["lines"].values())[-1]
    assert re.fullmatch(r"level order: 64 hosted ON\.LEVEL callback\(s\) #[0-9A-F]{8}: "
                        r"entityContext\.lua:1 x32 helpers2\.lua:1 x32", line), line


def test_the_verdict_names_the_hooks_that_differ():
    host, peer = machine(1), machine(2)
    host_report, peer_report = play_until(host, 32), play_until(peer, 6)
    compare(peer, peer_report, host_report)
    order = [l for l in lines(peer) if l.startswith("ON.LEVEL ORDER")]
    assert order == ["ON.LEVEL ORDER seq=1: DIFFERENT -- 38 hosted ON.LEVEL callback(s) here,"
                     " 64 on the host (entityContext.lua:1: 6 here, 32 on the host). The mods"
                     " registered them differently; compare the two logs' 'level order' lines"]


def test_the_same_hooks_in_another_order_is_said_as_such():
    host, peer = machine(1), machine(2)
    host.execute("""
        for _, name in ipairs({ "a", "b" }) do
            env.set_callback(load("return function() end", "@" .. name .. ".lua", "t", env)(), ON.LEVEL)
        end
        floor()
    """)
    peer.execute("""
        for _, name in ipairs({ "b", "a" }) do
            env.set_callback(load("return function() end", "@" .. name .. ".lua", "t", env)(), ON.LEVEL)
        end
        floor()
    """)
    compare(peer, peer.eval("Determinism.waterReport()"), host.eval("Determinism.waterReport()"))
    order = [l for l in lines(peer) if l.startswith("ON.LEVEL ORDER")]
    assert len(order) == 1
    assert "2 hosted ON.LEVEL callback(s) here, 2 on the host: the same callbacks, registered" \
        " in a different order." in order[0], order


def many_places(rt, counts):
    """ON.LEVEL callbacks from places p1.lua, p2.lua, ...: counts[i] from place i+1."""
    for i, n in enumerate(counts, start=1):
        rt.execute(f"""
            local make = load("return function() return function() end end", "@p{i}.lua", "t", env)()
            for _ = 1, {n} do env.set_callback(make(), ON.LEVEL) end
        """)
    rt.execute("floor()")
    return rt.eval("Determinism.waterReport()")


def test_past_ten_places_the_rest_are_counted_together():
    report = many_places(machine(1), [12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
    census = list(report["wire"]["og"].values())
    assert census[:2] == ["p1.lua:1", 12] and census[18:20] == ["p10.lua:1", 3]
    assert census[20:] == ["", 3], "p11's 2 and p12's 1"


def test_a_place_a_census_left_out_is_not_called_missing():
    host, peer = machine(1), machine(2)
    host_report = many_places(host, [12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
    peer_report = many_places(peer, [12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 1, 1])
    compare(peer, peer_report, host_report)
    order = [l for l in lines(peer) if l.startswith("ON.LEVEL ORDER")]
    assert len(order) == 1
    assert "77 hosted ON.LEVEL callback(s) here, 78 on the host, not in the same order." in order[0]


def test_the_same_places_and_a_different_total_is_not_called_the_same_callbacks():
    """Only the census's places agree: the difference is among the ones it left out."""
    peer = machine(2)
    mine = peer.table_from({"oc": 70, "oh": 1, "og": peer.table_from(["a.lua:1", 60, "", 10])})
    host = peer.table_from({"oc": 71, "oh": 2, "og": peer.table_from(["a.lua:1", 60, "", 11])})
    line = peer.eval("Determinism.levelOrderVerdict")(mine, host, 1)
    assert "70 hosted ON.LEVEL callback(s) here, 71 on the host, not in the same order." in line, line


def test_the_order_line_stops_at_sixty_four_names():
    report = many_places(machine(1), [1] * 70)
    line = list(report["lines"].values())[-1]
    assert line.endswith(" p64.lua:1 (+6 more)"), line[-60:]


def test_a_long_name_is_cut_short_between_characters():
    peer = machine(2)
    peer.execute('ModHost.envs["fyi.spelunky-25-2"].meta.name = string.rep("a", 31) .. "é" .. "tail"')
    peer.eval("module.warnModState")("here", "on the host", 1, 38, 64, None)
    toast = toasts(peer)[0]
    assert toast.startswith("Desync likely: " + "a" * 31 + " differs between your games"), toast


def test_a_host_report_without_a_census_still_reads_as_before():
    peer = machine(2)
    mine = peer.table_from({"oc": 38, "oh": 1, "og": peer.table_from(["entityContext.lua:1", 6])})
    host = peer.table_from({"oc": 64, "oh": 2})
    line = peer.eval("Determinism.levelOrderVerdict")(mine, host, 1)
    assert line.startswith("ON.LEVEL ORDER seq=1: DIFFERENT -- 38 hosted ON.LEVEL callback(s) here,"
                           " 64 on the host, not in the same order."), line


def test_a_match_is_judged_the_same_and_says_nothing():
    host, peer = machine(1), machine(2)
    host_report, peer_report = play_until(host, 6), play_until(peer, 6)
    judged = peer.eval("Determinism.levelOrderJudged")(peer_report["wire"],
                                                         wp.crossed(peer, host_report["wire"]))
    assert judged["same"] is True
    compare(peer, peer_report, host_report)
    assert said(peer) == [] and toasts(peer) == [] and list(peer.eval("sent").values()) == []


# ------------------------------------------------------------- what everyone is told

def test_room_pthp_is_told_at_1_1():
    host, peer = machine(1), machine(2)
    host_report, peer_report = play_until(host, 32), play_until(peer, 6)
    compare(peer, peer_report, host_report)
    assert toasts(peer) == ["Desync likely: Spelunky 2.5 differs between your games — restart"
                            " Spelunky 2 on every machine, then start a new run"]
    assert said(peer) == [
        "HOSTED MOD STATE DIFFERS at seq 1, the first floor compared this run: 38 hosted ON.LEVEL"
        " callback(s) here, 64 on the host (entityContext.lua:1: 6 here, 32 on the host)."
        " Spelunky 2.5 is not in the same state on every machine -- it keeps things from earlier"
        " play, or its settings differ -- so this run is likely to desync. Restart Spelunky 2 on"
        " every machine, then start a new run together"]
    deliver(peer, host)
    assert toasts(host) == toasts(peer)
    assert said(host) == [
        "HOSTED MOD STATE DIFFERS at seq 1, the first floor compared this run: 38 hosted ON.LEVEL"
        " callback(s) on slot 2, 64 here (entityContext.lua:1: 6 on slot 2, 32 here)."
        " Spelunky 2.5 is not in the same state on every machine -- it keeps things from earlier"
        " play, or its settings differ -- so this run is likely to desync. Restart Spelunky 2 on"
        " every machine, then start a new run together"]


def test_a_third_player_hears_it_from_the_one_who_found_it():
    peer, other = machine(2), machine(3)
    peer.eval("module.judgeModState")(1, peer.table_from(
        {"same": False, "here": 38, "host": 64,
         "diff": peer.table_from([peer.table_from({"w": "entityContext.lua:1", "m": 6, "h": 32})])}))
    deliver(peer, other)
    assert "38 hosted ON.LEVEL callback(s) on slot 2, 64 on the host" \
           " (entityContext.lua:1: 6 on slot 2, 32 on the host)" in said(other)[0]


def test_it_is_said_once_a_run():
    host, peer = machine(1), machine(2)
    compare(peer, play_until(peer, 6), play_until(host, 32), s=1)
    compare(peer, play_until(peer, 0, fresh=1), play_until(host, 0, fresh=2), s=3)
    assert len(toasts(peer)) == 1 and len(said(peer)) == 1
    assert len([e for e in peer.eval("sent").values() if str(e["kind"]) == "modstate"]) == 1
    deliver(peer, host)
    deliver(peer, host)  # every machine's report, and a resend
    assert len(toasts(host)) == 1


def test_a_first_floor_that_matches_is_the_runs_answer():
    """A later floor that differs is a desync of its own, which the floor digest and
    the position checksum already say; it is not the mod's state from before the run."""
    host, peer = machine(1), machine(2)
    compare(peer, play_until(peer, 6), play_until(host, 6), s=1)
    compare(peer, play_until(peer, 0, fresh=1), play_until(host, 0, fresh=2), s=3)
    assert toasts(peer) == [] and said(peer) == []
    assert any(l.startswith("ON.LEVEL ORDER seq=3: DIFFERENT") for l in lines(peer))


def test_our_own_report_coming_back_is_not_said_again():
    peer = machine(2)
    peer.eval("module.warnModState")("here", "on the host", 1, 38, 64, None)
    peer.execute("modStateWarned = false")
    peer.eval("onModStateG")(peer.table_from({"s": 1, "m": 38, "h": 64}), 2)
    assert len(toasts(peer)) == 1


def test_a_report_that_outlived_its_run_is_not_said():
    host = machine(1)
    host.execute("Network.isInRun = function() return false end")
    host.eval("onModStateG")(host.table_from({"s": 1, "m": 38, "h": 64}), 2)
    assert toasts(host) == [] and said(host) == []


def test_a_report_with_nothing_usable_in_it_still_reads():
    host = machine(1)
    host.eval("onModStateG")(host.table_from({"d": host.table_from(["x", "y"])}), 2)
    assert said(host)[0].startswith("HOSTED MOD STATE DIFFERS at seq nil, the first floor compared"
                                    " this run: 0 hosted ON.LEVEL callback(s) on slot 2, 0 here.")


def test_without_a_name_for_the_mod_it_is_still_said():
    peer = machine(2)
    peer.execute("ModHost = nil")
    peer.eval("module.warnModState")("here", "on the host", 1, 38, 64, None)
    assert toasts(peer) == ["Desync likely: A hosted mod differs between your games — restart"
                            " Spelunky 2 on every machine, then start a new run"]


def test_the_host_never_judges_itself():
    host = machine(1)
    host.execute("Network.isWorldHost = function() return true end")
    compare(host, play_until(host, 32), play_until(machine(1), 6))
    assert toasts(host) == []


# -------------------------------------------------------------- when it is judged

def _body(start: str) -> str:
    i = INPUT_SYNC.index(start)
    return INPUT_SYNC[i:INPUT_SYNC.index("\nend\n", i)]


def test_every_run_is_judged_afresh_and_a_resync_is_not_a_new_run():
    begin = _body("function module.beginSession(slots, delay)")
    assert "\n    modStateJudged = false\n" in begin and "\n    modStateWarned = false\n" in begin
    rebase = _body("function module.rebase(newSeq)")
    assert "modState" not in rebase


def test_the_room_hears_it_through_the_event():
    assert 'Network.onEvent("modstate", onModState)' in INPUT_SYNC
    probe = _body("function module.checkWaterProbe(s)")
    assert "module.judgeModState(s, judged)" in probe
