#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [string]$ModulePath = 'C:\VMateLab\VMate.HyperV.IdentityBoot.ps1',
    [string]$ProfileModulePath =
        'C:\VMateLab\gpup\VMate.GpuP.HardwareProfile.ps1',
    [string]$CatalogPath = 'C:\VMateLab\hardware\p11-platforms.json',
    [string]$ExtensionPath =
        'C:\VMateLab\VMateIdentityBoot-canonical.efi',
    [string]$ResultPath =
        'C:\VMateLab\p11-identity-canonical-migration.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. $ProfileModulePath
. $ModulePath

$expectedExtensionHash =
    '4D58562E0AC7E86FCA1A47392EC4B5E64B602BB870CE0922D858348D6C52563B'
if ((Get-FileHash -LiteralPath $ExtensionPath -Algorithm SHA256).Hash -cne
    $expectedExtensionHash) {
    throw 'canonical identity EFI hash mismatch.'
}

$profileId = 'lab-intel-i5-13600kf-galax-b760-metaltop-d4'
$profile = Resolve-VMateGpuPHardwareProfile -ProfileId $profileId `
    -CatalogPath $CatalogPath
$hardwareIdentity = [pscustomobject]@{
    Firmware = [pscustomobject]@{
        BIOSGUID = '8E941F54-F07D-4297-B0C7-CBF00B32F420'
        BIOSSerialNumber = 'F5BB047C2BA7B8C233111B87E3783197'
        BaseBoardSerialNumber = '7805087C78748AE30FF0809BDAB3715E'
        ChassisSerialNumber = 'C8E57678D6EE0D34CA3E09F42CBA904C'
        ChassisAssetTag = '80A45803EE57C97D2AB773B0B93473B0'
    }
}
$vm = Get-VM -Name $VMName -ErrorAction Stop
$wasRunning = [string]$vm.State -ceq 'Running'
$result = [ordered]@{
    VMName = $VMName
    VMId = $vm.Id.ToString('D')
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    InitialState = [string]$vm.State
    InitialSecureBoot = [string](Get-VMFirmware -VM $vm).SecureBoot
    ProfileId = $profileId
    ExpectedExtensionSha256 = $expectedExtensionHash
    GracefulShutdown = $false
    Install = $null
    OfflineStatus = $null
    Restarted = $false
    Heartbeat = $null
    Error = $null
}

try {
    if ($wasRunning) {
        $computerSystem = Get-CimInstance `
            -Namespace 'root/virtualization/v2' `
            -ClassName Msvm_ComputerSystem -ErrorAction Stop |
            Where-Object { [string]$_.Name -ceq $vm.Id.ToString('D') -or
                [string]$_.ElementName -ceq $VMName } |
            Select-Object -First 1
        if ($null -eq $computerSystem) {
            throw 'unable to resolve P11-Lab Hyper-V computer system.'
        }
        $shutdown = Invoke-CimMethod -InputObject $computerSystem `
            -MethodName RequestStateChange `
            -Arguments @{ RequestedState = [uint16]4 } -ErrorAction Stop
        if ([uint32]$shutdown.ReturnValue -notin @(0, 4096)) {
            throw "graceful shutdown returned $($shutdown.ReturnValue)."
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        do {
            Start-Sleep -Milliseconds 500
            $vm = Get-VM -Id $vm.Id -ErrorAction Stop
        } while ([string]$vm.State -cne 'Off' -and
            [DateTime]::UtcNow -lt $deadline)
        if ([string]$vm.State -cne 'Off') {
            throw 'P11-Lab graceful shutdown timed out; no force-off attempted.'
        }
        $result.GracefulShutdown = $true
    }
    elseif ([string]$vm.State -cne 'Off') {
        throw "P11-Lab state is not safe for migration: $($vm.State)"
    }
    $result.Install = Install-VMateHyperVIdentityBoot -VM $vm `
        -Profile $profile -HardwareIdentity $hardwareIdentity `
        -ExtensionPath $ExtensionPath -AllowDisableSecureBoot
    $result.OfflineStatus = Get-VMateHyperVIdentityBootStatus -VM $vm
    if (-not [bool]$result.OfflineStatus.Integrity -or
        [string]$result.OfflineStatus.State -cne 'Installed') {
        throw 'offline post-install integrity verification failed.'
    }
}
catch {
    $result.Error = $_.Exception.Message
}
finally {
    $vm = Get-VM -Id $vm.Id -ErrorAction SilentlyContinue
    if ($wasRunning -and $null -ne $vm -and [string]$vm.State -ceq 'Off') {
        try {
            Start-VM -VM $vm -ErrorAction Stop | Out-Null
            $result.Restarted = $true
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            do {
                Start-Sleep -Seconds 1
                $heartbeat = Get-VMIntegrationService -VMName $VMName `
                    -ErrorAction SilentlyContinue |
                    Where-Object {
                        [string]$_.Id -match `
                            '84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47$'
                    } | Select-Object -First 1
            } while (($null -eq $heartbeat -or
                    [uint16]$heartbeat.PrimaryOperationalStatus -ne 2) -and
                [DateTime]::UtcNow -lt $deadline)
            $result.Heartbeat = if ($null -eq $heartbeat) {
                'Unavailable'
            } elseif ([uint16]$heartbeat.PrimaryOperationalStatus -eq 2) {
                'OK'
            } else { "OperationalStatus=$($heartbeat.PrimaryOperationalStatus)" }
            if ([string]$result.Heartbeat -ne 'OK' -and
                [String]::IsNullOrWhiteSpace([string]$result.Error)) {
                $result.Error = 'P11-Lab heartbeat did not become OK.'
            }
        }
        catch {
            if ([String]::IsNullOrWhiteSpace([string]$result.Error)) {
                $result.Error = $_.Exception.Message
            }
            else {
                $result.Error = [string]$result.Error +
                    '; restart failed: ' + $_.Exception.Message
            }
        }
    }
    $result.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    [pscustomobject]$result | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

[pscustomobject]$result
if (-not [String]::IsNullOrWhiteSpace([string]$result.Error)) { exit 1 }
