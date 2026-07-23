#Requires -Version 5.1

<#
.SYNOPSIS
    解析可更换部件的随机/显式选择并维护稳定 profile 绑定。

.DESCRIPTION
    空 ID 使用启用目录的原有加权随机；非空 ID 必须在启用源头目录中大小写
    精确且唯一。既有 profile 始终先恢复持久绑定，再断言显式请求一致，绝不
    因本次参数重新抽取。存储目录只含 512110190592 bytes 产品；新 GPU 绑定
    只从 AIB 板卡池选择，历史通用标签仅用于旧 V3 profile 回读。
#>

function New-VMateResolvedComponents {
    param(
        [object]$Catalog,
        [object]$Storage,
        [object]$Monitor,
        [object]$Keyboard,
        [object]$Mouse,
        [object]$Tablet,
        [object]$Gpu = $null
    )

    if (-not $PSBoundParameters.ContainsKey('Gpu') -and
        (Test-VMateComponentProperty $Catalog 'gpu')) {
        # 保留既有六参数调用 ABI：测试/内部调用未显式传 GPU 时，沿用目录已经
        # 选出的标签。恢复 V1/V2 profile 的调用会显式传入 $null，仍保持未绑定。
        $Gpu = $Catalog.gpu
    }
    return [pscustomobject]@{
        schema_version = [int]$Catalog.schema_version
        catalog_revision = [string]$Catalog.catalog_revision
        catalog_digest = [string]$Catalog.catalog_digest
        storage_items = @($Catalog.storage_items)
        monitor_items = @($Catalog.monitor_items)
        gpu_items = @($Catalog.gpu_items)
        legacy_gpu_items = @($Catalog.legacy_gpu_items)
        gpu_profile_items = @($Catalog.gpu_profile_items)
        keyboard_items = @($Catalog.keyboard_items)
        mouse_items = @($Catalog.mouse_items)
        tablet_items = @($Catalog.tablet_items)
        storage = $Storage
        monitor = $Monitor
        gpu = $Gpu
        keyboard = $Keyboard
        mouse = $Mouse
        tablet = $Tablet
    }
}

function Resolve-VMateComponentSelection {
    param(
        [object]$Catalog,
        [object]$Binding
    )

    foreach ($field in @('storage_id', 'monitor_id', 'keyboard_id',
            'mouse_id')) {
        if (-not (Test-VMateComponentProperty $Binding $field) -or
            $Binding.$field -isnot [string]) {
            throw "硬件 profile 的部件绑定缺少 '$field'。"
        }
    }
    $tabletId = if (Test-VMateComponentProperty $Binding 'tablet_id') {
        [string]$Binding.tablet_id
    } else {
        'qemu-generic-usb-tablet'
    }
    $isV3 = (Test-VMateComponentProperty $Binding 'binding_version') -and
        (Test-VMateComponentInteger $Binding.binding_version) -and
        [int]$Binding.binding_version -eq 3
    $gpu = if ($isV3) {
        if (-not (Test-VMateComponentProperty $Binding 'gpu_id') -or
            $Binding.gpu_id -isnot [string]) {
            throw 'V3 硬件 profile 的部件绑定缺少 gpu_id。'
        }
        $profileGpuItems = if (Test-VMateComponentProperty `
                $Catalog 'gpu_profile_items') {
            @($Catalog.gpu_profile_items)
        } else {
            @($Catalog.gpu_items)
        }
        Get-VMateComponentById $profileGpuItems `
            ([string]$Binding.gpu_id) 'GPU'
    } else {
        # V1/V2 profile 生成时没有 GPU 标签。保持“未绑定”语义，不能在普通
        # 重启时偷偷抽取新标签；用户可显式 reroll 后升级到 V3。
        $null
    }
    $productStorages = @(Get-VMateStorageCapacityCandidates `
            $Catalog.storage_items 512110190592)
    $resolved = New-VMateResolvedComponents $Catalog `
        (Get-VMateComponentById $productStorages `
            ([string]$Binding.storage_id) 'storage') `
        (Get-VMateComponentById $Catalog.monitor_items `
            ([string]$Binding.monitor_id) 'monitor') `
        (Get-VMateComponentById $Catalog.keyboard_items `
            ([string]$Binding.keyboard_id) 'keyboard') `
        (Get-VMateComponentById $Catalog.mouse_items `
            ([string]$Binding.mouse_id) 'mouse') `
        (Get-VMateComponentById $Catalog.tablet_items $tabletId 'tablet') $gpu
    return $resolved
}

function Assert-VMateRequestedComponentSelection {
    param(
        [object]$Components,
        [string]$StorageId = '',
        [string]$GpuId = '',
        [string]$MonitorId = ''
    )

    $requests = [ordered]@{
        StorageId = @($StorageId, $Components.storage)
        GpuId = @($GpuId, $Components.gpu)
        MonitorId = @($MonitorId, $Components.monitor)
    }
    foreach ($entry in $requests.GetEnumerator()) {
        $requested = [string]$entry.Value[0]
        if (-not $requested) {
            continue
        }
        $selected = $entry.Value[1]
        if ($null -eq $selected -or
            [string]$selected.id -cne $requested) {
            $actual = if ($null -eq $selected) {
                'legacy-unbound'
            } else {
                [string]$selected.id
            }
            throw "已有 profile 的 $($entry.Key)=$actual 与显式请求 '$requested' 不一致；不会重新抽取。"
        }
    }
}

function Resolve-VMateComponentsForProfile {
    param(
        [object]$Catalog,
        [string]$ProfilePath,
        [bool]$Reroll,
        [string]$QemuImg = '',
        [string]$Disk = '',
        [bool]$DryRun = $false,
        [string]$DryRunStorageId = '',
        [string]$StorageId = '',
        [string]$GpuId = '',
        [string]$MonitorId = ''
    )

    if (-not $Reroll -and
        (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
        try {
            $profile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "硬件 profile 不是有效 JSON：$ProfilePath；$($_.Exception.Message)"
        }
        if (-not (Test-VMateComponentProperty $profile 'components')) {
            throw '已有硬件 profile 缺少部件绑定。'
        }
        $resolved = Resolve-VMateComponentSelection $Catalog $profile.components
        Assert-VMateRequestedComponentSelection $resolved $StorageId `
            $GpuId $MonitorId
        return $resolved
    }

    $productStorageBytes = [int64]512110190592
    $productStorages = @(Get-VMateStorageCapacityCandidates `
            $Catalog.storage_items $productStorageBytes)
    $capacity = $null
    if (-not $DryRun) {
        # 先读取磁盘真实 virtual-size；产品契约统一为精确 512G 原始字节数，
        # 不能因为目录仍保留历史 500GB 条目就静默扩大新建磁盘容量。
        $capacity = Get-VMateStorageVirtualSize -QemuImg $QemuImg -Disk $Disk
        if ([int64]$capacity -ne $productStorageBytes) {
            throw "新建磁盘 virtual-size=$capacity 不符合统一 512G（$productStorageBytes bytes）产品契约。"
        }
    }
    $effectiveStorageId = if ($StorageId) {
        $StorageId
    } elseif ($DryRun -and $DryRunStorageId) {
        $DryRunStorageId
    } else {
        ''
    }
    $storage = if ($effectiveStorageId) {
        $explicit = Get-VMateComponentById $productStorages `
            $effectiveStorageId `
            'storage'
        if ($null -ne $capacity -and
            [int64]$explicit.raw_bytes -ne [int64]$capacity) {
            throw "显式存储 '$effectiveStorageId' 的 raw_bytes=$($explicit.raw_bytes) 与磁盘 virtual-size=$capacity 不一致。"
        }
        $explicit
    } elseif ($null -ne $capacity) {
        Get-VMateWeightedComponent $productStorages '512G storage'
    } else {
        # DryRun 没有磁盘事实，仍只能在同一 512G 产品子池按源头权重选择。
        Get-VMateWeightedComponent $productStorages '512G storage'
    }
    $monitor = if ($MonitorId) {
        Get-VMateComponentById $Catalog.monitor_items $MonitorId 'monitor'
    } else {
        $Catalog.monitor
    }
    $gpu = if ($GpuId) {
        Get-VMateComponentById $Catalog.gpu_items $GpuId 'GPU'
    } else {
        $Catalog.gpu
    }
    return New-VMateResolvedComponents $Catalog $storage $monitor `
        $Catalog.keyboard $Catalog.mouse $Catalog.tablet $gpu
}

function New-VMateComponentProfileBinding {
    param([object]$Components)

    if ($null -eq $Components.gpu) {
        throw '新硬件 profile 必须从启用 AIB 目录选择一张 GPU 板卡。'
    }
    return [ordered]@{
        binding_version = 3
        schema_version = [int]$Components.schema_version
        catalog_revision = [string]$Components.catalog_revision
        catalog_digest = [string]$Components.catalog_digest
        storage_id = [string]$Components.storage.id
        storage_digest = Get-VMateComponentDigest $Components.storage
        gpu_id = [string]$Components.gpu.id
        gpu_digest = Get-VMateComponentDigest $Components.gpu
        gpu_label = Get-VMateGpuLabel $Components.gpu
        gpu_identity_fidelity = [string]$Components.gpu.identity_fidelity
        monitor_id = [string]$Components.monitor.id
        monitor_digest = Get-VMateComponentDigest $Components.monitor
        keyboard_id = [string]$Components.keyboard.id
        keyboard_digest = Get-VMateComponentDigest $Components.keyboard
        mouse_id = [string]$Components.mouse.id
        mouse_digest = Get-VMateComponentDigest $Components.mouse
        tablet_id = [string]$Components.tablet.id
        tablet_digest = Get-VMateComponentDigest $Components.tablet
    }
}

function Assert-VMateComponentProfileBinding {
    param(
        [object]$Binding,
        [object]$Components
    )

    $ids = [ordered]@{
        storage_id = [string]$Components.storage.id
        monitor_id = [string]$Components.monitor.id
        keyboard_id = [string]$Components.keyboard.id
        mouse_id = [string]$Components.mouse.id
    }
    foreach ($entry in $ids.GetEnumerator()) {
        if (-not (Test-VMateComponentProperty $Binding $entry.Key) -or
            [string]$Binding.($entry.Key) -cne $entry.Value) {
            throw "硬件 profile 的部件绑定 '$($entry.Key)' 与所选目录不一致。"
        }
    }
    if (-not (Test-VMateComponentProperty $Binding 'binding_version')) {
        $legacyFields = @('schema_version', 'catalog_revision',
            'catalog_digest', 'storage_id', 'monitor_id', 'keyboard_id',
            'mouse_id')
        $actualFields = @($Binding.PSObject.Properties.Name | Sort-Object)
        if (($actualFields -join "`n") -cne
            (@($legacyFields | Sort-Object) -join "`n")) {
            throw '旧版部件绑定字段集合无效，不能从摘要绑定降级。'
        }
        if (-not (Test-VMateComponentInteger $Binding.schema_version) -or
            [int]$Binding.schema_version -ne 1 -or
            $Binding.catalog_revision -isnot [string] -or
            $Binding.catalog_digest -isnot [string] -or
            [string]$Binding.storage_id -cne 'samsung-970-pro-512gb' -or
            [string]$Binding.monitor_id -cne 'samsung-s24f350') {
            throw '无条目摘要的旧版绑定只允许既有 Samsung 组合。'
        }
        return
    }
    if (-not (Test-VMateComponentInteger $Binding.binding_version) -or
        [int]$Binding.binding_version -notin @(2, 3) -or
        -not (Test-VMateComponentInteger $Binding.schema_version) -or
        [int]$Binding.schema_version -ne [int]$Components.schema_version) {
        throw '硬件 profile 的部件 binding_version/schema_version 无效。'
    }
    $bundles = [ordered]@{
        storage = $Components.storage
        monitor = $Components.monitor
        keyboard = $Components.keyboard
        mouse = $Components.mouse
        tablet = $Components.tablet
    }
    if ([int]$Binding.binding_version -eq 3) {
        if ($null -eq $Components.gpu -or
            -not (Test-VMateComponentProperty $Binding 'gpu_label') -or
            [string]$Binding.gpu_label -cne
                (Get-VMateGpuLabel $Components.gpu) -or
            -not (Test-VMateComponentProperty `
                $Binding 'gpu_identity_fidelity') -or
            [string]$Binding.gpu_identity_fidelity -cne
                [string]$Components.gpu.identity_fidelity -or
            [string]$Components.gpu.identity_fidelity -notin @(
                'label_only_out_of_scope',
                'audited_aib_bundle_shallow_user_projection_no_passthrough')) {
            throw 'V3 profile 的 GPU 稳定标签或证据边界无效。'
        }
        $bundles['gpu'] = $Components.gpu
    } elseif ($null -ne $Components.gpu) {
        throw 'V2 profile 不能携带未版本化的 GPU 标签绑定。'
    }
    foreach ($entry in $bundles.GetEnumerator()) {
        $idField = $entry.Key + '_id'
        $digestField = $entry.Key + '_digest'
        if (-not (Test-VMateComponentProperty $Binding $idField) -or
            [string]$Binding.$idField -cne [string]$entry.Value.id -or
            -not (Test-VMateComponentProperty $Binding $digestField) -or
            [string]$Binding.$digestField -cne
                (Get-VMateComponentDigest $entry.Value)) {
            throw "硬件 profile 的 $($entry.Key) 条目摘要与当前目录不一致。"
        }
    }
}
