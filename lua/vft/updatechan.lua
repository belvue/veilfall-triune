-- VF: overlay channel — machine-wide, not a toon loadout. main | beta.
-- VF: Suite and inv overlays both read this; live files that are not on the branch
-- VF: still get overwritten on Update. Beta Update always overlays (-Force);
-- VF: main still skips when local version >= GitHub.

local mq = require('mq')
local U = require('vft.util')

local M = {}

M.REPO = 'belvue/veilfall-triune'
M.MAIN = 'main'
M.BETA = 'beta'

local cached, cachedAt = nil, -1

function M.path()
    local cfg = ''
    pcall(function() cfg = tostring(mq.configDir or '') end)
    if cfg == '' or cfg == 'NULL' then cfg = '.' end
    return cfg:gsub('/', '\\'):gsub('\\+$', '') .. '\\vf_overlay.lua'
end

function M.normalize(name)
    name = tostring(name or ''):lower():gsub('%s+', '')
    if name == M.BETA then return M.BETA end
    return M.MAIN
end

function M.branch()
    local now = os.clock()
    if cached and (now - (cachedAt or 0)) < 0.25 then return cached end
    local t
    pcall(function()
        local chunk = loadfile(M.path())
        if chunk then t = chunk() end
    end)
    local b = M.MAIN
    if type(t) == 'table' then b = M.normalize(t.branch) end
    cached, cachedAt = b, now
    return b
end

function M.setBranch(name)
    name = M.normalize(name)
    cached, cachedAt = name, os.clock()
    U.writeTable(M.path(), { branch = name }, 'return ')
    return name
end

function M.isBeta()
    return M.branch() == M.BETA
end

function M.cdn(rel)
    return string.format('https://cdn.jsdelivr.net/gh/%s@%s/%s', M.REPO, M.branch(), rel)
end

function M.raw(rel)
    return string.format('https://raw.githubusercontent.com/%s/%s/%s', M.REPO, M.branch(), rel)
end

return M
