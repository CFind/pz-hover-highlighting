--[[
    HoverHighlighting
    This is a mod for Project Zomboid. It highlights items you hover
    the mouse over. Client side only.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
]]

-- Mouse input is always player 0 in vanilla click handling.
local MOUSE_PLAYER = 0

-- Height of one storey's wall in tiles of iso ground distance. A storey is
-- 96 * tileScale screen px (iso/IsoUtils.java:105) and a tile of iso x or y moves
-- the screen 32 * tileScale px (iso/IsoUtils.java:75), so a wall spans 3 tiles.
-- FBO picking ignores cutaway IsoWindows (iso/fboRenderChunk/FBORenderObjectPicker.java:140-163),
-- so south-facing glass is found on the wall plane instead of by ContextPick / PickWindow.
local WALL_HEIGHT_TILES = 3

-- The world menu's Grab options come from every ground item within this many screen
-- pixels of the cursor (divided by zoom). See iso/ISWorldObjectContextMenuLogic.java:3343-3361, 3414-3426.
local GRAB_RADIUS_PX = 48

-- With the cursor still, an object that drops out of the wanted set is held this
-- long before it is cleared. Engine-side churn (a door's Hit_Door render effect,
-- chunk re-renders) can remove an object from the pick list for a few frames; the
-- hold hides that. Any real cursor movement clears immediately.
local HOLD_MS = 100
local HOLD_MOVE_PX = 2

-- Java objects are stable table keys; vanilla keys ObjectsHighlightedElsewhere the same
-- way (client/ISUI/ISInventoryPage.lua:434).
---@type table<IsoObject, boolean>
local highlighted = {}
---Scratch set rebuilt every frame; emptied at the end of onRenderTick.
---@type table<IsoObject, boolean>
local wanted = {}
---getTimestampMs() of the last frame each highlighted object was wanted.
---@type table<IsoObject, number>
local lastWanted = {}
---Cursor position the hold is measured from; re-anchored on real movement.
local holdAnchorX, holdAnchorY = -1, -1

---@param obj IsoObject
local function clearHighlight(obj)
    if obj:getSquare() == nil then
        return
    end
    obj:setHighlighted(MOUSE_PLAYER, false, false)
    obj:setOutlineHighlight(MOUSE_PLAYER, false)
    obj:setOutlineHlAttached(MOUSE_PLAYER, false)
    ISInventoryPage.OnObjectHighlighted(MOUSE_PLAYER, obj, false)
end

local function clearAllHighlights()
    for obj in pairs(highlighted) do
        clearHighlight(obj)
        highlighted[obj] = nil
        lastWanted[obj] = nil
    end
end

---@param player IsoPlayer
---@return boolean
local function playerCanHover(player)
    if player:isDead() or player:isAiming() or player:isAsleep()
        or player:getVehicle() ~= nil then
        return false
    end
    local speedControls = UIManager.getSpeedControls()
    if speedControls ~= nil and speedControls:getCurrentGameSpeed() == 0 then
        return false
    end
    local cell = getCell()
    if cell ~= nil and cell:getDrag(MOUSE_PLAYER) ~= nil then
        return false
    end
    if ISWorldMap_instance and ISWorldMap_instance:isVisible() then
        return false
    end
    return true
end

---@return boolean
local function isMouseOverUI()
    if UIManager.isMouseOverInventory() then
        return true
    end
    if ISMouseDrag.dragging ~= nil and #ISMouseDrag.dragging > 0 then
        return true
    end
    local uiList = UIManager.getUI()
    if uiList == nil then
        return false
    end
    for i = uiList:size() - 1, 0, -1 do
        local ui = uiList:get(i)
        if ui ~= nil and ui:isVisible() and ui:isMouseOver() then
            return true
        end
    end
    return false
end

---The IsoWindow pane on the same N/W edge as this wall, frame, or cutaway.
---`IsoObject:isWindow()` is only the WindowN/W *wall* flags (iso/IsoObject.java:7032),
---not the glass. South-facing room walls are WindowN/cutN on the square south of
---the room; ContextPick hits that wall for most of the sprite.
---See iso/IsoGridSquare.java:3778, iso/objects/IsoWindowFrame.java:138.
---@param obj IsoObject
---@return IsoWindow|nil
local function windowPaneFor(obj)
    if instanceof(obj, "IsoWindow") then
        return obj
    end
    local square = obj:getSquare()
    if square == nil then
        return nil
    end
    if instanceof(obj, "IsoWindowFrame") then
        ---@type IsoWindowFrame
        local frame = obj
        return frame:getWindow()
    end
    if obj:hasProperty(IsoFlagType.WindowN)
        or obj:hasProperty(IsoFlagType.cutN)
        or obj:isWallN()
    then
        local pane = square:getWindow(true)
        if pane ~= nil then
            return pane
        end
    end
    if obj:hasProperty(IsoFlagType.WindowW)
        or obj:hasProperty(IsoFlagType.cutW)
        or obj:isWallW()
    then
        return square:getWindow(false)
    end
    return nil
end

---Use the multi-square master so fridge/counter glow matches the opened container.
---WindowN/W walls and frames that already have glass become the pane, so hovering
---the wall that *contains* the window lights the glass instead of nothing.
---@param obj IsoObject
---@return IsoObject
local function resolveTarget(obj)
    local master = obj:getMasterObject()
    if master ~= nil then
        obj = master
    end
    local pane = windowPaneFor(obj)
    if pane ~= nil then
        return pane
    end
    return obj
end

---The glass, a door, a curtain, an empty opening, or a player-built door/window.
---Wall sprites around an IsoWindow stay structural even if they carry WindowN/W.
---@param obj IsoObject
---@return boolean
local function isDoorOrWindow(obj)
    if instanceof(obj, "IsoDoor")
        or instanceof(obj, "IsoWindow")
        or instanceof(obj, "IsoCurtain")
    then
        return true
    end
    if instanceof(obj, "IsoThumpable") then
        ---@type IsoThumpable
        local thump = obj
        return thump:isDoor() or thump:isWindowN() or thump:isWindowW()
    end
    -- Glass lives in a separate IsoWindow; this object is the wall/frame around it.
    if windowPaneFor(obj) ~= nil then
        return false
    end
    return instanceof(obj, "IsoWindowFrame") or obj:isWindow()
end

---Floors, stairs, and cutaway walls are generic sprites;
---They 
---@param obj IsoObject
---@return boolean
local function isStructuralTile(obj)
    if isDoorOrWindow(obj) then
        return false
    end
    if obj:isFloor() or obj:isWall() or obj:isStairsObject() then
        return true
    end
    return obj:hasProperty(IsoFlagType.WallNW)
        or obj:hasProperty(IsoFlagType.cutN)
        or obj:hasProperty(IsoFlagType.cutW)
end

---True when this object has a player-facing loot container.
---Doghouses are ItemContainers (tile property container=doghouse) with loot, but they
---add no Open option.
---See iso/IsoObject.java:5441 and media/newtiledefinitions.tiles.txt (farm accessories).
---@param obj IsoObject
---@return boolean
local function hasPlayerLootContainer(obj)
    local count = obj:getContainerCount()
    if count <= 0 then
        return false
    end
    for i = 0, count - 1 do
        local container = obj:getContainerByIndex(i)
        if container ~= nil and container:getType() ~= "doghouse" then
            return true
        end
    end
    return false
end

---True when this object itself is a world-menu source, not scrapable.
---Square-level options (walk-to, clean blood) and disassemble-only tiles are ignored.
---See iso/ISWorldObjectContextMenuLogic.java:117.
---@param obj IsoObject
---@param player IsoPlayer
---@return boolean
local function contributesWorldMenu(obj, player)
    if isDoorOrWindow(obj) then
        return true
    end
    if instanceof(obj, "IsoWorldInventoryObject") or hasPlayerLootContainer(obj) then
        return true
    end
    if obj:hasFluid() or obj:hasComponent(ComponentType.FluidContainer) or obj:hasProperty(IsoFlagType.waterPiped) then
        return true
    end
    -- UiConfig exists on most sprite-config tiles (pianos, doghouses). Only accept
    -- entities that actually open a window — the option ISContextEntity would add.
    if ISEntityUI.CanOpenWindowFor(player, obj) then
        return true
    end
    if obj:isHoppable() or obj:hasProperty(IsoFlagType.bed) then
        return true
    end
    if obj:hasProperty("fuelAmount") or obj:getPipedFuelAmount() > 0 then
        return true
    end
    return instanceof(obj, "IsoLightSwitch")
        or instanceof(obj, "IsoStove")
        or instanceof(obj, "IsoGenerator")
        or instanceof(obj, "IsoWaveSignal")
        or instanceof(obj, "IsoBarbecue")
        or instanceof(obj, "IsoFireplace")
        or instanceof(obj, "IsoCompost")
        or instanceof(obj, "IsoClothingWasher")
        or instanceof(obj, "IsoClothingDryer")
        or instanceof(obj, "IsoCombinationWasherDryer")
        or instanceof(obj, "IsoStackedWasherDryer")
        or instanceof(obj, "IsoCarBatteryCharger")
        or instanceof(obj, "IsoMannequin")
        or instanceof(obj, "IsoTrap")
        or instanceof(obj, "IsoBrokenGlass")
        or instanceof(obj, "IsoTree")
        or instanceof(obj, "IsoDeadBody")
        or instanceof(obj, "IsoButcherHook")
        or instanceof(obj, "IsoFeedingTrough")
        or instanceof(obj, "IsoHutch")
        or instanceof(obj, "IsoJukebox")
        or instanceof(obj, "IsoAnimalTrack")
        or instanceof(obj, "BaseVehicle")
end

---@param obj IsoObject
---@param player IsoPlayer
---@return boolean
local function isEligible(obj, player)
    if instanceof(obj, "IsoGameCharacter") then
        return false
    end
    if isStructuralTile(obj) then
        return false
    end
    return contributesWorldMenu(obj, player)
end

---@param obj IsoObject
local function applyHighlight(obj)
    if instanceof(obj, "IsoWorldInventoryObject") then
        -- Ground items apply world-item color and outline inside setHighlighted.
        obj:setHighlighted(MOUSE_PLAYER, true, false)
    else
        local color = getCore():getObjectHighlitedColor()
        obj:setHighlightColor(MOUSE_PLAYER, color)
        -- renderOnce=false keeps the glow until we clear it.
        obj:setHighlighted(MOUSE_PLAYER, true, false)
        if getCore():getOptionDoContainerOutline() then
            obj:setOutlineHighlight(MOUSE_PLAYER, true)
            obj:setOutlineHlAttached(MOUSE_PLAYER, true)
            obj:setOutlineHighlightCol(MOUSE_PLAYER, color:getR(), color:getG(), color:getB(), 1)
        end
    end
    ISInventoryPage.OnObjectHighlighted(MOUSE_PLAYER, obj, true)
end

---Sprite quad scale used when recording pick bounds.
---See iso/IsoObject.java:6595-6604.
---@param tex Texture
---@return number
---@return number
local function spritePickScale(tex)
    if Core.getTileScale() == 2 and tex:getWidthOrig() == 64 and tex:getHeightOrig() == 128 then
        return 2, 2
    end
    return 1, 1
end

---True when the cursor hits this object's sprite mask.
---ContextPick already finds every mask hit, then returns only the highest-scored
---one (iso/IsoObjectPicker.java:184-203, iso/fboRenderChunk/FBORenderObjectPicker.java:80-125).
---ClickObject is not exposed, so the rest of that list is rebuilt here.
---@param obj IsoObject
---@return boolean
local function spriteContainsMouse(obj)
    if obj:getTargetAlpha(MOUSE_PLAYER) == 0 then
        return false
    end
    local sprite = obj:getSprite()
    if sprite == nil then
        return false
    end
    local square = obj:getSquare()
    if square == nil then
        return false
    end
    local dir = obj:getForwardIsoDirection()
    -- 1-arg only: the 2-arg overloads are (dir, boolean) and (dir, IsoObject),
    -- and Lua picks Java overloads by arity (docs/gotchas.md).
    local tex = sprite:getTextureForCurrentFrame(dir)
    if tex == nil then
        return false
    end
    local zoom = getCore():getZoom(MOUSE_PLAYER)
    -- Quad origin: XToScreen(square) minus object offsets, in UI pixels.
    -- iso/IsoObject.java:6616-6620 plus Lua/LuaManager.java:3515-3532.
    local ox = isoToScreenX(MOUSE_PLAYER, square:getX(), square:getY(), square:getZ())
        - obj:getOffsetX() / zoom
    local oy = isoToScreenY(MOUSE_PLAYER, square:getX(), square:getY(), square:getZ())
        -- Core.tileScale is a Java field and not a Lua number; vanilla uses getTileScale()
        -- (core/Core.java:4100, media/lua/server/BuildingObjects/ISDestroyCursor.lua:207).
        - (obj:getOffsetY() + obj:getRenderYOffset() * Core.getTileScale()) / zoom
    local scaleX, scaleY = spritePickScale(tex)
    local lx = (getMouseX() - ox) * zoom
    local ly = (getMouseY() - oy) * zoom
    local width = tex:getWidthOrig() * scaleX
    local height = tex:getHeightOrig() * scaleY
    if lx <= 0 or ly <= 0 or lx > width or ly > height then
        return false
    end
    -- iso/sprite/IsoSprite.java:1708
    local flip = dir == IsoDirections.W or dir == IsoDirections.SW or dir == IsoDirections.S
    if scaleX ~= 1 or scaleY ~= 1 then
        lx = lx / scaleX
        ly = ly / scaleY
    end
    lx = math.floor(lx)
    ly = math.floor(ly)
    return obj:isMaskClicked(lx, ly, flip)
end

---Light an opening (glass, empty frame, built window) and the curtain that hangs
---on it. Curtains are only ever reached through their opening: a curtainS has
---`north == true` (iso/CellLoader.java:340) and hangs one square north of its
---window, so scanning a square for "north curtains" also catches the curtain of
---the window on the *next* row — the wrong room. HasCurtains resolves the pair
---correctly (iso/objects/IsoWindow.java:152-162).
---@param obj IsoObject|nil
---@param player IsoPlayer
---@param out table<IsoObject, boolean>
local function addOpening(obj, player, out)
    if obj == nil then
        return
    end
    obj = resolveTarget(obj)
    if out[obj] then
        return
    end
    local square = obj:getSquare()
    if square == nil then
        return
    end
    if isEligible(obj, player) then
        out[obj] = true
        if instanceof(obj, "IsoWindow")
            or instanceof(obj, "IsoWindowFrame")
            or instanceof(obj, "IsoThumpable")
        then
            ---@type IsoWindow|IsoWindowFrame|IsoThumpable
            local opening = obj
            addOpening(opening:HasCurtains(), player, out)
        end
    end
end

---Add every opening on this square's north (or west) edge.
---@param square IsoGridSquare
---@param north boolean
---@param player IsoPlayer
---@param out table<IsoObject, boolean>
---@return boolean hasOpening true if the edge holds any opening, eligible or not
local function addOpeningsOnEdge(square, north, player, out)
    local found = false
    local window = square:getWindow(north)
    if window ~= nil then
        addOpening(window, player, out)
        found = true
    end
    local frame = square:getWindowFrame(north)
    if frame ~= nil then
        addOpening(frame, player, out)
        found = true
    end
    local objects = square:getObjects()
    for n = 0, objects:size() - 1 do
        local obj = objects:get(n)
        if instanceof(obj, "IsoThumpable") then
            ---@type IsoThumpable
            local thump = obj
            if (north and thump:isWindowN()) or (not north and thump:isWindowW()) then
                addOpening(thump, player, out)
                found = true
            end
        end
    end
    return found
end

---Openings on the N (or W) wall plane under the cursor.
---
---The FBO picker strips cutaway IsoWindows from its click list
---(iso/fboRenderChunk/FBORenderObjectPicker.java:140-163), so south-facing glass
---never reaches getLastPicked or PickWindow and has to be found geometrically.
---screenToIso assumes the cursor is on the ground; a point `h` px up a north wall
---at y = sy instead converts to (x - h/32t, sy - h/32t) (iso/IsoUtils.java:73-105,
---t = tileScale). So `d = sy - wy` is the height in tiles and `wx + d` the position
---along the wall. A storey is 96t px = 3 tiles, hence WALL_HEIGHT_TILES.
---
---Several squares along the toward-camera diagonal satisfy this for different
---heights; the nearest wall drawn on top wins, so walk from nearest and stop at
---the first edge holding an opening or a plain wall.
---@param cell IsoCell
---@param z integer
---@param wx number
---@param wy number
---@param north boolean
---@param player IsoPlayer
---@param out table<IsoObject, boolean>
local function collectOpeningsOnWallPlane(cell, z, wx, wy, north, player, out)
    -- `edge` is the plane coordinate (y for a north wall, x for a west wall);
    -- `along` runs the length of the wall.
    local e = north and wy or wx
    local a = north and wx or wy
    for edge = math.floor(e + WALL_HEIGHT_TILES), math.ceil(e), -1 do
        local d = edge - e
        if d < WALL_HEIGHT_TILES then
            local along = math.floor(a + d)
            local square
            if north then
                square = cell:getGridSquare(along, edge, z)
            else
                square = cell:getGridSquare(edge, along, z)
            end
            if square ~= nil then
                if addOpeningsOnEdge(square, north, player, out) then
                    return
                end
                if square:getWall(north) ~= nil then
                    return
                end
            end
        end
    end
end

---Eligible furniture on this square whose sprite mask contains the cursor.
---ContextPick finds every such hit and keeps only the top-scored one
---(iso/IsoObjectPicker.java:184-203); this recovers the rest. Windows, frames,
---and curtains are handled by collectOpeningsOnWallPlane, ground items by
---collectItemsOnSquare, so both are skipped here.
---@param square IsoGridSquare
---@param player IsoPlayer
---@param out table<IsoObject, boolean>
local function collectFurnitureOnSquare(square, player, out)
    local objects = square:getObjects()
    for n = 0, objects:size() - 1 do
        local obj = resolveTarget(objects:get(n))
        if not out[obj]
            and not instanceof(obj, "IsoWorldInventoryObject")
            and not instanceof(obj, "IsoWindow")
            and not instanceof(obj, "IsoCurtain")
            and not instanceof(obj, "IsoWindowFrame")
            and isEligible(obj, player)
            and spriteContainsMouse(obj)
        then
            out[obj] = true
        end
    end
end

---Ground items on this square within the world menu's grab radius of the cursor.
---This is the one part of the menu that is radius-based; vanilla applies it only
---to IsoWorldInventoryObject (iso/ISWorldObjectContextMenuLogic.java:3343-3361),
---and getScreenPosX/Y exists only on that class (iso/objects/IsoWorldInventoryObject.java:663).
---@param square IsoGridSquare
---@param mx integer
---@param my integer
---@param radiusSq number
---@param out table<IsoObject, boolean>
local function collectItemsOnSquare(square, mx, my, radiusSq, out)
    local items = square:getWorldObjects()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local dx = item:getScreenPosX(MOUSE_PLAYER) - mx
        local dy = item:getScreenPosY(MOUSE_PLAYER) - my
        if dx * dx + dy * dy <= radiusSq then
            out[item] = true
        end
    end
end

---One walk over the squares around the cursor, applying each kind's own test.
---The world menu has no single search to mirror: it expands to whole squares
---for objects (iso/ISWorldObjectContextMenuLogic.java:576-643) and uses a screen
---radius only for ground items. Square expansion is deliberately not used here —
---a piano next to a fridge would light — so the tests stay per kind, but the iso
---conversion and square lookup happen once.
---
---Box: one tile behind the cursor and pick, three toward the camera. Tall sprites
---cover pixels that iso-convert several squares in front
---(iso/fboRenderChunk/FBORenderObjectPicker.java:40-42, 267-275); the item
---radius needs less and is simply filtered by its own test.
---
---Furniture and items require a seen square, the same gate the right-click
---handler puts on the menu (server/ISObjectClickHandler.lua:33). Openings are
---exempt there too: a south window's square is outside the room.
---@param player IsoPlayer
---@param z integer
---@param pickSquare IsoGridSquare|nil
---@param out table<IsoObject, boolean>
local function collectAroundCursor(player, z, pickSquare, out)
    -- getMouseX/Y are Mouse.getXA/YA, the same space UIManager passes to the menu
    -- (ui/UIManager.java:533-534) and that getScreenPosX/Y returns.
    local mx = getMouseX()
    local my = getMouseY()
    local wx = screenToIsoX(MOUSE_PLAYER, mx, my, z)
    local wy = screenToIsoY(MOUSE_PLAYER, mx, my, z)
    local cell = getCell()
    collectOpeningsOnWallPlane(cell, z, wx, wy, true, player, out)
    collectOpeningsOnWallPlane(cell, z, wx, wy, false, player, out)
    local ix = math.floor(wx)
    local iy = math.floor(wy)
    local px, py = ix, iy
    if pickSquare ~= nil then
        px = pickSquare:getX()
        py = pickSquare:getY()
    end
    local minX = math.min(ix, px) - 1
    local maxX = math.max(ix, px) + 3
    local minY = math.min(iy, py) - 1
    local maxY = math.max(iy, py) + 3
    local radius = GRAB_RADIUS_PX / getCore():getZoom(MOUSE_PLAYER)
    local radiusSq = radius * radius
    for y = minY, maxY do
        for x = minX, maxX do
            local square = cell:getGridSquare(x, y, z)
            if square ~= nil and square:isSeen(MOUSE_PLAYER) then
                collectFurnitureOnSquare(square, player, out)
                collectItemsOnSquare(square, mx, my, radiusSq, out)
            end
        end
    end
end

---The right-click handler's visibility gate: the picked square must be seen
---unless the pick is a window, door, thumpable, or tree
---(server/ISObjectClickHandler.lua:33).
---@param obj IsoObject
---@param square IsoGridSquare
---@return boolean
local function pickIsVisible(obj, square)
    return square:isSeen(MOUSE_PLAYER)
        or instanceof(obj, "IsoWindow")
        or instanceof(obj, "IsoDoor")
        or instanceof(obj, "IsoThumpable")
        or instanceof(obj, "IsoTree")
end

---Fill `out` with every object the hover should light this frame.
---@param player IsoPlayer
---@param out table<IsoObject, boolean>
local function collectHoverObjects(player, out)
    -- ClickObject is not exposed to Lua (docs/java-library/zombie/iso/__package.lua),
    -- so ContextPick(...).tile throws. UIManager.getLastPicked() is the IsoObject the
    -- engine already resolved from that pick (ui/UIManager.java:1543-1560).
    --
    -- The pick is a hint, not a gate. UIManager nulls it whenever ContextPick has
    -- no hit (ui/UIManager.java:1542-1560), and an object drops out of the pick
    -- list while its render info is in flux — e.g. a door with a Hit_Door effect
    -- is pulled out of the chunk texture for 15-30 ticks per thump
    -- (iso/objects/IsoDoor.java:1200, iso/fboRenderChunk/FBORenderCell.java:1797).
    -- Bailing on a nil pick made every highlight blink at the thump rhythm.
    local picked = UIManager.getLastPicked()
    local z = math.floor(player:getZ())
    ---@type IsoGridSquare|nil
    local pickSquare = nil
    if picked ~= nil then
        local obj = resolveTarget(picked)
        pickSquare = obj:getSquare()
        if pickSquare ~= nil then
            z = pickSquare:getZ()
            if pickIsVisible(obj, pickSquare) and isEligible(obj, player) then
                out[obj] = true
            end
        end
    end
    -- The menu runs its search for any picked object with a square
    -- (server/ISObjectClickHandler.lua:33), so this runs even when the pick is a floor.
    collectAroundCursor(player, z, pickSquare, out)
end

local function onRenderTick()
    local player = getSpecificPlayer(MOUSE_PLAYER)
    if player == nil or not playerCanHover(player) or isMouseOverUI() then
        clearAllHighlights()
        return
    end
    local now = getTimestampMs()
    local mx = getMouseX()
    local my = getMouseY()
    local moved = math.abs(mx - holdAnchorX) > HOLD_MOVE_PX
        or math.abs(my - holdAnchorY) > HOLD_MOVE_PX
    if moved then
        holdAnchorX = mx
        holdAnchorY = my
    end
    collectHoverObjects(player, wanted)
    -- Lua 5.1 allows clearing the current key during pairs(); adding keys does not.
    for obj in pairs(highlighted) do
        if wanted[obj] then
            lastWanted[obj] = now
        elseif moved
            or obj:getSquare() == nil
            or now - (lastWanted[obj] or 0) > HOLD_MS
        then
            clearHighlight(obj)
            highlighted[obj] = nil
            lastWanted[obj] = nil
        end
    end
    for obj in pairs(wanted) do
        if not highlighted[obj] then
            applyHighlight(obj)
            highlighted[obj] = true
            lastWanted[obj] = now
        end
        wanted[obj] = nil
    end
end

Events.OnRenderTick.Add(onRenderTick)