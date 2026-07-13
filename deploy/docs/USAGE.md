# USAGE — Linux/KVM 操作参考

> **当前基线**：QEMU `11.0.2` + `vmate`，严格硬件目录 schema 1，Linux/KVM 为主路径。
> 新 VM 只启用 Intel i3-9100F/H310 和 i5-6400T/H110 两套受控身份 bundle；底层仍是
> Q35/ICH9，不能把 `supported` 解读为 H110/H310 machine/BDF 等价。AMD/B350 禁用。
> NVMe、显示器和 HID 各只有一套经过约束的组件模板，不再从十款字符串池随机拼装。
> GPU passthrough/vGPU 不在本分支范围，virtio 显示标签不代表真实独显。

当前能力、E5-2696 v4/X99、其它 E5 与 Windows/WHPX 的结论先看
[硬件平台评估](HARDWARE_PLATFORM_ASSESSMENT_2026-07-13.md)。字段来源和 fidelity 见
[Profile 字段](PROFILE-FIELDS.md)。

## 1. 宿主前提

Linux 严格启动至少需要：

- x86_64 Linux，BIOS 已开启 Intel VT-x/EPT 或 AMD-V/NPT，当前用户可访问 `/dev/kvm`。
- 本仓库编译的 patched `qemu-system-x86_64` 和 `qemu-img`；不能用 stock QEMU 代替。
- OVMF、swtpm/swtpm-tools、Python 3、`jq`、`socat`、`flock`。
- 默认 host tune/CPU isolate 所需的 root-owned helper。
- 4 个可用逻辑 CPU；当前启用客体 SKU 都是完整 4C/4T，不支持任意改成其它线程数。

Ubuntu 可从以下依赖起步；完整构建依赖仍以 `configure` 检查结果为准：

```bash
sudo apt update
sudo apt install -y build-essential ninja-build meson pkg-config python3 \
  libglib2.0-dev libpixman-1-dev libslirp-dev libsdl2-dev libepoxy-dev \
  libvirglrenderer-dev libspice-server-dev ovmf swtpm swtpm-tools \
  jq socat util-linux
```

本分支不做 GPU passthrough/vGPU，因此 VT-d/IOMMU 不是当前功能前提。它仍可用于宿主其它
用途，但不能据此提高本项目 GPU 真机化评级。

AMD/B350 compatibility bundle 默认禁用。AMD 物理宿主在 `STRICT_HARDWARE=1` 下目前可能
直接得到“无可用整机平台”，这是预期的 fail-closed 行为。

## 2. 构建与静态回归

```bash
# 增量构建 patched QEMU
deploy/tools/build.sh

# 常用构建选项
deploy/tools/build.sh --clean
deploy/tools/build.sh --reconfig
deploy/tools/build.sh --debug
deploy/tools/build.sh --jobs 8

# 并发快速回归；完整集为避免共享 socket 冲突而串行
python3 deploy/scripts/tests/run-vmate-tests.py --mode quick --jobs 4
python3 deploy/scripts/tests/run-vmate-tests.py --mode full
```

默认二进制路径为：

- `$REPO/build/qemu-system-x86_64`
- `$REPO/build/qemu-img`

迁移到其它目录时可传 `QEMU=/abs/path/qemu-system-x86_64`、
`QEMU_IMG=/abs/path/qemu-img`，或使用 `--qemu=...`。启动器默认 `QEMU_CAP_CHECK=1`，会检查
NVMe、EDID、USB、PCI identity、fb-shm 等定制属性；不要在生产中关闭。

## 3. 一次性宿主准备

### 3.1 安装最小 root helper

```bash
sudo deploy/scripts/setup-host-helpers.sh
sudo deploy/scripts/setup-host-helpers.sh check
```

安装器把固定副本放到 `/usr/local/libexec/qemu-vmate-*`，owner/mode 为 `root:root/0755`，
sudoers 使用 `NOPASSWD:NOSETENV`。旧版直接授权 Git 工作区脚本的 sudoers 会被删除。

不要手工把用户可写的仓库脚本加入 `NOPASSWD`。默认 `HOST_TUNE=1` 和
`CPU_ISOLATE=1` 会使用上述 helper。

### 3.2 检查 KVM/TSC

```bash
python3 deploy/scripts/kvm-capabilities.py --format json
lscpu -e=CPU,NODE,SOCKET,CORE,ONLINE,MAXMHZ,MINMHZ
```

严格模式会读取 `KVM_CAP_TSC_CONTROL`、`KVM_CAP_GET_TSC_KHZ` 和实际 vCPU TSC。没有 TSC
scaling 时，目标 profile 必须匹配宿主实测 TSC；选中后还会用 `enforce=on` 实际创建最小
QEMU/KVM vCPU。商品名、插槽或“同属 Intel”都不能替代这两个门禁。

### 3.3 桥接网络

```bash
# 创建 br0；指定物理上联后 guest 可从真实 LAN 获取地址
sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh

# 生产模式拒绝 bridge 失败后回落到 10.0.2.x SLIRP
STRICT_STEALTH=1 deploy/scripts/start-vm.sh 1
```

默认 `BRIDGE=br0`，但 `STRICT_STEALTH=0` 为兼容默认；bridge 不存在时可能明确告警并回落到
user-mode NAT。生产验收应显式设置 `STRICT_STEALTH=1`，不要用 NAT 结果代表物理 LAN 行为。

VLAN access TAP 示例：

```bash
# 首次为单一 VLAN-aware br0 准备 trunk；远程执行可能断 SSH，优先用带外控制台
sudo VLAN_TRUNK=1 UPLINK=enp5s0 deploy/scripts/setup-bridge.sh

deploy/scripts/start-vm.sh 1 --vlan-id=11
deploy/scripts/start-vm.sh 2 --vlan-id=20
```

guest 侧收到 untagged 帧，不需要创建 VLAN 子接口。显式 VLAN 预检失败会停止，不回退到
native LAN 或 NAT。只需要隔离功能测试时可用 `--no-bridge` 明确选择 SLIRP。

## 4. 创建与启动 VM

### 4.1 首次安装

```bash
# instance 1；首次生成 profile 和 512GB 稀疏 qcow2，并从 ISO 安装
deploy/scripts/start-vm.sh 1 \
  --iso=/home/ubuntu/images/win10_ltsc.iso

# 附加自动应答/驱动 ISO
EXTRA_ISO=/home/ubuntu/images/autounattend-vm1.iso \
  deploy/scripts/start-vm.sh 1 \
  --iso=/home/ubuntu/images/win10_ltsc.iso
```

新 profile 默认 8192 MiB，拓扑为 2×4 GiB DDR4、双通道、**一个 guest NUMA node**。
DIMM 数只通过 SMBIOS/SPD 表达；双 DIMM 从不等于双 NUMA。

首次磁盘是 qcow2 稀疏文件，但 guest-visible virtual-size 必须精确等于组件模板中的
`NVME_SIZE_BYTES=512110190592`。启动器每次用 `qemu-img info` 校验，不按宿主文件大小猜容量，
也不会静默 resize 不匹配的历史磁盘或 base image。

### 4.2 日常启动与关机

```bash
# 从已有磁盘启动
deploy/scripts/start-vm.sh 1

# 原生 QMP multi-client，并保留 .qmp.proxy 兼容别名
deploy/scripts/start-vm.sh 1 --proxy

# 优雅 ACPI 关机；等待 120 秒
deploy/scripts/stop-vm.sh 1 --wait=120

# 跳过 ACPI，直接发 QMP quit
deploy/scripts/stop-vm.sh 1 --hard
```

每个 instance 有独立磁盘、profile、OVMF NVRAM、TPM state 和 socket。默认位置：

| 资源 | 路径 |
|---|---|
| VM 目录 | `/home/ubuntu/images/vms/<N>/` |
| 磁盘 | `disk.qcow2` |
| 硬件身份 | `profile` |
| UEFI NVRAM | `ovmf-vars.fd` |
| TPM | `tpm-state/`、`tpm-sock` |
| QMP/HMP | `/tmp/qemu-stealth-<N>.qmp`、`.mon` |
| fb-shm | `/tmp/qemu-stealth-<N>.fb` |

用 `IMAGE_ROOT`、`VMS_DIR` 或 `VM_DIR` 可迁移数据路径；细节见
[可移植性](PORTABILITY.md)。

正式启动 swtpm 时，启动器会把经过 `realpath` 规范化、owner/type/mode 校验的
`tpm-state` 路径登记到当前用户的私有 runtime 目录。之后直接执行
`deploy/scripts/stop-vm.sh <N>` 即可停止使用自定义 `VM_DIR` 的实例，无需重复传入路径。
runtime 文件损坏、变成符号链接或权限向 group/other 开放时，stop 会拒绝模糊匹配和误杀；
没有 runtime 文件的旧实例仍兼容默认 `$VMS_DIR/<N>/tpm-state` 布局。

### 4.3 无副作用预检

```bash
STRICT_HARDWARE=1 DRY_RUN=1 \
  deploy/scripts/start-vm.sh 99 \
  --qemu="$PWD/build/qemu-system-x86_64" \
  --no-host-tune --no-cpu-isolate --no-bridge
```

`DRY_RUN=1` 不创建 profile、磁盘、OVMF vars、TPM state 或守护进程，但仍执行 patched QEMU
能力检查、KVM/TSC 检查和实际 CPU realize smoke。首次 dry-run 因为不创建磁盘，不能代替
已有 qcow2 容量校验；要验容量应显式传入匹配的 `--disk=/path/test.qcow2`。

## 5. 当前默认值

| 变量/标志 | 默认 | 当前语义 |
|---|---:|---|
| `STRICT_HARDWARE` | `1` | 平台、组件、KVM/TSC、CPU realize、TPM 等硬件面 fail closed |
| `STEALTH_TSC_POLICY` | `auto` | 有 scaling 用 profile TSC；无 scaling 按宿主实测约束 |
| `CPUS` | `4` | 必须等于所选 SKU 的完整 4 个线程 |
| `MEM_TOTAL_MB` | 新 profile `8192` | 2/4/8 GiB 由 manifest 约束；新建默认 2×4 GiB |
| `TPM` | `1` | swtpm 2.0 + CRB；严格模式下缺失/初始化失败不降级 |
| `HOST_TUNE` | `1` | governor=performance、`halt_poll`、THP defrag；不停止 irqbalance |
| `CPU_FREQ_CAP` | **`0`** | 默认不全局封顶；`--freq-cap` 才按目标 CPU 上限启用 |
| `CPU_ISOLATE` | `1` | 异步 NUMA-aware pinner + cgroup cpuset |
| `QEMU_SERVICE_CPUS` | `0` | `--svc-cpu` 分配 1 个辅助线程逻辑 CPU |
| `MEM_GUARD` | `1` | 可用内存不足时告警或拒绝；`MEM_FORCE=1` 显式越过硬拒绝 |
| `SDL` / `FB_SHM` | `1` / `1` | 默认本地 SDL/GL 窗口与 fb-shm 同时启用 |
| `STABLE_DISPLAY` | `0` | 默认 virtio-vga-gl；设 1 改用无 GL 稳定路径 |
| `GPU_DISPLAY` | `sdl` | 还支持 `sdl-egl` 兼容名和 `egl-headless` |
| `QEMU_CAP_CHECK` | `1` | 拒绝缺少定制设备属性的 QEMU |
| `STRICT_STEALTH` | `0` | 网络兼容默认；生产应显式设 1 禁止 NAT fallback |
| `PROXY` | `0` | `--proxy` 启用 QMP 原生 multi-client |

`CPU_FREQ_CAP=0` 是有意的默认值：全局 `scaling_max_freq` 会同时影响管理核和其它 VM，尤其
不适合未经评估的高核/双路 E5。优先用 NUMA/cpuset 放置；只有确认宿主调度策略后才使用
`--freq-cap`。

宿主内存使用单个 `memory-backend-memfd,share=on,prealloc=off`，按需占用物理页，不预留无效
hugepage 池。`share=on` 供 VMI 读取同一份 guest RAM；它不改变客体报告的内存容量。

## 6. 显示与 fb-shm

| 命令 | 本地窗口 | 远程显示 | fb-shm |
|---|---|---|---|
| `start-vm.sh 1` | SDL/GL | 无 | 开 |
| `start-vm.sh 1 --headless` | 无 | VNC | 开 |
| `start-vm.sh 1 --no-sdl` | 无 | 无 | 开 |
| `start-vm.sh 1 --no-fb-shm` | SDL/GL | 无 | 关 |
| `start-vm.sh 1 --gpu-headless` | 无 | EGL rendernode | 开 |

无 `DISPLAY` 且非交互终端时，默认 SDL 会自动关闭，仅保留 fb-shm。消费端示例：

```bash
build/qemu-fb-shm-stream \
  --sock /tmp/qemu-stealth-1.fb \
  --output /tmp/vm1.mp4 \
  --encoder libx264 --preset veryfast --mode auto
```

GPU handle 只是一条传帧优化；导出不可用时会回落到 SHM。无论路径为何，客体仍是 virtio
显示设备，不能把日志中的 GPU handoff、旧 NVIDIA/AMD 标签或注册表名称当作物理 GPU 证据。

## 7. Profile 与内存变更

```bash
# 查看，不要 source
sed -n '1,220p' /home/ubuntu/images/vms/1/profile

# 使用 manifest 允许的配置；重启后生效
deploy/scripts/set-vm-memory.sh 1 4G
deploy/scripts/set-vm-memory.sh 1 8G

# 重新生成整套平台/组件绑定和唯一值
deploy/scripts/reroll-identity.sh 1
# 或下一次启动时
deploy/scripts/start-vm.sh 1 --reroll
```

`--ram=`/`RAM=` 是本次启动覆盖，仍必须属于平台允许值。长期变更应写入 profile，避免容量
在重启间漂移。严格模式拒绝过时 manifest revision 和 legacy profile；reroll 会改变 UUID、
序列号和 MAC，可能触发 Windows 重新激活，应先备份并在测试实例验证。

## 8. E5/X99 宿主验收

E5 v3/v4 + X99/C612 只能标记为条件支持。E5-2696 v4 是 OEM 定制 SKU，必须先核对准确主板
型号、PCB revision、BIOS/微码、供电、散热和内存类型；“LGA2011-3 能插上”不等于受支持。

```bash
sudo dmidecode --type 0,2,4,16,17
grep -E 'vendor_id|model name|microcode|flags' /proc/cpuinfo | head -40
cat /sys/module/kvm_intel/parameters/ept 2>/dev/null
python3 deploy/scripts/kvm-capabilities.py --format json

# 在目标机执行真正的严格 CPU realize，但不写实例状态
STRICT_HARDWARE=1 DRY_RUN=1 \
  deploy/scripts/start-vm.sh 99 \
  --qemu="$PWD/build/qemu-system-x86_64" \
  --no-host-tune --no-cpu-isolate --no-bridge
```

无 TSC scaling 且实际 vCPU TSC 约为 2200 MHz 时，当前候选只剩 i5-6400T/H110；是否真的
可用仍由随后 Broadwell→Skylake named-model 的 QEMU/KVM realize 决定。任何 warning、
unsupported、CPUID 缺失或 TSC 设置失败都表示不支持，不能改成 `enforce=off` 绕过。

单路 X99 是一个宿主 NUMA 场景；双路 C612 应让每台 4-vCPU VM 优先放在一个 node，容量不足
而跨 node 只能算退化运行。高核心数提高多 VM 容量，不保证单台 4-vCPU VM 更快。

## 9. 客体快照与长稳

Linux 客体内：

```bash
sudo deploy/scripts/guest/collect-hardware-snapshot.sh /tmp/vmate-hardware-linux
```

至少核对 CPU/核心线程、SMBIOS 0/1/2/3/4/16/17、PCI 主/子系统 ID、PCIe link、NVMe
Identify/容量/firmware/SubNQN、NIC OUI、USB descriptor、EDID、TPM 和启动 warning。

宿主侧 24 小时 QMP soak：

```bash
python3 deploy/scripts/soak-vm.py \
  --qmp /tmp/qemu-stealth-1.qmp \
  --pid "$(pgrep -n -f 'qemu-system-x86_64.*win10-1')" \
  --duration 24h --interval 30 \
  --output /var/tmp/vmate-soak-1.jsonl
```

soak 通过仍不等于性能通过。E5/X99 还应记录 idle、单 VM 满载、多 VM 满载下的 scheduler
latency、NUMA remote access、磁盘/网络 P99、RSS、温度和功耗。

## 10. 历史文档说明

`STEALTH-WORKFLOW.md`、`STEALTH-APPROACHES.md`、`ACE-SHALLOW-STEALTH.md` 以及旧审计中仍可能
保留 AMD/B350、深层 GPU、多个 NVMe/显示器/HID 随机池等历史流程。它们不能覆盖当前
`platforms.json`、`components.json`、启动器和 2026-07-13 硬件评估；新部署以本页和当前
manifest 为准。
