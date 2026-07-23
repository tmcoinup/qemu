#Requires -Version 5.1

<#
.SYNOPSIS
  apply-gpu-spoof.ps1 的通用设备、AutoDetect、任务和显示模式辅助函数。

.DESCRIPTION
  本 helper 只提供可复用函数，不在载入时修改设备、注册表或计划任务。主脚本继续
  独占 GPU identity 与厂商 API durable transaction 的编排；这里负责无事务状态的
  环境操作，使 clone AutoDetect、Code 22 修复和显示模式验收可以独立测试。
#>

$gpuBoardIdentityContractPath = Join-Path $PSScriptRoot `
    'gpu-board-identity-contract.ps1'
if (-not (Test-Path -LiteralPath $gpuBoardIdentityContractPath -PathType Leaf)) {
    throw ('缺少同目录 GPU board identity contract：' +
        $gpuBoardIdentityContractPath)
}
. $gpuBoardIdentityContractPath

function Copy-GpuSpoofHelperIfDifferent {
    # legacy 安装可能直接从 ProgramData 中运行主脚本，此时源和持久化目标是同一文件。
    # Windows 路径不区分大小写；相同路径直接复用，路径不同才原样复制 UTF-8 BOM。
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $sourceFullPath = [IO.Path]::GetFullPath($Source)
    $destinationFullPath = [IO.Path]::GetFullPath($Destination)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $sourceFullPath, $destinationFullPath)) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
}

function Remove-GpuSpoofScheduledTaskIfPresent {
    # schtasks.exe 会把首次安装时正常的“不存在”写到 stderr；改用 ScheduledTasks API
    # 完整枚举根目录，只有唯一同名任务存在时才删除并严格复读。
    param([Parameter(Mandatory = $true)][string]$TaskName)

    $matches = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            [string]$_.TaskPath -ieq '\' -and [string]$_.TaskName -ieq $TaskName
        })
    if ($matches.Count -gt 1) { throw ('根目录存在多个同名计划任务：' + $TaskName) }
    if ($matches.Count -eq 0) { return }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -Confirm:$false -ErrorAction Stop
    $remaining = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            [string]$_.TaskPath -ieq '\' -and [string]$_.TaskName -ieq $TaskName
        })
    if ($remaining.Count -ne 0) { throw ('计划任务删除后仍可见：' + $TaskName) }
}

function Get-GpuSpoofDisplayDevices {
    # 不使用 -Status OK：Code 22/已禁用设备恰好不会出现在 OK 集合中。
    try {
        return @(Get-PnpDevice -Class 'Display' -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -and $_.Status -ne 'Unknown' })
    } catch {
        Write-Host ('  (Get-PnpDevice unavailable: ' + $_.Exception.Message + ')') `
            -ForegroundColor DarkYellow
        return @()
    }
}

function Test-GpuSpoofDisplayNeedsEnable {
    param($Device)

    if (-not $Device) { return $false }
    $status = [string]$Device.Status
    $problem = ''
    try { $problem = [string]$Device.Problem } catch {}
    if ($status -eq 'OK') { return $false }
    # 不同 Windows/PowerShell 版本可能把 Code 22 暴露为数字或 CM_PROB_DISABLED。
    if ($problem -eq '22' -or $problem -match 'CM_PROB_DISABLED|DISABLED') {
        return $true
    }
    # 部分 Win10 镜像只有 Status=Error/Degraded；对 Display 执行 Enable 是幂等兜底。
    return $status -eq 'Error' -or $status -eq 'Degraded'
}

function Enable-GpuSpoofDisplayDevices {
    param([string]$Reason = '恢复显示适配器启用状态')

    $changed = $false
    foreach ($device in @(Get-GpuSpoofDisplayDevices)) {
        if (-not (Test-GpuSpoofDisplayNeedsEnable -Device $device)) { continue }
        $label = [string]$device.FriendlyName
        if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$device.InstanceId }
        $problem = ''
        try { $problem = [string]$device.Problem } catch {}
        Write-Host ('  enabling display adapter (' + $Reason + '): ' + $label +
            ' [' + $device.Status + '/' + $problem + ']') -ForegroundColor Yellow
        try {
            Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false `
                -ErrorAction Stop
            Start-Sleep -Milliseconds 800
            $changed = $true
        } catch {
            Write-Host ('  (enable failed for ' + $device.InstanceId + ': ' +
                $_.Exception.Message + ')') -ForegroundColor DarkYellow
        }
    }
    return $changed
}

function Get-GpuSpoofAutoDetectProfile {
    # 新 profile 使用 1AF4:A101..A112 作为 stock virtio 设备的受控 carrier，
    # 真实 AIB subsystem 只进入用户态逻辑快照，绝不能挂到物理 VioGpuDod 节点。

    # RDP 登录还会枚举 ROOT\RDPINDIRECTDISPLAY；只允许唯一在线 stock virtio PCI
    # Display 参与映射，避免 RDP 节点或多显卡环境制造不确定身份。
    $gpuDevices = @(Get-PnpDevice -Class Display -PresentOnly `
        -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -ne 'Unknown' -and [string]$_.InstanceId -match `
                '^PCI\\VEN_1AF4&DEV_1050&SUBSYS_[0-9A-Fa-f]{8}(?:&|\\)'
        })
    if ($gpuDevices.Count -ne 1) {
        throw ('AutoDetect: 唯一在线 stock 1AF4:1050 Display 设备数=' +
            $gpuDevices.Count + '，拒绝继续')
    }
    $subsysMatch = [regex]::Match([string]$gpuDevices[0].InstanceId,
        'SUBSYS_([0-9A-Fa-f]{8})')
    if (-not $subsysMatch.Success) {
        throw 'AutoDetect: stock Display InstanceId 缺少 SUBSYS，拒绝继续'
    }
    $subsys = $subsysMatch.Groups[1].Value.ToUpperInvariant()
    $profile = Get-GpuBoardAutoDetectProfile -Subsys $subsys
    if ($null -eq $profile) {
        # 未知值不能回落到默认 1050，否则名称、PCI ID 与显存会拼成不存在的型号。
        throw ('AutoDetect: subsys=' + $subsys + ' 未在已知 GPU 池中，拒绝伪造默认型号')
    }
    Write-Host ('AutoDetect: subsys=' + $subsys + ' -> ' + $profile.Name) `
        -ForegroundColor Cyan
    return $profile
}

function Assert-GpuSpoofAibProfile {
    # 手工入口也必须服从当前 physical carrier，不允许覆盖 bundle 的任一字段。
    param(
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][hashtable]$Actual
    )
    foreach ($field in @(
            'Name', 'Vendor', 'Bios', 'RamMb', 'MemoryType', 'BusWidthBits',
            'BaseClockKHz', 'BoostClockKHz', 'MemoryClockKHz', 'SliSupported')) {
        if (-not $Actual.ContainsKey($field) -or
            $Actual[$field] -cne $Expected[$field]) {
            throw ('手工 GPU 参数与当前 AIB carrier 的 canonical bundle 不匹配：' +
                $field)
        }
    }
}

function Install-GpuSpoofScheduledTasks {
    # 名称刷新始终安装为 SYSTEM 任务；SkipDisplayTask 只禁止交互式显示模式任务。
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellExe,
        [Parameter(Mandatory = $true)][string]$ApplyScriptRoot,
        [Parameter(Mandatory = $true)][string]$RefreshHelperSource,
        [Parameter(Mandatory = $true)][string]$BoardIdentityContractSource,
        [Parameter(Mandatory = $true)][string]$DisplayModeHelperSource,
        [switch]$SkipDisplayTask
    )

    Write-Host ''
    Write-Host 'Installing boot-time refresh task (defeats BasicDisplay clobber)...' `
        -ForegroundColor Cyan
    $taskName = 'StealthGPU-RefreshName'
    $scriptDir = Split-Path -Parent $ApplyScriptRoot
    $scriptPath = Join-Path $scriptDir 'refresh-gpu-name.ps1'
    $contractPath = Join-Path $scriptDir 'gpu-board-identity-contract.ps1'
    New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null
    Copy-GpuSpoofHelperIfDifferent -Source $BoardIdentityContractSource `
        -Destination $contractPath
    Copy-GpuSpoofHelperIfDifferent -Source $RefreshHelperSource -Destination $scriptPath
    Remove-GpuSpoofScheduledTaskIfPresent -TaskName $taskName

    $action = New-ScheduledTaskAction -Execute $PowerShellExe `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
            $scriptPath + '"')
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable
    $task = New-ScheduledTask -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
    Write-Host ('  -> installed ' + $scriptPath) -ForegroundColor Green
    Write-Host ("  -> task '" + $taskName + "' registered (AtStartup + AtLogOn, SYSTEM)") `
        -ForegroundColor Green

    $displayTaskInstalled = $false
    $frequencyTask = 'StealthGPU-ForceDisplayFreq'
    if ($SkipDisplayTask) {
        $frequencyScript = Join-Path ([IO.Path]::GetTempPath()) `
            ('stealth-display-mode-' + $PID + '.ps1')
        $frequencyLog = ''
    } else {
        $frequencyScript = Join-Path $scriptDir 'force-displayfreq.ps1'
        $frequencyLog = Join-Path $scriptDir 'force-displayfreq.log'
    }
    Copy-GpuSpoofHelperIfDifferent -Source $DisplayModeHelperSource `
        -Destination $frequencyScript

    if ($SkipDisplayTask) {
        Write-Host '  -SkipTask: 不安装显示模式任务；将在当前会话同步切换并验收。' `
            -ForegroundColor Cyan
    } else {
        Write-Host ''
        Write-Host 'Installing user-session task to enforce and verify 1920x1080@60Hz...' `
            -ForegroundColor Cyan
        Remove-GpuSpoofScheduledTaskIfPresent -TaskName $frequencyTask
        $frequencyAction = New-ScheduledTaskAction -Execute $PowerShellExe `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                $frequencyScript + '" -LogPath "' + $frequencyLog + '"')
        $frequencyTrigger = New-ScheduledTaskTrigger -AtLogOn -User 'Administrator'
        $frequencyPrincipal = New-ScheduledTaskPrincipal -UserId 'Administrator' `
            -LogonType Interactive -RunLevel Highest
        $frequencySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries
        $frequencySchedule = New-ScheduledTask -Action $frequencyAction `
            -Trigger $frequencyTrigger -Principal $frequencyPrincipal `
            -Settings $frequencySettings
        try {
            Register-ScheduledTask -TaskName $frequencyTask `
                -InputObject $frequencySchedule -Force -ErrorAction Stop | Out-Null
            $displayTaskInstalled = $true
            Write-Host ("  -> task '" + $frequencyTask +
                "' registered (AtLogOn, Administrator/Interactive)") -ForegroundColor Green
            Write-Host ('  -> task result log: ' + $frequencyLog) -ForegroundColor Green
        } catch {
            Write-Host ('  -> display-mode task registration failed: ' +
                $_.Exception.Message) -ForegroundColor Red
        }
    }
    return [pscustomobject]@{
        DisplayTaskInstalled = $displayTaskInstalled
        FrequencyScript = $frequencyScript
        FrequencyLog = $frequencyLog
    }
}

function Invoke-GpuSpoofPnpRefresh {
    # 禁止 Disable/Enable 刷新：进程中断会把显卡永久留在 Code 22。这里只启用异常
    # Display 并请求扫描，属性最终重读仍交给 reboot 和开机刷新任务。
    Write-Host ''
    Write-Host 'Refreshing PnP state without disabling the display adapter...' `
        -ForegroundColor Cyan
    try {
        Enable-GpuSpoofDisplayDevices -Reason '最终收尾清理 Code 22' | Out-Null
        if (Get-Command 'pnputil.exe' -ErrorAction SilentlyContinue) {
            & pnputil.exe /scan-devices | Out-Null
            Write-Host '  requested PnP device scan' -ForegroundColor Green
            Start-Sleep -Milliseconds 800
            Enable-GpuSpoofDisplayDevices -Reason 'PnP 扫描后复查' | Out-Null
        } else {
            Write-Host '  (pnputil.exe unavailable; reboot will refresh PnP state)' `
                -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host ('  (PnP refresh skipped: ' + $_.Exception.Message + ')') `
            -ForegroundColor DarkYellow
    }
}

function Invoke-GpuSpoofDisplayModeVerification {
    # 子 PowerShell 的退出码是当前会话验收的唯一裁决；Session 0 只有在交互登录任务
    # 确实安装成功时才能返回 Deferred，不能把未验证状态伪装为成功。
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellExe,
        [Parameter(Mandatory = $true)][string]$FrequencyScript,
        [string]$FrequencyLog = '',
        [bool]$DisplayTaskInstalled = $false,
        [switch]$RemoveTemporaryScript
    )

    Write-Host ''
    Write-Host 'Applying and verifying current display mode synchronously...' `
        -ForegroundColor Cyan
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FrequencyScript)
    if (-not [string]::IsNullOrWhiteSpace($FrequencyLog)) {
        $arguments += @('-LogPath', $FrequencyLog)
    }
    $output = @()
    $resultCode = 24
    try {
        $output = @(& $PowerShellExe @arguments 2>&1)
        $resultCode = $LASTEXITCODE
    } catch {
        $output = @('无法启动显示模式辅助脚本：' + $_.Exception.Message)
    }
    foreach ($line in $output) { Write-Host ('  ' + [string]$line) }
    Write-Host ('  -> display-mode helper exit code: ' + $resultCode) `
        -ForegroundColor Cyan

    $deferred = $false
    $failed = $false
    $failureCode = 0
    $summary = '已同步验证：1920x1080@60Hz'
    switch ($resultCode) {
        0 {}
        10 {
            if ($DisplayTaskInstalled) {
                $deferred = $true
                $summary = '当前无交互桌面；已明确延后到 Administrator 下次交互登录验收'
            } else {
                $failed = $true
                $failureCode = 10
                $summary = '失败：当前无交互桌面，且没有已注册的登录任务可安全延后'
            }
        }
        11 {
            $failed = $true
            $failureCode = 11
            $summary = 'ChangeDisplaySettings 要求重启；请求已持久化，当前模式尚未验证'
        }
        default {
            $failed = $true
            $failureCode = if ($resultCode -gt 0) { $resultCode } else { 24 }
            $summary = '失败：显示模式辅助脚本退出码=' + $resultCode
        }
    }
    if ($RemoveTemporaryScript) {
        Remove-Item -LiteralPath $FrequencyScript -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Deferred = $deferred
        Failed = $failed
        FailureCode = $failureCode
        Summary = $summary
    }
}
