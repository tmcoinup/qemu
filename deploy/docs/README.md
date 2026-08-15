# VMate 部署文档

> 当前维护基线：QEMU `11.0.2`，分支 `P-11`。P-11 的主新增能力是独立的
> Windows Hyper-V GPU-P 后端；它不复用 V-11 guest 镜像、VioGpuDod 或身份投影。
> QEMU 可执行文件、QMP/QGA 协议和设备模型名称继续沿用上游名称。

P-11 新建 VM、NVIDIA/AMD 动态选择、官方 Windows WDDM 驱动同步及严格验收先看
[P-11 Hyper-V GPU-P 后端](HYPERV-GPU-P.md)。本文其余 QEMU/KVM/WHPX 内容作为
仓库的非 GPU-P 参考，不定义 P-11 guest 镜像。

仓库继承的 QEMU 路径仍应定位为：**Linux/KVM 优先、Windows/WHPX 受限支持、非 GPU
硬件身份高度一致，但底层仍是 Q35/ICH9/QEMU 设备行为的条件可用方案**。这段定位不适用于
P-11 的 Hyper-V GPU-P VM；P-11 的保证和限制只以专门文档为准。旧路径通过有限、可审计的整机和组件目录
避免随机出不存在或互相矛盾的组合，不承诺把虚拟机变成不可识别的物理机。

完整完成度、E5-2696 v4/X99、其它 E5、Windows/Linux 兼容性及优化结论见
[硬件平台评估](HARDWARE_PLATFORM_ASSESSMENT_2026-07-13.md)。

## 当前范围

| 范围 | 当前状态 |
|---|---|
| Linux 宿主 | QEMU/KVM 参考路径；不提供 Hyper-V GPU-P，也不复制 Linux 驱动到 Windows guest |
| Windows 宿主 | P-11 使用 Hyper-V GPU-P；QEMU/WHPX 路径仅作独立参考 |
| Windows 10 客体 | Linux/KVM 主验收对象 |
| Windows 11 客体 | 有 TPM 2.0 路径，但 Secure Boot operational state 尚未闭环，不宣称正式支持 |
| Linux 客体 | QEMU 设备功能兼容；启动器的命名、RTC 和安装流程仍偏向 Windows |
| Intel SMBus | 全池 A323/A123/1C22/1E22/8C22 使用五套 WHCP NO_DRV INF；2930 使用 Win10 inbox `machine.inf` |
| GPU | P-11 动态枚举真实 NVIDIA/AMD partitionable GPU、同步匹配的 Windows WDDM 驱动并配置 GPU-P；不做 PCIe 整卡直通，不使用旧 virtio/身份投影 guest |

## 唯一事实源

- [`deploy/hardware/platforms.json`](../hardware/platforms.json)：整机平台 schema、CPU、主板、
  BIOS、芯片组 PCI 身份、内存限制、网卡、音频和链路能力；顶层 `fidelity` 同时记录
  Q35 machine 行为边界和两个启动器实际生成的 BDF。
- [`deploy/hardware/components.json`](../hardware/components.json)：可更换部件入口、
  显示器 EDID、键盘、鼠标和通用绝对指针模板。
- [`deploy/hardware/gpu-boards.json`](../hardware/gpu-boards.json)：18 块启用 AIB
  的品牌、料号、逻辑主 ID、真实 subsystem、VBIOS、显存/时钟及
  `1AF4:A101`–`1AF4:A112` 内部 virtio carrier；由组件入口引用。目录不定义或
  合成未标准化的 GPU 序列号。
- [`deploy/hardware/storage.json`](../hardware/storage.json)：只含四款精确 512GB
  NVMe 的型号、料号、固件、PCI/subsystem、OUI 和序列号策略；由组件入口引用。
- [`deploy/hardware/household-compatibility.json`](../hardware/household-compatibility.json)：
  Linux 家用跨代候选与完整 CPU/主板/内存事实。
- [`deploy/hardware/storage-compatibility.json`](../hardware/storage-compatibility.json)：
  不支持 NVMe 启动的平台使用的 SATA 启动盘组合。
- [`deploy/hardware/host-compatibility.json`](../hardware/host-compatibility.json)：
  Linux/KVM 的显式宿主兼容模板和 Windows 未来恢复该能力时的共享格式。Windows
  当前不能兑现完整 CPUID/TSC 绑定及等价 WHPX realize，因此启动器 fail-closed。
- 每台 VM 的 Linux `vms/<N>/profile` 或 Windows `hardware-profile.json`：从上述
  目录选出整套事实后持久化平台 ID、目录修订号、UUID、MAC 和序列号。两种格式目前
  不能跨宿主直接互换；Linux 字段见 [Profile 字段](PROFILE-FIELDS.md)，Windows
  边界见 [Windows 打包与启动](WINDOWS-PACKAGING.md)。

旧的独立 CPU/主板/BIOS 随机池和“十款 NVMe/显示器/HID 任意组合”不再是当前实现。
型号数量少是有意设计：一个行为和深层字段能对齐的完整模板，比多个只替换字符串的模板可信。

## 当前启用整机

新 profile 优先从已启用且 `status=supported` 的主清单或 household registry
整机 bundle 中选择。这里的
`supported` 严格表示“通过运行时宿主门禁后可成为启动器候选”，不表示 Q35 machine、
PCI BDF、寄存器或 PCH 行为与目标 H110/H310 等价：

| Platform ID | CPU | 主板 / PCH | 内存 | 状态 |
|---|---|---|---|---|
| `intel-lga1151-i3-9100f-asus-prime-h310m-a-r2` | i3-9100F，4C/4T | ASUS PRIME H310M-A R2.0 / H310 | DDR4，2/4/8 GiB | 启用候选；Q35 identity compatibility |
| `intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2` | G4900，2C/2T | ASUS PRIME H310M-A R2.0 / H310 | DDR4，2/4/8 GiB | 启用候选；Q35 identity compatibility |
| `intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2` | G5400，2C/4T | ASUS PRIME H310M-A R2.0 / H310 | DDR4，2/4/8 GiB | 启用候选；Q35 identity compatibility |
| `intel-lga1151-i5-6400t-asus-h110m-a-m2` | i5-6400T，4C/4T | ASUS H110M-A/M.2 / H110 | DDR4，2/4/8 GiB | 启用候选；Q35 identity compatibility |
| `compat-haswell-g3220-h81` | G3220，2C/2T | ASUS H81M-K / H81 | DDR3，2/4/8 GiB | E5 v3/v4 默认正常池；Q35 identity compatibility |
| `compat-haswell-i3-4130-h81` | i3-4130，2C/4T | ASUS H81M-K / H81 | DDR3，2/4/8 GiB | E5 v3/v4 默认正常池；Q35 identity compatibility |
| `compat-haswell-i5-4570-h81` | i5-4570，4C/4T | ASUS H81M-K / H81 | DDR3，2/4/8 GiB | E5 v3/v4 默认正常池；Q35 identity compatibility |

三个 H81 条目保留历史 `compat-` ID 以兼容已有 profile；授权依据 registry 中的
`PLATFORM_STATUS=supported`，不依据 ID 文本。旧 revision 的同 ID
`compatibility` profile 会在内存中单向提升，文件不会被改写。

Ryzen 3 1200 + PRIME B350-PLUS 条目仅保留为 `compatibility`，默认禁用。当前 machine type
仍是 Intel Q35/ICH9；只改成 AMD PCI ID 不能得到 B350 行为，因此 AMD 宿主在严格模式下
默认没有可用新建候选，也不会静默回退到伪 AMD 整机。需要先安装/功能验证时，可显式
使用 `--allow-platform-compatibility`。启动器按宿主 CPU vendor、`CPUS`、最大频率和
TSC 约束自动匹配：始终优先选择 `supported`，只在没有可用 `supported` 候选时回退到
`compatibility`。已有 profile 继续复用持久化的 `PLATFORM_ID`；`--platform-id` 仅作高级固定或
一致性断言。该窄入口不会把 `STRICT_HARDWARE` 改成 `0`，仍继续执行 KVM/TSC、
CPU realize、profile、磁盘，以及平台自动启用或请求 `TPM=1` 时的 TPM 严格门禁，只接受整机
machine fidelity 不完整。
若没有 `supported` 匹配，但宿主确实能匹配某个 `compatibility` 模板，启动器会明确
提示追加 `--allow-platform-compatibility`；若该 allow 也无法找到候选，则不会误导性地给出此提示。

## 当前启用组件

| 类别 | 启用模板 | 关键约束 |
|---|---|---|
| GPU AIB | GT 1030、GTX 750 Ti、GTX 1050、GTX 1050 Ti、RX 550、RX 560 各 3 个品牌，共 18 块（12 NVIDIA、6 AMD） | 新 profile 按 21 列原子 bundle 绑定品牌/料号、逻辑 `10de`/`1002` 主 ID、真实 AIB subsystem 与 VBIOS；物理显示主 ID 始终为 virtio `1AF4:1050`，`1AF4:a101`–`1AF4:a112` 只作受控 carrier；不虚构 GPU serial |
| NVMe | Samsung 970 PRO、Intel 760p、WD PC SN730、KIOXIA XG6（均为 512GB） | 四项容量都精确为 `512110190592` 字节；型号、固件、PCI/subsystem、OUI 和厂商序列形态绑定为一个 `x-identity-profile`，NQN 使用标准 UUID 格式 |
| 显示器 | Samsung S24F350、AOC 24B2XH、Xiaomi RMMNT238NF、Lenovo L24e-30 | 全部固定 1920×1080、16:9；官方规格与 raw EDID 锁定完整身份，EDID 是事实源；统一 EXE 只用 `DEVPKEY_Device_FriendlyName` 投影标签，不改 EDID/HardwareID/INF/`monitor.sys` |
| 键盘 | Microsoft Wired Keyboard 600 | `045e:0750`、`bcdDevice=0163`；只绑定品牌身份，report descriptor 仍是通用实现；不暴露序列号 |
| 鼠标 | Microsoft USB Optical Mouse | `045e:00cb`、`bcdDevice=0163`；只绑定品牌身份，report descriptor 仍是通用实现；不暴露序列号 |
| 绝对指针 | QEMU USB Tablet | `0627:0001`，明确为通用虚拟设备，不冒充品牌数位板 |

四款 EDID PnP 映射为 `SAM0D20→Samsung S24F350`、`AOC2402→AOC 24B2XH`、
`XMI23C3→Xiaomi Mi Monitor (RMMNT238NF)`、`LEN66BC→Lenovo L24e-30`。

组件型号只从完整条目按稳定 ID 选择，禁止跨条目拼接；旧的六款 NVIDIA/AMD generic
GPU label 只用于已有 profile 的只读回查，不进入新 VM 抽签池。每台 VM 仍会生成并持久化 UUID、
MAC、主板/系统/机箱/CPU/DIMM、NVMe 和 EDID 序列号。键鼠模板声明不暴露 USB
serial，profile 内的稳定派生值不会送进描述符。
GPU 目录同样明确 `serial_exposed=false`：本项目没有 `GPU_SERIAL` 投影，也不会用
主板、显存或其它设备序列号冒充显卡序列号。
新 VM 的活动 DIMM 池包含 Samsung、Kingston、Crucial 三组 DDR4-2400，以及供
Sandy/Ivy/Haswell household bundle 使用的 Kingston、SK hynix DDR3-1333/1600。
缺精确料号或修订证据的 Hynix DDR4 和 Crucial DDR3 位于 quarantine，不会被严格
profile 或随机选择接受。

## 严格启动链

Linux 启动器默认按以下顺序 fail closed：

1. 检查 patched QEMU、KVM 和 TSC 能力。
2. 按宿主 CPU 厂商、目标 SKU 的完整 2/4 线程拓扑、宿主最大频率和 TSC 约束选择整机 bundle。
3. 用实际 QEMU/KVM 和 `enforce=on` 创建最小 vCPU，拒绝 warning、unsupported 或失败。
4. 校验 profile 的 platform/component schema、目录修订号及每个绑定字段。
5. 校验 qcow2 的 guest 可见虚拟容量等于实际启动盘的 `BOOT_STORAGE_SIZE_BYTES`。
6. 默认 `TPM=auto`，按主板 profile 选择支持状态、1.2/2.0 和 TIS/CRB；严格模式下
   swtpm、状态初始化、state 绑定或 socket 失败都会停止。`TPM=0` 可显式关闭。
7. 组装单 guest NUMA node；DIMM 数和双通道只通过 SMBIOS/SPD 表达。

`STRICT_HARDWARE=0` 仅用于开发和兼容诊断，不代表真机化验收结果。旧 profile 即使在
非严格模式也必须显式追加 `--allow-legacy-profile`，避免删除 manifest 元数据后静默
绕过平台授权。旧 profile 在严格模式下
必须显式 reroll；这会改变硬件身份并可能触发 Windows 重新激活。

## 真机化边界

| 硬件面 | 可见身份 | 行为边界 |
|---|---|---|
| CPU/SMBIOS/内存 | 平台字段、拓扑、Type 0/1/2/3/4/16/17；DIMM 额定/配置速率分离；DDR4 使用 512B EE1004 与 0x36/0x37 页选择，并把硬件目录中的品牌、料号和唯一序列号投影到 SPD page 1 | cache、MSR、微码、性能和时序仍受宿主及 KVM 限制；SPD 是按目录字段生成的标准数据，不是具体 DIMM 的原始 raw dump/XMP |
| 芯片组/PCIe/xHCI | 全 SMBus 池用 NO_DRV 正确归类和命名；芯片组与 root port 身份/链路可注入；xHCI 平台字段仅留作事实 | 五款 payload 不含 `.sys`/服务，2930 只用 inbox `machine.inf`；实现仍是 Q35/ICH9/QEMU 控制器；`qemu-xhci` 固定与行为匹配的 `1B36:000D rev01 / SUBSYS 1AF4:1100`；Linux 为 root port `00:01.0`–`00:04.0`、HDA `00:05.0`，Windows 少一个空端口、HDA 为 `00:04.0`，均不承诺目标 PCH BDF/silicon 等价 |
| NVMe | Identify、容量、PCI/subsystem、SubNQN 可绑定 | SMART、热管理、功耗和错误恢复仍是通用 QEMU NVMe |
| 音频 | HDA controller 和 ALC887 codec 身份 | `protocol_identity_only`，widget、插孔和板级布线不等价 |
| EDID/HID | EDID 型号规格成套，并按其 PnP code 投影 Monitor FriendlyName；HID 仅绑定 VID/PID/名称 | FriendlyName 不改变 EDID、HardwareID、INF 或 `monitor.sys`；EDID 产品码/制造信息是明确标注的合成值；键鼠 report descriptor 仍是通用实现 |
| 显示/GPU | 内核枚举固定为唯一 virtio `1AF4:1050` devnode；HardwareID 使用逻辑首项 + 物理尾项，NVAPI 以物理 carrier 跨接口关联并保留逻辑 external/AIB/型号 | `audited_aib_bundle_shallow_user_projection_no_passthrough`；不改变 virtio 驱动、寄存器、显存分配或 3D 性能，不代表 NVIDIA/AMD 物理 GPU，也不虚构 GPU 序列号 |

xHCI 的 USB 链路/设备电源管理属于正常真机行为；本项目只禁止把通用虚拟控制器冒充为
需要不同厂商 workaround 的 PCH。详细边界见 `PROFILE-FIELDS.md` 的
“xHCI 电源管理边界”。

## 快速开始

```bash
# 构建 patched QEMU；本地终端成功后自动同步并校验 root-owned helper
# 编译脚本以普通用户运行，安装阶段可能提示一次 sudo 密码
deploy/tools/build.sh

# 检查 KVM/TSC，并运行快速回归
python3 deploy/scripts/kvm-capabilities.py --format json
python3 deploy/scripts/tests/run-vmate-tests.py --mode quick --jobs 4

# 首次启动会生成并保存 profile；默认 8 GiB、4 vCPU、SDL + fb-shm
deploy/scripts/start-vm.sh 1 --iso=/home/ubuntu/images/win10_ltsc.iso

# AMD 宿主的显式功能兼容路径；不是 B350 真机化验收结果
deploy/scripts/start-vm.sh 2 \
  --allow-platform-compatibility \
  --iso=/home/ubuntu/images/win10.iso

# 后续从磁盘启动；优雅关机
deploy/scripts/start-vm.sh 1
deploy/scripts/stop-vm.sh 1
```

生产验收前先阅读 [操作参考](USAGE.md)，并在目标宿主执行评估文档中的 KVM capability、
客体快照和 24 小时 soak。E5-2696 v4/X99 只有主板/BIOS、TSC、CPU realize、客体枚举和
长稳全部通过后，才能从“条件支持”提升；CPU 名称或插槽相同不能替代实测。

`setup-host-helpers.sh` 是由编译入口调用的内部安全安装器，不是 VM 每次启动脚本；其
安装内容、QEMU path/inode/SHA-256 绑定、CI/非交互策略和手工诊断方式见
[操作参考的宿主准备章节](USAGE.md#31-编译脚本自动维护最小-root-helper)。

## 每实例资源

默认 `IMAGE_ROOT=/home/ubuntu/images`：

- `$IMAGE_ROOT/vms/<N>/disk.qcow2`：容量必须与组件模板一致的稀疏磁盘。
- `$IMAGE_ROOT/vms/<N>/profile`：0600 硬件身份文件。
- `$IMAGE_ROOT/vms/<N>/ovmf-vars.fd`：独立 UEFI NVRAM。
- `$IMAGE_ROOT/vms/<N>/tpm-state/` 或 `tpm12-state/`、`tpm-sock`：按 profile
  版本隔离的 TPM 状态和 socket；`platform-binding` 防止旧密钥被另一平台复用。
- `/tmp/qemu-stealth-<N>.qmp`：QMP；`--proxy` 时启用原生 multi-client。
- `/tmp/qemu-stealth-<N>.fb`：默认启用的 fb-shm 通道。

路径迁移见 [可移植性](PORTABILITY.md)，fb-shm 协议见 [FB-SHM](FB-SHM.md)。

## 文档入口

- [P-11 Hyper-V GPU-P 后端](HYPERV-GPU-P.md)：Windows Hyper-V 创建、双厂商动态选择、驱动同步、身份与 guest 验收。
- [硬件平台、E5/X99 与兼容性评估](HARDWARE_PLATFORM_ASSESSMENT_2026-07-13.md)：当前结论和验收矩阵。
- [Profile 字段](PROFILE-FIELDS.md)：schema、目录绑定、字段和 fidelity。
- [操作参考](USAGE.md)：Linux 构建、启动、网络、调优和验收命令。
- [开发与跨平台验证依赖](DEVELOPMENT-DEPENDENCIES.md)：Ubuntu 运行、构建、固件、
  完整回归和 Windows 工件的分组依赖与自检。
- [可移植性](PORTABILITY.md)：迁移 `IMAGE_ROOT`、QEMU 路径和宿主能力。
- [qcow2 读写性能](QCOW2-PERFORMANCE.md)：自动 AIO/元数据缓存、新盘布局与离线重排。
- [验证](VERIFY.md)：静态与客体侧核对入口。
- [fb-shm GPU 导出](FB-SHM-GPU-ZEROCOPY.md)：跨平台 handle、同步协议与回退边界。
- [Windows 打包与启动](WINDOWS-PACKAGING.md)：Windows/WHPX 路线。
- [Guest GPU 浅层工作流](STEALTH-WORKFLOW.md)：当前 `1AF4:1050`、
  `1AF4:a101`–`1AF4:a112`
  carrier、stock VioGpuDod 与
  系统厂商 API 的唯一受支持流程。
- [GPU 厂商 API 系统兼容层](GPU-VENDOR-API.md)：NVIDIA NVAPI、AMD ADL、统一身份
  读取合同、跨组件事务和能力边界。
- [GPU 身份方案边界](STEALTH-APPROACHES.md)：当前浅层实现、3D 能力边界与历史方案差异。
- [ACE 浅层边界](ACE-SHALLOW-STEALTH.md)：不使用自签名、EfiGuard 或内核伪装的约束。

旧审计和旧 GPU 深层流程只作为历史资料；其中的自签名、主 PCI ID 覆盖、随机池和
检测对抗结论不能覆盖上述当前浅层文档、当前 manifest 或启动器。
