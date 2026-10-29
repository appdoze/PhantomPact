<#
.SYNOPSIS
    Blood Pact-style self-test for PBZCoop: two copies of the game on this PC, linked by two relays over local UDP.
    Copy 1 = host (mod folder), copy 2 = client (mod folder\inst2). Each copy gets PBZCOOP_INSTANCE.

.PARAMETER Stop
    Close the relays and game copies this script started (read from the last run's state file).
.PARAMETER Exe
    Override the game exe (normally found from the Steam manifest, like pbz-setup.ps1).

.EXAMPLE
    .\tools\pbz-selftest.ps1
    .\tools\pbz-selftest.ps1 -Stop
#>
param(
    [switch]$Stop,
    # Only start the two relays (host on the mod folder, client on inst2\): for a copy you started yourself in a
    # second Windows user session (whose user has PBZCOOP_INSTANCE=2 set), next to the one in this session.
    [switch]$RelaysOnly,
    [string]$Exe,
    [string]$SteamLibrary = 'D:\SteamLibrary',
    [int]$SteamAppId = 4115450,
    [int]$Port = 47800,
    [int]$WindowTimeoutSec = 90
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$logsRoot = Join-Path $projectRoot 'logs'
$statePath = Join-Path $logsRoot 'selftest-last.json'

if ($Stop) {
    if (-not (Test-Path $statePath)) { Write-Output "No self-test state found."; return }
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($id in (@($state.Relays) + @($state.Games) | Where-Object { $_ -is [int] -or $_ -is [long] })) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p) { Stop-Process -Id $id -Force; Write-Output "Stopped $($p.ProcessName) ($id)" }
    }
    return
}

# The real python.exe of a working Python 3: the "py" launcher's (py -3) if there is one, else "python". The
# Windows Store stub (...\WindowsApps\python.exe) only opens the Store, so it fails the check and counts as missing.
# Checked before starting anything, and the relays get the interpreter itself, so -Stop stops the right PIDs.
function Resolve-Python {
    $candidates = @()
    $cmd = Get-Command py -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $candidates += @{ Exe = $cmd.Source; Args = @('-3') } }
    $cmd = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $candidates += @{ Exe = $cmd.Source; Args = @() } }
    foreach ($c in $candidates) {
        try {
            $exeArgs = $c.Args
            $out = @(& $c.Exe @exeArgs -I -c "import sys; print(sys.version); print(sys.executable)" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $out.Count -ge 2 -and $out[0] -match '^3\.' -and (Test-Path $out[1])) { return $out[1] }
        } catch { }
    }
    throw "Python 3 not found. Install Python 3 from python.org (tick 'Add python.exe to PATH'), then run this again."
}
$py = Resolve-Python

# Find the game (same lookup as pbz-setup.ps1: PBZ's real game is platform\steam\PBZ.exe, steam\PBZ.exe is a launcher).
$manifest = Join-Path $SteamLibrary "steamapps\appmanifest_$SteamAppId.acf"
$installDir = [regex]::Match((Get-Content $manifest -Raw), '"installdir"\s+"([^"]+)"').Groups[1].Value
$gameRoot = Join-Path $SteamLibrary "steamapps\common\$installDir"
if (-not $Exe) {
    $found = Get-ChildItem $gameRoot -Recurse -Filter '*-Win64-Shipping.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
        $found = Get-ChildItem (Join-Path $gameRoot 'platform') -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
    }
    if (-not $found) { throw "Game exe not found. Has PBZ unlocked and installed?" }
    $Exe = $found.FullName
}
$win64 = Split-Path $Exe -Parent
$procName = [IO.Path]::GetFileNameWithoutExtension($Exe)
$modRoot = Join-Path $win64 'ue4ss\Mods\PBZCoop'
$inst2 = Join-Path $modRoot 'inst2'
if (-not (Test-Path (Join-Path $modRoot 'enabled.txt'))) { throw "PBZCoop isn't installed in $win64 (run pbz-setup.ps1 first)." }
New-Item -ItemType Directory -Force $inst2 | Out-Null

$runDir = Join-Path $logsRoot ("selftest-" + (Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Force $runDir | Out-Null

# Both copies use the same save folder, so back it up before every run.
$project = (Get-ChildItem $gameRoot -Directory | Where-Object { $_.Name -ne 'Engine' -and (Test-Path (Join-Path $_.FullName 'Content\Paks')) } | Select-Object -First 1).Name
if ([string]::IsNullOrEmpty($project)) { throw "No game project folder (one with Content\Paks) in $gameRoot. Is PBZ fully installed?" }
# PBZ keeps saves in the game folder (<game>\ProjectPBZ\Saved\SaveGames); most UE games use %LOCALAPPDATA%.
$saves = @((Join-Path $gameRoot "$project\Saved\SaveGames"), (Join-Path $env:LOCALAPPDATA "$project\Saved\SaveGames")) |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ($saves) {
    $bk = Join-Path (Split-Path $SteamLibrary -Qualifier) "\PBZSaveBackup\selftest-$(Get-Date -Format yyyyMMdd-HHmmss)"
    New-Item -ItemType Directory -Force $bk | Out-Null
    Copy-Item "$saves\*" $bk -Recurse
    Write-Output "Saves backed up to $bk"
} else {
    Write-Warning "No SaveGames folder found; check where PBZ saves before letting two copies run for long."
}

function Start-Copy([int]$instance) {
    $before = @(Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object Id)
    $env:PBZCOOP_INSTANCE = "$instance"
    # Same arguments PBZ's launcher (steam\PBZ.exe) passes to the real game. Without steam_appid.txt next to the
    # exe, the game restarts itself through Steam and PBZCOOP_INSTANCE is lost.
    # -allowmultipleinstances is PBZ's own switch for its "already running on this machine" check (its log says
    # "Pass -allowmultipleinstances to override"); without it the second copy exits.
    $exeArgs = @($project, "-basedir=`"$(Join-Path $gameRoot "$project\Binaries\Win64")`"", '-pc-platform=Steam', '-allowmultipleinstances')
    $p = Start-Process -FilePath $Exe -ArgumentList $exeArgs -WorkingDirectory $win64 -PassThru
    Remove-Item Env:\PBZCOOP_INSTANCE
    $deadline = (Get-Date).AddSeconds($WindowTimeoutSec)
    do {
        Start-Sleep -Seconds 2
        $alive = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
        $new = Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id }
    } until (($alive -and $alive.MainWindowHandle -ne 0) -or (-not $alive) -or (Get-Date) -gt $deadline)
    if ($alive -and $alive.MainWindowHandle -ne 0) { return $p.Id }
    if (-not $alive -and $new) {
        Write-Warning "Copy $instance exited and another process ($($new.Id -join ',')) appeared: the game probably relaunched itself through Steam, which drops PBZCOOP_INSTANCE."
    } elseif (-not $alive) {
        Write-Warning "Copy $instance exited on its own (exit code $($p.ExitCode))."
    } else {
        Write-Warning "Copy $instance has no window after $WindowTimeoutSec s."
    }
    return 0
}

if ($RelaysOnly) {
    $pid1 = 0
    $pid2 = -1    # start the client relay too; the copies are started by hand
    Write-Output "Relays only: start PBZ yourself in both Windows sessions (the second user has PBZCOOP_INSTANCE=2)."
} else {
    Write-Output "Starting copy 1 (host)..."
    $pid1 = Start-Copy 1
    if (-not $pid1) { throw "Copy 1 didn't start; see the warning above." }
    Write-Output "Starting copy 2 (client)..."
    $pid2 = Start-Copy 2
    if (-not $pid2) {
        Write-Warning "PBZ won't run a second copy this way. Fall back to solo echo: python -I net\pbzcoop_net.py echo --dir `"$modRoot`""
    }
}

$relayPy = Join-Path $projectRoot 'net\pbzcoop_net.py'
$relays = @()
$relays += (Start-Process $py -ArgumentList '-I', "`"$relayPy`"", 'host', '--dir', "`"$modRoot`"", '--port', $Port -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runDir 'relay-host.log')).Id
if ($pid2) {
    $relays += (Start-Process $py -ArgumentList '-I', "`"$relayPy`"", 'client', '--dir', "`"$inst2`"", '--peer', '127.0.0.1', '--port', $Port -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runDir 'relay-client.log')).Id
}

@{ Games = @($pid1, $pid2) | Where-Object { $_ -gt 0 }; Relays = $relays; RunDir = $runDir; Exe = $Exe } |
    ConvertTo-Json | Set-Content $statePath -Encoding utf8

Write-Output "`nCopy 1 (host)   PID $pid1   files: $modRoot"
Write-Output "Copy 2 (client) PID $pid2   files: $inst2"
Write-Output "Relay logs: $runDir"
Write-Output "`nLoad a save in both copies, then drive them with:"
Write-Output ". .\tools\game-driver.ps1 -GameWin64 '$win64' -ProcessName '$procName'"
Write-Output "Select-GameInstance -ProcessId $pid1 -Instance 1; Send-ModCommand neton"
if ($pid2) { Write-Output "Select-GameInstance -ProcessId $pid2 -Instance 2; Send-ModCommand neton" }
Write-Output "Stop everything: .\tools\pbz-selftest.ps1 -Stop"
