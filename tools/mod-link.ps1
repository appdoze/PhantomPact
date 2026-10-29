<#
.SYNOPSIS
    Talks to the running PBZCoop mod: finds the game window, sends mod commands (cmd.txt) and reads the mod's lines
    from the UE4SS log. Dot-source it. This is all the player scripts need; game-driver.ps1 adds the test-only
    input and screenshot tools on top.

.EXAMPLE
    . .\tools\mod-link.ps1 -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam' -ProcessName 'PBZ'
    Send-ModCommand 'netstatus'
    Get-ModLog -Since (Get-Date).AddMinutes(-1)
#>
param(
    [Parameter(Mandatory = $true)][string]$GameWin64,
    [Parameter(Mandatory = $true)][string]$ProcessName
)

$script:GameWin64 = $GameWin64
$script:ProcessName = $ProcessName
$script:LogPath = Join-Path $GameWin64 'ue4ss\UE4SS.log'
$script:CmdPath = Join-Path $GameWin64 'ue4ss\Mods\PBZCoop\cmd.txt'

$script:TargetPid = 0

function Get-GameWindow {
    $procs = Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
    if ($script:TargetPid) { $procs = $procs | Where-Object { $_.Id -eq $script:TargetPid } }
    $p = $procs | Select-Object -First 1
    if (-not $p) { return [IntPtr]::Zero }
    return $p.MainWindowHandle
}

# Poll the mod with a "where" command until it reports player 1, i.e. gameplay is loaded.
function Wait-Gameplay {
    param([int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $t0 = Get-Date
        Send-ModCommand 'where'
        Start-Sleep -Seconds 3
        if (Get-ModLog -Since $t0 | Where-Object { $_ -match 'P1 at' }) { return $true }
    } until ((Get-Date) -gt $deadline)
    return $false
}

function Send-ModCommand {
    param([Parameter(Mandatory = $true)][string[]]$Command)
    [IO.File]::WriteAllText($script:CmdPath, ($Command -join "`n"))
}

function Get-ModLog {
    param([datetime]$Since = (Get-Date).AddMinutes(-2), [int]$Last = 200)
    if (-not (Test-Path $script:LogPath)) { return }
    $fs = [IO.File]::Open($script:LogPath, 'Open', 'Read', 'ReadWrite')
    $text = (New-Object IO.StreamReader $fs).ReadToEnd(); $fs.Dispose()
    $text -split "`r?`n" | Where-Object { $_ -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)' -and [datetime]$matches[1] -ge $Since.AddSeconds(-1) -and $_ -match 'PBZCoop|Lua.*error' } |
        Select-Object -Last $Last
}
