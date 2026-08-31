# 新建 NVIDIA vGPU VM：从 RTX6000-2Q 装驱动到消费卡身份

本文只适用于下面这条生产路径：

```text
deploy/scripts/create-vm.sh + deploy/scripts/create-disk.sh + deploy/scripts/start-vm.sh
```

这是本分支唯一的 VM 生命周期；日常启动和停止只使用
`deploy/scripts/start-vm.sh` 与 `deploy/scripts/stop-vm.sh`。

> **当前生产签名策略：** 历史 GTX1050 strict-A ZIP 会修改 INF 并自签 catalog，
> 已在 `finish-vgpu-install.sh` 中硬禁用。下文涉及
> patched driver/切 A 的信息仅是 legacy 说明，不能作为步骤执行。新 VM 统一保持
> B/native，由未修改 GRID driver 提供 NVIDIA/Microsoft 生产签名，型号显示走
> catalog/profile。

已有 VM 若遇到休眠 NTFS、`0x10E`、显示器缓存异常，或需要修复设备管理器/WMI 的
旧注册表名称，请按
[`VGPU-RECOVERY-RUNBOOK.md`](VGPU-RECOVERY-RUNBOOK.md) 逐步操作。
NVIDIA 控制面板产品名则应先排查 host per-mdev 配置和冷启动日志。

## 推荐入口：日常只记住 `deploy/scripts/start-vm.sh`

生命周期入口现在会按最终启动模式补齐缺失资源，不需要先手工运行
`create-vm.sh` / `create-disk.sh`：

| 命令 | 实例不存在时的行为 | 适用场景 |
|---|---|---|
| `./deploy/scripts/start-vm.sh 2` | 自动生成 `vm.conf`，严格从公共 base 创建 V-11 式增量盘，然后启动 | 已有合格 base，日常新建实例 |
| `./deploy/scripts/start-vm.sh 2 --install [ISO]` | 自动生成 `vm.conf`，严格创建空盘；安装期 helper 自动引导 xHCI USB Windows 光盘，并挂最小应答 ISO | 第一次制作 base，或确实要从 ISO 重装 |

`--install` 省略 ISO 时使用 `/home/ubuntu/images/iso/win10.iso`。这两个动作都只
补缺失文件：已有 `vm.conf` 保持原身份，已有 `disk.qcow2` 永不覆盖；因此给已有
实例加 `--install` 只会挂载 ISO。要真正抹盘重装，必须先明确执行生命周期删除，
不能让启动命令隐式销毁数据。

安装模式默认自动处理 OOBE：使用内置英文账号 `Administrator`、空密码并首次自动
登录，区域/输入法为中国大陆简体中文，时区为 `China Standard Time`（北京/上海
同属 UTC+8）。RTC 由宿主通过 `TZ=Asia/Shanghai` 和
`-rtc base=localtime,clock=vm,driftfix=slew` 提供；新装不写
`RealTimeIsUniversal`。NumLock 由宿主 QEMU 根据 guest USB LED 回报默认保持开启，
不依赖登录界面或用户注册表；specialize 阶段只一次性写 `HiberbootEnabled=0`，
避免首次“关机”变成 Fast Startup 休眠。
应答文件不含磁盘分区、
镜像版本选择或产品密钥；在安装界面中手动选 Windows 10 专业版、目标磁盘并完成
分区。它也不含 WinRM/RDP、网络下载或常驻任务，不会因为挂了应答介质就静默擦盘。
需要连 OOBE 也完整手动完成时使用：

```bash
./deploy/scripts/start-vm.sh 2 --install /path/to/windows.iso --manual-oobe
```

helper、USB Windows ISO 和应答 ISO 都是安装期设备；正式启动三者全部不挂载。
正式启动也不保留空光驱；需要 ISO 时才热插只读光驱，操作见
[`G11-OPTICAL-DRIVE.md`](G11-OPTICAL-DRIVE.md)。
`--manual-oobe` 只移除应答 ISO。默认 USB 路径异常时可显式加
`--install-media ide`，该慢速回退不持久化。完整傻瓜教程见
[`G11-INSTALL-MEDIA.md`](G11-INSTALL-MEDIA.md)。

宿主一次性前置依赖：

```bash
sudo apt install -y sudo python3 util-linux diffutils swtpm swtpm-tools xorriso ffmpeg
```

包名是 `swtpm-tools`（不是 `stpm-tools`）；它提供 `swtpm_setup` 和
`swtpm_localca`，供启动器初始化每个实例独立的 TPM 持久状态。
`util-linux` 提供默认 CPU 隔离需要的 `taskset` 与 `flock`，`diffutils`
提供安装副本一致性检查使用的 `cmp`；宿主还必须使用 cgroup v2 并暴露
`cpuset` controller。CPU 隔离默认是 fail-closed 的 `required` 模式。
`sudo` 是提权入口，必须预先可用。建议先交互执行 `sudo -v`，并在首次启动前
完成 root helper 和 sudoers 安装。无人值守确需凭据时，只能通过批准的安全渠道
或运行时环境变量提供；不得把宿主机密码写入仓库、配置或命令历史。前置安装失败时
VM 不会启动。

最短的新实例路径：

```bash
cd /home/ubuntu/projects/qemu

# 路径 A：公共 base 已验收，自动 clone 并启动
./deploy/scripts/start-vm.sh 2

# 路径 B：从 ISO 安装；即使公共 base 存在，缺盘时也只建空盘
./deploy/scripts/start-vm.sh 2 --install /home/ubuntu/images/iso/win10-ltsc.iso
```

普通启动找不到公共 base 时会拒绝静默创建一个不可启动的空盘，并提示改用
`--install`。ISO 路径错误也会在建盘前失败；修正路径后原命令重试即可。

VM ID 只使用正整数，例如 `2`；目录名会自动成为 `vm2`。`win10-2` 不是合法 ID，
`--install` 也只属于 `start-vm.sh`，不能传给 `create-vm.sh`。

需要固定首次生成的 GPU/显示器时，可先显式创建配置；这是高级入口，不是日常必需：

```bash
./deploy/scripts/create-vm.sh 2 \
  --gpu-profile gt1030_2gb \
  --monitor-profile benq-gw2480
./deploy/scripts/start-vm.sh 2
```

### 自动创建的确定性规则

| `vm.conf` | `disk.qcow2` | 最终模式 | 结果 |
|---|---|---|---|
| 缺失 | 任意 | 非 dry-run | 随机身份只生成一次并设为只读 |
| 任意 | 缺失 | `--install` | `create-disk --blank`，不读取/复制 base |
| 任意 | 任意 | `--install` | 默认挂临时 helper + USB Windows ISO + 最小 OOBE 应答 ISO；`--manual-oobe` 只关闭应答盘 |
| 任意 | 缺失 | 普通模式 | `create-disk --from-base --linked`；base 缺失则失败 |
| 任意 | 已存在 | 任意 | 原盘保持不变 |
| 缺失 | 任意 | `--dry-run` | 拒绝猜测身份，不创建任何资源 |

### guest 最小化边界

默认 native SDL/GTK 显示路径不需要也不会安装 `ivshmem.sys`、抓屏 relay、
`NvStreamSvc`、`AudioSvcHost` 或显示器脚本。显示器 EDID 由 host 在关机状态离线同步。
vGPU 本身仍必须在 guest 中保留匹配版本的 GRID 驱动和 license token；它们不是画面
转发组件，不能删除。

离线同步前，Windows 必须是完整关机而不是休眠/Fast Startup。GTX1050 的历史
strict-A ZIP 已禁用，当前保持 B，不运行 driver stager。当前 GTX750Ti、GT1030、
GTX1050 都使用同一个私有 `VgpuPortable.exe` 处理身份、token、Licensed 和电源
收尾；`finish-vgpu-install.sh` 只保留给统一前旧回执/UTC 迁移。这里不使用 RDP、
VNC、WinRM 或 guest HTTP，也不要让 host 强删 `hiberfil.sys`。

GPU 产品名默认也遵守 guest 最小化边界：使用默认/`--spoof-name-only` 时，host
按 mdev UUID 注入每 VM 名称，不需要仓库 PowerShell、启动任务或 NVAPI shim。
`--no-spoof` 则移除该 VM 的 per-mdev 名称项并保留驱动/mdev 原生身份。只有修复旧
base 的注册表残留时才需要 `sync-vgpu-profile.sh`；它不是新 clone 的必需步骤。

GRID driver 安装包由用户通过自己的文件传输方式放进 Windows 并本地运行。主新装
流程不启用远程管理服务，不下载脚本，也不创建固定实验凭据或 AutoLogon。

OOBE 应答介质只执行一条 `reg.exe` one-shot，把 `HiberbootEnabled` 设为 `0`；不会
写 `InitialKeyboardIndicators`、复制 PowerShell、创建服务或计划任务。G-11 的
`usb-kbd` 会读取 Windows HID `SET_REPORT` 的 NumLock LED 位：仅在明确 OFF 时原子
发送一次按下/释放并等待 ON，同一轮不会重复翻转。默认开启；本次确需关闭可给
`start-vm.sh` 加 `--no-numlock`。完整说明见
[`G11-NUMLOCK-FIRST-BOOT.md`](G11-NUMLOCK-FIRST-BOOT.md)。

空密码只适用于 QEMU 本地控制台。Windows 默认安全策略会拒绝空密码账号进行网络
登录；不要关闭这个限制。

当前 RTX 2080 unlock 宿主的每 VM 动态消费卡名由 host 的 vgpu_unlock per-mdev
override 完成，不需要 WinRM、guest 脚本或启动任务。官方 V100 宿主没有这个后端；
其模板默认关闭名称/PCI 覆盖并保留原生 V100 vGPU 身份。不要为了名称离线修改
Windows 的 boot-critical SYSTEM/SOFTWARE hive。

## 先理解四层身份

| 层 | 当前 off/B | legacy GTX1050 A（禁用） | 验收边界 |
|---|---|---|---|
| 宿主资源 | 1GB 为 `nvidia-256 / 1024 MB`，2GB 为 `nvidia-257 / 2048 MB` | `nvidia-257 / 2048 MB` | type 标签不是 guest 身份 |
| 外部 QEMU PCI | 1GB/1Q 为 `10DE:1E30 / 132510DE`，2GB/2Q 为 `10DE:1E30 / 132610DE` | `10DE:1C81 / 11C01028` | Windows PnP/GPU-Z Device ID |
| NVIDIA internal vdev/pdev | 继承 profile | `0x1C8111C0 / 0x1C81` | vGPU manager `Virtual Device Id` |
| Driver Store | 原版正式签名 GRID 538.33 | 修改 INF/自签 538.33（不合规） | `31.0.15.3833`、Code 0、生产签名 |

B 是所有 profile 当前的安全 name-only 路径。新 GTX1050 配置与其他型号一样记录
`VGPU_IDENTITY_TARGET=name-only`，不能手工切 A；旧 A 实例按生产迁移文档回到
原始 GRID driver 支持的 native PnP 身份。

“切成消费卡”不会改变底层 mdev、显存大小、物理频率或调度份额。六个芯片
身份按目录固定为 1024MB 或 2048MB，启动器必须分配同容量 mdev。

当前 RTX 2080/R535 宿主必须固定整池为 `nvidia-256/1024MB` 或
`nvidia-257/2048MB`。V100 全 1Q 推荐 R535/vGPU 16.4，并固定 `V100*-1Q`、
equal 1024MB。只有明确选择 V100/R580.159.01，且 NVIDIA 实时报告 heterogeneous
capability=`Supported`、mode=`Enabled` 时，才发布 1Q/2Q 双映射并允许混搭。完整
流程见 [`V100-ADAPTATION.md`](V100-ADAPTATION.md)。创建器、启动器和 mdev 分配器
仍会校验 profile、真实显存、parent 与总容量。

`deploy/host/gpu-mode.sh consumer` 是把**宿主机**切到消费版 NVIDIA 驱动，会让
mdev/vGPU 不可用；它与 guest 消费卡身份切换完全不是一回事。

## 当前可复现基线

截至 2026-07-12，这台宿主已验证稳定的组合是：

```text
host: 535.161.05
guest: 538.33 / DriverVersion 31.0.15.3833
```

staging 中的两个文件名历史上误写成了 `553.24`，内容实际是 538.33。运行安装器
前必须核对，不能用真正的 553.24 文件覆盖：

```bash
sha256sum \
  /home/ubuntu/images/staging/553.24.exe \
  /home/ubuntu/images/staging/553.24-display-driver.zip

# 本机已验证值：
# aaa3080c0b7e3a6fbe825a05725f4171c75072faa8b667d97556c1605a219ddd  553.24.exe
# a3d7ad8b8082d6ac6214565b4766b5190a819bc9b7574765b14897e0db809690  553.24-display-driver.zip

unzip -p /home/ubuntu/images/staging/553.24-display-driver.zip \
  Display.Driver/nvgridsw.inf | tr -d '\r' | rg '^DriverVer'
# 必须得到：DriverVer = 01/25/2024, 31.0.15.3833
```

更完整的版本说明见 [`DRIVER-INSTALL.md`](DRIVER-INSTALL.md)。

## 路线一：真正从空盘安装并制作 base

下面以 VM 4 为例。最短命令不指定显卡，首次启动会让 `create-vm.sh` 按
`VGPU_HOST_FB_TIER_MB` 从对应单档新建层随机一条并固化：2048MB 档使用 12 条
2GB 默认行，1024MB 档使用 4 条 Maxwell 1GB 新建行。一条命令完成配置、空盘和
安装启动：

```bash
cd /home/ubuntu/projects/qemu
VM_ID=4
ISO=/home/ubuntu/images/iso/win10.iso

./deploy/scripts/create-vm.sh --list-gpu-profiles
./deploy/scripts/create-vm.sh --list-monitor-profiles
./deploy/scripts/create-vm.sh --list-input-profiles
./deploy/scripts/check-hardware-pool.sh --machine-readable

./deploy/scripts/start-vm.sh "$VM_ID" --install "$ISO"
```

如果必须固定显卡，再额外设置 `PROFILE=gtx1050_2gb` 并使用
`GPU_PROFILE="$PROFILE" ./deploy/scripts/start-vm.sh "$VM_ID" --install "$ISO"`。

未显式指定显示器时，会先等概率随机一个中国大陆常见品牌，再随机该品牌的
21.5、23.8/24 或 27 英寸 FHD/1K（1920×1080@60）具体型号；profile 和显示器
序列只生成一次。完整目录 35 款与严格池 28 款都要求 preferred timing 为
1920×1080@60；1366×768、2560×1440 等不能混入为 profile 原生分辨率。型号来源、
尺寸档位和“不伪造 75 Hz 模式”的边界见
[`G11-MONITOR-POOL.md`](G11-MONITOR-POOL.md)。

普通新建品牌审计口径是主板 3、内存 5、SSD 5、GPU app-local 板卡 metadata 9、active
键盘 3、可选相对鼠标 3；显示器是明确例外（新建 8 品牌/完整 11 品牌）。默认绝对
指针只有 QEMU 通用 profile。GPU 板卡 metadata 的序列策略为 `not-exposed`，USB
输入为 `none`/`iSerialNumber=0`；不会拿 mdev UUID 或虚构 `serial=` 充数。显示器
只有 Samsung S24F350 与 Redmi RMMNT238NF 使用已审核的型号专属序列格式，其余
33 款明确为 `generic-prefix-hash`。全部品牌、固定设备例外与相对鼠标创建命令见
[`G11-HARDWARE-POOL.md`](G11-HARDWARE-POOL.md)。

底层 `q35`/ICH9 行为、ICH9-AHCI、`qemu-xhci` 和 QEMU `nvme` controller 是实现边界；
00:1f.0 的 LPC inventory identity 会按主板目录映射成 X79/H81/H97/B150/B360，
用来避免所有配置都被硬件工具标成 ICH9，但不代表完整 PCH 行为仿真；
安装/救援 `std-vga` 与 `--legacy-shmem` 的 `ivshmem` 是临时/旧兼容边界。它们不
参加品牌池，也不能因 profile 名称或 PCI metadata 被解释成完整物理设备仿真。

完整 25 条可选值以 `./deploy/scripts/create-vm.sh --list-gpu-profiles` 的实时输出
为准，包括 12 条 1GB 和 13 条 2GB 配置。新建生命周期为 12 条 2GB 默认、4 条
1GB Maxwell、1 条显式和 8 条 Kepler legacy；未显式指定时只从宿主容量档对应的
12 条或 4 条新建层随机，不会跨档。

可在另一终端确认配置已经固定到该 VM：

```bash
rg '^(GPU_PROFILE|GPU_NAME|GPU_PCI_DID|GPU_SUB_DID|VGPU_MDEV_PROFILE|VGPU_FB_MB|MONITOR_PROFILE|MONITOR_BRAND_NAME|MONITOR_MODEL_NAME|MONITOR_NATIVE_[XY])=' \
  "/home/ubuntu/images/vms/${VM_ID}/vm.conf"
```

默认布局下配置位于 `vms/${VM_ID}/vm.conf`，系统盘位于
`vms/${VM_ID}/disk.qcow2`。自定义路径请先用
`start-vm.sh "$VM_ID" --print-paths` 核对。完整目录说明见
[`STORAGE-LAYOUT.md`](STORAGE-LAYOUT.md)。

### 1-2. 自动建配置、空盘并安装 Windows

上面的 `start-vm.sh --install` 在盘缺失时内部固定调用 `create-disk.sh --blank`；
公共 base 是否存在不影响安装盘语义。等价的低级分步命令只用于调试或需要逐步检查时：

```bash
./deploy/scripts/create-vm.sh "$VM_ID" --gpu-profile "$PROFILE"
./deploy/scripts/create-disk.sh "$VM_ID" --blank
./deploy/scripts/start-vm.sh "$VM_ID" --install "$ISO"
```

安装模式使用 std-vga，**不挂 vGPU**。Windows ISO 默认经 xHCI USB BOT 读取，
helper 只负责 fresh NVRAM 自动引导；两者及应答盘在普通启动全部消失。安装显示只是
安装/救援临时设备，不计入三款 2 GB
GPU 品牌池。因此这一阶段看不到 RTX6000-2Q 是正常的；第一次挂 RTX6000-2Q 是
Windows 安装完成后的下一阶段。

Windows 文件复制和重启完成后，默认会跳过区域/账号页面并首次自动进入
`Administrator` 桌面；密码为空、时区为北京/上海 UTC+8、NumLock 默认开启。新装
不会写 `RealTimeIsUniversal`；宿主按本地 RTC 契约提供正确时间。
`--manual-oobe` 才会显示截图中的完整区域设置流程。

首次进入桌面后，只需确认 Windows 时区和时间：

```powershell
tzutil.exe /g
"Local: {0:o}" -f (Get-Date)
"UTC:   {0:o}" -f ([DateTime]::UtcNow)
```

期望 `China Standard Time`，本地时间为正确北京时间，UTC 行与真实 UTC 时刻一致。
不用检查或创建 `RealTimeIsUniversal`。

旧 `base=utc` VM/base 也不要运行 guest RTC 脚本。只有统一前、明确
`RTC_CONTRACT=utc` 的兼容资产，才在 Windows 完整关机后按其旧流程执行
`finish-vgpu-install.sh`；当前新 VM 已是 localtime，不需要这一步。

### 3. 宿主预检 RTX6000-2Q profile

先确保所有 VM 已停，再检查 host 驱动和 type 257：

```bash
systemctl is-active nvidia-vgpu-mgr
cat /sys/module/nvidia/version

# 可选的只读总览；不会创建 mdev，也不会写 sysfs
./deploy/host/probe-vgpu-host.sh --profile nvidia-257

VGPU_MGPU=${VGPU_MGPU:-0000:04:00.0}
TYPE_DIR="/sys/bus/pci/devices/$VGPU_MGPU/mdev_supported_types/nvidia-257"
cat "$TYPE_DIR/name"
cat "$TYPE_DIR/description"
```

资源验收只要求 description 包含 `framebuffer=2048M` 且实例容量正确；上面的 name
仅用于记录当前 type 级标签。

`$TYPE_DIR/name` 是 type 257 的全局名称，本机可能仍显示
`NVIDIA GeForce GT 1030`。这不再作为每 VM 名称的验收依据。启动器会在现有 host
全局锁内、创建 mdev 之前，按稳定的 `VM_UUID` 原子写入：

```toml
[mdev."<VM_UUID>"]
card_name = "<GPU_NAME>"
adapter_name = "<GPU_NAME>"
```

不要在 `[profile.nvidia-257]` 写 `card_name` 或 `adapter_name`，否则所有 VM 会被
改成同一个型号。per-mdev 配置由 unlock 在实例启动时读取，不需要重启
`nvidia-vgpu-mgr`；名称必须是 1..31 个 ASCII 可打印字节。

### 4. 用隔离 console 的真实 PCI 身份安装 GRID

```bash
./deploy/scripts/vmctl.sh driver-install "$VM_ID"
```

封装不添加任何 `x-pci-*` 消费卡覆盖。临时 `Microsoft Basic Display Adapter`
承担本地窗口，真实 mdev 以 native PnP 存在但固定 `display=off`，因此 GRID 首次接管
不会触发 R535 console 黑屏。安装完成后封装自动完整关机并离线认证 EDID/
`NV_Modes`，默认保持关机供继续制作母盘。

在 guest 管理员 PowerShell 中先确认 PnP 真 ID：

```powershell
Get-PnpDevice -Class Display -PresentOnly | Format-List Status,FriendlyName,InstanceId
# 1GB/nvidia-256 应为 SUBSYS_132510DE；2GB/nvidia-257 应为 SUBSYS_132610DE
```

### 5. 验收 538.33 guest 驱动

上一步会在宿主核对安装资产 hash/INF `DriverVer`，在活动桌面执行审核过的 GRID
538.33，并要求安装收据、完整关机和离线 INF/NV_Modes 认证全部通过。仓库 staging
中的 `553.24` 只是历史误名；验收内容版本必须是 538.33 / `31.0.15.3833`。
任一步失败都不要制作 base，也不要先切消费身份。

### 6. 统一完成身份、授权、电源和性能收尾

当前 25 条 B/native profile 没有型号专用分支。完整关机后，从普通 B 模式
重新启动，再在宿主
构建私有通用文件：

```bash
chmod 600 /home/ubuntu/images/staging/client_configuration_token.tok
./deploy/package-vgpu-one-click.sh --with-license-token
```

把 `VgpuPortableLicensed/VgpuPortable.exe` 安全复制进目标 Windows，双击后必须
看到性能优化 APPLY PASS、身份 INSTALL PASS、Code 0、`License: Licensed` 和
休眠/Fast Startup 已关闭，
然后完整关机并普通冷启动。不得复制 VM3 的 driver、证书、`oemN.inf` 或旧 marker，
也不运行型号专用 finish。详细说明见
[`VGPU-LICENSING.md`](VGPU-LICENSING.md)。

guest 管理员 PowerShell：

```powershell
$gpu = Get-CimInstance Win32_VideoController |
  Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' } |
  Select-Object -First 1
$gpu | Format-List Name,PNPDeviceID,DriverVersion,Status,ConfigManagerErrorCode,AdapterRAM
nvidia-smi -q | Select-String 'Product Name|Driver Version|License Status'
```

运行收尾前的 off 安装阶段验收条件：

- `PNPDeviceID` 含 `DEV_1E30`，并按资源档匹配 1GB/1Q 的
  `SUBSYS_132510DE` 或 2GB/2Q 的 `SUBSYS_132610DE`；
- `DriverVersion` 为 `31.0.15.3833`；
- `ConfigManagerErrorCode` 为 `0`；
- framebuffer 等于 `vm.conf` 的 `VGPU_FB_MB`（1GB 行为 1024MB，2GB 行为
  2048MB）；安装阶段不以产品名作为失败条件。

此时 token 可能尚未由收尾 EXE 安装，因此不要求预先显示 `Licensed`。任何驱动项不满足
都不要继续切换身份或制作公共 base；收尾后的 license/FRL 则按下一节的最终模式分别
验收。

### 7. 验收当前 B 身份

当前 25 条 profile 都保持 B，不要手工加 `--spoof`。日常启动：

```bash
./deploy/scripts/start-vm.sh "$VM_ID"
./deploy/scripts/report-vm-boot-timing.sh "$VM_ID"
```

预期 marketing name 等于 `vm.conf` 的型号，PCI 保持原生 `DEV_1E30`，Subsystem
按资源档为 1GB/1Q 的 `132510DE` 或 2GB/2Q 的 `132610DE`，driver 538.33、Code 0，framebuffer 等于配置的
1024/2048MB，并验收 DLS `Licensed`。六个芯片型号使用同一合同。

在 B 模式中，宿主验证可查看 vgpu manager 日志中的 mdev UUID 以及 `vgpu_name` /
`adapter_name` patch；然后重新打开 NVIDIA 控制面板，确认“系统信息”的图形卡名称
等于 `vm.conf` 的 `GPU_NAME`。25 条 profile 都以原生 PCI tuple、正式签名 driver、
Code 0 和 Licensed 为主验收条件；日志中的 backing type 名称不是失败判据：

```bash
journalctl -b -u nvidia-vgpu-mgr -u nvidia-vgpud --no-pager | \
  rg 'Applying mdev UUID|Patching .*?(vgpu_name|adapter_name)'
```

旧 base 若有 `RefreshGridNames` 任务或错误的 WMI 名称，可选择运行
`sync-vgpu-profile.sh "$VM_ID"` 做注册表修复；默认仍不安装 NVAPI shim。只有确认
当前 host/driver 不接受 per-mdev 产品名时，才使用显式的
`--with-nvapi-shim` 兼容回退。该回退会替换 Windows 的 x64/x86 NVAPI DLL，不属于
guest-minimal 路径。

验证：

```powershell
$gpu = Get-CimInstance Win32_VideoController |
  Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' } |
  Select-Object -First 1
$gpu | Format-List Name,PNPDeviceID,DriverVersion,Status,ConfigManagerErrorCode,AdapterRAM
nvidia-smi -q | Select-String 'License Status'
```

预期结果：

- `Name` 等于 `vms/N/vm.conf` 中的 `GPU_NAME`；
- 当前 25 条 profile 都保持 B，为原生 `DEV_1E30`，并分别使用 1GB/1Q 的
  `SUBSYS_132510DE` 或 2GB/2Q 的 `SUBSYS_132610DE`，Code 0、
  Licensed；marketing name 等于配置；
- 显存等于目录的 1GB 或 2GB，不接受跨容量替代。

这里保证的是 marketing name。CUDA 核心数、时钟、显存类型和总线位宽仍由底层
vGPU/物理卡路径上报，host-only 配置不会把这些数值伪装成消费卡规格。

这就是当前仓库支持的“用原生 vGPU PCI 身份安装正式签名 GRID driver，再保持 B
并由 host 按 VM 注入 marketing name”流程。历史 GTX1050 strict-A 自签转换不属于
当前支持路径。

### 8. 关机并制作 base

只在驱动和目标模式全部验收通过后制作 base。当前 25 条 profile 都要求 B/off、
Code 0 和 Licensed。`seal-base.sh` 要取得
独占存储锁，因此先正常关闭所有生产 VM，不只是模板 VM；它也会拒绝替换仍被
任何 overlay 引用的公共 base：

```powershell
shutdown /s /t 0
```

```bash
BASE_NAME=win10-ltsc-v1
./deploy/scripts/vmctl.sh seal "$VM_ID" "$BASE_NAME"
```

`vmctl seal` 封装 `seal-base.sh`。与 V-11 一样，它默认先离线删除源盘中的
WeGame/Tencent QIMEI、登录态、SSO/SDK/设备缓存、D3DSCache 和相应注册表键，
避免所有 clone 继承同一份身份。它不删除 ACE 程序；dirty/hibernated NTFS、
清理失败或 hive 校验失败都会停止且不发布 base。只有明确需要保留这些状态时才用
`./deploy/scripts/vmctl.sh seal "$VM_ID" "$BASE_NAME" --no-clean`。

已完成 G-11 存储迁移时，新 base 与 V-11 一样写入
`vms/_base/<BASE_NAME>.qcow2`。私有 Sysprep 一键流程只保留当前 qcow2，不创建
`archive/`；普通显式替换流程仍可按其提示保留回滚代次。旧平铺
`vms/win10-base.qcow2` 不属于新 G-11
默认布局，也不会被普通启动偷偷采用；应先按
[`STORAGE-LAYOUT.md`](STORAGE-LAYOUT.md) 停机、备份并完成受控迁移，再制作或
替换新布局下的 base。

base 中必须只保留未经修改且具有 NVIDIA/Microsoft 生产签名的 GRID driver；若
组织策略允许，也可保留已经正常安装到 NVIDIA 标准目录的 token，但不得留下包含
凭据的私有 portable。不得包含 patched driver、自签 catalog、私有根或测试签名配置。制作前必须
确认 `vm.conf` 使用 `RTC_CONTRACT=localtime`；新 base 不应包含
`RealTimeIsUniversal`，否则每个 clone 都可能继承 RTC 回拨和 B/off 授权失败。
不要把消费身份同步脚本、`RefreshGridNames` 任务或已执行的 NVAPI 身份层做进新
base；B 模式的每 VM 产品名由 host 在每次创建 mdev 时提供。默认只放尚未执行、
无 VM 绑定的 `VgpuPortable.exe`。portable 不内嵌、不下载、不要求 GPU-Z；它在
每个 clone 内首次双击时按本次启动的只读 firmware claim 安装受保护的
application-local 身份层、权威查询器和推荐 guest 性能优化；优化的原状态按该
clone 单独保存，不会从 base 继承回滚快照。

这里注入的必须是默认 `VgpuPortable/VgpuPortable.exe`。不要把
`VgpuPortableLicensed/VgpuPortable.exe` 写入通用 base；后者含 DLS 凭据，只在需要
为单台实际 VM 补授权时安全传入并运行。

所有 VM 保持停止后，为这个 base 一次性构建 portable EXE，并按默认单文件方式
安全注入：

```bash
cd /home/ubuntu/projects/qemu
BASE_NAME=win10-ltsc-v1
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh --base-name "$BASE_NAME"
```

注入器不会直接挂载 live base，而是修改私有临时副本；它会复验 portable 回执，
并在 schema-5 base 证明中记录 `gpuZIncluded=false` 和统一性能 profile，同时拒绝
dirty/hibernated NTFS、活动持有者、backing/data-file 和被其他 qcow2 依赖的 base。完整验证、
卸载和 `qemu-img check` 后才归档旧 base 并原子替换。不要用强制 NTFS 挂载或
`remove_hiberfile` 绕过。

只有明确希望所有克隆都预置经过审计的 GPU-Z 2.70 时，才给 base 注入命令增加
`--with-gpuz`；普通基础盘不加。以后也可在单台 guest 中从官网取得审计文件，
精确命名为 `GPU-Z.exe`，再运行 `VgpuPortable.exe /with-gpuz`。

## 路线二：从合格 base 新建普通实例

已有按上面流程验收过的
`vms/_base/<BASE_NAME>.qcow2` 及其同名 portable 证明后，不要为每台 VM 重装 Windows 和
NVIDIA 驱动：

该 base 必须是 standalone qcow2；`create-disk.sh` 会验证无 backing、执行
`qemu-img check`，把母盘 inode hard-link 固定为实例内 `.base.qcow2`，再通过临时
文件原子发布只保存写入的 `disk.qcow2` overlay。校验失败不会留下最终盘名或 pin。

```bash
cd /home/ubuntu/projects/qemu
BASE_NAME=win10-ltsc-v1
./deploy/scripts/vmctl.sh clone "$BASE_NAME" 5 --gpu-profile gt1030_2gb --start
```

`vmctl clone` 封装 `clone-from-base.sh`。脚本验证 base 自 portable 注入后没有改变，
创建新的 VM UUID/B 配置，再严格调用 `create-disk.sh --from-base`；即使 base 在
检查与建链之间消失也不会退回创建空盘。默认增量盘刚创建通常只有几百 KB；只有
显式传 `--full-copy` 才复制成可脱离母盘的 standalone 实例。不传
`--monitor-profile` 时自动从审核池
生成并固定显示器，克隆完成后立即同步；`--start` 仅决定是否立刻开机，普通启动
还会自动复核，因此无需单独执行 `vmctl monitor`。
默认克隆的公共桌面只有 `VgpuPortable.exe`。Windows 启动后双击一次，它会读取
`start-vm.sh` 自动注入的只读 profile/UUID/catalog claim 并选择 GT 1030；不需要
HTTP、WinRM、另一终端或 guest 完成后的 host commit，也不再运行独立 Audit/Apply
文件。看到最终 INSTALL PASS 后完整关机并正常冷启动。

安装完成后用 `vGPU Identity Query` 权威验收型号、板卡品牌和显存厂家，最后必须
显示 `VERIFY PASS`。默认流程完全不读取同目录 GPU-Z。以后显式选装后，才会创建
`GPU-Z (vGPU profile)` 快捷方式；原来的 TechPowerUp GPU-Z 进程不会继承
app-local shim，可显示原生 TU102，且 profile 快捷方式中未覆盖的底层字段也可能
仍显示 TU102/12 nm/754 mm²。

然后按路线一的 PowerShell 命令验收名称、PCI ID、Code 0、目录显存和
license。若
base 没有已安装 token，就为该实际 VM 运行私有统一 portable。本例 GT1030 和目标
为 GTX1050 的 clone 都保持 B，并按原生 PnP、Code 0 和 `Licensed` 验收；不要运行
旧 strict/型号专用 finish。

## 关于完整 PCI 消费身份 A

当前工具链不自动完成任何 strict-A：GTX1050 历史路径会重建自签 catalog，已永久
fail-closed；当前 25 条 profile 均继续 B。旧 `guest/spoof-inf` 与 patched artifact 仅是
历史实验设计，不能替代 [`DRIVER-INSTALL.md`](DRIVER-INSTALL.md) 的生产签名边界。

## 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| Windows 安装时看不到 RTX6000-2Q | `--install` 故意不挂 vGPU | 装完 Windows 后关机，再用 `--no-spoof` |
| `/sys/.../nvidia-257/name` 仍是 GT 1030 | 这是全局 type 名，不是 per-mdev 结果 | 查 vgpu manager 的 UUID/patch 日志，再以 guest 控制面板验收 |
| PnP 是 `DEV_1E30`，但 WMI 还是模板旧型号 | 旧 base 的注册表/`RefreshGridNames` 任务覆盖了显示名 | 可选运行 `sync-vgpu-profile.sh <vm_id>`；无需安装 shim |
| WMI 正确，但 NVIDIA“系统信息”仍是 GT 1030 | mdev 未冷重建、per-mdev 配置未被读取，或当前 unlock/driver 不兼容 | 先正常关机并重新启动、核对 UUID/patch 日志；最后才考虑 `--with-nvapi-shim` |
| 历史 A 启动后变 Basic Display Adapter / 分辨率减少 | driver 不合规或未绑定，不是 EDID 首因 | `--no-spoof --no-monitor-sync` 回退，安装正式签名 GRID driver 并保持 B；不要重跑 strict 收尾 |
| installer 文案写 553.24 | staging 历史文件名错误 | 以 SHA256 和 INF `31.0.15.3833` 为准，不要替换成真正 553.24 |
| `sync-vgpu-profile.sh` 找不到 guest | ARP 还没有该 VM 的 IP，或 WinRM 未就绪 | 等待网络；必要时传 `--ip A.B.C.D` |
