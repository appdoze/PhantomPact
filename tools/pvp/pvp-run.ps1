# Runs one mod command in game copy 1 or 2 and prints that copy's mod log lines from the next few seconds.
param([int]$I = 1, [Parameter(Mandatory = $true)][string]$Cmd, [double]$Wait = 1.5)
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$state = Get-Content "$PSScriptRoot\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
Select-GameInstance -ProcessId @($state.Games)[$I - 1] -Instance $I
$t0 = Get-Date; Send-ModCommand $Cmd; Start-Sleep -Milliseconds ([int]($Wait * 1000))
$tag = if ($I -eq 1) { '\[PBZCoop\] ' } else { '\[PBZCoop#2\] ' }
Get-ModLog -Since $t0 -Last 400 | Where-Object { $_ -match $tag -and $_ -notmatch '\] > ' } | ForEach-Object { $_ -replace '^.*?\[PBZCoop#?2?\] ', '' }
