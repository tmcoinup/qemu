#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-VMateP11ColdStartArtifactManifest {
    [CmdletBinding()]
    param([string]$Path = '')

    if ([String]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-VMateP11ArtifactManifestPath
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    try {
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "清单不存在：$fullPath"
        }
        $manifest = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 `
            -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([int]$manifest.SchemaVersion -ne 1 -or
            [string]$manifest.ContractId -cne
                'vmate-p11-cpuid-cold-start-artifacts-v1') {
            throw 'schema/contract 不受支持。'
        }
        $partitionProbe = Get-VMateP11ManifestProperty $manifest 'PartitionProbe'
        $vidContext = Get-VMateP11ManifestProperty $manifest 'VidContextDriver'
        $cpuid = Get-VMateP11ManifestProperty $manifest 'CpuidBrandDriver'
        $inbox = Get-VMateP11ManifestProperty $manifest 'Inbox'
        $files = [Collections.Generic.List[object]]::new()
        [void]$files.Add((Assert-VMateP11ArtifactFile `
            -Path (Resolve-VMateP11ArtifactPath $fullPath ([string](
                    Get-VMateP11ManifestProperty $partitionProbe 'Path'))) `
            -ExpectedSha256 ([string](Get-VMateP11ManifestProperty `
                    $partitionProbe 'Sha256')) -Label 'VID partition probe'))
        [void]$files.Add((Assert-VMateP11ArtifactFile `
            -Path (Resolve-VMateP11ArtifactPath $fullPath ([string](
                    Get-VMateP11ManifestProperty $vidContext 'Path'))) `
            -ExpectedSha256 ([string](Get-VMateP11ManifestProperty `
                    $vidContext 'Sha256')) -Label 'VID context driver' `
            -RequireValidSignature))
        [void]$files.Add((Assert-VMateP11ArtifactFile `
            -Path (Resolve-VMateP11ArtifactPath $fullPath ([string](
                    Get-VMateP11ManifestProperty $cpuid 'Path'))) `
            -ExpectedSha256 ([string](Get-VMateP11ManifestProperty `
                    $cpuid 'Sha256')) -Label 'CPUID brand driver' `
            -RequireValidSignature))
        $inboxFiles = @(
            @('vmwp.exe', (Join-Path $env:SystemRoot 'System32\vmwp.exe'),
                'VmwpSha256'),
            @('vid.dll', (Join-Path $env:SystemRoot 'System32\vid.dll'),
                'VidDllSha256'),
            @('vid.sys', (Join-Path $env:SystemRoot 'System32\drivers\vid.sys'),
                'VidSysSha256'),
            @('Hypervisor', (Resolve-VMateP11ArtifactPath $fullPath ([string](
                        Get-VMateP11ManifestProperty $inbox 'HypervisorPath'))),
                'HypervisorSha256')
        )
        foreach ($row in $inboxFiles) {
            [void]$files.Add((Assert-VMateP11ArtifactFile -Path $row[1] `
                -ExpectedSha256 ([string](Get-VMateP11ManifestProperty `
                        $inbox $row[2])) -Label $row[0] -RequireMicrosoftSigner))
        }
        return [pscustomobject][ordered]@{
            Valid = $true
            Path = $fullPath
            Sha256 = (Get-FileHash -LiteralPath $fullPath `
                -Algorithm SHA256).Hash
            Files = @($files)
            Error = ''
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Valid = $false
            Path = $fullPath
            Sha256 = ''
            Files = @()
            Error = $_.Exception.Message
        }
    }
}

function New-VMateP11ColdStartArtifactManifest {
    [CmdletBinding()]
    param(
        [string]$GpuPRoot = $PSScriptRoot,
        [string]$Path = ''
    )

    if ([String]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-VMateP11ArtifactManifestPath
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $partitionProbe = Join-Path $GpuPRoot `
        'native\bin\VMateVidPartitionProbe.exe'
    $vidContext = Join-Path $GpuPRoot 'native\bin\VMateVidContextProbe.sys'
    $cpuid = Join-Path $GpuPRoot 'native\bin\VMateCpuidBrandExtension.sys'
    foreach ($row in @(
            @($partitionProbe, 'VID partition probe', $false),
            @($vidContext, 'VID context driver', $true),
            @($cpuid, 'CPUID brand driver', $true))) {
        if (-not (Test-Path -LiteralPath $row[0] -PathType Leaf)) {
            throw "$($row[1]) 不存在：$($row[0])"
        }
        if ([bool]$row[2]) {
            $signature = Get-AuthenticodeSignature -LiteralPath $row[0]
            if ([string]$signature.Status -cne 'Valid') {
                throw "$($row[1]) 未通过 Authenticode 验证，不能生成宿主清单。"
            }
        }
    }
    $hypervisor = @(
        (Join-Path $env:SystemRoot 'System32\hvix64.exe'),
        (Join-Path $env:SystemRoot 'System32\hvax64.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if ([String]::IsNullOrWhiteSpace([string]$hypervisor)) {
        throw '找不到当前宿主 Hyper-V hypervisor 映像。'
    }
    $vmwp = Join-Path $env:SystemRoot 'System32\vmwp.exe'
    $vidDll = Join-Path $env:SystemRoot 'System32\vid.dll'
    $vidSys = Join-Path $env:SystemRoot 'System32\drivers\vid.sys'
    foreach ($row in @(
            @($vmwp, 'vmwp.exe'), @($vidDll, 'vid.dll'),
            @($vidSys, 'vid.sys'), @($hypervisor, 'Hypervisor'))) {
        [void](Assert-VMateP11ArtifactFile -Path $row[0] `
            -ExpectedSha256 (Get-FileHash -LiteralPath $row[0] `
                -Algorithm SHA256).Hash -Label $row[1] -RequireMicrosoftSigner)
    }
    $document = [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = 'vmate-p11-cpuid-cold-start-artifacts-v1'
        PartitionProbe = [pscustomobject][ordered]@{
            Path = [IO.Path]::GetFullPath($partitionProbe)
            Sha256 = (Get-FileHash -LiteralPath $partitionProbe `
                -Algorithm SHA256).Hash
        }
        VidContextDriver = [pscustomobject][ordered]@{
            Path = [IO.Path]::GetFullPath($vidContext)
            Sha256 = (Get-FileHash -LiteralPath $vidContext `
                -Algorithm SHA256).Hash
        }
        CpuidBrandDriver = [pscustomobject][ordered]@{
            Path = [IO.Path]::GetFullPath($cpuid)
            Sha256 = (Get-FileHash -LiteralPath $cpuid `
                -Algorithm SHA256).Hash
        }
        Inbox = [pscustomobject][ordered]@{
            VmwpSha256 = (Get-FileHash -LiteralPath $vmwp `
                -Algorithm SHA256).Hash
            VidDllSha256 = (Get-FileHash -LiteralPath $vidDll `
                -Algorithm SHA256).Hash
            VidSysSha256 = (Get-FileHash -LiteralPath $vidSys `
                -Algorithm SHA256).Hash
            HypervisorPath = [IO.Path]::GetFullPath($hypervisor)
            HypervisorSha256 = (Get-FileHash -LiteralPath $hypervisor `
                -Algorithm SHA256).Hash
        }
    }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $temporary = Join-Path $directory `
        ('.cpuid-artifacts.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary,
            ($document | ConvertTo-Json -Depth 6),
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    $result = Test-VMateP11ColdStartArtifactManifest -Path $fullPath
    if (-not $result.Valid) {
        throw "生成的冷启动工件清单复检失败：$($result.Error)"
    }
    return $result
}
