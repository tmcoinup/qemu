# project-monitor-identity.ps1 —— 按硬件池 EDID PnP ID 投影设备管理器显示名称。
#
# 本脚本只设置 DEVPKEY_Device_FriendlyName。显示器的 EDID、HardwareID、INF、
# Monitor Class、monitor.sys 与色彩配置均保持不变；因此没有厂商 INF 的型号也能在
# 设备管理器里显示硬件池名称，同时不会把通用 Monitor 驱动伪装成厂商内核驱动。

param(
    [string] $ManifestPath = (Join-Path $PSScriptRoot 'monitor-identities.json'),
    [string] $ProjectorPath = (
        Join-Path $PSScriptRoot 'monitor-friendly-name-projector.exe'
    ),
    [switch] $RegisterTask
)

$ErrorActionPreference = 'Stop'
$TaskName = 'StealthGPU-ProjectMonitorIdentity'

function Stop-MonitorProjection {
    param(
        [Parameter(Mandatory = $true)] [string] $Message,
        [int] $Code = 70
    )
    Write-Host ('FAIL: ' + $Message) -ForegroundColor Red
    exit $Code
}

function Assert-PlainPayloadFile {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ('payload 不是受控普通文件：' + $fullPath)
    }
    return $fullPath
}

function Get-DevicePropertyValues {
    param(
        [Parameter(Mandatory = $true)] [string] $InstanceId,
        [Parameter(Mandatory = $true)] [string] $KeyName
    )

    # 权限、CIM 或设备枚举失败必须向上抛出，不能把查询失败伪装成“属性为空”。
    $property = Get-PnpDeviceProperty -InstanceId $InstanceId `
        -KeyName $KeyName -ErrorAction Stop
    return @($property.Data | ForEach-Object { [string] $_ })
}

function Get-ProtectedMonitorState {
    param([Parameter(Mandatory = $true)] [string] $InstanceId)

    $keys = @(
        'DEVPKEY_Device_HardwareIds',
        'DEVPKEY_Device_DriverInfPath',
        'DEVPKEY_Device_Service',
        'DEVPKEY_Device_Class',
        'DEVPKEY_Device_DeviceDesc'
    )
    $state = [ordered]@{}
    foreach ($key in $keys) {
        $state[$key] = @(
            Get-DevicePropertyValues -InstanceId $InstanceId -KeyName $key
        )
    }
    return $state
}

function Assert-ProtectedMonitorStateUnchanged {
    param(
        [Parameter(Mandatory = $true)] [Collections.IDictionary] $Before,
        [Parameter(Mandatory = $true)] [Collections.IDictionary] $After
    )

    foreach ($key in $Before.Keys) {
        $beforeValue = @($Before[$key]) -join "`0"
        $afterValue = @($After[$key]) -join "`0"
        if ($beforeValue -cne $afterValue) {
            throw ("投影意外修改受保护字段 ${key}：`n" +
                "before=$beforeValue`nafter=$afterValue")
        }
    }
}

function Read-MonitorManifest {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ([int] $document.schema_version -ne 1) {
        throw ('不支持的显示器清单 schema：' + $document.schema_version)
    }

    $entries = @($document.monitors)
    if ($entries.Count -eq 0) { throw '显示器清单为空' }
    $seenComponents = @{}
    $seenPnpCodes = @{}
    foreach ($entry in $entries) {
        $componentId = [string] $entry.component_id
        $pnpCode = [string] $entry.pnp_code
        $hardwareId = [string] $entry.hardware_id
        $instancePrefix = [string] $entry.instance_prefix
        $friendlyName = [string] $entry.friendly_name
        if ($componentId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw ('非法 component_id：' + $componentId)
        }
        if ($pnpCode -cnotmatch '^[A-Z]{3}[0-9A-F]{4}$' -or
            $hardwareId -cne ('MONITOR\' + $pnpCode) -or
            $instancePrefix -cne ('DISPLAY\' + $pnpCode + '\')) {
            throw ('显示器清单 PnP 字段不一致：' + $componentId)
        }
        if ([string]::IsNullOrWhiteSpace($friendlyName) -or
            $friendlyName.Length -gt 128 -or $friendlyName -match '[\x00-\x1f\x7f]') {
            throw ('非法显示器名称：' + $componentId)
        }
        if ($seenComponents.ContainsKey($componentId) -or
            $seenPnpCodes.ContainsKey($pnpCode)) {
            throw ('显示器清单存在重复项：' + $componentId)
        }
        $seenComponents[$componentId] = $true
        $seenPnpCodes[$pnpCode] = $true
    }
    return $entries
}

function Find-ManagedMonitor {
    param([Parameter(Mandatory = $true)] [object[]] $Entries)

    $entryByCode = @{}
    foreach ($entry in $Entries) {
        $entryByCode[[string] $entry.pnp_code] = $entry
    }

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        # PowerShell 变量名不区分大小写；不能命名为 $matches，否则下一条 -match
        # 会把自动变量 $Matches（哈希表）覆盖进来，随后数组追加必然失败。
        $managedMatches = @()
        $devices = @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction Stop)
        foreach ($device in $devices) {
            $instanceId = [string] $device.InstanceId
            if ($instanceId -notmatch '(?i)^DISPLAY\\([A-Z]{3}[0-9A-F]{4})\\') {
                continue
            }
            $code = $Matches[1].ToUpperInvariant()
            if ($entryByCode.ContainsKey($code)) {
                $managedMatches += [pscustomobject]@{
                    Device = $device
                    Entry = $entryByCode[$code]
                }
            }
        }
        if ($managedMatches.Count -eq 1) { return $managedMatches[0] }
        if ($managedMatches.Count -gt 1) {
            throw ('预期一个硬件池显示器，实际在线=' + $managedMatches.Count)
        }
        Start-Sleep -Seconds 1
    }
    throw '30 秒内没有枚举到硬件池显示器'
}

function Get-MonitorProjectionTask {
    $tasks = @(Get-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -ErrorAction SilentlyContinue)
    if ($tasks.Count -gt 1) {
        throw ('根目录存在多个同名显示器任务：' + $TaskName)
    }
    if ($tasks.Count -eq 0) { return $null }
    return $tasks[0]
}

function Remove-MonitorProjectionTaskVerified {
    $task = Get-MonitorProjectionTask
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' `
            -Confirm:$false -ErrorAction Stop
    }
    if ($null -ne (Get-MonitorProjectionTask)) {
        throw ('显示器任务删除后仍可见：' + $TaskName)
    }
}

function Restore-MonitorFriendlyName {
    param(
        [Parameter(Mandatory = $true)] [string] $Projector,
        [Parameter(Mandatory = $true)] [string] $InstanceId,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $Previous
    )

    if ($Previous.Count -eq 0) {
        & $Projector $InstanceId --clear
    } elseif ($Previous.Count -eq 1) {
        & $Projector $InstanceId --set $Previous[0]
    } else {
        throw ('回滚快照含多个 FriendlyName：' + ($Previous -join '; '))
    }
    if ($LASTEXITCODE -ne 0) {
        throw ('FriendlyName 回滚器退出码=' + $LASTEXITCODE)
    }
}

function Register-MonitorProjectionTask {
    param(
        [Parameter(Mandatory = $true)] [string] $ScriptPath,
        [Parameter(Mandatory = $true)] [string] $Manifest,
        [Parameter(Mandatory = $true)] [string] $Projector
    )

    foreach ($value in $ScriptPath, $Manifest, $Projector) {
        if ($value.Contains('"')) { throw '计划任务路径包含非法引号' }
    }
    $powershell = Join-Path $PSHOME 'powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
        '-WindowStyle Hidden ' +
        '-File "' + $ScriptPath + '" -ManifestPath "' + $Manifest +
        '" -ProjectorPath "' + $Projector + '"'
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest
    # Queue 保留快速登录触发：若启动实例仍在等待 Monitor 枚举，登录实例会排队重试。
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances Queue
    $definition = New-ScheduledTask -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings
    $previousTask = Get-MonitorProjectionTask
    $previousTaskXml = if ($null -eq $previousTask) {
        $null
    } else {
        Export-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
    }
    Remove-MonitorProjectionTaskVerified
    try {
        Register-ScheduledTask -TaskName $TaskName -TaskPath '\' `
            -InputObject $definition -Force -ErrorAction Stop | Out-Null
        $task = Get-MonitorProjectionTask
        $systemIds = @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18')
        if ($null -eq $task -or
            -not ($systemIds -icontains [string] $task.Principal.UserId) -or
            [string] $task.Principal.RunLevel -ine 'Highest' -or
            [string] $task.Principal.LogonType -ine 'ServiceAccount' -or
            @($task.Triggers).Count -ne 2 -or @($task.Actions).Count -ne 1 -or
            [string] $task.Settings.MultipleInstances -ine 'Queue' -or
            -not [bool] $task.Settings.StartWhenAvailable -or
            [bool] $task.Settings.DisallowStartIfOnBatteries -or
            [bool] $task.Settings.StopIfGoingOnBatteries -or
            [string] $task.Actions[0].Execute -ine $powershell -or
            [string] $task.Actions[0].Arguments -cne $arguments) {
            throw '显示器名称维护任务回读不一致'
        }
    } catch {
        $registrationError = $_.Exception.Message
        try {
            Remove-MonitorProjectionTaskVerified
            if ($null -ne $previousTaskXml) {
                Register-ScheduledTask -TaskName $TaskName -TaskPath '\' `
                    -Xml $previousTaskXml -Force -ErrorAction Stop | Out-Null
                if ($null -eq (Get-MonitorProjectionTask)) {
                    throw '旧显示器任务恢复后不可见'
                }
            }
        } catch {
            throw ('显示器任务注册失败且回滚失败：' + $registrationError +
                '；cleanup=' + $_.Exception.Message)
        }
        throw $registrationError
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw '必须使用管理员权限运行'
    }

    $manifestFile = Assert-PlainPayloadFile -Path $ManifestPath
    $projectorFile = Assert-PlainPayloadFile -Path $ProjectorPath
    $entries = @(Read-MonitorManifest -Path $manifestFile)
    $target = Find-ManagedMonitor -Entries $entries
    $instanceId = [string] $target.Device.InstanceId
    $entry = $target.Entry
    $expectedHardwareId = [string] $entry.hardware_id
    $hardwareIds = @(
        Get-DevicePropertyValues -InstanceId $instanceId `
            -KeyName 'DEVPKEY_Device_HardwareIds'
    )
    if (@($hardwareIds | Where-Object {
                [string] $_ -ieq $expectedHardwareId
            }).Count -ne 1) {
        throw ('Monitor HardwareID 与清单不一致：' + ($hardwareIds -join '; '))
    }

    $previousFriendlyName = @(
        Get-DevicePropertyValues -InstanceId $instanceId `
            -KeyName 'DEVPKEY_Device_FriendlyName'
    )
    $previousFriendlyName = @($previousFriendlyName | Where-Object {
            -not [string]::IsNullOrEmpty([string] $_)
        })
    if ($previousFriendlyName.Count -gt 1) {
        throw ('FriendlyName 快照不唯一：' + ($previousFriendlyName -join '; '))
    }
    $before = Get-ProtectedMonitorState -InstanceId $instanceId
    $projectionAttempted = $false
    try {
        $projectionAttempted = $true
        & $projectorFile $instanceId --set ([string] $entry.friendly_name)
        if ($LASTEXITCODE -ne 0) {
            throw ('FriendlyName 投影器退出码=' + $LASTEXITCODE)
        }
        $friendlyName = @(
            Get-DevicePropertyValues -InstanceId $instanceId `
                -KeyName 'DEVPKEY_Device_FriendlyName'
        )
        if ($friendlyName.Count -ne 1 -or
            $friendlyName[0] -cne [string] $entry.friendly_name) {
            throw ('FriendlyName 回读不一致：' + ($friendlyName -join '; '))
        }
        $displayName = @(
            Get-DevicePropertyValues -InstanceId $instanceId `
                -KeyName 'DEVPKEY_NAME'
        )
        if ($displayName.Count -ne 1 -or
            $displayName[0] -cne [string] $entry.friendly_name) {
            throw ('设备管理器名称回读不一致：' + ($displayName -join '; '))
        }
        $after = Get-ProtectedMonitorState -InstanceId $instanceId
        Assert-ProtectedMonitorStateUnchanged -Before $before -After $after

        $device = Get-PnpDevice -InstanceId $instanceId -ErrorAction Stop
        $problem = @(
            Get-DevicePropertyValues -InstanceId $instanceId `
                -KeyName 'DEVPKEY_Device_ProblemCode'
        )
        if ([string] $device.Status -ine 'OK' -or $problem.Count -ne 1 -or
            [int] $problem[0] -ne 0) {
            throw ('显示器状态异常：Status=' + $device.Status +
                ' ProblemCode=' + ($problem -join ','))
        }

        if ($RegisterTask) {
            $scriptFile = Assert-PlainPayloadFile -Path $PSCommandPath
            Register-MonitorProjectionTask -ScriptPath $scriptFile `
                -Manifest $manifestFile -Projector $projectorFile
        }
    } catch {
        $projectionError = $_.Exception.Message
        if ($projectionAttempted) {
            try {
                Restore-MonitorFriendlyName -Projector $projectorFile `
                    -InstanceId $instanceId -Previous $previousFriendlyName
            } catch {
                throw ('显示器投影失败且 FriendlyName 回滚失败：' +
                    $projectionError + '；rollback=' + $_.Exception.Message)
            }
        }
        throw $projectionError
    }
    Write-Host ('  显示器名称：' + $expectedHardwareId + ' -> ' +
        [string] $entry.friendly_name) -ForegroundColor Green
    exit 0
} catch {
    Stop-MonitorProjection -Message $_.Exception.Message
}
