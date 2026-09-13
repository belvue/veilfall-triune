---@diagnostic disable: undefined-global, undefined-field
-- VF: Inventory UI — entry is /lua run vfi (module alone is not a runner).

local mq = require('mq')
local ImGui = require('ImGui')
local brand = require('vft.brand')
local chat = require('vft.chat')
local invLocks = require('vft.inv.locks')
local powerSrc = require('vft.powersource')
local augs = require('vft.inv.augs')

-- VF: Me.NumBagSlots; this emu is 10. Hardcoding 12 hit Invalid item slot pack11.
local function packCount()
    local n = 10
    pcall(function()
        local v = tonumber(mq.TLO.Me.NumBagSlots())
        if v and v > 0 then n = v end
    end)
    return n
end
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

-- VF: NMS Bank button is CBankWnd::Activate; no pocket, no #vault_bank.
local BANK_ACTIVATE, PINST_BANKWND, PINST_ME, EQ_BASE = 0x6273E0, 0xD1FC90, 0xDD2630, 0x400000

local function activateBankWnd()
    local did = false
    pcall(function()
        local ffi = require('ffi')
        pcall(function() ffi.cdef('void* GetModuleHandleA(const char*);') end)
        local k = ffi.load('kernel32')
        local b = ffi.cast('char*', k.GetModuleHandleA('eqgame.exe'))
        local function A(x) return b + x - EQ_BASE end
        local w = ffi.cast('void**', A(PINST_BANKWND))[0]
        local p = ffi.cast('void**', A(PINST_ME))[0]
        if w ~= ffi.NULL and p ~= ffi.NULL then
            ffi.cast('void(__thiscall*)(void*,void*)', A(BANK_ACTIVATE))(w, p)
            did = true
        end
    end)
    return did
end

local function closeBankWnd()
    pcall(function()
        if mq.TLO.Window('BigBankWnd').Open() then
            mq.cmd('/notify BigBankWnd DoneButton leftmouseup')
        end
        if mq.TLO.Window('BankWnd').Open() then
            mq.cmd('/notify BankWnd DoneButton leftmouseup')
        end
    end)
end

local function jobNeedsBank(job)
    if not job then return false end
    if job.op == 'massmove' or job.op == 'pickbank' then return true end
    if job.op == 'xlcombine' then return true end
    if job.op == 'putcursor' and job.dest == 'bank' then return true end
    if job.op == 'movetobank' or job.op == 'movetobags' then return true end
    return false
end

local function rightClicked()
    local right = (ImGuiMouseButton and ImGuiMouseButton.Right) or 1
    if ImGui.IsItemClicked and ImGui.IsItemClicked(right) then return true end
    return ImGui.IsItemHovered() and ImGui.IsMouseClicked(right)
end

local function create(opts)
    opts = opts or {}
    local hosted = not not opts.hosted
    -- VF: MQ Lua 60 upvalues on draw; mutable state lives on S.
    local S = {}
    S.openGUI = not hosted
    powerSrc.installEvents('VftInvPs')
    powerSrc.refresh()
    S.filter = ''
    S.showEmpty = false
    S.showHelp = false
    S.hideTooltips = false
    S.turninConfirm = nil -- { names=..., target=... } while confirm popup is up
    -- VF: Bags | Bank | Augs | Settings
    S.view = 'bags'
    S.augFamily = 'kera'
    S.augFlavor = nil
    S.includeWorn = true
    S.xlMath = true
    S.checked = {} -- checked[where][name] = true
    -- local bagTrace = false -- VF: re-enable Trace checkbox below when debugging sell/moves
    S.locked = {} -- item id -> name; [Locked] in {server}_{char}_loadout.ini
    S.lockPath = ''
    S.locksDirty = false
    S.lockSaveWarned = false
    S.lastScan = 0
    S.rows = {}
    S.used, S.free, S.packs = 0, 0, 0
    S.pending = nil
    S.jobQ = {}
    S.bankLease = nil
    S.status = ''
    S.bankWatchUntil = 0
    S.bankActivateAt = 0
    S.massDestroyQ = {}
    S.memQ = {}
    S.memWaitUntil = 0
    S.memExpect = nil
    S.memDone, S.memSkip, S.memFail = 0, 0, 0
    S.openedPacks = {}
    local ensurePackOpen -- VF: defined with scribe helpers; sell opens packs first.
    S.animItems = nil
    pcall(function() S.animItems = mq.FindTextureAnimation('A_DragItem') end)

    local function setTip(s)
        if S.hideTooltips or not s or s == '' then return end
        -- VF: MQ SetTooltip runs through format; escape % (e.g. power source 0%).
        ImGui.SetTooltip((tostring(s):gsub('%%', '%%%%')))
    end

    local function drawIcon(icon)
        if not S.animItems or not icon or icon <= 0 then
            ImGui.Dummy(ICON_SIZE, ICON_SIZE)
            return
        end
        local cell = icon - ICON_OFFSET
        if cell < 0 then cell = icon end
        local ok = pcall(function()
            S.animItems:SetTextureCell(cell)
            ImGui.DrawTextureAnimation(S.animItems, ICON_SIZE, ICON_SIZE)
        end)
        if not ok then ImGui.Dummy(ICON_SIZE, ICON_SIZE) end
    end

    local function pushRow(nextRows, row)
        nextRows[#nextRows + 1] = row
    end

    local function scanBags(nextRows, counts)
        for pack = 1, packCount() do
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
                            if S.showEmpty then
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
                else
                    -- VF: Loose item in a pack slot (not a bag). Autoinv often lands here.
                    local name, qty, id, icon, value, nodrop, norent, kind, teachName
                    pcall(function()
                        name = trim(bag.Name())
                        qty = tonumber(bag.Stack()) or 1
                        id = tonumber(bag.ID()) or 0
                        icon = tonumber(bag.Icon()) or 0
                        value = tonumber(bag.Value()) or 0
                        nodrop = not not bag.NoDrop()
                        norent = not not bag.NoRent()
                        kind, teachName = scrollInfo(bag)
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
                            pack = pack,
                            slot = 0,
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
                            loc = 'pack' .. pack,
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
                            if S.showEmpty then
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
        if not force and (now - S.lastScan) < SCAN_SEC then return end
        S.lastScan = now
        if S.view ~= 'bags' and S.view ~= 'bank' and S.view ~= 'augs' and S.view ~= 'settings' then
            S.view = 'bags'
        end
        if S.view == 'settings' then return end
        local nextRows = {}
        local counts = { used = 0, free = 0, packs = 0 }
        if S.view == 'bags' then scanBags(nextRows, counts) end
        if S.view == 'bank' then scanBank(nextRows, counts) end
        if S.view == 'augs' then
            scanBags(nextRows, counts)
            scanBank(nextRows, counts)
            -- VF: always list equipped augs in Loc; Settings includeWorn only changes shopping counts.
            augs.scanWorn(function(r) pushRow(nextRows, r) end)
        end
        nextRows = consolidateRows(nextRows)
        table.sort(nextRows, function(a, b)
            if (a.empty and not b.empty) then return false end
            if (b.empty and not a.empty) then return true end
            if (a.name or '') ~= (b.name or '') then return (a.name or '') < (b.name or '') end
            return (a.loc or '') < (b.loc or '')
        end)
        S.rows, S.used, S.free, S.packs = nextRows, counts.used, counts.free, counts.packs
    end

    local function rowLoc(row, idx)
        idx = idx or 1
        if row.locs and row.locs[idx] then return row.locs[idx] end
        return { pack = row.pack, slot = row.slot, bank = row.bank, qty = row.qty }
    end

    local function findFirstLoc(where, name, skipPack)
        skipPack = tonumber(skipPack) or 0
        local tmp, counts = {}, { used = 0, free = 0, packs = 0 }
        if where == 'bags' then
            scanBags(tmp, counts)
        else
            scanBank(tmp, counts)
        end
        for _, r in ipairs(tmp) do
            if not r.empty and r.name == name then
                if skipPack <= 0 or (tonumber(r.pack) or 0) ~= skipPack then
                    return { pack = r.pack, slot = r.slot, bank = r.bank, qty = tonumber(r.qty) or 1 }
                end
            end
        end
        return nil
    end

    local function ensureBankOpen()
        if bankOpen() then
            S.bankWatchUntil = 0
            S.bankActivateAt = 0
            return true
        end
        activateBankWnd()
        if bankOpen() then
            S.bankWatchUntil = 0
            S.bankActivateAt = 0
            return true
        end
        S.status = 'opening bank...'
        S.bankActivateAt = os.clock() + 0.3
        S.bankWatchUntil = os.clock() + BANK_WAIT
        return false
    end

    local function tickBankWatch()
        if S.bankWatchUntil <= 0 then return end
        if bankOpen() then
            S.bankWatchUntil = 0
            S.bankActivateAt = 0
            S.lastScan = 0
            S.status = ''
            return
        end
        if S.bankActivateAt > 0 and os.clock() >= S.bankActivateAt then
            activateBankWnd()
            S.bankActivateAt = os.clock() + 0.5
        end
        if os.clock() >= S.bankWatchUntil then
            S.bankWatchUntil = 0
            S.bankActivateAt = 0
            S.status = 'Bank window not open'
        end
    end

    local function beginBankLease()
        S.bankLease = S.bankLease or { owned = true }
    end

    -- VF: Close after our bank jobs. Do not keep it open for the Bank/Augs tabs.
    local function endBankLease()
        if S.pending or (S.jobQ and #S.jobQ > 0) then return end
        if S.destroyArmed or (S.massDestroyQ and #S.massDestroyQ > 0) then return end
        if S.bankLease then
            closeBankWnd()
            S.bankWatchUntil = 0
            S.bankActivateAt = 0
        end
        S.bankLease = nil
    end

    local function enqueueJob(job)
        if not job then return end
        if jobNeedsBank(job) then beginBankLease() end
        if S.pending then
            if S.pending.op == 'massmove' and job.op == 'massmove' and S.pending.toBank == job.toBank then
                for _, n in ipairs(job.names or {}) do
                    S.pending.names[#S.pending.names + 1] = n
                end
                S.status = string.format('queued %d...', #(S.pending.names or {}))
                return
            end
            S.jobQ[#S.jobQ + 1] = job
            S.status = string.format('queued (%d)', #S.jobQ)
            return
        end
        S.pending = job
    end

    local function pumpJobs()
        if S.pending then return end
        if S.jobQ and #S.jobQ > 0 then
            local n = table.remove(S.jobQ, 1)
            S.pending = n
            if jobNeedsBank(n) then beginBankLease() end
        end
    end

    local function rowWhere(row)
        return (row and row.where) or S.view or 'bags'
    end

    local function isChecked(where, name)
        local t = S.checked[where or '']
        return not not (t and name and t[name])
    end

    local function setChecked(where, name, on)
        where = where or S.view or 'bags'
        if not name or name == '' then return end
        if on then
            if not S.checked[where] then S.checked[where] = {} end
            S.checked[where][name] = true
        elseif S.checked[where] then
            S.checked[where][name] = nil
        end
    end

    -- VF: Trace left stubbed - uncomment Trace checkbox in draw to re-enable chat logs.
    local function dbg(...) end

    local function clearChecks()
        S.checked = {}
    end

    local function isLockedId(id)
        id = tonumber(id) or 0
        return id > 0 and S.locked[id] ~= nil
    end

    local function isLockedRow(row)
        return row and isLockedId(row.id)
    end

    -- VF: name-only paths (mass queue) - match locked display name or FindItem ID.
    local function isLockedName(name)
        name = trim(name or '')
        if name == '' then return false end
        for id, n in pairs(S.locked) do
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
        S.locked = map or {}
        S.lockPath = path or ''
        local n = 0
        for _ in pairs(S.locked) do n = n + 1 end
        dbg('locks loaded n=%d path=%s migrated=%s', n, tostring(S.lockPath), tostring(migrated))
        if migrated then S.locksDirty = true end
    end

    local function setLockedRow(row, on)
        if not row or row.empty then return end
        local id = tonumber(row.id) or 0
        if id <= 0 then
            S.status = 'no item id to lock'
            return
        end
        local want = not not on
        if want and S.locked[id] then return end
        if (not want) and not S.locked[id] then return end
        if want then
            S.locked[id] = row.name or ''
        else
            S.locked[id] = nil
        end
        S.locksDirty = true
        dbg('lock %s id=%s name=%s', want and 'ON' or 'OFF', tostring(id), tostring(row.name))
        S.status = (want and 'locked ' or 'unlocked ') .. (row.name or tostring(id))
    end

    local function flushLocks()
        if not S.locksDirty then return end
        S.locksDirty = false
        local ok, path = invLocks.save(S.locked)
        S.lockPath = path or S.lockPath
        if not ok and not S.lockSaveWarned then
            S.lockSaveWarned = true
            -- VF: one chat line; UI status still shows detail if needed.
            chat.err('Inv', 'could not write locks -- create vft/config/ (' .. tostring(path) .. ')')
        elseif ok then
            dbg('locks saved path=%s', tostring(path))
        end
    end

    reloadLocks()

    local function checkedNames(where, allowLocked)
        if where == 'augs' then
            local seen, names = {}, {}
            for _, w in ipairs({ 'bags', 'bank' }) do
                for _, n in ipairs(checkedNames(w, allowLocked)) do
                    if not seen[n] then
                        seen[n] = true
                        names[#names + 1] = n
                    end
                end
            end
            table.sort(names)
            return names
        end
        local names = {}
        local t = S.checked[where]
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
        S.lastScan = 0
        scan()
        local keep, skipped = {}, 0
        local t = S.checked[where]
        if not t then return keep, 0 end
        local names = {}
        for name, on in pairs(t) do
            if on and name ~= '' then names[#names + 1] = name end
        end
        for _, name in ipairs(names) do
            local row
            for _, r in ipairs(S.rows) do
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
        if where == 'augs' then
            return countChecked('bags') + countChecked('bank')
        end
        if where then
            local t = S.checked[where]
            if t then
                for _, on in pairs(t) do
                    if on then n = n + 1 end
                end
            end
            return n
        end
        for _, t in pairs(S.checked) do
            for _, on in pairs(t) do
                if on then n = n + 1 end
            end
        end
        return n
    end

    local function matches(row)
        if S.view == 'augs' then
            if row.empty then return false end
            if not augs.listMatch(row.name, S.augFamily, S.augFlavor) then return false end
        end
        local q = S.filter:lower()
        if q == '' then return true end
        if row.empty then return false end
        local hay = ((row.name or '') .. ' ' .. (row.loc or '')):lower()
        return hay:find(q, 1, true)
    end

    -- VF: slot 0 is a loose top-level pack item; `in pack N 0` is invalid.
    local function notifyPackClick(pack, slot, key)
        pack = tonumber(pack) or 0
        slot = tonumber(slot) or 0
        if pack <= 0 then return end
        if slot > 0 then
            mq.cmdf('%s /itemnotify in pack%d %d leftmouseup', key, pack, slot)
        else
            mq.cmdf('%s /itemnotify pack%d leftmouseup', key, pack)
        end
    end

    local function pickup(row, one)
        if not row or row.empty then return end
        local loc = rowLoc(row, 1)
        local w = row.where or 'bags'
        if w == 'worn' then
            S.status = 'worn augs stay in gear'
            return
        end
        if w == 'bags' then
            if (mq.TLO.Cursor.ID() or 0) > 0 then
                mq.cmd('/autoinventory')
                mq.delay(50)
            end
            -- VF: Ctrl+LMB takes one off a stack (same as /ctrlkey itemnotify).
            if one then
                notifyPackClick(loc.pack, loc.slot, '/nomodkey /ctrlkey')
                S.status = 'picked 1 ' .. (row.name or '')
            else
                notifyPackClick(loc.pack, loc.slot, '/nomodkey')
                S.status = 'picked ' .. (row.name or '')
            end
            S.lastScan = 0
        elseif w == 'bank' then
            enqueueJob({ op = 'pickbank', row = row, one = not not one })
            S.status = 'queued pick'
            return
        end
    end

    local function dropToBags(skipPack)
        skipPack = tonumber(skipPack) or 0
        if (mq.TLO.Cursor.ID() or 0) <= 0 then
            S.status = 'cursor empty'
            return false
        end
        for pack = 1, packCount() do
            if pack ~= skipPack then
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
                            S.status = string.format('dropped to pack%d:%d', pack, slot)
                            S.lastScan = 0
                            return true
                        end
                    end
                end
            end
        end
        -- VF: Empty pack slot (no bag/item). Never walk past Me.NumBagSlots (pack11 is invalid here).
        for pack = 1, packCount() do
            if pack ~= skipPack then
                local bag
                pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
                if not (bag and bag()) then
                    mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', pack)
                    S.status = 'dropped to pack' .. pack
                    S.lastScan = 0
                    return true
                end
            end
        end
        mq.cmd('/autoinventory')
        S.status = 'bags full -- autoinv'
        S.lastScan = 0
        return (mq.TLO.Cursor.ID() or 0) <= 0
    end

    -- VF: Never itemnotify bank* unless BankWnd is open - closed bank looks empty and dumps to inv.
    local function placeCursorInBank()
        if (mq.TLO.Cursor.ID() or 0) <= 0 then
            S.status = 'cursor empty'
            return false
        end
        if not bankOpen() then
            S.status = 'bank not open'
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
                            S.status = string.format('dropped to bank%d:%d', b, slot)
                            S.lastScan = 0
                            return true
                        end
                    end
                end
            else
                mq.cmdf('/nomodkey /itemnotify bank%d leftmouseup', b)
                S.status = 'dropped to bank' .. b
                S.lastScan = 0
                return true
            end
        end
        S.status = 'bank full'
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
        activateBankWnd()
        if bankOpen() then
            S.bankWatchUntil = 0
            S.bankActivateAt = 0
            S.status = ''
            return true
        end
        S.status = 'opening bank...'
        local deadline = os.clock() + BANK_WAIT
        local nextAct = os.clock() + 0.3
        while os.clock() < deadline do
            if bankOpen() then
                S.bankWatchUntil = 0
                S.bankActivateAt = 0
                S.status = ''
                return true
            end
            if os.clock() >= nextAct then
                activateBankWnd()
                nextAct = os.clock() + 0.3
            end
            mq.delay(40)
        end
        S.bankWatchUntil = 0
        S.bankActivateAt = 0
        S.status = 'Bank window not open'
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
            S.status = 'Bank window not open'
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
                notifyPackClick(loc.pack, loc.slot, '/nomodkey /shiftkey')
                mq.delay(80)
                acceptQtyQuick()
                if not waitCursor(true, 450) then
                    S.status = 'could not pick ' .. name
                    break
                end
                local got = cursorStack()
                if not placeCursorInBank() then break end
                acceptQtyQuick()
                waitCursor(false, 500)
                units = units + got
            else
                if not pickFromBankLoc(loc, name) then
                    S.status = 'could not pick from bank: ' .. name
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
                    S.status = 'bags full?'
                    break
                end
                units = units + got
            end
            moved = moved + 1
            dbg('move stack name=%s dir=%s slotQty=%s cursorWas=%s',
                name, toBank and 'bank' or 'bags', tostring(wantQty), tostring(units))
            mq.delay(40)
        end
        S.status = string.format('%s %d slot(s) / %d %s',
            toBank and 'banked' or 'bagged', moved, units, name)
        S.lastScan = 0
        return moved
    end

    local function dropToBank()
        if (mq.TLO.Cursor.ID() or 0) <= 0 then
            S.status = 'cursor empty'
            return
        end
        if not ensureBankReady() then
            S.status = 'Bank window not open'
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
        S.status = (ok and 'inspect ' or 'could not inspect ') .. (row.name or '')
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
            S.status = 'inventoried' .. (name ~= '' and (' ' .. name) or '')
        else
            S.status = 'cursor empty'
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
            S.status = 'Sell is bags only'
            return false
        end
        if row.nodrop then
            S.status = row.name .. ' is No Drop'
            return false
        end
        if isLockedRow(row) then
            S.status = row.name .. ' is locked'
            dbg('sell blocked locked %s id=%s', tostring(row.name), tostring(row.id))
            return false
        end
        if not merchantOpen() then
            S.status = 'Sell is off until a trader window is open'
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
            S.status = 'not in bags: ' .. want
            dbg('sell fail: no loc for %s', want)
            return false
        end

        -- VF: Path 1 - E3: leftmouseup in pack selects into MerchantWnd (or puts on cursor on Triune).
        if loc.pack and loc.pack > 0 and loc.slot and loc.slot > 0 then
            ensurePackOpen(loc.pack)
            mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', loc.pack, loc.slot)
        elseif loc.pack and loc.pack > 0 then
            mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', loc.pack)
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
                S.status = 'sold ' .. want
                dbg('sell ok path1 %s', want)
                return true
            end
        end
        clearCursor()

        -- VF: Path 2 - ctrl pickup onto cursor, then MW_Sell_Button.
        if loc.pack and loc.pack > 0 and loc.slot and loc.slot > 0 then
            ensurePackOpen(loc.pack)
            mq.cmdf('/nomodkey /ctrlkey /itemnotify in pack%d %d leftmouseup', loc.pack, loc.slot)
        elseif loc.pack and loc.pack > 0 then
            mq.cmdf('/nomodkey /ctrlkey /itemnotify pack%d leftmouseup', loc.pack)
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
                S.status = 'sold ' .. want
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
                S.status = 'sold ' .. want
                dbg('sell ok path3 %s', want)
                return true
            end
        end

        clearCursor()
        S.status = 'could not sell ' .. want
        dbg('sell fail all paths %s label=%q cursor=%q btn=%s',
            want, selectedLabel(), cursorName(), tostring(sellButtonOk()))
        return false
    end

    -- VF: Sell every copy of a bags item while merchant stays open.
    local function sellAllNamed(name)
        if not name or name == '' then return 0 end
        if not merchantOpen() then
            S.status = 'open a vendor to sell'
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
    S.destroyArmed = nil
    S.massDestroyWhere = 'bags'

    local function armDestroy(row)
        if not row or row.empty then return end
        local w = row.where or 'bags'
        if w ~= 'bags' and w ~= 'bank' then
            S.status = 'Del only from Bags or Bank'
            return
        end
        if w == 'bank' then
            beginBankLease()
            if not ensureBankReady() then
                S.status = 'Bank window not open'
                return
            end
        end
        if isLockedRow(row) then
            S.status = row.name .. ' is locked'
            return
        end
        local loc = rowLoc(row, 1)
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            mq.cmd('/autoinventory')
            waitCursor(false, 200)
        end
        if w == 'bags' then
            notifyPackClick(loc.pack, loc.slot, '/nomodkey /shiftkey')
            mq.delay(80)
            acceptQtyQuick()
            if not waitCursor(true, 450) then
                S.status = 'could not pick ' .. (row.name or '')
                return
            end
        else
            if not pickFromBankLoc(loc, row.name) then
                S.status = 'could not pick from bank: ' .. (row.name or '')
                return
            end
        end
        S.destroyArmed = {
            name = row.name,
            id = row.id or 0,
            at = os.clock(),
            where = w,
        }
        S.status = 'destroying ' .. row.name
    end

    local function finishDestroy()
        if not S.destroyArmed then return false end
        local now = os.clock()
        local curName, curId = '', 0
        pcall(function()
            curName = trim(mq.TLO.Cursor.Name())
            curId = tonumber(mq.TLO.Cursor.ID()) or 0
        end)
        local want = S.destroyArmed.name or ''
        local match = (curName ~= '' and curName == want)
            or (S.destroyArmed.id > 0 and curId == S.destroyArmed.id)
        if match then
            mq.cmd('/destroy')
            S.status = 'destroyed ' .. want
            S.destroyArmed = nil
            S.lastScan = 0
            return true
        end
        local timeout = (S.destroyArmed.where == 'bank') and 2.0 or 1.2
        if (now - (S.destroyArmed.at or now)) > timeout then
            S.status = 'destroy failed -- ' .. want .. ' not on cursor'
            if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
            S.destroyArmed = nil
            return true
        end
        return true
    end

    local function queueMassDestroy(names, where)
        S.massDestroyQ = {}
        S.massDestroyWhere = where or 'bags'
        for _, name in ipairs(names) do
            S.massDestroyQ[#S.massDestroyQ + 1] = name
        end
    end

    local function tickMassDestroy()
        if S.destroyArmed then return end
        local where = S.massDestroyWhere or 'bags'
        while #S.massDestroyQ > 0 do
            local name = S.massDestroyQ[1]
            local loc = findFirstLoc(where, name)
            if not loc then
                table.remove(S.massDestroyQ, 1)
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
        if isOpen then S.openedPacks[pack] = true end
        return isOpen
    end

    local function closeOpenedPacks()
        for pack in pairs(S.openedPacks) do
            pcall(function()
                if mq.TLO.Window('Pack' .. pack).Open() then
                    mq.cmdf('/nomodkey /itemnotify pack%d rightmouseup', pack)
                    mq.delay(60)
                end
            end)
        end
        S.openedPacks = {}
    end

    -- VF: Combine hooks on a table so app.tick stays under 60 upvalues.
    local xlHooks = {
        numPacks = packCount(),
        scan = scan,
        waitCursor = waitCursor,
        acceptQty = acceptQtyQuick,
        dropBags = dropToBags,
        dropBank = dropToBank,
        moveAllNamed = moveAllNamed,
        ensurePackOpen = ensurePackOpen,
        ensureBankReady = ensureBankReady,
        beginBankLease = beginBankLease,
        findFodder = function(name, skip) return findFirstLoc('bags', name, skip) end,
        status = function(s) S.status = s end,
        rows = function() return S.rows end,
    }

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
            S.status = 'cannot scribe -- ' .. why
            return
        end
        S.lastScan = 0
        scan()
        S.memQ = {}
        S.memExpect = nil
        S.memDone, S.memSkip, S.memFail = 0, 0, 0
        S.memWaitUntil = 0
        local seen = {}
        for _, row in ipairs(S.rows) do
            if row and not row.empty and row.kind and (row.where or 'bags') == 'bags' then
                local sn = row.spellName ~= '' and row.spellName or row.name
                local kind = row.kind
                local key = kind .. ':' .. sn:lower()
                if alreadyKnown(kind, sn) then
                    S.memSkip = S.memSkip + 1
                elseif seen[key] then
                    S.memSkip = S.memSkip + 1
                else
                    seen[key] = true
                    -- VF: Store full item name (Spell: Foo) for FindItem / itemnotify.
                    S.memQ[#S.memQ + 1] = {
                        name = row.name,
                        spellName = sn,
                        kind = kind,
                    }
                end
            end
        end
        if #S.memQ == 0 then
            S.status = S.memSkip > 0 and ('nothing new to scribe (skipped ' .. S.memSkip .. ')')
                or 'no scribe items in bags'
            return
        end
        S.status = string.format('scribe queue %d', #S.memQ)
    end

    local function tickScribe()
        if #S.memQ == 0 and not S.memExpect then return end
        local now = os.clock()

        if S.memExpect and scribeLanded(S.memExpect.kind, S.memExpect.spellName) then
            S.memWaitUntil = 0
        end
        if now < S.memWaitUntil then return end

        if S.memExpect then
            if scribeLanded(S.memExpect.kind, S.memExpect.spellName) then
                S.memDone = S.memDone + 1
            else
                S.memFail = S.memFail + 1
            end
            clearCursorQuiet()
            S.memExpect = nil
            S.lastScan = 0
            if #S.memQ == 0 then
                closeSpellBook()
                closeOpenedPacks()
                S.status = string.format('scribe done -- %d ok, %d skip, %d fail', S.memDone, S.memSkip, S.memFail)
                return
            end
        end

        if #S.memQ == 0 then return end

        local why = scribeBlocked()
        if why then
            S.status = 'scribe paused -- ' .. why .. ' (' .. #S.memQ .. ' left)'
            S.memWaitUntil = now + 0.75
            return
        end

        local job
        while #S.memQ > 0 do
            local cand = table.remove(S.memQ, 1)
            if alreadyKnown(cand.kind, cand.spellName) then
                S.memSkip = S.memSkip + 1
            else
                job = cand
                break
            end
        end
        if not job then
            closeSpellBook()
            closeOpenedPacks()
            S.status = string.format('scribe done -- %d ok, %d skip, %d fail', S.memDone, S.memSkip, S.memFail)
            return
        end

        clearCursorQuiet()
        if not rightClickByName(job.name) then
            S.memFail = S.memFail + 1
            S.status = 'not found: ' .. (job.name or '?')
            return
        end
        S.memExpect = job
        S.memWaitUntil = now + ((job.kind == 'disc') and 2.5 or 3.5)
        S.status = string.format('scribing %s (%s, %d left)', job.spellName, job.kind, #S.memQ)
    end

    -- VF: click ops fire in ImGui. Tick handles sell / scribe / bank moves (delays).
    local function clickNow(op, row)
        if op == 'vaultmerch' then
            mq.cmd('/say #vault_merchant')
            S.status = 'summoned vault merchant'
        elseif op == 'openbank' then
            ensureBankOpen()
        elseif op == 'autoinv' then
            mq.cmd('/autoinventory')
            S.status = 'inventoried'
        elseif op == 'dropbags' then
            local cid = mq.TLO.Cursor.ID() or 0
            if cid <= 0 then
                S.view = 'bags'
                S.status = 'bags'
                return
            end
            local nm = ''
            pcall(function() nm = trim(mq.TLO.Cursor.Name()) end)
            enqueueJob({ op = 'putcursor', dest = 'bags', name = nm })
            S.status = 'queued to bags'
        elseif op == 'dropbank' then
            local cid = mq.TLO.Cursor.ID() or 0
            if cid <= 0 then
                S.view = 'bank'
                S.status = 'bank'
                return
            end
            local nm = ''
            pcall(function() nm = trim(mq.TLO.Cursor.Name()) end)
            enqueueJob({ op = 'putcursor', dest = 'bank', name = nm })
            S.status = 'queued to bank'
        elseif op == 'masssell' then
            if merchantOpen() == false then
                S.status = 'open a vendor to Sell'
                return
            end
            if S.view ~= 'bags' then
                S.status = 'Sell is bags-only'
                return
            end
            local names, skipped = pruneChecksForSell('bags')
            if #names == 0 then
                S.status = skipped > 0 and 'nothing sellable in selection'
                    or 'check items to sell'
                return
            end
            S.pending = { op = 'masssell', names = names, i = 1, sold = 0 }
            S.status = skipped > 0
                and string.format('selling %d (skipped %d)...', #names, skipped)
                or string.format('selling %d...', #names)
            return
        elseif op == 'massdelete' then
            if merchantOpen() then
                S.status = 'close vendor before Delete'
                return
            end
            if S.view ~= 'bags' and S.view ~= 'bank' then
                S.status = 'Delete is Bags or Bank only'
                return
            end
            local names = checkedNames(S.view)
            if #names == 0 then
                S.status = 'check items to delete'
                return
            end
            queueMassDestroy(names, S.view)
            S.status = string.format('deleting %d...', #names)
            return
        elseif op == 'massmove' then
            if merchantOpen() then
                S.status = 'close vendor before Move'
                return
            end
            local where = S.view
            local names = checkedNames(where, true)
            if #names == 0 then
                S.status = 'check items to move'
                return
            end
            enqueueJob({
                op = 'massmove',
                toBank = (where == 'bags'),
                names = names,
                i = 1,
                moved = 0,
            })
            S.status = string.format('queued %d...', #names)
            return
        elseif op == 'pullneeded' then
            if merchantOpen() then
                S.status = 'close vendor first'
                return
            end
            S.lastScan = 0
            scan(true)
            local names = augs.neededBankNames(S.rows, S.augFamily, S.includeWorn)
            if #names == 0 then
                S.status = 'nothing to pull'
                return
            end
            enqueueJob({
                op = 'massmove',
                toBank = false,
                names = names,
                i = 1,
                moved = 0,
            })
            S.status = string.format('queued pull %d...', #names)
            return
        elseif op == 'pushtobank' then
            if merchantOpen() then
                S.status = 'close vendor first'
                return
            end
            S.lastScan = 0
            scan(true)
            local names = augs.bagFamilyNames(S.rows, S.augFamily, S.augFlavor)
            if #names == 0 then
                S.status = 'nothing in bags to push'
                return
            end
            enqueueJob({
                op = 'massmove',
                toBank = true,
                names = names,
                i = 1,
                moved = 0,
            })
            S.status = string.format('queued bank %d...', #names)
            return
        elseif op == 'xlcombine' then
            if merchantOpen() then
                S.status = 'close vendor first'
                return
            end
            if not S.augFlavor then
                S.status = 'pick a flavor'
                return
            end
            enqueueJob({
                op = 'xlcombine',
                pack = augs.COMBINE_PACK,
                family = S.augFamily,
                flavor = S.augFlavor,
            })
            S.status = 'queued combine'
            return
        elseif op == 'turnin' then
            if S.view ~= 'bags' then
                S.status = 'Turn-In is bags only'
                return
            end
            if (mq.TLO.Target.ID() or 0) <= 0 then
                S.status = 'target an NPC first'
                return
            end
            local names = checkedNames('bags', true)
            if #names == 0 then
                S.status = 'check items to turn in'
                return
            end
            local tname = ''
            pcall(function()
                tname = trim(mq.TLO.Target.CleanName() or mq.TLO.Target.Name() or '')
            end)
            if tname == '' or tname == 'NULL' then tname = 'target' end
            S.turninConfirm = { names = names, target = tname }
            return
        elseif op == 'turningo' then
            -- VF: Starts after confirm popup.
            local names = S.turninConfirm and S.turninConfirm.names or checkedNames('bags', true)
            S.turninConfirm = nil
            if S.view ~= 'bags' then
                S.status = 'Turn-In is bags only'
                return
            end
            if (mq.TLO.Target.ID() or 0) <= 0 then
                S.status = 'target an NPC first'
                return
            end
            if not names or #names == 0 then
                S.status = 'check items to turn in'
                return
            end
            S.pending = { op = 'turnin', names = names, i = 1, done = 0 }
            S.status = string.format('turning in %d stacks...', #names)
            return
        elseif op == 'inspect' then
            pcall(inspectItem, row)
        elseif op == 'destroy' then
            pcall(armDestroy, row)
        elseif op == 'pick' then
            pcall(pickup, row, false)
            if S.pending then return end
        elseif op == 'pickone' then
            pcall(pickup, row, true)
            if S.pending then return end
        elseif op == 'sell' or op == 'scribeall' or op == 'memall' then
            S.pending = { op = op, row = row }
            return
        end
        S.lastScan = 0
    end

    local function setOpen(v)
        S.openGUI = not not v
        if S.openGUI then S.lastScan = 0 end
    end

    local app = {}

    function app.isOpen()
        return S.openGUI
    end

    function app.toggle()
        setOpen(not S.openGUI)
        return S.openGUI
    end

    function app.setOpen(v)
        setOpen(v)
    end

    function app.hasPending()
        return S.pending ~= nil or S.destroyArmed ~= nil or #S.massDestroyQ > 0 or (S.jobQ and #S.jobQ > 0)
    end

    S.lastLockReload = 0

    function app.tick()
        pcall(flushLocks)
        if not S.locksDirty and (os.clock() - S.lastLockReload) > 2.0 then
            S.lastLockReload = os.clock()
            pcall(reloadLocks)
        end
        pcall(tickBankWatch)
        pcall(function()
            local Up = require('vft.inv.update')
            if Up.tick then Up.tick() end
        end)
        pcall(tickScribe)
        finishDestroy()
        pcall(tickMassDestroy)
        if not S.pending then pumpJobs() end
        if S.pending then
            local job = S.pending
            if job.op == 'sell' then
                S.pending = nil
                pcall(sell, job.row)
            elseif job.op == 'scribeall' or job.op == 'memall' then
                S.pending = nil
                pcall(queueScribeAll)
            elseif job.op == 'movetobank' then
                beginBankLease()
                S.pending = nil
                pcall(moveAllNamed, true, job.name)
            elseif job.op == 'movetobags' then
                beginBankLease()
                S.pending = nil
                pcall(moveAllNamed, false, job.name)
            elseif job.op == 'putcursor' then
                S.pending = nil
                if job.dest == 'bank' then
                    pcall(dropToBank)
                else
                    pcall(dropToBags)
                end
                S.status = (job.dest == 'bank' and 'to bank' or 'to bags')
                    .. ((job.name and job.name ~= '') and (' ' .. job.name) or '')
            elseif job.op == 'masssell' then
                local i = job.i or 1
                local name = job.names and job.names[i]
                dbg('masssell tick i=%d name=%s sold=%s', i, tostring(name), tostring(job.sold))
                if not name then
                    S.pending = nil
                    clearChecks()
                    S.status = string.format('sold %d groups', job.sold or 0)
                    dbg('masssell done sold=%s', tostring(job.sold))
                elseif not merchantOpen() then
                    S.pending = nil
                    S.status = 'vendor closed, sold ' .. tostring(job.sold or 0)
                    dbg('masssell abort: vendor closed')
                else
                    local n = sellAllNamed(name) or 0
                    dbg('masssell sellAllNamed(%s)=%d', name, n)
                    job.sold = (job.sold or 0) + (n > 0 and 1 or 0)
                    setChecked('bags', name, false)
                    job.i = i + 1
                    S.status = string.format('sold %s (%d/%d)', name, i, #(job.names or {}))
                end
            elseif job.op == 'massmove' then
                local i = job.i or 1
                local name = job.names and job.names[i]
                if not name then
                    S.pending = nil
                    clearChecks()
                    S.status = string.format('moved %d groups', job.moved or 0)
                elseif merchantOpen() then
                    S.pending = nil
                    S.status = 'close vendor first'
                else
                    local n = moveAllNamed(job.toBank, name) or 0
                    job.moved = (job.moved or 0) + (n > 0 and 1 or 0)
                    local where = job.toBank and 'bags' or 'bank'
                    setChecked(where, name, false)
                    job.i = i + 1
                    S.status = string.format('moved %s (%d/%d)', name, i, #(job.names or {}))
                end
            elseif job.op == 'turnin' then
                -- VF: Plow each checked name until FindItemCount is 0 (handinsingle loop).
                local i = job.i or 1
                local name = job.names and job.names[i]
                if not name then
                    S.pending = nil
                    clearChecks()
                    S.status = string.format('turned in %d', job.done or 0)
                elseif (mq.TLO.Target.ID() or 0) <= 0 then
                    S.pending = nil
                    S.status = 'no target'
                else
                    local left = 0
                    pcall(function()
                        left = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0
                    end)
                    if left < 1 then
                        setChecked('bags', name, false)
                        job.i = i + 1
                        S.status = string.format('turn-in (%d/%d)', i, #(job.names or {}))
                    elseif handinOne(name) then
                        job.done = (job.done or 0) + 1
                        S.status = string.format('turn-in %s (%d left)', name, math.max(0, left - 1))
                        S.lastScan = 0
                    else
                        setChecked('bags', name, false)
                        job.i = i + 1
                        S.status = 'turn-in failed: ' .. name
                    end
                end
            elseif job.op == 'pickbank' then
                beginBankLease()
                local row = job.row
                if not row or row.empty then
                    S.pending = nil
                    S.status = 'nothing to pick'
                elseif not ensureBankReady() then
                    S.pending = nil
                    S.status = 'Bank window not open'
                else
                    local loc = rowLoc(row, 1)
                    local ok = false
                    if job.one then
                        local bank = tonumber(loc.bank) or 0
                        local slot = tonumber(loc.slot) or 0
                        if bank > 0 then
                            if (mq.TLO.Cursor.ID() or 0) > 0 then
                                mq.cmd('/autoinventory')
                                waitCursor(false, 200)
                            end
                            if slot > 0 then
                                openBankBag(bank)
                                mq.cmdf('/nomodkey /ctrlkey /itemnotify in bank%d %d leftmouseup', bank, slot)
                            else
                                mq.cmdf('/nomodkey /ctrlkey /itemnotify bank%d leftmouseup', bank)
                            end
                            acceptQtyQuick()
                            ok = waitCursor(true, 450)
                        end
                    else
                        ok = pickFromBankLoc(loc, row.name)
                    end
                    S.pending = nil
                    S.status = ok and ('picked ' .. (row.name or ''))
                        or ('could not pick from bank: ' .. (row.name or ''))
                end
            elseif job.op == 'xlcombine' then
                beginBankLease()
                xlHooks.numPacks = packCount()
                local ran, ok, msg = pcall(augs.runCombine, job, xlHooks)
                S.pending = nil
                if not ran then
                    S.status = tostring(ok or 'combine error')
                else
                    S.status = msg or (ok and 'combined' or 'combine failed')
                end
            else
                S.pending = nil
            end
            S.lastScan = 0
        end
        if not S.pending then pumpJobs() end
        if not S.pending then endBankLease() end
    end

    function app.draw()
        if not S.openGUI then return end
        finishDestroy()
        scan()
        pushTheme()
        -- VF: Taller default so header + table + INV/Bank/XP + Close fit without an outer scrollbar.
        ImGui.SetNextWindowSize(720, 640, ImGuiCond.FirstUseEver)
        pcall(function()
            ImGui.SetNextWindowSizeConstraints(520, 600, 1600, 1400)
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
                    S.showHelp = not S.showHelp
                end
                if ImGui.IsItemHovered() then
                    setTip(S.showHelp and 'Hide help' or 'Help')
                end
            end
            if brand.drawGradientRule then brand.drawGradientRule() end

            -- VF: Bags | Bank tabs - same TAB_ON / TAB_OFF / TAB_HOVER as mgr.
            local function tabBtn(label, key)
                local on = S.view == key
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
                if ImGui.Button(label .. '##vfInvTab' .. key, 78, 24) then
                    if S.view ~= key then
                        S.view = key
                        S.filter = ''
                        clearChecks()
                        S.lastScan = 0
                    end
                end
                if pushed > 0 then pcall(ImGui.PopStyleColor, pushed) end
                ImGui.SameLine()
            end
            tabBtn('Bags', 'bags')
            tabBtn('Bank', 'bank')
            tabBtn('Augs', 'augs')
            tabBtn('Settings', 'settings')
            ImGui.NewLine()

            if S.view == 'settings' then
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Inventory')
                S.hideTooltips = ImGui.Checkbox('Hide tooltips##vfInvHideTips', S.hideTooltips)
                ImGui.Separator()
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Augs')
                S.includeWorn = ImGui.Checkbox('Count worn augs##vfInvIncWorn', S.includeWorn)
                if ImGui.IsItemHovered() then
                    setTip('Equipped legendaries count on the left (W and quest total). Off = loose only.')
                end
                S.xlMath = ImGui.Checkbox('XL 16-base math##vfInvXlMath', S.xlMath)
                if ImGui.IsItemHovered() then
                    setTip('Need line uses XL Gnomish Quadramorphic Combinerator (16 base = 1 legendary).')
                end
                ImGui.Separator()
                if augs.vfRunning() then
                    ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
                        'VF is running -- suite Update owns overlay.')
                else
                    local Up = nil
                    pcall(function() Up = require('vft.inv.update') end)
                    if Up then
                        if not Up.state then
                            pcall(function() Up.install() end)
                        end
                        if Up.drawPanel then Up.drawPanel() end
                    else
                        ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
                            'vft.inv.update missing -- /lua run vfi will install it.')
                    end
                end
            else

            if S.view == 'augs' then
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
                    string.format('%d items  bags+bank +gear', S.used))
            else
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
                    string.format('%d items - %d free - %d packs', S.used, S.free, S.packs))
            end
            if (S.view == 'bank' or S.view == 'augs') and not bankOpen() then
                ImGui.SameLine()
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], '- bank closed')
            end

            ImGui.SetNextItemWidth(200)
            S.filter = ImGui.InputText('##bagfilter', S.filter or '')
            --[[ VF: Trace - re-enable when debugging sell/moves
            ImGui.SameLine()
            bagTrace = ImGui.Checkbox('Trace##vfInvTrace', bagTrace)
            if ImGui.IsItemHovered() then
                setTip('Trace sell steps to chat')
            end
            --]]
            ImGui.SameLine()
            if ImGui.Button('Refresh##vfInvRefresh', 70, 24) then S.lastScan = 0 end
            if S.view == 'bags' then
                ImGui.SameLine()
                local memBusy = (#S.memQ > 0) or (S.memExpect ~= nil)
                if memBusy then
                    if ImGui.Button('Stop##vfInvScribeStop', 88, 24) then
                        S.memQ = {}
                        S.memExpect = nil
                        S.memWaitUntil = 0
                        closeSpellBook()
                        closeOpenedPacks()
                        S.status = string.format('scribe stopped -- %d ok, %d skip, %d fail', S.memDone, S.memSkip, S.memFail)
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
            elseif S.view == 'bank' then
                ImGui.SameLine()
                if ImGui.Button('Open Bank##vfInvOpenBank', 90, 24) then clickNow('openbank') end
            else
                ImGui.SameLine()
                if ImGui.Button('Open Bank##vfInvOpenBankAugs', 90, 24) then clickNow('openbank') end
                ImGui.SameLine()
                if ImGui.Button('Pull needed##vfInvPullNeed', 110, 24) then
                    clickNow('pullneeded')
                end
                if ImGui.IsItemHovered() then
                    setTip('Move unfinished-flavor augs from bank into bags.')
                end
                ImGui.SameLine()
                if ImGui.Button('Push to bank##vfInvPushAugs', 120, 24) then
                    clickNow('pushtobank')
                end
                if ImGui.IsItemHovered() then
                    setTip('Move this family\'s augs from bags into the bank. Worn stay in gear.')
                end
                ImGui.SameLine()
                local plan, planErr = nil, 'pick a flavor'
                if S.augFlavor then
                    plan, planErr = augs.xlPlan(S.rows, S.augFamily, S.augFlavor)
                end
                local canCombine = plan ~= nil
                if not canCombine then ImGui.BeginDisabled() end
                if ImGui.Button('Combine##vfInvXlCombine', 88, 24) then
                    clickNow('xlcombine')
                end
                if not canCombine then ImGui.EndDisabled() end
                if ImGui.IsItemHovered() then
                    local tip = planErr or 'pick a flavor'
                    if plan then
                        local tool = (plan.combiner == 'xl') and 'XL Combinerator' or 'Gnomish Combinerator'
                        tip = string.format('Combine %d into %s with the %s (pack 10).',
                            plan.need, plan.result, tool)
                    end
                    setTip(tip)
                end
            end

            local canSell = merchantOpen()
            local canMutate = not canSell
            local tblFlags = bitbor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg,
                ImGuiTableFlags.ScrollY, ImGuiTableFlags.Resizable,
                ImGuiTableFlags.SizingStretchProp, ImGuiTableFlags.Sortable)
            local NS = ImGuiTableColumnFlags.NoSort or 0
            local DS = ImGuiTableColumnFlags.DefaultSort or 0

            -- VF: Table owns vertical scroll. Footer is INV | Bank | XP + Close.
            local SQ, GAP = 50, 6
            local GRID_W = SQ * 3 + GAP * 2
            local GRID_H = 62
            local CLOSE_STRIP = 48
            local FOOTER_H = GRID_H + CLOSE_STRIP
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

            local function drawSq(id, label, onClick, tip, inner)
                local cf = (ImGuiChildFlags and ImGuiChildFlags.Borders) or true
                if ImGui.BeginChild(id, SQ, SQ, cf, slotChildFlags()) then
                    if inner then
                        inner()
                    else
                        local tw = 28
                        pcall(function()
                            local w = ImGui.CalcTextSize(label)
                            if type(w) == 'number' then tw = w
                            elseif w and w.x then tw = w.x end
                        end)
                        local x = math.max(2, (SQ - tw) * 0.5)
                        local y = math.max(2, (SQ - 14) * 0.5)
                        pcall(function() ImGui.SetCursorPos(x, y) end)
                        ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], label)
                    end
                    if ImGui.IsWindowHovered() and ImGui.IsMouseClicked(0) then
                        onClick()
                    end
                end
                ImGui.EndChild()
                if ImGui.IsItemHovered() then setTip(tip) end
            end

            -- VF: Filled slot = item icon; empty shows growth % (or XP).
            local function sqXp()
                local info = powerSrc.info()
                local psName = info.name or ''
                local psIcon = info.icon or 0
                if psName ~= '' and psName ~= 'NULL' and not info.empty and psIcon > 0 then
                    pcall(function() ImGui.SetCursorPos((SQ - ICON_SIZE) * 0.5, (SQ - ICON_SIZE) * 0.5) end)
                    drawIcon(psIcon)
                    return
                end
                local txt = 'XP'
                local col = MUTED
                if info.pct ~= nil then
                    txt = string.format('%.0f%%', info.pct)
                    col = GOOD
                end
                local tw = 28
                pcall(function()
                    local w = ImGui.CalcTextSize(txt)
                    if type(w) == 'number' then tw = w elseif w and w.x then tw = w.x end
                end)
                pcall(function() ImGui.SetCursorPos(math.max(2, (SQ - tw) * 0.5), (SQ - 14) * 0.5) end)
                ImGui.TextColored(col[1], col[2], col[3], col[4], txt)
            end

            -- VF: ScrollY needs a positive outer height - -1 inside a child was clipping with no bar.
            local augsList = true
            if S.view == 'augs' then
                if ImGui.BeginChild('vfAugsNav', 286, bodyH, true) then
                    local shop = {
                        family = S.augFamily,
                        flavor = S.augFlavor,
                        includeWorn = S.includeWorn,
                        xlMath = S.xlMath,
                        rows = S.rows,
                        muted = MUTED,
                        good = GOOD,
                        tabOn = TAB_ON,
                        tabOff = TAB_OFF,
                        tabHover = TAB_HOVER,
                    }
                    augs.drawShop(ImGui, shop)
                    S.augFamily = shop.family
                    S.augFlavor = shop.flavor
                end
                ImGui.EndChild()
                ImGui.SameLine()
                augsList = ImGui.BeginChild('vfAugsList', 0, bodyH, false)
            end
            if augsList and ImGui.BeginTable('taAllBags', 5, tblFlags, 0, S.view == 'augs' and 0 or bodyH) then
                ImGui.TableSetupColumn('##sel', bitbor(ImGuiTableColumnFlags.WidthFixed, NS), 28)
                ImGui.TableSetupColumn('Item', bitbor(ImGuiTableColumnFlags.WidthStretch, DS), 0, BAG_COL_ITEM)
                ImGui.TableSetupColumn('Qty', ImGuiTableColumnFlags.WidthFixed, 44, BAG_COL_QTY)
                ImGui.TableSetupColumn(S.view == 'augs' and 'Loc' or 'Price',
                    ImGuiTableColumnFlags.WidthFixed, S.view == 'augs' and 52 or 88, BAG_COL_PRICE)
                ImGui.TableSetupColumn('Lock', bitbor(ImGuiTableColumnFlags.WidthFixed, NS), 40, BAG_COL_LOCK)
                pcall(function() ImGui.TableSetupScrollFreeze(0, 1) end)
                ImGui.TableHeadersRow()

                local shown = {}
                for _, row in ipairs(S.rows) do
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
                        local showName = row.name
                        local tierCol = nil
                        if S.view == 'augs' then
                            local short, tier = augs.displayName(row.name)
                            if short and short ~= '' then showName = short end
                            if tier and augs.TIER[tier] then tierCol = augs.TIER[tier] end
                        end
                        local pushedTxt = 0
                        if tierCol then
                            local Col = ImGuiCol or _G.ImGuiCol
                            if Col and Col.Text
                                and pcall(ImGui.PushStyleColor, Col.Text, tierCol[1], tierCol[2], tierCol[3], tierCol[4]) then
                                pushedTxt = 1
                            end
                        end
                        if ImGui.Selectable(showName .. '##r' .. i, false) then
                            local ctrl = false
                            pcall(function()
                                local io = ImGui.GetIO()
                                if io and io.KeyCtrl then ctrl = true end
                            end)
                            clickNow(ctrl and 'pickone' or 'pick', row)
                        end
                        if pushedTxt > 0 then pcall(ImGui.PopStyleColor, pushedTxt) end
                        if rightClicked() then
                            clickNow('inspect', row)
                        end
                        if iconHover or ImGui.IsItemHovered() then
                            local tip = row.name
                            if isLockedRow(row) then tip = tip .. '\nLocked' end
                            if (row.copies or 1) > 1 then
                                tip = tip .. string.format('\n%d slots, qty %d', row.copies, row.qty or 0)
                            end
                            if row.loc and row.loc ~= '' then
                                if S.view == 'augs' then
                                    if row.where == 'worn' then
                                        tip = tip .. '\n' .. row.loc
                                    else
                                        tip = tip .. '\n' .. (row.where or '') .. ' ' .. row.loc
                                    end
                                else
                                    tip = tip .. '\n' .. row.loc
                                end
                            end
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
                    if S.view == 'augs' then
                        ImGui.Text(row.empty and '-' or augs.locLabel(row))
                    else
                        ImGui.Text(row.price or '-')
                    end
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
                    local emptyMsg = 'No bag items.'
                    if S.view == 'bank' then
                        emptyMsg = (bankOpen() and 'Bank empty.' or 'Open bank first.')
                    elseif S.view == 'augs' then
                        emptyMsg = 'No augs in this family.'
                    end
                    ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
                        S.filter ~= '' and 'No matches.' or emptyMsg)
                    ImGui.TableNextColumn(); ImGui.Dummy(1, 1)
                    ImGui.TableNextColumn(); ImGui.Dummy(1, 1)
                    ImGui.TableNextColumn(); ImGui.Dummy(1, 1)
                end
                ImGui.EndTable()
            end
            if S.view == 'augs' then ImGui.EndChild() end

            -- VF: Left = mass actions + coins; right = INV | Bank | XP.
            local nChk = countChecked(S.view)
            local railW = GRID_W
            local leftW = 280
            pcall(function()
                local ww = ImGui.GetWindowWidth() or 0
                if ww > railW + 40 then leftW = ww - railW - 28 end
            end)
            if ImGui.BeginChild('taBagsFootL', leftW, GRID_H, false) then
                if ImGui.SmallButton('All##vfInvChkAll') then
                    local n = 0
                    for _, row in ipairs(S.rows) do
                        -- VF: All skips locked.
                        -- VF: All skips locked. Augs rows live in bags/bank, not view='augs'.
                        if matches(row) and not row.empty and not isLockedRow(row)
                            and (S.view == 'augs'
                                and (row.where == 'bags' or row.where == 'bank')
                                or (row.where or S.view) == S.view) then
                            setChecked(rowWhere(row), row.name, true)
                            n = n + 1
                        end
                    end
                    dbg('All checked %d rows view=%s', n, tostring(S.view))
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
                local sellEn = canSell and S.view == 'bags'
                massBtn('Sell', 'masssell', sellEn,
                    canSell and (nChk > 0 and 'Sell checked' or 'Check items first')
                        or 'Open a vendor')
                local canDelete = canMutate and (S.view == 'bags' or S.view == 'bank')
                massBtn('Delete', 'massdelete', canDelete,
                    canMutate
                        and (nChk > 0 and 'Destroy checked' or 'Check items first')
                        or 'Close vendor first')
                massBtn('Move', 'massmove', canMutate,
                    canMutate
                        and (nChk > 0
                            and (S.view == 'bags' and 'Move to bank'
                                or S.view == 'augs' and 'Move checked from bank to bags'
                                or 'Move to bags')
                            or 'Check items first')
                        or 'Close vendor first')
                -- VF: Turn-In = handinsingle plow until each checked name is gone.
                if S.view == 'bags' then
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
            local function sqLabel(label)
                local hasCur = (mq.TLO.Cursor.ID() or 0) > 0
                if hasCur then
                    local icon = 0
                    pcall(function() icon = tonumber(mq.TLO.Cursor.Icon()) or 0 end)
                    pcall(function() ImGui.SetCursorPos((SQ - ICON_SIZE) * 0.5, 4) end)
                    drawIcon(icon)
                    pcall(function() ImGui.SetCursorPos(4, SQ - 16) end)
                    ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4], label)
                else
                    local tw = 28
                    pcall(function()
                        local w = ImGui.CalcTextSize(label)
                        if type(w) == 'number' then tw = w elseif w and w.x then tw = w.x end
                    end)
                    pcall(function() ImGui.SetCursorPos(math.max(2, (SQ - tw) * 0.5), (SQ - 14) * 0.5) end)
                    ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], label)
                end
            end
            local psTip = 'Triune Power Source\nClick to place or pick.'
            pcall(function()
                local info = powerSrc.info()
                local psName = info.name or ''
                if psName ~= '' and psName ~= 'NULL' and not info.empty then
                    psTip = psName
                    if info.pct ~= nil then
                        psTip = psTip .. string.format('\n%.2f%% grown', info.pct)
                    end
                    psTip = psTip .. '\nClick to swap'
                end
            end)
            if ImGui.BeginChild('taBagsFootR', GRID_W, SQ, false, slotChildFlags()) then
                drawSq('vfSqInv', 'INV', function() clickNow('dropbags') end,
                    'Queue cursor into bags. Empty click opens Bags.', function() sqLabel('INV') end)
                ImGui.SameLine(0, GAP)
                drawSq('vfSqBank', 'Bank', function() clickNow('dropbank') end,
                    'Queue cursor into bank. Empty click opens the Bank tab.', function() sqLabel('Bank') end)
                ImGui.SameLine(0, GAP)
                drawSq('vfSqXp', 'XP', function()
                    mq.cmd('/nomodkey /itemnotify powersource leftmouseup')
                    pcall(powerSrc.refresh)
                    S.lastScan = 0
                    S.status = 'power source'
                end, psTip, sqXp)
            end
            ImGui.EndChild()

            end

            ImGui.Dummy(0, 4)
            if brand.drawSolidRule then brand.drawSolidRule() end
            if S.status ~= '' then
                ImGui.TextColored(BRAND[1], BRAND[2], BRAND[3], BRAND[4], S.status)
                ImGui.SameLine()
            end
            local btnW = 80
            local ww = 0
            pcall(function() ww = ImGui.GetWindowWidth() or 0 end)
            if ww < 1 then ww = 560 end
            ImGui.SetCursorPosX(math.max(12, ww - 12 - btnW))
            if ImGui.Button('Close##vfInvClose', btnW, 24) then
                S.openGUI = false
            end

            -- VF: Turn-In confirm (plow empties stacks).
            if S.turninConfirm then
                pcall(function() ImGui.OpenPopup('Turn-In###vfInvTurnInConfirm') end)
            end
            pcall(function() ImGui.SetNextWindowSize(420, 280, ImGuiCond.Appearing) end)
            if ImGui.BeginPopupModal('Turn-In###vfInvTurnInConfirm') then
                local conf = S.turninConfirm
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
                    S.turninConfirm = nil
                    ImGui.CloseCurrentPopup()
                end
                ImGui.EndPopup()
            end
        end
        ImGui.End()

        -- VF: Help window from header ?.
        if S.showHelp then
            ImGui.SetNextWindowSize(420, 480, ImGuiCond.FirstUseEver)
            local helpOpen = true
            local helpShown
            helpOpen, helpShown = ImGui.Begin(
                brand.windowTitle('Inventory Help') .. '###vfInvHelpWin', helpOpen)
            if helpShown == nil then helpShown = helpOpen ~= false end
            if helpOpen == false then S.showHelp = false end
            if helpShown and S.showHelp then
                ImGui.TextWrapped(
                    'Bags are the current inventory of the character.')
                ImGui.Dummy(0, 4)
                ImGui.TextWrapped(
                    'Bank is the contents of your bank. This may change depending on the server. '
                    .. 'The window opens for a move, pick, or delete, then we close it. '
                    .. 'Open Bank is only if you want to look at it.')
                ImGui.Dummy(0, 6)
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Augs')
                ImGui.TextWrapped(
                    'Kera / Seru / Zeb shopping. Goal is one legendary per flavor, including equipped. '
                    .. 'W is gear. Pull needed brings unfinished augs from bank into bags. '
                    .. 'Push to bank sends this family\'s bag augs back. Combine uses pack 10. '
                    .. 'Four identical augs use the Gnomish Combinerator; 16 base uses the XL. '
                    .. 'We empty pack 10, seat the right combiner, bank the result, restore the bag.')
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
                ImGui.BulletText('INV queues a drop into bags. Bank queues a drop into the bank.')
                ImGui.BulletText('The bank window opens only for a transfer, then we close it.')
                ImGui.BulletText('Move / Pull / Push queue every name, including one item.')
                ImGui.BulletText('XP is the Power Source: icon if filled, growth % if empty. Click to swap.')
                ImGui.Dummy(0, 4)
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Other')
                ImGui.BulletText('Scribe All learns from bags.')
                ImGui.BulletText('Locks save per character.')
                ImGui.Dummy(0, 6)
                if ImGui.Button('Close##vfInvHelpClose', 80, 24) then
                    S.showHelp = false
                end
            end
            ImGui.End()
        end

        popTheme()
    end

    -- VF: Standalone overlay. Logo + brand, stretch, bag (/vf inv), fill% green→red, power source %.
    function app.drawHud()
        local hudCol, hudVar = 0, 0
        local begun = false
        local function popHud()
            if hudVar > 0 then pcall(ImGui.PopStyleVar, hudVar) end
            if hudCol > 0 then pcall(ImGui.PopStyleColor, hudCol) end
            hudCol, hudVar = 0, 0
        end
        local ok = pcall(function()
            local Col = ImGuiCol or _G.ImGuiCol
            local SV = ImGuiStyleVar or _G.ImGuiStyleVar
            if Col then
                if pcall(ImGui.PushStyleColor, Col.WindowBg, 0.031, 0.016, 0.055, 0.97) then hudCol = hudCol + 1 end
                if pcall(ImGui.PushStyleColor, Col.Border, 0.275, 0.125, 0.490, 1) then hudCol = hudCol + 1 end
                if pcall(ImGui.PushStyleColor, Col.Text, 0.910, 0.863, 0.784, 1) then hudCol = hudCol + 1 end
                if pcall(ImGui.PushStyleColor, Col.TextDisabled, 0.500, 0.400, 0.620, 1) then hudCol = hudCol + 1 end
                if pcall(ImGui.PushStyleColor, Col.Button, 0.078, 0.035, 0.137, 1) then hudCol = hudCol + 1 end
                if pcall(ImGui.PushStyleColor, Col.ButtonHovered, 0.710, 0.420, 1.000, 0.35) then hudCol = hudCol + 1 end
            end
            if SV then
                if pcall(ImGui.PushStyleVar, SV.WindowRounding, 7) then hudVar = hudVar + 1 end
                local ImVec2Type = _G.ImVec2 or ImVec2
                local function pushVec(id, x, y)
                    local okV
                    if type(ImVec2Type) == 'function' then
                        okV = pcall(ImGui.PushStyleVar, id, ImVec2Type(x, y))
                    else
                        okV = pcall(ImGui.PushStyleVar, id, x, y)
                    end
                    if okV then hudVar = hudVar + 1 end
                end
                if SV.WindowPadding then pushVec(SV.WindowPadding, 10, 6) end
                if SV.ItemSpacing then pushVec(SV.ItemSpacing, 6, 4) end
                if SV.FramePadding then pushVec(SV.FramePadding, 4, 2) end
            end
            ImGui.SetNextWindowSize(520, 36, ImGuiCond.FirstUseEver)
            pcall(function()
                ImGui.SetNextWindowSizeConstraints(300, 36, 1200, 36)
            end)
            local flags = 0
            local F = ImGuiWindowFlags
            if F and F.NoTitleBar and F.NoCollapse then
                flags = bitbor(F.NoTitleBar, F.NoCollapse)
                if F.NoScrollbar then flags = bitbor(flags, F.NoScrollbar) end
            end
            local opened, shown = ImGui.Begin('###vfInvHud', true, flags)
            begun = true
            if shown == nil then shown = opened ~= false end
            if not shown then return end

            if brand.drawHeaderWash then brand.drawHeaderWash() end
            brand.drawHeader()

            local now = os.clock()
            if (now - (S.hudFillAt or 0)) > 0.5 then
                S.hudFillAt = now
                local used, free = 0, 0
                pcall(function()
                    for pack = 1, packCount() do
                        local bag
                        pcall(function() bag = mq.TLO.Me.Inventory('pack' .. pack) end)
                        if bag and bag() then
                            local size = tonumber(bag.Container()) or 0
                            if size > 0 then
                                for slot = 1, size do
                                    local item
                                    pcall(function() item = bag.Item(slot) end)
                                    if item and item() then
                                        used = used + 1
                                    else
                                        free = free + 1
                                    end
                                end
                            else
                                used = used + 1
                            end
                        end
                    end
                end)
                local tot = used + free
                S.hudFillUsed, S.hudFillFree = used, free
                S.hudFillPct = (tot > 0) and ((used / tot) * 100) or 0
            end

            local invPct = tonumber(S.hudFillPct) or 0
            local invTxt = string.format('%d%%', math.floor(invPct + 0.5))
            local info = powerSrc.info()
            local psTxt = '--'
            if info.pct ~= nil then
                psTxt = string.format('%d%%', math.floor(info.pct + 0.5))
            end
            local psCol = powerSrc.tierColor()
            local t = invPct / 100
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local ir = 0.37 + (0.90 - 0.37) * t
            local ig = 0.88 + (0.22 - 0.88) * t
            local ib = 0.64 + (0.25 - 0.64) * t

            local invW, psW = 28, 28
            pcall(function()
                local w = ImGui.CalcTextSize(invTxt)
                if type(w) == 'number' then invW = w elseif w and w.x then invW = w.x end
                w = ImGui.CalcTextSize(psTxt)
                if type(w) == 'number' then psW = w elseif w and w.x then psW = w.x end
            end)
            local bagSz, gap, pad = 20, 8, 10
            local rightW = bagSz + gap + invW + gap + psW
            local ww = ImGui.GetWindowWidth() or 0
            ImGui.SameLine()
            pcall(function()
                local cx = ImGui.GetCursorPosX() or 0
                local target = ww - pad - rightW
                if target > cx + 4 then ImGui.SetCursorPosX(target) end
            end)

            local bagClicked = false
            local usedIcon = false
            pcall(function()
                if not S.hudBagTried then
                    S.hudBagTried = true
                    local dir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
                    local paths = { dir .. '../vf-bag.png', dir .. 'vf-bag.png' }
                    for i = 1, #paths do
                        local tok, tex = pcall(mq.CreateTexture, paths[i])
                        if tok and tex then
                            S.hudBagTex = tex
                            break
                        end
                    end
                end
                local tex = S.hudBagTex
                local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
                if tex and tex.GetTextureID and ImVec2Type then
                    usedIcon = true
                    ImGui.Image(tex:GetTextureID(), ImVec2Type(bagSz, bagSz))
                    if ImGui.IsItemClicked() then bagClicked = true end
                end
            end)
            if not usedIcon then
                if ImGui.SmallButton('Bag##vfInvHudBag') then bagClicked = true end
            end
            if bagClicked then setOpen(not S.openGUI) end
            if ImGui.IsItemHovered() then
                pcall(ImGui.SetTooltip, '/vf inv')
            end

            ImGui.SameLine(0, gap)
            ImGui.TextColored(ir, ig, ib, 1, invTxt)
            if ImGui.IsItemHovered() then
                pcall(ImGui.SetTooltip, string.format('%d used / %d bag slots', S.hudFillUsed or 0,
                    (S.hudFillUsed or 0) + (S.hudFillFree or 0)))
            end

            ImGui.SameLine(0, gap)
            ImGui.TextColored(psCol[1], psCol[2], psCol[3], psCol[4], psTxt)
            if ImGui.IsItemHovered() then
                local psName = info.name or ''
                local tip = 'Triune Power Source'
                if psName ~= '' and not info.empty then
                    tip = psName
                    if info.pct ~= nil then
                        tip = tip .. string.format('\n%.2f%% grown', info.pct)
                    end
                end
                pcall(ImGui.SetTooltip, (tip:gsub('%%', '%%%%')))
            end
        end)
        if begun then pcall(ImGui.End) end
        popHud()
    end

    return app
end

return { create = create }
