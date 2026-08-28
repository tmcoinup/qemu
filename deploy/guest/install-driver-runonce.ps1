<#
.SYNOPSIS
  在 guest 的活动用户会话中安装生产签名 GRID 538.33，并保护 R535 本地 console。

  pypsrp 在 SYSTEM session (session 0) 跑 setup.exe -s -clean 不可靠，因此默认
  入口只设置一次 AutoLogon + RunOnce。RunOnce 再以 -RunInstaller 回调本脚本：
    1. 安装前把活动显示切到 1920x1080；
    2. setup.exe 运行期间监控分辨率，阻止旧缓存恢复 1680x1050；
    3. 安装后再次确认 1920x1080，并写结构化完成收据。

  R535 会把 32-bpp scanout pitch 对齐到 128 字节，再把整帧消息补到 4 KiB。
  若 pitch*height 不是 4-KiB 整数倍，nvidia-vgpu-mgr 会拒绝 head delivery，QEMU
  收到全零 REGION。这里使用 Windows 自带的 user32 API；不安装额外驱动、不改
  BCD，也不修改 NVIDIA INF/CAT/SYS。

.PARAMETER InstallerPath
  guest 内 setup.exe 路径，默认 C:\nv\553.24.exe（历史文件名，内容是 538.33）。

.PARAMETER FlagPath
  安装结果收据，默认 C:\nv\drv-done.flag。

.PARAMETER RunInstaller
  仅供 RunOnce 回调；在当前活动桌面安装并监控显示模式。
#>
param(
    [string]$InstallerPath = 'C:\nv\553.24.exe',
    [string]$FlagPath      = 'C:\nv\drv-done.flag',
    [string]$AdminUser     = 'Administrator',
    [string]$AdminPass     = '123456',
    [switch]$RunInstaller
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

function Initialize-G11DisplayApi {
    if ('G11.SafeDisplay.NativeMethods' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace G11.SafeDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public UInt16 dmSpecVersion;
        public UInt16 dmDriverVersion;
        public UInt16 dmSize;
        public UInt16 dmDriverExtra;
        public UInt32 dmFields;
        public Int32 dmPositionX;
        public Int32 dmPositionY;
        public UInt32 dmDisplayOrientation;
        public UInt32 dmDisplayFixedOutput;
        public Int16 dmColor;
        public Int16 dmDuplex;
        public Int16 dmYResolution;
        public Int16 dmTTOption;
        public Int16 dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public UInt16 dmLogPixels;
        public UInt32 dmBitsPerPel;
        public UInt32 dmPelsWidth;
        public UInt32 dmPelsHeight;
        public UInt32 dmDisplayFlags;
        public UInt32 dmDisplayFrequency;
        public UInt32 dmICMMethod;
        public UInt32 dmICMIntent;
        public UInt32 dmMediaType;
        public UInt32 dmDitherType;
        public UInt32 dmReserved1;
        public UInt32 dmReserved2;
        public UInt32 dmPanningWidth;
        public UInt32 dmPanningHeight;
    }

    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool EnumDisplaySettings(
            string deviceName, int modeNum, ref DEVMODE devMode);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int ChangeDisplaySettingsEx(
            string deviceName, ref DEVMODE devMode, IntPtr hwnd,
            UInt32 flags, IntPtr lParam);
    }
}
'@
}

function Get-R535ConsoleFrameBytes {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )

    if ($Width -le 0 -or $Height -le 0) { return [int64]0 }
    [int64]$rowBytes = [int64]$Width * 4
    [int64]$pitch = [int64]([Math]::Ceiling($rowBytes / 128.0) * 128)
    return [int64]($pitch * $Height)
}

function Get-CurrentDisplayMode {
    Initialize-G11DisplayApi
    $mode = New-Object G11.SafeDisplay.DEVMODE
    $mode.dmSize = [Runtime.InteropServices.Marshal]::SizeOf(
        [type][G11.SafeDisplay.DEVMODE])
    $ok = [G11.SafeDisplay.NativeMethods]::EnumDisplaySettings(
        $null, -1, [ref]$mode)
    if (-not $ok) {
        return [pscustomobject]@{
            Valid = $false; Width = 0; Height = 0; Bits = 0; Frequency = 0
            FrameBytes = [int64]0; PageSafe = $false
        }
    }
    $frameBytes = Get-R535ConsoleFrameBytes `
        -Width ([int]$mode.dmPelsWidth) -Height ([int]$mode.dmPelsHeight)
    return [pscustomobject]@{
        Valid = $true
        Width = [int]$mode.dmPelsWidth
        Height = [int]$mode.dmPelsHeight
        Bits = [int]$mode.dmBitsPerPel
        Frequency = [int]$mode.dmDisplayFrequency
        FrameBytes = [int64]$frameBytes
        PageSafe = (($frameBytes % 4096) -eq 0)
    }
}

function Set-SafeFhdDisplayMode {
    Initialize-G11DisplayApi
    $mode = New-Object G11.SafeDisplay.DEVMODE
    $mode.dmSize = [Runtime.InteropServices.Marshal]::SizeOf(
        [type][G11.SafeDisplay.DEVMODE])
    if (-not [G11.SafeDisplay.NativeMethods]::EnumDisplaySettings(
            $null, -1, [ref]$mode)) {
        return -1
    }
    $mode.dmPelsWidth = 1920
    $mode.dmPelsHeight = 1080
    # DM_PELSWIDTH | DM_PELSHEIGHT.  Preserve the adapter's current refresh
    # and color depth instead of inventing an unsupported timing.
    $mode.dmFields = 0x00080000 -bor 0x00100000
    return [G11.SafeDisplay.NativeMethods]::ChangeDisplaySettingsEx(
        $null, [ref]$mode, [IntPtr]::Zero, 0x00000001, [IntPtr]::Zero)
}

function Wait-SafeFhdDisplayMode {
    param([int]$TimeoutSeconds = 30)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $mode = Get-CurrentDisplayMode
        if ($mode.Valid -and $mode.Width -eq 1920 -and
            $mode.Height -eq 1080 -and $mode.PageSafe) {
            return $mode
        }
        $result = Set-SafeFhdDisplayMode
        Write-Host ("  display guard: requested 1920x1080, user32 rc={0}" -f $result)
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    return Get-CurrentDisplayMode
}

function Format-DisplayMode {
    param([Parameter(Mandatory = $true)]$Mode)

    if (-not $Mode.Valid) { return 'unavailable' }
    return ("{0}x{1}@{2} {3}bpp frame=0x{4:X} page_safe={5}" -f
        $Mode.Width, $Mode.Height, $Mode.Frequency, $Mode.Bits,
        $Mode.FrameBytes, [int]$Mode.PageSafe)
}

if ($RunInstaller) {
    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "GRID installer not found: $InstallerPath"
    }
    $flagDirectory = Split-Path -Parent $FlagPath
    if ($flagDirectory) {
        New-Item -Path $flagDirectory -ItemType Directory -Force | Out-Null
    }
    Remove-Item -LiteralPath $FlagPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$FlagPath.tmp" -Force -ErrorAction SilentlyContinue

    Write-Host '[display-guard] pre-install 1920x1080 convergence' -Fore Cyan
    $preMode = Wait-SafeFhdDisplayMode -TimeoutSeconds 15
    Write-Host ("  before setup: " + (Format-DisplayMode $preMode))

    Write-Host '[driver] GRID 538.33 setup.exe in active desktop session' -Fore Cyan
    $process = Start-Process -FilePath $InstallerPath -ArgumentList @(
        '-s', '-clean', '-noreboot', '-noeula', '-noprogressbar'
    ) -PassThru
    $lastUnsafe = ''
    while (-not $process.WaitForExit(1000)) {
        $current = Get-CurrentDisplayMode
        $description = Format-DisplayMode $current
        if (-not $current.Valid -or $current.Width -ne 1920 -or
            $current.Height -ne 1080 -or -not $current.PageSafe) {
            if ($description -ne $lastUnsafe) {
                Write-Warning "setup changed/invalidated display mode: $description"
                $lastUnsafe = $description
            }
            [void](Set-SafeFhdDisplayMode)
        }
    }
    $installerExit = $process.ExitCode

    Write-Host '[display-guard] post-install 1920x1080 convergence' -Fore Cyan
    $finalMode = Wait-SafeFhdDisplayMode -TimeoutSeconds 60
    $displaySafe = ($finalMode.Valid -and $finalMode.Width -eq 1920 -and
        $finalMode.Height -eq 1080 -and $finalMode.PageSafe)
    Write-Host ("  after setup:  " + (Format-DisplayMode $finalMode))

    $receipt = [string[]]@(
        "installer=$installerExit",
        ("display={0}x{1}" -f $finalMode.Width, $finalMode.Height),
        ("console_bytes={0}" -f $finalMode.FrameBytes),
        ("console_safe={0}" -f [int]$displaySafe)
    )
    $receiptTemp = "$FlagPath.tmp"
    [IO.File]::WriteAllLines($receiptTemp, $receipt, [Text.Encoding]::ASCII)
    Move-Item -LiteralPath $receiptTemp -Destination $FlagPath -Force

    if (-not $displaySafe) {
        Write-Error ('GRID install completed but the R535 console could not ' +
            'converge to page-safe 1920x1080; leaving Windows running for recovery')
        exit 20
    }

    Write-Host "installer exit code: $installerExit; rebooting in 5s" -Fore Yellow
    Start-Sleep -Seconds 5
    shutdown /r /t 0 /f
    exit 0
}

Write-Host '[1/3] AutoAdminLogon -> Administrator (一次性)' -Fore Cyan
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $wl -Name 'AutoAdminLogon'  -Value '1'         -Type String
Set-ItemProperty -Path $wl -Name 'DefaultUserName' -Value $AdminUser -Type String
Set-ItemProperty -Path $wl -Name 'DefaultPassword' -Value $AdminPass -Type String
Set-ItemProperty -Path $wl -Name 'AutoLogonCount'  -Value 1           -Type DWord

Write-Host '[2/3] RunOnce: guarded GRID setup + structured receipt' -Fore Cyan
$ro = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$scriptPath = $MyInvocation.MyCommand.Path
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" " +
    "-RunInstaller -InstallerPath `"$InstallerPath`" -FlagPath `"$FlagPath`""
Set-ItemProperty -Path $ro -Name '!NvDriverInstall' -Value $cmd -Type String
# `!` makes Windows delete the RunOnce value only after this command returns.

Write-Host '[3/3] Trigger reboot' -Fore Cyan
"  RunOnce command armed (installer path only; no credential in command line)"
"  reboot in 5s..."
Start-Sleep -Seconds 5
shutdown /r /t 0 /f
