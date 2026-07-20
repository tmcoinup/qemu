#Requires -Version 5.1

. (Join-Path $PSScriptRoot 'VMate.Manifest.ps1')
. (Join-Path $PSScriptRoot 'VMate.Compatibility.ps1')
. (Join-Path $PSScriptRoot 'VMate.Memory.ps1')
. (Join-Path $PSScriptRoot 'VMate.ProfileStore.ps1')

<#
.SYNOPSIS
    从共享硬件清单创建并加载 Windows VM 的持久化身份。

.DESCRIPTION
    profile 只保存随机身份、所选平台 ID 和平台快照摘要，硬件事实始终来自
    deploy/hardware/platforms.json。这样 Linux/Windows 不会各自维护一份容易
    漂移的 CPU/主板表。文件使用同目录临时文件原子替换，避免断电留下半截 JSON。
#>

function Get-VMateSecureIndex {
    param([int]$Count)

    if ($Count -lt 1) {
        throw '安全随机选择要求至少一个候选项。'
    }
    $bytes = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        # 拒绝采样能消除 uint32 取模带来的微小偏差；硬件池再小也保持均匀选择。
        $limit = [uint64]::MaxValue
        $limit = 4294967296 - (4294967296 % [uint64]$Count)
        do {
            $rng.GetBytes($bytes)
            $value = [BitConverter]::ToUInt32($bytes, 0)
        } while ([uint64]$value -ge $limit)
        return [int]([uint64]$value % [uint64]$Count)
    } finally {
        $rng.Dispose()
    }
}

function New-VMateRandomHex {
    param([int]$Bytes)
    $data = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $rng.GetBytes($data)
            $value = ([BitConverter]::ToString($data)).Replace('-', '')
        } while ($value -match '^(0+|F+)$')
        return $value
    } finally {
        $rng.Dispose()
    }
}

function New-VMateRandomDigits {
    param([int]$Length)
    do {
        $builder = [System.Text.StringBuilder]::new()
        for ($index = 0; $index -lt $Length; $index++) {
            [void]$builder.Append((Get-VMateSecureIndex -Count 10))
        }
        $value = $builder.ToString()
    } while ($value -match '^0+$')
    return $value
}

function Get-VMatePlatformDigest {
    param([object]$Platform)
    $json = $Platform | ConvertTo-Json -Depth 64 -Compress
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($json))
        return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function New-VMateMacAddress {
    param([object]$Platform)
    # Windows 路线使用 manifest 声明的 Intel 82574L 独立网卡；OUI 与 PCI/
    # subsystem 必须来自同一设备条目，后三字节再由 CSPRNG 生成并持久化。
    $nic = $Platform.devices.nic
    $expectedBoardState = if (Test-VMateCompatibilityPlatform $Platform) {
        'not_applicable'
    } else {
        'disabled_in_bios'
    }
    if ([string]$nic.pci_vendor -ne '0x8086' -or
        [string]$nic.pci_device -ne '0x10D3' -or
        [string]$nic.attachment -ne 'add_in' -or
        [string]$nic.board_nic_state -ne $expectedBoardState) {
        throw "平台 '$($Platform.id)' 的 NIC 不能由当前 e1000e 独立网卡路线表达。"
    }
    $oui = ([string]$nic.mac_oui).Replace('-', ':').ToUpperInvariant()
    if ($oui -notmatch '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){2}$') {
        throw "平台 '$($Platform.id)' 的 nic.mac_oui 格式无效：$oui"
    }
    $suffix = New-VMateRandomHex -Bytes 3
    return ('{0}:{1}:{2}:{3}' -f $oui.ToUpperInvariant(),
        $suffix.Substring(0, 2), $suffix.Substring(2, 2), $suffix.Substring(4, 2))
}

function New-VMateHardwareProfile {
    param(
        [object]$Manifest,
        [object]$Platform,
        [object]$Components,
        [object]$HostCpu,
        [int]$Instance,
        [int]$MemoryMiB,
        [int]$Cpus,
        [bool]$PlatformCompatibility
    )

    $memoryPlan = Get-VMateMemoryModulePlan -Platform $Platform `
        -MemoryMiB $MemoryMiB
    $memorySerials = @()
    for ($index = 0; $index -lt $memoryPlan.ModuleCount; $index++) {
        $memorySerials += New-VMateRandomHex -Bytes 4
    }
    $memoryPart = [string]$memoryPlan.PartNumber
    $memoryRate = Get-VMateMemoryRateFacts -Platform $Platform -PartNumber $memoryPart
    $nvmeToken = New-VMateRandomHex -Bytes 6
    return [ordered]@{
        schema_version = 1
        manifest_schema_version = [int]$Manifest.schema_version
        manifest_catalog_revision = [string]$Manifest.catalog_revision
        platform_id = [string]$Platform.id
        platform_digest = Get-VMatePlatformDigest -Platform $Platform
        components = New-VMateComponentProfileBinding -Components $Components
        instance = $Instance
        created_utc = [DateTime]::UtcNow.ToString('o')
        cpu_policy = if ($PlatformCompatibility) {
            'whpx-host-compatibility'
        } else {
            'whpx-host'
        }
        configuration = [ordered]@{
            memory_mib = $MemoryMiB
            memory_configured_mts = $memoryRate.ConfiguredMts
            memory_module_mib = $memoryPlan.ModuleMiB
            memory_module_count = $memoryPlan.ModuleCount
            vcpus = $Cpus
            # 该标志只允许与通用 QEMU/Q35 模板一起出现；物理平台仍不允许
            # CPU/主板混搭。重载时调用方必须再次提供显式兼容授权。
            host_cpu_platform_mismatch_allowed = $PlatformCompatibility
        }
        host_cpu = [ordered]@{
            vendor_id = [string]$HostCpu.vendor_id
            name = [string]$HostCpu.name
            cores = [int]$HostCpu.cores
            logical_processors = [int]$HostCpu.logical_processors
            max_mhz = [int]$HostCpu.max_mhz
        }
        identity = [ordered]@{
            uuid = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
            mac = New-VMateMacAddress -Platform $Platform
            system_serial = 'SYS' + (New-VMateRandomHex -Bytes 6)
            board_serial = 'MB' + (New-VMateRandomDigits -Length 12)
            chassis_serial = 'CH' + (New-VMateRandomHex -Bytes 6)
            cpu_serial = 'CPU' + (New-VMateRandomHex -Bytes 6)
            memory_serials = $memorySerials
            memory_manufacturer = 'Samsung'
            memory_part = $memoryPart
            memory_rated_mts = $memoryRate.RatedMts
            nvme_serial = 'S' + $nvmeToken.Substring(0, 3) + 'N' +
                $nvmeToken.Substring(3, 9)
            monitor_serial = [string]$Components.monitor.serial_prefix +
                (New-VMateRandomDigits -Length 8)
        }
    }
}

function Assert-VMateHostCpuIdentity {
    param([object]$HostCpu)
    foreach ($field in @('vendor_id', 'name', 'cores', 'logical_processors',
            'max_mhz')) {
        if (-not (Test-VMateJsonProperty $HostCpu $field)) {
            throw "宿主 CPU 身份缺少字段 '$field'。"
        }
    }
    if ($HostCpu.vendor_id -isnot [string] -or
        [string]$HostCpu.vendor_id -notin @('GenuineIntel', 'AuthenticAMD') -or
        $HostCpu.name -isnot [string] -or -not ([string]$HostCpu.name).Trim()) {
        throw '宿主 CPU 厂商或名称类型无效。'
    }
    foreach ($field in @('cores', 'logical_processors', 'max_mhz')) {
        $value = $HostCpu.$field
        if (-not (Test-VMateIntegerValue $value) -or [int64]$value -lt 1) {
            throw "宿主 CPU 字段 '$field' 必须是正整数。"
        }
    }
    if ([int64]$HostCpu.logical_processors -lt [int64]$HostCpu.cores) {
        throw '宿主 CPU 逻辑处理器数不能少于核心数。'
    }
}

function Assert-VMateHardwareIdentity {
    param(
        [object]$Identity,
        [object]$Configuration,
        [object]$Platform,
        [object]$Components
    )

    $uuid = [string]$Identity.uuid
    if ($Identity.uuid -isnot [string] -or
        $uuid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' -or
        $uuid -in @('00000000-0000-4000-8000-000000000000', 'ffffffff-ffff-4fff-bfff-ffffffffffff')) {
        throw '硬件 profile 的 UUID 必须是规范的小写 RFC 4122 v4 标识。'
    }
    $mac = [string]$Identity.mac
    $oui = ([string]$Platform.devices.nic.mac_oui).Replace('-', ':').ToUpperInvariant()
    if ($Identity.mac -isnot [string] -or
        $mac -notmatch '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' -or
        $mac.Substring(0, 8) -ne $oui -or
        ([Convert]::ToInt32($mac.Substring(0, 2), 16) -band 3) -ne 0 -or
        $mac.Substring(9).Replace(':', '') -match '^(000000|FFFFFF)$') {
        throw '硬件 profile 的 MAC 必须使用 manifest OUI、全局单播地址和非占位后缀。'
    }

    $formats = [ordered]@{
        system_serial = '^SYS[0-9A-F]{12}$'
        board_serial = '^MB[0-9]{12}$'
        chassis_serial = '^CH[0-9A-F]{12}$'
        cpu_serial = '^CPU[0-9A-F]{12}$'
        nvme_serial = '^S[A-Z0-9]{3}N[A-Z0-9]{9}$'
        monitor_serial = '^' + [Regex]::Escape(
            [string]$Components.monitor.serial_prefix) + '[0-9]{8}$'
    }
    foreach ($entry in $formats.GetEnumerator()) {
        $value = $Identity.($entry.Key)
        if ($value -isnot [string] -or [string]$value -notmatch $entry.Value) {
            throw "硬件 profile 的 $($entry.Key) 格式无效或为空。"
        }
    }
    foreach ($value in @($Identity.system_serial.Substring(3),
            $Identity.board_serial.Substring(2),
            $Identity.chassis_serial.Substring(2),
            $Identity.cpu_serial.Substring(3),
            $Identity.monitor_serial.Substring(
                ([string]$Components.monitor.serial_prefix).Length))) {
        if ($value -match '^(0+|F+)$' -or
            $Identity.nvme_serial -match '^S(?:000N0{9}|FFFNF{9})$') {
            throw '硬件 profile 含全零或全 F 占位序列号。'
        }
    }

    if ($Identity.memory_serials -isnot [System.Array]) {
        throw '硬件 profile 的 memory_serials 必须是 JSON 数组。'
    }
    $memorySerials = @($Identity.memory_serials)
    $allSerials = @($Identity.system_serial, $Identity.board_serial,
        $Identity.chassis_serial, $Identity.cpu_serial, $Identity.nvme_serial,
        $Identity.monitor_serial) + $memorySerials
    $unique = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    if ($memorySerials.Count -ne [int]$Configuration.memory_module_count -or
        @($memorySerials | Where-Object {
                $_ -isnot [string] -or [string]$_ -notmatch '^[0-9A-F]{8}$' -or
                [string]$_ -match '^(00000000|00000001|FFFFFFFF)$'
            }).Count -gt 0 -or
        @($allSerials | Where-Object { -not $unique.Add([string]$_) }).Count -gt 0) {
        throw '硬件 profile 的序列号数量、格式或唯一性与硬件拓扑不一致。'
    }
}

function Assert-VMateHardwareProfile {
    param(
        [object]$Profile,
        [object]$Manifest,
        [object]$Platform,
        [object]$Components,
        [object]$HostCpu,
        [int]$Instance,
        [int]$MemoryMiB,
        [int]$Cpus,
        [Alias('AllowHostCpuPlatformMismatch')]
        [bool]$AllowPlatformCompatibility
    )

    Assert-VMateHostCpuIdentity -HostCpu $HostCpu
    foreach ($field in @('schema_version', 'manifest_schema_version',
            'manifest_catalog_revision', 'platform_id', 'platform_digest',
            'components', 'instance', 'cpu_policy', 'configuration', 'host_cpu',
            'identity')) {
        if (-not (Test-VMateJsonProperty $Profile $field)) {
            throw "硬件 profile 缺少字段 '$field'。"
        }
    }
    foreach ($field in @('schema_version', 'manifest_schema_version', 'instance')) {
        if (-not (Test-VMateIntegerValue $Profile.$field)) {
            throw "硬件 profile 字段 '$field' 必须是 JSON 整数。"
        }
    }
    if ([int]$Profile.schema_version -ne 1 -or
        [int]$Profile.manifest_schema_version -ne [int]$Manifest.schema_version) {
        throw '硬件 profile 与当前 schema 不兼容；请显式使用 -RerollHardwareProfile。'
    }
    if ($Profile.manifest_catalog_revision -isnot [string] -or
        [string]$Profile.manifest_catalog_revision -ne
            [string]$Manifest.catalog_revision) {
        throw '硬件 profile 与当前 manifest catalog_revision 不一致；请显式 reroll。'
    }
    if ([int]$Profile.instance -ne $Instance -or
        [string]$Profile.platform_id -ne [string]$Platform.id) {
        throw '硬件 profile 的实例或平台 ID 与当前启动请求不一致。'
    }
    foreach ($field in @('memory_mib', 'memory_configured_mts',
            'memory_module_mib', 'memory_module_count', 'vcpus',
            'host_cpu_platform_mismatch_allowed')) {
        if (-not (Test-VMateJsonProperty $Profile.configuration $field)) {
            throw "硬件 profile 的 configuration 缺少字段 '$field'。"
        }
    }
    foreach ($field in @('memory_mib', 'memory_configured_mts',
            'memory_module_mib', 'memory_module_count', 'vcpus')) {
        if (-not (Test-VMateIntegerValue $Profile.configuration.$field)) {
            throw "硬件 profile 的 configuration.$field 必须是 JSON 整数。"
        }
    }
    $isCompatibility = Test-VMateCompatibilityPlatform -Platform $Platform
    $storedCompatibility =
        $Profile.configuration.host_cpu_platform_mismatch_allowed
    if ($storedCompatibility -isnot [bool] -or
        [bool]$storedCompatibility -ne $isCompatibility) {
        throw '硬件 profile 的 compatibility 标志与所选目录类型不一致。'
    }
    if ($isCompatibility -and -not $AllowPlatformCompatibility) {
        throw '已有 profile 使用通用 Q35 兼容模板；每次启动都必须显式提供 -AllowPlatformCompatibility。'
    }
    if ($isCompatibility) {
        Assert-VMateHouseholdHostCpu -HostCpu $HostCpu
        Assert-VMateHouseholdHostCpu -HostCpu $Profile.host_cpu
    }
    if ([int]$Profile.configuration.memory_mib -ne $MemoryMiB -or
        [int]$Profile.configuration.vcpus -ne $Cpus) {
        throw '内存/vCPU 与持久化 profile 不一致；请审核后显式使用 -RerollHardwareProfile。'
    }
    if ([string]$Profile.platform_digest -ne
        (Get-VMatePlatformDigest -Platform $Platform)) {
        throw '硬件清单中的平台事实已变化；请审核后显式使用 -RerollHardwareProfile。'
    }
    Assert-VMateComponentProfileBinding -Binding $Profile.components `
        -Components $Components
    Assert-VMateHostCpuIdentity -HostCpu $Profile.host_cpu
    if (-not $isCompatibility -and
        -not (Test-VMateHostCpuPlatformPair $Platform $Profile.host_cpu)) {
        throw '硬件 profile 的宿主 CPU 与 manifest 主板/Type 4 平台不匹配。'
    }
    $profileCpuName = (([string]$Profile.host_cpu.name) -replace '\s+', ' ').Trim()
    $currentCpuName = (([string]$HostCpu.name) -replace '\s+', ' ').Trim()
    $expectedCpuPolicy = if ($isCompatibility) {
        'whpx-host-compatibility'
    } else {
        'whpx-host'
    }
    if ([string]$Profile.cpu_policy -ne $expectedCpuPolicy -or
        [string]$Profile.host_cpu.vendor_id -ne [string]$HostCpu.vendor_id -or
        $profileCpuName -ne $currentCpuName -or
        [int]$Profile.host_cpu.cores -ne [int]$HostCpu.cores -or
        [int]$Profile.host_cpu.logical_processors -ne
            [int]$HostCpu.logical_processors -or
        [int]$Profile.host_cpu.max_mhz -ne [int]$HostCpu.max_mhz) {
        throw 'WHPX 宿主 CPU 完整身份与持久化 profile 不一致，拒绝静默改变客体 CPU 面。'
    }
    foreach ($field in @('uuid', 'mac', 'system_serial', 'board_serial',
            'chassis_serial', 'cpu_serial', 'memory_serials',
            'memory_manufacturer', 'memory_part', 'memory_rated_mts', 'nvme_serial',
            'monitor_serial')) {
        if (-not (Test-VMateJsonProperty $Profile.identity $field)) {
            throw "硬件 profile 的 identity 缺少字段 '$field'。"
        }
    }
    Assert-VMateHardwareIdentity -Identity $Profile.identity `
        -Configuration $Profile.configuration -Platform $Platform `
        -Components $Components
    Assert-VMateMemoryRateFacts -Profile $Profile -Platform $Platform
}

function Prepare-VMateHardwareProfile {
    param(
        [object]$Manifest,
        [object]$CompatibilityManifest = $null,
        [object]$Components,
        [string]$Path,
        [string]$PlatformId,
        [object]$HostCpu,
        [int]$Instance,
        [int]$MemoryMiB,
        [int]$Cpus,
        [Alias('AllowHostCpuPlatformMismatch')]
        [bool]$AllowPlatformCompatibility,
        [bool]$Reroll
    )

    $existing = $null
    $profileExists = Test-Path -LiteralPath $Path -PathType Leaf
    if ($profileExists -and -not $Reroll) {
        try {
            $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "硬件 profile 不是有效 JSON：$Path；$($_.Exception.Message)"
        }
        if ($PlatformId -and [string]$existing.platform_id -ne $PlatformId) {
            throw '已有 profile 与 -PlatformId 不同；必须显式使用 -RerollHardwareProfile。'
        }
        $PlatformId = [string]$existing.platform_id
    }

    $platformSelection = Select-VMatePlatform -Manifest $Manifest `
        -CompatibilityManifest $CompatibilityManifest -PlatformId $PlatformId `
        -HostCpu $HostCpu -GuestCpus $Cpus `
        -AllowPlatformCompatibility $AllowPlatformCompatibility
    $platform = $platformSelection.Platform
    $catalog = $platformSelection.Catalog
    Assert-VMateRequestedTopology -Platform $platform -HostCpu $HostCpu `
        -MemoryMiB $MemoryMiB -Cpus $Cpus
    if ($null -eq $existing) {
        $attempt = 0
        do {
            $profile = New-VMateHardwareProfile -Manifest $catalog -Platform $platform `
                -Components $Components `
                -HostCpu $HostCpu -Instance $Instance -MemoryMiB $MemoryMiB -Cpus $Cpus `
                -PlatformCompatibility $platformSelection.IsCompatibility
            $attempt++
            $unique = Test-VMateProfileIdentityUnique -Profile $profile -Path $Path
        } while (-not $unique -and $attempt -lt 16)
        if (-not $unique) {
            throw '连续 16 次生成的身份均与现有 VM 冲突，拒绝写入 profile。'
        }
        Assert-VMateHardwareProfile -Profile $profile -Manifest $catalog `
            -Platform $platform -Components $Components -HostCpu $HostCpu `
            -Instance $Instance -MemoryMiB $MemoryMiB -Cpus $Cpus `
            -AllowPlatformCompatibility $AllowPlatformCompatibility
    } else {
        $profile = $existing
        if (-not (Test-VMateProfileIdentityUnique -Profile $profile -Path $Path)) {
            throw '已有 profile 的 UUID/MAC/NVMe 序列与相邻 VM 冲突。'
        }
        Assert-VMateHardwareProfile -Profile $profile -Manifest $catalog `
            -Platform $platform -Components $Components -HostCpu $HostCpu `
            -Instance $Instance -MemoryMiB $MemoryMiB -Cpus $Cpus `
            -AllowPlatformCompatibility $AllowPlatformCompatibility
    }
    $sourceDigest = if ($profileExists) {
        Get-VMateProfileFileDigest -Path $Path
    } else {
        ''
    }
    # 返回事务快照但不写文件。启动器只有在所有 SMBIOS、PCI、GPU、ROI 参数
    # 都构造成功后，才会把同一快照交给 Commit-VMateHardwareProfile。
    return [pscustomobject]@{
        Profile = $profile
        Platform = $platform
        SourceExisted = [bool]$profileExists
        SourceDigest = [string]$sourceDigest
        PreparedDigest = Get-VMateProfileObjectDigest -Profile $profile
        RequiresCommit = [bool]($null -eq $existing)
        Reroll = [bool]$Reroll
    }
}
