# PvP checks on a running two-copy session (pvp-session.ps1): plain hit, held block, timed parry, another weapon,
# end of round. Copy 1 attacks through the mod; copy 2 defends with real input (foreground).
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$run = "$PSScriptRoot\pvp-run.ps1"
$state = Get-Content "$PSScriptRoot\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
$inbox = 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam\ue4ss\Mods\PBZCoop\inst2\net_events_in.txt'
$results = [ordered]@{}
function Check([string]$name, [bool]$ok, [string]$detail) { $results[$name] = $ok; Write-Output ("{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail) }
$place = 'eval local pc,me=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local r=g:K2_GetActorRotation().Yaw local x,y=l.X+math.cos(math.rad(r))*150,l.Y+math.sin(math.rad(r))*150 me:K2_SetActorLocation({X=x,Y=y,Z=l.Z+5},false,{},true) me:K2_SetActorRotation({Pitch=0,Yaw=r+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=r+180,Roll=0}) PBZ.game.setHealth(me,850) PBZ.game.setPosture(me,300) return "placed"'
$face = 'eval local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local a,b=p:K2_GetActorLocation(),g:K2_GetActorLocation() local y=math.deg(math.atan(b.Y-a.Y,b.X-a.X)) p:K2_SetActorRotation({Pitch=0,Yaw=y,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y,Roll=0}) PBZ.game.setPosture(p,300) return "faced"'
function Swing([string]$move) { "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local cls asc.ActivatableAbilities.Items:ForEach(function(_,e) local ab=e:get().Ability if ab and ab:IsValid() and ab:GetClass():GetFName():ToString()=='$move' then cls=ab:GetClass() end end) if not cls then return 'no move' end return 'swing '..tostring(asc:TryActivateAbilityByClass(cls,true))" }
$stat = 'eval local _,p=PBZ.getPlayer1() return string.format("HP=%.0f posture=%.0f", PBZ.game.getHealth(p), PBZ.game.getPosture(p) or -1)'
function Num($s, $k) { [double]([regex]::Match(($s -join ' '), "$k=(-?\d+)").Groups[1].Value) }

# One exchange. $Defend: none | hold | tap (tap = RMB $TapMs after the move reaches copy 2).
function Exchange([string]$move = 'GA_Hun_Young_A_C', [string]$defend = 'none', [int]$tapMs = 200) {
    & $run -I 2 -Cmd $place -Wait 0.5 | Out-Null
    & $run -I 1 -Cmd $face -Wait 0.5 | Out-Null
    Select-GameInstance -ProcessId @($state.Games)[1] -Instance 2; Show-Game
    $t0 = Get-Date
    if ($defend -eq 'hold') { [GameDriver.Native]::mouse_event(0x8, 0, 0, 0, [UIntPtr]::Zero) }
    $before = (Get-Item $inbox).Length
    Select-GameInstance -ProcessId @($state.Games)[0] -Instance 1; Send-ModCommand (Swing $move)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-Item $inbox).Length -eq $before -and $sw.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 5 }
    if ($defend -eq 'tap') { Start-Sleep -Milliseconds $tapMs; [GameDriver.Native]::mouse_event(0x8, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80; [GameDriver.Native]::mouse_event(0x10, 0, 0, 0, [UIntPtr]::Zero) }
    Start-Sleep -Milliseconds 1500
    if ($defend -eq 'hold') { [GameDriver.Native]::mouse_event(0x10, 0, 0, 0, [UIntPtr]::Zero) }
    Start-Sleep -Milliseconds 600
    $d = & $run -I 2 -Cmd $stat -Wait 0.5
    $a = & $run -I 1 -Cmd $stat -Wait 0.5
    $log = @(Get-ModLog -Since $t0 | Where-Object { $_ -match 'PvP|Move class|couldn' } | ForEach-Object { $_ -replace '^.*\[Lua\] ', '' })
    @{ DefHP = Num $d 'HP'; DefPosture = Num $d 'posture'; AtkPosture = Num $a 'posture'; Log = $log }
}

$Late = $args -contains 'late'    # only the weapon and end-of-round checks
if (-not $Late) {
$r = Exchange
Check 'plain hit damages the defender' ($r.DefHP -lt 850) "HP 850 -> $($r.DefHP)"
Check 'plain hit is not a parry' (-not ($r.Log -match 'PARRIED')) (($r.Log -match 'PARRIED') -join ' / ')
$r = Exchange -defend hold
Check 'held block: no health damage, costs posture' ($r.DefHP -ge 850 -and $r.DefPosture -lt 300) "HP $($r.DefHP), posture 300 -> $($r.DefPosture)"
Check 'held block is not a parry' (-not ($r.Log -match 'PARRIED')) ''
$best = $null
foreach ($ms in 150, 220, 290) {
    $r = Exchange -defend tap -tapMs $ms
    if ($r.Log -match 'PARRIED' -and -not $best) { $best = $r; $bestMs = $ms }
}
Check 'timed parry is rewarded' ([bool]$best) $(if ($best) { "tap +${bestMs}ms: " + ($best.Log -match 'PARRIED' -join ' / ') } else { 'no PARRIED line' })
Check 'parried attacker loses posture' ($best -and $best.AtkPosture -lt 300) "attacker posture 300 -> $($best.AtkPosture)"
Start-Sleep 2
$h = & $run -I 1 -Cmd "eval local _,p=PBZ.getPlayer1() for _,c in ipairs(FindAllOf('HitreactComponent')) do if c:GetOwner():GetAddress()==p:GetAddress() then return 'hitstate='..c:GetCurrentHitState().TagName:ToString() end end return 'hitstate=?'" -Wait 0.6
Check 'parried attacker recovers (can act again)' (($h -join ' ') -match 'hitstate=None') ($h -join ' ')
}

# Another weapon: copy 1 switches to the Iron Blade; copy 2 must load and take its moves.
& $run -I 1 -Cmd 'eval local _,p=PBZ.getPlayer1() local bp=StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(p, StaticFindObject("/Script/ProjectPBZ.PBZBackPackSubsystem")) bp:ApplyForcedWeaponLoadout(FName("IronBlade"),1,false) return "iron"' -Wait 3 | Out-Null
$r = Exchange -move 'GA_Hun_Iron_A_C'
if ($r.DefHP -ge 850) { $r = Exchange -move 'GA_Hun_Iron_A_C' }
Check 'Iron Blade move lands on the defender' ($r.DefHP -lt 850) "HP 850 -> $($r.DefHP) $($r.Log -join ' / ')"
$r = Exchange -move 'GA_Hun_Iron_C_C'
if ($r.DefHP -ge 850) { $r = Exchange -move 'GA_Hun_Iron_C_C' }
Check 'Iron Blade weapon skill lands on the defender' ($r.DefHP -lt 850) "HP 850 -> $($r.DefHP) $($r.Log -join ' / ')"

# End of round: the defender at 30 health takes a hit, stays at 1, loses the round; both heal after the pause.
$round = $null
for ($k = 0; $k -lt 3 -and -not $round; $k++) {
    & $run -I 2 -Cmd $place -Wait 0.5 | Out-Null
    & $run -I 2 -Cmd 'eval local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p,30) return "30"' -Wait 0.3 | Out-Null
    & $run -I 1 -Cmd $face -Wait 0.5 | Out-Null
    $t0 = Get-Date
    & $run -I 1 -Cmd (Swing 'GA_Hun_Iron_A_C') -Wait 2 | Out-Null
    $lines = @(Get-ModLog -Since $t0 | Where-Object { $_ -match 'PvP: (VICTORY|DEFEAT)' })
    if ($lines -match 'PBZCoop#2\].*DEFEAT' -and $lines -match 'PBZCoop\].*VICTORY') { $round = $lines }
}
$d = & $run -I 2 -Cmd 'eval local _,p=PBZ.getPlayer1() return string.format("HP=%.1f dead=%s", PBZ.game.getHealth(p), tostring(PBZ.game.isDead(p)))' -Wait 0.5
Check 'loser stays alive at 1 health' (($d -join ' ') -match 'dead=false') ($d -join ' ')
Check 'round result reaches both players' ([bool]$round) (($round | ForEach-Object { $_ -replace '^.*\[Lua\] ', '' }) -join ' / ')
Start-Sleep 4
$d = & $run -I 2 -Cmd $stat -Wait 0.5
Check 'both heal for the next round' ((Num $d 'HP') -ge 849) ($d -join ' ')

$failed = @($results.GetEnumerator() | Where-Object { -not $_.Value }).Count
Write-Output ("`n{0} of {1} PvP checks passed" -f ($results.Count - $failed), $results.Count)
