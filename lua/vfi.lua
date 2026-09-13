---@diagnostic disable: undefined-global, undefined-field
-- VF: Inventory runner. /lua run vfi  (also /vfinv from VF, /lua run vft/inv shim).

local mq = require('mq')

-- VF: Seed install. vfi.lua alone can pull vft/inv + satellite modules from GitHub.
-- VF: Overlay copy list must match vft/inv/update.lua.
local function ensureInvTree()
    local function luaDir()
        local dir = ''
        pcall(function() dir = tostring(mq.luaDir or '') end)
        if dir == '' or dir == 'NULL' then
            dir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
            dir = dir:gsub('[/\\]vfi%.lua$', '')
        end
        return dir:gsub('/', '\\'):gsub('\\+$', '')
    end

    local function has(rel)
        local f = io.open(luaDir() .. '\\' .. rel:gsub('/', '\\'), 'r')
        if f then f:close() return true end
        return false
    end

    local need = {
        'vft/chat.lua',
        'vft/brand.lua',
        'vft/powersource.lua',
        'vft/toonini.lua',
        'vft/inv/app.lua',
        'vft/inv/locks.lua',
        'vft/inv/augs.lua',
        'vft/inv/update.lua',
        'vft/inv/version.txt',
    }
    local function missingList()
        local out = {}
        for i = 1, #need do
            if not has(need[i]) then out[#out + 1] = need[i] end
        end
        return out
    end

    local miss = missingList()
    if #miss == 0 then return true end

    print('\ag[VF:Inv]\ax Installing Veilfall.cc Inventory')

    local ps = [=[
param(
    [Parameter(Mandatory = $true)][string]$LuaDir,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [switch]$Force
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
$tmp = Join-Path $env:TEMP ('vfiup-' + [guid]::NewGuid().ToString('n'))
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
    $rel = Get-Ver "https://raw.githubusercontent.com/belvue/veilfall-triune/main/lua/vft/inv/version.txt"
    if (-not $rel) { throw 'inv version missing' }
    $verFile = Join-Path $LuaDir 'vft\inv\version.txt'
    $old = '0.0.0'
    if (Test-Path $verFile) { $old = (Get-Content $verFile -Raw).Trim() }
    if ($old -match '(\d+\.\d+\.\d+)') { $old = $Matches[1] } else { $old = '0.0.0' }
    if (-not $Force -and ((Cmp-Ver $old $rel) -ge 0)) { Write-Status "ok up-to-date $old"; exit 0 }
    $zip = Join-Path $tmp 'vf.zip'
    & curl.exe @headers --max-time 60 -o $zip "https://codeload.github.com/$repo/zip/refs/heads/$branch"
    if ($LASTEXITCODE -ne 0) { throw "curl zip $LASTEXITCODE" }
    if (-not (Test-Path $zip) -or ((Get-Item $zip).Length -lt 1000)) { throw 'zip too small' }
    & tar.exe -xf $zip -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "tar $LASTEXITCODE" }
    $srcRoot = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'veilfall-triune-*' } | Select-Object -First 1
    if (-not $srcRoot) { throw 'zip layout' }
    $luaSrc = Join-Path $srcRoot.FullName 'lua'
    $vfi = Join-Path $luaSrc 'vfi.lua'
    if (-not (Test-Path $vfi)) { throw 'zip has no lua/vfi.lua' }
    Copy-Item $vfi (Join-Path $LuaDir 'vfi.lua') -Force
    $invSrc = Join-Path $luaSrc 'vft\inv'
    $invDst = Join-Path $LuaDir 'vft\inv'
    if (-not (Test-Path $invSrc)) { throw 'zip has no lua/vft/inv' }
    New-Item -ItemType Directory -Path $invDst -Force | Out-Null
    Get-ChildItem $invSrc -Recurse -File | ForEach-Object {
        $relPath = $_.FullName.Substring($invSrc.Length).TrimStart('\', '/')
        if ($relPath -match '^[\\/]?config[\\/]' -and $_.Extension -match '\.(ini|old|tmp)$') { return }
        if ($_.Name -eq '.rev') { return }
        $dest = Join-Path $invDst $relPath
        $parent = Split-Path $dest
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item $_.FullName $dest -Force
    }
    foreach ($relName in @('vft\chat.lua', 'vft\brand.lua', 'vft\powersource.lua', 'vft\toonini.lua', 'vft\vf-mark.png', 'vft\vf-bag.png')) {
        $from = Join-Path $luaSrc $relName
        if (Test-Path $from) {
            $dest = Join-Path $LuaDir $relName
            $parent = Split-Path $dest
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item $from $dest -Force
        }
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

    local tmp = os.getenv('TEMP') or os.getenv('TMP') or '.'
    tmp = tmp:gsub('/', '\\'):gsub('\\+$', '')
    local ps1 = tmp .. '\\vfiup.ps1'
    local out = tmp .. '\\vfiup.out'
    pcall(os.remove, out)
    local f, e = io.open(ps1, 'w')
    if not f then
        print('\ag[VF:Inv]\ax \arcannot write ' .. ps1 .. ' -- ' .. tostring(e))
        return false
    end
    f:write(ps)
    f:close()

    os.execute(string.format(
        'start "" /min powershell.exe -NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "%s" -LuaDir "%s" -OutFile "%s" -Force',
        ps1:gsub('"', ''),
        luaDir():gsub('"', ''),
        out:gsub('"', '')))

    local function readOut()
        local fh = io.open(out, 'r')
        if not fh then return '' end
        local s = fh:read('*a') or ''
        fh:close()
        return s:gsub('%s+$', '')
    end

    local at = os.clock()
    local result = ''
    while true do
        result = readOut()
        if result ~= '' and result ~= 'run' then break end
        if (os.clock() - at) > 90 then
            result = 'err timed out'
            break
        end
        mq.delay(200)
    end
    pcall(os.remove, ps1)
    pcall(os.remove, out)

    if result:find('^err') or result == '' then
        local why = result:sub(1, 4) == 'err ' and result:sub(5) or (result ~= '' and result or 'update failed')
        print('\ag[VF:Inv]\ax \ar' .. why)
        return false
    end

    miss = missingList()
    if #miss > 0 then
        print('\ag[VF:Inv]\ax \arstill missing ' .. table.concat(miss, ', '))
        return false
    end
    print('\ag[VF:Inv]\ax Inventory files ready')
    return true
end

if not ensureInvTree() then return end

local chat = require('vft.chat')
local inv = require('vft.inv.app').create({ hosted = false })

local function mqLeaving()
    local leaving = false
    pcall(function()
        if mq.exiting then leaving = not not mq.exiting() end
    end)
    return leaving
end

local function vfRunning()
    local found = false
    pcall(function()
        local pids = tostring(mq.TLO.Lua.PIDs() or '')
        for tok in pids:gmatch('%d+') do
            local pid = tonumber(tok)
            local s = pid and mq.TLO.Lua.Script(pid) or nil
            if s then
                local st, sn = '', ''
                pcall(function() st = tostring(s.Status() or '') end)
                if st == 'RUNNING' or st == 'PAUSED' then
                    pcall(function() sn = tostring(s.Name() or ''):gsub('\\', '/'):lower() end)
                    if sn == 'vf' then found = true; return end
                end
            end
        end
    end)
    return found
end

-- VF: With VF, bag on Mini starts this script for the full window. Alone, overlay stays up.
local withVf = vfRunning()
inv.setOpen(withVf)

mq.imgui.init('VftInv', function()
    if not withVf then inv.drawHud() end
    inv.draw()
end)
pcall(function() mq.unbind('/vfi') end)
mq.bind('/vfi', function() inv.toggle() end)
if not withVf then
    pcall(function() mq.unbind('/vfinv') end)
    mq.bind('/vfinv', function() inv.toggle() end)
end
chat.say('Inv', withVf and 'Opening' or 'Overlay')

while not mqLeaving() and ((not withVf) or inv.isOpen()) do
    mq.doevents()
    local ok, err = pcall(function() inv.tick() end)
    if not ok then
        chat.err('Inv', err)
    end
    mq.delay(20)
end

chat.say('Inv', 'Closing')
pcall(function() mq.unbind('/vfi') end)
if not withVf then
    pcall(function() mq.unbind('/vfinv') end)
end
