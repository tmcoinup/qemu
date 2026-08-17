# patch-grid-strings.ps1 — 把 guest 注册表里的 "GRID RTX6000-*" 替换为审计目录中的消费级型号名
# 用法:
#   .\patch-grid-strings.ps1 -TargetName "NVIDIA GeForce GTX 1050"
# ProfileKey 可省略；兼容调用会从 schema-2 catalog 的完整 PCI subsystem
# tuple 精确推导。板卡品牌、显存厂商和所有数值字段必须来自同一原子行。
param(
    [string]$CatalogPath = '',
    [string]$CatalogSha256 = '',
    [string]$TargetName = 'NVIDIA GeForce GTX 1050',
    [string]$Vendor = '',
    [string]$ProfileKey = '',
    [ValidateRange(1,65535)][int]$NvapiPciVendorId = 0x10DE,
    [ValidateRange(1,65535)][int]$NvapiPciDeviceId = 0x1C81,
    [ValidateRange(1,65535)][int]$NvapiPciSubVendorId = 0x1028,
    [ValidateRange(1,65535)][int]$NvapiPciSubDeviceId = 0x11C0,
    [ValidateRange(0,255)][int]$NvapiPciRevisionId = 0xA1,
    [ValidateSet('profile-tuple','transport-device-profile-subsystem')]
    [string]$PciProjectionMode = 'profile-tuple',
    [ValidateRange(1,10000)][int]$CoreClockMHz = 1354,
    [ValidateRange(1,10000)][int]$BoostClockMHz = 1455,
    [ValidateRange(1,10000)][int]$MemoryClockMHz = 1752,
    [ValidateRange(1,1024)][int]$MemoryBusBits = 128,
    [ValidateRange(1,1000000)][int]$MemoryBandwidthMBps = 112000,
    [ValidateSet(2048)][int]$VramMB = 2048,
    [ValidateSet(8)][int]$MemoryType = 8,
    [ValidateRange(1,255)][int]$MemoryMaker = 1,
    [ValidateRange(1,1000000)][int]$CudaCores = 640,
    [ValidateRange(1,65535)][int]$ShaderSubPipes = 5,
    [ValidateRange(1,65535)][int]$RopCount = 32,
    [ValidateRange(1,1000000)][int]$TmuCount = 40,
    [ValidateRange(1,65535)][int]$Architecture = 0x130,
    [ValidateRange(1,65535)][int]$Implementation = 7,
    [ValidateRange(0,65535)][int]$ChipRevision = 0x11,
    [ValidateRange(1,32)][int]$PcieWidth = 16,
    [string]$VbiosVersion = '86.07.39.40.F4',
    # Windows 看到的 PCI Device ID 取决于启动模式：
    #   SPOOF_MODE=off/B → DEV_1E30 (GRID/RTX6000)
    #   SPOOF_MODE=A + gtx750ti_2gb → DEV_1380
    #   SPOOF_MODE=A + gtx1050_2gb → DEV_1C81
    #   SPOOF_MODE=A + gt1030_2gb  → DEV_1D01
    [string[]]$DeviceIdMatch = @(
        'VEN_10DE&DEV_1E30',
        'VEN_10DE&DEV_1380',
        'VEN_10DE&DEV_1C81',
        'VEN_10DE&DEV_1D01'
    )
)

$ErrorActionPreference = 'Stop'
$CatalogPath = if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
    Join-Path $PSScriptRoot 'vgpu-profile-catalog.json'
} else {
    [IO.Path]::GetFullPath($CatalogPath)
}
$out = "C:\Windows\Temp\patch-grid-strings.out"
"" | Out-File $out
function W($s){ $s | Out-File -Append $out; Write-Host $s }

# Compose final target. Vendor 可留空：默认就 "GeForce GTX 1050" 这种参考名。
if ([string]::IsNullOrWhiteSpace($Vendor)) {
    $to = $TargetName
} else {
    $to = "$Vendor $TargetName"
}
$to = $to.Trim()
if ($to -notmatch '\A[\x20-\x7E]{1,31}\z') {
    throw 'Final GPU name must contain 1-31 printable ASCII characters.'
}
if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
    throw "The schema-2 vGPU identity catalog is missing: $CatalogPath"
}
try {
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw |
        ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "The schema-2 vGPU identity catalog is invalid JSON: $($_.Exception.Message)"
}
if ([int]$catalog.schemaVersion -ne 2 -or
    [string]$catalog.identityMode -cne 'protected-user-mode' -or
    [string]$catalog.transportPnpId -cne 'PCI\VEN_10DE&DEV_1E30' -or
    [string]$catalog.catalogSha256 -cnotmatch '^[0-9A-F]{64}$') {
    throw 'The vGPU identity catalog header is not the supported schema-2 contract.'
}
if ([string]::IsNullOrWhiteSpace($CatalogSha256)) {
    $CatalogSha256 = [string]$catalog.catalogSha256
} elseif ($CatalogSha256 -cne [string]$catalog.catalogSha256) {
    throw 'The requested catalog hash does not match the protected catalog asset.'
}
$candidates = @($catalog.profiles | Where-Object {
    [int64]$_.nvapiPciVendorId -eq $NvapiPciVendorId -and
    [int64]$_.nvapiPciDeviceId -eq $NvapiPciDeviceId -and
    [int64]$_.nvapiPciSubVendorId -eq $NvapiPciSubVendorId -and
    [int64]$_.nvapiPciSubDeviceId -eq $NvapiPciSubDeviceId -and
    [int64]$_.nvapiPciRevisionId -eq $NvapiPciRevisionId -and
    ([string]::IsNullOrWhiteSpace($ProfileKey) -or
        [string]$_.profile -ceq $ProfileKey)
})
if ($candidates.Count -ne 1) {
    throw 'The full NVAPI PCI subsystem tuple does not select exactly one schema-2 profile.'
}
$selectedCatalogIdentity = $candidates[0]
if ([string]::IsNullOrWhiteSpace($ProfileKey)) {
    $ProfileKey = [string]$selectedCatalogIdentity.profile
}
$expectedFields = [ordered]@{
    profile = $ProfileKey
    name = $to
    nvapiPciVendorId = $NvapiPciVendorId
    nvapiPciDeviceId = $NvapiPciDeviceId
    nvapiPciSubVendorId = $NvapiPciSubVendorId
    nvapiPciSubDeviceId = $NvapiPciSubDeviceId
    nvapiPciRevisionId = $NvapiPciRevisionId
    coreClockMHz = $CoreClockMHz
    boostClockMHz = $BoostClockMHz
    memoryClockMHz = $MemoryClockMHz
    memoryBusBits = $MemoryBusBits
    memoryBandwidthMBps = $MemoryBandwidthMBps
    vramMB = $VramMB
    memoryType = $MemoryType
    memoryMaker = $MemoryMaker
    cudaCores = $CudaCores
    shaderSubPipes = $ShaderSubPipes
    ropCount = $RopCount
    tmuCount = $TmuCount
    architecture = $Architecture
    implementation = $Implementation
    chipRevision = $ChipRevision
    pcieWidth = $PcieWidth
}
foreach ($item in $expectedFields.GetEnumerator()) {
    $actual = $selectedCatalogIdentity.($item.Key)
    if ($item.Value -is [string]) {
        if ([string]$actual -cne [string]$item.Value) {
            throw "Profile field '$($item.Key)' does not match schema-2 catalog."
        }
    } elseif ([int64]$actual -ne [int64]$item.Value) {
        throw "Profile field '$($item.Key)' does not match schema-2 catalog."
    }
}
$catalogVbios = [string]$selectedCatalogIdentity.vbiosVersion
$requestedVbios = $VbiosVersion.Trim()
if ($requestedVbios.StartsWith('Version ', [StringComparison]::OrdinalIgnoreCase)) {
    $requestedVbios = $requestedVbios.Substring(8).Trim()
}
if ($requestedVbios -cne $catalogVbios) {
    throw 'VBIOS version does not match the schema-2 catalog row.'
}
$BoardBrand = [string]$selectedCatalogIdentity.boardBrand
$BoardModel = [string]$selectedCatalogIdentity.boardModel
$MemoryTypeName = [string]$selectedCatalogIdentity.memoryTypeName
$MemoryMakerName = [string]$selectedCatalogIdentity.memoryMakerName
$MemoryMakerNvapiName = [string]$selectedCatalogIdentity.memoryMakerNvapiName
$IdentityScope = [string]$selectedCatalogIdentity.identityScope
# 要替换掉的 GRID 原始名（覆盖 1Q/2Q/3Q/4Q/8Q 几个常见 profile）。
# 优先长串 ("NVIDIA GRID RTX6000-2Q") 先于短串 ("GRID RTX6000") 匹配，
# 否则命中短的会在 to 前留一个多余的 "NVIDIA " (→ "NVIDIA NVIDIA GeForce...")。
$from = 'NVIDIA GRID RTX6000-1Q','NVIDIA GRID RTX6000-2Q','NVIDIA GRID RTX6000-3Q','NVIDIA GRID RTX6000-4Q','NVIDIA GRID RTX6000-8Q','NVIDIA GRID RTX6000',
        'GRID RTX6000-1Q','GRID RTX6000-2Q','GRID RTX6000-3Q','GRID RTX6000-4Q','GRID RTX6000-8Q','GRID RTX6000'

W "==== Config ===="
W ("  ProfileKey = $ProfileKey")
W ("  Catalog    = schema 2 / $CatalogSha256")
W ("  TargetName = $TargetName")
W ("  Vendor     = $Vendor")
W ("  Final 'to' = $to")
W ("  DeviceIds  = $($DeviceIdMatch -join ', ')")
W ("  NVAPI PCI   = $($NvapiPciVendorId.ToString('X4')):$($NvapiPciDeviceId.ToString('X4')) / $($NvapiPciSubVendorId.ToString('X4')):$($NvapiPciSubDeviceId.ToString('X4')) rev $($NvapiPciRevisionId.ToString('X2'))")
W ("  PCI policy  = $PciProjectionMode")
W ("  VRAM       = $VramMB MB")
W ("  Clocks     = core $CoreClockMHz / boost $BoostClockMHz / memory $MemoryClockMHz MHz")
W ("  Memory     = type $MemoryType / maker $MemoryMaker / bus ${MemoryBusBits}-bit")
W ("  Board      = $BoardBrand $BoardModel")
W ("  VRAM maker = $MemoryMakerName (NVAPI $MemoryMakerNvapiName=$MemoryMaker)")
W ("  Scope      = $IdentityScope")
W ("  Cores      = CUDA $CudaCores / subpipes $ShaderSubPipes / ROPs $RopCount / TMUs $TmuCount")
W ("  GPU IDs    = arch 0x$($Architecture.ToString('X')) / impl $Implementation / chip rev 0x$($ChipRevision.ToString('X')) / PCIe x$PcieWidth")

$VbiosVersion = $VbiosVersion.Trim()
if ($VbiosVersion.StartsWith('Version ', [StringComparison]::OrdinalIgnoreCase)) {
    $VbiosVersion = $VbiosVersion.Substring(8).Trim()
}
if ($VbiosVersion -notmatch '\A[0-9A-Fa-f]{2}(\.[0-9A-Fa-f]{2}){4}\z') {
    throw 'VBIOS version must contain exactly five dot-separated hexadecimal bytes.'
}
W ("  VBIOS      = $VbiosVersion")

# Every currently published model uses the same verified GDDR5 clock
# representation.  Keep direct invocations fail-closed as well as staged
# profiles: a different RAM enum must gain its own audited raw-clock contract
# before this writer accepts it.
$memoryRawClockKHz = [int64]$MemoryClockMHz * 2000
$derivedBandwidthMBps = [int64]$memoryRawClockKHz * 2 *
    $MemoryBusBits / 8000
$bandwidthDifference = [Math]::Abs(
    $derivedBandwidthMBps - [int64]$MemoryBandwidthMBps
)
if ($bandwidthDifference * 100 -gt [int64]$MemoryBandwidthMBps) {
    throw "Memory clock/bus/bandwidth mismatch: profile $MemoryBandwidthMBps MB/s, derived $derivedBandwidthMBps MB/s (GDDR5 tolerance is 1%)."
}
if ($TmuCount -ne $ShaderSubPipes * 8) {
    throw 'TmuCount must equal ShaderSubPipes * 8 for the audited profiles.'
}

# The forwarding NVAPI shim reads this per-guest key.  Both clock names store
# the guest-verified raw NVAPI GDDR5 value: twice the frequency rendered by
# GPU-Z-like consumers.  Keep the legacy name for older shim builds.
$specKey = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvAPI'
New-Item -Path $specKey -Force | Out-Null
# IdentityContractVersion is the completion marker consumed by the shim.
# Invalidate the previous generation before changing any identity field.
Remove-ItemProperty -Path $specKey -Name IdentityContractVersion -Force `
    -ErrorAction SilentlyContinue
$expectedStrings = [ordered]@{
    IdentityProfileKey = $ProfileKey
    IdentityCatalogSha256 = $CatalogSha256
    IdentityGpuName = $to
    IdentityVbiosVersion = $VbiosVersion
    IdentityBoardBrand = $BoardBrand
    IdentityBoardModel = $BoardModel
    IdentityMemoryTypeName = $MemoryTypeName
    IdentityMemoryMakerName = $MemoryMakerName
    IdentityMemoryMakerNvapiName = $MemoryMakerNvapiName
    IdentityProjectionScope = $IdentityScope
    IdentityPciProjectionMode = $PciProjectionMode
}
foreach ($item in $expectedStrings.GetEnumerator()) {
    New-ItemProperty -Path $specKey -Name $item.Key -Value $item.Value `
        -PropertyType String -Force | Out-Null
}
$spec = @{
    IdentityVramMB = $VramMB
    # These values are consumed only by the forwarding DLL's public
    # NvAPI_GPU_GetPCIIdentifiers hook.  profile-tuple publishes the complete
    # catalog tuple for legacy app-local packages.  The system package selects
    # transport-device-profile-subsystem so vendor/device stay mergeable with
    # the one PnP adapter while the atomic AIB subsystem remains visible.
    # Neither policy alters PCI config space, PnP, driver binding or signature.
    IdentityPciVendorId = $NvapiPciVendorId
    IdentityPciDeviceId = $NvapiPciDeviceId
    IdentityPciSubVendorId = $NvapiPciSubVendorId
    IdentityPciSubDeviceId = $NvapiPciSubDeviceId
    IdentityPciRevisionId = $NvapiPciRevisionId
    IdentityCoreClockKHz = $CoreClockMHz * 1000
    IdentityBoostClockKHz = $BoostClockMHz * 1000
    IdentityMemoryClockNVAPIKHz = $memoryRawClockKHz
    IdentityMemoryClockKHz = $memoryRawClockKHz
    IdentityMemoryBusBits = $MemoryBusBits
    IdentityMemoryBandwidthMBps = $MemoryBandwidthMBps
    IdentityMemoryType = $MemoryType
    IdentityMemoryMaker = $MemoryMaker
    IdentityCudaCores = $CudaCores
    IdentityShaderSubPipes = $ShaderSubPipes
    IdentityRopCount = $RopCount
    IdentityTmuCount = $TmuCount
    # Every currently published profile predates hardware RT/Tensor cores.
    # Write explicit zeros so stale values from a reused base image cannot
    # override the shim's safe defaults.
    IdentityRayTracingCores = 0
    IdentityTensorCores = 0
    IdentityArchitecture = $Architecture
    IdentityImplementation = $Implementation
    IdentityChipRevision = $ChipRevision
    IdentityPcieWidth = $PcieWidth
}
foreach ($item in $spec.GetEnumerator()) {
    New-ItemProperty -Path $specKey -Name $item.Key -Value $item.Value `
        -PropertyType DWord -Force | Out-Null
}

# Both the legacy sync path and the staged profile path call this writer.
# Verify value data and registry kinds here so neither path can report success
# after a partial or redirected write.
$writtenKey = Get-Item -Path $specKey -ErrorAction Stop
$written = Get-ItemProperty -Path $specKey -ErrorAction Stop
$registryProblems = @()
foreach ($item in $expectedStrings.GetEnumerator()) {
    $property = @($written.PSObject.Properties |
        Where-Object { $_.Name -eq $item.Key })
    $actual = if ($property.Count -eq 1) {
        [string]$property[0].Value
    } else {
        $null
    }
    $kind = $null
    try {
        $kind = [string]$writtenKey.GetValueKind($item.Key)
    } catch {}
    if ($null -eq $actual -or $actual -cne [string]$item.Value -or
        $kind -cne 'String') {
        $registryProblems += "$($item.Key)='$actual'/$kind"
    }
}
foreach ($item in $spec.GetEnumerator()) {
    $property = @($written.PSObject.Properties |
        Where-Object { $_.Name -eq $item.Key })
    $actual = if ($property.Count -eq 1) {
        $property[0].Value
    } else {
        $null
    }
    $kind = $null
    try {
        $kind = [string]$writtenKey.GetValueKind($item.Key)
    } catch {}
    if ($null -eq $actual -or [int64]$actual -ne [int64]$item.Value -or
        $kind -cne 'DWord') {
        $registryProblems += "$($item.Key)=$actual/$kind"
    }
}
if ($registryProblems.Count -gt 0) {
    throw ('NVAPI identity registry verification failed: ' +
        ($registryProblems -join '; '))
}

# Commit the complete contract with one final registry-value write.  If even
# the marker readback is wrong, remove it again so a new shim process forwards
# the real NVIDIA results instead of consuming partial data.
New-ItemProperty -Path $specKey -Name IdentityContractVersion -Value 2 `
    -PropertyType DWord -Force | Out-Null
$committed = Get-ItemProperty -Path $specKey -ErrorAction Stop
$committedVersion = @($committed.PSObject.Properties |
    Where-Object { $_.Name -ceq 'IdentityContractVersion' })
$committedKind = $null
try {
    $committedKind = [string](
        (Get-Item -Path $specKey -ErrorAction Stop).GetValueKind(
            'IdentityContractVersion'
        )
    )
} catch {}
if ($committedVersion.Count -ne 1 -or
    [int64]$committedVersion[0].Value -ne 2 -or
    $committedKind -cne 'DWord') {
    Remove-ItemProperty -Path $specKey -Name IdentityContractVersion -Force `
        -ErrorAction SilentlyContinue
    throw 'NVAPI identity contract completion marker verification failed.'
}
W '  NVAPI identity registry contract committed (version 2, atomic AIB/VRAM identity).'

function RewriteKey($path) {
    if (-not (Test-Path $path)) { return }
    $props = Get-ItemProperty $path -ErrorAction SilentlyContinue
    if (-not $props) { return }
    $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -is [string] } | ForEach-Object {
        $orig = $_.Value
        $new  = $orig
        foreach ($f in $from) { $new = $new.Replace($f, $to) }
        if ($new -ne $orig) {
            W ("  $path :: $($_.Name)")
            W ("    -  $orig")
            W ("    +  $new")
            Set-ItemProperty -Path $path -Name $_.Name -Value $new -Force
        }
    }
}

$devMatchRegex = ($DeviceIdMatch | ForEach-Object { [regex]::Escape($_) }) -join '|'
W ""
W "==== Patching HKLM\SYSTEM\CurrentControlSet\Enum\PCI\* keys ===="
$pciRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
Get-ChildItem $pciRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match $devMatchRegex } | ForEach-Object {
    $inst = $_.PSPath
    Get-ChildItem $inst -ErrorAction SilentlyContinue | ForEach-Object {
        RewriteKey $_.PSPath
        Get-ChildItem $_.PSPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object { RewriteKey $_.PSPath }
    }
    RewriteKey $inst
}

# Normalize DeviceDesc format — drop the @oem6.inf,%...% prefix so Windows uses the literal
W ""
W "==== Normalizing DeviceDesc (strip oemN.inf INF reference) ===="
Get-ChildItem $pciRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match $devMatchRegex } | ForEach-Object {
    Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        $dd = (Get-ItemProperty $_.PSPath -Name DeviceDesc -ErrorAction SilentlyContinue).DeviceDesc
        if ($dd -and $dd -match '^@oem\d+\.inf,%[^%]+%;(.+)$') {
            $clean = $Matches[1]
            foreach ($f in $from) { $clean = $clean.Replace($f, $to) }
            W ("  $($_.PSPath) :: DeviceDesc => $clean")
            Set-ItemProperty -Path $_.PSPath -Name DeviceDesc -Value $clean -Force
        }
    }
}

W ""
W "==== Patching Control\Class\{4D36E968-...} (display GUID) ===="
$clsRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}'
Get-ChildItem $clsRoot -ErrorAction SilentlyContinue | ForEach-Object { RewriteKey $_.PSPath }

W ""
W "==== Patching Control\Video\{...} ===="
$vidRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Video'
Get-ChildItem $vidRoot -ErrorAction SilentlyContinue | ForEach-Object {
    RewriteKey $_.PSPath
    Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object { RewriteKey $_.PSPath }
}

W ""
W "==== Verifying Win32_VideoController ===="
$vc = Get-CimInstance Win32_VideoController
foreach ($c in $vc) {
    W ("Name = '$($c.Name)'")
    W ("Description = '$($c.Description)'")
    W ("VideoProcessor = '$($c.VideoProcessor)'")
}
W ""
W "==== DONE ===="
