-- VF: Settings window. Hosted inside TA or standalone.

local mq = require('mq')
local ImGui = require('ImGui')
local S = require('vft.mgr.schema')
local U = require('vft.mgr.util')
local MeleeCat = require('vft.mgr.melee_catalog')
local brand = require('vft.brand')

local M = {}
local theme = { colN = 0, varN = 0 }

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

-- VF: Deep royal purple / void.
local TAB_ON = { 0.290, 0.140, 0.510, 1 }
local TAB_OFF = { 0.078, 0.035, 0.137, 1 }
local TAB_HOVER = { 0.380, 0.180, 0.620, 1 }

-- VF: InputText returns text, changed — only store when the first return is a string.
local function bindInputText(label, cur)
    local typed = ImGui.InputText(label, tostring(cur or ''))
    if type(typed) == 'string' then return typed end
    return tostring(cur or '')
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
        pushCol(Col.Tab, TAB_OFF[1], TAB_OFF[2], TAB_OFF[3], TAB_OFF[4])
        pushCol(Col.TabHovered, TAB_HOVER[1], TAB_HOVER[2], TAB_HOVER[3], TAB_HOVER[4])
        pushCol(Col.TabSelected, TAB_ON[1], TAB_ON[2], TAB_ON[3], TAB_ON[4])
        pushCol(Col.CheckMark, 0.710, 0.420, 1.000, 1)
        pushCol(Col.SliderGrab, 0.769, 0.627, 0.439, 1)
        pushCol(Col.SliderGrabActive, 0.878, 0.659, 0.471, 1)
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
        pushVar(SV.PopupRounding, 4)
        pushVar(SV.TabRounding, 4)
        pushVar(SV.GrabRounding, 3)
        pushVar(SV.ScrollbarRounding, 6)
        pushVar(SV.FrameBorderSize, 1)
        pushVar(SV.FramePadding, 7, 4)
        pushVar(SV.ItemSpacing, 8, 6)
        pushVar(SV.WindowPadding, 12, 10)
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

local function bitbor(...)
    local acc = 0
    if bit and bit.bor then
        return bit.bor(...)
    end
    for i = 1, select('#', ...) do
        acc = acc + (select(i, ...) or 0)
    end
    return acc
end

-- VF: MQ Combo returns (index, changed).
local function comboIdx(id, cur, items)
    local v = ImGui.Combo(id, cur, items)
    v = tonumber(v) or cur
    return v
end

-- VF: the Mobs picker offers only >= and <=. The strict ops were redundant, not just
-- VF: ugly: schema.mobsToFields already reduces '>N' to min_xtar=N+1 and '<N' to
-- VF: max_xtargets=N-1, so "more than 2" and "at least 3" were always the same stored
-- VF: gate. The engine never sees the operator, only those two numbers.
local MOBS_OPS_UI = { '>=', '<=' }

-- VF: convert a saved strict row in place, losslessly, so old loadouts keep their
-- VF: exact gate while the picker stays two options. parseMobs still reads '<' / '>'
-- VF: off disk, so nothing breaks if a row is edited by hand.
local function normMobsOp(row)
    local n = tonumber(row.mobsN)
    if row.mobsOp == '>' then
        row.mobsOp = '>='
        if n then row.mobsN = tostring(n + 1) end
    elseif row.mobsOp == '<' then
        row.mobsOp = '<='
        if n then row.mobsN = tostring(math.max(n - 1, 0)) end
    end
    if row.mobsOp ~= '>=' and row.mobsOp ~= '<=' then row.mobsOp = '>=' end
end

local function textMuted(s)
    ImGui.TextColored(0.541, 0.439, 0.533, 1, s)
end

local function textWarn(s)
    ImGui.TextColored(1.0, 0.72, 0.30, 1, s)
end

local function textErr(s)
    ImGui.TextColored(1.0, 0.30, 0.30, 1, s)
end

local function textGood(s)
    ImGui.TextColored(0.37, 0.88, 0.64, 1, s)
end

local function setTooltip(txt)
    if txt == nil then return end
    ImGui.SetTooltip('%s', tostring(txt))
end

local function wrapTooltip(txt, width)
    txt = tostring(txt or '')
    if txt == '' then return '' end
    txt = txt:gsub('<[Bb][Rr]%s*/?>', '\n')
    txt = txt:gsub('<[^>]+>', '')
    txt = txt:gsub('\r\n', '\n'):gsub('\r', '\n')
    width = width or 68
    local out = {}
    for para in (txt .. '\n'):gmatch('(.-)\n') do
        para = para:gsub('^%s+', ''):gsub('%s+$', '')
        if para == '' then
            out[#out + 1] = ''
        else
            local line = ''
            for word in para:gmatch('%S+') do
                if line == '' then
                    line = word
                elseif (#line + 1 + #word) > width then
                    out[#out + 1] = line
                    line = word
                else
                    line = line .. ' ' .. word
                end
            end
            if line ~= '' then out[#out + 1] = line end
        end
    end
    return table.concat(out, '\n')
end

local function editRow(row, id, opts)
    opts = opts or {}
    ImGui.TableNextColumn()
    ImGui.SetNextItemWidth(78)
    do
        local n = S.normalizeType and S.normalizeType(row.type)
        if n then row.type = n end
    end
    local ti = U.idxOf(S.TYPES, row.type or 'Buff')
    local newTi = ImGui.Combo('##typ' .. id, ti, S.TYPES)
    newTi = tonumber(newTi) or ti
    if newTi >= 1 and newTi <= #S.TYPES then
        if S.TYPES[newTi] ~= row.type then
            row.type = S.TYPES[newTi]
            row.combat = S.defaultCombat(row.type)
            if not (S.hpBandEditable and S.hpBandEditable(row.type)) then
                row.above = ''
            end
            -- VF: AAs default blank Below (filler); gems/discs keep type default.
            if row.gem == nil and row.via ~= 'disc' then
                row.below = ''
                row.above = ''
            elseif S.defaultBelow then
                row.below = tostring(S.defaultBelow(row.type))
            end
        end
    end
    if ImGui.IsItemHovered() then
        setTooltip('Melee = MQ2Melee skill. Nuke = kill target. Tap = lifetap (my HP %, cast on mob, heal priority). DoT/Debuff = same on-mob gate. CC = Unmezzed Add. Heal = my HP %. HoT = my HP % and missing on buff/short. Cure = only this row; fires when a counter it strips (curse/poison/disease/corruption) is on your bar. Panic = my HP %. PetHeal/PetBuff = your pet. Burn = row checkbox.')
    end

    ImGui.TableNextColumn()
    ImGui.SetNextItemWidth(96)
    local ci = U.idxOf(S.COMBATS, row.combat or 'Always')
    local newCi = ImGui.Combo('##cmb' .. id, ci, S.COMBATS)
    newCi = tonumber(newCi) or ci
    if newCi >= 1 and newCi <= #S.COMBATS then
        row.combat = S.COMBATS[newCi]
    end
    if ImGui.IsItemHovered() then
        setTooltip('When this row may fire.\nAlways = no extra fight gate.\nIn Combat / Out of Combat = require that state.')
    end

    ImGui.TableNextColumn()
    local burn = row.burn and true or false
    local newBurn = ImGui.Checkbox('##brn' .. id, burn)
    row.burn = newBurn and true or false
    if ImGui.IsItemHovered() then
        setTooltip('Burn: only fire this row when Burn is on (Mini /ctrl).')
    end

    ImGui.TableNextColumn()
    do
        local Col = ImGuiCol or _G.ImGuiCol
        local bandOk = not S.hpBandEditable or S.hpBandEditable(row.type)
        local kind = S.hpBandKind and S.hpBandKind(row.type) or 'target'
        local dimN = 0
        if not bandOk then
            pcall(ImGui.BeginDisabled, true)
            if Col and Col.Text and pcall(ImGui.PushStyleColor, Col.Text, 0.45, 0.40, 0.48, 1) then
                dimN = dimN + 1
            end
            if Col and Col.FrameBg and pcall(ImGui.PushStyleColor, Col.FrameBg, 0.035, 0.018, 0.055, 1) then
                dimN = dimN + 1
            end
        end
        ImGui.SetNextItemWidth(42)
        if bandOk then
            row.above = bindInputText('##ab' .. id, row.above or '')
        else
            ImGui.InputText('##ab' .. id, '')
        end
        if ImGui.IsItemHovered() then
            if not bandOk then
                setTooltip('Above/Below not used for this Type (Buff / PetBuff / Summon / Cure).')
            elseif kind == 'self' then
                setTooltip('Above % -- your HP floor. Fire only when your HP is at least this. Empty = no floor.')
            else
                setTooltip('Above % -- target HP floor. Nuke/DoT/Debuff/Melee/CC = mob (PetHeal = pet). Empty = no floor.')
            end
        end

        ImGui.TableNextColumn()
        ImGui.SetNextItemWidth(42)
        if bandOk then
            row.below = bindInputText('##bl' .. id, row.below or '')
        else
            ImGui.InputText('##bl' .. id, row.below or '')
        end
        if not bandOk then
            if dimN > 0 then pcall(ImGui.PopStyleColor, dimN) end
            pcall(ImGui.EndDisabled)
        end
        if ImGui.IsItemHovered() then
            if not bandOk then
                setTooltip('Above/Below not used for this Type (Buff / PetBuff / Summon / Cure).')
            elseif row.gem == nil and row.via ~= 'disc' then
                setTooltip('Below % — blank = combat-only filler (instant AA, enabled only). Set a value to gate on HP.')
            elseif kind == 'self' then
                setTooltip('Below % -- your HP. Fire when your HP is at or below this (Heal / Panic / HoT / Tap).')
            else
                setTooltip('Below % -- target HP. Fire when mob/pet HP is at or below this (Nuke / DoT / Debuff / Melee / CC / PetHeal).')
            end
        end
    end

    ImGui.TableNextColumn()
    do
        -- VF: AA/combat floor is ≥N; Combo+SameLine InputText dropped the typed count on Save.
        local floorOnly = opts.mobsFloor == true
        if row.mobsOp == nil or row.mobsN == nil then
            local op, n = S.mobsPartsFromText(row.mobs)
            row.mobsOp = row.mobsOp or op or '>='
            row.mobsN = row.mobsN or n or ''
        end
        if floorOnly then row.mobsOp = '>=' end
        normMobsOp(row)
        local ops = MOBS_OPS_UI
        local Col = ImGuiCol and ImGuiCol.Text or nil
        local pushed = false
        local composed, okCompose = S.composeMobs(row.mobsOp, row.mobsN)
        row.mobsOk = okCompose ~= false
        if composed then row.mobs = composed end
        if Col then
            if not row.mobsOk then
                pushed = pcall(ImGui.PushStyleColor, Col, 1.0, 0.30, 0.30, 1)
            elseif S.isCeilingMobsRow and S.isCeilingMobsRow(row) then
                pushed = pcall(ImGui.PushStyleColor, Col, 1.0, 0.72, 0.30, 1)
            end
        end
        if floorOnly then
            ImGui.TextDisabled('≥')
            ImGui.SameLine(0, 2)
            ImGui.SetNextItemWidth(36)
            row.mobsN = bindInputText('##mbn' .. id, row.mobsN or '')
            row.mobsOp = '>='
        else
            ImGui.SetNextItemWidth(40)
            local oi = U.idxOf(ops, row.mobsOp or '>=')
            local newOi = ImGui.Combo('##mbop' .. id, oi, ops)
            newOi = tonumber(newOi) or oi
            if newOi >= 1 and newOi <= #ops then
                row.mobsOp = ops[newOi]
            end
            ImGui.SetNextItemWidth(36)
            row.mobsN = bindInputText('##mbn' .. id, row.mobsN or '')
        end
        if pushed then ImGui.PopStyleColor() end
        composed, okCompose = S.composeMobs(row.mobsOp, row.mobsN)
        row.mobsOk = okCompose ~= false
        if composed then row.mobs = composed end
        if ImGui.IsItemHovered() then
            local op = row.mobsOp or '>='
            if not row.mobsOk then
                setTooltip('Mobs number must be empty or a whole number.')
            elseif op == '<=' or op == '<' then
                setTooltip('Ceiling on proximity pack size. Empty number = ignore. <=1 = single only.')
            else
                setTooltip('Fire when mobs in proximity ≥ this count. Blank = default min 1.')
            end
        end
    end

    ImGui.TableNextColumn()
    local en = row.enabled and true or false
    local newEn = ImGui.Checkbox('##en' .. id, en)
    row.enabled = newEn and true or false
    if ImGui.IsItemHovered() then
        setTooltip('Enabled. Off: gems write pct=0. Discs/AAs write enabled=false and pct=0.')
    end
end

local function tableHeader()
    ImGui.TableSetupColumn('Name', ImGuiTableColumnFlags.WidthFixed, 220)
    ImGui.TableSetupColumn('Type', ImGuiTableColumnFlags.WidthFixed, 86)
    ImGui.TableSetupColumn('Combat', ImGuiTableColumnFlags.WidthFixed, 104)
    ImGui.TableSetupColumn('Burn', ImGuiTableColumnFlags.WidthFixed, 40)
    ImGui.TableSetupColumn('Above', ImGuiTableColumnFlags.WidthFixed, 50)
    ImGui.TableSetupColumn('Below', ImGuiTableColumnFlags.WidthFixed, 50)
    ImGui.TableSetupColumn('Mobs', ImGuiTableColumnFlags.WidthFixed, 92)
    ImGui.TableSetupColumn('Enabled', ImGuiTableColumnFlags.WidthFixed, 58)
    ImGui.TableHeadersRow()
end

local function drawSpells(state)
    local prefs = state.prefs
    if type(prefs) ~= 'table' then
        prefs = S.defaultPrefs()
        state.prefs = prefs
    end
    ImGui.TextWrapped('Spell failure lockouts are off — MQ2Cast / next tick retries. (Old Max retries / Lockout sliders removed.)')
    ImGui.Dummy(0, 8)
    local flags = bitbor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('t3Spells', 8, flags) then
        tableHeader()
        local ok, err = pcall(function()
            for i = 1, S.NUM_GEMS do
                local row = state.spellRows[i]
                if row then
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    if row.empty then
                        textMuted(string.format('%2d  (empty)', i))
                    else
                        ImGui.Text(string.format('%2d  %s', i, row.name))
                    end
                    if not row.empty then
                        editRow(row, 'sp' .. i)
                    else
                        for _ = 1, 8 do ImGui.TableNextColumn(); ImGui.Dummy(1, 1) end
                    end
                end
            end
        end)
        ImGui.EndTable()
        if not ok then error(err) end
    end
end

local function skillHoverTip(row, isDisc)
    local tip = row.tooltip
    if not tip or tip == '' then
        pcall(function()
            local sp = mq.TLO.Spell(row.name)
            if sp and sp() and sp.Description then
                tip = tostring(sp.Description() or '')
            end
            if (not tip or tip == '' or tip == 'NULL') and isDisc then
                local ca = mq.TLO.Me.CombatAbility(row.name)
                if ca and ca.Spell and ca.Spell.Description then
                    tip = tostring(ca.Spell.Description() or '')
                end
            end
        end)
        if tip == 'NULL' then tip = '' end
        row.tooltip = tip
    end
    local kind = isDisc and 'Discipline' or 'Ability'
    local pts = tonumber(row.skillPts)
    local head = row.name or kind
    if pts and pts > 0 then
        head = string.format('%s\n%s  skill %d', head, kind, pts)
    else
        head = string.format('%s\n%s', head, kind)
    end
    if not tip or tip == '' then return head end
    return head .. '\n\n' .. tip
end

-- VF: Disc sheet cols — Enabled|Level|Timer(group)|Name|Reuse|Duration|Burn|Boost|Mobs|Health.
local DISC_COL_ENABLED, DISC_COL_LEVEL, DISC_COL_GROUP = 1, 2, 3
local DISC_COL_NAME, DISC_COL_REUSE, DISC_COL_DUR = 4, 5, 6
local DISC_COL_BURN, DISC_COL_BOOST, DISC_COL_MOBS, DISC_COL_HP = 7, 8, 9, 10

local function discCenterCheckbox(id, value)
    local colW = 0
    pcall(function() colW = ImGui.GetColumnWidth() end)
    local box = 18
    if colW > box then
        local x = ImGui.GetCursorPosX()
        ImGui.SetCursorPosX(x + (colW - box) * 0.5)
    end
    return ImGui.Checkbox(id, value)
end

local function discSortCmp(a, b, sort_specs)
    local function cmpStr(x, y)
        x, y = tostring(x or ''), tostring(y or '')
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
            if col == DISC_COL_ENABLED then
                delta = cmpNum(a.enabled and 1 or 0, b.enabled and 1 or 0)
            elseif col == DISC_COL_LEVEL then
                delta = cmpNum(a.level, b.level)
            elseif col == DISC_COL_GROUP then
                delta = cmpNum(a.timerId, b.timerId)
            elseif col == DISC_COL_NAME then
                delta = cmpStr(a.name, b.name)
            elseif col == DISC_COL_REUSE then
                delta = cmpNum(a.cooldownSec, b.cooldownSec)
            elseif col == DISC_COL_DUR then
                delta = cmpNum(a.durationSec, b.durationSec)
            elseif col == DISC_COL_BURN then
                delta = cmpNum(a.burn and 1 or 0, b.burn and 1 or 0)
            elseif col == DISC_COL_BOOST then
                delta = cmpNum(a.boost and 1 or 0, b.boost and 1 or 0)
            elseif col == DISC_COL_MOBS then
                delta = cmpNum(a.mobsN, b.mobsN)
            elseif col == DISC_COL_HP then
                delta = cmpNum(a.below, b.below)
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

local function drawDisciplines(state)
    local rows = {}
    for _, row in ipairs(state.skillRows or {}) do
        if row.via ~= 'skill' then rows[#rows + 1] = row end
    end
    local flags = bitbor(
        ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.SizingFixedFit,
        ImGuiTableFlags.ScrollY, ImGuiTableFlags.Sortable)
    local shown = ImGui.BeginChild('t3DiscChild', 0, 360, true)
    local ok, err = true, nil
    if shown then
        -- VF: EndTable must run even if draw body errors (Missing EndTable pauses ImGui).
        if ImGui.BeginTable('t3Discs', 10, flags) then
            ok, err = pcall(function()
                local W = ImGuiTableColumnFlags.WidthFixed
                local DS = ImGuiTableColumnFlags.DefaultSort or 0
                local NS = ImGuiTableColumnFlags.NoSort or 0
                -- VF: widths fit short labels + sort arrow; no cursor-shift "centering" (it clipped to 1 letter).
                ImGui.TableSetupColumn('On', bitbor(W, NS), 28, DISC_COL_ENABLED)
                ImGui.TableSetupColumn('Lvl', W, 32, DISC_COL_LEVEL)
                ImGui.TableSetupColumn('Tmr', W, 36, DISC_COL_GROUP)
                ImGui.TableSetupColumn('Name', bitbor(W, DS), 200, DISC_COL_NAME)
                ImGui.TableSetupColumn('Reuse', W, 64, DISC_COL_REUSE)
                ImGui.TableSetupColumn('Duration', W, 68, DISC_COL_DUR)
                ImGui.TableSetupColumn('Burn', bitbor(W, NS), 48, DISC_COL_BURN)
                ImGui.TableSetupColumn('Boost', bitbor(W, NS), 52, DISC_COL_BOOST)
                ImGui.TableSetupColumn('Mobs', bitbor(W, NS), 48, DISC_COL_MOBS)
                ImGui.TableSetupColumn('HP', bitbor(W, NS), 40, DISC_COL_HP)
                pcall(function() ImGui.TableSetupScrollFreeze(0, 1) end)
                pcall(ImGui.SetWindowFontScale, 0.86)
                ImGui.TableHeadersRow()
                pcall(ImGui.SetWindowFontScale, 1.0)

                local sort_specs = ImGui.TableGetSortSpecs()
                if sort_specs and #rows > 1 then
                    table.sort(rows, function(a, b) return discSortCmp(a, b, sort_specs) end)
                    pcall(function() sort_specs.SpecsDirty = false end)
                end

                if #rows == 0 then
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Dummy(1, 1)
                    ImGui.TableNextColumn()
                    ImGui.Dummy(1, 1)
                    ImGui.TableNextColumn()
                    ImGui.Dummy(1, 1)
                    ImGui.TableNextColumn()
                    textMuted('No CombatAbility discs found yet.')
                    for _ = 1, 6 do ImGui.TableNextColumn(); ImGui.Dummy(1, 1) end
                else
                    for _, row in ipairs(rows) do
                        -- VF: id by name only — sort must not orphan the active InputText buffer.
                        local id = 'sk_' .. (row.name or '')
                        -- VF: Disc Mobs is ≥N only — force op; never clear N (that wiped typed values).
                        if row.mobsOp ~= '>=' then
                            row.mobsOp = '>='
                        end
                        ImGui.TableNextRow()

                        ImGui.TableNextColumn()
                        local en = row.enabled and true or false
                        row.enabled = discCenterCheckbox('##en' .. id, en) and true or false

                        ImGui.TableNextColumn()
                        local lvl = tonumber(row.level) or 0
                        if lvl > 0 and lvl < 255 then
                            ImGui.Text(tostring(lvl))
                        else
                            textMuted('—')
                        end

                        ImGui.TableNextColumn()
                        local tid = tonumber(row.timerId) or 0
                        if tid > 0 then
                            ImGui.Text(tostring(tid))
                        else
                            textMuted('—')
                        end
                        if ImGui.IsItemHovered() then
                            setTooltip('Cooldown timer group (Combat Skills Timer column).')
                        end

                        ImGui.TableNextColumn()
                        ImGui.Text(row.name or '')
                        if ImGui.IsItemHovered() then
                            setTooltip(wrapTooltip(skillHoverTip(row, true), 68))
                        end

                        ImGui.TableNextColumn()
                        local cd = (row.cooldown and row.cooldown ~= '') and row.cooldown or '—'
                        textMuted(cd)
                        if ImGui.IsItemHovered() then
                            local tip = 'Reuse time.'
                            local left = tonumber(row.cooldownLeft)
                            if left and left > 0.5 then
                                tip = tip .. ' Remaining: ' .. U.fmtHMS(left)
                            end
                            setTooltip(tip)
                        end

                        ImGui.TableNextColumn()
                        local dur = (row.duration and row.duration ~= '') and row.duration or '—'
                        textMuted(dur)
                        if ImGui.IsItemHovered() then
                            setTooltip('Effect duration.')
                        end

                        ImGui.TableNextColumn()
                        local burn = row.burn and true or false
                        row.burn = discCenterCheckbox('##brn' .. id, burn) and true or false
                        if ImGui.IsItemHovered() then setTooltip('Burn: only while Burn is on.') end

                        ImGui.TableNextColumn()
                        local boost = row.boost and true or false
                        row.boost = discCenterCheckbox('##bst' .. id, boost) and true or false
                        if ImGui.IsItemHovered() then
                            setTooltip('Boost stub — saved as boost_only, not fired yet.')
                        end

                        ImGui.TableNextColumn()
                        ImGui.SetNextItemWidth(28)
                        row.mobsN = bindInputText('##mbn' .. id, row.mobsN or '')
                        row.mobsOp = '>='
                        do
                            local composed, okCompose = S.composeMobs('>=', row.mobsN)
                            row.mobsOk = okCompose ~= false
                            if composed then row.mobs = composed end
                        end
                        if ImGui.IsItemHovered() then
                            setTooltip('Fire when mobs in proximity ≥ this count. Blank = default min 1.')
                        end

                        ImGui.TableNextColumn()
                        ImGui.SetNextItemWidth(32)
                        row.below = bindInputText('##bl' .. id, row.below or '')
                        if ImGui.IsItemHovered() then setTooltip('HP% gate. Blank = ungated.') end
                    end
                end
            end)
            ImGui.EndTable()
        end
    end
    ImGui.EndChild()
    if not ok then error(err) end
end

-- VF: same TAB_ON / TAB_OFF / TAB_HOVER as the parent strip in drawPaneTabs -- selected is the
-- VF: bright royal fill, idle is near-black.
local function aaPageBtn(label, key, cur, set, w, h)
    local on = cur == key
    local Col = ImGuiCol or _G.ImGuiCol
    local pushed = 0
    if Col then
        local fill = on and TAB_ON or TAB_OFF
        if pcall(ImGui.PushStyleColor, Col.Button, fill[1], fill[2], fill[3], fill[4]) then
            pushed = pushed + 1
        end
        if pcall(ImGui.PushStyleColor, Col.ButtonHovered, TAB_HOVER[1], TAB_HOVER[2], TAB_HOVER[3], TAB_HOVER[4]) then
            pushed = pushed + 1
        end
        if not on and pcall(ImGui.PushStyleColor, Col.Text, 0.620, 0.540, 0.700, 1) then
            pushed = pushed + 1
        end
    end
    if ImGui.Button(label .. '##aaPg' .. key, w or 88, h or 22) then
        set(key)
    end
    if pushed > 0 then pcall(ImGui.PopStyleColor, pushed) end
end

-- VF: BeginChild always needs EndChild, even when it returns false (same as bags.lua).
local function drawAaChild(id, w, h, fn)
    local shown = ImGui.BeginChild(id, w, h, true)
    if shown then pcall(ImGui.SetWindowFontScale, 0.82) end
    local ok, err = true, nil
    if shown then
        ok, err = pcall(fn)
    end
    pcall(ImGui.SetWindowFontScale, 1.0)
    ImGui.EndChild()
    if not ok then error(err) end
end

local function aaHoverTip(row)
    local tip = row.tooltip
    if not tip or tip == '' then
        pcall(function()
            local aa = mq.TLO.AltAbility(row.name)
            if not aa or not aa() then aa = mq.TLO.Me.AltAbility(row.name) end
            if aa and aa.Description then tip = tostring(aa.Description() or '') end
            if (not tip or tip == '' or tip == 'NULL') and aa and aa.Spell and aa.Spell.Description then
                tip = tostring(aa.Spell.Description() or '')
            end
        end)
        if tip == 'NULL' then tip = '' end
        row.tooltip = tip
    end
    if not tip or tip == '' then
        tip = row.name
    else
        tip = row.name .. '\n\n' .. tip
    end
    return tip
end

local function drawAASettings(state)
    textMuted('Purchased combat AAs (cooldown). List comes from the saved AA book.')
    local flags = bitbor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.SizingFixedFit)
    drawAaChild('t3AASetChild', 780, 360, function()
        if not ImGui.BeginTable('t3AA', 8, flags) then return end
        tableHeader()
        local ok, err = pcall(function()
            if #(state.aaRows or {}) == 0 then
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                if state.aaNeedScan then
                    textMuted(string.format('Building AA book… %d%%', tonumber(state.aaScanPct) or 0))
                else
                    textMuted('No activated AAs in the book.')
                end
                for _ = 1, 7 do ImGui.TableNextColumn(); ImGui.Dummy(1, 1) end
            else
                for _, row in ipairs(state.aaRows) do
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Text(row.name)
                    if ImGui.IsItemHovered() then
                        setTooltip(wrapTooltip(aaHoverTip(row), 68))
                    end
                    if row.cooldown and row.cooldown ~= '' then
                        ImGui.SameLine()
                        textMuted(row.cooldown)
                    end
                    editRow(row, 'aa_' .. (row.name or ''), { mobsFloor = true })
                end
            end
        end)
        ImGui.EndTable()
        if not ok then error(err) end
    end)
end

local gearTex, gearTried
local itemAnim
local ITEM_ICON_OFFSET = 500

local function drawGearButton(id)
    local hit = false
    local size = 16
    pcall(function()
        if not gearTried then
            gearTried = true
            local here = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
            local paths = { here .. '../vf-gear.png', here .. 'vf-gear.png' }
            for i = 1, #paths do
                local ok, tex = pcall(mq.CreateTexture, paths[i])
                if ok and tex then
                    gearTex = tex
                    break
                end
            end
        end
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        if not (gearTex and gearTex.GetTextureID and ImVec2Type and ImGui.ImageButton) then return end
        -- VF: transparent ImageButton — no SetCursorPos (MQ imgui forbids it in tables).
        local SV, Col = ImGuiStyleVar or _G.ImGuiStyleVar, ImGuiCol or _G.ImGuiCol
        local varN, colN = 0, 0
        if SV and SV.FramePadding and pcall(ImGui.PushStyleVar, SV.FramePadding, 0, 0) then
            varN = varN + 1
        end
        if SV and SV.FrameBorderSize and pcall(ImGui.PushStyleVar, SV.FrameBorderSize, 0) then
            varN = varN + 1
        end
        if Col and Col.Button and pcall(ImGui.PushStyleColor, Col.Button, 0, 0, 0, 0) then
            colN = colN + 1
        end
        if Col and Col.ButtonHovered and pcall(ImGui.PushStyleColor, Col.ButtonHovered, 0, 0, 0, 0) then
            colN = colN + 1
        end
        if Col and Col.ButtonActive and pcall(ImGui.PushStyleColor, Col.ButtonActive, 0, 0, 0, 0) then
            colN = colN + 1
        end
        if Col and Col.Border and pcall(ImGui.PushStyleColor, Col.Border, 0, 0, 0, 0) then
            colN = colN + 1
        end
        hit = ImGui.ImageButton('##gear' .. id, gearTex:GetTextureID(), ImVec2Type(size, size))
        if colN > 0 then pcall(ImGui.PopStyleColor, colN) end
        if varN > 0 then pcall(ImGui.PopStyleVar, varN) end
    end)
    if not gearTex then
        if ImGui.SmallButton('...' .. '##gear' .. id) then hit = true end
    end
    return hit
end

local function drawItemIcon(icon, size)
    size = size or 35
    if not itemAnim then
        pcall(function() itemAnim = mq.FindTextureAnimation('A_DragItem') end)
    end
    icon = tonumber(icon) or 0
    if not itemAnim or icon <= 0 then
        ImGui.Dummy(size, size)
        return
    end
    local cell = icon - ITEM_ICON_OFFSET
    if cell < 0 then cell = icon end
    local ok = pcall(function()
        itemAnim:SetTextureCell(cell)
        ImGui.DrawTextureAnimation(itemAnim, size, size)
    end)
    if not ok then ImGui.Dummy(size, size) end
end

local function itemHoverTip(row)
    local parts = { row.name or 'Item' }
    local where = row.where or ''
    local et = row.effectType or ''
    if where ~= '' or et ~= '' then
        local loc = where
        if et ~= '' then
            loc = (loc ~= '' and (loc .. ' · ') or '') .. et
        end
        parts[#parts + 1] = loc
    end
    local spell = row.spell or ''
    if spell ~= '' then
        parts[#parts + 1] = 'Casts: ' .. spell
        local durTxt, beneTxt = '', ''
        pcall(function()
            local sp = mq.TLO.Spell(spell)
            if not (sp and sp()) then return end
            local ticks = tonumber(sp.Duration()) or tonumber(sp.MyDuration()) or 0
            if ticks > 0 then
                durTxt = string.format('Duration: %s (%d ticks)', U.fmtHMS(ticks * 6), ticks)
            end
            local bene = false
            pcall(function() bene = not not sp.Beneficial() end)
            if bene then
                beneTxt = 'Beneficial buff'
            elseif sp.Beneficial then
                beneTxt = 'Detrimental'
            end
            local tip = row.tooltip
            if not tip or tip == '' then
                if sp.Description then
                    tip = tostring(sp.Description() or '')
                    if tip == 'NULL' then tip = '' end
                    row.tooltip = tip
                end
            end
        end)
        if durTxt ~= '' then parts[#parts + 1] = durTxt end
        if beneTxt ~= '' then parts[#parts + 1] = beneTxt end
    end
    local tip = row.tooltip
    if tip and tip ~= '' and tip ~= 'NULL' then
        parts[#parts + 1] = ''
        parts[#parts + 1] = tip
    end
    return table.concat(parts, '\n')
end

local function spellHoverTip(name, cache)
    name = tostring(name or '')
    if name == '' then return '' end
    cache = cache or {}
    if cache[name] then return cache[name] end
    local parts = { name }
    pcall(function()
        local sp = mq.TLO.Spell(name)
        if not (sp and sp()) then return end
        local typ, cat = '', ''
        pcall(function() typ = tostring(sp.SpellType() or '') end)
        pcall(function() cat = tostring(sp.Category() or '') end)
        if typ == 'NULL' then typ = '' end
        if cat == 'NULL' then cat = '' end
        if typ ~= '' or cat ~= '' then
            local line = typ
            if cat ~= '' then line = (line ~= '' and (line .. ' · ') or '') .. cat end
            parts[#parts + 1] = line
        end
        local ticks = tonumber(sp.Duration()) or tonumber(sp.MyDuration()) or 0
        if ticks > 0 then
            parts[#parts + 1] = string.format('Duration: %s (%d ticks)', U.fmtHMS(ticks * 6), ticks)
        end
        local tgt = ''
        pcall(function() tgt = tostring(sp.TargetType() or '') end)
        if tgt ~= '' and tgt ~= 'NULL' then parts[#parts + 1] = 'Target: ' .. tgt end
        local desc = ''
        if sp.Description then
            desc = tostring(sp.Description() or '')
            if desc == 'NULL' then desc = '' end
        end
        if desc ~= '' then
            parts[#parts + 1] = ''
            parts[#parts + 1] = desc
        end
    end)
    local tip = table.concat(parts, '\n')
    cache[name] = tip
    return tip
end

local function drawItemEditor(state)
    local row = state.itemEdit
    if not row then return end

    local id = 'itx_' .. (row.name or '')
    ImGui.BeginChild('##vfItL', 300, 360, true)
        drawItemIcon(row.icon, 35)
        ImGui.SameLine()
        ImGui.BeginGroup()
        ImGui.Text(row.name or 'Item')
        if ImGui.SmallButton('Back##vfItemBack') then
            state.itemEdit = nil
        end
        ImGui.EndGroup()
        ImGui.Dummy(0, 6)
        ImGui.Text('Type')
        ImGui.SetNextItemWidth(160)
        do
            local n = S.normalizeType and S.normalizeType(row.type)
            if n then row.type = n end
            local ti = U.idxOf(S.TYPES, row.type or 'Buff')
            local newTi = ImGui.Combo('##typ' .. id, ti, S.TYPES)
            newTi = tonumber(newTi) or ti
            if newTi >= 1 and newTi <= #S.TYPES and S.TYPES[newTi] ~= row.type then
                row.type = S.TYPES[newTi]
                row.combat = S.defaultCombat(row.type)
                if not (S.hpBandEditable and S.hpBandEditable(row.type)) then
                    row.above = ''
                    row.below = ''
                end
            end
        end
        ImGui.Text('Combat')
        ImGui.SetNextItemWidth(160)
        do
            local ci = U.idxOf(S.COMBATS, row.combat or 'Always')
            local newCi = ImGui.Combo('##cmb' .. id, ci, S.COMBATS)
            newCi = tonumber(newCi) or ci
            if newCi >= 1 and newCi <= #S.COMBATS then
                row.combat = S.COMBATS[newCi]
            end
        end
        ImGui.Dummy(0, 8)
        local spell = row.spell or ''
        if spell ~= '' then
            textMuted('Casts: ' .. spell)
            if ImGui.IsItemHovered() then
                row.spellTips = row.spellTips or {}
                setTooltip(wrapTooltip(spellHoverTip(spell, row.spellTips), 68))
            end
        else
            textMuted('Casts: —')
        end
        if (not row.extraBuffs or #row.extraBuffs == 0) and S.itemExtraBuffs then
            row.extraBuffs = S.itemExtraBuffs(mq, row.name, spell)
        end
        ImGui.Dummy(0, 6)
        local desc = row.tooltip or ''
        if desc == '' or desc == 'NULL' then
            pcall(function()
                if spell == '' then return end
                local sp = mq.TLO.Spell(spell)
                if sp and sp() and sp.Description then
                    desc = tostring(sp.Description() or '')
                    if desc == 'NULL' then desc = '' end
                    row.tooltip = desc
                end
            end)
        end
        if desc ~= '' then
            ImGui.TextWrapped(desc)
        else
            textMuted('No description.')
        end
        ImGui.EndChild()

        ImGui.SameLine()
        ImGui.BeginChild('##vfItR', 290, 360, true)
        local en = row.enabled and true or false
        local hitEn = ImGui.Checkbox('Enabled##' .. id, en)
        if hitEn ~= en then
            row.enabled = hitEn and true or false
            if row.enabled and state.lockItem then state.lockItem(row) end
        end
        ImGui.SameLine(0, 16)
        row.burn = ImGui.Checkbox('Burn##' .. id, row.burn and true or false) and true or false

        ImGui.Dummy(0, 6)
        ImGui.Text('Level')
        ImGui.SameLine()
        ImGui.SetNextItemWidth(48)
        row.levelMin = bindInputText('##lvn' .. id, row.levelMin or '')
        ImGui.SameLine()
        ImGui.SetNextItemWidth(48)
        row.levelMax = bindInputText('##lvx' .. id, row.levelMax or '')
        if ImGui.IsItemHovered() then
            setTooltip('Target level band. Empty = no gate. Skipped on self buffs.')
        end

        ImGui.Text('Mobs')
        ImGui.SameLine()
        do
            if row.mobsOp == nil or row.mobsN == nil then
                local op, n = S.mobsPartsFromText(row.mobs)
                row.mobsOp = row.mobsOp or op or '>='
                row.mobsN = row.mobsN or n or ''
            end
            normMobsOp(row)
            local ops = MOBS_OPS_UI
            ImGui.SetNextItemWidth(48)
            local oi = U.idxOf(ops, row.mobsOp or '>=')
            local newOi = ImGui.Combo('##mbop' .. id, oi, ops)
            newOi = tonumber(newOi) or oi
            if newOi >= 1 and newOi <= #ops then row.mobsOp = ops[newOi] end
            ImGui.SetNextItemWidth(48)
            row.mobsN = bindInputText('##mbn' .. id, row.mobsN or '')
            local composed, okCompose = S.composeMobs(row.mobsOp, row.mobsN)
            row.mobsOk = okCompose ~= false
            if composed then row.mobs = composed end
        end

        ImGui.Text('Health')
        ImGui.SameLine()
        do
            local bandOk = not S.hpBandEditable or S.hpBandEditable(row.type)
            if not bandOk then pcall(ImGui.BeginDisabled, true) end
            ImGui.SetNextItemWidth(48)
            if bandOk then
                row.above = bindInputText('##ab' .. id, row.above or '')
            else
                ImGui.InputText('##ab' .. id, '')
            end
            ImGui.SameLine()
            ImGui.SetNextItemWidth(48)
            if bandOk then
                row.below = bindInputText('##bl' .. id, row.below or '')
            else
                ImGui.InputText('##bl' .. id, row.below or '')
            end
            if not bandOk then pcall(ImGui.EndDisabled) end
            if ImGui.IsItemHovered() then
                setTooltip('Health min / max % (Above / Below). Empty = no gate.')
            end
        end

        ImGui.Dummy(0, 10)
        ImGui.Text('Keep buff')
        if ImGui.IsItemHovered() then
            setTooltip('Bar name we treat as "already up". Mount clickies: blessing after /dismount, not the mount.')
        end
        ImGui.SetNextItemWidth(-1)
        row.keepBuff = bindInputText('##keep' .. id, row.keepBuff or '')
        if ImGui.IsItemHovered() then
            row.spellTips = row.spellTips or {}
            local kn = U.trimName(row.keepBuff)
            if kn ~= '' then
                setTooltip(wrapTooltip(spellHoverTip(kn, row.spellTips), 68))
            else
                setTooltip('Spell name on your bar after the click. Hover Found chips for stats.')
            end
        end
        local extras = row.extraBuffs or {}
        if #extras > 0 then
            textMuted('Found:')
            for i, extra in ipairs(extras) do
                if ImGui.SmallButton(extra .. '##keeppick' .. id .. i) then
                    row.keepBuff = extra
                end
                if ImGui.IsItemHovered() then
                    row.spellTips = row.spellTips or {}
                    setTooltip(wrapTooltip(spellHoverTip(extra, row.spellTips), 68))
                end
            end
        end

        ImGui.Dummy(0, 10)
        ImGui.Text('Custom Commands')
        textMuted('Sent to the client before / after the click.')
        ImGui.Text('Before')
        ImGui.SetNextItemWidth(-1)
        row.cmdBefore = bindInputText('##bef' .. id, row.cmdBefore or '')
        ImGui.Text('After')
        ImGui.SetNextItemWidth(-1)
        row.cmdAfter = bindInputText('##aft' .. id, row.cmdAfter or '')
        ImGui.EndChild()
end

local function drawItems(state, actions)
    if state.itemEdit then
        drawItemEditor(state)
        return
    end
    textMuted('On locks the item in Inventory. Gear opens per-item gates and before/after commands.')
    local flags = bitbor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.SizingFixedFit)
    drawAaChild('t3ItemSetChild', 780, 360, function()
        if not ImGui.BeginTable('t3Items', 6, flags) then return end
        ImGui.TableSetupColumn('On', ImGuiTableColumnFlags.WidthFixed, 36)
        ImGui.TableSetupColumn('Burn', ImGuiTableColumnFlags.WidthFixed, 40)
        ImGui.TableSetupColumn('Name', ImGuiTableColumnFlags.WidthStretch, 220)
        ImGui.TableSetupColumn('Type', ImGuiTableColumnFlags.WidthFixed, 96)
        ImGui.TableSetupColumn('Combat', ImGuiTableColumnFlags.WidthFixed, 110)
        ImGui.TableSetupColumn('Custom', ImGuiTableColumnFlags.WidthFixed, 48)
        ImGui.TableHeadersRow()
        local ok, err = pcall(function()
            if #(state.itemRows or {}) == 0 then
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                textMuted('No clickies found on you (worn or bags).')
                for _ = 1, 5 do ImGui.TableNextColumn(); ImGui.Dummy(1, 1) end
            else
                for _, row in ipairs(state.itemRows) do
                    local id = 'it_' .. (row.name or '')
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    local en = row.enabled and true or false
                    local hitEn = ImGui.Checkbox('##en' .. id, en)
                    if hitEn ~= en then
                        row.enabled = hitEn and true or false
                        if row.enabled and state.lockItem then state.lockItem(row) end
                    end
                    if ImGui.IsItemHovered() then
                        setTooltip('Enabled. On also locks this item in Inventory.')
                    end

                    ImGui.TableNextColumn()
                    row.burn = ImGui.Checkbox('##brn' .. id, row.burn and true or false) and true or false
                    if ImGui.IsItemHovered() then
                        setTooltip('Burn: only fire this row when Burn is on.')
                    end

                    ImGui.TableNextColumn()
                    ImGui.Text(row.name or '')
                    if ImGui.IsItemHovered() then
                        setTooltip(wrapTooltip(itemHoverTip(row), 68))
                    end
                    if row.where == 'missing' then
                        ImGui.SameLine()
                        textMuted('(missing)')
                    elseif row.cooldown and row.cooldown ~= '' then
                        ImGui.SameLine()
                        textMuted(row.cooldown)
                    elseif row.where and row.where ~= '' then
                        ImGui.SameLine()
                        textMuted(row.where)
                    end

                    ImGui.TableNextColumn()
                    ImGui.SetNextItemWidth(90)
                    do
                        local n = S.normalizeType and S.normalizeType(row.type)
                        if n then row.type = n end
                        local ti = U.idxOf(S.TYPES, row.type or 'Buff')
                        local newTi = ImGui.Combo('##typ' .. id, ti, S.TYPES)
                        newTi = tonumber(newTi) or ti
                        if newTi >= 1 and newTi <= #S.TYPES and S.TYPES[newTi] ~= row.type then
                            row.type = S.TYPES[newTi]
                            row.combat = S.defaultCombat(row.type)
                        end
                    end

                    ImGui.TableNextColumn()
                    ImGui.SetNextItemWidth(104)
                    do
                        local ci = U.idxOf(S.COMBATS, row.combat or 'Always')
                        local newCi = ImGui.Combo('##cmb' .. id, ci, S.COMBATS)
                        newCi = tonumber(newCi) or ci
                        if newCi >= 1 and newCi <= #S.COMBATS then
                            row.combat = S.COMBATS[newCi]
                        end
                    end

                    ImGui.TableNextColumn()
                    if drawGearButton(id) then
                        state.itemEdit = row
                    end
                    if ImGui.IsItemHovered() then
                        setTooltip('Custom gates and before/after commands.')
                    end
                end
            end
        end)
        ImGui.EndTable()
        if not ok then error(err) end
    end)
end

local function drawAAPurchase(state)
    if type(state.aaQueue) ~= 'table' then state.aaQueue = S.emptyAaQueue() end
    local q = state.aaQueue
    q.items = q.items or {}
    if q.auto == nil then q.auto = true end

    local pts = 0
    pcall(function() pts = tonumber(mq.TLO.Me.AAPoints()) or 0 end)

    local autoOn = q.auto ~= false
    local hitAuto = ImGui.Checkbox('Enable##aaAuto', autoOn)
    if hitAuto ~= autoOn then
        q.auto = hitAuto and true or false
        if state.flushAaQueue then state.flushAaQueue() end
    end
    if ImGui.IsItemHovered() then
        setTooltip('Buy the checked AAs whenever points allow.\nOff writes an empty list, so nothing buys.')
    end
    ImGui.SameLine(0, 20)
    ImGui.Text(string.format('Unspent: %d', pts))
    -- VF: a missing plugin is the one failure with no other symptom, so it is the only thing
    -- VF: allowed to add a line here.
    local spendOk = false
    pcall(function() spendOk = mq.TLO.Plugin('MQ2AASpend').Name() ~= nil end)
    if not spendOk then
        ImGui.SameLine(0, 20)
        ImGui.TextColored(1.0, 0.45, 0.45, 1.0, 'MQ2AASpend not loaded')
        if ImGui.IsItemHovered() then
            setTooltip('Set mq2aaspend=1 in MacroQuest.ini. Nothing will buy until it loads.')
        end
    end

    if brand.drawSubRule then brand.drawSubRule() end

    local cat = state.aaCat or 'General'
    aaPageBtn('General', 'General', cat, function(v) state.aaCat = v end)
    ImGui.SameLine()
    aaPageBtn('Archetype', 'Archetype', cat, function(v) state.aaCat = v end)
    ImGui.SameLine()
    aaPageBtn('Class', 'Class', cat, function(v) state.aaCat = v end)
    ImGui.SameLine(0, 20)
    if ImGui.Button('Sync##aaSync', 60, 22) then
        if state.requestAaSync then state.requestAaSync() end
    end
    if ImGui.IsItemHovered() then
        setTooltip('Rebuild the AA list from live data.')
    end
    if state.aaNeedScan then
        ImGui.SameLine(0, 12)
        textMuted(string.format('%d%%', tonumber(state.aaScanPct) or 0))
    end

    local rows = (state.aaCatalog and state.aaCatalog[cat]) or {}

    local flags = bitbor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.SizingFixedFit)
    drawAaChild('t3AABuyChild', 640, 360, function()
        if not ImGui.BeginTable('t3AABuy', 4, flags) then return end
        ImGui.TableSetupColumn('Buy', ImGuiTableColumnFlags.WidthFixed, 36)
        ImGui.TableSetupColumn('AA', ImGuiTableColumnFlags.WidthStretch, 260)
        ImGui.TableSetupColumn('Rank', ImGuiTableColumnFlags.WidthFixed, 48)
        ImGui.TableSetupColumn('Cost', ImGuiTableColumnFlags.WidthFixed, 40)
        ImGui.TableHeadersRow()
        local ok, err = pcall(function()
            if #rows == 0 then
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                textMuted(state.aaNeedScan and 'Scanning…' or ('No trainable ' .. cat .. ' AAs.'))
            else
                for _, row in ipairs(rows) do
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    local on = S.aaQueuePri(q, row.name, row.gid) > 0
                    local hit = ImGui.Checkbox('##aaOn_' .. tostring(row.gid or row.name), on)
                    if hit ~= on then
                        if S.setAaQueueOn then
                            S.setAaQueueOn(q, row.name, hit, row.gid)
                        else
                            S.setAaQueuePri(q, row.name, hit and 1 or 0, row.gid)
                        end
                        if state.flushAaQueue then state.flushAaQueue() end
                    end

                    ImGui.TableNextColumn()
                    ImGui.Text(row.name or '')
                    if ImGui.IsItemHovered() then
                        local tip = aaHoverTip(row)
                        if row.canTrain then tip = tip .. '\n\nReady to train.' end
                        setTooltip(wrapTooltip(tip, 68))
                    end

                    ImGui.TableNextColumn()
                    textMuted(tostring(row.owned or 0) .. '/' .. tostring(row.max or 1))

                    ImGui.TableNextColumn()
                    if row.canTrain then
                        textGood(tostring(row.cost or 0))
                    else
                        ImGui.Text(tostring(row.cost or 0))
                    end
                end
            end
        end)
        ImGui.EndTable()
        if not ok then error(err) end
    end)
end

-- VF: boolean MQ2Melee ability toggles — live meleemvi; flips inject /melee key=0|1.
-- VF: default font (Spells/Abilities), not AA's 0.82 scale; wrap to a new column every N rows.
local function drawMeleeAbilities(state, actions)
    actions = actions or {}
    textMuted('Live MQ2Melee state. Checkbox issues /melee key=0|1 (ini + reload only if if= gates change).')
    local rows = MeleeCat.visibleRows(nil)
    if #rows == 0 then
        textMuted('No owned melee abilities for this character.')
        return
    end
    local PER_COL = 10
    local COL_W = 260
    local ROW_H = 26
    local shown = ImGui.BeginChild('t3MeleeChild', 780, 360, true)
    local ok, err = true, nil
    if shown then
        ok, err = pcall(function()
            local originX = ImGui.GetCursorPosX()
            local originY = ImGui.GetCursorPosY()
            for i, row in ipairs(rows) do
                local col = math.floor((i - 1) / PER_COL)
                local rowIn = (i - 1) % PER_COL
                ImGui.SetCursorPos(originX + col * COL_W, originY + rowIn * ROW_H)
                local on = MeleeCat.readLive(row.key) > 0
                local hit = ImGui.Checkbox('##meleeAb_' .. row.key, on)
                if hit ~= on then
                    if actions.meleeSet then
                        actions.meleeSet(row.key, hit)
                    else
                        pcall(function()
                            mq.cmdf('/melee %s=%s', row.key, hit and '1' or '0')
                        end)
                    end
                end
                ImGui.SameLine()
                ImGui.Text(row.label)
                if ImGui.IsItemHovered() and row.help then setTooltip(row.help) end
                ImGui.SameLine()
                textMuted(tostring(MeleeCat.readLive(row.key)))
            end
        end)
    end
    ImGui.EndChild()
    if not ok then error(err) end
end

-- VF: Loadout left rail — Abilities / Spells / Disciplines / AA / Items.
local function drawLoadout(state, actions)
    local page = state.loadoutPage or 'spells'
    if page == 'melee' then page = 'abilities'; state.loadoutPage = 'abilities' end
    local set = function(v)
        if v ~= 'items' or state.loadoutPage == 'items' then
            state.itemEdit = nil
        end
        state.loadoutPage = v
    end
    local navW, navH = 110, 24
    ImGui.BeginGroup()
    aaPageBtn('Abilities', 'abilities', page, set, navW, navH)
    aaPageBtn('Spells', 'spells', page, set, navW, navH)
    aaPageBtn('Disciplines', 'disciplines', page, set, navW, navH)
    aaPageBtn('AA', 'aa', page, set, navW, navH)
    aaPageBtn('Items', 'items', page, set, navW, navH)
    ImGui.EndGroup()
    ImGui.SameLine(0, 10)
    ImGui.BeginGroup()
    if page == 'abilities' then
        drawMeleeAbilities(state, actions)
    elseif page == 'disciplines' then
        drawDisciplines(state)
    elseif page == 'aa' then
        drawAASettings(state)
    elseif page == 'items' then
        drawItems(state, actions)
    elseif page == 'autobuy' then
        -- VF: old session landed here under Loadout; parent AutoBuy owns it now.
        state.pane = 'AutoBuy'
        drawAAPurchase(state)
    else
        drawSpells(state)
    end
    ImGui.EndGroup()
end

local function drawFilters(state)
    local filters = state.filters
    if type(filters) ~= 'table' then
        textMuted('Filters not ready.')
        return
    end
    local live = filters.liveZone or ''
    if live ~= '' then filters.zone = live end
    local curZone = live
    ImGui.Text('Zone: ' .. (curZone ~= '' and curZone or '(unknown)'))
    textMuted('Save writes this zone into filters. TA hunt reads it here.')

    local pack = S.ensureZone(filters, curZone)
    if not pack then
        textMuted('No zone yet -- zone in and this list fills.')
        return
    end

    ImGui.BeginGroup()
    ImGui.Text('Faction')
    if ImGui.Button('Hostile##t3FiltHost', 80, 22) then
        for _, row in ipairs(S.FACTION_ROWS) do
            pack.cons[row.key] = (row.key == 'Scowling' or row.key == 'Threateningly')
        end
    end
    ImGui.SameLine()
    if ImGui.Button('All##t3FiltAll', 50, 22) then
        for _, row in ipairs(S.FACTION_ROWS) do
            pack.cons[row.key] = true
        end
    end
    for _, row in ipairs(S.FACTION_ROWS) do
        local on = pack.cons[row.key] == true
        pack.cons[row.key] = ImGui.Checkbox(row.label .. '##t3Con_' .. row.key, on) and true or false
    end
    ImGui.EndGroup()

    ImGui.SameLine()
    ImGui.BeginGroup()
    ImGui.Text('Priority')
    textMuted('1 at top. Changing a rank shifts the rest.')
    for _, row in ipairs(S.sortedPriRows(pack)) do
        local pri = S.priOf(pack, row.key)
        ImGui.SetNextItemWidth(50)
        local newPri = comboIdx('##t3Pri_' .. row.key, pri, S.PRI_CHOICES)
        if newPri >= 1 and newPri <= 5 and newPri ~= pri then
            S.setPriority(pack, row.key, newPri)
        end
        ImGui.SameLine()
        ImGui.Text(row.label)
        if ImGui.IsItemHovered() then
            setTooltip(row.tip)
        end
    end
    ImGui.EndGroup()

    ImGui.SameLine()
    ImGui.BeginGroup()
    ImGui.Text('Block List')
    textMuted('Do not attack. % is a wildcard -- %Guard%')
    local removeAt = nil
    for i, line in ipairs(pack.block) do
        ImGui.SetNextItemWidth(360)
        pack.block[i] = ImGui.InputText('##blk' .. i, line or '') or ''
        ImGui.SameLine()
        if ImGui.Button('x##blkX' .. i) then removeAt = i end
    end
    if removeAt then table.remove(pack.block, removeAt) end
    if #pack.block == 0 then pack.block[1] = '' end
    if ImGui.Button('Add##t3BlkAdd', 70, 22) then
        pack.block[#pack.block + 1] = ''
    end
    ImGui.EndGroup()
end

-- VF: shared hub list -- no auto-target in these ShortNames.
local function drawZones(state, actions)
    actions = actions or {}
    if type(state.safeZones) ~= 'table' then
        state.safeZones = S.copySafeZones(S.defaultSafeZones())
    end
    local short, pretty = '', ''
    pcall(function()
        short = tostring(mq.TLO.Zone.ShortName() or '')
        pretty = tostring(mq.TLO.Zone.Name() or '')
    end)
    if short == 'NULL' then short = '' end
    local liveKey = S.normalizeZoneKey(short)
    local inSafe = false
    for _, z in ipairs(state.safeZones) do
        if z == liveKey then inSafe = true; break end
    end

    ImGui.Text('Non-hostile zones')
    textMuted('Shared for all toons (config/ta_safe_zones.lua). TA will not auto-target here.')
    if liveKey ~= '' then
        ImGui.Text(string.format('Here: %s%s', pretty ~= '' and (pretty .. '  ') or '', liveKey))
        if inSafe then
            textGood('This zone is on the list -- combat auto-target off.')
        else
            textMuted('Not on the list -- normal combat targeting.')
        end
    else
        textMuted('Zone unknown -- zone in to use Add current.')
    end

    ImGui.Dummy(0, 4)
    if ImGui.Button('Add current##vfSafeAddCur', 120, 22) then
        if liveKey ~= '' then
            local list = S.copySafeZones(state.safeZones)
            list[#list + 1] = liveKey
            state.safeZones = S.copySafeZones(list)
            if actions.flushSafeZones then actions.flushSafeZones() end
        end
    end
    ImGui.SameLine()
    if ImGui.Button('Reset defaults##vfSafeReset', 120, 22) then
        state.safeZones = S.copySafeZones(S.defaultSafeZones())
        if actions.flushSafeZones then actions.flushSafeZones() end
    end

    ImGui.Dummy(0, 6)
    ImGui.Text('List')
    local removeAt = nil
    for i, z in ipairs(state.safeZones) do
        ImGui.Text(z)
        ImGui.SameLine()
        if ImGui.Button('x##vfSafeX' .. i) then removeAt = i end
    end
    if removeAt then
        table.remove(state.safeZones, removeAt)
        if actions.flushSafeZones then actions.flushSafeZones() end
    end
    if #state.safeZones == 0 then
        textMuted('(empty -- every zone is fair game)')
    end

    ImGui.Dummy(0, 6)
    ImGui.Text('Add ShortName')
    state.safeZoneDraft = state.safeZoneDraft or ''
    ImGui.SetNextItemWidth(220)
    state.safeZoneDraft = ImGui.InputText('##vfSafeDraft', state.safeZoneDraft) or ''
    ImGui.SameLine()
    if ImGui.Button('Add##vfSafeAdd', 60, 22) then
        local z = S.normalizeZoneKey(state.safeZoneDraft)
        if z ~= '' then
            local list = S.copySafeZones(state.safeZones)
            list[#list + 1] = z
            state.safeZones = S.copySafeZones(list)
            state.safeZoneDraft = ''
            if actions.flushSafeZones then actions.flushSafeZones() end
        end
    end
end

-- VF: Combat tab = how THIS character fights. Per-zone route editing lives in
-- VF: the waypoints window (/vf wp); duplicating it here drifted out of sync.
local function drawCombat(state)
    local pull = state.pull
    if type(pull) ~= 'table' then
        pull = S.defaultPull()
        state.pull = pull
    end
    local prefs = state.prefs
    if type(prefs) ~= 'table' then
        prefs = S.defaultPrefs()
        state.prefs = prefs
    end
    -- VF: chase/scan/height are per-zone route-pack values. No zone yet = show why
    -- VF: instead of hiding the whole tab behind a missing pack.
    local pack = nil
    if type(state.routes) == 'table' then
        local live = state.routes.liveZone or ''
        if live ~= '' then state.routes.zone = live end
        pack = S.ensureRouteZone(state.routes, live)
    end

    ImGui.BeginGroup()

    ImGui.Text('Fighting')
    ImGui.Separator()
    ImGui.SetNextItemWidth(160)
    do
        local styles = S.FIGHT_STYLES
        local cur = 1
        for i, name in ipairs(styles) do
            if name == (prefs.style or 'Melee') then cur = i; break end
        end
        cur = comboIdx('##vfFightStyle', cur, styles)
        prefs.style = styles[cur] or prefs.style
    end
    ImGui.SameLine()
    ImGui.Text('Style')
    if ImGui.IsItemHovered() then
        setTooltip('Melee closes and swings. Ranged holds at Stand-off and autofires.\n'
            .. 'Spells are not a style -- they fire from the loadout in either one.')
    end

    ImGui.SetNextItemWidth(160)
    if (prefs.style or 'Melee') == 'Melee' then
        do
            local v = ImGui.SliderInt('##vfMeleeDist', prefs.melee or 14, 5, 50)
            prefs.melee = tonumber(v) or prefs.melee
        end
        ImGui.SameLine()
        ImGui.Text('Melee reach')
        if ImGui.IsItemHovered() then
            setTooltip('How close before we swing. Raise it and we swing from further out\n'
                .. 'than the server will actually land a hit.')
        end
    else
        do
            local v = ImGui.SliderInt('##vfRangeDist', prefs.ranged or 40, 15, 200)
            prefs.ranged = tonumber(v) or prefs.ranged
        end
        ImGui.SameLine()
        ImGui.Text('Stand-off')
        if ImGui.IsItemHovered() then
            setTooltip('Distance to hold while shooting.')
        end
    end

    prefs.enrage_hold = ImGui.Checkbox('Enrage hold##vfEnrageHold', prefs.enrage_hold ~= false)
    if ImGui.IsItemHovered() then
        setTooltip('On: stop swinging while the mob is enraged, so you do not eat the riposte.\n'
            .. 'Off: swing through it. Turning this off also disables MQ2Melee\'s own enrage\n'
            .. 'handling, so the two cannot fight over /attack.')
    end

    ImGui.Dummy(0, 10)
    ImGui.Text('Closing')
    ImGui.Separator()
    ImGui.SetNextItemWidth(160)
    do
        local positions = S.STICK_POSITIONS or { 'Any' }
        local cur = 1
        for i, name in ipairs(positions) do
            if name == (prefs.stick_position or 'Any') then cur = i; break end
        end
        cur = comboIdx('##vfStickPos', cur, positions)
        prefs.stick_position = positions[cur] or prefs.stick_position
    end
    ImGui.SameLine()
    ImGui.Text('Position')
    if ImGui.IsItemHovered() then
        setTooltip('Where MoveUtils parks you: Any, Behind, Front or Side.\n'
            .. 'Anything but Any strafes, which looks less human to onlookers.')
    end

    ImGui.SetNextItemWidth(160)
    do
        local v = ImGui.SliderInt('##vfStickHandoff', prefs.stick_handoff or 120, 40, 200)
        prefs.stick_handoff = tonumber(v) or prefs.stick_handoff
    end
    ImGui.SameLine()
    ImGui.Text('Stick inside')
    if ImGui.IsItemHovered() then
        -- VF: load-bearing. This is the "never /nav" band; see docs/STATUS.md.
        setTooltip('Inside this range we /stick and will NOT /nav -- the nav mesh\n'
            .. 'flaps this close and fought the stick for the feet.\n'
            .. 'Raising it means more geometry we walk into instead of pathing around.\n'
            .. 'No line of sight still overrides it and navs.')
    end

    ImGui.SetNextItemWidth(160)
    if pack then
        do
            local v = ImGui.SliderInt('##vfRtChase', pack.chase or 150, 25, 300)
            pack.chase = tonumber(v) or pack.chase
        end
        ImGui.SameLine()
        ImGui.Text('Chase leash')
        if ImGui.IsItemHovered() then
            setTooltip('Furthest we will chase a mob, and how far we will stray from a\n'
                .. 'waypoint to do it. Per zone. Rush ignores it -- it only pulls the pin.')
        end
    else
        textMuted('Chase leash: zone in to set (per zone).')
    end

    ImGui.Dummy(0, 10)
    ImGui.Text('Recovery')
    ImGui.Separator()
    ImGui.SetNextItemWidth(160)
    do
        local v = ImGui.SliderInt('##vfHealCombat', prefs.combat_heal_pct or 65, 0, 100, '%d%%')
        prefs.combat_heal_pct = tonumber(v) or prefs.combat_heal_pct
        prefs.combat_heal = (prefs.combat_heal_pct or 0) > 0
    end
    ImGui.SameLine()
    ImGui.Text('Heal in combat at')
    if ImGui.IsItemHovered() then
        setTooltip('Heal mid-fight at or below this HP. 0 = off.')
    end

    ImGui.SetNextItemWidth(160)
    do
        local v = ImGui.SliderInt('##vfHealRest', prefs.post_heal_pct or 90, 0, 100, '%d%%')
        prefs.post_heal_pct = tonumber(v) or prefs.post_heal_pct
        prefs.post_heal = (prefs.post_heal_pct or 0) > 0
    end
    ImGui.SameLine()
    ImGui.Text('Heal after fight to')
    if ImGui.IsItemHovered() then
        setTooltip('After a fight, top up to this HP before moving on. 0 = off.')
    end

    ImGui.SetNextItemWidth(160)
    do
        local v = ImGui.SliderInt('##vfRestMana', prefs.rest_mana_pct or 0, 0, 100, '%d%%')
        prefs.rest_mana_pct = tonumber(v) or prefs.rest_mana_pct
    end
    ImGui.SameLine()
    ImGui.Text('Rest mana at')
    if ImGui.IsItemHovered() then
        setTooltip('Sit at or below this mana, then stand at full. 0 = never sit.\n'
            .. 'No buffs while sitting. Med Break on the Settings tab overrides this.')
    end
    ImGui.EndGroup()

    ImGui.SameLine()
    ImGui.Dummy(24, 0)
    ImGui.SameLine()
    ImGui.BeginGroup()

    -- VF: Roam only, and labeled so. Rush is the face pull and reads none of this.
    ImGui.Text('Pulling')
    ImGui.Separator()
    textMuted('Roam only. Rush walks in and tags by hand.')
    ImGui.SetNextItemWidth(160)
    do
        local styles = S.PULL_STYLES
        local cur = 1
        for i, name in ipairs(styles) do
            if name == (pull.style or 'Spell') then cur = i; break end
        end
        cur = comboIdx('##vfPullStyle', cur, styles)
        pull.style = styles[cur] or pull.style
    end
    ImGui.SameLine()
    ImGui.Text('Pull with')
    if ImGui.IsItemHovered() then
        setTooltip('Spell casts the gem below. Ranged throws, then falls back to a bow.\n'
            .. 'Pet sends the pet in. All three tag from range and bring it to you.')
    end

    if pull.style == 'Spell' then
        ImGui.SetNextItemWidth(220)
        local labels = {}
        local slots = {}
        for i = 1, S.NUM_GEMS do
            local nm = state.bar and state.bar[i] or ''
            if nm ~= '' then
                labels[#labels + 1] = string.format('Gem %d: %s', i, nm)
                slots[#slots + 1] = i
            end
        end
        if #labels == 0 then
            labels[1] = '(no gems)'
            slots[1] = 1
        end
        local cur = 1
        for i, slot in ipairs(slots) do
            if slot == (pull.spell_gem or 1) then cur = i; break end
        end
        cur = comboIdx('##vfPullSpell', cur, labels)
        pull.spell_gem = slots[cur] or 1
        pull.spell = (state.bar and state.bar[pull.spell_gem]) or pull.spell or ''
        ImGui.SameLine()
        ImGui.Text('Gem')
    end

    ImGui.SetNextItemWidth(160)
    do
        local v = ImGui.SliderInt('##vfPullEngage', pull.engage or 100, 15, 250)
        pull.engage = tonumber(v) or pull.engage
    end
    ImGui.SameLine()
    ImGui.Text('Tag from')
    if ImGui.IsItemHovered() then
        setTooltip('Close to this range before tagging.')
    end

    pull.stand_back = ImGui.Checkbox('Hold at range##vfPullStand', pull.stand_back == true)
    if ImGui.IsItemHovered() then
        setTooltip('Do not close after tagging -- stay at Tag from and let the pet\n'
            .. 'or your ranged attacks work. Ignored outside Roam.')
    end

    ImGui.Dummy(0, 10)
    ImGui.Text('Scanning')
    ImGui.Separator()
    if pack then
        textMuted('Per zone. Rush ignores both -- it only pulls the pin.')
        ImGui.SetNextItemWidth(160)
        do
            local scan = pack.scan or pack.wander or pack.range or 1500
            local v = ImGui.SliderInt('##vfRtScan', scan, 10, 2000)
            v = tonumber(v) or scan
            -- VF: range/wander are legacy aliases the engine still reads.
            pack.scan, pack.range, pack.wander = v, v, v
        end
        ImGui.SameLine()
        ImGui.Text('Look out to')
        if ImGui.IsItemHovered() then
            setTooltip('How far to look for something to pull.')
        end

        ImGui.SetNextItemWidth(160)
        do
            local zBand = pack.z or pack.maxz or 25
            local v = ImGui.SliderInt('##vfRtZ', zBand, 5, 300)
            v = tonumber(v) or zBand
            -- VF: floor/maxz are legacy aliases the engine still reads.
            pack.z, pack.floor, pack.maxz = v, v, v
        end
        ImGui.SameLine()
        ImGui.Text('Height band')
        if ImGui.IsItemHovered() then
            setTooltip('How far up and down to look. Keep it tight indoors or we will\n'
                .. 'pull something a floor away that we cannot path to. Default 25.')
        end
    else
        textMuted('Zone in to set scan radius and height band.')
    end
    ImGui.EndGroup()
end

local function canSaveNow(state)
    -- VF: Manager always writes the loadout file; TA hot-reloads via /vf reloadloadout.
    return not state.dead and not state.noCharKey
end

local function drawHeader(state)
    if brand.drawHeaderWash then brand.drawHeaderWash() end
    brand.drawHeader('Manager')
    if brand.drawGradientRule then brand.drawGradientRule() end

    if state.t2Running then
        textMuted('VF is running — Save writes disk; VF reloads the loadout.')
    end
    if state.dead then
        textErr('Dead or corpse name -- writes refused.')
    end
    if state.noCharKey then
        textWarn('This character file is not already loaded -- Save will refuse (will not create a new toon).')
    end
end

local drawSettings
local drawGroup

local function drawPaneTabs(state, actions)
    local tabs = {
        { 'Settings', drawSettings },
        { 'Group', drawGroup },
        { 'Loadout', function(s) drawLoadout(s, actions) end },
        { 'Filters', drawFilters },
        { 'Zones', function(s) drawZones(s, actions) end },
        { 'Combat', drawCombat },
        { 'AutoBuy', drawAAPurchase },
    }
    state.pane = state.pane or 'Settings'
    state.loadoutPage = state.loadoutPage or 'spells'
    -- VF: old parent Spells/Skills/AA → Loadout; old Loadout AutoBuy page → parent AutoBuy.
    if state.pane == 'Spells' or state.pane == 'Skills' or state.pane == 'AA' then
        if state.pane == 'Skills' then
            state.loadoutPage = 'abilities'
            state.pane = 'Loadout'
        elseif state.pane == 'AA' then
            if state.aaPage == 'purchase' or state.loadoutPage == 'autobuy' then
                state.pane = 'AutoBuy'
            else
                state.loadoutPage = 'aa'
                state.pane = 'Loadout'
            end
        else
            state.loadoutPage = 'spells'
            state.pane = 'Loadout'
        end
    elseif state.loadoutPage == 'autobuy' and state.pane == 'Loadout' then
        state.pane = 'AutoBuy'
        state.loadoutPage = 'spells'
    end
    local Col = ImGuiCol or _G.ImGuiCol
    for i, tab in ipairs(tabs) do
        if i > 1 then ImGui.SameLine() end
        local on = state.pane == tab[1]
        local pushed = 0
        if Col then
            local fill = on and TAB_ON or TAB_OFF
            if pcall(ImGui.PushStyleColor, Col.Button, fill[1], fill[2], fill[3], fill[4]) then
                pushed = pushed + 1
            end
            if pcall(ImGui.PushStyleColor, Col.ButtonHovered, TAB_HOVER[1], TAB_HOVER[2], TAB_HOVER[3], TAB_HOVER[4]) then
                pushed = pushed + 1
            end
        end
        local tw = 88
        if tab[1] == 'Loadout' then tw = 100 end
        if tab[1] == 'AutoBuy' then tw = 96 end
        if ImGui.Button(tab[1] .. '##vfPane' .. i, tw, 24) then
            -- VF: entering Loadout from the parent strip always lands on Spells.
            if tab[1] == 'Loadout' and state.pane ~= 'Loadout' then
                state.loadoutPage = 'spells'
            end
            state.pane = tab[1]
        end
        if pushed > 0 then pcall(ImGui.PopStyleColor, pushed) end
    end
    if brand.drawSolidRule then brand.drawSolidRule() end
    for _, tab in ipairs(tabs) do
        if state.pane == tab[1] then
            local ok, err = pcall(tab[2], state)
            if not ok then textErr(tostring(err)) end
            break
        end
    end
end

local function drawFooter(state, actions)
    ImGui.Dummy(0, 6)
    if brand.drawSolidRule then brand.drawSolidRule() end
    -- VF: never SetCursorPosX from GetWindowWidth under AlwaysAutoResize — that locks a stretched window.
    local btnW = 80
    if ImGui.Button('Close##vfPaneClose', btnW, 24) then
        state.open = false
    end
    ImGui.SameLine(0, 8)
    if ImGui.Button('Save##vfPaneSave', btnW, 24) then
        if canSaveNow(state) then
            actions.save()
        end
    end
end

drawSettings = function(state)
    local prefs = state.prefs
    if type(prefs) ~= 'table' then
        prefs = S.defaultPrefs()
        state.prefs = prefs
    end
    ImGui.Text('Options')
    prefs.debug = ImGui.Checkbox('Debug mode##vfDebug', prefs.debug == true)
    if ImGui.IsItemHovered() then
        setTooltip('Extra combat lines in chat. Noisy.')
    end
    ImGui.Dummy(0, 6)
    ImGui.Text('Cast gate')
    ImGui.SetNextItemWidth(160)
    do
        local v = ImGui.SliderInt('##vfMinMana', prefs.min_mana or 0, 0, 95, '%d%%')
        prefs.min_mana = tonumber(v) or prefs.min_mana
    end
    ImGui.SameLine()
    ImGui.Text('Min mana')
    if ImGui.IsItemHovered() then
        setTooltip('Stop casting below this. A spend floor, not a rest trigger --\n'
            .. 'resting lives on Combat as "Rest mana at".')
    end
    ImGui.Dummy(0, 6)
    ImGui.Text('Pet')
    ImGui.SetNextItemWidth(160)
    do
        local v = ImGui.SliderInt('##vfPetAssist', prefs.pet_assist or 100, 1, 100, '%d%%')
        prefs.pet_assist = tonumber(v) or prefs.pet_assist
    end
    ImGui.SameLine()
    ImGui.Text('Assist at')
    prefs.pet_hold = ImGui.Checkbox('Pet hold##vfPetHold', prefs.pet_hold ~= false)
    ImGui.Dummy(0, 6)
    ImGui.Text('Med break')
    prefs.med_on = ImGui.Checkbox('Enable med break##vfMedOn', prefs.med_on == true)
    if prefs.med_on then
        -- VF: no HP row. Out-of-combat HP has one owner, the Combat tab's "Heal after
        -- VF: fight to" (post_combat_heal_pct). The HP checkbox and its two sliders
        -- VF: here were saved and never read by the engine.
        textMuted('HP recovery lives on Combat -- "Heal after fight to".')
        prefs.med_mana_on = ImGui.Checkbox('Mana##vfMedMana', prefs.med_mana_on == true)
        ImGui.SameLine(); ImGui.TextDisabled('at'); ImGui.SameLine(); ImGui.SetNextItemWidth(110)
        do
            local v = ImGui.SliderInt('##vfMedMaS', prefs.med_mana_start or 20, 0, 100, '%d%%')
            prefs.med_mana_start = tonumber(v) or prefs.med_mana_start
        end
        ImGui.SameLine(); ImGui.TextDisabled('until'); ImGui.SameLine(); ImGui.SetNextItemWidth(110)
        do
            local v = ImGui.SliderInt('##vfMedMaE', prefs.med_mana_stop or 90, 0, 100, '%d%%')
            prefs.med_mana_stop = tonumber(v) or prefs.med_mana_stop
        end
        prefs.med_end_on = ImGui.Checkbox('Endurance##vfMedEnd', prefs.med_end_on == true)
        ImGui.SameLine(); ImGui.TextDisabled('at'); ImGui.SameLine(); ImGui.SetNextItemWidth(110)
        do
            local v = ImGui.SliderInt('##vfMedEnS', prefs.med_end_start or 20, 0, 100, '%d%%')
            prefs.med_end_start = tonumber(v) or prefs.med_end_start
        end
        ImGui.SameLine(); ImGui.TextDisabled('until'); ImGui.SameLine(); ImGui.SetNextItemWidth(110)
        do
            local v = ImGui.SliderInt('##vfMedEnE', prefs.med_end_stop or 90, 0, 100, '%d%%')
            prefs.med_end_stop = tonumber(v) or prefs.med_end_stop
        end
    end
end

drawGroup = function(state)
    local assist = state.assist
    if type(assist) ~= 'table' then
        assist = S.defaultAssist()
        state.assist = assist
    end
    local trust = state.groupTrust
    if type(trust) ~= 'table' then
        trust = S.defaultGroupTrust()
        state.groupTrust = trust
    end
    if type(trust.names) ~= 'table' then trust.names = {} end

    ImGui.Text('Approved Characters')
    textMuted('Auto-accept invites from these names. Stay = keep Group through zones (mode combo still free).')
    trust.auto_accept = ImGui.Checkbox('Auto-accept invites##vfGrpAuto', trust.auto_accept ~= false)
    trust.stay = ImGui.Checkbox('Keep Group mode on (zones / with them)##vfGrpStay', trust.stay ~= false)
    if ImGui.IsItemHovered() then
        setTooltip('If you zone while in Group with an approved partner, stay in Group (do not pause). Does not lock you out of Manual/Roam/Rush — change the mode combo anytime.')
    end
    ImGui.Dummy(0, 6)
    ImGui.SetNextItemWidth(180)
    state.groupDraft = ImGui.InputText('##vfGrpDraft', state.groupDraft or '') or ''
    ImGui.SameLine()
    if ImGui.Button('Add##vfGrpAdd', 50, 22) then
        local nm = S.normalizePcName(state.groupDraft)
        if nm ~= '' then
            local key = nm:lower()
            local found = false
            for _, n in ipairs(trust.names) do
                if tostring(n):lower() == key then found = true break end
            end
            if not found then trust.names[#trust.names + 1] = nm end
            state.groupDraft = ''
        end
    end
    ImGui.Dummy(0, 4)
    if #trust.names == 0 then
        textMuted('No approved characters yet.')
    else
        local removeIdx = nil
        for i, n in ipairs(trust.names) do
            ImGui.Text(tostring(n))
            ImGui.SameLine()
            if ImGui.SmallButton('x##vfGrpRm' .. i) then removeIdx = i end
        end
        if removeIdx then table.remove(trust.names, removeIdx) end
    end

    ImGui.Dummy(0, 12)
    ImGui.Text('Assist / follow')
    textMuted('MA name blank uses group roles (Main Assist, then Main Tank).')
    ImGui.SetNextItemWidth(180)
    assist.ma_name = ImGui.InputText('MA name##vfMaName', assist.ma_name or '') or ''
    if ImGui.IsItemHovered() then
        setTooltip('Optional name override for follow/assist. Blank uses group roles.')
    end
    ImGui.SetNextItemWidth(160)
    do
        local v = ImGui.SliderInt('##vfAssistAt', assist.assist_at or 98, 1, 100, '%d%%')
        assist.assist_at = tonumber(v) or assist.assist_at
    end
    ImGui.SameLine()
    ImGui.Text('Assist at')
    ImGui.SetNextItemWidth(140)
    do
        local v = ImGui.SliderInt('##vfChaseDist', assist.chase_dist or 15, 5, 100)
        assist.chase_dist = tonumber(v) or assist.chase_dist
    end
    ImGui.SameLine()
    ImGui.Text('Follow range')
    assist.chase = true
    assist.camp = nil

    local prefs = state.prefs
    if type(prefs) ~= 'table' then
        prefs = S.defaultPrefs()
        state.prefs = prefs
    end

    ImGui.Dummy(0, 12)
    ImGui.Text('Support role')
    textMuted('Ordering only. How low an ally must be is the Below % on the heal row itself.')
    local hps = S.HEAL_PRIORITIES or { 'Support first', 'DPS first' }
    ImGui.SetNextItemWidth(180)
    do
        local hi = U.idxOf(hps, prefs.heal_priority or 'Support first')
        local newHi = comboIdx('##vfHealPri', hi, hps)
        if newHi >= 1 and newHi <= #hps then prefs.heal_priority = hps[newHi] end
    end
    if ImGui.IsItemHovered() then
        setTooltip('Support first -- Heal/Cure/HoT/Tap rows fire before the damage rotation.\n'
            .. 'DPS first -- rows aimed at an ALLY wait until after the rotation.\n'
            .. 'Either way a heal aimed at Myself still comes first; you dying outranks both.')
    end
    if prefs.heal_priority == 'DPS first' then
        textMuted('Ally heals wait for the rotation. Self-heals still preempt.')
    else
        textMuted('Heals come before damage. This is the long-standing behavior.')
    end
    -- VF: the Group tab is where people look for this, but nothing here heals an ally
    -- VF: unless a row actually aims at one -- that was the real reason a 36% ally sat
    -- VF: unhealed. Say so, rather than implying the dropdown is enough.
    textMuted('Needs a heal row on Loadout with Target = Lowest-HP Ally (or Whole Group).')
end

function M.draw(state, actions)
    if not state.open then return end
    pushTheme()
    local flags = ImGuiWindowFlags.AlwaysAutoResize
    local F = ImGuiWindowFlags
    if F.NoTitleBar and F.NoCollapse then
        flags = bitbor(F.AlwaysAutoResize, F.NoTitleBar, F.NoCollapse)
    end
    local show
    local title = brand.windowTitle('Manager') .. '###vfManager'
    local opened
    opened, show = ImGui.Begin(title, true, flags)
    if show == nil then show = opened ~= false end
    if show then
        local okH, errH = pcall(drawHeader, state)
        if not okH then textErr('Loadout draw error: ' .. tostring(errH)) end
        local okT, errT = pcall(drawPaneTabs, state, actions)
        if not okT then textErr('Loadout tab error: ' .. tostring(errT)) end
        local okF, errF = pcall(drawFooter, state, actions)
        if not okF then textErr('Loadout footer error: ' .. tostring(errF)) end
    end
    ImGui.End()
    popTheme()
end

return M
