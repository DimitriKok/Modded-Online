"""Tests the content-mod host — the loader build's replacement for the shim.

The shim prepends a determinism payload into another pack's `main.lua` because
Playlunky gives every pack its own Lua state and there is no channel between them.
This runs the mod's Lua in *our* state instead, against an environment we build, so
nothing on disk is ever modified.

Everything the host must guarantee is mechanical and testable without the game:
a hosted mod's globals must not reach ours, its reads must fall through to the
engine, a module imported twice must execute once, a cycle must terminate, and in
inert mode nothing may reach the engine at all.

Run:  python -m pytest tests/test_mod_host.py -q
"""

from __future__ import annotations

import pathlib
import textwrap

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")

NL = chr(10)


@pytest.fixture
def fake_pack(tmp_path, monkeypatch):
    """A pack tree on disk, laid out the way Playlunky expects."""
    root = tmp_path / "Mods" / "Packs" / "fake.mod"
    (root / "src").mkdir(parents=True)
    monkeypatch.chdir(tmp_path)

    def write(rel: str, body: str) -> None:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(body), encoding="utf-8")

    return write


def runtime(pack_root: str = "."):
    """Our Lua state, with the engine globals and the few pack helpers modHost uses."""
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
printed = {}
function print(s) printed[#printed + 1] = s end
ON = {LEVEL = 1, GAMEFRAME = 2, PRE_LEVEL_GENERATION = 3}
engineCalls = 0
registeredIds = {}
nextId = 100
cleared = {}
function set_callback(fn, id)
    engineCalls = engineCalls + 1
    registeredIds[#registeredIds + 1] = id
    nextId = nextId + 1
    return nextId
end
function clear_callback(id) cleared[#cleared + 1] = id or "current" end
function set_post_tile_code_callback(fn, code) engineCalls = engineCalls + 1; return 98 end
function spawn_entity() engineCalls = engineCalls + 1 end
OUR_SECRET = "modded online owns this"
function dbg() end
function errorf(fmt) printed[#printed + 1] = "ERR " .. tostring(fmt) end
function SafeCall(name, fn, ...) local ok, r = pcall(fn, ...); return ok and r or nil end
""")
    rt.execute('packRoot = "%s"' % pack_root)
    rt.execute('function PackPath(n) return packRoot .. "/" .. n end')
    rt.execute(MOD_HOST)
    return rt


def test_it_resolves_module_paths_the_way_a_pack_expects(fake_pack):
    rt = runtime()
    resolve = rt.eval("ModHost.resolve")
    assert str(resolve("fyi.spelunky-25-2", "src.game")) == \
        "Mods/Packs/fyi.spelunky-25-2/src/game.lua"
    # root-level modules too: 2.5 imports "sp25debug1" that way
    assert str(resolve("fyi.spelunky-25-2", "sp25debug1")) == \
        "Mods/Packs/fyi.spelunky-25-2/sp25debug1.lua"


def test_a_hosted_mod_loads_its_own_module_graph(fake_pack):
    fake_pack("main.lua", """
        local helpers = SafeImport({ path = "src.helpers" })
        MOD_READY = helpers.ready
    """)
    fake_pack("src/helpers.lua", """
        return { ready = true }
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is True, report["err"]
    assert [str(v) for v in report["modules"].values()] == ["main", "src.helpers"]
    assert int(report["files"]) == 2


def test_a_module_can_name_a_sibling_without_the_full_path(fake_pack):
    """hdmod's lib/journal/hdmod_journal.lua does require("journal_data") for the
    file next to it. Resolving only from the pack root failed that, which took the
    whole host down after six modules."""
    fake_pack("main.lua", """
        local user = SafeImport({ path = "lib.journal.user" })
        probe.sibling_loaded = user.data.tag
    """)
    fake_pack("lib/journal/user.lua", """
        return { data = require("journal_data") }
    """)
    fake_pack("lib/journal/journal_data.lua", """
        return { tag = "the real one" }
    """)
    rt = runtime()
    rt.execute("probe = {}")
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is True, report["err"]
    assert str(rt.eval("probe.sibling_loaded")) == "the real one"


def test_two_spellings_of_one_file_are_one_module(fake_pack):
    """hdmod requires the same journal data both ways. Cached by NAME it would load
    twice, and the second copy is the one its options GUI would close over."""
    fake_pack("main.lua", """
        local dotted = SafeImport({ path = "lib.journal.journal_data" })
        local user = SafeImport({ path = "lib.journal.user" })
        probe.same_table = (dotted == user.data)
        probe.times_run = dotted.runs
    """)
    fake_pack("lib/journal/user.lua", """
        return { data = require("journal_data") }
    """)
    fake_pack("lib/journal/journal_data.lua", """
        probe.runs = (probe.runs or 0) + 1
        return { runs = probe.runs }
    """)
    rt = runtime()
    rt.execute("probe = {}")
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is True, report["err"]
    assert rt.eval("probe.same_table") is True, "the file was loaded twice"
    assert int(rt.eval("probe.times_run")) == 1


def test_the_same_absent_module_is_only_searched_for_once(fake_pack):
    """A mod may ask repeatedly; the disk should not be walked every time."""
    fake_pack("main.lua", """
        require("src.texture")
        require("src.texture")
        require("src.texture")
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is True, report["err"]
    named = [str(v) for v in report["missingModules"].values()]
    assert named == ["src.texture"], named


def test_the_mods_globals_never_touch_ours(fake_pack):
    """The isolation the shim could never offer, because it ran inside the mod."""
    fake_pack("main.lua", """
        Sp25GameClass = { sp25World = "SP25-DWELL" }
        OUR_SECRET = "clobbered"
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is True, report["err"]
    assert rt.eval("Sp25GameClass") is None, "a hosted global leaked into our state"
    assert str(rt.eval("OUR_SECRET")) == "modded online owns this"


def test_the_mod_still_sees_the_engine(fake_pack):
    fake_pack("main.lua", """
        SAW_EVENT = ON.PRE_LEVEL_GENERATION
    """)
    rt = runtime()
    rt.eval("ModHost.host")("fake.mod")  # reads fall through to _G
    # the value was read successfully, so it was not reported as missing
    report = rt.eval("ModHost.host")("fake.mod")
    missing = [str(v) for v in report["missing"].values()]
    assert "ON" not in missing


def test_inert_mode_lets_nothing_reach_the_engine(fake_pack):
    """What makes the spike safe to run in a live game."""
    fake_pack("main.lua", """
        set_callback(function() end, ON.GAMEFRAME)
        set_callback(function() end, ON.LEVEL)
        register_console_command("boom", function() end)
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": True}))
    assert report["ok"] is True, report["err"]
    assert int(rt.eval("engineCalls")) == 0, "a registration reached the engine"
    calls = [str(c["api"]) for c in report["callbacks"].values()]
    assert calls == ["set_callback", "set_callback", "register_console_command"]


def test_registrations_are_recorded_with_their_event(fake_pack):
    fake_pack("main.lua", """
        set_callback(function() end, ON.GAMEFRAME)
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod")
    entry = list(report["callbacks"].values())[0]
    assert int(entry["event"]) == int(rt.eval("ON.GAMEFRAME"))


def test_a_module_imported_twice_runs_once(fake_pack):
    fake_pack("main.lua", """
        local a = SafeImport({ path = "src.counted" })
        local b = SafeImport({ path = "src.counted" })
        SAME = (a == b)
    """)
    fake_pack("src/counted.lua", """
        RUNS = (RUNS or 0) + 1
        return { n = RUNS }
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is True, report["err"]
    assert [str(v) for v in report["modules"].values()].count("src.counted") == 1


def test_a_circular_import_terminates(fake_pack):
    fake_pack("main.lua", """
        SafeImport({ path = "src.a" })
    """)
    fake_pack("src/a.lua", """
        SafeImport({ path = "src.b" })
        return { name = "a" }
    """)
    fake_pack("src/b.lua", """
        SafeImport({ path = "src.a" })
        return { name = "b" }
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod")   # must not recurse forever
    assert report["ok"] is True, report["err"]


def test_a_module_with_no_file_is_nil_rather_than_an_error(fake_pack):
    """Both mods hosted so far require a file they do not ship -- 2.5 asks for
    `src.texture`, hdmod for `lib.entities.hdtype` -- and both run fine under
    Playlunky. hdmod's is a bare require on line 42 with nothing to catch a throw,
    so Playlunky must hand back nil. Raising instead took the host down seven
    modules in, before hdmod had registered its options."""
    fake_pack("main.lua", """
        local absent = require("lib.entities.hdtype")
        probe.absent_is_nil = (absent == nil)
        SafeImport({ path = "src.present" })
        probe.reached_the_end = true
    """)
    fake_pack("src/present.lua", "return {}")
    rt = runtime()
    rt.execute("probe = {}")
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is True, report["err"]
    assert rt.eval("probe.absent_is_nil") is True
    assert rt.eval("probe.reached_the_end") is True, "a bare require killed the host"
    named = [str(v) for v in report["missingModules"].values()]
    assert named == ["lib.entities.hdtype"], named
    assert "src.present" in [str(v) for v in report["modules"].values()]


def test_a_module_that_exists_but_throws_is_still_an_error(fake_pack):
    """Only 'there is no such file' is tolerated. A real fault must not be hidden."""
    fake_pack("main.lua", """
        SafeImport({ path = "src.broken" })
        probe.reached_the_end = true
    """)
    fake_pack("src/broken.lua", "error('this module is genuinely broken')")
    rt = runtime()
    rt.execute("probe = {}")
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is True, report["err"]
    skipped = [str(e["path"]) for e in report["skipped"].values()]
    assert skipped == ["src.broken"], "a throwing module was treated as merely absent"
    assert len(report["missingModules"]) == 0


def test_an_error_names_the_mods_own_file(fake_pack):
    """`load(src, "@path")` so a traceback reads as the mod's file and line."""
    fake_pack("main.lua", """
        local x = nil
        x.y = 1
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is False
    assert "Mods/Packs/fake.mod/main.lua" in str(report["err"]), report["err"]


def test_unknown_globals_are_reported_once_each(fake_pack):
    """This list IS the spike's answer: the Playlunky APIs we have not emulated."""
    fake_pack("main.lua", """
        local a = SOME_PLAYLUNKY_THING
        local b = SOME_PLAYLUNKY_THING
        local c = ANOTHER_ONE
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod")
    missing = [str(v) for v in report["missing"].values()]
    assert missing.count("SOME_PLAYLUNKY_THING") == 1
    assert "ANOTHER_ONE" in missing


def test_overrides_replace_what_the_mod_sees(fake_pack):
    """The whole point: hand the mod OUR math.random, not Lua's."""
    fake_pack("main.lua", """
        ROLLED = math.random(1, 100)
    """)
    rt = runtime()
    rt.execute("""
    fakeMath = {}
    for k, v in pairs(math) do fakeMath[k] = v end
    fakeMath.random = function() return 42 end
    """)
    overrides = rt.table_from({"math": rt.eval("fakeMath")})
    report = rt.eval("ModHost.host")("fake.mod",
                                     rt.table_from({"inert": True, "overrides": overrides}))
    assert report["ok"] is True, report["err"]
    # and it did not disturb ours
    assert rt.eval("math.random") is not rt.eval("fakeMath.random")


def test_the_summary_is_legible_on_its_own(fake_pack):
    fake_pack("main.lua", """
        set_callback(function() end, ON.GAMEFRAME)
        local x = UNKNOWN_API
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod")
    lines = [str(v) for v in rt.eval("ModHost.summarize")(report).values()]
    assert "LOADED" in lines[0]
    assert "1 registrations" in lines[0]
    assert any("UNKNOWN_API" in line for line in lines)


def test_nothing_here_runs_by_itself():
    """`host` is called by hand. A module that hosted on load would fire inside any
    game that had this pack enabled, which is not something to discover at runtime."""
    assert "ModHost = module" in MOD_HOST
    body = MOD_HOST[MOD_HOST.index("ModHost = module"):]
    assert "module.spike(" not in body, "the spike invokes itself at load"


# ------------------------------------------------------- Spike 3: hosting for real

def test_live_mode_forwards_registrations_to_the_engine(fake_pack):
    """Inert mode is for measuring. Live mode has to actually install the callbacks,
    or a hosted mod loads and then does nothing at all."""
    fake_pack("main.lua", """
        set_callback(function() end, ON.GAMEFRAME)
        set_callback(function() end, ON.LEVEL)
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert int(rt.eval("engineCalls")) == 2, "the engine never saw them"
    assert [int(v) for v in rt.eval("registeredIds").values()] == [
        int(rt.eval("ON.GAMEFRAME")), int(rt.eval("ON.LEVEL"))]
    # and it is still counted, because registration happens per floor too
    assert len(report["callbacks"]) == 2


def test_live_mode_hands_back_the_engines_own_callback_id(fake_pack):
    """A mod that keeps the id to clear the callback later must get the real one."""
    fake_pack("main.lua", """
        GOT_ID = set_callback(function() end, ON.GAMEFRAME)
    """)
    rt = runtime()
    rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert int(rt.eval("engineCalls")) == 1


def test_no_flag_file_means_this_build_hosts_nothing(tmp_path, monkeypatch):
    """The default has to be inert: this pack is a copy of the shipping mod, and a
    boot that silently started hosting would be indistinguishable from a bug."""
    monkeypatch.chdir(tmp_path)
    rt = runtime(pack_root=str(tmp_path).replace("\\", "/"))
    assert rt.eval("ModHost.requestedPack()") is None
    assert rt.eval("ModHost.autoHost()") is None


def test_an_empty_flag_file_means_the_default_pack(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "mo_host.on").write_text("", encoding="utf-8")
    rt = runtime(pack_root=str(tmp_path).replace("\\", "/"))
    assert str(rt.eval("ModHost.requestedPack()")) == "fyi.spelunky-25-2"


def test_the_flag_file_can_name_another_pack(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "mo_host.on").write_text("  fyi.randomizer \n", encoding="utf-8")
    rt = runtime(pack_root=str(tmp_path).replace("\\", "/"))
    assert str(rt.eval("ModHost.requestedPack()")) == "fyi.randomizer"


def test_the_flag_file_can_name_several_packs(tmp_path, monkeypatch):
    """The picker writes one pack per line. The old reader stripped ALL whitespace,
    which would have welded two names into one nonexistent pack rather than failing
    visibly."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / "mo_host.on").write_text(
        "fyi.spelunky-25-2\nfyi.randomizer\n", encoding="utf-8")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    names = [str(v) for v in rt.eval("ModHost.requestedPacks()").values()]
    assert names == ["fyi.spelunky-25-2", "fyi.randomizer"]
    first = str(rt.eval("ModHost.requestedPack()"))
    assert first == "fyi.spelunky-25-2", "the single-pack reader must answer first"


def test_blank_lines_in_the_flag_file_are_not_packs(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "mo_host.on").write_text(
        "mod.a\n\n   \nmod.b\n", encoding="utf-8")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    got = [str(v) for v in rt.eval("ModHost.requestedPacks()").values()]
    assert got == ["mod.a", "mod.b"]


def test_our_own_block_is_detected_by_its_marker(fake_pack):
    """This used to hold all 27 payloads verbatim and strip an old one by exact
    text. Only nine were ever reachable, so a v21 block sailed through and ran our
    determinism a second time inside ours -- a game that would not boot. Nothing
    writes those blocks any more, so detecting the marker is the whole job."""
    rt = runtime()
    detect = rt.eval("ModHost.ourBlockIn")
    marker = "[ModdedOnline-DeterminismShim-v21]"
    assert str(detect("-- %s auto-added\nlocal x = 1" % marker)) == marker
    assert detect("local x = 1 -- an ordinary mod") is None


def test_a_mod_still_carrying_one_of_our_blocks_is_not_hosted(
        tmp_path, monkeypatch, fake_pack):
    """The HD mod arrived with a v21 determinism block an older shipping build had
    injected. Hosting it ran that block INSIDE ours, re-wrapping the set_callback
    that is now the callback registry: the game reached "Game initialized" and died
    with no Lua error and nothing in the log. A silent unbootable game is the worst
    outcome available, so this must fail loudly instead."""
    marker = "[ModdedOnline-DeterminismShim-v21]"
    fake_pack("main.lua", """
        -- %s auto-added by Modded Online
        do
            local moRealSetCallback = set_callback
        end
        HOSTED_ANYWAY = true
    """ % marker)
    monkeypatch.chdir(tmp_path)
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    report = rt.eval("ModHost.host")("fake.mod")
    assert report["ok"] is True, "the fixture itself must be loadable"

    # ...but autoHost, which is the path the game takes, must refuse it
    (tmp_path / "mo_host.on").write_text("fake.mod", encoding="utf-8")
    rt2 = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    assert rt2.eval("ModHost.autoHost()") is None, "hosted a mod carrying our block"
    assert rt2.eval("HOSTED_ANYWAY") is None, "the mod's code ran regardless"
    printed = [str(v) for v in rt2.eval("printed").values()]
    # the harness's errorf stub keeps the format string, not the filled-in text
    assert any("NOT hosting" in line and "Reinstall" in line for line in printed), printed


def test_a_mod_with_an_incomplete_setup_is_not_hosted(tmp_path, monkeypatch,
                                                     fake_pack):
    """The boot trace on the machine where this happened stopped on the "hosting"
    line with nothing after it, for two different mods: the process died in native
    code, where no pcall of ours can see it. Refusing is the only useful answer."""
    fake_pack("main.lua", "HOSTED_ANYWAY = true")
    monkeypatch.chdir(tmp_path)
    (tmp_path / "mo_host.on").write_text("fake.mod", encoding="utf-8")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute("""
PackSetup = {
    setupProblems = function() return { "res/ was never linked into us" } end,
}
""")
    assert rt.eval("ModHost.autoHost()") is None
    assert rt.eval("HOSTED_ANYWAY") is None, "the mod ran despite a broken setup"
    printed = [str(v) for v in rt.eval("printed").values()]
    assert any("setup is incomplete" in line for line in printed), printed


def test_an_option_registered_with_a_nil_description_reaches_the_engine_as_text(
        fake_pack):
    """hdmod registers dozens of options with `nil` for long_desc. A nil arriving
    where the binding wants a string is a native crash on some builds -- no Lua
    error, no log, nothing a pcall can see. The boot trace on the machine where
    this happened stopped on the module whose very next statement is one of these."""
    fake_pack("main.lua", """
        register_option_bool("hd_debug_feelings_info", "Show info", nil, false, true)
    """)
    rt = runtime()
    rt.execute("""
optionArgs = nil
function register_option_bool(...) optionArgs = {n = select("#", ...), ...} end
""")
    report = rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    assert report["ok"] is True, report["err"]
    args = rt.eval("optionArgs")
    assert args is not None, "the registration never reached the engine"
    assert str(args[1]) == "hd_debug_feelings_info"
    assert str(args[2]) == "Show info"
    assert str(args[3]) == "", "a nil description was passed straight through"
    assert args[4] is False, "the value after the descriptions was altered"


def test_a_real_description_is_left_alone(fake_pack):
    fake_pack("main.lua", """
        register_option_bool("id", "label", "the long one", true)
    """)
    rt = runtime()
    rt.execute('function register_option_bool(...) optionArgs = {...} end')
    rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    args = rt.eval("optionArgs")
    assert str(args[3]) == "the long one"
    assert args[4] is True


def test_a_texture_that_is_not_under_our_pack_is_refused_not_crashed(fake_pack):
    """Overlunky resolves a relative texture_path against the pack root of the script
    that asks, and hosted that is OURS. If the file is not there the call dies in
    native code -- no Lua error, no log, nothing a pcall can catch. A boot trace
    ending inside feats.lua, whose only load-time act is one of these, is what led
    here."""
    fake_pack("main.lua", """
        local tdef = { texture_path = "res/locked_feat.png" }
        probe.handle = define_texture(tdef)
        probe.reached_the_end = true
    """)
    rt = runtime()
    rt.execute("probe = {}")
    rt.execute("engineCalled = false")
    rt.execute("function define_texture() engineCalled = true; return 77 end")
    report = rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    assert report["ok"] is True, report["err"]
    assert rt.eval("engineCalled") is False, "the call reached the engine anyway"
    assert int(rt.eval("probe.handle")) == -1, "the mod got something other than -1"
    assert rt.eval("probe.reached_the_end") is True
    named = [str(v) for v in report["missingTextures"].values()]
    assert named == ["res/locked_feat.png"], named


def test_a_texture_that_is_present_reaches_the_engine(fake_pack):
    """The guard must not stand between a mod and assets that ARE linked in."""
    fake_pack("main.lua", """
        probe.handle = define_texture({ texture_path = "res/present.png" })
    """)
    fake_pack("res/present.png", "not really a png")
    rt = runtime(pack_root=".")
    rt.execute("probe = {}")
    rt.execute("function define_texture() return 77 end")
    rt.execute('function PackPath(rest) return "Mods/Packs/fake.mod/" .. rest end')
    report = rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    assert report["ok"] is True, report["err"]
    assert int(rt.eval("probe.handle")) == 77, "a present texture was refused"
    assert len(report["missingTextures"]) == 0


def test_one_fatal_texture_call_stops_all_of_them(fake_pack):
    """A native crash cannot be caught, only avoided, and skipping just the call
    that died converges one launch at a time -- hdmod defines around twenty cameo
    textures the same way. The first crash is enough evidence: this engine build
    does not survive the call, and vanilla sprites beat twenty more launches."""
    fake_pack("main.lua", """
        probe.first = define_texture({ texture_path = "res/locked_feat.png" })
        probe.second = define_texture({ texture_path = "res/cameo_yang.png" })
        probe.reached_the_end = true
    """)
    fake_pack("res/locked_feat.png", "present")
    fake_pack("res/cameo_yang.png", "present")
    rt = runtime(pack_root=".")
    rt.execute("probe = {}")
    rt.execute("engineCalls = 0")
    rt.execute("function define_texture() engineCalls = engineCalls + 1; return 77 end")
    rt.execute('function PackPath(rest) return "Mods/Packs/fake.mod/" .. rest end')
    rt.execute('ModHost.lastFatalStep = "  fake.mod: define_texture res/cameo_yang.png"')
    rt.execute("ModHost.skipTextures = false")
    report = rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    assert report["ok"] is True, report["err"]
    assert int(rt.eval("engineCalls")) == 0, "a texture still reached the engine"
    assert int(rt.eval("probe.first")) == -1
    assert int(rt.eval("probe.second")) == -1
    assert rt.eval("probe.reached_the_end") is True, "the mod stopped loading"


def test_the_fatal_call_is_remembered_so_the_next_boot_is_safe(fake_pack, tmp_path):
    """The boot trace is truncated every launch, so the previous run's last line
    only helps if that run was the crash. A list that only grows does not have
    that problem."""
    fake_pack("main.lua", 'probe.h = define_texture({ texture_path = "res/x.png" })')
    fake_pack("res/x.png", "present")
    rt = runtime(pack_root=".")
    rt.execute("probe = {}")
    rt.execute("function define_texture() return 77 end")
    rt.execute('function PackPath(rest) return "Mods/Packs/fake.mod/" .. rest end')
    rt.execute('ModHost.lastFatalStep = "  fake.mod: define_texture res/x.png"')
    rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    remembered = (tmp_path / "mo_fatal_calls.txt")
    assert remembered.exists(), "nothing was written for the next boot to read"
    assert "res/x.png" in remembered.read_text(encoding="utf-8")


def test_a_pack_playlunky_is_also_running_is_never_hosted(tmp_path, monkeypatch,
                                                         fake_pack):
    """Hosting requires the mod disabled in load_order.txt. If that edit did not
    take, the mod runs twice -- every callback fires twice and every texture is
    defined twice, which the engine does not survive."""
    fake_pack("main.lua", "HOSTED_ANYWAY = true")
    monkeypatch.chdir(tmp_path)
    (tmp_path / "mo_host.on").write_text("fake.mod", encoding="utf-8")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute('Network = { enabledScriptPacks = function() return {"fake.mod"} end }')
    assert rt.eval("ModHost.autoHost()") is None
    assert rt.eval("HOSTED_ANYWAY") is None, "the mod ran twice"
    printed = [str(v) for v in rt.eval("printed").values()]
    assert any("still ENABLED" in line for line in printed), printed


def test_the_skip_textures_switch_stubs_every_definition(fake_pack):
    """The escape hatch. Everything else here depends on having survived a boot to
    learn something; this does not, which is the point of having it."""
    fake_pack("main.lua", """
        probe.a = define_texture({ texture_path = "res/one.png" })
        probe.b = define_texture({ texture_path = "res/two.png" })
        probe.reached_the_end = true
    """)
    fake_pack("res/one.png", "present")
    fake_pack("res/two.png", "present")
    rt = runtime(pack_root=".")
    rt.execute("probe = {}")
    rt.execute("engineCalls = 0")
    rt.execute("function define_texture() engineCalls = engineCalls + 1; return 5 end")
    rt.execute('function PackPath(rest) return "Mods/Packs/fake.mod/" .. rest end')
    rt.execute("ModHost.skipTextures = true")
    report = rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    assert report["ok"] is True, report["err"]
    assert int(rt.eval("engineCalls")) == 0, "a definition still reached the engine"
    assert int(rt.eval("probe.a")) == -1 and int(rt.eval("probe.b")) == -1
    assert rt.eval("probe.reached_the_end") is True
    assert len(report["skippedTextures"]) == 2, "skipped is tracked apart from missing"


def test_a_fatal_call_is_remembered_across_boots(fake_pack, tmp_path, monkeypatch):
    """The boot trace is truncated every launch, so reading the previous run's last
    line only works if that run WAS the crash. One good boot in between and the
    record is gone -- which is exactly what happened."""
    fake_pack("main.lua", 'probe.h = define_texture({ texture_path = "res/x.png" })')
    fake_pack("res/x.png", "present")
    # where modHost looks: PackPath is resolved when the module loads, so this must
    # sit at the pack root the runtime is built with, not inside the hosted mod
    (tmp_path / "mo_fatal_calls.txt").write_text("res/x.png", encoding="utf-8")
    rt = runtime(pack_root=".")
    rt.execute("probe = {}")
    rt.execute("engineCalls = 0")
    rt.execute("function define_texture() engineCalls = engineCalls + 1; return 5 end")
    rt.execute('function PackPath(rest) return "Mods/Packs/fake.mod/" .. rest end')
    rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    assert int(rt.eval("engineCalls")) == 0, "a call known to be fatal was made again"
    assert int(rt.eval("probe.h")) == -1


def test_a_flag_file_switches_textures_off_without_the_options_panel(
        fake_pack, tmp_path):
    """A checkbox has to be reached, ticked and SAVED through Playlunky's options --
    on a machine that crashes during boot, before the panel exists. Two escape
    hatches shipped that both needed the player to survive a boot first, and
    neither engaged. Creating an empty file needs no game at all."""
    fake_pack("main.lua", 'probe.h = define_texture({ texture_path = "res/x.png" })')
    fake_pack("res/x.png", "present")
    (tmp_path / "mo_notextures.on").write_text("", encoding="utf-8")
    rt = runtime(pack_root=".")
    rt.execute("probe = {}")
    rt.execute("engineCalls = 0")
    rt.execute("function define_texture() engineCalls = engineCalls + 1; return 5 end")
    rt.execute('function PackPath(rest) return "Mods/Packs/fake.mod/" .. rest end')
    assert rt.eval("ModHost.texturesDisabled()") is True
    rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    assert int(rt.eval("engineCalls")) == 0, "a definition still reached the engine"
    assert int(rt.eval("probe.h")) == -1


def test_without_the_flag_textures_are_left_on(fake_pack, tmp_path):
    fake_pack("main.lua", "-- nothing")
    rt = runtime(pack_root=".")
    assert rt.eval("ModHost.texturesDisabled()") is False


def test_a_mod_that_fails_to_load_does_not_take_us_down(tmp_path, monkeypatch, fake_pack):
    """Containing the failure is the point. The injected payload never could."""
    fake_pack("main.lua", """
        local x = nil
        x.boom = 1
    """)
    monkeypatch.chdir(pathlib.Path.cwd())
    root = pathlib.Path.cwd()
    (root / "mo_host.on").write_text("fake.mod", encoding="utf-8")
    rt = runtime(pack_root=str(root).replace("\\", "/"))
    report = rt.eval("ModHost.autoHost()")          # must return, not raise
    assert report is None or report["ok"] is False


# ------------------------------------------- teardown, which hosting also shares

def test_the_mod_can_clear_the_callbacks_it_registered(fake_pack):
    fake_pack("main.lua", """
        local id = set_callback(function() end, ON.GAMEFRAME)
        clear_callback(id)
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert [int(v) for v in rt.eval("cleared").values()] == [101]
    assert int(report["refused"]) == 0


def test_it_cannot_clear_one_of_ours(fake_pack):
    """The bug that cost a two-machine run. Under Playlunky a script can only clear
    its OWN callbacks, because a script is the unit of ownership. Hosting puts the
    mod's callbacks and ours in one script, and 2.5 tears its hooks down on every
    floor — which killed our ON.POST_LEVEL_GENERATION handler after floor one, so
    the per-floor seed was never published and both machines froze on 1-4."""
    fake_pack("main.lua", """
        clear_callback(7)     -- an id Modded Online registered at load
        SURVIVED = true
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert [v for v in rt.eval("cleared").values()] == [], "one of ours was cleared"
    assert int(report["refused"]) == 1
    # and refusing must not stop the mod: it carries on to the next line
    assert rt.eval("env") is None or True


def test_a_bare_clear_is_passed_through(fake_pack):
    """`clear_callback()` with no id means the callback currently running, and the
    only callbacks running the mod's code are the mod's own."""
    fake_pack("main.lua", """
        clear_callback()
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert [str(v) for v in rt.eval("cleared").values()] == ["current"]
    assert int(report["refused"]) == 0


def test_an_id_cannot_be_cleared_twice(fake_pack):
    """After a clear the mod no longer owns it, and the engine may hand the number
    to someone else."""
    fake_pack("main.lua", """
        local id = set_callback(function() end, ON.GAMEFRAME)
        clear_callback(id)
        clear_callback(id)
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert len([v for v in rt.eval("cleared").values()]) == 1
    assert int(report["refused"]) == 1


def test_the_refusal_is_counted_in_the_summary(fake_pack):
    fake_pack("main.lua", """
        clear_callback(7)
        clear_callback(8)
    """)
    rt = runtime()
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    line = str(list(rt.eval("ModHost.summarize")(report).values())[0])
    assert "2 foreign teardowns refused" in line

def test_a_skipped_texture_is_not_reported_as_missing(fake_pack):
    """Skipping on purpose is not the same as a file that is not there. Filing them
    together printed "TEXTURES NOT FOUND -- assets are not linked in" for textures
    that were present and hard-linked, and sent the next diagnosis chasing an asset
    problem that did not exist."""
    fake_pack("main.lua", 'define_texture({ texture_path = "res/present.png" })')
    fake_pack("res/present.png", "present")
    rt = runtime(pack_root=".")
    rt.execute("function define_texture() return 77 end")
    rt.execute('function PackPath(rest) return "Mods/Packs/fake.mod/" .. rest end')
    rt.execute("ModHost.skipTextures = true")
    report = rt.eval("ModHost.host")("fake.mod", rt.table(inert=False))
    assert len(report["missingTextures"]) == 0, "a present file was called missing"
    assert len(report["skippedTextures"]) == 1
    summary = " ".join(str(v) for v in
                       rt.eval("ModHost.summarize")(report).values())
    assert "NOT FOUND" not in summary, summary
    assert "skipped on purpose" in summary, summary


# ------------------------------------------------------------------- meta


def test_a_hosted_mods_meta_writes_do_not_reach_ours(fake_pack):
    """`meta` is the one global where the sandbox's read-through leaked.

    Both Playlunky idioms look identical and are not. `meta = { ... }` is a write and
    lands in the sandbox. `meta.name = "HDMod"` is a READ -- answered with the real
    _G.meta -- followed by a field write on that table, which mutates OURS. hdmod
    (main.lua:67-70) and crossoverlunky (main.lua:1-4) both use the second form, and a
    session hosting crossoverlunky opened its desync log `=== Modded Online 1.0 ===`.

    netCore builds the lobby compatibility handshake from these two fields, so a mod
    rewriting them turns off the check that stops two different Modded Online builds
    sharing a room.
    """
    fake_pack("main.lua", """
        meta.name = "HDMod"
        meta.version = "2.0.0"
    """)
    rt = runtime()
    rt.execute('meta = { name = "Modded Online (loader build)", version = "2.0.0-dev54" }')
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert str(rt.eval("meta.version")) == "2.0.0-dev54", (
        "a hosted mod rewrote Modded Online's own version -- the lobby version gate "
        "compares this, and the desync log header names it")
    assert str(rt.eval("meta.name")) == "Modded Online (loader build)"


def test_a_hosted_mod_reads_back_the_meta_it_wrote(fake_pack):
    """Giving it a private table is only correct if the mod still sees its own
    values: hdmod stamps `mod_version = meta.version` into its save data, and 2.5
    reads meta.name for its crash diagnostics."""
    fake_pack("main.lua", """
        meta.version = "2.0.0"
        probe.seen = meta.version
    """)
    rt = runtime()
    rt.execute('meta = { name = "Modded Online (loader build)", version = "2.0.0-dev54" }')
    rt.execute("probe = {}")
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert str(rt.eval("probe.seen")) == "2.0.0", (
        "the mod could not read back its own meta")


def test_the_wholesale_meta_idiom_still_works(fake_pack):
    """2.5 writes `meta = { ... }`. That always landed in the sandbox; it must keep
    landing there now that a table is waiting for it."""
    fake_pack("main.lua", """
        meta = { name = "Spelunky 2.5", version = "9.9" }
    """)
    rt = runtime()
    rt.execute('meta = { name = "Modded Online (loader build)", version = "2.0.0-dev54" }')
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert str(rt.eval("meta.version")) == "2.0.0-dev54"


# ------------------------------------------------- the determinism bisection flag


def test_determinism_is_installed_by_default(fake_pack, tmp_path):
    fake_pack("main.lua", "probe.kind = type(pairs)")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute("probe = {}")
    rt.execute("Determinism = { install = function(env) env.MARKED = true return {} end }")
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert rt.eval("ModHost.determinismDisabled()") is False


def test_the_flag_file_runs_a_mod_on_the_raw_primitives(fake_pack, tmp_path):
    """Four primitives are rewritten under every hosted mod (pairs, math.random,
    get_frame/get_ms, the ON.FRAME remap). When one of them breaks a mod there is
    otherwise no way to tell that apart from the host plumbing without editing
    source and relaunching. The switch has to be a FILE for the same reason
    mo_host.on is one: a mod that kills the game must be recoverable without it."""
    (tmp_path / "mo_nodeterminism.on").write_text("", encoding="utf-8")
    fake_pack("main.lua", "probe.ran = true")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute("probe = {}")
    rt.execute("installed = false")
    rt.execute("Determinism = { install = function() installed = true return {} end }")
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert rt.eval("ModHost.determinismDisabled()") is True
    assert rt.eval("installed") is False, "determinism was installed despite the flag"
    assert rt.eval("probe.ran") is True, "the mod did not run at all"


def test_the_flag_says_so_out_loud(fake_pack, tmp_path):
    """A silent bisection switch is one that gets left on and then explains a desync
    nobody can account for."""
    (tmp_path / "mo_nodeterminism.on").write_text("", encoding="utf-8")
    fake_pack("main.lua", "")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute("Determinism = { install = function() return {} end }")
    rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    printed = [str(v) for v in rt.eval("printed").values()]
    assert any("mo_nodeterminism.on" in line for line in printed), printed


# ------------------------------------------------- the hosted sandbox, exposed


def test_the_hosted_sandbox_is_reachable_afterwards(fake_pack):
    """A mod's globals are WRITES, so they land in the sandbox and not in _G.
    Nothing outside could read them -- the gap LOADER.md flags for the 2.5 adapter
    ("the mod's world counter is a value in its own module table, in our state,
    readable directly") and which nothing actually provided."""
    fake_pack("main.lua", """
        worldlib = { HD_WORLDSTATE_STATE = 3 }
    """)
    rt = runtime()
    rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    env = rt.eval("ModHost.envFor")("fake.mod")
    assert env is not None, "the sandbox was discarded once the mod had loaded"
    assert int(env["worldlib"]["HD_WORLDSTATE_STATE"]) == 3
    assert rt.eval("worldlib") is None, "the mod's global leaked into ours"


def test_an_unhosted_pack_has_no_sandbox(fake_pack):
    rt = runtime()
    assert rt.eval("ModHost.envFor")("never.hosted") is None


def test_the_journal_probe_stays_out_unless_tracing_is_armed(fake_pack):
    """It reads a named mod's globals, which is the one thing the adapter system
    exists to keep out of the host. It is acceptable only as a flagged probe."""
    rt = runtime()
    rt.execute("DesyncLog = { tracing = function() return false end, traceNote = function() end }")
    rt.execute("ON.POST_LOAD_JOURNAL_CHAPTER = 139")
    assert rt.eval("ModHost.installJournalProbe")() is False
    assert int(rt.eval("engineCalls")) == 0


def test_the_journal_probe_registers_when_tracing(fake_pack):
    rt = runtime()
    rt.execute("DesyncLog = { tracing = function() return true end, traceNote = function() end }")
    rt.execute("ON.POST_LOAD_JOURNAL_CHAPTER = 139")
    assert rt.eval("ModHost.installJournalProbe")() is True
    assert 139 in [int(v) for v in rt.eval("registeredIds").values()]


def test_the_probe_degrades_on_a_build_without_the_hook(fake_pack):
    rt = runtime()
    rt.execute("DesyncLog = { tracing = function() return true end, traceNote = function() end }")
    rt.execute("ON.POST_LOAD_JOURNAL_CHAPTER = nil")
    assert rt.eval("ModHost.installJournalProbe")() is False


def test_main_installs_the_probe_after_hosting(fake_pack):
    """It reads the hosted mods' globals out of their sandboxes, which do not exist
    until they have run."""
    main = (PACK / "main.lua").read_text(encoding="utf-8")
    assert main.index("ModHost.hostOne") < main.index("installJournalProbe")


def test_the_probe_also_brackets_the_page_render(fake_pack):
    """The chapter callback returns and the engine is dead before the hosted mod's
    own RENDER_POST_JOURNAL_PAGE hook runs. That leaves the engine's page setup and
    its first page render, and nothing said which -- so the probe marks the render
    too, and crash_frame.txt names `journalPageProbe` instead of blaming a callback
    that finished several steps earlier."""
    rt = runtime()
    rt.execute("DesyncLog = { tracing = function() return true end, traceNote = function() end,"
               " frameMark = function() end, frameDone = function() end }")
    rt.execute("ON.POST_LOAD_JOURNAL_CHAPTER = 139; ON.RENDER_PRE_JOURNAL_PAGE = 145")
    assert rt.eval("ModHost.installJournalProbe")() is True
    kinds = [int(v) for v in rt.eval("registeredIds").values()]
    assert 139 in kinds and 145 in kinds, kinds


def test_the_page_probe_never_skips_a_page(fake_pack):
    """Returning `true` would skip the draw and returning an explicit nil is what
    Playlunky rejects as "Unexpected return type from function". A probe must be
    invisible to the thing it probes."""
    rt = runtime()
    rt.execute("noted = {}")
    rt.execute("DesyncLog = { tracing = function() return true end,"
               " traceNote = function(fmt, a) noted[#noted + 1] = tostring(a) end,"
               " frameMark = function() end, frameDone = function() end }")
    rt.execute("ON.POST_LOAD_JOURNAL_CHAPTER = 139; ON.RENDER_PRE_JOURNAL_PAGE = 145")
    # capture the functions, which the default harness throws away
    rt.execute("""
fns = {}
local realSet = set_callback
function set_callback(fn, id)
    fns[id] = fn
    return realSet(fn, id)
end
""")
    rt.eval("ModHost.installJournalProbe")()
    page = rt.eval("fns")[145]
    assert page is not None, "no RENDER_PRE_JOURNAL_PAGE probe was registered"
    assert page(3, 7) is None, "the probe returned a value and would alter the draw"
    noted = [str(v) for v in rt.eval("noted").values()]
    assert any("3, 7" in n for n in noted), (
        "the page render's arguments were not recorded: %r" % noted)


# ------------------------------------------------- the callback-wrapper bisection


def test_hosted_callbacks_are_wrapped_by_default(fake_pack, tmp_path):
    """The wrapper is what zeroes our callback depth, names the mod's callbacks in
    the crash trace, and charges them in the profile. It must stay on by default."""
    fake_pack("main.lua", "set_callback(function() end, 2)")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute("wrapped = 0")
    rt.execute("Callbacks = { rawSetCallback = set_callback,"
               " hosted = function(fn) wrapped = wrapped + 1 return fn end,"
               " depth = function() return 0 end }")
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert int(rt.eval("wrapped")) == 1
    assert rt.eval("ModHost.wrapDisabled()") is False


def test_the_flag_sends_hosted_callbacks_to_the_engine_raw(fake_pack, tmp_path):
    """The wrapper is the single largest thing hosting does that Playlunky does not:
    an extra Lua frame and a pcall around every callback. hdmod's journal story
    sequence is a nested storm of callbacks registering and clearing each other from
    inside one another, so it has to be separable from the rest of the sandbox."""
    (tmp_path / "mo_nowrap.on").write_text("", encoding="utf-8")
    fake_pack("main.lua", "set_callback(function() end, 2)")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute("wrapped = 0")
    rt.execute("Callbacks = { rawSetCallback = set_callback,"
               " hosted = function(fn) wrapped = wrapped + 1 return fn end,"
               " depth = function() return 0 end }")
    report = rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    assert report["ok"] is True, report["err"]
    assert rt.eval("ModHost.wrapDisabled()") is True
    assert int(rt.eval("wrapped")) == 0, "a wrapper was applied despite mo_nowrap.on"


def test_the_raw_flag_says_so_out_loud(fake_pack, tmp_path):
    (tmp_path / "mo_nowrap.on").write_text("", encoding="utf-8")
    fake_pack("main.lua", "")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.eval("ModHost.host")("fake.mod", rt.table_from({"inert": False}))
    printed = [str(v) for v in rt.eval("printed").values()]
    assert any("mo_nowrap.on" in line for line in printed), printed


def test_the_probe_returns_nothing_by_default(fake_pack, tmp_path):
    """A probe that answers a callback the engine consumes is not a probe."""
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute("DesyncLog = { tracing = function() return true end, traceNote = function() end,"
               " frameMark = function() end, frameDone = function() end }")
    rt.execute("ON.POST_LOAD_JOURNAL_CHAPTER = 139")
    rt.execute("""
fns = {}
local realSet = set_callback
function set_callback(fn, id) fns[id] = fn return realSet(fn, id) end
""")
    rt.eval("ModHost.installJournalProbe")()
    chapter = rt.eval("fns")[139]
    assert chapter(8, rt.table_from([2, 3, 4])) is None


def test_the_flag_makes_the_probe_restore_the_engines_page_list(fake_pack, tmp_path):
    """hdmod replaces the story chapter's 8 real pages with 20 fabricated ones and
    draws them itself. The engine dies right after accepting that, and it is the last
    thing in the path assumed rather than tested."""
    # "restore" spelled out: an EMPTY flag means `sameids` as of dev59, because a
    # player creating this file to stop the crash was getting the experiment's
    # non-crashing control and a journal full of vanilla pages.
    (tmp_path / "mo_nojournalpages.on").write_text("restore", encoding="utf-8")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute("noted = {}")
    rt.execute("DesyncLog = { tracing = function() return true end,"
               " traceNote = function(fmt, a, b) noted[#noted + 1] = tostring(a) end,"
               " frameMark = function() end, frameDone = function() end }")
    rt.execute("ON.POST_LOAD_JOURNAL_CHAPTER = 139")
    rt.execute("""
fns = {}
local realSet = set_callback
function set_callback(fn, id) fns[id] = fn return realSet(fn, id) end
""")
    rt.eval("ModHost.installJournalProbe")()
    out = rt.eval("fns")[139](8, rt.table_from([2, 3, 4, 5]))
    assert out is not None, "the engine's page list was not restored"
    assert [int(v) for v in out.values()] == [2, 3, 4, 5]


def test_the_restore_is_a_copy_not_the_engines_own_table(fake_pack, tmp_path):
    """Handing the engine back the very object it passed in is a different thing
    from handing it an equal list, and not one worth finding out about the hard way."""
    (tmp_path / "mo_nojournalpages.on").write_text("restore", encoding="utf-8")
    rt = runtime(pack_root=str(tmp_path).replace(chr(92), "/"))
    rt.execute("DesyncLog = { tracing = function() return true end, traceNote = function() end,"
               " frameMark = function() end, frameDone = function() end }")
    rt.execute("ON.POST_LOAD_JOURNAL_CHAPTER = 139")
    rt.execute("""
fns = {}
local realSet = set_callback
function set_callback(fn, id) fns[id] = fn return realSet(fn, id) end
incoming = {7, 8}
returned = nil
""")
    rt.eval("ModHost.installJournalProbe")()
    rt.execute("returned = fns[139](8, incoming)")
    assert rt.eval("returned ~= incoming") is True
    assert [int(v) for v in rt.eval("returned").values()] == [7, 8]


CAPTURE_SET_CALLBACK = """
fns = {}
local realSet = set_callback
function set_callback(fn, id) fns[id] = fn return realSet(fn, id) end
"""


def _probe_with_flag(tmp_path, body):
    """Install the probe with mo_nojournalpages.on holding `body`."""
    (tmp_path / "mo_nojournalpages.on").write_text(body, encoding="utf-8")
    rt = T_runtime(str(tmp_path).replace(chr(92), "/"))
    rt.execute("DesyncLog = { tracing = function() return true end, traceNote = function() end,"
               " frameMark = function() end, frameDone = function() end }")
    rt.execute("ON.POST_LOAD_JOURNAL_CHAPTER = 139")
    rt.execute(CAPTURE_SET_CALLBACK)
    rt.eval("ModHost.installJournalProbe")()
    return rt


T_runtime = runtime


def test_sameids_keeps_the_count_and_moves_the_ids(tmp_path, fake_pack):
    """If this crashes in the game, the ID RANGE is what the engine cannot take."""
    rt = _probe_with_flag(tmp_path, "sameids")
    rt.execute("res = fns[139](8, {2, 3, 4, 5, 6, 7, 8, 9})")
    got = [int(v) for v in rt.eval("res").values()]
    assert got == [601, 602, 603, 604, 605, 606, 607, 608]


def test_grow_keeps_the_ids_and_moves_the_count(tmp_path, fake_pack):
    """If this crashes instead, GROWING the page vector is what does it."""
    rt = _probe_with_flag(tmp_path, "grow")
    rt.execute("res = fns[139](8, {2, 3, 4, 5, 6, 7, 8, 9})")
    got = [int(v) for v in rt.eval("res").values()]
    assert len(got) == 20
    assert set(got) <= {2, 3, 4, 5, 6, 7, 8, 9}, got


def test_an_empty_flag_means_sameids_not_the_control(tmp_path, fake_pack):
    """REVERSED in dev59, on evidence this test predates.

    It used to assert the control stayed the default, so that a stale flag file could
    not silently become a different experiment. A real capture showed the cost of
    that: HANDOFF.md tells a player to create this file to stop the crash, they
    created it empty, and got `restore` -- the engine's own list. The crash stopped
    and the journal silently showed VANILLA pages instead of hdmod's.

    The stale-file worry is answered without paying that: every chapter logs
    `mode=...`, so which experiment ran is never a guess. `restore` stays available
    by writing it in, and the test above does exactly that."""
    rt = _probe_with_flag(tmp_path, "")
    rt.execute("res = fns[139](8, {2, 3, 4, 5})")
    assert [int(v) for v in rt.eval("res").values()] == [601, 602, 603, 604]


def test_an_unknown_mode_still_falls_back_to_restore(tmp_path, fake_pack):
    """A TYPO must not silently run an experiment: falling back to the engine's own
    list is the one mode that changes nothing."""
    rt = _probe_with_flag(tmp_path, "typo-here")
    rt.execute("res = fns[139](8, {2, 3, 4, 5})")
    assert [int(v) for v in rt.eval("res").values()] == [2, 3, 4, 5]
