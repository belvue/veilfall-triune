-- VF: TA settings I/O.

local mq = require('mq')
local U = require('vft.mgr.util')
local S = require('vft.mgr.schema')

local M = {}

local function cfgDir()
    return mq.configDir or ''
end

local function fileKey(s)
    s = tostring(s or ''):lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    if s == '' then return 'unknown' end
    return s
end

function M.serverKey()
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

function M.charFileName(name)
    return M.serverKey() .. '_' .. fileKey(name) .. '.lua'
end

local function livePath(name)
    return cfgDir() .. '/' .. M.charFileName(name)
end

local function bakPath(name)
    return livePath(name) .. '.bak'
end

local function tmpPath(name)
    return livePath(name) .. '.tmp'
end

function M.liveFile(name)
    name = name or M.charName()
    if not name then return cfgDir() .. '/(no character).lua' end
    return livePath(name)
end

function M.engineIsRunning()
    local running = false
    pcall(function()
        local s = mq.TLO.Lua.Script('ta')
        if (s() ~= nil) and (s.Status() == 'RUNNING') then
            running = true
        end
    end)
    return running
end

function M.t2IsRunning()
    return M.engineIsRunning()
end

function M.charName()
    local nm
    pcall(function() nm = mq.TLO.Me.CleanName() end)
    nm = U.trimName(nm)
    if nm == '' or nm == 'NULL' then return nil end
    return nm
end

function M.isDeadOrCorpse(name)
    local dead = false
    pcall(function() dead = not not mq.TLO.Me.Dead() end)
    if dead then return true end
    name = name or M.charName() or ''
    if name:lower():find("'s corpse$") or name:lower():find('s corpse$') then
        return true
    end
    return false
end

local function loadTable(path)
    local fn = loadfile(path)
    if not fn then return nil end
    local ok, t = pcall(fn)
    if ok and type(t) == 'table' then return t end
    return nil
end

local function unwrapEntry(t, name)
    if type(t) ~= 'table' then return nil end
    if type(t.gems) == 'table' or type(t.aas) == 'table' or type(t.control) == 'table' then
        return S.migrateEntry(t)
    end
    if name and type(t[name]) == 'table' then
        local e = S.migrateEntry(t[name])
        if type(t.__ignore) == 'table' and e.ignore == nil then e.ignore = t.__ignore end
        if type(t.__pullList) == 'table' and e.pull == nil then e.pull = t.__pullList end
        return e
    end
    return S.migrateEntry(t)
end

function M.loadAll()
    local nm = M.charName()
    if not nm then return {}, nil end
    local path = livePath(nm)
    local t = loadTable(path)
    if not t then
        t = loadTable(cfgDir() .. '/t2_loadout.lua') or loadTable(cfgDir() .. '/triune_loadout.lua')
        if t then path = cfgDir() .. '/t2_loadout.lua' end
    end
    if not t then return {}, nil end
    local entry = unwrapEntry(t, nm)
    if type(entry) ~= 'table' then return {}, path end
    return { [nm] = entry }, path
end

local function copyFile(src, dest)
    local inf = io.open(src, 'rb')
    if not inf then return false, 'cannot read ' .. tostring(src) end
    local data = inf:read('*a')
    inf:close()
    if not data or data == '' then return false, 'empty source ' .. tostring(src) end
    local out = io.open(dest, 'wb')
    if not out then return false, 'cannot write ' .. tostring(dest) end
    out:write(data)
    out:close()
    return true
end

local function validateLuaTable(path)
    local fn, err = loadfile(path)
    if not fn then return false, err or 'loadfile failed' end
    local ok, t = pcall(fn)
    if not ok then return false, tostring(t) end
    if type(t) ~= 'table' then return false, 'file did not return a table' end
    return true, t
end

local function replaceLive(tmp, dest)
    local bakTmp = dest .. '.old'
    pcall(os.remove, bakTmp)
    local live = io.open(dest, 'rb')
    if live then
        live:close()
        os.rename(dest, bakTmp)
    end
    local ok, err = os.rename(tmp, dest)
    if not ok then
        local old = io.open(bakTmp, 'rb')
        if old then
            old:close()
            os.rename(bakTmp, dest)
        end
        return false, err or 'rename failed'
    end
    pcall(os.remove, bakTmp)
    return true
end

-- VF: Mutate the logged-in character file.
function M.saveCharacter(allData, charName, entry, session)
    -- VF: Manager may write while TA runs; TA picks up via /vf reloadloadout.
    if not charName or charName == '' then
        return false, 'no character name'
    end
    if M.isDeadOrCorpse(charName) then
        return false, 'refuse write: dead or corpse name (' .. charName .. ')'
    end
    if type(allData) ~= 'table' then
        return false, 'no loadout table'
    end
    if type(allData[charName]) ~= 'table' then
        return false, 'character file is not already loaded: ' .. charName
    end
    if type(entry) ~= 'table' then
        return false, 'empty entry'
    end

    entry = S.migrateEntry(entry)
    local dest = livePath(charName)
    local probe = io.open(dest, 'rb')
    local hasLive = false
    if probe then
        probe:close()
        hasLive = true
    end

    if session and not session.backedUp then
        if hasLive then
            local ok, err = copyFile(dest, bakPath(charName))
            if not ok then return false, 'backup failed: ' .. tostring(err) end
        end
        session.backedUp = true
    elseif not session then
        if hasLive then
            local ok, err = copyFile(dest, bakPath(charName))
            if not ok then return false, 'backup failed: ' .. tostring(err) end
        end
    end

    local tmp = tmpPath(charName)
    local f = io.open(tmp, 'w')
    if not f then return false, 'cannot open temp file' end
    f:write('return ')
    U.serialize(entry, f, 1)
    f:close()

    local ok, errOrTable = validateLuaTable(tmp)
    if not ok then
        pcall(os.remove, tmp)
        return false, 'temp file invalid: ' .. tostring(errOrTable)
    end

    local replaced, rerr = replaceLive(tmp, dest)
    if not replaced then
        pcall(os.remove, tmp)
        return false, 'replace failed: ' .. tostring(rerr)
    end
    -- VF: cache only after the swap landed. Assigning first meant a failed write
    -- VF: left the Manager showing saved values that were never on disk, and the
    -- VF: next reload silently reverted them.
    allData[charName] = entry
    return true, dest
end

function M.routesPath(zone)
    zone = fileKey(zone)
    if zone == 'unknown' then return nil end
    return cfgDir() .. '/' .. zone .. '_routes.lua'
end

function M.loadRouteLib(zone)
    zone = U.trimName(tostring(zone or ''))
    if zone == '' then return S.emptyRouteLib() end
    local path = M.routesPath(zone)
    local t = path and loadTable(path) or nil
    if not t then
        local leftover = loadTable(cfgDir() .. '/' .. M.serverKey() .. '_routes.lua')
        if leftover then
            local all = S.copyRouteLib(leftover)
            local filtered = S.emptyRouteLib()
            local want = zone:lower()
            for _, it in ipairs(all.items) do
                if tostring(it.zone or ''):lower() == want then
                    filtered.items[#filtered.items + 1] = it
                end
            end
            return filtered
        end
    end
    return S.copyRouteLib(t)
end

function M.saveRouteLib(lib, zone)
    zone = U.trimName(tostring(zone or ''))
    local dest = M.routesPath(zone)
    if not dest then return false, 'no zone' end
    lib = S.copyRouteLib(lib)
    for _, it in ipairs(lib.items) do
        it.zone = zone
    end
    local tmp = dest .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return false, 'cannot open ' .. tmp end
    f:write('return ')
    U.serialize(lib, f, 1)
    f:close()
    local ok, errOrTable = validateLuaTable(tmp)
    if not ok then
        pcall(os.remove, tmp)
        return false, 'temp file invalid: ' .. tostring(errOrTable)
    end
    local replaced, rerr = replaceLive(tmp, dest)
    if not replaced then
        pcall(os.remove, tmp)
        return false, 'replace failed: ' .. tostring(rerr)
    end
    return true, dest
end

-- VF: shared non-hostile hubs (all toons). ShortName list.
function M.safeZonesPath()
    return cfgDir() .. '/ta_safe_zones.lua'
end

function M.loadSafeZones()
    local path = M.safeZonesPath()
    local t = loadTable(path)
    if not t then return S.copySafeZones(S.defaultSafeZones()) end
    local list = S.copySafeZones(t)
    if #list == 0 then return S.copySafeZones(S.defaultSafeZones()) end
    return list
end

function M.saveSafeZones(list)
    list = S.copySafeZones(list)
    local dest = M.safeZonesPath()
    local tmp = dest .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return false, 'cannot open ' .. tmp end
    f:write('return ')
    U.serialize({ zones = list }, f, 1)
    f:close()
    local ok, errOrTable = validateLuaTable(tmp)
    if not ok then
        pcall(os.remove, tmp)
        return false, 'temp file invalid: ' .. tostring(errOrTable)
    end
    local replaced, rerr = replaceLive(tmp, dest)
    if not replaced then
        pcall(os.remove, tmp)
        return false, 'replace failed: ' .. tostring(rerr)
    end
    return true, dest
end

return M
