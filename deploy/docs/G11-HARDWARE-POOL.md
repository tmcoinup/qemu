# G-11 vGPU 硬件池与合法性门禁：傻瓜教程

本页只适用于 **G-11/vGPU**。V-11 是独立分支；不要把 V-11 的显卡、显示驱动
或平台策略整包复制到 G-11。G-11 的系统 PCI 设备仍遵守宿主 mdev 与正式生产
驱动的合同。

## 先看结论

| 类别 | active / 完整目录 | 新建规则 |
|---|---:|---|
| CPU | 6 / 8 | 平台绑定 Intel；5 款进入默认低端池，i7-4790 通常显式选择；另 2 款只作 legacy |
| 主板 | 4 / 7 | 3 品牌：ASUS、Gigabyte、MSI；active 全是 H81、双内存槽 |
| 内存 | 15 / 17 | 4 品牌：Kingston、Samsung、Micron、SK hynix；active 全为双条 DDR3 |
| 审核整机组合 | 25 / 28 | 默认 24 套、显式 i7 1 套、legacy 3 套 |
| SSD | 9 / 9 | 5 品牌：Samsung、Crucial、Kingston、Intel、WD；每款精确 `512110190592` 字节 |
| GPU | 12 / 12 | 3 个 NVIDIA 目标型号；原子 app-local profile 的板卡 metadata 覆盖 NVIDIA、ASUS、Dell、MSI、Gigabyte、GALAX、Colorful（七彩虹），显存厂家覆盖 Samsung、SK hynix、Micron；全部 2048 MB |
| 显示器 | 28 / 35 | 新建 8 品牌/完整 11 品牌；35 款全部为 1920×1080@60，是超过 5 品牌的明确例外 |
| 键盘 | 3 / 8 | active 为 Microsoft、Logitech、Dell；旧 A4Tech/Rapoo 等 5 行只在 compatibility/quarantine |
| 相对鼠标 | 3 / 8 | Microsoft、Logitech、Dell；只在创建时显式 `--relative-mouse` 才挂载 |
| 绝对指针 | 1 / 5 | 默认仅 QEMU 通用绝对指针；这是行为真实性例外，不冒充数位板 |

日常不指定硬件时，只从 24 套低端默认组合中选。i7-4790 不参加正常随机，通常
必须显式指定；唯一例外是 5 款默认 CPU 没有任何一款通过 `enforce=on`、而 i7
得到明确 `supported` 结果时，创建器会先使用这套双槽 H81/i7 active 平台。只有
连 i7 在内的 6 款 active CPU 都得到明确的非 supported 结果，无参数创建才会从
能启动的 legacy 平台中兜底。如果仍有 active 探测结果不确定且 i7 也未明确通过，
创建器不会偷换旧平台，而是保留 active 选择，让启动门禁 fail-closed。

### 七彩虹 profile 审核依据

七彩虹条目不是只改原条目的品牌名称：PCI-SIG 的会员目录把 `0x7377` 分配给
[Shenzhen Colorful Yugong](https://pcisig.com/membership/member-companies?combine=&order=field_name&page=5&sort=asc)，
七彩虹官网存在
[GTX 1050 2 GB 产品](https://www.colorful.cn/home/product?id=1516&mid=102)，而
[Colorful GTX 1050 GAMING V5 数据页](https://www.techpowerup.com/gpu-specs/colorful-gtx-1050-gaming-v5.b6025)
给出 GP107-300-A1、2 GB GDDR5、128-bit、640 CUDA、1354/1455/1752 MHz。
目录中的 `7377:0000` 与 `86.07.39.80.02` 来自对应的
[VBIOS 记录](https://www.techpowerup.com/vgabios/248844/248844)；该页明确标为用户上传、
未经 TechPowerUp 验证，因此只作为本项目 B 模式受保护用户态目录的原子 metadata，
绝不用于刷写 VBIOS，也不据此改系统 PCI、驱动或 BCD。

## 品牌覆盖的正确口径

品牌数量只对可替换的消费硬件成立。主板、内存、SSD、键盘和可选相对鼠标
覆盖 3–5 个常见品牌；GPU 的 app-local 板卡 subsystem 目录扩展为 7 个品牌。显示器
为了保留已要求的 35 款 FHD 型号，明确例外为 8 个新建品牌、11 个完整目录
品牌；新建品牌是 Samsung、Dell、BenQ、AOC、Philips、Lenovo、ASUS、Redmi，
完整目录另含 Acer、HKC、ViewSonic。

下列设备不能为了凑数量随便换厂商：

- CPU 和芯片组是 Intel H81/LGA1150 平台合同；不能将 Intel host 冒充成 AMD。
- G-11 正式 vGPU 驱动绑定 NVIDIA mdev；“品牌”在这里指板卡 subsystem，不是换成
  AMD/Intel GPU。B 模式的系统 PCI 身份仍保持宿主 mdev。
- NIC 是 Intel e1000e，唯一硬件身份是 Intel OUI 的 MAC；不存在另一个 NIC 序列号。
- 音频是 Intel HDA 控制器、TPM 是 stateful swtpm，不能只改 VID/厂商字符串就宣称
  另一品牌。
- machine 固定为 QEMU `q35`，底层芯片组/板载 SATA 是 ICH9/ICH9-AHCI；H81、H97、
  B150、B360 profile 约束 SMBIOS、SPD、拓扑和合法组合，不把 QEMU PCH 变成对应
  物理芯片组。
- USB 控制器固定为 `qemu-xhci` 的虚拟寄存器模型和安全身份；主板 profile 中的
  Intel xHCI 字段只作事实/放置校验，不投影为另一块物理控制器。
- NVMe 型号、容量、固件、序列及经审核的 PCI metadata 可以按 SSD profile 固定，
  但实际控制器仍由 QEMU `nvme` 实现，不能据此宣称完整复刻 Samsung/Intel/WD
  控制器行为。
- 安装和救援使用的 `std-vga` 是临时显示设备，不计入 3 个目标型号/12 条 2 GB
  GPU 原子 profile；正常
  B/native 启动不侧挂它。
- `ivshmem` 只是 `--legacy-shmem` 的旧 guest relay 传输通道，不是默认硬件，也不
  计作另一个设备品牌；其中保留的 PCI metadata 只能作旧兼容合同理解。
- `usb-tablet` 只实现单接口通用绝对坐标 report。真 HUION/VEIKK/XP-Pen 还有复合
  接口、压力/倾角协议；因此新建池诚实使用 QEMU `0627:0001`。
- 默认安装期 UEFI helper、Windows ISO/应答 ISO 是 QEMU 通用临时设备，正常启动
  全部不挂载；Windows ISO 默认走 xHCI USB BOT，IDE 仅作显式回退。启动器不传
  `model=`/`serial=`，并清除环境或 `vm.conf` 中的旧 `ODD_MODEL`/`ODD_SERIAL`，
  因而它不计入持久整机品牌池，也不冒充未审核的实体光驱。

## 序列号与唯一性合同

| 设备 | 策略 |
|---|---|
| v3 system/baseboard/chassis 标签 | 延续 ASUS/MSI/Gigabyte 主板语法；同 VM 三个值不重复，所有权边界见下文 |
| 内存 | 4-byte JEDEC 序列；每槽稳定派生且不重复 |
| SSD | 9 个 exact model 各自的严格格式，同时进入 ATA/NVMe Identify |
| 显示器 | Samsung S24F350/Redmi RMMNT238NF 使用型号专属格式；其他型号是明示的 `generic-prefix-hash` |
| GPU 板卡 | `not-exposed`；V-11 目录也明确不暴露，不用 mdev UUID 冒充板卡序列 |
| USB 键鼠/指针 | `none`，descriptor `iSerialNumber=0`；启动参数永不加 `serial=` |
| NIC | 使用 Intel 全局单播 MAC，拒绝本地管理/多播位、非 Intel OUI、`000000`/`FFFFFF` 后缀 |
| 安装/应答临时光驱 | `none`；QEMU generic transient ODD，不传 `model=` 或 `serial=` |

创建器持有 fleet identity 全局锁，在发布 `vm.conf` 前不执行地解析其他数字 VM
目录，检查 UUID、MAC、SYS/MB/CHASSIS 共享序列命名空间、内存、SSD和显示器
序列。撞号会自动重抽，畸形配置或符号链接会 fail-closed。启动器会再复核一次。

> 边界：现有 hardware contract v3 延续了 SYS/MB/CHASSIS 三个值共用主板厂商语法的
> 旧关系。其中只有 baseboard serial 天然归主板厂所有；system/chassis 及其 asset tag
> 应由整机集成商或资产管理员提供。SMBIOS Type 17 已不再填写虚构的 DIMM asset tag。
> 本轮不把 V-11 的随机 CPU/System SKU/asset 数字当成厂商证据；之后若重做所有权
> 关系，需要明确的 v4 身份迁移，不会静默改写已有 VM。

## 六款 active CPU 是哪些

这里的“六款”只指 active CPU。`i5-6500`、`i3-8100` 是 legacy-only，不计入
六款；`i5-4590` 本身是 active CPU，但原来的 i5-4590/H97 整机已经降为 legacy。

| CPU key | 型号与拓扑 | 基础/最高频率 | 新建策略 |
|---|---|---|---|
| `g3220` | Pentium G3220，2C/2T | 3.0/3.0 GHz | 默认池；DDR3-1333 |
| `i3-4130` | Core i3-4130，2C/4T | 3.4/3.4 GHz | 默认池 |
| `i5-4460` | Core i5-4460，4C/4T | 3.2/3.4 GHz | 默认池 |
| `i5-4570` | Core i5-4570，4C/4T | 3.2/3.6 GHz | 默认池 |
| `i5-4590` | Core i5-4590，4C/4T | 3.3/3.7 GHz | 默认池；只配 active H81 时属于新池 |
| `i7-4790` | Core i7-4790，4C/8T | 3.6/4.0 GHz | 仅显式新建；或 5 款默认 CPU 均未 supported、且自身明确 supported 时兜底 |
| `i5-6500` | Core i5-6500，4C/4T | 3.2/3.6 GHz | legacy-only，不计入六款 |
| `i3-8100` | Core i3-8100，4C/4T | 3.6/3.6 GHz | legacy-only，不计入六款 |

## 主板：active 全是低端双槽 H81

| 主板 key | 型号 | DIMM 槽/上限 | 新建策略 |
|---|---|---:|---|
| `asus-h81m-k` | ASUS H81M-K | 2 / 16 GiB | active |
| `asus-h81m-c` | ASUS H81M-C | 2 / 16 GiB | active |
| `gigabyte-h81m-s1` | Gigabyte GA-H81M-S1 rev 2.1 | 2 / 16 GiB | active |
| `msi-h81m-p33` | MSI H81M-P33 | 2 / 16 GiB | active |
| `gigabyte-h97-d3h` | Gigabyte GA-H97-D3H | 4 / 32 GiB | legacy-only |
| `gigabyte-b150m-d3h` | Gigabyte GA-B150M-D3H | 4 / 64 GiB | legacy-only |
| `asus-prime-b360m-a` | ASUS PRIME B360M-A | 4 / 64 GiB | legacy-only |

因此新 VM 不会抽到四槽主板。三块旧板只为已有身份及“所有 active CPU 均明确
不可实现”时的最终兜底保留，不会混入正常低端池。

## 内存：四品牌、17 套目录、始终两条

active 内存共有 15 套 DDR3 profile，覆盖 Kingston、Samsung、Micron、SK hynix
四个品牌；它们都只占两槽。这里的一“套”是已经审核的逐槽料号和几何组合，不是
可以随意互换的单条 DIMM。完整目录再保留 2 套 Kingston DDR4 legacy，共 17 套：

| `MEMORY_PROFILE` | 品牌 | 逐槽料号 | 容量/频率 | 逐槽 Rank × device width | 策略 |
|---|---|---|---|---|---|
| `kvr13n9s6-2x2` | Kingston | `KVR13N9S6/2` ×2 | 2+2 GiB / 1333 | `1R×16, 1R×16` | active 双通道 |
| `kvr13n9-flex-4plus2` | Kingston | `KVR13N9S8/4` + `KVR13N9S6/2` | 4+2 GiB / 1333 | `1R×8, 1R×16` | active Flex |
| `kvr13n9s8-2x4` | Kingston | `KVR13N9S8/4` ×2 | 4+4 GiB / 1333 | `1R×8, 1R×8` | active 双通道 |
| `kvr16n11s6-2x2` | Kingston | `KVR16N11S6/2` ×2 | 2+2 GiB / 1600 | `1R×16, 1R×16` | active 双通道 |
| `kvr16n11-flex-4plus2` | Kingston | `KVR16N11S8/4` + `KVR16N11S6/2` | 4+2 GiB / 1600 | `1R×8, 1R×16` | active Flex |
| `kvr16n11s8-2x4` | Kingston | `KVR16N11S8/4` ×2 | 4+4 GiB / 1600 | `1R×8, 1R×8` | active 双通道 |
| `samsung-m378b5773dh0-2x2` | Samsung | `M378B5773DH0-CK0` ×2 | 2+2 GiB / 1600 | `1R×8, 1R×8` | active 双通道 |
| `samsung-m378b5-flex-4plus2` | Samsung | `M378B5273DH0-CK0` + `M378B5773DH0-CK0` | 4+2 GiB / 1600 | `2R×8, 1R×8` | active Flex |
| `samsung-m378b5273dh0-2x4` | Samsung | `M378B5273DH0-CK0` ×2 | 4+4 GiB / 1600 | `2R×8, 2R×8` | active 双通道 |
| `micron-mt4jtf25664az-2x2` | Micron | `MT4JTF25664AZ-1G6` ×2 | 2+2 GiB / 1600 | `1R×16, 1R×16` | active 双通道 |
| `micron-mtjtf-flex-4plus2` | Micron | `MT8JTF51264AZ-1G6` + `MT4JTF25664AZ-1G6` | 4+2 GiB / 1600 | `1R×8, 1R×16` | active Flex |
| `micron-mt8jtf51264az-2x4` | Micron | `MT8JTF51264AZ-1G6` ×2 | 4+4 GiB / 1600 | `1R×8, 1R×8` | active 双通道 |
| `hynix-hmt325u6cfr8c-2x2` | SK hynix | `HMT325U6CFR8C-PB` ×2 | 2+2 GiB / 1600 | `1R×8, 1R×8` | active 双通道 |
| `hynix-hmt3x5-flex-4plus2` | SK hynix | `HMT351U6CFR8C-PB` + `HMT325U6CFR8C-PB` | 4+2 GiB / 1600 | `2R×8, 1R×8` | active Flex |
| `hynix-hmt351u6cfr8c-2x4` | SK hynix | `HMT351U6CFR8C-PB` ×2 | 4+4 GiB / 1600 | `2R×8, 2R×8` | active 双通道 |
| `kvr21n15s8-2x4` | Kingston | `KVR21N15S8/4` ×2 | 4+4 GiB / DDR4-2133 | `1R×8, 1R×8` | legacy-only |
| `kvr24n17s8-2x4` | Kingston | `KVR24N17S8/4` ×2 | 4+4 GiB / DDR4-2400 | `1R×8, 1R×8` | legacy-only |

目录使用的原始两字节 JEP106 对为：Kingston module `0198`、DRAM `0000`；
Samsung `80CE/80CE`；Micron `802C/802C`；SK hynix `80AD/80AD`。它们按槽重复或
混合，不能根据显示名称临时猜厂商码。

4 GiB 和 8 GiB 的两条容量相同，全部容量按双通道工作。6 GiB 不能写成“全容量
双通道”：4 GiB 条与 2 GiB 条各拿出 2 GiB，合计 4 GiB 为对称双通道区，4 GiB
条剩余的 2 GiB 是单通道区。不同品牌的 2 GiB/4 GiB 条可能采用不同 Rank 和颗粒
宽度，启动器不会把它们统一伪装成 Kingston 的 `1R×16/1R×8`。

Micron 目录来源中的销售 SKU 可带 E1 后缀，例如
`MT4JTF25664AZ-1G6E1`、`MT8JTF51264AZ-1G6E1`，两者均为 19 个字符；DDR3
JEDEC SPD part-number 区只有 bytes 128..145 共 18 字节。因此 G-11 使用可核验的
17 字符基础 part `MT4JTF25664AZ-1G6` / `MT8JTF51264AZ-1G6`，再以空格填满字段；
不能截成含半个后缀的字符串。SMBIOS Type 17 使用同一份基础 part。

### DDR3 逐槽 SPD 合同

启动 DDR3 VM 时，启动器会把每一槽的容量、Rank、device width、模组 JEP106、
DRAM JEP106、序列号和料号作为一个原子组交给 QEMU。QEMU 据此生成以下四种已
审核几何：`2 GiB 1R×16`、`2 GiB 1R×8`、`4 GiB 1R×8`、`4 GiB 2R×8`，并同步
密度、row/column addressing、organization、tRFC、时序和 CRC。DDR3 SPD 中：

- bytes 117..118 是模组厂商 JEP106；
- bytes 122..125 是该槽独立的 4-byte 序列号；
- bytes 128..145 是以空格补齐的 18-byte part number；
- bytes 148..149 是 DRAM 厂商 JEP106；Kingston 的 `0000` 表示该 ValueRAM
  profile 不承诺固定颗粒供应商，不表示模组厂商未知。

逐槽详情必须全有或全无；条数必须等于 `MEM_SLOTS`。模块厂商 `0000`、保留序列
`00000000`/`00000001`/`FFFFFFFF`、重复序列、超长/非 ASCII 料号和未经审核的
容量/Rank/width 组合都会在 QEMU 启动前被拒绝。

两套 DDR4 只为旧 B150/B360 身份保留。当前 SMBus EEPROM 是 256-byte page 0
模型，没有 EE1004 page 1；因此 legacy DDR4 只生成 page 0 的容量/速度/时序/CRC，
不会谎称已在 SPD page 1 写入厂商、序列和料号。它们的可见身份仍由逐槽 SMBIOS
Type 17 提供。新建 DDR3 路径不受这一兼容边界影响。

## 28 套整机白名单

组件 key 只是目录，不能任意做笛卡尔积。创建器只接受下面已经审核的组合。

| 平台 key | CPU | 主板 | 内存 | 策略 |
|---|---|---|---|---|
| `g3220-h81m-k-4g` | G3220 | H81M-K | Kingston 2×2 GiB DDR3-1333 | 默认 |
| `g3220-h81m-c-6g` | G3220 | H81M-C | Kingston 4+2 GiB DDR3-1333 Flex | 默认 |
| `g3220-h81m-s1-8g` | G3220 | H81M-S1 | Kingston 2×4 GiB DDR3-1333 | 默认 |
| `i3-4130-h81m-c-4g` | i3-4130 | H81M-C | Kingston 2×2 GiB DDR3-1600 | 默认 |
| `i3-4130-h81m-s1-6g` | i3-4130 | H81M-S1 | Kingston 4+2 GiB DDR3-1600 Flex | 默认 |
| `i3-4130-h81m-p33-8g` | i3-4130 | H81M-P33 | Kingston 2×4 GiB DDR3-1600 | 默认 |
| `i5-4460-h81m-s1-4g` | i5-4460 | H81M-S1 | Kingston 2×2 GiB DDR3-1600 | 默认 |
| `i5-4460-h81m-p33-6g` | i5-4460 | H81M-P33 | Kingston 4+2 GiB DDR3-1600 Flex | 默认 |
| `i5-4460-h81m-k-8g` | i5-4460 | H81M-K | Kingston 2×4 GiB DDR3-1600 | 默认 |
| `i5-4570-h81m-p33-4g` | i5-4570 | H81M-P33 | Kingston 2×2 GiB DDR3-1600 | 默认 |
| `i5-4570-h81m-k-6g` | i5-4570 | H81M-K | Kingston 4+2 GiB DDR3-1600 Flex | 默认 |
| `i5-4570-h81m-c-8g` | i5-4570 | H81M-C | Kingston 2×4 GiB DDR3-1600 | 默认 |
| `i5-4590-h81m-k-4g` | i5-4590 | H81M-K | Kingston 2×2 GiB DDR3-1600 | 默认 |
| `i5-4590-h81m-c-6g` | i5-4590 | H81M-C | Kingston 4+2 GiB DDR3-1600 Flex | 默认 |
| `i5-4590-h81m-s1-8g` | i5-4590 | H81M-S1 | Kingston 2×4 GiB DDR3-1600 | 默认 |
| `i3-4130-h81m-k-samsung-4g` | i3-4130 | H81M-K | Samsung 2×2 GiB DDR3-1600 | 默认 |
| `i3-4130-h81m-s1-samsung-6g` | i3-4130 | H81M-S1 | Samsung 4+2 GiB DDR3-1600 Flex | 默认 |
| `i3-4130-h81m-p33-samsung-8g` | i3-4130 | H81M-P33 | Samsung 2×4 GiB DDR3-1600 | 默认 |
| `i5-4460-h81m-c-micron-4g` | i5-4460 | H81M-C | Micron 2×2 GiB DDR3-1600 | 默认 |
| `i5-4460-h81m-s1-micron-6g` | i5-4460 | H81M-S1 | Micron 4+2 GiB DDR3-1600 Flex | 默认 |
| `i5-4460-h81m-p33-micron-8g` | i5-4460 | H81M-P33 | Micron 2×4 GiB DDR3-1600 | 默认 |
| `i5-4570-h81m-k-hynix-4g` | i5-4570 | H81M-K | SK hynix 2×2 GiB DDR3-1600 | 默认 |
| `i5-4570-h81m-c-hynix-6g` | i5-4570 | H81M-C | SK hynix 4+2 GiB DDR3-1600 Flex | 默认 |
| `i5-4570-h81m-s1-hynix-8g` | i5-4570 | H81M-S1 | SK hynix 2×4 GiB DDR3-1600 | 默认 |
| `i7-4790-h81m-p33-8g` | i7-4790 | H81M-P33 | Kingston 2×4 GiB DDR3-1600 | `explicit-new` |
| `i5-4590` | i5-4590 | H97-D3H | Kingston 2×4 GiB DDR3-1600 | legacy |
| `i5-6500` | i5-6500 | B150M-D3H | Kingston 2×4 GiB DDR4-2133 | legacy |
| `i3-8100` | i3-8100 | PRIME B360M-A | Kingston 2×4 GiB DDR4-2400 | legacy |

前 24 行才是无参数创建的默认随机池。新增三品牌各有 4/6/8 GiB 一套审核整机；
目录没有因此开放任意 CPU × 主板 × 内存笛卡尔积。`explicit-new` 和三条 legacy
仍遵守原来的能力兜底规则。

## 第一步：一键审计和列目录

以下命令都从仓库根目录执行，不需要 sudo，也不会创建 VM、磁盘、TAP、mdev 或
TPM state：

```bash
cd /home/ubuntu/projects/qemu

./deploy/scripts/check-hardware-pool.sh
# 只看可供脚本/人工复核的数量、品牌、序列策略和固定例外：
./deploy/scripts/check-hardware-pool.sh --machine-readable
./deploy/scripts/create-vm.sh --list-cpu-profiles
./deploy/scripts/create-vm.sh --list-board-profiles
./deploy/scripts/create-vm.sh --list-memory-profiles
./deploy/scripts/create-vm.sh --list-platforms
./deploy/scripts/create-vm.sh --list-ssd-profiles
./deploy/scripts/create-vm.sh --list-gpu-profiles
./deploy/scripts/create-vm.sh --list-monitor-profiles
./deploy/scripts/create-vm.sh --list-input-profiles
# 只用于查旧 VM 为何进 compatibility，不是新建可选项：
./deploy/scripts/create-vm.sh --list-input-compat
```

审计器会验证目录引用、组件合同和整机合法性，并用暂停、无磁盘、无网络、无显示
的临时 QEMU 进程询问 KVM 是否能以 `enforce=on` 完整实现每个 CPU。输出中的
`supported` 才能用于 active 新建；`compatibility` 只允许走旧平台政策。

## 第二步：宿主桥接只执行一条

第一次配置网络时，在宿主本地控制台执行：

```bash
./deploy/scripts/setup-bridge.sh
```

它会自动识别上联网卡，建立 VLAN-aware `br0`，并在确认前保留自动回滚。不要把
宿主密码写入脚本、配置或仓库；需要提权时只在系统 sudo 提示中输入。详细恢复和
VLAN 白名单见 [G-11 宿主桥接/VLAN 教程](G11-NETWORK-BRIDGE-VLAN.md)。

## 第三步：照抄创建和启动

### 方案 A：使用默认低端池

配置不存在时，启动器会从本机能实现的 24 套默认组合、兼容 SSD、12 条 2 GB GPU
和 28 款新建显示器中选择并持久化。GPU 按 12 条原子 profile 等概率抽取；只在
第一次生成配置时随机，之后启动不会换卡：

```bash
./deploy/scripts/start-vm.sh 8 --install /home/ubuntu/images/iso/win10.iso
```

### 方案 B：固定一套 8 GiB 整机

```bash
./deploy/scripts/create-vm.sh 8 \
  --platform i3-4130-h81m-p33-8g \
  --ssd-profile samsung-850-pro-512gb \
  --gpu-profile gtx1050_2gb \
  --monitor-profile dell-p2419h

./deploy/scripts/start-vm.sh 8 --install /home/ubuntu/images/iso/win10.iso
```

### 方案 C：固定 4 GiB 真双通道

```bash
./deploy/scripts/create-vm.sh 9 \
  --platform i5-4570-h81m-k-hynix-4g \
  --ssd-profile crucial-mx100-512gb \
  --gpu-profile gt1030_2gb \
  --monitor-profile benq-gw2480
```

### 方案 D：固定 6 GiB Flex 混插

```bash
./deploy/scripts/create-vm.sh 10 \
  --cpu-profile i5-4460 \
  --board-profile gigabyte-h81m-s1 \
  --memory-profile micron-mtjtf-flex-4plus2
```

三个组件参数筛选的是同一份白名单；不存在对应整机时会拒绝，并提示运行
`--list-platforms`，不会自行拼出未经审核的硬件。

### 方案 E：明确选择 i7

```bash
./deploy/scripts/create-vm.sh 11 --platform i7-4790-h81m-p33-8g
```

i7 不进入正常随机。除显式创建外，只有 5 款默认 CPU 均未得到 `supported`、且
i7 自身明确得到 `supported` 时，无参数创建器才会把它作为 active 能力兜底。

### 可选：改成三品牌相对鼠标

默认的 QEMU 绝对指针可让鼠标直接离开 VM 窗口，最省事。只有明确要验收
常见相对鼠标身份时才这样创建：

```bash
# 不指定型号：从 Microsoft / Logitech / Dell 中选一个
./deploy/scripts/create-vm.sh 12 --relative-mouse

# 固定 Dell MS116；相对模式需要视图器抓取/释放鼠标
./deploy/scripts/create-vm.sh 13 \
  --keyboard-profile logitech-k120-r64 \
  --mouse-profile dell-ms116
```

键盘和相对鼠标目录都明确标记 `identity_only_generic_report`：VID/PID、
`bcdDevice`、USB version、raw iManufacturer/iProduct 和无序列策略会原子固定，
但 QEMU 仍是通用 HID report，文档不会宣称它已完整复刻真机复合接口。

### 默认 LAN 与可选 VLAN

网络参数只影响本次启动，不写入硬件身份。不带 `--vlan-id` 就是默认原生 LAN：

```bash
# 默认 LAN
./deploy/scripts/start-vm.sh 8

# 可选：接入宿主白名单已允许的 VLAN 11
./deploy/scripts/start-vm.sh 8 --vlan-id 11
```

## SSD、GPU 和显示器边界

- SSD 完整目录恰好 9 款，全部精确为 `512110190592` 字节：7 款 SATA、2 款
  NVMe。active H81 没有原生 M.2，所以自动选择会经过拓扑门禁并使用兼容的 SATA
  型号；NVMe 只会用于链路合法的旧平台。不存在其他容量的 active/default key。
- GPU 只有 GTX 750 Ti、GT 1030、GTX 1050 三个目标型号，guest 身份与宿主 mdev
  framebuffer 合同都固定为 2048 MB。12 条 app-local 原子行覆盖 7 个板卡品牌和
  Samsung/SK hynix/Micron 3 个显存厂家，序列策略都为 `not-exposed`；B 模式
  系统 PCI 始终保持宿主 mdev，不能把这些 metadata 解释成可替换的系统 PCI 板卡。
- 显示器完整目录 35 款，每一款 preferred/native timing 都是
  1920×1080@60；新建白名单为其中 28 款。其他分辨率不能作为 profile 的原生模式。

## 创建和启动会检查什么

创建器先验证整机组合，启动器每次再按 `vm.conf` 中的组件合同复核，并执行真实
KVM CPU realization。任一项矛盾都会在完整 QEMU 启动前失败：

- CPU 型号、核心/线程、频率、缓存、代际和插槽必须匹配；
- active 主板必须是目录中的双槽 H81，CPU、DDR 代际和最大频率必须合法；
- 两条内存的逐槽容量、料号、Rank、device width、电压、SPD 与 SMBIOS 必须一致；
- 6 GiB 必须保持 4+2 GiB Flex 布局，不能伪报成全容量双通道；
- SSD 的型号、精确字节数、固件、扇区、接口、controller、形态与 PCIe 链路必须
  同时匹配；
- GPU 必须来自 12 条 2 GB 原子目录，显示器必须通过 FHD preferred timing 门禁；
- 新 CPU 必须由本机 KVM 以 `enforce=on` 完整实现；未知错误、超时或无 KVM
  fail-closed。

### 硬件合同 v3 的序列号策略

新建 VM 写入 `G11_HARDWARE_CONTRACT_VERSION=3`，所有身份只生成一次并持久化到
`vms/<ID>/vm.conf`，以后启动只验证、不重抽：

- `SYS_SN`、`MB_SN`、`CHASSIS_SN` 是三个互不相同的标签，并遵守所选主板厂商
  规则：ASUS 使用带固定 `S` 位置的 12 字符格式；MSI 使用绑定 `MS-XXXX` 板号的
  `601-XXXX-...`；Gigabyte 使用绑定主板发布年份且周数为 01..53 的
  `SNYYWW........`。
- `MEM_SN` 是 8 位大写十六进制，即 JEDEC 4-byte 序列；拒绝全零、`00000001`、
  全 `F`。第一槽使用该值，第二槽由 `MEM_SN + slot number` 稳定 SHA-256 派生，
  所以两槽不同、每次启动不变。新建时完整两项写入 `MEM_SERIAL_LIST`，创建和启动
  都验证它与 `MEM_SN + MEM_SLOTS` 的派生结果完全一致；每个列表成员都在统一
  `MEMORY_SERIAL` 命名空间跨 VM 查重。相同逐槽序列同时送入 SMBIOS Type 17 与
  DDR3 SPD bytes 122..125。
- `SSD_SN` 按九款 SSD 各自的厂商格式生成并以 strict 模式验证；显示器也按
  profile 校验：Samsung S24F350 使用 `H4ZMC` + 5 位数字，Redmi RMMNT238NF
  使用 `29200` + 8 位数字，并拒绝 V-11 证据源中的四个实机样本值。其余型号
  使用各自目录前缀加稳定哈希的 12 字符兼容格式，不冒充尚未审核的厂商精确
  标签规则。
- 缺少 `MEM_SERIAL_LIST` 的 v1/v2/v3 旧配置在有 `MEM_SN`/`MEM_SLOTS` 时按同一算法
  稳定派生；更老且缺少 `MEM_SN` 的配置仍以 VM UUID 稳定派生。扫描器也按最终逐槽
  值查重，启动器不会改写旧 bundle，也不会每次启动改变身份。

只读查看某台 VM 的持久身份和 QEMU 逐槽输入：

```bash
rg '^(G11_HARDWARE_CONTRACT_VERSION|MEMORY_PROFILE|MEM_MODEL_LIST|MEM_RANK_LIST|MEM_DEVICE_WIDTH_LIST|MEM_SN|MEM_SERIAL_LIST)=' \
  /home/ubuntu/images/vms/8/vm.conf

./deploy/scripts/start-vm.sh 8 --dry-run | \
  rg 'QEMU_SPD_(TYPE|MODULE_MB_LIST|RANK_LIST|DEVICE_WIDTH_LIST|MODULE_MFR_JEP106_LIST|DRAM_MFR_JEP106_LIST|SERIAL_LIST|PART_LIST)'
```

正常启动摘要应包含：

```text
CPU realization: policy=enforced class=supported enforce=on
硬件合法性: strict/OK
```

## 真机化边界与安全底线

CPU、主板和内存目录控制 SMBIOS、SPD、vCPU 拓扑、缓存、频率、存储和设备身份
之间的一致性。底层 machine 仍是 QEMU `q35`/ICH9；它不是 H81、H97、B150 或
B360 的完整物理 PCH 行为仿真，也不应被描述成实现了这些 PCH 的全部寄存器和
驱动行为。

三个 GPU 目标型号、12 条板卡/显存 profile 是 G-11 的应用层消费卡身份与 2 GB
资源目录；系统 PnP PCI identity
仍保持宿主 mdev 生产驱动合同。这里不引入 V-11 的 GPU 方案或全系统 PCI identity
改写。

同理，`q35`/ICH9-AHCI、`qemu-xhci`、QEMU `nvme` controller、安装/救援
`std-vga` 和 legacy `ivshmem` 都是实现或兼容边界。它们不会因为 profile 中有
消费硬件名称、型号或 subsystem metadata 就变成对应物理设备，也不参加品牌随机。

本流程不修改 BCD，不开启 `testsigning`/`nointegritychecks`，也不安装测试签名或
自签名内核驱动。

## 常见报错

- “没有审核过的整机组合”：组件筛选为空；运行
  `./deploy/scripts/create-vm.sh --list-platforms`，选择同一行的 component keys。
- “仅保留给已有 VM”：显式把 legacy 平台当作新 VM；换用 24 套默认或 1 套
  `explicit-new`。无参数创建器在 5 款默认 CPU 均未 supported 时仍会探测 i7；
  只有 6 款 active 都得到明确非 supported 结果时才决定 legacy 自动兜底。
- `new-vm-blocked` / `G11_CPU_CAP_*`：本机不能完整实现 CPU；先运行一键审计，
  不要关闭 `enforce` 绕过。
- `COMPONENT_CONTRACT_MISMATCH`：配置字段与目录合同不一致；不要只手改某个
  字符串，应用新 VM ID 重建或完整审计旧 VM。
- `STORAGE_TOPOLOGY_UNSUPPORTED`：SSD 接口或 PCIe 链路不适合该主板；active
  H81 选择七款 SATA profile 之一。
