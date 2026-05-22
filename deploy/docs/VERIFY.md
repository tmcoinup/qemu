# 验证矩阵 — DNF 检测面清单

本文档列出 DNF 反作弊（XignCode3）和常见中国市场 VM 检测器会做的探测，以及本部署包是如何封堵的。

## 指令 / CPU 级别

| 探测                          | 修改前          | 修改后                                       | 实现路径                                         |
|-------------------------------|-----------------|----------------------------------------------|--------------------------------------------------|
| `cpuid(1).ECX[31]`            | 1（HV 标志）    | 0                                            | `target/i386/kvm/kvm.c` 擦除段                  |
| `cpuid(0x40000000)`           | `KVMKVMKVM`     | 叶返回 0（表里不存在）                       | 同上                                             |
| `cpuid(0x40000100-ff)`        | Hyper-V         | 叶被丢弃                                     | 同上                                             |
| Vendor 字符串                 | 因主机而异      | `AuthenticAMD`                               | `-cpu ...vendor=AuthenticAMD`                    |
| family / model / stepping     | 主机透传        | 23 / 1 / 1                                   | `target/i386/cpu.c` 新增 Ryzen3-1200            |
| invariant TSC                 | 可能缺失        | 存在                                         | `FEAT_8000_0007_EDX |= CPUID_APM_INVTSC`        |
| AES / AVX2 / SHA-NI           | 主机决定        | 保证开启                                     | Ryzen3-1200 特性位                               |
| 拓扑（核 / 线程）             | 暴露 SMT        | 4 / 4（无 SMT）                              | `-smp cpus=4,threads=1`                          |

## SMBIOS / DMI（Win32_* 类）

| WMI 类                        | 显示值                                    |
|-------------------------------|-------------------------------------------|
| `Win32_BIOS.Manufacturer`     | `American Megatrends Inc.`                |
| `Win32_BIOS.SMBIOSBIOSVersion`| 从池 `6203..2401` 随机                    |
| `Win32_BIOS.ReleaseDate`      | 2020..2023 池随机                         |
| `Win32_BaseBoard.Manufacturer`| 随机 AM4 厂商                             |
| `Win32_BaseBoard.Product`     | 对应型号                                  |
| `Win32_BaseBoard.SerialNumber`| 每次启动随机，厂商风格                    |
| `Win32_SystemEnclosure.*`     | Desktop / Tower，带厂商序列号             |
| `Win32_Processor.Name`        | `AMD Ryzen 3 1200 Quad-Core Processor`    |
| `Win32_PhysicalMemory.*`      | Kingston / DDR4-3200 / 双通道              |

## ACPI

| 表           | OEM_ID   | OEM_Table_ID |
|--------------|----------|--------------|
| RSDT / XSDT  | ALASKA   | A M I        |
| FADT / FACP  | ALASKA   | A M I        |
| DSDT / SSDT  | ALASKA   | A M I        |
| APIC / MCFG  | ALASKA   | A M I        |

之前所有表都写 `BOCHS ` / `BXPC    `——一眼就能判为虚拟机；现在统一伪装成 ASUS / MSI / Gigabyte / ASRock 这类消费主板固件。

## 存储

NVMe 池（5 款）每条都带真实 advertised 字节数，profile 抽中后 qcow2 同步建对应大小，**Model ↔ Size 自洽**：

| Model                            | Firmware | RAW_BYTES         | Win 看到容量 |
|----------------------------------|----------|--------------------|--------------|
| Samsung SSD 970 PRO 512GB        | 1B2QEXM7 | 512,110,190,592   | ~476.9 GiB    |
| Samsung SSD 970 EVO Plus 500GB   | 2B2QEXM7 | 500,107,862,016   | ~465.7 GiB    |
| Samsung SSD 980 PRO 500GB        | 5B2QGXA7 | 500,107,862,016   | ~465.7 GiB    |
| Samsung SSD 980 1TB              | 3B4QFXO7 | 1,000,204,886,016 | ~931.5 GiB    |
| Samsung SSD 990 PRO 1TB          | 3B2QJXD7 | 1,000,204,886,016 | ~931.5 GiB    |

| 字段                  | 值                                   |
|-----------------------|--------------------------------------|
| PCI vendor/device     | 144D:A809（Samsung）                 |
| 子 vendor/device      | 144D:A801（970 PRO 级）              |
| Identify Ctrl `MN`    | profile 抽中型号                      |
| Identify Ctrl `FR`    | profile 抽中固件                      |
| IEEE OUI              | 00:25:38（Samsung）—— `use-samsung-id=on` |
| SUBNQN                | `nqn.1994-11.com.samsung:nvme:...`   |

## 显示器（EDID 池，patch 0009）

`MONITOR_POOL` 10 条 24" 1920×1080 显示器；profile 抽 1 条写 EDID。Guest 端
`Get-CimInstance Win32_DesktopMonitor` 会看到对应型号。

| EDID Vendor | Name         | 尺寸 (mm) | 备注          |
|-------------|--------------|-----------|---------------|
| SAM         | S24F350      | 530×300   | Samsung 三星  |
| SAM         | C24F390      | 530×300   | 三星曲面      |
| AOC         | 24G2E5       | 530×300   | AOC 冠捷      |
| AOC         | 22B1H        | 485×275   | AOC 21.5"     |
| BNQ         | GW2480       | 530×300   | BenQ 明基     |
| DEL         | SE2419HR     | 527×296   | Dell OEM 捆绑 |
| HKC         | SG24A1       | 530×300   | **HKC 国产**   |
| HKC         | M24A1F       | 530×300   | HKC 国产      |
| GSM         | 24MK430      | 527×296   | LG 乐金       |
| PHL         | 246E9QJ      | 530×300   | Philips 飞利浦|

实现：patch 0009 给 virtio-vga 加 `edid-vendor=` / `edid-name=` / `edid-serial=` / `edid-width-mm=` / `edid-height-mm=` cmdline 选项，start-vm.sh 从 profile.EDID_* 注入。

## 键盘 / 鼠标 / 数位板（USB HID 池，patch 0010）

每 VM 独立抽。Guest 端 `Get-CimInstance Win32_USBHub`、设备管理器、`lsusb` 都看到 profile 选定的品牌。

| 池          | 数量 | 包含品牌 |
|-------------|-----|----------|
| KBD_POOL    | 5   | Microsoft / Logitech / **A4Tech 双飞燕** / **Rapoo 雷柏** / Dell |
| MOUSE_POOL  | 5   | Microsoft / Logitech / A4Tech / Rapoo / Dell |
| TABLET_POOL | 4   | HUION 绘王 / HUION H640P / **VEIKK** / **XP-Pen 国产** |

实现：patch 0010 给 usb-kbd/mouse/tablet 加 `vendorid=` / `productid=` / `manufacturer=` / `product=` cmdline 选项；`serial=` 走 USBDevice 父级。start-vm.sh 从 profile.{KBD,MOUSE,TABLET}_* 注入。

## TPM 2.0

| 字段 | 值 |
|---|---|
| QEMU 设备 | `-device tpm-crb,tpmdev=tpm0` (CRB 现代主板风格，不是老 TIS) |
| 后端 | `-tpmdev emulator,id=tpm0,chardev=chrtpm` + swtpm 后台 daemon |
| State 目录 | `$VM_DIR/tpm-state/` (含 `tpm2-00.permall` 主存储) |
| Control sock | `$VM_DIR/tpm-sock` (unixio chardev) |
| 首启 init | `swtpm_setup --tpm2 --create-ek-cert --create-platform-cert --lock-nvram` |
| OVMF 要求 | **必须**含 Tcg2Dxe/Pei/ConfigDxe/PlatformDxe 模块。Ubuntu 默认 `ovmf` 包**没编** TPM2 模块；本部署用 `deploy/tools/build-ovmf.sh` 重 build (`-D TPM2_ENABLE=TRUE`)，产出 `deploy/firmware/OVMF_CODE_4M_stealth.fd` |
| Guest 端验证 | `Get-Tpm` 应返回 `TpmPresent=True, TpmReady=True` |
| 常见坑 | (1) `/var/lib/swtpm-localca/` 只 root 可写 → EK cert 创建失败，permall 只 ~1.3KB；start-vm.sh 现自动 chown 修复，完整 init 后 permall ≥ 3KB。(2) OVMF 不含 Tcg2 → Get-Tpm 全 False；用 build-ovmf.sh 重 build。 |

## ACPI BGRT / SSDT

裸金属固件常有 BGRT (boot logo) + 至少一个 ThermalZone。空缺会被反作弊视为 VM 信号。本部署：

| 表 | 文件 | 内容 |
|---|---|---|
| BGRT | `firmware/bgrt.bin` (20 字节) | status=migrated, address=0, OEMID `ALASKA / A M I` |
| SSDT 热区 | `firmware/ssdt-thermal.{asl,aml}` (153 字节) | `\_SB.TZQE` ThermalZone (_TMP=40°C, _CRT=105°C, _PSV=85°C) + `\_SB.FANE` PNP0C0B 风扇 |

注入：`-acpitable sig=BGRT,...,data=<bgrt.bin>` + `-acpitable file=<ssdt-thermal.aml>`。Guest 端 `Get-CimInstance Win32_TemperatureProbe` / `Win32_Fan` 应非空。

## 网卡

| 字段               | 值                                                     |
|--------------------|--------------------------------------------------------|
| 设备               | Intel 82574L（`e1000e`）——不用 virtio-net             |
| MAC OUI            | 从 Intel / Realtek / ASUS 池随机（`_gen_mac`）         |
| 是否避开 52:54:00  | 是——启动器里曾硬编码 QEMU/KVM OUI，本次修复           |
| PHY 链路           | 1 Gbit 自动协商（e1000e 默认）                         |

## 内存（拓扑动态：1 条 / 2 条）

| 字段                         | RAM ≤ 4096 MiB              | RAM > 4096 MiB                  |
|------------------------------|-----------------------------|----------------------------------|
| QEMU 后端                    | 1 × `memory-backend-memfd`  | 2 × `memory-backend-memfd`       |
| NUMA node                    | 1                           | 2                                |
| Win32_PhysicalMemoryArray.MemoryDevices | 2 (T16_NUM_DEVICES) | 2 (T16_NUM_DEVICES) |
| Win32_PhysicalMemory 数量    | **1 条** (T17 entries)       | **2 条** (T17 entries)            |
| 卡槽布局                     | 2 卡槽 / 占 1 空 1            | 2 卡槽 / 全占                     |
| 厂商池                       | Kingston / Crucial / Samsung / SK hynix（随机抽 1 厂商）            |
| 部件号                       | < 4096 MiB/DIMM → `MEM_PART_2G`，≥ 4096 MiB/DIMM → `MEM_PART_4G` |
| **SN 持久化** (2026-05 新)   | DIMM 0 一次性生成 8-char hex 写 profile（`MEM_SERIAL`），跨重启不变；老 profile 缺字段时按 UUID 派生 |
| **双通道两条唯一 SN** (2026-05 新) | 第 2 条按 `sha256(MEM_SERIAL-dimm2)[:8]` 派生；emit `serial=SN1\|SN2`，两条 DIMM 各自唯一（共用同 SN = 伪造特征，`Win32_PhysicalMemory` 必查） |
| 速率                         | 2666 MT/s（可通过 `MEM_SPEED=` 改） |
| Device locator (DIMM 0/1)     | `DIMM_A2` / `DIMM_B2` （`loc_pfx=DIMM_%C2` 的 `%C` 替换） |
| Bank locator (DIMM 0/1)       | `P0 CHANNEL A` / `P0 CHANNEL B` （`%C` 替换） |
| 内存量来源                   | `profile.MEM_TOTAL_MB`（`set-vm-memory.sh <N> 8G` 切换）；`--ram=` / `RAM=` 临时覆盖 |
| 实现                         | `start-vm.sh` 动态构造 `MEMORY_ARGS` 数组；`stealth_smbios_args` t17 emit `serial=SN1\|SN2` + `loc_pfx=DIMM_%C2`；`smbios.c` type17 支持 `\|` 分隔 per-DIMM serial |

## 网络链路

| 项                    | 值                                                                       |
|-----------------------|--------------------------------------------------------------------------|
| 默认后端              | user-mode NAT（SLIRP），`10.0.2.0/24` + SSH/RDP hostfwd                 |
| 推荐后端（stealth）   | 桥接 `BRIDGE=br0`，`deploy/scripts/setup-bridge.sh` 一次性配好            |
| 理由                  | `10.0.2.x` / `192.168.76.x` 这类 NAT 段是 VM 信号；桥接后客机是上游 LAN 里一条正常 DHCP 租约 |
| helper 权能           | `qemu-bridge-helper` 设 `cap_net_admin+ep`（比 suid root 更干净）         |
| ACL                   | `/etc/qemu/bridge.conf` 里必须有 `allow br0`                             |

## OEM 字符串（SMBIOS type 11）

真实的 ASUS / MSI AM4 主板会带 3–5 条厂商字符串（`ASUS_MB_RSVD`、`ASUS_MB_CPU=…`、`ASUS_MB_LINK_URL=…`）。**缺失** type 11 比内容错误更显眼——我们现在产出一组 ASUS 风格的最小集。

## 本包已封堵 / 残留 PCI/USB/ACPI 字符串

### 已封堵（2026-04-25 P0/P1 一轮）

| 面                                  | 修改前                          | 修改后                                       | 实现路径                                         |
|-------------------------------------|---------------------------------|----------------------------------------------|--------------------------------------------------|
| 显示器 EDID 厂商 / 产品名           | `RHT` / `QEMU Monitor`          | `SAM` / `Samsung S24F350F`（`SAM0F65`）      | `hw/display/edid-generate.c`（含 atoi 序列号 bug 修复，djb2 hash 兜底） |
| qemu-xhci PCI VEN:DEV               | `1B36:000D`（Red Hat）          | `1022:43BB`（AMD 300 系列 USB 3.1 xHCI）     | `hw/usb/hcd-xhci-pci.c`                          |
| pcie-root-port PCI VEN:DEV          | `1B36:000C`（Red Hat）          | `1022:1453`（AMD Family 17h Internal PCIe GPP）| `hw/pci-bridge/gen_pcie_root_port.c`             |
| USB HID 描述符 manufacturer 串      | `QEMU`                          | `Microsoft`                                  | `hw/usb/dev-hid.c` `desc_strings[STR_MANUFACTURER]` |
| USB HID 产品串（mouse/kbd/tablet）  | `QEMU USB Mouse/Tablet/Keyboard`| `Microsoft USB Optical Mouse` / `Microsoft Wired Keyboard 600` / `Microsoft USB Tablet` | 同上 + `usb_*_class_initfn` 的 `product_desc` |
| USB HID idVendor:idProduct          | `0627:0001`（Adomax）           | mouse `045E:00CB` / kbd `045E:0750` / tablet `056A:00FB` | `desc_mouse / desc_mouse2 / desc_tablet / desc_tablet2 / desc_keyboard / desc_keyboard2` |
| ACPI fw_cfg `_HID`                  | `QEMU0002`                      | `PNP0C02`（Motherboard Resources）           | `hw/i386/fw_cfg.c` 与 `hw/nvram/fw_cfg-acpi.c`   |
| e1000e subsystem 默认               | `8086:0000`（Intel + 0）        | `1043:86C0`（ASUS PRIME B350）               | `hw/net/e1000e.c` `e1000e_properties`            |
| SMBIOS Type16 `error_correction`    | `0x06` Multi-bit ECC            | `0x03` None（消费级 DDR4 一致）              | `hw/smbios/smbios.c`                             |
| SMBIOS Type16 `location`            | `0x01` Other                    | `0x03` System board                          | 同上                                              |
| virtio-gpu PCI VEN:DEV              | `1AF4:1050`（Red Hat）          | `10DE:1C81`（NVIDIA GTX 1050，仅 `GPU_SELFSIGNED=1`） | `x-pci-vendor-id`/`x-pci-device-id` 透传到 virtio-vga |

### 仍残留（需要更换 machine type 或更大改动）

| 面                             | 当前值                       | 目标值                              | 成本                                         |
|--------------------------------|------------------------------|-------------------------------------|----------------------------------------------|
| Q35 host bridge / LPC / SMBus / HDA controller | Intel `8086:29C0` / `2918` / `2930` / `2668` | AMD B350 chipset (e.g. `1022:43B7` / `1022:790E`) | 需新 machine type 或重写 `hw/i386/pc_q35.c`  |
| ACPI DSDT 方法名               | QEMU 默认                     | BIOS 厂商特定                        | 侵入 `hw/i386/acpi-build.c`，改动大          |
| viogpudo.sys 内部串            | `Red Hat VIOGPU WDDM DOD`     | `NVIDIA GeForce GTX 1050`           | 已用 patched `viogpudo.sys`（mm260 源码改 + backdated NVIDIA-fake CA 签）覆盖；详见 `feedback_vm2_gpu_recovery.md` |

### 客机端（装完系统后必做）

| 任务                                                          | 方法                                                                                     |
|---------------------------------------------------------------|------------------------------------------------------------------------------------------|
| GPU 改名为 GeForce GTX 1050（WMI / DxDiag / 任务管理器）      | 以管理员身份跑 `deploy/scripts/apply-gpu-spoof.ps1`                                       |
| 关闭 Memory Integrity（HVCI）                                 | Windows 安全中心 → 设备安全 → 内核隔离 → 关                                                |
| 关闭 Virtualization-Based Security                            | `bcdedit /set hypervisorlaunchtype off` + 重启                                            |
| 移除 Hyper-V 可选组件                                         | `Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All`              |
| 不要装 virtio-win guest tools                                 | 会引入 `qemu-ga.exe` 和 Red Hat 签名的驱动                                                 |
| 不要装 SPICE guest tools                                      | 同上类型的暴露                                                                             |

### 进阶（前面全做完 DNF 还是报 0x403 时再处理）

* **驱动二进制名**——`viogpudo.sys` 在属性里写着 "Red Hat VirtIO"。重命名得先关驱动签名强制，有风险
* **`NvAPI_Initialize()` / `nvml.dll`**——没有真 NVIDIA 运行时。如果 XignCode 把"查询失败"本身当信号，主机端伪造无法修
* **RDTSC 确定性**——已经设了 `+invtsc`；更深的时序探测仍可能看到虚拟化抖动

## 运行时验证命令

### Host 端开机前自检（13 段）

```bash
QEMU=/home/ubuntu/projects/qemu/build/qemu-system-x86_64 \
    deploy/scripts/verify-stealth.sh
```

13 段全过才能放行启动：

| # | 检查项 |
|---|--------|
| 1 | CPU 型号注册（Ryzen3-1200 alias） |
| 2 | QMP query-cpu-model-expansion: hypervisor/kvm=False, invtsc/topoext/svm/sha-ni 在 |
| 3 | ACPI OEM 字符串 `ALASKA` / `A M I` baked in |
| 4 | NVMe `use-samsung-id` / `model-number` / `firmware-rev` 支持 |
| 5 | TPM 2.0：swtpm 可用 + QEMU `-tpmdev emulator` 编进去 |
| 6 | BGRT 伪表 (`firmware/bgrt.bin`, 20 字节) |
| 7 | BOARD_POOL 每条 8 字段 (含 SUBSYS_VEN / SUBSYS_DEV) |
| 8 | CPU_POOL 全部无 iGPU |
| 9 | NVMe 池 Model ↔ Size 自洽（1TB model = 10^12 B，不再 512GB） |
| 10 | DIMM SN 持久化：pick → save → load → load 全部一致；8GB 双通道时两条 DIMM SN 不重复（DIMM_A2 ≠ DIMM_B2） |
| 11 | USB HID + EDID 自定义 prop (patch 0009/0010 编进 QEMU) |
| 12 | 外设池 (MONITOR/KBD/MOUSE/TABLET) 字段数自洽 |
| 13 | 伪 SSDT 热区表 (`firmware/ssdt-thermal.aml`) |

### Guest 端装完 Windows 后验证

```powershell
# 基础（旧检查）
(Get-WmiObject Win32_BIOS).Manufacturer -eq "American Megatrends Inc."     # True
[Regex]::Match((Get-WmiObject Win32_ComputerSystem|Out-String),"BOCHS|BXPC").Success  # False
(Get-WmiObject Win32_Processor).HypervisorPresent                           # False

# TPM 2.0
(Get-Tpm).TpmPresent                                                        # True
(Get-Tpm).TpmReady                                                          # True

# ACPI 热区 / 风扇（patch 0007 SSDT 注入）
Get-CimInstance Win32_TemperatureProbe | Measure-Object | % Count            # ≥ 1
Get-CimInstance Win32_Fan | Measure-Object | % Count                         # ≥ 1

# 显示器（patch 0009 EDID 注入）
Get-CimInstance Win32_DesktopMonitor | Select Name, MonitorManufacturer, MonitorType
# 应匹配 profile.EDID_VENDOR + EDID_NAME，不是 "QEMU Monitor"

# USB HID 品牌（patch 0010）
Get-PnpDevice -Class Keyboard | Select FriendlyName, InstanceId
Get-PnpDevice -Class Mouse    | Select FriendlyName, InstanceId
# FriendlyName 应该是 profile.KBD_PRODUCT / MOUSE_PRODUCT 不是 "QEMU USB *"

# 跨向量自洽（这两组对照不应矛盾）
(Get-CimInstance Win32_BaseBoard).Manufacturer                              # 比如 "ASRock"
(Get-PnpDevice -Class System | ? Status -eq OK | Select -First 5 InstanceId) | fl
# PCI VEN_1849:DEV_... 子系统应匹配 ASRock (0x1849)，不是 ASUS (0x1043)
```
