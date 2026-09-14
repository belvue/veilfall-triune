---@diagnostic disable: undefined-global, undefined-field
-- VF: Inventory loop. /lua run vfi (seed) or /lua run vft/inv (suite overlay copies this tree).

local mq = require('mq')
local chat = require('vft.chat')

local M = {}

function M.run()
    local inv = require('vft.inv.app').create({ hosted = false })

    local function mqLeaving()
        local leaving = false
        pcall(function()
            if mq.exiting then leaving = not not mq.exiting() end
        end)
        return leaving
    end

    local function vfRunning()
        local found = false
        pcall(function()
            local pids = tostring(mq.TLO.Lua.PIDs() or '')
            for tok in pids:gmatch('%d+') do
                local pid = tonumber(tok)
                local s = pid and mq.TLO.Lua.Script(pid) or nil
                if s then
                    local st, sn = '', ''
                    pcall(function() st = tostring(s.Status() or '') end)
                    if st == 'RUNNING' or st == 'PAUSED' then
                        pcall(function() sn = tostring(s.Name() or ''):gsub('\\', '/'):lower() end)
                        if sn == 'vf' then found = true; return end
                    end
                end
            end
        end)
        return found
    end

    -- VF: With VF, bag opens the full window. Alone, overlay stays up.
    local withVf = vfRunning()
    inv.setOpen(withVf)

    mq.imgui.init('VftInv', function()
        if not withVf then inv.drawHud() end
        inv.draw()
    end)
    pcall(function() mq.unbind('/vfi') end)
    mq.bind('/vfi', function() inv.toggle() end)
    if not withVf then
        pcall(function() mq.unbind('/vfinv') end)
        mq.bind('/vfinv', function() inv.toggle() end)
    end
    chat.say('Inv', withVf and 'Opening' or 'Overlay')

    while not mqLeaving() and ((not withVf) or inv.isOpen()) do
        mq.doevents()
        local ok, err = pcall(function() inv.tick() end)
        if not ok then
            chat.err('Inv', err)
        end
        mq.delay(20)
    end

    chat.say('Inv', 'Closing')
    pcall(function() mq.unbind('/vfi') end)
    if not withVf then
        pcall(function() mq.unbind('/vfinv') end)
    end
end

return M
