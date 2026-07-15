# `vms/<N>/profile` 字段参考

每台 VM 首次启动时，从版本化 manifest 选择一套完整整机和组件模板，再生成该实例的
序列号、UUID、MAC 等唯一值，原子写入 `$IMAGE_ROOT/vms/<N>/profile`。后续启动复用同一文件，
避免硬件身份随重启漂移。

新 profile 的事实源只有：

- [`deploy/hardware/platforms.json`](../hardware/platforms.json)：整机平台。
- [`deploy/hardware/components.json`](../hardware/components.json)：NVMe、EDID 和 USB HID。

当前两份 manifest 都是 schema 1；目录修订号分别为 `2026-07-13.4` 和
`2026-07-13.1`。修订号是 profile 绑定的一部分，不应手工伪造。

## 格式与安全

profile 是每行一个 `KEY=VALUE` 的受限数据文件，不是 shell 脚本：

- 保存器只写白名单字段，使用临时文件原子替换，并将权限设为 0600。
- 加载器逐行解析，不 `source`、不 `eval`；未登记 key 会跳过。
- 包含命令替换、反引号或参数展开构造的值会被拒绝。
- `STRICT_HARDWARE=1` 时，schema、目录修订号、平台/组件 ID 以及事实字段必须与当前
  manifest 完全一致；缺字段、篡改和 legacy profile 都会失败。

序列号类字段允许每实例不同；平台事实字段不能脱离其 bundle 单独更改。profile 变化还可能
触发 Windows 激活或设备重枚举，生产环境不要直接编辑。

## 目录绑定

| 字段 | 含义 |
|---|---|
| `PLATFORM_SCHEMA_VERSION` | 整机 manifest schema；当前为 `1` |
| `PLATFORM_CATALOG_REVISION` | `platforms.json` 修订号 |
| `PLATFORM_ID` | 被选中的完整整机 bundle ID |
| `PLATFORM_STATUS` | 默认新 profile 优先选择 `supported`；显式 allow 授权后可在无 supported 候选时持久化 `compatibility`，但不表示目标 PCH machine/BDF 等价 |
| `PLATFORM_RELEASE_YEAR` | 整机模板年代约束 |
| `COMPONENT_SCHEMA_VERSION` | 组件 manifest schema；当前为 `1` |
| `COMPONENT_CATALOG_REVISION` | `components.json` 修订号 |

当前启用的 `PLATFORM_ID` 只有：

- `intel-lga1151-i3-9100f-asus-prime-h310m-a-r2`
- `intel-lga1151-i5-6400t-asus-h110m-a-m2`

AMD/B350 条目为禁用的 `compatibility` 资料，不进入默认候选池。显式传入
`--allow-platform-compatibility` 后，启动器按宿主 CPU vendor、`CPUS`、最大频率和 TSC
约束自动匹配：优先使用 `supported`，仅在没有可用 `supported` 候选时回退到
`compatibility`。已有 profile 复用其 `PLATFORM_ID`；`--platform-id` 可选，只用于高级固定
或一致性断言。allow 不会把 `STRICT_HARDWARE` 改成 `0`，也不会关闭 KVM/TSC、
CPU realize、组件绑定、磁盘，或请求 `TPM=1` 时的 TPM 严格门禁。

## CPU

| 字段 | 含义 / 可见面 |
|---|---|
| `CPU_QEMU_ARG` | manifest 中的 QEMU named-model、family/model/stepping 和 model-id 前缀 |
| `CPU_MODEL` | `CPU_QEMU_ARG` 的模型主名，用于摘要和兼容逻辑 |
| `CPU_VENDOR`、`CPU_NAME` | CPUID vendor 与品牌串；映射到客体处理器名称 |
| `CPU_CORES`、`CPU_THREADS` | 完整 SKU 拓扑；当前均为 4C/4T，`CPUS` 必须等于完整线程数 |
| `CPU_MAX_MHZ`、`CPU_CUR_MHZ` | SMBIOS Type 4 最大/当前频率 |
| `CPU_TSC_MHZ` | 目标 invariant TSC；受 KVM TSC scaling/实测频率硬约束 |
| `CPU_PHYS_BITS` | 客体物理地址位数 |
| `CPU_FEATURES` | bundle 允许的附加 CPUID 特性 |
| `CPU_SOCKET` | 目标桌面 CPU 插槽；与主板 bundle 绑定，当前为 LGA1151 |
| `CPU_PART` | SMBIOS Type 4 part number |
| `CPU_PROC_FAMILY` | SMBIOS Type 4 processor family |
| `CPU_SMBIOS_UPGRADE` | SMBIOS Type 4 processor upgrade/socket 编码 |
| `CPU_SMBIOS_VOLTAGE` | SMBIOS Type 4 电压，单位 mV |
| `CPU_SMBIOS_EXT_CLOCK` | SMBIOS Type 4 external clock，单位 MHz |
| `CPU_SMBIOS_CHARACTERISTICS` | SMBIOS Type 4 characteristics 位图 |
| `CPU_IGPU_PRESENT`、`CPU_IGPU_STATE`、`CPU_IGPU_MODEL` | 核显是否存在、熔断/BIOS 禁用状态和型号 |
| `CPU_SERIAL`、`CPU_ASSET` | 每实例持久化的 Type 4 serial/asset tag |

宿主厂商、最大频率和 TSC 只是候选过滤。严格启动还会用最终 `-cpu` 串和 `enforce=on`
实际创建最小 KVM vCPU；Broadwell/E5 宿主不能仅凭字段匹配获得支持结论。

## 主板、系统、BIOS 与机箱

| 字段组 | 字段 | 含义 |
|---|---|---|
| 主板事实 | `BOARD_MFR`、`BOARD_PRODUCT`、`BOARD_FAMILY`、`BOARD_VERSION` | SMBIOS Type 2 身份 |
| 主板能力 | `BOARD_DIMM_SLOTS`、`BOARD_MAX_MEMORY_GIB`、`PCH_MODEL`、`PCIE_GENERATION` | 槽位、容量、PCH 和 PCIe 代际限制 |
| PCI 子系统 | `BOARD_SUBSYS_VEN`、`BOARD_SUBSYS_DEV` | 主板相关控制器的 subsystem vendor/device |
| 主板唯一值 | `BOARD_SERIAL`、`BOARD_ASSET` | 每实例 Type 2 serial/asset |
| 系统事实 | `SYSTEM_MFR`、`SYSTEM_PRODUCT`、`SYSTEM_FAMILY`、`SYSTEM_VERSION` | SMBIOS Type 1 |
| 系统唯一值 | `SYSTEM_SERIAL`、`SYSTEM_SKU`、`UUID` | 每实例 Type 1/系统 UUID |
| BIOS | `BIOS_VENDOR`、`BIOS_VERSION`、`BIOS_DATE` | SMBIOS Type 0；与同一平台 bundle 绑定 |
| 机箱 | `SYSTEM_CHASSIS_TYPE`、`CHASSIS_TYPE`、`CHASSIS_SERIAL` | manifest 机箱编码、兼容文本和 Type 3 serial |

当前 ASUS H110/H310 bundle 的 CPU、主板、BIOS 和 PCH 不能交叉抽签。`BOARD_SUBSYS_*`
也不能按厂商名称猜测后单独替换。

## 芯片组、PCIe 与 USB 控制器

| 字段 | 含义 |
|---|---|
| `MCH_PCI_VEN`、`MCH_PCI_DEV`、`MCH_REV` | MCH PCI vendor/device/revision |
| `LPC_PCI_VEN`、`LPC_PCI_DEV`、`LPC_REV` | LPC bridge PCI 身份 |
| `SMBUS_PCI_VEN`、`SMBUS_PCI_DEV`、`SMBUS_REV` | SMBus controller PCI 身份 |
| `AHCI_PCI_VEN`、`AHCI_PCI_DEV`、`AHCI_REV` | AHCI controller PCI 身份 |
| `ROOT_PORT_PCI_VEN`、`ROOT_PORT_PCI_DEV`、`ROOT_PORT_REV` | PCIe root port 基础身份；各端口按规则派生 device ID |
| `XHCI_PCI_VEN`、`XHCI_PCI_DEV`、`XHCI_REV` | xHCI controller PCI 身份 |

这些字段描述 PCI configuration identity；底层寄存器和行为仍是 Q35/ICH9、QEMU root port
和 qemu-xhci，不等同于真实 H110/H310 silicon。这个行为边界是整份目录的全局事实，写在
`platforms.json.fidelity`，不作为每实例随机字段重复保存：

| 启动器 | 当前 Q35 root bus BDF |
|---|---|
| Linux | MCH `00:00.0`；root port `00:01.0`–`00:04.0`；额外 HDA `00:05.0`；LPC/AHCI/SMBus `00:1f.0/.2/.3` |
| Windows | MCH `00:00.0`；root port `00:01.0`–`00:03.0`；额外 HDA `00:04.0`；LPC/AHCI/SMBus `00:1f.0/.2/.3` |

两条路径的 HDA 都由 Q35 root bus 在 root port 之后自动分配；端口数量不同，所以地址不同。
这些地址有真实 `query-pci` 回归，但它们证明的是“当前 Q35 布局稳定”，不是“匹配目标
H110/H310 固定功能布局”。

## 网卡与音频

| 字段 | 含义 |
|---|---|
| `NIC_VENDOR`、`NIC_MODEL` | 当前为 Intel 82574L 扩展网卡画像 |
| `NIC_PCI_VEN`、`NIC_PCI_DEV` | e1000e 主 PCI 身份 |
| `NIC_SUBSYSTEM_VEN`、`NIC_SUBSYSTEM_DEV` | 网卡自身 subsystem；当前为 `8086:a01f` |
| `NIC_MAC_OUI`、`NIC_MAC` | Intel OUI 与每实例随机后缀；不使用 QEMU `52:54:00` OUI |
| `NIC_ATTACHMENT`、`BOARD_NIC_STATE` | 扩展卡连接方式及主板网卡 BIOS 禁用状态 |
| `AUDIO_VENDOR`、`AUDIO_CODEC` | 当前 Realtek ALC887 画像 |
| `AUDIO_CODEC_ID`、`AUDIO_CODEC_REVISION`、`AUDIO_CODEC_SUBSYSTEM_ID` | HDA codec ID/revision/subsystem |
| `AUDIO_CONTROLLER_PCI_VEN`、`AUDIO_CONTROLLER_PCI_DEV` | HDA controller PCI 身份 |
| `AUDIO_IDENTITY_FIDELITY` | 当前固定为 `protocol_identity_only` |

`protocol_identity_only` 表示只对协议身份和主要枚举字段负责，不承诺真实 ALC887 widget、
插孔检测、放大器、板级布线或声音路径。

## NVMe 与磁盘容量

平台提供连接能力，组件提供具体物料，二者会同时校验：

| 字段组 | 字段 | 含义 |
|---|---|---|
| 平台 M.2 | `NVME_MAX_PCIE_GENERATION`、`NVME_LANES` | 主板插槽最大 PCIe 代际/通道数 |
| 平台 M.2 | `NVME_BOOT_SUPPORTED`、`NVME_ATTACHMENT` | 是否可启动及 `m2_socket` 连接方式 |
| 组件绑定 | `NVME_COMPONENT_ID` | 当前唯一为 `samsung-970-pro-512gb` |
| Identify | `NVME_MODEL`、`NVME_FIRMWARE`、`NVME_SERIAL` | 当前型号、固件 `1B2QEXP7` 和每实例 serial |
| 容量 | `NVME_SIZE_BYTES` | 当前 `512110190592`；必须等于 qcow2 guest-visible virtual-size |
| PCI | `NVME_PCI_VEN`、`NVME_PCI_DEV` | 当前 `144d:a804` |
| PCI subsystem | `NVME_SUBSYS_VEN`、`NVME_SUBSYS_DEV` | 当前 `144d:a801` |
| NQN | `NVME_SUBNQN_TEMPLATE`、`NVME_SUBNQN` | Samsung 模板和代入 serial 后的最终 SubNQN |

主板链路能力可以低于 SSD 的 Gen3 x4 额定能力，例如 H310 模板为 Gen2 x2；这是可解释的
降速连接。不能把 970 PRO 的字符串与其它控制器 PCI ID、容量或固件混用。

## 内存、DIMM、SPD 与 NUMA

| 字段 | 含义 |
|---|---|
| `MEM_TOTAL_MB` | 持久化总内存；新 profile 默认 8192 MiB |
| `MEM_TYPE`、`MEM_CHANNELS` | 当前 DDR4、双通道能力 |
| `MEM_ALLOWED_TOTAL_MB` | 当前平台允许的总量：`2048,4096,8192` |
| `MEM_MODULE_MB` | 允许的单条容量：`2048,4096` |
| `MEM_MAX_CAPACITY_MB` | 主板最大内存容量 |
| `MEM_MAX_MTS`、`MEM_ALLOWED_MTS` | 平台控制器上限和允许速率 |
| `MEM_MFR`、`MEM_PART_2G`、`MEM_PART_4G` | DIMM 厂商及 2/4 GiB part number |
| `MEM_RATED`、`MEM_RATED_MTS` | DIMM 料号额定 MT/s；两字段保持相等，前者仅为旧 profile 兼容名 |
| `MEM_CONFIGURED_MTS` | 主板/CPU 训练后的实际 MT/s，必须属于平台允许集合且不高于额定值 |
| `MEM_VOLTAGE_MV`、`MEM_RANK` | SMBIOS Type 17 电压和 rank |
| `MEM_SERIAL` | 第一条 DIMM 的持久化 8 位十六进制 serial |

运行时由这些字段派生拓扑，不另存 `NUM_DIMMS`/`PER_DIMM_MB`：

| 总量 | DIMM/SPD | 通道 | guest NUMA |
|---:|---|---|---|
| 2048 MiB | 1×2 GiB | 单通道 | 1 node |
| 4096 MiB | 1×4 GiB | 单通道 | 1 node |
| 8192 MiB | 2×4 GiB | 双通道 | 1 node |

SMBIOS Type 17 的 `Speed` 使用 `MEM_RATED_MTS`，`Configured Memory Speed` 使用
`MEM_CONFIGURED_MTS`；Q35 SPD 的 tCKmin 只使用额定速率。例如 DDR4-2400 DIMM 在 H110/
i5-6400T 上仍报告 `Speed=2400`，但 `Configured Memory Speed=2133`。Windows JSON profile
使用同义字段 `identity.memory_rated_mts` 与 `configuration.memory_configured_mts`。

当前 DDR4 SPD 只实现可访问的 256 字节 page 0 地址空间，byte 0 因而声明 256B used/
256B total，并按 2/4/8Gb 颗粒生成地址几何和 tRFC。它不是完整 EE1004 512B 器件，也不包含
所选品牌 DIMM 的原始 page 1 厂商/序列号/料号 dump；这些身份目前由 SMBIOS Type 17 表达。

第二条 DIMM serial 由 `sha256("${MEM_SERIAL}-dimm2")` 前 8 位稳定派生。双 DIMM 不等于
双 NUMA；当前消费级单 socket 客体始终只创建一个 guest NUMA node。宿主双路 E5 的 NUMA
仅影响 vCPU/内存放置，不改变客体这一拓扑。

## 显示器 EDID

| 字段组 | 字段 |
|---|---|
| 组件和基础身份 | `EDID_COMPONENT_ID`、`EDID_VENDOR`、`EDID_PRODUCT_ID`、`EDID_NAME`、`EDID_SERIAL` |
| 物理参数 | `EDID_WIDTH_MM`、`EDID_HEIGHT_MM`、`EDID_MANUFACTURE_WEEK`、`EDID_MANUFACTURE_YEAR`、`EDID_VIDEO_INPUT` |
| 范围限制 | `EDID_MIN_VFREQ_HZ`、`EDID_MAX_VFREQ_HZ`、`EDID_MIN_HFREQ_KHZ`、`EDID_MAX_HFREQ_KHZ`、`EDID_MAX_PIXEL_CLOCK_MHZ` |
| 第二时序 | `EDID_SECONDARY_XRES`、`EDID_SECONDARY_YRES`、`EDID_SECONDARY_REFRESH_RATE` |

当前组件固定为 `samsung-s24f350`：`SAM/0F65`、530×300 mm、2018 年第 32 周、
50–75 Hz、30–83 kHz、170 MHz，第二时序 1600×900@60 Hz。只有 `EDID_SERIAL`
按实例生成；其它字段必须整体一致。

## USB HID

三个设备使用同一字段结构：

| 设备 | 字段 | 当前模板 / fidelity |
|---|---|---|
| 键盘 | `KBD_COMPONENT_ID`、`KBD_VID`、`KBD_PID`、`KBD_MFR`、`KBD_PRODUCT`、`KBD_SERIAL`、`KBD_BCD_DEVICE`、`KBD_DESCRIPTOR_FIDELITY` | Microsoft Wired Keyboard 600，`045e:0750/0163`，`fixed_template` |
| 鼠标 | `MOUSE_COMPONENT_ID`、`MOUSE_VID`、`MOUSE_PID`、`MOUSE_MFR`、`MOUSE_PRODUCT`、`MOUSE_SERIAL`、`MOUSE_BCD_DEVICE`、`MOUSE_DESCRIPTOR_FIDELITY` | Microsoft USB Optical Mouse，`045e:00cb/0163`，`fixed_template` |
| 绝对指针 | `TABLET_COMPONENT_ID`、`TABLET_VID`、`TABLET_PID`、`TABLET_MFR`、`TABLET_PRODUCT`、`TABLET_SERIAL`、`TABLET_BCD_DEVICE`、`TABLET_DESCRIPTOR_FIDELITY` | QEMU USB Tablet，`0627:0001/0000`，`generic_virtual_only` |

键盘和鼠标模板声明 `serial_exposed=false`，启动器不会把 profile 中的稳定派生 serial 送入
USB descriptor。默认 tablet 也不暴露品牌或 serial；它只实现通用绝对坐标协议，不能改名为
HUION、VEIKK 或 XP-Pen。

## GPU 字段及范围声明

`GPU_VENDOR`、`GPU_NAME`、`GPU_PCI_VEN`、`GPU_PCI_DEV`、`GPU_RAM_MB`、`GPU_BIOS`、
`GPU_REV` 是历史显示标签兼容字段。下列字段与同一 `GPU_POOL` 行绑定，
用于 guest schema-2 用户态身份快照：

| host profile | guest 注册表 | 单位 / 约束 |
|---|---|---|
| `GPU_MEMORY_TYPE` | `SpoofMemoryType` | 当前池为 `GDDR5` |
| `GPU_MEMORY_BUS_WIDTH_BITS` | `SpoofMemoryBusWidthBits` | bit；32–1024 的 2 次幂，当前型号为 64/128 |
| `GPU_BASE_CLOCK_KHZ` | `SpoofBaseClockKHz` | kHz；100000–5000000 |
| `GPU_BOOST_CLOCK_KHZ` | `SpoofBoostClockKHz` | kHz；100000–5000000，且不小于 base |
| `GPU_MEMORY_CLOCK_KHZ` | `SpoofMemoryClockKHz` | NVAPI clock-domain kHz；100000–10000000 |
| `GPU_SLI_SUPPORTED` | `SpoofSliSupported` | 仅允许 `0`；浅层实现为单 GPU、非 SLI |

GTX 1050 Ti bundle 固定为 `GDDR5 / 128 bit / 1290000 / 1392000 /
3504000 kHz / SLI=0`。其中 memory clock 按 NVAPI 口径保存；GPU-Z 显示为
1752 MHz，不应把包装标注的 7 Gbps 写入该字段。严格 profile 缺少任一
新字段都会 fail-closed；旧 profile 的运行时补值只服务显式非严格诊断。

`GPU_IDENTITY_FIDELITY` 仍必须为 `label_only_out_of_scope`。

本分支不做 GPU passthrough 或 vGPU；virtio-vga(-gl) 的主设备、驱动和行为不会因为这些
标签变成真实 NVIDIA/AMD GPU。显存与时钟也是用户态查询投影，不代表
客体可以访问该容量或达到该频率。这组字段不得计入真机化完成度或硬件支持承诺。

## 生命周期操作

```bash
# 查看当前 profile（不要 source）
sed -n '1,220p' /home/ubuntu/images/vms/1/profile

# 改为 manifest 允许的 8 GiB；只改变 MEM_TOTAL_MB，重启生效
deploy/scripts/set-vm-memory.sh 1 8G

# 显式重新生成整套身份；会改变 UUID/序列号/MAC，并可能触发 Windows 重新激活
deploy/scripts/reroll-identity.sh 1
# 也可在下一次启动时执行
deploy/scripts/start-vm.sh 1 --reroll
```

启动器会先把 reroll 结果保留在进程内存，依次通过宿主约束、CPU realize、磁盘容量、
所请求 TPM、内存/设备参数和完整 QEMU argv 组装后才原子替换 profile。尤其是旧 1TB
磁盘与当前 512GB NVMe 模板不符时，启动会失败但旧 profile 哈希保持不变。

非严格模式会为部分旧 profile 提供兼容默认值，但必须另加
`--allow-legacy-profile` 明确授权，而且这不代表旧的 AMD/B350、混合 NVMe/EDID/HID
画像已通过审计。迁移到当前严格目录应显式 reroll，并在测试实例上先验证激活、驱动和磁盘容量。
新建的 schema 1 AMD compatibility profile 与 legacy profile 不同：它会完整绑定目录事实，
后续启动会复用其 `PLATFORM_ID`，但仍须每次显式携带 allow 开关，且不能计为真实
B350 machine 验收。
