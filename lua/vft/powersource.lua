---@diagnostic disable: undefined-global, undefined-field
-- VF: Triune Power Source growth %. Server keeps Exp on the item instance (custom "Exp" 0-100).
-- VF: MQ2Lua cannot call GetCustomData; we probe Evolving/Power TLOs, then INI cache, then chat lines.

local mq = require('mq')
local store = require('vft.toonini')

local M = {}

local state = {
    pct = nil,
    name = nil,
    id = 0,
    source = nil,
    eventsOn = false,
}

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.path()
    return store.path()
end

local function slotItem()
    local item
    pcall(function()
        local slot = mq.TLO.Me.Inventory('PowerSource')
        if slot and slot() then item = slot end
    end)
    return item
end

local function readSlotMeta(item)
    local name, id, icon = '', 0, 0
    if not item then return name, id, icon end
    pcall(function() name = trim(item.Name() or '') end)
    pcall(function() id = tonumber(item.ID()) or 0 end)
    pcall(function() icon = tonumber(item.Icon()) or 0 end)
    if name == 'NULL' then name = '' end
    return name, id, icon
end

-- VF: Best-effort live read. Prefer any TLO that might carry instance Exp.
local function probeLive(item)
    if not item then return nil, nil end
    local pct

    -- VF: Some forks may expose custom data on the item TLO.
    pcall(function()
        local v = item.CustomData and item.CustomData('Exp')
        if v then
            local s = tostring(v() or v)
            pct = tonumber(s:match('([%d%.]+)'))
        end
    end)
    if pct then return pct, 'custom' end

    pcall(function()
        local evo = tonumber(item.Evolving.ExpPct())
        if evo and evo >= 0 then pct = evo end
    end)
    if pct then return pct, 'evolving' end

    pcall(function()
        local power = tonumber(item.Power())
        local maxp = tonumber(item.MaxPower())
        if power and maxp and maxp > 0 then
            pct = (power / maxp) * 100.0
        end
    end)
    if pct then return pct, 'power' end

    return nil, nil
end

function M.load()
    local data = store.load()
    local ps = data.powersource or {}
    local pct = tonumber(ps.pct)
    if pct == nil then return false end
    state.pct = pct
    if ps.name and ps.name ~= '' then state.name = ps.name end
    local id = tonumber(ps.id) or 0
    if id > 0 then state.id = id end
    state.source = ps.source or 'ini'
    return true
end

-- VF: mkdir unavailable; same as locks — write fails until vft/config exists.
function M.save()
    if state.pct == nil then return false end
    local ok = store.update(function(data)
        data.powersource = {
            pct = tostring(state.pct),
            name = tostring(state.name or ''),
            id = tostring(tonumber(state.id) or 0),
            source = tostring(state.source or 'cache'),
        }
    end)
    return ok and true or false
end

function M.set(pct, name, id, source)
    pct = tonumber(pct)
    if not pct then return end
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    -- VF: only write when a persisted field actually moved. refresh() is called from
    -- VF: the render path, so saving unconditionally meant a toon-store write every
    -- VF: frame the slot had a live value.
    local changed = (state.pct ~= pct)
    state.pct = pct
    if name and name ~= '' and state.name ~= name then
        state.name = name
        changed = true
    end
    if id and id > 0 and state.id ~= id then
        state.id = id
        changed = true
    end
    state.source = source or state.source or 'set'
    if changed then M.save() end
end

function M.onChatLine(line, pctTok)
    line = tostring(line or '')
    local n = tonumber(tostring(pctTok or ''):match('([%d%.]+)'))
    if not n then
        n = tonumber(line:match('(%d+%.%d+)%%')) or tonumber(line:match('(%d+)%%'))
    end
    if not n then return end
    local name = line:match('%[([^%]]+)%]')
    if not name or name == '' then
        name = line:match('Your%s+(.-)%s+absorbs energy')
    end
    if name and name ~= '' then
        name = name:gsub('\018', ''):gsub('^%x%x%x%x+', ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    local id = 0
    local item = slotItem()
    local slotName, slotId = readSlotMeta(item)
    if slotId > 0 then id = slotId end
    if (not name or name == '') and slotName ~= '' then name = slotName end
    M.set(n, name, id, 'log')
end

function M.refresh()
    local item = slotItem()
    local name, id, icon = readSlotMeta(item)
    if name ~= '' then state.name = name end
    if id > 0 then state.id = id end

    local live, src = probeLive(item)
    if live ~= nil then
        M.set(live, name, id, src)
    elseif state.pct == nil then
        M.load()
    end

    return {
        pct = state.pct,
        name = state.name,
        id = state.id,
        icon = icon,
        source = state.source,
        empty = (name == '' and not item),
    }
end

function M.pct()
    M.refresh()
    return state.pct
end

function M.pctText()
    local info = M.refresh()
    if info.pct ~= nil then
        return string.format('%d%%', math.floor(info.pct + 0.5))
    end
    return '--'
end

function M.info()
    return M.refresh()
end

function M.tierColor()
    local name = tostring(state.name or ''):lower()
    if name:find('legendary', 1, true) then return { 0.95, 0.72, 0.28, 1 } end
    if name:find('enchanted', 1, true) then return { 0.55, 0.72, 1.0, 1 } end
    if name ~= '' then return { 0.37, 0.88, 0.64, 1 } end
    return { 0.541, 0.439, 0.533, 1 }
end

function M.installEvents(tag)
    if state.eventsOn then return end
    state.eventsOn = true
    tag = tostring(tag or 'VftPs')
    pcall(function() mq.unevent(tag .. 'Grow') end)
    pcall(function() mq.unevent(tag .. 'Grow2') end)
    mq.event(tag .. 'Grow', '#*#absorbs energy#*#', function(line, a, b)
        M.onChatLine(line, a or b)
    end)
    mq.event(tag .. 'Grow2', '#*#faint shimmer#*#', function(line, a, b)
        M.onChatLine(line, a or b)
    end)
end

-- VF: boot cache so loader/inv show last known Exp before the next kill line.
M.load()

return M
