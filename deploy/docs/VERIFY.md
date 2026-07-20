# 验证矩阵 — DNF 检测面清单

本文档列出 DNF 仿真机（XignCode3）和常见中国市场 VM 检测器会做的探测，以及本部署包是如何封堵的。

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

当前严格组件目录只启用一个 NVMe 模板。profile 固化组件 ID 后，qcow2 必须使用
同一条目的精确 advertised 字节数，保证 **Model ↔ Firmware ↔ Size** 自洽：

| Model | Firmware | RAW_BYTES | Windows 可见容量 |
|---|---|---:|---:|
| Samsung SSD 970 PRO 512GB | 1B2QEXP7 | 512,110,190,592 | ~476.9 GiB |

| 字段                  | 值                                   |
|-----------------------|--------------------------------------|
| PCI vendor/device     | 144D:A804（Samsung 970 PRO 参考寄存器） |
| 子 vendor/device      | 144D:A801（970 PRO 级）              |
| Identify Ctrl `MN`    | profile 抽中型号                      |
| Identify Ctrl `FR`    | profile 抽中固件                      |
| IEEE OUI              | 00:25:38（Samsung）—— `use-samsung-id=on` |
| SUBNQN                | `nqn.2014-08.org.nvmexpress:uuid:...` |

## 显示器（EDID 池，patch 0009）

当前严格目录只启用一条 24" 1920×1080 模板。型号规格来自 Samsung 文档，
但 product/date/serial 等没有 raw EDID 样机，因此明确标记为合成身份。

| EDID Vendor | Name         | 尺寸 (mm) | 备注          |
|-------------|--------------|-----------|---------------|
| SAM         | S24F350      | 521×293   | 型号规格已核验；EDID 身份字段为合成值 |

实现：patch 0009 给 virtio-vga 加 `edid-vendor=` / `edid-name=` / `edid-serial=` / `edid-width-mm=` / `edid-height-mm=` cmdline 选项，start-vm.sh 从 profile.EDID_* 注入。

## 键盘 / 鼠标 / 数位板（USB HID 池，patch 0010）

当前目录各启用一个固定身份；不再从未经核验的品牌池随机拼接。

| 池          | 数量 | 包含品牌 |
|-------------|-----|----------|
| KBD_POOL    | 1   | Microsoft Wired Keyboard 600（通用 QEMU report） |
| MOUSE_POOL  | 1   | Microsoft USB Optical Mouse（通用 QEMU report） |
| TABLET_POOL | 1   | QEMU USB Tablet（纯虚拟设备） |

实现只投影 VID/PID/名称；键鼠没有原始 descriptor 抓取，且不向 guest 暴露 serial，
所以不能把 `identity_only_generic_report` 宣称成对应实体设备的完整实现。

## 动态 TPM

| 字段 | 值 |
|---|---|
| 策略 | `TPM=auto` 跟随 profile；H310 与禁用的 B350 兼容条目为 TPM 2.0 + CRB，H110 因缺板级 PTT 证据为 `none` |
| QEMU 设备 | TPM 2.0 可用 `tpm-crb`/`tpm-tis`；TPM 1.2 只用 `tpm-tis` |
| 后端 | `-tpmdev emulator,id=tpm0,chardev=chrtpm` + swtpm 后台 daemon |
| State 目录 | 2.0：`$VM_DIR/tpm-state/tpm2-00.permall`；1.2：`$VM_DIR/tpm12-state/tpm-00.permall` |
| State 绑定 | 0600 `platform-binding` 记录平台、实现、版本、前端和 PCR bank；不匹配时保留旧密钥并拒绝启动 |
| Control sock | `$VM_DIR/tpm-sock` (unixio chardev) |
| 首启 init | 2.0 带 `swtpm_setup --tpm2`；1.2 不带 `--tpm2`；两者都按 profile 设置 PCR bank |
| OVMF 要求 | 当前 TPM 2.0 平台使用含 Tcg2Dxe/Pei/ConfigDxe/PlatformDxe 的固件；本部署可用 `deploy/tools/build-ovmf.sh` 以 `-D TPM2_ENABLE=TRUE` 构建 `deploy/firmware/OVMF_CODE_4M_stealth.fd` |
| Guest 端验证 | `Get-Tpm` 应返回 `TpmPresent=True, TpmReady=True` |
| 常见坑 | (1) 不得修改系统 `/var/lib/swtpm-localca` 权限；启动器使用每实例私有 CA。(2) 更换主板或 TPM 版本时绑定会拒绝复用旧 state，应先备份并按迁移流程处理。(3) 当前 TPM 2.0 profile 所用 OVMF 若不含 Tcg2，`Get-Tpm` 可能无法 ready。 |

## ACPI BGRT / SSDT

裸金属固件常有 BGRT (boot logo) + 至少一个 ThermalZone。空缺会被仿真机视为 VM 信号。本部署：

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
| virtio-gpu 物理 PCI VEN:DEV         | `1AF4:1050`（virtio）           | 始终保持 `1AF4:1050`，供 stock VioGpuDod 绑定          | 启动器拒绝已删除的深层主 ID 开关 |
| virtio-gpu SUBSYS / 用户态逻辑 ID   | virtio 默认值                   | `SUBSYS_1C8210DE` / 逻辑 `10DE:1C82`（GTX 1050 Ti）    | QEMU subsystem 属性 + 统一 EXE 浅层投影 |

### 仍残留（需要更换 machine type 或更大改动）

| 面                             | 当前值                       | 目标值                              | 成本                                         |
|--------------------------------|------------------------------|-------------------------------------|----------------------------------------------|
| Q35 host bridge / LPC / SMBus / HDA controller | Intel `8086:29C0` / `2918` / `2930` / `2668` | AMD B350 chipset (e.g. `1022:43B7` / `1022:790E`) | 需新 machine type 或重写 `hw/i386/pc_q35.c`  |
| ACPI DSDT 方法名               | QEMU 默认                     | BIOS 厂商特定                        | 侵入 `hw/i386/acpi-build.c`，改动大          |
| stock viogpudo.sys 内部串      | `Red Hat VIOGPU WDDM DOD`     | 保持原版，不做内核字符串补丁         | 这是 Microsoft-WHQL stock 驱动的真实边界；名称只在用户态投影 |

### 客机端（只做必要初始化）

| 任务                                                          | 方法                                                                                     |
|---------------------------------------------------------------|------------------------------------------------------------------------------------------|
| GPU 驱动核验与浅层身份初始化（WMI / Device Manager）          | 只运行 `deploy/guest-stealth/package.sh` 生成的统一 `respawn-stealth.exe`                  |
| 保持 Windows 代码完整性与安全功能原状                         | 当前流程使用固定摘要、Microsoft-WHCP 签名的 stock 驱动；不要求关闭 HVCI/VBS、Hyper-V 或驱动签名强制 |
| 最小化 guest 附加软件                                         | 不为 GPU 身份安装完整 virtio-win/SPICE tools、NVIDIA 驱动、控制面板或常驻硬件工具          |
| 检查逻辑身份                                                   | 统一 EXE 成功并重启后，直接双击用户自行核验来源的 GPU-Z 2.70；无需 helper 或旁置 DLL       |

### 进阶（前面全做完 DNF 还是报 0x403 时再处理）

* **stock 驱动边界**——`viogpudo.sys` 的内部产品字符串属于原签名二进制，禁止重命名、修改或关闭签名强制。
* **`NvAPI_Initialize()` / `nvml.dll`**——系统搜索 shim 只覆盖已实现的 NVAPI 身份查询，
  没有真实 NVIDIA 内核运行时、NVML、Direct3D、CUDA 或 NVENC；原始 PCI 查询仍会看到
  物理 virtio 身份。
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
| 5 | 动态 TPM：清单能力/版本/前端一致，swtpm 可用，QEMU 含对应 TIS/CRB 前端 |
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

# TPM（版本应与当前 profile 的 TPM_VERSION 一致）
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
