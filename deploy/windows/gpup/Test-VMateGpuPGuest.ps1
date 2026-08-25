#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ExpectedVendor = '',
    [string]$ExpectedGpuName = '',
    [string]$ExpectedDriverVersion = '',
    [bool]$Strict = $true,
    [switch]$DisableHyperVVideo,
    [switch]$RequireNvidiaSmi,
    [switch]$RequireMonitor
)

# 入口只负责无交互参数绑定；验证逻辑独立成模块，便于宿主/guest mock 回归。
. (Join-Path $PSScriptRoot 'VMate.GpuP.D3DValidation.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.GuestValidation.ps1')

function Assert-VMateGpuPCleanGuestImage {
    # P-11 只接受重新制作的干净镜像；这里只读识别旧 V-11 payload，绝不卸载。
    $evidence = [System.Collections.Generic.List[string]]::new()
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        $facts = @([string]$process.Name, [string]$process.ExecutablePath) -join '|'
        if ($facts -match '(?i)respawn-stealth(?:\.exe)?') {
            [void]$evidence.Add("Process:$($process.ProcessId):$($process.Name)")
        }
    }
    foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop)) {
        $facts = @([string]$service.Name, [string]$service.DisplayName,
            [string]$service.PathName) -join '|'
        if ($facts -match '(?i)(respawn-stealth|StealthGPU|VMate.*stealth)') {
            [void]$evidence.Add("Service:$($service.Name)")
        }
    }
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
            $actions = @($task.Actions | ForEach-Object {
                    $execute = $_.PSObject.Properties['Execute']
                    $arguments = $_.PSObject.Properties['Arguments']
                    @(
                        if ($null -eq $execute) { '' }
                        else { [string]$execute.Value }
                        if ($null -eq $arguments) { '' }
                        else { [string]$arguments.Value }
                    ) -join ' '
                }) -join '|'
            if (([string]$task.TaskName + '|' + $actions) -match
                '(?i)(respawn-stealth|StealthGPU|VMate.*stealth)') {
                [void]$evidence.Add("ScheduledTask:$($task.TaskPath)$($task.TaskName)")
            }
        }
    }
    $payloads = @(
        (Join-Path $env:ProgramData 'VMate\respawn-stealth.exe'),
        (Join-Path $env:SystemDrive 'VMate\respawn-stealth.exe'),
        'D:\工具\respawn-stealth.exe'
    )
    foreach ($payload in $payloads) {
        if (Test-Path -LiteralPath $payload -PathType Leaf) {
            [void]$evidence.Add("File:$payload")
        }
    }
    $legacyRoot = Join-Path $env:ProgramData 'StealthGPU'
    if (Test-Path -LiteralPath $legacyRoot -PathType Container) {
        [void]$evidence.Add("Directory:$legacyRoot")
    }
    if ($evidence.Count -ne 0) {
        throw ('guest 不是干净 P-11 镜像；发现旧 respawn-stealth 投影痕迹：' +
            ($evidence -join '；'))
    }
    return [pscustomobject]@{ Passed = $true; LegacyProjectionEvidence = @() }
}

if ($MyInvocation.InvocationName -cne '.') {
    if (-not $ExpectedVendor -or -not $ExpectedGpuName -or
        -not $ExpectedDriverVersion) {
        throw '请显式提供 ExpectedVendor、ExpectedGpuName 和 ExpectedDriverVersion。'
    }
    $cleanImage = Assert-VMateGpuPCleanGuestImage
    $result = Test-VMateGpuPGuest -Vendor $ExpectedVendor -GpuName $ExpectedGpuName `
        -DriverVersion $ExpectedDriverVersion -StrictMode $Strict `
        -DisableHyperVVideoAdapter:$DisableHyperVVideo.IsPresent `
        -RequireNvidiaSmi:$RequireNvidiaSmi.IsPresent `
        -RequireMonitor:$RequireMonitor.IsPresent
    $result | Add-Member -NotePropertyName CleanImage -NotePropertyValue $cleanImage
    $result
}
