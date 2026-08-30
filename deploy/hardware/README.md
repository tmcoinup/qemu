# 版本化整机平台清单

`platforms.json` 是 Linux 与 Windows 启动器共享的整机平台事实源。新建 VM
必须先选定一个 `enabled=true` 的平台，再从该平台导出 CPU、主板、内存控制器、
芯片组和板载设备字段。禁止重新采用“先随机 CPU、再按 socket 随机主板、最后从
全局池随机 BIOS”的方式；这种独立抽签会生成现实中不存在的跨代组合。

默认 `supported` 池除既有 G4900（2C2T）、G5400（2C4T）、i3-9100F（4C4T）
和 i5-6400T（4C4T）外，还包含 i7-3820/i7-4820K（4C8T）及
i7-3930K/i7-4930K/i7-4960X（6C12T）。X79 原子组合覆盖 ASUS P9X79、
Gigabyte GA-X79-UP4、ASRock X79 Extreme4 三品牌，共 15 套；各条目仍与具体主板、
DDR3 速率、PCIe NVMe 转接能力、SATA 启动盘策略、BIOS、TPM 和设备身份成套绑定。

`board-vendors.json` 是主板 canonical manufacturer 的共享注册表，联合绑定平台 ID
token、序号生成函数、PCI subsystem vendor、官方来源主机和序号格式证据。ASUS、
MSI、GIGABYTE、ASRock 必须精确命中注册表，不允许靠厂商名称子串或通用 PCI ID
猜测；序号值始终合成且不得复制实机，证据范围不足时必须在 `evidence_scope` 中如实
保留“仅标签位置/保守形状”的边界。

`components.json` 是可更换部件的入口目录；原生 NVMe 完整事实拆分到
`storage.json`，活动显卡板卡拆分到 `gpu-boards.json`，显示器和 USB HID
仍由入口目录直接承载。`components.json`、`storage.json` 与 `gpu-boards.json`
当前目录修订均为 `2026-07-24.1`。存储子目录只允许精确
`512110190592` 字节的 Samsung 970 PRO、Intel 760p、WD PC SN730 和 KIOXIA XG6，
每项都把稳定 ID、型号、料号、固件、PCI/subsystem、OUI 和序列号样本形态原子绑定。
这些 SSD 有厂商文档和公开身份样本，但没有本项目实机设备快照；各条目必须用
fidelity/status 字段区分已核验字段与未采集行为。显示器池包含 Samsung S24F350、AOC 24B2XH、Xiaomi
RMMNT238NF 和 Lenovo L24e-30，全部限定为 1920×1080、16:9。型号、可视尺寸和
刷新范围来自厂商规格；product/date、EDID 1.3、文本/binary serial 规则及次要
DTD 的 clock/porch/sync/blanking、同步极性和 image size 来自对应型号的公开
raw EDID，并由目录按稳定 ID 原子绑定。序列值重新生成且
禁止复制证据样本。Microsoft 键鼠只有目录身份标签，仍使用 QEMU
通用 report descriptor，标为 `unverified_catalog_identity` /
`identity_only_generic_report`。绝对坐标 tablet 标为 `generic_virtual_only`。
`components.json` 内六款旧 generic GPU label 只作历史 profile 回查；活动
`gpu-boards.json` 则包含 GT 1030、GTX 750 Ti、GTX 1050、GTX 1050 Ti、
RX 550、RX 560 各 3 个品牌，共 18 块 AIB（12 NVIDIA、6 AMD）。其 carrier
连续占用 `1AF4:A101`–`1AF4:A112`，物理主 ID 仍固定为 `1AF4:1050`。

上述目录和 `component_peripheral_catalog.py`、`gpu_board_catalog.py`、
`storage_catalog.py`、`memory_catalog.py`、`board_vendor_policy.py` 都是纯离线
校验链：只读取仓库内 JSON，并使用 Python 标准库。`source_refs` /
`identity_source_refs` 中的 HTTPS 地址仅是人工审计证据的静态元数据；运行时只校验
其域名和字段形状，不发起网络请求，也不会自动安装或下载依赖。客机需要的驱动和
厂商 API shim 均由构建机预先准备并嵌入 `respawn-stealth.exe`。

`storage-compatibility.json` 独立保存无原生 NVMe boot 的老主板可用的 SATA 启动盘：
Samsung 840 PRO、850 PRO、860 PRO 512GB。每项将稳定 ID、型号、零售料号、固件、
容量和接口绑定为一个整体；资料来自 Samsung 官方产品页和固件目录，但没有对应实物的
ATA IDENTIFY capture，不能把目录生成的 Identify 字段表述成样机原始转储。

`household-compatibility.json` 是显式兜底目录，和默认 `platforms.json` 分开：
它只包含家用桌面 Guest CPU，并按 E5 v1/v2/v3/v4、AMD K10/Zen 等宿主类
映射到完整的 CPU、主板、内存、芯片组、固件和启动盘组合。这里的 E5 名称只用于
识别宿主代际；任何 Xeon/E3/E5/E7、EPYC、Opteron 或 Threadripper 都不能成为
Guest CPU。
该目录只有在 `--allow-platform-compatibility` 下、且正常 supported 候选均无法
由当前 KVM 创建时才参与选择。

K10 的 Athlon II/Phenom II 条目按 Family 10h CPUID 保留 `invtsc`，不暴露后代
`topoext`。3DNow!/3DNow!Ext 是该代真实能力，目录不会永久关闭；若执行宿主已经
移除相应 KVM 位，启动器只在最终 QEMU 参数中按宿主实情动态追加禁用项。

## 设计边界

- `status=supported` 只表示平台可在宿主运行时门禁通过后成为启动器候选，不表示目标
  H81/H110/H310/B350 machine、BDF 或寄存器行为已实现。当前启用 Intel 条目仍属于 Q35
  configuration-space identity compatibility。
- 主板/整机/机箱序号与 asset tag 都是按注册表格式受控的合成值，不是厂商实机采集值；
  MAC 仅核验厂商 OUI 并合成后缀，PCI subsystem 也没有 `lspci -nnvv` 样机快照闭环。
- 清单描述一块可实际组装并由厂商 BIOS 支持的消费级主板平台。
- 显卡直通和 vGPU 不属于本分支，因此 18 块 AIB 仅是独立的用户态浅层身份策略，
  不作为平台真实性承诺。目录全部声明 `serial_exposed=false`，不虚构缺少标准、
  可核验接口的 GPU 序列号。
- 存储是可更换部件；平台只绑定主板所能提供的 PCIe 代际、lane 数、UEFI 启动能力
  和启动盘池。运行时按 `NVME_BOOT_SUPPORTED` 自动选择 NVMe 或 SATA/AHCI，不能
  根据 CPU 型号推断。
- USB 键鼠、显示器等外设不属于板载平台，可继续从独立目录选择，但不得伪造尚未实现的
  深层 HID/EDID 行为。
- AM3、AM3+、FM2+、LGA1155 仍不进入默认 supported 清单。它们只存在于独立
  household compatibility 目录，并明确保留 Q35 configuration-identity 边界；
  新 VM 必须显式授权，不能把这些条目宣传成对应物理芯片组的完整行为模型。
- H81/Haswell 是窄例外：仅当宿主 CPUID 精确分类为 E5 v3/v4 时，G3220、
  i3-4130、i5-4570 三个家用型号进入默认正常 CPU 池；H81/PCH 仍只具有 Q35
  configuration identity，不宣称目标芯片组行为等价。
- Ryzen 7 5800 是另一个窄例外：仅当宿主同时命中 AuthenticAMD Family 25、
  Model 33 和完整品牌串时，`normal-ryzen7-5800-ryzen3-1200-b350` 才进入默认
  正常 CPU 池。Guest 固定为已有实测的 Ryzen 3 1200 4C4T，不缩核、不透传
  物理机的 8C16T，也不会把 5800X/5700X 等邻近 SKU 一并提升。
- `platforms.json` 中 Ryzen 3 1200 的静态 AM4 bundle 仍标记为禁用的
  `compatibility`；household 目录中的通用 Zen 候选也保持显式授权。Ryzen 3
  2300X 本身满足 4C4T，但因 PRIME B350-PLUS 官方 CPU 支持表无该板型搭配，
  已移出该 bundle；若后续采用官方列名支持它的 B450 主板，必须另建完整事实束，
  并在 Ryzen 7 5800 实机完成 KVM realize 后才能加入正常池。
  当前底层仍是 Intel Q35/ICH9 行为，仅替换 PCI ID 不能成为真实 AMD B350；调用方
  显式设置 `ALLOW_PLATFORM_COMPATIBILITY=1` 后，启动器按宿主 CPU vendor、`CPUS`、
  最大频率和 TSC 约束自动匹配。精确正常宿主先选择专用正常池；其它宿主
  优先普通 `supported`，只在没有可用正常候选时回退到 `compatibility`。
  已有 profile 复用其 `PLATFORM_ID`；
  `STEALTH_PLATFORM_ID`/`--platform-id` 只用于可选的高级固定或一致性断言。
  这个独立门禁不会把 `STRICT_HARDWARE` 改成 `0`，也不会关闭 KVM/TSC、CPU realize、
  profile、磁盘，或请求 `TPM=1` 时的 TPM 检查。历史内部调用的 `STRICT_HARDWARE=0`
  直载语义仅供诊断，未授权时不会选中禁用条目。
  实现真正的 AMD machine type 后，才允许把静态 AMD 整机提升为完整平台 supported。

## Schema 1 字段约束

顶层字段：

- `schema_version`：整数，目前只能为 `1`。不识别的版本必须拒绝，不能猜测兼容。
- `catalog_revision`：人工审计版本；修改任何平台事实时必须更新。
- `defaults`：新 profile 的默认 vCPU 数和内存总量。
- `fidelity`：全目录共用的 machine 行为边界。schema 1 固定为 Q35/ICH9 行为、仅 PCI
  configuration identity、目标 PCH 行为未实现且 BDF 不等价，并记录 Linux/Windows
  启动器经 `query-pci` 核验的实际 BDF；不得把它改成宣传性“等价”标记。
- `platforms`：平台对象数组，`id` 在整个文件内唯一。

CPU 字段：

- `qemu_arg`、`vendor_id`、`name` 和 `part` 共同描述同一个真实 SKU。
- `cores` 与 `threads` 是物理 SKU 的完整拓扑。新建 VM 的 `CPUS` 必须等于
  `threads`；当前启动器不能可信地表达 BIOS 关闭部分核心的场景。
- `current_mhz` 是 SMBIOS 当前速度，`tsc_mhz` 是客体 invariant TSC 目标。
  宿主没有 VMX TSC scaling 时只能选择与宿主 TSC 完全匹配的平台。
- `phys_bits`、`features` 是允许向 QEMU 传递的地址位宽和特性集合，不能从宿主
  无条件透传。
- `integrated_gpu.profile_state=disabled_in_bios` 表示该 SKU 物理带核显，但平台身份
  明确采用 BIOS 关闭状态；`absent`/`fused_off` 才表示硬件本身没有核显。
- `smbios` 中的 family、upgrade、voltage、external clock 和 characteristics 必须按
  DMTF 枚举及该 SKU 规格填写。

主板和内存字段：

- `board.pch`、`pcie_generation`、DIMM 槽位和最大容量绑定到具体主板型号。
- `memory.type`、通道数、最大速率和允许工作速率必须同时符合 CPU 内存控制器与主板。
  颗粒额定速率可以高于平台工作速率，但客体报告值必须降到 `max_mts`。
- `voltage_mv`、`rank`、`module_mib` 和 `allowed_total_mib` 共同限制可生成的 DIMM
  组合。既有平台保持 2/4/8GB；X79 提供 4/8/12/16GB，并以 1/2/3/4 条 4GB
  模块表达。任何少于四个 DIMM 槽的平台都不得声明 12/16GB。
- `bios.version` 与 `bios.date` 是同一厂商正式发布的配对值；不能跨主板随机。
- `system.chassis_type` 是 SMBIOS Type 3 的 DMTF 编码。当前整机清单只允许
  Desktop `0x03`，Linux 与 Windows 必须从该字段生成相同的机箱类型。
- `source_refs` 至少包含 CPU 支持表和 BIOS 发布页。新增平台时必须人工打开来源核验，
  不能用本仓库自己的白名单证明本仓库自己的数据。

TPM 字段：

- `tpm` 随整机平台绑定，选择平台后统一导出 `TPM_CAPABILITY`、`TPM_SUPPORTED`、
  `TPM_IMPLEMENTATION`、`TPM_VERSION`、`TPM_FRONTEND` 和 `TPM_PCR_BANKS`。启动器
  不得再独立随机 TPM 版本或实现，否则会把 Intel PTT、AMD fTPM 与错误的主板组合。
- `capability` 描述目标平台具有 `firmware` 固件 TPM、`discrete` 独立模块能力或
  `none`；`implementation` 进一步区分 `intel-ptt`、`amd-ftpm`、
  `discrete-module` 和 `none`。固件实现必须与 CPU 厂商一致。
- `supported` 是 TPM 能力状态，与平台对象顶层的启动候选 `status/enabled` 含义不同。
  因此 AM4 compatibility 平台可以禁用为启动候选，同时仍如实记录主板支持 AMD fTPM。
- `version` 只允许 `none`、`1.2`、`2.0`；`pcr_banks` 只允许 `sha1` 和 `sha256`。
  TPM 1.2 只能使用 `sha1`，`tpm-crb` 只能承载 TPM 2.0。不支持 TPM 时，能力、实现、
  版本和前端必须全部为 `none`，PCR bank 必须为空。
- `emulation_frontend`（即启动器采用的 TPM interface/frontend）是本项目提供给客体的
  仿真选择，用来在 `tpm-tis`、`tpm-crb` 与 `none` 之间生成一致的 QEMU 参数；
  它不是目标主板上的物理接口、排针类型或固件内部连接方式，也不得据此宣称已模拟
  主板 TPM 电气拓扑。当前 H310 和兼容性 B350 条目选择 TPM 2.0
  `tpm-crb`/`sha256`；H110M-A/M.2 因缺少板级 PTT 证据而 fail closed 为 `none`。
  X79 中 P9X79/GA-X79-UP4 按独立 TPM 1.2、TIS/SHA-1 投影，X79 Extreme4
  在证据不足时 fail closed 为 `none`。
- `support_source_ref` 与 `version_source_ref` 必须是两条不同的当前主板或 CPU
  厂商官方 HTTPS 证据：前者核验具体主板/芯片组是否提供 fTPM/PTT 或独立模块排针，
  后者核验对应实现的 TPM 版本。不能只用一篇通用 TPM 文章同时替代两项依据。

设备字段：

- `root_port` 与 `xhci` 代表该代平台可见的控制器身份。
- `chipset` 必须完整给出 MCH、LPC、SMBus 和 AHCI 的 vendor/device/revision 三元组；
  MCH 仅用于声明目标/兼容边界，不得覆盖 Q35 启动所需的原生 `8086:29c0`。
  AM4 compatibility 条目故意记录底层 Q35/ICH9 三元组，用来明确暴露兼容边界，不能
  把它解释成已实现 B350 行为。
- PCI ID 可注入不改变地址拓扑：Linux 当前有 `00:01.0`–`00:04.0` 四个 Q35 root port，
  HDA 为 `00:05.0`；Windows 有 `00:01.0`–`00:03.0` 三个 root port，HDA 为
  `00:04.0`；两者的 LPC/AHCI/SMBus 均是 Q35 `00:1f.0/.2/.3`。这些地址必须与顶层
  `fidelity.bdf_layout` 和 C 层 query-pci 回归同步，不能描述成 H110/H310 真机拓扑。
- 当前 QEMU 只实现 Intel 82574L/e1000e，故 `nic.attachment=add_in`，同时把主板
  自带 Realtek 网卡记录为 `board_nic_state=disabled_in_bios`。在 RTL8111H 行为模型
  实现前，不得仅改 PCI ID 或名称后宣称它是板载 Realtek 网卡。
  82574L bundle 还必须绑定 Intel 子系统 `0x8086:0xA01F` 和 `mac_oui=3c:fd:fe`；
  Linux/Windows 都只能消费清单值，不允许在启动器再硬编码一份。
- `audio` 是具体主板的板载器件，不能跟随全局随机值或板厂随意改变。
  受控 ALC887/ALC892/ALC898 必须分别绑定 `0x10ec0887`/`0x10ec0892`/
  `0x10ec0899`、共同的 `codec_revision=0x00100302`，以及以当前板厂 PCI
  subsystem vendor 开头的 `codec_subsystem_id`。当前
  `identity_fidelity` 必须是
  `protocol_identity_only`：它只承诺 HDA 协议身份，不承诺真实 codec 的全部
  widget、插孔检测和板级布线拓扑。
- `nvme` 是总线能力而不是某一块 SSD 的型号；SSD model、firmware、容量仍需在存储
  目录中成套选择。`boot_supported=true` 必须对应 `attachment=m2_socket`；无原生
  M.2 的 X79 使用 `boot_supported=false`、`attachment=pcie_add_in`，系统盘切到
  SATA/AHCI，NVMe 只作为数据盘能力。
- `NVME_BOOT_SUPPORTED=false` 时，household 平台必须把
  `PLATFORM_BOOT_MODEL`/`PLATFORM_BOOT_FIRMWARE` 写成
  `storage-compatibility-pool` 策略标记，并绑定
  `PLATFORM_BOOT_STORAGE_POOL_ID=samsung-sata-pro-512gb`。实际 Guest 可见的
  SATA ID、型号、料号、固件、容量、接口和独立序列号由 `BOOT_STORAGE_*` 首次
  随机后持久化；普通重启按所存 ID 重建，不得重新抽签，也不得复用 `NVME_*`。

## 变更流程

1. 从 CPU 和主板厂商官网核对 SKU、核数、线程、socket、内存上限和 BIOS 支持版本。
2. 从主板规格/手册核对 PCH、PCIe、DIMM、NIC、audio 与 USB 控制器。
3. 添加完整平台对象并更新 `catalog_revision`。
4. 运行 `test_board_vendor_policy.py` 与 `test_platform_manifest.sh`，再运行硬件池目录测试。
   可更换部件同时运行 `deploy/scripts/tests/test_component_manifest.sh`。
5. Linux 与 Windows 均应保存 `PLATFORM_ID` 和 `PLATFORM_SCHEMA_VERSION`；已有 VM
   不得在普通重启时自动换平台。

严格模式会拒绝 `legacy-unversioned`；默认也拒绝 `status!=supported`。唯一窄例外是
显式 allow 授权的 schema 1 `compatibility` profile，此时仍会执行全部事实绑定与
运行时门禁；已有 profile 以自身 `PLATFORM_ID` 为准，可选的 ID 参数只断言一致。
会改变 Guest 硬件身份的旧 profile 升级必须由用户显式执行 `--reroll`；它可能触发客体
重新激活，启动器不得自动替用户执行。精确命中已知旧 revision 的目录元数据修复是窄例外：
只允许补入稳定 DIMM module ID、清除从未暴露的候选料号，或把内部启动盘占位值替换为
同一 component 的真实料号。此类修复必须保持全部 Guest 可见身份不变，严格门禁通过后
先创建只读备份再原子保存；它不要求重建实例或 reroll。

## E5 v1-v4 宿主映射说明

- E5 v1 宿主 → Sandy Bridge 家用 DDR3 Guest；E5 v2 宿主 → Ivy Bridge
  家用 DDR3 Guest；E5 v3/v4 宿主 → Haswell 家用 DDR3 Guest。E5 v3/v4
  对应的实际 Guest 候选仅为 G3220（2C2T）、i3-4130（2C4T）和
  i5-4570（4C4T），它们是无需 compatibility 参数的正常池；不允许缩核，
  也绝不把 E5 品牌串透传给 Guest。E5 v1/v2 仍是显式兜底。
- H61/B75/H81 等老主板没有原生 NVMe boot，运行时会把系统盘真正切到
  SATA/AHCI，并从受控的 Samsung 840/850/860 PRO 512GB 池首次随机一套完整身份；
  后续重启复用同一 `BOOT_STORAGE_COMPONENT_ID`。NVMe 仅作为 data-only 能力。
- 带核显的 SKU 固定为 `disabled_in_bios`，本分支不创建仅改 PCI ID 的假 Intel/
  AMD iGPU，因此 Windows 设备管理器不会枚举一块无法由 QEMU 实现的核显。
- 无 TSC scaling 或宿主频率低于目标 SKU 时，E5 v3/v4 正常池可沿用宿主
  TSC/受限执行性能并给出警告；其它候选仍要求显式 compatibility。CPU feature
  必须以 `enforce=on` 通过真实 KVM realize，不能用 `enforce=off` 掩盖缺失指令。
- 2026-07-19 已在 E5-2696 v4/JGINYUE X99-TI D4 PLUS、QEMU 8.2.2 上实测 G3220 2C2T、
  i3-4130 2C4T、i5-4570 4C4T 三个 Haswell 家用模型均能无 warning 创建 vCPU；
  该结果只证明瞬时 CPU realize；客体枚举与长稳尚未完成，E5 v3 仍由每次启动的
  真实 KVM realize 决定。

## Ryzen 7 5800 宿主映射说明

- 精确 Ryzen 7 5800 宿主无需 `--allow-platform-compatibility` 即可获得唯一的
  Ryzen 3 1200、4C4T 家用 Guest；2T、6T 或更大拓扑不会由该正常池生成。
- 物理机 DDR4-3200 是宿主内存事实，不参与 Guest DIMM 身份选择。Guest 继续遵循
  PRIME B350-PLUS bundle 的 DDR4-2133/2400/2666 配置上限；当前已审计 DDR4 DIMM
  料号额定均为 2400 MT/s，因此实际新 Guest 会保持受控的 DDR4-2400 身份。
- 该正常状态只复用 2026-07-13 在 5800 宿主上完成的 Ryzen3-1200 瞬时 KVM
  realize 证据；AMD B350 仍是 Q35 configuration identity 边界，不代表芯片组
  寄存器、BDF、固件行为或长稳已经与物理 B350 等价。
