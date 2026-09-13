-- VF: overlay GitHub main onto mq.luaDir. Mgr Settings + /lua run vfup.
-- VF: owned set only. Never vft/config ini. Reload is Manager's job, not this module's CLI.

local mq = require('mq')

local M = {}

M.REPO = 'belvue/veilfall-triune'
M.BRANCH = 'main'
M.releaseSha = ''
M.note = ''
M.err = ''

local job = nil
local checkedAt = 0

local function luaDir()
    local dir = ''
    pcall(function() dir = tostring(mq.luaDir or '') end)
    if dir == '' or dir == 'NULL' then
        dir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
        dir = dir:gsub('[/\\]vft[/\\]?$', '')
    end
    return dir:gsub('/', '\\'):gsub('\\+$', '')
end

local function tempDir()
    local t = os.getenv('TEMP') or os.getenv('TMP') or '.'
    return t:gsub('/', '\\'):gsub('\\+$', '')
end

local function readFile(path)
    local f = io.open(path, 'r')
    if not f then return '' end
    local s = f:read('*a') or ''
    f:close()
    return s:gsub('%s+$', '')
end

function M.short(sha)
    sha = tostring(sha or ''):gsub('%s+', '')
    if sha == '' then return '' end
    return sha:sub(1, 7)
end

function M.currentSha()
    return readFile(luaDir() .. '\\vft\\.rev')
end

function M.busy()
    return job ~= nil
end

local PS = [=[
param(
    [Parameter(Mandatory = $true)][string]$LuaDir,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [ValidateSet('check','update')][string]$Mode = 'update'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

function Write-Status([string]$line) {
    Set-Content -Path $OutFile -Value $line -Encoding ascii
}

Write-Status 'run'
$LuaDir = [IO.Path]::GetFullPath($LuaDir)
if (-not (Test-Path $LuaDir)) {
    Write-Status "err lua dir missing"
    exit 1
}

$repo = 'belvue/veilfall-triune'
$branch = 'main'
$token = $env:VF_GITHUB_TOKEN
$headers = @('-sL', '-H', 'User-Agent: VF')
if ($token) { $headers += @('-H', "Authorization: Bearer $token") }

$tmp = Join-Path $env:TEMP ('vfup-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $apiFile = Join-Path $tmp 'sha.json'
    $apiUrl = "https://api.github.com/repos/$repo/commits/$branch"
    & curl.exe @headers -o $apiFile $apiUrl
    if ($LASTEXITCODE -ne 0) { throw "curl sha $LASTEXITCODE" }
    $json = Get-Content $apiFile -Raw -ErrorAction SilentlyContinue
    if (-not $json) { throw 'empty sha response' }
    if ($json -match 'API rate limit exceeded') { throw 'GitHub rate limit' }
    if ($json -notmatch '"sha"\s*:\s*"([0-9a-f]{40})"') { throw 'no sha in response' }
    $sha = $Matches[1]

    if ($Mode -eq 'check') {
        Write-Status "ok sha $sha"
        exit 0
    }

    $revFile = Join-Path $LuaDir 'vft\.rev'
    $old = ''
    if (Test-Path $revFile) { $old = (Get-Content $revFile -Raw).Trim() }
    if ($old -eq $sha) {
        Write-Status "ok up-to-date $sha"
        exit 0
    }

    $zip = Join-Path $tmp 'vf.zip'
    $zipUrl = "https://codeload.github.com/$repo/zip/refs/heads/$branch"
    & curl.exe @headers -o $zip $zipUrl
    if ($LASTEXITCODE -ne 0) { throw "curl zip $LASTEXITCODE" }
    if (-not (Test-Path $zip) -or ((Get-Item $zip).Length -lt 1000)) { throw 'zip too small' }

    & tar.exe -xf $zip -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "tar $LASTEXITCODE" }

    $srcRoot = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'veilfall-triune-*' } | Select-Object -First 1
    if (-not $srcRoot) { throw 'zip layout' }
    $luaSrc = Join-Path $srcRoot.FullName 'lua'
    $vfSrc = Join-Path $luaSrc 'vf.lua'
    if (-not (Test-Path $vfSrc)) { throw 'zip has no lua/vf.lua' }

    foreach ($name in @('vf.lua', 'vft.lua', 'vfup.lua')) {
        $from = Join-Path $luaSrc $name
        if (Test-Path $from) {
            Copy-Item $from (Join-Path $LuaDir $name) -Force
        }
    }

    $vftSrc = Join-Path $luaSrc 'vft'
    $vftDst = Join-Path $LuaDir 'vft'
    if (Test-Path $vftSrc) {
        New-Item -ItemType Directory -Path $vftDst -Force | Out-Null
        Get-ChildItem $vftSrc -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($vftSrc.Length).TrimStart('\', '/')
            if ($rel -match '^[\\/]?config[\\/]' -and $_.Extension -match '\.(ini|old|tmp)$') { return }
            if ($_.Name -eq '.rev') { return }
            $dest = Join-Path $vftDst $rel
            $parent = Split-Path $dest
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item $_.FullName $dest -Force
        }
    }

    $revDir = Split-Path $revFile
    if (-not (Test-Path $revDir)) { New-Item -ItemType Directory -Path $revDir -Force | Out-Null }
    Set-Content -Path $revFile -Value $sha -Encoding ascii -NoNewline
    Write-Status "ok updated $sha"
    exit 0
} catch {
    Write-Status ("err " + $_.Exception.Message)
    exit 1
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
]=]

local function startJob(mode)
    if job then return false end
    mode = (mode == 'check') and 'check' or 'update'
    local dest = luaDir()
    local tmp = tempDir()
    local ps1 = tmp .. '\\vfup.ps1'
    local out = tmp .. '\\vfup.out'
    pcall(os.remove, out)
    local f, e = io.open(ps1, 'w')
    if not f then
        M.err = 'cannot write ' .. ps1 .. ' -- ' .. tostring(e)
        return false
    end
    f:write(PS)
    f:close()
    job = {
        mode = mode,
        ps1 = ps1,
        out = out,
        at = os.clock(),
        limit = (mode == 'check') and 25 or 90,
    }
    M.err = ''
    M.note = (mode == 'check') and 'checking…' or 'updating…'
    -- VF: start returns immediately so the Manager draw does not freeze on the zip.
    os.execute(string.format(
        'cmd /c start "" /min powershell.exe -NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "%s" -LuaDir "%s" -OutFile "%s" -Mode %s',
        ps1:gsub('"', ''),
        dest:gsub('"', ''),
        out:gsub('"', ''),
        mode))
    return true
end

function M.reloadVf()
    -- VF: /timed is deciseconds. stop now, run in 1s so the VM is gone first.
    pcall(function()
        mq.cmd('/multiline ; /vf pause; /lua stop vf; /timed 10 /lua run vf')
    end)
end

local function finish(result)
    local mode = job and job.mode or ''
    local ps1 = job and job.ps1
    local out = job and job.out
    job = nil
    if ps1 then pcall(os.remove, ps1) end
    if out then pcall(os.remove, out) end
    if result:find('^ok sha ') then
        M.releaseSha = result:match('(%x+)$') or M.releaseSha
        checkedAt = os.clock()
        M.note = ''
        M.err = ''
        return
    end
    if result:find('^ok up%-to%-date') then
        M.releaseSha = result:match('(%x+)$') or M.releaseSha
        checkedAt = os.clock()
        M.note = 'up to date'
        M.err = ''
        return
    end
    if result:find('^ok updated') then
        M.releaseSha = result:match('(%x+)$') or M.releaseSha
        checkedAt = os.clock()
        M.note = ''
        M.err = ''
        M.reloadVf()
        return
    end
    if result:sub(1, 4) == 'err ' then
        M.err = result:sub(5)
        M.note = ''
        return
    end
    if result ~= '' and result ~= 'run' then
        M.err = result
        M.note = ''
        return
    end
    if mode == 'update' then
        M.err = 'update failed'
        M.note = ''
    else
        M.err = 'check failed'
        M.note = ''
    end
end

function M.tick()
    if not job then return end
    local result = readFile(job.out)
    if result ~= '' and result ~= 'run' then
        finish(result)
        return
    end
    if (os.clock() - job.at) > (job.limit or 90) then
        finish('err timed out')
    end
end

function M.ensureCheck()
    if job then return end
    if M.releaseSha ~= '' and (os.clock() - checkedAt) < 120 then return end
    startJob('check')
end

function M.startUpdate()
    if job then return end
    startJob('update')
end

-- VF: /lua run vfup. Blocks this VM only; Manager uses startUpdate + tick.
function M.runCli()
    if not startJob('update') then
        print('\ag[VF]\ax \ar' .. (M.err ~= '' and M.err or 'update failed'))
        return
    end
    print('\ag[VF]\ax overlaying ' .. M.REPO .. '@' .. M.BRANCH)
    while job do
        if mq.canDelay and mq.canDelay() then
            mq.delay(200)
        end
        M.tick()
    end
    if M.err ~= '' then
        print('\ag[VF]\ax \ar' .. M.err)
        return
    end
    if M.note == 'up to date' then
        print('\ag[VF]\ax up to date ' .. M.short(M.releaseSha))
        return
    end
    print('\ag[VF]\ax updated ' .. M.short(M.releaseSha))
    M.reloadVf()
end

return M
