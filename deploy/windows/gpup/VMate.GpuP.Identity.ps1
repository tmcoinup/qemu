#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VMateGpuPDefaultStateRoot {
    [CmdletBinding()]
    param()

    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    if ([String]::IsNullOrWhiteSpace($programData)) {
        throw '无法解析 Windows CommonApplicationData，不能保存 GPU-P 身份清单。'
    }
    return [IO.Path]::Combine($programData, 'VMate', 'GpuP')
}

function New-VMateGpuPRandomHex {
    [CmdletBinding()]
    param(
        [ValidateRange(16, 64)]
        [int]$ByteCount = 32
    )

    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function Write-VMateGpuPAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if ([String]::IsNullOrWhiteSpace($directory)) {
        throw "身份清单路径缺少父目录：$Path"
    }

    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = [IO.Path]::Combine(
        $directory,
        ([IO.Path]::GetFileName($fullPath) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    )
    $encoding = New-Object Text.UTF8Encoding($false)
    $backupPath = ''
    try {
        $json = $InputObject | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $encoding)
        # File.Replace 在同卷上以原子方式替换现有清单，避免 Move-Item -Force
        # 可能先删除旧文件而留下短暂空窗；首次发布则直接原子 rename。
        if ([IO.File]::Exists($fullPath)) {
            $backupPath = "$fullPath.$([Guid]::NewGuid().ToString('N')).bak"
            [IO.File]::Replace($temporaryPath, $fullPath, $backupPath)
        }
        else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force `
                -ErrorAction SilentlyContinue
        }
        if (-not [String]::IsNullOrWhiteSpace($backupPath) -and
            (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Remove-Item -LiteralPath $backupPath -Force `
                -ErrorAction SilentlyContinue
        }
    }
    return $fullPath
}

function Get-VMateGpuPIdentityPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Guid]$VMId,

        [string]$StateRoot = ''
    )

    if ([String]::IsNullOrWhiteSpace($StateRoot)) {
        $StateRoot = Get-VMateGpuPDefaultStateRoot
    }
    $root = [IO.Path]::GetFullPath($StateRoot)
    return [IO.Path]::Combine($root, $VMId.ToString('D'), 'identity.json')
}

function Assert-VMateGpuPIdentityRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Identity,

        [Parameter(Mandatory = $true)]
        [Guid]$VMId
    )

    if ([int]$Identity.SchemaVersion -ne 1) {
        throw 'GPU-P 身份清单 schema 不受支持。'
    }
    $recordVmId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$Identity.VMId, [ref]$recordVmId) -or $recordVmId -ne $VMId) {
        throw "GPU-P 身份清单与 VMId $VMId 不匹配。"
    }
    if ([string]$Identity.PartitionIdentitySeed -notmatch '^[0-9a-f]{64}$') {
        throw 'GPU-P 身份清单的 256-bit 分区身份种子无效。'
    }
    if ([string]$Identity.PhysicalGpuSerialPolicy -ne 'vendor-managed-read-only') {
        throw 'GPU-P 身份清单试图声明不受支持的物理显卡序列号策略。'
    }
    $scope = $Identity.PSObject.Properties['ObservedVendorGpuUuidScope']
    if ($null -eq $scope) {
        $Identity | Add-Member -NotePropertyName ObservedVendorGpuUuidScope `
            -NotePropertyValue 'unknown-physical-or-virtual'
    }
    elseif ([string]$scope.Value -ne 'unknown-physical-or-virtual') {
        throw 'GPU-P 身份清单包含不受支持的 vendor UUID 范围声明。'
    }
    return $Identity
}

function Read-VMateGpuPIdentityManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "GPU-P 身份清单不存在：$fullPath"
    }
    if (-not [IO.Path]::GetFileName($fullPath).Equals(
            'identity.json', [StringComparison]::OrdinalIgnoreCase)) {
        throw "GPU-P 身份清单文件名无效：$fullPath"
    }
    try {
        $record = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "无法读取 GPU-P 身份清单 $fullPath：$($_.Exception.Message)"
    }
    $vmId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$record.VMId, [ref]$vmId) -or
        $vmId -eq [Guid]::Empty) {
        throw "GPU-P 身份清单的 VMId 无效：$fullPath"
    }
    $parentName = [IO.DirectoryInfo]::new(
        [IO.Path]::GetDirectoryName($fullPath)).Name
    if (-not $parentName.Equals($vmId.ToString('D'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "GPU-P 身份清单目录与 VMId 不匹配：$fullPath"
    }
    Assert-VMateGpuPIdentityRecord -Identity $record -VMId $vmId | Out-Null
    return $record
}

function Get-VMateGpuPIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Guid]$VMId,

        [string]$StateRoot = ''
    )

    $path = Get-VMateGpuPIdentityPath -VMId $VMId -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    $record = Read-VMateGpuPIdentityManifest -Path $path
    Assert-VMateGpuPIdentityRecord -Identity $record -VMId $VMId | Out-Null
    return $record
}

function Enter-VMateGpuPIdentityLock {
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $name = 'Global\VMate.GpuP.Identity.' + $VMId.ToString('N')
    $mutex = [Threading.Mutex]::new($false, $name)
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "等待 VM GPU-P 身份锁超过 ${TimeoutSeconds}s。"
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-VMateGpuPIdentityLock {
    param([Parameter(Mandatory = $true)][Threading.Mutex]$Mutex)
    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Initialize-VMateGpuPIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Guid]$VMId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')]
        [string]$Vendor,

        [string]$PartitionIdentitySeed = '',

        [string]$StateRoot = '',

        [switch]$DryRun
    )

    $identityLock = Enter-VMateGpuPIdentityLock -VMId $VMId
    try {
    $path = Get-VMateGpuPIdentityPath -VMId $VMId -StateRoot $StateRoot
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-VMateGpuPIdentityRecord -Identity $record -VMId $VMId | Out-Null
        if ([string]$record.Vendor -ne $Vendor) {
            throw "VM 已绑定 $($record.Vendor) GPU-P 身份，不能静默切换为 $Vendor。"
        }
        if (-not [String]::IsNullOrWhiteSpace($PartitionIdentitySeed) -and
            [string]$record.PartitionIdentitySeed -ine
                $PartitionIdentitySeed.Trim()) {
            throw 'VM 已有不同的 PartitionIdentitySeed，拒绝重抽身份。'
        }
        return $record
    }

    $seed = if ([String]::IsNullOrWhiteSpace($PartitionIdentitySeed)) {
        New-VMateGpuPRandomHex -ByteCount 32
    }
    else {
        if ($PartitionIdentitySeed -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'PartitionIdentitySeed 必须是 64 位十六进制字符串。'
        }
        $PartitionIdentitySeed.ToLowerInvariant()
    }
    $record = [pscustomobject][ordered]@{
        SchemaVersion = 1
        VMId = $VMId.ToString('D')
        Vendor = $Vendor
        PartitionIdentitySeed = $seed
        IdentityAuthority = 'hyper-v-and-gpu-vendor'
        PhysicalGpuSerialPolicy = 'vendor-managed-read-only'
        GpuInstancePath = $null
        HostGpuName = $null
        DriverVersion = $null
        DriverInf = $null
        PartitionId = $null
        PartitionVfLuid = $null
        VendorGpuUuid = $null
        ObservedVendorGpuUuidScope = 'unknown-physical-or-virtual'
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    if (-not $DryRun) {
        Write-VMateGpuPAtomicJson -InputObject $record -Path $path | Out-Null
    }
    return $record
    }
    finally {
        Exit-VMateGpuPIdentityLock -Mutex $identityLock
    }
}

function Set-VMateGpuPIdentityBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Guid]$VMId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')]
        [string]$Vendor,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GpuInstancePath,

        [string]$HostGpuName = '',

        [string]$DriverVersion = '',

        [string]$DriverInf = '',

        [string]$StateRoot = '',

        [switch]$AllowRebind
    )

    $identityLock = Enter-VMateGpuPIdentityLock -VMId $VMId
    try {
    $path = Get-VMateGpuPIdentityPath -VMId $VMId -StateRoot $StateRoot
    $record = Get-VMateGpuPIdentity -VMId $VMId -StateRoot $StateRoot
    if ($null -eq $record) {
        throw "GPU-P 身份清单不存在：$path"
    }
    if ([string]$record.Vendor -ne $Vendor) {
        throw "GPU-P 身份厂商不匹配：$($record.Vendor) != $Vendor"
    }
    $vendorId = if ($Vendor -ieq 'NVIDIA') { '10DE' } else { '1002' }
    if ($GpuInstancePath -notmatch "(?i)VEN_$vendorId(?=&|#|\\|$)") {
        throw "GPU InstancePath 与身份厂商 $Vendor 不匹配。"
    }
    $oldPath = [string]$record.GpuInstancePath
    if (-not [String]::IsNullOrWhiteSpace($oldPath) -and
        -not $oldPath.Equals($GpuInstancePath, [StringComparison]::OrdinalIgnoreCase) -and
        -not $AllowRebind) {
        throw 'VM 已固定到另一 GPU InstancePath；只有显式迁移流程可以重新绑定。'
    }
    $record.GpuInstancePath = $GpuInstancePath
    $record.HostGpuName = $HostGpuName
    $record.DriverVersion = $DriverVersion
    $record.DriverInf = $DriverInf
    $record.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-VMateGpuPAtomicJson -InputObject $record -Path $path | Out-Null
    return $record
    }
    finally {
        Exit-VMateGpuPIdentityLock -Mutex $identityLock
    }
}

function Update-VMateGpuPObservedIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Guid]$VMId,

        [AllowNull()]
        [object]$PartitionId,

        [AllowNull()]
        [object]$PartitionVfLuid,

        [AllowEmptyString()]
        [string]$VendorGpuUuid = '',

        [string]$StateRoot = ''
    )

    $identityLock = Enter-VMateGpuPIdentityLock -VMId $VMId
    try {
    $path = Get-VMateGpuPIdentityPath -VMId $VMId -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "GPU-P 身份清单不存在：$path"
    }
    $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-VMateGpuPIdentityRecord -Identity $record -VMId $VMId | Out-Null
    # 只更新调用者明确绑定的观测项；否则单独回写 UUID 时
    # 会意外清空已持久化的 Hyper-V partition 标识。
    if ($PSBoundParameters.ContainsKey('PartitionId')) {
        $record.PartitionId = $PartitionId
    }
    if ($PSBoundParameters.ContainsKey('PartitionVfLuid')) {
        $record.PartitionVfLuid = $PartitionVfLuid
    }
    if ($PSBoundParameters.ContainsKey('VendorGpuUuid') -and
        -not [String]::IsNullOrWhiteSpace($VendorGpuUuid)) {
        $record.VendorGpuUuid = $VendorGpuUuid.Trim()
    }
    $record.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-VMateGpuPAtomicJson -InputObject $record -Path $path | Out-Null
    return $record
    }
    finally {
        Exit-VMateGpuPIdentityLock -Mutex $identityLock
    }
}

function Test-VMateGpuPIdentityUniqueness {
    [CmdletBinding()]
    param(
        [string]$StateRoot = ''
    )

    if ([String]::IsNullOrWhiteSpace($StateRoot)) {
        $StateRoot = Get-VMateGpuPDefaultStateRoot
    }
    if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
        return [pscustomobject]@{
            IsUnique = $true
            Records = 0
            Collisions = @()
            ObservedVendorGpuUuidCollisions = @()
        }
    }

    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $StateRoot -Filter identity.json -File -Recurse)) {
        $records += Read-VMateGpuPIdentityManifest -Path $file.FullName
    }

    $collisions = @()
    foreach ($property in @('VMId', 'PartitionIdentitySeed')) {
        $groups = $records |
            Where-Object {
                $candidate = $_.PSObject.Properties[$property]
                $null -ne $candidate -and
                    -not [String]::IsNullOrWhiteSpace([string]$candidate.Value)
            } |
            Group-Object -Property $property |
            Where-Object { $_.Count -gt 1 }
        foreach ($group in @($groups)) {
            $collisions += [pscustomobject]@{
                Field = $property
                Value = [string]$group.Name
                Count = [int]$group.Count
            }
        }
    }

    # 消费级 GPU-P/NVML 可能把同一物理 GPU UUID 暴露给多个合法 partition；
    # 它只作为观测信息报告，不能当成 VM 身份唯一键而阻断多 guest。
    $observedUuidCollisions = @($records |
        Where-Object {
            -not [String]::IsNullOrWhiteSpace([string]$_.VendorGpuUuid)
        } | Group-Object -Property VendorGpuUuid |
        Where-Object { $_.Count -gt 1 } | ForEach-Object {
            [pscustomobject]@{ Value = [string]$_.Name; Count = [int]$_.Count }
        })

    return [pscustomobject]@{
        IsUnique = ($collisions.Count -eq 0)
        Records = $records.Count
        Collisions = $collisions
        ObservedVendorGpuUuidCollisions = $observedUuidCollisions
    }
}
