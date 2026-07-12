# `vms/<N>/profile` 字段完全表

每台 VM 首次启动时 `stealth_pick_profile` 抽样下面所有字段并写入
`/home/ubuntu/images/vms/<N>/profile` 文件持久化，后续重启**永远复用同一份**。
保证 Windows 不会反激活、反作弊不会看到"硬件指纹漂移"。

字段分组按 stealth-lib.sh 内的池子组织。

## CPU （3 条候选池 `CPU_POOL`）

| 字段 | 来源 | 示例 | guest 端可见 |
|---|---|---|---|
| `CPU_QEMU_ARG` | pool 列 1 | `Ryzen3-1200` / `Skylake-Client-IBRS,family=6,model=158,...` | `-cpu` 字符串前缀 |
| `CPU_VENDOR` | pool 列 2 | `AuthenticAMD` / `GenuineIntel` | CPUID 0,0 vendor |
| `CPU_NAME` | pool 列 3 | `AMD Ryzen 3 1200 Quad-Core Processor` | `Win32_Processor.Name` |
| `CPU_MAX_MHZ` | pool 列 4 | 3400 | Win32_Processor.MaxClockSpeed |
| `CPU_CUR_MHZ` | pool 列 5 | 3100 | TSC freq |
| `CPU_PART` | pool 列 6 | `YD1200BBM4KAE` | SMBIOS Type 4 part |
| `CPU_PROC_FAMILY` | pool 列 7 | `0x139` (Zen) / `0xCD` (Intel) | SMBIOS Type 4 family |
| `CPU_SOCKET` | pool 列 8 | AM4 / LGA1151 / LGA1200 | SMBIOS Type 4 socket type |
| `CPU_MODEL` | 派生 `CPU_QEMU_ARG.split(',')[0]` | `Ryzen3-1200` | QEMU 模型主名 |
| `CPU_SERIAL` | `_rand 10位` | `4781458834` | SMBIOS Type 4 serial |

## 主板 + PCI 子系统 （27 条候选池 `BOARD_POOL`，按 socket 过滤）

| 字段 | 来源 | 示例 | guest 端 |
|---|---|---|---|
| `BOARD_MFR` | pool 列 2 | `ASRock` / `ASUSTeK COMPUTER INC.` / `Micro-Star International Co., Ltd.` | Win32_BaseBoard.Manufacturer |
| `BOARD_PRODUCT` | pool 列 3 | `AB350 Pro4` / `PRIME B350-PLUS` | Win32_BaseBoard.Product |
| `BOARD_FAMILY` | pool 列 4 | `AB350 Pro4` / `PRIME` | SMBIOS Type 2 family |
| `BOARD_VERSION` | pool 列 5 | `Default string` / `Rev X.0x` | Win32_BaseBoard.Version |
| `BOARD_SERIAL` | `_serial_<mfr>` 函数 | `M80-2BD02679` (ASRock) | Win32_BaseBoard.SerialNumber |
| `BOARD_ASSET` | `_rand 10位` | `9012345678` | SMBIOS Type 2 asset tag |
| **`BOARD_SUBSYS_VEN`** | pool 列 7 (2026-05 新) | `0x1849` (ASRock) | PCI 子系统 vendor ID（所有桥/控制器） |
| **`BOARD_SUBSYS_DEV`** | pool 列 8 (2026-05 新) | `0x1230` | PCI 子系统 device ID |

## 系统 / BIOS / 机箱

| 字段 | 来源 | 示例 | guest 端 |
|---|---|---|---|
| `SYSTEM_MFR` | = `BOARD_MFR` | 同上 | Win32_ComputerSystem.Manufacturer |
| `SYSTEM_PRODUCT` | `SYSTEM_PRODUCT_POOL` | `System Product Name` / `Default string` / `All Series` | Win32_ComputerSystem.Model |
| `SYSTEM_FAMILY` | `SYSTEM_FAMILY_POOL` | `Desktop` / `To be filled by O.E.M.` | SMBIOS Type 1 family |
| `SYSTEM_VERSION` | = `BOARD_VERSION` | 同上 | Win32_ComputerSystem.SystemVersion |
| `SYSTEM_SERIAL` | `_serial_<mfr>` | `M80-6BAC4509` | Win32_BIOS.SerialNumber |
| `SYSTEM_SKU` | `_rand SKU<6位>` | `SKU138567` | Win32_ComputerSystem.SystemSKUNumber |
| `BIOS_VENDOR` | 常量 | `American Megatrends Inc.` | Win32_BIOS.Manufacturer |
| `BIOS_VERSION` | `BIOS_VERSION_POOL` (9 个) | `6042` | Win32_BIOS.SMBIOSBIOSVersion |
| `BIOS_DATE` | `BIOS_DATE_POOL` (6 个) | `12/09/2021` | Win32_BIOS.ReleaseDate |
| `CHASSIS_TYPE` | `CHASSIS_POOL` | `Desktop` / `Tower` / `Mini Tower` | Win32_SystemEnclosure.ChassisTypes |
| `CHASSIS_SERIAL` | `_serial_<mfr>` | `M80-53092893` | Win32_SystemEnclosure.SerialNumber |

## 网卡

| 字段 | 来源 | 示例 | guest 端 |
|---|---|---|---|
| `NIC_MAC` | `_gen_mac` (从 11 OUI 池) | `54:bf:64:e9:8e:48` | Win32_NetworkAdapter.MACAddress；MAC OUI 池 = Intel/Realtek/ASUS，**绝不**用 52:54:00 |

## UUID

| 字段 | 来源 | 示例 | guest 端 |
|---|---|---|---|
| `UUID` | `_gen_uuid` | `2987ae96-5e0f-4bd1-af70-09142971286a` | Win32_ComputerSystemProduct.UUID |

## 显卡 GPU （6 条池 `GPU_POOL`）

| 字段 | 来源 | 示例 | guest 端 |
|---|---|---|---|
| `GPU_VENDOR` | pool 列 1 | NVIDIA / AMD | Win32_VideoController.AdapterCompatibility |
| `GPU_NAME` | pool 列 2 | `NVIDIA GeForce GTX 1050 Ti` | Win32_VideoController.Name (经 apply-gpu-spoof.ps1) |
| `GPU_PCI_VEN` | pool 列 3 | `0x10DE` (NVIDIA) | PCI 子系统 vendor ID（vga 设备） |
| `GPU_PCI_DEV` | pool 列 4 | `0x1C82` | PCI 子系统 device ID |
| `GPU_RAM_MB` | pool 列 5 | 2048 / 4096 | 显存大小（仅 SMBIOS 报告） |
| `GPU_BIOS` | pool 列 6 | `Version 86.07.48.00.A0` | GPU BIOS 字符串 |
| `GPU_REV` | pool 列 7 | `0xA1` | PCI revision |

## 显示器（10 条池 `MONITOR_POOL`，**2026-05 新加**，patch 0009）

| 字段 | 来源 | 示例 | guest 端 |
|---|---|---|---|
| `EDID_VENDOR` | pool 列 1 (3 char EDID code) | `AOC` / `SAM` / `HKC` / `BNQ` / `DEL` / `GSM` / `PHL` | EDID 头 manufacturer code → Win32_DesktopMonitor.MonitorManufacturer |
| `EDID_NAME` | pool 列 2 | `24G2E5` / `C24F390` / `M24A1F` | EDID detailed descriptor 0xFC → Win32_DesktopMonitor.Name |
| `EDID_WIDTH_MM` | pool 列 3 | 530 | EDID basic display params |
| `EDID_HEIGHT_MM` | pool 列 4 | 300 | EDID basic display params |
| `EDID_SERIAL` | `_monitor_serial <prefix>` | `H4VWLFY8XB2I` | EDID 0xFF descriptor; 8 char alnum suffix |

## NVMe （5 条池 `NVME_POOL`）

| 字段 | 来源 | 示例 | guest 端 |
|---|---|---|---|
| `NVME_MODEL` | pool 列 1 | `Samsung SSD 970 PRO 512GB` | NVMe Identify MN; Win32_DiskDrive.Model |
| `NVME_FIRMWARE` | pool 列 2 | `1B2QEXM7` | NVMe Identify FR |
| **`NVME_SIZE_BYTES`** | pool 列 3 (2026-05 新) | `512110190592` / `1000204886016` | NVMe namespace size；qcow2 同步建对应大小 |
| `NVME_SERIAL` | `_nvme_serial` | `S000B48A390N` | NVMe Identify SN; Win32_DiskDrive.SerialNumber |

## 内存 （4 条池 `MEM_POOL`，2026-05 SN 持久化 + 内存量持久化）

| 字段 | 来源 | 示例 | guest 端 |
|---|---|---|---|
| `MEM_MFR` | pool 列 1 | Kingston / Crucial / Samsung / SK hynix | SMBIOS Type 17 manufacturer; Win32_PhysicalMemory.Manufacturer |
| `MEM_PART_2G` | pool 列 2 | `KVR26N19S6/2` | per-DIMM ≤ 2GB 时用 |
| `MEM_PART_4G` | pool 列 3 | `HX426C16FB3A/4` | per-DIMM ≥ 4GB 时用 |
| **`MEM_SERIAL`** | `_mem_serial` (2026-05 新) | `597757F0` | DIMM 0 的 SMBIOS Type 17 serial → Win32_PhysicalMemory.SerialNumber；**跨重启不变** |
| **`MEM_TOTAL_MB`** | pick 默认 4096 (2026-05 新) | `4096` / `8192` | 内存总量 (MiB)，决定 DIMM 拓扑；钉进 profile 跨重启稳定 |

**双通道第 2 条 DIMM 的序列号不另存**：`stealth_smbios_args` 在 8GB 时按
`sha256("${MEM_SERIAL}-dimm2")[:8]` 确定性派生第 2 条 SN（跨重启稳定、跨 VM 唯一），
与 DIMM 0 的 `MEM_SERIAL` 一起以 `serial=SN1|SN2` 喂给打了补丁的 QEMU `type=17`。
两条 DIMM 因此各自唯一 SN——真实主板两条内存 SN 必不同，共用同一 SN 是一眼假的伪造特征。

> DIMM 数 / 容量由 `MEM_TOTAL_MB`（或启动时 `--ram=` / `RAM=` 临时覆盖）决定：
> - ≤ 4096 → 1 条 DIMM 占满，单通道（2 卡槽占 1 空 1，槽位 `DIMM_A2`）
> - \> 4096 → 2 条 DIMM 各占一半，双通道（2 卡槽全占，槽位 `DIMM_A2` / `DIMM_B2`，CHANNEL A/B）
>
> **改某台 VM 的内存（启动命令不变）**：`deploy/scripts/set-vm-memory.sh <N> 8G`
> 只改 `MEM_TOTAL_MB` 一个字段，不碰其它身份；改完重启 VM 生效。
> 解析优先级：`--ram=` / `RAM=` > `profile.MEM_TOTAL_MB` > 4096。

## 键盘 （5 条池 `KBD_POOL`，**2026-05 新加**，patch 0010）

| 字段 | 来源 | 示例 | guest 端 |
|---|---|---|---|
| `KBD_VID` | pool 列 1 | `0x045E` (Microsoft) / `0x046D` (Logitech) / `0x09DA` (A4Tech 双飞燕) / `0x24AE` (Rapoo 雷柏) / `0x413C` (Dell) | USB idVendor |
| `KBD_PID` | pool 列 2 | `0x0750` / `0xC31C` / `0x1F12` / `0x200A` / `0x2003` | USB idProduct |
| `KBD_MFR` | pool 列 3 | `Microsoft` / `Logitech` / `A4TECH` / `Rapoo` / `Dell` | USB iManufacturer |
| `KBD_PRODUCT` | pool 列 4 | `Microsoft Wired Keyboard 600` / `A4TECH USB Keyboard KK-3` / ... | USB iProduct |
| `KBD_SERIAL` | `_usb_hid_serial <prefix>` | `A405HI1K` | USB iSerialNumber |

## 鼠标 （5 条池 `MOUSE_POOL`，patch 0010）

| 字段 | 来源 | 示例 |
|---|---|---|
| `MOUSE_VID` | pool 列 1 | `0x045E` / `0x046D` / `0x09DA` / `0x24AE` / `0x413C` |
| `MOUSE_PID` | pool 列 2 | `0x00CB` / `0xC077` / `0x31AC` / `0x1102` / `0x301A` |
| `MOUSE_MFR` | pool 列 3 | 同 KBD_MFR 选项 |
| `MOUSE_PRODUCT` | pool 列 4 | `Microsoft USB Optical Mouse` / `A4TECH OP-720` 等 |
| `MOUSE_SERIAL` | `_usb_hid_serial` | 6 char |

## 数位板 （4 条池 `TABLET_POOL`，patch 0010；usb-tablet 默认）

| 字段 | 来源 | 示例 |
|---|---|---|
| `TABLET_VID` | pool 列 1 | `0x256C` (HUION) / `0x2FEB` (VEIKK) / `0x28BD` (XP-Pen) |
| `TABLET_PID` | pool 列 2 | `0x006D` / `0x006E` / `0x0001` / `0x0094` |
| `TABLET_MFR` | pool 列 3 | HUION / VEIKK / XP-PEN |
| `TABLET_PRODUCT` | pool 列 4 | `HUION PenTablet` / `VEIKK A30` / `XP-Pen Star G640` |
| `TABLET_SERIAL` | `_usb_hid_serial` | 6 char |

## 老 profile 升级路径

如果你已经在用 2026-04 之前的 profile（缺 `BOARD_SUBSYS_*` / `NVME_SIZE_BYTES` / `MEM_SERIAL` / `EDID_*` / `KBD_*` / `MOUSE_*` / `TABLET_*`），`stealth_load_profile` 会按以下规则智能 fallback，**不需要 reroll 整身份**：

| 缺失字段 | Fallback 策略 |
|---|---|
| `BOARD_SUBSYS_VEN/DEV` | 按 `BOARD_MFR` 推：ASUS→0x1043:0x8694、MSI→0x1462:0x7B49、Gigabyte→0x1458:0x5001、ASRock→0x1849:0x1230 |
| `NVME_SIZE_BYTES` | 按 `NVME_MODEL` 关键词推：含 "1TB"→10^12 B、"500GB"→5×10^11 B、"512GB"→5.12×10^11 B 等 |
| `MEM_SERIAL` | `sha256("${UUID}-mem")[:8]` 去派生确定性 8 字符 SN（UUID 跨 VM 唯一 → SN 唯一） |
| `MEM_TOTAL_MB` | 留空 → start-vm.sh 退回历史默认 4096 MiB（不擅自给老 VM 升内存量；要升用 `set-vm-memory.sh <N> 8G`） |
| `EDID_*` | 退化为 patch 0009 默认值：`SAM / S24F350 / H4ZK500001VL / 530×300mm` |
| `KBD_*` | 退化为 patch 0010 默认值：Microsoft Wired Keyboard 600 (045E:0750) |
| `MOUSE_*` | Microsoft USB Optical Mouse (045E:00CB) |
| `TABLET_*` | HUION PenTablet (256C:006D) |

想用上新池子的话：
```bash
# 方案 1：保留 UUID 等核心身份，只补新字段（写一次 save 让 fallback 值持久化）
( source /home/ubuntu/projects/qemu/deploy/scripts/stealth-lib.sh && \
  stealth_load_profile /home/ubuntu/images/vms/1/profile && \
  stealth_save_profile /home/ubuntu/images/vms/1/profile )

# 方案 2：重 roll 整身份（含 UUID 全换；激活会重激活，重装才安全）
deploy/scripts/start-vm.sh 1 --reroll
```

## 启动时打印

`start-vm.sh` 在 `--- launching ---` 之前调 `stealth_print_profile`，把上述全部字段
按分组打印到 stderr。看 host 终端就能确认这 VM 这次会以什么硬件画像启动。
