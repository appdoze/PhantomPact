# Victory screen look on a running session (pvp-session.ps1): shows it in copy 1 with the "pvp alive" command and
# screenshots the entrance (early) and the settled screen.
param([string]$Dir = $env:TEMP)
$run = "$PSScriptRoot\pvp-run.ps1"
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$state = Get-Content "$PSScriptRoot\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
Select-GameInstance -ProcessId @($state.Games)[0] -Instance 1; Show-Game
Send-ModCommand 'pvp alive'
Start-Sleep -Milliseconds 750
Save-GameScreenshot "$Dir\alive-entrance.png" -Scale 0.5 | Out-Null
Start-Sleep -Milliseconds 1200
Save-GameScreenshot "$Dir\alive-settled.png" -Scale 0.5 | Out-Null
"shots in $Dir"
