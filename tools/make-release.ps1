<#
.SYNOPSIS
    Builds the player package dist\PhantomPact-<version>.zip, laid out like the game folder: players extract it into
    ...\steamapps\common\PBZ and it lands in platform\steam\ue4ss\Mods\PBZCoop. Settings are in PhantomPact.ini; the
    mod starts the relay itself (autostart.lua). No .bat/.ps1 files: Nexus quarantines script files.
    Runtime files the mod writes while playing (cmd.txt, net_*.txt, inst2\) are left out.

.EXAMPLE
    .\tools\make-release.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = [regex]::Match((Get-Content (Join-Path $root 'mod\PBZCoop\Scripts\main.lua') -Raw), 'local VERSION = "([^"]+)"').Groups[1].Value
if (-not $version) { throw "No VERSION in main.lua" }

$stage = Join-Path $root "dist\PhantomPact-$version"
if (Test-Path $stage) { throw "$stage already exists; bump VERSION in main.lua or move the old build away." }
$mod = Join-Path $stage 'platform\steam\ue4ss\Mods\PBZCoop'
New-Item -ItemType Directory -Force (Join-Path $mod 'Scripts'), (Join-Path $mod 'relay') | Out-Null

Copy-Item (Join-Path $root 'INSTALL.md') (Join-Path $stage 'Phantom Pact - INSTALL.md')
foreach ($f in 'enabled.txt', 'PhantomPact.ini') { Copy-Item (Join-Path $root "mod\PBZCoop\$f") $mod }
Copy-Item (Join-Path $root 'mod\PBZCoop\Scripts\*.lua') (Join-Path $mod 'Scripts')
Copy-Item (Join-Path $root 'net\pbzcoop_net.py') (Join-Path $mod 'relay')

$zip = "$stage.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) }
"Built $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"
