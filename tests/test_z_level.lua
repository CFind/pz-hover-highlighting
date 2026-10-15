local sourcePath = arg[1] or "hoverhighlighting/42/media/lua/client/HoverHighlighting.lua"

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")
            .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local renderHandler = nil
local picked = nil
local playerZ = 0
local now = 0
local requestedZ = {}

local function newValueOption(value)
    return {
        value = value,
        getValue = function(self)
            return self.value
        end,
    }
end

require = function(name)
    assertEqual(name, "PZAPI/ModOptions", "unexpected required module")
end

PZAPI = {
    ModOptions = {
        Data = {},
        getOptions = function()
            return nil
        end,
        create = function(self)
            local options = { dict = {} }
            options.addColorPicker = function(optionSelf, optionId, _, r, g, b, a)
                local option = newValueOption({ r = r, g = g, b = b, a = a })
                optionSelf.dict[optionId] = option
                return option
            end
            options.addTickBox = function(optionSelf, optionId, _, value)
                local option = newValueOption(value)
                optionSelf.dict[optionId] = option
                return option
            end
            options.getOption = function(optionSelf, optionId)
                return optionSelf.dict[optionId]
            end
            return options
        end,
        load = function() end,
    },
}

Events = {
    OnGameBoot = { Add = function() end },
    OnRenderTick = {
        Add = function(handler)
            renderHandler = handler
        end,
    },
}

Keyboard = { KEY_TAB = 15 }
keyBinding = {}
isKeyDown = function()
    return true
end

local player = {
    isDead = function() return false end,
    isAiming = function() return false end,
    isAsleep = function() return false end,
    getVehicle = function() return nil end,
    getZ = function() return playerZ end,
}

getSpecificPlayer = function()
    return player
end

local cell = {
    getDrag = function() return nil end,
    getGridSquare = function(_, _, _, z)
        requestedZ[#requestedZ + 1] = z
        return nil
    end,
}

getCell = function()
    return cell
end

UIManager = {
    getSpeedControls = function() return nil end,
    isMouseOverInventory = function() return false end,
    getUI = function() return nil end,
    getLastPicked = function() return picked end,
}

ISMouseDrag = { dragging = {} }
ISWorldMap_instance = nil
ISEntityUI = { CanOpenWindowFor = function() return false end }
GridSquareEdgeFacingDirection = {
    NORTH_SOUTH = "NORTH_SOUTH",
    EAST_WEST = "EAST_WEST",
}
IsoFlagType = {
    WindowN = "WindowN",
    WindowW = "WindowW",
    cutN = "cutN",
    cutW = "cutW",
    WallNW = "WallNW",
    waterPiped = "waterPiped",
    bed = "bed",
}
ComponentType = { FluidContainer = "FluidContainer" }

instanceof = function(obj, className)
    return obj ~= nil and obj.className == className
end

getMouseX = function() return 100 end
getMouseY = function() return 100 end
screenToIsoX = function() return 0 end
screenToIsoY = function() return 0 end
getTimestampMs = function() return now end
getCore = function()
    return { getZoom = function() return 1 end }
end

local function newSquare(z)
    return {
        getX = function() return 0 end,
        getY = function() return 0 end,
        getZ = function() return z end,
        isSeen = function() return true end,
    }
end

local function newWorldItem(square)
    local item = {
        className = "IsoWorldInventoryObject",
        square = square,
        outlined = false,
        outlineCalls = 0,
    }
    item.getMasterObject = function() return nil end
    item.getSquare = function(self) return self.square end
    item.hasProperty = function() return false end
    item.isWallN = function() return false end
    item.isWallW = function() return false end
    item.isWindow = function() return false end
    item.isFloor = function() return false end
    item.isWall = function() return false end
    item.isStairsObject = function() return false end
    item.getContainerCount = function() return 0 end
    item.hasFluid = function() return false end
    item.hasComponent = function() return false end
    item.isHoppable = function() return false end
    item.getPipedFuelAmount = function() return 0 end
    item.setOutlineHighlight = function(self, _, enabled)
        self.outlined = enabled
        self.outlineCalls = self.outlineCalls + 1
    end
    item.setOutlineHlAttached = function() end
    item.setOutlineHighlightCol = function() end
    item.isHighlighted = function() return false end
    return item
end

dofile(sourcePath)
assert(renderHandler ~= nil, "OnRenderTick handler was not registered")

local offLevelItem = newWorldItem(newSquare(1))
picked = offLevelItem
requestedZ = {}
renderHandler()

assertEqual(offLevelItem.outlined, false, "off-level direct pick must not highlight")
assert(#requestedZ > 0, "cursor scan did not request any grid squares")
for _, z in ipairs(requestedZ) do
    assertEqual(z, 0, "cursor scan must use the player's Z-level")
end

local sameLevelItem = newWorldItem(newSquare(0))
picked = sameLevelItem
now = 1000
renderHandler()
assertEqual(sameLevelItem.outlined, true, "same-level direct pick must highlight")

picked = nil
playerZ = 1
now = 1001
renderHandler()
assertEqual(sameLevelItem.outlined, false,
    "changing Z-level must clear an existing highlight without the hold delay")

print("PASS: HoverHighlighting Z-level filtering")
