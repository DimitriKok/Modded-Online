"""Spike 1, run from the command line: load a content mod's Lua into the host's
sandbox and report what it asks for.

The point of running this outside the game is the loop. Booting Spelunky to read one
report is minutes; this is seconds, and Spike 1 is a question you ask twenty times
while filling in the gaps it finds.

Two things make the answer meaningful rather than noise:

* `_G` is seeded from the Overlunky API definitions that 2.5 already bundles
  (`src/apiFiles/spel2-part*.lua`, downloaded from overlunky's own `spel2.lua`), so a
  global reported as missing is genuinely missing rather than merely "not in a bare
  Lua".
* every registration API is inert, so this cannot do anything even if pointed at a
  live install.

    py tools/spike1.py                     # against fyi.spelunky-25-2
    py tools/spike1.py fyi.randomizer      # or any other pack

Caveat worth knowing before you read a failure: lupa here is Lua 5.5 and Playlunky is
5.4. A handful of things legal in 5.4 are errors in 5.5 — assigning to a `for` loop
variable is the one already seen in this codebase. Those show up as load failures that
would NOT happen in the game, and the report flags the ones it can recognise.
"""

from __future__ import annotations

import pathlib
import re
import sys

import lupa

HERE = pathlib.Path(__file__).resolve().parent.parent   # the pack root
GAME_ROOT = HERE.parent.parent.parent                  # ...\Spelunky 2
PACKS = GAME_ROOT / "Mods" / "Packs"

# The definition files declare engine names in three shapes, and all three count.
# An earlier version of API_TABLE required an ALL-CAPS name, which quietly excluded
# `Color = {}` and every other mixed-case class — they then showed up in the report
# as though the host had failed to provide them.
API_FUNCTION = re.compile(r"^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.M)
API_TABLE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{", re.M)
API_CLASS = re.compile(r"^\s*---\s*@class\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)

LUA55_ONLY = (
    ("attempt to assign to const variable", "assigning to a for-loop variable"),
    ("<const>", "a 5.4/5.5 attribute difference"),
)


def api_names(pack: pathlib.Path) -> tuple[set[str], set[str]]:
    """(functions, tables) the engine provides, read from a pack's API stubs.

    Most mods ship none -- 2.5 is unusual in bundling Overlunky's `spel2.lua`. The
    stubs describe the ENGINE, not the mod, so any pack's copy will do; without a
    fallback this tool could only ever examine 2.5, and `ON` came back nil two
    modules into hdmod.
    """
    functions: set[str] = set()
    tables: set[str] = set()
    source = pack
    # the stub file itself, not merely the folder: one pack here has an empty
    # apiFiles directory, and picking it seeded nothing at all
    if not (pack / "src" / "apiFiles" / "spel2-part1.lua").is_file():
        for other in sorted(pack.parent.iterdir()):
            if (other / "src" / "apiFiles" / "spel2-part1.lua").is_file():
                source = other
                print(f"{pack.name} ships no API stubs; "
                      f"describing the engine from {other.name}")
                break
    for name in ("spel2-part1.lua", "spel2-part2.lua", "undocumented.lua"):
        path = source / "src" / "apiFiles" / name
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        functions.update(API_FUNCTION.findall(text))
        tables.update(API_TABLE.findall(text))
        # `--- @class TextureDefinition` and friends: real engine types that the stub
        # file only ever declares as an annotation
        tables.update(API_CLASS.findall(text))
    return functions, tables


def build_runtime(functions: set[str], tables: set[str]) -> lupa.LuaRuntime:
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("printed = {}\nfunction print(s) printed[#printed + 1] = tostring(s) end")
    # Engine functions return nil; that is what a stub can honestly promise. A mod
    # that needs a real return value will surface as its own error, which is a
    # finding rather than a problem with the harness.
    for name in sorted(functions):
        rt.execute(f"function {name}() end")
    for name in sorted(tables):
        # an enum whose members all read as 0 -- enough to index without erroring
        rt.execute(f"{name} = setmetatable({{}}, {{__index = function() return 0 end}})")

    # PackPath is Playlunky's, not Overlunky's, so it is not in the API stubs this
    # harness seeds from -- and modHost reads its host flag through it at load. Since
    # Spike 3 added that line this tool died before it hosted anything.
    rt.execute('function PackPath(n) return "Mods/Packs/fyi.modded-online-loader/"'
               ' .. n end')

    # get_local_state is the one stub that cannot return nil. 2.5's very first act is
    # Sp25GameClass:construct() -> resetGame() -> get_local_state().screen, so a nil
    # here stops its startup dead -- silently, because 2.5 wraps startup in its own
    # SafeCall. With a nil stub the report reads "30 modules, no errors"; with this
    # one it reads 56 and reaches game:init(). Worth knowing that a harness gap and a
    # hosting gap look identical from the outside.
    rt.execute("""
function get_local_state()
    return {screen = 4, screen_next = 4, world = 1, level = 1, theme = 1,
            world_next = 1, level_next = 1, theme_next = 1, level_count = 0,
            time_total = 0, time_level = 0, quest_flags = 0, presence_flags = 0,
            loading = 0, items = {player_inventory = {}}, level_gen = {themes = {}},
            arena = {player_lives = {0, 0, 0, 0}}}
end
function state() return get_local_state() end
""")
    return rt


def main() -> int:
    pack_name = sys.argv[1] if len(sys.argv) > 1 else "fyi.spelunky-25-2"
    pack = PACKS / pack_name
    if not (pack / "main.lua").exists():
        print(f"no main.lua in {pack} — nothing to host")
        return 2

    functions, tables = api_names(pack)
    print(f"engine API seeded from the pack's own stubs: "
          f"{len(functions)} functions, {len(tables)} enums")

    rt = build_runtime(functions, tables)
    # The callback registry first, exactly as main.lua loads it: it replaces the
    # global set_callback, and modHost's teardown guard asks it whether a bare
    # clear_callback() would land on one of ours. Hosting without it would be
    # measuring a configuration the game never runs.
    rt.execute((HERE / "src" / "callbacks.lua").read_text(encoding="utf-8"))
    rt.execute((HERE / "src" / "modHost.lua").read_text(encoding="utf-8"))

    # modHost resolves "Mods/Packs/<pack>/..." relative to the working directory,
    # which is how it will resolve them in the game
    import os
    os.chdir(GAME_ROOT)

    # A mod still carrying one of our old injected blocks is refused by the game --
    # the block runs our determinism a second time inside ours -- so measuring it here
    # would describe a configuration that cannot run.
    main_src = (pack / "main.lua").read_text(encoding="utf-8", errors="replace")
    marker = re.search(r"(\[ModdedOnline-[^\]]+\])", main_src)
    if marker:
        print(f"{pack.name} still carries {marker.group(1)} in its main.lua.")
        print("The game refuses to host a mod in that state. Reinstall the mod.")
        return 1
    sources = rt.table_from({"main": main_src})
    report = rt.eval("ModHost.host")(
        pack_name, rt.table_from({"inert": True, "sources": sources}))
    for line in rt.eval("ModHost.summarize")(report).values():
        print(str(line))

    modules = [str(v) for v in report["modules"].values()]
    missing = [str(v) for v in report["missing"].values()]
    skipped = [(str(e["path"]), str(e["err"])) for e in (report["skipped"] or {}).values()] \
        if report["skipped"] is not None else []

    print()
    print(f"modules loaded ({len(modules)}):")
    for name in modules[:40]:
        print(f"    {name}")
    if len(modules) > 40:
        print(f"    ... +{len(modules) - 40} more")

    if skipped:
        print()
        print(f"skipped ({len(skipped)}) — each is a gap to close or a 5.5 artefact:")
        for path, err in skipped:
            note = ""
            for needle, why in LUA55_ONLY:
                if needle in err:
                    note = f"   [harness only: {why}]"
                    break
            print(f"    {path}: {err}{note}")

    # 2.5 wraps its own startup in SafeCall, which swallows failures and reports
    # them through print(). Without this, a mod whose init died silently would look
    # like a clean load -- the exact mistake this spike exists to avoid making.
    said = [str(v) for v in rt.eval("printed").values()]
    loud = [line for line in said
            if "ERROR" in line or "error" in line or "failed" in line or "FAIL" in line]
    print()
    print(f"the mod's own output: {len(said)} lines, {len(loud)} of them complaints")
    for line in loud[:25]:
        print(f"    {line}")
    if len(loud) > 25:
        print(f"    ... +{len(loud) - 25} more")

    if missing:
        print()
        print(f"globals neither we nor the engine stubs had ({len(missing)}) — "
              f"this is the list Spike 1 exists to produce:")
        for name in missing:
            print(f"    {name}")

    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
