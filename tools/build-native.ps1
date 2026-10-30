<#
.SYNOPSIS
    Builds the C++ relay into native\build: main.dll (the mod ships it in PBZCoop\dlls) and relay_cli.exe (for
    net\test_pbzcoop_net.py only, never shipped). Needs Visual Studio 2022 with the C++ tools. Static runtime (/MT), so
    players need no Visual C++ redistributable.

.EXAMPLE
    .\tools\build-native.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'native'
$out = Join-Path $src 'build'
New-Item -ItemType Directory -Force $out | Out-Null

# Any Visual Studio with the C++ tools, as Windows' own locator lists it (Build Tools install under Program Files
# (x86), and 2026 is version 18); the fixed 2022 path is the fallback when vswhere isn't there.
$vcvars = $null
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vs) { $vcvars = Get-Item (Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat') -ErrorAction SilentlyContinue }
}
if (-not $vcvars) {
    $vcvars = Get-ChildItem "$env:ProgramFiles\Microsoft Visual Studio\2022\*\VC\Auxiliary\Build\vcvars64.bat" -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
if (-not $vcvars) { throw 'Visual Studio with the C++ tools was not found.' }
"Using $($vcvars.FullName)"

$flags = '/nologo /std:c++20 /O2 /MT /EHsc /W3 /utf-8 /D_WINSOCK_DEPRECATED_NO_WARNINGS'
$libs = 'ws2_32.lib bcrypt.lib winmm.lib'
$script = @"
@echo off
call "$($vcvars.FullName)" >nul 2>nul
cd /d "$out"
cl $flags /LD "$src\main_dll.cpp" "$src\steam.cpp" /Fe:main.dll /link /NOLOGO $libs || exit /b 1
cl $flags "$src\relay_cli.cpp" /Fe:relay_cli.exe /link /NOLOGO $libs || exit /b 1
"@
$bat = Join-Path $out 'build.bat'
Set-Content $bat $script -Encoding ascii
& cmd /c $bat
if ($LASTEXITCODE -ne 0) { throw "Build failed (exit code $LASTEXITCODE)." }
Get-Item (Join-Path $out 'main.dll'), (Join-Path $out 'relay_cli.exe') | ForEach-Object { "$($_.Name)  $([math]::Round($_.Length / 1KB)) KB" }
