#Requires -Version 5.1
<#
.SYNOPSIS
    通过 QMP 让 Windows 宿主上的 patched QEMU 优雅退出。

.DESCRIPTION
    start-vm.ps1 默认打开 127.0.0.1:(4440 + Instance) 的 QMP TCP 端口。
    本脚本直接用 .NET TcpClient 发送 qmp_capabilities 与 quit，不需要 Python。
    连接阶段使用 BeginConnect，避免目标端口不可达时长时间卡住控制台。
#>

[CmdletBinding()]
param(
    [int]$Instance = 1,
    [string]$QmpHost = "127.0.0.1",
    [int]$QmpPort = 0,
    [int]$TimeoutMs = 3000,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Send-QmpJson {
    param(
        [System.IO.StreamWriter]$Writer,
        [hashtable]$Object
    )
    $json = $Object | ConvertTo-Json -Compress -Depth 8
    $Writer.WriteLine($json)
}

if (-not $QmpPort) {
    $QmpPort = 4440 + $Instance
}

Write-Host "QMP: ${QmpHost}:$QmpPort"
if ($DryRun) {
    Write-Output '{"execute":"qmp_capabilities"}'
    Write-Output '{"execute":"quit"}'
    exit 0
}

$client = [System.Net.Sockets.TcpClient]::new()
$async = $client.BeginConnect($QmpHost, $QmpPort, $null, $null)
if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
    $client.Close()
    throw "连接 QMP 超时：${QmpHost}:$QmpPort"
}
$client.EndConnect($async)

try {
    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutMs
    $stream.WriteTimeout = $TimeoutMs
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8)
    $writer.AutoFlush = $true

    # QMP 首包是 greeting；读取后再协商 capabilities。
    [void]$reader.ReadLine()
    Send-QmpJson $writer @{ execute = 'qmp_capabilities' }
    [void]$reader.ReadLine()
    Send-QmpJson $writer @{ execute = 'quit' }
    Write-Host '已发送 QMP quit。'
} finally {
    $client.Close()
}
