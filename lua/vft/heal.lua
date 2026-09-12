-- VF: urgent heal /stopsong. A song resumes; a death does not. Only break songs, never a real cast.

return function(mq, runtime, deps)
    deps = deps or {}
    local minGapSec = deps.minGapSec or 0.6
    local tag = deps.tag or '[VF heal]'

    local function casting()
        local id, name, skill = 0, '', ''
        pcall(function()
            id = mq.TLO.Me.Casting.ID() or 0
            name = mq.TLO.Me.Casting.Name() or ''
            skill = mq.TLO.Me.Casting.Skill() or ''
        end)
        return id, name, skill
    end

    -- VF: lock is bardHoldUntil or an instrument/song on the bar. Never /stopsong a real spell.
    local function breakSongLock(why)
        local now = os.clock()
        if (now - (runtime.t2StopSongAt or 0)) < minGapSec then return false end

        local held = (runtime.bardHoldUntil or 0) > now
        local id, name, skill = casting()
        -- VF: every instrument skill holds the bar, not just Singing -- Denon's sat through a heal.
        local singing = (id > 0) and runtime.bardCastSkill ~= nil and runtime.bardCastSkill(skill) == true

        if not held and not singing then return false end

        runtime.t2StopSongAt = now
        runtime.bardHoldUntil = 0
        if singing then
            if type(runtime.freeBardBarForHeal) == 'function' then
                runtime.freeBardBarForHeal()
            else
                mq.cmd('/stopsong')
                mq.delay(400)
            end
            print(string.format('\ay%s\ax %s -- interrupted "%s" to heal.', tag, why, name))
        end
        return true
    end

    -- VF: wrap selfHealCast -- it bails while anything is casting, including persist songs.
    local baseCast = runtime.selfHealCast
    if type(baseCast) == 'function' then
        runtime.selfHealCast = function()
            breakSongLock('self heal')
            return baseCast()
        end
    end
end
