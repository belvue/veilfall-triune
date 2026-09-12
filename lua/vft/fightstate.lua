-- VF: shared mood reader for satellites — TLO only, no engine runtime.
-- VF: no Group.CombatState; walk Present members. docs match enginestate.lua.

local mq = require('mq')

local M = {}

M.GROUP_NEAR = 300

function M.engineState()
    local s = 'UNKNOWN'
    pcall(function() s = tostring(mq.TLO.Me.CombatState() or 'UNKNOWN') end)
    if s == 'NULL' or s == '' then s = 'UNKNOWN' end
    return s
end

function M.meInCombat()
    return M.engineState() == 'COMBAT'
end

local function spawnCombatState(id)
    local cs = ''
    if not id or id <= 0 then return cs end
    pcall(function()
        local s = mq.TLO.Spawn(id)
        if s and s() then cs = tostring(s.CombatState() or '') end
    end)
    return cs
end

local function memberCombatState(m)
    local cs = ''
    pcall(function() cs = tostring(m.CombatState() or '') end)
    if cs == 'COMBAT' then return cs end
    local id = 0
    pcall(function() id = tonumber(m.ID()) or 0 end)
    if id > 0 then
        local via = spawnCombatState(id)
        if via ~= '' then return via end
    end
    return cs
end

-- VF: me COMBAT, or Present group member within GROUP_NEAR with CombatState COMBAT.
function M.fightHot()
    if M.meInCombat() then return true, 'me' end
    local near = tonumber(M.GROUP_NEAR) or 300
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Group.Members()) or 0 end)
    for i = 1, n do
        local hot = false
        pcall(function()
            local m = mq.TLO.Group.Member(i)
            if not m or not m() or not m.Present() then return end
            if (m.Distance3D() or 9999) > near then return end
            if memberCombatState(m) == 'COMBAT' then hot = true end
        end)
        if hot then return true, 'group' end
    end
    return false, nil
end

function M.pctHP()
    local n = 100
    pcall(function() n = tonumber(mq.TLO.Me.PctHPs()) or 100 end)
    return n
end

function M.myId()
    local id = 0
    pcall(function() id = tonumber(mq.TLO.Me.ID()) or 0 end)
    return id
end

function M.dead()
    local d = false
    pcall(function() d = not not mq.TLO.Me.Dead() end)
    return d
end

-- VF: real spell on the bar. Singing is not busy (heal may /stopsong).
function M.barBusy()
    local id, skill = 0, ''
    pcall(function()
        id = tonumber(mq.TLO.Me.Casting.ID()) or 0
        skill = tostring(mq.TLO.Me.Casting.Skill() or '')
    end)
    if id <= 0 then return false end
    return skill ~= 'Singing'
end

function M.singing()
    local id, skill = 0, ''
    pcall(function()
        id = tonumber(mq.TLO.Me.Casting.ID()) or 0
        skill = tostring(mq.TLO.Me.Casting.Skill() or '')
    end)
    return id > 0 and skill == 'Singing'
end

return M
