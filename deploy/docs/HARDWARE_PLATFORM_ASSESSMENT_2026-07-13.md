# VMate 硬件平台、真机化与兼容性评估

评估日期：2026-07-13；AMD 宿主运行补充：2026-07-14
评估对象：`vmate` 分支当前工作树，QEMU 11.0.2
评估范围：CPU、主板/芯片组、SMBIOS、内存/SPD、NVMe、网络、音频、USB HID、EDID、固件/TPM、宿主能力、调度、Windows/Linux 兼容性。
明确不在本分支范围：GPU passthrough、SR-IOV GPU、vGPU，以及把 virtio 显示设备等同于真实 NVIDIA/AMD GPU 的承诺。

## 1. 结论摘要

本分支当前应定位为：**Linux/KVM 优先、Windows/WHPX 受限支持、主要硬件身份字段成套但底层仍是 Q35/ICH9/QEMU 设备行为的条件可用方案**。

对 E5-2696 v4 + X99，结论不是“支持”或“不支持”的静态二选一，而是：

1. 物理主机能否启动，先由具体 X99 主板 PCB/BIOS/微码、供电和内存兼容性决定。
2. Linux/KVM 能否创建目标 VM，先由 `/dev/kvm`、`KVM_CAP_TSC_CONTROL`、实际 vCPU TSC 和目标 CPU 特性决定。
3. 当前唯一适合常见 2200 MHz、无 TSC scaling 情形的启用目标是 i5-6400T/H110 identity bundle；它只解决 TSC 候选和配置空间身份问题，不实现 H110 machine/BDF。
4. 最终必须由启动器的 QEMU/KVM CPU realize smoke 无警告通过；未通过就属于不支持，不能回退或忽略。
5. Windows/WHPX 严格模式要求物理宿主 CPU 名称与清单中的启用 SKU 精确一致，因此 E5-2696 v4 和其它 E5 **不属于 Windows/WHPX 严格支持宿主**；显式 mismatch 开关仅是功能模式，不是真机化模式。

Intel 官方明确说明 E5-2696 v4 是由系统厂商定义规格的定制处理器，Intel 不提供标准 ARK 规格；购买信息、核心数、频率和主板兼容性必须向实际系统厂商或卖家核实，不能拿 E5-2699 v4 等零售 SKU 的 ARK 页面替代。[Intel 对 E5-2696 v4 non-ARK/OEM 的说明](https://www.intel.com/content/www/us/en/support/articles/000090280/processors/intel-xeon-processors.html)

## 2. 完成度评分

以下百分比是工程评估，不是硬件认证、Windows WHQL 认证，也不是对任何检测软件“不可识别”的保证。

| 分项 | 完成度 | 判断 |
|---|---:|---|
| 本分支声明范围内的功能实现 | 84% | 平台清单、严格门禁、设备参数、持久化、测试与验收工具已经形成闭环；缺实机结果和若干行为层 |
| 随机硬件跨字段一致性 | 88% | 平台与主要可更换组件已改为完整 bundle；DIMM 仍是按 socket/速率过滤的受限兼容池，目标 PCH 与实际 Q35 BDF/行为也仍不成套 |
| 客体可枚举身份一致性 | 76% | SMBIOS、PCI ID、SPD、NVMe Identify、EDID、USB 描述符主要字段可对齐；PCI 地址拓扑仍明确暴露 Q35 |
| 真实硬件行为等价度 | 50% | PCI ID 可换，但 H310/H110、ALC887、Samsung 固件行为及 PCH BDF 仍由 Q35/ICH9/通用 QEMU 模型实现 |
| Linux/KVM 生产就绪度 | 78% | 是主路径；能力探测、CPU realize、TPM、NUMA/cpuset、桥接与长稳工具齐全，但缺目标 E5 实测 |
| Windows/WHPX 生产就绪度 | 55% | Win10/普通 Linux guest 可条件运行；宿主 SKU 门禁很窄，Win11、nested、桥接仍未闭环 |
| E5-2696 v4/X99 置信度 | 50% | 软件门禁已实现，物理主板兼容、TSC、CPUID realize、24 小时长稳均缺目标实机证据 |
| **总体（本分支非 GPU 范围）** | **70%** | 可进入受控实机验收，不应标记为“所有硬件平台生产支持”或“目标主板 machine 等价” |

如果把“真机化”定义为客体中所有可观测行为都与一台真实 OEM PC 相同，则完成度会低于上述总体值。虚拟固件、虚拟显示设备、设备时序、未实现寄存器、ACPI/电源模型和高权限计时侧信道都可能揭示虚拟化；本项目只能减少自相矛盾，不能消除虚拟化事实。

## 3. 当前事实源与随机策略

### 3.1 整机平台

`deploy/hardware/platforms.json` 是 Linux 与 Windows 共用的 schema 1 事实源。新 VM 只会从 `enabled=true/status=supported` 条目中选择。目录顶层 `fidelity.supported_semantics=launch_candidate_after_runtime_preflight` 明确规定：`supported` 只是宿主门禁通过后的启动候选，不是 H110/H310 machine、BDF 或 silicon 等价声明。

| Platform ID | CPU | 主板/PCH | 内存约束 | 状态 |
|---|---|---|---|---|
| `intel-lga1151-i3-9100f-asus-prime-h310m-a-r2` | i3-9100F，4C/4T，目标 TSC 3600 MHz | ASUS PRIME H310M-A R2.0 / H310 | DDR4，2 槽，2/4/8 GiB | 启用候选；Q35 identity compatibility |
| `intel-lga1151-i5-6400t-asus-h110m-a-m2` | i5-6400T，4C/4T，目标 TSC 2200 MHz | ASUS H110M-A/M.2 / H110 | DDR4，2 槽，2/4/8 GiB | 启用候选；Q35 identity compatibility |
| 两个 Ryzen 3 + PRIME B350-PLUS 条目 | Ryzen 3 1200/2300X | AMD B350 | DDR4 | 禁用、仅 compatibility |

AMD 条目禁用是正确的保守处理：当前 machine type 仍是 Intel Q35/ICH9，仅改 AMD PCI ID 不会得到 AMD B350 行为。AMD 物理宿主默认不会随机得到一个伪装成“完整支持”的平台。2026-07-14 增加的 `--allow-platform-compatibility` 是显式功能入口：启动器按宿主 CPU vendor、`CPUS`、最大频率和 TSC 约束自动匹配，始终优先 `supported`，仅在没有可用 `supported` 候选时回退到 `compatibility`。已有 profile 复用其 `PLATFORM_ID`；`--platform-id` 只是可选的高级固定或一致性断言。该 allow 只放宽整机 machine fidelity，不会把 `STRICT_HARDWARE` 改成 `0`；KVM/TSC、宿主厂商/线程/频率/物理地址位、CPU 无警告 realize、profile、磁盘，以及请求 `TPM=1` 时的 TPM 门禁仍保持严格。该入口能用于安装和行为验证，但不能提高 B350 真机化评级。

在 Ryzen 7 5800 宿主上的瞬时 KVM 实测表明，Ryzen3-1200 与 Ryzen3-2300X 均可按 4C/4T 和目标 TSC realize。原先直接传 `phys-bits=43` 会因宿主 48 位产生 warning；启动器现改为先验证宿主位宽，再用 `host-phys-bits=on,host-phys-bits-limit=43` 固定客体值。但这仍只证明 vCPU 可创建：KVM 最终 surface 默认关闭 SVM、MONITOR/MWAIT 和 PMU，cache 模板、微码以及额外 `tsc-deadline` 尚无目标零售 Ryzen 样机快照闭环，因此 AMD CPU 也不能提升为严格等价。

CPU、主板、PCH、BIOS 版本/日期、机箱类型、板载音频、网卡状态、M.2 能力和内存限制作为一个原子 bundle 选择。vCPU 必须等于 SKU 完整线程数；当前两个启用平台都固定为 4 vCPU，不支持随意生成 2C/4T、关闭部分核心或多 socket 客体。

### 3.2 可更换组件

`deploy/hardware/components.json` 把可更换组件也收敛为已审计模板：

- 存储：唯一启用 Samsung SSD 970 PRO 512GB，固定 model、firmware、容量、PCI/subsystem、Gen3 x4、IEEE OUI 和 SubNQN 模板。
- 显示器：唯一启用 Samsung S24F350，固定 EISA vendor、product ID、尺寸、制造时间、频率范围、pixel clock 和第二时序。
- 键盘：Microsoft Wired Keyboard 600，`045e:0750`、`bcdDevice=0x0163`、固定描述符模板、不暴露 serial。
- 鼠标：Microsoft USB Optical Mouse，`045e:00cb`、`bcdDevice=0x0163`、固定描述符模板、不暴露 serial。
- 绝对指针：保留 `0627:0001` 通用 QEMU USB Tablet，不再冒充 HUION/VEIKK/XP-Pen，因为当前 report descriptor 没有品牌数位笔的压力、倾角和协议。

这种方案牺牲了“看起来随机”的型号数量，但消除了把 Samsung EDID 深层字段套到 AOC、把 Microsoft bcdDevice 套到 Logitech、把 970 PRO 控制器套到 980 等更严重的矛盾。对真实性而言，**一个完整模板优于十个只改字符串的模板**。

DIMM 是目前需要单独说明的例外：Linux 仍从手写物料池按 socket、内存代际、额定速率和容量组合过滤，Windows 也只内置两个 Samsung `*-CRC` 料号。它们比任意字符串拼装更受控，但尚未像 `components.json` 一样具备 catalog revision、逐料号 `source_refs`、原始 SPD hash 和 profile digest 绑定，因此应称为“受限兼容池”，不能称为证据绑定的真实组件目录。

Samsung 官方数据表确认 970 PRO 512GB 是 M.2 2280、PCIe Gen3 x4、NVMe 1.3、Samsung Phoenix 控制器和 512GB 容量；该来源支持产品/接口/控制器事实，但项目中的具体 PCI ID 仍应以真实样机 `lspci -nnvv` 快照复核。[Samsung 970 PRO 官方数据表](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_NVMe_SSD_970_PRO_Data_Sheet_Rev.1.0.pdf)

### 3.3 身份持久化与完整性

- Linux profile 使用白名单逐行解析，不 `source`/`eval` 不可信 profile；保存时临时文件原子替换并设为 0600。
- 严格 Linux profile 必须含 schema、platform ID、catalog revision 和全部平台绑定字段；与当前 manifest 不一致即失败。
- Windows profile 使用 JSON、平台 SHA-256 digest、原子替换和 reroll 备份；平台事实变化后要求显式重新生成。
- UUID、MAC、主板/系统/CPU/DIMM/NVMe/显示器序列号首次生成后持久化，普通重启不漂移。
- legacy-unversioned profile 在严格模式下拒绝；迁移必须显式 reroll，因为它会改变 Windows 激活和设备身份。

## 4. 各硬件面的真实度

| 硬件面 | 已实现 | 仍然存在的边界 |
|---|---|---|
| CPU | 厂商、名称、family/model/stepping、物理地址位、特性、拓扑、TSC、SMBIOS Type 4；宿主位宽下限门禁；`enforce=on` realize | 命名 CPU 仍受宿主 CPUID/KVM 默认属性限制；AMD compatibility 的 SVM、MONITOR/MWAIT、PMU、cache、微码与 `tsc-deadline` 尚无目标样机闭环，吞吐也不会自动一致 |
| SMBIOS | Linux：Type 0/1/2/3/4/11/16/17，含 chassis、CPU 电压/外频/upgrade/characteristics、内存类型/rank/voltage；Windows：Type 0/1/2/3/4/16/17 子集 | Windows 尚无 Type 11，且 Type 1 SKU、Type 2/3 asset/SKU 等字段少于 Linux；两条路线都不是具体 ASUS BIOS 生成的完整 DMI 表 |
| 内存/SPD | 合法总量、模块容量、槽位、通道、rank、电压、每 DIMM 唯一 serial；Type17 额定/配置速率分离；256B SPD 按 2/4/8Gb 生成地址几何与 tRFC；2x4 GiB 只生成两条 SPD | 当前 EEPROM 诚实声明 256B used/total，但不是完整 EE1004 512B 器件，也不是所选品牌 DIMM 的 page 1/raw dump |
| guest NUMA | 消费级单 socket 客体始终一个 NUMA node，DIMM 数不再错误映射为 NUMA 数 | 物理双路 E5 的 host NUMA 只用于放置，不向当前 4C/4T 消费级客体暴露双 socket |
| MCH/LPC/SMBus/AHCI | PCI vendor/device/revision/subsystem 可由平台注入 | C 代码明确只是 PCI configuration identity；寄存器、端口、固定功能与 BDF 仍是 Q35/ICH9 |
| PCIe/root port/xHCI | 平台 ID、revision、链路速度/宽度、hotplug 状态可约束 | 设备行为和地址分配仍是 QEMU pcie-root-port/qemu-xhci，不是 H110/H310 silicon/拓扑 |
| NVMe | 970 PRO model/firmware/容量、144d:a804、subsystem、OUI、SubNQN、Gen3 x4；非法型号 fail closed | 控制器命令、SMART、热管理、功耗、错误恢复仍是通用 QEMU NVMe，不是 Phoenix 固件 |
| NIC | Intel 82574L/e1000e、Intel subsystem、Intel OUI；主板板载 NIC 明示为 BIOS disabled、另插扩展卡 | Windows 默认 user-mode NAT；网络拓扑和性能不像物理 LAN，Linux 应优先 bridge/TAP |
| 音频 | Linux 可传 controller vendor/device/revision/subsystem 与 ALC887 codec ID/revision/subsystem；Windows 覆盖 controller vendor/device 和 codec 三元组 | Windows controller revision/subsystem 尚未与 Linux 对齐；manifest 已诚实标记 `protocol_identity_only`，widget、插孔和板级布线不等价 |
| EDID | 单一 S24F350 深层字段成套生成，含校验和与时序 | 仍由 virtio 显示设备提供；没有真实显示器 DDC 时序、HDCP 和厂商扩展行为 |
| USB HID | Microsoft VID/PID/bcdDevice/字符串与模板绑定；品牌 tablet 被拒绝 | HID report/config descriptor 只对当前固定模板负责，扩展新品牌必须新增完整模板 |
| 固件/TPM | OVMF、per-VM NVRAM、swtpm 2.0、CRB、EK/Platform cert、严格模式 fail closed | OVMF 不是 ASUS AMI 固件；Linux 路线未证明 Secure Boot 已处于 `SecureBoot=1, SetupMode=0` |
| 显示/GPU | virtio-vga(-gl)、SDL/EGL、fb-shm、SHM/GPU handle fallback；物理主 ID 固定为 stock VioGpuDod 可绑定的 `1AF4:1050`，profile 只提供 subsystem/revision 与用户态逻辑身份；非零 `GPU_SELFSIGNED` 在任何 host 副作用前 fail-closed | 底层始终是 virtio，不是所标 NVIDIA/AMD 设备；浅层 `10DE:1C82` 投影不增加 Windows guest Direct3D、CUDA 或 NVENC，GPU passthrough/vGPU 明确不做且不计入真机化 |

当前实际 root bus 地址由 C 层 `query-pci` 回归锁定：

| 启动路径 | MCH | root port | 额外 HDA | Q35 PCH 固定功能 |
|---|---|---|---|---|
| Linux | `00:00.0` | `00:01.0`–`00:04.0` | `00:05.0` | LPC `00:1f.0`、AHCI `00:1f.2`、SMBus `00:1f.3` |
| Windows | `00:00.0` | `00:01.0`–`00:03.0` | `00:04.0` | LPC `00:1f.0`、AHCI `00:1f.2`、SMBus `00:1f.3` |

Windows 少一个空 root port，所以无显式 `addr` 的 HDA 自动地址与 Linux 不同。该测试只能证明当前 Q35 布局稳定；它不能证明这些 BDF 匹配 PRIME H310M-A R2.0 或 H110M-A/M.2 真机。最大真实性缺口不是某个序列号，而是“较新的 H110/H310 PCI 身份 + 较老的 Q35/ICH9 地址拓扑和行为”。在实现真实 chipset machine model 前，客体软件若读取 BDF、深层寄存器、ACPI 路由、SMBus 行为或设备时序，仍可区分。

## 5. Linux/Windows 宿主与客体兼容矩阵

| 宿主 | 客体 | 当前级别 | 前提与限制 |
|---|---|---|---|
| Linux/KVM | Windows 10 x64 | 主路径、可进入生产验收 | `/dev/kvm` 可用、patched QEMU 11.0.2、目标 CPU realize 通过、OVMF/virtio 驱动/swtpm 完整 |
| Linux/KVM | Windows 11 | 条件可启动，不算正式闭环 | TPM 2.0 路径存在；但启动器尚未验证 Secure Boot operational state，不能据此宣称满足 Win11 正式要求 |
| Linux/KVM | Linux x86_64 | 功能兼容、非一等公民 | QEMU 设备本身可供 Linux 使用，客体采集脚本已提供；Linux 启动器仍以 Win10 命名、ISO 流程和 localtime RTC 为主，应增加显式 guest OS 策略 |
| Windows/WHPX | Windows 10 x64 | 受限支持 | Windows 10 build 19041+、HypervisorPlatform、patched QEMU 11.0.2，并且严格模式要求宿主 CPU 名称精确等于启用 platform SKU |
| Windows/WHPX | Windows 11 | 明确拒绝 | 当前原生路线没有经过验证的 TPM 2.0 + Secure Boot，启动器在写文件前 fail closed |
| Windows/WHPX | Linux x86_64 | 条件功能支持 | UTC RTC 已区分；仍受精确宿主 SKU、WHPX 和 user-mode NAT 限制 |
| Windows/WHPX | 任意 nested Hyper-V/WSL2/KVM 场景 | 明确拒绝 | 当前启动器不承诺 WHPX nested；`-RequireNestedVirtualization` 会提前失败 |
| 任意宿主 | TCG fallback | 仅显式功能模式 | Linux 主路径不应回退；Windows 必须显式 `-AllowTcgFallback`，此时 CPU 改为 `max`，不计入真机化或性能支持 |

QEMU 官方将 WHPX 定义为 Windows Hypervisor Platform 的加速后端，要求安装 HypervisorPlatform；x86_64 从 Windows 10 2004 开始测试，并列出 MMIO 指令、VGA 和中断等已知限制。[QEMU WHPX 文档](https://www.qemu.org/docs/master/system/whpx.html)

Microsoft 说明 WHP 是供第三方虚拟化栈创建 partition、映射内存和控制虚拟处理器的用户态 API；可查询的 CPU 能力来自实际 hypervisor/硬件平台，这也是 Windows 路线不能任意塑造另一颗 CPU 的原因。[Microsoft Windows Hypervisor Platform API](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/hypervisor-platform)

Windows 11 对 VM 仍要求 UEFI/Secure Boot、TPM 2.0、至少 4GB 内存和两个虚拟处理器；本项目 Windows/WHPX 路线的拒绝策略是正确的保守行为。[Microsoft Windows 11 requirements](https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements)

## 6. E5 与 X99/C612 物理宿主评估

### 6.1 代际矩阵

| 宿主 CPU 类别 | 常见物理平台 | KVM 基础能力 | 当前 Linux 严格 VMate | 当前 Windows 严格 VMate |
|---|---|---|---|---|
| E5 v1 / Sandy Bridge-EP | LGA2011、X79/C60x、DDR3 | 有 VT-x/EPT 的 SKU 可运行 KVM | 通常无 TSC/CPUID 合格候选；必须实测，不能与 X99 混装 | 不支持：没有精确同名启用 SKU |
| E5 v2 / Ivy Bridge-EP | LGA2011、X79/C60x、DDR3 | 代表 SKU 支持 VT-x/EPT | 与 v1 类似；当前平台清单不含适配它的 guest bundle | 不支持 |
| E5 v3 / Haswell-EP | LGA2011-3、X99/C612、DDR4 | 一般适合作 KVM 宿主 | 条件支持；先过 TSC 候选，再过 Skylake target realize | 不支持 |
| E5 v4 / Broadwell-EP | LGA2011-3、X99/C612、DDR4 | 一般适合作 KVM 宿主 | 当前最有希望的 E5 路线；无 scaling 且实际 TSC≈2200 MHz 时只会选 i5-6400T bundle，realize 决定最终结果 | 不支持 |
| E5 v3/v4 双路 | 双路 C612 服务器/工作站板 | KVM + 多 NUMA node | 条件支持；pinner 优先把单 VM 放入一个 node，容量不足才跨 node；尚无双路实机长稳证据 | 不支持 |

Intel 的 E5-2697 v2 ARK 页面可作为 v2 家族代表，确认 FCLGA2011、最大 2 路、VT-x/EPT、VT-d 和 PCIe 3.0；它不能证明任意 v2 SKU或主板组合。[Intel E5-2697 v2 规格](https://www.intel.com/content/www/us/en/products/sku/75283/intel-xeon-processor-e52697-v2-30m-cache-2-70-ghz/specifications.html)

Intel 的 E5-2699 v4 ARK 页面可作为标准 v4 家族代表，确认 Broadwell、DDR4、2S、VT-x/EPT 和 PCIe 3.0；这些字段不能移植成 E5-2696 v4 的标准规格，因为后者由 OEM 定义。[Intel E5-2699 v4 规格](https://www.intel.com/content/www/us/en/products/sku/91317/intel-xeon-processor-e52699-v4-55m-cache-2-20-ghz/specifications.html)

ASUS X99-E 官方 CPU 支持表列出许多 E5 v3/v4，并按最低 BIOS 版本区分，同时提示 Xeon 在 X99 上可能有功能限制。该表中没有 E5-2696 v4，因此“同为 LGA2011-3”不能替代主板厂商验证。[ASUS X99-E CPU support](https://www.asus.com/us/supportonly/x99-e/helpdesk_cpu/)

### 6.2 E5-2696 v4 + X99 必须满足的物理前提

1. **主板确认**：核对准确型号、PCB revision、官方/定制 BIOS、微码和 CPU support list。OEM E5-2696 v4 不在标准 ARK 和常见公开支持表内时，必须取得主板厂商或整机厂商证据。
2. **供电与散热**：按实际 OEM SKU 的 TDP/PL1/PL2、全核负载和 VRM 能力验收；不能直接套用 E5-2699 v4 参数。
3. **内存**：确认主板支持的是 UDIMM、ECC UDIMM 还是 RDIMM，确认容量、rank、通道和 BIOS 训练；X99 消费板不能因为 CPU 支持 ECC 就推导出支持任意服务器 RDIMM。
4. **虚拟化**：BIOS 开启 VT-x 和 EPT；本分支不做 GPU passthrough/vGPU，因此 VT-d/IOMMU 不是当前必要条件。
5. **微码/内核**：安装最新可用 BIOS 微码和受支持 Linux 内核，保留安全缓解；不要为性能关闭宿主漏洞缓解。
6. **同构双路**：双路板使用相同 SKU、stepping、微码和对称内存；混插或单侧内存不平衡不进入支持范围。

### 6.3 TSC 与 CPU realize 是决定性门禁

`deploy/scripts/kvm-capabilities.py` 直接通过 KVM UAPI 查询 `KVM_CAP_TSC_CONTROL`、`KVM_CAP_GET_TSC_KHZ`，并创建临时 VM/vCPU 读取 `KVM_GET_TSC_KHZ`。Linux 内核文档规定 `KVM_SET_TSC_KHZ` 的单位是 kHz，且能力必须由 KVM capability 宣告；不能只看 CPU 商品名猜测。[Linux KVM API](https://www.kernel.org/doc/html/latest/virt/kvm/api.html)

当前策略：

- 有 TSC control：可请求 profile TSC，仍需 QEMU/KVM realize 成功。
- 无 TSC control：目标和实际 vCPU TSC 必须在 250 ppm 内；选平台时还会先做 MHz 精确过滤。
- E5 实际 TSC 为 2200 MHz 时，当前 4C/4T 候选只有 i5-6400T/H110。
- 选中后以 `-cpu ...,enforce=on` 创建最小 4-vCPU Q35/KVM 实例；退出码、QMP quit 和 stderr 任一异常/警告都会拒绝。
- 因此“选择到了 i5-6400T”不等于通过；Broadwell-EP 是否能实现项目配置的 Skylake-Client CPUID，以这次 smoke 为准。

QEMU 官方建议不需要迁移时使用 host passthrough 以获得最完整性能和宿主特性；本项目为了固定客体身份选择 named model，必然牺牲部分宿主覆盖面，并必须自行做 compatibility check。[QEMU/KVM CPU model 文档](https://www.qemu.org/docs/master/system/qemu-cpu-models.html)

### 6.4 单路与双路性能判断

- X99 是单路场景；高核心 E5 的优势主要是多 VM 容量，不代表单个 4-vCPU VM 会自动更快。
- 双路 C612 的核心和内存分属不同 NUMA node。当前 pinner 先选可容纳 vCPU + service CPU 的单一 node，并优先物理主线程、后用 SMT；这是正确默认。
- 单 node 容量不足时跨 node 只是退化运行，不应作为低延迟支持配置。应减少单 VM vCPU、减少并发 VM，或重新平衡每 socket 内存。
- 默认全局 CPU frequency cap 已关闭，避免一台 VM 降低整台双路宿主频率；应使用 cpuset/NUMA 放置保证隔离。
- irqbalance 保持运行。若要隔离 IRQ，应配置 banned CPUs/IRQ affinity，而不是在高核 E5 上全局停掉 irqbalance。

Linux KVM nested 在新内核通常可用，但需要 `nested`、EPT、VMX 暴露和额外测试；当前 VMate 默认平台没有把 nested 当成受支持功能。内核文档给出 `kvm_intel nested`、Shadow VMCS、APICv 和 EPT 的检查方法。[Linux KVM nested 文档](https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html)

Microsoft 的 nested Hyper-V 支持条件针对 Hyper-V 管理的 VM，并要求 Intel VT-x/EPT 或符合条件的 AMD 平台；Microsoft 同时说明非 Microsoft virtualization 的嵌套组合不属于其测试支持范围，所以不能据此推导 QEMU/WHPX nested 受支持。[Microsoft nested virtualization](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/nested-virtualization)

## 7. 已处理项与剩余优先级

### P0 已处理

- CPU/主板/BIOS 从独立随机改为版本化完整平台 bundle；未知 schema、禁用平台、跨厂商和无候选均 fail closed。
- AMD B350 仅保留 compatibility 且不进入严格随机池。
- AMD compatibility 只需独立 allow 开关显式授权，再按宿主约束自动匹配；平台 ID 只作可选的高级固定或一致性断言。该入口只放宽 Q35 machine fidelity，不再要求用 `STRICT_HARDWARE=0` 连带跳过 CPU/TPM 等门禁。
- CPU 物理地址位改为“宿主下限预检 + `host-phys-bits-limit`”，避免 48-bit 宿主实现 39/43-bit 目标时产生 warning 或泄漏宿主值。
- KVM/TSC 真能力探测、250 ppm 判断和选型前 TSC 过滤。
- 选型后真实 QEMU/KVM CPU realize smoke，拒绝 warning、缺 QMP 响应和伪成功。
- NVMe/EDID/HID 收敛到 C 行为层真正支持的单一完整组件模板。
- 严格 TPM 请求在 swtpm 缺失、初始化失败或 socket 超时时不再静默降级。
- sudoers 不再指向用户可写工作区脚本；改为 root-owned `/usr/local/libexec` helper、`NOSETENV` 和参数白名单。
- CPU isolate 的全局锁已从可置换的 `/tmp` 移到 root:root 0700 的 `/run/qemu-vmate-cpu-isolate`；打开前后校验 symlink、owner、mode、link count 和 inode，并有“锁指向 victim 不得截断”的 user-namespace 回归。
- CPU isolate 只接受 sudo 调用 UID 自己拥有的 `qemu-system-x86_64`，逐一核对 vCPU TID/Tgid/comm、PID starttime 和实例登记；单次/累计分配至少给宿主保留两个在线 CPU。
- swtpm CA 改为每实例私有目录，不再改动系统 `/var/lib/swtpm-localca` 的 owner；TPM state、socket、log 也拒绝 symlink 和不安全目录。
- Windows 默认 WHPX、无静默 TCG；精确宿主 SKU 门禁；Win11/nested 未满足时在写状态前拒绝。
- Windows 在读取共享清单时已与 Linux 同步锁定 `enabled/status/fidelity/BDF` 语义；内存/vCPU/宿主拓扑在任何 profile 写入或 reroll 备份前验证。

### P0 仍需实机完成

- 在目标 E5-2696 v4 + 准确 X99 型号上取得 BIOS 启动、KVM capability、CPU realize 和 24 小时长稳证据。
- 在至少一台受支持 Windows 10 物理宿主上验证 WHPX patched build、驱动、显示、I/O 和关机清理。
- Linux/Windows 11 路线必须验证 Secure Boot operational state、已注册 PK/KEK/db 和 TPM PCR/Measured Boot；仅有 Tcg2 模块不够。
- 每台实际 Linux 宿主必须在本地终端完成一次集成式 `deploy/tools/build.sh`，或在无人值守
  部署中显式使用 `--install-host-helpers`；编译入口的安装与 `check` 成功才代表目标机
  已更新 root-owned helper、QEMU 信任摘要并移除旧 sudoers。

### P1 已处理

- MCH/LPC/SMBus/AHCI/HDA/root port/xHCI PCI 身份可参数化并有非法值失败测试。
- SMBIOS Type 3/4/17 深层字段、DDR3/DDR4 SPD、合法 DIMM 拓扑和单 guest NUMA node。
- NUMA-aware vCPU/service thread pinner、cgroup v2 cpuset、多 VM 避让和管理核预留。
- profile 安全解析、平台/组件事实绑定、持久化序列号和显式 legacy reroll。
- Linux bridge/TAP/VLAN 严格失败策略；NAT fallback 会明确标注。
- Windows/Linux 客体硬件快照采集器、异步测试调度器和 QMP soak monitor。
- DIMM Type 17 已把料号额定速率与平台训练后的配置速率分开，Q35 SPD 只使用额定速率；DDR4 256B 容量声明、2/4/8/16Gb 地址几何和 tRFC 均有 C 单测。
- 自定义 `VM_DIR` 的 canonical TPM state 会原子登记在用户私有 runtime；stop/reaper 不再硬编码 `*/vms/<instance>`，并有自定义路径、旧默认路径、恶意 symlink 和孤儿锁回归。

### P1 剩余

- 实现真正 H110/H310 machine behavior，或继续把相关字段明确标为 identity compatibility，不能提升为“芯片组仿真完成”。
- 实现完整 EE1004 512B/page-select，并签入与具体 DIMM 料号对应的 page 1 manufacturer/serial/part raw SPD；当前 256B 是自洽的基础 SPD，不是品牌 DIMM 原始镜像。
- 把 Linux/Windows DIMM 手写兼容池迁入带 revision、`source_refs`、原始 SPD hash 和 profile digest 的版本化组件目录。
- ALC887 完整 codec widget/插孔模型和可选真实音频 backend。
- Windows TAP/bridge 后端；当前 SLIRP NAT 既影响性能，也与物理 LAN 拓扑不同。
- 自动把 guest snapshot 与 profile/manifest 做字段级 diff；现有采集器只收证据，不自动判定所有跨表关系。
- Linux 启动器增加显式 `GuestOs=Windows/Linux`，为 Linux guest 使用 UTC RTC、通用名称和安装流程。
- Windows QMP 从固定 localhost TCP 端口迁到带 ACL 的 named pipe/私有通道，降低同宿主本地进程访问面。

### P2 已处理

- GitHub CI 包含 shell/Python 检查、并发 quick tests、最小 x86_64 QEMU `--enable-werror` 构建和 C 硬件身份测试。
- `soak-vm.py` 可异步轮询 QMP status、vCPU、内存、blockstats、进程 RSS，并输出 JSONL/summary。
- CPU pinner、guest collectors、测试 runner、Windows profile、SPD 映射与 fb-shm 大文件已拆分；新增自有模块和脚本均保持在 500 行约束内（注释不计）。
- 本次仍局部修改的 `hw/nvme/ctrl.c`、既有配套头文件 `hw/nvme/nvme.h`、`hw/smbios/smbios.c`、`hw/audio/*`、`hw/usb/dev-hid.c`、`hw/isa/lpc_ich9.c`、`hw/pci-host/q35.c`、`hw/net/e1000e.c`、`hw/display/edid-generate.c` 是上游既有大型设备模型 translation unit/header。为保持 QEMU 上游对象/迁移状态/构建结构，未在本分支把整份上游文件机械拆开；新增逻辑已尽量抽到独立模块（例如 SPD 与 fb-shm），这些上游文件是明确的 500 行例外。

### P2 剩余

- 目标 E5 单路/双路上的 24/72 小时实测结果、并发 VM 密度、P95/P99 延迟、功耗和温度基线。
- swtpm 崩溃、QMP 断连、磁盘满、host suspend/resume、QEMU SIGKILL 和网络重配的故障注入。
- Windows 原生 CI/签名包 smoke；Linux CI 上的 PowerShell 静态测试不能替代真实 WHPX。
- manifest 来源快照、审核人、采集命令、原始 `lspci/dmidecode/edid` hash 与签名发布流程。

## 8. 性能、安全与稳定性优化建议

按优先级建议：

1. 先完成 E5/X99 实机门禁和长稳，不为通过率放宽 `enforce=on`、TSC 或 warning 拒绝条件。
2. E5 双路上每台 4-vCPU VM 固定单 NUMA node，并按需配置 1 个 service CPU；禁止超卖后再用全局 frequency cap 掩盖调度抖动。
3. Linux 网络统一使用 bridge/TAP；生产严格模式不允许无意回落到 10.0.2.x SLIRP。
4. 保持 `cache=none,aio=threads` 的已验证路径；若要增加 iothread，先修正和验证 NVMe BlockBackend AioContext，再做 fio/掉电恢复测试。
5. 保持 THP `madvise`、`defrag=never`；当前 memfd backend 不使用预留 hugetlbfs 池，禁止无效地预留大量 hugepages。
6. 保留 irqbalance 和宿主安全缓解；只对 VM 专属 CPU 配置 IRQ affinity，不全局停服务。
7. QEMU 以非 root 用户运行，限制 VM 目录、profile、QMP、TAP 和磁盘权限；root helper 只保留固定副本和最小命令集。QEMU 官方也建议用非 root、设备组、sandbox/cgroup 限制宿主访问面。[QEMU security](https://www.qemu.org/docs/master/system/security.html)
8. 为 Windows QMP、fb-shm 和输出目录添加 ACL；不要把 `ExtraQemuArgs` 暴露给不可信调用者。
9. 每次 platform/component catalog 变化都视为硬件迁移，必须人工审计、更新 revision，并对旧 profile 做显式决策。

## 9. 验收命令

### 9.1 Linux 宿主安装与静态回归

```bash
# 编译、可选验证、安装 root-owned helper 及 check 由同一入口串行完成
deploy/tools/build.sh --install-host-helpers

python3 deploy/scripts/kvm-capabilities.py --format json
python3 deploy/scripts/tests/run-vmate-tests.py --mode quick --jobs 4
python3 deploy/scripts/tests/run-vmate-tests.py --mode full

ninja -C build -j"$(nproc)" qemu-system-x86_64
QEMU="$PWD/build/qemu-system-x86_64" \
  bash deploy/scripts/tests/test_c_hardware_identity.sh
```

编译入口在 `ninja`、二进制检查和可选 `--verify` 成功后调用
`setup-host-helpers.sh install --qemu=<本次构建产物>`，再执行 `check`。安装器把 QEMU
规范路径、device/inode 与 SHA-256 写入 root-owned 信任清单，同时更新调优/隔离 helper
固定副本和最小 sudoers。它不是每次 VM 启动运行的脚本；重新编译或修改 helper 后只需
重新运行编译入口，宿主重启不需要重复安装。install/check 由 root-owned `flock` 串行化；
安装先在 staging 校验全部文件，发布时暂时撤下 sudoers，并以版本化 runtime、main 最后
切换和失败回滚避免并发覆盖或混合版本。

CI/无终端构建的默认 `auto` 策略会明确跳过宿主修改；真实目标机无人值守部署必须显式
传 `--install-host-helpers`，而纯打包任务应传 `--no-install-host-helpers`。若使用仓库外
另一份经过审核的 patched QEMU，才直接使用低层安装器登记并检查：

```bash
sudo deploy/scripts/setup-host-helpers.sh install \
  --qemu=/absolute/path/to/qemu-system-x86_64
sudo deploy/scripts/setup-host-helpers.sh check
```

这项约束只授权管理员登记的精确可执行文件进入 root cpuset 事务；同名文件或只伪造
进程名不会通过。源码已更新并不代表目标机 `/usr/local/libexec` 中的固定副本已更新。

正式 CI 还应以 `--enable-werror` 配置一个干净 build 目录；复用旧 build 成功不能证明没有新增 warning。

### 9.2 E5/X99 宿主预检

```bash
lscpu -e=CPU,NODE,SOCKET,CORE,ONLINE,MAXMHZ,MINMHZ
sudo dmidecode --type 0,2,4,16,17
grep -E 'vendor_id|model name|microcode|flags' /proc/cpuinfo | head -40
cat /sys/module/kvm_intel/parameters/ept 2>/dev/null
cat /sys/module/kvm_intel/parameters/nested 2>/dev/null
python3 deploy/scripts/kvm-capabilities.py --format json
```

在目标机使用现有/一次性磁盘做严格 dry-run。该命令仍会执行真实 KVM CPU realize，但不会创建 profile、磁盘、OVMF vars 或 swtpm state：

```bash
STRICT_HARDWARE=1 DRY_RUN=1 \
  deploy/scripts/start-vm.sh 1 \
  --qemu="$PWD/build/qemu-system-x86_64" \
  --disk=/path/to/existing-test.qcow2 \
  --cpus=4 --ram=8192 --no-host-tune --no-cpu-isolate
```

E5-2696 v4/X99 只有在以下全部满足时才能从“条件支持”提升：

- 主板厂商/整机厂商确认该 CPU + BIOS + 内存组合。
- KVM JSON 为 `available=true`。
- 若 `tsc_control=false`，实际 TSC 与所选 2200 MHz profile 在 250 ppm 内。
- dry-run CPU realize 退出码为 0，且没有 warning/error/unsupported。
- 客体快照与 profile/manifest 一致。
- 24 小时 soak 无 QMP 连续失败、非 running 状态、进程退出或内核/客体关键错误。

### 9.3 客体枚举快照

Linux 客体：

```bash
sudo deploy/scripts/guest/collect-hardware-snapshot.sh /tmp/vmate-hardware-linux
```

Windows 客体（管理员 PowerShell 可取得更完整证据）：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\deploy\windows\collect-hardware-snapshot.ps1 `
  -OutputDirectory C:\Temp\vmate-hardware-windows `
  -Parallelism 4 -TimeoutSeconds 90
```

至少人工核对 CPU/核心线程、SMBIOS 0/1/2/3/4/16/17、PCI 主/子系统 ID、PCIe link、NVMe Identify/容量/firmware/SubNQN、NIC OUI、USB descriptor、EDID、TPM、Secure Boot、设备驱动和本次启动 warning。

### 9.4 长稳

```bash
python3 deploy/scripts/soak-vm.py \
  --qmp /tmp/qemu-stealth-1.qmp \
  --pid "$(pgrep -n -f 'qemu-system-x86_64.*win10-1')" \
  --duration 24h --interval 30 \
  --output /var/tmp/vmate-e5-x99-soak.jsonl
```

长稳通过不等于性能通过。还应分别记录 idle、单 VM 满载、多 VM 满载下的 guest benchmark、host steal/scheduler latency、NUMA remote access、磁盘 P99、网络 P99、RSS、温度和功耗。

## 10. 不可消除或本分支不处理的边界

- GPU passthrough/vGPU 不在本分支；即使 Linux 写入物理 GPU 的 subsystem/revision，或显式覆盖主 VEN/DEV，virtio 显示设备的驱动和行为也不会变成真实独显。
- Q35/ICH9、OVMF、通用 NVMe、e1000e、qemu-xhci 和 virtio-gpu 的行为可被深层探测；改 ID 不改变实现。
- 宿主 CPU 的 cache、MSR、微码、漏洞缓解、性能计数器和时序不能被 SMBIOS 字符串完全重塑。
- TSC scaling 只能在硬件/KVM 宣告能力时使用；软件不能安全伪造不存在的能力。
- E5-2696 v4 是 OEM 定制 SKU，没有标准 ARK；二手市场标签、ES/QS 状态、改微码 BIOS 和主板魔改均超出项目可验证范围。
- WHPX 暴露宿主 CPU 面，严格真机化只能支持 manifest 中与宿主精确同名的 SKU；放宽 mismatch 就必须降低真实性评级。
- TPM emulator 与真实离散/固件 TPM 的证书链、抗篡改和厂商实现不等价。
- 任何基于虚拟化的方案都不能承诺绕过第三方安全产品、仿真机、许可证或设备认证；验收应以合法业务兼容性、稳定性和可审计一致性为准。

最终判断：**当前代码已经把“会随机出不存在硬件”的主要结构性问题收敛为 fail-closed 的有限真实目录（DIMM 仍是明确降级的受限兼容池），也为 E5/X99 提供了正确的软件判定路径；但 E5-2696 v4/X99、双路 E5 和 Windows/WHPX 都必须以目标实机结果收口。在这些证据产生前，最准确的发布标签是“Linux/KVM 条件支持，Windows/WHPX 受限支持，非 GPU 硬件身份高一致性”，而不是“全平台完成”。**
