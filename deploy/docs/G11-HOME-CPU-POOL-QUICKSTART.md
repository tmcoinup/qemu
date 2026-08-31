# G-11 家用 CPU 通用池一键教程

这个入口保留原有消费级 G3220/Core i3/i5/i7 + H81 池，并追加 Core i7 + X79
扩展池；不会选择 Xeon，也不会新建已经归档的 6G 内存组合。可选规格完整恢复为
`2c2t`、`2c4t`、`4c4t`、`4c8t`、`6c12t`，内存默认 8G：

```bash
# 2 核 2 线程 / 2 核 4 线程
./deploy/scripts/create-home-vm.sh 101 --spec 2c2t
./deploy/scripts/create-home-vm.sh 102 --spec 2c4t

# 4 核 4 线程
./deploy/scripts/create-home-vm.sh 103 --spec 4c4t

# 4 核 8 线程；默认 8G，优先 i7-4820K + DDR3-1866
./deploy/scripts/create-home-vm.sh 104 --spec 4c8t

# 6 核 12 线程；默认 8G，优先 i7-4960X + DDR3-1866
./deploy/scripts/create-home-vm.sh 105 --spec 6c12t
```

脚本会先用 KVM `enforce=on` 检查宿主能否实现所选 CPU。首选型号不可用时，只会在
同一规格内向下尝试；不会悄悄换成另一个核数，也不会降级到归档平台。

## 已纳入的真实产品

| 规格 | profile | Intel 零售型号/部件号 | 主频/睿频 | 官方内存上限 | 新建组合 |
|---|---|---|---:|---:|---:|
| 2C/2T | `g3220` | Pentium G3220 / `BX80646G3220` | 3.00/3.00 GHz | DDR3-1333 | 2 |
| 2C/4T | `i3-4130` | Core i3-4130 / `BX80646I34130` | 3.40/3.40 GHz | DDR3-1600 | 161 |
| 4C/4T | `i5-4460` | Core i5-4460 / `BX80646I54460` | 3.20/3.40 GHz | DDR3-1600 | 4 |
| 4C/4T | `i5-4570` | Core i5-4570 / `SR14E` | 3.20/3.60 GHz | DDR3-1600 | 4 |
| 4C/4T | `i5-4590` | Core i5-4590 / `SR1QJ` | 3.30/3.70 GHz | DDR3-1600 | 2 |
| 4C/8T | `i7-4790` | Core i7-4790 / `BX80646I74790` | 3.60/4.00 GHz | DDR3-1600 | 1（手选） |
| 4C/8T | `i7-3820` | Core i7-3820 / `BX80619I73820` | 3.60/3.80 GHz | DDR3-1600 | 48 |
| 4C/8T | `i7-4820k` | Core i7-4820K / `BX80633I74820K` | 3.70/3.90 GHz | DDR3-1866 | 56 |
| 6C/12T | `i7-3930k` | Core i7-3930K / `BX80619I73930K` | 3.20/3.80 GHz | DDR3-1600 | 48 |
| 6C/12T | `i7-4930k` | Core i7-4930K / `BX80633I74930K` | 3.40/3.90 GHz | DDR3-1866 | 54 |
| 6C/12T | `i7-4960x` | Core i7-4960X / `BX80633I74960X` | 3.60/4.00 GHz | DDR3-1866 | 54 |

X79 扩展主板不是虚构名称：

| profile | 厂商/型号 | BIOS | DIMM 插槽 | 审核内存上限 |
|---|---|---|---:|---:|
| `asus-p9x79` | ASUS P9X79 | 4701 | 8 | DDR3-1866 |
| `gigabyte-x79-up4` | Gigabyte GA-X79-UP4 rev. 1.0 | F7 | 8 | DDR3-1866 |
| `asrock-x79-extreme4` | ASRock X79 Extreme4 | P3.20 | 4 | DDR3-1600 |

原有 mainstream 池继续使用 H81 审核主板；完整可见新建池覆盖 ASUS、Gigabyte、
MSI、ASRock、ECS 五个主板品牌。内存使用 Samsung、Micron、Elpida、Kingston、
SK hynix、Crucial 六个真实品牌及真实料号，X79 子池仍严格保持每组 4–5 个品牌，
例如 `M378B5173QH0-CMA`、`MT8KTF51264AZ-1G9`、`EBJ40UG8BFW0-JS-F`、
`KVR16N11S8/4`、`HMT351U6CFR8C-PB`。X79 子池的每个 CPU/主板/容量至少有
4 个品牌，满足条件的 DDR3-1866 组合有 5 个品牌。

“真实序列号”在这里指真实厂商、型号、部件号、JEDEC 厂商码，以及符合该厂商标签
规则的每 VM 唯一序列号。系统不会复制市场上某一台实体设备的序列号，也不会让多台
VM 共用序列号；创建后会对主板、每根 DIMM、SSD、MAC 等身份逐项做严格格式和冲突
校验。

## 内存容量和频率规则

| 选择 | 典型布局 | 规则 |
|---|---|---|
| `4G` | 2×2G | 可选 |
| `8G` | 2×4G | 默认 |
| `12G` | 3×4G | 主板必须至少 4 个 DIMM 插槽；双槽旧平台不会出现 |
| `16G` | 4×4G | 主板必须至少 4 个 DIMM 插槽；双槽旧平台不会出现 |

DDR3-1866 是优先级，不是强行超频：i7-4820K/i7-4930K/i7-4960X 搭配 ASUS 或
Gigabyte 时优先 1866；i7-3820/i7-3930K 的官方上限，以及 ASRock X79 Extreme4
的非超频审核上限，均保持 1600。以后若加入少于 4 个插槽的主板，12G/16G 会在目录
校验和创建入口两层直接拒绝。

## 常用复制粘贴命令

```bash
# 旧双槽平台可选 4G/8G
./deploy/scripts/create-home-vm.sh 106 --spec 4c4t --memory-size 4G

# X79 四槽/八槽平台可选 12G/16G
./deploy/scripts/create-home-vm.sh 107 --spec 6c12t --memory-size 12G

# 固定具体 CPU；规格必须匹配
./deploy/scripts/create-home-vm.sh 108 --spec 2c4t --cpu-profile i3-4130
./deploy/scripts/create-home-vm.sh 109 --spec 4c8t --cpu-profile i7-4790
./deploy/scripts/create-home-vm.sh 110 --spec 6c12t --cpu-profile i7-4930k

# 固定主板；内存品牌仍从该原子白名单中选择
./deploy/scripts/create-home-vm.sh 111 --spec 6c12t --board-profile asus-p9x79

# 查看目录
./deploy/scripts/create-vm.sh --list-cpu-profiles
./deploy/scripts/create-vm.sh --list-board-profiles
./deploy/scripts/create-vm.sh --list-memory-profiles
./deploy/scripts/create-vm.sh --list-platforms
```

创建后检查最终结果：

```bash
VM_ROOT=${VM_ROOT:-${IMAGE_ROOT:-/home/ubuntu/images}/vms}
grep -E '^(CPU_PROFILE|CPU_CORES|CPU_VCPUS|BOARD_BRAND|BOARD_MODEL|MEM_BRAND|MEM_MODEL_LIST|MEM_TOTAL_MB|MEM_SPEED|BOARD_SN|MEM_SN_LIST)=' \
  "$VM_ROOT/104/vm.conf"
```

正常应看到 `CPU_CORES/CPU_VCPUS` 与所选的五种规格之一一致、默认
`MEM_TOTAL_MB=8192`，以及由 CPU 和主板共同决定的 `MEM_SPEED=1600|1866`。

## 验收和封装

```bash
# 只读审计目录和宿主兼容性
./deploy/scripts/check-hardware-pool.sh

# 自动化回归
bash ./deploy/tests/vgpu/test_hardware_legality.sh
bash ./deploy/tests/vgpu/test_create_6c12t_pool.sh
bash ./deploy/tests/vgpu/test_create_vm_platform_fallback.sh
```

`create-home-vm.sh` 就是日常傻瓜封装；底层仍统一调用 `create-vm.sh`，所以 GPU、SSD、
显示器、存储锁、序列号唯一性和生命周期门禁不会出现第二套实现。宿主凭据只通过已有
安全渠道或环境变量提供，脚本和生成配置都不会把凭据写入仓库。整个流程不修改 BCD，
不启用 `testsigning`/`nointegritychecks`，也不安装测试签名或自签名内核驱动。
