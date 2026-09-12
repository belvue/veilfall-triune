-- VF: cast handoff — gem channel (queued) + instant AA channel (fire beside). docs/PLUGIN_AUDIT.md

local mq = require('mq')

local M = {}

local ROTATION_PRI = 100

function M.install(runtime, deps)
    local getCtrl = deps.ctrl or function() return nil end
    local getTracker = deps.castTracker or function() return nil end
    local getLoadout = deps.getLoadout or function() return nil end
    local st = {
        pending = false, name = nil, startedAt = 0, priority = nil, sung = false,
        landOn = 0, restoreTarget = 0, clearAfter = false, restoreDone = false,
        stickPaused = false,
    }
    runtime.castState = st

    local function castingId()
        local id = 0
        pcall(function() id = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
        return id
    end

    local function currentTarget()
        local id = 0
        pcall(function() id = tonumber(mq.TLO.Target.ID()) or 0 end)
        return id
    end

    -- VF: MQ2Cast optional for clickies — /use <name> is the client fallback.
    local function mq2castLoaded()
        local ok, loaded = pcall(function()
            local p = mq.TLO.Plugin('mq2cast') or mq.TLO.Plugin('MQ2Cast')
            if p and p() and p.IsLoaded and p.IsLoaded() then return true end
            return false
        end)
        return ok and loaded == true
    end

    runtime.mq2castLoaded = mq2castLoaded

    runtime.itemUseCmd = function(name)
        name = tostring(name or ''):gsub('"', '')
        if name == '' then return nil end
        return string.format('/use "%s"', name)
    end

    local function castStatus()
        local s = ''
        pcall(function()
            local v = mq.TLO.Cast and mq.TLO.Cast.Status()
            if v ~= nil and v ~= false then s = tostring(v) end
        end)
        if s == 'nil' then s = '' end
        return s
    end

    local function barBusy()
        -- VF: a held song bar keeps Casting.ID. Treating that as busy froze every later
        -- VF: buff and refreshed standCastUntil so the bard never walked (server rule 3).
        if runtime.songBarHeld and runtime.songBarHeld() then return false end
        if castingId() > 0 then return true end
        local s = castStatus()
        return s ~= '' and s ~= 'I'
    end

    local function aimAt(id)
        id = tonumber(id) or 0
        if id <= 0 then return true end
        if currentTarget() == id then return true end
        mq.cmdf('/target id %d', math.floor(id))
        return true
    end

    -- VF: Stick policy (cast-only — do not drive stick elsewhere for casting):
    -- VF: must-stand cast (not sung / bardCastSkill) → /stick pause → cast → settle
    -- VF: (success/fizzle/resist/…) → /stick unpause. Sung/move-cast: leave stick alone.
    -- VF: Gate on spell skill via castingMustStand / gemIsSung — not g.cls == 'Brd'.
    -- VF: Today pause is still unconditional on gem channel; tighten to must-stand later.
    local function stickPause()
        if st.stickPaused then return end
        pcall(function()
            if mq.TLO.Stick and (mq.TLO.Stick.Active() or mq.TLO.Stick.Status() == 'ON') then
                mq.cmd('/stick pause')
                st.stickPaused = true
            end
        end)
    end

    local function stickUnpause()
        if not st.stickPaused then return end
        st.stickPaused = false
        pcall(function()
            if mq.TLO.Stick and tostring(mq.TLO.Stick.Status() or '') == 'PAUSED' then
                mq.cmd('/stick unpause')
            end
        end)
    end

    -- VF: put combat Target back as soon as the cast has started (not at settle).
    local function restoreAim()
        if st.restoreDone then return end
        st.restoreDone = true
        local id = tonumber(st.restoreTarget) or 0
        local clear = st.clearAfter
        st.restoreTarget = 0
        st.landOn = 0
        st.clearAfter = false
        if id > 0 then
            if currentTarget() ~= id then
                mq.cmdf('/target id %d', math.floor(id))
            end
            return
        end
        -- VF: started with no Target — put it back to empty after landOn.
        if clear and currentTarget() > 0 then
            mq.cmd('/target clear')
        end
    end

    local function clear(out)
        local tracker = getTracker()
        local name = st.name
        out = out or 'CAST_SUCCESS'
        if out == 'CAST_SUCCESS' then
            if tracker and tracker.recordSuccess then tracker.recordSuccess(name) end
            if tracker then tracker.activeSpell = nil; tracker.failed = false end
        else
            if tracker then tracker.failed = true; tracker.activeSpell = nil end
        end
        print(string.format('\ag[VF]\ax cast %s -> %s', tostring(name), out))
        st.pending = false
        st.name = nil
        st.priority = nil
        st.sung = false
        restoreAim()
        stickUnpause()
    end

    -- VF: the panic floor is the loadout's, not a setting. It is the highest HP% of
    -- VF: any live Panic row, so "am I in panic" and "will a Panic row fire" cannot
    -- VF: disagree. There was a ctrl.panic_heal_pct knob; it was a second answer.
    local panicAt, panicFrom = 0, nil
    function runtime.underPanicFloor()
        local lo = getLoadout()
        if type(lo) ~= 'table' then return false end
        -- VF: recompute only when the loadout table is swapped (reload writes a new one).
        if lo ~= panicFrom then
            panicFrom, panicAt = lo, 0
            for _, bucket in ipairs({ lo.gems, lo.items, lo.aas }) do
                if type(bucket) == 'table' then
                    for _, row in pairs(bucket) do
                        if type(row) == 'table'
                            and (runtime.castRole and runtime.castRole(row)) == 'Panic' then
                            local pct = tonumber(row.pct) or 0
                            if pct > panicAt then panicAt = pct end
                        end
                    end
                end
            end
        end
        if panicAt <= 0 then return false end
        local hp = 100
        pcall(function() hp = tonumber(mq.TLO.Me.PctHPs()) or 100 end)
        return hp <= panicAt
    end

    function runtime.castPriority(entry)
        if not entry then return nil end
        local p = runtime.castPriorityOf and runtime.castPriorityOf(entry) or nil
        if p == nil then return nil end
        if p > 0 and runtime.underPanicFloor() then
            local role = runtime.castRole and runtime.castRole(entry) or nil
            if role == 'Heal' or role == 'Tap' then return 0 end
        end
        return p
    end

    function runtime.castCanPreempt(entry)
        if not st.pending and not barBusy() then return true end
        local newP = runtime.castPriority(entry)
        if newP == nil then return false end
        local cur = st.priority
        if cur == nil then cur = ROTATION_PRI end
        return newP < cur
    end

    function runtime.castBusy()
        return st.pending or barBusy()
    end

    function runtime.castTiming()
        local t = 0
        pcall(function() t = tonumber(mq.TLO.Cast.Timing()) or 0 end)
        return t
    end

    -- VF: local aim/restore for the AA channel — never touch gem-channel st.restore*.
    local function aimPressRestore(landOn, restore, clearAfter, pressFn)
        local cur = currentTarget()
        local willAim = landOn > 0 and cur ~= landOn
        if willAim then aimAt(landOn) end
        pressFn()
        if restore > 0 then
            if currentTarget() ~= restore then aimAt(restore) end
        elseif (clearAfter or (willAim and restore <= 0)) and currentTarget() > 0 then
            mq.cmd('/target clear')
        end
    end

    -- VF: opts.landOn = spawn the spell must hit; opts.restoreTarget = put Target back after (default: current if different).
    -- VF: instant alt = AA channel (fire beside gem; no pending). Cast-time alt/gem share the spell channel.
    function runtime.castStart(opts)
        opts = opts or {}
        local name = opts.name
        if not name or name == '' then return false end
        local newP = opts.priority
        if newP ~= nil then newP = tonumber(newP) end
        local kind = opts.kind or 'gem'

        -- VF: AA channel — /alt act beside an in-flight gem; no queue, no preempt, no pending.
        if kind == 'alt' and opts.instant and opts.aaId then
            local cur = currentTarget()
            local landOn = tonumber(opts.landOn or opts.targetId) or 0
            local restore = tonumber(opts.restoreTarget)
            if restore == nil then
                if landOn > 0 and cur > 0 and cur ~= landOn then
                    restore = cur
                else
                    restore = 0
                end
            end
            restore = restore or 0
            local willAim = landOn > 0 and cur ~= landOn
            local clearAfter = willAim and restore <= 0
            aimPressRestore(landOn, restore, clearAfter, function()
                mq.cmdf('/alt act %d', math.floor(tonumber(opts.aaId) or 0))
            end)
            local tracker = getTracker()
            if tracker then
                tracker.lastSpell = name
                tracker.lastTime = os.clock()
                tracker.failed = false
            end
            local aimTag = landOn > 0 and string.format(' ->#%d', landOn) or ''
            print(string.format('\ag[VF]\ax aa %s%s', name, aimTag))
            return true
        end

        if st.pending or barBusy() then
            local cur = st.priority
            if cur == nil then cur = ROTATION_PRI end
            if newP == nil or newP >= cur then return false end
            print(string.format('\ay[VF]\ax cast preempt — %s', name))
            mq.cmd('/interrupt')
            mq.cmd('/stopcast')
            -- VF: hand the combat target back before the next aim.
            restoreAim()
            stickUnpause()
            st.pending = false
            st.name = nil
            st.priority = nil
            st.sung = false
            st.restoreDone = false
        end

        local cur = currentTarget()
        local landOn = tonumber(opts.landOn or opts.targetId) or 0
        local restore = tonumber(opts.restoreTarget)
        if restore == nil then
            if landOn > 0 and cur > 0 and cur ~= landOn then
                restore = cur
            else
                restore = 0
            end
        end
        -- VF: restore=0 + will aim ⇒ clear Target after (had no target).
        local willAim = landOn > 0 and cur ~= landOn
        local clearAfter = willAim and (restore or 0) <= 0

        if willAim then
            aimAt(landOn)
        end

        if kind == 'gem' then
            local gem = tonumber(opts.gem)
            if not gem or gem < 1 then return false end
            mq.cmdf('/cast %d', math.floor(gem))
        elseif kind == 'alt' then
            local cmd = string.format('/casting "%s" alt', tostring(name):gsub('"', ''))
            if landOn > 0 then
                cmd = cmd .. string.format(' -targetid|%d', math.floor(landOn))
            end
            mq.cmd(cmd)
        elseif kind == 'item' then
            -- VF: clickies use /use — MQ2Cast /casting item is optional and often a no-op here.
            local cmd = runtime.itemUseCmd(name)
            if not cmd then return false end
            mq.cmd(cmd)
        else
            return false
        end

        -- VF: only a must-stand cast pauses stick. A sung row keeps walking (server rule 1).
        if not opts.sung then stickPause() end

        st.pending = true
        st.sung = not not opts.sung
        st.name = name
        st.priority = newP
        st.landOn = landOn
        st.restoreTarget = restore or 0
        st.clearAfter = clearAfter
        st.restoreDone = false
        st.startedAt = os.clock()

        -- VF: snap combat Target back as soon as the bar is up -- do not sit on landOn for the whole cast.
        local wait = 0
        while not barBusy() and wait < 100 do
            mq.delay(10)
            wait = wait + 10
        end
        restoreAim()

        local tracker = getTracker()
        if tracker then
            tracker.lastSpell = name
            tracker.lastTime = st.startedAt
            tracker.failed = false
            tracker.activeSpell = name
        end

        local priTag = newP ~= nil and string.format(' [p%d]', newP) or ''
        local aimTag = landOn > 0 and string.format(' ->#%d', landOn) or ''
        print(string.format('\ag[VF]\ax casting %s%s%s', name, priTag, aimTag))
        return true
    end

    function runtime.castTick()
        if not st.pending then return end
        -- VF: backup snap if press-time poll missed the bar.
        if barBusy() or (os.clock() - (st.startedAt or 0)) >= 0.05 then
            restoreAim()
        end
        local age = os.clock() - (st.startedAt or 0)
        if barBusy() then
            -- VF: songs do not need a stand hold. Refreshing it here parked the ranger.
            if not st.sung then
                local ms = runtime.castTiming()
                runtime.standCastUntil = os.clock() + ((ms > 0 and ms / 1000.0) or 0.35) + 0.15
            end
            return
        end
        if age < 0.25 then return end
        clear('CAST_SUCCESS')
    end

    function runtime.castDiag()
        print(string.format(
            '\ag[VF]\ax castdiag: pending=%s name=%s pri=%s landOn=%d restore=%d clear=%s restored=%s curTarget=%d status=%s castingId=%d',
            tostring(st.pending), tostring(st.name), tostring(st.priority),
            tonumber(st.landOn) or 0, tonumber(st.restoreTarget) or 0,
            tostring(st.clearAfter), tostring(st.restoreDone),
            currentTarget(), castStatus(), castingId()))
    end

    function runtime.castEnabled()
        return true
    end
end

return M
