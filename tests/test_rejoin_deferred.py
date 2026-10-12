"""A player coming back while a hosted mod runs joins the next run, not this one.

Folding a player back into a run under way rebuilds the party at the next floor from
the host's snapshot of the ENGINE's state. A hosted content mod keeps the run's
history in its own memory, and a game that rejoins mid-run has none of it -- least
of all one just restarted after a crash. Room QZUX: the rejoiner built a different
1-4 from the same seed at once, and the run desynced six seconds later. So with a
hosted mod the run host no longer asks for the fold-in: the returning player waits
in the camp and comes in with the next run (the path the server already takes for a
join no transition picked up). Without a hosted mod nothing changes, and
`mo_midrunjoin.on` in the pack folder folds them in anyway.

Run:  python -m pytest tests/test_rejoin_deferred.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8").replace("\r\n", "\n")


def extract(start: str) -> str:
    i = EVENT_SYNC.index(start)
    return EVENT_SYNC[i:EVENT_SYNC.index("\nend\n", i) + len("\nend\n")]


ENV = """
module = {}
runActive, joinPending = true, false
toasts, lines = {}, {}
function toast(t) toasts[#toasts + 1] = t end
DesyncLog = { event = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end }
Network = { slot = 1, isInRun = function() return runActive end }
ModHost = { hostedPacks = function() return { "fyi.spelunky-25-2" } end }
InputSync = { hostedModName = function() return "Spelunky 2.5" end }
function PackPath(rest) return "no/such/folder/" .. rest end
"""


def runtime(hosted=True, allowed=False, in_run=True, slot=1):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    if not hosted:
        rt.execute("ModHost = { hostedPacks = function() return {} end }")
    start = EVENT_SYNC.index("--- Folding a player back into a run under way")
    end = EVENT_SYNC.index("\nend\n", EVENT_SYNC.index("function module.hostedModName()")) + len("\nend\n")
    rt.execute(EVENT_SYNC[start:end])
    if allowed:
        rt.execute("module.midRunJoinAllowed = true")
    rt.execute(extract("local function onJoinPending(payload)") + "onJoinPendingG = onJoinPending\n")
    rt.execute(f"runActive = {str(in_run).lower()}; Network.slot = {slot}")
    return rt


def pending(rt, slot=2, name="DoctorPuppy"):
    payload = rt.eval("{}")
    payload["slot"] = slot
    payload["name"] = name
    rt.eval("onJoinPendingG")(payload)


def toasts(rt):
    return [str(v) for v in rt.eval("toasts").values()]


def test_with_a_hosted_mod_the_run_host_does_not_fold_them_in():
    rt = runtime()
    pending(rt)
    assert rt.eval("joinPending") is False
    assert toasts(rt) == ["DoctorPuppy is back, and will join the next run: Spelunky 2.5 can't take"
                          " a player back mid-run"]
    said = [str(v) for v in rt.eval("lines").values()]
    assert len(said) == 1 and said[0].startswith("rejoin DEFERRED: DoctorPuppy (slot 2) waits for the next run")


def test_the_player_coming_back_is_told_too():
    rt = runtime(in_run=False, slot=2)
    pending(rt, slot=2)
    assert toasts(rt) == ["You'll join the next run: Spelunky 2.5 can't take a player back into a run"
                          " already under way"]


def test_someone_else_in_the_camp_hears_nothing():
    rt = runtime(in_run=False, slot=3)
    pending(rt, slot=2)
    assert toasts(rt) == []


def test_without_a_hosted_mod_they_are_folded_in_as_before():
    rt = runtime(hosted=False)
    pending(rt)
    assert rt.eval("joinPending") is True
    assert toasts(rt) == ["DoctorPuppy is joining next floor..."]


def test_the_flag_file_folds_them_in_anyway():
    rt = runtime(allowed=True)
    pending(rt)
    assert rt.eval("joinPending") is True


def test_the_flag_file_is_read_from_the_pack_folder(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "pack").mkdir()
    (tmp_path / "pack" / "mo_midrunjoin.on").write_text("", encoding="utf-8")
    rt = runtime()
    rt.execute('function PackPath(rest) return "pack/" .. rest end')
    start = EVENT_SYNC.index("module.midRunJoinAllowed = false")
    rt.execute(EVENT_SYNC[start:EVENT_SYNC.index("\nend)\n", start) + len("\nend)\n")])
    assert rt.eval("module.midRunJoinAllowed") is True


def test_a_host_api_that_fails_is_no_reason_to_hold_them_back():
    rt = runtime()
    rt.execute("ModHost = { hostedPacks = function() error('boom') end }")
    pending(rt)
    assert rt.eval("joinPending") is True


def test_the_fold_in_itself_still_needs_joinpending():
    src = extract("local function pollJoinAtTransition()")
    assert "if not joinPending or not runActive or not Network.isInRun() then" in src
