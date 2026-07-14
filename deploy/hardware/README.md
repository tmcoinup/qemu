# 版本化整机平台清单

`platforms.json` 是 Linux 与 Windows 启动器共享的整机平台事实源。新建 VM
必须先选定一个 `enabled=true` 的平台，再从该平台导出 CPU、主板、内存控制器、
芯片组和板载设备字段。禁止重新采用“先随机 CPU、再按 socket 随机主板、最后从
全局池随机 BIOS”的方式；这种独立抽签会生成现实中不存在的跨代组合。

`components.json` 是可更换部件事实源。SSD、显示器和 USB HID 只有在 C 设备模型
能够同时表达型号、固件、PCI/EDID/descriptor 深层字段时才可设为 `enabled=true`。
当前严格目录刻意只启用 Samsung 970 PRO 512GB、Samsung S24F350、Microsoft
Wired Keyboard 600、Microsoft USB Optical Mouse；绝对坐标 tablet 明确标为
`generic_virtual_only`，GPU 明确标为 `out_of_scope_virtual_display`。

## 设计边界

- `status=supported` 只表示平台可在宿主运行时门禁通过后成为启动器候选，不表示目标
  H110/H310/B350 machine、BDF 或寄存器行为已实现。当前启用 Intel 条目仍属于 Q35
  configuration-space identity compatibility。
- 清单描述一块可实际组装并由厂商 BIOS 支持的消费级主板平台。
- 显卡直通和 vGPU 不属于本分支，因此显卡仍是独立显示策略，不作为平台真实性承诺。
- NVMe 是可更换部件；平台只绑定主板所能提供的 PCIe 代际、lane 数和 UEFI 启动能力。
- USB 键鼠、显示器等外设不属于板载平台，可继续从独立目录选择，但不得伪造尚未实现的
  深层 HID/EDID 行为。
- AM3、AM3+、FM2+、LGA1155 暂不进入清单。当前 Q35/平台设备层不能同时表达这些
  芯片组的 PCI root、USB、音频和 DDR3 行为；保留旧 profile 的加载兼容性，但禁止
  新 VM 再随机出这些组合。
- 两个 AM4 bundle 保留了已核验的 CPU/主板事实，但标记为 `compatibility` 且禁用。
  当前底层仍是 Intel Q35/ICH9 行为，仅替换 PCI ID 不能成为真实 AMD B350；调用方
  显式设置 `ALLOW_PLATFORM_COMPATIBILITY=1` 后，启动器按宿主 CPU vendor、`CPUS`、
  最大频率和 TSC 约束自动匹配。选择器始终优先 `supported`，只在没有可用
  `supported` 候选时回退到 `compatibility`。已有 profile 复用其 `PLATFORM_ID`；
  `STEALTH_PLATFORM_ID`/`--platform-id` 只用于可选的高级固定或一致性断言。
  这个独立门禁不会把 `STRICT_HARDWARE` 改成 `0`，也不会关闭 KVM/TSC、CPU realize、
  profile、磁盘，或请求 `TPM=1` 时的 TPM 检查。历史内部调用的 `STRICT_HARDWARE=0`
  直载语义仅供诊断，未授权时不会选中禁用条目。
  实现真正的 AMD machine type 后才允许将其改回 `enabled=true/status=supported`。

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
  组合。当前只允许单条 2GB、单条 4GB 或两条 4GB，明确禁止把 6GB 虚构成两条
  不存在于物料目录的 3GB UDIMM。
- `bios.version` 与 `bios.date` 是同一厂商正式发布的配对值；不能跨主板随机。
- `system.chassis_type` 是 SMBIOS Type 3 的 DMTF 编码。当前整机清单只允许
  Desktop `0x03`，Linux 与 Windows 必须从该字段生成相同的机箱类型。
- `source_refs` 至少包含 CPU 支持表和 BIOS 发布页。新增平台时必须人工打开来源核验，
  不能用本仓库自己的白名单证明本仓库自己的数据。

设备字段：

- `root_port` 与 `xhci` 代表该代平台可见的控制器身份。
- `chipset` 必须完整给出 MCH、LPC、SMBus 和 AHCI 的 vendor/device/revision 三元组。
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
  ALC887 必须同时绑定 `codec_id=0x10ec0887`、`codec_revision=0x00100302`
  和 ASUS `codec_subsystem_id=0x104386c7`。当前 `identity_fidelity` 必须是
  `protocol_identity_only`：它只承诺 HDA 协议身份，不承诺真实 ALC887 的全部
  widget、插孔检测和板级布线拓扑。
- `nvme` 是总线能力而不是某一块 SSD 的型号；SSD model、firmware、容量仍需在存储
  目录中成套选择。`attachment=m2_socket` 是物理插槽硬约束，避免在只有一个已被
  独显占用的 x16 插槽上同时虚构一块 x4 NVMe 转接卡。

## 变更流程

1. 从 CPU 和主板厂商官网核对 SKU、核数、线程、socket、内存上限和 BIOS 支持版本。
2. 从主板规格/手册核对 PCH、PCIe、DIMM、NIC、audio 与 USB 控制器。
3. 添加完整平台对象并更新 `catalog_revision`。
4. 运行 `deploy/scripts/tests/test_platform_manifest.sh`，再运行硬件池目录测试。
   可更换部件同时运行 `deploy/scripts/tests/test_component_manifest.sh`。
5. Linux 与 Windows 均应保存 `PLATFORM_ID` 和 `PLATFORM_SCHEMA_VERSION`；已有 VM
   不得在普通重启时自动换平台。

严格模式会拒绝 `legacy-unversioned`；默认也拒绝 `status!=supported`。唯一窄例外是
显式 allow 授权的 schema 1 `compatibility` profile，此时仍会执行全部事实绑定与
运行时门禁；已有 profile 以自身 `PLATFORM_ID` 为准，可选的 ID 参数只断言一致。
旧 profile 迁移必须由用户显式执行
`deploy/scripts/reroll-identity.sh <实例号>`；reroll 会改变整套硬件身份并可能触发客体
重新激活，启动器不得自动替用户执行。

## E5 v4 宿主说明

`intel-lga1151-i5-6400t-asus-h110m-a-m2` 的 TSC 是 2200 MHz，因此它是无 VMX TSC
scaling 的 2.2 GHz Broadwell-EP/E5 v4 宿主在 TSC 维度上唯一可用的 4C/4T 候选。
这不等于已证明 E5 v4 能实现完整 `Skylake-Client-IBRS` CPUID：选中后还必须在
目标宿主上通过 KVM CPU realize smoke，任一特性缺失都要 fail-closed。未完成该实机
smoke 前，E5-2696 v4/X99 只能评为条件支持。选择器仅在宿主供应商、vCPU 数、
频率和强制 TSC 条件全部满足时产生它；没有候选时明确失败，不得回退到任意
Intel SKU。
