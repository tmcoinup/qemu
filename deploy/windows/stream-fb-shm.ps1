#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 上使用原生 qemu-fb-shm-stream.exe 拉流，并自动选择可运行编码器。

.DESCRIPTION
    -Encoder auto 会按 NVENC、QSV、AMF、libx264 的顺序做一帧运行时探测。
    只检查 ffmpeg -encoders 不足以证明显卡、驱动和 session 仍可用；一帧探测
    可以在正式推流前完成安全回退。用户显式指定编码器时保持严格语义，不回退。
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 1000)]
    [int]$Instance = 1,
    [string]$Streamer = '',
    [string]$Ffmpeg = '',
    [string]$Sock = '',
    [Parameter(Mandatory = $true)]
    [string]$Output,
    [string]$Encoder = 'auto',
    [string]$Preset = '',
    [string]$Bitrate = '6M',
    [ValidateSet('auto', 'gpu', 'shm')]
    [string]$Mode = 'auto',
    [ValidateRange(1, 1000)]
    [int]$Gop = 60,
    [ValidateRange(0, 240)]
    [int]$Rate = 0,
    [string]$Roi = '',
    [string]$Container = '',
    [int]$MaxFrames = 0,
    [ValidateSet('Auto', 'Nvenc', 'Qsv', 'Amf', 'Software', 'None')]
    [string]$EncoderProbe = 'Auto',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$libraryRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libraryRoot 'VMate.Common.ps1')

function Test-VMateRoi {
    param([string]$Value)

    if ($Value -and $Value -notmatch '^\d+,\d+,\d+,\d+$') {
        throw "Roi 必须是 x,y,w,h 四个非负整数，实际：$Value"
    }
    if ($Value) {
        $parts = $Value.Split(',')
        if ([int64]$parts[2] -eq 0 -or [int64]$parts[3] -eq 0) {
            throw 'Roi 的宽和高必须大于零。'
        }
    }
}

function Test-VMateFfmpegEncoder {
    param(
        [string]$Executable,
        [string]$Name
    )

    try {
        # 64x64 单帧不会影响桌面流畅性，却能真正触发驱动初始化和硬件 session
        # 分配。所有输出均捕获，候选失败属于正常回退过程，不污染运行日志。
        $probeOutput = & $Executable '-hide_banner' '-loglevel' 'error' `
            '-f' 'lavfi' '-i' 'color=size=64x64:rate=1' '-frames:v' '1' `
            '-c:v' $Name '-f' 'null' 'NUL' 2>&1
        [void]($probeOutput | Out-String)
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Verbose "编码器 $Name 探测失败：$($_.Exception.Message)"
        return $false
    }
}

function Get-VMateEncoderFromProbe {
    param([string]$Probe)

    switch ($Probe) {
        'Nvenc' { return 'h264_nvenc' }
        'Qsv' { return 'h264_qsv' }
        'Amf' { return 'h264_amf' }
        'Software' { return 'libx264' }
        'None' { throw '测试注入声明没有可用编码器。' }
        default { return '' }
    }
}

function Select-VMateEncoder {
    param(
        [string]$Requested,
        [string]$Probe,
        [string]$FfmpegExecutable,
        [bool]$IsDryRun
    )

    if ($Requested -notmatch '^[A-Za-z0-9_]+$') {
        throw "Encoder 包含非法字符：$Requested"
    }
    if ($Probe -ne 'Auto') {
        if (-not $IsDryRun) {
            throw 'EncoderProbe 注入值仅允许和 -DryRun 一起用于测试。'
        }
        $injected = Get-VMateEncoderFromProbe $Probe
        if ($Requested -eq 'auto') {
            return $injected
        }
        return $Requested
    }
    if ($IsDryRun) {
        # DryRun 不应访问 GPU/驱动；未注入时选择可移植软件编码器用于打印参数。
        return $(if ($Requested -eq 'auto') { 'libx264' } else { $Requested })
    }
    if (-not $FfmpegExecutable) {
        throw '找不到 ffmpeg.exe，无法验证编码器；请用 -Ffmpeg 指定。'
    }
    if ($Requested -ne 'auto') {
        if (-not (Test-VMateFfmpegEncoder $FfmpegExecutable $Requested)) {
            throw "显式编码器 '$Requested' 运行时探测失败；严格模式不自动替换。"
        }
        return $Requested
    }
    foreach ($candidate in @('h264_nvenc', 'h264_qsv', 'h264_amf', 'libx264')) {
        if (Test-VMateFfmpegEncoder $FfmpegExecutable $candidate) {
            return $candidate
        }
    }
    throw 'NVENC/QSV/AMF/libx264 均未通过一帧运行时探测。'
}

function Get-VMateDefaultPreset {
    param([string]$SelectedEncoder)

    switch ($SelectedEncoder) {
        'h264_nvenc' { return 'p1' }
        'h264_amf' { return 'speed' }
        default { return 'veryfast' }
    }
}

$repo = Get-VMateRepoRoot
if (-not $Streamer) {
    $Streamer = Find-VMateFirstExisting @(
        (Join-Path $repo 'qemu-fb-shm-stream.exe'),
        (Join-Path $repo 'build-win64\qemu-fb-shm-stream.exe'),
        (Join-Path $repo 'build\qemu-fb-shm-stream.exe'),
        (Join-Path $PSScriptRoot 'qemu-fb-shm-stream.exe'),
        'C:\Program Files\qemu\qemu-fb-shm-stream.exe'
    )
}
if (-not $Streamer) {
    throw '找不到 qemu-fb-shm-stream.exe，请用 -Streamer 指定。'
}
if (-not $Ffmpeg -and -not $DryRun) {
    $ffmpegCommand = Get-Command 'ffmpeg.exe' -ErrorAction SilentlyContinue
    if ($ffmpegCommand) {
        $Ffmpeg = $ffmpegCommand.Source
    }
}
if ($Ffmpeg -and -not (Test-Path -LiteralPath $Ffmpeg -PathType Leaf)) {
    throw "ffmpeg.exe 不存在：$Ffmpeg"
}
if (-not $Sock) {
    # 字符串拼接让 Linux CI 的 DryRun 不要求存在 C: PowerShell drive。
    $Sock = "C:\qemu-run\fb-$Instance.sock"
}
Test-VMateRoi $Roi

$selectedEncoder = Select-VMateEncoder -Requested $Encoder -Probe $EncoderProbe `
    -FfmpegExecutable $Ffmpeg -IsDryRun $DryRun.IsPresent
if (-not $Preset) {
    $Preset = Get-VMateDefaultPreset $selectedEncoder
}

$arguments = [System.Collections.Generic.List[string]]::new()
Add-VMateArgument $arguments @(
    '--sock', $Sock,
    '--output', $Output,
    '--encoder', $selectedEncoder,
    '--preset', $Preset,
    '--bitrate', $Bitrate,
    '--mode', $Mode,
    '--gop', $Gop.ToString()
)
if ($Rate -gt 0) {
    Add-VMateArgument $arguments @('--rate', $Rate.ToString())
}
if ($Roi) {
    Add-VMateArgument $arguments @('--roi', $Roi)
}
if ($Container) {
    Add-VMateArgument $arguments @('--container', $Container)
}
if ($MaxFrames -gt 0) {
    Add-VMateArgument $arguments @('--max-frames', $MaxFrames.ToString())
}

Write-Host "Streamer: $Streamer"
Write-Host "Socket:   $Sock"
Write-Host "Output:   $Output"
Write-Host "Encoder:  $selectedEncoder (preset=$Preset)"
if ($DryRun) {
    $arguments | ForEach-Object { Write-Output $_ }
    exit 0
}

if ($Ffmpeg) {
    # native streamer 通过 PATH 启动 ffmpeg。把已验证 exe 的目录只加入当前
    # PowerShell 子进程环境，既支持便携目录，又不改系统或用户级 PATH。
    $ffmpegDirectory = Split-Path -Parent $Ffmpeg
    $env:PATH = $ffmpegDirectory + [IO.Path]::PathSeparator + $env:PATH
}
& $Streamer @arguments
if ($LASTEXITCODE -ne 0) {
    throw "qemu-fb-shm-stream 异常退出，exit code=$LASTEXITCODE"
}
