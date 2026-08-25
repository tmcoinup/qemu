#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\VMateLab\vmspoofer-ui-audit.json',
    [string]$ScreenshotPath = 'C:\VMateLab\vmspoofer-ui.png'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class VMateWindowCaptureNative {
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
    public static extern bool PrintWindow(IntPtr window, IntPtr deviceContext,
        uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetMenu(IntPtr window);

    [DllImport("user32.dll")]
    public static extern int GetMenuItemCount(IntPtr menu);

    [DllImport("user32.dll")]
    public static extern uint GetMenuItemID(IntPtr menu, int position);

    [DllImport("user32.dll")]
    public static extern IntPtr GetSubMenu(IntPtr menu, int position);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetMenuString(IntPtr menu, uint item,
        StringBuilder text, int maximum, uint flags);
}
'@

function Get-VMateAutomationProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Element,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )
    try { return $Element.Current.$Name }
    catch { return $DefaultValue }
}

function Get-VMateMenuItems {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Menu,
        [int]$Depth = 0
    )
    $items = [Collections.Generic.List[object]]::new()
    $count = [VMateWindowCaptureNative]::GetMenuItemCount($Menu)
    for ($position = 0; $position -lt $count; ++$position) {
        $buffer = New-Object Text.StringBuilder 512
        [void][VMateWindowCaptureNative]::GetMenuString(
            $Menu, [uint32]$position, $buffer, $buffer.Capacity, 0x400)
        $submenu = [VMateWindowCaptureNative]::GetSubMenu($Menu, $position)
        $children = if ($submenu -eq [IntPtr]::Zero) { @() } else {
            @(Get-VMateMenuItems -Menu $submenu -Depth ($Depth + 1))
        }
        [void]$items.Add([pscustomobject][ordered]@{
                Position = $position
                Text = $buffer.ToString()
                CommandId = [uint32][VMateWindowCaptureNative]::GetMenuItemID(
                    $Menu, $position)
                HasSubmenu = $submenu -ne [IntPtr]::Zero
                Children = $children
            })
    }
    return @($items)
}

$processes = @(Get-Process -Name VMSpoofer -ErrorAction Stop)
if ($processes.Count -ne 1 -or $processes[0].MainWindowHandle -eq 0) {
    throw 'expected one VMSpoofer process with a main window.'
}
$process = $processes[0]
$handle = [IntPtr]$process.MainWindowHandle
$root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
if ($null -eq $root) { throw 'unable to resolve the manager UI root.' }
$menuHandle = [VMateWindowCaptureNative]::GetMenu($handle)
$menus = if ($menuHandle -eq [IntPtr]::Zero) { @() } else {
    @(Get-VMateMenuItems -Menu $menuHandle)
}

$elements = @($root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition))
$rows = [Collections.Generic.List[object]]::new()
foreach ($element in $elements) {
    $controlType = Get-VMateAutomationProperty $element 'ControlType' $null
    $typeName = if ($null -eq $controlType) { '' } else {
        [string]$controlType.ProgrammaticName
    }
    $name = if ($typeName -in @('ControlType.Edit', 'ControlType.Document')) {
        '<redacted-control>'
    }
    else { [string](Get-VMateAutomationProperty $element 'Name' '') }
    $patterns = try {
        @($element.GetSupportedPatterns() | ForEach-Object {
                [string]$_.ProgrammaticName
            })
    }
    catch { @() }
    [void]$rows.Add([pscustomobject][ordered]@{
            Name = $name
            AutomationId = [string](Get-VMateAutomationProperty `
                    $element 'AutomationId' '')
            ControlType = $typeName
            ClassName = [string](Get-VMateAutomationProperty `
                    $element 'ClassName' '')
            IsEnabled = [bool](Get-VMateAutomationProperty `
                    $element 'IsEnabled' $false)
            IsOffscreen = [bool](Get-VMateAutomationProperty `
                    $element 'IsOffscreen' $true)
            NativeWindowHandle = [int](Get-VMateAutomationProperty `
                    $element 'NativeWindowHandle' 0)
            Patterns = $patterns
        })
}

$rectangle = New-Object VMateWindowCaptureNative+RECT
$captured = $false
$captureError = ''
if ([VMateWindowCaptureNative]::GetWindowRect($handle, [ref]$rectangle)) {
    $width = $rectangle.Right - $rectangle.Left
    $height = $rectangle.Bottom - $rectangle.Top
    if ($width -gt 0 -and $height -gt 0) {
        $bitmap = New-Object Drawing.Bitmap $width, $height
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $deviceContext = $graphics.GetHdc()
        try {
            $captured = [VMateWindowCaptureNative]::PrintWindow(
                $handle, $deviceContext, 2)
        }
        catch { $captureError = $_.Exception.Message }
        finally {
            $graphics.ReleaseHdc($deviceContext)
            $graphics.Dispose()
        }
        if ($captured) { $bitmap.Save($ScreenshotPath) }
        $bitmap.Dispose()
    }
}

$document = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    ProcessId = [int]$process.Id
    SessionId = [int]$process.SessionId
    MainWindowTitle = [string]$process.MainWindowTitle
    MainWindowHandle = ('0x{0:X}' -f $handle.ToInt64())
    ScreenshotCaptured = $captured
    ScreenshotError = $captureError
    ScreenshotPath = if ($captured) { $ScreenshotPath } else { '' }
    WindowRectangle = [pscustomobject][ordered]@{
        Left = $rectangle.Left
        Top = $rectangle.Top
        Right = $rectangle.Right
        Bottom = $rectangle.Bottom
    }
    ControlCount = $rows.Count
    Controls = @($rows)
    Menus = $menus
}
[IO.File]::WriteAllText($OutputPath,
    ($document | ConvertTo-Json -Depth 8),
    (New-Object Text.UTF8Encoding($false)))
