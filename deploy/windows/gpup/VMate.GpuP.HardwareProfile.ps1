#Requires -Version 5.1

<#
.SYNOPSIS
    读取并验证 P-11 的成组硬件平台池。

.DESCRIPTION
    P-11 复用共享 platforms.json 与 household-compatibility.json 的完整 CPU/主板
    事实束，并额外提供经授权实验机观测的 LGA1700 参考束。选择始终以整个平台 ID
    为单位，不允许独立随机 CPU、主板、BIOS、内存和设备。

    标准 Hyper-V 能原生应用的字段与需要额外宿主扩展的字段会分别返回。调用方必须
    显式检查 FullIdentitySupported，不能把仅保存的参考元数据表述成 guest 已生效。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.CpuidProfile.ps1')

function Get-VMateGpuPProfileProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Label = 'object'
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Label 缺少 $Name 属性。" }
    return $property.Value
}

function Get-VMateGpuPOptionalProfileProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Get-VMateGpuPHardwareProfileCatalogPath {
    [CmdletBinding()]
    param([string]$CatalogPath = '')

    if (-not [String]::IsNullOrWhiteSpace($CatalogPath)) {
        return [IO.Path]::GetFullPath($CatalogPath)
    }
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot `
                '..\..\hardware\p11-platforms.json'))
}

function Read-VMateGpuPJsonDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label 不存在：$Path"
    }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 `
            -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$Label 不是有效 JSON：$($_.Exception.Message)"
    }
}

function Assert-VMateGpuPProfileIdentifier {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$Label = 'profile id'
    )
    if ($Value -notmatch '^[a-z0-9][a-z0-9._:-]{2,127}$') {
        throw "$Label 无效：$Value"
    }
    return $Value
}

function ConvertTo-VMateGpuPNormalizedProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][string]$CatalogPath
    )

    $id = Assert-VMateGpuPProfileIdentifier ([string](
            Get-VMateGpuPProfileProperty $Profile 'id' 'P-11 profile'))
    $enabled = [bool](Get-VMateGpuPProfileProperty $Profile 'enabled' $id)
    $status = [string](Get-VMateGpuPProfileProperty $Profile 'status' $id)
    if ($status -notin @('supported', 'reference')) {
        throw "P-11 profile $id 的 status 无效：$status"
    }
    $fidelity = [string](Get-VMateGpuPProfileProperty `
            $Profile 'identity_fidelity' $id)
    if ($fidelity -notin @('hyperv-native', 'host-extension-required')) {
        throw "P-11 profile $id 的 identity_fidelity 无效：$fidelity"
    }
    $processor = Get-VMateGpuPProfileProperty $Profile 'processor' $id
    $cpuid = New-VMateGpuPCpuidIdentity $processor
    $memory = Get-VMateGpuPProfileProperty $Profile 'memory' $id
    $count = [int](Get-VMateGpuPProfileProperty $processor 'count' "$id.processor")
    $startup = [uint64](Get-VMateGpuPProfileProperty `
            $memory 'startup_bytes' "$id.memory")
    $maximum = [int](Get-VMateGpuPProfileProperty `
            $processor 'maximum_percent' "$id.processor")
    $reserve = [int](Get-VMateGpuPProfileProperty `
            $processor 'reserve_percent' "$id.processor")
    $weight = [int](Get-VMateGpuPProfileProperty `
            $processor 'relative_weight' "$id.processor")
    $threadsPerCore = [int](Get-VMateGpuPProfileProperty `
            $processor 'hw_threads_per_core' "$id.processor")
    if ($count -lt 1 -or $count -gt 256) {
        throw "P-11 profile $id 的 processor.count 越界。"
    }
    if ($maximum -lt 1 -or $maximum -gt 100 -or
        $reserve -lt 0 -or $reserve -gt 100 -or
        $weight -lt 1 -or $weight -gt 10000 -or
        $threadsPerCore -lt 1 -or $threadsPerCore -gt 64) {
        throw "P-11 profile $id 的 processor 调度字段越界。"
    }
    if ($startup -lt 1GB -or $startup -gt 1TB) {
        throw "P-11 profile $id 的 memory.startup_bytes 越界。"
    }
    $nativeFields = @((Get-VMateGpuPProfileProperty `
                $Catalog.fidelity 'hyperv_native_fields' 'P-11 fidelity') |
        ForEach-Object { [string]$_ })
    $extensionFields = @((Get-VMateGpuPProfileProperty `
                $Catalog.fidelity 'host_extension_required_fields' `
                'P-11 fidelity') | ForEach-Object { [string]$_ })
    if ($nativeFields.Count -eq 0 -or $extensionFields.Count -eq 0) {
        throw 'P-11 fidelity 字段集合不能为空。'
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        CatalogRevision = [string]$Catalog.catalog_revision
        CatalogPath = $CatalogPath
        Id = $id
        Label = [string](Get-VMateGpuPProfileProperty $Profile 'label' $id)
        Source = [string](Get-VMateGpuPProfileProperty $Profile 'source' $id)
        Status = $status
        Enabled = $enabled
        IdentityFidelity = $fidelity
        FullIdentitySupported = $fidelity -ceq 'hyperv-native'
        RequiresHostExtension = $fidelity -ceq 'host-extension-required'
        Processor = [pscustomobject][ordered]@{
            Count = $count
            MaximumPercent = $maximum
            ReservePercent = $reserve
            RelativeWeight = $weight
            HwThreadsPerCore = $threadsPerCore
            ExposeVirtualizationExtensions = [bool](
                Get-VMateGpuPProfileProperty $processor `
                    'expose_virtualization_extensions' "$id.processor")
            Manufacturer = [string](Get-VMateGpuPOptionalProfileProperty `
                    $processor 'manufacturer' '')
            Name = [string](Get-VMateGpuPOptionalProfileProperty `
                    $processor 'name' '')
            BrandPolicy = [string](Get-VMateGpuPProfileProperty `
                    $processor 'brand_policy' "$id.processor")
            Cpuid = $cpuid
        }
        Memory = $memory
        Platform = Get-VMateGpuPProfileProperty $Profile 'platform' $id
        Bios = Get-VMateGpuPOptionalProfileProperty $Profile 'bios' $null
        Storage = Get-VMateGpuPOptionalProfileProperty $Profile 'storage' $null
        Network = Get-VMateGpuPProfileProperty $Profile 'network' $id
        Firmware = Get-VMateGpuPProfileProperty $Profile 'firmware' $id
        Gpu = Get-VMateGpuPProfileProperty $Profile 'gpu' $id
        HyperVNativeFields = $nativeFields
        HostExtensionRequiredFields = if ($fidelity -ceq
            'host-extension-required') { $extensionFields } else { @() }
        InvariantGpuPSignal = [string]$Catalog.fidelity.invariant_gpu_p_signal
        FidelityPolicy = [string]$Catalog.fidelity.standard_backend_policy
    }
}

. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareCatalog.ps1')

function Get-VMateGpuPHardwareProfiles {
    [CmdletBinding()]
    param(
        [string]$CatalogPath = '',
        [switch]$IncludeDisabled
    )

    $path = Get-VMateGpuPHardwareProfileCatalogPath $CatalogPath
    $catalog = Read-VMateGpuPJsonDocument $path 'P-11 hardware catalog'
    if ([int](Get-VMateGpuPProfileProperty `
                $catalog 'schema_version' 'P-11 hardware catalog') -ne 1) {
        throw 'P-11 hardware catalog schema 不受支持。'
    }
    if ([string]$catalog.backend -cne 'hyper-v-gpu-p' -or
        [string]$catalog.selection_policy -cne 'atomic-platform-bundle-only') {
        throw 'P-11 hardware catalog backend/selection policy 无效。'
    }
    $rawProfiles = [Collections.Generic.List[object]]::new()
    foreach ($profile in @($catalog.profiles)) {
        [void]$rawProfiles.Add($profile)
    }

    $sharedName = [string]$catalog.shared_platform_catalog
    if ($sharedName -cne 'platforms.json' -or
        [IO.Path]::GetFileName($sharedName) -cne $sharedName) {
        throw 'P-11 shared platform catalog 必须是同目录 platforms.json。'
    }
    $sharedPath = [IO.Path]::GetFullPath((Join-Path `
                ([IO.Path]::GetDirectoryName($path)) $sharedName))
    $shared = Read-VMateGpuPJsonDocument $sharedPath 'shared platform catalog'
    if ([int]$shared.schema_version -ne 1) {
        throw 'shared platform catalog schema 不受支持。'
    }
    foreach ($platform in @($shared.platforms)) {
        if ([string]$platform.status -notin @('supported', 'compatibility')) {
            throw "shared platform status 无效：$($platform.id)"
        }
        if ([string]$platform.status -ceq 'compatibility' -and
            -not [bool]$platform.enabled) {
            continue
        }
        [void]$rawProfiles.Add((ConvertTo-VMateGpuPSharedPlatformProfile `
                    $platform $shared $catalog))
    }

    $householdName = [string](Get-VMateGpuPProfileProperty $catalog `
            'shared_compatibility_catalog' 'P-11 hardware catalog')
    $householdPolicy = [string](Get-VMateGpuPProfileProperty $catalog `
            'shared_compatibility_policy' 'P-11 hardware catalog')
    if ($householdName -cne 'household-compatibility.json' -or
        [IO.Path]::GetFileName($householdName) -cne $householdName -or
        $householdPolicy -cne 'deduplicate-equivalent-identity-bundles') {
        throw 'P-11 household compatibility catalog/policy 无效。'
    }
    $householdPath = [IO.Path]::GetFullPath((Join-Path `
                ([IO.Path]::GetDirectoryName($path)) $householdName))
    $household = Read-VMateGpuPJsonDocument `
        $householdPath 'household compatibility catalog'
    if ([int]$household.schema_version -ne 1) {
        throw 'household compatibility catalog schema 不受支持。'
    }
    $householdPlatforms = @{}
    foreach ($platform in @($household.platform_profiles)) {
        $platformId = Assert-VMateGpuPProfileIdentifier ([string]$platform.id) `
            'household platform id'
        if ($householdPlatforms.ContainsKey($platformId)) {
            throw "household platform ID 重复：$platformId"
        }
        $householdPlatforms[$platformId] = $platform
    }
    $householdBundles = @{}
    foreach ($candidate in @($household.candidates)) {
        $candidateId = Assert-VMateGpuPProfileIdentifier `
            ([string]$candidate.id) 'household candidate id'
        if ([string]$candidate.status -notin @('supported', 'compatibility')) {
            throw "household candidate status 无效：$candidateId"
        }
        $platformId = [string](Get-VMateGpuPProfileProperty `
                $candidate 'profile_id' $candidateId)
        if (-not $householdPlatforms.ContainsKey($platformId)) {
            throw "household candidate $candidateId 引用了未知 platform：$platformId"
        }
        $platform = $householdPlatforms[$platformId]
        $bundleKey = Get-VMateGpuPHouseholdBundleKey $candidate $platform
        if ($householdBundles.ContainsKey($bundleKey)) { continue }
        $householdBundles[$bundleKey] = $candidateId
        [void]$rawProfiles.Add((ConvertTo-VMateGpuPHouseholdProfile `
                    $candidate $platform $household))
    }

    $seen = @{}
    $profiles = [Collections.Generic.List[object]]::new()
    foreach ($raw in @($rawProfiles)) {
        $profile = ConvertTo-VMateGpuPNormalizedProfile `
            $raw $catalog $path
        $key = $profile.Id.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw "P-11 hardware profile ID 重复：$($profile.Id)"
        }
        $seen[$key] = $true
        if ($profile.Enabled -or $IncludeDisabled) {
            [void]$profiles.Add($profile)
        }
    }
    return @($profiles | Sort-Object Id)
}

function Resolve-VMateGpuPHardwareProfile {
    [CmdletBinding()]
    param(
        [string]$ProfileId = 'host-native',
        [string]$CatalogPath = '',
        [switch]$RequireFullIdentity
    )

    $id = Assert-VMateGpuPProfileIdentifier $ProfileId
    $matches = @(Get-VMateGpuPHardwareProfiles -CatalogPath $CatalogPath |
        Where-Object { [string]$_.Id -ieq $id })
    if ($matches.Count -ne 1) {
        throw "找不到唯一启用的 P-11 hardware profile：$id"
    }
    $profile = $matches[0]
    if ($RequireFullIdentity -and -not $profile.FullIdentitySupported) {
        throw ("P-11 hardware profile $id 需要版本匹配的宿主身份扩展；" +
            '标准 Hyper-V 只会应用计算资源、固件序号、静态 MAC 和 GPU 配额。')
    }
    return $profile
}

function Get-VMateGpuPHardwareProfilePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Profile)

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ProfileId = [string]$Profile.Id
        CatalogRevision = [string]$Profile.CatalogRevision
        IdentityFidelity = [string]$Profile.IdentityFidelity
        FullIdentitySupported = [bool]$Profile.FullIdentitySupported
        RequiresHostExtension = [bool]$Profile.RequiresHostExtension
        Compute = $Profile.Processor
        MemoryStartupBytes = [uint64]$Profile.Memory.startup_bytes
        HyperVNativeFields = @($Profile.HyperVNativeFields)
        HostExtensionRequiredFields = @($Profile.HostExtensionRequiredFields)
        InvariantGpuPSignal = [string]$Profile.InvariantGpuPSignal
        UnsupportedIdentityAction = if ($Profile.RequiresHostExtension) {
            'persist-reference-and-report-partial-never-claim-full'
        } else { 'not-applicable' }
    }
}

function Assert-VMateGpuPHardwareProfileOverrides {
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Overrides
    )

    $idProperty = $Profile.PSObject.Properties['Id']
    $id = if ($null -ne $idProperty) { [string]$idProperty.Value } else {
        [string](Get-VMateGpuPProfileProperty $Profile 'ProfileId' 'HardwareProfile')
    }
    if ($id -ceq 'host-native') { return $true }
    $expected = [ordered]@{
        ProcessorCount = [int]$Profile.Processor.Count
        CpuMaximumPercent = [int]$Profile.Processor.MaximumPercent
        CpuReservePercent = [int]$Profile.Processor.ReservePercent
        CpuRelativeWeight = [int]$Profile.Processor.RelativeWeight
        HwThreadCountPerCore = [int]$Profile.Processor.HwThreadsPerCore
        ExposeVirtualizationExtensions = [bool]$Profile.Processor.ExposeVirtualizationExtensions
        MemoryStartupBytes = [uint64]$Profile.Memory.startup_bytes
    }
    foreach ($name in $expected.Keys) {
        if ($Overrides.ContainsKey($name) -and
            [string]$Overrides[$name] -cne [string]$expected[$name]) {
            throw "hardware profile $id 的 $name 必须随整机束固定为 $($expected[$name])。"
        }
    }
    return $true
}

function ConvertTo-VMateGpuPHardwareProfileBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Profile)

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        PersistencePolicy = 'select-once-no-reroll'
        ReprofilePolicy = 'explicit-vm-off-transaction-only'
        BindingRevision = 1
        ProfileId = [string]$Profile.Id
        CatalogRevision = [string]$Profile.CatalogRevision
        Label = [string]$Profile.Label
        Source = [string]$Profile.Source
        IdentityFidelity = [string]$Profile.IdentityFidelity
        FullIdentitySupported = [bool]$Profile.FullIdentitySupported
        RequiresHostExtension = [bool]$Profile.RequiresHostExtension
        Processor = $Profile.Processor
        Memory = $Profile.Memory
        Platform = $Profile.Platform
        Bios = $Profile.Bios
        Storage = $Profile.Storage
        Network = $Profile.Network
        Firmware = $Profile.Firmware
        Gpu = $Profile.Gpu
        HyperVNativeFields = @($Profile.HyperVNativeFields)
        HostExtensionRequiredFields = @($Profile.HostExtensionRequiredFields)
        InvariantGpuPSignal = [string]$Profile.InvariantGpuPSignal
        ReprofileHistory = @()
        BoundAtUtc = ''
    }
}

function Assert-VMateGpuPHardwareProfileBinding {
    param([Parameter(Mandatory = $true)][object]$Binding)

    if ([int](Get-VMateGpuPProfileProperty `
                $Binding 'SchemaVersion' 'HardwareProfile') -ne 1 -or
        [string](Get-VMateGpuPProfileProperty $Binding `
                'PersistencePolicy' 'HardwareProfile') -cne
            'select-once-no-reroll') {
        throw 'HardwareProfile binding schema/persistence policy 无效。'
    }
    [void](Assert-VMateGpuPProfileIdentifier ([string](
                Get-VMateGpuPProfileProperty $Binding `
                    'ProfileId' 'HardwareProfile')))
    $fidelity = [string](Get-VMateGpuPProfileProperty `
            $Binding 'IdentityFidelity' 'HardwareProfile')
    if ($fidelity -notin @('hyperv-native', 'host-extension-required')) {
        throw 'HardwareProfile binding identity fidelity 无效。'
    }
    $reprofilePolicy = [string](Get-VMateGpuPOptionalProfileProperty `
            $Binding 'ReprofilePolicy' 'explicit-vm-off-transaction-only')
    if ($reprofilePolicy -cne 'explicit-vm-off-transaction-only') {
        throw 'HardwareProfile binding reprofile policy 无效。'
    }
    return $Binding
}

function Get-VMateGpuPHardwareProfileBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [string]$StateRoot = ''
    )

    $identity = Get-VMateGpuPIdentity -VMId $VMId -StateRoot $StateRoot
    if ($null -eq $identity) { return $null }
    $property = $identity.PSObject.Properties['HardwareProfile']
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    return Assert-VMateGpuPHardwareProfileBinding $property.Value
}

function Set-VMateGpuPHardwareProfileBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$Profile,
        [string]$StateRoot = '',
        [switch]$AllowReprofile,
        [string]$ReprofileReason = ''
    )

    $requested = ConvertTo-VMateGpuPHardwareProfileBinding $Profile
    $mutex = Enter-VMateGpuPIdentityLock -VMId $VMId
    try {
        $path = Get-VMateGpuPIdentityPath -VMId $VMId -StateRoot $StateRoot
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "GPU-P 身份清单不存在：$path"
        }
        $identity = Read-VMateGpuPIdentityManifest -Path $path
        Assert-VMateGpuPIdentityRecord $identity $VMId | Out-Null
        $property = $identity.PSObject.Properties['HardwareProfile']
        if ($null -ne $property -and $null -ne $property.Value) {
            $current = Assert-VMateGpuPHardwareProfileBinding $property.Value
            if ([string]$current.ProfileId -cne [string]$requested.ProfileId -or
                [string]$current.CatalogRevision -cne
                    [string]$requested.CatalogRevision) {
                if (-not $AllowReprofile) {
                    throw 'VM 已绑定不同硬件 profile；普通启动禁止重新抽取。'
                }
                if ([String]::IsNullOrWhiteSpace($ReprofileReason)) {
                    throw '显式换型必须提供非空 ReprofileReason。'
                }
                $history = [Collections.Generic.List[object]]::new()
                foreach ($entry in @(
                        Get-VMateGpuPOptionalProfileProperty `
                            $current 'ReprofileHistory' @())) {
                    [void]$history.Add($entry)
                }
                [void]$history.Add([pscustomobject][ordered]@{
                        ProfileId = [string]$current.ProfileId
                        CatalogRevision = [string]$current.CatalogRevision
                        BoundAtUtc = [string]$current.BoundAtUtc
                        ReplacedAtUtc = [DateTime]::UtcNow.ToString('o')
                        Reason = $ReprofileReason.Trim()
                    })
                $requested.BindingRevision = [int](
                    Get-VMateGpuPOptionalProfileProperty `
                        $current 'BindingRevision' 1) + 1
                $requested.ReprofileHistory = @($history)
                $requested.BoundAtUtc = [DateTime]::UtcNow.ToString('o')
                $property.Value = $requested
                $identity.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
                Write-VMateGpuPAtomicJson $identity $path | Out-Null
                return $requested
            }
            return $current
        }
        $requested.BoundAtUtc = [DateTime]::UtcNow.ToString('o')
        $identity | Add-Member -NotePropertyName HardwareProfile `
            -NotePropertyValue $requested
        $identity.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-VMateGpuPAtomicJson $identity $path | Out-Null
        return $requested
    }
    finally { Exit-VMateGpuPIdentityLock -Mutex $mutex }
}
