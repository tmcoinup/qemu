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

迁移到其它 host 时不要使用系统自带 QEMU。启动器会做 patched QEMU 能力预检；
路径和二进制位置配置见 [PORTABILITY.md](PORTABILITY.md)。

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
qemu-fb-shm-stream --sock /tmp/qemu-stealth-1.fb \
    --output /tmp/vm1.mp4 --encoder libx264 --preset veryfast

# 后台 daemon：关 SDL，仅 fb-shm 推流
deploy/scripts/start-vm.sh 1 --no-sdl

# 远程登录 + 推流：VNC 看实时画面，fb-shm 推 RTMP
deploy/scripts/start-vm.sh 1 --headless
qemu-fb-shm-stream --sock /tmp/qemu-stealth-1.fb \
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
| `BRIDGE` | `br0` | 桥接网卡；不存在/无授权时**默认**回退 user-mode NAT（见 `STRICT_STEALTH`） |
| `--no-bridge` | - | 强制走 user-mode NAT（10.0.2.0/24） |
| `STRICT_STEALTH` | 0 | 1 = 桥接失败即 fail-fast，**拒绝**静默回退 NAT（NAT 的 10.0.2.x 子网本身是 VM 特征，隐身验收致命） |
| `ALLOW_NAT_FALLBACK` | 0 | 1 = 在 `STRICT_STEALTH=1` 下显式允许回退 NAT（回退时日志打醒目标记） |
| `DRY_RUN` | 0 | 1 = 仅打印组装好的 QEMU argv 后退出；不落盘、不起守护、不 exec（调试/回归基准用） |
| `IMAGE_ROOT` | `/home/ubuntu/images` | VM 数据根目录；迁移到其它 host/挂载点时改这里即可 |
| `VMS_DIR` | `$IMAGE_ROOT/vms` | 多实例目录；每台 VM 默认在 `$VMS_DIR/<N>` |
| `VM_DIR` | `$VMS_DIR/<N>` | 单实例目录覆盖；用于把某台 VM 放到独立盘 |
| `QEMU` | `build/qemu-system-x86_64` | QEMU 二进制；迁移时必须指向 patched QEMU，不能用 stock QEMU |
| `QEMU_IMG` | `build/qemu-img` | 创建/克隆 qcow2 用的 qemu-img |
| `QEMU_CAP_CHECK` | 1 | 1 = 启动前检查 QEMU 是否带 NVMe/EDID/USB/fb-shm 等 stealth 属性；缺失则 fail-fast，防止误用 stock QEMU 破坏真机模拟 |
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
| `MEM_GUARD` | 1 | 启动前内存护栏：可用物理(MemAvailable)+SwapFree 不足以再容下本 VM 的 `-m`+2GiB 余量就 WARN；连 RAM+swap 都装不下则**拒绝启动**（防 OOM-kill 误伤其它在跑的 VM）。`0` = 关闭检查 |
| `MEM_FORCE` | 0 | 1 = 越过 `MEM_GUARD` 的硬拒绝强行启动（风险自负） |
| `HOST_TUNE` | **1** | 起 VM 前自动跑 `host-performance.sh`：governor=performance + halt_poll=500000 + THP defrag=never，压低 vCPU 服务延迟方差 → 缓解 ACE「游戏计时异常」(13-131130-8)。只动 host 侧旋钮，guest CPUID/tsc-freq/拓扑全不变（**零反检测影响**）。已调优自动跳过免重复 sudo；DRY_RUN 下严格 no-op。`0` / `--no-host-tune` = 跳过 |
| `CPU_FREQ_CAP` | **1** | （需 `HOST_TUNE=1`）把 host `scaling_max_freq` 封顶到本实例伪装 CPU 的 `CPU_MAX_MHZ`（= SMBIOS Type4 自报 `max-speed`，如 Ryzen3-1200=3400）。host(5800) boost 4.6GHz 远超伪装规格，固定 `tsc-freq` 下 guest 实测吞吐就会超该型号上限 = **变速器/计时异常 tell**。**只降不升**：多 VM 并发自然收敛到运行中最小值，绝不让任一 VM 跑出超自身规格的速度。`0` / `--no-freq-cap` = 满 boost 不封顶 |
| `CPU_ISOLATE` | **1** | 起 VM 后把 QEMU 钉进 cgroup v2 cpuset 独占分区，**线程级**隔离 vCPU：每个 vCPU 独占 1 个逻辑线程（非整颗物理核），4vCPU 的 VM 只吃 4 个逻辑线程。分配器优先把多台 VM 横向铺到不同物理核心，主线程耗尽后才使用 SMT 兄弟。`0` / `--no-cpu-isolate` = 关 |
| `HOST_RESERVE_CORES` | **auto** | 给宿主机预留物理核心；auto 默认 `max(2, ceil(物理核心数/8))`，多开需求过高时自动缩小预留以保证 VM 先铺不同物理核心。显式 N = 硬预留 N 颗，`0` = 使用整机逻辑 CPU 池（仅 `CPU_ISOLATE=1` 生效） |
| `QEMU_SERVICE_CPUS` / `QEMU_SVC_CPUS` | **0** | 给 QEMU main/IO/SDL/fb-shm worker 等非 vCPU 辅助线程额外预留 N 个逻辑 CPU；默认 0 保持旧行为。常用 `--svc-cpu`（等价 1）/ `--svc-cpus=N` / `--no-svc-cpus`，长兼容别名 `--qemu-service-cpu` / `--qemu-service-cpus=N` |
| `DISPLAY` | `:0` | X11 显示，未设默认本地 :0；HEADLESS=1 时忽略 |
| `EXTRA_ISO=PATH` | - | 副 CDROM（autounattend.xml / 驱动盘 等） |
| `--iso=PATH` | - | 主启动 ISO（装系统） |
| `--reroll` | - | 删掉 `vms/<N>/profile` 重新随机一次硬件身份 |
| `CPU_MODEL` | profile 写入 | `Ryzen3-1200`（默认）/ `Ryzen3-2300X`（Win11 LTSC 兼容）。第一次 reroll 时持久化到 profile，之后不用每次设 |

> **内存按需分配（`prealloc=off`）**：memfd 后端不再开机就把整块 `-m` 摸一遍钉死 host
> 物理内存——guest 用多少才占多少，未触及页不占、配 `mem-lock=off` 还可换出。多 VM 并发
> 时配合 `MEM_GUARD` 防 OOM。advertised 容量 / DIMM SMBIOS 完全不变（纯 host 侧分配策略，
> **零反检测影响**）。host 为 32GiB 时，3×8GiB VM 已贴上限，第 4 台务必看护栏提示。

> **host 计时抖动调优（`HOST_TUNE=1`，默认开）**：start-vm.sh 起 VM 前自动跑
> `host-performance.sh`，把 CPU governor 钉到 `performance`、halt_poll 拉到 500000ns、
> THP `defrag=never`。这些压低 vCPU 服务延迟的方差——ACE「游戏计时异常」(13-131130-8)
> 这类反作弊时钟检测对抖动尖刺敏感。**只动 host 侧**：guest 的 CPUID / 品牌串 /
> `tsc-freq` / vCPU 拓扑全不变，零反检测影响。已调优自动跳过（不每次 sudo）；后台/无 tty
> 且无免密 sudo 时只 WARN 不阻断启动。`--no-host-tune` 跳过。
> ⚠ 旧版 `host-performance.sh` 默认预留 32GiB hugepage——但内存后端是 `memfd`，**不用**
> 显式 hugepage 池，预留只会白锁 host 内存重新招回 OOM。现已默认关，仅 `HUGEPAGES=N`
> 且后端换 hugetlbfs 时才开。
>
> **频率封顶（`CPU_FREQ_CAP=1`，默认开）**：host(Ryzen7 5800)的 boost 能到 4.6GHz，
> 而 VM 伪装的是 Ryzen3-1200（自报 boost 3.4GHz）。guest 的 TSC 被钉死在 3.1GHz，但 CPU
> 实际以 host 频率执行指令——若 host 跑 4.4GHz，guest「单位 TSC tick 内干的活」就远超这颗
> CPU 该有的量，等于一台超频/变速的机器，正是 `13-131130-8` 计时异常的来源之一。把
> `scaling_max_freq` 压到 `CPU_MAX_MHZ`（伪装 CPU 上限）后，guest 再也跑不出超规格速度，
> 且固定频率顺带把抖动也压平。**多 VM 取运行中最小**：scaling_max_freq=当前在跑各 VM
> `CPU_MAX_MHZ` 的最小值（每次启动按实际在跑集合重算，可升可降），保证任一 VM 都不超自身
> 规格。低规格 VM 停机不触发重算，高规格 VM 要到下次启动/手动调才回升。
>
> **免密 sudo**：频率封顶要写 `scaling_max_freq`（root）。已装 `/etc/sudoers.d/qemu-hostperf`
> 仅给 `host-performance.sh` 免密（其余 sudo 仍要密码），所以 start-vm 自动调优**不再提示
> 输密码**。手动也可：`sudo deploy/scripts/host-performance.sh <封顶kHz>`（cap 走位置参数）。
>
> **CPU 亲和隔离（`CPU_ISOLATE=1`，默认开，线程级）**：频率封顶只解决「跑多快」，解决不了
> 「vCPU 抢不抢得到核」。宿主机一跑满核（如 `cargo build` 默认 `nproc` 个并行任务塞满全部
> 16 线程），QEMU 的 vCPU 线程只是普通 CFS 线程，要和几十个编译线程抢同一批核 → guest 该跑
> 时抢不到 → 卡顿/掉帧/鼠标延迟/ACE 计时异常。`start-vm` 起 VM 后由后台 pinner 等 QMP 报出
> vCPU 线程号，调 `host-cpu-isolate.sh` 把 QEMU 钉进 cgroup v2 cpuset **独占分区**：
> - **线程级**——每个 vCPU 独占 1 个逻辑线程（不是整颗物理核）。4vCPU 的 VM 默认只占
>   4 个逻辑线程；分配顺序优先遍历可用物理核心的第一个逻辑线程，主线程耗尽后才使用 SMT 兄弟。
> - 分区 `cpuset.cpus.partition=root` → 这些线程从 root cgroup 的 effective 摘走，宿主机
>   一切进程（桌面 / 编译）被内核挤到其余线程，**物理上碰不到 VM 的线程**；vCPU 永不被抢占。
> - **多 VM**：所有实例共用同一 `vmiso` 分区并按已占线程错开（flock 串行）。`HOST_RESERVE_CORES=auto`
>   会在多开需求较高时自动缩小宿主机预留，让 VM 优先横向铺到不同物理核心。分区随起停**动态伸缩**，
>   某台停机即把它的线程还给宿主机（`stop-vm.sh` 自动调 `release`）。
> - **辅助线程专用 CPU**：`--svc-cpu` / `QEMU_SVC_CPUS=1` 会额外分配 1 个逻辑 CPU，并把 QEMU
>   main loop、IO、SDL、fb-shm worker 等非 vCPU 线程收窄到这组 CPU。vCPU 满载时，显示/IO 路径
>   不再和 vCPU 抢同一条调度队列；日志应出现 `>> qemu svc`。`--svc-cpus=N` 可加大数量。
> - 代价：线程级下宿主机用到兄弟线程时与 vCPU 共享物理核执行单元（SMT 争用，**只掉吞吐不掉
>   调度**）。想要更强隔离可调高 `HOST_RESERVE_CORES`，或减少每台 VM 的 `--cpus=` 并配 `--svc-cpu`。
> - 纯运行态（cgroup v2，不重启），`guest` 完全无感知（零反检测影响）。免密 sudo 走
>   `/etc/sudoers.d/qemu-cpuiso`（仅 `host-cpu-isolate.sh`）。`--no-cpu-isolate` 关；
>   查看状态 `sudo deploy/scripts/host-cpu-isolate.sh status`。
>
> **CPU 按宿主机自动匹配**：新建 VM 选伪装 CPU 时硬过滤**同厂商**（AMD 宿主机只挑 AMD、
> 反之亦然——`enforce=off` 下宿主机微架构特性会透过 KVM 暴露，伪装异厂商即矛盾）+ 频率
> ≤宿主机单核上限（自报规格本机真实可达）。CPU 再按 socket 配套对应主板。无核显约束下
> CPU 池全 4C/4T（桌面 2C/4T 全带核显）。

每个 INSTANCE 的资源分配（默认 `IMAGE_ROOT=/home/ubuntu/images`，可迁移，见 [PORTABILITY.md](PORTABILITY.md)）：
- 磁盘：`$VMS_DIR/<N>/disk.qcow2`（不存在则按 profile 的 NVMe 容量创建 sparse qcow2）
- profile：`$VMS_DIR/<N>/profile`
- OVMF NVRAM：`$VMS_DIR/<N>/ovmf-vars.fd`
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

## 6.4 QMP 多客户端（QEMU 原生 multi=on）

普通 `-qmp unix:...,server=on` 是**单连接** chardev：dgame 一长期挂着，
image-search / 任何脚本去 connect 就 ECONNREFUSED。本分支给 QMP socket
加了 `multi=on`，`start-vm.sh --proxy` 会直接启用原生多客户端 listener：

```bash
# 起 VM，同时启用 QMP 原生 multi-client
deploy/scripts/start-vm.sh 2 --proxy

# 新旧路径都能连：.qmp 是原生 multi socket，.qmp.proxy 是兼容 symlink
#   推荐:         /tmp/qemu-stealth-2.qmp
#   dgame:        --qmp /tmp/qemu-stealth-2.qmp.proxy
#   image-search: 把 src/qmp.rs 里的 socket path 改后缀
#   socat:        socat - UNIX-CONNECT:/tmp/qemu-stealth-2.qmp.proxy
```

原生工作机制：

* socket listener 持续 accept，每个 client 创建独立 QMP monitor；
* 每个 client 独立做 `qmp_capabilities`，命令响应天然回到发起连接；
* 事件（RESET/SHUTDOWN/...）沿用 QEMU monitor 事件广播，发给所有已握手 client；
* OOB 命令（`exec-oob`）沿用原 QMP monitor 支持；
* 不再需要 Python `qmp-proxy.py` 常驻进程。

实测：4 个并发 client 各自 `query-status`，id 全部正确路由；3 个 listener
触发一次 `system_reset` 全部收到 `RESET` event。

注意：fb-shm 截图比 QMP screendump 快 10-100×，长期方案是把 image-search 改成
直接走 fb-shm（看 [FB-SHM.md](FB-SHM.md)）。

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
qemu-fb-shm-stream --sock /tmp/qemu-stealth-1.fb \
    --output 'rtmp://ingest/live/vm1' --encoder h264_nvenc --bitrate 6M &
qemu-fb-shm-stream --sock /tmp/qemu-stealth-2.fb \
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
# 确认停机后还会收摊本实例的 swtpm daemon、旧版 Python qmp-proxy
# 残留进程和 .qmp.proxy 兼容别名：swtpm 是脱离 qemu 的 --daemon，
# 不显式停会一直持 tpm-state NVRAM 锁，下次启动新 QEMU CMD_INIT
# 抢不到锁报 0x9 秒退（见 docs/DEBUG.md）。
```

> 直接 `kill -9` qemu 或关 SDL 窗口**不会**清 swtpm；但 `start-vm.sh` 起 daemon 前有
> preflight reaper 会按实例自动清掉孤儿 swtpm（无活 qemu 占用本实例 tpm-sock 时才清，
> 跨实例零误杀），所以即便硬杀过，下次 `start-vm.sh <N>` 也能自愈。

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
