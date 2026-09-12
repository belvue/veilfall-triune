-- VF: AA purchase: TA owns the queue + ini, MQ2AASpend owns execution.

local mq = require('mq')

local M = {}

-- VF: AutoSpend follows the Enable checkbox. On, the plugin also buys on its own AA-gain /
-- VF: level / cap triggers, which is fine (buying is instant), and TA's idle nudge drains any standing bank on top.
local function settingsFor(autoOn)
    return {
        AutoSpend = autoOn and '1' or '0',
        BruteForce = '0',
        BruteForceBonusFirst = '0',
        BankPoints = '0',
    }
end
local OURS = { AutoSpend = true, BruteForce = true, BruteForceBonusFirst = true, BankPoints = true }

local SEC_SET = 'MQ2AASpend_Settings'
local SEC_LIST = 'MQ2AASpend_AAList'

function M.install(runtime, deps)
    deps = deps or {}
    -- VF: loadout is rebuilt on character change, so hold a getter, never the table.
    local getLoadout = deps.getLoadout or function() return deps.loadout end
    local cfg = deps.cfg or (mq.configDir or '.')

    local st = {
        sig = nil, nudgeAt = 0, pruneAt = 0, warnAt = 0, armed = false,
        wasIdle = false, oocDone = false, drain = false, pendingCheck = false, ptsBefore = 0,
    }
    runtime.aaSpendState = st

    -- VF: character change moves the ini path, so the written-signature cache must go with it.
    function runtime.aaSpendReset()
        st.sig, st.nudgeAt, st.pruneAt, st.armed = nil, 0, 0, false
        st.wasIdle, st.oocDone, st.drain, st.pendingCheck, st.ptsBefore = false, false, false, false, 0
    end

    local function log(msg)
        pcall(function()
            local f = io.open(cfg .. '/ta_aa.log', 'a')
            if not f then return end
            f:write(string.format('%.2f %s\n', os.clock(), tostring(msg)))
            f:close()
        end)
    end
    runtime.aaLog = log

    -- VF: one AltAbility record per rank; nil when the id resolves to nothing.
    function runtime.aaRecord(idx)
        local rec
        pcall(function()
            rec = mq.TLO.AltAbility(idx)
            if rec and (rec() == nil or tostring(rec()) == 'NULL') then rec = nil end
        end)
        return rec
    end

    function runtime.aaField(rec, key)
        local v
        pcall(function()
            local m = rec[key]
            if m then v = tonumber(m()) end
        end)
        return v or 0
    end

    -- VF: Rank is CurrentRank (ranks owned) and reads the same on every record in the group.
    -- VF: Look up by NAME -- numeric AltAbility takes an Index, so a stored gid reads a different AA.
    function runtime.aaOwnedRank(name)
        local rec = runtime.aaRecord(tostring(name or ''))
        if not rec then return 0, 0 end
        local maxr = runtime.aaField(rec, 'MaxRank')
        return runtime.aaField(rec, 'Rank'), maxr
    end

    -- VF: AA burn when CombatState is not COMBAT (hate). ACTIVE = OOC.
    function runtime.aaIdle()
        local why = nil
        pcall(function()
            local me = mq.TLO.Me
            if me.Dead() then why = 'dead'; return end
            if me.Hovering() then why = 'hovering'; return end
            if me.Combat() then why = '/attack is on'; return end
            if me.AutoFire() then why = 'autofire is on'; return end
            if me.CombatState() == 'COMBAT' then why = "CombatState is 'COMBAT'"; return end
            if (me.Casting.ID() or 0) > 0 then why = 'casting'; return end
        end)
        if not why and runtime.pullerRushing and runtime.pullerRushing() then why = 'Puller Rush is running' end
        return why == nil, why
    end

    function runtime.aaSpendLoaded()
        local on = false
        pcall(function() on = mq.TLO.Plugin('MQ2AASpend').Name() ~= nil end)
        return on
    end

    -- VF: backoff is not optional -- this runs off the main tick, so a missing plugin would
    -- VF: otherwise re-issue /plugin and reprint the warning every frame.
    function runtime.aaSpendRequire()
        if runtime.aaSpendLoaded() then return true end
        local now = os.clock()
        if (now - (st.requireAt or -60)) < 30 then return false end
        st.requireAt = now
        mq.cmd('/plugin MQ2AASpend noauto')
        mq.delay(300, runtime.aaSpendLoaded)
        if not runtime.aaSpendLoaded() then
            print('\ar[VF]\ax MQ2AASpend did not load -- AA autopurchase is off. Set \aymq2aaspend=1\ax in MacroQuest.ini.')
            return false
        end
        return true
    end

    -- VF: same stem as the loadout .lua -- {server}_{char}.ini, which is what the plugin reads.
    function runtime.aaSpendPath()
        local server = (runtime.serverKey and runtime.serverKey()) or 'local'
        local who = (runtime.fileKey and runtime.fileKey(mq.TLO.Me.Name() or 'unknown')) or 'unknown'
        return cfg .. '/' .. server .. '_' .. who .. '.ini'
    end

    local function queueNames(q)
        local out = {}
        if type(q) ~= 'table' or q.auto == false or type(q.items) ~= 'table' then return out end
        for _, it in ipairs(q.items) do
            local n = tostring((type(it) == 'table' and it.name) or it or '')
            if n ~= '' then out[#out + 1] = n end
        end
        return out
    end

    -- VF: order-sensitive -- queue order IS buy priority in the ini. Carries the Enable flag
    -- VF: so unticking it rewrites (AutoSpend flips even though the name list is already empty).
    local function sigOf(names, autoOn)
        return (autoOn and '1|' or '0|') .. #names .. '|' .. table.concat(names, '\1')
    end

    -- VF: rewrite [MQ2AASpend_AAList] whole; keep unknown Settings keys (SpendOrder, Merc*).
    -- VF: The plugin blanks and re-emits both sections on every SaveINI, so TA must be the only writer.
    function runtime.aaSpendWriteIni(names, autoOn)
        local path = runtime.aaSpendPath()
        local SETTINGS = settingsFor(autoOn ~= false)
        local lines, seen = {}, {}
        local f = io.open(path, 'r')
        if f then
            local sec = ''
            for line in f:lines() do
                local hdr = line:match('^%s*%[(.-)%]%s*$')
                if hdr then sec = hdr end
                if sec == SEC_LIST and not hdr then
                    -- VF: drop: rebuilt below.
                elseif sec == SEC_SET and not hdr then
                    local k = line:match('^%s*([^=;%s]+)%s*=')
                    if k and OURS[k] then
                        if not seen[k] then
                            seen[k] = true
                            lines[#lines + 1] = k .. '=' .. SETTINGS[k]
                        end
                    else
                        lines[#lines + 1] = line
                    end
                else
                    lines[#lines + 1] = line
                end
            end
            f:close()
        end
        -- VF: insert any of our keys the file did not already carry, right under the header
        local missing = {}
        for k, v in pairs(SETTINGS) do
            if not seen[k] then missing[#missing + 1] = k .. '=' .. v end
        end
        table.sort(missing)
        if #missing > 0 then
            local at = nil
            for i, line in ipairs(lines) do
                if line:match('^%s*%[' .. SEC_SET .. '%]%s*$') then at = i; break end
            end
            if at then
                for i = #missing, 1, -1 do table.insert(lines, at + 1, missing[i]) end
            else
                lines[#lines + 1] = '[' .. SEC_SET .. ']'
                for _, l in ipairs(missing) do lines[#lines + 1] = l end
            end
        end
        -- VF: keep the list header where it was; append it only if the file never had one
        local hasList = false
        for _, line in ipairs(lines) do
            if line:match('^%s*%[' .. SEC_LIST .. '%]%s*$') then hasList = true; break end
        end
        if not hasList then lines[#lines + 1] = '[' .. SEC_LIST .. ']' end
        local out = {}
        for _, line in ipairs(lines) do
            out[#out + 1] = line
            if line:match('^%s*%[' .. SEC_LIST .. '%]%s*$') then
                -- VF: the |M suffix is mandatory -- LoadAAInfo silently drops entries without it
                for i, n in ipairs(names) do
                    out[#out + 1] = string.format('%d=%s|M', i - 1, n)
                end
            end
        end
        local w = io.open(path, 'w')
        if not w then
            local now = os.clock()
            if (now - (st.writeWarnAt or -60)) > 30 then
                st.writeWarnAt = now
                print('\ar[VF]\ax could not write ' .. path .. ' -- AA autopurchase is off.')
            end
            return false
        end
        w:write(table.concat(out, '\n') .. '\n')
        w:close()
        return true
    end

    -- VF: write + /aaspend load. Returns true when the plugin holds our list.
    function runtime.aaSpendSync(force)
        local lo = getLoadout()
        local q = lo and lo.aa_queue
        local autoOn = not (type(q) == 'table' and q.auto == false)
        local names = queueNames(q)
        local sig = sigOf(names, autoOn)
        if not force and sig == st.sig then return true end
        if not runtime.aaSpendLoaded() then
            if not runtime.aaSpendRequire() then return false end
        end
        if not runtime.aaSpendWriteIni(names, autoOn) then return false end
        mq.cmd('/aaspend load')
        st.sig = sig
        st.armed = autoOn and #names > 0
        log(string.format('sync  autospend=%d %d queued -> %s',
            autoOn and 1 or 0, #names, runtime.aaSpendPath()))
        return true
    end

    -- VF: the plugin never removes finished entries -- it just skips them and burns a list slot,
    -- VF: and the checkbox stays lit.
    function runtime.aaSpendPrune()
        local lo = getLoadout()
        local q = lo and lo.aa_queue
        if type(q) ~= 'table' or type(q.items) ~= 'table' or #q.items == 0 then return 0 end
        local keep, dropped = {}, 0
        for _, it in ipairs(q.items) do
            local name = tostring((type(it) == 'table' and it.name) or it or '')
            local owned, maxr = runtime.aaOwnedRank(name)
            if name ~= '' and maxr >= 1 and owned >= maxr then
                dropped = dropped + 1
                print(string.format('\ag[VF]\ax AA: %s is maxed (%d/%d) -- removed from the queue.', name, owned, maxr))
                log(string.format('maxed %s %d/%d -- dropped', name, owned, maxr))
            else
                keep[#keep + 1] = it
            end
        end
        if dropped > 0 then
            q.items = keep
            lo.aa_queue = q
            if runtime.settings and runtime.settings.reloadAaQueue then
                pcall(runtime.settings.reloadAaQueue, q)
            end
            runtime.aaSpendSync(true)
        end
        return dropped
    end

    -- VF: one /aaspend auto now per OOC entry. Keep going only while points actually drop.
    function runtime.aaSpendNudge(force)
        local lo = getLoadout()
        local q = lo and lo.aa_queue
        if type(q) ~= 'table' or q.auto == false then return false end
        if type(q.items) ~= 'table' or #q.items == 0 then return false end
        local now = os.clock()
        local idle = force or false
        if not force then
            idle = not not select(1, runtime.aaIdle())
        end
        if not idle then
            st.wasIdle, st.oocDone, st.drain, st.pendingCheck = false, false, false, false
            return false
        end
        if not st.wasIdle then
            st.wasIdle = true
            st.oocDone, st.drain, st.pendingCheck = false, false, false
        end
        local pts = 0
        pcall(function() pts = tonumber(mq.TLO.Me.AAPoints()) or 0 end)
        if pts < 1 then
            st.oocDone, st.drain, st.pendingCheck = true, false, false
            return false
        end
        if st.pendingCheck and (now - st.nudgeAt) >= 0.5 then
            st.pendingCheck = false
            if pts < (st.ptsBefore or pts) then
                st.drain = true
            else
                st.oocDone = true
                st.drain = false
            end
        end
        if st.pendingCheck then return false end
        if not force and st.oocDone and not st.drain then return false end
        if not force and (now - st.nudgeAt) < 1.0 then return false end
        if not runtime.aaSpendSync() then return false end
        st.ptsBefore = pts
        st.nudgeAt = now
        st.pendingCheck = not force
        mq.cmd('/aaspend auto now')
        return true
    end

    function runtime.aaSpendTick()
        local lo = getLoadout()
        if type(lo) ~= 'table' or type(lo.aa_queue) ~= 'table' then return end
        runtime.aaSpendSync()
        local now = os.clock()
        local idle = select(1, runtime.aaIdle())
        if idle and (now - st.pruneAt) > 3 then
            st.pruneAt = now
            runtime.aaSpendPrune()
        end
        runtime.aaSpendNudge()
    end

    -- VF: replaces the old TLO chain dump -- the plugin owns trainability now, so ask it.
    function runtime.aaSpendStatus()
        local lo = getLoadout()
        local q = lo and lo.aa_queue
        local names = queueNames(q)
        local pts = 0
        pcall(function() pts = tonumber(mq.TLO.Me.AAPoints()) or 0 end)
        print(string.format('\ag[VF]\ax AA: %s, %d banked, %d queued, plugin %s, ini %s',
            (type(q) == 'table' and q.auto == false) and '\ayDISABLED\ax' or 'enabled',
            pts, #names, runtime.aaSpendLoaded() and 'loaded' or '\arMISSING\ax', runtime.aaSpendPath()))
        local idle, why = runtime.aaIdle()
        if not idle then print('  waiting: ' .. tostring(why)) end
        for i, n in ipairs(names) do
            local owned, maxr = runtime.aaOwnedRank(n)
            print(string.format('  %d. %s  rank %d/%d', i, n, owned, maxr))
        end
        if #names == 0 then
            print('  queue is empty -- check AAs on the Loadout \ayAA Purchase\ax tab.')
        end
        mq.cmd('/aaspend status')
    end

    return M
end

return M
