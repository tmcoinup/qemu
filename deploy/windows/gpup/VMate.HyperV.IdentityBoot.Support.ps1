#Requires -Version 5.1

<#
.SYNOPSIS
    生成、安装和回滚 P-11 的来宾启动期 SMBIOS 身份扩展。

.DESCRIPTION
    扩展只在 Generation 2 VM 关机时写入系统 VHD 的 EFI 分区。原微软启动管理器
    以 SHA-256 校验的文件级备份保留；GPU-P VM 不支持 checkpoint 时仍可离线回滚。
    本模块不宣称修改直接 CPUID、GPU PnP 路径或 Hyper-V 固有设备。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VMateIdentityBootRelativePath = 'Microsoft\Boot\bootmgfw.efi'
$script:VMateIdentityBootStockRelativePath =
    'Microsoft\Boot\bootmgfw.vmate-stock.efi'
$script:VMateIdentityBootConfigRelativePath = 'VMate\identity.ini'
$script:VMateIdentityBootManifestRelativePath =
    'VMate\identity-manifest.json'

function Get-VMateHyperVIdentityBootProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Label = 'identity object'
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Label 缺少 $Name 属性。" }
    return $property.Value
}

function Get-VMateHyperVIdentityBootOptionalProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-VMateHyperVIdentityBootProfileId {
    param([Parameter(Mandatory = $true)][object]$Profile)

    foreach ($name in @('Id', 'ProfileId')) {
        $property = $Profile.PSObject.Properties[$name]
        if ($null -ne $property -and
            -not [String]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    throw 'HardwareProfile 缺少 Id/ProfileId。'
}

function ConvertTo-VMateHyperVIdentityBootAscii {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $text = [string]$Value
    if ($text.Length -lt 1 -or $text.Length -gt 64 -or
        $text -cne $text.Trim() -or $text -match '[^\x20-\x7e]' -or
        $text.Contains('=')) {
        throw "$Label 必须是 1..64 位安全 ASCII，且不能包含等号。"
    }
    return $text
}

function Get-VMateHyperVIdentityBootDerivedSerial {
    param(
        [Parameter(Mandatory = $true)][object]$Firmware,
        [Parameter(Mandatory = $true)][string]$Domain
    )

    $parts = @($Domain)
    foreach ($name in @('BIOSGUID', 'BIOSSerialNumber',
            'BaseBoardSerialNumber', 'ChassisSerialNumber',
            'ChassisAssetTag')) {
        $parts += [string](Get-VMateHyperVIdentityBootProperty `
                $Firmware $name 'HardwareIdentity.Firmware')
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($parts -join '|'))
        $digest = $sha.ComputeHash($bytes)
    }
    finally { $sha.Dispose() }
    return ([BitConverter]::ToString($digest, 0, 16)).Replace('-', '')
}

function ConvertTo-VMateHyperVIdentityBootDate {
    param([Parameter(Mandatory = $true)][string]$Value)

    $parsed = [DateTime]::MinValue
    $formats = [string[]]@('yyyy-MM-dd', 'MM/dd/yyyy')
    if (-not [DateTime]::TryParseExact(
            $Value, $formats, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw "BIOS release_date 无效：$Value"
    }
    return $parsed.ToString(
        'MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-VMateHyperVIdentityBootMemoryType {
    param([Parameter(Mandatory = $true)][object]$Value)

    $number = 0
    if ([int]::TryParse([string]$Value, [ref]$number) -and
        $number -ge 1 -and $number -le 255) {
        return $number
    }
    if ([string]$Value -match '^0[xX]([0-9a-fA-F]{1,2})$') {
        $number = [Convert]::ToInt32($Matches[1], 16)
        if ($number -ge 1 -and $number -le 255) { return $number }
    }
    switch (([string]$Value).Trim().ToUpperInvariant()) {
        'DDR3' { return 24 }
        'DDR4' { return 26 }
        'LPDDR4' { return 30 }
        'DDR5' { return 34 }
        'LPDDR5' { return 35 }
        default { throw "不支持的 SMBIOS memory type：$Value" }
    }
}

function ConvertTo-VMateHyperVIdentityBootChassisType {
    param([Parameter(Mandatory = $true)][object]$Value)

    $number = 0
    if ([int]::TryParse([string]$Value, [ref]$number) -and
        $number -ge 1 -and $number -le 127) {
        return $number
    }
    if ([string]$Value -match '^0[xX]([0-9a-fA-F]{1,2})$') {
        $number = [Convert]::ToInt32($Matches[1], 16)
        if ($number -ge 1 -and $number -le 127) { return $number }
    }
    switch (([string]$Value).Trim().ToLowerInvariant()) {
        'desktop' { return 3 }
        'low profile desktop' { return 4 }
        'tower' { return 7 }
        'portable' { return 8 }
        'laptop' { return 9 }
        'notebook' { return 10 }
        'mini pc' { return 35 }
        default { throw "不支持的 SMBIOS chassis type：$Value" }
    }
}

function New-VMateHyperVIdentityBootConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$HardwareIdentity
    )

    $processor = Get-VMateHyperVIdentityBootProperty `
        $Profile 'Processor' 'HardwareProfile'
    $memory = Get-VMateHyperVIdentityBootProperty `
        $Profile 'Memory' 'HardwareProfile'
    $platform = Get-VMateHyperVIdentityBootProperty `
        $Profile 'Platform' 'HardwareProfile'
    $bios = Get-VMateHyperVIdentityBootProperty `
        $Profile 'Bios' 'HardwareProfile'
    $firmware = Get-VMateHyperVIdentityBootProperty `
        $HardwareIdentity 'Firmware' 'HardwareIdentity'
    $systemProduct = Get-VMateHyperVIdentityBootOptionalProperty `
        $platform 'system_product' $null
    if ([String]::IsNullOrWhiteSpace([string]$systemProduct)) {
        $systemProduct = Get-VMateHyperVIdentityBootProperty `
            $platform 'product' 'HardwareProfile.Platform'
    }
    $systemFamily = Get-VMateHyperVIdentityBootOptionalProperty `
        $platform 'system_family' 'Default string'
    $version = Get-VMateHyperVIdentityBootOptionalProperty `
        $platform 'version' '1.0'
    $memoryManufacturer = Get-VMateHyperVIdentityBootOptionalProperty `
        $memory 'manufacturer' 'JEDEC'
    $memoryPart = Get-VMateHyperVIdentityBootOptionalProperty `
        $memory 'part_number' 'VMATE-MEMORY'
    $speed = [int](Get-VMateHyperVIdentityBootOptionalProperty `
            $memory 'speed_mts' (Get-VMateHyperVIdentityBootOptionalProperty `
                $memory 'max_mts' 3200))
    if ($speed -lt 1 -or $speed -gt 65535) {
        throw "memory speed 越界：$speed"
    }

    $fields = [ordered]@{
        BiosVendor = Get-VMateHyperVIdentityBootProperty `
            $bios 'manufacturer' 'HardwareProfile.Bios'
        BiosVersion = Get-VMateHyperVIdentityBootProperty `
            $bios 'version' 'HardwareProfile.Bios'
        BiosDate = ConvertTo-VMateHyperVIdentityBootDate ([string](
                Get-VMateHyperVIdentityBootProperty `
                    $bios 'release_date' 'HardwareProfile.Bios'))
        SystemManufacturer = Get-VMateHyperVIdentityBootProperty `
            $platform 'manufacturer' 'HardwareProfile.Platform'
        SystemProduct = $systemProduct
        SystemVersion = $version
        SystemSerial = Get-VMateHyperVIdentityBootDerivedSerial `
            $firmware 'SYSTEM-SERIAL'
        SystemSku = 'P11-' + $VMId.ToString('N').Substring(0, 8).ToUpperInvariant()
        SystemFamily = $systemFamily
        BoardManufacturer = Get-VMateHyperVIdentityBootProperty `
            $platform 'manufacturer' 'HardwareProfile.Platform'
        BoardProduct = Get-VMateHyperVIdentityBootProperty `
            $platform 'product' 'HardwareProfile.Platform'
        BoardVersion = $version
        BoardSerial = Get-VMateHyperVIdentityBootProperty `
            $firmware 'BaseBoardSerialNumber' 'HardwareIdentity.Firmware'
        BoardAsset = Get-VMateHyperVIdentityBootDerivedSerial `
            $firmware 'BOARD-ASSET'
        ChassisManufacturer = Get-VMateHyperVIdentityBootProperty `
            $platform 'manufacturer' 'HardwareProfile.Platform'
        ChassisVersion = $version
        ChassisSerial = Get-VMateHyperVIdentityBootProperty `
            $firmware 'ChassisSerialNumber' 'HardwareIdentity.Firmware'
        ChassisAsset = Get-VMateHyperVIdentityBootProperty `
            $firmware 'ChassisAssetTag' 'HardwareIdentity.Firmware'
        CpuManufacturer = Get-VMateHyperVIdentityBootProperty `
            $processor 'Manufacturer' 'HardwareProfile.Processor'
        CpuVersion = Get-VMateHyperVIdentityBootProperty `
            $processor 'Name' 'HardwareProfile.Processor'
        CpuSerial = Get-VMateHyperVIdentityBootDerivedSerial `
            $firmware 'CPU-SERIAL'
        CpuAsset = Get-VMateHyperVIdentityBootDerivedSerial `
            $firmware 'CPU-ASSET'
        CpuPart = Get-VMateHyperVIdentityBootDerivedSerial `
            $firmware 'CPU-PART'
        MemoryManufacturer = $memoryManufacturer
        MemorySerial = Get-VMateHyperVIdentityBootDerivedSerial `
            $firmware 'MEMORY-SERIAL'
        MemoryAsset = Get-VMateHyperVIdentityBootDerivedSerial `
            $firmware 'MEMORY-ASSET'
        MemoryPart = $memoryPart
        ChassisType = ConvertTo-VMateHyperVIdentityBootChassisType `
            (Get-VMateHyperVIdentityBootProperty `
                $platform 'chassis_type' 'HardwareProfile.Platform')
        MemoryType = ConvertTo-VMateHyperVIdentityBootMemoryType `
            (Get-VMateHyperVIdentityBootProperty `
                $memory 'type' 'HardwareProfile.Memory')
        MemorySpeed = $speed
        MemoryConfiguredSpeed = $speed
    }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($name in $fields.Keys) {
        $value = if ($name -in @('ChassisType', 'MemoryType',
                'MemorySpeed', 'MemoryConfiguredSpeed')) {
            [string]$fields[$name]
        } else {
            ConvertTo-VMateHyperVIdentityBootAscii $fields[$name] $name
        }
        [void]$lines.Add("$name=$value")
    }
    $text = (@($lines) -join "`r`n") + "`r`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString(
                $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '')
    }
    finally { $sha.Dispose() }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        VMId = $VMId.ToString('D')
        FieldCount = $fields.Count
        Fields = [pscustomobject]$fields
        Text = $text
        Sha256 = $hash
        Capability = 'guest-boot-smbios-only'
        DoesNotModify = @('direct-cpuid', 'gpu-pnp-instance-id',
            'hyper-v-intrinsic-devices')
    }
}

function Import-VMateHyperVIdentityBootConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$ExpectedConfig,
        [switch]$AllowProfileReplacement
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw '已安装扩展缺少 identity.ini；拒绝重新生成序列。'
    }
    $sourceBytes = [IO.File]::ReadAllBytes($Path)
    $hadUtf8Bom = $sourceBytes.Length -ge 3 -and
        $sourceBytes[0] -eq 0xef -and $sourceBytes[1] -eq 0xbb -and
        $sourceBytes[2] -eq 0xbf
    $text = [Text.Encoding]::UTF8.GetString($sourceBytes)
    if ($hadUtf8Bom) { $text = $text.Substring(1) }
    $legacyLineEndingsNormalized = $false
    if ($text.Contains("`r`n")) {
        $withoutCrLf = $text.Replace("`r`n", '')
        if ($withoutCrLf.Contains("`r") -or $withoutCrLf.Contains("`n")) {
            throw '已安装 identity.ini 混用了换行格式。'
        }
    }
    elseif ($text.Contains("`n") -and -not $text.Contains("`r")) {
        $text = $text.Replace("`n", "`r`n")
        $legacyLineEndingsNormalized = $true
    }
    if ($text.Length -lt 1 -or -not $text.EndsWith("`r`n") -or
        $text -match '[^\x0d\x0a\x20-\x7e]') {
        throw '已安装 identity.ini 不是可迁移的 ASCII/CRLF 格式。'
    }
    $lines = @($text.Substring(0, $text.Length - 2) -split "`r`n")
    $expectedNames = @($ExpectedConfig.Fields.PSObject.Properties.Name)
    if ($lines.Count -ne $expectedNames.Count -or $lines.Count -ne 31) {
        throw '已安装 identity.ini 不是严格 31 字段。'
    }
    $fields = [ordered]@{}
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -cnotmatch '^([^=]+)=([^=]+)$') {
            throw "已安装 identity.ini 第 $($index + 1) 行无效。"
        }
        $name = [string]$Matches[1]
        $value = [string]$Matches[2]
        if ($name -cne [string]$expectedNames[$index]) {
            throw "已安装 identity.ini 字段顺序/名称不匹配：$name"
        }
        [void](ConvertTo-VMateHyperVIdentityBootAscii $value $name)
        $fields[$name] = $value
    }
    # 序列与资产字段由第一次安装拥有；升级只校验不会改变平台事实的字段。
    $profileFields = @(
        'BiosVendor', 'BiosVersion', 'BiosDate',
        'SystemManufacturer', 'SystemProduct', 'SystemVersion', 'SystemSku',
        'SystemFamily', 'BoardManufacturer', 'BoardProduct', 'BoardVersion',
        'ChassisManufacturer', 'ChassisVersion', 'CpuManufacturer',
        'CpuVersion', 'MemoryManufacturer', 'MemoryPart', 'ChassisType',
        'MemoryType', 'MemorySpeed', 'MemoryConfiguredSpeed'
    )
    foreach ($name in $profileFields) {
        if ([string]$fields[$name] -cne [string]$ExpectedConfig.Fields.$name) {
            if (-not $AllowProfileReplacement) {
                throw "已安装 identity.ini 的 $name 与绑定 profile 不匹配。"
            }
            $fields[$name] = [string]$ExpectedConfig.Fields.$name
        }
    }
    if ($AllowProfileReplacement) {
        $normalizedLines = [Collections.Generic.List[string]]::new()
        foreach ($name in $expectedNames) {
            [void]$normalizedLines.Add("$name=$($fields[$name])")
        }
        $text = (@($normalizedLines) -join "`r`n") + "`r`n"
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha.ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '')
        $sourceHash = ([BitConverter]::ToString(
                $sha.ComputeHash($sourceBytes))).Replace('-', '')
    }
    finally { $sha.Dispose() }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        VMId = [string]$ExpectedConfig.VMId
        FieldCount = 31
        Fields = [pscustomobject]$fields
        Text = $text
        Sha256 = $hash
        SourceSha256 = $sourceHash
        LegacyUtf8BomRemoved = [bool]$hadUtf8Bom
        LegacyLineEndingsNormalized = [bool]$legacyLineEndingsNormalized
        Capability = 'guest-boot-smbios-only'
        IdentityPolicy = if ($AllowProfileReplacement) {
            'preserve-unique-serials-explicit-offline-profile-replacement'
        } else { 'preserve-first-installed-no-reroll' }
    }
}

function Assert-VMateHyperVIdentityBootVm {
    param([Parameter(Mandatory = $true)][object]$VM)

    if ([string]$VM.State -cne 'Off') {
        throw 'VMate identity boot 只能在 VM Off 状态安装或回滚。'
    }
    if ([int]$VM.Generation -ne 2) {
        throw 'VMate identity boot 只支持 Generation 2 VM。'
    }
}

function Invoke-VMateHyperVIdentityBootEsp {
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [switch]$ReadOnly
    )

    $drives = @(Get-VMHardDiskDrive -VM $VM | Where-Object {
            $_.ControllerLocation -eq 0
        })
    if ($drives.Count -ne 1) { throw '无法唯一解析 VM 系统 VHD。' }
    $path = [string]$drives[0].Path
    $mounted = $false
    try {
        $disk = Mount-VHD -Path $path -ReadOnly:$ReadOnly.IsPresent -Passthru
        $mounted = $true
        Set-Disk -Number $disk.DiskNumber -IsOffline $false -ErrorAction Stop
        if (-not $ReadOnly) {
            Set-Disk -Number $disk.DiskNumber -IsReadOnly $false `
                -ErrorAction Stop
        }
        $esp = @(Get-Partition -DiskNumber $disk.DiskNumber | Where-Object {
                [string]$_.GptType -ieq `
                    '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
            })
        if ($esp.Count -ne 1) { throw '无法唯一解析 EFI system partition。' }
        $volume = $esp[0] | Get-Volume -ErrorAction Stop
        $root = Join-Path ([string]$volume.Path) 'EFI'
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw '挂载后没有找到 EFI 根目录。'
        }
        return & $Action $root
    }
    finally {
        if ($mounted) { Dismount-VHD -Path $path -ErrorAction Stop }
    }
}

