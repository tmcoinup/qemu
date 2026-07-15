# VMate 部署文档

> 当前维护基线：QEMU `11.0.2`，分支 `vmate`，硬件目录修订日期
> `2026-07-13`。`vmate` 是仓库分支名；QEMU 可执行文件、QMP/QGA 协议和设备模型名称
> 继续沿用上游名称。

VMate 当前应定位为：**Linux/KVM 优先、Windows/WHPX 受限支持、非 GPU 硬件身份高度一致，
但底层仍是 Q35/ICH9/QEMU 设备行为的条件可用方案**。它通过有限、可审计的整机和组件目录
避免随机出不存在或互相矛盾的组合，不承诺把虚拟机变成不可识别的物理机。

完整完成度、E5-2696 v4/X99、其它 E5、Windows/Linux 兼容性及优化结论见
[硬件平台评估](HARDWARE_PLATFORM_ASSESSMENT_2026-07-13.md)。

## 当前范围

| 范围 | 当前状态 |
|---|---|
| Linux 宿主 | KVM 主路径；默认 `STRICT_HARDWARE=1`，能力或身份不匹配即停止 |
| Windows 宿主 | WHPX 受限路径；详情见 [Windows 打包与启动](WINDOWS-PACKAGING.md) |
| Windows 10 客体 | Linux/KVM 主验收对象 |
| Windows 11 客体 | 有 TPM 2.0 路径，但 Secure Boot operational state 尚未闭环，不宣称正式支持 |
| Linux 客体 | QEMU 设备功能兼容；启动器的命名、RTC 和安装流程仍偏向 Windows |
| GPU | GPU passthrough、SR-IOV GPU、vGPU 均不在本分支范围；virtio 显示标签不计入真机化 |

## 唯一事实源

- [`deploy/hardware/platforms.json`](../hardware/platforms.json)：整机平台 schema、CPU、主板、
  BIOS、芯片组 PCI 身份、内存限制、网卡、音频和链路能力；顶层 `fidelity` 同时记录
  Q35 machine 行为边界和两个启动器实际生成的 BDF。
- [`deploy/hardware/components.json`](../hardware/components.json)：NVMe、显示器 EDID、键盘、
  鼠标和通用绝对指针模板。
- 每台 VM 的 `vms/<N>/profile`：从上述目录选出整套事实后，持久化平台 ID、目录修订号、
  UUID、MAC 和序列号；字段见 [Profile 字段](PROFILE-FIELDS.md)。

旧的独立 CPU/主板/BIOS 随机池和“十款 NVMe/显示器/HID 任意组合”不再是当前实现。
型号数量少是有意设计：一个行为和深层字段能对齐的完整模板，比多个只替换字符串的模板可信。

## 当前启用整机

新 profile 只从 `enabled=true` 且 `status=supported` 的整机 bundle 中选择。这里的
`supported` 严格表示“通过运行时宿主门禁后可成为启动器候选”，不表示 Q35 machine、
PCI BDF、寄存器或 PCH 行为与目标 H110/H310 等价：

| Platform ID | CPU | 主板 / PCH | 内存 | 状态 |
|---|---|---|---|---|
| `intel-lga1151-i3-9100f-asus-prime-h310m-a-r2` | i3-9100F，4C/4T | ASUS PRIME H310M-A R2.0 / H310 | DDR4，2/4/8 GiB | 启用候选；Q35 identity compatibility |
| `intel-lga1151-i5-6400t-asus-h110m-a-m2` | i5-6400T，4C/4T | ASUS H110M-A/M.2 / H110 | DDR4，2/4/8 GiB | 启用候选；Q35 identity compatibility |

两个 Ryzen 3 + PRIME B350-PLUS 条目仅保留为 `compatibility`，默认禁用。当前 machine type
仍是 Intel Q35/ICH9；只改成 AMD PCI ID 不能得到 B350 行为，因此 AMD 宿主在严格模式下
默认没有可用新建候选，也不会静默回退到伪 AMD 整机。需要先安装/功能验证时，可显式
使用 `--allow-platform-compatibility`。启动器按宿主 CPU vendor、`CPUS`、最大频率和
TSC 约束自动匹配：始终优先选择 `supported`，只在没有可用 `supported` 候选时回退到
`compatibility`。已有 profile 继续复用持久化的 `PLATFORM_ID`；`--platform-id` 仅作高级固定或
一致性断言。该窄入口不会把 `STRICT_HARDWARE` 改成 `0`，仍继续执行 KVM/TSC、
CPU realize、profile、磁盘，以及请求 `TPM=1` 时的 TPM 严格门禁，只接受整机
machine fidelity 不完整。
若没有 `supported` 匹配，但宿主确实能匹配某个 `compatibility` 模板，启动器会明确
提示追加 `--allow-platform-compatibility`；若该 allow 也无法找到候选，则不会误导性地给出此提示。

## 当前启用组件

| 类别 | 唯一启用模板 | 关键约束 |
|---|---|---|
| NVMe | Samsung SSD 970 PRO 512GB | `144d:a804`、subsystem `144d:a801`、`1B2QEXP7`、512110190592 B、Gen3 x4 |
| 显示器 | Samsung S24F350 | `SAM/0F65`、530×300 mm、制造周/年、频率范围和第二时序成套绑定 |
| 键盘 | Microsoft Wired Keyboard 600 | `045e:0750`、`bcdDevice=0163`、固定描述符、不暴露序列号 |
| 鼠标 | Microsoft USB Optical Mouse | `045e:00cb`、`bcdDevice=0163`、固定描述符、不暴露序列号 |
| 绝对指针 | QEMU USB Tablet | `0627:0001`，明确为通用虚拟设备，不冒充品牌数位板 |

组件型号本身不再随机；每台 VM 仍会生成并持久化 UUID、MAC、主板/系统/机箱/CPU/DIMM、
NVMe 和 EDID 序列号。键鼠模板声明不暴露 USB serial，profile 内的稳定派生值不会送进描述符。

## 严格启动链

Linux 启动器默认按以下顺序 fail closed：

1. 检查 patched QEMU、KVM 和 TSC 能力。
2. 按宿主 CPU 厂商、完整 4 线程 SKU、宿主最大频率和 TSC 约束选择整机 bundle。
3. 用实际 QEMU/KVM 和 `enforce=on` 创建最小 vCPU，拒绝 warning、unsupported 或失败。
4. 校验 profile 的 platform/component schema、目录修订号及每个绑定字段。
5. 校验 qcow2 的 guest 可见虚拟容量等于 `NVME_SIZE_BYTES`。
6. 默认 `TPM=1`；严格模式下 swtpm、状态初始化或 socket 失败都会停止。
7. 组装单 guest NUMA node；DIMM 数和双通道只通过 SMBIOS/SPD 表达。

`STRICT_HARDWARE=0` 仅用于开发和兼容诊断，不代表真机化验收结果。旧 profile 即使在
非严格模式也必须显式追加 `--allow-legacy-profile`，避免删除 manifest 元数据后静默
绕过平台授权。旧 profile 在严格模式下
必须显式 reroll；这会改变硬件身份并可能触发 Windows 重新激活。

## 真机化边界

| 硬件面 | 可见身份 | 行为边界 |
|---|---|---|
| CPU/SMBIOS/内存 | 平台字段、拓扑、Type 0/1/2/3/4/16/17；DIMM 额定/配置速率分离，256B SPD 的密度几何与 tRFC 可成套校验 | cache、MSR、微码、性能和时序仍受宿主及 KVM 限制；SPD 不是完整 EE1004/品牌 raw dump |
| 芯片组/PCIe/xHCI | vendor/device/revision/subsystem 与链路可注入 | 实现仍是 Q35/ICH9/QEMU 控制器；Linux 为 root port `00:01.0`–`00:04.0`、HDA `00:05.0`，Windows 少一个空端口、HDA 为 `00:04.0`，均不承诺 H110/H310 BDF/silicon 等价 |
| NVMe | Identify、容量、PCI/subsystem、SubNQN 可绑定 | SMART、热管理、功耗和错误恢复仍是通用 QEMU NVMe |
| 音频 | HDA controller 和 ALC887 codec 身份 | `protocol_identity_only`，widget、插孔和板级布线不等价 |
| EDID/HID | 当前单一模板深层字段一致 | 只对现有固定模板负责，新增品牌必须同时实现描述符/行为 |
| 显示/GPU | virtio-vga(-gl)、SDL/EGL、fb-shm 可用 | `label_only_out_of_scope`，不是 NVIDIA/AMD 物理 GPU |

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
- `$IMAGE_ROOT/vms/<N>/tpm-state/`、`tpm-sock`：独立 TPM 2.0 状态和 socket。
- `/tmp/qemu-stealth-<N>.qmp`：QMP；`--proxy` 时启用原生 multi-client。
- `/tmp/qemu-stealth-<N>.fb`：默认启用的 fb-shm 通道。

路径迁移见 [可移植性](PORTABILITY.md)，fb-shm 协议见 [FB-SHM](FB-SHM.md)。

## 文档入口

- [硬件平台、E5/X99 与兼容性评估](HARDWARE_PLATFORM_ASSESSMENT_2026-07-13.md)：当前结论和验收矩阵。
- [Profile 字段](PROFILE-FIELDS.md)：schema、目录绑定、字段和 fidelity。
- [操作参考](USAGE.md)：Linux 构建、启动、网络、调优和验收命令。
- [可移植性](PORTABILITY.md)：迁移 `IMAGE_ROOT`、QEMU 路径和宿主能力。
- [验证](VERIFY.md)：静态与客体侧核对入口。
- [fb-shm GPU 导出](FB-SHM-GPU-ZEROCOPY.md)：跨平台 handle、同步协议与回退边界。
- [Windows 打包与启动](WINDOWS-PACKAGING.md)：Windows/WHPX 路线。
- [Guest GPU 浅层工作流](STEALTH-WORKFLOW.md)：当前 `1AF4:1050`、stock VioGpuDod 与
  双架构系统 NVAPI 的唯一受支持流程。
- [GPU 身份方案边界](STEALTH-APPROACHES.md)：当前浅层实现、3D 能力边界与历史方案差异。
- [ACE 浅层边界](ACE-SHALLOW-STEALTH.md)：不使用自签名、EfiGuard 或内核伪装的约束。

旧审计和旧 GPU 深层流程只作为历史资料；其中的自签名、主 PCI ID 覆盖、随机池和
检测对抗结论不能覆盖上述当前浅层文档、当前 manifest 或启动器。
