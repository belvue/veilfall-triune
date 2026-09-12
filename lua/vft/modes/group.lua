-- VF: Group mode — follow the anchor; fight when MA/MT declare a mob.
-- VF: Anchor (follow) = ctrl.ma_name override, else Group.MainAssist / MainTank / Puller / Leader.
-- VF: Mob = Me.GroupAssistTarget (MA), else MainTank.Target, else follow-anchor.Target.

local mq = require('mq')

local M = {}

local ROLE_CHAIN = { 'MainAssist', 'MainTank', 'Puller', 'Leader' }
-- VF: Assist target order — MA via GroupAssistTarget TLO, then MT via their Target.
local ASSIST_ROLE_ORDER = { 'MainAssist', 'MainTank' }
-- VF: Ally CombatState COMBAT within this 3D range counts as group-in-combat for declare.
-- VF: Same SoT as runtime.engineFightHot (enginestate) — not XTarget, not AutoFire.
local GROUP_FIGHT_NEAR = 300
local FOLLOW_STUCK_SEC = 8

function M.install(runtime, api)
    api = api or {}
    local getCtrl       = api.ctrl or function() return {} end
    local distToId      = api.distToId or function() return 999 end
    local setTarget     = api.setTarget or function() return false end
    local moveToward    = api.moveToward or function() return false end
    local moveTowardLoc = api.moveTowardLoc or function() return false end
    local stopMoving    = api.stopMoving or function() end
    local desiredRange  = api.desiredRange or function() return 18 end
    local pctHP         = api.pctHP or function() return 100 end
    -- VF: no hasLoS here -- group movement goes through moveToward, which gates it.
    local isHostile     = api.isHostileTarget or function() return false end
    local isPetOrPc     = api.isSpawnPetOrPlayer or function() return false end
    local isGrpMember   = api.isGroupOrRaidMember or function() return false end
    local spawnAlive    = api.isSpawnAlive or function() return false end
    local claimMover    = api.claimMover or function() end

    local st = {
        active = false, followId = 0, sig = '', warned = false, lastMode = nil, rolesSig = nil,
        followDist = nil, followDistAt = 0, followStuck = false, xtarHinted = false,
        catchupTravel = false, travelWarned = false, anchorWarned = false,
    }

    -- VF: debug only, and self-capping -- same shape as walk.W.log. Callers do not
    -- VF: gate on moverDebug, and this logs per tick, so ungated it was an unbounded
    -- VF: append plus a file open/close in the group path. ta_rush.log hit 76MB the
    -- VF: same way. Gate here so no call site can forget.
    local logBytes = nil
    local function log(msg)
        if not runtime.moverDebug then return end
        local line = string.format('%.2f %s\n', os.clock(), tostring(msg))
        pcall(function()
            local p = (mq.configDir or '.') .. '/ta_group.log'
            if logBytes == nil then
                local probe = io.open(p, 'rb')
                if probe then
                    logBytes = probe:seek('end') or 0
                    probe:close()
                else
                    logBytes = 0
                end
            end
            -- VF: roll at 8MB, keep one generation. A trace, not a record.
            if logBytes > 8388608 then
                pcall(os.remove, p .. '.old')
                os.rename(p, p .. '.old')
                logBytes = 0
            end
            local f = io.open(p, 'a')
            if not f then return end
            f:write(line)
            f:close()
            logBytes = logBytes + #line
        end)
    end

    -- VF: Group Anchor — wait spot between pulls; defend camp without MA declare.
    local ANCHOR_PARK = 12
    local ANCHOR_RAD = 80

    function runtime.groupAnchorStamp()
        local ctrl = getCtrl()
        if not ctrl then return false end
        local x, y, z = 0, 0, 0
        pcall(function()
            x = mq.TLO.Me.X() or 0
            y = mq.TLO.Me.Y() or 0
            z = mq.TLO.Me.Z() or 0
        end)
        if x == 0 and y == 0 then return false end
        ctrl.group_anchor = true
        ctrl.group_anchor_loc = { x = x, y = y, z = z }
        print(string.format('\ag[VF]\ax Group Anchor stamped Y:%.1f X:%.1f Z:%.1f — wait here; fight camp invaders.',
            y, x, z))
        log(string.format('anchor stamp %.1f %.1f %.1f', y, x, z))
        return true
    end

    local function anchorLoc()
        local ctrl = getCtrl()
        local loc = ctrl and ctrl.group_anchor_loc
        if type(loc) ~= 'table' then return nil end
        if not loc.x or not loc.y then return nil end
        return loc
    end

    local function anchorRadius()
        local ctrl = getCtrl()
        return tonumber(ctrl and (ctrl.camp_radius or ctrl.group_anchor_radius)) or ANCHOR_RAD
    end

    local function distToAnchor()
        local loc = anchorLoc()
        if not loc then return 1e12 end
        local mx, my = 0, 0
        pcall(function()
            mx = mq.TLO.Me.X() or 0
            my = mq.TLO.Me.Y() or 0
        end)
        local dx = mx - (loc.x or 0)
        local dy = my - (loc.y or 0)
        return math.sqrt(dx * dx + dy * dy)
    end

    local function atAnchor()
        return distToAnchor() <= ANCHOR_PARK
    end

    function runtime.groupAnchorAllows(id)
        local ctrl = getCtrl()
        if not ctrl or not ctrl.group_anchor or not ctrl.running then return false end
        id = tonumber(id) or 0
        if id <= 0 then return false end
        if not isHostile(id) or isPetOrPc(id) or isGrpMember(id) then return false end
        if not spawnAlive(id) then return false end
        local rad = anchorRadius()
        if runtime.spawnIsOnMe and runtime.spawnIsOnMe(id) then return true end
        if distToId(id) <= rad then return true end
        local loc = anchorLoc()
        -- VF: 3D. The flat fallback ran after the 3D distToId test already failed,
        -- VF: so its only effect was to re-admit mobs a floor off the camp -- it
        -- VF: undid the check above it.
        local f = runtime.spawnDist3ToLoc or runtime.spawnDist2ToLoc
        if loc and f then
            return f(id, loc) <= rad
        end
        return false
    end

    local function campInvaderId()
        local ctrl = getCtrl()
        if not ctrl or not ctrl.group_anchor then return nil end
        local rad = anchorRadius()
        local onMe = runtime.closestMobOnMe and runtime.closestMobOnMe(rad)
        if onMe and runtime.groupAnchorAllows(onMe) then return onMe end
        local near = runtime.closestThreat and runtime.closestThreat(rad)
        if near and runtime.groupAnchorAllows(near) then return near end
        return nil
    end

    local function returnToAnchor()
        local loc = anchorLoc()
        if not loc then
            runtime.groupAnchorStamp()
            loc = anchorLoc()
        end
        if not loc then return end
        runtime.groupFollowStop()
        if atAnchor() then
            stopMoving()
            return
        end
        moveTowardLoc(loc.x, loc.y, loc.z, ANCHOR_PARK)
    end

    local function advLoaded()
        local on = false
        pcall(function()
            on = (mq.TLO.Plugin('mq2advpath')() or mq.TLO.Plugin('MQ2AdvPath')()) and true or false
        end)
        return on
    end

    local function advRequire()
        if advLoaded() then return true end
        mq.cmd('/plugin mq2advpath')
        return advLoaded()
    end

    local function spawnByName(name)
        if not name or name == '' then return nil end
        local id = nil
        pcall(function()
            local s = mq.TLO.Spawn('pc ' .. name)
            if s and s() and spawnAlive(s.ID()) then id = s.ID() end
        end)
        return id
    end

    -- VF: whoever holds this group role, US INCLUDED. Assist and the Tank / Main
    -- VF: Assist target tokens all want this one: being the MA yourself is a valid
    -- VF: answer, not an absence.
    local function roleHolderId(role)
        local id = nil
        pcall(function()
            local g = mq.TLO.Group
            if not g then return end
            local m = g[role]
            if not m or not m() then return end
            local mid = m.ID() or 0
            if mid > 0 and spawnAlive(mid) then id = mid end
        end)
        return id
    end

    -- VF: the ALLY holding this role. Excludes us on purpose -- you cannot follow
    -- VF: yourself, and that is the only thing this answers. For "who holds the role"
    -- VF: (where we are a legal answer) use roleHolderId. Keeping one function for
    -- VF: both questions is what broke assist on the leader: a character who is MA,
    -- VF: MT and Leader got nil from every role and the whole chain went dead.
    local function roleMemberId(role)
        local id = roleHolderId(role)
        if not id then return nil end
        local me = 0
        pcall(function() me = mq.TLO.Me.ID() or 0 end)
        if id == me then return nil end
        return id
    end

    local function roleLabel(id)
        if not id or id <= 0 then return '?' end
        for _, role in ipairs(ROLE_CHAIN) do
            local rid = roleMemberId(role)
            if rid == id then return role end
        end
        return 'named'
    end

    -- VF: the ALLY we follow / camp on. nil when we hold every role, which is correct
    -- VF: here and must not be treated as "no group" -- see runtime.groupRoleHolderId.
    function runtime.groupAnchorId(maName)
        local typed = spawnByName(maName)
        if typed then return typed end
        for _, role in ipairs(ROLE_CHAIN) do
            local id = roleMemberId(role)
            if id then return id end
        end
        return nil
    end

    -- VF: Published for maPcId / Tank / Main Assist tokens in every mode. Self-
    -- VF: inclusive, so the MA resolves to us when we are the MA. groupAnchorId used
    -- VF: to serve this and returned nil on the leader, which killed the Tank token,
    -- VF: maTargetId and groupAssistMobId at once.
    function runtime.groupRoleHolderId(maName)
        local typed = spawnByName(maName)
        if typed then return typed end
        for _, role in ipairs(ROLE_CHAIN) do
            local id = roleHolderId(role)
            if id then return id end
        end
        return nil
    end

    local function validMobId(id)
        if not id or id <= 0 then return nil end
        if isPetOrPc(id) or not isHostile(id) or not spawnAlive(id) then return nil end
        return id
    end

    -- VF: spawn has NO Target member -- only Targetable and TargetOfTarget (both
    -- VF: mirrors agree). This read `a.Target` and so always returned nil, which is
    -- VF: why the Main Tank assist branch never fired. TargetOfTarget at least
    -- VF: exists, and MQ2Melee / MQ2MoveUtils read that struct field as "who this
    -- VF: spawn is fighting" -- UNPROVEN for an arbitrary spawn here. `/vf gdiag`
    -- VF: theirTgt column settles it: if every member reports the same id it is
    -- VF: really "my target's target" and this stays dead. Last resort on purpose,
    -- VF: behind Me.GroupAssistTarget, and validMobId rejects anything not hostile.
    local function spawnTargetMobId(pcId)
        if not pcId or pcId <= 0 then return nil end
        local tid = nil
        pcall(function()
            local a = mq.TLO.Spawn(pcId)
            if not a or not a() then return end
            local t = a.TargetOfTarget
            if not t or not t() then return end
            tid = t.ID() or 0
        end)
        return validMobId(tid)
    end

    -- VF: MQ Character TLO — target of the Group Main Assist (no /assist).
    local function maAssistMobId()
        local id = nil
        pcall(function()
            local t = mq.TLO.Me.GroupAssistTarget
            if t and t() then id = t.ID() or 0 end
        end)
        return validMobId(id)
    end
    -- VF: published so maTargetId can skip its blocking /assist.
    runtime.maGroupAssistMobId = maAssistMobId

    -- VF: Assist order MainAssist → MainTank. MA uses GroupAssistTarget; MT has no twin TLO.
    -- VF: roleHolderId, not roleMemberId -- when WE are the MA, GroupAssistTarget is
    -- VF: still the right answer, and the ally-only lookup skipped straight past it.
    local function resolveAssistMobId(anchorId)
        for _, role in ipairs(ASSIST_ROLE_ORDER) do
            local pcId = roleHolderId(role)
            if pcId then
                local mob
                if role == 'MainAssist' then
                    mob = maAssistMobId()
                else
                    mob = spawnTargetMobId(pcId)
                end
                if mob then return mob end
            end
        end
        -- VF: typed ma_name / follow anchor when roles missing or idle.
        return spawnTargetMobId(anchorId)
    end

    local function xtarSetupHint()
        if st.xtarHinted then return end
        st.xtarHinted = true
        print('\ay[VF]\ax Group -- assist uses Me.GroupAssistTarget (MA), then Main Tank target. Set those group roles.')
    end

    local function memberEngineCombat(m)
        if not m or not m() then return false end
        local cs = ''
        pcall(function() cs = tostring(m.CombatState() or '') end)
        if cs == 'COMBAT' then return true end
        pcall(function()
            local id = tonumber(m.ID()) or 0
            if id <= 0 then return end
            local s = mq.TLO.Spawn(id)
            if s and s() then cs = tostring(s.CombatState() or '') end
        end)
        return cs == 'COMBAT'
    end

    -- VF: Me or any Present group member within maxDist with engine CombatState COMBAT.
    local function groupAnyoneFightingNear(maxDist)
        maxDist = tonumber(maxDist) or GROUP_FIGHT_NEAR
        if runtime.engineInCombat and runtime.engineInCombat() then
            return true, mq.TLO.Me.ID() or 0
        end
        local meCs = ''
        pcall(function() meCs = tostring(mq.TLO.Me.CombatState() or '') end)
        if meCs == 'COMBAT' then return true, mq.TLO.Me.ID() or 0 end

        local n = 0
        pcall(function() n = mq.TLO.Group.Members() or 0 end)
        for i = 1, n do
            local id, fighting, dist = 0, false, 9999
            pcall(function()
                local m = mq.TLO.Group.Member(i)
                if not m or not m() or not m.Present() then return end
                dist = m.Distance3D() or 9999
                if dist > maxDist then return end
                if memberEngineCombat(m) then
                    fighting = true
                    id = m.ID() or 0
                end
            end)
            if fighting and id > 0 then return true, id end
        end
        return false, nil
    end

    -- VF: Target of a nearby fighting ally (when MA assist TLO is still empty).
    local function mobFromNearbyFightingAlly(maxDist)
        maxDist = tonumber(maxDist) or GROUP_FIGHT_NEAR
        local n = 0
        pcall(function() n = mq.TLO.Group.Members() or 0 end)
        for i = 1, n do
            local mob = nil
            pcall(function()
                local m = mq.TLO.Group.Member(i)
                if not m or not m() or not m.Present() then return end
                local dist = m.Distance3D() or 9999
                if dist > maxDist then return end
                if not memberEngineCombat(m) then return end
                local t = m.Target
                if t and t() then mob = validMobId(t.ID() or 0) end
            end)
            if mob then return mob end
        end
        -- VF: Me in engine COMBAT with a hostile Target while Group is on.
        local mine = nil
        pcall(function()
            if tostring(mq.TLO.Me.CombatState() or '') ~= 'COMBAT' then return end
            local t = mq.TLO.Target
            if t and t() then mine = validMobId(t.ID() or 0) end
        end)
        return mine
    end

    local function mobDeclared(anchorId, mobId)
        if not mobId or mobId <= 0 then return false end
        if isPetOrPc(mobId) or not isHostile(mobId) then return false end
        local s = nil
        pcall(function() s = mq.TLO.Spawn(mobId) end)
        if not s or not s() or s.Dead() or s.Type() == 'Corpse' then return false end

        -- VF: Prefer MA then MT as the "who is fighting" signal.
        -- VF: roleHolderId -- us being the MA is a valid answer here too.
        for _, role in ipairs(ASSIST_ROLE_ORDER) do
            local pcId = roleHolderId(role)
            if pcId then
                local fighting = false
                pcall(function()
                    local a = mq.TLO.Spawn(pcId)
                    if a and a() and memberEngineCombat(a) then fighting = true end
                end)
                if fighting then return true end
            end
        end
        local fighting = false
        pcall(function()
            local a = mq.TLO.Spawn(anchorId)
            if a and a() and memberEngineCombat(a) then fighting = true end
        end)
        if fighting then return true end
        -- VF: Any group member (or Me) fighting within range — declare even if MA TLO lagged.
        if groupAnyoneFightingNear(GROUP_FIGHT_NEAR) then return true end
        if (s.PctHPs() or 100) < 100 then return true end
        local tot = 0
        pcall(function() tot = s.TargetOfTarget.ID() or 0 end)
        if tot > 0 and (tot == anchorId or tot == (mq.TLO.Me.ID() or 0) or isGrpMember(tot)) then
            return true
        end
        return false
    end

    function runtime.groupLeaderCombat()
        local ctrl = getCtrl()
        -- VF: role holder, not follow anchor. A character who is MA/MT/Leader has no
        -- VF: ally anchor, and bailing here returned nil from groupAssistMobId --
        -- VF: which targetIsEngaged reads as "nothing is engaged" in Group mode, so
        -- VF: the leader would not fight at all. Our own target is the assist target.
        local anchor = runtime.groupAnchorId(ctrl and ctrl.ma_name)
            or runtime.groupRoleHolderId(ctrl and ctrl.ma_name)
        if not anchor then return false, nil, nil end
        local mobId = resolveAssistMobId(anchor)
        if mobId and mobDeclared(anchor, mobId) then return true, anchor, mobId end
        -- VF: Ally already swinging nearby but assist target not published yet — use their Target.
        if groupAnyoneFightingNear(GROUP_FIGHT_NEAR) then
            local nearMob = mobId or mobFromNearbyFightingAlly(GROUP_FIGHT_NEAR)
            if nearMob and mobDeclared(anchor, nearMob) then
                return true, anchor, nearMob
            end
            if nearMob then return true, anchor, nearMob end
        end
        return false, anchor, mobId
    end

    function runtime.groupAssistMobId()
        local declared, _, mobId = runtime.groupLeaderCombat()
        return declared and mobId or nil
    end

    -- VF: Rush travel gate: XTarget alone is not combat in Group mode.
    function runtime.groupIsCombat()
        local ctrl = getCtrl()
        if not ctrl or ctrl.mode ~= 'Group' then return nil end
        local declared = runtime.groupLeaderCombat()
        if declared then return true end
        local tid = 0
        pcall(function() tid = mq.TLO.Target.ID() or 0 end)
        if tid > 0 and mq.TLO.Me.Combat() then
            local _, _, mobId = runtime.groupLeaderCombat()
            if mobId and tid == mobId then return true end
        end
        return false
    end

    -- VF: leave the player's click; only drop the swing when the group is not in a fight.
    local function travelStrip()
        -- VF: guard at the writer. The callers leaned on one upstream `declared` test,
        -- VF: which only counts OUR target being the group's mob -- an add we were
        -- VF: already swinging at read as "not in a fight" and got stripped.
        if runtime.attackReleaseOk and not runtime.attackReleaseOk() then return end
        if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
        if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
    end

    function runtime.groupFollowStop()
        if advLoaded() then
            pcall(function()
                if mq.TLO.AdvPath.Following() then mq.cmd('/afollow off') end
            end)
        end
        st.followId = 0
        st.sig = ''
        if runtime.mover == 'follow' then
            runtime.mover = nil
        end
    end

    -- VF: Zone-in clears movement; keep Group running and re-arm follow next tick.
    function runtime.groupOnZoned()
        runtime.groupFollowStop()
        st.pendingFollow = true
        log('zoned -- follow will re-arm')
        -- VF: Only persist Group if we already were Group. Stay must not steal Roam/Rush/Manual.
        local ctrl = getCtrl()
        if ctrl and ctrl.mode == 'Group' and ctrl.group_stay ~= false
            and runtime.groupTrustStayArmed and runtime.groupTrustStayArmed() then
            ctrl.submode = ''
            -- VF: do not force running -- pause survives zone.
        end
    end

    -- VF: Group leader only. EQ /grouproles: 1=MT 2=MA. Do not assign Puller (3).
    function runtime.groupEnsureLeaderRoles()
        local ctrl = getCtrl()
        if not ctrl or not ctrl.running then return false end
        local myId, myName = 0, ''
        pcall(function()
            myId = mq.TLO.Me.ID() or 0
            myName = mq.TLO.Me.CleanName() or ''
        end)
        if myId <= 0 or myName == '' then return false end
        local isLeader = false
        pcall(function()
            local g = mq.TLO.Group
            if not g or not g.Leader() then return end
            isLeader = (g.Leader.ID() or 0) == myId
        end)
        if not isLeader then return false end

        local sig = myName .. '|base'
        if st.rolesSig == sig then return true end

        local needMT, needMA = true, true
        pcall(function()
            local mt = mq.TLO.Group.MainTank
            if mt() and (mt.ID() or 0) == myId then needMT = false end
            local ma = mq.TLO.Group.MainAssist
            if ma() and (ma.ID() or 0) == myId then needMA = false end
        end)
        if not needMT and not needMA then
            st.rolesSig = sig
            return true
        end

        if needMT then mq.cmdf('/grouproles set %s 1', myName) end
        if needMA then mq.cmdf('/grouproles set %s 2', myName) end
        st.rolesSig = sig
        print(string.format('\ag[VF]\ax Group roles set on %s: Main Tank, Main Assist.', myName))
        log('roles ' .. myName)
        return true
    end

    function runtime.groupOnPlay()
        runtime.groupEnsureLeaderRoles()
    end

    local function followSig(anchorId, dist)
        return string.format('%d|%d', anchorId or 0, math.floor(tonumber(dist) or 25))
    end

    local function followTrack(anchorId)
        local d = distToId(anchorId)
        if not st.followDist or d < st.followDist - 3 then
            st.followDist = d
            st.followDistAt = os.clock()
            st.followStuck = false
        elseif (os.clock() - (st.followDistAt or 0)) > FOLLOW_STUCK_SEC then
            st.followStuck = true
        end
        return d
    end

    local function followNav(anchorId, dist)
        runtime.groupFollowStop()
        moveToward(anchorId, dist, true)
    end

    -- VF: Far from MA/MT — /nav target|id to spawn (not frozen loc).
    local GROUP_MESH_FAR = 100

    local function clearCatchupTravel()
        if not st.catchupTravel then return end
        st.catchupTravel = false
        st.travelWarned = false
        local tr = runtime.travel
        if tr and tr.resume and tr.resume() and tr.resume().groupCatchup then
            tr.clear()
        elseif tr and tr.trip and tr.trip() and tr.trip().groupCatchup then
            tr.clear()
        end
    end

    -- VF: travelIgnore tracking a spawn (/nav target|id). Loc-only was the slow/wrong Group path.
    local function travelIgnoreSpawn(id, arrive, keepTarget)
        id = tonumber(id) or 0
        if id <= 0 then return false end
        local tr = runtime.travel
        if not tr or not tr.ensureSpawn then return false end
        st.catchupTravel = true
        return tr.ensureSpawn('ignore', id, {
            arrive = tonumber(arrive) or 20,
            groupCatchup = true,
            keepTarget = keepTarget and true or false,
        }) and true or false
    end

    local function followCatchupTravel(anchorId, arrive)
        runtime.groupFollowStop()
        local tr = runtime.travel
        if not tr or not tr.ensureSpawn then
            followNav(anchorId, arrive)
            return
        end
        -- VF: Select leader so /nav target tracks them (works better than frozen loc / bare id).
        if mq.TLO.Target.ID() ~= anchorId then
            pcall(function() mq.cmdf('/target id %d', anchorId) end)
        end
        travelIgnoreSpawn(anchorId, arrive, true)
        if not st.travelWarned then
            st.travelWarned = true
            print('\ay[VF]\ax Group -- far from anchor; /nav target catch-up (spawn track).')
            log(string.format('catchup nav target %d', anchorId))
        end
    end

    -- VF: Assist mob past Chase — /nav id|target, not moveToward not-closing spam.
    local function assistCatchupTravel(mobId, arrive)
        runtime.groupFollowStop()
        local tr = runtime.travel
        if not tr or not tr.ensureSpawn then
            moveToward(mobId, arrive, true)
            return
        end
        if mq.TLO.Target.ID() ~= mobId then setTarget(mobId) end
        travelIgnoreSpawn(mobId, arrive, true)
        if not st.travelWarned then
            st.travelWarned = true
            print('\ay[VF]\ax Group -- assist past Chase; /nav target to mob.')
            log(string.format('assist nav target %d', mobId))
        end
    end

    local function followStart(anchorId, dist)
        if not anchorId or anchorId <= 0 then return false end
        if not advRequire() then
            if not st.advWarned then
                st.advWarned = true
                print('\ay[VF]\ax Group mode needs MQ2AdvPath (/afollow). Load the plugin and reload VF.')
            end
            return false
        end
        local sig = followSig(anchorId, dist)
        local monitoring = 0
        pcall(function() monitoring = mq.TLO.AdvPath.Monitor() or 0 end)
        if st.sig == sig and mq.TLO.AdvPath.Following() and monitoring == anchorId then
            return true
        end
        runtime.groupFollowStop()
        mq.cmdf('/afollow spawn %d', anchorId)
        claimMover('follow')
        st.followId = anchorId
        st.sig = sig
        log(string.format('follow spawn %d dist %s', anchorId, tostring(dist)))
        return true
    end

    local function modeExit()
        if not st.active then return end
        clearCatchupTravel()
        runtime.groupFollowStop()
        st.active = false
        st.sig = ''
        st.warned = false
        st.followDist = nil
        st.followStuck = false
        st.navWarned = false
        st.xtarHinted = false
        log('exit Group')
    end

    local function modeEnter()
        if st.active then return end
        st.active = true
        st.sig = ''
        st.warned = false
        local ctrl = getCtrl()
        local anchor = runtime.groupAnchorId(ctrl and ctrl.ma_name)
        if anchor then
            print(string.format('\ag[VF]\ax Group -- following %s (%s). Ignore adds; fight their target only.',
                tostring(mq.TLO.Spawn(anchor).CleanName() or '?'), roleLabel(anchor)))
            xtarSetupHint()
        else
            print('\ay[VF]\ax Group -- set Main Assist or Main Tank in the group window, or type an MA name in settings.')
        end
        log('enter Group')
    end

    function runtime.groupModeSync()
        local ctrl = getCtrl()
        local mode = ctrl and ctrl.mode or ''
        if st.lastMode == 'Group' and mode ~= 'Group' then modeExit() end
        if mode == 'Group' and st.lastMode ~= 'Group' then modeEnter() end
        st.lastMode = mode
    end

    function runtime.groupModeTick()
        runtime.groupModeSync()
        local ctrl = getCtrl()
        if not ctrl or ctrl.mode ~= 'Group' then return false, false end

        local anchor = runtime.groupAnchorId(ctrl.ma_name)
        if not anchor then
            if not st.warned then
                st.warned = true
                print('\ay[VF]\ax Group -- no anchor. Set a group role (Main Assist / Main Tank) or MA name in settings.')
            end
            runtime.groupFollowStop()
            return false, false
        end
        st.warned = false

        -- VF: Anchor — camp wait + defend invaders; do not chase the group across the zone.
        if ctrl.group_anchor then
            if not anchorLoc() then runtime.groupAnchorStamp() end
            if not st.anchorWarned then
                st.anchorWarned = true
                print('\ag[VF]\ax Group Anchor on — waiting at camp; fighting invaders without MA declare.')
            end
            local invader = campInvaderId()
            if invader then
                clearCatchupTravel()
                runtime.groupFollowStop()
                if mq.TLO.Target.ID() ~= invader then setTarget(invader) end
                local assistAt = tonumber(ctrl.assist_at) or 100
                -- VF: combatTick AssistOn owns melee close.
                if pctHP(invader) <= assistAt then
                    return true, true
                end
                return true, false
            end
            local declared, _, mobId = runtime.groupLeaderCombat()
            if declared and mobId and runtime.groupAnchorAllows(mobId) then
                clearCatchupTravel()
                runtime.groupFollowStop()
                local chase = tonumber(ctrl.xtar_nav_dist) or 150
                local mobDist = distToId(mobId)
                if mobDist > chase then
                    -- VF: Far declare while Anchored — stay home; MA will bring it or you already fought invaders.
                    travelStrip()
                    clearCatchupTravel()
                    returnToAnchor()
                    return false, false
                end
                if mq.TLO.Target.ID() ~= mobId then setTarget(mobId) end
                local assistAt = tonumber(ctrl.assist_at) or 100
                local hpOk = pctHP(mobId) <= assistAt
                -- VF: combatTick AssistOn owns melee close.
                if hpOk then
                    return true, true
                end
                return true, false
            end
            travelStrip()
            clearCatchupTravel()
            returnToAnchor()
            return false, false
        end
        st.anchorWarned = false

        local followDist = tonumber(ctrl.chase_dist) or 25
        local meshFar = math.max(GROUP_MESH_FAR, followDist * 3)
        local anchorDist = distToId(anchor)

        -- VF: Far from leader — always /nav the PC. Do not steal target onto their far assist mob.
        if anchorDist > meshFar or (st.followStuck and anchorDist > followDist) then
            followTrack(anchor)
            followCatchupTravel(anchor, followDist)
            st.pendingFollow = false
            return false, false
        end

        local declared, _, mobId = runtime.groupLeaderCombat()
        if declared and mobId then
            runtime.groupFollowStop()
            local chase = tonumber(ctrl.xtar_nav_dist) or 150
            local mobDist = distToId(mobId)
            -- VF: Past Chase, moveToward refuses and spams; mesh there immediately.
            if mobDist > chase then
                if mq.TLO.Target.ID() ~= mobId then setTarget(mobId) end
                assistCatchupTravel(mobId, desiredRange(mobId))
                return true, false
            end
            clearCatchupTravel()
            if mq.TLO.Target.ID() ~= mobId then setTarget(mobId) end
            local assistAt = tonumber(ctrl.assist_at) or 100
            local hpOk = pctHP(mobId) <= assistAt
            -- VF: combatTick AssistOn owns melee close.
            if hpOk then
                return true, true
            end
            return true, false
        end

        travelStrip()
        local needFollow = st.pendingFollow or anchorDist > followDist
        st.pendingFollow = false
        if needFollow then
            followTrack(anchor)
            clearCatchupTravel()
            st.navWarned = false
            followStart(anchor, followDist)
        else
            clearCatchupTravel()
            st.followDist = nil
            st.followStuck = false
            st.navWarned = false
            if advLoaded() and mq.TLO.AdvPath.Following() then
                runtime.groupFollowStop()
            end
        end
        return false, false
    end

    runtime.groupModeReset = function()
        modeExit()
        st.lastMode = nil
        st.rolesSig = nil
    end

    local function nameApproved(name)
        local ctrl = getCtrl()
        if not ctrl then return false end
        name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if name == '' then return false end
        local key = name:lower()
        local list = ctrl.group_approved
        if type(list) ~= 'table' then return false end
        for _, n in ipairs(list) do
            if tostring(n):lower() == key then return true end
        end
        return false
    end

    local function groupedWithApproved()
        local ctrl = getCtrl()
        if not ctrl or ctrl.group_stay == false then return false end
        local list = ctrl.group_approved
        if type(list) ~= 'table' or #list == 0 then return false end
        local members = 0
        pcall(function() members = mq.TLO.Group.Members() or 0 end)
        if members < 1 then return false end
        for i = 1, members do
            local nm = ''
            pcall(function()
                local m = mq.TLO.Group.Member(i)
                if m and m() then nm = m.Name() or m.CleanName() or '' end
            end)
            if nameApproved(nm) then return true end
        end
        return false
    end

    function runtime.groupTrustStayArmed()
        return groupedWithApproved()
    end

    local function armGroupMode(why, startRun)
        local ctrl = getCtrl()
        if not ctrl then return end
        local changed = (ctrl.mode ~= 'Group')
        ctrl.mode = 'Group'
        ctrl.submode = ''
        -- VF: startRun only on invite accept. Stay/zone never un-pauses the player.
        if startRun and not ctrl.running then
            changed = true
            ctrl.running = true
            runtime.wasRunning = true
            if runtime.resetRouteOnPlay then runtime.resetRouteOnPlay() end
            if runtime.groupOnPlay then runtime.groupOnPlay() end
        end
        if changed then
            print(string.format('\ag[VF]\ax Group -- %s', why or 'armed'))
            log('trust arm ' .. tostring(why))
        end
    end

    local function acceptInviteFrom(name)
        name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if name == '' or not nameApproved(name) then return false end
        local ctrl = getCtrl()
        if ctrl and ctrl.group_auto_accept == false then return false end
        local now = os.clock()
        if (now - (st.lastAcceptAt or 0)) < 2.0 then return false end
        st.lastAcceptAt = now
        -- VF: pending invite -- /invite accepts; dialog Yes as fallback.
        pcall(function() mq.cmd('/invite') end)
        pcall(function()
            if mq.TLO.Window('ConfirmationDialogBox').Open() then
                mq.cmd('/notify ConfirmationDialogBox Yes_Button leftmouseup')
            end
        end)
        armGroupMode('accepted invite from ' .. name, true)
        st.pendingInviter = nil
        log('accept ' .. name)
        return true
    end

    pcall(function()
        mq.unevent('VFGroupInvite')
    end)
    mq.event('VFGroupInvite', '#1# invites you to join a group.', function(_, name)
        st.pendingInviter = name
        log('invite event ' .. tostring(name))
    end)

    -- VF: Runs every combatTick (any mode) -- whitelist accept + stay mode (respect pause).
    function runtime.groupTrustTick()
        local ctrl = getCtrl()
        if not ctrl then return end
        if type(ctrl.group_approved) ~= 'table' or #ctrl.group_approved == 0 then
            return
        end

        local invited, inviter = false, ''
        pcall(function()
            invited = not not mq.TLO.Me.Invited()
            inviter = tostring(mq.TLO.Me.Inviter() or '')
        end)
        if st.pendingInviter and st.pendingInviter ~= '' then
            inviter = st.pendingInviter
            invited = true
        end
        if invited and inviter ~= '' then
            acceptInviteFrom(inviter)
        end

        -- VF: Pause = player owns move/target; never re-force Play from stay.
        if ctrl.mode == 'Group' and not ctrl.running then
            runtime.groupFollowStop()
            return
        end

        -- VF: Stay is zone-persist only (onZoned). Do not snap mode back every tick —
        -- VF: that locked toons with an approved partner out of Manual/Roam/Rush.
    end
end

return M
