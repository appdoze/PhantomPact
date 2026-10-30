# Repeated PvP kills both ways on a running session (pvp-session.ps1, PvP on in both). The prologue's tutorial heal is
# removed (it catches most killing blows) and the loser is brought back with full health after each death, so the
# same player dies again and again: each kill must be scored on both sides, show the winner's victory screen, and
# leave no mod errors or bell refreshes.
param([int]$Rounds = 3)
$noHeal = "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local h asc.ActivatableAbilities.Items:ForEach(function(_,e) local s=e:get() if s.Ability:IsValid() and s.Ability:GetClass():GetFName():ToString()=='GA_Tutorial_Health_Passive_C' then h=s.Handle end end) if h then asc:ClearAbility(h) end return 'heal off'"
$revive = 'eval local _,p=PBZ.getPlayer1() local _,m=PBZ.game.getHealth(p) PBZ.game.setHealth(p,m) return string.format("revived hp=%.0f dead=%s", PBZ.game.getHealth(p), tostring(PBZ.game.isDead(p)))'
$run = "$PSScriptRoot\pvp-run.ps1"
. "$PSScriptRoot\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
$place = 'eval local pc,me=PBZ.getPlayer1() local g=PBZ.net.ghost local l=g:K2_GetActorLocation() local r=g:K2_GetActorRotation().Yaw local x,y=l.X+math.cos(math.rad(r))*150,l.Y+math.sin(math.rad(r))*150 me:K2_SetActorLocation({X=x,Y=y,Z=l.Z+5},false,{},true) me:K2_SetActorRotation({Pitch=0,Yaw=r+180,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=r+180,Roll=0}) PBZ.game.setHealth(me,5) return "placed"'
$face = 'eval local pc,p=PBZ.getPlayer1() local g=PBZ.net.ghost local a,b=p:K2_GetActorLocation(),g:K2_GetActorLocation() local y=math.deg(math.atan(b.Y-a.Y,b.X-a.X)) p:K2_SetActorRotation({Pitch=0,Yaw=y,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=y,Roll=0}) return "faced"'
$swing = "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local cls asc.ActivatableAbilities.Items:ForEach(function(_,e) local ab=e:get().Ability if ab and ab:IsValid() and ab:GetClass():GetFName():ToString()=='GA_Hun_Young_A_C' then cls=ab:GetClass() end end) return 'swing '..tostring(asc:TryActivateAbilityByClass(cls,true))"
$screen = "eval local w=FindAllOf('W_PlayerDead_C') or {} local v={} for _,x in ipairs(w) do v[#v+1]=tostring(x:GetVisibility()) end return 'screens '..#w..' vis '..table.concat(v,',')"
foreach ($i in 1, 2) { & $run -I $i -Cmd $noHeal -Wait 0.6 | Out-Null }
$t0 = Get-Date
$results = @()
foreach ($attacker in 1, 2) {
    $defender = 3 - $attacker
    for ($k = 1; $k -le $Rounds; $k++) {
        $tk = Get-Date
        $scored = $false
        for ($try = 0; $try -lt 5 -and -not $scored; $try++) {
            & $run -I $defender -Cmd $place -Wait 0.5 | Out-Null
            & $run -I $attacker -Cmd $face -Wait 0.4 | Out-Null
            & $run -I $attacker -Cmd $swing -Wait 1.5 | Out-Null
            $lines = @(Get-ModLog -Since $tk | Where-Object { $_ -match 'PvP: (VICTORY|DEFEAT)' })
            $scored = ($lines | Where-Object { $_ -match 'DEFEAT' }).Count -gt 0
        }
        $win = if ($attacker -eq 1) { '\[PBZCoop\] PvP: VICTORY' } else { '\[PBZCoop#2\] PvP: VICTORY' }
        $lose = if ($defender -eq 1) { '\[PBZCoop\] PvP: DEFEAT' } else { '\[PBZCoop#2\] PvP: DEFEAT' }
        Start-Sleep -Milliseconds 800
        $lines = @(Get-ModLog -Since $tk | Where-Object { $_ -match 'PvP: (VICTORY|DEFEAT)' })
        $vis = (& $run -I $attacker -Cmd $screen -Wait 0.5) -join ' '
        $ok = ($lines -match $win).Count -eq 1 -and ($lines -match $lose).Count -eq 1 -and $vis -match 'vis 3'
        $results += $ok
        "copy $attacker kills copy $defender (#$k): " + $(if ($ok) { 'PASS' } else { 'FAIL' }) + "  " + (($lines | ForEach-Object { $_ -replace '^.*\[Lua\] \[(PBZCoop#?2?)\] PvP: ', '[$1] ' }) -join ' / ') + "  winner $vis"
        Start-Sleep 2
        "    loser " + ((& $run -I $defender -Cmd $revive -Wait 0.6) -join ' ')
        Start-Sleep 2
    }
}
Start-Sleep 7
foreach ($i in 1, 2) { "copy $i after: " + ((& $run -I $i -Cmd 'pvp status' -Wait 0.6) -join ' ') + '  ' + ((& $run -I $i -Cmd $screen -Wait 0.5) -join ' ') }
$bad = @(Get-ModLog -Since $t0 -Last 5000 | Where-Object { $_ -match 'Rested at a bell|net error|event \w+ error|\.lua:\d+' })
"bell refreshes / mod errors: $($bad.Count) " + (($bad | Select-Object -First 3) -join ' | ')
"{0} of {1} kills scored correctly" -f @($results | Where-Object { $_ }).Count, $results.Count
