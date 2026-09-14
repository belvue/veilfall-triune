-- VF: overlay GitHub branch (main or beta) onto mq.luaDir. Manager Settings Check/Update (suite).
-- VF: Suite overlay is vf.lua + vfi.lua + vft/**. Inv overlay is inventory-only.
-- VF: Check fetches lua/vft/version.txt (0.N.N). Never on draw. README is fallback.
-- VF: Branch is vft.updatechan (config/vf_overlay.lua), not a toon loadout.

local mq = require('mq')
local Chan = require('vft.updatechan')

local M = {}

M.REPO = Chan.REPO
M.release = ''
M.note = ''
M.err = ''

local job = nil
local currentCache, currentAt = '', -1

function M.branch()
    return Chan.branch()
end

-- VF: mq.luaDir can be relative 'lua'. Resolve against configDir, never PowerShell CWD.
local function luaDir()
    local function norm(p)
        return tostring(p or ''):gsub('/', '\\'):gsub('\\+$', '')
    end
    local function isAbs(p)
        p = norm(p)
        return p:match('^[%a]:') ~= nil or p:match('^\\\\') ~= nil
    end
    local dir, cfg = '', ''
    pcall(function() dir = tostring(mq.luaDir or '') end)
    pcall(function() cfg = tostring(mq.configDir or '') end)
    if dir == 'NULL' then dir = '' end
    if cfg == 'NULL' then cfg = '' end
    dir, cfg = norm(dir), norm(cfg)
    if isAbs(dir) then return dir end
    if cfg ~= '' then
        local root = cfg:gsub('\\config$', '')
        local rel = (dir ~= '' and dir or 'lua')
        return norm(root .. '\\' .. rel)
    end
    local script = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
    return norm(script):gsub('\\vft$', '')
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

function M.parseVer(body)
    body = tostring(body or '')
    if body == '' or body:find('404:', 1, true) or body:find('<', 1, true) then
        return ''
    end
    local line = body:match('^%s*([^\r\n]+)') or ''
    return line:match('(%d+%.%d+%.%d+)') or ''
end

function M.parseParts(v)
    local a, b, c = tostring(v or ''):match('(%d+)%.(%d+)%.(%d+)')
    return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

function M.cmpVer(a, b)
    local a1, a2, a3 = M.parseParts(a)
    local b1, b2, b3 = M.parseParts(b)
    if a1 ~= b1 then return (a1 < b1) and -1 or 1 end
    if a2 ~= b2 then return (a2 < b2) and -1 or 1 end
    if a3 ~= b3 then return (a3 < b3) and -1 or 1 end
    return 0
end

function M.display(v)
    return tostring(v or ''):gsub('%s+', '')
end

function M.current()
    local now = os.clock()
    if (now - currentAt) < 2 then return currentCache end
    local dir = luaDir()
    currentCache = M.parseVer(readFile(dir .. '\\vft\\version.txt'))
    if currentCache == '' then
        currentCache = M.parseVer(readFile(dir .. '\\vft\\.rev'))
    end
    currentAt = now
    return currentCache
end

function M.busy()
    return job ~= nil
end

local PS = [=[
param(
    [Parameter(Mandatory = $true)][string]$LuaDir,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [switch]$Force,
    [string]$Branch = 'main'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Write-Status([string]$line) {
    Set-Content -Path $OutFile -Value $line -Encoding ascii
}
Write-Status 'run'
$LuaDir = [IO.Path]::GetFullPath($LuaDir)
if (-not (Test-Path $LuaDir)) { Write-Status "err lua dir missing"; exit 1 }
$repo = 'belvue/veilfall-triune'
if ($Branch -ne 'beta') { $Branch = 'main' }
$token = $env:VF_GITHUB_TOKEN
$headers = @('-sL', '-H', 'User-Agent: VF-Update')
if ($token) { $headers += @('-H', "Authorization: Bearer $token") }
$tmp = Join-Path $env:TEMP ('vfup-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tmp | Out-Null
function Get-Ver([string]$url) {
    $f = Join-Path $tmp 'ver.txt'
    & curl.exe @headers --max-time 15 -o $f $url
    if ($LASTEXITCODE -ne 0) { return '' }
    $raw = Get-Content $f -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return '' }
    if ($raw -match '404:') { return '' }
    if ($raw -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return ''
}
function Cmp-Ver([string]$a, [string]$b) {
    $ax = @(0, 0, 0)
    if ($a -match '(\d+)\.(\d+)\.(\d+)') { $ax = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
    $bx = @(0, 0, 0)
    if ($b -match '(\d+)\.(\d+)\.(\d+)') { $bx = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
    for ($i = 0; $i -lt 3; $i++) {
        if ($ax[$i] -lt $bx[$i]) { return -1 }
        if ($ax[$i] -gt $bx[$i]) { return 1 }
    }
    return 0
}
try {
    $rel = ''
    if ($Branch -eq 'beta') {
        $rel = Get-Ver "https://raw.githubusercontent.com/belvue/veilfall-triune/$Branch/lua/vft/version.txt"
        if (-not $rel) { $rel = Get-Ver "https://cdn.jsdelivr.net/gh/belvue/veilfall-triune@$Branch/lua/vft/version.txt" }
    } else {
        $rel = Get-Ver "https://cdn.jsdelivr.net/gh/belvue/veilfall-triune@$Branch/lua/vft/version.txt"
        if (-not $rel) { $rel = Get-Ver "https://raw.githubusercontent.com/belvue/veilfall-triune/$Branch/lua/vft/version.txt" }
    }
    if (-not $rel) { $rel = Get-Ver "https://raw.githubusercontent.com/belvue/veilfall-triune/$Branch/README.md" }
    $verFile = Join-Path $LuaDir 'vft\version.txt'
    $vfiDest = Join-Path $LuaDir 'vfi.lua'
    $old = ''
    if (Test-Path $verFile) { $old = (Get-Content $verFile -Raw).Trim() }
    if ($old -match '(\d+\.\d+\.\d+)') { $old = $Matches[1] }
    if (-not $Force -and $rel -and (Test-Path $vfiDest) -and ((Cmp-Ver $old $rel) -ge 0)) { Write-Status "ok up-to-date $old"; exit 0 }
    $zip = Join-Path $tmp 'vf.zip'
    & curl.exe @headers --max-time 60 -o $zip "https://codeload.github.com/$repo/zip/refs/heads/$Branch"
    if ($LASTEXITCODE -ne 0) { throw "curl zip $LASTEXITCODE" }
    if (-not (Test-Path $zip) -or ((Get-Item $zip).Length -lt 1000)) { throw 'zip too small' }
    & tar.exe -xf $zip -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "tar $LASTEXITCODE" }
    $srcRoot = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'veilfall-triune-*' } | Select-Object -First 1
    if (-not $srcRoot) { throw 'zip layout' }
    $luaSrc = Join-Path $srcRoot.FullName 'lua'
    $vfSrc = Join-Path $luaSrc 'vf.lua'
    $vfiSrc = Join-Path $luaSrc 'vfi.lua'
    if (-not (Test-Path $vfSrc)) { throw 'zip has no lua/vf.lua' }
    if (-not (Test-Path $vfiSrc)) { throw 'zip has no lua/vfi.lua' }
    Copy-Item $vfSrc (Join-Path $LuaDir 'vf.lua') -Force
    Copy-Item $vfiSrc $vfiDest -Force
    if (-not (Test-Path $vfiDest)) { throw 'vfi.lua copy failed' }
    $vftSrc = Join-Path $luaSrc 'vft'
    $vftDst = Join-Path $LuaDir 'vft'
    if (Test-Path $vftSrc) {
        New-Item -ItemType Directory -Path $vftDst -Force | Out-Null
        Get-ChildItem $vftSrc -Recurse -File | ForEach-Object {
            $relPath = $_.FullName.Substring($vftSrc.Length).TrimStart('\', '/')
            if ($relPath -match '^[\\/]?config[\\/]' -and $_.Extension -match '\.(ini|old|tmp)$') { return }
            if ($_.Name -eq '.rev') { return }
            $dest = Join-Path $vftDst $relPath
            $parent = Split-Path $dest
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item $_.FullName $dest -Force
        }
    }
    if ($rel -and -not (Test-Path $verFile)) {
        $verDir = Split-Path $verFile
        if (-not (Test-Path $verDir)) { New-Item -ItemType Directory -Path $verDir -Force | Out-Null }
        Set-Content -Path $verFile -Value $rel -Encoding ascii -NoNewline
    }
    $got = $rel
    if (Test-Path $verFile) { $got = (Get-Content $verFile -Raw).Trim() }
    Write-Status ("ok updated " + $got)
    exit 0
} catch {
    Write-Status ("err " + $_.Exception.Message)
    exit 1
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
]=]

local function spawnCurlCheck(url)
    local out = tempDir() .. '\\vf-ver.txt'
    pcall(os.remove, out)
    job = { mode = 'check', out = out, at = os.clock(), limit = 12, url = url }
    M.note = 'checking…'
    M.err = ''
    -- VF: Lua os.execute is already cmd /c. start "" returns now; curl is the click.
    os.execute(string.format(
        'start "" /min curl.exe -sL --max-time 10 -A VF-Update -o "%s" "%s"',
        out:gsub('"', ''),
        url))
end

local function startUpdateJob(force)
    if job then return false end
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
    job = { mode = 'update', ps1 = ps1, out = out, at = os.clock(), limit = 90 }
    M.err = ''
    M.note = 'updating…'
    os.execute(string.format(
        'start "" /min powershell.exe -NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "%s" -LuaDir "%s" -OutFile "%s" -Branch "%s"%s',
        ps1:gsub('"', ''),
        dest:gsub('"', ''),
        out:gsub('"', ''),
        Chan.branch(),
        force and ' -Force' or ''))
    return true
end

function M.reloadVf()
    pcall(function()
        mq.cmd('/multiline ; /vf pause; /lua stop vfi; /lua stop vft/inv; /lua stop vf; /timed 10 /lua run vf; /timed 20 /lua run vft/inv')
    end)
end

local function finishCheck()
    local body = job and readFile(job.out) or ''
    local url = job and job.url or ''
    job = nil
    local ver = M.parseVer(body)
    if ver ~= '' then
        M.release = ver
        M.err = ''
        M.note = (M.cmpVer(M.current(), ver) >= 0) and 'up to date' or ''
        return
    end
    local cdn = Chan.cdn('lua/vft/version.txt')
    local raw = Chan.raw('lua/vft/version.txt')
    local readme = Chan.raw('README.md')
    if url == cdn then
        spawnCurlCheck(raw)
        return
    end
    if url == raw then
        spawnCurlCheck(readme)
        return
    end
    M.note = ''
    M.err = (body == '') and 'check timed out' or 'could not read GitHub version'
end

local function takeVer(result)
    return M.parseVer(result) ~= '' and M.parseVer(result) or (result:match('(%d+%.%d+%.%d+)%s*$') or '')
end

local function finishUpdate(result)
    local ps1 = job and job.ps1
    local out = job and job.out
    job = nil
    if ps1 then pcall(os.remove, ps1) end
    if out then pcall(os.remove, out) end
    currentAt = -1
    local ver = takeVer(result)
    if result:find('^ok up%-to%-date') then
        if ver ~= '' then
            M.release = ver
        end
        M.note = 'up to date'
        M.err = ''
        return
    end
    if result:find('^ok updated') then
        if ver ~= '' then
            M.release = ver
        end
        M.note = ''
        M.err = ''
        M.reloadVf()
        return
    end
    M.note = ''
    if result:sub(1, 4) == 'err ' then
        M.err = result:sub(5)
        return
    end
    M.err = (result ~= '' and result ~= 'run') and result or 'update failed'
end

function M.tick()
    if not job then return end
    if job.mode == 'check' then
        local body = readFile(job.out)
        if M.parseVer(body) ~= '' then
            finishCheck()
            return
        end
        if body:find('404:', 1, true) then
            finishCheck()
            return
        end
        if (os.clock() - job.at) > (job.limit or 12) then
            finishCheck()
        end
        return
    end
    local result = readFile(job.out)
    if result ~= '' and result ~= 'run' then
        finishUpdate(result)
        return
    end
    if (os.clock() - job.at) > (job.limit or 90) then
        finishUpdate('err timed out')
    end
end

function M.startCheck()
    if job then return end
    -- VF: beta Check uses GitHub raw — jsDelivr @branch can stay stale for hours.
    local url = Chan.isBeta() and Chan.raw('lua/vft/version.txt') or Chan.cdn('lua/vft/version.txt')
    spawnCurlCheck(url)
end

function M.startUpdate()
    if job then return end
    startUpdateJob(Chan.isBeta())
end

function M.runCli()
    if not startUpdateJob(Chan.isBeta()) then
        print('\ag[VF]\ax \ar' .. (M.err ~= '' and M.err or 'update failed'))
        return
    end
    print('\ag[VF]\ax overlaying ' .. Chan.REPO .. '@' .. Chan.branch())
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
        print('\ag[VF]\ax up to date ' .. M.display(M.release))
        return
    end
    print('\ag[VF]\ax updated ' .. M.display(M.release))
    M.reloadVf()
end

return M
