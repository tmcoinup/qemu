# 虚拟化检测面 (DNF TP / 常见反作弊) 全量清单

最后更新 2026-07-15。按检测层从低到高排列。GPU 身份必须区分新配置的安全 B、
V3 收尾后的已审计 GTX 1050 A，以及始终不变的 host backing hardware。

## Layer 0 — CPU / CPUID

| 检测点 | 物理机 | QEMU 默认 | 本项目方案 |
|-------|--------|-----------|-----------|
| `CPUID.1.ECX[31]` HYPERVISOR bit | 0 | **1** ⚠️ | `-cpu ...,x-hv-stealth=on` (见 `target/i386/cpu.c:8317`) |
| `CPUID.40000000-400000FF` KVM/HV leaves | 无 (InvalidLeaf) | KVM signature ⚠️ | `-cpu ...,kvm=off` |
| `CPUID.1.ECX[5]` VMX / `CPUID.80000001.ECX[2]` SVM | 可能 1 | 0 | 我们显式 `,vmx=off` 固化 |
| Brand string (80000002-4) | 真实型号 | QEMU 默认带 "Virtual CPU" | 本项目三个模型 model_id 写了真实 brand |
| Family / Model / Stepping | 真实 | qemu64 族：15/6/1 | 新增 Core-i5-4590 / Core-i5-6500 / Core-i3-8100 模型 |
| TSC invariant (`80000007.EDX[8]`) | 1 | 0 (qemu64) | `,+invtsc` 固定打开 |
| RDTSC 一致性 (rdtsc 在不同核差异 < 几千周期) | 一致 | KVM-clock 校准差 → 可能漂移 | `kvm=off` 关 KVMclock；`-rtc clock=host,driftfix=slew` 矫正 |

### 残留风险

- **MSR 列表**。TP 不怎么读 MSR，但硬核反作弊会读 IA32_PERF_STATUS / IA32_MPERF。KVM 模拟粒度够，通常过检。
- **时间精度**。`rdtsc` + `rdpmc` 做 timing attack 可能显出 vm-exit 尖峰。无成本修法仅限于「用物理 cpu pin + 关 hpet」，延迟建模超出本工程范围。

## Layer 1 — SMBIOS / DMI

| 字段 | 物理机 | QEMU 默认 | 本项目 |
|-----|--------|-----------|--------|
| Type 0 vendor | AMI / Phoenix / Insyde | "SeaBIOS" ⚠️ | `-smbios type=0,vendor="American Megatrends Inc."` |
| Type 1 manufacturer/product | ASUS / MSI / Gigabyte 等 | "QEMU"/"Standard PC" ⚠️ | `create-vm.sh` 随机池，写入 `instances/vmN/vm.conf` 后每次启动一致 |
| Type 1 UUID | 厂固化 | 启动新 uuid | 配置里固化 `VM_UUID` |
| Type 2 serial | 主板 SN | 空 | 从 `instances/vmN/vm.conf` 的 `MB_SN` 填 |
| Type 17 memory_type | 0x18 / 0x1A / 0x22 (DDR3/4/5) | **0x07 (RAM)** ⚠️ | `memtype=0x1A` (CLI) + 新 QEMU opts (本仓库 patch) |
| Type 17 type_detail | 0x80 (Synchronous) | **0x02 (Other)** ⚠️ | `typedetail=0x80` (本仓库 patch) |
| Type 17 data_width/total_width | 64 / 64 (no ECC) | **0xFFFF / 0xFFFF** ⚠️ | `width=64,totalwidth=64` (本仓库 patch) |
| Type 17 manufacturer/part/serial | Kingston / KVR... | 空 | `instances/vmN/vm.conf` 随机池 |
| Type 3 chassis | 机箱 SN | 空 | `CHASSIS_SN` |

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

| 检测面 | GTX 1050 目标 | 原生/off/B | 已审计 GTX1050 A |
|-----|--------|-----------|--------|
| GPU VID:DID | `10DE:1C81` | `10DE:1E30` | QEMU 外部 PCI 为 `10DE:1C81` |
| GPU subsystem | Dell `1028:11C0` | NVIDIA `10DE:1326` | subvendor `1028`、subdevice `11C0`；Windows 为 `SUBSYS_11C01028` |
| NVIDIA internal tuple | 与消费 device 一致 | 继承 mdev profile | per-mdev `pci_id=0x1C8111C0`、`pci_device_id=0x1C81` |
| Driver binding | 对应 `DEV_1C81` | 原版 GRID 538.33 绑定 `DEV_1E30` | audited patched 538.33、`31.0.15.3833`、Code 0 |
| Host resource | 与 PCI 身份对应的物理资源 | `nvidia-257 / 2048 MB` | 仍是同一 `nvidia-257 / 2048 MB` backing |

严格路径同时要求外部 VID/DID/subsystem、NVIDIA internal vdev/pdev、匹配的
Windows Driver Store 包与同一个生成配置一致；B/off 则故意保留 `DEV_1E30`。

### GTX 1050 的安全推进顺序

新 `gtx1050_2gb` 配置先持久写入：

```text
SPOOF_MODE=B
VGPU_IDENTITY_TARGET=full-consumer
VGPU_PATCHED_DRIVER_REQUIRED_VERSION=31.0.15.3833
```

这时 marketing name 可以来自 per-mdev 配置，但 PCI 仍是 `DEV_1E30`。基础 GRID
driver 安装完并完整关机后，运行：

```bash
./deploy/finish-vgpu-install.sh <vm_id>
```

将生成的 `VgpuGuestFinish-GTX1050.zip` 全部解压并运行其中 EXE。guest add-only
预暂存 locked 538.33 并写 V3 receipt；宿主离线校验 UUID、GPU、token、driver、动态
`oemN.inf` 和 patched INF hash 后才持久化：

```text
VGPU_IDENTITY_TARGET=full-consumer
SPOOF_MODE=A
VGPU_MDEV_INTERNAL_PCI_IDENTITY=1
VGPU_MDEV_FRL_ENABLED=0
VGPU_PATCHED_DRIVER_VERSION=31.0.15.3833
```

未完成 V3 时，启动器拒绝用 `--spoof` 绕过 gate。GTX 750 Ti 与 GT 1030 的
`VGPU_IDENTITY_TARGET=name-only`，始终保持 B；当前不能把它们写成完整消费 PCI
身份已经实现。

### 检测边界仍然存在

严格 A 让 PnP、GPU-Z Device ID 和普通 PCI 身份查询得到精确的
`10DE:1C81 / 1028:11C0`，但不会把 backing hardware 变成真实 GP107。CUDA 核心数、
频率、总线宽度、调度份额和部分 GPU-Z 底层字段仍可能暴露真实 vGPU/物理路径。
host `nvidia-smi vgpu` 的 `vGPU Name` 也可能继续显示 GT 1030/type 标签；它是资源层
信息，不等于 guest identity 失败。

授权页同样不是身份或 license 的单一判据。严格 GTX1050 下控制面板授权页会消失，
host 当前仍如实显示 `License Status: Unlicensed`；per-mdev `frl_enabled=0` 则单独
表现为 `Frame Rate Limit: N/A`。授权页消失不等于激活，`N/A` 也不等于 Licensed。
B/off 仍按原生 vGPU 合同验收 DLS/token 和 `Licensed`。

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
#   - Brand string 显示 i5-6500
#   - CPUID: family 6 model 94 step 3
#   - Mainboard: Gigabyte B85M-...（或随机到的那一套）
#   - SPD: Kingston KVR16N11S8/8 1600 MT/s

# 对 DNF TP 的最终测试方式:
#   - 先装游戏
#   - 启动 dnf.exe, 观察是否正常进登录界面
#   - 登录后能进角色选择 = TP 过检
```
