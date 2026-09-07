---@diagnostic disable: undefined-global, undefined-field
-- VF: Inventory mini loader. /lua run vfti — header, bag + AA/h PP/h, PS% right, footer.
-- VF: Copied from engine Mini row; no run/mode/gear/burn/boost.

local mq = require('mq')
local ImGui = require('ImGui')
local brand = require('vft.brand')
local chat = require('vft.chat')

local scriptDir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
local open = true
local bagTex, bagTried
local colN, varN = 0, 0

local MUTED = { 0.541, 0.439, 0.533, 1 }
local GOOD = { 0.37, 0.88, 0.64, 1 }
local ARC = { 0.55, 0.72, 1.0, 1 }
local WARN = { 0.95, 0.72, 0.28, 1 }

local track = {
    startTime = os.time(),
    startAA = nil,
    currentAA = nil,
    startPlat = nil,
    currentPlat = nil,
}
local ps = { pct = nil, name = nil, source = nil, growAnnounced = false }

local function borFlags(...)
    if bit and bit.bor then return bit.bor(...) end
    local acc = 0
    for i = 1, select('#', ...) do acc = acc + (select(i, ...) or 0) end
    return acc
end

local function pushCol(id, r, g, b, a)
    if id and pcall(ImGui.PushStyleColor, id, r, g, b, a) then colN = colN + 1 end
end

local function pushVar(id, a, b)
    local ok
    if b ~= nil then
        ok = pcall(ImGui.PushStyleVar, id, a, b)
    else
        ok = pcall(ImGui.PushStyleVar, id, a)
    end
    if ok then varN = varN + 1 end
end

local function pushTheme()
    colN, varN = 0, 0
    local Col = ImGuiCol or _G.ImGuiCol or (mq.imgui and mq.imgui.Col)
    local SV = ImGuiStyleVar or _G.ImGuiStyleVar or (mq.imgui and mq.imgui.StyleVar)
    if Col then
        pushCol(Col.WindowBg, 0.031, 0.016, 0.055, 0.97)
        pushCol(Col.Border, 0.275, 0.125, 0.490, 1)
        pushCol(Col.Text, 0.910, 0.863, 0.784, 1)
        pushCol(Col.TextDisabled, 0.500, 0.400, 0.620, 1)
        pushCol(Col.Button, 0.078, 0.035, 0.137, 1)
        pushCol(Col.ButtonHovered, 0.710, 0.420, 1.000, 0.35)
        pushCol(Col.ButtonActive, 0.710, 0.420, 1.000, 0.55)
    end
    if SV then
        pushVar(SV.WindowRounding, 7)
        pushVar(SV.FramePadding, 6, 3)
        pushVar(SV.ItemSpacing, 6, 4)
        pushVar(SV.WindowPadding, 10, 8)
    end
end

local function popTheme()
    if varN > 0 then pcall(ImGui.PopStyleVar, varN); varN = 0 end
    if colN > 0 then pcall(ImGui.PopStyleColor, colN); colN = 0 end
end

local function mqLeaving()
    local leaving = false
    pcall(function()
        if mq.exiting then leaving = not not mq.exiting() end
    end)
    return leaving
end

local function invPid()
    local found = nil
    pcall(function()
        local function isInv(s)
            if not s then return false end
            local st, name, path = '', '', ''
            pcall(function() st = tostring(s.Status() or '') end)
            if st ~= 'RUNNING' and st ~= 'PAUSED' then return false end
            pcall(function() name = tostring(s.Name() or '') end)
            pcall(function() path = tostring(s.Path() or '') end)
            name = name:gsub('\\', '/'):lower()
            path = path:gsub('\\', '/'):lower()
            if name == 'vft/inv' or name == 'inv' or name == 'bags' then return true end
            if path:find('vft/inv', 1, true) or path:match('bags%.lua$') then return true end
            return false
        end
        local pids = tostring(mq.TLO.Lua.PIDs() or '')
        for tok in pids:gmatch('%d+') do
            local pid = tonumber(tok)
            if pid and isInv(mq.TLO.Lua.Script(pid)) then
                found = pid
                return
            end
        end
    end)
    return found
end

local function toggleInv()
    local pid = invPid()
    if pid then
        mq.cmd('/lua stop vft/inv')
        mq.cmd('/lua stop bags')
        if type(pid) == 'number' then mq.cmdf('/lua stop %d', pid) end
    else
        mq.cmd('/lua run vft/inv')
    end
end

local function getCurrentAA()
    local okTotal, total = pcall(function() return mq.TLO.Me.AAPointsTotal() end)
    local okSpent, spent = pcall(function() return mq.TLO.Me.AAPointsSpent() end)
    local okUnspent, unspent = pcall(function() return mq.TLO.Me.AAPoints() end)
    local okPct, pct = pcall(function() return mq.TLO.Me.PctAAExp() end)
    local aaCount = nil
    if okTotal and type(total) == 'number' then
        aaCount = total
    elseif (okSpent and type(spent) == 'number') or (okUnspent and type(unspent) == 'number') then
        aaCount = (spent or 0) + (unspent or 0)
    end
    if aaCount and okPct and type(pct) == 'number' then
        aaCount = aaCount + (pct / 100)
    end
    return aaCount
end

local function getCurrentPlat()
    local okCash, cash = pcall(function() return mq.TLO.Me.Cash() end)
    if okCash and type(cash) == 'number' and cash >= 0 then
        return math.floor(cash / 1000)
    end
    local okPlat, plat = pcall(function() return mq.TLO.Me.Platinum() end)
    if okPlat and type(plat) == 'number' then return plat end
    return nil
end

local function resetTracker()
    track.startTime = os.time()
    track.startAA = getCurrentAA()
    track.currentAA = track.startAA or 0
    track.startPlat = getCurrentPlat()
    track.currentPlat = track.startPlat or 0
end

local function updateTracker()
    local aa = getCurrentAA()
    if aa ~= nil then
        if track.startAA == nil then track.startAA = aa end
        track.currentAA = aa
    end
    local plat = getCurrentPlat()
    if plat ~= nil then
        if track.startPlat == nil then track.startPlat = plat end
        track.currentPlat = plat
    end
end

local function refreshPowerSource()
    local item
    pcall(function()
        local slot = mq.TLO.Me.Inventory('PowerSource')
        if slot and slot() then item = slot end
    end)
    if not item then return end
    local name = ''
    pcall(function() name = item.Name() or '' end)
    if name ~= '' then ps.name = name end
    local evoPct
    pcall(function() evoPct = tonumber(item.Evolving.ExpPct()) end)
    if evoPct and evoPct > 0 and ps.source ~= 'log' then
        ps.pct = evoPct
        ps.source = 'evolving TLO'
    end
end

local function onPowerGrow(line, pctTok)
    line = tostring(line or '')
    local n = tonumber(tostring(pctTok or ''):match('([%d%.]+)'))
    if not n then
        n = tonumber(line:match('(%d+%.%d+)%%')) or tonumber(line:match('(%d+)%%'))
    end
    if not n then return end
    ps.pct = n
    ps.source = 'log'
    local name = line:match('%[([^%]]+)%]')
    if not name or name == '' then
        name = line:match('Your%s+(.-)%s+absorbs energy')
    end
    if name and name ~= '' then
        name = name:gsub('\018', ''):gsub('^%x%x%x%x+', ''):gsub('^%s+', ''):gsub('%s+$', '')
        if name ~= '' then ps.name = name end
    end
    if not ps.growAnnounced then
        ps.growAnnounced = true
        chat.say('Inv', string.format('Power source hooked: %s at %.2f%%', tostring(ps.name or '?'), n))
    end
end

local function peekPS()
    refreshPowerSource()
    if ps.pct ~= nil then return string.format('%d%%', math.floor(ps.pct)) end
    return '--'
end

local function psTierColor()
    local name = tostring(ps.name or ''):lower()
    if name:find('legendary', 1, true) then return WARN end
    if name:find('enchanted', 1, true) then return ARC end
    if name ~= '' then return GOOD end
    return MUTED
end

local function drawBagButton()
    local size = 20
    local clicked = false
    local usedIcon = false
    pcall(function()
        if not bagTried then
            bagTried = true
            local paths = {
                scriptDir .. 'vft/vf-bag.png',
                scriptDir .. 'vf-bag.png',
                scriptDir .. 'vft/inv/../vf-bag.png',
            }
            for i = 1, #paths do
                local ok, tex = pcall(mq.CreateTexture, paths[i])
                if ok and tex then bagTex = tex; break end
            end
        end
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        if bagTex and bagTex.GetTextureID and ImVec2Type then
            usedIcon = true
            ImGui.Image(bagTex:GetTextureID(), ImVec2Type(size, size))
            if ImGui.IsItemClicked() then clicked = true end
        end
    end)
    if not usedIcon then
        if ImGui.SmallButton('Bag##vftiBags') then clicked = true end
    end
    if clicked then toggleInv() end
    if ImGui.IsItemHovered() then
        pcall(ImGui.SetTooltip, 'Inventory. /vf inv  or  /vf bags')
    end
end

local function drawGui()
    if not open then return end
    pushTheme()
    pcall(function()
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        if ImVec2Type and ImGui.SetNextWindowSizeConstraints then
            ImGui.SetNextWindowSizeConstraints(ImVec2Type(220, 0), ImVec2Type(520, 200))
        end
    end)
    local flags = ImGuiWindowFlags.AlwaysAutoResize
    local F = ImGuiWindowFlags
    if F.NoTitleBar and F.NoCollapse then
        flags = borFlags(F.AlwaysAutoResize, F.NoTitleBar, F.NoCollapse)
    end
    local show
    open, show = ImGui.Begin('###vftiMini', open, flags)
    if not open then
        open = false
        ImGui.End()
        popTheme()
        return
    end

    -- VF: header (same chrome as engine Mini / inv).
    if brand.drawHeaderWash then brand.drawHeaderWash() end
    brand.drawHeader()
    if brand.drawGradientRule then brand.drawGradientRule() end

    if show then
        updateTracker()
        local elapsedSec = os.time() - (track.startTime or os.time())
        local elapsedHrs = math.max(elapsedSec / 3600.0, 0)
        local aaGained = (track.startAA and track.currentAA) and math.max(0, track.currentAA - track.startAA) or 0
        local aaRate = (elapsedHrs > 0.0001) and (aaGained / elapsedHrs) or 0.0
        local platGained = (track.startPlat and track.currentPlat) and (track.currentPlat - track.startPlat) or 0
        local platRate = (elapsedHrs > 0.0001) and (platGained / elapsedHrs) or 0.0
        local platStr
        if platRate >= 1000 then
            platStr = string.format('%.1fk', platRate / 1000)
        else
            platStr = string.format('%.0f', platRate)
        end

        drawBagButton()
        ImGui.SameLine()
        ImGui.TextDisabled(string.format('AA: %.1f/h', aaRate))
        if ImGui.IsItemClicked() then resetTracker() end
        if ImGui.IsItemHovered() then
            pcall(ImGui.SetTooltip, 'Click to reset session AA and plat tracking.')
        end
        ImGui.SameLine()
        ImGui.TextDisabled(string.format('PP: %s/h', platStr))
        if ImGui.IsItemClicked() then resetTracker() end
        if ImGui.IsItemHovered() then
            pcall(ImGui.SetTooltip, string.format('Session platinum %+d. Click to reset.', platGained))
        end

        local psText = peekPS()
        local psCol = psTierColor()
        local pad, tw = 12, 28
        pcall(function()
            local w = ImGui.CalcTextSize(psText)
            if type(w) == 'number' then tw = w
            elseif w and w.x then tw = w.x end
        end)
        local ww = ImGui.GetWindowWidth() or 0
        local cx = ImGui.GetCursorPosX() or 0
        local targetX = ww - pad - tw
        if targetX > cx + 8 then
            ImGui.SameLine(targetX)
        else
            ImGui.SameLine()
        end
        ImGui.TextColored(psCol[1], psCol[2], psCol[3], psCol[4], psText)
        if ImGui.IsItemHovered() then
            local tip = string.format('%s\n%s',
                tostring(ps.name or '(no power source yet)'),
                ps.pct and string.format('%.2f%% (%s)', ps.pct, tostring(ps.source or '?'))
                    or 'Percent arrives on the next shimmer / absorb line.')
            pcall(ImGui.SetTooltip, tip)
        end
    end

    -- VF: footer rule (same solid rule as inv chrome).
    if brand.drawSolidRule then brand.drawSolidRule() end

    ImGui.End()
    popTheme()
end

pcall(function() mq.unevent('VftiPowerGrow') end)
pcall(function() mq.unevent('VftiPowerGrow2') end)
mq.event('VftiPowerGrow', '#*#absorbs energy#*#', function(line, a, b) onPowerGrow(line, a or b) end)
mq.event('VftiPowerGrow2', '#*#faint shimmer#*#', function(line, a, b) onPowerGrow(line, a or b) end)

resetTracker()
mq.imgui.init('VftiMini', drawGui)
chat.say('Inv', 'Mini')

-- VF: hotkey-friendly toggles (engine /vf also does this when vft is running).
local function vfInvCmd(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        local a = select(i, ...)
        if a ~= nil and tostring(a) ~= '' then parts[#parts + 1] = tostring(a):lower() end
    end
    local cmd = parts[1] or 'inv'
    if cmd == 'inv' or cmd == 'bags' or cmd == 'bag' or cmd == 'inventory' or cmd == 'allbags' then
        toggleInv()
    else
        chat.say('Inv', 'usage: /vf inv  or  /vf bags')
    end
end

pcall(function() mq.unbind('/vfti') end)
pcall(function() mq.unbind('/vfinv') end)
pcall(function() mq.unbind('/tabags') end)
pcall(function() mq.unbind('/vf') end)
mq.bind('/vfti', function() open = not open end)
mq.bind('/vfinv', toggleInv)
mq.bind('/tabags', toggleInv)
mq.bind('/vf', vfInvCmd)

while open and not mqLeaving() do
    mq.doevents()
    mq.delay(20)
end

chat.say('Inv', 'Mini closed')
pcall(function() mq.unbind('/vfti') end)
pcall(function() mq.unbind('/vfinv') end)
pcall(function() mq.unbind('/tabags') end)
pcall(function() mq.unbind('/vf') end)
