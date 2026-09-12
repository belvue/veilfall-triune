-- VF: EQ engine mood (Me.CombatState) — not Me.Combat /attack, not combatTick activity.
local mq = require('mq')

local M = {}

function M.install(runtime, deps)
    deps = deps or {}
    -- VF: ctrl is replaced on character change, so hold a getter, never the table.
    local getCtrl = deps.ctrl or function() return nil end

    local st = { seen = {}, last = '', changedAt = 0 }
    runtime.engineStateStats = st
    -- VF: alias — old name from combatstate.lua era.
    runtime.combatStateStats = st

    -- VF: raw Me.CombatState string (COMBAT/RESTING/ACTIVE/…).
    function runtime.engineState()
        local s = 'UNKNOWN'
        pcall(function() s = tostring(mq.TLO.Me.CombatState() or 'UNKNOWN') end)
        st.seen[s] = (st.seen[s] or 0) + 1
        if s ~= st.last then
            local prev = st.last
            st.last, st.changedAt = s, os.clock()
            if runtime.chat then
                runtime.chat.debug('enginestate', 'engineState',
                    string.format('mood %s → %s', (prev ~= '' and prev) or '?', s))
            end
        end
        return s
    end

    -- VF: engine mood == COMBAT. Optional pre-read string = one TLO per tick.
    function runtime.engineInCombat(raw)
        return (raw or runtime.engineState()) == 'COMBAT'
    end

    -- VF: something is ACTUALLY on my hate list, right now. CombatState lags this
    -- VF: by seconds, so engineFightHot cannot answer "am I being attacked".
    -- VF: Band-limited: a hater left behind in another room must not pin us out
    -- VF: of OOC forever.
    local agSeen, agAt = false, 0
    function runtime.aggroOnMe(radius)
        local now = os.clock()
        if (now - agAt) < 0.1 then return agSeen end
        agAt = now
        radius = tonumber(radius) or 100
        local hot = false
        pcall(function()
            local slots = tonumber(mq.TLO.Me.XTargetSlots()) or 0
            for i = 1, math.min(slots, 13) do
                local x = mq.TLO.Me.XTarget(i)
                if x and x() then
                    local tt = tostring(x.TargetType() or '')
                    local id = tonumber(x.ID()) or 0
                    if id > 0 and tt == 'Auto Hater' then
                        local s = mq.TLO.Spawn(id)
                        if s and s() and not s.Dead()
                            and (tonumber(s.Distance3D()) or 9999) <= radius then
                            hot = true
                            return
                        end
                    end
                end
            end
        end)
        agSeen = hot
        return hot
    end
    -- VF: alias — prefer engineInCombat at new call sites.
    runtime.inCombatState = runtime.engineInCombat

    -- VF: melee attack button on? Not engine mood. (AutoFire is Ranged style later.)
    function runtime.isAttackOn()
        local on = false
        pcall(function() on = mq.TLO.Me.Combat() or false end)
        return on
    end

    -- VF: SoT fight-hot for skip-OOC: Me.CombatState COMBAT, or Present group member
    -- VF: within GROUP_ENGINE_NEAR with CombatState COMBAT. Not XTarget / SpawnCount.
    -- VF: EQ→MQ hooks→TLO. Member.CombatState; Spawn fallback if Member lacks the field.
    runtime.GROUP_ENGINE_NEAR = 300

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
            local viaSpawn = spawnCombatState(id)
            if viaSpawn ~= '' then return viaSpawn end
        end
        return cs
    end

    -- VF: true = do not enter OOC hold. Returns true, why ('me'|'group').
    function runtime.engineFightHot(raw)
        if runtime.engineInCombat(raw) then return true, 'me' end
        local near = tonumber(runtime.GROUP_ENGINE_NEAR) or 300
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

    -- VF: "is something hostile on me", not "am I fighting". Targeting input, not state.
    function runtime.hasThreat()
        local n = 0
        if runtime.countPackMobs then
            pcall(function() n = runtime.countPackMobs() or 0 end)
        end
        return n > 0, n
    end

    -- VF: may we heal / buff / sit / spend? COOLDOWN and RESTING are idle.
    function runtime.canIdle(raw)
        local why = nil
        pcall(function()
            local me = mq.TLO.Me
            if me.Dead() then why = 'dead'; return end
            if me.Hovering() then why = 'hovering'; return end
            if (me.Casting.ID() or 0) > 0 then why = 'casting'; return end
        end)
        if not why and runtime.engineInCombat(raw) then why = "engine CombatState is 'COMBAT'" end
        if not why and runtime.pullerRushing and runtime.pullerRushing() then
            why = 'Puller Rush is running'
        end
        if not why and runtime.rushOnTheMove and runtime.rushOnTheMove() then
            why = 'Rush is on the move'
        end
        return why == nil, why
    end

    function runtime.recoveryOutstanding()
        -- VF: ooc.lua owns this decision. What follows is only a fallback for a
        -- VF: boot order where ooc has not installed yet -- do not grow it back
        -- VF: into a second opinion.
        if runtime.oocOutstanding then return runtime.oocOutstanding() end
        local ctrl = getCtrl()
        if not ctrl then return false, '' end
        local want = {}
        local myId = 0
        pcall(function() myId = mq.TLO.Me.ID() or 0 end)

        if myId > 0 and ctrl.post_combat_heal ~= false then
            local target = tonumber(ctrl.post_combat_heal_pct) or 0
            local hp = 100
            pcall(function()
                hp = (runtime.pctHP and runtime.pctHP(myId)) or (mq.TLO.Me.PctHPs() or 100)
            end)
            if target > 0 and hp < target then
                want[#want + 1] = string.format('heal %d<%d', hp, target)
            end
        end

        -- VF: the _stop sliders are the release side of a latch: sit at <= _start, get
        -- VF: up at >= _stop. They were saved and never read, so med was a single
        -- VF: threshold and flapped on the boundary. A _stop at or below _start
        -- VF: degenerates to the old one-threshold behavior, which is the safe default.
        if ctrl.medbreak_enabled then
            local mana, endur = 100, 100
            pcall(function()
                mana = mq.TLO.Me.PctMana() or 100
                endur = mq.TLO.Me.PctEndurance() or 100
            end)
            runtime.medLatch = runtime.medLatch or {}
            local latch = runtime.medLatch
            if ctrl.medbreak_mana_on then
                local startAt = tonumber(ctrl.medbreak_mana_start) or 20
                local stopAt = math.max(tonumber(ctrl.medbreak_mana_stop) or 0, startAt)
                if mana <= startAt then latch.mana = true end
                if latch.mana and mana >= stopAt then latch.mana = false end
                if latch.mana then want[#want + 1] = 'mana ' .. tostring(mana) end
            else
                latch.mana = false
            end
            if ctrl.medbreak_end_on then
                local startAt = tonumber(ctrl.medbreak_end_start) or 20
                local stopAt = math.max(tonumber(ctrl.medbreak_end_stop) or 0, startAt)
                if endur <= startAt then latch.endur = true end
                if latch.endur and endur >= stopAt then latch.endur = false end
                if latch.endur then want[#want + 1] = 'end ' .. tostring(endur) end
            else
                latch.endur = false
            end
        end

        if ctrl.maintain_buffs ~= false and runtime.hasMissingSelfBuff then
            local miss = false
            pcall(function() miss = runtime.hasMissingSelfBuff() end)
            if miss then want[#want + 1] = 'buff' end
        end

        local bank = 0
        pcall(function() bank = tonumber(mq.TLO.Me.AAPoints()) or 0 end)
        if bank > 0 then want[#want + 1] = 'aa ' .. tostring(bank) end

        return #want > 0, table.concat(want, ', ')
    end

    -- VF: four exclusive program states. Pause masks PROGRAM → COMBAT/OOC/IDLE only.
    function runtime.resolveState(raw)
        if runtime.engineInCombat(raw) then return 'combat' end
        if runtime.recoveryOutstanding() then return 'ooc' end
        local ctrl = getCtrl()
        if ctrl and ctrl.running then return 'program' end
        return 'idle'
    end

    function runtime.stateReport()
        local raw = runtime.engineState()
        local threat, n = runtime.hasThreat()
        local idle, why = runtime.canIdle(raw)
        local rec, what = runtime.recoveryOutstanding()
        local ctrl = getCtrl()
        print('\ag[VF engine]\ax')
        print(string.format('  engineState    \ay%s\ax  (held %.1fs)  -- Me.CombatState TLO',
            raw, os.clock() - (st.changedAt or 0)))
        print(string.format('  engineInCombat %s', tostring(raw == 'COMBAT')))
        local fightHot, fightWhy = runtime.engineFightHot(raw)
        print(string.format('  engineFightHot  %s%s  -- Me|group@%d CombatState',
            tostring(fightHot),
            fightWhy and (' (' .. fightWhy .. ')') or '',
            tonumber(runtime.GROUP_ENGINE_NEAR) or 300))
        print(string.format('  isAttackOn     %s  -- Me.Combat() melee button',
            tostring(runtime.isAttackOn())))
        print(string.format('  hasThreat      %s  (%d pack)', tostring(threat), n))
        print(string.format('  canIdle        %s%s', tostring(idle),
            idle and '' or '  -- ' .. tostring(why)))
        print(string.format('  recovery       %s%s', tostring(rec), rec and '  -- ' .. what or ''))
        print(string.format('  resolveState   \ag%s\ax  (running=%s)',
            runtime.resolveState(raw), tostring(ctrl and ctrl.running or false)))
        local seen = {}
        for k, v in pairs(st.seen) do seen[#seen + 1] = string.format('%s=%d', k, v) end
        table.sort(seen)
        print('  seen so far    ' .. table.concat(seen, '  '))
        if not (st.seen['COMBAT'] or st.seen['RESTING'] or st.seen['COOLDOWN']) then
            print('  \ayonly ACTIVE seen -- if that never changes, this client lacks CombatState\ax')
        end
    end

    return M
end

return M
