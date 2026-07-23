#Requires -Version 5.1

<#
.SYNOPSIS
    对 Windows SSD 与显示器目录的型号级精确契约执行故障注入。
#>

function Invoke-VMateComponentPolicyExactTests {
    param([object]$Catalog)

    $storageFacts = [ordered]@{
        'samsung-970-pro-512gb' = @(6, 2018)
        'intel-760p-512gb' = @(5, 2018)
        'wd-pc-sn730-512gb' = @(6, 2019)
        'kioxia-xg6-512gb' = @(4, 2018)
    }
    foreach ($storage in $Catalog.storage_items) {
        $id = [string]$storage.id
        $expected = $storageFacts[$id]
        if ($null -eq $expected -or $storage.enabled -ne $true -or
            [int]$storage.selection_weight -ne [int]$expected[0] -or
            [int]$storage.release_year -ne [int]$expected[1]) {
            throw "SSD '$id' 的启用状态、权重或发售年份未精确锁定。"
        }
        foreach ($field in @('enabled', 'selection_weight', 'release_year')) {
            $bad = $storage | ConvertTo-Json -Depth 32 | ConvertFrom-Json
            if ($field -ceq 'enabled') {
                $bad.enabled = $false
            } else {
                $bad.$field = [int]$bad.$field + 1
            }
            Assert-Throws {
                Assert-VMateStorageComponent $bad
            } "SSD '$id' 的 $field 篡改没有 fail closed。"
        }
    }

    $badId = $Catalog.storage_items[0] |
        ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $badId.id = ([string]$badId.id).ToUpperInvariant()
    $badId.identity_profile = ([string]$badId.identity_profile).ToUpperInvariant()
    Assert-Throws {
        Assert-VMateStorageComponent $badId
    } 'SSD 稳定 ID 大小写篡改没有 fail closed。'

    $retiredIdentityHosts = [ordered]@{
        'samsung-970-pro-512gb' = 'forums.developer.nvidia.com'
        'intel-760p-512gb' = 'cdrdv2-public.intel.com'
        'wd-pc-sn730-512gb' = 'forum.level1techs.com'
        'kioxia-xg6-512gb' = 'raw.githubusercontent.com'
    }
    foreach ($storage in $Catalog.storage_items) {
        $id = [string]$storage.id
        $bad = $storage | ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $bad.identity_source_refs[0] =
            "https://$($retiredIdentityHosts[$id])/identity-sample"
        Assert-Throws {
            Assert-VMateStorageComponent $bad
        } "SSD '$id' 接受了 storage_catalog.py 之外的身份来源域名。"
    }

    $reservedFacts = [ordered]@{
        'samsung-s24f350' = @('H4ZMC01676', 'H4ZMC01889')
        'aoc-24b2xh' = @('UOWN9HA005249', 'AWDM61A005357',
            'RSKN61A000560')
        'xiaomi-rmmnt238nf' = @('2920000167575', '2920000116680')
        'lenovo-l24e-30' = @('URB5DT6H', 'URB4N2F4', 'URB644NY')
    }
    $reservedFaults = [ordered]@{
        'samsung-s24f350' = 'H4ZMC99999'
        'aoc-24b2xh' = 'ZZZZ9ZA999999'
        'xiaomi-rmmnt238nf' = '2920099999999'
        'lenovo-l24e-30' = 'URBZZZZZ'
    }
    $timingFields = @('xres', 'yres', 'refresh_millihz',
        'pixel_clock_khz', 'hfront', 'hsync', 'hblank', 'vfront', 'vsync',
        'vblank', 'hsync_positive', 'vsync_positive', 'width_mm', 'height_mm')
    $timingFacts = [ordered]@{
        'samsung-s24f350' = @(1280, 720, 50000, 74250, 440, 40, 700,
            5, 5, 30, $true, $true, 521, 293)
        'aoc-24b2xh' = @(1920, 1080, 74973, 174500, 48, 32, 160,
            3, 5, 39, $true, $false, 527, 296)
        'xiaomi-rmmnt238nf' = @(1920, 1080, 75002, 185630, 48, 40, 280,
            5, 5, 45, $true, $true, 160, 90)
        'lenovo-l24e-30' = @(1920, 1080, 74973, 174500, 48, 32, 160,
            3, 5, 39, $true, $false, 527, 296)
    }
    foreach ($monitor in $Catalog.monitor_items) {
        $id = [string]$monitor.id
        $actualReserved = @($monitor.serial_policy.reserved_values |
            Sort-Object -CaseSensitive)
        $expectedReserved = @($reservedFacts[$id] | Sort-Object -CaseSensitive)
        if (($actualReserved -join "`n") -cne
            ($expectedReserved -join "`n")) {
            throw "显示器 '$id' 的证据样本保留序列集合未精确锁定。"
        }
        $badReserved = $monitor |
            ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $badReserved.serial_policy.reserved_values[0] = $reservedFaults[$id]
        Assert-Throws {
            Assert-VMateMonitorComponent $badReserved
        } "显示器 '$id' 接受了未核验的保留序列样本。"

        $expectedTiming = $timingFacts[$id]
        for ($index = 0; $index -lt $timingFields.Count; $index++) {
            $field = $timingFields[$index]
            if ($monitor.secondary_timing.$field -ne $expectedTiming[$index]) {
                throw "显示器 '$id' 的 secondary_timing.$field 未精确锁定。"
            }
            $badTiming = $monitor |
                ConvertTo-Json -Depth 32 | ConvertFrom-Json
            if ($expectedTiming[$index] -is [bool]) {
                $badTiming.secondary_timing.$field = -not $expectedTiming[$index]
            } else {
                $badTiming.secondary_timing.$field =
                    [int]$expectedTiming[$index] + 1
            }
            Assert-Throws {
                Assert-VMateMonitorComponent $badTiming
            } "显示器 '$id' 的 secondary_timing.$field 篡改没有 fail closed。"
        }
    }

    $selectorCollision = @($Catalog.monitor_items | ForEach-Object {
            $_ | ConvertTo-Json -Depth 32 | ConvertFrom-Json
        })
    $aocTiming = @($selectorCollision | Where-Object {
            [string]$_.id -ceq 'aoc-24b2xh'
        })[0].secondary_timing
    $xiaomiTiming = @($selectorCollision | Where-Object {
            [string]$_.id -ceq 'xiaomi-rmmnt238nf'
        })[0].secondary_timing
    $xiaomiTiming.xres = $aocTiming.xres
    $xiaomiTiming.yres = $aocTiming.yres
    $xiaomiTiming.refresh_millihz = $aocTiming.refresh_millihz
    Assert-Throws {
        Assert-VMateMonitorTimingSelectorSet $selectorCollision
    } '不同 DTD 细节复用同一个 x/y/refresh 选择器时没有 fail closed。'
}
