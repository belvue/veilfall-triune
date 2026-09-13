---@diagnostic disable: undefined-global, undefined-field
-- VF: Triune super-aug catalog, name parse, 4+4 convert, shopping status.

local mq
do
    local ok, mod = pcall(require, 'mq')
    if ok then mq = mod end
end

local M = {}

-- VF: MQ Lua has no | operator; same helper as vft.inv.app.
local function bitbor(...)
    if bit and bit.bor then return bit.bor(...) end
    local acc = 0
    for i = 1, select('#', ...) do acc = acc + (select(i, ...) or 0) end
    return acc
end

local KERA_FLAVORS = {
    'Cleaving', 'Ferocity', 'Sharpshooting', 'Blocking', 'Dodging', 'Magic',
    'Affliction', 'Enhancement', 'Torment', 'Healing', 'Summoning', 'Range',
    'Hastened Casting', 'Faerune', 'Preservation',
}

local SERU_FLAVORS = {
    'Runic', 'Akhevan', 'Ssraeshzian', 'Yttrium', 'Lethal', 'Magical',
    'Fiery', 'Icy', 'Healing', 'Hastened', 'Gelid', 'Replenishing',
}

local ZEB_FLAVORS = {
    'Turbulent', 'Trueflight', 'Unseen', 'Frenzied', 'Crashing', 'Evocative',
    'Altered', 'Conjured', 'Lyrical', 'Howling', 'Runic', 'Corrupted',
}

M.FAMILY_ORDER = { 'kera', 'seru', 'zeb' }

-- VF: Base green, Enchanted blue, Legendary orange (shop counts + item names).
M.TIER = {
    base = { 0.37, 0.88, 0.64, 1 },
    enchanted = { 0.42, 0.68, 1.00, 1 },
    legendary = { 1.00, 0.58, 0.16, 1 },
    ready = { 0.95, 0.82, 0.22, 1 },
}

-- VF: 4-slot upgrade vs XL 16-base legendary. Do not treat them as one item.
M.QUAD_ITEM = 'Gnomish Quadramorphic Combinerator'
M.XL_ITEM = 'XL Gnomish Quadramorphic Combinerator'
M.QUAD_ID, M.XL_ID = 4041, 24150

M.FAMILIES = {
    kera = {
        id = 'kera',
        label = 'Kera',
        hint = 'prismatic',
        prefix = 'Prismatic Scale of ',
        flavors = KERA_FLAVORS,
        extras = {
            'Essence of Earth', 'Essence of Wind', 'Essence of Fire', 'Essence of Water',
            'Crucible of the Elements',
        },
        goal = 15,
    },
    seru = {
        id = 'seru',
        label = 'Seru',
        hint = 'of truth',
        suffix = ' Fragment of Truth',
        flavors = SERU_FLAVORS,
        extras = { 'Time Phased Quintessence', 'Vortex of the Past' },
        goal = 12,
    },
    zeb = {
        id = 'zeb',
        label = 'Zeb',
        hint = 'splinter of time',
        suffix = ' Splinter of Time',
        flavors = ZEB_FLAVORS,
        extras = {},
        goal = 12,
    },
}

local WORN_SLOTS = {
    'charm', 'leftear', 'head', 'face', 'rightear', 'neck', 'shoulder', 'arms',
    'back', 'leftwrist', 'rightwrist', 'ranged', 'hands', 'primary', 'secondary',
    'leftfinger', 'rightfinger', 'chest', 'legs', 'feet', 'waist', 'ammo',
    'powersource',
}

local WORN_LABEL = {
    charm = 'Charm', leftear = 'Left Ear', head = 'Head', face = 'Face',
    rightear = 'Right Ear', neck = 'Neck', shoulder = 'Shoulder', arms = 'Arms',
    back = 'Back', leftwrist = 'Left Wrist', rightwrist = 'Right Wrist',
    ranged = 'Ranged', hands = 'Hands', primary = 'Primary', secondary = 'Secondary',
    leftfinger = 'Left Finger', rightfinger = 'Right Finger', chest = 'Chest',
    legs = 'Legs', feet = 'Feet', waist = 'Waist', ammo = 'Ammo',
    powersource = 'Power Source',
}

function M.wornLoc(slot, n)
    local label = WORN_LABEL[slot] or tostring(slot or '?')
    n = tonumber(n) or 0
    if n > 1 then return 'worn ' .. label .. ' ' .. n end
    return 'worn ' .. label
end

local function trim(s)
    return tostring(s or ''):match('^%s*(.-)%s*$') or ''
end

local function lower(s)
    return trim(s):lower()
end

function M.parseName(name)
    name = trim(name)
    if name == '' or name == 'NULL' then return nil end
    local stem = name
    local tier = 'base'
    local low = name:lower()
    if low:find('%s*%(legendary%)%s*$') then
        tier = 'legendary'
        stem = name:gsub('%s*%([Ll]egendary%)%s*$', '')
    elseif low:find('%s*%(enchanted%)%s*$') then
        tier = 'enchanted'
        stem = name:gsub('%s*%([Ee]nchanted%)%s*$', '')
    end
    return trim(stem), tier, name
end

function M.combinerKind(name, id)
    id = tonumber(id) or 0
    if id == M.XL_ID then return 'xl' end
    if id == M.QUAD_ID then return 'quad' end
    local stem = M.parseName(name)
    if not stem then return nil end
    local s = lower(stem)
    if s == lower(M.XL_ITEM) then return 'xl' end
    if s == lower(M.QUAD_ITEM) then return 'quad' end
    if s:find('xl gnomish quadramorphic combin', 1, true) then return 'xl' end
    if s:find('gnomish quadramorphic combin', 1, true) then return 'quad' end
    return nil
end

function M.isXl(name, id)
    return M.combinerKind(name, id) == 'xl'
end

function M.isQuad(name, id)
    return M.combinerKind(name, id) == 'quad'
end

local function extraOf(fam, stem)
    local want = lower(stem)
    for _, ex in ipairs(fam.extras or {}) do
        if lower(ex) == want then return ex end
    end
    return nil
end

function M.classify(name)
    local stem, tier = M.parseName(name)
    if not stem then return nil end
    for _, id in ipairs(M.FAMILY_ORDER) do
        local fam = M.FAMILIES[id]
        local extra = extraOf(fam, stem)
        if extra then
            return { family = id, extra = extra, tier = tier, stem = stem }
        end
        if fam.prefix then
            local pre = fam.prefix
            if stem:sub(1, #pre) == pre then
                local flavor = trim(stem:sub(#pre + 1))
                for _, fl in ipairs(fam.flavors) do
                    if fl == flavor then
                        return { family = id, flavor = fl, tier = tier, stem = stem }
                    end
                end
            end
        end
        if fam.suffix then
            local suf = fam.suffix
            if stem:sub(-#suf) == suf then
                local flavor = trim(stem:sub(1, #stem - #suf))
                for _, fl in ipairs(fam.flavors) do
                    if fl == flavor then
                        return { family = id, flavor = fl, tier = tier, stem = stem }
                    end
                end
            end
        end
    end
    return nil
end

-- VF: Drop family boilerplate; keep flavor + (Enchanted)/(Legendary).
function M.displayName(name)
    local kind = M.combinerKind(name)
    if kind == 'xl' then return 'XL Combinerator', 'ready' end
    if kind == 'quad' then return 'Combinerator', 'ready' end
    local info = M.classify(name)
    if not info then return name, nil end
    local label = info.flavor or info.extra or info.stem or name
    local tier = info.tier
    if not info.flavor then
        if tier ~= 'enchanted' and tier ~= 'legendary' then return label, nil end
        return label, tier
    end
    if tier == 'enchanted' then return label .. ' (Enchanted)', 'enchanted' end
    if tier == 'legendary' then return label .. ' (Legendary)', 'legendary' end
    return label, 'base'
end

function M.locLabel(row)
    local w = row and row.where or ''
    if w == 'worn' then return 'Worn' end
    if w == 'bank' then return 'Bank' end
    if w == 'bags' then return 'Bags' end
    if row and row.loc and row.loc ~= '' then return row.loc end
    return '-'
end

function M.convert(b, e, l)
    b = tonumber(b) or 0
    e = tonumber(e) or 0
    l = tonumber(l) or 0
    e = e + math.floor(b / 4)
    b = b % 4
    l = l + math.floor(e / 4)
    e = e % 4
    return b, e, l
end

function M.statusLine(b, e, l, xlOn)
    b, e, l = tonumber(b) or 0, tonumber(e) or 0, tonumber(l) or 0
    -- VF: done is a real legendary, not 4+4 folded by convert.
    if l >= 1 then return 'done' end
    if xlOn and b >= 16 then return 'ready XL' end
    if e >= 4 or b >= 4 then return 'ready combine' end
    local need = 16 - (e * 4 + b)
    if need <= 0 then return 'done' end
    return string.format('need %d more base', need)
end

function M.vfRunning()
    if not mq then return false end
    local found = false
    pcall(function()
        local pids = tostring(mq.TLO.Lua.PIDs() or '')
        for tok in pids:gmatch('%d+') do
            local pid = tonumber(tok)
            local s = pid and mq.TLO.Lua.Script(pid) or nil
            if s then
                local st, sn = '', ''
                pcall(function() st = tostring(s.Status() or '') end)
                if st == 'RUNNING' or st == 'PAUSED' then
                    pcall(function() sn = tostring(s.Name() or ''):gsub('\\', '/'):lower() end)
                    if sn == 'vf' then found = true; return end
                end
            end
        end
    end)
    return found
end

function M.extraLines(tally, familyId)
    local fam = M.FAMILIES[familyId]
    local lines = {}
    if not fam then return lines, '' end
    for _, ex in ipairs(fam.extras or {}) do
        lines[#lines + 1] = string.format('%s  %d', ex, (tally and tally.extras and tally.extras[ex]) or 0)
    end
    local foot = string.format('%d/%d legendary', (tally and tally.done) or 0, fam.goal or 0)
    return lines, foot
end

function M.xlCount(rows)
    return M.countCombiner(rows, 'xl')
end

function M.countCombiner(rows, kind)
    local n = 0
    for _, row in ipairs(rows or {}) do
        if not row.empty and M.combinerKind(row.name, row.id) == kind then
            n = n + (tonumber(row.qty) or 1)
        end
    end
    return n
end

function M.stemOf(familyId, flavor)
    local fam = M.FAMILIES[familyId]
    if not fam or not flavor or flavor == '' then return nil end
    if fam.prefix then return fam.prefix .. flavor end
    return flavor .. (fam.suffix or '')
end

function M.countName(rows, name, where)
    local n = 0
    if not name or name == '' then return 0 end
    for _, row in ipairs(rows or {}) do
        if not row.empty and row.name == name and (not where or row.where == where) then
            n = n + (tonumber(row.qty) or 1)
        end
    end
    return n
end

-- VF: 16 base uses XL; 4 identical uses the 4-slot Gnomish.
function M.xlPlan(rows, familyId, flavor)
    local stem = M.stemOf(familyId, flavor)
    if not stem then return nil, 'pick a flavor' end
    local base = stem
    local enc = stem .. ' (Enchanted)'
    local leg = stem .. ' (Legendary)'
    local n4 = M.countCombiner(rows, 'quad')
    local n16 = M.countCombiner(rows, 'xl')
    local bagsB, bankB = M.countName(rows, base, 'bags'), M.countName(rows, base, 'bank')
    local bagsE, bankE = M.countName(rows, enc, 'bags'), M.countName(rows, enc, 'bank')
    local function pack(kind, need, fodder, result, bags, bank, combiner)
        return {
            kind = kind, need = need, fodder = fodder, result = result,
            bags = bags, bank = bank, xl = n16, quad = n4,
            combiner = combiner,
            combinerName = (combiner == 'xl') and M.XL_ITEM or M.QUAD_ITEM,
        }
    end
    if (bagsB + bankB) >= 16 then
        return pack('xl', 16, base, leg, bagsB, bankB, 'xl')
    end
    if (bagsE + bankE) >= 4 then
        return pack('to_leg', 4, enc, leg, bagsE, bankE, 'quad')
    end
    if (bagsB + bankB) >= 4 then
        return pack('to_enc', 4, base, enc, bagsB, bankB, 'quad')
    end
    return nil, string.format('need %d more base (or %d enchanted)',
        math.max(0, 4 - (bagsB + bankB)), math.max(0, 4 - (bagsE + bankE)))
end

function M.drawShop(ImGui, st)
    if not ImGui or not st then return end
    local MUTED = st.muted or { 0.541, 0.439, 0.533, 1 }
    local GOOD = st.good or { 0.37, 0.88, 0.64, 1 }
    local BASE = M.TIER.base
    local ENCH = M.TIER.enchanted
    local LEG = M.TIER.legendary
    local READY = M.TIER.ready
    local TAB_ON = st.tabOn or { 0.290, 0.140, 0.510, 1 }
    local TAB_OFF = st.tabOff or { 0.078, 0.035, 0.137, 1 }
    local TAB_HOVER = st.tabHover or { 0.380, 0.180, 0.620, 1 }
    local Col = ImGuiCol or _G.ImGuiCol
    local function famBtn(id, label)
        local on = st.family == id
        local pushed = 0
        if Col and Col.Button then
            local fill = on and TAB_ON or TAB_OFF
            if pcall(ImGui.PushStyleColor, Col.Button, fill[1], fill[2], fill[3], fill[4]) then
                pushed = pushed + 1
            end
            if Col.ButtonHovered
                and pcall(ImGui.PushStyleColor, Col.ButtonHovered, TAB_HOVER[1], TAB_HOVER[2], TAB_HOVER[3], TAB_HOVER[4]) then
                pushed = pushed + 1
            end
        end
        if ImGui.Button(label .. '##vfAugFam' .. id, 64, 22) then
            if st.family ~= id then
                st.family = id
                st.flavor = nil
            end
        end
        if pushed > 0 then pcall(ImGui.PopStyleColor, pushed) end
        ImGui.SameLine()
    end
    famBtn('kera', 'Kera')
    famBtn('seru', 'Seru')
    famBtn('zeb', 'Zeb')
    ImGui.NewLine()
    local fam = M.FAMILIES[st.family]
    if not fam then return end
    local tally = M.tallyRows(st.rows, st.family, st.includeWorn)
    local flags = 0
    pcall(function()
        flags = bitbor(
            ImGuiTableFlags.Borders or 0,
            ImGuiTableFlags.RowBg or 0,
            ImGuiTableFlags.ScrollY or 0,
            ImGuiTableFlags.SizingFixedFit or 0)
    end)
    if flags == 0 then flags = 1 end
    local tblH = 280
    pcall(function()
        local ax, ay = ImGui.GetContentRegionAvail()
        if type(ax) == 'number' then tblH = (ay or 0) - 52 end
    end)
    if tblH < 120 then tblH = 120 end
    if ImGui.BeginTable('vfAugShop', 6, flags, 0, tblH) then
        ImGui.TableSetupColumn('Flavor', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('B', ImGuiTableColumnFlags.WidthFixed, 22)
        ImGui.TableSetupColumn('E', ImGuiTableColumnFlags.WidthFixed, 22)
        ImGui.TableSetupColumn('L', ImGuiTableColumnFlags.WidthFixed, 22)
        ImGui.TableSetupColumn('W', ImGuiTableColumnFlags.WidthFixed, 22)
        ImGui.TableSetupColumn('##st', ImGuiTableColumnFlags.WidthFixed, 40)
        pcall(function() ImGui.TableSetupScrollFreeze(0, 1) end)
        ImGui.TableNextRow()
        ImGui.TableNextColumn(); ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Flavor')
        ImGui.TableNextColumn(); ImGui.TextColored(BASE[1], BASE[2], BASE[3], BASE[4], 'B')
        ImGui.TableNextColumn(); ImGui.TextColored(ENCH[1], ENCH[2], ENCH[3], ENCH[4], 'E')
        ImGui.TableNextColumn(); ImGui.TextColored(LEG[1], LEG[2], LEG[3], LEG[4], 'L')
        ImGui.TableNextColumn(); ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'W')
        ImGui.TableNextColumn(); ImGui.Dummy(1, 1)
        local function countText(n, col)
            n = tonumber(n) or 0
            if n > 0 then
                ImGui.TextColored(col[1], col[2], col[3], col[4], tostring(n))
            else
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], '0')
            end
        end
        for _, fl in ipairs(fam.flavors) do
            local slot = tally.flavors[fl] or {
                base = 0, enchanted = 0, legendary = 0, worn = 0, wornLegendary = 0,
            }
            local b, e, l = slot.base or 0, slot.enchanted or 0, slot.legendary or 0
            local w = slot.worn or 0
            local questL = l
            if st.includeWorn then questL = questL + (slot.wornLegendary or 0) end
            local sel = st.flavor == fl
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            if ImGui.Selectable(fl .. '##vfAugFl', sel, ImGuiSelectableFlags and ImGuiSelectableFlags.SpanAllColumns or 0) then
                st.flavor = (st.flavor == fl) and nil or fl
            end
            ImGui.TableNextColumn(); countText(b, BASE)
            ImGui.TableNextColumn(); countText(e, ENCH)
            ImGui.TableNextColumn(); countText(questL, LEG)
            ImGui.TableNextColumn()
            if w >= 1 then
                ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4], tostring(w))
            else
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], '0')
            end
            ImGui.TableNextColumn()
            local line = M.statusLine(b, e, questL, st.xlMath)
            if line == 'ready combine' then
                line = 'ready'
            elseif line == 'ready XL' then
                line = 'XL'
            else
                local n = line:match('^need (%d+)')
                if n then line = n end
            end
            if line == 'done' then
                ImGui.TextColored(LEG[1], LEG[2], LEG[3], LEG[4], line)
            elseif line == 'ready' or line == 'XL' then
                ImGui.TextColored(READY[1], READY[2], READY[3], READY[4], line)
            else
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], line)
            end
        end
        ImGui.EndTable()
    end
    local extras, foot = M.extraLines(tally, st.family)
    ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], foot)
    if st.flavor then
        local n4 = M.countCombiner(st.rows, 'quad')
        local n16 = M.countCombiner(st.rows, 'xl')
        local c4 = (n4 > 0) and READY or MUTED
        local c16 = (n16 > 0) and READY or MUTED
        ImGui.TextColored(c4[1], c4[2], c4[3], c4[4],
            string.format('Combinerator  %d', n4))
        ImGui.TextColored(c16[1], c16[2], c16[3], c16[4],
            string.format('XL Combinerator  %d', n16))
    end
    for _, line in ipairs(extras) do
        ImGui.TextWrapped(line)
    end
end

function M.emptyTally(familyId)
    local fam = M.FAMILIES[familyId]
    local out = { flavors = {}, extras = {}, done = 0, goal = fam and fam.goal or 0 }
    if not fam then return out end
    for _, fl in ipairs(fam.flavors) do
        out.flavors[fl] = { base = 0, enchanted = 0, legendary = 0, worn = 0, wornLegendary = 0 }
    end
    for _, ex in ipairs(fam.extras or {}) do
        out.extras[ex] = 0
    end
    return out
end

function M.addToTally(tally, info, qty, worn)
    if not tally or not info then return end
    qty = tonumber(qty) or 1
    if info.extra then
        tally.extras[info.extra] = (tally.extras[info.extra] or 0) + qty
        return
    end
    local slot = tally.flavors[info.flavor]
    if not slot then return end
    if worn then
        slot.worn = (slot.worn or 0) + qty
        local key = info.tier or 'base'
        if key ~= 'base' and key ~= 'enchanted' and key ~= 'legendary' then key = 'base' end
        if key == 'legendary' then
            slot.wornLegendary = (slot.wornLegendary or 0) + qty
        end
        return
    end
    local key = info.tier or 'base'
    if key ~= 'base' and key ~= 'enchanted' and key ~= 'legendary' then key = 'base' end
    slot[key] = (slot[key] or 0) + qty
end

function M.finishTally(tally, includeWorn)
    if not tally then return tally end
    tally.done = 0
    for _, slot in pairs(tally.flavors) do
        local l = slot.legendary or 0
        if includeWorn then l = l + (slot.wornLegendary or 0) end
        if l >= 1 then tally.done = tally.done + 1 end
    end
    return tally
end

function M.tallyRows(rows, familyId, includeWorn)
    local tally = M.emptyTally(familyId)
    for _, row in ipairs(rows or {}) do
        if not row.empty then
            local info = M.classify(row.name)
            if info and info.family == familyId then
                local worn = (row.where == 'worn')
                if worn and not includeWorn then
                    -- VF: still record worn; finishTally decides if it counts as done.
                    M.addToTally(tally, info, row.qty, true)
                else
                    M.addToTally(tally, info, row.qty, worn)
                end
            end
        end
    end
    return M.finishTally(tally, includeWorn)
end

function M.neededBankNames(rows, familyId, includeWorn)
    local tally = M.tallyRows(rows, familyId, includeWorn)
    local fam = M.FAMILIES[familyId]
    local names = {}
    local seen = {}
    if not fam then return names end
    for _, fl in ipairs(fam.flavors) do
        local slot = tally.flavors[fl]
        local l = slot.legendary or 0
        if includeWorn then l = l + (slot.wornLegendary or 0) end
        if l < 1 then
            local stem
            if fam.prefix then
                stem = fam.prefix .. fl
            else
                stem = fl .. (fam.suffix or '')
            end
            for _, suf in ipairs({ '', ' (Enchanted)', ' (Legendary)' }) do
                seen[stem .. suf] = true
            end
        end
    end
    for _, row in ipairs(rows or {}) do
        if not row.empty and row.where == 'bank' and seen[row.name] then
            names[#names + 1] = row.name
        end
    end
    table.sort(names)
    local uniq, last = {}, nil
    for _, n in ipairs(names) do
        if n ~= last then uniq[#uniq + 1] = n; last = n end
    end
    return uniq
end

function M.bagFamilyNames(rows, familyId, flavor)
    local names, seen = {}, {}
    for _, row in ipairs(rows or {}) do
        if not row.empty and row.where == 'bags' and M.inFamily(row.name, familyId, flavor) then
            local n = row.name
            if n and n ~= '' and not seen[n] then
                seen[n] = true
                names[#names + 1] = n
            end
        end
    end
    table.sort(names)
    return names
end

function M.scanWorn(pushRow)
    if not mq or not pushRow then return end
    for _, slot in ipairs(WORN_SLOTS) do
        local item
        pcall(function() item = mq.TLO.Me.Inventory(slot) end)
        if item and item() then
            for n = 1, 6 do
                local name, id, icon
                pcall(function()
                    local a = item.AugSlot(n)
                    if not a then return end
                    local empty = true
                    pcall(function() empty = not not a.Empty() end)
                    if empty then return end
                    name = trim(a.Name() or '')
                    if name == '' or name == 'NULL' then
                        local it = a.Item
                        if it and it() then name = trim(it.Name() or '') end
                    end
                    if a.Item and a.Item() then
                        id = tonumber(a.Item.ID()) or 0
                        icon = tonumber(a.Item.Icon()) or 0
                    end
                end)
                if name and name ~= '' and name ~= 'NULL' and M.classify(name) then
                    pushRow({
                        name = name,
                        qty = 1,
                        pack = 0,
                        slot = n,
                        bank = 0,
                        id = id or 0,
                        icon = icon or 0,
                        value = 0,
                        price = 'worn',
                        where = 'worn',
                        loc = M.wornLoc(slot, n),
                        worn = true,
                    })
                end
            end
        end
    end
end

function M.inFamily(name, familyId, flavor)
    local info = M.classify(name)
    if not info or info.family ~= familyId then return false end
    if flavor and info.flavor ~= flavor then return false end
    return true
end

-- VF: Flavor drill-down lists both combiners (Push/Pull stay flavor-only).
function M.listMatch(name, familyId, flavor)
    if flavor and M.combinerKind(name) then return true end
    return M.inFamily(name, familyId, flavor)
end

M.COMBINE_PACK = 10
M.NUM_PACKS = 10

-- VF: This emu is 10 pack slots; 12 produced Invalid item slot pack11.
function M.livePackCount(hint)
    local n = tonumber(hint) or M.NUM_PACKS
    if mq then
        pcall(function()
            local v = tonumber(mq.TLO.Me.NumBagSlots())
            if v and v > 0 then n = v end
        end)
    end
    return n
end

function M.packInfo(pack)
    pack = tonumber(pack) or M.COMBINE_PACK
    local out = { pack = pack, empty = true, size = 0, filled = 0, name = '', id = 0 }
    if not mq then return out end
    local bag
    pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
    if not (bag and bag()) then return out end
    out.empty = false
    pcall(function()
        out.name = trim(bag.Name() or '')
        out.id = tonumber(bag.ID()) or 0
        out.size = tonumber(bag.Container()) or 0
        out.filled = tonumber(bag.Items()) or 0
    end)
    if out.size > 0 then
        local n = 0
        for s = 1, out.size do
            local it
            pcall(function() it = bag.Item(s) end)
            if it and it() then n = n + 1 end
        end
        out.filled = n
    end
    return out
end

function M.freeSlotsExcept(skipPack, numPacks)
    skipPack = tonumber(skipPack) or 0
    numPacks = M.livePackCount(numPacks)
    local free = 0
    if not mq then return 0 end
    for pack = 1, numPacks do
        if pack ~= skipPack then
            local bag
            pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
            if bag and bag() then
                local size = tonumber(bag.Container()) or 0
                for s = 1, size do
                    local it
                    pcall(function() it = bag.Item(s) end)
                    if not (it and it()) then free = free + 1 end
                end
            end
        end
    end
    return free
end

function M.emptyPackSlot(skipPack, numPacks)
    skipPack = tonumber(skipPack) or 0
    numPacks = M.livePackCount(numPacks)
    if not mq then return nil end
    for pack = 1, numPacks do
        if pack ~= skipPack then
            local bag
            pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
            if not (bag and bag()) then return pack end
        end
    end
    return nil
end

function M.findXl(numPacks)
    return M.findCombiner('xl', numPacks)
end

function M.findCombiner(kind, numPacks)
    numPacks = M.livePackCount(numPacks)
    if not mq or not kind then return nil end
    for pack = 1, numPacks do
        local bag
        pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
        if bag and bag() then
            local bname, bid = '', 0
            pcall(function()
                bname = trim(bag.Name() or '')
                bid = tonumber(bag.ID()) or 0
            end)
            if M.combinerKind(bname, bid) == kind then
                return { pack = pack, slot = 0, id = bid, name = bname }
            end
            local size = tonumber(bag.Container()) or 0
            for slot = 1, size do
                local n, iid = '', 0
                pcall(function()
                    local it = bag.Item(slot)
                    if it and it() then
                        n = trim(it.Name() or '')
                        iid = tonumber(it.ID()) or 0
                    end
                end)
                if n ~= '' and M.combinerKind(n, iid) == kind then
                    return { pack = pack, slot = slot, id = iid, name = n }
                end
            end
        end
    end
    return nil
end

function M.findNamed(name, id, numPacks)
    name = trim(name or '')
    id = tonumber(id) or 0
    numPacks = M.livePackCount(numPacks)
    if not mq or name == '' then return nil end
    for pack = 1, numPacks do
        local bag
        pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
        if bag and bag() then
            local bname, bid = '', 0
            pcall(function()
                bname = trim(bag.Name() or '')
                bid = tonumber(bag.ID()) or 0
            end)
            if bname == name or (id > 0 and bid == id) then
                return { pack = pack, slot = 0, id = bid, name = bname }
            end
            local size = tonumber(bag.Container()) or 0
            for slot = 1, size do
                local n, iid = '', 0
                pcall(function()
                    local it = bag.Item(slot)
                    if it and it() then
                        n = trim(it.Name() or '')
                        iid = tonumber(it.ID()) or 0
                    end
                end)
                if n == name or (id > 0 and iid == id) then
                    return { pack = pack, slot = slot, id = iid, name = n }
                end
            end
        end
    end
    return nil
end

-- VF: Close PackN so a left-click on the bag slot picks the bag, not the window.
local function closePackWindow(pack)
    local isOpen = false
    pcall(function() isOpen = not not mq.TLO.Window('Pack' .. pack).Open() end)
    if not isOpen then return end
    mq.cmdf('/nomodkey /itemnotify pack%d rightmouseup', pack)
    mq.delay(200)
end

local function notifyLoc(h, loc)
    if not loc then return end
    if (tonumber(loc.slot) or 0) > 0 then
        if h.ensurePackOpen then h.ensurePackOpen(loc.pack) end
        mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', loc.pack, loc.slot)
    else
        closePackWindow(loc.pack)
        mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', loc.pack)
    end
    if h.acceptQty then h.acceptQty() end
end

local function cursorOn()
    return (mq.TLO.Cursor.ID() or 0) > 0
end

local function dropInOtherBag(h, skipPack, nPacks)
    if not cursorOn() then return false end
    local destPack, destSlot = M.firstInnerSlot(skipPack, nPacks)
    if not destPack then return false end
    if h.ensurePackOpen then h.ensurePackOpen(destPack) end
    mq.delay(40)
    mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', destPack, destSlot)
    if h.waitCursor(false, 800) or not cursorOn() then
        return true, destPack, destSlot
    end
    return false
end

local function autoinvOffCursor(h, skipPack)
    mq.cmd('/autoinventory')
    mq.delay(80)
    if h.acceptQty then h.acceptQty() end
    if h.waitCursor(false, 800) then return true end
    if dropInOtherBag(h, skipPack, M.livePackCount(h and h.numPacks)) then return true end
    if h.dropBags then h.dropBags(skipPack) end
    return h.waitCursor(false, 800) or not cursorOn()
end

-- VF: Pickup one inside-pack slot; shift first, then plain click.
local function pickupInside(h, pack, slot)
    if cursorOn() then autoinvOffCursor(h, pack) end
    if h.ensurePackOpen then h.ensurePackOpen(pack) end
    mq.delay(80)
    mq.cmdf('/nomodkey /shiftkey /itemnotify in pack%d %d leftmouseup', pack, slot)
    mq.delay(80)
    if h.acceptQty then h.acceptQty() end
    if h.waitCursor(true, 700) then return true end
    mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', pack, slot)
    mq.delay(80)
    if h.acceptQty then h.acceptQty() end
    if h.waitCursor(true, 700) then return true end
    mq.cmdf('/nomodkey /shiftkey /itemnotify pack%d %d leftmouseup', pack, slot)
    mq.delay(80)
    if h.acceptQty then h.acceptQty() end
    return h.waitCursor(true, 700)
end

-- VF: Shift-click, then FindItem by name. Plain itemnotify often fails with Pack10 open.
local function pickLoc(h, loc, name, skipPack)
    name = trim(name or (loc and loc.name) or '')
    skipPack = tonumber(skipPack) or 0
    if loc then
        local cname = ''
        if cursorOn() then
            pcall(function() cname = trim(mq.TLO.Cursor.Name() or '') end)
            if name ~= '' and cname == name then return true end
            autoinvOffCursor(h, loc.pack)
        end
        local slot = tonumber(loc.slot) or 0
        if slot > 0 then
            if pickupInside(h, loc.pack, slot) then return true end
        else
            notifyLoc(h, loc)
            if h.waitCursor(true, 800) then return true end
        end
    elseif cursorOn() then
        local cname = ''
        pcall(function() cname = trim(mq.TLO.Cursor.Name() or '') end)
        if name ~= '' and cname == name then return true end
    end
    if name == '' or not mq then return false end
    local fi
    pcall(function() fi = mq.TLO.FindItem('=' .. name) end)
    if not (fi and fi()) then
        pcall(function() fi = mq.TLO.FindItem(name) end)
    end
    local islot, slot2
    pcall(function()
        if fi and fi() then
            islot = tonumber(fi.ItemSlot())
            slot2 = tonumber(fi.ItemSlot2())
        end
    end)
    if islot and islot >= 23 and slot2 ~= nil and slot2 >= 0 then
        local p = islot - 22
        if p ~= skipPack and pickupInside(h, p, slot2 + 1) then return true end
    elseif islot and islot > 0 then
        mq.cmdf('/nomodkey /shiftkey /itemnotify %d leftmouseup', islot)
        mq.delay(80)
        if h.acceptQty then h.acceptQty() end
        if h.waitCursor(true, 800) then return true end
    end
    if skipPack > 0 then return false end
    local safe = name:gsub('"', '')
    mq.cmdf('/nomodkey /shiftkey /itemnotify "%s" leftmouseup', safe)
    mq.delay(80)
    if h.acceptQty then h.acceptQty() end
    return h.waitCursor(true, 800)
end

local function firstFilledSlot(pack, keepName)
    keepName = trim(keepName or '')
    local bag
    pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
    if not (bag and bag()) then return nil end
    local size = tonumber(bag.Container()) or 0
    for s = 1, size do
        local it, n = nil, ''
        pcall(function()
            it = bag.Item(s)
            if it and it() then n = trim(it.Name() or '') end
        end)
        if it and it() and (keepName == '' or n ~= keepName) then return s end
    end
    return nil
end

local function countNamedInPack(pack, name)
    name = trim(name or '')
    if name == '' then return 0 end
    local n = 0
    local bag
    pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
    if not (bag and bag()) then return 0 end
    local size = tonumber(bag.Container()) or 0
    for s = 1, size do
        local iname = ''
        pcall(function()
            local it = bag.Item(s)
            if it and it() then iname = trim(it.Name() or '') end
        end)
        if iname == name then n = n + 1 end
    end
    return n
end

-- VF: For each item in pack10: pickup, /autoinventory. keepName stays (fodder already loaded).
local function explodePack(h, pack, keepName)
    local info = M.packInfo(pack)
    if info.empty then return true end
    if (info.size or 0) <= 0 then return true end
    if not firstFilledSlot(pack, keepName) then return true end
    if h.status then h.status('emptying pack' .. pack .. '...') end
    if h.ensurePackOpen then h.ensurePackOpen(pack) end
    local nPacks = M.livePackCount(h and h.numPacks)
    for _ = 1, 80 do
        local slot = firstFilledSlot(pack, keepName)
        if not slot then return true end
        if not pickupInside(h, pack, slot) then
            mq.delay(120)
            if firstFilledSlot(pack, keepName) ~= slot then
                -- VF: TLO was stale; slot already empty.
            else
                return false, 'could not empty pack' .. pack
            end
        else
            mq.cmd('/autoinventory')
            mq.delay(80)
            if h.acceptQty then h.acceptQty() end
            h.waitCursor(false, 800)
            mq.delay(80)
            if firstFilledSlot(pack, keepName) == slot then
                if not pickupInside(h, pack, slot) then
                    return false, 'could not empty pack' .. pack
                end
                if not dropInOtherBag(h, pack, nPacks) then
                    return false, 'bags full emptying pack' .. pack
                end
            end
        end
    end
    return firstFilledSlot(pack, keepName) == nil, 'could not empty pack' .. pack
end

function M.firstInnerSlot(skipPack, numPacks)
    skipPack = tonumber(skipPack) or 0
    numPacks = M.livePackCount(numPacks)
    if not mq then return nil end
    for p = 1, numPacks do
        if p ~= skipPack then
            local bag
            pcall(function() bag = mq.TLO.Me.Inventory('pack' .. p) end)
            if bag and bag() then
                local size = tonumber(bag.Container()) or 0
                for s = 1, size do
                    local it
                    pcall(function() it = bag.Item(s) end)
                    if not (it and it()) then return p, s end
                end
            end
        end
    end
    return nil
end

local function packIsEmpty(pack)
    return M.packInfo(pack).empty
end

-- VF: Move pack10 itself into any empty slot of another bag.
local function parkPackBag(h, pack, job, nPacks)
    local info = M.packInfo(pack)
    if info.empty then return true end
    if h.status then h.status('parking pack' .. pack .. ' bag...') end
    if cursorOn() then autoinvOffCursor(h, pack) end
    closePackWindow(pack)
    mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', pack)
    mq.delay(80)
    if h.acceptQty then h.acceptQty() end
    if not h.waitCursor(true, 700) then
        return false, 'could not pick pack' .. pack .. ' bag'
    end
    if job then job.saved = { name = info.name, id = info.id } end
    local parked, destPack, destSlot = dropInOtherBag(h, pack, nPacks)
    mq.delay(80)
    if parked and packIsEmpty(pack) then
        if job and job.saved then
            job.saved.pack, job.saved.slot = destPack, destSlot
        end
        return true
    end
    local dest = M.emptyPackSlot(pack, nPacks)
    if dest then
        mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', dest)
        if h.waitCursor(false, 700) and packIsEmpty(pack) then
            if job and job.saved then
                job.saved.pack, job.saved.slot = dest, 0
            end
            return true
        end
    end
    -- VF: Leave the bag on the cursor so a combinator swap can use it.
    return false, 'could not park pack' .. pack .. ' bag'
end

-- VF: Swap pack10 with the combinator we are about to fill.
local function swapPackWithCombiner(h, pack, job, want, nPacks)
    local loc = M.findCombiner(want, nPacks)
    if not loc then return false, 'no combinator to swap' end
    if loc.pack == pack and (tonumber(loc.slot) or 0) == 0 then
        if job then job.saved = nil end
        return true
    end
    if h.status then h.status('swapping pack' .. pack .. ' with combinator...') end
    local info = M.packInfo(pack)
    if job then
        job.saved = job.saved or {}
        if (not job.saved.name or job.saved.name == '') and not info.empty then
            job.saved.name, job.saved.id = info.name, info.id
        end
        if cursorOn() and (not job.saved.name or job.saved.name == '') then
            pcall(function()
                job.saved.name = trim(mq.TLO.Cursor.Name() or '')
                job.saved.id = tonumber(mq.TLO.Cursor.ID()) or 0
            end)
        end
        job.saved.pack, job.saved.slot = loc.pack, loc.slot
    end

    -- VF: Reseat a failed-park bag so we can pick the combinator, then swap.
    if cursorOn() and info.empty then
        mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', pack)
        mq.delay(80)
        h.waitCursor(false, 700)
        info = M.packInfo(pack)
    elseif cursorOn() then
        autoinvOffCursor(h, pack)
        info = M.packInfo(pack)
    end

    loc = M.findCombiner(want, nPacks)
    if not loc then return false, 'no combinator to swap' end
    if loc.pack == pack and (tonumber(loc.slot) or 0) == 0 then
        if job then job.saved = nil end
        return true
    end

    if cursorOn() then
        notifyLoc(h, loc)
        if not h.waitCursor(true, 800) then
            return false, 'could not swap pack' .. pack .. ' with combinator'
        end
        mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', pack)
        mq.delay(80)
        if h.acceptQty then h.acceptQty() end
        if not h.waitCursor(false, 800) then
            return false, 'could not seat combinator'
        end
        local seated = M.packInfo(pack)
        if M.combinerKind(seated.name, seated.id) ~= want then
            return false, 'could not swap pack' .. pack .. ' with combinator'
        end
        return true
    end

    notifyLoc(h, loc)
    if not h.waitCursor(true, 800) then
        return false, 'could not pick combinator to swap'
    end
    mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', pack)
    mq.delay(80)
    if h.acceptQty then h.acceptQty() end
    mq.delay(80)
    local seated = M.packInfo(pack)
    if M.combinerKind(seated.name, seated.id) ~= want then
        return false, 'could not swap pack' .. pack .. ' with combinator'
    end
    if cursorOn() then
        notifyLoc(h, loc)
        if not h.waitCursor(false, 700) then
            autoinvOffCursor(h, pack)
        end
    end
    return true
end

-- VF: Empty pack10, seat XL, fill 16 base, combine, bank, restore the bag.
function M.runCombine(job, h)
    if not mq or not h or not job then return false, 'no mq' end
    local pack = tonumber(job.pack) or M.COMBINE_PACK
    local nPacks = M.livePackCount(h and h.numPacks)
    if h.scan then h.scan(true) end
    local rows = h.rows and h.rows() or job.rows
    local plan, err = M.xlPlan(rows, job.family, job.flavor)
    if not plan then return false, err or 'no plan' end

    if (mq.TLO.Cursor.ID() or 0) > 0 then
        mq.cmd('/autoinventory')
        h.waitCursor(false, 400)
    end

    if plan.bags < plan.need then
        if h.status then h.status('pulling base from bank...') end
        if h.moveAllNamed then h.moveAllNamed(false, plan.fodder) end
        if h.scan then h.scan(true) end
        rows = h.rows and h.rows() or rows
        plan, err = M.xlPlan(rows, job.family, job.flavor)
        if not plan or plan.bags < plan.need then
            return false, 'not enough in bags'
        end
    end

    local want = plan.combiner or 'xl'
    local wantLabel = (want == 'xl') and 'XL Combinerator' or 'Gnomish Combinerator'
    local function isWanted(name, id)
        return M.combinerKind(name, id) == want
    end

    local info = M.packInfo(pack)
    -- VF: Pack10 already a combinator with enough slots — keep it (XL can also do 4).
    if not info.empty and M.combinerKind(info.name, info.id) and (info.size or 0) >= plan.need then
        job.saved = nil
        if h.status then h.status('using combinator in pack' .. pack) end
        local okKeep, keepErr = explodePack(h, pack, plan.fodder)
        if not okKeep then return false, keepErr end
        info = M.packInfo(pack)
    else
        if not M.findCombiner(want, nPacks) then
            local pullName = plan.combinerName
            for _, row in ipairs(rows or {}) do
                if not row.empty and row.where == 'bank' and M.combinerKind(row.name, row.id) == want then
                    pullName = row.name
                    break
                end
            end
            if pullName and h.moveAllNamed then
                if h.status then h.status('pulling ' .. wantLabel .. '...') end
                h.moveAllNamed(false, pullName)
            end
            if not M.findCombiner(want, nPacks) then return false, 'no ' .. wantLabel end
        end

        local okEmpty, emptyErr = explodePack(h, pack)
        if not okEmpty then return false, emptyErr end
        info = M.packInfo(pack)
        if not info.empty and not isWanted(info.name, info.id) then
            local okPark = parkPackBag(h, pack, job, nPacks)
            if not okPark then
                local okSwap, swapErr = swapPackWithCombiner(h, pack, job, want, nPacks)
                if not okSwap then return false, swapErr end
            end
            info = M.packInfo(pack)
        elseif not info.empty and isWanted(info.name, info.id) then
            job.saved = nil
        end

        if info.empty then
            if h.status then h.status('seating ' .. wantLabel .. '...') end
            local loc = M.findCombiner(want, nPacks)
            if not loc then return false, 'no ' .. wantLabel end
            if loc.pack == pack and (tonumber(loc.slot) or 0) == 0 then
                -- already seated
            else
                if not pickLoc(h, loc, loc.name or wantLabel) then
                    return false, 'could not pick ' .. wantLabel
                end
                mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', pack)
                if not h.waitCursor(false, 600) then return false, 'could not seat ' .. wantLabel end
            end
            info = M.packInfo(pack)
        end
    end
    if not M.combinerKind(info.name, info.id) then
        return false, 'pack' .. pack .. ' is not a combinator'
    end
    if info.size < plan.need then
        return false, string.format('combinator has %d slots, need %d', info.size, plan.need)
    end

    local have = countNamedInPack(pack, plan.fodder)
    local need = plan.need - have
    if need < 0 then need = 0 end
    if need > 0 then
        if h.status then h.status('filling combinator...') end
        for _ = 1, need do
            local loc = h.findFodder and h.findFodder(plan.fodder, pack)
            if not loc then return false, 'not enough ' .. plan.fodder end
            closePackWindow(pack)
            if not pickLoc(h, loc, plan.fodder, pack) then
                return false, 'could not pick ' .. plan.fodder
            end
            if h.ensurePackOpen then h.ensurePackOpen(pack) end
            local placed = false
            local bag
            pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
            local size = 0
            pcall(function() size = tonumber(bag.Container()) or 0 end)
            for s = 1, size do
                local it
                pcall(function() it = bag.Item(s) end)
                if not (it and it()) then
                    mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', pack, s)
                    if h.waitCursor(false, 500) then placed = true; break end
                end
            end
            if not placed then return false, 'could not fill combinator' end
            mq.delay(40)
        end
    end

    if h.status then h.status('combining...') end
    if h.ensurePackOpen then h.ensurePackOpen(pack) end
    local before = 0
    pcall(function()
        before = tonumber(mq.TLO.FindItemCount('=' .. plan.result)()) or 0
    end)
    mq.cmdf('/combine pack%d', pack)
    local deadline = os.clock() + 8
    local got = false
    while os.clock() < deadline do
        mq.delay(100)
        local cname = ''
        pcall(function() cname = trim(mq.TLO.Cursor.Name() or '') end)
        if cname == plan.result then got = true; break end
        local n = 0
        pcall(function() n = tonumber(mq.TLO.FindItemCount('=' .. plan.result)()) or 0 end)
        if n > before then got = true; break end
    end
    if not got then return false, 'combine failed' end

    if h.status then h.status('banking ' .. plan.result .. '...') end
    if h.beginBankLease then h.beginBankLease() end
    if h.ensureBankReady and not h.ensureBankReady() then
        return false, 'Bank window not open'
    end
    local cname = ''
    pcall(function() cname = trim(mq.TLO.Cursor.Name() or '') end)
    if cname ~= plan.result then
        info = M.packInfo(pack)
        local bag
        pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
        for s = 1, (info.size or 0) do
            local n = ''
            pcall(function()
                local it = bag.Item(s)
                if it and it() then n = trim(it.Name() or '') end
            end)
            if n == plan.result then
                mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', pack, s)
                if h.acceptQty then h.acceptQty() end
                h.waitCursor(true, 450)
                break
            end
        end
        pcall(function() cname = trim(mq.TLO.Cursor.Name() or '') end)
    end
    if cname == plan.result then
        if h.dropBank then h.dropBank() end
        h.waitCursor(false, 800)
    end
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        mq.cmd('/autoinventory')
        h.waitCursor(false, 400)
    end

    info = M.packInfo(pack)
    if not info.empty and M.combinerKind(info.name, info.id) then
        local okHusk, huskErr = parkPackBag(h, pack, nil, nPacks)
        if not okHusk then return false, huskErr or 'could not park combiner' end
    end

    if job.saved and job.saved.name and job.saved.name ~= '' then
        if h.status then h.status('restoring pack' .. pack .. '...') end
        local loc = M.findNamed(job.saved.name, job.saved.id, nPacks)
        if not loc then return false, 'combined, but missing original bag' end
        if not pickLoc(h, loc, job.saved.name) then return false, 'could not pick original bag' end
        mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', pack)
        if not h.waitCursor(false, 600) then return false, 'could not restore pack' .. pack end
    end

    return true, 'combined ' .. plan.result
end

return M
