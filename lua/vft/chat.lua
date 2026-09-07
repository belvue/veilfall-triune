---@diagnostic disable: undefined-global, undefined-field
-- VF: MQ console lines — [VF:<module>] msg. Purple chrome, cyan letters (MQ closest to brand).
-- VF: Usage: local chat = require('vft.chat'); chat.say('Inv', 'Opening'); chat.err('Inv', err)
-- VF: No \ax before msg (inherits prior). No bold in MQ echo. No exact #b56bff — \ap is the purple lane.

local M = {}

function M.tag(mod)
    -- VF: \ap purple []:; \at cyan VF + module.
    return '\ap[\atVF\ap:\at' .. tostring(mod or '?') .. '\ap]'
end

function M.say(mod, msg)
    -- VF: \a-w grey (W2 from the color strip).
    print(M.tag(mod) .. '\a-w ' .. tostring(msg or ''))
end

function M.err(mod, msg)
    print(M.tag(mod) .. '\ar ' .. tostring(msg or ''))
end

return M
