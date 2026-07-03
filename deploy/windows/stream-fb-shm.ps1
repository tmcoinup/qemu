#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 10 / Windows 11 上使用原生 qemu-fb-shm-stream.exe 拉流。

.DESCRIPTION
    这个脚本只负责找到 patched QEMU 打出来的原生消费端，并把常用编码参数
    转成命令行。它不依赖 Python、Bash 或 MSYS；真正编码仍由 ffmpeg 处理，
    因此需要 ffmpeg.exe 位于 PATH，或由用户在外层 PATH 中指定。
#>

[CmdletBinding()]
param(
    [int]$Instance = 1,

    [string]$Streamer = "",
    [string]$Sock = "",
    [Parameter(Mandatory = $true)]
    [string]$Output,

    [string]$Encoder = "h264_nvenc",
    [string]$Preset = "p1",
    [string]$Bitrate = "6M",
    [int]$Gop = 60,
    [int]$Rate = 0,
    [string]$Roi = "",
    [string]$Container = "",
    [int]$MaxFrames = 0,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
    # deploy/windows/stream-fb-shm.ps1 -> repo root
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Find-FirstExisting {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
    return ""
}

function Add-Arg {
    param([System.Collections.Generic.List[string]]$List, [string[]]$Items)
    foreach ($item in $Items) {
        [void]$List.Add($item)
    }
}

function Test-Roi {
    param([string]$Value)
    if ($Value -and $Value -notmatch '^\d+,\d+,\d+,\d+$') {
        throw "Roi 必须是 x,y,w,h 四个非负整数，实际：$Value"
    }
}

$repo = Resolve-RepoRoot
if (-not $Streamer) {
    $Streamer = Find-FirstExisting @(
        (Join-Path $repo 'build-win64\qemu-fb-shm-stream.exe'),
        (Join-Path $repo 'build\qemu-fb-shm-stream.exe'),
        (Join-Path $PSScriptRoot 'qemu-fb-shm-stream.exe'),
        'C:\Program Files\qemu\qemu-fb-shm-stream.exe'
    )
}
if (-not $Streamer) {
    throw '找不到 qemu-fb-shm-stream.exe，请用 -Streamer 指定 patched QEMU 工具路径。'
}

if (-not $Sock) {
    # 与 start-vm.ps1 默认保持一致：短路径规避 Windows AF_UNIX sun_path 限制。
    $Sock = Join-Path 'C:\qemu-run' "fb-$Instance.sock"
}
Test-Roi $Roi

$argsList = [System.Collections.Generic.List[string]]::new()
Add-Arg $argsList @(
    '--sock', $Sock,
    '--output', $Output,
    '--encoder', $Encoder,
    '--preset', $Preset,
    '--bitrate', $Bitrate,
    '--gop', $Gop.ToString()
)
if ($Rate -gt 0) {
    Add-Arg $argsList @('--rate', $Rate.ToString())
}
if ($Roi) {
    Add-Arg $argsList @('--roi', $Roi)
}
if ($Container) {
    Add-Arg $argsList @('--container', $Container)
}
if ($MaxFrames -gt 0) {
    Add-Arg $argsList @('--max-frames', $MaxFrames.ToString())
}

Write-Host "Streamer: $Streamer"
Write-Host "Socket:   $Sock"
Write-Host "Output:   $Output"

if ($DryRun) {
    $argsList | ForEach-Object { Write-Output $_ }
    exit 0
}

& $Streamer @argsList
