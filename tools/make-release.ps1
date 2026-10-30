<#
.SYNOPSIS
    Builds the player package dist\PhantomPact-<version>.zip, laid out like the game folder: players extract it into
    ...\steamapps\common\PBZ and it lands in platform\steam\ue4ss\Mods\PBZCoop. Settings are in PhantomPact.ini; the
    mod starts the relay itself (autostart.lua), the built-in one in dlls\main.dll. No .bat/.ps1 files, and no
    other binaries: Nexus quarantines scripts and quarantined a bundled Python for its .exe files (1.3.1).
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
# The PvP victory calligraphy (生还, painted in Lumina), loaded by pbz.lua at run time.
New-Item -ItemType Directory -Force (Join-Path $mod 'art') | Out-Null
Copy-Item (Join-Path $root 'mod\PBZCoop\art\*.png') (Join-Path $mod 'art')
Copy-Item (Join-Path $root 'net\pbzcoop_net.py'), (Join-Path $root 'net\steam_transport.py') (Join-Path $mod 'relay')

# The built-in relay. Built here so the zip can never carry an older one than the source.
& (Join-Path $PSScriptRoot 'build-native.ps1') | Out-Null
$dll = Join-Path $mod 'dlls\main.dll'
New-Item -ItemType Directory -Force (Split-Path $dll) | Out-Null
Copy-Item (Join-Path $root 'native\build\main.dll') $dll

$zip = "$stage.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) }
"Built $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"

# The checks Nexus runs on upload, done first: file types it quarantines on sight, then an antivirus scan
# (Windows Defender; Nexus also uses VirusTotal, which this can't replace). Read-only: nothing is removed.
$quarantined = '.exe', '.dll', '.bat', '.cmd', '.ps1', '.vbs', '.js', '.jar', '.msi', '.scr', '.com', '.zip', '.rar', '.7z'
$risky = Get-ChildItem $stage -Recurse -File | Where-Object { $quarantined -contains $_.Extension.ToLower() -and $_.FullName -ne $dll }
if ($risky) { throw "Nexus would quarantine this zip: $(($risky | ForEach-Object Name) -join ', ')" }
"File types OK for Nexus: $((Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.Extension.ToLower() } | Sort-Object -Unique) -join ' ')"
$defender = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
if (Test-Path $defender) {
    $scan = & $defender -Scan -ScanType 3 -File $zip -DisableRemediation 2>&1 | Out-String
    if ($scan -notmatch 'found no threats') { throw "Windows Defender flagged the zip:`n$scan" }
    "Windows Defender: no threats."
} else {
    Write-Warning "Windows Defender not found; scan the zip before uploading."
}
"SHA-256 (look it up on virustotal.com): $((Get-FileHash $zip -Algorithm SHA256).Hash)"
