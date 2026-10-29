# PvP death check on a running two-copy session (pvp-session.ps1, PvP on in both): copy 2 at 30 health takes copy 1's
# swings until it dies. Prints both players' PvP lines, copy 2's respawn, and whether the death triggered the
# "bell" enemy refresh (which would also respawn copy 1's enemies through the R event).
$run = "$PSScriptRoot\pvp-run.ps1"
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$place = 'eval local pc,me=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local r=g:K2_GetActorRotation().Yaw local x,y=l.X+math.cos(math.rad(r))*150,l.Y+math.sin(math.rad(r))*150 me:K2_SetActorLocation({X=x,Y=y,Z=l.Z+5},false,{},true) me:K2_SetActorRotation({Pitch=0,Yaw=r+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=r+180,Roll=0}) PBZ.game.setHealth(me,30) return "placed"'
$face = 'eval local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local a,b=p:K2_GetActorLocation(),g:K2_GetActorLocation() local y=math.deg(math.atan(b.Y-a.Y,b.X-a.X)) p:K2_SetActorRotation({Pitch=0,Yaw=y,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y,Roll=0}) return "faced"'
$swing = "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local cls asc.ActivatableAbilities.Items:ForEach(function(_,e) local ab=e:get().Ability if ab and ab:IsValid() and ab:GetClass():GetFName():ToString()=='GA_Hun_Young_A_C' then cls=ab:GetClass() end end) return 'swing '..tostring(asc:TryActivateAbilityByClass(cls,true))"
$hp = 'eval local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() return string.format("HP=%.0f dead=%s at %.0f,%.0f dust=%d", PBZ.game.getHealth(p) or -1, tostring(PBZ.game.isDead(p)), l.X, l.Y, p.ConsciousnessDust)'
"copy 2 before: " + (& $run -I 2 -Cmd $hp -Wait 0.5)
$t0 = Get-Date
for ($k = 0; $k -lt 4; $k++) {
    & $run -I 2 -Cmd $place -Wait 0.5 | Out-Null
    & $run -I 1 -Cmd $face -Wait 0.5 | Out-Null
    & $run -I 1 -Cmd $swing -Wait 2 | Out-Null
    $s = & $run -I 2 -Cmd $hp -Wait 0.5
    "after swing ${k}: $s"
    if (($s -join ' ') -match 'dead=true|HP=0') { break }
}
"waiting for respawn..."
Start-Sleep 25
"copy 2 after respawn: " + (& $run -I 2 -Cmd $hp -Wait 0.5)
Get-ModLog -Since $t0 -Last 2000 | Where-Object { $_ -match 'PvP|bell|Bell|Rested|respawn|Ghost hidden|Ghost visible' -and $_ -notmatch '\] > ' } | ForEach-Object { '  ' + ($_ -replace '^.*\[Lua\] ', '') }
