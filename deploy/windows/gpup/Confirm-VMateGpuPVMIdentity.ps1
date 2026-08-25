#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    通过 PowerShell Direct 发布同一次 P-11 冷启动的直接 CPUID/CIM 回读。

.DESCRIPTION
    调用者显式提供 guest PSCredential 和固定 SHA-256 的 CPUID probe。probe 只会
    临时复制到 guest Windows Temp，采集完成后删除；密码不会写入磁盘或清单。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
    [Parameter(Mandatory = $true)][string]$CpuidProbePath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedCpuidProbeSha256,
    [string]$StateRoot = '',
    [ValidateRange(5, 300)][int]$ReadinessTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.HyperV.HostIdentityRuntime.ps1')
Import-Module Hyper-V -ErrorAction Stop

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -cne 'Running') {
    throw "guest identity 回读要求 VM 为 Running；当前 $($vm.State)。"
}
$probe = Assert-VMateHyperVHostIdentityRuntimeFile `
    -Path $CpuidProbePath -ExpectedSha256 $ExpectedCpuidProbeSha256 `
    -Description 'VMate direct CPUID guest probe' -AllowHashPinnedUnsigned
$status = Get-VMateHyperVHostIdentityExtensionStatus `
    -VMId ([Guid]$vm.Id) -StateRoot $StateRoot
if (-not [bool]$status.Attested -or [bool]$status.GuestVerified) {
    throw "HostIdentityExtension 必须处于 AttestedAwaitingGuestReadback。"
}
$identity = Get-VMateGpuPIdentity -VMId ([Guid]$vm.Id) -StateRoot $StateRoot
$attestation = $identity.HostIdentityExtension.Attestation
$session = $null
$guestProbe = 'C:\Windows\Temp\VMateCpuidProbe-' +
    [Guid]::NewGuid().ToString('N') + '.exe'
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
    do {
        try {
            $session = New-PSSession -VMName $VMName `
                -Credential $GuestCredential -ErrorAction Stop
        }
        catch { $session = $null }
        if ($null -eq $session) { Start-Sleep -Seconds 1 }
    } while ($null -eq $session -and [DateTime]::UtcNow -lt $deadline)
    if ($null -eq $session) {
        throw "PowerShell Direct 在 $ReadinessTimeoutSeconds 秒内未就绪。"
    }
    Copy-Item -ToSession $session -LiteralPath $probe.Path `
        -Destination $guestProbe -Force -ErrorAction Stop
    $readback = Invoke-Command -Session $session -ArgumentList @(
        [string]$status.VMId,
        [string]$status.ProfileId,
        [string]$status.ManifestSha256,
        [string]$attestation.BootId,
        $guestProbe
    ) -ScriptBlock {
        param($VMId, $ProfileId, $ManifestSha256, $BootId, $ProbePath)
        $ErrorActionPreference = 'Stop'
        $raw = @(& $ProbePath 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "direct CPUID probe 失败（$exitCode）：$($raw -join ' ')"
        }
        $cpuid = ($raw -join '') | ConvertFrom-Json -ErrorAction Stop
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $display = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { [string]$_.PNPClass -ceq 'Display' })
        $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
        $smiOutput = @()
        $smiExitCode = -1
        if ($null -ne $smi) {
            $smiOutput = @(& $smi.Source `
                '--query-gpu=name,driver_version,memory.total' `
                '--format=csv,noheader' 2>&1 |
                ForEach-Object { $_.ToString() })
            $smiExitCode = $LASTEXITCODE
        }
        return [pscustomobject][ordered]@{
            SchemaVersion = 1
            VMId = $VMId
            ProfileId = $ProfileId
            ManifestSha256 = $ManifestSha256
            BootId = $BootId
            EvidenceMethod = 'in-guest-direct-cpuid-and-cim'
            DirectCpuid = [pscustomobject][ordered]@{
                VendorId = ([string]$cpuid.Vendor).Trim()
                BrandString = ([string]$cpuid.Brand).TrimEnd()
                Leaf1EaxHex = '0x{0:X8}' -f [uint32]$cpuid.Leaf1Eax
            }
            ComputerSystem = [pscustomobject][ordered]@{
                Manufacturer = [string]$computer.Manufacturer
                Model = [string]$computer.Model
            }
            BaseBoard = [pscustomobject][ordered]@{
                Manufacturer = [string]$board.Manufacturer
                Product = [string]$board.Product
            }
            Bios = [pscustomobject][ordered]@{
                Manufacturer = [string]$bios.Manufacturer
                Version = [string]$bios.SMBIOSBIOSVersion
            }
            FunctionalGpuP = $smiExitCode -eq 0 -and
                @($display | Where-Object {
                    [string]$_.Service -ieq 'VirtualRender' -and
                    [int]$_.ConfigManagerErrorCode -eq 0
                }).Count -eq 1
            NvidiaSmi = $smiOutput
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
    } -ErrorAction Stop
    $verified = Publish-VMateHyperVHostIdentityGuestReadback `
        -VMId ([Guid]$vm.Id) -GuestReadback $readback -StateRoot $StateRoot
    [pscustomobject][ordered]@{
        VMName = $VMName
        Readback = $readback
        Status = $verified
    }
}
finally {
    if ($null -ne $session) {
        Invoke-Command -Session $session -ArgumentList $guestProbe `
            -ScriptBlock {
                param($Path)
                Remove-Item -LiteralPath $Path -Force `
                    -ErrorAction SilentlyContinue
            } -ErrorAction SilentlyContinue
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
