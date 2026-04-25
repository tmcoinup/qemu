# 虚拟化检测面 (DNF TP / 常见反作弊) 全量清单

最后更新 2026-04-23。按检测层从低到高排列，每项都给出「物理机会看到什么 / VM 默认会看到什么 / 本项目如何堵」。

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
| Type 1 manufacturer/product | ASUS / MSI / Gigabyte 等 | "QEMU"/"Standard PC" ⚠️ | `create-vm.sh` 随机池，写入 `vmN.conf` 后每次启动一致 |
| Type 1 UUID | 厂固化 | 启动新 uuid | 配置里固化 `VM_UUID` |
| Type 2 serial | 主板 SN | 空 | 从 `vmN.conf` 的 `MB_SN` 填 |
| Type 17 memory_type | 0x18 / 0x1A / 0x22 (DDR3/4/5) | **0x07 (RAM)** ⚠️ | `memtype=0x1A` (CLI) + 新 QEMU opts (本仓库 patch) |
| Type 17 type_detail | 0x80 (Synchronous) | **0x02 (Other)** ⚠️ | `typedetail=0x80` (本仓库 patch) |
| Type 17 data_width/total_width | 64 / 64 (no ECC) | **0xFFFF / 0xFFFF** ⚠️ | `width=64,totalwidth=64` (本仓库 patch) |
| Type 17 manufacturer/part/serial | Kingston / KVR... | 空 | `vmN.conf` 随机池 |
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

| 设备 | 物理机 | QEMU 默认 | 本项目 |
|-----|--------|-----------|--------|
| GPU VID/DID | NVIDIA 10DE:1C81 (1050) | 10DE:RTX2080原值 | vgpu_unlock-rs `vdev_id` + QEMU `x-pci-vendor-id` 双改 |
| GPU 子系统 VID/DID | 厂商 OEM ID | 覆盖原值 | `x-pci-sub-vendor-id` + `x-pci-sub-device-id` |
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
