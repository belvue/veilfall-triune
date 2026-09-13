---@diagnostic disable: undefined-global, undefined-field
-- VF: Waypoints mini-bar satellite — /lua run vft/waypoints (/vf waypoints).

local mq = require('mq')
local ImGui = require('ImGui')
local brand = require('vft.brand')
local S = require('vft.mgr.schema')
local IO = require('vft.mgr.io')
local U = require('vft.mgr.util')
local MapLocs = require('vft.maplocs')

local theme = { colN = 0, varN = 0 }
local TAB_ON = { 0.290, 0.140, 0.510, 1 }
local TAB_HOVER = { 0.380, 0.180, 0.620, 1 }
local MUTED = { 0.541, 0.439, 0.533, 1 }

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
        pushCol(Col.CheckMark, 0.710, 0.420, 1.000, 1)
        pushCol(Col.Separator, 0.275, 0.125, 0.490, 1)
    end
    if SV then
        pushVar(SV.WindowRounding, 6)
        pushVar(SV.FrameRounding, 4)
        pushVar(SV.PopupRounding, 4)
        pushVar(SV.FrameBorderSize, 1)
        pushVar(SV.FramePadding, 6, 3)
        pushVar(SV.ItemSpacing, 6, 4)
        pushVar(SV.WindowPadding, 10, 8)
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
    if bit and bit.bor then return bit.bor(...) end
    for i = 1, select('#', ...) do
        acc = acc + (select(i, ...) or 0)
    end
    return acc
end

local function comboIdx(id, cur, items)
    local v = ImGui.Combo(id, cur, items)
    return tonumber(v) or cur
end

local function zoneShort()
    local z = ''
    pcall(function() z = tostring(mq.TLO.Zone.ShortName() or '') end)
    if z == 'NULL' then z = '' end
    return z
end

local function meXYZ()
    local x, y, z = 0, 0, 0
    pcall(function()
        x = mq.TLO.Me.X() or 0
        y = mq.TLO.Me.Y() or 0
        z = mq.TLO.Me.Z() or 0
    end)
    return tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
end

local function captureLoc(ignoreZ)
    local loc = S.captureLoc(mq)
    if not loc then return nil end
    if ignoreZ then loc.z = nil end
    return loc
end

local state = {
    open = true,
    ignoreZ = false,
    locsOpen = true,
    locNumEdit = nil,
    routes = S.emptyRoutes(),
    routeLib = S.emptyRouteLib(),
    routeLibZone = '',
    routeSave = nil,
    charName = nil,
    allData = {},
    charEntry = nil,
    dead = false,
    noCharKey = false,
    backedUp = false,
    hydratedName = nil,
    lastFileAt = 0,
    hydratedSig = '',
}

-- VF: nearest loc by stand dist. Flat pins and Ignore Z both use XY only.
local function nearestLocIdx(pack)
    local locs = pack and pack.locs
    if type(locs) ~= 'table' or #locs < 1 then return nil, nil end
    local mx, my, mz = meXYZ()
    local best, bestD = nil, 1e12
    for i = 1, #locs do
        local loc = locs[i]
        if type(loc) == 'table' then
            local lx = tonumber(loc.x)
            local ly = tonumber(loc.y)
            if lx and ly then
                local dx = mx - lx
                local dy = my - ly
                local d = dx * dx + dy * dy
                if not state.ignoreZ and loc.z ~= nil then
                    local dz = mz - (tonumber(loc.z) or 0)
                    d = d + dz * dz
                end
                if d < bestD then
                    best, bestD = i, d
                end
            end
        end
    end
    if not best then return nil, nil end
    return best, math.sqrt(bestD)
end

local function zonePack()
    local zone = zoneShort()
    if zone == '' then return nil, '' end
    if not state.routes then state.routes = S.emptyRoutes() end
    state.routes.zones = state.routes.zones or {}
    -- VF: only seed a missing pack — never deep-copy every draw (that raced Move).
    if type(state.routes.zones[zone]) ~= 'table' then
        state.routes.zones[zone] = S.copyRoutePack(nil)
    end
    state.routes.liveZone = zone
    state.routes.zone = zone
    return state.routes.zones[zone], zone
end

local function locSig(pack, zone)
    return MapLocs.sig(pack and pack.locs, zone)
end

local function paintPins()
    local pack, zone = zonePack()
    MapLocs.paint(pack and pack.locs, zone)
end

local function mqLeaving()
    local leaving = false
    pcall(function()
        if mq.exiting then leaving = not not mq.exiting() end
    end)
    return leaving
end

local function refreshEntry(force)
    local now = os.clock()
    -- VF: 0.25s so Ctrl+click / engine adds land in the list without a 2s stall.
    if not force and (now - state.lastFileAt) < 0.25 then
        state.charName = IO.charName()
        state.dead = IO.isDeadOrCorpse(state.charName)
        return
    end
    state.lastFileAt = now
    local all = IO.loadAll()
    state.allData = all or {}
    local nm = IO.charName()
    state.charName = nm
    state.dead = IO.isDeadOrCorpse(nm)
    if nm and type(state.allData[nm]) == 'table' then
        state.charEntry = state.allData[nm]
        state.noCharKey = false
    else
        state.charEntry = nil
        state.noCharKey = nm ~= nil
    end
end

local function hydrateIfNeeded(force)
    local nm = state.charName
    local z = zoneShort()
    local pack = (state.charEntry and state.charEntry.waypoints
        and state.charEntry.waypoints.zones and z ~= '')
        and state.charEntry.waypoints.zones[z] or nil
    local sig = locSig(pack, z)
    if not force and nm == state.hydratedName and sig == state.hydratedSig then return end
    state.hydratedName = nm
    state.hydratedSig = sig
    local rawWp = state.charEntry and state.charEntry.waypoints
    state.routes = S.copyRoutes(rawWp)
    local zone = zoneShort()
    state.routeLibZone = zone
    state.routeLib = IO.loadRouteLib(zone)
    if zone ~= '' then
        if type(state.routes.zones[zone]) ~= 'table' then
            state.routes.zones[zone] = S.copyRoutePack(nil)
        end
        state.routes.liveZone = zone
        state.routes.zone = zone
    end
    paintPins()
end

local function flushRoutes()
    local nm = state.charName
    if not nm or state.dead or state.noCharKey then
        print('\ay[VF WP]\ax cannot write locs -- no character loadout key.')
        return false
    end
    local prev = state.allData[nm] or state.charEntry
    if type(prev) ~= 'table' then return false end
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
        return true
    end
    print('\ar[VF WP]\ax route flush failed: ' .. tostring(err))
    return false
end

local function syncNamedRoute()
    local pack, zone = zonePack()
    if not pack or zone == '' then return false end
    local id = U.trimName(tostring(pack.lib_id or ''))
    if id == '' then return false end
    local item = S.findRoute(state.routeLib, id)
    if not item then return false end
    item.pack = S.copyRoutePack(pack)
    item.pack.lib_id = item.id
    local ok, destOrErr = IO.saveRouteLib(state.routeLib, zone)
    if not ok then
        print('\ar[VF WP]\ax route update failed: ' .. tostring(destOrErr))
        return false
    end
    return true
end

local function applyRoutePreset(item)
    local _, zone = zonePack()
    if zone == '' or type(item) ~= 'table' then return false end
    local nextPack = S.copyRoutePack(item.pack)
    nextPack.lib_id = item.id
    state.routes.zones[zone] = nextPack
    paintPins()
    return flushRoutes()
end

local function writeRoutePreset(draft)
    local pack, zone = zonePack()
    if not pack or type(draft) ~= 'table' then return false end
    local name = U.trimName(tostring(draft.name or ''))
    if name == '' then
        print('\ay[VF WP]\ax name the route before Write.')
        return false
    end
    local item = {
        id = U.trimName(tostring(draft.id or '')),
        name = name,
        zone = zone,
        map = U.trimName(tostring(draft.map or '')),
        note = tostring(draft.note or ''),
        pack = S.copyRoutePack(pack),
    }
    local lib, saved = S.upsertRoute(state.routeLib, item)
    state.routeLib = lib
    if not saved then return false end
    pack.lib_id = saved.id
    local ok, destOrErr = IO.saveRouteLib(lib, zone)
    if not ok then
        print('\ar[VF WP]\ax route save failed: ' .. tostring(destOrErr))
        return false
    end
    flushRoutes()
    print(string.format('\ag[VF WP]\ax wrote %s -- %s (%d locs).', destOrErr, saved.name, #(pack.locs or {})))
    return true
end

local function addKind(kind)
    local pack, zone = zonePack()
    if not pack or zone == '' then
        print('\ay[VF WP]\ax no zone -- cannot add a loc.')
        return
    end
    local loc = captureLoc(state.ignoreZ)
    if not loc then
        print('\ay[VF WP]\ax could not read a loc.')
        return
    end
    loc.kind = kind
    pack.locs = pack.locs or {}
    pack.locs[#pack.locs + 1] = loc
    state.locsOpen = true
    paintPins()
    flushRoutes()
    syncNamedRoute()
    print(string.format('\ag[VF WP]\ax %s loc %d added -- %s (Y:%.1f X:%.1f%s).',
        zone, #pack.locs, kind, loc.y, loc.x,
        loc.z and string.format(' Z:%.1f', loc.z) or ' flat'))
end

local function moveNearestLoc()
    local pack = zonePack()
    local idx = nearestLocIdx(pack)
    if not pack or not idx then
        print('\ay[VF WP]\ax no locs to move.')
        return
    end
    local loc = pack.locs[idx]
    local fresh = captureLoc(state.ignoreZ)
    if not fresh or type(loc) ~= 'table' then
        print('\ay[VF WP]\ax could not read a loc.')
        return
    end
    local kind = tostring(loc.kind or 'loop'):lower()
    if kind ~= 'travel' and kind ~= 'guide' then kind = 'loop' end
    loc.x = fresh.x
    loc.y = fresh.y
    loc.z = fresh.z
    loc.kind = kind
    pack.locs[idx] = loc
    paintPins()
    flushRoutes()
    syncNamedRoute()
    print(string.format('\ag[VF WP]\ax moved loc #%d to Y:%.1f X:%.1f%s.',
        idx, loc.y, loc.x, loc.z and string.format(' Z:%.1f', loc.z) or ' flat'))
end

local function openSaveDraft(asNew)
    local pack = zonePack()
    local prev = nil
    if not asNew and pack and pack.lib_id then
        prev = S.findRoute(state.routeLib, pack.lib_id)
    end
    local mapName = ''
    pcall(function() mapName = tostring(mq.TLO.Zone.Name() or '') end)
    if mapName == 'NULL' then mapName = '' end
    state.routeSave = {
        open = true,
        id = (not asNew and prev and prev.id) or '',
        name = (not asNew and prev and prev.name) or '',
        map = (not asNew and prev and prev.map ~= '' and prev.map) or mapName,
        note = (not asNew and prev and prev.note) or '',
    }
    if asNew then
        -- VF: New always starts a fresh save id so Write upserts a new named route.
        state.routeSave.id = ''
    elseif not prev then
        print('\ay[VF WP]\ax pick a saved route to edit, or use New.')
        state.routeSave = nil
    end
end

local function drawHeader()
    brand.drawChromeHeader('Waypoints', 'vfWpClose', function()
        state.open = false
    end)
end

local function drawSavePopup()
    local draft = state.routeSave
    if type(draft) ~= 'table' or not draft.open then return end
    local show
    draft.open, show = ImGui.Begin('Save route###vfWpSavePop', draft.open, ImGuiWindowFlags.AlwaysAutoResize)
    if show == nil then show = draft.open end
    if draft.open and show then
        ImGui.SetNextItemWidth(260)
        draft.name = ImGui.InputText('Name##vfWpSvName', draft.name or '') or ''
        ImGui.SetNextItemWidth(260)
        draft.map = ImGui.InputText('Map##vfWpSvMap', draft.map or '') or ''
        ImGui.SetNextItemWidth(260)
        draft.note = ImGui.InputText('Note##vfWpSvNote', draft.note or '') or ''
        if ImGui.Button('Write##vfWpSvOk', 80, 22) then
            if writeRoutePreset(draft) then draft.open = false end
        end
        ImGui.SameLine()
        if ImGui.Button('Cancel##vfWpSvNo', 80, 22) then
            draft.open = false
        end
    end
    ImGui.End()
end

local function drawBody()
    local pack, zone = zonePack()

    -- VF: col1 — stand-here kind buttons.
    ImGui.BeginGroup()
    if ImGui.Button('Guide##vfWpGuide', 56, 22) then addKind('guide') end
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Add current loc as Guide (walk-through).') end
    ImGui.SameLine()
    if ImGui.Button('Loop##vfWpLoop', 48, 22) then addKind('loop') end
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Add current loc as Loop (fight pin).') end
    ImGui.SameLine()
    if ImGui.Button('Travel##vfWpTravel', 56, 22) then addKind('travel') end
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Add current loc as Travel.') end
    ImGui.EndGroup()

    ImGui.SameLine()
    ImGui.TextDisabled('|')
    ImGui.SameLine()

    -- VF: col2 — route pick + New/Edit.
    ImGui.BeginGroup()
    local zoneLib = S.routesForZone(state.routeLib, zone)
    local labels = { '(unsaved)' }
    local cur = 1
    if pack then
        for i, it in ipairs(zoneLib) do
            labels[#labels + 1] = it.name
            if pack.lib_id and it.id == pack.lib_id then cur = #labels end
        end
    end
    ImGui.SetNextItemWidth(130)
    local newCur = comboIdx('##vfWpLib', cur, labels)
    if newCur ~= cur and pack then
        if newCur <= 1 then
            pack.lib_id = nil
            flushRoutes()
        else
            local item = zoneLib[newCur - 1]
            if item then applyRoutePreset(item) end
        end
    end
    ImGui.SameLine()
    if ImGui.Button('New##vfWpNew', 40, 22) then openSaveDraft(true) end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Save current locs as a new named route.')
    end
    ImGui.SameLine()
    if ImGui.Button('Edit##vfWpEdit', 40, 22) then openSaveDraft(false) end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Edit name/map/note for the selected saved route.')
    end
    ImGui.SameLine()
    if ImGui.Button('List##vfWpList', 40, 22) then
        state.locsOpen = not state.locsOpen
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Show or hide the ordered loc list window.')
    end
    ImGui.EndGroup()

    -- VF: row 2 — Ignore Z + live XYZ + nearest # + Move.
    ImGui.Dummy(0, 2)
    local x, y, z = meXYZ()
    state.ignoreZ = ImGui.Checkbox('Ignore Z##vfWpFlat', state.ignoreZ == true) and true or false
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Add flat pins (no height) -- same as a map click.')
    end
    ImGui.SameLine()
    ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'X:')
    ImGui.SameLine()
    ImGui.Text(string.format('%.1f', x))
    ImGui.SameLine()
    ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Y:')
    ImGui.SameLine()
    ImGui.Text(string.format('%.1f', y))
    ImGui.SameLine()
    ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Z:')
    ImGui.SameLine()
    ImGui.Text(string.format('%.1f', z))
    ImGui.SameLine()
    local nearIdx, nearDist = nearestLocIdx(pack)
    if nearIdx then
        ImGui.Text(string.format('#%d', nearIdx))
        if ImGui.IsItemHovered() then
            local loc = pack.locs[nearIdx]
            ImGui.SetTooltip(string.format('Nearest loc (%s) — %.0f away.',
                loc and (loc.kind or 'loop') or '?', nearDist or 0))
        end
        ImGui.SameLine()
        if ImGui.Button('Move##vfWpMove', 48, 22) then
            moveNearestLoc()
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Repin nearest loc to where you are standing.')
        end
    else
        ImGui.TextDisabled('#-')
    end
end

local function locArrow(id, dirName)
    local Dir = ImGuiDir or _G.ImGuiDir
    local d = Dir and Dir[dirName]
    if d ~= nil then
        local ok, hit = pcall(ImGui.ArrowButton, id, d)
        if ok then return hit end
    end
    return ImGui.SmallButton(((dirName == 'Up') and '^' or 'v') .. id)
end

local function drawLocsWindow()
    if not state.locsOpen then return end
    local pack = zonePack()
    local nearIdx = nearestLocIdx(pack)
    local n = pack and #(pack.locs or {}) or 0
    local flags = ImGuiWindowFlags.None
    local F = ImGuiWindowFlags
    if F.NoTitleBar and F.NoCollapse then
        flags = bitbor(F.NoTitleBar, F.NoCollapse)
    elseif F.NoCollapse then
        flags = bitbor(F.NoCollapse)
    end
    local Cond = ImGuiCond or _G.ImGuiCond
    if Cond and Cond.FirstUseEver then
        ImGui.SetNextWindowSize(440, 300, Cond.FirstUseEver)
    else
        pcall(ImGui.SetNextWindowSize, 440, 300)
    end
    local title = brand.windowTitle('Locs') .. '###vfWpLocs'
    local opened, show = ImGui.Begin(title, true, flags)
    if show == nil then show = opened ~= false end
    if show then
        brand.drawChromeHeader('Locs', 'vfWpLocClose', function()
            state.locsOpen = false
        end)
        if not state.locsOpen then
            ImGui.End()
            return
        end
        ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
            string.format('%d loc%s', n, n == 1 and '' or 's'))
        ImGui.Separator()
        local childOk = ImGui.BeginChild('##vfWpLocScroll', 0, 0, true)
        if childOk then
            local removeAt, moveFrom, moveTo, kindChanged = nil, nil, nil, false
            for i, loc in ipairs((pack and pack.locs) or {}) do
                if ImGui.SmallButton('x##vfWpX' .. i) then removeAt = i end
                ImGui.SameLine()
                if locArrow('##vfWpU' .. i, 'Up') and i > 1 then
                    moveFrom, moveTo = i, i - 1
                end
                ImGui.SameLine()
                if locArrow('##vfWpD' .. i, 'Down') and i < n then
                    moveFrom, moveTo = i, i + 1
                end
                ImGui.SameLine()
                ImGui.SetNextItemWidth(36)
                local shown = tostring(i)
                if state.locNumEdit and state.locNumEdit.i == i then
                    shown = state.locNumEdit.text or shown
                end
                local typed = ImGui.InputText('##vfWpN' .. i, shown)
                if typed ~= shown then
                    state.locNumEdit = { i = i, text = typed }
                end
                local apply = false
                pcall(function() apply = ImGui.IsItemDeactivatedAfterEdit() end)
                pcall(function()
                    if state.locNumEdit and state.locNumEdit.i == i then
                        local Key = ImGuiKey or _G.ImGuiKey
                        if Key and (ImGui.IsKeyPressed(Key.Enter) or ImGui.IsKeyPressed(Key.KeypadEnter)) then
                            apply = true
                        end
                    end
                end)
                if apply then
                    local dest = tonumber(state.locNumEdit and state.locNumEdit.text or typed)
                    state.locNumEdit = nil
                    if dest then moveFrom, moveTo = i, dest end
                end
                ImGui.SameLine()
                ImGui.SetNextItemWidth(72)
                local kinds = S.LOC_KINDS
                local curLabel = S.locKindLabel(S.locKind(loc))
                local ki = U.idxOf(kinds, curLabel)
                local newKi = comboIdx('##vfWpK' .. i, ki, kinds)
                if kinds[newKi] and kinds[newKi] ~= curLabel then
                    loc.kind = kinds[newKi]:lower()
                    kindChanged = true
                end
                ImGui.SameLine()
                local coord = string.format('%.1f, %.1f, %s', loc.x or 0, loc.y or 0,
                    loc.z and string.format('%.1f', loc.z) or '--')
                if nearIdx == i then
                    ImGui.TextColored(0.710, 0.420, 1.000, 1, coord)
                else
                    ImGui.Text(coord)
                end
            end
            if n == 0 then
                ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'No locs yet.')
            end
            if removeAt and pack then
                table.remove(pack.locs, removeAt)
            elseif moveFrom and pack and S.moveLoc then
                S.moveLoc(pack.locs, moveFrom, moveTo)
            end
            if removeAt or moveFrom or kindChanged then
                paintPins()
                flushRoutes()
                syncNamedRoute()
            end
        end
        ImGui.EndChild()
    end
    ImGui.End()
end

local function draw()
    if not state.open then
        state.locsOpen = false
        return
    end
    pushTheme()
    -- VF: no AlwaysAutoResize — chrome close needs a stable width (NMS-style).
    local flags = 0
    local F = ImGuiWindowFlags
    if F.NoTitleBar and F.NoCollapse then
        flags = bitbor(F.NoTitleBar, F.NoCollapse)
    end
    local Cond = ImGuiCond or _G.ImGuiCond
    if Cond and Cond.FirstUseEver then
        ImGui.SetNextWindowSize(560, 128, Cond.FirstUseEver)
    else
        pcall(ImGui.SetNextWindowSize, 560, 128)
    end
    pcall(function()
        if ImGui.SetNextWindowSizeConstraints then
            ImGui.SetNextWindowSizeConstraints(500, 110, 900, 220)
        end
    end)
    local title = brand.windowTitle('Waypoints') .. '###vfWaypoints'
    local opened, show = ImGui.Begin(title, true, flags)
    if show == nil then show = opened ~= false end
    if show then
        local okH, errH = pcall(drawHeader)
        if not okH then ImGui.TextColored(1, 0.3, 0.3, 1, tostring(errH)) end
        local okB, errB = pcall(drawBody)
        if not okB then ImGui.TextColored(1, 0.3, 0.3, 1, tostring(errB)) end
    end
    ImGui.End()
    if state.open then
        pcall(drawSavePopup)
        pcall(drawLocsWindow)
    end
    popTheme()
end

local function tick()
    refreshEntry(false)
    hydrateIfNeeded(false)
    local z = zoneShort()
    if z ~= '' then
        zonePack()
        if state.routeLibZone ~= z then
            state.routeLibZone = z
            state.routeLib = IO.loadRouteLib(z)
            hydrateIfNeeded(true)
        else
            paintPins()
        end
    end
end

mq.imgui.init('VFWaypointsUI', function()
    local ok, err = pcall(draw)
    if not ok then
        print('\ar[VF WP]\ax draw error: ' .. tostring(err))
    end
end)

refreshEntry(true)
hydrateIfNeeded(true)
print('\ag[VF WP]\ax Waypoints bar up. Header x or /vf waypoints to close.')

while state.open and not mqLeaving() do
    mq.doevents()
    local ok, err = pcall(tick)
    if not ok then
        print('\ar[VF WP]\ax tick error: ' .. tostring(err))
    end
    mq.delay(200)
end
