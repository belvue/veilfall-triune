-- VF: Non-combat walkers: Puller Rush, the hunt pin cursor, and map/player nav.

local mq = require('mq')

local M = {}

function M.install(runtime, api)
    api = api or {}

    -- VF: ta.lua REASSIGNS ctrl wholesale in onCharacterChanged, so this stays a getter.
    local getCtrl       = api.ctrl or function() return {} end
    local pursuit       = api.pursuit or {}
    -- VF: no navLoaded / stickLoaded here -- nothing in this file reads them.
    local stopMoving    = api.stopMoving or function() end
    local moveTowardLoc = api.moveTowardLoc or function() end
    local isMoveActive  = api.isMoveActive or function() return false end

    local W = {}

    -- VF: Every one of these was tuned against a live symptom.
    W.RANGE = {
        arrive     = 35,  -- close enough to call it "on the pin"
        guide      = 25,  -- legacy guide handoff (chain is the live roll-through)
        guideLate  = 60,  -- handoff once nav has already stopped
        park       = 12,  -- below moveTowardLoc's stop, so a guide never parks
        travelPark = 20,  -- normal approach stop
        huntArrive = 20,  -- hunt pin arrival
        fight      = 80,  -- fallback for runtime.rushNear
        chain      = 20,  -- guide: if this close, repin next (no lookahead — that flip-flopped)
    }
    W.TIMING = {
        train     = 4,    -- loop pin waits for the train to catch up
        stall     = 12,   -- no progress toward a pin before we call it unreachable
        coldHate  = 30,   -- hate list that cannot reach us before we move on
        displace  = 8,    -- after summon/yank: hold fight before re-anchoring
    }

    -- VF: Walker state.

    -- VF: Three nested scopes, widest last.
    function W.reset(scope)
        local n = runtime.nav
        n.fighting, n.engaged = false, false
        n.arrivedAt, n.reachAt = nil, nil
        n.watch.pin, n.watch.best, n.watch.at = nil, nil, nil
        if scope ~= 'route' and scope ~= 'zone' then return end
        n.clearedPin, n.anchored, n.travelSpent, n.warned = 0, false, false, false
        n.reanchor = false
        if scope ~= 'zone' then return end
        n.pin = 1
        -- VF: Map/Rush dests are zone-local; keep them and /nav walks the old mesh forever.
        W.rushTripClear()
        pursuit.id, pursuit.lastNavTargetId, pursuit.lastNavLoc = 0, 0, nil
    end

    function W.resetOnPlay()
        W.reset('route')
    end

    -- VF: debug only, and self-capping. The callers do NOT gate on moverDebug and
    -- VF: displacement fires on knockback, summon and zone hitches, so this was an
    -- VF: unbounded append plus a file open/close inside the movement path. It grew
    -- VF: ta_rush.log to 76MB live. Gate here so no call site can forget.
    local logBytes = nil
    function W.log(msg)
        if not runtime.moverDebug then return end
        local line = string.format('%.2f %s\n', os.clock(), tostring(msg))
        pcall(function()
            local path = (mq.configDir or '.') .. '/ta_rush.log'
            if logBytes == nil then
                local probe = io.open(path, 'rb')
                if probe then
                    logBytes = probe:seek('end') or 0
                    probe:close()
                else
                    logBytes = 0
                end
            end
            -- VF: roll at 8MB, keep one generation. A trace, not a record.
            if logBytes > 8388608 then
                pcall(os.remove, path .. '.old')
                os.rename(path, path .. '.old')
                logBytes = 0
            end
            local f = io.open(path, 'a')
            if not f then return end
            f:write(line)
            f:close()
            logBytes = logBytes + #line
        end)
    end

    -- VF: Displacement: we were moved without asking.

    -- VF: No legitimate movement reaches this speed, and a sample wider than the window means we were loading or paused, not moving.
    W.DISPLACE = { speed = 400, window = 2.0 }

    -- VF: something moved us -- summon, knockback, fear. Nav pins, pursuit
    -- VF: distances and the stall watchdog all read a position that no longer exists, so drop them before the next pathing decision.
    function W.displaced(why)
        local n = runtime.nav
        local now = os.clock()
        if (now - (n.displacedAt or -60)) < 1.0 then return end
        n.displacedAt = now
        stopMoving()
        -- VF: Map travel keeps travelResume and pauses; do not wipe the dest on summon.
        local paused = false
        if runtime.travel and runtime.travel.pause then
            paused = runtime.travel.pause('displace', {
                holdUntil = now + (W.TIMING.displace or 8),
            }) and true or false
        end
        if not paused then
            runtime.rushDest = nil
            runtime.rushCloseTicks = 0
            if runtime.travel and runtime.travel.clearTrip then
                runtime.travel.clearTrip()
            else
                runtime.playerNav = nil
            end
        end
        pursuit.id, pursuit.lastNavTargetId, pursuit.lastNavLoc = 0, 0, nil
        pursuit.bestDist, pursuit.improvedAt = nil, now
        n.watch.pin, n.watch.best, n.watch.at = nil, nil, nil
        n.reanchor = true
        -- VF: Stay in fight until proximity is cold (or displace hold ends). Do not mark engaged yet —
        -- VF: that made empty-XTarget summons take "hate list clear" / re-anchor travel immediately.
        n.fighting, n.engaged = true, false
        n.arrivedAt, n.reachAt = now, now
        n.displaceHoldUntil = now + W.TIMING.displace
        print(string.format('\ay[VF]\ax displaced (%s) -- fighting here, then re-anchoring.', why))
        W.log('displaced: ' .. tostring(why))
    end

    function W.summoned()
        W.displaced('summoned')
    end

    -- VF: pin is hot if something around you wants a fight. Not XTarget.
    local function rushSwarm()
        local pack = 0
        if runtime.countPackMobs then
            pack = tonumber(runtime.countPackMobs(W.RANGE.fight)) or 0
        end
        if pack > 0 then return true, pack end
        if runtime.closestThreat and runtime.closestThreat(W.RANGE.fight) then
            return true, 1
        end
        local swinging = false
        pcall(function()
            if mq.TLO.Me.Combat() then swinging = true end
        end)
        return swinging, pack
    end

    local function fearedNow()
        local on = false
        pcall(function()
            local fb = mq.TLO.Me.Feared
            if not fb then return end
            local id = fb.ID and fb.ID() or nil
            if id and id > 0 then on = true; return end
            local nm = fb()
            on = (nm ~= nil and nm ~= '' and nm ~= 'NULL' and nm ~= false)
        end)
        return on
    end

    -- VF: fear is not a teleport -- you run at normal speed, so the speed test
    -- VF: cannot see it.
    function W.watchTick()
        local n = runtime.nav
        local s = W.sample
        if not s then s = {}; W.sample = s end
        local now = os.clock()
        local x, y, z, zone, dead
        local ok = pcall(function()
            x, y, z = mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
            zone = mq.TLO.Zone.ID()
            dead = mq.TLO.Me.Dead()
        end)
        if not ok or not x or not y then return end

        -- VF: Zone change reseeds.
        if s.zone ~= zone or not s.at then
            s.zone, s.x, s.y, s.z, s.at, s.feared = zone, x, y, z, now, fearedNow()
            return
        end

        local feared = fearedNow()
        if s.feared and not feared then
            s.x, s.y, s.z, s.at, s.feared = x, y, z, now, false
            W.displaced('fear ended')
            return
        end
        s.feared = feared
        -- VF: Running blind under fear is not a stalled pin.
        if feared then
            n.watch.pin, n.watch.best, n.watch.at = nil, nil, nil
            s.x, s.y, s.z, s.at = x, y, z, now
            return
        end

        local dt = now - s.at
        if not dead and dt > 0.02 and dt <= W.DISPLACE.window then
            local dx, dy, dz = x - s.x, y - s.y, (z or 0) - (s.z or 0)
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if (d / dt) >= W.DISPLACE.speed then
                s.x, s.y, s.z, s.at = x, y, z, now
                W.displaced(string.format('moved %.0f in %.2fs', d, dt))
                return
            end
        end
        s.x, s.y, s.z, s.at = x, y, z, now
    end

    -- VF: Hunt pin cursor.

    -- VF: One prologue for huntTick / huntPin / (later) rush legs.
    function W.pinCursor()
        local kind, pack, locs = runtime.routeKind()
        if kind ~= 'loop' or type(locs) ~= 'table' or #locs < 1 then
            return nil, nil, nil, nil
        end
        local idx = runtime.pickRouteStart and runtime.pickRouteStart(locs) or (runtime.nav.pin or 1)
        if runtime.nav.travelSpent then
            local hops = 0
            while hops < #locs and runtime.locKind(locs[idx]) == 'travel' do
                idx = runtime.routeNextIdx and runtime.routeNextIdx(locs, idx) or (idx + 1)
                hops = hops + 1
            end
        end
        if idx < 1 or idx > #locs then idx = 1 end
        runtime.nav.pin = idx
        local wp = locs[idx]
        if not wp then return nil, nil, nil, nil end
        local ctrl = getCtrl()
        local range = tonumber(pack and (pack.scan or pack.wander or pack.range))
            or (ctrl.hunter_radius or 1500)
        return wp, idx, range, locs
    end

    -- VF: Mesh walk a pin through travel (continue-on-break). Returns idle|walking|arrived.
    function W.goPin(policy, arrive, opts)
        opts = opts or {}
        local wp = opts.wp
        if not wp then wp = select(1, W.pinCursor()) end
        if not wp then return 'idle' end
        arrive = tonumber(arrive) or W.RANGE.huntArrive
        -- VF: 3D. Flat arrival counted a pin one floor up as reached, so we stopped
        -- VF: under it and called it done. locDist3 collapses to flat when the pin
        -- VF: has no z, so old routes behave exactly as before.
        local d2 = runtime.locDist3 and runtime.locDist3(wp)
            or (runtime.locDist2 and runtime.locDist2(wp)) or 999
        if d2 <= arrive then
            stopMoving()
            local tr = runtime.travel
            if tr and tr.active and tr.active() then
                local r = tr.resume and tr.resume() or nil
                local t = tr.trip and tr.trip() or nil
                local ty = (t and t.y) or (r and r.y)
                local tx = (t and t.x) or (r and r.x)
                local pol = tr.policy and tr.policy() or (r and r.policy)
                if pol == policy and ty and tx
                    and math.abs(ty - (wp.y or 0)) < 5
                    and math.abs(tx - (wp.x or 0)) < 5 then
                    tr.clear()
                end
            end
            return 'arrived'
        end
        local tr = runtime.travel
        if tr and tr.ensure then
            tr.ensure(policy, wp.y, wp.x, wp.z, {
                arrive = arrive,
                onArrive = opts.onArrive,
            })
        else
            moveTowardLoc(wp.x, wp.y, wp.z, arrive)
        end
        return 'walking'
    end

    function W.huntTick()
        local wp = select(1, W.pinCursor())
        if not wp then return false end
        return W.goPin('defend', W.RANGE.huntArrive, { wp = wp }) == 'arrived'
    end

    function W.huntPin()
        local wp, idx, range = W.pinCursor()
        if not wp then return nil, nil, nil end
        return wp, idx, range
    end

    function W.idNearPin(id, wp, range)
        if not id or id <= 0 or not wp then return false end
        range = tonumber(range) or 1500
        -- VF: 3D -- flat radius pulled in mobs a floor above or below the pin.
        local f = runtime.spawnDist3ToLoc or runtime.spawnDist2ToLoc
        return f(id, wp) <= range
    end

    -- VF: Puller Rush.

    function W.rushing()
        local ctrl = getCtrl()
        return ctrl and ctrl.running and ctrl.mode == 'Rush'
            and not runtime.nav.fighting
    end

    -- VF: rushMode sketch — if within chain of a guide pin, repin(next). Not a huge lift.
    function W.rushRepinIfClose(locs, idx, wp, d2, d3)
        if not locs or not idx or not wp then return nil end
        if (runtime.locKind and runtime.locKind(wp) or '') ~= 'guide' then return nil end
        if runtime.nav.fighting or runtime.nav.reanchor then return nil end
        if (runtime.nav.displaceHoldUntil or 0) > os.clock() then return nil end
        d2 = tonumber(d2) or (runtime.locDist2 and runtime.locDist2(wp)) or 999
        d3 = tonumber(d3) or (runtime.locDist3 and runtime.locDist3(wp)) or d2
        local navActive = false
        pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
        -- VF: d3 only. d3 >= d2 always, so "d2 <= chain or d3 <= chain" was just the
        -- VF: flat test wearing a 3D coat, and it repinned off a guide we were only
        -- VF: under. Flat pins report d3 == d2, so nothing changes on old routes.
        if d3 <= W.RANGE.chain
            or ((not navActive) and d3 <= W.RANGE.guideLate) then
            return W.advance(locs, idx, string.format('guide #%d', idx))
        end
        return nil
    end

    function W.advance(locs, idx, why)
        local ni = runtime.routeNextIdx and runtime.routeNextIdx(locs, idx) or (idx + 1)
        if ni < 1 then ni = 1 end
        W.reset('pin')
        runtime.nav.clearedPin = idx
        runtime.nav.anchored = true
        runtime.nav.pin = ni
        print(string.format('\ag[VF]\ax Puller Rush -- %s. next loc %d/%d.', why or 'next', ni, #locs))
        if runtime.rushLog then runtime.rushLog(string.format('%s %d -> %d', why or 'next', idx, ni)) end
        local nwp = locs[ni]
        if nwp then
            -- VF: Replace /nav dest; do not stopMoving first (roll-through).
            pursuit.lastNavLoc = nil
            moveTowardLoc(nwp.x, nwp.y, nwp.z, W.RANGE.travelPark)
        end
        return 'travel'
    end

    -- VF: pin unreachable or no progress -- say which and skip it.
    function W.stalled(idx, wp, d2, kind)
        local w = runtime.nav.watch
        if w.pin ~= idx then
            w.pin, w.best, w.at = idx, d2, os.clock()
            return false
        end
        if d2 < (w.best or 1e12) - 2 then
            w.best, w.at = d2, os.clock()
            return false
        end
        if (os.clock() - (w.at or os.clock())) < W.TIMING.stall then return false end
        local why = (runtime.locPathLen and runtime.locPathLen(wp))
            and string.format('no progress, still %.0f away', d2)
            or 'no nav path to it'
        local msg = string.format(
            'Puller Rush cannot reach loc #%d (%s) at Y:%.1f X:%.1f Z:%.1f -- %s. Skipping it.',
            idx, kind, tonumber(wp.y) or 0, tonumber(wp.x) or 0, tonumber(wp.z) or 0, why)
        print('\ar[VF]\ax ' .. msg .. ' Move or delete that pin.')
        if runtime.rushLog then runtime.rushLog(msg) end
        return true
    end

    function W.rushTick()
        local ctrl = getCtrl()
        if not (ctrl and ctrl.running and ctrl.mode == 'Rush') then
            return 'idle'
        end
        local _, _, locs = runtime.routeKind()
        if type(locs) ~= 'table' or #locs < 1 then
            if not runtime.nav.warned then
                runtime.nav.warned = true
                print('\ay[VF]\ax Puller Rush needs a Combat loc. Gear → Combat Add, or /vf wp_loop.')
            end
            return 'idle'
        end
        runtime.nav.warned = false
        local idx = runtime.pickRouteStart and runtime.pickRouteStart(locs) or (runtime.nav.pin or 1)
        if idx < 1 or idx > #locs then idx = 1 end
        if runtime.nav.travelSpent then
            local hops = 0
            while hops < #locs and runtime.locKind(locs[idx]) == 'travel' do
                idx = runtime.routeNextIdx and runtime.routeNextIdx(locs, idx) or (idx + 1)
                hops = hops + 1
            end
        end
        runtime.nav.pin = idx
        local wp = locs[idx]
        if not wp then return 'idle' end

        local d2 = runtime.locDist2 and runtime.locDist2(wp) or 999
        local d3 = runtime.locDist3 and runtime.locDist3(wp) or d2
        -- VF: d3 only -- see rushRepinIfClose. The OR reduced to the flat test.
        local onPin = (d3 <= W.RANGE.arrive)
        local pinKind = runtime.locKind and runtime.locKind(wp) or 'loop'
        local swarm, hate = rushSwarm()
        local rushNote = string.format(
            '#%d %s d2=%.0f on=%s fight=%s hate=%s swarm=%s seen=%s hold=%s',
            idx, pinKind, d2, tostring(onPin), tostring(runtime.nav.fighting),
            tostring(hate), tostring(swarm), tostring(runtime.nav.engaged),
            tostring((runtime.nav.displaceHoldUntil or 0) > os.clock()))
        if runtime.rushLog and rushNote ~= runtime.nav.logLast then
            runtime.nav.logLast = rushNote
            runtime.rushLog(rushNote)
        end

        if pinKind == 'guide' then
            -- VF: Mid-summon / displace on a Guide must not wipe the fight latch and keep rushing.
            local holdFight = runtime.nav.fighting or runtime.nav.reanchor
                or ((runtime.nav.displaceHoldUntil or 0) > os.clock())
            if not holdFight then
                runtime.nav.fighting = false
                if runtime.markHuntLoc then runtime.markHuntLoc(wp) end
                local repinned = W.rushRepinIfClose(locs, idx, wp, d2, d3)
                if repinned then return repinned end
                if W.stalled(idx, wp, d2, pinKind) then
                    return W.advance(locs, idx, 'unreachable pin')
                end
                -- VF: holdFight already covers the latched cases; this covers aggro the
                -- VF: latch never saw (wanderer, train) without waiting for a summon.
                if not runtime.attackReleaseOk or runtime.attackReleaseOk() then
                    if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
                    pcall(function()
                        if mq.TLO.Target() and mq.TLO.Target.Type() == 'NPC' then mq.cmd('/target clear') end
                    end)
                end
                -- VF: Always aim at CURRENT guide until chain repin. Lookahead to next flip-flopped at ~20/40.
                moveTowardLoc(wp.x, wp.y, wp.z, 1)
                return 'travel'
            end
            -- VF: Fall through to the fight latch below (same as a Loop pin).
            if not runtime.nav.fighting then
                runtime.nav.fighting = true
                runtime.nav.arrivedAt = runtime.nav.arrivedAt or os.clock()
                runtime.nav.reachAt = os.clock()
            end
        end

        -- VF: Already fighting this pin: stay in the fight even if you chase 40 off the loc.
        if runtime.nav.fighting then
            if swarm then
                runtime.nav.engaged = true
                if runtime.markHuntLoc then runtime.markHuntLoc(wp) end
                local near = runtime.rushNear or W.RANGE.fight
                local reach = runtime.closestThreat and runtime.closestThreat(near)
                if reach or mq.TLO.Me.Combat() then
                    runtime.nav.reachAt = os.clock()
                elseif (os.clock() - (runtime.nav.reachAt or runtime.nav.arrivedAt or os.clock()))
                    >= W.TIMING.coldHate then
                    return W.advance(locs, idx, 'unreachable hate')
                end
                return 'fight'
            end
            -- VF: After summon/yank — hold here until proximity cold or hold expires (do not resume nav mid-summon).
            if runtime.nav.reanchor then
                if (runtime.nav.displaceHoldUntil or 0) > os.clock() then
                    return 'fight'
                end
                W.reset('pin')
                runtime.nav.anchored = false
                runtime.nav.clearedPin = 0
                runtime.nav.reanchor = false
                runtime.nav.displaceHoldUntil = nil
                print('\ag[VF]\ax clear -- re-anchoring the route from here.')
                W.log('displacement cleared -> re-anchor')
                return 'travel'
            end
            if runtime.nav.engaged then
                return W.advance(locs, idx, 'hate list clear')
            end
            -- VF: Loop pins wait for the train to catch up.
            local wait = (pinKind == 'travel') and 0 or W.TIMING.train
            if runtime.nav.arrivedAt and (os.clock() - runtime.nav.arrivedAt) >= wait then
                return W.advance(locs, idx, 'nothing on hate list')
            end
            return 'fight'
        end

        if not onPin then
            -- VF: Only watch when nothing is on us.
            if not swarm and W.stalled(idx, wp, d2, pinKind) then
                return W.advance(locs, idx, 'unreachable pin')
            end
            -- VF: the `swarm` test two lines up guards only the stall/advance decision --
            -- VF: this disengage ran every off-pin tick with a mob on us, which is the
            -- VF: failure the TriuneSummoned comment describes. Clearing the target is
            -- VF: inside the guard on purpose: losing the mob costs more than the toggle.
            if not runtime.attackReleaseOk or runtime.attackReleaseOk() then
                if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
                if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
                pcall(function()
                    if mq.TLO.Target() and mq.TLO.Target.Type() == 'NPC' then mq.cmd('/target clear') end
                end)
            end
            moveTowardLoc(wp.x, wp.y, wp.z, W.RANGE.travelPark)
            return 'travel'
        end

        if runtime.nav.clearedPin == idx and not swarm then
            return W.advance(locs, idx, 'already-cleared')
        end
        runtime.nav.fighting = true
        runtime.nav.arrivedAt = runtime.nav.arrivedAt or os.clock()
        runtime.nav.reachAt = os.clock()
        if swarm then runtime.nav.engaged = true end
        if runtime.markHuntLoc then runtime.markHuntLoc(wp) end
        print(string.format('\ag[VF]\ax Puller Rush arrived %s #%d -- clearing hate list (%s).',
            pinKind, idx, tostring(hate)))
        return 'fight'
    end

    -- VF: Route mana break.

    function W.manaHold()
        local ctrl = getCtrl()
        -- VF: one rest-mana owner. This read the per-zone route pack, which was a
        -- VF: fourth copy of the same threshold; see prefs.rest_mana_pct.
        local need = tonumber(ctrl and ctrl.rest_mana_pct) or 0
        local maxMana = 0
        pcall(function() maxMana = tonumber(mq.TLO.Me.MaxMana()) or 0 end)
        if need <= 0 or maxMana <= 0 then
            if runtime.routeManaSit then
                runtime.routeManaSit = false
                if not ctrl.medbreak_enabled then
                    runtime.medBreakActive = false
                    if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
                end
            end
            return false
        end
        local inFight = false
        if runtime.engineInCombat then
            inFight = not not runtime.engineInCombat()
        elseif runtime.inCombatState then
            inFight = not not runtime.inCombatState()
        else
            pcall(function() inFight = mq.TLO.Me.CombatState() == 'COMBAT' end)
        end
        if inFight then
            if runtime.routeManaSit then
                runtime.routeManaSit = false
                if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
            end
            return false
        end
        local myMana = 100
        pcall(function() myMana = tonumber(mq.TLO.Me.PctMana()) or 100 end)
        -- VF: Sit at the set %; stay down until full.
        if (not runtime.routeManaSit and myMana <= need) or (runtime.routeManaSit and myMana < 100) then
            if not runtime.routeManaSit then
                runtime.routeManaSit = true
                print(string.format('\ay[VF]\ax med at %d%% -- sitting until full.', need))
            end
            runtime.medBreakActive = true
            stopMoving()
            if not mq.TLO.Me.Sitting() and not mq.TLO.Me.Ducking()
                and not mq.TLO.Me.Combat() and not mq.TLO.Me.Moving() and not isMoveActive() then
                mq.cmd('/sit')
            end
            return true
        end
        if runtime.routeManaSit then
            runtime.routeManaSit = false
            runtime.medBreakActive = false
            if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
            print('\ag[VF]\ax mana full -- moving on.')
        end
        return false
    end

    -- VF: Map nav -- Shift+LMB travelIgnore, Shift+RMB travelDefend. Engine is ta/travel.lua.

    local function travel()
        return runtime.travel
    end

    function W.mapnavClear()
        if travel() then travel().clear() else runtime.playerNav = nil end
        runtime.travelResume = nil
    end

    function W.rushTripClear()
        W.mapnavClear()
        runtime.rushDest = nil
        runtime.rushCloseTicks = 0
    end

    function W.rushNavEnsure()
        local ctrl = getCtrl()
        local tr = travel()
        -- VF: fight-on-arrival trip uses rushDest; not a mode.
        if not ctrl or not runtime.rushDest or not tr then return end
        if tr.active() then return end
        local d = runtime.rushDest
        tr.beginIgnore(d.y, d.x, d.z, {
            arrive = tr.RANGE.rushArrive,
            onArrive = function()
                if ctrl.running and ctrl.mode ~= 'Manual' then
                    runtime.manualFightArmed = true
                    runtime.rushDest = nil
                    print('\ag[VF]\ax map travel arrived -- engaging.')
                end
            end,
        })
    end

    -- VF: policy = ignore|defend. Map Shift+LMB / Shift+RMB.
    function W.mapnavBegin(y, x, z, policy)
        local ctrl = getCtrl()
        local tr = travel()
        if not tr then return false end
        y, x, z = tonumber(y), tonumber(x), tonumber(z)
        if not y or not x then return false end
        if y == 0 and x == 0 then return false end
        policy = tostring(policy or 'ignore'):lower()
        if policy ~= 'defend' then policy = 'ignore' end

        if policy == 'defend' then
            runtime.rushDest = nil
            tr.beginDefend(y, x, z, { arrive = tr.RANGE.arrive })
            print(string.format('\ag[VF]\ax travelDefend -> Y:%.1f X:%.1f%s  (yield on hate; Escape cancels)',
                y, x, runtime.zLabel(z)))
            return true
        end

        runtime.rushDest = nil
        tr.beginIgnore(y, x, z, { arrive = tr.RANGE.arrive })
        print(string.format('\ag[VF]\ax travelIgnore -> Y:%.1f X:%.1f%s  (strip adds; Escape cancels)',
            y, x, runtime.zLabel(z)))
        return true
    end

    function W.mapnavIssue()
        local tr = travel()
        return tr and tr.issue() or false
    end

    -- VF: Ignore trips own the tick (strip, no fight). Defend yields — mode must scan/engage.
    -- VF: Group catch-up also yields the early-return so groupModeTick can repin the leader.
    function W.mapnavActive()
        local tr = travel()
        local pol = tr and tr.policy and tr.policy() or nil
        if pol == 'defend' then return false end
        local t = tr and tr.trip and tr.trip() or runtime.playerNav
        local r = tr and tr.resume and tr.resume() or nil
        if (t and t.groupCatchup) or (r and r.groupCatchup) then return false end
        if t and t.prep then return false end
        if r and not (t and t.prep) then
            if r.policy == 'defend' then return false end
            return true
        end
        return (tr and tr.active and tr.active() and pol == 'ignore') or (runtime.rushDest ~= nil)
    end

    function W.mapnavHold()
        local ctrl = getCtrl()
        local tr = travel()
        if not tr or not tr.active or not tr.active() then return false end
        local t = tr.trip and tr.trip() or nil

        -- VF: prep gate for fight-on-arrival trips that still set rushDest+prep.
        if runtime.rushDest and t and t.prep then
            if (os.clock() - (t.started or 0)) > 25 then
                print('\ay[VF]\ax map travel prep timed out -- running.')
                tr.issue()
            elseif runtime.rushPrepNeeded and runtime.rushPrepNeeded() then
                local navActive = false
                pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
                if navActive then pcall(function() mq.cmd('/nav stop') end) end
                return true
            else
                print(string.format('\ag[VF]\ax map travel -> Y:%.1f X:%.1f%s  (buffs/heals done)',
                    t.y, t.x, runtime.zLabel(t.z)))
                tr.issue()
            end
        end

        return tr.tick()
    end

    -- VF: World loc under the map cursor.
    function W.mapPointer()
        local y, x, z
        pcall(function()
            local ms = mq.TLO.MapSpawn
            if ms and ms() then
                y, x, z = ms.Y(), ms.X(), ms.Z()
            end
        end)
        if y and x then return y, x, z, 'spawn' end

        local found = {}
        local function consider(text)
            if not text or text == '' or text == 'NULL' then return end
            local a, b, c = tostring(text):match('([-%d%.]+)%s*,%s*([-%d%.]+)%s*,%s*([-%d%.]+)')
            if a then
                found[#found + 1] = { tonumber(a), tonumber(b), tonumber(c) }
                return
            end
            a, b = tostring(text):match('([-%d%.]+)%s*,%s*([-%d%.]+)')
            if a then
                found[#found + 1] = { tonumber(a), tonumber(b), nil }
            end
        end
        local function walk(node, depth)
            if not node or depth > 8 then return end
            local exists = false
            pcall(function() exists = not not node() end)
            if not exists then return end
            local t
            pcall(function() t = node.Text() end); consider(t)
            pcall(function() t = node.Tooltip() end); consider(t)
            local child
            pcall(function() child = node.FirstChild end)
            if child then walk(child, depth + 1) end
            local nxt
            pcall(function() nxt = node.Next end)
            if nxt then walk(nxt, depth + 1) end
        end
        pcall(function()
            local w = mq.TLO.Window('MapWindow')
            if w and w() then walk(w, 0) end
        end)
        for i = 1, #found do
            if found[i][1] and found[i][2] then
                return found[i][1], found[i][2], found[i][3], 'label'
            end
        end
        return nil
    end

    function W.mapNavLine(line, policy)
        line = tostring(line or '')
        policy = tostring(policy or 'ignore'):lower()
        if line:find('defend', 1, true) then policy = 'defend' end
        if line:find('ignore', 1, true) then policy = 'ignore' end
        if policy ~= 'defend' then policy = 'ignore' end
        line = line:gsub('%f[%w]ignore%f[%W]', ' '):gsub('%f[%w]defend%f[%W]', ' ')
        line = line:gsub('%f[%w]locxy%f[%W]', ' '):gsub('%f[%w]loc%f[%W]', ' ')
        if line == '' or line:find('%%', 1, true) then
            local y, x, z = W.mapPointer()
            if y then return W.mapnavBegin(y, x, z, policy) end
            print('\ay[VF]\ax map pointer has no world loc yet. Shift+LMB Ignore / Ctrl+Shift+LMB Defend.')
            return false
        end
        -- VF: mapclick must pass %x,%y as ONE token -- space-split drops Y in the Lua bind.
        local a, b, c = line:match('([-%d%.]+)%s*,%s*([-%d%.]+)%s*,%s*([-%d%.]+)')
        if not a then
            a, b = line:match('([-%d%.]+)%s*,%s*([-%d%.]+)')
        end
        if not a then
            a, b, c = line:match('([-%d%.]+)%s+([-%d%.]+)%s+([-%d%.]+)')
        end
        if not a then
            a, b = line:match('([-%d%.]+)%s+([-%d%.]+)')
        end
        if not a or not b then
            local y, x, z = W.mapPointer()
            if y then return W.mapnavBegin(y, x, z, policy) end
            print('\ay[VF]\ax map nav got no numbers: ' .. line)
            return false
        end
        -- VF: mapclick %x,%y are world X then Y -- begin wants Y,X.
        if not c then
            return W.mapnavBegin(b, a, nil, policy)
        end
        return W.mapnavBegin(a, b, c, policy)
    end

    -- VF: Shared by both map click polls: is the map open, and is this a fresh press?.
    local function mapOpen()
        local open = false
        pcall(function()
            local w = mq.TLO.Window('MapWindow')
            open = w and w.Open and w.Open()
        end)
        return open
    end

    local function keyDown(vKey)
        local down = false
        pcall(function()
            local ffi = require('ffi')
            if not runtime._escCdef then
                pcall(function() ffi.cdef('short GetAsyncKeyState(int vKey);') end)
                runtime._escCdef = true
            end
            down = ffi.C.GetAsyncKeyState(vKey) < 0
        end)
        return down
    end

    function W.pollNavClick()
        if not mapOpen() then
            runtime.mapNavWasDown = false
            return
        end
        -- VF: Shift+LMB only (no Alt/Ctrl/RMB) -> travelIgnore.
        local down = keyDown(0x10) and keyDown(0x01) and not keyDown(0x02)
            and not keyDown(0x11) and not keyDown(0x12)
        if not down then
            runtime.mapNavWasDown = false
            return
        end
        if runtime.mapNavWasDown then return end
        runtime.mapNavWasDown = true
        W.mapNavLine('', 'ignore')
    end

    function W.pollDefendClick()
        if not mapOpen() then
            runtime.mapDefendWasDown = false
            return
        end
        -- VF: Ctrl+Shift+LMB -> travelDefend (left mapclick path; RMB never gets empty-dirt coords).
        local down = keyDown(0x11) and keyDown(0x10) and keyDown(0x01) and not keyDown(0x02)
        if not down then
            runtime.mapDefendWasDown = false
            return
        end
        if runtime.mapDefendWasDown then return end
        runtime.mapDefendWasDown = true
        W.mapNavLine('', 'defend')
    end

    function W.pollPointClick()
        if not mapOpen() then
            runtime.mapPointWasDown = false
            return
        end
        -- VF: Ctrl+LMB without Shift -> Guide pin.
        local down = keyDown(0x11) and keyDown(0x01) and not keyDown(0x10)
        if not down then
            runtime.mapPointWasDown = false
            return
        end
        if runtime.mapPointWasDown then return end
        runtime.mapPointWasDown = true
        if runtime.addRouteLocFromMapLine then runtime.addRouteLocFromMapLine('') end
    end
    -- VF: Publish.

    runtime.walk = W

    runtime.navReset               = W.reset
    runtime.onSummoned             = W.summoned
    runtime.displaceTick           = W.watchTick
    runtime.resetRouteOnPlay       = W.resetOnPlay
    runtime.rushLog                = W.log
    runtime.wpTick                 = W.huntTick
    runtime.currentHuntWp          = W.huntPin
    runtime.huntIdNearWp           = W.idNearPin
    runtime.pullerRushing          = W.rushing
    runtime.pullerRushTick         = W.rushTick
    runtime.routeManaHold          = W.manaHold
    runtime.clearPlayerNav         = W.mapnavClear
    runtime.clearRushTrip          = W.rushTripClear
    runtime.ensureRushNav          = W.rushNavEnsure
    runtime.rushOnTheMove          = W.mapnavActive
    runtime.playerNavHold          = W.mapnavHold
    runtime.applyMapNavLine        = W.mapNavLine
    runtime.pollMapNavClick        = W.pollNavClick
    runtime.pollMapDefendClick     = W.pollDefendClick
    runtime.pollMapPointClick      = W.pollPointClick

    -- VF: Zero callers in ta.lua: only the moved block used these, so they are now internal.
    runtime.rushGoNext             = W.advance
    runtime.rushNavStuck           = W.stalled
    runtime.beginPlayerNav         = W.mapnavBegin
    runtime.issuePlayerNav         = W.mapnavIssue
    runtime.readMapPointerLoc      = W.mapPointer

    return W
end

return M
