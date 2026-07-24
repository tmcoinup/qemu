# PORTABILITY — host 迁移兼容说明

本页记录把 VM bundle 迁移到其它 host 时必须保持的约束。原则是：路径和二进制位置可以变，guest 可见的真机画像不能静默降级。

## 主要改动

### 1. VM 数据根目录可配置

默认仍使用历史路径：

```bash
IMAGE_ROOT=/home/ubuntu/images
VMS_DIR=$IMAGE_ROOT/vms
VM_DIR=$VMS_DIR/<INSTANCE>
```

迁移到新 host 或新磁盘时只需要改 `IMAGE_ROOT`：

```bash
IMAGE_ROOT=/mnt/vm-images ./deploy/scripts/start-vm.sh 1 --proxy
```

也可以只覆盖某台 VM：

```bash
VM_DIR=/mnt/fastssd/vm1 ./deploy/scripts/start-vm.sh 1 --proxy
```

`DISK` 仍可单独覆盖；未指定时默认是 `$VM_DIR/disk.qcow2`。

base 生命周期入口也支持显式路径。clone 会经过 `sudo`，因此迁移宿主时优先使用
CLI flag，不依赖 sudo 是否保留调用者环境：

```bash
deploy/scripts/seal-base.sh 1 win10-ltsc-v1 \
  --image-root=/mnt/vm-images

sudo deploy/scripts/clone-from-base.sh win10-ltsc-v1 2 \
  --vms-dir=/mnt/vm-images/vms \
  --base-dir=/mnt/vm-images/vms/_base
```

clone 要求 `VMS_DIR` 是最终 VM 用户拥有的真实目录；这保证同一路径不会被不同 UID
分别用两把 per-user 生命周期锁并发操作。seal 后的 base 为 `root:root/0444`；
clone 会用 hard-link 在 `VM_DIR/.base.qcow2` 固定 backing inode，所以
`BASE_DIR` 与 `VMS_DIR` 必须在同一文件系统。迁移时应整体复制 VMS tree；
不支持让 thin overlay 跨文件系统引用一个可被替换的外部 base 路径。

单独搬运 standalone base 时，`scp`、浏览器下载、Windows/移动介质造成的 owner、
mode 变化不需要手工修复。把文件复制到目标 Linux `BASE_DIR` 后正常执行 `sudo
clone-from-base.sh`，clone 会校验传输已结束并自动密封。NTFS/CIFS/DrvFS 若不能
可靠保存 Unix owner/mode，必须先复制到 Linux 文件系统；实例启动时不会放宽 pin。

`VM_DIR` 必须是当前用户所有的私有真实目录，不能是符号链接。启动 swtpm 前，
`tpm-state` 会被规范化为 canonical path 并登记在当前用户的私有 runtime 目录；
因此关机不需要再次提供原路径：

```bash
deploy/scripts/stop-vm.sh 1 --wait=120
```

stop/reaper 会同时验证 runtime 文件、state 目录 owner/type/mode 及 swtpm 的
`/proc/<pid>/exe`/argv，只有全部指向同一个 canonical state_dir 才会发信号。
若迁移时直接复制了正在运行主机的临时 runtime 文件，应删除该临时文件并在新主机
重新启动实例；不要手工把 runtime 文件改成宽权限或软链接。未登记的旧版默认布局仍按
`$VMS_DIR/<INSTANCE>/tpm-state` 兼容解析。

### 2. QEMU / qemu-img 可配置

迁移 host 后不要用系统自带 stock QEMU。启动器默认使用仓库内构建产物：

```bash
QEMU=build/qemu-system-x86_64
QEMU_IMG=build/qemu-img
```

如果二进制放在其它位置：

```bash
QEMU=/opt/qemu-stealth/bin/qemu-system-x86_64 \
QEMU_IMG=/opt/qemu-stealth/bin/qemu-img \
IMAGE_ROOT=/mnt/vm-images \
./deploy/scripts/start-vm.sh 1 --proxy
```

seal/clone 不会在显式路径拼错时静默回退系统工具：

```bash
deploy/scripts/seal-base.sh 1 win10-ltsc-v1 \
  --qemu-img=/opt/qemu-v11/bin/qemu-img

sudo deploy/scripts/clone-from-base.sh win10-ltsc-v1 2 \
  --qemu=/opt/qemu-v11/bin/qemu-system-x86_64 \
  --qemu-img=/opt/qemu-v11/bin/qemu-img
```

clone 会以最终 VM 普通用户执行与 start 相同的完整设备能力预检，stock QEMU 即使
能通过 CPU smoke，也会在创建 overlay 前被拒绝。

### 3. 启动前 QEMU 能力预检

`start-vm.sh` 会 source `lib/sv-portability.sh`，默认执行 `QEMU_CAP_CHECK=1`。它会检查 patched QEMU 是否支持以下 guest-visible stealth 属性：

- NVMe：`x-identity-profile` / `model-number` / `firmware-rev`
- virtio-vga：EDID 字符串、`edid-managed-timing-version` 和 PCI subsystem override
- USB HID：`vendorid` / `productid` / `manufacturer` / `product`
- PCIe root-port：平台 PCI ID 和链路属性 override
- qemu-xhci：固定上游行为身份，不提供 PCI ID override
- fb-shm / memfd object

缺失时 fail-fast，避免误用 stock QEMU 让 guest 看到 Red Hat NVMe、默认显示器或默认 USB 设备。只有非隐身调试才建议跳过：

受管显示启动固定传入 `edid-managed-timing-version=1`。该属性默认值为 `0`，
保持普通 QEMU 调用方兼容；当前实现只接受显式版本 `1`，其它非零版本会在设备
realize 阶段拒绝。这样旧 patched QEMU 即使已有 secondary 分辨率属性，也无法
冒充包含当前多品牌精确时序表的构建。

```bash
QEMU_CAP_CHECK=0 ./deploy/scripts/start-vm.sh 1 --no-bridge
```

### 4. 启动盘总线与 I/O 路径保持稳定

不要给 emulated NVMe 加 `iothread=...`。当前 NVMe DMA helper 需要 BlockBackend 留在主 AioContext；强行迁移到 IOThread 会触发 `dma_blk_cb` 断言。

当前设备身份稳定参数是（文件 AIO 由启动前 active-read 自动选择）：

```bash
-drive file=...,if=none,id=bootdisk0,format=qcow2,cache=none,aio=<io_uring|native|threads>,discard=unmap
-device nvme,...,drive=bootdisk0,x-identity-profile=...,model-number=...,firmware-rev=...
```

`QEMU_DISK_AIO=auto` 不创建临时盘，依次用候选后端实际读取 QEMU ELF；不可用时
回退 `threads`。显式指定后端则 fail closed。三种模式均不改变 Guest 设备，
也不添加 IOThread；本地前台构建会自动补齐 `liburing-dev` 与 `libaio-dev`。

`x-identity-profile` 把所选 Samsung、Intel、Western Digital 或 KIOXIA 型号的
model、firmware、PCI/subsystem、OUI、链路和序列格式作为一个整体校验；旧
`use-samsung-id=on` 只作为历史 Samsung profile 的命令行兼容入口。

启动总线由主板清单的 `NVME_BOOT_SUPPORTED` 决定，而不是由宿主或 Guest CPU 名称
推断。值为 `1` 时继续使用上述 NVMe 路径；H61/B75/H81/AM3 等值为 `0` 的家用
compatibility bundle 会自动切换为：

```bash
-drive file=...,if=none,id=bootdisk0,format=qcow2,cache=none,aio=<auto-selected>,discard=unmap
-device ide-hd,bus=ide.2,unit=0,drive=bootdisk0,model=...,serial=...,ver=...,rotation_rate=1
```

`ide.0`、`ide.1` 分别保留给主安装 ISO 和驱动 ISO，避免安装时与系统盘争用同一
AHCI 端口。

SATA 路径从独立的 `storage-compatibility.json` 等概率选择一套 512GB 完整组合：

- 840 PRO：`MZ-7PD512BW` / `DXM06B0Q`
- 850 PRO：`MZ-7KE512BW` / `EXM04B6Q`
- 860 PRO：`MZ-76P512BW` / `RVM02B6Q`

选择只在首次创建 profile 或显式 reroll 时发生。`BOOT_STORAGE_COMPONENT_ID`、
`BOOT_STORAGE_MODEL`、`BOOT_STORAGE_PART_NUMBER`、`BOOT_STORAGE_FIRMWARE`、
`BOOT_STORAGE_SIZE_BYTES`、`BOOT_STORAGE_SERIAL` 和 `BOOT_STORAGE_INTERFACE`
随后原子持久化；普通重启按已保存 ID 重建并逐字段校验，不能重新抽签。
`PLATFORM_BOOT_MODEL`/`PLATFORM_BOOT_FIRMWARE` 在 SATA 分支固定为
`storage-compatibility-pool` 策略标记，不是 Guest 可见型号或固件。

SATA 启动参数、ATA serial 与 qcow2 容量完全使用独立 `BOOT_STORAGE_*`，不再复用
`NVME_COMPONENT_ID`、`NVME_MODEL`、`NVME_FIRMWARE`、`NVME_SIZE_BYTES` 或
`NVME_SERIAL`。不得把 970 PRO 型号挂到 SATA，也不得忽略 profile 的
`PLATFORM_BOOT_STORAGE` 和 `PLATFORM_BOOT_STORAGE_POOL_ID`。

840/850/860 PRO 条目的型号、料号、接口及固件来自 Samsung 官方产品页和固件目录，
并记录 SATA 1.5/3/6 Gb/s 向下兼容能力；当前没有对应实物的 ATA IDENTIFY capture。
因此这些条目只承诺厂商文档覆盖的字段，不应描述成样机 Identify 原始转储。

## 新 Ubuntu host 的额外环境

VM 运行、TPM、bridge、patched QEMU 构建、固件重建、完整回归与 Windows
交叉打包使用不同依赖组。按用途安装并执行自检，统一见
[开发与跨平台验证依赖](DEVELOPMENT-DEPENDENCIES.md)；不要把缺少可选打包工具误判成
Linux VM 运行环境不可用。

Debian/Ubuntu 本地前台运行 `deploy/tools/build.sh` 时会自动补齐缺失的源码构建
包；CI、容器、后台和离线环境应预置构建组并使用 `--no-install-build-deps`。
该机制不安装 bridge、VM 运行或固件重建依赖。

持久 bridge 推荐沿用已由 netplan 使用的 NetworkManager，并在迁移前确认状态：

```bash
systemctl is-active NetworkManager
nmcli -t -f NAME,TYPE,DEVICE connection show --active
ip -4 route show default
```

Ubuntu Server 若由 systemd-networkd 管理，不要通过 SSH 临时切换 renderer；脚本在
NetworkManager 未运行时只能建立非持久 iproute2 bridge。需要切换时先准备本地或带外控制台。
确认切换方案后再安装 `network-manager` 并更新 netplan renderer。
迁移后必须重新确认 KVM 权限与默认启用的 cgroup v2/cpuset：

```bash
test -r /dev/kvm && test -w /dev/kvm
test -c /dev/net/tun
id -nG | tr ' ' '\n' | grep -Fx kvm
stat -fc %T /sys/fs/cgroup
grep -w cpuset /sys/fs/cgroup/cgroup.controllers
```

需要时执行 `sudo usermod -aG kvm "$USER"`，注销并重新登录后再测；不能只在当前 shell
临时 `newgrp` 后把部署视为完成。

`setup-bridge.sh` 默认 `VLAN_TRUNK=1`，省略参数时会从唯一默认路由物理口、
`br0` 的唯一物理 port、唯一 carrier-up 物理口依次探测上联。不会按 `enp*` 名称猜测；
多个候选时必须显式使用 `sudo UPLINK=enp3s0 deploy/scripts/setup-bridge.sh`。
它在没有 `qemu-bridge-helper` 时会自动安装 `qemu-system-common`，其余依赖应由上面的
环境步骤预先安装。

两个宿主安装器会持久修改以下 root-owned 状态，迁移、备份和排障时应一并知道：

| 安装器 | 持久状态 |
|---|---|
| `setup-bridge.sh` | `/etc/modules-load.d/qemu-stealth.conf`（`tun`/`bridge`/`8021q`） |
| `setup-bridge.sh` | `/etc/qemu/bridge.conf`、`qemu-bridge-helper` capability/兼容链接 |
| `setup-bridge.sh` | `/usr/local/libexec/qemu-stealth-vlan-{tap,down}` |
| `setup-bridge.sh` | `/etc/qemu/stealth-vlan.conf`、`/etc/sudoers.d/qemu-stealth-vlan` |
| `setup-bridge.sh` | NetworkManager 的 `br0`、`br0-slave-<上联>` profile；原物理口 active profile 会停用并关闭 autoconnect |
| `setup-host-helpers.sh` | `/usr/local/libexec/qemu-vmate-host-performance`、`qemu-vmate-cpu-isolate*`、QEMU 信任清单 |
| `setup-host-helpers.sh` | `/etc/sudoers.d/qemu-vmate-host` |

这些文件不能从旧 host 直接盲拷：UID、上联网卡名、QEMU canonical path/inode/hash 都可能不同。
应在新 host 从当前仓库重新运行两个安装器。

## 迁移 checklist

1. 按上节安装运行与构建环境，然后在新 host 构建 patched QEMU：

```bash
deploy/tools/build.sh --verify
```

成功构建会在本地交互终端同步 host performance/CPU isolate helper；无人值守任务需显式
使用 `deploy/tools/build.sh --verify --install-build-deps --install-host-helpers`；
受管/离线环境则预置依赖并传 `--no-install-build-deps`。

若复制的是另一台机器的预编译动态二进制，必须先检查动态库并在新 host 重新登记信任：

```bash
ldd /absolute/path/qemu-system-x86_64 | grep 'not found'  # 必须无输出
sudo deploy/scripts/setup-host-helpers.sh install \
  --qemu=/absolute/path/qemu-system-x86_64
sudo deploy/scripts/setup-host-helpers.sh check
```

2. 准备 VM 数据目录：

```bash
# 先在旧 host 停止并确认所有待迁移实例已退出，再复制 qcow2。
deploy/scripts/stop-vm.sh 1 --wait=120
sudo mkdir -p /mnt/vm-images/vms
sudo rsync -aHS --numeric-ids /home/ubuntu/images/vms/ /mnt/vm-images/vms/
stat -c '%u:%g %a %h %n' \
  /mnt/vm-images/vms/_base/*.qcow2 \
  /mnt/vm-images/vms/*/.base.qcow2
```

迁移必须保留 root owner 和 hard-link（`-H`）；上面的 base/pin 应为 `0:0 444`，
同一 base 与各实例 pin 的 link count 应大于 1。若目标宿主 UID/GID 规划不同，
只调整普通实例目录的用户 owner，不得把 base/pin 改回普通用户所有。

3. 检查并初始化默认 VLAN-aware bridge 和 OVMF 依赖：

```bash
sudo deploy/scripts/setup-bridge.sh
ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
ip -d link show br0
bridge vlan show
```

4. dry-run 验证路径和 QEMU 能力：

```bash
IMAGE_ROOT=/mnt/vm-images \
DRY_RUN=1 TPM=0 HOST_TUNE=0 \
./deploy/scripts/start-vm.sh 1 --no-sdl --no-fb-shm --no-bridge
```

5. 正式启动：

```bash
IMAGE_ROOT=/mnt/vm-images ./deploy/scripts/start-vm.sh 1 --proxy
```

## 测试

本次新增的轻量回归测试：

```bash
deploy/scripts/tests/test_start_vm_perf.sh
```

覆盖内容：

- dry-run 不生成 `nvme,iothread=...`
- Samsung NVMe identity/model/firmware/serial 仍在
- QEMU 能接受 Samsung NVMe 属性
- `IMAGE_ROOT` dry-run 不落盘且路径正确
