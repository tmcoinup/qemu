#Requires -Version 5.1

[CmdletBinding()]
param([string]$StageRoot = 'C:\VMateLab\manager-stage')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$gpup = Join-Path $StageRoot 'deploy\windows\gpup'
$catalog = Join-Path $StageRoot 'deploy\hardware\p11-platforms.json'
$syntaxErrors = [Collections.Generic.List[string]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath $gpup -Filter '*.ps1' -File)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) {
        [void]$syntaxErrors.Add("$($file.Name): $($parseError.Message)")
    }
}
if ($syntaxErrors.Count -ne 0) {
    throw "PowerShell parse failures: $($syntaxErrors -join ' | ')"
}

. (Join-Path $gpup 'VMate.GpuP.HardwareProfile.ps1')
. (Join-Path $gpup 'VMate.GpuP.Common.ps1')
. (Join-Path $gpup 'VMate.GpuP.Lifecycle.ps1')
$profiles = @(Get-VMateGpuPHardwareProfiles -CatalogPath $catalog)
if ($profiles.Count -ne 9) { throw "Expected 9 profiles, got $($profiles.Count)" }
$pc01 = Resolve-VMateGpuPHardwareProfile `
    -ProfileId 'lab-intel-i5-13600kf-galax-b760-metaltop-d4' `
    -CatalogPath $catalog
$pc02 = Resolve-VMateGpuPHardwareProfile `
    -ProfileId 'lab-intel-i7-13700f-msi-b760m-bomber-wifi' `
    -CatalogPath $catalog
if ($pc01.Processor.Count -ne 20 -or $pc02.Processor.Count -ne 20 -or
    [string]$pc01.Platform.product -ceq [string]$pc02.Platform.product) {
    throw 'Reference profile CPU/board bundles are not distinct and complete.'
}
$strictRejected = $false
try {
    Resolve-VMateGpuPHardwareProfile -ProfileId $pc01.Id `
        -CatalogPath $catalog -RequireFullIdentity | Out-Null
}
catch { $strictRejected = $true }
if (-not $strictRejected) { throw 'Unsupported strict identity was accepted.' }
$splitRejected = $false
try {
    Assert-VMateGpuPHardwareProfileOverrides $pc01 @{ ProcessorCount = 4 } |
        Out-Null
}
catch { $splitRejected = $true }
if (-not $splitRejected) { throw 'Split CPU override was accepted.' }
$quota = Resolve-VMateGpuPQuotaRequest -Percentages @{
    VramPercentage = 50
    EncodePercentage = 50
    DecodePercentage = 50
    ComputePercentage = 50
} -FullSharedGpuQuota
if ($quota.QuotaMode -cne 'FullHostReportedGpuPQuota' -or
    $quota.Percentages.VramPercentage -ne 100 -or
    -not $quota.EffectiveAllowOvercommit) {
    throw 'Full shared GPU quota did not resolve to the host-reported maximum.'
}
$plan = Get-VMateGpuPVirtualMachinePlan `
    -VMName 'VMate-P11-999' `
    -VhdPath (Join-Path $StageRoot 'dryrun-never-created.vhdx') `
    -CreateVhd -VhdSizeBytes 127GB `
    -IsoPath 'C:\VMateLab\VMateSampleGuestAudit.iso' `
    -HardwareProfileId $pc02.Id -HardwareProfileCatalogPath $catalog
if ($plan.ProcessorCount -ne 20 -or $plan.MemoryStartupBytes -ne 8GB -or
    $plan.HardwareProfile.IdentityFidelity -cne 'host-extension-required') {
    throw 'P-11 profile dry-run did not preserve the atomic compute/fidelity plan.'
}

$facade = Join-Path $gpup 'VMateGpuP.Client.ps1'
$statusText = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $facade `
    -Action Status -VMName 'VMate-P11-999' 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "Facade status failed: $statusText" }
$status = $statusText.Trim() | ConvertFrom-Json
if ($status.Exists -or $status.State -cne 'Missing') {
    throw 'Facade missing-VM status contract failed.'
}

[pscustomobject][ordered]@{
    PowerShellVersion = [string]$PSVersionTable.PSVersion
    ParsedScriptCount = @(Get-ChildItem -LiteralPath $gpup -Filter '*.ps1' -File).Count
    EnabledProfileCount = $profiles.Count
    Pc01Processor = [string]$pc01.Processor.Name
    Pc01Board = [string]$pc01.Platform.product
    Pc02Processor = [string]$pc02.Processor.Name
    Pc02Board = [string]$pc02.Platform.product
    StrictUnsupportedRejected = $strictRejected
    SplitOverrideRejected = $splitRejected
    FullQuotaMode = [string]$quota.QuotaMode
    DryRunProfile = [string]$plan.HardwareProfile.ProfileId
    DryRunProcessorCount = [int]$plan.ProcessorCount
    FacadeStatus = [string]$status.State
} | ConvertTo-Json -Depth 6
