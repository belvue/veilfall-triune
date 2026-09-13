-- VF: writes the [MQ2Melee] rail block. Configure() re-applies compiled defaults on every zone-in, so every rail must be explicit. See docs/MELEE_OFFLOAD.md.

local mq = require('mq')
local MeleeCat = require('vft.mgr.melee_catalog')

local M = {}

-- VF: every rail must be listed here -- Configure() resets anything we do not write.
local RAIL_ORDER = {
    'plugin', 'melee', 'aggro', 'taunt', 'enrage', 'infuriate',
    'petassist', 'petdelay', 'petrange', 'petmend', 'petengagehps',
    'stickmode', 'stickrange', 'sticknorange', 'stickdelay', 'stickbreak',
    'backoff', 'feigndeath', 'escape', 'resume', 'standup',
    'range', 'facing',
    'assassinate', 'strike', 'strikemode',
    'kick', 'bash', 'slam', 'disarm', 'frenzy', 'backstab',
    'dragonpunch', 'eaglestrike', 'flyingkick', 'roundkick', 'tigerclaw',
    'intimidation', 'mend', 'sneak', 'hide', 'evade', 'pickpocket',
    'sensetraps', 'forage', 'begging',
    'battleleap', 'callchallenge',
    'pothealfast', 'pothealover',
    'throwstone', 'stunning', 'provoke0', 'provoke1', 'provokemax',
    'stun0', 'stun1',
    'meleepri', 'meleesec', 'aggropri', 'aggrosec', 'shield', 'poker', 'bow', 'arrow',
}
-- VF: abilityif keys — empty if= is no gate; always write with the toggle (MELEE_OFFLOAD).
for _, ifk in ipairs(MeleeCat.ifKeys()) do
    RAIL_ORDER[#RAIL_ORDER + 1] = ifk
end

-- VF: skill engine on; stickmode=2 -- VFT owns /stick % of MaxRangeTo. Melee AvatarHeight+moveback moonwalks fat models.
local DELEGATED = {
    plugin = '1', melee = '1', stickmode = '2',
    sticknorange = '0', stickdelay = '0', stickbreak = '0',
    resume = '100',
    enrage = '1', infuriate = '1',
}

-- VF: stickrange follows Chase. Catalog abilities get toggle + if= together.
local function buildRails(chase, abilityPrefs, enrageHold)
    local r = {}
    for _, k in ipairs(RAIL_ORDER) do r[k] = '0' end
    for k, v in pairs(DELEGATED) do r[k] = v end
    r.stickrange = tostring(math.max(10, math.floor(tonumber(chase) or 150)))
    -- VF: TA's hold and doENRAGE/doINFURIATE must move together. Leaving the plugin's
    -- VF: enrage AttackOFF on while TA stops holding just rebuilds the two-owner flap.
    if not enrageHold then r.enrage, r.infuriate = '0', '0' end
    MeleeCat.applyPrefs(r, abilityPrefs)
    return r
end

-- VF: bump when the rail set or if= gate shape changes -- seeds the written signature.
local RAILS_VER = 'ooc-v5'

-- VF: floor between /melee reload commands. ta_melee.log recorded 646 of them, because
-- VF: the signature is recomputed from readIniAbilityPrefs() -- the ini we just wrote --
-- VF: so it never settles. A plugin reload swaps a DLL under the running client, so bound
-- VF: it here at the writer instead of trusting the signature to converge.
local RELOAD_MIN_GAP = 10

-- VF: read back after /melee reload against the rails we built.
local PROBE = {
    'plugin', 'melee', 'aggro', 'taunt', 'kick', 'bash', 'enrage', 'infuriate',
    'stickmode', 'stickrange', 'sticknorange', 'resume',
}

local function abilitySig(prefs)
    if type(prefs) ~= 'table' then return '' end
    local keys = {}
    for k in pairs(prefs) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local on = MeleeCat.isOn(prefs[k])
        parts[#parts + 1] = k .. '=' .. (on and '1' or '0')
    end
    return table.concat(parts, ',')
end

local SEC = 'MQ2Melee'

function M.install(runtime, deps)
    deps = deps or {}
    local cfg = deps.cfg or (mq.configDir or '.')

    local st = { sig = nil, reloaded = nil }
    runtime.meleeState = st

    -- VF: character change moves the ini path, so the written-signature cache must go with it.
    function runtime.meleeReset()
        st.sig, st.reloaded, st.absentWarned, st.loadAt = nil, nil, nil, nil
        -- VF: reloadAt too, or RELOAD_MIN_GAP suppresses the new character's first reload.
        st.reloadAt = nil
    end

    local function log(msg)
        pcall(function()
            local f = io.open(cfg .. '/ta_melee.log', 'a')
            if not f then return end
            f:write(string.format('%.2f %s\n', os.clock(), tostring(msg)))
            f:close()
        end)
    end
    runtime.meleeLog = log

    function runtime.meleeLoaded()
        local on = false
        pcall(function() on = mq.TLO.Plugin('MQ2Melee').Name() ~= nil end)
        return on
    end

    -- VF: same shape as stickRequire/navRequire. mayDelay only on bootEnter (tick must not delay).
    function runtime.meleeRequire(mayDelay)
        if runtime.meleeLoaded() then return true end
        local now = os.clock()
        if not mayDelay and (now - (st.loadAt or 0)) < 30 then return false end
        st.loadAt = now
        pcall(function() mq.cmd('/plugin MQ2Melee load') end)
        log('plugin load issued')
        if mayDelay then
            pcall(function() mq.delay(400, runtime.meleeLoaded) end)
        end
        if runtime.meleeLoaded() then
            print('\ag[VF]\ax MQ2Melee loaded.')
            return true
        end
        print('\ar[VF]\ax MQ2Melee is required and did not load. Set mq2melee=1 in MacroQuest.ini.')
        return false
    end

    -- VF: tick runs at char select too, where meleePath() would write {server}_unknown.ini.
    function runtime.meleeInGame()
        local ok = false
        pcall(function()
            local n = mq.TLO.Me.Name()
            ok = (n ~= nil and n ~= '' and (tonumber(mq.TLO.Me.ID()) or 0) > 0)
        end)
        return ok
    end

    -- VF: same stem as the loadout .lua and MQ2AASpend -- {server}_{char}.ini.
    function runtime.meleePath()
        local server = (runtime.serverKey and runtime.serverKey()) or 'local'
        local who = (runtime.fileKey and runtime.fileKey(mq.TLO.Me.Name() or 'unknown')) or 'unknown'
        return cfg .. '/' .. server .. '_' .. who .. '.ini'
    end

    -- VF: abilities persist in the MQ2Melee ini. Loadout.melee_abilities overlays on applyEntry.
    -- VF: never rebuild them from meleemvi on sync — live can read 0 before Configure finishes.
    local function readIniAbilityPrefs()
        return MeleeCat.readIniPrefs(runtime.meleePath())
    end

    local function abilityPrefs(patch)
        local prefs = readIniAbilityPrefs()
        if runtime.meleeApplyLoadout then
            runtime.meleeApplyLoadout = nil
            local lo = nil
            pcall(function()
                local L = deps.loadout and deps.loadout()
                lo = L and L.melee_abilities
            end)
            if type(lo) == 'table' then
                for k, v in pairs(MeleeCat.copyAbilities(lo)) do
                    prefs[k] = v
                end
            end
        end
        if type(patch) == 'table' then
            for k, v in pairs(patch) do
                if prefs[k] ~= nil then
                    if MeleeCat.isOn(v) then
                        prefs[k] = 1
                    elseif v == false or v == 0 or v == '0' or v == 'off' then
                        prefs[k] = 0
                    end
                end
            end
        end
        return prefs
    end

    local function chaseDist()
        local c = deps.ctrl and deps.ctrl() or nil
        return c and c.xtar_nav_dist or 150
    end

    -- VF: default ON -- an absent key on an older loadout must not silently disable it.
    local function enrageHoldOn()
        local c = deps.ctrl and deps.ctrl() or nil
        return not (c and c.enrage_hold == false)
    end

    -- VF: rewrite only RAILS keys in [MQ2Melee]; preserve unknown keys and every other section.
    function runtime.meleeRails(patch)
        return buildRails(chaseDist(), abilityPrefs(patch), enrageHoldOn())
    end

    -- VF: /melee key=0|1 is instant (CmdListe). if= lives in IniListe — reload only when gates change.
    function runtime.meleeSetAbility(key, on)
        if not key or key == '' then return false end
        if not runtime.meleeInGame() then return false end
        if not runtime.meleeLoaded() then
            runtime.meleeRequire()
            if not runtime.meleeLoaded() then return false end
        end
        local val = on and '1' or '0'
        mq.cmdf('/melee %s=%s', key, val)
        log('cmd ' .. key .. '=' .. val)
        local rails = runtime.meleeRails({ [key] = on and 1 or 0 })
        local ifChanged = false
        local prev = st.rails
        if type(prev) ~= 'table' then
            ifChanged = true
        else
            for _, ifk in ipairs(MeleeCat.ifKeys()) do
                if prev[ifk] ~= rails[ifk] then ifChanged = true; break end
            end
        end
        if not runtime.meleeWriteIni(rails) then return false end
        st.rails = rails
        st.sig = RAILS_VER .. ':' .. rails.stickrange .. ':' .. rails.enrage .. ':'
            .. abilitySig(abilityPrefs({ [key] = on and 1 or 0 }))
        if ifChanged then
            mq.cmd('/melee reload')
            st.reloaded = st.sig
            log('reload for if= gates')
        else
            st.reloaded = st.sig
        end
        return true
    end

    function runtime.meleeWriteIni(rails)
        local RAILS = rails or runtime.meleeRails()
        local path = runtime.meleePath()
        local lines, seen = {}, {}
        local hasSection = false
        local f = io.open(path, 'r')
        if f then
            local sec = ''
            for line in f:lines() do
                local hdr = line:match('^%s*%[(.-)%]%s*$')
                if hdr then
                    sec = hdr
                    if sec == SEC then hasSection = true end
                end
                if sec == SEC and not hdr then
                    local k = line:match('^%s*([^=;%s]+)%s*=')
                    if k and RAILS[k] ~= nil then
                        if not seen[k] then
                            seen[k] = true
                            lines[#lines + 1] = k .. '=' .. RAILS[k]
                        end
                        -- VF: duplicate rail key in the file -- drop the extra, keep one.
                    else
                        lines[#lines + 1] = line
                    end
                else
                    lines[#lines + 1] = line
                end
            end
            f:close()
        end
        -- VF: rails absent from the file go under the header, or create the section at EOF.
        local missing = {}
        for _, k in ipairs(RAIL_ORDER) do
            if not seen[k] then missing[#missing + 1] = k .. '=' .. RAILS[k] end
        end
        if #missing > 0 then
            local at = nil
            if hasSection then
                for i, line in ipairs(lines) do
                    if line:match('^%s*%[' .. SEC .. '%]%s*$') then at = i; break end
                end
            end
            if at then
                for i = #missing, 1, -1 do table.insert(lines, at + 1, missing[i]) end
            else
                lines[#lines + 1] = '[' .. SEC .. ']'
                for _, l in ipairs(missing) do lines[#lines + 1] = l end
            end
        end
        local w = io.open(path, 'w')
        if not w then
            local now = os.clock()
            if (now - (st.writeWarnAt or -60)) > 30 then
                st.writeWarnAt = now
                print('\ar[VF]\ax could not write ' .. path .. ' -- MQ2Melee rails are not set.')
            end
            return false
        end
        w:write(table.concat(lines, '\n') .. '\n')
        w:close()
        return true
    end

    -- VF: write first, /melee reload second. Never load the plugin here, never /melee save.
    function runtime.meleeSync(force)
        if not runtime.meleeInGame() then return false end
        if force then st.sig, st.reloaded, st.absentWarned = nil, nil, nil end
        local prefs = abilityPrefs()
        local rails = runtime.meleeRails()
        st.rails = rails
        -- VF: enrage is in the sig because it is not a catalog ability -- without it the
        -- VF: checkbox would write the rail and never reload the plugin to pick it up.
        local sig = RAILS_VER .. ':' .. rails.stickrange .. ':' .. rails.enrage .. ':'
            .. abilitySig(prefs)
        if sig ~= st.sig then
            if not runtime.meleeWriteIni(rails) then return false end
            st.sig, st.reloaded = sig, nil
            log('write rails -> ' .. runtime.meleePath() .. ' stickrange=' .. rails.stickrange)
        end
        if st.reloaded == sig then return true end
        -- VF: first reload is never throttled (st.reloadAt nil), so the rails still land
        -- VF: at startup and meleeOwnsPositioning still flips.
        local now = os.clock()
        if st.reloadAt and (now - st.reloadAt) < RELOAD_MIN_GAP then return false end
        if not runtime.meleeLoaded() then
            runtime.meleeRequire()
            if not runtime.meleeLoaded() then return false end
        end
        st.absentWarned = nil
        mq.cmd('/melee reload')
        st.reloaded = sig
        st.reloadAt = now
        log('reload issued')
        return true
    end

    -- VF: true once rails are on disk and the plugin is live. Does NOT mean
    -- VF: Melee sticks -- stickmode=2, Lua issues /stick. docs/COMBAT_OWNERS.md.
    function runtime.meleeOwnsPositioning()
        return (st.reloaded ~= nil) and runtime.meleeLoaded()
    end

    -- VF: /vf meleediag. An unknown key reads 0 and still reports success, so resume=100 is the probe.
    function runtime.meleeVerify()
        local loaded = runtime.meleeLoaded()
        print(string.format('\ag[VF]\ax MQ2Melee: plugin %s, ini %s',
            loaded and 'loaded' or '\arNOT LOADED\ax', runtime.meleePath()))
        if not loaded then
            print('  nothing to read -- \ay${meleemvi[...]}\ax needs the plugin loaded.')
            return nil
        end
        -- VF: meleemvi is int-typed -- compare as numbers, not strings.
        local RAILS = st.rails or buildRails(150)
        local vals, bad = {}, 0
        for _, k in ipairs(PROBE) do
            local raw
            pcall(function() raw = mq.TLO.meleemvi(k)() end)
            local n = tonumber(raw)
            local v = n and string.format('%g', n) or (raw == nil and '?' or tostring(raw))
            vals[k] = v
            local okKey = (n ~= nil) and (n == tonumber(RAILS[k])) or (v == RAILS[k])
            if not okKey then bad = bad + 1 end
            print(string.format('  %-13s %-4s %s', k, v,
                okKey and 'ok' or ('\arexpected ' .. RAILS[k] .. '\ax')))
        end
        local probeOk = (tonumber(vals.resume) == 100)
        print(string.format('  positive probe: resume=%s -- %s', tostring(vals.resume),
            probeOk and 'section is being read' or '\arFAIL: rails may not be applied at all\ax'))
        if bad == 0 and probeOk then
            print('\ag[VF]\ax rails hold.')
        else
            print(string.format('\ar[VF]\ax %d rail(s) off expected value -- see docs/MELEE_OFFLOAD.md.', bad))
        end
        log(string.format('verify loaded=%s bad=%d resume=%s', tostring(loaded), bad, tostring(vals.resume)))
        return vals
    end

    -- VF: MQ2Melee owns enrage/infuriate attack-off. Do not /attack on over it.
    -- VF: MQ2Melee keeps its OWN kill target and only auto-acquires while MeleeTarg is 0
    -- VF: (MQ2Melee.cpp:4543). After that every target switch takes the 4548 branch ->
    -- VF: Override() -> AttackOFF() + return, once per pulse, and SHOW_OVERRIDE is a
    -- VF: compile-time 0 so it never says so. /killthis is the registered command that
    -- VF: re-points it. Without this TA re-issues /attack on each tick and the two owners
    -- VF: flap the toggle forever. The plugin self-guards (needs an NPC target that
    -- VF: differs from MeleeTarg), so a redundant call is a no-op.
    function runtime.meleeClaimTarget(id)
        id = tonumber(id) or 0
        if id <= 0 then return false end
        if not runtime.meleeLoaded or not runtime.meleeLoaded() then return false end
        local mt = 0
        -- VF: Melee.Target is isKill ? MeleeTarg : 0, so 0 also means "not engaged yet".
        pcall(function() mt = tonumber(mq.TLO.Melee.Target()) or 0 end)
        if mt == id then return false end
        local now = os.clock()
        if st.claimAt and (now - st.claimAt) < 0.5 then return false end
        st.claimAt = now
        pcall(function() mq.cmd('/killthis') end)
        log('killthis -> ' .. id .. ' (melee had ' .. mt .. ')')
        return true
    end

    function runtime.meleeEnrageHold()
        if not enrageHoldOn() then return false end
        local hold = false
        pcall(function()
            if not runtime.meleeLoaded or not runtime.meleeLoaded() then return end
            local m = mq.TLO.Melee
            if m and (m.Enrage() or m.Infuriate()) then hold = true end
        end)
        return hold
    end

    return M
end

return M
