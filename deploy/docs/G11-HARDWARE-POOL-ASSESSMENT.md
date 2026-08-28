# G-11 硬件池搭配合理性评估

> 评估日期：2026-08-19
> 评估对象：`deploy/lib/` 下的 G-11 硬件身份目录（CPU / 主板 / 内存 / SSD / GPU / 显示器 / 输入设备）
> 消费方：`/home/ubuntu/projects/vmate` 客户端（`VmBackend::G11` → `G11_LINUX_VGPU_BACKEND`）
> 宿主：JGINYUE X99-TI D4 PLUS + Xeon E5-2696 v4 + 62 GiB DDR4 + RTX 2080 16 GiB（vgpu_unlock）+ 单块 WD Blue SN570 1 TB
> 方法：目录静态审计（`check-hardware-pool.sh`）+ 宿主实机压测（mdev 创建实验）
> 性质：**初版评估 + 2026-08-20 仓库复核与整改记录**

> 2026-08-21 后续状态：正常新建池已经替换为 Core i7-4820K/i7-3820、三品牌
> X79、4/8/12/16G 与平台感知的 Gen3 NVMe 优先策略。本文的 H81/6G/264 条统计是
> 历史审计底稿，不再是操作口径；当前事实见
> [G11-HARDWARE-POOL.md](G11-HARDWARE-POOL.md)。
>
> 2026-08-27 后续状态：Core i7-4930K 6C/12T 已并入普通创建池，覆盖三品牌 X79、
> 每容量 4–5 个大牌内存；当前完整目录为 11/16/45/366，操作见
> [G11-6C12T-QUICKSTART.md](G11-6C12T-QUICKSTART.md)。后文旧统计仍只作历史底稿。

## 先读：2026-08-20 复核结论（优先于后文初版）

本报告的 **GPU 双显存档位冲突方向成立**，但初版把若干目录统计、推测和真实
故障混在了一起。我只部分赞成。后文保留为审计底稿；凡与本节冲突的结论、评分、
容量估算和整改建议均作废，不能再直接当执行清单。

### 赞成并已处理

| 问题 | 复核后的准确结论 | 仓库整改 |
|---|---|---|
| 同卡 1GB/2GB 混档 | vGPU 16 的同一物理 GPU 必须使用相同 framebuffer 大小；同容量的 A/B/Q type 可以不同，不能笼统写成“type 必须完全相同” | 新建和管理端 TSV 都先读 `VGPU_HOST_FB_TIER_MB`，`AUTO_RANDOM` 只标记当前档；已有单一档沿用，空池默认 2048MB；启动前复核；mdev 分配锁内扫描同 parent 的活动实例并拒绝异档或不可解析状态 |
| 新建 GPU/驱动世代 | 实际 guest 基线是正式签名 GRID **538.33 / R535**，不是文件历史误名 553.24；8 个 GT 730/740 Kepler 身份与该基线不自洽 | 2GB 默认层 12 条；1GB 新建层只保留 4 条 Maxwell GTX 750；8 条 Kepler 仅供旧 `vm.conf` 读取，不再新建/随机 |
| 跨组件 SSD 随机 | `create-vm.sh` 自己会先按平台过滤，不存在“随机命中 NVMe 后不重试”；但客户端若先从 `AUTO_RANDOM=1` 独立选 SSD，再显式传给默认 H81，确有跨组件拒绝风险 | 默认层只含 7 款 H81 可达 SATA；WD Black、970 Pro、960 Pro 三款 NVMe 都改为显式选择 |
| 宿主 profile 漂移 | 全局 `profile_override.toml` 基线漂移真实存在；当前活动 VM 的 per-mdev FHD 合同正确，不能声称它正在继承 4 屏旧值 | 提供只读 check、保留未知/mdev 段的语义合并和停机应用封装；不在本次提交中改宿主 `/etc` 或重启服务 |
| 未来 V100 | V100 也不能沿用 `1Q+2Q` 混档方案；官方卡应走原生 vGPU 驱动与原生身份，不需要 vgpu_unlock | 配置封装每张物理卡只生成 `V100*-1Q` 或 `V100*-2Q` 一个档；V100 路径关闭 identity override |

### 显存容量决定

按当前宿主“AMD 负责桌面输出、NVIDIA 整卡用于 vGPU”的用途，**不设置固定显存
预留**。`VGPU_TOTAL_FB_MB` 保持物理完整容量：16GB 为 16384MB，32GB 为
32768MB；不采纳初版的 15872MB 建议。容量检查同时使用 sysfs
`available_instances` 和同 parent framebuffer 求和。

`mdev create` 成功不等于 Windows 能用，因此 RTX 2080 的第 8 个 2GB 实例、
第 16 个 1GB 实例，以及未来 V100 的对应满槽实例，必须用真实 QEMU VFIO 打开、
Windows 设备管理器 Code 0、guest `nvidia-smi`、图形压力和无 Xid 长稳验收。若末槽
实测失败，记录该 host/SKU/profile 的“实测最大实例数”，不虚构一个通用 512MB
扣减值。[NVIDIA vGPU 16 的有效 time-sliced 配置要求同一物理 GPU 使用相同
framebuffer 大小](https://docs.nvidia.com/vgpu/16.0/grid-vgpu-user-guide/index.html)。

### 初版中不采纳或需纠正的项目

- “264 套中 91.3% 是 i3”只描述含 237 条 `explicit-new` 的完整手动目录，不是
  默认随机池。默认 24 条是 G3220=3、i3-4130=6、i5-4460=6、i5-4570=6、
  i5-4590=3；因此不按初版扩张 CPU 笛卡尔积。
- [ASUS H81M-K BIOS 3802（2024-01-23）](https://www.asus.com/uk/supportonly/h81m-k/helpdesk_bios/)
  是官方发布版本，不是异常值。
- Crucial MX100 的 logical=512、physical=4096 是 **512e**，不是 4Kn。
- `ivshmem` 仅在显式 legacy/RDP 路径出现，不是默认 PCI 暴露。
- “第 8 台大概率失败”“稳定体验只能 4–6 台”、CPU/IOPS 估算都没有完整启动
  压测证据，不作为硬编码容量。
- 不把 qemu-xhci/ICH9-AHCI 改成真实 Intel PCI ID。QEMU 行为模型并不等价于
  对应实体控制器，错误 ID 可能让 Windows 加载硬件专属 workaround；只有真实
  模型或物理直通才是有效修复。
- 单 NUMA 能减少远端内存问题，但不能“消除全部亲和性复杂度”。

后续章节中的 “R550/553.24”“同 type”“扣 host 余量”“V100 1Q+2Q 混用”以及
据此得出的 3/10 评分，均以本节为准纠正。

### 当前宿主落地状态（本次未改运行态）

2026-08-20 只读复查时，宿主仍有一个活动的 1024MB `nvidia-256` mdev；仓库本地
`deploy/host/vgpu-host.conf` 尚未生成。新的管理端 TSV 因而从现有 VM 合同推导为
1024MB，只把 4 条 Maxwell GTX 750 标成 `AUTO_RANDOM=1`，不会再选 Kepler 或
2GB 行。`profile_override` 的只读 check 同时确认全局 256 缺失、257 与模板漂移。

本次没有关闭 VM、删除 mdev、覆盖 `/etc` 或重启 vGPU 服务。两个应用封装都会在
活动 mdev 存在时拒绝写入。停机窗口中二选一：

```bash
# 继续沿用当前 1GB 整池（把 BDF 替换为 lspci -D 查到的 NVIDIA 地址）
./deploy/configure-g11-vgpu-host.sh \
  --preset rtx2080-16gb --tier 1024 --gpu 0000:BB:DD.F

# 或完成全部 1GB VM 的迁移规划后，把整池统一切到 2GB
./deploy/configure-g11-vgpu-host.sh \
  --preset rtx2080-16gb --tier 2048 --gpu 0000:BB:DD.F

# RTX 2080 unlock 路径随后合并全局 profile；真 V100 不运行这一条
sudo deploy/host/sync-vgpu-profile-override.sh --apply
sudo deploy/host/sync-vgpu-profile-override.sh --check
```

不能只改某一台 VM，也不能在仍有 1GB mdev 时用 `--force` 切到 2GB。

---

## 0. 初版总评（评分已由页首复核结论取代）

| 维度 | 初版评分/状态 | 复核后的判定 |
|------|------|-----------|
| 单台 VM 内部自洽性 | 初版 6.5 / 10 | 仓库校验能证明目录内部一致，不能替代所有外部型号规格核验；Kepler 已退出新建层，控制器属于已知模型边界 |
| 池内多样性（抗聚类） | 初版 4.0 / 10 | 91.3% 只适用于含 explicit-new 的完整手动目录，不能代表默认随机池 |
| 宿主资源匹配度 | 待压测 | 显存理论边界可计算，CPU、磁盘与满槽体验未完成启动压测 |
| 时代与市场真实性 | 初版 5.0 / 10 | 默认平台仍集中在 H81 + Haswell；这是目录范围，不等同于运行故障 |
| 架构边界 | 待产品决策 | xHCI/SATA/NIC/指针模型仍可识别；不能用虚假的真实硬件 ID 掩盖 |
| **成池运营可用性** | **阻断项已修** | 随机池受宿主单档约束；实际并发上限仍待 Windows 满槽压测 |

### 综合结论

初版目录偏重单 VM 身份细节，缺少宿主级 framebuffer 档位合同；本次已补上该合同。

单机维度包含丰富的内存、SSD、显示器和 GPU 元数据，仓库一致性校验覆盖较全；
外部产品规格仍应按具体型号引用官方来源，不能由内部校验推导为全部真实。

整改前把它当作**资源池**（一个宿主并发服务 N 个用户）时，有一个阻断项和两个
目录/身份问题：

1. **GPU 池的 1 GB / 2 GB 双档在单卡宿主上物理互斥**，而旧新建流程从两档混合池随机取卡；本次已修；
2. 完整手动目录的 264 套里 241 套是同一颗 CPU，但默认 24 条并不按该比例随机；
3. **8 / 25 条 Kepler GPU 身份与 guest 实际 GRID 538.33/R535 基线不自洽**。

---

## 1. 评估范围

### 1.1 纳入范围

`deploy/scripts/check-hardware-pool.sh` 审计的完整 G-11 目录：

```
summary cpu=8 board=13 chipset_presentation=4 memory=27 combination=264
        new_default=24 explicit_new=237 legacy=3
        ssd_512gb=10 optical=1 gpu_catalog=25 gpu_1gb=12 gpu_2gb=13
        monitor_catalog=35 monitor_new=28
brands  board=5 memory=5 ssd=5 gpu_board=9 keyboard=3 relative_mouse=3
        monitor_catalog=11 monitor_new=8
```

以及这些身份落到宿主上时的物理承载能力。

### 1.2 排除范围

- V-11 / P-11 后端（用户明确限定只评估 G-11）
- vmate 的商业逻辑（钱包、卡密、订单）
- guest 内 Windows 侧的软件伪装链（NVAPI shim、GPU-Z 封装）——只在与硬件池搭配直接冲突时提及

---

## 2. 宿主基线（实测数据）

| 资源 | 实测值 | 备注 |
|------|--------|------|
| CPU | Xeon E5-2696 v4，22C / 44T，2.2 GHz base / 3.7 GHz boost | Broadwell-EP，单路，**单 NUMA node** |
| L3 | 55 MiB（单实例） | 多 VM 共享，无 CAT 分区 |
| 内存 | 62 GiB 可用（4 × 16 GiB Hynix DDR4-2133，A1/B1/C1/D1 四通道） | X99 四通道插满 ✓ |
| GPU | RTX 2080（TU104），**魔改 16 GiB**，驱动 535.161.05（vGPU 16.x + unlock） | `nvidia-smi` 报 16384 MiB，空载占用 96 MiB |
| 存储 | **单块** WD Blue SN570 1 TB，**DRAM-less（依赖 HMB）** | `/` 183 G（用 17%），`/home` 687 G（用 54%，**剩 304 G**） |
| 主板 | JGINYUE X99-TI D4 PLUS，AMI BIOS 5.11（2024-09-19） | |
| 第二显卡 | AMD RX 580/570（Ellesmere，05:00.0） | 供宿主桌面输出，未参与 vGPU |

**单 NUMA node 是这台机器的优势**：它避免跨节点远端内存，但不能消除 vCPU、
中断和 I/O 线程亲和性规划。

---

## 3. 关键实测：vGPU 容量与档位互斥

以下是初版评估记录的实验快照，实验后当时已清理；本轮复核没有重做实验，也没有
改变当前运行态。当前已有 VM/mdev 的状态以页首“当前宿主落地状态”为准。

### 3.1 实验一：异构 profile 能否共存

```
初始 available：  nvidia-256(1Q)=24   nvidia-257(2Q)=12   nvidia-259(4Q)=6

创建 1 个 nvidia-256（1 GB）后：
  nvidia-256: 23        ← 只有本档位递减
  nvidia-257: 0         ← 立即归零
  nvidia-258: 0
  nvidia-259: 0
  nvidia-261: 0

强行创建 nvidia-257：
  sh: echo: I/O error
  dmesg: NVRM: Failed to add vgpu create request: 0x56
         vGPU creation failed on device 0x400. -5
         nvidia-vgpu-vfio: probe failed with error -12
```

**结论（确凿）**：在**当前宿主**上，同一物理 GPU 的所有 vGPU 实例必须使用
相同 framebuffer 大小；相同容量的不同 type 不应被误拒绝。

本项目固定在 R535 / vGPU 16.x；该分支的官方有效配置要求同一物理 GPU 上的
time-sliced vGPU 使用相同 framebuffer 大小。本机 sysfs 行为与该约束一致。
未来 V100 若继续使用本项目的 vGPU 16 栈，同样必须按单一档位配置；不把其他
驱动分支可能提供的 heterogeneous/mixed-size 能力当作本项目合同（见附录 C）。

### 3.2 实验二：2 GB 档真实上限

```
连续创建 nvidia-257：#1…#12 全部成功，第 13 个失败
每次创建后 nvidia-smi memory.used 恒为 96 MiB —— 显存在 VM 实际启动时才分配
```

**两个结论**：

1. `available_instances` 报 12 是**驱动按伪装的 RTX 6000 24 GiB 记账**的结果（24 ÷ 2 = 12），**不是物理真值**。物理 16 GiB 的 2GB 理论边界是 8 台，仍须真实启动第 8 台验收。
2. mdev "创建成功" ≠ "能启动"。容量失败会推迟到 VM 开机那一刻，报错点离用户操作很远。

代码保留 `VGPU_TOTAL_FB_MB=16384` 并做 framebuffer 求和是正确的。本机由 AMD
承担桌面输出，NVIDIA 整卡供 vGPU，按用户要求不扣固定余量。第 8 台是否能通过
VFIO open、Windows Code 0 和压力测试是待验收边界，不能先写成“大概率失败”。

---

## 4. 逐维度评估

### 4.1 CPU 池 —— 默认随机基本均衡，完整手动目录偏斜

| profile | QEMU model | 拓扑 | 宿主可实现性 | 新建可用 |
|---------|-----------|------|-------------|---------|
| g3220 | Intel-Pentium-G3220 | 2C/2T | supported | ✓ |
| i3-4130 | Core-i3-4130 | 2C/4T | supported | ✓ |
| i5-4460 / 4570 / 4590 | Core-i5-44xx/45xx | 4C/4T | supported | ✓ |
| i7-4790 | Core-i7-4790 | 4C/8T | supported | explicit-new |
| i5-6500 | Core-i5-6500 | 4C/4T | **compatibility** | ✗ |
| i3-8100 | Core-i3-8100 | 4C/4T | **compatibility** | ✗ |

**完整手动目录分布（264 套，包含 237 条 explicit-new）**：

```
i3-4130  241 套 (91.3%)
i5-4570    6 套
i5-4460    6 套
i5-4590    5 套
g3220      3 套
i7-4790    1 套
i5-6500    1 套（legacy-only）
i3-8100    1 套（legacy-only）
```

**判定**：

- 该分布不能代替默认随机权重。默认 24 条中 G3220=3、i3-4130=6、
  i5-4460=6、i5-4570=6、i5-4590=3；只有显式/UI 全目录等权抽样才会继承
  241/264 的偏斜。
- i5-6500 / i3-8100 无法新建，**根因是宿主 CPU 是 Broadwell-EP**。实测确认了精确的缺失特性：

  ```
  $ qemu-system-x86_64 -cpu Core-i5-6500,enforce=on ...
  warning: host doesn't support requested feature: CPUID[eax=07h,ecx=00h].EBX.clflushopt [bit 23]
  warning: host doesn't support requested feature: CPUID[eax=0Dh,ecx=01h].EAX.xsavec  [bit 1]
  warning: host doesn't support requested feature: CPUID[eax=0Dh,ecx=01h].EAX.xgetbv1 [bit 2]
  Host doesn't support requested features
  ```

  `clflushopt` / `xsavec` / `xgetbv1` 都是 Skylake 引入、Broadwell 没有的指令。这不是目录的错，是**硬件天花板**：这台宿主能诚实伪装的最高世代就是 Haswell/Broadwell。想要 Skylake 及以后的身份，必须换宿主 CPU。
- 只有在客户端把完整 `explicit-new` 目录等权随机时，2C/4T 的 i3-4130 才会占
  绝对多数；当前默认路径不能据此断言 CPU 侧一定成为体验瓶颈。

### 4.2 主板 / 芯片组池 —— ⚠️ 世代单一

13 块板中 **10 块是 H81**；另外 3 块（H97-D3H / B150M-D3H /
PRIME B360M-A）只出现在显式或兼容目录，不进入当前默认随机路径。

芯片组呈现覆盖 4 种（H81=8086:8C5C/04、H97=8086:8CC6/00、B150=8086:A148/31、B360=8086:A308/10），但**新建 VM 100% 落在 H81**。

主板元数据质量很高，逐条核对通过：

| 字段 | 值 | 核验 |
|------|-----|------|
| 内存槽数 | H81 = 2，H97/B150/B360 = 4 | ✓ 与真实规格一致 |
| 最大容量 | H81 = 16 GB，B150/B360 = 64 GB | ✓ |
| TPM | H81 = none，H97 = 1.2，B150/B360 = 2.0 | ✓ |
| NVMe PCIe | H81 = 0/0（不支持），B360 = gen3 ×4 | ✓ 并被存储守卫强制执行 |
| 内存类型 | H81/H97 = DDR3-1600，B150 = DDR4-2133，B360 = DDR4-2666 | ✓ |

**BIOS 版本/日期**基本可信；ASUS H81M-K 的 3802 / 2024-01-23 也能在 ASUS
官方支持页核对到，不列为异常。

**判定**：主板数据本身是这套池子里质量最高的部分；问题在**选取范围**——2026 年一个池子里所有机器都是 2013 年的 H81 入门板，这个人群画像本身就不自然。

### 4.3 内存池 —— ✓ 质量优秀，2 条非默认 DDR4 目录

27 套内存套装，5 个品牌（Kingston / Samsung / Micron / SK hynix / Crucial），DDR3-1333 与 DDR3-1600 双频段都有原生型号（不是拿 1600 改标速），JEDEC JEP-106 厂商码正确（Samsung=80CE、Micron/Crucial=802C、SK hynix=80AD、Kingston=0198），rank 与颗粒位宽随型号变化（`M378B5273DH0` 双 rank、`M378B5773DH0` 单 rank）——这一层做得非常扎实。

容量三档 4 / 6 / 8 GB，分布均匀（86 / 87 / 91）。6 GB 走 `flex`（4096+2048 单双通道混合），是 H81 时代真实存在的配法 ✓

**问题**：

- `kvr21n15s8-2x4`（DDR4-2133）和 `kvr24n17s8-2x4`（DDR4-2400）只能配
  B150/B360，因此不进入当前 H81 默认随机路径；它们属于显式/兼容目录，不应
  计入默认容量，也不必从完整 catalog 删除。
- **4 GB 档占 86 套（32.6%）**。Windows 10 LTSC + GRID 驱动 + 一个 3D 应用，4 GB 已经在临界线上，装完就剩几百 MB。作为"能开机"的身份没问题，作为"能用"的配置偏低。

### 4.4 SSD 池 —— 默认 7 款 SATA，显式 3 款 NVMe

10 款全部精确 512110190592 字节（476.9 GiB），型号字符串、固件版本、逻辑/物理扇区都对得上真实产品 ✓

| 接口 | 款数 | 新建可用性 |
|------|------|-----------|
| SATA AHCI | 7 | ✓ |
| NVMe M.2 | 3（WD Black PCIe / 970 PRO / 960 PRO） | 仅显式选择；H81 会由 `hardware_storage_combination_allowed` 拒绝 |

守卫逻辑本身是**正确且必要**的。`create-vm.sh` 会先按平台过滤，不存在“命中
NVMe 后拒绝且不重试”；跨组件风险来自管理端先独立选盘再显式传入。整改后 7 款
SATA 为默认层，3 款 NVMe 全部为显式层。

**Crucial MX100 是 logical=512、physical=4096 的 512e**，不是 4Kn。

### 4.5 GPU 池 —— 🔴 **本次评估的核心问题所在**

25 条身份，9 个板卡品牌（NVIDIA / ASUS / MSI / Gigabyte / ZOTAC / GALAX / Colorful / EVGA / Dell）。每条都带完整的 VBIOS 版本、核心/Boost/显存频率、位宽、带宽、CUDA 核心数、显存颗粒类型与厂商——这一层的数据密度是全池最高的。

按芯片架构展开：

| 型号 | 芯片 | 架构 | 条数 | 显存 | mdev type | GRID 538.33/R535 身份自洽 |
|------|------|------|------|------|-----------|----------------------|
| GT 730 (0x1287) | GK208B | **Kepler** | 4 | 1 GB | nvidia-256 | ❌ **停在 R470** |
| GT 740 (0x0FC8) | GK107 | **Kepler** | 4 | 1 GB | nvidia-256 | ❌ **停在 R470** |
| GTX 750 (0x1381) | GM107 | Maxwell | 4 | 1 GB | nvidia-256 | ✓ |
| GTX 750 Ti (0x1380) | GM107 | Maxwell | 5 | 2 GB | nvidia-257 | ✓ |
| GT 1030 (0x1D01) | GP108 | Pascal | 4 | 2 GB | nvidia-257 | ✓ |
| GTX 1050 (0x1C81) | GP107 | Pascal | 4 | 2 GB | nvidia-257 | ✓ |

#### P0-1（已修）：双档在单卡宿主上物理互斥

整改前的 `VGPU_DEFAULT_PROFILE_KEYS` 把 12 条 1GB 与 12 条 2GB 放在同一随机池，
管理端也把两档都标成 `AUTO_RANDOM=1`。结合 §3.1，这会让两类新建 VM 无法
同时运行。

结合 §3.1 的实测：

> 整改前批量创建 N 台 VM，期望约一半落 1GB、一半落 2GB。先启动的档位会让
> 另一档 `available_instances` 归零，后来者直到开机才失败。

这是整改前的阻断性缺陷。当前策略把 2GB 默认 12 条、1GB Maxwell 4 条拆成两个
宿主档，并让 TSV、建号、启动与锁内分配执行同一合同。

`mdev_active_framebuffer_mb` 继续负责完整物理容量求和；在它之前，分配器已在同一
锁内逐个解析同 parent 的活动 mdev，并拒绝不同或不可解析的 framebuffer 档。
因此容量求和不再被当成混档许可。

#### 🔴 P0-2：8 条 Kepler 身份与实装驱动版本不可能共存

guest 实际装的是正式签名 **GRID 538.33（R535）**；staging 的 553.24 只是历史
误名。Kepler 的 Windows 主线停在 R470，因此将 GT 730/740 marketing identity 与
R535 版本并列仍不自洽。

也就是说：一台在用户态声称 `NVIDIA GeForce GT 740`、同时报告 538.33/R535 的
机器会暴露型号×版本矛盾；系统 PnP transport 实际仍是原生 vGPU endpoint。

**受影响的正是 1 GB 档的 2/3**（GT 730 ×4 + GT 740 ×4）。1 GB 档 12 条里只有 4 条 GTX 750（Maxwell）是版本自洽的。**当前 vm8 用的就是 `gt740_1gb`。**

Maxwell 与 Pascal 行保留在当前生产基线；新建 1GB 层只使用 4 条 Maxwell GTX 750。

#### ⚠️ P1：`available_instances` 是 24 GiB 假数

驱动按伪装的 RTX 6000 记账，1GB 档报 24、2GB 档报 12。16 GiB 物理显存的
理论边界是 16×1GB 或 8×2GB；完整物理容量继续作为上限，末槽必须实机验收。

#### ⚠️ P1：`/etc/vgpu_unlock/profile_override.toml` 与仓库版本漂移

| 项 | 仓库 `deploy/host/profile_override.toml` | 宿主生效版本 |
|----|----------------------------------------|-------------|
| `[profile.nvidia-256]` | 存在（1 屏 / 1920×1080） | **缺失** |
| `[profile.nvidia-257]` | 1 屏 / 1920×1080 / max_pixels=2073600 | **4 屏 / 1920×1200 / max_pixels=9216000**（旧值） |

全局基线确有漂移，但当前活动 VM 的 per-mdev 段已经写入单头 FHD 合同，不能声称
它正在继承 4 屏旧值。风险在旧的无 FHD mdev 段和 identity backend 不可用路径。
原 `sync-vgpu-profile.sh` 是 guest registry wrapper，不会修改宿主 TOML；本次新增
独立宿主语义合并工具。

per-mdev 段的质量则很好——`rm_fb_bus_width=128`、`rm_fb_ram_type=8`(GDDR5)、`rm_fb_memory_vendor=1`(Samsung) 与 catalog 逐字段对齐 ✓

#### ✓ 做得对的地方

- **显存档位与 mdev framebuffer 严格绑定**（1 GB → nvidia-256，2 GB → nvidia-257），`vgpu_profile_pick_random_vram` 的注释明确写了"绝不能先选卡再改 `GPU_VRAM_MB`"——这个约束意识是对的。
- 2 GB 档的 `framebuffer = 1856 MiB + reservation = 192 MiB` 处理正确，注释里"写成 2048+256 会让 GPU-Z 误报 2304 MB"说明踩过坑并修好了。
- 品牌与型号的对应关系真实（ASUS GT730-1GD5-BRK 确实是 GK208/GDDR5/64-bit，注释里还专门警告不要与 GF108 128-bit 或 DDR3 版本混淆）。
- Colorful 的 PCI-SIG subsystem vendor 0x7377 正确。

### 4.6 显示器池 —— ✓ 全池质量最高的一环

35 款 catalog / 28 款新建池，11 个品牌（新建池 8 个）：Samsung / Dell / BenQ / AOC / HKC / Redmi / Philips / Lenovo / ASUS / Acer / ViewSonic。

全部 1920×1080 @ 60 Hz，尺寸覆盖 21.5" / 23.8" / 24" / 27"，物理尺寸（mm）随尺寸正确变化（476×268 / 527×296 / 598×336 …），EDID 时序参数（H/V 频率范围、最大点时钟）齐备。

**判定：完全合理。**FHD 60 Hz 与 1–2 GB 显存的入门卡是自洽的搭配；品牌构成贴合中国大陆装机市场（HKC、Redmi 这类本地品牌的存在提升了可信度）。这一维度没有发现问题。

唯一可提的：全池 100% 是 60 Hz FHD，没有任何 75 Hz 型号——而 AOC/HKC 这个价位段 75 Hz 相当普遍。属于可选的多样性增强，不是缺陷。

### 4.7 输入设备池 —— 🔴 默认路径暴露 QEMU

| 类别 | 款数 | 内容 |
|------|------|------|
| 键盘 | 3 | Microsoft Wired 600 (045E:0750) / Logitech K120 r64 (046D:C31C) / Dell SK-8115 (413C:2003) |
| 相对鼠标 | 3 | MS Basic Optical v2 (045E:00CB) / Logitech M105 r72 (046D:C077) / Dell MS116 (413C:301A) |
| 绝对指针 | **1** | **`qemu-generic-usb-tablet` — VID 0x0627 / PID 0x0001 / 厂商串 "QEMU" / 产品串 "QEMU USB Tablet"** |

键鼠的 VID/PID/bcdDevice 都是真实值 ✓ 但：

**`POINTER_MODE=absolute` 是默认**（vm8 即为此配置），意味着默认每台 VM 都挂着一个自报家门叫 "QEMU USB Tablet" 的 USB 设备。任何枚举 USB 设备树的程序——一行 WMI 查询就够——立刻拿到 VM 判定。

目录注释把它记为"honest generic QEMU tablet"，相对鼠标模式因为需要 viewer 指针捕获而设为 opt-in。这个取舍在**人工交互便利性**上说得通，在**反检测**上是把最大的破绽放在了默认路径。一台配着 Dell SK-8115 键盘、却接着 "QEMU USB Tablet" 的机器，搭配本身就不成立。

### 4.8 网卡 / 控制器 / 总线身份 —— ⚠️ 结构性泄漏

`check-hardware-pool.sh` 自己声明的边界（值得肯定的坦诚）：

```
fixed_exceptions        cpu=Intel-H81-platform nic=Intel-e1000e audio=Intel-HDA
                        absolute_pointer=QEMU-generic tpm=swtpm ...
architecture_boundaries machine=q35-ICH9-behavior sata=ICH9-AHCI xhci=qemu-xhci
                        nvme=QEMU-nvme rescue_display=std-vga legacy_transport=ivshmem
```

落到 guest PCI 拓扑上：

| 设备 | guest 看到 | 真实 ASUS H81M-K 应该是 | 判定 |
|------|-----------|------------------------|------|
| LPC | 8086:8C5C rev 04（H81） | 8086:8C5C | ✓ 已 spoof，自洽 |
| GPU root port | Intel（`x-pci-vendor-id=0x8086`） | Intel PEG | ✓ |
| SATA AHCI | **8086:2922（ICH9）** | 8086:8C82 / 8C80（Lynx Point） | ❌ 跨代不符 |
| USB 3.0 | **1B36:000D，SUBSYS 1AF4:1100** | 8086:8C31（Lynx Point xHCI） | ❌❌ **1AF4 = Red Hat/Virtio，教科书级 VM 指纹** |
| 网卡 | 8086:10D3（82574L），subsys 8086:A01F | Realtek RTL8111G（10EC:8168） | ⚠️ 板载网卡型号不符 |
| 音频 | Intel HDA（QEMU 通用） | 8086:8C20（Lynx Point HDA） | ⚠️ |
| ivshmem | 仅显式 legacy/RDP 路径 | 默认 native 路径不存在 | 已知兼容边界，不是默认暴露 |

`vm.conf` 里记录了正确的 `XHCI_PCI_DEVICE_ID=0x8C31`，但 `start-vm.sh:4581` 明确打印"行为身份固定；目标平台 8086:8C31 仅作事实校验"——即**知道正确值是什么，但选择不投射**。这是稳定性优先的工程决策（xHCI PCI ID 覆盖会影响驱动绑定），代价是把一个高价值指纹留在了台面上。

**其中 SUBSYS 1AF4:1100 是最严重的一条**：1AF4 是 Red Hat 为 virtio 申请的 vendor ID，在物理硬件上不可能出现。

---

## 5. 交叉搭配矩阵

以 vm8（当前唯一实例，`PLATFORM=i3-4130-h81m-k-samsung-4g`）为样本逐对检验：

| 组合 | 判定 | 说明 |
|------|------|------|
| i3-4130 ↔ H81M-K | ✓ | LGA1150 + H81，2013 年主流入门搭配 |
| H81M-K ↔ 2×2 GB DDR3-1600 Samsung | ✓ | 2 槽插满，1600 是 H81 上限 |
| H81M-K ↔ Kingston KC400 512 GB SATA | ✓ | SATA 6 Gb/s 2.5" |
| H81M-K ↔ NVMe SSD | — | 已被守卫正确阻断 |
| i3-4130 (2C/4T) ↔ GT 740 | ✓ | 时代吻合，性能档位匹配 |
| GT 740 1 GB ↔ nvidia-256 (1Q, 1024 MB) | ✓ | 显存严格对齐 |
| **GT 740 (Kepler) ↔ GRID 538.33 (R535)** | ❌ | **用户态型号与版本不自洽** |
| GT 740 ↔ Dell P2719H FHD 60 Hz | ✓ | 1 GB 卡带 FHD 单屏合理 |
| H81（2013）↔ P2719H（2019 产） | ✓ | 老主机换新显示器，常见 |
| 4 GB 内存 ↔ Win10 LTSC + GRID 驱动 | ⚠️ | 能跑，余量极小 |
| Dell SK-8115 键盘 ↔ **QEMU USB Tablet** | ❌ | 真实用户不会有这个组合 |
| ASUS H81M-K ↔ Intel 82574L 网卡 | ⚠️ | 板载应是 Realtek 8111G |
| H81 平台 ↔ ICH9 AHCI + Red Hat xHCI | ❌ | 跨代 + 虚拟化厂商 ID |
| 1 GB 档 VM ↔ 同宿主的 2 GB 档 VM | ❌ | **物理互斥，实测确认** |

**自洽性小结**：SMBIOS 层（DMI：主板、内存、SSD、显示器、CPU）做到了高度自洽；**PCI 层和驱动版本层没有跟上**，这两层恰好是自动化检测最容易采集的层。

---

## 6. 问题清单

### P0 — 阻断运营，必须解决

| # | 问题 | 证据 | 影响 |
|---|------|------|------|
| **P0-1** | GPU 1GB/2GB 双档在单卡宿主互斥，旧新建/管理目录未受宿主档位约束 | §3.1 实测 | 已按宿主单档、动态 TSV、创建/启动/锁内三层门禁修复 |
| **P0-2** | 8 条 Kepler GPU marketing identity 与 guest 实际 538.33/R535 版本不自洽 | NVIDIA Kepler 最后 Windows 主线 = R470 | 已移到 legacy-only；不再新建/随机 |

### P1 — 显著削弱效果

| # | 问题 | 证据 | 影响 |
|---|------|------|------|
| P1-1 | 完整手动目录中 241/264 是 i3-4130 | §4.1 分布统计 | 不代表默认 24 条随机权重，降为目录/UI 信息项 |
| P1-2 | USB 3.0 控制器 SUBSYS = 1AF4:1100（Red Hat virtio） | `start-vm.sh:4581` | 一次 PCI 枚举即暴露虚拟化 |
| P1-3 | 默认 `POINTER_MODE=absolute` 挂 "QEMU USB Tablet" (0627:0001) | `input-profiles.sh` 绝对指针池仅 1 款 | 一次 USB 枚举即暴露 |
| P1-4 | `/etc/vgpu_unlock/profile_override.toml` 全局 256/257 基线漂移 | 宿主实读 | per-mdev 可兜底当前 VM；仍需停机语义合并以便审计 |
| P1-5 | SATA 控制器仍是 ICH9（8086:2922），与 H81 跨代 | `architecture_boundaries sata=ICH9-AHCI` | 芯片组交叉校验不过 |
| P1-6 | 初版建议固定扣 host 显存 | 无末槽启动证据 | **不采纳**；保留 16384，末槽实机验收 |
| P1-7 | 单块 DRAM-less SN570 承载全部 VM 存储 | `lsblk` / `df` | 多 VM 并发 O_DIRECT 随机写会严重掉速；单点故障 |

### P2 — 应清理或补齐

| # | 问题 | 影响 |
|---|------|------|
| P2-1 | 3 块非 H81 主板 + 2 套 DDR4 内存 + 3 款 NVMe SSD + 2 款 CPU 不在当前默认路径 | 属于显式/兼容目录，应在 API/UI 标明 lifecycle，不应误称默认库存 |
| P2-2 | 新建池 100% H81 + Haswell（2013–2015），无任何世代梯度 | 人群画像不自然 |
| P2-3 | 4 GB 内存档占 32.6%，实际体验吃紧 | 用户投诉来源 |
| P2-4 | 网卡固定 Intel e1000e，与 ASUS/Gigabyte/MSI H81 板载 Realtek 不符 | 板卡交叉校验不过 |
| P2-5 | `asus-h81m-k` BIOS 3802 / 2024-01-23 | 已由 ASUS 官方支持页确认，删除问题项 |
| P2-6 | 显示器池无 75 Hz 型号 | 多样性可增强（非缺陷） |

---

## 7. 容量模型：这台宿主到底能同时开几台

按每台 4 vCPU / 4 GB 内存 / 2 GB vGPU / 约 35 GB 磁盘实占估算：

| 约束线 | 计算 | 上限 |
|--------|------|------|
| **vGPU 显存**（2 GB 档） | 16384 MiB ÷ 2048，不扣固定余量 | **理论 8 台，须验第 8 台** |
| vGPU 显存（1 GB 档） | 16384 MiB ÷ 1024，不扣固定余量 | 理论 16 台，须验第 16 台 |
| **内存** | (62 − 10 host) GiB ÷ Guest 完整上限；默认 `prealloc=on`，按需模式仍须按最坏工作集核算 | **13 台**（4 GB 档）/ 6 台（8 GB 档） |
| **CPU 线程** | 44 线程，实际每 VM 调度与负载未知 | 待并发压测 |
| **磁盘容量** | 304 GiB ÷ 35 GiB | **8 台**（不含游戏数据） |
| 磁盘 IOPS | 单块 DRAM-less TLC，多 VM 并发 O_DIRECT 随机写 | 风险存在，缺少 IOPS/体验压测 |

**收敛结论**：

- **2GB 档：显存理论 8 台**，生产数以第 8 台完整启动/长稳为准。
- **1GB 档：显存理论 16 台**，但 CPU、内存、磁盘很可能先成为约束，仍需压测。
- 不能从当前静态数据声称“体验线 4–6 台”。

22C/44T + 62GB + 16GB 显存 + 单 SSD 的配比是否在 7–8 台收敛，需要真实业务
并发压测；单块 SSD 仍是性能与单点故障风险。

运营前提是同一物理 GPU 上的所有活动 VM 都属于同一 framebuffer 档；本次整改已
把该前提提升为宿主级合同，不再让随机建号产生跨档 VM。

---

## 8. 与 vmate 商业分发的匹配度

vmate 是带钱包、卡密、订单、设备绑定的商业平台，`client/src/hardware_randomization.rs` 会在建号时对 G-11 目录做随机化，并支持按维度加锁（`gpu_vram` / `gpu_model` / `gpu_brand` / `memory_*` 等）。

**匹配良好的部分**：

- 身份目录仍有充分组合空间：平台完整目录 264、SSD 默认 7、显示器新建 28；GPU
  自动池按宿主档位为 2GB 12 条或 1GB 4 条。唯一性检查覆盖 VM/主板/机箱/内存/
  SSD/显示器序列号；不再用整改前的“24 条 GPU 自动池”计算组合数。
- 分维度锁的设计合理，允许"换卡但保持容量档位"这类真实运维需求。
- `vm.conf` 只读 + `--force` 才能换指纹，与 Windows 激活/license 绑定的耦合关系处理得当。

**本次补齐的边界**：

1. 管理目录 TSV 的 `AUTO_RANDOM` 现在只标记宿主当前 framebuffer 档；客户端即使
   独立随机，也不会再跨档建号。
2. `create-vm.sh` 在建号时拒绝显式异档，`start-vm.sh` 在启动时复核，mdev 分配器
   在同一 parent 的锁内再检查活动实例，覆盖旧 VM、手工修改和并发竞态。
3. 默认 CPU 随机只使用 24 条 `new` 目录；完整 264 条手动目录的 i3 偏斜应由
   lifecycle 字段向 UI 明示，不能套用为默认随机概率。

---

## 9. 整改状态与后续边界

### 已完成（仓库侧）

1. 宿主配置新增单值 `VGPU_HOST_FB_TIER_MB=1024|2048`；空池默认 2048，已有
   单档池可安全推导，混档或信息不完整时 fail-closed；配置文件必须是可读普通
   非符号链接文件，坏配置不能静默回退。
2. 管理端目录、建号、启动和 mdev 锁内分配四层使用同一档位合同；同容量的不同
   A/B/Q type 仍可共存。分配前预写恢复记录；create 后的中断/API/解锁失败只回滚
   本次新 UUID，不误删旧对象。
3. 8 条 Kepler 身份移入 legacy-only；1GB 新建层只含 4 条 Maxwell，2GB 默认层
   含 12 条 Maxwell/Pascal，另有 1 条 2GB 显式条目。
4. SSD 默认层只含 7 款 H81 可达 SATA；3 款 NVMe 保留为显式目录。
5. 新增安全的 profile override `--check/--apply` 语义合并器；只管理 256/257
   全局段，保留全部未知 profile 和 per-mdev 段，并在活动 mdev 存在时拒绝应用。
6. 新增 RTX 2080/V100 宿主配置封装和傻瓜教程；保持物理完整显存，不写凭据，
   不安装驱动，不修改 BCD，也不管理或重启服务；已初始化宿主从活动检查到发布
   全程使用与 mdev 分配相同的全局锁。

### 明确不做

- 不为通用 qemu-xhci、ICH9-AHCI 或 USB Tablet 套真实硬件 ID；身份与行为不匹配
  可能触发 Windows 错误驱动/workaround。相对鼠标可作为运营选项，但不能给通用
  tablet 冒用真实绘图板 VID/PID。
- 不因完整手动目录统计而扩张 CPU 笛卡尔积；先由客户端/API 正确区分
  `new`、`explicit-new` 与 `legacy`。
- 不把物理 16GB 改写成 15872MB；末槽失败时记录实测实例上限。

### 仍需硬件/运营完成

- 停机窗口生成并安装本机 `vgpu-host.conf`，再对 RTX 2080 unlock 的全局 profile
  做语义合并；当前有活动 mdev，封装会拒绝写入。
- 对 1GB 第 16 台或 2GB 第 8 台做真实 Windows 满槽长稳验收。
- 单块 SN570 的并发 I/O 与单点风险只能靠真实业务压测和增加独立 VM SSD 解决，
  不能用代码或目录伪装成已修复。

---

## 10. 一页纸总结

**做得好的**：内存 SPD 与 JEDEC 厂商码、SSD 字节级容量与固件、显示器 EDID 与物理尺寸、GPU 的 VBIOS/位宽/颗粒厂商、主板槽位与容量上限、身份唯一性检查、H81↔NVMe 的存储守卫、显存与 mdev framebuffer 的严格绑定。这些是同类项目里少见的严谨度。

**已修的阻断项**：GPU 随机池已受宿主单档约束，异档在建号、启动和锁内分配
阶段都会被拒绝；Kepler 不再进入新建/随机。

**没有伪装修复的边界**：H81 平台世代单一，以及 qemu-xhci、ICH9-AHCI、Intel
e1000e、QEMU Tablet 的行为模型边界仍然可见。错误投射 PCI/USB ID 不算修复。

**宿主承载**：2GB 理论 8 台、1GB 理论 16 台；不设固定显存预留，生产上限必须
由满槽 Windows Code 0、负载和长稳测试确定。CPU 与单块 DRAM-less SSD 是否先
成为瓶颈也仍需并发压测。

---

## 附录 A：实测记录

```
# 实验一：异构 profile 互斥
初始:  nvidia-256=24  nvidia-257=12  nvidia-259=6
创建 1×nvidia-256 后:
       nvidia-256=23  nvidia-257=0   nvidia-258=0  nvidia-259=0  nvidia-261=0
创建 nvidia-257 → I/O error
dmesg: NVRM: Failed to add vgpu create request: 0x56
       [nvidia-vgpu-vfio] vGPU creation failed on device 0x400. -5
       nvidia-vgpu-vfio: probe failed with error -12

# 实验二：2 GB 档上限
#1..#12 创建成功，#13 失败
每次创建后 nvidia-smi memory.used 恒为 96 MiB（显存在 VM 启动时才分配）

# 清理
剩余 mdev = 0
available_instances 恢复初始值 (256=24 / 257=12)，nvidia-smi memory.used = 96 MiB

# 实验三：Skylake CPU model 在本宿主的可实现性
$ qemu-system-x86_64 -machine q35,accel=kvm -cpu Core-i5-6500,enforce=on
warning: host doesn't support requested feature: CPUID[eax=07h,ecx=00h].EBX.clflushopt [bit 23]
warning: host doesn't support requested feature: CPUID[eax=0Dh,ecx=01h].EAX.xsavec  [bit 1]
warning: host doesn't support requested feature: CPUID[eax=0Dh,ecx=01h].EAX.xgetbv1 [bit 2]
Host doesn't support requested features
```

> 这是初版实验结束时的历史状态：测试 mdev 当时已逐个 remove。它不表示
> 2026-08-20 当前 `/sys/bus/mdev/devices/` 为空；本轮只读复查确认已有 VM8 mdev
> 正在活动，因此没有执行任何宿主配置应用。

## 附录 B：审计原始输出

```
G-11 硬件池
  CPU: 8（新建可用 6 款；旧代兼容 2 款）
  主板: 13；芯片组 identity: 4；内存套装: 27；合法整机组合: 264
       （默认 24 / 显式新建 237 / 旧兼容 3）
  SSD: 10 款精确 512GB；可选光驱: 1 款；GPU: 25 条（1GB 12 / 2GB 13）
  显示器: 35 catalog / 28 新建池
  品牌: 主板 5 / 内存 5 / SSD 5 / GPU 板卡 9 / 键盘 3 / 相对鼠标 3
  显示器: 新建 8 品牌 / 完整 11 品牌
selection new_ready=24 explicit_ready=237 fallback_ready=3 result=new-ready

vCPU 拓扑分布: 2C/2T ×3, 2C/4T ×241, 4C/4T ×19, 4C/8T ×1
内存容量分布: 4096MiB ×86, 6144MiB ×87, 8192MiB ×91
主板分布: 10 块 H81 各 24–29 套, H97/B150/B360 各 1 套
```

---

## 附录 C：本项目的 V100 合同

> 补充于 2026-08-20，回答“Tesla V100 能否 1GB/2GB 混搭”。

### C.1 framebuffer 规则

本项目使用 R535 / vGPU 16.x。NVIDIA vGPU 16 的有效 time-sliced 配置允许在同一
物理 GPU 上混用相同 framebuffer 大小的不同 A/B/Q series，但不允许混用不同
framebuffer 大小。因此守卫比较的是解析出的 framebuffer MB，不是 type 名称：

- `V100-2Q` 与同为 2048MB 的其他 series 可以通过同档检查；
- `V100-1Q` 与 `V100-2Q` 不能在同一物理 GPU 上同时活动；
- type 描述、framebuffer 或 parent 无法可靠解析时 fail-closed。

这条规则同时适用于当前 RTX 2080 unlock 路径和未来 V100 官方路径。即使其他
硬件/驱动组合存在 mixed-size 能力，也不自动扩大本项目已经验证的合同。

### C.2 容量与 profile

每张物理 V100 只配置一个档，默认 2048MB：

| SKU | 默认 profile | 完整显存 | 2GB 理论槽位 |
|---|---|---:|---:|
| V100 PCIe 16GB | `V100-2Q` | 16384MB | 8 |
| V100 32GB / V100S 32GB | 按 sysfs 实际名称解析对应 2Q | 32768MB | 16 |

不扣固定 512MB 预留。第 8/16 个实例必须完成 QEMU VFIO open、Windows Code 0、
guest 驱动/许可、负载与长稳测试；`mdev create` 成功本身不算容量验收。

### C.3 与 RTX 2080 路径隔离

V100 是官方 vGPU 路径，配置 `VGPU_MDEV_IDENTITY_MODE=off`，使用原生 V100 vGPU
身份验收；不安装或加载 vgpu_unlock，不创建 `profile_override.toml`，也不复用
钉死 RTX 2080 BDF/驱动包的恢复脚本。严格遵守本仓库约束：不开
`testsigning`/`nointegritychecks`，不修改 BCD，不安装测试签名或自签名内核驱动。

买卡后仍须确认精确 SKU（PCIe/FHHL 与 SXM2 不能混为一谈）、BDF、供电、被动
散热风道、IOMMU 分组、官方 host/guest bundle 和许可证。宿主凭据与许可材料必须
放在仓库外的 root-owned 配置或通过环境变量/安全渠道提供。

完整封装与验收步骤见 `G11-VGPU-HOST-QUICKSTART.md` 和 `V100-ADAPTATION.md`。
