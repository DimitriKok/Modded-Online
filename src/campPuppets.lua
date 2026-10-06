--- Modded Online — the other players in the camp lobby.
---
--- The camp is not simulated in lockstep: until the run starts, each machine's camp
--- holds only its own spelunker, so a room of four looked like four people alone.
--- This puts everyone else in it too, as PUPPETS: each machine sends where its
--- spelunker is and how it is posed a few times a second, and every other machine in
--- the camp draws that player there -- climbing down the entry rope when they
--- arrive, then walking about.
---
--- A puppet is a picture, not a player. It is an item (ITEM_ROCK) wearing the
--- player's character sheet, posed with their animation frame and facing, with its
--- physics paused and every interaction switched off: it falls through nothing, can't
--- be picked up, whipped, stomped or hurt, and is in no player list, so the HUD, the
--- camera, the camp's NPCs, the door ready-check and the hosted mods' player hooks
--- never see it. A real spawned character would be a co-op player or a companion,
--- with an inventory, a HUD row and a place in the next level.
---
--- THE STREAM rides the unreliable world channel (`sendWorld`, kind "pp"), which the
--- server relays to the room in any phase, the lobby included. No server change. The
--- reliable event channel is never used for it: its log is kept for the life of the
--- room and replayed in order, so a stream of positions there would grow without end
--- and stall the chat behind it.
---
---   { k = "pp", x, y, a = animation frame, f = 1 facing left, l = layer, c = character }
---   { k = "pp", g = 1 }  -- gone: left the camp
---
--- A packet is sent when something changed, at most every SEND_MS, and at least every
--- KEEPALIVE_MS while standing still, from the GUI frame so it keeps going while this
--- machine's pause menu has the game stopped. A puppet nobody has heard from for
--- STALE_MS is taken away.
---
--- THE RUN IS NEVER TOUCHED. Puppets exist only in the camp, outside any run, and are
--- forgotten the moment the camp is torn down (PRE_LEVEL_DESTRUCTION, a screen change),
--- before any uid could be recycled into the run's world. The camp already differs on
--- every machine (each one's own movement, save and NPCs), so nothing here adds to
--- what the run start has always had to reset.

local module = {}

local PUPPET_TYPE = ENT_TYPE ~= nil and ENT_TYPE.ITEM_ROCK or nil
local SEND_MS = 50          -- 20 a second, the input resend's throttle and no more
local KEEPALIVE_MS = 400
local STALE_MS = 3000
local SNAP_DISTANCE = 3     -- tiles: further than this is a teleport, not a step
local FOLLOW = 0.5          -- each update closes this much of the gap to the latest sample
local TAG_ABOVE = 0.85      -- the name tag's height above the puppet, in tiles
-- The playable characters' ENT_TYPEs (CHAR_ANA_SPELUNKY .. CHAR_EGGPLANT_CHILD), the
-- range the roster clamps a pick to; anything else from the wire is Ana.
local CHAR_FIRST, CHAR_LAST = 194, 216

-- ENT_FLAG bit indices (spel2.lua). Read from the engine's enum where it has one.
local FLAG = { INVISIBLE = 1, PASSES_THROUGH_OBJECTS = 4, PASSES_THROUGH_EVERYTHING = 5,
               TAKE_NO_DAMAGE = 6, THROWABLE_OR_KNOCKBACKABLE = 7, NO_GRAVITY = 10,
               INTERACT_WITH_WATER = 11, STUNNABLE = 12, COLLIDES_WALLS = 13,
               INTERACT_WITH_SEMISOLIDS = 14, CAN_BE_STOMPED = 15, FACING_LEFT = 17,
               PICKUPABLE = 18, ENABLE_BUTTON_PROMPT = 20, INTERACT_WITH_WEBS = 21,
               PASSES_THROUGH_PLAYER = 25, PAUSE_AI_AND_PHYSICS = 28 }
pcall(function()
    for name in pairs(FLAG) do
        if type(ENT_FLAG[name]) == "number" then
            FLAG[name] = ENT_FLAG[name]
        end
    end
end)
local SET_FLAGS = { "PASSES_THROUGH_EVERYTHING", "PASSES_THROUGH_OBJECTS", "PASSES_THROUGH_PLAYER",
                    "TAKE_NO_DAMAGE", "NO_GRAVITY", "PAUSE_AI_AND_PHYSICS" }
local CLEAR_FLAGS = { "THROWABLE_OR_KNOCKBACKABLE", "INTERACT_WITH_WATER", "STUNNABLE",
                      "COLLIDES_WALLS", "INTERACT_WITH_SEMISOLIDS", "CAN_BE_STOMPED",
                      "PICKUPABLE", "ENABLE_BUTTON_PROMPT", "INTERACT_WITH_WEBS" }

-- ------------------------------------------------------------------- state

local samples = {}    -- network slot -> the latest sample { x, y, a, f, l, c, at }
local puppets = {}    -- network slot -> { uid, x, y, c } of the puppet drawn for it
local lastSentMs = -1000000
local lastSent = { x = nil, y = nil, a = nil, f = nil, l = nil, c = nil }
local inCampLastFrame = false
local broken = nil    --- @type string? # why puppets stood down for the session

--- @param reason string
local function standDown(reason)
    if broken ~= nil then
        return
    end
    broken = reason
    if DesyncLog ~= nil and DesyncLog.earlyEvent ~= nil then
        DesyncLog.earlyEvent("camp puppets OFF: %s", reason)
    end
    errorf("camp puppets switched off (%s)", reason)
end

--- Is this machine in the camp lobby, outside any run?
--- @return boolean, table?
local function inCamp()
    if Network == nil or not Network.isActive() or Network.isInRun() then
        return false, nil
    end
    local ok, ls = pcall(get_local_state)
    if not ok or ls == nil or ls.screen ~= SCREEN.CAMP then
        return false, nil
    end
    return true, ls
end

--- Is `slot` someone in our room right now?
--- @param slot integer
--- @return boolean
local function inRoom(slot)
    for _, player in ipairs(Network.lobbyPlayers or {}) do
        if player.slot == slot then
            return true
        end
    end
    return false
end

--- The name the room knows `slot` by (chat's nameOf: in the camp the lobby list has
--- it; playerNames is a run's).
--- @param slot integer
--- @return string
local function nameOf(slot)
    for _, player in ipairs(Network.lobbyPlayers or {}) do
        if player.slot == slot then
            return tostring(player.name)
        end
    end
    return "Player " .. tostring(slot)
end

-- ------------------------------------------------------------------ sending

--- Round to 1/100 of a tile: the JSON encoder writes every digit it is given.
local function r2(v)
    return math.floor(v * 100 + 0.5) / 100
end

--- @param p userdata
--- @return number, number, integer, integer, integer, integer
local function readLocal(p)
    local x, y = p:get_absolute_position()
    return r2(x), r2(y), math.floor(p.animation_frame), test_flag(p.flags, FLAG.FACING_LEFT) and 1 or 0,
        math.floor(p.layer), math.floor(p.type.id)
end

--- From the GUI frame: our spelunker, to the room, while we are in the camp.
local function sendTick()
    local here = inCamp()
    if not here then
        if inCampLastFrame then
            -- left the camp: say so, so nobody keeps a puppet of us standing there
            inCampLastFrame = false
            lastSent.x = nil
            if Network ~= nil and Network.isActive() then
                Network.sendWorld({ k = "pp", g = 1 })
            end
        end
        return
    end
    inCampLastFrame = true
    local now = get_ms()
    if now - lastSentMs < SEND_MS then
        return
    end
    local p = SafePlayer(1)
    if p == nil then
        return
    end
    local ok, x, y, a, f, l, c = pcall(readLocal, p)
    if not ok then
        return
    end
    local changed = x ~= lastSent.x or y ~= lastSent.y or a ~= lastSent.a or f ~= lastSent.f
        or l ~= lastSent.l or c ~= lastSent.c
    if not changed and now - lastSentMs < KEEPALIVE_MS then
        return
    end
    lastSentMs = now
    lastSent.x, lastSent.y, lastSent.a, lastSent.f, lastSent.l, lastSent.c = x, y, a, f, l, c
    Network.sendWorld({ k = "pp", x = x, y = y, a = a, f = f, l = l, c = c })
end

-- ---------------------------------------------------------------- receiving

--- A puppet packet from `slot` (netCore's world channel, kind "pp").
--- @param slot integer
--- @param d table
function module.onSample(slot, d)
    slot = math.floor(tonumber(slot) or 0)
    if slot <= 0 then
        return
    end
    if d.g == 1 then
        samples[slot] = nil
        return
    end
    local x, y = tonumber(d.x), tonumber(d.y)
    if x == nil or y == nil then
        return
    end
    local s = samples[slot] or {}
    s.x, s.y = x, y
    s.a = math.floor(tonumber(d.a) or 0)
    s.f = d.f == 1
    s.l = math.floor(tonumber(d.l) or 0)
    local c = math.floor(tonumber(d.c) or 0)
    s.c = (c >= CHAR_FIRST and c <= CHAR_LAST) and c or CHAR_FIRST
    s.at = get_ms()
    samples[slot] = s
end

--- The puppet entity of `slot`, or nil if it is gone -- including when its uid now
--- belongs to something else, which the engine does with freed uids.
--- @return userdata?
local function puppetEntity(slot)
    local pup = puppets[slot]
    if pup == nil then
        return nil
    end
    local ent = get_entity(pup.uid)
    if ent == nil or ent.type == nil or ent.type.id ~= PUPPET_TYPE
        or type(ent.user_data) ~= "table" or ent.user_data.mo_puppet ~= slot then
        puppets[slot] = nil
        return nil
    end
    return ent
end

--- Make an entity a picture of a player: the character's sheet, the player's size and
--- depth, and nothing it can touch or be touched by.
--- @param ent userdata
--- @param s table # the sample
local function dress(ent, s)
    local flags = ent.flags
    for _, name in ipairs(SET_FLAGS) do
        flags = set_flag(flags, FLAG[name])
    end
    for _, name in ipairs(CLEAR_FLAGS) do
        flags = clr_flag(flags, FLAG[name])
    end
    ent.flags = flags
    pcall(function() ent.hitbox_enabled = false end)
    pcall(function()
        ent.velocityx, ent.velocityy = 0, 0
    end)
    pcall(function()
        ent:set_pre_update_state_machine(function() return true end)
    end)
    local me = SafePlayer(1)
    pcall(function()
        ent.width, ent.height = me ~= nil and me.width or 1.25, me ~= nil and me.height or 1.25
    end)
    pcall(function()
        if me ~= nil then
            ent:set_draw_depth(me.draw_depth)
        end
    end)
    ent:set_texture(get_type(s.c).texture)
end

--- @param slot integer
--- @param s table
--- @return userdata?
local function spawnPuppet(slot, s)
    local uid = spawn_entity_nonreplaceable(PUPPET_TYPE, s.x, s.y, s.l, 0, 0)
    local ent = uid ~= nil and uid >= 0 and get_entity(uid) or nil
    if ent == nil then
        return nil
    end
    ent.user_data = { mo_puppet = slot }
    dress(ent, s)
    puppets[slot] = { uid = uid, x = s.x, y = s.y, c = s.c }
    return ent
end

--- @param slot integer
local function removePuppet(slot)
    local ent = puppetEntity(slot)
    if ent ~= nil then
        pcall(function() ent:destroy() end)
    end
    puppets[slot] = nil
end

--- Forget every puppet without touching an entity: the level they were in is being
--- torn down, and their uids are about to be given to the next one's entities.
local function forgetAll()
    for slot in pairs(puppets) do
        puppets[slot] = nil
    end
end

local LOCAL_LAYER_DEFAULT = 0

--- From POST_UPDATE: one puppet per player heard from, where they are, as they are.
local function updatePuppets()
    local here, ls = inCamp()
    if not here then
        for slot in pairs(puppets) do
            removePuppet(slot)
        end
        return
    end
    local now = get_ms()
    local me = SafePlayer(1)
    local myLayer = LOCAL_LAYER_DEFAULT
    if me ~= nil then
        pcall(function() myLayer = math.floor(me.layer) end)
    end
    local mySlot = Network.slot
    for slot, s in pairs(samples) do
        if slot == mySlot or not inRoom(slot) or now - s.at > STALE_MS then
            samples[slot] = nil
        end
    end
    for slot in pairs(puppets) do
        if samples[slot] == nil then
            removePuppet(slot)
        end
    end
    for slot, s in pairs(samples) do
        local ent = puppetEntity(slot)
        if ent == nil and ls.loading == FADE.NONE then
            ent = spawnPuppet(slot, s)
        end
        if ent ~= nil then
            local pup = puppets[slot]
            if pup.c ~= s.c then
                pup.c = s.c
                ent:set_texture(get_type(s.c).texture)
            end
            local dx, dy = s.x - pup.x, s.y - pup.y
            if dx * dx + dy * dy > SNAP_DISTANCE * SNAP_DISTANCE then
                pup.x, pup.y = s.x, s.y
            else
                pup.x, pup.y = pup.x + dx * FOLLOW, pup.y + dy * FOLLOW
            end
            ent.x, ent.y = pup.x, pup.y
            ent.animation_frame = s.a
            local flags = ent.flags
            flags = s.f and set_flag(flags, FLAG.FACING_LEFT) or clr_flag(flags, FLAG.FACING_LEFT)
            -- in the other layer of the camp, out of sight from this one
            flags = (s.l ~= myLayer) and set_flag(flags, FLAG.INVISIBLE) or clr_flag(flags, FLAG.INVISIBLE)
            ent.flags = flags
        end
    end
end

-- ---------------------------------------------------------------- name tags

--- Each puppet's name, above it, as the run's name tags are drawn over players.
--- @return table # { { name, sx, sy } } in screen space
local function tags()
    local out = {}
    for slot, pup in pairs(puppets) do
        local s = samples[slot]
        if s ~= nil then
            local ok, sx, sy = pcall(screen_position, pup.x, pup.y + TAG_ABOVE)
            if ok and type(sx) == "number" then
                local me = SafePlayer(1)
                local myLayer = me ~= nil and me.layer or 0
                if s.l == myLayer then
                    out[#out + 1] = { nameOf(slot), sx, sy }
                end
            end
        end
    end
    return out
end

local function vanillaTags(ctx, screen)
    if screen ~= SCREEN.CAMP or next(puppets) == nil then
        return false
    end
    for _, tag in ipairs(tags()) do
        VanillaUI.shadowText(ctx, tag[1], (tag[2] + 1) * 960, (1 - tag[3]) * 540, 14, "row",
            "center", "bold", 0.9)
    end
    return true
end

--- The ImGui fallback for the tags.
--- @param ctx GuiDrawContext
local function guiTags(ctx)
    if next(puppets) == nil or (VanillaUI ~= nil and VanillaUI.serving("puppettags")) then
        return
    end
    for _, tag in ipairs(tags()) do
        local w = 0
        pcall(function() w = math.abs(draw_text_size(18, tag[1])) end)
        ctx:draw_text(tag[2] - w / 2, tag[3], 18, tag[1], rgba(255, 255, 255, 200))
    end
end

-- -------------------------------------------------------------- the hooks

--- Has every engine piece this needs? Asked once, so a build without one simply has
--- no puppets instead of an error every frame.
--- @return boolean
local function ready()
    if broken ~= nil then
        return false
    end
    for _, name in ipairs({ "spawn_entity_nonreplaceable", "get_entity", "get_type", "set_flag",
                            "clr_flag", "test_flag", "screen_position" }) do
        if type(rawget(_G, name)) ~= "function" then
            standDown(name .. " is missing")
            return false
        end
    end
    if PUPPET_TYPE == nil then
        standDown("ENT_TYPE.ITEM_ROCK is missing")
        return false
    end
    return true
end

if Network ~= nil and Network.onWorldKind ~= nil then
    Network.onWorldKind("pp", function(slot, d)
        if ready() then
            module.onSample(slot, d)
        end
    end)
end
if ON ~= nil and ON.POST_UPDATE ~= nil then
    set_callback(function()
        if broken == nil and (next(samples) ~= nil or next(puppets) ~= nil) then
            local ok, err = pcall(updatePuppets)
            if not ok then
                forgetAll()
                standDown("drawing them failed: " .. tostring(err))
            end
        end
    end, ON.POST_UPDATE)
end
set_callback(function(ctx)
    if broken ~= nil then
        return
    end
    SafeCall("campPuppets:send", sendTick)
    if next(puppets) ~= nil then
        SafeCall("campPuppets:tags", guiTags, ctx)
    end
end, ON.GUIFRAME)
-- The camp is going: its entities, the puppets among them, die with it, and their uids
-- are the next level's to give out.
if ON ~= nil and ON.PRE_LEVEL_DESTRUCTION ~= nil then
    set_callback(forgetAll, ON.PRE_LEVEL_DESTRUCTION)
end
if ON ~= nil and ON.SCREEN ~= nil then
    set_callback(function()
        local ok, ls = pcall(get_local_state)
        if not ok or ls == nil or ls.screen ~= SCREEN.CAMP then
            forgetAll()
        end
    end, ON.SCREEN)
end
if VanillaUI ~= nil and VanillaUI.layer ~= nil then
    VanillaUI.layer("puppettags", 25, vanillaTags)
end

--- For the tests and the log: how many puppets are up.
--- @return integer
function module.count()
    local n = 0
    for _ in pairs(puppets) do
        n = n + 1
    end
    return n
end

--- @return string?
function module.why()
    return broken
end

CampPuppets = module
return module
