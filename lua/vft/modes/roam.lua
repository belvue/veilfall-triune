-- VF: Roam/Hunt acquire + pull-style close. combatTick only dispatches.
-- VF: Third return true = faction clear on acquire; combatTick must abort the pulse.

local mq = require('mq')
local D = require('vft.data')

local M = {}

function M.install(runtime, api)
    api = api or {}
    local getCtrl      = api.ctrl or function() return {} end
    local getLoadout   = api.loadout or function() return {} end
    local pursuit      = api.pursuit or runtime.pursuit or {}
    local stuckState   = api.stuckState or {}
    local petState     = api.petState or {}
    local distToId     = api.distToId or runtime.distToId
    local setTarget    = api.setTarget or runtime.setTarget
    local moveToward   = api.moveToward or runtime.moveToward
    local moveTowardLoc = api.moveTowardLoc or runtime.moveTowardLoc
    local stopMoving   = api.stopMoving or runtime.stopMoving
    local desiredRange = api.desiredRange or runtime.desiredRange
    local maxMeleeDistance = api.maxMeleeDistance or runtime.maxMeleeDistance
    local hasLoS       = api.hasLoS or runtime.hasLoS
    local isMoveActive = api.isMoveActive or runtime.isMoveActive
    local isIgnored    = api.isIgnored or runtime.isIgnored
    local isUnreachable = api.isUnreachable or runtime.isUnreachable
    local markUnreachable = api.markUnreachable or runtime.markUnreachable
    local wantsFight   = runtime.spawnWantsFight
    local closestThreat = runtime.closestThreat
    local findRoamTarget = api.findRoamTarget or runtime.findRoamTarget
    local checkCloserTarget = api.checkCloserTarget or runtime.checkCloserTarget
    local packCount    = runtime.countPackMobs
    local isHostileTarget = api.isHostileTarget or runtime.isHostileTarget
    local isSpawnAlive = api.isSpawnAlive or runtime.isSpawnAlive
    local hasActivePet = api.hasActivePet or runtime.hasActivePet
    local castGem      = api.castGem or runtime.castGem
    local isDetrimentalAction = api.isDetrimentalAction or runtime.isDetrimentalAction

    function runtime.roamModeTick(haveNPC)
        local ctrl = getCtrl()
        local loadout = getLoadout()
        local engage = false
        local maxHuntZ = ctrl.hunter_z or 75
        local myZ = mq.TLO.Me.Z() or 0
        if haveNPC then
            local tid = mq.TLO.Target.ID() or 0
            local tspawn = mq.TLO.Spawn(tid)
            local maxScan = ctrl.hunter_radius or 1500
            -- VF: Hysteresis so a spawn on the radius edge is not dropped the next tick.
            local dropDist = maxScan * 1.3 + 50
            if not tspawn() or tspawn.Dead() or tspawn.Type() == 'Corpse' then
                -- VF: leave the corpse targeted — chainSwing claims the next id without a clear flap.
                haveNPC = false
            elseif isIgnored(tspawn.CleanName()) then
                haveNPC = false
                mq.cmd('/target clear')
            elseif isUnreachable(tid) and not (runtime.spawnIsOnMe and runtime.spawnIsOnMe(tid)) then
                haveNPC = false
                mq.cmd('/target clear')
            elseif wantsFight and wantsFight(tid) then
                local maxXtarDist = (ctrl.xtar_nav_dist or 150)
                if distToId(tid) > (maxXtarDist + 20) and not mq.TLO.Me.Combat() then
                    -- VF: wantsFight beyond Chase + buffer and not swinging.
                    haveNPC = false
                    mq.cmd('/target clear')
                    stopMoving()
                end
            elseif runtime.routeKind() == 'loop' and not mq.TLO.Me.Combat()
                and not (runtime.spawnIsOnMe and runtime.spawnIsOnMe(tid)) then
                local wp, _, wpRange = runtime.currentHuntWp()
                if wp and not runtime.huntIdNearWp(tid, wp, wpRange) then
                    haveNPC = false
                    mq.cmd('/target clear')
                end
            elseif not (wantsFight and wantsFight(tid)) and not mq.TLO.Me.Combat() then
                local okZ, sz = pcall(function() return tspawn.Z() end)
                local tooFarZ = okZ and sz and math.abs(sz - myZ) > (maxHuntZ + 15)
                local tooFarDist = not isMoveActive() and distToId(tid) > dropDist
                if tooFarZ or tooFarDist then
                    -- VF: blacklist this spawn 60s so findRoamTarget cannot re-acquire next tick.
                    local reason = tooFarZ and 'elevation diff' or 'stationary+out-of-range'
                    print(string.format(
                        '\\ay[VF]\\ax Hunt: dropping #%d (%s) -- %s. Blacklisting for 60s.',
                        tid, tostring(tspawn.CleanName()), reason))
                    markUnreachable(tid)
                    haveNPC = false
                    mq.cmd('/target clear')
                end
            end
        end

        if not haveNPC then
            if runtime.chainSwing and runtime.chainSwing() then
                haveNPC = true
                engage = true
            elseif runtime.closestMobOnMe then
                local onMe = runtime.closestMobOnMe(80)
                if onMe and runtime.claimFightTarget and runtime.claimFightTarget(onMe) then
                    haveNPC = true
                    engage = true
                end
            end
        end

        local fightId = closestThreat and closestThreat(ctrl.xtar_nav_dist or 150)
        if fightId and runtime.routeKind() == 'loop' then
            local wp, _, wpRange = runtime.currentHuntWp()
            if wp and not runtime.huntIdNearWp(fightId, wp, wpRange)
                and not (runtime.spawnIsOnMe and runtime.spawnIsOnMe(fightId)) then
                fightId = nil
            end
        end
        if fightId then
            local curId = haveNPC and mq.TLO.Target.ID() or 0
            if curId ~= fightId and (curId == 0 or not (wantsFight and wantsFight(curId))) then
                stopMoving()
                pursuit.id = 0
                pursuit.lastNavTargetId = 0
                if setTarget(fightId) then
                    print(string.format('\ay[VF]\ax Roam fight nearby -- engaging #%d (%s) [dist %.1f, max chase %d]',
                        fightId, tostring(mq.TLO.Target.CleanName()), distToId(fightId), ctrl.xtar_nav_dist or 150))
                end
                haveNPC = true
            end
        end

        if haveNPC then
            if not (wantsFight and wantsFight(mq.TLO.Target.ID())) and not mq.TLO.Me.Combat() and (ctrl.check_closer_mobs == nil or ctrl.check_closer_mobs) then
                local curId = mq.TLO.Target.ID()
                local huntMin, huntMax = runtime.npcLevelBand()
                local closerId, candDist, curDist = checkCloserTarget(curId, nil, maxHuntZ, huntMin, huntMax)
                if closerId and setTarget(closerId) then
                    stopMoving()
                    pursuit.id = 0
                    pursuit.lastNavTargetId = 0
                    pursuit.hasRetargeted = true
                    print(string.format(
                        '\ay[VF]\ax Roam: Found closer NPC while traveling -- retargeting #%d (%s) [dist %.1f vs %.1f]',
                        closerId, tostring(mq.TLO.Target.CleanName()), candDist, curDist))
                end
            end
        else
            if stuckState.escapingUntil and os.clock() < stuckState.escapingUntil then
                local sx, sy, sz = stuckState.lastSafeX, stuckState.lastSafeY, stuckState.lastSafeZ
                if sx and sy and sz then
                    if moveTowardLoc(sx, sy, sz, 12) then
                        stuckState.escapingUntil = nil
                        runtime.recordSafeSpot()
                    end
                elseif not runtime.isInWater() then
                    stuckState.escapingUntil = nil
                end
            else
            local scanRadius = ctrl.hunter_radius or 1500
            local huntMin, huntMax = runtime.npcLevelBand()
            local routeWp, _, wpRange = runtime.currentHuntWp()
            if routeWp then
                local toWp = runtime.locDist2(routeWp)
                scanRadius = math.max(wpRange, toWp + wpRange)
            end
            local id = findRoamTarget(scanRadius, maxHuntZ, huntMin, huntMax)
            if id and routeWp and not runtime.huntIdNearWp(id, routeWp, wpRange) then
                id = nil
            end
            if id and setTarget(id) then
                if not runtime.verifyTargetCon(id, true) then
                    print(string.format(
                        '\ay[VF]\ax Roam: target #%d (%s) blocked by Faction Consideration filter -- clearing target.',
                        id, tostring(mq.TLO.Target.CleanName())))
                    mq.cmd('/target clear')
                    haveNPC = false
                    pursuit.id = 0
                    return haveNPC, engage, true
                end
                stopMoving()
                haveNPC = true
                pursuit.wanderLoc = nil
                pursuit.hasRetargeted = false
                stuckState.meshAttempts = 0
                runtime.meshPathFails = 0
                runtime.lastHunterMsgKey = nil
                print(string.format('\ay[VF]\ax Roam target acquired: #%d (%s) dist %.1f',
                    id, tostring(mq.TLO.Target.CleanName()), distToId(id)))
            elseif not (packCount and packCount(runtime.rushNear or 80) > 0) then
                    if pursuit.wanderLoc then
                        pursuit.wanderLoc = nil
                        if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
                        if mq.TLO.Stick.Active() then mq.cmd('/stick off') end
                    end

                    local radius = ctrl.hunter_radius or 1500
                    local minLv, maxLv = runtime.npcLevelBand()
                    local zDiff = ctrl.hunter_z or 75
                    local zPlane = ctrl.hunter_z_plane or 15
                    local anchorKey = ''
                    if ctrl.hunter_combat_loc and (ctrl.hunter_combat_radius or 0) > 0 then
                        anchorKey = string.format('; anchor R%d @ %.0f,%.0f,%.0f',
                            ctrl.hunter_combat_radius, ctrl.hunter_combat_loc.x, ctrl.hunter_combat_loc.y,
                            ctrl.hunter_combat_loc.z)
                    end
                    local currentKey = string.format('%d-%d-%d-%d-%d-%s', minLv, maxLv, radius, zDiff, zPlane, anchorKey)

                    if runtime.routeKind() == 'loop' then
                        if not (runtime.routeManaHold and runtime.routeManaHold()) then
                            if runtime.wpTick() then
                                local _, _, locs = runtime.routeKind()
                                local idx = runtime.nav.pin or 1
                                runtime.nav.pin = runtime.routeNextIdx(locs, idx)
                                print(string.format('\ag[VF]\ax Hunt -- next loc %d/%d.',
                                    runtime.nav.pin, locs and #locs or 0))
                            end
                        end
                    elseif runtime.lastHunterMsgKey ~= currentKey then
                        runtime.lastHunterMsgKey = currentKey
                        print(string.format(
                            '\ay[VF]\ax Roam: No NPCs found (Lvl %d-%d, Radius %d, Max Z %d, Floor Z %d%s). Waiting...',
                            minLv, maxLv, radius, zDiff, zPlane, anchorKey))
                    end
            end
            end
        end

        if haveNPC and not engage and not mq.TLO.Me.Combat() then
            local id = mq.TLO.Target.ID()
            if id and id > 0 and not (wantsFight and wantsFight(id)) and not runtime.verifyTargetCon(id) then
                print(string.format(
                    '\ay[VF]\ax Hunter: target #%d (%s) blocked by Faction Consideration filter -- clearing target.',
                    id, tostring(mq.TLO.Target.CleanName())))
                mq.cmd('/target clear')
                pursuit.id = 0
                stopMoving()
                haveNPC = false
            end
        end

        if haveNPC then
            local id = mq.TLO.Target.ID()
            -- VF: Facepull walks in and swings. Spell/Pet/Ranged tag at range.
            local pullStyle = ctrl.pull_style or 'Spell'
            local facepull = (pullStyle == 'Facepull')

            -- VF: Pet pull: dispatch pets while navigating (don't wait for arrival).
            if pullStyle == 'Pet' and (os.clock() - (runtime.lastPetPullAt or 0)) > 3.0 then
                runtime.lastPetPullAt = os.clock()
                petState.petHoldActive = false
                local petId = mq.TLO.Me.Pet.ID() or 0
                if petId > 0 and isSpawnAlive(petId) then mq.cmd('/pet attack') end
                if hasActivePet() then
                    mq.cmd('/say #petcmd attack all')
                end
            end

            -- VF: Facepull closes to melee. Other styles close to Tag from, then desiredRange once tagged.
            local reqRange
            if facepull or (wantsFight and wantsFight(id)) or mq.TLO.Me.Combat() then
                reqRange = desiredRange(id)
            else
                reqRange = ctrl.pull_engage_dist or 100
            end

            local onMe = runtime.spawnIsOnMe and runtime.spawnIsOnMe(id)
            -- VF: Facepull — LoS → AssistOn /stick this tick; no LoS → /nav. Do not nav a visible spawn.
            if facepull then
                local d = distToId(id)
                local maxEng = (runtime.maxEngageDistance and runtime.maxEngageDistance()) or (ctrl.xtar_nav_dist or 150)
                local losOk = onMe or (runtime.pickLosOk and runtime.pickLosOk(id, d))
                    or (hasLoS and hasLoS(id))
                if losOk and d <= maxEng then
                    engage = true
                    if runtime.assistOn then
                        runtime.assistOn(id)
                    end
                else
                    moveToward(id, reqRange)
                end
            else
            local arrived
            if onMe then
                stopMoving()
                arrived = true
            elseif (wantsFight and wantsFight(id)) or mq.TLO.Me.Combat() then
                -- VF: tagged melee close is AssistOn in combatTick, not /nav.
                if (ctrl.combat_style or 'Melee') == 'Ranged' then
                    arrived = moveToward(id, desiredRange(id))
                else
                    arrived = true
                end
            else
                arrived = moveToward(id, reqRange)
            end
            local tagRange = ctrl.pull_engage_dist or 100
            local inRange = arrived
                or (distToId(id) <= tagRange and (hasLoS(id) or onMe))

            if inRange then
                if pullStyle == 'Spell' then
                    -- VF: Spell pull: cast pull spell from engagement range.
                    mq.cmd('/face fast')
                    if (wantsFight and wantsFight(id)) or mq.TLO.Me.Combat() then
                        engage = true
                    else
                        local slotToCast = ctrl.pull_spell_gem or 1
                        local g = loadout.gems and loadout.gems[slotToCast]
                        local spellName = ctrl.pull_spell
                        if not spellName or spellName == '' then
                            pcall(function() spellName = mq.TLO.Me.Gem(slotToCast).Name() end)
                        end
                        if spellName and spellName ~= '' then
                            local dummyEntry = g or { spell = spellName, target = 'E: Current Target', cls = 'ALL' }
                            castGem(slotToCast, dummyEntry, id)
                        else
                            -- VF: Fallback: try first detrimental spell in loadout.
                            for i = 1, D.NUM_GEMS do
                                local lg = loadout.gems and loadout.gems[i]
                                local lpct = lg and tonumber(lg.pct)
                                if lpct == nil then lpct = 100 end
                                if lg and lg.spell and lg.spell ~= '' and lpct > 0 then
                                    local isDet = isDetrimentalAction(lg.spell, lg.target, lg)
                                    if isDet and castGem(i, lg, id) then break end
                                end
                            end
                        end
                        -- VF: Check if spell tagged the mob.
                        if wantsFight and wantsFight(id) then engage = true end
                    end
                elseif pullStyle == 'Pet' then
                    -- VF: Pet pull: pets already dispatched above during approach.
                    mq.cmd('/face fast')
                    if (wantsFight and wantsFight(id)) or distToId(id) <= 35 then
                        engage = true
                    else
                        local petTgtId = 0
                        pcall(function() petTgtId = mq.TLO.Pet.Target.ID() or 0 end)
                        if petTgtId > 0 and petTgtId == id then
                            engage = true
                        end
                    end
                elseif pullStyle == 'Ranged' then
                    -- VF: Ranged pull: try Throw Stone first, then bow/autofire, then melee fallback.
                    mq.cmd('/face fast')
                    if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
                    if (wantsFight and wantsFight(id)) or mq.TLO.Me.Combat() then
                        engage = true
                    else
                        local tsReady = false
                        pcall(function() tsReady = mq.TLO.Me.AbilityReady('Throw Stone')() end)
                        if tsReady then
                            mq.cmd('/doability "Throw Stone"')
                        else
                            -- VF: Fallback to ranged weapon (bow/autofire).
                            local hasRanged = false
                            pcall(function() hasRanged = mq.TLO.Me.Inventory('ranged')() ~= nil end)
                            if hasRanged then
                                if not mq.TLO.Me.AutoFire() then mq.cmd('/autofire on') end
                            else
                                -- VF: No ranged option available; fall back to melee.
                                if not mq.TLO.Me.Combat() then mq.cmd('/attack on') end
                            end
                        end
                        -- VF: Check if target was tagged.
                        if wantsFight and wantsFight(id) then engage = true end
                    end
                end
            elseif wantsFight and wantsFight(id) then
                if distToId(id) <= (ctrl.xtar_nav_dist or 150) and hasLoS(id) then
                    engage = true
                end
            end
            end
        end
        return haveNPC, engage
    end
end

return M
