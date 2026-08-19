# 虚拟化检测面 (DNF TP / 常见反作弊) 全量清单

最后更新 2026-08-03。按检测层从低到高排列。本文只描述 G-11/vGPU；V-11 是
独立分支，不能把它的 GPU、显示驱动或检测结论直接套用。GPU 身份必须区分新配置
的安全 B、历史 A 实验，以及始终不变的 host backing hardware。

## Layer 0 — CPU / CPUID

| 检测点 | 物理机 | QEMU 默认 | 本项目方案 |
|-------|--------|-----------|-----------|
| `CPUID.1.ECX[31]` HYPERVISOR bit | 0 | **1** ⚠️ | `-cpu ...,x-hv-stealth=on` (见 `target/i386/cpu.c:8317`) |
| `CPUID.40000000-400000FF` KVM/HV leaves | 无 (InvalidLeaf) | KVM signature ⚠️ | `-cpu ...,kvm=off` |
| `CPUID.1.ECX[5]` VMX / `CPUID.80000001.ECX[2]` SVM | 可能 1 | 0 | 我们显式 `,vmx=off` 固化 |
| Brand string (80000002-4) | 真实型号 | QEMU 默认带 "Virtual CPU" | 8 个目录模型各自写入对应 brand；active 6、legacy 2 |
| Family / Model / Stepping | 真实 | qemu64 族：15/6/1 | G3220、i3-4130、i5-4460/4570/4590、i7-4790 及 legacy i5-6500/i3-8100 显式模型 |
| TSC invariant (`80000007.EDX[8]`) | 1 | 0 (qemu64) | `,+invtsc` 固定打开 |
| RDTSC 一致性 (rdtsc 在不同核差异 < 几千周期) | 一致 | KVM-clock 校准差 → 可能漂移 | `kvm=off` 关 KVMclock；`-rtc clock=host,driftfix=slew` 矫正 |

### 残留风险

- **MSR 列表**。TP 不怎么读 MSR，但硬核反作弊会读 IA32_PERF_STATUS / IA32_MPERF。KVM 模拟粒度够，通常过检。
- **时间精度**。`rdtsc` + `rdpmc` 做 timing attack 可能显出 vm-exit 尖峰。无成本修法仅限于「用物理 cpu pin + 关 hpet」，延迟建模超出本工程范围。

## Layer 1 — SMBIOS / DMI

| 字段 | 物理机 | QEMU 默认 | 本项目 |
|-----|--------|-----------|--------|
| Type 0 vendor | AMI / Phoenix / Insyde | "SeaBIOS" ⚠️ | `-smbios type=0,vendor="American Megatrends Inc."` |
| Type 1 manufacturer/product | ASUS / MSI / Gigabyte 等 | "QEMU"/"Standard PC" ⚠️ | `create-vm.sh` 随机池，写入 `vms/N/vm.conf` 后每次启动一致 |
| Type 1 UUID | 厂固化 | 启动新 uuid | 配置里固化 `VM_UUID` |
| Type 2 serial | 主板 SN | 空 | 从 `vms/N/vm.conf` 的 `MB_SN` 填 |
| Type 17 memory_type | 0x18 / 0x1A / 0x22 (DDR3/4/5) | **0x07 (RAM)** ⚠️ | profile 按 DDR3=`0x18`、DDR4=`0x1A` 传入 |
| Type 17 type_detail | 0x80 (Synchronous) | **0x02 (Other)** ⚠️ | `typedetail=0x80` (本仓库 patch) |
| Type 17 data_width/total_width | 64 / 64 (no ECC) | **0xFFFF / 0xFFFF** ⚠️ | `width=64,totalwidth=64` (本仓库 patch) |
| Type 17 manufacturer/part/serial | DIMM 实际品牌/逐槽料号/不同序列 | 空 | 18 套目录；active 为 Kingston、Samsung、Micron、SK hynix、Crucial 五品牌；v3 持久化完整 `MEM_SERIAL_LIST` 并逐槽跨 VM 查重 |
| DDR3 SPD 几何/身份 | 容量、Rank、颗粒宽度、JEP106、serial、part 自洽 | 通常无本项目身份 | 四种审核几何；bytes 117/122/128/148 起分别写 module JEP106/serial/18-byte part/DRAM JEP106 |
| legacy DDR4 SPD | EE1004 page 1 常含身份 | 仅 page 0 | 本项目明确保持 256-byte page 0-only；身份由 SMBIOS Type 17 提供，不伪造 page 1 |
| Type 3 chassis | 机箱 SN | 空 | `CHASSIS_SN` |

硬件合同 v3 的 `SYS_SN`、`MB_SN`、`CHASSIS_SN` 遵守 ASUS/MSI/Gigabyte 各自
格式且互不重复；DIMM 基准序列是非保留 8 位十六进制，第二槽稳定派生另一值，
完整 `MEM_SERIAL_LIST` 与 `MEM_SN + slot` 必须一致，且每个成员进入同一
`MEMORY_SERIAL` 跨 VM 命名空间。SMBIOS 与 DDR3 SPD 使用同一对序列。Micron E1 目录 SKU 超过 JEDEC 18-byte part
字段，所以两种 Micron profile 均使用可核验的 `...-1G6` 基础 part，而不是半截
`...-1G6E`。这些值创建后固定，启动不会重新随机。

验证命令 (guest):

```cmd
wmic memorychip get banklabel,capacity,devicelocator,manufacturer,partnumber,speed,typedetail
wmic csproduct get name,uuid,vendor
wmic baseboard get manufacturer,product,serialnumber
wmic bios get manufacturer,releasedate,smbiosbiosversion,version
```

## Layer 2 — ACPI / DSDT

| 字段 | 检测效果 |
|-----|---------|
| DSDT OEM ID / OEM Table ID | Windows 只暴露给驱动，用户态 WMI 不看；TP 无此检查 |
| `_SB.PCI0._HID` | `PNP0A08` (PCIe Root) 物理机 & QEMU 都一样 |
| FADT Hypervisor Present flag (bit 20) | Windows 会看这个 flag 决定 IsVM；`-machine ...,x-oem-id=...` 改 OEM，但 flag 没改 |

QEMU 默认 FADT/FACP 里 Hypervisor Present Flag = 0 (除非 `+hypervisor`)，所以这里一般不是 TP 的命中点。

## Layer 3 — PCI 配置空间

| 检测面 | GTX 1050 目标 | 当前原生/off/B | legacy GTX1050 A（禁用） |
|-----|--------|-----------|--------|
| GPU VID:DID | `10DE:1C81` | `10DE:1E30` | QEMU 外部 PCI 为 `10DE:1C81` |
| GPU subsystem | Dell `1028:11C0` | NVIDIA `10DE:1326` | subvendor `1028`、subdevice `11C0`；Windows 为 `SUBSYS_11C01028` |
| NVIDIA internal tuple | 与消费 device 一致 | 继承 mdev profile | per-mdev `pci_id=0x1C8111C0`、`pci_device_id=0x1C81` |
| Driver binding | 对应 `DEV_1C81` | 原版正式签名 GRID 538.33 绑定 `DEV_1E30` | 修改 INF/自签 538.33，不合规 |
| Host resource | 与 PCI 身份对应的物理资源 | `nvidia-257 / 2048 MB` | 仍是同一 `nvidia-257 / 2048 MB` backing |

严格路径同时要求外部 VID/DID/subsystem、NVIDIA internal vdev/pdev、匹配的
Windows Driver Store 包与同一个生成配置一致；B/off 则故意保留 `DEV_1E30`。

### GTX 1050 当前停留点

新 `gtx1050_2gb` 配置先持久写入：

```text
SPOOF_MODE=B
VGPU_IDENTITY_TARGET=name-only
```

这时 marketing name 可以来自 per-mdev 配置，但 PCI 仍是 `DEV_1E30`。这就是当前
安全停留点。历史 finish 会修改 INF/自签 catalog，已在产生包和 marker 前拒绝；
不要运行旧 ZIP或手工写 A/internal/FRL。当前 25 条 GPU 原子 profile 的受支持策略始终保持 B；
真实 VM3 的 legacy A 通过 production migration 回到原始 GRID 538.33/native
身份，设备管理器与 GPU-Z 的型号由 name/profile overlay 提供。

### 检测边界仍然存在

legacy 严格 A 实验曾让 PnP、GPU-Z Device ID 和普通 PCI 身份查询得到精确的
`10DE:1C81 / 1028:11C0`，但不会把 backing hardware 变成真实 GP107。CUDA 核心数、
频率、总线宽度、调度份额和部分 GPU-Z 底层字段仍可能暴露真实 vGPU/物理路径。
host `nvidia-smi vgpu` 的 `vGPU Name` 也可能继续显示 GT 1030/type 标签；它是资源层
信息，不等于 guest identity 失败。

授权页同样不是身份或 license 的单一判据。legacy 严格 GTX1050 的历史记录是控制
面板授权页消失、host `Unlicensed`、per-mdev `FRL N/A`；它不等于激活，也不是当前
生产合同。当前 25 条 GPU 原子 profile 都按 B/off 原生 vGPU 合同验收 DLS/token 和
`Licensed`。

Guest 验证：

```powershell
$gpu = Get-CimInstance Win32_VideoController |
  Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' } |
  Select-Object -First 1
$gpu | Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,AdapterRAM
```

Host 验证：

```bash
nvidia-smi vgpu -q
journalctl -b -u nvidia-vgpu-mgr -u nvidia-vgpud --no-pager | \
  rg 'Virtual Device Id|Patching|frl_enabled|1c81'
```

最终 GPU/分辨率验收必须断开 RDP 后在 native SDL/GTK 进行；RDP Remote Display
Adapter、动态分辨率和编码帧率不是 NVIDIA PCI/FRL 证据。

下列非 GPU PCI 设备维持原有策略：

| 设备 | 物理机 | QEMU 默认 | 本项目 |
|-----|--------|-----------|--------|
| NIC 设备 | Intel I217-LM / Realtek | e1000 / virtio-net ⚠️ | `e1000e` (仿 Intel) + 真 Intel OUI MAC |
| AHCI / NVMe ID | Samsung / WDC / Kingston... | 0x8086:0x2922 (AHCI) | `-device nvme,serial=...,model=...`；本项目直接 NVMe + 真实 serial/model |
| RTC/IDE/PIT 类设备存在 | 物理机也存在 | 一样 | 不改动 |

## Layer 4 — 时钟 / 延迟 / 指令特征

- **RDTSC 纯度**: `kvm=off, +invtsc, tsc-freq=<真实频率>` 让 guest 的 TSC 行为与物理机一致。
- **HPET**: 物理机一般有 HPET。**但 Windows 10 下关闭 HPET 反而更好**（无 jitter），
  本项目启动脚本用 `-no-hpet`。
- **PIT lost tick**: 用 `-global kvm-pit.lost_tick_policy=discard` 避免 guest 时钟变慢。

## Layer 5 — 其它 OS 级信号

- **Windows 系统「系统类型」 → 物理**: 需要 SMBIOS 修好 + HypervisorPresent=0。
- **MSR 0xC0000082/3 (SYSCALL)**: KVM 已正常模拟，和物理机一致。
- **Local APIC timer 源**: 物理机是 HPET/LAPIC；我们 `-no-hpet`，留 LAPIC 一致。
- **Device Manager 中"Hyper-V Enlightenments"**: QEMU 不开 hv_* enlightenment 则不会出现。

## 验证跑批

启动后在 guest PowerShell:

```powershell
# HYPERVISOR bit
Get-CimInstance Win32_Processor | Select-Object Name, Family, Model, Stepping
Get-CimInstance Win32_ComputerSystem | Select-Object HypervisorPresent, Manufacturer, Model

# AIDA64 / CPU-Z 里肉眼确认:
#   - Brand string/核心数/缓存与 vm.conf 的 CPU_PROFILE 一致
#   - Mainboard 是白名单中的 H81（legacy VM 才可能是 H97/B150/B360）
#   - SMBIOS Type 17 与 SPD 的逐槽容量、Rank、料号、品牌和序列一致
#   - active 内存可能是 Kingston、Samsung、Micron 或 SK hynix，不应强求 KVR

# 对 DNF TP 的最终测试方式:
#   - 先装游戏
#   - 启动 dnf.exe, 观察是否正常进登录界面
#   - 登录后能进角色选择 = TP 过检
```

安全底线不因“检测优化”而放宽：不修改 BCD，不开启 `testsigning` 或
`nointegritychecks`，不安装测试签名/自签名内核驱动，也不把 V-11 的驱动方案复制
到 G-11。目录与 SPD/SMBIOS 一致性只能减少矛盾，不能把 QEMU q35、mdev backing
或 timing 行为宣称成完整物理机等价物。
