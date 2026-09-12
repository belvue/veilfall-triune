---@diagnostic disable: undefined-global, undefined-field
-- VF: MQ console — [VF:<module>] say/err; debug → [VF:<file> - <fn>] when debug_mode.
-- VF: Usage: local chat = require('vft.chat'); chat.say('Inv', 'Opening')
-- VF:         chat.debug('woke attack')  -- auto file+fn; or chat.debug('enginestate', 'pulse', msg)
-- VF: No \ax before msg (inherits prior). No bold in MQ echo.

local M = {}

-- VF: ctrl.debug_mode (or explicit true). Set via chat.setDebug(fn|bool).
local debugGate = false

function M.setDebug(gate)
    debugGate = gate
end

function M.isDebug()
    if type(debugGate) == 'function' then
        local ok, on = pcall(debugGate)
        return ok and on and true or false
    end
    return debugGate and true or false
end

local function fileBase(src)
    if not src or src == '' then return '?' end
    -- VF: debug.getinfo source is often "@G:\\...\\vft\\enginestate.lua" or "=stdin".
    local s = tostring(src):gsub('^@', '')
    s = s:match('([^/\\]+)$') or s
    s = s:gsub('%.lua$', '')
    if s == '' or s == 'stdin' then return '?' end
    return s
end

local function callerMeta(stack)
    local info = debug.getinfo((stack or 3), 'Sn')
    if not info then return '?', '?' end
    local mod = fileBase(info.source or info.short_src)
    local fn = info.name
    if not fn or fn == '' then fn = '?' end
    return mod, fn
end

function M.tag(mod)
    -- VF: \ap purple []:; \at cyan VF + module.
    return '\ap[\atVF\ap:\at' .. tostring(mod or '?') .. '\ap]'
end

function M.debugTag(mod, fn)
    -- VF: [VF:<file> - <function>]
    return '\ap[\atVF\ap:\at' .. tostring(mod or '?') .. '\ap - \at' .. tostring(fn or '?') .. '\ap]'
end

function M.say(mod, msg)
    -- VF: \a-w grey (W2 from the color strip).
    print(M.tag(mod) .. '\a-w ' .. tostring(msg or ''))
end

function M.err(mod, msg)
    print(M.tag(mod) .. '\ar ' .. tostring(msg or ''))
end

-- VF: chat.debug(msg) | chat.debug(mod, msg) | chat.debug(mod, fn, msg). No-op unless debug_mode.
function M.debug(a, b, c)
    if not M.isDebug() then return end
    local mod, fn, msg
    if c ~= nil then
        mod, fn, msg = a, b, c
    elseif b ~= nil then
        mod, msg = a, b
        local _, autoFn = callerMeta(3)
        fn = autoFn
    else
        msg = a
        mod, fn = callerMeta(3)
    end
    -- VF: \ao orange — same lane as existing [DEBUG] combat telemetry.
    print(M.debugTag(mod, fn) .. '\ao ' .. tostring(msg or ''))
end

return M
