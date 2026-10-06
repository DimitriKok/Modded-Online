"""A stubbed engine for the menu modules: menuInput, mainMenuHook, menuUI, menuProbe.

Not a test file. It builds on the stub in tests/test_first_run.py and adds what the
main menu takeover needs: the engine's update with the menu input it reads, the main
menu itself, the string table, and a model of how the vanilla main menu answers the
input it is given -- so a test can see what the ENGINE saw, not only what we wrote.

    engine = Engine(tmp_path)
    engine.update("SELECT")      # one engine update with the pad holding SELECT
    engine.gui("DOWN")           # one GUI frame with the keyboard pressing DOWN
    engine.seen                  # what the engine's update read: (now, prev)
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent

BITS = {"SELECT": 1, "BACK": 2, "DELETE": 4, "RANDOM": 8, "JOURNAL": 16,
        "LEFT": 32, "RIGHT": 64, "UP": 128, "DOWN": 256}

ENV = r"""
function rgba(r, g, b, a) return (r << 24) | (g << 16) | (b << 8) | a end
KEY = { O = 79, UP = 38, DOWN = 40, Z = 90, RETURN = 13, ESCAPE = 27, BACKSPACE = 8,
        A = 65, PERIOD = 190, MINUS = 189, COMMA = 188, SPACE = 32, OL_MOD_SHIFT = 0x200,
        LEFT = 37, RIGHT = 39 }
down = {}
ioState = { wantkeyboard = false }
ioState.keypressed = function(code, _allowRepeat) return down[code] == true end
function get_io() return ioState end
now = 100000
function get_ms() return now end

ON = { GUIFRAME = 100, SCREEN = 102, SCRIPT_ENABLE = 115, SCRIPT_DISABLE = 116,
       RENDER_POST_HUD = 118, PRE_UPDATE = 142, POST_UPDATE = 143, POST_PROCESS_INPUT = 154 }
callbacks = {}
function set_callback(fn, id)
    callbacks[id] = callbacks[id] or {}
    table.insert(callbacks[id], fn)
    return #callbacks[id]
end
-- runs every callback of a kind; returns the most values any of them returned
function runCallbacks(id, ...)
    local most = 0
    for _, fn in ipairs(callbacks[id] or {}) do
        local n = select("#", fn(...))
        if n > most then most = n end
    end
    return most
end
function SafeCall(_, f, ...) return f(...) end
errors = {}
function errorf(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
function dbg(_) end

SCREEN = { LOGO = 0, INTRO = 1, TITLE = 3, MENU = 4, OPTIONS = 5, CHARACTER_SELECT = 9,
           CAMP = 11, LEVEL = 12, TRANSITION = 13 }
FADE = { NONE = 0, OUT = 2 }
MENU_INPUT = { NONE = 0, SELECT = 1, BACK = 2, DELETE = 4, RANDOM = 8, JOURNAL = 16,
               LEFT = 32, RIGHT = 64, UP = 128, DOWN = 256 }

lstate = { screen = SCREEN.MENU, loading = FADE.NONE, player_inputs = { player_slots = {
    { buttons = 0, buttons_gameplay = 0 }, { buttons = 0, buttons_gameplay = 0 },
    { buttons = 0, buttons_gameplay = 0 }, { buttons = 0, buttons_gameplay = 0 } } } }
function get_local_state() return lstate end

game_manager = {
    screen_menu = { state = 7, menu_id = 0, selected_menu_index = 1, transfer_to_menu_id = 0 },
    game_props = { input_menu = 0, input_menu_previous = 0 },
}
function GameManager() return game_manager end

strings = { [0xa1023681] = "Online" }
changes = {}
function hash_to_stringid(h) return h end
function get_string(id) return strings[id] end
function change_string(id, s) strings[id] = s; changes[#changes + 1] = s end
toasts = {}
function toast(s) toasts[#toasts + 1] = s end
function PackPath(rest) return flagDir .. rest end

-- The vanilla main menu, as far as these tests need it: six rows, ONLINE at
-- `engineOnlineRow`, a SELECT on PLAY or ONLINE moving to that submenu through state
-- 8, BACK in a submenu going home the same way, BACK on the main menu leaving for the
-- title. It reads the input pair exactly as it finds it at the moment it reads.
engineOnlineRow = 1
engineIgnoresSwallow = false
-- reads a selection lingers in state 6 (highlight_selection) before moving on; 0 goes
-- straight to state 8 (to_submenu)
engineHighlightReads = 0
engineHighlightLeft = 0
engineTransferTo = 0
wentToTitle = false
local function choose(to)
    if engineHighlightReads > 0 then
        local m = game_manager.screen_menu
        m.state, engineHighlightLeft, engineTransferTo = 6, engineHighlightReads, to
    else
        local m = game_manager.screen_menu
        m.transfer_to_menu_id = to; m.state = 8
    end
end
function engineMenu()
    if lstate.screen ~= SCREEN.MENU then return end
    local m, p = game_manager.screen_menu, game_manager.game_props
    if m == nil then return end
    if m.state == 6 then
        engineHighlightLeft = engineHighlightLeft - 1
        if engineHighlightLeft <= 0 then
            m.transfer_to_menu_id = engineTransferTo; m.state = 8
        end
        return
    end
    if m.state == 8 then
        m.menu_id = m.transfer_to_menu_id
        m.state = 7
        return
    end
    if m.state ~= 7 then return end
    p = engineProps or p
    local pressed = p.input_menu & ~p.input_menu_previous
    if engineIgnoresSwallow then
        pressed = pressed | (deviceNow & ~devicePrevSeen)
    end
    if m.menu_id == 0 then
        if pressed & 128 ~= 0 then m.selected_menu_index = (m.selected_menu_index - 1) % 6 end
        if pressed & 256 ~= 0 then m.selected_menu_index = (m.selected_menu_index + 1) % 6 end
        if pressed & 1 ~= 0 then
            if m.selected_menu_index == engineOnlineRow then
                choose(2)
            elseif m.selected_menu_index == 0 then
                choose(1)
            end
        end
        if pressed & 2 ~= 0 then wentToTitle = true end
    elseif pressed & 2 ~= 0 then
        m.transfer_to_menu_id = 0; m.state = 8
    end
end

-- What the game read at its read: the menu's input as it really reached it.
function engineRead()
    local p = engineProps or game_manager.game_props
    seenNow, seenPrev = p.input_menu, p.input_menu_previous
    engineMenu()
end

deviceNow, devicePrevSeen = 0, 0
seenNow, seenPrev = 0, 0
preUpdateValues = 0
-- The engine's own view of the pair, when a test has put a proxy in front of it for
-- the scripts (a build that refuses the write).
engineProps = nil
-- WHERE in a frame the main menu reads its input is not known -- dev68 assumed
-- between PRE_UPDATE and POST_UPDATE, and the game proved otherwise. So the model can
-- read it at any of the four places, and the tests that matter run in all of them:
--   frame_start  before the input is processed (it reads what the last frame left)
--   after_input  straight after it is processed, before PRE_UPDATE
--   inside       between PRE_UPDATE and POST_UPDATE (dev68's assumption)
--   after_post   after POST_UPDATE
engineOrder = "after_input"
engineRefills = false

-- One engine frame: the game processes the input (the previous from what the field
-- held, the current from the device), POST_PROCESS_INPUT runs, then PRE_UPDATE, the
-- update and POST_UPDATE; the menu reads wherever engineOrder says.
function engineUpdate(device)
    local p = engineProps or game_manager.game_props
    if engineOrder == "frame_start" then engineRead() end
    devicePrevSeen = deviceNow
    deviceNow = device
    p.input_menu_previous = p.input_menu
    p.input_menu = device
    runCallbacks(ON.POST_PROCESS_INPUT)
    if engineRefills then
        -- a build that fills the field a second time before the update
        p.input_menu = device
    end
    if engineOrder == "after_input" then engineRead() end
    preUpdateValues = runCallbacks(ON.PRE_UPDATE)
    if engineOrder == "inside" then engineRead() end
    runCallbacks(ON.POST_UPDATE)
    if engineOrder == "after_post" then engineRead() end
end

Network = {
    config = { hideRoomCode = false, testPlayer = 0, autoSendLogs = false, autoSyncSave = false,
               debugMessages = false, firstRunDone = true, serverHost = "127.0.0.1",
               serverPort = 26000, joinHost = "" },
    PHASE = { IDLE = "idle", CONNECTING = "connecting", LOBBY = "lobby", INGAME = "ingame",
              ERROR = "error" },
    phase = "idle",
    room = nil,
    lastError = nil,
    lastErrorCode = nil,
    lobbyPlayers = {},
    MAX_TEST_PLAYERS = 3,
    saves = 0,
    left = 0,
    launched = 0,
    stopped = 0,
}
function Network.saveConfig() Network.saves = Network.saves + 1 end
function Network.isInRun() return Network.phase == Network.PHASE.INGAME end
function Network.isActive()
    return Network.phase == Network.PHASE.LOBBY or Network.phase == Network.PHASE.INGAME
end
function Network.leave() Network.left = Network.left + 1; Network.phase = Network.PHASE.IDLE end
function Network.launchTestPlayer() Network.launched = Network.launched + 1 end
function Network.stopTestPlayers() Network.stopped = Network.stopped + 1 end
connectResult = "connecting"
local function connect()
    if connectResult == "connecting" then
        Network.phase = Network.PHASE.CONNECTING
        Network.lastError = nil
    else
        Network.phase = Network.PHASE.IDLE
        Network.lastError = connectResult
    end
end
Network.hostOfficial = connect
Network.hostGame = connect
Network.joinOfficial = function(_) connect() end
Network.joinGame = function(_) connect() end
Network.matchmake = function(_) connect() end
function Network.isPublicRoom() return false end
Network.slot = 1
Network.playerNames = {}
sent = {}
function Network.onEvent(_, _) end
function Network.sendEvent(kind, _) sent[#sent + 1] = kind end
function Network.isHost() return true end
SaveShare = { lastResult = function() return nil end, syncToMod = function() end }

-- ---- the game's renderer, for src/vanillaUI.lua
TEXTURE = { DATA_TEXTURES_MENU_BASIC_0 = 41, DATA_TEXTURES_MENU_DISP_1 = 32,
            DATA_TEXTURES_MENU_GENERIC_0 = 36, DATA_TEXTURES_MENU_BRICK1_0 = 39,
            DATA_TEXTURES_MENU_BRICK2_0 = 40 }
texdefs = { [41] = { width = 1280, height = 1280 }, [32] = { width = 1408, height = 768 },
            [36] = { width = 1920, height = 1080 }, [39] = { width = 1920, height = 1080 },
            [40] = { width = 1920, height = 1080 } }
function get_texture_definition(id) return texdefs[id] end
AABB = {}
function AABB:new(l, t, r, b) return { left = l, top = t, right = r, bottom = b } end
Quad = {}
Quad.__index = Quad
function Quad:new(aabb)
    local q = setmetatable({}, Quad)
    if aabb ~= nil then
        q.top_left_x, q.top_left_y = aabb.left, aabb.top
        q.top_right_x, q.top_right_y = aabb.right, aabb.top
        q.bottom_left_x, q.bottom_left_y = aabb.left, aabb.bottom
        q.bottom_right_x, q.bottom_right_y = aabb.right, aabb.bottom
    end
    return q
end
function Quad:flip_horizontally()
    self.top_left_x, self.top_right_x = self.top_right_x, self.top_left_x
    self.bottom_left_x, self.bottom_right_x = self.bottom_right_x, self.bottom_left_x
    return self
end
Color = {}
function Color:new(r, g, b, a) return { r = r, g = g, b = b, a = a } end
VANILLA_TEXT_ALIGNMENT = { LEFT = 0, CENTER = 1, RIGHT = 2 }
VANILLA_FONT_STYLE = { NORMAL = 0, ITALIC = 1, BOLD = 2 }
-- The stub font: glyph cells GLYPH_CELL tall per 0.001 of scale, hanging DOWN from
-- the y they are drawn at (so their middle is half a cell below it), and each
-- character GLYPH_WIDTH wide per 0.001.
GLYPH_CELL, GLYPH_WIDTH = 0.06, 0.02
TextRenderingInfo = {}
function TextRenderingInfo:new(text, sx, _sy, _align, _style)
    local t = { text = text, sx = sx }
    function t:get_dest()
        local letters = {}
        for i = 1, #text do
            local q = Quad:new(AABB:new(0, 0, 0, -GLYPH_CELL * sx / 0.001))
            letters[i] = { get_quad = function() return q end }
        end
        return letters
    end
    function t:text_size() return #text * sx * GLYPH_WIDTH / 0.001, -GLYPH_CELL * sx / 0.001 end
    return t
end
screenCallbacks = {}
function set_post_render_screen(id, fn)
    screenCallbacks[id] = screenCallbacks[id] or {}
    table.insert(screenCallbacks[id], fn)
    return #screenCallbacks[id]
end
vdrawn = {}
local function corners(q)
    return { q.top_left_x, q.top_left_y, q.bottom_right_x, q.bottom_right_y }
end
vctx = {
    draw_screen_texture = function(_self, tex, src, dst, color)
        vdrawn[#vdrawn + 1] = { kind = "tex", tex = tex, src = corners(src), dst = corners(dst),
                                a = color.a }
    end,
    draw_text = function(_self, text, x, y, sx, _sy, color, align, style)
        vdrawn[#vdrawn + 1] = { kind = "text", text = text, x = x, y = y, scale = sx,
                                align = align, style = style, a = color.a }
    end,
    draw_text_size = function(_self, text, sx, _sy, _style)
        return #text * sx * GLYPH_WIDTH / 0.001, -GLYPH_CELL * sx / 0.001
    end,
    draw_screen_rect_filled = function(_self, _aabb, color)
        vdrawn[#vdrawn + 1] = { kind = "fill", a = color.a }
    end,
}
drawFails = false
-- one render of `id`: its post-render callbacks, or the HUD's for a screen without
function renderScreen(id)
    vdrawn = {}
    if screenCallbacks[id] ~= nil then
        for _, fn in ipairs(screenCallbacks[id]) do fn({}, vctx) end
    else
        runCallbacks(ON.RENDER_POST_HUD, vctx)
    end
end

function draw_text_size(size, text) return #text * size * 0.00035, -(size * 0.00185) end
drawn = {}
ctx = {
    draw_rect_filled = function() end,
    draw_rect = function() end,
    draw_line = function() end,
    draw_text = function(_self, x, y, size, text, _color)
        drawn[#drawn + 1] = { x = x, y = y, size = size, text = text }
    end,
}
"""

MODULES = ("menuInput", "mainMenuHook", "menuUI")
ROW_SIZES = (28, 30)  # menuUI's unselected and selected rows
ORDERS = ("frame_start", "after_input", "inside", "after_post")


def source(name: str) -> str:
    return (PACK / "src" / (name + ".lua")).read_text(encoding="utf-8")


class Engine:
    """The menu modules running against the stub, with helpers to drive them."""

    def __init__(self, tmp_path: pathlib.Path, modules=MODULES, flags=(), before=None,
                 order="after_input", highlight=0, **config):
        self.rt = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.rt.execute(ENV)
        self.lua('engineOrder = "%s"; engineHighlightReads = %d' % (order, highlight))
        self.rt.globals().flagDir = str(tmp_path).replace("\\", "/") + "/"
        for name in flags:
            (tmp_path / name).write_text("", encoding="utf-8")
        for key, value in config.items():
            self.lua("Network.config.%s = %s" % (key, lua_value(value)))
        if before is not None:
            self.lua(before)
        for name in modules:
            self.rt.execute(source(name))

    # -------------------------------------------------------------- driving

    def lua(self, code: str):
        return self.rt.execute(code)

    def eval(self, expr: str):
        return self.rt.eval(expr)

    def update(self, *bits: str) -> None:
        """One engine update with the device (a controller) holding `bits`."""
        mask = 0
        for bit in bits:
            mask |= BITS[bit]
        self.lua("engineUpdate(%d)" % mask)

    def gui(self, *keys: str, ms: int = 16) -> list[str]:
        """One GUI frame `ms` after the last, with keyboard `keys` pressed. Returns the
        texts drawn, in order."""
        self.lua("now = now + %d; drawn = {}; down = {}; ioState.wantkeyboard = false" % ms)
        for key in keys:
            self.lua("down[KEY.%s] = true" % key)
        self.lua("runCallbacks(ON.GUIFRAME, ctx)")
        self.lua("down = {}")
        return [str(self.eval("drawn[%d].text" % i)) for i in range(1, int(self.eval("#drawn")) + 1)]

    def tick(self, *bits: str, ms: int = 16) -> list[str]:
        """An engine update with the pad holding `bits`, then a GUI frame."""
        self.update(*bits)
        return self.gui(ms=ms)

    def rows(self, *keys: str, ms: int = 16) -> list[str]:
        """The menu rows drawn on one GUI frame."""
        self.lua("now = now + %d; drawn = {}; down = {}; ioState.wantkeyboard = false" % ms)
        for key in keys:
            self.lua("down[KEY.%s] = true" % key)
        self.lua("runCallbacks(ON.GUIFRAME, ctx)")
        self.lua("down = {}")
        out = []
        for i in range(1, int(self.eval("#drawn")) + 1):
            if self.eval("drawn[%d].size" % i) in ROW_SIZES:
                out.append(str(self.eval("drawn[%d].text" % i)))
        return out

    def render(self, screen: str = "MENU") -> list[dict]:
        """One render of `screen` by the game: what the game's look drew, in order."""
        self.lua("renderScreen(SCREEN.%s)" % screen)
        out = []
        for i in range(1, int(self.eval("#vdrawn")) + 1):
            d = self.eval("vdrawn[%d]" % i)
            entry = {k: d[k] for k in ("kind", "text", "tex", "x", "y", "scale", "align",
                                       "style", "a")}
            for k in ("src", "dst"):
                if d[k] is not None:
                    entry[k] = [d[k][j] for j in range(1, 5)]
            out.append(entry)
        return out

    def frame(self, *bits: str, keys=(), screen: str = "MENU", ms: int = 16):
        """A whole frame as the game runs it: input and update, render, GUI. Returns
        (what the game's look drew, what the ImGui version drew)."""
        self.update(*bits)
        vanilla = self.render(screen)
        gui = self.gui(*keys, ms=ms)
        return vanilla, gui

    def wait(self, ms: int) -> None:
        """Let time pass with GUI frames and idle updates, 16 ms apart."""
        for _ in range(max(1, ms // 16)):
            self.update()
            self.gui()

    # ------------------------------------------------------------- reading

    @property
    def seen(self) -> tuple[int, int]:
        """What the game's menu read at its last read: (now, prev)."""
        return int(self.eval("seenNow")), int(self.eval("seenPrev"))

    @property
    def label(self) -> str:
        return str(self.eval("strings[0xa1023681]"))

    @property
    def menu(self) -> dict:
        m = self.eval("game_manager.screen_menu")
        return {k: m[k] for k in ("state", "menu_id", "selected_menu_index", "transfer_to_menu_id")}

    def is_open(self) -> bool:
        return bool(self.eval("NetMenuUI.isOpen()"))

    def active(self):
        return self.eval("MainMenuHook.active()")


def lua_value(value) -> str:
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "nil"
    if isinstance(value, str):
        return '"%s"' % value
    return str(value)


def open_menu(engine: Engine) -> None:
    """From the main menu on ONLINE: SELECT, let go, and wait out the arming pause."""
    engine.update()            # installs the takeover
    engine.update("SELECT")
    engine.gui()
    engine.update()
    engine.gui(ms=200)
