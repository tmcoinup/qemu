#Requires -Version 5.1

<#
.SYNOPSIS
    加载 Windows/Linux 共用的可更换硬件部件目录。

.DESCRIPTION
    根清单引用独立 SSD/AIB 子目录；加载时校验全部原子身份，再按权重选择
    存储、AIB GPU 和显示器。profile 绑定所选条目的 ID 与摘要，目录修订变化
    不会改变既有 VM；条目自身变化仍会 fail closed。旧通用 GPU 仅供回读。
#>

. (Join-Path $PSScriptRoot 'VMate.ComponentPolicy.ps1')
. (Join-Path $PSScriptRoot 'VMate.StoragePolicy.ps1')
. (Join-Path $PSScriptRoot 'VMate.ComponentRuntime.ps1')
. (Join-Path $PSScriptRoot 'VMate.Gpu.ps1')
. (Join-Path $PSScriptRoot 'VMate.Json.ps1')

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

function Test-VMateComponentInteger {
    param([object]$Value)

    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Get-VMateComponentDigest {
    param([object]$Catalog)

    $json = $Catalog | ConvertTo-Json -Depth 64 -Compress
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $digest = $sha256.ComputeHash($bytes)
        return ([BitConverter]::ToString($digest)).Replace('-', '').
            ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Assert-VMateHidComponent {
    param(
        [object]$Hid,
        [string]$Kind,
        [string]$ExpectedVendor,
        [string]$ExpectedProduct,
        [string]$ExpectedBcd,
        [string]$ExpectedId,
        [string]$ExpectedName
    )

    Assert-VMatePolicyFields $Hid @('id', 'enabled', 'vendor_id',
        'product_id', 'bcd_device', 'manufacturer', 'product',
        'serial_exposed', 'verification_status', 'descriptor_fidelity') `
        "HID 部件 '$Kind/$($Hid.id)'"
    if ($Hid.enabled -isnot [bool] -or
        [string]$Hid.id -cne $ExpectedId -or
        [string]$Hid.vendor_id -cne $ExpectedVendor -or
        [string]$Hid.product_id -cne $ExpectedProduct -or
        [string]$Hid.bcd_device -cne $ExpectedBcd -or
        [string]$Hid.manufacturer -cne 'Microsoft' -or
        [string]$Hid.product -cne $ExpectedName -or
        $Hid.serial_exposed -ne $false -or
        [string]$Hid.verification_status -cne
            'unverified_catalog_identity' -or
        [string]$Hid.descriptor_fidelity -cne
            'identity_only_generic_report') {
        throw "HID 部件 '$Kind/$($Hid.id)' 与 patched descriptor 不一致。"
    }
}

function Assert-VMateTabletComponent {
    param([object]$Tablet)

    Assert-VMatePolicyFields $Tablet @('id', 'enabled', 'vendor_id',
        'product_id', 'bcd_device', 'manufacturer', 'product',
        'serial_exposed', 'verification_status', 'descriptor_fidelity') `
        "tablet '$($Tablet.id)'"
    if ($Tablet.enabled -isnot [bool] -or
        [string]$Tablet.id -cne 'qemu-generic-usb-tablet' -or
        [string]$Tablet.vendor_id -cne '0x0627' -or
        [string]$Tablet.product_id -cne '0x0001' -or
        [string]$Tablet.bcd_device -cne '0x0000' -or
        [string]$Tablet.manufacturer -cne 'not_exposed' -or
        [string]$Tablet.product -cne 'QEMU USB Tablet' -or
        $Tablet.serial_exposed -ne $false -or
        [string]$Tablet.verification_status -cne
            'qemu_native_virtual_device' -or
        [string]$Tablet.descriptor_fidelity -cne 'generic_virtual_only') {
        throw '通用 tablet 目录与 QEMU 原生设备不一致。'
    }
}

function Get-VMateValidatedComponentItems {
    param(
        [object[]]$Items,
        [string]$Kind,
        [scriptblock]$Validator
    )

    if ($Items.Count -lt 1) {
        throw "部件目录 '$Kind' 不能为空。"
    }
    $ids = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($item in $Items) {
        if (-not (Test-VMateComponentProperty $item 'id') -or
            $item.id -isnot [string] -or
            [string]$item.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
            -not $ids.Add([string]$item.id)) {
            throw "部件目录 '$Kind' 含空、重复或非法 ID。"
        }
        & $Validator $item
    }
    $enabled = @($Items | Where-Object { $_.enabled -eq $true })
    if ($enabled.Count -lt 1) {
        throw "部件目录 '$Kind' 至少要启用一个已核验模板。"
    }
    return $enabled
}

function Assert-VMateMonitorCatalogSet {
    param([object[]]$Items)

    $expectedIds = @(
        'samsung-s24f350',
        'aoc-24b2xh',
        'xiaomi-rmmnt238nf',
        'lenovo-l24e-30'
    )
    $actualIds = @($Items | ForEach-Object { [string]$_.id } | Sort-Object)
    if ($Items.Count -ne $expectedIds.Count -or
        ($actualIds -join "`n") -cne
            (@($expectedIds | Sort-Object) -join "`n") -or
        @($Items | Where-Object {
                $_.enabled -isnot [bool] -or $_.enabled -ne $true
            }).Count -ne 0) {
        throw '显示器目录必须精确包含且启用四款受控 1080p/16:9 型号。'
    }
}

function Get-VMateWeightedComponent {
    param(
        [object[]]$Items,
        [string]$Kind
    )

    if ($Items.Count -eq 1) {
        return $Items[0]
    }
    [uint64]$total = 0
    foreach ($item in $Items) {
        if (-not (Test-VMateComponentProperty $item 'selection_weight') -or
            -not (Test-VMateComponentInteger $item.selection_weight) -or
            [int]$item.selection_weight -lt 1) {
            throw "部件目录 '$Kind/$($item.id)' 缺少正整数 selection_weight。"
        }
        $total += [uint64]$item.selection_weight
    }
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 8
        $remainder = ([uint64]::MaxValue % $total + 1) % $total
        $limit = [uint64]::MaxValue - $remainder
        do {
            $rng.GetBytes($bytes)
            $sample = [BitConverter]::ToUInt64($bytes, 0)
        } while ($sample -gt $limit)
    } finally {
        $rng.Dispose()
    }
    [uint64]$target = $sample % $total
    [uint64]$cursor = 0
    foreach ($item in $Items) {
        $cursor += [uint64]$item.selection_weight
        if ($target -lt $cursor) {
            return $item
        }
    }
    throw "部件目录 '$Kind' 的加权选择状态无效。"
}

function Get-VMateComponentById {
    param(
        [object[]]$Items,
        [string]$Id,
        [string]$Kind
    )

    if (-not $Id) {
        throw "硬件 profile 缺少 $Kind ID。"
    }
    $matched = @($Items | Where-Object { [string]$_.id -ceq $Id })
    if ($matched.Count -ne 1) {
        throw "硬件 profile 所选 $Kind '$Id' 未在启用目录中找到。"
    }
    return $matched[0]
}

function Read-VMateComponentJson {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到$Label：$Path"
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        Assert-VMateJsonNoDuplicateProperties -Json $json -Label $Label
        return ConvertFrom-Json -InputObject $json -ErrorAction Stop
    } catch {
        throw "$Label 不是有效 JSON：$Path；$($_.Exception.Message)"
    }
}

function Resolve-VMateComponentCatalogPath {
    param(
        [string]$RootPath,
        [object]$Reference,
        [string]$Label
    )

    if ($Reference -isnot [string] -or
        [string]$Reference -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$' -or
        [IO.Path]::GetFileName([string]$Reference) -cne [string]$Reference) {
        throw "$Label 必须是与根清单同目录的 JSON 文件名。"
    }
    $directory = [IO.Path]::GetDirectoryName(
        [IO.Path]::GetFullPath($RootPath))
    return [IO.Path]::Combine($directory, [string]$Reference)
}

function Assert-VMateChildCatalogHeader {
    param(
        [object]$Document,
        [string]$Revision,
        [string]$Scope,
        [string]$ItemsField,
        [string]$Label
    )

    Assert-VMatePolicyFields $Document @('schema_version',
        'catalog_revision', 'scope', $ItemsField) $Label
    if (-not (Test-VMateComponentInteger $Document.schema_version) -or
        [int]$Document.schema_version -ne 1 -or
        [string]$Document.catalog_revision -cne $Revision -or
        [string]$Document.scope -cne $Scope -or
        $Document.$ItemsField -isnot [System.Array]) {
        throw "$Label 的版本、修订、范围或条目数组无效。"
    }
}

function Read-VMateComponentManifest {
    param([string]$Path)

    $root = Read-VMateComponentJson $Path '共享部件目录'
    Assert-VMatePolicyFields $root @('schema_version', 'catalog_revision',
        'scope', 'storage_catalog', 'gpu_board_catalog', 'gpus', 'monitors',
        'hid') '部件目录根对象'
    if (-not (Test-VMateComponentInteger $root.schema_version) -or
        [int]$root.schema_version -ne 1 -or
        $root.catalog_revision -isnot [string] -or
        [string]$root.catalog_revision -notmatch '^\d{4}-\d{2}-\d{2}\.\d+$') {
        throw '部件目录只支持 schema_version=1 和日期格式 catalog_revision。'
    }
    Assert-VMatePolicyFields $root.scope @('gpu', 'tablet') '部件目录 scope'
    if ([string]$root.scope.gpu -cne 'out_of_scope_virtual_display' -or
        [string]$root.scope.tablet -cne
            'generic_virtual_absolute_pointer') {
        throw '部件目录 scope 与当前无 GPU 直通分支不一致。'
    }
    Assert-VMatePolicyFields $root.hid @('keyboards', 'mice', 'tablets') `
        '部件目录 hid'

    $storagePath = Resolve-VMateComponentCatalogPath $Path `
        $root.storage_catalog 'storage_catalog'
    $gpuBoardPath = Resolve-VMateComponentCatalogPath $Path `
        $root.gpu_board_catalog 'gpu_board_catalog'
    $storageDocument = Read-VMateComponentJson $storagePath 'SSD 子目录'
    $gpuBoardDocument = Read-VMateComponentJson $gpuBoardPath 'AIB GPU 子目录'
    Assert-VMateChildCatalogHeader $storageDocument `
        ([string]$root.catalog_revision) 'verified_exact_512gb_nvme_only' `
        'storage' 'SSD 子目录'
    Assert-VMateChildCatalogHeader $gpuBoardDocument `
        ([string]$root.catalog_revision) `
        'shallow_user_projection_no_gpu_passthrough' 'boards' 'AIB GPU 子目录'

    $storages = @(Get-VMateValidatedComponentItems `
            @($storageDocument.storage) `
            'storage' { param($item) Assert-VMateStorageComponent $item })
    $legacyGpus = @(Get-VMateValidatedComponentItems @($root.gpus) `
            'gpus' { param($item) Assert-VMateGpuComponent $item })
    $gpus = @(Get-VMateValidatedComponentItems @($gpuBoardDocument.boards) `
            'gpu boards' { param($item) Assert-VMateGpuBoardComponent $item })
    Assert-VMateGpuBoardCatalogContract $gpus 18 3
    Assert-VMateMonitorCatalogSet @($root.monitors)
    $monitors = @(Get-VMateValidatedComponentItems @($root.monitors) `
            'monitors' { param($item) Assert-VMateMonitorComponent $item })
    Assert-VMateMonitorTimingSelectorSet $monitors
    $keyboards = @(Get-VMateValidatedComponentItems @($root.hid.keyboards) `
            'keyboards' { param($item)
                Assert-VMateHidComponent $item 'keyboards' '0x045E' '0x0750' `
                    '0x0163' 'microsoft-wired-keyboard-600' `
                    'Microsoft Wired Keyboard 600'
            })
    $mice = @(Get-VMateValidatedComponentItems @($root.hid.mice) 'mice' {
            param($item)
            Assert-VMateHidComponent $item 'mice' '0x045E' '0x00CB' `
                '0x0163' 'microsoft-usb-optical-mouse' `
                'Microsoft USB Optical Mouse'
        })
    $tablets = @(Get-VMateValidatedComponentItems @($root.hid.tablets) `
            'tablets' { param($item) Assert-VMateTabletComponent $item })
    if ($keyboards.Count -ne 1 -or $mice.Count -ne 1 -or
        $tablets.Count -ne 1) {
        throw '当前 HID 行为层要求键盘、鼠标和 tablet 各启用一个模板。'
    }
    if ($storages.Count -ne 4 -or
        @($storages | Where-Object {
                [int64]$_.raw_bytes -ne 512110190592L
            }).Count -ne 0) {
        throw '当前产品契约要求四款精确 512GB SSD 和十八款已审计 AIB GPU。'
    }
    $profileGpuIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($gpu in @($gpus) + @($legacyGpus)) {
        if (-not $profileGpuIds.Add([string]$gpu.id)) {
            throw "AIB 与旧 GPU 目录存在重复 ID：$($gpu.id)"
        }
    }
    $carrierIds = @($gpus | ForEach-Object {
            ([string]$_.carrier_vendor).ToUpperInvariant() + ':' +
                ([string]$_.carrier_device).ToUpperInvariant()
        })
    if (@($carrierIds | Select-Object -Unique).Count -ne $carrierIds.Count) {
        throw 'AIB GPU 目录包含重复的 virtio 载体编号。'
    }
    $catalog = [pscustomobject]@{
        schema_version = [int]$root.schema_version
        catalog_revision = [string]$root.catalog_revision
        catalog_digest = Get-VMateComponentDigest ([ordered]@{
                root = $root
                storage = $storageDocument
                gpu_boards = $gpuBoardDocument
            })
        storage_items = $storages
        gpu_items = $gpus
        legacy_gpu_items = $legacyGpus
        gpu_profile_items = @($gpus) + @($legacyGpus)
        monitor_items = $monitors
        keyboard_items = $keyboards
        mouse_items = $mice
        tablet_items = $tablets
    }
    return New-VMateResolvedComponents $catalog `
        (Get-VMateWeightedComponent $storages '512G storage') `
        (Get-VMateWeightedComponent $monitors 'monitors') `
        $keyboards[0] $mice[0] $tablets[0] `
        (Get-VMateWeightedComponent $gpus 'gpus')
}

function Get-VMateStorageCapacityCandidates {
    param(
        [object[]]$Items,
        [int64]$CapacityBytes
    )

    if ($CapacityBytes -lt 1) {
        throw '磁盘 virtual-size 必须是正整数。'
    }
    $matched = @($Items | Where-Object {
            [int64]$_.raw_bytes -eq $CapacityBytes
        })
    if ($matched.Count -lt 1) {
        throw "启用的存储部件中没有 raw_bytes=$CapacityBytes 的精确匹配项。"
    }
    return $matched
}


. (Join-Path $PSScriptRoot 'VMate.ComponentSelection.ps1')
