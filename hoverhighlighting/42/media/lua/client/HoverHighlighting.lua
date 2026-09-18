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

-- The world menu's Grab options come from every ground item within this many screen
-- pixels of the cursor (divided by zoom), across squares within one tile of the
-- cursor's iso position. See iso/ISWorldObjectContextMenuLogic.java:3326-3361, 3414-3426.
local GRAB_RADIUS_PX = 48
local GRAB_RADIUS_TILES = 1

-- Java objects are stable table keys; vanilla keys ObjectsHighlightedElsewhere the same
-- way (client/ISUI/ISInventoryPage.lua:434).
---@type table<IsoObject, boolean>
local highlighted = {}
---Scratch set rebuilt every frame; emptied at the end of onRenderTick.
---@type table<IsoObject, boolean>
local wanted = {}

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

---True when the cursor hits this object's sprite mask (or a window's glass gap).
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
    if obj:isMaskClicked(lx, ly, flip) then
        return true
    end
    -- Window / frame glass is empty mask; PickWindow still accepts the click when
    -- opaque pixels sit both above and below (iso/IsoObjectPicker.java:374-394, 424-442).
    if not instanceof(obj, "IsoWindow") and not instanceof(obj, "IsoWindowFrame") then
        return false
    end
    local above = false
    local ty = ly
    while ty >= 0 do
        if obj:isMaskClicked(lx, ty) then
            above = true
            break
        end
        ty = ty - 1
    end
    if not above then
        return false
    end
    ty = ly
    local maskHeight = tex:getHeightOrig()
    while ty < maskHeight do
        if obj:isMaskClicked(lx, ty) then
            return true
        end
        ty = ty + 1
    end
    return false
end

---Eligible tiles whose sprites actually contain the cursor, including ones
---ContextPick discarded as not the top hit. Search the pick square and the iso
---cell under the cursor, plus a few tiles toward the camera — tall sprites cover
---pixels that iso-convert several squares in front (iso/fboRenderChunk/FBORenderObjectPicker.java:40-42, 267-275).
---@param player IsoPlayer
---@param pickSquare IsoGridSquare
---@param out table<IsoObject, boolean>
local function collectOverlappingObjects(player, pickSquare, out)
    local mx = getMouseX()
    local my = getMouseY()
    local z = pickSquare:getZ()
    local wx = math.floor(screenToIsoX(MOUSE_PLAYER, mx, my, z))
    local wy = math.floor(screenToIsoY(MOUSE_PLAYER, mx, my, z))
    local px = pickSquare:getX()
    local py = pickSquare:getY()
    local minX = math.min(wx, px) - 1
    local maxX = math.max(wx, px) + 3
    local minY = math.min(wy, py) - 1
    local maxY = math.max(wy, py) + 3
    local cell = getCell()
    for y = minY, maxY do
        for x = minX, maxX do
            local square = cell:getGridSquare(x, y, z)
            if square ~= nil and square:isSeen(MOUSE_PLAYER) then
                local objects = square:getObjects()
                for n = 0, objects:size() - 1 do
                    local obj = resolveTarget(objects:get(n))
                    if not out[obj]
                        and not instanceof(obj, "IsoWorldInventoryObject")
                        and isEligible(obj, player)
                        and spriteContainsMouse(obj)
                    then
                        out[obj] = true
                    end
                end
            end
        end
    end
end

---Ground items the world menu would offer to grab: the same radius search
---ISWorldObjectContextMenuLogic.handleInteraction runs on right-click, so a stack of
---items lights as one. Only the pick's Z is used; the cursor decides the squares.
---@param pickSquare IsoGridSquare
---@param out table<IsoObject, boolean>
local function collectNearbyWorldItems(pickSquare, out)
    -- getMouseX/Y are Mouse.getXA/YA, the same space UIManager passes to the menu
    -- (ui/UIManager.java:533-534) and that getScreenPosX/Y returns
    -- (iso/objects/IsoWorldInventoryObject.java:663-674).
    local mx = getMouseX()
    local my = getMouseY()
    local z = pickSquare:getZ()
    local wx = screenToIsoX(MOUSE_PLAYER, mx, my, z)
    local wy = screenToIsoY(MOUSE_PLAYER, mx, my, z)
    local radius = GRAB_RADIUS_PX / getCore():getZoom(MOUSE_PLAYER)
    local radiusSq = radius * radius
    local cell = getCell()
    for y = math.floor(wy - GRAB_RADIUS_TILES), math.ceil(wy + GRAB_RADIUS_TILES) do
        for x = math.floor(wx - GRAB_RADIUS_TILES), math.ceil(wx + GRAB_RADIUS_TILES) do
            local square = cell:getGridSquare(x, y, z)
            if square ~= nil and square:isSeen(MOUSE_PLAYER) then
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
        end
    end
end

---Fill `out` with every object the hover should light this frame.
---@param player IsoPlayer
---@param out table<IsoObject, boolean>
local function collectHoverObjects(player, out)
    -- ClickObject is not exposed to Lua (docs/java-library/zombie/iso/__package.lua),
    -- so ContextPick(...).tile throws. UIManager.getLastPicked() is the IsoObject the
    -- engine already resolved from that pick (ui/UIManager.java:1543-1560).
    local picked = UIManager.getLastPicked()
    if picked == nil then
        return
    end
    local obj = resolveTarget(picked)
    local square = obj:getSquare()
    if square == nil or not square:isSeen(MOUSE_PLAYER) then
        return
    end
    if isEligible(obj, player) then
        out[obj] = true
    end
    -- The wall's mask is the frame; clicks in the opening pick whatever is behind.
    -- PickWindow uses that gap test (iso/IsoObjectPicker.java:352-399) so the pane
    -- still lights. Skip it when resolveTarget already turned the wall into glass.
    if not instanceof(obj, "IsoWindow") and not instanceof(obj, "IsoCurtain") then
        local mx = getMouseX()
        local my = getMouseY()
        local window = IsoObjectPicker.Instance:PickWindow(mx, my)
        if window ~= nil then
            window = resolveTarget(window)
            local windowSquare = window:getSquare()
            if windowSquare ~= nil and windowSquare:isSeen(MOUSE_PLAYER) and isEligible(window, player) then
                out[window] = true
            end
        end
        local frame = IsoObjectPicker.Instance:PickWindowFrame(mx, my)
        if frame ~= nil then
            frame = resolveTarget(frame)
            local frameSquare = frame:getSquare()
            if frameSquare ~= nil and frameSquare:isSeen(MOUSE_PLAYER) and isEligible(frame, player) then
                out[frame] = true
            end
        end
    end
    -- ContextPick keeps only the top hit; collect every eligible sprite the cursor
    -- is actually over so a window in front of a bookcase can both light.
    collectOverlappingObjects(player, square, out)
    -- The menu runs the item search for any picked object with a seen square
    -- (server/ISObjectClickHandler.lua:33), so it runs even when the pick is a floor.
    collectNearbyWorldItems(square, out)
end

local function onRenderTick()
    local player = getSpecificPlayer(MOUSE_PLAYER)
    if player == nil or not playerCanHover(player) or isMouseOverUI() then
        clearAllHighlights()
        return
    end
    collectHoverObjects(player, wanted)
    -- Lua 5.1 allows clearing the current key during pairs(); adding keys does not.
    for obj in pairs(highlighted) do
        if not wanted[obj] then
            clearHighlight(obj)
            highlighted[obj] = nil
        end
    end
    for obj in pairs(wanted) do
        if not highlighted[obj] then
            applyHighlight(obj)
            highlighted[obj] = true
        end
        wanted[obj] = nil
    end
end

Events.OnRenderTick.Add(onRenderTick)