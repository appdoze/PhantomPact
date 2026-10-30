<#
.SYNOPSIS
    Builds the player package dist\PhantomPact-<version>.zip, laid out like the game folder: players extract it into
    ...\steamapps\common\PBZ and it lands in platform\steam\ue4ss\Mods\PBZCoop. Settings are in PhantomPact.ini; the
    mod starts the relay itself (autostart.lua) with the bundled Python (PBZCoop\python). No .bat/.ps1 files: Nexus
    quarantines script files. It quarantined the bundled Python's .exe files too (1.3.1), so the Nexus upload is built
    with -NoPython: dist\PhantomPact-<version>-nexus.zip, for players with Python installed.
    Runtime files the mod writes while playing (cmd.txt, net_*.txt, inst2\) are left out.

.EXAMPLE
    .\tools\make-release.ps1
    .\tools\make-release.ps1 -NoPython
#>
param(
    [switch]$NoPython
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = [regex]::Match((Get-Content (Join-Path $root 'mod\PBZCoop\Scripts\main.lua') -Raw), 'local VERSION = "([^"]+)"').Groups[1].Value
if (-not $version) { throw "No VERSION in main.lua" }

$stage = Join-Path $root "dist\PhantomPact-$version$(if ($NoPython) { '-nexus' })"
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

if (-not $NoPython) {
    # Python's own embeddable build (python.org, signed by the PSF), so players don't install Python. Downloaded once
    # into dist\cache and pinned by hash. Its standard library comes as python314.zip; it's unpacked into Lib so the
    # release has no archive inside the archive.
    $pyVersion = '3.14.10'
    $pySha256 = '90905E64A840557D8C1BC4F5B74DB3D7EE85E3FFB217611CAC1C7813ACEA4159'
    $pyZip = Join-Path $root "dist\cache\python-$pyVersion-embed-amd64.zip"
    if (-not (Test-Path $pyZip)) {
        New-Item -ItemType Directory -Force (Split-Path $pyZip) | Out-Null
        Invoke-WebRequest "https://www.python.org/ftp/python/$pyVersion/python-$pyVersion-embed-amd64.zip" -OutFile $pyZip
    }
    if ((Get-FileHash $pyZip -Algorithm SHA256).Hash -ne $pySha256) { throw "$pyZip doesn't match the pinned SHA-256." }
    $py = Join-Path $mod 'python'
    Expand-Archive $pyZip $py
    $stdlib = Get-Item (Join-Path $py 'python3*.zip')
    Expand-Archive $stdlib.FullName (Join-Path $py 'Lib')
    Remove-Item $stdlib.FullName
    # The stdlib carries one macOS helper script (ctypes\macholib\fetch_macholib.bat); script files get quarantined.
    Get-ChildItem (Join-Path $py 'Lib') -Recurse -File -Include *.bat, *.cmd, *.ps1, *.vbs, *.js | Remove-Item
    $pth = Get-Item (Join-Path $py 'python3*._pth')
    Set-Content $pth.FullName "Lib`r`n." -Encoding ascii
}

$zip = "$stage.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) }
"Built $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"

# The checks Nexus runs on upload, done first: file types it quarantines on sight, then an antivirus scan
# (Windows Defender; Nexus also uses VirusTotal, which this can't replace). Read-only: nothing is removed.
$quarantined = '.exe', '.dll', '.bat', '.cmd', '.ps1', '.vbs', '.js', '.jar', '.msi', '.scr', '.com', '.zip', '.rar', '.7z'
$risky = Get-ChildItem $stage -Recurse -File | Where-Object { $quarantined -contains $_.Extension.ToLower() -and
    -not ($_.FullName.StartsWith("$py\") -and @('.exe', '.dll') -contains $_.Extension.ToLower()) }
if ($risky) { throw "Nexus would quarantine this zip: $(($risky | ForEach-Object Name) -join ', ')" }
if (-not $NoPython) {
    # Binaries are allowed only in the bundled Python, and only as shipped: signed by the PSF (or Microsoft's runtime).
    $unsigned = Get-ChildItem $py -Recurse -File -Include *.exe, *.dll, *.pyd | Get-AuthenticodeSignature |
        Where-Object { $_.Status -ne 'Valid' -or $_.SignerCertificate.Subject -notmatch 'CN=(Python Software Foundation|Microsoft)' }
    if ($unsigned) { throw "Unsigned binaries in the bundled Python: $(($unsigned | ForEach-Object { Split-Path $_.Path -Leaf }) -join ', ')" }
    $signedCount = @(Get-ChildItem $py -Recurse -File -Include *.exe, *.dll, *.pyd).Count
    if ($signedCount -eq 0) { throw "The bundled Python has no binaries." }
    "Bundled Python $pyVersion`: $signedCount binaries, all signed."
}
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
