# USAGE — 操作参考

主流程在 [STEALTH-WORKFLOW.md](STEALTH-WORKFLOW.md)。本文件是命令参考。

## 1. 前置依赖（一次性）

```bash
sudo apt install -y build-essential ninja-build python3-venv python3-pip \
    python3-setuptools pkg-config libglib2.0-dev libpixman-1-dev \
    libsdl2-dev libspice-server-dev libvirglrenderer-dev libepoxy-dev \
    libslirp-dev libseccomp-dev libssh-dev ovmf \
    socat jq imagemagick ffmpeg sshpass faketime osslsigncode chntpw libguestfs-tools
```

必备文件：
- `/home/ubuntu/images/win10.iso` 或 `/home/ubuntu/images/win10_ltsc.iso`
- `/usr/share/OVMF/OVMF_CODE_4M.fd` / `OVMF_VARS_4M.fd`（启动器首跑会拷贝模板到 `/home/ubuntu/images/vms/<N>/ovmf-vars.fd`）

## 2. 构建 QEMU

```bash
deploy/tools/build.sh                 # 增量构建
deploy/tools/build.sh --clean         # 先 rm -rf build/ 再从零编译
deploy/tools/build.sh --reconfig      # 保留 build/ 但强制重跑 configure
deploy/tools/build.sh --debug         # 带调试符号
deploy/tools/build.sh --jobs 8        # 限制 ninja 并行度
deploy/tools/build.sh --verify        # 完后跑 verify-stealth.sh
```

输出：`build/qemu-system-x86_64`。

## 3. 主机调优（建议每次开机跑一次）

```bash
sudo deploy/scripts/host-performance.sh
# governor=performance / hugepages / THP=madvise / KVM halt_poll=500µs /
# 停 irqbalance / NVMe scheduler=none
```

## 4. 桥接（多 VM 上 LAN）

```bash
# 隔离 br0（host 和 guest 互通，但 guest 拿不到上游 LAN 的 IP）
sudo deploy/scripts/setup-bridge.sh

# 把物理 NIC 接入 br0，guest 拿上游 DHCP（推荐）
sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh
```

## 5. 启动器 (`start-vm.sh`)

```bash
# 最简（90% 情况）
deploy/scripts/start-vm.sh 1            # instance 1
deploy/scripts/start-vm.sh 2            # instance 2

# 装系统时挂 ISO
deploy/scripts/start-vm.sh 1 --iso=/home/ubuntu/images/win10_ltsc.iso

# 反正向 OOBE 自动跳过：再挂一张 autounattend 副 ISO
EXTRA_ISO=/home/ubuntu/images/autounattend-vm2.iso \
    deploy/scripts/start-vm.sh 1 --iso=/home/ubuntu/images/win10_ltsc.iso
```

INSTANCE 用位置参数即可（`./start-vm.sh 2`），同时设 `INSTANCE=` 环境变量也允许，但若两者不一致会警告并以位置参数为准。

| 变量/标志 | 默认 | 说明 |
|---|---|---|
| 位置参数 N | 1 | instance 编号；决定磁盘/profile/socket/端口 |
| `BRIDGE` | `br0` | 桥接网卡；不存在/无授权时自动回退到 user-mode NAT |
| `--no-bridge` | - | 强制走 user-mode NAT（10.0.2.0/24） |
| `STABLE_DISPLAY` | **1** | `virtio-vga` 无 GL，规避 virgl BSOD；ACE/腾讯反作弊友好 |
| `GPU_SELFSIGNED` | **0** | 0 = PCI 主 ID 留 `1AF4:1050` + subsys 改 NVIDIA `1C8110DE`，搭配 stock virtio-win + apply-gpu-spoof.ps1 = 通过 ACE。1 = 把主 ID 也改 `10DE:1C81`，需要 patched viogpudo + 伪 NVIDIA CA，**ACE 会判异常 13-131106-0** |
| `USB_RELATIVE_MOUSE` | 0 | 1 = `usb-mouse` 相对坐标（更像真鼠）；默认 `usb-tablet` 绝对坐标 |
| `HEADLESS` | 0 | 1 = `-display none -vnc 127.0.0.1:N-1`，无 SDL 窗口 |
| `RAM` | 4096 | 单位 MB（4GB 双通道 = 2×2GB） |
| `MEM_PER_DIMM_MB` | RAM/2 | DIMM 总量自动除 2 凑双通道 SPD |
| `DISPLAY` | `:0` | X11 显示，未设默认本地 :0；HEADLESS=1 时忽略 |
| `EXTRA_ISO=PATH` | - | 副 CDROM（autounattend.xml / 驱动盘 等） |
| `--iso=PATH` | - | 主启动 ISO（装系统） |
| `--reroll` | - | 删掉 `vms/<N>/profile` 重新随机一次硬件身份 |
| `CPU_MODEL` | profile 写入 | `Ryzen3-1200`（默认）/ `Ryzen3-2300X`（Win11 LTSC 兼容）。第一次 reroll 时持久化到 profile，之后不用每次设 |

每个 INSTANCE 的资源分配：
- 磁盘：`/home/ubuntu/images/vms/<N>/disk.qcow2`（不存在则创建空白 512GB）
- profile：`/home/ubuntu/images/vms/<N>/profile`
- OVMF NVRAM：`/home/ubuntu/images/vms/<N>/ovmf-vars.fd`
- QMP socket：`/tmp/qemu-stealth-<N>.qmp`
- HMP socket：`/tmp/qemu-stealth-<N>.mon`
- VNC 显示：`<N-1>`（端口 5900+N-1）
- SSH 转发：`127.0.0.1:1002<N+2>`
- RDP 转发：`127.0.0.1:1338<N+8>`

## 6. 一键全套 stealth

见 [STEALTH-WORKFLOW.md](STEALTH-WORKFLOW.md)。两步：

```bash
# Step 1 (guest 内, 首次)
irm http://<host-on-br0>:8765/vm-bootstrap.ps1 | iex

# Step 2 (host)
deploy/scripts/install-stealth.sh <INSTANCE>
```

## 7. 多 VM

每个 INSTANCE 独立装。比如：

```bash
# Terminal A (装 VM1，挂 autounattend 全自动)
EXTRA_ISO=/home/ubuntu/images/autounattend-vm2.iso \
    deploy/scripts/start-vm.sh 1 --iso=/home/ubuntu/images/win10_ltsc.iso

# Terminal B (装 VM2)
EXTRA_ISO=/home/ubuntu/images/autounattend-vm2.iso \
    deploy/scripts/start-vm.sh 2 --iso=/home/ubuntu/images/win10_ltsc.iso

# 装好后给两个分别跑一次 stealth 安装
deploy/scripts/install-stealth.sh 1
deploy/scripts/install-stealth.sh 2

# 同时跑（生产，无窗口）
HEADLESS=1 nohup deploy/scripts/start-vm.sh 1 > /tmp/qemu1.log 2>&1 &
HEADLESS=1 nohup deploy/scripts/start-vm.sh 2 > /tmp/qemu2.log 2>&1 &
```

注意 RAM：每台默认 4GB（2×2GB 双通道），宿主要够。

## 7.1. 基础镜像克隆（快速创建新 VM）

适合先装好 1 台「干净系统 + 浅层 stealth」当模板，后续不再走 ISO 装系统：

```bash
# 把已经装好的 instance 2 固化为 base（VM 必须先关机）
deploy/scripts/seal-base.sh 2 win10-ltsc-shallow
# -> /home/ubuntu/images/vms/_base/win10-ltsc-shallow.qcow2 （只读）

# 用 base 克隆出新 instance 4（增量盘，硬件身份重新随机）
deploy/scripts/clone-from-base.sh win10-ltsc-shallow 4
# -> /home/ubuntu/images/vms/4/disk.qcow2  (qcow2 backed by base)
# -> /home/ubuntu/images/vms/4/profile     (新随机 CPU/主板/GPU/MAC)

# 直接启动
deploy/scripts/start-vm.sh 4
```

或不通过 seal/clone，直接在 `start-vm.sh` 加 `BASE_IMAGE=`：

```bash
BASE_IMAGE=/home/ubuntu/images/vms/_base/win10-ltsc-shallow.qcow2 \
    deploy/scripts/start-vm.sh 5
# 首次启动前自动建增量盘
```

⚠️ 没有 sysprep 的话克隆出的 VM 与 base 共享 SID/MachineGUID；
单机用没问题，多机并发 / 域加入会冲突。需要彻底干净就在 base 里跑 `sysprep /generalize /oobe` 后再 seal-base.sh。

## 8. 停机

```bash
deploy/scripts/stop-vm.sh <INSTANCE>
# = ACPI shutdown → 等 30s → QMP quit → 再等 5s → SIGTERM → SIGKILL
```

## 9. 重置硬件身份

```bash
deploy/scripts/reroll-identity.sh <INSTANCE>
# 或单次：deploy/scripts/start-vm.sh <N> --reroll
```

## 10. QMP / HMP 调试

```bash
# QMP（JSON）：截图、发按键、savevm/loadvm、query-* 等
deploy/scripts/qmp-frame.sh <N> screenshot /tmp/vm.png
deploy/scripts/qmp-frame.sh <N> sendkey ctrl-alt-del

# HMP（人话）
socat - unix-connect:/tmp/qemu-stealth-<N>.mon
(qemu) info status
(qemu) info pci
```

## 11. RDP

```bash
deploy/scripts/rdp-connect.sh <N>
# 等价于 xfreerdp /v:127.0.0.1:1338<N+8> /u:Administrator /p:123456 /size:1600x900
```

## 12. 自检

```bash
deploy/scripts/verify-stealth.sh
# 离线扫源码 + 二进制，检查 CPUID / 字符串 / SMBIOS 是否符合预期
```

## 13. 故障排查

详见 [STEALTH-WORKFLOW.md](STEALTH-WORKFLOW.md) 第 6 节，以及 [DEBUG.md](DEBUG.md)。

常见操作：

```bash
# 抓 guest 内 minidump
sshpass -p 123456 scp Administrator@<guest>:'C:/Windows/Minidump/*.dmp' /tmp/

# 简易解析 dump (host)
deploy/efiguard/analyze-minidump.sh /tmp/<dump>.dmp

# offline 改 ESP（guest 关机后）
sudo qemu-nbd --connect=/dev/nbd0 /home/ubuntu/images/vms/<N>/disk.qcow2
sudo mount /dev/nbd0p1 /mnt/esp
# ... 改文件 ...
sudo umount /mnt/esp
sudo qemu-nbd --disconnect /dev/nbd0

# offline 改注册表 (Windows partition is /dev/nbd0p3)
sudo mount /dev/nbd0p3 /mnt/winsys
sudo hivexsh -w /mnt/winsys/Windows/System32/config/SYSTEM
> cd ControlSet001\Enum\PCI\...
```
