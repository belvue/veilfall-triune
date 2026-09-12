-- VF: pure helpers. No MQ/ImGui. Apostrophe strip is load-bearing for song names.

local D = require('vft.data')
-- VF: toCanonicalClassAbbr closed over this as a main-chunk local.
local ALL_ABBR = D.ALL_ABBR

-- VF: no-match is 1, not 0, because every ImGui.Combo caller feeds this straight
-- VF: back as a 1-based selection. Do NOT "fix" it to 0. It is therefore useless
-- VF: as a membership test -- use contains() for that.
local function idxOf(tbl, val)
    if not tbl then return 1 end
    for i, v in ipairs(tbl) do
        if v == val then return i end
    end
    return 1
end

local function contains(tbl, val)
    if not tbl then return false end
    for _, v in ipairs(tbl) do
        if v == val then return true end
    end
    return false
end

-- VF: '%' is the user-facing wildcard (SQL style, matching MQ's own filter syntax),
-- VF: so %Guard% means "contains Guard". Every other character is literal, which
-- VF: matters because mob names carry '.', '-' and apostrophes that are Lua magic.
local function wildToPattern(pat)
    -- VF: \1 stands in for the wildcard so escaping cannot eat it.
    local p = tostring(pat):gsub('%%', '\1')
    p = p:gsub('[%^%$%(%)%.%[%]%*%+%-%?%%]', '%%%0')
    p = p:gsub('\1', '.*')
    return '^' .. p .. '$'
end

-- VF: case-insensitive whole-name match against one '%' wildcard pattern.
local function wildMatch(str, pat)
    if type(str) ~= 'string' or str == '' then return false end
    pat = tostring(pat or '')
    if pat == '' then return false end
    local ok, hit = pcall(string.find, str:lower(), wildToPattern(pat:lower()))
    return (ok and hit) and true or false
end

-- VF: true if any pattern in the list matches. Used for the per-zone Block List.
local function wildMatchAny(str, list)
    if type(list) ~= 'table' then return false end
    for _, pat in ipairs(list) do
        if wildMatch(str, pat) then return true end
    end
    return false
end

local function toCanonicalClassAbbr(str)
    if not str then return nil end
    local s = tostring(str)
    if s == '' or s == 'nil' or s == 'NULL' then return nil end
    local up = s:upper():gsub('%s+', '')
    local MQSHORT = {
        WARRIOR = 'War', WAR = 'War', WARRIORS = 'War',
        CLERIC = 'Clr', CLR = 'Clr', CLERICS = 'Clr',
        PALADIN = 'Pal', PAL = 'Pal', PALADINS = 'Pal',
        RANGER = 'Rng', RNG = 'Rng', RANGERS = 'Rng',
        SHADOWKNIGHT = 'SK', SHADOW = 'SK', SHD = 'SK', SK = 'SK', SHADOWKNIGHTS = 'SK',
        DRUID = 'Dru', DRU = 'Dru', DRUIDS = 'Dru',
        MONK = 'Mnk', MNK = 'Mnk', MONKS = 'Mnk',
        BARD = 'Brd', BRD = 'Brd', BARDS = 'Brd',
        ROGUE = 'Rog', ROG = 'Rog', ROGUES = 'Rog',
        SHAMAN = 'Shm', SHM = 'Shm', SHAMANS = 'Shm',
        NECROMANCER = 'Nec', NEC = 'Nec', NECROMANCERS = 'Nec',
        WIZARD = 'Wiz', WIZ = 'Wiz', WIZARDS = 'Wiz',
        MAGICIAN = 'Mag', MAG = 'Mag', MAGICIANS = 'Mag',
        ENCHANTER = 'Enc', ENC = 'Enc', ENCHANTERS = 'Enc',
        BEASTLORD = 'Bst', BST = 'Bst', BEASTLORDS = 'Bst',
        BERSERKER = 'Ber', BER = 'Ber', BERSERKERS = 'Ber'
    }
    -- VF: was idxOf(...) > 0, which is always true -- idxOf returns 1 on no-match,
    -- VF: so any junk string came back as a valid class abbreviation.
    return MQSHORT[up] or (contains(ALL_ABBR, s) and s) or nil
end

local function defaultsForKind(kind, bene)
    if kind == 'heal' then return 'F: Myself', 'my HP <=', 75 end
    if kind == 'buff' then return 'F: Myself', 'missing buff', 100 end
    if kind == 'pet' then return 'F: Myself', 'missing pet', 100 end
    if kind == 'util' then return 'F: Myself', 'always', 100 end
    if kind == 'debuff' then return 'E: Current Target', 'target HP <=', 98 end
    if kind == 'dot' then return 'E: Current Target', 'target HP <=', 98 end
    if kind == 'dd' then return 'E: Current Target', 'target HP <=', 95 end
    if bene == true then return 'F: Myself', 'missing buff', 100 end
    return 'E: Current Target', 'target HP <=', 95
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

local function trimName(nm)
    return tostring(nm or ''):match('^%s*(.-)%s*$') or ''
end

local function sungKey(spellName, targetId)
    return string.format('%d_%s', targetId or 0, normalizeSpellName(spellName))
end

-- VF: numbers before strings, each ascending. pairs() order is not stable, so
-- VF: without this every save reshuffled the loadout file and you could not read
-- VF: a diff to see what actually changed.
local function sortedKeys(o)
    local keys = {}
    for k in pairs(o) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta == 'number' end
        if ta == 'number' or ta == 'string' then return a < b end
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function serialize(o, f, indent)
    local t = type(o)
    if t == 'number' or t == 'boolean' then
        f:write(tostring(o))
    elseif t == 'string' then
        f:write(string.format('%q', o))
    elseif t == 'table' then
        f:write('{\n')
        for _, k in ipairs(sortedKeys(o)) do
            f:write(string.rep('  ', indent))
            if type(k) == 'string' then
                f:write('[' .. string.format('%q', k) .. ']=')
            else
                f:write('[' .. tostring(k) .. ']=')
            end
            serialize(o[k], f, indent + 1); f:write(',\n')
        end
        f:write(string.rep('  ', indent - 1) .. '}')
    else
        f:write('nil')
    end
end

-- VF: never truncate the live file. Serialize to .tmp, prove it loads, then swap,
-- VF: keeping the previous copy as .old until the swap succeeds. io.open(path,'w')
-- VF: truncates first, so a crash mid-write left a half-written loadout and no
-- VF: fallback. mgr/io.lua does the same dance with its own extra checks.
local function writeTable(path, value, prefix)
    local tmp = path .. '.tmp'
    local f, err = io.open(tmp, 'w')
    if not f then return false, err or 'cannot open temp file' end
    local ok, werr = pcall(function()
        if prefix then f:write(prefix) end
        serialize(value, f, 1)
        f:write('\n')
    end)
    f:close()
    if not ok then
        pcall(os.remove, tmp)
        return false, tostring(werr)
    end
    -- VF: a file that does not load is worse than a stale one. Check before swapping.
    if prefix and not loadfile(tmp) then
        pcall(os.remove, tmp)
        return false, 'temp file does not parse'
    end
    local old = path .. '.old'
    pcall(os.remove, old)
    local live = io.open(path, 'rb')
    if live then
        live:close()
        -- VF: Windows rename will not clobber, so the live file has to move aside.
        os.rename(path, old)
    end
    local moved, merr = os.rename(tmp, path)
    if not moved then
        local back = io.open(old, 'rb')
        if back then
            back:close()
            os.rename(old, path)
        end
        return false, merr or 'rename failed'
    end
    pcall(os.remove, old)
    return true
end

local function baseTok(token)
    local s = tostring(token or '')
    s = s:gsub('^[FE]:%s*', '')
    if s == 'Target' or s == 'Current Target' then return 'Current Target' end
    if s == 'Self' or s == 'Myself' then return 'Myself' end
    return s
end

return {
    idxOf = idxOf,
    contains = contains,
    wildMatch = wildMatch,
    wildMatchAny = wildMatchAny,
    toCanonicalClassAbbr = toCanonicalClassAbbr,
    defaultsForKind = defaultsForKind,
    cleanSpellName = cleanSpellName,
    normalizeSpellName = normalizeSpellName,
    apostropheVariants = apostropheVariants,
    trimName = trimName,
    sungKey = sungKey,
    serialize = serialize,
    writeTable = writeTable,
    baseTok = baseTok,
}
