--- Modded Online — drawing with the game's own renderer: its font and its sprites.
---
--- The MODDED ONLINE menu, its popups and the in-game plaques used to be drawn with
--- ImGui (GuiDrawContext): flat rectangles and a desktop font over the game. This
--- draws them the way the game's own OPTIONS screen is drawn:
---
---   * the layered brick walls (menu_generic, menu_brick2, menu_brick1);
---   * the top wood panel, with the parchment scroll across it for the title;
---   * the ringed bottom wood panel for the button hints (menu_disp);
---   * the red highlight bar and the gold arrows of an options row (menu_basic);
---   * the wood-framed panel for a dialog, a dark torn box for a plaque;
---   * and the game's own font.
---
--- The sprite rectangles below were measured from the sheets themselves, extracted
--- from Spel2.exe, and the sheets' sizes are the ones the menu probe read back from
--- get_texture_definition on this build (mo_menuprobe.txt, 2026-10-05). Source
--- coordinates are fractions of the whole sheet, as the game's own
--- TextureRenderingInfo fields are (the probe's left_spear read 0.70..1.00 of
--- menu_basic, which is where the spear is).
---
--- LAYERS. menuUI and chat each register what they draw (`layer`). A layer is called
--- from the game's render callbacks -- set_post_render_screen on the menu screens,
--- ON.RENDER_POST_HUD in the camp and levels -- and draws from whatever state the
--- last GUI frame left. The GUI version stays as the automatic fallback: menuUI asks
--- `serving(name)` before drawing its ImGui version, which is true only while the
--- render callbacks are actually running and the layer has not failed.
---
--- NOTHING HERE MAY TAKE THE GAME DOWN. Every layer is called through pcall; the
--- first error switches that layer off for the session and is logged once, and the
--- GUI version takes over. A native crash cannot be caught, so the very first vanilla
--- draw of a session is bracketed by a breadcrumb file (mo_vanillaui.txt, the same
--- idea as modHost's mo_fatal_calls.txt): a session that died inside it leaves
--- "drawing" behind, and the next one stays on the GUI look and says why.
--- `mo_novanillaui.on` forces the GUI look.
---
--- Positions are in pixels of a 1920x1080 screen, turned into the renderer's -1..1
--- space; the game draws its menus in 16:9.

local module = {}

local FLAG_OFF = "mo_novanillaui.on"
local CRUMB = "mo_vanillaui.txt"

--- The sheets, by the TEXTURE whose definition is the whole image, and the size every
--- rectangle below was measured against.
local SHEETS = {
    basic = { tex = "DATA_TEXTURES_MENU_BASIC_0", w = 1280, h = 1280 },
    disp = { tex = "DATA_TEXTURES_MENU_DISP_1", w = 1408, h = 768 },
    generic = { tex = "DATA_TEXTURES_MENU_GENERIC_0", w = 1920, h = 1080 },
    brick1 = { tex = "DATA_TEXTURES_MENU_BRICK1_0", w = 1920, h = 1080 },
    brick2 = { tex = "DATA_TEXTURES_MENU_BRICK2_0", w = 1920, h = 1080 },
}

--- { sheet, left, top, right, bottom } in sheet pixels.
local SPRITES = {
    wood_top = { "disp", 1, 256, 1408, 508 },
    wood_bottom = { "disp", 3, 536, 1405, 768 },
    scroll_paper = { "disp", 191, 60, 1221, 201 },
    scroll_handle_l = { "disp", 31, 20, 95, 239 },
    scroll_handle_r = { "disp", 1313, 17, 1377, 236 },
    red_bar = { "basic", 832, 1232, 1216, 1264 },
    arrow = { "basic", 1068, 45, 1111, 86 },
    entry_bar = { "basic", 704, 527, 1088, 563 },
    frame = { "basic", 12, 2, 639, 636 },
    darkbox = { "basic", 656, 14, 1008, 116 },
    wall_back = { "generic", 0, 0, 1920, 1080 },
    wall_middle = { "brick2", 0, 0, 1920, 1080 },
    wall_front = { "brick1", 0, 0, 1920, 1080 },
}
module.SPRITES = SPRITES
module.SHEETS = SHEETS

--- Colours, as 0..255 RGB.
local PALETTE = {
    title_ink = { 74, 44, 22 },      -- brown ink on the parchment
    row = { 232, 216, 184 },         -- parchment-light text on the dark wall
    row_lit = { 255, 248, 230 },     -- the selected row, on the red bar
    dim = { 178, 158, 128 },
    hint = { 240, 228, 200 },        -- on the wood
    hint_dim = { 214, 196, 160 },
    gold = { 255, 206, 92 },
    error = { 240, 112, 90 },
    black = { 0, 0, 0 },
    white = { 255, 255, 255 },
}

-- ------------------------------------------------------------------ state

local enabled = nil      --- @type boolean? # nil until the first render call decides
local whyOff = nil       --- @type string?
local layers = {}        -- { name, z, fn } in z order
local broken = {}        -- layer name -> its first error
local guiCounter = 0     -- GUI frames, counted by our own GUIFRAME
local lastDispatchGui = -1000
local crumbState = nil   -- nil, "drawing", "ok"

--- @param fmt string
local function report(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    line = ok and line or tostring(fmt)
    if DesyncLog ~= nil and DesyncLog.earlyEvent ~= nil then
        DesyncLog.earlyEvent("vanilla look: %s", line)
    end
    if MenuProbe ~= nil and MenuProbe.note ~= nil then
        MenuProbe.note("vanillaUI: %s", line)
    end
    dbg("vanilla look: " .. line)
end

--- @param name string
--- @return string?
local function readPackFile(name)
    local body = nil
    pcall(function()
        local h = io.open(PackPath(name), "r")
        if h ~= nil then
            body = h:read("*a") or ""
            h:close()
        end
    end)
    return body
end

--- @param name string
--- @param body string
local function writePackFile(name, body)
    pcall(function()
        local h = io.open(PackPath(name), "w")
        if h ~= nil then
            h:write(body)
            h:close()
        end
    end)
end

-- ----------------------------------------------------------- the sprites

local texIds = {}        -- sheet key -> TEXTURE id
local srcQuads = {}      -- sprite name -> Quad (and name .. "|flip")
local scratch = nil      -- one destination Quad, rewritten for every draw

--- Check every sheet against the size its rectangles were measured on. A texture mod
--- that replaced one with a different layout would put the wrong part of it on
--- screen; a mismatch keeps the GUI look instead.
--- @return string? # why not
local function checkSheets()
    for key, sheet in pairs(SHEETS) do
        local id = TEXTURE[sheet.tex]
        if id == nil then
            return "TEXTURE." .. sheet.tex .. " is missing"
        end
        local ok, def = pcall(get_texture_definition, id)
        if not ok or def == nil then
            return "no texture definition for " .. sheet.tex
        end
        if def.width ~= sheet.w or def.height ~= sheet.h then
            return string.format("%s is %dx%d, not the %dx%d it was measured on", sheet.tex,
                def.width, def.height, sheet.w, sheet.h)
        end
        texIds[key] = id
    end
    return nil
end

--- @param name string
--- @param flip boolean?
--- @return userdata
local function sourceQuad(name, flip)
    local key = flip and (name .. "|flip") or name
    local q = srcQuads[key]
    if q == nil then
        local s = SPRITES[name]
        local sheet = SHEETS[s[1]]
        q = Quad:new(AABB:new(s[2] / sheet.w, s[3] / sheet.h, s[4] / sheet.w, s[5] / sheet.h))
        if flip then
            -- the return value, in case it is a new Quad rather than this one flipped
            q = q:flip_horizontally() or q
        end
        srcQuads[key] = q
    end
    return q
end

--- 1080p pixels to the renderer's space.
local function X(px) return px / 960 - 1 end
local function Y(py) return 1 - py / 540 end
module.X, module.Y = X, Y

--- @param q userdata
local function setQuad(q, l, t, r, b)
    q.top_left_x, q.top_left_y = l, t
    q.top_right_x, q.top_right_y = r, t
    q.bottom_left_x, q.bottom_left_y = l, b
    q.bottom_right_x, q.bottom_right_y = r, b
end

local colors = {}

--- A cached Color: the palette entry at an alpha rounded to 1/64.
--- @param name string
--- @param alpha number? # 0..1
--- @return userdata
local function color(name, alpha)
    local step = math.floor((alpha or 1) * 64 + 0.5)
    local key = name .. step
    local c = colors[key]
    if c == nil then
        local rgb = PALETTE[name] or PALETTE.white
        c = Color:new(rgb[1] / 255, rgb[2] / 255, rgb[3] / 255, step / 64)
        colors[key] = c
    end
    return c
end
module.color = color

--- Draw a sprite into a 1080p pixel rectangle.
function module.sprite(ctx, name, l, t, r, b, alpha, flip)
    scratch = scratch or Quad:new()
    setQuad(scratch, X(l), Y(t), X(r), Y(b))
    ctx:draw_screen_texture(texIds[SPRITES[name][1]], sourceQuad(name, flip), scratch,
        color("white", alpha))
end

local nineCache = {}

--- A sprite drawn in nine pieces: the corners at their own size, the edges and the
--- middle stretched, so a frame keeps its border at any size. `inset` is the border
--- in sheet pixels (and is drawn at that many 1080p pixels).
function module.nine(ctx, name, l, t, r, b, inset, alpha)
    local s = SPRITES[name]
    local sheet = SHEETS[s[1]]
    local key = name .. inset
    local pieces = nineCache[key]
    if pieces == nil then
        pieces = {}
        local xs = { s[2], s[2] + inset, s[4] - inset, s[4] }
        local ys = { s[3], s[3] + inset, s[5] - inset, s[5] }
        for i = 1, 3 do
            for j = 1, 3 do
                pieces[#pieces + 1] = Quad:new(AABB:new(xs[i] / sheet.w, ys[j] / sheet.h,
                    xs[i + 1] / sheet.w, ys[j + 1] / sheet.h))
            end
        end
        nineCache[key] = pieces
    end
    local dx = { l, l + inset, r - inset, r }
    local dy = { t, t + inset, b - inset, b }
    scratch = scratch or Quad:new()
    local tint = color("white", alpha)
    local tex = texIds[s[1]]
    local n = 0
    for i = 1, 3 do
        for j = 1, 3 do
            n = n + 1
            setQuad(scratch, X(dx[i]), Y(dy[j]), X(dx[i + 1]), Y(dy[j + 1]))
            ctx:draw_screen_texture(tex, pieces[n], scratch, tint)
        end
    end
end

--- A flat colour over a 1080p pixel rectangle.
function module.fill(ctx, l, t, r, b, colorName, alpha)
    ctx:draw_screen_rect_filled(AABB:new(X(l), Y(t), X(r), Y(b)), color(colorName, alpha))
end

-- --------------------------------------------------------------- the text

--- How tall a capital letter is per unit of scale, and where its middle sits relative to
--- the y given to draw_text -- measured once from the glyphs the game lays out, rather
--- than assumed (the script API does not say whether y is the top, the middle or the
--- baseline).
---
--- It is the CAPITAL's height, ink to ink: the quads the game gives an "H" are tight
--- around it. dev70 took them for the whole cell (line height) and sized everything
--- for that, so every line came out about 1.7 times too big; its first screenshots had
--- "MATCHMAKING" asked for at 44 with capitals 45 px tall. Every size here is now the
--- height of a capital, in 1080p pixels.
local capPerScale = nil
local midPerScale = 0
local CAL_SCALE = 0.001

local function calibrate()
    capPerScale = 0.06 / CAL_SCALE -- an estimate, in case neither measurement answers
    midPerScale = 0
    local how = "estimated"
    local ok, err = pcall(function()
        local tri = TextRenderingInfo:new("H", CAL_SCALE, CAL_SCALE, VANILLA_TEXT_ALIGNMENT.LEFT,
            VANILLA_FONT_STYLE.BOLD)
        local letters = tri:get_dest()
        local top, bottom = -math.huge, math.huge
        for i = 1, #letters do
            local q = letters[i]:get_quad()
            for _, y in ipairs({ q.top_left_y, q.top_right_y, q.bottom_left_y, q.bottom_right_y }) do
                if y > top then top = y end
                if y < bottom then bottom = y end
            end
        end
        if top > bottom then
            capPerScale = (top - bottom) / CAL_SCALE
            midPerScale = ((top + bottom) / 2) / CAL_SCALE
            how = "glyph quads"
        else
            local _, h = tri:text_size()
            if type(h) == "number" and h ~= 0 then
                capPerScale = math.abs(h) / CAL_SCALE
                how = "text_size"
            end
        end
    end)
    report("text measured (%s): capital %.4f per scale, middle %.4f per scale%s", how,
        capPerScale, midPerScale, ok and "" or (" -- " .. tostring(err)))
end

--- The draw scale for capitals `sizePx` tall at 1080p.
--- @return number
local function scaleFor(sizePx)
    if capPerScale == nil then
        calibrate()
    end
    return (sizePx / 540) / capPerScale
end

local ALIGN = { left = 0, center = 1, right = 2 }
local STYLE = { normal = 0, italic = 1, bold = 2 }
pcall(function()
    ALIGN = { left = VANILLA_TEXT_ALIGNMENT.LEFT, center = VANILLA_TEXT_ALIGNMENT.CENTER,
              right = VANILLA_TEXT_ALIGNMENT.RIGHT }
    STYLE = { normal = VANILLA_FONT_STYLE.NORMAL, italic = VANILLA_FONT_STYLE.ITALIC,
              bold = VANILLA_FONT_STYLE.BOLD }
end)

--- Draw text in the game's font, its capitals `sizePx` tall, centred vertically on
--- `yPx`.
--- @param align string? # left | center | right (x is that edge, or the middle)
--- @param style string? # normal | italic | bold
function module.text(ctx, str, xPx, yPx, sizePx, colorName, align, style, alpha)
    local scale = scaleFor(sizePx)
    ctx:draw_text(str, X(xPx), Y(yPx) - midPerScale * scale, scale, scale,
        color(colorName, alpha), ALIGN[align or "left"], STYLE[style or "bold"])
end

--- Width of `str` in 1080p pixels at that size.
--- @return number
function module.width(ctx, str, sizePx, style)
    local scale = scaleFor(sizePx)
    local w = ctx:draw_text_size(str, scale, scale, STYLE[style or "bold"])
    return math.abs(w or 0) * 960
end

--- The largest size up to `sizePx` at which `str` fits in `maxPx`.
--- @return number
function module.fit(ctx, str, sizePx, maxPx, style)
    local w = module.width(ctx, str, sizePx, style)
    if w <= maxPx or w <= 0 then
        return sizePx
    end
    return sizePx * maxPx / w
end

local wrapCache = {}

--- `str` in lines no wider than `maxPx`, cached: measuring every word every frame
--- would be most of the cost of a popup.
--- @return string[]
function module.wrap(ctx, str, sizePx, maxPx, style)
    local key = str .. "|" .. sizePx .. "|" .. maxPx .. "|" .. tostring(style)
    local lines = wrapCache[key]
    if lines ~= nil then
        return lines
    end
    lines = {}
    local line = ""
    for word in str:gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if line ~= "" and module.width(ctx, candidate, sizePx, style) > maxPx then
            lines[#lines + 1] = line
            line = word
        else
            line = candidate
        end
    end
    if line ~= "" then
        lines[#lines + 1] = line
    end
    wrapCache[key] = lines
    return lines
end

-- ---------------------------------------------------------- composites
--
-- Sizes are capital heights in 1080p pixels, from the mockup the layout was drawn on
-- (rows at 24, the title 44, hints 22).
--
-- The menu and its popups are in the main menu's own font: the game's italic style,
-- which is what PLAY, ONLINE, OPTIONS and the rest are drawn in. The plaques, the run
-- status line and chat keep the bold upright style the game uses in a level.
local MENU_STYLE = "italic"

--- The OPTIONS-style page: the walls, the top panel and its scroll with the title, the
--- rows, and the bottom panel with the hints.
---
--- m.title; m.rows = { { name, value?, changes?, field?, selected, editing } };
--- m.hintLeft, m.hintRight, m.middle, m.middleError; m.alpha
function module.page(ctx, m)
    local a = m.alpha or 1
    module.sprite(ctx, "wall_back", 0, 0, 1920, 1080, a)
    module.sprite(ctx, "wall_middle", 0, 0, 1920, 1080, a)
    module.sprite(ctx, "wall_front", 0, 0, 1920, 1080, a)

    module.sprite(ctx, "wood_top", 256, -40, 1663, 212, a)
    module.sprite(ctx, "scroll_paper", 520, 140, 1400, 260, a)
    module.sprite(ctx, "scroll_handle_l", 482, 104, 538, 296, a)
    module.sprite(ctx, "scroll_handle_r", 1382, 104, 1438, 296, a)
    module.text(ctx, m.title, 960, 200, module.fit(ctx, m.title, 44, 800, MENU_STYLE),
        "title_ink", "center", MENU_STYLE, a)

    local rows = m.rows
    local n = #rows
    local rowH = n > 0 and math.min(68, 520 / n) or 68
    local top = 580 - n * rowH / 2
    for i = 1, n do
        local row = rows[i]
        local cy = top + (i - 0.5) * rowH
        local lit = row.selected
        if lit then
            module.sprite(ctx, "red_bar", 560, cy - rowH * 0.42, 1360, cy + rowH * 0.42, a)
        end
        local ink = lit and "row_lit" or "row"
        local labelMax = (row.value ~= nil or row.field ~= nil) and 470 or 720
        module.text(ctx, row.name, 600, cy,
            module.fit(ctx, row.name, lit and 25 or 24, labelMax, MENU_STYLE), ink, "left",
            MENU_STYLE, a)
        if row.field ~= nil then
            module.sprite(ctx, "entry_bar", 1000, cy - 20, 1340, cy + 20, a)
            local shown = row.field .. (row.editing and "_" or "")
            module.text(ctx, shown, 1016, cy, module.fit(ctx, shown, 20, 310, MENU_STYLE), ink,
                "left", MENU_STYLE, a)
        elseif row.value ~= nil then
            -- the arrows only where LEFT and RIGHT change it
            local arrows = lit and row.changes
            if arrows then
                module.sprite(ctx, "arrow", 1100, cy - 18, 1138, cy + 18, a, true)
                module.sprite(ctx, "arrow", 1302, cy - 18, 1340, cy + 18, a)
            end
            module.text(ctx, row.value, 1220, cy,
                module.fit(ctx, row.value, 24, arrows and 150 or 270, MENU_STYLE), ink, "center",
                MENU_STYLE, a)
        end
    end

    module.sprite(ctx, "wood_bottom", 259, 868, 1661, 1100, a)
    local left, right = m.hintLeft or "", m.hintRight or ""
    module.text(ctx, left, 420, 975, 22, "hint", "left", MENU_STYLE, a)
    module.text(ctx, right, 1500, 975, 22, "hint", "right", MENU_STYLE, a)
    if m.middle ~= nil and m.middle ~= "" then
        -- between the two hints, never over them
        local from = 420 + module.width(ctx, left, 22, MENU_STYLE) + 40
        local to = 1500 - module.width(ctx, right, 22, MENU_STYLE) - 40
        local room = math.max(80, to - from)
        local cx = math.max(from + room / 2, math.min(960, to - room / 2))
        module.text(ctx, m.middle, cx, 975, module.fit(ctx, m.middle, 20, room, MENU_STYLE),
            m.middleError and "error" or "hint_dim", "center", MENU_STYLE, a)
    end
end

--- Where everything in a dialog goes: measured, then drawn, so the frame is exactly as
--- tall as what is in it.
local DIALOG_W = 1000
local DIALOG_BORDER = 110   -- the frame's border, in both its sheet and 1080p pixels
local DIALOG_INNER = DIALOG_W - 2 * 120

--- A dialog over whatever is on screen: a shade, the wood frame, a gold title, the
--- text, the buttons and a hint.
---
--- d.title, d.text, d.buttons = { labels }, d.choice, d.footer
function module.dialog(ctx, d)
    module.fill(ctx, 0, 0, 1920, 1080, "black", 0.6)
    local bodySize = 22
    local lines = module.wrap(ctx, d.text, bodySize, DIALOG_INNER, MENU_STYLE)
    if #lines > 12 then
        bodySize = 19
        lines = module.wrap(ctx, d.text, bodySize, DIALOG_INNER, MENU_STYLE)
    end
    local lineH = bodySize * 1.7
    local buttonH = 60
    local titleH, gap = 50, 26
    local H = DIALOG_BORDER + titleH + gap + #lines * lineH + gap + #d.buttons * buttonH
        + 40 + DIALOG_BORDER - 30
    H = math.min(H, 1060)
    local L, T = (1920 - DIALOG_W) / 2, (1080 - H) / 2
    module.nine(ctx, "frame", L, T, L + DIALOG_W, T + H, DIALOG_BORDER)

    local y = T + DIALOG_BORDER - 10 + titleH / 2
    module.text(ctx, d.title, 960, y, module.fit(ctx, d.title, 32, DIALOG_INNER, MENU_STYLE),
        "gold", "center", MENU_STYLE)
    y = y + titleH / 2 + gap
    local centred = #lines <= 3
    for i = 1, #lines do
        local cy = y + (i - 0.5) * lineH
        if centred then
            module.text(ctx, lines[i], 960, cy, bodySize, "row", "center", MENU_STYLE)
        else
            module.text(ctx, lines[i], L + 120, cy, bodySize, "row", "left", MENU_STYLE)
        end
    end
    y = y + #lines * lineH + gap
    for i = 1, #d.buttons do
        local cy = y + (i - 0.5) * buttonH
        local lit = i == d.choice
        if lit then
            module.sprite(ctx, "red_bar", 760, cy - 26, 1160, cy + 26)
        end
        module.text(ctx, d.buttons[i], 960, cy, lit and 26 or 25, lit and "row_lit" or "row",
            "center", MENU_STYLE)
    end
    y = y + #d.buttons * buttonH
    module.text(ctx, d.footer or "", 960, y + 22, 17, "hint_dim", "center", MENU_STYLE)
end

local PLAQUE_PAD = 18
local PLAQUE_LINE = 1.75   -- a line's height, in capitals

--- How tall `plaque` draws these lines.
--- @return number
function module.plaqueHeight(lines)
    local h = PLAQUE_PAD * 2
    for i = 1, #lines do
        h = h + (lines[i][3] or 18) * PLAQUE_LINE
    end
    return h
end

--- How wide `plaque` draws these lines: its widest line and the padding, inside
--- `minW`..`maxW`.
--- @return number
function module.plaqueWidth(ctx, lines, minW, maxW)
    local widest = 0
    for i = 1, #lines do
        local w = module.width(ctx, lines[i][1], lines[i][3] or 18)
        if w > widest then
            widest = w
        end
    end
    return math.max(minW, math.min(maxW, widest + PLAQUE_PAD * 2 + 12))
end

--- A dark torn plaque holding lines of text: { { text, color?, size? } }, left-aligned,
--- from (l, t), as wide as `w`.
function module.plaque(ctx, l, t, w, lines, alpha)
    local pad = PLAQUE_PAD
    local h = module.plaqueHeight(lines)
    module.nine(ctx, "darkbox", l, t, l + w, t + h, 24, (alpha or 1) * 0.95)
    local y = t + pad
    for i = 1, #lines do
        local size = lines[i][3] or 18
        local lineH = size * PLAQUE_LINE
        module.text(ctx, lines[i][1], l + pad + 6, y + lineH / 2,
            module.fit(ctx, lines[i][1], size, w - pad * 2 - 12), lines[i][2] or "row", "left",
            "bold", alpha)
        y = y + lineH
    end
    return h
end

--- Text with a dark shadow, for lines drawn straight over the game.
function module.shadowText(ctx, str, xPx, yPx, sizePx, colorName, align, style, alpha)
    module.text(ctx, str, xPx + 2, yPx + 2, sizePx, "black", align, style, (alpha or 1) * 0.8)
    module.text(ctx, str, xPx, yPx, sizePx, colorName, align, style, alpha)
end

-- -------------------------------------------------------------- layers

--- Register something to draw. `fn(ctx, screen)` returns true when it drew; a higher
--- `z` draws later (on top).
--- @param name string
--- @param z number
--- @param fn fun(ctx: userdata, screen: integer): boolean
function module.layer(name, z, fn)
    layers[#layers + 1] = { name = name, z = z, fn = fn }
    table.sort(layers, function(a, b) return a.z < b.z end)
end

--- Should `name` be drawn by this module rather than its GUI version? Only while the
--- render callbacks are running (they ran within the last two GUI frames), the look
--- is on, and that layer has not failed.
--- @return boolean
function module.serving(name)
    return enabled == true and broken[name] == nil and guiCounter - lastDispatchGui <= 2
end

--- Is the look on? nil until the first render call has decided.
--- @return boolean?
function module.active()
    return enabled
end

--- @return string?
function module.why()
    return whyOff
end

--- The first render call: is everything here, and did the last session survive its
--- first draw?
local function decide()
    if readPackFile(FLAG_OFF) ~= nil or readPackFile(FLAG_OFF .. ".txt") ~= nil then
        enabled, whyOff = false, FLAG_OFF .. " is present"
    else
        local crumb = readPackFile(CRUMB)
        if crumb ~= nil and (crumb:find("drawing", 1, true) or crumb:find("crashed", 1, true)) then
            enabled = false
            whyOff = "the game died during the first vanilla draw of an earlier session; delete "
                .. CRUMB .. " to try again"
            writePackFile(CRUMB, "crashed\n")
        else
            for _, name in ipairs({ "TextRenderingInfo", "Quad", "AABB", "Color" }) do
                if rawget(_G, name) == nil then
                    enabled, whyOff = false, name .. " is missing"
                end
            end
            if enabled == nil then
                local reason = checkSheets()
                if reason ~= nil then
                    enabled, whyOff = false, reason
                else
                    enabled = true
                end
            end
        end
    end
    report(enabled and "ON" or ("OFF -- " .. tostring(whyOff)))
end

--- One render call: every layer, in order.
--- @param ctx userdata
--- @param screen integer
local function dispatch(ctx, screen)
    if enabled == nil then
        decide()
    end
    if not enabled then
        return
    end
    lastDispatchGui = guiCounter
    for i = 1, #layers do
        local layer = layers[i]
        if broken[layer.name] == nil then
            if crumbState == nil then
                crumbState = "drawing"
                writePackFile(CRUMB, "drawing\n")
            end
            local ok, err = pcall(layer.fn, ctx, screen)
            if not ok then
                broken[layer.name] = tostring(err)
                report("layer %s failed, back to the GUI look for it: %s", layer.name, tostring(err))
            end
        end
    end
    if crumbState == "drawing" then
        crumbState = "ok"
        writePackFile(CRUMB, "ok\n")
    end
end

--- @return integer?
local function currentScreen()
    local ok, ls = pcall(get_local_state)
    return ok and ls ~= nil and ls.screen or nil
end

-- The menu screens draw from their own post-render callback, right after the screen
-- itself; the camp and the levels from the HUD's, so the pause menu and the journal
-- still come on top. The probe saw RENDER_POST_HUD fire on every screen, so it skips
-- the ones served here.
local SCREEN_HOOKED = {}
if type(set_post_render_screen) == "function" then
    for _, name in ipairs({ "TITLE", "MENU", "OPTIONS", "PLAYER_PROFILE", "LEADERBOARD",
                            "SEED_INPUT", "CHARACTER_SELECT", "TEAM_SELECT", "TRANSITION",
                            "ONLINE_LOADING", "ONLINE_LOBBY" }) do
        local id = SCREEN[name]
        if id ~= nil then
            local ok = pcall(set_post_render_screen, id, function(_, ctx)
                if DesyncLog ~= nil then
                    DesyncLog.frameMark("render:vanillaUI")
                end
                dispatch(ctx, id)
                if DesyncLog ~= nil then
                    DesyncLog.frameDone("render:vanillaUI")
                end
            end)
            if ok then
                SCREEN_HOOKED[id] = true
            end
        end
    end
end
if ON ~= nil and ON.RENDER_POST_HUD ~= nil then
    set_callback(function(ctx)
        local screen = currentScreen()
        if screen == nil or SCREEN_HOOKED[screen] then
            return
        end
        if DesyncLog ~= nil then
            DesyncLog.frameMark("render:vanillaUI")
        end
        dispatch(ctx, screen)
        if DesyncLog ~= nil then
            DesyncLog.frameDone("render:vanillaUI")
        end
    end, ON.RENDER_POST_HUD)
end
set_callback(function()
    guiCounter = guiCounter + 1
end, ON.GUIFRAME)

VanillaUI = module
return module
