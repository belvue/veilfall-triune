-- VF: overlay version. main is 0.6.N; beta is 0.6.N.B (missing B compares as 0).

local M = {}

function M.parse(body)
    body = tostring(body or '')
    if body == '' or body:find('404:', 1, true) or body:find('<', 1, true) then
        return ''
    end
    local line = body:match('^%s*([^\r\n]+)') or ''
    -- VF: four-part first or 0.6.17.2 is read as 0.6.17 and Check skips.
    return line:match('(%d+%.%d+%.%d+%.%d+)') or line:match('(%d+%.%d+%.%d+)') or ''
end

function M.parts(v)
    v = tostring(v or '')
    local a, b, c, d = v:match('(%d+)%.(%d+)%.(%d+)%.(%d+)')
    if a then
        return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0, tonumber(d) or 0
    end
    a, b, c = v:match('(%d+)%.(%d+)%.(%d+)')
    return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0, 0
end

function M.cmp(a, b)
    local a1, a2, a3, a4 = M.parts(a)
    local b1, b2, b3, b4 = M.parts(b)
    if a1 ~= b1 then return (a1 < b1) and -1 or 1 end
    if a2 ~= b2 then return (a2 < b2) and -1 or 1 end
    if a3 ~= b3 then return (a3 < b3) and -1 or 1 end
    if a4 ~= b4 then return (a4 < b4) and -1 or 1 end
    return 0
end

return M
