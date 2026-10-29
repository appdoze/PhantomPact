<#
.SYNOPSIS
    End-to-end co-op test: two PBZ copies on this PC (host + client), checked feature by feature.
    Starts both copies (pbz-selftest.ps1), continues both saves, connects them, then checks: players see each
    other, client matches host enemies, client hits land in the host world, boss fight + boss bar, host kills
    reach the client, bell rest, shared dust, shared loot. Cleans up the test dust/items and stops everything.
    Prints PASS/FAIL per check; exit code 0 only if all pass.

.EXAMPLE
    .\tools\pbz-e2e.ps1
#>
param(
    [string]$GameWin64 = 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam',
    # Test the player setup: PhantomPact.ini says Host (copy 1) and Guest (copy 2), and the mod starts its own
    # relays and turns sync on by itself. Without it the test starts the relays and sends neton itself.
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'
$results = [ordered]@{}
function Check([string]$name, [bool]$ok, [string]$detail) {
    $results[$name] = $ok
    Write-Output ("{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
}

. (Join-Path $PSScriptRoot 'game-driver.ps1') -GameWin64 $GameWin64 -ProcessName 'PBZ'
Get-Process PBZ -ErrorAction SilentlyContinue | Where-Object SessionId -eq (Get-Process -Id $PID).SessionId | Stop-Process -Force
Start-Sleep 3
& (Join-Path $PSScriptRoot 'install-mod.ps1') -GameWin64 $GameWin64 | Out-Null
$modRoot = Join-Path $GameWin64 'ue4ss\Mods\PBZCoop'
New-Item -ItemType Directory -Force (Join-Path $modRoot 'inst2') | Out-Null
$ini1, $ini2 = (Join-Path $modRoot 'PhantomPact.ini'), (Join-Path $modRoot 'inst2\PhantomPact.ini')
if ($Auto) {
    Set-Content $ini1 "Role = Host`r`nPort = 47800" -Encoding ascii
    Set-Content $ini2 "Role = Guest`r`nHostAddress = 127.0.0.1`r`nPort = 47800" -Encoding ascii
} else {
    Set-Content $ini1 'Role = Off' -Encoding ascii; Set-Content $ini2 'Role = Off' -Encoding ascii
}
$t0Launch = Get-Date
if ($Auto) { & (Join-Path $PSScriptRoot 'pbz-selftest.ps1') -NoRelays | Out-Null } else { & (Join-Path $PSScriptRoot 'pbz-selftest.ps1') | Out-Null }
$state = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\selftest-last.json') -Raw | ConvertFrom-Json
$hostPid, $clientPid = @($state.Games)[0], @($state.Games)[1]
if (-not $clientPid) { Check 'two copies start' $false 'copy 2 did not start'; exit 1 }
Check 'two copies start' $true "host $hostPid, client $clientPid"

function Use([int]$i) { if ($i -eq 1) { Select-GameInstance -ProcessId $hostPid -Instance 1 } else { Select-GameInstance -ProcessId $clientPid -Instance 2 } }
function Run([int]$i, [string]$cmd, [double]$wait = 1.5) {
    Use $i; $t0 = Get-Date; Send-ModCommand $cmd; Start-Sleep -Milliseconds ([int]($wait * 1000))
    $tag = if ($i -eq 1) { '\[PBZCoop\] ' } else { '\[PBZCoop#2\] ' }
    Get-ModLog -Since $t0 | Where-Object { $_ -match $tag -and $_ -notmatch '\] > ' } | ForEach-Object { $_ -replace '^.*?\[PBZCoop#?2?\] ', '' }
}

# Both copies into gameplay (Enter = CONTINUE; copy 2 may compile shaders first).
foreach ($i in 1, 2) {
    Use $i; $ok = $false
    for ($k = 0; $k -lt 10 -and -not $ok; $k++) {
        if (Wait-Gameplay -TimeoutSec 6) { $ok = $true; break }
        Show-Game; Send-GameKey RETURN; Start-Sleep 10
        $ok = Wait-Gameplay -TimeoutSec 20
    }
    Check "copy $i in gameplay" $ok ''
    if (-not $ok) { & (Join-Path $PSScriptRoot 'pbz-selftest.ps1') -Stop | Out-Null; exit 1 }
}

# Same spot and facing in both worlds, so enemies spawned "in front" stand at the same place in each.
$setup = 'eval local pc,p=PBZ.getPlayer1() p:K2_SetActorLocation({X=-107617,Y=221427,Z=-13250},false,{},true) p:K2_SetActorRotation({Pitch=0,Yaw=25.8,Roll=0},false) pc:SetControlRotation({Pitch=-10,Yaw=25.8,Roll=0}) return "ok"'
Run 1 $setup | Out-Null; Run 2 $setup | Out-Null
if ($Auto) {
    # The mods started their relays at launch and turn sync on by themselves once in gameplay.
    $deadline = (Get-Date).AddSeconds(30)
    do { Start-Sleep 2; $boot = @(Get-ModLog -Since $t0Launch -Last 5000) } until (
        (($boot | Where-Object { $_ -match '\[PBZCoop\] Phantom Pact Host: co-op on' }) -and
         ($boot | Where-Object { $_ -match '\[PBZCoop#2\] Phantom Pact Guest: co-op on' })) -or (Get-Date) -gt $deadline)
    $started = ($boot | Where-Object { $_ -match '\[PBZCoop\] Relay started as host' }) -and ($boot | Where-Object { $_ -match '\[PBZCoop#2\] Relay started as guest' })
    $on = ($boot | Where-Object { $_ -match 'Host: co-op on' }) -and ($boot | Where-Object { $_ -match 'Guest: co-op on' })
    Check 'mods start their relays from PhantomPact.ini' ([bool]$started) ''
    Check 'co-op turns on by itself in gameplay' ([bool]$on) ''
    Start-Sleep 4
} else {
    Run 1 'neton host' 1 | Out-Null; Run 2 'neton client' 4 | Out-Null
}
$h = Run 1 'netstatus'; $c = Run 2 'netstatus'
Check 'relay connected' (($h -join ' ') -match 'connected=yes' -and ($c -join ' ') -match 'connected=yes') ''
Check 'players see each other' (($h -join ' ') -match 'ghost=true' -and ($c -join ' ') -match 'ghost=true') ''

# Monsters: same thug in both worlds; client must match the host's (different runtime names).
Run 1 'spawnenemy BP_Monster_MaleThug_Sword_Blue 450' | Out-Null; Run 2 'spawnenemy BP_Monster_MaleThug_Sword_Blue 450' 3 | Out-Null
$c = Run 2 'netstatus'
Check 'client matches host enemy' (($c -join ' ') -match 'remote_enemies=[1-9]') (($c | Select-String 'Mod:') -replace '.*(remote_enemies=\d+).*', '$1')

# Client hits: real attacks from the client copy; the host world must take the damage.
$hp = 'eval local n=0 for _,e in ipairs(PBZ.game.listEnemies()) do if not PBZ.game.isDead(e) then n=n+PBZ.game.getHealth(e)+PBZ.game.getPosture(e) end end return string.format("POOL %.0f", n)'
$before = [double](((Run 1 $hp) -join ' ') -replace '.*POOL (\d+).*', '$1')
$face = 'eval local best,bd=nil,1e9 local pc,p=PBZ.getPlayer1() local a=p:K2_GetActorLocation() for _,e in ipairs(PBZ.game.listEnemies()) do if not PBZ.game.isDead(e) then local d=PBZ.distance(a,e:K2_GetActorLocation()) if d<bd then best,bd=e,d end end end if best then local b=best:K2_GetActorLocation() pc:SetControlRotation({Pitch=-10,Yaw=math.deg(math.atan(b.Y-a.Y,b.X-a.X)),Roll=0}) end'
for ($r = 0; $r -lt 6; $r++) {
    Run 2 $face 0.2 | Out-Null; Use 2; Show-Game
    [GameDriver.Native]::keybd_event(0x57, 0x11, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 300; [GameDriver.Native]::keybd_event(0x57, 0x11, 2, [UIntPtr]::Zero)
    for ($i = 0; $i -lt 4; $i++) { [GameDriver.Native]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [GameDriver.Native]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 400 }
}
Start-Sleep 2
$after = [double](((Run 1 $hp) -join ' ') -replace '.*POOL (\d+).*', '$1')
$hs = Run 1 'netstatus'
$applied = [int]((($hs | Select-String 'Mod:') -replace '.*hits_applied=(\d+).*', '$1'))
Check 'client hits land in host world' ($applied -gt 0 -and $after -lt $before) "hits applied $applied, host enemy health+posture $before -> $after"

# Bosses: same boss in both worlds; the host's fight shows the boss bar on the client.
Run 1 'eval for _,e in ipairs(PBZ.game.listEnemies()) do PBZ.game.applyDamage(e,99999,0) end' 2 | Out-Null
# The client turned and moved while attacking: line both players up again so the two bosses spawn at one spot.
Run 1 $setup | Out-Null; Run 2 $setup | Out-Null
Run 1 'spawnenemy BP_Monster_ZuoShang_Young_Tutorial 600' | Out-Null; Run 2 'spawnenemy BP_Monster_ZuoShang_Young_Tutorial 600' 3 | Out-Null
Use 2; $t0 = Get-Date; Run 1 'bossbar' 4 | Out-Null
$clientLog = Get-ModLog -Since $t0 | Where-Object { $_ -match '\[PBZCoop#2\] ' }
Check 'boss fight shows boss bar on client' (($clientLog -join ' ') -match 'Showing boss bar') ''

# Deaths: the host kills the boss; the client's copy must die too.
Use 2; $t0 = Get-Date
Run 1 'eval for _,e in ipairs(PBZ.game.listEnemies()) do PBZ.game.applyDamage(e,99999,0) end' 4 | Out-Null
$clientLog = Get-ModLog -Since $t0 | Where-Object { $_ -match '\[PBZCoop#2\] ' }
Check 'host kill reaches client' (($clientLog -join ' ') -match 'Host says? .* died.*killed it here') ''

# Bell rest, dust, loot: host side actions, client must follow.
$inv = 'eval local _,p=PBZ.getPlayer1() local bp=StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(p, StaticFindObject("/Script/ProjectPBZ.PBZBackPackSubsystem")) return string.format("INV dust=%d material=%d", p.ConsciousnessDust, PBZ.game.itemCount(bp, "Weapon_Material_01"))'
$c0 = (Run 2 $inv) -join ' '
Use 2; $t0 = Get-Date
Run 1 'rest' 3 | Out-Null
Run 1 'eval local _,p=PBZ.getPlayer1() p:ChangeDustNumInternal(20)' 2 | Out-Null
Run 1 'eval local _,p=PBZ.getPlayer1() local l=p:K2_GetActorLocation() local gs=PBZ.gs() local t={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=l.X+120,Y=l.Y,Z=l.Z},Scale3D={X=1,Y=1,Z=1}} local a=gs:BeginDeferredActorSpawnFromClass(p, StaticFindObject("/Script/ProjectPBZ.PBZPickupActor"), t, 2, nil, 1) a.ItemId=FName("Weapon_Material_01") a.bIsPickable=true a=gs:FinishSpawningActor(a, t, 1) PBZ.testPickup=a' 2 | Out-Null
Run 1 'eval PBZ.testPickup:K2_DestroyActor()' 4 | Out-Null
$clientLog = Get-ModLog -Since $t0 | Where-Object { $_ -match '\[PBZCoop#2\] ' }
$c1 = (Run 2 $inv) -join ' '
$d0 = [int]($c0 -replace '.*dust=(\d+).*', '$1'); $d1 = [int]($c1 -replace '.*dust=(\d+).*', '$1')
$m0 = [int]($c0 -replace '.*material=(\d+).*', '$1'); $m1 = [int]($c1 -replace '.*material=(\d+).*', '$1')
Check 'bell rest respawns on client' (($clientLog -join ' ') -match 'rested at a bell') ''
Check 'shared dust' ($d1 -ge $d0 + 20) "client dust $d0 -> $d1"
Check 'shared loot' ($m1 -eq $m0 + 1) "client material $m0 -> $m1"

# Clean up what the test granted, then stop everything.
$clean = 'eval local _,p=PBZ.getPlayer1() local bp=StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(p, StaticFindObject("/Script/ProjectPBZ.PBZBackPackSubsystem")) local n=PBZ.game.itemCount(bp,"Weapon_Material_01") if n>0 then bp:RemovePropsFromBackPack(n, FName("Weapon_Material_01"), false) end p:ChangeDustNumInternal(-p.ConsciousnessDust) return "clean"'
Run 1 $clean | Out-Null; Run 2 $clean | Out-Null
Run 1 'netoff' | Out-Null; Run 2 'netoff' | Out-Null
$errors = Get-ModLog -Since (Get-Date).AddMinutes(-15) | Where-Object { $_ -match 'net error|event \w+ error|\.lua:\d+' }
Check 'no mod errors' (-not $errors) (($errors | Select-Object -First 2) -join ' | ')
& (Join-Path $PSScriptRoot 'pbz-selftest.ps1') -Stop | Out-Null
if ($Auto) {
    # The relays the mods started must notice the games are gone (stale heartbeat) and exit.
    $deadline = (Get-Date).AddSeconds(60)
    do { Start-Sleep 3; $left = @(Get-CimInstance Win32_Process -Filter "Name like 'py%'" | Where-Object { $_.CommandLine -match 'pbzcoop_net.*--alive-file' }) } until (-not $left -or (Get-Date) -gt $deadline)
    Check 'relays close when the game closes' (-not $left) "$($left.Count) left"
    # Back to the shipped settings (Guest with no address = off), so a normal game start doesn't auto-host.
    Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'mod\PBZCoop\PhantomPact.ini') $ini1 -Force
    Remove-Item $ini2 -Force
}

$failed = @($results.GetEnumerator() | Where-Object { -not $_.Value }).Count
Write-Output ("`n{0} of {1} checks passed" -f ($results.Count - $failed), $results.Count)
exit $(if ($failed) { 1 } else { 0 })
