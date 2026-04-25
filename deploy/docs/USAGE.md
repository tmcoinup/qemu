# 使用手册 — QEMU 9.2.0 Ryzen3-1200 Stealth 部署包

面向日常使用者，按"装—跑—查—救"四段式组织。

> 2026-04-20 起，显卡身份已从客机端 GPU 改名升级为 QEMU+客机双层方案：
> QEMU 侧新增 `0008-virtio-gpu-subsys.patch`，把 virtio-gpu 的 PCI
> subsystem ID 改成 `10DE:1C81`（NVIDIA GTX 1050）+ Revision `A1`，
> VEN/DEV 仍保留 `1AF4:1050` 让 virtio-win 驱动继续 bind。客机内再用
> `apply-gpu-spoof.ps1` 改名字字段。整个 bootstrap
> 过程可通过 QMP sendkey 全自动执行，不再依赖 RDP GUI。详见第 7.5 节。
>
> 2026-04-20 撤回：原先 `guest-lock-drivers.ps1` 写
> `DenyDeviceClasses` / `ExcludeWUDriversInQualityUpdate` 等策略键本身
> 就是虚拟化/OEM 不愿留下的指纹，反而帮反作弊识别，已整体去掉。WU
> 若下发新显卡驱动导致名字被刷回，改靠重跑 `apply-gpu-spoof.ps1` 或
> `StealthGPU-RefreshName` 开机任务兜底。
>
> 2026-04-20 补丁：Device Manager → GPU → 驱动程序 → "驱动程序提供商"
> 会显示"未知"。原因是 `Enum\PCI\<inst>\Properties\{a8b865dd-...}` 这条
> DEVPKEY 子树被 Windows 锁到 TrustedInstaller ACL 且值必须用
> DEVPROP_TYPE_STRING (`0xFFFF0012`)，而 `reg.exe /t REG_SZ` 只能写
> 类型 `0x1` — 客机里怎么折腾都改不掉。新增 host 侧 offline 修复脚本
> `deploy/scripts/host-fix-gpu-devpkey.sh`，在 VM 关机后直接 raw-edit
> hive 修 SD + 类型，一次搞定。详见第 7.6 节。

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

**关 VM 推荐用 `stop-vm.sh`**（比直接 `quit` 多一次 ACPI 优雅停机 + 降级兜底）：

```bash
deploy/scripts/stop-vm.sh            # 默认 instance=1，ACPI powerdown → 等 60s → QMP quit → SIGTERM → SIGKILL
deploy/scripts/stop-vm.sh 2          # 停实例 2
deploy/scripts/stop-vm.sh 1 --hard   # 跳过 ACPI 直接 QMP quit
deploy/scripts/stop-vm.sh 1 --wait=120  # 拉长 ACPI 等待
```

停完会清 `/tmp/qemu-stealth-<N>.{qmp,mon}` socket，不会留残留。

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

1. 下载 virtio-win ISO（注意路径里是 `groups/virt/virtio-win`，不是 `groups/virtio-win` 那是旧链接会 404）：
   `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win.iso`
2. 把 ISO 挂给 VM（可以临时拿另一台带 GUI 的机器手动 copy 进去，或暂时用 `--iso=` 的第二 CD 位——更简单的是用 Spice 剪贴板拖进去，或者照 7.5 节起 HTTP server 从 guest 里 `curl` 拉）。
3. 在客机里**只装 `viogpu` 子目录下的 INF**，不要跑 `virtio-win-guest-tools.exe`：
   ```cmd
   pnputil /add-driver D:\viogpudo\w10\amd64\viogpudo.inf /install
   ```
   装完 Windows 会自动把 Microsoft Basic Display 换成 `Red Hat VirtIO GPU DOD controller` 并切到 1080p。
4. 紧接着跑 `apply-gpu-spoof.ps1`，把这个新显卡的描述字段改成 `NVIDIA GeForce GTX 1050`（7.4 节）。WU 如果下发新 display.inf 把名字刷回，靠 `StealthGPU-RefreshName` 开机任务兜底即可——不要再装驱动锁策略，反而是指纹。

如果你不想动 Windows 里的显示驱动，可以退而求其次：只在 QEMU 侧允许 1024×768，外加 `--headless` 走 VNC 客户端自行放大。但 DNF 不会关心客机当前的分辨率，所以这步只是易用性。

### 7.4 客机侧 — 装完系统后必做的 GPU 改名 + VBS 关闭

把 `deploy/scripts/apply-gpu-spoof.ps1` 拷进 VM（Spice 剪贴板、SMB 共享、或临时挂一块 iso 都行），然后在客机 PowerShell 里（以管理员身份）：

```powershell
# 推荐：一次到位。自动找到 virtio GPU 子键改 DriverDesc/HardwareInformation.*，
# 同时改 Enum\PCI\...\FriendlyName + DeviceDesc + Mfg（Device Manager、
# Win32_VideoController.Name 和 DxDiag 的 "制造商" 字段读这里），并改
# Enum\DISPLAY + Class\{4d36e96e-...} 把监视器名从 "Generic PnP Monitor" 改
# 成 "Samsung SyncMaster S24F350"，最后安装开机任务计划
# StealthGPU-RefreshName（SYSTEM、AtStartup+AtLogOn），
# 每次开机后 ~2 秒把 GPU + 监视器名字再刷一次，防 BasicDisplay 驱动启动时覆盖。
powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1

# 只想看当前有哪些 Class 子键、不做任何修改：
powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -ListOnly

# 手动指定 Class 子键（自动识别失败时）：
powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -Subkey 0001

# 只改注册表不装任务计划（重启会被 BasicDisplay 刷回去，仅做对照测试用）：
powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -SkipTask
```

脚本顶部有 4 个可覆写的字符串（需要改品牌就在脚本里改，然后重跑；任务计
划里嵌入的 refresh 脚本也会跟着被重写）：

| 变量           | 默认值                         | 生效位置                                               |
|----------------|--------------------------------|--------------------------------------------------------|
| `$spoofName`   | `NVIDIA GeForce GTX 1050`      | `Win32_VideoController.Name`、Device Manager GPU 名    |
| `$spoofVendor` | `NVIDIA`                       | DxDiag "制造商" / Device Manager → GPU 属性 → 制造商   |
| `$monitorName` | `Samsung SyncMaster S24F350`   | Device Manager 监视器节点名、DxDiag "监视器" 名        |
| `$monitorMfg`  | `Samsung`                      | 监视器的制造商字段                                     |

**关于持久化**：Windows 10/11 没有自带签名的 virtio-gpu 驱动，所以
`VEN_1AF4&DEV_1050` 会回落到内置的 `BasicDisplay` 驱动。这个驱动**每次
开机都会把 `Enum\PCI\...\DeviceDesc` 从 `display.inf` 刷回默认本地化字串**
（中文系统就是「Microsoft 基本显示适配器」），同时清空 `FriendlyName`。
上面那个任务计划就是为了每次开机后再刷一遍，打时间差赢过驱动，
不需要装 virtio-gpu 驱动（装了反而是明显虚拟化特征）。

**但还差一步** — `apply-gpu-spoof.ps1` 跑完后 Device Manager → 驱动程序
选项卡的"驱动程序提供商"仍然是"未知"。WMI 的 `Name/Mfg/VideoProcessor`、
DxDiag 的制造商都好了，**只剩 Driver 选项卡这一处**。原因见本页顶部注释：
`Enum\PCI\<inst>\Properties\{a8b865dd-...}\0009\00000000` 这条 DEVPKEY
存储是 TrustedInstaller ACL + DEVPROP_TYPE_STRING（`0xFFFF0012`），
客机里的 reg.exe 改不掉类型字段。**关掉 VM 之后**在主机侧跑：

```bash
sudo deploy/scripts/host-fix-gpu-devpkey.sh 1    # 实例 1
```

它会 qemu-nbd 挂 qcow2、ntfsfix、raw-edit `SYSTEM` hive，做三件事：
  1. Phase A — 把 Properties 子树里所有 nk 的 sk 指针重写成 instance nk
     的开放 SD（Admin 可读），绕开 TrustedInstaller ACL；
  2. Phase B — 把 pid `0004`/`0009` 的 vk.type 从 `0x1` 改成 `0xFFFF0012`
     并把数据写成 UTF-16LE 的 `NVIDIA GeForce GTX 1050` / `NVIDIA`；
  3. Phase C — 同步 regf 头部 `primary = secondary` 序列号并重算 XOR
     checksum，让 Windows 把 hive 当 clean、不走 LOG1 回放。

完全幂等，重复跑不会累加改动。跑完直接再开 VM，Driver 选项卡的
"驱动程序提供商"就固定为 `NVIDIA`，日期/版本/数字签名（Microsoft Windows
Hardware Compatibility Publisher）全部正常。详见第 7.6 节。

**关于驱动更新（2026-04-20 撤回驱动锁策略）**：

早先版本用 `guest-lock-drivers.ps1` 把
`DriverSearching\SearchOrderConfig=0`、
`DeviceInstall\Restrictions\DenyDeviceClasses={4d36e968-...}`、
`Device Metadata\PreventDeviceMetadataFromNetwork=1`、
`WindowsUpdate\ExcludeWUDriversInQualityUpdate=1`
这四处都写死；但这些策略键本身就是普通 OEM 机器不会长成的样子，
反倒给反作弊提供了"这是被管控的 VM/企业托管机"的旁证。

现在的做法是 **不碰策略**，WU 照常跑：名字字段如果被 WU 刷回，由
`StealthGPU-RefreshName` 开机任务计划重新盖上即可。`apply-gpu-spoof.ps1`
默认会装这个任务；硬件变动后重跑一次 `apply-gpu-spoof.ps1`。

如果你是从老 bundle 升上来，确认先前写入的锁策略已清：

```cmd
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" /v SearchOrderConfig
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" /s
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" /v PreventDeviceMetadataFromNetwork
```

三处都回 "系统找不到指定的路径" 才算干净。

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

### 7.5 全自动 bootstrap（QMP sendkey + HTTP 拉取，无需 GUI）

全新装好的 Win10 客机如果 RDP/网络还没开、也不想坐在 SDL 窗口前手敲命令，
可以用下面的两段式 bootstrap，从 host 侧 **完全自动化** 把 GPU 伪装 + 驱动
锁全部落完。脚本都在 `deploy/scripts/` 里：

| 文件                            | 作用                                                                 |
|---------------------------------|----------------------------------------------------------------------|
| `guest-bootstrap-phase1.cmd`    | 设置 Administrator 密码 `123456`、开 RDP、关 NLA、起 TermService     |
| `guest-bootstrap-phase2.cmd`    | curl 拉 virtio-win.iso → mount → `pnputil /add-driver viogpudo.inf /install` → 跑 `apply-gpu-spoof.ps1` |
| `guest-bootstrap.cmd`           | 1+2 合并的单段脚本（适合 RDP 进去后手动跑）                           |
| `apply-gpu-spoof.ps1`           | 见 7.4                                                                |

#### 一、起 host HTTP 服务

脚本都靠 `http://10.0.2.2:8787/*` 分发（10.0.2.2 是 QEMU user-mode NAT
固定给客机看到的 host gateway）。桥接模式下请把 8787 端口改成 host 实际
LAN IP 或 0.0.0.0。

```bash
mkdir -p ~/deploy-serve
ln -sf ~/projects/qemu/deploy/scripts/guest-bootstrap-phase1.cmd ~/deploy-serve/phase1.cmd
ln -sf ~/projects/qemu/deploy/scripts/guest-bootstrap-phase2.cmd ~/deploy-serve/phase2.cmd
ln -sf ~/projects/qemu/deploy/scripts/apply-gpu-spoof.ps1         ~/deploy-serve/apply-gpu-spoof.ps1
ln -sf ~/images/iso/virtio-win.iso                                ~/deploy-serve/virtio-win.iso

cd ~/deploy-serve && python3 -m http.server 8787 --bind 0.0.0.0 &
```

#### 二、QMP HMP sendkey 驱动客机

`/tmp/qemu-stealth-<N>.mon` 是 HMP 控制端。它的 `sendkey` 命令支持字面
`ctrl-shift-ret`、`shift-1` 等组合，比 QMP 的 `send-key` 宽松。

典型流程（首次开机、还没 RDP）：

```bash
# 1) 打开 Run 对话框，敲 cmd，Ctrl+Shift+Enter 拉起管理员 cmd
(echo "sendkey meta_l-r 60"; sleep 1) | socat - UNIX-CONNECT:/tmp/qemu-stealth-1.mon
# 在管理员 cmd 里敲：curl + 跑 phase1
(echo "sendkey c 30"; echo "sendkey m 30"; echo "sendkey d 30"; echo "sendkey ctrl-shift-ret 60") | \
    socat - UNIX-CONNECT:/tmp/qemu-stealth-1.mon
# UAC 对话框若出现：敲 Alt+Y
(echo "sendkey alt-y 60") | socat - UNIX-CONNECT:/tmp/qemu-stealth-1.mon
```

再把下面这一行在客机 cmd 窗口里 "type 进去" + 回车（建议 host 侧写个
Python 小脚本 wraps `sendkey` 按字符循环敲）：

```cmd
curl -sfo c:\p1.cmd http://10.0.2.2:8787/phase1.cmd && c:\p1.cmd
```

phase1 跑完（`=== phase1 done ===`）：Administrator 密码已改成 `123456`，
RDP 已开，NLA 已关。此时可 **切回 RDP 继续**：

```bash
xfreerdp /v:127.0.0.1:13390 /u:Administrator /p:123456 \
         /cert-ignore /sec:tls /network:lan \
         /size:1600x900 /dynamic-resolution \
         +clipboard +fonts /sound:sys:pulse \
         /log-level:WARN
```

RDP 连上后在 cmd 里跑 phase2：

```cmd
curl -sfo c:\p2.cmd http://10.0.2.2:8787/phase2.cmd && c:\p2.cmd
```

phase2 的 5 步完成后（`=== phase2 done ===`）：iso 已挂、viogpudo 已装、
GPU 已改名 `NVIDIA GeForce GTX 1050`、WU 驱动更新已锁死。此时用
`Get-CimInstance Win32_VideoController | Select Name,VideoProcessor,AdapterRAM,DriverVersion | Format-List`
即可最终验证 WMI 层。

**最后一步 — host 侧 offline 修 DEVPKEY**（否则 Device Manager 驱动程序
选项卡的"驱动程序提供商"会停在"未知"）：

```bash
# 客机里先把系统正常关机 (Start -> Power -> Shutdown), 或者 host 侧:
deploy/scripts/stop-vm.sh 1 --wait=120

# 修一次 DEVPKEY 类型 + SD
sudo deploy/scripts/host-fix-gpu-devpkey.sh 1

# 再启动 VM 验证
deploy/scripts/win10-ryzen3-stealth.sh 1
```

之后 Device Manager → 显示适配器 → NVIDIA GeForce GTX 1050 → 属性
→ 驱动程序 看到的应该是:

- 驱动程序提供商：`NVIDIA`
- 驱动程序日期：（原 VioGpuDod 签署日期，保留不动）
- 驱动程序版本：`100.101.104.28500`
- 数字签名者：`Microsoft Windows Hardware Compatibility Publisher`

> 如果客机里的 `Get-PnpDevice -Class Display` 里看到的是
> `PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8110DE&REV_A1`，说明 0008 补丁已经
> 生效；如果还是 `SUBSYS_11001AF4`，说明启动时没带 `x-pci-sub-*` 参数，
> 检查启动器是否读到了 `GPU_SUBSYS_VEN/DEV/REV` 环境变量。

Host 侧要抓一眼客机画面确认运行到哪一步：`deploy/scripts/qmp-frame.sh 1 screenshot /tmp/vm1.png`。

### 7.6 Host 侧 offline DEVPKEY 修复（驱动程序提供商: 未知 的最终解）

**什么时候需要跑：**

- 新装 Win10 + VioGpuDod 驱动 + `apply-gpu-spoof.ps1` 之后，Device Manager
  → 驱动程序 → 驱动程序提供商仍显示"未知"；
- 之前跑过旧版脚本（把 pid 0004/0009 写成 REG_SZ）、签名/版本/日期栏
  全变空白或"未签名"的话，也跑这个脚本一次即可。

**原理：** 客机里 `reg.exe add /t REG_SZ /v 00000000` 只能把 vk.type 字段
写成 `0x1`（REG_SZ），但 DEVPKEY 存储只认 `0xFFFF0012`
（DEVPROP_TYPE_STRING | 0xFFFF0000 prefix）。`SetupDiGetDeviceProperty`
读到类型不匹配就返回失败，Device Manager 显示"未知"。另外
`Enum\PCI\<inst>\Properties` 整个子树的 SD 默认是 TrustedInstaller-only，
Admin 连读都不行。两个问题必须在 offline 状态用 raw-edit hive 修正。

**依赖：**

```bash
sudo apt install -y qemu-utils ntfs-3g python3-hivex
```

**使用：**

```bash
# VM 必须先关（脚本会自动帮你关一次）
sudo deploy/scripts/host-fix-gpu-devpkey.sh 1            # 实例 1
sudo deploy/scripts/host-fix-gpu-devpkey.sh 2            # 实例 2

# 只预览不写盘
sudo deploy/scripts/host-fix-gpu-devpkey.sh 1 --dry-run

# 自定义 provider / desc
sudo PROVIDER=NVIDIA DEVICE_DESC='NVIDIA GeForce GTX 1060' \
    deploy/scripts/host-fix-gpu-devpkey.sh 1
```

**脚本内部做的事：**

1. `qemu-nbd --connect` 把 qcow2 挂到 `/dev/nbd0`；
2. `ntfsfix --clear-dirty`，然后 `mount -t ntfs-3g -o rw,remove_hiberfile`；
3. 打开 `C:\Windows\System32\config\SYSTEM` hive，hivex 枚举
   `ControlSet001\Enum\PCI\VEN_1AF4&DEV_1050*\<inst>\Properties` 子树；
4. Phase A — 把子树里所有 nk 的 `sk_offset` 改成 instance nk 自己的 sk
   （Admin 可读），sk 记录的 refcount 同步修正；
5. Phase B — 对 pid `0004`（DriverDesc）和 pid `0009`（DriverProvider）
   下的 `00000000` 和 `(default)` 值：
   - `vk.type` 从 `0x00000001` 改成 `0xFFFF0012`；
   - `vk.data` 写成 UTF-16LE 的 `NVIDIA GeForce GTX 1050` / `NVIDIA`
     （自带 trailing NUL，所需长度不够时会在 hbin 里找 free cell 重新分配）；
6. Phase C — 同步 regf 头 `primary = secondary`，重算 XOR checksum，
   避免 Windows 下次启动走 LOG1 回放把改动吃掉；
7. umount + `qemu-nbd --disconnect`。

**幂等。** 跑过后再跑不会累加改动，只会在输出里显示 0 type fixes。

**常见误解：**

- 这个脚本只改 DEVPKEY 层（`Properties\{a8b865dd-...}`）。Class\、Enum\PCI
  顶层、Monitor 等其他字段靠 `apply-gpu-spoof.ps1` 在客机内搞定，**两个
  脚本互补，缺一不可**。
- 脚本不改驱动文件、不改 CAT，所以数字签名检查不受影响。跑完后 Driver
  选项卡的"数字签名者"仍是 `Microsoft Windows Hardware Compatibility
  Publisher`（VioGpuDod 原始签名）。

### 7.7 在运行中的 VM 上手动 QMP 查

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
A: 看 `NOTES-GPU.md` + `PLAN-GPU-NVIDIA.md`。主机这边 CPUID/SMBIOS/ACPI/NVMe/GPU-SUBSYS 五个面已关；剩的 GPU 名字必须进客机跑 `apply-gpu-spoof.ps1`，并确保 `StealthGPU-RefreshName` 开机任务计划已装（WU 若下发新 display.inf，任务会重新把名字盖回去）。

**Q: 客机 `Get-PnpDevice -Class Display` 仍显示 `SUBSYS_11001AF4`（没改成 `1C8110DE`）**
A: 0008 补丁没打进或启动器没带 `x-pci-sub-*` 参数。先 `deploy/tools/apply-patches.sh` 确认 `0008-virtio-gpu-subsys.patch` 打上；启动器会从 `GPU_SUBSYS_VEN/DEV/REV` 读默认 `0x10DE/0x1C81/0xA1`。

**Q: 开机后 `Win32_VideoController.Name` 被刷回 "Microsoft 基本显示适配器"**
A: `StealthGPU-RefreshName` 任务计划没跑。检查 `schtasks /Query /TN StealthGPU-RefreshName` 是否存在、RunLevel=Highest、Principal=SYSTEM。`apply-gpu-spoof.ps1` 不带 `-SkipTask` 参数重跑一遍即可。

**Q: Device Manager → 驱动程序 → 驱动程序提供商 显示"未知"**
A: 客机里的 `apply-gpu-spoof.ps1` 把 `Enum\PCI\<inst>\Properties\{a8b865dd-...}\0009\00000000` 的 vk.type 写成 `REG_SZ(0x1)`，而 DEVPKEY 存储只认 `DEVPROP_TYPE_STRING(0xFFFF0012)`；并且 Properties 子树的 SD 是 TrustedInstaller-only，Admin 连读都不行。客机里的 reg.exe 改不掉这两处，必须 offline 修。流程：`deploy/scripts/stop-vm.sh 1` → `sudo deploy/scripts/host-fix-gpu-devpkey.sh 1` → 再开 VM。详见 7.6 节。

**Q: `sudo deploy/scripts/host-fix-gpu-devpkey.sh 1` 报 `Windows is hibernated, refused to mount`**
A: 上次 VM 不是正常关机，Windows 留了 hiberfile。脚本已经在 mount 时传了 `remove_hiberfile`，ntfs-3g 会把 hiberfile 清掉；偶尔需要连跑两次才能彻底处理。彻底避免：`stop-vm.sh <N> --wait=120` 等 ACPI 优雅关机，或客机里 Start → Power → Shutdown。

**Q: 跑完 `host-fix-gpu-devpkey.sh` 后 VM 启动报注册表损坏/Boot recovery**
A: 说明 hive checksum 或 hbin 结构被破坏。极少见，脚本里已做 `primary=secondary` + XOR checksum 同步。万一真出事，Windows 还有 `System32\config\RegBack\` 的旧 SYSTEM 副本可恢复：客机 WinPE 下 `copy C:\Windows\System32\config\RegBack\SYSTEM C:\Windows\System32\config\SYSTEM`。

**Q: DxDiag 的"制造商"字段显示 `Red Hat, Inc.`，不是 `NVIDIA`**
A: 用的是旧版 `apply-gpu-spoof.ps1`（早期只改 `Class\...\ProviderName`）。DxDiag 的
"制造商"字段其实读的是 `Enum\PCI\...\Mfg`（从 INF `Provider=` 行在安装时烧进 PnP）。
2026-04-20 起的脚本已经会同步写 `Mfg`，重跑一遍 `apply-gpu-spoof.ps1` 即可。

**Q: Device Manager / DxDiag 里监视器是 "Generic PnP Monitor"**
A: 0007 补丁让 QEMU 上报的 EDID 里 vendor=SAM / name=SyncMaster，但 Windows 没有
预置能匹配这个 EDID 的 monitor INF，就回落到内置 "Generic PnP Monitor"。重跑
`apply-gpu-spoof.ps1` 会直接改 `Enum\DISPLAY\*\*` 和 `Class\{4d36e96e-...}` 把
名字固定成 `Samsung SyncMaster S24F350`，RefreshName 任务也会每次开机再刷一次。

**Q: Windows Update 给我下发了 NVIDIA 真实驱动，虽然 bind 失败但 SetupAPI 留痕**
A: 不再用驱动锁策略压这个（策略键本身就是虚拟化指纹）。SetupAPI 留痕只是 `C:\Windows\INF\setupapi.dev.log` 里一行"无匹配设备"，反作弊通常不读；若真担心，在 WU 拉完之后清一下 `DriverStore\FileRepository\nv_dispi.*` 目录即可，别动策略键。

**Q: 想复现出完全一样的 SMBIOS 身份**
A: `SEED=<整数>` 固定种子，下次启动同一个 INSTANCE 会选到同样的主板/BIOS/序列号。

## 9. 目录速查

```
deploy/
├── docs/
│   ├── README.md          # 总览和设计目标
│   ├── USAGE.md           # 本文件
│   ├── NOTES-GPU.md       # GPU 伪装补充说明
│   ├── PLAN-GPU-NVIDIA.md # 0008 补丁 + GTX 1050 9 段工程文档
│   ├── VERIFY.md          # 检测面 vs 关闭手段对照表
│   └── verify-runs/       # 验证截图归档
├── patches/
│   ├── 0001-cpu-add-ryzen3-1200.patch
│   ├── 0002-kvm-strip-hypervisor.patch
│   ├── 0003-acpi-oem-spoof.patch
│   ├── 0004-nvme-samsung-id.patch
│   ├── 0005-pci-ids.patch
│   ├── 0006-smbios-dual-channel-bank.patch   # %C→A/B 让两条 DIMM 落到不同 bank
│   ├── 0007-pci-gpu-edid-spoof.patch         # virtio-vga EDID 宣告 1080p
│   ├── 0008-virtio-gpu-subsys.patch          # virtio-pci SUBSYS/REV 可配置
│   └── combined-stealth.patch                # 全合并
├── scripts/
│   ├── stealth-lib.sh                # SMBIOS 随机池 / MAC / OEM 字符串
│   ├── win10-ryzen3-stealth.sh       # 主启动器
│   ├── stop-vm.sh                    # 优雅停机：ACPI → QMP quit → SIGTERM → SIGKILL
│   ├── host-performance.sh           # 主机调优（需 sudo）
│   ├── setup-bridge.sh               # 一次性创建 br0 / 配 bridge.conf（需 sudo）
│   ├── reroll-identity.sh            # 删 .profile：让指定实例下次启动重滚身份
│   ├── qmp-frame.sh                  # QMP 控制入口
│   ├── verify-stealth.sh             # 离线自检
│   ├── guest-bootstrap.cmd           # 客机总 bootstrap（phase1+2 合并）
│   ├── guest-bootstrap-phase1.cmd    # 客机 phase1：密码 + RDP + NLA
│   ├── guest-bootstrap-phase2.cmd    # 客机 phase2：viogpudo + spoof
│   ├── apply-gpu-spoof.ps1           # 客机：改 Class + Enum\PCI，并装开机任务计划
│   └── host-fix-gpu-devpkey.sh       # 2026-04-20 新增：offline 修 DEVPKEY 类型 + SD (7.6 节)
├── virtio-win/
│   └── viogpudo-nvidia.inf           # optional INF 重贴品牌（需 testsigning）
└── tools/
    ├── apply-patches.sh              # 打补丁（幂等）并调用 build.sh
    └── build.sh                      # 构建（configure + ninja），支持 clean/reconfig/debug
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
