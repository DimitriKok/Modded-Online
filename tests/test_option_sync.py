"""End-to-end tests for the mod-SETTINGS sync (src/optionSync.lua + the
option-sync block src/shimInjector.lua prepends to every pack with settings).

The interesting half of this feature runs inside ANOTHER mod's Lua VM, where
nothing in this repo can reach it, so it is tested the only way that proves
anything: the block is pulled out of the injector exactly as it would be written
into a pack's main.lua, loaded into a real Lua state next to a fake mod that
registers ON.SAVE, and driven through the whole lifecycle.

What these lock down, in the order they matter:
  * a mod's OWN values are what its save callback sees, ALWAYS -- with an
    override applied, across a re-apply, and after release;
  * no backup file on disk means no override at all (fail closed);
  * only keys the mod already has are ever written;
  * the file round-trips bools, ints, floats and strings unchanged.

Run:  python -m pytest tests/test_option_sync.py -q
"""

from __future__ import annotations

import contextlib
import os
import re
import pathlib
import shutil
import tempfile

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent


@contextlib.contextmanager
def sandbox():
    """A throwaway Mods/Packs tree, entered as the cwd (every path the Lua under
    test opens is relative to the game directory). The cwd has to be restored
    BEFORE the directory is removed -- Windows will not delete a directory that
    is still some process's working directory.
    """
    here = os.getcwd()
    path = tempfile.mkdtemp()
    try:
        yield pathlib.Path(path)
    finally:
        os.chdir(here)
        shutil.rmtree(path, ignore_errors=True)


SHIM_SRC = (PACK / "src" / "shimInjector.lua").read_text(encoding="utf-8")
OPT_SYNC_SRC = (PACK / "src" / "optionSync.lua").read_text(encoding="utf-8")


def opt_shim() -> str:
    """The option-sync block exactly as injectInto would write it."""
    match = re.search(
        r'local OPT_SHIM = "-- " \.\. OPT_MARKER \.\. \[\[(.*?)\n\]\]\n', SHIM_SRC, re.S
    )
    assert match, "OPT_SHIM payload not found in src/shimInjector.lua"
    body = match.group(1)
    assert "]]" not in body, "payload closes its own long bracket"
    return "-- [ModdedOnline-OptionSync-v1]" + body


PRELUDE = """
-- Playlunky/Overlunky surface the injected block uses.
ON = {
    SAVE = 1, GUIFRAME = 2, PRE_LEVEL_GENERATION = 3, LOADING = 4,
    POST_LEVEL_GENERATION = 5, PRE_LOAD_SCREEN = 6, PRE_LOAD_LEVEL_FILES = 7,
    FRAME = 8, GAMEFRAME = 9,
}
meta = { name = "Fake Mod" }
callbacks = {}
function set_callback(cb, id)
    callbacks[id] = callbacks[id] or {}
    table.insert(callbacks[id], cb)
    return #callbacks[id]
end
function fire(id, ...)
    for _, cb in ipairs(callbacks[id] or {}) do cb(...) end
end
-- ON.GUIFRAME is polled every 20th tick by the block
function guiframes(n)
    for _ = 1, n do fire(ON.GUIFRAME) end
end
function writefile(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end
function readfile(path)
    local f = io.open(path, "r")
    if f == nil then return nil end
    local d = f:read("*a")
    f:close()
    return d
end
"""

# A stand-in content mod: it registers ON.SAVE the way the HD mod's lib/save.lua
# does, and records exactly what `options` held when it ran.
FAKE_MOD = """
options = {
    hd_og_floorstyle_temple = false,
    hd_use_s2_item_pools = false,
    hd_debug_camp_rope_entry = true,
    olmec_orb_chance_denominator = 2,
    yama_swing_windup_base = 35.5,
    hd_debug_scripted_levelgen_tilecodes_blacklist = "",
}
saved = nil
saves = 0
set_callback(function()
    saves = saves + 1
    local snap = {}
    for k, v in pairs(options) do snap[k] = v end
    saved = snap
end, ON.SAVE)
"""


def new_state(tmp: pathlib.Path, mod: str = FAKE_MOD):
    os.chdir(tmp)
    (tmp / "Mods" / "Packs").mkdir(parents=True, exist_ok=True)
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    lua.execute(opt_shim())  # PREPENDED: wraps set_callback before the mod runs
    lua.execute(mod)
    return lua


def override_file(gen: int, lines: str) -> str:
    return "# comment\ngen\t%d\n%s\n" % (gen, lines)


BASIC = (
    "hd_og_floorstyle_temple\tb\t1\n"
    "hd_use_s2_item_pools\tb\t1\n"
    "olmec_orb_chance_denominator\tn\t7\n"
    "yama_swing_windup_base\tn\t40.25\n"
    "hd_debug_scripted_levelgen_tilecodes_blacklist\ts\tpush\\tblock\n"
    "not_an_option_this_mod_has\tb\t1"
)


def test_applies_host_values_and_types_round_trip():
    with sandbox() as tmp:
        lua = new_state(tmp)
        (tmp / "Mods" / "Packs" / "mo_options.txt").write_text(override_file(11, BASIC))
        lua.execute("guiframes(20)")
        opts = lua.eval("options")
        assert opts["hd_og_floorstyle_temple"] is True
        assert opts["hd_use_s2_item_pools"] is True
        assert opts["olmec_orb_chance_denominator"] == 7
        assert lua.eval("math.type(options.olmec_orb_chance_denominator)") == "integer"
        assert opts["yama_swing_windup_base"] == 40.25
        assert opts["hd_debug_scripted_levelgen_tilecodes_blacklist"] == "push\tblock"
        # untouched: the host did not publish it
        assert opts["hd_debug_camp_rope_entry"] is True
        # never invented: the mod has no such option
        assert lua.eval("options.not_an_option_this_mod_has") is None


def test_backup_file_written_before_any_override():
    with sandbox() as tmp:
        lua = new_state(tmp)
        (tmp / "Mods" / "Packs" / "mo_options.txt").write_text(override_file(11, BASIC))
        lua.execute("guiframes(20)")
        backup = tmp / "Mods" / "Packs" / "mo_options_backup_Fake Mod.txt"
        assert backup.exists()
        text = backup.read_text()
        # exactly the keys that were CHANGED, at their pre-override values
        assert "hd_og_floorstyle_temple = false" in text
        assert "olmec_orb_chance_denominator = 2" in text
        # not changed by the override, so not in the backup
        assert "hd_debug_camp_rope_entry" not in text


def test_no_backup_no_override():
    """Fail closed: if the backup cannot be written, nothing is overridden."""
    with sandbox() as tmp:
        lua = new_state(tmp)
        # make every write fail the way a read-only or missing directory would
        lua.execute("""
            local realopen = io.open
            io.open = function(path, mode)
                if mode == "w" then return nil end
                return realopen(path, mode)
            end
        """)
        (tmp / "Mods" / "Packs" / "mo_options.txt").write_text(override_file(11, BASIC))
        lua.execute("guiframes(60)")
        assert lua.eval("options.hd_og_floorstyle_temple") is False
        assert lua.eval("options.olmec_orb_chance_denominator") == 2


def test_mod_only_ever_saves_its_own_values():
    with sandbox() as tmp:
        lua = new_state(tmp)
        (tmp / "Mods" / "Packs" / "mo_options.txt").write_text(override_file(11, BASIC))
        lua.execute("guiframes(20)")
        assert lua.eval("options.hd_og_floorstyle_temple") is True

        lua.execute("fire(ON.SAVE)")
        saved = lua.eval("saved")
        # THE point of the whole feature: the host's values never reach the disk
        assert saved["hd_og_floorstyle_temple"] is False
        assert saved["hd_use_s2_item_pools"] is False
        assert saved["olmec_orb_chance_denominator"] == 2
        assert saved["yama_swing_windup_base"] == 35.5
        # ...and the room's settings are back in force straight afterwards
        assert lua.eval("options.hd_og_floorstyle_temple") is True
        assert lua.eval("options.olmec_orb_chance_denominator") == 7


def test_release_restores_and_then_drops_the_backup():
    with sandbox() as tmp:
        lua = new_state(tmp)
        override = tmp / "Mods" / "Packs" / "mo_options.txt"
        backup = tmp / "Mods" / "Packs" / "mo_options_backup_Fake Mod.txt"
        override.write_text(override_file(11, BASIC))
        lua.execute("guiframes(20)")
        assert backup.exists()

        override.unlink()  # left the room
        lua.execute("guiframes(20)")
        assert lua.eval("options.hd_og_floorstyle_temple") is False
        assert lua.eval("options.olmec_orb_chance_denominator") == 2
        # the record survives until the mod has written its own values back out
        assert backup.exists()

        lua.execute("fire(ON.SAVE)")
        assert lua.eval("saved")["hd_og_floorstyle_temple"] is False
        assert not backup.exists() or backup.read_text() == ""


def test_new_generation_keeps_the_original_backup():
    with sandbox() as tmp:
        lua = new_state(tmp)
        override = tmp / "Mods" / "Packs" / "mo_options.txt"
        override.write_text(override_file(11, "hd_og_floorstyle_temple\tb\t1"))
        lua.execute("guiframes(20)")
        # host toggles it back, and turns something else on
        override.write_text(
            override_file(12, "hd_og_floorstyle_temple\tb\t0\nhd_use_s2_item_pools\tb\t1")
        )
        lua.execute("guiframes(20)")
        lua.execute("fire(ON.SAVE)")
        saved = lua.eval("saved")
        assert saved["hd_og_floorstyle_temple"] is False
        assert saved["hd_use_s2_item_pools"] is False
        override.unlink()
        lua.execute("guiframes(20)")
        assert lua.eval("options.hd_og_floorstyle_temple") is False
        assert lua.eval("options.hd_use_s2_item_pools") is False


def test_reasserted_when_the_mod_rebuilds_its_options_table():
    """The HD mod replaces `options` wholesale on ON.LOAD and on reset-to-defaults."""
    with sandbox() as tmp:
        lua = new_state(tmp)
        (tmp / "Mods" / "Packs" / "mo_options.txt").write_text(override_file(11, BASIC))
        lua.execute("guiframes(20)")
        assert lua.eval("options.hd_og_floorstyle_temple") is True
        lua.execute("options = { hd_og_floorstyle_temple = false, hd_use_s2_item_pools = false }")
        lua.execute("guiframes(20)")
        assert lua.eval("options.hd_og_floorstyle_temple") is True
        assert lua.eval("options.hd_use_s2_item_pools") is True


def test_applied_before_level_generation():
    """A file that lands between polls is still in force before anything generates."""
    with sandbox() as tmp:
        lua = new_state(tmp)
        (tmp / "Mods" / "Packs" / "mo_options.txt").write_text(override_file(11, BASIC))
        lua.execute("fire(ON.PRE_LEVEL_GENERATION)")
        assert lua.eval("options.hd_og_floorstyle_temple") is True


def test_no_settings_file_changes_nothing():
    with sandbox() as tmp:
        lua = new_state(tmp)
        lua.execute("guiframes(60); fire(ON.LOADING); fire(ON.PRE_LEVEL_GENERATION)")
        assert lua.eval("options.hd_og_floorstyle_temple") is False
        lua.execute("fire(ON.SAVE)")
        assert lua.eval("saved")["olmec_orb_chance_denominator"] == 2
        assert not (tmp / "Mods" / "Packs" / "mo_options_backup_Fake Mod.txt").exists()


# ------------------------------------------------------------ the sending half

OPT_SYNC_PRELUDE = """
ON = { GUIFRAME = 2 }
callbacks = {}
function set_callback(cb, id) callbacks[id] = cb end
function dbg() end
function dbgf() end
function toast(t) last_toast = t end
function SafeCall(_, fn, ...) return fn(...) end
now_ms = 0
function get_ms() return now_ms end
DesyncLog = nil
sent = {}
Network = {
    lobbyPlayers = { { slot = 1 } },
    active = true,
    host = false,
    isActive = function() return Network.active end,
    isHost = function() return Network.host end,
    hostSlot = function() return 0 end,
    onEvent = function(kind, handler) Network.handlers = Network.handlers or {}; Network.handlers[kind] = handler end,
    sendEvent = function(kind, payload) sent[#sent + 1] = { k = kind, p = payload } end,
    enabledScriptPacks = function() return { "fake.pack" } end,
    -- every content mod in play, hosted ones included; optionSync asks for this
    -- rather than the load_order walk, because a hosted mod is disabled there
    syncedScriptPacks = function() return { "fake.pack" }, {} end,
    packOptions = function() return Network.opts end,
    allPackOptions = function() return Network.opts end,
    opts = {
        hd_og_floorstyle_temple = true,
        olmec_orb_chance_denominator = 7,
        pos_x = 0.5,               -- window geometry: never synced
        entity_spawner_index = 3,  -- dev-panel state: never synced
    },
}
package = { loaded = {} }
function require() end
"""


def load_option_sync(tmp: pathlib.Path):
    os.chdir(tmp)
    (tmp / "Mods" / "Packs").mkdir(parents=True, exist_ok=True)
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE.replace("function set_callback", "function _unused_set_callback"))
    lua.execute(OPT_SYNC_PRELUDE)
    lua.execute(OPT_SYNC_SRC)
    return lua


def test_host_publishes_only_world_affecting_settings():
    with sandbox() as tmp:
        lua = load_option_sync(tmp)
        lua.execute("Network.host = true; now_ms = 100000; OptionSync.poll()")
        events = lua.eval("sent")
        assert len(events) >= 1
        text = "".join(events[i]["p"]["d"] for i in range(1, len(events) + 1))
        assert "hd_og_floorstyle_temple\tb\t1" in text
        assert "olmec_orb_chance_denominator\tn\t7" in text
        # per-machine window geometry and dev-panel state are never sent
        assert "pos_x" not in text
        assert "entity_spawner_index" not in text


def test_host_does_not_republish_unchanged_settings():
    with sandbox() as tmp:
        lua = load_option_sync(tmp)
        lua.execute("Network.host = true; now_ms = 100000; OptionSync.poll()")
        first = len(lua.eval("sent"))
        # past the poll throttle but inside the resend backstop: still silent
        lua.execute("now_ms = 102100; OptionSync.poll()")
        assert len(lua.eval("sent")) == first
        # ...but a change goes out at once
        lua.execute("Network.opts.hd_og_floorstyle_temple = false; now_ms = 104200; OptionSync.poll()")
        assert len(lua.eval("sent")) > first


def test_host_republishes_when_someone_joins():
    with sandbox() as tmp:
        lua = load_option_sync(tmp)
        lua.execute("Network.host = true; now_ms = 100000; OptionSync.poll()")
        first = len(lua.eval("sent"))
        lua.execute("""
            table.insert(Network.lobbyPlayers, { slot = 2 })
            now_ms = 102100
            OptionSync.poll()
        """)
        assert len(lua.eval("sent")) > first


def test_joiner_writes_the_file_and_a_backup_then_cleans_up():
    with sandbox() as tmp:
        lua = load_option_sync(tmp)
        # take the host's own chunks and feed them to a joiner
        lua.execute("Network.host = true; now_ms = 100000; OptionSync.poll()")
        lua.execute("""
            local chunks = {}
            for i = 1, #sent do chunks[i] = sent[i] end
            Network.host = false
            for i = 1, #chunks do Network.handlers["modopts"](chunks[i].p, 1) end
        """)
        override = tmp / "Mods" / "Packs" / "mo_options.txt"
        backup = tmp / "Mods" / "Packs" / "mo_options_backup.txt"
        assert override.exists() and backup.exists()
        body = override.read_text()
        assert re.search(r"^gen\t\d+$", body, re.M)
        assert "hd_og_floorstyle_temple\tb\t1" in body
        assert "[fake.pack]" in backup.read_text()
        assert lua.eval("last_toast") is not None

        lua.execute("Network.active = false; now_ms = 200000; OptionSync.poll()")
        assert not override.exists() or override.read_text() == ""


def test_joiner_rejects_a_scrambled_reassembly():
    with sandbox() as tmp:
        lua = load_option_sync(tmp)
        lua.execute("""
            Network.host = false
            Network.handlers["modopts"]({ g = 12345, i = 1, n = 1, d = "hd_og_floorstyle_temple\\tb\\t1" }, 1)
        """)
        assert not (tmp / "Mods" / "Packs" / "mo_options.txt").exists()


def test_joiner_ignores_settings_from_a_non_host_slot():
    with sandbox() as tmp:
        lua = load_option_sync(tmp)
        lua.execute("Network.host = true; now_ms = 100000; OptionSync.poll()")
        lua.execute("""
            local chunks = {}
            for i = 1, #sent do chunks[i] = sent[i] end
            Network.host = false
            for i = 1, #chunks do Network.handlers["modopts"](chunks[i].p, 3) end
        """)
        assert not (tmp / "Mods" / "Packs" / "mo_options.txt").exists()


def test_stale_override_is_cleared_at_load():
    """A file left behind by a crash must never leak into the next solo game."""
    with sandbox() as tmp:
        (tmp / "Mods" / "Packs").mkdir(parents=True, exist_ok=True)
        (tmp / "Mods" / "Packs" / "mo_options.txt").write_text(
            override_file(11, "hd_og_floorstyle_temple\tb\t1")
        )
        load_option_sync(tmp)
        override = tmp / "Mods" / "Packs" / "mo_options.txt"
        assert not override.exists() or override.read_text() == ""


# --------------------------------------------- both injected blocks, together

DETERMINISM_ENV = """
ON.FRAME = 10
ON.GAMEFRAME = 11
ON.POST_LEVEL_GENERATION = 12
ON.PRE_LOAD_LEVEL_FILES = 13
function get_adventure_seed() return 12345, 6789 end
function get_local_state()
    return { world = 1, level = 1, theme = 1, time_total = 100 }
end
function seed_prng() end
function get_frame() return 7 end
function get_ms() return 116 end
prng = {
    get_pair = function(_, _) return 1, 2 end,
    set_pair = function() end,
}
"""


def determinism_shim() -> str:
    match = re.search(
        r'local SHIM = "-- " \.\. MARKER \.\. \[\[(.*?)\n\]\]\n', SHIM_SRC, re.S
    )
    assert match, "SHIM payload not found in src/shimInjector.lua"
    return "-- [ModdedOnline-DeterminismShim-v19]" + match.group(1)


def test_both_blocks_compose():
    """main.lua really carries BOTH prepended blocks, and both wrap set_callback.
    The determinism shim's wrapper must not swallow the option block's ON.SAVE
    restore, and vice versa."""
    with sandbox() as tmp:
        os.chdir(tmp)
        (tmp / "Mods" / "Packs").mkdir(parents=True, exist_ok=True)
        lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(PRELUDE)
        lua.execute(DETERMINISM_ENV)
        lua.execute(determinism_shim())  # written first by injectInto
        lua.execute(opt_shim())
        lua.execute(FAKE_MOD)
        (tmp / "Mods" / "Packs" / "mo_options.txt").write_text(override_file(11, BASIC))
        lua.execute("guiframes(20)")
        assert lua.eval("options.hd_og_floorstyle_temple") is True
        lua.execute("fire(ON.SAVE)")
        assert lua.eval("saved")["hd_og_floorstyle_temple"] is False
        assert lua.eval("options.hd_og_floorstyle_temple") is True
        # the determinism shim is still doing its own job through the same chain
        assert lua.eval("get_frame()") == 100
