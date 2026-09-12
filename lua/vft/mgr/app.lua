-- VF: Loadout app.

local mq = require('mq')
local U = require('vft.mgr.util')
local S = require('vft.mgr.schema')
local IO = require('vft.mgr.io')
local UI = require('vft.mgr.ui')
local invLocks = require('vft.inv.locks')
local toonini = require('vft.toonini')

local function newState(hosted)
    return {
        open = false,
        hosted = not not hosted,
        t2Running = false,
        forceWrite = false,
        dead = false,
        noCharKey = false,
        charName = nil,
        allData = {},
        charEntry = nil,
        bar = {},
        spellRows = {},
        spellGates = {},
        skillRows = {},
        skillByName = {},
        aaRows = {},
        aaByName = {},
        itemRows = {},
        itemByName = {},
        itemEdit = nil,
        itemEditOpen = false,
        status = nil,
        statusOk = false,
        backedUp = false,
        offLimit = nil,
        filters = S.emptyFilters(),
        routes = S.emptyRoutes(),
        pull = S.defaultPull(),
        assist = S.defaultAssist(),
        groupTrust = S.defaultGroupTrust(),
        groupDraft = '',
        prefs = S.defaultPrefs(),
        aaQueue = S.emptyAaQueue(),
        aaBook = S.emptyAaBook(),
        loadoutPage = 'spells',
        aaCat = 'General',
        aaCatalog = { General = {}, Archetype = {}, Class = {} },
        routeLib = S.emptyRouteLib(),
        routeSave = nil,
        safeZones = S.copySafeZones(S.defaultSafeZones()),
        safeZoneDraft = '',
        aaNeedScan = false,
        aaScanPct = 0,
    }
end

local function create(opts)
    opts = opts or {}
    local hosted = not not opts.hosted
    local state = newState(hosted)
    local lastGemAt, lastSkillAt, lastSkillScanAt, lastAAAt, lastItemAt, lastFileAt, lastAaScanAt = 0, 0, 0, 0, 0, 0, 0
    local aaScanIdx, aaSeen, aaBuild, aaScanHoldUntil = 1, {}, { General = {}, Archetype = {}, Class = {} }, 0
    local aaNamesSeeded = false
    local hydratedName = nil

    local function setStatus(ok, msg)
        state.statusOk = not not ok
        state.status = msg
        if msg then
            if ok then
                print('\ag[VF Mgr]\ax ' .. msg)
            else
                print('\ar[VF Mgr]\ax ' .. msg)
            end
        end
    end

    local function refreshEntry()
        if hosted and opts.getCharEntry then
            state.charEntry = S.migrateEntry(opts.getCharEntry() or { gems = {}, discs = {}, aas = {} })
            state.charName = IO.charName()
            state.dead = false
            state.noCharKey = false
            state.t2Running = false
            return
        end
        local now = os.clock()
        if (now - lastFileAt) < 2.0 then
            state.charName = IO.charName()
            state.dead = IO.isDeadOrCorpse(state.charName)
            state.t2Running = IO.t2IsRunning()
            return
        end
        lastFileAt = now
        local all = IO.loadAll()
        state.allData = all
        local nm = IO.charName()
        state.charName = nm
        state.dead = IO.isDeadOrCorpse(nm)
        state.t2Running = IO.t2IsRunning()
        if nm and type(all[nm]) == 'table' then
            state.charEntry = all[nm]
            state.noCharKey = false
        else
            state.charEntry = nil
            state.noCharKey = nm ~= nil
        end
    end

    local function attachSpellRows()
        local gems = state.charEntry and state.charEntry.gems
        for i = 1, S.NUM_GEMS do
            local nm = state.bar[i] or ''
            local existing = S.lookupSpellGate(state.spellGates, gems, nm)
            state.spellRows[i] = S.rowFromGem(mq, i, nm, existing)
        end
    end

    local function abilityName(v)
        if type(v) ~= 'string' then return '' end
        local t = U.trimName(v)
        if t == '' or t == 'NULL' or t == 'true' or t == 'false' then return '' end
        if not t:match('^[%a]') then return '' end
        return t
    end

    -- VF: Instant Disciplines paint from saved discs — live pulseSkills reconciles after.
    -- VF: via=skill rows are MQ2Melee's; do not seed them into the Disciplines list.
    local function seedSkillRowsFromSheet()
        local discs = state.charEntry and state.charEntry.discs
        local nextByName, nextRows = {}, {}
        if type(discs) == 'table' then
            for name, existing in pairs(discs) do
                name = abilityName(name)
                if name ~= '' and type(existing) == 'table' and existing.via ~= 'skill' then
                    local typ = S.typeFromStored(existing) or 'Nuke'
                    local row = S.rowFromAbility(name, existing, 'disc', typ)
                    nextByName[name] = row
                    nextRows[#nextRows + 1] = row
                end
            end
        end
        table.sort(nextRows, function(a, b)
            return (a.name or '') < (b.name or '')
        end)
        state.skillByName = nextByName
        state.skillRows = nextRows
    end

    local function aaName(v)
        if type(v) ~= 'string' then return '' end
        local t = U.trimName(v)
        if t == '' or t == 'NULL' or t == 'true' or t == 'false' then return '' end
        return t
    end

    -- VF: Instant AA Loadout paint from saved aas — pulseAA reconciles after.
    local function seedAaRowsFromSheet()
        local aas = state.charEntry and state.charEntry.aas
        local nextByName, nextRows = {}, {}
        if type(aas) == 'table' then
            for name, existing in pairs(aas) do
                name = aaName(name)
                if name ~= '' and type(existing) == 'table' then
                    local row = S.rowFromAbility(name, existing, nil, S.typeFromStored(existing) or 'Nuke')
                    row.cooldown = ''
                    nextByName[name] = row
                    nextRows[#nextRows + 1] = row
                end
            end
        end
        table.sort(nextRows, function(a, b)
            return (a.name or '') < (b.name or '')
        end)
        state.aaByName = nextByName
        state.aaRows = nextRows
    end

    -- VF: INI extras (before/after, level) overlay empty UI fields.
    local function overlayItemIni(row)
        if not row or not row.name then return end
        local rec = toonini.item(row.name)
        if not rec then return end
        if (not row.cmdBefore or row.cmdBefore == '') then
            row.cmdBefore = rec.cmd_before or rec.before or ''
        end
        if (not row.cmdAfter or row.cmdAfter == '') then
            row.cmdAfter = rec.cmd_after or rec.after or ''
        end
        if (not row.keepBuff or row.keepBuff == '') then
            row.keepBuff = rec.keep_buff or ''
        end
        if (not row.levelMin or row.levelMin == '') and rec.level_min and tostring(rec.level_min) ~= '' then
            row.levelMin = tostring(rec.level_min)
        end
        if (not row.levelMax or row.levelMax == '') and rec.level_max and tostring(rec.level_max) ~= '' then
            row.levelMax = tostring(rec.level_max)
        end
        if (not row.mobs or row.mobs == '') and rec.mobs and tostring(rec.mobs) ~= '' then
            row.mobs = rec.mobs
            local op, n = S.mobsPartsFromText(rec.mobs)
            row.mobsOp = op or row.mobsOp
            row.mobsN = n or row.mobsN
        end
        local iid = tonumber(rec.id or rec.item_id) or 0
        if (not row.itemId or row.itemId == 0) and iid > 0 then row.itemId = iid end
    end

    function state.lockItem(row)
        if not row or not row.name then return end
        local id = tonumber(row.itemId) or 0
        if id <= 0 then
            pcall(function()
                local fi = mq.TLO.FindItem('=' .. row.name)
                if fi and fi() then
                    id = tonumber(fi.ID()) or 0
                    row.itemId = id
                    row.icon = tonumber(fi.Icon()) or row.icon or 0
                end
            end)
        end
        if id <= 0 then return end
        invLocks.lockItem(id, row.name)
    end

    -- VF: Instant Items paint from saved clickies — pulseItems reconciles after.
    local function seedItemRowsFromSheet()
        local items = state.charEntry and state.charEntry.items
        local nextByName, nextRows = {}, {}
        if type(items) == 'table' then
            for name, existing in pairs(items) do
                name = U.trimName(name)
                if name ~= '' and type(existing) == 'table' then
                    local typ = S.typeFromStored(existing)
                        or (existing.spell and S.inferTypeFromTLO(mq, existing.spell))
                        or 'Buff'
                    local row = S.rowFromAbility(name, existing, 'item', typ)
                    row.spell = existing.spell or ''
                    row.effectType = existing.effect_type or ''
                    row.where = ''
                    row.cooldown = ''
                    nextByName[name] = row
                    nextRows[#nextRows + 1] = row
                end
            end
        end
        table.sort(nextRows, function(a, b)
            return (a.name or '') < (b.name or '')
        end)
        for _, row in ipairs(nextRows) do overlayItemIni(row) end
        state.itemByName = nextByName
        state.itemRows = nextRows
    end

    local function hydrateIfNeeded()
        local nm = state.charName
        if nm == hydratedName then return end
        hydratedName = nm
        local storedLim = state.charEntry and tonumber(state.charEntry.off_limit or state.charEntry.t3_off_limit)
        state.offLimit = storedLim
        state.spellGates = S.seedSpellGates(state.charEntry)
        attachSpellRows()
        -- VF: paint Loadout from the char sheet first so Disciplines/AA are not empty
        -- VF: while the live scan catches up (looks bugged otherwise).
        seedSkillRowsFromSheet()
        seedAaRowsFromSheet()
        seedItemRowsFromSheet()
        lastSkillAt = 0
        lastSkillScanAt = 0
        lastAAAt = 0
        lastItemAt = 0
        state.aaBook = S.copyAaBook(state.charEntry and state.charEntry.aa_book)
        state.aaCatalog = S.aaCatalogFromBook(state.aaBook)
        if S.aaBookReady(state.aaBook) then
            state.aaNeedScan = false
            state.aaScanPct = 100
        else
            if aaScanIdx <= 1 then
                lastAaScanAt = 0
                aaScanHoldUntil = 0
                aaScanIdx, aaSeen = 1, {}
                aaBuild = { General = {}, Archetype = {}, Class = {} }
                aaNamesSeeded = false
                state.aaScanPct = 0
            end
            state.aaNeedScan = true
        end
        state.filters = S.copyFilters(state.charEntry and (state.charEntry.filters or state.charEntry.t3_filters))
        local rawWp = state.charEntry and state.charEntry.waypoints
        state.routes = S.copyRoutes(rawWp)
        local liveCtrl = state.charEntry and (state.charEntry.control or state.charEntry.ctrl)
        S.seedRoutePacksFromCtrl(state.routes, rawWp and rawWp.zones, liveCtrl)
        state.pull = S.copyPull(liveCtrl)
        state.assist = S.copyAssist(liveCtrl)
        state.groupTrust = S.copyGroupTrust(liveCtrl)
        state.groupDraft = ''
        state.prefs = S.copyPrefs(liveCtrl)
        state.aaQueue = S.copyAaQueue(state.charEntry and state.charEntry.aa_queue)
        state.safeZones = IO.loadSafeZones()
        state.safeZoneDraft = ''
        local z = ''
        pcall(function() z = tostring(mq.TLO.Zone.ShortName() or '') end)
        if z == 'NULL' then z = '' end
        state.routeLibZone = z
        state.routeLib = IO.loadRouteLib(z)
        state.routeLibApplied = false
        if z ~= '' then
            if not state.routes then state.routes = S.emptyRoutes() end
            S.ensureRouteZone(state.routes, z)
            state.routes.liveZone = z
            state.routes.zone = z
        end
    end

    local function pulseGems()
        local now = os.clock()
        if (now - lastGemAt) < 0.25 then return end
        lastGemAt = now
        for i = 1, S.NUM_GEMS do
            local nm = ''
            pcall(function()
                local g = mq.TLO.Me.Gem(i)
                if g then nm = g.Name() or '' end
            end)
            if nm == 'NULL' then nm = '' end
            state.bar[i] = nm
        end
        if not state.spellRows[1] then
            attachSpellRows()
            return
        end
        local gems = state.charEntry and state.charEntry.gems
        for i = 1, S.NUM_GEMS do
            local row = state.spellRows[i]
            local nm = state.bar[i] or ''
            if U.normalizeSpellName(row and row.name or '') ~= U.normalizeSpellName(nm) then
                S.rememberSpellGate(state.spellGates, row)
                local donor
                for j = 1, S.NUM_GEMS do
                    local other = state.spellRows[j]
                    if j ~= i and other and not other.empty
                        and U.normalizeSpellName(other.name) == U.normalizeSpellName(nm)
                        and nm ~= '' then
                        donor = other
                    end
                end
                if donor then
                    state.spellRows[i] = {
                        gem = i,
                        name = nm,
                        type = donor.type,
                        combat = donor.combat,
                        burn = donor.burn,
                        above = donor.above,
                        below = donor.below,
                        mobs = donor.mobs,
                        mobsOp = donor.mobsOp,
                        mobsN = donor.mobsN,
                        mobsOk = donor.mobsOk,
                        pri = donor.pri,
                        enabled = donor.enabled,
                        empty = false,
                        cls = donor.cls,
                        source = donor.source,
                    }
                else
                    local existing = S.lookupSpellGate(state.spellGates, gems, nm)
                    state.spellRows[i] = S.rowFromGem(mq, i, nm, existing)
                end
            end
        end
    end

    -- VF: Disc: Me.CombatAbility slot. abilityName is defined above for sheet seed.

    local function skillPts(name)
        local v
        pcall(function() v = mq.TLO.Me.Skill(name)() end)
        return tonumber(v)
    end

    local function pulseSkills()
        local now = os.clock()
        -- VF: Timer paint ~1s; name scan ~5s (Spell TLO per disc was stalling the sheet).
        if (now - lastSkillAt) < 1.0 then return end
        lastSkillAt = now
        local keep = state.skillByName
        local needScan = (now - lastSkillScanAt) >= 5.0
            or not keep
            or next(keep) == nil
        local MeleeCat = nil
        pcall(function() MeleeCat = require('vft.mgr.melee_catalog') end)

        local function discRemainingSec(name)
            local sec = 0
            pcall(function()
                local timerVal = mq.TLO.Me.CombatAbilityTimer(name)
                if not timerVal then return end
                if type(timerVal.TotalSeconds) == 'function' then
                    sec = tonumber(timerVal.TotalSeconds()) or 0
                elseif type(timerVal.TotalSeconds) == 'number' then
                    sec = timerVal.TotalSeconds
                else
                    local v = timerVal()
                    if type(v) == 'number' then
                        sec = v
                        if sec >= 1000 then sec = sec / 1000 end
                    end
                end
            end)
            return sec
        end

        -- VF: Cache reuse, duration, level, RecastTimerID (Combat Skills Timer group).
        local function ensureDiscMeta(row)
            if not row or not row.name then return end
            if row._metaOk and row.timerId ~= nil then return end
            local reuse, dur, lvl, timerId = 0, 0, 0, 0
            pcall(function()
                local sp = mq.TLO.Spell(row.name)
                if not (sp and sp()) then return end
                local rt = tonumber(sp.RecastTime()) or 0
                if rt > 0 then
                    if rt > 1800 then reuse = rt / 1000 else reuse = rt end
                end
                if reuse == 0 and type(sp.RecastTime) == 'userdata' then
                    local ts = 0
                    pcall(function() ts = sp.RecastTime.TotalSeconds() or 0 end)
                    if ts > 0 then reuse = ts end
                end
                local ticks = tonumber(sp.Duration()) or tonumber(sp.MyDuration()) or 0
                if ticks > 0 then dur = ticks * 6 end
                -- VF: Combat Skills uses per-class Level[class]; bare Level() is primary class (often 255 on discs).
                local best = 255
                for c = 1, 16 do
                    local v = 0
                    pcall(function() v = tonumber(sp.Level(c)()) or 0 end)
                    if v > 0 and v < best then best = v end
                end
                if best < 255 then
                    lvl = best
                else
                    lvl = 0
                end
                -- VF: Combat Skills "Timer" column = recast timer group id.
                if sp.RecastTimerID then
                    timerId = tonumber(sp.RecastTimerID()) or 0
                end
                if (not timerId or timerId <= 0) and sp.TimerID then
                    timerId = tonumber(sp.TimerID()) or 0
                end
            end)
            row.cooldownSec = reuse
            row.durationSec = dur
            row.duration = U.fmtHMS(dur)
            row.level = lvl
            row.timerId = timerId
            row._metaOk = true
        end

        local function paintDiscTimers(row)
            ensureDiscMeta(row)
            local reuse = tonumber(row.cooldownSec) or 0
            local left = discRemainingSec(row.name)
            row.cooldownLeft = left
            row.cooldown = reuse > 0 and U.fmtHMS(reuse) or '—'
            row.duration = U.fmtHMS(tonumber(row.durationSec) or 0)
        end

        if not needScan then
            for _, row in pairs(keep or {}) do
                if row and row.via ~= 'skill' then paintDiscTimers(row) end
            end
            return
        end
        lastSkillScanAt = now

        local nextByName = {}
        local nextRows = {}

        local function addDisc(name)
            name = abilityName(name)
            if name == '' then return end
            if S.SPECIAL_SKILL and S.SPECIAL_SKILL[name] then return end
            if MeleeCat and MeleeCat.isDelegated and MeleeCat.isDelegated(name) then return end
            if nextByName[name] then return end
            local row = keep and keep[name]
            if not row then
                local discs = state.charEntry and state.charEntry.discs
                local existing = discs and discs[name] or nil
                local typ = S.typeFromStored(existing) or 'Nuke'
                row = S.rowFromAbility(name, existing, 'disc', typ)
            end
            row.via = 'disc'
            row.skillPts = skillPts(name)
            row._metaOk = false
            paintDiscTimers(row)
            nextByName[name] = row
            nextRows[#nextRows + 1] = row
        end

        pcall(function()
            local function caName(i)
                local name
                pcall(function()
                    local ca = mq.TLO.Me.CombatAbility(i)
                    if not ca then return end
                    local v = ca()
                    if type(v) == 'string' then
                        name = v
                    elseif type(v) == 'number' and v > 0 and ca.Name then
                        name = ca.Name()
                    elseif ca.Name then
                        name = ca.Name()
                    end
                end)
                return abilityName(name)
            end
            local count = 0
            pcall(function() count = tonumber(mq.TLO.Me.CombatAbilityCount()) or 0 end)
            if count > 0 then
                for i = 1, count do
                    local name = caName(i)
                    if name ~= '' then addDisc(name) end
                end
            elseif keep and next(keep) then
                -- VF: keep sheet-seeded names; avoid 300-slot blank walk on slow TLO.
                for name, _ in pairs(keep) do addDisc(name) end
            else
                local blank = 0
                for i = 1, 80 do
                    local name = caName(i)
                    if name ~= '' then
                        blank = 0
                        addDisc(name)
                    else
                        blank = blank + 1
                        if i > 20 and blank > 15 then break end
                    end
                end
            end
        end)
        table.sort(nextRows, function(a, b)
            return (a.name or '') < (b.name or '')
        end)
        if #nextRows == 0 and #(state.skillRows or {}) > 0 then
            for _, row in ipairs(state.skillRows) do
                if row.via ~= 'skill' then paintDiscTimers(row) end
            end
            return
        end
        state.skillByName = nextByName
        state.skillRows = nextRows
    end

    -- VF: Full reuse period — not AltAbilityTimer (that is remaining CD).
    local function aaReuseSec(aa, name)
        local best = 0
        local function consider(v)
            v = tonumber(v) or 0
            if v <= 0 then return end
            if v >= 1000 then v = v / 1000 end
            if v > best then best = v end
        end
        pcall(function()
            if not aa and name then aa = mq.TLO.Me.AltAbility(name) end
            if not aa then return end
            -- VF: MyReuseTime includes haste; ReuseTime is base.
            if aa.MyReuseTime then consider(aa.MyReuseTime()) end
            if aa.ReuseTime then consider(aa.ReuseTime()) end
            if aa.SpellReuseTime then consider(aa.SpellReuseTime()) end
            local sp = aa.Spell
            if sp and sp() and sp.RecastTime then consider(sp.RecastTime()) end
        end)
        return best
    end

    local function aaRemainingSec(name)
        local left = 0
        pcall(function()
            left = tonumber(mq.TLO.Me.AltAbilityTimer(name)()) or 0
            if left >= 1000 then left = left / 1000 end
        end)
        return left
    end

    -- VF: No cooldown → not an activated AA. Passive (Rapid Defiance) is never a combat click.
    local function isActivatedAA(aa, name)
        local passive = false
        pcall(function()
            if not aa and name then aa = mq.TLO.Me.AltAbility(name) end
            if aa and aa.Passive then passive = not not aa.Passive() end
        end)
        if passive then return false end
        return aaReuseSec(aa, name) > 0
    end

    local function aaCooldown(name)
        local sec = aaReuseSec(nil, name)
        if sec <= 0 then return '', 0 end
        local label = U.fmtSec(math.floor(sec + 0.5))
        local left = aaRemainingSec(name)
        if left > 0.5 then
            label = label .. ' CD ' .. U.fmtSec(math.floor(left + 0.5))
        end
        return label, sec
    end

    local function aaTooltip(name, aa)
        local tip = ''
        pcall(function()
            if not aa then aa = mq.TLO.Me.AltAbility(name) end
            if not aa then return end
            if aa.Description then
                tip = tostring(aa.Description() or '')
            end
            if (tip == '' or tip == 'NULL') and aa.Spell then
                local sp = aa.Spell
                if sp and sp.Description then
                    tip = tostring(sp.Description() or '')
                end
            end
        end)
        if tip == 'NULL' then tip = '' end
        return tip
    end

    local function pulseAA()
        local now = os.clock()
        if (now - lastAAAt) < 5.0 then return end
        lastAAAt = now
        local keep = state.aaByName
        local nextByName = {}
        local nextRows = {}

        local function addAA(name)
            name = aaName(name)
            if name == '' or nextByName[name] then
                if nextByName[name] then
                    local cd, sec = aaCooldown(name)
                    nextByName[name].cooldown = cd
                    nextByName[name].cooldownSec = sec
                end
                return
            end
            local row = keep[name]
            if not row then
                local aas = state.charEntry and state.charEntry.aas
                local existing = aas and aas[name] or nil
                row = S.rowFromAbility(name, existing, nil, S.typeFromStored(existing) or 'Nuke')
            end
            local cd, sec = aaCooldown(name)
            row.cooldown = cd
            row.cooldownSec = sec
            if not row.tooltip or row.tooltip == '' then
                row.tooltip = aaTooltip(name)
            end
            nextByName[name] = row
            nextRows[#nextRows + 1] = row
        end

        local function consider(name, aa)
            name = aaName(name)
            if name == '' then return end
            local rank = 0
            pcall(function()
                if not aa then aa = mq.TLO.Me.AltAbility(name) end
                if aa and aa.Rank then rank = tonumber(aa.Rank()) or 0 end
            end)
            if rank > 0 and isActivatedAA(aa, name) then addAA(name) end
        end

        local book = state.aaBook
        if not S.aaBookReady(book) then
            book = state.charEntry and state.charEntry.aa_book
        end
        if S.aaBookReady(book) then
            for _, rec in ipairs(book.purchased or {}) do
                if rec.activated then consider(rec.name, nil) end
            end
        else
            for i = 1, 2500 do
                local name, aa
                pcall(function()
                    aa = mq.TLO.Me.AltAbility(i)
                    if aa then
                        if aa.Name then name = aa.Name() end
                        if type(name) ~= 'string' then name = aa() end
                    end
                end)
                consider(name, aa)
            end
        end
        local stored = state.charEntry and state.charEntry.aas
        if type(stored) == 'table' then
            for name, _ in pairs(stored) do
                consider(name, nil)
            end
        end
        table.sort(nextRows, function(a, b)
            return (a.name or '') < (b.name or '')
        end)
        -- VF: empty AA scan must not blank sheet-seeded rows while the book builds.
        if #nextRows == 0 and #(state.aaRows or {}) > 0 then
            return
        end
        local same = #nextRows == #(state.aaRows or {})
        if same then
            for i, row in ipairs(state.aaRows) do
                if row.name ~= nextRows[i].name then
                    same = false
                    break
                end
            end
        end
        if same then
            for name, row in pairs(nextByName) do
                local cur = keep[name]
                if cur then cur.cooldown = row.cooldown end
            end
            return
        end
        state.aaByName = nextByName
        state.aaRows = nextRows
    end

    -- VF: right-click clickies on worn + bags (Item.Clicky / EffectType Click*).
    local function pulseItems()
        local now = os.clock()
        if (now - lastItemAt) < 3.0 then return end
        lastItemAt = now
        local keep = state.itemByName or {}
        local nextByName, nextRows = {}, {}

        local function addClicky(item, where)
            if not item then return end
            local name, spellName, effectType, tip = '', '', '', ''
            local hasClicky = false
            pcall(function()
                if not item() then return end
                name = tostring(item.Name() or '')
                if name == '' or name == 'NULL' then return end
                local et = tostring(item.EffectType() or '')
                if et == 'NULL' then et = '' end
                local clicky = item.Clicky
                if clicky and clicky() then
                    hasClicky = true
                    local sp = clicky.Spell
                    if sp and sp() then
                        spellName = tostring(sp.Name() or sp() or '')
                        if spellName == 'NULL' then spellName = '' end
                        if sp.Description then
                            tip = tostring(sp.Description() or '')
                            if tip == 'NULL' then tip = '' end
                        end
                    end
                end
                if not hasClicky and et:find('Click', 1, true) then
                    hasClicky = true
                    local sp = item.Spell
                    if sp and sp() then
                        spellName = tostring(sp.Name() or sp() or '')
                        if spellName == 'NULL' then spellName = '' end
                    end
                end
                if hasClicky then effectType = et end
            end)
            if not hasClicky or name == '' then return end
            if nextByName[name] then
                -- VF: prefer worn label when the same clicky is also in a bag.
                if where == 'worn' then nextByName[name].where = 'worn' end
                return
            end
            local row = keep[name]
            local items = state.charEntry and state.charEntry.items
            local existing = items and items[name] or nil
            if not row then
                local typ = S.typeFromStored(existing)
                    or (spellName ~= '' and S.inferTypeFromTLO(mq, spellName))
                    or 'Buff'
                row = S.rowFromAbility(name, existing, 'item', typ)
                overlayItemIni(row)
            end
            row.via = 'item'
            row.spell = (existing and existing.spell) or spellName or row.spell or ''
            if row.spell == '' and spellName ~= '' then row.spell = spellName end
            row.effectType = effectType or row.effectType or ''
            row.where = where or ''
            if tip and tip ~= '' then row.tooltip = tip end
            local left = 0
            pcall(function()
                left = tonumber(item.TimerReady()) or 0
            end)
            row.cooldownLeft = left
            row.cooldown = left > 0 and U.fmtHMS(left) or ''
            pcall(function()
                row.itemId = tonumber(item.ID()) or row.itemId or 0
                row.icon = tonumber(item.Icon()) or row.icon or 0
            end)
            if S.itemExtraBuffs then
                row.extraBuffs = S.itemExtraBuffs(mq, name, row.spell)
            end
            nextByName[name] = row
            nextRows[#nextRows + 1] = row
        end

        -- VF: worn 0..22, packs 23..34 (contents via Item[n]).
        for slot = 0, 22 do
            local it
            pcall(function() it = mq.TLO.Me.Inventory(slot) end)
            addClicky(it, 'worn')
        end
        for pack = 23, 34 do
            local bag
            pcall(function() bag = mq.TLO.Me.Inventory(pack) end)
            local slots = 0
            pcall(function()
                if bag and bag() then slots = tonumber(bag.Container()) or 0 end
            end)
            if slots > 0 then
                for i = 1, slots do
                    local it
                    pcall(function() it = bag.Item(i) end)
                    addClicky(it, 'bag')
                end
            else
                addClicky(bag, 'bag')
            end
        end

        -- VF: keep enabled prefs for clickies temporarily missing from bags.
        local stored = state.charEntry and state.charEntry.items
        if type(stored) == 'table' then
            for name, existing in pairs(stored) do
                name = U.trimName(name)
                if name ~= '' and not nextByName[name] and type(existing) == 'table'
                    and existing.enabled == true then
                    local typ = S.typeFromStored(existing)
                        or (existing.spell and S.inferTypeFromTLO(mq, existing.spell))
                        or 'Buff'
                    local row = keep[name]
                    if not row then
                        row = S.rowFromAbility(name, existing, 'item', typ)
                        overlayItemIni(row)
                    end
                    row.via = 'item'
                    row.spell = existing.spell or row.spell or ''
                    row.effectType = existing.effect_type or row.effectType or ''
                    row.where = 'missing'
                    row.cooldown = ''
                    nextByName[name] = row
                    nextRows[#nextRows + 1] = row
                end
            end
        end

        table.sort(nextRows, function(a, b)
            return (a.name or '') < (b.name or '')
        end)
        if #nextRows == 0 and #(state.itemRows or {}) > 0 then
            return
        end
        state.itemByName = nextByName
        state.itemRows = nextRows
        if state.itemEdit and state.itemEdit.name then
            state.itemEdit = nextByName[state.itemEdit.name] or state.itemEdit
        end
    end

    local AA_SCAN_MAX = 16000
    local AA_SCAN_SLICE = 400

    -- VF: AltAbility ToString is GroupID, not Name. Never use aa() as the title.
    local function aaTloName(aa)
        local name = ''
        pcall(function()
            if aa and aa.Name then name = tostring(aa.Name() or '') end
        end)
        if name == 'NULL' then name = '' end
        return name
    end

    local function aaBucket(aa)
        local cat, typ = '', 0
        pcall(function()
            if aa.Category then cat = tostring(aa.Category() or ''):lower() end
            if aa.Type then typ = tonumber(aa.Type()) or 0 end
        end)
        if cat == 'null' then cat = '' end
        if cat:find('class', 1, true) then return 'Class' end
        if cat:find('archetype', 1, true) or cat:find('archtype', 1, true) then return 'Archetype' end
        if cat:find('general', 1, true) then return 'General' end
        if typ == 3 then return 'Class' end
        if typ == 2 then return 'Archetype' end
        -- VF: Type 0/1/4+ still list. Skipping unknown buckets hid every unowned General.
        if typ == 1 or typ <= 0 or typ >= 4 then return 'General' end
        return 'General'
    end

    -- VF: AltAbility[name|id] is the full database. Me.AltAbility is character-only.
    -- VF: Rank already applies HasAlternateAbility. PointsSpent is TotalPoints — not yours.
    local function aaOwnedRank(aa, name)
        local owned, maxr = 0, 0
        pcall(function()
            if aa and aa.MaxRank then maxr = tonumber(aa.MaxRank()) or 0 end
            if aa and aa.Rank then owned = tonumber(aa.Rank()) or 0 end
        end)
        if name and name ~= '' then
            local mineName, meRank, meMax = '', 0, 0
            pcall(function()
                local mine = mq.TLO.Me.AltAbility(name)
                if mine and mine.Name then mineName = tostring(mine.Name() or '') end
                if mineName == 'NULL' then mineName = '' end
                if mineName ~= '' then
                    if mine.Rank then meRank = tonumber(mine.Rank()) or 0 end
                    if mine.MaxRank then meMax = tonumber(mine.MaxRank()) or 0 end
                end
            end)
            if mineName == '' then
                owned = 0
            elseif not aa then
                owned = meRank
                if meMax > maxr then maxr = meMax end
            elseif meMax > maxr then
                maxr = meMax
            end
        end
        if maxr < 1 then maxr = 1 end
        if owned < 0 then owned = 0 end
        if owned > maxr then owned = maxr end
        return owned, maxr
    end

    -- VF: unowned AAs can miss a numeric walk. Name + id lookup still lists them.
    local AA_NAME_SEED = {
        'Innate Strength', 'Innate Stamina', 'Innate Agility', 'Innate Dexterity',
        'Innate Intelligence', 'Innate Wisdom', 'Innate Charisma',
        'Innate Fire Protection', 'Innate Cold Protection', 'Innate Magic Protection',
        'Innate Poison Protection', 'Innate Disease Protection',
        'Innate Run Speed', 'Innate Regeneration', 'Innate Metabolism', 'Innate Lung Capacity',
        'Combat Agility', 'Combat Stability', 'Combat Fury', 'Combat Medic',
        'Natural Durability', 'Mystical Attuning', 'First Aid', 'Bandage Wounds',
        'Delay Death', 'Packrat', 'Planar Durability', 'Battle Ready',
        'Baking Mastery', 'Blacksmithing Mastery', 'Brewing Mastery', 'Fletching Mastery',
        'Foraging', 'Discordant Defiance', 'Energetic Attunement', 'Eyes Wide Open',
        'New Tanaan Crafting Mastery', 'Persistent Illusion', 'Salvage',
    }

    local function ingestAa(aa, fallbackKey)
        local name = aaTloName(aa)
        -- VF: skip GroupID-as-title leaks and empty Name().
        if name == '' or not name:find('%a') then return end
        local gid
        pcall(function() gid = tonumber(aa.GroupID()) end)
        local key = gid or fallbackKey
        if not key then return end
        local bucket = aaBucket(aa) or 'General'
        local owned, maxr, cost, canTrain, buyId = 0, 1, 0, false, 0
        pcall(function()
            if aa.Cost then cost = tonumber(aa.Cost()) or 0 end
            if aa.CanTrain then canTrain = aa.CanTrain() and true or false end
            if aa.NextIndex then buyId = tonumber(aa.NextIndex()) or 0 end
            if buyId < 1 and aa.Index then buyId = tonumber(aa.Index()) or 0 end
        end)
        owned, maxr = aaOwnedRank(aa, name)
        -- VF: CanTrain means a rank is still buyable. Rank==MaxRank is the unowned lie.
        if canTrain and owned >= maxr then owned = 0 end
        local row = {
            name = name,
            gid = gid,
            bucket = bucket,
            cost = cost,
            owned = owned,
            max = maxr,
            canTrain = canTrain,
            buyId = buyId,
            activated = owned > 0 and isActivatedAA(aa, name),
        }
        local prev = aaSeen[key]
        local hop = tonumber(row.buyId) or 0
        local prevHop = prev and (tonumber(prev.buyId) or 0) or 0
        if not prev or (hop > 0 and (prevHop == 0 or hop < prevHop)) then
            aaSeen[key] = row
        end
    end

    local function ingestName(name, gid)
        name = tostring(name or '')
        if name == '' then return end
        gid = tonumber(gid)
        local aa
        pcall(function() aa = mq.TLO.AltAbility(name) end)
        if aaTloName(aa) == '' and gid then
            pcall(function() aa = mq.TLO.AltAbility(gid) end)
            local got = aaTloName(aa)
            if got ~= '' and got:lower() ~= name:lower() then
                ingestAa(aa, gid)
                aa = nil
            end
        end
        if aaTloName(aa) ~= '' then
            ingestAa(aa, gid or ('name:' .. name))
        end
        local want = string.lower(name)
        for _, row in pairs(aaSeen) do
            if string.lower(tostring(row.name or '')) == want then return end
        end
        -- VF: TLO miss still lists the name so Autobuy is not only "already owned".
        local owned, maxr = aaOwnedRank(nil, name)
        if owned >= maxr then owned = 0 end
        aaSeen['name:' .. name] = {
            name = name,
            gid = gid,
            bucket = 'General',
            cost = 0,
            owned = owned,
            max = maxr,
            canTrain = true,
            buyId = 0,
            activated = false,
        }
    end

    local function ingestKnownNames()
        local book = state.aaBook
        if (not book or not S.aaBookReady(book)) and state.charEntry then
            book = state.charEntry.aa_book
        end
        if type(book) == 'table' then
            for _, rec in ipairs(book.purchased or {}) do
                if rec and rec.name then ingestName(rec.name, rec.gid) end
            end
            for _, rec in ipairs(book.unpurchased or {}) do
                if rec and rec.name then ingestName(rec.name, rec.gid) end
            end
        end
        for _, name in ipairs(AA_NAME_SEED) do ingestName(name) end
    end

    local function compileAaBook()
        local book = S.emptyAaBook()
        book.at = os.time()
        -- VF: same name, two groups (original + universal +20000). Keep the open chain
        -- VF: (not-maxed over maxed, then highest owned, then highest max).
        local bestByName = {}
        for _, row in pairs(aaSeen) do
            local n = string.lower(tostring(row.name or ''))
            if n ~= '' then
                local prev = bestByName[n]
                local ow, mx = tonumber(row.owned) or 0, tonumber(row.max) or 0
                local pow = prev and (tonumber(prev.owned) or 0) or -1
                local pmx = prev and (tonumber(prev.max) or 0) or -1
                local open = ow < mx
                local prevOpen = prev and pow < pmx
                local take = not prev
                    or (open and not prevOpen)
                    or (open == prevOpen and (ow > pow or (ow == pow and mx > pmx)))
                if take then bestByName[n] = row end
            end
        end
        for _, row in pairs(aaSeen) do
            local n = string.lower(tostring(row.name or ''))
            if n ~= '' and bestByName[n] == row then
                if (row.owned or 0) > 0 then
                    book.purchased[#book.purchased + 1] = {
                        name = row.name,
                        gid = row.gid,
                        bucket = row.bucket,
                        owned = row.owned,
                        max = row.max,
                        activated = row.activated and true or false,
                    }
                end
                if (row.owned or 0) < (row.max or 1) then
                    book.unpurchased[#book.unpurchased + 1] = {
                        name = row.name,
                        gid = row.gid,
                        bucket = row.bucket,
                        cost = row.cost,
                        owned = row.owned,
                        max = row.max,
                        canTrain = row.canTrain,
                        buyId = row.buyId,
                    }
                end
            end
        end
        table.sort(book.purchased, function(a, b) return (a.name or '') < (b.name or '') end)
        table.sort(book.unpurchased, function(a, b) return (a.name or '') < (b.name or '') end)
        return book
    end

    local function flushAaBook(book)
        book = S.copyAaBook(book)
        state.aaBook = book
        if hosted and opts.applyCharEntry then
            opts.applyCharEntry({ aa_book = book })
        end
    end

    local function pulseAaCatalog()
        if not state.aaNeedScan then
            if S.aaBookReady(state.charEntry and state.charEntry.aa_book)
                and (not S.aaBookReady(state.aaBook)
                    or (state.charEntry.aa_book.at or 0) ~= (state.aaBook.at or 0)) then
                state.aaBook = S.copyAaBook(state.charEntry.aa_book)
                state.aaCatalog = S.aaCatalogFromBook(state.aaBook)
            end
            return
        end
        local now = os.clock()
        if now < (aaScanHoldUntil or 0) then return end
        if (now - lastAaScanAt) < 0.05 then return end
        lastAaScanAt = now
        -- VF: name/id lookup first so Autobuy is not empty until 16000 ids finish.
        if not aaNamesSeeded then
            aaNamesSeeded = true
            ingestKnownNames()
            state.aaCatalog = S.aaCatalogFromBook(compileAaBook())
        end
        local slice = AA_SCAN_SLICE
        if hosted and not state.open then slice = 80 end
        local start = aaScanIdx
        local stop = start + slice - 1
        if stop > AA_SCAN_MAX then stop = AA_SCAN_MAX end
        -- VF: AltAbility[n] is altability id (GroupID), not Index.
        for i = start, stop do
            local aa
            pcall(function() aa = mq.TLO.AltAbility(i) end)
            ingestAa(aa, 'id:' .. i)
        end
        state.aaScanPct = math.floor((stop / AA_SCAN_MAX) * 100)
        if stop >= AA_SCAN_MAX then
            ingestKnownNames()
            local book = compileAaBook()
            state.aaCatalog = S.aaCatalogFromBook(book)
            flushAaBook(book)
            -- VF: class drop orphans — prune loadout AAs with Rank 0.
            do
                local prevAas = (state.charEntry and state.charEntry.aas) or {}
                local pruned, dropped = S.pruneUnownedAas(prevAas)
                if dropped > 0 and hosted and opts.applyCharEntry then
                    opts.applyCharEntry({ aas = pruned })
                    print(string.format('\ag[VF]\ax AA Sync pruned %d unowned AA(s) from loadout.', dropped))
                end
            end
            -- VF: Autobuy checkboxes that the new book says are already maxed.
            do
                local q = state.aaQueue
                if type(q) == 'table' and type(q.items) == 'table' then
                    local stillOpen = {}
                    for _, rec in ipairs(book.unpurchased) do
                        local n = string.lower(tostring(rec.name or ''))
                        if n ~= '' then stillOpen[n] = true end
                    end
                    local keep, dropped = {}, 0
                    for _, it in ipairs(q.items) do
                        local n = tostring((type(it) == 'table' and it.name) or it or '')
                        if n ~= '' and not stillOpen[string.lower(n)] then
                            dropped = dropped + 1
                        else
                            keep[#keep + 1] = it
                        end
                    end
                    if dropped > 0 then
                        q.items = keep
                        if hosted and opts.applyCharEntry then
                            opts.applyCharEntry({ aa_queue = S.copyAaQueue(q) })
                        end
                        print(string.format('\ag[VF]\ax AA Sync dropped %d maxed AA(s) from Autobuy.', dropped))
                    end
                end
            end
            aaBuild = { General = {}, Archetype = {}, Class = {} }
            aaSeen = {}
            aaScanIdx = 1
            state.aaScanPct = 100
            state.aaNeedScan = false
            lastAAAt = 0
            local zero = 0
            for _, rec in ipairs(book.unpurchased) do
                if (tonumber(rec.owned) or 0) == 0 then zero = zero + 1 end
            end
            print(string.format('\ag[VF]\ax AA book saved: %d purchased, %d unpurchased (%d at 0 ranks). Sync if it looks wrong.',
                #book.purchased, #book.unpurchased, zero))
            pcall(function()
                local a = mq.TLO.AltAbility('Innate Agility')
                local m = mq.TLO.Me.AltAbility('Innate Agility')
                print(string.format(
                    '\ag[VF]\ax AltAbility[Innate Agility] Rank=%s Max=%s CanTrain=%s | Me.Name=%s',
                    tostring(a and a.Rank and a.Rank()),
                    tostring(a and a.MaxRank and a.MaxRank()),
                    tostring(a and a.CanTrain and a.CanTrain()),
                    tostring(m and m.Name and m.Name())))
            end)
        else
            aaScanIdx = stop + 1
        end
    end

    local function flushAaQueue()
        if hosted and opts.applyCharEntry then
            opts.applyCharEntry({ aa_queue = S.copyAaQueue(state.aaQueue) })
            return
        end
        -- VF: satellite — persist queue to char loadout; TA hot-reloads.
        local nm = state.charName
        if not nm or state.dead or state.noCharKey then return end
        local prev = state.allData[nm] or state.charEntry
        if type(prev) ~= 'table' then return end
        local entry = {}
        for k, v in pairs(prev) do entry[k] = v end
        entry.aa_queue = S.copyAaQueue(state.aaQueue)
        local session = { backedUp = state.backedUp, forceWrite = true }
        local ok, err = IO.saveCharacter(state.allData, nm, entry, session)
        state.backedUp = session.backedUp
        if ok then
            state.charEntry = entry
            state.allData[nm] = entry
            pcall(function() mq.cmd('/vf reloadloadout') end)
        elseif err then
            print('\ar[VF Mgr]\ax AA queue flush failed: ' .. tostring(err))
        end
    end
    state.flushAaQueue = flushAaQueue

    local function flushRoutes()
        if hosted and opts.applyCharEntry then
            opts.applyCharEntry({ waypoints = S.copyRoutes(state.routes) })
            if opts.persist then opts.persist() end
            return
        end
        -- VF: satellite — loc kind/order must hit char loadout or TA never sees it.
        local nm = state.charName
        if not nm or state.dead or state.noCharKey then return end
        local prev = state.allData[nm] or state.charEntry
        if type(prev) ~= 'table' then return end
        local entry = {}
        for k, v in pairs(prev) do entry[k] = v end
        entry.waypoints = S.copyRoutes(state.routes)
        local session = { backedUp = state.backedUp, forceWrite = true }
        local ok, err = IO.saveCharacter(state.allData, nm, entry, session)
        state.backedUp = session.backedUp
        if ok then
            state.charEntry = entry
            state.allData[nm] = entry
            pcall(function() mq.cmd('/vf reloadloadout') end)
        elseif err then
            print('\ar[VF Mgr]\ax route flush failed: ' .. tostring(err))
        end
    end
    state.flushRoutes = flushRoutes

    local function flushSafeZones()
        local ok, err = IO.saveSafeZones(state.safeZones)
        if not ok then
            setStatus(false, 'safe zones save failed: ' .. tostring(err))
            print('\ar[VF Mgr]\ax safe zones save failed: ' .. tostring(err))
            return false
        end
        state.safeZones = IO.loadSafeZones()
        if opts.onSafeZones then
            pcall(opts.onSafeZones, state.safeZones)
        end
        setStatus(true, 'safe zones saved')
        return true
    end
    state.flushSafeZones = flushSafeZones

    function state.adoptLibId(zone, pack)
        if type(pack) ~= 'table' then return nil end
        local id = U.trimName(tostring(pack.lib_id or ''))
        if id ~= '' then return id end
        local fromUi = state.routes and state.routes.zones and zone and state.routes.zones[zone]
        id = fromUi and U.trimName(tostring(fromUi.lib_id or '')) or ''
        if id ~= '' then
            pack.lib_id = id
            return id
        end
        local list = S.routesForZone(state.routeLib, zone)
        if #list == 1 then
            pack.lib_id = list[1].id
            return pack.lib_id
        end
        return nil
    end

    function state.pullLiveRoutes()
        if hosted and opts.getCharEntry then
            local e = opts.getCharEntry()
            if e and e.waypoints then
                state.routes = S.copyRoutes(e.waypoints)
                local z = ''
                pcall(function() z = tostring(mq.TLO.Zone.ShortName() or '') end)
                if z ~= '' and z ~= 'NULL' then
                    state.routes.liveZone = z
                    state.routes.zone = z
                end
            end
        end
    end

    function state.syncNamedRoute()
        local zone = state.routes and (state.routes.liveZone or state.routes.zone) or ''
        if zone == '' then
            pcall(function() zone = tostring(mq.TLO.Zone.ShortName() or '') end)
        end
        if zone == '' or zone == 'NULL' then return false end
        local pack = S.ensureRouteZone(state.routes, zone)
        local id = pack and U.trimName(tostring(pack.lib_id or '')) or ''
        if id == '' then return false end
        local item = S.findRoute(state.routeLib, id)
        if not item then return false end
        item.pack = S.copyRoutePack(pack)
        item.pack.lib_id = item.id
        local ok, destOrErr = IO.saveRouteLib(state.routeLib, zone)
        if not ok then
            print('\ar[VF]\ax route update failed: ' .. tostring(destOrErr))
            return false
        end
        print(string.format('\ag[VF]\ax updated %s -- %s (%d locs).', item.name, destOrErr, #(pack.locs or {})))
        return true
    end

    function state.applyRoutePreset(item)
        local zone = state.routes and (state.routes.liveZone or state.routes.zone) or ''
        if zone == '' or type(item) ~= 'table' then return false end
        local pack = S.copyRoutePack(item.pack)
        pack.lib_id = item.id
        if not state.routes then state.routes = S.emptyRoutes() end
        state.routes.zones = state.routes.zones or {}
        state.routes.zones[zone] = pack
        flushRoutes()
        return true
    end

    function state.reportZoneRoute()
        local zone = state.routes and (state.routes.liveZone or state.routes.zone) or ''
        if zone == '' then return end
        local pack = S.ensureRouteZone(state.routes, zone)
        local n = pack and #(pack.locs or {}) or 0
        local list = S.routesForZone(state.routeLib, zone)
        local linked = pack and pack.lib_id and S.findRoute(state.routeLib, pack.lib_id) or nil
        local path = IO.routesPath(zone) or (zone .. '_routes.lua')
        if linked then
            print(string.format('\ag[VF]\ax %s: %d locs (%s) from %s.', zone, n, linked.name, path))
        else
            print(string.format('\ag[VF]\ax %s: %d locs (unsaved). %s has %d saved.', zone, n, path, #list))
        end
    end

    function state.autoLoadZoneRoute()
        local zone = state.routes and (state.routes.liveZone or state.routes.zone) or ''
        if zone == '' then return false end
        local pack = S.ensureRouteZone(state.routes, zone)
        if not pack then return false end
        if pack.lib_id and not S.findRoute(state.routeLib, pack.lib_id) then
            print(string.format('\ay[VF]\ax %s: saved route missing from zone file -- keeping %d locs as unsaved.',
                zone, #(pack.locs or {})))
            pack.lib_id = nil
            flushRoutes()
        end
        if #(pack.locs or {}) > 0 then return false end
        local list = S.routesForZone(state.routeLib, zone)
        if #list == 0 then return false end
        local item = pack.lib_id and S.findRoute(state.routeLib, pack.lib_id) or nil
        if not item then item = list[1] end
        return state.applyRoutePreset(item)
    end

    -- VF: no load/write/deleteRoutePreset here. They lost their callers when the
    -- VF: Combat tab's route editor was deleted -- the waypoints window (/vf wp)
    -- VF: owns saved routes now, with its own implementation.

    function state.requestAaSync()
        state.aaNeedScan = true
        lastAaScanAt = 0
        aaScanHoldUntil = 0
        aaScanIdx, aaSeen = 1, {}
        aaBuild = { General = {}, Archetype = {}, Class = {} }
        aaNamesSeeded = false
        state.aaScanPct = 0
        print('\ag[VF]\ax syncing AA book…')
    end

    local function buildEntry(prev)
        local gems = {}
        for i = 1, S.NUM_GEMS do
            local row = state.spellRows[i]
            if row and not row.empty then
                local built, err = S.buildGemEntry(row)
                if not built then return nil, err or ('bad gem ' .. i) end
                gems[i] = built
                S.rememberSpellGate(state.spellGates, row)
            end
        end
        -- VF: Discs/skills/AAs: overlay this scan; keep prior names so prefs survive flips.
        local discs, dErr = S.mergeNamedAbilities(
            prev and prev.discs, state.skillRows, S.buildAbilityEntry)
        if not discs then return nil, dErr end
        -- VF: drop stale via=skill rows — MQ2Melee owns /doability presses.
        do
            local kept = {}
            for k, v in pairs(discs) do
                if type(v) ~= 'table' or v.via ~= 'skill' then
                    kept[k] = v
                end
            end
            discs = kept
        end
        local aas, aErr = S.mergeNamedAbilities(
            prev and prev.aas, state.aaRows, S.buildAbilityEntry)
        if not aas then return nil, aErr end
        local items, iErr = S.mergeNamedAbilities(
            prev and prev.items, state.itemRows, S.buildAbilityEntry)
        if not items then return nil, iErr end
        local aaDrop, discDrop, itemDrop = 0, 0, 0
        aas, aaDrop = S.pruneUnownedAas(aas)
        discs, discDrop = S.pruneUnownedDiscs(discs)
        items, itemDrop = S.pruneUnownedItems(items)
        if aaDrop > 0 or discDrop > 0 or itemDrop > 0 then
            print(string.format(
                '\ag[VF]\ax Save pruned %d AA(s), %d disc(s), %d item(s) you no longer own.',
                aaDrop, discDrop, itemDrop))
        end
        local entry = {}
        if type(prev) == 'table' then
            for k, v in pairs(prev) do entry[k] = v end
        end
        entry.gems = gems
        entry.spell_gates = S.copySpellGates(state.spellGates)
        entry.discs = discs
        entry.aas = aas
        entry.items = items
        entry.off_limit = nil
        entry.t3_off_limit = nil
        entry.aa_queue = S.copyAaQueue(state.aaQueue)
        if S.aaBookReady(state.aaBook) then
            entry.aa_book = S.copyAaBook(state.aaBook)
        elseif type(prev) == 'table' and S.aaBookReady(prev.aa_book) then
            entry.aa_book = S.copyAaBook(prev.aa_book)
        end
        entry.filters = S.copyFilters(state.filters)
        entry.t3_filters = nil
        entry.melee_abilities = nil
        entry = S.migrateEntry(entry)
        entry.waypoints = S.copyRoutes(state.routes)
        local control = {}
        if type(prev) == 'table' and type(prev.control) == 'table' then
            for k, v in pairs(prev.control) do control[k] = v end
        end
        entry.control = S.writePullToControl(control, state.pull)
        entry.control = S.writeAssistToControl(entry.control, state.assist)
        entry.control = S.writeGroupTrustToControl(entry.control, state.groupTrust)
        entry.control = S.writePrefsToControl(entry.control, state.prefs)
        return entry
    end

    local function checkMobs(rows)
        for _, row in ipairs(rows or {}) do
            if row and not row.empty then
                local text, ok = S.composeMobs(row.mobsOp, row.mobsN)
                if text == nil or ok == false then
                    setStatus(false, 'bad mobs on ' .. tostring(row.name) .. ' -- empty or a whole number')
                    return false
                end
                row.mobs = text
                row.mobsOk = true
            end
        end
        return true
    end

    local function doSave()
        refreshEntry()
        if state.dead then
            setStatus(false, 'refuse write: dead or corpse')
            return
        end
        local nm = state.charName
        if not nm then
            setStatus(false, 'no character name')
            return
        end
        if type(state.allData[nm]) ~= 'table' then
            setStatus(false, 'character key not already in file: ' .. nm)
            return
        end
        if not checkMobs(state.spellRows) then return end
        if not checkMobs(state.skillRows) then return end
        if not checkMobs(state.aaRows) then return end
        if not checkMobs(state.itemRows) then return end

        local prev = state.allData[state.charName] or state.charEntry
        local entry, err = buildEntry(prev)
        if not entry then
            setStatus(false, tostring(err))
            return
        end

        local session = { backedUp = state.backedUp, forceWrite = true }
        local ok, ioErr = IO.saveCharacter(state.allData, state.charName, entry, session)
        state.backedUp = session.backedUp
        if ok then
            state.charEntry = entry
            state.allData[state.charName] = entry
            -- VF: re-paint Disc rows from what we wrote so Mobs/HP match disk after Save.
            seedSkillRowsFromSheet()
            seedAaRowsFromSheet()
            seedItemRowsFromSheet()
            lastSkillAt = 0
            lastSkillScanAt = 0
            lastAAAt = 0
            lastItemAt = 0
            if state.itemEdit and state.itemEdit.name then
                state.itemEdit = state.itemByName[state.itemEdit.name] or state.itemEdit
            end
            setStatus(true, nil)
            do
                local recs = {}
                for name, it in pairs(entry.items or {}) do
                    recs[name] = toonini.recFromEntry(name, it)
                end
                toonini.setItems(recs)
            end
            -- VF: nudge TA to re-read disk without restarting combat.
            pcall(function() mq.cmd('/vf reloadloadout') end)
        else
            setStatus(false, tostring(ioErr))
        end
    end

    local app = {}
    app.adoptLibId = state.adoptLibId
    app.pullLiveRoutes = state.pullLiveRoutes
    app.syncNamedRoute = state.syncNamedRoute

    -- VF: TA drops maxed AAs from the queue (ta/aaspend.lua); mirror it so an open tab stays honest.
    function app.reloadAaQueue(q)
        state.aaQueue = S.copyAaQueue(q)
    end

    function app.isOpen()
        return state.open
    end

    function app.toggle()
        state.open = not state.open
        if state.open then
            hydratedName = nil
            lastFileAt = 0
            pcall(function()
                local s = mq.TLO.Lua.Script('t3')
                if s() and s.Status() == 'RUNNING' then mq.cmd('/lua stop t3') end
            end)
        end
        return state.open
    end

    function app.setOpen(v)
        state.open = not not v
        if state.open then
            hydratedName = nil
            lastFileAt = 0
        end
    end

    function app.tick()
        if hosted and not state.open then
            refreshEntry()
            hydrateIfNeeded()
            pulseAaCatalog()
            return
        end
        refreshEntry()
        pulseGems()
        hydrateIfNeeded()
        pulseSkills()
        pulseAA()
        pulseItems()
        pulseAaCatalog()
        local short = ''
        pcall(function()
            short = tostring(mq.TLO.Zone.ShortName() or '')
        end)
        if short == 'NULL' then short = '' end
        if short ~= '' then
            if not state.filters then state.filters = S.emptyFilters() end
            S.ensureZone(state.filters, short)
            if state.filters.liveZone ~= short then
                state.filters.liveZone = short
                state.filters.zone = short
            end
            if not state.routes then state.routes = S.emptyRoutes() end
            S.ensureRouteZone(state.routes, short)
            if state.routes.liveZone ~= short then
                state.routes.liveZone = short
                state.routes.zone = short
            end
            if state.routeLibZone ~= short then
                state.routeLibZone = short
                state.routeLib = IO.loadRouteLib(short)
                state.routeLibApplied = false
            end
            if not state.routeLibApplied then
                state.routeLibApplied = true
                state.autoLoadZoneRoute()
                state.reportZoneRoute()
            end
        end
    end

    function app.draw()
        UI.draw(state, {
            save = doSave,
            meleeSet = opts.meleeSet,
            flushSafeZones = flushSafeZones,
        })
    end

    function app.save()
        doSave()
    end

    function app.command(line)
        line = U.trimName(line):lower()
        if line == '' or line == 'help' then
            print('\ay[VF Mgr]\ax Save writes {server}_{char}.lua and vft/config/{server}_{char}_loadout.ini.')
            print('\ay[VF Mgr]\ax Gear or /vfmgr toggles /lua run vft/mgr')
            return
        end
        if line == 'save' then
            doSave()
            return
        end
        print('\ay[VF Mgr]\ax unknown command')
    end

    return app
end

return { create = create }
