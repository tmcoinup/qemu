#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\VMateLab\vmspoofer-popup-audit.json',
    [string]$ScreenshotPath = 'C:\VMateLab\vmspoofer-popup.png',
    [ValidateRange(0, 32767)][int]$TargetClientX = 150,
    [ValidateRange(0, 32767)][int]$TargetClientY = 134
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class VMatePopupAuditNative {
    public delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out RECT rectangle);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr window, uint message,
        IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window,
        out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr window, StringBuilder value,
        int maximum);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr window, StringBuilder value,
        int maximum);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsCallback callback,
        IntPtr parameter);

    public static IntPtr[] GetTopLevelWindows() {
        List<IntPtr> windows = new List<IntPtr>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            windows.Add(window);
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
'@

function Get-VMateWindowMetadata {
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)

    $processId = [uint32]0
    $threadId = [VMatePopupAuditNative]::GetWindowThreadProcessId(
        $Handle, [ref]$processId)
    $className = New-Object Text.StringBuilder 256
    $title = New-Object Text.StringBuilder 512
    [void][VMatePopupAuditNative]::GetClassName(
        $Handle, $className, $className.Capacity)
    [void][VMatePopupAuditNative]::GetWindowText(
        $Handle, $title, $title.Capacity)
    $rectangle = New-Object VMatePopupAuditNative+RECT
    $hasRectangle = [VMatePopupAuditNative]::GetWindowRect(
        $Handle, [ref]$rectangle)
    [pscustomobject][ordered]@{
        Handle = ('0x{0:X}' -f $Handle.ToInt64())
        ProcessId = [int]$processId
        ThreadId = [int]$threadId
        ClassName = $className.ToString()
        Title = $title.ToString()
        Visible = [VMatePopupAuditNative]::IsWindowVisible($Handle)
        Rectangle = if ($hasRectangle) {
            [pscustomobject][ordered]@{
                Left = $rectangle.Left
                Top = $rectangle.Top
                Right = $rectangle.Right
                Bottom = $rectangle.Bottom
            }
        }
        else { $null }
    }
}

function Get-VMateRelevantWindows {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $rows = [Collections.Generic.List[object]]::new()
    foreach ($window in [VMatePopupAuditNative]::GetTopLevelWindows()) {
        $metadata = Get-VMateWindowMetadata -Handle $window
        if ($metadata.ProcessId -eq $ProcessId -or
            $metadata.ClassName -eq '#32768') {
            [void]$rows.Add($metadata)
        }
    }
    return @($rows)
}

$processes = @(Get-Process -Name VMSpoofer -ErrorAction Stop)
if ($processes.Count -ne 1 -or $processes[0].MainWindowHandle -eq 0) {
    throw 'expected one VMSpoofer process with a main window.'
}
$process = $processes[0]
$handle = [IntPtr]$process.MainWindowHandle
$rectangle = New-Object VMatePopupAuditNative+RECT
if (-not [VMatePopupAuditNative]::GetWindowRect($handle, [ref]$rectangle)) {
    throw 'unable to resolve the VMSpoofer window rectangle.'
}

$beforeForeground = [VMatePopupAuditNative]::GetForegroundWindow()
$beforeWindows = @(Get-VMateRelevantWindows -ProcessId $process.Id)
[void][VMatePopupAuditNative]::SetForegroundWindow($handle)
Start-Sleep -Milliseconds 150

# WM_RBUTTONDOWN/WM_RBUTTONUP are posted directly to the manager. This does not
# move the physical pointer and cannot be delivered to a VM console window.
$packedPoint = (($TargetClientY -band 0xffff) -shl 16) -bor
    ($TargetClientX -band 0xffff)
$rightButton = [IntPtr]2
if (-not [VMatePopupAuditNative]::PostMessage(
        $handle, 0x0204, $rightButton, [IntPtr]$packedPoint)) {
    throw 'failed to post WM_RBUTTONDOWN to VMSpoofer.'
}
if (-not [VMatePopupAuditNative]::PostMessage(
        $handle, 0x0205, [IntPtr]::Zero, [IntPtr]$packedPoint)) {
    throw 'failed to post WM_RBUTTONUP to VMSpoofer.'
}
Start-Sleep -Milliseconds 750

$popupForeground = [VMatePopupAuditNative]::GetForegroundWindow()
$popupWindows = @(Get-VMateRelevantWindows -ProcessId $process.Id)
$screen = [Windows.Forms.SystemInformation]::VirtualScreen
$left = [Math]::Max($screen.Left, $rectangle.Left - 48)
$top = [Math]::Max($screen.Top, $rectangle.Top - 48)
$right = [Math]::Min($screen.Right, $rectangle.Right + 320)
$bottom = [Math]::Min($screen.Bottom, $rectangle.Bottom + 160)
$width = $right - $left
$height = $bottom - $top
$captured = $false
if ($width -gt 0 -and $height -gt 0) {
    $bitmap = New-Object Drawing.Bitmap $width, $height
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($left, $top, 0, 0,
            (New-Object Drawing.Size $width, $height))
        $bitmap.Save($ScreenshotPath)
        $captured = $true
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$popupMetadata = if ($popupForeground -eq [IntPtr]::Zero) { $null } else {
    Get-VMateWindowMetadata -Handle $popupForeground
}
# Only dismiss the popup when the foreground still belongs to the sample
# manager (or is a standard menu window). No global keyboard input is used.
if ($null -ne $popupMetadata -and
    ($popupMetadata.ProcessId -eq $process.Id -or
        $popupMetadata.ClassName -eq '#32768')) {
    [void][VMatePopupAuditNative]::PostMessage(
        $popupForeground, 0x0100, [IntPtr]0x1B, [IntPtr]::Zero)
    [void][VMatePopupAuditNative]::PostMessage(
        $popupForeground, 0x0101, [IntPtr]0x1B, [IntPtr]::Zero)
}
[void][VMatePopupAuditNative]::PostMessage(
    $handle, 0x001F, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 300

$afterForeground = [VMatePopupAuditNative]::GetForegroundWindow()
$document = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    ProcessId = [int]$process.Id
    MainWindowHandle = ('0x{0:X}' -f $handle.ToInt64())
    TargetClientPoint = [pscustomobject][ordered]@{
        X = $TargetClientX
        Y = $TargetClientY
    }
    BeforeForeground = ('0x{0:X}' -f $beforeForeground.ToInt64())
    PopupForeground = ('0x{0:X}' -f $popupForeground.ToInt64())
    AfterForeground = ('0x{0:X}' -f $afterForeground.ToInt64())
    PopupForegroundMetadata = $popupMetadata
    BeforeWindows = $beforeWindows
    PopupWindows = $popupWindows
    ScreenshotCaptured = $captured
    ScreenshotPath = if ($captured) { $ScreenshotPath } else { '' }
    CaptureRectangle = [pscustomobject][ordered]@{
        Left = $left
        Top = $top
        Right = $right
        Bottom = $bottom
    }
}
[IO.File]::WriteAllText($OutputPath,
    ($document | ConvertTo-Json -Depth 8),
    (New-Object Text.UTF8Encoding($false)))
