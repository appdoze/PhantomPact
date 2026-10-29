<#
.SYNOPSIS
    Drives a running Unreal game for mod testing: focus the window, send keys, take screenshots,
    send PBZCoop commands and read the PBZCoop lines from the UE4SS log.

.EXAMPLE
    . .\tools\game-driver.ps1 -GameWin64 "D:\SteamLibrary\steamapps\common\BlackMythWukong\b1\Binaries\Win64" -ProcessName "b1-Win64-Shipping"
    Send-GameKey RETURN
    Save-GameScreenshot "C:\temp\shot.png"
    Send-ModCommand "info", "where"
    Get-ModLog -Since (Get-Date).AddMinutes(-1)
#>
param(
    [Parameter(Mandatory = $true)][string]$GameWin64,
    [Parameter(Mandatory = $true)][string]$ProcessName
)

if (-not ('GameDriver.Native' -as [type])) {
    Add-Type -Namespace GameDriver -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
'@
}
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
# Without this, window coordinates come back scaled on high-DPI screens and captures are misaligned.
[GameDriver.Native]::SetProcessDPIAware() | Out-Null

$script:GameWin64 = $GameWin64
$script:ProcessName = $ProcessName
$script:LogPath = Join-Path $GameWin64 'ue4ss\UE4SS.log'
$script:CmdPath = Join-Path $GameWin64 'ue4ss\Mods\PBZCoop\cmd.txt'

$script:TargetPid = 0

# Two copies on one PC: point the driver at one of them. Instance 1 uses the mod folder, N > 1 uses instN\.
function Select-GameInstance {
    param([Parameter(Mandatory = $true)][int]$ProcessId, [int]$Instance = 1)
    $script:TargetPid = $ProcessId
    $modDir = Join-Path $script:GameWin64 'ue4ss\Mods\PBZCoop'
    if ($Instance -gt 1) { $modDir = Join-Path $modDir "inst$Instance" }
    $script:CmdPath = Join-Path $modDir 'cmd.txt'
}

function Get-GameWindow {
    $procs = Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
    if ($script:TargetPid) { $procs = $procs | Where-Object { $_.Id -eq $script:TargetPid } }
    $p = $procs | Select-Object -First 1
    if (-not $p) { return [IntPtr]::Zero }
    return $p.MainWindowHandle
}

function Show-Game {
    $h = Get-GameWindow
    if ($h -eq [IntPtr]::Zero) { throw "Game window not found" }
    [GameDriver.Native]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
    # Windows only lets a foreground app hand over focus; a stray ALT press unlocks it.
    [GameDriver.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [GameDriver.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [GameDriver.Native]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 400
}

# Key names as in System.Windows.Forms.Keys (RETURN, ESCAPE, E, F8, UP, DOWN, ...).
function Send-GameKey {
    param([Parameter(Mandatory = $true)][string]$Key, [int]$HoldMs = 80, [int]$Times = 1)
    $vkName = @{ RETURN = 'Return'; ESC = 'Escape'; ESCAPE = 'Escape' }[$Key.ToUpper()]
    if (-not $vkName) { $vkName = $Key }
    $vk = [int][System.Windows.Forms.Keys]::$vkName
    $scan = [GameDriver.Native]::MapVirtualKey($vk, 0)
    for ($i = 0; $i -lt $Times; $i++) {
        [GameDriver.Native]::keybd_event([byte]$vk, [byte]$scan, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds $HoldMs
        [GameDriver.Native]::keybd_event([byte]$vk, [byte]$scan, 2, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 250
    }
}

# Left-click at a point given in screenshot pixels (as seen in a capture taken with the same -Scale).
function Invoke-GameClick {
    param([Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y, [double]$Scale = 1.0)
    $h = Get-GameWindow
    $r = New-Object GameDriver.Native+RECT
    if ($h -eq [IntPtr]::Zero -or -not [GameDriver.Native]::GetWindowRect($h, [ref]$r)) { throw "Game window not found" }
    [GameDriver.Native]::SetCursorPos($r.Left + [int]($X / $Scale), $r.Top + [int]($Y / $Scale)) | Out-Null
    Start-Sleep -Milliseconds 300
    [GameDriver.Native]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero)   # left down
    Start-Sleep -Milliseconds 80
    [GameDriver.Native]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)   # left up
    Start-Sleep -Milliseconds 300
}

function Save-GameScreenshot {
    param([Parameter(Mandatory = $true)][string]$Path, [double]$Scale = 0.5)
    $h = Get-GameWindow
    $r = New-Object GameDriver.Native+RECT
    if ($h -eq [IntPtr]::Zero -or -not [GameDriver.Native]::GetWindowRect($h, [ref]$r)) { throw "Game window not found" }
    $w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $hgt
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $out = New-Object System.Drawing.Bitmap $bmp, ([int]($w * $Scale)), ([int]($hgt * $Scale))
    $out.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose(); $out.Dispose()
    return $Path
}

# Kill the game, relaunch it through Steam and wait for its window.
function Restart-Game {
    param([Parameter(Mandatory = $true)][int]$SteamAppId, [int]$TimeoutSec = 120)
    Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 4
    Start-Process "steam://rungameid/$SteamAppId"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 3
    } until ((Get-GameWindow) -ne [IntPtr]::Zero -or (Get-Date) -gt $deadline)
    if ((Get-GameWindow) -eq [IntPtr]::Zero) { throw "Game window did not appear within $TimeoutSec s" }
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
