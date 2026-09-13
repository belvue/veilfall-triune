-- VF: OOC state — CombatState ~= COMBAT. Order: debuffs → HP → AA → buffs → mana(sit full→buffs).
-- VF: Poll ~1 Hz; COMBAT aborts immediately; clear → resume PROGRAM (Puller/Rush).

local mq = require('mq')

local M = {}

local OOC_PERIOD = 1.0

function M.install(runtime, api)
    api = api or {}
    -- VF: ctrl is replaced on character change — never cache the table.
    local function getCtrl()
        if type(api.ctrl) == 'function' then return api.ctrl() end
        return api.ctrl
    end

    local function combatRaw()
        if runtime.engineState then return runtime.engineState() end
        local s = 'UNKNOWN'
        pcall(function() s = tostring(mq.TLO.Me.CombatState() or 'UNKNOWN') end)
        return s
    end

    -- VF: daemon state from config/vf_fight.txt. Staleness is "tick stopped
    -- VF: changing", never a clock difference — it is a separate Lua VM.
    -- VF: This was ${VFC.*}; reading a TLO owned by a stopped script crashed the
    -- VF: client (confirmed 2026-09-11). See vft/ipc.lua.
    local ipc = require('vft.ipc')
    local dSeen, dSeenAt, dState, dPollAt = nil, 0, nil, 0

    local function daemonState()
        local now = os.clock()
        if (now - dPollAt) < 0.25 then return dState end
        dPollAt = now
        local tick, state = nil, nil
        local t = ipc.read('fight')
        if t then tick, state = t.tick, t.state end
        if tick == nil then
            dSeen, dState = nil, nil
            return nil
        end
        if tick ~= dSeen then
            dSeen, dSeenAt = tick, now
        elseif (now - dSeenAt) > 2.0 then
            dState = nil
            return nil
        end
        dState = state
        return dState
    end

    runtime.daemonState = daemonState

    -- VF: daemon owns the combat↔OOC edge (leave-dwell stops COOLDOWN flapping
    -- VF: mid-pack). No daemon, or a frozen one, falls back to the raw TLO.
    function runtime.currentState(raw)
        local d = daemonState()
        if d then return (d == 'combat') and 'combat' or 'ooc' end
        raw = raw or combatRaw()
        if raw == 'COMBAT' then return 'combat' end
        return 'ooc'
    end

    function runtime.oocDebuffTick()
        if mq.TLO.Me.Dead() then return false end
        if not runtime.bandCast then return false end
        if not (runtime.selfHasCureableOnBar and runtime.selfHasCureableOnBar()) then
            return false
        end
        return not not runtime.bandCast({ 'Cure' }, 0, true, false, {
            allowMoveGems = true,
            ignoreMinXtar = true,
        })
    end

    local function stopForOoc()
        -- VF: do not /nav stop while Cast pending or Me.Casting — aborts OOC buffs/heals.
        if runtime.castingMustStand and runtime.castingMustStand() then return end
        if runtime.castBusy and runtime.castBusy() then return end
        if api.isCasting and api.isCasting() then return end
        -- VF: Manual attack commit -- never /attack off mid-close.
        if runtime.manualFightArmed or ((tonumber(runtime.manualCommitId) or 0) > 0) then
            return
        end
        -- VF: the commit guard above covers Manual only. This one covers every mode.
        if runtime.attackReleaseOk and not runtime.attackReleaseOk() then return end
        -- VF: travelIgnore/Defend trip must survive OOC stopMoving after combat clears.
        if runtime.travel and runtime.travel.active and runtime.travel.active() then
            return
        end
        if api.stopMoving then api.stopMoving() end
        pcall(function()
            if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
            if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
        end)
    end

    local function modeLabel()
        local ctrl = getCtrl()
        if not ctrl then return 'mode' end
        if ctrl.mode == 'Rush' then return 'Rush' end
        if ctrl.mode == 'Roam' then return 'Roam' end
        return tostring(ctrl.mode or 'mode')
    end

    local function oocNeedHeal()
        local ctrl = getCtrl()
        if not ctrl then return false end
        if ctrl.post_combat_heal == false then return false end
        local target = tonumber(ctrl.post_combat_heal_pct) or 0
        if target <= 0 then return false end
        if mq.TLO.Me.Dead() then return false end
        if runtime.postCombatHealGaveUp then return false end
        if runtime.rushOnTheMove and runtime.rushOnTheMove() then return false end
        local myId = 0
        pcall(function() myId = mq.TLO.Me.ID() or 0 end)
        if myId <= 0 then return false end
        local hp = 100
        if api.pctHP then
            hp = api.pctHP(myId) or 100
        else
            pcall(function() hp = mq.TLO.Me.PctHPs() or 100 end)
        end
        if hp >= target then return false end
        if api.hasSelfHealLoadout and not api.hasSelfHealLoadout() then return false end
        return true
    end

    local function oocNeedBuff()
        local ctrl = getCtrl()
        if not ctrl or ctrl.maintain_buffs == false then return false end
        if mq.TLO.Me.Dead() then return false end
        if runtime.postCombatBuffGaveUp then return false end
        if runtime.rushOnTheMove and runtime.rushOnTheMove() then return false end
        if runtime.castingMustStand and runtime.castingMustStand() then return true end
        if runtime.castBusy and runtime.castBusy() then return true end
        if api.isCasting and api.isCasting() then return true end
        if runtime.hasMissingSelfBuff then return runtime.hasMissingSelfBuff() end
        return false
    end

    local function oocManaStartPct()
        local ctrl = getCtrl()
        if not ctrl then return nil end
        -- VF: Med Break mana threshold when that toggle is on.
        if ctrl.medbreak_enabled and ctrl.medbreak_mana_on then
            return tonumber(ctrl.medbreak_mana_start) or 20
        end
        -- VF: one owner. min_mana_pct is the CAST floor, not a rest trigger --
        -- VF: reading it here meant raising the floor also made us sit more. The
        -- VF: per-zone route pack mana was a third owner and is gone.
        local rest = tonumber(ctrl.rest_mana_pct) or 0
        if rest > 0 then return rest end
        return nil
    end

    local function oocManaLow()
        local maxMana, mana = 0, 100
        pcall(function()
            maxMana = tonumber(mq.TLO.Me.MaxMana()) or 0
            mana = tonumber(mq.TLO.Me.PctMana()) or 100
        end)
        if maxMana <= 0 then return false end
        if runtime.oocManaSit then return mana < 100 end
        local startAt = oocManaStartPct()
        if not startAt then return false end
        return mana <= startAt
    end

    local function oocSitMana()
        runtime.oocManaSit = true
        runtime.medBreakActive = true
        stopForOoc()
        pcall(function()
            if not mq.TLO.Me.Sitting() and not mq.TLO.Me.Ducking()
                and not mq.TLO.Me.Combat() and not mq.TLO.Me.Moving()
                and not (api.isMoveActive and api.isMoveActive()) then
                mq.cmd('/sit')
            end
        end)
    end

    local function oocStandFromMana()
        if not runtime.oocManaSit and not runtime.medBreakActive then return end
        runtime.oocManaSit = false
        runtime.medBreakActive = false
        runtime.oocRecheckBuffs = true
        pcall(function()
            if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
        end)
        print('\ag[VF]\ax OOC mana full -- recheck buffs.')
    end

    function runtime.oocOnEnterCombat()
        if runtime.oocManaSit or runtime.medBreakActive then
            runtime.oocManaSit = false
            if not (getCtrl() and getCtrl().medbreak_enabled and runtime.routeManaSit) then
                runtime.medBreakActive = false
            end
            pcall(function()
                if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
            end)
        end
        if runtime.oocBusy then
            print('\ay[VF]\ax OOC aborted -- CombatState COMBAT.')
        end
        runtime.postCombatHealActive = false
        runtime.postCombatBuffActive = false
        runtime.oocBusy = false
        runtime.oocRecheckBuffs = false
        runtime.oocForcePass = false
    end

    -- VF: Enter OOC and hold PROGRAM until one recovery pass finishes.
    function runtime.oocEnter(reason)
        runtime.postCombatHealGaveUp = nil
        runtime.postCombatBuffGaveUp = nil
        runtime.oocForcePass = true
        runtime.oocLastAt = 0
        if runtime.invalidateBarCache then runtime.invalidateBarCache() end
        if not runtime.oocBusy then
            runtime.oocBusy = true
            print('\ay[VF]\ax OOC -- ' .. tostring(reason or 'enter')
                .. '; holding ' .. modeLabel() .. '.')
        end
    end

    -- VF: true when HP / mana / buffs actually need a hold. Empty pass is not a pause.
    local function oocNeedsHold()
        if oocNeedHeal() or oocNeedBuff() or oocManaLow() then return true end
        if runtime.postCombatHealActive or runtime.postCombatBuffActive then return true end
        if runtime.oocManaSit then return true end
        if api.isCasting and api.isCasting() then return true end
        if runtime.castBusy and runtime.castBusy() then return true end
        if runtime.castingMustStand and runtime.castingMustStand() then return true end
        return false
    end

    -- VF: CombatState left COMBAT. Hold PROGRAM only if recovery is actually owed.
    function runtime.oocOnLeaveCombat()
        -- VF: Burn is session-only; never carry into the next pull.
        local c = getCtrl()
        if c and c.burn then
            c.burn = false
            print('\ag[VF]\ax Burn mode auto-disabled (combat ended).')
        end
        if runtime.resetBurnMultiline then runtime.resetBurnMultiline() end
        if runtime.meleeStickSuppressed then
            runtime.meleeStickSuppressed = false
        end
        if oocNeedsHold() then
            runtime.oocEnter('CombatState left COMBAT')
        end
    end

    -- VF: /lua run vf while already idle — same OOC pass as end-of-fight.
    function runtime.oocOnStartup()
        if runtime.currentState() == 'combat' then return end
        runtime.oocEnter('startup, not COMBAT')
    end

    local function oocMarkBusy()
        if not runtime.oocBusy then
            runtime.oocBusy = true
            print('\ay[VF]\ax OOC -- holding ' .. modeLabel() .. ' until recovery done.')
        end
        return true
    end

    local function oocMarkClear()
        if runtime.oocBusy then
            runtime.oocBusy = false
            runtime.oocForcePass = false
            print('\ag[VF]\ax OOC clear -- resume ' .. modeLabel() .. '.')
        end
        return false
    end

    local function oocServicing()
        if runtime.oocForcePass then return true end
        if runtime.postCombatHealActive or runtime.postCombatBuffActive then return true end
        if runtime.oocManaSit or runtime.oocRecheckBuffs then return true end
        if api.isCasting and api.isCasting() then return true end
        if runtime.castBusy and runtime.castBusy() then return true end
        if runtime.castingMustStand and runtime.castingMustStand() then return true end
        return false
    end

    -- VF: the one "is recovery outstanding" answer. enginestate.recoveryOutstanding
    -- VF: was a second implementation that only fed /vf state and could disagree.
    function runtime.oocOutstanding()
        if runtime.oocBusy then return true, 'oocBusy' end
        if oocServicing() then return true, 'servicing' end
        if oocNeedBuff() then return true, 'missing buff' end
        return false, ''
    end

    -- VF: run one OOC pass. true = hold PROGRAM; false = COMBAT took over or recovery clear.
    local function oocRunPipeline()
        runtime.oocLastAt = os.clock()
        runtime.oocForcePass = false

        -- 1. Debuffs (stub)
        if runtime.oocDebuffTick() then return oocMarkBusy() end

        -- 2. HP — post_combat_heal_pct (gem Below % ignored while active; see selfHealCondOk)
        local ctrl = getCtrl()
        if oocNeedHeal() then
            if not runtime.postCombatHealActive then
                runtime.postCombatHealActive = true
                local maxSec = tonumber(ctrl and ctrl.post_combat_heal_max_sec) or 45
                runtime.postCombatHealUntil = os.clock() + math.max(maxSec, 5)
                runtime.postCombatHealLastReason = nil
                print(string.format('\ay[VF]\ax OOC heal -- to %d%% HP.',
                    tonumber(ctrl and ctrl.post_combat_heal_pct) or 90))
            elseif (runtime.postCombatHealUntil or 0) > 0
                and os.clock() > runtime.postCombatHealUntil then
                runtime.postCombatHealGaveUp = true
                runtime.postCombatHealActive = false
                runtime.postCombatHealUntil = 0
                print('\ay[VF]\ax OOC heal timed out'
                    .. (runtime.healBlockReason and (' (' .. tostring(runtime.healBlockReason) .. ')') or '')
                    .. '.')
            end
            if runtime.postCombatHealActive then
                stopForOoc()
                pcall(function()
                    if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
                end)
                local fired = false
                if runtime.postCombatHealTick then
                    fired = runtime.postCombatHealTick() and true or false
                end
                if not fired and runtime.healBlockReason
                    and runtime.healBlockReason ~= runtime.postCombatHealLastReason then
                    runtime.postCombatHealLastReason = runtime.healBlockReason
                    print('\ay[VF]\ax OOC heal wait -- ' .. tostring(runtime.healBlockReason))
                end
                return oocMarkBusy()
            end
        elseif runtime.postCombatHealActive then
            runtime.postCombatHealActive = false
            runtime.postCombatHealUntil = 0
            print('\ag[VF]\ax OOC heal complete.')
        end

        -- 3. AA Spend
        if runtime.aaSpendTick then runtime.aaSpendTick() end

        -- 4. Buffs (also after mana-full recheck)
        if runtime.oocRecheckBuffs then runtime.oocRecheckBuffs = false end
        if oocNeedBuff() then
            if not runtime.postCombatBuffActive then
                runtime.postCombatBuffActive = true
                runtime.postCombatBuffUntil = os.clock() + 45
                stopForOoc()
                print('\ay[VF]\ax OOC buff -- missing self buffs.')
            elseif (runtime.postCombatBuffUntil or 0) > 0 and os.clock() > runtime.postCombatBuffUntil then
                runtime.postCombatBuffGaveUp = true
                runtime.postCombatBuffActive = false
                print('\ay[VF]\ax OOC buff timed out.')
                return oocMarkClear()
            end
            if runtime.postCombatBuffActive then
                stopForOoc()
                if runtime.buffTick then runtime.buffTick() end
                return oocMarkBusy()
            end
        elseif runtime.postCombatBuffActive then
            if (runtime.castBusy and runtime.castBusy())
                or (api.isCasting and api.isCasting()) then
                stopForOoc()
                return oocMarkBusy()
            end
            if runtime.castingMustStand and runtime.castingMustStand() then
                stopForOoc()
                return oocMarkBusy()
            end
            runtime.postCombatBuffActive = false
            runtime.standCastUntil = 0
            print('\ag[VF]\ax OOC buff complete.')
        end

        if runtime.castingMustStand and runtime.castingMustStand() then
            runtime.standHoldSince = runtime.standHoldSince or os.clock()
            if (os.clock() - runtime.standHoldSince) < 10 then
                stopForOoc()
                return oocMarkBusy()
            end
            runtime.standCastUntil = 0
        else
            runtime.standHoldSince = nil
        end

        -- 5. Mana — sit until full, then buffs again next pass
        if oocManaLow() then
            if not runtime.oocManaSit then
                local at = oocManaStartPct() or 0
                print(string.format('\ay[VF]\ax OOC mana -- sit at <=%d%% until full.', at))
            end
            oocSitMana()
            return oocMarkBusy()
        end
        if runtime.oocManaSit then
            oocStandFromMana()
            return oocMarkBusy()
        end

        return oocMarkClear()
    end

    -- VF: true = OOC owns tick (hold Puller/Rush). false = go combat or resume mode.
    function runtime.oocTick()
        -- VF: COMBAT wins every call — do not wait for the 1s OOC poll.
        if runtime.currentState() == 'combat' then
            if runtime.oocBusy or runtime.oocManaSit or runtime.postCombatHealActive
                or runtime.postCombatBuffActive then
                runtime.oocOnEnterCombat()
            end
            return false
        end
        if mq.TLO.Me.Dead() then return oocMarkClear() end
        -- VF: Rush in transit owns move; OOC only between fights / startup.
        if runtime.rushOnTheMove and runtime.rushOnTheMove() then return false end

        -- VF: HP/mana/buffs already good — do not sit on a 1s OOC poll.
        if (runtime.oocBusy or runtime.oocForcePass) and not oocNeedsHold() then
            return oocMarkClear()
        end

        -- VF: leave-combat / zone / startup hold PROGRAM; idle missing buffs just click, no hold.
        if not runtime.oocBusy and not oocServicing() then
            if oocNeedBuff() then
                local now = os.clock()
                if (now - (runtime.oocIdleBuffAt or 0)) >= OOC_PERIOD then
                    runtime.oocIdleBuffAt = now
                    if runtime.buffTick then runtime.buffTick() end
                end
            end
            return false
        end

        local now = os.clock()
        if oocServicing() then
            return oocRunPipeline()
        end

        if runtime.oocManaSit then oocSitMana() end
        if (now - (runtime.oocLastAt or 0)) < OOC_PERIOD then
            return true
        end
        return oocRunPipeline()
    end
end

return M
