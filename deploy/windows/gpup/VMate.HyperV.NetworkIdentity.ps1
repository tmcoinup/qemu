#Requires -Version 5.1

<#
.SYNOPSIS
    生成并事务应用 Hyper-V 虚拟网卡的稳定随机 MAC 身份。

.DESCRIPTION
    本模块只使用 Hyper-V 官方 StaticMacAddress 接口。生成过程由全局 allocator
    mutex 串行化，并同时盘点宿主全部 Hyper-V 网卡和既有 P-11 identity.json。
    上层负责把返回 fragment 写入 HardwareIdentity；本模块不自行创建网卡，也
    不修改身份清单。没有网卡时返回 NotPresent。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')

function Assert-VMateHyperVNetworkIdentityHost {
    if ($env:OS -cne 'Windows_NT') {
        throw 'Hyper-V 网络身份只能在 Windows 宿主机上配置。'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Hyper-V 网络身份配置需要管理员权限。'
    }
    foreach ($command in @('Get-VMNetworkAdapter', 'Set-VMNetworkAdapter')) {
        if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Hyper-V 命令不可用：$command"
        }
    }
}

function ConvertTo-VMateHyperVMacAddress {
    param([Parameter(Mandatory = $true)][string]$MacAddress)

    $normalized = ($MacAddress -replace '[-:\.]', '').ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{12}$') {
        throw "MAC 地址格式无效：$MacAddress"
    }
    return $normalized
}

function Assert-VMateHyperVLocalUnicastMacAddress {
    param([Parameter(Mandatory = $true)][string]$MacAddress)

    $normalized = ConvertTo-VMateHyperVMacAddress $MacAddress
    $first = [Convert]::ToByte($normalized.Substring(0, 2), 16)
    if (($first -band 1) -ne 0 -or ($first -band 2) -eq 0) {
        throw "MAC 必须是 locally-administered unicast：$MacAddress"
    }
    return $normalized
}

function New-VMateHyperVRandomMacAddress {
    $bytes = New-Object byte[] 5
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    # 固定 02 明确表示 locally-administered unicast，不冒用实体厂商 OUI。
    return '02' + (($bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Enter-VMateHyperVNetworkIdentityAllocator {
    param([ValidateRange(1, 120)][int]$TimeoutSeconds = 30)

    $mutex = [Threading.Mutex]::new(
        $false, 'Global\VMate.HyperV.NetworkIdentity.Allocator')
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw "等待 Hyper-V MAC allocator 锁超过 ${TimeoutSeconds}s。"
        }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-VMateHyperVNetworkIdentityAllocator {
    param([Parameter(Mandatory = $true)][Threading.Mutex]$Mutex)
    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Get-VMateHyperVNetworkIdentityStateRoot {
    param([string]$StateRoot = '')

    if (-not [String]::IsNullOrWhiteSpace($StateRoot)) {
        return [IO.Path]::GetFullPath($StateRoot)
    }
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    if ([String]::IsNullOrWhiteSpace($programData)) {
        throw '无法解析 CommonApplicationData，不能盘点 P-11 MAC 身份。'
    }
    return [IO.Path]::Combine($programData, 'VMate', 'GpuP')
}

function Get-VMateHyperVAdapterKey {
    param([Parameter(Mandatory = $true)][object]$Adapter)

    $property = $Adapter.PSObject.Properties['Id']
    if ($null -eq $property -or
        [String]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw 'Hyper-V 网卡缺少稳定 Id，拒绝用可重名的 Name 代替。'
    }
    return ([string]$property.Value).Trim()
}

function Get-VMateHyperVReservedNetworkIdentity {
    param([string]$StateRoot = '')

    $root = Get-VMateHyperVNetworkIdentityStateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $reservations = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter identity.json `
            -File -Recurse -ErrorAction Stop)) {
        $record = Read-VMateGpuPIdentityManifest -Path $file.FullName
        $hardwareProperty = $record.PSObject.Properties['HardwareIdentity']
        if ($null -eq $hardwareProperty) { continue }
        if ($null -eq $hardwareProperty.Value) {
            throw "P-11 HardwareIdentity 为空：$($file.FullName)"
        }
        $networkProperty = $hardwareProperty.Value.PSObject.Properties[
            'NetworkAdapters']
        if ($null -eq $networkProperty) {
            throw "P-11 HardwareIdentity 缺少 NetworkAdapters：$($file.FullName)"
        }
        $recordVmId = [Guid]::Empty
        if (-not [Guid]::TryParse([string]$record.VMId, [ref]$recordVmId) -or
            $recordVmId -eq [Guid]::Empty) {
            throw "P-11 网络身份的 VMId 无效：$($file.FullName)"
        }
        foreach ($item in @($networkProperty.Value)) {
            $macProperty = $item.PSObject.Properties['StaticMacAddress']
            if ($null -eq $macProperty) {
                $macProperty = $item.PSObject.Properties['MacAddress']
            }
            if ($null -eq $macProperty) {
                throw "P-11 网络身份条目缺少 MAC：$($file.FullName)"
            }
            if ([String]::IsNullOrWhiteSpace([string]$item.AdapterId)) {
                throw "P-11 网络身份条目缺少 AdapterId：$($file.FullName)"
            }
            $mac = Assert-VMateHyperVLocalUnicastMacAddress $macProperty.Value
            [void]$reservations.Add([pscustomobject][ordered]@{
                    VMId = $recordVmId.ToString('D')
                    AdapterId = [string]$item.AdapterId
                    StaticMacAddress = $mac
                    SourcePath = $file.FullName
                })
        }
    }
    return @($reservations)
}

function Get-VMateHyperVOccupiedMacAddresses {
    param([string]$StateRoot = '')

    $occupied = [Collections.Generic.List[object]]::new()
    # -All 盘点全部 guest vNIC；-ManagementOS 另外覆盖宿主管理 vNIC。
    $hostAdapters = @(Get-VMNetworkAdapter -All -ErrorAction Stop) +
        @(Get-VMNetworkAdapter -ManagementOS -ErrorAction Stop)
    foreach ($adapter in $hostAdapters) {
        if ([String]::IsNullOrWhiteSpace([string]$adapter.MacAddress)) { continue }
        $raw = ([string]$adapter.MacAddress -replace '[-:\.]', '')
        if ($raw -notmatch '^[0-9A-Fa-f]{12}$') { continue }
        [void]$occupied.Add([pscustomobject][ordered]@{
                VMId = if ($null -eq $adapter.PSObject.Properties['VMId']) {
                    ''
                } else { [string]$adapter.VMId }
                AdapterId = Get-VMateHyperVAdapterKey $adapter
                StaticMacAddress = $raw.ToUpperInvariant()
                SourcePath = 'Hyper-V'
            })
    }
    foreach ($reservation in @(Get-VMateHyperVReservedNetworkIdentity $StateRoot)) {
        [void]$occupied.Add($reservation)
    }
    return @($occupied)
}

function New-VMateHyperVNetworkIdentityFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [string]$StateRoot = ''
    )

    Assert-VMateHyperVNetworkIdentityHost
    $lock = Enter-VMateHyperVNetworkIdentityAllocator
    try {
        $vmId = [Guid]$VM.Id
        $vmAdapters = @(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop |
            Sort-Object { Get-VMateHyperVAdapterKey $_ })
        if ($vmAdapters.Count -eq 0) {
            return [pscustomobject][ordered]@{
                SchemaVersion = 1; Status = 'NotPresent'; NetworkAdapters = @()
            }
        }
        $used = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @(Get-VMateHyperVOccupiedMacAddresses $StateRoot)) {
            [void]$used.Add([string]$entry.StaticMacAddress)
        }
        $items = [Collections.Generic.List[object]]::new()
        foreach ($adapter in $vmAdapters) {
            $mac = $null
            for ($attempt = 0; $attempt -lt 256; $attempt++) {
                $candidate = New-VMateHyperVRandomMacAddress
                if ($used.Add($candidate)) { $mac = $candidate; break }
            }
            if ($null -eq $mac) { throw '生成唯一 Hyper-V MAC 连续碰撞 256 次。' }
            [void]$items.Add([pscustomobject][ordered]@{
                    AdapterId = Get-VMateHyperVAdapterKey $adapter
                    AdapterName = [string]$adapter.Name
                    StaticMacAddress = $mac
                })
        }
        return [pscustomobject][ordered]@{
            SchemaVersion = 1; Status = 'Planned'; NetworkAdapters = @($items)
        }
    }
    finally { Exit-VMateHyperVNetworkIdentityAllocator $lock }
}

function Assert-VMateHyperVNetworkIdentityFragment {
    param([Parameter(Mandatory = $true)][object]$Fragment)

    if ([int]$Fragment.SchemaVersion -ne 1 -or
        [string]$Fragment.Status -notin @('NotPresent', 'Planned')) {
        throw 'Hyper-V NetworkIdentity fragment schema 或状态无效。'
    }
    $ids = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $macs = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Fragment.NetworkAdapters)) {
        if ([String]::IsNullOrWhiteSpace([string]$item.AdapterId) -or
            -not $ids.Add([string]$item.AdapterId)) {
            throw 'NetworkIdentity 包含空白或重复 AdapterId。'
        }
        $mac = Assert-VMateHyperVLocalUnicastMacAddress $item.StaticMacAddress
        if (-not $macs.Add($mac)) { throw "NetworkIdentity MAC 重复：$mac" }
    }
    if (([string]$Fragment.Status -eq 'NotPresent') -ne
        (@($Fragment.NetworkAdapters).Count -eq 0)) {
        throw 'NetworkIdentity Status 与网卡数量不一致。'
    }
}

function Get-VMateHyperVNetworkIdentityObserved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$NetworkIdentity
    )

    Assert-VMateHyperVNetworkIdentityFragment $NetworkIdentity
    $actualById = @{}
    foreach ($adapter in @(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop)) {
        $actualById[(Get-VMateHyperVAdapterKey $adapter)] = $adapter
    }
    $rows = foreach ($expected in @($NetworkIdentity.NetworkAdapters)) {
        $actual = $actualById[[string]$expected.AdapterId]
        $actualMac = if ($null -eq $actual -or
            [String]::IsNullOrWhiteSpace([string]$actual.MacAddress)) {
            $null
        }
        else { ConvertTo-VMateHyperVMacAddress ([string]$actual.MacAddress) }
        [pscustomobject][ordered]@{
            AdapterId = [string]$expected.AdapterId
            Expected = [string]$expected.StaticMacAddress
            Actual = $actualMac
            Dynamic = if ($null -eq $actual) { $null } else {
                [bool]$actual.DynamicMacAddressEnabled
            }
            Match = $null -ne $actual -and
                -not [bool]$actual.DynamicMacAddressEnabled -and
                $actualMac -ceq [string]$expected.StaticMacAddress
        }
    }
    $expectedIds = @($NetworkIdentity.NetworkAdapters | ForEach-Object {
            [string]$_.AdapterId })
    $unexpected = @($actualById.Keys | Where-Object { $_ -notin $expectedIds })
    return [pscustomobject][ordered]@{
        Status = if ($actualById.Count -eq 0) { 'NotPresent' } else { 'Observed' }
        NetworkAdapters = @($rows)
        UnexpectedAdapterIds = $unexpected
        Match = @($rows | Where-Object { -not $_.Match }).Count -eq 0 -and
            $unexpected.Count -eq 0
    }
}

function Test-VMateHyperVNetworkIdentityCollision {
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$NetworkIdentity,
        [string]$StateRoot = ''
    )

    foreach ($expected in @($NetworkIdentity.NetworkAdapters)) {
        $mac = Assert-VMateHyperVLocalUnicastMacAddress $expected.StaticMacAddress
        foreach ($owner in @(Get-VMateHyperVOccupiedMacAddresses $StateRoot |
                Where-Object StaticMacAddress -eq $mac)) {
            $sameVm = [string]$owner.VMId -eq $VMId.ToString('D')
            $sameAdapter = [string]$owner.AdapterId -ieq [string]$expected.AdapterId
            # Hyper-V AdapterId 本身全局稳定；部分系统版本的对象不公开 VMId，
            # 此时同 AdapterId 仍可确认是目标本身。状态清单则必须同时匹配 VMId。
            $sameOwner = $sameAdapter -and ($sameVm -or
                [string]$owner.SourcePath -ceq 'Hyper-V')
            if (-not $sameOwner) {
                throw "静态 MAC 已被另一张 Hyper-V 网卡或 P-11 身份占用：$mac"
            }
        }
    }
}

function Set-VMateHyperVNetworkIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$NetworkIdentity,
        [string]$StateRoot = '',
        [switch]$DryRun
    )

    Assert-VMateHyperVNetworkIdentityHost
    $allocatorLock = Enter-VMateHyperVNetworkIdentityAllocator
    try {
    Assert-VMateHyperVNetworkIdentityFragment $NetworkIdentity
    if ([string]$VM.State -ne 'Off') { throw 'VM 必须为 Off 才能应用网络身份。' }
    $current = @{}
    foreach ($adapter in @(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop)) {
        $current[(Get-VMateHyperVAdapterKey $adapter)] = $adapter
    }
    if ([string]$NetworkIdentity.Status -eq 'NotPresent') {
        if ($current.Count -ne 0) { throw '清单为 NotPresent，但 VM 已出现网卡。' }
        return [pscustomobject][ordered]@{ Status = 'NotPresent'; Changed = 0 }
    }
    foreach ($expected in @($NetworkIdentity.NetworkAdapters)) {
        if (-not $current.ContainsKey([string]$expected.AdapterId)) {
            throw "清单中的 Hyper-V 网卡已不存在：$($expected.AdapterId)"
        }
    }
    if ($current.Count -ne @($NetworkIdentity.NetworkAdapters).Count) {
        throw 'VM 存在未纳入 NetworkIdentity 的额外网卡。'
    }
    Test-VMateHyperVNetworkIdentityCollision ([Guid]$VM.Id) `
        $NetworkIdentity $StateRoot
    if ($DryRun) {
        return [pscustomobject][ordered]@{ Status = 'Planned'; Changed = 0 }
    }

    $changed = [Collections.Generic.List[object]]::new()
    try {
        foreach ($expected in @($NetworkIdentity.NetworkAdapters)) {
            $adapter = $current[[string]$expected.AdapterId]
            $beforeDynamic = [bool]$adapter.DynamicMacAddressEnabled
            # 动态 MAC 在关机且从未启动的 VM 上可以为空。回滚动态策略不需要
            # 旧地址，因此只在原策略为静态时严格解析旧值。
            $beforeMac = if ($beforeDynamic) { $null } else {
                ConvertTo-VMateHyperVMacAddress ([string]$adapter.MacAddress)
            }
            $desired = Assert-VMateHyperVLocalUnicastMacAddress `
                $expected.StaticMacAddress
            if ($beforeDynamic -or $beforeMac -cne $desired) {
                [void]$changed.Add([pscustomobject]@{
                        Adapter = $adapter; AdapterId = [string]$expected.AdapterId
                        BeforeMac = $beforeMac; BeforeDynamic = $beforeDynamic })
                Set-VMNetworkAdapter -VMNetworkAdapter $adapter `
                    -StaticMacAddress $desired -Confirm:$false -ErrorAction Stop
            }
        }
        $observed = Get-VMateHyperVNetworkIdentityObserved $VM $NetworkIdentity
        if (-not $observed.Match) { throw '静态 MAC 写入后的回读不匹配。' }
        return [pscustomobject][ordered]@{
            Status = 'Applied'; Changed = $changed.Count; Observed = $observed
        }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        for ($index = $changed.Count - 1; $index -ge 0; $index--) {
            $entry = $changed[$index]
            try {
                if ($entry.BeforeDynamic) {
                    Set-VMNetworkAdapter -VMNetworkAdapter $entry.Adapter `
                        -DynamicMacAddress -Confirm:$false -ErrorAction Stop
                }
                else {
                    Set-VMNetworkAdapter -VMNetworkAdapter $entry.Adapter `
                        -StaticMacAddress $entry.BeforeMac -Confirm:$false `
                        -ErrorAction Stop
                }
            }
            catch { [void]$rollbackErrors.Add("网卡回滚失败：$($_.Exception.Message)") }
        }
        try {
            $afterRollback = @{}
            foreach ($adapter in @(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop)) {
                $afterRollback[(Get-VMateHyperVAdapterKey $adapter)] = $adapter
            }
            foreach ($entry in @($changed)) {
                $restored = $afterRollback[[string]$entry.AdapterId]
                if ($null -eq $restored) {
                    throw "回滚后网卡不存在：$($entry.AdapterId)"
                }
                if ($entry.BeforeDynamic) {
                    if (-not [bool]$restored.DynamicMacAddressEnabled) {
                        throw "回滚后网卡没有恢复动态 MAC：$($entry.AdapterId)"
                    }
                }
                else {
                    $restoredMac = ConvertTo-VMateHyperVMacAddress $restored.MacAddress
                    if ([bool]$restored.DynamicMacAddressEnabled -or
                        $restoredMac -cne [string]$entry.BeforeMac) {
                        throw "回滚后静态 MAC 不匹配：$($entry.AdapterId)"
                    }
                }
            }
        }
        catch { [void]$rollbackErrors.Add("网卡回滚回读失败：$($_.Exception.Message)") }
        $rollback = if ($rollbackErrors.Count) {
            $rollbackErrors -join '；'
        } else { '已回滚并验证原 MAC 策略' }
        throw "应用 Hyper-V 网络身份失败：$failure；$rollback"
    }
    }
    finally { Exit-VMateHyperVNetworkIdentityAllocator $allocatorLock }
}
