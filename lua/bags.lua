---@diagnostic disable: undefined-global, undefined-field
-- VF: shim for /lua run bags. Prefer /lua run vft/inv

local mq = require('mq')
local chat = require('vft.chat')
local inv = require('vft.inv.app').create({ hosted = false })
inv.setOpen(true)

local function mqLeaving()
    local leaving = false
    pcall(function()
        if mq.exiting then leaving = not not mq.exiting() end
    end)
    return leaving
end

mq.imgui.init('VftInv', function() inv.draw() end)
chat.say('Inv', 'Opening')

while inv.isOpen() and not mqLeaving() do
    mq.doevents()
    local ok, err = pcall(function() inv.tick() end)
    if not ok then
        chat.err('Inv', err)
    end
    mq.delay(20)
end

chat.say('Inv', 'Closing')
