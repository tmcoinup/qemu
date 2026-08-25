#Requires -Version 5.1

param(
    [string]$DetectorPath = 'C:\VMateLab\gpup-profile\Detect-VGpuP.ps1',
    [string]$OutputRoot = 'C:\VMateLab\gpup-profile'
)

$ErrorActionPreference = 'Stop'

function Get-P11LabCredential {
    $lines = Get-Content -LiteralPath `
        'C:\VMateLab\Probe-VMateP11Guest.ps1' -Encoding UTF8
    $code = ($lines[3..4] -join [Environment]::NewLine) +
        [Environment]::NewLine + 'return $credential'
    return & ([scriptblock]::Create($code))
}

function Get-SamplePassword {
    $lines = Get-Content -LiteralPath `
        'C:\VMateLab\Probe-VMateSampleGuests.ps1' -Encoding UTF8
    $code = $lines[3] + [Environment]::NewLine + 'return $password'
    return & ([scriptblock]::Create($code))
}

function Invoke-VMateLiveDetector {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$Credential
    )

    $session = $null
    $guestPath = 'C:\Windows\Temp\VMate-Detect-VGpuP.ps1'
    try {
        $session = New-PSSession -VMName $VMName -Credential $Credential `
            -ErrorAction Stop
        Copy-Item -LiteralPath $DetectorPath -Destination $guestPath `
            -ToSession $session -Force -ErrorAction Stop
        $result = Invoke-Command -Session $session -ScriptBlock {
            param($Path)
            $source = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            $source = $source -replace '(?m)^exit \$exitCode\s*$',
                'if ($exitCode -ne 0) { throw "detector failed" }'
            & ([scriptblock]::Create($source)) -Json | ConvertFrom-Json
        } -ArgumentList $guestPath -ErrorAction Stop
        $path = Join-Path $OutputRoot ("live-detector-$VMName.json")
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path `
            -Encoding UTF8
        return [pscustomobject][ordered]@{
            VMName = $VMName
            Verdict = [string]$result.Verdict
            Functional = [int]$result.FunctionalGpuPSignalCount
            Intrinsic = [int]$result.IntrinsicGpuPSignalCount
            Artifacts = [int]$result.ArtifactExposureSignalCount
            OutputPath = $path
        }
    }
    finally {
        if ($null -ne $session) {
            Invoke-Command -Session $session -ScriptBlock {
                param($Path)
                Remove-Item -LiteralPath $Path -Force `
                    -ErrorAction SilentlyContinue
            } -ArgumentList $guestPath -ErrorAction SilentlyContinue
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

$samplePassword = Get-SamplePassword
$rows = [Collections.Generic.List[object]]::new()
foreach ($vmName in @('pc01', 'pc02')) {
    $credential = New-Object System.Management.Automation.PSCredential `
        -ArgumentList ($vmName + '\Administrator'), $samplePassword
    try {
        [void]$rows.Add((Invoke-VMateLiveDetector $vmName $credential))
    }
    catch {
        [void]$rows.Add([pscustomobject][ordered]@{
                VMName = $vmName
                Verdict = 'Unavailable'
                Message = $_.Exception.Message
            })
    }
}
try {
    [void]$rows.Add((Invoke-VMateLiveDetector 'P11-Lab' `
                (Get-P11LabCredential)))
}
catch {
    [void]$rows.Add([pscustomobject][ordered]@{
            VMName = 'P11-Lab'
            Verdict = 'Unavailable'
            Message = $_.Exception.Message
        })
}
@($rows) | ConvertTo-Json -Depth 6
