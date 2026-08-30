# G-11 家用 4C/8T、6C/12T 一键教程

这个入口只会创建已审核的消费级 Intel Core i7 + X79 + DDR3 整机，不会选 Xeon、
4C/4T、H81 或 6G 内存。最简单的两条命令如下：

```bash
# 4 核 8 线程；默认 8G，优先 i7-4820K + DDR3-1866
./deploy/scripts/create-home-vm.sh 101 --spec 4c8t

# 6 核 12 线程；默认 8G，优先 i7-4960X + DDR3-1866
./deploy/scripts/create-home-vm.sh 102 --spec 6c12t
```

脚本会先用 KVM `enforce=on` 检查宿主能否实现所选 CPU。首选型号不可用时，只会在
同一 `4c8t` 或 `6c12t` 规格内向下尝试；不会悄悄换成另一个核数，也不会降级到
归档平台。

## 已纳入的真实产品

| 规格 | profile | Intel 零售型号/部件号 | 主频/睿频 | 官方内存上限 | 新建组合 |
|---|---|---|---:|---:|---:|
| 4C/8T | `i7-3820` | Core i7-3820 / `BX80619I73820` | 3.60/3.80 GHz | DDR3-1600 | 48 |
| 4C/8T | `i7-4820k` | Core i7-4820K / `BX80633I74820K` | 3.70/3.90 GHz | DDR3-1866 | 56 |
| 6C/12T | `i7-3930k` | Core i7-3930K / `BX80619I73930K` | 3.20/3.80 GHz | DDR3-1600 | 48 |
| 6C/12T | `i7-4930k` | Core i7-4930K / `BX80633I74930K` | 3.40/3.90 GHz | DDR3-1866 | 54 |
| 6C/12T | `i7-4960x` | Core i7-4960X / `BX80633I74960X` | 3.60/4.00 GHz | DDR3-1866 | 54 |

主板不是虚构名称：

| profile | 厂商/型号 | BIOS | DIMM 插槽 | 审核内存上限 |
|---|---|---|---:|---:|
| `asus-p9x79` | ASUS P9X79 | 4701 | 8 | DDR3-1866 |
| `gigabyte-x79-up4` | Gigabyte GA-X79-UP4 rev. 1.0 | F7 | 8 | DDR3-1866 |
| `asrock-x79-extreme4` | ASRock X79 Extreme4 | P3.20 | 4 | DDR3-1600 |

内存使用 Samsung、Micron、Elpida、Kingston、SK hynix 五个真实品牌及真实料号，
例如 `M378B5173QH0-CMA`、`MT8KTF51264AZ-1G9`、`EBJ40UG8BFW0-JS-F`、
`KVR16N11S8/4`、`HMT351U6CFR8C-PB`。每个 CPU/主板/容量至少有 4 个品牌，
满足条件的 DDR3-1866 组合有 5 个品牌。

“真实序列号”在这里指真实厂商、型号、部件号、JEDEC 厂商码，以及符合该厂商标签
规则的每 VM 唯一序列号。系统不会复制市场上某一台实体设备的序列号，也不会让多台
VM 共用序列号；创建后会对主板、每根 DIMM、SSD、MAC 等身份逐项做严格格式和冲突
校验。

## 内存容量和频率规则

| 选择 | 典型布局 | 规则 |
|---|---|---|
| `4G` | 2×2G | 可选 |
| `8G` | 2×4G | 默认 |
| `12G` | 3×4G | 主板必须至少 4 个 DIMM 插槽 |
| `16G` | 4×4G | 主板必须至少 4 个 DIMM 插槽 |

DDR3-1866 是优先级，不是强行超频：i7-4820K/i7-4930K/i7-4960X 搭配 ASUS 或
Gigabyte 时优先 1866；i7-3820/i7-3930K 的官方上限，以及 ASRock X79 Extreme4
的非超频审核上限，均保持 1600。以后若加入少于 4 个插槽的主板，12G/16G 会在目录
校验和创建入口两层直接拒绝。

## 常用复制粘贴命令

```bash
# 改成 4G、12G 或 16G
./deploy/scripts/create-home-vm.sh 103 --spec 6c12t --memory-size 12G

# 固定具体 CPU；规格必须匹配
./deploy/scripts/create-home-vm.sh 104 --spec 4c8t --cpu-profile i7-3820
./deploy/scripts/create-home-vm.sh 105 --spec 6c12t --cpu-profile i7-4930k

# 固定主板；内存品牌仍从该原子白名单中选择
./deploy/scripts/create-home-vm.sh 106 --spec 6c12t --board-profile asus-p9x79

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
  "$VM_ROOT/101/vm.conf"
```

正常应看到 `CPU_CORES/CPU_VCPUS` 为 `4/8` 或 `6/12`、默认
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
