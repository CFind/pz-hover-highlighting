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

---@type IsoObject|nil
local highlightedObject = nil

---Clear the current hover highlight, if any.
local function clearHighlight()
    local obj = highlightedObject
    if obj == nil then
        return
    end
    highlightedObject = nil
    if obj:getSquare() == nil then
        return
    end
    obj:setHighlighted(MOUSE_PLAYER, false, false)
    obj:setOutlineHighlight(MOUSE_PLAYER, false)
    obj:setOutlineHlAttached(MOUSE_PLAYER, false)
    ISInventoryPage.OnObjectHighlighted(MOUSE_PLAYER, obj, false)
end

---@param player IsoPlayer
---@return boolean
local function playerCanHover(player)
    if player:isDead() or player:isAiming() or player:isAsleep() then
        return false
    end
    if player:getVehicle() ~= nil then
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

---Use the multi-square master so fridge/counter glow matches the opened container.
---@param obj IsoObject
---@return IsoObject
local function resolveTarget(obj)
    local master = obj:getMasterObject()
    if master ~= nil then
        return master
    end
    return obj
end

---True when this square already has IsoWindow glass on the same N/W edge.
---WindowN/W wall sprites (and IsoWindowFrame) copy the window's menu; highlight the glass.
---See iso/IsoObject.java:7032, iso/objects/IsoWindowFrame.java:138, iso/IsoGridSquare.java:3778.
---@param obj IsoObject
---@return boolean
local function hasWindowGlassOnSameEdge(obj)
    local square = obj:getSquare()
    if square == nil then
        return false
    end
    if obj:hasProperty(IsoFlagType.WindowN) and square:getWindow(true) ~= nil then
        return true
    end
    if obj:hasProperty(IsoFlagType.WindowW) and square:getWindow(false) ~= nil then
        return true
    end
    if instanceof(obj, "IsoWindowFrame") then
        ---@type IsoWindowFrame
        local frame = obj
        return frame:hasWindow()
    end
    return false
end

---Door/window tiles can carry wall flags; treat them as interactables, not walls.
---The wall around an IsoWindow is a separate pick with WindowN/W; leave it dark.
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
    if hasWindowGlassOnSameEdge(obj) then
        return false
    end
    return instanceof(obj, "IsoWindowFrame") or obj:isWindow()
end

---Floors, stairs, and cutaway walls are generic sprites; they pick easily and glow badly.
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
---add no Open option. Skip that type rather than the Wood_DogHouse script name.
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

---True when this object itself is a world-menu source, not merely scrapable.
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

---@param player IsoPlayer
---@return IsoObject|nil
local function getHoverObject(player)
    -- ClickObject is not exposed to Lua (docs/java-library/zombie/iso/__package.lua),
    -- so ContextPick(...).tile throws. UIManager.getLastPicked() is the IsoObject the
    -- engine already resolved from that pick (ui/UIManager.java:1543-1560).
    local picked = UIManager.getLastPicked()
    if picked == nil then
        return nil
    end
    local obj = resolveTarget(picked)
    local square = obj:getSquare()
    if square == nil or not square:isSeen(MOUSE_PLAYER) then
        return nil
    end
    if not isEligible(obj, player) then
        return nil
    end
    return obj
end

local function onRenderTick()
    local player = getSpecificPlayer(MOUSE_PLAYER)
    if player == nil or not playerCanHover(player) or isMouseOverUI() then
        clearHighlight()
        return
    end
    local obj = getHoverObject(player)
    if obj == highlightedObject then
        return
    end
    clearHighlight()
    if obj == nil then
        return
    end
    applyHighlight(obj)
    highlightedObject = obj
end

Events.OnRenderTick.Add(onRenderTick)
