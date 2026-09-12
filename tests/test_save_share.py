"""Tests sharing the hosted mod's save data across a room.

While you are in a room everyone plays on the ROOM HOST's save, so a mod that
branches on its own progression cannot build a different world on each machine.

The dangerous half is not the sharing, it is the giving back. These files are a
player's progression, and the failure mode is somebody else's sitting permanently
in their save. So: the peer's own copies are set aside first, the swap is abandoned
if that cannot be done, the originals come back byte-for-byte on leaving, and they
come back at load too in case the last session ended in a crash while borrowing.

Everything here runs against an in-memory filesystem. Nothing touches disk.

Run:  python -m pytest tests/test_save_share.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
SAVE_SHARE = (PACK / "src" / "saveShare.lua").read_text(encoding="utf-8")

ENV = """
FS = {}          -- path -> contents
BLOCKED = {}     -- paths that refuse to open for writing
sent = {}
events = {}
isHostValue = false
activeValue = true

io = {
    open = function(path, mode)
        if mode == "rb" or mode == "r" then
            local data = FS[path]
            if data == nil then return nil end
            return {
                read = function(_self, _fmt) return data end,
                close = function() end,
            }
        end
        if BLOCKED[path] then return nil end
        local buf = {}
        return {
            write = function(_self, s) buf[#buf + 1] = s end,
            close = function() FS[path] = table.concat(buf) end,
        }
    end,
}
os = { remove = function(p) FS[p] = nil end }

ON = { GUIFRAME = 4 }
function set_callback(_fn, _kind) end
function SafeCall(_name, fn, ...) return fn(...) end
function PackPath(rest) return "PACK/" .. rest end
-- Chunks are built in a second runtime (the host's) and fed into this one.
-- They travel as plain values: lupa refuses to mix tables across runtimes.
function feed(slot, g, f, c, i, n, d)
    SaveShare.onSaveData({ g = g, f = f, c = c, i = i, n = n, d = d }, slot)
end
DesyncLog = { event = function() end }
savegame = {
    shortcuts = 1, characters = 2, players = 3, tutorial_state = 4,
    deepest_area = 5, seeded_unlocked = false,
}
reloaded = {}
ModHost = {
    requestedPacks = function() return { "fyi.hdmod" } end,
    reloadSaveData = function(text) reloaded[#reloaded + 1] = text return 1 end,
}
Network = {
    isActive = function() return activeValue end,
    isHost = function() return isHostValue end,
    hostSlot = function() return 1 end,
    lobbyPlayers = {},
    sendEvent = function(k, p) sent[#sent + 1] = { k = k, p = p } end,
    onEvent = function(k, fn) events[k] = fn end,
}
"""


def runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(SAVE_SHARE)
    return rt


def fs_put(rt, path, data):
    rt.globals()["FS"][path] = data


def fs_get(rt, path):
    return rt.globals()["FS"][path]


def drain(rt, frames=400):
    """publish() only QUEUES; poll() is what puts chunks on the wire."""
    for _ in range(frames):
        rt.eval("SaveShare.poll")()


# --------------------------------------------------------------------- base64


BINARY = bytes(range(256)).decode("latin-1")


@pytest.mark.parametrize("payload", [
    "",
    "a",
    "ab",
    "abc",
    "abcd",
    BINARY,
    BINARY * 3,
])
def test_base64_round_trips_arbitrary_bytes(payload):
    """save.dat and savegame.sav are binary, and the wire is JSON. Every byte value
    and every length modulo 3 has to survive."""
    rt = runtime()
    rt.execute("""
function roundTrip(s)
    FS["PACK/save.dat"] = s
    FS["PACK/savegame.sav"] = nil
    isHostValue = true
    SaveShare.publish()
    for _ = 1, 400 do SaveShare.poll() end
    local text = {}
    for i = 1, #sent do
        if sent[i].k == "savedata" then text[#text + 1] = sent[i].p.d end
    end
    sent = {}
    isHostValue = false
    -- feed them straight back in
    local total = 0
    for _ in pairs(text) do total = total + 1 end
    for i = 1, total do
        SaveShare.onSaveData({ g = 1, f = "save.dat", c = 1, i = i, n = total,
                               d = text[i] }, 1)
    end
    return FS["PACK/save.dat"]
end
""")
    if payload == "":
        # nothing to publish; the module correctly sends nothing at all
        rt.globals()["FS"]["PACK/save.dat"] = payload
        rt.globals()["isHostValue"] = True
        rt.eval("SaveShare.publish")()
        drain(rt)
        assert int(rt.eval("#sent")) == 0
        return
    assert rt.eval("roundTrip")(payload) == payload


def test_a_realistic_file_survives_chunking():
    """hdmod's savegame.sav is ~14 KB, which is more than twenty chunks."""
    rt = runtime()
    payload = (BINARY * 60)[:14000]
    fs_put(rt, "PACK/savegame.sav", payload)
    rt.globals()["isHostValue"] = True
    rt.eval("SaveShare.publish")()
    drain(rt)
    chunks = int(rt.eval("(function() local n = 0 for i = 1, #sent do "
                          "if sent[i].k == 'savedata' then n = n + 1 end end return n end)()"))
    assert chunks > 15, "expected the file to be split across many events, got %d" % chunks
    rt.execute("""
parts = {}
for i = 1, #sent do
    if sent[i].k == "savedata" then parts[#parts + 1] = sent[i].p end
end
isHostValue = false
FS["PACK/savegame.sav"] = nil
for i = 1, #parts do SaveShare.onSaveData(parts[i], 1) end
""")
    assert fs_get(rt, "PACK/savegame.sav") == payload


def test_no_chunk_exceeds_a_safe_datagram():
    rt = runtime()
    fs_put(rt, "PACK/savegame.sav", BINARY * 60)
    rt.globals()["isHostValue"] = True
    rt.eval("SaveShare.publish")()
    drain(rt)
    longest = int(rt.eval("(function() local m = 0 for i = 1, #sent do "
                          "if sent[i].k == 'savedata' and #sent[i].p.d > m then "
                          "m = #sent[i].p.d end end return m end)()"))
    assert longest <= 900, "a chunk of %d chars will fragment or be dropped" % longest


# ------------------------------------------------------------------ borrowing


def peer_with_own_save(rt):
    fs_put(rt, "PACK/save.dat", "MINE-dat")
    fs_put(rt, "PACK/savegame.sav", "MINE-sav")
    rt.globals()["isHostValue"] = False


def chunks_from(dat="HOST-dat", sav="HOST-sav"):
    """One complete generation, built by a host runtime of the real module."""
    src = runtime()
    fs_put(src, "PACK/save.dat", dat)
    fs_put(src, "PACK/savegame.sav", sav)
    src.globals()["isHostValue"] = True
    src.eval("SaveShare.publish")()
    drain(src)
    out = []
    for i in range(1, int(src.eval("#sent")) + 1):
        if src.eval("sent[%d].k" % i) != "savedata":
            continue      # the small live-fields event rides the same list
        out.append(tuple(src.eval("sent[%d].p.%s" % (i, key))
                         for key in ("g", "f", "c", "i", "n", "d")))
    return out


def deliver(rt, dat="HOST-dat", sav="HOST-sav", slot=1, drop_last=False):
    parts = chunks_from(dat, sav)
    if drop_last:
        parts = parts[:-1]
    for g, f, c, i, n, d in parts:
        rt.eval("feed")(slot, g, f, c, i, n, d)


def test_a_peer_adopts_the_hosts_save():
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    assert fs_get(rt, "PACK/save.dat") == "HOST-dat"
    assert fs_get(rt, "PACK/savegame.sav") == "HOST-sav"
    assert rt.eval("SaveShare.borrowing()") is True


def test_the_peers_own_save_is_set_aside_first():
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    assert fs_get(rt, "PACK/save.dat.mo_mine") == "MINE-dat"
    assert fs_get(rt, "PACK/savegame.sav.mo_mine") == "MINE-sav"


def test_it_comes_back_byte_for_byte_on_leaving():
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    rt.eval("SaveShare.restoreOwn")()
    assert fs_get(rt, "PACK/save.dat") == "MINE-dat"
    assert fs_get(rt, "PACK/savegame.sav") == "MINE-sav"
    assert fs_get(rt, "PACK/save.dat.mo_mine") is None, "the parked copy was left behind"
    assert rt.eval("SaveShare.borrowing()") is False


def test_it_fails_closed_when_the_save_cannot_be_set_aside():
    """The failure this guards against is another player's progression left
    permanently in this player's save."""
    rt = runtime()
    peer_with_own_save(rt)
    rt.globals()["BLOCKED"]["PACK/save.dat.mo_mine"] = True
    deliver(rt)
    assert fs_get(rt, "PACK/save.dat") == "MINE-dat", (
        "the host's save was written over a save that could not be backed up")
    assert fs_get(rt, "PACK/savegame.sav") == "MINE-sav"
    assert rt.eval("SaveShare.borrowing()") is False


def test_a_session_that_just_closed_gives_the_save_back_at_load():
    """A parked copy on disk at load means the last session ended while borrowing --
    left cleanly, crashed, or simply closed.

    At LOAD modHost does not exist yet (saveShare is required before it), so the
    parked copies must SURVIVE this phase: Playlunky already handed the mod the
    host's save.dat before any of our Lua ran, and retiring the backup before that
    is undone would lose the player's progression for good.
    """
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute("ModHost = nil")          # as it really is at this point in boot
    rt.globals()["FS"]["PACK/save.dat"] = "HOST-dat"
    rt.globals()["FS"]["PACK/save.dat.mo_mine"] = "MINE-dat"
    rt.execute(SAVE_SHARE)

    assert fs_get(rt, "PACK/save.dat") == "MINE-dat", "the file was not put back"
    assert fs_get(rt, "PACK/save.dat.mo_mine") == "MINE-dat", (
        "the parked copy was retired before the mod's loader had been re-run from it")

    # ...and the second phase, once the mod exists to be re-run
    rt.execute("""
reloaded = {}
ModHost = { reloadSaveData = function(text) reloaded[#reloaded + 1] = text return 1 end }
""")
    assert rt.eval("SaveShare.finishStartupRestore()") is True
    assert list(rt.eval("reloaded").values()) == ["MINE-dat"], (
        "the mod was left holding the host's save state for the whole session")
    assert fs_get(rt, "PACK/save.dat.mo_mine") is None, "the parked copy was never retired"


def test_the_startup_restore_is_idempotent_if_it_is_interrupted():
    """A crash between the two phases must simply mean the next launch does it again."""
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute("ModHost = nil")
    rt.globals()["FS"]["PACK/save.dat"] = "HOST-dat"
    rt.globals()["FS"]["PACK/save.dat.mo_mine"] = "MINE-dat"
    rt.execute(SAVE_SHARE)
    # ...the game closes again before finishStartupRestore. Next launch:
    rt2 = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt2.execute(ENV)
    rt2.execute("ModHost = nil")
    rt2.globals()["FS"]["PACK/save.dat"] = "HOST-dat-again"
    rt2.globals()["FS"]["PACK/save.dat.mo_mine"] = "MINE-dat"
    rt2.execute(SAVE_SHARE)
    assert fs_get(rt2, "PACK/save.dat") == "MINE-dat"


def test_a_file_that_cannot_be_put_back_keeps_its_parked_copy():
    """Losing the backup on a failed write would lose the progression for good."""
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.globals()["FS"]["PACK/save.dat"] = "HOST-dat"
    rt.globals()["FS"]["PACK/save.dat.mo_mine"] = "MINE-dat"
    rt.globals()["BLOCKED"]["PACK/save.dat"] = True
    rt.execute(SAVE_SHARE)
    assert fs_get(rt, "PACK/save.dat.mo_mine") == "MINE-dat"


def test_main_finishes_the_restore_after_hosting():
    main = (PACK / "main.lua").read_text(encoding="utf-8")
    at = main.index("SaveShare.finishStartupRestore")
    assert main.index("ModHost.hostOne") < at, (
        "the restore is finished before the mod is hosted, so there is no loader "
        "to re-run")


def test_only_the_room_host_is_authoritative():
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt, dat="IMPOSTOR", slot=4)  # slot 4 is not the room host
    assert fs_get(rt, "PACK/save.dat") == "MINE-dat"


def test_the_host_never_adopts_its_own_broadcast():
    rt = runtime()
    fs_put(rt, "PACK/save.dat", "HOST-OWN")
    rt.globals()["isHostValue"] = True
    rt.eval("feed")(1, 1, "save.dat", 1, 1, 1, "QUJD")
    assert fs_get(rt, "PACK/save.dat") == "HOST-OWN"


def test_an_incomplete_generation_changes_nothing():
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt, dat=BINARY * 5, drop_last=True)
    assert fs_get(rt, "PACK/save.dat") == "MINE-dat", "adopted a half-delivered save"
    assert rt.eval("SaveShare.borrowing()") is False


# --------------------------------------------------------------- the two doors


def test_seeding_never_overwrites_an_existing_modded_online_save():
    """Once Modded Online has a copy, that copy IS the progression. Re-arming the
    same mod must not throw away everything played under it."""
    rt = runtime()
    fs_put(rt, "PACK/save.dat", "PLAYED-UNDER-MO")
    fs_put(rt, "Mods/Packs/fyi.hdmod/save.dat", "FRESH-FROM-MOD")
    fs_put(rt, "Mods/Packs/fyi.hdmod/savegame.sav", "FRESH-SAV")
    seeded = int(rt.eval("SaveShare.seedFrom")("fyi.hdmod"))
    assert fs_get(rt, "PACK/save.dat") == "PLAYED-UNDER-MO"
    assert fs_get(rt, "PACK/savegame.sav") == "FRESH-SAV", "the absent one was not seeded"
    assert seeded == 1


def test_sync_to_mod_writes_our_save_into_the_mod():
    rt = runtime()
    fs_put(rt, "PACK/save.dat", "MO-PROGRESS")
    fs_put(rt, "Mods/Packs/fyi.hdmod/save.dat", "MOD-OLD")
    rt.eval("SaveShare.syncToMod")()
    assert fs_get(rt, "Mods/Packs/fyi.hdmod/save.dat") == "MO-PROGRESS"
    assert fs_get(rt, "Mods/Packs/fyi.hdmod/save.dat.before_mo") == "MOD-OLD", (
        "overwrote the mod's own save with no way back")


def test_sync_to_mod_refuses_while_borrowing_the_hosts_save():
    """What is on disk then is the ROOM HOST's progression. Writing it into this
    player's mod is the one thing this must never do."""
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    fs_put(rt, "Mods/Packs/fyi.hdmod/save.dat", "MOD-OLD")
    result = rt.eval("SaveShare.syncToMod")()
    assert "borrow" in result
    assert fs_get(rt, "Mods/Packs/fyi.hdmod/save.dat") == "MOD-OLD"


def test_sync_to_mod_says_so_when_no_mod_is_enabled():
    rt = runtime()
    rt.execute("ModHost.requestedPacks = function() return {} end")
    fs_put(rt, "PACK/save.dat", "MO-PROGRESS")
    assert "no mod" in rt.eval("SaveShare.syncToMod")()


def test_the_mods_own_save_is_only_backed_up_once():
    """A second sync must not overwrite the pre-Modded-Online copy with a
    Modded-Online one, or the way back is gone."""
    rt = runtime()
    fs_put(rt, "PACK/save.dat", "MO-1")
    fs_put(rt, "Mods/Packs/fyi.hdmod/save.dat", "MOD-ORIGINAL")
    rt.eval("SaveShare.syncToMod")()
    fs_put(rt, "PACK/save.dat", "MO-2")
    rt.eval("SaveShare.syncToMod")()
    assert fs_get(rt, "Mods/Packs/fyi.hdmod/save.dat") == "MO-2"
    assert fs_get(rt, "Mods/Packs/fyi.hdmod/save.dat.before_mo") == "MOD-ORIGINAL"


# ------------------------------------------------------------------- plumbing


def test_a_peer_asks_the_room_for_its_save_once():
    rt = runtime()
    rt.eval("SaveShare.poll")()
    rt.eval("SaveShare.poll")()
    asks = int(rt.eval("(function() local n = 0 for i = 1, #sent do "
                       "if sent[i].k == 'saveask' then n = n + 1 end end return n end)()"))
    assert asks == 1


def test_the_host_answers_an_ask_by_publishing():
    rt = runtime()
    fs_put(rt, "PACK/save.dat", "HOST-dat")
    rt.globals()["isHostValue"] = True
    rt.eval("SaveShare.onSaveAsk")({}, 2)
    drain(rt)
    assert int(rt.eval("#sent")) > 0


def test_chunks_are_paced_rather_than_dumped_in_one_frame():
    rt = runtime()
    fs_put(rt, "PACK/savegame.sav", BINARY * 60)
    rt.globals()["isHostValue"] = True
    rt.eval("SaveShare.publish")()
    rt.execute("sent = {}")          # drop the live-fields event publish sends
    rt.eval("SaveShare.poll")()
    first = int(rt.eval("#sent"))
    drain(rt)
    total = int(rt.eval("#sent"))
    assert 0 < first < total, (
        "the whole file went out in one frame (%d of %d)" % (first, total))


def test_leaving_a_session_gives_the_save_back():
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    rt.globals()["activeValue"] = False
    rt.eval("SaveShare.poll")()
    assert fs_get(rt, "PACK/save.dat") == "MINE-dat"


def test_netcore_restores_on_leaving_the_room():
    net = (PACK / "src" / "netCore.lua").read_text(encoding="utf-8")
    assert "SaveShare.restoreOwn" in net


def test_the_menu_offers_the_button():
    menu = (PACK / "src" / "menuUI.lua").read_text(encoding="utf-8")
    assert "SYNC SAVE DATA" in menu
    assert "syncSaveItem()," in menu


def test_the_setup_seeds_but_does_not_copy_the_save_files():
    """In COPY_FILES they would be overwritten on every apply, which throws away
    everything played under Modded Online each time the mod is re-armed."""
    setup = (PACK / "src" / "packSetup.lua").read_text(encoding="utf-8")
    assert "SaveShare.seedFrom(packName)" in setup
    at = setup.index("local COPY_FILES = {")
    line = setup[at:setup.index("}", at)]
    assert "savegame.sav" not in line and "save.dat" not in line


# ------------------------------------------------------- live, without a restart


HOST_FIELDS = {"shortcuts": 7, "characters": 99, "players": 8,
               "tutorial_state": 4, "deepest_area": 6, "seeded_unlocked": 1}


def send_fields(rt, values=None, slot=1):
    rt.execute("""
function feedFields(slot, shortcuts, characters, players, tutorial_state,
                    deepest_area, seeded_unlocked)
    SaveShare.onSaveFields({ shortcuts = shortcuts, characters = characters,
                             players = players, tutorial_state = tutorial_state,
                             deepest_area = deepest_area,
                             seeded_unlocked = seeded_unlocked }, slot)
end
""")
    v = dict(HOST_FIELDS if values is None else values)
    rt.eval("feedFields")(slot, v["shortcuts"], v["characters"], v["players"],
                          v["tutorial_state"], v["deepest_area"], v["seeded_unlocked"])


def field(rt, name):
    return rt.eval("savegame.%s" % name)


def test_the_hosts_savegame_fields_are_applied_live():
    """The whole point. Writing savegame.sav does nothing for the session in
    progress -- the engine parsed it at launch and reads from memory."""
    rt = runtime()
    send_fields(rt)
    assert int(field(rt, "shortcuts")) == 7, (
        "Mama Tunnel is still decided by this player's own progress")
    assert int(field(rt, "characters")) == 99
    assert rt.eval("SaveShare.borrowing()") is True


def test_a_boolean_field_stays_a_boolean():
    """Assigning a number where the engine holds a bool is a native type error."""
    rt = runtime()
    send_fields(rt)
    assert field(rt, "seeded_unlocked") is True


def test_our_own_fields_come_back_when_we_leave():
    rt = runtime()
    send_fields(rt)
    rt.eval("SaveShare.restoreOwn")()
    assert int(field(rt, "shortcuts")) == 1
    assert int(field(rt, "characters")) == 2
    assert field(rt, "seeded_unlocked") is False


def test_our_own_fields_are_captured_only_once():
    """A second batch must not record the HOST's values as ours -- that is how a
    borrow silently becomes permanent."""
    rt = runtime()
    send_fields(rt)
    send_fields(rt, dict(HOST_FIELDS, shortcuts=10))
    rt.eval("SaveShare.restoreOwn")()
    assert int(field(rt, "shortcuts")) == 1


def test_only_the_room_host_can_set_the_fields():
    rt = runtime()
    send_fields(rt, slot=4)
    assert int(field(rt, "shortcuts")) == 1


def test_the_host_does_not_apply_its_own_broadcast():
    rt = runtime()
    rt.globals()["isHostValue"] = True
    send_fields(rt)
    assert int(field(rt, "shortcuts")) == 1


def test_publishing_sends_the_live_fields_too():
    rt = runtime()
    fs_put(rt, "PACK/save.dat", "HOST-dat")
    rt.globals()["isHostValue"] = True
    rt.eval("SaveShare.publish")()
    kinds = [rt.eval("sent[%d].k" % i) for i in range(1, int(rt.eval("#sent")) + 1)]
    assert "savefields" in kinds, kinds


def test_adopting_re_runs_the_mods_loader_with_the_new_save():
    """Playlunky hands save.dat to ON.LOAD once, at script load. Hosting means that
    handler is a function we can call again -- which is what removes the restart."""
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    ran = list(rt.eval("reloaded").values())
    assert ran and ran[-1] == "HOST-dat", ran


def test_leaving_re_runs_the_mods_loader_with_our_own_save():
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    rt.eval("SaveShare.restoreOwn")()
    ran = list(rt.eval("reloaded").values())
    assert ran[-1] == "MINE-dat", (
        "the mod was left holding the host's save state after leaving: %r" % ran)


def test_the_host_never_re_runs_its_own_loader():
    rt = runtime()
    rt.globals()["isHostValue"] = True
    rt.eval("SaveShare.restoreOwn")()
    assert list(rt.eval("reloaded").values()) == []


# --------------------------------------------------------- the modHost half


def test_mod_host_captures_the_hosted_mods_load_handler():
    host = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")
    assert "module.loadHandlers[#module.loadHandlers + 1] = first" in host
    assert "select(2, ...) == ON_LOAD" in host


def test_the_synthesised_context_answers_the_call_the_mod_makes():
    """hdmod's handler (lib/save.lua) does `load_ctx:load()` and nothing else with
    the context, so a table with a `load` function is a complete stand-in."""
    host = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")
    assert "local context = { load = function() return text end }" in host


def test_one_mods_loader_throwing_does_not_strand_the_others():
    host = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")
    at = host.index("function module.reloadSaveData(text)")
    body = host[at:at + 600]
    assert "pcall(handler, context)" in body


# ------------------------------------------- closing the game while borrowing


def test_our_own_field_values_are_parked_on_disk_too():
    """The engine writes savegame.sav from its OWN memory whenever it saves, so a
    player who just closes the game leaves the host's values in their file -- and the
    next launch loads them back before we can restore anything. Restoring the file is
    not enough; the values have to be put back in memory, and after a restart this
    sidecar is the only record of what they were."""
    rt = runtime()
    send_fields(rt)
    parked = fs_get(rt, "PACK/mo_own_fields.txt")
    assert parked is not None, "nothing would survive a restart"
    assert "shortcuts=1" in parked, parked
    assert "characters=2" in parked, parked


def test_the_parked_values_are_put_back_in_memory_after_a_restart():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute("ModHost = nil")
    # what closing the game mid-borrow leaves behind
    rt.globals()["FS"]["PACK/save.dat"] = "HOST-dat"
    rt.globals()["FS"]["PACK/save.dat.mo_mine"] = "MINE-dat"
    rt.globals()["FS"]["PACK/mo_own_fields.txt"] = "characters=2" + chr(10) + "shortcuts=1"
    # the engine has already loaded the contaminated savegame into memory
    rt.execute("savegame.shortcuts = 7 savegame.characters = 99")
    rt.execute(SAVE_SHARE)
    assert int(rt.eval("savegame.shortcuts")) == 1, (
        "the host's progression is still in engine memory and will be written back")
    assert int(rt.eval("savegame.characters")) == 2


def test_the_parked_values_are_retired_with_the_parked_files():
    rt = runtime()
    send_fields(rt)
    rt.eval("SaveShare.restoreOwn")()
    assert fs_get(rt, "PACK/mo_own_fields.txt") is None


def test_every_per_machine_artifact_is_declared_in_one_place():
    """packSetup's teardown and --package both read this list, so neither can drift."""
    rt = runtime()
    names = sorted(rt.eval("SaveShare.artifacts()").values())
    assert names == sorted([
        "save.dat", "save.dat.mo_mine", "save.dat.mo_absent",
        "savegame.sav", "savegame.sav.mo_mine", "savegame.sav.mo_absent",
        "mo_own_fields.txt"]), names
    setup = (PACK / "src" / "packSetup.lua").read_text(encoding="utf-8")
    assert "SaveShare.artifacts()" in setup


# ------------------------------- a peer who had no save of their own to begin with


def test_a_file_that_did_not_exist_before_the_borrow_is_deleted_on_restore():
    """The reported bug. A parked copy cannot exist for a file that was never there,
    so nothing was recorded and the host's save simply stayed -- permanently, and
    with no log line to say so. The packaged zip ships neither save file, so a
    freshly installed loader is exactly this case."""
    rt = runtime()
    rt.globals()["isHostValue"] = False        # peer with NO save files at all
    deliver(rt)
    assert fs_get(rt, "PACK/save.dat") == "HOST-dat", "did not adopt in the first place"
    assert fs_get(rt, "PACK/save.dat.mo_absent") is not None, (
        "nothing recorded that this file did not exist before")

    rt.eval("SaveShare.restoreOwn")()
    assert fs_get(rt, "PACK/save.dat") is None, (
        "the peer kept the room host's save because there was nothing to put back")
    assert fs_get(rt, "PACK/savegame.sav") is None
    assert fs_get(rt, "PACK/save.dat.mo_absent") is None, "the marker was left behind"


def test_the_absent_marker_survives_closing_the_game():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute("ModHost = nil")
    # what closing the game mid-borrow leaves for a peer who had no save of their own
    rt.globals()["FS"]["PACK/save.dat"] = "HOST-dat"
    rt.globals()["FS"]["PACK/save.dat.mo_absent"] = ""
    rt.execute(SAVE_SHARE)
    assert fs_get(rt, "PACK/save.dat") is None, (
        "the host's save survived a restart on a peer that never had one")


def test_a_mix_of_parked_and_absent_is_undone_correctly():
    """save.dat existed, savegame.sav did not."""
    rt = runtime()
    fs_put(rt, "PACK/save.dat", "MINE-dat")
    deliver(rt)
    assert fs_get(rt, "PACK/save.dat") == "HOST-dat"
    assert fs_get(rt, "PACK/savegame.sav") == "HOST-sav"
    rt.eval("SaveShare.restoreOwn")()
    assert fs_get(rt, "PACK/save.dat") == "MINE-dat"
    assert fs_get(rt, "PACK/savegame.sav") is None


def test_the_status_line_says_whose_save_this_is():
    """Because the failure was otherwise completely silent."""
    rt = runtime()
    peer_with_own_save(rt)
    assert "on your own save" in rt.eval("SaveShare.status()")
    deliver(rt)
    status = rt.eval("SaveShare.status()")
    assert "BORROWING" in status, status
    assert "2 parked" in status, status


def test_the_desync_log_header_carries_it():
    log = (PACK / "src" / "desyncLog.lua").read_text(encoding="utf-8")
    assert "saveshare=" in log and "SaveShare.status()" in log


# ------------------------------------------- putting the pack back in working order


def test_an_absent_file_is_re_seeded_from_the_mod_rather_than_left_missing():
    """The state from the capture: `0 parked, 2 marked absent`, i.e. a pack holding
    neither save file. Deleting them on leave is a faithful undo and a useless one --
    hdmod NEEDS its savegame.sav, and without it the HD campaign opens fully
    unlocked. The pack goes back to its SEEDED state, not to empty."""
    rt = runtime()
    fs_put(rt, "Mods/Packs/fyi.hdmod/save.dat", "MOD-dat")
    fs_put(rt, "Mods/Packs/fyi.hdmod/savegame.sav", "MOD-sav")
    deliver(rt)                       # peer had neither file of its own
    assert fs_get(rt, "PACK/save.dat") == "HOST-dat"

    rt.eval("SaveShare.restoreOwn")()
    assert fs_get(rt, "PACK/save.dat") == "MOD-dat", (
        "the host's save was kept, or the pack was left empty")
    assert fs_get(rt, "PACK/savegame.sav") == "MOD-sav"
    assert fs_get(rt, "PACK/save.dat.mo_absent") is None


def test_the_mod_is_reloaded_from_the_re_seeded_file_not_from_nothing():
    rt = runtime()
    fs_put(rt, "Mods/Packs/fyi.hdmod/save.dat", "MOD-dat")
    deliver(rt)
    rt.eval("SaveShare.restoreOwn")()
    ran = list(rt.eval("reloaded").values())
    assert ran[-1] == "MOD-dat", (
        "the mod was handed an empty save instead of its own starting state: %r" % ran)


def test_a_parked_copy_still_wins_over_re_seeding():
    """Re-seeding is only for what was never there. A player who HAD a save gets
    that save back, not the mod's fresh one."""
    rt = runtime()
    peer_with_own_save(rt)
    fs_put(rt, "Mods/Packs/fyi.hdmod/save.dat", "MOD-dat")
    deliver(rt)
    rt.eval("SaveShare.restoreOwn")()
    assert fs_get(rt, "PACK/save.dat") == "MINE-dat"


def test_seeding_covers_a_pack_that_packsetup_never_applied_to():
    """packSetup only seeds when the armed selection CHANGES, so a mod armed under an
    older build never got its save files -- which is how a peer came to borrow with
    nothing of its own to give back."""
    rt = runtime()
    fs_put(rt, "Mods/Packs/fyi.hdmod/save.dat", "MOD-dat")
    fs_put(rt, "Mods/Packs/fyi.hdmod/savegame.sav", "MOD-sav")
    assert int(rt.eval("SaveShare.seedHosted()")) == 2
    assert fs_get(rt, "PACK/savegame.sav") == "MOD-sav"
    assert int(rt.eval("SaveShare.seedHosted()")) == 0, "seeding is not idempotent"


def test_boot_seeds_after_hosting():
    main = (PACK / "main.lua").read_text(encoding="utf-8")
    assert "SaveShare.seedHosted" in main
    assert main.index("ModHost.hostOne") < main.index("SaveShare.seedHosted"), (
        "seeding runs before the packs are known")


# ------------------------------------------- a restore that did not actually happen


def test_a_blocked_file_leaves_the_peer_still_borrowing():
    """The module used to clear `borrowed` whether or not the restore worked, so a
    peer holding the host's files reported "on your own save". Three things go wrong
    behind that one lie: the `saveshare=` log header -- the only instrument for this
    bug -- says the wrong thing, SYNC SAVE DATA becomes willing to write the host's
    progression into the mod's own folder, and poll() treats the loan as closed."""
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    rt.globals()["BLOCKED"]["PACK/save.dat"] = True
    rt.eval("SaveShare.restoreOwn")()
    assert rt.eval("SaveShare.borrowing()") is True, (
        "an incomplete restore reported success")
    assert fs_get(rt, "PACK/save.dat.mo_mine") == "MINE-dat", "the parked copy was lost"
    assert "not while borrowing" in rt.eval("SaveShare.syncToMod")()


def test_a_blocked_file_does_not_cost_the_live_fields_too():
    """The files land at the next launch; the `savegame` fields are what the player
    SEES this session. A file that could not be written must not also leave the
    host's unlocks live in engine memory."""
    rt = runtime()
    peer_with_own_save(rt)
    send_fields(rt)
    assert int(field(rt, "shortcuts")) == 7
    deliver(rt)
    rt.globals()["BLOCKED"]["PACK/save.dat"] = True
    rt.eval("SaveShare.restoreOwn")()
    assert int(field(rt, "shortcuts")) == 1, (
        "the host's unlocks were left live because a FILE could not be written")


def test_an_incomplete_restore_keeps_what_it_needs_to_try_again():
    """`ownFields` was retired on the way past, so the retry -- the whole point of
    keeping the parked copies -- had nothing left to put back."""
    rt = runtime()
    peer_with_own_save(rt)
    send_fields(rt)
    deliver(rt)
    rt.globals()["BLOCKED"]["PACK/save.dat"] = True
    rt.eval("SaveShare.restoreOwn")()
    assert fs_get(rt, "PACK/mo_own_fields.txt") is not None, (
        "the on-disk record of this player's own values was retired by a restore "
        "that did not complete")
    rt.globals()["BLOCKED"]["PACK/save.dat"] = None
    rt.execute("savegame.shortcuts = 99")   # as if the host's value were live again
    rt.eval("SaveShare.restoreOwn")()
    assert fs_get(rt, "PACK/save.dat") == "MINE-dat"
    assert int(field(rt, "shortcuts")) == 1
    assert rt.eval("SaveShare.borrowing()") is False


def test_poll_does_not_retry_a_blocked_restore_every_frame():
    """poll() runs on ON.GUIFRAME. Retrying a locked file several times a second for
    as long as the player sits on the main menu is not a retry strategy."""
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    rt.globals()["BLOCKED"]["PACK/save.dat"] = True
    rt.eval("SaveShare.restoreOwn")()
    rt.execute("""
writeAttempts = 0
local realOpen = io.open
io.open = function(path, mode)
    if mode == "wb" then writeAttempts = writeAttempts + 1 end
    return realOpen(path, mode)
end
""")
    rt.globals()["activeValue"] = False
    drain(rt, frames=20)
    assert int(rt.eval("writeAttempts")) == 0, (
        "poll() kept re-attempting a restore it already knows fails")


def test_a_fresh_borrow_re_arms_a_stalled_restore():
    """The stall is "this file would not open a moment ago", not a permanent verdict.
    Borrowing again has to clear it or the NEXT leave is skipped as well."""
    rt = runtime()
    peer_with_own_save(rt)
    deliver(rt)
    rt.globals()["BLOCKED"]["PACK/save.dat"] = True
    rt.eval("SaveShare.restoreOwn")()
    rt.globals()["BLOCKED"]["PACK/save.dat"] = None
    deliver(rt)                    # the room re-publishes; we adopt again
    rt.globals()["activeValue"] = False
    drain(rt, frames=5)
    assert fs_get(rt, "PACK/save.dat") == "MINE-dat"
    assert rt.eval("SaveShare.borrowing()") is False


def test_the_restore_says_what_it_did_every_time():
    """It used to log only when there was something to put back, so a peer that left
    holding somebody else's save left no trace of why -- which dev53's own post-mortem
    names as the reason two rounds of fixes went to the wrong mechanisms."""
    rt = runtime()
    logged = []
    rt.globals()["DesyncLog"] = rt.table_from({
        "event": lambda fmt, *a: logged.append(str(fmt)),
    })
    rt.eval("SaveShare.restoreOwn")()
    assert any("restore ->" in line for line in logged), (
        "a restore with nothing to do said nothing at all")


# ---------------------------------------- the two mechanisms over the same fields


def test_the_capture_is_not_poisoned_by_event_syncs_override():
    """eventSync runs a second mechanism over `shortcuts` and `characters`: it holds
    the host's values across a load and gives the player's own back when the screen
    settles. Its `holdSaveSync` stands down while we are borrowing -- but only in
    that direction. Nothing stopped US capturing while ITS override was up, and
    `readFields()` then records the HOST's values as this player's own, on disk.

    After that the borrow is permanent: leaving "restores" the host's unlocks, the
    parked field file says the same, and a relaunch restores them again. It needs
    only for `savefields` to land after the run started -- a mid-run join has no
    lobby phase at all, and a reliable event can simply arrive late.
    """
    rt = runtime()
    rt.execute("savegame.shortcuts = 1; savegame.characters = 2")
    # eventSync got there first and is holding the host's values
    rt.execute("""
heldOwn = {shortcuts = 1, characters = 2}
savegame.shortcuts = 7
savegame.characters = 99
EventSync = { releaseSaveSync = function()
    savegame.shortcuts = heldOwn.shortcuts
    savegame.characters = heldOwn.characters
end }
""")
    send_fields(rt)
    # the on-disk record is written at capture time, and is what a RELAUNCH restores
    # from -- so a poisoned capture outlives the session that made it
    parked = fs_get(rt, "PACK/mo_own_fields.txt")
    assert "shortcuts=1" in parked and "characters=2" in parked, (
        "the host's values were written to disk as this player's own, so even a "
        "relaunch hands them back: parked=%r" % parked)
    rt.eval("SaveShare.restoreOwn")()
    assert int(field(rt, "shortcuts")) == 1, (
        "the host's shortcut progress was recorded as this player's own and handed "
        "back to them as theirs")
    assert int(field(rt, "characters")) == 2, (
        "the host's unlocked characters became the peer's, permanently -- "
        "savegame.characters is where hdmod keeps unlocks, not save.dat")


def test_a_build_without_event_sync_still_captures():
    """The release is a courtesy to a module that may not be loaded."""
    rt = runtime()
    rt.execute("EventSync = nil")
    send_fields(rt)
    rt.eval("SaveShare.restoreOwn")()
    assert int(field(rt, "shortcuts")) == 1
