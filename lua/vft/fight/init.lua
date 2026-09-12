---@diagnostic disable: undefined-global, undefined-field
-- VF: Combat daemon entry. /lua run vft/fight  (loader: /vf fight). /vfc for state.

local mq = require('mq')
local chat = require('vft.chat')
local fight = require('vft.fight.app')

local function mqLeaving()
    local leaving = false
    pcall(function()
        if mq.exiting then leaving = not not mq.exiting() end
    end)
    return leaving
end

fight.start()

while fight.running() and not mqLeaving() do
    mq.doevents()
    local ok, err = pcall(fight.tick)
    if not ok then
        chat.err('Fight', err)
    end
    mq.delay(math.floor((fight.period() or 0.05) * 1000))
end

fight.shutdown()
chat.say('Fight', 'Closing')
