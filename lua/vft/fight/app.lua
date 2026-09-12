---@diagnostic disable: undefined-global, undefined-field
-- VF: Combat daemon. /lua run vft/fight. Spec: docs/COMBAT_DAEMON.md.
-- VF: Phase 1 is READ-ONLY -- resolve state, publish ${VFC.*}. It must not issue
-- VF: a game command. Targeting/casting land in phases 3-4.

local mq = require('mq')
local chat = require('vft.chat')
local FS = require('vft.fightstate')
local ipc = require('vft.ipc')

local M = {}

-- VF: two rates. Wake is one TLO; resolve runs the machine; scan walks the group.
local PERIOD       = 0.05
local WAKE         = 0.10
local RESOLVE      = 0.25
local SCAN         = 0.50
local LOADER_POLL  = 1.0

-- VF: COOLDOWN lands the instant the last mob dies -- do not flap mid-pack.
-- VF: tune live with /vfc dwell <sec>; pack fighting wants more than solo.
local LEAVE_DWELL  = 2.5
-- VF: stale COMBAT right after a zone is the one case where the TLO lies.
local ZONE_SETTLE  = 2.0
-- VF: dead-man. A headless controller must not outlive the loader.
local LOADER_GRACE = 3.0

-- VF: travel policy overrides mode. initiate = start a fight, commit = answer an
-- VF: attacker, chase = follow it. Pause commits only to what the player armed.
local MODE_POLICY  = {
    Manual = { initiate = false, commit = true, chase = true },
    Roam   = { initiate = true, commit = true, chase = true },
    Rush   = { initiate = true, commit = true, chase = true },
    Group  = { initiate = false, commit = true, chase = true },
}
-- VF: Pause does chase -- `Manual/Pause: near+LoS stick, far travelIgnore` is
-- VF: shipped behavior (vft.lua). It chases only the target you armed.
local PAUSED       = { initiate = false, commit = true, chase = true }
local IGNORE       = { initiate = false, commit = false, chase = false }
local DEFEND       = { initiate = false, commit = true, chase = false }

local st           = {
    run = false,
    state = 'idle',
    why = 'boot',
    raw = 'UNKNOWN',
    hot = false,
    coldSince = 0,
    hotSince = 0,
    groupHot = false,
    mode = 'Manual',
    running = false,
    travel = 'none',
    linked = false,
    zone = '',
    zonedAt = 0,
    sawLoader = false,
    loaderGone = 0,
    tick = 0,
    nextWake = 0,
    nextResolve = 0,
    nextScan = 0,
    nextLoader = 0,
    changes = 0,
    dwell = LEAVE_DWELL,
}

-- VF: loader state from config/vf_ctrl.txt. Missing file = Pause defaults;
-- VF: never guess a mode. This was an ${VF.*} TLO -- see vft/ipc.lua for why
-- VF: that crashed the client and must not come back.
local ctrlCache = nil

local function loaderSays(key)
    local v = ctrlCache and ctrlCache[key]
    if v == nil or v == '' then return nil end
    return v
end

local function readLoader()
    ctrlCache = ipc.read('ctrl')
    st.linked = ctrlCache ~= nil
    st.mode = loaderSays('mode') or 'Manual'
    st.running = st.linked and (loaderSays('running') == 'true') or false
    st.travel = loaderSays('travel') or 'none'
end

function M.policy()
    if st.travel == 'ignore' then return IGNORE, 'travelIgnore' end
    if st.travel == 'defend' then return DEFEND, 'travelDefend' end
    if not st.running then return PAUSED, st.linked and 'paused' or 'no loader' end
    return MODE_POLICY[st.mode] or PAUSED, st.mode
end

-- VF: scan for the loader itself (script name 'vft'), not a satellite path.
local function loaderPid()
    local found = nil
    pcall(function()
        local pids = tostring(mq.TLO.Lua.PIDs() or '')
        for tok in pids:gmatch('%d+') do
            local pid = tonumber(tok)
            local s = pid and mq.TLO.Lua.Script(pid) or nil
            if s then
                local sn = ''
                pcall(function() sn = tostring(s.Name() or '') end)
                if sn:gsub('\\', '/'):lower() == 'vft' then
                    found = pid
                    return
                end
            end
        end
    end)
    return found
end

local function setState(state, why)
    if st.state ~= state then
        st.changes = st.changes + 1
        chat.debug('fight', 'state', string.format('%s -> %s (%s)', st.state, state, why))
    end
    st.state, st.why = state, why
end

local function resolve(now)
    local raw = st.raw
    local hot = (raw == 'COMBAT')

    -- VF: zone settle -- leftover COMBAT on zone-in is not a fight.
    if hot and (now - st.zonedAt) < ZONE_SETTLE then hot = false end

    if hot then
        if not st.hot then st.hotSince = now end
        st.hot, st.coldSince = true, 0
    elseif st.hot then
        -- VF: leave only after the dwell AND an empty bubble.
        if st.coldSince == 0 then st.coldSince = now end
        if (now - st.coldSince) >= (st.dwell or LEAVE_DWELL) and not st.groupHot then
            st.hot, st.coldSince = false, 0
        end
    end

    if st.hot then
        setState('combat', raw == 'COMBAT' and 'CombatState COMBAT' or 'leaving, dwell')
    elseif st.running then
        setState('program', st.mode)
    else
        setState('idle', st.linked and 'paused' or 'no loader')
    end
end

-- VF: strings only, written to config/vf_fight.txt. tick is the liveness signal:
-- VF: the loader decides "stale" from tick not changing, never from a clock diff
-- VF: across two VMs.
local function publish()
    local p = M.policy()
    ipc.write('fight', {
        state    = st.state,
        why      = st.why,
        raw      = st.raw,
        mode     = st.mode,
        tick     = string.format('%.3f', st.tick),
        fighthot = tostring(st.hot or st.groupHot),
        initiate = tostring(p.initiate),
        commit   = tostring(p.commit),
        chase    = tostring(p.chase),
    })
end

function M.report()
    local p, pwhy = M.policy()
    print('\ag[VF fight]\ax')
    print(string.format('  state      \ag%s\ax  -- %s', st.state, st.why))
    print(string.format('  CombatState %s   held %s   group %s   dwell %.1fs',
        st.raw, tostring(st.hot), tostring(st.groupHot), st.dwell or LEAVE_DWELL))
    print(string.format('  loader     %s   mode %s   running %s   travel %s',
        st.linked and '\aglinked\ax' or '\aynot found\ax', st.mode,
        tostring(st.running), st.travel))
    print(string.format('  policy     %s -- initiate %s  commit %s  chase %s',
        pwhy, tostring(p.initiate), tostring(p.commit), tostring(p.chase)))
    print(string.format('  zone       %s  (%.1fs)   transitions %d',
        st.zone, os.clock() - (st.zonedAt or 0), st.changes))
    print('  \ayread-only -- this daemon does not act yet (COMBAT_DAEMON.md phase 1)\ax')
end

local function onCmd(...)
    local a = select('#', ...) > 0 and tostring(select(1, ...) or ''):lower() or ''
    local b = select('#', ...) > 1 and tostring(select(2, ...) or '') or ''
    if a == 'stop' or a == 'quit' then
        chat.say('Fight', 'stopping')
        st.run = false
    elseif a == 'reload' then
        readLoader()
        chat.say('Fight', 'relinked to loader')
    elseif a == 'dwell' then
        local n = tonumber(b)
        if n and n >= 0 then
            st.dwell = n
            chat.say('Fight', string.format('leave dwell = %.1fs', n))
        else
            print('\ay[VF]\ax usage: /vfc dwell <seconds>')
        end
    else
        -- VF: anything else just prints state; an unknown arg is not worth a scold.
        M.report()
    end
end

function M.start()
    st.run = true
    st.tick = os.clock()
    st.zonedAt = os.clock()
    pcall(function() st.zone = tostring(mq.TLO.Zone.ShortName() or '') end)
    st.raw = FS.engineState()
    readLoader()
    -- VF: own VM, own chat module -- mirror the loader's debug_mode.
    chat.setDebug(function() return loaderSays('debug') == 'true' end)
    publish()
    pcall(function() mq.unbind('/vfc') end)
    mq.bind('/vfc', onCmd)
    chat.say('Fight', string.format('daemon on (read-only). loader %s. /vfc for state.',
        st.linked and 'linked' or 'not found'))
end

function M.stop()
    st.run = false
end

function M.running()
    return st.run
end

function M.shutdown()
    pcall(function() mq.unbind('/vfc') end)
    -- VF: remove the file so the loader sees "no daemon" immediately and falls
    -- VF: back to the raw TLO, instead of waiting out the stale-tick timer.
    ipc.clear('fight')
end

function M.tick()
    if not st.run then return end
    local now = os.clock()
    st.tick = now

    if now >= st.nextWake then
        st.nextWake = now + WAKE
        st.raw = FS.engineState()
    end

    if now >= st.nextScan then
        st.nextScan = now + SCAN
        local z = ''
        pcall(function() z = tostring(mq.TLO.Zone.ShortName() or '') end)
        if z ~= '' and z ~= st.zone then
            st.zone, st.zonedAt = z, now
            st.hot, st.coldSince = false, 0
        end
        -- VF: group hot is separate from my own COMBAT -- the tank can be fighting
        -- VF: 60 units away while I am still ACTIVE.
        st.groupHot = select(1, FS.fightHot()) and st.raw ~= 'COMBAT'
        readLoader()
    end

    if now >= st.nextResolve then
        st.nextResolve = now + RESOLVE
        resolve(now)
        -- VF: republish every resolve -- the file IS the publication now, and
        -- VF: tick must keep moving or the loader reads us as dead.
        publish()
    end

    if now >= st.nextLoader then
        st.nextLoader = now + LOADER_POLL
        if loaderPid() then
            st.sawLoader, st.loaderGone = true, 0
        elseif st.sawLoader then
            if st.loaderGone == 0 then st.loaderGone = now end
            if (now - st.loaderGone) >= LOADER_GRACE then
                chat.err('Fight', 'loader gone -- daemon exiting (dead-man).')
                st.run = false
            end
        end
    end
end

function M.period()
    return PERIOD
end

return M
