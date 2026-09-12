-- VF: shared window header: mark + brand.
local mq = require('mq')
local ImGui = require('ImGui')

local M = {}
local scriptDir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
local brandTex, brandTried

local PURPLE = { 0.710, 0.420, 1.000, 1 }
local BONE = { 0.910, 0.863, 0.784, 1 }
local MUTED = { 0.541, 0.439, 0.533, 1 }

function M.windowTitle(suffix)
    if suffix and suffix ~= '' then
        return 'Veilfall.cc | Triune > ' .. tostring(suffix)
    end
    return 'Veilfall.cc | Triune'
end

function M.drawLogo(size)
    size = size or 20
    local w = size * 1.55
    local drew = false
    pcall(function()
        if not brandTried then
            brandTried = true
            local paths = { scriptDir .. 'vf-mark.png', scriptDir .. '../ta/vf-mark.png' }
            for i = 1, #paths do
                local ok, tex = pcall(mq.CreateTexture, paths[i])
                if ok and tex then
                    brandTex = tex
                    break
                end
            end
        end
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        if brandTex and brandTex.GetTextureID and ImVec2Type then
            ImGui.Image(brandTex:GetTextureID(), ImVec2Type(w, size))
            drew = true
            return
        end
        if not ImVec2Type then return end
        local dl = ImGui.GetWindowDrawList()
        local p = ImGui.GetCursorScreenPosVec()
        local y = p.y + size * 0.5
        local col = IM_COL32(181, 107, 255, 230)
        dl:AddCircleFilled(ImVec2Type(p.x + size * 0.28, y), size * 0.16, col, 10)
        dl:AddCircleFilled(ImVec2Type(p.x + size * 0.78, y), size * 0.20, col, 10)
        dl:AddCircleFilled(ImVec2Type(p.x + size * 1.24, y), size * 0.16, col, 10)
        drew = true
    end)
    if not drew then ImGui.Dummy(w, size) end
end

function M.drawHeaderWash()
    pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        local wp = ImGui.GetWindowPosVec()
        local ww = ImGui.GetWindowWidth() or 0
        if dl and ImVec2Type and wp and ww > 8 then
            dl:AddRectFilledMultiColor(
                ImVec2Type(wp.x + 1, wp.y + 1),
                ImVec2Type(wp.x + ww - 1, wp.y + 32),
                IM_COL32(36, 16, 72, 200),
                IM_COL32(36, 16, 72, 200),
                IM_COL32(8, 4, 16, 0),
                IM_COL32(8, 4, 16, 0)
            )
        end
    end)
end

function M.drawHeader(extra)
    M.drawHeaderPath('Triune', extra)
end

-- VF: Veilfall.cc | mid > extra  (item modal uses mid=Manager).
function M.drawHeaderPath(mid, extra)
    M.drawLogo(20)
    if ImGui.IsItemHovered() then
        pcall(ImGui.SetTooltip, M.windowTitle())
    end
    ImGui.SameLine()
    ImGui.TextColored(PURPLE[1], PURPLE[2], PURPLE[3], PURPLE[4], 'Veilfall.cc')
    ImGui.SameLine()
    ImGui.TextDisabled('|')
    ImGui.SameLine()
    ImGui.TextColored(BONE[1], BONE[2], BONE[3], BONE[4], tostring(mid or 'Triune'))
    if extra and extra ~= '' then
        extra = tostring(extra):gsub('^[|>]%s*', '')
        if extra ~= '' then
            ImGui.SameLine()
            ImGui.TextDisabled('>')
            ImGui.SameLine()
            ImGui.TextColored(BONE[1], BONE[2], BONE[3], BONE[4], extra)
        end
    end
end

-- VF: NMS-style chrome — mark + Veilfall.cc | Triune > Name, close pinned right.
-- VF: Caller must NOT use AlwaysAutoResize; right-align needs a stable window width.
function M.drawChromeHeader(extra, closeId, onClose)
    if M.drawHeaderWash then M.drawHeaderWash() end
    local btnW, pad = 20, 10
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
    M.drawHeader(extra)
    ImGui.SameLine()
    pcall(function()
        if lineW > btnW + pad then
            ImGui.SetCursorPosX(lineStart + lineW - btnW)
        end
    end)
    local hit = ImGui.SmallButton('x##' .. tostring(closeId or extra or 'chrome'))
    if hit and onClose then onClose() end
    if M.drawGradientRule then M.drawGradientRule() end
    return hit
end

function M.drawGradientRule()
    pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        local p = ImGui.GetCursorScreenPosVec()
        local wp = ImGui.GetWindowPosVec()
        if not (dl and ImVec2Type and p) then return end
        local ww = ImGui.GetWindowWidth() or 0
        local pad = 12
        local x1 = (wp and wp.x or p.x) + pad
        local x2 = (wp and wp.x or p.x) + ww - pad
        if x2 < x1 + 80 then x2 = p.x + 280 end
        local y = p.y + 2
        local h = 2
        local mid = x1 + (x2 - x1) * 0.36
        local c0 = IM_COL32(40, 16, 72, 0)
        local c2 = IM_COL32(181, 107, 255, 240)
        local c4 = IM_COL32(40, 16, 72, 0)
        if dl.AddRectFilledMultiColor then
            dl:AddRectFilledMultiColor(ImVec2Type(x1, y), ImVec2Type(mid, y + h), c0, c2, c2, c0)
            dl:AddRectFilledMultiColor(ImVec2Type(mid, y), ImVec2Type(x2, y + h), c2, c4, c4, c2)
        else
            dl:AddLine(ImVec2Type(x1, y), ImVec2Type(x2, y), c2, 1)
        end
    end)
    ImGui.Dummy(1, 8)
end

-- VF: secondary divider for inside a tab -- dark purple fading right into the window bg.
-- VF: Quieter than drawGradientRule (header) and drawSolidRule (tab strip / footer).
function M.drawSubRule()
    pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        local p = ImGui.GetCursorScreenPosVec()
        local wp = ImGui.GetWindowPosVec()
        if not (dl and ImVec2Type and p) then return end
        local ww = ImGui.GetWindowWidth() or 0
        local pad = 10
        local x1 = (wp and wp.x or p.x) + pad
        local x2 = (wp and wp.x or p.x) + ww - pad
        if x2 < x1 + 80 then x2 = p.x + 280 end
        local y = p.y + 1
        local h = 2
        local c0 = IM_COL32(96, 48, 168, 225)
        local c1 = IM_COL32(40, 16, 72, 0)
        if dl.AddRectFilledMultiColor then
            dl:AddRectFilledMultiColor(ImVec2Type(x1, y), ImVec2Type(x2, y + h), c0, c1, c1, c0)
        else
            dl:AddLine(ImVec2Type(x1, y), ImVec2Type(x2, y), c0, 1)
        end
    end)
    ImGui.Dummy(1, 6)
end

function M.drawSolidRule()
    pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        local p = ImGui.GetCursorScreenPosVec()
        local wp = ImGui.GetWindowPosVec()
        if not (dl and ImVec2Type and p) then return end
        local ww = ImGui.GetWindowWidth() or 0
        local x1 = (wp and wp.x or p.x) + 1
        local x2 = (wp and wp.x or p.x) + ww - 1
        if x2 < x1 + 40 then x2 = p.x + 280 end
        local y = p.y + 1
        local col = IM_COL32(70, 32, 125, 255)
        if dl.AddRectFilled then
            dl:AddRectFilled(ImVec2Type(x1, y), ImVec2Type(x2, y + 2), col)
        else
            dl:AddLine(ImVec2Type(x1, y), ImVec2Type(x2, y), col, 2)
        end
    end)
    ImGui.Dummy(1, 8)
end

return M
