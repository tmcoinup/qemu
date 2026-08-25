#Requires -Version 5.1

<#
.SYNOPSIS
    管理 P-11 每 VM、冷启动生效的 Hyper-V 宿主身份扩展契约。

.DESCRIPTION
    本模块发布 CPU/主板/BIOS/设备身份的确定性期望清单，并验证宿主扩展证明与
    guest 直接回读。单独存在 JSON、EFI SMBIOS 配置或管理器显示值都不会把
    FullIdentitySupported 置为 true；必须同时满足二进制签名/哈希、宿主
    hypervisor 哈希、同一次冷启动绑定以及 guest 直接 CPUID/CIM 回读。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')

$script:VMateHostIdentityContractId =
    'vmate-p11-hyperv-host-identity-cold-boot-v1'
$script:VMateHostIdentityRequiredCapabilities = @(
    'per-vm-cold-boot-binding',
    'direct-cpuid-override',
    'platform-smbios-override'
)

function Get-VMateHyperVHostIdentityOptionalProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Get-VMateHyperVHostIdentityProfileId {
    param([Parameter(Mandatory = $true)][object]$Profile)

    foreach ($name in @('Id', 'ProfileId')) {
        $property = $Profile.PSObject.Properties[$name]
        if ($null -ne $property -and
            -not [String]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    throw 'Host identity profile 缺少 Id/ProfileId。'
}

function Get-VMateHyperVHostIdentityObjectSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$InputObject)

    $json = $InputObject | ConvertTo-Json -Depth 16 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '')
    }
    finally { $sha.Dispose() }
}

function New-VMateHyperVHostIdentityDesiredManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$HardwareIdentity
    )

    if ([string]$VM.State -cne 'Off') {
        throw '宿主身份扩展期望清单只允许在 VM 为 Off 时生成。'
    }
    $profileId = Get-VMateHyperVHostIdentityProfileId $Profile
    $processor = Get-VMateHyperVHostIdentityOptionalProperty `
        $Profile 'Processor' $null
    $cpuid = Get-VMateHyperVHostIdentityOptionalProperty `
        $processor 'Cpuid' $null
    $platform = Get-VMateHyperVHostIdentityOptionalProperty `
        $Profile 'Platform' $null
    $bios = Get-VMateHyperVHostIdentityOptionalProperty $Profile 'Bios' $null
    $memory = Get-VMateHyperVHostIdentityOptionalProperty `
        $Profile 'Memory' $null
    if ($null -eq $processor -or $null -eq $cpuid -or
        $null -eq $platform -or $null -eq $bios -or $null -eq $memory) {
        throw "profile $profileId 缺少宿主身份扩展所需事实。"
    }
    $brand = [string](Get-VMateHyperVHostIdentityOptionalProperty `
            $cpuid 'BrandString' '')
    if ([String]::IsNullOrWhiteSpace($brand)) {
        throw "profile $profileId 缺少 CPUID brand string。"
    }
    $firmware = Get-VMateHyperVHostIdentityOptionalProperty `
        $HardwareIdentity 'Firmware' $null
    if ($null -eq $firmware) {
        throw 'HardwareIdentity 缺少 Firmware。'
    }
    $systemProduct = [string](Get-VMateHyperVHostIdentityOptionalProperty `
            $platform 'system_product' '')
    if ([String]::IsNullOrWhiteSpace($systemProduct)) {
        $systemProduct = [string](Get-VMateHyperVHostIdentityOptionalProperty `
                $platform 'product' '')
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = $script:VMateHostIdentityContractId
        VMId = ([Guid]$VM.Id).ToString('D')
        ProfileId = $profileId
        CatalogRevision = [string](
            Get-VMateHyperVHostIdentityOptionalProperty `
                $Profile 'CatalogRevision' '')
        ApplyPolicy = 'vm-off-publish-next-cold-boot-only'
        RuntimeModelSwitch = 'forbidden'
        FailurePolicy = 'fail-closed-never-claim-full'
        Cpu = [pscustomobject][ordered]@{
            VendorId = [string]$cpuid.VendorId
            BrandString = $brand
            BrandLeaves = $cpuid.BrandLeaves
            Family = $cpuid.Family
            Model = $cpuid.Model
            Stepping = $cpuid.Stepping
            Leaf1EaxHex = [string]$cpuid.Leaf1EaxHex
            EvidenceSource = [string]$cpuid.EvidenceSource
        }
        Platform = [pscustomobject][ordered]@{
            SystemManufacturer = [string]$platform.manufacturer
            SystemProduct = $systemProduct
            BaseBoardManufacturer = [string]$platform.manufacturer
            BaseBoardProduct = [string]$platform.product
            BaseBoardVersion = [string]$platform.version
            BiosManufacturer = [string]$bios.manufacturer
            BiosVersion = [string]$bios.version
            BiosReleaseDate = [string]$bios.release_date
            Firmware = $firmware
        }
        Memory = $memory
        Storage = Get-VMateHyperVHostIdentityOptionalProperty `
            $Profile 'Storage' $null
        Network = Get-VMateHyperVHostIdentityOptionalProperty `
            $Profile 'Network' $null
        Gpu = Get-VMateHyperVHostIdentityOptionalProperty `
            $Profile 'Gpu' $null
        RequiredCapabilities =
            @($script:VMateHostIdentityRequiredCapabilities)
        RequiredGuestEvidence = @(
            'direct-cpuid-brand',
            'direct-cpuid-leaf1',
            'win32-computersystem',
            'win32-baseboard',
            'win32-bios',
            'functional-gpu-p'
        )
    }
}

function Publish-VMateHyperVHostIdentityDesiredManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$HardwareIdentity,
        [string]$StateRoot = '',
        [switch]$DryRun
    )

    $desired = New-VMateHyperVHostIdentityDesiredManifest `
        -VM $VM -Profile $Profile -HardwareIdentity $HardwareIdentity
    $manifestSha = Get-VMateHyperVHostIdentityObjectSha256 $desired
    $vmId = [Guid]$VM.Id
    $identity = Get-VMateGpuPIdentity -VMId $vmId -StateRoot $StateRoot
    if ($null -eq $identity) {
        throw '发布宿主身份扩展清单前必须先创建 GPU-P identity.json。'
    }
    $existingProperty = $identity.PSObject.Properties['HostIdentityExtension']
    $existing = if ($null -ne $existingProperty) {
        $existingProperty.Value
    } else { $null }
    $same = $null -ne $existing -and
        [string](Get-VMateHyperVHostIdentityOptionalProperty `
            $existing 'ManifestSha256' '') -ceq $manifestSha
    if ($DryRun) {
        return [pscustomobject][ordered]@{
            Status = 'DryRun'
            ChangeRequired = -not $same
            ManifestSha256 = $manifestSha
            Desired = $desired
            FullIdentitySupported = $false
        }
    }
    if ($same) {
        return [pscustomobject][ordered]@{
            Status = 'DesiredUnchanged'
            ChangeRequired = $false
            ManifestSha256 = $manifestSha
            Desired = $desired
            FullIdentitySupported = [bool](
                Get-VMateHyperVHostIdentityOptionalProperty `
                    $existing 'FullIdentitySupported' $false)
        }
    }

    $mutex = Enter-VMateGpuPIdentityLock -VMId $vmId
    try {
        $path = Get-VMateGpuPIdentityPath -VMId $vmId -StateRoot $StateRoot
        $identity = Read-VMateGpuPIdentityManifest -Path $path
        $currentProperty = $identity.PSObject.Properties[
            'HostIdentityExtension']
        $current = if ($null -ne $currentProperty) {
            $currentProperty.Value
        } else { $null }
        $previousSha = [string](
            Get-VMateHyperVHostIdentityOptionalProperty `
                $current 'ManifestSha256' '')
        $record = [pscustomobject][ordered]@{
            SchemaVersion = 1
            State = 'DesiredOnly'
            ManifestSha256 = $manifestSha
            PreviousManifestSha256 = $previousSha
            Desired = $desired
            Attestation = $null
            GuestReadback = $null
            FullIdentitySupported = $false
            PublishedAtUtc = [DateTime]::UtcNow.ToString('o')
            VerifiedAtUtc = ''
        }
        if ($null -eq $currentProperty) {
            $identity | Add-Member -NotePropertyName HostIdentityExtension `
                -NotePropertyValue $record
        }
        else { $currentProperty.Value = $record }
        $identity.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-VMateGpuPAtomicJson $identity $path | Out-Null
        return [pscustomobject][ordered]@{
            Status = 'DesiredPublished'
            ChangeRequired = $true
            ManifestSha256 = $manifestSha
            Desired = $desired
            FullIdentitySupported = $false
        }
    }
    finally { Exit-VMateGpuPIdentityLock -Mutex $mutex }
}

function Test-VMateHyperVHostIdentityAttestation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DesiredRecord,
        [Parameter(Mandatory = $true)][object]$Attestation
    )

    try {
        if ([int]$Attestation.SchemaVersion -ne 1 -or
            [string]$Attestation.ContractId -cne
                $script:VMateHostIdentityContractId -or
            [string]$Attestation.State -cne 'AppliedAtColdBoot' -or
            [string]$Attestation.VMId -cne
                [string]$DesiredRecord.Desired.VMId -or
            [string]$Attestation.ProfileId -cne
                [string]$DesiredRecord.Desired.ProfileId -or
            [string]$Attestation.ManifestSha256 -cne
                [string]$DesiredRecord.ManifestSha256 -or
            [String]::IsNullOrWhiteSpace([string]$Attestation.BootId)) {
            return $false
        }
        foreach ($capability in $script:VMateHostIdentityRequiredCapabilities) {
            if (@($Attestation.Capabilities) -cnotcontains $capability) {
                return $false
            }
        }
        foreach ($pathName in @('ExtensionBinaryPath', 'HypervisorPath')) {
            $path = [string]$Attestation.$pathName
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return $false
            }
        }
        $extensionHash = (Get-FileHash `
            -LiteralPath ([string]$Attestation.ExtensionBinaryPath) `
            -Algorithm SHA256).Hash
        $hypervisorHash = (Get-FileHash `
            -LiteralPath ([string]$Attestation.HypervisorPath) `
            -Algorithm SHA256).Hash
        if ($extensionHash -cne [string]$Attestation.ExtensionSha256 -or
            $hypervisorHash -cne [string]$Attestation.HypervisorSha256) {
            return $false
        }
        $signature = Get-AuthenticodeSignature `
            -LiteralPath ([string]$Attestation.ExtensionBinaryPath)
        if ([string]$signature.Status -cne 'Valid' -or
            $null -eq $signature.SignerCertificate -or
            [string]$signature.SignerCertificate.Subject -cne
                [string]$Attestation.ExtensionSignerSubject) {
            return $false
        }
        return $true
    }
    catch { return $false }
}

function Test-VMateHyperVHostIdentityGuestReadback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DesiredRecord,
        [Parameter(Mandatory = $true)][object]$Attestation,
        [Parameter(Mandatory = $true)][object]$GuestReadback
    )

    try {
        $desired = $DesiredRecord.Desired
        if ([int]$GuestReadback.SchemaVersion -ne 1 -or
            [string]$GuestReadback.VMId -cne [string]$desired.VMId -or
            [string]$GuestReadback.ProfileId -cne
                [string]$desired.ProfileId -or
            [string]$GuestReadback.ManifestSha256 -cne
                [string]$DesiredRecord.ManifestSha256 -or
            [string]$GuestReadback.BootId -cne
                [string]$Attestation.BootId -or
            [string]$GuestReadback.EvidenceMethod -cne
                'in-guest-direct-cpuid-and-cim') {
            return $false
        }
        if ([string]$GuestReadback.DirectCpuid.VendorId -cne
                [string]$desired.Cpu.VendorId -or
            [string]$GuestReadback.DirectCpuid.BrandString -cne
                [string]$desired.Cpu.BrandString) {
            return $false
        }
        if (-not [String]::IsNullOrWhiteSpace(
                [string]$desired.Cpu.Leaf1EaxHex) -and
            [string]$GuestReadback.DirectCpuid.Leaf1EaxHex -cne
                [string]$desired.Cpu.Leaf1EaxHex) {
            return $false
        }
        $pairs = @(
            @('ComputerSystem', 'Manufacturer', 'SystemManufacturer'),
            @('ComputerSystem', 'Model', 'SystemProduct'),
            @('BaseBoard', 'Manufacturer', 'BaseBoardManufacturer'),
            @('BaseBoard', 'Product', 'BaseBoardProduct'),
            @('Bios', 'Manufacturer', 'BiosManufacturer'),
            @('Bios', 'Version', 'BiosVersion')
        )
        foreach ($pair in $pairs) {
            if ([string]$GuestReadback.($pair[0]).($pair[1]) -cne
                [string]$desired.Platform.($pair[2])) {
                return $false
            }
        }
        return [bool]$GuestReadback.FunctionalGpuP
    }
    catch { return $false }
}

function Get-VMateHyperVHostIdentityExtensionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [string]$StateRoot = ''
    )

    $identity = Get-VMateGpuPIdentity -VMId $VMId -StateRoot $StateRoot
    $property = if ($null -ne $identity) {
        $identity.PSObject.Properties['HostIdentityExtension']
    } else { $null }
    if ($null -eq $property -or $null -eq $property.Value) {
        return [pscustomobject][ordered]@{
            State = 'Missing'
            Integrity = $false
            Attested = $false
            GuestVerified = $false
            FullIdentitySupported = $false
        }
    }
    $record = $property.Value
    $desiredHash = Get-VMateHyperVHostIdentityObjectSha256 $record.Desired
    $integrity = [int]$record.SchemaVersion -eq 1 -and
        $desiredHash -ceq [string]$record.ManifestSha256
    $attestation = Get-VMateHyperVHostIdentityOptionalProperty `
        $record 'Attestation' $null
    $attested = $integrity -and $null -ne $attestation -and
        (Test-VMateHyperVHostIdentityAttestation $record $attestation)
    $guestReadback = Get-VMateHyperVHostIdentityOptionalProperty `
        $record 'GuestReadback' $null
    $guestVerified = $attested -and $null -ne $guestReadback -and
        (Test-VMateHyperVHostIdentityGuestReadback `
            $record $attestation $guestReadback)
    return [pscustomobject][ordered]@{
        State = if (-not $integrity) { 'Drift' }
            elseif ($guestVerified) { 'Verified' }
            elseif ($attested) { 'AttestedAwaitingGuestReadback' }
            else { 'DesiredOnly' }
        Integrity = [bool]$integrity
        VMId = [string]$record.Desired.VMId
        ProfileId = [string]$record.Desired.ProfileId
        ManifestSha256 = [string]$record.ManifestSha256
        Attested = [bool]$attested
        GuestVerified = [bool]$guestVerified
        FullIdentitySupported = [bool]$guestVerified
        Desired = $record.Desired
    }
}
