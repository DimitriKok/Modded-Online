"""Our own folder, found from the file the engine loaded.

Until dev82 the pack was found only by searching load_order.txt for a folder that
holds src/modHost.lua directly. Unpack a download into Mods/Packs one folder too deep
(Mods/Packs/<zip name>/<folder in the zip>/main.lua) and Playlunky still runs the mod,
while every path of ours pointed at a folder that is not there: config.json could not
be written, so the first-run popups came back on every launch, and Python was handed
a bridge script that did not exist ("the bridge did not start"). A Linux tester saw
exactly that pair.

Run:  python -m pytest tests/test_pack_root.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

import test_python_detect as detect

PACK = pathlib.Path(__file__).resolve().parent.parent
UTIL = (PACK / "src" / "util.lua").read_text(encoding="utf-8")


def make(tmp_path, rel: str) -> None:
    """Our files at Mods/Packs/<rel>: just what the search looks for."""
    root = tmp_path / "Mods" / "Packs" / rel
    (root / "src").mkdir(parents=True)
    (root / "src" / "modHost.lua").write_text("-- fingerprint\n", encoding="utf-8")
    (root / "src" / "util.lua").write_text(UTIL, encoding="utf-8")


def load(tmp_path, monkeypatch, chunkname: str | None, load_order=("",)):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "Mods" / "Packs").mkdir(parents=True, exist_ok=True)
    (tmp_path / "Mods" / "Packs" / "load_order.txt").write_text("\n".join(load_order) + "\n",
                                                                 encoding="utf-8")
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("function print() end; function get_ms() return 0 end")
    if chunkname is None:
        rt.execute(UTIL)  # loaded as a string: nothing to read a path from
    else:
        rt.eval("function(src, name) assert(load(src, name))() end")(UTIL, chunkname)
    return rt


def test_a_pack_unpacked_one_folder_deep_is_found_where_it_is(tmp_path, monkeypatch):
    make(tmp_path, "Modded-Online-main/Modded-Online")
    rt = load(tmp_path, monkeypatch, "@Mods/Packs/Modded-Online-main/Modded-Online/src/util.lua",
              load_order=["Modded-Online-main"])
    assert rt.eval("PackDir()") == "Modded-Online-main"
    assert rt.eval("PackPath('config.json')") == "Mods/Packs/Modded-Online-main/Modded-Online/config.json"
    assert rt.eval("PackPathWin('server/client_bridge.py')") == \
        "Mods\\Packs\\Modded-Online-main\\Modded-Online\\server\\client_bridge.py"
    assert rt.eval("PackRootPath()") == "Mods/Packs/Modded-Online-main/Modded-Online"


def test_a_pack_installed_normally_resolves_as_it_always_did(tmp_path, monkeypatch):
    make(tmp_path, "fyi.modded-online")
    rt = load(tmp_path, monkeypatch, "@Mods/Packs/fyi.modded-online/src/util.lua",
              load_order=["fyi.spelunky-25-2", "fyi.modded-online"])
    assert rt.eval("PackDir()") == "fyi.modded-online"
    assert rt.eval("PackPath('config.json')") == "Mods/Packs/fyi.modded-online/config.json"


def test_windows_separators_in_the_name_are_read_too(tmp_path, monkeypatch):
    make(tmp_path, "fyi.modded-online")
    rt = load(tmp_path, monkeypatch, "@Mods/Packs\\fyi.modded-online\\src\\util.lua")
    assert rt.eval("PackPath('config.json')") == "Mods/Packs/fyi.modded-online/config.json"


def test_it_does_not_need_load_order_txt(tmp_path, monkeypatch):
    make(tmp_path, "Some Other Name")
    rt = load(tmp_path, monkeypatch, "@Mods/Packs/Some Other Name/src/util.lua", load_order=[])
    assert rt.eval("PackDir()") == "Some Other Name"


def test_without_a_file_name_the_load_order_search_still_works(tmp_path, monkeypatch):
    make(tmp_path, "fyi.modded-online")
    rt = load(tmp_path, monkeypatch, None, load_order=["fyi.modded-online"])
    assert rt.eval("PackPath('config.json')") == "Mods/Packs/fyi.modded-online/config.json"


def test_a_name_that_does_not_check_out_is_not_believed(tmp_path, monkeypatch):
    """The fingerprint must be there: a path that merely looks right is not enough."""
    make(tmp_path, "fyi.modded-online")
    rt = load(tmp_path, monkeypatch, "@Mods/Packs/elsewhere/src/util.lua",
              load_order=["fyi.modded-online"])
    assert rt.eval("PackDir()") == "fyi.modded-online"


# -------------------------------------------- saying so when a path is wrong anyway

@pytest.fixture
def net(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "Mods" / "Packs").mkdir(parents=True)
    (tmp_path / "Mods" / "Packs" / "load_order.txt").write_text("fyi.modded-online\n", encoding="utf-8")
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(detect.ENV)
    rt.execute((PACK / "src" / "json.lua").read_text(encoding="utf-8"))
    rt.execute((PACK / "src" / "netCore.lua").read_text(encoding="utf-8"))
    rt.execute(detect.MACHINE)
    rt.eval("function(k, v) envVars[k] = v end")("WINDIR", "C:\\windows")
    rt.eval("function(p) files[p] = true end")("C:\\windows\\py.exe")
    return rt


def test_settings_that_cannot_be_saved_are_said_once(net):
    """The pack folder is missing here, so config.json cannot be created."""
    net.execute("Network.saveConfig(); Network.saveConfig()")
    said = [s for s in detect.said(net) if "could not save" in s]
    assert len(said) == 1, said
    assert "Mods/Packs/fyi.modded-online/config.json" in said[0]
    assert "first-run popups" in said[0]


def test_a_missing_bridge_script_is_named_instead_of_launched(net):
    assert net.eval("Network.launchBridge")("203.0.113.7", 26000) is False
    assert not any(c.startswith("start ") for c in detect.ran(net)), "launched anyway"
    assert "Mods/Packs/fyi.modded-online/server/client_bridge.py" in str(net.eval("Network.lastError"))
    assert any("cannot start connection bridge" in s for s in detect.said(net))


def test_a_missing_server_script_is_named_instead_of_launched(net):
    assert net.eval("Network.launchLocalServer")() is False
    assert not any(c.startswith("start ") for c in detect.ran(net))
    assert "server/server.py" in str(net.eval("Network.lastError"))


def test_settings_survive_the_pack_folder_being_replaced(tmp_path, monkeypatch):
    """A fresh download unpacked over the old folder takes config.json with it."""
    def boot():
        rt = lupa.LuaRuntime(unpack_returned_tuples=True)
        rt.execute(detect.ENV)
        rt.execute((PACK / "src" / "json.lua").read_text(encoding="utf-8"))
        rt.execute((PACK / "src" / "netCore.lua").read_text(encoding="utf-8"))
        return rt
    monkeypatch.chdir(tmp_path)
    pack = tmp_path / "Mods" / "Packs" / "fyi.modded-online"
    pack.mkdir(parents=True)
    (tmp_path / "Mods" / "Packs" / "load_order.txt").write_text("fyi.modded-online\n", encoding="utf-8")
    rt = boot()
    rt.execute("Network.config.firstRunDone = true; Network.config.playerName = 'Ana'; Network.saveConfig()")
    assert (pack / "config.json").exists() and (tmp_path / "modded_online_settings.json").exists()
    (pack / "config.json").unlink()  # the new build's folder has none
    rt = boot()
    assert rt.eval("Network.config.firstRunDone") is True
    assert rt.eval("Network.config.playerName") == "Ana"


def test_the_packs_own_settings_win_over_the_copy(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    pack = tmp_path / "Mods" / "Packs" / "fyi.modded-online"
    pack.mkdir(parents=True)
    (tmp_path / "Mods" / "Packs" / "load_order.txt").write_text("fyi.modded-online\n", encoding="utf-8")
    (pack / "config.json").write_text('{"playerName":"Pack"}', encoding="utf-8")
    (tmp_path / "modded_online_settings.json").write_text('{"playerName":"Copy"}', encoding="utf-8")
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(detect.ENV)
    rt.execute((PACK / "src" / "json.lua").read_text(encoding="utf-8"))
    rt.execute((PACK / "src" / "netCore.lua").read_text(encoding="utf-8"))
    assert rt.eval("Network.config.playerName") == "Pack"
