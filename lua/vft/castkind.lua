-- VF: cast_type → role for combat rotate. docs/COMBAT_TICK_IDEAL.md Gate 1.
-- VF: Settings write cast_type; this is what the engine should honor.

local U = require('vft.util')

local M = {}

local TYPE_ALIASES = {
    Pet = 'Summon',
    Util = 'Buff',
    Port = 'Buff',
    Threat = 'Melee',
    AoE = 'Nuke',
    Rain = 'Nuke',
    Mez = 'CC',
    Defensive = 'Panic',
}

local ROLES = {
    Melee = true, Nuke = true, DoT = true, Debuff = true, CC = true,
    Heal = true, HoT = true, Cure = true, Panic = true, Tap = true,
    Buff = true, Summon = true, PetHeal = true, PetBuff = true,
}

-- VF: HoT is a heal: my HP% + missing on buff/short. Tap = heal priority, nuke cast. docs/COMBAT_TICK_IDEAL.md
local SURVIVAL = { Panic = true, Heal = true, Tap = true, HoT = true, Cure = true }

-- VF: lower = more urgent. nil = combat rotation (never preempts). Leave gaps to grow.
-- VF: Panic 0 · Heal 4 · HoT/Tap 5 · Cure 6 · OOC cold 9.
local CAST_PRIORITY = {
    Panic = 0,
    Heal = 4,
    HoT = 5,
    Tap = 5,
    Cure = 6,
    Buff = 9,
    PetBuff = 9,
    Summon = 9,
}
-- VF: Gate 6 — Buff/PetBuff/Summon; hot only when Combat col In Combat|Always.
local COLD = { Buff = true, PetBuff = true, Summon = true }
-- VF: DoT and Debuff share the same on-mob effect gate (Gate 5 snapshot).
local MOB_EFFECT = { DoT = true, Debuff = true }

local function normalize(typ)
    if not typ or typ == '' then return nil end
    typ = TYPE_ALIASES[typ] or typ
    if ROLES[typ] then return typ end
    return nil
end

-- VF: Infer when cast_type missing (old rows). Prefer stored type.
local function inferRole(entry)
    if not entry then return 'Nuke' end
    local when = entry.when or ''
    local tgt = tostring(entry.target or '')
    if tgt:find('Unmezzed', 1, true) then return 'CC' end
    if when == 'has Poison/Disease' then return 'Cure' end
    if when == 'missing pet' then return 'Summon' end
    if when == 'missing buff' then
        if tgt:find('Pet', 1, true) then return 'PetBuff' end
        return 'Buff'
    end
    if when == 'my HP <=' then return 'Heal' end
    if when == 'HP <=' and tgt:find('Pet', 1, true) then return 'PetHeal' end
    if when == 'in combat' or when == 'twist while fighting' then return 'Melee' end
    local tok = U.baseTok and U.baseTok(tgt) or tgt
    if when == 'always' and (tok == 'Myself' or tok == 'Self') then return 'Buff' end
    if entry.kind == 'heal' then return 'Heal' end
    if entry.kind == 'buff' then return 'Buff' end
    if entry.kind == 'dot' then return 'DoT' end
    if entry.kind == 'debuff' then return 'Debuff' end
    if entry.kind == 'pet' then return 'Summon' end
    return 'Nuke'
end

function M.role(entry)
    if not entry then return 'Nuke' end
    local stored = normalize(entry.cast_type or entry.t3_type)
    if stored then return stored end
    return inferRole(entry)
end

function M.isSurvival(role)
    return SURVIVAL[role] == true
end

function M.priority(entry)
    local role = M.role(entry)
    return CAST_PRIORITY[role]
end

function M.isCold(role)
    return COLD[role] == true
end

function M.isMobEffect(role)
    return MOB_EFFECT[role] == true
end

-- VF: Gate 6 — cold ok on hot path when Combat col is In Combat or Always.
function M.idleBuffOk(entry, role, ctrl, inFight)
    role = role or M.role(entry)
    if not M.isCold(role) then return true end
    local c = entry and (entry.combat or entry.t3_combat) or 'Always'
    if c == 'in combat' or c == 'combat' then c = 'In Combat' end
    if c == 'out of combat' or c == 'ooc' then c = 'Out of Combat' end
    if c == 'always' then c = 'Always' end
    if c == 'Always' or c == 'In Combat' then return true end
    return not inFight
end

-- VF: Gate 4 — after Panic/Heal. Melee dumps every tick; other buckets share one cast bar.
M.OFFENSE_BUCKETS = {
    { 'PetHeal' },
    { 'Melee' },
    { 'Nuke' },
    { 'DoT', 'Debuff' },
    { 'CC' },
    { 'Buff', 'PetBuff', 'Summon' },
}

function M.roleInSet(role, set)
    if not role or not set then return false end
    for i = 1, #set do
        if set[i] == role then return true end
    end
    return false
end

function M.install(runtime)
    runtime.castRole = M.role
    runtime.castIsSurvival = M.isSurvival
    runtime.castIsCold = M.isCold
    runtime.castIsMobEffect = M.isMobEffect
    runtime.castPriorityOf = M.priority
    runtime.castIdleBuffOk = function(entry, ctrl, inFight)
        return M.idleBuffOk(entry, M.role(entry), ctrl, inFight)
    end
    runtime.OFFENSE_BUCKETS = M.OFFENSE_BUCKETS
    runtime.castRoleInSet = M.roleInSet
end

return M
