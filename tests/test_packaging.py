"""The zip must carry the mod, and none of this machine's setup.

`--package` and `src/packSetup.lua` used to keep separate lists of the files the setup
creates. They drifted the moment packSetup began carrying `savegame.sav`,
`mod_info.json` and the string mods across: the zip kept excluding the old three and
shipped the new ones. That zip then took one machine's hdmod arrangement to another,
where the `image_map` pointed at a `res` folder that was not there -- Playlunky crashed
slicing sprites out of missing images, at boot, before any Lua ran, so there was
nothing in the log to say why.

The lists are one list now. These tests hold them together.

Run:  python -m pytest tests/test_packaging.py -q
"""

from __future__ import annotations

import importlib.util
import pathlib

import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
PACK_SETUP = (PACK / "src" / "packSetup.lua").read_text(encoding="utf-8")


def spike2():
    spec = importlib.util.spec_from_file_location("spike2", PACK / "tools" / "spike2.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def artifacts():
    dirs, files, globs = spike2().setup_artifacts()
    return dirs, files, globs


def test_every_directory_the_setup_links_is_excluded(artifacts):
    dirs, _, _ = artifacts
    assert {"Data", "res", "soundbank"} <= dirs, dirs


def test_every_file_the_setup_copies_is_excluded(artifacts):
    """savegame.sav is a save file and mod_info.json is a sprite map for a mod the
    other machine may not even have."""
    _, files, _ = artifacts
    assert {"savegame.sav", "mod_info.json", "shaders_mod.hlsl"} <= files, files


def test_the_string_mods_are_excluded_by_pattern(artifacts):
    _, _, globs = artifacts
    assert "*_mod.str" in globs, globs


def test_the_lists_are_read_from_packsetup_not_restated():
    """The whole point: adding a file to packSetup must exclude it from the zip with no
    second edit. Proven by checking the names really do come from that file."""
    for name in ("savegame.sav", "mod_info.json", "*_mod.str"):
        assert name in PACK_SETUP, f"{name} is not declared in packSetup.lua"
    source = (PACK / "tools" / "spike2.py").read_text(encoding="utf-8")
    body = source.split("def package(")[1]
    for name in ("savegame.sav", "mod_info.json", "_mod.str"):
        assert name not in body, \
            f"package() restates {name}; that is how the two lists drifted before"


def test_packaging_refuses_rather_than_guesses(tmp_path, monkeypatch):
    """If packSetup is ever renamed or restructured, shipping a partial exclusion list
    would be worse than not shipping at all."""
    module = spike2()
    monkeypatch.setattr(module, "HERE", tmp_path)
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "packSetup.lua").write_text("-- nothing here", encoding="utf-8")
    with pytest.raises(SystemExit):
        module.setup_artifacts()

def test_clean_undoes_the_setup_from_outside_the_game(tmp_path, monkeypatch):
    """The in-game button needs Modded Online enabled and running. This exists for
    the opposite case: the loader disabled, its mirrored copy of a mod's assets
    still in the pack, and the game refusing to boot because two packs now supply
    the same files. Nothing can run inside a game that will not start."""
    module = spike2()
    packs = tmp_path / "Mods" / "Packs"
    here = packs / "fyi.modded-online-loader"
    (here / "src").mkdir(parents=True)
    (here / "src" / "packSetup.lua").write_text(
        (PACK / "src" / "packSetup.lua").read_text(encoding="utf-8"), encoding="utf-8")
    (here / "src" / "saveShare.lua").write_text(
        (PACK / "src" / "saveShare.lua").read_text(encoding="utf-8"), encoding="utf-8")

    # what a session of hosting leaves behind
    (here / "res").mkdir()
    (here / "res" / "boulder.png").write_text("a hard link", encoding="utf-8")
    (here / "mod_info.json").write_text("{}", encoding="utf-8")
    (here / "strings00_mod.str").write_text("text", encoding="utf-8")
    (here / "mo_host.on").write_text("fyi.hdmod", encoding="utf-8")
    (here / "mo_setup_undo.txt").write_text("fyi.hdmod", encoding="utf-8")
    order = packs / "load_order.txt"
    order.write_text(chr(10).join(["--fyi.hdmod", "fyi.modded-online-loader", ""]),
                     encoding="utf-8")

    monkeypatch.setattr(module, "HERE", here)
    monkeypatch.setattr(module, "PACKS", packs)
    monkeypatch.setattr(module, "LOAD_ORDER", order)
    assert module.clean() == 0

    assert not (here / "res").exists(), "the mirrored assets were left behind"
    assert not (here / "mod_info.json").exists(), "the sprite map was left behind"
    assert not (here / "strings00_mod.str").exists()
    assert not (here / "mo_host.on").exists(), "still armed to host"
    restored = order.read_text(encoding="utf-8").splitlines()
    assert restored[0] == "fyi.hdmod", "the mod was not re-enabled"


def test_clean_never_deletes_through_a_junction(tmp_path, monkeypatch):
    """Deleting a folder of hard links removes those names only. The same recursive
    delete THROUGH a junction destroys the mod it points at."""
    module = spike2()
    here = tmp_path / "pack"
    (here / "src").mkdir(parents=True)
    (here / "src" / "packSetup.lua").write_text(
        (PACK / "src" / "packSetup.lua").read_text(encoding="utf-8"), encoding="utf-8")
    (here / "src" / "saveShare.lua").write_text(
        (PACK / "src" / "saveShare.lua").read_text(encoding="utf-8"), encoding="utf-8")
    (here / "res").mkdir()
    (here / "res" / "keep.png").write_text("the mod's real file", encoding="utf-8")

    monkeypatch.setattr(module, "HERE", here)
    monkeypatch.setattr(module, "PACKS", tmp_path)
    monkeypatch.setattr(module, "LOAD_ORDER", tmp_path / "load_order.txt")
    monkeypatch.setattr(module, "is_reparse_point", lambda p: p.name == "res")

    calls = []
    monkeypatch.setattr(module.shutil, "rmtree",
                        lambda p, **k: calls.append(p))
    monkeypatch.setattr(module.pathlib.Path, "rmdir",
                        lambda self: calls.append(("rmdir", self)))
    module.clean()
    assert calls == [("rmdir", here / "res")], calls
    assert (here / "res" / "keep.png").exists(), "deleted through the junction"
