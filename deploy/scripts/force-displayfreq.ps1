param([string]$LogPath = '')

# 本脚本既由 apply-gpu-spoof 在当前用户桌面同步调用，也由登录任务重试。
# 所有原生返回值和最终枚举值都会输出；计划任务模式还会追加日志，便于定位失败。
$ErrorActionPreference = 'Stop'

function Write-ModeMessage {
    param([string]$Message)

    $line = ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message)
    Write-Output $line
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try {
            Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            # 日志写入失败不能覆盖显示切换的真实结果；stdout 仍保留诊断信息。
            Write-Output ('[日志写入失败] ' + $_.Exception.Message)
        }
    }
}

function Get-DisplayChangeName {
    param([int]$Code)

    switch ($Code) {
        0  { return 'DISP_CHANGE_SUCCESSFUL' }
        1  { return 'DISP_CHANGE_RESTART' }
        -1 { return 'DISP_CHANGE_FAILED' }
        -2 { return 'DISP_CHANGE_BADMODE' }
        -3 { return 'DISP_CHANGE_NOTUPDATED' }
        -4 { return 'DISP_CHANGE_BADFLAGS' }
        -5 { return 'DISP_CHANGE_BADPARAM' }
        -6 { return 'DISP_CHANGE_BADDUALVIEW' }
        default { return ('UNKNOWN(' + $Code + ')') }
    }
}

if (-not ('StDisp' -as [type])) {
    Add-Type -ErrorAction Stop @"
using System;
using System.Runtime.InteropServices;
public class StDisp {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint   dmFields;
        public int    dmPositionX;
        public int    dmPositionY;
        public uint   dmDisplayOrientation;
        public uint   dmDisplayFixedOutput;
        public short  dmColor;
        public short  dmDuplex;
        public short  dmYResolution;
        public short  dmTTOption;
        public short  dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint   dmBitsPerPel;
        public uint   dmPelsWidth;
        public uint   dmPelsHeight;
        public uint   dmDisplayFlags;
        public uint   dmDisplayFrequency;
        public uint   dmICMMethod;
        public uint   dmICMIntent;
        public uint   dmMediaType;
        public uint   dmDitherType;
        public uint   dmReserved1;
        public uint   dmReserved2;
        public uint   dmPanningWidth;
        public uint   dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int ChangeDisplaySettings(ref DEVMODE devMode, uint flags);
}
"@
}

function Get-CurrentDisplayMode {
    # ENUM_CURRENT_SETTINGS(-1) 读取当前桌面的真实有源模式；返回 0 通常说明当前
    # 进程位于 Session 0、桌面尚未初始化，或当前会话根本没有显示输出。
    $mode = New-Object StDisp+DEVMODE
    $mode.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf($mode)
    $enumResult = [StDisp]::EnumDisplaySettings($null, -1, [ref]$mode)
    return [pscustomobject]@{
        Available = ($enumResult -ne 0)
        NativeResult = $enumResult
        Mode = $mode
    }
}

function Format-DisplayMode {
    param($Snapshot)

    if (-not $Snapshot -or -not $Snapshot.Available) { return '<不可枚举>' }
    return ('{0}x{1}@{2}Hz/{3}bpp' -f `
        $Snapshot.Mode.dmPelsWidth,
        $Snapshot.Mode.dmPelsHeight,
        $Snapshot.Mode.dmDisplayFrequency,
        $Snapshot.Mode.dmBitsPerPel)
}

$targetWidth = 1920
$targetHeight = 1080
$targetFrequency = 60
$cdsUpdateRegistry = 0x00000001
$cdsTest = 0x00000002

try {
    $before = Get-CurrentDisplayMode
    if (-not $before.Available) {
        Write-ModeMessage '无法枚举当前显示模式：当前进程没有可交互桌面；未执行切换。'
        exit 10
    }
    Write-ModeMessage ('切换前模式：' + (Format-DisplayMode $before))

    # 重启后的二阶段验收会再次运行本 helper。若驱动已经把持久化请求应用为目标模式，
    # 直接以当前枚举值验收成功，不再重复调用 ChangeDisplaySettings 并陷入 rc=11 循环。
    if ($before.Mode.dmPelsWidth -eq $targetWidth -and
        $before.Mode.dmPelsHeight -eq $targetHeight -and
        $before.Mode.dmDisplayFrequency -eq $targetFrequency) {
        Write-ModeMessage '验收成功：当前显示模式已经是 1920x1080@60Hz，无需重复切换。'
        exit 0
    }

    # 以当前 DEVMODE 为基线，只声明确实要修改的四个字段，避免覆盖驱动私有数据。
    $desired = $before.Mode
    $desired.dmPelsWidth = $targetWidth
    $desired.dmPelsHeight = $targetHeight
    $desired.dmBitsPerPel = 32
    $desired.dmDisplayFrequency = $targetFrequency
    # DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY
    $desired.dmFields = [uint32]0x005C0000

    # CDS_TEST 先确认驱动接受该模式；即使测试失败也必须记录原生返回码，不能继续
    # 调用并假装成功。测试成功后用 CDS_UPDATEREGISTRY 同步应用且持久化到重启后。
    $testResult = [StDisp]::ChangeDisplaySettings([ref]$desired, $cdsTest)
    Write-ModeMessage ('ChangeDisplaySettings(CDS_TEST) 返回码=' + $testResult +
        ' [' + (Get-DisplayChangeName $testResult) + ']')
    if ($testResult -ne 0) { exit 20 }

    $changeResult = [StDisp]::ChangeDisplaySettings([ref]$desired, $cdsUpdateRegistry)
    Write-ModeMessage ('ChangeDisplaySettings(CDS_UPDATEREGISTRY) 返回码=' + $changeResult +
        ' [' + (Get-DisplayChangeName $changeResult) + ']')
    if ($changeResult -eq 1) {
        $pending = Get-CurrentDisplayMode
        Write-ModeMessage ('当前仍为：' + (Format-DisplayMode $pending))
        Write-ModeMessage '模式已持久化，但驱动要求重启后生效；当前会话尚未验证为目标模式。'
        exit 11
    }
    if ($changeResult -ne 0) { exit 21 }

    # 原生 API 返回 SUCCESSFUL 只表示请求被接受，不代表桌面已经完成模式切换。
    # 最多等待 2 秒并反复枚举，最终必须同时匹配宽、高和刷新率才返回成功。
    $after = $null
    for ($attempt = 0; $attempt -lt 9; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Milliseconds 250 }
        $after = Get-CurrentDisplayMode
        if ($after.Available -and
            $after.Mode.dmPelsWidth -eq $targetWidth -and
            $after.Mode.dmPelsHeight -eq $targetHeight -and
            $after.Mode.dmDisplayFrequency -eq $targetFrequency) {
            break
        }
    }
    if (-not $after -or -not $after.Available) {
        Write-ModeMessage '切换后无法重新枚举显示模式，不能确认请求是否生效。'
        exit 22
    }

    Write-ModeMessage ('切换后模式：' + (Format-DisplayMode $after))
    if ($after.Mode.dmPelsWidth -ne $targetWidth -or
        $after.Mode.dmPelsHeight -ne $targetHeight -or
        $after.Mode.dmDisplayFrequency -ne $targetFrequency) {
        Write-ModeMessage '验收失败：最终宽度、高度或刷新率与 1920x1080@60Hz 不一致。'
        exit 23
    }

    Write-ModeMessage '验收成功：当前显示模式为 1920x1080@60Hz。'
    exit 0
} catch {
    Write-ModeMessage ('显示模式处理发生未捕获异常：' + $_.Exception.Message)
    exit 24
}
