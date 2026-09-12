"""Tests that a hosted mod counts as a mod in play.

The compatibility signature exists to prove two machines are running the same content
mods, and it was built by walking `load_order.txt`. Hosting breaks that assumption:
a hosted mod is *disabled* in that file — that is precisely what stops Playlunky
loading it a second time — so the mod we are actually running became invisible to the
check meant to police it.

Left alone, two players on different builds of the same hosted mod would have matched
and been allowed to play, then desynced for a reason with nothing to do with the
loader. That is the worst shape a bug can take here: it makes every other test lie.

Run:  python -m pytest tests/test_hosted_signature.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
NET_CORE = (PACK / "src" / "netCore.lua").read_text(encoding="utf-8")
MOD_HOST = (PACK / "src" / "modHost.lua").read_text(encoding="utf-8")


def runtime(load_order: list[str], hosted: list[str]):
    """netCore's pack-listing functions over a fake load_order and a fake host."""
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("lines = {}")
    push = rt.eval("function(s) lines[#lines + 1] = s end")
    for line in load_order:
        push(line)
    rt.execute("""
function io_lines_stub()
    local i = 0
    return function()
        i = i + 1
        return lines[i]
    end
end
function PackDir() return "fyi.modded-online-loader" end
""")
    rt.execute("hostedPacks = {}")
    push_hosted = rt.eval("function(s) hostedPacks[#hostedPacks + 1] = s end")
    for name in hosted:
        push_hosted(name)
    rt.execute("ModHost = { hostedPacks = function() return hostedPacks end }")

    # only the two listing functions are needed, lifted from the real file so the
    # test cannot drift from the implementation
    start = NET_CORE.index("--- The enabled SCRIPT packs")
    end = NET_CORE.index("--- One script pack's persisted OPTIONS")
    body = NET_CORE[start:end]
    body = body.replace("io.lines(LOAD_ORDER_PATH)", "io_lines_stub()")
    # every listed pack "has" a main.lua in this test
    body = body.replace('local script = io.open("Mods/Packs/" .. line .. "/main.lua", "r")',
                        "local script = FAKE_MAIN")
    body = body.replace("script:close()", "local _ = script")
    rt.execute("FAKE_MAIN = {}\nlocal module = {}\n" + body + "\nNet = module")
    return rt


ORDER = [
    "fyi.modded-online-loader",
    "--fyi.spelunky-25-2",      # disabled, because we host it
    "SomeTexturePack",
    "--fyi.hdmod",              # disabled and not hosted: genuinely not in play
]


def test_the_load_order_walk_alone_misses_the_hosted_mod():
    """The bug, stated as a test: this is what the signature used to be built on."""
    rt = runtime(ORDER, hosted=["fyi.spelunky-25-2"])
    enabled = [str(v) for v in rt.eval("Net.enabledScriptPacks()").values()]
    assert "fyi.spelunky-25-2" not in enabled


def test_the_synced_list_includes_it():
    rt = runtime(ORDER, hosted=["fyi.spelunky-25-2"])
    names = [str(v) for v in rt.eval("(Net.syncedScriptPacks())").values()]
    assert "fyi.spelunky-25-2" in names
    assert "SomeTexturePack" in names


def test_a_disabled_mod_that_is_not_hosted_stays_out():
    """Disabled and unhosted means not running, and it must not join the key."""
    rt = runtime(ORDER, hosted=["fyi.spelunky-25-2"])
    names = [str(v) for v in rt.eval("(Net.syncedScriptPacks())").values()]
    assert "fyi.hdmod" not in names


def test_a_hosted_mod_is_marked_as_hosted():
    """A machine running a mod inside our state and a machine letting Playlunky run
    it with an injected payload are not the same execution model, so the signature
    must not treat them as interchangeable."""
    rt = runtime(ORDER, hosted=["fyi.spelunky-25-2"])
    flags = rt.eval("select(2, Net.syncedScriptPacks())")
    assert flags["fyi.spelunky-25-2"] is True
    assert flags["SomeTexturePack"] is None


def test_no_duplicate_when_a_pack_is_somehow_both():
    rt = runtime(["fyi.modded-online-loader", "fyi.spelunky-25-2"],
                 hosted=["fyi.spelunky-25-2"])
    names = [str(v) for v in rt.eval("(Net.syncedScriptPacks())").values()]
    assert names.count("fyi.spelunky-25-2") == 1


def test_nothing_hosted_leaves_the_old_behaviour_exactly():
    rt = runtime(ORDER, hosted=[])
    names = [str(v) for v in rt.eval("(Net.syncedScriptPacks())").values()]
    enabled = [str(v) for v in rt.eval("Net.enabledScriptPacks()").values()]
    assert names == enabled


def test_our_own_pack_is_still_left_out():
    """Folding ourselves in made our FOLDER NAME part of the compatibility key, and
    publishing the pack under a different name rejected identical builds."""
    rt = runtime(ORDER, hosted=["fyi.spelunky-25-2"])
    names = [str(v) for v in rt.eval("(Net.syncedScriptPacks())").values()]
    assert "fyi.modded-online-loader" not in names


def test_a_failed_host_is_not_claimed_as_running():
    """If hosting failed here and worked there, the signatures SHOULD differ."""
    rt = runtime(ORDER, hosted=[])
    names = [str(v) for v in rt.eval("(Net.syncedScriptPacks())").values()]
    assert "fyi.spelunky-25-2" not in names


def test_only_a_successful_host_is_recorded():
    """modHost's side of the same rule."""
    assert "if report.ok then" in MOD_HOST
    at = MOD_HOST.index("if report.ok then")
    assert "hosted[#hosted + 1] = packDir" in MOD_HOST[at:at + 120]


def test_both_callers_ask_for_the_synced_list():
    """Compatibility is a question about what code is RUNNING, not what is enabled.

    There were three callers; optionSync was the third and is gone with the shim
    that applied what it published."""
    assert "for _, packName in ipairs(module.syncedScriptPacks()) do" in NET_CORE
    assert "local names, isHosted = module.syncedScriptPacks()" in NET_CORE
    # and the signature no longer walks load_order itself
    at = NET_CORE.index("local function loadOrderSignature()")
    body = NET_CORE[at:NET_CORE.index("modSignature = #entries > 0", at)]
    assert "io.lines(LOAD_ORDER_PATH)" not in body
