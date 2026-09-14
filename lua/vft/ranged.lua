-- VF: Ranged stand-off — rubber band, /nav loc back-off (not stick / keypress), LoS, melee fallback.

local M = {}

local ANGLES = { 0, 22, -22, 45, -45, 70, -70, 110, -110 }
local MIN_SLACK = 4
local ARRIVE = 8
local BACK_TIMEOUT = 6
local MIN_STAND = 8

function M.clampStand(n)
    n = tonumber(n)
    if not n then n = 40 end
    if n < 0 then n = 0 end
    if n > 300 then n = 300 end
    return math.floor(n + 0.5)
end

function M.clampRubber(n)
    n = tonumber(n)
    if not n then n = 20 end
    if n < 0 then n = 0 end
    if n > 50 then n = 50 end
    return math.floor(n + 0.5)
end

-- VF: 120 @ 20% rubber → hold 96–144, no reposition.
function M.standBand(stand, rubberPct)
    stand = M.clampStand(stand)
    rubberPct = M.clampRubber(rubberPct)
    if stand <= 0 then return 0, 0, 0 end
    local slack = math.max(MIN_SLACK, stand * (rubberPct / 100.0))
    local lo = math.max(0, stand - slack)
    local hi = stand + slack
    return stand, lo, hi
end

function M.inBand(d, lo, hi)
    d = tonumber(d) or 0
    return d >= (tonumber(lo) or 0) and d <= (tonumber(hi) or 0)
end

-- VF: point `dist` from mob along (from - mob), rotated angleDeg. headingDeg if stacked.
function M.radialPoint(mobX, mobY, fromX, fromY, dist, angleDeg, headingDeg)
    mobX, mobY = tonumber(mobX) or 0, tonumber(mobY) or 0
    fromX, fromY = tonumber(fromX) or 0, tonumber(fromY) or 0
    dist = tonumber(dist) or 0
    angleDeg = tonumber(angleDeg) or 0
    local dx, dy = fromX - mobX, fromY - mobY
    local len = math.sqrt(dx * dx + dy * dy)
    local nx, ny
    if len < 0.25 then
        local h = tonumber(headingDeg) or 0
        local rad = math.rad(h)
        nx, ny = math.sin(rad), math.cos(rad)
    else
        nx, ny = dx / len, dy / len
    end
    if angleDeg ~= 0 then
        local a = math.rad(angleDeg)
        local c, s = math.cos(a), math.sin(a)
        nx, ny = nx * c - ny * s, nx * s + ny * c
    end
    return mobX + nx * dist, mobY + ny * dist
end

function M.install(runtime, api)
    api = api or {}
    local mq = require('mq')
    local getCtrl = api.ctrl or function() return {} end
    local pursuit = api.pursuit or {}
    local distToId = api.distToId or function() return 999 end
    local distToLoc = api.distToLoc or function() return 999 end
    local hasLoS = api.hasLoS or function() return true end
    local moveToward = api.moveToward or function() return false end
    local moveTowardLoc = api.moveTowardLoc or function() return false end
    local stopMoving = api.stopMoving or function() end
    local maxMeleeDistance = api.maxMeleeDistance or function() return 14 end

    local st = {
        id = 0, dest = nil, tried = {}, since = 0, meleeId = 0,
        warnedMelee = false, warnAt = 0,
    }

    local function reset()
        st.id = 0
        st.dest = nil
        st.tried = {}
        st.since = 0
        st.meleeId = 0
        st.warnedMelee = false
    end

    runtime.rangedReset = reset

    runtime.rangedStandBand = function()
        local ctrl = getCtrl()
        return M.standBand(ctrl and ctrl.ranged_dist, ctrl and ctrl.ranged_rubber_pct)
    end

    runtime.rangedMeleeFallback = function(id)
        id = tonumber(id) or 0
        return id > 0 and st.meleeId == id
    end

    local function spawnXYZ(id)
        local x, y, z = nil, nil, nil
        pcall(function()
            local s = mq.TLO.Spawn(id)
            if s and s() then
                x = tonumber(s.X())
                y = tonumber(s.Y())
                z = tonumber(s.Z())
            end
        end)
        return x, y, z
    end

    local function meXYZ()
        local x, y, z = 0, 0, 0
        pcall(function()
            x = tonumber(mq.TLO.Me.X()) or 0
            y = tonumber(mq.TLO.Me.Y()) or 0
            z = tonumber(mq.TLO.Me.Z()) or 0
        end)
        return x, y, z
    end

    local function headingDeg()
        local h = 0
        pcall(function() h = tonumber(mq.TLO.Me.Heading.Degrees()) or 0 end)
        return h
    end

    -- VF: Rooted is a buff TLO (name), Stunned is bool. Summon often roots in melee.
    local function cannotPark()
        local stuck = false
        pcall(function()
            if mq.TLO.Me.Stunned() then stuck = true; return end
            local r = mq.TLO.Me.Rooted
            if r and r.ID and (tonumber(r.ID()) or 0) > 0 then stuck = true; return end
            local n = r and r()
            if n and n ~= false then
                local s = tostring(n)
                if s ~= '' and s ~= 'NULL' and s ~= 'nil' and s ~= '0' then stuck = true end
            end
        end)
        return stuck
    end

    -- VF: y,x,z:y2,x2,z2. Fail open if the TLO errors.
    local function locLos(x, y, z, tx, ty, tz)
        local got = false
        local ok = true
        pcall(function()
            local q = string.format('%.2f,%.2f,%.2f:%.2f,%.2f,%.2f', y, x, z, ty, tx, tz)
            local v = mq.TLO.LineOfSight(q)
            if type(v) == 'function' then v = v() end
            if v == nil then return end
            got = true
            ok = not not v
        end)
        if not got then return true end
        return ok
    end

    local function allyXY()
        local ctrl = getCtrl()
        local id = 0
        if runtime.groupAnchorId then
            id = tonumber(runtime.groupAnchorId(ctrl and ctrl.ma_name)) or 0
        end
        if id <= 0 then return nil, nil end
        local x, y = spawnXYZ(id)
        return x, y
    end

    local function destKey(x, y)
        if runtime.navKey then return runtime.navKey('rng_', y, x, nil) end
        return string.format('rng_%.0f_%.0f', y, x)
    end

    local function pickDest(tid, stand)
        local mx, my, mz = spawnXYZ(tid)
        if not mx or not my then return nil end
        local ex, ey, ez = meXYZ()
        local ax, ay = allyXY()
        local maxWalk = stand + 60
        local best, bestScore = nil, 1e12
        for _, ang in ipairs(ANGLES) do
            local x, y = M.radialPoint(mx, my, ex, ey, stand, ang, headingDeg())
            local key = destKey(x, y)
            if not st.tried[key] then
                local dx, dy = x - ex, y - ey
                local walk = math.sqrt(dx * dx + dy * dy)
                if walk <= maxWalk then
                    local z = ez
                    if mz and math.abs((mz or 0) - ez) < 8 then z = ez end
                    if locLos(x, y, z, mx, my, mz or z) then
                        local score = math.abs(ang)
                        if ax and ay then
                            local adx, ady = x - ax, y - ay
                            score = math.sqrt(adx * adx + ady * ady)
                        end
                        score = score + walk * 0.05
                        if score < bestScore then
                            bestScore = score
                            best = { x = x, y = y, z = nil, key = key }
                        end
                    end
                end
            end
        end
        return best
    end

    local function holdShot(tid)
        st.dest = nil
        stopMoving()
        local now = os.clock()
        if (now - (runtime.rangedFaceAt or 0)) > 0.35 then
            runtime.rangedFaceAt = now
            mq.cmdf('/face fast id %d', tid)
        end
        local ctrl = getCtrl()
        -- VF: Autofire on = /autofire only. Never /attack on or /killthis at stand-off.
        if ctrl and ctrl.ranged_autofire == false then
            if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
            return
        end
        if not mq.TLO.Me.AutoFire() then mq.cmd('/autofire on') end
    end

    local function meleeFallback(tid, why)
        st.meleeId = tid
        st.dest = nil
        if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
        -- VF: AssistOn — ensureAttack + stick. meleeNow opens those gates for this id.
        if runtime.assistOn then
            runtime.assistOn(tid)
        else
            if runtime.ensureAttack then runtime.ensureAttack(tid) end
            if runtime.stickPursue then runtime.stickPursue(tid) end
        end
        if not st.warnedMelee then
            st.warnedMelee = true
            print(string.format('\ay[VF]\ax Ranged -- no LoS nav park (%s); melee until this mob dies.',
                why or 'blocked'))
        end
    end

    local function navBack(tid, stand)
        local now = os.clock()
        if st.dest then
            local locKey = st.dest.key
            if pursuit.navRefusedKey == locKey then
                st.tried[locKey] = true
                st.dest = nil
            elseif (now - (st.since or 0)) > BACK_TIMEOUT then
                st.tried[locKey] = true
                st.dest = nil
            else
                if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
                if moveTowardLoc(st.dest.x, st.dest.y, st.dest.z, ARRIVE) then
                    st.tried[locKey] = true
                    st.dest = nil
                end
                return
            end
        end
        local dest = pickDest(tid, stand)
        if not dest then
            meleeFallback(tid, 'no mesh LoS spot')
            return
        end
        st.dest = dest
        st.since = now
        if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
        moveTowardLoc(dest.x, dest.y, dest.z, ARRIVE)
    end

    -- VF: never /keypress back. /nav loc to a rubber-band park; melee if LoS/mesh cannot.
    runtime.rangedFightTick = function(tid, mayClose)
        tid = tonumber(tid) or 0
        if tid <= 0 then return end
        if runtime.manualFightConsent and not runtime.manualFightConsent() then return end
        if runtime.groupFadeHold and runtime.groupFadeHold() then return end
        if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end

        if st.id ~= tid then
            st.id = tid
            st.dest = nil
            st.tried = {}
            st.since = 0
            st.meleeId = 0
            st.warnedMelee = false
        end

        local d = distToId(tid)
        local stand, lo, hi = runtime.rangedStandBand()
        local los = hasLoS(tid)

        if stand < MIN_STAND then
            meleeFallback(tid, 'max distance 0')
            return
        end

        if st.meleeId == tid then
            if M.inBand(d, lo, hi) and los then
                st.meleeId = 0
                st.warnedMelee = false
                holdShot(tid)
                return
            end
            meleeFallback(tid, 'latched')
            return
        end

        -- VF: rooted/summoned in melee → real melee. Stuck out of melee → shoot from here.
        if cannotPark() then
            if d <= maxMeleeDistance(tid) then
                meleeFallback(tid, 'rooted/summoned')
                return
            end
            if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
            holdShot(tid)
            return
        end

        if mq.TLO.Me.Combat() then mq.cmd('/attack off') end

        if M.inBand(d, lo, hi) and los then
            holdShot(tid)
            return
        end

        if d > hi then
            st.dest = nil
            st.tried = {}
            if mayClose and not (runtime.castingMustStand and runtime.castingMustStand()) then
                moveToward(tid, stand)
            end
            return
        end

        -- VF: too close, or in-band with no LoS — park on the mesh, not stick/keyboard.
        if mayClose and not (runtime.castingMustStand and runtime.castingMustStand()) then
            navBack(tid, stand)
            return
        end
        holdShot(tid)
    end
end

return M
