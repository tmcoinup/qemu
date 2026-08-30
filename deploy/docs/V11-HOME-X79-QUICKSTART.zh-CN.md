# V-11 家用 X79（4C/8T、6C/12T）傻瓜教程

V-11 已继承 G-11 的家用 CPU 规格，但两条分支仍是独立实现。V-11 不做显卡直通或
vGPU；本次只扩展 CPU、主板、内存、SMBIOS/PCI 配套事实和启动封装。

## 1. 最省事的用法

先进入 V-11 仓库并查看可选型号：

```bash
cd /home/ubuntu/projects/qemu
git switch V-11
deploy/scripts/start-home-vm.sh --list
```

新建 4 核 8 线程实例，默认 8G：

```bash
deploy/scripts/start-home-vm.sh 11 --spec 4c8t
```

新建 6 核 12 线程实例，指定 16G，并在后台显示：

```bash
deploy/scripts/start-home-vm.sh 12 --spec 6c12t --memory-size 16G --headless
```

内存只接受 `4G`、`8G`、`12G`、`16G`，默认 `8G`。封装会把 4C/8T 映射为 8 个
vCPU，把 6C/12T 映射为 12 个 vCPU；不能再同时传 `--cpus` 或 `--ram`，避免互相覆盖。

新实例默认优先选择能以 DDR3-1866 工作的组合：

- 4C/8T：Core i7-4820K + ASUS P9X79；
- 6C/12T：Core i7-4960X + ASUS P9X79。

如果当前 KVM 宿主不能无警告实现首选 named CPU，底层启动器会按相同线程规格执行
真实 CPU realize 预检并尝试其它审核候选；不会用 `-cpu host` 或服务器品牌串冒充家用 CPU。

## 2. CPU、主板和内存型号

### CPU

| 规格 | QEMU 型号 | 真实零售型号 / Product Code | 基准/睿频 | 官方内存上限 |
|---|---|---|---:|---:|
| 4C/8T | `Core-i7-4820K` | Core i7-4820K / `BX80633I74820K` | 3.70/3.90 GHz | DDR3-1866 |
| 4C/8T | `Core-i7-3820` | Core i7-3820 / `BX80619I73820` | 3.60/3.80 GHz | DDR3-1600 |
| 6C/12T | `Core-i7-4960X` | Core i7-4960X / `BX80633I74960X` | 3.60/4.00 GHz | DDR3-1866 |
| 6C/12T | `Core-i7-4930K` | Core i7-4930K / `BX80633I74930K` | 3.40/3.90 GHz | DDR3-1866 |
| 6C/12T | `Core-i7-3930K` | Core i7-3930K / `BX80619I73930K` | 3.20/3.80 GHz | DDR3-1600 |

### 主板

| 品牌 / 型号 | BIOS | DIMM 槽 | 目录上限 | 音频 |
|---|---|---:|---:|---|
| ASUSTeK P9X79 | 4701 | 8 | DDR3-1866 / 64G | Realtek ALC892 |
| Gigabyte GA-X79-UP4 rev. 1.0 | F7 | 8 | DDR3-1866 / 64G | Realtek ALC892 |
| ASRock X79 Extreme4 | P3.20 | 4 | DDR3-1600 / 32G | Realtek ALC898 |

五款 CPU 都分别和三款主板组成完整原子平台，共 15 个组合。不能把某条平台的 BIOS、
codec、DIMM 槽数或 PCIe 代际拆出来与另一块板随机拼装。

### 内存（默认 8G）

| 品牌 | 2G 料号 | 4G 料号 | 额定频率 | 优先级 |
|---|---|---|---:|---|
| Samsung | `M378B5773DH0-CMA` | `M378B5273DH0-CMA` | DDR3-1866 | 最高 |
| Kingston | `KVR16N11S6/2` | `KVR16N11S8/4` | DDR3-1600 | 回落 |
| SK hynix | `HMT325U6CFR8C-PB` | `HMT351U6CFR8C-PB` | DDR3-1600 | 回落 |

DDR3-1866 是优先级，不是强制超频。只有 i7-4820K/i7-4930K/i7-4960X 搭配
P9X79 或 GA-X79-UP4 时报告 1866；i7-3820/i7-3930K，以及 X79 Extreme4，均按
CPU/主板共同的 1600 上限工作。

容量按 4G 模块形成 `1×4G`、`2×4G`、`3×4G`、`4×4G`。目录、运行时拓扑和
Windows 打包校验都会拒绝在少于四个 DIMM 槽的主板上提供 12G/16G。本次三块 X79
主板均有至少四槽，所以四档容量都可选；这条规则也会约束以后加入的双槽板。

## 3. 固定其它 CPU 或主板

平台 ID 的格式是：

```text
intel-lga2011-i7-<CPU>-<board>
```

CPU token：`3820`、`4820k`、`3930k`、`4930k`、`4960x`。

主板 token：`asus-p9x79`、`gigabyte-ga-x79-up4`、`asrock-x79-extreme4`。

例如固定 i7-3820 + Gigabyte：

```bash
deploy/scripts/start-home-vm.sh 13 \
  --spec 4c8t \
  --platform-id=intel-lga2011-i7-3820-gigabyte-ga-x79-up4
```

封装会先检查平台和 `--spec` 的线程规格是否一致；4C/8T 不能误选 6C/12T 平台。

## 4. 已有实例和换容量

每个实例首次创建后会把 CPU、主板、内存、序列号和部件组合写入自己的 `profile`。
普通重启必须沿用它，不能每次随机换硬件。封装发现已有 profile 时不会强塞默认 ASUS
平台。

如确实要更换平台或容量，先备份实例，并明确追加底层支持的 `--reroll`：

```bash
deploy/scripts/start-home-vm.sh 11 --spec 4c8t --memory-size 12G --reroll
```

`--reroll` 会改变 Guest 看到的硬件身份，可能影响 Windows 激活或软件授权，不能由脚本
自动替用户执行。

## 5. X79 的启动盘事实

P9X79、GA-X79-UP4 和 X79 Extreme4 都没有原生 M.2 插槽。本分支不会把它们描述成
板载 NVMe 启动：

- 系统盘从审核的 Samsung 840/850/860 PRO 512GB SATA/AHCI 池选择；
- NVMe 只通过 PCIe x4 转接卡作为数据盘能力；
- Sandy Bridge-E 组合按 Gen2 x4，Ivy Bridge-E 组合按 Gen3 x4；
- profile 中固定 `NVME_ROLE=data-only`，不会把 PCIe 转接卡冒充 M.2 socket。

## 6. 序列号说明

CPU Product Code、主板型号、内存料号和 BIOS 版本是目录中核验的真实产品字段。
主板、整机、机箱、DIMM 和磁盘的唯一序列值则按对应厂商标签/SPD格式现场生成并持久化：

- 每台 VM、每根 DIMM 的序列值互不复用；
- 普通重启不变化；
- 不从互联网上复制某台真实设备的唯一 S/N，也不把示例序列冒充样机采集值。

这是“真实品牌/真实料号 + 厂商格式的唯一合成序列”，而不是盗用实体硬件身份。

## 7. 第一次部署与检查

已有 V-11 编译环境只需重新构建并安装最终二进制的宿主 helper：

```bash
deploy/tools/build.sh --verify --install-host-helpers
deploy/scripts/tests/test_home_x79_pool.sh
```

依赖和全量宿主准备见 [USAGE](USAGE.md)。宿主凭据不要写入仓库；无人值守环境使用受控
部署服务或环境变量/安全凭据通道，`sudo -n` 无授权时应立即失败。

Windows 启动后可核对：

```powershell
Get-CimInstance Win32_Processor |
  Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed
Get-CimInstance Win32_BaseBoard |
  Select-Object Manufacturer,Product,Version,SerialNumber
Get-CimInstance Win32_PhysicalMemory |
  Select-Object Manufacturer,PartNumber,SerialNumber,Speed,ConfiguredClockSpeed,Capacity
```

预期 CPU 为 4/8 或 6/12，内存总量为所选档位；1866 只会出现在上述合法组合。

本流程不需要也不会开启 `testsigning`、`nointegritychecks`，不会修改 BCD，也不会安装
测试签名或自签名内核驱动。

## 8. 官方资料

- [Intel Core i7-3820](https://www.intel.com/content/www/us/en/products/sku/63698/intel-core-i73820-processor-10m-cache-up-to-3-80-ghz/specifications.html)
- [Intel Core i7-3930K](https://www.intel.com/content/www/us/en/products/sku/63697/intel-core-i73930k-processor-12m-cache-up-to-3-80-ghz/specifications.html)
- [Intel Core i7-4820K](https://www.intel.com/content/www/us/en/products/sku/77781/intel-core-i74820k-processor-10m-cache-up-to-3-90-ghz/specifications.html)
- [Intel Core i7-4930K](https://www.intel.com/content/www/us/en/products/sku/77780/intel-core-i74930k-processor-12m-cache-up-to-3-90-ghz/specifications.html)
- [Intel Core i7-4960X](https://www.intel.com/content/www/us/en/products/sku/77779/intel-core-i74960x-processor-extreme-edition-15m-cache-up-to-4-00-ghz/specifications.html)
- [ASUS P9X79 手册](https://dlcdnets.asus.com/pub/ASUS/mb/LGA2011/P9X79/E8038_P9X79.pdf)
- [Gigabyte GA-X79-UP4 规格](https://www.gigabyte.com/us/Motherboard/GA-X79-UP4-rev-10/sp)
- [ASRock X79 Extreme4](https://www.asrock.com/mb/Intel/X79%20Extreme4/index.asp)
- [Samsung DDR3-1866 2G UDIMM 数据表](https://download.semiconductor.samsung.com/resources/data-sheet/237561ds_ddr3_2gb_d-die_based_udimm_rev14.pdf)
- [Samsung M378B5273DH0-CMA 数据表](https://download.semiconductor.samsung.com/resources/data-sheet/m378b5273dh0-cma_ck0_ch9_cf8-0.pdf)
