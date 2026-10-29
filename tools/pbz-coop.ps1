<#
.SYNOPSIS
    Starts PBZCoop online co-op for a running Phantom Blade Zero: launches the relay, waits until you're in
    gameplay, then turns sync on in the mod. Run it on both PCs (host first).

.PARAMETER Role
    host    your world is the truth for enemies, bosses and deaths; your friend joins you
    client  you join the host (needs -Peer)
    echo    solo test: a fake friend copies your moves 3 m to the side (host logic only)
    loop    solo test: like echo, but also runs the client logic against the echoed data
    record  solo two-PC stand-in, part 1: play as host while the relay records what the host sends (-File)
    replay  part 2, ideally after restarting the game: play as client against the recorded host (-File);
            the client's own events are logged next to the recording (.client.txt)
.PARAMETER File
    The recording for record/replay (default logs\host-recording.jsonl).
.PARAMETER Peer
    The host's Tailscale IP (client only), e.g. 100.112.4.45.
.PARAMETER Stop
    Turn sync off and stop the relay started by this script.

.EXAMPLE
    .\tools\pbz-coop.ps1 -Role host
    .\tools\pbz-coop.ps1 -Role client -Peer 100.112.4.45
    .\tools\pbz-coop.ps1 -Role loop
    .\tools\pbz-coop.ps1 -Stop
#>
param(
    [ValidateSet('host', 'client', 'echo', 'loop', 'record', 'replay')][string]$Role = 'host',
    [string]$Peer,
    [string]$File,
    [int]$Port = 47800,
    [switch]$Stop,
    [string]$GameWin64,    # found through Steam when left out
    [int]$GameplayTimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'find-game.ps1')
if (-not $GameWin64) {
    $GameWin64 = Find-PbzGame
    if (-not $GameWin64) { throw "Phantom Blade Zero wasn't found in your Steam libraries. Run again with -GameWin64 '<Steam library>\steamapps\common\PBZ\platform\steam'." }
}
$projectRoot = Split-Path $PSScriptRoot -Parent
$statePath = Join-Path $projectRoot 'logs\coop-last.json'
$modDir = Join-Path $GameWin64 'ue4ss\Mods\PBZCoop'
. (Join-Path $PSScriptRoot 'game-driver.ps1') -GameWin64 $GameWin64 -ProcessName 'PBZ'

# The relay this script started last time (logs\coop-last.json), if it's still running. Only a Python process
# counts: after a reboot the same PID can belong to something else.
function Stop-LastRelay {
    if (-not (Test-Path $statePath)) { return }
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    if (-not $state.Relay) { return }
    $p = Get-Process -Id $state.Relay -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match '^py(thon)?') {
        Stop-Process -Id $state.Relay -Force
        Write-Output "Stopped relay ($($state.Relay))."
    }
}

# The real python.exe of a working Python 3: the "py" launcher's (py -3) if there is one, else "python". The
# Windows Store stub (...\WindowsApps\python.exe) only opens the Store, so it fails the check and counts as missing.
# The relay is started with the interpreter itself (not py.exe), so its PID is the one that Stop-LastRelay stops.
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

if ($Stop) {
    Stop-LastRelay
    if ((Get-GameWindow) -ne [IntPtr]::Zero) { Send-ModCommand 'netoff'; Write-Output "Sync off." }
    return
}

if ($Role -eq 'client' -and -not $Peer) { throw "-Role client needs -Peer <host's Tailscale IP>." }
if (-not (Test-Path (Join-Path $modDir 'enabled.txt'))) { throw "PBZCoop isn't installed in $GameWin64 (run tools\pbz-setup.ps1)." }
if ((Get-GameWindow) -eq [IntPtr]::Zero) { throw "Start Phantom Blade Zero first." }

$runDir = Join-Path $projectRoot ("logs\coop-" + (Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Force $runDir | Out-Null
$relayRole = if ($Role -in 'echo', 'loop') { 'echo' } else { $Role }
$modRole = @{ record = 'host'; replay = 'client' }[$Role]
if (-not $modRole) { $modRole = $Role }
if (-not $File) { $File = Join-Path $projectRoot 'logs\host-recording.jsonl' }
$relayArgs = @('-I', "`"$(Join-Path $projectRoot 'net\pbzcoop_net.py')`"", $relayRole, '--dir', "`"$modDir`"")
if ($relayRole -in 'host', 'client') { $relayArgs += @('--port', $Port) }
if ($Role -eq 'client') { $relayArgs += @('--peer', $Peer) }
if ($Role -eq 'record') { $relayArgs += @('--file', "`"$File`"") }
if ($Role -eq 'replay') {
    if (-not (Test-Path $File)) { throw "No recording at $File (run -Role record first)." }
    $relayArgs += @('--file', "`"$File`"", '--client-log', "`"$([IO.Path]::ChangeExtension($File, '.client.txt'))`"")
}
$py = Resolve-Python
# A relay left over from an earlier run would hold the UDP port and fight over the files.
Stop-LastRelay
$relayErr = Join-Path $runDir 'relay-err.log'
$relay = Start-Process $py -ArgumentList $relayArgs -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $runDir 'relay.log') -RedirectStandardError $relayErr
$null = $relay.Handle    # keeps the handle open, so ExitCode is readable if it exits
@{ Relay = $relay.Id; Role = $Role; RunDir = $runDir } | ConvertTo-Json | Set-Content $statePath -Encoding utf8
# A relay that can't start (port in use, bad arguments) exits right away: say why instead of waiting for gameplay.
Start-Sleep -Milliseconds 1500
if ($relay.HasExited) {
    if (Test-Path $relayErr) { Get-Content $relayErr }
    throw "The relay exited right away (exit code $($relay.ExitCode)); see $relayErr."
}
Write-Output "Relay ($relayRole) started, PID $($relay.Id). Logs: $runDir"

Write-Output "Waiting until you're in gameplay (load your save)..."
if (-not (Wait-Gameplay -TimeoutSec $GameplayTimeoutSec)) { throw "Not in gameplay after $GameplayTimeoutSec s; run this again once you are." }
# The mod reads cmd.txt every 0.5 s; confirm it really turned sync on, and ask again if not.
$syncOn = $false
for ($try = 1; $try -le 3 -and -not $syncOn; $try++) {
    $t0 = Get-Date
    Send-ModCommand "neton $modRole"
    do {
        Start-Sleep -Milliseconds 500
        $lines = @(Get-ModLog -Since $t0 | Where-Object { $_ -match 'Online sync|error' })
        $syncOn = [bool]($lines | Where-Object { $_ -match 'Online sync on' })
    } until ($syncOn -or (Get-Date) -gt $t0.AddSeconds(5))
    if (-not $syncOn) { Write-Warning "The mod hasn't logged 'Online sync on' yet (try $try of 3)." }
}
$lines
if (-not $syncOn) { throw "The mod never turned sync on (no 'Online sync on' in the UE4SS log). Is PBZCoop loaded? Check ue4ss\UE4SS.log." }
if ($Role -eq 'host') { Write-Output "Hosting on UDP $Port. Your friend opens '3 - Join friend.bat' and enters your Tailscale IP." }
Write-Output "Link status: $modDir\net_status.txt (or send the mod command 'netstatus')."
