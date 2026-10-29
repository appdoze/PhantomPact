# Starts two PBZ copies (selftest), gets both into gameplay, lines them up 4 m apart facing each other and turns
# sync on (host/client). Leaves everything running for interactive PvP recon via Send-ModCommand.
$ErrorActionPreference = 'Stop'
$tools = "$PSScriptRoot\.."
$GameWin64 = 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam'
. (Join-Path $tools 'game-driver.ps1') -GameWin64 $GameWin64 -ProcessName 'PBZ'
Get-Process PBZ -ErrorAction SilentlyContinue | Where-Object SessionId -eq (Get-Process -Id $PID).SessionId | Stop-Process -Force
Start-Sleep 3
& (Join-Path $tools 'install-mod.ps1') -GameWin64 $GameWin64 | Out-Null
$modRoot = Join-Path $GameWin64 'ue4ss\Mods\PBZCoop'
Set-Content (Join-Path $modRoot 'PhantomPact.ini') 'Role = Off' -Encoding ascii
Remove-Item (Join-Path $modRoot 'inst2\PhantomPact.ini') -ErrorAction SilentlyContinue
& (Join-Path $tools 'pbz-selftest.ps1')
$state = Get-Content "$PSScriptRoot\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
$hostPid, $clientPid = @($state.Games)[0], @($state.Games)[1]
function Use([int]$i) { if ($i -eq 1) { Select-GameInstance -ProcessId $hostPid -Instance 1 } else { Select-GameInstance -ProcessId $clientPid -Instance 2 } }
foreach ($i in 1, 2) {
    Use $i; $ok = $false
    for ($k = 0; $k -lt 10 -and -not $ok; $k++) {
        if (Wait-Gameplay -TimeoutSec 6) { $ok = $true; break }
        Show-Game; Send-GameKey RETURN; Start-Sleep 10
        $ok = Wait-Gameplay -TimeoutSec 20
    }
    "copy $i in gameplay: $ok"
}
Use 1; Send-ModCommand 'neton host'; Start-Sleep 2; Use 2; Send-ModCommand 'neton client'; Start-Sleep 4
"hostPid=$hostPid clientPid=$clientPid"
