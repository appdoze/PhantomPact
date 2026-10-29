<#
.SYNOPSIS
    Launch-day setup for Phantom Blade Zero: finds the game, backs up saves, installs and configures UE4SS,
    applies a PBZ custom config if UE4SS ships one, installs PBZCoop and records the game build.

.PARAMETER UE4SSZip
    Path to the UE4SS experimental zip (UE4SS_v3.0.1-*.zip). Required unless -Disable/-Enable.
.PARAMETER ConfigsZip
    Optional path to zCustomGameConfigs.zip from the same release.
.PARAMETER Disable / -Enable
    Turn UE4SS off/on by renaming dwmapi.dll (nothing is deleted).
.PARAMETER GameRoot
    Override the install folder (for testing); normally read from the Steam manifest.

.EXAMPLE
    .\tools\pbz-setup.ps1 -UE4SSZip C:\dl\UE4SS_v3.0.1-1200-gabc.zip -ConfigsZip C:\dl\zCustomGameConfigs.zip
    .\tools\pbz-setup.ps1 -Disable
#>
param(
    [string]$UE4SSZip,
    [string]$ConfigsZip,
    [switch]$Disable,
    [switch]$Enable,
    [string]$SteamLibrary = 'D:\SteamLibrary',
    [int]$SteamAppId = 4115450,
    [string]$GameRoot
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

function Step($msg) { Write-Output "`n== $msg" }

# 1. Find the game.
$manifest = $null
if (-not $GameRoot) {
    $manifest = Join-Path $SteamLibrary "steamapps\appmanifest_$SteamAppId.acf"
    if (-not (Test-Path $manifest)) { throw "Steam manifest not found: $manifest" }
    $installDir = [regex]::Match((Get-Content $manifest -Raw), '"installdir"\s+"([^"]+)"').Groups[1].Value
    $GameRoot = Join-Path $SteamLibrary "steamapps\common\$installDir"
}
# Standard UE games ship <Project>\Binaries\Win64\<Project>-Win64-Shipping.exe. PBZ instead ships the real game
# as platform\steam\PBZ.exe (steam\PBZ.exe is only a launcher), so fall back to the biggest exe under platform\.
$exe = Get-ChildItem $GameRoot -Recurse -Filter '*-Win64-Shipping.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $exe) {
    $exe = Get-ChildItem (Join-Path $GameRoot 'platform') -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
}
if (-not $exe) {
    throw "No game exe under $GameRoot. Has the game unlocked and finished installing in Steam?"
}
$win64 = $exe.DirectoryName
# The UE project is the folder that holds Content\Paks (ProjectPBZ for PBZ).
$project = (Get-ChildItem $GameRoot -Directory | Where-Object { $_.Name -ne 'Engine' -and (Test-Path (Join-Path $_.FullName 'Content\Paks')) } | Select-Object -First 1).Name
$dll = Join-Path $win64 'dwmapi.dll'

if ($Disable -or $Enable) {
    $off = "$dll.disabled"
    if ($Disable -and (Test-Path $dll)) { Rename-Item $dll (Split-Path $off -Leaf); Write-Output "UE4SS disabled." }
    elseif ($Enable -and (Test-Path $off)) { Rename-Item $off 'dwmapi.dll'; Write-Output "UE4SS enabled." }
    else { Write-Output "Nothing to change (dwmapi.dll present: $(Test-Path $dll))." }
    return
}
if (-not $UE4SSZip -or -not (Test-Path $UE4SSZip)) { throw "Pass -UE4SSZip with the downloaded UE4SS zip." }

Step "Game"
$ver = $exe.VersionInfo
$info = [ordered]@{
    Exe            = $exe.FullName
    Project        = $project
    ExeSizeMB      = [math]::Round($exe.Length / 1MB)
    FileVersion    = $ver.FileVersion
    ProductVersion = $ver.ProductVersion
    SteamBuildId   = if ($manifest) { [regex]::Match((Get-Content $manifest -Raw), '"buildid"\s+"(\d+)"').Groups[1].Value } else { '' }
    RecordedAt     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
}
$info.GetEnumerator() | ForEach-Object { '{0,-15} {1}' -f $_.Key, $_.Value }

# 2. First run without mods: UE writes its config to %LOCALAPPDATA%\<Project>\Saved on first launch.
$userSaved = Join-Path $env:LOCALAPPDATA "$project\Saved"
if (-not (Test-Path $userSaved)) {
    Write-Warning "No $userSaved yet. Launch the game once WITHOUT mods, reach gameplay, quit, then rerun this script."
    return
}

Step "Save backup"
$backupRoot = Join-Path (Split-Path $SteamLibrary -Qualifier) "\PBZSaveBackup\$(Get-Date -Format yyyyMMdd-HHmmss)"
$saveDirs = @((Join-Path $userSaved 'SaveGames'), (Join-Path $GameRoot "$project\Saved\SaveGames")) | Where-Object { Test-Path $_ }
if ($saveDirs.Count -eq 0) {
    Write-Warning "No SaveGames folder found yet (the game may save elsewhere). Search for *.sav before testing."
}
foreach ($d in $saveDirs) {
    $dst = Join-Path $backupRoot ($d -replace '[:\\]', '_')
    New-Item -ItemType Directory -Force $dst | Out-Null
    Copy-Item "$d\*" $dst -Recurse
    Write-Output "Backed up $d -> $dst"
}

Step "UE4SS"
if (Test-Path $dll) { throw "dwmapi.dll already exists in $win64. UE4SS (or another mod) is already installed." }
Expand-Archive $UE4SSZip -DestinationPath $win64
$ue4ss = Join-Path $win64 'ue4ss'
$ini = Join-Path $ue4ss 'UE4SS-settings.ini'

if ($ConfigsZip) {
    $tmp = Join-Path $env:TEMP "ue4ss-configs-$PID"
    Expand-Archive $ConfigsZip -DestinationPath $tmp -Force
    $pattern = '(?i)phantom|pbz|' + [regex]::Escape($project)
    $match = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
    if ($match) {
        Copy-Item "$($match.FullName)\*" $ue4ss -Recurse -Force
        Write-Output "Applied custom game config '$($match.Name)'."
    } else {
        Write-Output "No PBZ custom config in this release (expected on day one)."
    }
    Remove-Item $tmp -Recurse -Force
}

# Text console on, GUI off (the GUI is one more thing that can crash a new game).
$t = Get-Content $ini -Raw
$t = $t -replace '(?m)^ConsoleEnabled = \d', 'ConsoleEnabled = 1'
$t = $t -replace '(?m)^GuiConsoleEnabled = \d', 'GuiConsoleEnabled = 0'
$t = $t -replace '(?m)^GuiConsoleVisible = \d', 'GuiConsoleVisible = 0'
[IO.File]::WriteAllText($ini, $t)
Select-String -Path $ini -Pattern '^(ConsoleEnabled|GuiConsoleEnabled|bUseUObjectArrayCache|MajorVersion|MinorVersion) ' | ForEach-Object { '  ' + $_.Line }

# Only PBZCoop runs; the bundled sample mods stay off.
$modsTxt = Join-Path $ue4ss 'Mods\mods.txt'
if (Test-Path $modsTxt) { [IO.File]::WriteAllText($modsTxt, ((Get-Content $modsTxt -Raw) -replace '(?m)^(\w+) : 1', '$1 : 0')) }
$modsJson = Join-Path $ue4ss 'Mods\mods.json'
if (Test-Path $modsJson) {
    $mods = Get-Content $modsJson -Raw | ConvertFrom-Json
    foreach ($m in $mods) { $m.mod_enabled = $false }
    [IO.File]::WriteAllText($modsJson, ($mods | ConvertTo-Json))
}

Step "PBZCoop"
& (Join-Path $PSScriptRoot 'install-mod.ps1') -GameWin64 $win64

Step "Record"
$label = if ($info.SteamBuildId) { $info.SteamBuildId } else { 'unknown' }
$dumpDir = Join-Path $projectRoot "dumps\pbz-$label"
New-Item -ItemType Directory -Force $dumpDir | Out-Null
$info.GetEnumerator() | ForEach-Object { '{0}: {1}' -f $_.Key, $_.Value } | Set-Content (Join-Path $dumpDir 'game-info.txt') -Encoding utf8
Write-Output "Game info written to $dumpDir\game-info.txt"

Write-Output "`nDone. Driver line for this game:"
Write-Output ". .\tools\game-driver.ps1 -GameWin64 '$win64' -ProcessName '$($exe.BaseName)'"
