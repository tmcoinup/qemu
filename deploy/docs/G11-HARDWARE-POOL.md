# G-11 X79 硬件池与合法性门禁

本页是当前 G-11 新建硬件池的权威操作说明。V-11 与 G-11 是独立分支；不要把
V-11 的整套平台、驱动或运行参数直接复制到 G-11。

## 先看结论

| 类别 | 当前结果 |
|---|---|
| 普通新建 CPU | 3 款：Core i7-4930K 6C/12T、Core i7-4820K/Core i7-3820 4C/8T；均为家用无核显 |
| 正常新建主板 | 3 款/3 品牌：ASUS P9X79、Gigabyte GA-X79-UP4、ASRock X79 Extreme4 |
| 正常内存档 | 4G、8G、12G、16G；DDR3-1600/1866，Samsung/Micron/Kingston/SK hynix/Elpida |
| 通道 | 4G/8G 为两根双通道；12G 为 3×4G 三通道；16G 为 4×4G 四通道 |
| 可新建整机组合 | 普通 `new` 102 条，其中 i7-4930K 54 条；全部是 X79/LGA2011 原子白名单 |
| 完整目录 | 11 CPU、16 主板、45 内存、366 整机；其中 261 archived、3 legacy compatibility |
| SSD | 10 款精确 512110190592 字节；自动优先 3 款 Gen3 x4 NVMe，再按平台回退 7 款 SATA |
| 序列 | 主板厂牌格式、DIMM JEDEC 4-byte、SSD 型号严格格式；创建并持久化、全池查重 |

旧 H81 与 6G 组合没有删除 ID，而是统一变成 `archived`，只用于加载已有 VM。
`--include-fallback` 也不会让 archived 重新参与新建。三条
`legacy-compatibility` 只在显式授权时作为旧平台兜底，不属于正常 X79 池。

机器可读事实以脚本输出为准：

```bash
./deploy/scripts/create-vm.sh --list-platforms
./deploy/scripts/create-vm.sh --include-fallback --list-platforms
./deploy/scripts/create-vm.sh --list-memory-profiles
./deploy/scripts/create-vm.sh --list-ssd-profiles
./deploy/scripts/check-hardware-pool.sh --machine-readable
```

当前摘要必须是：

```text
cpu=11 board=16 memory=45 combination=366
new_default=102 explicit_new=0 archived=261 legacy=3
brands board=3 memory=5 ssd=5
```

## 三款普通新建 CPU

用户条件的交集是：

1. 消费/家用 Core 型号；
2. 同一创建池同时提供 4 核 8 线程和恰好 6 核 12 线程；
3. 不带核显优先；
4. 能与消费 X79/LGA2011 四通道主板及非 ECC DDR3 合理搭配；
5. QEMU/KVM 能按闭合模型实现并通过 realization 门禁。

审核交集是：

| key | 型号 | 拓扑 | 基础/最高频率 | 官方内存上限 | PCIe |
|---|---|---:|---:|---:|---:|
| `i7-4820k` | Core i7-4820K | 4C/8T | 3.7/3.9 GHz | DDR3-1866、4 通道 | Gen3 |
| `i7-3820` | Core i7-3820 | 4C/8T | 3.6/3.8 GHz | DDR3-1600、4 通道 | Gen2 |
| `i7-4930k` | Core i7-4930K | 6C/12T | 3.4/3.9 GHz | DDR3-1866、4 通道 | Gen3 |

新增项使用家用 Core i7 而不是 Xeon，也不引入带核显平台。i7-4930K 直接属于
普通 `new` 池，默认性能优先级先选 i7-4930K + DDR3-1866，再按宿主能力回落到
i7-4820K/i7-3820。宿主不支持某个模型时仍由 realization 门禁跳过，不会只看名字
强启。所有创建统一使用 `create-vm.sh`，详细教程见
[G11-6C12T-QUICKSTART.md](G11-6C12T-QUICKSTART.md)。

官方来源：

- [Intel Core i7-3820 规格](https://www.intel.com/content/www/us/en/products/sku/63698/intel-core-i73820-processor-10m-cache-up-to-3-80-ghz/specifications.html)
- [Intel Core i7-4820K 规格](https://www.intel.com/content/www/us/en/products/sku/77781/intel-core-i74820k-processor-10m-cache-up-to-3-90-ghz/specifications.html)
- [Intel Core i7-4930K 规格](https://www.intel.com/content/www/us/en/products/sku/77780/intel-core-i74930k-processor-12m-cache-up-to-3-90-ghz/specifications.html)
- [Intel 关于无核显处理器的说明](https://www.intel.com/content/www/us/en/support/articles/000006778/processors.html)

## 三块真实 X79 主板

| key | 厂牌与型号 | DIMM 槽/上限 | 审核内存上限 | 主 PCIe 槽 |
|---|---|---:|---:|---|
| `asus-p9x79` | ASUSTeK P9X79 | 8 / 64 GiB | DDR3-1866 | PCIEX16_1 |
| `gigabyte-x79-up4` | Gigabyte GA-X79-UP4 rev.1.0 | 8 / 64 GiB | DDR3-1866 | PCIEX16_1 |
| `asrock-x79-extreme4` | ASRock X79 Extreme4 | 4 / 32 GiB | DDR3-1600 | PCIE1 |

三块板都属于消费 X79，也都没有原生 M.2。NVMe 只能通过目录中的被动 PCIe 转接器
路径出现；启动器不会把转接器伪报成主板原生 M.2。

官方来源：

- [ASUS P9X79 手册](https://dlcdnets.asus.com/pub/ASUS/mb/LGA2011/P9X79/E8038_P9X79.pdf)
  与 [BIOS 页](https://www.asus.com/us/supportonly/p9x79/helpdesk_bios/)
- [Gigabyte GA-X79-UP4 规格](https://www.gigabyte.com/us/Motherboard/GA-X79-UP4-rev-10/sp)
- [ASRock X79 Extreme4 规格](https://www.asrock.com/mb/Intel/X79%20Extreme4/)
  与 [手册](https://download.asrock.com/Manual/X79%20Extreme4.pdf)
- [ASRock i7-4930K 支持表（X79 Extreme4 最低 P3.20）](https://www.asrock.com/support/cpu.asp?s=2011&u=672)

底层 machine 仍是 QEMU q35/ICH9 行为模型；00:1f.0 的 inventory identity 会显示
审核 X79 LPC `8086:1D41 rev06`。这修正平台身份，但不宣称完整复刻实体 X79 PCH。
ICH9-AHCI、qemu-xhci 和 QEMU nvme controller 仍保留各自真实实现边界。

## 4/8/12/16 内存

新建档位只允许：

| 容量 | 逐槽 | 通道 |
|---:|---|---|
| 4 GiB | 2+2 GiB | dual-channel |
| 8 GiB | 4+4 GiB | dual-channel |
| 12 GiB | 4+4+4 GiB | triple-channel |
| 16 GiB | 4+4+4+4 GiB | quad-channel |

“几根就是几通道”在这里落实为 2/2、3/3、4/4 对称布局。12G 不是 8+4 Flex，16G
也不是单条或两条 8G。每槽容量、Rank、device width、JEP106、料号与独立序列同时
进入 SMBIOS Type 17 和 SPD，任何字段不一致都会失败关闭。

DDR3-1866 使用 Samsung CMA、Intel Ivy Bridge-E 非 ECC 验证表中的 Elpida
`EBJ40UG8BFW0-JS-F` 与 Micron `MT8KTF51264AZ-1G9`；只和 Ivy Bridge-E 及支持
1866 的 P9X79/GA-X79-UP4 组合。ASRock X79 Extreme4 按官方非超频上限使用
DDR3-1600。

i7-4930K 的品牌覆盖不是固定整机：P9X79/GA-X79-UP4 的 4G 有 Samsung、Micron、
Kingston、SK hynix 四品牌，8/12/16G 再加入 Elpida，共五品牌；X79 Extreme4 的
每个容量都有 Samsung、Micron、Kingston、SK hynix 四品牌。最低 4G 的 1866 选项
为 `2 × M378B5773DH0-CMA`，8/12/16G 的 Samsung 1866 使用
`M378B5173QH0-CMA`。不会为了凑品牌数违反板、CPU 或模组上限。

来源：

- [Intel Sandy Bridge-E DDR3-1600 验证表](https://www.intel.com/content/dam/doc/platform-memory/ddr3-1600-udimm-n-ecc-sandy-bridge.pdf)
- [Intel Ivy Bridge-E DDR3-1866 验证表](https://www.intel.com/content/dam/www/public/us/en/documents/platform-memory/ddr3-1866-udimm-n-ecc-ivybridge-e-validation-results.pdf)
- [Micron MT8KTF51264AZ 数据表](https://www.micron-electronic.com/pdf-92/mt8ktf51264az-1g9p1.pdf)

SPD 的 1600/1866 是来宾硬件身份，不是 QEMU 带宽限速。启动使用宿主原生内存带宽；
宿主性能策略把 THP 设为 `madvise` 并关闭同步 defrag，详见
[G11-PERFORMANCE-QUICKSTART.md](G11-PERFORMANCE-QUICKSTART.md)。

## PCIe 3.0 SSD 优先且保持合理

自动存储顺序优先：

1. WD Black PCIe 512GB；
2. Samsung 970 PRO 512GB；
3. Samsung 960 PRO 512GB；
4. 七款审核 SATA 512GB。

三款 NVMe 都声明 Gen3 x4，`i7-4820K/i7-4930K + X79 被动转接器` 能满足合同。
i7-3820 的官方 PCIe 是 Gen2，因此源头自动选择会回退 SATA；手动指定不合理的
Gen3 profile 会被平台/SSD 联合门禁拒绝。十款盘的虚拟容量均精确为
`512110190592` 字节，不能只改型号字符串跨容量重绑。

## 序列号策略

新 VM 创建一次并将身份写入 `vm.conf`，启动时再次验证：

- ASUS baseboard：12 字符、带发布年/月与 `S` 位置的厂牌格式；
- Gigabyte：`SNyyww######`，年份与主板发布年一致、周数 01..53；
- ASRock：审核的字母数字结构；
- DIMM：非保留 JEDEC 4-byte，每槽稳定派生且互不重复；
- SSD：每个具体型号的严格 ATA/NVMe Identify 格式；
- GPU/USB：没有可靠实体 S/N 来源时分别为 `not-exposed` / `none`，不拿 mdev UUID
  或 QEMU 占位值冒充。

格式依据使用厂商公开的标签查找说明：

- [ASUS 序列号位置与格式说明](https://www.asus.com/us/support/article/706/)
- [Gigabyte 主板序列号说明](https://esupport.gigabyte.com/Notice/mb_sn.htm)
- [ASRock 查找序列号说明](https://www.asrock.com/SUPPORT/index.asp?cat=FindSN)

生成值不是从网页或某台实物复制来的序列。创建器持有 fleet identity 锁，对
system/baseboard/chassis、DIMM、SSD、显示器、UUID 和 MAC 跨 VM 查重；撞号重抽。

## 新建示例

性能优先自动选择：

```bash
./deploy/scripts/create-vm.sh 101
```

固定一条真实 12G/三通道组合，并让存储自动优先 Gen3 NVMe：

```bash
./deploy/scripts/create-vm.sh 102 \
  --platform i7-4820k-x79-up4-elpida-12g
```

固定 16G/四通道和审核 NVMe：

```bash
./deploy/scripts/create-vm.sh 103 \
  --platform i7-4820k-p9x79-micron-16g \
  --ssd-profile samsung-970-pro-512gb
```

旧 6G ID 会明确报 archived，不会因 `--force` 或 `--allow-fallback-platform` 重新
变成新建平台。已有 VM 可以继续运行或删除，不会被静默迁移。

## 共享 CPU、22C/44T 与时钟

`--cpu-isolate=false` 完全绕过 taskset、QMP pin、cpuset/cgroup 和隔离 helper。8 vCPU
是 Guest 的最大并行资源，不是永久占用 8 个宿主线程；空闲时调度资源可给宿主和
其它 VM。它不等于无限算力，也不会直接修复 RTC/TSC。

22C/44T 宿主使用共享模式时不按 VM 数量或已分配 vCPU 总数警告、拦截；第六台及
后续 VM 可直接启动。它适合 Guest 大多空闲或错峰繁忙的场景；六台 4C/8T 若一起
满载，仍是 48 vCPU 竞争 44 个宿主线程，必然发生调度争用。

时钟与 V-11 体感差异由动态全频段、稳定 TSC/RTC 和内存/I/O 策略单独处理：

```bash
./deploy/scripts/g11-performance.sh audit
./deploy/scripts/g11-performance.sh apply
./deploy/scripts/start-vm.sh 101 --cpu-isolate=false
```

不会开启 testsigning/nointegritychecks，不改 Windows BCD，不安装测试签名或自签名
内核驱动。宿主凭据只可通过 sudo 或运行时安全环境变量提供，不得写入仓库。

## 验证

```bash
bash ./deploy/tests/vgpu/test_hardware_legality.sh
bash ./deploy/tests/vgpu/test_hardware_pool_audit.sh
bash ./deploy/tests/vgpu/test_hardware_serials.sh
bash ./deploy/tests/vgpu/test_ssd_catalog.sh
bash ./deploy/tests/vgpu/test_cpu_isolation.sh
bash ./deploy/tests/vgpu/test_vm_capacity.sh
bash ./deploy/tests/vgpu/test_host_performance.sh
bash ./deploy/tests/vgpu/test_tsc_policy.sh
```

硬件目录测试只证明软件合同闭合；正式投产还应在具体宿主、BIOS、内存与 PCIe 转接
硬件上做实机带宽、稳定性、Windows 时钟告警和满载并发验收。
