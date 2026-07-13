#Requires -Version 5.1

<#
.SYNOPSIS
    加载并校验 Windows/Linux 共用的可更换硬件部件目录。

.DESCRIPTION
    整机平台负责 CPU、主板和芯片组；本模块只负责 SSD、显示器和 HID。
    目录中的关联字段作为一个整体校验，避免从不同真实设备拼出不存在的组合。
    生成后的 profile 会保存目录修订、摘要和所选 ID，普通重启不重新选择。
#>

function Test-VMateComponentProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-VMateComponentDigest {
    param([object]$Catalog)

    $json = $Catalog | ConvertTo-Json -Depth 64 -Compress
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $digest = $sha256.ComputeHash($bytes)
        return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-VMateSingleEnabledComponent {
    param(
        [object[]]$Items,
        [string]$Kind
    )

    $enabled = @($Items | Where-Object { $_.enabled -eq $true })
    if ($enabled.Count -ne 1) {
        throw "部件目录 '$Kind' 必须且只能启用一个已核验模板，实际：$($enabled.Count)"
    }
    if (-not (Test-VMateComponentProperty $enabled[0] 'id') -or
        -not [string]$enabled[0].id) {
        throw "部件目录 '$Kind' 的启用项缺少 ID。"
    }
    return $enabled[0]
}

function Assert-VMateStorageComponent {
    param([object]$Storage)

    foreach ($field in @('model', 'firmware', 'raw_bytes', 'pci', 'nvme')) {
        if (-not (Test-VMateComponentProperty $Storage $field)) {
            throw "SSD 部件 '$($Storage.id)' 缺少字段 '$field'。"
        }
    }
    # 当前 C 行为层的 use-samsung-id 只实现这一套经过关联验证的身份。
    if ([string]$Storage.model -ne 'Samsung SSD 970 PRO 512GB' -or
        [string]$Storage.firmware -ne '1B2QEXP7' -or
        [int64]$Storage.raw_bytes -ne 512110190592) {
        throw 'SSD 目录必须匹配已实现的 Samsung 970 PRO 512GB 型号/固件/容量。'
    }
    $pciTuple = @('vendor', 'device', 'subsystem_vendor', 'subsystem_device') |
        ForEach-Object { ([string]$Storage.pci.$_).ToUpperInvariant() }
    if (($pciTuple -join ':') -ne '0X144D:0XA804:0X144D:0XA801') {
        throw 'Samsung 970 PRO PCI 身份必须为 144d:a804 / 144d:a801。'
    }
    if ([int]$Storage.nvme.pcie_generation -ne 3 -or
        [int]$Storage.nvme.lanes -ne 4 -or
        [string]$Storage.nvme.ieee_oui -ne '00:25:38' -or
        [string]$Storage.nvme.subnqn_template -notmatch '\{serial\}') {
        throw 'Samsung 970 PRO NVMe 链路、OUI 或 subnqn 模板不完整。'
    }
}

function Assert-VMateMonitorComponent {
    param([object]$Monitor)

    foreach ($field in @('vendor_code', 'product_id', 'name', 'serial_prefix',
            'width_mm', 'height_mm', 'manufacture_week', 'manufacture_year',
            'video_input', 'range', 'secondary_timing', 'evidence')) {
        if (-not (Test-VMateComponentProperty $Monitor $field)) {
            throw "显示器部件 '$($Monitor.id)' 缺少字段 '$field'。"
        }
    }
    if ([string]$Monitor.vendor_code -notmatch '^[A-Z]{3}$' -or
        [string]$Monitor.product_id -notmatch '^0x[0-9A-Fa-f]{4}$' -or
        [string]$Monitor.video_input -notmatch '^0x[0-9A-Fa-f]{2}$' -or
        [string]$Monitor.serial_prefix -notmatch '^[A-Za-z0-9]{1,8}$') {
        throw "显示器 '$($Monitor.id)' 的厂商、产品、输入或序列前缀格式无效。"
    }
    if (-not (Test-VMateUnsignedInteger $Monitor.width_mm 1 65535) -or
        -not (Test-VMateUnsignedInteger $Monitor.height_mm 1 65535) -or
        -not (Test-VMateUnsignedInteger $Monitor.manufacture_week 1 53) -or
        -not (Test-VMateUnsignedInteger $Monitor.manufacture_year 1990 2100)) {
        throw "显示器 '$($Monitor.id)' 的物理尺寸或生产日期无效。"
    }
    $range = $Monitor.range
    foreach ($field in @('min_vfreq_hz', 'max_vfreq_hz', 'min_hfreq_khz',
            'max_hfreq_khz', 'max_pixel_clock_mhz')) {
        if (-not (Test-VMateComponentProperty $range $field) -or
            -not (Test-VMateUnsignedInteger $range.$field 1 65535)) {
            throw "显示器 '$($Monitor.id)' 的 range.$field 无效。"
        }
    }
    if ([int]$range.min_vfreq_hz -gt [int]$range.max_vfreq_hz -or
        [int]$range.min_hfreq_khz -gt [int]$range.max_hfreq_khz -or
        [int]$range.max_pixel_clock_mhz -lt 1) {
        throw "显示器 '$($Monitor.id)' 的扫描范围无效。"
    }
    $timing = $Monitor.secondary_timing
    foreach ($field in @('xres', 'yres', 'refresh_millihz')) {
        if (-not (Test-VMateComponentProperty $timing $field) -or
            -not (Test-VMateUnsignedInteger $timing.$field 1 1000000)) {
            throw "显示器 '$($Monitor.id)' 的 secondary_timing.$field 无效。"
        }
    }
}

function Assert-VMateHidComponent {
    param(
        [object]$Hid,
        [string]$Kind,
        [string]$ExpectedVendor,
        [string]$ExpectedProduct,
        [string]$ExpectedBcd,
        [string]$ExpectedName
    )

    foreach ($field in @('vendor_id', 'product_id', 'bcd_device', 'manufacturer',
            'product', 'serial_exposed', 'descriptor_fidelity')) {
        if (-not (Test-VMateComponentProperty $Hid $field)) {
            throw "HID 部件 '$Kind/$($Hid.id)' 缺少字段 '$field'。"
        }
    }
    if ([string]$Hid.vendor_id -ne $ExpectedVendor -or
        [string]$Hid.product_id -ne $ExpectedProduct -or
        [string]$Hid.bcd_device -ne $ExpectedBcd -or
        [string]$Hid.manufacturer -ne 'Microsoft' -or
        [string]$Hid.product -ne $ExpectedName -or
        $Hid.serial_exposed -ne $false -or
        [string]$Hid.descriptor_fidelity -ne 'fixed_template') {
        throw "HID 部件 '$Kind/$($Hid.id)' 与 patched C descriptor 不一致。"
    }
}

function Read-VMateComponentManifest {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到共享部件目录：$Path"
    }
    try {
        $root = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "共享部件目录不是有效 JSON：$Path；$($_.Exception.Message)"
    }
    if ([int]$root.schema_version -ne 1 -or -not [string]$root.catalog_revision) {
        throw '部件目录只支持 schema_version=1，且必须包含 catalog_revision。'
    }
    if ([string]$root.scope.gpu -ne 'out_of_scope_virtual_display') {
        throw '部件目录必须明确 GPU 为本分支范围外的虚拟显示。'
    }
    $storage = Get-VMateSingleEnabledComponent @($root.storage) 'storage'
    $monitor = Get-VMateSingleEnabledComponent @($root.monitors) 'monitors'
    $keyboard = Get-VMateSingleEnabledComponent @($root.hid.keyboards) 'keyboards'
    $mouse = Get-VMateSingleEnabledComponent @($root.hid.mice) 'mice'
    $tablet = Get-VMateSingleEnabledComponent @($root.hid.tablets) 'tablets'
    Assert-VMateStorageComponent $storage
    Assert-VMateMonitorComponent $monitor
    Assert-VMateHidComponent $keyboard 'keyboards' '0x045E' '0x0750' '0x0163' `
        'Microsoft Wired Keyboard 600'
    Assert-VMateHidComponent $mouse 'mice' '0x045E' '0x00CB' '0x0163' `
        'Microsoft USB Optical Mouse'
    if ([string]$tablet.vendor_id -ne '0x0627' -or
        [string]$tablet.product_id -ne '0x0001' -or
        [string]$tablet.bcd_device -ne '0x0000' -or
        $tablet.serial_exposed -ne $false -or
        [string]$tablet.descriptor_fidelity -ne 'generic_virtual_only') {
        throw '通用 tablet 目录与 patched C descriptor 不一致。'
    }
    return [pscustomobject]@{
        schema_version = [int]$root.schema_version
        catalog_revision = [string]$root.catalog_revision
        catalog_digest = Get-VMateComponentDigest $root
        storage = $storage
        monitor = $monitor
        keyboard = $keyboard
        mouse = $mouse
        tablet = $tablet
    }
}

function New-VMateComponentProfileBinding {
    param([object]$Components)

    return [ordered]@{
        schema_version = [int]$Components.schema_version
        catalog_revision = [string]$Components.catalog_revision
        catalog_digest = [string]$Components.catalog_digest
        storage_id = [string]$Components.storage.id
        monitor_id = [string]$Components.monitor.id
        keyboard_id = [string]$Components.keyboard.id
        mouse_id = [string]$Components.mouse.id
    }
}

function Assert-VMateComponentProfileBinding {
    param(
        [object]$Binding,
        [object]$Components
    )

    $expected = New-VMateComponentProfileBinding $Components
    foreach ($field in @('schema_version', 'catalog_revision', 'catalog_digest',
            'storage_id', 'monitor_id', 'keyboard_id', 'mouse_id')) {
        if (-not (Test-VMateComponentProperty $Binding $field) -or
            [string]$Binding.$field -ne [string]$expected.$field) {
            throw "硬件 profile 的部件绑定 '$field' 与当前目录不一致；请审核后 reroll。"
        }
    }
}

function Get-VMateNvmeSubnqn {
    param(
        [object]$Components,
        [string]$Serial
    )

    $value = ([string]$Components.storage.nvme.subnqn_template).Replace(
        '{serial}', $Serial)
    if ($value -notmatch '^nqn\.' -or $value.Length -ge 256 -or
        $value -match '[{},\r\n]') {
        throw '由部件目录生成的 NVMe subnqn 无效。'
    }
    return $value
}

function Get-VMateMonitorEdidSuffix {
    param(
        [object]$Components,
        [object]$Profile
    )

    $monitor = $Components.monitor
    $range = $monitor.range
    $timing = $monitor.secondary_timing
    $fields = [ordered]@{
        'edid-vendor' = [string]$monitor.vendor_code
        'edid-name' = [string]$monitor.name
        'edid-serial' = [string]$Profile.identity.monitor_serial
        'edid-width-mm' = [int]$monitor.width_mm
        'edid-height-mm' = [int]$monitor.height_mm
        'edid-product-id' = ([string]$monitor.product_id).ToLowerInvariant()
        'edid-manufacture-week' = [int]$monitor.manufacture_week
        'edid-manufacture-year' = [int]$monitor.manufacture_year
        'edid-video-input' = ([string]$monitor.video_input).ToLowerInvariant()
        'edid-min-vfreq-hz' = [int]$range.min_vfreq_hz
        'edid-max-vfreq-hz' = [int]$range.max_vfreq_hz
        'edid-min-hfreq-khz' = [int]$range.min_hfreq_khz
        'edid-max-hfreq-khz' = [int]$range.max_hfreq_khz
        'edid-max-pixel-clock-mhz' = [int]$range.max_pixel_clock_mhz
        'edid-secondary-xres' = [int]$timing.xres
        'edid-secondary-yres' = [int]$timing.yres
        'edid-secondary-refresh-rate' = [int]$timing.refresh_millihz
    }
    $pairs = @($fields.GetEnumerator() | ForEach-Object {
        $_.Key + '=' + (ConvertTo-VMateQemuString ([string]$_.Value))
    })
    return ',' + ($pairs -join ',')
}

function Assert-VMateStorageCapacity {
    param(
        [string]$QemuImg,
        [string]$Disk,
        [int64]$ExpectedBytes,
        [bool]$DryRun
    )

    if ($DryRun) {
        return
    }
    if (-not (Test-Path -LiteralPath $QemuImg -PathType Leaf)) {
        throw "找不到同版本 qemu-img.exe，无法核验 NVMe 容量：$QemuImg"
    }
    try {
        $output = & $QemuImg 'info' '--output=json' $Disk 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "qemu-img exit code=$LASTEXITCODE；$output"
        }
        $info = $output | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "无法核验磁盘虚拟容量：$($_.Exception.Message)"
    }
    if ([int64]$info.'virtual-size' -ne $ExpectedBytes) {
        throw "磁盘虚拟容量 $($info.'virtual-size') bytes 与部件目录 $ExpectedBytes bytes 不一致。"
    }
}
