---@diagnostic disable: undefined-global, undefined-field
-- VF: Cross-VM control plane. Files, NOT TLOs.
-- VF: mq.AddTopLevelObject registers a C callback that closes over the owning
-- VF: Lua state. /lua stop tears that state down without unregistering, so the
-- VF: next ${...} read from the other VM calls into freed memory and takes the
-- VF: client with it. Confirmed live 2026-09-11: /lua stop vft/fight crashed EQ
-- VF: because the loader polls the daemon every 100ms.
-- VF: Do not reintroduce a TLO for IPC. See docs/COMBAT_DAEMON.md.

local mq = require('mq')

local M = {}

local function path(name)
    return mq.configDir .. '/vf_' .. name .. '.txt'
end

M.path = path

-- VF: tmp + rename, never truncate in place. 'w' empties the live file first, so a
-- VF: reader polling every 100ms could catch it with some keys written and the rest
-- VF: missing -- and a partial read is worse than a missed one, because a dropped
-- VF: 'running' key reads as false and pauses the satellite.
function M.write(name, tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        -- VF: newline would split one value into two keys. None of ours need it.
        out[#out + 1] = k .. '=' .. tostring(tbl[k]):gsub('[\r\n]', ' ')
    end
    local ok = false
    pcall(function()
        local live = path(name)
        local tmp = live .. '.tmp'
        local f = io.open(tmp, 'w')
        if not f then return end
        f:write(table.concat(out, '\n'), '\n')
        f:close()
        -- VF: Windows rename will not clobber, so the live file has to move aside.
        os.remove(live)
        ok = os.rename(tmp, live) and true or false
        if not ok then os.remove(tmp) end
    end)
    return ok
end

-- VF: nil = no file / unreadable / unparseable. Callers keep their last value
-- VF: rather than treating a missed read as "the other side died".
function M.read(name)
    local blob = nil
    pcall(function()
        local f = io.open(path(name), 'r')
        if not f then return end
        blob = f:read('*a')
        f:close()
    end)
    if not blob or blob == '' then return nil end
    local t = {}
    for k, v in blob:gmatch('([%w_]+)=([^\r\n]*)') do t[k] = v end
    if next(t) == nil then return nil end
    return t
end

-- VF: publishing side calls this on shutdown so the reader sees "gone" at once
-- VF: instead of waiting out a staleness timer.
function M.clear(name)
    pcall(function() os.remove(path(name)) end)
end

return M
