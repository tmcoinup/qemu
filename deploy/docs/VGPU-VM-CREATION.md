# 新建 NVIDIA vGPU VM：从 RTX6000-2Q 装驱动到消费卡身份

本文只适用于下面这条生产路径：

```text
deploy/create-vm.sh + deploy/create-disk.sh + deploy/start-vm.sh
```

这是本分支唯一的 VM 生命周期；日常启动和停止只使用
`deploy/start-vm.sh` 与 `deploy/stop-vm.sh`。

> **当前生产签名策略：** 历史 GTX1050 strict-A ZIP 会修改 INF 并自签 catalog，
> 已在 `finish-vgpu-install.sh` 中硬禁用。下文涉及
> patched driver/切 A 的信息仅是 legacy 说明，不能作为步骤执行。新 VM 统一保持
> B/native，由未修改 GRID driver 提供 NVIDIA/Microsoft 生产签名，型号显示走
> catalog/profile。

已有 VM 若遇到休眠 NTFS、`0x10E`、显示器缓存异常，或需要修复设备管理器/WMI 的
旧注册表名称，请按
[`VGPU-RECOVERY-RUNBOOK.md`](VGPU-RECOVERY-RUNBOOK.md) 逐步操作。
NVIDIA 控制面板产品名则应先排查 host per-mdev 配置和冷启动日志。

## 推荐入口：日常只记住 `start-vm.sh`

生命周期入口现在会按最终启动模式补齐缺失资源，不需要先手工运行
`create-vm.sh` / `create-disk.sh`：

| 命令 | 实例不存在时的行为 | 适用场景 |
|---|---|---|
| `./deploy/start-vm.sh 2` | 自动生成 `vm.conf`，严格从公共 base 复制系统盘，然后启动 | 已有合格 base，日常新建实例 |
| `./deploy/start-vm.sh 2 --install [ISO]` | 自动生成 `vm.conf`，严格创建空盘，挂 Windows ISO 和最小应答 ISO 后启动 | 第一次制作 base，或确实要从 ISO 重装 |

`--install` 省略 ISO 时使用 `/home/ubuntu/images/iso/win10.iso`。这两个动作都只
补缺失文件：已有 `vm.conf` 保持原身份，已有 `disk.qcow2` 永不覆盖；因此给已有
实例加 `--install` 只会挂载 ISO。要真正抹盘重装，必须先明确执行生命周期删除，
不能让启动命令隐式销毁数据。

安装模式默认自动处理 OOBE：使用内置英文账号 `Administrator`、空密码并首次自动
登录，区域/输入法为中国大陆简体中文，时区为 `China Standard Time`（北京/上海
同属 UTC+8）。RTC 由宿主通过 `TZ=Asia/Shanghai` 和
`-rtc base=localtime,clock=host,driftfix=slew` 提供；新装不写
`RealTimeIsUniversal`。登录界面和该账号的 NumLock 默认开启。
应答文件不含磁盘分区、
镜像版本选择或产品密钥；在安装界面中手动选 Windows 10 专业版、目标磁盘并完成
分区。它也不含 WinRM/RDP、网络下载或常驻任务，不会因为挂了应答介质就静默擦盘。
需要连 OOBE 也完整手动完成时使用：

```bash
./deploy/start-vm.sh 2 --install /path/to/windows.iso --manual-oobe
```

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
./deploy/start-vm.sh 2

# 路径 B：从 ISO 安装；即使公共 base 存在，缺盘时也只建空盘
./deploy/start-vm.sh 2 --install /home/ubuntu/images/iso/win10-ltsc.iso
```

普通启动找不到公共 base 时会拒绝静默创建一个不可启动的空盘，并提示改用
`--install`。ISO 路径错误也会在建盘前失败；修正路径后原命令重试即可。

VM ID 只使用正整数，例如 `2`；目录名会自动成为 `vm2`。`win10-2` 不是合法 ID，
`--install` 也只属于 `start-vm.sh`，不能传给 `create-vm.sh`。

需要固定首次生成的 GPU/显示器时，可先显式创建配置；这是高级入口，不是日常必需：

```bash
./deploy/create-vm.sh 2 \
  --gpu-profile gt1030_2gb \
  --monitor-profile benq-gw2480
./deploy/start-vm.sh 2
```

### 自动创建的确定性规则

| `vm.conf` | `disk.qcow2` | 最终模式 | 结果 |
|---|---|---|---|
| 缺失 | 任意 | 非 dry-run | 随机身份只生成一次并设为只读 |
| 任意 | 缺失 | `--install` | `create-disk --blank`，不读取/复制 base |
| 任意 | 任意 | `--install` | 默认挂最小 OOBE 应答 ISO；`--manual-oobe` 可关闭 |
| 任意 | 缺失 | 普通模式 | `create-disk --from-base`；base 缺失则失败 |
| 任意 | 已存在 | 任意 | 原盘保持不变 |
| 缺失 | 任意 | `--dry-run` | 拒绝猜测身份，不创建任何资源 |

### guest 最小化边界

默认 native SDL/GTK 显示路径不需要也不会安装 `ivshmem.sys`、抓屏 relay、
`NvStreamSvc`、`AudioSvcHost` 或显示器脚本。显示器 EDID 由 host 在关机状态离线同步。
vGPU 本身仍必须在 guest 中保留匹配版本的 GRID 驱动和 license token；它们不是画面
转发组件，不能删除。

离线同步前，Windows 必须是完整关机而不是休眠/Fast Startup。GTX1050 的历史
strict-A ZIP 已禁用，当前保持 B，不运行 driver stager。GTX750Ti/GT1030 的 legacy
B 收尾仍可使用小 `VgpuGuestFinish.exe` 处理 token/休眠/RTC；宿主核验当前 VM 的
UUID/GPU/token 后再离线同步。这里不使用 RDP、VNC、WinRM 或 guest HTTP，也不要让
host 强删 `hiberfil.sys`。

GPU 产品名默认也遵守 guest 最小化边界：使用默认/`--spoof-name-only` 时，host
按 mdev UUID 注入每 VM 名称，不需要仓库 PowerShell、启动任务或 NVAPI shim。
`--no-spoof` 则移除该 VM 的 per-mdev 名称项并保留驱动/mdev 原生身份。只有修复旧
base 的注册表残留时才需要 `sync-vgpu-profile.sh`；它不是新 clone 的必需步骤。

GRID driver 安装包由用户通过自己的文件传输方式放进 Windows 并本地运行。主新装
流程不启用远程管理服务，不下载脚本，也不创建固定实验凭据或 AutoLogon。

OOBE 应答介质只执行两条 `reg.exe` one-shot，把登录界面和 `Administrator` 的
`InitialKeyboardIndicators` 设为 `2`；不会复制 PowerShell、创建服务或计划任务。
不做 host/guest NumLock 动态同步：QEMU 输入链路没有可靠的 LED 双向状态查询，
启动时盲目发送 NumLock 只能“切换”而不能幂等地“设为开”。

空密码只适用于 QEMU 本地控制台。Windows 默认安全策略会拒绝空密码账号进行网络
登录；不要关闭这个限制。

每 VM 动态消费卡名由 host 的 vgpu_unlock per-mdev override 完成，不需要 WinRM、
guest 脚本或启动任务。不要为了名称离线修改 Windows 的 boot-critical
SYSTEM/SOFTWARE hive。

## 先理解四层身份

| 层 | 当前 off/B | legacy GTX1050 A（禁用） | 验收边界 |
|---|---|---|---|
| 宿主资源 | `nvidia-257 / 2048 MB` | 相同 | type 标签可能仍是 GT1030，不是 guest 身份 |
| 外部 QEMU PCI | `10DE:1E30 / 132610DE` | `10DE:1C81 / 11C01028` | Windows PnP/GPU-Z Device ID |
| NVIDIA internal vdev/pdev | 继承 profile | `0x1C8111C0 / 0x1C81` | vGPU manager `Virtual Device Id` |
| Driver Store | 原版正式签名 GRID 538.33 | 修改 INF/自签 538.33（不合规） | `31.0.15.3833`、Code 0、生产签名 |

B 是所有 profile 当前的安全 name-only 路径。新 GTX1050 配置与其他型号一样记录
`VGPU_IDENTITY_TARGET=name-only`，不能手工切 A；旧 A 实例按生产迁移文档回到
原始 GRID driver 支持的 native PnP 身份。

“切成消费卡”不会改变底层 mdev、显存大小、物理频率或调度份额。三种消费身份
始终共用 `nvidia-257 / 2048 MB`。

本教程也要求宿主资源配置最终解析为 `VGPU_RESOURCE_PROFILE=nvidia-257`、
`VGPU_RESOURCE_FB_MB=2048`。如果 `deploy/host/vgpu-host.conf` 正在把资源切到
V100 profile，请先改回 RTX6000-2Q 对应的 2 GB profile；V100 适配流程见
[`V100-ADAPTATION.md`](V100-ADAPTATION.md)，不要混用不同宿主资源配置。
`deploy/host/vgpu-host.conf` 是可选的本机覆盖文件；不存在时启动器正常回退到
`nvidia-257 / 2048 MB`，示例文件是 `deploy/host/vgpu-host-v100.conf.example`。

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

下面以 VM 4、最终身份 GTX 1050 2GB 为例。首次启动把环境中的 profile 传给
自动调用的 `create-vm.sh`，一条命令完成配置、空盘和安装启动：

```bash
cd /home/ubuntu/projects/qemu
VM_ID=4
PROFILE=gtx1050_2gb
ISO=/home/ubuntu/images/iso/win10-ltsc.iso

./deploy/create-vm.sh --list-gpu-profiles
./deploy/create-vm.sh --list-monitor-profiles

GPU_PROFILE="$PROFILE" ./deploy/start-vm.sh "$VM_ID" --install "$ISO"
```

未显式指定显示器时，会先等概率随机一个中国大陆常见品牌，再随机该品牌的
23.8/24 英寸 FHD/1K（1920×1080）具体型号；结果和序列号只生成一次。

可选值为：

```text
gtx750ti_2gb
gt1030_2gb
gtx1050_2gb
```

可在另一终端确认配置已经固定到该 VM：

```bash
rg '^(GPU_PROFILE|GPU_NAME|GPU_PCI_DID|GPU_SUB_DID|VGPU_MDEV_PROFILE|VGPU_FB_MB|MONITOR_PROFILE|MONITOR_BRAND_NAME|MONITOR_MODEL_NAME|MONITOR_NATIVE_[XY])=' \
  "/home/ubuntu/images/vms/G-11/vm${VM_ID}/vm.conf"
```

默认布局下配置位于 `vms/G-11/vm${VM_ID}/vm.conf`，系统盘位于
`vms/G-11/vm${VM_ID}/disk.qcow2`。自定义路径请先用
`start-vm.sh "$VM_ID" --print-paths` 核对。完整目录说明见
[`STORAGE-LAYOUT.md`](STORAGE-LAYOUT.md)。

### 1-2. 自动建配置、空盘并安装 Windows

上面的 `start-vm.sh --install` 在盘缺失时内部固定调用 `create-disk.sh --blank`；
公共 base 是否存在不影响安装盘语义。等价的低级分步命令只用于调试或需要逐步检查时：

```bash
./deploy/create-vm.sh "$VM_ID" --gpu-profile "$PROFILE"
./deploy/create-disk.sh "$VM_ID" --blank
./deploy/start-vm.sh "$VM_ID" --install "$ISO"
```

安装模式使用 std-vga，**不挂 vGPU**。因此这一阶段看不到 RTX6000-2Q 是正常的；
第一次挂 RTX6000-2Q 是 Windows 安装完成后的下一阶段。

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

旧 `base=utc` VM/base 也不要运行 guest RTC 脚本。让 Windows 完整关机后执行
`finish-vgpu-install.sh`；脚本会兼容启动旧契约，等 guest EXE 再次完整关机后，由
宿主备份 SYSTEM hive、离线删除旧 DWORD，并写入 `RTC_CONTRACT=localtime`。

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

### 4. 用真实 PCI 身份启动 vGPU

```bash
# 终端 A；保持前台运行
./deploy/start-vm.sh "$VM_ID" --no-spoof --no-monitor-sync
```

此时 QEMU 不添加任何 `x-pci-*` 消费卡覆盖。驱动安装前，Windows 可能只显示
`Microsoft Basic Display Adapter`；原版 GRID 驱动成功绑定后应出现 NVIDIA
适配器，但产品名可能继承当前 type 级标签。新装此时跳过 EDID 同步，是为了在关闭
休眠/Fast Startup 前不离线写 NTFS；最终由收尾脚本完成同步。

在 guest 管理员 PowerShell 中先确认 PnP 真 ID：

```powershell
Get-PnpDevice -Class Display -PresentOnly | Format-List Status,FriendlyName,InstanceId
# NVIDIA 项应包含 DEV_1E30&SUBSYS_132610DE
```

### 5. 安装 538.33 guest 驱动

先在宿主核对安装资产 hash 和 INF `DriverVer`，再用自己的文件传输方式把已验证的
GRID 538.33 安装包放进 Windows，在当前本地 QEMU 窗口中运行 NVIDIA 安装器。不要
从 guest 下载脚本或安装包，也不需要远程管理服务。仓库 staging 中的 `553.24`
只是历史误名；验收内容版本必须是 538.33 / `31.0.15.3833`。

驱动安装完成后，让 Windows 完整关机。不要制作 base，也不要先切消费身份。

### 6. 验收原生正式签名安装状态

GTX1050 不运行 legacy finish；该入口会在生成包前拒绝，VM 保持 B。GTX750Ti/
GT1030 如需 legacy token/RTC 收尾，可在完整关机后运行
`./deploy/finish-vgpu-install.sh "$VM_ID"` 并使用打印的小 EXE。不得复制 VM3 的
driver、证书、`oemN.inf` 或完成 marker。详细说明见
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

- `PNPDeviceID` 含 `DEV_1E30&SUBSYS_132610DE`；
- `DriverVersion` 为 `31.0.15.3833`；
- `ConfigManagerErrorCode` 为 `0`；
- framebuffer 为约 2 GB；安装阶段不以产品名作为失败条件。

此时 token 可能尚未由收尾 EXE 安装，因此不要求预先显示 `Licensed`。任何驱动项不满足
都不要继续切换身份或制作公共 base；收尾后的 license/FRL 则按下一节的最终模式分别
验收。

### 7. 验收当前 B 身份

当前三款 profile 都保持 B，不要手工加 `--spoof`。日常启动：

```bash
./deploy/start-vm.sh "$VM_ID"
./deploy/report-vm-boot-timing.sh "$VM_ID"
```

预期 marketing name 等于 `vm.conf` 的型号，PCI 保持原生
`DEV_1E30&SUBSYS_132610DE`，driver 538.33、Code 0、2048 MB，并验收 DLS
`Licensed`。GTX1050 与 GTX750Ti/GT1030 使用同一合同。

在 B 模式中，宿主验证可查看 vgpu manager 日志中的 mdev UUID 以及 `vgpu_name` /
`adapter_name` patch；然后重新打开 NVIDIA 控制面板，确认“系统信息”的图形卡名称
等于 `vm.conf` 的 `GPU_NAME`。三款 profile 都以原生 PCI tuple、正式签名 driver、
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

- `Name` 等于 `G-11/vmN/vm.conf` 中的 `GPU_NAME`；
- 三款当前 profile 都保持 B，为原生 `DEV_1E30&SUBSYS_132610DE`、Code 0、
  Licensed；marketing name 等于配置；
- 显存均约 2 GB。

这里保证的是 marketing name。CUDA 核心数、时钟、显存类型和总线位宽仍由底层
vGPU/物理卡路径上报，host-only 配置不会把这些数值伪装成消费卡规格。

这就是当前仓库支持的“用原生 vGPU PCI 身份安装正式签名 GRID driver，再保持 B
并由 host 按 VM 注入 marketing name”流程。历史 GTX1050 strict-A 自签转换不属于
当前支持路径。

### 8. 关机并制作 base

只在驱动和目标模式全部验收通过后制作 base。当前三款 profile 都要求 B/off、
Code 0 和 Licensed。`promote-base.sh` 要取得
独占存储锁，因此先正常关闭所有生产 VM，不只是模板 VM；它也会拒绝替换仍被
任何 overlay 引用的公共 base：

```powershell
shutdown /s /t 0
```

```bash
./deploy/promote-base.sh "$VM_ID"
```

已完成 G-11 存储迁移时，新 base 写入
`vms/G-11/shared/bases/win10-base.qcow2`，旧 base 归档到
`vms/G-11/shared/bases/archive/`。旧平铺 `vms/win10-base.qcow2` 不属于新 G-11
默认布局，也不会被普通启动偷偷采用；应先按
[`STORAGE-LAYOUT.md`](STORAGE-LAYOUT.md) 停机、备份并完成受控迁移，再制作或
替换新布局下的 base。

base 中必须只保留未经修改且具有 NVIDIA/Microsoft 生产签名的 GRID driver 和
token；不得包含 patched driver、自签 catalog、私有根或测试签名配置。制作前必须
确认 `vm.conf` 使用 `RTC_CONTRACT=localtime`；新 base 不应包含
`RealTimeIsUniversal`，否则每个 clone 都可能继承 RTC 回拨和 B/off 授权失败。
不要把消费身份同步脚本、`RefreshGridNames` 任务或 NVAPI shim 做进新 base；B 模式
的每 VM 产品名由 host 在每次创建 mdev 时提供。可以放入的是尚未执行、无 VM
绑定的离线 `VgpuPortable.exe`；它在每个 clone 内首次双击时才按本次启动的只读
firmware claim 安装受保护的 GPU-Z application-local 身份层。

所有 VM 保持停止后，为这个 base 一次性构建并安全注入 portable EXE：

```bash
cd /home/ubuntu/projects/qemu
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh
```

注入器不会直接挂载 live base，而是修改私有临时副本；它拒绝 dirty/hibernated
NTFS、活动持有者、backing/data-file 和被其他 qcow2 依赖的 base。完整验证、
卸载和 `qemu-img check` 后才归档旧 base 并原子替换。不要用强制 NTFS 挂载或
`remove_hiberfile` 绕过。

## 路线二：从合格 base 新建普通实例

已有按上面流程验收过的
`vms/G-11/shared/bases/win10-base.qcow2` 后，不要为每台 VM 重装 Windows 和
NVIDIA 驱动：

该 base 必须是 standalone qcow2；`create-disk.sh` 会验证无 backing、执行
`qemu-img check`，并通过临时文件原子发布克隆盘。校验失败不会留下最终盘名。

```bash
cd /home/ubuntu/projects/qemu
./deploy/clone-vgpu-base.sh 5 --gpu-profile gt1030_2gb --start
```

脚本验证 base 自 portable 注入后没有改变，创建新的 VM UUID/B 配置，再严格调用
`create-disk.sh --from-base`；即使 base 在检查与复制之间消失也不会退回创建空盘。
克隆的公共桌面已有 `VgpuPortable.exe`。Windows 启动后双击一次，它会读取
`start-vm.sh` 自动注入的只读 profile/UUID/catalog claim 并选择 GT 1030；不需要
HTTP、WinRM、另一终端或 guest 完成后的 host commit。

然后按路线一第 7 步的 PowerShell 命令验收名称、PCI ID、Code 0、2 GB 和 license。
本例 GT1030 保持 B，所以要求 `Licensed`。若 clone 的配置目标是 GTX1050，也始终
安全停留在 B，并按原生 PnP、Code 0 和 `Licensed` 验收；不要运行已禁用的 strict
收尾。未来取得匹配目标 tuple 的正式生产签名驱动后，再另行审计 transition。

## 关于完整 PCI 消费身份 A

当前工具链不自动完成任何 strict-A：GTX1050 历史路径会重建自签 catalog，已永久
fail-closed；三款 profile 均继续 B。旧 `guest/spoof-inf` 与 patched artifact 仅是
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
