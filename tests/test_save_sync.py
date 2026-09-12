"""Tests the host-authoritative sync of save-derived generation state.

Mods branch on the LOCAL player's save. The HD mod reads `savegame.shortcuts` to
decide whether Mama Tunnel appears at a world transition, and `savegame.characters`
to pick a per-floor character unlock (which draws from the level-generation PRNG).
Two players with different progress therefore build different worlds from the same
seed. A capture desynced at the 1-4 -> 2-1 transition for exactly this reason: 34
lockstep stalls, a resync warp, and a position desync on the floor after.

The dangerous part is not the sync, it is the restore. `savegame` is what the game
serialises into savegame.sav, so an override left standing is one that can write the
HOST's progress into a PEER's save file. Every test here is ultimately about that:
the override is held across a load and released the moment the screen settles, and
there is a watchdog behind it in case the screen never does.

Run:  python -m pytest tests/test_save_sync.py -q
"""

from __future__ import annotations

import pathlib
import re

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
EVENT_SYNC = (PACK / "src" / "eventSync.lua").read_text(encoding="utf-8")
NL = chr(10)


def _block():
    """The save-sync section, lifted out of eventSync so it can run standalone."""
    start = EVENT_SYNC.index("local SAVE_SYNC_FIELDS")
    # forgetSaveSync is the LAST function in the section, so slicing to the end of
    # it takes releaseSaveSync along with it. Extending this marker is the price of
    # adding anything below it -- which is deliberate: a mechanism outside the slice
    # is a mechanism with no tests.
    marker = "function module.forgetSaveSync()"
    end = EVENT_SYNC.index(NL + "end" + NL, EVENT_SYNC.index(marker)) + len(NL + "end" + NL)
    # The exports MUST be part of the same chunk: these are `local function`s,
    # and a separate lua execute() cannot see another chunk's locals.
    return (EVENT_SYNC[start:end] + NL
            + "hold = holdSaveSync" + NL
            + "poll = pollSaveSync" + NL
            + "onSync = onSaveSync" + NL)


ENV = """
nowValue = 0
loadingValue = 0
FADE = {NONE = 0}
sent = {}
hostSlot = 1
isHostValue = false

savegame = {shortcuts = 0, characters = 0}
function get_ms() return nowValue end
function get_local_state() return {loading = loadingValue} end
function petHostSlot() return hostSlot end
module = {}
Network = {
    isActive = function() return true end,
    isHost = function() return isHostValue end,
    sendEvent = function(tag, payload) sent[#sent + 1] = {tag = tag, p = payload} end,
}
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(_block())
    return rt


def peer_holding(rt, mine_shortcuts=1, host_shortcuts=7):
    """A non-host that has adopted the host's values and is mid-load."""
    rt.execute("savegame.shortcuts = %d" % mine_shortcuts)
    rt.execute("onSync({shortcuts = %d}, 1)" % host_shortcuts)
    rt.execute("loadingValue = 2")  # a load is in flight
    rt.execute("hold()")
    return rt


def test_a_peer_adopts_the_hosts_value_for_the_load():
    rt = peer_holding(runtime(), mine_shortcuts=1, host_shortcuts=7)
    assert int(rt.eval("savegame.shortcuts")) == 7, (
        "the peer did not adopt the host's shortcut progress, so Mama Tunnel "
        "appears for one machine and not the other")


def test_the_peers_own_value_comes_back_when_the_screen_settles():
    rt = peer_holding(runtime(), mine_shortcuts=1, host_shortcuts=7)
    rt.execute("loadingValue = FADE.NONE; poll()")
    assert int(rt.eval("savegame.shortcuts")) == 1, (
        "the host's progress was left standing in a peer's savegame -- the next "
        "time the game saves, it writes the host's unlocks into their file")


def test_the_watchdog_releases_a_load_that_never_finishes():
    """"Released when the screen settles" is only true if the screen ever settles."""
    rt = peer_holding(runtime(), mine_shortcuts=1, host_shortcuts=7)
    rt.execute("loadingValue = 2; nowValue = 4000; poll()")
    assert int(rt.eval("savegame.shortcuts")) == 7, "released too early"
    rt.execute("nowValue = 6000; poll()")
    assert int(rt.eval("savegame.shortcuts")) == 1, (
        "an override survived a load that never completed")


def test_the_host_never_overrides_itself():
    rt = runtime()
    rt.execute("isHostValue = true; savegame.shortcuts = 3")
    rt.execute("onSync({shortcuts = 9}, 1); hold()")
    assert int(rt.eval("savegame.shortcuts")) == 3


def test_only_the_room_host_is_authoritative():
    rt = runtime()
    rt.execute("savegame.shortcuts = 3")
    rt.execute("onSync({shortcuts = 9}, 4)")  # slot 4 is not the host
    rt.execute("loadingValue = 2; hold()")
    assert int(rt.eval("savegame.shortcuts")) == 3


def test_holding_twice_cannot_lose_the_players_own_value():
    """The second hold must not record the HOST's value as 'mine'. That is the bug
    that silently converts an override into a permanent overwrite."""
    rt = peer_holding(runtime(), mine_shortcuts=1, host_shortcuts=7)
    rt.execute("hold()")
    rt.execute("loadingValue = FADE.NONE; poll()")
    assert int(rt.eval("savegame.shortcuts")) == 1


def test_every_synced_field_is_restored_not_just_the_first():
    rt = runtime()
    rt.execute("savegame.shortcuts = 1; savegame.characters = 5")
    rt.execute("onSync({shortcuts = 7, characters = 99}, 1)")
    rt.execute("loadingValue = 2; hold()")
    assert (int(rt.eval("savegame.shortcuts")), int(rt.eval("savegame.characters"))) == (7, 99)
    rt.execute("loadingValue = FADE.NONE; poll()")
    assert (int(rt.eval("savegame.shortcuts")), int(rt.eval("savegame.characters"))) == (1, 5)


def test_a_matching_value_is_never_written_at_all():
    """Nothing to restore means nothing that can go wrong."""
    rt = runtime()
    rt.execute("savegame.shortcuts = 7")
    rt.execute("onSync({shortcuts = 7}, 1); loadingValue = 2; hold()")
    rt.execute("loadingValue = FADE.NONE; poll()")
    assert int(rt.eval("savegame.shortcuts")) == 7


def test_the_host_broadcasts_its_values():
    rt = runtime()
    rt.execute("isHostValue = true; savegame.shortcuts = 4; savegame.characters = 8")
    rt.execute("nowValue = 10000; poll()")
    assert int(rt.eval("#sent")) == 1
    assert rt.eval("sent[1].tag") == "savesync"
    assert int(rt.eval("sent[1].p.shortcuts")) == 4


def test_the_hold_is_wired_above_the_screen_next_check():
    """A Mama Tunnel encounter is a SCREEN.TRANSITION. onPreLoadScreen returns early
    unless the next screen is a LEVEL, so a hold placed below that line would never
    run for the one screen this exists for."""
    at = EVENT_SYNC.index("local function onPreLoadScreen()")
    body = EVENT_SYNC[at:at + 900]
    assert body.index("holdSaveSync()") < body.index("screen_next ~= SCREEN.LEVEL")


def test_the_release_runs_every_frame_not_only_on_a_hook():
    assert 'SafeCall("eventSync:pollSaveSync", pollSaveSync)' in EVENT_SYNC
    assert "module.releaseSaveSync()" in _block()


def test_the_hosts_values_are_forgotten_when_the_run_ends():
    """Releasing gives this player their own values back. It does NOT answer the
    other question -- whose values were being held -- and leaving that standing
    meant the FIRST load of the next run, in a different room, held the player to
    the progression of somebody they are no longer playing with."""
    rt = peer_holding(rt=runtime(), mine_shortcuts=1, host_shortcuts=7)
    rt.execute("module.releaseSaveSync()")
    rt.execute("module.forgetSaveSync()")
    # a fresh load, with no host having broadcast anything yet
    rt.execute("loadingValue = 2")
    rt.execute("hold()")
    assert rt.globals().savegame.shortcuts == 1


def test_forgetting_without_releasing_still_gives_the_value_back():
    """The two are called together and in that order, but a teardown path that
    only forgot would strand the override with nothing left to restore it from."""
    rt = peer_holding(rt=runtime(), mine_shortcuts=3, host_shortcuts=9)
    assert rt.globals().savegame.shortcuts == 9
    rt.execute("module.forgetSaveSync()")
    rt.execute("module.releaseSaveSync()")
    assert rt.globals().savegame.shortcuts == 3


def test_clear_run_state_both_releases_and_forgets():
    """Wired in eventSync itself, where the test harness cannot reach: both calls
    have to be on the teardown path or neither mechanism above matters."""
    teardown = EVENT_SYNC[EVENT_SYNC.index("local function clearRunState"):]
    teardown = teardown[:teardown.index(NL + "end" + NL)]
    assert "releaseSaveSync()" in teardown
    assert "forgetSaveSync()" in teardown
