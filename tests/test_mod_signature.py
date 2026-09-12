"""Tests for the mod-compatibility signature and the mismatch report.

A rejection used to read `Mods don't match the room (host runs: 1 scripts/199
files/19f26e1d)` and that was the whole story: two players with the same mod and
the same 199 files had no way to find out which of the four inputs to that digest
had actually moved. The signature is per-pack and field-wise now, and these lock
down that a rejection names the real difference.

Run:  python -m pytest tests/test_mod_signature.py -q
"""

from __future__ import annotations

import contextlib
import os
import pathlib
import shutil
import tempfile

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent


@contextlib.contextmanager
def sandbox():
    here = os.getcwd()
    path = tempfile.mkdtemp()
    try:
        yield pathlib.Path(path)
    finally:
        os.chdir(here)
        shutil.rmtree(path, ignore_errors=True)


ENV = """
meta = { version = "1.0.5" }
ON = { GUIFRAME = 1 }
function set_callback() end
function dbg() end
function dbgf() end
errors = {}
function errorf(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
function SafeCall(_, fn, ...) return fn(...) end
function get_ms() return 0 end
function toast() end
function PackDir() return "fyi.modded-online" end
function PackPath(rest) return "Mods/Packs/fyi.modded-online/" .. rest end
function PackPathWin(rest) return (PackPath(rest):gsub("/", "\\\\")) end
"""


def make_pack(root: pathlib.Path, name: str, files, marker="[ModdedOnline-DeterminismShim-v19]"):
    """A minimal script pack: main.lua carrying a shim marker, plus `files`."""
    packs = root / "Mods" / "Packs"
    (packs / name).mkdir(parents=True, exist_ok=True)
    (packs / name / "main.lua").write_text("-- %s\nlocal x = 1\n" % marker, encoding="utf-8")
    for rel in files:
        path = packs / name / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("return {}\n", encoding="utf-8")


def load_net_core(root: pathlib.Path, enabled):
    os.chdir(root)
    packs = root / "Mods" / "Packs"
    packs.mkdir(parents=True, exist_ok=True)
    (packs / "load_order.txt").write_text("\n".join(enabled) + "\n", encoding="utf-8")
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(ENV)
    lua.execute((PACK / "src" / "json.lua").read_text(encoding="utf-8"))
    lua.execute((PACK / "src" / "netCore.lua").read_text(encoding="utf-8"))
    return lua


def signature(lua) -> str:
    return lua.eval("Network.modSignature()")


def describe(lua, theirs):
    lua.execute('short, detail = Network.describeModMismatch("%s")' % theirs)
    lines = lua.eval("detail")
    return lua.eval("short"), [lines[i] for i in range(1, len(lines) + 1)]


def test_signature_is_per_pack_and_readable():
    with sandbox() as root:
        make_pack(root, "fyi.hdmod", ["lib/a.lua", "lib/b.lua"])
        lua = load_net_core(root, ["fyi.hdmod", "fyi.modded-online"])
        lua.execute('short, detail = Network.describeModMismatch("1.0.5 + other:1:00000000:v19")')
        detail = lua.eval("detail")
        joined = "\n".join(detail[i] for i in range(1, len(detail) + 1))
        assert "fyi.hdmod" in joined


def test_reports_a_differently_named_folder_as_a_rename():
    """Same mod, same files, different folder name — the case that produced the
    'same 199 files, different hash' report."""
    with sandbox() as root:
        make_pack(root, "fyi.hdmod", ["lib/a.lua", "lib/b.lua"])
        lua = load_net_core(root, ["fyi.hdmod", "fyi.modded-online"])
        # the room's entry: same file count and hash, different folder name
        entry = signature(lua)
        name, rest = entry.split(":", 1)
        theirs = "1.0.5 + HDmod-1.3.1:" + rest
        short, detail = describe(lua, theirs)
        joined = "\n".join(detail)
        assert "same mod" in joined
        assert "HDmod-1.3.1" in joined
        assert "rename" in joined.lower()


def test_reports_a_different_mod_version_by_file_count():
    with sandbox() as root:
        make_pack(root, "fyi.hdmod", ["lib/a.lua", "lib/b.lua"])
        lua = load_net_core(root, ["fyi.hdmod", "fyi.modded-online"])
        short, detail = describe(lua, "1.0.5 + fyi.hdmod:57:deadbeef:v19")
        joined = "\n".join(detail)
        assert "different VERSION" in joined
        assert "57" in joined


def test_reports_an_unfinished_patch():
    """The rollout case: one player has restarted since updating and one has not."""
    with sandbox() as root:
        make_pack(root, "fyi.hdmod", ["lib/a.lua", "lib/b.lua"])
        lua = load_net_core(root, ["fyi.hdmod", "fyi.modded-online"])
        name, files, hashed, _shim = signature(lua).split(":")
        theirs = "1.0.5 + %s:%s:%s:v19+optv1" % (name, files, hashed)
        short, detail = describe(lua, theirs)
        joined = "\n".join(detail)
        assert "patched differently" in joined
        assert "start the game once more" in joined


def test_reports_an_extra_and_a_missing_pack():
    with sandbox() as root:
        make_pack(root, "fyi.hdmod", ["lib/a.lua"])
        lua = load_net_core(root, ["fyi.hdmod", "fyi.modded-online"])
        short, detail = describe(lua, "1.0.5 + fyi.randomizer:9:0badf00d:v19")
        joined = "\n".join(detail)
        assert "you do not" in joined and "fyi.randomizer" in joined
        assert "the room does not" in joined and "fyi.hdmod" in joined


def test_reports_a_modded_online_version_difference_first():
    with sandbox() as root:
        make_pack(root, "fyi.hdmod", ["lib/a.lua"])
        lua = load_net_core(root, ["fyi.hdmod", "fyi.modded-online"])
        short, detail = describe(lua, "1.0.4 + fyi.hdmod:1:00000000:v19")
        assert "Modded Online itself differs" in detail[0]
        assert len(detail) == 1


def test_same_files_different_contents_is_not_called_a_rename():
    with sandbox() as root:
        make_pack(root, "fyi.hdmod", ["lib/a.lua", "lib/b.lua"])
        lua = load_net_core(root, ["fyi.hdmod", "fyi.modded-online"])
        mine = signature(lua)
        name, files, _hash, shim = mine.split(":")
        short, detail = describe(lua, "1.0.5 + %s:%s:aaaaaaaa:%s" % (name, files, shim))
        joined = "\n".join(detail)
        assert "not the same files" in joined


def test_our_own_pack_is_never_in_the_signature():
    with sandbox() as root:
        make_pack(root, "fyi.hdmod", ["lib/a.lua"])
        make_pack(root, "fyi.modded-online", ["src/netCore.lua"])
        lua = load_net_core(root, ["fyi.hdmod", "fyi.modded-online"])
        assert "fyi.modded-online" not in signature(lua)


def test_folder_name_is_not_baked_into_the_file_hash():
    """Two installs of one mod under different names must produce the same hash,
    which is what makes the rename detection above possible at all."""
    hashes = []
    for name in ["fyi.hdmod", "HDmod-1.3.1"]:
        with sandbox() as root:
            make_pack(root, name, ["lib/a.lua", "lib/sub/b.lua"])
            lua = load_net_core(root, [name, "fyi.modded-online"])
            hashes.append(signature(lua).split(":")[2])
    assert hashes[0] == hashes[1]
