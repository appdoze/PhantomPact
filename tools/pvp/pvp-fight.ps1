# PvP fight probe: copy $Attacker swings (abilities activated through the mod, so no window focus is needed) at
# copy $Defender, which is placed 1.5 m in front of the attacker's ghost before every swing. Prints the defender's
# health/posture and the PvP lines from both logs.
param([int]$Attacker = 1, [int]$Swings = 6, [string]$Move = 'GA_Hun_Young_A_C', [string]$DefenderEval = '')
$run = "$PSScriptRoot\pvp-run.ps1"
$Defender = 3 - $Attacker
$place = 'eval local pc,me=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local r=g:K2_GetActorRotation().Yaw local x,y=l.X+math.cos(math.rad(r))*150,l.Y+math.sin(math.rad(r))*150 me:K2_SetActorLocation({X=x,Y=y,Z=l.Z+5},false,{},true) me:K2_SetActorRotation({Pitch=0,Yaw=r+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=r+180,Roll=0}) return "placed"'
$face = 'eval local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local a,b=p:K2_GetActorLocation(),g:K2_GetActorLocation() local y=math.deg(math.atan(b.Y-a.Y,b.X-a.X)) p:K2_SetActorRotation({Pitch=0,Yaw=y,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y,Roll=0}) return "faced"'
$swing = "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local cls asc.ActivatableAbilities.Items:ForEach(function(_,e) local ab=e:get().Ability if ab and ab:IsValid() and ab:GetClass():GetFName():ToString()=='$Move' then cls=ab:GetClass() end end) if not cls then return 'no $Move' end return 'swing '..tostring(asc:TryActivateAbilityByClass(cls,true))"
$stat = 'eval local _,p=PBZ.getPlayer1() return string.format("HP=%.0f posture=%.0f", PBZ.game.getHealth(p), PBZ.game.getPosture(p) or -1)'
for ($s = 0; $s -lt $Swings; $s++) {
    & $run -I $Defender -Cmd $place -Wait 0.5 | Out-Null
    & $run -I $Attacker -Cmd $face -Wait 0.5 | Out-Null
    if ($DefenderEval) { & $run -I $Defender -Cmd $DefenderEval -Wait 0.1 | Out-Null }
    $sw = & $run -I $Attacker -Cmd $swing -Wait 1.6
    $d = & $run -I $Defender -Cmd $stat -Wait 0.6
    "swing $s ($sw): defender $d"
}
Get-Content 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam\ue4ss\UE4SS.log' -Tail 300 | Where-Object { $_ -match 'PvP' -and $_ -notmatch '\] > ' } | Select-Object -Last 8 | ForEach-Object { $_.Substring(12) }
