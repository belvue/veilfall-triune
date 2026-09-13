-- VF: overlay GitHub main onto mq.luaDir. Mgr Settings + /lua run vfup.
-- VF: Check fetches lua/vft/version.txt (0.N.N). Never on draw. README is fallback.

local mq = require('mq')

local M = {}

M.REPO = 'belvue/veilfall-triune'
M.BRANCH = 'main'
M.release = ''
M.note = ''
M.err = ''

local job = nil
local currentCache, currentAt = '', -1
local VER_URL = 'https://raw.githubusercontent.com/belvue/veilfall-triune/main/lua/vft/version.txt'
local README_URL = 'https://raw.githubusercontent.com/belvue/veilfall-triune/main/README.md'

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

function M.parseVer(body)
    body = tostring(body or '')
    if body == '' or body:find('404:', 1, true) or body:find('<', 1, true) then
        return ''
    end
    local line = body:match('^%s*([^\r\n]+)') or ''
    return line:match('(%d+%.%d+%.%d+)') or ''
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
    [Parameter(Mandatory = $true)][string]$OutFile
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
$branch = 'main'
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
try {
    $rel = Get-Ver "https://raw.githubusercontent.com/belvue/veilfall-triune/main/lua/vft/version.txt"
    if (-not $rel) { $rel = Get-Ver "https://raw.githubusercontent.com/belvue/veilfall-triune/main/README.md" }
    $verFile = Join-Path $LuaDir 'vft\version.txt'
    $old = ''
    if (Test-Path $verFile) { $old = (Get-Content $verFile -Raw).Trim() }
    if ($old -match '(\d+\.\d+\.\d+)') { $old = $Matches[1] }
    if ($rel -and $old -eq $rel) { Write-Status "ok up-to-date $rel"; exit 0 }
    $zip = Join-Path $tmp 'vf.zip'
    & curl.exe @headers --max-time 60 -o $zip "https://codeload.github.com/$repo/zip/refs/heads/$branch"
    if ($LASTEXITCODE -ne 0) { throw "curl zip $LASTEXITCODE" }
    if (-not (Test-Path $zip) -or ((Get-Item $zip).Length -lt 1000)) { throw 'zip too small' }
    & tar.exe -xf $zip -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "tar $LASTEXITCODE" }
    $srcRoot = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'veilfall-triune-*' } | Select-Object -First 1
    if (-not $srcRoot) { throw 'zip layout' }
    $luaSrc = Join-Path $srcRoot.FullName 'lua'
    if (-not (Test-Path (Join-Path $luaSrc 'vf.lua'))) { throw 'zip has no lua/vf.lua' }
    foreach ($name in @('vf.lua', 'vft.lua', 'vfup.lua')) {
        $from = Join-Path $luaSrc $name
        if (Test-Path $from) { Copy-Item $from (Join-Path $LuaDir $name) -Force }
    }
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

local function startUpdateJob()
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
        'start "" /min powershell.exe -NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "%s" -LuaDir "%s" -OutFile "%s"',
        ps1:gsub('"', ''),
        dest:gsub('"', ''),
        out:gsub('"', '')))
    return true
end

function M.reloadVf()
    pcall(function()
        mq.cmd('/multiline ; /vf pause; /lua stop vf; /timed 10 /lua run vf')
    end)
end

local function finishCheck()
    local body = job and readFile(job.out) or ''
    local tryReadme = job and job.url ~= README_URL
    job = nil
    local ver = M.parseVer(body)
    if ver ~= '' then
        M.release = ver
        M.err = ''
        M.note = (ver == M.current()) and 'up to date' or ''
        return
    end
    if tryReadme then
        spawnCurlCheck(README_URL)
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
    spawnCurlCheck(VER_URL)
end

function M.startUpdate()
    if job then return end
    startUpdateJob()
end

function M.runCli()
    if not startUpdateJob() then
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
        print('\ag[VF]\ax up to date ' .. M.display(M.release))
        return
    end
    print('\ag[VF]\ax updated ' .. M.display(M.release))
    M.reloadVf()
end

return M
