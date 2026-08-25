#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    在实验宿主上回归 P-11 单显示 GPU-P 冷启动链路。

.DESCRIPTION
    仅操作显式指定的 P-11 VM。脚本先确认样例 VM 均为 Off，再通过来宾
    shutdown.exe 正常关机，执行固定 artifact manifest 的暂停态冷启动与来宾
    身份确认，最后回读唯一显示节点、Enhanced Session 和 receipt 完整性。
    GuestCredential 只在调用进程内使用，不写入结果或磁盘。
#>

[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [string[]]$ReadOnlySampleVMNames = @('pc01', 'pc02'),
    [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
    [Parameter(Mandatory = $true)][string]$GpuPToolsRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$ArtifactManifestPath,
    [Parameter(Mandatory = $true)][string]$CpuidProbePath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedCpuidProbeSha256,
    [Parameter(Mandatory = $true)][string]$DisplayTopologyReceiptPath,
    [string]$MetadataExchangeReceiptPath = '',
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$StatusPath,
    [ValidateRange(30, 300)][int]$ShutdownTimeoutSeconds = 120,
    [ValidateRange(30, 300)][int]$ReadinessTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $GpuPToolsRoot 'VMate.HyperV.DisplayTopology.ps1')
. (Join-Path $GpuPToolsRoot 'VMate.HyperV.EnhancedSession.ps1')
. (Join-Path $GpuPToolsRoot 'VMate.HyperV.MetadataExchange.ps1')
Import-Module Hyper-V -ErrorAction Stop

function Write-VMateP11ColdRegressionJson {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(2, 30)][int]$Depth = 10
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [IO.File]::WriteAllText(
        $fullPath,
        ($Value | ConvertTo-Json -Depth $Depth),
        (New-Object Text.UTF8Encoding($false)))
}

function Get-VMateP11SampleState {
    return @(Get-VM -Name $ReadOnlySampleVMNames -ErrorAction Stop |
        Sort-Object Name | Select-Object Name, State)
}

$status = [ordered]@{
    SchemaVersion = 1
    Status = 'Running'
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    CredentialPersisted = $false
}
Write-VMateP11ColdRegressionJson -Value ([pscustomobject]$status) `
    -Path $StatusPath

try {
    $requiredFiles = @(
            $ArtifactManifestPath,
            $CpuidProbePath,
            $DisplayTopologyReceiptPath,
            (Join-Path $GpuPToolsRoot 'Start-VMateGpuPVM.ps1'),
            (Join-Path $GpuPToolsRoot 'Confirm-VMateGpuPVMIdentity.ps1'))
    $validateMetadataExchange =
        -not [String]::IsNullOrWhiteSpace($MetadataExchangeReceiptPath)
    if ($validateMetadataExchange) {
        $requiredFiles += $MetadataExchangeReceiptPath
    }
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "冷启动回归依赖不存在：$requiredFile"
        }
    }

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ([string]$vm.State -cne 'Running') {
        throw "回归开始时 $VMName 必须为 Running；当前 $($vm.State)。"
    }
    $sampleBefore = Get-VMateP11SampleState
    if (@($sampleBefore | Where-Object {
                [string]$_.State -cne 'Off'
            }).Count -ne 0) {
        throw '只读样例 VM 必须均为 Off；拒绝继续。'
    }

    $identityPath = Join-Path $StateRoot (
        ([Guid]$vm.Id).ToString('D') + '\identity.json')
    $identityBefore = Get-Content -LiteralPath $identityPath -Raw `
        -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $previousBootId =
        [string]$identityBefore.HostIdentityExtension.Attestation.BootId
    if ([String]::IsNullOrWhiteSpace($previousBootId)) {
        throw '回归前身份记录缺少 BootId。'
    }

    $topologyBefore = Get-VMateHyperVDisplayTopologySnapshot -VMName $VMName
    if ([string]$topologyBefore.Mode -cne 'EnhancedSessionGpuOnly') {
        throw '回归前显示拓扑不是 EnhancedSessionGpuOnly。'
    }
    $receiptHashBefore = [string](Get-FileHash -Algorithm SHA256 `
        -LiteralPath $DisplayTopologyReceiptPath).Hash
    $metadataBefore = $null
    $metadataReceiptHashBefore = ''
    if ($validateMetadataExchange) {
        $metadataBefore = [pscustomobject][ordered]@{
            Host = Get-VMateHyperVMetadataExchangeHostSnapshot -VMName $VMName
            Guest = Get-VMateHyperVMetadataExchangeGuestSnapshot `
                -VMName $VMName -GuestCredential $GuestCredential
        }
        if ([bool]$metadataBefore.Host.IntegrationServiceEnabled -or
            [bool]$metadataBefore.Guest.ParametersKeyExists -or
            [string]$metadataBefore.Guest.GuestServiceState -cne 'Stopped') {
            throw '回归前 metadata exchange 不是 MinimalHostMetadata。'
        }
        $metadataReceiptHashBefore = [string](Get-FileHash `
            -Algorithm SHA256 -LiteralPath $MetadataExchangeReceiptPath).Hash
    }

    # shutdown.exe 在来宾内立即排队关机；连接中断只有在 VM 确实进入 Off 后才视为正常。
    $shutdownError = ''
    try {
        $shutdownExitCode = Invoke-Command -VMName $VMName `
            -Credential $GuestCredential -ErrorAction Stop -ScriptBlock {
            & "$env:SystemRoot\System32\shutdown.exe" /s /t 0 /f /d p:4:1 `
                /c 'VMate P11 cold-start regression'
            return $LASTEXITCODE
        }
        if ([int]$shutdownExitCode -ne 0) {
            throw "guest shutdown.exe 退出码为 $shutdownExitCode。"
        }
    }
    catch { $shutdownError = $_.Exception.Message }

    $deadline = [DateTime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
    do {
        Start-Sleep -Seconds 1
        $vm = Get-VM -Name $VMName -ErrorAction Stop
    } while ([string]$vm.State -cne 'Off' -and
        [DateTime]::UtcNow -lt $deadline)
    if ([string]$vm.State -cne 'Off') {
        throw "来宾关机超时：$shutdownError"
    }

    $topologyOff = Get-VMateHyperVDisplayTopologySnapshot -VMName $VMName
    if ([string]$topologyOff.Mode -cne 'EnhancedSessionGpuOnly' -or
        [int]$topologyOff.SyntheticDisplayCount -ne 0 -or
        [int]$topologyOff.GpuPartitionAdapterCount -ne 1) {
        throw 'VM 关机后单显示拓扑发生变化。'
    }
    $metadataHostOff = if ($validateMetadataExchange) {
        Get-VMateHyperVMetadataExchangeHostSnapshot -VMName $VMName
    } else { $null }
    if ($validateMetadataExchange -and
        [bool]$metadataHostOff.IntegrationServiceEnabled) {
        throw 'VM 关机后 KVP integration service 意外启用。'
    }

    $start = & (Join-Path $GpuPToolsRoot 'Start-VMateGpuPVM.ps1') `
        -VMName $VMName -StateRoot $StateRoot `
        -ArtifactManifestPath $ArtifactManifestPath `
        -StartupTimeoutSeconds 20 -MaxPausedUptimeSeconds 30
    $confirm = & (Join-Path $GpuPToolsRoot `
            'Confirm-VMateGpuPVMIdentity.ps1') `
        -VMName $VMName -GuestCredential $GuestCredential `
        -CpuidProbePath $CpuidProbePath `
        -ExpectedCpuidProbeSha256 $ExpectedCpuidProbeSha256 `
        -StateRoot $StateRoot `
        -ReadinessTimeoutSeconds $ReadinessTimeoutSeconds

    $topologyAfter = Get-VMateHyperVDisplayTopologySnapshot -VMName $VMName
    $enhanced = Get-VMateHyperVEnhancedSessionStatus -VMName $VMName `
        -GuestCredential $GuestCredential
    $guest = Invoke-Command -VMName $VMName -Credential $GuestCredential `
        -ErrorAction Stop -ScriptBlock {
        $display = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { [string]$_.PNPClass -ceq 'Display' } |
            Select-Object Name, PNPDeviceID, Status, ConfigManagerErrorCode,
                Manufacturer, Service)
        $processor = Get-CimInstance Win32_Processor -ErrorAction Stop |
            Select-Object -First 1 Name, Manufacturer, Description,
                NumberOfCores, NumberOfLogicalProcessors
        $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop |
            Select-Object -First 1 Manufacturer, Product, Version, SerialNumber
        $smi = @(& nvidia-smi.exe `
            --query-gpu=name,driver_version,memory.total,utilization.gpu `
            --format=csv,noheader 2>&1 | ForEach-Object { $_.ToString() })
        $smiExitCode = $LASTEXITCODE
        return [pscustomobject][ordered]@{
            Display = $display
            DisplayCount = $display.Count
            Processor = $processor
            BaseBoard = $board
            NvidiaSmi = $smi
            NvidiaSmiExitCode = $smiExitCode
        }
    }
    $receiptHashAfter = [string](Get-FileHash -Algorithm SHA256 `
        -LiteralPath $DisplayTopologyReceiptPath).Hash
    $sampleAfter = Get-VMateP11SampleState
    $displayAfter = @($guest.Display)
    $metadataAfter = $null
    $metadataReceiptHashAfter = ''
    if ($validateMetadataExchange) {
        $metadataAfter = [pscustomobject][ordered]@{
            Host = Get-VMateHyperVMetadataExchangeHostSnapshot -VMName $VMName
            Guest = Get-VMateHyperVMetadataExchangeGuestSnapshot `
                -VMName $VMName -GuestCredential $GuestCredential
        }
        $metadataReceiptHashAfter = [string](Get-FileHash `
            -Algorithm SHA256 -LiteralPath $MetadataExchangeReceiptPath).Hash
    }

    if ([string]$topologyAfter.Mode -cne 'EnhancedSessionGpuOnly' -or
        $displayAfter.Count -ne 1 -or
        [string]$displayAfter[0].Name -cne 'NVIDIA GeForce RTX 4060 Ti' -or
        [string]$displayAfter[0].Service -ine 'VirtualRender' -or
        [int]$displayAfter[0].ConfigManagerErrorCode -ne 0 -or
        [int]$guest.NvidiaSmiExitCode -ne 0 -or
        -not [bool]$enhanced.Ready) {
        throw '冷启动后的单显示、GPU-P 或 Enhanced Session 回读失败。'
    }
    if ([string]$confirm.Readback.BootId -ceq $previousBootId) {
        throw '冷启动没有发布新的 BootId。'
    }
    if ($receiptHashBefore -cne $receiptHashAfter) {
        throw '冷启动期间显示拓扑 receipt 被改写。'
    }
    if ($validateMetadataExchange -and (
            [bool]$metadataAfter.Host.IntegrationServiceEnabled -or
            [bool]$metadataAfter.Guest.ParametersKeyExists -or
            [string]$metadataAfter.Guest.GuestServiceState -cne 'Stopped' -or
            $metadataReceiptHashBefore -cne $metadataReceiptHashAfter)) {
        throw '冷启动后的 MinimalHostMetadata 状态或 receipt 不一致。'
    }
    if (@($sampleAfter | Where-Object {
                [string]$_.State -cne 'Off'
            }).Count -ne 0) {
        throw 'P-11 回归期间样例 VM 生命周期发生变化。'
    }

    $result = [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = 'vmate-p11-single-display-cold-regression-v1'
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        PreviousBootId = $previousBootId
        NewBootId = [string]$confirm.Readback.BootId
        SampleVMsBefore = $sampleBefore
        SampleVMsAfter = $sampleAfter
        TopologyBefore = $topologyBefore
        TopologyOff = $topologyOff
        TopologyAfter = $topologyAfter
        DisplayTopologyReceiptSha256 = $receiptHashAfter
        MetadataExchangeBefore = $metadataBefore
        MetadataExchangeOff = $metadataHostOff
        MetadataExchangeAfter = $metadataAfter
        MetadataExchangeReceiptSha256 = $metadataReceiptHashAfter
        ShutdownTransientError = $shutdownError
        ColdStart = $start
        Confirmation = $confirm
        EnhancedSession = $enhanced
        Guest = $guest
        CredentialPersisted = $false
        Passed = $true
    }
    Write-VMateP11ColdRegressionJson -Value $result -Path $OutputPath `
        -Depth 18

    $status.Status = 'Passed'
    $status.PreviousBootId = $previousBootId
    $status.NewBootId = [string]$confirm.Readback.BootId
    $status.TopologyMode = [string]$topologyAfter.Mode
    $status.DisplayCount = [int]$guest.DisplayCount
    $status.GpuName = [string]$displayAfter[0].Name
    $status.EnhancedSessionReady = [bool]$enhanced.Ready
    $status.MinimalHostMetadata = if ($validateMetadataExchange) {
        -not [bool]$metadataAfter.Host.IntegrationServiceEnabled -and
        -not [bool]$metadataAfter.Guest.ParametersKeyExists -and
        [string]$metadataAfter.Guest.GuestServiceState -ceq 'Stopped'
    } else { $null }
}
catch {
    $status.Status = 'Failed'
    $status.Error = $_.Exception.Message
    $status.Position = $_.InvocationInfo.PositionMessage
    try { $status.P11State = [string](Get-VM -Name $VMName).State } catch {}
}
finally {
    $status.CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-VMateP11ColdRegressionJson -Value ([pscustomobject]$status) `
        -Path $StatusPath
}

if ([string]$status.Status -cne 'Passed') {
    throw [string]$status.Error
}
