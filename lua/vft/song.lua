-- VF: bard lane rules. Pure -- no TLO reads, so tools/test-song-lanes.lua covers it offline.
-- VF: Server rules 1-3 live here: skill decides sung vs stand, and only chants hold the bar.

local M = {}

-- VF: the sung skills. One character holds both songs and spells, so this is never g.cls.
local SUNG_SKILL = {
    ['Singing']                = true,
    ['Percussion Instruments'] = true,
    ['Stringed Instruments']   = true,
    ['Wind Instruments']       = true,
    ['Brass Instruments']      = true,
}

function M.isSungSkill(skill)
    return SUNG_SKILL[tostring(skill or '')] == true
end

-- VF: 'spell' must stand · 'song' sings while walking · 'chant' holds the bar until something else casts.
function M.lane(skill, beneficial)
    if not M.isSungSkill(skill) then return 'spell' end
    return beneficial and 'song' or 'chant'
end

return M
