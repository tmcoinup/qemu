param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [Parameter(Mandatory = $true)]
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
$rows = [Collections.Generic.List[object]]::new()
$serviceGuid = '6C09BB55-D683-4DA0-8931-C9BF705F6480'
foreach ($vmName in @('pc01', 'pc02')) {
    $drives = @(Get-VMDvdDrive -VMName $vmName -ErrorAction Stop)
    $drive = $drives | Select-Object -First 1
    $created = $false
    if ($null -eq $drive) {
        $drive = Add-VMDvdDrive -VMName $vmName -Passthru -ErrorAction Stop
        $created = $true
    }
    $service = Get-VMIntegrationService -VMName $vmName |
        Where-Object { $_.Id.EndsWith($serviceGuid,
                [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    [void]$rows.Add([pscustomobject][ordered]@{
            VMName = $vmName
            ControllerNumber = [int]$drive.ControllerNumber
            ControllerLocation = [int]$drive.ControllerLocation
            OriginalPath = [string]$drive.Path
            Created = $created
            GuestServiceOriginallyEnabled = if ($null -eq $service) {
                $null
            } else {
                [bool]$service.Enabled
            }
        })
    Set-VMDvdDrive -VMName $vmName `
        -ControllerNumber $drive.ControllerNumber `
        -ControllerLocation $drive.ControllerLocation -Path $IsoPath `
        -ErrorAction Stop
}
@($rows) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath `
    -Encoding UTF8
