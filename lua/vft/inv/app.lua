---@diagnostic disable: undefined-global, undefined-field
-- VF: Inventory UI — entry is /lua run vft/inv (module alone is not a runner).

local mq = require('mq')
local ImGui = require('ImGui')
local brand = require('vft.brand')
local chat = require('vft.chat')
local invLocks = require('vft.inv.locks')
local powerSrc = require('vft.powersource')

local NUM_PACKS = 12
local SCAN_SEC = 0.25
local ICON_SIZE = 20
local ICON_OFFSET = 500
local BANK_WAIT = 5.0

-- VF: Lilac / jade / brand purple (Veilfall.cc text). Tab fills match mgr.
local MUTED = { 0.541, 0.439, 0.533, 1 }
local GOOD = { 0.37, 0.88, 0.64, 1 }
local BRAND = { 0.710, 0.420, 1.000, 1 }

local TAB_ON = { 0.290, 0.140, 0.510, 1 }
local TAB_OFF = { 0.078, 0.035, 0.137, 1 }
local TAB_HOVER = { 0.380, 0.180, 0.620, 1 }
local theme = { colN = 0, varN = 0 }

-- VF: Sortable bag table column ids (UserID).
local BAG_COL_ITEM, BAG_COL_QTY, BAG_COL_PRICE, BAG_COL_LOCK = 0, 1, 2, 3

local function bagSortCmp(a, b, sort_specs)
    local function cmpStr(x, y)
        x, y = tostring(x or ''):lower(), tostring(y or ''):lower()
        if x < y then return -1 end
        if x > y then return 1 end
        return 0
    end
    local function cmpNum(x, y)
        x, y = tonumber(x) or 0, tonumber(y) or 0
        if x < y then return -1 end
        if x > y then return 1 end
        return 0
    end
    if a.empty and not b.empty then return false end
    if b.empty and not a.empty then return true end
    local count = tonumber(sort_specs.SpecsCount) or 0
    for n = 1, count do
        local spec = nil
        pcall(function()
            if sort_specs.Specs then spec = sort_specs:Specs(n) end
        end)
        if not spec then
            pcall(function() spec = sort_specs.Specs[n] end)
        end
        if spec then
            local col = tonumber(spec.ColumnUserID) or -1
            local delta = 0
            if col == BAG_COL_ITEM then
                delta = cmpStr(a.name, b.name)
            elseif col == BAG_COL_QTY then
                delta = cmpNum(a.qty, b.qty)
            elseif col == BAG_COL_PRICE then
                delta = cmpNum(a.value, b.value)
            elseif col == BAG_COL_LOCK then
                delta = cmpNum(a.locked and 1 or 0, b.locked and 1 or 0)
            end
            if delta ~= 0 then
                local asc = true
                pcall(function()
                    local dir = spec.SortDirection
                    local Asc = ImGuiSortDirection and ImGuiSortDirection.Ascending
                    if Asc ~= nil then asc = (dir == Asc) else asc = (tonumber(dir) or 1) == 1 end
                end)
                if asc then return delta < 0 end
                return delta > 0
            end
        end
    end
    return (a.name or '') < (b.name or '')
end

local function bitbor(...)
    if bit and bit.bor then return bit.bor(...) end
    local acc = 0
    for i = 1, select('#', ...) do acc = acc + (select(i, ...) or 0) end
    return acc
end

local function pushCol(id, r, g, b, a)
    if id == nil then return end
    if pcall(ImGui.PushStyleColor, id, r, g, b, a) then
        theme.colN = theme.colN + 1
    end
end

local function pushVar(id, a, b)
    if id == nil then return end
    local ok
    if b ~= nil then
        local ImVec2Type = _G.ImVec2 or ImVec2
        if type(ImVec2Type) == 'function' then
            ok = pcall(ImGui.PushStyleVar, id, ImVec2Type(a, b))
        else
            ok = pcall(ImGui.PushStyleVar, id, a, b)
        end
    else
        ok = pcall(ImGui.PushStyleVar, id, a)
    end
    if ok then theme.varN = theme.varN + 1 end
end

local function pushTheme()
    theme.colN, theme.varN = 0, 0
    local Col = ImGuiCol or _G.ImGuiCol
    local SV = ImGuiStyleVar or _G.ImGuiStyleVar
    if Col then
        pushCol(Col.WindowBg, 0.031, 0.016, 0.055, 0.98)
        pushCol(Col.ChildBg, 0.045, 0.020, 0.080, 1)
        pushCol(Col.PopupBg, 0.031, 0.016, 0.047, 1)
        pushCol(Col.Border, 0.275, 0.125, 0.490, 1)
        pushCol(Col.Text, 0.910, 0.863, 0.784, 1)
        pushCol(Col.TextDisabled, 0.500, 0.400, 0.620, 1)
        pushCol(Col.TitleBg, 0.055, 0.027, 0.102, 1)
        pushCol(Col.TitleBgActive, 0.078, 0.035, 0.137, 1)
        pushCol(Col.FrameBg, 0.055, 0.027, 0.102, 1)
        pushCol(Col.FrameBgHovered, 0.145, 0.055, 0.235, 1)
        pushCol(Col.FrameBgActive, 0.200, 0.078, 0.310, 1)
        pushCol(Col.Button, TAB_ON[1], TAB_ON[2], TAB_ON[3], TAB_ON[4])
        pushCol(Col.ButtonHovered, TAB_HOVER[1], TAB_HOVER[2], TAB_HOVER[3], TAB_HOVER[4])
        pushCol(Col.ButtonActive, 0.450, 0.220, 0.720, 1)
        pushCol(Col.Header, 0.078, 0.035, 0.137, 1)
        pushCol(Col.HeaderHovered, TAB_HOVER[1], TAB_HOVER[2], TAB_HOVER[3], 0.85)
        pushCol(Col.HeaderActive, TAB_ON[1], TAB_ON[2], TAB_ON[3], TAB_ON[4])
        pushCol(Col.CheckMark, 0.710, 0.420, 1.000, 1)
        pushCol(Col.Separator, 0.275, 0.125, 0.490, 1)
        pushCol(Col.ScrollbarBg, 0.031, 0.016, 0.047, 1)
        pushCol(Col.ScrollbarGrab, 0.275, 0.125, 0.490, 1)
        pushCol(Col.TableHeaderBg, 0.078, 0.035, 0.137, 1)
        pushCol(Col.TableRowBg, 0.031, 0.016, 0.055, 0.35)
        pushCol(Col.TableRowBgAlt, 0.055, 0.027, 0.102, 0.45)
        pushCol(Col.TableBorderStrong, 0.275, 0.125, 0.490, 1)
        pushCol(Col.TableBorderLight, 0.200, 0.078, 0.310, 1)
    end
    if SV then
        pushVar(SV.WindowRounding, 6)
        pushVar(SV.ChildRounding, 5)
        pushVar(SV.FrameRounding, 4)
        pushVar(SV.FrameBorderSize, 1)
        pushVar(SV.FramePadding, 7, 4)
        pushVar(SV.ItemSpacing, 8, 6)
        pushVar(SV.WindowPadding, 12, 10)
        pushVar(SV.ScrollbarRounding, 6)
    end
end

local function popTheme()
    if theme.varN > 0 then
        pcall(ImGui.PopStyleVar, theme.varN)
        theme.varN = 0
    end
    if theme.colN > 0 then
        pcall(ImGui.PopStyleColor, theme.colN)
        theme.colN = 0
    end
end

-- VF: Shared string trim (must precede scrollInfo).
local function trim(s)
    return tostring(s or ''):match('^%s*(.-)%s*$') or ''
end

-- VF: Teachables by name - Spell:/Song:/Scroll:/Tome: prefixes, plus "Tome of …" discs.
local function scrollInfo(item)
    local kind, teachName = nil, ''
    if not item then return nil, '' end
    pcall(function()
        if not item() then return end
        local name = trim(item.Name() or '')
        if name == '' or name == 'NULL' then return end

        local rest = name:match('^[Ss]pell:%s*(.+)$')
        if rest then
            kind = 'spell'
            teachName = trim(rest)
        else
            rest = name:match('^[Ss]ong:%s*(.+)$')
            if rest then
                kind = 'song'
                teachName = trim(rest)
            else
                rest = name:match('^[Ss]croll:%s*(.+)$')
                if rest then
                    -- VF: Scroll: may be spell or disc; refine with IsSkill / song cats below.
                    kind = 'spell'
                    teachName = trim(rest)
                else
                    rest = name:match('^[Tt]ome:%s*(.+)$')
                    if rest then
                        kind = 'disc'
                        teachName = trim(rest)
                    else
                        -- VF: Live-style names e.g. "Tome of Deflection Discipline".
                        rest = name:match('^[Tt]ome of%s+(.+)$')
                        if rest then
                            kind = 'disc'
                            teachName = trim(rest)
                        end
                    end
                end
            end
        end
        if not kind then return end

        -- VF: Scroll: (and Spell: that is actually a CA/song) - promote kind via TLO.
        if kind == 'spell' and teachName ~= '' then
            local isDisc = false
            pcall(function()
                local sp = (item.Spell and item.Spell()) and item.Spell or mq.TLO.Spell(teachName)
                if sp and sp() and sp.IsSkill and sp.IsSkill() then isDisc = true end
            end)
            if isDisc then
                kind = 'disc'
            else
                local isSong = false
                pcall(function()
                    local sp = (item.Spell and item.Spell()) and item.Spell or mq.TLO.Spell(teachName)
                    if not (sp and sp()) then return end
                    local cat = tostring(sp.Category() or ''):lower()
                    local sub = tostring(sp.Subcategory() or ''):lower()
                    local skill = tostring(sp.Skill() or ''):lower()
                    if cat:find('song', 1, true) or sub:find('song', 1, true)
                        or skill == 'singing' or skill == 'percussion instruments'
                        or skill == 'stringed instruments' or skill == 'wind instruments'
                        or skill == 'brass instruments' then
                        isSong = true
                    end
                end)
                if isSong then kind = 'song' end
            end
        end

        if teachName == 'NULL' then teachName = '' end
    end)
    return kind, teachName
end

-- VF: Already in spellbook (spells/songs) or combat abilities (discs).
local function alreadyInBook(spellName)
    if not spellName or spellName == '' then return false end
    local ok = false
    pcall(function()
        if mq.TLO.Me.Book(spellName)() then ok = true end
    end)
    return ok
end

local function alreadyHasDisc(discName)
    if not discName or discName == '' then return false end
    local ok = false
    pcall(function()
        if mq.TLO.Me.CombatAbility(discName)() then ok = true end
    end)
    return ok
end

local function alreadyKnown(kind, teachName)
    if kind == 'disc' then return alreadyHasDisc(teachName) end
    return alreadyInBook(teachName)
end

local function scribeLanded(kind, teachName)
    return alreadyKnown(kind, teachName)
end

local function scribeBlocked()
    local why
    pcall(function()
        if mq.TLO.Me.Combat() then
            why = 'in combat'
        elseif mq.TLO.Me.Moving() then
            why = 'moving'
        elseif mq.TLO.Me.Casting() then
            why = 'casting'
        end
    end)
    return why
end

local function closeSpellBook()
    pcall(function()
        if mq.TLO.Window('SpellBookWnd').Open() then
            mq.cmd('/windowstate SpellBookWnd close')
        end
    end)
end

local function fmtCoins(copper)
    copper = tonumber(copper) or 0
    if copper <= 0 then return '-' end
    local p = math.floor(copper / 1000)
    local g = math.floor((copper % 1000) / 100)
    local s = math.floor((copper % 100) / 10)
    local c = copper % 10
    local parts = {}
    if p > 0 then parts[#parts + 1] = p .. 'p' end
    if g > 0 then parts[#parts + 1] = g .. 'g' end
    if s > 0 then parts[#parts + 1] = s .. 's' end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. 'c' end
    return table.concat(parts, ' ')
end

-- VF: 1234567 â†’ 1,234,567
local function fmtNum(n)
    n = math.floor(tonumber(n) or 0)
    local neg = n < 0
    if neg then n = -n end
    local s = tostring(n)
    while true do
        local next, k = s:gsub('^(%d+)(%d%d%d)', '%1,%2')
        s = next
        if k == 0 then break end
    end
    return neg and ('-' .. s) or s
end

local function purseCoins()
    local p, g, s, c = 0, 0, 0, 0
    pcall(function()
        p = tonumber(mq.TLO.Me.Platinum()) or 0
        g = tonumber(mq.TLO.Me.Gold()) or 0
        s = tonumber(mq.TLO.Me.Silver()) or 0
        c = tonumber(mq.TLO.Me.Copper()) or 0
    end)
    return p, g, s, c
end

local function merchantOpen()
    local open = false
    pcall(function()
        open = not not mq.TLO.Window('MerchantWnd').Open()
        if not open and mq.TLO.Merchant and mq.TLO.Merchant.Open then
            open = not not mq.TLO.Merchant.Open()
        end
    end)
    return open
end

local function bankOpen()
    local open = false
    pcall(function()
        open = not not (mq.TLO.Window('BigBankWnd').Open() or mq.TLO.Window('BankWnd').Open())
    end)
    return open
end

local function rightClicked()
    local right = (ImGuiMouseButton and ImGuiMouseButton.Right) or 1
    if ImGui.IsItemClicked and ImGui.IsItemClicked(right) then return true end
    return ImGui.IsItemHovered() and ImGui.IsMouseClicked(right)
end

local function create(opts)
    opts = opts or {}
    local hosted = not not opts.hosted
    local openGUI = not hosted
    powerSrc.installEvents('VftInvPs')
    powerSrc.refresh()
    local filter = ''
    local showEmpty = false
    local showHelp = false
    local hideTooltips = false
    local turninConfirm = nil -- { names=..., target=... } while confirm popup is up
    -- VF: Bags | Bank
    local view = 'bags'
    local checked = {} -- checked[where][name] = true
    -- local bagTrace = false -- VF: re-enable Trace checkbox below when debugging sell/moves
    local locked = {} -- item id -> name; [Locked] in {server}_{char}_loadout.ini
    local lockPath = ''
    local locksDirty = false
    local lockSaveWarned = false
    local lastScan = 0
    local rows = {}
    local used, free, packs = 0, 0, 0
    local pending = nil
    local status = ''
    local bankWatchUntil = 0
    local massDestroyQ = {}
    local memQ = {}
    local memWaitUntil = 0
    local memExpect = nil
    local memDone, memSkip, memFail = 0, 0, 0
    local openedPacks = {}
    local ensurePackOpen -- VF: defined with scribe helpers; sell opens packs first.
    local animItems
    pcall(function() animItems = mq.FindTextureAnimation('A_DragItem') end)

    local function setTip(s)
        if hideTooltips or not s or s == '' then return end
        -- VF: MQ SetTooltip runs through format; escape % (e.g. power source 0%).
        ImGui.SetTooltip((tostring(s):gsub('%%', '%%%%')))
    end

    local function drawIcon(icon)
        if not animItems or not icon or icon <= 0 then
            ImGui.Dummy(ICON_SIZE, ICON_SIZE)
            return
        end
        local cell = icon - ICON_OFFSET
        if cell < 0 then cell = icon end
        local ok = pcall(function()
            animItems:SetTextureCell(cell)
            ImGui.DrawTextureAnimation(animItems, ICON_SIZE, ICON_SIZE)
        end)
        if not ok then ImGui.Dummy(ICON_SIZE, ICON_SIZE) end
    end

    local function pushRow(nextRows, row)
        nextRows[#nextRows + 1] = row
    end

    local function scanBags(nextRows, counts)
        for pack = 1, NUM_PACKS do
            local bag
            pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
            if bag and bag() then
                local size = tonumber(bag.Container()) or 0
                if size > 0 then
                    counts.packs = counts.packs + 1
                    for slot = 1, size do
                        local item, name, qty, id, icon, value, nodrop, norent, kind, teachName
                        pcall(function()
                            item = bag.Item(slot)
                            if item and item() then
                                name = trim(item.Name())
                                qty = tonumber(item.Stack()) or 1
                                id = tonumber(item.ID()) or 0
                                icon = tonumber(item.Icon()) or 0
                                value = tonumber(item.Value()) or 0
                                nodrop = not not item.NoDrop()
                                norent = not not item.NoRent()
                                kind, teachName = scrollInfo(item)
                            end
                        end)
                        if name and name ~= '' and name ~= 'NULL' then
                            counts.used = counts.used + 1
                            local stackable = false
                            pcall(function()
                                if item and item.Stackable then stackable = not not item.Stackable() end
                            end)
                            local copper = value or 0
                            pushRow(nextRows, {
                                name = name,
                                qty = qty or 1,
                                pack = pack,
                                slot = slot,
                                bank = 0,
                                id = id or 0,
                                icon = icon or 0,
                                copper = copper,
                                value = nodrop and 0 or copper,
                                price = nodrop and 'NO DROP' or fmtCoins(copper),
                                nodrop = nodrop,
                                norent = norent,
                                stackable = stackable,
                                spell = kind ~= nil,
                                kind = kind,
                                spellName = teachName or '',
                                where = 'bags',
                                loc = string.format('pack%d:%d', pack, slot),
                            })
                        else
                            counts.free = counts.free + 1
                            if showEmpty then
                                pushRow(nextRows, {
                                    name = '',
                                    qty = 0,
                                    pack = pack,
                                    slot = slot,
                                    bank = 0,
                                    id = 0,
                                    icon = 0,
                                    value = 0,
                                    price = '-',
                                    empty = true,
                                    where = 'bags',
                                    loc = string.format('pack%d:%d', pack, slot),
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    local function scanBank(nextRows, counts)
        local maxBank = 24
        pcall(function()
            local n = tonumber(mq.TLO.Me.NumBankSlots and mq.TLO.Me.NumBankSlots() or mq.TLO.Bank.BagSlots())
            if n and n > 0 then maxBank = n end
        end)
        for b = 1, maxBank do
            local bag
            pcall(function() bag = mq.TLO.Me.Bank(b) end)
            if bag and bag() then
                local size = tonumber(bag.Container()) or 0
                if size > 0 then
                    counts.packs = counts.packs + 1
                    for slot = 1, size do
                        local item, name, qty, id, icon, value, nodrop, norent
                        pcall(function()
                            item = bag.Item(slot)
                            if item and item() then
                                name = trim(item.Name())
                                qty = tonumber(item.Stack()) or 1
                                id = tonumber(item.ID()) or 0
                                icon = tonumber(item.Icon()) or 0
                                value = tonumber(item.Value()) or 0
                                nodrop = not not item.NoDrop()
                                norent = not not item.NoRent()
                            end
                        end)
                        if name and name ~= '' and name ~= 'NULL' then
                            counts.used = counts.used + 1
                            local stackable = false
                            pcall(function()
                                if item and item.Stackable then stackable = not not item.Stackable() end
                            end)
                            local copper = value or 0
                            pushRow(nextRows, {
                                name = name,
                                qty = qty or 1,
                                pack = 0,
                                slot = slot,
                                bank = b,
                                id = id or 0,
                                icon = icon or 0,
                                copper = copper,
                                value = nodrop and 0 or copper,
                                price = nodrop and 'NO DROP' or fmtCoins(copper),
                                nodrop = nodrop,
                                norent = norent,
                                stackable = stackable,
                                where = 'bank',
                                loc = string.format('bank%d:%d', b, slot),
                            })
                        else
                            counts.free = counts.free + 1
                            if showEmpty then
                                pushRow(nextRows, {
                                    name = '',
                                    qty = 0,
                                    pack = 0,
                                    slot = slot,
                                    bank = b,
                                    id = 0,
                                    icon = 0,
                                    value = 0,
                                    price = '-',
                                    empty = true,
                                    where = 'bank',
                                    loc = string.format('bank%d:%d', b, slot),
                                })
                            end
                        end
                    end
                else
                    -- VF: Loose item sitting in a top-level bank slot (not a container).
                    local name, qty, id, icon, value, nodrop, norent
                    pcall(function()
                        name = trim(bag.Name())
                        qty = tonumber(bag.Stack()) or 1
                        id = tonumber(bag.ID()) or 0
                        icon = tonumber(bag.Icon()) or 0
                        value = tonumber(bag.Value()) or 0
                        nodrop = not not bag.NoDrop()
                        norent = not not bag.NoRent()
                    end)
                    if name and name ~= '' and name ~= 'NULL' then
                        counts.used = counts.used + 1
                        local stackable = false
                        pcall(function()
                            if bag.Stackable then stackable = not not bag.Stackable() end
                        end)
                        local copper = value or 0
                        pushRow(nextRows, {
                            name = name,
                            qty = qty or 1,
                            pack = 0,
                            slot = 0,
                            bank = b,
                            id = id or 0,
                            icon = icon or 0,
                            copper = copper,
                            value = nodrop and 0 or copper,
                            price = nodrop and 'NO DROP' or fmtCoins(copper),
                            nodrop = nodrop,
                            norent = norent,
                            stackable = stackable,
                            where = 'bank',
                            loc = 'bank' .. b,
                        })
                    else
                        counts.free = counts.free + 1
                    end
                end
            else
                counts.free = counts.free + 1
            end
        end
    end

    -- VF: Merge same-name rows so Qty counts copies (incl. non-stackables).
    local function consolidateRows(list)
        local out, map = {}, {}
        for _, r in ipairs(list) do
            if r.empty then
                out[#out + 1] = r
            else
                local key = (r.where or '') .. '\t' .. (r.name or '')
                local g = map[key]
                if not g then
                    g = {
                        name = r.name,
                        qty = tonumber(r.qty) or 1,
                        pack = r.pack,
                        slot = r.slot,
                        bank = r.bank,
                        id = r.id,
                        icon = r.icon,
                        value = r.value,
                        copper = r.copper or r.value,
                        price = r.price,
                        nodrop = r.nodrop,
                        norent = r.norent,
                        stackable = r.stackable,
                        spell = r.spell,
                        kind = r.kind,
                        spellName = r.spellName,
                        where = r.where,
                        loc = r.loc,
                        copies = 1,
                        locs = {
                            { pack = r.pack, slot = r.slot, bank = r.bank, qty = tonumber(r.qty) or 1 },
                        },
                    }
                    map[key] = g
                    out[#out + 1] = g
                else
                    g.qty = (g.qty or 0) + (tonumber(r.qty) or 1)
                    g.copies = (g.copies or 1) + 1
                    g.locs[#g.locs + 1] = {
                        pack = r.pack, slot = r.slot, bank = r.bank, qty = tonumber(r.qty) or 1,
                    }
                    if (r.loc or '') ~= '' and not (g.loc or ''):find(r.loc, 1, true) then
                        g.loc = (g.loc or '') .. ', ' .. r.loc
                    end
                end
            end
        end
        return out
    end

    local function scan(force)
        local now = os.clock()
        if not force and (now - lastScan) < SCAN_SEC then return end
        lastScan = now
        if view ~= 'bags' and view ~= 'bank' then view = 'bags' end
        local nextRows = {}
        local counts = { used = 0, free = 0, packs = 0 }
        if view == 'bags' then scanBags(nextRows, counts) end
        if view == 'bank' then scanBank(nextRows, counts) end
        nextRows = consolidateRows(nextRows)
        table.sort(nextRows, function(a, b)
            if (a.empty and not b.empty) then return false end
            if (b.empty and not a.empty) then return true end
            if (a.name or '') ~= (b.name or '') then return (a.name or '') < (b.name or '') end
            return (a.loc or '') < (b.loc or '')
        end)
        rows, used, free, packs = nextRows, counts.used, counts.free, counts.packs
    end

    local function rowLoc(row, idx)
        idx = idx or 1
        if row.locs and row.locs[idx] then return row.locs[idx] end
        return { pack = row.pack, slot = row.slot, bank = row.bank, qty = row.qty }
    end

    local function findFirstLoc(where, name)
        local tmp, counts = {}, { used = 0, free = 0, packs = 0 }
        if where == 'bags' then
            scanBags(tmp, counts)
        else
            scanBank(tmp, counts)
        end
        for _, r in ipairs(tmp) do
            if not r.empty and r.name == name then
                return { pack = r.pack, slot = r.slot, bank = r.bank, qty = tonumber(r.qty) or 1 }
            end
        end
        return nil
    end

    local function ensureBankOpen()
        if bankOpen() then
            bankWatchUntil = 0
            return true
        end
        mq.cmd('/say #vault_bank')
        status = 'opening bank...'
        bankWatchUntil = os.clock() + BANK_WAIT
        return false
    end

    local function tickBankWatch()
        if bankWatchUntil <= 0 then return end
        if bankOpen() then
            bankWatchUntil = 0
            lastScan = 0
            status = ''
            return
        end
        if os.clock() >= bankWatchUntil then
            bankWatchUntil = 0
            status = 'Bank window not open'
        end
    end

    local function rowWhere(row)
        return (row and row.where) or view or 'bags'
    end

    local function isChecked(where, name)
        local t = checked[where or '']
        return not not (t and name and t[name])
    end

    local function setChecked(where, name, on)
        where = where or view or 'bags'
        if not name or name == '' then return end
        if on then
            if not checked[where] then checked[where] = {} end
            checked[where][name] = true
        elseif checked[where] then
            checked[where][name] = nil
        end
    end

    -- VF: Trace left stubbed - uncomment Trace checkbox in draw to re-enable chat logs.
    local function dbg(...) end

    local function clearChecks()
        checked = {}
    end

    local function isLockedId(id)
        id = tonumber(id) or 0
        return id > 0 and locked[id] ~= nil
    end

    local function isLockedRow(row)
        return row and isLockedId(row.id)
    end

    -- VF: name-only paths (mass queue) - match locked display name or FindItem ID.
    local function isLockedName(name)
        name = trim(name or '')
        if name == '' then return false end
        for id, n in pairs(locked) do
            if n == name then return true end
        end
        local id = 0
        pcall(function()
            local fi = mq.TLO.FindItem('=' .. name)
            if fi and fi() then id = tonumber(fi.ID()) or 0 end
        end)
        return isLockedId(id)
    end

    local function reloadLocks()
        local map, path, migrated = invLocks.load()
        locked = map or {}
        lockPath = path or ''
        local n = 0
        for _ in pairs(locked) do n = n + 1 end
        dbg('locks loaded n=%d path=%s migrated=%s', n, tostring(lockPath), tostring(migrated))
        if migrated then locksDirty = true end
    end

    local function setLockedRow(row, on)
        if not row or row.empty then return end
        local id = tonumber(row.id) or 0
        if id <= 0 then
            status = 'no item id to lock'
            return
        end
        local want = not not on
        if want and locked[id] then return end
        if (not want) and not locked[id] then return end
        if want then
            locked[id] = row.name or ''
        else
            locked[id] = nil
        end
        locksDirty = true
        dbg('lock %s id=%s name=%s', want and 'ON' or 'OFF', tostring(id), tostring(row.name))
        status = (want and 'locked ' or 'unlocked ') .. (row.name or tostring(id))
    end

    local function flushLocks()
        if not locksDirty then return end
        locksDirty = false
        local ok, path = invLocks.save(locked)
        lockPath = path or lockPath
        if not ok and not lockSaveWarned then
            lockSaveWarned = true
            -- VF: one chat line; UI status still shows detail if needed.
            chat.err('Inv', 'could not write locks -- create vft/config/ (' .. tostring(path) .. ')')
        elseif ok then
            dbg('locks saved path=%s', tostring(path))
        end
    end

    reloadLocks()

    local function checkedNames(where, allowLocked)
        local names = {}
        local t = checked[where]
        if t then
            for name, on in pairs(t) do
                -- VF: Lock blocks Sell/Delete only; Move may include locked names.
                if on and name ~= '' and (allowLocked or not isLockedName(name)) then
                    names[#names + 1] = name
                end
            end
        end
        table.sort(names)
        return names
    end

    -- VF: Vendor won't take No Drop / temporary (NoRent) / 0-value - uncheck before Sell.
    local function canVendorSellRow(row)
        if not row or row.empty then return false end
        if row.nodrop or row.norent then return false end
        if isLockedRow(row) then return false end
        local copper = tonumber(row.copper) or tonumber(row.value) or 0
        if copper <= 0 then return false end
        return true
    end

    local function pruneChecksForSell(where)
        where = where or 'bags'
        lastScan = 0
        scan()
        local keep, skipped = {}, 0
        local t = checked[where]
        if not t then return keep, 0 end
        local names = {}
        for name, on in pairs(t) do
            if on and name ~= '' then names[#names + 1] = name end
        end
        for _, name in ipairs(names) do
            local row
            for _, r in ipairs(rows) do
                if not r.empty and (r.where or where) == where and r.name == name then
                    row = r
                    break
                end
            end
            if row and canVendorSellRow(row) then
                keep[#keep + 1] = name
            else
                setChecked(where, name, false)
                skipped = skipped + 1
            end
        end
        table.sort(keep)
        return keep, skipped
    end

    local function countChecked(where)
        local n = 0
        if where then
            local t = checked[where]
            if t then
                for _, on in pairs(t) do
                    if on then n = n + 1 end
                end
            end
            return n
        end
        for _, t in pairs(checked) do
            for _, on in pairs(t) do
                if on then n = n + 1 end
            end
        end
        return n
    end

    local function matches(row)
        local q = filter:lower()
        if q == '' then return true end
        if row.empty then return false end
        local hay = ((row.name or '') .. ' ' .. (row.loc or '')):lower()
        return hay:find(q, 1, true)
    end

    local function pickup(row, one)
        if not row or row.empty then return end
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            mq.cmd('/autoinventory')
            mq.delay(50)
        end
        local loc = rowLoc(row, 1)
        local w = row.where or 'bags'
        if w == 'bags' then
            -- VF: Ctrl+LMB takes one off a stack (same as /ctrlkey itemnotify).
            if one then
                mq.cmdf('/nomodkey /ctrlkey /itemnotify in pack%d %d leftmouseup', loc.pack, loc.slot)
                status = 'picked 1 ' .. (row.name or '')
            else
                mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', loc.pack, loc.slot)
                status = 'picked ' .. (row.name or '')
            end
            lastScan = 0
        elseif w == 'bank' then
            if one then
                if not bankOpen() then
                    status = 'Open bank first'
                    return
                end
                local bank = tonumber(loc.bank) or 0
                local slot = tonumber(loc.slot) or 0
                if bank <= 0 then return end
                if slot > 0 then
                    mq.cmdf('/nomodkey /ctrlkey /itemnotify in bank%d %d leftmouseup', bank, slot)
                else
                    mq.cmdf('/nomodkey /ctrlkey /itemnotify bank%d leftmouseup', bank)
                end
                status = 'picked 1 ' .. (row.name or '')
                lastScan = 0
                return
            end
            pending = { op = 'pickbank', row = row, phase = 'prep', t = os.clock() }
            status = 'picking from bank...'
            return
        end
    end

    local function dropToBags()
        if (mq.TLO.Cursor.ID() or 0) <= 0 then
            status = 'cursor empty'
            return
        end
        for pack = 1, NUM_PACKS do
            local bag
            pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
            if bag and bag() then
                local size = tonumber(bag.Container()) or 0
                for slot = 1, size do
                    local empty = true
                    pcall(function()
                        local it = bag.Item(slot)
                        if it and it() then empty = false end
                    end)
                    if empty then
                        mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', pack, slot)
                        status = string.format('dropped to pack%d:%d', pack, slot)
                        lastScan = 0
                        return
                    end
                end
            end
        end
        mq.cmd('/autoinventory')
        status = 'bags full -- autoinv'
        lastScan = 0
    end

    -- VF: Never itemnotify bank* unless BankWnd is open - closed bank looks empty and dumps to inv.
    local function placeCursorInBank()
        if (mq.TLO.Cursor.ID() or 0) <= 0 then
            status = 'cursor empty'
            return false
        end
        if not bankOpen() then
            status = 'bank not open'
            return false
        end
        local maxBank = 24
        pcall(function()
            local n = tonumber(mq.TLO.Bank.BagSlots())
            if n and n > 0 then maxBank = n end
        end)
        for b = 1, maxBank do
            local bag
            pcall(function() bag = mq.TLO.Me.Bank(b) end)
            if bag and bag() then
                local size = tonumber(bag.Container()) or 0
                if size > 0 then
                    for slot = 1, size do
                        local empty = true
                        pcall(function()
                            local it = bag.Item(slot)
                            if it and it() then empty = false end
                        end)
                        if empty then
                            mq.cmdf('/nomodkey /itemnotify in bank%d %d leftmouseup', b, slot)
                            status = string.format('dropped to bank%d:%d', b, slot)
                            lastScan = 0
                            return true
                        end
                    end
                end
            else
                mq.cmdf('/nomodkey /itemnotify bank%d leftmouseup', b)
                status = 'dropped to bank' .. b
                lastScan = 0
                return true
            end
        end
        status = 'bank full'
        return false
    end

    -- VF: Bag<->bank moves run in this script's own tick (satellite), short polls.
    local function waitCursor(wantOn, maxMs)
        maxMs = maxMs or 300
        local deadline = os.clock() + (maxMs / 1000)
        while os.clock() < deadline do
            local on = (mq.TLO.Cursor.ID() or 0) > 0
            if wantOn == on then return true end
            mq.delay(20)
        end
        return ((mq.TLO.Cursor.ID() or 0) > 0) == wantOn
    end

    -- VF: Shift-pickup / stack merge can open QuantityWnd - accept full amount.
    local function acceptQtyQuick()
        local open = false
        pcall(function() open = not not mq.TLO.Window('QuantityWnd').Open() end)
        if not open then return end
        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        mq.delay(500, function()
            local o = false
            pcall(function() o = not not mq.TLO.Window('QuantityWnd').Open() end)
            return not o
        end)
    end

    local function cursorStack()
        local n = 0
        pcall(function() n = tonumber(mq.TLO.Cursor.Stack()) or 0 end)
        if n <= 0 and (mq.TLO.Cursor.ID() or 0) > 0 then n = 1 end
        return n
    end

    local function clearCursorAutoinv(maxMs)
        maxMs = maxMs or 2000
        local deadline = os.clock() + (maxMs / 1000)
        while os.clock() < deadline do
            if (mq.TLO.Cursor.ID() or 0) <= 0 then return true end
            mq.cmd('/autoinventory')
            mq.delay(20)
        end
        return (mq.TLO.Cursor.ID() or 0) <= 0
    end

    -- VF: Same flow as Macros/handinsingle.mac with amount=1 delay=1 (one item, 0.1s).
    local function handinOne(name)
        name = tostring(name or '')
        if name == '' then return false end
        if (mq.TLO.Target.ID() or 0) <= 0 then return false end
        local left = 0
        pcall(function()
            left = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0
        end)
        if left < 1 then return false end
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            mq.cmd('/autoinventory')
            waitCursor(false, 400)
        end
        local safe = name:gsub('"', '')
        mq.cmdf('/ctrlkey /itemnotify "%s" leftmouseup', safe)
        if not waitCursor(true, 500) then return false end
        mq.cmd('/click left target')
        if not waitCursor(false, 1000) then return false end
        mq.cmd('/notify GiveWnd GVW_Give_Button leftmouseup')
        mq.delay(500)
        clearCursorAutoinv(2000)
        mq.delay(100)
        return true
    end

    local function ensureBankReady()
        if bankOpen() then return true end
        mq.cmd('/say #vault_bank')
        status = 'opening bank...'
        local deadline = os.clock() + BANK_WAIT
        while os.clock() < deadline do
            if bankOpen() then
                status = ''
                return true
            end
            mq.delay(40)
        end
        status = 'Bank window not open'
        return false
    end

    -- VF: MQ will not itemnotify inside a closed bank bag (FindItemBank ItemSlot rule).
    local function openBankBag(bank)
        bank = tonumber(bank) or 0
        if bank <= 0 then return false end
        local size = 0
        pcall(function() size = tonumber(mq.TLO.Me.Bank(bank).Container()) or 0 end)
        if size <= 0 then return true end
        mq.cmdf('/nomodkey /itemnotify bank%d rightmouseup', bank)
        mq.delay(280)
        return true
    end

    -- VF: Shift-click picks the whole stack (plain click often grabs 1 or opens qty).
    local function pickFromBankLoc(loc, name)
        if not loc or not loc.bank then return false end
        if not ensureBankReady() then return false end
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            mq.cmd('/autoinventory')
            waitCursor(false, 200)
        end
        local bank, slot = loc.bank, tonumber(loc.slot) or 0
        local function tryNotify(fmt, ...)
            mq.cmdf(fmt, ...)
            mq.delay(80)
            acceptQtyQuick()
            return waitCursor(true, 450)
        end
        if slot > 0 then
            openBankBag(bank)
            if tryNotify('/nomodkey /shiftkey /itemnotify in bank%d %d leftmouseup', bank, slot) then
                return true
            end
            if tryNotify('/nomodkey /shiftkey /itemnotify bank%d %d leftmouseup', bank, slot) then
                return true
            end
            if name and name ~= '' then
                local fi
                pcall(function() fi = mq.TLO.FindItemBank('=' .. name) end)
                if not (fi and fi()) then
                    pcall(function() fi = mq.TLO.FindItemBank(name) end)
                end
                local islot, islot2
                pcall(function()
                    if fi and fi() then
                        islot = tonumber(fi.ItemSlot())
                        islot2 = tonumber(fi.ItemSlot2())
                    end
                end)
                if islot and islot2 ~= nil and islot2 >= 0 then
                    local b = islot - 1999
                    if b >= 1 then
                        openBankBag(b)
                        if tryNotify('/nomodkey /shiftkey /itemnotify in bank%d %d leftmouseup', b, islot2 + 1) then
                            return true
                        end
                    end
                end
            end
            dbg('pickFromBank fail bank=%s slot=%s name=%s', tostring(bank), tostring(slot), tostring(name))
            return false
        end
        return tryNotify('/nomodkey /shiftkey /itemnotify bank%d leftmouseup', bank)
    end

    local function moveAllNamed(toBank, name)
        if not name or name == '' then return 0 end
        local where = toBank and 'bags' or 'bank'
        if not ensureBankReady() then
            status = 'Bank window not open'
            return 0
        end
        local moved = 0
        local units = 0
        for _ = 1, 40 do
            if (mq.TLO.Cursor.ID() or 0) > 0 then
                mq.cmd('/autoinventory')
                waitCursor(false, 200)
            end
            local loc = findFirstLoc(where, name)
            if not loc then break end
            local wantQty = tonumber(loc.qty) or 1
            if toBank then
                -- VF: shift = whole stack off the bag slot.
                mq.cmdf('/nomodkey /shiftkey /itemnotify in pack%d %d leftmouseup', loc.pack, loc.slot)
                mq.delay(80)
                acceptQtyQuick()
                if not waitCursor(true, 450) then
                    status = 'could not pick ' .. name
                    break
                end
                local got = cursorStack()
                if not placeCursorInBank() then break end
                acceptQtyQuick()
                waitCursor(false, 500)
                units = units + got
            else
                if not pickFromBankLoc(loc, name) then
                    status = 'could not pick from bank: ' .. name
                    break
                end
                local got = cursorStack()
                -- VF: with bank open, autoinv parks the cursor stack into bags/inventory.
                mq.cmd('/autoinventory')
                acceptQtyQuick()
                if not waitCursor(false, 600) then
                    dropToBags()
                    acceptQtyQuick()
                    waitCursor(false, 400)
                end
                if (mq.TLO.Cursor.ID() or 0) > 0 then
                    status = 'bags full?'
                    break
                end
                units = units + got
            end
            moved = moved + 1
            dbg('move stack name=%s dir=%s slotQty=%s cursorWas=%s',
                name, toBank and 'bank' or 'bags', tostring(wantQty), tostring(units))
            mq.delay(40)
        end
        status = string.format('%s %d slot(s) / %d %s',
            toBank and 'banked' or 'bagged', moved, units, name)
        lastScan = 0
        return moved
    end

    local function dropToBank()
        if (mq.TLO.Cursor.ID() or 0) <= 0 then
            status = 'cursor empty'
            return
        end
        if not ensureBankReady() then
            status = 'Bank window not open'
            return
        end
        pcall(placeCursorInBank)
    end

    local function inspectItem(row)
        if not row or row.empty then return end
        local ok = false
        if (row.where or 'bags') == 'bags' then
            ok = pcall(function()
                local item = mq.TLO.Me.Inventory('pack' .. row.pack).Item(row.slot)
                if item and item() then
                    item.Inspect()
                    return
                end
                item = mq.TLO.FindItem('=' .. (row.name or ''))
                if item and item() then item.Inspect() end
            end)
        elseif row.where == 'bank' then
            ok = pcall(function()
                local item
                if (row.slot or 0) > 0 then
                    item = mq.TLO.Me.Bank(row.bank).Item(row.slot)
                else
                    item = mq.TLO.Me.Bank(row.bank)
                end
                if item and item() then item.Inspect() end
            end)
        end
        status = (ok and 'inspect ' or 'could not inspect ') .. (row.name or '')
    end

    local function autoinv()
        local n = 0
        local name = ''
        pcall(function() name = trim(mq.TLO.Cursor.Name()) end)
        while (mq.TLO.Cursor.ID() or 0) > 0 and n < 40 do
            mq.cmd('/autoinventory')
            n = n + 1
            mq.delay(50)
        end
        if n > 0 then
            status = 'inventoried' .. (name ~= '' and (' ' .. name) or '')
        else
            status = 'cursor empty'
        end
    end

    -- VF: E3 / LootNScoot sell - itemnotify selects into MerchantWnd (not cursor),
    -- wait MW_SelectedItemLabel + Sell enabled, then shift+MW_Sell_Button (full stack).
    local function selectedLabel()
        local t = ''
        pcall(function() t = trim(mq.TLO.Window('MerchantWnd/MW_SelectedItemLabel').Text()) end)
        if t == '' then
            pcall(function()
                t = trim(mq.TLO.Window('MerchantWnd').Child('MW_SelectedItemLabel').Text())
            end)
        end
        return t
    end

    local function merchantSelectedName()
        local n = ''
        pcall(function()
            local sel = mq.TLO.Merchant.SelectedItem
            if sel and sel() then n = trim(sel.Name()) end
        end)
        return n
    end

    local function sellButtonOk()
        local ok = false
        pcall(function() ok = not not mq.TLO.Window('MerchantWnd/MW_Sell_Button').Enabled() end)
        if not ok then
            pcall(function()
                ok = not not mq.TLO.Window('MerchantWnd').Child('MW_Sell_Button').Enabled()
            end)
        end
        return ok
    end

    local function sellPriceOk()
        local price = ''
        pcall(function() price = tostring(mq.TLO.Window('MerchantWnd/MW_SelectedPriceLabel').Text() or '') end)
        if price == '' then
            pcall(function()
                price = tostring(mq.TLO.Window('MerchantWnd').Child('MW_SelectedPriceLabel').Text() or '')
            end)
        end
        -- VF: empty price with Sell enabled still counts; only hard-reject explicit 0c.
        if price == '0c' then return false end
        return true
    end

    local function acceptQtyIfOpen()
        local open = false
        pcall(function() open = not not mq.TLO.Window('QuantityWnd').Open() end)
        if not open then return end
        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        mq.delay(400, function()
            local o = false
            pcall(function() o = not not mq.TLO.Window('QuantityWnd').Open() end)
            return not o
        end)
    end

    local function cursorName()
        local n = ''
        pcall(function() n = trim(mq.TLO.Cursor.Name()) end)
        return n
    end

    local function clearCursor()
        local n = 0
        while (mq.TLO.Cursor.ID() or 0) > 0 and n < 20 do
            mq.cmd('/autoinventory')
            n = n + 1
            mq.delay(40)
        end
    end

    -- VF: FindItem pack/slot for notify - same math as scribe (ItemSlot 23=pack1, ItemSlot2 0-based).
    local function findItemPackSlot(itemName)
        itemName = trim(itemName or '')
        if itemName == '' then return nil end
        local fi
        pcall(function() fi = mq.TLO.FindItem('=' .. itemName) end)
        if not fi or not fi() then
            pcall(function() fi = mq.TLO.FindItem(itemName) end)
        end
        if not fi or not fi() then return nil end
        local slot, slot2
        pcall(function()
            slot = tonumber(fi.ItemSlot())
            slot2 = tonumber(fi.ItemSlot2())
        end)
        if slot and slot >= 23 and slot2 ~= nil and slot2 >= 0 then
            return { pack = slot - 22, slot = slot2 + 1, invSlot = slot }
        elseif slot and slot > 0 then
            return { pack = 0, slot = 0, invSlot = slot }
        end
        return nil
    end

    local function clickSellButton()
        mq.cmd('/nomodkey /shiftkey /notify MerchantWnd MW_Sell_Button leftmouseup')
        mq.delay(250)
        acceptQtyIfOpen()
    end

    local function sellSelectedOrCursor(want)
        if selectedLabel() == want or merchantSelectedName() == want then
            if sellButtonOk() and sellPriceOk() then
                clickSellButton()
                return true
            end
            -- VF: button disabled = vendor won't buy; still try TLO Sell once.
            local sold = false
            pcall(function()
                mq.TLO.Merchant.Sell(1)()
                sold = true
            end)
            dbg('sell TLO Merchant.Sell after select sold=%s btn=%s', tostring(sold), tostring(sellButtonOk()))
            mq.delay(300)
            return not findFirstLoc('bags', want) or selectedLabel() ~= want
        end
        if cursorName() == want then
            dbg('sell cursor path for %s', want)
            clickSellButton()
            mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) <= 0 end)
            if (mq.TLO.Cursor.ID() or 0) > 0 and cursorName() == want then
                -- VF: Sell miss - put it back.
                clearCursor()
                return false
            end
            return true
        end
        return false
    end

    local function sell(row)
        if not row or row.empty then return false end
        if (row.where or 'bags') ~= 'bags' then
            status = 'Sell is bags only'
            return false
        end
        if row.nodrop then
            status = row.name .. ' is No Drop'
            return false
        end
        if isLockedRow(row) then
            status = row.name .. ' is locked'
            dbg('sell blocked locked %s id=%s', tostring(row.name), tostring(row.id))
            return false
        end
        if not merchantOpen() then
            status = 'Sell is off until a trader window is open'
            return false
        end
        local want = row.name or ''
        local safe = want:gsub('"', '')
        clearCursor()

        local fiLoc = findItemPackSlot(want)
        local loc = fiLoc or rowLoc(row, 1)
        dbg('sell start name=%s findItem pack=%s slot=%s inv=%s row pack=%s slot=%s',
            want,
            tostring(fiLoc and fiLoc.pack), tostring(fiLoc and fiLoc.slot), tostring(fiLoc and fiLoc.invSlot),
            tostring(row.pack), tostring(row.slot))
        if not loc then
            status = 'not in bags: ' .. want
            dbg('sell fail: no loc for %s', want)
            return false
        end

        -- VF: Path 1 - E3: leftmouseup in pack selects into MerchantWnd (or puts on cursor on Triune).
        if loc.pack and loc.pack > 0 and loc.slot and loc.slot > 0 then
            ensurePackOpen(loc.pack)
            mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', loc.pack, loc.slot)
        elseif loc.invSlot and loc.invSlot > 0 then
            mq.cmdf('/nomodkey /itemnotify %d leftmouseup', loc.invSlot)
        end
        mq.delay(800, function()
            return selectedLabel() == want
                or merchantSelectedName() == want
                or cursorName() == want
                or sellButtonOk()
        end)
        dbg('sell path1 label=%q merchSel=%q cursor=%q btn=%s priceOk=%s',
            selectedLabel(), merchantSelectedName(), cursorName(),
            tostring(sellButtonOk()), tostring(sellPriceOk()))
        if sellSelectedOrCursor(want) then
            mq.delay(500, function() return not findFirstLoc('bags', want) or selectedLabel() ~= want end)
            if not findFirstLoc('bags', want) or selectedLabel() ~= want or cursorName() ~= want then
                status = 'sold ' .. want
                dbg('sell ok path1 %s', want)
                return true
            end
        end
        clearCursor()

        -- VF: Path 2 - ctrl pickup onto cursor, then MW_Sell_Button.
        if loc.pack and loc.pack > 0 and loc.slot and loc.slot > 0 then
            ensurePackOpen(loc.pack)
            mq.cmdf('/nomodkey /ctrlkey /itemnotify in pack%d %d leftmouseup', loc.pack, loc.slot)
        elseif loc.invSlot and loc.invSlot > 0 then
            mq.cmdf('/nomodkey /ctrlkey /itemnotify %d leftmouseup', loc.invSlot)
        else
            mq.cmdf('/nomodkey /ctrlkey /itemnotify "%s" leftmouseup', safe)
        end
        mq.delay(600, function() return cursorName() == want end)
        dbg('sell path2 cursor=%q', cursorName())
        if cursorName() == want then
            clickSellButton()
            mq.delay(500, function() return (mq.TLO.Cursor.ID() or 0) <= 0 end)
            if (mq.TLO.Cursor.ID() or 0) <= 0 or cursorName() ~= want then
                status = 'sold ' .. want
                dbg('sell ok path2 %s', want)
                return true
            end
            clearCursor()
        end

        -- VF: Path 3 - Merchant.SelectItem / /selectitem + Sell TLO / button.
        pcall(function() mq.TLO.Merchant.SelectItem('=' .. safe)() end)
        mq.delay(200)
        if merchantSelectedName() ~= want and selectedLabel() ~= want then
            mq.cmdf('/selectitem "=%s"', safe)
            mq.delay(300, function()
                return merchantSelectedName() == want or selectedLabel() == want
            end)
        end
        dbg('sell path3 label=%q merchSel=%q btn=%s',
            selectedLabel(), merchantSelectedName(), tostring(sellButtonOk()))
        if merchantSelectedName() == want or selectedLabel() == want then
            local sold = false
            local qty = 1
            pcall(function()
                local sel = mq.TLO.Merchant.SelectedItem
                if sel and sel() then qty = tonumber(sel.Stack()) or 1 end
            end)
            pcall(function()
                mq.TLO.Merchant.Sell(qty)()
                sold = true
            end)
            if not sold then
                clickSellButton()
                sold = true
            end
            mq.delay(400)
            dbg('sell path3 Sell qty=%s', tostring(qty))
            if not findFirstLoc('bags', want) or selectedLabel() ~= want then
                status = 'sold ' .. want
                dbg('sell ok path3 %s', want)
                return true
            end
        end

        clearCursor()
        status = 'could not sell ' .. want
        dbg('sell fail all paths %s label=%q cursor=%q btn=%s',
            want, selectedLabel(), cursorName(), tostring(sellButtonOk()))
        return false
    end

    -- VF: Sell every copy of a bags item while merchant stays open.
    local function sellAllNamed(name)
        if not name or name == '' then return 0 end
        if not merchantOpen() then
            status = 'open a vendor to sell'
            return 0
        end
        local sold = 0
        for _ = 1, 40 do
            local loc = findFirstLoc('bags', name)
            if not loc then break end
            local ok = sell({
                name = name,
                where = 'bags',
                empty = false,
                pack = loc.pack,
                slot = loc.slot,
                locs = { loc },
            })
            if not ok then break end
            sold = sold + 1
            mq.delay(50)
        end
        return sold
    end

    -- VF: /destroy eats the cursor. Pick this tick, destroy next tick when the name matches.
    local destroyArmed = nil
    local massDestroyWhere = 'bags'

    local function armDestroy(row)
        if not row or row.empty then return end
        local w = row.where or 'bags'
        if w ~= 'bags' and w ~= 'bank' then
            status = 'Del only from Bags or Bank'
            return
        end
        if w == 'bank' and not bankOpen() then
            status = 'open bank to delete from bank'
            return
        end
        if isLockedRow(row) then
            status = row.name .. ' is locked'
            return
        end
        local loc = rowLoc(row, 1)
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            mq.cmd('/autoinventory')
            waitCursor(false, 200)
        end
        if w == 'bags' then
            mq.cmdf('/nomodkey /shiftkey /itemnotify in pack%d %d leftmouseup', loc.pack, loc.slot)
            mq.delay(80)
            acceptQtyQuick()
            if not waitCursor(true, 450) then
                status = 'could not pick ' .. (row.name or '')
                return
            end
        else
            if not pickFromBankLoc(loc, row.name) then
                status = 'could not pick from bank: ' .. (row.name or '')
                return
            end
        end
        destroyArmed = {
            name = row.name,
            id = row.id or 0,
            at = os.clock(),
            where = w,
        }
        status = 'destroying ' .. row.name
    end

    local function finishDestroy()
        if not destroyArmed then return false end
        local now = os.clock()
        local curName, curId = '', 0
        pcall(function()
            curName = trim(mq.TLO.Cursor.Name())
            curId = tonumber(mq.TLO.Cursor.ID()) or 0
        end)
        local want = destroyArmed.name or ''
        local match = (curName ~= '' and curName == want)
            or (destroyArmed.id > 0 and curId == destroyArmed.id)
        if match then
            mq.cmd('/destroy')
            status = 'destroyed ' .. want
            destroyArmed = nil
            lastScan = 0
            return true
        end
        local timeout = (destroyArmed.where == 'bank') and 2.0 or 1.2
        if (now - (destroyArmed.at or now)) > timeout then
            status = 'destroy failed -- ' .. want .. ' not on cursor'
            if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
            destroyArmed = nil
            return true
        end
        return true
    end

    local function queueMassDestroy(names, where)
        massDestroyQ = {}
        massDestroyWhere = where or 'bags'
        for _, name in ipairs(names) do
            massDestroyQ[#massDestroyQ + 1] = name
        end
    end

    local function tickMassDestroy()
        if destroyArmed then return end
        local where = massDestroyWhere or 'bags'
        while #massDestroyQ > 0 do
            local name = massDestroyQ[1]
            local loc = findFirstLoc(where, name)
            if not loc then
                table.remove(massDestroyQ, 1)
                setChecked(where, name, false)
            else
                armDestroy({
                    name = name,
                    where = where,
                    empty = false,
                    pack = loc.pack,
                    slot = loc.slot,
                    bank = loc.bank,
                    id = 0,
                    locs = { loc },
                })
                return
            end
        end
    end

    local function clearCursorQuiet()
        local n = 0
        while (mq.TLO.Cursor.ID() or 0) > 0 and n < 20 do
            mq.cmd('/autoinventory')
            n = n + 1
            mq.delay(40)
        end
    end

    -- VF: packN notify only works while that bag window is open.
    ensurePackOpen = function(pack)
        local isOpen = false
        pcall(function() isOpen = not not mq.TLO.Window('Pack' .. pack).Open() end)
        if isOpen then return true end
        mq.cmdf('/nomodkey /itemnotify pack%d rightmouseup', pack)
        mq.delay(500, function()
            local o = false
            pcall(function() o = not not mq.TLO.Window('Pack' .. pack).Open() end)
            return o
        end)
        pcall(function() isOpen = not not mq.TLO.Window('Pack' .. pack).Open() end)
        if isOpen then openedPacks[pack] = true end
        return isOpen
    end

    local function closeOpenedPacks()
        for pack in pairs(openedPacks) do
            pcall(function()
                if mq.TLO.Window('Pack' .. pack).Open() then
                    mq.cmdf('/nomodkey /itemnotify pack%d rightmouseup', pack)
                    mq.delay(60)
                end
            end)
        end
        openedPacks = {}
    end

    -- VF: FindItem each click -- queued pack/slot goes stale when a scroll is consumed.
    local function rightClickByName(itemName)
        itemName = trim(itemName)
        if itemName == '' then return false end
        local fi
        pcall(function() fi = mq.TLO.FindItem('=' .. itemName) end)
        if not fi or not fi() then
            pcall(function() fi = mq.TLO.FindItem(itemName) end)
        end
        if not fi or not fi() then return false end

        local slot, slot2
        pcall(function()
            slot = tonumber(fi.ItemSlot())
            slot2 = tonumber(fi.ItemSlot2())
        end)

        -- VF: ItemSlot 23 = pack1; ItemSlot2 is 0-based inside the bag.
        if slot and slot >= 23 and slot2 ~= nil and slot2 >= 0 then
            local pack = slot - 22
            if ensurePackOpen(pack) then
                mq.cmdf('/nomodkey /itemnotify in pack%d %d rightmouseup', pack, slot2 + 1)
                return true
            end
        elseif slot and slot > 0 then
            mq.cmdf('/nomodkey /itemnotify %d rightmouseup', slot)
            return true
        end

        local safe = itemName:gsub('"', '')
        mq.cmdf('/nomodkey /itemnotify "%s" rightmouseup', safe)
        return true
    end

    local function queueScribeAll()
        local why = scribeBlocked()
        if why then
            status = 'cannot scribe -- ' .. why
            return
        end
        lastScan = 0
        scan()
        memQ = {}
        memExpect = nil
        memDone, memSkip, memFail = 0, 0, 0
        memWaitUntil = 0
        local seen = {}
        for _, row in ipairs(rows) do
            if row and not row.empty and row.kind and (row.where or 'bags') == 'bags' then
                local sn = row.spellName ~= '' and row.spellName or row.name
                local kind = row.kind
                local key = kind .. ':' .. sn:lower()
                if alreadyKnown(kind, sn) then
                    memSkip = memSkip + 1
                elseif seen[key] then
                    memSkip = memSkip + 1
                else
                    seen[key] = true
                    -- VF: Store full item name (Spell: Foo) for FindItem / itemnotify.
                    memQ[#memQ + 1] = {
                        name = row.name,
                        spellName = sn,
                        kind = kind,
                    }
                end
            end
        end
        if #memQ == 0 then
            status = memSkip > 0 and ('nothing new to scribe (skipped ' .. memSkip .. ')')
                or 'no scribe items in bags'
            return
        end
        status = string.format('scribe queue %d', #memQ)
    end

    local function tickScribe()
        if #memQ == 0 and not memExpect then return end
        local now = os.clock()

        if memExpect and scribeLanded(memExpect.kind, memExpect.spellName) then
            memWaitUntil = 0
        end
        if now < memWaitUntil then return end

        if memExpect then
            if scribeLanded(memExpect.kind, memExpect.spellName) then
                memDone = memDone + 1
            else
                memFail = memFail + 1
            end
            clearCursorQuiet()
            memExpect = nil
            lastScan = 0
            if #memQ == 0 then
                closeSpellBook()
                closeOpenedPacks()
                status = string.format('scribe done -- %d ok, %d skip, %d fail', memDone, memSkip, memFail)
                return
            end
        end

        if #memQ == 0 then return end

        local why = scribeBlocked()
        if why then
            status = 'scribe paused -- ' .. why .. ' (' .. #memQ .. ' left)'
            memWaitUntil = now + 0.75
            return
        end

        local job
        while #memQ > 0 do
            local cand = table.remove(memQ, 1)
            if alreadyKnown(cand.kind, cand.spellName) then
                memSkip = memSkip + 1
            else
                job = cand
                break
            end
        end
        if not job then
            closeSpellBook()
            closeOpenedPacks()
            status = string.format('scribe done -- %d ok, %d skip, %d fail', memDone, memSkip, memFail)
            return
        end

        clearCursorQuiet()
        if not rightClickByName(job.name) then
            memFail = memFail + 1
            status = 'not found: ' .. (job.name or '?')
            return
        end
        memExpect = job
        memWaitUntil = now + ((job.kind == 'disc') and 2.5 or 3.5)
        status = string.format('scribing %s (%s, %d left)', job.spellName, job.kind, #memQ)
    end

    -- VF: click ops fire in ImGui. Tick handles sell / scribe / bank moves (delays).
    local function clickNow(op, row)
        if op == 'vaultmerch' then
            mq.cmd('/say #vault_merchant')
            status = 'summoned vault merchant'
        elseif op == 'openbank' then
            ensureBankOpen()
        elseif op == 'autoinv' then
            mq.cmd('/autoinventory')
            status = 'inventoried'
        elseif op == 'dropbags' then
            pcall(dropToBags)
        elseif op == 'dropbank' then
            pcall(dropToBank)
        elseif op == 'masssell' then
            if merchantOpen() == false then
                status = 'open a vendor to Sell'
                return
            end
            if view ~= 'bags' then
                status = 'Sell is bags-only'
                return
            end
            local names, skipped = pruneChecksForSell('bags')
            if #names == 0 then
                status = skipped > 0 and 'nothing sellable in selection'
                    or 'check items to sell'
                return
            end
            pending = { op = 'masssell', names = names, i = 1, sold = 0 }
            status = skipped > 0
                and string.format('selling %d (skipped %d)...', #names, skipped)
                or string.format('selling %d...', #names)
            return
        elseif op == 'massdelete' then
            if merchantOpen() then
                status = 'close vendor before Delete'
                return
            end
            if view == 'bank' and not bankOpen() then
                status = 'open bank to delete from bank'
                return
            end
            if view ~= 'bags' and view ~= 'bank' then
                status = 'Delete is Bags or Bank only'
                return
            end
            local names = checkedNames(view)
            if #names == 0 then
                status = 'check items to delete'
                return
            end
            queueMassDestroy(names, view)
            status = string.format('deleting %d...', #names)
            return
        elseif op == 'massmove' then
            if merchantOpen() then
                status = 'close vendor before Move'
                return
            end
            local where = view
            local names = checkedNames(where, true)
            if #names == 0 then
                status = 'check items to move'
                return
            end
            pending = {
                op = 'massmove',
                toBank = (where == 'bags'),
                names = names,
                i = 1,
                moved = 0,
            }
            status = string.format('moving %d...', #names)
            return
        elseif op == 'turnin' then
            if view ~= 'bags' then
                status = 'Turn-In is bags only'
                return
            end
            if (mq.TLO.Target.ID() or 0) <= 0 then
                status = 'target an NPC first'
                return
            end
            local names = checkedNames('bags', true)
            if #names == 0 then
                status = 'check items to turn in'
                return
            end
            local tname = ''
            pcall(function()
                tname = trim(mq.TLO.Target.CleanName() or mq.TLO.Target.Name() or '')
            end)
            if tname == '' or tname == 'NULL' then tname = 'target' end
            turninConfirm = { names = names, target = tname }
            return
        elseif op == 'turningo' then
            -- VF: Starts after confirm popup.
            local names = turninConfirm and turninConfirm.names or checkedNames('bags', true)
            turninConfirm = nil
            if view ~= 'bags' then
                status = 'Turn-In is bags only'
                return
            end
            if (mq.TLO.Target.ID() or 0) <= 0 then
                status = 'target an NPC first'
                return
            end
            if not names or #names == 0 then
                status = 'check items to turn in'
                return
            end
            pending = { op = 'turnin', names = names, i = 1, done = 0 }
            status = string.format('turning in %d stacks...', #names)
            return
        elseif op == 'inspect' then
            pcall(inspectItem, row)
        elseif op == 'destroy' then
            pcall(armDestroy, row)
        elseif op == 'pick' then
            pcall(pickup, row, false)
            if pending then return end
        elseif op == 'pickone' then
            pcall(pickup, row, true)
            if pending then return end
        elseif op == 'sell' or op == 'scribeall' or op == 'memall' then
            pending = { op = op, row = row }
            return
        end
        lastScan = 0
    end

    local function setOpen(v)
        openGUI = not not v
        if openGUI then lastScan = 0 end
    end

    local app = {}

    function app.isOpen()
        return openGUI
    end

    function app.toggle()
        setOpen(not openGUI)
        return openGUI
    end

    function app.setOpen(v)
        setOpen(v)
    end

    function app.hasPending()
        return pending ~= nil or destroyArmed ~= nil or #massDestroyQ > 0
    end

    local lastLockReload = 0

    function app.tick()
        pcall(flushLocks)
        if not locksDirty and (os.clock() - lastLockReload) > 2.0 then
            lastLockReload = os.clock()
            pcall(reloadLocks)
        end
        pcall(tickBankWatch)
        pcall(tickScribe)
        finishDestroy()
        pcall(tickMassDestroy)
        if pending then
            local job = pending
            if job.op == 'sell' then
                pending = nil
                pcall(sell, job.row)
            elseif job.op == 'scribeall' or job.op == 'memall' then
                pending = nil
                pcall(queueScribeAll)
            elseif job.op == 'movetobank' then
                pending = nil
                pcall(moveAllNamed, true, job.name)
            elseif job.op == 'movetobags' then
                pending = nil
                pcall(moveAllNamed, false, job.name)
            elseif job.op == 'masssell' then
                local i = job.i or 1
                local name = job.names and job.names[i]
                dbg('masssell tick i=%d name=%s sold=%s', i, tostring(name), tostring(job.sold))
                if not name then
                    pending = nil
                    clearChecks()
                    status = string.format('sold %d groups', job.sold or 0)
                    dbg('masssell done sold=%s', tostring(job.sold))
                elseif not merchantOpen() then
                    pending = nil
                    status = 'vendor closed, sold ' .. tostring(job.sold or 0)
                    dbg('masssell abort: vendor closed')
                else
                    local n = sellAllNamed(name) or 0
                    dbg('masssell sellAllNamed(%s)=%d', name, n)
                    job.sold = (job.sold or 0) + (n > 0 and 1 or 0)
                    setChecked('bags', name, false)
                    job.i = i + 1
                    status = string.format('sold %s (%d/%d)', name, i, #(job.names or {}))
                end
            elseif job.op == 'massmove' then
                local i = job.i or 1
                local name = job.names and job.names[i]
                if not name then
                    pending = nil
                    clearChecks()
                    status = string.format('moved %d groups', job.moved or 0)
                elseif merchantOpen() then
                    pending = nil
                    status = 'close vendor first'
                else
                    local n = moveAllNamed(job.toBank, name) or 0
                    job.moved = (job.moved or 0) + (n > 0 and 1 or 0)
                    local where = job.toBank and 'bags' or 'bank'
                    setChecked(where, name, false)
                    job.i = i + 1
                    status = string.format('moved %s (%d/%d)', name, i, #(job.names or {}))
                end
            elseif job.op == 'turnin' then
                -- VF: Plow each checked name until FindItemCount is 0 (handinsingle loop).
                local i = job.i or 1
                local name = job.names and job.names[i]
                if not name then
                    pending = nil
                    clearChecks()
                    status = string.format('turned in %d', job.done or 0)
                elseif (mq.TLO.Target.ID() or 0) <= 0 then
                    pending = nil
                    status = 'no target'
                else
                    local left = 0
                    pcall(function()
                        left = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0
                    end)
                    if left < 1 then
                        setChecked('bags', name, false)
                        job.i = i + 1
                        status = string.format('turn-in (%d/%d)', i, #(job.names or {}))
                    elseif handinOne(name) then
                        job.done = (job.done or 0) + 1
                        status = string.format('turn-in %s (%d left)', name, math.max(0, left - 1))
                        lastScan = 0
                    else
                        setChecked('bags', name, false)
                        job.i = i + 1
                        status = 'turn-in failed: ' .. name
                    end
                end
            elseif job.op == 'pickbank' then
                pending = nil
                local row = job.row
                if row and not row.empty and ensureBankReady() then
                    local loc = rowLoc(row, 1)
                    if pickFromBankLoc(loc, row.name) then
                        status = 'picked ' .. (row.name or '')
                    else
                        status = 'could not pick from bank: ' .. (row.name or '')
                    end
                else
                    status = 'Bank window not open'
                end
            else
                pending = nil
            end
            lastScan = 0
            return
        end
    end

    function app.draw()
        if not openGUI then return end
        finishDestroy()
        scan()
        pushTheme()
        -- VF: Taller default so header + table + AutoInv/Power + Close fit without an outer scrollbar.
        ImGui.SetNextWindowSize(580, 620, ImGuiCond.FirstUseEver)
        pcall(function()
            ImGui.SetNextWindowSizeConstraints(480, 600, 1400, 1200)
        end)
        local winFlags = 0
        local F = ImGuiWindowFlags
        if F and F.NoTitleBar and F.NoCollapse then
            winFlags = bitbor(F.NoTitleBar, F.NoCollapse)
            if F.NoScrollbar then winFlags = bitbor(winFlags, F.NoScrollbar) end
        end
        local opened, shown = ImGui.Begin(brand.windowTitle('Inventory') .. '###vfInv', true, winFlags)
        if shown == nil then shown = opened ~= false end
        if shown then
            if brand.drawHeaderWash then brand.drawHeaderWash() end
            brand.drawHeader('Inventory')
            ImGui.SameLine()
            do
                local btnW, pad = 22, 10
                local lineStart, lineW = 0, 0
                pcall(function() lineStart = ImGui.GetCursorPosX() or 0 end)
                pcall(function()
                    if ImGui.GetContentRegionAvailVec then
                        local a = ImGui.GetContentRegionAvailVec()
                        if a and a.x then lineW = a.x end
                    else
                        local a = ImGui.GetContentRegionAvail()
                        if type(a) == 'number' then
                            lineW = a
                        elseif a and a.x then
                            lineW = a.x
                        end
                    end
                    if lineW < 8 then
                        lineW = (ImGui.GetWindowWidth() or 0) - 20
                    end
                end)
                pcall(function()
                    if lineW > btnW + pad then
                        ImGui.SetCursorPosX(lineStart + lineW - btnW)
                    end
                end)
                if ImGui.SmallButton('?##vfInvHelp') then
                    showHelp = not showHelp
                end
                if ImGui.IsItemHovered() then
                    setTip(showHelp and 'Hide help' or 'Help')
                end
            end
            if brand.drawGradientRule then brand.drawGradientRule() end

            -- VF: Bags | Bank tabs - same TAB_ON / TAB_OFF / TAB_HOVER as mgr.
            local function tabBtn(label, key)
                local on = view == key
                local Col = ImGuiCol or _G.ImGuiCol
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
                    if not on and Col.Text
                        and pcall(ImGui.PushStyleColor, Col.Text, 0.620, 0.540, 0.700, 1) then
                        pushed = pushed + 1
                    end
                end
                if ImGui.Button(label .. '##vfInvTab' .. key, 64, 24) then
                    if view ~= key then
                        view = key
                        clearChecks()
                        lastScan = 0
                        if key == 'bank' then ensureBankOpen() end
                    end
                end
                if pushed > 0 then pcall(ImGui.PopStyleColor, pushed) end
                ImGui.SameLine()
            end
            tabBtn('Bags', 'bags')
            tabBtn('Bank', 'bank')
            ImGui.NewLine()

            ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
                string.format('%d items - %d free - %d packs', used, free, packs))
            if view == 'bank' and not bankOpen() then
                ImGui.SameLine()
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], '- bank closed')
            end

            ImGui.SetNextItemWidth(200)
            filter = ImGui.InputText('##bagfilter', filter or '')
            --[[ VF: Trace - re-enable when debugging sell/moves
            ImGui.SameLine()
            bagTrace = ImGui.Checkbox('Trace##vfInvTrace', bagTrace)
            if ImGui.IsItemHovered() then
                setTip('Trace sell steps to chat')
            end
            --]]
            ImGui.SameLine()
            if ImGui.Button('Refresh##vfInvRefresh', 70, 24) then lastScan = 0 end
            if view == 'bags' then
                ImGui.SameLine()
                local memBusy = (#memQ > 0) or (memExpect ~= nil)
                if memBusy then
                    if ImGui.Button('Stop##vfInvScribeStop', 88, 24) then
                        memQ = {}
                        memExpect = nil
                        memWaitUntil = 0
                        closeSpellBook()
                        closeOpenedPacks()
                        status = string.format('scribe stopped -- %d ok, %d skip, %d fail', memDone, memSkip, memFail)
                    end
                else
                    if ImGui.Button('Scribe All##vfInvScribeAll', 88, 24) then
                        clickNow('scribeall')
                    end
                end
                if ImGui.IsItemHovered() then
                    setTip('Scribe spells, songs, scrolls, and tomes from bags')
                end
                ImGui.SameLine()
                if ImGui.Button('Vault Merchant##vfInvVault', 120, 24) then
                    clickNow('vaultmerch')
                end
                if ImGui.IsItemHovered() then
                    setTip("Summons Triune's Vault Merchant.")
                end
            else
                ImGui.SameLine()
                if ImGui.Button('Open Bank##vfInvOpenBank', 90, 24) then clickNow('openbank') end
            end

            local canSell = merchantOpen()
            local canMutate = not canSell
            local tblFlags = bitbor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg,
                ImGuiTableFlags.ScrollY, ImGuiTableFlags.Resizable,
                ImGuiTableFlags.SizingStretchProp, ImGuiTableFlags.Sortable)
            local NS = ImGuiTableColumnFlags.NoSort or 0
            local DS = ImGuiTableColumnFlags.DefaultSort or 0

            -- VF: Table owns vertical scroll. Reserve slots + Close strip so the window does not clip.
            local SLOT_W, SLOT_H = 104, 54
            local CLOSE_STRIP = 48
            local FOOTER_H = SLOT_H + CLOSE_STRIP
            local bodyH = 280
            pcall(function()
                if ImGui.GetContentRegionAvailVec then
                    local a = ImGui.GetContentRegionAvailVec()
                    bodyH = (a.y or 0) - FOOTER_H
                else
                    local ax, ay = ImGui.GetContentRegionAvail()
                    if type(ax) == 'number' then
                        bodyH = (ay or 0) - FOOTER_H
                    elseif ax and ax.y then
                        bodyH = (ax.y or 0) - FOOTER_H
                    end
                end
            end)
            if bodyH < 140 then bodyH = 140 end

            local function slotChildFlags()
                local wf = 0
                local F = ImGuiWindowFlags
                if F then
                    if F.NoScrollbar then wf = bitbor(wf, F.NoScrollbar) end
                    if F.NoScrollWithMouse then wf = bitbor(wf, F.NoScrollWithMouse) end
                end
                return wf
            end

            local function drawDropBox(w, h)
                local hasCur = (mq.TLO.Cursor.ID() or 0) > 0
                local cf = (ImGuiChildFlags and ImGuiChildFlags.Borders) or true
                if ImGui.BeginChild('taDropInv', w, h, cf, slotChildFlags()) then
                    if hasCur then
                        local icon = 0
                        pcall(function() icon = tonumber(mq.TLO.Cursor.Icon()) or 0 end)
                        drawIcon(icon)
                        ImGui.SameLine()
                        ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4], 'AutoInv')
                    else
                        ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'AutoInv')
                    end
                    if ImGui.IsWindowHovered() and ImGui.IsMouseClicked(0) then
                        clickNow('autoinv')
                    end
                end
                ImGui.EndChild()
                if ImGui.IsItemHovered() then
                    setTip('/autoinventory')
                end
            end

            -- VF: Triune Power Source. Exp is server custom data; MQ reads TLOs + INI/cache.
            local function drawPowerSourceBox(w, h)
                local info = powerSrc.info()
                local psName = info.name or ''
                local psIcon = info.icon or 0
                local psPct = info.pct
                local cf = (ImGuiChildFlags and ImGuiChildFlags.Borders) or true
                if ImGui.BeginChild('taPowerSrc', w, h, cf, slotChildFlags()) then
                    if psName ~= '' and psName ~= 'NULL' and not info.empty then
                        if psIcon > 0 then
                            drawIcon(psIcon)
                            ImGui.SameLine()
                        end
                        if psPct ~= nil then
                            ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4],
                                string.format('%.1f%%', psPct))
                        else
                            ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], '--%')
                        end
                    else
                        ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Power')
                        ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], '(empty)')
                    end
                    if ImGui.IsWindowHovered() and ImGui.IsMouseClicked(0) then
                        -- VF: Triune unique. Place/pick PowerSource.
                        mq.cmd('/nomodkey /itemnotify powersource leftmouseup')
                        lastScan = 0
                        status = 'power source'
                    end
                end
                ImGui.EndChild()
                if ImGui.IsItemHovered() then
                    local tip = 'Triune Power Source\nClick to place or pick.'
                    if psName ~= '' and psName ~= 'NULL' and not info.empty then
                        tip = psName
                        if psPct ~= nil then
                            tip = tip .. string.format('\n%.2f%% grown', psPct)
                            if info.source and info.source ~= '' then
                                tip = tip .. ' (' .. tostring(info.source) .. ')'
                            end
                        else
                            tip = tip .. '\nGrowth % not on client yet'
                        end
                        tip = tip .. '\nClick to swap'
                    end
                    setTip(tip)
                end
            end

            -- VF: ScrollY needs a positive outer height - -1 inside a child was clipping with no bar.
            if ImGui.BeginTable('taAllBags', 5, tblFlags, 0, bodyH) then
                ImGui.TableSetupColumn('##sel', bitbor(ImGuiTableColumnFlags.WidthFixed, NS), 28)
                ImGui.TableSetupColumn('Item', bitbor(ImGuiTableColumnFlags.WidthStretch, DS), 0, BAG_COL_ITEM)
                ImGui.TableSetupColumn('Qty', ImGuiTableColumnFlags.WidthFixed, 44, BAG_COL_QTY)
                ImGui.TableSetupColumn('Price', ImGuiTableColumnFlags.WidthFixed, 88, BAG_COL_PRICE)
                ImGui.TableSetupColumn('Lock', bitbor(ImGuiTableColumnFlags.WidthFixed, NS), 40, BAG_COL_LOCK)
                pcall(function() ImGui.TableSetupScrollFreeze(0, 1) end)
                ImGui.TableHeadersRow()

                local shown = {}
                for _, row in ipairs(rows) do
                    if matches(row) then shown[#shown + 1] = row end
                end
                local sort_specs = ImGui.TableGetSortSpecs()
                if sort_specs and #shown > 1 then
                    table.sort(shown, function(a, b) return bagSortCmp(a, b, sort_specs) end)
                    pcall(function() sort_specs.SpecsDirty = false end)
                end

                local shownN = 0
                for i, row in ipairs(shown) do
                    shownN = shownN + 1
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    if row.empty then
                        ImGui.Dummy(1, 1)
                    else
                        local where = rowWhere(row)
                        local rowLocked = isLockedRow(row)
                        local on = isChecked(where, row.name)
                        ImGui.PushID(where)
                        ImGui.PushID(tostring(row.id or row.name or ''))
                        local newOn, pressed = ImGui.Checkbox('##chk', on)
                        ImGui.PopID()
                        ImGui.PopID()
                        if pressed then
                            setChecked(where, row.name, newOn and true or false)
                        elseif newOn ~= nil and pressed == nil then
                            setChecked(where, row.name, newOn and true or false)
                        end
                        if rowLocked and ImGui.IsItemHovered() then
                            setTip('Locked')
                        end
                    end
                    ImGui.TableNextColumn()
                    if row.empty then
                        ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], '(empty)')
                    else
                        drawIcon(row.icon)
                        local iconHover = ImGui.IsItemHovered()
                        if iconHover and ImGui.IsMouseClicked((ImGuiMouseButton and ImGuiMouseButton.Right) or 1) then
                            clickNow('inspect', row)
                        end
                        ImGui.SameLine()
                        if ImGui.Selectable(row.name .. '##r' .. i, false) then
                            local ctrl = false
                            pcall(function()
                                local io = ImGui.GetIO()
                                if io and io.KeyCtrl then ctrl = true end
                            end)
                            clickNow(ctrl and 'pickone' or 'pick', row)
                        end
                        if rightClicked() then
                            clickNow('inspect', row)
                        end
                        if iconHover or ImGui.IsItemHovered() then
                            local tip = row.name
                            if isLockedRow(row) then tip = tip .. '\nLocked' end
                            if (row.copies or 1) > 1 then
                                tip = tip .. string.format('\n%d slots, qty %d', row.copies, row.qty or 0)
                            end
                            if row.loc and row.loc ~= '' then tip = tip .. '\n' .. row.loc end
                            tip = tip .. '\nCtrl+click: take 1'
                            setTip(tip)
                        end
                    end
                    ImGui.TableNextColumn()
                    if row.empty then
                        ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], '-')
                    else
                        ImGui.Text(tostring(row.qty))
                    end
                    ImGui.TableNextColumn()
                    ImGui.Text(row.price or '-')
                    ImGui.TableNextColumn()
                    if row.empty then
                        ImGui.Dummy(1, 1)
                    else
                        local lockOn = isLockedRow(row)
                        ImGui.PushID('lock')
                        ImGui.PushID(tostring(row.id or 0))
                        local newLock, lockPressed = ImGui.Checkbox('##lock', lockOn)
                        ImGui.PopID()
                        ImGui.PopID()
                        if lockPressed then
                            setLockedRow(row, newLock and true or false)
                        elseif lockPressed == nil and newLock ~= lockOn then
                            setLockedRow(row, newLock and true or false)
                        end
                        if ImGui.IsItemHovered() then
                            setTip(lockOn and 'Unlock' or 'Lock')
                        end
                    end
                end
                if shownN == 0 then
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Dummy(1, 1)
                    ImGui.TableNextColumn()
                    local emptyMsg = view == 'bank'
                        and (bankOpen() and 'Bank empty.' or 'Open bank first.')
                        or 'No bag items.'
                    ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
                        filter ~= '' and 'No matches.' or emptyMsg)
                    ImGui.TableNextColumn(); ImGui.Dummy(1, 1)
                    ImGui.TableNextColumn(); ImGui.Dummy(1, 1)
                    ImGui.TableNextColumn(); ImGui.Dummy(1, 1)
                end
                ImGui.EndTable()
            end

            -- VF: Left = mass actions + coins; right = Drop | Power on one row spanning both.
            local nChk = countChecked(view)
            local railW = SLOT_W * 2 + 8
            local leftW = 280
            pcall(function()
                local ww = ImGui.GetWindowWidth() or 0
                if ww > railW + 40 then leftW = ww - railW - 28 end
            end)
            if ImGui.BeginChild('taBagsFootL', leftW, SLOT_H, false) then
                if ImGui.SmallButton('All##vfInvChkAll') then
                    local n = 0
                    for _, row in ipairs(rows) do
                        -- VF: All skips locked.
                        if matches(row) and not row.empty and (row.where or view) == view
                            and not isLockedRow(row) then
                            setChecked(rowWhere(row), row.name, true)
                            n = n + 1
                        end
                    end
                    dbg('All checked %d rows view=%s', n, tostring(view))
                end
                if ImGui.IsItemHovered() then setTip('Select All') end
                ImGui.SameLine()
                if ImGui.SmallButton('None##vfInvChkNone') then clearChecks() end
                if ImGui.IsItemHovered() then setTip('Deselect All') end
                ImGui.SameLine()
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], nChk .. ' checked')
                ImGui.SameLine()

                local function massBtn(label, op, enable, tip, w)
                    w = w or 70
                    if not enable then ImGui.BeginDisabled() end
                    if ImGui.Button(label .. '##vfInvMass' .. op, w, 24) then
                        clickNow(op)
                    end
                    if not enable then ImGui.EndDisabled() end
                    if ImGui.IsItemHovered() then setTip(tip) end
                    ImGui.SameLine()
                end
                local sellEn = canSell and view == 'bags'
                massBtn('Sell', 'masssell', sellEn,
                    canSell and (nChk > 0 and 'Sell checked' or 'Check items first')
                        or 'Open a vendor')
                local canDelete = canMutate and (view == 'bags' or (view == 'bank' and bankOpen()))
                massBtn('Delete', 'massdelete', canDelete,
                    canMutate
                        and (view == 'bank' and not bankOpen() and 'Open bank first'
                            or (nChk > 0 and 'Destroy checked' or 'Check items first'))
                        or 'Close vendor first')
                massBtn('Move', 'massmove', canMutate,
                    canMutate
                        and (nChk > 0
                            and (view == 'bags' and 'Move to bank' or 'Move to bags')
                            or 'Check items first')
                        or 'Close vendor first')
                -- VF: Turn-In = handinsingle plow until each checked name is gone.
                if view == 'bags' then
                    local hasTarget = (mq.TLO.Target.ID() or 0) > 0
                    local tip = 'Target an NPC first'
                    if hasTarget and nChk > 0 then
                        tip = 'Hand every checked stack to your target until gone.\nOpens a confirm first.'
                    elseif hasTarget then
                        tip = 'Check items first'
                    end
                    massBtn('Turn-In', 'turnin', nChk > 0 and hasTarget, tip, 76)
                end
                ImGui.NewLine()

                local pp, gp, sp, cp = purseCoins()
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
                    string.format('%s plat   %s gold   %s silver   %s copper',
                        fmtNum(pp), fmtNum(gp), fmtNum(sp), fmtNum(cp)))
                if ImGui.IsItemHovered() then
                    setTip('Purse')
                end
            end
            ImGui.EndChild()
            ImGui.SameLine()
            drawDropBox(SLOT_W, SLOT_H)
            ImGui.SameLine()
            drawPowerSourceBox(SLOT_W, SLOT_H)

            ImGui.Dummy(0, 4)
            if brand.drawSolidRule then brand.drawSolidRule() end
            if status ~= '' then
                ImGui.TextColored(BRAND[1], BRAND[2], BRAND[3], BRAND[4], status)
                ImGui.SameLine()
            end
            local btnW = 80
            local ww = 0
            pcall(function() ww = ImGui.GetWindowWidth() or 0 end)
            if ww < 1 then ww = 560 end
            ImGui.SetCursorPosX(math.max(12, ww - 12 - btnW))
            if ImGui.Button('Close##vfInvClose', btnW, 24) then
                openGUI = false
            end

            -- VF: Turn-In confirm (plow empties stacks).
            if turninConfirm then
                pcall(function() ImGui.OpenPopup('Turn-In###vfInvTurnInConfirm') end)
            end
            pcall(function() ImGui.SetNextWindowSize(420, 280, ImGuiCond.Appearing) end)
            if ImGui.BeginPopupModal('Turn-In###vfInvTurnInConfirm') then
                local conf = turninConfirm
                local names = conf and conf.names or {}
                local tname = conf and conf.target or 'target'
                ImGui.TextWrapped(
                    string.format('Hand these to %s until each stack is gone?', tname))
                ImGui.Dummy(0, 4)
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
                    string.format('%d item name(s)', #names))
                if ImGui.BeginChild('taBagsTurnInList', 0, 120, true) then
                    for _, n in ipairs(names) do
                        ImGui.BulletText(n)
                    end
                end
                ImGui.EndChild()
                ImGui.Dummy(0, 4)
                ImGui.TextWrapped(
                    'This keeps going for each checked name until you have none left. '
                    .. 'Make sure the target is the right NPC.')
                ImGui.Dummy(0, 8)
                if ImGui.Button('Turn-In##vfInvTurnInGo', 100, 24) then
                    ImGui.CloseCurrentPopup()
                    clickNow('turningo')
                end
                ImGui.SameLine()
                if ImGui.Button('Cancel##vfInvTurnInCancel', 80, 24) then
                    turninConfirm = nil
                    ImGui.CloseCurrentPopup()
                end
                ImGui.EndPopup()
            end
        end
        ImGui.End()

        -- VF: Help window from header ?.
        if showHelp then
            ImGui.SetNextWindowSize(420, 480, ImGuiCond.FirstUseEver)
            local helpOpen = true
            local helpShown
            helpOpen, helpShown = ImGui.Begin(
                brand.windowTitle('Inventory Help') .. '###vfInvHelpWin', helpOpen)
            if helpShown == nil then helpShown = helpOpen ~= false end
            if helpOpen == false then showHelp = false end
            if helpShown and showHelp then
                ImGui.TextWrapped(
                    'Bags are the current inventory of the character.')
                ImGui.Dummy(0, 4)
                ImGui.TextWrapped(
                    'Bank is the contents of your bank. This may change depending on the server. '
                    .. 'For actions between the bank and inventory, the bank window needs to be open.')
                ImGui.Dummy(0, 6)
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Items')
                ImGui.BulletText('Left click picks up. Ctrl+click takes one from a stack.')
                ImGui.BulletText('Right click inspects.')
                ImGui.BulletText('Filter narrows the list.')
                ImGui.Dummy(0, 4)
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Actions')
                ImGui.BulletText('Check rows, then Sell, Delete, or Move.')
                ImGui.BulletText('Sell needs a vendor. Delete/Move need it closed.')
                ImGui.BulletText('Lock skips Sell and Delete.')
                ImGui.Dummy(0, 4)
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Turn-In')
                ImGui.TextWrapped(
                    'Target the NPC, check the items, then Turn-In. '
                    .. 'You get a confirm listing the names and the target. '
                    .. 'After confirm it hands one at a time until each checked stack is empty, '
                    .. 'then moves to the next name.')
                ImGui.BulletText('Needs a target.')
                ImGui.BulletText('Runs until depleted. Wrong NPC will still take the items.')
                ImGui.Dummy(0, 4)
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Slots')
                ImGui.BulletText('AutoInv puts the cursor item away.')
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Power Source')
                ImGui.TextWrapped(
                    'Triune-only leveling slot. Growth % comes from the item (cached for the mini bar). '
                    .. 'Swap them here instead of digging bags.')
                ImGui.BulletText('Click with an item on the cursor to place it.')
                ImGui.BulletText('Click a filled slot to pick it up.')
                ImGui.Dummy(0, 4)
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Other')
                ImGui.BulletText('Scribe All learns from bags.')
                ImGui.BulletText('Locks save per character.')
                ImGui.Dummy(0, 8)
                hideTooltips = ImGui.Checkbox('Hide tooltips##vfInvHideTips', hideTooltips)
                ImGui.Dummy(0, 6)
                if ImGui.Button('Close##vfInvHelpClose', 80, 24) then
                    showHelp = false
                end
            end
            ImGui.End()
        end

        popTheme()
    end

    return app
end

return { create = create }
