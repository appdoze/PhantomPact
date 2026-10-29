<#
.SYNOPSIS
    Copies the PBZCoop mod into a game's UE4SS Mods folder.

.PARAMETER GameWin64
    The game's Binaries\Win64 folder (where the *-Win64-Shipping.exe and UE4SS's dwmapi.dll live).

.EXAMPLE
    .\tools\install-mod.ps1 -GameWin64 "C:\Program Files (x86)\Steam\steamapps\common\BlackMythWukong\b1\Binaries\Win64"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$GameWin64
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $GameWin64)) {
    throw "Folder not found: $GameWin64"
}

# UE4SS 3.x keeps mods in ue4ss\Mods; older releases put Mods next to the DLL.
$modsDir = @('ue4ss\Mods', 'Mods') |
    ForEach-Object { Join-Path $GameWin64 $_ } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if (-not $modsDir) {
    throw "No UE4SS Mods folder in $GameWin64. Install UE4SS first (docs\UE4SS_SETUP.md)."
}

$source = Join-Path $PSScriptRoot '..\mod\PBZCoop'
$target = Join-Path $modsDir 'PBZCoop'

# Copy over the top rather than deleting first, so runtime folders (inst2\ for the self-test, net files) survive.
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item (Join-Path $source '*') $target -Recurse -Force

# This UE4SS build loads the mods listed in mods.txt; without an entry PBZCoop silently doesn't run.
$modsTxt = Join-Path $modsDir 'mods.txt'
if (Test-Path $modsTxt) {
    $text = [IO.File]::ReadAllText($modsTxt)
    if ($text -notmatch '(?m)^\s*PBZCoop\s*:') {
        # Above the built-in Keybinds entry, which UE4SS wants last.
        if ($text -match '(?m)^; Built-in keybinds') {
            $text = $text -replace '(?m)^(; Built-in keybinds)', "PBZCoop : 1`r`n`r`n`$1"
        } else {
            $text = $text.TrimEnd() + "`r`nPBZCoop : 1`r`n"
        }
        [IO.File]::WriteAllText($modsTxt, $text)
        Write-Output "Enabled PBZCoop in $modsTxt"
    } elseif ($text -match '(?m)^\s*PBZCoop\s*:\s*0') {
        [IO.File]::WriteAllText($modsTxt, ($text -replace '(?m)^(\s*PBZCoop\s*:\s*)0', '${1}1'))
        Write-Output "Re-enabled PBZCoop in $modsTxt"
    }
}

Write-Output "Installed PBZCoop to $target"
Write-Output "Restart the game, load into gameplay, then press F6 to test."
