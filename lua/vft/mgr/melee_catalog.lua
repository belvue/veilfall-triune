-- VF: boolean MQ2Melee ability keys for Loadout Abilities tab.
-- VF: MQ2Melee-owned — TA never /doability them (see MELEE_OFFLOAD).

local mq = require('mq')

local M = {}

-- VF: Me.Skill is non-zero for latent multiclass skills you do not own (Backstab etc).
-- VF: Me.Ability(name) is the /doability slot — same ownership probe as the Abilities tab.
local function abilityOwned(name)
    local v
    pcall(function() v = mq.TLO.Me.Ability(name)() end)
    if v == nil or v == false then return false end
    if type(v) == 'number' then return v > 0 end
    if type(v) == 'boolean' then return v == true end
    if type(v) == 'string' then
        return v ~= '' and v ~= 'NULL'
    end
    return false
end

local function aaOn(name)
    local hit = false
    pcall(function()
        local aa = mq.TLO.Me.AltAbility(name)
        hit = not not (aa and aa() and (tonumber(aa.Rank()) or 0) > 0)
    end)
    return hit
end

local function raceSlam()
    -- VF: barbarian=2 troll=9 ogre=10 (MQ2Melee slam show).
    local id = 0
    pcall(function() id = tonumber(mq.TLO.Me.Race.ID()) or 0 end)
    return id == 2 or id == 9 or id == 10
end

-- VF: boolean abilities only — no stick/policy, no % thresholds (mend/layhand/stunning/…).
-- VF: battleleap / callchallenge stay here (MQ2Melee boolean AAs); only when Rank > 0.
M.ABILITIES = {
    { key = 'kick', label = 'Kick', help = '[ON/OFF]?', have = function() return abilityOwned('Kick') end },
    { key = 'bash', label = 'Bash', help = '[ON/OFF]?', have = function() return abilityOwned('Bash') end },
    { key = 'slam', label = 'Slam', help = '[ON/OFF]?', have = raceSlam },
    { key = 'disarm', label = 'Disarm', help = '[ON/OFF]?', have = function() return abilityOwned('Disarm') end },
    { key = 'taunt', label = 'Taunt', help = '[ON/OFF]?', have = function() return abilityOwned('Taunt') end },
    { key = 'frenzy', label = 'Frenzy', help = '[ON/OFF]?', have = function() return abilityOwned('Frenzy') end },
    { key = 'backstab', label = 'Backstab', help = '[ON/OFF]?', have = function() return abilityOwned('Backstab') end },
    { key = 'dragonpunch', label = 'Dragon Punch', help = '[ON/OFF]?', have = function() return abilityOwned('Dragon Punch') end },
    { key = 'eaglestrike', label = 'Eagle Strike', help = '[ON/OFF]?', have = function() return abilityOwned('Eagle Strike') end },
    { key = 'flyingkick', label = 'Flying Kick', help = '[ON/OFF]?', have = function() return abilityOwned('Flying Kick') end },
    { key = 'roundkick', label = 'Round Kick', help = '[ON/OFF]?', have = function() return abilityOwned('Round Kick') end },
    { key = 'tigerclaw', label = 'Tiger Claw', help = '[ON/OFF]?', have = function() return abilityOwned('Tiger Claw') end },
    { key = 'pickpocket', label = 'Pick Pockets', help = '[ON/OFF]?', have = function() return abilityOwned('Pick Pockets') end },
    { key = 'sneak', label = 'Sneak', help = '[ON/OFF]?', have = function() return abilityOwned('Sneak') end },
    { key = 'hide', label = 'Hide', help = '[ON/OFF]?', have = function() return abilityOwned('Hide') end },
    { key = 'forage', label = 'Forage', help = '[ON/OFF]?', have = function() return abilityOwned('Forage') end },
    { key = 'begging', label = 'Begging', help = '[ON/OFF]?', have = function() return abilityOwned('Begging') end },
    { key = 'sensetraps', label = 'Sense Traps', help = '[ON/OFF]?', have = function() return abilityOwned('Sense Traps') end },
    { key = 'intimidation', label = 'Intimidation', help = '[ON/OFF]?', have = function() return abilityOwned('Intimidation') end },
    { key = 'battleleap', label = 'Battle Leap', help = 'AA [ON/OFF]?', have = function() return aaOn('Battle Leap') end },
    { key = 'callchallenge', label = 'Call of Challenge', help = 'AA [ON/OFF]?', have = function() return aaOn('call of challenge') end },
}

-- VF: ooc/utility — Standing gate; combat skills — Me.Combat. Never leave if= empty when on.
-- VF: Ready() Evaluate() is atoi(ParseMacroData) — bare ${Me.Combat} expands TRUE/FALSE → atoi 0
-- VF: always aborts (0x15). Must be ${If[...,1,0]}. MQ2Melee.cpp:2147,2628.
local OOC_GATE = {
    forage = true, begging = true, sneak = true, hide = true, sensetraps = true,
}

local byLabel = {}
for _, row in ipairs(M.ABILITIES) do
    byLabel[string.lower(row.label)] = row.key
end

function M.isOn(v)
    return v == true or v == 1 or v == '1' or v == 'on'
end

function M.keyForName(name)
    name = tostring(name or ''):match('^%s*(.-)%s*$') or ''
    if name == '' then return nil end
    return byLabel[string.lower(name)]
end

-- VF: catalog membership = MQ2Melee owns the press; TA must not /doability or fireAA it.
function M.isDelegated(name)
    return M.keyForName(name) ~= nil
end

-- VF: if= stays the on-gate even when toggle is 0 — /melee key=0|1 is enough to flip;
-- VF: empty if= is no gate, so never write blank (MELEE_OFFLOAD).
function M.gateExpr(key)
    if OOC_GATE[key] then return '${If[${Me.Standing},1,0]}' end
    return '${If[${Me.Combat},1,0]}'
end

-- VF: live plugin state — source of truth for the Melee tab (not char loadout).
function M.readLivePrefs()
    local out = {}
    for _, row in ipairs(M.ABILITIES) do
        out[row.key] = M.readLive(row.key) > 0 and 1 or 0
    end
    return out
end

-- VF: toggle from prefs/meleemvi; if= always the standing/combat gate.
function M.applyPrefs(rails, prefs)
    if type(rails) ~= 'table' then return end
    prefs = prefs or {}
    for _, row in ipairs(M.ABILITIES) do
        local on = M.isOn(prefs[row.key])
        rails[row.key] = on and '1' or '0'
        rails[row.key .. 'if'] = M.gateExpr(row.key)
    end
end

function M.ifKeys()
    local keys = {}
    for _, row in ipairs(M.ABILITIES) do
        keys[#keys + 1] = row.key .. 'if'
    end
    return keys
end

-- VF: seed missing owned keys from live meleemvi so the tab starts honest.
function M.seedPrefs(src)
    local out = M.copyAbilities(src)
    for _, row in ipairs(M.ABILITIES) do
        if out[row.key] == nil then
            local ok = false
            pcall(function() ok = not not row.have() end)
            if ok then
                out[row.key] = M.readLive(row.key) > 0 and 1 or 0
            end
        end
    end
    return out
end

function M.copyAbilities(src)
    local out = {}
    if type(src) ~= 'table' then return out end
    for _, row in ipairs(M.ABILITIES) do
        local v = src[row.key]
        if v == true or v == 1 or v == '1' or v == 'on' then
            out[row.key] = 1
        elseif v == false or v == 0 or v == '0' or v == 'off' then
            out[row.key] = 0
        end
    end
    return out
end

function M.readLive(key)
    local n = 0
    pcall(function() n = tonumber(mq.TLO.meleemvi(key)()) or 0 end)
    return n
end

function M.visibleRows(prefs)
    prefs = prefs or {}
    local rows = {}
    for _, row in ipairs(M.ABILITIES) do
        local ok = false
        pcall(function() ok = not not row.have() end)
        if ok then
            local on = prefs[row.key]
            if on == nil then
                on = M.readLive(row.key) > 0 and 1 or 0
            else
                on = (on == true or on == 1 or on == '1') and 1 or 0
            end
            rows[#rows + 1] = {
                key = row.key,
                label = row.label,
                help = row.help,
                on = on == 1,
                live = M.readLive(row.key),
            }
        end
    end
    return rows
end

function M.keys()
    local keys = {}
    for _, row in ipairs(M.ABILITIES) do
        keys[#keys + 1] = row.key
    end
    return keys
end

return M
