# G-11 家用 6C/12T：统一创建池傻瓜教程

Core i7-4930K 已直接进入 `create-vm.sh` 普通新建池，不需要也不提供单独的
`create-6c12t-vm.sh`。CPU、主板、内存、SSD 都通过通用组件参数选择，最终仍只会
生成审核过的完整整机组合。

## 1. 可选硬件

固定 CPU 身份是 Intel Core i7-4930K：6 核 12 线程、3.40/3.90 GHz、12 MiB L3、
LGA2011、四通道 DDR3-1866、无核显。Intel 的
[官方规格](https://www.intel.com/content/www/us/en/products/sku/77780/intel-core-i74930k-processor-12m-cache-up-to-3-90-ghz/specifications.html)
是 CPU 合同依据。

主板有三个品牌：

| `--board-profile` | 品牌/型号 | BIOS | 审核内存上限 |
|---|---|---|---:|
| `asus-p9x79` | ASUS P9X79 | 4701 | DDR3-1866 |
| `gigabyte-x79-up4` | Gigabyte GA-X79-UP4 | F7 | DDR3-1866 |
| `asrock-x79-extreme4` | ASRock X79 Extreme4 | P3.20 | DDR3-1600 非超频档 |

ASUS 的 CPU 支持表、Gigabyte 的 F4 起 Ivy Bridge-E 支持，以及 ASRock 的 P3.20
支持表分别证明三块板可配 i7-4930K：

- [ASUS P9X79 CPU 支持](https://www.asus.com/supportonly/p9x79/helpdesk_cpu/)
- [Gigabyte GA-X79-UP4 支持与 BIOS](https://www.gigabyte.com/us/Motherboard/GA-X79-UP4-rev-10/support)
- [ASRock LGA2011 CPU 支持表](https://www.asrock.com/support/cpu.asp?s=2011&u=672)

内存按大牌优先，且不伪造频率：

| 主板 | 4 GiB | 8/12/16 GiB |
|---|---|---|
| ASUS / Gigabyte | Samsung 1866；Micron、Kingston、SK hynix 1600，共 4 品牌 | Samsung、Micron、Elpida 1866；Kingston、SK hynix 1600，共 5 品牌 |
| ASRock | Samsung、Micron、Kingston、SK hynix 1600，共 4 品牌 | 同左，每个容量都是 4 品牌 |

Samsung 2 GiB/4 GiB CMA 和 Intel 的 Ivy Bridge-E 非 ECC 验证表是 1866 条目的依据：

- [Samsung 2GB DDR3 UDIMM 数据表](https://download.semiconductor.samsung.com/resources/data-sheet/237561ds_ddr3_2gb_d-die_based_udimm_rev14.pdf)
- [Samsung 4Gb DDR3 UDIMM 数据表](https://download.semiconductor.samsung.com/resources/data-sheet/DS_DDR3_4Gb_Q_die_UDIMM_Rev10-0.pdf)
- [Intel X79/Ivy Bridge-E DDR3-1866 验证结果](https://www.intel.com/content/dam/www/public/us/en/documents/platform-memory/ddr3-1866-udimm-n-ecc-ivybridge-e-validation-results.pdf)

SSD 通用池提供五个品牌：Samsung、Crucial、Kingston、Intel、Western Digital。
每个 profile 都是精确 512 GB；默认会先尝试审核过的 Gen3 x4 被动转接 NVMe，
需要年代原生搭配时也可显式选择 SATA。

## 2. 先查看列表

在仓库根目录运行：

```bash
./deploy/scripts/check-hardware-pool.sh
./deploy/scripts/create-vm.sh --list-cpu-profiles
./deploy/scripts/create-vm.sh --list-board-profiles
./deploy/scripts/create-vm.sh --list-memory-profiles
./deploy/scripts/create-vm.sh --list-ssd-profiles
```

宿主检查中 `i7-4930k` 的 `HOST_CLASS` 必须为 `supported`。如果不是，不要绕过
`enforce=on`；换宿主或选择检查通过的 CPU。

## 3. 复制命令创建

先选一个没有使用过的 VM ID。下面三条分别覆盖三个主板品牌、三个内存品牌和三个
SSD 品牌。

ASUS + Samsung DDR3-1866 4 GiB + Samsung 840 PRO：

```bash
./deploy/scripts/create-vm.sh 101 \
  --cpu-profile i7-4930k \
  --board-profile asus-p9x79 \
  --memory-profile samsung-m378b5773dh0-1866-2x2 \
  --ssd-profile samsung-840-pro-512gb
```

Gigabyte + Elpida DDR3-1866 12 GiB + Crucial MX100：

```bash
./deploy/scripts/create-vm.sh 102 \
  --cpu-profile i7-4930k \
  --board-profile gigabyte-x79-up4 \
  --memory-profile elpida-ebj40ug8bfw0-3x4 \
  --ssd-profile crucial-mx100-512gb
```

ASRock + SK hynix DDR3-1600 16 GiB + WD SA530：

```bash
./deploy/scripts/create-vm.sh 103 \
  --cpu-profile i7-4930k \
  --board-profile asrock-x79-extreme4 \
  --memory-profile hynix-hmt351u6cfr8c-4x4 \
  --ssd-profile wd-pc-sa530-512gb
```

只关心容量时，可以让池子在该主板的最高审核频率档内选择品牌：

```bash
./deploy/scripts/create-vm.sh 104 \
  --cpu-profile i7-4930k \
  --board-profile asus-p9x79 \
  --memory-size 8G \
  --ssd-profile intel-545s-512gb
```

需要确定品牌时必须使用 `--memory-profile`，不要同时再传 `--memory-size`。合法容量为
`4G`、`8G`、`12G`、`16G`；12G 如实呈现三通道，16G 如实呈现四通道。

GPU 和显示器仍来自现有通用池；因为 4930K 没有核显，需要时可附加：

```bash
--gpu-vram 2048 --monitor-profile dell-p2419h
```

## 4. 启动和验收

```bash
./deploy/scripts/start-vm.sh 101
```

宿主侧只读核对：

```bash
grep -E '^(PLATFORM|CPU_MODEL|CPU_CORES|CPU_VCPUS|BOARD_BRAND|BOARD_MODEL|MEM_BRAND|MEM_MODEL_LIST|MEM_SPEED|MEM_TOTAL_MB|SSD_BRAND|SSD_MODEL)=' \
  "${VM_ROOT:-${IMAGE_ROOT:-/home/ubuntu/images}/vms}/101/vm.conf"
```

Windows PowerShell 中只读核对：

```powershell
Get-CimInstance Win32_Processor |
  Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, L3CacheSize
Get-CimInstance Win32_BaseBoard |
  Select-Object Manufacturer, Product, Version
Get-CimInstance Win32_PhysicalMemory |
  Select-Object Manufacturer, PartNumber, Speed, Capacity
Get-PhysicalDisk | Select-Object FriendlyName, BusType, Size
```

CPU 应显示 6 核/12 线程和 12288 KiB L3；主板、内存和 SSD 品牌应与创建命令一致。

## 5. 安全边界

- 不要用 `--force` 把已有 VM 的磁盘改绑到另一套硬件；换组合请使用新 VM ID。
- 组件选择仍经过原子白名单，不会把任意 CPU、主板和内存做笛卡尔积乱配。
- 这项功能不启用 `testsigning` 或 `nointegritychecks`，不修改 BCD，不安装测试签名
  或自签名内核驱动。
- 宿主凭据不得写入仓库；需要时使用环境变量或安全渠道。
