# respawn-restart-state.ps1 —— respawn 跨重启状态与计划任务 helper。
#
# 本文件只定义函数，由 respawn-stealth-local.ps1 从同一受保护 payload 目录加载。
# Full 阶段用于显示驱动/显示模式必须跨启动边界后继续完整流程的场景；
# ChipsetVerification 只验证已经提交的 NO_DRV 芯片组 INF，成功后立即退出，
# 不得再次运行 GPU spoof 或安排第二次重启。

function Enable-RespawnDisplayDevices {
    # 上次运行若在 PnP 刷新中断，显示适配器可能停在 Code 22。恢复流程只尝试
    # 启用异常 Display 设备，不通过 Disable/Enable 制造新的黑屏窗口。
    try {
        $displayDevices = @(Get-PnpDevice -Class 'Display' `
            -ErrorAction SilentlyContinue | Where-Object {
                $_.InstanceId -and $_.Status -ne 'Unknown'
            })
    } catch {
        Write-Host ("  (显示适配器状态检查失败: " + $_.Exception.Message + ")") `
            -ForegroundColor DarkYellow
        return
    }
    foreach ($device in $displayDevices) {
        $problem = ''
        try { $problem = [string]$device.Problem } catch {}
        $needsEnable = $device.Status -ne 'OK' -or $problem -eq '22' -or
            $problem -match 'CM_PROB_DISABLED|DISABLED'
        if (-not $needsEnable) { continue }
        $label = [string]$device.FriendlyName
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = [string]$device.InstanceId
        }
        Write-Host ("  启用显示适配器: " + $label + " [" +
            $device.Status + "/" + $problem + "]") -ForegroundColor Yellow
        try {
            Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false `
                -ErrorAction Stop
            Start-Sleep -Milliseconds 800
        } catch {
            Write-Host ("  (启用失败: " + $_.Exception.Message + ")") `
                -ForegroundColor DarkYellow
        }
    }
}

function Clear-RespawnDisplayModeTask {
    # FirstLogon 只清理依赖交互桌面的显示模式任务；名称与 HardwareID 任务保留。
    Remove-ScheduledTaskVerified -TaskName 'StealthGPU-ForceDisplayFreq'
}

function Get-RootScheduledTaskExact {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    # 完整枚举可以区分“任务不存在”和 Task Scheduler/CIM 查询失败；只有成功
    # 枚举后确实找不到根目录同名项，才可安全判定为不存在。
    $matches = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            [string]$_.TaskPath -ieq '\' -and [string]$_.TaskName -ieq $TaskName
        })
    if ($matches.Count -gt 1) {
        throw ('根目录存在多个同名计划任务：' + $TaskName)
    }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Remove-ScheduledTaskVerified {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    # 先禁用触发器，再停止活动实例。删除定义前必须复读到 Disabled，防止旧
    # SYSTEM 投影器越过 physical-only 门禁，或恢复任务在删除竞态中再次启动。
    $task = Get-RootScheduledTaskExact -TaskName $TaskName
    if ($null -eq $task) { return }
    Disable-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop |
        Out-Null
    $task = Get-RootScheduledTaskExact -TaskName $TaskName
    if ($null -eq $task) { return }
    if ([bool]$task.Settings.Enabled) {
        throw ('计划任务禁用后仍显示 Enabled：' + $TaskName)
    }
    if ([string]$task.State -imatch '^(Running|Queued)$') {
        Stop-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 100
            $task = Get-RootScheduledTaskExact -TaskName $TaskName
        } while ($null -ne $task -and
            [string]$task.State -imatch '^(Running|Queued)$' -and
            [DateTime]::UtcNow -lt $deadline)
        if ($null -ne $task -and
            [string]$task.State -imatch '^(Running|Queued)$') {
            throw ('计划任务在超时后仍有活动实例：' + $TaskName)
        }
    }
    if ($null -ne $task -and [string]$task.State -ine 'Disabled') {
        throw ('计划任务未进入唯一安全的 Disabled 状态：' + $TaskName +
            '（当前=' + [string]$task.State + '）')
    }
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' `
            -Confirm:$false -ErrorAction Stop
    }
    if ($null -ne (Get-RootScheduledTaskExact -TaskName $TaskName)) {
        throw ('计划任务删除后仍可见：' + $TaskName)
    }
}

function Remove-RespawnResumeTask {
    param([switch]$CurrentInstance)

    # 当前 PowerShell 可能正是恢复任务的 Running 实例；这种情况下只删除任务
    # 定义，绝不能 Stop 自己。其它调用者仍走完整的禁用、停止、复读流程。
    if (-not $CurrentInstance) {
        Remove-ScheduledTaskVerified -TaskName 'StealthGPU-ResumeRespawn'
        return
    }
    $taskName = 'StealthGPU-ResumeRespawn'
    $task = Get-RootScheduledTaskExact -TaskName $taskName
    if ($null -eq $task) { return }
    Disable-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop |
        Out-Null
    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' `
        -Confirm:$false -ErrorAction Stop
    if ($null -ne (Get-RootScheduledTaskExact -TaskName $taskName)) {
        throw ('一次性恢复任务删除后仍可见：' + $taskName)
    }
}

function Register-RespawnResumeTask {
    param(
        [Parameter(Mandatory = $true)][string]$MainScriptPath,
        [switch]$KeepFirstLogon,
        [ValidateSet('Full', 'ChipsetVerification')]
        [string]$ResumeStage = 'Full'
    )

    # 使用当前管理员的交互登录触发器。Full 阶段后续需要枚举当前桌面显示模式；
    # ChipsetVerification 虽不依赖桌面，也沿用同一主体和一次性清理协议。
    $resumeUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($resumeUser -match '\\SYSTEM$') { $resumeUser = 'Administrator' }
    # helper 被 dot-source 后，PSCommandPath 会指向本 helper，而不是入口脚本；
    # 恢复任务必须显式回到主流程，不能依赖调用栈自动变量推断路径。
    $scriptPath = [string]$MainScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or
        -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw '无法定位重启后要继续执行的 respawn 脚本。'
    }

    $resumeArgs = '-NoProfile -ExecutionPolicy Bypass -File "' +
        $scriptPath + '" -ResumeAfterReboot -Unattended -ResumeStage ' +
        $ResumeStage
    if ($KeepFirstLogon) { $resumeArgs += ' -FirstLogon' }
    if ($ResumeAfterReboot) {
        Remove-RespawnResumeTask -CurrentInstance
    } else {
        Remove-RespawnResumeTask
    }

    $action = New-ScheduledTaskAction -Execute $powershellExe `
        -Argument $resumeArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $resumeUser
    $trigger.Delay = 'PT15S'
    $principal = New-ScheduledTaskPrincipal -UserId $resumeUser `
        -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $task = New-ScheduledTask -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskName 'StealthGPU-ResumeRespawn' `
        -InputObject $task -Force -ErrorAction Stop | Out-Null
}

function Invoke-RespawnShutdown {
    param(
        [Parameter(Mandatory = $true)][string]$ShutdownPath,
        [Parameter(Mandatory = $true)][int]$DelaySeconds,
        [Parameter(Mandatory = $true)][string]$Comment
    )

    # 固定调用 System32 完整路径，并立即保存原生命令退出码。若进程根本无法
    # 创建，PowerShell 可能保留上一条原生命令的 LASTEXITCODE，不能据此误报成功。
    if ([string]::IsNullOrWhiteSpace($ShutdownPath) -or
        -not (Test-Path -LiteralPath $ShutdownPath -PathType Leaf)) {
        throw ('找不到可信的 Windows 重启程序：' + $ShutdownPath)
    }
    $previousErrorActionPreference = $ErrorActionPreference
    $global:LASTEXITCODE = $null
    try {
        $ErrorActionPreference = 'Stop'
        & $ShutdownPath /r /t $DelaySeconds /f /c $Comment
        $nativeExitCode = $global:LASTEXITCODE
    } catch {
        throw ('无法启动 Windows 重启程序：' + $_.Exception.Message)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($null -eq $nativeExitCode) {
        throw 'Windows 重启程序没有返回可验证的退出码。'
    }
    if ([int]$nativeExitCode -ne 0) {
        throw ('shutdown.exe 返回错误码 ' + [int]$nativeExitCode)
    }
}

function Restart-RespawnForPendingWork {
    param(
        [Parameter(Mandatory = $true)][string]$MainScriptPath,
        [Parameter(Mandatory = $true)][int]$PendingExitCode,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$ShutdownComment,
        [Parameter(Mandatory = $true)][int]$RegistrationFailureCode,
        [Parameter(Mandatory = $true)][int]$ShutdownFailureCode
    )

    Write-Host $Reason -ForegroundColor Yellow
    if ($NoReboot) {
        Write-Host '当前为 -NoReboot：请手动重启后再次运行本程序完成验证。' `
            -ForegroundColor Yellow
        exit $PendingExitCode
    }
    try {
        Register-RespawnResumeTask -MainScriptPath $MainScriptPath `
            -KeepFirstLogon:$FirstLogon `
            -ResumeStage 'Full'
    } catch {
        Write-Host ('FAIL: 无法创建重启后二阶段恢复任务：' +
            $_.Exception.Message) -ForegroundColor Red
        exit $RegistrationFailureCode
    }
    Write-Host "已创建一次性恢复任务，${RebootDelay}s 后重启继续验证。" `
        -ForegroundColor Green
    try {
        Invoke-RespawnShutdown -ShutdownPath $shutdownExe `
            -DelaySeconds $RebootDelay -Comment $ShutdownComment
    } catch {
        Write-Host ('FAIL: Windows 拒绝安排重启；恢复任务已保留，可手动重启。' +
            ' 原因：' + $_.Exception.Message) `
            -ForegroundColor Red
        exit $ShutdownFailureCode
    }
    exit 0
}

function Wait-ResumeDisplayDeviceReady {
    # AtLogOn 可能早于显示类设备就绪；超时必须保留任务，供下次登录重试。
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try {
            $ready = @(Get-PnpDevice -Class Display -PresentOnly `
                -ErrorAction Stop | Where-Object {
                    [string]$_.InstanceId -match
                        '^PCI\\VEN_1AF4&DEV_1050(?:&|\\)'
                })
            if ($ready.Count -gt 0) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
