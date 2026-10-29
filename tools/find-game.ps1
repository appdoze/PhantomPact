<#
.SYNOPSIS
    Find-PbzGame: the folder of Phantom Blade Zero's real game exe (...\steamapps\common\PBZ\platform\steam), found
    through Steam's library list, so players don't have to type their Steam library path. Dot-source this file.
#>
function Find-PbzGame([int]$SteamAppId = 4115450) {
    $steam = $null
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        $p = Get-ItemProperty $key -ErrorAction SilentlyContinue
        $steam = if ($p.SteamPath) { $p.SteamPath } elseif ($p.InstallPath) { $p.InstallPath } else { $null }
        if ($steam) { break }
    }
    $libraries = @()
    if ($steam) {
        $steam = $steam -replace '/', '\'
        $libraries += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            $libraries += [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
        }
    }
    # Common spots, in case Steam's registry entry is missing.
    $libraries += Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'SteamLibrary' }
    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $manifest = Join-Path $lib "steamapps\appmanifest_$SteamAppId.acf"
        if (-not (Test-Path $manifest)) { continue }
        $dir = [regex]::Match((Get-Content $manifest -Raw), '"installdir"\s+"([^"]+)"').Groups[1].Value
        $win64 = Join-Path $lib "steamapps\common\$dir\platform\steam"
        if (Test-Path (Join-Path $win64 'PBZ.exe')) { return $win64 }
    }
    return $null
}
