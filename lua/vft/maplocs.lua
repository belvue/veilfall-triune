-- VF: /maploc X's for route pins. Label is N:Kind. Shared by engine + waypoints VM.

local mq = require('mq')

local M = {}

local COLORS = {
    loop   = { 196, 160, 70 },
    guide  = { 181, 107, 255 },
    travel = { 80, 180, 220 },
}

local lastSig = ''
local PIN_LAYER = 1

-- VF: /maploc has no layer option; X's take MQ2Map ActiveLayer (default 2).
local function mqMapActiveLayer()
    local dir = mq.configDir
    if not dir or dir == '' then return nil end
    local f = io.open(dir .. '/MQ2Map.ini', 'r')
    if not f then return nil end
    local inFilters, layer = false, nil
    for line in f:lines() do
        if line:match('^%[') then
            inFilters = line:match('^%[Map Filters%]') ~= nil
        elseif inFilters then
            local v = line:match('^ActiveLayer%s*=%s*(%d+)')
            if v then
                layer = tonumber(v)
                break
            end
        end
    end
    f:close()
    return layer
end

local function pinToLayer1()
    if mqMapActiveLayer() == PIN_LAYER then return end
    pcall(function() mq.cmdf('/squelch /mapactivelayer %d', PIN_LAYER) end)
end

local function kindOf(loc)
    local k = loc and tostring(loc.kind or loc.wp or ''):lower() or ''
    if k == 'travel' or k == 'guide' then return k end
    return 'loop'
end

local function kindLabel(k)
    if k == 'travel' then return 'Travel' end
    if k == 'guide' then return 'Guide' end
    return 'Loop'
end

function M.sig(locs, zone)
    local parts = { tostring(zone or '') }
    if type(locs) ~= 'table' then return table.concat(parts, '|') end
    for i = 1, #locs do
        local loc = locs[i]
        if type(loc) == 'table' then
            parts[#parts + 1] = string.format('%d:%s:%.1f:%.1f:%s',
                i, kindOf(loc), tonumber(loc.x) or 0, tonumber(loc.y) or 0,
                loc.z ~= nil and string.format('%.1f', loc.z) or '-')
        end
    end
    return table.concat(parts, '|')
end

function M.clear()
    pcall(function() mq.cmd('/squelch /maploc remove') end)
    lastSig = ''
end

-- VF: wipe and re-drop. /maploc remove is all-or-nothing; our pins are the maplocs.
function M.paint(locs, zone)
    local sig = M.sig(locs, zone)
    if sig == lastSig then return end
    lastSig = sig
    pinToLayer1()
    pcall(function() mq.cmd('/squelch /maploc remove') end)
    if type(locs) ~= 'table' then return end
    for i = 1, #locs do
        local loc = locs[i]
        if type(loc) == 'table' then
            local k = kindOf(loc)
            local c = COLORS[k] or COLORS.loop
            local label = string.format('%d:%s', i, kindLabel(k))
            local y = tonumber(loc.y) or 0
            local x = tonumber(loc.x) or 0
            pcall(function()
                if loc.z ~= nil then
                    mq.cmdf(
                        '/squelch /maploc %.1f %.1f %.1f size 28 width 3 color %d %d %d label %s',
                        y, x, tonumber(loc.z) or 0, c[1], c[2], c[3], label)
                else
                    mq.cmdf(
                        '/squelch /maploc %.1f %.1f size 28 width 3 color %d %d %d label %s',
                        y, x, c[1], c[2], c[3], label)
                end
            end)
        end
    end
end

return M
