-- VF: Self buff / song-bar detect and the OOC buff pass. Gate 7: cold roles + zone settle.

local mq = require('mq')
local U = require('vft.util')
local D = require('vft.data')

local M = {}

local function tloTrue(fn)
    local hit = false
    pcall(function() if fn() then hit = true end end)
    return hit
end

function M.install(runtime, api)
    api = api or {}
    local barNameCache, barNameCacheAt = nil, 0

    local function spellNamesEqual(a, b)
        a, b = tostring(a or ''), tostring(b or '')
        if a == '' or b == '' then return false end
        if a == b then return true end
        if U.cleanSpellName(a):lower() == U.cleanSpellName(b):lower() then return true end
        return U.normalizeSpellName(a) == U.normalizeSpellName(b)
    end

    local function tloEffectPresent(tlo)
        local present = false
        pcall(function()
            if not tlo then return end
            local n = tlo.Name()
            if n and n ~= '' and n ~= 'NULL' then
                present = true
                return
            end
            local id = tonumber(tlo.ID() or 0) or 0
            if id > 0 then present = true end
        end)
        return present
    end

    local function selfHasWindowEffect(windowName, name)
        for _, n in ipairs(U.apostropheVariants(name)) do
            if tloEffectPresent(mq.TLO.Me[windowName](n)) then return true end
        end
        local wantId = 0
        for _, n in ipairs(U.apostropheVariants(name)) do
            pcall(function() wantId = tonumber(mq.TLO.Spell(n).ID() or 0) or 0 end)
            if wantId > 0 then break end
        end
        local maxSlot = (windowName == 'Song') and 30 or 42
        for i = 1, maxSlot do
            local slotName, slotId = nil, 0
            pcall(function()
                local slot = mq.TLO.Me[windowName](i)
                slotName = slot.Name()
                slotId = tonumber(slot.SpellID() or slot.ID() or 0) or 0
            end)
            if slotName and spellNamesEqual(slotName, name) then return true end
            if wantId > 0 and slotId == wantId then return true end
        end
        return false
    end

    local function stripBarDecor(name)
        name = U.cleanSpellName(tostring(name or ''))
        name = name:gsub(':[^:]+$', '')
        name = name:gsub(':Permanent$', '')
        return (name:gsub('%s+$', ''))
    end

    -- VF: BuffWindow + ShortDurationBuffWindow merge into one set; class/bar does not matter.
    local function addBarName(into, n)
        n = tostring(n or '')
        if n == '' or n == 'NULL' then return end
        local first = n:match('^[^\r\n]+') or n
        first = first:gsub('%s+$', '')
        if first == '' then return end
        local chrome = { songs = true, effects = true, buffs = true, buff = true, close = true }
        if chrome[first:lower()] then return end
        into.raw[#into.raw + 1] = first
        into.set[first] = true
        into.set[first:lower()] = true
        into.set[U.cleanSpellName(first):lower()] = true
        into.set[U.normalizeSpellName(first)] = true
        local decor = stripBarDecor(first)
        if decor ~= '' then
            into.set[decor] = true
            into.set[decor:lower()] = true
            into.set[U.normalizeSpellName(decor)] = true
        end
        local display = (decor ~= '' and decor) or first
        local key = U.normalizeSpellName(display)
        if key ~= '' and into.seen and not into.seen[key] then
            into.seen[key] = true
            into.names[#into.names + 1] = display
        end
    end

    local function harvestWindow(into, winName)
        local function walk(node, depth)
            if not node or depth > 10 then return end
            local exists = false
            pcall(function() exists = not not node() end)
            if not exists then return end
            local tip, txt
            pcall(function() tip = node.Tooltip() end)
            pcall(function() txt = node.Text() end)
            addBarName(into, tip)
            addBarName(into, txt)
            local child, nxt
            pcall(function() child = node.FirstChild end)
            if child then walk(child, depth + 1) end
            pcall(function() nxt = node.Next end)
            if nxt then walk(nxt, depth + 1) end
        end
        pcall(function()
            local w = mq.TLO.Window(winName)
            if w and w() then walk(w, 0) end
        end)
    end

    local SHORT_WINS = {
        { 'ShortDurationBuffWindow', { 'Buff%d', 'SDBW_Buff%d_Button', 'SDB_Buff%d', 'Song%d' } },
        { 'Songs',                   { 'Buff%d', 'Song%d', 'SDBW_Buff%d_Button', 'SDB_Buff%d' } },
        { 'SongWindow',              { 'Buff%d', 'Song%d', 'SW_Song%d_Button' } },
        { 'ShortBuffWindow',         { 'Buff%d', 'SBW_Buff%d_Button' } },
        { 'SongbuffWindow',          { 'Buff%d', 'Song%d' } },
    }

    local function gatherSelfBarEffects(force)
        local now = os.clock()
        if not force and barNameCache and (now - barNameCacheAt) < 0.45 then
            return barNameCache
        end
        local into = { raw = {}, set = {}, names = {}, seen = {} }
        for i = 1, 42 do
            pcall(function()
                local b = mq.TLO.Me.Buff(i)
                local n = b.Name()
                if (not n or n == '' or n == 'NULL') and b.Spell then n = b.Spell.Name() end
                addBarName(into, n)
            end)
        end
        for i = 1, 30 do
            pcall(function()
                local s = mq.TLO.Me.Song(i)
                local n = s.Name()
                if (not n or n == '' or n == 'NULL') and s.Spell then n = s.Spell.Name() end
                addBarName(into, n)
            end)
        end
        harvestWindow(into, 'BuffWindow')
        for i = 0, 41 do
            pcall(function()
                local c = mq.TLO.Window('BuffWindow').Child(string.format('Buff%d', i))
                if c and c() then
                    addBarName(into, c.Tooltip())
                    addBarName(into, c.Text())
                end
            end)
            pcall(function()
                local c = mq.TLO.Window('BuffWindow').Child(string.format('BW_Buff%d_Button', i))
                if c and c() then
                    addBarName(into, c.Tooltip())
                    addBarName(into, c.Text())
                end
            end)
        end
        for _, spec in ipairs(SHORT_WINS) do
            harvestWindow(into, spec[1])
            for _, fmt in ipairs(spec[2]) do
                for i = 0, 41 do
                    pcall(function()
                        local c = mq.TLO.Window(spec[1]).Child(string.format(fmt, i))
                        if c and c() then
                            addBarName(into, c.Tooltip())
                            addBarName(into, c.Text())
                        end
                    end)
                end
            end
        end
        barNameCache, barNameCacheAt = into, now
        return into
    end

    local function possessivePrefix(name)
        name = U.cleanSpellName(tostring(name or ''))
        local p = name:match("^([%a]+)'s") or name:match("^([%a]+)\226\128\153s")
        return p and p:lower() or ''
    end

    local function isSeloFamily(name)
        return U.normalizeSpellName(name):find('selo', 1, true) ~= nil
    end

    local function selfBarHasSpell(name)
        name = tostring(name or '')
        if name == '' then return false end
        local bar = gatherSelfBarEffects()
        local decor = stripBarDecor(name)
        if bar.set[name] or bar.set[name:lower()] then return true end
        if bar.set[decor] or bar.set[decor:lower()] then return true end
        if bar.set[U.cleanSpellName(name):lower()] or bar.set[U.normalizeSpellName(name)] then return true end
        if bar.set[U.normalizeSpellName(decor)] then return true end
        local needle = decor:lower()
        local needleNorm = U.normalizeSpellName(decor)
        if needle == '' and needleNorm == '' then return false end
        local pref = possessivePrefix(name)
        local wantSelo = isSeloFamily(name)
        for _, raw in ipairs(bar.raw) do
            local raws = tostring(raw)
            local rawDecor = stripBarDecor(raws):lower()
            local rawNorm = U.normalizeSpellName(raws)
            if needle ~= '' and (raws:lower():find(needle, 1, true) or rawDecor == needle) then return true end
            if needleNorm ~= '' and rawNorm == needleNorm then return true end
            if needleNorm ~= '' and U.normalizeSpellName(rawDecor) == needleNorm then return true end
            -- VF: Improved Familiar vs Improved Familiar: Permanent after punct strip.
            if needleNorm ~= '' and #rawNorm >= #needleNorm and rawNorm:sub(1, #needleNorm) == needleNorm then
                local rest = rawNorm:sub(#needleNorm + 1)
                if rest == 'permanent' or rest == '' then return true end
            end
            if pref ~= '' and possessivePrefix(raws) == pref then return true end
            if wantSelo and rawNorm:find('selo', 1, true) then return true end
        end
        return false
    end

    local function hasNamedBuff(spawnObj, name, isMe)
        name = tostring(name or '')
        if name == '' or not spawnObj() then return false end
        if isMe and selfBarHasSpell(name) then return true end

        local found = false
        for _, n in ipairs(U.apostropheVariants(name)) do
            pcall(function()
                if tloEffectPresent(spawnObj.Buff(n)) then found = true end
            end)
            if found then break end
        end
        if not found and isMe then
            for _, n in ipairs(U.apostropheVariants(name)) do
                pcall(function()
                    if tloEffectPresent(spawnObj.Song(n)) then found = true end
                end)
                if found then break end
            end
            if not found then
                found = selfHasWindowEffect('Buff', name) or selfHasWindowEffect('Song', name)
            end
        end
        if found then return true end

        local cnt = 0
        pcall(function() cnt = spawnObj.BuffCount() or 0 end)
        for i = 1, cnt do
            local b = spawnObj.Buff(i)
            if b() then
                local bn = b.Name() or ''
                if bn == name or spellNamesEqual(bn, name) then found = true end
            end
        end
        if isMe and not found then
            for i = 1, 30 do
                local sn = ''
                pcall(function() sn = mq.TLO.Me.Song(i).Name() or '' end)
                if sn ~= '' and (spellNamesEqual(sn, name) or (isSeloFamily(name) and isSeloFamily(sn))) then
                    found = true
                    break
                end
            end
        end
        return found
    end

    local function buffActive(id, name)
        if not id or id == 0 then return false end
        local myId = 0
        pcall(function() myId = mq.TLO.Me.ID() or 0 end)
        if id == myId then
            if selfBarHasSpell(name) then return true end
            if hasNamedBuff(mq.TLO.Me, name, true) then return true end
            return false
        end
        local total = 0
        pcall(function() total = mq.TLO.Group.Members() or 0 end)
        for i = 0, total do
            local m = nil
            pcall(function() m = mq.TLO.Group.Member(i) end)
            if m and m() and (m.ID() or 0) == id then
                if hasNamedBuff(m, name) then return true end
                if tloTrue(function() return m.Song(name)() end) then return true end
                return false
            end
        end
        local pets = api.petState and api.petState.myPets
        if type(pets) == 'table' then
            for _, petId in pairs(pets) do
                if petId == id then
                    local s = mq.TLO.Spawn(id)
                    return s() and hasNamedBuff(s, name)
                end
            end
        end
        if mq.TLO.Target.ID() == id then
            return hasNamedBuff(mq.TLO.Target, name)
        end
        local s = mq.TLO.Spawn(id)
        if s and s() then
            return hasNamedBuff(s, name)
        end
        return false
    end

    runtime.tloEffectPresent = tloEffectPresent
    runtime.selfHasWindowEffect = selfHasWindowEffect
    runtime.spellNamesEqual = spellNamesEqual
    runtime.selfBarHasSpell = selfBarHasSpell
    runtime.buffActive = buffActive
    -- VF: merged BuffWindow + short bar scrape for OOC + combat presence.
    runtime.snapshotSelfBars = gatherSelfBarEffects
    runtime.invalidateBarCache = function()
        barNameCache = nil
    end

    runtime.persistSongOnBar = function(name)
        name = tostring(name or '')
        if name == '' then return false end
        if selfBarHasSpell(name) then
            local singing = ''
            pcall(function() singing = mq.TLO.Me.Casting.Name() or '' end)
            if singing == '' then return true end
            return not spellNamesEqual(singing, name)
        end
        return false
    end

    -- VF: Cure presence = name on the bar. Me.Counters* / Beneficial / slot counters stay dirty or zero.
    local function tloEffectName(tlo)
        local n = ''
        pcall(function()
            if not tlo then return end
            if tlo.Name then n = tostring(tlo.Name() or '') end
            if n == '' or n == 'NULL' then n = tostring(tlo() or '') end
        end)
        if n == '' or n == 'NULL' or n == 'nil' then return '' end
        return n
    end

    local function slotCureDetail(slot)
        local detail = nil
        pcall(function()
            if not slot or not slot() then return end
            local n = slot.Name()
            if (not n or n == '' or n == 'NULL') and slot.Spell then
                n = slot.Spell.Name()
            end
            if not n or n == '' or n == 'NULL' then return end
            local p = tonumber(slot.CountersPoison()) or 0
            local d = tonumber(slot.CountersDisease()) or 0
            local c = tonumber(slot.CountersCurse()) or 0
            local r = tonumber(slot.CountersCorruption()) or 0
            local tot = tonumber(slot.TotalCounters()) or 0
            if tot <= 0 then tot = p + d + c + r end
            if tot <= 0 then
                local sp = slot
                if slot.Spell and slot.Spell() then sp = slot.Spell end
                local ct = ''
                pcall(function() ct = tostring(sp.CounterType() or ''):lower() end)
                if ct == 'poison' then p = 1
                elseif ct == 'disease' then d = 1
                elseif ct == 'curse' then c = 1
                elseif ct == 'corruption' then r = 1
                elseif sp.HasSPA then
                    if sp.HasSPA(36)() then p = 1 end
                    if sp.HasSPA(35)() then d = 1 end
                    if sp.HasSPA(116)() then c = 1 end
                    if sp.HasSPA(369)() then r = 1 end
                end
                tot = p + d + c + r
            end
            if tot <= 0 then return end
            detail = { name = n, poison = p, disease = d, curse = c, corruption = r, total = tot }
        end)
        return detail
    end

    local function slotHasCureCounters(slot)
        return slotCureDetail(slot) ~= nil
    end

    -- VF: Me.Poisoned name must still be on Buff/Song/window — dirty flags without a slot are ignored.
    runtime.selfCureCounters = function()
        local out = {
            poison = 0, disease = 0, curse = 0, corruption = 0, total = 0,
            slots = {},
        }
        local slotP, slotD, slotC, slotR = 0, 0, 0, 0
        local function addDetail(d, where, i)
            if not d then return end
            d.where = where
            d.index = i
            out.slots[#out.slots + 1] = d
            slotP = slotP + (d.poison or 0)
            slotD = slotD + (d.disease or 0)
            slotC = slotC + (d.curse or 0)
            slotR = slotR + (d.corruption or 0)
        end
        for i = 1, 42 do
            local slot = nil
            pcall(function() slot = mq.TLO.Me.Buff(i) end)
            addDetail(slotCureDetail(slot), 'Buff', i)
        end
        for i = 1, 30 do
            local slot = nil
            pcall(function() slot = mq.TLO.Me.Song(i) end)
            addDetail(slotCureDetail(slot), 'Song', i)
        end
        local function addFlag(kind, tlo)
            local n = tloEffectName(tlo)
            if n == '' or not selfBarHasSpell(n) then return end
            local d = {
                name = n, poison = 0, disease = 0, curse = 0, corruption = 0, total = 1,
            }
            d[kind] = 1
            addDetail(d, 'Flag', 0)
        end
        if slotP == 0 then addFlag('poison', mq.TLO.Me.Poisoned) end
        if slotD == 0 then addFlag('disease', mq.TLO.Me.Diseased) end
        if slotC == 0 then addFlag('curse', mq.TLO.Me.Cursed) end
        if slotR == 0 then addFlag('corruption', mq.TLO.Me.Corrupted) end
        out.poison, out.disease, out.curse, out.corruption = slotP, slotD, slotC, slotR
        out.total = slotP + slotD + slotC + slotR
        return out
    end

    runtime.selfHasCureableOnBar = function()
        local c = runtime.selfCureCounters()
        if c.total > 0 or #c.slots > 0 then return true end
        if (c.poison + c.disease + c.curse + c.corruption) > 0 then return true end
        return false
    end

    -- VF: what a Cure row removes — Beneficial SPA, then CounterType, then name.
    runtime.cureSpellKind = function(spellName)
        spellName = tostring(spellName or '')
        if spellName == '' then return 'any' end
        local ct, bene = '', false
        local hasP, hasD, hasC, hasR = false, false, false, false
        pcall(function()
            local sp = mq.TLO.Spell(spellName)
            if not (sp and sp()) then return end
            bene = not not sp.Beneficial()
            ct = tostring(sp.CounterType() or '')
            -- VF: 35 disease / 36 poison / 116 curse / 369 corruption counters.
            if sp.HasSPA then
                hasD = not not sp.HasSPA(35)()
                hasP = not not sp.HasSPA(36)()
                hasC = not not sp.HasSPA(116)()
                hasR = not not sp.HasSPA(369)()
            end
        end)
        if bene then
            local n = (hasP and 1 or 0) + (hasD and 1 or 0) + (hasC and 1 or 0) + (hasR and 1 or 0)
            if n >= 2 then return 'any' end
            if hasC then return 'curse' end
            if hasR then return 'corruption' end
            if hasP then return 'poison' end
            if hasD then return 'disease' end
        end
        ct = ct:lower()
        if ct == 'poison' or ct == 'disease' or ct == 'curse' or ct == 'corruption' then
            return ct
        end
        local nm = spellName:lower()
        if nm:find('corrupt', 1, true) then return 'corruption' end
        if nm:find('curse', 1, true) then return 'curse' end
        if nm:find('poison', 1, true) or nm:find('venom', 1, true)
            or nm:find('toxin', 1, true) then
            return 'poison'
        end
        if nm:find('disease', 1, true) or nm:find('plague', 1, true)
            or nm:find('malady', 1, true) then
            return 'disease'
        end
        if nm:find('radiant', 1, true) or nm:find('panacea', 1, true)
            or nm:find('purge', 1, true) or nm:find('blood of', 1, true)
            or nm:find('abolish', 1, true) then
            return 'any'
        end
        -- VF: generic "Cure" / Counteract with no CounterType — poison or disease only.
        return 'poison_disease'
    end

    runtime.hasCureNeed = function(spellName, targetId)
        local myId = 0
        pcall(function() myId = mq.TLO.Me.ID() or 0 end)
        if not targetId or targetId <= 0 then return false end
        local kind = runtime.cureSpellKind(spellName)
        if targetId ~= myId then
            -- VF: group/other — only NetBots/Target poison+disease today; curse needs self counters.
            if kind == 'curse' or kind == 'corruption' then return false end
            if api.isPoisonedOrDiseased then return not not api.isPoisonedOrDiseased(targetId) end
            return false
        end
        local c = runtime.selfCureCounters()
        local function hasP() return (c.poison or 0) > 0 end
        local function hasD() return (c.disease or 0) > 0 end
        local function hasC() return (c.curse or 0) > 0 end
        local function hasR() return (c.corruption or 0) > 0 end
        if kind == 'poison' then return hasP() end
        if kind == 'disease' then return hasD() end
        if kind == 'curse' then return hasC() end
        if kind == 'corruption' then return hasR() end
        if kind == 'any' then
            return (c.total or 0) > 0
        end
        -- VF: poison_disease — never open on curse/corruption alone.
        return hasP() or hasD()
    end

    runtime.buffSessionBlocked = runtime.buffSessionBlocked or {}

    -- VF: "Blocked by X" = higher/stacking buff; treat as satisfied for this session (until zone).
    runtime.buffSessionClear = function()
        runtime.buffSessionBlocked = {}
    end

    runtime.buffSessionIsBlocked = function(spellName)
        local key = U.normalizeSpellName(U.cleanSpellName(tostring(spellName or '')))
        if key == '' then return false end
        return runtime.buffSessionBlocked[key] ~= nil
    end

    runtime.buffSessionBlock = function(spellName, blocker)
        spellName = U.cleanSpellName(tostring(spellName or ''))
        if spellName == '' then return false end
        local key = U.normalizeSpellName(spellName)
        if runtime.buffSessionBlocked[key] then return true end
        runtime.buffSessionBlocked[key] = {
            name = spellName,
            by = tostring(blocker or '?'),
            at = os.clock(),
        }
        local me = 0
        pcall(function() me = mq.TLO.Me.ID() or 0 end)
        if me > 0 and runtime.sungBuffs then
            runtime.sungBuffs[U.sungKey(spellName, me)] = true
        end
        if runtime.invalidateBarCache then runtime.invalidateBarCache() end
        print(string.format(
            '\ay[VF]\ax "%s" blocked by %s -- session latch (won\'t recast until zone).',
            spellName, tostring(blocker or '?')))
        return true
    end

    -- VF: sungKey is "id_normalizedSpell"; park after N failed tries, or for session block.
    runtime.buffRetryOk = function(key)
        if not key then return true end
        local spellPart = tostring(key):match('^%d+_(.+)$') or tostring(key)
        if runtime.buffSessionIsBlocked(spellPart) then return false end
        -- VF: also accept raw spell names passed as key.
        if runtime.buffSessionIsBlocked(key) then return false end
        local st = runtime.buffTries and runtime.buffTries[key]
        if not st then return true end
        if st.blockedUntil and os.clock() < st.blockedUntil then return false end
        if st.blockedUntil then runtime.buffTries[key] = nil end
        return true
    end

    runtime.buffTryRecorded = function(key, spellName)
        if runtime.invalidateBarCache then runtime.invalidateBarCache() end
        if not key then return end
        if not runtime.buffTries then runtime.buffTries = {} end
        local ctrl = api.getCtrl and api.getCtrl() or api.ctrl
        local maxTries = tonumber(ctrl and ctrl.buff_max_tries) or 3
        local backoff = tonumber(ctrl and ctrl.buff_retry_sec) or 60
        local st = runtime.buffTries[key] or { n = 0 }
        st.n = (st.n or 0) + 1
        if st.n >= maxTries then
            st.n = 0
            st.blockedUntil = os.clock() + backoff
            print(string.format(
                '\ay[VF]\ax "%s" still reads missing after %d casts -- pausing %ds.',
                tostring(spellName), maxTries, backoff))
        end
        runtime.buffTries[key] = st
    end

    local function resolveBlockedSpell()
        local name = nil
        pcall(function() name = mq.TLO.Me.Casting.Name() end)
        if (not name or name == '') and api.castTracker then
            name = api.castTracker.activeSpell or api.castTracker.lastSpell
        end
        return name
    end

    mq.event('TABuffBlockedBy', '#*#(Blocked by #1#)#*#', function(_, blocker)
        local spell = resolveBlockedSpell()
        if spell and spell ~= '' then
            runtime.buffSessionBlock(spell, blocker)
        end
    end)
    -- VF: some builds omit the parens: "...take hold. Blocked by Protect."
    mq.event('TABuffBlockedBy2', '#*#Blocked by #1#.#*#', function(_, blocker)
        local spell = resolveBlockedSpell()
        if spell and spell ~= '' then
            runtime.buffSessionBlock(spell, blocker)
        end
    end)

    runtime.buffFactuallyUp = function(id, name)
        name = tostring(name or '')
        if not id or id == 0 or name == '' then return false end
        if runtime.buffSessionIsBlocked(name) then return true end
        local myId = 0
        pcall(function() myId = mq.TLO.Me.ID() or 0 end)
        if id == myId then
            if selfBarHasSpell(name) then return true end
            -- VF: AA name may land as Spell Name: Permanent (Improved Familiar).
            local spName = ''
            pcall(function()
                local aa = mq.TLO.Me.AltAbility(name)
                if aa and aa() and aa.Spell and aa.Spell() then
                    spName = tostring(aa.Spell.Name() or aa.Spell() or '')
                end
            end)
            spName = U.trimName(spName)
            if spName ~= '' and spName ~= 'NULL' and spName ~= name and selfBarHasSpell(spName) then
                return true
            end
            return false
        end
        return buffActive(id, name)
    end

    runtime.dumpSelfBarToFile = function(reason)
        local bar = gatherSelfBarEffects(true)
        local path = (mq.configDir or '.') .. '\\ta_buffdump.txt'
        local f = io.open(path, 'w')
        if not f then return path end
        f:write('=== TA buff dump ' .. os.date('%Y-%m-%d %H:%M:%S') .. ' ===\n')
        f:write('reason=' .. tostring(reason or 'manual') .. '\n')
        pcall(function() f:write('name=' .. tostring(mq.TLO.Me.Name()) .. '\n') end)
        pcall(function()
            f:write('CountBuffs=' .. tostring(mq.TLO.Me.CountBuffs()) .. ' CountSongs=' .. tostring(mq.TLO.Me.CountSongs()) .. '\n')
        end)
        local counters = runtime.selfCureCounters and runtime.selfCureCounters() or nil
        if counters then
            local line = string.format(
                'Me counters: poison=%d disease=%d curse=%d corruption=%d total=%d',
                counters.poison or 0, counters.disease or 0, counters.curse or 0,
                counters.corruption or 0, counters.total or 0)
            f:write(line .. '\n')
            print('\ag[VF]\ax ' .. line)
            local function flagLine(label, tlo)
                local s = tloEffectName(tlo)
                if s == '' then return end
                local onBar = selfBarHasSpell(s)
                f:write(string.format('  %s: %s onbar=%s\n', label, s, onBar and 'yes' or 'no'))
            end
            flagLine('Poisoned', mq.TLO.Me.Poisoned)
            flagLine('Diseased', mq.TLO.Me.Diseased)
            flagLine('Cursed', mq.TLO.Me.Cursed)
            f:write('debuff slots with counters:\n')
            if not counters.slots or #counters.slots == 0 then
                f:write('  (none)\n')
            else
                for _, d in ipairs(counters.slots) do
                    local slotLine = string.format(
                        '  [%s %d] "%s" P=%d D=%d C=%d R=%d tot=%d',
                        tostring(d.where), tonumber(d.index) or 0, tostring(d.name),
                        d.poison or 0, d.disease or 0, d.curse or 0, d.corruption or 0, d.total or 0)
                    f:write(slotLine .. '\n')
                    print('\ay[VF]\ax ' .. slotLine:gsub('^%s+', ''))
                end
            end
        end
        local function writeCureRow(via, name, spell)
            spell = tostring(spell or name or '')
            if spell == '' then return end
            local kind = runtime.cureSpellKind and runtime.cureSpellKind(spell) or '?'
            local myId = 0
            pcall(function() myId = mq.TLO.Me.ID() or 0 end)
            local need = false
            if runtime.hasCureNeed and myId > 0 then
                need = not not runtime.hasCureNeed(spell, myId)
            end
            local line = string.format(
                '  %s "%s" strips=%s match=%s',
                via, spell, tostring(kind), need and 'yes' or 'no')
            if name and name ~= '' and name ~= spell then
                line = string.format(
                    '  %s "%s" click="%s" strips=%s match=%s',
                    via, name, spell, tostring(kind), need and 'yes' or 'no')
            end
            f:write(line .. '\n')
            print('\ag[VF]\ax Cure ' .. line:gsub('^%s+', ''))
        end
        f:write('Cure loadout (Type=Cure only):\n')
        do
            local loadout = api.loadout
            if type(api.getLoadout) == 'function' then loadout = api.getLoadout() or loadout end
            loadout = loadout or {}
            local n = 0
            for i = 1, D.NUM_GEMS do
                local g = loadout.gems and loadout.gems[i]
                local role = runtime.castRole and runtime.castRole(g) or nil
                if g and g.spell and g.spell ~= '' and role == 'Cure' then
                    n = n + 1
                    writeCureRow('gem ' .. i, g.spell, g.spell)
                    if (tonumber(g.pct) or 0) <= 0 then
                        f:write('    (muted — enable the gem row)\n')
                    end
                end
            end
            for name, it in pairs(loadout.items or {}) do
                local role = runtime.castRole and runtime.castRole(it) or nil
                if it and it.enabled and role == 'Cure' then
                    local spell = ''
                    if runtime.itemClickSpell then
                        spell = runtime.itemClickSpell(name, it) or ''
                    elseif it.spell then
                        spell = it.spell
                    end
                    n = n + 1
                    writeCureRow('item', name, spell)
                end
            end
            for name, a in pairs(loadout.aas or {}) do
                local role = runtime.castRole and runtime.castRole(a) or nil
                if a and a.enabled and role == 'Cure' then
                    n = n + 1
                    writeCureRow('aa', name, name)
                end
            end
            if n == 0 then
                f:write('  (none — set Type=Cure on the gem/item in Settings)\n')
                print('\ay[VF]\ax Cure loadout: none. Set Type=Cure on the gem or item in Settings.')
            end
        end
        local function writeList(label, list)
            f:write(label .. ':\n')
            if not list or #list == 0 then
                f:write('  (none)\n')
            else
                for _, n in ipairs(list) do
                    f:write('  - ' .. n .. '\n')
                end
            end
        end
        writeList('self bars (BuffWindow + ShortDuration / Me.Buff + Me.Song)', bar.names)
        for _, winName in ipairs({
            'BuffWindow', 'ShortDurationBuffWindow', 'Songs', 'SongWindow', 'ShortBuffWindow',
        }) do
            local open = '?'
            pcall(function() open = tostring(mq.TLO.Window(winName).Open()) end)
            f:write(string.format('Window[%s] Open=%s\n', winName, open))
        end
        local loadout = api.loadout
        if type(api.getLoadout) == 'function' then loadout = api.getLoadout() or loadout end
        loadout = loadout or {}
        local function checkRow(kind, slot, n, when, cls)
            if not n or n == '' then return end
            local selfBuff = (when == 'missing buff' or when == 'always')
            if not selfBuff then return end
            local up = selfBarHasSpell(n)
            local line = string.format('  %s %s "%s" (%s, %s) => %s',
                kind, tostring(slot), n, tostring(when), tostring(cls or '?'), up and 'UP' or 'MISSING')
            f:write(line .. '\n')
            print(string.format('\ag[VF]\ax %s', line:gsub('^%s+', '')))
        end
        local function spellInBook(name)
            name = tostring(name or '')
            if name == '' then return false end
            local hit = false
            local function try(n)
                pcall(function()
                    local b = mq.TLO.Me.Book(n)
                    if b and b() then
                        local v = b()
                        if type(v) == 'number' then
                            hit = v > 0
                        else
                            hit = tostring(v) ~= '' and tostring(v) ~= 'NULL'
                        end
                    end
                end)
            end
            try(name)
            if hit then return true end
            if U.apostropheVariants then
                for _, n in ipairs(U.apostropheVariants(name)) do
                    if n ~= name then
                        try(n)
                        if hit then return true end
                    end
                end
            end
            return false
        end

        f:write('loadout vs merged bars:\n')
        local gemN = 0
        for i = 1, D.NUM_GEMS do
            local g = loadout.gems and loadout.gems[i]
            if g then
                gemN = gemN + 1
                checkRow('gem', i, g.spell, g.when, g.cls)
            end
        end
        if gemN == 0 then f:write('  (no gems in loadout yet)\n') end
        local gateShown, gateSkip = 0, 0
        if loadout.spell_gates then
            for key, g in pairs(loadout.spell_gates) do
                if type(g) == 'table' and g.spell and g.spell ~= '' then
                    if spellInBook(g.spell) then
                        gateShown = gateShown + 1
                        checkRow('gate', key, g.spell, g.when, g.cls)
                    else
                        gateSkip = gateSkip + 1
                    end
                end
            end
        end
        if gateSkip > 0 then
            local skipLine = string.format(
                '  (skipped %d library gate(s) not in spellbook -- /vf prunegates to drop them)',
                gateSkip)
            f:write(skipLine .. '\n')
            print('\ay[VF]\ax ' .. skipLine:gsub('^%s+', ''))
        end
        f:close()
        print('\ag[VF]\ax wrote buff dump: ' .. path)
        return path
    end

    -- VF: drop spell_gates rows for spells no longer in the book (stale Brd library, etc.).
    runtime.pruneSpellGates = function()
        local loadout = api.loadout
        if type(api.getLoadout) == 'function' then loadout = api.getLoadout() or loadout end
        if type(loadout) ~= 'table' or type(loadout.spell_gates) ~= 'table' then
            print('\ay[VF]\ax no spell_gates library to prune.')
            return 0
        end
        local function inBook(name)
            name = tostring(name or '')
            if name == '' then return false end
            local hit = false
            pcall(function()
                local b = mq.TLO.Me.Book(name)
                if not b or not b() then return end
                local v = b()
                if type(v) == 'number' then hit = v > 0
                else hit = tostring(v) ~= '' and tostring(v) ~= 'NULL' end
            end)
            if hit then return true end
            if U.apostropheVariants then
                for _, n in ipairs(U.apostropheVariants(name)) do
                    pcall(function()
                        local b = mq.TLO.Me.Book(n)
                        if b and b() then
                            local v = b()
                            if type(v) == 'number' then hit = v > 0
                            else hit = tostring(v) ~= '' and tostring(v) ~= 'NULL' end
                        end
                    end)
                    if hit then return true end
                end
            end
            return false
        end
        local dropped = {}
        for key, g in pairs(loadout.spell_gates) do
            local spell = type(g) == 'table' and g.spell or nil
            if not spell or spell == '' or not inBook(spell) then
                dropped[#dropped + 1] = tostring(spell or key)
                loadout.spell_gates[key] = nil
            end
        end
        table.sort(dropped)
        if #dropped == 0 then
            print('\ag[VF]\ax spell_gates already clean -- nothing to prune.')
            return 0
        end
        for i = 1, math.min(#dropped, 12) do
            print(string.format('\ay[VF]\ax pruned gate: %s', dropped[i]))
        end
        if #dropped > 12 then
            print(string.format('\ay[VF]\ax ...and %d more.', #dropped - 12))
        end
        print(string.format(
            '\ag[VF]\ax pruned %d spell_gates row(s). Save Settings (or wait for autosave) to persist.',
            #dropped))
        return #dropped
    end

    -- VF: Gate 7 — idle cold roles only. HoT is heal-family but may ride OOC missing-buff rows.
    local IDLE_COLD = { Buff = true, HoT = true, PetBuff = true, Summon = true }

    local function idleColdRole(entry)
        local role = runtime.castRole and runtime.castRole(entry) or nil
        return role and IDLE_COLD[role] == true
    end

    -- VF: Gate 7 — after zone, wait ~3s or until buff/song bar looks populated.
    runtime.onBuffZone = function()
        runtime.buffZoneSettleUntil = os.clock() + 3
        barNameCache = nil
        barNameCacheAt = 0
        if runtime.buffSessionClear then runtime.buffSessionClear() end
        -- VF: buffs never drop except zone — re-enter OOC so missing gems/clickies fire without a fight.
        if runtime.oocEnter and runtime.currentState and runtime.currentState() ~= 'combat' then
            runtime.oocEnter('zoned')
        end
    end

    local function barLooksPopulated()
        local n = 0
        pcall(function() n = tonumber(mq.TLO.Me.CountBuffs()) or 0 end)
        if n > 0 then return true end
        local songs = 0
        pcall(function() songs = tonumber(mq.TLO.Me.CountSongs()) or 0 end)
        if songs > 0 then return true end
        local bar = gatherSelfBarEffects(true)
        return bar and bar.names and #bar.names > 0
    end

    runtime.buffZoneSettled = function()
        local untilAt = runtime.buffZoneSettleUntil or 0
        if untilAt <= 0 then return true end
        if os.clock() >= untilAt then
            runtime.buffZoneSettleUntil = 0
            return true
        end
        if barLooksPopulated() then
            runtime.buffZoneSettleUntil = 0
            return true
        end
        return false
    end

    runtime.buffTick = function()
        if mq.TLO.Me.Dead() then return false end
        -- VF: Me.Casting lags under MQ2Cast — pending must block the next buff press.
        if runtime.castBusy and runtime.castBusy() then return true end
        if api.isCasting and api.isCasting() then return false end
        -- VF: after mq2cast SUCCESS, wait for bar before counting a miss.
        if runtime.buffAwaitSpell and runtime.buffAwaitKey then
            local spell = runtime.buffAwaitSpell
            local key = runtime.buffAwaitKey
            local myId = mq.TLO.Me.ID() or 0
            local age = os.clock() - (runtime.buffAwaitAt or 0)
            if runtime.buffFactuallyUp(myId, spell) then
                print(string.format('\ag[VF]\ax OOC "%s" landed on bar.', spell))
                runtime.buffAwaitSpell = nil
                runtime.buffAwaitKey = nil
                if runtime.buffTries then runtime.buffTries[key] = nil end
            elseif age >= 2.0 then
                local buffHit, songHit = false, false
                pcall(function() buffHit = not not mq.TLO.Me.Buff(spell)() end)
                pcall(function() songHit = not not mq.TLO.Me.Song(spell)() end)
                print(string.format(
                    '\ay[VF]\ax OOC "%s" Cast settled OK but bar miss (%.1fs) Me.Buff=%s Me.Song=%s — check if the spell actually lands by hand.',
                    spell, age, tostring(buffHit), tostring(songHit)))
                runtime.buffTryRecorded(key, spell)
                runtime.buffAwaitSpell = nil
                runtime.buffAwaitKey = nil
            else
                return true
            end
        end
        if runtime.rushOnTheMove and runtime.rushOnTheMove() then return false end
        if runtime.routeManaHold and runtime.routeManaHold() then return false end
        if runtime.postCombatBuffActive then
            if mq.TLO.Me.Moving() or (api.isMoveActive and api.isMoveActive()) then
                -- VF: only stop plugin movement — bare /nav stop with no path cancels WASD.
                pcall(function()
                    if mq.TLO.Navigation and mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
                end)
                pcall(function()
                    if mq.TLO.Stick and (mq.TLO.Stick.Active() or mq.TLO.Stick.Status() == 'ON') then
                        mq.cmd('/stick off')
                    end
                end)
            end
        elseif mq.TLO.Me.Moving() or (api.isMoveActive and api.isMoveActive()) then
            return false
        end
        local myId = mq.TLO.Me.ID() or 0
        if myId <= 0 then return false end
        local ctrl = api.ctrl
        if type(api.getCtrl) == 'function' then ctrl = api.getCtrl() or ctrl end
        local loadout = api.loadout
        if type(api.getLoadout) == 'function' then loadout = api.getLoadout() or loadout end
        if not ctrl or not loadout then return false end

        -- VF: OOC heal top-off may fire during zone settle.
        local inCs = (runtime.engineInCombat and runtime.engineInCombat())
            or (runtime.inCombatState and runtime.inCombatState()) or false
        if ctrl.post_combat_heal ~= false and not inCs then
            local targetPct = tonumber(ctrl.post_combat_heal_pct) or 90
            if api.pctHP and api.hasSelfHealLoadout
                and api.pctHP(myId) < targetPct and api.hasSelfHealLoadout() then
                if runtime.selfHealCast and runtime.selfHealCast() then return true end
            end
        end

        if not runtime.buffZoneSettled() then return false end

        local oocHold = runtime.postCombatBuffActive or runtime.oocBusy
        local petId = 0
        pcall(function() petId = mq.TLO.Me.Pet.ID() or 0 end)

        local function rowGates(entry, spellName, id)
            if not entry or not spellName or spellName == '' or not id or id <= 0 then return false end
            if not idleColdRole(entry) then return false end
            if entry.burn_only then return false end
            local pct = tonumber(entry.pct)
            if pct == nil then pct = 100 end
            if pct <= 0 then return false end
            if entry.enabled == false then return false end
            -- VF: Combat col always — oocHold must not fire In Combat rows after the fight.
            if api.rowBlocked and api.rowBlocked(entry, spellName, id) then
                return false
            end
            if runtime.itemLevelOk and not runtime.itemLevelOk(entry, id) then
                return false
            end
            if not api.conditionMet or not api.conditionMet(entry.when, pct, spellName, id, entry.cls) then
                return false
            end
            return true
        end

        -- VF: Summon first when pet missing — standstill cast before self buffs.
        -- VF: skip when the summon already sits on the bar (Familiar: Permanent).
        if petId <= 0 then
            for name, a in pairs(loadout.aas or {}) do
                if a and a.enabled and idleColdRole(a)
                    and (runtime.castRole(a) == 'Summon')
                    and not runtime.buffFactuallyUp(myId, name)
                    and rowGates(a, name, myId) then
                    if api.fireAA and api.fireAA(name, a, myId) then return true end
                end
            end
            for i = 1, D.NUM_GEMS do
                local g = loadout.gems[i]
                if g and g.spell and g.spell ~= '' and idleColdRole(g)
                    and (runtime.castRole(g) == 'Summon')
                    and not runtime.buffFactuallyUp(myId, g.spell)
                    and rowGates(g, g.spell, myId) then
                    local locked = api.castTracker and api.castTracker.isLockedOut(g.spell)
                    if not locked and api.castGem and api.castGem(i, g, myId) then return true end
                end
            end
        end

        -- VF: AAs — Buff/HoT (self), PetBuff (pet). Summon already tried.
        for name, a in pairs(loadout.aas or {}) do
            if a and a.enabled and idleColdRole(a) then
                local role = runtime.castRole(a)
                if role == 'PetBuff' and petId > 0
                    and not runtime.buffFactuallyUp(petId, name)
                    and rowGates(a, name, petId) then
                    if api.fireAA and api.fireAA(name, a, petId) then return true end
                elseif (role == 'Buff' or role == 'HoT')
                    and api.isIdleSelfBuff and api.isIdleSelfBuff(a.when, a.target)
                    and not runtime.buffFactuallyUp(myId, name)
                    and rowGates(a, name, myId) then
                    if api.fireAA and api.fireAA(name, a, myId) then return true end
                end
            end
        end

        -- VF: clicky items — Buff/HoT/PetBuff; bar check uses Clicky.Spell only.
        for name, it in pairs(loadout.items or {}) do
            if it and it.enabled and idleColdRole(it) then
                local role = runtime.castRole(it)
                local spellName = ''
                if runtime.itemBuffSpell then
                    spellName = runtime.itemBuffSpell(name, it) or ''
                elseif runtime.itemClickSpell then
                    spellName = runtime.itemClickSpell(name, it) or ''
                elseif it.spell and it.spell ~= '' then
                    spellName = it.spell
                end
                if spellName ~= '' then
                    if role == 'PetBuff' and petId > 0
                        and not runtime.buffFactuallyUp(petId, spellName)
                        and rowGates(it, spellName, petId) then
                        if api.fireItem and api.fireItem(name, it, petId) then return true end
                    elseif (role == 'Buff' or role == 'HoT')
                        and api.isIdleSelfBuff and api.isIdleSelfBuff(it.when, it.target)
                        and not runtime.buffFactuallyUp(myId, spellName)
                        and rowGates(it, spellName, myId) then
                        if api.fireItem and api.fireItem(name, it, myId) then return true end
                    end
                end
            end
        end

        -- VF: PetBuff gems.
        if petId > 0 then
            for i = 1, D.NUM_GEMS do
                local g = loadout.gems[i]
                if g and g.spell and g.spell ~= '' and idleColdRole(g)
                    and runtime.castRole(g) == 'PetBuff'
                    and not runtime.buffFactuallyUp(petId, g.spell)
                    and rowGates(g, g.spell, petId) then
                    local locked = api.castTracker and api.castTracker.isLockedOut(g.spell)
                    if not locked and api.castGem and api.castGem(i, g, petId) then
                        return true
                    end
                end
            end
        end

        for i = 1, D.NUM_GEMS do
            local g = loadout.gems[i]
            if g and g.spell and g.spell ~= '' and idleColdRole(g)
                and api.isIdleSelfBuff and api.isIdleSelfBuff(g.when, g.target) then
                local role = runtime.castRole(g)
                if role == 'Buff' or role == 'HoT' then
                    local persistSong = false
                    pcall(function()
                        local sk = tostring(mq.TLO.Spell(g.spell).Skill() or '')
                        persistSong = runtime.bardCastSkill and runtime.bardCastSkill(sk)
                            and not not mq.TLO.Spell(g.spell).Beneficial()
                    end)
                    local fighting = (runtime.engineInCombat and runtime.engineInCombat())
                        or (runtime.inCombatState and runtime.inCombatState()) or false
                    if persistSong and not oocHold and fighting then
                        -- VF: persist songs are not recast mid-fight.
                    elseif runtime.buffFactuallyUp(myId, g.spell) then
                        -- VF: already on buff or song bar.
                    else
                        local buffKey = (g.when == 'missing buff') and U.sungKey(g.spell, myId) or nil
                        local retryOk = (not buffKey) or runtime.buffRetryOk(buffKey)
                        local locked = api.castTracker and api.castTracker.isLockedOut(g.spell)
                        if retryOk and not locked and rowGates(g, g.spell, myId) then
                            if api.castGem and api.castGem(i, g, myId) then
                                -- VF: record after settle — castBusy means press landed; verify on next pass.
                                if buffKey then
                                    runtime.buffAwaitKey = buffKey
                                    runtime.buffAwaitSpell = g.spell
                                    runtime.buffAwaitAt = os.clock()
                                end
                                return true
                            end
                            local now = os.clock()
                            local throttle = false
                            pcall(function()
                                local key = 'g' .. i
                                throttle = (now - (runtime.lastCast[key] or 0)) < 1.2
                            end)
                            if throttle then
                                -- VF: lastCast gate — not a cast failure.
                            elseif (now - (runtime.lastBuffSkipAt or 0)) > 8 then
                                runtime.lastBuffSkipAt = now
                                print(string.format(
                                    '\ay[VF]\ax OOC "%s" (gem %d) missing but castGem refused (mem/ready/mana/busy?).',
                                    tostring(g.spell), i))
                            end
                        end
                    end
                end
            end
        end
        return false
    end

    runtime.hasMissingSelfBuff = function()
        local myId = mq.TLO.Me.ID() or 0
        if myId <= 0 then return false end
        local loadout = api.loadout
        if type(api.getLoadout) == 'function' then
            loadout = api.getLoadout() or loadout
        end
        if type(loadout) ~= 'table' then return false end
        local function missing(entry, name)
            if not entry or not name or name == '' then return false end
            if not idleColdRole(entry) then return false end
            if not api.isIdleSelfBuff or not api.isIdleSelfBuff(entry.when, entry.target) then return false end
            local pct = tonumber(entry.pct)
            if pct == nil then pct = 100 end
            if pct <= 0 or entry.burn_only then return false end
            if runtime.buffSessionIsBlocked and runtime.buffSessionIsBlocked(name) then return false end
            if runtime.buffFactuallyUp(myId, name) then return false end
            -- VF: Combat col always — missing In Combat rows must not hold OOC forever.
            if api.rowBlocked and api.rowBlocked(entry, name, myId) then
                return false
            end
            if runtime.itemLevelOk and not runtime.itemLevelOk(entry, myId) then
                return false
            end
            return true
        end
        for name, a in pairs(loadout.aas or {}) do
            if a and a.enabled and missing(a, name) then return true end
        end
        for name, it in pairs(loadout.items or {}) do
            if it and it.enabled then
                local spellName = ''
                if runtime.itemBuffSpell then
                    spellName = runtime.itemBuffSpell(name, it) or ''
                elseif runtime.itemClickSpell then
                    spellName = runtime.itemClickSpell(name, it) or ''
                elseif it.spell and it.spell ~= '' then
                    spellName = it.spell
                end
                -- VF: never treat the item name as a buff window match.
                if spellName ~= '' and missing(it, spellName) then return true end
            end
        end
        for i = 1, D.NUM_GEMS do
            local g = loadout.gems and loadout.gems[i]
            if g and missing(g, g.spell) then return true end
        end
        return false
    end
end

return M
