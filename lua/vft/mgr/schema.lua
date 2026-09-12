-- VF: Settings row language and TA write mapping.

local mq = require('mq')
local U = require('vft.mgr.util')

local NUM_GEMS = 12

-- VF: Role tags for rotate buckets. docs/COMBAT_TICK_IDEAL.md
-- VF: Burn is burn_only checkbox, not a Type. CC = mez/add control, not kill target.
local TYPES = {
    'Melee', 'Nuke', 'DoT', 'Debuff', 'CC',
    'Heal', 'Tap', 'HoT', 'Cure', 'Panic',
    'Buff', 'Summon', 'PetHeal', 'PetBuff',
}
local TYPE_SET = {}
for _, t in ipairs(TYPES) do TYPE_SET[t] = true end

-- VF: old Type names â†’ new. Loadouts keep working after the dropdown shrink.
local TYPE_ALIASES = {
    Pet = 'Summon',
    Util = 'Buff',
    Port = 'Buff',
    Threat = 'Melee',
    AoE = 'Nuke',
    Rain = 'Nuke',
    Mez = 'CC',
}
for old, new in pairs(TYPE_ALIASES) do
    TYPE_SET[old] = true -- accept on read; normalize via alias
end

-- VF: Must match t2/data.lua WHENS.
local WHENS = {
    'HP <=', 'target HP <=', 'my HP <=', 'my Mana <=', 'missing buff', 'missing pet',
    'has Poison/Disease', 'ally is Dead', 'add is loose', 'twist while fighting',
    'in combat', 'always',
}

local WHEN_SET = {}
for _, w in ipairs(WHENS) do WHEN_SET[w] = true end

-- VF: where the Heal / Cure / HoT / Tap bands sit relative to the offense rotation.
-- VF: 'Support first' is the long-standing behavior -- those bands already preempt
-- VF: offense every tick. 'DPS first' demotes only the ALLY-targeted heal rows to
-- VF: after the offense dump; self-targeted heals still preempt, because us dying
-- VF: outranks the rotation regardless of role.
local HEAL_PRIORITIES = { 'Support first', 'DPS first' }
local HEAL_PRIORITY_SET = {}
for _, h in ipairs(HEAL_PRIORITIES) do HEAL_PRIORITY_SET[h] = true end

-- VF: Extra gates.
local COMBATS = { 'Always', 'In Combat', 'Out of Combat' }
local COMBAT_SET = {}
for _, c in ipairs(COMBATS) do COMBAT_SET[c] = true end

local function defaultCombat(typ)
    if typ == 'Melee' or typ == 'DoT' or typ == 'Nuke' or typ == 'Debuff' or typ == 'CC'
        or typ == 'PetHeal' or typ == 'Tap' then
        return 'In Combat'
    end
    if typ == 'Buff' or typ == 'PetBuff' or typ == 'Summon' then
        return 'Out of Combat'
    end
    -- VF: Heal / HoT / Cure / Panic: Always (HoT = HP% + missing on buff/short).
    return 'Always'
end

local function combatFromEntry(entry, typ)
    local c = entry and (entry.combat or entry.t3_combat)
    if c == 'in combat' or c == 'combat' then c = 'In Combat' end
    if c == 'out of combat' or c == 'ooc' then c = 'Out of Combat' end
    if c == 'always' then c = 'Always' end
    if COMBAT_SET[c] then return c end
    return defaultCombat(typ)
end

-- VF: Not CombatAbility discs â€” skip if they appear on the CA list (MQ2Melee / non-disc).
local SPECIAL_SKILL = { Mend = true, ['Feign Death'] = true }

local function isWhenOk(when)
    return when and WHEN_SET[when] == true
end

local function nextType(cur)
    local i = U.idxOf(TYPES, cur)
    return TYPES[(i % #TYPES) + 1]
end

local function defaultBelow(typ)
    if typ == 'Panic' then return 20 end
    if typ == 'Heal' or typ == 'HoT' or typ == 'PetHeal' or typ == 'Tap' then return 75 end
    if typ == 'Cure' then return 100 end
    if typ == 'Melee' or typ == 'DoT' or typ == 'Nuke' or typ == 'Debuff' or typ == 'CC' then
        return 98
    end
    return 100
end

local function normalizeType(typ)
    if not typ then return nil end
    if TYPE_ALIASES[typ] then return TYPE_ALIASES[typ] end
    if typ == 'Mez' then return 'CC' end
    -- VF: only canonical TYPES for new writes (aliases accepted on read above).
    for _, t in ipairs(TYPES) do
        if t == typ then return typ end
    end
    return nil
end

-- VF: Above/Below HP band â€” self, target, or locked (Buff/PetBuff/Summon/Cure).
local function hpBandKind(typ)
    typ = normalizeType(typ) or typ
    -- VF: Tap = my HP band, cast on mob (mapType sets E: Current Target).
    if typ == 'Heal' or typ == 'Panic' or typ == 'HoT' or typ == 'Tap' then return 'self' end
    if typ == 'Nuke' or typ == 'DoT' or typ == 'Debuff' or typ == 'Melee'
        or typ == 'CC' or typ == 'PetHeal' then
        return 'target'
    end
    return 'none'
end

local function hpBandEditable(typ)
    return hpBandKind(typ) ~= 'none'
end

-- VF: type -> when/target. CC = Unmezzed Add (not the kill target).
-- VF: HoT = my HP% like Heal, plus missing on buff/short (engine dual-gate).
-- VF: Tap = my HP% gate, Current Target cast (lifetap).
local function mapType(typ)
    typ = normalizeType(typ) or typ
    if typ == 'Buff' then return 'missing buff', 'F: Myself' end
    if typ == 'PetBuff' then return 'missing buff', 'F: Pet' end
    if typ == 'Heal' or typ == 'Panic' or typ == 'HoT' then return 'my HP <=', 'F: Myself' end
    if typ == 'Tap' then return 'my HP <=', 'E: Current Target' end
    if typ == 'PetHeal' then return 'HP <=', 'F: Pet' end
    if typ == 'Cure' then return 'has Poison/Disease', 'F: Myself' end
    if typ == 'Summon' then return 'missing pet', 'F: Myself' end
    if typ == 'CC' then return 'target HP <=', 'E: Unmezzed Add' end
    if typ == 'Melee' then return 'target HP <=', 'E: Current Target' end
    if typ == 'DoT' or typ == 'Nuke' or typ == 'Debuff' then
        return 'target HP <=', 'E: Current Target'
    end
    return 'always', 'F: Myself'
end

local function typeFromStored(entry)
    if not entry then return nil end
    local stored = entry.cast_type or entry.t3_type
    local n = normalizeType(stored)
    if n then return n end
    local when = entry.when
    local tgt = tostring(entry.target or '')
    if tgt:find('Unmezzed', 1, true) then return 'CC' end
    if when == 'has Poison/Disease' then return 'Cure' end
    if when == 'missing buff' then
        if tgt:find('Pet', 1, true) then return 'PetBuff' end
        -- VF: name hints when cast_type was stripped â€” Ethereal Cleansing is HoT not Buff.
        local nm = tostring(entry.spell or entry.name or ''):lower()
        if nm:find('cleansing', 1, true) or nm:find('regenerat', 1, true)
            or nm:find('heal over', 1, true) then
            return 'HoT'
        end
        return 'Buff'
    end
    if when == 'my HP <=' then return 'Heal' end
    if when == 'HP <=' and tgt:find('Pet', 1, true) then return 'PetHeal' end
    if when == 'missing pet' then return 'Summon' end
    if when == 'always' then return 'Buff' end
    return nil
end

local function inferTypeFromTLO(mq, name)
    if not name or name == '' then return 'Buff' end
    local cat, sub, bene, tgtType = '', '', true, ''
    pcall(function()
        local sp = mq.TLO.Spell(name)
        if not sp or not sp() then return end
        local c = sp.Category
        if c then cat = tostring(c() or c.Name() or c):lower() end
        local sc = sp.Subcategory
        if sc then sub = tostring(sc() or sc.Name() or sc):lower() end
        local b = sp.Beneficial
        if type(b) == 'function' or type(b) == 'userdata' then
            bene = b() or false
        else
            bene = b or false
        end
        local tt = sp.TargetType
        if tt then tgtType = tostring(tt() or ''):lower() end
    end)
    local nm = name:lower()
    if cat:find('mez') or sub:find('mez') or cat:find('mesmer') or sub:find('mesmer')
        or nm:find('mesmerize') or nm:find('mez ') then
        return 'CC'
    end
    if cat:find('cure') or sub:find('cure') or nm:find('cure')
        or nm:find('counteract') or nm:find('abolish') then
        return 'Cure'
    end
    -- VF: Familiar is a self buff (: Permanent on bar), not a Me.Pet summon.
    if nm:find('familiar', 1, true) then
        return 'Buff'
    end
    if cat:find('pet') or sub:find('pet') then
        if bene and (cat:find('heal') or sub:find('heal') or nm:find('heal')) then
            return 'PetHeal'
        end
        if bene and (tgtType:find('pet') or cat:find('buff') or sub:find('buff')) then
            return 'PetBuff'
        end
        return 'Summon'
    end
    -- VF: HoT = duration heal; Save writes my HP <= (engine also requires missing on bar).
    if bene and (cat:find('heal over') or sub:find('heal over') or cat:find('hot')
        or sub:find('hot') or nm:find('heal over') or nm:find(' regeneration')
        or nm:find('regenerat') or nm:find('cleansing')) then
        return 'HoT'
    end
    if cat:find('heal') or sub:find('heal') or cat:find('restore') or sub:find('restore') then
        local dur = 0
        pcall(function()
            local sp = mq.TLO.Spell(name)
            if sp and sp() then dur = tonumber(sp.Duration()) or 0 end
        end)
        if dur > 0 then return 'HoT' end
        return 'Heal'
    end
    if cat:find('lifetap') or sub:find('lifetap') or nm:find('lifetap')
        or nm:find('lifedraw') or nm:find('lifespike') or nm:find('siphon life')
        or nm:find('lifeburn') or nm:find('vampyric') then
        return 'Tap'
    end
    if cat:find('dot') or cat:find('damage over time') or sub:find('dot')
        or sub:find('damage over time') then
        return 'DoT'
    end
    if cat:find('taunt') or sub:find('taunt') or cat:find('hate') or sub:find('hate')
        or nm:find('taunt') then
        return 'Melee'
    end
    if not bene then
        if cat:find('debuff') or sub:find('debuff') or cat:find('slow') or sub:find('slow')
            or cat:find('snare') or sub:find('snare') or nm:find('snare') or nm:find('tash') then
            return 'Debuff'
        end
        return 'Nuke'
    end
    return 'Buff'
end

local MOBS_OPS = { '<=', '>=', '<', '>' }

local function parseMobs(text)
    text = U.trimName(tostring(text or ''))
    if text == '' then return { ok = true, kind = nil, n = nil, op = nil, display = '' } end
    -- VF: <=N / >=N inclusive; <N / >N strict (max=N-1 / min=N+1).
    local bare = text:match('^(%d+)$')
    if bare then
        local n = tonumber(bare)
        return { ok = true, kind = 'ge', n = n, op = '>=', display = '>=' .. n }
    end
    -- VF: '[<>]=?' -- Lua patterns have NO '|' alternation. This was
    -- VF: '^(<=|>=|[<>])%s*(%d+)$', which matches nothing at all, so every operator
    -- VF: form failed to parse: composeMobs wrote '>=3' and parseMobs could not read it
    -- VF: back, blanking the count and dropping the gate to min_xtar=1 on every reload.
    -- VF: tools/test-healpri.lua pins the real values so this cannot regress silently.
    local op, num = text:match('^([<>]=?)%s*(%d+)$')
    if not op then
        return { ok = false, kind = nil, n = nil, op = nil, display = text }
    end
    local n = tonumber(num)
    if op == '<=' then return { ok = true, kind = 'le', n = n, op = '<=', display = '<=' .. n } end
    if op == '>=' then return { ok = true, kind = 'ge', n = n, op = '>=', display = '>=' .. n } end
    if op == '<' then return { ok = true, kind = 'lt', n = n, op = '<', display = '<' .. n } end
    return { ok = true, kind = 'gt', n = n, op = '>', display = '>' .. n }
end

-- VF: Empty number = no pack gate. Invalid returns nil, false.
local function composeMobs(op, n)
    local num = U.trimName(tostring(n or ''))
    if num == '' then return '', true end
    local v = tonumber(num)
    if not v or v ~= math.floor(v) or v < 0 or not num:match('^%d+$') then
        return nil, false
    end
    if op ~= '<=' and op ~= '>=' and op ~= '<' and op ~= '>' then op = '<=' end
    return op .. tostring(v), true
end

local function mobsPartsFromText(text)
    local p = parseMobs(text)
    if not p.ok or not p.op then
        -- VF: Disc sheet is â‰¥N only; default op must match or the UI scrubber clears N.
        return '>=', '', p.ok
    end
    return p.op, tostring(p.n), true
end

-- VF: >N â†’ min=N+1; <N â†’ max=N-1; >=N â†’ min=N; <=N â†’ max=N. Empty â†’ default min 1, no max.
local function mobsToFields(text, existing)
    local parsed = parseMobs(text)
    local minXt = existing and tonumber(existing.min_xtar) or 1
    local maxXt = existing and existing.max_xtargets or nil
    if not parsed.ok then
        return minXt, maxXt, false
    end
    if parsed.kind == 'gt' then
        return parsed.n + 1, nil, true
    end
    if parsed.kind == 'ge' then
        local floor = parsed.n
        if floor < 0 then floor = 0 end
        return floor, nil, true
    end
    if parsed.kind == 'lt' then
        local ceiling = parsed.n - 1
        if ceiling < 0 then ceiling = 0 end
        return 1, ceiling, true
    end
    if parsed.kind == 'le' then
        local ceiling = parsed.n
        if ceiling < 0 then ceiling = 0 end
        return 1, ceiling, true
    end
    return 1, nil, true
end

local function fieldsToMobs(entry)
    if not entry then return '' end
    -- VF: exact UI string from last Save â€” do not hide >=1 / rebuild from defaults.
    local expr = U.trimName(tostring(entry.mobs_expr or ''))
    if expr ~= '' then return expr end
    local maxXt = tonumber(entry.max_xtargets)
    if maxXt ~= nil then
        return '<=' .. maxXt
    end
    local minXt = tonumber(entry.min_xtar)
    -- VF: min_xtar=1 with no expr is the engine default â€” keep UI blank.
    if minXt ~= nil and (minXt == 0 or minXt > 1) then
        return '>=' .. minXt
    end
    return ''
end

-- VF: no mobsPartsFromEntry. Exported, never called; callers compose
-- VF: mobsPartsFromText(fieldsToMobs(entry)) themselves.

local function indexByName(tbl)
    local out = {}
    if type(tbl) ~= 'table' then return out end
    for _, row in pairs(tbl) do
        if type(row) == 'table' and row.spell and row.spell ~= '' then
            local key = U.normalizeSpellName(row.spell)
            if key ~= '' then out[key] = row end
        end
    end
    return out
end

local function findNamed(tbl, name)
    local key = U.normalizeSpellName(name)
    if key == '' then return nil end
    if type(tbl) ~= 'table' then return nil end
    for _, row in pairs(tbl) do
        if type(row) == 'table' then
            local src = row.spell or row.name
            if src and U.normalizeSpellName(src) == key then
                return row
            end
        end
    end
    return nil
end

local function gemEnabled(entry)
    if not entry then return true end
    local pct = tonumber(entry.pct)
    if pct == nil then return true end
    return pct > 0
end

local function abilityEnabled(entry)
    if not entry then return false end
    if entry.enabled ~= true then return false end
    local pct = tonumber(entry.pct)
    -- VF: nil pct = ungated AA filler bucket (Above/Below blank).
    if pct == nil then return true end
    return pct > 0
end

local function isAaUiRow(row)
    return row and row.gem == nil and row.via ~= 'disc'
end

local function belowFromEntry(entry, typ, kind)
    -- VF: kind 'aa'|'disc'|'item'|nil â€” discs/AAs/items default blank HP%; gems use type default.
    if kind == 'aa' or kind == 'disc' or kind == 'item' then
        if not entry then return '' end
        local pct = tonumber(entry.pct)
        local stash = tonumber(entry.ui_pct or entry.t3_pct)
        if pct == 0 then
            if stash and stash < 98 then return tostring(stash) end
            return ''
        end
        if pct and pct >= 98 then return '' end
        if pct then return tostring(pct) end
        if stash and stash < 98 then return tostring(stash) end
        return ''
    end
    if not entry then return tostring(defaultBelow(typ)) end
    local pct = tonumber(entry.pct)
    local stash = tonumber(entry.ui_pct or entry.t3_pct)
    if pct == 0 then
        if stash then return tostring(stash) end
        return tostring(defaultBelow(typ))
    end
    if pct then return tostring(pct) end
    if stash then return tostring(stash) end
    return tostring(defaultBelow(typ))
end

local function aboveFromEntry(entry)
    if not entry then return '' end
    local a = entry.above
    if a == nil then a = entry.t3_above end
    if a == nil or a == '' then return '' end
    return tostring(a)
end

local function rowFromGem(mq, slot, barName, existing)
    local name = U.trimName(barName)
    if name == '' or name == 'NULL' then
        return {
            gem = slot, name = '', type = 'Buff', combat = 'Always',
            burn = false, above = '', below = '',
            mobs = '', mobsOp = '<=', mobsN = '', mobsOk = true,
            pri = 50, enabled = false, empty = true,
        }
    end
    local typ = typeFromStored(existing) or inferTypeFromTLO(mq, name)
    local pri = (existing and tonumber(existing.priority)) or 50
    local mobs = fieldsToMobs(existing)
    local mop, mn = mobsPartsFromText(mobs)
    return {
        gem = slot,
        name = name,
        type = typ,
        combat = combatFromEntry(existing, typ),
        burn = existing and existing.burn_only == true,
        above = aboveFromEntry(existing),
        below = belowFromEntry(existing, typ),
        mobs = mobs,
        mobsOp = mop,
        mobsN = mn,
        mobsOk = true,
        pri = pri,
        enabled = gemEnabled(existing),
        empty = false,
        cls = existing and existing.cls or nil,
        source = existing,
    }
end

local function rowFromAbility(name, existing, via, typHint)
    local typ = typeFromStored(existing) or typHint or 'Nuke'
    local pri = (existing and tonumber(existing.priority)) or 50
    local mobs = fieldsToMobs(existing)
    local mop, mn = mobsPartsFromText(mobs)
    return {
        name = name,
        type = typ,
        combat = combatFromEntry(existing, typ),
        burn = existing and existing.burn_only == true,
        boost = existing and existing.boost_only == true,
        above = aboveFromEntry(existing),
        below = belowFromEntry(existing, typ, via == 'disc' and 'disc' or 'aa'),
        mobs = mobs,
        mobsOp = mop,
        mobsN = mn,
        mobsOk = true,
        pri = pri,
        enabled = abilityEnabled(existing),
        via = via,
        cls = existing and existing.cls or nil,
        source = existing,
        cooldown = '',
        cooldownSec = 0,
        duration = '',
        durationSec = 0,
        level = 0,
        timerId = 0,
        itemId = (existing and tonumber(existing.item_id)) or 0,
        icon = (existing and tonumber(existing.icon)) or 0,
        levelMin = (existing and existing.min_level ~= nil and existing.min_level ~= '')
            and tostring(existing.min_level) or '',
        levelMax = (existing and existing.max_level ~= nil and existing.max_level ~= '')
            and tostring(existing.max_level) or '',
        cmdBefore = (existing and existing.cmd_before) and tostring(existing.cmd_before) or '',
        cmdAfter = (existing and existing.cmd_after) and tostring(existing.cmd_after) or '',
        keepBuff = (existing and existing.keep_buff) and tostring(existing.keep_buff) or '',
        extraBuffs = {},
    }
end

local function applyTypeGates(built, typ)
    typ = normalizeType(typ) or typ
    local when, target = mapType(typ)
    if not isWhenOk(when) then
        when, target = 'always', 'F: Myself'
    end
    built.when = when
    built.target = target
    built.cast_type = typ
    built.t3_type = nil
end

local function thresholdFor(row)
    local n = tonumber(row.below)
    if n then
        if n < 0 then n = 0 end
        if n > 100 then n = 100 end
        return n
    end
    -- VF: blank Below on AAs/discs = ungated (pct nil). Gems keep type default.
    if isAaUiRow(row) or row.via == 'disc' then return nil end
    return defaultBelow(row.type)
end

local function applyAbove(built, row)
    -- VF: Buff / PetBuff / Summon / Cure â€” no HP band.
    if not hpBandEditable(row and row.type) then
        built.above = nil
        built.t3_above = nil
        return
    end
    local a = U.trimName(row.above)
    if a == '' then
        built.above = nil
        built.t3_above = nil
        return
    end
    local n = tonumber(a)
    if n then
        if n < 0 then n = 0 end
        if n > 100 then n = 100 end
        built.above = n
        built.t3_above = nil
    end
end

local function applyMobs(built, row, existing)
    local text, okCompose = composeMobs(row.mobsOp, row.mobsN)
    -- VF: Combo+SameLine can leave mobsN blank while row.mobs still has >=N.
    if (text == nil or text == '') and row.mobs and tostring(row.mobs) ~= '' then
        local parsed = parseMobs(row.mobs)
        if parsed.ok and parsed.op then
            text = parsed.display
            okCompose = true
            row.mobsOp = parsed.op
            row.mobsN = tostring(parsed.n)
        end
    end
    if text == nil then
        row.mobsOk = false
        row.mobs = tostring(row.mobs or '')
        local minXt = existing and tonumber(existing.min_xtar) or 1
        local maxXt = existing and existing.max_xtargets or nil
        built.min_xtar = minXt
        built.max_xtargets = maxXt
        built.mobs_expr = existing and existing.mobs_expr or nil
        return
    end
    row.mobs = text
    local minXt, maxXt, ok = mobsToFields(text, existing)
    row.mobsOk = ok and okCompose ~= false
    built.min_xtar = minXt
    if maxXt ~= nil then
        built.max_xtargets = maxXt
    else
        built.max_xtargets = nil
    end
    -- VF: empty = default min 1; keep expr so >=N survives Saveâ†’reload.
    built.mobs_expr = (text ~= '') and text or nil
end

local function copyPreserved(existing)
    local out = {}
    if type(existing) ~= 'table' then return out end
    for k, v in pairs(existing) do
        out[k] = v
    end
    return out
end

-- VF: by-name gem prefs survive unmem/remem. Slot gems still drive the engine.
local function copySpellGates(tbl)
    local out = {}
    if type(tbl) ~= 'table' then return out end
    for k, v in pairs(tbl) do
        if type(v) == 'table' then
            local key = U.normalizeSpellName(v.spell or k)
            if key ~= '' then
                local rec = copyPreserved(v)
                rec.spell = v.spell or tostring(k)
                out[key] = rec
            end
        end
    end
    return out
end

local function seedSpellGates(entry)
    local out = copySpellGates(entry and entry.spell_gates)
    for k, v in pairs(indexByName(entry and entry.gems)) do
        if not out[k] and type(v) == 'table' then
            out[k] = copyPreserved(v)
        end
    end
    return out
end

local function lookupSpellGate(gates, gems, name)
    local key = U.normalizeSpellName(name)
    if key == '' then return nil end
    if type(gates) == 'table' and type(gates[key]) == 'table' then
        return gates[key]
    end
    return indexByName(gems)[key]
end

-- VF: Merge prior named discs/AAs so Save does not drop prefs when a scan misses a row.
local function mergeNamedAbilities(prevTbl, rows, buildRow)
    local out = {}
    if type(prevTbl) == 'table' then
        for k, v in pairs(prevTbl) do
            if type(k) == 'string' and type(v) == 'table' then
                out[k] = copyPreserved(v)
            end
        end
    end
    for _, row in ipairs(rows or {}) do
        local built, err = buildRow(row)
        if built then
            out[row.name] = built
        elseif err then
            return nil, err
        end
    end
    return out
end

-- VF: Drop class-flip orphans â€” Rank 0 AA / missing CombatAbility.
local function aaStillOwned(name)
    if not name or name == '' then return false end
    local owned = 0
    pcall(function()
        local aa = mq.TLO.Me.AltAbility(name)
        if aa and aa() and aa.Rank then owned = tonumber(aa.Rank()) or 0 end
    end)
    return owned > 0
end

local function discStillOwned(name, entry)
    if not name or name == '' then return false end
    if entry and entry.via == 'skill' then return false end
    local ok = false
    pcall(function()
        if mq.TLO.Me.CombatAbility(name)() then ok = true end
    end)
    return ok
end

local function pruneUnownedAas(tbl)
    if type(tbl) ~= 'table' then return tbl, 0 end
    local out, n = {}, 0
    for name, a in pairs(tbl) do
        if aaStillOwned(name) then
            out[name] = a
        else
            n = n + 1
        end
    end
    return out, n
end

local function pruneUnownedDiscs(tbl)
    if type(tbl) ~= 'table' then return tbl, 0 end
    local out, n = {}, 0
    for name, d in pairs(tbl) do
        if discStillOwned(name, d) then
            out[name] = d
        else
            n = n + 1
        end
    end
    return out, n
end

-- VF: extra land-on-you spells (mount blessing / Spell.Trigger / Item.Blessing).
local function itemExtraBuffs(mq, itemName, clickySpell)
    local out, seen = {}, {}
    local clickKey = U.normalizeSpellName(clickySpell or '')
    local function add(n)
        n = U.trimName(n)
        if n == '' or n == 'NULL' then return end
        if n:lower() == 'unknown spell' then return end
        local key = U.normalizeSpellName(n)
        if key == '' or seen[key] then return end
        if clickKey ~= '' and key == clickKey then return end
        seen[key] = true
        out[#out + 1] = n
    end
    local function walkSpell(sp)
        if not sp then return end
        local ok = false
        pcall(function() ok = not not sp() end)
        if not ok then return end
        local n = 8
        pcall(function() n = tonumber(sp.NumEffects()) or 8 end)
        if n < 1 then n = 8 end
        if n > 20 then n = 20 end
        for i = 1, n do
            pcall(function()
                local t = sp.Trigger(i)
                if t and t() then add(tostring(t.Name() or t() or '')) end
            end)
        end
    end
    pcall(function()
        local it = mq.TLO.FindItem('=' .. tostring(itemName or ''))
        if not (it and it()) then return end
        if it.Blessing then add(tostring(it.Blessing() or '')) end
        if it.Clicky and it.Clicky() and it.Clicky.Spell then walkSpell(it.Clicky.Spell) end
        if it.Spell then walkSpell(it.Spell) end
    end)
    if clickySpell and clickySpell ~= '' then
        pcall(function() walkSpell(mq.TLO.Spell(clickySpell)) end)
    end
    return out
end

local function itemStillOwned(name)
    if not name or name == '' then return false end
    local ok = false
    pcall(function()
        local it = mq.TLO.FindItem('=' .. name)
        ok = not not (it and it())
    end)
    return ok
end

local function pruneUnownedItems(tbl)
    if type(tbl) ~= 'table' then return tbl, 0 end
    local out, n = {}, 0
    for name, it in pairs(tbl) do
        if itemStillOwned(name) then
            out[name] = it
        else
            n = n + 1
        end
    end
    return out, n
end

-- VF: Gems: mute is pct=0 only.
local function buildGemEntry(row)
    if row.empty or not row.name or row.name == '' then return nil end
    local existing = row.source
    local built = copyPreserved(existing)
    built.spell = row.name
    applyTypeGates(built, row.type)
    built.combat = COMBAT_SET[row.combat] and row.combat or defaultCombat(row.type)
    built.interrupt = nil
    built.burn_only = row.burn == true
    local thresh = thresholdFor(row)
    built.ui_pct = thresh
    built.t3_combat = nil
    built.t3_interrupt = nil
    built.t3_pct = nil
    built.priority = nil
    if row.enabled then
        built.pct = thresh
    else
        built.pct = 0
    end
    applyAbove(built, row)
    applyMobs(built, row, existing)
    -- VF: Never invent cls.
    if existing and existing.cls then
        built.cls = existing.cls
    else
        built.cls = nil
    end
    if not isWhenOk(built.when) then
        return nil, 'rejected when: ' .. tostring(built.when)
    end
    return built
end

-- VF: discs fire when enabled+pct>0; AAs also when enabled+pct nil (filler bucket).
local function buildAbilityEntry(row)
    if not row.name or row.name == '' then return nil end
    local existing = row.source
    local built = copyPreserved(existing)
    applyTypeGates(built, row.type)
    built.combat = COMBAT_SET[row.combat] and row.combat or defaultCombat(row.type)
    built.interrupt = nil
    built.burn_only = row.burn == true
    -- VF: Boost stub on disc sheet â€” stored only; engine ignore until wired.
    built.boost_only = row.boost == true
    local thresh = thresholdFor(row)
    built.ui_pct = thresh
    built.t3_combat = nil
    built.t3_interrupt = nil
    built.t3_pct = nil
    built.priority = nil
    if row.enabled then
        built.enabled = true
        built.pct = thresh
    else
        built.enabled = false
        built.pct = 0
    end
    if row.via then built.via = row.via end
    -- VF: clicky item â€” cast by item name; buff/heal gates use Clicky.Spell name.
    if row.via == 'item' then
        local sp = U.trimName(row.spell or (existing and existing.spell) or '')
        if sp ~= '' then built.spell = sp end
        if row.effectType and row.effectType ~= '' then
            built.effect_type = row.effectType
        elseif existing and existing.effect_type then
            built.effect_type = existing.effect_type
        end
        local iid = tonumber(row.itemId)
        if iid and iid > 0 then
            built.item_id = iid
        elseif existing and tonumber(existing.item_id) then
            built.item_id = tonumber(existing.item_id)
        end
        local icon = tonumber(row.icon)
        if icon and icon > 0 then built.icon = icon end
        local lmin = tonumber(row.levelMin)
        built.min_level = lmin
        local lmax = tonumber(row.levelMax)
        built.max_level = lmax
        local before = U.trimName(row.cmdBefore)
        built.cmd_before = (before ~= '') and before or nil
        local after = U.trimName(row.cmdAfter)
        built.cmd_after = (after ~= '') and after or nil
        local keep = U.trimName(row.keepBuff)
        built.keep_buff = (keep ~= '') and keep or nil
    end
    applyAbove(built, row)
    applyMobs(built, row, existing)
    if existing and existing.cls then
        built.cls = existing.cls
    else
        built.cls = nil
    end
    if not isWhenOk(built.when) then
        return nil, 'rejected when: ' .. tostring(built.when)
    end
    return built
end

-- VF: Snapshot UI row gates into the by-name library (unmem before Save).
local function rememberSpellGate(gates, row)
    if type(gates) ~= 'table' or not row or row.empty then return end
    local built = buildGemEntry(row)
    if not built then return end
    local key = U.normalizeSpellName(row.name)
    if key ~= '' then gates[key] = built end
end

local function isCeilingMobs(text)
    local p = parseMobs(text)
    return p.ok and (p.kind == 'lt' or p.kind == 'le')
end

local function isCeilingMobsRow(row)
    if not row then return false end
    local op = row.mobsOp
    if (not op or op == '') and row.mobs then
        local p = parseMobs(row.mobs)
        op = p.op
    end
    return op == '<=' or op == '<'
end

-- VF: per-zone hunt filters. Cons keys match pull_con_filter.
local FACTION_ROWS = {
    { key = 'Scowling',      label = 'KoS' },
    { key = 'Threateningly', label = 'Threat' },
    { key = 'Dubious',       label = 'Dubious' },
    { key = 'Apprehensive',  label = 'Apprehensive' },
    { key = 'Indifferent',   label = 'Indifferent' },
    { key = 'Amiably',       label = 'Amiable' },
    { key = 'Kindly',        label = 'Kindly' },
    { key = 'Warmly',        label = 'Warm' },
    { key = 'Ally',          label = 'Ally' },
}

local PRI_ROWS = {
    { key = 'healers', label = 'Healers', tip = 'NPC class Cleric, Druid, Shaman' },
    { key = 'closest', label = 'Closest', tip = 'Nearest remaining spawn in the pack' },
    { key = 'ranged',  label = 'Ranged',  tip = 'Wizard, Magician, Necromancer, Ranger' },
    { key = 'named',   label = 'Named',   tip = 'Hidden # prefix on the spawn name' },
    { key = 'melee',   label = 'Melee',   tip = 'Everything else' },
}

local PRI_CHOICES = { '1', '2', '3', '4', '5' }

local function priOf(pack, key)
    local n = tonumber(pack and pack.pri and pack.pri[key]) or 99
    if n < 1 then n = 1 end
    if n > 5 then n = 5 end
    return n
end

local function sortedPriRows(pack)
    local rows = {}
    for i, row in ipairs(PRI_ROWS) do
        rows[i] = row
    end
    table.sort(rows, function(a, b)
        local pa, pb = priOf(pack, a.key), priOf(pack, b.key)
        if pa ~= pb then return pa < pb end
        return a.label < b.label
    end)
    return rows
end

-- VF: Move key to newPri and shift the rest so ranks stay 1..N with no ties.
local function setPriority(pack, key, newPri)
    if type(pack) ~= 'table' or not pack.pri then return end
    newPri = tonumber(newPri) or 1
    if newPri < 1 then newPri = 1 end
    local order = {}
    for _, row in ipairs(sortedPriRows(pack)) do
        if row.key ~= key then
            order[#order + 1] = row.key
        end
    end
    if newPri > (#order + 1) then newPri = #order + 1 end
    table.insert(order, newPri, key)
    for i, k in ipairs(order) do
        pack.pri[k] = i
    end
end

local function defaultZonePack()
    local cons = {}
    for _, row in ipairs(FACTION_ROWS) do
        cons[row.key] = true
    end
    return {
        cons = cons,
        pri = { healers = 1, closest = 2, ranged = 3, named = 4, melee = 5 },
        block = { '' },
    }
end

local function copyZonePack(src)
    local pack = defaultZonePack()
    if type(src) ~= 'table' then return pack end
    if type(src.cons) == 'table' then
        for _, row in ipairs(FACTION_ROWS) do
            if src.cons[row.key] ~= nil then
                pack.cons[row.key] = not not src.cons[row.key]
            end
        end
    end
    if type(src.pri) == 'table' then
        for _, row in ipairs(PRI_ROWS) do
            local n = tonumber(src.pri[row.key])
            if n then
                if n < 1 then n = 1 end
                if n > 5 then n = 5 end
                pack.pri[row.key] = n
            end
        end
    end
    pack.block = {}
    if type(src.block) == 'table' then
        for _, line in ipairs(src.block) do
            pack.block[#pack.block + 1] = tostring(line or '')
        end
    end
    if #pack.block == 0 then pack.block[1] = '' end
    return pack
end

local function emptyFilters()
    return { zones = {}, zone = '', liveZone = '' }
end

local function copyFilters(src)
    local out = emptyFilters()
    if type(src) ~= 'table' then return out end
    if type(src.zones) == 'table' then
        for name, pack in pairs(src.zones) do
            if type(name) == 'string' and name ~= '' then
                out.zones[name] = copyZonePack(pack)
            end
        end
    end
    if type(src.zone) == 'string' then out.zone = src.zone end
    return out
end

local function ensureZone(filters, zone)
    if not zone or zone == '' then return nil end
    filters.zones[zone] = copyZonePack(filters.zones[zone])
    return filters.zones[zone]
end

-- VF: no filtersSummary / zoneNames. Both were exported and never called -- the
-- VF: Filters tab iterates state.filters directly.

-- VF: pulling is always at range. Walking up and hitting it is Rush's whole job,
-- VF: so a 'Melee' pull was a second face-pull that only Roam could reach. A saved
-- VF: 'Melee' fails the set below and falls back to 'Spell'.
local PULL_STYLES = { 'Spell', 'Ranged', 'Pet' }
local PULL_STYLE_SET = { Spell = true, Ranged = true, Pet = true }

local function defaultPull()
    return {
        style = 'Spell',
        spell = '',
        spell_gem = 1,
        engage = 100,
        stand_back = false,
    }
end

local function copyPull(src)
    local pull = defaultPull()
    if type(src) ~= 'table' then return pull end
    local style = src.pull_style or src.style
    if PULL_STYLE_SET[style] then pull.style = style end
    pull.spell = tostring(src.pull_spell or src.spell or '')
    if pull.spell == 'nil' then pull.spell = '' end
    pull.spell_gem = tonumber(src.pull_spell_gem or src.spell_gem) or pull.spell_gem
    pull.engage = tonumber(src.pull_engage_dist or src.engage) or pull.engage
    if pull.spell_gem < 1 then pull.spell_gem = 1 end
    if pull.spell_gem > NUM_GEMS then pull.spell_gem = NUM_GEMS end
    if pull.engage < 15 then pull.engage = 15 end
    if pull.engage > 250 then pull.engage = 250 end
    if src.pull_stand_back == true or src.stand_back == true then
        pull.stand_back = true
    else
        pull.stand_back = false
    end
    return pull
end

local function defaultAssist()
    return {
        ma_name = '',
        assist_at = 100,
        chase = true,
        chase_dist = 15,
        camp = nil,
    }
end

local function copyAssist(src)
    local a = defaultAssist()
    if type(src) ~= 'table' then return a end
    a.ma_name = tostring(src.ma_name or '')
    if a.ma_name == 'nil' or a.ma_name == 'NULL' then a.ma_name = '' end
    a.assist_at = tonumber(src.assist_at) or a.assist_at
    if a.assist_at < 1 then a.assist_at = 1 end
    if a.assist_at > 100 then a.assist_at = 100 end
    -- VF: Assist camp/chase checkbox gone; keep chase_dist for Group follow.
    a.chase = true
    a.chase_dist = tonumber(src.chase_dist) or a.chase_dist
    if a.chase_dist < 5 then a.chase_dist = 5 end
    if a.chase_dist > 100 then a.chase_dist = 100 end
    a.camp = nil
    return a
end

local function writeAssistToControl(control, assist)
    if type(control) ~= 'table' then control = {} end
    assist = copyAssist(assist)
    control.ma_name = assist.ma_name
    control.assist_at = assist.assist_at
    control.chase = true
    control.chase_dist = assist.chase_dist
    control.assist_camp = false
    return control
end

-- VF: Group tab â€” approved PC whitelist for auto-accept + stay in Group mode.
local function defaultGroupTrust()
    return {
        auto_accept = true,
        stay = true,
        names = {},
    }
end

local function normalizePcName(name)
    name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' or name == 'nil' or name == 'NULL' then return '' end
    return name
end

local function copyGroupTrust(src)
    local g = defaultGroupTrust()
    if type(src) ~= 'table' then return g end
    if src.group_auto_accept == false or src.auto_accept == false then g.auto_accept = false end
    if src.group_stay == false or src.stay == false then g.stay = false end
    local list = src.group_approved or src.names or src.approved
    if type(list) == 'table' then
        local seen = {}
        for _, n in ipairs(list) do
            local nm = normalizePcName(n)
            local key = nm:lower()
            if nm ~= '' and not seen[key] then
                seen[key] = true
                g.names[#g.names + 1] = nm
            end
        end
    end
    return g
end

local function writeGroupTrustToControl(control, trust)
    if type(control) ~= 'table' then control = {} end
    trust = copyGroupTrust(trust)
    control.group_auto_accept = trust.auto_accept and true or false
    control.group_stay = trust.stay and true or false
    control.group_approved = {}
    for i, n in ipairs(trust.names) do
        control.group_approved[i] = n
    end
    return control
end

-- VF: Melee and Ranged only. 'Spell' was selectable and combatTick has no branch
-- VF: for it, so picking it silently disabled engaging. A saved 'Spell' fails
-- VF: FIGHT_STYLE_SET below and falls back to the 'Melee' default -- that is the
-- VF: migration; do not add a coercion pass.
local FIGHT_STYLES = { 'Melee', 'Ranged' }
local FIGHT_STYLE_SET = { Melee = true, Ranged = true }

-- VF: Where MoveUtils /stick parks us relative to the mob.
local STICK_POSITIONS = { 'Any', 'Behind', 'Front', 'Side' }
local STICK_POSITION_SET = { Any = true, Behind = true, Front = true, Side = true }

local function defaultPrefs()
    return {
        style = 'Melee',
        melee = 14,
        ranged = 40,
        stick_position = 'Any',
        stick_handoff = 120,
        enrage_hold = true,
        combat_heal = true,
        combat_heal_pct = 65,
        post_heal = true,
        post_heal_pct = 90,
        -- VF: ordering only. HOW LOW an ally must be is the row's own Below % -- do not
        -- VF: add a threshold here, it would be a second owner of that number.
        heal_priority = 'Support first',
        retries = 2,
        lockout = 30,
        debug = false,
        -- VF: cast floor -- do not spend below this. NOT a rest trigger; that is
        -- VF: rest_mana_pct. They were the same key and raising one raised both.
        min_mana = 0,
        rest_mana_pct = 0,
        pet_assist = 100,
        pet_hold = true,
        med_on = false,
        -- VF: no med_hp_*. post_combat_heal_pct owns out-of-combat HP.
        med_mana_on = false,
        med_mana_start = 20,
        med_mana_stop = 90,
        med_end_on = false,
        med_end_start = 20,
        med_end_stop = 90,
    }
end

local function clamp(n, lo, hi, fallback)
    n = tonumber(n)
    if not n then return fallback end
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function copyPrefs(src)
    local p = defaultPrefs()
    if type(src) ~= 'table' then return p end
    local style = src.combat_style or src.style
    if FIGHT_STYLE_SET[style] then p.style = style end
    p.melee = clamp(src.melee_dist or src.melee, 5, 50, p.melee)
    p.ranged = clamp(src.ranged_dist or src.ranged, 15, 200, p.ranged)
    local spos = src.stick_position
    if STICK_POSITION_SET[spos] then p.stick_position = spos end
    p.stick_handoff = clamp(src.stick_handoff, 40, 200, p.stick_handoff)
    p.enrage_hold = (src.enrage_hold ~= false)
    if src.combat_heal == false then
        p.combat_heal_pct = 0
    else
        p.combat_heal_pct = clamp(src.combat_heal_pct, 0, 100, p.combat_heal_pct)
    end
    p.combat_heal = (p.combat_heal_pct or 0) > 0
    if src.post_combat_heal == false or src.post_heal == false then
        p.post_heal_pct = 0
    else
        p.post_heal_pct = clamp(src.post_combat_heal_pct or src.post_heal_pct, 0, 100, p.post_heal_pct)
    end
    p.post_heal = (p.post_heal_pct or 0) > 0
    if HEAL_PRIORITY_SET[src.heal_priority] then p.heal_priority = src.heal_priority end
    p.retries = clamp(src.cast_max_retries or src.retries, 1, 10, p.retries)
    p.lockout = clamp(src.cast_lockout_sec or src.lockout, 5, 300, p.lockout)
    p.debug = (src.debug_mode == true or src.debug == true)
    p.min_mana = clamp(src.min_mana_pct or src.min_mana, 0, 95, p.min_mana)
    -- VF: migrate the old route-pack mana / min_mana rest trigger into the one key.
    p.rest_mana_pct = clamp(src.rest_mana_pct, 0, 100, p.rest_mana_pct)
    p.pet_assist = clamp(src.pet_assist_at or src.pet_assist, 1, 100, p.pet_assist)
    p.pet_hold = (src.pet_hold_enabled ~= false and src.pet_hold ~= false)
    p.med_on = (src.medbreak_enabled == true or src.med_on == true)
    -- VF: med_hp_* dropped -- never read by the engine; HP is post_combat_heal_pct.
    p.med_mana_on = (src.medbreak_mana_on == true or src.med_mana_on == true)
    p.med_mana_start = clamp(src.medbreak_mana_start or src.med_mana_start, 0, 100, p.med_mana_start)
    p.med_mana_stop = clamp(src.medbreak_mana_stop or src.med_mana_stop, 0, 100, p.med_mana_stop)
    p.med_end_on = (src.medbreak_end_on == true or src.med_end_on == true)
    p.med_end_start = clamp(src.medbreak_end_start or src.med_end_start, 0, 100, p.med_end_start)
    p.med_end_stop = clamp(src.medbreak_end_stop or src.med_end_stop, 0, 100, p.med_end_stop)
    return p
end

local AA_CATS = { 'General', 'Archetype', 'Class' }

local function emptyAaQueue()
    return { items = {}, auto = true }
end

local function copyAaQueue(src)
    local q = emptyAaQueue()
    if type(src) ~= 'table' then return q end
    if src.auto == false then q.auto = false else q.auto = true end
    local function add(name, gid)
        name = U.trimName(tostring(name or ''))
        gid = tonumber(gid)
        if name == '' or name == 'NULL' then return end
        for _, it in ipairs(q.items) do
            if (gid and it.gid and it.gid == gid) or it.name == name then return end
        end
        q.items[#q.items + 1] = { name = name, gid = gid }
    end
    if type(src.items) == 'table' then
        for _, it in ipairs(src.items) do
            if type(it) == 'table' then
                add(it.name, it.gid)
            elseif type(it) == 'string' then
                add(it)
            end
        end
    elseif type(src.names) == 'table' then
        for i, name in ipairs(src.names) do
            add(name, type(src.gids) == 'table' and src.gids[i] or nil)
        end
    else
        for _, name in ipairs(src) do
            if type(name) == 'string' then add(name) end
        end
    end
    return q
end

local function aaQueuePri(queue, name, gid)
    name = U.trimName(tostring(name or ''))
    gid = tonumber(gid)
    if type(queue) ~= 'table' or type(queue.items) ~= 'table' then return 0 end
    for i, it in ipairs(queue.items) do
        if gid and it.gid and it.gid == gid then return i end
        if name ~= '' and it.name == name then return i end
    end
    return 0
end

local function setAaQueuePri(queue, name, newPri, gid)
    if type(queue) ~= 'table' then return end
    queue.items = queue.items or {}
    name = U.trimName(tostring(name or ''))
    gid = tonumber(gid)
    if name == '' then return end
    newPri = tonumber(newPri) or 0
    local items = {}
    for _, it in ipairs(queue.items) do
        local same = (gid and it.gid and it.gid == gid) or it.name == name
        if not same then items[#items + 1] = it end
    end
    if newPri < 1 then
        queue.items = items
        return
    end
    if newPri > (#items + 1) then newPri = #items + 1 end
    table.insert(items, newPri, { name = name, gid = gid })
    queue.items = items
end

local function setAaQueueOn(queue, name, on, gid)
    if type(queue) ~= 'table' then return end
    if on then
        if aaQueuePri(queue, name, gid) > 0 then return end
        queue.items = queue.items or {}
        setAaQueuePri(queue, name, #queue.items + 1, gid)
    else
        setAaQueuePri(queue, name, 0, gid)
    end
end

local function aaPriChoices(n, inQueue)
    n = tonumber(n) or 0
    local maxn = inQueue and n or (n + 1)
    if maxn < 1 then maxn = 1 end
    local c = { 'â€”' }
    for i = 1, maxn do c[#c + 1] = tostring(i) end
    return c
end

local function emptyAaBook()
    return { purchased = {}, unpurchased = {}, at = 0 }
end

local function copyAaLine(src, kind)
    if type(src) ~= 'table' then return nil end
    local name = U.trimName(tostring(src.name or ''))
    if name == '' or name == 'NULL' then return nil end
    local bucket = src.bucket
    if bucket ~= 'General' and bucket ~= 'Archetype' and bucket ~= 'Class' then
        bucket = 'General'
    end
    local row = {
        name = name,
        gid = tonumber(src.gid),
        bucket = bucket,
        owned = tonumber(src.owned) or 0,
        max = tonumber(src.max) or 1,
    }
    if kind == 'unpurchased' then
        row.cost = tonumber(src.cost) or 0
        row.canTrain = src.canTrain and true or false
        row.buyId = tonumber(src.buyId) or 0
    else
        row.activated = src.activated and true or false
    end
    return row
end

local function copyAaBook(src)
    local book = emptyAaBook()
    if type(src) ~= 'table' then return book end
    book.at = tonumber(src.at) or 0
    if type(src.purchased) == 'table' then
        for _, rec in ipairs(src.purchased) do
            local row = copyAaLine(rec, 'purchased')
            if row then book.purchased[#book.purchased + 1] = row end
        end
    end
    if type(src.unpurchased) == 'table' then
        for _, rec in ipairs(src.unpurchased) do
            local row = copyAaLine(rec, 'unpurchased')
            if row then book.unpurchased[#book.unpurchased + 1] = row end
        end
    end
    return book
end

local function aaBookReady(book)
    if type(book) ~= 'table' then return false end
    local p = book.purchased
    local u = book.unpurchased
    return (type(p) == 'table' and #p > 0) or (type(u) == 'table' and #u > 0)
end

local function aaCatalogFromBook(book)
    local cat = { General = {}, Archetype = {}, Class = {} }
    if type(book) ~= 'table' or type(book.unpurchased) ~= 'table' then return cat end
    for _, rec in ipairs(book.unpurchased) do
        local row = copyAaLine(rec, 'unpurchased')
        if row then
            local list = cat[row.bucket] or cat.General
            list[#list + 1] = row
        end
    end
    for _, list in pairs(cat) do
        table.sort(list, function(a, b)
            return (a.name or '') < (b.name or '')
        end)
    end
    return cat
end

local function noteAaPurchased(book, name, gid)
    book = copyAaBook(book)
    name = U.trimName(tostring(name or ''))
    gid = tonumber(gid)
    local un = book.unpurchased
    for i, rec in ipairs(un) do
        local same = (gid and rec.gid and rec.gid == gid) or (name ~= '' and rec.name == name)
        if same then
            rec.owned = (tonumber(rec.owned) or 0) + 1
            local maxr = tonumber(rec.max) or 1
            if rec.owned >= maxr then
                table.remove(un, i)
                local found = false
                for _, p in ipairs(book.purchased) do
                    if (gid and p.gid and p.gid == gid) or p.name == rec.name then
                        p.owned = maxr
                        p.max = maxr
                        found = true
                        break
                    end
                end
                if not found then
                    book.purchased[#book.purchased + 1] = {
                        name = rec.name,
                        gid = rec.gid,
                        bucket = rec.bucket,
                        owned = maxr,
                        max = maxr,
                        activated = true,
                    }
                end
            end
            book.at = os.time()
            return book
        end
    end
    return book
end

local function writePrefsToControl(control, prefs)
    if type(control) ~= 'table' then control = {} end
    prefs = copyPrefs(prefs)
    control.combat_style = prefs.style
    control.melee_dist = prefs.melee
    control.ranged_dist = prefs.ranged
    control.stick_position = prefs.stick_position
    control.stick_handoff = prefs.stick_handoff
    control.enrage_hold = prefs.enrage_hold ~= false
    control.combat_heal = (prefs.combat_heal_pct or 0) > 0
    control.combat_heal_pct = prefs.combat_heal_pct or 0
    control.post_combat_heal = (prefs.post_heal_pct or 0) > 0
    control.post_combat_heal_pct = prefs.post_heal_pct or 0
    control.heal_priority = HEAL_PRIORITY_SET[prefs.heal_priority] and prefs.heal_priority
        or 'Support first'
    control.cast_max_retries = prefs.retries
    control.cast_lockout_sec = prefs.lockout
    control.debug_mode = prefs.debug
    control.min_mana_pct = prefs.min_mana
    control.rest_mana_pct = prefs.rest_mana_pct or 0
    control.pet_assist_at = prefs.pet_assist
    control.pet_hold_enabled = prefs.pet_hold
    control.medbreak_enabled = prefs.med_on
    -- VF: no medbreak_hp_* written. Nothing read it; see enginestate.recoveryOutstanding.
    control.medbreak_mana_on = prefs.med_mana_on
    control.medbreak_mana_start = prefs.med_mana_start
    control.medbreak_mana_stop = prefs.med_mana_stop
    control.medbreak_end_on = prefs.med_end_on
    control.medbreak_end_start = prefs.med_end_start
    control.medbreak_end_stop = prefs.med_end_stop
    control.maintain_buffs = true
    control.hud = 'mini'
    return control
end

-- VF: no applyPrefsToCtrl. It was a never-called wrapper over writePrefsToControl,
-- VF: which every live save path calls directly -- a second name for one job.

local function writePullToControl(control, pull)
    if type(control) ~= 'table' then control = {} end
    pull = copyPull(pull)
    control.pull_style = pull.style
    control.pull_spell = pull.spell
    control.pull_spell_gem = pull.spell_gem
    control.pull_engage_dist = pull.engage
    control.pull_stand_back = pull.stand_back
    return control
end

-- VF: engine seed only. Prefs/pull/group-assist come from the writers above.
local function defaultControl()
    local c = {
        running = false,
        mode = 'Manual',
        submode = 'Hunt',
        xtar_nav_dist = 150,
        -- VF: camp_* kept nil for old loadout keys; Puller Camp is deleted.
        camp_loc = nil,
        camp_radius = 100,
        camp_z = 75,
        camp_z_plane = 15,
        hunter_radius = 1500,
        hunter_z_plane = 15,
        hunter_z = 75,
        hunter_min_level = 1,
        hunter_max_level = 100,
        hunter_level_rel = true,
        hunter_rel_min = 0,
        hunter_rel_max = 5,
        hunter_combat_radius = 250,
        hunter_combat_loc = nil,
        pull_min_level = 1,
        pull_max_level = 100,
        pull_con_filter = {},
        check_closer_mobs = true,
        focus_adds = false,
        group_anchor = false,
        group_anchor_loc = nil,
        buff_max_tries = 3,
        buff_retry_sec = 60,
        post_combat_heal_max_sec = 45,
        -- VF: default matches the behavior that shipped for every character before the
        -- VF: key existed -- heal bands preempt offense. Only set 'DPS first' to opt out.
        heal_priority = 'Support first',
        burn = false,
        boost = false,
        compact = true,
        group_auto_accept = true,
        group_stay = true,
        group_approved = {},
    }
    writePrefsToControl(c, defaultPrefs())
    writePullToControl(c, defaultPull())
    writeAssistToControl(c, defaultAssist())
    writeGroupTrustToControl(c, defaultGroupTrust())
    return c
end

local function defaultRoutePack()
    return {
        range = 1500,
        wander = 1500,
        scan = 1500,
        chase = 150,
        -- VF: no mana here. Resting is one character-wide prefs.rest_mana_pct;
        -- VF: a per-zone copy meant the same decision had three owners.
        floor = 25,
        maxz = 25,
        z = 25,
        closer = true,
        locs = {},
    }
end

local function copyRoutePack(src)
    local pack = defaultRoutePack()
    if type(src) ~= 'table' then return pack end
    pack.scan = tonumber(src.scan) or tonumber(src.wander) or tonumber(src.range) or pack.scan
    if pack.scan < 10 then pack.scan = 10 end
    if pack.scan > 2000 then pack.scan = 2000 end
    pack.range = pack.scan
    pack.wander = pack.scan
    pack.chase = tonumber(src.chase) or pack.chase
    pack.z = tonumber(src.z) or tonumber(src.maxz) or tonumber(src.floor) or pack.z
    if pack.z < 5 then pack.z = 5 end
    if pack.z > 300 then pack.z = 300 end
    pack.floor = pack.z
    pack.maxz = pack.z
    if src.closer == false then pack.closer = false else pack.closer = true end
    if pack.chase < 25 then pack.chase = 25 end
    if pack.chase > 300 then pack.chase = 300 end
    pack.lib_id = src.lib_id
    pack.locs = {}
    if type(src.locs) == 'table' then
        for _, loc in ipairs(src.locs) do
            if type(loc) == 'table' then
                local x, y, z = tonumber(loc.x), tonumber(loc.y), tonumber(loc.z)
                -- VF: z is optional.
                if x and y then
                    local kind = tostring(loc.kind or loc.wp or ''):lower()
                    if kind ~= 'travel' and kind ~= 'guide' then kind = 'loop' end
                    pack.locs[#pack.locs + 1] = { x = x, y = y, z = z, kind = kind }
                end
            end
        end
    end
    return pack
end

local function emptyRoutes()
    return { zones = {}, zone = '', liveZone = '' }
end

local function copyRoutes(src)
    local out = emptyRoutes()
    if type(src) ~= 'table' then return out end
    if type(src.zones) == 'table' then
        for name, pack in pairs(src.zones) do
            if type(name) == 'string' and name ~= '' then
                out.zones[name] = copyRoutePack(pack)
            end
        end
    end
    if type(src.zone) == 'string' then out.zone = src.zone end
    return out
end

local function ensureRouteZone(routes, zone)
    if not zone or zone == '' then return nil end
    routes.zones[zone] = copyRoutePack(routes.zones[zone])
    return routes.zones[zone]
end

-- VF: First Combat-tab visit after this cut: old zone packs have no floor/maxz/closer.
local function seedRoutePacksFromCtrl(routes, rawZones, ctrl)
    if type(routes) ~= 'table' or type(routes.zones) ~= 'table' then return end
    if type(ctrl) ~= 'table' then return end
    rawZones = (type(rawZones) == 'table') and rawZones or {}
    for name, pack in pairs(routes.zones) do
        if type(pack) == 'table' then
            local raw = rawZones[name]
            if type(raw) ~= 'table' or raw.floor == nil then
                pack.floor = tonumber(ctrl.hunter_z_plane) or tonumber(ctrl.camp_z_plane) or pack.floor
            end
            if type(raw) ~= 'table' or raw.maxz == nil then
                pack.maxz = tonumber(ctrl.hunter_z) or tonumber(ctrl.camp_z) or pack.maxz
            end
            if type(raw) ~= 'table' or raw.closer == nil then
                pack.closer = (ctrl.check_closer_mobs ~= false)
            end
        end
    end
end

local function emptyRouteLib()
    return { items = {} }
end

local function copyRouteLibItem(src)
    if type(src) ~= 'table' then return nil end
    local name = U.trimName(tostring(src.name or ''))
    local zone = U.trimName(tostring(src.zone or ''))
    if name == '' or zone == '' then return nil end
    return {
        id = U.trimName(tostring(src.id or '')) ,
        name = name,
        zone = zone,
        map = U.trimName(tostring(src.map or '')),
        note = tostring(src.note or ''),
        pack = copyRoutePack(src.pack),
    }
end

local function copyRouteLib(src)
    local lib = emptyRouteLib()
    if type(src) ~= 'table' then return lib end
    local raw = src.items
    if type(raw) ~= 'table' then raw = src end
    for _, it in ipairs(raw) do
        local row = copyRouteLibItem(it)
        if row then
            if row.id == '' then row.id = row.zone .. ':' .. row.name end
            lib.items[#lib.items + 1] = row
        end
    end
    return lib
end

local function removeRoute(lib, id)
    lib = copyRouteLib(lib)
    id = U.trimName(tostring(id or ''))
    if id == '' then return lib, false end
    local kept, removed = {}, false
    for _, it in ipairs(lib.items) do
        if it.id == id then
            removed = true
        else
            kept[#kept + 1] = it
        end
    end
    lib.items = kept
    return lib, removed
end

local function routesForZone(lib, zone)
    local out = {}
    zone = U.trimName(tostring(zone or '')):lower()
    if zone == '' or type(lib) ~= 'table' or type(lib.items) ~= 'table' then return out end
    for _, it in ipairs(lib.items) do
        if tostring(it.zone or ''):lower() == zone then out[#out + 1] = it end
    end
    table.sort(out, function(a, b) return (a.name or '') < (b.name or '') end)
    return out
end

local function findRoute(lib, id)
    id = U.trimName(tostring(id or ''))
    if id == '' or type(lib) ~= 'table' then return nil end
    for _, it in ipairs(lib.items or {}) do
        if it.id == id then return it end
    end
    return nil
end

local function upsertRoute(lib, item)
    lib = copyRouteLib(lib)
    item = copyRouteLibItem(item)
    if not item then return lib, nil end
    if item.id == '' then
        item.id = item.zone .. ':' .. tostring(os.time())
    end
    local found = false
    for i, it in ipairs(lib.items) do
        if it.id == item.id then
            lib.items[i] = item
            found = true
            break
        end
    end
    if not found then lib.items[#lib.items + 1] = item end
    return lib, item
end

-- VF: Move loc `from` to slot `to` (1-based).
local function moveLoc(locs, from, to)
    if type(locs) ~= 'table' then return false end
    local n = #locs
    from = math.floor(tonumber(from) or 0)
    to = math.floor(tonumber(to) or 0)
    if from < 1 or from > n then return false end
    if to < 1 then to = 1 end
    if to > n then to = n end
    if from == to then return false end
    local item = table.remove(locs, from)
    table.insert(locs, to, item)
    return true
end

local function captureLoc(mq)
    local x, y, z
    pcall(function()
        x, y, z = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
    end)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then return nil end
    return {
        x = math.floor(x * 10) / 10,
        y = math.floor(y * 10) / 10,
        z = math.floor(z * 10) / 10,
        kind = 'loop',
    }
end

local LOC_KINDS = { 'Loop', 'Travel', 'Guide' }

local function locKind(loc)
    local k = loc and tostring(loc.kind or loc.wp or ''):lower() or ''
    if k == 'travel' or k == 'guide' then return k end
    return 'loop'
end

local function locKindLabel(k)
    if k == 'travel' then return 'Travel' end
    if k == 'guide' then return 'Guide' end
    return 'Loop'
end

local function migrateAbility(rec)
    if type(rec) ~= 'table' then return rec end
    if rec.combat == nil and rec.t3_combat ~= nil then rec.combat = rec.t3_combat end
    if rec.cast_type == nil and rec.t3_type ~= nil then rec.cast_type = rec.t3_type end
    if rec.ui_pct == nil and rec.t3_pct ~= nil then rec.ui_pct = rec.t3_pct end
    if rec.above == nil and rec.t3_above ~= nil then rec.above = rec.t3_above end
    -- VF: fold dropped Type names onto the new catalog.
    local n = normalizeType(rec.cast_type)
    if n then rec.cast_type = n end
    rec.interrupt = nil
    rec.t3_combat = nil
    rec.t3_interrupt = nil
    rec.t3_type = nil
    rec.t3_pct = nil
    rec.t3_above = nil
    return rec
end

-- VF: AA/disc pct/ui_pct >= 98 â†’ blank (ungated). Offense AAs only; all discs.
local FILLER_SNIP_TYPES = {
    Melee = true, Nuke = true, DoT = true, Debuff = true, CC = true, Tap = true,
}

local function snipAaFillerThreshold(rec)
    if type(rec) ~= 'table' then return rec end
    local typ = normalizeType(rec.cast_type or rec.t3_type)
    if not (typ and FILLER_SNIP_TYPES[typ]) then return rec end
    local pct = tonumber(rec.pct)
    local ui = tonumber(rec.ui_pct)
    if ui and ui >= 98 then rec.ui_pct = nil end
    if pct and pct >= 98 then rec.pct = nil end
    return rec
end

local function snipDiscHpThreshold(rec)
    if type(rec) ~= 'table' then return rec end
    local pct = tonumber(rec.pct)
    local ui = tonumber(rec.ui_pct)
    if ui and ui >= 98 then rec.ui_pct = nil end
    if pct and pct >= 98 then rec.pct = nil end
    return rec
end

local function migrateEntry(e)
    if type(e) ~= 'table' then return e end
    if e.filters == nil and e.t3_filters ~= nil then e.filters = e.t3_filters end
    if e.off_limit == nil and e.t3_off_limit ~= nil then e.off_limit = e.t3_off_limit end
    e.t3_filters = nil
    e.t3_off_limit = nil
    if type(e.gems) == 'table' then
        for k, g in pairs(e.gems) do e.gems[k] = migrateAbility(g) end
    end
    if type(e.aas) == 'table' then
        for k, g in pairs(e.aas) do
            e.aas[k] = snipAaFillerThreshold(migrateAbility(g))
        end
    end
    if type(e.discs) == 'table' then
        local discs = {}
        for k, g in pairs(e.discs) do
            if type(g) ~= 'table' or g.via ~= 'skill' then
                discs[k] = snipDiscHpThreshold(migrateAbility(g))
            end
        end
        e.discs = discs
    end
    if type(e.items) == 'table' then
        for k, g in pairs(e.items) do
            local rec = snipAaFillerThreshold(migrateAbility(g))
            if type(rec) == 'table' then
                rec.via = 'item'
                e.items[k] = rec
            end
        end
    end
    if type(e.spell_gates) == 'table' then
        local gates = {}
        for k, g in pairs(e.spell_gates) do
            local rec = migrateAbility(g)
            if type(rec) == 'table' then
                local key = U.normalizeSpellName(rec.spell or k)
                if key ~= '' then
                    rec.spell = rec.spell or tostring(k)
                    gates[key] = rec
                end
            end
        end
        e.spell_gates = gates
    end
    -- VF: melee toggles live in MQ2Melee ini / meleemvi â€” drop any stale char-sheet copy.
    e.melee_abilities = nil
    return e
end

-- VF: shared hub zones -- no auto-target. ShortName keys. config/ta_safe_zones.lua.
local function defaultSafeZones()
    return { 'bazaar', 'poknowledge', 'potranquility' }
end

local function normalizeZoneKey(s)
    s = tostring(s or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' or s == 'null' then return '' end
    return s
end

local function copySafeZones(src)
    local out, seen = {}, {}
    local function add(z)
        z = normalizeZoneKey(z)
        if z == '' or seen[z] then return end
        seen[z] = true
        out[#out + 1] = z
    end
    if type(src) == 'table' then
        if type(src.zones) == 'table' then
            for _, z in ipairs(src.zones) do add(z) end
        else
            for _, z in ipairs(src) do add(z) end
        end
    end
    table.sort(out)
    return out
end

return {
    NUM_GEMS = NUM_GEMS,
    TYPES = TYPES,
    COMBATS = COMBATS,
    MOBS_OPS = MOBS_OPS,
    defaultCombat = defaultCombat,
    HEAL_PRIORITIES = HEAL_PRIORITIES,
    WHENS = WHENS,
    SPECIAL_SKILL = SPECIAL_SKILL,
    isWhenOk = isWhenOk,
    nextType = nextType,
    defaultBelow = defaultBelow,
    hpBandKind = hpBandKind,
    hpBandEditable = hpBandEditable,
    mapType = mapType,
    normalizeType = normalizeType,
    typeFromStored = typeFromStored,
    inferTypeFromTLO = inferTypeFromTLO,
    parseMobs = parseMobs,
    composeMobs = composeMobs,
    mobsPartsFromText = mobsPartsFromText,
    mobsToFields = mobsToFields,
    fieldsToMobs = fieldsToMobs,
    indexByName = indexByName,
    findNamed = findNamed,
    copySpellGates = copySpellGates,
    seedSpellGates = seedSpellGates,
    lookupSpellGate = lookupSpellGate,
    rememberSpellGate = rememberSpellGate,
    mergeNamedAbilities = mergeNamedAbilities,
    pruneUnownedAas = pruneUnownedAas,
    pruneUnownedDiscs = pruneUnownedDiscs,
    pruneUnownedItems = pruneUnownedItems,
    itemStillOwned = itemStillOwned,
    itemExtraBuffs = itemExtraBuffs,
    aaStillOwned = aaStillOwned,
    rowFromGem = rowFromGem,
    rowFromAbility = rowFromAbility,
    buildGemEntry = buildGemEntry,
    buildAbilityEntry = buildAbilityEntry,
    migrateAbility = migrateAbility,
    migrateEntry = migrateEntry,
    isCeilingMobs = isCeilingMobs,
    isCeilingMobsRow = isCeilingMobsRow,
    FACTION_ROWS = FACTION_ROWS,
    PRI_ROWS = PRI_ROWS,
    PRI_CHOICES = PRI_CHOICES,
    priOf = priOf,
    sortedPriRows = sortedPriRows,
    setPriority = setPriority,
    defaultZonePack = defaultZonePack,
    copyZonePack = copyZonePack,
    emptyFilters = emptyFilters,
    copyFilters = copyFilters,
    ensureZone = ensureZone,
    defaultRoutePack = defaultRoutePack,
    copyRoutePack = copyRoutePack,
    emptyRoutes = emptyRoutes,
    copyRoutes = copyRoutes,
    ensureRouteZone = ensureRouteZone,
    emptyRouteLib = emptyRouteLib,
    copyRouteLib = copyRouteLib,
    routesForZone = routesForZone,
    findRoute = findRoute,
    upsertRoute = upsertRoute,
    removeRoute = removeRoute,
    seedRoutePacksFromCtrl = seedRoutePacksFromCtrl,
    captureLoc = captureLoc,
    moveLoc = moveLoc,
    LOC_KINDS = LOC_KINDS,
    locKind = locKind,
    locKindLabel = locKindLabel,
    PULL_STYLES = PULL_STYLES,
    defaultPull = defaultPull,
    copyPull = copyPull,
    writePullToControl = writePullToControl,
    defaultControl = defaultControl,
    defaultAssist = defaultAssist,
    copyAssist = copyAssist,
    writeAssistToControl = writeAssistToControl,
    defaultGroupTrust = defaultGroupTrust,
    copyGroupTrust = copyGroupTrust,
    writeGroupTrustToControl = writeGroupTrustToControl,
    normalizePcName = normalizePcName,
    FIGHT_STYLES = FIGHT_STYLES,
    STICK_POSITIONS = STICK_POSITIONS,
    defaultPrefs = defaultPrefs,
    copyPrefs = copyPrefs,
    writePrefsToControl = writePrefsToControl,
    emptyAaQueue = emptyAaQueue,
    copyAaQueue = copyAaQueue,
    aaQueuePri = aaQueuePri,
    setAaQueuePri = setAaQueuePri,
    setAaQueueOn = setAaQueueOn,
    aaPriChoices = aaPriChoices,
    emptyAaBook = emptyAaBook,
    copyAaBook = copyAaBook,
    aaBookReady = aaBookReady,
    aaCatalogFromBook = aaCatalogFromBook,
    noteAaPurchased = noteAaPurchased,
    AA_CATS = AA_CATS,
    defaultSafeZones = defaultSafeZones,
    normalizeZoneKey = normalizeZoneKey,
    copySafeZones = copySafeZones,
}
