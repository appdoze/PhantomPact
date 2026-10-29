<#
.SYNOPSIS
    Builds the player package dist\PBZCoop-<version>.zip: the mod, the relay, the launcher and the installer,
    with INSTALL.md at the top. Runtime files the mod writes while playing (cmd.txt, net_*.txt, inst2\) are left out.

.EXAMPLE
    .\tools\make-release.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = [regex]::Match((Get-Content (Join-Path $root 'mod\PBZCoop\Scripts\main.lua') -Raw), 'local VERSION = "([^"]+)"').Groups[1].Value
if (-not $version) { throw "No VERSION in main.lua" }

$stage = Join-Path $root "dist\PhantomPact-$version"
if (Test-Path $stage) { throw "$stage already exists; bump VERSION in main.lua or move the old build away." }
New-Item -ItemType Directory -Force (Join-Path $stage 'mod\PBZCoop\Scripts'), (Join-Path $stage 'net'), (Join-Path $stage 'tools') | Out-Null

Copy-Item (Join-Path $root 'INSTALL.md') $stage
Copy-Item (Join-Path $root 'mod\PBZCoop\enabled.txt') (Join-Path $stage 'mod\PBZCoop')
Copy-Item (Join-Path $root 'mod\PBZCoop\Scripts\*.lua') (Join-Path $stage 'mod\PBZCoop\Scripts')
Copy-Item (Join-Path $root 'net\pbzcoop_net.py') (Join-Path $stage 'net')
foreach ($t in 'install-mod.ps1', 'pbz-coop.ps1', 'game-driver.ps1', 'pbz-selftest.ps1') { Copy-Item (Join-Path $PSScriptRoot $t) (Join-Path $stage 'tools') }

$zip = "$stage.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) }
"Built $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"
