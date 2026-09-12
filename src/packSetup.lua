--- Giving a hosted mod its assets, and taking them away again completely.
---
--- Hosting a mod means running its Lua in OUR state. Playlunky would otherwise run
--- `main.lua` a second time in its own, so the mod has to be disabled in
--- `load_order.txt` -- and disabling it also stops Playlunky mounting its textures,
--- sounds and level files. Supplying those back is what this module is for. There
--- is no assets-only mode in `playlunky.ini`; a pack is loaded whole or not at all.
---
--- **The assets go in THIS pack, and that is not a choice.**
---
--- Overlunky resolves a relative asset path against the pack root of the script
--- that asks -- `list_dir` is "relative to the script root", `create_sound` is
--- "relative to this script" -- and the script asking is ours, because hosting
--- means running the mod's Lua here. hdmod opens with
--- `define_texture("res/locked_feat.png")`, and that path is looked for in our
--- folder. A separate assets pack was tried: tidier in every way except the one
--- that matters, and it died on the first texture.
---
--- So the discipline has to come from the teardown instead. Every bug here had one
--- shape -- something outliving the mod it belonged to. A stale `mod_info.json`
--- applying one mod's sprite map to another's textures. Playlunky's converted
--- output surviving in `.db/Mods/<us>/Data/Textures` with no `Data` behind it,
--- still served with Modded Online switched off entirely.
---
--- `clearAssets` therefore removes ALL of it, unconditionally, and `apply` calls it
--- before every build. Nothing is kept because it looks current; there is one path
--- in and one path out.
---
--- Hard links rather than junctions. A junction is a reparse point, and a directory
--- walk that skips those -- as file-system code often does, to avoid loops -- never
--- sees the files, while Lua's `io.open` follows one without noticing. That gap is
--- a texture the engine cannot find and Lua can, which crashed one machine on boot
--- for six versions. A hard link is another name for the same file: nothing to
--- traverse, and no extra disk.
---
--- Nothing outside our own pack and its converted tree is ever written or deleted.
--- An earlier version junctioned into another mod's converted output and deleted
--- recursively through it, destroying textures that mod needed to boot on its own.
--- That is what the boundary in `removeTree` is for.
local module = {}

local PACKS_DIR = "Mods/Packs"
local LOAD_ORDER_PATH = PACKS_DIR .. "/load_order.txt"
local DB_DIR = PACKS_DIR .. "/.db/Mods"

--- (see the note at the top of this file for why the assets live here)

--- Hard-linked in. A mod with none of these is script-only, which is
--- what lets several be hosted at once (see `module.plan`).
local LINK_DIRS = { "Data", "res", "soundbank" }

--- Copied, because a hard link needs a file and Playlunky reads these per pack.
---
--- `savegame.sav` and `save.dat` are NOT here. They are the mod's PROGRESSION, and
--- this list is copied on every apply -- which would throw away everything played
--- under Modded Online each time the same mod was re-armed. src/saveShare.lua seeds
--- them instead, once, only when we do not already have a copy. They are still
--- listed for teardown below, so switching mods does start the new one clean.
---
--- Seeding still matters for the reason it always did: hdmod reads its shortcut
--- unlocks straight out of the savegame and ships a fresh one, and without it the
--- game handed hdmod the player's real save and the HD campaign opened with
--- everything already unlocked.
local COPY_FILES = { "shaders_mod.hlsl" }

--- Playlunky merges every `*_mod.str` it finds into one string file.
local COPY_GLOB = "*_mod.str"

--- Playlunky reads sprite remapping out of a pack's `mod_info.json`. hdmod has 27
--- entries slicing its own `res/*.png` into vanilla atlases, which is why its jungle
--- snail kept the vanilla sprite while everything served whole looked right.
---
--- Only the map is taken; the name, version and author would be the wrong pack's.
local INFO_FILE = "mod_info.json"

--- Playlunky's converted output for this pack, cleared with everything else.
local DB_DIRS = { "Data", "res", "Guidebook" }

--- The one converted folder we borrow from the mod, and the one we must not.
---
--- Playlunky never converted our copies -- 205 raw files in `res/` and zero DDS
--- beside them, while the mod's own tree had 176 -- so a hosted
--- `define_texture("res/cameo_yang.png")` had nothing to load and killed the process.
--- That is why hdmod runs perfectly on its own and dies hosted.
---
--- `res/` is safe to borrow: it holds the mod's own images, converted plainly. An
--- `image_map` reads FROM `res/` and writes INTO `Data/`, so nothing is baked into a
--- res conversion.
---
--- `Data/` is not safe, and borrowing it is what made hdmod's wall decoration wrong:
--- the mod's copy already has the map applied, and Playlunky then reads our copy of
--- the same map and applies it again on top of itself. Playlunky builds ours.
local DB_BORROW = { "res" }

--- The shipping build. Two enabled copies of Modded Online would both bind the UDP
--- port and register every callback twice, so it is never offered as a mod to host.
local SHIPPING_PACK = "fyi.modded-online"

--- Names the pack(s) to host. A FILE and not a setting, for the reason modHost gives:
--- if hosting a mod takes the game down before a menu can be drawn, deleting a file
--- is the only recovery that does not need the game to start.
local HOST_FLAG = "mo_host.on"

--- Which load_order lines WE commented, so they can be restored exactly.
local UNDO_FILE = "mo_setup_undo.txt"

--- Written beside the assets, naming the mod they were built from.
local SOURCE_MARK = ".mo_source"

--- Vanilla atlases we caused Playlunky to patch, so they can be put back.
---
--- An `image_map` does not only affect the pack that declares it. Playlunky applies
--- it to the VANILLA texture and writes the result to a GLOBAL tree,
--- `.db/Data/Textures/`, shared by every session. Twelve of those were found stamped
--- with hdmod's patches while no script mod was enabled at all -- our pack had
--- carried hdmod's map, and taking the map away gave Playlunky no reason to undo
--- what it had already written.
---
--- Nothing inside our own pack could ever have fixed that, which is why cleaning it
--- repeatedly did not. The names are recorded when the map is installed and the
--- generated files deleted when it is removed; `.db/Original/` holds the pristine
--- copies Playlunky rebuilds them from.
local PATCHED_MARK = "mo_patched_textures.txt"

--- Playlunky's global generated tree and the index that says what is in it.
local DB_GLOBAL_TEXTURES = PACKS_DIR .. "/.db/Data/Textures"
local DB_GLOBAL_INDEX = PACKS_DIR .. "/.db/mod.db"

--- A pack one version briefly created, and this one has to clean up after.
---
--- The assets were moved there for a release, on the reasoning that a folder you can
--- delete whole cannot leave anything behind. It could not work: Overlunky resolves a
--- relative asset path against the pack root of the script that ASKS, and the script
--- asking is ours, so the mod's first `define_texture` found nothing. Reverting
--- stopped creating it and left the one already on disk -- still listed, still
--- mounted, still serving a mod's textures into every session after it.
---
--- Removed on sight, folder, converted tree and load_order line.
local LEGACY_ASSET_PACK = "fyi.modded-online-assets"

-- ------------------------------------------------------------------- primitives

--- @param path string
--- @return string?
local function readTextFile(path)
    local handle = io.open(path, "r")
    if handle == nil then
        return nil
    end
    local body = handle:read("*a")
    handle:close()
    return body
end

--- @param path string
--- @param body string
--- @return boolean
local function writeTextFile(path, body)
    return pcall(function()
        local handle = io.open(path, "w")
        if handle == nil then
            error("cannot write " .. path)
        end
        handle:write(body)
        handle:close()
    end)
end

--- @param path string
--- @return boolean
local function fileExists(path)
    local handle = io.open(path, "r")
    if handle == nil then
        return false
    end
    handle:close()
    return true
end

--- Run a command and hand back whatever it said.
--- @param cmd string
--- @return string
local function shell(cmd)
    local out = ""
    pcall(function()
        local pipe = io.popen(cmd .. " 2>&1")
        if pipe == nil then
            return
        end
        out = pipe:read("*a") or ""
        pipe:close()
    end)
    return out or ""
end

--- @param path string
--- @return string
local function win(path)
    return (path:gsub("/", "\\"))
end

--- @param path string
--- @return boolean
local function dirExists(path)
    local probe = shell(string.format('if exist "%s\\" (echo yes)', win(path)))
    return probe:find("yes", 1, true) ~= nil
end

--- Is this a junction, left by a version that used them?
---
--- Only ever asked before deleting. `rmdir /s` on a folder of hard links removes
--- those names; the same command THROUGH a junction destroys the mod it points at.
--- @param path string
--- @return boolean
local function isJunction(path)
    local parent, leaf = path:match("^(.*)/([^/]+)$")
    if parent == nil then
        return false
    end
    local listing = shell(string.format('dir /al "%s"', win(parent)))
    for line in listing:gmatch("[^\r\n]+") do
        if line:find(leaf, 1, true) ~= nil and line:match("%[(.-)%]") ~= nil then
            return true
        end
    end
    return false
end

--- @param rest string?
--- @return string
local function assetPath(rest)
    if rest == nil then
        return PACKS_DIR .. "/" .. PackDir()
    end
    return PackPath(rest)
end

--- Delete a directory of ours, and refuse anything that is not.
---
--- A boundary, not a check. An earlier version junctioned into another pack's
--- converted output and deleted recursively through it, taking 34 texture files and
--- 204 of 205 res files -- and that mod then would not boot on its own at all.
--- Detection can be wrong; a boundary cannot.
--- @param path string
--- @return boolean removed
local function removeTree(path)
    local normalised = path:gsub("\\", "/")
    local ours = {
        PACKS_DIR .. "/" .. PackDir(),
        DB_DIR .. "/" .. PackDir(),
        PACKS_DIR .. "/" .. LEGACY_ASSET_PACK,
        DB_DIR .. "/" .. LEGACY_ASSET_PACK,
    }
    local allowed = false
    for _, root in ipairs(ours) do
        if normalised == root or normalised:sub(1, #root + 1) == root .. "/" then
            allowed = true
        end
    end
    if not allowed then
        errorf("mod host: REFUSING to delete %s -- Modded Online has no business"
            .. " removing another pack's files.", path)
        return false
    end
    if isJunction(normalised) then
        shell(string.format('rmdir "%s"', win(normalised))) -- the link, never through it
    else
        shell(string.format('rmdir /s /q "%s"', win(normalised)))
    end
    return not dirExists(normalised)
end

--- Every file matching COPY_GLOB in a folder.
--- @param dir string
--- @return string[]
local function globFiles(dir)
    local found = {}
    local listing = shell(string.format('dir /b "%s\\%s"', win(dir), COPY_GLOB))
    for line in listing:gmatch("[^\r\n]+") do
        local name = line:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" and name:find(" ") == nil and name:find("%.str$") ~= nil then
            found[#found + 1] = name
        end
    end
    return found
end

--- Mirror a folder as real directories of hard links.
--- @param source string
--- @param dest string
--- @return string
local function mirrorTree(source, dest)
    return shell('powershell -NoProfile -ExecutionPolicy Bypass -Command "'
        .. "$ErrorActionPreference='SilentlyContinue';"
        .. "$s=(Resolve-Path -LiteralPath '" .. win(source) .. "').Path;"
        .. "$d='" .. win(dest) .. "';"
        .. "New-Item -ItemType Directory -Force -Path $d | Out-Null;"
        .. "Get-ChildItem -LiteralPath $s -Recurse -File | ForEach-Object{"
        .. "$t=Join-Path $d $_.FullName.Substring($s.Length+1);"
        .. "$p=Split-Path $t;"
        .. "if(-not(Test-Path -LiteralPath $p)){New-Item -ItemType Directory -Force -Path $p|Out-Null};"
        .. "if(-not(Test-Path -LiteralPath $t)){New-Item -ItemType HardLink -Path $t -Target $_.FullName|Out-Null}"
        .. "}"
        .. '"')
end

-- ------------------------------------------------------------------- discovery

--- A stable, valid identifier for a pack's option.
---
--- Playlunky reads options back as `options.<name>`, so it has to be an identifier
--- and has to stay the same between sessions. Sanitising alone is not enough --
--- "a.b" and "a-b" would collide -- so a hash of the true name is appended.
--- @param packName string
--- @return string
function module.optionKey(packName)
    local hash = 5381
    for index = 1, #packName do
        hash = (hash * 33 + packName:byte(index)) % 0xFFFFFF
    end
    return "mo_host_" .. packName:gsub("[^%w]", "_") .. "_" .. string.format("%06x", hash)
end

--- Every script pack installed, whether or not load_order has it enabled.
---
--- By directory rather than by load order: a pack we host IS disabled there, and a
--- list read from that file would lose the mod the moment it was selected.
--- @return string[]
function module.installedScriptPacks()
    local names, own = {}, PackDir()
    local listing = shell(string.format('dir /b /ad "%s"', win(PACKS_DIR)))
    for line in listing:gmatch("[^\r\n]+") do
        local name = line:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" and name:sub(1, 1) ~= "." and name ~= own
            and name ~= SHIPPING_PACK
            and fileExists(PACKS_DIR .. "/" .. name .. "/main.lua") then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

--- Which of the linkable asset directories a pack actually ships.
--- @param packName string
--- @return string[]
function module.assetDirs(packName)
    local found = {}
    for _, dir in ipairs(LINK_DIRS) do
        if dirExists(PACKS_DIR .. "/" .. packName .. "/" .. dir) then
            found[#found + 1] = dir
        end
    end
    return found
end

--- Which mod the assets here were built from, or nil if there are none.
--- @return string?
function module.assetSource()
    local body = readTextFile(assetPath(SOURCE_MARK))
    if body == nil then
        return nil
    end
    return (body:gsub("%s+", ""))
end

--- The packs currently armed for hosting, read from the flag file.
--- @return string[]
function module.selection()
    local names = {}
    local body = readTextFile(PackPath(HOST_FLAG))
    if body == nil then
        return names
    end
    for name in body:gmatch("[^\r\n,]+") do
        local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            names[#names + 1] = trimmed
        end
    end
    return names
end

--- @param names string[]
--- @return boolean
local function writeSelection(names)
    if #names == 0 then
        os.remove(PackPath(HOST_FLAG))
        return true
    end
    return writeTextFile(PackPath(HOST_FLAG), table.concat(names, "\n") .. "\n")
end

--- Decide what a requested selection can actually be given, and why.
---
--- The one hard limit is assets: every hosted mod's `Data` and `res` land in the
--- this pack under those exact names, so a second asset-bearing mod has nowhere to
--- go. Script-only mods have no such problem and any number can be hosted together.
--- @param wanted string[]
--- @return string[] accepted, string[] rejected, string[] notes
function module.plan(wanted)
    local accepted, rejected, notes = {}, {}, {}
    local assetOwner = nil
    for _, name in ipairs(wanted) do
        if #module.assetDirs(name) == 0 then
            accepted[#accepted + 1] = name
        elseif assetOwner == nil then
            assetOwner = name
            accepted[#accepted + 1] = name
        else
            rejected[#rejected + 1] = name
            notes[#notes + 1] = string.format(
                "%s also ships textures, and %s already claims the asset folders."
                .. " Only one mod with assets can be hosted at a time.", name, assetOwner)
        end
    end
    return accepted, rejected, notes
end

--- Which pack in a selection claims the asset folders, if any.
--- @param names string[]
--- @return string?
local function assetOwnerOf(names)
    for _, name in ipairs(names) do
        if #module.assetDirs(name) > 0 then
            return name
        end
    end
    return nil
end

-- ------------------------------------------------------------------ load order

--- @return string[]
local function readUndo()
    local names = {}
    local body = readTextFile(PackPath(UNDO_FILE))
    if body == nil then
        return names
    end
    for line in body:gmatch("[^\r\n]+") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            names[#names + 1] = trimmed
        end
    end
    return names
end

--- Comment out the hosted packs, restore any we previously commented, and add or
--- and restore any we previously commented.
---
--- Line-level and reversible rather than a whole-file backup: a backup taken once
--- goes stale the moment the player installs another mod, and restoring it would
--- silently undo their own edits. A line we did not comment is never claimed, which
--- is what stopped mods switching themselves back on in Modlunky.
--- @param disable string[]
--- @return string[] changed
local function rewriteLoadOrder(disable)
    local wanted, changed = {}, {}
    for _, name in ipairs(disable) do
        wanted[name] = true
    end
    local previously = {}
    for _, name in ipairs(readUndo()) do
        previously[name] = true
    end

    local lines = {}
    local ok = pcall(function()
        for line in io.lines(LOAD_ORDER_PATH) do
            lines[#lines + 1] = line
        end
    end)
    if not ok or #lines == 0 then
        return changed
    end

    local out, stillOurs = {}, {}
    for _, line in ipairs(lines) do
        local bare = line:gsub("^%s*%-%-", ""):gsub("^%s+", ""):gsub("%s+$", "")
        local commented = line:match("^%s*%-%-") ~= nil
        if bare == LEGACY_ASSET_PACK then
            changed[#changed + 1] = "removed " .. LEGACY_ASSET_PACK
                .. " (a pack one version created and should not have)"
        elseif wanted[bare] and not commented then
            out[#out + 1] = "--" .. line
            changed[#changed + 1] = "disabled " .. bare
            stillOurs[#stillOurs + 1] = bare
        elseif wanted[bare] then
            -- Already commented. Claim it ONLY if we were the ones who commented it:
            -- owning a line the player disabled themselves means re-enabling their
            -- mod when they later deselect it, with nobody having touched it.
            out[#out + 1] = line
            if previously[bare] then
                stillOurs[#stillOurs + 1] = bare
            end
        elseif previously[bare] and commented then
            out[#out + 1] = line:gsub("^(%s*)%-%-", "%1")
            changed[#changed + 1] = "re-enabled " .. bare
        else
            out[#out + 1] = line
        end
    end
    writeTextFile(LOAD_ORDER_PATH, table.concat(out, "\n") .. "\n")
    if #stillOurs == 0 then
        os.remove(PackPath(UNDO_FILE))
    else
        writeTextFile(PackPath(UNDO_FILE), table.concat(stillOurs, "\n") .. "\n")
    end
    return changed
end

-- ------------------------------------------------------------ assets in, out

--- Remove every trace of a hosted mod from this pack.
---
--- Unconditional, and called before every build. Nothing is kept because it looks
--- current: deciding what to keep is how one mod ended up serving another mod's
--- files, four separate times.
--- @return string[] steps, boolean complete
local function clearAssets()
    local steps, complete = {}, true
    for _, dir in ipairs(LINK_DIRS) do
        if dirExists(assetPath(dir)) then
            removeTree(assetPath(dir))
            if dirExists(assetPath(dir)) then
                -- `rmdir` fails SILENTLY on a directory Playlunky has mounted, and it
                -- mounted every one of these at startup. Building the next mod on top
                -- then leaves both mods' files in one folder -- which is a run wearing
                -- a mix of two mods' textures, and is what this return value prevents.
                complete = false
                steps[#steps + 1] = dir .. "/ COULD NOT be removed (the game has it open)"
            else
                steps[#steps + 1] = dir .. "/ removed"
            end
        end
    end
    -- Playlunky's converted output for this pack. It outlives the assets it was
    -- built from and is keyed to the folder rather than the load order, so it is
    -- served even with Modded Online disabled -- which is how a hosted mod's
    -- textures turned up in a different mod entirely.
    for _, dir in ipairs(DB_DIRS) do
        local db = DB_DIR .. "/" .. PackDir() .. "/" .. dir
        if dirExists(db) then
            removeTree(db)
            steps[#steps + 1] = "converted " .. dir .. "/ removed"
        end
    end
    local files = { INFO_FILE, SOURCE_MARK, "mo_assets_from.txt" }
    for _, name in ipairs(COPY_FILES) do
        files[#files + 1] = name
    end
    -- the seeded save files too: a different mod means a different progression
    if SaveShare ~= nil and SaveShare.artifacts ~= nil then
        for _, name in ipairs(SaveShare.artifacts()) do
            files[#files + 1] = name
        end
    end
    for _, name in ipairs(globFiles(PACKS_DIR .. "/" .. PackDir())) do
        files[#files + 1] = name
    end
    for _, name in ipairs(files) do
        if fileExists(PackPath(name)) then
            os.remove(PackPath(name))
            steps[#steps + 1] = name .. " removed"
        end
    end
    local cache = DB_DIR .. "/" .. PackDir() .. "/mod.db"
    if fileExists(cache) then
        os.remove(cache)
        steps[#steps + 1] = "conversion cache cleared"
    end

    -- the vanilla atlases our image_map made Playlunky rewrite, globally
    local patched = readTextFile(PackPath(PATCHED_MARK))
    if patched ~= nil then
        local restored = 0
        for leaf in patched:gmatch("[^\r\n]+") do
            local name = leaf:gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then
                for _, ext in ipairs({ ".DDS", ".png" }) do
                    local target = DB_GLOBAL_TEXTURES .. "/" .. name .. ext
                    if fileExists(target) then
                        os.remove(target)
                        restored = restored + 1
                    end
                end
            end
        end
        os.remove(PackPath(PATCHED_MARK))
        if restored > 0 then
            -- and the index, or Playlunky believes they are still current
            if fileExists(DB_GLOBAL_INDEX) then
                os.remove(DB_GLOBAL_INDEX)
            end
            steps[#steps + 1] = string.format(
                "%d patched vanilla atlases removed -- Playlunky rebuilds them from"
                .. " .db/Original on the next launch", restored)
        end
    end
    return steps, complete
end

--- Bring one mod's assets in.
--- @param packName string
--- @return string[] steps
local function buildAssets(packName)
    local steps = {}
    for _, dir in ipairs(module.assetDirs(packName)) do
        mirrorTree(PACKS_DIR .. "/" .. packName .. "/" .. dir, assetPath(dir))
        steps[#steps + 1] = dir .. (dirExists(assetPath(dir))
            and " linked" or " FAILED to link")
    end

    local toCopy = {}
    for _, name in ipairs(COPY_FILES) do
        toCopy[#toCopy + 1] = name
    end
    for _, name in ipairs(globFiles(PACKS_DIR .. "/" .. packName)) do
        toCopy[#toCopy + 1] = name
    end
    for _, name in ipairs(toCopy) do
        local source = PACKS_DIR .. "/" .. packName .. "/" .. name
        if fileExists(source) then
            shell(string.format('copy /y "%s" "%s" >nul',
                win(source), win(assetPath(name))))
            steps[#steps + 1] = name .. " copied"
        end
    end
    -- The mod's progression, seeded ONCE. See COPY_FILES for why it is not in
    -- that list.
    if SaveShare ~= nil and SaveShare.seedFrom ~= nil then
        local seeded = SaveShare.seedFrom(packName)
        if seeded > 0 then
            steps[#steps + 1] = seeded .. " save file(s) seeded from the mod"
        end
    end

    -- the sprite remapping, without the identity that comes with it
    local info = readTextFile(PACKS_DIR .. "/" .. packName .. "/" .. INFO_FILE)
    if info ~= nil then
        pcall(function()
            local parsed = NetJson.decode(info)
            if type(parsed) ~= "table" or type(parsed.image_map) ~= "table" then
                return
            end
            writeTextFile(assetPath(INFO_FILE),
                NetJson.encode({ image_map = parsed.image_map }))
            steps[#steps + 1] = INFO_FILE .. " sprite remapping copied"
            -- remember what this will make Playlunky rewrite globally
            local targets = {}
            for _, dests in pairs(parsed.image_map) do
                if type(dests) == "table" then
                    for dest in pairs(dests) do
                        local leaf = tostring(dest):match("([^/\\]+)%.%w+$")
                        if leaf ~= nil then
                            targets[leaf] = true
                        end
                    end
                end
            end
            local names = {}
            for leaf in pairs(targets) do
                names[#names + 1] = leaf
            end
            table.sort(names)
            if #names > 0 then
                writeTextFile(PackPath(PATCHED_MARK), table.concat(names, "\n"))
                steps[#steps + 1] = string.format(
                    "%d vanilla atlases will be patched globally, and are recorded so"
                    .. " they can be put back", #names)
            end
        end)
    end

    -- the mod's converted `res/`, because ours is never built (see DB_BORROW)
    local dbHere = DB_DIR .. "/" .. PackDir()
    for _, dir in ipairs(DB_BORROW) do
        local source = DB_DIR .. "/" .. packName .. "/" .. dir
        if dirExists(source) then
            shell(string.format('if not exist "%s\\" (mkdir "%s")',
                win(dbHere), win(dbHere)))
            mirrorTree(source, dbHere .. "/" .. dir)
            steps[#steps + 1] = "converted " .. dir .. (dirExists(dbHere .. "/" .. dir)
                and " linked" or " FAILED to link")
        else
            steps[#steps + 1] = "converted " .. dir .. " MISSING from " .. packName
                .. " -- launch it on its own once so Playlunky builds it"
        end
    end

    writeTextFile(assetPath(SOURCE_MARK), packName)
    return steps
end

-- --------------------------------------------------------------------- public

--- Clear whatever an older version left behind -- and NOTHING that is in use.
---
--- This delegated straight to the teardown for four versions, which meant every
--- boot deleted the setup that was working and built it again. Playlunky mounts
--- before any of that runs, so its view was permanently one boot stale: after
--- switching to 2.5 the game was still showing hdmod's textures, because the
--- textures it had mounted were the ones the PREVIOUS boot had rebuilt.
---
--- The `.mo_source` mark is what tells the two apart. Assets belonging to the mod
--- that is armed are the current setup; anything else is residue.
--- @return string[] steps
function module.migrate()
    local steps = {}
    local armed = assetOwnerOf(module.selection())
    local here = module.assetSource()
    if armed == nil or here ~= armed then
        steps = clearAssets()
    end
    for _, path in ipairs({ PACKS_DIR .. "/" .. LEGACY_ASSET_PACK,
                            DB_DIR .. "/" .. LEGACY_ASSET_PACK }) do
        if dirExists(path) then
            removeTree(path)
            steps[#steps + 1] = LEGACY_ASSET_PACK .. " removed"
                .. (dirExists(path) and " FAILED (close the game and relaunch)" or "")
        end
    end
    return steps
end

--- Is anything of a hosted mod still lying about?
--- @return boolean
function module.hasLeftovers()
    for _, dir in ipairs(LINK_DIRS) do
        if dirExists(PackPath(dir)) then
            return true
        end
    end
    for _, dir in ipairs(DB_DIRS) do
        if dirExists(DB_DIR .. "/" .. PackDir() .. "/" .. dir) then
            return true
        end
    end
    return fileExists(PackPath(INFO_FILE)) or fileExists(PackPath(SOURCE_MARK))
end

--- Everything wrong with a pack's setup, in words a player can act on.
---
--- Checked BEFORE hosting rather than reported after: a mod whose assets are not
--- actually there defines its textures at load against files that do not exist, and
--- the process dies in native code where no pcall of ours will ever see it.
--- @param packName string
--- @return string[]
function module.setupProblems(packName)
    local problems = {}
    local assets = module.assetDirs(packName)
    if #assets == 0 then
        return problems -- script-only: there is nothing to arrange
    end
    local from = module.assetSource()
    if from ~= packName then
        problems[#problems + 1] = string.format(
            "the assets here are %s's, not %s's -- untick the mod and tick it again",
            tostring(from), packName)
    end
    for _, dir in ipairs(assets) do
        if not dirExists(assetPath(dir)) then
            problems[#problems + 1] = string.format(
                "%s/ never reached this pack -- the setup did not run, or could not"
                .. " create it", dir)
        end
    end
    -- without these, define_texture has nothing to load and kills the process
    for _, dir in ipairs(DB_BORROW) do
        if dirExists(DB_DIR .. "/" .. packName .. "/" .. dir)
            and not dirExists(DB_DIR .. "/" .. PackDir() .. "/" .. dir) then
            problems[#problems + 1] = string.format(
                "the converted %s/ never reached this pack -- a texture the mod defines"
                .. " would have nothing to load", dir)
        end
    end
    return problems
end

--- Put the whole arrangement in place for a selection of packs.
--- @param wanted string[]
--- @return table report
function module.apply(wanted)
    local accepted, rejected, notes = module.plan(wanted)
    local owner = assetOwnerOf(accepted)

    -- Always from scratch. Rebuilding costs a moment; deciding what to keep is how
    -- the previous design ended up serving one mod's files under another mod's name.
    local steps, cleared = clearAssets()
    if owner ~= nil and not cleared then
        -- Never build on top of a folder that still holds another mod's files. That
        -- is not a partial success; it is two mods' textures in one place, which is
        -- worse than doing nothing and says nothing about itself.
        notes[#notes + 1] = "the previous mod's files are still in use by the running"
            .. " game, so they could not be cleared. CLOSE Spelunky and start it again"
            .. " -- the swap finishes on the next launch, before anything is hosted."
        return {
            accepted = {},
            rejected = rejected,
            notes = notes,
            steps = steps,
            changed = {},
            deferred = true,
        }
    end
    if owner ~= nil then
        for _, step in ipairs(buildAssets(owner)) do
            steps[#steps + 1] = owner .. ": " .. step
        end
    end

    local changed = rewriteLoadOrder(accepted)
    if not writeSelection(accepted) then
        notes[#notes + 1] = "could not write " .. HOST_FLAG
            .. " -- nothing will be hosted next launch"
    end
    return {
        accepted = accepted,
        rejected = rejected,
        notes = notes,
        steps = steps,
        changed = changed,
    }
end

--- Undo everything: no assets, no flag, load_order as it was.
--- @return table report
function module.clear()
    local steps, cleared = clearAssets()
    if not cleared then
        steps[#steps + 1] = "CLOSE Spelunky and start it again -- the rest is removed"
            .. " on the next launch, before anything is mounted"
    end
    local changed = rewriteLoadOrder({})
    writeSelection({})
    return { accepted = {}, rejected = {}, notes = {}, steps = steps, changed = changed }
end

PackSetup = module
return module
