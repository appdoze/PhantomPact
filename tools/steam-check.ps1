# Connect = Steam on one PC: two copies (host + guest, same Steam account), each mod starts its relay over Steam
# next to the running game. One account can't reach itself through Steam, so this proves the relays run beside
# the games (Steam starts in the relay, games stay up, no mod errors, relays exit with the games); the real
# connection needs a second Steam account on another PC.
$ErrorActionPreference = 'Stop'
$GameWin64 = 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam'
. (Join-Path $PSScriptRoot 'game-driver.ps1') -GameWin64 $GameWin64 -ProcessName 'PBZ'
$results = [ordered]@{}
function Check([string]$name, [bool]$ok, [string]$detail) {
    $results[$name] = $ok
    Write-Output ("{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
}
Get-Process PBZ -ErrorAction SilentlyContinue | Where-Object SessionId -eq (Get-Process -Id $PID).SessionId | Stop-Process -Force
Start-Sleep 3
& (Join-Path $PSScriptRoot 'install-mod.ps1') -GameWin64 $GameWin64 | Out-Null
$modRoot = Join-Path $GameWin64 'ue4ss\Mods\PBZCoop'
New-Item -ItemType Directory -Force (Join-Path $modRoot 'inst2') | Out-Null
$ini1, $ini2 = (Join-Path $modRoot 'PhantomPact.ini'), (Join-Path $modRoot 'inst2\PhantomPact.ini')
Set-Content $ini1 "Role = Host`r`nConnect = Steam" -Encoding ascii
Set-Content $ini2 "Role = Guest`r`nConnect = Steam" -Encoding ascii
$t0 = Get-Date
& (Join-Path $PSScriptRoot 'pbz-selftest.ps1') -NoRelays | Out-Null
$state = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\selftest-last.json') -Raw | ConvertFrom-Json
$games = @($state.Games)
Check 'two copies start' ($games.Count -eq 2) "$($games -join ', ')"
foreach ($i in 1, 2) {
    Select-GameInstance -ProcessId $games[$i - 1] -Instance $i; $ok = $false
    for ($k = 0; $k -lt 10 -and -not $ok; $k++) {
        if (Wait-Gameplay -TimeoutSec 6) { $ok = $true; break }
        Show-Game; Send-GameKey RETURN; Start-Sleep 10
        $ok = Wait-Gameplay -TimeoutSec 20
    }
    Check "copy $i in gameplay" $ok ''
}
Start-Sleep 15
$log = @(Get-ModLog -Since $t0 -Last 5000)
Check 'host relay started over Steam' ([bool]($log -match '\[PBZCoop\] Relay started as host over Steam')) ''
Check 'guest relay looks for a hosting friend' ([bool]($log -match "\[PBZCoop#2\] Relay started as guest, looking for a Steam friend")) ''
foreach ($pair in @(@('host', $modRoot), @('guest', (Join-Path $modRoot 'inst2')))) {
    $status = (Get-Content (Join-Path $pair[1] 'net_status.txt') -Raw -ErrorAction SilentlyContinue)
    $fresh = $status -match 'time=(\d+)' -and ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$Matches[1]) -le 5
    Check "$($pair[0]) relay running via Steam" ($fresh -and $status -match 'via=steam') ($status -replace '\s+$', '')
}
$alive = @($games | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
Check 'both games still running' ($alive.Count -eq 2) ''
$errors = @($log | Where-Object { $_ -match 'net error|event \w+ error|\.lua:\d+' })
Check 'no mod errors' (-not $errors) (($errors | Select-Object -First 2) -join ' | ')
& (Join-Path $PSScriptRoot 'pbz-selftest.ps1') -Stop | Out-Null
$deadline = (Get-Date).AddSeconds(60)
do { Start-Sleep 3; $left = @(Get-CimInstance Win32_Process -Filter "Name like 'py%'" | Where-Object { $_.CommandLine -match 'pbzcoop_net.*--alive-file' }) } until (-not $left -or (Get-Date) -gt $deadline)
Check 'relays close when the game closes' (-not $left) "$($left.Count) left"
Remove-Item $ini2 -Force
$failed = @($results.GetEnumerator() | Where-Object { -not $_.Value }).Count
Write-Output ("`n{0} of {1} checks passed" -f ($results.Count - $failed), $results.Count)
