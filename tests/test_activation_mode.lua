local sourcePath = arg[1] or "hoverhighlighting/42/media/lua/client/HoverHighlighting.lua"

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ")
            .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local bootHandlers = {}
local renderHandler = nil
local optionsById = {}
local activationModeOption = nil
local modOptionsLoadCount = 0
local keyDown = false
local keyChecks = 0
local playerLookups = 0

require = function(name)
    assertEqual(name, "PZAPI/ModOptions", "unexpected required module")
end

local function newValueOption(value)
    return {
        value = value,
        getValue = function(self)
            return self.value
        end,
        setValue = function(self, newValue)
            self.value = newValue
        end,
    }
end

PZAPI = {
    ModOptions = {
        Data = {},
        getOptions = function(self, id)
            return optionsById[id]
        end,
        create = function(self, id, name)
            local options = { id = id, name = name, data = {}, dict = {} }
            options.addColorPicker = function(optionSelf, optionId, optionName, r, g, b, a, tooltip)
                local option = newValueOption({ r = r, g = g, b = b, a = a })
                option.id = optionId
                option.name = optionName
                option.tooltip = tooltip
                optionSelf.dict[optionId] = option
                table.insert(optionSelf.data, option)
                return option
            end
            options.addTickBox = function(optionSelf, optionId, optionName, value, tooltip)
                local option = newValueOption(value)
                option.id = optionId
                option.name = optionName
                option.tooltip = tooltip
                optionSelf.dict[optionId] = option
                table.insert(optionSelf.data, option)
                activationModeOption = option
                return option
            end
            options.getOption = function(optionSelf, optionId)
                return optionSelf.dict[optionId]
            end
            optionsById[id] = options
            table.insert(self.Data, options)
            return options
        end,
        load = function()
            modOptionsLoadCount = modOptionsLoadCount + 1
        end,
    },
}

Events = {
    OnGameBoot = {
        Add = function(handler)
            table.insert(bootHandlers, handler)
        end,
    },
    OnRenderTick = {
        Add = function(handler)
            renderHandler = handler
        end,
    },
}

Keyboard = { KEY_TAB = 15 }
keyBinding = {}

isKeyDown = function(bindingName)
    keyChecks = keyChecks + 1
    assertEqual(bindingName, "HoverHighlighting Activation", "render guard binding")
    return keyDown
end

getSpecificPlayer = function()
    playerLookups = playerLookups + 1
    return nil
end

dofile(sourcePath)

assert(activationModeOption ~= nil, "Require key press option was not registered")
assertEqual(activationModeOption.name, "IGUI_HoverHighlighting_RequireKeyPress", "checkbox translation key")
assertEqual(activationModeOption:getValue(), false, "Require key press default")
assert(renderHandler ~= nil, "OnRenderTick handler was not registered")

for _, handler in ipairs(bootHandlers) do
    handler()
end

assertEqual(modOptionsLoadCount, 1, "Mod Options load count")
assertEqual(#keyBinding, 2, "vanilla keybinding entries")
assertEqual(keyBinding[1].value, "[Hover Highlighting]", "keybinding category")
assertEqual(keyBinding[2].value, "HoverHighlighting Activation", "keybinding identifier")
assertEqual(keyBinding[2].key, Keyboard.KEY_TAB, "keybinding default")

activationModeOption:setValue(true)
keyDown = false
keyChecks = 0
playerLookups = 0
renderHandler()
assertEqual(keyChecks, 1, "enabled mode key checks")
assertEqual(playerLookups, 0, "key-up mode must exit before hover discovery")

keyDown = true
keyChecks = 0
playerLookups = 0
renderHandler()
assertEqual(keyChecks, 1, "held-key mode key checks")
assertEqual(playerLookups, 1, "held key must continue hover processing")

activationModeOption:setValue(false)
keyDown = false
keyChecks = 0
playerLookups = 0
renderHandler()
assertEqual(keyChecks, 0, "disabled mode must not inspect the activation key")
assertEqual(playerLookups, 1, "disabled mode must continue hover processing")

print("PASS: HoverHighlighting activation mode")
