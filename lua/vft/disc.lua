-- VF: Discipline helper — ActiveDisc wait signal so combat skips ahead, no /disc spam.
-- VF: fireDisc returns true | false | 'wait'. 'wait' = slot held; try next candidate.

local mq = require('mq')

local M = {}

function M.install(runtime, deps)
    deps = deps or {}
    local getCtrl = deps.ctrl or function() return nil end
    local getPetState = deps.petState or function() return nil end
    local setTarget = deps.setTarget
    local clearCursor = deps.clearCursor

    -- VF: Live ActiveDisc only — empty TLO still returns userdata; no-time leftovers
    -- VF: (rule 2) must not block every duration disc forever.
    function runtime.discActive()
        local name, id, dur = nil, 0, 0
        local present = false
        pcall(function()
            local ad = mq.TLO.Me.ActiveDisc
            if not ad then return end
            pcall(function()
                local v = ad()
                if v ~= nil and v ~= false and tostring(v) ~= '' and tostring(v) ~= 'NULL' then
                    present = true
                    if type(v) == 'string' then name = v end
                end
            end)
            pcall(function() id = tonumber(ad.ID()) or 0 end)
            if id > 0 then present = true end
            if not name then
                pcall(function()
                    local n = ad.Name()
                    if n and tostring(n) ~= '' and tostring(n) ~= 'NULL' then
                        name = tostring(n)
                    end
                end)
            end
            pcall(function()
                if ad.Duration then
                    dur = tonumber(ad.Duration()) or 0
                end
            end)
        end)
        if not present or id <= 0 then return nil, 0 end
        -- VF: no-time ActiveDisc reads present with Duration 0 — do not hold the slot.
        if dur <= 0 then return nil, 0 end
        return name, id
    end

    local function discDurationSelf(name)
        local hasDuration, isSelf = false, true
        pcall(function()
            local sp = mq.TLO.Spell(name)
            if not (sp and sp()) then return end
            local durTicks = tonumber(sp.Duration()) or tonumber(sp.MyDuration()) or 0
            if durTicks > 0 then hasDuration = true end
            local tt = sp.TargetType()
            if tt and tostring(tt):lower() ~= 'self' then isSelf = false end
        end)
        return hasDuration, isSelf
    end

    -- VF: true when a live ActiveDisc blocks this press — skip to next candidate.
    function runtime.discWait(name)
        if not name or name == '' then return false end
        local adName, adId = runtime.discActive()
        if not adName and (not adId or adId <= 0) then return false end
        if adName and adName:lower() == tostring(name):lower() then return true end
        local hasDuration, isSelf = discDurationSelf(name)
        if hasDuration and isSelf then return true end
        return false
    end

    -- VF: 'ready' | 'wait' | 'no'
    function runtime.discGate(name)
        if not name or name == '' then return 'no' end
        if runtime.discWait(name) then return 'wait' end

        local now = os.clock()
        if runtime.discCooldown and runtime.discCooldown[name] and now < runtime.discCooldown[name] then
            return 'no'
        end
        local key = 'd' .. name
        if runtime.lastCast and runtime.lastCast[key] and now < runtime.lastCast[key] then
            return 'no'
        end

        local known = false
        pcall(function()
            local ca = mq.TLO.Me.CombatAbility(name)
            if ca and ca() then known = true end
        end)
        if not known then return 'no' end

        local readyOk, isReady = pcall(function() return mq.TLO.Me.CombatAbilityReady(name)() end)
        if readyOk and isReady == false then return 'no' end

        local timerOk, timerVal = pcall(function() return mq.TLO.Me.CombatAbilityTimer(name) end)
        if timerOk and timerVal then
            local sec = 0
            pcall(function()
                if type(timerVal.TotalSeconds) == 'function' then
                    sec = timerVal.TotalSeconds() or 0
                elseif type(timerVal.TotalSeconds) == 'number' then
                    sec = timerVal.TotalSeconds
                elseif timerVal() then
                    local v = timerVal()
                    if type(v) == 'number' then sec = v end
                end
            end)
            if sec > 0 then return 'no' end
        end

        local endOk = true
        pcall(function()
            local sp = mq.TLO.Spell(name)
            if not (sp and sp()) then return end
            local endCost = tonumber(sp.EnduranceCost()) or 0
            if endCost > 0 and (mq.TLO.Me.CurrentEndurance() or 0) < endCost then
                endOk = false
            end
        end)
        if not endOk then return 'no' end

        return 'ready'
    end

    function runtime.isDiscReady(name)
        return runtime.discGate(name) == 'ready'
    end

    -- VF: /vf discdiag — why discs are not pressing.
    function runtime.discDiag()
        local adName, adId = runtime.discActive()
        print(string.format('\ag[VF]\ax discdiag: ActiveDisc=%s id=%s',
            tostring(adName or '-'), tostring(adId or 0)))
        local loadout = deps.getLoadout and deps.getLoadout() or {}
        local n = 0
        for name, d in pairs(loadout.discs or {}) do
            if d and d.enabled and d.via ~= 'skill' then
                n = n + 1
                local gate = runtime.discGate(name)
                local burn = d.burn_only and ' burn' or ''
                print(string.format('  %s → %s%s type=%s min=%s pct=%s',
                    name, gate, burn, tostring(d.cast_type or '-'),
                    tostring(d.min_xtar or '-'), tostring(d.pct)))
            end
        end
        if n == 0 then
            print('\ay[VF]\ax discdiag: no enabled discs in loadout.')
        end
    end

    -- VF: true = pressed, false = not ready, 'wait' = ActiveDisc held (skip, do not spam).
    function runtime.fireDisc(name, a, id)
        -- VF: Melee style — offensive /disc before the swing eats /attack on.
        local ctrl = getCtrl()
        if not ctrl or (ctrl.combat_style or 'Melee') == 'Melee' then
            local swinging = false
            pcall(function() swinging = not not mq.TLO.Me.Combat() end)
            if not swinging then
                local det = runtime.isDetrimentalAction
                if det and det(name, a and a.target, a) then return false end
            end
        end
        if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then
            mq.cmd('/stand')
        end
        local gate = runtime.discGate(name)
        if gate == 'wait' then return 'wait' end
        if gate ~= 'ready' then return false end

        local selfCast = (id == mq.TLO.Me.ID())
        local orig = mq.TLO.Target.ID() or 0
        local retargeted = false
        if not selfCast then
            if setTarget and not setTarget(id) then return false end
            retargeted = (orig ~= id)
        elseif orig ~= id and runtime.selfCastNeedsTarget and runtime.selfCastNeedsTarget(mq.TLO.Spell(name)) then
            if setTarget and not setTarget(id) then return false end
            retargeted = true
        end
        if clearCursor then clearCursor() end
        mq.cmdf('/disc "%s"', name)

        local now = os.clock()
        local key = 'd' .. name
        local recastSec = 0
        pcall(function()
            local sp = mq.TLO.Spell(name)
            if not (sp and sp()) then return end
            local rt = tonumber(sp.RecastTime()) or 0
            if rt > 0 then
                if rt > 1800 then recastSec = rt / 1000 else recastSec = rt end
            end
            if recastSec == 0 and type(sp.RecastTime) == 'userdata' then
                local ts = sp.RecastTime.TotalSeconds() or 0
                if ts > 0 then recastSec = ts end
            end
        end)

        pcall(function()
            local cat = mq.TLO.Me.CombatAbilityTimer(name)
            if cat and cat() then
                local ts = 0
                if type(cat.TotalSeconds) == 'function' then
                    ts = cat.TotalSeconds() or 0
                elseif type(cat.TotalSeconds) == 'number' then
                    ts = cat.TotalSeconds
                elseif type(cat) == 'number' then
                    ts = cat
                end
                if ts > recastSec then recastSec = ts end
            end
        end)

        -- VF: short press lock only — ActiveDisc (with Duration>0) owns the real hold.
        local lockSec = recastSec
        if lockSec <= 0 then lockSec = 1.5 end
        if lockSec > 6 then lockSec = 6 end

        if not runtime.discCooldown then runtime.discCooldown = {} end
        if not runtime.lastCast then runtime.lastCast = {} end
        if not runtime.discExpires then runtime.discExpires = {} end

        if recastSec > 0 then runtime.discCooldown[name] = now + recastSec end
        runtime.discExpires[name] = nil
        runtime.lastCast[key] = now + lockSec

        local ps = getPetState and getPetState()
        if ps and a then ps.lastCastCls = a.cls end
        print('\ag[VF]\ax discipline fired: ' .. name)
        if retargeted then
            mq.delay(60)
            if orig > 0 and mq.TLO.Target.ID() ~= orig then mq.cmdf('/target id %d', orig) end
        end
        return true
    end
end

return M
