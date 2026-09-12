---@diagnostic disable: undefined-global, undefined-field
-- VF: overlay GitHub main onto this MQ lua folder. /lua run vfup
-- VF: owned set only (vf.lua, vft.lua, vfup.lua, vft/). Never vft/config ini. No reload.

local mq = require('mq')

local REPO = 'belvue/veilfall-triune'
local BRANCH = 'main'

local function say(msg)
    print('\ag[VF]\ax ' .. tostring(msg or ''))
end

local function fail(msg)
    print('\ag[VF]\ax \ar' .. tostring(msg or ''))
end

local function luaDir()
    local dir = ''
    pcall(function()
        dir = tostring(mq.luaDir or '')
    end)
    if dir == '' or dir == 'NULL' then
        dir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
    end
    dir = dir:gsub('/', '\\'):gsub('\\+$', '')
    return dir
end

local function tempDir()
    local t = os.getenv('TEMP') or os.getenv('TMP') or '.'
    return t:gsub('/', '\\'):gsub('\\+$', '')
end

local PS = [=[
param(
    [Parameter(Mandatory = $true)][string]$LuaDir,
    [Parameter(Mandatory = $true)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

function Write-Status([string]$line) {
    Set-Content -Path $OutFile -Value $line -Encoding ascii
}

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

local dest = luaDir()
local tmp = tempDir()
local ps1 = tmp .. '\\vfup.ps1'
local out = tmp .. '\\vfup.out'
pcall(os.remove, out)

local f, e = io.open(ps1, 'w')
if not f then
    fail('cannot write ' .. ps1 .. ' -- ' .. tostring(e))
    return
end
f:write(PS)
f:close()

say('checking ' .. REPO .. '@' .. BRANCH .. ' -> ' .. dest)

local cmd = string.format(
    'powershell.exe -NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "%s" -LuaDir "%s" -OutFile "%s"',
    ps1:gsub('"', ''),
    dest:gsub('"', ''),
    out:gsub('"', '')
)
os.execute(cmd)

local result = ''
local rf = io.open(out, 'r')
if rf then
    result = (rf:read('*a') or ''):gsub('%s+$', '')
    rf:close()
end
pcall(os.remove, ps1)
pcall(os.remove, out)

if result:find('^ok up%-to%-date') then
    say('up to date ' .. (result:match('(%x+)$') or ''))
    return
end
if result:find('^ok updated') then
    local sha = result:match('(%x+)$') or ''
    say('updated ' .. sha .. '. /lua stop vf then /lua run vf')
    return
end
if result:sub(1, 4) == 'err ' then
    fail(result:sub(5))
    return
end
fail(result ~= '' and result or 'update failed')
