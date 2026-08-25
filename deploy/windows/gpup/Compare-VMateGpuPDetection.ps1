#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReferenceJsonPath,
    [Parameter(Mandatory = $true)][string]$CandidateJsonPath,
    [string]$ReferenceLabel = 'reference',
    [string]$CandidateLabel = 'candidate',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VMate.GpuP.DetectionParity.ps1')

$result = Compare-VMateGpuPDetection `
    -Reference $ReferenceJsonPath -Candidate $CandidateJsonPath `
    -ReferenceLabel $ReferenceLabel -CandidateLabel $CandidateLabel
if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else { $result }

if (-not $result.OverallParity) { exit 2 }
