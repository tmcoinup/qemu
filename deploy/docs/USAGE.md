# USAGE — Linux/KVM 操作参考

> **当前基线**：QEMU `11.0.2` + `V-11`，严格硬件目录 schema 1，Linux/KVM 为主路径。新 VM 启用六套 Intel 受控 bundle，主板覆盖 ASUS、MSI、GIGABYTE；底层仍是 Q35/ICH9，不能把 `supported` 解读为 H110/H310 machine/BDF 等价。AMD/B350 禁用。
> NVMe 只含 Samsung、Intel、WD、KIOXIA 四款精确 512GB 原子模板，显示器有四款 1080p/16:9 模板；新 GPU 池覆盖 6 个芯片型号，每个型号 3 个板卡品牌，共 18 块 AIB（12 NVIDIA、6 AMD）。物理显示仍为 virtio `1AF4:1050`，不使用 GPU passthrough/vGPU，也不虚构 GPU 序列号。

当前能力、E5-2696 v4/X99、其它 E5 与 Windows/WHPX 的结论先看 [硬件平台评估](HARDWARE_PLATFORM_ASSESSMENT_2026-07-13.md)；字段来源和 fidelity 见 [Profile 字段](PROFILE-FIELDS.md)。DGame 的区域推流依赖最终 QEMU 叶进程的进程级 Yama 例外；`start-vm.sh` 已逐实例自动选择包内 wrapper、内置 Python wrapper 或新版 `setpriv`，无需手工降低全局 `ptrace_scope`，详见 [DGame QEMU 内存授权记录](DGAME_QEMU_MEMORY_AUTH.md)。

## 1. 宿主前提

Linux 严格启动至少需要：

- x86_64 Linux，BIOS 已开启 Intel VT-x/EPT 或 AMD-V/NPT，当前用户可访问 `/dev/kvm`。
- 本仓库编译的 patched `qemu-system-x86_64` 和 `qemu-img`；不能用 stock QEMU 代替。
- OVMF、swtpm/swtpm-tools、Python 3、`socat`、`flock`（`jq` 用于诊断输出）。
- 默认 host tune/CPU isolate 所需的 root-owned helper。
- 至少 2 个可用逻辑 CPU；`CPUS` 只能为 2 或 4，并须等于所选 2C2T/2C4T/4C4T SKU 的完整线程数。

新 Ubuntu host 应按用途安装依赖，不要把运行时、固件重建和 Windows 交叉打包工具混成一组。完整包名、命令对应关系、Podman/rootless 边界及安装后自检见 [开发与跨平台验证依赖](DEVELOPMENT-DEPENDENCIES.md)。

Ubuntu Desktop 通常已经由 NetworkManager 管理网卡；持久化 `br0` 前先确认：

```bash
systemctl is-active NetworkManager
nmcli -t -f NAME,TYPE,DEVICE connection show --active
ip -4 route show default
```

如果输出不是 `active`，`setup-bridge.sh` 只会使用非持久的 iproute2 fallback。Ubuntu Server 若仍由 netplan/systemd-networkd 管理，不要在 SSH 中直接切 renderer；先准备本地/带外控制台，再执行 `sudo apt install -y network-manager` 并切换 renderer。

GNOME Wayland 会话由 Mutter 决定 XWayland 窗口能否抑制 `Super`、`Alt+Tab` 等宿主快捷键。QEMU 会在键盘抓取前发送 `_XWAYLAND_MAY_GRAB_KEYBOARD`，为当前普通 SDL 窗口申请权限；这条逐窗口请求不依赖 `xwayland-allow-grabs`，后者只影响 override-redirect 窗口，不应为 QEMU 全局开启。
默认无需修改 GNOME 设置。只有宿主自定义了 `xwayland-grab-access-rules` 并显式拒绝 QEMU 时，才用 `xprop WM_CLASS` 确认 SDL 窗口类并调整对应拒绝规则；不要放宽为任意应用。原生 Xorg 不需要该 XWayland 授权消息。

安装后还要验证 KVM 与默认 CPU 隔离前提；把用户加入 `kvm` 组后必须重新登录：

```bash
test -r /dev/kvm && test -w /dev/kvm
test -c /dev/net/tun
id -nG | tr ' ' '\n' | grep -Fx kvm
stat -fc %T /sys/fs/cgroup                 # 期望 cgroup2fs
grep -w cpuset /sys/fs/cgroup/cgroup.controllers
```

若缺少 `kvm` 组权限，执行 `sudo usermod -aG kvm "$USER"` 后注销并重新登录。日常启动不需要记忆或手工执行 CPU isolate preflight；`start-vm.sh` 在启用 `CPU_ISOLATE=1` 时会自动运行。下面的命令只用于安装后的独立诊断：

```bash
sudo -n /usr/local/libexec/qemu-vmate-cpu-isolate preflight
```

其中 `sudo -n` 表示只使用已安装的 `NOPASSWD` 授权，绝不等待密码输入；授权缺失时立即失败。`preflight` 会验证固定 helper/runtime、QEMU 信任清单中的 canonical path、device/inode 和 SHA-256，并检查 cgroup v2/cpuset（缺少 subtree controller 时会尝试启用），同时准备 root-only 的 `/run/qemu-vmate-cpu-isolate` 目录。它不会创建 `vmiso` CPU 分区、迁移进程、修改 governor 或启动 VM；成功输出包含 `abi=5 policy=logical-1to1-v1`。

本分支不做 GPU passthrough/vGPU，因此 VT-d/IOMMU 不是当前功能前提。它仍可用于宿主其它用途，但不能据此提高本项目 GPU 真机化评级。
家用 CPU 目录分为两层：E5 v3/v4 精确宿主类拥有无需附加参数的 Haswell `supported` 正常池；E5 v1/v2、AMD K10/Zen 及其它候选仍属于显式 `compatibility` 兜底。E5 v1-v4 在这里只是宿主代际分类，不是 Guest 型号；目录只产生家用 Guest CPU，服务器/E 系列不会作为 Guest 兜底。

若当前目标只是先在 AMD 宿主安装/运行 Windows 10，并明确接受“Ryzen/B350 字段 +
Q35/ICH9 machine 行为”不等于真实 B350，可使用窄范围兼容入口：

```bash
deploy/scripts/start-vm.sh 2 \
  --allow-platform-compatibility \
  --iso=/home/ubuntu/images/win10.iso
```

新建 profile 时，启动器按宿主 CPU vendor、CPUID 代际和 `CPUS` 自动匹配。
E5 v3/v4 先选择其专用 Haswell 家用正常池；其它宿主先选择普通 `supported`
整机，只在没有可用正常候选时回退到已授权的家用 `compatibility` 完整组合。
已有 profile 会复用其持久化的 `PLATFORM_ID`，不会在普通重启时重新抽选；
后续手工启动兼容 profile 时只需继续携带 `--allow-platform-compatibility`，Dock 入口、
guest 安装器自动重启和内存管理提示也会自动传播该授权。

从 base 创建克隆时使用同一授权；clone 会在写入 profile 前加载与启动器相同的
KVM/物理地址位/真实 vCPU realize 门禁，并把兼容参数写进最后显示的启动命令：

```bash
sudo deploy/scripts/clone-from-base.sh win10-ltsc-shallow 2 \
  --cpus=4 \
  --allow-platform-compatibility
```

E5 v3/v4 的 Haswell 正常池不需要这个参数；E5 v1/v2、AMD 和其它
`status=compatibility` 兜底在创建与后续启动时都必须显式携带。

密封 base 必须由实际 VM 普通用户执行；clone 则必须由该用户通过 `sudo` 调用。
两个入口都接受 `--migrate-storage-profile`。该授权只让已知旧 profile 在内存中
补齐启动盘字段，不会改写文件；clone 复用旧 UI profile 时，会把同一参数继续写入
完成提示中的 start/finalize 命令。示例：

```bash
deploy/scripts/seal-base.sh 1 win10-ltsc-shallow \
  --migrate-storage-profile

sudo deploy/scripts/clone-from-base.sh win10-ltsc-shallow 2 \
  --migrate-storage-profile
```

`seal-base.sh` 会校验并把最终 base 密封为 `root:root/0444`；clone 在实例目录建立同 inode 的
`.base.qcow2` 只读 pin，overlay 只引用这个相对路径。因此删除或移动 `_base` 原目录项都不会改变已有实例的
backing；base 与 `VMS_DIR` 必须位于同一文件系统。完成提示包含 `sudo`、base 绝对路径、`VMS_DIR`、`qemu-img`、compatibility 与迁移授权，可直接复制；seal 默认生成低尾延迟的未压缩 base（`--compression=zlib` 或 `BASE_COMPRESSION=zlib` 才压缩），并按 staging 与最终独立 inode 的峰值提前检查空间。

浏览器下载、`scp`、Windows 或移动介质复制会丢失 Linux owner/mode。把独立 qcow2
复制到目标 Linux 文件系统后，仍直接执行 `sudo clone-from-base.sh`：clone 会在稳定 FD
上全检，确认文件属于调用用户、只有一个硬链接且没有进程持有，再自动密封为
`root:root/0444`，无需手工 `chown/chmod`。NTFS/CIFS/DrvFS 无法持久化 Unix 权限时会明确拒绝，应先复制到 Linux
`BASE_DIR`；base 与 `VMS_DIR` 仍须位于同一文件系统，才能建立零拷贝实例 pin。

升级前已有的 overlay 仍可读取普通用户拥有、无任何写权限的 legacy `0444`
backing，启动时会给出迁移警告；新 clone 和实例内 pin 继续使用严格密封契约。

`--platform-id` 保留为高级选项：新建时可固定特定候选，已有 profile 上则断言与持久化
ID 一致。例如：

```bash
deploy/scripts/start-vm.sh 2 \
  --allow-platform-compatibility \
  --platform-id=amd-am4-r3-1200-asus-prime-b350-plus \
  --iso=/home/ubuntu/images/win10.iso
```

`--allow-platform-compatibility` **不会**把 `STRICT_HARDWARE` 改成 `0`：宿主 CPU 厂商、
完整线程数、物理地址位、CPU feature 的 KVM 无警告 realize、profile 绑定、磁盘容量及 TPM
仍然 fail closed。E5 v3/v4 正常家用池以及显式家用 compatibility 在无 TSC
scaling/低频时可沿用宿主 TSC 与受限性能，并明确警告；该例外仍要求精确 CPUID
宿主分类和真实 KVM realize。参数本身只允许自动选择或重载清单中
`status=compatibility/enabled=false` 的匹配整机。不能把这一运行结果计为 B350 真机化支持；
当前 KVM CPU surface 的 SVM、MONITOR/MWAIT、PMU、cache、微码也缺少目标 Ryzen 样机快照闭环。

旧 schema profile 不具备 manifest 绑定，不能用来替代上述兼容授权。即使显式设置
`STRICT_HARDWARE=0`，加载器仍默认拒绝；只有排障时才可再追加
`--allow-legacy-profile`。该选项只表示操作者明确接受“无法验证平台来源”的诊断风险，
严格模式会拒绝它，Dock/安装器等正式生命周期也不应依赖该路径。

旧 schema-1 profile 若来自独立启动盘字段发布前，加载器默认同样 fail closed。确认
profile 的来源并完成备份后，可在启动时显式追加 `--migrate-storage-profile`。该选项
只允许已知旧 revision、完整缺失的启动盘字段和精确历史序号/NQN 元组在内存中迁移；
不会改写 profile，也不会放宽当前 profile 的部分缺失、空值或目录事实绑定。由于
profile 本身不是签名凭据，旧 profile 每次加载都必须继续携带该显式授权。

目录升级另有两项不改变 Guest 身份的自动规范化，不需要
`--migrate-storage-profile`，也不需要重建实例或 `--reroll`：

- `2026-07-19.6` 的精确 Kingston 历史组合会把实际
  `KVR24N17S8/4`、2×4 GiB 拓扑绑定到稳定 module ID，并移除从未暴露给 Guest 的
  无效 2 GiB 候选；
- `2026-07-19.6` 当时唯一的 Samsung 970 PRO component 若完整绑定，
  `BOOT_STORAGE_PART_NUMBER=component-catalog` 会替换为真实零售料号
  `MZ-V7P512BW`；后来加入的 Intel/WD/KIOXIA component 不能伪装成该历史格式。

两项都要求旧字段与当前目录逐项精确匹配，任一字段被修改就 fail closed。`DRY_RUN=1`
只验证并报告，不改文件；下一次非 dry-run 启动在 CPU realize、磁盘、TPM、内存拓扑
和完整 QEMU 参数门禁全部通过后，会先把原文件保存为权限 `0400` 的
`profile.pre-catalog-migration.<原文件SHA-256>`，再原子提交规范化 profile。
若 profile 从加载到提交之间被外部修改，或同名恢复副本的内容、owner、mode 不匹配，
启动会拒绝覆盖。UUID、主板/整机/机箱序列号、DIMM serial、NVMe serial/NQN、MAC
和 TPM 绑定均保持不变。

不要用 `STEALTH_HOST_CPU_VENDOR=GenuineIntel` 在 AMD 宿主强选 Intel bundle，也不要只把
AMD 清单条目改成 `enabled=true`；两种做法都会制造跨厂商或跨芯片组矛盾。

## 2. 构建与静态回归

```bash
# 增量构建 patched QEMU
deploy/tools/build.sh

# 常用构建选项
deploy/tools/build.sh --clean
deploy/tools/build.sh --reconfig
deploy/tools/build.sh --debug
deploy/tools/build.sh --jobs 8

# 本地终端缺包时默认自动安装；CI/后台强制安装须显式授权
deploy/tools/build.sh --install-build-deps
# 完全禁止系统安装与宿主 helper 部署（依赖门禁仍启用）
deploy/tools/build.sh --no-install-build-deps --no-install-host-helpers
# 构建后的宿主 helper 策略与依赖安装互相独立
deploy/tools/build.sh --install-host-helpers
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

## 3. 宿主准备

### 3.1 编译脚本自动维护最小 root helper

`deploy/tools/build.sh` 在 `ninja`、二进制存在性检查及可选 `--verify` 全部成功后，自动调用
`deploy/scripts/setup-host-helpers.sh`。编译脚本必须以普通用户运行，只有安装阶段通过 `sudo`
提权；安装或校验失败会令整个编译入口返回非零，不能把“QEMU 已生成”误认为宿主已可启动。

安装器不是每次启动 VM 执行的调优脚本，而是编译入口内部的安全部署模块，负责：

- 把 `host-performance.sh`、`host-cpu-isolate.sh` 及其 runtime 安装到
  `/usr/local/libexec/qemu-vmate-*`，固定为 `root:root/0755`。
- 生成最小 `NOPASSWD:NOSETENV` sudoers，绝不授权用户可写的 Git 工作区脚本。
- 把本次构建的 QEMU canonical path、device/inode 与 SHA-256 写入 root-owned 信任清单，
  防止同名进程或替换后的二进制进入 CPU 隔离事务。
- 以 `/run/qemu-vmate/host-helper-install.lock` 的 root-owned `flock` 串行化 install/check，
  再在 root-owned staging 中完成权限、内容及 `visudo` 校验；发布时暂时撤下旧 sudoers，
  原子切换版本化 runtime、信任清单和 main helper，任一步失败都在恢复 sudoers 前回滚。
- 对照编译验证结束时的 QEMU device/inode/SHA-256，拒绝在等待 `sudo` 期间被替换的产物；
  安装后立即执行 `check`，复核目录、文件、链接数、权限、sudoers 及 QEMU 摘要。

构建前的 `INSTALL_BUILD_DEPS` 与构建后的 `INSTALL_HOST_HELPERS` 相互独立。本地交互
终端默认补齐缺失构建包并在成功构建后同步 helper，因此重新编译 QEMU
或修改 helper 后只需再次运行 `deploy/tools/build.sh`，不再单独维护安装步骤。CI、容器、
后台 job 和无前台终端任务默认不修改当前宿主；目标机无人值守部署须使用
`--install-host-helpers`（认证不可用时 `sudo -n` 会立即失败），纯构建/打包使用
`--no-install-host-helpers`。不要给用户可写的工作区 installer 配置 NOPASSWD；无人值守
部署应由受控的 root 部署服务执行，并设置 `VMATE_TARGET_UID=<普通用户 UID>`。宿主重启
和普通 VM 启动不需要重新安装。

开发或测试会重链 QEMU 时，把下面三步留到所有并行构建结束后执行；升级 helper ABI 或绑核策略前须安全关闭仍位于 `/vmiso` 的全部 VM，安装器检测到任何活动子分区或进程都会拒绝。第二步只是可选诊断：

```bash
deploy/tools/build.sh --verify --install-host-helpers
sudo -n /usr/local/libexec/qemu-vmate-cpu-isolate preflight  # 可选
deploy/scripts/start-vm.sh <实例号> [启动参数]
```

第一步成功后不要再单独运行会重链 `qemu-system-x86_64` 的 Ninja 目标；否则信任摘要按设计
失效，需要在最终构建后重新执行第一步。

低层脚本只在检查故障或登记仓库之外的 patched QEMU 时手工使用：

```bash
# 只检查当前安装契约
sudo deploy/scripts/setup-host-helpers.sh check

# 高级用法：登记另一份经过审核的 patched QEMU
sudo deploy/scripts/setup-host-helpers.sh install \
  --qemu=/absolute/path/to/qemu-system-x86_64
sudo deploy/scripts/setup-host-helpers.sh check
```

不要编辑 `/usr/local/libexec` 中的安装副本，也不要手工把用户可写的仓库脚本加入
`NOPASSWD`。默认 `HOST_TUNE=1` 和 `CPU_ISOLATE=1` 会在 VM 生命周期内调用安装副本；
安装器本身不会立即修改 governor 或划分 cpuset。

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
# 默认创建 VLAN-aware br0，并安全自动识别唯一物理上联
sudo deploy/scripts/setup-bridge.sh

# 生产模式拒绝 bridge 失败后回落到 10.0.2.x SLIRP
STRICT_STEALTH=1 deploy/scripts/start-vm.sh 1
```

默认 `BRIDGE=br0`，但 `STRICT_STEALTH=0` 为兼容默认；bridge 不存在时可能明确告警并回落到
user-mode NAT。生产验收应显式设置 `STRICT_STEALTH=1`，不要用 NAT 结果代表物理 LAN 行为。
如确实只需旧的普通 bridge，显式运行
`sudo VLAN_TRUNK=0 UPLINK=enp3s0 deploy/scripts/setup-bridge.sh`（按本机接口名替换）。

VLAN access TAP 示例：

```bash
# 首次为单一 VLAN-aware br0 准备 trunk；默认已启用并自动识别唯一物理上联
# 远程执行可能断 SSH，优先用带外控制台
sudo deploy/scripts/setup-bridge.sh

deploy/scripts/start-vm.sh 1 --vlan-id=11
deploy/scripts/start-vm.sh 2 --vlan-id=20
```

探测顺序为唯一默认路由物理口、`br0` 下唯一物理口、唯一 carrier-up 物理口；
不会按 `enp*` 名称猜测，也不会自动选择 Wi-Fi、VLAN/TAP 或多个有线候选。
无法唯一确定时，显式运行
`sudo UPLINK=enp3s0 deploy/scripts/setup-bridge.sh`。

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
`BOOT_STORAGE_SIZE_BYTES=512110190592`。启动器每次用 `qemu-img info` 校验，不按宿主文件
大小猜容量，也不会静默 resize 不匹配的历史磁盘或 base image。

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
| TPM | 2.0：`tpm-state/`；1.2：`tpm12-state/`；共用 `tpm-sock` |
| QMP/HMP | `/tmp/qemu-stealth-<N>.qmp`、`.mon` |
| fb-shm | `/tmp/qemu-stealth-<N>.fb` |

用 `IMAGE_ROOT`、`VMS_DIR` 或 `VM_DIR` 可迁移数据路径；细节见
[可移植性](PORTABILITY.md)。

正式启动 swtpm 时，启动器会把经过 `realpath` 规范化、owner/type/mode 校验的
`tpm-state` 或 `tpm12-state` 路径登记到当前用户的私有 runtime 目录，并以
`platform-binding` 把既有 state 绑定到平台 ID、TPM 版本、前端和 PCR bank。绑定不一致
会保留原密钥并拒绝启动，不会把 BitLocker/Windows Hello 状态原地改成另一种 TPM。之后直接执行
`deploy/scripts/stop-vm.sh <N>` 即可停止使用自定义 `VM_DIR` 的实例，无需重复传入路径。
runtime 文件损坏、变成符号链接或权限向 group/other 开放时，stop 会拒绝模糊匹配和误杀；
没有 runtime 文件的旧 TPM 2.0 实例仍兼容默认 `$VMS_DIR/<N>/tpm-state` 布局。

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
| `STEALTH_PLATFORM_ID` / `--platform-id` | 空 | 可选高级固定；已有 profile 上只断言一致，换平台必须 `--reroll` |
| `ALLOW_PLATFORM_COMPATIBILITY` / `--allow-platform-compatibility` | `0` | 允许宿主自动匹配 compatibility；优先 supported，不关闭其它严格门禁 |
| `ALLOW_LEGACY_PROFILE` / `--allow-legacy-profile` | `0` | 仅配合 `STRICT_HARDWARE=0` 显式诊断无 manifest 绑定旧 profile |
| `ALLOW_STORAGE_PROFILE_MIGRATION` / `--migrate-storage-profile` | `0` | 显式允许已知旧 schema-1 启动盘字段做只读内存迁移 |
| `STEALTH_TSC_POLICY` | `auto` | 有 scaling 用 profile TSC；无 scaling 按宿主实测约束 |
| `CPUS` | `4` | 只允许 `2`/`4`，并须等于所选 2C2T/2C4T/4C4T SKU 的完整线程数 |
| `MEM_TOTAL_MB` | 新 profile `8192` | 2/4/8 GiB 由 manifest 约束；新建默认 2×4 GiB |
| `TPM` | `auto` | 跟随 profile 的主板能力、版本和前端；`1` 强制要求支持，`0` 显式关闭 |
| `HOST_TUNE` | `1` | PPD performance（无 PPD 时回退 performance governor）、`halt_poll`、THP defrag |
| `CPU_FREQ_CAP` | **`0`** | 默认不全局封顶；`--freq-cap` 才按目标 CPU 上限启用 |
| `CPU_ISOLATE` | `1` | 严格启动闸门 + NUMA-aware pinner + 每实例 cgroup cpuset |
| `QEMU_SERVICE_CPUS` | `0` | `--svc-cpu` 分配 1 个辅助线程逻辑 CPU |
| `QEMU_DISK_AIO` | `auto` | 实测选择 `io_uring`→`native`→`threads`，不增加 IOThread |
| `MEM_GUARD` | `1` | 可用内存不足时告警或拒绝；`MEM_FORCE=1` 显式越过硬拒绝 |
| `SDL` / `FB_SHM` | `1` / `1` | 默认本地稳定 SDL 窗口与 fb-shm 同时启用 |
| `STABLE_DISPLAY` | `1` | 默认 `virtio-vga`、无 virgl/blob/hostmem；设 `0` 显式启用 GL |
| `GPU_DISPLAY` | `sdl` | `sdl-egl`/`egl-headless` 显式 opt-in GL，但默认仍为 gl-safe |
| `QEMU_CAP_CHECK` | `1` | 拒绝缺少定制设备属性的 QEMU |
| `STRICT_STEALTH` | `0` | 网络兼容默认；生产应显式设 1 禁止 NAT fallback |
| `PROXY` | `0` | `--proxy` 启用 QMP 原生 multi-client |

`CPU_FREQ_CAP=0` 是有意的默认值：全局 `scaling_max_freq` 会影响管理核和其它 VM，尤其不适合未经评估的高核/双路 E5。
优先用 NUMA/cpuset 放置；只有确认宿主调度策略后才使用 `--freq-cap`。

宿主内存使用单个 `memory-backend-memfd,share=on,prealloc=off` 按需占页，不预留无效 hugepage 池；`share=on` 供 VMI 读取同一份 guest RAM，不改变客体容量。

## 6. 显示与 fb-shm

| 命令 | 本地窗口 | 远程显示 | fb-shm |
|---|---|---|---|
| `start-vm.sh 1` | SDL（稳定、无 GL） | 无 | 开 |
| `start-vm.sh 1 --headless` | 无 | VNC | 开 |
| `start-vm.sh 1 --no-sdl` | 无 | 无 | 开 |
| `start-vm.sh 1 --no-fb-shm` | SDL（稳定、无 GL） | 无 | 关 |
| `start-vm.sh 1 --gpu-sdl-egl` | SDL/GL（显式 opt-in） | 无 | 开 |
| `start-vm.sh 1 --gpu-headless` | 无 | EGL rendernode（显式 opt-in） | 开 |

默认 `STABLE_DISPLAY=1` 使用最小 PCI 显示面；`STABLE_DISPLAY=0`、`--gpu-sdl-egl` 或 `--gpu-headless` 启用 GL-safe，不带 blob/hostmem，但 guest 仍能看到 virtio `VIRGL/CONTEXT_INIT` feature，并非与 stable 完全相同。只有显式追加 `--gpu-zerocopy` 才重排 guest PCI BAR：MSI-X 从 BAR4 移到 BAR1，BAR4/5 变为 host-visible window，并且必须保留 fb-shm；`GPU_HOSTMEM` 只接受 256M..8G 内 2 的幂。显式 `STABLE_DISPLAY=1` 优先：`sdl-egl` 降级为普通 SDL，`egl-headless` 拒绝启动。用户曾实测旧 GL+zero-copy 配置可稳定运行，因此该隔离策略不能单独证明它是 DNF 退出根因。
无 `DISPLAY` 且非交互终端时，默认 SDL 会自动关闭，仅保留 fb-shm。消费端示例：

```bash
build/qemu-fb-shm-stream \
  --sock /tmp/qemu-stealth-1.fb \
  --output /tmp/vm1.mp4 \
  --encoder libx264 --preset veryfast --mode auto
```

显式 GL 即使不带 blob/hostmem，renderer 仍可尝试从普通 texture 导出 GPU handle；失败回落 SHM。客体始终是 virtio 显示设备，不能把 GPU handoff、AIB 逻辑身份或 carrier 当作物理 NVIDIA/AMD GPU 证据。

## 7. Profile 与内存变更

```bash
# 查看，不要 source
sed -n '1,220p' /home/ubuntu/images/vms/1/profile

# 使用 manifest 允许的配置；重启后生效
deploy/scripts/set-vm-memory.sh 1 4G
deploy/scripts/set-vm-memory.sh 1 8G

# 原子重抽唯一值；无 TPM state 时也可重新选平台
deploy/scripts/start-vm.sh 1 --reroll
```

`--ram=`/`RAM=` 是本次启动覆盖，仍必须属于平台允许值。长期变更应写入 profile，避免容量
在重启间漂移。严格模式拒绝过时 manifest revision 和 legacy profile；reroll 会改变 UUID、
序列号和 MAC，可能触发 Windows 重新激活，应先备份并在测试实例验证。已有 TPM state
时会在生成候选前拒绝，避免新主板身份复用旧密钥；如需更换身份、主板型号或 TPM
版本，应新建 instance 或走经过验证的密钥迁移/归档。旧 `reroll-identity.sh` 已改为
非破坏性门禁，不再删除 profile。

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

E5 v1/v2/v3/v4 宿主分别映射到 Sandy/Ivy/Haswell/Haswell 家用 DDR3 Guest
完整组合；E5 本身从不作为 Guest CPU。E5 v3/v4 默认正常池为 G3220 2C2T、
i3-4130 2C4T、i5-4570 4C4T，不需要 `--allow-platform-compatibility`；
E5 v1/v2 仍通过该参数进入兜底池。无 TSC scaling 时正常池会省略不可能的
`tsc-freq`，但仍用 `enforce=on` 做真实 KVM realize。E5-2696 v4 /
JGINYUE X99-TI D4 PLUS 已实测三个型号均可无 warning 创建 vCPU；该结果不替代
客体枚举和长稳，E5 v3 每次启动仍以本机 KVM 预检为准。

单路 X99 通常只有一个宿主 NUMA 场景；双路 C612 每台 VM 必须完整落在同一 `(NUMA node, physical package)` 域，容量不足严格拒绝。ABI5 的 `/vmiso` 父分区只保存所有 VM 的 CPU/node 并集，每台 QEMU 使用 `/vmiso/vm-N` exact child。VM 数量和实例槽位不预配置：helper 每次在全局锁内动态枚举全部 `vm-N`，按当前剩余唯一逻辑 CPU 和 Guest packing 决定能否接纳下一台；实例号允许 1–10 位正整数。
严格模式先由 guard/sentinel 锚定 `-S` QEMU 独立进程组，父 shell 只在 pinner 完成 `ARMED → RUNNING`（child/NUMA/vCPU 绑核及 QMP `cont`）后移交；FAIL/EOF/超时或移交前父代 SIGKILL 都会终止该组。`-cpu/-smp/-numa` 等 guest 身份参数不变，实例锁保持到 QEMU 退出并完成 CPU release。
多 NUMA 时 helper 在 QEMU 停止态用 `migratepages` 把既有页迁至最终 node，再收窄 child `cpuset.mems`；工具缺失或迁移不完整都会严格失败。
“22C/44T、单 node、预留 3 个管理核”时剩余 19C/38T。2C2T、2C4T、4C4T 的 exact 分别只有 2、4、4 条逻辑 CPU；单台 2C2T/4C4T 的 vCPU 仍分处 2/4 颗物理核，2C4T 使用两颗完整 SMT2 核。不同 VM 可使用同核不同 sibling，但绝不复用同一逻辑 CPU。无 service CPU 的同型上限依次为 19/9/9 台，service=1 时为 12/7/7 台；混合池先满足 `2×2C2T+4×2C4T+4×4C4T+service总数≤38`，再由 helper 检查单 VM 物理核形状。VM 数量本身不固定。
运行时以 sysfs 和单一 NUMA/package 域为准；多域必须逐域按逻辑线程预算和每台 Guest 的 distinct-core/SMT2 约束装箱，禁止跨域拼接。默认 service=0 时 QEMU 辅助线程只能在本实例的 2/4/4 条 exact logical CPU 内与 vCPU 竞争；未选 sibling 可被宿主或其它 VM 使用，因此仍须在目标 E5 实测交互尾延迟。

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

## 10. 当前 GPU 文档与历史资料

`STEALTH-WORKFLOW.md`、`STEALTH-APPROACHES.md` 和 `ACE-SHALLOW-STEALTH.md` 描述当前浅层 GPU 流程：全局只有一个 `1AF4:1050 + stock VioGpuDod` devnode；PnP HardwareID 为规范逻辑首项 + 完整物理尾项，真实 InstanceId/BDF/Service/Driver 不变；NVAPI 主 PCI 键用物理 carrier 跨接口去重，external/AIB/型号保持逻辑 NVIDIA。该投影不增加显卡设备、显存或性能，目录也不生成 GPU serial。
旧审计中的自签驱动、EfiGuard、主 PCI ID 覆盖或真实 NVIDIA 转发器只代表历史快照，不能覆盖当前 manifest、启动器和上述三份文档。
