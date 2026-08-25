#Requires -Version 5.1

<#
.SYNOPSIS
    记录并验证 P-11 同一次冷启动的宿主扩展证明与 guest 直接回读。

.DESCRIPTION
    本模块只接受 HostIdentityExtension 中已发布且摘要完整的 Desired 记录。
    Attestation 必须绑定协调器返回的 BootId、签名扩展和 Microsoft hypervisor；
    GuestReadback 必须再绑定同一个 BootId。两阶段均原子写入 identity.json。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.HostIdentityExtension.ps1')

function Assert-VMateHyperVHostIdentityRuntimeFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$RequireMicrosoftSigner,
        [switch]$AllowHashPinnedUnsigned
    )

    if ($RequireMicrosoftSigner -and $AllowHashPinnedUnsigned) {
        throw 'Microsoft signer 与 hash-only 例外不能同时启用。'
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Description 不存在：$fullPath"
    }
    $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
    if ($hash -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "$Description SHA-256 不匹配。"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $fullPath
    $signatureValid = [string]$signature.Status -ceq 'Valid' -and
        $null -ne $signature.SignerCertificate
    if (-not $signatureValid -and -not $AllowHashPinnedUnsigned) {
        throw "$Description Authenticode 签名无效。"
    }
    $signer = if ($signatureValid) {
        [string]$signature.SignerCertificate.Subject
    } else { '' }
    if ($RequireMicrosoftSigner -and $signer -notmatch
        '(?i)(Microsoft Windows|Microsoft Corporation)') {
        throw "$Description 不是 Microsoft 签名。"
    }
    return [pscustomobject][ordered]@{
        Path = $fullPath
        Sha256 = $hash
        Signer = $signer
        SignatureStatus = if ($signatureValid) { 'Valid' }
            else { 'HashPinnedUnsigned' }
    }
}

function New-VMateHyperVHostIdentityColdBootAttestation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$DesiredRecord,
        [Parameter(Mandatory = $true)][object]$ColdBoot,
        [Parameter(Mandatory = $true)][string]$ExtensionBinaryPath,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedExtensionSha256,
        [Parameter(Mandatory = $true)][string]$HypervisorPath,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedHypervisorSha256
    )

    $vmId = ([Guid]$VM.Id).ToString('D')
    if ([string]$VM.State -cne 'Running' -or
        [string]$DesiredRecord.Desired.VMId -cne $vmId -or
        [string]$ColdBoot.VMId -cne $vmId -or
        [string]$ColdBoot.State -cne 'RunningAfterAppliedColdBoot' -or
        [bool]$ColdBoot.RuntimeModelSwitch -or
        [string]$ColdBoot.BrandString -cne
            [string]$DesiredRecord.Desired.Cpu.BrandString -or
        [String]::IsNullOrWhiteSpace([string]$ColdBoot.BootId)) {
        throw '冷启动结果没有与 Running VM/Desired CPU/BootId 完整绑定。'
    }
    $extension = Assert-VMateHyperVHostIdentityRuntimeFile `
        -Path $ExtensionBinaryPath `
        -ExpectedSha256 $ExpectedExtensionSha256 `
        -Description 'VMate host identity extension'
    $hypervisor = Assert-VMateHyperVHostIdentityRuntimeFile `
        -Path $HypervisorPath `
        -ExpectedSha256 $ExpectedHypervisorSha256 `
        -Description 'Microsoft Hyper-V hypervisor' -RequireMicrosoftSigner
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = [string]$DesiredRecord.Desired.ContractId
        State = 'AppliedAtColdBoot'
        VMId = $vmId
        ProfileId = [string]$DesiredRecord.Desired.ProfileId
        ManifestSha256 = [string]$DesiredRecord.ManifestSha256
        BootId = [string]$ColdBoot.BootId
        Capabilities = @($DesiredRecord.Desired.RequiredCapabilities)
        ExtensionBinaryPath = $extension.Path
        ExtensionSha256 = $extension.Sha256
        ExtensionSignerSubject = $extension.Signer
        HypervisorPath = $hypervisor.Path
        HypervisorSha256 = $hypervisor.Sha256
        HypervisorSignerSubject = $hypervisor.Signer
        RuntimeModelSwitch = $false
        PausedUptimeSeconds = [double]$ColdBoot.PausedUptimeSeconds
        PartitionId = [uint64]$ColdBoot.PartitionId
        AppliedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Publish-VMateHyperVHostIdentityColdBootAttestation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$Attestation,
        [string]$StateRoot = ''
    )

    $mutex = Enter-VMateGpuPIdentityLock -VMId $VMId
    try {
        $path = Get-VMateGpuPIdentityPath -VMId $VMId -StateRoot $StateRoot
        $identity = Read-VMateGpuPIdentityManifest -Path $path
        $property = $identity.PSObject.Properties['HostIdentityExtension']
        if ($null -eq $property -or $null -eq $property.Value) {
            throw 'identity.json 缺少 HostIdentityExtension。'
        }
        $record = $property.Value
        $desiredHash = Get-VMateHyperVHostIdentityObjectSha256 $record.Desired
        if ($desiredHash -cne [string]$record.ManifestSha256 -or
            -not (Test-VMateHyperVHostIdentityAttestation `
                $record $Attestation)) {
            throw '冷启动 attestation 与当前 Desired manifest 不匹配。'
        }
        $record.State = 'AttestedAwaitingGuestReadback'
        $record.Attestation = $Attestation
        $record.GuestReadback = $null
        $record.FullIdentitySupported = $false
        $record.VerifiedAtUtc = ''
        $identity.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-VMateGpuPAtomicJson $identity $path | Out-Null
        return [pscustomobject][ordered]@{
            State = [string]$record.State
            VMId = $VMId.ToString('D')
            ProfileId = [string]$record.Desired.ProfileId
            ManifestSha256 = [string]$record.ManifestSha256
            BootId = [string]$Attestation.BootId
            FullIdentitySupported = $false
        }
    }
    finally { Exit-VMateGpuPIdentityLock -Mutex $mutex }
}

function Publish-VMateHyperVHostIdentityGuestReadback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$GuestReadback,
        [string]$StateRoot = ''
    )

    $mutex = Enter-VMateGpuPIdentityLock -VMId $VMId
    try {
        $path = Get-VMateGpuPIdentityPath -VMId $VMId -StateRoot $StateRoot
        $identity = Read-VMateGpuPIdentityManifest -Path $path
        $property = $identity.PSObject.Properties['HostIdentityExtension']
        if ($null -eq $property -or $null -eq $property.Value) {
            throw 'identity.json 缺少 HostIdentityExtension。'
        }
        $record = $property.Value
        if (-not (Test-VMateHyperVHostIdentityAttestation `
                $record $record.Attestation) -or
            -not (Test-VMateHyperVHostIdentityGuestReadback `
                $record $record.Attestation $GuestReadback)) {
            throw 'guest readback 未与当前 Desired/Attestation/BootId 完整匹配。'
        }
        $record.State = 'Verified'
        $record.GuestReadback = $GuestReadback
        $record.FullIdentitySupported = $true
        $record.VerifiedAtUtc = [DateTime]::UtcNow.ToString('o')
        $profile = $identity.PSObject.Properties['HardwareProfile']
        if ($null -ne $profile -and $null -ne $profile.Value) {
            $profile.Value.FullIdentitySupported = $true
        }
        $identity.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-VMateGpuPAtomicJson $identity $path | Out-Null
        return Get-VMateHyperVHostIdentityExtensionStatus `
            -VMId $VMId -StateRoot $StateRoot
    }
    finally { Exit-VMateGpuPIdentityLock -Mutex $mutex }
}
