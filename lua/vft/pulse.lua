-- VF: Gate 2 — one snapshot per hot pulse. Buckets read this, not per-row rescans.
-- VF: Gate 5 — targetEffects = DoT/Debuff names already on kill target.
-- VF: docs/COMBAT_TICK_IDEAL.md

local mq = require('mq')
local U = require('vft.util')

local M = {}

local function addEffectName(set, name)
    name = tostring(name or '')
    if name == '' or name == 'NULL' then return end
    set[name] = true
    set[name:lower()] = true
    local cleaned = U.cleanSpellName(name)
    if cleaned ~= '' then
        set[cleaned] = true
        set[cleaned:lower()] = true
    end
    local norm = U.normalizeSpellName(name)
    if norm ~= '' then set[norm] = true end
end

-- VF: Target.Buff / Spawn.BuffCount once per pulse — DoT and Debuff share this set.
local function gatherTargetEffects(targetId)
    local set = {}
    if not targetId or targetId <= 0 then return set end
    local tgtId = 0
    pcall(function() tgtId = mq.TLO.Target.ID() or 0 end)
    local src = nil
    if tgtId == targetId then
        src = mq.TLO.Target
    else
        local s = mq.TLO.Spawn(targetId)
        if s and s() then src = s end
    end
    if not src then return set end
    local cnt = 0
    pcall(function() cnt = tonumber(src.BuffCount()) or 0 end)
    if cnt < 1 then
        pcall(function() cnt = tonumber(src.CachedBuffCount()) or 0 end)
    end
    for i = 1, math.min(cnt, 84) do
        local bn = ''
        pcall(function() bn = src.Buff(i).Name() or '' end)
        if bn == '' or bn == 'NULL' then
            pcall(function()
                local b = src.Buff(i)
                if b and b.Spell then bn = b.Spell.Name() or '' end
            end)
        end
        addEffectName(set, bn)
    end
    -- VF: own casts sometimes only under MyBuff on NPCs.
    for i = 1, 42 do
        local bn = ''
        local ok = pcall(function()
            local b = src.MyBuff(i)
            if not b or not b() then return end
            bn = b.Name() or ''
            if (bn == '' or bn == 'NULL') and b.Spell then bn = b.Spell.Name() or '' end
        end)
        if not ok or bn == '' then break end
        addEffectName(set, bn)
    end
    return set
end

function M.install(runtime, api)
    api = api or {}

    local function getCtrl()
        if type(api.getCtrl) == 'function' then return api.getCtrl() end
        return api.ctrl
    end

    function runtime.takePulseSnapshot()
        local ctrl = getCtrl()
        local p = {
            at = os.clock(),
            xtar = 0,
            myHp = 100,
            myMana = 100,
            myEnd = 100,
            petId = 0,
            petUp = false,
            petHp = 100,
            burn = not not (ctrl and ctrl.burn),
            floor = tonumber(ctrl and ctrl.combat_heal_pct) or 0,
            combatHealOn = not (ctrl and ctrl.combat_heal == false),
            cureable = false,
            targetId = 0,
            targetEffects = {},
        }
        if api.countPackMobs then
            pcall(function() p.xtar = tonumber(api.countPackMobs()) or 0 end)
        end
        local myId = 0
        pcall(function() myId = mq.TLO.Me.ID() or 0 end)
        if myId > 0 and api.pctHP then
            p.myHp = api.pctHP(myId) or 100
        else
            pcall(function() p.myHp = mq.TLO.Me.PctHPs() or 100 end)
        end
        pcall(function()
            p.myMana = mq.TLO.Me.PctMana() or 100
            p.myEnd = mq.TLO.Me.PctEndurance() or 100
        end)
        pcall(function()
            p.petId = mq.TLO.Me.Pet.ID() or 0
            if p.petId > 0 then
                p.petUp = true
                if api.pctHP then
                    p.petHp = api.pctHP(p.petId) or 100
                else
                    p.petHp = mq.TLO.Spawn(p.petId).PctHPs() or 100
                end
            end
        end)
        pcall(function() p.targetId = mq.TLO.Target.ID() or 0 end)
        if p.targetId > 0 then
            p.targetEffects = gatherTargetEffects(p.targetId)
        end
        if myId > 0 then
            if runtime.selfHasCureableOnBar then
                pcall(function() p.cureable = not not runtime.selfHasCureableOnBar() end)
            end
            if not p.cureable and api.isPoisonedOrDiseased then
                pcall(function() p.cureable = not not api.isPoisonedOrDiseased(myId) end)
            end
        end
        runtime.pulse = p
        return p
    end

    -- VF: DoT/Debuff already on mob — pulse set first, then per-name TLO fallback.
    function runtime.targetEffectUp(spellName, targetId)
        spellName = tostring(spellName or '')
        if spellName == '' then return false end
        local p = runtime.pulse
        local tid = targetId or (p and p.targetId) or 0
        if p and p.targetEffects and tid > 0 and (p.targetId == 0 or p.targetId == tid) then
            local set = p.targetEffects
            if set[spellName] or set[spellName:lower()] then return true end
            local cleaned = U.cleanSpellName(spellName)
            if cleaned ~= '' and (set[cleaned] or set[cleaned:lower()]) then return true end
            local norm = U.normalizeSpellName(spellName)
            if norm ~= '' and set[norm] then return true end
        end
        if runtime.buffFactuallyUp and tid > 0 then
            return not not runtime.buffFactuallyUp(tid, spellName)
        end
        return false
    end

    -- VF: Gate 3 — myHP ≤ combat_heal_pct floor, and survivalCast has something to try.
    function runtime.survivalNeeded(p)
        p = p or runtime.pulse
        if not p then return false end
        if not p.combatHealOn then return false end
        if (p.floor or 0) <= 0 then return false end
        if (p.myHp or 100) > p.floor then return false end
        -- VF: empty survival (no Heal loadout, not cureable) must not stall the tick.
        if p.cureable then return true end
        if api.hasSelfHealLoadout then
            local ok = false
            pcall(function() ok = not not api.hasSelfHealLoadout() end)
            return ok
        end
        return true
    end
end

return M
