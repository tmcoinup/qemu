#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VMateGpuPDetectionProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Resolve-VMateGpuPDetectionDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()][object]$InputObject,
        [string]$Label = 'GPU-P detection result'
    )

    $document = $InputObject
    if ($InputObject -is [string]) {
        $path = [IO.Path]::GetFullPath([string]$InputObject)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$Label 不存在：$path"
        }
        try {
            $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 `
                -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop
        }
        catch { throw "$Label 不是有效 JSON：$($_.Exception.Message)" }
    }
    if ($null -eq $InputObject) { throw "$Label 不能为空。" }
    if ($null -eq $document) { throw "$Label 不能为空。" }
    if ($null -ne $document.PSObject.Properties['Verdict']) {
        return $document
    }
    foreach ($name in @('GpuPDetector', 'Detector')) {
        $property = $document.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and
            $null -ne $property.Value.PSObject.Properties['Verdict']) {
            return $property.Value
        }
    }
    throw "$Label 缺少 Verdict 或已知检测结果容器。"
}

function Get-VMateGpuPDetectionLayerCount {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][string[]]$Layers
    )

    $signals = @(Get-VMateGpuPDetectionProperty $Document 'Signals' @())
    return @($signals | Where-Object {
            [bool](Get-VMateGpuPDetectionProperty $_ 'Hit' $false) -and
            [string](Get-VMateGpuPDetectionProperty $_ 'Layer' '') -in $Layers
        }).Count
}

function Get-VMateGpuPDetectionMetrics {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Document)

    $hypervisor = Get-VMateGpuPDetectionProperty $Document `
        'HypervisorExposureSignalCount' $null
    if ($null -eq $hypervisor) {
        $hypervisor = Get-VMateGpuPDetectionLayerCount $Document @('Hypervisor')
    }
    $display = Get-VMateGpuPDetectionProperty $Document `
        'DisplayExposureSignalCount' $null
    if ($null -eq $display) {
        $display = Get-VMateGpuPDetectionLayerCount $Document @('Display')
    }
    $intrinsic = Get-VMateGpuPDetectionProperty $Document `
        'IntrinsicGpuPSignalCount' $null
    if ($null -eq $intrinsic) {
        $intrinsic = Get-VMateGpuPDetectionLayerCount $Document @('D3DKMT')
    }
    $functional = Get-VMateGpuPDetectionProperty $Document `
        'FunctionalGpuPSignalCount' $null
    if ($null -eq $functional) {
        $functional = Get-VMateGpuPDetectionProperty $Document `
            'GpuPSignalCount' $null
    }
    if ($null -eq $functional) {
        $functional = [int]$display + [int]$intrinsic
    }
    $artifact = Get-VMateGpuPDetectionProperty $Document `
        'ArtifactExposureSignalCount' $null
    if ($null -eq $artifact) {
        $artifact = [int]$hypervisor + [int]$display
    }

    return [pscustomobject][ordered]@{
        Verdict = [string](Get-VMateGpuPDetectionProperty `
                $Document 'Verdict' 'Inconclusive')
        FunctionalGpuPSignalCount = [int]$functional
        IntrinsicGpuPSignalCount = [int]$intrinsic
        HypervisorExposureSignalCount = [int]$hypervisor
        DisplayExposureSignalCount = [int]$display
        ArtifactExposureSignalCount = [int]$artifact
    }
}

function Compare-VMateGpuPDetection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Reference,
        [Parameter(Mandatory = $true)][object]$Candidate,
        [string]$ReferenceLabel = 'reference',
        [string]$CandidateLabel = 'candidate'
    )

    $referenceDocument = Resolve-VMateGpuPDetectionDocument `
        $Reference $ReferenceLabel
    $candidateDocument = Resolve-VMateGpuPDetectionDocument `
        $Candidate $CandidateLabel
    $referenceMetrics = Get-VMateGpuPDetectionMetrics $referenceDocument
    $candidateMetrics = Get-VMateGpuPDetectionMetrics $candidateDocument
    $referenceIsGpuP = $referenceMetrics.Verdict -ceq 'GPU-P'
    $candidateIsGpuP = $candidateMetrics.Verdict -ceq 'GPU-P'
    $functionalParity = $candidateIsGpuP -and
        $candidateMetrics.FunctionalGpuPSignalCount -ge
            $referenceMetrics.FunctionalGpuPSignalCount
    $intrinsicParity = $candidateMetrics.IntrinsicGpuPSignalCount -ge
        $referenceMetrics.IntrinsicGpuPSignalCount
    $concealmentParity = $candidateMetrics.ArtifactExposureSignalCount -le
        $referenceMetrics.ArtifactExposureSignalCount

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ReferenceLabel = $ReferenceLabel
        CandidateLabel = $CandidateLabel
        ReferenceIsGpuP = $referenceIsGpuP
        CandidateIsGpuP = $candidateIsGpuP
        FunctionalParity = $functionalParity
        IntrinsicGpuPParity = $intrinsicParity
        ConcealmentParity = $concealmentParity
        OverallParity = ($referenceIsGpuP -and $functionalParity -and
            $intrinsicParity -and $concealmentParity)
        Reference = $referenceMetrics
        Candidate = $candidateMetrics
        Delta = [pscustomobject][ordered]@{
            FunctionalGpuPSignalCount =
                $candidateMetrics.FunctionalGpuPSignalCount -
                $referenceMetrics.FunctionalGpuPSignalCount
            IntrinsicGpuPSignalCount =
                $candidateMetrics.IntrinsicGpuPSignalCount -
                $referenceMetrics.IntrinsicGpuPSignalCount
            ArtifactExposureSignalCount =
                $candidateMetrics.ArtifactExposureSignalCount -
                $referenceMetrics.ArtifactExposureSignalCount
        }
        Policy = 'function-at-least-reference-and-artifacts-no-more-than-reference'
    }
}
