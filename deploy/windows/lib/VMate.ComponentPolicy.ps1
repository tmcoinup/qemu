#Requires -Version 5.1

<#
.SYNOPSIS
    提供组件策略公共校验器并校验显示器原子身份。

.DESCRIPTION
    公共校验器供 SSD、GPU 和显示器策略模块复用。显示器型号、EDID 身份、
    扫描范围和序列号策略作为一个整体变化，不能跨品牌拼接。
#>

function Test-VMatePolicyInteger {
    param([object]$Value)

    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Assert-VMatePolicyFields {
    param(
        [object]$Object,
        [string[]]$Fields,
        [string]$Label
    )

    if ($null -eq $Object) {
        throw "$Label 不能为空。"
    }
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Fields | Sort-Object)
    if (($actual -join "`n") -cne ($expected -join "`n")) {
        throw "$Label 字段集合无效；实际：$($actual -join ', ')"
    }
}

function Assert-VMatePolicySources {
    param(
        [object]$Value,
        [string[]]$AllowedHosts,
        [string]$Label,
        [int]$Minimum = 2
    )

    if ($Value -isnot [System.Array]) {
        throw "$Label 必须是 JSON 数组。"
    }
    $sources = @($Value)
    if ($sources.Count -lt $Minimum -or
        @($sources | Select-Object -Unique).Count -ne $sources.Count) {
        throw "$Label 必须包含至少 $Minimum 条互不重复的来源。"
    }
    foreach ($source in $sources) {
        $uri = $null
        if ($source -isnot [string] -or
            -not [Uri]::TryCreate([string]$source, [UriKind]::Absolute,
                [ref]$uri) -or
            $uri.Scheme -cne 'https' -or
            $uri.DnsSafeHost.ToLowerInvariant() -notin $AllowedHosts) {
            throw "$Label 含未授权来源域名：$source"
        }
    }
}

function Get-VMateMonitorContract {
    param([string]$Id)

    $knownIds = @(
        'samsung-s24f350',
        'aoc-24b2xh',
        'xiaomi-rmmnt238nf',
        'lenovo-l24e-30'
    )
    if ($Id -cnotin $knownIds) {
        return $null
    }
    $contracts = @{
        'samsung-s24f350' = @{
            SelectionWeight = 2
            ReleaseYear = 2016
            FriendlyName = 'Samsung S24F350'
            Facts = @('Samsung', 'LS24F350FHUXEN', 'SAM', '0x0D20',
                'S24F350', 521, 293, 49, 2019, '0x80')
            Range = @(50, 75, 30, 81, 170)
            Serial = @('samsung_h4zmc_decimal5', 10,
                '^H4ZMC[0-9]{5}$')
            ReservedValues = @('H4ZMC01676', 'H4ZMC01889')
            BinarySerial = @('fixed_u32', '0x5A5A5055',
                'observed_raw_edid_value')
            Revision = 3
            Timing = @(1280, 720, 50000, 74250, 440, 40, 700, 5, 5, 30,
                $true, $true, 521, 293)
            SerialFidelity = 'observed_raw_edid_format_synthetic_value'
            Hosts = @('www.samsung.com', 'images.samsung.com')
            IdentityHosts = @('raw.githubusercontent.com')
            Evidence = 'official_specs_plus_raw_edid_capture'
        }
        'aoc-24b2xh' = @{
            SelectionWeight = 6
            ReleaseYear = 2020
            FriendlyName = 'AOC 24B2XH'
            Facts = @('AOC', '24B2XH', 'AOC', '0x2402', '24B2W1G5',
                527, 296, 39, 2022, '0x80')
            Range = @(48, 75, 30, 85, 180)
            Serial = @('aoc_upper_alnum7_decimal6', 13,
                '^[A-Z]{4}[0-9][A-Z0-9]A[0-9]{6}$')
            ReservedValues = @('UOWN9HA005249', 'AWDM61A005357',
                'RSKN61A000560')
            BinarySerial = @('decimal_suffix6', $null,
                'observed_raw_edid_rule')
            Revision = 3
            Timing = @(1920, 1080, 74973, 174500, 48, 32, 160, 3, 5, 39,
                $true, $false, 527, 296)
            SerialFidelity = 'observed_raw_edid_format_synthetic_value'
            Hosts = @('www.aoc.com')
            IdentityHosts = @('raw.githubusercontent.com', 'bugs.kde.org')
            Evidence = 'official_specs_plus_raw_edid_capture'
        }
        'xiaomi-rmmnt238nf' = @{
            SelectionWeight = 5
            ReleaseYear = 2020
            FriendlyName = 'Xiaomi Mi Monitor (RMMNT238NF)'
            Facts = @('Xiaomi', 'RMMNT238NF', 'XMI', '0x23C3',
                'Mi Monitor', 527, 293, 20, 2020, '0x80')
            Range = @(50, 75, 15, 100, 190)
            Serial = @('xiaomi_29200_label_slash_removed_decimal', 13,
                '^29200[0-9]{8}$')
            ReservedValues = @('2920000167575', '2920000116680')
            BinarySerial = @('fixed_u32', '0x00000001',
                'observed_raw_edid_value')
            Revision = 3
            Timing = @(1920, 1080, 75002, 185630, 48, 40, 280, 5, 5, 45,
                $true, $true, 160, 90)
            SerialFidelity =
                'official_label_separator_removed_as_observed_in_raw_edid'
            Hosts = @('www.mi.com')
            IdentityHosts = @('raw.githubusercontent.com')
            Evidence = 'official_specs_plus_raw_edid_capture'
        }
        'lenovo-l24e-30' = @{
            SelectionWeight = 4
            ReleaseYear = 2020
            FriendlyName = 'Lenovo L24e-30'
            Facts = @('Lenovo', 'L24e-30', 'LEN', '0x66BC', 'L24e-30',
                527, 296, 5, 2022, '0x80')
            Range = @(48, 75, 30, 83, 180)
            Serial = @('lenovo_urb_upper_alnum', 8,
                '^URB[A-Z0-9]{5}$')
            ReservedValues = @('URB5DT6H', 'URB4N2F4', 'URB644NY')
            BinarySerial = @('fixed_u32', '0x01010101',
                'observed_raw_edid_value')
            Revision = 3
            Timing = @(1920, 1080, 74973, 174500, 48, 32, 160, 3, 5, 39,
                $true, $false, 527, 296)
            SerialFidelity = 'observed_raw_edid_format_synthetic_value'
            Hosts = @('psref.lenovo.com')
            IdentityHosts = @('download.lenovo.com',
                'raw.githubusercontent.com')
            Evidence = 'official_specs_driver_plus_raw_edid_capture'
        }
    }
    return $contracts[$Id]
}

function Assert-VMateMonitorComponent {
    param([object]$Monitor)

    $fields = @('id', 'enabled', 'selection_weight', 'release_year',
        'manufacturer', 'model', 'windows_friendly_name', 'vendor_code',
        'product_id', 'name',
        'serial_policy', 'binary_serial_policy', 'native_resolution', 'width_mm',
        'height_mm', 'manufacture_week', 'manufacture_year', 'video_input',
        'edid_revision', 'range', 'secondary_timing', 'evidence', 'identity_fidelity',
        'source_refs', 'identity_source_refs')
    Assert-VMatePolicyFields $Monitor $fields "显示器 '$($Monitor.id)'"
    $id = [string]$Monitor.id
    $contract = Get-VMateMonitorContract $id
    if ($null -eq $contract) {
        throw "显示器 '$id' 没有已审计 EDID 模板。"
    }
    foreach ($field in @('selection_weight', 'release_year', 'width_mm',
            'height_mm', 'manufacture_week', 'manufacture_year',
            'edid_revision')) {
        if (-not (Test-VMatePolicyInteger $Monitor.$field)) {
            throw "显示器 '$id' 的 $field 必须是 JSON 整数。"
        }
    }
    if ($Monitor.enabled -isnot [bool] -or $Monitor.enabled -ne $true -or
        [int]$Monitor.selection_weight -ne
            [int]$contract.SelectionWeight -or
        [int]$Monitor.release_year -ne [int]$contract.ReleaseYear -or
        [int]$Monitor.manufacture_year -lt [int]$Monitor.release_year -or
        [int]$Monitor.edid_revision -ne [int]$contract.Revision) {
        throw "显示器 '$id' 的启用状态、选择权重或发售年份与受控目录不一致。"
    }
    $facts = @([string]$Monitor.manufacturer, [string]$Monitor.model,
        [string]$Monitor.vendor_code, [string]$Monitor.product_id,
        [string]$Monitor.name, [int]$Monitor.width_mm,
        [int]$Monitor.height_mm, [int]$Monitor.manufacture_week,
        [int]$Monitor.manufacture_year, [string]$Monitor.video_input)
    if (($facts -join "`n") -cne (@($contract.Facts) -join "`n")) {
        throw "显示器 '$id' 的型号、EDID 厂商或物理规格被交叉拼接。"
    }
    $friendlyName = [string]$Monitor.windows_friendly_name
    if ([string]::IsNullOrWhiteSpace($friendlyName) -or
        $friendlyName.Length -gt 128 -or
        $friendlyName -match '[\x00-\x1F\x7F]' -or
        $friendlyName -cne [string]$contract.FriendlyName) {
        throw "显示器 '$id' 的 Windows FriendlyName 无效。"
    }
    Assert-VMatePolicyFields $Monitor.native_resolution @('x', 'y',
        'aspect_ratio') "显示器 '$id' 的 native_resolution"
    if (-not (Test-VMatePolicyInteger $Monitor.native_resolution.x) -or
        -not (Test-VMatePolicyInteger $Monitor.native_resolution.y) -or
        [int]$Monitor.native_resolution.x -ne 1920 -or
        [int]$Monitor.native_resolution.y -ne 1080 -or
        [string]$Monitor.native_resolution.aspect_ratio -cne '16:9') {
        throw "显示器 '$id' 必须是 1920x1080、16:9 的 1K/FHD 模板。"
    }

    Assert-VMatePolicyFields $Monitor.serial_policy @('kind', 'length',
        'pattern', 'format_fidelity', 'reserved_values') `
        "显示器 '$id' 的 serial_policy"
    $policy = $Monitor.serial_policy
    $serialFacts = @([string]$policy.kind, [int]$policy.length,
        [string]$policy.pattern)
    $reserved = @($policy.reserved_values)
    $expectedReserved = @($contract.ReservedValues)
    if (-not (Test-VMatePolicyInteger $policy.length) -or
        ($serialFacts -join "`n") -cne (@($contract.Serial) -join "`n") -or
        [string]$policy.format_fidelity -cne
            [string]$contract.SerialFidelity -or
        [int]$policy.length -gt 13 -or
        $reserved.Count -ne $expectedReserved.Count -or
        @($reserved | Select-Object -Unique).Count -ne $reserved.Count -or
        @($reserved | Where-Object {
                $_ -isnot [string] -or
                ([string]$_).Length -ne [int]$policy.length -or
                [string]$_ -cnotmatch [string]$policy.pattern -or
                [string]$_ -cnotin $expectedReserved
            }).Count -gt 0) {
        throw "显示器 '$id' 的序列号策略无法编码为受控 EDID 字段。"
    }

    Assert-VMatePolicyFields $Monitor.binary_serial_policy @('kind',
        'fixed_value', 'format_fidelity') `
        "显示器 '$id' 的 binary_serial_policy"
    $binaryPolicy = $Monitor.binary_serial_policy
    $binaryFacts = @([string]$binaryPolicy.kind,
        $binaryPolicy.fixed_value, [string]$binaryPolicy.format_fidelity)
    if (($binaryFacts -join "`n") -cne
        (@($contract.BinarySerial) -join "`n") -or
        ([string]$binaryPolicy.kind -ceq 'fixed_u32' -and
            ($binaryPolicy.fixed_value -isnot [string] -or
                [string]$binaryPolicy.fixed_value -cnotmatch
                    '^0x[0-9A-F]{8}$')) -or
        ([string]$binaryPolicy.kind -cne 'fixed_u32' -and
            $null -ne $binaryPolicy.fixed_value)) {
        throw "显示器 '$id' 的 EDID binary serial 策略无效。"
    }

    Assert-VMatePolicyFields $Monitor.range @('min_vfreq_hz',
        'max_vfreq_hz', 'min_hfreq_khz', 'max_hfreq_khz',
        'max_pixel_clock_mhz') "显示器 '$id' 的 range"
    $range = @('min_vfreq_hz', 'max_vfreq_hz', 'min_hfreq_khz',
        'max_hfreq_khz', 'max_pixel_clock_mhz') | ForEach-Object {
        if (-not (Test-VMatePolicyInteger $Monitor.range.$_)) {
            throw "显示器 '$id' 的 range.$_ 必须是 JSON 整数。"
        }
        [int]$Monitor.range.$_
    }
    if (($range -join ':') -cne (@($contract.Range) -join ':')) {
        throw "显示器 '$id' 的扫描范围与型号规格不一致。"
    }
    $timingFields = @('xres', 'yres', 'refresh_millihz',
        'pixel_clock_khz', 'hfront', 'hsync', 'hblank', 'vfront', 'vsync',
        'vblank', 'hsync_positive', 'vsync_positive', 'width_mm', 'height_mm')
    $timingIntegerFields = @('xres', 'yres', 'refresh_millihz',
        'pixel_clock_khz', 'hfront', 'hsync', 'hblank', 'vfront', 'vsync',
        'vblank', 'width_mm', 'height_mm')
    $timingBooleanFields = @('hsync_positive', 'vsync_positive')
    Assert-VMatePolicyFields $Monitor.secondary_timing $timingFields `
        "显示器 '$id' 的 secondary_timing"
    $timing = $Monitor.secondary_timing
    if (@($timingIntegerFields | Where-Object {
                -not (Test-VMatePolicyInteger $timing.$_)
            }).Count -gt 0 -or
        @($timingBooleanFields | Where-Object {
                $timing.$_ -isnot [bool]
            }).Count -gt 0 -or
        (@($timingFields | ForEach-Object { $timing.$_ }) -join ':') -cne
            (@($contract.Timing) -join ':') -or
        [string]$Monitor.evidence -cne [string]$contract.Evidence -or
        [string]$Monitor.identity_fidelity -cne
            'audited_raw_identity_timing_fields_synthetic_edid') {
        throw "显示器 '$id' 的次要时序或 EDID 证据边界无效。"
    }
    Assert-VMatePolicySources $Monitor.source_refs $contract.Hosts `
        "显示器 '$id' 的官方来源"
    Assert-VMatePolicySources $Monitor.identity_source_refs `
        $contract.IdentityHosts "显示器 '$id' 的实机 EDID 来源"
}

function Assert-VMateMonitorTimingSelectorSet {
    param([object[]]$Monitors)

    # 当前 QEMU 运行时以 x/y/refresh 三元组选择审核过的完整 DTD。多个型号
    # 可以共享选择器，但只能共享完全相同的 clock/porch/blank/polarity/size；
    # 否则启动参数无法无歧义表达目录事实。
    $selectors = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::Ordinal)
    $detailFields = @('pixel_clock_khz', 'hfront', 'hsync', 'hblank',
        'vfront', 'vsync', 'vblank', 'hsync_positive', 'vsync_positive',
        'width_mm', 'height_mm')
    foreach ($monitor in $Monitors) {
        $timing = $monitor.secondary_timing
        $selector = @(
            [string]$timing.xres,
            [string]$timing.yres,
            [string]$timing.refresh_millihz
        ) -join ':'
        $detail = @($detailFields | ForEach-Object {
                [string]$timing.$_
            }) -join ':'
        $priorDetail = $null
        if ($selectors.TryGetValue($selector, [ref]$priorDetail)) {
            if ($priorDetail -cne $detail) {
                throw "显示器 '$($monitor.id)' 的次要 DTD 选择器 '$selector' " +
                    '与另一型号冲突。'
            }
        } else {
            $selectors.Add($selector, $detail)
        }
    }
}

function New-VMatePolicyRandomText {
    param(
        [int]$Length,
        [string]$Alphabet
    )

    if ($Length -lt 1 -or -not $Alphabet) {
        throw '随机字符串长度和字符表必须有效。'
    }
    $output = [System.Text.StringBuilder]::new($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = New-Object byte[] 1
        $limit = 256 - (256 % $Alphabet.Length)
        while ($output.Length -lt $Length) {
            $rng.GetBytes($buffer)
            if ([int]$buffer[0] -lt $limit) {
                [void]$output.Append($Alphabet[[int]$buffer[0] %
                            $Alphabet.Length])
            }
        }
    } finally {
        $rng.Dispose()
    }
    return $output.ToString()
}

function Assert-VMateMonitorSerial {
    param(
        [object]$Monitor,
        [string]$Serial
    )

    $policy = $Monitor.serial_policy
    if ($Serial -isnot [string] -or
        $Serial.Length -ne [int]$policy.length -or
        $Serial -cnotmatch [string]$policy.pattern -or
        $Serial -cin @($policy.reserved_values)) {
        throw "显示器 '$($Monitor.id)' 的序列号不符合目录策略。"
    }
    if ([string]$Monitor.binary_serial_policy.kind -ceq 'decimal_suffix6' -and
        $Serial.Substring($Serial.Length - 6, 6) -ceq '000000') {
        throw "显示器 '$($Monitor.id)' 的序列号映射到保留的 binary serial 0。"
    }
}

function Get-VMateMonitorBinarySerial {
    param(
        [object]$Monitor,
        [string]$Serial
    )

    Assert-VMateMonitorSerial $Monitor $Serial
    $policy = $Monitor.binary_serial_policy
    [uint32]$value = 0
    switch ([string]$policy.kind) {
        'fixed_u32' {
            $value = [Convert]::ToUInt32(
                ([string]$policy.fixed_value).Substring(2), 16)
        }
        'decimal_suffix6' {
            if (-not [uint32]::TryParse(
                    $Serial.Substring($Serial.Length - 6, 6),
                    [ref]$value)) {
                throw "显示器 '$($Monitor.id)' 的十进制 binary serial 无效。"
            }
        }
        default {
            throw "显示器 '$($Monitor.id)' 的 binary serial 策略未知。"
        }
    }
    if ($value -eq 0) {
        throw "显示器 '$($Monitor.id)' 的 binary serial 不能为 0。"
    }
    return ('0x{0:X8}' -f $value)
}

function New-VMateMonitorSerial {
    param([object]$Monitor)

    $policy = $Monitor.serial_policy
    do {
        $serial = switch ([string]$policy.kind) {
            'samsung_h4zmc_decimal5' {
                'H4ZMC' + (New-VMatePolicyRandomText 5 '0123456789')
            }
            'aoc_upper_alnum7_decimal6' {
                (New-VMatePolicyRandomText 4 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') +
                    (New-VMatePolicyRandomText 1 '0123456789') +
                    (New-VMatePolicyRandomText 1 `
                        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ') + 'A' +
                    (New-VMatePolicyRandomText 6 '0123456789')
            }
            'xiaomi_29200_label_slash_removed_decimal' {
                '29200' + (New-VMatePolicyRandomText 8 '0123456789')
            }
            'lenovo_urb_upper_alnum' {
                'URB' + (New-VMatePolicyRandomText 5 `
                    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ')
            }
            default {
                throw "未知显示器序列号策略：$($policy.kind)"
            }
        }
        $mustRedraw = $serial -cin @($policy.reserved_values)
        if (-not $mustRedraw -and
            [string]$Monitor.binary_serial_policy.kind -ceq
                'decimal_suffix6' -and
            $serial.Substring($serial.Length - 6, 6) -ceq '000000') {
            $mustRedraw = $true
        }
    } while ($mustRedraw)
    Assert-VMateMonitorSerial $Monitor $serial
    return $serial
}
