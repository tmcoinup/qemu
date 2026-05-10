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

### 5.1 显示模式（默认 SDL + fb-shm 双开）

`fb-shm` 是 `-object fb-shm,...` 用户可创建对象，在主显示控制台上注册一条独立
DCL，与 `-display sdl/none/...` 完全解耦 —— 所以默认两条通道并存：

| 命令 | 本地窗口 | 远程 | 推流通道 |
|---|---|---|---|
| `start-vm.sh 1`                       | **SDL** | 无 | **fb-shm @ `/tmp/qemu-stealth-1.fb`** |
| `start-vm.sh 1 --headless`            | 无 | VNC :5900+N-1 | + fb-shm |
| `start-vm.sh 1 --no-sdl`              | 无 | 无 | fb-shm（后台 daemon）|
| `start-vm.sh 1 --no-fb-shm`           | SDL | 无 | — |
| `start-vm.sh 1 --headless --no-fb-shm`| 无 | VNC | — |

无 `DISPLAY` 又非交互终端时（`nohup ... &`）自动降级 `--no-sdl`，避免 SDL crash。

### 5.2 常见调用

```bash
# 最简（默认 SDL 窗口 + fb-shm 推流并存，可同时直接玩 + 录屏）
deploy/scripts/start-vm.sh 1
# 另开一个终端开始拉流：
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output /tmp/vm1.mp4 --encoder libx264 --preset veryfast

# 后台 daemon：关 SDL，仅 fb-shm 推流
deploy/scripts/start-vm.sh 1 --no-sdl

# 远程登录 + 推流：VNC 看实时画面，fb-shm 推 RTMP
deploy/scripts/start-vm.sh 1 --headless
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output 'rtmp://ingest/live/vm1' --encoder h264_nvenc --bitrate 6M

# 只推 ROI（省 CPU/带宽）
deploy/scripts/start-vm.sh 1 --fb-shm-roi=0,0,1280,720 --fb-shm-rate=30

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
| `STABLE_DISPLAY` | **1** | 仅 `--sdl` 模式生效：`virtio-vga` 无 GL，规避 virgl BSOD |
| `GPU_SELFSIGNED` | **0** | 0 = PCI 主 ID 留 `1AF4:1050` + subsys 改 NVIDIA `1C8110DE`，搭配 stock virtio-win + apply-gpu-spoof.ps1 = 通过 ACE。1 = 把主 ID 也改 `10DE:1C81`，需要 patched viogpudo + 伪 NVIDIA CA，**ACE 会判异常 13-131106-0** |
| `USB_RELATIVE_MOUSE` | 0 | 1 = `usb-mouse` 相对坐标（更像真鼠）；默认 `usb-tablet` 绝对坐标 |
| **`FB_SHM`** | **1** | **默认开**：始终带 `-object fb-shm,...` 共享内存推流通道。`--no-fb-shm` 关 |
| `FB_SHM_SOCK` | `/tmp/qemu-stealth-<N>.fb` | 控制 socket 路径 (flag: `--fb-shm-sock=…`) |
| `FB_SHM_RATE` | 60 | 推流帧率 Hz, [1,240] (flag: `--fb-shm-rate=…`) |
| `FB_SHM_ROI` | `` | 子区域 `x,y,w,h`；空 = 全屏 (flag: `--fb-shm-roi=…`) |
| **`SDL`** | **1** | **默认开**：SDL 窗口；`--no-sdl` 关；`--headless` 自动关 |
| `HEADLESS` | 0 | 1 = 关 SDL 改 VNC（与 fb-shm 并存）(flag: `--headless`) |
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

## 6.4 QMP 多客户端（qmp-proxy.py）

QEMU 的 `-qmp unix:...,server=on` 是**单连接** chardev：dgame 一长期挂着，
image-search / 任何脚本去 connect 就 ECONNREFUSED。 用 fanout 代理解决：

```bash
# 起 VM（不变）
deploy/scripts/start-vm.sh 2

# 起代理（独占 /tmp/qemu-stealth-2.qmp，再开一个 .proxy 多客户端入口）
nohup deploy/scripts/qmp-proxy.py 2 > /tmp/qmp-proxy-2.log 2>&1 &

# 把所有工具改成连 .qmp.proxy（不再连 .qmp）
#   dgame:        --qmp /tmp/qemu-stealth-2.qmp.proxy
#   image-search: 把 src/qmp.rs 里的 socket path 改后缀
#   socat:        socat - UNIX-CONNECT:/tmp/qemu-stealth-2.qmp.proxy
```

代理工作机制：

* upstream 单连接由代理独占，对下游开 16 后台连接的 listener；
* 命令的 `id` 字段被代理改写成 `p<n>` 转发，响应回来按 `id` 路由回原 client，原始 id 还原；
* 事件（RESET/SHUTDOWN/...）广播给所有 client；
* `qmp_capabilities` 在每个下游 client 本地接住，不重复发上游；
* OOB 命令（`exec-oob`）一并支持，路由方式相同；
* upstream 死了广播一个合成的 `PROXY_UPSTREAM_LOST` 事件然后代理退出。

实测：4 个并发 client 各自 `query-status`，id 全部正确路由；3 个 listener
触发一次 `system_reset` 全部收到 `RESET` event。

注意：fb-shm 截图比 QMP screendump 快 10-100×，长期方案是把 image-search 改成
直接走 fb-shm（看 [FB-SHM.md](FB-SHM.md)）；qmp-proxy 是短期 workaround。

## 6.5 运行时切换显示通道

启动后想隐藏 SDL 窗口只留推流（节省 ~3-7% CPU）/ 反向：

```bash
deploy/scripts/ctl-vm.sh 1 stream-only    # SDL 隐 + fb-shm 跑
deploy/scripts/ctl-vm.sh 1 sdl-only       # SDL 显 + fb-shm 暂停
deploy/scripts/ctl-vm.sh 1 sdl-hide       # 仅隐 SDL
deploy/scripts/ctl-vm.sh 1 sdl-show       # 仅显 SDL
deploy/scripts/ctl-vm.sh 1 fb-off         # 卸载 fb-shm（删 socket）
deploy/scripts/ctl-vm.sh 1 fb-on 60       # 重装 fb-shm
deploy/scripts/ctl-vm.sh 1 status         # 查询当前状态
```

底层走 QMP：`display-pause` / `display-resume`（DCL 暂停）+ `object-del` /
`object-add`（fb-shm 卸载/重装）。详见 [FB-SHM.md](FB-SHM.md)。

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

# 同时跑（生产 daemon；nohup 无 DISPLAY 自动降级 --no-sdl，仅推流）
nohup deploy/scripts/start-vm.sh 1 > /tmp/qemu1.log 2>&1 &
nohup deploy/scripts/start-vm.sh 2 > /tmp/qemu2.log 2>&1 &

# 给两台分别拉一路 NVENC 推流（不同 RTMP key / UDP 端口）
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output 'rtmp://ingest/live/vm1' --encoder h264_nvenc --bitrate 6M &
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-2.fb \
    --output 'rtmp://ingest/live/vm2' --encoder h264_nvenc --bitrate 6M &

# 或者用编排器一次起多 VM 消费端
scripts/qemu-fb-shm-multivm.py --config multivm.yaml
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
