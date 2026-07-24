# `vms/<N>/profile` 字段参考

每台 VM 首次启动时，从版本化 manifest 选择一套完整整机和组件模板，再生成该实例的
序列号、UUID、MAC 等唯一值，原子写入 `$IMAGE_ROOT/vms/<N>/profile`。后续启动复用同一文件，
避免硬件身份随重启漂移。

新 profile 的事实源只有：

- [`deploy/hardware/platforms.json`](../hardware/platforms.json)：整机平台。
- [`deploy/hardware/household-compatibility.json`](../hardware/household-compatibility.json)：
  E5/AMD 宿主可塑造的家用 CPU 完整兼容组合。
- [`deploy/hardware/host-compatibility.json`](../hardware/host-compatibility.json)：
  仅限 2C2T/2C4T/4C4T 家用物理宿主的 generic Q35 host 模板。
- [`deploy/hardware/components.json`](../hardware/components.json)：可更换部件入口、EDID
  和 USB HID。
- [`deploy/hardware/gpu-boards.json`](../hardware/gpu-boards.json)：6 个芯片型号各
  3 个板卡品牌，共 18 块启用 AIB 的 21 列原子身份，由组件入口引用。
- [`deploy/hardware/storage.json`](../hardware/storage.json)：四款精确 512GB NVMe
  的独立事实目录，由组件入口引用。
- [`deploy/hardware/storage-compatibility.json`](../hardware/storage-compatibility.json)：
  无原生 NVMe boot 的老主板可用的消费级 SATA 启动盘完整组合。

当前目录都是 schema 1；整机为 `2026-07-22.1`，household 为
`2026-07-19.6`，组件、GPU AIB 与 NVMe 子目录为 `2026-07-24.1`，SATA 启动盘为
`2026-07-19.1`。
修订号用于绑定或迁移诊断，不应手工伪造。

## 格式与安全

profile 是每行一个 `KEY=VALUE` 的受限数据文件，不是 shell 脚本：

- 保存器只写白名单字段，使用临时文件原子替换，并将权限设为 0600。
- 加载器逐行解析，不 `source`、不 `eval`；未登记 key 会跳过。
- 包含命令替换、反引号或参数展开构造的值会被拒绝。
- `STRICT_HARDWARE=1` 时，schema、平台/组件 ID 及其事实字段必须按对应 manifest
  重建校验；缺字段、篡改和未授权 legacy profile 都会失败。SATA 目录修订号仅用于
  诊断/迁移，扩池不会使已持久化且条目事实未变的旧 VM 失效。

序列号类字段允许每实例不同；平台事实字段不能脱离其 bundle 单独更改。profile 变化还可能
触发 Windows 激活或设备重枚举，生产环境不要直接编辑。

## 目录绑定

| 字段 | 含义 |
|---|---|
| `PLATFORM_SCHEMA_VERSION` | 整机 manifest schema；当前为 `1` |
| `PLATFORM_CATALOG_REVISION` | `platforms.json` 修订号 |
| `PLATFORM_ID` | 被选中的完整整机 bundle ID |
| `PLATFORM_STATUS` | E5 v3/v4 的 Haswell 家用正常池及普通启用整机为 `supported`；其余候选需显式 allow 才可持久化 `compatibility`。两种状态都不表示目标 PCH machine/BDF 等价 |
| `PLATFORM_RELEASE_YEAR` | 整机模板年代约束 |
| `PLATFORM_CPU_SOURCE` | `manifest`、`named-household-compatibility` 或受限 `host-passthrough` |
| `PLATFORM_MACHINE_MODEL`、`PLATFORM_IDENTITY_SCOPE`、`PLATFORM_DEVICE_IDENTITY_SCOPE`、`PLATFORM_SMBIOS_POLICY` | Q35、SMBIOS 和设备身份的实现边界 |
| `PLATFORM_HOST_CLASSES` | household 候选允许的 E5 v1-v4/K10/Zen 宿主类 |
| `PLATFORM_BOOT_STORAGE_POOL_ID` | 平台绑定的启动盘池；当前为 `component-nvme` 或 `samsung-sata-pro-512gb` |
| `PLATFORM_BOOT_STORAGE` | 主板能力决定的实际启动总线：`nvme` 或 `sata-ahci` |
| `PLATFORM_BOOT_MODEL`、`PLATFORM_BOOT_FIRMWARE` | 平台策略标记；NVMe 为 `component`，SATA 为 `storage-compatibility-pool`，不是 Guest 可见型号/固件 |
| `PLATFORM_STORAGE_SWITCH_REQUIRED`、`NVME_ROLE` | 是否必须切换到 SATA，以及 NVMe 是 boot 或 data-only |
| `COMPONENT_SCHEMA_VERSION` | 组件 manifest schema；当前为 `1` |
| `COMPONENT_CATALOG_REVISION` | `components.json` 修订号 |

TPM 也是整机平台事实，不再由启动器固定成同一种设备：

| 字段 | 含义 |
|---|---|
| `TPM_CAPABILITY` | 主板能力：`firmware`、`discrete` 或 `none` |
| `TPM_SUPPORTED` | 当前平台是否支持 TPM，保存为 `1`/`0` |
| `TPM_IMPLEMENTATION` | `intel-ptt`、`amd-ftpm`、`discrete-module` 或 `none` |
| `TPM_VERSION` | 客体应看到的 `1.2`、`2.0` 或 `none` |
| `TPM_FRONTEND` | QEMU 前端：`tpm-tis`、`tpm-crb` 或 `none` |
| `TPM_PCR_BANKS` | 逗号分隔 PCR bank；TPM 1.2 仅允许 `sha1` |

新 profile 会持久化以上六项并参与 manifest 事实校验。升级前已经存在的 schema-1
profile 若六项全部缺失，加载器只按同一个 `PLATFORM_ID` 从已校验目录补齐；若只缺一部分，
则按截断或篡改处理并拒绝。`TPM=auto` 只决定本次是否启用平台声明的 TPM，不会改写这些事实。

当前启用的 `PLATFORM_ID` 有：

- `intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2`
- `intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2`
- `intel-lga1151-i3-9100f-asus-prime-h310m-a-r2`
- `intel-lga1151-i5-6400t-asus-h110m-a-m2`

AMD/B350 与独立 household 条目为 `compatibility`，不进入默认候选池。显式传入
`--allow-platform-compatibility` 后，启动器按宿主 vendor、CPUID 代际和完整拓扑匹配：
优先使用 `supported`，仅在没有可用正常候选时回退。已有 profile 复用其
`PLATFORM_ID`；`--platform-id` 可选，只用于高级固定
或一致性断言。allow 不会把 `STRICT_HARDWARE` 改成 `0`，也不会关闭 KVM/TSC、
CPU realize、组件绑定、磁盘，或请求 `TPM=1` 时的 TPM 严格门禁。

## CPU

| 字段 | 含义 / 可见面 |
|---|---|
| `CPU_QEMU_ARG` | manifest 中的 QEMU named-model、family/model/stepping 和 model-id 前缀 |
| `CPU_MODEL` | `CPU_QEMU_ARG` 的模型主名，用于摘要和兼容逻辑 |
| `CPU_VENDOR`、`CPU_NAME` | CPUID vendor 与品牌串；映射到客体处理器名称 |
| `CPU_CORES`、`CPU_THREADS` | 完整 SKU 拓扑；只允许 2C2T、2C4T、4C4T，`CPUS` 必须等于完整线程数 |
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
| `CPU_HOST_FAMILY`、`CPU_HOST_MODEL`、`CPU_HOST_STEPPING`、`CPU_HOST_CORES`、`CPU_HOST_ONLINE_THREADS`、`CPU_HOST_PHYS_BITS`、`CPU_HOST_TSC_KHZ`、`CPU_HOST_FINGERPRINT` | 仅 host-passthrough profile 使用的当前宿主强绑定；任一变化都拒绝重载 |
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
| `XHCI_PCI_VEN`、`XHCI_PCI_DEV`、`XHCI_REV` | 目标平台 xHCI 事实；不投影到行为不同的 `qemu-xhci` PCI ID |

除明确标为“目标平台事实”的 xHCI 字段外，这些字段描述 PCI configuration identity；
底层寄存器和行为仍是 Q35/ICH9、QEMU root port 和 qemu-xhci，不等同于真实
H110/H310 silicon。xHCI 始终使用与虚拟模型匹配的上游
`1B36:000D rev01 / SUBSYS 1AF4:1100`。这个行为边界是整份目录的全局事实，写在
`platforms.json.fidelity`，不作为每实例随机字段重复保存：

### xHCI 电源管理边界

xHCI 参与的是 USB 子系统的正常电源管理，包括 USB 链路 `U0/U1/U2/U3`、设备挂起/
恢复和远程唤醒；控制器自身的 PCI `D0/D3` 状态及整机睡眠/唤醒仍由 PCIe、ACPI 和
操作系统电源框架协同完成，并不是“整机通过 USB 管理电源”。

Windows `USBXHCI.SYS` 会根据控制器硬件身份选择厂商/型号 workaround。只覆盖
vendor/device/revision 并不会让 `qemu-xhci` 获得 Intel A12F 的复位、LPM 或电源转换
语义，因此不能投影 `8086:A12F`。固定上游完整身份不会禁用 USB 电源管理，而是让客体
使用与虚拟寄存器模型匹配的通用 xHCI 路径。背景可参考 Microsoft 的
[USB 3.0 驱动栈架构](https://learn.microsoft.com/windows-hardware/drivers/usbcon/usb-3-0-driver-stack-architecture)。

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

## 启动盘、SATA/NVMe 与磁盘容量

平台只提供连接和启动能力，具体 Guest 可见启动盘由独立组件绑定。启动器根据主板
`NVME_BOOT_SUPPORTED` 自动选择路径：值为 `1` 时使用 NVMe；值为 `0` 时切换到
SATA/AHCI，不根据宿主或 Guest CPU 名称猜测存储能力。

| 字段组 | 字段 | 含义 |
|---|---|---|
| 平台 M.2 | `NVME_MAX_PCIE_GENERATION`、`NVME_LANES` | 主板插槽最大 PCIe 代际/通道数 |
| 平台 M.2 | `NVME_BOOT_SUPPORTED`、`NVME_ATTACHMENT` | 是否可启动及 `m2_socket` 连接方式 |
| 启动盘目录 | `BOOT_STORAGE_CATALOG_REVISION`、`BOOT_STORAGE_COMPONENT_ID` | 所选启动盘目录修订号与稳定条目 ID |
| 启动盘物料 | `BOOT_STORAGE_MANUFACTURER`、`BOOT_STORAGE_MODEL`、`BOOT_STORAGE_PART_NUMBER` | Guest 可见厂商/型号及对应零售料号 |
| 启动盘 Identify | `BOOT_STORAGE_FIRMWARE`、`BOOT_STORAGE_SERIAL` | Guest 可见固件与每实例独立持久化序列号 |
| 启动盘几何 | `BOOT_STORAGE_SIZE_BYTES`、`BOOT_STORAGE_INTERFACE` | qcow2 guest-visible 容量与实际接口 |
| 组件绑定 | `NVME_COMPONENT_ID` | `samsung-970-pro-512gb`、`intel-760p-512gb`、`wd-pc-sn730-512gb` 或 `kioxia-xg6-512gb` |
| Identify | `NVME_MODEL`、`NVME_FIRMWARE`、`NVME_SERIAL` | 所选条目的型号、固件和符合其厂商形态的每实例 serial |
| 容量 | `NVME_SIZE_BYTES` | 四个现行 NVMe component 均为精确 `512110190592` 字节；仅在 NVMe 作为启动盘时等于 qcow2 virtual-size |
| PCI | `NVME_PCI_VEN`、`NVME_PCI_DEV` | 依次为 `144d:a808`、`8086:f1a6`、`15b7:5006`、`1179:011a` |
| PCI subsystem | `NVME_SUBSYS_VEN`、`NVME_SUBSYS_DEV` | 与所选条目原子绑定的 subsystem |
| NQN | `NVME_SUBNQN_TEMPLATE`、`NVME_SUBNQN` | NVMe 标准 UUID 模板和代入持久 UUID 后的最终 SubNQN；不冒用厂商域名命名权 |

原生 NVMe 路径的 `BOOT_STORAGE_*` 与同一 `NVME_*` component 镜像并交叉校验。
主板链路能力可以低于 SSD 的 Gen3 x4 额定能力，例如 H310 模板为 Gen2 x2；这是
可解释的降速连接。不能把任一品牌的字符串与其它控制器 PCI ID、容量或固件混用。

无原生 NVMe boot 的 H61/B75/H81/AM3 平台从 `samsung-sata-pro-512gb` 池等概率选择
一个完整组合：

| ID | Guest 型号 | 料号 | 固件 | 接口 / 容量 |
|---|---|---|---|---|
| `samsung-840-pro-512gb-sata` | Samsung SSD 840 PRO 512GB | `MZ-7PD512BW` | `DXM06B0Q` | SATA 6 Gb/s / `512110190592` |
| `samsung-850-pro-512gb-sata` | Samsung SSD 850 PRO 512GB | `MZ-7KE512BW` | `EXM04B6Q` | SATA 6 Gb/s / `512110190592` |
| `samsung-860-pro-512gb-sata` | Samsung SSD 860 PRO 512GB | `MZ-76P512BW` | `RVM02B6Q` | SATA 6 Gb/s / `512110190592` |

选择只发生在首次创建 profile 或显式 reroll；所选 ID、型号、料号、固件、容量、接口和
独立 SATA serial 会作为 `BOOT_STORAGE_*` 原子持久化。普通重启按保存的 ID 从目录重建
并逐字段比较，不会再次抽签。SATA QEMU 参数和磁盘容量校验不读取或复用
`NVME_COMPONENT_ID`、`NVME_MODEL`、`NVME_FIRMWARE`、`NVME_SIZE_BYTES` 或
`NVME_SERIAL`。

独立 `BOOT_STORAGE_*` 发布前的 schema-1 profile 默认拒绝加载。只有全部新字段与
pool ID 在原文件中都缺失、平台 revision 早于其所属目录的 cutoff，并且旧
860 PRO/RVM02B6Q 序号/NQN 元组精确匹配时，`--migrate-storage-profile` 才允许
只读内存迁移。旧 ATA Identify serial 会原样保留；规范化后的 NVMe 身份及全部
启动盘目录事实仍执行当前严格绑定。加载器不会改写原 profile。

另有一个不改变 Guest 身份的窄元数据修复：`2026-07-19.6` profile 若完整绑定
当时唯一的 `samsung-970-pro-512gb`，且只有
`BOOT_STORAGE_PART_NUMBER=component-catalog` 这一内部占位值，加载器会把它
规范化为 `MZ-V7P512BW`。任何其它现行 component 即使伪造旧 revision
也不会命中；任何其它字段不一致同样拒绝。非 `DRY_RUN` 启动在全部严格门禁通过后，先创建
`profile.pre-catalog-migration.<原文件SHA-256>` 只读恢复副本，再原子保存规范化
结果。加载摘要、备份内容或 rename 前源摘要有任一变化都会 fail closed。

三项 SATA bundle 的型号、零售料号、接口和固件来自 Samsung 官方产品/固件资料，并声明
SATA 1.5/3/6 Gb/s 向下兼容；当前没有对应实物的 ATA IDENTIFY capture。因此 fidelity
仅为 `vendor-document-model-and-firmware-no-device-capture`，不能把生成的 Identify
内容描述成样机原始转储。

## 内存、DIMM、SPD 与 NUMA

| 字段 | 含义 |
|---|---|
| `MEM_TOTAL_MB` | 持久化总内存；新 profile 默认 8192 MiB |
| `MEM_TYPE`、`MEM_CHANNELS` | 随平台选择 DDR3/DDR4；当前目录均支持双通道 |
| `MEM_ALLOWED_TOTAL_MB` | 当前平台允许的总量：`2048,4096,8192` |
| `MEM_MODULE_MB` | 允许的单条容量：`2048,4096` |
| `MEM_MAX_CAPACITY_MB` | 主板最大内存容量 |
| `MEM_MAX_MTS`、`MEM_ALLOWED_MTS` | 平台控制器上限和允许速率 |
| `MEM_MFR`、`MEM_PART_2G`、`MEM_PART_4G` | DIMM 厂商及旧版系列视图；只有目录确有对应容量时才保存料号，否则为空 |
| `MEM_FAMILY_ID`、`MEM_MODULE_ID` | 物料系列和当前实际 DIMM 的稳定 ID；严格校验以 `MEM_MODULE_ID` 为权威 |
| `MEM_SELECTED_MODULE_MB`、`MEM_MODULE_COUNT`、`MEM_SPD_EE1004` | 单条容量、条数和 SPD EE1004 能力 |
| `MEM_RATED`、`MEM_RATED_MTS` | DIMM 料号额定 MT/s；两字段保持相等，前者仅为旧 profile 兼容名 |
| `MEM_CONFIGURED_MTS` | 主板/CPU 训练后的实际 MT/s，必须属于平台允许集合且不高于额定值 |
| `MEM_VOLTAGE_MV`、`MEM_RANK` | SMBIOS Type 17 电压；`MEM_RANK` 仅供旧 profile 回退 |
| `MEM_RANK_2G`、`MEM_DEVICE_WIDTH_2G` | 2 GiB 料号核验后的 rank 和单颗 DRAM 位宽 |
| `MEM_RANK_4G`、`MEM_DEVICE_WIDTH_4G` | 4 GiB 料号核验后的 rank 和单颗 DRAM 位宽 |
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

DDR4 SPD 实现完整 512 字节 EE1004 地址空间和 0x36/0x37 页选择，byte 0 声明
384B used/512B total，并按 2/4/8/16Gb 颗粒生成地址几何和 tRFC。page 1 的 JEP106
模组厂商码、唯一序列号和料号与 SMBIOS Type 17 使用同一份 profile 输入；当前覆盖硬件目录
中的 Crucial、Samsung、Kingston 和 SK hynix。该数据是按目录字段生成的标准 SPD，不是
具体 DIMM 的原始 raw dump，也不声明 XMP。只有取得官方精确 SPD 的 Samsung 模板写入
已核验 raw-card；其余短料号使用 JEDEC `ZZ`（未知）值，避免把批次相关 PCB revision
伪造成固定事实。

DDR3 继续使用标准 256 字节 SPD，模组厂商码、序列号和料号位于同一页；同样覆盖目录中的
Crucial、Kingston 和 SK hynix，并按具体 2/4 GiB 料号生成 rank、颗粒位宽与时序。

历史 `2026-07-19.6` profile 中曾把 Kingston 4 GiB 实际模块
`KVR24N17S8/4` 与一个未使用的 2 GiB 候选一起保存。只有平台、总量、插槽数、速率、
电压、rank、颗粒位宽和实际 2×4 GiB 拓扑全部精确命中该历史形态时，加载器才补入
稳定 `MEM_FAMILY_ID`/`MEM_MODULE_ID`，并清空不存在的 2 GiB 系列槽位；DIMM 厂商、
实际料号、容量、条数和序列号均不改变。其它旧内存组合继续 fail closed。保存时使用
与启动盘元数据修复相同的只读备份和原子提交机制；`DRY_RUN` 永不改写 profile。

迁移/快照目标必须使用与源端相同的 `spd-ee1004` 设备配置，这与其它 QEMU 设备拓扑参数
相同；已访问 SPD 的 256B/512B 状态错配会直接拒绝加载。

第二条 DIMM serial 由 `sha256("${MEM_SERIAL}-dimm2")` 前 8 位稳定派生。双 DIMM 不等于
双 NUMA；当前消费级单 socket 客体始终只创建一个 guest NUMA node。宿主双路 E5 的 NUMA
仅影响 vCPU/内存放置，不改变客体这一拓扑。

## 显示器 EDID

| 字段组 | 字段 |
|---|---|
| 组件和基础身份 | `EDID_COMPONENT_ID`、`EDID_VENDOR`、`EDID_PRODUCT_ID`、`EDID_NAME`、`EDID_SERIAL`、`EDID_BINARY_SERIAL`、`EDID_REVISION` |
| 物理参数 | `EDID_WIDTH_MM`、`EDID_HEIGHT_MM`、`EDID_MANUFACTURE_WEEK`、`EDID_MANUFACTURE_YEAR`、`EDID_VIDEO_INPUT` |
| 范围限制 | `EDID_MIN_VFREQ_HZ`、`EDID_MAX_VFREQ_HZ`、`EDID_MIN_HFREQ_KHZ`、`EDID_MAX_HFREQ_KHZ`、`EDID_MAX_PIXEL_CLOCK_MHZ` |
| 第二时序 | `EDID_SECONDARY_XRES`、`EDID_SECONDARY_YRES`、`EDID_SECONDARY_REFRESH_RATE` |
| 第二时序明细 | `EDID_SECONDARY_PIXEL_CLOCK_KHZ`、`EDID_SECONDARY_HFRONT`、`EDID_SECONDARY_HSYNC`、`EDID_SECONDARY_HBLANK`、`EDID_SECONDARY_VFRONT`、`EDID_SECONDARY_VSYNC`、`EDID_SECONDARY_VBLANK`、`EDID_SECONDARY_HSYNC_POSITIVE`、`EDID_SECONDARY_VSYNC_POSITIVE`、`EDID_SECONDARY_WIDTH_MM`、`EDID_SECONDARY_HEIGHT_MM` |

当前目录提供 `samsung-s24f350`、`aoc-24b2xh`、`xiaomi-rmmnt238nf` 和
`lenovo-l24e-30`，全部为 1920×1080、16:9。四款均用已核验的实机 EDID 1.3
身份和时序字段重建；生成结果不是对样机 EDID 的逐字节复制。次要 DTD 分别为
Samsung 1280×720@50、AOC/Lenovo
1920×1080@74.973、Xiaomi 1920×1080@75.002，并校验 pixel clock、front
porch、sync、blanking、同步极性与 DTD image size。四款 native DTD 均为
H+/V+；Samsung/Xiaomi 次 DTD 为 H+/V+，AOC/Lenovo 为 H+/V-。Xiaomi raw
次 DTD 的 image size 是 160×90 mm，其余次 DTD 使用各自面板尺寸。文本序列号
按厂商格式生成且拒绝复制证据样本；
binary serial 按型号固定值或 AOC 十进制后六位映射计算。binary serial、revision
和完整 DTD 明细均写入 profile；启动及离线缓存修复会按 stable ID 逐项复核，避免
同 ID 目录修订让旧实例静默漂移。所有尺寸、扫描范围、产品码、制造时间、序列策略
和 DTD 必须按 `EDID_COMPONENT_ID` 原子一致。

当前组件目录修订为 `2026-07-24.1`。缺少上述 binary serial、revision 和完整 DTD
字段的旧 Linux schema-1 profile 会直接拒绝加载，即使 `STRICT_HARDWARE=0` 也不会静默补齐。
可备份后显式 `--reroll` 生成新身份，或新建实例；这项 profile ABI 更新本身不要求
重装 Guest，但磁盘 virtual-size 仍必须精确匹配现行 512GB 目录。

## USB HID

三个设备使用同一字段结构：

| 设备 | 字段 | 当前模板 / fidelity |
|---|---|---|
| 键盘 | `KBD_COMPONENT_ID`、`KBD_VID`、`KBD_PID`、`KBD_MFR`、`KBD_PRODUCT`、`KBD_SERIAL`、`KBD_BCD_DEVICE`、`KBD_DESCRIPTOR_FIDELITY` | Microsoft Wired Keyboard 600，`045e:0750/0163`，`identity_only_generic_report` |
| 鼠标 | `MOUSE_COMPONENT_ID`、`MOUSE_VID`、`MOUSE_PID`、`MOUSE_MFR`、`MOUSE_PRODUCT`、`MOUSE_SERIAL`、`MOUSE_BCD_DEVICE`、`MOUSE_DESCRIPTOR_FIDELITY` | Microsoft USB Optical Mouse，`045e:00cb/0163`，`identity_only_generic_report` |
| 绝对指针 | `TABLET_COMPONENT_ID`、`TABLET_VID`、`TABLET_PID`、`TABLET_MFR`、`TABLET_PRODUCT`、`TABLET_SERIAL`、`TABLET_BCD_DEVICE`、`TABLET_DESCRIPTOR_FIDELITY` | QEMU USB Tablet，`0627:0001/0000`，`generic_virtual_only` |

键盘和鼠标模板声明 `serial_exposed=false`，启动器不会把 profile 中的稳定派生 serial 送入
USB descriptor。默认 tablet 也不暴露品牌或 serial；它只实现通用绝对坐标协议，不能改名为
HUION、VEIKK 或 XP-Pen。

## GPU 字段及范围声明

新 profile 从 `gpu-boards.json` 的 18 块板卡中选择一块完整 AIB，21 列字段按
`GPU_COMPONENT_ID` 原子绑定。`GPU_PCI_VEN`/`GPU_PCI_DEV` 与
`GPU_SUBSYS_VEN`/`GPU_SUBSYS_DEV` 是客体用户态逻辑身份；它们不会替换物理
virtio-vga 的 `1AF4:1050`。物理节点只携带
`GPU_CARRIER_VEN`/`GPU_CARRIER_DEV`，由 stock VioGpuDod 继续绑定。

| profile 字段 | 含义 / 当前约束 |
|---|---|
| `GPU_COMPONENT_ID` | 18 个已审计 AIB 稳定 ID 之一；精确集合以 `gpu-boards.json` 为准 |
| `GPU_VENDOR`、`GPU_NAME` | 逻辑芯片厂商与完整 AIB canonical 标签；`GPU_NAME` 会原样进入 identity schema-2 的 `SpoofName`，当前为 12 块 NVIDIA 与 6 块 AMD |
| `GPU_BOARD_PARTNER`、`GPU_PART_NUMBER` | 与稳定 ID 绑定的 ASUS、Colorful、GALAX、MSI、Gigabyte、EVGA 或 Sapphire 品牌/真实料号组合 |
| `GPU_PCI_VEN`、`GPU_PCI_DEV` | 六个用户态逻辑主 ID：NVIDIA `10de:1d01/1380/1c81/1c82`，AMD `1002:699f/67ff` |
| `GPU_SUBSYS_VEN`、`GPU_SUBSYS_DEV` | 与所选板卡原子绑定的真实逻辑 AIB subsystem；不能只按芯片主 ID 推断 |
| `GPU_CARRIER_VEN`、`GPU_CARRIER_DEV` | 物理 virtio 节点的内部选择令牌：连续且精确为 `1af4:a101`–`1af4:a112`；不是 AIB subsystem |
| `GPU_RAM_MB`、`GPU_BIOS`、`GPU_REV` | 与同一 AIB 绑定的逻辑显存容量、VBIOS 与 revision |
| `GPU_IDENTITY_FIDELITY` | 新 AIB 必须为 `audited_aib_bundle_shallow_user_projection_no_passthrough` |

目录全部 18 条都固定 `serial_exposed=false`。profile 和 guest schema 均没有
`GPU_SERIAL` 字段；显卡缺少本项目可核验的标准序列接口，因此不得从其它硬件字段
派生或虚构 GPU 序列号。

下列规格字段同样与所选 21 列 AIB bundle 绑定，用于 guest schema-2 用户态身份快照：

`GPU_NAME`/`SpoofName` 不等于 Windows 设备展示名。完整 AIB bundle 校验通过后，
Enum `FriendlyName`/`DeviceDesc`、Class `DriverDesc`、
`HardwareInformation.AdapterString` 和 `HardwareInformation.ChipType` 按
`GPU_PCI_VEN`/`GPU_PCI_DEV` 的封闭映射使用标准芯片名；Enum `Mfg` 与 Class
`ProviderName` 使用 `GPU_VENDOR`。NVAPI/ADL 的公开 adapter 名称复用同一映射，
完整 AIB 标签只保留在内部 identity 中用于原子校验。新的 Windows 投影使用
transaction schema-5，transaction schema 1/2/3/4 仅用于恢复旧 journal，不改变
identity schema-2。

schema-5 的 SetupAPI HardwareID 首项包含逻辑 `VEN/DEV`、所选板卡的
`GPU_SUBSYS_VEN`/`GPU_SUBSYS_DEV` 和 `GPU_REV`；后续物理 `1AF4:1050` 条目完整保留，
而 `MatchingDeviceId`、`InfPath`、`InfSection`、`Service` 继续使用 stock
`VioGpuDod` 绑定值。它们是同一 VioGpuDod devnode 的多条匹配字符串，不会生成额外
显卡；真实 InstanceId、BDF、Driver 和 Service 仍属于 `1AF4:1050`。NVAPI
`GetPCIIdentifiers` 的主 `deviceId` 同样使用物理 `1AF4:1050` carrier 作为跨接口
去重键，AIB subsystem/revision、external device 和标准型号保持逻辑厂商身份。

4 GiB AIB 的 NVAPI legacy `MemoryInfo` v1/v2/v3 与 frame-buffer size 接口返回
`4194304 KiB`，`MemoryInfoEx` v1 返回 `4294967296 bytes`。旧 32 位
`HardwareInformation.MemorySize` 则投影为
`2047 MiB`（`0x7FF00000`），确保错误按有符号 Int32 读取它的旧工具仍得到正数；
64 位 `HardwareInformation.qwMemorySize` 与相应厂商接口仍精确投影 4 GiB。历史
schema-4 journal 只参与恢复，并按原语义重建 `4095 MiB`。

| host profile | guest 注册表 | 单位 / 约束 |
|---|---|---|
| `GPU_MEMORY_TYPE` | `SpoofMemoryType` | 当前池为 `GDDR5` |
| `GPU_MEMORY_BUS_WIDTH_BITS` | `SpoofMemoryBusWidthBits` | bit；32–1024 的 2 次幂，当前型号为 64/128 |
| `GPU_BASE_CLOCK_KHZ` | `SpoofBaseClockKHz` | kHz；100000–5000000 |
| `GPU_BOOST_CLOCK_KHZ` | `SpoofBoostClockKHz` | kHz；100000–5000000，且不小于 base |
| `GPU_MEMORY_CLOCK_KHZ` | `SpoofMemoryClockKHz` | NVAPI clock-domain kHz；100000–10000000 |
| `GPU_SLI_SUPPORTED` | `SpoofSliSupported` | 仅允许 `0`；浅层实现为单 GPU、非 SLI |

GT 1030、GTX 750 Ti、GTX 1050、GTX 1050 Ti、RX 550 和 RX 560 每个芯片型号
都精确包含 3 个不同品牌板卡；禁止把 18 块板卡的 subsystem、VBIOS、料号、显存
或时钟交叉拼接。memory clock 按 NVAPI clock-domain 口径保存，不把包装标注的
有效传输率直接写入该字段。严格新 profile 缺少任一 AIB 或规格字段都会
fail-closed。

升级前的六款 NVIDIA/AMD generic profile 没有 AIB 扩展字段，加载器只按原主 ID
在 `components.json` 中唯一回查，并保持 `label_only_out_of_scope`；
这些条目只读兼容，不进入新 profile 选择池，也不会被自动冒充为某块品牌板卡。

本分支不做 GPU passthrough 或 vGPU；virtio-vga(-gl) 的主设备、驱动和行为不会因为这些
逻辑身份变成真实 NVIDIA/AMD GPU。显存与时钟也是用户态查询投影，不代表
客体可以访问该容量或达到该频率。这组字段不得计入真机化完成度或硬件支持承诺。

## 生命周期操作

```bash
# 查看当前 profile（不要 source）
sed -n '1,220p' /home/ubuntu/images/vms/1/profile

# 改为 manifest 允许的 8 GiB；只改变 MEM_TOTAL_MB，重启生效
deploy/scripts/set-vm-memory.sh 1 8G

# 显式原子重新生成身份；会改变 UUID/序列号/MAC，并可能触发 Windows 重新激活
deploy/scripts/start-vm.sh 1 --reroll
```

启动器会先把 reroll 结果保留在进程内存，依次通过宿主约束、CPU realize、磁盘容量、
所请求 TPM、内存/设备参数和完整 QEMU argv 组装后才原子替换 profile。尤其是旧 1TB
磁盘与当前所选 512GB 启动盘模板不符时，启动会失败但旧 profile 哈希保持不变。
若已有 TPM state，reroll 会在生成候选前拒绝，避免新 UUID/主板序列号复用旧 EK/NVRAM；
更换身份、主板型号或 TPM 版本应新建 instance，或先执行经过验证的密钥迁移/归档。
`reroll-identity.sh` 不再删除 profile，只会提示上述安全命令。

非严格模式会为部分旧 profile 提供兼容默认值，但必须另加
`--allow-legacy-profile` 明确授权，而且这不代表旧的 AMD/B350、混合 NVMe/EDID/HID
画像已通过审计。无 TPM state 时可显式 reroll；已有 state 时应新建 instance 或先迁移密钥，
并在测试实例上验证激活、驱动和磁盘容量。
新建的 schema 1 AMD compatibility profile 与 legacy profile 不同：它会完整绑定目录事实，
后续启动会复用其 `PLATFORM_ID`，但仍须每次显式携带 allow 开关，且不能计为真实
B350 machine 验收。
