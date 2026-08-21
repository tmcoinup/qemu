#Requires -Version 5.1

<#
.SYNOPSIS
  Install, verify or roll back the VM-bound G-11 system NVAPI projection.

.DESCRIPTION
  This coordinator publishes the same catalog identity to both Windows NVAPI
  search paths.  It is process-agnostic: x86 and x64 callers receive the same
  committed profile, while unrecognized NVAPI calls continue to the original,
  production-signed NVIDIA DLL kept beside the shim.

  The coordinator never changes BCD, boot policy, kernel drivers or driver
  signatures.  It refuses to run when testsigning/nointegritychecks are enabled,
  when the package UUID/Display/driver does not match, or when either system
  NVAPI pair contains an unknown file.
#>
[CmdletBinding()]
param(
    [ValidateSet(
        'Install', 'Verify', 'Uninstall', 'VerifyUninstall',
        'RefreshMonitor', 'RefreshIdentity'
    )]
    [string]$Action = 'Install',
    [string]$PayloadDir = '',
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ManifestName = 'system-nvapi-manifest.json'
$ContractName = 'system-nvapi-contract.json'
$StateRoot = Join-Path ([Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData)) `
    'G11\SystemNvapiProjection'
$ReceiptRoot = Join-Path $StateRoot 'receipts'
$CloneComputerNameState = Join-Path $StateRoot 'private-clone-computer-name.json'
$TaskPrefix = 'G11-System-NVAPI-'
$MonitorTaskPrefix = 'G11-Monitor-Identity-'
if ([string]::IsNullOrWhiteSpace($PayloadDir)) {
    # Windows PowerShell 5.1 binds script parameters before $PSScriptRoot is
    # reliably available to a default-value expression.  Resolve it only
    # after param binding so an ISO root such as G:\ remains a legal path.
    $PayloadDir = $PSScriptRoot
}
$ExpectedPayloadNames = @(
    'install-system-nvapi-projection.ps1',
    'install-nvapi-shim.ps1',
    'patch-grid-strings.ps1',
    'vgpu-profile-catalog.json',
    'nvapi.dll',
    'nvapi64.dll',
    'SystemNvapiProbe32.exe',
    'SystemNvapiProbe64.exe',
    'D3D12CapabilityProbe32.exe',
    'D3D12CapabilityProbe64.exe',
    'monitor-edid.bin',
    $ContractName
)

function Write-Step([string]$Message) {
    Write-Host "[system-nvapi] $Message" -ForegroundColor Cyan
}

function Assert-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '请右键 Run-As-Administrator.cmd，以管理员身份运行。'
    }
    if (-not [Environment]::Is64BitOperatingSystem -or
        -not [Environment]::Is64BitProcess) {
        throw '系统投影只允许由 64 位 PowerShell 在 64 位 Windows 上运行。'
    }
}

function Get-RegularFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context 必须是普通、非重解析文件：$Path"
    }
    return $item
}

function Assert-PlainDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.DirectoryInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "目录必须是普通、非重解析目录：$Path"
    }
}

function New-ProtectedDirectory([string]$Path) {
    $null = New-Item -Path $Path -ItemType Directory -Force
    Assert-PlainDirectory $Path
    $administrators = New-Object Security.Principal.SecurityIdentifier `
        -ArgumentList 'S-1-5-32-544'
    $system = New-Object Security.Principal.SecurityIdentifier `
        -ArgumentList 'S-1-5-18'
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetOwner($administrators)
    $security.SetAccessRuleProtection($true, $false)
    $inherit = (
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    )
    foreach ($sid in @($administrators, $system)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule `
            -ArgumentList @(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inherit,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-PeMachine([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "不是有效 PE 文件：$Path"
    }
    $offset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($offset -lt 0x40 -or $offset + 6 -gt $bytes.Length -or
        $bytes[$offset] -ne 0x50 -or $bytes[$offset + 1] -ne 0x45 -or
        $bytes[$offset + 2] -ne 0 -or $bytes[$offset + 3] -ne 0) {
        throw "PE 头无效：$Path"
    }
    return [int][BitConverter]::ToUInt16($bytes, $offset + 4)
}

function Assert-OriginalNvidiaImage([string]$Path, [int]$Machine) {
    $item = Get-RegularFile $Path 'NVIDIA 原始 NVAPI'
    if ((Get-PeMachine $item.FullName) -ne $Machine) {
        throw "NVIDIA 原始 NVAPI 架构不匹配：$Path"
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName)
    $signature = Get-AuthenticodeSignature -LiteralPath $item.FullName
    $certificate = $signature.SignerCertificate
    $subject = if ($null -ne $certificate) { [string]$certificate.Subject } else { '' }
    $trustedSigner = $subject -match 'NVIDIA' -or
        $subject -match '\ACN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)'
    if ($version.CompanyName -notmatch '\ANVIDIA(?: Corporation)?\z' -or
        [string]$signature.Status -cne 'Valid' -or $null -eq $certificate -or
        $subject -ceq [string]$certificate.Issuer -or -not $trustedSigner) {
        throw "原始 NVAPI 不是有效 NVIDIA/WHCP 签名文件：$Path"
    }
    $ascii = [Text.Encoding]::ASCII.GetString(
        [IO.File]::ReadAllBytes($item.FullName))
    if ($ascii.Contains('IdentityGpuName')) {
        throw "原始 NVAPI 位置不能是身份投影 DLL：$Path"
    }
}

function Assert-ExactPropertyNames($Object, [string[]]$Names, [string]$Context) {
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (@(Compare-Object $expected $actual).Count -ne 0) {
        throw "$Context 含缺失或额外字段。"
    }
}

function Get-EdidPnpVendor([byte[]]$Bytes) {
    if ($Bytes.Length -lt 12) { throw 'EDID 太短，无法解析 PNP vendor。' }
    $word = ([int]$Bytes[8] -shl 8) -bor [int]$Bytes[9]
    $codes = @(
        (($word -shr 10) -band 0x1F),
        (($word -shr 5) -band 0x1F),
        ($word -band 0x1F)
    )
    if (@($codes | Where-Object { $_ -lt 1 -or $_ -gt 26 }).Count -ne 0) {
        throw 'EDID PNP vendor 编码无效。'
    }
    return -join @($codes | ForEach-Object { [char](64 + $_) })
}

function Test-ByteArrayEqual([byte[]]$Left, [byte[]]$Right) {
    if ($null -eq $Left -or $null -eq $Right -or
        $Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Test-MonitorBaseIdentity([byte[]]$Bytes, $Monitor) {
    if ($null -eq $Bytes -or $Bytes.Length -lt 128) { return $false }
    [byte[]]$header = @(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)
    for ($index = 0; $index -lt $header.Length; $index++) {
        if ($Bytes[$index] -ne $header[$index]) { return $false }
    }
    $sum = 0
    for ($index = 0; $index -lt 128; $index++) {
        $sum = ($sum + [int]$Bytes[$index]) -band 0xFF
    }
    if ($sum -ne 0) { return $false }
    try { $vendor = Get-EdidPnpVendor $Bytes } catch { return $false }
    $product = [int]$Bytes[10] -bor ([int]$Bytes[11] -shl 8)
    return $vendor -ceq [string]$Monitor.pnpVendor -and
        $product -eq [int]$Monitor.productId
}

function Assert-MonitorEdidFile([string]$Path, $Monitor) {
    $item = Get-RegularFile $Path 'monitor EDID'
    [byte[]]$bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -ne 256 -or [int]$bytes[126] -ne 1 -or
        -not (Test-MonitorBaseIdentity $bytes $Monitor)) {
        throw 'monitor EDID 不是合同指定的 256-byte PNP 身份。'
    }
    for ($block = 0; $block -lt 2; $block++) {
        $sum = 0
        for ($index = 0; $index -lt 128; $index++) {
            $sum = ($sum + [int]$bytes[$block * 128 + $index]) -band 0xFF
        }
        if ($sum -ne 0) { throw "monitor EDID block $block checksum 无效。" }
    }
    return $bytes
}

function Read-Payload([string]$Root) {
    $resolved = [IO.Path]::GetFullPath($Root)
    Assert-PlainDirectory $resolved
    $manifestPath = Join-Path $resolved $ManifestName
    $manifestItem = Get-RegularFile $manifestPath 'payload manifest'
    try {
        $manifest = Get-Content -LiteralPath $manifestItem.FullName -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "payload manifest JSON 无效：$($_.Exception.Message)"
    }
    Assert-ExactPropertyNames $manifest @(
        'schemaVersion', 'purpose', 'contractId', 'files'
    ) 'payload manifest'
    if ([int]$manifest.schemaVersion -ne 1 -or
        [string]$manifest.purpose -cne 'g11-system-nvapi-projection' -or
        [string]$manifest.contractId -cnotmatch '^[0-9A-F]{64}$') {
        throw 'payload manifest 头部无效。'
    }
    $files = @($manifest.files)
    if ($files.Count -ne $ExpectedPayloadNames.Count) {
        throw 'payload manifest 文件数量不正确。'
    }
    $seen = @{}
    foreach ($entry in $files) {
        Assert-ExactPropertyNames $entry @('path', 'bytes', 'sha256') `
            'payload manifest file'
        $name = [string]$entry.path
        if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
            $seen.ContainsKey($name) -or $ExpectedPayloadNames -cnotcontains $name -or
            [string]$entry.sha256 -cnotmatch '^[0-9A-F]{64}$' -or
            [int64]$entry.bytes -lt 1) {
            throw "payload manifest 文件条目无效：$name"
        }
        $seen[$name] = $true
        $item = Get-RegularFile (Join-Path $resolved $name) "payload $name"
        if ([int64]$item.Length -ne [int64]$entry.bytes -or
            (Get-Sha256 $item.FullName) -cne [string]$entry.sha256) {
            throw "payload 文件摘要/大小不匹配：$name"
        }
    }
    foreach ($name in $ExpectedPayloadNames) {
        if (-not $seen.ContainsKey($name)) {
            throw "payload 缺少必需文件：$name"
        }
    }
    $contractPath = Join-Path $resolved $ContractName
    try {
        $contract = Get-Content -LiteralPath $contractPath -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "system NVAPI contract JSON 无效：$($_.Exception.Message)"
    }
    Assert-ExactPropertyNames $contract @(
        'schemaVersion', 'purpose', 'contractId', 'vmId', 'vmUuid',
        'sourceConfigSha256', 'identityCatalogSha256', 'transport', 'profile',
        'monitor', 'payload'
    ) 'system NVAPI contract'
    Assert-ExactPropertyNames $contract.transport @(
        'targetPnpId', 'driverVersion', 'gpuName', 'pciVendorId',
        'pciDeviceId', 'pciProjectionMode'
    ) 'contract.transport'
    Assert-ExactPropertyNames $contract.payload @(
        'coordinatorSha256', 'lowLevelInstallerSha256',
        'profileWriterSha256', 'identityCatalogJsonSha256',
        'shimX86Sha256', 'shimX64Sha256', 'probeX86Sha256', 'probeX64Sha256',
        'd3dProbeX86Sha256', 'd3dProbeX64Sha256'
    ) 'contract.payload'
    Assert-ExactPropertyNames $contract.monitor @(
        'key', 'pnpVendor', 'productId', 'pnpId', 'edidName', 'displayName',
        'manufacturer', 'serial', 'edidSha256'
    ) 'contract.monitor'
    Assert-ExactPropertyNames $contract.profile @(
        'key', 'name', 'boardBrand', 'boardModel', 'memoryTypeName',
        'memoryMakerName', 'memoryMakerNvapiName', 'identityScope',
        'pciVendorId', 'pciDeviceId', 'pciSubVendorId', 'pciSubDeviceId',
        'pciRevisionId', 'coreClockMHz', 'boostClockMHz', 'memoryClockMHz',
        'memoryBusBits', 'memoryBandwidthMBps', 'vramMB', 'memoryType',
        'memoryMaker', 'cudaCores', 'shaderSubPipes', 'ropCount', 'tmuCount',
        'architecture', 'implementation', 'chipRevision', 'pcieWidth',
        'd3d12RaytracingTier', 'rayTracingCores', 'tensorCores',
        'vbiosVersion'
    ) 'contract.profile'
    if ([int]$contract.schemaVersion -ne 4 -or
        [string]$contract.purpose -cne 'g11-system-nvapi-projection' -or
        [string]$contract.contractId -cne [string]$manifest.contractId -or
        [string]$contract.contractId -cnotmatch '^[0-9A-F]{64}$' -or
        [int64]$contract.vmId -lt 1 -or [int64]$contract.vmId -gt 2147483647 -or
        [string]$contract.vmUuid -cnotmatch
            '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        [string]$contract.sourceConfigSha256 -cnotmatch '^[0-9A-F]{64}$' -or
        [string]$contract.identityCatalogSha256 -cnotmatch '^[0-9A-F]{64}$' -or
        [string]$contract.transport.targetPnpId -cnotmatch
            '^PCI\\VEN_10DE&DEV_[0-9A-F]{4}(&SUBSYS_[0-9A-F]{8})?$' -or
        [string]$contract.transport.driverVersion -cnotmatch
            '^[0-9]+(\.[0-9]+){3}$' -or
        [int64]$contract.transport.pciVendorId -lt 1 -or
        [int64]$contract.transport.pciVendorId -gt 65535 -or
        [int64]$contract.transport.pciDeviceId -lt 1 -or
        [int64]$contract.transport.pciDeviceId -gt 65535 -or
        [string]$contract.transport.pciProjectionMode -cne
            'transport-device-profile-subsystem' -or
        [string]$contract.profile.key -cnotmatch '^[a-z0-9_]+$' -or
        [string]$contract.profile.name -cne [string]$contract.transport.gpuName -or
        [int]$contract.profile.vramMB -notin @(1024, 2048) -or
        [int]$contract.profile.memoryType -ne 8 -or
        [int]$contract.profile.memoryMaker -notin @(1, 6, 10) -or
        [int]$contract.profile.d3d12RaytracingTier -ne 0 -or
        [int]$contract.profile.rayTracingCores -ne 0 -or
        [int]$contract.profile.tensorCores -ne 0 -or
        [string]$contract.monitor.key -cnotmatch
            '^[a-z0-9][a-z0-9-]{0,47}$' -or
        [string]$contract.monitor.pnpVendor -cnotmatch '^[A-Z]{3}$' -or
        [int]$contract.monitor.productId -lt 1 -or
        [int]$contract.monitor.productId -gt 65535 -or
        [string]$contract.monitor.pnpId -cne
            (([string]$contract.monitor.pnpVendor) +
             ([int]$contract.monitor.productId).ToString('X4')) -or
        [string]$contract.monitor.edidName -cnotmatch '^[\x20-\x7E]{1,12}$' -or
        [string]::IsNullOrWhiteSpace([string]$contract.monitor.displayName) -or
        [string]::IsNullOrWhiteSpace([string]$contract.monitor.manufacturer) -or
        -not ([string]$contract.monitor.displayName).StartsWith(
            ([string]$contract.monitor.manufacturer) + ' ',
            [StringComparison]::Ordinal) -or
        [string]$contract.monitor.serial -cnotmatch '^[A-Z0-9]{2,20}$' -or
        [string]$contract.monitor.edidSha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw 'system NVAPI contract 身份字段无效。'
    }
    $transportPnpPrefix = 'PCI\VEN_{0:X4}&DEV_{1:X4}' -f
        [int64]$contract.transport.pciVendorId,
        [int64]$contract.transport.pciDeviceId
    if ([string]$contract.transport.targetPnpId -cne $transportPnpPrefix -and
        -not ([string]$contract.transport.targetPnpId).StartsWith(
            $transportPnpPrefix + '&', [StringComparison]::Ordinal)) {
        throw 'transport PCI 数值与 targetPnpId 不一致。'
    }
    $fileHashes = @{}
    foreach ($entry in $files) { $fileHashes[[string]$entry.path] = [string]$entry.sha256 }
    if ([string]$contract.payload.coordinatorSha256 -cne
            $fileHashes['install-system-nvapi-projection.ps1'] -or
        [string]$contract.payload.lowLevelInstallerSha256 -cne
            $fileHashes['install-nvapi-shim.ps1'] -or
        [string]$contract.payload.profileWriterSha256 -cne
            $fileHashes['patch-grid-strings.ps1'] -or
        [string]$contract.payload.identityCatalogJsonSha256 -cne
            $fileHashes['vgpu-profile-catalog.json'] -or
        [string]$contract.payload.shimX86Sha256 -cne $fileHashes['nvapi.dll'] -or
        [string]$contract.payload.shimX64Sha256 -cne $fileHashes['nvapi64.dll'] -or
        [string]$contract.payload.probeX86Sha256 -cne
            $fileHashes['SystemNvapiProbe32.exe'] -or
        [string]$contract.payload.probeX64Sha256 -cne
            $fileHashes['SystemNvapiProbe64.exe'] -or
        [string]$contract.payload.d3dProbeX86Sha256 -cne
            $fileHashes['D3D12CapabilityProbe32.exe'] -or
        [string]$contract.payload.d3dProbeX64Sha256 -cne
            $fileHashes['D3D12CapabilityProbe64.exe'] -or
        [string]$contract.monitor.edidSha256 -cne
            $fileHashes['monitor-edid.bin']) {
        throw 'contract payload 摘要与 manifest 不一致。'
    }
    $null = Assert-MonitorEdidFile (Join-Path $resolved 'monitor-edid.bin') `
        $contract.monitor
    $catalog = Get-Content -LiteralPath (Join-Path $resolved `
        'vgpu-profile-catalog.json') -Raw | ConvertFrom-Json -ErrorAction Stop
    if ([int]$catalog.schemaVersion -ne 2 -or
        [string]$catalog.catalogSha256 -cne
            [string]$contract.identityCatalogSha256) {
        throw '身份目录与 system NVAPI contract 不一致。'
    }
    return [pscustomobject]@{
        Root = $resolved
        Manifest = $manifest
        Contract = $contract
    }
}

function Copy-PayloadDurably($Payload) {
    New-ProtectedDirectory $StateRoot
    $target = Join-Path $StateRoot ([string]$Payload.Contract.contractId)
    if (Test-Path -LiteralPath $target) {
        $existing = Read-Payload $target
        return $existing.Root
    }
    $stage = Join-Path $StateRoot ('.stage-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-ProtectedDirectory $stage
        foreach ($entry in @($Payload.Manifest.files)) {
            Copy-Item -LiteralPath (Join-Path $Payload.Root ([string]$entry.path)) `
                -Destination (Join-Path $stage ([string]$entry.path))
        }
        Copy-Item -LiteralPath (Join-Path $Payload.Root $ManifestName) `
            -Destination (Join-Path $stage $ManifestName)
        $null = Read-Payload $stage
        Move-Item -LiteralPath $stage -Destination $target -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return (Read-Payload $target).Root
}

function Get-V11ComputerName($Contract) {
    try {
        $compact = ([Guid]$Contract.vmUuid).ToString('N').ToUpperInvariant()
    } catch {
        throw '无法从合同 UUID 生成 V-11 风格主机名。'
    }
    return 'DESKTOP-' + $compact.Substring(0, 7)
}

function Test-PayloadRootIsCdRom([string]$Root) {
    try {
        $driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Root))
        if ([string]::IsNullOrWhiteSpace($driveRoot)) { return $false }
        $drive = New-Object IO.DriveInfo -ArgumentList $driveRoot
        return $drive.IsReady -and
            $drive.DriveType -eq [IO.DriveType]::CDRom
    } catch {
        return $false
    }
}

function Write-CloneComputerNameState($Contract, [string]$ComputerName) {
    New-ProtectedDirectory $StateRoot
    $state = [ordered]@{
        schemaVersion = 1
        purpose = 'g11-private-clone-computer-name'
        contractId = [string]$Contract.contractId
        vmUuid = ([Guid]$Contract.vmUuid).ToString('D').ToLowerInvariant()
        computerName = $ComputerName
    }
    $temporary = "$CloneComputerNameState.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary,
            (($state | ConvertTo-Json -Compress) + "`r`n"),
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $CloneComputerNameState `
            -Force -ErrorAction Stop
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Read-CloneComputerNameState($Contract) {
    if (-not (Test-Path -LiteralPath $CloneComputerNameState -PathType Leaf)) {
        return $null
    }
    $item = Get-RegularFile $CloneComputerNameState 'private clone computer-name state'
    $state = Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    Assert-ExactPropertyNames $state @(
        'schemaVersion', 'purpose', 'contractId', 'vmUuid', 'computerName'
    ) 'private clone computer-name state'
    $expected = Get-V11ComputerName $Contract
    if ([int]$state.schemaVersion -ne 1 -or
        [string]$state.purpose -cne 'g11-private-clone-computer-name' -or
        [string]$state.contractId -cne [string]$Contract.contractId -or
        ([Guid]$state.vmUuid).ToString('D').ToLowerInvariant() -cne
            ([Guid]$Contract.vmUuid).ToString('D').ToLowerInvariant() -or
        [string]$state.computerName -cne $expected) {
        throw 'private clone computer-name state 与当前 VM 合同不一致。'
    }
    return $state
}

function Prepare-V11CloneComputerName($Payload) {
    $state = Read-CloneComputerNameState $Payload.Contract
    if ($null -eq $state -and
        -not (Test-PayloadRootIsCdRom $Payload.Root)) {
        # A manually unpacked system-NVAPI package is not a private clone
        # bootstrap and must not rename an existing operator-managed machine.
        return
    }
    $expected = Get-V11ComputerName $Payload.Contract
    if ([string]$env:COMPUTERNAME -cne $expected) {
        if (-not (Get-Command Rename-Computer -ErrorAction SilentlyContinue)) {
            throw '系统缺少 Rename-Computer，无法应用 V-11 风格主机名。'
        }
        Rename-Computer -NewName $expected -Force -ErrorAction Stop
        $pending = [string](Get-ItemProperty -LiteralPath `
            'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
            -Name ComputerName -ErrorAction Stop).ComputerName
        if ($pending -cne $expected) {
            throw "主机名重启待生效值不匹配：$pending"
        }
        Write-Host "COMPUTER_NAME_PENDING PASS name=$expected" `
            -ForegroundColor Green
    }
    Write-CloneComputerNameState $Payload.Contract $expected
}

function Assert-V11CloneComputerName($Contract) {
    $state = Read-CloneComputerNameState $Contract
    if ($null -eq $state) { return }
    $expected = Get-V11ComputerName $Contract
    if ([string]$env:COMPUTERNAME -cne $expected) {
        throw "V-11 风格主机名未在重启后生效：$($env:COMPUTERNAME) != $expected"
    }
    Write-Host "COMPUTER_NAME_VERIFY PASS name=$expected" `
        -ForegroundColor Green
}

function Initialize-StorageEjectApi {
    if ($null -ne ('VMate.G11.StorageMedia' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace VMate.G11 {
    public static class StorageMedia {
        private const uint GENERIC_READ = 0x80000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint IOCTL_STORAGE_EJECT_MEDIA = 0x002D4808;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName, uint desiredAccess, uint shareMode,
            IntPtr securityAttributes, uint creationDisposition,
            uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            SafeFileHandle device, uint controlCode,
            IntPtr inBuffer, uint inBufferSize,
            IntPtr outBuffer, uint outBufferSize,
            out uint bytesReturned, IntPtr overlapped);

        public static void Eject(string driveName) {
            string normalized = driveName.TrimEnd('\\');
            if (normalized.Length != 2 || normalized[1] != ':') {
                throw new ArgumentException("Not a drive-letter root", "driveName");
            }
            using (SafeFileHandle handle = CreateFileW(
                @"\\.\" + normalized, GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
                OPEN_EXISTING, 0, IntPtr.Zero)) {
                if (handle.IsInvalid) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Could not open payload CD-ROM");
                }
                uint returned;
                if (!DeviceIoControl(handle, IOCTL_STORAGE_EJECT_MEDIA,
                        IntPtr.Zero, 0, IntPtr.Zero, 0,
                        out returned, IntPtr.Zero)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Could not eject payload CD-ROM");
                }
            }
        }
    }
}
'@
}

function Eject-MatchingPayloadMedia($Contract) {
    Initialize-StorageEjectApi
    $ejected = 0
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady -or
                $drive.DriveType -ne [IO.DriveType]::CDRom) { continue }
        } catch {
            # A removable drive can disappear during enumeration.
            continue
        }
        $contractPath = Join-Path $drive.RootDirectory.FullName $ContractName
        try {
            $candidateContract = Get-Content -LiteralPath $contractPath `
                -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        if ([string]$candidateContract.contractId -cne
            [string]$Contract.contractId -or
            [string]$candidateContract.vmUuid -cne
            [string]$Contract.vmUuid) { continue }
        try {
            # A matching label/contract is security-sensitive: validate the
            # complete manifest again before using it as the detach signal.
            $candidate = Read-Payload $drive.RootDirectory.FullName
            if ([string]$candidate.Contract.contractId -cne
                [string]$Contract.contractId) {
                throw 'matching payload contract changed while being read'
            }
            [VMate.G11.StorageMedia]::Eject($drive.Name)
        } catch {
            throw "无法弹出已复制的 VM-bound 初始化光盘 $($drive.Name)：$($_.Exception.Message)"
        }
        $ejected++
        Write-Host ("INIT_MEDIA_EJECT PASS drive={0} contract={1}" -f
            $drive.Name, [string]$Contract.contractId) -ForegroundColor Green
    }
    return $ejected
}

function Get-TrustedPriorShimHashes($Payload) {
    $result = [ordered]@{ X86 = @(); X64 = @() }
    if (-not (Test-Path -LiteralPath $ReceiptRoot -PathType Container)) {
        return [pscustomobject]$result
    }
    Assert-PlainDirectory $ReceiptRoot

    $x86 = @{}
    $x64 = @{}
    foreach ($item in @(Get-ChildItem -LiteralPath $ReceiptRoot -Force |
            Where-Object {
                $_.Name -cmatch '^[0-9A-F]{64}-validated\.json$'
            })) {
        try {
            $receiptFile = Get-RegularFile $item.FullName 'validated receipt'
            $receipt = Get-Content -LiteralPath $receiptFile.FullName -Raw |
                ConvertFrom-Json -ErrorAction Stop
            if ([int]$receipt.schemaVersion -ne 2 -or
                [string]$receipt.purpose -cne 'g11-system-nvapi-projection' -or
                [string]$receipt.state -cne 'validated' -or
                [string]$receipt.contractId -cnotmatch '^[0-9A-F]{64}$' -or
                $item.Name -cne
                    (([string]$receipt.contractId) + '-validated.json') -or
                [int64]$receipt.vmId -ne [int64]$Payload.Contract.vmId -or
                [string]$receipt.vmUuid -cne [string]$Payload.Contract.vmUuid -or
                [string]$receipt.driverVersion -cne
                    [string]$Payload.Contract.transport.driverVersion -or
                -not (Test-PnpPrefix ([string]$receipt.displayInstanceId) `
                    ([string]$Payload.Contract.transport.targetPnpId)) -or
                [string]$receipt.shimX86Sha256 -cnotmatch '^[0-9A-F]{64}$' -or
                [string]$receipt.shimX64Sha256 -cnotmatch '^[0-9A-F]{64}$') {
                continue
            }

            # A receipt alone is not enough.  Its protected durable payload
            # must still contain the exact manifest-pinned DLL bytes.  This
            # also permits upgrades from an older contract schema without
            # relaxing validation of the executable images themselves.
            $priorRoot = Join-Path $StateRoot ([string]$receipt.contractId)
            Assert-PlainDirectory $priorRoot
            $manifestFile = Get-RegularFile (Join-Path $priorRoot $ManifestName) `
                'prior payload manifest'
            $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw |
                ConvertFrom-Json -ErrorAction Stop
            if ([int]$manifest.schemaVersion -ne 1 -or
                [string]$manifest.purpose -cne
                    'g11-system-nvapi-projection' -or
                [string]$manifest.contractId -cne [string]$receipt.contractId) {
                continue
            }
            foreach ($candidate in @(
                [pscustomobject]@{
                    Name = 'nvapi.dll'; Hash = [string]$receipt.shimX86Sha256
                    Machine = 0x014C; Set = $x86
                },
                [pscustomobject]@{
                    Name = 'nvapi64.dll'; Hash = [string]$receipt.shimX64Sha256
                    Machine = 0x8664; Set = $x64
                }
            )) {
                $entries = @($manifest.files | Where-Object {
                    [string]$_.path -ceq [string]$candidate.Name
                })
                if ($entries.Count -ne 1 -or
                    [string]$entries[0].sha256 -cne [string]$candidate.Hash -or
                    [int64]$entries[0].bytes -lt 1) {
                    throw "prior payload manifest mismatch: $($candidate.Name)"
                }
                $image = Get-RegularFile (Join-Path $priorRoot $candidate.Name) `
                    "prior payload $($candidate.Name)"
                if ([int64]$image.Length -ne [int64]$entries[0].bytes -or
                    (Get-Sha256 $image.FullName) -cne [string]$candidate.Hash) {
                    throw "prior payload digest mismatch: $($candidate.Name)"
                }
                if ((Get-PeMachine $image.FullName) -ne [int]$candidate.Machine) {
                    throw "prior payload PE architecture mismatch: $($candidate.Name)"
                }
                $ascii = [Text.Encoding]::ASCII.GetString(
                    [IO.File]::ReadAllBytes($image.FullName))
                if (-not $ascii.Contains('IdentityGpuName') -or
                    -not $ascii.Contains('nvapi_QueryInterface')) {
                    throw "prior payload is not a managed identity shim: $($candidate.Name)"
                }
                $candidate.Set[[string]$candidate.Hash] = $true
            }
        } catch {
            Write-Warning ("忽略不可验证的旧投影收据 {0}：{1}" -f
                $item.FullName, $_.Exception.Message)
        }
    }
    $result.X86 = @($x86.Keys | Sort-Object)
    $result.X64 = @($x64.Keys | Sort-Object)
    return [pscustomobject]$result
}

function Get-NormalBcdSnapshot {
    $bcdedit = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
    $output = (& $bcdedit /enum all 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "无法只读检查 BCD：$output"
    }
    foreach ($flag in @('testsigning', 'nointegritychecks')) {
        foreach ($line in @($output -split "`r?`n" |
                Where-Object { $_ -match "^\s*$flag\s+" })) {
            if ($line -notmatch '(?i)\b(no|off|false|0)\s*$') {
                throw "$flag 已启用或状态未知；本工具不会修改 BCD。"
            }
        }
    }
    $normalized = (($output -replace "`r`n", "`n") -replace "`r", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized.TrimEnd() + "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Test-PnpPrefix([string]$Actual, [string]$Expected) {
    if ([string]::IsNullOrWhiteSpace($Actual)) { return $false }
    $actualUpper = $Actual.Trim().ToUpperInvariant()
    $expectedUpper = $Expected.Trim().ToUpperInvariant()
    return $actualUpper -eq $expectedUpper -or
        $actualUpper.StartsWith($expectedUpper + '&', [StringComparison]::Ordinal) -or
        $actualUpper.StartsWith($expectedUpper + '\', [StringComparison]::Ordinal)
}

function Get-GuestTransport($Contract) {
    $products = @(Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop)
    if ($products.Count -ne 1 -or
        [Guid]$products[0].UUID -ne [Guid]$Contract.vmUuid) {
        throw "该包只适用于 vm$($Contract.vmId) / $($Contract.vmUuid)。"
    }
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
        throw '系统缺少 Get-PnpDevice，无法验证唯一 Display。'
    }
    $displays = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop)
    if ($displays.Count -ne 1 -or
        -not (Test-PnpPrefix ([string]$displays[0].InstanceId) `
            ([string]$Contract.transport.targetPnpId))) {
        throw "需要唯一且匹配合同的 Display；当前数量=$($displays.Count)。"
    }
    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
        Where-Object {
            [string]$_.PNPDeviceID -ieq [string]$displays[0].InstanceId
        })
    if ($controllers.Count -ne 1 -or
        [int]$controllers[0].ConfigManagerErrorCode -ne 0 -or
        [string]$controllers[0].DriverVersion -cne
            [string]$Contract.transport.driverVersion -or
        [string]$controllers[0].Name -cne [string]$Contract.transport.gpuName) {
        throw 'Display 不是合同指定的 Code 0 / 驱动版本 / GPU 名称。'
    }
    $signed = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { [string]$_.DeviceID -ieq [string]$displays[0].InstanceId })
    if ($signed.Count -ne 1 -or -not [bool]$signed[0].IsSigned -or
        [string]$signed[0].DriverProviderName -notmatch
            '\ANVIDIA(?: Corporation)?\z') {
        throw '当前 Display 未绑定唯一的生产签名 NVIDIA 驱动。'
    }
    return [pscustomobject]@{
        Display = $displays[0]
        Controller = $controllers[0]
        SignedDriver = $signed[0]
    }
}

function Wait-GuestTransport($Contract, [int]$Seconds = 300) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $last = ''
    do {
        try {
            return Get-GuestTransport $Contract
        } catch {
            $last = $_.Exception.Message
            if ((Get-Date) -ge $deadline) {
                throw "Display 在 $Seconds 秒内未达到合同状态：$last"
            }
            Start-Sleep -Seconds 5
        }
    } while ($true)
}

function Convert-ToRegExePath([string]$Path) {
    $result = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $result = $result -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    return ($result -replace '^HKLM:', 'HKLM')
}

function Initialize-MonitorSetupApi {
    if ($null -ne ('VMate.G11.MonitorSetupApi' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace VMate.G11 {
    public static class MonitorSetupApi {
        private const uint DIGCF_ALLCLASSES = 0x00000004;
        private const uint DEVPROP_TYPE_STRING = 0x00000012;

        [StructLayout(LayoutKind.Sequential)]
        private struct SP_DEVINFO_DATA {
            public uint cbSize;
            public Guid ClassGuid;
            public uint DevInst;
            public UIntPtr Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DEVPROPKEY {
            public Guid fmtid;
            public uint pid;
        }

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern IntPtr SetupDiGetClassDevsW(
            IntPtr classGuid, string enumerator, IntPtr parent,
            uint flags);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern bool SetupDiOpenDeviceInfoW(
            IntPtr deviceInfoSet, string instanceId, IntPtr parent,
            uint flags, ref SP_DEVINFO_DATA deviceInfoData);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern bool SetupDiSetDevicePropertyW(
            IntPtr deviceInfoSet, ref SP_DEVINFO_DATA deviceInfoData,
            ref DEVPROPKEY propertyKey, uint propertyType,
            byte[] propertyBuffer, uint propertyBufferSize, uint flags);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiDestroyDeviceInfoList(
            IntPtr deviceInfoSet);

        public static void SetFriendlyName(
                string instanceId, string friendlyName) {
            IntPtr set = SetupDiGetClassDevsW(
                IntPtr.Zero, null, IntPtr.Zero, DIGCF_ALLCLASSES);
            if (set == new IntPtr(-1)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "SetupDiGetClassDevs failed");
            }
            try {
                SP_DEVINFO_DATA data = new SP_DEVINFO_DATA();
                data.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                if (!SetupDiOpenDeviceInfoW(
                        set, instanceId, IntPtr.Zero, 0, ref data)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "SetupDiOpenDeviceInfo failed for " + instanceId);
                }
                DEVPROPKEY key = new DEVPROPKEY();
                key.fmtid = new Guid(
                    "A45C254E-DF1C-4EFD-8020-67D146A850E0");
                key.pid = 14; // DEVPKEY_Device_FriendlyName
                byte[] value = Encoding.Unicode.GetBytes(friendlyName + "\0");
                if (!SetupDiSetDevicePropertyW(
                        set, ref data, ref key, DEVPROP_TYPE_STRING,
                        value, (uint)value.Length, 0)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "SetupDiSetDeviceProperty(FriendlyName) failed for " +
                        instanceId);
                }
            } finally {
                SetupDiDestroyDeviceInfoList(set);
            }
        }
    }
}
'@
}

function Set-MonitorPnpFriendlyName(
        [string]$InstanceId, [string]$FriendlyName) {
    Initialize-MonitorSetupApi
    [VMate.G11.MonitorSetupApi]::SetFriendlyName($InstanceId, $FriendlyName)
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $property = Get-PnpDeviceProperty -InstanceId $InstanceId `
            -KeyName 'DEVPKEY_Device_FriendlyName' -ErrorAction Stop
        if ([string]$property.Data -ceq $FriendlyName) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "SetupAPI FriendlyName 回读失败：$InstanceId"
}

function Set-ProtectedMonitorValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('String', 'Binary')][string]$Type,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
    $regPath = Convert-ToRegExePath $Path
    $regType = if ($Type -ceq 'String') { 'REG_SZ' } else { 'REG_BINARY' }
    $data = if ($Type -ceq 'String') {
        [string]$Value
    } else {
        -join @([byte[]]$Value | ForEach-Object { $_.ToString('X2') })
    }
    & $reg add $regPath /v $Name /t $regType /d $data /f 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "无法写入受保护的 monitor 值：$regPath\$Name"
    }
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    $kind = if ($Type -ceq 'String') {
        [Microsoft.Win32.RegistryValueKind]::String
    } else {
        [Microsoft.Win32.RegistryValueKind]::Binary
    }
    if ($key.GetValueKind($Name) -ne $kind) {
        throw "monitor 值类型回读失败：$regPath\$Name"
    }
    $actual = $key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($Type -ceq 'String') {
        if ([string]$actual -cne [string]$Value) {
            throw "monitor 字符串回读失败：$regPath\$Name"
        }
    } elseif (-not (Test-ByteArrayEqual ([byte[]]$actual) ([byte[]]$Value))) {
        throw "monitor 二进制回读失败：$regPath\$Name"
    }
}

function Set-MonitorEdidOverride([string]$ParametersPath, [byte[]]$Edid) {
    if ($Edid.Length -ne 256 -or [int]$Edid[126] -ne 1) {
        throw '只允许发布合同锁定的两块 EDID。'
    }
    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
    $overridePath = Join-Path $ParametersPath 'EDID_OVERRIDE'
    $regPath = Convert-ToRegExePath $overridePath
    if (Test-Path -LiteralPath $overridePath) {
        & $reg delete $regPath /f 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "无法重建 $regPath" }
    }
    for ($block = 0; $block -lt 2; $block++) {
        [byte[]]$bytes = $Edid[($block * 128)..($block * 128 + 127)]
        Set-ProtectedMonitorValue $overridePath ([string]$block) Binary $bytes
    }
    $key = Get-Item -LiteralPath $overridePath -ErrorAction Stop
    $names = @($key.GetValueNames() | Sort-Object)
    if ($names.Count -ne 2 -or $names[0] -cne '0' -or $names[1] -cne '1') {
        throw 'EDID_OVERRIDE 必须且只能包含 0/1 两个 block。'
    }
}

function Get-MonitorRegistryInstances(
        $Payload, [switch]$IncludeNonMatching) {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    $result = @()
    foreach ($device in @(Get-ChildItem -LiteralPath $base -ErrorAction Stop)) {
        foreach ($instance in @(Get-ChildItem -LiteralPath $device.PSPath `
                -ErrorAction Stop)) {
            $parameters = Join-Path $instance.PSPath 'Device Parameters'
            if (-not (Test-Path -LiteralPath $parameters)) { continue }
            $parameterKey = Get-Item -LiteralPath $parameters -ErrorAction Stop
            if (@($parameterKey.GetValueNames()) -cnotcontains 'EDID' -or
                $parameterKey.GetValueKind('EDID') -ne
                    [Microsoft.Win32.RegistryValueKind]::Binary) { continue }
            [byte[]]$edid = $parameterKey.GetValue('EDID')
            if (-not $IncludeNonMatching -and
                -not (Test-MonitorBaseIdentity $edid $Payload.Contract.monitor)) {
                continue
            }
            $result += [pscustomobject]@{
                InstanceId = 'DISPLAY\' + [string]$device.PSChildName + '\' +
                    [string]$instance.PSChildName
                InstancePath = [string]$instance.PSPath
                ParametersPath = [string]$parameters
            }
        }
    }
    return $result
}

function Get-PresentMonitorMap {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) -or
        -not (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) {
        throw '系统缺少 PnpDevice cmdlet，无法验证当前 monitor 实例。'
    }
    $result = @{}
    foreach ($device in @(Get-PnpDevice -Class Monitor -PresentOnly `
            -ErrorAction Stop)) {
        $result[[string]$device.InstanceId] = $device
    }
    return $result
}

function Publish-MonitorInstance($Instance, [byte[]]$Edid, $Monitor) {
    Set-ProtectedMonitorValue $Instance.ParametersPath 'EDID' Binary $Edid
    Set-MonitorEdidOverride $Instance.ParametersPath $Edid
    # DeviceDesc/Manufacturer/HardwareIds are OS/driver-owned properties.
    # Publish only the documented writable friendly-name property through
    # SetupAPI so the live PnP manager and Device Manager see the same value.
    Set-MonitorPnpFriendlyName $Instance.InstanceId `
        ([string]$Monitor.displayName)
}

function Assert-MonitorIdentity($Payload, [byte[]]$Edid) {
    $instances = @(Get-MonitorRegistryInstances $Payload)
    $present = Get-PresentMonitorMap
    $active = @($instances | Where-Object {
        $present.ContainsKey([string]$_.InstanceId)
    })
    if ($active.Count -ne 1) {
        throw "合同 monitor 当前匹配实例数量不是 1：$($active.Count)"
    }
    foreach ($instance in $instances) {
        $parameters = Get-Item -LiteralPath $instance.ParametersPath `
            -ErrorAction Stop
        [byte[]]$raw = $parameters.GetValue('EDID')
        if (-not (Test-ByteArrayEqual $raw $Edid)) {
            throw "monitor raw EDID 不匹配：$($instance.InstanceId)"
        }
        $override = Get-Item -LiteralPath (
            Join-Path $instance.ParametersPath 'EDID_OVERRIDE') -ErrorAction Stop
        $names = @($override.GetValueNames() | Sort-Object)
        if ($names.Count -ne 2 -or $names[0] -cne '0' -or $names[1] -cne '1') {
            throw "monitor EDID_OVERRIDE block 不完整：$($instance.InstanceId)"
        }
        for ($block = 0; $block -lt 2; $block++) {
            [byte[]]$expected = $Edid[($block * 128)..($block * 128 + 127)]
            [byte[]]$actual = $override.GetValue([string]$block)
            if (-not (Test-ByteArrayEqual $actual $expected)) {
                throw "monitor EDID_OVERRIDE\$block 不匹配：$($instance.InstanceId)"
            }
        }
    }
    $pnp = $present[[string]$active[0].InstanceId]
    if ([string]$pnp.FriendlyName -cne
        [string]$Payload.Contract.monitor.displayName) {
        throw "PnP monitor 名称仍不是合同值：$($pnp.FriendlyName)"
    }
    return [string]$active[0].InstanceId
}

function Sync-MonitorIdentity($Payload, [int]$WaitSeconds = 0) {
    [byte[]]$edid = Assert-MonitorEdidFile (
        Join-Path $Payload.Root 'monitor-edid.bin') $Payload.Contract.monitor
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $last = ''
    do {
        try {
            $instances = @(Get-MonitorRegistryInstances $Payload)
            $present = Get-PresentMonitorMap
            $active = @($instances | Where-Object {
                $present.ContainsKey([string]$_.InstanceId)
            })
            if ($active.Count -eq 0) {
                # A generalized clone initially enumerates the native NVIDIA
                # monitor PDO with the template/generic EDID.  Bootstrap only
                # the unambiguous one-head NVDxxxx instance; never guess among
                # multiple displays or touch a remote/foreign monitor.
                $presentIds = @($present.Keys)
                if ($presentIds.Count -ne 1 -or
                    [string]$presentIds[0] -notmatch
                        '\ADISPLAY\\NVD[0-9A-F]{4}\\') {
                    throw '唯一的 native NVIDIA monitor 实例尚未稳定。'
                }
                $allRegistry = @(Get-MonitorRegistryInstances $Payload `
                    -IncludeNonMatching)
                $bootstrap = @($allRegistry | Where-Object {
                    [string]$_.InstanceId -ieq [string]$presentIds[0]
                })
                if ($bootstrap.Count -ne 1) {
                    throw '当前 NVIDIA monitor 没有唯一的 EDID 注册表实例。'
                }
                Publish-MonitorInstance $bootstrap[0] $edid `
                    $Payload.Contract.monitor
                $instances = @(Get-MonitorRegistryInstances $Payload)
                $present = Get-PresentMonitorMap
                $active = @($instances | Where-Object {
                    $present.ContainsKey([string]$_.InstanceId)
                })
            }
            if ($active.Count -ne 1) {
                throw '匹配 EDID 的当前 monitor 实例尚未稳定。'
            }
            foreach ($instance in $instances) {
                Publish-MonitorInstance $instance $edid $Payload.Contract.monitor
            }
            $activeId = Assert-MonitorIdentity $Payload $edid
            Write-Host ("MONITOR_IDENTITY_VERIFY PASS instance={0} name={1}" -f
                $activeId, [string]$Payload.Contract.monitor.displayName) `
                -ForegroundColor Green
            return $activeId
        } catch {
            $last = $_.Exception.Message
            if ((Get-Date) -ge $deadline) { throw $last }
            Start-Sleep -Seconds 5
        }
    } while ($true)
}

function Get-SystemEntries($Contract) {
    $windows = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Windows)
    $system64 = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::System)
    $system32 = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::SystemX86)
    if ([string]::IsNullOrWhiteSpace($windows) -or
        [IO.Path]::GetFullPath($system64).TrimEnd('\') -ine
            [IO.Path]::GetFullPath((Join-Path $windows 'System32')).TrimEnd('\') -or
        [IO.Path]::GetFullPath($system32).TrimEnd('\') -ine
            [IO.Path]::GetFullPath((Join-Path $windows 'SysWOW64')).TrimEnd('\')) {
        throw 'Windows Known Folder 系统目录异常。'
    }
    return @(
        [pscustomobject]@{
            Label='x86'; Machine=0x014C; Target=(Join-Path $system32 'nvapi.dll')
            Backup=(Join-Path $system32 'nvapi_orig.dll')
            Expected=[string]$Contract.payload.shimX86Sha256
        },
        [pscustomobject]@{
            Label='x64'; Machine=0x8664; Target=(Join-Path $system64 'nvapi64.dll')
            Backup=(Join-Path $system64 'nvapi64_orig.dll')
            Expected=[string]$Contract.payload.shimX64Sha256
        }
    )
}

function Assert-SystemProjection($Payload) {
    foreach ($entry in @(Get-SystemEntries $Payload.Contract)) {
        $target = Get-RegularFile $entry.Target "system NVAPI $($entry.Label)"
        if ((Get-PeMachine $target.FullName) -ne [int]$entry.Machine -or
            (Get-Sha256 $target.FullName) -cne [string]$entry.Expected) {
            throw "system NVAPI $($entry.Label) 不是合同锁定的投影。"
        }
        Assert-OriginalNvidiaImage $entry.Backup ([int]$entry.Machine)
    }
}

function Assert-SystemOriginalsRestored($Payload) {
    foreach ($entry in @(Get-SystemEntries $Payload.Contract)) {
        Assert-OriginalNvidiaImage $entry.Target ([int]$entry.Machine)
        if (Test-Path -LiteralPath $entry.Backup) {
            throw "回滚后仍残留原始备份路径：$($entry.Backup)"
        }
    }
}

function Get-RegistryValue($Key, [string]$Name, $Kind) {
    if (-not (@($Key.GetValueNames()) -ccontains $Name) -or
        $Key.GetValueKind($Name) -ne $Kind) {
        throw "NVAPI 注册表值缺失或类型错误：$Name"
    }
    return $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Assert-RegistryContract($Contract) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $key = $null
    try {
        $key = $base.OpenSubKey('SOFTWARE\NVIDIA Corporation\Global\NvAPI', $false)
        if ($null -eq $key) { throw 'NVAPI 身份注册表合同不存在。' }
        $profile = $Contract.profile
        $catalog = [string]$Contract.identityCatalogSha256
        $strings = [ordered]@{
            IdentityProfileKey = [string]$profile.key
            IdentityCatalogSha256 = $catalog
            IdentityGpuName = [string]$profile.name
            IdentityVbiosVersion = [string]$profile.vbiosVersion
            IdentityBoardBrand = [string]$profile.boardBrand
            IdentityBoardModel = [string]$profile.boardModel
            IdentityMemoryTypeName = [string]$profile.memoryTypeName
            IdentityMemoryMakerName = [string]$profile.memoryMakerName
            IdentityMemoryMakerNvapiName = [string]$profile.memoryMakerNvapiName
            IdentityProjectionScope = [string]$profile.identityScope
            IdentityPciProjectionMode =
                [string]$Contract.transport.pciProjectionMode
        }
        $dwords = [ordered]@{
            IdentityContractVersion = 2
            IdentityVramMB = [int]$profile.vramMB
            IdentityPciVendorId = [int]$profile.pciVendorId
            IdentityPciDeviceId = [int]$profile.pciDeviceId
            IdentityPciSubVendorId = [int]$profile.pciSubVendorId
            IdentityPciSubDeviceId = [int]$profile.pciSubDeviceId
            IdentityPciRevisionId = [int]$profile.pciRevisionId
            IdentityCoreClockKHz = [int]$profile.coreClockMHz * 1000
            IdentityBoostClockKHz = [int]$profile.boostClockMHz * 1000
            IdentityMemoryClockNVAPIKHz = [int]$profile.memoryClockMHz * 2000
            IdentityMemoryClockKHz = [int]$profile.memoryClockMHz * 2000
            IdentityMemoryBusBits = [int]$profile.memoryBusBits
            IdentityMemoryBandwidthMBps = [int]$profile.memoryBandwidthMBps
            IdentityMemoryType = [int]$profile.memoryType
            IdentityMemoryMaker = [int]$profile.memoryMaker
            IdentityCudaCores = [int]$profile.cudaCores
            IdentityShaderSubPipes = [int]$profile.shaderSubPipes
            IdentityRopCount = [int]$profile.ropCount
            IdentityTmuCount = [int]$profile.tmuCount
            IdentityRayTracingCores = [int]$profile.rayTracingCores
            IdentityTensorCores = [int]$profile.tensorCores
            IdentityArchitecture = [int]$profile.architecture
            IdentityImplementation = [int]$profile.implementation
            IdentityChipRevision = [int]$profile.chipRevision
            IdentityPcieWidth = [int]$profile.pcieWidth
        }
        foreach ($item in $strings.GetEnumerator()) {
            $actual = Get-RegistryValue $key $item.Key `
                ([Microsoft.Win32.RegistryValueKind]::String)
            if ([string]$actual -cne [string]$item.Value) {
                throw "NVAPI 注册表合同不匹配：$($item.Key)"
            }
        }
        foreach ($item in $dwords.GetEnumerator()) {
            $actual = Get-RegistryValue $key $item.Key `
                ([Microsoft.Win32.RegistryValueKind]::DWord)
            if ([int64]$actual -ne [int64]$item.Value) {
                throw "NVAPI 注册表合同不匹配：$($item.Key)"
            }
        }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $base.Dispose()
    }
}

function Wait-RegistryContract($Contract, [int]$TimeoutSeconds = 120) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = ''
    do {
        try {
            Assert-RegistryContract $Contract
            return
        } catch {
            $last = $_.Exception.Message
            if ((Get-Date) -ge $deadline) { throw $last }
            Start-Sleep -Seconds 5
        }
    } while ($true)
}

function Invoke-SystemProbes($Payload) {
    $profile = $Payload.Contract.profile
    $transport = $Payload.Contract.transport
    $expectedDevice = ([uint64][int]$transport.pciDeviceId -shl 16) -bor
        [uint64][int]$transport.pciVendorId
    $expectedSubsystem = ([uint64][int]$profile.pciSubDeviceId -shl 16) -bor
        [uint64][int]$profile.pciSubVendorId
    foreach ($name in @('SystemNvapiProbe32.exe', 'SystemNvapiProbe64.exe')) {
        $probe = Join-Path $Payload.Root $name
        $output = (& $probe ([int]$profile.memoryMaker) `
            ([int]$profile.memoryType) ([int]$profile.memoryBusBits) `
            $expectedDevice.ToString() $expectedSubsystem.ToString() `
            ([int]$profile.rayTracingCores) `
            ([int]$profile.tensorCores) 2>&1 |
            Out-String)
        if ($LASTEXITCODE -ne 0 -or
            $output -notmatch 'SYSTEM_NVAPI_VERIFY PASS') {
            throw "$name 系统搜索路径运行时验证失败：$output"
        }
        Write-Host ($output.Trim()) -ForegroundColor Green
    }
}

function Invoke-NativeD3D12Probes($Payload) {
    $profile = $Payload.Contract.profile
    if ([int]$profile.d3d12RaytracingTier -ne 0) {
        throw 'native D3D12 audit currently accepts only the reviewed tier-zero catalog.'
    }
    $capabilityMismatch = @()
    foreach ($name in @(
            'D3D12CapabilityProbe32.exe',
            'D3D12CapabilityProbe64.exe'
        )) {
        $probe = Join-Path $Payload.Root $name
        # The signed GRID userspace driver owns native D3D12 capability
        # reporting.  The system NVAPI projection cannot truthfully change
        # ID3D12Device::CheckFeatureSupport, so clone readiness only requires
        # both native architectures to enumerate/query the NVIDIA adapter.
        # Keep --require-tier-zero in the standalone diagnostic probe for
        # operators who want a strict transport-coherence audit.
        $output = (& $probe 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or
            $output -notmatch 'D3D12_NATIVE_VERIFY PASS') {
            throw ("$name 无法查询签名显卡驱动的原生 D3D12 OPTIONS5；" +
                "已拒绝继续安装/验收：`r`n$output")
        }
        if ($output -match 'native_raytracing_nonzero=yes') {
            $capabilityMismatch += $name
        }
        Write-Host ($output.Trim()) -ForegroundColor Green
    }
    if ($capabilityMismatch.Count -gt 0) {
        Write-Warning ("目标旧卡的 NVAPI 能力合同为 DXR tier 0，但签名 vGPU " +
            "transport 的原生 D3D12 暴露了光追能力（{0}）。本工具不会替换 " +
            "d3d12.dll 或伪造 ID3D12Device；该差异已记录，但不阻断 NVAPI " +
            "投影与克隆初始化。" -f ($capabilityMismatch -join ', '))
    }
}

function Invoke-ProfileWriter($Payload) {
    $contract = $Payload.Contract
    $profile = $contract.profile
    $arguments = @{
        CatalogPath = Join-Path $Payload.Root 'vgpu-profile-catalog.json'
        CatalogSha256 = [string]$contract.identityCatalogSha256
        ProfileKey = [string]$profile.key
        TargetName = [string]$profile.name
        NvapiPciVendorId = [int]$profile.pciVendorId
        NvapiPciDeviceId = [int]$profile.pciDeviceId
        NvapiPciSubVendorId = [int]$profile.pciSubVendorId
        NvapiPciSubDeviceId = [int]$profile.pciSubDeviceId
        NvapiPciRevisionId = [int]$profile.pciRevisionId
        PciProjectionMode = [string]$contract.transport.pciProjectionMode
        CoreClockMHz = [int]$profile.coreClockMHz
        BoostClockMHz = [int]$profile.boostClockMHz
        MemoryClockMHz = [int]$profile.memoryClockMHz
        MemoryBusBits = [int]$profile.memoryBusBits
        MemoryBandwidthMBps = [int]$profile.memoryBandwidthMBps
        VramMB = [int]$profile.vramMB
        MemoryType = [int]$profile.memoryType
        MemoryMaker = [int]$profile.memoryMaker
        CudaCores = [int]$profile.cudaCores
        ShaderSubPipes = [int]$profile.shaderSubPipes
        RopCount = [int]$profile.ropCount
        TmuCount = [int]$profile.tmuCount
        Architecture = [int]$profile.architecture
        Implementation = [int]$profile.implementation
        ChipRevision = [int]$profile.chipRevision
        PcieWidth = [int]$profile.pcieWidth
        VbiosVersion = [string]$profile.vbiosVersion
    }
    & (Join-Path $Payload.Root 'patch-grid-strings.ps1') @arguments
}

function Invoke-LowLevelInstaller($Payload, [switch]$Remove) {
    $trustedPrior = Get-TrustedPriorShimHashes $Payload
    $parameters = @{
        X64Path = Join-Path $Payload.Root 'nvapi64.dll'
        X86Path = Join-Path $Payload.Root 'nvapi.dll'
        ExpectedX64Sha256 = [string]$Payload.Contract.payload.shimX64Sha256
        ExpectedX86Sha256 = [string]$Payload.Contract.payload.shimX86Sha256
        TrustedPriorX64Sha256 = @($trustedPrior.X64)
        TrustedPriorX86Sha256 = @($trustedPrior.X86)
    }
    if ($Remove) { $parameters.Uninstall = $true }
    & (Join-Path $Payload.Root 'install-nvapi-shim.ps1') @parameters
}

function Get-TaskName($Contract) {
    return $TaskPrefix + ([string]$Contract.contractId).Substring(0, 16)
}

function Get-MonitorTaskName($Contract) {
    return $MonitorTaskPrefix + ([string]$Contract.contractId).Substring(0, 16)
}

function Remove-StaleProjectionTasks($Contract) {
    $keepVerify = Get-TaskName $Contract
    $keepMonitor = Get-MonitorTaskName $Contract
    foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.TaskName.StartsWith($TaskPrefix,
                    [StringComparison]::Ordinal) -or
                 $_.TaskName.StartsWith($MonitorTaskPrefix,
                    [StringComparison]::Ordinal)) -and
                $_.TaskName -cne $keepVerify -and
                $_.TaskName -cne $keepMonitor
            })) {
        Unregister-ScheduledTask -TaskName $task.TaskName `
            -TaskPath $task.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Register-VerificationTask($Payload, [string]$NextAction) {
    $taskName = Get-TaskName $Payload.Contract
    $script = Join-Path $Payload.Root 'install-system-nvapi-projection.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1} -PayloadDir "{2}"' `
        -f $script, $NextAction, $Payload.Root
    $taskAction = New-ScheduledTaskAction -Execute (
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    ) -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    # The persistent identity task runs after legacy/base-image refresh tasks
    # and republishes the complete current contract.  Verify after that
    # convergence point instead of racing an older RefreshGridNames action.
    $trigger.Delay = 'PT45S'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5))
    Register-ScheduledTask -TaskName $taskName -Action $taskAction `
        -Trigger $trigger -Principal $principal -Settings $settings -Force |
        Out-Null
}

function Unregister-VerificationTask($Contract) {
    Unregister-ScheduledTask -TaskName (Get-TaskName $Contract) `
        -Confirm:$false -ErrorAction SilentlyContinue
}

function Register-MonitorIdentityTask($Payload) {
    $taskName = Get-MonitorTaskName $Payload.Contract
    $script = Join-Path $Payload.Root 'install-system-nvapi-projection.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Action RefreshIdentity -PayloadDir "{1}"' `
        -f $script, $Payload.Root
    $taskAction = New-ScheduledTaskAction -Execute (
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    ) -Argument $arguments
    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT30S'
    $logon = New-ScheduledTaskTrigger -AtLogOn
    $logon.Delay = 'PT10S'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes(6))
    Register-ScheduledTask -TaskName $taskName -Action $taskAction `
        -Trigger @($startup, $logon) -Principal $principal -Settings $settings `
        -Force | Out-Null
}

function Unregister-MonitorIdentityTask($Contract) {
    Unregister-ScheduledTask -TaskName (Get-MonitorTaskName $Contract) `
        -Confirm:$false -ErrorAction SilentlyContinue
}

function Assert-MonitorIdentityTask($Payload) {
    $task = Get-ScheduledTask -TaskName (Get-MonitorTaskName $Payload.Contract) `
        -ErrorAction Stop
    if ([string]$task.Principal.UserId -cne 'SYSTEM' -or
        [string]$task.Principal.RunLevel -cne 'Highest' -or
        @($task.Triggers).Count -ne 2 -or @($task.Actions).Count -ne 1 -or
        [string]$task.Actions[0].Arguments -notmatch
            '(?i)-Action\s+RefreshIdentity\b') {
        throw '持久 GPU/monitor identity 任务与合同不一致。'
    }
}

function Write-Receipt(
    $Payload,
    [string]$State,
    $Transport,
    [string]$BcdSha,
    [string]$MonitorInstance = ''
) {
    New-ProtectedDirectory $ReceiptRoot
    $receipt = [ordered]@{
        schemaVersion = 2
        purpose = 'g11-system-nvapi-projection'
        state = $State
        contractId = [string]$Payload.Contract.contractId
        vmId = [int]$Payload.Contract.vmId
        vmUuid = [string]$Payload.Contract.vmUuid
        gpuProfile = [string]$Payload.Contract.profile.key
        gpuName = [string]$Payload.Contract.profile.name
        boardBrand = [string]$Payload.Contract.profile.boardBrand
        memoryType = [string]$Payload.Contract.profile.memoryTypeName
        memoryMaker = [string]$Payload.Contract.profile.memoryMakerName
        memoryMakerNvapi = [int]$Payload.Contract.profile.memoryMaker
        monitorProfile = [string]$Payload.Contract.monitor.key
        monitorName = [string]$Payload.Contract.monitor.displayName
        monitorPnpId = [string]$Payload.Contract.monitor.pnpId
        monitorInstanceId = $MonitorInstance
        displayInstanceId = if ($null -ne $Transport) {
            [string]$Transport.Display.InstanceId
        } else { '' }
        driverVersion = if ($null -ne $Transport) {
            [string]$Transport.Controller.DriverVersion
        } else { '' }
        driverSigned = if ($null -ne $Transport) {
            [bool]$Transport.SignedDriver.IsSigned
        } else { $false }
        shimX86Sha256 = [string]$Payload.Contract.payload.shimX86Sha256
        shimX64Sha256 = [string]$Payload.Contract.payload.shimX64Sha256
        testsigning = $false
        nointegritychecks = $false
        bcdSha256 = $BcdSha
        completedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $json = $receipt | ConvertTo-Json -Depth 6
    $final = Join-Path $ReceiptRoot (
        ([string]$Payload.Contract.contractId) + '-' + $State + '.json')
    $temp = "$final.$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, $json + "`r`n",
        (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $final -Force
    Write-Host "收据：$final" -ForegroundColor Green
}

function Restart-IfRequested {
    if ($Reboot) {
        Write-Host '5 秒后重启以切换系统 NVAPI 映像。' -ForegroundColor Yellow
        & (Join-Path $env:SystemRoot 'System32\shutdown.exe') /r /t 5 /f
        if ($LASTEXITCODE -ne 0) { throw '无法安排 Windows 重启。' }
    } else {
        Write-Host '请完整重启 Windows；下次启动会自动验证并写入 validated 收据。' `
            -ForegroundColor Yellow
    }
}

Assert-Administrator
$payload = Read-Payload $PayloadDir
$entryBcd = Get-NormalBcdSnapshot
$transport = if ($Action -in @(
        'Verify', 'VerifyUninstall', 'RefreshMonitor', 'RefreshIdentity'
    )) {
    Wait-GuestTransport $payload.Contract
} else {
    Get-GuestTransport $payload.Contract
}

switch ($Action) {
    'Install' {
        Write-Step "安装32/64位程序共用的单显卡系统投影：$($payload.Contract.profile.key)"
        Write-Step '写入前审计签名显卡驱动的原生 x86/x64 D3D12 OPTIONS5'
        Invoke-NativeD3D12Probes $payload
        Prepare-V11CloneComputerName $payload
        $durableRoot = Copy-PayloadDurably $payload
        $payload = Read-Payload $durableRoot
        # The exact VM-bound package is now durable.  Eject every matching
        # read-only ISO so the host watcher can hot-remove the complete
        # temporary optical stack before the verification reboot.
        $null = Eject-MatchingPayloadMedia $payload.Contract
        Remove-StaleProjectionTasks $payload.Contract
        Invoke-ProfileWriter $payload
        Assert-RegistryContract $payload.Contract
        Invoke-LowLevelInstaller $payload
        $monitorInstance = Sync-MonitorIdentity $payload 30
        Register-MonitorIdentityTask $payload
        Assert-MonitorIdentityTask $payload
        Register-VerificationTask $payload 'Verify'
        $exitBcd = Get-NormalBcdSnapshot
        if ($exitBcd -cne $entryBcd) {
            throw '安装期间 BCD 发生变化；本工具没有授权此操作。'
        }
        Write-Receipt $payload 'pending-reboot' $transport $exitBcd `
            $monitorInstance
        Restart-IfRequested
    }
    'Verify' {
        Write-Step '验证单逻辑显卡的32/64位系统搜索路径与显存厂家结果'
        Assert-V11CloneComputerName $payload.Contract
        Assert-SystemProjection $payload
        Wait-RegistryContract $payload.Contract 120
        Invoke-SystemProbes $payload
        Invoke-NativeD3D12Probes $payload
        $monitorInstance = Sync-MonitorIdentity $payload 300
        Assert-MonitorIdentityTask $payload
        $exitBcd = Get-NormalBcdSnapshot
        if ($exitBcd -cne $entryBcd) { throw '验证期间 BCD 发生变化。' }
        Write-Receipt $payload 'validated' $transport $exitBcd $monitorInstance
        Unregister-VerificationTask $payload.Contract
        Write-Host ("PASS：x86/x64 系统 NVAPI 符合目标能力合同，原生 D3D12 路径已如实审计；{0} / {1}；monitor={2}。" -f
            $payload.Contract.profile.memoryTypeName,
            $payload.Contract.profile.memoryMakerName,
            $payload.Contract.monitor.displayName) -ForegroundColor Green
    }
    'Uninstall' {
        Write-Step '回滚系统 NVAPI 投影并恢复生产签名 NVIDIA 原件'
        Unregister-MonitorIdentityTask $payload.Contract
        Invoke-LowLevelInstaller $payload -Remove
        Register-VerificationTask $payload 'VerifyUninstall'
        $exitBcd = Get-NormalBcdSnapshot
        if ($exitBcd -cne $entryBcd) { throw '回滚期间 BCD 发生变化。' }
        Write-Receipt $payload 'rollback-pending-reboot' $transport $exitBcd
        Restart-IfRequested
    }
    'VerifyUninstall' {
        Write-Step '验证系统 NVAPI 原件恢复'
        Assert-SystemOriginalsRestored $payload
        if (Get-ScheduledTask -TaskName (Get-MonitorTaskName $payload.Contract) `
                -ErrorAction SilentlyContinue) {
            throw '回滚后 monitor identity 任务仍存在。'
        }
        $exitBcd = Get-NormalBcdSnapshot
        if ($exitBcd -cne $entryBcd) { throw '回滚验证期间 BCD 发生变化。' }
        Write-Receipt $payload 'rolled-back' $transport $exitBcd
        Unregister-VerificationTask $payload.Contract
        Write-Host 'PASS：x86/x64 系统 NVAPI 已恢复为生产签名 NVIDIA 原件。' `
            -ForegroundColor Green
    }
    'RefreshMonitor' {
        Write-Step '按合同 EDID 收敛新枚举的 monitor 实例'
        $null = Sync-MonitorIdentity $payload 300
        $exitBcd = Get-NormalBcdSnapshot
        if ($exitBcd -cne $entryBcd) {
            throw 'monitor identity 刷新期间 BCD 发生变化。'
        }
    }
    'RefreshIdentity' {
        Write-Step '在设备枚举后重新发布完整 GPU/monitor 身份合同'
        Invoke-ProfileWriter $payload
        Assert-RegistryContract $payload.Contract
        $null = Sync-MonitorIdentity $payload 300
        $exitBcd = Get-NormalBcdSnapshot
        if ($exitBcd -cne $entryBcd) {
            throw 'GPU/monitor identity 刷新期间 BCD 发生变化。'
        }
    }
}
