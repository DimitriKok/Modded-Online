"""Extract the game's menu sprite sheets from Spel2.exe, to measure sprites on.

src/vanillaUI.lua draws the MODDED ONLINE menu from the game's own sheets (menu_disp,
menu_basic, menu_generic, menu_brick1/2). Its sprite rectangles were measured on the
sheets this writes. Run it again if the game ever moves a sprite, or to find a new
one. It only READS the exe.

It needs modlunky2's asset reader, which pins a zstandard that will not build without
a C compiler. So install that package on its own and give it a current zstandard:

    uv venv --python 3.12 mlenv
    uv pip install --python mlenv/Scripts/python.exe --no-deps modlunky2
    uv pip install --python mlenv/Scripts/python.exe zstandard pillow
    mlenv/Scripts/python.exe tools/extract_menu_sheets.py OUT_DIR

The PNGs land in OUT_DIR/Data/Textures. The game's DDS files are uncompressed BGRA,
which modlunky2's own converter no longer reads on a current Pillow, so they are
decoded here. A copy of menu_basic matched the original PNG in .db/Original pixel for
pixel.
"""

from __future__ import annotations

import io
import logging
import pathlib
import sys
import types
from struct import unpack

# Sounds are not wanted, and their module needs a library that is not installed.
_soundbank = types.ModuleType("modlunky2.assets.soundbank")
_soundbank.extract_soundbank = lambda *a, **k: None
sys.modules["modlunky2.assets.soundbank"] = _soundbank

from PIL import Image  # noqa: E402
import modlunky2.assets.assets as assets  # noqa: E402
from modlunky2.assets.assets import AssetStore  # noqa: E402

EXE = pathlib.Path(__file__).resolve().parents[4] / "Spel2.exe"
SHEETS = ("menu_basic", "menu_disp", "menu_header", "menu_generic", "menu_brick1",
          "menu_brick2", "menu_online", "menu_title", "menu_tunnel", "menu_leader")


def dds_to_png(data: bytes) -> bytes:
    """ "DDS " + a 124-byte header, then uncompressed 32-bit BGRA pixels."""
    height, width = unpack("<II", data[12:20])
    img = Image.frombytes("RGBA", (width, height), data[128:128 + width * height * 4],
                          "raw", "BGRA")
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = pathlib.Path(sys.argv[1])
    (out / "Data" / "Textures").mkdir(parents=True, exist_ok=True)
    assets.dds_to_png = dds_to_png
    logging.basicConfig(level=logging.WARNING)
    with EXE.open("rb") as exe:
        store = AssetStore.load_from_file(exe)
        for name in SHEETS:
            path = f"Data/Textures/{name}.DDS"
            asset = store.find_asset(path)
            if asset is None:
                print("not in the exe:", path)
                continue
            asset.filepath = path
            asset.load_data(exe)
            asset.extract(out, out, store.key, recompress=False)
            print("extracted", path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
