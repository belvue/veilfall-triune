---@diagnostic disable: undefined-global, undefined-field
-- VF: Veilfall Manager — /lua run vft/mgr

local mq = require('mq')

local App = require('vft.mgr.app')
local IO = require('vft.mgr.io')

local app = App.create({})
app.setOpen(true)

local function mqLeaving()
    local leaving = false
    pcall(function()
        if mq.exiting then leaving = not not mq.exiting() end
    end)
    return leaving
end

-- VF: /vfmgr stays on TA (toggle run/stop). Save is the Manager UI button.
mq.imgui.init('VFManagerUI', function() app.draw() end)

if IO.t2IsRunning() then
    print('\ag[VF Mgr]\ax VF is live — Save writes the loadout file and VF reloads.')
else
    print('\ag[VF Mgr]\ax Manager up. Close window or /lua stop vft/mgr.')
end

while app.isOpen() and not mqLeaving() do
    mq.doevents()
    local ok, err = pcall(function() app.tick() end)
    if not ok then
        print('\ar[VF Mgr]\ax tick error: ' .. tostring(err))
    end
    mq.delay(200)
end
