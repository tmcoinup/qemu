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
- `/usr/share/OVMF/OVMF_CODE_4M.fd` / `OVMF_VARS_4M.fd`（启动器首跑会拷贝模板到 `/home/ubuntu/images/ovmf-vars-<N>.fd`）

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

## 5. 启动器 (`win10-ryzen3-stealth.sh`)

```bash
# 完整形式（环境变量 + 位置参数）
DISPLAY=:1 INSTANCE=<N> BRIDGE=br0 \
    [STABLE_DISPLAY=1] [GPU_SELFSIGNED=1] [HEADLESS=1] \
    deploy/scripts/win10-ryzen3-stealth.sh [--iso=PATH] [--reroll]
```

| 变量/标志 | 默认 | 说明 |
|---|---|---|
| `INSTANCE` | 1 | 多 VM 区分；决定磁盘/profile/socket/端口 |
| `BRIDGE` | (unset) | 设为 `br0` 走桥接；未设则走 user-mode NAT |
| `STABLE_DISPLAY` | 0 | 1 = `virtio-vga`（无 GL），避开 virgl BSOD；DNF 用 WARP 仍能玩 |
| `GPU_SELFSIGNED` | 0 | 1 = 把 PCI VEN/DEV 也覆盖到 `0x10DE/0x1C81`；要求 guest 已装好自签 viogpudo |
| `USB_RELATIVE_MOUSE` | 0 | 1 = `usb-mouse` 相对坐标（更像真鼠）；默认 `usb-tablet` 绝对坐标 |
| `HEADLESS` | 0 | 1 = `-display none -vnc 127.0.0.1:N-1`，无 SDL 窗口 |
| `RAM` | 8192 | 单位 MB |
| `MEM_PER_DIMM_MB` | RAM/2 | DIMM 总量自动除 2 凑双通道 SPD |
| `--iso=PATH` | - | 启动从 ISO（装系统） |
| `--reroll` | - | 删掉 `stealth-inst<N>.profile` 重新随机一次硬件身份 |

每个 INSTANCE 的资源分配：
- 磁盘：`/home/ubuntu/images/win10-inst<N>.qcow2`（不存在则创建空白 512GB）
- profile：`/home/ubuntu/images/stealth-inst<N>.profile`
- OVMF NVRAM：`/home/ubuntu/images/ovmf-vars-<N>.fd`
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
# Terminal A (装 VM1)
DISPLAY=:1 INSTANCE=1 BRIDGE=br0 STABLE_DISPLAY=1 \
    deploy/scripts/win10-ryzen3-stealth.sh --iso=/path/to/iso

# Terminal B (装 VM2)
DISPLAY=:1 INSTANCE=2 BRIDGE=br0 STABLE_DISPLAY=1 \
    deploy/scripts/win10-ryzen3-stealth.sh --iso=/path/to/iso

# 装好后给两个分别跑一次 stealth 安装
deploy/scripts/install-stealth.sh 1
deploy/scripts/install-stealth.sh 2

# 同时跑（生产）
DISPLAY=:1 INSTANCE=1 BRIDGE=br0 GPU_SELFSIGNED=1 STABLE_DISPLAY=1 \
    nohup deploy/scripts/win10-ryzen3-stealth.sh > /tmp/qemu1.log 2>&1 &

DISPLAY=:1 INSTANCE=2 BRIDGE=br0 GPU_SELFSIGNED=1 STABLE_DISPLAY=1 \
    nohup deploy/scripts/win10-ryzen3-stealth.sh > /tmp/qemu2.log 2>&1 &
```

注意 RAM：每台默认 8GB，宿主要够。

## 8. 停机

```bash
deploy/scripts/stop-vm.sh <INSTANCE>
# = ACPI shutdown → 等 30s → QMP quit → 再等 5s → SIGTERM → SIGKILL
```

## 9. 重置硬件身份

```bash
deploy/scripts/reroll-identity.sh <INSTANCE>
# 或单次：deploy/scripts/win10-ryzen3-stealth.sh <N> --reroll
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
sudo qemu-nbd --connect=/dev/nbd0 /home/ubuntu/images/win10-inst<N>.qcow2
sudo mount /dev/nbd0p1 /mnt/esp
# ... 改文件 ...
sudo umount /mnt/esp
sudo qemu-nbd --disconnect /dev/nbd0

# offline 改注册表 (Windows partition is /dev/nbd0p3)
sudo mount /dev/nbd0p3 /mnt/winsys
sudo hivexsh -w /mnt/winsys/Windows/System32/config/SYSTEM
> cd ControlSet001\Enum\PCI\...
```
