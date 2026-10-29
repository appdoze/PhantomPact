# Edge cases of who-decides-what (docs/AUTHORITY.md), on a fresh two-copy session (pvp-session.ps1):
#   double hits   a swing replayed by the ghost must not count again (PvP on: the ghost has a real Attack)
#   host kills    the client's copy of a host enemy can't die before the host says so, and does when it does
#   heals         a heal on the host's enemy reaches the client's copy
#   deaths        a client's death respawn leaves the host's world alone; a host's refreshes both; bells both
#   spectating    a dead player's camera follows the partner, and comes back on revive
$ErrorActionPreference = 'Stop'
$p = $PSScriptRoot
$results = [ordered]@{}
function Check([string]$name, [bool]$ok, [string]$detail) {
    $results[$name] = $ok
    Write-Output ("{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
}
function Q([int]$i, [string]$c, [double]$w = 1.0) { ((& "$p\pvp-run.ps1" -I $i -Cmd $c -Wait $w) -join ' | ') }
function Num([string]$text, [string]$key) { if ($text -match "$key=(-?[\d.]+)") { [double]$Matches[1] } else { [double]::NaN } }
. "$p\..\game-driver.ps1" -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'

& "$p\..\pbz-selftest.ps1" -Stop | Out-Null     # an earlier run's relays would hold the port
$ready = @(& "$p\pvp-session.ps1" 2>&1 | Select-String 'gameplay')
$ready
if (@($ready | Where-Object { $_ -match 'gameplay: True' }).Count -ne 2) {
    & "$p\..\pbz-selftest.ps1" -Stop | Out-Null
    throw 'A game copy did not reach gameplay: nothing to test (run again).'
}
Start-Sleep 3
$t0 = Get-Date

$defs = "eval PBZT={} function PBZT.near(a) local best,bd for _,e in ipairs(PBZ.game.listEnemies()) do if not PBZ.game.isDead(e) then local d=PBZ.distance(a,e:K2_GetActorLocation()) if not bd or d<bd then best,bd=e,d end end end return best end function PBZT.atk() local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local c asc.ActivatableAbilities.Items:ForEach(function(_,x) local ab=x:get().Ability if ab and ab:IsValid() and ab:GetClass():GetFName():ToString()=='GA_Hun_Young_A_C' then c=ab:GetClass() end end) return c end function PBZT.front(actor,e,cm) local gl=actor:K2_GetActorLocation() local r=actor:K2_GetActorRotation().Yaw e:K2_SetActorLocation({X=gl.X+math.cos(math.rad(r))*cm,Y=gl.Y+math.sin(math.rad(r))*cm,Z=gl.Z+5},false,{},true) e:K2_SetActorRotation({Pitch=0,Yaw=r+180,Roll=0},false) return r end function PBZT.swing() local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) return asc:TryActivateAbilityByClass(PBZT.atk(),true) end function PBZT.st() local s=PBZ.net.stats local hp,po=-1,-1 if PBZT.e and PBZT.e:IsValid() then hp,po=PBZ.game.getHealth(PBZT.e),PBZ.game.getPosture(PBZT.e) or -1 end return string.format('hp=%.1f posture=%.1f reported=%d applied=%d undone=%d dead=%s', hp or -1, po, s.hitsReported or 0, s.hitsApplied or 0, s.undone or 0, tostring(PBZT.e and PBZT.e:IsValid() and PBZ.game.isDead(PBZT.e))) end return 'defs'"
Q 1 $defs | Out-Null; Q 2 $defs | Out-Null
# Same spot and facing in both worlds (the e2e spot), one thug 4.5 m ahead in each: the client matches them.
$spot = 'eval local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=-107617,Y=221427,Z=-13250},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=25.8,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=25.8,Roll=0}) return "spot"'
Q 1 $spot | Out-Null; Q 2 $spot 2 | Out-Null
Q 1 'spawnenemy BP_Monster_MaleThug_Sword_Blue 450' 1 | Out-Null; Q 2 'spawnenemy BP_Monster_MaleThug_Sword_Blue 450' 3 | Out-Null
Q 1 "eval local _,p=PBZ.getPlayer1() PBZT.e=PBZT.near(p:K2_GetActorLocation()) return 'host enemy'" | Out-Null
Q 2 "eval local _,p=PBZ.getPlayer1() PBZT.e=PBZT.near(p:K2_GetActorLocation()) return 'client copy'" | Out-Null
$hs = Q 1 'netstatus'; $cs = Q 2 'netstatus'
Check 'client matches the host enemy' ($cs -match 'remote_enemies=[1-9]') ''
Check 'client copy is held for the host' ($cs -match 'held=[1-9]') (($cs -split ' \| ' | Where-Object { $_ -match 'Mod:' }) -replace '.*(held=\d+).*', '$1')

# --- double hits, PvP on: the host swings (host world takes it natively); the client's ghost of the host
# replays that swing on the client's copy, which must be undone there and never reported back.
Q 1 'pvp on' 1 | Out-Null; Q 2 'pvp on' 2 | Out-Null
# The client steps 4 m aside: standing inside each other, a PvP swing would hit the ghost before the enemy.
Q 2 "eval local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() p:K2_SetActorLocation({X=l.X+170,Y=l.Y-360,Z=l.Z},false,{},true) return 'aside'" 1.5 | Out-Null
$place1 = "eval local _,p=PBZ.getPlayer1() PBZT.front(p,PBZT.e,150) return 'placed'"
$placeG = "eval PBZT.front(PBZ.net.ghost,PBZT.e,150) return 'placed'"
$h0 = Q 1 'eval return PBZT.st()'; $c0 = Q 2 'eval return PBZT.st()'
# Thugs block and step aside: keep swinging (up to 8) until one lands.
for ($k = 0; $k -lt 8; $k++) {
    Q 1 $place1 0.2 | Out-Null; Q 2 $placeG 0.2 | Out-Null; Q 1 'eval return tostring(PBZT.swing())' 1.6 | Out-Null
    if ((Num (Q 1 'eval return PBZT.st()' 0.3) 'hp') -lt (Num $h0 'hp')) { break }
}
Start-Sleep 1
$h1 = Q 1 'eval return PBZT.st()'; $c1 = Q 2 'eval return PBZT.st()'
$hostDrop = (Num $h0 'hp') - (Num $h1 'hp')
Check 'host swing: the host world takes it' ($hostDrop -gt 0) "host hp $(Num $h0 'hp') -> $(Num $h1 'hp')"
Check "host swing: client doesn't report the ghost's replay" ((Num $c1 'reported') -eq (Num $c0 'reported')) "client reported $(Num $c0 'reported') -> $(Num $c1 'reported'), undone $(Num $c0 'undone') -> $(Num $c1 'undone')"
Check 'host swing: no hit applied twice on the host' ((Num $h1 'applied') -eq (Num $h0 'applied')) "host applied $(Num $h0 'applied') -> $(Num $h1 'applied')"
# The reverse: the client swings; the host's ghost replays it on the host's enemy (undone there), and only the
# reported damage lands, so the host's drop matches the client's own.
Q 1 "eval PBZ.game.setHealth(PBZT.e, select(2,PBZ.game.getHealth(PBZT.e))) return 'full'" 1.5 | Out-Null
Start-Sleep 1.5
$h0 = Q 1 'eval return PBZT.st()'; $c0 = Q 2 'eval return PBZT.st()'
for ($k = 0; $k -lt 3; $k++) { Q 2 "eval local _,p=PBZ.getPlayer1() PBZT.front(p,PBZT.e,150) return 'placed'" 0.2 | Out-Null; Q 1 "eval PBZT.front(PBZ.net.ghost,PBZT.e,150) return 'placed'" 0.2 | Out-Null; Q 2 'eval return tostring(PBZT.swing())' 1.6 | Out-Null }
Start-Sleep 1.5
$h1 = Q 1 'eval return PBZT.st()'; $c1 = Q 2 'eval return PBZT.st()'
$clientDrop = (Num $c0 'hp') - (Num $c1 'hp'); $hostDrop = (Num $h0 'hp') - (Num $h1 'hp')
Check 'client swing: reported to the host' ((Num $c1 'reported') -gt (Num $c0 'reported')) "client reported $(Num $c0 'reported') -> $(Num $c1 'reported')"
Check 'client swing: host takes it once' ($hostDrop -gt 0 -and [math]::Abs($hostDrop - $clientDrop) -le 1.5) "host drop $hostDrop, client drop $clientDrop, host undone $(Num $h0 'undone') -> $(Num $h1 'undone')"
Q 1 'pvp off' 1 | Out-Null; Q 2 'pvp off' 2 | Out-Null

# --- heals: the host's enemy gets health back (a boss phase); the client's copy follows within ~1 s.
Q 1 "eval PBZ.game.setHealth(PBZT.e, 200) return 'low'" 1.5 | Out-Null
$c0 = Q 2 'eval return PBZT.st()'
Q 1 "eval PBZ.game.setHealth(PBZT.e, select(2,PBZ.game.getHealth(PBZT.e))) return 'healed'" 2.5 | Out-Null
$c1 = Q 2 'eval return PBZT.st()'
$hmax = Num (Q 1 'eval return PBZT.st()') 'hp'
Check 'heal on the host reaches the client' ((Num $c0 'hp') -le 201 -and [math]::Abs((Num $c1 'hp') - $hmax) -le 1) "client copy $(Num $c0 'hp') -> $(Num $c1 'hp') (host $hmax)"

# --- host decides deaths: the client's killing blow can't kill its copy on its own; the host's K does.
Q 1 "eval PBZ.game.setHealth(PBZT.e, 20) return 'low'" 1.5 | Out-Null
$tk = Get-Date
for ($k = 0; $k -lt 4; $k++) { Q 2 "eval local _,p=PBZ.getPlayer1() PBZT.front(p,PBZT.e,150) return 'placed'" 0.2 | Out-Null; Q 1 "eval PBZT.front(PBZ.net.ghost,PBZT.e,150) return 'placed'" 0.2 | Out-Null; Q 2 'eval return tostring(PBZT.swing())' 1.2 | Out-Null }
Start-Sleep 2
$h1 = Q 1 'eval return PBZT.st()'; $c1 = Q 2 'eval return PBZT.st()'
$klog = @(Get-ModLog -Since $tk | Where-Object { $_ -match '\[PBZCoop#2\] Host says .* died' })
Check "client's killing blow: host's enemy dies" ($h1 -match 'dead=true') $h1
Check 'client copy dies by the host''s word' ($c1 -match 'dead=true' -and $klog.Count -ge 1) "$c1 / K lines $($klog.Count)"

# --- deaths and bells
$tr = Get-Date
Q 2 'respawnrefresh' 3 | Out-Null
$log = @(Get-ModLog -Since $tr -Last 3000)
Check 'client death respawn: client knows it died' ([bool]($log -match '\[PBZCoop#2\] You died and respawned')) ''
Check "client death respawn: host's world untouched" (-not ($log -match '\[PBZCoop\] The (other player rested|host died)')) ''
$tr = Get-Date
Q 1 'respawnrefresh' 3 | Out-Null
$log = @(Get-ModLog -Since $tr -Last 3000)
Check 'host death respawn: client refreshes too' ([bool]($log -match '\[PBZCoop#2\] The host died and respawned')) ''
$tr = Get-Date
Q 2 'rest' 3 | Out-Null
$log = @(Get-ModLog -Since $tr -Last 3000)
Check 'bell rest (client): host refreshes too' ([bool]($log -match '\[PBZCoop\] The other player rested at a bell')) ''
$mirrored = @($log -match '\] The other player rested at a bell')
Check 'one refresh per rest (no echo)' ($mirrored.Count -eq 1) "$($mirrored.Count) mirrored refreshes"

# --- the client dies while the host wins the boss fight: the host's fight goes on untouched, and the host's
# kill still reaches the client's copy of the boss.
Q 1 $spot | Out-Null; Q 2 $spot 2 | Out-Null
Q 1 'spawnenemy BP_Monster_ZuoShang_Young_Tutorial 600' 1 | Out-Null; Q 2 'spawnenemy BP_Monster_ZuoShang_Young_Tutorial 600' 3 | Out-Null
Q 1 "eval local _,p=PBZ.getPlayer1() PBZT.e=PBZT.near(p:K2_GetActorLocation()) return 'boss'" | Out-Null
Q 2 "eval local _,p=PBZ.getPlayer1() PBZT.e=PBZT.near(p:K2_GetActorLocation()) return 'boss copy'" | Out-Null
$tb = Get-Date
Q 1 'bossbar' 3 | Out-Null
Q 1 "eval local h,m=PBZ.game.getHealth(PBZT.e) PBZ.game.setHealth(PBZT.e, m/2) return 'half'" 2 | Out-Null
$b0 = Q 1 'eval return PBZT.st()'
Q 2 'respawnrefresh' 3 | Out-Null
$b1 = Q 1 'eval return PBZT.st()'
Check "client dies mid-boss: host's boss fight untouched" ((Num $b1 'hp') -eq (Num $b0 'hp') -and $b1 -match 'dead=false') "host boss $(Num $b0 'hp') -> $(Num $b1 'hp')"
Q 1 "eval PBZ.game.applyDamage(PBZT.e, 99999, 0) return 'host wins'" 3 | Out-Null
$c1 = Q 2 'eval return PBZT.st()'
$log = @(Get-ModLog -Since $tb -Last 3000)
Check "host's win reaches the respawned client" ($c1 -match 'dead=true' -and ($log -match '\[PBZCoop#2\] Host says .* died')) $c1
Check "boss bar was shown on the client" ([bool]($log -match '\[PBZCoop#2\] Showing boss bar')) ''

# --- spectating: the client's player goes down (tutorial heal off), its camera follows the host, then returns.
$noHeal = "eval local _,p=PBZ.getPlayer1() local asc=StaticFindObject('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(p) local h asc.ActivatableAbilities.Items:ForEach(function(_,e) local s=e:get() if s.Ability:IsValid() and s.Ability:GetClass():GetFName():ToString()=='GA_Tutorial_Health_Passive_C' then h=s.Handle end end) if h then asc:ClearAbility(h) end return 'heal off'"
$view = "eval local pc,p=PBZ.getPlayer1() local v=pc:GetViewTarget() return 'VIEW '..((PBZ.game.isSpectating() and v:GetAddress()~=p:GetAddress()) and 'ghost' or (v:GetAddress()==p:GetAddress() and 'self' or 'other'))"
Q 2 $noHeal | Out-Null
$ts = Get-Date
Q 2 "eval local _,p=PBZ.getPlayer1() PBZ.game.setHealth(p,0) return 'down'" 5 | Out-Null
$v1 = Q 2 $view
Save-GameScreenshot "$env:TEMP\pp-spectate.png" -Scale 0.5 | Out-Null
Q 2 "eval local _,p=PBZ.getPlayer1() local _,m=PBZ.game.getHealth(p) PBZ.game.setHealth(p,m) return 'up'" 2 | Out-Null
$v2 = Q 2 $view
$log = @(Get-ModLog -Since $ts -Last 3000)
Check 'dead player watches the partner' ($v1 -match 'VIEW ghost' -and ($log -match "You're down: watching")) "$v1 (shot: $env:TEMP\pp-spectate.png)"
Check 'camera returns on revive' ($v2 -match 'VIEW self' -and ($log -match 'Back on your feet')) $v2

# --- both grab the same pickup in the same moment: the other's report for a pickup we took ourselves grants
# nothing (each has theirs, as in single-player); a report for one we didn't take still shares the item.
$inv = 'eval local _,p=PBZ.getPlayer1() local bp=StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(p, StaticFindObject("/Script/ProjectPBZ.PBZBackPackSubsystem")) return string.format("INV material=%d", PBZ.game.itemCount(bp, "Weapon_Material_01"))'
Q 1 'eval local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local gs=PBZ.gs() local t={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=l.X+120,Y=l.Y,Z=l.Z},Scale3D={X=1,Y=1,Z=1}} local a=gs:BeginDeferredActorSpawnFromClass(p, StaticFindObject("/Script/ProjectPBZ.PBZPickupActor"), t, 2, nil, 1) a.ItemId=FName("Weapon_Material_01") a.bIsPickable=true a=gs:FinishSpawningActor(a, t, 1) PBZT.pick=a PBZT.pickName=a:GetFName():ToString() return "pickup "..PBZT.pickName' 2 | Out-Null
Q 1 'eval PBZT.pick:K2_DestroyActor() return "taken"' 2 | Out-Null
$m0 = Num (Q 1 $inv) 'material'
$dup = Q 1 'eval PBZ.coop.handlers.I(PBZT.pickName.." Weapon_Material_01") return "dup"' 1
$m1 = Num (Q 1 $inv) 'material'
Q 1 'eval PBZ.coop.handlers.I("PBZPickupActor_NotOurs Weapon_Material_01") return "other"' 1 | Out-Null
$m2 = Num (Q 1 $inv) 'material'
Check 'same pickup grabbed by both: no second copy' ($m1 -eq $m0 -and $dup -match 'too; you already have yours') "material $m0 -> $m1"
Check "partner's pickup is still shared" ($m2 -eq $m1 + 1) "material $m1 -> $m2"
Q 1 'eval local _,p=PBZ.getPlayer1() local bp=StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(p, StaticFindObject("/Script/ProjectPBZ.PBZBackPackSubsystem")) local n=PBZ.game.itemCount(bp,"Weapon_Material_01") if n>0 then bp:RemovePropsFromBackPack(n, FName("Weapon_Material_01"), false) end return "clean"' | Out-Null

# --- the partner vanishes (crash, quit, lost connection): the host's relay dies. Both sides must notice, hide the
# frozen ghost and release what was held for them.
$state = Get-Content "$p\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
$tg = Get-Date
Stop-Process -Id @($state.Relays)[0] -Force -ErrorAction SilentlyContinue
Start-Sleep 9
$log = @(Get-ModLog -Since $tg -Last 3000)
$cs = Q 2 'netstatus'
Check 'client notices the host is gone' ([bool]($log -match '\[PBZCoop#2\] Lost the other player') -and $cs -match 'held=0') (($cs -split ' \| ' | Where-Object { $_ -match 'Mod:' }) -replace '.*(held=\d+).*', '$1')
Check 'host notices the client is gone' ([bool]($log -match '\[PBZCoop\] Lost the other player')) ''
Check 'ghosts hidden, not frozen in place' (@($log -match 'Ghost hidden: the other player is gone').Count -ge 2) ''

# Two copies on one PC: now and then one exits on its own (no crash dump, no Windows error; seen with and without
# these changes). Say so, so its silence isn't read as mod failures.
$st = Get-Content "$p\..\..\logs\selftest-last.json" -Raw | ConvertFrom-Json
$gone = @(@($st.Games) | Where-Object { -not (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
if ($gone.Count) { Write-Output "NOTE  game copy PID $($gone -join ',') exited during the run: the checks after that are void, run again" }

$errors = @(Get-ModLog -Since $t0 -Last 8000 | Where-Object { $_ -match 'net error|event \w+ error|\.lua:\d+' })
Check 'no mod errors' (-not $errors) (($errors | Select-Object -First 2) -join ' | ')
& "$p\..\pbz-selftest.ps1" -Stop | Out-Null
$failed = @($results.GetEnumerator() | Where-Object { -not $_.Value }).Count
Write-Output ("`n{0} of {1} checks passed" -f ($results.Count - $failed), $results.Count)
