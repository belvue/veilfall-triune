---@diagnostic disable: undefined-global, undefined-field
-- VF: Per-toon store — vft/config/{server}_{char}_loadout.ini (locks + powersource + items).

local mq = require('mq')

local M = {}

local cached
local cachePath

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
    return (here .. 'config'):gsub('\\', '/')
end

function M.path()
    return configDir() .. '/' .. serverKey() .. '_' .. charKey() .. '_loadout.ini'
end

function M.legacyInventoryPath()
    return configDir() .. '/' .. serverKey() .. '_' .. charKey() .. '_inventory.ini'
end

function M.legacyPowerPath()
    return configDir() .. '/' .. serverKey() .. '_' .. charKey() .. '_powersource.ini'
end

local function empty()
    return { locked = {}, powersource = {}, items = {} }
end

local function itemKey(name)
    name = trim(name)
    if name == '' then return '' end
    return name:lower()
end

local function parseLockedVal(key, val, out)
    key, val = trim(key), trim(val)
    local id = tonumber(key)
    if id and id > 0 then
        if val == '' or val == '1' or val:lower() == 'true' or val:lower() == 'yes' then
            out[id] = ''
        else
            out[id] = val
        end
        return
    end
    -- VF: leftover Name=1 keys stay as name-only until inv migrates them.
    if key ~= '' then out[key] = val end
end

local function parseIniFull(path)
    local data = empty()
    local f = io.open(path, 'r')
    if not f then return data, false end
    local sec = ''
    local curItem
    local function finishItem()
        if not curItem then return end
        local name = trim(curItem.name or '')
        if name == '' then
            local secName = tostring(curItem._sec or '')
            name = secName:match('^item%.(.+)$') or secName:match('^item:(.+)$') or ''
            if name:sub(1, 5) == 'name.' then name = name:sub(6) end
            name = name:gsub('_', ' ')
        end
        name = trim(name)
        if name ~= '' and name ~= 'NULL' then
            curItem.name = name
            local secId = tostring(curItem._sec or ''):match('^item%.(%d+)$')
            if not tonumber(curItem.id) and secId then curItem.id = secId end
            -- VF: disk keys are before/after; writers also use cmd_*.
            if (not curItem.cmd_before or curItem.cmd_before == '') and curItem.before then
                curItem.cmd_before = curItem.before
            end
            if (not curItem.cmd_after or curItem.cmd_after == '') and curItem.after then
                curItem.cmd_after = curItem.after
            end
            data.items[itemKey(name)] = curItem
        end
        curItem = nil
    end
    for line in f:lines() do
        local hdr = line:match('^%s*%[(.-)%]%s*$')
        if hdr then
            finishItem()
            sec = trim(hdr)
            local sl = sec:lower()
            if sl:sub(1, 5) == 'item.' or sl:sub(1, 5) == 'item:' then
                curItem = { _sec = sl }
            end
        else
            local key, val = line:match('^%s*([^;=%s][^=]-)%s*=%s*(.-)%s*$')
            if key then
                key, val = trim(key), trim(val)
                local sl = sec:lower()
                if sl == 'locked' then
                    parseLockedVal(key, val, data.locked)
                elseif sl == 'powersource' then
                    data.powersource[key] = val
                elseif curItem then
                    curItem[key] = val
                end
            end
        end
    end
    finishItem()
    f:close()
    return data, true
end

local function readLegacyInventory(path, locked)
    local f = io.open(path, 'r')
    if not f then return false end
    local sec = ''
    local any = false
    for line in f:lines() do
        local hdr = line:match('^%s*%[(.-)%]%s*$')
        if hdr then
            sec = trim(hdr):lower()
        elseif sec == 'locked' then
            local key, val = line:match('^%s*(.-)%s*=%s*(.-)%s*$')
            if key and key ~= '' and not key:match('^%s*;') then
                parseLockedVal(key, val, locked)
                any = true
            end
        end
    end
    f:close()
    return any
end

local function readLegacyPower(path, ps)
    local f = io.open(path, 'r')
    if not f then return false end
    local any = false
    for line in f:lines() do
        local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
        if k then
            ps[k] = v
            any = true
        end
    end
    f:close()
    return any
end

local function writeBool(v)
    if v == true or v == '1' or v == 1 or tostring(v):lower() == 'true' then return '1' end
    return '0'
end

-- VF: write to .tmp and swap, never truncate the live file -- a crash mid-write
-- VF: used to lose every inventory lock. Done inline, NOT via vft.util: this file
-- VF: is in the standalone inventory subset and must keep requiring only mq.
local function writeIni(path, data)
    data = data or empty()
    local tmp = path .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return false end
    f:write('; VF toon store — locks, powersource, item clickies\n')
    f:write('[Locked]\n')
    local ids = {}
    for id, name in pairs(data.locked or {}) do
        local n = tonumber(id)
        if n and n > 0 then
            ids[#ids + 1] = n
        end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local name = data.locked[id]
        if type(name) ~= 'string' or name == '' then name = '1' end
        f:write(tostring(id) .. '=' .. name .. '\n')
    end
    f:write('\n[powersource]\n')
    local ps = data.powersource or {}
    if ps.pct ~= nil then f:write('pct=' .. tostring(ps.pct) .. '\n') end
    if ps.name ~= nil then f:write('name=' .. tostring(ps.name) .. '\n') end
    if ps.id ~= nil then f:write('id=' .. tostring(ps.id) .. '\n') end
    if ps.source ~= nil then f:write('source=' .. tostring(ps.source) .. '\n') end

    local items = {}
    for _, rec in pairs(data.items or {}) do
        if type(rec) == 'table' and trim(rec.name or '') ~= '' then
            items[#items + 1] = rec
        end
    end
    table.sort(items, function(a, b)
        return tostring(a.name or '') < tostring(b.name or '')
    end)
    for _, rec in ipairs(items) do
        local id = tonumber(rec.id or rec.item_id) or 0
        local sec
        if id > 0 then
            sec = 'item.' .. tostring(id)
        else
            sec = 'item.name.' .. fileKey(rec.name)
        end
        f:write('\n[' .. sec .. ']\n')
        f:write('name=' .. tostring(rec.name) .. '\n')
        if id > 0 then f:write('id=' .. tostring(id) .. '\n') end
        f:write('enabled=' .. writeBool(rec.enabled) .. '\n')
        f:write('burn=' .. writeBool(rec.burn) .. '\n')
        f:write('type=' .. tostring(rec.type or '') .. '\n')
        f:write('combat=' .. tostring(rec.combat or '') .. '\n')
        f:write('spell=' .. tostring(rec.spell or '') .. '\n')
        f:write('effect_type=' .. tostring(rec.effect_type or '') .. '\n')
        f:write('keep_buff=' .. tostring(rec.keep_buff or '') .. '\n')
        f:write('level_min=' .. tostring(rec.level_min or '') .. '\n')
        f:write('level_max=' .. tostring(rec.level_max or '') .. '\n')
        f:write('mobs=' .. tostring(rec.mobs or '') .. '\n')
        f:write('hp_min=' .. tostring(rec.hp_min or '') .. '\n')
        local hpMax = rec.hp_max
        if hpMax == nil then hpMax = '' end
        f:write('hp_max=' .. tostring(hpMax) .. '\n')
        local before = rec.cmd_before or rec.before or ''
        local after = rec.cmd_after or rec.after or ''
        f:write('before=' .. tostring(before) .. '\n')
        f:write('after=' .. tostring(after) .. '\n')
    end
    f:close()
    local old = path .. '.old'
    pcall(os.remove, old)
    local live = io.open(path, 'rb')
    if live then
        live:close()
        -- VF: Windows rename will not clobber, so move the live file aside first.
        os.rename(path, old)
    end
    if not os.rename(tmp, path) then
        local back = io.open(old, 'rb')
        if back then
            back:close()
            os.rename(old, path)
        end
        return false
    end
    pcall(os.remove, old)
    return true
end

function M.load()
    local path = M.path()
    local data, existed = parseIniFull(path)
    local migrated = false
    if not existed then
        if readLegacyInventory(M.legacyInventoryPath(), data.locked) then migrated = true end
        if readLegacyPower(M.legacyPowerPath(), data.powersource) then migrated = true end
        if migrated then
            writeIni(path, data)
        end
    else
        -- VF: first loadout write may predate locks; pull leftover inventory.ini once.
        local n = 0
        for _ in pairs(data.locked) do n = n + 1 end
        if n == 0 and readLegacyInventory(M.legacyInventoryPath(), data.locked) then
            migrated = true
            writeIni(path, data)
        end
        if (data.powersource.pct == nil) and readLegacyPower(M.legacyPowerPath(), data.powersource) then
            migrated = true
            writeIni(path, data)
        end
    end
    cached = data
    cachePath = path
    return data, path, migrated
end

function M.data()
    if not cached then M.load() end
    return cached
end

-- VF: inv / mgr / engine are separate Lua states — re-read before every write.
function M.update(mutator)
    local path = M.path()
    local data = parseIniFull(path)
    if mutator then mutator(data) end
    local ok = writeIni(path, data)
    if ok then
        cached = data
        cachePath = path
    end
    return ok, path
end

function M.save(data)
    if type(data) ~= 'table' then
        return M.update(nil)
    end
    return M.update(function(fresh)
        if data.locked then fresh.locked = data.locked end
        if data.powersource then fresh.powersource = data.powersource end
        if data.items then fresh.items = data.items end
    end)
end

function M.item(name)
    local data = M.data()
    local key = itemKey(name)
    if key == '' then return nil end
    return data.items[key]
end

function M.setItem(name, rec)
    local key = itemKey(name)
    if key == '' then return false end
    rec = rec or {}
    rec.name = rec.name or name
    return M.update(function(data)
        data.items[key] = rec
    end)
end

function M.setItems(items)
    local nextItems = {}
    if type(items) == 'table' then
        for name, rec in pairs(items) do
            if type(rec) == 'table' then
                rec.name = rec.name or name
                local key = itemKey(rec.name)
                if key ~= '' then nextItems[key] = rec end
            end
        end
    end
    return M.update(function(data)
        data.items = nextItems
    end)
end

-- VF: fold a manager/engine item entry into the INI record shape.
function M.recFromEntry(name, entry)
    if type(entry) ~= 'table' then return nil end
    name = trim(name or entry.name or '')
    if name == '' then return nil end
    local mobs = tostring(entry.mobs_expr or '')
    if mobs == '' then
        if entry.max_xtargets ~= nil then
            mobs = '<=' .. tostring(entry.max_xtargets)
        elseif entry.min_xtar ~= nil and tonumber(entry.min_xtar) and (entry.min_xtar == 0 or entry.min_xtar > 1) then
            mobs = '>=' .. tostring(entry.min_xtar)
        end
    end
    return {
        name = name,
        id = tonumber(entry.item_id) or 0,
        enabled = entry.enabled == true,
        burn = entry.burn_only == true,
        type = entry.cast_type or '',
        combat = entry.combat or '',
        spell = entry.spell or '',
        effect_type = entry.effect_type or '',
        level_min = entry.min_level,
        level_max = entry.max_level,
        mobs = mobs,
        hp_min = entry.above,
        hp_max = entry.pct,
        cmd_before = entry.cmd_before or '',
        cmd_after = entry.cmd_after or '',
        keep_buff = entry.keep_buff or '',
    }
end

return M
