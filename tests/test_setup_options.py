"""The per-mod checkboxes in Playlunky's options panel (src/setupUI.lua).

Every installed script pack gets a "Play <pack> online" checkbox. They used to carry
the same long paragraph each, which filled the panel; the label says what the box
does, and the restart it needs is printed when it is ticked. The two entries that
are NOT per mod -- the texture escape hatch and the undo button -- keep theirs,
because they say when to use them.

These run the shipped module's install() against a stubbed PackSetup and record
exactly what reaches Playlunky.

Run:  python -m pytest tests/test_setup_options.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
SETUP_UI = (PACK / "src" / "setupUI.lua").read_text(encoding="utf-8")

PACKS = ["fyi.co-op-shared-camera", "fyi.hdmod", "fyi.randomizer"]

ENV = """
registered = {}
local function record(kind)
    return function(...)
        local a = { ... }
        registered[#registered + 1] = {
            kind = kind, n = select("#", ...), name = a[1], desc = a[2], long = a[3], value = a[4],
        }
    end
end
register_option_bool = record("bool")
register_option_button = record("button")
ON = { GUIFRAME = 100 }
function set_callback() return 1 end
function print() end
function key(name) return "mo_host_" .. name:gsub("[^%w]", "_") end
PackSetup = {
    selection = function() return { "fyi.hdmod" } end,
    installedScriptPacks = function()
        return { "fyi.co-op-shared-camera", "fyi.hdmod", "fyi.randomizer" }
    end,
    optionKey = key,
    migrate = function() return {} end,
    hasLeftovers = function() return false end,
    clear = function() return { changed = {}, steps = {} } end,
    setupProblems = function() return {} end,
    apply = function() error("install() re-applied a selection that had not changed") end,
}
options = { [key("fyi.hdmod")] = true }
"""


def installed():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(SETUP_UI)
    rt.eval("SetupUI.install")()
    out = []
    for i in range(1, int(rt.eval("#registered")) + 1):
        out.append({k: rt.eval("registered[%d].%s" % (i, k))
                    for k in ("kind", "n", "name", "desc", "long", "value")})
    return out


def per_mod(entries):
    return [e for e in entries if str(e["desc"]).startswith("Play ")]


def test_every_installed_mod_gets_a_checkbox_with_no_description():
    mods = per_mod(installed())
    assert [str(e["desc"]) for e in mods] == ["Play %s online" % p for p in PACKS]
    for e in mods:
        assert e["kind"] == "bool"
        assert e["long"] == "", "a per-mod checkbox still carries a description: %r" % e["long"]


def test_the_description_is_an_empty_string_not_nil():
    """A nil where Playlunky's binding wants a string is a native crash on some
    builds (modHost.lua, withOptionStrings). So the description is passed, empty,
    in the same four-argument call that is known to work."""
    for e in per_mod(installed()):
        assert e["n"] == 4 and isinstance(e["long"], str)


def test_the_boxes_still_start_as_what_is_armed_on_disk():
    values = {str(e["desc"]): e["value"] for e in per_mod(installed())}
    assert values == {
        "Play fyi.co-op-shared-camera online": False,
        "Play fyi.hdmod online": True,
        "Play fyi.randomizer online": False,
    }


def test_the_two_entries_that_are_not_per_mod_keep_their_descriptions():
    by_name = {str(e["name"]): e for e in installed()}
    assert "crashes on startup" in str(by_name["mo_skip_textures"]["long"])
    assert "Unlink every hosted mod" in str(by_name["mo_setup_clear"]["long"])


# ---------------------------------------------- asking for a restart (menuUI)

RESTART_ENV = """
restartAsked = 0
NetMenuUI = { showRestartNotice = function() restartAsked = restartAsked + 1 end }
guiframe = nil
function set_callback(fn, _) guiframe = fn return 1 end
PackSetup.apply = function(wanted)
    return { notes = {}, changed = {}, steps = {}, accepted = wanted, deferred = false }
end
"""


def restart_runtime():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(ENV)
    rt.execute(RESTART_ENV)
    rt.execute(SETUP_UI)
    return rt


def test_nothing_changed_asks_for_nothing():
    rt = restart_runtime()
    rt.eval("SetupUI.install")()
    for _ in range(60):
        rt.execute("guiframe()")
    assert int(rt.eval("restartAsked")) == 0


def test_ticking_a_mod_asks_for_a_restart():
    rt = restart_runtime()
    rt.eval("SetupUI.install")()
    rt.execute('options[key("fyi.randomizer")] = true')
    for _ in range(60):
        rt.execute("guiframe()")
    assert int(rt.eval("restartAsked")) == 1


def test_unticking_one_asks_too():
    rt = restart_runtime()
    rt.eval("SetupUI.install")()
    rt.execute('options[key("fyi.hdmod")] = false')
    for _ in range(60):
        rt.execute("guiframe()")
    assert int(rt.eval("restartAsked")) == 1


def test_a_change_made_last_session_asks_at_boot():
    """A tick that was never applied (the game was closed from the options panel)
    is applied at the next boot, and that needs a restart of its own."""
    rt = restart_runtime()
    rt.execute('options[key("fyi.randomizer")] = true')
    rt.eval("SetupUI.install")()
    assert int(rt.eval("restartAsked")) == 1


def test_undoing_the_setup_asks_for_a_restart():
    rt = restart_runtime()
    rt.eval("SetupUI.install")()
    undo = [i for i in range(1, int(rt.eval("#registered")) + 1)
            if str(rt.eval("registered[%d].name" % i)) == "mo_setup_clear"]
    assert len(undo) == 1
    rt.execute("registered[%d].value()" % undo[0])
    assert int(rt.eval("restartAsked")) == 1
