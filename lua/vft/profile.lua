-- VF: tick profiler. Off by default. /vf ticks.

local mq = require('mq')

local M = {}

function M.install(runtime, deps)
    deps = deps or {}
    local cfg = deps.cfg or (mq.configDir or '.')

    local st = { on = false, since = 0, loops = 0, rows = {} }
    runtime.profState = st

    local function row(name)
        local r = st.rows[name]
        if not r then
            r = { n = 0, ms = 0, peak = 0 }
            st.rows[name] = r
        end
        return r
    end

    -- VF: drop-in for pcall(fn) at a tick site. Returns exactly what pcall returns, so a
    -- VF: call site converts by swapping the word and adding a name -- and reverts the same way.
    function runtime.profCall(name, fn, ...)
        if not st.on then return pcall(fn, ...) end
        local t0 = os.clock()
        local ok, err = pcall(fn, ...)
        local dt = (os.clock() - t0) * 1000
        local r = row(name)
        r.n = r.n + 1
        r.ms = r.ms + dt
        if dt > r.peak then r.peak = dt end
        return ok, err
    end

    function runtime.profLoop()
        if st.on then st.loops = st.loops + 1 end
    end

    function runtime.profReset()
        st.loops = 0
        st.rows = {}
        st.since = os.clock()
    end

    function runtime.profReport(quiet)
        local span = os.clock() - (st.since or 0)
        if span <= 0 then span = 0.001 end
        local names = {}
        for k in pairs(st.rows) do names[#names + 1] = k end
        table.sort(names, function(a, b) return (st.rows[a].ms or 0) > (st.rows[b].ms or 0) end)

        local lines = {}
        lines[#lines + 1] = string.format('=== TA tick profile  %s  %.1fs  state=%s ===',
            os.date('%Y-%m-%d %H:%M:%S'), span,
            tostring(runtime.resolveState and runtime.resolveState() or '?'))
        lines[#lines + 1] = string.format('main loop: %d iterations  (%.2f/sec)',
            st.loops, st.loops / span)
        lines[#lines + 1] = string.format('%-14s %8s %9s %9s %9s %7s',
            'subsystem', 'calls', 'calls/s', 'avg ms', 'peak ms', '%% cpu')
        local totalMs = 0
        for _, nm in ipairs(names) do
            local r = st.rows[nm]
            totalMs = totalMs + r.ms
            lines[#lines + 1] = string.format('%-14s %8d %9.2f %9.3f %9.3f %6.2f%%',
                nm, r.n, r.n / span, r.ms / math.max(r.n, 1), r.peak, (r.ms / (span * 1000)) * 100)
        end
        lines[#lines + 1] = string.format('total measured: %.1f ms over %.1fs = %.2f%% of wall clock',
            totalMs, span, (totalMs / (span * 1000)) * 100)

        if not quiet then
            for _, l in ipairs(lines) do print('\ag[VF]\ax ' .. l) end
        end
        pcall(function()
            local f = io.open(cfg .. '/ta_ticks.log', 'a')
            if not f then return end
            for _, l in ipairs(lines) do f:write(l .. '\n') end
            f:write('\n')
            f:close()
        end)
    end

    function runtime.profToggle()
        if st.on then
            st.on = false
            runtime.profReport()
            print('\ag[VF]\ax tick profiling \arOFF\ax -- written to config/ta_ticks.log')
        else
            runtime.profReset()
            st.on = true
            print('\ag[VF]\ax tick profiling \agON\ax -- run \ay/vf ticks\ax again to stop and report.')
        end
    end

    return M
end

return M
