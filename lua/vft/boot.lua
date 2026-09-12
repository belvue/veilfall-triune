-- VF: plugin/data/ini at load and character change. tick() only re-issues if something dropped.

local mq = require('mq')

local M = {}

function M.loadData(cfg, scriptDir)
    local data = { era_expansion = 5, spells = {}, discs = {}, aas = {} }
    local paths = {
        (cfg or '.') .. '/vft_data.lua',
        (cfg or '.') .. '/ta_data.lua',
        (cfg or '.') .. '/triune_data.lua',
    }
    pcall(function()
        if scriptDir then
            paths[#paths + 1] = scriptDir .. 'vft_data.lua'
            paths[#paths + 1] = scriptDir .. 'ta_data.lua'
            paths[#paths + 1] = scriptDir .. '../config/vft_data.lua'
            paths[#paths + 1] = scriptDir .. '../config/ta_data.lua'
        end
        if mq.luaDir then
            paths[#paths + 1] = mq.luaDir .. '/vft_data.lua'
            paths[#paths + 1] = mq.luaDir .. '/ta_data.lua'
        end
    end)
    for i = 1, #paths do
        local f = loadfile(paths[i])
        if f then
            local ok, t = pcall(f)
            if ok and type(t) == 'table' and t.spells then
                return t, true
            end
        end
    end
    return data, false
end

function M.install(runtime, deps)
    deps = deps or {}
    local stickLoaded = deps.stickLoaded or function() return false end
    local navLoaded = deps.navLoaded or function() return false end
    local getCtrl = deps.ctrl or function() return nil end

    runtime.STICK_SETTINGS = {
        'heading fast',
        'useback off',
        'stucklogic on',
        'trytojump on',
        'turnhalf on',
        'delaystrafe on',
        'breakonhit off',
        'breakontarget off',
        -- VF: default BreakKB ends /stick on WASD. Keep pulling; EQ still accepts the key.
        'breakonkb off',
        -- VF: off -- Casting.ID on non-BRD (songs/held bar) parked stick ON with no walk. docs/COMBAT_ENGAGED_FLOW.md
        'autopause off',
        'autoUW on',
        'usefleeing on',
        'totalsilence on',
    }

    local st = { moveAt = 0, navAt = 0, danAt = 0 }
    runtime.bootState = st

    function runtime.stickRequire(mayDelay)
        if stickLoaded() then return true end
        local now = os.clock()
        if not mayDelay and (now - (st.moveAt or 0)) < 30 then return false end
        st.moveAt = now
        pcall(function() mq.cmd('/plugin mq2moveutils load') end)
        if mayDelay then pcall(function() mq.delay(750) end) end
        if stickLoaded() then
            print('\ag[VF]\ax MQ2MoveUtils loaded.')
            return true
        end
        print('\ar[VF]\ax MQ2MoveUtils is required and did not load. Set mq2moveutils=1 in MacroQuest.ini.')
        return false
    end

    function runtime.stickPush()
        local ctrl = getCtrl()
        if not ctrl then return end
        if not stickLoaded() then
            if not runtime.stickWarned then
                runtime.stickWarned = true
                print('\ar[VF]\ax MQ2MoveUtils not loaded -- combat movement is degraded.')
            end
            return
        end
        if (mq.TLO.Me.ID() or 0) == 0 then return end
        for _, s in ipairs(runtime.STICK_SETTINGS) do
            pcall(function() mq.cmdf('/stick set %s', s) end)
        end
        runtime.stickPushedAt = os.clock()
        print(string.format('\ag[VF]\ax MoveUtils configured (%d settings, position %s).',
            #runtime.STICK_SETTINGS, tostring(ctrl.stick_position or 'Any')))
    end

    function runtime.navRequire(mayDelay)
        if navLoaded() then return true end
        local now = os.clock()
        if not mayDelay and (now - (st.navAt or 0)) < 30 then return false end
        st.navAt = now
        pcall(function() mq.cmd('/plugin MQ2Nav') end)
        if mayDelay then pcall(function() mq.delay(400) end) end
        if navLoaded() then
            print('\ag[VF]\ax MQ2Nav loaded.')
            return true
        end
        print('\ar[VF]\ax MQ2Nav is required and did not load.')
        return false
    end

    local function danNetLoaded()
        local ok = false
        pcall(function()
            local p = mq.TLO.Plugin('MQ2DanNet') or mq.TLO.Plugin('mq2dannet')
            ok = p and p.IsLoaded and p.IsLoaded()
        end)
        if ok then return true end
        pcall(function()
            local n = mq.TLO.DanNet and mq.TLO.DanNet.Name and mq.TLO.DanNet.Name()
            ok = n ~= nil and n ~= '' and n ~= 'NULL'
        end)
        return ok and true or false
    end

    local function danNetInAll()
        local joined = ''
        pcall(function() joined = tostring(mq.TLO.DanNet.Joined() or '') end)
        joined = '|' .. joined:lower() .. '|'
        return joined:find('|all|', 1, true) ~= nil
    end

    -- VF: session join only. Class channels auto-join on plugin load.
    function runtime.danNetJoin()
        if not danNetLoaded() then return end
        if danNetInAll() then return end
        pcall(function() mq.cmd('/djoin all') end)
        print('\ag[VF]\ax DanNet joined all.')
    end

    function runtime.danNetRequire(mayDelay)
        if danNetLoaded() then
            runtime.danNetJoin()
            return true
        end
        local now = os.clock()
        if not mayDelay and (now - (st.danAt or 0)) < 30 then return false end
        st.danAt = now
        pcall(function() mq.cmd('/plugin mq2dannet load') end)
        if mayDelay then pcall(function() mq.delay(400) end) end
        if danNetLoaded() then
            print('\ag[VF]\ax MQ2DanNet loaded.')
            runtime.danNetJoin()
            return true
        end
        print('\ar[VF]\ax MQ2dannet not found')
        return false
    end

    -- VF: loading or reloading a plugin DLL is the one crash-class thing we do, and a
    -- VF: pcall around mq.cmd does NOT catch a native AV -- so this gate is the only
    -- VF: protection. Self-arming: any tick spent zoning or without a character pushes
    -- VF: the settle out, which covers char select and the window after Zoning clears
    -- VF: where plugin TLOs still read absent and we would "re-load" them.
    -- VF: NOT buffZoneSettleUntil -- buff.lua consumes and zeroes that one.
    local WORLD_SETTLE = 3
    function runtime.worldReady()
        local live = false
        pcall(function()
            if mq.TLO.Me.Zoning() then return end
            if (tonumber(mq.TLO.Me.ID()) or 0) <= 0 then return end
            live = true
        end)
        if not live then
            runtime.worldSettleUntil = os.clock() + WORLD_SETTLE
            return false
        end
        return os.clock() >= (runtime.worldSettleUntil or 0)
    end

    -- VF: delay only here. tick() must not mq.delay.
    function runtime.bootEnter()
        runtime.stickRequire(true)
        runtime.navRequire(true)
        if runtime.meleeRequire then runtime.meleeRequire(true) end
        if runtime.aaSpendRequire then runtime.aaSpendRequire() end
        runtime.stickPush()
        if not runtime.danNetRequire(true) then return false end
        -- VF: deferred, not skipped. This is the call that issues /melee reload, and
        -- VF: AutoRun fires bootEnter at world enter -- i.e. a DLL swap while the zone
        -- VF: is still settling. bootTick performs it once worldReady.
        runtime.meleeSyncForce = true
        if runtime.reloadSafeZones then runtime.reloadSafeZones() end
        -- VF: corpse clutter after every /lua run vf and char enter.
        pcall(function() mq.cmd('/hidecorpse looted') end)
    end

    function runtime.bootTick()
        -- VF: everything in this block touches a plugin DLL or /melee reload. Zone-in is
        -- VF: when the requires misfire, because the TLOs read absent mid-transition.
        if not runtime.worldReady or runtime.worldReady() then
            if not stickLoaded() then runtime.stickRequire(false) end
            if not navLoaded() then runtime.navRequire(false) end
            if runtime.danNetRequire then runtime.danNetRequire(false) end
            if runtime.meleeRequire and not (runtime.meleeLoaded and runtime.meleeLoaded()) then
                runtime.meleeRequire(false)
            end
            if runtime.meleeSync then
                -- VF: consume bootEnter's deferred force exactly once.
                local force = runtime.meleeSyncForce
                runtime.meleeSyncForce = nil
                runtime.meleeSync(force and true or nil)
            end
        end
        -- VF: outside the gate on purpose -- a file read, nothing native.
        if runtime.reloadSafeZones and (os.clock() - (runtime.safeZonesAt or 0)) > 5 then
            runtime.reloadSafeZones()
        end
    end

    return M
end

return M
