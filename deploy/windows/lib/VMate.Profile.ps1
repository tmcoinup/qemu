#Requires -Version 5.1

. (Join-Path $PSScriptRoot 'VMate.Manifest.ps1')
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
        $rng.GetBytes($data)
    } finally {
        $rng.Dispose()
    }
    return ([BitConverter]::ToString($data)).Replace('-', '')
}

function New-VMateRandomDigits {
    param([int]$Length)

    $builder = [System.Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Length; $index++) {
        [void]$builder.Append((Get-VMateSecureIndex -Count 10))
    }
    return $builder.ToString()
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

function Select-VMatePlatform {
    param(
        [object]$Manifest,
        [string]$PlatformId = '',
        [string]$HostVendorId = '',
        [string]$HostCpuName = '',
        [bool]$AllowHostCpuPlatformMismatch = $false
    )

    $enabled = @($Manifest.platforms | Where-Object {
        $_.enabled -eq $true -and [string]$_.status -eq 'supported' -and
        [string]$_.devices.audio.controller_pci_vendor -eq '0x8086'
    })
    foreach ($platform in $enabled) {
        Assert-VMatePlatformShape -Platform $platform
    }
    if ($PlatformId) {
        $matches = @($enabled | Where-Object { $_.id -eq $PlatformId })
        if ($matches.Count -ne 1) {
            throw "平台 '$PlatformId' 不存在、已禁用或 ID 不唯一。"
        }
        $manifestCpu = ([string]$matches[0].cpu.name -replace '\s+', ' ').Trim()
        $hostCpu = ($HostCpuName -replace '\s+', ' ').Trim()
        if (-not $AllowHostCpuPlatformMismatch -and $manifestCpu -ne $hostCpu) {
            throw "WHPX 无法应用平台 CPU '$manifestCpu'，宿主实际为 '$hostCpu'；仅功能模式可显式使用 -AllowHostCpuPlatformMismatch。"
        }
        return $matches[0]
    }

    # Windows 构建当前只提供 ICH9 HDA 行为层；AMD HDA 即使改 PCI ID 也不是
    # 同一控制器，不能进入 Windows 候选。WHPX 的 -cpu 又不会塑造自定义 CPU，
    # 自动选择时至少保证平台与宿主 CPU 厂商一致，精确型号记录为 whpx-host。
    $candidates = @($enabled | Where-Object {
        if ($AllowHostCpuPlatformMismatch) {
            return (-not $HostVendorId -or $_.cpu.vendor_id -eq $HostVendorId)
        }
        $manifestCpu = ([string]$_.cpu.name -replace '\s+', ' ').Trim()
        $hostCpu = ($HostCpuName -replace '\s+', ' ').Trim()
        return ($_.cpu.vendor_id -eq $HostVendorId -and $manifestCpu -eq $hostCpu)
    })
    if ($candidates.Count -eq 0) {
        throw "共享清单没有与 WHPX 宿主 CPU '$HostCpuName' 精确匹配的启用平台。"
    }
    return $candidates[(Get-VMateSecureIndex -Count $candidates.Count)]
}

function New-VMateMacAddress {
    param([object]$Platform)

    # Windows 路线使用 manifest 声明的 Intel 82574L 独立网卡；OUI 与 PCI/
    # subsystem 必须来自同一设备条目，后三字节再由 CSPRNG 生成并持久化。
    $nic = $Platform.devices.nic
    if ([string]$nic.pci_vendor -ne '0x8086' -or
        [string]$nic.pci_device -ne '0x10D3' -or
        [string]$nic.attachment -ne 'add_in' -or
        [string]$nic.board_nic_state -ne 'disabled_in_bios') {
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
        [bool]$AllowHostCpuPlatformMismatch
    )

    $memoryPlan = Get-VMateMemoryModulePlan -Platform $Platform `
        -MemoryMiB $MemoryMiB
    $memorySerials = @()
    for ($index = 0; $index -lt $memoryPlan.ModuleCount; $index++) {
        $memorySerials += New-VMateRandomHex -Bytes 4
    }
    $memoryPart = [string]$memoryPlan.PartNumber
    $memoryRate = Get-VMateMemoryRateFacts -Platform $Platform -PartNumber $memoryPart
    return [ordered]@{
        schema_version = 1
        manifest_schema_version = [int]$Manifest.schema_version
        manifest_catalog_revision = [string]$Manifest.catalog_revision
        platform_id = [string]$Platform.id
        platform_digest = Get-VMatePlatformDigest -Platform $Platform
        components = New-VMateComponentProfileBinding -Components $Components
        instance = $Instance
        created_utc = [DateTime]::UtcNow.ToString('o')
        cpu_policy = 'whpx-host'
        configuration = [ordered]@{
            memory_mib = $MemoryMiB
            memory_configured_mts = $memoryRate.ConfiguredMts
            memory_module_mib = $memoryPlan.ModuleMiB
            memory_module_count = $memoryPlan.ModuleCount
            vcpus = $Cpus
            host_cpu_platform_mismatch_allowed = $AllowHostCpuPlatformMismatch
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
            nvme_serial = 'S5H9NS0N' + (New-VMateRandomDigits -Length 7)
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
        [bool]$AllowHostCpuPlatformMismatch
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
    if ($Profile.configuration.host_cpu_platform_mismatch_allowed -isnot [bool]) {
        throw '硬件 profile 的 host_cpu_platform_mismatch_allowed 必须是布尔值。'
    }
    if ([int]$Profile.configuration.memory_mib -ne $MemoryMiB -or
        [int]$Profile.configuration.vcpus -ne $Cpus -or
        $Profile.configuration.host_cpu_platform_mismatch_allowed -ne
            $AllowHostCpuPlatformMismatch) {
        throw '内存/vCPU 与持久化 profile 不一致；请审核后显式使用 -RerollHardwareProfile。'
    }
    if ([string]$Profile.platform_digest -ne
        (Get-VMatePlatformDigest -Platform $Platform)) {
        throw '硬件清单中的平台事实已变化；请审核后显式使用 -RerollHardwareProfile。'
    }
    Assert-VMateComponentProfileBinding -Binding $Profile.components `
        -Components $Components
    Assert-VMateHostCpuIdentity -HostCpu $Profile.host_cpu
    $profileCpuName = (([string]$Profile.host_cpu.name) -replace '\s+', ' ').Trim()
    $currentCpuName = (([string]$HostCpu.name) -replace '\s+', ' ').Trim()
    if ([string]$Profile.cpu_policy -ne 'whpx-host' -or
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
    if ([string]$Profile.identity.uuid -notmatch
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
        [string]$Profile.identity.mac -notmatch '^([0-9A-F]{2}:){5}[0-9A-F]{2}$') {
        throw '硬件 profile 的 UUID 或 MAC 格式无效。'
    }
    $memorySerials = @($Profile.identity.memory_serials)
    if ($memorySerials.Count -ne
        [int]$Profile.configuration.memory_module_count -or
        @($memorySerials | Where-Object {
                $_ -isnot [string] -or [string]$_ -notmatch '^[0-9A-F]{8}$'
            }).Count -gt 0) {
        throw '硬件 profile 的 DIMM 序列号数量或格式与模块拓扑不一致。'
    }
    Assert-VMateMemoryRateFacts -Profile $Profile -Platform $Platform
}

function Prepare-VMateHardwareProfile {
    param(
        [object]$Manifest,
        [object]$Components,
        [string]$Path,
        [string]$PlatformId,
        [object]$HostCpu,
        [int]$Instance,
        [int]$MemoryMiB,
        [int]$Cpus,
        [bool]$AllowHostCpuPlatformMismatch,
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

    $platform = Select-VMatePlatform -Manifest $Manifest -PlatformId $PlatformId `
        -HostVendorId ([string]$HostCpu.vendor_id) -HostCpuName ([string]$HostCpu.name) `
        -AllowHostCpuPlatformMismatch $AllowHostCpuPlatformMismatch
    Assert-VMateRequestedTopology -Platform $platform -HostCpu $HostCpu `
        -MemoryMiB $MemoryMiB -Cpus $Cpus
    if ($null -eq $existing) {
        $attempt = 0
        do {
            $profile = New-VMateHardwareProfile -Manifest $Manifest -Platform $platform `
                -Components $Components `
                -HostCpu $HostCpu -Instance $Instance -MemoryMiB $MemoryMiB -Cpus $Cpus `
                -AllowHostCpuPlatformMismatch $AllowHostCpuPlatformMismatch
            $attempt++
            $unique = Test-VMateProfileIdentityUnique -Profile $profile -Path $Path
        } while (-not $unique -and $attempt -lt 16)
        if (-not $unique) {
            throw '连续 16 次生成的身份均与现有 VM 冲突，拒绝写入 profile。'
        }
        Assert-VMateHardwareProfile -Profile $profile -Manifest $Manifest `
            -Platform $platform -Components $Components -HostCpu $HostCpu `
            -Instance $Instance -MemoryMiB $MemoryMiB -Cpus $Cpus `
            -AllowHostCpuPlatformMismatch $AllowHostCpuPlatformMismatch
    } else {
        $profile = $existing
        if (-not (Test-VMateProfileIdentityUnique -Profile $profile -Path $Path)) {
            throw '已有 profile 的 UUID/MAC/NVMe 序列与相邻 VM 冲突。'
        }
        Assert-VMateHardwareProfile -Profile $profile -Manifest $Manifest `
            -Platform $platform -Components $Components -HostCpu $HostCpu `
            -Instance $Instance -MemoryMiB $MemoryMiB -Cpus $Cpus `
            -AllowHostCpuPlatformMismatch $AllowHostCpuPlatformMismatch
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
