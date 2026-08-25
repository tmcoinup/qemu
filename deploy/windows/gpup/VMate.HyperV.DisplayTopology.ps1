#Requires -Version 5.1

<#
.SYNOPSIS
    事务化管理 GPU-P VM 的 Hyper-V 合成显示控制器。

.DESCRIPTION
    EnhancedSessionGpuOnly 模式从关机 VM 配置中移除合成显示控制器，保留唯一
    GPU-P partition adapter，并固定由 VMConnect Enhanced Session 提供交互显示。
    本模块只使用 Hyper-V WMI 资源接口；不修改 guest ClassGUID、PnP devnode、
    驱动或代码完整性策略。每次移除前都写入可恢复 receipt。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.HyperV.ConsoleProfile.ps1')

$script:VMateHyperVNamespace = 'root\virtualization\v2'
$script:VMateSyntheticDisplaySubType =
    'Microsoft:Hyper-V:Synthetic Display Controller'
$script:VMateDisplayTopologyContract =
    'vmate-hyperv-gpup-display-topology-v1'

function Get-VMateHyperVDisplayVssd {
    param([Parameter(Mandatory = $true)][object]$VM)

    $vmId = ([Guid]$VM.Id).ToString('D')
    $rows = @(Get-CimInstance -Namespace $script:VMateHyperVNamespace `
            -ClassName Msvm_VirtualSystemSettingData `
            -Filter "VirtualSystemIdentifier='$vmId'" -ErrorAction Stop |
        Where-Object {
            [string]$_.VirtualSystemIdentifier -ieq $vmId -and
            [string]$_.VirtualSystemType -ceq
                'Microsoft:Hyper-V:System:Realized'
        })
    if ($rows.Count -ne 1) {
        throw "VM [$($VM.Name)] realized VSSD 必须恰好一条，实际 $($rows.Count)。"
    }
    return $rows[0]
}

function Get-VMateHyperVSyntheticDisplayResources {
    param([Parameter(Mandatory = $true)][object]$VM)

    $vssd = Get-VMateHyperVDisplayVssd -VM $VM
    return @(Get-CimAssociatedInstance -InputObject $vssd `
            -Association Msvm_VirtualSystemSettingDataComponent `
            -ErrorAction Stop | Where-Object {
                $_.CimClass.CimClassName -ceq
                    'Msvm_SyntheticDisplayControllerSettingData' -and
                [string]$_.ResourceSubType -ceq
                    $script:VMateSyntheticDisplaySubType
            })
}

function Get-VMateHyperVDisplayTopologySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$VMName)

    Import-Module Hyper-V -ErrorAction Stop
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $display = @(Get-VMateHyperVSyntheticDisplayResources -VM $vm)
    $gpu = @(Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)
    $console = if ($display.Count -eq 1) {
        Get-VMateHyperVConsoleSnapshot -VM $vm
    } else { $null }
    $hostState = Get-VMHost -ErrorAction Stop
    return [pscustomobject][ordered]@{
        VMName = [string]$vm.Name
        VMId = ([Guid]$vm.Id).ToString('D')
        VMState = [string]$vm.State
        VMVersion = [string]$vm.Version
        EnhancedSessionTransportType =
            [string]$vm.EnhancedSessionTransportType
        HostEnhancedSessionEnabled =
            [bool]$hostState.EnableEnhancedSessionMode
        SyntheticDisplayCount = $display.Count
        SyntheticDisplayInstanceIds = @($display | ForEach-Object {
                [string]$_.InstanceID
            })
        GpuPartitionAdapterCount = $gpu.Count
        Console = $console
        Mode = if ($display.Count -eq 0 -and $gpu.Count -eq 1) {
            'EnhancedSessionGpuOnly'
        } elseif ($display.Count -eq 1 -and $gpu.Count -eq 1) {
            'SyntheticConsoleAndGpuP'
        } else { 'Unsupported' }
    }
}

function Write-VMateHyperVDisplayTopologyReceipt {
    param(
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force `
            -ErrorAction Stop | Out-Null
    }
    $temporary = "$fullPath.$PID.tmp"
    $json = $Receipt | ConvertTo-Json -Depth 9
    try {
        [IO.File]::WriteAllText($temporary, $json,
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force `
            -ErrorAction Stop
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
    }
    return $fullPath
}

function Read-VMateHyperVDisplayTopologyReceipt {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "显示拓扑 receipt 不存在：$fullPath"
    }
    try {
        $receipt = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 `
            -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw "显示拓扑 receipt 无效：$($_.Exception.Message)" }
    if ([int]$receipt.SchemaVersion -ne 1 -or
        [string]$receipt.ContractId -cne
            $script:VMateDisplayTopologyContract) {
        throw '显示拓扑 receipt schema/contract 不受支持。'
    }
    return $receipt
}

function Wait-VMateHyperVDisplayCimJob {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [string]$Operation = 'Hyper-V resource operation'
    )

    $returnValue = [uint32]$Result.ReturnValue
    if ($returnValue -eq 0) { return }
    if ($returnValue -ne 4096 -or $null -eq $Result.Job) {
        throw "$Operation 失败，ReturnValue=$returnValue。"
    }
    $instanceId = [string]$Result.Job.InstanceID
    for ($attempt = 0; $attempt -lt 150; ++$attempt) {
        $job = @(Get-CimInstance -Namespace $script:VMateHyperVNamespace `
                -ClassName Msvm_ConcreteJob -ErrorAction Stop |
            Where-Object { [string]$_.InstanceID -ceq $instanceId })
        if ($job.Count -ne 1) {
            throw "$Operation 异步作业回读数量异常：$($job.Count)。"
        }
        if ([uint16]$job[0].JobState -eq 7) {
            if ([uint32]$job[0].ErrorCode -ne 0) {
                throw "$Operation 异步失败：$($job[0].ErrorDescription)"
            }
            return
        }
        if ([uint16]$job[0].JobState -in @(8, 9, 10)) {
            throw "$Operation 异步失败：$($job[0].ErrorDescription)"
        }
        Start-Sleep -Milliseconds 200
    }
    throw "$Operation 异步作业超时。"
}

function Remove-VMateHyperVSyntheticDisplayResource {
    param([Parameter(Mandatory = $true)][object]$VM)

    $resources = @(Get-VMateHyperVSyntheticDisplayResources -VM $VM)
    if ($resources.Count -ne 1) {
        throw "移除前合成显示控制器必须恰好一条，实际 $($resources.Count)。"
    }
    $service = Get-CimInstance -Namespace $script:VMateHyperVNamespace `
        -ClassName Msvm_VirtualSystemManagementService -ErrorAction Stop
    $result = Invoke-CimMethod -InputObject $service `
        -MethodName RemoveResourceSettings -Arguments @{
            ResourceSettings = [CimInstance[]]@($resources[0])
        } -ErrorAction Stop
    Wait-VMateHyperVDisplayCimJob -Result $result `
        -Operation 'RemoveResourceSettings(SyntheticDisplay)'
}

function Add-VMateHyperVSyntheticDisplayResource {
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$ConsoleProfile
    )

    $namespace = $script:VMateHyperVNamespace
    $settings = @(Get-WmiObject -Namespace $namespace `
            -Class Msvm_VirtualSystemSettingData -ErrorAction Stop |
        Where-Object {
            [string]$_.VirtualSystemIdentifier -ieq
                ([Guid]$VM.Id).ToString('D') -and
            [string]$_.VirtualSystemType -ceq
                'Microsoft:Hyper-V:System:Realized'
        })
    if ($settings.Count -ne 1) {
        throw "恢复时 realized VSSD 必须恰好一条，实际 $($settings.Count)。"
    }
    $default = @(Get-WmiObject -Namespace $namespace `
            -Class Msvm_SyntheticDisplayControllerSettingData `
            -ErrorAction Stop | Where-Object {
                [string]$_.InstanceID -match
                    '(?i)^Microsoft:Definition\\.*\\Default$' -and
                [string]$_.ResourceSubType -ceq
                    $script:VMateSyntheticDisplaySubType
            })
    if ($default.Count -ne 1) {
        throw "Hyper-V 默认合成显示 RASD 必须恰好一条，实际 $($default.Count)。"
    }
    $service = Get-WmiObject -Namespace $namespace `
        -Class Msvm_VirtualSystemManagementService -ErrorAction Stop
    $input = $service.GetMethodParameters('AddResourceSettings')
    $input.AffectedConfiguration = $settings[0].Path.Path
    $input.ResourceSettings = @($default[0].GetText(
            [Management.TextFormat]::CimDtd20))
    $output = $service.InvokeMethod('AddResourceSettings', $input, $null)
    if ([uint32]$output.ReturnValue -ne 0) {
        throw "AddResourceSettings(SyntheticDisplay) 失败，ReturnValue=$($output.ReturnValue)。"
    }
    $current = Get-VM -Name $VM.Name -ErrorAction Stop
    [void](Set-VMateHyperVConsoleProfile -VM $current `
            -Profile $ConsoleProfile)
}

function Set-VMateHyperVDisplayTopology {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [ValidateSet('EnhancedSessionGpuOnly')]
        [string]$Mode = 'EnhancedSessionGpuOnly',
        [switch]$DryRun
    )

    $before = Get-VMateHyperVDisplayTopologySnapshot -VMName $VMName
    if ([string]$before.VMState -cne 'Off') {
        throw "显示拓扑变更要求 VM 为 Off；当前 $($before.VMState)。"
    }
    if ($before.GpuPartitionAdapterCount -ne 1) {
        throw 'EnhancedSessionGpuOnly 要求恰好一个 GPU partition adapter。'
    }
    if ([string]$before.EnhancedSessionTransportType -cne 'VMBus' -or
        -not [bool]$before.HostEnhancedSessionEnabled) {
        throw 'Enhanced Session 必须先在宿主启用并固定使用 VMBus。'
    }
    if ($before.SyntheticDisplayCount -ne 1 -or $null -eq $before.Console) {
        throw "变更前合成显示控制器必须恰好一条，实际 $($before.SyntheticDisplayCount)。"
    }
    $status = 'Prepared'
    if ($DryRun) { $status = 'DryRun' }
    $receipt = [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = $script:VMateDisplayTopologyContract
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        VMName = $before.VMName
        VMId = $before.VMId
        Mode = $Mode
        Status = $status
        Before = $before
        Integrity = [pscustomobject][ordered]@{
            GuestPnpRegistryModified = $false
            GuestDriverModified = $false
            CodeIntegrityModified = $false
            RuntimeModelSwitch = $false
        }
    }
    if ($DryRun) { return $receipt }
    $receiptFile = Write-VMateHyperVDisplayTopologyReceipt `
        -Receipt $receipt -Path $ReceiptPath
    try {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        Remove-VMateHyperVSyntheticDisplayResource -VM $vm
        $after = Get-VMateHyperVDisplayTopologySnapshot -VMName $VMName
        if ($after.SyntheticDisplayCount -ne 0 -or
            $after.GpuPartitionAdapterCount -ne 1 -or
            [string]$after.Mode -cne 'EnhancedSessionGpuOnly') {
            throw '合成显示移除后拓扑回读不一致。'
        }
        $receipt.Status = 'Applied'
        $receipt | Add-Member -NotePropertyName AppliedAtUtc `
            -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $receipt | Add-Member -NotePropertyName After `
            -NotePropertyValue $after -Force
        [void](Write-VMateHyperVDisplayTopologyReceipt `
                -Receipt $receipt -Path $receiptFile)
    }
    catch {
        $primary = $_.Exception.Message
        try {
            $current = Get-VM -Name $VMName -ErrorAction Stop
            if (@(Get-VMateHyperVSyntheticDisplayResources `
                        -VM $current).Count -eq 0) {
                Add-VMateHyperVSyntheticDisplayResource -VM $current `
                    -ConsoleProfile $before.Console
            }
            $receipt.Status = 'RolledBack'
            [void](Write-VMateHyperVDisplayTopologyReceipt `
                    -Receipt $receipt -Path $receiptFile)
        }
        catch {
            throw "显示拓扑变更失败：$primary；自动恢复失败：$($_.Exception.Message)"
        }
        throw "显示拓扑变更失败：$primary；已恢复合成显示控制器。"
    }
    return $receipt
}

function Restore-VMateHyperVDisplayTopology {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )

    $receipt = Read-VMateHyperVDisplayTopologyReceipt -Path $ReceiptPath
    $snapshot = Get-VMateHyperVDisplayTopologySnapshot -VMName $VMName
    if ([string]$snapshot.VMState -cne 'Off') {
        throw "显示拓扑恢复要求 VM 为 Off；当前 $($snapshot.VMState)。"
    }
    if ([string]$receipt.VMName -cne [string]$snapshot.VMName -or
        [string]$receipt.VMId -cne [string]$snapshot.VMId) {
        throw '显示拓扑 receipt 与目标 VM 名称或 ID 不匹配。'
    }
    if ($snapshot.SyntheticDisplayCount -gt 1) {
        throw "合成显示控制器数量异常：$($snapshot.SyntheticDisplayCount)。"
    }
    if ($snapshot.SyntheticDisplayCount -eq 0) {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        Add-VMateHyperVSyntheticDisplayResource -VM $vm `
            -ConsoleProfile $receipt.Before.Console
    }
    else {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        [void](Set-VMateHyperVConsoleProfile -VM $vm `
                -Profile $receipt.Before.Console)
    }
    $after = Get-VMateHyperVDisplayTopologySnapshot -VMName $VMName
    if ($after.SyntheticDisplayCount -ne 1 -or
        $after.GpuPartitionAdapterCount -ne 1) {
        throw '显示拓扑恢复后回读不一致。'
    }
    $receipt.Status = 'Restored'
    $receipt | Add-Member -NotePropertyName RestoredAtUtc `
        -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $receipt | Add-Member -NotePropertyName Restored `
        -NotePropertyValue $after -Force
    [void](Write-VMateHyperVDisplayTopologyReceipt `
            -Receipt $receipt -Path $ReceiptPath)
    return $receipt
}
