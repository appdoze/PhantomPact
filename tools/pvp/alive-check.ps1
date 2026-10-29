# Victory screen check on a running two-copy session (pvp-session.ps1): copy 1 kills copy 2 (tutorial heal removed)
# with PvP on. Copy 1 must show the golden 生還 / ALIVE screen (screenshot), hide it again, keep its enemy and not
# run the bell refresh (removing the death widget would).
param([string]$Shot = "$env:TEMP\pbz-alive.png")
$run = "$PSScriptRoot\pvp-run.ps1"
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$state = Get-Content "$PSScriptRoot\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
$thug = 'eval local out={} for _,e in ipairs(PBZ.game.listEnemies(true)) do out[#out+1]=string.format("hp=%.0f dead=%s", PBZ.game.getHealth(e) or -1, tostring(PBZ.game.isDead(e))) end return #out.." enemies: "..table.concat(out," | ")'
& $run -I 1 -Cmd 'spawnenemy BP_Monster_MaleThug_Sword_Blue 900' -Wait 3 | Out-Null
"copy 1 enemies before: " + (& $run -I 1 -Cmd $thug -Wait 0.8)
& $run -I 2 -Cmd "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local h asc.ActivatableAbilities.Items:ForEach(function(_,e) local s=e:get() if s.Ability:IsValid() and s.Ability:GetClass():GetFName():ToString()=='GA_Tutorial_Health_Passive_C' then h=s.Handle end end) if h then asc:ClearAbility(h) end return 'heal off'" -Wait 1 | Out-Null
foreach ($i in 1, 2) { & $run -I $i -Cmd 'pvp on' -Wait 1 | Out-Null }
$t0 = Get-Date
$place = 'eval local pc,me=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local r=g:K2_GetActorRotation().Yaw local x,y=l.X+math.cos(math.rad(r))*150,l.Y+math.sin(math.rad(r))*150 me:K2_SetActorLocation({X=x,Y=y,Z=l.Z+5},false,{},true) me:K2_SetActorRotation({Pitch=0,Yaw=r+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=r+180,Roll=0}) PBZ.game.setHealth(me,5) return "placed"'
$face = 'eval local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local a,b=p:K2_GetActorLocation(),g:K2_GetActorLocation() local y=math.deg(math.atan(b.Y-a.Y,b.X-a.X)) p:K2_SetActorRotation({Pitch=0,Yaw=y,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y,Roll=0}) return "faced"'
$swing = "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local cls asc.ActivatableAbilities.Items:ForEach(function(_,e) local ab=e:get().Ability if ab and ab:IsValid() and ab:GetClass():GetFName():ToString()=='GA_Hun_Young_A_C' then cls=ab:GetClass() end end) return 'swing '..tostring(asc:TryActivateAbilityByClass(cls,true))"
& $run -I 2 -Cmd $place -Wait 0.5 | Out-Null
& $run -I 1 -Cmd $face -Wait 0.5 | Out-Null
Select-GameInstance -ProcessId @($state.Games)[0] -Instance 1; Show-Game
Send-ModCommand $swing
$won = $false
for ($k = 0; $k -lt 40 -and -not $won; $k++) {
    Start-Sleep -Milliseconds 100
    $won = [bool](Get-ModLog -Since $t0 | Where-Object { $_ -match '\[PBZCoop\] PvP: VICTORY' })
}
Start-Sleep -Milliseconds 700
Save-GameScreenshot $Shot -Scale 0.5 | Out-Null
"victory logged: $won; screenshot: $Shot"
Start-Sleep 6
& $run -I 1 -Cmd "eval local w=FindAllOf('W_PlayerDead_C') or {} local v={} for _,x in ipairs(w) do v[#v+1]=tostring(x:GetVisibility()) end return 'death widgets: '..#w..' visibility: '..table.concat(v,',')" -Wait 0.8
"copy 1 enemies after: " + (& $run -I 1 -Cmd $thug -Wait 0.8)
Get-ModLog -Since $t0 -Last 3000 | Where-Object { $_ -match 'PvP:|Rested|rested|Victory screen' -and $_ -notmatch '\] > ' } | ForEach-Object { '  ' + ($_ -replace '^.*\[Lua\] ', '') }
