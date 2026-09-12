-- VF: En-route mesh travel. travelResume survives pause; trip is the active latch.

local mq = require('mq')

local M = {}

function M.install(runtime, api)
    api = api or {}
    -- VF: no getCtrl here -- nothing in this file reads it.
    local pursuit     = api.pursuit or {}
    local navLoaded   = api.navLoaded or function() return false end
    local stickLoaded = api.stickLoaded or function() return false end
    local stopMoving  = api.stopMoving or function() end
    local claimMover  = api.claimMover or function() end

    local T = {}
    T.RANGE = { arrive = 15, rushArrive = 20 }
    T.TIMING = { reissue = 2.0, maxTrip = 180, closeTicks = 2, displace = 8 }

    -- VF: Active /nav latch. May be nil while travelResume still wants the dest.
    local trip = nil

    local function syncCompat()
        runtime.playerNav = trip
    end

    local function engineInCombat()
        if runtime.engineInCombat then
            return not not runtime.engineInCombat()
        end
        if runtime.inCombatState then
            return not not runtime.engineInCombat()
        end
        local cs = false
        pcall(function() cs = mq.TLO.Me.CombatState() == 'COMBAT' end)
        return cs
    end

    local function stopNavOnly()
        stopMoving()
        if navLoaded() then
            local navActive = false
            pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
            if navActive then pcall(function() mq.cmd('/nav stop') end) end
        end
        pursuit.lastNavLoc = nil
    end

    function T.clearResume()
        runtime.travelResume = nil
    end

    function T.clearTrip()
        trip = nil
        syncCompat()
    end

    -- VF: Escape / arrive / zone / new cancel -- wipe latch and durable dest.
    function T.clear()
        T.clearTrip()
        T.clearResume()
    end

    function T.active()
        return trip ~= nil or runtime.travelResume ~= nil
    end

    function T.walking()
        return trip ~= nil and not (trip.holdWhy)
    end

    function T.policy()
        if trip then return trip.policy end
        local r = runtime.travelResume
        return r and r.policy or nil
    end

    function T.trip()
        return trip
    end

    function T.resume()
        return runtime.travelResume
    end

    local function setResume(policy, y, x, z, opts)
        opts = opts or {}
        local zoneId = 0
        pcall(function() zoneId = mq.TLO.Zone.ID() or 0 end)
        runtime.travelResume = {
            policy = policy,
            y = y,
            x = x,
            z = z,
            zone = zoneId,
            arrive = tonumber(opts.arrive) or T.RANGE.arrive,
            onArrive = opts.onArrive,
            spawnId = tonumber(opts.spawnId) or nil,
            keepTarget = opts.keepTarget and true or false,
            groupCatchup = opts.groupCatchup and true or false,
            holdWhy = nil,
            holdUntil = nil,
        }
    end

    -- VF: One /nav to a place. Caller owns policy.
    function T.toLoc(y, x, z)
        y, x, z = tonumber(y), tonumber(x), tonumber(z)
        if not y or not x then return false end
        if runtime.navEscapedHold and runtime.navEscapedHold() then return false end
        claimMover('travel')
        -- VF: /nav off-mesh underwater stops the swim; leave feet to the player.
        if runtime.isInWater and runtime.isInWater() then
            if trip then trip.lastIssue = os.clock() end
            return true
        end
        if navLoaded() then
            local navActive = false
            pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
            if navActive then pcall(function() mq.cmd('/nav stop') end) end
        end
        local spec = runtime.navSpec(y, x, z)
        mq.cmdf('/nav %s', spec)
        if trip then
            trip.lastIssue = os.clock()
            if not trip.zone or trip.zone == 0 then
                pcall(function() trip.zone = mq.TLO.Zone.ID() or 0 end)
            end
        end
        pursuit.lastNavLoc = runtime.navKey('travel_', y, x, z)
        return true
    end

    -- VF: Third dest kind — track a spawn (/nav target|id), not a frozen loc. Loc = map/pins.
    function T.toSpawn(id, dist)
        id = tonumber(id) or 0
        if id <= 0 then return false end
        if runtime.navEscapedHold and runtime.navEscapedHold() then return false end
        claimMover('travel')
        local want = math.max(5, math.floor(tonumber(dist) or T.RANGE.arrive))
        local key = 'travel_id_' .. tostring(id)
        -- VF: /nav id|target in a swim tunnel same hitch as loc — do not issue.
        if runtime.isInWater and runtime.isInWater() then
            if trip then trip.lastIssue = os.clock() end
            return true
        end
        local navActive = false
        pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
        -- VF: Same spawn already tracking — do not /nav stop (that stuttered Group catch-up).
        if pursuit.lastNavLoc == key and navActive then
            if trip then trip.lastIssue = os.clock() end
            return true
        end
        local tid = 0
        pcall(function() tid = mq.TLO.Target.ID() or 0 end)
        -- VF: /nav target tracks moving PCs better than a one-shot loc; id works without a target.
        if tid == id then
            mq.cmdf('/nav target distance=%d', want)
        else
            mq.cmdf('/nav id %d distance=%d', id, want)
        end
        if trip then
            trip.lastIssue = os.clock()
            if not trip.zone or trip.zone == 0 then
                pcall(function() trip.zone = mq.TLO.Zone.ID() or 0 end)
            end
        end
        pursuit.lastNavTargetId = id
        pursuit.lastNavLoc = key
        return true
    end

    local function issueTripNav()
        if not trip then return false end
        if trip.spawnId and trip.spawnId > 0 then
            return T.toSpawn(trip.spawnId, trip.arrive)
        end
        return T.toLoc(trip.y, trip.x, trip.z)
    end

    -- VF: keepTarget=true for Manual far-close (commit stays; map Ignore still strips adds).
    local function stripCombat(opts)
        opts = opts or {}
        -- VF: guard at the writer, and it also drops /stick -- costlier to re-establish
        -- VF: than the attack toggle, so releasing mid-fight cost two things, not one.
        if runtime.attackReleaseOk and not runtime.attackReleaseOk() then return end
        if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
        if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
        if stickLoaded() then
            local stickOn = false
            pcall(function()
                stickOn = (mq.TLO.Stick.Active() or mq.TLO.Stick.Status() == 'ON') or false
            end)
            if stickOn then pcall(function() mq.cmd('/stick off') end) end
        end
        if opts.keepTarget then return end
        pcall(function()
            local t = mq.TLO.Target
            if t() and (t.Type() == 'NPC' or t.Type() == 'Pet') and not t.Dead() and t.Type() ~= 'Corpse' then
                mq.cmd('/target clear')
            end
        end)
    end

    local function dist2To(y, x)
        local mx, my = 0, 0
        pcall(function() mx = mq.TLO.Me.X() or 0 end)
        pcall(function() my = mq.TLO.Me.Y() or 0 end)
        local dx = mx - (x or 0)
        local dy = my - (y or 0)
        return math.sqrt(dx * dx + dy * dy)
    end

    -- VF: map-pin arrival needs Z or a pin one floor up counts as reached. Falls back
    -- VF: to flat when the pin carries no z, so old routes are unaffected.
    local function dist3To(y, x, z)
        local flat = dist2To(y, x)
        if z == nil then return flat end
        local mz = nil
        pcall(function() mz = mq.TLO.Me.Z() end)
        if mz == nil then return flat end
        local dz = mz - z
        return math.sqrt(flat * flat + dz * dz)
    end

    -- VF: Stop feet, keep travelResume. why = combat|displace.
    function T.pause(why, opts)
        opts = opts or {}
        why = tostring(why or 'pause')
        local r = runtime.travelResume
        if not r and trip then
            setResume(trip.policy, trip.y, trip.x, trip.z, {
                arrive = trip.arrive,
                onArrive = trip.onArrive,
                spawnId = trip.spawnId,
                keepTarget = trip.keepTarget,
                groupCatchup = trip.groupCatchup,
            })
            r = runtime.travelResume
        end
        if not r then return false end
        r.holdWhy = why
        if opts.holdUntil then
            r.holdUntil = opts.holdUntil
        elseif why == 'displace' then
            r.holdUntil = os.clock() + (T.TIMING.displace or 8)
        else
            r.holdUntil = nil
        end
        stopNavOnly()
        -- VF: Drop the walking latch; resume rebuilds it. Durable dest stays in travelResume.
        T.clearTrip()
        print(string.format('\ay[VF]\ax travel%s -- paused (%s); dest held.',
            r.policy == 'defend' and 'Defend' or 'Ignore', why))
        return true
    end

    local function blockedByHold(r)
        if not r or not r.holdWhy then return false end
        if r.holdWhy == 'combat' then
            return engineInCombat()
        end
        if r.holdWhy == 'displace' then
            if r.holdUntil and os.clock() < r.holdUntil then return true end
            -- VF: Still COMBAT after a summon -- keep holding so we do not run into the next yank.
            if engineInCombat() then return true end
            return false
        end
        return false
    end

    -- VF: Break always continues the same dest (Manual/Roam/Rush). Do not wipe on combat clear.
    local function startWalkingFromResume()
        local r = runtime.travelResume
        if not r then return false end
        local now = os.clock()
        trip = {
            policy = r.policy,
            y = r.y,
            x = r.x,
            z = r.z,
            started = now,
            lastIssue = now,
            zone = r.zone,
            arrive = r.arrive or T.RANGE.arrive,
            onArrive = r.onArrive,
            spawnId = tonumber(r.spawnId) or nil,
            keepTarget = r.keepTarget and true or false,
            groupCatchup = r.groupCatchup and true or false,
            closeTicks = 0,
            holdWhy = nil,
        }
        r.holdWhy = nil
        r.holdUntil = nil
        syncCompat()
        print(string.format('\ag[VF]\ax travel%s -- resuming Y:%.1f X:%.1f%s.',
            trip.policy == 'defend' and 'Defend' or 'Ignore',
            trip.y, trip.x, runtime.zLabel(trip.z)))
        issueTripNav()
        return true
    end

    function T.begin(policy, y, x, z, opts)
        opts = opts or {}
        policy = tostring(policy or 'ignore'):lower()
        if policy ~= 'defend' then policy = 'ignore' end
        y, x, z = tonumber(y), tonumber(x), tonumber(z)
        if not y or not x then return false end
        if y == 0 and x == 0 then return false end
        runtime.navEscapedUntil = 0
        local now = os.clock()
        local spawnId = tonumber(opts.spawnId) or 0
        if trip and (now - (trip.started or 0)) < 0.4
            and trip.policy == policy then
            if spawnId > 0 and trip.spawnId == spawnId then
                return true
            end
            if spawnId <= 0
                and math.abs((trip.y or 0) - y) < 2 and math.abs((trip.x or 0) - x) < 2 then
                return true
            end
        end
        setResume(policy, y, x, z, opts)
        trip = {
            policy = policy,
            y = y,
            x = x,
            z = z,
            started = now,
            lastIssue = now,
            zone = runtime.travelResume.zone,
            arrive = tonumber(opts.arrive) or T.RANGE.arrive,
            prep = opts.prep and true or false,
            onArrive = opts.onArrive,
            spawnId = (spawnId > 0) and spawnId or nil,
            keepTarget = opts.keepTarget and true or false,
            groupCatchup = opts.groupCatchup and true or false,
            closeTicks = 0,
            holdWhy = nil,
        }
        syncCompat()
        if not trip.prep then
            issueTripNav()
        end
        return true
    end

    function T.beginIgnore(y, x, z, opts)
        return T.begin('ignore', y, x, z, opts)
    end

    function T.beginDefend(y, x, z, opts)
        return T.begin('defend', y, x, z, opts)
    end

    -- VF: Same policy+dest while active/held → no-op. Held resume keeps holdWhy (continuation).
    function T.ensure(policy, y, x, z, opts)
        opts = opts or {}
        policy = tostring(policy or 'ignore'):lower()
        if policy ~= 'defend' then policy = 'ignore' end
        local spawnId = tonumber(opts.spawnId) or 0
        local arrive = tonumber(opts.arrive) or T.RANGE.arrive
        -- VF: Spawn trips key on id (moving PC/NPC), not frozen y/x.
        if spawnId > 0 then
            if trip and not trip.holdWhy and trip.policy == policy and trip.spawnId == spawnId
                and math.abs((trip.arrive or 0) - arrive) < 0.5 then
                return true
            end
            local r = runtime.travelResume
            if r and r.holdWhy and r.policy == policy and tonumber(r.spawnId) == spawnId then
                return true
            end
            if r and not trip and r.policy == policy and tonumber(r.spawnId) == spawnId then
                return true
            end
            y, x, z = tonumber(y), tonumber(x), tonumber(z)
            if (not y or not x) or (y == 0 and x == 0) then
                pcall(function()
                    local s = mq.TLO.Spawn(spawnId)
                    if s and s() then
                        y, x, z = s.Y() or 0, s.X() or 0, s.Z() or 0
                    end
                end)
            end
            if not y or not x or (y == 0 and x == 0) then return false end
            return T.begin(policy, y, x, z, opts)
        end
        y, x, z = tonumber(y), tonumber(x), tonumber(z)
        if not y or not x or (y == 0 and x == 0) then return false end
        -- VF: Z counts. Without it a destination directly above or below the active
        -- VF: one read as "already going there" and ensure() returned true without
        -- VF: retargeting, so we kept walking to the wrong floor. Only compare z when
        -- VF: both sides have one, so a flat pin still matches a flat trip.
        local function sameDest(py, px, pz)
            if math.abs((py or 0) - y) >= 2 or math.abs((px or 0) - x) >= 2 then
                return false
            end
            if z ~= nil and pz ~= nil and math.abs(pz - z) >= 10 then return false end
            return true
        end
        if trip and not trip.holdWhy and trip.policy == policy and sameDest(trip.y, trip.x, trip.z)
            and math.abs((trip.arrive or 0) - arrive) < 0.5 then
            return true
        end
        local r = runtime.travelResume
        if r and r.holdWhy then
            if r.policy ~= policy or not sameDest(r.y, r.x, r.z)
                or math.abs((r.arrive or 0) - arrive) >= 0.5 then
                local why, holdUntil = r.holdWhy, r.holdUntil
                setResume(policy, y, x, z, opts)
                r = runtime.travelResume
                r.holdWhy, r.holdUntil = why, holdUntil
            end
            return true
        end
        if r and not trip and r.policy == policy and sameDest(r.y, r.x) then
            return true
        end
        return T.begin(policy, y, x, z, opts)
    end

    -- VF: Group / Manual far-close — ignore policy + spawn track (/nav target|id).
    function T.ensureSpawn(policy, id, opts)
        opts = opts or {}
        id = tonumber(id) or 0
        if id <= 0 then return false end
        opts.spawnId = id
        return T.ensure(policy, nil, nil, nil, opts)
    end

    function T.policyFor(mode)
        mode = tostring(mode or '')
        if mode == 'Roam' then return 'defend' end
        if mode == 'Rush' then return 'ignore' end
        return nil
    end

    -- VF: Manual far-close -- travelIgnore to spawn, keep target, attack off until range+LoS.
    function T.beginIgnoreSpawn(id, opts)
        opts = opts or {}
        id = tonumber(id) or 0
        if id <= 0 then return false end
        local y, x, z = 0, 0, 0
        pcall(function()
            local s = mq.TLO.Spawn(id)
            if s and s() then
                y, x, z = s.Y() or 0, s.X() or 0, s.Z() or 0
            end
        end)
        if (not y or not x) or (y == 0 and x == 0) then return false end
        opts.spawnId = id
        opts.keepTarget = true
        return T.beginIgnore(y, x, z, opts)
    end

    function T.issue()
        if not trip then return false end
        trip.prep = false
        return issueTripNav()
    end

    -- VF: true = travel owns move this tick.
    function T.tick()
        if runtime.navEscapedHold and runtime.navEscapedHold() then
            T.clear()
            return false
        end

        local r = runtime.travelResume
        if r then
            local zoneId = 0
            pcall(function() zoneId = mq.TLO.Zone.ID() or 0 end)
            if r.zone and r.zone > 0 and zoneId > 0 and r.zone ~= zoneId then
                T.clear()
                stopNavOnly()
                print('\ay[VF]\ax travel dropped -- zone changed.')
                return false
            end
        end

        if runtime.escapeKeyDown and runtime.escapeKeyDown() then
            if runtime.escapeHardStopNav then
                runtime.escapeHardStopNav()
            else
                T.clear()
                stopNavOnly()
                runtime.navEscapedUntil = os.clock() + (runtime.NAV_ESC_HOLD or 12)
            end
            print('\ay[VF]\ax travel cancelled.')
            return false
        end

        -- VF: Held dest, no walking latch -- wait out combat/displace then rebuild trip.
        if not trip and r then
            if blockedByHold(r) then
                return false
            end
            if r.holdWhy then
                return startWalkingFromResume()
            end
            -- VF: Resume dest with no hold and no trip (cleared under us) -- walk again.
            return startWalkingFromResume()
        end

        if not trip then return false end

        if trip.prep then
            return true
        end

        -- VF: Defend pauses on CombatState COMBAT, Me.Combat, or a live NPC target (Roam engage mid-pin).
        if trip.policy == 'defend' then
            local hot = engineInCombat()
            if not hot then
                pcall(function() hot = not not mq.TLO.Me.Combat() end)
            end
            if not hot then
                pcall(function()
                    local t = mq.TLO.Target
                    if t() and t.Type() == 'NPC' and not t.Dead() then hot = true end
                end)
            end
            if hot then
                T.pause('combat')
                return false
            end
        end

        -- VF: do not /attack off an armed Manual pack — leftover ignore was stealing the next swing.
        if trip.policy == 'ignore' then
            local fighting = runtime.manualFightArmed
                or ((tonumber(runtime.manualCommitId) or 0) > 0)
            pcall(function()
                if mq.TLO.Me.Combat() then fighting = true end
            end)
            if not fighting then
                stripCombat({ keepTarget = trip.keepTarget })
            end
        end

        local d = dist3To(trip.y, trip.x, trip.z)
        local losOk = true
        local spawnGone = false
        local spawnReach = 0
        if trip.spawnId and trip.spawnId > 0 then
            local sid = trip.spawnId
            local sOk = false
            pcall(function()
                local s = mq.TLO.Spawn(sid)
                if not s or not s() or s.Dead() or s.Type() == 'Corpse' then
                    spawnGone = true
                    return
                end
                sOk = true
                d = tonumber(s.Distance3D()) or d
                losOk = not not s.LineOfSight()
                spawnReach = tonumber(s.MaxRangeTo()) or tonumber(s.MaxMeleeTo()) or 0
                trip.y, trip.x, trip.z = s.Y() or trip.y, s.X() or trip.x, s.Z() or trip.z
                if runtime.travelResume then
                    runtime.travelResume.y, runtime.travelResume.x, runtime.travelResume.z =
                        trip.y, trip.x, trip.z
                end
            end)
            if spawnGone or not sOk then
                T.clear()
                stopNavOnly()
                print('\ay[VF]\ax travelIgnore -- spawn gone.')
                return false
            end
        end

        local navActive = false
        pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
        local arriveAt = trip.arrive or T.RANGE.arrive
        if spawnReach > 0 then
            arriveAt = math.max(arriveAt, spawnReach)
        end
        -- VF: stick_handoff (120) -- yield /nav. Stick owns the last stretch.
        local stickBand = (runtime.stickHandoff and runtime.stickHandoff()) or (runtime.STICK_HANDOFF or 120)
        -- VF: losOk is required. A wall is the one thing /stick cannot solve, so
        -- VF: handing off inside the band with no line of sight parked us against
        -- VF: the geometry. Same exception moveToward makes: no LoS keeps navving.
        if trip.spawnId and d <= stickBand and losOk then
            local cb = trip.onArrive
            T.clear()
            stopNavOnly()
            if cb then pcall(cb) end
            return false
        end
        -- VF: spawn close needs range + LoS; map pin only needs range.
        local atPin = (d <= arriveAt) and losOk and not navActive
        if atPin then
            trip.closeTicks = (trip.closeTicks or 0) + 1
            if trip.closeTicks >= (T.TIMING.closeTicks or 2) then
                local cb = trip.onArrive
                T.clear()
                if cb then pcall(cb) end
                return false
            end
        else
            trip.closeTicks = 0
        end

        if (os.clock() - (trip.started or 0)) > (T.TIMING.maxTrip or 180) then
            T.clear()
            return false
        end

        if not navActive then
            if runtime.isInWater and runtime.isInWater() then
                if not trip.wetSkip then
                    trip.wetSkip = true
                    print('\ay[VF]\ax travel -- swimming, mesh idle; no /nav reissue.')
                end
            else
                local last = trip.lastIssue or trip.started or 0
                if (os.clock() - last) >= (T.TIMING.reissue or 2.0) then
                    issueTripNav()
                end
            end
        end
        return true
    end

    function T.beginFollow(leaderId, dist)
        return T.ensureSpawn('ignore', leaderId, {
            arrive = tonumber(dist) or T.RANGE.arrive,
            keepTarget = true,
            groupCatchup = true,
        })
    end

    runtime.travel = T
    syncCompat()
    return T
end

return M
