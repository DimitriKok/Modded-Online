--- Modded Online — the menu probe: what the game's menus look like from Lua.
---
--- Armed by `mo_menuprobe.on` in the pack folder; without it this module checks for
--- the file once and does nothing else. It writes `mo_menuprobe.txt`, one line at a
--- time, opened and closed per line like mo_journal.txt, so the file survives
--- whatever happens next. Started fresh at each launch and bounded at 400 lines;
--- a line repeated back to back is written once, with a count.
---
--- It answers what the vanilla-styled menu needs measured in the game itself:
---
---   * which script API pieces exist on this build, or the exact error if not;
---   * every MENU_* texture definition (path, size, tile size);
---   * the main-menu labels and the button-glyph strings;
---   * the main menu's state as it changes (menu id, highlighted row, state,
---     submenu), and the menu input as the engine filled it, before anything of
---     ours touched it -- which row is ONLINE, and whether the vanilla highlight
---     stays still while our menu swallows the input;
---   * the OPTIONS screen's panels (wood panels, scroll, bricks, scarab, arrows):
---     where they sit and which part of their sheet they come from;
---   * engine updates per GUI frame, and which render hooks fire on which screen.
---
--- The flag file's contents pick extra modes, space-separated:
---
---   draw      draw test text in the game font, the glyph strings, and on OPTIONS
---             every MENU_* sheet as a thumbnail with the dumped panels outlined on
---             it, so a screenshot shows which sheet each panel comes from; plus a
---             tag on every screen saying which hook drew it
---   capture   on the main menu, take the keyboard away from the game in alternating
---             five-second windows, logging what reaches the menu input in each

local module = {}

local FLAG = "mo_menuprobe.on"
local LOG = "mo_menuprobe.txt"
local MAX_LINES = 400

local armed = false
local modes = {}
-- `.on.txt` as well: Windows Explorer's New > Text Document, with extensions hidden,
-- names the file "mo_menuprobe.on.txt" while showing "mo_menuprobe.on". That is
-- exactly how the first attempt to arm this probe silently did nothing.
for _, name in ipairs({ FLAG, FLAG .. ".txt" }) do
    if not armed then
        pcall(function()
            local h = io.open(PackPath(name), "r")
            if h ~= nil then
                local body = h:read("*a") or ""
                h:close()
                armed = true
                for word in body:gmatch("%S+") do
                    modes[word:lower()] = true
                end
            end
        end)
    end
end

--- @return boolean
function module.armed()
    return armed
end

local written = 0
local lastLine = nil
local repeats = 0

--- @param line string
local function writeLine(line)
    pcall(function()
        local h = io.open(PackPath(LOG), "a")
        if h ~= nil then
            h:write(os.date("[%H:%M:%S] ") .. line .. "\n")
            h:close()
        end
    end)
end

--- One line of the probe log (nothing unless armed). Other modules call this to put
--- their own events in the same timeline.
--- @param fmt string
function module.note(fmt, ...)
    if not armed then
        return
    end
    local ok, line = pcall(string.format, fmt, ...)
    line = ok and line or tostring(fmt)
    if line == lastLine then
        repeats = repeats + 1
        return
    end
    if repeats > 0 and written < MAX_LINES then
        written = written + 1
        writeLine(string.format("  ... and %d more of the line above", repeats))
    end
    repeats = 0
    lastLine = line
    if written >= MAX_LINES then
        return
    end
    written = written + 1
    writeLine(line)
end

if not armed then
    MenuProbe = module
    return module
end

-- ------------------------------------------------------------------ helpers

--- A value for the log, or the error that reading it raised (the first line only).
--- @return string
local function shown(ok, v)
    if ok then
        return tostring(v)
    end
    local msg = tostring(v):gsub("%s+", " ")
    msg = msg:match("^.-%.lua:%d+:%s*(.+)$") or msg
    return "ERR(" .. msg:sub(1, 80) .. ")"
end

local BIT_NAMES = { { 1, "SELECT" }, { 2, "BACK" }, { 4, "DELETE" }, { 8, "RANDOM" },
                    { 16, "JOURNAL" }, { 32, "LEFT" }, { 64, "RIGHT" }, { 128, "UP" },
                    { 256, "DOWN" } }

--- @param bits integer
--- @return string
local function bitNames(bits)
    if bits == 0 then
        return "-"
    end
    local names = {}
    for _, pair in ipairs(BIT_NAMES) do
        if (bits & pair[1]) ~= 0 then
            names[#names + 1] = pair[2]
        end
    end
    local known = 0
    for _, pair in ipairs(BIT_NAMES) do
        known = known | pair[1]
    end
    if (bits & ~known) ~= 0 then
        names[#names + 1] = string.format("0x%x", bits & ~known)
    end
    return table.concat(names, "+")
end

--- @param id integer?
--- @return string
local function screenName(id)
    if id == nil then
        return "?"
    end
    for name, value in pairs(SCREEN) do
        if value == id then
            return name
        end
    end
    return tostring(id)
end

--- @param q userdata # a Quad
--- @return string
local function quadText(q)
    return string.format("TL(%.4f,%.4f) TR(%.4f,%.4f) BL(%.4f,%.4f) BR(%.4f,%.4f)",
        q.top_left_x, q.top_left_y, q.top_right_x, q.top_right_y,
        q.bottom_left_x, q.bottom_left_y, q.bottom_right_x, q.bottom_right_y)
end

--- Where a TextureRenderingInfo sits and which part of its sheet it shows.
--- @param tri userdata
--- @return string
local function triText(tri)
    local okXY, xy = pcall(function() return string.format("x=%.4f y=%.4f", tri.x, tri.y) end)
    local okS, src = pcall(function() return quadText(tri:source_get_quad()) end)
    local okD, dst = pcall(function() return quadText(tri:dest_get_quad()) end)
    return string.format("%s | src %s | dst %s", shown(okXY, xy), shown(okS, src), shown(okD, dst))
end

--- The source rectangle of a TextureRenderingInfo as {left, top, right, bottom} in
--- 0..1 sheet space, or nil.
--- @param tri userdata
--- @return number[]?
local function sourceRect(tri)
    local ok, r = pcall(function()
        local q = tri:source_get_quad()
        local l = math.min(q.top_left_x, q.bottom_left_x)
        local rr = math.max(q.top_right_x, q.bottom_right_x)
        local t = math.min(q.top_left_y, q.top_right_y)
        local b = math.max(q.bottom_left_y, q.bottom_right_y)
        return { l, t, rr, b }
    end)
    if ok and type(r) == "table" and r[3] > r[1] and r[4] > r[2] then
        return r
    end
    return nil
end

-- --------------------------------------------------------------- the header

-- a fresh file for each launch
pcall(function()
    local h = io.open(PackPath(LOG), "w")
    if h ~= nil then
        h:close()
    end
end)

module.note("=== menu probe armed (Modded Online %s) modes=%s ===",
    tostring(meta ~= nil and meta.version or "?"),
    (function()
        local list = {}
        for name in pairs(modes) do
            list[#list + 1] = name
        end
        table.sort(list)
        return #list > 0 and table.concat(list, ",") or "log"
    end)())

do
    local functions = { "set_pre_render_screen", "set_post_render_screen",
        "clear_screen_callback", "change_string", "get_string", "hash_to_stringid",
        "get_texture_definition", "play_sound", "get_window_size", "toast",
        "get_game_manager", "draw_text_size" }
    local parts = {}
    for _, name in ipairs(functions) do
        parts[#parts + 1] = name .. "=" .. type(rawget(_G, name))
    end
    module.note("api functions: %s", table.concat(parts, " "))

    parts = {}
    for _, name in ipairs({ "TextRenderingInfo", "Quad", "AABB", "Color" }) do
        local cls = rawget(_G, name)
        local okNew, hasNew = pcall(function() return cls ~= nil and cls.new ~= nil end)
        parts[#parts + 1] = name .. "=" .. type(cls) .. "/new:" .. shown(okNew, hasNew)
    end
    module.note("api classes: %s", table.concat(parts, " "))

    parts = {}
    for _, name in ipairs({ "VANILLA_TEXT_ALIGNMENT", "VANILLA_FONT_STYLE", "MENU_INPUT",
                            "VANILLA_SOUND", "TEXTURE", "SCREEN" }) do
        parts[#parts + 1] = name .. "=" .. type(rawget(_G, name))
    end
    module.note("api enums: %s", table.concat(parts, " "))

    parts = {}
    for _, name in ipairs({ "PRE_UPDATE", "POST_UPDATE", "PRE_PROCESS_INPUT",
                            "POST_PROCESS_INPUT", "PRE_GAME_LOOP", "RENDER_POST_HUD",
                            "SCREEN", "SCRIPT_ENABLE", "SCRIPT_DISABLE", "GUIFRAME" }) do
        parts[#parts + 1] = name .. "=" .. tostring(ON[name])
    end
    module.note("api ON: %s", table.concat(parts, " "))

    local okSound, sounds = pcall(function()
        local list = {}
        for _, name in ipairs({ "MENU_MM_NAVI", "MENU_MM_TOGGLE", "MENU_MM_SELECTION",
                                "MENU_CANCEL", "MENU_NAVI" }) do
            list[#list + 1] = name .. "=" .. tostring(VANILLA_SOUND[name])
        end
        return table.concat(list, " ")
    end)
    module.note("api sounds: %s", shown(okSound, sounds))
    module.note("game_manager global: %s", type(rawget(_G, "game_manager")))
end

-- ------------------------------------------------- first update: the tables

local MENU_HASHES = {
    { 0x49054a7e, "Play" }, { 0xa1023681, "Online" }, { 0xfe203cc2, "Options" },
    { 0x34906f28, "Leaderboards" }, { 0x8ca20866, "Player Profile" },
    { 0x9a19dfba, "Quit Game" },
    { 0x32ff8ff3, "<SYS_ACCEPT/>" }, { 0x0ed9f628, "<SYS_BACK/>" },
    { 0x32d818fb, "Back <SYS_BACK/>" }, { 0x70ad4e49, "<SYS_LEFT/>" },
    { 0x870ecccf, "<SYS_RIGHT/>" }, { 0xd41f49aa, "Yes" }, { 0xcd92c15d, "No" },
}

--- The MENU_* textures, sorted by name: {name, id}.
local menuTextures = {}

local function dumpTables()
    local names = {}
    pcall(function()
        for name, id in pairs(TEXTURE) do
            if type(name) == "string" and name:find("MENU", 1, true) ~= nil then
                names[#names + 1] = name
            end
        end
    end)
    table.sort(names)
    for _, name in ipairs(names) do
        local id = TEXTURE[name]
        menuTextures[#menuTextures + 1] = { name, id }
        local ok, text = pcall(function()
            local d = get_texture_definition(id)
            return string.format("path=%s size=%dx%d tile=%dx%d sub=(%d,%d %dx%d)",
                tostring(d.texture_path), d.width, d.height, d.tile_width, d.tile_height,
                d.sub_image_offset_x, d.sub_image_offset_y, d.sub_image_width,
                d.sub_image_height)
        end)
        module.note("texture %s (%s): %s", name, tostring(id), shown(ok, text))
    end
    for _, pair in ipairs(MENU_HASHES) do
        local ok, text = pcall(function() return get_string(hash_to_stringid(pair[1])) end)
        module.note("string 0x%08x (%s) = %q", pair[1], pair[2], shown(ok, text))
    end
end

-- ------------------------------------------------------- per-screen counting

local currentScreen = nil   --- @type integer?
local updates, guiFrames = 0, 0
local hookCalls = {}        -- hook name -> calls on the current screen
local tablesDumped = false

local function summariseScreen(nextScreen)
    if currentScreen ~= nil then
        local hooks = {}
        for name, count in pairs(hookCalls) do
            hooks[#hooks + 1] = name .. "=" .. count
        end
        table.sort(hooks)
        module.note("screen %s -> %s | updates=%d gui=%d | hooks %s",
            screenName(currentScreen), screenName(nextScreen), updates, guiFrames,
            #hooks > 0 and table.concat(hooks, " ") or "none")
    end
    currentScreen = nextScreen
    updates, guiFrames = 0, 0
    hookCalls = {}
end

-- ------------------------------------------------------------ the main menu

local lastMenu = nil
local lastNow, lastPrev = -1, -1
local lastUpdateNow = 0

--- @return any
local function readField(obj, name)
    return obj[name]
end

--- One field for the log, read on its own: a field missing on this build says so
--- without hiding the others.
--- @return string
local function fieldText(obj, name)
    local ok, v = pcall(readField, obj, name)
    if not ok then
        return shown(false, v)
    end
    if math.type(v) == "float" then
        return string.format("%.1f", v)
    end
    return tostring(v)
end

local MENU_FIELDS = { { "menu_id", "id" }, { "selected_menu_index", "index" },
                      { "state", "state" }, { "transfer_to_menu_id", "transfer" },
                      { "menu_text_opacity", "opacity" }, { "loaded_once", "loaded_once" },
                      { "loop", "loop" } }

--- @param gm userdata
local function probeMenu(gm)
    local _, m = pcall(readField, gm, "screen_menu")
    local parts = {}
    for _, pair in ipairs(MENU_FIELDS) do
        parts[#parts + 1] = pair[2] .. "=" .. fieldText(m, pair[1])
    end
    local text = "menu " .. table.concat(parts, " ")
    local capturing = NetMenuUI ~= nil and NetMenuUI.capturing ~= nil and NetMenuUI.capturing()
    local hook = MainMenuHook ~= nil and MainMenuHook.active ~= nil and MainMenuHook.active()
    text = string.format("%s | ours=%s hook=%s", text, tostring(capturing), tostring(hook))
    if text ~= lastMenu then
        lastMenu = text
        module.note("%s", text)
    end
end

local menuDumped = false

--- @param gm userdata
local function dumpMenuPanels(gm)
    for _, field in ipairs({ "play_scroll", "left_spear", "right_spear",
                             "spear_dangler_related", "info_toast" }) do
        local ok, text = pcall(function() return triText(gm.screen_menu[field]) end)
        module.note("menu.%s: %s", field, shown(ok, text))
    end
end

-- ------------------------------------------------------- the options screen

local OPTIONS_FIELDS = { "brick_background", "brick_middlelayer", "brick_foreground",
    "topleft_woodpanel_esc", "selected_item_rounded_rect", "selected_item_scarab",
    "item_option_arrow_left", "item_option_arrow_right", "tooltip_background",
    "sectionheader_background", "bottom_scroll", "bottom_left_scrollhandle",
    "bottom_right_scrollhandle" }
local PANEL_FIELDS = { "top_woodpanel", "bottom_woodpanel", "scroll",
    "top_woodpanel_left_scrollhandle", "top_woodpanel_right_scrollhandle" }

--- Each dumped panel's source rectangle, for the outlines in draw mode: {name, rect}.
local panelRects = {}
local optionsUpdates = 0

--- @param gm userdata
--- @param when string
local function dumpOptions(gm, when)
    panelRects = {}
    module.note("options panels (%s):", when)
    for _, field in ipairs(OPTIONS_FIELDS) do
        local ok, tri = pcall(function() return gm.screen_options[field] end)
        if ok and tri ~= nil then
            module.note("  options.%s: %s", field, triText(tri))
            local rect = sourceRect(tri)
            if rect ~= nil then
                panelRects[#panelRects + 1] = { field, rect }
            end
        else
            module.note("  options.%s: %s", field, shown(ok, tri))
        end
    end
    for _, field in ipairs(PANEL_FIELDS) do
        local ok, tri = pcall(function() return gm.screen_options.screen_panels[field] end)
        if ok and tri ~= nil then
            module.note("  panels.%s: %s", field, triText(tri))
            local rect = sourceRect(tri)
            if rect ~= nil then
                panelRects[#panelRects + 1] = { field, rect }
            end
        else
            module.note("  panels.%s: %s", field, shown(ok, tri))
        end
    end
    local ok, text = pcall(function()
        local p = gm.screen_options.screen_panels
        return string.format("woodpanels_progress=%.2f scroll_unfurl=%.2f bottom_y_offset=%.3f"
            .. " top_visible=%s bottom_visible=%s scroll_text=%q left=%q middle=%q right=%q",
            p.woodpanels_progress, p.scroll_unfurl_progress, p.bottom_woodpanel_y_offset,
            tostring(p.top_woodpanel_visible), tostring(p.bottom_woodpanel_visible),
            get_string(p.scroll_text), get_string(p.bottom_left_text),
            get_string(p.bottom_middle_text), get_string(p.bottom_right_text))
    end)
    module.note("  panels: %s", shown(ok, text))
end

-- ----------------------------------------------------------------- capture

local captureOn = false
local captureSwitchMs = 0
local CAPTURE_WINDOW_MS = 5000

-- ------------------------------------------- where in a frame things happen
--
-- dev68's takeover assumed the main menu reads its input between PRE_UPDATE and
-- POST_UPDATE, and the game proved otherwise. These say where it really does: the
-- order the callbacks run in, and between which two of them the menu's state moves.

local HAS_INPUT_PHASE = ON.POST_PROCESS_INPUT ~= nil
local lastTuple, lastTuplePhase = nil, nil
local orderTrail, orderLogged = {}, false
local inputPair = nil       -- the pair as the game built it this frame
local prePair = nil         -- ...and as PRE_UPDATE found it

--- @param gm userdata
--- @return string
local function readTuple(gm)
    local m = gm.screen_menu
    return string.format("id=%d index=%d state=%d transfer=%d", m.menu_id,
        m.selected_menu_index, m.state, m.transfer_to_menu_id)
end

--- @param gm userdata
--- @return integer, integer
local function readInput(gm)
    return math.floor(gm.game_props.input_menu), math.floor(gm.game_props.input_menu_previous)
end

--- The main menu as this callback finds it; a change since the last callback that
--- looked is logged with the two callbacks it happened between.
--- @param phase string
local function observe(phase)
    local okLs, ls = pcall(get_local_state)
    if not okLs or ls == nil or ls.screen ~= SCREEN.MENU then
        lastTuple = nil
        return
    end
    if not orderLogged then
        orderTrail[#orderTrail + 1] = phase
        if #orderTrail >= 24 then
            orderLogged = true
            module.note("callback order on the main menu: %s", table.concat(orderTrail, " "))
        end
    end
    local gm = GameManager ~= nil and GameManager() or nil
    if gm == nil then
        return
    end
    local ok, tuple = pcall(readTuple, gm)
    if not ok then
        return
    end
    if lastTuple ~= nil and tuple ~= lastTuple then
        module.note("menu moved between %s and %s: %s -> %s", lastTuplePhase, phase,
            lastTuple, tuple)
    end
    lastTuple, lastTuplePhase = tuple, phase
end

--- The menu input exactly as the game built it. Runs before menuInput's callbacks
--- (module order), so nothing of ours has touched it yet.
--- @param gm userdata
local function logInput(gm)
    local okIn, now, prev = pcall(readInput, gm)
    if not okIn then
        return
    end
    inputPair = now .. "/" .. prev
    if (now ~= lastNow or prev ~= lastPrev) and (now ~= 0 or prev ~= 0 or lastNow ~= 0) then
        module.note("input now=%s prev=%s (prev %s last frame's now)%s", bitNames(now),
            bitNames(prev), prev == lastUpdateNow and "==" or "~=",
            modes.capture and (" capture=" .. (captureOn and "on" or "off")) or "")
    end
    lastNow, lastPrev = now, prev
    lastUpdateNow = now
end

local function inputPhase()
    local gm = GameManager ~= nil and GameManager() or nil
    if gm ~= nil then
        logInput(gm)
    end
    observe("POST_PROCESS_INPUT")
end

local function postUpdate()
    observe("POST_UPDATE")
    local gm = GameManager ~= nil and GameManager() or nil
    if gm == nil or prePair == nil then
        return
    end
    local ok, now, prev = pcall(readInput, gm)
    if ok and now .. "/" .. prev ~= prePair then
        module.note("input changed DURING the update: %s -> %s/%s", prePair, now, prev)
    end
end

-- ----------------------------------------------------------- the callbacks

local function preUpdate()
    local okLs, ls = pcall(get_local_state)
    if not okLs or ls == nil then
        return
    end
    if ls.screen ~= currentScreen then
        summariseScreen(ls.screen)
        optionsUpdates = 0
    end
    updates = updates + 1
    if not tablesDumped then
        tablesDumped = true
        dumpTables()
    end
    local gm = GameManager ~= nil and GameManager() or nil
    if gm == nil then
        return
    end

    if HAS_INPUT_PHASE then
        -- what POST_PROCESS_INPUT left, as the update is about to read it: anything
        -- but the game's own value or our zero means something refilled it
        local ok, now, prev = pcall(readInput, gm)
        if ok then
            prePair = now .. "/" .. prev
            if inputPair ~= nil and prePair ~= inputPair and (now ~= 0 or prev ~= 0) then
                module.note("input refilled before PRE_UPDATE: %s -> %s", inputPair, prePair)
            end
        end
    else
        logInput(gm)
        local ok, now, prev = pcall(readInput, gm)
        prePair = ok and (now .. "/" .. prev) or nil
    end
    observe("PRE_UPDATE")

    if ls.screen == SCREEN.MENU then
        if not menuDumped then
            menuDumped = true
            dumpMenuPanels(gm)
        end
        probeMenu(gm)
    elseif ls.screen == SCREEN.OPTIONS then
        optionsUpdates = optionsUpdates + 1
        -- on entry, and again once the wood panels have slid in
        if optionsUpdates == 2 then
            dumpOptions(gm, "on entry")
        elseif optionsUpdates == 62 then
            dumpOptions(gm, "one second in")
        end
    end
end

local CAPTURE_KEYS = { { 38, "UP" }, { 40, "DOWN" }, { 37, "LEFT" }, { 39, "RIGHT" },
                       { 90, "Z" }, { 88, "X" }, { 13, "ENTER" }, { 27, "ESC" } }

local lastWantKeyboard = nil

local function guiFrame()
    guiFrames = guiFrames + 1
    observe("GUIFRAME")
    local okIo, io_ = pcall(get_io)
    if not okIo or io_ == nil then
        return
    end
    -- What ImGui left in the flag at the start of our frame, before anyone set it
    -- this frame: whether it is reset between frames decides whether "the overlay
    -- has the keyboard" can be read from it.
    local okWant, want = pcall(function() return io_.wantkeyboard end)
    want = okWant and want or nil
    if want ~= lastWantKeyboard then
        lastWantKeyboard = want
        module.note("gui: wantkeyboard at frame start = %s", tostring(want))
    end
    if not modes.capture then
        return
    end
    local okLs, ls = pcall(get_local_state)
    if not okLs or ls == nil or ls.screen ~= SCREEN.MENU then
        captureOn = false
        return
    end
    local now = get_ms()
    if now - captureSwitchMs >= CAPTURE_WINDOW_MS then
        captureSwitchMs = now
        captureOn = not captureOn
        module.note("capture window: keyboard %s", captureOn and "TAKEN from the game" or "left to the game")
    end
    if captureOn then
        pcall(function() io_.wantkeyboard = true end)
    end
    for _, pair in ipairs(CAPTURE_KEYS) do
        local okKey, hit = pcall(io_.keypressed, pair[1], false)
        if okKey and hit then
            module.note("key %s pressed (capture=%s)", pair[2], captureOn and "on" or "off")
        end
    end
end

-- ---------------------------------------------------------------- drawing

local colorCache = {}

--- @return userdata?
local function color(r, g, b, a)
    local key = r .. "," .. g .. "," .. b .. "," .. a
    local c = colorCache[key]
    if c == nil then
        local ok, made = pcall(function() return Color:new(r, g, b, a) end)
        c = ok and made or nil
        colorCache[key] = c or false
    end
    return c or nil
end

local OUTLINE_COLORS = { { 1, 0.2, 0.2 }, { 0.2, 1, 0.2 }, { 0.3, 0.5, 1 }, { 1, 1, 0.2 },
                         { 1, 0.3, 1 }, { 0.2, 1, 1 }, { 1, 0.6, 0.2 }, { 1, 1, 1 } }

--- @param ctx userdata # VanillaRenderContext
local function drawText(ctx, text, x, y, scale, style, align)
    pcall(function()
        ctx:draw_text(text, x, y, scale, scale, color(1, 1, 1, 1),
            align or VANILLA_TEXT_ALIGNMENT.LEFT, style or VANILLA_FONT_STYLE.NORMAL)
    end)
end

--- Font and glyph test strip, bottom of the main menu.
local function drawMenuStrip(ctx)
    local y = -0.55
    for _, pair in ipairs({ { "NORMAL", "NORMAL" }, { "ITALIC", "ITALIC" }, { "BOLD", "BOLD" } }) do
        drawText(ctx, "Modded Online HOST JOIN SETTINGS (" .. pair[1] .. ")", -0.95, y, 0.0011,
            VANILLA_FONT_STYLE[pair[2]])
        y = y - 0.07
    end
    local okGlyph, glyphs = pcall(function()
        return get_string(hash_to_stringid(0x32ff8ff3)) .. " select   "
            .. get_string(hash_to_stringid(0x32d818fb)) .. "   "
            .. get_string(hash_to_stringid(0x70ad4e49)) .. get_string(hash_to_stringid(0x870ecccf))
            .. " change"
    end)
    drawText(ctx, okGlyph and glyphs or "glyph strings: ERR", -0.95, y, 0.0011)
    y = y - 0.07
    drawText(ctx, "raw: <SYS_ACCEPT/> select  \u{8F} \u{83} \u{84}", -0.95, y, 0.0011)
    local okSize, w, h = pcall(function() return ctx:draw_text_size("Modded Online", 0.0011, 0.0011, VANILLA_FONT_STYLE.NORMAL) end)
    drawText(ctx, string.format("draw_text_size('Modded Online', 0.0011) = %s, %s",
        okSize and string.format("%.4f", w) or shown(okSize, w),
        okSize and string.format("%.4f", h) or ""), -0.95, y - 0.07, 0.0008)
    -- a square, aspect-corrected the way hdmod does it (y * 16/9), to see if it is one
    pcall(function()
        ctx:draw_screen_rect_filled(AABB:new(0.7, -0.55, 0.8, -0.55 - 0.1 * 16 / 9), color(1, 0.8, 0.3, 0.8))
    end)
end

--- Every MENU_* sheet as a labelled thumbnail, with the dumped OPTIONS panels'
--- source rectangles outlined on each, so a screenshot shows which sheet holds them.
local function drawSheets(ctx)
    pcall(function()
        ctx:draw_screen_rect_filled(AABB:new(-1, 1, 1, -1), color(0, 0, 0, 0.85))
    end)
    local cols = 8
    local cellW = 0.235
    local cellH = cellW * 16 / 9 * 0.5
    local thumbW = cellW * 0.82
    local thumbH = thumbW * 16 / 9
    local x0, y0 = -0.98, 0.96
    for i, pair in ipairs(menuTextures) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local left = x0 + col * cellW
        local top = y0 - row * (thumbH + 0.06)
        pcall(function()
            ctx:draw_screen_texture(pair[2], Quad:new(AABB:new(0, 0, 1, 1)),
                Quad:new(AABB:new(left, top, left + thumbW, top - thumbH)), color(1, 1, 1, 1))
        end)
        for n, panel in ipairs(panelRects) do
            local r = panel[2]
            local c = OUTLINE_COLORS[(n - 1) % #OUTLINE_COLORS + 1]
            pcall(function()
                ctx:draw_screen_rect(AABB:new(left + r[1] * thumbW, top - r[2] * thumbH,
                    left + r[3] * thumbW, top - r[4] * thumbH), 2, color(c[1], c[2], c[3], 1))
            end)
        end
        drawText(ctx, (pair[1]:gsub("DATA_TEXTURES_", "")), left, top - thumbH - 0.01, 0.0005)
    end
    -- the legend: which outline is which panel
    for n, panel in ipairs(panelRects) do
        local c = OUTLINE_COLORS[(n - 1) % #OUTLINE_COLORS + 1]
        pcall(function()
            ctx:draw_text(panel[1], 0.62, -0.30 - (n - 1) * 0.045, 0.0006, 0.0006,
                color(c[1], c[2], c[3], 1), VANILLA_TEXT_ALIGNMENT.LEFT, VANILLA_FONT_STYLE.NORMAL)
        end)
    end
    if #panelRects == 0 then
        drawText(ctx, "(no panel rectangles yet -- wait a second on this screen)", 0.3, -0.9, 0.0007)
    end
end

--- @param name string # the hook, as the tag reads
local function drawTag(ctx, name, slot)
    pcall(function()
        ctx:draw_text(name, 0.98, 0.95 - slot * 0.05, 0.0007, 0.0007, color(1, 0.4, 1, 1),
            VANILLA_TEXT_ALIGNMENT.RIGHT, VANILLA_FONT_STYLE.BOLD)
    end)
end

-- Every screen a vanilla-styled layer might want: count which hooks fire where.
local HOOKED = { "TITLE", "MENU", "OPTIONS", "PLAYER_PROFILE", "LEADERBOARD", "SEED_INPUT",
                 "CHARACTER_SELECT", "TEAM_SELECT", "CAMP", "LEVEL", "TRANSITION", "DEATH",
                 "SCORES", "ONLINE_LOADING", "ONLINE_LOBBY" }

if type(set_post_render_screen) == "function" then
    for _, name in ipairs(HOOKED) do
        local id = SCREEN[name]
        if id ~= nil then
            local tag = "post_screen " .. name
            local okSet, err = pcall(set_post_render_screen, id, function(_, ctx)
                hookCalls[tag] = (hookCalls[tag] or 0) + 1
                if not modes.draw then
                    return
                end
                drawTag(ctx, tag, 0)
                if name == "MENU" and not (NetMenuUI ~= nil and NetMenuUI.isOpen ~= nil
                    and NetMenuUI.isOpen()) then
                    drawMenuStrip(ctx)
                elseif name == "OPTIONS" then
                    drawSheets(ctx)
                end
            end)
            if not okSet then
                module.note("set_post_render_screen(%s) failed: %s", name, shown(false, err))
            end
        end
    end
end
if ON.RENDER_POST_HUD ~= nil then
    set_callback(function(ctx)
        hookCalls.post_hud = (hookCalls.post_hud or 0) + 1
        if modes.draw then
            drawTag(ctx, "post_hud", 1)
        end
    end, ON.RENDER_POST_HUD)
end
-- All registered before menuInput's (module order), so each sees the input before
-- anything of ours writes it.
if HAS_INPUT_PHASE then
    set_callback(function()
        SafeCall("menuProbe:input", inputPhase)
    end, ON.POST_PROCESS_INPUT)
end
if ON.PRE_UPDATE ~= nil then
    set_callback(function()
        SafeCall("menuProbe:preUpdate", preUpdate)
    end, ON.PRE_UPDATE)
end
if ON.POST_UPDATE ~= nil then
    set_callback(function()
        SafeCall("menuProbe:postUpdate", postUpdate)
    end, ON.POST_UPDATE)
end
set_callback(function()
    SafeCall("menuProbe:guiFrame", guiFrame)
end, ON.GUIFRAME)

MenuProbe = module
return module
