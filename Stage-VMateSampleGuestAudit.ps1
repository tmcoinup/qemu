param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$sourceRoot = 'C:\VMateLab\GuestAuditSource'
$guestRoot = 'C:\VMateAudit'
$serviceGuid = '6C09BB55-D683-4DA0-8931-C9BF705F6480'
$files = @(
    'Audit-VMateSampleGuest.ps1',
    'VMateCpuidProbe.exe',
    'Detect-VGpuP.ps1'
)
$rows = [Collections.Generic.List[object]]::new()

foreach ($vmName in @('pc01', 'pc02')) {
    $service = Get-VMIntegrationService -VMName $vmName -ErrorAction Stop |
        Where-Object { $_.Id.EndsWith($serviceGuid,
                [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if ($null -eq $service) {
        throw "Guest Service Interface was not found for $vmName."
    }
    $originalEnabled = [bool]$service.Enabled
    try {
        if (-not $originalEnabled) {
            Enable-VMIntegrationService -VMIntegrationService $service
        }
        $copied = [Collections.Generic.List[string]]::new()
        foreach ($fileName in $files) {
            $source = Join-Path $sourceRoot $fileName
            $destination = Join-Path $guestRoot $fileName
            Copy-VMFile -VMName $vmName -SourcePath $source `
                -DestinationPath $destination -FileSource Host `
                -CreateFullPath -Force -ErrorAction Stop
            [void]$copied.Add($fileName)
        }
        [void]$rows.Add([pscustomobject][ordered]@{
                VMName = $vmName
                Status = 'Ready'
                OriginalGuestServiceEnabled = $originalEnabled
                Copied = @($copied)
            })
    }
    catch {
        [void]$rows.Add([pscustomobject][ordered]@{
                VMName = $vmName
                Status = 'Failed'
                OriginalGuestServiceEnabled = $originalEnabled
                Message = $_.Exception.Message
            })
    }
}

@($rows) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath `
    -Encoding UTF8
