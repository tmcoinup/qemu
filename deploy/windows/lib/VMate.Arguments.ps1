#Requires -Version 5.1

<#
.SYNOPSIS
    把已验证的平台与身份转换为 QEMU 参数。

.DESCRIPTION
    本文件不负责随机化和文件写入。所有设备都从同一个 platform/profile 快照
    生成，确保 UUID、MAC、SMBIOS 和 PCI 子系统不会在一次启动中互相漂移。
#>

function Assert-VMateHexId {
    param(
        [object]$Value,
        [string]$Field
    )

    $text = [string]$Value
    if ($text -notmatch '^0x[0-9a-fA-F]{1,8}$') {
        throw "平台字段 '$Field' 不是合法十六进制 ID：$text"
    }
    return $text.ToLowerInvariant()
}

function Get-VMatePcieSpeed {
    param([int]$Generation)

    switch ($Generation) {
        1 { return '2_5' }
        2 { return '5' }
        3 { return '8' }
        4 { return '16' }
        5 { return '32' }
        default { throw "不支持的 PCIe generation：$Generation" }
    }
}

function New-VMateSmbiosArguments {
    param(
        [object]$Platform,
        [object]$Profile
    )

    $identity = $Profile.identity
    $hostCpu = $Profile.host_cpu
    $board = $Platform.board
    $bios = $Platform.bios
    $system = $Platform.system
    $isCompatibility = Test-VMateCompatibilityPlatform -Platform $Platform
    $cpuManufacturer = if ([string]$hostCpu.vendor_id -eq 'AuthenticAMD') {
        'Advanced Micro Devices, Inc.'
    } else {
        'Intel(R) Corporation'
    }

    $type0 = if ($isCompatibility) {
        # 通用模板没有可证明的固件版本/日期；让正在使用的 OVMF 自己提供 Type 0，
        # 不能为了填满字段而伪造一个固定 BIOS。
        $null
    } else {
        'type=0,vendor={0},version={1},date={2},uefi=on' -f
            (ConvertTo-VMateQemuString ([string]$bios.vendor)),
            (ConvertTo-VMateQemuString ([string]$bios.version)),
            (ConvertTo-VMateQemuString ([string]$bios.date))
    }
    $systemManufacturer = if ($isCompatibility) {
        [string]$system.manufacturer
    } else {
        [string]$board.manufacturer
    }
    $systemVersion = if ($isCompatibility) {
        [string]$system.version
    } else {
        [string]$board.version
    }
    $type1 = 'type=1,manufacturer={0},product={1},version={2},serial={3},uuid={4},family={5}' -f
        (ConvertTo-VMateQemuString $systemManufacturer),
        (ConvertTo-VMateQemuString ([string]$system.product)),
        (ConvertTo-VMateQemuString $systemVersion),
        (ConvertTo-VMateQemuString ([string]$identity.system_serial)),
        ([string]$identity.uuid),
        (ConvertTo-VMateQemuString ([string]$system.family))
    $type2 = 'type=2,manufacturer={0},product={1},version={2},serial={3}' -f
        (ConvertTo-VMateQemuString ([string]$board.manufacturer)),
        (ConvertTo-VMateQemuString ([string]$board.product)),
        (ConvertTo-VMateQemuString ([string]$board.version)),
        (ConvertTo-VMateQemuString ([string]$identity.board_serial))
    [void](Assert-VMateHexId $system.chassis_type 'system.chassis_type')
    $type3 = 'type=3,manufacturer={0},version={1},serial={2},chassis-type={3}' -f
        (ConvertTo-VMateQemuString $systemManufacturer),
        (ConvertTo-VMateQemuString $systemVersion),
        (ConvertTo-VMateQemuString ([string]$identity.chassis_serial)),
        ([string]$system.chassis_type)
    if ($Profile.configuration.host_cpu_platform_mismatch_allowed -eq $true) {
        # 功能模式只能诚实报告宿主可观测字段；socket family/voltage 等无法从
        # WHPX 推导时保持 Unknown，不能套用 manifest 中另一个 CPU 的数据。
        $type4 = 'type=4,sock_pfx=CPU,manufacturer={0},version={1},serial={2},max-speed={3},current-speed={3}' -f
            (ConvertTo-VMateQemuString $cpuManufacturer),
            (ConvertTo-VMateQemuString ([string]$hostCpu.name)),
            (ConvertTo-VMateQemuString ([string]$identity.cpu_serial)),
            ([int]$hostCpu.max_mhz)
    } else {
        $cpuFacts = $Platform.cpu
        $smbiosCpu = $cpuFacts.smbios
        $voltageUnits = [int]([Math]::Round([int]$smbiosCpu.voltage_mv / 100.0))
        if ($voltageUnits -lt 1 -or $voltageUnits -gt 127) {
            throw "平台 CPU 电压无法编码进 SMBIOS Type 4：$($smbiosCpu.voltage_mv)mV"
        }
        $encodedVoltage = 0x80 -bor $voltageUnits
        foreach ($field in @('family', 'upgrade', 'characteristics')) {
            [void](Assert-VMateHexId $smbiosCpu.$field "cpu.smbios.$field")
        }
        $type4 = 'type=4,sock_pfx={0},manufacturer={1},version={2},serial={3},part={4},max-speed={5},current-speed={6},processor-family={7},voltage={8},external-clock={9},processor-upgrade={10},processor-characteristics={11}' -f
            (ConvertTo-VMateQemuString ([string]$cpuFacts.socket)),
            (ConvertTo-VMateQemuString $cpuManufacturer),
            (ConvertTo-VMateQemuString ([string]$cpuFacts.name)),
            (ConvertTo-VMateQemuString ([string]$identity.cpu_serial)),
            (ConvertTo-VMateQemuString ([string]$cpuFacts.part)),
            ([int]$cpuFacts.max_mhz),
            ([int]$cpuFacts.current_mhz),
            ([string]$smbiosCpu.family),
            $encodedVoltage,
            ([int]$smbiosCpu.external_clock_mhz),
            ([string]$smbiosCpu.upgrade),
            ([string]$smbiosCpu.characteristics)
    }
    $type16 = 'type=16,max-capacity={0}G,num-devices={1}' -f
        ([int]$board.max_memory_gib), ([int]$board.dimm_slots)

    $allowedMts = @($Platform.memory.allowed_mts | ForEach-Object { [int]$_ })
    $memoryRatedMts = [int]$identity.memory_rated_mts
    $memoryConfiguredMts = [int]$Profile.configuration.memory_configured_mts
    $memoryModuleId = if (Test-VMateMemoryProperty `
            $identity 'memory_module_id') {
        [string]$identity.memory_module_id
    } else {
        ''
    }
    $memoryFacts = Get-VMateMemoryRateFacts -Platform $Platform `
        -PartNumber ([string]$identity.memory_part) `
        -Manufacturer ([string]$identity.memory_manufacturer) `
        -ModuleId $memoryModuleId
    if ($allowedMts.Count -eq 0 -or $memoryRatedMts -le 0 -or
        $memoryConfiguredMts -le 0 -or $memoryConfiguredMts -gt $memoryRatedMts -or
        $memoryConfiguredMts -notin $allowedMts) {
        throw "平台 '$($Platform.id)' 的内存额定/配置速率不一致。"
    }
    $memoryType = switch ([string]$Platform.memory.type) {
        'DDR3' { '0x18' }
        'DDR4' { '0x1a' }
        default { throw "Windows Q35 SPD 生成器不支持内存类型：$($Platform.memory.type)" }
    }
    $serials = @($identity.memory_serials)
    if ($serials.Count -ne [int]$Profile.configuration.memory_module_count) {
        throw '硬件 profile 的 DIMM 序列号数量与模块拓扑不一致。'
    }
    # 中文注释：speed 是 DIMM/SPD 额定能力；configured-speed 是内存控制器
    # 训练后的实际工作速率。Q35 仅用前者生成 SPD，SMBIOS 同时报告两者。
    $encodedSerials = @($serials | ForEach-Object {
        ConvertTo-VMateQemuString ([string]$_)
    }) -join '|'
    $type17 = 'type=17,loc_pfx=DIMM_%C2,bank=P0 CHANNEL %C,manufacturer={0},serial={1},part={2},speed={3},configured-speed={4},memory-type={5},type-detail=0x80,rank={6},voltage={7},device-width={8}' -f
        (ConvertTo-VMateQemuString ([string]$identity.memory_manufacturer)),
        $encodedSerials,
        (ConvertTo-VMateQemuString ([string]$identity.memory_part)),
        $memoryRatedMts,
        $memoryConfiguredMts,
        $memoryType,
        ([int]$memoryFacts.Rank),
        ([int]$Platform.memory.voltage_mv),
        ([int]$memoryFacts.DeviceWidthBits)
    if ($memoryFacts.SpdEe1004) {
        $type17 += ',spd-ee1004=on'
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($type0, $type1, $type2, $type3, $type4, $type16, $type17)) {
        if ($null -ne $value) {
            Add-VMateArgument $arguments @('-smbios', $value)
        }
    }
    return $arguments.ToArray()
}

function New-VMatePlatformDeviceArguments {
    param(
        [object]$Platform,
        [object]$Profile,
        [object]$Components,
        [string]$Disk,
        [int]$SshForwardPort,
        [int]$RdpForwardPort
    )

    $rootPort = $Platform.devices.root_port
    $nvme = $Platform.devices.nvme
    $storage = $Components.storage
    $keyboard = $Components.keyboard
    $mouse = $Components.mouse
    $isCompatibility = Test-VMateCompatibilityPlatform -Platform $Platform
    $rootVendor = Assert-VMateHexId $rootPort.pci_vendor 'devices.root_port.pci_vendor'
    $rootDevice = Assert-VMateHexId $rootPort.pci_device 'devices.root_port.pci_device'
    $rootRevision = Assert-VMateHexId $rootPort.revision 'devices.root_port.revision'
    $rootDeviceBase = [Convert]::ToUInt32($rootDevice.Substring(2), 16)
    if ($rootDeviceBase -gt 0xfffd) {
        throw "root port base device ID 无法派生三个连续功能：$rootDevice"
    }
    $rootDevices = @(0, 1, 2 | ForEach-Object {
        '0x{0:x4}' -f ($rootDeviceBase + $_)
    })
    $audioVendor = Assert-VMateHexId $Platform.devices.audio.controller_pci_vendor `
        'devices.audio.controller_pci_vendor'
    $audioDevice = Assert-VMateHexId $Platform.devices.audio.controller_pci_device `
        'devices.audio.controller_pci_device'
    $nicSubVendor = Assert-VMateHexId $Platform.devices.nic.subsystem_vendor `
        'devices.nic.subsystem_vendor'
    $nicSubDevice = Assert-VMateHexId $Platform.devices.nic.subsystem_device `
        'devices.nic.subsystem_device'
    if ($audioVendor -ne '0x8086') {
        throw "Windows ICH9 HDA 行为层不能表达非 Intel 控制器：$audioVendor"
    }
    $expectedAudioFidelity = if ($isCompatibility) {
        'generic_virtual_protocol'
    } else {
        'protocol_identity_only'
    }
    if ([string]$Platform.devices.audio.identity_fidelity -ne
        $expectedAudioFidelity) {
        throw "平台音频 identity_fidelity 必须是 '$expectedAudioFidelity'，不能声称未实现的 Codec 拓扑。"
    }
    $codecId = Assert-VMateHexId $Platform.devices.audio.codec_id `
        'devices.audio.codec_id'
    $codecRevision = Assert-VMateHexId $Platform.devices.audio.codec_revision `
        'devices.audio.codec_revision'
    $codecSubsystem = Assert-VMateHexId $Platform.devices.audio.codec_subsystem_id `
        'devices.audio.codec_subsystem_id'
    $storageSubVendor = Assert-VMateHexId $storage.pci.subsystem_vendor `
        'components.storage.pci.subsystem_vendor'
    $storageSubDevice = Assert-VMateHexId $storage.pci.subsystem_device `
        'components.storage.pci.subsystem_device'
    $keyboardVendor = Assert-VMateHexId $keyboard.vendor_id `
        'components.keyboard.vendor_id'
    $keyboardProduct = Assert-VMateHexId $keyboard.product_id `
        'components.keyboard.product_id'
    $mouseVendor = Assert-VMateHexId $mouse.vendor_id 'components.mouse.vendor_id'
    $mouseProduct = Assert-VMateHexId $mouse.product_id 'components.mouse.product_id'

    if ($nvme.boot_supported -ne $true -or [int]$nvme.max_pcie_generation -lt 1 -or
        [int]$nvme.lanes -lt 1) {
        throw "平台 '$($Platform.id)' 不能承载 NVMe 启动盘。"
    }
    if ([int]$storage.nvme.pcie_generation -lt [int]$nvme.max_pcie_generation -or
        [int]$storage.nvme.lanes -lt [int]$nvme.lanes) {
        throw "SSD '$($storage.id)' 无法满足平台 M.2 插槽的链路能力。"
    }
    # 目录中的三个消费级 SSD 都是 Gen3 x4 端点，但会按主板 M.2 插槽能力
    # 向下协商；root port 必须报告实际插槽链路，不能拿端点上限覆盖主板能力。
    $nvmeSpeed = Get-VMatePcieSpeed -Generation ([int]$nvme.max_pcie_generation)
    $nvmeWidth = [int]$nvme.lanes
    $nvmeSubnqn = Get-VMateNvmeSubnqn -Components $Components `
        -Uuid ([string]$Profile.identity.uuid)
    Assert-VMateComponentSerial $storage `
        ([string]$Profile.identity.nvme_serial) 'SSD'
    $storageIdentityProfile = ConvertTo-VMateQemuString `
        ([string]$storage.identity_profile)
    $storageModel = ConvertTo-VMateQemuString ([string]$storage.model)
    $storageFirmware = ConvertTo-VMateQemuString ([string]$storage.firmware)
    $keyboardManufacturer = ConvertTo-VMateQemuString ([string]$keyboard.manufacturer)
    $keyboardName = ConvertTo-VMateQemuString ([string]$keyboard.product)
    $mouseManufacturer = ConvertTo-VMateQemuString ([string]$mouse.manufacturer)
    $mouseName = ConvertTo-VMateQemuString ([string]$mouse.product)
    $arguments = [System.Collections.Generic.List[string]]::new()
    $commonPort = 'hotplug=off,x-pci-vendor-id={0},x-pci-revision={1}' -f
        $rootVendor, $rootRevision
    $audioController = if ($isCompatibility) {
        'ich9-intel-hda,id=hda,bus=pcie.0,addr=0x4'
    } else {
        "intel-hda,id=hda,bus=pcie.0,addr=0x4,x-pci-vendor-id=$audioVendor,x-pci-device-id=$audioDevice"
    }
    $audioCodec = if ($isCompatibility) {
        'hda-duplex,bus=hda.0'
    } else {
        "hda-duplex,bus=hda.0,x-identity-compat=on,x-codec-id=$codecId,x-codec-revision=$codecRevision,x-codec-subsystem-id=$codecSubsystem"
    }
    Add-VMateArgument $arguments @(
        '-device', "pcie-root-port,id=rp1,slot=1,bus=pcie.0,addr=0x1,x-speed=$nvmeSpeed,x-width=$nvmeWidth,$commonPort,x-pci-device-id=$($rootDevices[0])",
        '-device', "pcie-root-port,id=rp2,slot=2,bus=pcie.0,addr=0x2,x-speed=2_5,x-width=1,$commonPort,x-pci-device-id=$($rootDevices[1])",
        '-device', "pcie-root-port,id=rp3,slot=3,bus=pcie.0,addr=0x3,x-speed=2_5,x-width=1,$commonPort,x-pci-device-id=$($rootDevices[2])",
        '-drive', "file=$Disk,if=none,id=nvm0,format=qcow2,cache=none,aio=threads,discard=unmap,detect-zeroes=unmap",
        '-device', "nvme,id=nvmectl0,bus=rp1,drive=nvm0,x-identity-profile=$storageIdentityProfile,serial=$($Profile.identity.nvme_serial),model-number=$storageModel,firmware-rev=$storageFirmware,subsys-vendor-id=$storageSubVendor,subsys-id=$storageSubDevice,subnqn=$nvmeSubnqn",
        '-netdev', "user,id=net0,hostfwd=tcp:127.0.0.1:$SshForwardPort-:22,hostfwd=tcp:127.0.0.1:$RdpForwardPort-:3389",
        # Intel Gigabit CT Desktop Adapter 按独立扩展卡建模；板载 NIC 状态和
        # subsystem/OUI 已作为同一 manifest 设备原子校验，不能在此另写常量。
        '-device', "e1000e,id=nic0,netdev=net0,bus=rp2,mac=$($Profile.identity.mac),subsys_ven=$nicSubVendor,subsys=$nicSubDevice",
        # qemu-xhci 的 PCI ID 是 USBXHCI.SYS 选择硬件 quirk 的行为契约。保留
        # 上游完整身份，不能把 manifest 的 Intel/AMD PCH ID 套到虚拟寄存器模型。
        '-device', 'qemu-xhci,id=xhci,bus=rp3',
        # 中文注释：与 Linux 启动器保持同一键盘实例名和 NumLock 策略。QEMU 只会在
        # guest 明确回报 LED 为 OFF 时异步补发一次按键，不会在未知状态下盲目切换。
        '-device', "usb-kbd,id=kbd0,bus=xhci.0,vendorid=$keyboardVendor,productid=$keyboardProduct,manufacturer=$keyboardManufacturer,product=$keyboardName,x-force-numlock-on=on",
        '-device', "usb-mouse,bus=xhci.0,vendorid=$mouseVendor,productid=$mouseProduct,manufacturer=$mouseManufacturer,product=$mouseName",
        # 00:04.0 是 manifest 的 Windows Q35 观测布局；显式 pin 地址，避免设备
        # 顺序变化后 QEMU 自动分配到其它槽位而清单仍误报一致。
        '-device', $audioController,
        '-device', $audioCodec
    )
    return $arguments.ToArray()
}

function New-VMateChipsetArguments {
    param([object]$Platform)

    $arguments = [System.Collections.Generic.List[string]]::new()
    if (Test-VMateCompatibilityPlatform -Platform $Platform) {
        # generic Q35 兼容模板使用 machine 自身的 ICH9 身份。物理平台所需的
        # PCH/subsystem 覆盖在这里必须完全禁用，否则又会形成品牌混搭。
        return $arguments.ToArray()
    }
    $chipset = $Platform.devices.chipset
    $subVendor = Assert-VMateHexId $Platform.board.subsystem_vendor `
        'board.subsystem_vendor'
    $subDevice = Assert-VMateHexId $Platform.board.subsystem_device `
        'board.subsystem_device'
    # 中文注释：Q35 MCH 的 8086:29c0 是 EDK2 PlatformPei 识别 machine type
    # 的启动契约。把清单中的 H310/H110 MCH ID 注入 q35-pcihost 会使 OVMF
    # 在固件早期 CpuDeadLoop；这里只投影可安全覆盖的 PCH 功能。
    $definitions = @(
        @('lpc', 'ICH9-LPC', 'x-pci-'),
        @('smbus', 'ICH9-SMB', 'x-pci-'),
        @('ahci', 'ich9-ahci', 'x-pci-')
    )
    foreach ($definition in $definitions) {
        $name = [string]$definition[0]
        $type = [string]$definition[1]
        $prefix = [string]$definition[2]
        if (-not (Test-VMateJsonProperty $chipset $name)) {
            throw "平台 '$($Platform.id)' 缺少 devices.chipset.$name。"
        }
        $identity = @($chipset.$name)
        if ($identity.Count -ne 3) {
            throw "devices.chipset.$name 必须是 vendor/device/revision 三元组。"
        }
        $vendor = Assert-VMateHexId $identity[0] "devices.chipset.$name[0]"
        $device = Assert-VMateHexId $identity[1] "devices.chipset.$name[1]"
        $revision = Assert-VMateHexId $identity[2] "devices.chipset.$name[2]"
        Add-VMateArgument $arguments @(
            '-global', "$type.${prefix}vendor-id=$vendor",
            '-global', "$type.${prefix}device-id=$device",
            '-global', "$type.${prefix}revision=$revision",
            '-global', "$type.${prefix}sub-vendor-id=$subVendor",
            '-global', "$type.${prefix}sub-device-id=$subDevice"
        )
    }
    return $arguments.ToArray()
}

function Get-VMateRtcArgument {
    param([string]$GuestOs)

    if ($GuestOs -like 'Windows*') {
        return 'base=localtime,clock=host,driftfix=slew'
    }
    return 'base=utc,clock=host,driftfix=slew'
}
