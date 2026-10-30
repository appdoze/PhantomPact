# A real death and the game's own full respawn (BP_RenewalPlayer "Respawn": reset combat, save, recover, refresh
# monsters, teleport to the revive point), on a fresh two-copy session. The prologue never starts a respawn by
# itself, so the test calls it after a real PvP death:
#   client dies + respawns: the client's world refreshes, the host's doesn't
#   host dies + respawns:   both refresh
# The respawn autosaves (and costs a "day"): the save is put back from before the test, autosaves moved aside.
$ErrorActionPreference = 'Stop'
$p = $PSScriptRoot
$results = [ordered]@{}
function Check([string]$name, [bool]$ok, [string]$detail) {
    $results[$name] = $ok
    Write-Output ("{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
}
function Q([int]$i, [string]$c, [double]$w = 1.0) { ((& "$p\pvp-run.ps1" -I $i -Cmd $c -Wait $w) -join ' | ') }
. "$p\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'

$saveDir = 'D:\SteamLibrary\steamapps\common\PBZ\ProjectPBZ\Saved\SaveGames\Steam\76561198310534467'
$keep = Join-Path $env:TEMP ("pp-save-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $keep | Out-Null
Copy-Item "$saveDir\PBZSaveGame.sav" $keep
$before = @(Get-ChildItem $saveDir -Recurse -File | ForEach-Object FullName)
$saveHash = (Get-FileHash "$saveDir\PBZSaveGame.sav").Hash

try {
    & "$p\..\pbz-selftest.ps1" -Stop | Out-Null
    $ready = @(& "$p\pvp-session.ps1" 2>&1 | Select-String 'gameplay')
    $ready
    if (@($ready | Where-Object { $_ -match 'gameplay: True' }).Count -ne 2) { throw 'A game copy did not reach gameplay (run again).' }
    Start-Sleep 3
    $mk = Get-Content "$p\multi-kill.ps1"
    $noHeal = ($mk | Where-Object { $_ -match '^\$noHeal = ' }) -replace '^\$noHeal = "', '' -replace '"$', ''
    $place = ($mk | Where-Object { $_ -match "^\`$place = " }) -replace "^\`$place = '", '' -replace "'$", ''
    $face = ($mk | Where-Object { $_ -match "^\`$face = " }) -replace "^\`$face = '", '' -replace "'$", ''
    $swing = ($mk | Where-Object { $_ -match '^\$swing = ' }) -replace '^\$swing = "', '' -replace '"$', ''
    $state = "eval local pc,p=PBZ.getPlayer1() return string.format('dead=%s hp=%.0f spectating=%s', tostring(PBZ.game.isDead(p)), PBZ.game.getHealth(p) or -1, tostring(PBZ.game.isSpectating()))"
    Q 1 'pvp on' 1 | Out-Null; Q 2 'pvp on' 2 | Out-Null
    Q 1 $noHeal | Out-Null; Q 2 $noHeal | Out-Null
    # Which steps of the respawn actually run (printed below, since the next game start overwrites the log).
    $trace = "eval local b='/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C:' for _,f in ipairs({b..'Respawn', b..'Respawn Refresh Monster', b..'Save Game on Respawn ', '/Game/PBZContent/Blueprint/BP_GameMode_Build.BP_GameMode_Build_C:Refresh Monster'}) do local ok,err=pcall(function() RegisterHook(f, function() PBZ.log('STEP '..f:match(':(.*)$')) end) end) n=(n or 0)+(ok and 1 or 0) if not ok then PBZ.log('trace failed '..f..': '..tostring(err)) end end return 'traced '..tostring(n)"
    "    trace: " + (Q 1 $trace) + ' / ' + (Q 2 $trace)

    foreach ($pair in @(@(2, 1), @(1, 2))) {
        $dying, $killer = $pair
        $who = if ($dying -eq 2) { 'client' } else { 'host' }
        for ($t = 0; $t -lt 5; $t++) {
            Q $dying $place 0.5 | Out-Null; Q $killer $face 0.4 | Out-Null; Q $killer $swing 1.5 | Out-Null
            if ((Q $dying $state 0.3) -match 'dead=true') { break }
        }
        Start-Sleep 4
        $down = Q $dying $state 0.3
        Check "$who really died (spectating the partner)" ($down -match 'dead=true' -and $down -match 'spectating=true') $down
        $tr = Get-Date
        Q $dying "eval local _,p=PBZ.getPlayer1() local ok,err=pcall(function() p:Respawn() end) return 'respawn '..tostring(ok)..' '..tostring(err)" 8 | Out-Null
        Start-Sleep 4
        $up = Q $dying $state 0.3
        $log = @(Get-ModLog -Since $tr -Last 4000)
        $log | Where-Object { $_ -match 'STEP |respawn (true|false)|died|rested|Rested' } | ForEach-Object { '    ' + ($_ -replace '^.*?\[(PBZCoop#?2?)\] ', '[$1] ') }
        Check "$who respawned through the game's own respawn" ($up -match 'dead=false' -and $up -match 'spectating=false') $up
        if ($dying -eq 2) {
            Check 'client respawn: told it was a death, not a rest' ([bool]($log -match '\[PBZCoop#2\] You died and respawned')) ''
            Check "client respawn: host's world untouched" (-not ($log -match '\[PBZCoop\] The (other player rested|host died)')) ''
        } else {
            Check 'host respawn: host told it was a death' ([bool]($log -match '\[PBZCoop\] You died as host')) ''
            Check 'host respawn: client refreshes too' ([bool]($log -match '\[PBZCoop#2\] The host died and respawned')) ''
        }
    }
    $errors = @(Get-ModLog -Since (Get-Date).AddMinutes(-10) -Last 8000 | Where-Object { $_ -match 'net error|event \w+ error|\.lua:\d+' })
    Check 'no mod errors' (-not $errors) (($errors | Select-Object -First 2) -join ' | ')
} finally {
    & "$p\..\pbz-selftest.ps1" -Stop | Out-Null
    Start-Sleep 3
    # Put the save back; autosave copies the respawns wrote go aside (moved, not deleted).
    $aside = "D:\PBZSaveBackup\respawn-check-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $new = @(Get-ChildItem $saveDir -Recurse -File | Where-Object { $before -notcontains $_.FullName })
    if ($new.Count -or (Get-FileHash "$saveDir\PBZSaveGame.sav").Hash -ne $saveHash) {
        New-Item -ItemType Directory -Force $aside | Out-Null
        Copy-Item "$saveDir\PBZSaveGame.sav" "$aside\PBZSaveGame-after-respawns.sav"
        foreach ($f in $new) { Move-Item $f.FullName (Join-Path $aside ($f.Directory.Name + '-' + $f.Name)) }
        Copy-Item "$keep\PBZSaveGame.sav" "$saveDir\PBZSaveGame.sav" -Force
        Write-Output "Save put back ($($new.Count) autosave copies moved to $aside)"
    }
    Write-Output ("save restored: " + ((Get-FileHash "$saveDir\PBZSaveGame.sav").Hash -eq $saveHash))
}
$failed = @($results.GetEnumerator() | Where-Object { -not $_.Value }).Count
Write-Output ("`n{0} of {1} checks passed" -f ($results.Count - $failed), $results.Count)
