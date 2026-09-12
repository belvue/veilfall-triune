---@diagnostic disable: undefined-global, undefined-field
-- VF: engine entry. /lua run vf. Boot checks live in vft/boot.lua.

local mq                = require('mq')
local ImGui             = require('ImGui')
local scriptDir         = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or "./"
package.path            = scriptDir .. "?.lua;" .. package.path
local D                 = require('vft.data')
local U                 = require('vft.util')
local Boot              = require('vft.boot')
local Song              = require('vft.song')

local VERSION           = '0.6.12'
local ENGINE            = 'VF'
local open              = true
local cfg               = mq.configDir
local toggleVfInv

-- VF: gestalt trio, detected on login. Settings does not edit this.
local myClasses         = {}

local DATA, DATA_OK     = Boot.loadData(cfg, scriptDir)

local lvlMin, lvlMax = 1, 65

-- VF: gems[i] / aas[name] / discs[name] / items[name]. Items = MQ2Cast clickies.
local loadout        = { gems = {}, aas = {}, discs = {}, items = {}, spell_gates = {} }




local ctrl                   -- forward declaration for lexical scoping in helpers
local isGroupOrRaidMember    -- forward declaration for lexical scoping in helpers
local isSpawnPetOrPlayer     -- forward declaration for lexical scoping in helpers
local isAnyPet               -- forward declaration for lexical scoping in helpers
local isHostileTarget        -- forward declaration for lexical scoping in helpers
local isCombat               -- forward declaration for lexical scoping in helpers
local isIdleSelfBuff         -- forward declaration; used by rowBlocked above its def
local buffActive             -- forward declaration for lexical scoping in helpers

-- VF: maps leftover mode names onto Manual | Roam | Rush | Group.
local function sanitizeModeConfig(c)
    c = c or ctrl
    if not c then return end
    local m = c.mode
    local sub = c.submode
    if m == 'Manual Hunter' or m == 'Pause' then
        c.mode = 'Manual'
    elseif m == 'Puller' then
        c.mode = (sub == 'Rush') and 'Rush' or 'Roam'
    elseif m == 'Hunt' or m == 'Roam' or m == 'Solo' or m == 'Hunter'
        or m == 'Pet Tank' or m == 'Grinder' or m == 'Pull & Assist' then
        c.mode = 'Roam'
    elseif m == 'Party' or m == 'Chase Assist' or m == 'Group'
        or m == 'Assist' or m == 'Garrison' or m == 'Tank' then
        c.mode = 'Group'
    end

    if c.mode ~= 'Manual' and c.mode ~= 'Roam' and c.mode ~= 'Rush' and c.mode ~= 'Group' then
        c.mode = 'Manual'
    end
    c.submode = ''

    if c.hunter_z_plane == nil then c.hunter_z_plane = 15 end
    if c.hunter_z == nil then c.hunter_z = 75 end
    c.hunter_level_rel = true
    c.maintain_buffs = true
    c.hud = 'mini'
    if c.hunter_rel_min == nil then c.hunter_rel_min = 0 end
    if c.hunter_rel_max == nil then c.hunter_rel_max = 5 end

    if type(c.pull_con_filter) ~= 'table' then
        c.pull_con_filter = {}
    end
    for _, conName in ipairs(D.PULL_CON_LIST) do
        if c.pull_con_filter[conName] == nil then
            c.pull_con_filter[conName] = true
        end
    end
end

local function defaultCtrl()
    return require('vft.mgr.schema').defaultControl()
end
ctrl = defaultCtrl()
sanitizeModeConfig(ctrl)

-- VF: Runtime & state management tables.
local runtime = {
    allData = {},
    pullState = 'IDLE',
    pullTargetId = 0,
    deathGuardFired = false,
    medBreakActive = false,
    postCombatHealActive = false,
    healKindCache = {},
    lastCast = {},
    lastTick = 0,
    wasRunning = false,
    lastSig = nil,
    autoDirty = false,
    autoDirtyAt = 0,
    lastBuffDiagAt = 0,
    lastHunterDiagAt = 0,
    lastHunterMsgKey = nil,
    lastGemDiagAt = 0,
    lastAssistCmdAt = 0,
    manualFightArmed = false,
    manualCommitId = 0,
    _assistId = 0,
    sungBuffs = {},
    buffTries = {},
    trackStartTime = nil,
    startAA = nil,
    currentAA = 0,
    startPlat = nil,
    currentPlat = 0,
    psPct = nil,
    psName = nil,
    psAt = 0,
    psSource = nil,
    ignoreList = {},
    pullList = {},
    ignoreInput = '',
    pullInput = '',
    conCache = {},
    lastConReqAt = 0,
    knownDiscSet = nil,
    discExpires = {},
    discCooldown = {},
    gemSyncWarned = {},
    lastGemSyncCheckAt = 0,
    colN = 0,
    varN = 0,

    -- VF: walker cursor. One table, one navReset(). Do not scatter these fields again.
    nav = {
        pin = 1,             -- index of the loc we are walking to
        anchored = false,    -- pin was chosen; do not re-pick nearest
        travelSpent = false, -- first Loop/Guide reached, Travel pass is over
        fighting = false,    -- standing on a pin clearing its hate list
        engaged = false,     -- something actually showed up on this pin
        clearedPin = 0,      -- last pin we finished, so it cannot re-arm
        arrivedAt = nil,     -- when we reached the pin (train grace)
        reachAt = nil,       -- last time anything on the list was reachable
        warned = false,      -- "route has no Combat loc" printed once
        logLast = nil,       -- de-dupes ta_rush.log
        watch = { pin = nil, best = nil, at = nil }, -- approach stall watchdog
    }
}

local petState = {
    myPets = {},
    lastObservedId = 0,
    lastCastCls = nil,
    lastCmdTargetId = 0,
    lastCmdAt = 0,
    manualHunterHold = nil,
    petHoldActive = false, -- true when we issued /pet hold waiting for HP threshold
    holdIssuedForId = 0    -- target ID for which a hold was issued
}

local pursuit = {
    id = 0,
    bestDist = 9e9,
    improvedAt = 0,
    navStalls = 0,
    wasNavActive = false,
    lastLoSAt = 0,
    lastNavTargetId = 0,
    lastNavLoc = nil,
    wanderLoc = nil,
    unreachableIds = {},
    lastTooFarRepositionAt = 0,
    lastCantHitAt = 0,
    cantHitCount = 0,
    hasRetargeted = false,
    nonXtarTargetId = 0,
    nonXtarEngageAt = 0,
    lastCombatFaceAt = 0,
    lastStickDist = 0
}

local stuckState = {
    checkAt = 0,
    lastX = 0,
    lastY = 0,
    counter = 0,
    attempts = 0,
    lastDoorClickAt = 0,
    lastStuckRecoveryAt = nil,
    lastCannotSeeAt = 0,
    cannotSeeAttempts = 0,
    lastMeshRecoveryAt = nil,
    meshAttempts = 0,
    lastSwimJump = 0,
    lastSafeX = nil,
    lastSafeY = nil,
    lastSafeZ = nil,
    lastSafeAt = 0,
    lastEscapeAt = 0,
    escapingUntil = nil,
}

-- VF: fullStop / onZoned -- STOP, mode switch, death, zone-in.
local fullStop, onZoned, hasActivePet
local function trioHasPetClass()
    for _, c in ipairs(myClasses) do if D.PET_CLASSES[c] then return true end end
    return false
end

local function trioHasBard()
    for _, c in ipairs(myClasses) do
        if c == 'Brd' or c == 'BRD' then return true end
    end
    return false
end

-- VF: THE owner for taking the bar back: stop the rotation, then /stopsong. Never stops a real spell.
local function freeBardBarForHeal(why)
    if not trioHasBard() then return false end
    runtime.bardHoldUntil = 0
    if runtime.songRotateStop then runtime.songRotateStop(why or 'bar') end
    local id, skill = 0, ''
    pcall(function()
        id = mq.TLO.Me.Casting.ID() or 0
        skill = mq.TLO.Me.Casting.Skill() or ''
    end)
    if id <= 0 then return false end
    -- VF: instrument songs hold the bar too. Matching only 'Singing' let Denon's
    -- VF: (Brass Instruments) sit locked and the heal never got the bar.
    if not runtime.bardCastSkill(skill) then return false end
    mq.cmd('/stopsong')
    -- VF: do not park the tick. 400ms+400ms here made every post-song gem feel frozen.
    local waited = 0
    while waited < 150 do
        local still, stillSkill = 0, ''
        pcall(function()
            still = mq.TLO.Me.Casting.ID() or 0
            stillSkill = mq.TLO.Me.Casting.Skill() or ''
        end)
        if still == 0 or not runtime.bardCastSkill(stillSkill) then break end
        mq.delay(50)
        waited = waited + 50
    end
    return true
end

-- VF: combat->idle release. Skill-checked -- an unconditional /stopsong here killed Dru/Rng casts in flight.
local function releaseBardBarAfterCombat()
    if not trioHasBard() then return end
    local now = os.clock()
    if (now - (runtime.bardCombatStopAt or 0)) < 2.0 then return end
    runtime.bardCombatStopAt = now
    freeBardBarForHeal('combat end')
end

-- VF: /pet hold is a no-op without this AA. pcall -- missing AA throws on some MQ builds.
local function hasAdvPetDiscipline()
    local ok, result = pcall(function()
        local aa = mq.TLO.Me.AltAbility('Advanced Pet Discipline')
        if not aa or not aa() then return false end
        local rank = aa.Rank() or 0
        return rank >= 1
    end)
    return ok and result == true
end

-- VF: ignore names — auto-target and /attack. Shared across toons. Click still works; we will not swing.




local function classPlausible(abbr)
    if not abbr or type(abbr) ~= 'string' then return false end
    if DATA and DATA.spells and DATA.spells[abbr] and #DATA.spells[abbr] > 0 then
        return true
    end
    for _, a in ipairs(D.ALL_ABBR) do
        if a == abbr then return true end
    end
    return false
end




local function isGemMatching(slotOrName, targetSpellName)
    if not targetSpellName or targetSpellName == '' then return false end
    local gemName = nil
    if type(slotOrName) == 'number' then
        pcall(function() gemName = mq.TLO.Me.Gem(slotOrName).Name() end)
    else
        gemName = slotOrName
    end
    if not gemName or gemName == '' or gemName == 'NULL' or gemName == 'nil' then return false end
    if gemName == targetSpellName then return true end

    local cleanGem = U.cleanSpellName(gemName):lower()
    local cleanTarget = U.cleanSpellName(targetSpellName):lower()
    if cleanGem ~= '' and cleanGem == cleanTarget then return true end

    local normGem = U.normalizeSpellName(gemName)
    local normTarget = U.normalizeSpellName(targetSpellName)
    if normGem ~= '' and normGem == normTarget then return true end

    local ok1, r1 = pcall(function() return mq.TLO.Spell(gemName).RankName() end)
    local ok2, r2 = pcall(function() return mq.TLO.Spell(targetSpellName).RankName() end)
    if ok1 and ok2 and r1 and r2 then
        local str1, str2 = tostring(r1), tostring(r2)
        if str1 ~= '' and str1 ~= 'NULL' and str1 == str2 then
            return true
        end
    end
    return false
end


local function scanKnownDiscs()
    runtime.knownDiscSet = {}
    pcall(function()
        -- VF: CombatAbility(i)() is the name; Count/.Name() are flaky on this build.
        local function caName(i)
            local name
            pcall(function()
                local ca = mq.TLO.Me.CombatAbility(i)
                if not ca then return end
                local v = ca()
                if type(v) == 'string' then name = v
                elseif ca.Name then name = ca.Name() end
            end)
            if type(name) ~= 'string' or name == '' or name == 'NULL' then return '' end
            return name
        end
        local count = 0
        pcall(function() count = tonumber(mq.TLO.Me.CombatAbilityCount()) or 0 end) ---@diagnostic disable-line: undefined-field
        if count > 0 then
            for i = 1, count do
                local name = caName(i)
                if name ~= '' then
                    runtime.knownDiscSet[name] = true
                    runtime.knownDiscSet[name:lower()] = true
                end
            end
        else
            local blank = 0
            for i = 1, 300 do
                local name = caName(i)
                if name ~= '' then
                    blank = 0
                    runtime.knownDiscSet[name] = true
                    runtime.knownDiscSet[name:lower()] = true
                else
                    blank = blank + 1
                    if i > 50 and blank > 30 then break end
                end
            end
        end
    end)
end

local function isDiscKnown(discName)
    if not discName or discName == "" then return false end
    if not runtime.knownDiscSet then scanKnownDiscs() end
    local kSet = runtime.knownDiscSet or {}
    local nm = U.cleanSpellName(discName) or ""
    if (nm ~= "" and (kSet[nm] or kSet[nm:lower()])) or kSet[discName] or kSet[discName:lower()] then
        return true
    end
    local ok, res = pcall(function() return mq.TLO.Me.CombatAbility(nm)() end)
    return (ok and res ~= nil)
end

local function parseClassLine(text)
    if not text or type(text) ~= 'string' or text == '' or text == 'NULL' then return nil end
    local cleaned = text:gsub('^%s*%d+[%s%.:]*', ''):gsub('^%s+', '')
    if cleaned == '' then return nil end

    local up = cleaned:upper()
    if up:find('^LEVEL') or up:find('^LVL') then return nil end

    local code3 = up:sub(1, 3)
    if MQSHORT[code3] then return MQSHORT[code3] end

    local code2 = up:sub(1, 2)
    if MQSHORT[code2] then return MQSHORT[code2] end

    for word in cleaned:gmatch('%a+') do
        local wup = word:upper()
        if MQSHORT[wup] then return MQSHORT[wup] end
    end

    return nil
end

local function scanOneNode(node, found)
    if not node or not node() then return end
    pcall(function()
        local items = node.Items()
        if items and items > 0 then
            for i = 1, items do
                local ok, text = pcall(function() return node.List(i)() end)
                if ok and text and text ~= '' and text ~= 'NULL' then
                    local norm = parseClassLine(text)
                    if norm then
                        local dup = false
                        for _, existing in ipairs(found) do
                            if existing == norm then
                                dup = true; break
                            end
                        end
                        if not dup then found[#found + 1] = norm end
                    end
                end
            end
        end
    end)
    pcall(function()
        local text = node.Text()
        if text and text ~= '' and text ~= 'NULL' then
            for line in text:gmatch('[^\r\n]+') do
                local norm = parseClassLine(line)
                if norm then
                    local dup = false
                    for _, existing in ipairs(found) do
                        if existing == norm then
                            dup = true; break
                        end
                    end
                    if not dup then found[#found + 1] = norm end
                end
            end
        end
    end)
end

local function walkChildTree(parentNode, found, depth)
    if not parentNode or not parentNode() then return end
    depth = depth or 0
    if depth > 15 then return end
    local okChild, child = pcall(function() return parentNode.FirstChild end)
    if not okChild or not child or not child() then return end
    local visited = 0
    while child and child() and visited < 200 do
        visited = visited + 1
        scanOneNode(child, found)
        walkChildTree(child, found, depth + 1)
        local okNext, nxt = pcall(function() return child.Next end)
        if not okNext or not nxt or not nxt() then break end
        child = nxt
    end
end

local function classesFromInventoryWindow(loud, force)
    local wasOpen = false
    pcall(function() wasOpen = mq.TLO.Window('InventoryWindow').Open() end)

    if not wasOpen and force then
        mq.cmd('/windowstate InventoryWindow open')
        mq.delay(250)
    end

    local found = {}

    -- VF: 1.
    pcall(function()
        local invWin = mq.TLO.Window('InventoryWindow')
        if not invWin or not invWin() then return end
        local abbrChild = invWin.Child('IW_ClassAbbr')
        if abbrChild and abbrChild() then
            local text = abbrChild.Text()
            if text and text ~= '' and text ~= 'NULL' then
                for line in text:gmatch('[^\r\n]+') do
                    local norm = parseClassLine(line)
                    if norm then
                        local dup = false
                        for _, existing in ipairs(found) do
                            if existing == norm then
                                dup = true; break
                            end
                        end
                        if not dup then found[#found + 1] = norm end
                    end
                end
            end
        end
    end)

    -- VF: 2.
    if #found == 0 then
        pcall(function()
            local invWin = mq.TLO.Window('InventoryWindow')
            if not invWin or not invWin() then return end
            local clsChild = invWin.Child('IW_Class')
            if clsChild and clsChild() then
                local text = clsChild.Text()
                if text and text ~= '' and text ~= 'NULL' then
                    for line in text:gmatch('[^\r\n]+') do
                        local norm = parseClassLine(line)
                        if norm then
                            local dup = false
                            for _, existing in ipairs(found) do
                                if existing == norm then
                                    dup = true; break
                                end
                            end
                            if not dup then found[#found + 1] = norm end
                        end
                    end
                end
            end
        end)
    end

    -- VF: 3.
    if #found == 0 then
        pcall(function()
            local invWin = mq.TLO.Window('InventoryWindow')
            if not invWin or not invWin() then return end
            local listChild = invWin.Child('IW_ClassList')
            if listChild and listChild() then
                for i = 1, 10 do
                    local ok, text = pcall(function() return listChild.List(i)() end)
                    if ok and text and text ~= '' and text ~= 'NULL' then
                        local norm = parseClassLine(text)
                        if norm then
                            local dup = false
                            for _, existing in ipairs(found) do
                                if existing == norm then
                                    dup = true; break
                                end
                            end
                            if not dup then found[#found + 1] = norm end
                        end
                    end
                end
                if #found == 0 then
                    local okText, rawText = pcall(function() return listChild.Text() end)
                    if okText and rawText and rawText ~= '' and rawText ~= 'NULL' then
                        for line in rawText:gmatch('[^\r\n]+') do
                            local norm = parseClassLine(line)
                            if norm then
                                local dup = false
                                for _, existing in ipairs(found) do
                                    if existing == norm then
                                        dup = true; break
                                    end
                                end
                                if not dup then found[#found + 1] = norm end
                            end
                        end
                    end
                end
            end
        end)
    end

    -- VF: 4.
    if #found == 0 then
        pcall(function()
            local invWin = mq.TLO.Window('InventoryWindow')
            if invWin and invWin() then
                walkChildTree(invWin, found, 0)
            end
        end)
    end

    if not wasOpen and force then
        mq.cmd('/windowstate InventoryWindow close')
    end

    if #found > 0 then
        if loud then
            print(string.format('\127[33m[VF]\127[r Detected %d class(es) from InventoryWindow: %s', #found,
                table.concat(found, ', ')))
        end
        return found
    end

    if loud then
        print('\127[31m[VF]\127[r InventoryWindow returned no classes.')
    end
    return nil
end

local function detectClasses(loud)
    local found = classesFromInventoryWindow(loud, true)
    if found and #found > 0 then return found end

    local ok, mainClass = pcall(function() return mq.TLO.Me.Class.ShortName() end)
    if ok and mainClass and mainClass ~= '' and mainClass ~= 'NULL' then
        local norm = U.toCanonicalClassAbbr(mainClass)
        if norm then
            if loud then
                print(string.format('\127[33m[VF]\127[r Single-class character fallback (%s).', norm))
            end
            return { norm }
        end
    end

    return nil
end

local function isSpawnAlive(id)
    if not id or id <= 0 then return false end
    local ok, s = pcall(function() return mq.TLO.Spawn(id) end)
    if not ok or not s or not s() then return false end
    local dead, tp, state = false, '', ''
    pcall(function() dead = s.Dead() end)
    pcall(function() tp = s.Type() end)
    pcall(function() state = s.State() end)
    return (not dead) and (tp ~= 'Corpse') and (state ~= 'DEAD')
end

local function isSpawnMyPet(s_or_id)
    if not s_or_id then return false end
    local s = (type(s_or_id) == 'number') and mq.TLO.Spawn(s_or_id) or s_or_id
    if not s or not s() then return false end
    local myId = 0
    local myName = ''
    pcall(function()
        myId = mq.TLO.Me.ID() or 0
        myName = mq.TLO.Me.CleanName() or ''
    end)
    if myId <= 0 then return false end

    local isMine = false
    pcall(function()
        local curPetId = mq.TLO.Me.Pet.ID() or 0
        local sid = s.ID() or 0
        if curPetId > 0 and sid == curPetId then
            isMine = true
            return
        end

        local m = s.Master
        if m and m() and (m.ID() or 0) == myId then
            isMine = true
            return
        end

        local o = s.Owner
        if o and o() and (o.ID() or 0) == myId then
            isMine = true
            return
        end

        local cname = s.CleanName() or ''
        if myName ~= '' and cname ~= '' then
            if cname:find(myName .. "'s ", 1, true) or
               cname:find(myName .. "`s ", 1, true) or
               cname:find('(Owner: ' .. myName .. ')', 1, true) then
                isMine = true
                return
            end
        end
    end)
    return isMine
end

-- VF: Returns true if the player currently has an active living pet (or any live trio pet in petState.myPets).
hasActivePet = function()
    local myPetId = 0
    pcall(function() myPetId = mq.TLO.Me.Pet.ID() or 0 end)
    if myPetId > 0 and isSpawnAlive(myPetId) then
        return true
    end
    if petState and type(petState.myPets) == 'table' then
        for k, petId in pairs(petState.myPets) do
            if petId and petId > 0 and isSpawnAlive(petId) and isSpawnMyPet(petId) then
                return true
            elseif petId and petId > 0 and not isSpawnAlive(petId) then
                petState.myPets[k] = nil
            end
        end
    end
    return false
end

-- VF: 3D. Distance() is (x,y) only -- a mob one floor up read as in reach, so
-- VF: /attack fired and never landed. Other call sites already used Distance3D.
local function distToId(id)
    if not id or id <= 0 then return 9999 end
    local d = 9999
    pcall(function() d = mq.TLO.Spawn(id).Distance3D() or 9999 end)
    if d == 9999 then
        pcall(function() d = mq.TLO.Spawn(id).Distance() or 9999 end)
    end
    return d
end

local function distToLoc(x, y, z)
    if not x or not y then return 9999 end
    local mx, my, mz = 0, 0, 0
    pcall(function() mx = mq.TLO.Me.X() or 0 end)
    pcall(function() my = mq.TLO.Me.Y() or 0 end)
    pcall(function() mz = mq.TLO.Me.Z() or 0 end)
    local dx, dy = mx - x, my - y
    local dz = z and (mz - z) or 0
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function hasLoS(id)
    if not id or id <= 0 then return false end
    local los = false
    pcall(function() los = mq.TLO.Spawn(id).LineOfSight() or false end)
    return los
end

local function pctHP(id)
    if not id or id <= 0 then return 0 end
    local hp = nil
    pcall(function()
        -- VF: Target.PctHPs is fresher than Spawn for the kill target (client HP cache).
        local tid = mq.TLO.Target.ID() or 0
        if tid == id then
            hp = mq.TLO.Target.PctHPs()
        end
        if hp == nil then
            local s = mq.TLO.Spawn(id)
            if s and s() then hp = s.PctHPs() end
        end
    end)
    return tonumber(hp) or 0
end




local function navLoaded()
    local ok, loaded = pcall(function()
        if mq.TLO.Navigation and (mq.TLO.Navigation() ~= nil or mq.TLO.Navigation.MeshLoaded() ~= nil) then
            return true
        end
        local p = mq.TLO.Plugin('mq2nav') or mq.TLO.Plugin('MQ2Nav') or mq.TLO.Plugin('nav')
        if p and p() and p.IsLoaded and p.IsLoaded() then return true end
        return false
    end)
    return ok and (loaded == true)
end

local function stickLoaded()
    local ok, loaded = pcall(function()
        if mq.TLO.Stick and (mq.TLO.Stick() ~= nil or mq.TLO.Stick.Status() ~= nil) then
            return true
        end
        local p = mq.TLO.Plugin('mq2moveutils') or mq.TLO.Plugin('MQ2MoveUtils') or mq.TLO.Plugin('moveutils')
        if p and p() and p.IsLoaded and p.IsLoaded() then return true end
        return false
    end)
    return ok and (loaded == true)
end

local function isMoveActive()
    local navActive, moveActive, moveToActive, nativeActive = false, false, false, false
    if navLoaded() then
        pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
    end
    if stickLoaded() then
        pcall(function()
            if mq.TLO.Stick.Active() or mq.TLO.Stick.Status() == 'ON' then
                moveActive = mq.TLO.Me.Moving() or false
            end
        end)
    end
    pcall(function()
        if mq.TLO.MoveTo and mq.TLO.MoveTo.Moving then
            moveToActive = mq.TLO.MoveTo.Moving() or false
        end
    end)
    if (pursuit.lastNavLoc and string.find(tostring(pursuit.lastNavLoc), '^native_')) or
       (pursuit.lastNavTargetId and string.find(tostring(pursuit.lastNavTargetId), '^native_')) then
        if mq.TLO.Me.Moving() then
            nativeActive = true
        end
    end
    return navActive or moveActive or moveToActive or nativeActive
end

-- VF: mover ownership. travel=MQ2Nav, combat=MoveUtils, follow=AdvPath. Never two at once.
runtime.mover = nil          -- nil | 'travel' | 'combat' | 'follow'
runtime.moverAt = 0
runtime.moverDebug = false   -- true logs handoffs to config/ta_rush.log

runtime.claimMover = function(kind)
    if runtime.mover == kind then return end
    if runtime.moverDebug and runtime.rushLog then
        runtime.rushLog(string.format('mover %s -> %s', tostring(runtime.mover), tostring(kind)))
    end
    if kind ~= 'follow' and runtime.groupFollowStop then runtime.groupFollowStop() end
    -- VF: claiming travel/follow kills leftover stick/moveto. Claiming combat must not stop nav yet.
    if (kind == 'travel' or kind == 'follow') and stickLoaded() then
        pcall(function()
            if mq.TLO.Stick.Active() or mq.TLO.Stick.Status() == 'ON' then mq.cmd('/stick off') end
        end)
        pcall(function()
            if mq.TLO.MoveTo and mq.TLO.MoveTo.Moving and mq.TLO.MoveTo.Moving() then
                mq.cmd('/moveto off')
            end
        end)
    end
    runtime.mover = kind
    runtime.moverAt = os.clock()
end

-- VF: nav owns the approach past this range, /stick owns everything inside it.
runtime.STICK_HANDOFF = 120
runtime.stickHandoff = function()
    local n = ctrl and tonumber(ctrl.stick_handoff)
    if n and n > 0 then return n end
    return runtime.STICK_HANDOFF or 120
end
-- VF: walk ? crow must be ? this for stick/Melee. Larger = wall/detour ? keep /nav.
runtime.PATH_SLACK = 25
runtime.STICK_POS_FLAG = { Behind = ' behind', Front = ' front', Side = ' pin' }
-- VF: RH closeness. Honest humanoid 70% of MaxRangeTo; fat/Kael-lie 30%. Re-issue on target switch.
runtime.STICK_PCT = 70
runtime.STICK_PCT_FAT = 30
runtime.STICK_FAT_REACH = 28
runtime.STICK_FAT_HEIGHT = 14

-- VF: true when MoveUtils is already sticking this exact spawn.
runtime.stickHolding = function(id)
    if not id or id <= 0 or not stickLoaded() then return false end
    local active, st = false, 0
    pcall(function() active = (mq.TLO.Stick.Active() or mq.TLO.Stick.Status() == 'ON') or false end)
    if not active then return false end
    pcall(function() st = mq.TLO.Stick.StickTarget() or 0 end)
    return st == id
end

-- VF: in stick range. MoveUtils holds the gap itself, so do not stopMoving here.
runtime.stickStopped = function()
    local stopped = false
    pcall(function() stopped = mq.TLO.Stick.Stopped() or false end)
    return stopped
end

-- VF: PathLength ? Distance ? honest crow-flies approach for stick/Melee.
-- VF: no mesh loaded ? allow stick (only mover left). No path ? never stick a wall.
runtime.pathOpenTo = function(id)
    if not id or id <= 0 then return false end
    if not navLoaded() then return true end
    local exists, walk = false, 0
    pcall(function()
        local spec = 'id ' .. id
        exists = not not mq.TLO.Navigation.PathExists(spec)()
        walk = tonumber(mq.TLO.Navigation.PathLength(spec)()) or 0
    end)
    if not exists or walk <= 0 then return false end
    local crow = distToId(id)
    if crow < 1 then crow = 1 end
    return (walk - crow) <= (runtime.PATH_SLACK or 25)
end

-- VF: weapon reach. Helpers ABOVE stickPursue ? later locals are not upvalues (override was nil).
local MELEE_RANGE = 14

local function spawnMeleeMetrics(id)
    local reach, height = 0, 0
    if not id or id <= 0 then return reach, height end
    pcall(function()
        local s = mq.TLO.Spawn(id)
        if s and s() then
            reach = tonumber(s.MaxRangeTo()) or tonumber(s.MaxMeleeTo()) or 0
            height = tonumber(s.AvatarHeight()) or tonumber(s.Height()) or 0
        end
    end)
    if reach <= 0 or height <= 0 then
        pcall(function()
            local t = mq.TLO.Target
            if t() and (t.ID() or 0) == id then
                if reach <= 0 then
                    reach = tonumber(t.MaxRangeTo()) or tonumber(t.MaxMeleeTo()) or 0
                end
                if height <= 0 then
                    height = tonumber(t.AvatarHeight()) or tonumber(t.Height()) or 0
                end
            end
        end)
    end
    return reach, height
end

-- VF: inside stick_handoff (120) stick owns feet -- no LoS/path/nav gate.
-- VF: Ranged: melee stick only when already in MaxRangeTo. The bow line is nav, not 70%.
runtime.canStickClose = function(id)
    if not id or id <= 0 then return false end
    if ctrl and ctrl.combat_style == 'Ranged' then
        -- VF: this helper sits above the maxMeleeDistance local. Use the runtime slot.
        local reach = 18
        if runtime.maxMeleeDistance then reach = runtime.maxMeleeDistance(id) or 18 end
        return distToId(id) <= reach
    end
    if runtime.stickHolding(id) then return true end
    return distToId(id) <= runtime.stickHandoff()
end

-- VF: fat/Kael -- MaxRangeTo or height past these uses 30% closeness, not 70%.
local function stickNeedsHitboxOverride(id)
    local reach, height = spawnMeleeMetrics(id)
    local fatReach = runtime.STICK_FAT_REACH or 28
    local fatH = runtime.STICK_FAT_HEIGHT or 14
    return (reach > fatReach) or (height > fatH), reach, height
end

-- VF: percent of MaxRangeTo for /stick. Not AvatarHeight -- that is Melee's moonwalk Dist.
runtime.stickCloseness = function(id)
    if select(1, stickNeedsHitboxOverride(id)) then
        return runtime.STICK_PCT_FAT or 30
    end
    return runtime.STICK_PCT or 70
end

-- VF: fat model -- stand at MaxRangeTo, not melee_dist (inside the box → Melee walks backwards).
local function hitboxEdgeDist(id)
    local reach = select(1, spawnMeleeMetrics(id))
    local userDist = (ctrl and ctrl.melee_dist) or MELEE_RANGE
    if reach > userDist then
        return math.max(userDist, reach - 2)
    end
    return 0
end

-- VF: restore Melee stick rails after any leftover suppress.
local function meleeStickSuppress(on)
    if not (runtime.meleeLoaded and runtime.meleeLoaded()) then return end
    if on then
        pcall(function() mq.cmd('/melee stickmode=2') end)
        pcall(function() mq.cmd('/melee stickrange=0') end)
        pcall(function() mq.cmd('/melee sticknorange=0') end)
        pcall(function() mq.cmd('/stick off') end)
    else
        -- VF: VFT owns /stick %. Never restore stickmode=0 (AvatarHeight + moveback).
        pcall(function() mq.cmd('/melee stickmode=2') end)
        local chase = (ctrl and tonumber(ctrl.xtar_nav_dist)) or 150
        -- VF: Manual idle bubble; attack-commit chase uses full Chase for Melee stickrange.
        if not runtime.manualCommitId
            and ((not ctrl.running) or (ctrl and ctrl.mode == 'Manual')) then
            chase = math.min(chase, runtime.rushNear or 80)
        end
        pcall(function() mq.cmdf('/melee stickrange=%d', math.max(10, math.floor(chase))) end)
    end
end
runtime.meleeStickSuppress = meleeStickSuppress

local function clearMeleeStickSuppress()
    if not runtime.meleeStickSuppressed then return end
    runtime.meleeStickSuppressed = false
    meleeStickSuppress(false)
end

-- VF: no-op. Large-hitbox Melee suppress reinvented stick; do not re-arm.
local function ensureHitboxMeleeSuppress(_id)
    clearMeleeStickSuppress()
    return false
end
runtime.ensureHitboxMeleeSuppress = ensureHitboxMeleeSuppress

-- VF: E3 StickToAssistTarget. Dist is MaxMelee (MaxRangeTo) with the Combat slider
-- VF: as a floor, then clamp 1-33. docs/COMBAT_OWNERS.md.
runtime.clampAssistDist = function(maxRangeTo, userDist)
    local d = tonumber(maxRangeTo) or 0
    local user = tonumber(userDist) or 0
    if user > 0 then d = math.max(d, user) end
    if d > 33 then d = 33 end
    if d < 1 then d = 14 end
    return math.floor(d)
end

runtime.assistDistance = function(id)
    local reach = select(1, spawnMeleeMetrics(id))
    local user = (ctrl and tonumber(ctrl.melee_dist)) or 0
    return runtime.clampAssistDist(reach, user)
end

-- VF: Chase leash is max engage (E3 Assists_MaxEngagedDistance analogue).
runtime.maxEngageDistance = function()
    local chase = (ctrl and tonumber(ctrl.xtar_nav_dist)) or 150
    if chase < 1 then chase = 150 end
    if (not ctrl.running) or (ctrl.mode == 'Manual') then
        local commit = tonumber(runtime.manualCommitId) or 0
        if commit <= 0 then
            return math.min(chase, runtime.rushNear or 80)
        end
    end
    return chase
end

-- VF: /stick hold <point> <MaxMelee> uw. No percent stick. No mq.delay snaproll.
runtime.assistStickCmd = function(id)
    local dist = runtime.assistDistance(id)
    local pos = (ctrl and ctrl.stick_position) or 'Any'
    if pos == 'Front' then
        return string.format('hold front %d uw', dist)
    end
    if pos == 'Side' then
        return string.format('hold moveback pin %d uw', dist)
    end
    return string.format('hold moveback behind %d uw', dist)
end

-- VF: restick if not Active or PAUSED. Never /nav. E3 ProcessCombat.
runtime.stickToAssistTarget = function(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    if runtime.castingMustStand and runtime.castingMustStand() then return false end
    if not stickLoaded() then return false end
    if runtime.navEscapedHold and runtime.navEscapedHold() then return false end
    local cmd = runtime.assistStickCmd(id)
    local active, status = false, ''
    pcall(function()
        active = not not mq.TLO.Stick.Active()
        status = tostring(mq.TLO.Stick.Status() or '')
    end)
    if active and status ~= 'PAUSED' and runtime.stickHolding(id)
        and pursuit.assistCmd == cmd then
        return true
    end
    runtime.claimMover('combat')
    if navLoaded() then
        pcall(function()
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
        end)
    end
    mq.cmdf('/squelch /face fast id %d', id)
    mq.cmdf('/squelch /stick %s', cmd)
    pursuit.assistCmd = cmd
    pursuit.stickId = id
    pursuit.stickPct = nil
    return true
end

-- VF: E3 AssistOn. Face + stick hold + ensureAttack. No /nav on a fight spawn.
runtime.assistOn = function(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    if runtime.swingTargetLive and not runtime.swingTargetLive(id) then return false end
    local d = distToId(id)
    local maxEng = runtime.maxEngageDistance()
    local onMe = runtime.spawnIsOnMe and runtime.spawnIsOnMe(id)
    if d > maxEng and not onMe then return false end
    if runtime.ensureAttack then runtime.ensureAttack(id) end
    if runtime.mayClose and not runtime.mayClose(id) then return true end
    return runtime.stickToAssistTarget(id)
end

-- VF: percent /stick for travel handoff and ranged-in-face. Melee fight uses stickToAssistTarget.
runtime.stickPursue = function(id, dist)
    if runtime.castingMustStand and runtime.castingMustStand() then return false end
    if not id or id <= 0 then return false end
    if not stickLoaded() then return false end
    clearMeleeStickSuppress()
    if not runtime.canStickClose(id) then
        pursuit.stickId = nil
        pursuit.stickPct = nil
        return false
    end
    if navLoaded() then
        pcall(function()
            if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
        end)
    end
    local pct = runtime.stickCloseness(id)
    local pos = ''
    if ctrl and runtime.STICK_POS_FLAG then
        pos = runtime.STICK_POS_FLAG[ctrl.stick_position] or ''
    end
    -- VF: breakontarget off keeps old Dist on a new spawn -- do not trust StickTarget alone.
    if runtime.stickHolding(id) and pursuit.stickId == id and pursuit.stickPct == pct then
        return true
    end
    pcall(function()
        mq.cmdf('/stick %d%% id %d%s', pct, id, pos)
    end)
    pursuit.stickId = id
    pursuit.stickPct = pct
    return true
end

-- VF: /stick id holds the old spawn. A new hostile target must restick -- do not keep the last id.
-- VF: look-at is not a chase -- only /attack on, CombatState COMBAT, or on-me.
-- VF: unarmed Manual is not assisting (COMBAT_OWNERS consent).
runtime.stickFollowTarget = function()
    local tid = 0
    pcall(function() tid = mq.TLO.Target.ID() or 0 end)
    if tid <= 0 or not isHostileTarget(tid) then return false end
    if runtime.manualFightConsent and not runtime.manualFightConsent() then return false end
    local swinging, inCs, onMe = false, false, false
    pcall(function() swinging = not not mq.TLO.Me.Combat() end)
    if runtime.engineInCombat then inCs = not not runtime.engineInCombat() end
    if runtime.spawnIsOnMe then onMe = not not runtime.spawnIsOnMe(tid) end
    if not swinging and not inCs and not onMe then return false end
    if runtime.stickToAssistTarget then return runtime.stickToAssistTarget(tid) end
    return runtime.stickPursue(tid)
end

local function stopMoving()
    -- VF: VFT owns /stick %. Always drop it here -- Melee stickmode=2 will not re-issue.
    if runtime.mover == 'follow' and runtime.groupFollowStop then runtime.groupFollowStop() end
    runtime.mover = nil
    if navLoaded() then
        local navActive = false
        pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
        if navActive then pcall(function() mq.cmd('/nav stop') end) end
    end
    if stickLoaded() then
        local stickActive = false
        pcall(function() stickActive = (mq.TLO.Stick.Active() or mq.TLO.Stick.Status() == 'ON') or false end)
        if stickActive then
            pcall(function() mq.cmd('/stick off') end)
        end
    end
    pursuit.stickId = nil
    pursuit.stickPct = nil
    pursuit.assistCmd = nil
    pcall(function()
        if mq.TLO.MoveTo and mq.TLO.MoveTo.Moving and mq.TLO.MoveTo.Moving() then
            mq.cmd('/moveto off')
        end
    end)
    pursuit.id = 0
    pursuit.lastNavTargetId = 0
    pursuit.lastNavLoc = nil
    pursuit.lastStickDist = 0
end

-- VF: map clicks have no Z -- nav locyx, never invent a height.
runtime.navSpec = function(y, x, z)
    if z == nil then return string.format('locyx %.2f %.2f', y, x) end
    return string.format('loc %.2f %.2f %.2f', y, x, z)
end

runtime.navKey = function(prefix, y, x, z)
    if z == nil then return string.format('%s%.1f_%.1f_flat', prefix, y, x) end
    return string.format('%s%.1f_%.1f_%.1f', prefix, y, x, z)
end

-- VF: travel nav. Issue /nav then verify Navigation.Active -- do NOT pre-gate on
-- VF: PathExists, it reports false for 2D locyx specs that /nav walks fine.
-- VF: true = nav owns movement. false = nav refused, caller walks it natively.
runtime.NAV_TAKE_SECS = 1.5
runtime.NAV_REFUSE_SECS = 15

runtime.navTravel = function(locStr, locKey)
    if runtime.navEscapedHold and runtime.navEscapedHold() then return false end
    if pursuit.navRefusedKey == locKey
        and (os.clock() - (pursuit.navRefusedAt or 0)) < runtime.NAV_REFUSE_SECS then
        return false
    end

    if pursuit.lastNavLoc == locKey then
        local navActive = false
        pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
        if navActive then return true end
        -- VF: Still inside the grace window: nav has not answered yet.
        if (os.clock() - (pursuit.navIssuedAt or 0)) < runtime.NAV_TAKE_SECS then return true end
        pursuit.navRefusedKey = locKey
        pursuit.navRefusedAt = os.clock()
        return false
    end

    mq.cmdf('/nav %s', locStr)
    pursuit.lastNavLoc = locKey
    pursuit.navIssuedAt = os.clock()
    return true
end

-- VF: ' Z:12.3', or nothing at all for a flat destination.
runtime.zLabel = function(z)
    if z == nil then return '' end
    return string.format(' Z:%.1f', z)
end

-- VF: zOr: Me.Z() when a caller must have a number for a flat loc.
runtime.zOr = function(z)
    if z ~= nil then return z end
    local mz = 0
    pcall(function() mz = mq.TLO.Me.Z() or 0 end)
    return mz or 0
end

-- VF: group/raid/self/pet membership.
isGroupOrRaidMember = function(id)
    if not id or id <= 0 then return false end
    if id == mq.TLO.Me.ID() then return true end
    local myPetId = 0
    pcall(function() myPetId = mq.TLO.Me.Pet.ID() or 0 end)
    if myPetId > 0 and id == myPetId then return true end
    if petState and type(petState.myPets) == 'table' then
        for _, petId in pairs(petState.myPets) do
            if petId == id then return true end
        end
    end
    local grpCount = 0
    pcall(function() grpCount = mq.TLO.Group.Members() or 0 end)
    if grpCount > 0 then
        for i = 1, grpCount do
            local m = nil
            pcall(function() m = mq.TLO.Group.Member(i) end)
            if m and m() then
                if (m.ID() or 0) == id then return true end
                local mPet = nil
                pcall(function() mPet = m.Pet end)
                if mPet and mPet() and (mPet.ID() or 0) == id then return true end
            end
        end
    end
    local raidCount = 0
    pcall(function() raidCount = mq.TLO.Raid.Members() or 0 end)
    if raidCount > 0 then
        for i = 1, raidCount do
            local rm = nil
            pcall(function() rm = mq.TLO.Raid.Member(i) end)
            if rm and rm() and (rm.ID() or 0) == id then return true end
        end
    end
    return false
end

-- VF: any pet -- never auto-target these.
isAnyPet = function(s_or_id)
    if not s_or_id then return false end
    local s = (type(s_or_id) == 'number') and mq.TLO.Spawn(s_or_id) or s_or_id
    if not s or not s() then return false end

    local isPetSpawn = false
    pcall(function()
        local stype = s.Type() or ''
        if stype == 'Pet' then isPetSpawn = true return end

        local m = s.Master
        if m and m() and (m.ID() or 0) > 0 then
            isPetSpawn = true
            return
        end

        local o = s.Owner
        if o and o() and (o.ID() or 0) > 0 then
            isPetSpawn = true
            return
        end

        local cname = s.CleanName() or ''
        if cname ~= '' then
            if cname:find("`s pet", 1, true) or cname:find("'s pet", 1, true) or
               cname:find("`s warder", 1, true) or cname:find("'s warder", 1, true) or
               cname:find("`s Familiar", 1, true) or cname:find("'s Familiar", 1, true) or
               cname:find("`s familiar", 1, true) or cname:find("'s familiar", 1, true) then
                isPetSpawn = true
                return
            end
        end
    end)
    return isPetSpawn
end

-- VF: Returns true if spawn ID is self, player pet, group member pet, player character, or pet of a player/mercenary.
isSpawnPetOrPlayer = function(id)
    if not id or id <= 0 then return false end
    if id == mq.TLO.Me.ID() then return true end
    local myPetId = 0
    pcall(function() myPetId = mq.TLO.Me.Pet.ID() or 0 end)
    if myPetId > 0 and id == myPetId then return true end
    if petState and type(petState.myPets) == 'table' then
        for _, petId in pairs(petState.myPets) do
            if petId == id then return true end
        end
    end
    if isGroupOrRaidMember(id) then return true end

    local s = mq.TLO.Spawn(id)
    if not s or not s() then return false end

    local isPlayerOrFriendly = false
    pcall(function()
        if s.Trader and s.Trader() then isPlayerOrFriendly = true return end
        local stype = s.Type() or ''
        if stype == 'PC' or stype == 'Mercenary' then isPlayerOrFriendly = true return end

        local m = s.Master
        if m and m() then
            local mid = m.ID() or 0
            if mid > 0 then
                local mt = m.Type() or ''
                if mt == 'PC' or mt == 'Mercenary' or mid == mq.TLO.Me.ID() or isGroupOrRaidMember(mid) then
                    isPlayerOrFriendly = true
                    return
                end
            end
        end

        local o = s.Owner
        if o and o() then
            local oid = o.ID() or 0
            if oid > 0 then
                local ot = o.Type() or ''
                if ot == 'PC' or ot == 'Mercenary' or oid == mq.TLO.Me.ID() or isGroupOrRaidMember(oid) then
                    isPlayerOrFriendly = true
                    return
                end
            end
        end

        if stype == 'Pet' then
            local cname = s.CleanName() or ''
            if cname:find("`s pet", 1, true) or cname:find("'s pet", 1, true) or
               cname:find("`s warder", 1, true) or cname:find("'s warder", 1, true) or
               cname:find("`s Familiar", 1, true) or cname:find("'s Familiar", 1, true) or
               cname:find("`s familiar", 1, true) or cname:find("'s familiar", 1, true) then
                isPlayerOrFriendly = true
                return
            end
        end
    end)

    return isPlayerOrFriendly
end

-- VF: merchant/banker/tribute/guildmaster — spawn-search + class. Cached 2s.
runtime.isCivicNpc = function(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    local cache = runtime.civicCache
    if type(cache) ~= 'table' then
        cache = {}
        runtime.civicCache = cache
    end
    local now = os.clock()
    local row = cache[id]
    if row and (now - (row.at or 0)) < 2.0 then return row.v and true or false end
    local civic = false
    pcall(function()
        for _, kind in ipairs({ 'merchant', 'banker', 'tribute' }) do
            local s = mq.TLO.Spawn(string.format('id %d %s', id, kind))
            if s and s() and (s.ID() or 0) == id then civic = true; return end
        end
        local s = mq.TLO.Spawn(id)
        if not s or not s() then return end
        if s.Trader and s.Trader() then civic = true; return end
        if s.Buyer and s.Buyer() then civic = true; return end
        local cls = ''
        pcall(function() cls = tostring(s.Class.Name() or ''):lower() end)
        if cls:find('merchant', 1, true) or cls:find('banker', 1, true)
            or cls:find('tribute', 1, true) or cls:find('guildmaster', 1, true)
            or cls:find('guild master', 1, true) or cls:find('shopkeeper', 1, true) then
            civic = true
        end
    end)
    cache[id] = { at = now, v = civic }
    return civic
end

-- VF: per-zone Block List from the Manager Filters tab. '%' is the wildcard, so
-- VF: %Guard% means "name contains Guard". Distinct from runtime.ignoreList, which
-- VF: is global and exact-match. The tab wrote pack.block and nothing read it.
-- VF: Matching is U.wildMatchAny -- see tools/test-blocklist.lua.
runtime.zoneBlockList = function()
    local f = loadout and loadout.filters
    if type(f) ~= 'table' or type(f.zones) ~= 'table' then return nil end
    local short = ''
    pcall(function() short = tostring(mq.TLO.Zone.ShortName() or '') end)
    if short == '' or short == 'NULL' then return nil end
    local pack = f.zones[short]
    if type(pack) == 'table' and type(pack.block) == 'table' then return pack.block end
    return nil
end

runtime.nameBlocked = function(cname)
    if type(cname) ~= 'string' or cname == '' then return false end
    return U.wildMatchAny(cname, runtime.zoneBlockList and runtime.zoneBlockList())
end

-- VF: real aggro — Aggressive flag, or PlayerState 4/8 (Aggressive/ForcedAggressive).
-- VF: The ONLY signal allowed to override the friendly exclusions in isHostileTarget.
runtime.spawnIsAggro = function(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    local s = mq.TLO.Spawn(id)
    if not s or not s() then return false end
    local agg = false
    pcall(function() agg = not not s.Aggressive() end)
    if agg then return true end
    local ps = 0
    pcall(function() ps = tonumber(s.PlayerState()) or 0 end)
    return (math.floor(ps / 4) % 2 == 1) or (math.floor(ps / 8) % 2 == 1)
end

-- VF: in-fight "who" — Aggressive / ForcedAggressive, or wounded hunt trash.
-- VF: ToT-is-us is an ally in the same fight (escort), not a kill. Friendly con / title / surname stay off the pack.
runtime.spawnWantsFight = function(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    if isGroupOrRaidMember(id) or isSpawnPetOrPlayer(id) then return false end
    local s = mq.TLO.Spawn(id)
    if not s or not s() then return false end
    if s.Dead and s.Dead() then return false end
    local stype = ''
    pcall(function() stype = s.Type() or '' end)
    if stype ~= 'NPC' and stype ~= 'Pet' then return false end
    if stype == 'Corpse' then return false end
    local cname = ''
    pcall(function() cname = s.CleanName() or '' end)
    if cname ~= '' and runtime.ignoreList then
        for _, n in ipairs(runtime.ignoreList) do
            if tostring(n) == cname then return false end
        end
    end
    -- VF: Block List is explicit "do not attack", so it outranks aggro here the same
    -- VF: way the ignore list does -- we will still defend via isHostileTarget.
    if runtime.nameBlocked and runtime.nameBlocked(cname) then return false end
    if runtime.isCivicNpc and runtime.isCivicNpc(id) then return false end
    if cname ~= '' and runtime.conCache then
        local tier = runtime.conCache[cname]
        if tier == 'Ally' or tier == 'Warmly' or tier == 'Kindly' or tier == 'Amiably' then
            return false
        end
    end
    if runtime.spawnIsAggro(id) then return true end
    local title, sur = '', ''
    pcall(function() title = tostring(s.Title() or '') end)
    pcall(function() sur = tostring(s.Surname() or '') end)
    if title ~= '' or sur ~= '' then return false end
    local hp = 100
    pcall(function() hp = tonumber(s.PctHPs()) or 100 end)
    return hp < 100
end

-- VF: hostile gate. Civics / ignore / idle friendlies are not attackable.
isHostileTarget = function(id)
    if not id or id <= 0 then return false end
    if runtime.inSafeZone and runtime.inSafeZone() then return false end
    if isSpawnPetOrPlayer(id) then return false end

    local s = mq.TLO.Spawn(id)
    if not s or not s() then return false end
    if s.Dead and s.Dead() then return false end

    local stype = ''
    pcall(function() stype = s.Type() or '' end)
    if stype ~= 'NPC' and stype ~= 'Pet' then return false end

    -- VF: only real aggro may skip the exclusions below. "Wounded" must not:
    -- VF: a quest NPC under 100% reads hostile, and once we land one hit it
    -- VF: stays under 100%, so the mistake latches until it regens or despawns.
    if runtime.spawnIsAggro and runtime.spawnIsAggro(id) then return true end

    local cname = ''
    pcall(function() cname = s.CleanName() or '' end)
    if cname ~= '' and runtime.ignoreList then
        for _, n in ipairs(runtime.ignoreList) do
            if tostring(n) == cname then return false end
        end
    end
    if runtime.nameBlocked and runtime.nameBlocked(cname) then return false end
    if runtime.isCivicNpc and runtime.isCivicNpc(id) then return false end
    if cname ~= '' and runtime.conCache then
        local tier = runtime.conCache[cname]
        if tier == 'Ally' or tier == 'Warmly' or tier == 'Kindly' or tier == 'Amiably' then
            return false
        end
    end
    local sit, title, sur = false, '', ''
    pcall(function() sit = not not s.Sitting() end)
    pcall(function() title = tostring(s.Title() or '') end)
    pcall(function() sur = tostring(s.Surname() or '') end)
    -- VF: idle quest NPCs sit or carry a title/surname; hunt trash is "a rat" with neither.
    if sit or title ~= '' or sur ~= '' then return false end
    return true
end

-- VF: XTarget slot scan removed — closestThreat / spawnWantsFight own fight pick.

local function findMaPcId(maName)
    -- VF: groupRoleHolderId, NOT groupAnchorId. The anchor is "which ally do I
    -- VF: follow" and is nil when we hold every role, so the Tank / Main Assist
    -- VF: tokens resolved to nil on the group leader.
    if runtime.groupRoleHolderId then
        return runtime.groupRoleHolderId(maName)
    end
    if not maName or maName == '' then return nil end
    local id = nil
    pcall(function()
        local s = mq.TLO.Spawn('pc ' .. maName)
        if s and s() and isSpawnAlive(s.ID()) then id = s.ID() end
    end)
    return id
end

local function createCastTracker()
    -- VF: soft lockouts removed ? banned heals mid-fight. MQ2Cast Result is enough.
    local tracker = {}

    local function recordFailure(_spellName, _maxRetries, _lockoutSec)
        tracker.failed = true
    end

    local function isLockedOut(_spellName)
        return false
    end

    local function onFailureEvent(reason, _maxRetries, _lockoutSec)
        local castingName = nil
        pcall(function() castingName = mq.TLO.Me.Casting.Name() end)
        if not castingName or castingName == '' then
            castingName = tracker.activeSpell or tracker.lastSpell
        end
        if castingName and castingName ~= '' then
            tracker.failed = true
        end
    end

    local function recordSuccess(_spellName)
        tracker.failed = false
    end

    tracker.recordFailure = recordFailure
    tracker.recordSuccess = recordSuccess
    tracker.isLockedOut = isLockedOut
    tracker.onFailureEvent = onFailureEvent
    tracker.clear = function() end
    tracker.failed = false
    tracker.activeSpell = nil
    tracker.lastSpell = nil
    tracker.wasCasting = false

    return tracker
end

local function clearCursor()
    local item = mq.TLO.Cursor
    if not item() or (item.ID() or 0) <= 0 then return false end
    pcall(function()
        local count = 0
        while (mq.TLO.Cursor.ID() or 0) > 0 and count < 255 do
            mq.cmd('/autoinventory')
            mq.delay(50)
            count = count + 1
        end
    end)
    return true
end

local function lookupSpells(abbr)
    if not abbr or not DATA.spells then return {} end
    if DATA.spells[abbr] then return DATA.spells[abbr] end

    local u = abbr:upper()
    if DATA.spells[u] then return DATA.spells[u] end

    local titleCase = u:sub(1, 1) .. u:sub(2):lower()
    if DATA.spells[titleCase] then return DATA.spells[titleCase] end

    local alt = D.ALIAS_CLASS_MAP[u] or D.ALIAS_CLASS_MAP[abbr]
    if alt and DATA.spells[alt] then return DATA.spells[alt] end
    if alt then
        local altTitle = alt:sub(1, 1):upper() .. alt:sub(2):lower()
        if DATA.spells[altTitle] then return DATA.spells[altTitle] end
    end

    for k, v in pairs(DATA.spells) do
        if type(k) == 'string' and k:upper() == u then
            return v
        end
    end
    return {}
end


local function isDisciplineSpell(abbr, spellName)
    if not abbr or not spellName or spellName == "" then return false end
    if D.PURE_MELEE_CLASSES[abbr] or D.PURE_MELEE_CLASSES[abbr:upper()] then return true end

    if DATA and DATA.discs then
        local alt = D.ALIAS_CLASS_MAP[abbr:upper()] or abbr
        local discList = DATA.discs[abbr] or DATA.discs[abbr:upper()] or DATA.discs[alt]
        if discList then
            for _, row in ipairs(discList) do
                if row[1] == spellName or row[1]:lower() == spellName:lower() then
                    return true
                end
            end
        end
    end

    local isSkill = false
    pcall(function()
        local spObj = mq.TLO.Spell(spellName)
        if spObj() and spObj.IsSkill() then
            isSkill = true
        end
    end)
    if isSkill then return true end

    return isDiscKnown(spellName)
end

local function checkHasSPA(tloSpell, name, sp, spaId)
    local hasIt = false
    pcall(function()
        if tloSpell then
            local res = tloSpell.HasSPA(spaId)
            if res == true or res == 1 then hasIt = true end
            if not hasIt and (type(res) == 'function' or type(res) == 'userdata') then
                local ok, r2 = pcall(res) ---@diagnostic disable-line: param-type-mismatch
                if ok and (r2 == true or r2 == 1) then hasIt = true end
            end
        end
    end)
    if not hasIt and sp and sp.ID and sp.ID() > 0 then
        pcall(function()
            local res = mq.TLO.Spell(sp.ID()).HasSPA(spaId)
            if res == true or res == 1 then hasIt = true end
            if not hasIt and (type(res) == 'function' or type(res) == 'userdata') then
                local ok, r2 = pcall(res) ---@diagnostic disable-line: param-type-mismatch
                if ok and (r2 == true or r2 == 1) then hasIt = true end
            end
        end)
    end
    if not hasIt and name and name ~= "" then
        pcall(function()
            local res = mq.TLO.Spell(name).HasSPA(spaId)
            if res == true or res == 1 then hasIt = true end
            if not hasIt and (type(res) == 'function' or type(res) == 'userdata') then
                local ok, r2 = pcall(res) ---@diagnostic disable-line: param-type-mismatch
                if ok and (r2 == true or r2 == 1) then hasIt = true end
            end
        end)
    end
    return hasIt
end

local function mapTLOCategoryToKind(sp, name)
    if not sp and not name then return 'other' end

    -- VF: Extract Spell TLO via ID first (most reliable in MQ).
    local tloSpell = nil
    pcall(function()
        if sp and sp.ID and sp.ID() > 0 then
            tloSpell = mq.TLO.Spell(sp.ID())
        end
    end)
    if not tloSpell and name and name ~= "" then
        pcall(function()
            tloSpell = mq.TLO.Spell(name)
        end)
    end
    if not tloSpell and name and name ~= "" then
        pcall(function()
            local cl = U.cleanSpellName(name)
            if cl ~= name then tloSpell = mq.TLO.Spell(cl) end
        end)
    end
    if not tloSpell and type(sp) == 'userdata' then
        tloSpell = sp
    end

    -- VF: 1.
    local catStr = ""
    local subcatStr = ""

    pcall(function()
        if tloSpell then
            local c = tloSpell.Category
            if c then catStr = tostring(c() or c.Name() or c):lower() end
            local sc = tloSpell.Subcategory
            if sc then subcatStr = tostring(sc() or sc.Name() or sc):lower() end
        end
    end)

    if (catStr == "" or catStr == "nil") and sp then
        pcall(function()
            local c = sp.Category
            if c then catStr = tostring(c() or c.Name() or c):lower() end
            local sc = sp.Subcategory
            if sc then subcatStr = tostring(sc() or sc.Name() or sc):lower() end
        end)
    end

    local nmLower = name and name:lower() or ""

    -- VF: Check specific pet subcategories/categories, pet spell names, or pet buff spells (e.g.
    if subcatStr:find('pet') or (catStr:find('pet') and not catStr:find('utility'))
        or subcatStr:find('burnout') or nmLower:find('burnout')
        or nmLower:find('elemental') or nmLower:find('companion') or nmLower:find('minion') or nmLower:find('servant')
        or subcatStr:find('companion') or catStr:find('companion') or subcatStr:find('minion') or catStr:find('minion') then
        return 'pet'
    end

    -- VF: Extract Beneficial status early.
    local bene = true
    pcall(function()
        if tloSpell then
            local b = tloSpell.Beneficial
            if type(b) == 'function' or type(b) == 'userdata' then bene = b() or false else bene = b or false end
        elseif sp then
            local b = sp.Beneficial
            if type(b) == 'function' or type(b) == 'userdata' then bene = b() or false else bene = b or false end
        end
    end)

    -- VF: Check player buffs / damage shields / haste spells (Celerity, Alacrity, Haste, Swift, Shield of Lava, etc.).
    if bene then
        if catStr:find('buff') or catStr:find('stat') or catStr:find('resist') or catStr:find('shield')
            or subcatStr:find('buff') or catStr:find('aura') or subcatStr:find('aura') or subcatStr:find('shield')
            or subcatStr:find('haste') or catStr:find('haste')
            or nmLower:find('shield') or nmLower:find('celerity') or nmLower:find('alacrity') or nmLower:find('haste') or nmLower:find('swift') then
            return 'buff'
        end
    end

    -- VF: Debuff Check for resist debuffs (Mala, Malo, Malosi, Tash, etc.).
    if not bene then
        if catStr:find('debuff') or subcatStr:find('debuff') or catStr:find('slow') or subcatStr:find('slow')
            or catStr:find('dispel') or subcatStr:find('dispel') or catStr:find('blind') or subcatStr:find('blind')
            or nmLower:find('mala') or nmLower:find('malo') or nmLower:find('tash') or nmLower:find('incapacitate') or nmLower:find('listless') or nmLower:find('disempower') then
            return 'debuff'
        end
    end

    -- VF: Utility Check (Gate, Bind Affinity, Invisibility, Camouflage, Teleports, Illusions, Item Summons).
    if nmLower:find('gate') or nmLower:find('bind affinity') or nmLower:find('invisib') or nmLower:find('camouflage') or nmLower:find('translocate')
        or catStr:find('transport') or catStr:find('travel') or catStr:find('teleport') or catStr:find('gate') or catStr:find('illusion') or catStr:find('invis')
        or subcatStr:find('transport') or subcatStr:find('travel') or subcatStr:find('teleport') or subcatStr:find('gate') or subcatStr:find('illusion') or subcatStr:find('invis')
        or (catStr:find('utility') and not catStr:find('debuff')) or (subcatStr:find('utility') and not subcatStr:find('debuff')) then
        return 'util'
    end

    -- VF: 2.
    if checkHasSPA(tloSpell, name, sp, 103) then return 'pet' end
    if checkHasSPA(tloSpell, name, sp, 32) or checkHasSPA(tloSpell, name, sp, 108) or checkHasSPA(tloSpell, name, sp, 33) then
        return
        'util'
    end
    if checkHasSPA(tloSpell, name, sp, 83) or checkHasSPA(tloSpell, name, sp, 88) or checkHasSPA(tloSpell, name, sp, 12) or checkHasSPA(tloSpell, name, sp, 41) or checkHasSPA(tloSpell, name, sp, 29) or checkHasSPA(tloSpell, name, sp, 30) then
        return
        'util'
    end
    if checkHasSPA(tloSpell, name, sp, 81) or checkHasSPA(tloSpell, name, sp, 91) then return 'util' end
    if checkHasSPA(tloSpell, name, sp, 18) or checkHasSPA(tloSpell, name, sp, 22) or checkHasSPA(tloSpell, name, sp, 31) then
        return
        'util'
    end
    if not bene then
        if checkHasSPA(tloSpell, name, sp, 11) or checkHasSPA(tloSpell, name, sp, 46) or checkHasSPA(tloSpell, name, sp, 23)
            or checkHasSPA(tloSpell, name, sp, 4) or checkHasSPA(tloSpell, name, sp, 5) or checkHasSPA(tloSpell, name, sp, 6) or checkHasSPA(tloSpell, name, sp, 7) then
            return 'debuff'
        end
    end

    -- VF: 3. Duration heals are HoT (buff-bar), not click heals ? Ethereal Cleansing etc.
    if catStr:find('heal') or subcatStr:find('heal') or catStr:find('restore') or subcatStr:find('restore')
        or catStr:find('heal over') or subcatStr:find('heal over') or catStr:find('hot') or subcatStr:find('hot') then
        local dur = 0
        pcall(function()
            if tloSpell then dur = tonumber(tloSpell.Duration()) or 0 end
        end)
        if dur > 0 or catStr:find('heal over') or subcatStr:find('heal over')
            or catStr:find('hot') or subcatStr:find('hot') or nmLower:find('heal over') then
            return 'buff'
        end
        return 'heal'
    elseif catStr:find('dot') or catStr:find('damage over time') or subcatStr:find('dot') or subcatStr:find('damage over time') then
        return 'dot'
    elseif catStr:find('direct damage') or catStr:find('nuke') or catStr:find('dd') or subcatStr:find('direct damage') or subcatStr:find('nuke') or catStr:find('lifetap') or subcatStr:find('lifetap') or nmLower:find('lifetap') or nmLower:find('lifedraw') or nmLower:find('lifespike') or nmLower:find('siphon life') or nmLower:find('drain') then
        return 'dd'
    elseif catStr:find('debuff') or subcatStr:find('debuff') or catStr:find('slow') or subcatStr:find('slow') or catStr:find('dispel') or subcatStr:find('dispel') or catStr:find('blind') or subcatStr:find('blind') or nmLower:find('incapacitate') or nmLower:find('listless') or nmLower:find('disempower') then
        return 'debuff'
    elseif bene or catStr:find('buff') or catStr:find('stat') or catStr:find('resist') or catStr:find('shield') or subcatStr:find('buff') or catStr:find('aura') or subcatStr:find('aura') or subcatStr:find('shield') or nmLower:find('spirit of wolf') or nmLower:find('sow') then
        return 'buff'
    elseif catStr:find('transport') or catStr:find('travel') or catStr:find('utility') or catStr:find('misc') or catStr:find('teleport') or catStr:find('gate') or catStr:find('illusion') or catStr:find('summon') or subcatStr:find('summon') then
        return 'util'
    end

    if bene then
        return 'buff'
    else
        return 'dd'
    end
end

local function spellClassInfo(name)
    for _, abbr in ipairs(myClasses) do
        if not D.PURE_MELEE_CLASSES[abbr] and not D.PURE_MELEE_CLASSES[abbr:upper()] then
            local list = lookupSpells(abbr)
            if list then
                for _, it in ipairs(list) do
                    if it[1] == name and not isDisciplineSpell(abbr, name) then
                        local kind = mapTLOCategoryToKind(nil, name)
                        if not kind or kind == 'other' then kind = it[4] or 'other' end
                        return abbr, (it[3] == 1), kind
                    end
                end
            end
        end
    end
    local fallbackKind = mapTLOCategoryToKind(nil, name)
    return myClasses[1] or 'War', true, fallbackKind
end

-- VF: copy the live gem bar into the loadout. Does not remem.
local function importCurrentGems(targetGemsTable)
    targetGemsTable = targetGemsTable or loadout.gems
    for i = 1, D.NUM_GEMS do
        local nm
        pcall(function() nm = mq.TLO.Me.Gem(i).Name() end)
        if nm and nm ~= '' and nm ~= 'NULL' then
            local cls, bene, kind = spellClassInfo(nm)
            local tgt, wn, pc = U.defaultsForKind(kind, bene)
            targetGemsTable[i] = { cls = cls, spell = nm, target = tgt, when = wn, pct = pc }
        else
            targetGemsTable[i] = nil
        end
    end
end

-- VF: bar drives active gems; spell_gates rebinds known prefs. Empty bar leaves planned slots alone.
local function checkGemMemSync()
    local now = os.clock()
    if (now - (runtime.lastGemSyncCheckAt or 0)) < 1.0 then return end
    runtime.lastGemSyncCheckAt = now
    runtime.gemSyncWarned = runtime.gemSyncWarned or {}
    if mq.TLO.Window('SpellBookWnd').Open() then return end
    loadout.spell_gates = loadout.spell_gates or {}
    local function rememberGate(g)
        if type(g) ~= 'table' or not g.spell or g.spell == '' then return end
        local key = U.normalizeSpellName(g.spell)
        if key == '' then return end
        local copy = {}
        for k, v in pairs(g) do copy[k] = v end
        loadout.spell_gates[key] = copy
    end
    for i = 1, D.NUM_GEMS do
        rememberGate(loadout.gems[i])
    end
    local S
    pcall(function() S = require('vft.mgr.schema') end)
    local rebound = 0
    for i = 1, D.NUM_GEMS do
        local memmed
        pcall(function() memmed = mq.TLO.Me.Gem(i).Name() end)
        local g = loadout.gems[i]
        -- VF: empty gem -- keep loadout row (planned mem / post-zone).
        if memmed and memmed ~= '' and memmed ~= 'NULL' then
            local matched = g and g.spell and g.spell ~= '' and isGemMatching(i, g.spell)
            if matched then
                runtime.gemSyncWarned[i] = nil
            else
                local existing
                if S and S.lookupSpellGate then
                    existing = S.lookupSpellGate(loadout.spell_gates, loadout.gems, memmed)
                else
                    local key = U.normalizeSpellName(memmed)
                    existing = key ~= '' and loadout.spell_gates[key] or nil
                end
                if type(existing) == 'table' then
                    rememberGate(g)
                    local copy = {}
                    for k, v in pairs(existing) do copy[k] = v end
                    copy.spell = memmed
                    loadout.gems[i] = copy
                    rememberGate(copy)
                    runtime.gemSyncWarned[i] = nil
                    rebound = rebound + 1
                elseif not runtime.gemSyncWarned[i] then
                    runtime.gemSyncWarned[i] = true
                    local was = (g and g.spell) or '(none)'
                    print(string.format(
                        '\ay[VF]\ax gem %d has "%s" memmed (was "%s") but no saved gates -- open Mgr Spells and Save once for this spell.',
                        i, memmed, was))
                end
            end
        end
    end
    if rebound > 0 then
        print(string.format('\ag[VF]\ax gem bar: applied known configs to %d slot(s).', rebound))
    end
end

local function collectEntry()
    return {
        classes = myClasses,
        lvlMin = lvlMin,
        lvlMax = lvlMax,
        gems = loadout.gems,
        spell_gates = loadout.spell_gates,
        aas = loadout.aas,
        discs = loadout.discs,
        items = loadout.items,
        off_limit = loadout.off_limit,
        filters = loadout.filters,
        waypoints = loadout.waypoints,
        aa_queue = loadout.aa_queue,
        aa_book = loadout.aa_book,
        control = ctrl
    }
end
local function applyEntry(e)
    if type(e) ~= 'table' then return end
    pcall(function() e = require('vft.mgr.schema').migrateEntry(e) end)
    if type(e.classes) == 'table' and #e.classes > 0 then myClasses = e.classes end
    lvlMin = e.lvlMin or lvlMin; lvlMax = e.lvlMax or lvlMax
    loadout.gems = e.gems or {}
    loadout.spell_gates = e.spell_gates or {}
    loadout.off_limit = tonumber(e.off_limit or e.t3_off_limit)
    loadout.aas  = {}
    if type(e.aas) == 'table' then
        for k, v in pairs(e.aas) do
            if not tonumber(k) and type(v) == 'table' then
                loadout.aas[U.trimName(k)] = v
            end
        end
    end
    loadout.discs = e.discs or {}
    loadout.items = {}
    if type(e.items) == 'table' then
        for k, v in pairs(e.items) do
            if not tonumber(k) and type(v) == 'table' then
                local rec = v
                rec.via = 'item'
                loadout.items[U.trimName(k)] = rec
            end
        end
    end
    loadout.filters = e.filters or e.t3_filters
    loadout.waypoints = e.waypoints
    loadout.aa_queue = runtime.copyAaQueue(e.aa_queue)
    loadout.aa_book = nil
    pcall(function()
        loadout.aa_book = require('vft.mgr.schema').copyAaBook(e.aa_book)
    end)
    if type(e.control) == 'table' then
        for k, v in pairs(e.control) do ctrl[k] = v end
        sanitizeModeConfig()
        -- VF: Burn/Boost are session-only (Mini / /vf burn|boost); never restore from disk.
        ctrl.burn = false
        ctrl.boost = false
        -- VF: old-dev: pre-3.6 use_melee/use_ranged -> combat_style.
        if not e.control.combat_style then
            ctrl.combat_style = e.control.use_ranged and 'Ranged' or 'Melee'
        end
        -- VF: a saved 'Spell' has no combatTick branch and would disable engaging.
        if ctrl.combat_style ~= 'Ranged' then ctrl.combat_style = 'Melee' end
        -- VF: resting used to come off min_mana_pct (the cast floor). Seed once so an
        -- VF: existing character keeps resting instead of silently stopping.
        if ctrl.rest_mana_pct == nil then
            ctrl.rest_mana_pct = tonumber(ctrl.min_mana_pct) or 0
        end
        -- VF: pulling is ranged-only now; a saved 'Melee' pull meant "no stand back".
        if ctrl.pull_style == 'Melee' then
            ctrl.pull_style = 'Spell'
            ctrl.pull_stand_back = false
        end
        if ctrl.melee_dist == nil then ctrl.melee_dist = 14 end
        ctrl.stick_manage = nil
        if ctrl.stick_position == nil then ctrl.stick_position = 'Any' end
        if ctrl.stick_handoff == nil then ctrl.stick_handoff = runtime.STICK_HANDOFF or 120 end
        if ctrl.hunter_z_plane == nil then ctrl.hunter_z_plane = 15 end
        if ctrl.hunter_z == nil then ctrl.hunter_z = 75 end
        ctrl.maintain_buffs = true
        ctrl.hud = 'mini'
        if ctrl.hunter_level_rel == nil then ctrl.hunter_level_rel = true end
        if ctrl.hunter_rel_min == nil then ctrl.hunter_rel_min = 0 end
        if ctrl.hunter_rel_max == nil then ctrl.hunter_rel_max = 5 end
        -- VF: never restore a saved camp anchor. See docs/ANCHOR.md.
        ctrl.camp_loc = nil
        if runtime.applyZoneRoute then runtime.applyZoneRoute() end
        -- VF: Same reasoning, and nothing re-applies this one.
        ctrl.hunter_combat_loc = nil
        -- VF: Group Anchor is zone-local; re-stamp with the checkbox after zone.
        ctrl.group_anchor_loc = nil
        -- VF: Puller waypoint patrol is gone.
        ctrl.use_waypoints = nil
        ctrl.waypoints = nil
        ctrl.waypoint_radius = nil
        ctrl.waypoint_scan_radius = nil
        ctrl.waypoint_direction = nil
        ctrl.current_waypoint_idx = nil
    end
end

function runtime.copyAaQueue(src)
    local q = { items = {}, auto = true }
    if type(src) ~= 'table' then return q end
    if src.auto == false then q.auto = false end
    local function add(name, gid)
        name = U.trimName(tostring(name or ''))
        gid = tonumber(gid)
        if name == '' or name == 'NULL' then return end
        for _, it in ipairs(q.items) do
            if (gid and it.gid and it.gid == gid) or it.name == name then return end
        end
        q.items[#q.items + 1] = { name = name, gid = gid }
    end
    if type(src.items) == 'table' then
        for _, it in ipairs(src.items) do
            if type(it) == 'table' then
                add(it.name, it.gid)
            elseif type(it) == 'string' then
                add(it)
            end
        end
    elseif type(src.names) == 'table' then
        for i, name in ipairs(src.names) do
            add(name, type(src.gids) == 'table' and src.gids[i] or nil)
        end
    else
        for _, name in ipairs(src) do
            if type(name) == 'string' then add(name) end
        end
    end
    return q
end

function runtime.fileKey(s)
    s = tostring(s or ''):gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    if s == '' then return 'unknown' end
    return s
end

function runtime.serverKey()
    local s = ''
    pcall(function()
        s = tostring(mq.TLO.EverQuest.Server() or '')
        if s == '' or s == 'NULL' then
            s = tostring(mq.TLO.MacroQuest.Server() or '')
        end
    end)
    if s == 'NULL' then s = '' end
    s = runtime.fileKey(s)
    if s == 'unknown' then s = 'local' end
    return s
end

function runtime.loadoutPath(name)
    name = name or myName or 'unknown'
    return cfg .. '/' .. runtime.serverKey() .. '_' .. runtime.fileKey(name) .. '.lua'
end

local function unwrapEntry(t, name)
    local e = t
    pcall(function()
        local S = require('vft.mgr.schema')
        if type(t.gems) == 'table' or type(t.control) == 'table' or type(t.aas) == 'table' then
            e = S.migrateEntry(t)
            return
        end
        if name and type(t[name]) == 'table' then
            e = S.migrateEntry(t[name])
            if type(t.__ignore) == 'table' and e.ignore == nil then e.ignore = t.__ignore end
            if type(t.__pullList) == 'table' and e.pull == nil then e.pull = t.__pullList end
            return
        end
        e = S.migrateEntry(t)
    end)
    return e
end

local function saveLoadout(silent)
    if not myName then return end
    -- VF: Burn/Boost are session-only ? never persist true to disk.
    local wasBurn, wasBoost = ctrl.burn, ctrl.boost
    ctrl.burn = false
    ctrl.boost = false
    local e = collectEntry()
    ctrl.burn = wasBurn
    ctrl.boost = wasBoost
    pcall(function() e = require('vft.mgr.schema').migrateEntry(e) end)
    e.ignore = runtime.ignoreList
    e.pull = runtime.pullList
    runtime.allData[myName] = e
    local path = runtime.loadoutPath(myName)
    local ok, err = U.writeTable(path, e, 'return ')
    if not ok then
        print('\ar[VF]\ax save FAILED, loadout on disk untouched: ' .. tostring(err))
        return false
    end
    if not silent then print('\ag[VF]\ax saved ' .. path) end
    return true
end

local function loadAll()
    if not myName then return end
    local path = runtime.loadoutPath(myName)
    local fn = loadfile(path)
    local fromLegacy = false
    if not fn then
        fn = loadfile(cfg .. '/t2_loadout.lua') or loadfile(cfg .. '/triune_loadout.lua')
        fromLegacy = fn ~= nil
    end
    if not fn then return end
    local ok, t = pcall(fn)
    if not (ok and type(t) == 'table') then return end
    local e = unwrapEntry(t, myName)
    if type(e) ~= 'table' then return end
    runtime.allData[myName] = e
    if type(e.ignore) == 'table' then runtime.ignoreList = e.ignore end
    if type(e.pull) == 'table' then runtime.pullList = e.pull end
    if fromLegacy then
        runtime.needMigrateSave = true
        print('\ag[VF]\ax will write migrated loadout to ' .. path)
    end
end

-- VF: ignore list blocks auto-target and isHostileTarget (/attack).
local function isIgnored(name)
    if not name then return false end
    local cleanName = tostring(name)
    if cleanName == '' then return false end
    if not runtime.ignoreList then return false end
    for _, n in ipairs(runtime.ignoreList) do
        if tostring(n) == cleanName then return true end
    end
    return false
end
local function addIgnore(name)
    if not name or name == '' or isIgnored(name) then return end
    table.insert(runtime.ignoreList, name)
    table.sort(runtime.ignoreList)
    saveLoadout(true)
    print('\ag[VF]\ax added to ignore list: ' .. name)
end
local function removeIgnore(name)
    for i, n in ipairs(runtime.ignoreList) do
        if n == name then
            table.remove(runtime.ignoreList, i); break
        end
    end
    saveLoadout(true)
    print('\ag[VF]\ax removed from ignore list: ' .. name)
end

-- VF: pull-list (include-list) helpers for Puller mode:.
local function isPullListed(name)
    if not name or name == '' then return false end
    for _, n in ipairs(runtime.pullList) do if n == name then return true end end
    return false
end
local function addPull(name)
    if not name or name == '' or isPullListed(name) then return end
    table.insert(runtime.pullList, name)
    table.sort(runtime.pullList)
    saveLoadout(true)
    print('\ag[VF]\ax added to pull list: ' .. name)
end
local function removePull(name)
    for i, n in ipairs(runtime.pullList) do
        if n == name then
            table.remove(runtime.pullList, i); break
        end
    end
    saveLoadout(true)
    print('\ag[VF]\ax removed from pull list: ' .. name)
end

-- VF: shared hub ShortNames -- no auto-target. Mgr Zones tab / config/ta_safe_zones.lua.
runtime.safeZones = runtime.safeZones or {}
runtime.reloadSafeZones = function()
    local list = {}
    pcall(function()
        local IO = require('vft.mgr.io')
        list = IO.loadSafeZones()
    end)
    if type(list) ~= 'table' or #list == 0 then
        pcall(function()
            list = require('vft.mgr.schema').copySafeZones(
                require('vft.mgr.schema').defaultSafeZones())
        end)
    end
    runtime.safeZones = type(list) == 'table' and list or {}
    runtime.safeZonesAt = os.clock()
    return runtime.safeZones
end
runtime.isSafeZone = function(short)
    short = tostring(short or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    if short == '' or short == 'null' then return false end
    local list = runtime.safeZones
    if type(list) ~= 'table' then return false end
    for _, z in ipairs(list) do
        if tostring(z):lower() == short then return true end
    end
    return false
end
runtime.inSafeZone = function()
    local short = ''
    pcall(function() short = tostring(mq.TLO.Zone.ShortName() or '') end)
    return runtime.isSafeZone(short)
end
runtime.reloadSafeZones()

local function isPullAllowed(name)
    if not name then return false end
    local cleanName = tostring(name)
    if cleanName == '' then return false end
    if isIgnored(cleanName) then return false end
    if not runtime.pullList or #runtime.pullList == 0 then return true end
    for _, n in ipairs(runtime.pullList) do
        local strN = tostring(n)
        if strN ~= '' and (cleanName == strN or cleanName:find(strN, 1, true)) then
            return true
        end
    end
    return false
end

function runtime.extractConName(line)
    if not line or line == '' then return nil end
    local name = line:match('^(.-)%s+scowls')
        or line:match('^(.-)%s+glares')
        or line:match('^(.-)%s+glowers')
        or line:match('^(.-)%s+looks')
        or line:match('^(.-)%s+regards')
        or line:match('^(.-)%s+judges')
        or line:match('^(.-)%s+judge')
    if name then
        name = name:gsub('^%s*(.-)%s*$', '%1')
        if name ~= '' then return name end
    end
    return nil
end

function runtime.recordTargetCon(tier, line)
    runtime.conCache = runtime.conCache or {}
    local tgtName = mq.TLO.Target.CleanName()
    if not tgtName or tgtName == '' then
        tgtName = runtime.extractConName(line)
    end
    if not tgtName or tgtName == '' or not tier then return end
    runtime.conCache[tgtName] = tier
    if ctrl and ctrl.debug_mode then
        print(string.format('\ag[VF]\ax Captured faction consideration for "%s": %s', tgtName, tier))
    end
end

mq.event('TriuneConScowl', '#*#scowls#*#', function(line) runtime.recordTargetCon('Scowling', line) end)
mq.event('TriuneConThreat', '#*#threateningly#*#', function(line) runtime.recordTargetCon('Threateningly', line) end)
mq.event('TriuneConDubious', '#*#dubiously#*#', function(line) runtime.recordTargetCon('Dubious', line) end)
mq.event('TriuneConApprehens', '#*#apprehensively#*#', function(line) runtime.recordTargetCon('Apprehensive', line) end)
mq.event('TriuneConIndiff', '#*#indifferently#*#', function(line) runtime.recordTargetCon('Indifferent', line) end)
mq.event('TriuneConAmiable', '#*#amiably#*#', function(line) runtime.recordTargetCon('Amiably', line) end)
mq.event('TriuneConKindly', '#*#kindly#*#', function(line) runtime.recordTargetCon('Kindly', line) end)
mq.event('TriuneConWarmly', '#*#warmly#*#', function(line) runtime.recordTargetCon('Warmly', line) end)
mq.event('TriuneConAlly', '#*#an ally#*#', function(line) runtime.recordTargetCon('Ally', line) end)

runtime.conFilterTable = function()
    local f = loadout.filters
    if type(f) == 'table' and type(f.zones) == 'table' then
        local short = ''
        pcall(function()
            short = tostring(mq.TLO.Zone.ShortName() or '')
        end)
        if short == 'NULL' then short = '' end
        local pack = (short ~= '') and f.zones[short]
        if type(pack) == 'table' and type(pack.cons) == 'table' then
            return pack.cons
        end
    end
    return ctrl and ctrl.pull_con_filter
end

local function isConAllowed(s)
    if not s or not s() then return false end
    local cons = runtime.conFilterTable and runtime.conFilterTable()
    if type(cons) ~= 'table' then return true end

    local cname = nil
    local okName, nameVal = pcall(function() return s.CleanName() end)
    if okName and nameVal and nameVal ~= '' then
        cname = nameVal
    end

    -- VF: 1.
    if cname and runtime.conCache and runtime.conCache[cname] then
        local cachedTier = runtime.conCache[cname]
        if cons[cachedTier] == false then
            return false
        end
    end

    -- VF: 2.
    return true
end

function runtime.verifyTargetCon(id, blockUntilCached)
    if not id or id <= 0 then return true end
    if runtime.spawnWantsFight and runtime.spawnWantsFight(id) then return true end

    local tgt = mq.TLO.Target
    if not tgt() or (tgt.ID() or 0) ~= id then return true end

    local cname = tgt.CleanName()
    if not cname or cname == '' then return true end

    runtime.conCache = runtime.conCache or {}
    if not runtime.conCache[cname] then
        mq.cmd('/consider')
        if blockUntilCached then
            local waited = 0
            while waited < 400 do
                mq.delay(20)
                mq.doevents()
                waited = waited + 20
                if runtime.conCache[cname] then break end
            end
        else
            mq.doevents()
        end
    end

    local cachedTier = runtime.conCache[cname]
    local cons = runtime.conFilterTable and runtime.conFilterTable()
    if cachedTier and type(cons) == 'table' then
        if cons[cachedTier] == false then
            return false
        end
    end

    return true
end

-- VF: lightweight signature of the loadout, for auto-save change detection.
local function loadoutSig()
    local p = { table.concat(myClasses or {}, ','), tostring(lvlMin), tostring(lvlMax) }
    for i = 1, D.NUM_GEMS do
        local g = loadout.gems and loadout.gems[i]
        if type(g) == 'table' then
            p[#p + 1] = tostring(i) ..
                '~' ..
                tostring(g.enabled) ..
                '~' ..
                tostring(g.spell) ..
                '~' ..
                tostring(g.target) ..
                '~' ..
                tostring(g.when) ..
                '~' ..
                tostring(g.pct) ..
                '~' ..
                tostring(g.above) ..
                '~' ..
                tostring(g.boss_only) ..
                '~' .. tostring(g.burn_only) .. '~' .. tostring(g.priority) .. '~' .. tostring(g.max_xtargets)
                .. '~' .. tostring(g.min_xtar)
                .. '~' .. tostring(g.ooc_heal)
                .. '~' .. tostring(g.combat or g.t3_combat)
        end
    end
    p[#p + 1] = 'offlim~' .. tostring(loadout.off_limit)
    do
        local gkeys = {}
        if loadout.spell_gates then
            for k in pairs(loadout.spell_gates) do gkeys[#gkeys + 1] = k end
        end
        table.sort(gkeys)
        for _, nm in ipairs(gkeys) do
            local g = loadout.spell_gates[nm]
            if type(g) == 'table' then
                p[#p + 1] = 'sg~' .. nm .. '~' .. tostring(g.pct) .. '~' .. tostring(g.cast_type or g.t3_type)
                    .. '~' .. tostring(g.priority) .. '~' .. tostring(g.combat or g.t3_combat)
            end
        end
    end
    local akeys = {}
    if loadout.aas then for k in pairs(loadout.aas) do akeys[#akeys + 1] = k end end
    table.sort(akeys)
    for _, nm in ipairs(akeys) do
        local a = loadout.aas[nm]
        if type(a) == 'table' then
            p[#p + 1] = nm ..
                '~' ..
                tostring(a.enabled) .. '~' .. tostring(a.target) .. '~' .. tostring(a.when) .. '~' .. tostring(a.pct)
                .. '~' .. tostring(a.boss_only) .. '~' .. tostring(a.burn_only) .. '~' .. tostring(a.priority)
                .. '~' .. tostring(a.ooc_heal)
                .. '~' .. tostring(a.combat or a.t3_combat)
        end
    end
    local dkeys = {}
    if loadout.discs then for k in pairs(loadout.discs) do dkeys[#dkeys + 1] = k end end
    table.sort(dkeys)
    for _, nm in ipairs(dkeys) do
        local d = loadout.discs and loadout.discs[nm]
        if type(d) == 'table' then
            p[#p + 1] = nm ..
                '~' ..
                tostring(d.enabled) .. '~' .. tostring(d.target) .. '~' .. tostring(d.when) .. '~' .. tostring(d.pct)
                .. '~' .. tostring(d.boss_only) .. '~' .. tostring(d.burn_only) .. '~' .. tostring(d.priority)
                .. '~' .. tostring(d.ooc_heal)
                .. '~' .. tostring(d.combat or d.t3_combat)
        end
    end
    local ikeys = {}
    if loadout.items then for k in pairs(loadout.items) do ikeys[#ikeys + 1] = k end end
    table.sort(ikeys)
    for _, nm in ipairs(ikeys) do
        local it = loadout.items[nm]
        if type(it) == 'table' then
            p[#p + 1] = 'it~' .. nm ..
                '~' .. tostring(it.enabled) .. '~' .. tostring(it.spell) .. '~' .. tostring(it.target)
                .. '~' .. tostring(it.when) .. '~' .. tostring(it.pct)
                .. '~' .. tostring(it.burn_only) .. '~' .. tostring(it.combat or it.t3_combat)
        end
    end
    local ckeys = {}
    if ctrl then for k in pairs(ctrl) do ckeys[#ckeys + 1] = k end end
    table.sort(ckeys)
    local ctrlParts = {}
    for _, k in ipairs(ckeys) do
        if k ~= 'current_waypoint_idx' and k ~= 'waypoint_direction' and k ~= 'waypoints'
            and k ~= 'use_waypoints' and k ~= 'waypoint_radius' and k ~= 'waypoint_scan_radius' then
            local v = ctrl[k]
            if type(v) == 'table' then
                if k == 'camp_loc' or k == 'hunter_combat_loc' then
                    ctrlParts[#ctrlParts + 1] = string.format('%s=%.1f,%.1f,%.1f', k, v.x or 0, v.y or 0, v.z or 0)
                elseif k == 'pull_con_filter' then
                    local conStr = {}
                    for ck, cv in pairs(v) do conStr[#conStr + 1] = ck .. '=' .. tostring(cv) end
                    table.sort(conStr)
                    ctrlParts[#ctrlParts + 1] = 'pull_con_filter:' .. table.concat(conStr, ',')
                end
            else
                ctrlParts[#ctrlParts + 1] = string.format('%s=%s', k, tostring(v))
            end
        end
    end
    p[#p + 1] = table.concat(ctrlParts, '~')
    local aq = loadout.aa_queue
    if type(aq) == 'table' then
        local qn = { tostring(aq.auto ~= false) }
        if type(aq.items) == 'table' then
            for _, it in ipairs(aq.items) do
                qn[#qn + 1] = tostring(it.name or '') .. ':' .. tostring(it.gid or '')
            end
        end
        p[#p + 1] = 'aaq:' .. table.concat(qn, ',')
    end
    local ab = loadout.aa_book
    if type(ab) == 'table' then
        p[#p + 1] = 'aab:' .. tostring(ab.at or 0) .. ':' .. tostring(ab.purchased and #ab.purchased or 0)
            .. ':' .. tostring(ab.unpurchased and #ab.unpurchased or 0)
    end
    if runtime.ignoreList then p[#p + 1] = 'ignore:' .. table.concat(runtime.ignoreList, ',') end
    if runtime.pullList then p[#p + 1] = 'pull:' .. table.concat(runtime.pullList, ',') end
    return table.concat(p, '|')
end

-- VF: Manager wrote disk; re-read without dropping session burn/boost/running.
function runtime.reloadLoadout(silent)
    if not myName then return false end
    local wasBurn, wasBoost, wasRunning = ctrl.burn, ctrl.boost, ctrl.running
    loadAll()
    local e = runtime.allData[myName]
    if type(e) ~= 'table' then
        if not silent then print('\ay[VF]\ax reloadloadout: no entry for ' .. tostring(myName)) end
        return false
    end
    applyEntry(e)
    ctrl.burn = wasBurn
    ctrl.boost = wasBoost
    ctrl.running = wasRunning
    runtime.lastSig = loadoutSig()
    runtime.autoDirty = false
    pcall(runtime.stickPush)
    if not silent then print('\ag[VF]\ax loadout reloaded from disk.') end
    return true
end

-- VF: validate a saved class slot. detectClasses used to hardcode Rng/Brd -- that is old-dev.

-- VF: character change: load save or detect classes.
local function onCharacterChanged()
    loadAll()
    -- VF: mutate in place ? modules hold loadout/ctrl refs from install.
    loadout.gems, loadout.aas, loadout.discs, loadout.items, loadout.spell_gates = {}, {}, {}, {}, {}
    loadout.off_limit, loadout.filters, loadout.waypoints = nil, nil, nil
    loadout.aa_queue, loadout.aa_book = nil, nil
    local fresh = defaultCtrl()
    for k in pairs(ctrl) do ctrl[k] = nil end
    for k, v in pairs(fresh) do ctrl[k] = v end
    -- VF: new toon means a new {server}_{char}.ini, so the AA sync cache is stale
    if runtime.aaSpendReset then runtime.aaSpendReset() end
    if runtime.meleeReset then runtime.meleeReset() end
    if runtime.groupModeReset then runtime.groupModeReset() end
    if runtime.buffSessionClear then runtime.buffSessionClear() end
    runtime.sungBuffs = {}
    runtime.buffTries = {}
    runtime.pullState = 'IDLE'; runtime.pullTargetId = 0
    runtime.oocBootstrapped = false
    runtime.oocSawCombat = false
    lvlMin, lvlMax = 1, 65
    if runtime.allData[myName] then
        applyEntry(runtime.allData[myName])
        scanKnownDiscs()
        if runtime.needMigrateSave then
            runtime.needMigrateSave = false
            saveLoadout(true)
        end
    else
        local detected = detectClasses(true)
        if detected then myClasses = detected end
        importCurrentGems() -- new character: seed the loadout from the current bar
    end
    if not myClasses or #myClasses == 0 then
        local liveClasses = detectClasses(false)
        if liveClasses then myClasses = liveClasses end
    end
    ctrl.running = false
    if runtime.bootEnter then runtime.bootEnter() end
end

loadAll()

local UI = {}

function UI.accent(c, txt) ImGui.TextColored(c[1], c[2], c[3], c[4], txt) end
local accent = UI.accent
function UI.setTooltip(txt)
    if txt ~= nil then
        ImGui.SetTooltip('%s', tostring(txt))
    end
end

function UI.pushCol(id, r, g, b, a)
    if id == nil then return end
    if pcall(ImGui.PushStyleColor, id, r, g, b, a) then runtime.colN = (runtime.colN or 0) + 1 end
end
function UI.pushVar(id, a, b)
    if id == nil then return end
    local ok
    if b ~= nil then
        local ImVec2Type = _G.ImVec2 or ImVec2
        if type(ImVec2Type) == 'function' then
            ok = pcall(ImGui.PushStyleVar, id, ImVec2Type(a, b))
        else
            ok = pcall(ImGui.PushStyleVar, id, a, b)
        end
    else
        ok = pcall(ImGui.PushStyleVar, id, a)
    end
    if ok then runtime.varN = (runtime.varN or 0) + 1 end
end

function UI.pushSlimTheme()
    runtime.colN, runtime.varN = 0, 0
    local Col = ImGuiCol or _G.ImGuiCol or (mq.imgui and mq.imgui.Col)
    local SV = ImGuiStyleVar or _G.ImGuiStyleVar or (mq.imgui and mq.imgui.StyleVar)
    if Col then
        UI.pushCol(Col.WindowBg, 0.031, 0.016, 0.055, 0.97)
        UI.pushCol(Col.ChildBg, 0.063, 0.031, 0.094, 1)
        UI.pushCol(Col.PopupBg, 0.031, 0.016, 0.047, 1)
        UI.pushCol(Col.Border, 0.275, 0.125, 0.490, 1)
        UI.pushCol(Col.Text, 0.910, 0.863, 0.784, 1)
        UI.pushCol(Col.TextDisabled, 0.500, 0.400, 0.620, 1)
        UI.pushCol(Col.FrameBg, 0.055, 0.027, 0.102, 1)
        UI.pushCol(Col.FrameBgHovered, 0.145, 0.055, 0.235, 1)
        UI.pushCol(Col.FrameBgActive, 0.200, 0.078, 0.310, 1)
        UI.pushCol(Col.Button, 0.078, 0.035, 0.137, 1)
        UI.pushCol(Col.ButtonHovered, 0.710, 0.420, 1.000, 0.35)
        UI.pushCol(Col.ButtonActive, 0.710, 0.420, 1.000, 0.55)
        UI.pushCol(Col.Header, 0.161, 0.063, 0.125, 1)
        UI.pushCol(Col.HeaderHovered, 0.710, 0.420, 1.000, 0.40)
        UI.pushCol(Col.CheckMark, 0.710, 0.420, 1.000, 1)
        UI.pushCol(Col.SliderGrab, 0.769, 0.627, 0.439, 1)
        UI.pushCol(Col.Separator, 0.420, 0.220, 0.690, 1)
        UI.pushCol(Col.ScrollbarBg, 0.031, 0.016, 0.047, 1)
        UI.pushCol(Col.ScrollbarGrab, 0.420, 0.157, 0.282, 1)
    end
    if SV then
        UI.pushVar(SV.WindowRounding, 7)
        UI.pushVar(SV.FrameRounding, 3)
        UI.pushVar(SV.FramePadding, 6, 3)
        UI.pushVar(SV.ItemSpacing, 6, 4)
        UI.pushVar(SV.WindowPadding, 10, 8)
    end
end

function UI.popTheme()
    if (runtime.varN or 0) > 0 then
        pcall(ImGui.PopStyleVar, runtime.varN); runtime.varN = 0
    end
    if (runtime.colN or 0) > 0 then
        pcall(ImGui.PopStyleColor, runtime.colN); runtime.colN = 0
    end
end

-- VF: Veilfall mark (hood / horns / helm).
function UI.drawEmblem(size)
    size = size or 22
    local w = size * 1.55
    local drew = false
    pcall(function()
        if not runtime.brandTexTried then
            runtime.brandTexTried = true
            local paths = { scriptDir .. 'vft/vf-mark.png' }
            for i = 1, #paths do
                local ok, tex = pcall(mq.CreateTexture, paths[i])
                if ok and tex then
                    runtime.brandTex = tex
                    break
                end
            end
        end
        local tex = runtime.brandTex
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        if tex and tex.GetTextureID and ImVec2Type then
            ImGui.Image(tex:GetTextureID(), ImVec2Type(w, size))
            drew = true
            return
        end
        local dl = ImGui.GetWindowDrawList()
        local p = ImGui.GetCursorScreenPosVec()
        local y = p.y + size * 0.5
        local col = IM_COL32(181, 107, 255, 230)
        dl:AddCircleFilled(ImVec2Type(p.x + size * 0.28, y), size * 0.16, col, 10)
        dl:AddCircleFilled(ImVec2Type(p.x + size * 0.78, y), size * 0.20, col, 10)
        dl:AddCircleFilled(ImVec2Type(p.x + size * 1.24, y), size * 0.16, col, 10)
    end)
    if not drew then ImGui.Dummy(w, size) end
end

function UI.borFlags(...)
    if bit and bit.bor then return bit.bor(...) end
    local acc = 0
    for i = 1, select('#', ...) do acc = acc + (select(i, ...) or 0) end
    return acc
end

-- VF: Mini title: mark + brand only.
function UI.drawSlimTitleBar()
    pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        local wp = ImGui.GetWindowPosVec()
        local ww = ImGui.GetWindowWidth() or 0
        if dl and ImVec2Type and wp and ww > 8 and ww < 700 then
            dl:AddRectFilledMultiColor(
                ImVec2Type(wp.x + 1, wp.y + 1),
                ImVec2Type(wp.x + ww - 1, wp.y + 30),
                IM_COL32(36, 16, 72, 200),
                IM_COL32(36, 16, 72, 200),
                IM_COL32(8, 4, 16, 0),
                IM_COL32(8, 4, 16, 0)
            )
        end
    end)

    require('vft.brand').drawHeader()

    UI.drawSlimGradientRule()
end

function UI.drawSlimGradientRule()
    pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        local p = ImGui.GetCursorScreenPosVec()
        local wp = ImGui.GetWindowPosVec()
        if not (dl and ImVec2Type and p) then return end
        local ww = ImGui.GetWindowWidth() or 0
        if ww > 620 then ww = 420 end
        local pad = 10
        local x1 = (wp and wp.x or p.x) + pad
        local x2 = (wp and wp.x or p.x) + ww - pad
        if x2 < x1 + 80 then x2 = p.x + 220 end
        local y = p.y + 2
        local h = 2
        local mid = x1 + (x2 - x1) * 0.36
        local c0 = IM_COL32(40, 16, 72, 0)
        local c2 = IM_COL32(181, 107, 255, 240)
        local c4 = IM_COL32(40, 16, 72, 0)
        if dl.AddRectFilledMultiColor then
            dl:AddRectFilledMultiColor(ImVec2Type(x1, y), ImVec2Type(mid, y + h), c0, c2, c2, c0)
            dl:AddRectFilledMultiColor(ImVec2Type(mid, y), ImVec2Type(x2, y + h), c2, c4, c4, c2)
        else
            dl:AddLine(ImVec2Type(x1, y), ImVec2Type(x2, y), c2, 1)
        end
    end)
    ImGui.Dummy(1, 8)
end

-- VF: Mini-HUD icons.
function UI.drawSlimTexButton(triedKey, texKey, fileName, fallback, onClick, tip, tint)
    local size = 20
    local clicked = false
    local usedIcon = false
    pcall(function()
        if not runtime[triedKey] then
            runtime[triedKey] = true
            local paths = { scriptDir .. 'vft/' .. fileName }
            for i = 1, #paths do
                local ok, tex = pcall(mq.CreateTexture, paths[i])
                if ok and tex then
                    runtime[texKey] = tex
                    break
                end
            end
        end
        local tex = runtime[texKey]
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        if tex and tex.GetTextureID and ImVec2Type then
            usedIcon = true
            local id = tex:GetTextureID()
            local sz = ImVec2Type(size, size)
            if tint then
                local painted = pcall(function()
                    local ImVec4Type = _G.ImVec4 or ImVec4
                    if ImVec4Type then
                        ImGui.Image(id, sz, ImVec2Type(0, 0), ImVec2Type(1, 1),
                            ImVec4Type(tint[1], tint[2], tint[3], tint[4] or 1))
                    else
                        ImGui.Image(id, sz)
                    end
                end)
                if not painted then ImGui.Image(id, sz) end
            else
                ImGui.Image(id, sz)
            end
            if ImGui.IsItemClicked() then clicked = true end
        end
    end)
    if not usedIcon then
        if ImGui.SmallButton(fallback) then clicked = true end
    end
    if clicked and onClick then onClick() end
    if ImGui.IsItemHovered() then
        UI.setTooltip(tip)
    end
end

function UI.drawSlimBagButton()
    UI.drawSlimTexButton('bagTexTried', 'bagTex', 'vf-bag.png', 'Bag##slimBags', function()
        if toggleVfInv then toggleVfInv() end
    end, 'Inv. /vf inv (/lua run vft/inv)')
end

function UI.drawSlimGearButton()
    UI.drawSlimTexButton('gearTexTried', 'gearTex', 'vf-gear.png', 'Gear##slimLoadout', function()
        if runtime.toggleManager then runtime.toggleManager() end
    end, 'Opens or closes Veilfall Manager (/vfmgr). Save writes the loadout; VF reloads.')
end

function UI.drawSlimPinButton()
    UI.drawSlimTexButton('pinTexTried', 'pinTex', 'vf-pin.png', 'Pin##slimWaypoints', function()
        if runtime.toggleWaypoints then runtime.toggleWaypoints() end
    end, 'Opens or closes Waypoints bar (/vf waypoints).')
end

function UI.drawSlimBurnButton()
    local tint
    if ctrl.burn then
        local pulse = (math.sin(os.clock() * 8.0) + 1.0) * 0.5
        tint = { 1.0, 0.28 + (0.40 * pulse), 0.06, 1 }
    else
        tint = { 0.62, 0.52, 0.44, 0.80 }
    end
    UI.drawSlimTexButton('flameTexTried', 'flameTex', 'vf-flame.png', 'Burn##slimBurn',
        function()
            ctrl.burn = not ctrl.burn
            if runtime.resetBurnMultiline then runtime.resetBurnMultiline() end
            print(string.format('\ag[VF]\ax Burn mode %s.', ctrl.burn and 'ENABLED!' or 'DISABLED.'))
        end,
        'Burn (session). Mini or /vf burn. Instant burn_only ? /multiline every ~10 ticks; cast-time burn rows one-fire. Clears when CombatState leaves COMBAT.',
        tint)
end

-- VF: Boost stub ? lightning bolt; /vf boost. No combat behavior yet.
function UI.drawSlimBoostButton()
    local size = 20
    local on = not not ctrl.boost
    local cr, cg, cb, ca
    if on then
        local pulse = (math.sin(os.clock() * 8.0) + 1.0) * 0.5
        cr, cg, cb, ca = 0.85, 0.55 + (0.35 * pulse), 1.0, 1.0
    else
        cr, cg, cb, ca = 0.54, 0.44, 0.53, 0.85
    end
    local clicked = false
    local drew = false
    pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        if not (dl and ImVec2Type) then return end
        local p = ImGui.GetCursorScreenPosVec()
        if not p then return end
        ImGui.InvisibleButton('##slimBoost', ImVec2Type(size, size))
        if ImGui.IsItemClicked() then clicked = true end
        local col = IM_COL32(math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255), math.floor(ca * 255))
        local x, y, s = p.x, p.y, size
        -- VF: simple bolt in brand purple.
        if dl.AddTriangleFilled then
            dl:AddTriangleFilled(
                ImVec2Type(x + s * 0.58, y + s * 0.08),
                ImVec2Type(x + s * 0.22, y + s * 0.52),
                ImVec2Type(x + s * 0.48, y + s * 0.52), col)
            dl:AddTriangleFilled(
                ImVec2Type(x + s * 0.42, y + s * 0.48),
                ImVec2Type(x + s * 0.36, y + s * 0.92),
                ImVec2Type(x + s * 0.78, y + s * 0.40), col)
        end
        drew = true
    end)
    if not drew then
        local Col = ImGuiCol or _G.ImGuiCol or (mq.imgui and mq.imgui.Col)
        local pushed = 0
        if Col and Col.Text then
            if pcall(ImGui.PushStyleColor, Col.Text, cr, cg, cb, ca) then pushed = pushed + 1 end
        end
        if ImGui.SmallButton('Boost##slimBoost') then clicked = true end
        if pushed > 0 then pcall(ImGui.PopStyleColor, pushed) end
    end
    if clicked then
        ctrl.boost = not ctrl.boost
        print(string.format('\ag[VF]\ax Boost %s (stub).', ctrl.boost and 'ON' or 'OFF'))
    end
    if ImGui.IsItemHovered() then
        UI.setTooltip('Boost (session stub). Mini or /vf boost. No combat behavior yet.')
    end
end

-- VF: Session Tracker Helpers (AA / Platinum).
function UI.getCurrentAA()
    local okTotal, total = pcall(function() return mq.TLO.Me.AAPointsTotal() end)
    local okSpent, spent = pcall(function() return mq.TLO.Me.AAPointsSpent() end)
    local okUnspent, unspent = pcall(function() return mq.TLO.Me.AAPoints() end)
    local okPct, pct = pcall(function() return mq.TLO.Me.PctAAExp() end)

    local aaCount = nil
    if okTotal and type(total) == 'number' then
        aaCount = total
    elseif (okSpent and type(spent) == 'number') or (okUnspent and type(unspent) == 'number') then
        aaCount = (spent or 0) + (unspent or 0)
    end

    if aaCount and okPct and type(pct) == 'number' then
        aaCount = aaCount + (pct / 100)
    end
    return aaCount
end

function UI.getCurrentPlat()
    local okCash, cash = pcall(function() return mq.TLO.Me.Cash() end)
    if okCash and type(cash) == 'number' and cash >= 0 then
        return math.floor(cash / 1000)
    end
    local okPlat, plat = pcall(function() return mq.TLO.Me.Platinum() end)
    if okPlat and type(plat) == 'number' then
        return plat
    end
    return nil
end

function UI.resetTracker()
    runtime.trackStartTime = os.time()
    runtime.startAA = UI.getCurrentAA()
    runtime.currentAA = runtime.startAA or 0
    runtime.startPlat = UI.getCurrentPlat()
    runtime.currentPlat = runtime.startPlat or 0
end

function UI.maybeResetTrackerOnClick(tip)
    if ImGui.IsItemClicked() then
        UI.resetTracker()
    end
    if ImGui.IsItemHovered() then
        UI.setTooltip(tip)
    end
end

function UI.updateTracker()
    if not runtime.trackStartTime then
        runtime.trackStartTime = os.time()
    end
    local aa = UI.getCurrentAA()
    if aa ~= nil then
        if runtime.startAA == nil then runtime.startAA = aa end
        runtime.currentAA = aa
    end
    local plat = UI.getCurrentPlat()
    if plat ~= nil then
        if runtime.startPlat == nil then runtime.startPlat = plat end
        runtime.currentPlat = plat
    end
end

local function setManualHunterPetHold(on, force)
    if not hasActivePet() then return end
    if on then
        if force or petState.manualHunterHold ~= true then
            mq.cmd('/say #petcmd hold all')
            mq.cmd('/say #petcmd ghold on')
            mq.cmd('/pet back off')
            petState.manualHunterHold = true
            petState.petHoldActive = true
        end
    else
        if force or petState.manualHunterHold ~= false then
            mq.cmd('/say #petcmd ghold off')
            petState.manualHunterHold = false
            petState.petHoldActive = false
        end
    end
end

local desiredRange    -- forward declaration; defined in the engine section below
local maxMeleeDistance -- forward declaration; defined in the engine section below

function UI.toggleEngine()
    if ctrl.running then
        if ctrl.mode == 'Manual' then
            setManualHunterPetHold(true, true)
        else
            setManualHunterPetHold(false, true)
        end
        ctrl.running = false
        fullStop()
        print('\ag[VF]\ax paused.')
    else
        ctrl.running = true
        runtime.wasRunning = true
        if runtime.resetRouteOnPlay then runtime.resetRouteOnPlay() end
        if runtime.groupOnPlay then runtime.groupOnPlay() end
        print('\ag[VF]\ax running.')
    end
end

-- VF: Last known good glyphs: || = paused, > = running.
function UI.drawSlimRunButton()
    local c, tip, label
    if not ctrl.running then
        c, tip, label = D.WARN, 'Paused -- click to start', '[||]'
    elseif runtime.medBreakActive then
        c, tip, label = D.ARC, 'Med break -- click to pause', '[~]'
    elseif runtime.postCombatHealActive then
        c, tip, label = D.ARC, 'Healing -- click to pause', '[+]'
    else
        c, tip, label = D.GOOD, 'Running -- click to pause', '[>]'
    end
    local Col = ImGuiCol or _G.ImGuiCol or (mq.imgui and mq.imgui.Col)
    local pushed = 0
    if Col and Col.Text and c then
        if pcall(ImGui.PushStyleColor, Col.Text, c[1], c[2], c[3], c[4] or 1) then
            pushed = pushed + 1
        end
    end
    local hit = ImGui.SmallButton(label .. '##slimRun')
    if pushed > 0 then pcall(ImGui.PopStyleColor, pushed) end
    if hit then UI.toggleEngine() end
    if ImGui.IsItemHovered() then UI.setTooltip(tip) end
end

function UI.peekPowerSource()
    if runtime.refreshPowerSourceSlot then runtime.refreshPowerSourceSlot() end
    if runtime.psPct ~= nil then
        return string.format('%d%%', math.floor(runtime.psPct))
    end
    return '--'
end

-- VF: item tier is in the name, not a TLO. Floor the percent.
function UI.powerSourceTier()
    local name = tostring(runtime.psName or ''):lower()
    if name:find('legendary', 1, true) then return 'Legendary', D.WARN end
    if name:find('enchanted', 1, true) then return 'Enchanted', D.ARC end
    if name ~= '' then return 'Base', D.GOOD end
    return 'unknown', D.MUTED
end

function UI.powerSourceTooltip()
    local name = runtime.psName or '(no growing item seen yet)'
    local src = runtime.psSource or 'waiting for a combat XP tick'
    local tier = UI.powerSourceTier()
    if runtime.psPct ~= nil then
        return string.format('%s\nTier: %s -- %.2f%%  (%s)\nTriune prints this in chat; MQ has no item-XP TLO for it.',
            name, tier, runtime.psPct, src)
    end
    return string.format('%s\nTier: %s\n%s\nEquipped name is visible; percent arrives on the next shimmer line.',
        name, tier, src)
end

-- VF: relative hunt band. Unknown values stay so opening the combo cannot rewrite them.
function UI.drawRelLevelPick(id, cur, apply, width)
    local steps = { -99, -10, -5, -3, -1, 0, 1, 3, 5, 10, 99 }
    cur = tonumber(cur) or 0
    if cur <= -50 then cur = -99 end
    if cur >= 50 then cur = 99 end
    local merged, present = {}, false
    for _, v in ipairs(steps) do
        merged[#merged + 1] = v
        if v == cur then present = true end
    end
    if not present then
        merged[#merged + 1] = cur
        table.sort(merged)
    end
    local labels, idx = {}, 1
    for i, v in ipairs(merged) do
        if v <= -50 or v >= 50 then
            labels[i] = 'Any'
        elseif v == 0 then
            labels[i] = '0'
        else
            labels[i] = string.format('%+d', v)
        end
        if v == cur then idx = i end
    end
    ImGui.SetNextItemWidth(width or 64)
    local newIdx = ImGui.Combo(id, idx, labels)
    newIdx = tonumber(newIdx) or idx
    if newIdx ~= idx and merged[newIdx] then apply(merged[newIdx]) end
end

function UI.drawSlimLevelBand()
    local lo = tonumber(ctrl.hunter_rel_min) or 0
    local hi = tonumber(ctrl.hunter_rel_max) or 5
    local meL = 1
    pcall(function() meL = tonumber(mq.TLO.Me.Level()) or 1 end)
    local a = math.max(1, meL + lo)
    local b = math.min(120, meL + hi)
    if lo <= -50 then a = 1 end
    if hi >= 50 then b = 120 end
    local tip = string.format('NPC level vs you. Any = no bound.\nHunting %d to %d (you are %d).', a, b, meL)

    UI.drawRelLevelPick('##slimLvlMin', lo, function(v)
        ctrl.hunter_rel_min = v
        if v > (tonumber(ctrl.hunter_rel_max) or 5) then ctrl.hunter_rel_max = v end
        saveLoadout(true)
    end, 64)
    if ImGui.IsItemHovered() then UI.setTooltip(tip) end
    ImGui.SameLine()
    UI.drawRelLevelPick('##slimLvlMax', hi, function(v)
        ctrl.hunter_rel_max = v
        if v < (tonumber(ctrl.hunter_rel_min) or 0) then ctrl.hunter_rel_min = v end
        saveLoadout(true)
    end, 64)
    if ImGui.IsItemHovered() then UI.setTooltip(tip) end
end

function UI.drawSlimGui()
    if not open then return end
    UI.pushSlimTheme()
    pcall(function()
        local ImVec2Type = _G.ImVec2 or ImVec2 or (mq.imgui and mq.imgui.ImVec2)
        if ImVec2Type and ImGui.SetNextWindowSizeConstraints then
            ImGui.SetNextWindowSizeConstraints(ImVec2Type(240, 0), ImVec2Type(620, 420))
        end
    end)
    local flags = ImGuiWindowFlags.AlwaysAutoResize
    local F = ImGuiWindowFlags
    if F.NoTitleBar and F.NoCollapse then
        flags = UI.borFlags(F.AlwaysAutoResize, F.NoTitleBar, F.NoCollapse)
    end
    local show
    open, show = ImGui.Begin('###vfSlim', open, flags)
    if not open then
        open = true
        ImGui.End()
        UI.popTheme()
        return
    end

    UI.drawSlimTitleBar()

    if show then
        UI.drawSlimRunButton()

        ImGui.SameLine()
        ImGui.SetNextItemWidth(78)
        local curPrimaryIdx = U.idxOf(D.PRIMARY_MODES, ctrl.mode)
        local newPrimaryIdx = ImGui.Combo('##slimPrimary', curPrimaryIdx, D.PRIMARY_MODES)
        if newPrimaryIdx ~= curPrimaryIdx then
            local newPrimaryMode = D.PRIMARY_MODES[newPrimaryIdx]
            if ctrl.mode == 'Manual' and newPrimaryMode ~= 'Manual' then
                setManualHunterPetHold(false)
            elseif newPrimaryMode == 'Manual' then
                if not ctrl.running or not isCombat() then
                    setManualHunterPetHold(true, true)
                end
            end
            if (newPrimaryMode == 'Roam' or newPrimaryMode == 'Rush') and newPrimaryMode ~= ctrl.mode then
                runtime.navReset()
            end
            ctrl.mode = newPrimaryMode
            if D.SUBMODES[ctrl.mode] then
                local keep = ctrl.submode
                local ok = false
                for _, s in ipairs(D.SUBMODES[ctrl.mode]) do
                    if s == keep then ok = true break end
                end
                if ok then ctrl.submode = keep else ctrl.submode = D.SUBMODES[ctrl.mode][1] end
            else
                ctrl.submode = 'Hunt'
            end
            saveLoadout(true)
        end

        if D.SUBMODES[ctrl.mode] then
            ImGui.SameLine()
            ImGui.SetNextItemWidth(70)
            local subList = D.SUBMODES[ctrl.mode]
            local curSubIdx = U.idxOf(subList, ctrl.submode)
            local newSubIdx = ImGui.Combo('##slimSub', curSubIdx, subList)
            if newSubIdx ~= curSubIdx then
                ctrl.submode = subList[newSubIdx]
                if ctrl.mode == 'Rush' then
                    runtime.navReset()
                end
                saveLoadout(true)
            end
        end

        if ctrl.mode == 'Manual' then
            ImGui.SameLine()
            local fa = ctrl.focus_adds == true
            local newFa = ImGui.Checkbox('Focus Adds##slimFocusAdds', fa)
            if newFa ~= fa then
                ctrl.focus_adds = newFa
                saveLoadout(true)
            end
            if ImGui.IsItemHovered() then
                UI.setTooltip('Lowest-level hostiles in proximity first (adds before boss).')
            end
        end

        if ctrl.mode == 'Group' then
            ImGui.SameLine()
            local ga = ctrl.group_anchor == true
            local newGa = ImGui.Checkbox('Anchor##slimGroupAnchor', ga)
            if newGa ~= ga then
                ctrl.group_anchor = newGa
                if newGa then
                    if runtime.groupAnchorStamp then runtime.groupAnchorStamp() end
                else
                    ctrl.group_anchor_loc = nil
                end
                saveLoadout(true)
            end
            if ImGui.IsItemHovered() then
                UI.setTooltip('Wait at this spot between pulls. Fight camp invaders without waiting for the group. Stamps your position when checked.')
            end
        end

        -- VF: hide relative offsets unless that band is what is filtering.
        if ctrl.mode == 'Roam' or ctrl.mode == 'Rush' then
            ImGui.SameLine()
            UI.drawSlimLevelBand()
        end

        UI.updateTracker()
        local elapsedSec = os.time() - (runtime.trackStartTime or os.time())
        local elapsedHrs = math.max(elapsedSec / 3600.0, 0)
        local aaGained = (runtime.startAA and runtime.currentAA) and math.max(0, runtime.currentAA - runtime.startAA) or 0
        local aaRate = (elapsedHrs > 0.0001) and (aaGained / elapsedHrs) or 0.0
        local platGained = (runtime.startPlat and runtime.currentPlat) and (runtime.currentPlat - runtime.startPlat) or 0
        local platRate = (elapsedHrs > 0.0001) and (platGained / elapsedHrs) or 0.0
        local platStr
        if platRate >= 1000 then
            platStr = string.format('%.1fk', platRate / 1000)
        else
            platStr = string.format('%.0f', platRate)
        end

        UI.drawSlimBagButton()
        ImGui.SameLine()
        UI.drawSlimGearButton()
        ImGui.SameLine()
        UI.drawSlimPinButton()
        ImGui.SameLine()
        UI.drawSlimBurnButton()
        ImGui.SameLine()
        UI.drawSlimBoostButton()
        ImGui.SameLine()
        ImGui.TextDisabled(string.format('AA: %.1f/h', aaRate))
        UI.maybeResetTrackerOnClick('Click to reset session AA and plat tracking.')
        ImGui.SameLine()
        ImGui.TextDisabled(string.format('Plat: %s/h', platStr))
        UI.maybeResetTrackerOnClick(string.format(
            'Session platinum %+d. Click to reset AA and plat tracking.', platGained))

        -- VF: Power Source sits on the right edge of the mini row.
        local psText = UI.peekPowerSource()
        local _, psCol = UI.powerSourceTier()
        local pad = 12
        local tw = 28
        pcall(function()
            local w = ImGui.CalcTextSize(psText)
            if type(w) == 'number' then tw = w
            elseif w and w.x then tw = w.x end
        end)
        local ww = ImGui.GetWindowWidth() or 0
        local cx = ImGui.GetCursorPosX() or 0
        local targetX = ww - pad - tw
        if targetX > cx + 8 then
            ImGui.SameLine(targetX)
        else
            ImGui.SameLine()
        end
        ImGui.TextColored(psCol[1], psCol[2], psCol[3], psCol[4], psText)
        if ImGui.IsItemHovered() then
            UI.setTooltip(UI.powerSourceTooltip())
        end
    end

    ImGui.End()
    UI.popTheme()
end


local function draw()
    if not open then return end
    UI.drawSlimGui()
end

-- VF: combatTick: target, move, gems, AAs, discs.


local function setTarget(id)
    if not id or id == 0 then return false end
    local s = mq.TLO.Spawn(id)
    if not s() or s.Dead() or s.Type() == 'Corpse' then return false end
    if mq.TLO.Target.ID() == id then return true end
    -- VF: Group: declared assist, or Anchor camp invader.
    if ctrl and ctrl.mode == 'Group' and ctrl.running and isHostileTarget(id) then
        local assist = runtime.groupAssistMobId and runtime.groupAssistMobId() or nil
        if assist ~= id then
            if not (ctrl.group_anchor and runtime.groupAnchorAllows
                and runtime.groupAnchorAllows(id)) then
                return false
            end
        end
    end
    -- VF: Manual/Rush+On / Pause: no hostile target snaps until attack arms chase.
    if ctrl and ((not ctrl.running) or ctrl.mode == 'Manual') and not runtime.manualFightArmed then
        if isHostileTarget(id) then return false end
    end
    local wasCombat = mq.TLO.Me.Combat()
    mq.cmdf('/target id %d', id)
    -- VF: do not mq.delay in a fight — 60ms froze the swing pulse. TLO catches up next frame.
    local fighting = wasCombat
    if not fighting then
        pcall(function() fighting = mq.TLO.Me.CombatState() == 'COMBAT' end)
    end
    if not fighting then
        local t = 0
        while mq.TLO.Target.ID() ~= id and t < 60 do
            mq.delay(10); t = t + 10
        end
    end
    local success = mq.TLO.Target.ID() == id or fighting
    -- VF: keep /attack on a retarget only if the toggle was already down. CombatState is not consent.
    if wasCombat and isHostileTarget(id) then
        if not mq.TLO.Me.Combat() then mq.cmd('/attack on') end
    end
    return success
end

-- VF: Buff / song detect lives in ta/buff.lua (own local budget).
buffActive = function(id, name)
    if runtime.buffActive then return runtime.buffActive(id, name) end
    return false
end

-- VF: Group.Members() EXCLUDES you, so `0, total` covers every slot. Index 0 is you
-- VF: and is the starting baseline; do not "fix" it to 1.
-- VF: Present is required. A member in another zone still answers Group.Member(i) and
-- VF: reports a stale PctHPs -- a 0 from a zoned-out ally would win "lowest" forever
-- VF: and aim every heal at someone who cannot be targeted.
local function lowestHpAlly()
    local bestId, bestHp = mq.TLO.Me.ID(), (mq.TLO.Me.PctHPs() or 100)
    local total = 0
    pcall(function() total = mq.TLO.Group.Members() or 0 end)
    for i = 0, total do
        local m = nil
        pcall(function() m = mq.TLO.Group.Member(i) end)
        if m and m() and not m.Dead() then
            local here = true
            pcall(function()
                if m.Offline() or m.OtherZone() then here = false end
            end)
            local hp = m.PctHPs() or 100
            if here and hp < bestHp then
                bestHp = hp; bestId = m.ID()
            end
        end
    end
    return bestId
end

local isUnreachable -- forward declaration; defined in the pursuit section below

-- VF: pack = how many around you want a fight. Not idle radius. Slots are not read.
local function countPackMobs(radius)
    radius = tonumber(radius) or 80
    local cnt = 0
    pcall(function()
        local filt = string.format('npc radius %d', radius)
        local n = mq.TLO.SpawnCount(filt)() or 0
        for i = 1, math.min(n, 40) do
            local s = mq.TLO.NearestSpawn(i, filt)
            if s and s() then
                local id = s.ID() or 0
                if id > 0 and runtime.spawnWantsFight and runtime.spawnWantsFight(id) then
                    cnt = cnt + 1
                end
            end
        end
    end)
    return cnt
end

-- VF: Returns true if an action (spell, AA, disc, skill) is detrimental (offensive).
local function isDetrimentalAction(name, targetToken, entry)
    if not name or name == '' then return false end
    targetToken = tostring(targetToken or '')

    if targetToken:sub(1, 2) == 'E:' then return true end

    local isBene = nil
    pcall(function()
        local sp = mq.TLO.Spell(name)
        if sp() then isBene = sp.Beneficial() end
    end)
    if isBene == false then return true end
    if isBene == true then return false end

    pcall(function()
        local aa = mq.TLO.Me.AltAbility(name)
        if aa() then
            local sp = aa.Spell
            if sp() then isBene = sp.Beneficial() end
        end
    end)
    if isBene == false then return true end
    if isBene == true then return false end

    pcall(function()
        local ca = mq.TLO.Me.CombatAbility(name)
        if ca() then
            local sp = ca.Spell
            if sp() then isBene = sp.Beneficial() end
        end
    end)
    if isBene == false then return true end
    if isBene == true then return false end

    if entry and entry.kind then
        if entry.kind == 'dd' or entry.kind == 'dot' or entry.kind == 'debuff' then return true end
        if entry.kind == 'buff' or entry.kind == 'heal' or entry.kind == 'pet' or entry.kind == 'util' then return false end
    end

    local _, spellBene, kind = spellClassInfo(name)
    if not spellBene then return true end
    if kind == 'dd' or kind == 'dot' or kind == 'debuff' then return true end

    local lowerName = name:lower()
    if lowerName:find('kick') or lowerName:find('bash') or lowerName:find('backstab') or lowerName:find('frenzy')
        or lowerName:find('slam') or lowerName:find('strike') or lowerName:find('taunt') or lowerName:find('disarm')
        or lowerName:find('dragon punch') or lowerName:find('eagle strike') or lowerName:find('round kick') or lowerName:find('tiger claw') then
        return true
    end

    return false
end

local function isTargetInRange(name, targetId)
    if not targetId or targetId == 0 then return false end
    local myId = mq.TLO.Me.ID() or 0
    if targetId == myId then return true end

    local dist = distToId(targetId)
    if dist < 0 then return false end

    local maxRange = 0
    if name and name ~= '' then
        pcall(function()
            local sp = mq.TLO.Spell(name)
            if sp() then
                local r = sp.Range() or 0
                if r > 0 then maxRange = r end
            end
        end)
    end
    if maxRange == 0 then
        maxRange = maxMeleeDistance(targetId)
    end

    return dist <= (maxRange + 2)
end

local function maPcId()
    return findMaPcId(ctrl and ctrl.ma_name)
end

local function targetIsEngaged(id)
    if not id or id <= 0 then return false end
    if isSpawnPetOrPlayer(id) or not isHostileTarget(id) then return false end
    -- VF: Group: only the anchor's declared kill target counts as engaged.
    if ctrl and ctrl.mode == 'Group' and runtime.groupAssistMobId then
        local mobId = runtime.groupAssistMobId()
        return mobId ~= nil and id == mobId
    end
    if runtime.spawnWantsFight and runtime.spawnWantsFight(id) then return true end
    local s = mq.TLO.Spawn(id)
    if not s() or s.Dead() or s.Type() == 'Corpse' then return false end
    if (s.PctHPs() or 100) < 100 then return true end

    -- VF: Check if target of target is player or group member.
    local totId = 0
    pcall(function() totId = s.TargetOfTarget.ID() or 0 end)
    if totId > 0 then
        if isGroupOrRaidMember(totId) or totId == (mq.TLO.Me.ID() or 0) then
            return true
        end
    end

    -- VF: If in Roam/Rush (or paused), valid NPC targets selected by engine are engaged.
    if ctrl and (ctrl.mode == 'Roam' or ctrl.mode == 'Rush' or not ctrl.running) then
        return true
    end

    return false
end

-- VF: Me.CombatState == COMBAT is the only engine combat mood. Toggle/threat stay elsewhere.
isCombat = function()
    if runtime.engineInCombat then
        return not not runtime.engineInCombat()
    end
    if runtime.inCombatState then
        return not not runtime.inCombatState()
    end
    local ok, res = pcall(function()
        return mq.TLO.Me.CombatState() == 'COMBAT'
    end)
    return ok and res or false
end

-- VF: alias kept for older call sites; same as engineInCombat.
runtime.inCombatHate = function()
    return isCombat()
end

local function anyNearbyEngagedNpc(radius)
    if countPackMobs(runtime.rushNear or 80) > 0 then return true end
    local filt = string.format('npc radius %d', radius or 150)
    local n = mq.TLO.SpawnCount(filt)() or 0
    for i = 1, n do
        local s = mq.TLO.NearestSpawn(i, filt)
        if s() and s.ID() > 0 and not isSpawnPetOrPlayer(s.ID()) and isHostileTarget(s.ID()) then
            if targetIsEngaged(s.ID()) then return true end
        end
    end
    return false
end

-- VF: "on me" means THIS mob has aggro on THIS character. It used to alias
-- VF: spawnWantsFight, which answers "is this a legal kill" -- true for any
-- VF: aggressive OR merely wounded NPC in the zone, including one fighting someone
-- VF: else. Every caller reading it as "I am being attacked" was wrong, which is
-- VF: how we dropped a runner to chase a stranger's mob. playerHasAggro is the
-- VF: real test (ToT / AggroHolder / PctAggro).
function runtime.spawnIsOnMe(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    -- VF: an ally or a pet is never "on me", whatever its hate list says.
    if isGroupOrRaidMember(id) or isSpawnPetOrPlayer(id) then return false end
    return not not (runtime.playerHasAggro and runtime.playerHasAggro(id))
end

-- VF: nearest spawn in band that wants a fight. unmezzed=true skips mez (CC / add is loose).
-- VF: onMeOnly=true narrows it to mobs actually on us -- see closestMobOnMe.
function runtime.closestThreat(radius, exclude, unmezzed, onMeOnly)
    radius = tonumber(radius) or 80
    exclude = tonumber(exclude) or 0
    local bestId, bestD = nil, radius + 1
    pcall(function()
        local filt = string.format('npc radius %d', radius)
        local n = mq.TLO.SpawnCount(filt)() or 0
        for i = 1, math.min(n, 20) do
            local s = mq.TLO.NearestSpawn(i, filt)
            if s and s() then
                local id = s.ID() or 0
                if id > 0 and id ~= exclude and runtime.spawnWantsFight(id)
                    and (not onMeOnly or runtime.spawnIsOnMe(id)) then
                    local mezzed = false
                    if unmezzed and buffActive then
                        mezzed = not not buffActive(id, 'Mez')
                    end
                    if not mezzed then
                        local d = s.Distance3D() or 999
                        if d < bestD then
                            bestD = d
                            bestId = id
                        end
                    end
                end
            end
        end
    end)
    return bestId
end

-- VF: nearest mob that actually has aggro on us. Was a bare alias of closestThreat
-- VF: ("nearest mob that wants a fight"), so retargetThreat would abandon a runner
-- VF: for any wounded mob in the band and log it as "on-me". Group camp defense
-- VF: still sees wanderers: campInvaderId falls back to closestThreat.
function runtime.closestMobOnMe(radius)
    return runtime.closestThreat(radius, 0, false, true)
end

function runtime.anyMobOnMe(radius)
    return runtime.closestMobOnMe(radius) ~= nil
end

-- VF: nearest live hostile in the Manual bubble — not spawnIsOnMe (ToT is empty here).
function runtime.closestHostileNear(radius)
    radius = tonumber(radius) or (runtime.rushNear or 80)
    local bestId, bestD = nil, radius + 1
    pcall(function()
        local filt = string.format('npc radius %d', radius)
        local n = mq.TLO.SpawnCount(filt)() or 0
        for i = 1, math.min(n, 20) do
            local s = mq.TLO.NearestSpawn(i, filt)
            if s() then
                local id = s.ID() or 0
                local stype = s.Type() or ''
                if id > 0 and (stype == 'NPC' or stype == 'Pet')
                    and not s.Dead() and stype ~= 'Corpse'
                    and isHostileTarget(id) and not isIgnored(s.CleanName())
                    and not isUnreachable(id)
                    and not isGroupOrRaidMember(id) and not isSpawnPetOrPlayer(id) then
                    local d = s.Distance3D() or 999
                    if d < bestD then
                        bestD = d
                        bestId = id
                    end
                end
            end
        end
    end)
    return bestId
end

-- VF: stay in the Manual pack after a kill — Combat() drops on corpse.
function runtime.manualPackHot(radius)
    radius = tonumber(radius) or (runtime.rushNear or 80)
    local hot = false
    pcall(function()
        if mq.TLO.Me.Combat() then hot = true; return end
        if mq.TLO.Me.CombatState() == 'COMBAT' then hot = true; return end
    end)
    if hot then return true end
    return runtime.closestThreat(radius) ~= nil
end

local function maTargetId()
    if ctrl.mode == 'Group' and runtime.groupAssistMobId then
        return runtime.groupAssistMobId()
    end
    -- VF: Me.GroupAssistTarget is the MA's kill target with no command, no 150ms
    -- VF: mq.delay and no target hijack, and it works in every mode -- so it goes
    -- VF: ahead of the /assist path, which now only earns its cost when the group
    -- VF: has no MA role set. isHostileTarget re-applies the ignore / Block List.
    local gat = runtime.maGroupAssistMobId and runtime.maGroupAssistMobId()
    if gat and isHostileTarget(gat) then return gat end

    local maId = maPcId()
    if not maId then return nil end
    local gated = (ctrl.mode == 'Group')
    if gated and not anyNearbyEngagedNpc(150) then
        return nil -- nothing nearby is actually being fought -- don't even peek via /assist
    end
    local now = os.clock()
    if (now - runtime.lastAssistCmdAt) >= 1.0 then
        runtime.lastAssistCmdAt = now
        local nm = mq.TLO.Spawn(maId).CleanName()
        if nm and nm ~= '' then
            mq.cmdf('/assist %s', nm)
            mq.delay(150)
        end
    end
    local t = mq.TLO.Target
    if not (t() and (t.Type() == 'NPC' or t.Type() == 'Pet') and not t.Dead() and t.Type() ~= 'Corpse' and not isSpawnPetOrPlayer(t.ID()) and isHostileTarget(t.ID())) then return nil end
    if gated and not targetIsEngaged(t.ID()) then
        return nil
    end
    return t.ID()
end

local function resolveTargetId(token, cls)
    local b = U.baseTok(token)
    local id
    if b == 'Myself' then
        id = mq.TLO.Me.ID()
    elseif b == 'Whole Group' then
        -- VF: was Me.ID(), which broke the GATE, not just the target: conditionMet only
        -- VF: ever receives the resolved id, so 'HP <=' on a Whole Group row measured
        -- VF: the caster. At 97% with an ally at 36% the row never fired.
        -- VF: Deliberately the same resolution as 'Lowest-HP Ally' -- one implementation,
        -- VF: no second owner. A Group v1 spell cast on any group member still heals the
        -- VF: whole group, so this is correct for group and single-target heals alike.
        id = lowestHpAlly()
    elseif b == 'Main Assist' or b == 'Tank' then
        id = maPcId()
    elseif b == 'Lowest-HP Ally' then
        id = lowestHpAlly()
    elseif b == 'Pet' then
        local p = (cls and petState.myPets[cls] and isSpawnAlive(petState.myPets[cls]) and petState.myPets[cls]) or
            (mq.TLO.Me.Pet.ID() or 0)
        id = (p and p > 0) and p or nil
    elseif b == 'Current Target' then
        id = mq.TLO.Target.ID()
    elseif b == 'Assist Target' then
        id = maTargetId()
    elseif b == 'Unmezzed Add' then
        -- VF: Group CC: the add that is not the one the MA is beating on.
        local r = (ctrl and tonumber(ctrl.xtar_nav_dist)) or runtime.rushNear or 80
        id = runtime.closestThreat(r, maTargetId(), true)
    elseif b == 'Nearest Add' or b == 'All Enemies' then
        local maxZ = ctrl.hunter_z or 75
        local r = (ctrl and tonumber(ctrl.xtar_nav_dist)) or runtime.rushNear or 80
        id = runtime.closestThreat(r)
        if not id then
            local minL, maxL = runtime.npcLevelBand()
            local maxR = ctrl.hunter_radius or 1500
            local myZ = mq.TLO.Me.Z() or 0
            for i = 1, 10 do
                local s = mq.TLO.NearestSpawn(i, string.format('npc targetable radius %d', maxR))
                if not s() then break end
                local sid = s.ID() or 0
                if sid > 0 and s.Type() == 'NPC' and not s.Dead() and s.Type() ~= 'Corpse'
                    and not isAnyPet(s) and not isSpawnPetOrPlayer(sid) and isHostileTarget(sid)
                    and not isIgnored(s.CleanName()) and not isUnreachable(sid) then
                    local okZ, sz = pcall(function() return s.Z() end)
                    if okZ and sz and math.abs(sz - myZ) <= maxZ then
                        local lvl = s.Level() or 0
                        if lvl == 0 or (lvl >= minL and lvl <= maxL) then
                            id = sid
                            break
                        end
                    end
                end
            end
        end
    else
        id = mq.TLO.Target.ID()
    end
    if not id or id <= 0 then return nil end
    local s = mq.TLO.Spawn(id)
    if not s() or s.Dead() or s.Type() == 'Corpse' then return nil end
    local hp = 100
    pcall(function() hp = s.PctHPs() or 100 end)
    local stype = ''
    pcall(function() stype = s.Type() or '' end)
    local cname = ''
    pcall(function() cname = s.CleanName() or '' end)
    if cname ~= '' and isIgnored(cname) then return nil end
    -- VF: Assist gate removed with Assist mode.
    return id
end

mq.event('TriuneZone', 'You have entered #*#', function()
    runtime.sungBuffs = {}
    runtime.buffTries = {}
    if runtime.buffSessionClear then runtime.buffSessionClear() end
    -- VF: Gate 7 ? settle before Buff/HoT dump; invalidate bar cache.
    if runtime.onBuffZone then
        runtime.onBuffZone()
    else
        runtime.buffZoneSettleUntil = os.clock() + 3
        if runtime.invalidateBarCache then runtime.invalidateBarCache() end
    end
    onZoned()
end)

-- VF: songs stubbed until Twist/Medley -- no re-sing scan.
local function reconcileSungBuffs()
end

local function reconcilePets()
    local petClassList = {}
    for _, c in ipairs(myClasses) do if D.PET_CLASSES[c] then petClassList[#petClassList + 1] = c end end
    if #petClassList == 0 then return end
    local n = 0
    pcall(function() n = mq.TLO.SpawnCount('pet radius 100')() or 0 end)
    local assigned = 0
    for i = 1, n do
        if assigned >= #petClassList then break end
        local s = mq.TLO.NearestSpawn(i, 'pet radius 100')
        if s and s() and s.ID() and isSpawnMyPet(s) then
            assigned = assigned + 1
            petState.myPets[petClassList[assigned]] = s.ID()
            petState.lastObservedId = s.ID()
        end
    end
    if assigned > 0 then
        print('\ag[VF]\ax found ' .. assigned .. ' existing pet(s) on load -- wont re-summon them.')
    end
end

local function isPoisonedOrDiseased(targetId)
    if not targetId or targetId <= 0 then return false end

    -- VF: 1.
    local myId = 0
    pcall(function() myId = mq.TLO.Me.ID() or 0 end)
    if targetId == myId then
        -- VF: bar-scan only -- Me.Poisoned / Counters* stay dirty with a clean bar.
        if runtime.selfCureCounters then
            local c = runtime.selfCureCounters()
            if (c.poison or 0) > 0 or (c.disease or 0) > 0 then return true end
        end
        return false
    end

    -- VF: 2.
    local s = nil
    pcall(function() s = mq.TLO.Spawn(targetId) end)
    if not s or not s() then return false end

    local cleanName = ''
    pcall(function() cleanName = s.CleanName() or '' end)

    -- VF: 2a.
    if cleanName ~= '' then
        local nbP, nbD = 0, 0
        pcall(function()
            local nb = mq.TLO.NetBots(cleanName)
            if nb and nb() then
                nbP = tonumber(nb.Poisoned()) or 0
                nbD = tonumber(nb.Diseased()) or 0
                if nbP == 0 and nbD == 0 then
                    local det = tostring(nb.Detrimental() or '')
                    if det:find('Poison') or det:find('Disease') then
                        nbP = 1
                    end
                end
            end
        end)
        if nbP > 0 or nbD > 0 then return true end
    end

    -- VF: 2b.
    local isTarget = false
    pcall(function() isTarget = ((mq.TLO.Target.ID() or 0) == targetId) end)
    if isTarget then
        local tp, td = false, false
        pcall(function()
            local p = mq.TLO.Target.Poisoned
            if p and p() then
                local str = tostring(p())
                if str ~= '' and str ~= 'NULL' and str ~= 'nil' then
                    tp = true
                end
            end
        end)
        if tp then return true end

        pcall(function()
            local d = mq.TLO.Target.Diseased
            if d and d() then
                local str = tostring(d())
                if str ~= '' and str ~= 'NULL' and str ~= 'nil' then
                    td = true
                end
            end
        end)
        if td then return true end
    end

    return false
end

local function isAnyGroupMemberAfflicted()
    local myId = 0
    pcall(function() myId = mq.TLO.Me.ID() or 0 end)
    if myId > 0 and isPoisonedOrDiseased(myId) then return true end

    local grpCount = 0
    pcall(function() grpCount = mq.TLO.Group.Members() or 0 end)
    for i = 1, grpCount do
        local mid = nil
        pcall(function()
            local m = mq.TLO.Group.Member(i)
            if m and m() and not m.Dead() then
                mid = m.ID() or 0
            end
        end)
        if mid and mid > 0 and isPoisonedOrDiseased(mid) then
            return true
        end
    end
    return false
end

-- VF: row veto ? true = skip. Combat col, DoT/Debuff on-bar, HoT, Above/Below by role.
local function rowBlocked(entry, name, targetId)
    local typ = entry and (entry.cast_type or entry.t3_type)
    local role = runtime.castRole and runtime.castRole(entry) or typ
    -- VF: missing Combat col uses role default (Nuke/Melee?In Combat), not Always.
    local combat = entry and (entry.combat or entry.t3_combat)
    if combat == 'in combat' or combat == 'combat' then combat = 'In Combat' end
    if combat == 'out of combat' or combat == 'ooc' then combat = 'Out of Combat' end
    if combat == 'always' then combat = 'Always' end
    if combat ~= 'In Combat' and combat ~= 'Out of Combat' and combat ~= 'Always' then
        if role == 'Melee' or role == 'DoT' or role == 'Nuke' or role == 'Debuff' or role == 'CC'
            or role == 'PetHeal' or role == 'Tap' then
            combat = 'In Combat'
        elseif role == 'Buff' or role == 'PetBuff' or role == 'Summon' then
            combat = 'Out of Combat'
        else
            combat = 'Always'
        end
    end
    local inCs = false
    if runtime.engineInCombat then
        inCs = not not runtime.engineInCombat()
    elseif runtime.inCombatState then
        inCs = not not runtime.inCombatState()
    else
        pcall(function() inCs = mq.TLO.Me.CombatState() == 'COMBAT' end)
    end
    if combat == 'In Combat' and not inCs then return true end
    if combat == 'Out of Combat' and inCs then return true end
    if runtime.castIsMobEffect and runtime.castIsMobEffect(role)
        and runtime.targetEffectUp and runtime.targetEffectUp(name, targetId) then
        return true
    end
    if role == 'HoT' then
        local me = 0
        pcall(function() me = mq.TLO.Me.ID() or 0 end)
        local pct = tonumber(entry and entry.pct) or 100
        if pct <= 0 then return true end
        if me > 0 and pctHP(me) > pct then return true end
        if me > 0 and runtime.buffFactuallyUp and runtime.buffFactuallyUp(me, name) then
            return true
        end
    end
    -- VF: Above/Below by cast_type role ? not only `when` (unknown when fails open).
    local below = tonumber(entry and entry.pct) or 0
    local above = tonumber(entry and (entry.above or entry.t3_above))
    local selfBand = role == 'Heal' or role == 'Panic' or role == 'HoT' or role == 'Tap'
    local tgtBand = role == 'Nuke' or role == 'DoT' or role == 'Debuff' or role == 'Melee'
        or role == 'CC' or role == 'PetHeal'
    if selfBand or tgtBand then
        local hp = selfBand and pctHP(mq.TLO.Me.ID()) or pctHP(targetId)
        if below > 0 and hp > below then return true end
        if above and above > 0 and hp < above then return true end
    elseif (entry.when or '') == 'my Mana <=' then
        local mana = tonumber(mq.TLO.Me.PctMana()) or 100
        if above and above > 0 and mana < above then return true end
    end
    return false
end

local function conditionMet(when, pct, spellName, targetId, cls)
    pct = tonumber(pct) or 0
    if pct <= 0 then return false end
    if when == 'always' then
        -- VF: Persist / twist songs that are already on the song or buff bar stay up.
        if spellName and targetId and runtime.buffFactuallyUp and runtime.buffFactuallyUp(targetId, spellName) then
            return false
        end
        return true
    end
    if when == 'in combat' or when == 'twist while fighting' then return isCombat() end
    if when == 'my Mana <=' then return (tonumber(mq.TLO.Me.PctMana()) or 100) <= pct end
    -- VF: my HP <= gates caster HP (Heal / Panic / HoT / Tap). Tap still targets the mob.
    if when == 'my HP <=' then return pctHP(mq.TLO.Me.ID()) <= pct end
    if when == 'HP <=' or when == 'target HP <=' then return pctHP(targetId) <= pct end
    if when == 'missing buff' then
        -- VF: Blocked by X session latch ? do not keep casting a weaker stack.
        if runtime.buffSessionIsBlocked and runtime.buffSessionIsBlocked(spellName) then
            return false
        end
        return not runtime.buffFactuallyUp(targetId, spellName)
    end
    -- VF: this server: one pet per class. Check myPets[cls], never Me.Pet.
    -- VF: Familiar-style summons land as self buffs (: Permanent) — bar up = not missing.
    if when == 'missing pet' then
        local me = 0
        pcall(function() me = mq.TLO.Me.ID() or 0 end)
        if spellName and me > 0 and runtime.buffFactuallyUp and runtime.buffFactuallyUp(me, spellName) then
            return false
        end
        if not cls then
            local petId = mq.TLO.Me.Pet.ID()
            return not petId or petId == 0
        end
        return not isSpawnAlive(petState.myPets[cls])
    end
    if when == 'ally is Dead' then
        local s = mq.TLO.Spawn(targetId); return s() and s.Dead()
    end
    if when == 'has Poison/Disease' then
        -- VF: match Cure spell to counter kind (Remove Greater Curse ? disease).
        if runtime.hasCureNeed then
            return runtime.hasCureNeed(spellName, targetId)
        end
        return isPoisonedOrDiseased(targetId)
    end
    if when == 'add is loose' then
        local r = (ctrl and tonumber(ctrl.xtar_nav_dist)) or runtime.rushNear or 80
        return runtime.closestThreat(r, nil, true) ~= nil
    end
    -- VF: no gate authored on the row -- fires, as it always has.
    if when == nil or when == '' then return true end
    -- VF: an unknown gate must fail CLOSED, or a typo silently arms the row.
    -- VF: all 12 data.lua WHENS are handled above; warn once so a stale value is visible.
    runtime.badWhen = runtime.badWhen or {}
    if not runtime.badWhen[when] then
        runtime.badWhen[when] = true
        print(string.format("\ay[VF]\ax unknown cast gate '%s' -- row held. Re-pick When in Manager.",
            tostring(when)))
    end
    return false
end

isIdleSelfBuff = function(when, target)
    local tok = U.baseTok(target)
    return (when == 'missing buff' or when == 'always') and (tok == 'Myself' or tok == 'Self')
end

local function isCasting()
    if (runtime.bardHoldUntil or 0) > os.clock() then return true end
    local cid = nil
    pcall(function() cid = mq.TLO.Me.Casting.ID() end)
    if not (cid and cid > 0) then return false end
    -- VF: a held song bar is not a cast in progress. Server rule 3.
    if runtime.songBarHeld and runtime.songBarHeld() then return false end
    return true
end

-- VF: sung-vs-stand and the lane rules live in vft/song.lua so they can be tested offline.
runtime.bardCastSkill = Song.isSungSkill
runtime.songLane = Song.lane

-- VF: /vf songs -- the lane per gem, from the SERVER's Skill()/Beneficial(). A spell tagged with an
-- VF: instrument skill would cast while running and never land; this is how you see that, per row.
runtime.songReport = function()
    local myId = 0
    pcall(function() myId = mq.TLO.Me.ID() or 0 end)
    print('\ag[VF]\ax song lanes -- spell [skill] -> lane (spell=stand, song=sing, chant=holds bar)')
    for i = 1, D.NUM_GEMS do
        local g = loadout.gems[i]
        if g and g.spell and g.spell ~= '' then
            local skill, bene, dur = '', false, 0
            pcall(function()
                local sp = mq.TLO.Spell(g.spell)
                skill = tostring(sp.Skill() or '')
                bene = not not sp.Beneficial()
                dur = tonumber(sp.Duration()) or 0
            end)
            local lane = runtime.songLane(skill, bene)
            local up = 'n/a'
            if runtime.buffFactuallyUp and myId > 0 then
                up = tostring(runtime.buffFactuallyUp(myId, g.spell))
            end
            print(string.format('  %2d %-32s [%-22s] bene=%-5s dur=%-6s %s%-5s\ax up=%s',
                i, g.spell, skill, tostring(bene), tostring(dur),
                (lane == 'chant' and '\ar') or (lane == 'song' and '\ay') or '\ag',
                lane, up))
        end
    end
end

-- VF: sung damage keeps Me.Casting.ID() after the cast. Gating on it stalls every class. Detection only.
runtime.SONG_BAR_MARGIN = 1.25
runtime.songBar = { id = nil, since = 0, grace = 0 }

runtime.songBarHeld = function()
    local cid, skill = 0, ''
    pcall(function()
        cid = mq.TLO.Me.Casting.ID() or 0
        skill = mq.TLO.Me.Casting.Skill() or ''
    end)
    local sb = runtime.songBar
    if cid <= 0 or not runtime.bardCastSkill(skill) then
        sb.id = nil
        return false
    end
    if sb.id ~= cid then
        local ct = 0
        pcall(function()
            local sp = mq.TLO.Spell(cid)
            ct = tonumber(sp.MyCastTime()) or tonumber(sp.CastTime()) or 0
        end)
        if ct > 20 then ct = ct / 1000 end
        sb.id, sb.since, sb.grace = cid, os.clock(), ct + runtime.SONG_BAR_MARGIN
    end
    return (os.clock() - sb.since) > sb.grace
end

runtime.castingMustStand = function()
    -- VF: MQ2Cast pending / Timing ? Me.Casting can lag; do not walk off a heal.
    if ctrl and runtime.castBusy and runtime.castBusy() then return true end
    if (runtime.standCastUntil or 0) > os.clock() then return true end
    local cid, skill = 0, ''
    pcall(function()
        cid = mq.TLO.Me.Casting.ID() or 0
        skill = mq.TLO.Me.Casting.Skill() or ''
    end)
    if not cid or cid <= 0 then return false end
    return not runtime.bardCastSkill(skill)
end

-- VF: Spell fail events still mark tracker.failed; soft lockouts are off.
local castTracker = createCastTracker()

local function onFailureEvent(reason)
    castTracker.onFailureEvent(reason, ctrl and ctrl.cast_max_retries or 2, ctrl and ctrl.cast_lockout_sec or 30)
end

local function onCannotSeeEvent()
    onFailureEvent('cannot see target')
end

mq.event('TriuneFizzle', '#*#fizzle#*#', function() onFailureEvent('fizzled') end)
mq.event('TriuneInterrupt', '#*#interrupted#*#', function() onFailureEvent('interrupted') end)
mq.event('TriuneOutOfRangeSpell', '#*#out of range#*#', function() onFailureEvent('out of range') end)
mq.event('TriuneCannotSee', '#*#see your target#*#', onCannotSeeEvent)
mq.event('TriuneNoTakeHold', '#*#take hold#*#', function() onFailureEvent('did not take hold') end)
mq.event('TriuneImmuneSpell', '#*#immune#*#', function() onFailureEvent('target immune') end)
mq.event('TriuneDeadTargetSpell', '#*#dead target#*#', function() onFailureEvent('dead target') end)
mq.event('TriuneCantCast', '#*#cast spells while#*#', function() onFailureEvent('cannot cast') end)
mq.event('TriuneResisted1', '#*#resisted your#*#', function() onFailureEvent('resisted') end)
mq.event('TriuneResisted2', '#*#resisted the#*#', function() onFailureEvent('resisted') end)
mq.event('TriuneNotReady', '#*#not ready#*#', function() onFailureEvent('not ready') end)
mq.event('TriuneNoMana', '#*#enough mana#*#', function() onFailureEvent('insufficient mana') end)

-- VF: Power Source XP is chat-only -- no evolving-item TLO. Old-dev name, keep the parse.
runtime.refreshPowerSourceSlot = function()
    local item
    pcall(function()
        local slot = mq.TLO.Me.Inventory('PowerSource')
        if slot and slot() then item = slot end
    end)
    if not item then
        pcall(function()
            local slot = mq.TLO.Me.Inventory('Back')
            if slot and slot() then item = slot end
        end)
    end
    if not item then return end
    local name = ''
    pcall(function() name = item.Name() or '' end)
    if name ~= '' then runtime.psName = name end
    -- VF: If this server ever starts sending real evolving packets, prefer that.
    local evoPct
    pcall(function() evoPct = tonumber(item.Evolving.ExpPct()) end)
    if evoPct and evoPct > 0 and runtime.psSource ~= 'log' then
        runtime.psPct = evoPct
        runtime.psSource = 'evolving TLO'
        runtime.psAt = os.clock()
    end
end

runtime.onPowerSourceGrow = function(line, pctTok)
    line = tostring(line or '')
    local n = tonumber(tostring(pctTok or ''):match('([%d%.]+)'))
    if not n then
        n = tonumber(line:match('(%d+%.%d+)%%')) or tonumber(line:match('(%d+)%%'))
    end
    if not n then return end
    runtime.psPct = n
    runtime.psAt = os.clock()
    runtime.psSource = 'log'
    local name = line:match('%[([^%]]+)%]')
    if not name or name == '' then
        name = line:match('Your%s+(.-)%s+absorbs energy')
    end
    if name and name ~= '' then
        name = name:gsub('\018', '')
        name = name:gsub('^%x%x%x%x+', '')
        name = name:gsub('^%s+', ''):gsub('%s+$', '')
        if name ~= '' then runtime.psName = name end
    end
    if not runtime.psGrowAnnounced then
        runtime.psGrowAnnounced = true
        print(string.format('\ag[VF]\ax Power source hooked: %s at %.2f%%',
            tostring(runtime.psName or '?'), n))
    end
end

-- VF: MQ event pattern: no % or parens -- item links break captures. Parse in Lua.
pcall(function() mq.unevent('TriunePowerGrow') end)
pcall(function() mq.unevent('TriunePowerGrow2') end)
mq.event('TriunePowerGrow', '#*#absorbs energy#*#',
    function(line, a, b) runtime.onPowerSourceGrow(line, a or b) end)
mq.event('TriunePowerGrow2', '#*#faint shimmer#*#',
    function(line, a, b) runtime.onPowerSourceGrow(line, a or b) end)

-- VF: Single heals need a target after the mob dies. Unreadable TargetType keeps the old path.
runtime.selfCastNeedsTarget = function(sp)
    local tt = ''
    pcall(function() tt = tostring(sp.TargetType() or '') end)
    return tt ~= '' and tt ~= 'Self'
end

local function castGem(i, g, id)
    if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then
        mq.cmd('/stand')
        mq.delay(50)
    end
    if castTracker.isLockedOut(g.spell) then return false end
    local key = 'g' .. i
    if (os.clock() - (runtime.lastCast[key] or 0)) < 1.2 then return false end
    local sp = mq.TLO.Spell(g.spell)
    if not sp() then
        for _, n in ipairs(U.apostropheVariants(g.spell)) do
            pcall(function()
                local t = mq.TLO.Spell(n)
                if t and t() then sp = t end
            end)
            if sp() then break end
        end
    end
    if not sp() then return false end
    local isMemmed = false
    pcall(function()
        isMemmed = isGemMatching(i, g.spell) or (mq.TLO.Me.Gem(g.spell)() ~= nil)
    end)
    if not isMemmed then
        for _, n in ipairs(U.apostropheVariants(g.spell)) do
            pcall(function()
                if mq.TLO.Me.Gem(n)() ~= nil then isMemmed = true end
            end)
            if isMemmed then break end
        end
    end
    if not isMemmed then return false end -- not memmed
    if (mq.TLO.Me.CurrentMana() or 0) < (sp.Mana() or 0) then return false end
    if not g.ignore_min_mana and not ctrl.burn and (ctrl.min_mana_pct or 0) > 0 and (mq.TLO.Me.PctMana() or 100) < (ctrl.min_mana_pct or 0) then return false end
    local ready = false
    pcall(function() ready = not not mq.TLO.Me.SpellReady(i)() end)
    if not ready then
        pcall(function() ready = not not mq.TLO.Me.SpellReady(g.spell)() end)
    end
    if not ready then return false end

    local dur = 0
    pcall(function() dur = tonumber(sp.Duration()) or 0 end)
    dur = tonumber(dur) or 0
    if dur > 0 and buffActive(id, g.spell) then
        return false
    end

    -- VF: spell skill owns song vs stand ? not g.cls (Divine Might was mis-tagged Brd).
    local castSkill = ''
    pcall(function() castSkill = tostring(sp.Skill() or '') end)
    local isSongCast = runtime.bardCastSkill(castSkill)
    local castSlot = i
    if not isGemMatching(i, g.spell) then
        castSlot = 0
        for j = 1, D.NUM_GEMS do
            if isGemMatching(j, g.spell) then castSlot = j; break end
        end
        if castSlot == 0 then return false end
    end

    -- VF: beneficial songs sing (cast once, rule 2). Chants hold the bar (rule 3) -- parked on the Twist probe.
    if isSongCast then
        local bene = false
        pcall(function() bene = not not sp.Beneficial() end)
        if runtime.songLane(castSkill, bene) == 'chant' then
            local now = os.clock()
            if (now - (runtime.songStubWarnAt or 0)) > 30 then
                runtime.songStubWarnAt = now
                print(string.format('\ay[VF]\ax chant "%s" not sung -- no rotation yet (docs/PLUGIN_AUDIT.md).', g.spell))
            end
            return false
        end
    end

    local orig = mq.TLO.Target.ID() or 0

    castTracker.lastSpell   = g.spell
    castTracker.lastTime    = os.clock()
    castTracker.failed      = false
    castTracker.activeSpell = g.spell
    clearCursor()
    if ctrl.debug_mode then
        print(string.format('\ao[DEBUG cast]\ax Gem %d "%s" on target #%d (dist=%.1f, Me.Combat=%s)',
            castSlot, g.spell, id, distToId(id), tostring(mq.TLO.Me.Combat())))
    end

    -- VF: a held song bar reports an ID with an EMPTY Name. Gating the steal on Name skipped it,
    -- VF: and the /cast press was eaten by the locked bar -- the first spell after a song never landed.
    local barId = 0
    pcall(function() barId = mq.TLO.Me.Casting.ID() or 0 end)
    local when = g.when or ''
    local isHealGem = g.ooc_heal or g.kind == 'heal' or when == 'my HP <=' or when == 'HP <='
    if barId > 0 then
        freeBardBarForHeal(isHealGem and 'heal' or 'gem')
        barId = 0
        pcall(function() barId = mq.TLO.Me.Casting.ID() or 0 end)
        -- VF: the steal only clears SONG bars -- a real cast still in flight must still block us.
        if barId > 0 and not isHealGem then return false end
    end
    if (runtime.bardHoldUntil or 0) > os.clock() then
        runtime.bardHoldUntil = 0
    end

    -- VF: castPriority ? nil=rotation (no preempt); else may /interrupt if more urgent.
    local pri = runtime.castPriority and runtime.castPriority(g) or nil
    local canPre = not runtime.castCanPreempt or runtime.castCanPreempt(g)

    -- VF: cast helper owns press, Stick pause, landOn/restore.
    if (isCasting() or (runtime.castBusy and runtime.castBusy())) and not canPre then
        return false
    end
    -- VF: sung rows land while running -- no stopMoving, no stand hold. Ask the skill, never g.cls.
    if not isSongCast then
        local moving = false
        pcall(function() moving = not not mq.TLO.Me.Moving() end)
        if moving or (isMoveActive and isMoveActive()) then stopMoving() end
        local ct = 0
        pcall(function()
            ct = tonumber(sp.MyCastTime()) or tonumber(sp.CastTime()) or 0
        end)
        if ct > 20 then ct = ct / 1000 end
        runtime.standCastUntil = os.clock() + math.max(ct, 0.75) + 0.35
    end
    if not runtime.castStart then return false end
    if runtime.castBusy and runtime.castBusy() and not canPre then return false end
    local restore = (orig > 0 and orig ~= id) and orig or 0
    if not runtime.castStart({
        name = g.spell,
        kind = 'gem',
        gem = castSlot,
        landOn = id,
        restoreTarget = restore,
        priority = pri,
        sung = isSongCast,
    }) then
        return false
    end
    runtime.lastCast[key] = os.clock()
    petState.lastCastCls = g.cls
    return true
end

local function fireAA(name, a, id)
    name = U.trimName(name)
    -- VF: Battle Leap / Call of Challenge live on the Melee tab when catalogued.
    local delegated = false
    pcall(function()
        delegated = not not require('vft.mgr.melee_catalog').isDelegated(name)
    end)
    if delegated then return false end
    -- VF: Melee style — offensive /alt act before the swing eats /attack on.
    if (ctrl.combat_style or 'Melee') == 'Melee' then
        local swinging = false
        pcall(function() swinging = not not mq.TLO.Me.Combat() end)
        if not swinging and isDetrimentalAction(name, a and a.target, a) then
            return false
        end
    end
    if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then
        mq.cmd('/stand')
    end
    local key = 'a' .. name
    -- VF: instant AA dump relies on AltAbilityReady; keep only a short anti-double-tap.
    local aaInstantProbe = true
    do
        local okSp, sp0 = pcall(function() return mq.TLO.Me.AltAbility(name).Spell end)
        if okSp and sp0 and sp0() then
            local ms = 0
            pcall(function()
                local ct = sp0.MyCastTime() or sp0.CastTime()
                if type(ct) == 'number' then ms = ct
                else
                    local raw, ts
                    pcall(function() if ct.Raw then raw = ct.Raw() end end)
                    pcall(function() if ct.TotalSeconds then ts = ct.TotalSeconds() end end)
                    if raw ~= nil then ms = tonumber(raw) or 0
                    elseif ts ~= nil then ms = (tonumber(ts) or 0) * 1000
                    else ms = tonumber(ct) or 0 end
                end
                if ms > 0 and ms < 20 then ms = ms * 1000 end
            end)
            -- VF: <100ms = instant channel (TLO noise); real cast-time AAs share the gem bar.
            aaInstantProbe = ms < 100
        end
    end
    local lock = aaInstantProbe and 0.15 or 1.5
    if (os.clock() - (runtime.lastCast[key] or 0)) < lock then return false end
    local aa = mq.TLO.Me.AltAbility(name)
    if not aa() then return false end
    if (aa.Rank() or 0) <= 0 then return false end
    if not mq.TLO.Me.AltAbilityReady(name)() then return false end
    local ok, sp = pcall(function() return aa.Spell end)
    if ok and sp and sp() then
        local endCost = tonumber(sp.EnduranceCost()) or 0
        local manaCost = tonumber(sp.Mana()) or 0
        if endCost > 0 and (mq.TLO.Me.CurrentEndurance() or 0) < endCost then return false end
        if manaCost > 0 and (mq.TLO.Me.CurrentMana() or 0) < manaCost then return false end
    end
    local selfCast = (id == mq.TLO.Me.ID())
    local orig = mq.TLO.Target.ID() or 0
    clearCursor()
    -- VF: all loadout AAs through cast helper (instants + cast-time). Melee-catalog skipped above.
    if not runtime.castStart then return false end
    local pri = runtime.castPriority and runtime.castPriority(a) or nil
    local restore = (orig > 0 and orig ~= id) and orig or 0
    local needLand = (not selfCast) or (ok and sp and sp() and runtime.selfCastNeedsTarget(sp))
    local aaInstant = aaInstantProbe
    -- VF: instant AA = second channel ? never wait on gem pending. Cast-time AA shares spell channel.
    if not aaInstant then
        local canPre = not runtime.castCanPreempt or runtime.castCanPreempt(a)
        if runtime.castBusy and runtime.castBusy() and not canPre then return false end
    end
    if not runtime.castStart({
        name = name,
        kind = 'alt',
        aaId = aa.ID(),
        instant = aaInstant,
        landOn = needLand and id or nil,
        restoreTarget = restore,
        priority = pri,
    }) then
        return false
    end
    runtime.lastCast[key] = os.clock()
    petState.lastCastCls = a.cls
    print('\ag[VF]\ax AA fired: ' .. name)
    return true
end

-- VF: user before/after lines on item clickies — /cmd or cmd; /cmd2.
runtime.runSlashLines = function(text)
    text = tostring(text or '')
    if text == '' then return end
    for line in text:gmatch('[^\r\n]+') do
        for part in line:gmatch('[^;]+') do
            part = U.trimName(part)
            if part ~= '' then
                if part:sub(1, 1) ~= '/' then part = '/' .. part end
                mq.cmd(part)
            end
        end
    end
end

-- VF: clicky items via MQ2Cast when loaded, else /use "Name". Buff gates use Clicky.Spell, never item name.
runtime.itemClickSpell = function(name, entry)
    local sp = entry and entry.spell
    if type(sp) == 'string' then
        sp = U.trimName(sp)
        if sp ~= '' then return sp end
    end
    local out = ''
    pcall(function()
        local it = mq.TLO.FindItem('=' .. tostring(name or ''))
        if not (it and it()) then return end
        local clicky = it.Clicky
        if clicky and clicky() then
            local s = clicky.Spell
            if s and s() then out = tostring(s.Name() or s() or '') end
        end
        if (out == '' or out == 'NULL') and it.Spell and it.Spell() then
            out = tostring(it.Spell.Name() or it.Spell() or '')
        end
    end)
    if out == 'NULL' then out = '' end
    out = U.trimName(out)
    if out ~= '' and type(entry) == 'table' then entry.spell = out end
    return out
end

-- VF: missing-buff gate — keep_buff (mount blessing) if set, else the clicky spell.
runtime.itemBuffSpell = function(name, entry)
    local keep = entry and U.trimName(entry.keep_buff or '')
    if keep ~= '' then return keep end
    return runtime.itemClickSpell(name, entry)
end

local function fireItem(name, a, id)
    name = U.trimName(name)
    if not name or name == '' then return false end
    local role = runtime.castRole and runtime.castRole(a) or nil
    -- VF: Buff/heal clickies skip the swing gate — item name is not a Spell (spellClassInfo = det).
    local needSwing = role ~= 'Buff' and role ~= 'HoT' and role ~= 'Heal'
        and role ~= 'Cure' and role ~= 'Panic' and role ~= 'Summon'
        and role ~= 'PetBuff' and role ~= 'PetHeal'
    if needSwing and (ctrl.combat_style or 'Melee') == 'Melee' then
        local swinging = false
        pcall(function() swinging = not not mq.TLO.Me.Combat() end)
        local detName = name
        if runtime.itemClickSpell then
            local sp = runtime.itemClickSpell(name, a)
            if sp and sp ~= '' then detName = sp end
        end
        if not swinging and isDetrimentalAction(detName, a and a.target, a) then
            return false
        end
    end
    if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then
        mq.cmd('/stand')
    end
    local key = 'i' .. name
    if (os.clock() - (runtime.lastCast[key] or 0)) < 1.0 then return false end
    local it
    pcall(function() it = mq.TLO.FindItem('=' .. name) end)
    if (not it or not it()) and a and tonumber(a.item_id) then
        pcall(function() it = mq.TLO.FindItem(tonumber(a.item_id)) end)
    end
    if not it or not it() then return false end
    local left = 0
    pcall(function() left = tonumber(it.TimerReady()) or 0 end)
    if left > 0 then return false end
    -- VF: Charges() is 0 on unlimited clickies; only refuse spent charged items.
    local charges, maxCh = nil, nil
    pcall(function()
        charges = tonumber(it.Charges())
        if it.Clicky and it.Clicky() then
            maxCh = tonumber(it.Clicky.MaxCharges())
        end
    end)
    if maxCh and maxCh > 0 and charges == 0 then return false end
    -- VF: backfill Clicky.Spell onto the row so buff checks never use the item name.
    runtime.itemClickSpell(name, a)
    local tok = a and U.baseTok(a.target) or ''
    local myIdNow = 0
    pcall(function() myIdNow = mq.TLO.Me.ID() or 0 end)
    -- VF: Buff/HoT/self heals always land on Me ? never the kill target.
    local forceSelf = tok == 'Myself'
        or role == 'Buff' or role == 'HoT' or role == 'Heal'
        or role == 'Panic' or role == 'Cure' or role == 'Summon'
    if forceSelf and myIdNow > 0 then
        id = myIdNow
    end
    local orig = mq.TLO.Target.ID() or 0
    clearCursor()
    if not runtime.castStart then return false end
    local pri = runtime.castPriority and runtime.castPriority(a) or nil
    local restore = (orig > 0 and orig ~= id) and orig or 0
    local spOk, sp = false, nil
    pcall(function()
        if it.Clicky and it.Clicky() then
            sp = it.Clicky.Spell
            spOk = not not (sp and sp())
        end
    end)
    -- VF: Self TargetType normally skips aim; still pass -targetid|me for buff clickies.
    local needLand = forceSelf
        or (id ~= myIdNow)
        or (spOk and runtime.selfCastNeedsTarget and runtime.selfCastNeedsTarget(sp))
    local canPre = not runtime.castCanPreempt or runtime.castCanPreempt(a)
    if runtime.castBusy and runtime.castBusy() and not canPre then return false end
    if a and a.cmd_before and a.cmd_before ~= '' then
        runtime.runSlashLines(a.cmd_before)
        mq.delay(100)
    end
    local invWas = false
    pcall(function() invWas = not not mq.TLO.Window('InventoryWindow').Open() end)
    if not runtime.castStart({
        name = name,
        kind = 'item',
        landOn = needLand and id or nil,
        restoreTarget = restore,
        priority = pri,
    }) then
        return false
    end
    if a and a.cmd_after and a.cmd_after ~= '' then
        -- VF: 0.5s after /use so After (/dismount) lands after the click.
        mq.delay(500)
        runtime.runSlashLines(a.cmd_after)
    end
    -- VF: /use on a bag clicky opens InventoryWindow — put it back if we opened it.
    if not invWas then
        pcall(function()
            if mq.TLO.Window('InventoryWindow').Open() then
                mq.cmd('/windowstate InventoryWindow close')
            end
        end)
    end
    runtime.lastCast[key] = os.clock()
    if a then petState.lastCastCls = a.cls end
    print('\ag[VF]\ax item fired: ' .. name
        .. ((a and a.spell and a.spell ~= '') and (' (' .. a.spell .. ')') or ''))
    return true
end

-- VF: disc ready/fire live in ta/disc.lua (ActiveDisc wait signal).

-- VF: MOVEMENT. MQ2Nav when a mesh path exists, else native /face + forward.
-- VF: no /stick here -- MoveUtils is combat-only. See docs/COMBAT_MOVE_OFFLOAD.md.

-- VF: point-blank LoS exception. Must stay tighter than MELEE_RANGE or LoS is never checked.
local LOS_TRUST_RANGE = 8

maxMeleeDistance = function(id)
    local userDist = (ctrl and ctrl.melee_dist) or MELEE_RANGE
    local spawnReach = select(1, spawnMeleeMetrics(id))
    if spawnReach > 0 then
        -- VF: true melee ceiling is MaxRangeTo (large dragons are not userDist+10).
        return math.max(userDist, spawnReach)
    end
    return userDist
end

desiredRange = function(id)
    -- VF: Roam only. Rush IS the face pull -- honoring stand-back there made it
    -- VF: hold at range and never grab aggro, driven by a setting Rush never shows.
    if ctrl.mode == 'Roam' and ctrl.pull_stand_back then
        return ctrl.pull_engage_dist or 100
    end
    local style = ctrl and ctrl.combat_style or 'Melee'
    if style ~= 'Melee' then
        return ctrl.ranged_dist or 40
    end
    local edge = hitboxEdgeDist(id)
    if edge > 0 then return edge end
    local userDist = (ctrl and ctrl.melee_dist) or MELEE_RANGE
    local spawnReach = select(1, spawnMeleeMetrics(id))
    if spawnReach > 0 then
        return math.max(5, math.min(userDist, spawnReach - 2))
    end
    return math.max(5, math.floor(userDist - 2))
end

-- VF: Move to within `dist` of a spawn.
local LOS_FLICKER_GRACE = 2.5   -- treat LoS as still good this long after the last true reading (stairs flicker it)

-- VF: Spawn ids MQ2Nav has told us have no path to.
local function markUnreachable(id) pursuit.unreachableIds[id] = os.clock() end
isUnreachable = function(id)
    local t = pursuit.unreachableIds[id]
    if not t then return false end
    if (os.clock() - t) > 60 then
        pursuit.unreachableIds[id] = nil; return false
    end
    return true
end

-- VF: arrival requires LoS. Fails open if the TLO errors.


local function moveToward(id, dist, followOnly)
    if not id or id <= 0 then return false end
    if not followOnly and runtime.castingMustStand and runtime.castingMustStand() then
        return false
    end
    if runtime.navEscapedHold and runtime.navEscapedHold() then
        return false
    end
    local d = distToId(id)
    -- VF: Manual bubble unless this is the attack-commit chase (then Chase leash).
    local maxNav = (ctrl and ctrl.xtar_nav_dist) or 150
    local commitChase = runtime.manualCommitId and runtime.manualCommitId == id
    if not commitChase and ((not ctrl.running) or (ctrl and ctrl.mode == 'Manual')) then
        maxNav = math.min(maxNav, runtime.rushNear or 80)
    end
    if runtime.spawnWantsFight and runtime.spawnWantsFight(id) and d > maxNav then
        -- VF: Chase is a hard ceiling on the combat approach. Refusing in silence
        -- VF: reads in game as "it just stands there and never closes".
        if (os.clock() - (pursuit.chaseWarnAt or 0)) > 5 then
            pursuit.chaseWarnAt = os.clock()
            local label = commitChase and 'Chase' or (
                ((not ctrl.running) or (ctrl and ctrl.mode == 'Manual')) and 'Manual near' or 'Chase')
            print(string.format(
                '\ay[VF]\ax #%d is %.0f out, past %s %d -- not closing.',
                id, d, label, maxNav))
        end
        stopMoving()
        return false
    end
    if followOnly and ctrl and ctrl.mode == 'Group' then
        runtime.claimMover('travel')
    else
        runtime.claimMover('combat')
    end

    local isMelee = (not followOnly and (ctrl and ctrl.combat_style or 'Melee') == 'Melee')
    local targetDist = dist or (isMelee and desiredRange(id) or 18)
    local effectiveArrivalDist = targetDist + (isMelee and 2 or 3)

    -- VF: Update pursuit tracking for stall detection.
    if pursuit.id ~= id then
        pursuit.id = id; pursuit.bestDist = d; pursuit.improvedAt = os.clock()
        pursuit.navStalls = 0; pursuit.wasNavActive = false
        pursuit.lastLoSAt = 0
    elseif d < pursuit.bestDist - 2 then
        pursuit.bestDist = d; pursuit.improvedAt = os.clock()
        pursuit.navStalls = 0
    end

    local losNow = hasLoS(id)
    if losNow then pursuit.lastLoSAt = os.clock() end
    local losOk = losNow or (pursuit.lastLoSAt > 0 and (os.clock() - pursuit.lastLoSAt) < LOS_FLICKER_GRACE)

    -- VF: Stick.Stopped = within stick dist. Re-issue if this spawn's closeness changed.
    -- VF: losOk is required: stopped against a wall is not "arrived", and without
    -- VF: it this returns success and nothing below ever runs.
    if not followOnly and losOk and runtime.stickHolding(id) and runtime.stickStopped()
        and pursuit.stickId == id and pursuit.stickPct == runtime.stickCloseness(id) then
        if mq.TLO.Target.ID() ~= id then setTarget(id) end
        pursuit.lastNavTargetId = 0
        pursuit.id = 0
        return true
    end

    -- VF: already in MaxRangeTo — stick this spawn at its closeness; do not /nav into the box.
    if isMelee and d <= maxMeleeDistance(id) and (losOk or d <= LOS_TRUST_RANGE) then
        if not followOnly and runtime.canStickClose(id) and runtime.stickPursue(id, targetDist) then
            if mq.TLO.Target.ID() ~= id then setTarget(id) end
            pursuit.lastNavTargetId = 0
            pursuit.id = 0
            return true
        end
        if not runtime.stickHolding(id) then
            stopMoving()
        end
        if mq.TLO.Target.ID() ~= id then setTarget(id) end
        pursuit.lastNavTargetId = 0
        pursuit.id = 0
        return true
    end

    if d <= effectiveArrivalDist and (losOk or d <= LOS_TRUST_RANGE) then
        -- VF: stick holds the gap. Arrival without this spawn's /stick would keep the last mob's Dist.
        if not followOnly and runtime.canStickClose(id) and runtime.stickPursue(id, targetDist) then
            if mq.TLO.Target.ID() ~= id then setTarget(id) end
            pursuit.lastNavTargetId = 0
            pursuit.id = 0
            return true
        end
        if not (not followOnly and runtime.stickHolding(id)) then
            stopMoving()
        end
        if not followOnly then
            if mq.TLO.Target.ID() ~= id then setTarget(id) end
        end
        pursuit.lastNavTargetId = 0
        pursuit.id = 0
        return true
    end

    -- VF: water swim path disabled — never worked in combat (PoWater). Use normal stick/nav.
    --[[
    if (runtime.isInWater() or runtime.isWading()) and not isCombat() then
        local sx, sy, sz = 0, 0, 0
        pcall(function()
            local s = mq.TLO.Spawn(id)
            if s() then
                sx = s.X() or 0
                sy = s.Y() or 0
                sz = s.Z() or 0
            end
        end)
        if sx ~= 0 or sy ~= 0 then
            return runtime.moveThroughWater(sx, sy, sz, effectiveArrivalDist)
        end
    end
    --]]

    -- VF: inside stick_handoff -- stick only. Never /nav (fat mesh flaps under the hull).
    -- VF: EXCEPT with no LoS. A wall is the one thing /stick cannot solve -- it
    -- VF: walks the crow line into it and Stick.Stopped reads as arrived. Nav is
    -- VF: the only mover that paths around geometry, so let it through, and drop
    -- VF: stick first or the two movers fight over the feet.
    if not followOnly and d <= runtime.stickHandoff() then
        -- VF: Ranged past melee reach must nav to ranged_dist. /stick 70% is the face-bow.
        local bowHold = ctrl and ctrl.combat_style == 'Ranged' and d > maxMeleeDistance(id)
        if losOk and not bowHold then
            runtime.stickPursue(id, targetDist)
            return false
        end
        if runtime.stickHolding(id) then stopMoving() end
    end

    if navLoaded() then
        local ok = false
        pcall(function() ok = mq.TLO.Navigation.PathExists('id ' .. id)() end)
        if ok then
            local navActiveNow = mq.TLO.Navigation.Active()
            if pursuit.wasNavActive and not navActiveNow then
                pursuit.navStalls = pursuit.navStalls + 1
            end
            pursuit.wasNavActive = navActiveNow
            if pursuit.lastNavTargetId ~= id or not navActiveNow then
                mq.cmdf('/nav id %d distance=%d', id, math.floor(targetDist))
                pursuit.lastNavTargetId = id
            end
            return false
        end
        -- VF: off-mesh hunt target is skipped, not walked through walls. followOnly falls through.
        if not followOnly and ctrl and (ctrl.mode == 'Roam' or ctrl.mode == 'Rush') then
            print(string.format('\ay[VF]\ax no nav path to #%d -- skipping (wall / off-mesh).', id))
            markUnreachable(id)
            stopMoving()
            pursuit.id = 0
            pursuit.lastNavTargetId = 0
            return false
        end
    end

    -- VF: no open stick path ? do not /stick through walls across the zone.
    if not followOnly and runtime.canStickClose(id) and runtime.stickPursue(id, targetDist) then
        return false
    end
    if (os.clock() - (pursuit.noMoverWarnAt or 0)) > 5 then
        pursuit.noMoverWarnAt = os.clock()
        print(string.format(
            '\ay[VF]\ax cannot close on #%d -- need nav path or open stick approach.', id))
    end
    return false
end

-- VF: bow in the face: never /attack on the bow line.
-- VF: Manual/Pause: no autofire / melee swap until you armed the fight.
runtime.rangedFightTick = function(tid, mayClose)
    tid = tonumber(tid) or 0
    if tid <= 0 then return end
    if runtime.manualFightConsent and not runtime.manualFightConsent() then return end
    if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
    local d = distToId(tid)
    local stand = (ctrl and tonumber(ctrl.ranged_dist)) or 40
    local reach = maxMeleeDistance(tid)
    if reach < 8 then reach = 8 end
    if d <= reach then
        if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
        if runtime.ensureAttack then runtime.ensureAttack(tid) end
        -- VF: stickFollowTarget waits on Me.Combat -- first swap tick would not stick.
        if runtime.stickPursue then runtime.stickPursue(tid) end
        return
    end
    if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
    -- VF: bow heading is ours. MQ2Melee facing is a melee rail and stays off.
    local now = os.clock()
    if (now - (runtime.rangedFaceAt or 0)) > 0.35 then
        runtime.rangedFaceAt = now
        mq.cmdf('/face fast id %d', tid)
    end
    -- VF: slack so Rush/Group moveToward and this tick do not re-nav at stand+1.
    if d > stand + 4 then
        if mayClose and not (runtime.castingMustStand and runtime.castingMustStand()) then
            moveToward(tid, stand)
        end
        return
    end
    stopMoving()
    if not mq.TLO.Me.AutoFire() then mq.cmd('/autofire on') end
end

-- VF: a summon yanks us off-route mid-travel. Without this TA keeps navving back
-- VF: to the pin and issuing /attack off every tick while the mob beats on us.
mq.event('TriuneSummoned', '#*#have been summoned#*#', function()
    if runtime.onSummoned then runtime.onSummoned() end
end)

-- VF: swim/underwater — mesh /nav will not hold a tunnel; do not treat as dry.
runtime.isInWater = function()
    local wet = false
    pcall(function()
        if mq.TLO.Me.Underwater() then wet = true end
    end)
    if wet then return true end
    local st = ''
    pcall(function() st = string.upper(tostring(mq.TLO.Me.State() or '')) end)
    return st:find('SWIM', 1, true) and true or false
end

runtime.isWading = function()
    return false
    --[[
    local wading = false
    pcall(function()
        if mq.TLO.Me.FeetWet() and not mq.TLO.Me.Underwater() then wading = true end
    end)
    return wading
    --]]
end

-- VF: Travel = moving between camp/MA/Rush dest with no active fight.
runtime.isTravelMode = function()
    if not ctrl or not ctrl.running then
        -- VF: Map travelIgnore/Defend while paused still counts as travel for songs.
        if runtime.travel and runtime.travel.active and runtime.travel.active() then
            return runtime.travel.policy() == 'ignore'
        end
        return false
    end
    if runtime.travel and runtime.travel.active and runtime.travel.active()
        and runtime.travel.policy() == 'ignore' then
        return true
    end
    if runtime.rushDest and not (runtime.playerNav and runtime.playerNav.prep) then
        return true
    end
    if isCombat() then return false end
    -- VF: melee attack toggle = engagement, not engine state — still not "travel".
    -- VF: AutoFire is Ranged-style only (settings later), not a fight-state duplicate.
    if mq.TLO.Me.Combat() then return false end
    if stuckState.escapingUntil and os.clock() < stuckState.escapingUntil then return true end
    if ctrl.mode == 'Roam' then
        if isMoveActive() then
            return true
        end
    end
    if runtime.pullerRushing and runtime.pullerRushing() then
        return true
    end
    return false
end

runtime.moveThroughWater = function(x, y, z, dist)
    -- VF: disabled ? fall through to normal move.
    return false
    --[[
    dist = dist or 15
    local d = distToLoc(x, y, z)
    if d <= dist then
        stopMoving()
        pursuit.lastNavLoc = nil
        stuckState.wetTravelBest = nil
        stuckState.wetTravelStall = 0
        return true
    end

    local locStr = string.format('loc %.2f %.2f %.2f', y, x, z)
    local locKey = string.format('swim_%.1f_%.1f_%.1f', y, x, z)

    if navLoaded() then
        local navActive = false
        pcall(function() navActive = mq.TLO.Navigation.Active() or false end)
        local pathOk = false
        pcall(function() pathOk = mq.TLO.Navigation.PathExists(locStr)() end)
        if pathOk then
            if pursuit.lastNavLoc ~= locKey or not navActive then
                mq.cmdf('/nav %s', locStr)
                pursuit.lastNavLoc = locKey
            end
            return false
        end
    end

    mq.cmdf('/face fast loc %.2f,%.2f', y, x)
    local underwater = false
    pcall(function() underwater = mq.TLO.Me.Underwater() end)
    if underwater then
        local now = os.clock()
        if (now - (stuckState.lastSwimJump or 0)) > 1.2 then
            stuckState.lastSwimJump = now
            mq.cmd('/keypress jump')
        end
    end
    local isMoving = false
    pcall(function() isMoving = mq.TLO.Me.Moving() or false end)
    if not isMoving then
        mq.cmd('/keypress forward hold')
    end
    pursuit.lastNavLoc = locKey

    if not stuckState.wetTravelBest or d < stuckState.wetTravelBest - 2 then
        stuckState.wetTravelBest = d
        stuckState.wetTravelAt = os.clock()
        stuckState.wetTravelStall = 0
    elseif (os.clock() - (stuckState.wetTravelAt or 0)) > 10 then
        stuckState.wetTravelStall = (stuckState.wetTravelStall or 0) + 1
        stuckState.wetTravelAt = os.clock()
        stuckState.wetTravelBest = d
        if stuckState.wetTravelStall >= 2 then
            stopMoving() -- VF: water block still commented; was performUnstuck
            stuckState.wetTravelStall = 0
        end
    end
    return false
    --]]
end

-- VF: flat pin: z may be nil. distToLoc already drops Z.
local function moveTowardLoc(x, y, z, dist)
    if runtime.navEscapedHold and runtime.navEscapedHold() then return false end
    dist = dist or 15
    runtime.claimMover('travel')
    if distToLoc(x, y, z) <= dist then
        stopMoving()
        pursuit.lastNavLoc = nil
        return true
    end

    -- VF: water check needs a number, so a flat pin borrows our own Z here only.
    local zNum = z
    if zNum == nil then
        pcall(function() zNum = mq.TLO.Me.Z() or 0 end)
        zNum = zNum or 0
    end

    -- VF: swimming — do not /nav or stopMoving; mesh reissue froze the stroke every 2s.
    if runtime.isInWater and runtime.isInWater() then
        return false
    end

    -- VF: EQ order is Y X Z. Flat pins use locyx so climbing does not re-issue /nav.
    local locStr = runtime.navSpec(y, x, z)
    local locKey = runtime.navKey('', y, x, z)

    if navLoaded() then
        if runtime.navTravel(locStr, locKey) then return false end
        -- VF: A 3D pin with a stale Z can refuse where the flat spec walks fine.
        if z ~= nil and runtime.navTravel(runtime.navSpec(y, x, nil),
                                         runtime.navKey('flat_', y, x, nil)) then
            return false
        end
    end

    if navLoaded() and runtime.navNoPathKey ~= locKey then
        runtime.navNoPathKey = locKey
        print(string.format(
            '\ay[VF]\ax nav refused Y:%.1f X:%.1f%s (%s) -- stopping. Move that pin onto the mesh.',
            y, x, runtime.zLabel(z), locStr))
    end

    -- VF: travel is MQ2Nav only, and that includes no keypress walk. A pin nav refuses
    -- VF: is a bad pin, so face it and stop -- do not walk it through geometry.
    mq.cmdf('/face fast loc %.2f,%.2f', y, x)
    stopMoving()
    return false
end

-- VF: route.lua. ctrl/loadout are getters -- onCharacterChanged replaces both.
require('vft.route').install(runtime, {
    ctrl        = function() return ctrl end,
    loadout     = function() return loadout end,
    navLoaded   = navLoaded,
    saveLoadout = saveLoadout,
})

-- VF: travel policies before walk -- map Shift+LMB/RMB and Rush trip keep-alive.
require('vft.travel').install(runtime, {
    ctrl        = function() return ctrl end,
    pursuit     = pursuit,
    navLoaded   = navLoaded,
    stickLoaded = stickLoaded,
    stopMoving  = stopMoving,
    claimMover  = runtime.claimMover,
})

-- VF: walk.lua. Needs moveTowardLoc above.
require('vft.walk').install(runtime, {
    ctrl          = function() return ctrl end,
    pursuit       = pursuit,
    navLoaded     = navLoaded,
    stickLoaded   = stickLoaded,
    stopMoving    = stopMoving,
    moveTowardLoc = moveTowardLoc,
    isMoveActive  = isMoveActive,
})
pcall(runtime.applyZoneRoute)

runtime.recordSafeSpot = function()
    if mq.TLO.Me.Dead() then return end
    -- VF: was "skip if underwater" ? water disabled, always allow dry-path safe spots.
    -- if runtime.isInWater() and not runtime.isWading() then return end
    pcall(function()
        stuckState.lastSafeX = mq.TLO.Me.X()
        stuckState.lastSafeY = mq.TLO.Me.Y()
        stuckState.lastSafeZ = mq.TLO.Me.Z()
        stuckState.lastSafeAt = os.clock()
    end)
end

runtime.escapeToSafeSpot = function(reason)
    local now = os.clock()
    if (now - (stuckState.lastEscapeAt or 0)) < 8 then return false end
    stuckState.lastEscapeAt = now
    stopMoving()
    local tid = 0
    pcall(function() tid = mq.TLO.Target.ID() or 0 end)
    if tid > 0 then
        local tt = ''
        pcall(function() tt = mq.TLO.Target.Type() or '' end)
        if tt == 'NPC' then
            markUnreachable(tid)
            mq.cmd('/target clear')
        end
    end
    pursuit.id = 0
    pursuit.lastNavTargetId = 0
    pursuit.lastNavLoc = nil
    runtime.pullTargetId = 0
    runtime.pullState = 'IDLE'

    local x, y, z = stuckState.lastSafeX, stuckState.lastSafeY, stuckState.lastSafeZ
    local haveSafe = x and y and z and (now - (stuckState.lastSafeAt or 0)) < 300
    if not haveSafe and ctrl.hunter_combat_loc then
        x, y, z = ctrl.hunter_combat_loc.x, ctrl.hunter_combat_loc.y, ctrl.hunter_combat_loc.z
        haveSafe = x and y and z
    end
    -- VF: camp_loc gone with Puller Camp.
    print(string.format('\ay[VF]\ax %s -- moving to a safer spot.', tostring(reason or 'stuck')))
    if haveSafe then
        stuckState.escapingUntil = now + 15
        moveTowardLoc(x, y, z, 12)
        return true
    end
    -- VF: no keypress unstuck -- MoveUtils/Nav own recovery.
    stopMoving()
    return true
end

-- VF: live hostile we can swing — corpse / Dead / ignore are not.
runtime.swingTargetLive = function(id)
    if not id or id <= 0 then return false end
    if not isHostileTarget(id) then return false end
    if isUnreachable(id) then return false end
    local ok = false
    pcall(function()
        local s = mq.TLO.Spawn(id)
        if not s or not s() then return end
        if s.Dead and s.Dead() then return end
        local st = s.Type() or ''
        if st == 'Corpse' then return end
        if (tonumber(s.PctHPs()) or 1) <= 0 then return end
        if isIgnored(s.CleanName()) then return end
        ok = true
    end)
    return ok
end

-- VF: next swing = nearest wantsFight in the band. Group stays on assist.
runtime.nextSwingId = function(exclude)
    exclude = tonumber(exclude) or 0
    local near = runtime.rushNear or 80
    if ctrl.mode == 'Group' and ctrl.running then
        local assist = runtime.groupAssistMobId and runtime.groupAssistMobId() or nil
        if assist and assist ~= exclude and runtime.swingTargetLive(assist) then return assist end
        return nil
    end
    if ctrl.focus_adds and runtime.lowestLevelNear then
        local addId = select(1, runtime.lowestLevelNear(near, exclude))
        if addId and addId ~= exclude and runtime.spawnWantsFight(addId) then return addId end
    end
    return runtime.closestThreat(near, exclude)
end

-- VF: COMBAT_OWNERS consent. Manual/Pause: armed, commit, or you pressed attack.
-- VF: Auto modes always true. Far targeting is not consent. Unarmed = no AssistOn.
runtime.manualFightConsent = function()
    if not ctrl or not (ctrl.mode == 'Manual' or not ctrl.running) then return true end
    if runtime.manualFightArmed then return true end
    if (tonumber(runtime.manualCommitId) or 0) > 0 then return true end
    local swinging = false
    pcall(function() swinging = not not mq.TLO.Me.Combat() end)
    return swinging
end
runtime.consent = function()
    return runtime.manualFightConsent()
end

runtime.manualInMeleeReach = function(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    local d = distToId(id)
    local reach = 18
    if maxMeleeDistance then reach = maxMeleeDistance(id) or 18 end
    -- VF: MaxRangeTo can sit under true melee. 25u is the face-check in ensureAttack.
    if not (d <= reach or d <= 25) then return false end
    return runtime.swingLosOk(id, d)
end

-- VF: maySwing door. Unarmed Manual does not swing because you walked into reach.
runtime.swingAllowed = function(id)
    if not id or id <= 0 then return false end
    return runtime.manualFightConsent()
end

-- VF: inFight = live kill id this tick (E3 IsAssisting). Modes still return engage;
-- VF: melee and ranged read this bit. docs/COMBAT_OWNERS.md.
runtime.inFight = function()
    return (tonumber(runtime._assistId) or 0) > 0
end

runtime.mayClose = function(id)
    id = tonumber(id) or 0
    local assist = tonumber(runtime._assistId) or 0
    if assist <= 0 then return false end
    if id > 0 and id ~= assist then return false end
    if (ctrl.combat_style or 'Melee') ~= 'Melee' then return false end
    if runtime.castingMustStand and runtime.castingMustStand() then return false end
    if ctrl.mode == 'Manual' or not ctrl.running then
        return (tonumber(runtime.manualCommitId) or 0) == assist
    end
    return true
end

-- VF: snapshot AssistTargetID after mode ticks. Auto: haveNPC is enough.
-- VF: Manual/Pause needs mode engage (armed path), not a look-at.
runtime.setAssist = function(haveNPC, engage)
    local tid = 0
    pcall(function() tid = tonumber(mq.TLO.Target.ID()) or 0 end)
    local live = haveNPC and tid > 0
        and runtime.swingTargetLive and runtime.swingTargetLive(tid)
    local ok = live and runtime.manualFightConsent()
    if ok then
        if ctrl.mode == 'Manual' or not ctrl.running then
            if not engage then live = false end
        end
    end
    runtime._assistId = (ok and live and tid) or 0
    return runtime._assistId
end

-- VF: in reach through a WALL is not in reach. The ONE owner of that rule -- it was
-- VF: written inline in combatTick, so the chainSwing and pulseMeleeAttack paths
-- VF: reached ensureAttack without it. Do not re-add a second copy: any new
-- VF: exception belongs here, and LOS_TRUST_RANGE is the only one there is.
-- VF: Note Me.Combat() is NOT an exception -- it is true for the whole fight, so
-- VF: trusting it would disable this gate exactly when it matters.
runtime.swingLosOk = function(id, dist)
    id = tonumber(id) or 0
    if id <= 0 then return true end
    local d = tonumber(dist) or distToId(id)
    -- VF: point-blank readings flicker in melee; trust the distance under the trust
    -- VF: range. Above it a false reading means geometry, and moveToward navs around.
    if d <= LOS_TRUST_RANGE then return true end
    return hasLoS(id) and true or false
end

-- VF: a hater we cannot kill or reach would otherwise hold every travel leg forever,
-- VF: which is far worse than the dropped swing this guard exists to prevent.
runtime.ATTACK_HOLD_MAX = 10

-- VF: the ONE owner of "may I drop /attack right now". Six sites decided this for
-- VF: themselves with the guard at the CALL site, so each new one forgot -- the comment
-- VF: on TriuneSummoned is the result: navving back to the pin and issuing /attack off
-- VF: every tick while the mob beats on us. Only usable now that spawnIsOnMe means real
-- VF: aggro; when it aliased spawnWantsFight it was true for half the zone.
-- VF: Explicit intent does NOT come through here -- safe zone and Escape are commands,
-- VF: not inferences, and they must always release.
runtime.attackReleaseOk = function()
    local combatOn = false
    pcall(function() combatOn = not not mq.TLO.Me.Combat() end)
    if not combatOn then
        runtime.attackHoldSince = nil
        return true
    end

    -- VF: current target first -- one spawn, and aggroSignal has stronger evidence for
    -- VF: it (ToT / AggroHolder / PctAggro) than the hate list alone.
    local held = false
    local tid = 0
    pcall(function() tid = tonumber(mq.TLO.Target.ID()) or 0 end)
    if tid > 0 and runtime.spawnIsOnMe and runtime.spawnIsOnMe(tid) then held = true end

    -- VF: then the hate list, which is cached 0.25s. Positive-only by design: a full
    -- VF: auto-hater list means an absent id proves nothing, so this only ever holds.
    if not held and runtime.xtargetHaters then
        local band = (ctrl and tonumber(ctrl.xtar_nav_dist)) or 150
        for id in pairs(runtime.xtargetHaters()) do
            if isSpawnAlive(id) and distToId(id) <= band then
                held = true
                break
            end
        end
    end

    if not held then
        runtime.attackHoldSince = nil
        return true
    end
    local now = os.clock()
    runtime.attackHoldSince = runtime.attackHoldSince or now
    -- VF: cap it. Better to lose the swing than to park mid-route indefinitely.
    if (now - runtime.attackHoldSince) >= runtime.ATTACK_HOLD_MAX then return true end
    return false
end

-- VF: /attack on this id if in reach or on-me. No acquire. No delay.
runtime.ensureAttack = function(id)
    if mq.TLO.Me.Dead() then return false end
    if (ctrl.combat_style or 'Melee') ~= 'Melee' then return false end
    if runtime.meleeEnrageHold and runtime.meleeEnrageHold() then return false end
    if not runtime.swingTargetLive(id) then return false end
    if not runtime.swingAllowed(id) then return false end
    local d = distToId(id)
    local reach = maxMeleeDistance(id)
    -- VF: /attack only in reach, or a wantsFight spawn in our face (MaxRangeTo can lie).
    if not (d <= reach or (d <= 25 and runtime.spawnWantsFight and runtime.spawnWantsFight(id))) then
        return false
    end
    -- VF: pass d -- swingLosOk would otherwise re-run distToId on every pulse.
    if not runtime.swingLosOk(id, d) then return false end
    if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then
        mq.cmd('/stand')
        return true
    end
    -- VF: before the Combat() early-out, not after -- the flap happens while attack is
    -- VF: already on, and MQ2Melee Overrides it off every pulse until its own MeleeTarg
    -- VF: matches ours.
    if runtime.meleeClaimTarget then runtime.meleeClaimTarget(id) end
    if mq.TLO.Me.Combat() then return true end
    mq.cmd('/attack on')
    if runtime.lastEnsureId ~= id then
        runtime.lastEnsureId = id
        print(string.format('\ag[VF]\ax Engaging /attack on -> %s (#%d) [dist=%.1f reach=%.1f]',
            tostring(mq.TLO.Target.CleanName()), id, d, reach))
    end
    return true
end

-- VF: /target id with no wait; re-arm attack. VFT owns the id — do not stopMoving (drops stick).
runtime.claimFightTarget = function(id)
    if not runtime.swingTargetLive(id) then return false end
    if not runtime.swingAllowed(id) and not (ctrl.running and ctrl.mode ~= 'Manual') then
        return false
    end
    local cur = 0
    pcall(function() cur = mq.TLO.Target.ID() or 0 end)
    if cur ~= id then
        mq.cmdf('/target id %d', id)
    end
    if ctrl.mode == 'Manual' or not ctrl.running then
        runtime.manualCommitId = id
        runtime.manualFightArmed = true
    end
    runtime.ensureAttack(id)
    return true
end

-- VF: corpse / empty target → next wantsFight in band, then /attack on.
runtime.chainSwing = function()
    local tid = 0
    pcall(function() tid = mq.TLO.Target.ID() or 0 end)
    if runtime.swingTargetLive(tid) then
        return runtime.claimFightTarget(tid)
    end
    local nxt = runtime.nextSwingId(tid)
    if not nxt then return false end
    return runtime.claimFightTarget(nxt)
end

-- VF: ensure attack when in range. No stuck keypress ladder.
-- VF: Pulsed every main-loop delay (~150ms) — combatTick alone is 0.4s and misses stand→attack.
runtime.pulseMeleeAttack = function()
    if mq.TLO.Me.Dead() then return false end
    if (ctrl.combat_style or 'Melee') ~= 'Melee' then return false end
    if runtime.meleeEnrageHold and runtime.meleeEnrageHold() then return false end
    -- VF: Rush/ignore transit owns feet — unless Manual is already in the pack.
    if runtime.pullerRushing and runtime.pullerRushing() then return false end
    local manualHot = runtime.manualFightArmed
        or ((tonumber(runtime.manualCommitId) or 0) > 0)
        or (mq.TLO.Me.Combat() and true or false)
    if runtime.rushOnTheMove and runtime.rushOnTheMove() and not manualHot then
        return false
    end
    -- VF: Group idle — do not steal a player click (vendor / quest) or /attack it.
    if ctrl.mode == 'Group' and ctrl.running then
        local assist = runtime.groupAssistMobId and runtime.groupAssistMobId() or nil
        local catchingUp = false
        pcall(function()
            local tr = runtime.travel
            local r = tr and tr.resume and tr.resume()
            local t = tr and tr.trip and tr.trip()
            catchingUp = (r and r.groupCatchup) or (t and t.groupCatchup) or false
        end)
        if not assist and not catchingUp then
            return false
        end
    end
    -- VF: Roam only -- see desiredRange.
    if ctrl.mode == 'Roam' and ctrl.pull_stand_back then return false end
    -- VF: corpse → next wantsFight, then /attack on. Keep stick if already swinging.
    if runtime.chainSwing() then
        if mq.TLO.Me.Combat() and runtime.stickFollowTarget then
            runtime.stickFollowTarget()
        end
        return true
    end
    local tid = 0
    pcall(function() tid = mq.TLO.Target.ID() or 0 end)
    local inCs = runtime.engineInCombat and runtime.engineInCombat()
    local onMe = tid > 0 and runtime.spawnIsOnMe and runtime.spawnIsOnMe(tid)
    if not onMe and not inCs then
        local closing = false
        pcall(function()
            local tr = runtime.travel
            local t = tr and tr.trip and tr.trip()
            closing = t and t.spawnId and t.spawnId > 0
        end)
        if not closing and runtime.stickHolding and runtime.stickHolding(tid) then
            stopMoving()
        end
    end
    return false
end

local function checkCombatStall()
    if runtime.pulseMeleeAttack and runtime.pulseMeleeAttack() then return end
    -- VF: Ranged keep-alive (Melee handled by pulseMeleeAttack).
    if runtime.manualFightConsent and not runtime.manualFightConsent() then return end
    local t = mq.TLO.Target
    local haveLiveNPC = t() and (t.Type() == 'NPC' or t.Type() == 'Pet') and not t.Dead() and t.Type() ~= 'Corpse'
    if not haveLiveNPC or not isHostileTarget(t.ID()) then return end
    if ctrl.combat_style == 'Ranged' and runtime.rangedFightTick then
        local id = t.ID()
        local mayWalk = (ctrl.mode ~= 'Manual')
            or ((tonumber(runtime.manualCommitId) or 0) == id)
            or runtime.manualFightArmed
        runtime.rangedFightTick(id, mayWalk)
    end
end

-- VF: self-directed target pick. Never used for a target you pick.
runtime.npcLevelBand = function()
    if ctrl.hunter_level_rel ~= false then
        local meLvl = 1
        pcall(function() meLvl = tonumber(mq.TLO.Me.Level()) or 1 end)
        if meLvl < 1 then meLvl = 1 end
        local lo = tonumber(ctrl.hunter_rel_min) or 0
        local hi = tonumber(ctrl.hunter_rel_max) or 5
        if lo > hi then lo, hi = hi, lo end
        return math.max(1, meLvl + lo), math.min(120, meLvl + hi)
    end
    return ctrl.hunter_min_level or 1, ctrl.hunter_max_level or 100
end

local function findRoamTarget(searchRadius, searchMaxZ, minLevel, maxLevel)
    local bandMin, bandMax = runtime.npcLevelBand()
    local minLv        = minLevel or bandMin
    local maxLv        = maxLevel or bandMax

    local anchorLoc    = ctrl.hunter_combat_loc
    local anchorRadius = (anchorLoc and (ctrl.hunter_combat_radius or 0) or 0)

    -- VF: Explicit Y/X handling to account for EQ's (Y, X) standard.
    local function outsideAnchor(sy, sx)
        if anchorRadius <= 0 or not anchorLoc then return false end
        local ay = anchorLoc.y or anchorLoc[1] or 0
        local ax = anchorLoc.x or anchorLoc[2] or 0
        local dy = sy - ay
        local dx = sx - ax
        return (dx * dx + dy * dy) > (anchorRadius * anchorRadius)
    end

    local defaultRadius = ctrl.hunter_radius or 1500
    local radius = searchRadius or defaultRadius
    local maxZ   = searchMaxZ or (ctrl.hunter_z or 75)
    local myZ    = mq.TLO.Me.Z() or 0

    runtime.meshPathFails = 0

    -- VF: 1. Already in a fight nearby — take that over a fresh hunt pick.
    local maxChase = (ctrl and ctrl.xtar_nav_dist) or 150
    local fightId = runtime.closestThreat and runtime.closestThreat(maxChase)
    if fightId then
        local fs = mq.TLO.Spawn(fightId)
        if fs and fs() then
            local lvl = fs.Level() or 0
            local okZ, fz = pcall(function() return fs.Z() end)
            if lvl >= minLv and lvl <= maxLv
                and (okZ and fz and math.abs(fz - myZ) <= maxZ)
                and isPullAllowed(fs.CleanName())
                and not isUnreachable(fightId)
                and not outsideAnchor(fs.Y() or 0, fs.X() or 0) then
                return fightId
            end
        end
    end

    -- VF: 2.
    local function scanSpawns(zLimit)
        local search = string.format('npc targetable radius %d', radius)
        for i = 1, 300 do
            local s = mq.TLO.NearestSpawn(i, search)
            if not (s and s()) then break end
            local sid = s.ID() or 0
            if sid > 0 then
                local stype = s.Type() or ''
                if stype == 'NPC' and not s.Dead() and stype ~= 'Corpse' then
                    if not isAnyPet(s) and not isSpawnPetOrPlayer(sid) and isHostileTarget(sid) then
                        local lvl = s.Level() or 0
                        if lvl >= minLv and lvl <= maxLv then
                            local okZ, sz = pcall(function() return s.Z() end)
                            if okZ and sz and math.abs(sz - myZ) <= zLimit then
                                local sy, sx = s.Y() or 0, s.X() or 0
                                if not outsideAnchor(sy, sx) then
                                    if isPullAllowed(s.CleanName()) and isConAllowed(s) and not isUnreachable(sid) then
                                        local pathOk = true
                                        if navLoaded() then
                                            local meshOk, meshLoaded = pcall(function() return mq.TLO.Navigation.MeshLoaded() end)
                                            if meshOk and meshLoaded then
                                                local dist = s.Distance3D() or 999
                                                if dist > 25 then
                                                    local hasPath = false
                                                    local ok = pcall(function() hasPath = mq.TLO.Navigation.PathExists('id ' .. sid)() end)
                                                    if ok and not hasPath then
                                                        pathOk = false
                                                        runtime.meshPathFails = (runtime.meshPathFails or 0) + 1
                                                    end
                                                end
                                            end
                                        end
                                        if pathOk then
                                            return sid
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        return nil
    end

    -- VF: Z-plane pick: same floor first, then hunter_z.
    local floorZ = ctrl.hunter_z_plane or 15
    local tier1Z = math.min(floorZ, maxZ)
    local targetId = scanSpawns(tier1Z)
    if targetId then return targetId end

    -- VF: Tier 2: Expand to full maxZ range if no target on immediate floor.
    if maxZ > tier1Z then
        targetId = scanSpawns(maxZ)
        if targetId then return targetId end
    end

    return nil
end
local function checkCloserTarget(curTargetId, searchRadius, searchMaxZ, minLevel, maxLevel)
    if not curTargetId or curTargetId <= 0 then return nil end
    if ctrl.check_closer_mobs == false then return nil end
    if pursuit.hasRetargeted then return nil end

    local bandMin, bandMax = runtime.npcLevelBand()
    local minL = minLevel or bandMin
    local maxL = maxLevel or bandMax
    local maxZ = searchMaxZ or (ctrl.hunter_z or 75)

    local curDist = distToId(curTargetId)
    if curDist <= 35 or mq.TLO.Me.Combat() then return nil end

    local candId = findRoamTarget(searchRadius, maxZ, minL, maxL)
    if candId and candId ~= curTargetId then
        local candDist = distToId(candId)
        if candDist <= (curDist - 25) and candDist <= (curDist * 0.75) then
            return candId, candDist, curDist
        end
    end
    return nil
end


-- VF: the client's own hate list. TargetType 'Auto Hater' means exactly "this mob
-- VF: has me on its hate list", and it is the ONLY direct answer EQ gives for a mob
-- VF: that is not our current target. This is the XTarget TLO used to VERIFY aggro;
-- VF: it is not the XTarget window scrape that was removed from target PICKING --
-- VF: nothing here chooses what to fight (see closestThreat).
-- VF: Auto-hater slots can fill, so an absent id is NOT proof of no aggro. Only ever
-- VF: read this as a positive, never as a veto.
runtime._xtHate = { at = 0, ids = {}, slots = nil }
runtime.xtargetHaters = function()
    local c = runtime._xtHate
    local now = os.clock()
    -- VF: the slot list churns every combat round; 4x/sec is plenty and keeps this
    -- VF: off the per-spawn hot path in closestThreat.
    if (now - c.at) < 0.25 then return c.ids end
    c.at = now
    local out = {}
    pcall(function()
        local slots = tonumber(mq.TLO.Me.XTargetSlots()) or 0
        c.slots = slots
        for i = 1, math.min(slots, 25) do
            local x = mq.TLO.Me.XTarget(i)
            if x and x() then
                local tt = ''
                pcall(function() tt = tostring(x.TargetType() or '') end)
                if tt == 'Auto Hater' then
                    local xid = tonumber(x.ID()) or 0
                    if xid > 0 then out[xid] = true end
                end
            end
        end
    end)
    c.ids = out
    return out
end

-- VF: returns hasAggro, which-signal. /vf aggro prints the signal, so a live
-- VF: disagreement is something you read instead of guess at. Ordered strongest
-- VF: first; AggroHolder and PctAggro exist ONLY on target, never on spawn --
-- VF: the old off-target branch read Spawn.AggroHolder and was always nil.
runtime.aggroSignal = function(targetId)
    targetId = tonumber(targetId) or 0
    if targetId == 0 then return false, 'no id' end
    local myId = mq.TLO.Me.ID() or 0
    if myId == 0 then return false, 'no me' end

    if runtime.xtargetHaters()[targetId] then return true, 'xtarget auto-hater' end

    local t = mq.TLO.Target
    local isCur = false
    pcall(function() isCur = (t() and (t.ID() or 0) == targetId) and true or false end)
    if isCur then
        local totId, ahId, pct = 0, 0, 0
        pcall(function() totId = tonumber(t.TargetOfTarget.ID()) or 0 end)
        if totId == myId then return true, 'target-of-target is me' end
        pcall(function() ahId = tonumber(t.AggroHolder.ID()) or 0 end)
        if ahId == myId then return true, 'aggro holder is me' end
        pcall(function() pct = tonumber(t.PctAggro()) or 0 end)
        if pct >= 100 then return true, 'pct aggro 100' end
        local inCombat, d, hp = false, 999, 100
        pcall(function() inCombat = not not mq.TLO.Me.Combat() end)
        pcall(function() d = tonumber(t.Distance3D()) or 999 end)
        pcall(function() hp = tonumber(t.PctHPs()) or 100 end)
        -- VF: weakest tier -- we are swinging, it is in our face, and it is hurt.
        if inCombat and d <= 25 then
            if pct > 0 then return true, 'in melee, pct aggro ' .. tostring(pct) end
            if hp < 100 then return true, 'in melee, target hurt' end
        end
        return false, 'target: no aggro signal'
    end

    -- VF: off target and the hate list is silent. If XTarget reports slots at all
    -- VF: then it works here, and its silence is the answer -- closestThreat runs
    -- VF: this per candidate every tick, so probing 20 spawns is not worth covering
    -- VF: the one edge case (a full hate list).
    if (tonumber(runtime._xtHate.slots) or 0) > 0 then
        return false, 'off target: not on hate list'
    end

    -- VF: no XTarget on this server. Spawn.TargetOfTarget is all that is left;
    -- VF: MQ2MoveUtils and MQ2Melee both read that struct field as "who this spawn
    -- VF: is fighting".
    local totId = 0
    pcall(function()
        local s = mq.TLO.Spawn(targetId)
        if s and s() then totId = tonumber(s.TargetOfTarget.ID()) or 0 end
    end)
    if totId == myId then return true, 'spawn target-of-target is me' end
    return false, 'off target: no aggro signal'
end

local function playerHasAggro(targetId)
    local yes = runtime.aggroSignal(targetId)
    return yes
end

-- VF: /vf aggro — what every aggro signal says right now. This exists because
-- VF: "is it on me" is not directly observable in game: the client shows a hate
-- VF: list but the engine reads four different signals to build one answer, and
-- VF: when retargeting misbehaves you need to know which one lied.
runtime.aggroReport = function()
    local myId = 0
    pcall(function() myId = tonumber(mq.TLO.Me.ID()) or 0 end)
    local haters = runtime.xtargetHaters()
    local slots = tonumber(runtime._xtHate.slots) or 0
    print(string.format('\ag[VF]\ax aggro report -- me #%d, XTarget slots %d%s',
        myId, slots,
        slots == 0 and ' \ay(no XTarget: falling back to Spawn.TargetOfTarget)\ax' or ''))

    local n = 0
    for _ in pairs(haters) do n = n + 1 end
    print(string.format('  hate list: %d auto-hater slot(s)', n))
    for id in pairs(haters) do
        local nm, d = '?', -1
        pcall(function()
            local s = mq.TLO.Spawn(id)
            if s and s() then
                nm = tostring(s.CleanName() or '?')
                d = tonumber(s.Distance3D()) or -1
            end
        end)
        print(string.format('    #%d %s @%.0f', id, nm, d))
    end

    local tid = 0
    pcall(function() tid = tonumber(mq.TLO.Target.ID()) or 0 end)
    if tid <= 0 then
        print('  target: none')
    else
        local yes, why = runtime.aggroSignal(tid)
        local nm = '?'
        pcall(function() nm = tostring(mq.TLO.Target.CleanName() or '?') end)
        print(string.format('  target #%d %s -> onMe=%s (%s)', tid, nm, tostring(yes), why))
        print(string.format('    isHostileTarget=%s wantsFight=%s isAggro=%s',
            tostring(runtime.isHostileTarget and runtime.isHostileTarget(tid)),
            tostring(runtime.spawnWantsFight and runtime.spawnWantsFight(tid)),
            tostring(runtime.spawnIsAggro and runtime.spawnIsAggro(tid))))
        local d, reach, los = -1, -1, nil
        pcall(function() d = tonumber(mq.TLO.Target.Distance3D()) or -1 end)
        pcall(function() los = not not mq.TLO.Target.LineOfSight() end)
        if runtime.maxMeleeDistance then reach = runtime.maxMeleeDistance(tid) or -1 end
        -- VF: the gates ensureAttack actually applies, in its order.
        print(string.format('    dist3D=%.1f reach=%.1f rawLoS=%s', d, reach, tostring(los)))
        print(string.format('    live=%s allowed=%s losGate=%s -> in reach=%s',
            tostring(runtime.swingTargetLive and runtime.swingTargetLive(tid)),
            tostring(runtime.swingAllowed and runtime.swingAllowed(tid)),
            tostring(runtime.swingLosOk and runtime.swingLosOk(tid)),
            tostring(d >= 0 and reach >= 0 and d <= reach)))
    end

    local band = tonumber(ctrl and ctrl.xtar_nav_dist) or 150
    local onMe = runtime.closestMobOnMe and runtime.closestMobOnMe(band) or nil
    local threat = runtime.closestThreat and runtime.closestThreat(band) or nil
    print(string.format('  in %d: closestMobOnMe=%s closestThreat=%s',
        band, tostring(onMe), tostring(threat)))
end

-- VF: /vf why -- pulse hold vs first ensureAttack gate, plus stick/nav/Melee context.
-- VF: docs/COMBAT_OWNERS.md. Does not issue /attack or /stick. Do not call pullerRushTick here.
runtime.whyFight = function()
    local mode = tostring(ctrl and ctrl.mode or '?')
    local running = not not (ctrl and ctrl.running)
    local style = (ctrl and ctrl.combat_style) or 'Melee'
    local tid, nm = 0, 'none'
    pcall(function()
        tid = tonumber(mq.TLO.Target.ID()) or 0
        if tid > 0 then nm = tostring(mq.TLO.Target.CleanName() or '?') end
    end)
    print(string.format('\ag[VF]\ax why -- mode=%s running=%s style=%s tgt=#%d %s',
        mode, tostring(running), style, tid, nm))

    local pulse, atk
    local function take(slot, msg)
        if not slot then return msg end
        return slot
    end

    local dead, swinging, sit = false, false, false
    pcall(function()
        dead = not not mq.TLO.Me.Dead()
        swinging = not not mq.TLO.Me.Combat()
        sit = not not (mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking())
    end)
    local packHot = not not runtime.manualFightArmed
        or ((tonumber(runtime.manualCommitId) or 0) > 0)
        or swinging
    if runtime.navEscapedHold and runtime.navEscapedHold() then
        pulse = take(pulse, 'navEscapedHold (Escape)')
    end
    if runtime.rushOnTheMove and runtime.rushOnTheMove() and not packHot then
        pulse = take(pulse, 'rushOnTheMove (travel owns feet)')
    end
    if runtime.pullerRushing and runtime.pullerRushing() then
        pulse = take(pulse, 'Rush travel (pullerRushing)')
    end
    pcall(function()
        local tr = runtime.travel
        if tr and tr.active and tr.active() then
            pulse = take(pulse, 'travel.active (trip owns feet)')
        end
    end)
    if ctrl and ctrl.mode == 'Group' and ctrl.running then
        local assist = runtime.groupAssistMobId and runtime.groupAssistMobId() or nil
        if not assist then
            pulse = take(pulse, 'Group idle (no assist mob -- pulseMeleeAttack skips)')
        end
    end
    if ctrl and ctrl.mode == 'Roam' and ctrl.pull_stand_back then
        pulse = take(pulse, 'Roam pull_stand_back (melee block skipped)')
    end
    local st = runtime.currentState and runtime.currentState() or '?'
    local engineCombat = (st == 'combat')
    pcall(function()
        if mq.TLO.Me.CombatState() == 'COMBAT' then engineCombat = true end
    end)
    local fightHot = runtime.engineFightHot and runtime.engineFightHot() or false
    local aggro = runtime.aggroOnMe and runtime.aggroOnMe() or false
    if not engineCombat and not fightHot and not aggro and not packHot then
        pulse = take(pulse, 'OOC hold (no CombatState/fightHot/aggroOnMe/commit)')
    end

    -- VF: ensureAttack order -- Dead, style, enrage, live, allowed, reach, LoS, sit.
    if dead then atk = take(atk, 'Me.Dead') end
    if style ~= 'Melee' then
        atk = take(atk, 'combat_style=' .. tostring(style) .. ' (ensureAttack is Melee-only)')
    end
    if runtime.meleeEnrageHold and runtime.meleeEnrageHold() then
        atk = take(atk, 'meleeEnrageHold (enrage/infuriate)')
    end
    local d, reach, los = -1, -1, nil
    if tid <= 0 then
        atk = take(atk, 'no target')
    else
        d = distToId(tid)
        reach = maxMeleeDistance(tid) or 18
        los = hasLoS(tid)
        if not runtime.swingTargetLive(tid) then
            atk = take(atk, 'swingTargetLive (dead / ignore / not hostile)')
        end
        if not runtime.swingAllowed(tid) then
            atk = take(atk, 'swingAllowed (no consent -- unarmed Manual is not AssistOn)')
        end
        local wants = runtime.spawnWantsFight and runtime.spawnWantsFight(tid)
        if not (d <= reach or (d <= 25 and wants)) then
            atk = take(atk, string.format('out of reach (dist=%.1f reach=%.1f)', d, reach))
        end
        if not runtime.swingLosOk(tid, d) then
            atk = take(atk, string.format('swingLosOk (dist=%.1f, LoS false and >8u)', d))
        end
        if sit then
            atk = take(atk, 'sitting/ducking (ensureAttack /stand then returns this tick)')
        end
    end

    if pulse then
        print('  \arPULSE:\ax ' .. pulse)
    else
        print('  \agPULSE:\ax would reach melee / ensureAttack')
    end
    if atk then
        print('  \arATTACK:\ax ' .. atk)
    elseif swinging then
        print('  \agATTACK:\ax Me.Combat already on (ensureAttack early-out)')
    else
        print('  \agATTACK:\ax would /attack on')
    end

    local stickSt, stickActive, stickStopped, stickPaused, navOn = 'n/a', false, false, false, false
    pcall(function()
        navOn = not not (mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
        if mq.TLO.Stick then
            stickSt = tostring(mq.TLO.Stick.Status() or '?')
            stickActive = not not mq.TLO.Stick.Active()
            stickStopped = not not (mq.TLO.Stick.Stopped and mq.TLO.Stick.Stopped())
            stickPaused = not not (mq.TLO.Stick.Paused and mq.TLO.Stick.Paused())
        end
    end)
    local meleeInfo = 'n/a'
    if runtime.meleeLoaded and runtime.meleeLoaded() then
        pcall(function()
            local ms = tostring(mq.TLO.Melee.Status() or '?')
            local mt = tonumber(mq.TLO.Melee.Target()) or 0
            meleeInfo = (ms:gsub('%s+$', ''))
                .. ((mt ~= tid) and (' MT#' .. mt .. '/=us') or ' MT=us')
        end)
    end
    print(string.format(
        '  consent=%s inFight=%s mayClose=%s assist=#%d commit=#%d armed(fight)=%s Combat=%s state=%s',
        tostring(runtime.consent and runtime.consent()),
        tostring(runtime.inFight and runtime.inFight()),
        tostring(runtime.mayClose and runtime.mayClose(tid)),
        tonumber(runtime._assistId) or 0,
        tonumber(runtime.manualCommitId) or 0,
        tostring(not not runtime.manualFightArmed),
        tostring(swinging), tostring(st)))
    print(string.format(
        '  dist=%.1f reach=%.1f LoS=%s nav=%s mover=%s',
        d, reach, tostring(los), tostring(navOn), tostring(runtime.mover)))
    print(string.format(
        '  stick Status=%s Active=%s Stopped=%s Paused=%s cmd=%s',
        stickSt, tostring(stickActive), tostring(stickStopped), tostring(stickPaused),
        tostring(pursuit.assistCmd or '-')))
    print(string.format('  Melee:%s  aggroOnMe=%s', meleeInfo, tostring(aggro)))
    if tid <= 0 then
        local band = (ctrl and tonumber(ctrl.xtar_nav_dist)) or 150
        print(string.format('  nearest: onMe=%s threat=%s (band %d)',
            tostring(runtime.closestMobOnMe and runtime.closestMobOnMe(band)),
            tostring(runtime.closestThreat and runtime.closestThreat(band)),
            band))
    end
end

-- VF: distinguishes an unset TLO from a zero. 'NULL'/nil means this server does not
-- VF: hand us the field at all, which is the whole question a peer transport answers.
runtime.probeStr = function(fn)
    local ok, v = pcall(fn)
    if not ok then return 'err' end
    if v == nil then return 'nil' end
    local s = tostring(v)
    if s == '' or s == 'NULL' then return 'NULL' end
    return s
end

-- VF: /vf gdiag — what the group TLOs actually hand us on THIS server, and what
-- VF: comes back NULL. docs/MULTIBOX.md sizes the MQ2DanNet decision on exactly
-- VF: this: whatever is readable here needs no transport. That doc lists peer mana
-- VF: and endurance as needing one, which looks wrong -- groupmember inherits
-- VF: spawn (which has PctMana / PctEndurance) and Group.LowMana() exists. Run this
-- VF: grouped and mid-fight and read the Mana%/End% columns before trusting the doc.
runtime.groupReport = function()
    local P = runtime.probeStr
    local size = tonumber(mq.TLO.Group.GroupSize()) or 0
    if size <= 0 then
        print('\ay[VF]\ax gdiag: not in a group.')
        return
    end
    print(string.format('\ag[VF]\ax group diag -- GroupSize=%s Members=%s Present=%s anyoneMissing=%s',
        P(function() return mq.TLO.Group.GroupSize() end),
        P(function() return mq.TLO.Group.Members() end),
        P(function() return mq.TLO.Group.Present() end),
        P(function() return mq.TLO.Group.AnyoneMissing() end)))
    -- VF: free healer-policy inputs. If these two return numbers, peer HP and mana
    -- VF: are client-side and a transport buys nothing for heal decisions.
    print(string.format('  aggregates: Injured(90)=%s LowMana(50)=%s',
        P(function() return mq.TLO.Group.Injured(90)() end),
        P(function() return mq.TLO.Group.LowMana(50)() end)))
    print(string.format('  roles: Leader=%s MainTank=%s MainAssist=%s Puller=%s',
        P(function() return mq.TLO.Group.Leader.Name() end),
        P(function() return mq.TLO.Group.MainTank.Name() end),
        P(function() return mq.TLO.Group.MainAssist.Name() end),
        P(function() return mq.TLO.Group.Puller.Name() end)))

    -- VF: index 0 is us. Do not "fix" that to 1; lowestHpAlly relies on it.
    print('  idx name              cls lvl   HP%   Mana%  End%   dist   where      id       theirTgt')
    local tots = {}
    for i = 0, math.min(size - 1, 5) do
        local m = mq.TLO.Group.Member(i)
        tots[#tots + 1] = runtime.probeStr(function() return m.TargetOfTarget.ID() end)
        local function pb(f) return P(f):lower() == 'true' end
        local where = 'here'
        if pb(function() return m.Offline() end) then
            where = 'offline'
        elseif pb(function() return m.OtherZone() end) then
            where = 'otherzone'
        end
        local tags = ''
        if pb(function() return m.MainTank() end) then tags = tags .. 'MT' end
        if pb(function() return m.MainAssist() end) then tags = tags .. 'MA' end
        if pb(function() return m.Puller() end) then tags = tags .. 'PU' end
        if pb(function() return m.Mercenary() end) then tags = tags .. 'merc' end
        print(string.format('  %-3d %-17s %-3s %-5s %-5s %-6s %-6s %-6s %-10s %-8s %s%s',
            i,
            P(function() return m.Name() end):sub(1, 17),
            P(function() return m.Class.ShortName() end),
            P(function() return m.Level() end),
            P(function() return m.PctHPs() end),
            P(function() return m.PctMana() end),
            P(function() return m.PctEndurance() end),
            P(function() return m.Distance3D() end),
            where,
            P(function() return m.ID() end),
            -- VF: if this is readable for members other than us, the MA's kill target
            -- VF: needs no /assist and no transport. That is the big open question.
            P(function() return m.TargetOfTarget.ID() end),
            tags ~= '' and ('  [' .. tags .. ']') or ''))
    end

    -- VF: is theirTgt per-ally, or just our own target's target echoed back? Judge the
    -- VF: ALLY rows only -- tots[1] is index 0, which is us, and self always reports.
    -- VF: Measured 2026-09-11 mid-fight: self reported its target's target, every ally
    -- VF: reported 0. So Spawn.TargetOfTarget is NOT an ally's target, and that is what
    -- VF: keeps the Main Tank assist branch dead (Me.GroupAssistTarget covers the MA).
    local allySeen, allyDistinct, allyFirst = 0, 0, nil
    for i = 2, #tots do
        local v = tots[i]
        if v ~= '0' and v ~= 'NULL' and v ~= 'nil' then
            allySeen = allySeen + 1
            if allyFirst == nil then allyFirst = v; allyDistinct = 1
            elseif v ~= allyFirst then allyDistinct = 2 end
        end
    end
    print(string.format('  theirTgt verdict: %s', (function()
        if #tots < 2 then return 'no allies in group -- inconclusive' end
        if allySeen == 0 then
            return 'every ALLY reports 0 -- not an ally\'s target; MT assist branch cannot work natively'
        end
        if allyDistinct >= 2 then return 'differs per ally -- ally targets ARE readable' end
        if allyFirst == tots[1] then
            return 'allies echo our own target\'s target -- not per-ally'
        end
        return 'allies all report ' .. tostring(allyFirst) .. ' -- single id, verify it is theirs'
    end)()))

    print(string.format('  assist: ma_name=%s maPcId=%s roleHolder=%s anchor=%s',
        tostring(ctrl and ctrl.ma_name), tostring(maPcId()),
        tostring(runtime.groupRoleHolderId and runtime.groupRoleHolderId(ctrl and ctrl.ma_name)),
        tostring(runtime.groupAnchorId and runtime.groupAnchorId(ctrl and ctrl.ma_name))))
    -- VF: the no-/assist path. If this prints an id mid-fight, the blocking /assist
    -- VF: in maTargetId is dead weight and DanNet buys nothing for assist targeting.
    print(string.format('  Me.GroupAssistTarget=%s (%s)  groupAssistMobId=%s',
        P(function() return mq.TLO.Me.GroupAssistTarget.ID() end),
        P(function() return mq.TLO.Me.GroupAssistTarget.CleanName() end),
        tostring(runtime.groupAssistMobId and runtime.groupAssistMobId())))

    local myId = tonumber(mq.TLO.Me.ID()) or 0
    local toks = { 'Whole Group', 'Lowest-HP Ally', 'Main Assist' }
    -- VF: 'Assist Target' is skipped outside Group mode on purpose -- maTargetId
    -- VF: fires a real /assist plus mq.delay(150) there, and a diagnostic must not
    -- VF: hijack your target. In Group mode it reads groupAssistMobId, so it is free.
    if ctrl and ctrl.mode == 'Group' then toks[#toks + 1] = 'Assist Target' end
    for _, tok in ipairs(toks) do
        local rid = resolveTargetId(tok)
        local note = ''
        if tok == 'Whole Group' and (tonumber(rid) or 0) == myId then
            note = '  <-- BUG: resolves to self; group heals do not exist yet'
        end
        print(string.format('  token %-16s -> %-8s%s', tok, tostring(rid), note))
    end
    if not (ctrl and ctrl.mode == 'Group') then
        print('  token Assist Target    -> skipped (would /assist + delay outside Group mode)')
    end
end

-- VF: player has started the fight (melee attack / HP drop + aggro). Ranged ≠ire ≠ combat_style.
local function playerIsEngagingTarget(tid)
    if mq.TLO.Me.Combat() then return true end
    -- VF: Spell/Ranged: confirm a hit has landed via HP drop + aggro ownership.
    local tpct = pctHP(tid) or 100
    if tpct < 100 and playerHasAggro(tid) then return true end
    return false
end

-- VF: ONE threat-retarget standard for every mode (not Roam-only copies).
-- VF: Fight band (stick handoff) > chase leash (xtar_nav_dist). On-me in band beats a far runner.
-- VF: Targeting menu may use Spawn; fight-state SoT stays CombatState (enginestate).
local function retargetThreat()
    if (os.clock() - (runtime.lastAggroSwitchAt or 0)) < 0.75 then return false end
    -- VF: Do not stopMoving/retarget mid Rush or travelIgnore — strip+nav owns the leg.
    if runtime.pullerRushing and runtime.pullerRushing() then return false end
    if runtime.rushOnTheMove and runtime.rushOnTheMove() then return false end
    -- VF: Group catch-up only — idle clicks (vendor/quest) must survive. Assist steal is groupModeTick.
    if ctrl.mode == 'Group' and ctrl.running then
        local catchingUp = false
        pcall(function()
            local tr = runtime.travel
            local r = tr and tr.resume and tr.resume()
            local t = tr and tr.trip and tr.trip()
            catchingUp = (r and r.groupCatchup) or (t and t.groupCatchup) or false
        end)
        if catchingUp then
            local tid = 0
            local tType = ''
            pcall(function()
                local t = mq.TLO.Target
                if t() and not t.Dead() then
                    tid = t.ID() or 0
                    tType = t.Type() or ''
                end
            end)
            -- VF: Drop NPC/Pet only — leave PC (leader) targeted for /nav target.
            if tid > 0 and (tType == 'NPC' or tType == 'Pet') then
                mq.cmd('/target clear')
            end
            return false
        end
        if not (runtime.groupAssistMobId and runtime.groupAssistMobId()) then
            return false
        end
    end
    local manualHot = runtime.manualFightArmed
        or ((tonumber(runtime.manualCommitId) or 0) > 0)
    if (ctrl.mode == 'Manual' or not ctrl.running) and not manualHot then
        return false
    end

    local fightBand = runtime.stickHandoff and runtime.stickHandoff() or 120
    local leash = (ctrl and tonumber(ctrl.xtar_nav_dist)) or 150
    local cur = mq.TLO.Target
    local curId = 0
    local curDist = 999
    pcall(function()
        if cur() and (cur.Type() == 'NPC' or cur.Type() == 'Pet') and not cur.Dead() then
            curId = cur.ID() or 0
            curDist = cur.Distance3D() or 999
        end
    end)
    if curId > 0 and (isIgnored(cur.CleanName()) or not isHostileTarget(curId)) then
        curId, curDist = 0, 999
    end

    local curOnMe = curId > 0 and runtime.spawnIsOnMe and runtime.spawnIsOnMe(curId)
    local onMeId = runtime.closestMobOnMe and runtime.closestMobOnMe(fightBand) or nil

    -- VF: Something beating us in the fight band while we stare at a runner.
    -- VF: in-reach live hostile stays — swarm closest-on-me flaps drop Me.Combat().
    if onMeId and onMeId > 0 and onMeId ~= curId then
        local inReach = curId > 0 and curDist <= (maxMeleeDistance(curId) or 18)
        local runner = (not inReach) and (curId <= 0 or curDist > fightBand or not curOnMe)
        if runner then
            if setTarget(onMeId) then
                runtime.lastAggroSwitchAt = os.clock()
                stopMoving()
                pursuit.id = 0
                pursuit.lastNavTargetId = 0
                if runtime.manualFightArmed or manualHot then
                    runtime.manualCommitId = onMeId
                end
                local msg = string.format('threat retarget #%d (%s) — on-me in band (was #%d @%.0f)',
                    onMeId, tostring(mq.TLO.Target.CleanName()), curId, curDist)
                if runtime.chat then
                    runtime.chat.debug('vft', 'retargetThreat', msg)
                end
                print('\ay[VF]\ax ' .. msg)
                return true
            end
        end
    end

    -- VF: Past chase leash and not on-me — drop; do not nav across the zone.
    if curId > 0 and curDist > leash and not curOnMe then
        runtime.lastAggroSwitchAt = os.clock()
        stopMoving()
        pursuit.id = 0
        pursuit.lastNavTargetId = 0
        mq.cmd('/target clear')
        if runtime.manualCommitId == curId then runtime.manualCommitId = 0 end
        local msg = string.format('threat drop #%d — past chase leash %.0f (dist %.0f)',
            curId, leash, curDist)
        if runtime.chat then
            runtime.chat.debug('vft', 'retargetThreat', msg)
        end
        print('\ay[VF]\ax ' .. msg)
        return true
    end

    return false
end

-- VF: alias — old Roam-only name.
local function checkAggroSwitch()
    return retargetThreat()
end

fullStop = function()
    if runtime.clearRushTrip then runtime.clearRushTrip() else runtime.clearPlayerNav() end
    stopMoving()
    -- VF: Paused Group -- drop /afollow so the player owns move/target.
    if runtime.groupFollowStop then runtime.groupFollowStop() end
    -- VF: Paused: player is in control.
    if isCasting() then
        mq.cmd('/stopsong')
        mq.cmd('/stopcast')
    end
    if not ctrl.running then
        setManualHunterPetHold(true, true)
    else
        setManualHunterPetHold(false)
    end
    pursuit.id = 0
    pursuit.lastNavTargetId = 0
    pursuit.lastNavLoc = nil
    pursuit.wanderLoc = nil
    runtime.pullState = 'IDLE'
    runtime.pullTargetId = 0
    runtime.manualFightArmed = false
    runtime.manualCommitId = 0
    if runtime.medBreakActive then
        runtime.medBreakActive = false; if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
    end
    runtime.routeManaSit = false
    runtime.postCombatHealActive = false
    runtime.postCombatHealRetryAt = 0
    runtime.postCombatHealGaveUp = nil
    runtime.postCombatHealUntil = 0
    runtime.postCombatBuffActive = false
    runtime.postCombatBuffGaveUp = nil
    runtime.postCombatBuffUntil = 0
    runtime.combatHealRetryAt = 0
    runtime.bardHoldUntil = 0
    runtime.t2StopSongAt = 0
    runtime.lastCast = {}
    if castTracker and castTracker.clear then castTracker.clear() end
    runtime.buffTries = {}
    if runtime.meleeStickSuppressed then
        runtime.meleeStickSuppressed = false
        meleeStickSuppress(false)
    end
    stuckState.counter = 0
    stuckState.attempts = 0
    stuckState.cannotSeeAttempts = 0
end

onZoned = function()
    if ctrl.running then
        local stayGroup = false
        if ctrl.mode == 'Group' and ctrl.group_stay ~= false then
            stayGroup = (not runtime.groupTrustStayArmed)
                or (runtime.groupTrustStayArmed() and true or false)
        end
        if stayGroup then
            fullStop()
            if runtime.groupOnZoned then runtime.groupOnZoned() end
            print('\ay[VF]\ax zoned -- Group still running; will re-follow when the anchor is here.')
        else
            ctrl.running = false
            fullStop()
            if ctrl.mode == 'Group' and runtime.groupOnZoned then runtime.groupOnZoned() end
            print('\ay[VF]\ax zoned -- pausing.')
        end
    else
        -- VF: Paused map-nav still held old-zone locs and re-issued /nav every tick.
        if runtime.clearRushTrip then runtime.clearRushTrip() elseif runtime.clearPlayerNav then runtime.clearPlayerNav() end
        stopMoving()
        pursuit.lastNavLoc = nil
        pursuit.lastNavTargetId = 0
        pursuit.id = 0
        if ctrl.mode == 'Group' and runtime.groupOnZoned then runtime.groupOnZoned() end
    end
    pursuit.unreachableIds = {}
    pursuit.id = 0
    pursuit.wanderLoc = nil
    runtime.pullState = 'IDLE'
    runtime.pullTargetId = 0
    runtime.discExpires = {}
    runtime.discCooldown = {}
    petState.myPets = {}
    petState.petHoldActive = false
    petState.manualHunterHold = nil
    petState.lastObservedId = 0
    petState.lastCmdTargetId = 0
    petState.lastCmdAt = 0
    petState.holdIssuedForId = 0
    ctrl.camp_loc = nil
    if ctrl.hunter_combat_loc then
        print('\ay[VF]\ax zoned -- clearing Hunter combat anchor (it was set in the previous zone).')
        ctrl.hunter_combat_loc = nil
    end
    if ctrl.group_anchor_loc then
        print('\ay[VF]\ax zoned -- clearing Group Anchor (re-check Anchor to stamp this zone).')
        ctrl.group_anchor_loc = nil
    end
    if ctrl.running and runtime.groupEnsureLeaderRoles then runtime.groupEnsureLeaderRoles() end
    -- VF: already have classes — do not /windowstate InventoryWindow open on every zone.
    if not (myClasses and #myClasses > 0) then
        local detected = classesFromInventoryWindow(false, true)
        if detected then myClasses = detected end
    end
    if runtime.reloadSafeZones then runtime.reloadSafeZones() end
    if runtime.inSafeZone and runtime.inSafeZone() then
        runtime.manualFightArmed = false
        runtime.manualCommitId = 0
        -- VF: deliberately NOT through attackReleaseOk -- a safe zone is unconditional.
        if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
        if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
        print('\ay[VF]\ax safe zone -- combat auto-target off.')
    end
end

runtime.releaseManualFight = function()
    if not runtime.manualFightArmed and not mq.TLO.Me.Combat() then return false end
    local now = os.clock()
    if (now - (runtime.lastManualEscapeAt or 0)) < 0.35 then return false end
    runtime.lastManualEscapeAt = now
    runtime.manualFightArmed = false
    runtime.manualCommitId = 0
    if runtime.clearRushTrip then runtime.clearRushTrip() elseif runtime.clearPlayerNav then runtime.clearPlayerNav() end
    stopMoving()
    -- VF: deliberately NOT through attackReleaseOk -- Escape is a command, not a guess.
    if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
    if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
    print('\ay[VF]\ax Escape -- chase off. Press attack when you want it again.')
    return true
end

-- VF: Escape always kills /nav (and stick/moveto). Latch so combatTick cannot re-issue for a few seconds.
runtime.NAV_ESC_HOLD = 12
runtime.escapeHardStopNav = function()
    local now = os.clock()
    if (now - (runtime.lastNavEscapeAt or 0)) < 0.35 then return false end
    runtime.lastNavEscapeAt = now

    local tid = 0
    pcall(function() tid = mq.TLO.Target.ID() or 0 end)
    if tid <= 0 then tid = pursuit.lastNavTargetId or 0 end
    if tid > 0 and markUnreachable then markUnreachable(tid) end

    if runtime.clearRushTrip then
        runtime.clearRushTrip()
    elseif runtime.clearPlayerNav then
        runtime.clearPlayerNav()
    end
    stopMoving()
    pursuit.id = 0
    pursuit.lastNavTargetId = 0
    pursuit.lastNavLoc = nil
    pursuit.lastStickDist = 0
    pursuit.navStalls = 0
    runtime.navEscapedUntil = now + (runtime.NAV_ESC_HOLD or 12)
    runtime.releaseManualFight()
    print(string.format(
        '\ay[VF]\ax Escape -- nav hard stop%s. No combat nav for %ds.',
        (tid > 0) and string.format(' (marked #%d unreachable)', tid) or '',
        runtime.NAV_ESC_HOLD or 12))
    return true
end

runtime.navEscapedHold = function()
    local untilAt = runtime.navEscapedUntil or 0
    return untilAt > 0 and os.clock() < untilAt
end

runtime.escapeKeyDown = function()
    local hit = false
    pcall(function()
        if ImGui.IsKeyPressed and ImGui.Key and ImGui.Key.Escape then
            hit = ImGui.IsKeyPressed(ImGui.Key.Escape)
        end
    end)
    if hit then return true end
    pcall(function()
        local ImGuiKey = rawget(_G, 'ImGuiKey')
        if ImGui.IsKeyPressed and ImGuiKey and ImGuiKey.Escape then
            hit = ImGui.IsKeyPressed(ImGuiKey.Escape)
        end
    end)
    if hit then return true end
    -- VF: Game has focus more often than ImGui.
    local down = false
    pcall(function()
        local ffi = require('ffi')
        if not runtime._escCdef then
            pcall(function() ffi.cdef('short GetAsyncKeyState(int vKey);') end)
            runtime._escCdef = true
        end
        down = ffi.C.GetAsyncKeyState(0x1B) < 0
    end)
    local pressed = down and not runtime.escWasDown
    runtime.escWasDown = down
    return pressed
end

-- VF: Bind engine helpers to runtime table to prevent exceeding Lua 5.1 / LuaJIT 60-upvalue limit.
runtime.fullStop = fullStop
runtime.pctHP = pctHP
runtime.isCombat = isCombat
runtime.countPackMobs = countPackMobs
runtime.isGroupOrRaidMember = isGroupOrRaidMember
runtime.isAnyPet = isAnyPet
runtime.isSpawnPetOrPlayer = isSpawnPetOrPlayer
runtime.isHostileTarget = isHostileTarget
-- VF: Rush kills what is on the pin.
runtime.rushNear = 80
-- VF: hate = how many around you want a fight. Slot count is not the source.
runtime.rushHate = function()
    return tonumber(countPackMobs(runtime.rushNear or 80)) or 0
end
-- VF: lowest-level hostile in range (Focus Adds). Tie-break nearer.
runtime.lowestLevelNear = function(maxDist, excludeId)
    maxDist = tonumber(maxDist) or (runtime.rushNear or 80)
    local bestId, bestLvl, bestD = nil, 1e9, maxDist + 1
    local function consider(id)
        if not id or id <= 0 or id == excludeId then return end
        if not isSpawnAlive(id) or isGroupOrRaidMember(id) or isSpawnPetOrPlayer(id) then return end
        if not isHostileTarget(id) or isUnreachable(id) then return end
        local s = mq.TLO.Spawn(id)
        if not s() then return end
        local stype = s.Type() or ''
        if not ((stype == 'NPC' or stype == 'Pet') and not s.Dead() and stype ~= 'Corpse') then return end
        if isIgnored(s.CleanName()) then return end
        local dist = s.Distance3D() or 999
        if dist > maxDist then return end
        local lvl = tonumber(s.Level()) or 999
        if lvl < bestLvl or (lvl == bestLvl and dist < bestD) then
            bestLvl, bestD, bestId = lvl, dist, id
        end
    end
    pcall(function()
        local filt = string.format('npc radius %d', maxDist)
        local n = mq.TLO.SpawnCount(filt)() or 0
        for i = 1, math.min(n, 20) do
            local s = mq.TLO.NearestSpawn(i, filt)
            if s and s() then
                local id = s.ID() or 0
                if id > 0 and runtime.spawnWantsFight and runtime.spawnWantsFight(id) then
                    consider(id)
                end
            end
        end
    end)
    return bestId, bestLvl
end
-- VF: Manual/Pause: attack locks that target. Near+LoS = stick; far = travelIgnore.
-- VF: Focus Adds: re-pick lowest-level hostile in proximity (adds before boss).
-- VF: armed=false -- target only, never moveToward / travel.
runtime.manualProxFight = function(haveNPC, armed)
    local near = runtime.rushNear or 80

    if not armed then
        runtime.manualCommitId = 0
        return haveNPC, false
    end

    if ctrl.focus_adds then
        local addId, addLvl = runtime.lowestLevelNear(near)
        if addId then
            local cur = tonumber(runtime.manualCommitId) or 0
            if cur ~= addId then
                runtime.manualCommitId = addId
                if setTarget(addId) then
                    stopMoving()
                    pursuit.id = 0
                    pursuit.lastNavTargetId = 0
                    print(string.format(
                        '\ay[VF]\ax Focus Adds -> #%d (%s) L%d [%.0f]',
                        addId, tostring(mq.TLO.Target.CleanName()), tonumber(addLvl) or 0, distToId(addId)))
                end
            elseif mq.TLO.Target.ID() ~= addId then
                setTarget(addId)
            end
            -- VF: fall through to stick-or-travelIgnore for the add.
        end
    end

    local commit = tonumber(runtime.manualCommitId) or 0
    if commit > 0 then
        local s = mq.TLO.Spawn(commit)
        if not s() or s.Dead() or s.Type() == 'Corpse'
            or not isHostileTarget(commit) or isUnreachable(commit) then
            runtime.manualCommitId = 0
            commit = 0
            haveNPC = false
        end
    end

    -- VF: first attack press locks the hostile you had targeted.
    if commit <= 0 then
        local tid = mq.TLO.Target.ID() or 0
        if tid > 0 and isHostileTarget(tid) and not isUnreachable(tid) then
            runtime.manualCommitId = tid
            commit = tid
            print(string.format('\ay[VF]\ax Manual commit #%d (%s) -- near stick / far travelIgnore.',
                tid, tostring(mq.TLO.Target.CleanName())))
        end
    end

    if commit > 0 then
        local tid = mq.TLO.Target.ID() or 0
        -- VF: new hostile = new commit. PC/heal keeps the old stick id without stealing target.
        if tid > 0 and tid ~= commit and isHostileTarget(tid) and not isUnreachable(tid) then
            runtime.manualCommitId = tid
            commit = tid
        elseif tid <= 0 then
            setTarget(commit)
        end
        local reach = maxMeleeDistance(commit)
        local d = distToId(commit)
        local los = hasLoS(commit)
        -- VF: Stick band or already in reach+LoS -- combat owns. Else travelIgnore (attack off).
        -- VF: look-at / OOC -- do not /stick or /nav a quiet hostile.
        local swinging, inCs, onMe = false, false, false
        pcall(function() swinging = not not mq.TLO.Me.Combat() end)
        if runtime.engineInCombat then inCs = not not runtime.engineInCombat() end
        if runtime.spawnIsOnMe then onMe = not not runtime.spawnIsOnMe(commit) end
        if runtime.canStickClose(commit) or (d <= reach and los) then
            if not (swinging or inCs or onMe) then
                return haveNPC, false
            end
            local tr = runtime.travel
            if tr and tr.trip then
                local t = tr.trip()
                if t and t.spawnId == commit then tr.clear() end
            end
            -- VF: combatTick AssistOn owns close. Do not /nav a fight spawn.
            return true, true
        end
        local tr = runtime.travel
        if tr and tr.beginIgnoreSpawn then
            local t = tr.trip and tr.trip() or nil
            if not (t and t.spawnId == commit) then
                tr.beginIgnoreSpawn(commit, {
                    arrive = math.max(reach, tr.RANGE and tr.RANGE.arrive or 15),
                    onArrive = function()
                        print(string.format(
                            '\ag[VF]\ax Manual arrive #%d -- range+LoS; combat takes over.',
                            commit))
                    end,
                })
            end
        end
        return true, false
    end

    -- VF: armed but no commit yet -- only pick something already near (not roam).
    if haveNPC then
        local tid = mq.TLO.Target.ID() or 0
        if tid <= 0 or not isHostileTarget(tid) or isUnreachable(tid) then
            haveNPC = false
        elseif distToId(tid) > (near + 15)
            and not (runtime.spawnIsOnMe and runtime.spawnIsOnMe(tid)) then
            haveNPC = false
            mq.cmd('/target clear')
            stopMoving()
            pursuit.id = 0
            pursuit.lastNavTargetId = 0
        end
    end
    if not haveNPC then
        local id = runtime.closestThreat and runtime.closestThreat(near)
        if id and runtime.claimFightTarget and runtime.claimFightTarget(id) then
            haveNPC = true
            pursuit.id = 0
            pursuit.lastNavTargetId = 0
            print(string.format('\ay[VF]\ax Manual near commit #%d (%s) [%.0f]',
                id, tostring(mq.TLO.Target.CleanName()), distToId(id)))
        end
    end
    local engage = false
    if haveNPC then
        local id = mq.TLO.Target.ID()
        if id and isHostileTarget(id) then
            if (tonumber(runtime.manualCommitId) or 0) <= 0 then
                runtime.manualCommitId = id
            end
            -- VF: Recurse into stick-or-travel via commit path next tick; close if already near.
            if runtime.canStickClose(id) or (distToId(id) <= maxMeleeDistance(id) and hasLoS(id)) then
                engage = true
            end
        else
            haveNPC = false
        end
    end
    return haveNPC, engage
end
runtime.stopMoving = stopMoving
runtime.distToId = distToId
runtime.distToLoc = distToLoc
runtime.hasLoS = hasLoS
runtime.isMoveActive = isMoveActive
runtime.isCasting = isCasting
runtime.navLoaded = navLoaded
runtime.stickLoaded = stickLoaded
runtime.hasActivePet = hasActivePet
runtime.trioHasPetClass = trioHasPetClass
runtime.releaseBardBarAfterCombat = releaseBardBarAfterCombat
runtime.freeBardBarForHeal = freeBardBarForHeal
runtime.setManualHunterPetHold = setManualHunterPetHold
runtime.playerHasAggro = playerHasAggro
runtime.playerIsEngagingTarget = playerIsEngagingTarget
runtime.checkCombatStall = checkCombatStall
runtime.checkGemMemSync = checkGemMemSync
runtime.checkAggroSwitch = checkAggroSwitch
runtime.retargetThreat = retargetThreat
runtime.findRoamTarget = findRoamTarget
runtime.checkCloserTarget = checkCloserTarget
runtime.spawnDist2ToLoc = function(id, loc)
    if not loc or not id or id <= 0 then return 1e12 end
    local sx, sy = nil, nil
    pcall(function()
        local s = mq.TLO.Spawn(id)
        if s and s() then
            sx = s.X()
            sy = s.Y()
        end
    end)
    if sx == nil or sy == nil then return 1e12 end
    local dx = sx - (loc.x or 0)
    local dy = sy - (loc.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end
-- VF: use this, not spawnDist2ToLoc, for "is this mob inside my pin/camp radius".
-- VF: The 2D one reads a mob a floor up as standing on the pin. A pin with no z
-- VF: stamped collapses to the flat answer, so this is safe on old routes.
runtime.spawnDist3ToLoc = function(id, loc)
    if not loc or not id or id <= 0 then return 1e12 end
    local flat = runtime.spawnDist2ToLoc(id, loc)
    if loc.z == nil or flat >= 1e12 then return flat end
    local sz = nil
    pcall(function()
        local s = mq.TLO.Spawn(id)
        if s and s() then sz = s.Z() end
    end)
    if sz == nil then return flat end
    local dz = sz - (loc.z or 0)
    return math.sqrt(flat * flat + dz * dz)
end
runtime.maTargetId = maTargetId
runtime.resolveTargetId = resolveTargetId
runtime.castGem = castGem
runtime.fireAA = fireAA
runtime.fireItem = fireItem
runtime.isDetrimentalAction = isDetrimentalAction
runtime.isTargetInRange = isTargetInRange
runtime.conditionMet = conditionMet
runtime.baseTok = U.baseTok
runtime.sungKey = U.sungKey
runtime.clearCursor = clearCursor
runtime.markUnreachable = markUnreachable
runtime.moveToward = moveToward
runtime.moveTowardLoc = moveTowardLoc
runtime.setTarget = setTarget
runtime.desiredRange = desiredRange
runtime.maxMeleeDistance = maxMeleeDistance
runtime.isIgnored = isIgnored
runtime.isUnreachable = isUnreachable

require('vft.modes.group').install(runtime, {
    ctrl                 = function() return ctrl end,
    distToId             = distToId,
    setTarget            = setTarget,
    moveToward           = moveToward,
    moveTowardLoc        = moveTowardLoc,
    stopMoving           = stopMoving,
    desiredRange         = desiredRange,
    pctHP                = pctHP,
    hasLoS               = hasLoS,
    isHostileTarget      = isHostileTarget,
    isSpawnPetOrPlayer   = isSpawnPetOrPlayer,
    isGroupOrRaidMember  = isGroupOrRaidMember,
    isSpawnAlive         = isSpawnAlive,
    claimMover           = runtime.claimMover,
})

require('vft.modes.roam').install(runtime, {
    ctrl                 = function() return ctrl end,
    loadout              = function() return loadout end,
    pursuit              = pursuit,
    stuckState           = stuckState,
    petState             = petState,
    distToId             = distToId,
    setTarget            = setTarget,
    moveToward           = moveToward,
    moveTowardLoc        = moveTowardLoc,
    stopMoving           = stopMoving,
    desiredRange         = desiredRange,
    maxMeleeDistance     = maxMeleeDistance,
    hasLoS               = hasLoS,
    isMoveActive         = isMoveActive,
    isIgnored            = isIgnored,
    isUnreachable        = isUnreachable,
    markUnreachable      = markUnreachable,
    findRoamTarget       = findRoamTarget,
    checkCloserTarget    = checkCloserTarget,
    isHostileTarget      = isHostileTarget,
    isSpawnAlive         = isSpawnAlive,
    hasActivePet         = hasActivePet,
    castGem              = castGem,
    isDetrimentalAction  = isDetrimentalAction,
})

local function combatTick()
    local fullStop = runtime.fullStop
    local pctHP = runtime.pctHP
    local countPackMobs = runtime.countPackMobs
    local isSpawnPetOrPlayer = runtime.isSpawnPetOrPlayer
    local isHostileTarget = runtime.isHostileTarget
    local stopMoving = runtime.stopMoving
    local distToId = runtime.distToId
    local hasLoS = runtime.hasLoS
    local isMoveActive = runtime.isMoveActive
    local isCasting = runtime.isCasting
    local navLoaded = runtime.navLoaded
    local stickLoaded = runtime.stickLoaded
    local hasActivePet = runtime.hasActivePet
    local releaseBardBarAfterCombat = runtime.releaseBardBarAfterCombat
    local setManualHunterPetHold = runtime.setManualHunterPetHold
    local playerHasAggro = runtime.playerHasAggro
    local playerIsEngagingTarget = runtime.playerIsEngagingTarget
    local checkCombatStall = runtime.checkCombatStall
    local checkGemMemSync = runtime.checkGemMemSync
    local checkAggroSwitch = runtime.checkAggroSwitch
    local retargetThreat = runtime.retargetThreat
    local maTargetId = runtime.maTargetId
    local resolveTargetId = runtime.resolveTargetId
    local castGem = runtime.castGem
    local fireAA = runtime.fireAA
    local fireDisc = runtime.fireDisc
    local isDiscReady = runtime.isDiscReady
    local isDetrimentalAction = runtime.isDetrimentalAction
    local conditionMet = runtime.conditionMet
    local clearCursor = runtime.clearCursor
    local markUnreachable = runtime.markUnreachable
    local moveToward = runtime.moveToward
    local setTarget = runtime.setTarget
    local desiredRange = runtime.desiredRange
    local maxMeleeDistance = runtime.maxMeleeDistance
    local isIgnored = runtime.isIgnored

    -- VF: settle MQ2Cast every tick ? OOC returns before combatTick and was leaving pending stuck.
    if runtime.castTick then runtime.castTick() end

    if mq.TLO.Me.Dead() then
        if not runtime.deathGuardFired then
            runtime.deathGuardFired = true
            fullStop()
            runtime.sungBuffs = {}
            runtime.discExpires = {}
            runtime.discCooldown = {}
            petState.myPets = {}; petState.lastObservedId = 0; petState.lastCastCls = nil
            print('\ar[VF]\ax character is dead -- paused. Will resume automatically once alive again.')
        end
        return
    end
    runtime.deathGuardFired = false

    -- VF: Group whitelist -- auto-accept invites + stay in Group when with approved.
    if runtime.groupTrustTick then runtime.groupTrustTick() end

    -- VF: Rush in transit: no sit/heal/fight. Prep still falls through.
    -- VF: leftover ignoreResume must not skip an armed Manual pack.
    if runtime.rushOnTheMove and runtime.rushOnTheMove() then
        local packHot = runtime.manualFightArmed
            or ((tonumber(runtime.manualCommitId) or 0) > 0)
            or (mq.TLO.Me.Combat() and true or false)
        if not packHot then
            if runtime.ensureRushNav then runtime.ensureRushNav() end
            if runtime.playerNavHold then runtime.playerNavHold() end
            if runtime.rushOnTheMove() then return end
        end
    end

    -- VF: Travel before OOC -- defend resume must see CombatState leave COMBAT even when OOC holds.
    local travelOwns = false
    if runtime.playerNavHold then
        travelOwns = runtime.playerNavHold() and true or false
    end

    -- VF: CombatState alone owns combat↔OOC.
    local engineCombat = runtime.currentState and runtime.currentState() == 'combat'
    if not engineCombat then
        pcall(function()
            if mq.TLO.Me.CombatState() == 'COMBAT' then engineCombat = true end
        end)
    end

    if engineCombat then
        runtime.oocSawCombat = true
        runtime.oocBootstrapped = true
        if runtime.oocOnEnterCombat then runtime.oocOnEnterCombat() end
    elseif runtime.oocSawCombat then
        runtime.oocSawCombat = false
        releaseBardBarAfterCombat()
        if runtime.oocOnLeaveCombat then runtime.oocOnLeaveCombat() end
    elseif not runtime.oocBootstrapped then
        -- VF: wait until loadout is applied (char change mutates gems in place).
        local ready = false
        for i = 1, D.NUM_GEMS do
            if loadout.gems and loadout.gems[i] and loadout.gems[i].spell then ready = true; break end
        end
        if not ready and loadout.aas then
            for _, a in pairs(loadout.aas) do
                if a and a.enabled then ready = true; break end
            end
        end
        if not ready and loadout.items then
            for _, it in pairs(loadout.items) do
                if it and it.enabled then ready = true; break end
            end
        end
        if ready then
            runtime.oocBootstrapped = true
            if runtime.oocOnStartup then runtime.oocOnStartup() end
        end
    end

    if engineCombat then
        -- VF: fall through — Me.CombatState COMBAT.
    elseif runtime.manualFightArmed or mq.TLO.Me.Combat()
        or ((tonumber(runtime.manualCommitId) or 0) > 0) then
        -- VF: Manual commit / melee attack toggle -- do not OOC /attack off while closing.
    elseif runtime.aggroOnMe and runtime.aggroOnMe() then
        -- VF: being attacked NOW. CombatState lags by seconds and OOC holds the
        -- VF: whole tick while it casts, so a buff mid-pull delayed /attack by
        -- VF: the length of the cast. Aggro pre-empts OOC; do not remove.
    else
        -- VF: SoT — Me or Present group@GROUP_ENGINE_NEAR CombatState COMBAT. Not XTarget/prox.
        local fightHot = false
        if runtime.engineFightHot then
            fightHot = runtime.engineFightHot() and true or false
        end
        if not fightHot and not travelOwns and runtime.oocTick and runtime.oocTick() then
            if runtime.chat and runtime.chat.isDebug() then
                local now = os.clock()
                if (now - (runtime.lastOocHoldDbg or 0)) > 2.0 then
                    runtime.lastOocHoldDbg = now
                    runtime.chat.debug('vft', 'combatTick',
                        'OOC hold (quiet — no Me/group@300 CombatState, no attack)')
                end
            end
            return
        end
    end
    -- VF: oocTick false + not COMBAT → resume mode (Roam/Rush/Manual/Group).

    -- VF: Rush must not sit between pins. Old-dev 40% mana gate cancelled /nav.
    -- VF: Never skip melee swing for mana hold when already on a mob.
    if ctrl.mode ~= 'Rush'
        and not runtime.postCombatHealActive
        and not runtime.oocManaSit
        and runtime.routeManaHold and runtime.routeManaHold() then
        if runtime.pulseMeleeAttack then runtime.pulseMeleeAttack() end
        local swinging = false
        pcall(function() swinging = mq.TLO.Me.Combat() or false end)
        if not swinging then return end
    end

    local curPetId = mq.TLO.Me.Pet.ID() or 0
    if curPetId ~= 0 and curPetId ~= petState.lastObservedId then
        if petState.lastCastCls then petState.myPets[petState.lastCastCls] = curPetId end
        petState.lastObservedId = curPetId
    elseif curPetId == 0 then
        petState.lastObservedId = 0
    end

    -- VF: retarget before /attack on — pulse must not swing a spawn combatTick is about to drop.
    if retargetThreat then retargetThreat() else checkAggroSwitch() end
    checkCombatStall()
    checkGemMemSync()

    local numXtar = countPackMobs and countPackMobs(runtime.rushNear or 80) or 0
    local t = mq.TLO.Target
    local haveNPC = t() and (t.Type() == 'NPC' or t.Type() == 'Pet') and not t.Dead() and t.Type() ~= 'Corpse'
        and not isSpawnPetOrPlayer(t.ID()) and isHostileTarget(t.ID())
    if haveNPC and (ctrl.mode == 'Roam' or ctrl.mode == 'Rush') then
        if isIgnored(t.CleanName()) then
            haveNPC = false
            mq.cmd('/target clear')
        elseif not (runtime.spawnWantsFight and runtime.spawnWantsFight(t.ID())) then
            local minL, maxL = runtime.npcLevelBand()
            local lvl = t.Level() or 0
            if lvl > 0 and (lvl < minL or lvl > maxL) then
                haveNPC = false
                mq.cmd('/target clear')
            end
        end
    elseif haveNPC and not ctrl.running then
        if isIgnored(t.CleanName()) then
            haveNPC = false
        end
    end
    local engage = false

    if travelOwns then
        -- VF: map/travel owns move this tick. Gems still run.
    elseif (not ctrl.running) or ctrl.mode == 'Manual' then
        -- VF: RMB = target only. Melee attack arms. Far = travelIgnore; near+LoS = stick/combat.
        local swinging = false
        pcall(function()
            swinging = mq.TLO.Me.Combat() or false
        end)
        if swinging then
            runtime.manualFightArmed = true
        elseif runtime.manualFightArmed then
            -- VF: Combat() drops on corpse — stay armed while the pack is still here.
            if not (runtime.manualPackHot and runtime.manualPackHot(80)) then
                runtime.manualFightArmed = false
                runtime.manualCommitId = 0
                stopMoving()
            end
        end
        if runtime.escapeKeyDown and runtime.escapeKeyDown() then
            runtime.escapeHardStopNav()
        end
        haveNPC, engage = runtime.manualProxFight(haveNPC, runtime.manualFightArmed)
    elseif ctrl.mode == 'Rush' then
        local rushTravel = false
        if runtime.pullerRushTick then
            rushTravel = runtime.pullerRushTick() ~= 'fight'
        end
        if rushTravel then
            haveNPC = false
            engage = false
            -- VF: "do not fight en route" is policy, but it fired every travel tick with
            -- VF: no aggro test at all. attackReleaseOk owns that question now.
            if not runtime.attackReleaseOk or runtime.attackReleaseOk() then
                if mq.TLO.Me.Combat() then mq.cmd('/attack off') end
                if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
            end
            -- VF: Rush travel: do not gem-cast -- idle buffs retarget and stand on the pin.
            return
        end
        -- VF: pin fight: do not drop because ToT is empty. Do not vacuum after haters die.
        local near = runtime.rushNear or 80
        local haters = runtime.rushHate and runtime.rushHate() or 0
        local pack = 0
        if runtime.countPackMobs then
            pack = tonumber(runtime.countPackMobs(near)) or 0
        end
        local grace = (runtime.nav.arrivedAt and (os.clock() - runtime.nav.arrivedAt) < 4)
            or ((runtime.nav.displaceHoldUntil or 0) > os.clock())
            or (runtime.nav.reanchor == true)
        if haveNPC then
            local tid = mq.TLO.Target.ID() or 0
            if tid <= 0 or isIgnored(mq.TLO.Target.CleanName()) then
                haveNPC = false
                mq.cmd('/target clear')
            elseif distToId(tid) > (near + 15)
                and not (runtime.spawnIsOnMe and runtime.spawnIsOnMe(tid)) then
                haveNPC = false
                mq.cmd('/target clear')
            end
        end
        if not haveNPC then
            -- VF: chain first (corpse → next wantsFight). Pin start only if nothing is fighting yet.
            if runtime.chainSwing and runtime.chainSwing() then
                haveNPC = true
            else
                local id = runtime.closestThreat and runtime.closestThreat(near)
                local inCs = runtime.engineInCombat and runtime.engineInCombat()
                if not id and not inCs and (pack > 0 or grace or haters > 0) then
                    id = runtime.closestHostileNear and runtime.closestHostileNear(near)
                end
                if id and runtime.claimFightTarget and runtime.claimFightTarget(id) then
                    haveNPC = true
                end
            end
        end
        if haveNPC then
            local id = mq.TLO.Target.ID()
            if id and isHostileTarget(id) then
                -- VF: melee close is AssistOn after setAssist. Ranged keeps rangedFightTick.
                engage = true
            else
                haveNPC = false
            end
        end
    elseif ctrl.mode == 'Roam' and runtime.roamModeTick then
        local abort
        haveNPC, engage, abort = runtime.roamModeTick(haveNPC)
        if abort then return end
    elseif ctrl.mode == 'Group' and runtime.groupModeTick then
        haveNPC, engage = runtime.groupModeTick()
        if not haveNPC then
            return
        end
    end

    -- VF: Hunt timeout when far and never aggro'd (Roam/Rush).
    if haveNPC and (ctrl.mode == 'Roam' or ctrl.mode == 'Rush') then
        local tid = mq.TLO.Target.ID() or 0
        if tid > 0 and not (runtime.spawnWantsFight and runtime.spawnWantsFight(tid)) and distToId(tid) > 30 then
            if pursuit.nonXtarTargetId ~= tid then
                pursuit.nonXtarTargetId = tid
                pursuit.nonXtarEngageAt = 0
            end
            if engage or mq.TLO.Me.Combat() then
                if pursuit.nonXtarEngageAt == 0 then
                    pursuit.nonXtarEngageAt = os.clock()
                elseif (os.clock() - pursuit.nonXtarEngageAt) > 15.0 then
                    print(string.format(
                        '\ay[VF]\ax Target #%d (%s) unreachable after 15s -- marking unreachable & moving to next NPC.',
                        tid, tostring(mq.TLO.Target.CleanName())))
                    markUnreachable(tid)
                    stopMoving()
                    mq.cmd('/target clear')
                    haveNPC = false
                    engage = false
                    pursuit.id = 0
                    pursuit.nonXtarTargetId = 0
                    pursuit.nonXtarEngageAt = 0
                end
            else
                pursuit.nonXtarEngageAt = 0
            end
        else
            pursuit.nonXtarTargetId = 0
            pursuit.nonXtarEngageAt = 0
        end
    else
        pursuit.nonXtarTargetId = 0
        pursuit.nonXtarEngageAt = 0
    end

    -- VF: four flags. engage is mode output; inFight is AssistTargetID. docs/COMBAT_OWNERS.md.
    if runtime.setAssist then runtime.setAssist(haveNPC, engage) end

    -- VF: auto-attack only in reach or wantsFight. Paused also requires hostile.
    local autoAttackOk = true
    if haveNPC and runtime.inFight() then
        local engineMode = (ctrl.mode == 'Roam' or ctrl.mode == 'Rush')
        if not engineMode then
            local tid = mq.TLO.Target.ID() or 0
            if not isHostileTarget(tid) then autoAttackOk = false end
        end
    end
    -- VF: combat_style is a play/settings latch, not decided here.
    local style = ctrl and ctrl.combat_style or 'Melee'
    local tid = mq.TLO.Target.ID() or 0
    -- VF: Roam only -- see desiredRange.
    local isPullStandBack = (ctrl.mode == 'Roam' and ctrl.pull_stand_back)
    -- VF: maySwing is ensureAttack. Melee close is AssistOn, not moveToward.
    if style == 'Melee' then
        if not isPullStandBack then
            if haveNPC and autoAttackOk and runtime.inFight() then
                if runtime.assistOn then
                    runtime.assistOn(tid)
                elseif runtime.ensureAttack then
                    runtime.ensureAttack(tid)
                end
            end
        end
    elseif style == 'Ranged' then
        local may = haveNPC and autoAttackOk and runtime.inFight()
        if may and tid > 0 then
            local mayWalk = (ctrl.mode ~= 'Manual')
                or ((tonumber(runtime.manualCommitId) or 0) == tid)
            runtime.rangedFightTick(tid, mayWalk)
        else
            if mq.TLO.Me.AutoFire() then mq.cmd('/autofire off') end
            if tid > 0 and runtime.stickHolding and runtime.stickHolding(tid) then
                stopMoving()
            end
        end
    end

    -- VF: after /attack on so Combat: is not sampled on the pre-swing tick.
    if ctrl.debug_mode and (os.clock() - (runtime.lastHunterDiagAt or 0)) > 1.5 then
        runtime.lastHunterDiagAt = os.clock()
        local t = mq.TLO.Target
        local dtid = (t() and t.ID()) or 0
        local tname = (t() and t.CleanName()) or 'none'
        local thp = (t() and t.PctHPs()) or -1
        local dist = (dtid > 0) and distToId(dtid) or -1
        local reach = (dtid > 0) and maxMeleeDistance(dtid) or 18
        local los = (dtid > 0) and hasLoS(dtid) or false
        local navActive = navLoaded() and mq.TLO.Navigation.Active() or false
        local stickState = 'n/a'
        if stickLoaded() then
            local on = false
            pcall(function() on = (mq.TLO.Stick.Active() or mq.TLO.Stick.Status() == 'ON') or false end)
            stickState = on and 'on' or 'off'
        end
        local isHostile = (dtid > 0) and isHostileTarget(dtid) or false
        local combat = mq.TLO.Me.Combat() or false
        local casting = isCasting()
        local moving = isMoveActive()
        -- VF: MQ2Melee owns /attack too -- melee=1 in the rails, and it drops the toggle
        -- VF: from 13 sites. Melee.Status names the reason (ENRAGE / INFURIATE / BACKING /
        -- VF: EVADING / FEIGNING / RANGE); its SHOW_ENRAGING and SHOW_OVERRIDE announces
        -- VF: are compile-time 0 so chat will never tell us. Melee.Target is ITS melee
        -- VF: target, and a mismatch with ours is the silent AttackOFF path.
        local meleeInfo = 'n/a'
        if runtime.meleeLoaded and runtime.meleeLoaded() then
            pcall(function()
                local ms = tostring(mq.TLO.Melee.Status() or '?')
                local mt = tonumber(mq.TLO.Melee.Target()) or 0
                meleeInfo = (ms:gsub('%s+$', ''))
                    .. ((mt ~= (tonumber(dtid) or 0)) and (' MT#' .. mt .. '/=us') or '')
            end)
        end
        print(string.format(
            '\ao[DEBUG]\ax Mode:%s Style:%s | Tgt:%s(#%d HP:%d%% Hostile:%s) | Dist:%.1f Reach:%.1f LoS:%s | Nav:%s Stick:%s Mov:%s | Eng:%s Combat:%s Cast:%s | XTar:%d | Melee:%s',
            tostring(ctrl.mode), tostring(ctrl.combat_style or 'Melee'), tostring(tname), tonumber(dtid) or 0, tonumber(thp) or 0, tostring(isHostile), tonumber(dist) or 0, tonumber(reach) or 18, tostring(los),
            tostring(navActive), stickState, tostring(moving), tostring(runtime.inFight()), tostring(combat), tostring(casting), tonumber(numXtar) or 0, meleeInfo))
    end

    -- VF: multi-pet: /say #petcmd -- mq.cmd cannot parse a leading #. Once per target.
    local assistThreshold = ctrl.pet_assist_at or 100
    local canCommandPets = hasActivePet()
    local petHoldEnabled = (ctrl.pet_hold_enabled ~= false) and canCommandPets

    -- VF: Puller Hunt Pet Pull: don't re-hold pets while navigating to mob.
    local isHuntPetApproach = ((ctrl.mode == 'Roam')
        and ctrl.pull_style == 'Pet' and haveNPC and not engage)

    if petHoldEnabled and not (haveNPC and engage) and not isHuntPetApproach then
        if not petState.petHoldActive then
            mq.cmd('/say #petcmd hold all')
            petState.petHoldActive = true
        end
    end

    if haveNPC and engage and canCommandPets then
        if not ctrl.running then
            setManualHunterPetHold(false)
        end
        local tid = mq.TLO.Target.ID() or 0
        local dueForRetry = (os.clock() - (petState.lastCmdAt or 0)) > 5.0
        if (tid ~= petState.lastCmdTargetId or dueForRetry) and not isCasting() then
            local tgtHp = pctHP(tid) or 100
            -- VF: Self-directed modes: character is leading combat directly, skip external MA aggro gate.
            local selfDirected = (not ctrl.running or ctrl.mode == 'Roam' or ctrl.mode == 'Rush')
            local engageOk = selfDirected or (playerHasAggro(tid) and playerIsEngagingTarget(tid))
            if tgtHp <= assistThreshold then
                if engageOk then
                    -- VF: Threshold met: send attack.
                    mq.cmd('/say #petcmd attack all')
                    petState.lastCmdTargetId = tid
                    petState.lastCmdAt = os.clock()
                    petState.petHoldActive = false
                    petState.holdIssuedForId = 0
                end
            elseif petHoldEnabled and not petState.petHoldActive then
                mq.cmd('/say #petcmd hold all')
                petState.petHoldActive = true
                petState.holdIssuedForId = tid
            end
        end
    else
        -- VF: No active NPC target or still pulling back to camp: reset command tracking.
        petState.lastCmdTargetId = 0
        if not ctrl.running and not mq.TLO.Me.Combat() and canCommandPets then
            setManualHunterPetHold(true)
        end
    end

    -- VF: offensive actions need a hostile. Self-directed pick is its own gate.
    local ENGINE_TARGETS_MODE = {
        ['Solo'] = true,
    }
    local combatReady = (not haveNPC or engage)
    if haveNPC and engage and not ENGINE_TARGETS_MODE[ctrl.mode] then
        local tid = mq.TLO.Target.ID() or 0
        if not isHostileTarget(tid) then
            -- VF: self-heal aims Me until restore ? keep buckets open while gem channel busy.
            local selfHealWindow = runtime.castBusy and runtime.castBusy()
            if not selfHealWindow then
                combatReady = false
            end
        end
    end

    -- VF: Combat col bucket — engine mood COMBAT opens In Combat / Always rows.
    -- VF: not the AssistOn inFight flag (runtime.inFight).
    local engineFight = false
    if runtime.engineInCombat then
        engineFight = not not runtime.engineInCombat()
    elseif runtime.inCombatState then
        engineFight = not not runtime.inCombatState()
    else
        pcall(function() engineFight = mq.TLO.Me.CombatState() == 'COMBAT' end)
    end

    -- VF: Gate 2 ? one pulse snapshot for this cast section.
    local pulse = runtime.takePulseSnapshot and runtime.takePulseSnapshot() or nil
    if pulse then numXtar = pulse.xtar or numXtar end

    -- VF: Gate 3 ? below combat_heal_pct: Panic ? Heal ? Cure. Burn dump disabled for now.
    if pulse and runtime.survivalNeeded and runtime.survivalNeeded(pulse) then
        if isMoveActive() and not (runtime.rushOnTheMove and runtime.rushOnTheMove()) then
            stopMoving()
        end
        runtime.freeBardBarForHeal()
        if os.clock() >= (runtime.combatHealRetryAt or 0) then
            local fired = runtime.survivalCast and runtime.survivalCast(pulse)
            -- VF: failed heal retry was 3s ? felt like heals were "skipped".
            runtime.combatHealRetryAt = fired and 0 or (os.clock() + 0.75)
        end
        -- VF: do not return ? Melee dump still runs while heal channels.
    end

    -- VF: Gate 4 ? heals + per-bucket offense. docs/COMBAT_TICK_IDEAL.md
    if runtime.needsCombatHeal and runtime.needsCombatHeal() then
        if isMoveActive() and not (runtime.rushOnTheMove and runtime.rushOnTheMove()) then
            stopMoving()
        end
        runtime.freeBardBarForHeal()
    end

    if runtime.castTick then runtime.castTick() end

    if isCasting() then
        castTracker.wasCasting = true
    elseif castTracker.wasCasting then
        castTracker.wasCasting = false
        if stickLoaded() then
            pcall(function()
                if mq.TLO.Stick.Status() == 'PAUSED' then mq.cmd('/stick unpause') end
            end)
        end
        if not castTracker.failed then
            castTracker.recordSuccess(castTracker.activeSpell or castTracker.lastSpell)
        end
        castTracker.activeSpell = nil
        clearCursor()
        -- VF: restore /attack in reach; re-close via AssistOn, not moveToward.
        local tid = mq.TLO.Target.ID() or 0
        local d = (tid > 0) and distToId(tid) or 999
        local maxReach = (tid > 0) and maxMeleeDistance(tid) or ((ctrl and ctrl.melee_dist) or MELEE_RANGE)
        if ctrl and ctrl.combat_style == 'Melee' and haveNPC
            and runtime.inFight() then
            if d <= maxReach then
                if mq.TLO.Me.Sitting() or mq.TLO.Me.Ducking() then mq.cmd('/stand') end
            elseif runtime.mayClose(tid) and tid > 0 then
                if runtime.assistOn then runtime.assistOn(tid) end
            end
        end
    end

    mq.doevents()

    -- VF: Melee/offense/filler only on CombatState COMBAT — combatReady is true with no NPC.
    if engineFight and runtime.meleeBucketCast then
        runtime.meleeBucketCast(numXtar, combatReady, engineFight)
    end

    -- VF: survival may return early; offense+filler still only when factually in COMBAT.
    local function offenseDump()
        if not engineFight then return end
        if runtime.offenseBucketCast then
            runtime.offenseBucketCast(numXtar, combatReady, engineFight)
        end
        if runtime.fillerAaDump then
            runtime.fillerAaDump(engineFight)
        end
    end

    -- VF: survival ladder may preempt in-flight cast (helper compares castPriority).
    local survOpts = { allowMoveGems = true, ignoreMinXtar = true }
    -- VF: Support role (Manager > Group). 'Support first' is the behavior that always
    -- VF: shipped: these bands preempt offense. 'DPS first' runs them selfOnly here and
    -- VF: replays the ALLY rows after the rotation, so a DPS with heals saves himself at
    -- VF: full speed but does not drop his rotation for a scratched ally. The threshold
    -- VF: is the row's Below % -- there is deliberately no setting for it.
    local dpsFirst = (ctrl.heal_priority == 'DPS first')
    local healOpts = survOpts
    if dpsFirst then
        healOpts = { allowMoveGems = true, ignoreMinXtar = true, selfOnly = true }
    end
    local HEAL_BANDS = { 'Cure', 'Heal', 'Tap', 'HoT' }
    if runtime.priorityPanicCast and runtime.priorityPanicCast() then offenseDump(); return end
    if runtime.bandCast then
        for _, band in ipairs(HEAL_BANDS) do
            if runtime.bandCast({ band }, numXtar, combatReady, engineFight, healOpts) then
                offenseDump(); return
            end
        end
    end

    -- VF: offenseBucketCast dumps instant AAs while gem busy; cast-time only when free.
    -- VF: burn fires burn_only rows as one multiline every BURN_ML_EVERY pulses. It
    -- VF: does not return early -- offense still runs, burn is additive on top.
    if ctrl.burn and runtime.burnCast then
        pcall(runtime.burnCast, numXtar, combatReady, engineFight)
    end
    offenseDump()

    -- VF: 'DPS first' only -- the ally half of the heal bands, after the rotation had its
    -- VF: turn. Deliberately last and non-returning: this is the leftover-time pass.
    if dpsFirst and runtime.bandCast then
        local allyOpts = { allowMoveGems = true, ignoreMinXtar = true, allyOnly = true }
        for _, band in ipairs(HEAL_BANDS) do
            if runtime.bandCast({ band }, numXtar, combatReady, engineFight, allyOpts) then return end
        end
    end
end

-- VF: Combat heal helpers live below combatTick (forward refs on runtime).

-- VF: explicit OOC Heal beats inference.
local function anyExplicitOocHeal()
    for i = 1, D.NUM_GEMS do
        local g = loadout.gems[i]
        if g and g.ooc_heal and g.spell and g.spell ~= '' then return true end
    end
    for _, a in pairs(loadout.aas or {}) do
        if a and a.enabled and a.ooc_heal then return true end
    end
    for _, it in pairs(loadout.items or {}) do
        if it and it.enabled and it.ooc_heal then return true end
    end
    for _, d in pairs(loadout.discs or {}) do
        if d and d.enabled and d.ooc_heal then return true end
    end
    return false
end

-- VF: explicitMode is hoisted -- do not rescan the loadout per gem.
local function isSelfHealEntry(entry, spellName, explicitMode)
    if not entry then return false end
    if entry.ooc_heal then return true end
    if explicitMode then return false end
    local role = runtime.castRole and runtime.castRole(entry) or nil
    -- VF: Panic is combat survival only ? never OOC top-off / selfHealCast.
    if role == 'Panic' then return false end
    if role == 'Buff' or role == 'PetBuff' or role == 'Summon' then
        return false
    end
    -- VF: Heal/HoT on Myself ? OOC top-off and combat heal floor.
    if role == 'Heal' or role == 'HoT' then
        if U.baseTok(entry.target) == 'Myself' then return true end
    end
    local typ = entry.cast_type or entry.t3_type
    if typ == 'Panic' then return false end
    if typ == 'Buff' or typ == 'PetBuff' or typ == 'Summon' then
        return false
    end
    if typ == 'HoT' and U.baseTok(entry.target) == 'Myself' then return true end
    local when = entry.when or ''
    if when == 'always' or when == 'missing pet' then
        return false
    end
    if when == 'missing buff' and typ ~= 'HoT' and role ~= 'HoT' then
        return false
    end
    if U.baseTok(entry.target) ~= 'Myself' then return false end
    if when == 'my HP <=' or when == 'HP <=' then return true end
    if entry.kind == 'heal' then return true end
    if spellName and spellName ~= '' then
        -- VF: memoize spellClassInfo by name.
        local hit = runtime.healKindCache[spellName]
        if hit == nil then
            local _, bene, kind = spellClassInfo(spellName)
            hit = (kind == 'heal' and bene) and true or false
            runtime.healKindCache[spellName] = hit
        end
        return hit
    end
    return false
end
runtime.isSelfHealEntry = function(entry, spellName)
    return isSelfHealEntry(entry, spellName, anyExplicitOocHeal())
end

local function hasSelfHealLoadout()
    local explicitMode = anyExplicitOocHeal()
    for i = 1, D.NUM_GEMS do
        local g = loadout.gems[i]
        if g and g.spell and g.spell ~= '' and isSelfHealEntry(g, g.spell, explicitMode) then return true end
    end
    for name, a in pairs(loadout.aas or {}) do
        if a and a.enabled and isSelfHealEntry(a, name, explicitMode) then return true end
    end
    for name, it in pairs(loadout.items or {}) do
        if it and it.enabled then
            local spellName = ''
            if runtime.itemClickSpell then
                spellName = runtime.itemClickSpell(name, it) or ''
            elseif it.spell and it.spell ~= '' then
                spellName = it.spell
            end
            if spellName ~= '' and isSelfHealEntry(it, spellName, explicitMode) then return true end
        end
    end
    for name, d in pairs(loadout.discs or {}) do
        if d and d.enabled and isSelfHealEntry(d, name, explicitMode) then return true end
    end
    return false
end

-- VF: Is HP low enough that we should be healing instead of doing damage?.
runtime.needsCombatHeal = function()
    if (tonumber(ctrl.combat_heal_pct) or 0) <= 0 then return false end
    if ctrl.combat_heal == false then return false end
    if not ctrl.running then return false end
    if mq.TLO.Me.Dead() then return false end
    if runtime.rushOnTheMove and runtime.rushOnTheMove() then return false end
    local myId = mq.TLO.Me.ID() or 0
    if myId <= 0 then return false end
    if pctHP(myId) > (tonumber(ctrl.combat_heal_pct) or 65) then return false end
    return hasSelfHealLoadout()
end

-- VF: selfHealCast: discs, then AAs, then gems. First fire wins. Honor Below %.
-- VF: HoT needs my HP% and missing on buff/short. Panic never rides this path.
-- VF: OOC top-off uses Settings post_combat_heal_pct ? gem Below % is combat-only.
local function selfHealCondOk(entry, spellName, myId)
    if not entry then return false end
    local role = runtime.castRole and runtime.castRole(entry) or nil
    if role == 'Panic' then return false end
    local pct = tonumber(entry.pct) or 100
    if pct <= 0 then return false end
    if runtime.postCombatHealActive then
        local target = tonumber(ctrl.post_combat_heal_pct) or 90
        if pctHP(myId) >= target then return false end
        if role == 'HoT' then
            if runtime.buffFactuallyUp and runtime.buffFactuallyUp(myId, spellName) then
                return false
            end
        end
        return true
    end
    if role == 'HoT' then
        if pctHP(myId) > pct then return false end
        if runtime.buffFactuallyUp and runtime.buffFactuallyUp(myId, spellName) then
            return false
        end
        return true
    end
    return conditionMet(entry.when or '', pct, spellName, myId, entry.cls)
end

runtime.selfHealCast = function()
    if mq.TLO.Me.Dead() then
        runtime.healBlockReason = 'dead'
        return false
    end
    if runtime.castTick then runtime.castTick() end
    freeBardBarForHeal()
    local cid, skill = 0, ''
    pcall(function()
        cid = mq.TLO.Me.Casting.ID() or 0
        skill = mq.TLO.Me.Casting.Skill() or ''
    end)
    if cid > 0 and skill == 'Singing' then
        freeBardBarForHeal()
    end
    if runtime.rushOnTheMove and runtime.rushOnTheMove() then
        runtime.healBlockReason = 'rush'
        return false
    end
    local barHeld = (cid > 0 and skill ~= 'Singing')
        or (runtime.castBusy and runtime.castBusy())
    if not barHeld and (mq.TLO.Me.Moving() or isMoveActive()) then
        stopMoving()
    end
    local myId = mq.TLO.Me.ID() or 0
    if myId <= 0 then return false end
    local explicitMode = anyExplicitOocHeal()

    -- VF: instant heal AAs/discs fire beside an in-flight gem; gems wait for free bar.
    for name, d in pairs(loadout.discs or {}) do
        if d and d.enabled and d.via ~= 'skill'
            and isSelfHealEntry(d, name, explicitMode)
            and selfHealCondOk(d, name, myId) then
            if runtime.isDiscReady(name) then
                local fired = runtime.fireDisc(name, d, myId)
                if fired == true then
                    return true
                end
                -- VF: wait/false ? next heal row (do not re-press this disc).
            end
        end
    end

    for name, a in pairs(loadout.aas or {}) do
        if a and a.enabled and isSelfHealEntry(a, name, explicitMode)
            and selfHealCondOk(a, name, myId) then
            if fireAA(name, a, myId) then return true end
        end
    end

    if barHeld then
        runtime.healBlockReason = (cid > 0) and 'casting' or 'cast-busy'
        return true
    end

    for name, it in pairs(loadout.items or {}) do
        if it and it.enabled then
            local spellName = ''
            if runtime.itemClickSpell then
                spellName = runtime.itemClickSpell(name, it) or ''
            elseif it.spell and it.spell ~= '' then
                spellName = it.spell
            end
            if spellName ~= '' and isSelfHealEntry(it, spellName, explicitMode)
                and selfHealCondOk(it, spellName, myId) then
                if fireItem(name, it, myId) then
                    runtime.healBlockReason = nil
                    return true
                end
            end
        end
    end

    for i = 1, D.NUM_GEMS do
        local g = loadout.gems[i]
        if g and g.spell and g.spell ~= '' and isSelfHealEntry(g, g.spell, explicitMode)
            and selfHealCondOk(g, g.spell, myId) then
            if castTracker.isLockedOut(g.spell) then
                runtime.healBlockReason = 'lockout:' .. g.spell
            elseif castGem(i, g, myId) then
                runtime.healBlockReason = nil
                return true
            else
                runtime.healBlockReason = runtime.healBlockReason or ('cast-refused:' .. g.spell)
            end
        end
    end
    runtime.healBlockReason = runtime.healBlockReason or 'no-ready-heal'
    return false
end

-- VF: After combat, top off with configured self-heals before hunt/travel resumes.
runtime.postCombatHealTick = function()
    return runtime.selfHealCast()
end

-- VF: urgent heal interrupts a song. See ta/heal.lua. Old-dev T2 name.
require('vft.heal')(mq, runtime, { tag = '[VF heal]' })

runtime.buffRetryOk = runtime.buffRetryOk or function() return true end
runtime.buffTryRecorded = runtime.buffTryRecorded or function() end
require('vft.aaspend').install(runtime, {
    cfg = cfg,
    getLoadout = function() return loadout end,
})
-- VF: Phase 0 diagnostics. Nothing consumes these yet -- /vf state and /vf ticks only.
-- VF: EQ engine mood (Me.CombatState) — docs/STATE_ENGINE.md / COMBAT_STATE.md.
require('vft.enginestate').install(runtime, { ctrl = function() return ctrl end })
do
    local chat = require('vft.chat')
    chat.setDebug(function() return ctrl and ctrl.debug_mode end)
    runtime.chat = chat
end
require('vft.profile').install(runtime, { cfg = cfg })
require('vft.melee').install(runtime, {
    cfg = cfg,
    ctrl = function() return ctrl end,
})
require('vft.castkind').install(runtime)
require('vft.disc').install(runtime, {
    ctrl = function() return ctrl end,
    petState = function() return petState end,
    getLoadout = function() return loadout end,
    setTarget = setTarget,
    clearCursor = clearCursor,
})
require('vft.mq2cast').install(runtime, {
    ctrl = function() return ctrl end,
    castTracker = function() return castTracker end,
    getLoadout = function() return loadout end,
})
Boot.install(runtime, {
    ctrl = function() return ctrl end,
    stickLoaded = stickLoaded,
    navLoaded = navLoaded,
})
if runtime.bootEnter then
    -- VF: DanNet missing is fatal at /lua run vf. Char-change bootEnter only prints.
    if runtime.bootEnter() == false then
        print('\ar[VF]\ax stopped.')
        return
    end
end
require('vft.buckets').install(runtime, {
    getLoadout = function() return loadout end,
    getCtrl = function() return ctrl end,
    countPackMobs = countPackMobs,
    resolveTargetId = resolveTargetId,
    rowBlocked = rowBlocked,
    conditionMet = conditionMet,
    isIdleSelfBuff = isIdleSelfBuff,
    isDetrimentalAction = isDetrimentalAction,
    isHostileTarget = isHostileTarget,
    isTargetInRange = isTargetInRange,
    fireAA = fireAA,
    fireItem = fireItem,
    fireDisc = function(name, entry, id) return runtime.fireDisc(name, entry, id) end,
    isDiscReady = function(name) return runtime.isDiscReady(name) end,
    discWait = function(name) return runtime.discWait(name) end,
    castGem = castGem,
    castTracker = castTracker,
    isCasting = isCasting,
    castBusy = function()
        return not not (runtime.castBusy and runtime.castBusy())
    end,
    isMoveActive = isMoveActive,
    freeBardBarForHeal = freeBardBarForHeal,
    meDead = function() return not not mq.TLO.Me.Dead() end,
    stopMovingIfNeeded = function()
        if isMoveActive() and not (runtime.rushOnTheMove and runtime.rushOnTheMove()) then
            stopMoving()
        end
    end,
})
require('vft.pulse').install(runtime, {
    getCtrl = function() return ctrl end,
    countPackMobs = countPackMobs,
    pctHP = pctHP,
    isPoisonedOrDiseased = isPoisonedOrDiseased,
    hasSelfHealLoadout = hasSelfHealLoadout,
})
require('vft.buff').install(runtime, {
    ctrl = ctrl,
    getCtrl = function() return ctrl end,
    loadout = loadout,
    getLoadout = function() return loadout end,
    petState = petState,
    castTracker = castTracker,
    isCasting = isCasting,
    isCombat = isCombat,
    isMoveActive = isMoveActive,
    pctHP = pctHP,
    hasSelfHealLoadout = hasSelfHealLoadout,
    isIdleSelfBuff = isIdleSelfBuff,
    rowBlocked = rowBlocked,
    conditionMet = conditionMet,
    fireAA = fireAA,
    fireItem = fireItem,
    castGem = castGem,
})
require('vft.ooc').install(runtime, {
    ctrl = function() return ctrl end,
    stopMoving = stopMoving,
    pctHP = pctHP,
    hasSelfHealLoadout = hasSelfHealLoadout,
    isCasting = isCasting,
    isMoveActive = isMoveActive,
})

-- VF: True while Rush is waiting to leave: still healing, still missing a self buff, or still on the cast bar.
runtime.rushPrepNeeded = function()
    if isCasting() then return true end
    local myId = mq.TLO.Me.ID() or 0
    if myId <= 0 then return false end
    if (tonumber(ctrl.post_combat_heal_pct) or 0) > 0 and ctrl.post_combat_heal ~= false
        and not runtime.postCombatHealGaveUp then
        local targetPct = tonumber(ctrl.post_combat_heal_pct) or 90
        if pctHP(myId) < targetPct and hasSelfHealLoadout() then return true end
    end
    if ctrl.maintain_buffs == false then return false end
    -- VF: always / persist songs never block Rush departure.
    for name, a in pairs(loadout.aas or {}) do
        if a and a.enabled and a.when == 'missing buff' and a.cls ~= 'Brd' then
            local tok = U.baseTok(a.target)
            if (tok == 'Myself' or tok == 'Self') then
                local aPct = tonumber(a.pct) or 100
                if aPct > 0 and not a.burn_only and not rowBlocked(a, name, myId)
                    and conditionMet(a.when, aPct, name, myId, a.cls) then
                    return true
                end
            end
        end
    end
    for i = 1, D.NUM_GEMS do
        local g = loadout.gems[i]
        if g and g.spell and g.spell ~= '' and g.when == 'missing buff' and g.cls ~= 'Brd' then
            local tok = U.baseTok(g.target)
            if (tok == 'Myself' or tok == 'Self') then
                local pctVal = tonumber(g.pct) or 100
                local buffKey = U.sungKey(g.spell, myId)
                local retryOk = runtime.buffRetryOk(buffKey)
                if pctVal > 0 and retryOk and not g.burn_only and not castTracker.isLockedOut(g.spell)
                    and not rowBlocked(g, g.spell, myId)
                    and conditionMet(g.when, pctVal, g.spell, myId, g.cls) then
                    return true
                end
            end
        end
    end
    return false
end

-- VF: Out-of-combat self-buff pass.
local function buffTick()
    if runtime.buffTick then return runtime.buffTick() end
    return false
end

require('vft.cmd').install(runtime, {
    getCtrl = function() return ctrl end,
    saveLoadout = saveLoadout,
    fullStop = fullStop,
    setManualHunterPetHold = setManualHunterPetHold,
    buffTick = buffTick,
    clearCursor = clearCursor,
    addIgnore = addIgnore,
    removeIgnore = removeIgnore,
    toggleEngine = function() UI.toggleEngine() end,
    spawnMeleeMetrics = spawnMeleeMetrics,
    stickNeedsHitboxOverride = stickNeedsHitboxOverride,
    hitboxEdgeDist = hitboxEdgeDist,
})

-- VF: One PID scan for every satellite. Do not call Script() as a function --
-- VF: slash names make s() nil.
runtime.satPid = function(name)
    name = tostring(name or ''):gsub('\\', '/'):lower()
    if name == '' then return nil end
    local found = nil
    pcall(function()
        local pids = tostring(mq.TLO.Lua.PIDs() or '')
        for tok in pids:gmatch('%d+') do
            local pid = tonumber(tok)
            local s = pid and mq.TLO.Lua.Script(pid) or nil
            if s then
                local st, sn, sp = '', '', ''
                pcall(function() st = tostring(s.Status() or '') end)
                if st == 'RUNNING' or st == 'PAUSED' then
                    pcall(function() sn = tostring(s.Name() or '') end)
                    pcall(function() sp = tostring(s.Path() or '') end)
                    sn = sn:gsub('\\', '/'):lower()
                    sp = sp:gsub('\\', '/'):lower()
                    if sn == name or sp:find(name, 1, true) then
                        found = pid
                        return
                    end
                end
            end
        end
    end)
    return found
end

runtime.satRunning = function(name)
    return runtime.satPid(name) ~= nil
end

-- VF: stop by pid -- name alone misses slash-named scripts. NEVER issue both:
-- VF: the second stop targets a pid the first one already freed.
runtime.satStop = function(name)
    local pid = runtime.satPid(name)
    if not pid then return false end
    mq.cmdf('/lua stop %d', pid)
    return true
end

runtime.satStart = function(name)
    if runtime.satPid(name) then return false end
    mq.cmdf('/lua run %s', name)
    return true
end

-- VF: true = it started the satellite, false = it stopped one.
runtime.satToggle = function(name)
    if runtime.satStop(name) then return false end
    return runtime.satStart(name)
end

-- VF: Bags is a satellite (/lua run vft/inv); Mini HUD and /vf bags toggle it.
-- VF: [VF:Inv] Opening/Closing come from the satellite, not the engine toggle.
runtime.bagsPid = function() return runtime.satPid('vft/inv') end
runtime.bagsRunning = function() return runtime.satRunning('vft/inv') end
runtime.toggleBags = function() runtime.satToggle('vft/inv') end

-- VF: Control plane for satellites -- config/vf_ctrl.txt, polled by the daemon.
-- VF: This was an ${VF.*} TLO and it crashed the client on /lua stop; see
-- VF: vft/ipc.lua. A satellite that cannot read it assumes Pause, never guesses.
-- VF: On runtime so vft.lua gains no chunk-local (200-local cap).
runtime.ipc = require('vft.ipc')
runtime.ctrlNextPub = 0
runtime.ctrlPublish = function(force)
    local now = os.clock()
    if not force and now < (runtime.ctrlNextPub or 0) then return end
    runtime.ctrlNextPub = now + 0.25
    local travel = 'none'
    pcall(function()
        if runtime.travel and runtime.travel.active and runtime.travel.active() then
            travel = tostring(runtime.travel.policy() or 'none')
        end
    end)
    runtime.ipc.write('ctrl', {
        mode    = (ctrl and ctrl.mode) or 'Manual',
        running = not not (ctrl and ctrl.running),
        debug   = not not (ctrl and ctrl.debug_mode),
        travel  = travel,
        -- VF: heartbeat. A frozen tick means the loader is wedged, not paused.
        tick    = string.format('%.2f', now),
    })
end
runtime.ctrlPublish(true)

-- VF: Combat daemon satellite (/lua run vft/fight); /vf fight toggles it. /vfc prints state.
runtime.fightPid = function() return runtime.satPid('vft/fight') end
runtime.fightRunning = function() return runtime.satRunning('vft/fight') end

runtime.toggleFight = function()
    if runtime.satToggle('vft/fight') then
        runtime.fightWanted, runtime.fightFails, runtime.fightGaveUp = true, 0, false
        print('\ag[VF]\ax Combat daemon launching... (/vfc for state)')
    else
        -- VF: an explicit stop must stick -- do not let the supervisor undo it.
        runtime.fightWanted = false
        print('\ag[VF]\ax Combat daemon stopping...')
    end
end

-- VF: loader owns the daemon's life. Starts it on boot and restarts a dead one.
-- VF: Backoff is not optional: a daemon that fails to load would otherwise be
-- VF: respawned every pulse forever.
runtime.fightWanted  = true
runtime.fightNextTry = 0
runtime.fightFails   = 0
runtime.fightSupervise = function()
    if not runtime.fightWanted then return end
    local now = os.clock()
    if now < (runtime.fightNextTry or 0) then return end
    if runtime.fightRunning() then
        runtime.fightFails, runtime.fightNextTry = 0, now + 2.0
        return
    end
    if (runtime.fightFails or 0) >= 3 then
        if not runtime.fightGaveUp then
            runtime.fightGaveUp = true
            print('\ay[VF]\ax Combat daemon will not stay up - giving up. /vf fight to retry.')
        end
        return
    end
    runtime.fightFails   = (runtime.fightFails or 0) + 1
    runtime.fightNextTry = now + 3.0
    runtime.satStart('vft/fight')
end

toggleVfInv = function()
    if runtime.toggleBags then runtime.toggleBags() end
end

-- VF: /ta* names are retired. Unbind first so a reload does not leave the old one live.
pcall(function() mq.unbind('/tabags') end)
pcall(function() mq.unbind('/vfinv') end)
mq.bind('/vfinv', toggleVfInv)
-- VF: /tapoint retired -- use /vf wp_loop | wp_guide | wp_travel.
pcall(function() mq.unbind('/tapoint') end)
pcall(function() mq.unbind('/t2bags') end)

pcall(function() mq.unbind('/tavault') end)
pcall(function() mq.unbind('/vfvault') end)
mq.bind('/vfvault', function()
    mq.cmd('/say #vault_merchant')
end)
pcall(function() mq.unbind('/t2vault') end)

pcall(function() mq.unbind('/tamapnav') end)
pcall(function() mq.unbind('/vfmapnav') end)
pcall(function() mq.unbind('/t2mapnav') end)
runtime.mapNavCmd = function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        local a = select(i, ...)
        if a ~= nil and tostring(a) ~= '' then
            parts[#parts + 1] = tostring(a)
        end
    end
    local line = table.concat(parts, ' ')
    if runtime.applyMapNavLine then runtime.applyMapNavLine(line) end
end
mq.bind('/vfmapnav', function(...) runtime.mapNavCmd(...) end)
pcall(function()
    -- VF: Defend on left-click (same %x,%y path as Ignore). RMB mapclick does not feed empty dirt.
    mq.cmd('/mapclick left shift clear')
    mq.cmd('/mapclick left shift /vfmapnav ignore %x,%y')
    mq.cmd('/mapclick left ctrl+shift clear')
    mq.cmd('/mapclick left ctrl+shift /vfmapnav defend %x,%y')
    mq.cmd('/mapclick left alt+shift clear')
    mq.cmd('/mapclick shift clear')
    mq.cmd('/mapclick left ctrl clear')
    mq.cmd('/mapclick left ctrl /vfmappoint %x,%y')
    print('\ag[VF]\ax map: Shift+LMB = travelIgnore | Ctrl+Shift+LMB = travelDefend | Ctrl+LMB = Guide pin')
end)

pcall(function() mq.unbind('/tamappoint') end)
pcall(function() mq.unbind('/vfmappoint') end)
mq.bind('/vfmappoint', function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        local a = select(i, ...)
        if a ~= nil and tostring(a) ~= '' then
            parts[#parts + 1] = tostring(a)
        end
    end
    if runtime.addRouteLocFromMapLine then runtime.addRouteLocFromMapLine(table.concat(parts, ' ')) end
end)

-- VF: Manager is a satellite (/lua run vft/mgr); gear and /vfmgr toggle it.
runtime.mgrPid = function() return runtime.satPid('vft/mgr') end
runtime.mgrRunning = function() return runtime.satRunning('vft/mgr') end

runtime.toggleManager = function()
    if runtime.satToggle('vft/mgr') then
        print('\ag[VF]\ax Manager launching...')
    else
        print('\ag[VF]\ax Manager stopping...')
    end
end
runtime.toggleSettings = runtime.toggleManager
runtime.toggleT3 = runtime.toggleManager

pcall(function() mq.unbind('/vfmgr') end)
mq.bind('/vfmgr', function()
    if runtime.toggleManager then runtime.toggleManager() end
end)

-- VF: Waypoints mini-bar satellite (/lua run vft/waypoints); /vf waypoints toggles it.
runtime.waypointsPid = function() return runtime.satPid('vft/waypoints') end

runtime.toggleWaypoints = function()
    if runtime.satToggle('vft/waypoints') then
        print('\ag[VF]\ax Waypoints launching...')
    else
        print('\ag[VF]\ax Waypoints stopping...')
    end
end

mq.imgui.init('VFEngine', draw)
print('\ag[VF]\ax loaded v' ..
    VERSION ..
    '. Data: ' ..
    (DATA_OK and 'vft_data.lua OK' or 'MISSING -- vft_data.lua (or leftover triune_data.lua)') ..
    '. Commands: /vf (/ta is an EQ alias for /target). Stop with /lua stop vf.')

-- VF: no-ops unless vft/profile.lua loaded, so a failed require cannot stall the tick.
runtime.profCall = runtime.profCall or function(_, fn, ...) return pcall(fn, ...) end
runtime.profLoop = runtime.profLoop or function() end

local function runMainLoop()
    while open do
        mq.doevents()
        -- VF: Esc hard-stops /nav every pulse (not only ImGui / pause chase).
        if runtime.escapeKeyDown and runtime.escapeKeyDown() then
            if runtime.escapeHardStopNav then runtime.escapeHardStopNav() end
        end
        runtime.profLoop()
        runtime.ctrlPublish()
        runtime.fightSupervise()
        if not runtime.buffDumpDone and myName and myName ~= ''
            and mq.TLO.Me.ID() and (mq.TLO.Me.ID() or 0) > 0
            and loadout.gems and next(loadout.gems) then
            runtime.buffDumpDone = true
            pcall(function() runtime.dumpSelfBarToFile('autoload') end)
        end
        local nm = mq.TLO.Me.CleanName()
        if nm and nm ~= '' and nm ~= myName then
            myName = nm
            onCharacterChanged()
            runtime.buffDumpDone = false
            UI.resetTracker()
            -- VF: camp restored from a save; no map circle is drawn.
            reconcileSungBuffs()                                      -- don't re-sing bard buffs that are already up
            reconcilePets()                                           -- don't re-summon pets that are already out
            runtime.lastSig = loadoutSig(); runtime.autoDirty = false -- baseline; don't save what we just loaded
        end
        local curZone = mq.TLO.Zone.ShortName()
        if curZone and curZone ~= '' and curZone ~= runtime.lastZoneShort then
            runtime.lastZoneShort = curZone
            -- VF: ShortName can flip before the entered-zone event; drop map-nav here too.
            if runtime.clearRushTrip then runtime.clearRushTrip() elseif runtime.clearPlayerNav then runtime.clearPlayerNav() end
            stopMoving()
            pursuit.lastNavLoc = nil
            pursuit.lastNavTargetId = 0
            pursuit.id = 0
            runtime.navReset('zone')
            if runtime.applyZoneRoute then runtime.applyZoneRoute() end
        end
        -- VF: (Cursor items are cleared on-demand prior to actions or post-cast completion).
        local now = os.clock()
        -- VF: /attack on lives in combatTick (after retarget). Pulse only on frames tick skipped.
        if runtime.castTick then pcall(runtime.castTick) end
        -- VF: Guide repin must beat /nav "Reached" — combatTick at 0.4s overshoots chain=20.
        if runtime.pullerRushing and runtime.pullerRushing() and runtime.pullerRushTick then
            pcall(runtime.pullerRushTick)
        end
        -- VF: self buffs are OOC-owned (ta/ooc.lua). No side buffTick during PROGRAM/Rush.
        local tickNeed = 0.4
        pcall(function()
            if mq.TLO.Me.Combat() or mq.TLO.Me.CombatState() == 'COMBAT'
                or runtime.manualFightArmed or ((tonumber(runtime.manualCommitId) or 0) > 0)
                or (runtime.pullerRushing and runtime.pullerRushing()) then
                tickNeed = 0.15
            else
                local tid = mq.TLO.Target.ID() or 0
                if (tid > 0 and isHostileTarget(tid))
                    or (runtime.closestThreat and runtime.closestThreat(runtime.rushNear or 80)) then
                    tickNeed = 0.15
                end
            end
        end)
        local didCombatTick = false
        if (now - runtime.lastTick) > tickNeed then
            local ok, err = runtime.profCall('combatTick', combatTick)
            if not ok and err then
                print('\ar[VF error]\ax combatTick failed: ' .. tostring(err))
            end
            runtime.lastTick = now
            runtime.wasRunning = true
            didCombatTick = true
        end
        if not didCombatTick and runtime.pulseMeleeAttack then
            pcall(runtime.pulseMeleeAttack)
        end

        -- VF: auto-save: persist the loadout ~1.5s after any change (no Save click needed).
        local sig = loadoutSig()
        if sig ~= runtime.lastSig then
            runtime.lastSig = sig; runtime.autoDirty = true; runtime.autoDirtyAt = os.clock()
        end
        if runtime.autoDirty and (os.clock() - runtime.autoDirtyAt) > 1.5 then
            -- VF: only clear dirty on a write that landed. Clearing unconditionally
            -- VF: dropped the change on a failed write and never retried it.
            if saveLoadout(true) then
                runtime.autoDirty = false
            else
                runtime.autoDirtyAt = os.clock()
            end
        end

        -- VF: last step of the cycle. MQ2AASpend does the buying; this syncs the ini, prunes maxed
        -- VF: AAs, and nudges the plugin while runtime.aaIdle() holds.
        if runtime.aaSpendTick then
            local oka, erra = runtime.profCall('aaSpend', runtime.aaSpendTick)
            if not oka and erra then
                print('\ar[VF error]\ax aa spend failed: ' .. tostring(erra))
            end
        end
        if runtime.bootTick then
            local okm, errm = runtime.profCall('boot', runtime.bootTick)
            if not okm and errm then
                print('\ar[VF error]\ax boot tick failed: ' .. tostring(errm))
            end
        end
        if runtime.displaceTick then
            pcall(runtime.displaceTick)
        end
        if runtime.pollMapNavClick then
            pcall(runtime.pollMapNavClick)
        end
        if runtime.pollMapDefendClick then
            pcall(runtime.pollMapDefendClick)
        end
        if runtime.pollMapPointClick then
            pcall(runtime.pollMapPointClick)
        end

        -- VF: Map open ? tight loop so Shift+RMB / map polls do not miss the click.
        local mapOpenNow = false
        pcall(function()
            local w = mq.TLO.Window('MapWindow')
            mapOpenNow = w and w.Open and w.Open()
        end)
        -- VF: Hot wake 100ms when swinging / COMBAT / armed / hostile on target or pack.
        local loopMs = 150
        pcall(function()
            if mq.TLO.Me.Combat() or mq.TLO.Me.CombatState() == 'COMBAT'
                or runtime.manualFightArmed or ((tonumber(runtime.manualCommitId) or 0) > 0) then
                loopMs = 100
            else
                local tid = mq.TLO.Target.ID() or 0
                if (tid > 0 and isHostileTarget(tid))
                    or (runtime.closestThreat and runtime.closestThreat(runtime.rushNear or 80)) then
                    loopMs = 100
                end
            end
        end)
        if mapOpenNow then
            mq.delay(0)
        else
            mq.delay(loopMs)
        end
    end
end

runMainLoop()
-- VF: clear the control file first -- the daemon reads "loader gone" from its
-- VF: absence and exits on its own even if this shutdown block never runs.
pcall(function() if runtime.ipc then runtime.ipc.clear('ctrl') end end)
-- VF: loader owns the daemon's life; its dead-man switch is only the backstop.
pcall(function() if runtime.satStop then runtime.satStop('vft/fight') end end)
pcall(function() mq.cmd('/squelch /maploc remove') end)
pcall(function() mq.cmd('/mapclick left shift clear') end)
pcall(function() mq.cmd('/mapclick left ctrl+shift clear') end)
pcall(function() mq.cmd('/mapclick shift clear') end)
pcall(function() mq.cmd('/mapclick left alt+shift clear') end)
pcall(function() mq.cmd('/mapclick left ctrl clear') end)
pcall(function() mq.unbind('/vfmapnav') end)
pcall(function() mq.unbind('/vfmappoint') end)
pcall(function() mq.unbind('/vfinv') end)
pcall(function() mq.unbind('/vfrun') end)
pcall(function() mq.unbind('/vf') end)
pcall(function() mq.unbind('/vfvault') end)
-- VF: retired names, still unbound on exit so an old session cannot leave one live.
pcall(function() mq.unbind('/tamapnav') end)
pcall(function() mq.unbind('/tamappoint') end)
pcall(function() mq.unbind('/t2mapnav') end)
pcall(function() mq.unbind('/tabags') end)
pcall(function() mq.unbind('/tapoint') end)
pcall(function() mq.unbind('/t2bags') end)
pcall(function() mq.unbind('/tarun') end)
pcall(function() mq.unbind('/t2run') end)
pcall(function() mq.unbind('/ta') end)
pcall(function() mq.unbind('/t2') end)
pcall(function() mq.unbind('/tavault') end)
pcall(function() mq.unbind('/t2vault') end)
saveLoadout(true)

