-- VF: settings helpers. Apostrophe strip matches ta/util.lua -- do not retype it.

local function idxOf(tbl, val)
    if not tbl then return 1 end
    for i, v in ipairs(tbl) do
        if v == val then return i end
    end
    return 1
end

local function trimName(nm)
    return tostring(nm or ''):match('^%s*(.-)%s*$') or ''
end

-- VF: EQ/MQ mix ASCII ', backtick, and UTF-8 curly quotes on the same song (Katta's / Katta`s / Katta’s).
local function stripApostrophes(s)
    if not s or type(s) ~= 'string' then return '' end
    s = s:gsub("[''`´]", '')
    s = s:gsub('\226\128[\152\153\154\155]', '')
    return s
end

local function apostropheVariants(name)
    name = tostring(name or '')
    if name == '' then return { name } end
    local out, seen = {}, {}
    local function add(s)
        if s ~= '' and not seen[s] then
            seen[s] = true
            out[#out + 1] = s
        end
    end
    add(name)
    local deutf = name:gsub('\226\128[\152\153\154\155]', "'")
    add(deutf)
    add(deutf:gsub("'", '`'))
    add(deutf:gsub('`', "'"))
    add(stripApostrophes(name))
    return out
end

local function cleanSpellName(name)
    if not name or type(name) ~= 'string' then return "" end
    local cleaned = name:gsub('%s*%([^)]*%)$', '')
    return (cleaned:gsub('^%s*(.-)%s*$', '%1'))
end

local function normalizeSpellName(name)
    if not name or type(name) ~= 'string' then return "" end
    local s = name:lower()
    s = stripApostrophes(s)
    s = s:gsub('%s*%(?%s*rk%.?%s*[%ivxlc%d]+%s*%)?', '')
    s = s:gsub('%s*%([^%)]+%)', '')
    s = s:gsub('[%p%s]', '')
    return s
end

local function fmtSec(s)
    s = tonumber(s) or 0
    if s < 60 then return s .. 's' end
    local m = math.floor(s / 60); local r = s % 60
    return (r == 0) and (m .. 'm') or (m .. 'm ' .. r .. 's')
end

-- VF: Disc sheet times as 00:00:00 (Combat Skills style).
local function fmtHMS(s)
    s = math.floor((tonumber(s) or 0) + 0.5)
    if s <= 0 then return '—' end
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = s % 60
    return string.format('%02d:%02d:%02d', h, m, sec)
end

-- VF: one serializer, in vft.util. This was a byte-identical copy, so a fix to
-- VF: either one (sorted keys, escaping) silently missed half the config writes.
local serialize = require('vft.util').serialize

return {
    idxOf = idxOf,
    trimName = trimName,
    stripApostrophes = stripApostrophes,
    apostropheVariants = apostropheVariants,
    cleanSpellName = cleanSpellName,
    normalizeSpellName = normalizeSpellName,
    fmtSec = fmtSec,
    fmtHMS = fmtHMS,
    serialize = serialize,
}
