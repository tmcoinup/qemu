<#
.SYNOPSIS
  在 guest 的活动用户会话中安装与宿主分支匹配的生产签名 GRID 驱动。

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
  guest 内已通过精确 SHA-256 与 Authenticode 验证的 setup.exe 路径。

.PARAMETER FlagPath
  安装结果收据，默认 C:\nv\drv-done.flag。

.PARAMETER RunInstaller
  仅供 RunOnce 回调；在当前活动桌面安装并监控显示模式。

.PARAMETER ConsoleGuardPolicy
  Required 用于 SDL/GTK 安装窗口，必须实时收敛 1920x1080；Offline 只允许
  host 已从 QEMU /proc 证明 `-display none` 且 NVIDIA mdev `display=off` 的
  headless 安装。后者不冒充在线 console 验收，必须由 host 完整关机后离线同步。
#>
param(
    [string]$InstallerPath = 'C:\nv\g11-grid-driver.exe',
    [string]$FlagPath      = 'C:\nv\drv-done.flag',
    [string]$AdminUser     = 'Administrator',
    [string]$AdminPass     = '',
    [ValidateSet('R535', 'R570', 'R580')]
    [string]$DriverBranch  = 'R535',
    [string]$ExpectedInstallerSha256 = '',
    [string]$ExpectedSourcePackageSha256 = '',
    [string]$PayloadArchivePath = '',
    [string]$ExpectedPayloadSha256 = '',
    [string]$ExpectedDriverVersion = '',
    [ValidateSet('Required', 'Offline')]
    [string]$ConsoleGuardPolicy = 'Required',
    [switch]$RunInstaller
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$stagePath = 'C:\nv\drv-stage.flag'
if ($RunInstaller) {
    New-Item -Path (Split-Path -Parent $stagePath) -ItemType Directory -Force |
        Out-Null
    [IO.File]::AppendAllText($stagePath,
        "stage=powershell-entered`r`nbranch=$DriverBranch`r`n",
        [Text.Encoding]::ASCII)
}

if ($ExpectedInstallerSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
    throw 'ExpectedInstallerSha256 must be exactly 64 hexadecimal characters'
}
if ($ExpectedSourcePackageSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
    throw 'ExpectedSourcePackageSha256 must be exactly 64 hexadecimal characters'
}
if ($DriverBranch -eq 'R580') {
    if ($ExpectedPayloadSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'ExpectedPayloadSha256 must be supplied for R580'
    }
    if (-not (Test-Path -LiteralPath $PayloadArchivePath -PathType Leaf)) {
        throw "R580 payload archive not found: $PayloadArchivePath"
    }
}
if ($ExpectedDriverVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw 'ExpectedDriverVersion is invalid'
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
    $packageSha256 = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($packageSha256 -cne $ExpectedInstallerSha256.ToUpperInvariant()) {
        throw "GRID installer SHA-256 mismatch: $packageSha256"
    }
    [IO.File]::AppendAllText($stagePath,
        "stage=installer-hash-verified`r`n",
        [Text.Encoding]::ASCII)
    $payloadSha256 = 'none'
    if ($DriverBranch -eq 'R580') {
        $payloadSha256 = (Get-FileHash -LiteralPath $PayloadArchivePath `
            -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($payloadSha256 -cne $ExpectedPayloadSha256.ToUpperInvariant()) {
            throw "R580 payload archive SHA-256 mismatch: $payloadSha256"
        }
        [IO.File]::AppendAllText($stagePath,
            "stage=payload-hash-verified`r`n",
            [Text.Encoding]::ASCII)
    }
    $packageSignature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
    if ($packageSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
            $null -eq $packageSignature.SignerCertificate -or
            $packageSignature.SignerCertificate.Subject -notmatch 'NVIDIA Corporation') {
        throw ("GRID installer production signature is not valid: status={0} signer={1}" -f
            $packageSignature.Status,
            $packageSignature.SignerCertificate.Subject)
    }
    $flagDirectory = Split-Path -Parent $FlagPath
    if ($flagDirectory) {
        New-Item -Path $flagDirectory -ItemType Directory -Force | Out-Null
    }
    Remove-Item -LiteralPath $FlagPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$FlagPath.tmp" -Force -ErrorAction SilentlyContinue
    [IO.File]::AppendAllText($stagePath,
        "stage=signature-verified`r`nbranch=$DriverBranch`r`n",
        [Text.Encoding]::ASCII)

    if ($DriverBranch -eq 'R535' -and $ConsoleGuardPolicy -eq 'Required') {
        Write-Host '[display-guard] pre-install 1920x1080 convergence' -Fore Cyan
        $preMode = Wait-SafeFhdDisplayMode -TimeoutSeconds 15
        Write-Host ("  before setup: " + (Format-DisplayMode $preMode))
    } elseif ($DriverBranch -eq 'R535') {
        Write-Host '[display-guard] headless console is host-isolated; defer page-safe convergence to offline host sync' -Fore Cyan
    } else {
        Write-Host "[display-guard] $DriverBranch does not use the R535 page-alignment workaround" -Fore Cyan
    }

    Write-Host ("[driver] {0} production setup.exe in active desktop session" -f
        $DriverBranch) -Fore Cyan
    if ($DriverBranch -eq 'R580') {
        $ngxKey = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore'
        New-Item -Path $ngxKey -Force | Out-Null
        Set-ItemProperty -Path $ngxKey -Name EnableOTA -Type DWord -Value 0
        $installerLog = 'C:\nv\installer-logs'
        New-Item -Path $installerLog -ItemType Directory -Force | Out-Null
        # NVIDIA's documented silent path targets the inner setup.exe and
        # installs only Display.Driver.  -n suppresses installer-initiated
        # reboot so this wrapper can persist its signed receipt first.
        $installerArgs = @(
            '-s', '-n', 'Display.Driver',
            '-log:C:\nv\installer-logs', '-loglevel:6'
        )
    } else {
        $installerArgs = @(
            '-s', '-clean', '-noreboot', '-noeula', '-noprogressbar'
        )
    }
    $process = Start-Process -FilePath $InstallerPath `
        -ArgumentList $installerArgs -PassThru
    [IO.File]::AppendAllText($stagePath,
        "stage=setup-started`r`npid=$($process.Id)`r`n",
        [Text.Encoding]::ASCII)
    $lastUnsafe = ''
    while (-not $process.WaitForExit(1000)) {
        if ($DriverBranch -eq 'R535' -and $ConsoleGuardPolicy -eq 'Required') {
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
    }
    $installerExit = $process.ExitCode
    [IO.File]::AppendAllText($stagePath,
        "stage=setup-exited`r`ninstaller=$installerExit`r`n",
        [Text.Encoding]::ASCII)

    if ($DriverBranch -eq 'R535' -and $ConsoleGuardPolicy -eq 'Required') {
        Write-Host '[display-guard] post-install 1920x1080 convergence' -Fore Cyan
        $finalMode = Wait-SafeFhdDisplayMode -TimeoutSeconds 60
        $displaySafe = ($finalMode.Valid -and $finalMode.Width -eq 1920 -and
            $finalMode.Height -eq 1080 -and $finalMode.PageSafe)
        Write-Host ("  after setup:  " + (Format-DisplayMode $finalMode))
    } elseif ($DriverBranch -eq 'R535') {
        $finalMode = [pscustomobject]@{
            Width = 0; Height = 0; FrameBytes = [int64]0
        }
        $displaySafe = $true
    } else {
        $finalMode = [pscustomobject]@{
            Width = 0; Height = 0; FrameBytes = [int64]0
        }
        $displaySafe = $true
    }

    $receipt = [string[]]@(
        "installer=$installerExit",
        "branch=$DriverBranch",
        "expected_driver=$ExpectedDriverVersion",
        "source_package_sha256=$($ExpectedSourcePackageSha256.ToUpperInvariant())",
        "installer_sha256=$packageSha256",
        "payload_sha256=$payloadSha256",
        "package_signature=$($packageSignature.Status)",
        ("display={0}x{1}" -f $finalMode.Width, $finalMode.Height),
        ("console_bytes={0}" -f $finalMode.FrameBytes),
        ("console_required={0}" -f [int](
            $DriverBranch -eq 'R535' -and
            $ConsoleGuardPolicy -eq 'Required')),
        ("console_safe={0}" -f [int]$displaySafe)
    )
    $receiptTemp = "$FlagPath.tmp"
    [IO.File]::WriteAllLines($receiptTemp, $receipt, [Text.Encoding]::ASCII)
    Move-Item -LiteralPath $receiptTemp -Destination $FlagPath -Force

    if ($DriverBranch -eq 'R535' -and
            $ConsoleGuardPolicy -eq 'Required' -and -not $displaySafe) {
        Write-Error ('GRID install completed but the R535 console could not ' +
            'converge to page-safe 1920x1080; leaving Windows running for recovery')
        exit 20
    }

    Write-Host "installer exit code: $installerExit; rebooting in 5s" -Fore Yellow
    Start-Sleep -Seconds 5
    shutdown /r /t 0 /f
    exit 0
}

if ([string]::IsNullOrEmpty($AdminPass) -or $AdminPass.Length -lt 6 -or
        $AdminPass.Length -gt 64 -or $AdminPass -match '[\x00\r\n]') {
    throw 'AdminPass must be supplied at runtime and contain 6..64 safe characters'
}
Write-Host '[1/3] AutoAdminLogon -> Administrator (一次性)' -Fore Cyan
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $wl -Name 'AutoAdminLogon'  -Value '1'         -Type String
Set-ItemProperty -Path $wl -Name 'DefaultUserName' -Value $AdminUser -Type String
Set-ItemProperty -Path $wl -Name 'DefaultDomainName' -Value $env:COMPUTERNAME `
    -Type String
Set-ItemProperty -Path $wl -Name 'DefaultPassword' -Value $AdminPass -Type String
# Two logons tolerate the first boot reaching Winlogon before the local account
# domain is fully ready.  The host verifier removes every transient value after
# the signed driver is active, so this never becomes persistent AutoLogon.
Set-ItemProperty -Path $wl -Name 'AutoLogonCount'  -Value 2           -Type DWord

Write-Host '[2/3] RunOnce: guarded GRID setup + structured receipt' -Fore Cyan
$ro = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$scriptPath = 'C:\nv\install-driver-runonce.ps1'
$launcherPath = 'C:\nv\install-driver-runonce.cmd'
$consoleLogPath = 'C:\nv\runonce-console.log'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "RunOnce script not found at the verified staging path: $scriptPath"
}
foreach ($safePath in @($InstallerPath, $FlagPath, $scriptPath, $launcherPath,
        $consoleLogPath)) {
    if ($safePath -notmatch '^C:\\nv\\[A-Za-z0-9._\\-]+$') {
        throw "RunOnce path is outside the guarded C:\nv staging tree: $safePath"
    }
}
if ($DriverBranch -eq 'R580' -and
        $PayloadArchivePath -notmatch '^C:\\nv\\[A-Za-z0-9._\\-]+$') {
    throw "R580 payload path is outside the guarded C:\nv staging tree: $PayloadArchivePath"
}

$powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$powerShellCommand = "`"$powerShellPath`" -NoLogo -NoProfile -NonInteractive " +
    "-ExecutionPolicy Bypass -File `"$scriptPath`" " +
    "-RunInstaller -InstallerPath `"$InstallerPath`" -FlagPath `"$FlagPath`" " +
    "-DriverBranch $DriverBranch " +
    "-ExpectedInstallerSha256 $ExpectedInstallerSha256 " +
    "-ExpectedSourcePackageSha256 $ExpectedSourcePackageSha256 "
if ($DriverBranch -eq 'R580') {
    $powerShellCommand += "-PayloadArchivePath `"$PayloadArchivePath`" " +
        "-ExpectedPayloadSha256 $ExpectedPayloadSha256 "
}
$powerShellCommand += "-ExpectedDriverVersion $ExpectedDriverVersion " +
    "-ConsoleGuardPolicy $ConsoleGuardPolicy"

# Run/RunOnce registry data is limited to 260 characters.  Keep only this
# fixed short launcher in the registry and put the reviewed hash arguments in
# a local batch file.  The batch file contains no credential and records an
# entry marker before powershell.exe is created, making pre-script failures
# distinguishable from NVIDIA setup failures.
$launcherLines = [string[]]@(
    '@echo off',
    'setlocal',
    '>C:\nv\drv-stage.flag echo stage=launcher-entered',
    '>>C:\nv\drv-stage.flag echo launcher_time=%DATE% %TIME%',
    ($powerShellCommand + ' >>C:\nv\runonce-console.log 2>&1'),
    'set "G11_PS_RC=%ERRORLEVEL%"',
    '>>C:\nv\drv-stage.flag echo stage=powershell-exited',
    '>>C:\nv\drv-stage.flag echo powershell_exit=%G11_PS_RC%',
    'exit /b %G11_PS_RC%'
)
Remove-Item -LiteralPath $consoleLogPath -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllLines($launcherPath, $launcherLines, [Text.Encoding]::ASCII)

$cmd = "$env:SystemRoot\System32\cmd.exe /d /c $launcherPath"
if ($cmd.Length -gt 260) {
    throw "RunOnce launcher unexpectedly exceeds 260 characters: $($cmd.Length)"
}
Set-ItemProperty -Path $ro -Name '!NvDriverInstall' -Value $cmd -Type String
# `!` delays deletion of the RunOnce value until after this command returns.

Write-Host '[3/3] Trigger reboot' -Fore Cyan
"  RunOnce launcher armed ($($cmd.Length)/260 characters; no credential)"
"  reboot in 5s..."
Start-Sleep -Seconds 5
shutdown /r /t 0 /f
