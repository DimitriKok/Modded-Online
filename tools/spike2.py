"""Spike 2 — give a hosted mod its assets without running its Lua.

Disabling a pack stops two things: Playlunky executing its `main.lua`, and Playlunky
mounting its files. The second is collateral damage the loader has to undo, because a
mod hosted inside Modded Online still needs its textures, its `.lvl` files and its
sounds.

The brief originally called for a separate assets-only twin pack. Reading the API
definitions 2.5 bundles says that is the wrong shape:

    spel2-part1.lua:685   "List files in directory relative to the script root"
    spel2-part1.lua:1472  "Loads a sound from disk relative to this script"

and 2.5 loads its atlases by relative path — `textureDef.texture_path =
"res/ATLASES/textures1.png"` (src/theming/textures.lua:45,100). If Overlunky resolves
those paths against *the calling script's* root, then a mod hosted inside Modded
Online resolves them against **our** root, not its own. So the assets belong inside
the loader pack, not beside it — one pack, which also gets them mounted for free.

That resolution rule is documented for `list_dir` and `create_sound`. Whether
`define_texture` follows it is an inference, and booting the game is what settles it.

Junctions, not copies: `res/` alone is 279 MB, and a junction tracks the real folder
so a 2.5 update is picked up rather than going stale. `mklink /J` needs no elevation.

    py tools/spike2.py                # what state is everything in
    py tools/spike2.py --link         # junction the assets in (safe: pack is disabled)
    py tools/spike2.py --unlink       # take them back out
    py tools/spike2.py --apply        # flip load_order for the test (backs it up)

SUPERSEDED for setup: Modded Online now offers a checkbox per installed script pack
in Playlunky's own options panel, and ticking one does all of this itself -- see
src/setupUI.lua and src/packSetup.lua. This script stays for --package and for
recovering an install from outside the game, which is the one thing a menu cannot do.
    py tools/spike2.py --revert       # put load_order back
    py tools/spike2.py --clean        # undo everything, with the game CLOSED
    py tools/spike2.py --repair       # rebuild textures an older version deleted
    py tools/spike2.py --setup        # apply + link + arm, in the order that works
    py tools/spike2.py --package      # a zip to carry to the second machine

The two states that boot are "everything linked and the source pack disabled" and
"nothing linked and the source pack enabled". Mixing them mounts every asset twice
and the game dies during startup, so --link refuses to create that state and
--status and --revert both call it out.
"""

from __future__ import annotations

import fnmatch
import pathlib
import re
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent      # the loader pack
PACKS = HERE.parent
GAME_ROOT = PACKS.parent.parent                           # ...\Spelunky 2
LOAD_ORDER = PACKS / "load_order.txt"
BACKUP = HERE / "tools" / "load_order.backup.txt"

SOURCE_PACK = "fyi.spelunky-25-2"

# The disposable assets pack. Read from packSetup.lua rather than restated, for
# the reason setup_artifacts() exists: two lists of the same thing drift.

def setup_artifacts() -> tuple[set[str], set[str], list[str]]:
    """(dirs, files, glob patterns) that src/packSetup.lua puts into this pack.

    Read from packSetup.lua rather than restated here. They were restated here, and
    the two lists drifted the moment packSetup started carrying `savegame.sav`,
    `mod_info.json` and the string mods across: --package kept excluding the old
    three and shipped the new ones. The zip then carried one machine's hdmod setup
    to another machine, where the image_map pointed at a `res` folder that was not
    there -- Playlunky crashed slicing sprites out of missing images, at boot,
    before any Lua ran, which is why there was nothing in the log.
    """
    source = (HERE / "src" / "packSetup.lua").read_text(encoding="utf-8")

    def lua_list(name: str) -> list[str]:
        match = re.search(r"local %s = {([^}]*)}" % name, source)
        return re.findall(r'"([^"]+)"', match.group(1)) if match else []

    def lua_string(name: str) -> list[str]:
        match = re.search(r'local %s = "([^"]+)"' % name, source)
        return [match.group(1)] if match else []

    dirs = set(lua_list("LINK_DIRS"))
    files = set(lua_list("COPY_FILES")) | set(lua_string("INFO_FILE"))
    globs = lua_string("COPY_GLOB")

    # ...and the save files, which packSetup deliberately does NOT carry in
    # COPY_FILES (they are progression, seeded once rather than copied on every
    # apply) but which are just as much this machine's business as the rest. They
    # live in src/saveShare.lua, read from there for the same reason as above:
    # restating them here is how the two lists drift, and the drift ships one
    # player's save to another.
    share_path = HERE / "src" / "saveShare.lua"
    share = share_path.read_text(encoding="utf-8") if share_path.exists() else ""
    match = re.search(r"local FILES = {([^}]*)}", share)
    save_files = re.findall(r'"([^"]+)"', match.group(1)) if match else []
    if not save_files:
        raise SystemExit(
            "could not read FILES out of src/saveShare.lua -- refusing to package "
            "rather than ship this machine's save data to another")
    for name in save_files:
        files.add(name)
        files.add(name + ".mo_mine")   # a peer's own save, parked while borrowing
    fields = re.search(r'local FIELDS_FILE = "([^"]+)"', share)
    if fields:
        files.add(fields.group(1))     # ...and their parked savegame values
    if not dirs or not files:
        raise SystemExit(
            "could not read the setup artifacts out of src/packSetup.lua -- refusing "
            "to package rather than ship one machine's mod setup to another")
    return dirs, files, globs
# directories are junctioned; single files have to be copied, and a copy goes stale
LINK_DIRS = ("Data", "res", "soundbank")
COPY_FILES = ("shaders_mod.hlsl",)

# Playlunky does not serve a pack's PNGs to the game. It converts them to .DDS and
# writes the result to Mods/Packs/.db/Mods/<pack>/, then mounts that alongside the
# pack itself -- `.db\Mods\X` first, then `Mods/Packs\X`. For 2.5 that processed
# tree is 170 MB of Data and 2.1 GB of res.
#
# The first run of this spike linked only the source assets. Playlunky catalogued
# them (a 45 KB mod.db appeared for us) but converted nothing, and 2.5's own .db --
# where every converted texture already sits -- is not mounted while 2.5 is disabled.
# So the game saw raw PNGs it does not read, and no textures changed. Level files
# need no conversion, which is exactly why world generation DID change.
DB = PACKS / ".db" / "Mods"
DB_LINK_DIRS = ("Data", "res", "Guidebook")   # not "src": we read the mod's Lua directly

# what --apply changes: the mod under test off, the shipping build off (two enabled
# copies of Modded Online would both bind the UDP port), the loader build on
DISABLE = (SOURCE_PACK, "fyi.modded-online")
ENABLE = ("fyi.modded-online-loader",)


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.0f} GB"


def is_junction(path: pathlib.Path) -> bool:
    """A junction reports as a directory AND as a reparse point."""
    if not path.exists():
        return False
    try:
        return path.is_dir() and path.is_symlink() or bool(
            path.lstat().st_file_attributes & 0x400)  # FILE_ATTRIBUTE_REPARSE_POINT
    except (OSError, AttributeError):
        return False


def source_enabled() -> bool:
    for line in read_order():
        if line.strip().lstrip("-").strip() == SOURCE_PACK:
            return not line.strip().startswith("--")
    return False


def linked() -> bool:
    return any((HERE / name).exists() for name in LINK_DIRS)


def incoherent() -> str | None:
    """The one configuration that must never reach a boot.

    These junctions exist to serve a DISABLED mod's assets from our pack. If the mod
    is enabled at the same time, Playlunky mounts the same trees twice under two pack
    names -- for 2.5 that is 2.1 GB of `res` and 170 MB of `Data`, duplicated -- and
    the game dies during startup. It has happened once already: `--revert` put 2.5
    back on and left the junctions in, and the next two boots crashed.
    """
    if linked() and source_enabled():
        return (f"{SOURCE_PACK} is ENABLED while its assets are also junctioned into "
                f"this pack.\n  Playlunky would mount both copies and the game will "
                f"crash on boot.\n  Fix with either:  py tools/spike2.py --unlink   "
                f"(back to normal play)\n              or:  py tools/spike2.py --apply "
                f"    (into the test configuration)")
    return None


def read_order() -> list[str]:
    return LOAD_ORDER.read_text(encoding="utf-8").splitlines()


def status() -> int:
    print("assets in the loader pack:")
    for name in LINK_DIRS:
        dest = HERE / name
        if not dest.exists():
            print(f"  {name:<14} absent")
        elif is_junction(dest):
            try:
                sample = next(dest.rglob("*.*"), None)
                readable = sample is not None and sample.stat().st_size > 0
            except OSError:
                readable = False
            print(f"  {name:<14} junction, readable={readable}")
        else:
            print(f"  {name:<14} REAL DIRECTORY (not a junction)")
    for name in COPY_FILES:
        print(f"  {name:<14} {'copied' if (HERE / name).exists() else 'absent'}")

    print("\nconverted assets (.db) — what the game actually loads:")
    for name in DB_LINK_DIRS:
        dest = DB / HERE.name / name
        if dest.exists():
            print(f"  {name:<14} {'junction' if is_junction(dest) else 'REAL DIRECTORY'}")
        else:
            print(f"  {name:<14} absent")

    print("\nload order:")
    for line in read_order():
        name = line.lstrip("-").strip()
        if name in DISABLE + ENABLE:
            print(f"  {'off' if line.startswith('--') else 'ON ':<4} {name}")
    print(f"\nbackup present: {BACKUP.exists()}")

    problem = incoherent()
    if problem is not None:
        print("\n*** WILL CRASH ON BOOT: " + problem)
    elif linked():
        print("\nverdict: test configuration — assets served from this pack, "
              f"{SOURCE_PACK} disabled")
    else:
        print("\nverdict: normal — no assets linked from this pack")
    return 0


def is_reparse_point(path: pathlib.Path) -> bool:
    """A junction, from before the hard-link mirror. Deleting a directory of hard
    links removes those names only; doing the same THROUGH a junction destroys the
    mod it points at."""
    try:
        return bool(path.lstat().st_file_attributes & 0x400)  # REPARSE_POINT
    except (OSError, AttributeError):
        return False


def tree_count(path: pathlib.Path) -> int:
    return sum(1 for _ in path.rglob("*")) if path.is_dir() else 0


def repair() -> int:
    """Make Playlunky rebuild a mod whose converted textures an older version deleted.

    Those versions junctioned `.db/Mods/<us>/res` at another pack's converted output
    and then deleted recursively through it. The source pack survives; what is gone
    is the DDS Playlunky built from it -- and `mod.db` still lists every one of those
    files as converted, so Playlunky rebuilds nothing and the mod will not boot on
    its own, with Modded Online switched off entirely.

    Deleting that cache is the whole repair: the next launch reconverts from source.
    """
    db = PACKS / ".db" / "Mods"
    if not db.is_dir():
        print("no converted trees to check")
        return 0
    repaired = []
    for pack_db in sorted(db.iterdir()):
        if not pack_db.is_dir() or pack_db.name == HERE.name:
            continue
        source, cache = PACKS / pack_db.name, pack_db / "mod.db"
        if not source.is_dir() or not cache.is_file():
            continue
        for asset in ("Data", "res"):
            have = tree_count(source / asset)
            built = tree_count(pack_db / asset)
            # gutted: the source has plenty and the converted tree has almost none
            if have > 10 and built * 4 < have:
                cache.unlink()
                repaired.append(f"{pack_db.name} ({asset}: {built} built of {have})")
                break
    if not repaired:
        print("every mod's converted textures look intact")
        return 0
    for item in repaired:
        print(f"  cleared the conversion cache for {item}")
    print()
    print("Launch each of those mods once, on its own. Playlunky rebuilds the")
    print("textures from the mod's own files, which were never touched. That first")
    print("launch is slow because of it.")
    return 0


def clean() -> int:
    """Undo the setup from outside the game.

    The in-game button needs Modded Online enabled and running. The situation this
    exists for is the opposite one: the loader disabled, its mirrored copy of a
    mod's assets still in the pack, and the game refusing to boot because two packs
    now supply the same files. Nothing can run inside a game that will not start.
    """
    artifact_dirs, artifact_files, artifact_globs = setup_artifacts()
    removed = []

    # A pack one version briefly created. It could not work -- Overlunky resolves a
    # relative asset path against the pack root of the script that ASKS -- and the
    # revert left the one already on disk, still listed and still serving a mod's
    # textures into every session after it.
    legacy = re.search(r'local LEGACY_ASSET_PACK = "([^"]+)"',
                       (HERE / "src" / "packSetup.lua").read_text(encoding="utf-8")
                       ).group(1)
    for target in (PACKS / legacy, PACKS / ".db" / "Mods" / legacy):
        if not target.exists():
            continue
        if is_reparse_point(target):
            target.rmdir()
        else:
            shutil.rmtree(target)
        removed.append(f"{legacy} ({target.parent.name})")

    # the mod's asset folders, which live in this pack because Overlunky resolves a
    # relative texture path against the pack root of the script that asks -- and the
    # script asking is ours
    for name in sorted(artifact_dirs):
        target = HERE / name
        if not target.exists() and not target.is_symlink():
            continue
        if is_reparse_point(target):
            target.rmdir()          # the link only; never recursively through it
            removed.append(f"{name}/ (junction)")
        else:
            shutil.rmtree(target)   # hard links: these names, not the mod's
            removed.append(f"{name}/")

    files = set(artifact_files) | {"mo_assets_from.txt", "mo_host.on"}
    for path in sorted(HERE.iterdir()):
        if not path.is_file():
            continue
        if path.name in files or any(fnmatch.fnmatch(path.name, g)
                                     for g in artifact_globs):
            path.unlink()
            removed.append(path.name)

    db_here = PACKS / ".db" / "Mods" / HERE.name
    for name in sorted(artifact_dirs):
        target = db_here / name
        if not target.exists():
            continue
        # never outside our own folder, whatever shape this turns out to be
        if not str(target.resolve()).startswith(str(db_here.resolve())):
            print(f"  REFUSING to touch {target} -- not inside {db_here}")
            continue
        if is_reparse_point(target):
            target.rmdir()
        else:
            shutil.rmtree(target)
        removed.append(f".db/{name}/")

    # put back exactly the lines we commented, and nothing else
    undo = HERE / "mo_setup_undo.txt"
    if LOAD_ORDER.exists():
        ours = set()
        if undo.exists():
            ours = {line.strip()
                    for line in undo.read_text(encoding="utf-8").splitlines()
                    if line.strip()}
        out = []
        for line in LOAD_ORDER.read_text(encoding="utf-8").splitlines():
            bare = line.lstrip("-").strip()
            if bare == legacy:
                removed.append(f"load_order.txt: removed {bare}")
            elif bare in ours and line.lstrip().startswith("--"):
                out.append(bare)
                removed.append(f"load_order.txt: re-enabled {bare}")
            else:
                out.append(line)
        LOAD_ORDER.write_text(chr(10).join(out) + chr(10), encoding="utf-8")
        if undo.exists():
            undo.unlink()

    if not removed:
        print("nothing to clean -- this pack holds no hosted mod's assets")
        return 0
    for item in removed:
        print(f"  removed {item}")
    print()
    print("Clean. Your mods are exactly as they were; enable them normally.")
    return 0

def package() -> int:
    """A zip of this pack that another machine can unfold and set up.

    Copying the folder directly would follow the junctions and carry 2.1 GB of the
    source mod's converted textures with it. Those are machine-local anyway — the
    other machine makes its own, pointing at its own copy of the mod — so the zip
    holds only what is actually ours.
    """
    import zipfile

    artifact_dirs, artifact_files, artifact_globs = setup_artifacts()
    skip_dirs = artifact_dirs | {"__pycache__", ".pytest_cache", ".vs", ".claude"}
    skip_files = artifact_files | {
        "mo_host.on",            # the in-game picker writes it, per machine
        "mo_setup_undo.txt",     # which load_order lines WE commented, per machine
        "mo_fatal_calls.txt",    # engine calls that crash THAT machine, per machine
        "mo_notextures.on",      # that machine's escape hatch, per machine
        "mo_profile.off",        # a diagnostic someone switched OFF, per machine
        "mo_patched_textures.txt",  # vanilla atlases WE made Playlunky rewrite
        ".mo_source",            # which mod a mirrored folder was built from
        "mo_assets_from.txt",    # which mod the copied files came from
        "config.json",           # player name and server address are personal
        "desync_log.txt", "desync_log.prev.txt", "crash_frame.txt",
        "load_order.backup.txt",  # that machine's own load order, not theirs
        "save.dat",
    }
    out = GAME_ROOT / (HERE.name + ".zip")
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(HERE.rglob("*")):
            rel = path.relative_to(HERE)
            if any(part in skip_dirs for part in rel.parts):
                continue
            if path.is_file() and path.name not in skip_files:
                if path.suffix in (".log",):
                    continue
                if any(fnmatch.fnmatch(path.name, g) for g in artifact_globs):
                    continue
                z.write(path, pathlib.Path(HERE.name) / rel)
                count += 1
    print(f"{out}")
    print(f"  {count} files, {human(out.stat().st_size)} — junctions and personal "
          f"files left out")
    print()
    print("On the other machine: unzip into Mods/Packs, enable Modded Online in")
    print("Modlunky, and tick the mod you want under its options. Nothing else --")
    print("the setup is per-machine and is deliberately NOT in this zip.")
    print(f"It needs its own {SOURCE_PACK} installed, at the SAME version — the")
    print("compatibility signature now covers hosted mods, so a mismatch is refused")
    print("with a reason rather than silently desyncing.")
    return 0


def main() -> int:
    arg = sys.argv[1] if len(sys.argv) > 1 else "--status"
    return {
        # --link/--unlink/--apply/--revert/--setup are gone: the mod picker in
        # Playlunky's options panel does all of that from inside the game now, and
        # two ways of arranging the same files is how they came to disagree.
        "--status": status, "--package": package, "--clean": clean,
        "--repair": repair,
    }.get(arg, lambda: (print(__doc__), 2)[1])()


if __name__ == "__main__":
    raise SystemExit(main())
