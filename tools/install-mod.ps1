<#
.SYNOPSIS
    Copies the PBZCoop mod into a game's UE4SS Mods folder.

.PARAMETER GameWin64
    The folder of the real game exe, where UE4SS's dwmapi.dll lives (for PBZ: ...\PBZ\platform\steam).
    Found through Steam when left out.

.EXAMPLE
    .\tools\install-mod.ps1
    .\tools\install-mod.ps1 -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam'
#>
param(
    [string]$GameWin64
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'find-game.ps1')
if (-not $GameWin64) {
    $GameWin64 = Find-PbzGame
    if (-not $GameWin64) { throw "Phantom Blade Zero wasn't found in your Steam libraries. Run again with -GameWin64 '<Steam library>\steamapps\common\PBZ\platform\steam'." }
}

if (-not (Test-Path $GameWin64)) {
    throw "Folder not found: $GameWin64"
}

# UE4SS 3.x keeps mods in ue4ss\Mods; older releases put Mods next to the DLL.
$modsDir = @('ue4ss\Mods', 'Mods') |
    ForEach-Object { Join-Path $GameWin64 $_ } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if (-not $modsDir) {
    throw "No UE4SS Mods folder in $GameWin64. Install UE4SS for Phantom Blade Zero (Nexus Mods) there first."
}

$source = Join-Path $PSScriptRoot '..\mod\PBZCoop'
$target = Join-Path $modsDir 'PBZCoop'

# Copy over the top rather than deleting first, so runtime folders (inst2\ for the self-test, net files) survive.
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item (Join-Path $source '*') $target -Recurse -Force
# The relay lives in the mod folder; autostart.lua starts it from there (PhantomPact.ini, Role = Host/Guest).
New-Item -ItemType Directory -Force (Join-Path $target 'relay') | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..\net\pbzcoop_net.py'), (Join-Path $PSScriptRoot '..\net\steam_transport.py') (Join-Path $target 'relay') -Force
# This is the developer install (the tests send "eval" through cmd.txt): turn eval on. The release zip has no dev.txt.
Set-Content (Join-Path $target 'dev.txt') 'eval enabled for development (tools\install-mod.ps1)' -Encoding ascii

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
Write-Output "Start the game: the UE4SS console should show '[PBZCoop] Loaded (instance 1, ...)'. Then see INSTALL.md, 'Play'."
