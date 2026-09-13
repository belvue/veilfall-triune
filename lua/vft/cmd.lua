-- VF: /vf /vfrun dispatcher. Bind at boot; discuss the command list here, not in vf.lua.

local mq = require('mq')
local D = require('vft.data')

local M = {}

local function normalizeCommandKey(text)
    return tostring(text or ''):lower():gsub('[^%w]', '')
end

function M.install(runtime, api)
    api = api or {}
    local getCtrl = api.getCtrl or function() return {} end
    local saveLoadout = api.saveLoadout or function() end
    local fullStop = api.fullStop or runtime.fullStop
    local setManualHunterPetHold = api.setManualHunterPetHold or function() end
    local clearCursor = api.clearCursor or runtime.clearCursor
    local addIgnore = api.addIgnore or runtime.addIgnore
    local removeIgnore = api.removeIgnore or runtime.removeIgnore
    local toggleEngine = api.toggleEngine or function() end
    local spawnMeleeMetrics = api.spawnMeleeMetrics
    local stickNeedsHitboxOverride = api.stickNeedsHitboxOverride
    local hitboxEdgeDist = api.hitboxEdgeDist

    local function setMode(arg1, arg2)
        if not arg1 or arg1 == '' then return false end
        local ctrl = getCtrl()
        local k1 = normalizeCommandKey(arg1)
        local k2 = arg2 and normalizeCommandKey(arg2) or ''

        local newMode
        if k1 == 'manual' or k1 == 'manualhunter' or k1 == 'pause' or k1 == 'maprush' then
            newMode = 'Manual'
        elseif k1 == 'rush' or k1 == 'run'
            or ((k1 == 'puller' or k1 == 'solo') and (k2 == 'rush' or k2 == 'run')) then
            newMode = 'Rush'
        elseif k1 == 'roam' or k1 == 'hunt' or k1 == 'hunter' or k1 == 'pethunter'
            or k1 == 'pettank' or k1 == 'grinder' or k1 == 'grind'
            or k1 == 'pull' or k1 == 'pullassist' or k1 == 'puller' or k1 == 'solo' then
            newMode = 'Roam'
        elseif k1 == 'group' or k1 == 'party' or k1 == 'box'
            or k1 == 'assist' or k1 == 'chase' or k1 == 'chaseassist'
            or k1 == 'garrison' or k1 == 'tank' or k1 == 'backline' or k1 == 'ranged' then
            newMode = 'Group'
        else
            return false
        end

        if ctrl.mode == 'Manual' and newMode ~= 'Manual' then
            setManualHunterPetHold(false, false)
        end
        if newMode == 'Rush' then
            runtime.navReset()
        end

        ctrl.mode = newMode
        ctrl.submode = ''

        print(string.format('\ag[VF]\ax mode set to %s.', ctrl.mode))
        saveLoadout(true)
        return true
    end

    local function toggle()
        toggleEngine()
    end

    local function command(...)
        local ctrl = getCtrl()
        local args = { ... }
        local cmd = ''
        if #args > 0 then
            cmd = normalizeCommandKey(args[1])
        end
        if cmd == '' then
            toggle()
            return
        end
        if cmd == 'run' then
            toggle()
            return
        end
        if cmd == 'start' then
            if ctrl.running then
                print('\ay[VF]\ax already running.')
            else
                ctrl.running = true
                runtime.wasRunning = true
                if runtime.resetRouteOnPlay then runtime.resetRouteOnPlay() end
                if runtime.groupOnPlay then runtime.groupOnPlay() end
                print('\ag[VF]\ax running.')
            end
        elseif cmd == 'pause' or cmd == 'stop' then
            if not ctrl.running then
                print('\ay[VF]\ax already paused.')
            else
                if ctrl.mode == 'Manual' then
                    setManualHunterPetHold(true, true)
                else
                    setManualHunterPetHold(false, true)
                end
                ctrl.running = false
                if fullStop then fullStop() end
                print('\ag[VF]\ax paused.')
            end
        elseif cmd == 'status' then
            print(string.format('\ag[VF]\ax mode: %s, burn: %s, boost: %s',
                ctrl.mode, ctrl.burn and 'ON' or 'OFF', ctrl.boost and 'ON' or 'OFF'))
        elseif cmd == 'aggro' then
            -- VF: reads which aggro signal fires, per mob. "on me" drives retargeting
            -- VF: and add detection, so when it looks wrong this is how you see why.
            if runtime.aggroReport then runtime.aggroReport() else print('\ar[VF]\ax aggroReport missing.') end
        elseif cmd == 'why' then
            -- VF: first ensureAttack gate that refused. docs/COMBAT_OWNERS.md.
            if runtime.whyFight then runtime.whyFight() else print('\ar[VF]\ax whyFight missing.') end
        elseif cmd == 'gdiag' or cmd == 'groupdiag' then
            -- VF: not '/vf group' -- that already sets Group mode. Prints which group
            -- VF: fields this server actually populates; docs/MULTIBOX.md §3 sizes the
            -- VF: DanNet decision on it, so measure before adding a transport.
            if runtime.groupReport then runtime.groupReport() else print('\ar[VF]\ax groupReport missing.') end
        elseif cmd == 'burn' or cmd == 'burnon' or cmd == 'burnoff' or cmd == 'burn1' or cmd == 'burn0' or cmd == 'burntoggle' then
            local sub = args[2] and string.lower(args[2]) or ''
            if sub == 'diag' or sub == 'status' then
                if runtime.burnDiag then runtime.burnDiag() else print('\ar[VF]\ax burndiag missing.') end
            elseif sub == 'on' or sub == '1' or cmd == 'burnon' or cmd == 'burn1' then
                ctrl.burn = true
                if runtime.resetBurnMultiline then runtime.resetBurnMultiline() end
                print('\ag[VF]\ax Burn mode ENABLED!')
            elseif sub == 'off' or sub == '0' or cmd == 'burnoff' or cmd == 'burn0' then
                ctrl.burn = false
                if runtime.resetBurnMultiline then runtime.resetBurnMultiline() end
                print('\ag[VF]\ax Burn mode DISABLED.')
            else
                ctrl.burn = not ctrl.burn
                if runtime.resetBurnMultiline then runtime.resetBurnMultiline() end
                print(string.format('\ag[VF]\ax Burn mode %s.', ctrl.burn and 'ENABLED!' or 'DISABLED.'))
            end
        elseif cmd == 'boost' or cmd == 'booston' or cmd == 'boostoff' or cmd == 'boosttoggle' then
            -- VF: Boost stub — session flag only until combat wiring lands.
            local sub = args[2] and string.lower(args[2]) or ''
            if sub == 'on' or sub == '1' or cmd == 'booston' then
                ctrl.boost = true
                print('\ag[VF]\ax Boost ON (stub).')
            elseif sub == 'off' or sub == '0' or cmd == 'boostoff' then
                ctrl.boost = false
                print('\ag[VF]\ax Boost OFF (stub).')
            else
                ctrl.boost = not ctrl.boost
                print(string.format('\ag[VF]\ax Boost %s (stub).', ctrl.boost and 'ON' or 'OFF'))
            end
        elseif cmd == 'burndiag' then
            if runtime.burnDiag then runtime.burnDiag() else print('\ar[VF]\ax burndiag missing.') end
        elseif cmd == 'discdiag' then
            if runtime.discDiag then runtime.discDiag() else print('\ar[VF]\ax discdiag missing.') end
        elseif cmd == 'debug' or cmd == 'debugmode' or cmd == 'diag' then
            ctrl.debug_mode = not ctrl.debug_mode
            print(string.format('\ag[VF]\ax Debug Mode: %s',
                ctrl.debug_mode and '\agENABLED\ax (\ao[VF:file - fn]\ax chat.debug + combat telemetry)' or '\arDISABLED\ax'))
        elseif cmd == 'songs' or cmd == 'songdiag' then
            -- VF: per-row Skill()/Beneficial() as the server reports them. Class is not a proxy here.
            if runtime.songReport then runtime.songReport() else print('\ar[VF]\ax songReport missing.') end
        elseif cmd == 'castdiag' then
            if runtime.castDiag then runtime.castDiag()
            else print('\ar[VF]\ax castdiag missing.') end
        elseif cmd == 'castdebug' then
            runtime.castDebug = not runtime.castDebug
            print(string.format('\ag[VF]\ax cast debug: %s',
                runtime.castDebug and '\agON\ax (helper tick spam)' or '\arOFF\ax'))
        elseif cmd == 'aabuy' or cmd == 'aaburn' then
            local idle, why = runtime.aaIdle()
            if not idle then
                print('\ay[VF]\ax AA burn would normally wait (' .. tostring(why) .. ') -- nudging anyway.')
            end
            runtime.aaSpendPrune()
            if not runtime.aaSpendNudge(true) then
                print('\ay[VF]\ax nothing to buy -- no banked points, or the queue is empty. \ay/vf aadiag\ax.')
            end
        elseif cmd == 'aadiag' or cmd == 'aa' then
            runtime.aaSpendStatus()
        elseif cmd == 'state' or cmd == 'combatstate' or cmd == 'enginestate' then
            if runtime.stateReport then
                runtime.stateReport()
            else
                print('\ar[VF]\ax vft/enginestate.lua did not load.')
            end
        elseif cmd == 'ticks' or cmd == 'profile' then
            if runtime.profToggle then
                runtime.profToggle()
            else
                print('\ar[VF]\ax ta/profile.lua did not load.')
            end
        elseif cmd == 'summon' then
            if runtime.onSummoned then
                runtime.onSummoned()
            else
                print('\ar[VF]\ax ta/walk.lua did not load -- no summon handler.')
            end
        elseif cmd == 'meleediag' or cmd == 'meleerails' then
            if runtime.meleeVerify then
                runtime.meleeVerify()
            else
                print('\ar[VF]\ax ta/melee.lua did not load -- MQ2Melee rails are not set.')
            end
        elseif cmd == 'hitboxdiag' or cmd == 'hitbox' then
            local tid = mq.TLO.Target.ID() or 0
            if tid <= 0 then
                print('\ay[VF]\ax hitboxdiag needs a target.')
            else
                local reach, height = spawnMeleeMetrics(tid)
                local need = stickNeedsHitboxOverride(tid)
                local edge = hitboxEdgeDist(tid)
                print(string.format(
                    '\ag[VF]\ax hitbox #%d: MaxRangeTo=%.1f Height=%.1f stick=%d%% fat=%s edge=%d',
                    tid, reach, height, runtime.stickCloseness(tid),
                    need and 'YES' or 'no', edge))
            end
        elseif cmd == 'dumpbuffs' or cmd == 'buffdump' or cmd == 'bar' then
            runtime.dumpSelfBarToFile('slash')
        elseif cmd == 'prunegates' or cmd == 'gatesprune' or cmd == 'prune' then
            if runtime.pruneSpellGates then
                runtime.pruneSpellGates()
            else
                print('\ar[VF]\ax pruneSpellGates missing.')
            end
        elseif cmd == 'prebuff' or cmd == 'buffcheck' or cmd == 'buffs' then
            ctrl.maintain_buffs = true
            local tick = api.buffTick or runtime.buffTick
            if tick and tick() then
                print('\ag[VF]\ax prebuff: casting a missing self buff.')
            else
                print('\ag[VF]\ax prebuff: no missing self buffs ready (stand still, not casting).')
            end
        elseif cmd == 'help' or cmd == 'h' or cmd == '?' then
            local p = '/vf'
            print('\ag[VF]\ax --- Slash Commands (' .. p .. ') ---')
            print('  \ay/ta is an EQ abbreviation for /target.\ax Use \ag' .. p .. '\ax if /ta does not reach TA.')
            print('  \ag' .. p .. ' run\ax - Toggle run/pause (same as /vfrun)')
            print('  \ag' .. p .. ' start\ax - Start (already running stays running)')
            print('  \ag' .. p .. ' prebuff | buffs\ax - Refresh missing self buffs without starting combat')
            print('  \ag' .. p .. ' pause | stop\ax - Pause (you walk, press attack)')
            print('  \ag' .. p .. ' burn [on|off|diag]\ax - Session burn; diag = why burn_only rows skip')
            print('  \ag' .. p .. ' boost [on|off]\ax - Session boost stub (no combat wiring yet)')
            print('  \ag' .. p .. ' prunegates\ax - Drop spell library rows not in your spellbook')
            print('  \ag' .. p .. ' debug\ax - Toggle live combat debug telemetry in chat')
            print('  \ag' .. p .. ' aadiag\ax - AA queue, banked points, and MQ2AASpend status')
            print('  \ag' .. p .. ' aabuy\ax - Buy one queued AA rank now, ignoring the out-of-combat gate')
            print('  \ag' .. p .. ' meleediag\ax - Read the MQ2Melee rails back out of the plugin')
            print('  \ag' .. p .. ' discdiag\ax - Why enabled discs skip (ActiveDisc / ready / burn)')
            print('  \ag' .. p .. ' castdiag\ax - Cast helper status')
            print('  \ag' .. p .. ' castdebug\ax - Toggle cast helper tick spam')
            print('  \ag' .. p .. ' summon\ax - Fire the summoned handler by hand, to test it')
            print('  \ag' .. p .. ' why\ax - First gate that refused /attack (docs/COMBAT_OWNERS.md)')
            print('  \ag' .. p .. ' aggro\ax - Which on-me signal fired for the current target')
            print('  \ag' .. p .. ' state\ax - engine mood (Me.CombatState), attack-on, threat, resolveState')
            print('  \ag' .. p .. ' ticks\ax - Toggle tick profiling; reports to config/ta_ticks.log')
            print('  \ag' .. p .. ' status\ax - Print running state and mode')
            print('  \ag' .. p .. ' settings | loadout | mgr\ax - Toggle Veilfall Manager (/vfmgr)')
            print('  \ag' .. p .. ' reloadloadout\ax - Re-read char loadout from disk (Manager Save does this)')
            print('  \ag' .. p .. ' help | h | ?\ax - Print slash command summary')
            print('  \ag' .. p .. ' spellbook | book\ax - Toggle spellbook browser')
            print('  \ag/vfinv\ax - Toggle inventory (/lua run vft/inv)')
            print('  \ag/vfvault\ax - /say #vault_merchant')
            print('  \ag' .. p .. ' inv | bags | inventory\ax - same as /vfinv')
            print('  \ag' .. p .. ' clearcursor | autoinv\ax - Clear items from cursor')
            print('  \ag' .. p .. ' style [melee|ranged|spell]\ax - Configure combat style')
            print('  \ag' .. p .. ' range [dist]\ax - Configure melee or ranged distance')
            print('  \ag' .. p .. ' buffbot | buff\ax - Toggle interactive buffbot window')
            print('  \ag' .. p .. ' zplane [5-100]\ax - Configure Hunter Tier 1 same-floor / Z plane height threshold')
            print('  \ag' .. p .. ' huntz [10-300]\ax - Configure Hunter Tier 2 max vertical height difference')
            print('  \ag' .. p .. ' pullcon [con]\ax - Configure faction consideration filter')
            print('  \ag' .. p .. ' ignore [list|del]\ax - Never-attack list (target name, or list/del)')
            print('  \ag' .. p .. ' <mode> [sub]\ax - Pause, solo [hunt|camp|rush], party [chase|camp|backline]')
            print('  \ag/vfrun\ax - Quick keybind command to toggle run/pause')
            print('  \ag/vfmgr\ax - Toggle Veilfall Manager (/lua run vft/mgr)')
            print('  \ag' .. p .. ' wp_loop | wp_guide | wp_travel\ax - Add current loc (kind) to this zone route')
            print('  \ag' .. p .. ' waypoints\ax - Toggle Waypoints mini-bar (/lua run vft/waypoints)')
            print('  \ag' .. p .. ' fight\ax - Toggle combat daemon (/lua run vft/fight); \ag/vfc\ax prints its state')
            print('  \agCtrl+LMB on map\ax - Add a Guide loc at the click (named route auto-saves)')
        elseif cmd == 'spellbook' or cmd == 'book' then
            local s = mq.TLO.Lua.Script('triune_spellbook')
            if s() and s.Status() == 'RUNNING' then
                mq.cmd('/lua stop triune_spellbook')
                print('\ag[VF]\ax stopping spellbook engine...')
            else
                mq.cmd('/lua run triune_spellbook')
                print('\ag[VF]\ax launching spellbook engine...')
            end
        elseif cmd == 'bags' or cmd == 'bag' or cmd == 'inventory' or cmd == 'allbags' or cmd == 'inv' then
            if runtime.toggleBags then runtime.toggleBags() end
        elseif cmd == 'vault' or cmd == 'vaultmerch' or cmd == 'merchant' then
            mq.cmd('/say #vault_merchant')
            print('\ag[VF]\ax /say #vault_merchant')
        elseif cmd == 'buff' or cmd == 'buffbot' or cmd == 'buffui' then
            local s = mq.TLO.Lua.Script('triune_buffbot')
            if s() and s.Status() == 'RUNNING' then
                mq.cmd('/lua stop triune_buffbot')
                print('\ag[VF]\ax stopping buffbot engine...')
            else
                mq.cmd('/lua run triune_buffbot')
                print('\ag[VF]\ax launching buffbot engine...')
            end
        elseif cmd == 't3' or cmd == 'settings' or cmd == 'loadout' or cmd == 'mgr' or cmd == 'manager' or cmd == 'vfmgr' then
            if runtime.toggleManager then runtime.toggleManager() end
        elseif cmd == 'reloadloadout' then
            if runtime.reloadLoadout then runtime.reloadLoadout(false) end
        elseif cmd == 'wploop' or cmd == 'wpguide' or cmd == 'wptravel' then
            -- VF: stand-here add. Typed as /vf wp_loop etc; normalizeCommandKey drops '_'.
            local kind = (cmd == 'wpguide' and 'guide') or (cmd == 'wptravel' and 'travel') or 'loop'
            local a2 = args[2] and string.lower(args[2]) or ''
            local flat = (a2 == 'flat' or a2 == 'noz' or a2 == 'ignorez')
            if runtime.addRouteLoc then
                runtime.addRouteLoc(nil, nil, nil, flat, kind)
            end
        elseif cmd == 'waypoints' or cmd == 'waypoint' or cmd == 'wps' then
            if runtime.toggleWaypoints then runtime.toggleWaypoints() end
        elseif cmd == 'fight' or cmd == 'daemon' or cmd == 'combat' then
            if runtime.toggleFight then runtime.toggleFight() end
        elseif cmd == 'clearcursor' or cmd == 'autoinv' or cmd == 'cursor' then
            if clearCursor then clearCursor() end
        elseif cmd == 'full' or cmd == 'compact' or cmd == 'mini' or cmd == 'hud' then
            print('\ay[VF]\ax HUD is mini only. /vf settings opens Manager.')
        elseif cmd == 'pullcon' or cmd == 'con' or cmd == 'confilter' then
            ctrl.pull_con_filter = ctrl.pull_con_filter or {}
            local arg2 = args[2] and string.lower(args[2]) or ''
            local arg3 = args[3] and string.lower(args[3]) or ''
            if arg2 == 'preset' then
                if arg3 == 'hostile' then
                    for _, c in ipairs(D.PULL_CON_LIST) do
                        ctrl.pull_con_filter[c] = (c == 'Scowling' or c == 'Threateningly' or c == 'Dubious' or c == 'Apprehensive')
                    end
                    print('\ag[VF]\ax Puller Faction Con filter set to preset: Hostile Only')
                elseif arg3 == 'indifferent' then
                    for _, c in ipairs(D.PULL_CON_LIST) do
                        ctrl.pull_con_filter[c] = (c == 'Scowling' or c == 'Threateningly' or c == 'Dubious' or c == 'Apprehensive' or c == 'Indifferent')
                    end
                    print('\ag[VF]\ax Puller Faction Con filter set to preset: Hostile + Indifferent')
                elseif arg3 == 'all' or arg3 == 'selectall' then
                    for _, c in ipairs(D.PULL_CON_LIST) do ctrl.pull_con_filter[c] = true end
                    print('\ag[VF]\ax Puller Faction Con filter set to preset: Select All')
                elseif arg3 == 'clear' or arg3 == 'none' then
                    for _, c in ipairs(D.PULL_CON_LIST) do ctrl.pull_con_filter[c] = false end
                    print('\ag[VF]\ax Puller Faction Con filter set to preset: Clear All')
                else
                    print('\ay[VF]\ax usage: /vf pullcon preset [all|hostile|indifferent|none]')
                end
                saveLoadout(true)
            elseif arg2 ~= '' then
                local targetCon = nil
                for _, c in ipairs(D.PULL_CON_LIST) do
                    if string.lower(c) == arg2 then
                        targetCon = c; break
                    end
                end
                if targetCon then
                    local enable = true
                    if arg3 == 'off' or arg3 == '0' or arg3 == 'false' then enable = false end
                    ctrl.pull_con_filter[targetCon] = enable
                    saveLoadout(true)
                    print(string.format('\ag[VF]\ax Puller Faction Con "%s" set to %s.', targetCon,
                        enable and 'ENABLED' or 'DISABLED'))
                else
                    print('\ay[VF]\ax unknown consideration tier: ' .. tostring(args[2]))
                end
            else
                print('\ag[VF]\ax --- Puller Faction Considerations ---')
                for _, c in ipairs(D.PULL_CON_LIST) do
                    print(string.format('  %s: %s', c, ctrl.pull_con_filter[c] and '\agENABLED\ax' or '\arDISABLED\ax'))
                end
                print(
                    '\ay[VF]\ax usage: /vf pullcon [con_name] [on|off] OR /vf pullcon preset [all|hostile|indifferent|none]')
            end
        elseif cmd == 'style' or cmd == 'combatstyle' then
            local st = args[2] and string.lower(args[2]) or ''
            if st == 'melee' then
                ctrl.combat_style = 'Melee'
                saveLoadout(true)
                print('\ag[VF]\ax Combat style set to: \agMelee\ax (range ' .. tostring(ctrl.melee_dist or 14) .. ')')
            elseif st == 'ranged' or st == 'bow' then
                ctrl.combat_style = 'Ranged'
                saveLoadout(true)
                print('\ag[VF]\ax Combat style set to: \agRanged (bow)\ax (range ' .. tostring(ctrl.ranged_dist or 40) .. ')')
            elseif st == 'spell' or st == 'cast' or st == 'caster' then
                -- VF: combatTick has no Spell branch -- setting it stopped us engaging
                -- VF: at all, silently. Casting is driven by the loadout, not by style.
                print('\ay[VF]\ax No Spell style. Pick melee or ranged; spells come from the loadout.')
            else
                print('\ay[VF]\ax usage: /vf style [melee|ranged]')
            end
        elseif cmd == 'range' or cmd == 'meleerange' or cmd == 'dist' then
            local val = tonumber(args[2])
            if val then
                if ctrl.combat_style == 'Melee' or cmd == 'meleerange' then
                    ctrl.melee_dist = math.max(5, math.min(50, math.floor(val)))
                    saveLoadout(true)
                    print(string.format('\ag[VF]\ax Max Melee Distance set to %d units.', ctrl.melee_dist))
                else
                    ctrl.ranged_dist = math.max(15, math.min(200, math.floor(val)))
                    saveLoadout(true)
                    print(string.format('\ag[VF]\ax Ranged Engagement Distance set to %d units.', ctrl.ranged_dist))
                end
            else
                if ctrl.combat_style == 'Melee' then
                    print(string.format('\ag[VF]\ax Current Max Melee Distance: %d units. (usage: /vf range [5-50])', ctrl.melee_dist or 14))
                else
                    print(string.format('\ag[VF]\ax Current Ranged Distance: %d units. (usage: /vf range [15-200])', ctrl.ranged_dist or 40))
                end
            end
        elseif cmd == 'mover' then
            -- VF: who is moving us right now. travel=MQ2Nav, combat=MoveUtils.
            if (args[2] or ''):lower() == 'log' then
                runtime.moverDebug = not runtime.moverDebug
                print('\ag[VF]\ax mover log ' .. (runtime.moverDebug and 'ON' or 'OFF') .. ' -> config/ta_rush.log')
            else
                local stickS, stickA, moveTo, navA = 'not loaded', false, false, false
                if runtime.stickLoaded() then
                    pcall(function() stickS = tostring(mq.TLO.Stick.Status()) end)
                    pcall(function() stickA = mq.TLO.Stick.Active() or false end)
                    pcall(function()
                        if mq.TLO.MoveTo and mq.TLO.MoveTo.Moving then moveTo = mq.TLO.MoveTo.Moving() or false end
                    end)
                end
                if runtime.navLoaded() then
                    pcall(function() navA = mq.TLO.Navigation.Active() or false end)
                end
                print(string.format('\ag[VF]\ax mover=\ay%s\ax (%.1fs ago)  nav.active=%s  stick=%s/active=%s  moveto=%s',
                    tostring(runtime.mover), os.clock() - (runtime.moverAt or 0),
                    tostring(navA), stickS, tostring(stickA), tostring(moveTo)))
                if runtime.navNoPathKey then
                    print('\ay[VF]\ax last off-mesh dest: ' .. tostring(runtime.navNoPathKey))
                end
                print('\a-w[VF] mover=travel + nav.active=false means no mesh path: VF is walking it natively.\ax')
            end
        elseif cmd == 'huntz' or cmd == 'z' then
            local val = tonumber(args[2])
            if val then
                ctrl.hunter_z = math.max(10, math.min(300, math.floor(val)))
                saveLoadout(true)
                print(string.format('\ag[VF]\ax Hunter Max Height Diff (Z) set to %d units.', ctrl.hunter_z))
            else
                print(string.format('\ag[VF]\ax Current Hunter Max Height Diff (Z): %d units. (usage: /vf huntz [10-300])', ctrl.hunter_z or 75))
            end
        elseif cmd == 'zplane' or cmd == 'huntplane' or cmd == 'floorz' then
            local val = tonumber(args[2])
            if val then
                ctrl.hunter_z_plane = math.max(5, math.min(100, math.floor(val)))
                saveLoadout(true)
                print(string.format('\ag[VF]\ax Hunter Floor Height (Z Plane) set to %d units.', ctrl.hunter_z_plane))
            else
                print(string.format('\ag[VF]\ax Current Hunter Floor Height (Z Plane): %d units. (usage: /vf zplane [5-100])', ctrl.hunter_z_plane or 15))
            end
        elseif cmd == 'ignore' or cmd == 'never' then
            local sub = tostring(args[2] or ''):lower()
            if sub == 'list' then
                local n = runtime.ignoreList and #runtime.ignoreList or 0
                if n == 0 then
                    print('\ay[VF]\ax ignore list empty. Target an NPC and /vf ignore')
                else
                    print(string.format('\ag[VF]\ax ignore list (%d):', n))
                    for _, name in ipairs(runtime.ignoreList) do
                        print('  ' .. tostring(name))
                    end
                end
            elseif sub == 'del' or sub == 'rm' or sub == 'remove' then
                local name = args[3]
                if not name or name == '' then
                    pcall(function() name = mq.TLO.Target.CleanName() end)
                end
                if name and name ~= '' then
                    removeIgnore(name)
                else
                    print('\ay[VF]\ax /vf ignore del <name> (or target them)')
                end
            else
                local name = args[2]
                if not name or name == '' then
                    pcall(function() name = mq.TLO.Target.CleanName() end)
                end
                if name and name ~= '' then
                    addIgnore(name)
                else
                    print('\ay[VF]\ax target an NPC, then /vf ignore')
                end
            end
        elseif setMode(args[1], args[2]) then
            -- VF: mode command handled.
        else
            print(
                '\ay[VF]\ax usage: /vf [run|pause|burn|settings|reloadloadout|status|spellbook|bags|buffbot|clearcursor|style|range|zplane|huntz|help|pullcon|wp_loop|wp_guide|wp_travel|waypoints|manual|rush|puller [hunt|camp|rush]|assist [chase|camp|backline]]')
        end
    end

    runtime.vfCommand = command
    runtime.vfToggle = toggle

    -- VF: /ta is retired -- EQ expands it to /target, so it never reliably reached us.
    pcall(function() mq.unbind('/ta') end)
    pcall(function() mq.unbind('/vf') end)
    if not pcall(function() mq.bind('/vf', command) end) then
        print('\ay[VF]\ax /vf is already taken by something else.')
    end
    pcall(function() mq.unbind('/t2') end)

    pcall(function() mq.unbind('/tarun') end)
    pcall(function() mq.unbind('/vfrun') end)
    mq.bind('/vfrun', toggle)
    pcall(function() mq.unbind('/t2run') end)
end

return M
