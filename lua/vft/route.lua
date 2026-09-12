-- VF: zone route data and cursor. No movement commands. See docs/MOVE_REFACTOR.md.

local mq = require('mq')

local M = {}

function M.install(runtime, api)
    api = api or {}

    -- VF: ta.lua REASSIGNS ctrl and loadout wholesale in onCharacterChanged, so these have to stay getters.
    local getCtrl     = api.ctrl or function() return {} end
    local getLoadout  = api.loadout or function() return {} end
    local navLoaded   = api.navLoaded or function() return false end
    local saveLoadout = api.saveLoadout or function() end

    -- VF: Cost of the loc pickStart chose, just for its own print.
    local startCost = nil

    local R = {}

    function R.zone()
        local z = ''
        pcall(function() z = tostring(mq.TLO.Zone.ShortName() or '') end)
        if z == 'NULL' then z = '' end
        return z
    end

    -- VF: 'loop' (2+ locs), 'camp' (exactly 1) or 'none'.
    function R.current()
        local z = R.zone()
        local lo = getLoadout()
        local w = lo and lo.waypoints
        local pack = (type(w) == 'table' and type(w.zones) == 'table' and z ~= '') and w.zones[z] or nil
        if type(pack) ~= 'table' then return 'none', nil, nil end
        local locs = pack.locs
        if type(locs) ~= 'table' then return 'none', pack, nil end
        if #locs >= 2 then return 'loop', pack, locs end
        if #locs == 1 then return 'camp', pack, locs end
        return 'none', pack, locs
    end

    -- VF: Push the zone pack's saved radii / z-band / chase onto live ctrl.
    function R.apply()
        local kind, pack = R.current()
        local ctrl = getCtrl()
        if type(pack) == 'table' then
            local scan = tonumber(pack.scan or pack.wander or pack.range)
            if scan then
                ctrl.camp_radius = scan
                ctrl.hunter_radius = scan
            end
            if tonumber(pack.chase) then ctrl.xtar_nav_dist = tonumber(pack.chase) end
            local zBand = tonumber(pack.z or pack.maxz or pack.floor)
            if zBand then
                ctrl.hunter_z_plane = zBand
                ctrl.camp_z_plane = zBand
                ctrl.hunter_z = zBand
                ctrl.camp_z = zBand
            end
            if pack.closer ~= nil then ctrl.check_closer_mobs = pack.closer and true or false end
        end
        -- VF: routes never set ctrl.camp_loc. See docs/ANCHOR.md.
        if kind ~= 'loop' then runtime.nav.pin = 1 end
    end

    function R.kind(loc)
        local k = loc and tostring(loc.kind or loc.wp or ''):lower() or ''
        if k == 'travel' or k == 't' or k == 'path' then return 'travel' end
        if k == 'guide' or k == 'g' or k == 'via' then return 'guide' end
        return 'loop'
    end

    -- VF: Only Guide is a walk-through.
    function R.isVia(loc)
        return R.kind(loc) == 'guide'
    end

    function R.me()
        local mx, my, mz = 0, 0, 0
        pcall(function()
            mx = mq.TLO.Me.X() or 0
            my = mq.TLO.Me.Y() or 0
            mz = mq.TLO.Me.Z() or 0
        end)
        return mx, my, mz
    end

    function R.dist2(loc)
        if not loc then return 1e12 end
        local mx, my = R.me()
        local dx = mx - (loc.x or 0)
        local dy = my - (loc.y or 0)
        return math.sqrt(dx * dx + dy * dy)
    end

    -- VF: flat pin has no Z -- dist3 collapses to dist2.
    function R.distZ(loc)
        if not loc then return 1e12 end
        if loc.z == nil then return 0 end
        local _, _, mz = R.me()
        return math.abs(mz - (loc.z or 0))
    end

    function R.dist3(loc)
        if not loc then return 1e12 end
        local xy = R.dist2(loc)
        local dz = R.distZ(loc)
        return math.sqrt(xy * xy + dz * dz)
    end

    -- VF: How far you actually have to run.
    -- VF: no PathExists pre-gate -- it reports false for specs /nav walks fine.
    function R.rawLen(spec)
        local n = nil
        pcall(function()
            local v = tonumber(mq.TLO.Navigation.PathLength(spec)())
            if v and v > 0 then n = v end
        end)
        return n
    end

    function R.pathLen(loc)
        if not loc then return nil end
        if not navLoaded() then return nil end
        local y, x = tonumber(loc.y) or 0, tonumber(loc.x) or 0
        local z = tonumber(loc.z)
        local n = R.rawLen(runtime.navSpec(y, x, z))
        -- VF: 2D locyx measures as nothing, so re-measure a flat pin at our own Z.
        if n == nil and z == nil then
            n = R.rawLen(runtime.navSpec(y, x, runtime.zOr(nil)))
        end
        return n
    end

    -- VF: Nearest pin by nav path.
    function R.nearest(locs, wantKind)
        if type(locs) ~= 'table' or #locs < 1 then return 1 end
        local best, bestCost, any = 1, 1e12, false
        for i = 1, #locs do
            local loc = locs[i]
            if loc and ((not wantKind) or R.kind(loc) == wantKind) then
                local d3 = R.dist3(loc)
                if (not any) or d3 < bestCost then
                    local cost = R.pathLen(loc) or d3
                    if (not any) or cost < bestCost then
                        best, bestCost, any = i, cost, true
                    end
                end
            end
        end
        if wantKind and not any then
            return R.nearest(locs, nil)
        end
        startCost = any and bestCost or nil
        return best
    end

    -- VF: Loop or Guide kills the zone-in Travel pass.
    function R.markHunt(loc)
        local k = R.kind(loc)
        if k == 'loop' or k == 'guide' then
            runtime.nav.travelSpent = true
        end
    end

    function R.start(locs)
        if runtime.nav.anchored then return runtime.nav.pin end
        -- VF: Play: shortest nav path.
        local idx = R.nearest(locs, nil)
        runtime.nav.pin = idx
        runtime.nav.anchored = true
        R.markHunt(locs[idx])
        if type(locs) == 'table' and #locs >= 2 then
            print(string.format('\ag[VF]\ax start loc #%d (%s) -- %s away%s.',
                idx, R.kind(locs[idx]),
                startCost and string.format('%.0f', startCost) or '?',
                runtime.nav.travelSpent and ', travel off' or ''))
        end
        return idx
    end

    -- VF: Write this character's zone pack back out to the shared route file.
    function R.sync()
        local z = R.zone()
        if z == '' then return false end
        local lo = getLoadout()
        local pack = lo.waypoints and lo.waypoints.zones and lo.waypoints.zones[z]
        if type(pack) ~= 'table' then return false end
        if runtime.settings and runtime.settings.adoptLibId then
            pcall(runtime.settings.adoptLibId, z, pack)
        end
        if runtime.settings and runtime.settings.pullLiveRoutes then
            pcall(runtime.settings.pullLiveRoutes)
        end
        if runtime.settings and runtime.settings.syncNamedRoute then
            local ok = runtime.settings.syncNamedRoute()
            if ok then return true end
        end
        if not pack.lib_id or pack.lib_id == '' then
            print('\ay[VF]\ax loc is on this character. Pick a saved route so Ctrl+click writes the zone file.')
            return false
        end
        local ok, dest, name = false, nil, nil
        pcall(function()
            local IO = require('vft.mgr.io')
            local S = require('vft.mgr.schema')
            local lib = IO.loadRouteLib(z)
            local item = S.findRoute(lib, pack.lib_id)
            if not item then return end
            item.pack = S.copyRoutePack(pack)
            item.pack.lib_id = item.id
            name = item.name
            ok, dest = IO.saveRouteLib(lib, z)
        end)
        if ok then
            print(string.format('\ag[VF]\ax updated route %s -- %s.', tostring(name), tostring(dest)))
        end
        return ok
    end

    -- VF: Append a loc to this zone's route.
    function R.add(optX, optY, optZ, flat, kind)
        local z = R.zone()
        if z == '' then
            print('\ay[VF]\ax no zone -- cannot add a combat loc.')
            return false
        end
        local lo = getLoadout()
        lo.waypoints = lo.waypoints or { zones = {} }
        lo.waypoints.zones = lo.waypoints.zones or {}
        local pack = lo.waypoints.zones[z] or {
            range = 1500, wander = 1500, scan = 1500, chase = 150, mana = 0,
            floor = 25, maxz = 25, z = 25,
            closer = (getCtrl().check_closer_mobs ~= false),
            locs = {},
        }
        pack.locs = pack.locs or {}
        local loc
        optX, optY, optZ = tonumber(optX), tonumber(optY), tonumber(optZ)
        if optX and optY then
            if optZ == nil and not flat then
                pcall(function() optZ = mq.TLO.Me.Z() or 0 end)
                optZ = optZ or 0
            end
            loc = {
                x = math.floor(optX * 10) / 10,
                y = math.floor(optY * 10) / 10,
                kind = 'loop',
            }
            if optZ ~= nil then loc.z = math.floor(optZ * 10) / 10 end
        else
            pcall(function()
                local S = require('vft.mgr.schema')
                loc = S.captureLoc(mq)
            end)
        end
        if not loc then
            print('\ay[VF]\ax could not read a loc.')
            return false
        end
        if kind ~= nil then loc.kind = R.kind({ kind = kind }) end
        -- VF: flat drops height even when captureLoc stamped Me.Z.
        if flat then loc.z = nil end
        pack.locs[#pack.locs + 1] = loc
        lo.waypoints.zones[z] = pack
        R.apply()
        saveLoadout(true)
        R.sync()
        local n = #pack.locs
        if n == 1 and R.kind(loc) == 'loop' then
            print(string.format('\ag[VF]\ax %s loc 1 set -- camp (Y:%.1f X:%.1f%s).',
                z, loc.y, loc.x, runtime.zLabel(loc.z)))
        else
            print(string.format('\ag[VF]\ax %s loc %d added -- %s (Y:%.1f X:%.1f%s).',
                z, n, R.kind(loc), loc.y, loc.x, runtime.zLabel(loc.z)))
        end
        return true
    end

    -- VF: Ctrl+LMB on the map arrives here as a /vfmapnav line.
    -- VF: map clicks default to Guide -- a 2D click is a path point. The few
    -- VF: pins that should stop and fight get flipped to Loop in settings, or placed by /vf wp_loop.
    function R.addFromMapLine(line, kind)
        kind = kind or 'guide'
        line = tostring(line or '')
        line = line:gsub('%f[%w]locxy%f[%W]', ' '):gsub('%f[%w]loc%f[%W]', ' ')
        -- VF: mapclick %x,%y as one token -- space-split drops Y in the Lua bind.
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
        if (not a or not b) and runtime.readMapPointerLoc then
            local y, x, z = runtime.readMapPointerLoc()
            -- VF: A spawn under the pointer has a real Z; a bare map label does not.
            if y then return R.add(x, y, z, z == nil, kind) end
        end
        if not a or not b then
            print('\ay[VF]\ax map point got no numbers. Ctrl+LMB on the map.')
            return false
        end
        -- VF: %x,%y are world X then Y, and carry no height.
        if not c then
            return R.add(tonumber(a), tonumber(b), nil, true, kind)
        end
        return R.add(tonumber(b), tonumber(a), tonumber(c), false, kind)
    end

    -- VF: Advance the cursor, skipping Travel locs once the Travel pass is spent.
    function R.nextIdx(locs, idx)
        local n = type(locs) == 'table' and #locs or 0
        if n < 1 then return 1 end
        idx = tonumber(idx) or 1
        R.markHunt(locs[idx])
        local i = idx
        for _ = 1, n do
            i = i + 1
            if i > n then i = 1 end
            local k = R.kind(locs[i])
            if runtime.nav.travelSpent then
                if k ~= 'travel' then return i end
            else
                return i
            end
        end
        return idx
    end

    runtime.route = R

    -- VF: Back-compat aliases for ta.lua's existing call sites.
    runtime.zoneShort             = R.zone
    runtime.routeKind             = R.current
    runtime.applyZoneRoute        = R.apply
    runtime.locKind               = R.kind
    runtime.locIsVia              = R.isVia
    runtime.locMe                 = R.me
    runtime.locDist2              = R.dist2
    runtime.locDistZ              = R.distZ
    runtime.locDist3              = R.dist3
    runtime.locPathLen            = R.pathLen
    runtime.nearestRouteIdx       = R.nearest
    runtime.markHuntLoc           = R.markHunt
    runtime.pickRouteStart        = R.start
    runtime.syncNamedRoute        = R.sync
    runtime.addRouteLoc           = R.add
    runtime.addRouteLocFromMapLine = R.addFromMapLine
    runtime.routeNextIdx          = R.nextIdx

    return R
end

return M
