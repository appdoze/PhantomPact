# Real-death check on a running two-copy session (pvp-session.ps1): copy 1 gets a thug to watch, copy 2 loses the
# prologue's tutorial heal (GA_Tutorial_Health_Passive, which won't let the player die), PvP goes on, and copy 1's
# swing kills copy 2. Shows copy 2's respawn (position, health), whether the death ran the game's enemy refresh
# (the mod then sends R and the partner's enemies respawn too), and whether copy 1's thug survived.
$run = "$PSScriptRoot\pvp-run.ps1"
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$state = Get-Content "$PSScriptRoot\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
$me = 'eval local _,p=PBZ.getPlayer1() if not p or not p:IsValid() then return "no pawn" end local l=p:K2_GetActorLocation() return string.format("HP=%.0f dead=%s at %.0f,%.0f", PBZ.game.getHealth(p) or -1, tostring(PBZ.game.isDead(p)), l.X, l.Y)'
$thug = 'eval local out={} for _,e in ipairs(PBZ.game.listEnemies(true)) do out[#out+1]=string.format("%s hp=%.0f dead=%s", e:GetFName():ToString():sub(-10), PBZ.game.getHealth(e) or -1, tostring(PBZ.game.isDead(e))) end return #out.." enemies: "..table.concat(out," | ")'
& $run -I 1 -Cmd 'spawnenemy BP_Monster_MaleThug_Sword_Blue 900' -Wait 3 | Out-Null
"copy 1 enemies before: " + (& $run -I 1 -Cmd $thug -Wait 0.8)
& $run -I 2 -Cmd "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local h asc.ActivatableAbilities.Items:ForEach(function(_,e) local s=e:get() if s.Ability:IsValid() and s.Ability:GetClass():GetFName():ToString()=='GA_Tutorial_Health_Passive_C' then h=s.Handle end end) if not h then return 'no tutorial heal' end asc:ClearAbility(h) return 'tutorial heal removed'" -Wait 1
foreach ($i in 1, 2) { & $run -I $i -Cmd 'pvp on' -Wait 1 | Out-Null }
"copy 2 before: " + (& $run -I 2 -Cmd $me -Wait 0.6)
$t0 = Get-Date
$place = 'eval local pc,me=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local r=g:K2_GetActorRotation().Yaw local x,y=l.X+math.cos(math.rad(r))*150,l.Y+math.sin(math.rad(r))*150 me:K2_SetActorLocation({X=x,Y=y,Z=l.Z+5},false,{},true) me:K2_SetActorRotation({Pitch=0,Yaw=r+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=r+180,Roll=0}) PBZ.game.setHealth(me,5) return "placed"'
$face = 'eval local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local a,b=p:K2_GetActorLocation(),g:K2_GetActorLocation() local y=math.deg(math.atan(b.Y-a.Y,b.X-a.X)) p:K2_SetActorRotation({Pitch=0,Yaw=y,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y,Roll=0}) return "faced"'
$swing = "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local cls asc.ActivatableAbilities.Items:ForEach(function(_,e) local ab=e:get().Ability if ab and ab:IsValid() and ab:GetClass():GetFName():ToString()=='GA_Hun_Young_A_C' then cls=ab:GetClass() end end) return 'swing '..tostring(asc:TryActivateAbilityByClass(cls,true))"
for ($k = 0; $k -lt 3; $k++) {
    & $run -I 2 -Cmd $place -Wait 0.5 | Out-Null
    & $run -I 1 -Cmd $face -Wait 0.5 | Out-Null
    & $run -I 1 -Cmd $swing -Wait 2 | Out-Null
    $s = & $run -I 2 -Cmd $me -Wait 0.6
    "after swing ${k}: $s"
    if (($s -join ' ') -match 'dead=true|HP=0|no pawn') { break }
}
foreach ($wait in 10, 20, 30) {
    Start-Sleep 10
    "copy 2 +${wait}s: " + (& $run -I 2 -Cmd $me -Wait 0.8)
}
"copy 1 enemies after: " + (& $run -I 1 -Cmd $thug -Wait 0.8)
"--- log since the fight:"
Get-ModLog -Since $t0 -Last 3000 | Where-Object { $_ -match 'PvP:|bell|Bell|Rested|respawn|Ghost hidden|Ghost visible|rested' -and $_ -notmatch '\] > ' } | ForEach-Object { '  ' + ($_ -replace '^.*\[Lua\] ', '') }
