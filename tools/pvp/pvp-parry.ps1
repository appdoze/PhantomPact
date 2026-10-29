# Parry probe: copy 1 swings (through the mod); copy 2 (real input, foreground) taps the right mouse button
# $Delay ms after copy 1's move arrives in copy 2's event inbox. Prints copy 2's health/posture and both logs.
param([int[]]$Delays = @(150, 250, 350, 450))
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$run = "$PSScriptRoot\pvp-run.ps1"
$state = Get-Content "$PSScriptRoot\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
$inbox = 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam\ue4ss\Mods\PBZCoop\inst2\net_events_in.txt'
$place = 'eval local pc,me=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local r=g:K2_GetActorRotation().Yaw local x,y=l.X+math.cos(math.rad(r))*150,l.Y+math.sin(math.rad(r))*150 me:K2_SetActorLocation({X=x,Y=y,Z=l.Z+5},false,{},true) me:K2_SetActorRotation({Pitch=0,Yaw=r+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=r+180,Roll=0}) PBZ.game.setHealth(me,850) PBZ.game.setPosture(me,400) return "placed"'
$face = 'eval local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local a,b=p:K2_GetActorLocation(),g:K2_GetActorLocation() local y=math.deg(math.atan(b.Y-a.Y,b.X-a.X)) p:K2_SetActorRotation({Pitch=0,Yaw=y,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y,Roll=0}) PBZ.game.setPosture(p,400) return "faced"'
$swing = "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local cls asc.ActivatableAbilities.Items:ForEach(function(_,e) local ab=e:get().Ability if ab and ab:IsValid() and ab:GetClass():GetFName():ToString()=='GA_Hun_Young_A_C' then cls=ab:GetClass() end end) return 'swing '..tostring(asc:TryActivateAbilityByClass(cls,true))"
$stat = 'eval local _,p=PBZ.getPlayer1() return string.format("HP=%.0f posture=%.0f", PBZ.game.getHealth(p), PBZ.game.getPosture(p) or -1)'
$stat1 = 'eval local _,p=PBZ.getPlayer1() return string.format("attacker posture=%.0f", PBZ.game.getPosture(p) or -1)'
foreach ($d in $Delays) {
    & $run -I 2 -Cmd $place -Wait 0.5 | Out-Null
    & $run -I 1 -Cmd $face -Wait 0.5 | Out-Null
    Select-GameInstance -ProcessId @($state.Games)[1] -Instance 2; Show-Game
    $before = (Get-Item $inbox).Length
    Select-GameInstance -ProcessId @($state.Games)[0] -Instance 1; Send-ModCommand $swing
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-Item $inbox).Length -eq $before -and $sw.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 5 }
    Start-Sleep -Milliseconds $d
    [GameDriver.Native]::mouse_event(0x8, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [GameDriver.Native]::mouse_event(0x10, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1500
    $t0 = (Get-Date).AddSeconds(-3)
    "tap +${d}ms: defender " + (& $run -I 2 -Cmd $stat -Wait 0.5) + " | " + (& $run -I 1 -Cmd $stat1 -Wait 0.5)
    Get-ModLog -Since $t0 | Where-Object { $_ -match 'PvP' } | ForEach-Object { '    ' + ($_ -replace '^.*\[Lua\] ', '') }
}
