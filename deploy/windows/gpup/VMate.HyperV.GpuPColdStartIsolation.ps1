#Requires -Version 5.1

<#
.SYNOPSIS
    只用于恢复历史未完成事务的 GPU-P adapter 快照模块。

.DESCRIPTION
    旧 paused-CPUID 实验曾在 Off 状态摘除 adapter，并尝试在 Paused 状态恢复。
    该序列已在 Win10 19045 复现 vmwp/vmuidevices access violation 和 dxgkrnl
    BugCheck 0x3B，现已永久停用。保留本模块只为读取旧事务日志，并在 VM 为 Off
    时按原十二项配额恢复 adapter；新流程绝不创建事务、摘除或热加 adapter。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonModule = Join-Path $PSScriptRoot 'VMate.GpuP.Common.ps1'
if (-not (Get-Command Get-VMateGpuPHostPartitionableGpu `
        -CommandType Function -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path -LiteralPath $commonModule -PathType Leaf)) {
        throw "GPU-P 公共模块不存在：$commonModule"
    }
    . $commonModule
}

function Get-VMateHyperVGpuPQuotaNames {
    $names = [Collections.Generic.List[string]]::new()
    foreach ($resource in @('VRAM', 'Encode', 'Decode', 'Compute')) {
        foreach ($bound in @('Min', 'Max', 'Optimal')) {
            [void]$names.Add("${bound}Partition$resource")
        }
    }
    return @($names)
}

function ConvertTo-VMateHyperVGpuPQuota {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try { return [Convert]::ToUInt64([string]$Value) }
    catch { throw "$Label 不是有效的 UInt64：$Value" }
}

function Get-VMateHyperVGpuPColdStartAdapterSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][string]$GpuInstancePath
    )

    if ([string]$VM.State -cne 'Off') {
        throw "GPU-P 冷启动快照要求 VM 为 Off；当前 $($VM.State)。"
    }
    if ([String]::IsNullOrWhiteSpace($GpuInstancePath)) {
        throw 'GPU-P 冷启动隔离缺少持久化物理 GPU InstancePath。'
    }
    $adapters = @(Get-VMGpuPartitionAdapter -VM $VM -ErrorAction Stop)
    if ($adapters.Count -ne 1) {
        throw "GPU-P 冷启动隔离要求恰好一个 adapter；实际 $($adapters.Count)。"
    }
    $adapter = $adapters[0]
    $quotas = [ordered]@{}
    foreach ($name in @(Get-VMateHyperVGpuPQuotaNames)) {
        $property = $adapter.PSObject.Properties[$name]
        if ($null -eq $property) { throw "GPU-P adapter 缺少配额 $name。" }
        # JSON 中用十进制字符串保存，避免 UInt64.MaxValue 被旧 PowerShell
        # ConvertFrom-Json 转成 Double 后丢失精度。
        $quotas[$name] = ([uint64](ConvertTo-VMateHyperVGpuPQuota `
                    $property.Value "GPU-P adapter.$name")).ToString()
    }
    $reportedPath = ''
    $pathProperty = $adapter.PSObject.Properties['InstancePath']
    if ($null -ne $pathProperty) { $reportedPath = [string]$pathProperty.Value }
    if (-not [String]::IsNullOrWhiteSpace($reportedPath) -and
        -not [string]::Equals($reportedPath, $GpuInstancePath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'GPU-P adapter 的 InstancePath 与持久化 GPU 绑定不一致。'
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = 'vmate-p11-gpup-adapter-snapshot-v1'
        VMName = [string]$VM.Name
        VMId = ([Guid]$VM.Id).ToString('D')
        GpuInstancePath = $GpuInstancePath
        ReportedInstancePath = $reportedPath
        AdapterId = [string]$adapter.Id
        Quotas = [pscustomobject]$quotas
    }
}

function Get-VMateHyperVGpuPColdStartQuotaParameters {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    if ([int]$Snapshot.SchemaVersion -ne 1 -or
        [string]$Snapshot.ContractId -cne
            'vmate-p11-gpup-adapter-snapshot-v1') {
        throw 'GPU-P 冷启动 adapter 快照 contract 无效。'
    }
    $parameters = @{}
    foreach ($name in @(Get-VMateHyperVGpuPQuotaNames)) {
        $property = $Snapshot.Quotas.PSObject.Properties[$name]
        if ($null -eq $property) { throw "GPU-P adapter 快照缺少 $name。" }
        $parameters[$name] = ConvertTo-VMateHyperVGpuPQuota `
            $property.Value "GPU-P adapter 快照.$name"
    }
    return $parameters
}

function Assert-VMateHyperVGpuPColdStartAdapterRestored {
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    $adapters = @(Get-VMGpuPartitionAdapter -VM $VM -ErrorAction Stop)
    if ($adapters.Count -ne 1) {
        throw "GPU-P adapter 恢复后必须恰好一个；实际 $($adapters.Count)。"
    }
    $expected = Get-VMateHyperVGpuPColdStartQuotaParameters $Snapshot
    foreach ($name in $expected.Keys) {
        $actual = ConvertTo-VMateHyperVGpuPQuota `
            $adapters[0].PSObject.Properties[$name].Value `
            "恢复后的 GPU-P adapter.$name"
        if ($actual -ne [uint64]$expected[$name]) {
            throw "GPU-P adapter 恢复后 $name 回读不一致。"
        }
    }
    return $adapters[0]
}

function Add-VMateHyperVGpuPColdStartAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    $current = Get-VM -Name ([string]$VM.Name) -ErrorAction Stop
    if ([string]$current.State -cne 'Off') {
        throw "GPU-P adapter 只允许在 Off 状态恢复；当前 $($current.State)。"
    }
    $existing = @(Get-VMGpuPartitionAdapter -VM $current -ErrorAction Stop)
    if ($existing.Count -eq 1) {
        return Assert-VMateHyperVGpuPColdStartAdapterRestored `
            -VM $current -Snapshot $Snapshot
    }
    if ($existing.Count -ne 0) {
        throw "GPU-P adapter 恢复前数量异常：$($existing.Count)。"
    }

    $add = Get-Command Add-VMGpuPartitionAdapter -ErrorAction Stop
    if (-not $add.Parameters.ContainsKey('Passthru')) {
        throw 'Add-VMGpuPartitionAdapter 缺少事务所需的 Passthru。'
    }
    $parameters = Get-VMateHyperVGpuPColdStartQuotaParameters $Snapshot
    $parameters['VM'] = $current
    $parameters['Passthru'] = $true
    $parameters['Confirm'] = $false
    $parameters['ErrorAction'] = 'Stop'
    if ($add.Parameters.ContainsKey('InstancePath')) {
        $parameters['InstancePath'] = [string]$Snapshot.GpuInstancePath
    }
    else {
        $hostGpus = @(Get-VMateGpuPHostPartitionableGpu)
        if ($hostGpus.Count -ne 1) {
            throw ('当前 Win10 Add-VMGpuPartitionAdapter 不支持 InstancePath，' +
                "宿主必须恰好一张 partitionable GPU；实际 $($hostGpus.Count)。")
        }
        $hostPath = [string]$hostGpus[0].Name
        if (-not [string]::Equals($hostPath,
                [string]$Snapshot.GpuInstancePath,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw '唯一 partitionable GPU 与持久化绑定不一致。'
        }
    }
    [void](Add-VMGpuPartitionAdapter @parameters)
    return Assert-VMateHyperVGpuPColdStartAdapterRestored `
        -VM (Get-VM -Name $current.Name -ErrorAction Stop) -Snapshot $Snapshot
}

function Remove-VMateHyperVGpuPColdStartAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    throw ('GPU-P cold-start adapter 摘除路径已停用：adapter 必须从 Off ' +
        '到 Running 全程保持绑定。')
}

function Get-VMateHyperVGpuPColdStartTransactionPath {
    param([Parameter(Mandatory = $true)][Guid]$VMId)

    $commonData = [Environment]::GetFolderPath('CommonApplicationData')
    if ([String]::IsNullOrWhiteSpace($commonData)) {
        throw '无法解析 ProgramData，不能记录 GPU-P 冷启动事务。'
    }
    return Join-Path $commonData (
        'VMate\GpuP\cold-start-transactions\' +
        $VMId.ToString('D') + '.json')
}

function Write-VMateHyperVGpuPColdStartTransaction {
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$Document
    )

    $path = Get-VMateHyperVGpuPColdStartTransactionPath $VMId
    $directory = [IO.Path]::GetDirectoryName($path)
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $temporary = Join-Path $directory (
        '.cold-start.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary,
            ($Document | ConvertTo-Json -Depth 8),
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
    }
    return $path
}

function Set-VMateHyperVGpuPColdStartTransactionPhase {
    param(
        [Parameter(Mandatory = $true)][object]$Transaction,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    $Transaction.Phase = $Phase
    $Transaction.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    [void](Write-VMateHyperVGpuPColdStartTransaction `
            -VMId ([Guid]$Transaction.VMId) -Document $Transaction)
}

function New-VMateHyperVGpuPColdStartTransaction {
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $document = [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = 'vmate-p11-gpup-cold-start-transaction-v1'
        VMName = [string]$VM.Name
        VMId = ([Guid]$VM.Id).ToString('D')
        HostBootUtc = ([DateTime]$os.LastBootUpTime).ToUniversalTime().ToString('o')
        Phase = 'Prepared'
        Adapter = $Snapshot
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    [void](Write-VMateHyperVGpuPColdStartTransaction `
            -VMId ([Guid]$VM.Id) -Document $document)
    return $document
}

function Remove-VMateHyperVGpuPColdStartTransaction {
    param([Parameter(Mandatory = $true)][Guid]$VMId)

    Remove-Item -LiteralPath (
        Get-VMateHyperVGpuPColdStartTransactionPath $VMId) -Force `
        -ErrorAction SilentlyContinue
}

function Repair-VMateHyperVGpuPColdStartTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    $path = Get-VMateHyperVGpuPColdStartTransactionPath ([Guid]$VM.Id)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'NoTransaction'; Path = $path }
    }
    try {
        $transaction = Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw "GPU-P 冷启动恢复日志损坏：$($_.Exception.Message)" }
    if ([int]$transaction.SchemaVersion -ne 1 -or
        [string]$transaction.ContractId -cne
            'vmate-p11-gpup-cold-start-transaction-v1' -or
        [Guid]$transaction.VMId -ne [Guid]$VM.Id -or
        [string]$transaction.VMName -cne [string]$VM.Name) {
        throw 'GPU-P 冷启动恢复日志与目标 VM 不一致。'
    }
    $current = Get-VM -Name ([string]$VM.Name) -ErrorAction Stop
    if ([string]$current.State -cne 'Off') {
        Stop-VM -VM $current -TurnOff -Force -Confirm:$false `
            -ErrorAction Stop
        $current = Get-VM -Name ([string]$VM.Name) -ErrorAction Stop
    }
    [void](Add-VMateHyperVGpuPColdStartAdapter `
            -VM $current -Snapshot $transaction.Adapter)
    Remove-VMateHyperVGpuPColdStartTransaction ([Guid]$VM.Id)
    return [pscustomobject]@{
        Status = 'Recovered'
        Path = $path
        PreviousPhase = [string]$transaction.Phase
        AdapterCount = @(Get-VMGpuPartitionAdapter -VM $current).Count
    }
}
