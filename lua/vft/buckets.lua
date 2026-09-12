-- VF: Gate 4 — per-bucket fire. Melee instants every tick; one cast-time start when bar free.
-- VF: docs/COMBAT_TICK_IDEAL.md

local mq = require('mq')
local U = require('vft.util')
local D = require('vft.data')
local MeleeCat = require('vft.mgr.melee_catalog')

local M = {}

function M.install(runtime, api)
    api = api or {}

    local function getLoadout()
        if type(api.getLoadout) == 'function' then return api.getLoadout() end
        return api.loadout or {}
    end

    local function getCtrl()
        if type(api.getCtrl) == 'function' then return api.getCtrl() end
        return api.ctrl
    end

    -- VF: item Level min/max — spawn level (Me on self buffs). Blank = ungated.
    function runtime.itemLevelOk(entry, id)
        if not entry then return true end
        local minL = tonumber(entry.min_level)
        local maxL = tonumber(entry.max_level)
        if not minL and not maxL then return true end
        local lvl = 0
        pcall(function()
            id = tonumber(id) or 0
            if id > 0 then
                local s = mq.TLO.Spawn(id)
                if s and s() then lvl = tonumber(s.Level()) or 0 end
            end
            if lvl <= 0 then lvl = tonumber(mq.TLO.Me.Level()) or 0 end
        end)
        if minL and lvl < minL then return false end
        if maxL and lvl > maxL then return false end
        return true
    end

    -- VF: Melee style — no AA/disc dump until auto-attack is actually on. /alt act eats /attack on.
    local function meleeSwingReady()
        local ctrl = getCtrl()
        if not ctrl or (ctrl.combat_style or 'Melee') ~= 'Melee' then return true end
        local on = false
        pcall(function() on = not not mq.TLO.Me.Combat() end)
        return on
    end

    local function roleOf(entry)
        return runtime.castRole and runtime.castRole(entry) or (entry and entry.cast_type) or nil
    end

    local function belowOf(entry)
        return tonumber(entry and entry.pct) or 100
    end

    -- VF: kind = 'disc'|'aa'|'item'|'gem'. AA/item before disc — Kick/Bash were starving Melee AAs.
    local function sortCandidates(list)
        table.sort(list, function(a, b)
            local ba, bb = belowOf(a.entry), belowOf(b.entry)
            if ba ~= bb then return ba < bb end
            local function ord(k)
                if k == 'aa' or k == 'item' then return 1 end
                if k == 'disc' then return 2 end
                return 3
            end
            local oa, ob = ord(a.kind), ord(b.kind)
            if oa ~= ob then return oa < ob end
            return tostring(a.name) < tostring(b.name)
        end)
    end

    local function fireOne(c)
        if not c then return false end
        local entry, id, name = c.entry, c.id, c.name
        if c.kind == 'disc' then
            -- VF: 'wait' = ActiveDisc held — skip this row, keep dumping the rest.
            local r = api.fireDisc and api.fireDisc(name, entry, id)
            return r == true
        elseif c.kind == 'aa' then
            return not not (api.fireAA and api.fireAA(name, entry, id))
        elseif c.kind == 'item' then
            return not not (api.fireItem and api.fireItem(name, entry, id))
        elseif c.kind == 'gem' then
            if api.castTracker and api.castTracker.isLockedOut and api.castTracker.isLockedOut(entry.spell) then
                return false
            end
            local buffKey = nil
            if entry.when == 'missing buff' and id and U.sungKey then
                buffKey = U.sungKey(entry.spell, id)
                if buffKey and runtime.buffRetryOk and not runtime.buffRetryOk(buffKey) then
                    return false
                end
            end
            if not (api.castGem and api.castGem(c.slot, entry, id)) then return false end
            if buffKey then
                local bene = false
                pcall(function() bene = not not mq.TLO.Spell(entry.spell).Beneficial() end)
                if bene and runtime.sungBuffs then runtime.sungBuffs[buffKey] = true end
                if runtime.buffTryRecorded then runtime.buffTryRecorded(buffKey, entry.spell) end
            end
            return true
        end
        return false
    end

    -- VF: no fireFirstEligible. Never called; the live paths are fireMeleeDump and
    -- VF: fireFirstCastTime, which apply their own gating on top of sortCandidates.

    -- VF: CastTime may be number ms, seconds, or timestamp userdata (Raw / TotalSeconds).
    local function spellCastMs(name)
        if not name or name == '' then return nil end
        local ms = nil
        pcall(function()
            local sp = mq.TLO.Spell(name)
            if not (sp and sp()) then return end
            local ct = sp.MyCastTime() or sp.CastTime()
            if ct == nil then return end
            if type(ct) == 'number' then
                ms = ct
            else
                local raw, ts
                pcall(function() if ct.Raw then raw = ct.Raw() end end)
                pcall(function() if ct.TotalSeconds then ts = ct.TotalSeconds() end end)
                if raw ~= nil then
                    ms = tonumber(raw)
                elseif ts ~= nil then
                    ms = (tonumber(ts) or 0) * 1000
                else
                    ms = tonumber(ct)
                end
            end
        end)
        if ms == nil then return nil end
        if ms > 0 and ms < 20 then ms = ms * 1000 end
        return ms
    end

    local function candidateInstant(c)
        if not c then return false end
        if c.kind == 'aa' then
            -- VF: use AA.Spell cast time — Spell(name) can hit a different spell and false-out.
            local ms = nil
            pcall(function()
                local aa = mq.TLO.Me.AltAbility(c.name)
                if not (aa and aa()) then return end
                local sp = aa.Spell
                if not (sp and sp()) then return end
                local ct = sp.MyCastTime() or sp.CastTime()
                if type(ct) == 'number' then
                    ms = ct
                else
                    local raw, ts
                    pcall(function() if ct.Raw then raw = ct.Raw() end end)
                    pcall(function() if ct.TotalSeconds then ts = ct.TotalSeconds() end end)
                    if raw ~= nil then ms = tonumber(raw)
                    elseif ts ~= nil then ms = (tonumber(ts) or 0) * 1000
                    else ms = tonumber(ct) end
                end
                if ms and ms > 0 and ms < 20 then ms = ms * 1000 end
            end)
            -- VF: <100ms counts as instant for the AA channel dump.
            return ms == nil or ms < 100
        end
        if c.kind == 'disc' then
            local ms = spellCastMs(c.name)
            return ms == nil or ms <= 0
        end
        if c.kind == 'gem' then
            local ms = spellCastMs(c.name)
            return ms ~= nil and ms <= 0
        end
        if c.kind == 'item' then
            local ms = nil
            pcall(function()
                local it = mq.TLO.FindItem('=' .. tostring(c.name or ''))
                if not (it and it()) then return end
                local ct = tonumber(it.CastTime()) or 0
                if ct > 0 and ct < 20 then ct = ct * 1000 end
                ms = ct
                if (not ms or ms <= 0) and it.Clicky and it.Clicky() then
                    local sp = it.Clicky.Spell
                    if sp and sp() then
                        ms = spellCastMs(tostring(sp.Name() or sp() or ''))
                    end
                end
            end)
            return ms == nil or ms < 100
        end
        return false
    end

    local function aaCastMs(name)
        local ms = nil
        pcall(function()
            local aa = mq.TLO.Me.AltAbility(name)
            if not (aa and aa()) then return end
            local sp = aa.Spell
            if not (sp and sp()) then return end
            local ct = sp.MyCastTime() or sp.CastTime()
            if type(ct) == 'number' then
                ms = ct
            else
                local raw, ts
                pcall(function() if ct.Raw then raw = ct.Raw() end end)
                pcall(function() if ct.TotalSeconds then ts = ct.TotalSeconds() end end)
                if raw ~= nil then ms = tonumber(raw)
                elseif ts ~= nil then ms = (tonumber(ts) or 0) * 1000
                else ms = tonumber(ct) end
            end
            if ms and ms > 0 and ms < 20 then ms = ms * 1000 end
        end)
        return ms
    end

    -- VF: Melee dump — instant discs + AAs (cast-time AA skipped only while already casting).
    local function fireMeleeDump(candidates, casting)
        if not candidates or #candidates == 0 then return false end
        sortCandidates(candidates)
        local any = false
        for i = 1, #candidates do
            local c = candidates[i]
            local fire = false
            if c.kind == 'aa' then
                local ms = aaCastMs(c.name)
                fire = (not casting) or (ms == nil or ms < 100)
            elseif candidateInstant(c) then
                fire = true
            end
            if fire and fireOne(c) then
                any = true
            end
        end
        return any
    end

    -- VF: one cast-time start — skip pure instants (Melee dump owns those).
    local function fireFirstCastTime(candidates)
        if not candidates or #candidates == 0 then return false end
        sortCandidates(candidates)
        for i = 1, #candidates do
            local c = candidates[i]
            if not candidateInstant(c) and fireOne(c) then
                return true
            end
        end
        return false
    end

    local function bucketIsMeleeOnly(set)
        return type(set) == 'table' and #set == 1 and set[1] == 'Melee'
    end

    -- VF: Burn dump — /multiline instants every X loops; /timed 3 (~0.3s) keysmash stagger.
    local BURN_ML_EVERY = 10
    local BURN_ML_STEP = 3
    local BURN_ML_PER_LINE = 6

    local function aaOwned(name)
        local owned = 0
        pcall(function()
            local aa = mq.TLO.Me.AltAbility(name)
            if aa and aa() and aa.Rank then owned = tonumber(aa.Rank()) or 0 end
        end)
        return owned > 0
    end

    local function aaReady(name)
        local ok = false
        pcall(function() ok = not not mq.TLO.Me.AltAbilityReady(name)() end)
        return ok
    end

    local function burnCmdFor(c)
        if not c or not c.name or c.name == '' then return nil end
        if c.kind == 'aa' then
            if not aaOwned(c.name) then return nil end
            return '/aa act ' .. c.name
        end
        if c.kind == 'disc' then
            if api.discWait and api.discWait(c.name) then return nil end
            return '/disc "' .. c.name .. '"'
        end
        if c.kind == 'item' then
            if runtime.itemUseCmd then
                return runtime.itemUseCmd(c.name)
            end
            return string.format('/use "%s"', tostring(c.name):gsub('"', ''))
        end
        if c.kind == 'gem' and c.slot then
            return string.format('/cast %d', c.slot)
        end
        return nil
    end

    function runtime.buildBurnMultilineLines(candidates)
        if not candidates or #candidates == 0 then return {} end
        sortCandidates(candidates)
        local acts = {}
        for i = 1, #candidates do
            local c = candidates[i]
            if candidateInstant(c) then
                local ready = true
                if c.kind == 'aa' then
                    ready = aaOwned(c.name) and aaReady(c.name)
                elseif c.kind == 'disc' then
                    ready = not not (api.isDiscReady and api.isDiscReady(c.name))
                elseif c.kind == 'item' then
                    ready = true
                    pcall(function()
                        local it = mq.TLO.FindItem('=' .. tostring(c.name or ''))
                        if not (it and it()) then ready = false; return end
                        local left = tonumber(it.TimerReady()) or 0
                        if left > 0 then ready = false end
                    end)
                elseif c.kind == 'gem' then
                    ready = true
                    pcall(function()
                        ready = not not mq.TLO.Me.SpellReady(c.slot)()
                    end)
                end
                if ready then
                    local cmd = burnCmdFor(c)
                    if cmd then acts[#acts + 1] = cmd end
                end
            end
        end
        if #acts == 0 then return {} end
        local lines, i = {}, 1
        while i <= #acts do
            local parts = {}
            local last = math.min(i + BURN_ML_PER_LINE - 1, #acts)
            for j = i, last do
                local off = (j - 1) * BURN_ML_STEP
                if off <= 0 then
                    parts[#parts + 1] = acts[j]
                else
                    parts[#parts + 1] = string.format('/timed %d %s', off, acts[j])
                end
            end
            lines[#lines + 1] = '/multiline ; ' .. table.concat(parts, ';')
            i = last + 1
        end
        return lines
    end

    function runtime.resetBurnMultiline()
        runtime.burnMlLoop = 0
    end

    function runtime.fireBurnMultiline(candidates)
        local lines = runtime.buildBurnMultilineLines(candidates)
        if #lines == 0 then return false end
        for i = 1, #lines do
            mq.cmd(lines[i])
        end
        print(string.format('\ag[VF]\ax Burn multiline: %d line(s), dump queued.', #lines))
        return true
    end

    local function rowOk(entry, spellName, id, numXtar, combatReady, inFight, allowIdle, allowBurn, ignoreMinXtar)
        if not entry or not spellName or spellName == '' then return false end
        -- VF: burn_only only in Burn band (allowBurn); never in normal offense.
        if entry.burn_only and not allowBurn then return false end
        local pct = tonumber(entry.pct)
        -- VF: blank HP% on discs = ungated (100); Cure ignores Below; AA nil stays 30 outside filler.
        if pct == nil then
            local role = roleOf(entry)
            if role == 'Cure' or entry.via == 'disc' then
                pct = 100
            else
                pct = 30
            end
        end
        if pct <= 0 then return false end
        if entry.enabled == false then return false end
        local role = roleOf(entry)
        -- VF: Gate 6 — cold roles: OOC → buffTick; in fight → Combat col In Combat|Always only.
        if runtime.castIsCold and runtime.castIsCold(role) then
            if not inFight then return false end
            if not (runtime.castIdleBuffOk and runtime.castIdleBuffOk(entry, getCtrl(), true)) then
                return false
            end
        end
        local idleBuff = api.isIdleSelfBuff and api.isIdleSelfBuff(entry.when, entry.target)
        if idleBuff and runtime.castIdleBuffOk and not runtime.castIdleBuffOk(entry, getCtrl(), inFight) then
            idleBuff = false
        end
        if idleBuff and not allowIdle then return false end
        -- VF: non-survival offense needs CombatState COMBAT — combatReady alone is true with no NPC.
        local survival = runtime.castIsSurvival and runtime.castIsSurvival(role)
        if not survival and not idleBuff and not inFight then return false end
        -- VF: Burn dump — named bosses often not nearby; don't require min pack.
        -- VF: Pack gates = proximity (spawnIsOnMe in radius), not XTarget.
        -- VF: Heal/Panic/Cure ignore pack — min_xtar was delaying survival heals.
        local xtNeed = idleBuff and 0 or (tonumber(entry.min_xtar) or 1)
        if allowBurn then xtNeed = tonumber(entry.min_xtar) or 0 end
        if ignoreMinXtar then xtNeed = 0 end
        local xtMax = tonumber(entry.max_xtargets)
        local xtCount = 0
        if api.countPackMobs then
            xtCount = tonumber(api.countPackMobs()) or 0
        else
            xtCount = tonumber(numXtar) or 0
        end
        if xtCount < xtNeed then return false end
        if xtMax ~= nil and xtCount > xtMax then return false end
        -- VF: Burn while fighting even if stick has not "engaged" yet.
        if not (combatReady or idleBuff or allowBurn) then return false end
        if not id or id <= 0 then return false end
        if runtime.itemLevelOk and not runtime.itemLevelOk(entry, id) then return false end
        if api.rowBlocked and api.rowBlocked(entry, spellName, id) then return false end
        if api.conditionMet and not api.conditionMet(entry.when, pct, spellName, id, entry.cls) then
            return false
        end
        -- VF: Cure rows must see a detrimental counter slot -- empty when= was always-true.
        if role == 'Cure' and runtime.hasCureNeed and not runtime.hasCureNeed(spellName, id) then
            return false
        end
        if api.isDetrimentalAction then
            local isDet = api.isDetrimentalAction(spellName, entry.target, entry)
            if isDet then
                if not (api.isHostileTarget and api.isHostileTarget(id)) then return false end
                if not (api.isTargetInRange and api.isTargetInRange(spellName, id)) then return false end
            end
        end
        return true, idleBuff
    end

    local function gatherRoleSet(roleSet, numXtar, combatReady, inFight, opts)
        opts = opts or {}
        local loadout = getLoadout()
        local out = {}
        local wantBurn = opts.burnOnly == true
        local allowIdle = opts.allowIdle == true
        local ignoreMinXtar = opts.ignoreMinXtar == true
        local burnOn = not not (getCtrl() and getCtrl().burn)

        -- VF: 'DPS first' splits the heal bands in two passes over the same rows --
        -- VF: selfOnly before the rotation, allyOnly after it. A row is "ally" purely by
        -- VF: where its target RESOLVED this tick, so 'Lowest-HP Ally' counts as self
        -- VF: while we are the worst off, which is what we want: that is a self-heal.
        -- VF: Unset opts means no filter, so every existing caller is unchanged.
        local myId = 0
        pcall(function() myId = tonumber(mq.TLO.Me.ID()) or 0 end)
        local function targetAllowed(id)
            if not (opts.selfOnly or opts.allyOnly) then return true end
            id = tonumber(id) or 0
            -- VF: an unresolved target is not an ally; let it through the self pass so a
            -- VF: broken row fails visibly in one place instead of vanishing from both.
            local isSelf = (id <= 0) or (myId > 0 and id == myId)
            if opts.selfOnly then return isSelf end
            return not isSelf
        end

        local function roleMatch(role)
            if opts.anyRole then return true end
            if not roleSet then return false end
            return runtime.castRoleInSet and runtime.castRoleInSet(role, roleSet)
        end

        -- VF: burn_only instants → multiline; cast-time burn_only → normal buckets while Burn on.
        local function wantEntry(entry, kindHint, name)
            if not entry then return false end
            if wantBurn then
                return not not entry.burn_only
            end
            if not entry.burn_only then return true end
            if not burnOn then return false end
            local probe = { kind = kindHint, name = name }
            return not candidateInstant(probe)
        end

        for name, d in pairs(loadout.discs or {}) do
            -- VF: via=skill pruned; MQ2Melee catalog AAs skipped below on AA loop.
            if d and d.via ~= 'skill' and not MeleeCat.isDelegated(name)
                and wantEntry(d, 'disc', name) then
                local role = roleOf(d)
                if roleMatch(role) and (d.enabled ~= false) then
                    local id = api.resolveTargetId and api.resolveTargetId(d.target, d.cls) or 0
                    local allowBurnRow = wantBurn or (burnOn and d.burn_only)
                    if targetAllowed(id) and rowOk(d, name, id, numXtar, combatReady, inFight, allowIdle, allowBurnRow, ignoreMinXtar) then
                        local ready = not not (api.isDiscReady and api.isDiscReady(name))
                        if ready and d.boss_only then
                            local named = false
                            pcall(function()
                                local s = mq.TLO.Spawn(id)
                                named = not not (s() and s.Named())
                            end)
                            if not named then ready = false end
                        end
                        if ready then
                            out[#out + 1] = { kind = 'disc', name = name, entry = d, id = id }
                        end
                    end
                end
            end
        end

        for name, a in pairs(loadout.aas or {}) do
            -- VF: nil pct = filler bucket only; Cure rows fire without a Below %.
            local aaRole = roleOf(a)
            local aaPctOk = a and (a.pct ~= nil or aaRole == 'Cure')
            if a and a.enabled and aaPctOk and not MeleeCat.isDelegated(name)
                and wantEntry(a, 'aa', name) then
                local role = aaRole
                if roleMatch(role) then
                    local id = api.resolveTargetId and api.resolveTargetId(a.target, a.cls) or 0
                    local allowBurnRow = wantBurn or (burnOn and a.burn_only)
                    if targetAllowed(id) and rowOk(a, name, id, numXtar, combatReady, inFight, allowIdle, allowBurnRow, ignoreMinXtar) then
                        out[#out + 1] = { kind = 'aa', name = name, entry = a, id = id }
                    end
                end
            end
        end

        for name, it in pairs(loadout.items or {}) do
            local itRole = roleOf(it)
            local itPctOk = it and (it.pct ~= nil or itRole == 'Cure')
            if it and it.enabled and itPctOk and wantEntry(it, 'item', name) then
                local role = itRole
                if roleMatch(role) then
                    -- VF: gates/buff bar match Clicky.Spell — never the item name.
                    local gateName = ''
                    if runtime.itemBuffSpell then
                        gateName = runtime.itemBuffSpell(name, it) or ''
                    elseif runtime.itemClickSpell then
                        gateName = runtime.itemClickSpell(name, it) or ''
                    else
                        gateName = (it.spell and it.spell ~= '') and it.spell or ''
                    end
                    if gateName ~= '' then
                        local id = api.resolveTargetId and api.resolveTargetId(it.target, it.cls) or 0
                        -- VF: Buff/HoT always resolve to Me before fireItem.
                        if role == 'Buff' or role == 'HoT' or role == 'Heal'
                            or role == 'Panic' or role == 'Cure' or role == 'Summon' then
                            pcall(function()
                                local mid = mq.TLO.Me.ID() or 0
                                if mid > 0 then id = mid end
                            end)
                        end
                        local allowBurnRow = wantBurn or (burnOn and it.burn_only)
                        if targetAllowed(id) and rowOk(it, gateName, id, numXtar, combatReady, inFight, allowIdle, allowBurnRow, ignoreMinXtar) then
                            out[#out + 1] = { kind = 'item', name = name, entry = it, id = id }
                        end
                    end
                end
            end
        end

        -- VF: gems need standstill unless allowMoveGems (survival after stopMoving).
        if not (api.isCasting and api.isCasting()) then
            local moving = api.isMoveActive and api.isMoveActive()
            if opts.allowMoveGems or not moving then
                for i = 1, D.NUM_GEMS do
                    local g = loadout.gems and loadout.gems[i]
                    if g and g.spell and g.spell ~= '' and wantEntry(g, 'gem', g.spell, false) then
                        local role = roleOf(g)
                        if roleMatch(role) then
                            local id = api.resolveTargetId and api.resolveTargetId(g.target, g.cls) or 0
                            local allowBurnRow = wantBurn or (burnOn and g.burn_only)
                            if targetAllowed(id) and rowOk(g, g.spell, id, numXtar, combatReady, inFight, allowIdle, allowBurnRow, ignoreMinXtar) then
                                out[#out + 1] = { kind = 'gem', name = g.spell, entry = g, id = id, slot = i }
                            end
                        end
                    end
                end
            end
        end
        return out
    end

    -- VF: Panic / Heal / HoT / Cure / Burn bands — one fire.
    -- VF: dump instant AAs/discs always; return true only if a cast-time start (spell channel).
    function runtime.bandCast(roleSet, numXtar, combatReady, inFight, opts)
        local cands = gatherRoleSet(roleSet, numXtar, combatReady, inFight, opts)
        local casting = (api.isCasting and api.isCasting())
            or (api.castBusy and api.castBusy())
        fireMeleeDump(cands, casting)
        if casting then return false end
        return fireFirstCastTime(cands)
    end

    function runtime.priorityPanicCast()
        local ctrl = getCtrl()
        local numXtar = 0
        if api.countPackMobs then numXtar = tonumber(api.countPackMobs()) or 0 end
        local inFight = (runtime.engineInCombat and runtime.engineInCombat())
            or (runtime.inCombatState and runtime.inCombatState()) or false
        return runtime.bandCast({ 'Panic' }, numXtar, true, inFight, {})
    end

    function runtime.burnCast(numXtar, combatReady, inFight)
        local ctrl = getCtrl()
        if not (ctrl and ctrl.burn) then return false end
        runtime.burnMlLoop = (runtime.burnMlLoop or 0) + 1
        local n = runtime.burnMlLoop
        -- VF: first pulse + every BURN_ML_EVERY — no per-AA CD vars; MQ no-ops unready.
        if n ~= 1 and ((n - 1) % BURN_ML_EVERY) ~= 0 then return false end
        local cands = gatherRoleSet(nil, numXtar, combatReady, inFight, {
            burnOnly = true,
            anyRole = true,
            allowMoveGems = true,
        })
        return runtime.fireBurnMultiline(cands)
    end

    -- VF: /vf burndiag — why burn_only rows are not firing.
    function runtime.burnDiag()
        local ctrl = getCtrl()
        local loadout = getLoadout()
        local numXtar = 0
        if api.countPackMobs then numXtar = tonumber(api.countPackMobs()) or 0 end
        local inFight = (runtime.engineInCombat and runtime.engineInCombat())
            or (runtime.inCombatState and runtime.inCombatState()) or false
        local myHp = 100
        pcall(function() myHp = mq.TLO.Me.PctHPs() or 100 end)
        local tid = 0
        pcall(function() tid = mq.TLO.Target.ID() or 0 end)
        local thp = tid > 0 and (api.pctHP and api.pctHP(tid)) or -1
        print(string.format(
            '\ag[VF]\ax burndiag: burn=%s inFight=%s xtar=%d myHP=%d tgt=%d thp=%s',
            tostring(ctrl and ctrl.burn), tostring(inFight), numXtar, myHp, tid, tostring(thp)))
        local n = 0
        local function check(kind, name, entry)
            if not entry or not entry.burn_only then return end
            n = n + 1
            local role = roleOf(entry)
            local pct = tonumber(entry.pct)
            if pct == nil then pct = 30 end
            local id = api.resolveTargetId and api.resolveTargetId(entry.target, entry.cls) or 0
            local why = 'gates ok'
            if kind == 'aa' then
                if not aaOwned(name) then why = 'AA not owned'
                elseif not aaReady(name) then why = 'AA on cooldown' end
            elseif kind == 'disc' then
                local known = false
                pcall(function()
                    local ca = mq.TLO.Me.CombatAbility(name)
                    known = not not (ca and ca())
                end)
                if not known then why = 'disc not known' end
            elseif type(kind) == 'string' and kind:sub(1, 3) == 'gem' then
                local inBook = false
                pcall(function()
                    local b = mq.TLO.Me.Book(name)
                    if b and b() then
                        local v = b()
                        inBook = (type(v) == 'number' and v > 0)
                            or (tostring(v) ~= '' and tostring(v) ~= 'NULL')
                    end
                end)
                if not inBook then why = 'not in spellbook' end
            end
            if why == 'gates ok' or why == 'AA on cooldown' then
                if entry.enabled == false then why = 'enabled=false'
                elseif pct <= 0 then why = 'pct=0 (disabled)'
                elseif not (ctrl and ctrl.burn) then why = 'burn OFF'
                elseif not id or id <= 0 then why = 'no target id'
                elseif api.rowBlocked and api.rowBlocked(entry, name, id) then why = 'rowBlocked'
                elseif api.conditionMet and not api.conditionMet(entry.when, pct, name, id, entry.cls) then
                    why = string.format('when "%s" @%d%% failed', tostring(entry.when), pct)
                elseif why == 'gates ok' then
                    why = 'gates ok (ready/CD not checked)'
                end
            end
            print(string.format('  %s "%s" role=%s cls=%s pct=%d en=%s -> %s',
                kind, name, tostring(role), tostring(entry.cls or '-'), pct,
                tostring(entry.enabled), why))
        end
        for name, a in pairs(loadout.aas or {}) do check('aa', name, a) end
        for name, it in pairs(loadout.items or {}) do check('item', name, it) end
        for name, d in pairs(loadout.discs or {}) do check('disc', name, d) end
        for i = 1, D.NUM_GEMS do
            local g = loadout.gems and loadout.gems[i]
            if g and g.spell then check('gem' .. i, g.spell, g) end
        end
        if n == 0 then
            print('\ay[VF]\ax burndiag: no burn_only rows in loadout. Check Burn col + Save in Settings.')
        else
            print(string.format('\ag[VF]\ax burndiag: %d burn_only row(s).', n))
        end
    end

    -- VF: survival — Panic → Cure → Heal → Tap → HoT; helper preempts by priority.
    function runtime.survivalCast(pulse)
        if api.meDead and api.meDead() then return false end
        if runtime.rushOnTheMove and runtime.rushOnTheMove() then return false end
        if api.freeBardBarForHeal then api.freeBardBarForHeal() end
        local numXtar = (pulse and pulse.xtar) or 0
        local inFight = true
        local survOpts = { allowMoveGems = true, ignoreMinXtar = true }
        if runtime.bandCast({ 'Panic' }, numXtar, true, inFight, survOpts) then return true end
        if pulse and pulse.cureable then
            if runtime.bandCast({ 'Cure' }, numXtar, true, inFight, survOpts) then return true end
        end
        if runtime.bandCast({ 'Heal' }, numXtar, true, inFight, survOpts) then return true end
        if runtime.bandCast({ 'Tap' }, numXtar, true, inFight, survOpts) then return true end
        if runtime.bandCast({ 'HoT' }, numXtar, true, inFight, survOpts) then return true end
        if api.isCasting and api.isCasting() then
            local skill = ''
            pcall(function() skill = mq and mq.TLO.Me.Casting.Skill() or '' end)
            if skill ~= 'Singing' then return false end
            if api.freeBardBarForHeal then api.freeBardBarForHeal() end
        end
        if api.stopMovingIfNeeded then api.stopMovingIfNeeded() end
        return false
    end

    -- VF: Melee instants + Melee AAs every hot tick — even while cast bar is busy (instant AAs).
    function runtime.meleeBucketCast(numXtar, combatReady, inFight)
        if not meleeSwingReady() then return false end
        local casting = (api.isCasting and api.isCasting())
            or (api.castBusy and api.castBusy())
        local cands = gatherRoleSet({ 'Melee' }, numXtar, combatReady, inFight, {
            allowMoveGems = true,
        })
        local any = fireMeleeDump(cands, casting)
        -- VF: cast-time Melee discs/gems when bar free (AAs already tried above).
        if not casting then
            if fireFirstCastTime(cands) then any = true end
        end
        return any
    end

    -- VF: instant AAs dump even while gem channel busy; one cast-time start when bar free.
    function runtime.offenseBucketCast(numXtar, combatReady, inFight)
        if not meleeSwingReady() then return false end
        local casting = (api.isCasting and api.isCasting())
            or (api.castBusy and api.castBusy())
        local buckets = runtime.OFFENSE_BUCKETS or {}
        local any, castStarted = false, false
        for bi = 1, #buckets do
            local set = buckets[bi]
            if not bucketIsMeleeOnly(set) then
                local allowIdle = false
                for _, r in ipairs(set) do
                    if r == 'Buff' or r == 'PetBuff' or r == 'Summon' then allowIdle = true end
                end
                local cands = gatherRoleSet(set, numXtar, combatReady, inFight, { allowIdle = allowIdle })
                if fireMeleeDump(cands, casting) then any = true end
                if not casting and not castStarted and fireFirstCastTime(cands) then
                    castStarted = true
                    any = true
                end
            end
        end
        return any
    end

    -- VF: priority-9 filler — offense instant AAs with blank pct; combat only.
    -- VF: never Buff/PetBuff/Summon (OOC/bar path owns those — Familiar was cycling here).
    function runtime.fillerAaDump(inFight)
        if not inFight then return false end
        if not meleeSwingReady() then return false end
        if runtime.engineInCombat and not runtime.engineInCombat() then return false end
        if runtime.inCombatState and not runtime.engineInCombat and not runtime.inCombatState() then return false end
        local loadout = getLoadout()
        local casting = (api.isCasting and api.isCasting())
            or (api.castBusy and api.castBusy())
        local meId = 0
        pcall(function() meId = tonumber(mq.TLO.Me.ID()) or 0 end)
        local function coldOrSurvival(role)
            return role == 'Panic' or role == 'Heal' or role == 'Cure' or role == 'HoT'
                or role == 'Buff' or role == 'PetBuff' or role == 'Summon'
        end
        local function buffAlreadyUp(name, id)
            if not (runtime.buffFactuallyUp and name and id and id > 0) then return false end
            return not not runtime.buffFactuallyUp(id, name)
        end
        local cands = {}
        for name, a in pairs(loadout.aas or {}) do
            if a and a.enabled == true and a.pct == nil and not MeleeCat.isDelegated(name) then
                local role = roleOf(a)
                if not coldOrSurvival(role) then
                    local ms = aaCastMs(name)
                    if ms == nil or ms < 100 then
                        local id = 0
                        if api.resolveTargetId then
                            id = tonumber(api.resolveTargetId(a.target, a.cls)) or 0
                        end
                        if id <= 0 then id = meId end
                        if id > 0 and not buffAlreadyUp(name, meId > 0 and meId or id) then
                            cands[#cands + 1] = { kind = 'aa', name = name, entry = a, id = id }
                        end
                    end
                end
            end
        end
        for name, it in pairs(loadout.items or {}) do
            if it and it.enabled == true and it.pct == nil then
                local role = roleOf(it)
                if not coldOrSurvival(role) then
                    local probe = { kind = 'item', name = name, entry = it }
                    if candidateInstant(probe) then
                        local id = 0
                        if api.resolveTargetId then
                            id = tonumber(api.resolveTargetId(it.target, it.cls)) or 0
                        end
                        if id <= 0 then id = meId end
                        local gateName = name
                        if runtime.itemBuffSpell then
                            local sp = runtime.itemBuffSpell(name, it) or ''
                            if sp ~= '' then gateName = sp end
                        elseif runtime.itemClickSpell then
                            local sp = runtime.itemClickSpell(name, it) or ''
                            if sp ~= '' then gateName = sp end
                        elseif it.spell and it.spell ~= '' then
                            gateName = it.spell
                        end
                        if id > 0 and not buffAlreadyUp(gateName, meId > 0 and meId or id) then
                            cands[#cands + 1] = { kind = 'item', name = name, entry = it, id = id }
                        end
                    end
                end
            end
        end
        return fireMeleeDump(cands, casting)
    end
end

return M
