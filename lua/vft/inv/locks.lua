---@diagnostic disable: undefined-global, undefined-field
-- VF: Per-toon locked bag items — [Locked] in vft/config/{server}_{char}_loadout.ini

local mq = require('mq')
local store = require('vft.toonini')

local M = {}

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function findIdByName(name)
    name = trim(name)
    if name == '' then return 0 end
    local id = 0
    pcall(function()
        local fi = mq.TLO.FindItem('=' .. name)
        if fi and fi() then id = tonumber(fi.ID()) or 0 end
    end)
    if id <= 0 then
        pcall(function()
            local fi = mq.TLO.FindItem(name)
            if fi and fi() then id = tonumber(fi.ID()) or 0 end
        end)
    end
    return id
end

function M.path()
    return store.path()
end

-- VF: Returns locked[id] = name (or ""), plus migrated=true if leftover name keys were resolved.
function M.load()
    local data, path, migrated = store.load()
    local out = {}
    local extra = false
    for key, val in pairs(data.locked or {}) do
        local id = tonumber(key)
        if id and id > 0 then
            out[id] = val
        else
            local resolved = findIdByName(tostring(key))
            if resolved > 0 then
                out[resolved] = tostring(key)
                extra = true
            end
        end
    end
    if extra then
        store.update(function(fresh)
            fresh.locked = out
        end)
        migrated = true
    end
    return out, path, migrated
end

function M.save(locked)
    locked = locked or {}
    local clean = {}
    for id, name in pairs(locked) do
        id = tonumber(id) or 0
        if id > 0 then clean[id] = name end
    end
    return store.update(function(data)
        data.locked = clean
    end)
end

function M.lockItem(id, name)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    local map = M.load()
    map[id] = trim(name)
    return M.save(map)
end

return M
