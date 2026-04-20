# 使用手册 — QEMU 9.2.0 Ryzen3-1200 Stealth 部署包

面向日常使用者，按"装—跑—查—救"四段式组织。

## 1. 前置依赖

主机要求：Ubuntu 22.04 及以上，支持 KVM（`/dev/kvm` 存在）。

```bash
# 构建依赖
sudo apt install -y build-essential ninja-build python3-venv python3-pip \
    python3-setuptools pkg-config libglib2.0-dev libpixman-1-dev \
    libsdl2-dev libspice-server-dev libvirglrenderer-dev libepoxy-dev \
    libslirp-dev libseccomp-dev libssh-dev ovmf

# 运行期工具（QMP 脚本、host 调优需要）
sudo apt install -y socat jq imagemagick ffmpeg
```

必备文件：

| 文件                                    | 用途             |
|-----------------------------------------|------------------|
| `/home/ubuntu/images/win10.iso`         | Win10 安装镜像   |
| `/usr/share/OVMF/OVMF_CODE_4M.fd`       | UEFI 固件        |
| `/usr/share/OVMF/OVMF_VARS_4M.fd`       | UEFI NVRAM 模板  |

启动器首跑时会自动在 `/home/ubuntu/images/` 生成 `ovmf-vars-N.fd` 和 `win10-instN.qcow2`。

## 2. 第一次构建（仅一次）

```bash
cd /home/ubuntu/projects/qemu
deploy/tools/apply-patches.sh
```

等价于"打补丁 + 调 build.sh"。`apply-patches.sh` 是幂等的：已应用的补丁会 skip，不会二次冲突。打完后它会 `exec` 到 `build.sh` 自动构建。

出错最常见原因：对非 `v9.2.0` 源树打补丁会在 `target/i386/cpu.c` 冲突，先 `git checkout v9.2.0` 再运行。

### 只重新构建（已经打过补丁）

日常改完代码、或者换了 JOBS 数，只想触发构建：

```bash
deploy/tools/build.sh                 # 增量构建
deploy/tools/build.sh --clean         # 先 rm -rf build/ 再从零编译
deploy/tools/build.sh --reconfig      # 保留 build/ 但强制重跑 configure
deploy/tools/build.sh --debug         # 带调试符号（--enable-debug --disable-strip）
deploy/tools/build.sh --jobs 8        # 限制 ninja 并行度
deploy/tools/build.sh --verify        # 构建完自动跑 verify-stealth.sh

# 追加 configure 参数
EXTRA_CONFIGURE="--enable-trace-backends=log" deploy/tools/build.sh --reconfig
```

`build.sh` 会先做依赖预检（ninja/pkg-config/glib/pixman 缺一报错并给出 apt 命令），构建完成后打印二进制大小 + sha256 + mtime 方便核对。

## 3. 日常启动流程

### 3.1 每次开机一次的主机调优

```bash
sudo deploy/scripts/host-performance.sh
# 或调整 hugepages 预留量（默认 16384 个 2MiB = 32 GiB）
sudo HUGEPAGES=8192 deploy/scripts/host-performance.sh
```

做的事：governor=performance、hugepages、THP=madvise、KVM halt_poll=500µs、停 irqbalance、NVMe scheduler=none。

### 3.2 首次装 Windows（从 ISO 引导）

```bash
deploy/scripts/win10-ryzen3-stealth.sh 1 --iso=/home/ubuntu/images/win10.iso
# 位置参数 1 = 实例号；有 --iso 就走 ISO 引导（安装盘）
```

首次启动时启动器会：①生成 512 GB qcow2 空盘（512,000,000,000 B，严格按厂家标签口径 512 × 10^9）；②**一次性**随机出这台 VM 的全部硬件身份（主板型号/序列号/MAC/UUID/NVMe 序列号等）并写到 `/home/ubuntu/images/stealth-inst1.profile`；③启动。

装完系统后**关机**（而不是重启），下一次启动再换盘引导。

### 3.3 已装完系统，从硬盘引导

```bash
deploy/scripts/win10-ryzen3-stealth.sh 1           # 实例 1，默认从盘引导
deploy/scripts/win10-ryzen3-stealth.sh 2           # 实例 2
```

没有 `--iso` 就默认从 qcow2 引导。每次启动都会从 `.profile` 文件里读出相同的硬件身份——Windows 不会把它当新机激活，DNF 也不会看到 MAC/主板序列号在变。

### 3.4 重新随机化硬件身份

只有在需要让 DNF/Windows 把你当新机（比如封号后换指纹）时才做：

```bash
# 方式一：单次启动时加 --reroll
deploy/scripts/win10-ryzen3-stealth.sh 1 --reroll

# 方式二：专用脚本，删档而已（不动 qcow2，不动系统）
deploy/scripts/reroll-identity.sh 1          # 只重滚实例 1
deploy/scripts/reroll-identity.sh 1 2 3      # 多实例
deploy/scripts/reroll-identity.sh --all      # 全部
```

重滚后下一次启动会生成新身份并覆盖写入 `.profile`。Windows 可能要求重新激活。

### 3.5 无头（后台）模式 — 只开 VNC

```bash
deploy/scripts/win10-ryzen3-stealth.sh 1 --headless
# 连接：vncviewer 127.0.0.1:5900
```

## 4. 命令行参数 / 环境变量完整清单

所有参数都有默认值，按需覆盖即可。位置参数（INSTANCE）和常用选项用命令行 flag 就行，其它用同名环境变量。

| 参数                  | 默认                                            | 说明                                            |
|-----------------------|-------------------------------------------------|-------------------------------------------------|
| 位置参数 `<INSTANCE>` | 1                                               | 实例编号，决定 QMP/VNC/MAC/端口偏移             |
| `--iso=<path>`        | 无                                              | 提供则从 ISO 引导（安装模式），不给就从硬盘     |
| `--disk=<path>`       | `/home/ubuntu/images/win10-inst${INSTANCE}.qcow2` | qcow2 磁盘路径                                |
| `--bridge=<br>`       | `br0`（默认走桥接）                             | 桥接网桥名；不存在时自动降级到 NAT 并打印 WARN |
| `--no-bridge`         | 关                                              | 强制退回到 user-mode NAT（10.0.2.x + SSH/RDP 转发）|
| `--headless`          | 关                                              | 关 SDL 只开 VNC，用 virtio-vga 非 GL           |
| `--reroll`            | 否                                              | 本次启动前重新随机一次硬件身份并覆盖 `.profile` |
| `--ram=<MiB>` / `RAM` | 8192                                            | 客机内存（平分到 2 个 NUMA 节点）               |
| `--cpus=<n>` / `CPUS` | 4                                               | vCPU 数（cores=CPUS, threads=1, sockets=1）     |
| `--qemu=<path>`       | `$REPO_ROOT/build/qemu-system-x86_64`           | 指向打过补丁的二进制                            |
| `MEM_SPEED=<MHz>`     | 2666                                            | 上报给客机的 DIMM JEDEC 频率。Ryzen 3 1200 官方上限 DDR4-2667 |
| `ISO=<path>`          | `/home/ubuntu/images/win10.iso`                 | 等价于 `--iso=` 的默认值（只在有 `--iso=` 时生效） |

### 4.1 硬件身份文件（.profile）

- 路径：`/home/ubuntu/images/stealth-inst<INSTANCE>.profile`
- **创建时写入**：首次启动（或 `--reroll`）生成；其它时候**绝对不碰**。
- **内容**：20 多个环境变量（主板、BIOS、NVMe 序列号、MAC、UUID、CPU 序列号等），纯文本 `VAR=value` 格式，可手动编辑然后重启生效。
- **删除** `.profile` 等价于 `--reroll`。
- **备份**一份 `.profile`（外加对应的 qcow2 镜像）就可以把这台「虚拟物理机」完整搬到其它主机，身份一模一样。

## 5. 多实例运行

两台并跑只需把 INSTANCE 换掉：

```bash
deploy/scripts/win10-ryzen3-stealth.sh 1 &
deploy/scripts/win10-ryzen3-stealth.sh 2 &
```

每个实例自动分配不冲突的资源：

| INSTANCE | QMP socket                 | HMP socket                 | VNC      | SSH 转发           | RDP 转发           |
|----------|----------------------------|----------------------------|----------|--------------------|--------------------|
| 1        | /tmp/qemu-stealth-1.qmp    | /tmp/qemu-stealth-1.mon    | :0/5900  | 127.0.0.1:10023→22 | 127.0.0.1:13390→3389 |
| 2        | /tmp/qemu-stealth-2.qmp    | /tmp/qemu-stealth-2.mon    | :1/5901  | 127.0.0.1:10024→22 | 127.0.0.1:13391→3389 |
| N        | /tmp/qemu-stealth-N.qmp    | /tmp/qemu-stealth-N.mon    | :(N-1)   | 10022+N            | 13389+N            |

每实例 OVMF_VARS、qcow2、MAC 地址、SMBIOS 随机身份都是独立的，不会互相污染。

### 5.1 桥接网络（推荐，让客机拿到 LAN IP）

DNF 反作弊会把 10.0.2.x / 192.168.76.x 这类 NAT 子网当成虚拟机信号。桥接模式让客机像局域网里的独立物理机一样拿 DHCP。

**一次性主机配置**（需 `sudo`）：

```bash
# 方案 A：隔离桥（不动物理网卡，host 给 br0 分配 192.168.76.1/24，客机之间互通但不上外网）
sudo deploy/scripts/setup-bridge.sh

# 方案 B：把物理网卡吃进 br0，客机直接用上游路由器的 DHCP（会短暂断网再恢复）
sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh
```

`setup-bridge.sh` 帮你一次性搞定所有依赖，不需要再装什么"插件"——它会自动：

1. **装 apt 包** `qemu-system-common`（里面就是 `qemu-bridge-helper`，Ubuntu 下就是这个包，不是什么额外插件）；
2. `modprobe tun bridge`，并写入 `/etc/modules-load.d/qemu-stealth.conf` 让它们开机自动加载；
3. 扫描三个可能的 helper 路径（`/usr/lib/qemu/`、`/usr/libexec/`、`/usr/local/libexec/`）和源码树里的 `build/qemu-bridge-helper`，**每一个都加 `cap_net_admin+ep`**；
4. **关键修复**：源码编译的 QEMU 默认去 `/usr/local/libexec/qemu-bridge-helper` 找 helper，而 apt 包装在 `/usr/lib/qemu/`，所以脚本会做一个 symlink 让两边路径都生效；
5. 写 `/etc/qemu/bridge.conf` 加 `allow br0`；
6. 启动器这边也额外用 `-netdev bridge,helper=<实测可用的 helper 路径>` 写死一遍，双保险。

整个过程幂等，可重跑。

启动 VM 时**无需任何 flag**——启动器默认就走 `br0`：

```bash
deploy/scripts/win10-ryzen3-stealth.sh 1
```

启动器会自动用 `-netdev bridge,helper=...`，不再分配 SSH/RDP 主机转发端口（因为客机已有自己的 IP，直接 `ssh <LAN-IP>` 即可）。

需要用别的桥名：`--bridge=br1`。临时想退回 NAT 调试：`--no-bridge`。如果 `br0` 不存在（忘了跑 setup-bridge.sh）脚本会打印 WARN 并自动降级到 NAT，不会直接挂掉。

## 6. QMP 控制命令（不进客机就能操作）

所有命令都通过 `deploy/scripts/qmp-frame.sh <INSTANCE> <cmd> [args]`：

```bash
# 抓一帧画面 -> PNG（底层 screendump 到 PPM 再转码）
deploy/scripts/qmp-frame.sh 1 screenshot /tmp/vm1.png

# 查询运行状态
deploy/scripts/qmp-frame.sh 1 info

# 发按键（qcode 名见 QEMU 文档：ret/tab/esc/f1...f12/ctrl/alt 等）
deploy/scripts/qmp-frame.sh 1 send-key ret
deploy/scripts/qmp-frame.sh 1 send-key ctrl-alt-delete   # 需自行拆成多次，或用 raw

# 存/恢复快照（savevm/loadvm）
deploy/scripts/qmp-frame.sh 1 snapshot clean-install
deploy/scripts/qmp-frame.sh 1 loadvm   clean-install

# 电源/暂停
deploy/scripts/qmp-frame.sh 1 stop       # 暂停
deploy/scripts/qmp-frame.sh 1 cont       # 继续
deploy/scripts/qmp-frame.sh 1 reset      # 硬复位
deploy/scripts/qmp-frame.sh 1 shutdown   # 通知 Windows 正常关机
deploy/scripts/qmp-frame.sh 1 quit       # 直接结束进程

# 原始 JSON（什么都能发）
deploy/scripts/qmp-frame.sh 1 raw '{"execute":"query-kvm"}'
```

连续录像（主机侧 VNC 录屏，不需进客机）：

```bash
HEADLESS=1 INSTANCE=1 deploy/scripts/win10-ryzen3-stealth.sh &
ffmpeg -framerate 30 -f x11grab -video_size 1920x1080 \
       -i :0 -c:v libx264 -pix_fmt yuv420p /tmp/vm1.mp4
```

或者用 VNC 客户端直连 `127.0.0.1:5900 + (INSTANCE-1)`。

## 7. 验证方法

### 7.1 主机侧、不开 VM 快查

```bash
deploy/scripts/verify-stealth.sh
```

检查：Ryzen3-1200 模型已注册、`query-cpu-model-expansion` 返回 hypervisor=False/kvm=False/vendor=AuthenticAMD、ACPI 字符串（ALASKA / A M I）已编入二进制、NVMe 的 `use-samsung-id` / `model-number` / `firmware-rev` 属性可用。

### 7.2 客机内（PowerShell）

```powershell
# 厂商应为 American Megatrends
(Get-WmiObject Win32_BIOS).Manufacturer

# 不应出现 BOCHS / BXPC
[Regex]::Match((Get-WmiObject Win32_ComputerSystem | Out-String),"BOCHS|BXPC").Success

# 所有核心都应 False（没被 Windows 认出虚拟化）
(Get-WmiObject Win32_Processor).HypervisorPresent

# NVMe 型号应为 Samsung SSD 970 PRO 512GB
(Get-WmiObject Win32_DiskDrive).Model
```

完整检测矩阵见 `VERIFY.md`。

### 7.3 客机侧 — 1920×1080 分辨率

QEMU 侧已经配好了：`virtio-vga-gl,edid=on,xres=1920,yres=1080` 会合成一段 EDID 宣告 1080p 为首选模式。但**安装期间**你仍然会看到 1024×768——OVMF 的 GOP 和 Windows 安装程序自带的 Basic Display Adapter 都不支持更高分辨率。装完系统后，要切到 1920×1080 只需装 virtio 显示驱动（只装一个文件，不是整包的 guest-tools，避免引入 `qemu-ga.exe` 这种明显 VM 标记）：

1. 下载 virtio-win ISO：`https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso`
2. 把 ISO 挂给 VM（可以临时拿另一台带 GUI 的机器手动 copy 进去，或暂时用 `--iso=` 的第二 CD 位——更简单的是用 Spice 剪贴板拖进去）。
3. 在客机里**只装 `viogpu` 子目录下的 INF**，不要跑 `virtio-win-guest-tools.exe`：
   ```cmd
   pnputil /add-driver D:\viogpudo\w10\amd64\viogpudo.inf /install
   ```
   装完 Windows 会自动把 Microsoft Basic Display 换成 `Red Hat VirtIO GPU DOD controller` 并切到 1080p。
4. 紧接着跑 `apply-gpu-spoof.ps1`，把这个新显卡的描述字段改成 `NVIDIA GeForce GTX 1050`（7.4 节）。

如果你不想动 Windows 里的显示驱动，可以退而求其次：只在 QEMU 侧允许 1024×768，外加 `--headless` 走 VNC 客户端自行放大。但 DNF 不会关心客机当前的分辨率，所以这步只是易用性。

### 7.4 客机侧 — 装完系统后必做的 GPU 改名 + VBS 关闭

把 `deploy/scripts/apply-gpu-spoof.ps1` 拷进 VM（Spice 剪贴板、SMB 共享、或临时挂一块 iso 都行），然后在客机 PowerShell 里（以管理员身份）：

```powershell
# 推荐：一次到位。自动找到 virtio GPU 子键改 DriverDesc/HardwareInformation.*，
# 同时改 Enum\PCI\...\FriendlyName + DeviceDesc（Device Manager 和
# Win32_VideoController.Name 读这里），并安装开机任务计划
# StealthGPU-RefreshName（SYSTEM、AtStartup+AtLogOn），
# 每次开机后 ~2 秒把名字再刷一次，防 BasicDisplay 驱动启动时覆盖。
powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1

# 只想看当前有哪些 Class 子键、不做任何修改：
powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -ListOnly

# 手动指定 Class 子键（自动识别失败时）：
powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -Subkey 0001

# 只改注册表不装任务计划（重启会被 BasicDisplay 刷回去，仅做对照测试用）：
powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -SkipTask
```

**关于持久化**：Windows 10/11 没有自带签名的 virtio-gpu 驱动，所以
`VEN_1AF4&DEV_1050` 会回落到内置的 `BasicDisplay` 驱动。这个驱动**每次
开机都会把 `Enum\PCI\...\DeviceDesc` 从 `display.inf` 刷回默认本地化字串**
（中文系统就是「Microsoft 基本显示适配器」），同时清空 `FriendlyName`。
上面那个任务计划就是为了每次开机后再刷一遍，打时间差赢过驱动，
不需要装 virtio-gpu 驱动（装了反而是明显虚拟化特征）。

历史兼容：`guest-gpu-spoof.reg` 仍保留，但它**只**改 Class 子键，
不改 Enum 节点也不装任务计划，重启后 `Win32_VideoController.Name` 会
变回本地化 Basic Display 名字，**不推荐继续用**。

同时一定要做：

```powershell
# 关 VBS / Hyper-V Launch（否则 cpuid 的 hypervisor 位会被 Windows 自己打开）
bcdedit /set hypervisorlaunchtype off

# 关 HVCI / Memory Integrity — Windows 安全中心 → 设备安全 → 内核隔离 → 关闭
# 或命令行：
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 0 /f

# 不要装 virtio-win guest agent / SPICE tools，它们会把 qemu-ga.exe 摆在进程表里
```

重启后再启动 DNF 试 403。详细残留检测面见 `VERIFY.md`。

### 7.4 在运行中的 VM 上手动 QMP 查

```bash
deploy/scripts/qmp-frame.sh 1 raw '{"execute":"query-cpu-model-expansion","arguments":{"type":"full","model":{"name":"Ryzen3-1200"}}}'
deploy/scripts/qmp-frame.sh 1 raw '{"execute":"query-pci"}'
deploy/scripts/qmp-frame.sh 1 raw '{"execute":"query-cpus-fast"}'
```

## 8. 常见问题

**Q: `Python's ensurepip module is not found` (configure 阶段)**
A: `sudo apt install python3-venv python3-pip python3-setuptools` 后重试。

**Q: `aio=io_uring invalid option`**
A: 编译没开 `--enable-linux-io-uring`。启动器已改用 `aio=threads`，如果被改过，恢复回来即可。

**Q: `Property 'host-cache-info' not found`**
A: 这是 host-cpu 专有属性，Ryzen3-1200 模型没有。不要往 `-cpu` 行里加。

**Q: `hda-duplex: no default audio driver available`**
A: 启动器应带 `-audiodev none,id=aud0` 并在 `hda-duplex` 上加 `audiodev=aud0`。被删过就补回来。

**Q: `spice ... gl=on` 报错**
A: SPICE GL 只能本地输出，跟 `-spice port=` 冲突。HEADLESS=1 场景直接用 VNC，不开 GL；带 GUI 场景用 SDL + virtio-vga-gl（已默认）。

**Q: VM 启动后卡在 UEFI Shell 里**
A: 没带 `--iso=` 但系统还没装。首次启动加 `--iso=/path/to/win10.iso`；已装过就不用加。

**Q: 想复现之前某次的硬件身份**
A: 保留好 `.profile` 文件就行，每次启动都会从它里面读；想换一套就 `--reroll`。

**Q: 多个 VM 想用同一套硬件身份**
A: 复制 `.profile` 文件就行：`cp stealth-inst1.profile stealth-inst2.profile`。但要在复制后手动把 `NIC_MAC` 改成一个新 MAC，否则局域网 ARP 会撞。

**Q: `BRIDGE=br0` 启动报 "bridge br0 does not exist"**
A: 先跑 `sudo deploy/scripts/setup-bridge.sh`（隔离桥）或带 `UPLINK=<物理网卡>`（LAN 桥），一次性配好再启动。

**Q: 桥接模式下客机拿不到 IP**
A: 隔离桥没有 DHCP 服务，客机要么自配静态 IP（同 192.168.76.0/24 网段），要么在 host 上装 `dnsmasq` 或直接用 `UPLINK=` 把桥挂到路由器下。

**Q: 客机里 WMI 查出 `Win32_PhysicalMemory` 只有一条/通道都是 "A"**
A: 重新构建时 0006 补丁没打上。确认 `deploy/patches/0006-smbios-dual-channel-bank.patch` 存在、`deploy/tools/apply-patches.sh` 的输出里有它、然后 `deploy/tools/build.sh --reconfig` 重编。

**Q: DNF 还是报 403**
A: 看 `NOTES-GPU.md`。主机这边的 CPUID/SMBIOS/ACPI/NVMe 四个面都关了，剩的 GPU 面必须进客机改注册表（`HKLM\...\Class\{4d36e968-...}\0000` 下的 `DriverDesc` / `HardwareInformation.*`）。

**Q: 想复现出完全一样的 SMBIOS 身份**
A: `SEED=<整数>` 固定种子，下次启动同一个 INSTANCE 会选到同样的主板/BIOS/序列号。

## 9. 目录速查

```
deploy/
├── docs/
│   ├── README.md       # 总览和设计目标
│   ├── USAGE.md        # 本文件
│   ├── NOTES-GPU.md    # GPU 伪装补充说明
│   └── VERIFY.md       # 检测面 vs 关闭手段对照表
├── patches/
│   ├── 0001-cpu-add-ryzen3-1200.patch
│   ├── 0002-kvm-strip-hypervisor.patch
│   ├── 0003-acpi-oem-spoof.patch
│   ├── 0004-nvme-samsung-id.patch
│   ├── 0005-pci-ids.patch
│   ├── 0006-smbios-dual-channel-bank.patch   # %C→A/B 让两条 DIMM 落到不同 bank
│   └── combined-stealth.patch    # 六合一
├── scripts/
│   ├── stealth-lib.sh            # SMBIOS 随机池 / MAC / OEM 字符串
│   ├── win10-ryzen3-stealth.sh   # 主启动器
│   ├── host-performance.sh       # 主机调优（需 sudo）
│   ├── setup-bridge.sh           # 一次性创建 br0 / 配 bridge.conf（需 sudo）
│   ├── reroll-identity.sh        # 删 .profile：让指定实例下次启动重滚身份
│   ├── qmp-frame.sh              # QMP 控制入口
│   ├── verify-stealth.sh         # 离线自检
│   ├── guest-gpu-spoof.reg       # 客机注册表：GPU 改名 GTX 1050（legacy，不保证重启后保留）
│   └── apply-gpu-spoof.ps1       # 推荐：改 Class + Enum\PCI，并装开机任务计划
└── tools/
    ├── apply-patches.sh          # 打补丁（幂等）并调用 build.sh
    └── build.sh                  # 构建（configure + ninja），支持 clean/reconfig/debug
```

## 10. 清理 / 重置

```bash
# 1) 单实例 qcow2 + NVRAM + 硬件身份清掉（彻底重装）
rm -f /home/ubuntu/images/win10-inst1.qcow2 \
      /home/ubuntu/images/ovmf-vars-1.fd \
      /home/ubuntu/images/stealth-inst1.profile

# 2) QMP / HMP socket 残留
rm -f /tmp/qemu-stealth-*.qmp /tmp/qemu-stealth-*.mon

# 3) 彻底回到未打补丁源树（慎用，会丢本地改动）
cd /home/ubuntu/projects/qemu
git checkout v9.2.0 -- target/i386/cpu.c target/i386/kvm/kvm.c \
    include/hw/acpi/aml-build.h include/hw/pci/pci_ids.h \
    hw/nvme/nvme.h hw/nvme/ctrl.c
```
