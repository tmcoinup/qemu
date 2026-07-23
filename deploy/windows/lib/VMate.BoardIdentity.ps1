#Requires -Version 5.1

<#
.SYNOPSIS
    按共享厂商策略生成并校验主板序列号。

.DESCRIPTION
    序列号只复用厂商公开标签的结构，不复制真实设备值。主板厂商、PCI
    subsystem vendor、生成器和格式必须同时命中同一 vendor 条目。
#>

function Get-VMateBoardVendorPolicy {
    param([object]$Platform)

    $catalogPath = Join-Path $PSScriptRoot '../../hardware/board-vendors.json'
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        throw "找不到主板厂商策略：$catalogPath"
    }
    try {
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "主板厂商策略不是有效 JSON：$($_.Exception.Message)"
    }
    if ([int]$catalog.schema_version -ne 1 -or
        [string]$catalog.catalog_revision -notmatch
            '^\d{4}-\d{2}-\d{2}\.\d+$') {
        throw '主板厂商策略 schema/revision 无效。'
    }
    if ([string]$Platform.board.manufacturer -ceq 'QEMU' -and
        [string]$Platform.board.serial_fn -ceq '_serial_qemu' -and
        [string]$Platform.board.subsystem_vendor -ceq '0x1B36') {
        # host compatibility 明确声明为通用虚拟模板，不冒充任何物理品牌。
        return [pscustomobject]@{
            Key = 'qemu-generic'
            Regex = '^MB[0-9]{12}$'
        }
    }

    $contracts = @{
        '0x1043' = @('asus', 'ASUSTeK COMPUTER INC.', '_serial_asus',
            '^[A-Z0-9]{2}S[A-Z0-9]{9}$', 'asus_12_char_third_s')
        '0x1462' = @('msi', 'Micro-Star International Co., Ltd.',
            '_serial_msi', '^601-[A-Z0-9]{4}-[A-Z0-9]{14}$',
            'msi_601_board_code_14_suffix')
        '0x1458' = @('gigabyte', 'Gigabyte Technology Co., Ltd.',
            '_serial_giga', '^SN[0-9]{12}$',
            'gigabyte_sn_yyww_8_digits')
        '0x1849' = @('asrock', 'ASRock', '_serial_asr',
            '^[A-Z0-9]{12}$', 'asrock_12_char_uppercase_label')
    }
    $expected = $contracts[[string]$Platform.board.subsystem_vendor]
    if ($null -eq $expected) {
        throw "主板 '$($Platform.board.product)' 的 subsystem vendor 未注册。"
    }
    $policy = $catalog.vendors.($expected[0])
    if ($null -eq $policy -or
        [string]$policy.manufacturer -cne $expected[1] -or
        [string]$policy.serial_fn -cne $expected[2] -or
        [string]$policy.subsystem_vendor -cne
            [string]$Platform.board.subsystem_vendor -or
        [string]$policy.serial_policy.regex -cne $expected[3] -or
        [string]$policy.serial_policy.generator_contract -cne $expected[4] -or
        [string]$Platform.board.manufacturer -cne $expected[1] -or
        [string]$Platform.board.serial_fn -cne $expected[2]) {
        throw "主板 '$($Platform.board.product)' 的厂商原子身份与共享策略不一致。"
    }
    return [pscustomobject]@{
        Key = $expected[0]
        Regex = [string]$policy.serial_policy.regex
    }
}

function New-VMateBoardRandomText {
    param(
        [int]$Length,
        [string]$Alphabet
    )

    $builder = [System.Text.StringBuilder]::new($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = New-Object byte[] 1
        $limit = 256 - (256 % $Alphabet.Length)
        while ($builder.Length -lt $Length) {
            $rng.GetBytes($buffer)
            if ([int]$buffer[0] -lt $limit) {
                [void]$builder.Append(
                    $Alphabet[[int]$buffer[0] % $Alphabet.Length])
            }
        }
    } finally {
        $rng.Dispose()
    }
    return $builder.ToString()
}

function Assert-VMateBoardSerial {
    param(
        [object]$Platform,
        [string]$Serial,
        [bool]$AllowLegacyAsusProfile = $false
    )

    $policy = Get-VMateBoardVendorPolicy -Platform $Platform
    if ($AllowLegacyAsusProfile -and $policy.Key -eq 'asus' -and
        $Serial -cmatch '^MB[0-9]{12}$') {
        if ($Serial.Substring(2) -match '^0+$') {
            throw '旧版 ASUS 主板序列号不能使用全零占位值。'
        }
        return
    }
    if ($Serial -isnot [string] -or $Serial -cnotmatch $policy.Regex) {
        throw "主板 '$($Platform.board.product)' 的序列号不符合厂商规格。"
    }
    if ($policy.Key -eq 'msi') {
        $boardCode = ([string]$Platform.board.subsystem_device).
            Replace('0x', '').ToUpperInvariant()
        if (-not $Serial.StartsWith("601-$boardCode-",
                [StringComparison]::Ordinal)) {
            throw 'MSI 主板序列号没有绑定当前 MS board code。'
        }
    } elseif ($policy.Key -eq 'gigabyte') {
        $year = ([int]$Platform.release_year % 100).ToString('00')
        $week = [int]$Serial.Substring(4, 2)
        if ($Serial.Substring(2, 2) -cne $year -or
            $week -lt 1 -or $week -gt 53) {
            throw 'GIGABYTE 主板序列号的 YYWW 日期码无效。'
        }
    } elseif ($policy.Key -eq 'qemu-generic' -and
        $Serial.Substring(2) -match '^0+$') {
        throw '通用 Q35 主板序列号不能使用占位值。'
    }
    $payload = $Serial -replace '^(?:601-)?', '' -replace '[-SN]', ''
    if ($payload -match '^(?:0+|F+)$') {
        throw '主板序列号不能使用全零或全 F 占位值。'
    }
}

function New-VMateBoardSerial {
    param([object]$Platform)

    $policy = Get-VMateBoardVendorPolicy -Platform $Platform
    $alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $serial = switch ($policy.Key) {
        'asus' {
            (New-VMateBoardRandomText 2 $alpha) + 'S' +
                (New-VMateBoardRandomText 9 $alpha)
        }
        'msi' {
            $code = ([string]$Platform.board.subsystem_device).
                Replace('0x', '').ToUpperInvariant()
            '601-' + $code + '-' + (New-VMateBoardRandomText 14 $alpha)
        }
        'gigabyte' {
            $year = ([int]$Platform.release_year % 100).ToString('00')
            $week = (1 + (Get-VMateSecureIndex -Count 53)).ToString('00')
            'SN' + $year + $week + (New-VMateBoardRandomText 8 '0123456789')
        }
        'asrock' { New-VMateBoardRandomText 12 $alpha }
        'qemu-generic' {
            'MB' + (New-VMateBoardRandomText 12 '0123456789')
        }
        default { throw "未知主板序列号策略：$($policy.Key)" }
    }
    Assert-VMateBoardSerial -Platform $Platform -Serial $serial
    return $serial
}
