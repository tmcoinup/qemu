#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\VMateLab\vmspoofer-modify-audit.json',
    [string]$ScreenshotPath = 'C:\VMateLab\vmspoofer-modify.png',
    [ValidateRange(0, 32767)][int]$TargetClientX = 150,
    [ValidateRange(0, 32767)][int]$TargetClientY = 134,
    [ValidateRange(5, 60)][int]$PreparationTimeoutSeconds = 30
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

public static class VMateModifyAuditNative {
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
    $threadId = [VMateModifyAuditNative]::GetWindowThreadProcessId(
        $Handle, [ref]$processId)
    $className = New-Object Text.StringBuilder 256
    $title = New-Object Text.StringBuilder 512
    [void][VMateModifyAuditNative]::GetClassName(
        $Handle, $className, $className.Capacity)
    [void][VMateModifyAuditNative]::GetWindowText(
        $Handle, $title, $title.Capacity)
    $rectangle = New-Object VMateModifyAuditNative+RECT
    $hasRectangle = [VMateModifyAuditNative]::GetWindowRect(
        $Handle, [ref]$rectangle)
    [pscustomobject][ordered]@{
        HandleValue = $Handle.ToInt64()
        Handle = ('0x{0:X}' -f $Handle.ToInt64())
        ProcessId = [int]$processId
        ThreadId = [int]$threadId
        ClassName = $className.ToString()
        Title = $title.ToString()
        Visible = [VMateModifyAuditNative]::IsWindowVisible($Handle)
        Rectangle = if ($hasRectangle) {
            [pscustomobject][ordered]@{
                Left = $rectangle.Left
                Top = $rectangle.Top
                Right = $rectangle.Right
                Bottom = $rectangle.Bottom
                Width = $rectangle.Right - $rectangle.Left
                Height = $rectangle.Bottom - $rectangle.Top
            }
        }
        else { $null }
    }
}

function Get-VMateProcessWindows {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $rows = [Collections.Generic.List[object]]::new()
    foreach ($window in [VMateModifyAuditNative]::GetTopLevelWindows()) {
        $metadata = Get-VMateWindowMetadata -Handle $window
        if ($metadata.ProcessId -eq $ProcessId) {
            [void]$rows.Add($metadata)
        }
    }
    return @($rows)
}

function Send-VMateMouseClick {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Handle,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][ValidateSet('Left', 'Right')]
        [string]$Button
    )

    $packedPoint = (($Y -band 0xffff) -shl 16) -bor ($X -band 0xffff)
    if ($Button -eq 'Right') {
        $downMessage = 0x0204
        $upMessage = 0x0205
        $buttonFlag = [IntPtr]2
    }
    else {
        $downMessage = 0x0201
        $upMessage = 0x0202
        $buttonFlag = [IntPtr]1
    }
    if (-not [VMateModifyAuditNative]::PostMessage(
            $Handle, $downMessage, $buttonFlag, [IntPtr]$packedPoint)) {
        throw "failed to post $Button button-down."
    }
    if (-not [VMateModifyAuditNative]::PostMessage(
            $Handle, $upMessage, [IntPtr]::Zero, [IntPtr]$packedPoint)) {
        throw "failed to post $Button button-up."
    }
}

$processes = @(Get-Process -Name VMSpoofer -ErrorAction Stop)
if ($processes.Count -ne 1 -or $processes[0].MainWindowHandle -eq 0) {
    throw 'expected one VMSpoofer process with a main window.'
}
$process = $processes[0]
$mainHandle = [IntPtr]$process.MainWindowHandle
$beforeWindows = @(Get-VMateProcessWindows -ProcessId $process.Id)
[void][VMateModifyAuditNative]::SetForegroundWindow($mainHandle)
Start-Sleep -Milliseconds 150
Send-VMateMouseClick -Handle $mainHandle -X $TargetClientX `
    -Y $TargetClientY -Button Right
Start-Sleep -Milliseconds 500

$menuWindows = @(Get-VMateProcessWindows -ProcessId $process.Id)
$menu = @($menuWindows | Where-Object {
        $_.Visible -and $_.HandleValue -ne $mainHandle.ToInt64() -and
        $_.ClassName -eq 'FLTK' -and $_.Title -eq '' -and
        $_.Rectangle.Width -eq 95 -and $_.Rectangle.Height -eq 276
    })
if ($menu.Count -ne 1) {
    [void][VMateModifyAuditNative]::PostMessage(
        $mainHandle, 0x001F, [IntPtr]::Zero, [IntPtr]::Zero)
    throw "expected one 95x276 VMSpoofer context menu; found $($menu.Count)."
}
$menuHandle = [IntPtr][int64]$menu[0].HandleValue

# In the validated 95x276 offline context menu, the center of the
# 'Modify virtual machine' row is (47, 119). The menu dimensions above are a
# hard guard against selecting an item from a different layout.
Send-VMateMouseClick -Handle $menuHandle -X 47 -Y 119 -Button Left
$observations = [Collections.Generic.List[object]]::new()
$preparationSeen = $false
$configurationReached = $false
$deadline = [DateTime]::UtcNow.AddSeconds($PreparationTimeoutSeconds)
$dialogWindows = @()
$dialog = @()
do {
    Start-Sleep -Milliseconds 500
    $dialogWindows = @(Get-VMateProcessWindows -ProcessId $process.Id)
    $visibleAuxiliary = @($dialogWindows | Where-Object {
            $_.Visible -and $_.HandleValue -ne $mainHandle.ToInt64() -and
            $_.HandleValue -ne $menuHandle.ToInt64()
        })
    [void]$observations.Add([pscustomobject][ordered]@{
            AtUtc = [DateTime]::UtcNow.ToString('o')
            Windows = $visibleAuxiliary
        })
    $configuration = @($visibleAuxiliary | Where-Object {
            -not ($_.Rectangle.Width -eq 316 -and
                $_.Rectangle.Height -eq 139)
        } | Sort-Object { $_.Rectangle.Width * $_.Rectangle.Height } `
        -Descending | Select-Object -First 1)
    if ($configuration.Count -eq 1) {
        $dialog = $configuration
        $configurationReached = $true
        break
    }
    if (@($visibleAuxiliary | Where-Object {
                $_.Rectangle.Width -eq 316 -and
                $_.Rectangle.Height -eq 139
            }).Count -gt 0) {
        $preparationSeen = $true
    }
} while ([DateTime]::UtcNow -lt $deadline)

if ($dialog.Count -eq 0) {
    $dialog = @($dialogWindows | Where-Object {
            $_.Visible -and $_.HandleValue -ne $mainHandle.ToInt64() -and
            $_.HandleValue -ne $menuHandle.ToInt64()
        } | Sort-Object { $_.Rectangle.Width * $_.Rectangle.Height } `
        -Descending | Select-Object -First 1)
}

$mainRectangle = New-Object VMateModifyAuditNative+RECT
if (-not [VMateModifyAuditNative]::GetWindowRect(
        $mainHandle, [ref]$mainRectangle)) {
    throw 'unable to resolve the manager rectangle.'
}
$screen = [Windows.Forms.SystemInformation]::VirtualScreen
$left = [Math]::Max($screen.Left, $mainRectangle.Left - 48)
$top = [Math]::Max($screen.Top, $mainRectangle.Top - 48)
$right = [Math]::Min($screen.Right, $mainRectangle.Right + 320)
$bottom = [Math]::Min($screen.Bottom, $mainRectangle.Bottom + 160)
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

# Dismiss only the newly opened VMSpoofer dialog. Input is posted directly to
# its window handle, never globally and never to a VM console.
$dismissedHandle = [IntPtr]::Zero
if ($dialog.Count -eq 1) {
    $dismissedHandle = [IntPtr][int64]$dialog[0].HandleValue
    [void][VMateModifyAuditNative]::PostMessage(
        $dismissedHandle, 0x0100, [IntPtr]0x1B, [IntPtr]::Zero)
    [void][VMateModifyAuditNative]::PostMessage(
        $dismissedHandle, 0x0101, [IntPtr]0x1B, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    $stillVisible = @((Get-VMateProcessWindows -ProcessId $process.Id) |
        Where-Object {
            $_.Visible -and $_.HandleValue -eq $dismissedHandle.ToInt64()
        }).Count -gt 0
    if ($stillVisible) {
        [void][VMateModifyAuditNative]::PostMessage(
            $dismissedHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 300
    }
}
else {
    [void][VMateModifyAuditNative]::PostMessage(
        $mainHandle, 0x001F, [IntPtr]::Zero, [IntPtr]::Zero)
}

$afterWindows = @(Get-VMateProcessWindows -ProcessId $process.Id)
$document = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    ProcessId = [int]$process.Id
    MainWindowHandle = ('0x{0:X}' -f $mainHandle.ToInt64())
    Menu = $menu[0]
    Dialog = if ($dialog.Count -eq 1) { $dialog[0] } else { $null }
    DialogCount = $dialog.Count
    PreparationSeen = $preparationSeen
    ConfigurationReached = $configurationReached
    PreparationTimeoutSeconds = $PreparationTimeoutSeconds
    Observations = @($observations)
    DismissedHandle = ('0x{0:X}' -f $dismissedHandle.ToInt64())
    BeforeWindows = $beforeWindows
    DialogWindows = $dialogWindows
    AfterWindows = $afterWindows
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
