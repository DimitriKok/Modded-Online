"""Tests the in-game mod picker's setup — what `tools/spike2.py --setup` used to do.

This module edits `load_order.txt`, a file the player also edits by hand, and creates
and destroys directory junctions. Both are worth proving before they run on someone's
install, so the whole Windows vocabulary it uses (`dir`, `if exist`, `mklink`, `rmdir`)
is faked here against an in-memory tree.

The guarantees that matter:

  * a selection comments out exactly the packs chosen and nothing else;
  * undoing it un-comments exactly the lines we commented, and leaves the player's own
    commented-out mods alone;
  * only one asset-bearing mod is ever accepted, because every hosted mod's `Data` and
    `res` are junctioned into our pack under those names and two cannot both own them.

Run:  python -m pytest tests/test_pack_setup.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
PACK_SETUP = (PACK / "src" / "packSetup.lua").read_text(encoding="utf-8")
JSON = (PACK / "src" / "json.lua").read_text(encoding="utf-8")

OWN = "fyi.modded-online-loader"
# the assets live in our own pack: Overlunky resolves relative asset paths
# against the pack root of the script that asks, and that is ours
COMPANION = OWN

# A fake Windows shell over an in-memory tree. Only the handful of commands
# packSetup actually issues are understood; anything else returns nothing, which is
# how a real cmd behaves for a command that matched no files.
HARNESS = """
files = {}          -- path (forward slashes) -> contents
dirs = {}           -- path -> true
links = {}          -- junction path -> what it points at
commands = {}       -- every command line issued, in order

function norm(p) return (tostring(p):gsub("\\\\", "/")) end

function PackDir() return "__OWN__" end
function PackPath(rest) return "Mods/Packs/" .. PackDir() .. "/" .. rest end

local realOpen = io.open

io.open = function(path, mode)
    path = norm(path)
    if mode == nil or mode:find("r") then
        local body = files[path]
        if body == nil then return nil end
        local pos = 1
        return {
            read = function(_, what)
                if what == "*a" or what == "a" then
                    local rest = body:sub(pos); pos = #body + 1; return rest
                end
                if pos > #body then return nil end
                local nl = body:find("\\n", pos, true)
                local line
                if nl == nil then line = body:sub(pos); pos = #body + 1
                else line = body:sub(pos, nl - 1); pos = nl + 1 end
                return line
            end,
            lines = function(self)
                return function() return self:read("l") end
            end,
            close = function() end,
        }
    end
    local buffer = {}
    return {
        write = function(_, s) buffer[#buffer + 1] = s end,
        close = function() files[path] = table.concat(buffer) end,
    }
end

io.lines = function(path)
    path = norm(path)
    local body = files[path]
    if body == nil then error("no such file: " .. path) end
    local pos = 1
    return function()
        if pos > #body then return nil end
        local nl = body:find("\\n", pos, true)
        local line
        if nl == nil then line = body:sub(pos); pos = #body + 1
        else line = body:sub(pos, nl - 1); pos = nl + 1 end
        return line
    end
end

os.remove = function(path) files[norm(path)] = nil end

-- A quoted path may carry a trailing separator (`if exist "X\"`), so every capture
-- goes through here rather than trying to match the separator in the pattern.
function cleanPath(p)
    return (norm(p):gsub("/+$", ""))
end

io.popen = function(cmd)
    commands[#commands + 1] = cmd
    local out = ""
    local listing = cmd:match('^dir /b /ad "([^"]+)"')
    local exists = cmd:match('^if exist "([^"]+)" %(echo yes%)')
    local mkdirIf = cmd:match('^if not exist "[^"]+" %(mkdir "([^"]+)"%)')
    local link, target = cmd:match('^mklink /J "([^"]+)" "([^"]+)"')
    local rm = cmd:match('^rmdir "([^"]+)"')
    local from, to = cmd:match('^copy /y "([^"]+)" "([^"]+)"')
    local listAll = cmd:match('^dir /al "([^"]+)"')
    local rmAll = cmd:match('^rmdir /s /q "([^"]+)"')
    -- the PowerShell hard-link mirror: source and destination out of the script
    local psSrc = cmd:match("Resolve%-Path %-LiteralPath '([^']+)'")
    local psDest = cmd:match("%$d='([^']+)'")
    -- `dir /b "<folder>\\<glob>"`: files, where the /ad form above lists folders
    local fileGlob = nil
    if listing == nil then
        fileGlob = cmd:match('^dir /b "([^"]+)"')
    end

    if listing ~= nil then
        local base = cleanPath(listing) .. "/"
        local seen = {}
        for path in pairs(dirs) do
            if path:sub(1, #base) == base then
                local leaf = path:sub(#base + 1):match("^[^/]+")
                if leaf ~= nil and not seen[leaf] then
                    seen[leaf] = true
                    out = out .. leaf .. "\\n"
                end
            end
        end
    elseif exists ~= nil then
        if dirs[cleanPath(exists)] then out = "yes\\n" end
    elseif mkdirIf ~= nil then
        dirs[cleanPath(mkdirIf)] = true
    elseif listAll ~= nil then
        local base = cleanPath(listAll) .. "/"
        for path, dest in pairs(links) do
            if path:sub(1, #base) == base then
                local leaf = path:sub(#base + 1)
                if leaf:find("/") == nil then
                    out = out .. "  <JUNCTION>    " .. leaf
                        .. " [" .. dest .. "]" .. "\\n"
                end
            end
        end
    elseif link ~= nil then
        if dirs[cleanPath(target)] then
            dirs[cleanPath(link)] = true
            links[cleanPath(link)] = cleanPath(target)
            out = "Junction created for " .. link .. " <<===>> " .. target .. "\\n"
        else
            out = "The system cannot find the file specified.\\n"
        end
    elseif rmAll ~= nil then
        -- recursive: the folder and everything under it
        local base = cleanPath(rmAll)
        local prefix = base .. "/"
        dirs[base] = nil
        links[base] = nil
        for path in pairs(dirs) do
            if path:sub(1, #prefix) == prefix then dirs[path] = nil end
        end
        for path in pairs(files) do
            if path:sub(1, #prefix) == prefix then files[path] = nil end
        end
    elseif psSrc ~= nil and psDest ~= nil then
        local base = cleanPath(psSrc) .. "/"
        local dest = cleanPath(psDest)
        dirs[dest] = true
        local copied = {}
        for path, body in pairs(files) do
            if path:sub(1, #base) == base then
                copied[dest .. "/" .. path:sub(#base + 1)] = body
            end
        end
        for path, body in pairs(copied) do
            files[path] = body
            local parent = path:match("^(.*)/[^/]+$")
            if parent ~= nil then dirs[parent] = true end
        end
    elseif rm ~= nil then
        dirs[cleanPath(rm)] = nil
        links[cleanPath(rm)] = nil
    elseif from ~= nil then
        files[cleanPath(to)] = files[cleanPath(from)] or ""
    elseif fileGlob ~= nil then
        local dir, pattern = cleanPath(fileGlob):match("^(.*)/([^/]+)$")
        if dir ~= nil then
            local rule = "^" .. pattern:gsub("%.", "%%."):gsub("%*", ".*") .. "$"
            for path in pairs(files) do
                local parent, leaf = path:match("^(.*)/([^/]+)$")
                if parent == dir and leaf ~= nil and leaf:match(rule) then
                    out = out .. leaf .. "\\n"
                end
            end
        end
    end

    local pos = 1
    return {
        read = function() local r = out:sub(pos); pos = #out + 1; return r end,
        close = function() end,
    }
end
""".replace("__OWN__", OWN)


def runtime(load_order: str = "", tree: dict | None = None):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(HARNESS)
    rt.execute(JSON)
    rt.execute(PACK_SETUP)
    if load_order:
        rt.eval("function(body) files['Mods/Packs/load_order.txt'] = body end")(load_order)
    for path, kind in (tree or {}).items():
        if kind == "dir":
            rt.eval("function(p) dirs[p] = true end")(path)
        else:
            rt.eval("function(p, b) files[p] = b end")(path, kind)
    return rt


def pack(name: str, *, assets: bool = False, converted: bool = False) -> dict:
    """An installed script pack, optionally with textures."""
    tree = {
        f"Mods/Packs/{name}": "dir",
        f"Mods/Packs/{name}/main.lua": "-- a mod",
    }
    if assets:
        tree[f"Mods/Packs/{name}/Data"] = "dir"
        tree[f"Mods/Packs/{name}/res"] = "dir"
    if converted:
        tree[f"Mods/Packs/.db/Mods/{name}"] = "dir"
        tree[f"Mods/Packs/.db/Mods/{name}/Data"] = "dir"
    return tree


# ------------------------------------------------------------------- option keys


ORDER = chr(10).join([
    "fyi.spelunky-25-2",
    "--player.own-disabled-mod",
    "fyi.randomizer",
    OWN,
]) + chr(10)


def companion(rest=""):
    tail = ("/" + rest) if rest else ""
    return "Mods/Packs/%s%s" % (COMPANION, tail)


# ------------------------------------------------------------------ option keys


def test_an_option_key_is_a_valid_identifier():
    key = str(runtime().eval("PackSetup.optionKey")("fyi.spelunky-25-2"))
    assert key.replace("_", "a").isalnum() and not key[0].isdigit(), key


def test_names_that_sanitise_the_same_still_get_different_keys():
    """'a.b' and 'a-b' both become 'a_b'; a saved toggle must not cross over."""
    optionKey = runtime().eval("PackSetup.optionKey")
    assert str(optionKey("mod.one")) != str(optionKey("mod-one"))


def test_an_option_key_is_stable_across_sessions():
    """Playlunky remembers ticks by name; a key that moved would lose the setting."""
    first = str(runtime().eval("PackSetup.optionKey")("fyi.spelunky-25-2"))
    second = str(runtime().eval("PackSetup.optionKey")("fyi.spelunky-25-2"))
    assert first == second


# -------------------------------------------------------------------- discovery


def test_only_installed_script_packs_are_offered():
    tree = {**pack("fyi.spelunky-25-2"), **pack("fyi.randomizer")}
    tree["Mods/Packs/some.texture-pack"] = "dir"
    tree["Mods/Packs/.db"] = "dir"
    tree["Mods/Packs/%s" % OWN] = "dir"
    tree["Mods/Packs/%s/main.lua" % OWN] = "-- us"
    tree[companion()] = "dir"
    tree["Mods/Packs/fyi.modded-online"] = "dir"
    tree["Mods/Packs/fyi.modded-online/main.lua"] = "-- shipping"
    names = [str(v) for v in
             runtime(tree=tree).eval("PackSetup.installedScriptPacks()").values()]
    assert names == ["fyi.randomizer", "fyi.spelunky-25-2"], names


def test_a_pack_stays_listed_once_it_is_hosted():
    """Hosting DISABLES it in load_order; a list read from there would lose it."""
    rt = runtime(load_order="--fyi.spelunky-25-2" + chr(10) + OWN + chr(10),
                 tree=pack("fyi.spelunky-25-2"))
    names = [str(v) for v in rt.eval("PackSetup.installedScriptPacks()").values()]
    assert names == ["fyi.spelunky-25-2"]


# --------------------------------------------------------------------- planning


def test_any_number_of_script_only_mods_can_be_hosted_together():
    tree = {**pack("mod.a"), **pack("mod.b"), **pack("mod.c")}
    rt = runtime(tree=tree)
    rt.execute("accepted, rejected = PackSetup.plan({'mod.a','mod.b','mod.c'})")
    assert len(rt.eval("accepted")) == 3 and len(rt.eval("rejected")) == 0


def test_only_one_asset_bearing_mod_is_accepted():
    """Both would put their Data into the companion, under the same name."""
    tree = {**pack("mod.a", assets=True), **pack("mod.b", assets=True)}
    rt = runtime(tree=tree)
    rt.execute("accepted, rejected, notes = PackSetup.plan({'mod.a','mod.b'})")
    assert [str(v) for v in rt.eval("accepted").values()] == ["mod.a"]
    assert [str(v) for v in rt.eval("rejected").values()] == ["mod.b"]
    assert any("only one mod with assets" in str(v).lower()
               for v in rt.eval("notes").values())


def test_a_script_only_mod_still_rides_along_with_an_asset_mod():
    tree = {**pack("mod.a", assets=True), **pack("mod.b")}
    rt = runtime(tree=tree)
    rt.execute("accepted = PackSetup.plan({'mod.a','mod.b'})")
    assert sorted(str(v) for v in rt.eval("accepted").values()) == ["mod.a", "mod.b"]

# ------------------------------------------------------- building and removing


def test_the_assets_land_where_the_asking_script_will_look():
    """Overlunky resolves a relative asset path against the pack root of the script
    that asks, and hosting means the script asking is OURS. hdmod opens with
    define_texture("res/locked_feat.png"), looked for in this folder. Putting them
    anywhere else was tried, and died on the first texture."""
    rt = runtime(load_order=ORDER, tree=pack("mod.a", assets=True))
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    assert rt.eval("dirs['Mods/Packs/%s/Data']" % OWN) is True
    assert rt.eval("dirs['Mods/Packs/%s/res']" % OWN) is True
    source = rt.eval("files['Mods/Packs/%s/.mo_source']" % OWN)
    assert str(source) == "mod.a"


def test_the_companion_has_no_main_lua():
    """If it had one, Playlunky would run the mod a second time -- which is the
    thing disabling the mod was for in the first place."""
    rt = runtime(load_order=ORDER, tree=pack("mod.a", assets=True))
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    assert rt.eval("files['%s']" % companion("main.lua")) is None


def test_stopping_removes_the_companion_entirely():
    """One delete, not the reversal of half a dozen changes. Nothing survives a
    step that was missed, because there are no steps to miss."""
    tree = pack("mod.a", assets=True)
    tree["Mods/Packs/mod.a/res/art.png"] = "art"
    tree["Mods/Packs/mod.a/mod_info.json"] = '{"image_map": {"res/a.png": {}}}'
    tree["Mods/Packs/mod.a/strings00_mod.str"] = "text"
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    assert rt.eval("files['%s']" % companion("res/art.png")) is not None

    rt.eval("PackSetup.clear")()
    for leftover in ("res/art.png", "mod_info.json", "strings00_mod.str",
                     ".mo_source"):
        gone = rt.eval("files['%s']" % companion(leftover))
        assert gone is None, "%s survived the teardown" % leftover
    assert rt.eval("dirs['%s']" % companion()) is None


def test_switching_mods_leaves_nothing_of_the_previous_one():
    """The failure this design replaces: one mod's sprite map applied to another
    mod's textures, and a run of 2.5 wearing some of hdmod's."""
    tree = {**pack("mod.a", assets=True), **pack("mod.b", assets=True)}
    tree["Mods/Packs/mod.a/res/only_a.png"] = "A"
    tree["Mods/Packs/mod.a/strings00_mod.str"] = "A text"
    tree["Mods/Packs/mod.b/res/only_b.png"] = "B"
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    rt.eval("PackSetup.apply")(rt.table("mod.b"))

    assert rt.eval("files['%s']" % companion("res/only_b.png")) is not None
    stale_art = rt.eval("files['%s']" % companion("res/only_a.png"))
    assert stale_art is None, "the previous mod's art was still being served"
    stale_text = rt.eval("files['%s']" % companion("strings00_mod.str"))
    assert stale_text is None, "the previous mod's text was still being served"
    assert str(rt.eval("files['%s']" % companion(".mo_source"))) == "mod.b"


def test_neither_mods_own_files_are_ever_touched():
    """An earlier version deleted recursively through a junction into another
    pack's converted output, taking 34 textures and 204 of 205 res files."""
    tree = {**pack("mod.a", assets=True), **pack("mod.b", assets=True)}
    tree["Mods/Packs/mod.a/res/keep.png"] = "mod.a art"
    tree["Mods/Packs/mod.b/res/keep.png"] = "mod.b art"
    tree["Mods/Packs/.db/Mods/mod.a/res/built.dds"] = "mod.a converted"
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    rt.eval("PackSetup.apply")(rt.table("mod.b"))
    rt.eval("PackSetup.clear")()
    for name in ("mod.a", "mod.b"):
        kept = rt.eval("files['Mods/Packs/%s/res/keep.png']" % name)
        assert kept is not None, "%s lost its own files" % name
    built = rt.eval("files['Mods/Packs/.db/Mods/mod.a/res/built.dds']")
    assert built is not None, "deleted a mod's converted textures"

# ----------------------------------------------------------------- load order


def test_selecting_a_mod_comments_out_exactly_that_line():
    tree = {**pack("fyi.spelunky-25-2", assets=True), **pack("fyi.randomizer")}
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("fyi.spelunky-25-2"))
    order = str(rt.eval("files['Mods/Packs/load_order.txt']")).splitlines()
    assert "--fyi.spelunky-25-2" in order
    assert "--player.own-disabled-mod" in order, "touched a line that was not ours"
    assert "fyi.randomizer" in order, "disabled a mod nobody selected"


def test_the_players_load_order_gains_no_line_of_ours():
    """The assets go in a pack that is already listed. Nothing of ours should",
    appear in a file the player reads."""
    before = ORDER.splitlines()
    rt = runtime(load_order=ORDER, tree=pack("mod.a", assets=True))
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    after = str(rt.eval("files['Mods/Packs/load_order.txt']")).splitlines()
    added = [line for line in after if line not in before]
    assert added == [], added


def test_a_script_only_mod_brings_no_assets():
    rt = runtime(load_order=ORDER, tree=pack("mod.a"))
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    assert rt.eval("dirs['Mods/Packs/%s/Data']" % OWN) is None
    assert rt.eval("dirs['Mods/Packs/%s/res']" % OWN) is None


def test_undoing_restores_our_line_and_leaves_the_players_own_alone():
    rt = runtime(load_order=ORDER, tree=pack("fyi.spelunky-25-2", assets=True))
    rt.eval("PackSetup.apply")(rt.table("fyi.spelunky-25-2"))
    rt.eval("PackSetup.clear")()
    order = str(rt.eval("files['Mods/Packs/load_order.txt']")).splitlines()
    assert "fyi.spelunky-25-2" in order, "the mod was not put back"
    assert "--player.own-disabled-mod" in order, "re-enabled the player's own"


def test_a_mod_the_player_had_already_disabled_is_never_switched_on():
    """Claiming a line the player disabled means re-enabling their mod when they
    later deselect it -- a mod turning itself on with nobody having touched it."""
    rt = runtime(load_order=ORDER, tree=pack("player.own-disabled-mod"))
    rt.eval("PackSetup.apply")(rt.table("player.own-disabled-mod"))
    rt.eval("PackSetup.apply")(rt.table())
    order = str(rt.eval("files['Mods/Packs/load_order.txt']")).splitlines()
    assert "--player.own-disabled-mod" in order, "switched on a mod nobody enabled"


# -------------------------------------------------------------------- migration


def test_state_an_older_version_left_in_our_pack_is_cleared():
    """Both machines have this on disk: assets and converted output in the pack that
    holds our code, still served with Modded Online switched off."""
    tree = pack("mod.a", assets=True)
    tree["Mods/Packs/%s/Data" % OWN] = "dir"
    tree["Mods/Packs/%s/res" % OWN] = "dir"
    tree["Mods/Packs/%s/mod_info.json" % OWN] = "{}"
    tree["Mods/Packs/%s/strings00_mod.str" % OWN] = "stale"
    tree["Mods/Packs/.db/Mods/%s/Data" % OWN] = "dir"
    tree["Mods/Packs/.db/Mods/%s/mod.db" % OWN] = "cache"
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.migrate")()
    for stale in ("Data", "res"):
        left = rt.eval("dirs['Mods/Packs/%s/%s']" % (OWN, stale))
        assert left is None, "%s/ was left in our pack" % stale
    for stale in ("mod_info.json", "strings00_mod.str"):
        left = rt.eval("files['Mods/Packs/%s/%s']" % (OWN, stale))
        assert left is None, "%s was left in our pack" % stale
    db = rt.eval("dirs['Mods/Packs/.db/Mods/%s/Data']" % OWN)
    assert db is None, "converted output was left, and is served regardless"
    cache = rt.eval("files['Mods/Packs/.db/Mods/%s/mod.db']" % OWN)
    assert cache is None, "the conversion cache was left, so nothing rebuilds"


def test_hosting_is_refused_when_the_assets_are_not_here():
    """A mod whose assets are not there defines its textures at load against files
    that do not exist, and the process dies where no pcall can see it."""
    rt = runtime(load_order=ORDER, tree=pack("mod.a", assets=True))
    problems = [str(v) for v in rt.eval("PackSetup.setupProblems('mod.a')").values()]
    assert problems != [], "hosting would have gone ahead with no assets"

    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    assert len(rt.eval("PackSetup.setupProblems('mod.a')")) == 0


def test_a_companion_built_from_another_mod_is_reported():
    tree = {**pack("mod.a", assets=True), **pack("mod.b", assets=True)}
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    problems = [str(v) for v in rt.eval("PackSetup.setupProblems('mod.b')").values()]
    assert any("mod.a" in p for p in problems), problems

def test_a_swap_is_refused_rather_than_blended_when_the_old_files_are_in_use():
    """`rmdir` fails SILENTLY on a directory Playlunky has mounted, and it mounted
    every one of these at startup. Building the next mod on top left both mods'
    files in one folder -- a run wearing a mix of two mods' textures, which is what
    was reported. Refusing says so; blending does not."""
    tree = {**pack("mod.a", assets=True), **pack("mod.b", assets=True)}
    tree["Mods/Packs/mod.a/res/only_a.png"] = "A"
    tree["Mods/Packs/mod.b/res/only_b.png"] = "B"
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))

    # the game has the folder open, so every removal quietly does nothing
    rt.execute("realPopen = io.popen")
    rt.execute("""
io.popen = function(cmd)
    if cmd:match("^rmdir") then
        return { read = function() return "" end, close = function() end }
    end
    return realPopen(cmd)
end
""")
    rt.execute("report = PackSetup.apply({'mod.b'})")

    assert rt.eval("report.deferred") is True, "went ahead anyway"
    blended = rt.eval("files['Mods/Packs/%s/res/only_b.png']" % OWN)
    assert blended is None, "mirrored mod.b on top of mod.a -- a mix of both"
    kept = rt.eval("files['Mods/Packs/%s/res/only_a.png']" % OWN)
    assert kept is not None, "left the folder half emptied"
    notes = [str(v) for v in rt.eval("report.notes").values()]
    assert any("CLOSE Spelunky" in n for n in notes), notes


def test_the_armed_selection_is_unchanged_when_a_swap_is_deferred():
    """So the next boot retries it, with the same mod still hosted meanwhile --
    consistent, rather than hosting one mod against another mod's assets."""
    tree = {**pack("mod.a", assets=True), **pack("mod.b", assets=True)}
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    rt.execute("realPopen = io.popen")
    rt.execute("""
io.popen = function(cmd)
    if cmd:match("^rmdir") then
        return { read = function() return "" end, close = function() end }
    end
    return realPopen(cmd)
end
""")
    rt.eval("PackSetup.apply")(rt.table("mod.b"))
    armed = [str(v) for v in rt.eval("PackSetup.selection()").values()]
    assert armed == ["mod.a"], armed

def test_the_pack_a_previous_version_created_is_removed():
    """One release moved the assets into their own pack. It could not work --
    Overlunky resolves a relative asset path against the pack root of the script
    that ASKS -- and the revert stopped creating it while leaving the one already
    on disk: still listed, still mounted, still serving a mod's textures into every
    session after it. Disabling it by hand was what finally fixed the textures."""
    legacy = "fyi.modded-online-assets"
    order = chr(10).join(["fyi.spelunky-25-2", legacy, OWN]) + chr(10)
    tree = pack("mod.a", assets=True)
    tree["Mods/Packs/%s" % legacy] = "dir"
    tree["Mods/Packs/%s/res" % legacy] = "dir"
    tree["Mods/Packs/%s/res/stale.png" % legacy] = "another mod's art"
    tree["Mods/Packs/.db/Mods/%s" % legacy] = "dir"
    rt = runtime(load_order=order, tree=tree)

    rt.eval("PackSetup.migrate")()
    assert rt.eval("dirs['Mods/Packs/%s']" % legacy) is None, "the folder survived"
    db = rt.eval("dirs['Mods/Packs/.db/Mods/%s']" % legacy)
    assert db is None, "its converted textures survived, and are still served"


def test_its_load_order_line_goes_too():
    """Listed is what makes Playlunky mount it. A folder removed but still listed
    is only half a fix."""
    legacy = "fyi.modded-online-assets"
    order = chr(10).join(["fyi.spelunky-25-2", "--" + legacy, OWN]) + chr(10)
    rt = runtime(load_order=order, tree=pack("mod.a"))
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    lines = str(rt.eval("files['Mods/Packs/load_order.txt']")).splitlines()
    assert not any(legacy in line for line in lines), lines

def test_the_mods_converted_res_is_borrowed_but_never_its_data():
    """Playlunky never converted our copies -- 205 raw files and zero DDS beside
    them, while the mod's own tree had 176 -- so a hosted define_texture had nothing
    to load and killed the process. res/ is safe to borrow: an image_map reads FROM
    res and writes INTO Data, so nothing is baked into a res conversion. Data is not
    safe, and borrowing it is what made hdmod's wall decoration wrong."""
    tree = pack("mod.a", assets=True)
    tree["Mods/Packs/.db/Mods/mod.a"] = "dir"
    tree["Mods/Packs/.db/Mods/mod.a/res"] = "dir"
    tree["Mods/Packs/.db/Mods/mod.a/res/cameo.DDS"] = "converted"
    tree["Mods/Packs/.db/Mods/mod.a/Data"] = "dir"
    tree["Mods/Packs/.db/Mods/mod.a/Data/patched.DDS"] = "map already applied"
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))

    borrowed = rt.eval("files['Mods/Packs/.db/Mods/%s/res/cameo.DDS']" % OWN)
    assert borrowed is not None, "define_texture would have nothing to load"
    data = rt.eval("files['Mods/Packs/.db/Mods/%s/Data/patched.DDS']" % OWN)
    assert data is None, "borrowed Data -- the image_map gets applied twice"


def test_a_mod_whose_textures_were_never_converted_is_reported():
    """Its converted tree is built when it runs on its own. Hosted without one,
    every texture it defines has nothing behind it."""
    rt = runtime(load_order=ORDER, tree=pack("mod.a", assets=True))
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    steps = [str(v) for v in rt.eval("PackSetup.apply({'mod.a'}).steps").values()]
    assert any("MISSING" in s and "res" in s for s in steps), steps


def test_hosting_is_refused_when_the_converted_res_did_not_arrive():
    tree = pack("mod.a", assets=True)
    tree["Mods/Packs/.db/Mods/mod.a"] = "dir"
    tree["Mods/Packs/.db/Mods/mod.a/res"] = "dir"
    tree["Mods/Packs/.db/Mods/mod.a/res/cameo.DDS"] = "converted"
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    assert len(rt.eval("PackSetup.setupProblems('mod.a')")) == 0

    rt.execute("dirs['Mods/Packs/.db/Mods/%s/res'] = nil" % OWN)
    problems = [str(v) for v in rt.eval("PackSetup.setupProblems('mod.a')").values()]
    assert any("converted" in p for p in problems), problems

def test_a_working_setup_survives_a_boot():
    """This delegated straight to the teardown for four versions, so every boot
    deleted the setup that was working and rebuilt it. Playlunky mounts before any
    of that runs, so its view was permanently one boot stale -- after switching to
    2.5 the game still showed the previous mod's textures."""
    tree = pack("mod.a", assets=True)
    tree["Mods/Packs/mod.a/res/art.png"] = "art"
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))

    steps = [str(v) for v in rt.eval("PackSetup.migrate()").values()]
    assert steps == [], "the boot tore down its own working setup: %s" % steps
    kept = rt.eval("files['Mods/Packs/%s/res/art.png']" % OWN)
    assert kept is not None, "the live assets were deleted at boot"


def test_another_mods_leftovers_are_still_cleared():
    """The distinction migrate is for: assets belonging to the mod that is ARMED
    are the current setup; anything else is residue."""
    tree = {**pack("mod.a", assets=True), **pack("mod.b", assets=True)}
    rt = runtime(load_order=ORDER, tree=tree)
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    # arm mod.b while mod.a's files are still here, as a half-finished swap would
    rt.execute("files['Mods/Packs/%s/mo_host.on'] = 'mod.b'" % OWN)

    steps = [str(v) for v in rt.eval("PackSetup.migrate()").values()]
    assert steps != [], "left another mod's files in place"
    assert rt.eval("dirs['Mods/Packs/%s/res']" % OWN) is None


def test_leftovers_are_cleared_when_nothing_is_armed():
    rt = runtime(load_order=ORDER, tree=pack("mod.a", assets=True))
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    rt.execute("files['Mods/Packs/%s/mo_host.on'] = nil" % OWN)
    rt.eval("PackSetup.migrate")()
    assert rt.eval("dirs['Mods/Packs/%s/res']" % OWN) is None

def test_the_vanilla_atlases_an_image_map_patches_are_recorded_and_put_back():
    """An image_map does not only affect the pack that declares it. Playlunky
    applies it to the VANILLA texture and writes the result to a GLOBAL tree shared
    by every session -- twelve of those were found carrying hdmod's patches with no
    script mod enabled at all. Nothing inside our own pack could fix that, which is
    why cleaning it repeatedly did not."""
    tree = pack("mod.a", assets=True)
    tree["Mods/Packs/mod.a/mod_info.json"] = '{"image_map": {"res/boulder.png": {"Data/Textures/deco_ice.png": []}, "res/worm.png": {"Data/Textures/deco_eggplant.png": []}}}'
    tree["Mods/Packs/.db/Data/Textures/deco_ice.DDS"] = "patched vanilla"
    tree["Mods/Packs/.db/Data/Textures/deco_eggplant.DDS"] = "patched vanilla"
    tree["Mods/Packs/.db/Data/Textures/unrelated.DDS"] = "somebody else's"
    tree["Mods/Packs/.db/mod.db"] = "global index"
    rt = runtime(load_order=ORDER, tree=tree)

    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    recorded = str(rt.eval("files['Mods/Packs/%s/mo_patched_textures.txt']" % OWN))
    assert "deco_ice" in recorded and "deco_eggplant" in recorded, recorded

    rt.eval("PackSetup.clear")()
    for name in ("deco_ice", "deco_eggplant"):
        left = rt.eval("files['Mods/Packs/.db/Data/Textures/%s.DDS']" % name)
        assert left is None, "%s stayed patched for every other session" % name
    other = rt.eval("files['Mods/Packs/.db/Data/Textures/unrelated.DDS']")
    assert other is not None, "removed a global texture that was not ours"
    index = rt.eval("files['Mods/Packs/.db/mod.db']")
    assert index is None, "left the index saying the patched files are current"


def test_a_mod_with_no_image_map_records_nothing():
    rt = runtime(load_order=ORDER, tree=pack("mod.a", assets=True))
    rt.eval("PackSetup.apply")(rt.table("mod.a"))
    recorded = rt.eval("files['Mods/Packs/%s/mo_patched_textures.txt']" % OWN)
    assert recorded is None
