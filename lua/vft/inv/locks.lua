---@diagnostic disable: undefined-global, undefined-field
-- VF: Per-toon locked bag items — vft/config/{server}_{char}_inventory.ini
-- VF: Keys are item IDs (id=Name). No os.execute from draw.

local mq = require('mq')

local M = {}

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function fileKey(s)
    s = tostring(s or ''):lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    if s == '' then return 'unknown' end
    return s
end

local function serverKey()
    local s = ''
    pcall(function()
        s = tostring(mq.TLO.EverQuest.Server() or '')
        if s == '' or s == 'NULL' then
            s = tostring(mq.TLO.MacroQuest.Server() or '')
        end
    end)
    if s == 'NULL' then s = '' end
    s = fileKey(s)
    if s == 'unknown' then s = 'local' end
    return s
end

local function charKey()
    local n = ''
    pcall(function() n = mq.TLO.Me.CleanName() end)
    n = trim(n)
    if n == '' or n == 'NULL' then
        pcall(function() n = mq.TLO.Me.Name() end)
        n = trim(n)
    end
    return fileKey(n)
end

local function configDir()
    local here = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
    return (here .. '../config'):gsub('\\', '/')
end

function M.path()
    return configDir() .. '/' .. serverKey() .. '_' .. charKey() .. '_inventory.ini'
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

-- VF: Returns locked[id] = name (or ""), plus migrated=true if legacy name keys were resolved.
function M.load()
    local out = {}
    local path = M.path()
    local f = io.open(path, 'r')
    if not f then return out, path, false end
    local sec = ''
    local migrated = false
    for line in f:lines() do
        local hdr = line:match('^%s*%[(.-)%]%s*$')
        if hdr then
            sec = hdr:lower()
        elseif sec == 'locked' then
            local key, val = line:match('^%s*(.-)%s*=%s*(.-)%s*$')
            if key and key ~= '' and not key:match('^%s*;') then
                key, val = trim(key), trim(val)
                local id = tonumber(key)
                if id and id > 0 then
                    if val == '' or val == '1' or val:lower() == 'true' or val:lower() == 'yes' then
                        out[id] = ''
                    else
                        out[id] = val
                    end
                else
                    -- VF: legacy Name=1 → resolve to ID once.
                    local resolved = findIdByName(key)
                    if resolved > 0 then
                        out[resolved] = key
                        migrated = true
                    end
                end
            end
        end
    end
    f:close()
    return out, path, migrated
end

-- VF: Call from tick (not ImGui draw). Writes id=Name lines.
function M.save(locked)
    locked = locked or {}
    local path = M.path()
    local ids = {}
    for id, name in pairs(locked) do
        id = tonumber(id) or 0
        if id > 0 then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local f = io.open(path, 'w')
    if not f then
        return false, path
    end
    f:write('; VF Bags locks by item id\n')
    f:write('[Locked]\n')
    for _, id in ipairs(ids) do
        local name = locked[id]
        if type(name) ~= 'string' or name == '' then name = '1' end
        f:write(tostring(id) .. '=' .. name .. '\n')
    end
    f:close()
    return true, path
end

return M
