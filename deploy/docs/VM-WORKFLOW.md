# VM 装机 + 克隆完整操作手册

按顺序跟着做，每一步用了什么脚本说清楚。**前提**：host 已经 setup-bridge 过、QEMU 已编、stealth OVMF 已 build 过（这些是一次性工作，正常无需重做）。

---

## 阶段 0：host 端生成统一离线 EXE

全新系统和 clone 都只运行 `respawn-stealth.exe`。显示驱动、签名 CAT/INF、安装器和
初始化脚本已经内嵌，不需要启动 `serve-stealth-http.py`：

```bash
bash deploy/guest-stealth/package.sh
sha256sum deploy/guest-stealth/dist/respawn-stealth.exe
```

每次修改 `respawn-stealth-local.ps1`、`apply-gpu-spoof.ps1`、安装器或 stock 驱动后，
都必须重新构建并替换 guest 中的旧 EXE。`deploy/scripts/respawn-stealth.ps1` 与
`shallow-stealth.ps1` 已改为无副作用 fail-fast 迁移提示，不能再作为调试入口；当前
流程也不需要 HTTP server。

---

## 阶段 A：VM1 装 Win10 22H2

### A.1 启动 VM 装系统

```bash
# 删旧 VM1（如有），从 base ISO 装新机
rm -rf /home/ubuntu/images/vms/1/{disk.qcow2,profile,ovmf-vars.fd,tpm-state}

# 启动装机
/home/ubuntu/projects/qemu/deploy/scripts/start-vm.sh 1 \
    --iso=/mnt/disk2/iso/Win10_22H2_Chinese_Simplified_x64v1.iso
```

启动日志会显示 `=== stealth profile ===`，GPU 型号不用手记；EXE 会按 PCI SUBSYS 自动查表。

启动器默认给 `usb-kbd` 加 `x-force-numlock-on=on`。QEMU 等 Windows 用 HID
`SET_REPORT` 明确回报 NumLock OFF 后才异步送一次 NumLock；已是 ON 时不会翻转，
也不修改 Windows 注册表或 Linux XKB。临时关闭策略可传 `--no-numlock`。

### A.2 装机选项

- 选 **Windows 10 专业版**（install.wim index=4）
- OOBE 阶段：选"中国 / 简体中文 / 微软拼音"，账号选**离线账号**（Shift+F10 → `oobe\BypassNRO` 跳过强制微软账号）
- 进系统后**不要急着干别的**，先跑 Windows Update 直到 build = 19045.5856 或更新（让系统稳定）

### A.3 拷入并运行统一 EXE

把阶段 0 生成的 `deploy/guest-stealth/dist/respawn-stealth.exe` 通过现有数据盘、ISO、
共享目录或其它离线传输方式拷入 guest，推荐固定为 `D:\工具\respawn-stealth.exe`。
然后在**本地 SDL 控制台**的管理员 PowerShell 运行：

```powershell
powercfg -h off
Start-Process -FilePath 'D:\工具\respawn-stealth.exe' -Wait
```

EXE 会先判断真实 `Service`。克隆机已是 `VioGpuDod` 时跳过安装；全新机则校验
内嵌 SYS/CAT/INF 的摘要与微软签名，执行 `pnputil /install`，确认绑定成功后才做
GPU/显示器初始化。任何一步失败都会停止，不会把 BasicDisplay 只改一个 GTX 名字。

### A.4 等 EXE 自动重启

默认约 8 秒后自动重启，让 VioGpuDod、实时 EDID 和名称覆盖一起生效。调试时若用了
`-NoReboot`，检查日志后再手动执行 `shutdown /r /t 0`。

### A.5 验证真实驱动和分辨率

重启后在 SDL 控制台运行：

```powershell
Get-PnpDevice -Class Display -PresentOnly | ForEach-Object {
    $_
    Get-PnpDeviceProperty -InstanceId $_.InstanceId `
        -KeyName DEVPKEY_Device_Service,DEVPKEY_Device_DriverInfPath
}
Get-CimInstance Win32_VideoController |
    Format-List Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution
```

期望 PCI 显示设备 `Service=VioGpuDod`、INF 为 `oem*.inf`，显示设置可选
1920×1080。设备名称显示 NVIDIA 不是驱动成功的证据；真实判断必须看 Service。

### A.6 host 端跑 host-fix-gpu-devpkey.sh（修"驱动程序提供商"显示）

统一 EXE 跑完并重启后，guest 再关机一次（Win10 → 开始 → 关机），然后 **host 端**：

```bash
# 等 guest 真关机（看不见 QEMU 进程）
ps -ef | grep "win10-1" | grep -v grep

# 修 DEVPKEY；由 sudo 通过终端安全读取宿主密码，不要把密码写进命令或脚本
sudo /home/ubuntu/projects/qemu/deploy/scripts/host-fix-gpu-devpkey.sh 1
```

这一步把"驱动程序提供商"从 `Red Hat, Inc.` 改成 `NVIDIA`（设备管理器 → GPU → 属性 → 驱动程序）。

### A.7 装 DNF / wegame / 实际游戏环境

启动 VM1：

```bash
/home/ubuntu/projects/qemu/deploy/scripts/start-vm.sh 1
```

guest 内：
- 装 wegame
- 通过 wegame 装 DNF（或者下安装包手动装）
- 配置游戏账号、设置等（**这一步装的所有东西都会进 base，clone 出来的 VM 共享**）

### A.8 验证 stealth 生效

guest 内 PowerShell：

```powershell
# GPU 显示 NVIDIA
(Get-CimInstance Win32_VideoController | ? { $_.Name -ne 'Microsoft Basic Display Adapter' }).Name
# 应输出 profile 抽到的型号，如 "NVIDIA GeForce GTX 750 Ti"

# CPU
(Get-CimInstance Win32_Processor).Name
# 应输出 profile 抽到的型号，如 "AMD Ryzen 3 1200 Quad-Core Processor"

# 主板
(Get-CimInstance Win32_BaseBoard).Manufacturer
# 应输出 ASUS / MSI / Gigabyte / ASRock

# TPM
Get-Tpm | Select-Object TpmPresent, TpmReady
# 都应 True

# 仿真机红线（必须全 False / 否）
(Get-CimInstance Win32_BIOS).Manufacturer -eq 'American Megatrends Inc.'   # True
(Get-CimInstance Win32_Processor).HypervisorPresent                         # False
[Regex]::Match((Get-CimInstance Win32_ComputerSystem | Out-String), 'BOCHS|BXPC').Success  # False
```

任何一条不对，回到对应步骤排查。

---

## 阶段 B：密封 base

> 💡 封 base 前推荐把已核验哈希的
> `deploy/guest-stealth/dist/respawn-stealth.exe` 离线放到
> `D:\工具\respawn-stealth.exe`。clone 首次登录可直接运行统一 EXE，不需要 `iwr`、
> HTTP 服务或在 guest 安装下载工具。

### B.1 sysprep（强烈建议）

guest 内最后一次跑（**不可逆**，跑完进 OOBE）：

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

这会清掉：
- MachineGUID（VM 之间隔离的关键 ID）
- ComputerSID
- Windows 激活信息
- 网卡 MAC 配对历史
- 已安装驱动的实例 ID

跑完自动关机。

> **不 sysprep 也能 clone**，但多 VM 的 MachineGUID/SID 全相同，仿真机跨账号容易关联。生产 VM 建议 sysprep；只跑 1 个号自玩可以不做。

### B.2 host 端密封成只读 base

`seal-base.sh` 必须由实际 VM 普通用户执行，不要给它整体加 `sudo`：

```bash
/home/ubuntu/projects/qemu/deploy/scripts/seal-base.sh 1 win10-shallow-dnf-v1
```

如果源实例仍是受支持的旧启动盘 profile，显式允许只读内存迁移：

```bash
deploy/scripts/seal-base.sh 1 win10-shallow-dnf-v1 \
  --migrate-storage-profile
```

脚本会持有与 start/stop 相同的实例锁，严格校验 profile、启动盘容量和 qcow2，
把源盘压缩转换到同目录 staging，复核镜像完整性后以 no-replace 方式发布，并自动
把最终 base 设为 `root:root/0444`。不再需要手工 `chmod -w`。每次 clone 还会
在实例目录内建立 `.base.qcow2` hard-link pin；原 `_base` 目录项以后被移动或
删除时，既有实例仍引用原 inode。为保持零拷贝 thin clone，base 和实例目录必须
位于同一文件系统。

从其它主机、Windows、浏览器下载或移动硬盘导入 standalone qcow2 时，只需先把
文件复制到目标 Linux 的 `_base` 目录，再正常运行 `sudo clone-from-base.sh`。
脚本会在 qcow2 全检后自动把调用用户拥有的单链接文件密封成 `root:root/0444`；
复制方式造成的 owner/mode 差异不会再要求手工修复。

默认清理会修改源 `disk.qcow2` 中的应用缓存；需要保持源盘字节内容不变时必须显式
使用 `--no-clean`。无论哪种模式，convert 都不会移动或替换源盘。

### B.3 关于 VM1 本身

密封完，VM1 那份 disk.qcow2 还在原位置。你有 3 个选择：

| 选 | 操作 | 何时用 |
|---|---|---|
| **a** 保留 VM1 当生产号 | 不动 | 你只想跑 1 个号，base 留作以后建第 2 个号 |
| **b** 删 VM1，重新 clone 一个 instance=1 | `rm -rf /home/ubuntu/images/vms/1`<br>`sudo clone-from-base.sh win10-shallow-dnf-v1 1` | 想测 clone 流程；想让 VM1 也走"sysprep + 重新走 OOBE 拿独立 SID"路径 |
| **c** 删 VM1 不重建 | `rm -rf /home/ubuntu/images/vms/1` | 不需要 instance=1 时（用 instance=2/3/4） |

---

## 阶段 C：clone 出 VM2 / VM3 / ...

### C.1 一行 clone（**必须 sudo**）

```bash
sudo /home/ubuntu/projects/qemu/deploy/scripts/clone-from-base.sh win10-shallow-dnf-v1 2
```

> ⚠️ **一定要带 sudo**。脚本要离线挂载 Windows 系统盘；不带 sudo 会在任何
> 文件写入前立即失败。脚本只会把本事务创建或替换的目录项归还给原始用户，
> 不再递归改属已有实例目录。
>
> **重要原则**：在 sysprep 后、clone 尚未完成首次枚举的阶段，**不离线改
> boot-critical hive**（SYSTEM / SOFTWARE / DEFAULT）—— Win10 22H2
> incremental log 协议下，此时离线改 hive 即使 `.LOG1/.LOG2` 一起处理也可能
> 导致 `0xc0000001`。guest 启动后才要的注册表改动统一走
> `deploy/autounattend/autounattend.xml` 的 `<FirstLogonCommands>`；首次枚举并
> 完整关机后的 `finalize-clone-gpu.sh` 是专用、受控的离线收尾。
>
> **注意**：clone 阶段不会调用 `host-fix-gpu-devpkey.sh`，因此不会为了探测
> sysprep 已清空的 `Enum\PCI` 而重写 SYSTEM hive。新 clone 首次开机由 Windows
> 重新枚举设备，GPU 名由 FirstLogonCommands Order=10 的本地 respawn 重对齐；
> 进入桌面并完整关机后，再按 C.3 运行离线 finalizer。

自动做完：
1. 复用合法的 UI 预置 profile；否则重抽完整身份，并让实际 `BOOT_STORAGE_*`
   （NVMe 或 SATA/AHCI）容量逐字节等于 base。
2. 创建使用相对 backing 路径的 qcow2 增量层和全新 OVMF NVRAM；发布前后都会复核
   格式、容量、backing inode 和 patched QEMU 能力。
3. clone 阶段不离线写 SYSTEM；首启枚举后再运行 `finalize-clone-gpu.sh`。
4. **`host-inject-unattend.sh`** 把 `deploy/autounattend/autounattend.xml` 写到 guest 三处：
   - `%WINDIR%\Panther\Unattend\unattend.xml`（OOBE 主搜索路径）
   - `C:\unattend.xml`（备用）
   - `%WINDIR%\System32\Sysprep\unattend.xml`（备用）
5. per-instance 把 `<ComputerName>` 替换成 `DESKTOP-<7位随机[A-Z0-9]>`。
6. 精确归还本次 disk/profile/OVMF（以及新建目录）的所有权，再提交事务。

联网 OOBE 会自动检查并安装关键 ZDP，旧 base 首启可能出现数分钟的“Windows
将稳步更新”页面并按更新要求重启。这是 Windows 客体的预期更新阶段；若每个
clone 都重复等待，应在更新完成后重新执行 sysprep，并密封为新版 base。

### C.2 启动新 VM

```bash
/home/ubuntu/projects/qemu/deploy/scripts/start-vm.sh 2
```

**guest 内 0 手动操作** ——OOBE 自动跑完 unattend.xml：

1. **OOBE specialize 阶段**（首启）：处理 `<settings pass="specialize">`，应用 `ComputerName=DESKTOP-XXXXXXX`（host-inject 注入的随机名）+ 时区 + 输入法等，重启
2. **OOBE oobeSystem 阶段**（第二启）：通过 `HideEULAPage / HideOnlineAccountScreens / HideLocalAccountScreen / ...` 隐藏交互页面，并为隔离测试镜像启用内置 Administrator；不使用 Microsoft 明确不建议用于自动化 OOBE 的 `SkipMachineOOBE`。该默认口令不得复用于宿主或生产环境
3. **AutoLogon Administrator**：`<AutoLogon Enabled=true LogonCount=999>` 自动登录到桌面
4. **`<FirstLogonCommands>` Order 1→10 顺序跑**：
   - Order 1-3: Enable RDP + 防火墙放行 + 关 NLA
   - Order 4-5: 关 IE wizard / 关 Windows Update 自动重启
   - Order 6-9: 注册 ms-gamingoverlay no-op handler + 关 GameDVR
   - **Order 10: `D:\工具\respawn-stealth.exe --firstlogon`**
5. `respawn-stealth.exe` 先验证物理 `1AF4:1050`/stock VioGpuDod，再按 PCI subsys
   提交浅层逻辑 ID；事务发布 x86 SysWOW64 + x64 System32 NVAPI，使 GPU-Z 2.70
   可直接双击；随后自动重启。`--firstlogon` 保留 SYSTEM 名称刷新与 HardwareID
   投影任务，只跳过交互式显示模式任务；不安装第三方服务
6. 重启后桌面就绪，Device Manager 显示 profile.GPU_NAME（可能跟 base 的 VM1 不同）

整个过程从 `start-vm.sh` 到稳定桌面通常需要 **约 5-10 分钟**；旧 base
触发联网 ZDP 时会更久，全程不需要鼠标键盘。

#### C.2.1 兜底：FirstLogonCommands Order=10 没跑成功怎么办

少数情况首启那次 Order 10 没跑起来，表现 = guest 进桌面后 Device Manager GPU 名还是 base 里的老型号。补救方式：

**本地 EXE（不连 host）**：

```powershell
Start-Process -FilePath 'D:\工具\respawn-stealth.exe' -ArgumentList '--firstlogon' -Wait
```

诊断 FirstLogonCommands 是否真没跑：
```powershell
# 有 log → 跑成功；没 log → 没跑，或 D:\工具\respawn-stealth.exe 不存在
Test-Path C:\stealth\respawn.log
# 看 Order 1-10 日志
Get-WinEvent -LogName 'Microsoft-Windows-Shell-Core/Operational' -MaxEvents 20 | Where-Object Message -Match 'FirstLogon'
```

### C.3 首启后 GPU Provider 一键收尾

clone 首启后 Windows 会重新枚举显示设备，并按 stock `viogpudo.inf` 把设备管理器 →
GPU → 驱动程序 → 驱动程序提供商写回 `Red Hat, Inc.`。等 guest 第一次进桌面、
本地 respawn 完成 GPU 名重对齐并重启/关机后，在 host 跑：

```bash
deploy/scripts/finalize-clone-gpu.sh 2
```

普通用户直接跑即可；脚本会自动 `sudo` 重执行并显式传递白名单环境，因为底层需要
qemu-nbd + ntfs-3g 离线挂载 Windows 盘。若希望修完后自动启动：

```bash
STABLE_DISPLAY=1 HOST_RESERVE_CORES=0 \
  deploy/scripts/finalize-clone-gpu.sh 2 --restart -- --proxy
```

`STABLE_DISPLAY=1` 也是当前默认值；无论 base/clone 选择 AMD 还是 NVIDIA 逻辑
身份，此处都保持普通 `virtio-vga`，不增加 blob/hostmem PCI BAR。需要对照 GL 时可给
restart 透传 `--gpu-sdl-egl`，该路径默认仍为 gl-safe；只有再显式加
`--gpu-zerocopy` 才把 MSI-X 从 BAR4 移到 BAR1，并以 BAR4/5 启用 host-visible window；`GPU_HOSTMEM` 必须是 256M..8G 内
2 的幂。用户曾实测旧 GL+zero-copy 配置可稳定运行，因此该对照只能缩小变量，不能单独把
zero-copy 定性为 DNF 自动退出的根因。

### C.4 sysprep 与 OOBE

- 阶段 B.1 sysprep **已做**：clone 的 VM 第一次开机自动走 OOBE，
  **unattend.xml 配置并隐藏相应页面**，随后 AutoLogon 进桌面。每个 VM
  走完后有**独立 SID/MachineGUID**（stealth 友好）。
- 阶段 B.1 sysprep **没做**：clone 的 VM 直接登录到 base 的 Administrator，**多 VM 的 MachineGUID 相同**，stealth 弱一点。两种都通，但生产 VM 建议 sysprep。

### C.5 验证

跟阶段 A.8 一样的命令在 VM2 内跑一遍。未预置 profile 时，clone 会生成新的完整
profile；预置 profile 时则应与该 profile 的身份一致。

---

## 阶段 D：base 升级（DNF 大版本 / Win10 安全补丁）

**不要直接改 base**。base 一改，所有 clone 的增量层里残留的 NTFS 元数据指针会指错 → 蓝屏 / chkdsk 报错。

正确做法是滚版本：

```bash
# 1. 临时 instance=99 走老 base
sudo /home/ubuntu/projects/qemu/deploy/scripts/clone-from-base.sh win10-shallow-dnf-v1 99
/home/ubuntu/projects/qemu/deploy/scripts/start-vm.sh 99

# 2. guest 内更新 DNF / 装新软件 / 跑 Windows Update
# 3. sysprep + 关机
# 4. host 密封新 base
/home/ubuntu/projects/qemu/deploy/scripts/seal-base.sh 99 win10-shallow-dnf-v2

# 5. 清临时 VM
rm -rf /home/ubuntu/images/vms/99

# 6. 之后新 clone 用 v2
sudo /home/ubuntu/projects/qemu/deploy/scripts/clone-from-base.sh win10-shallow-dnf-v2 5
```

老 VM（v1 来的）继续跑没问题。想跟上 v2 让它们各自跑 wegame 自动更新即可。

---

## 客机离线统一安装与重对齐（`deploy/guest-stealth/`）

阶段 C 的 GPU 重对齐（首启 `FirstLogonCommands` Order=10 / C.2.1 兜底）只走
`D:\工具\respawn-stealth.exe --firstlogon`。`FirstLogonCommands` 是 OOBE 后首次登录
执行一次，不是每次开机执行；`--firstlogon` 保留 `StealthGPU-RefreshName` 与
`StealthGPU-ProjectHardwareId`，只跳过交互式显示模式任务。迁移到其它主机时不要求对方有相同 host IP
或 HTTP 服务。

### 文件

| 文件 | 作用 |
|---|---|
| `dist/respawn-stealth.exe` | **唯一发布入口**：内嵌驱动三件套、安装器与初始化脚本 |
| `install-display-driver.ps1` | 用真实 Service 做幂等判断；全新机安装，克隆机跳过 |
| `respawn-stealth-local.ps1` | 串联驱动、`apply-gpu-spoof -AutoDetect`、清 RunOnce 与重启 |
| `README.md` | 该目录自带的简要说明 |
| `package.sh` | host 上打一个默认只含 `respawn-stealth.exe` 的 `dist/`（已 gitignore）|

行为：先核验/绑定 `VioGpuDod` → 仅新装系统清模式缓存 → 按 PCI SUBSYS 查 GPU 池
→ 改 `Class\{4d36e968}` + `Enum\PCI` + `Enum\DISPLAY` → 重启。所有依赖释放到
`C:\ProgramData\StealthGPU\respawn-exe\`，不依赖网络。

### 打包进 base（必需，封 base 前做一次）

host 上先生成单文件 EXE：

```bash
bash deploy/guest-stealth/package.sh
```

封 base 前（阶段 A 末、B.1 sysprep 之前），只把
`deploy/guest-stealth/dist/respawn-stealth.exe` 拷进 guest，固定放到
`D:\工具\respawn-stealth.exe`。
EXE 自带 stock `viogpudo.sys/.cat/.inf`、安装器、respawn 和 apply 脚本，运行时
释放到 `C:\ProgramData\StealthGPU\respawn-exe\`，不依赖旁边任何文件。

拷完照常 sysprep + `seal-base.sh` 封 base，之后每个 clone 首次登录都会执行这份 EXE 一次。

### 客机内怎么用

资源管理器进 `D:\工具\`，双击 `respawn-stealth.exe` → UAC 点"是" → 跑完自动重启。
OOBE 后自动执行时用 `--firstlogon` 跳过确认框。

### 什么时候用它

- **全新 VM 初始化**：没有 VioGpuDod 时自动安装签名驱动，再完成名称和模式初始化。
- **C.2.1 的离线兜底**：clone 进桌面后 GPU 名还是 base 老型号 → 执行 `D:\工具\respawn-stealth.exe --firstlogon`。
- **随时重抽身份后重跑**：任何时候想按当前 PCI subsys 重新对齐 GPU 注册表覆盖，客机内双击一下就行（可反复跑，幂等）。
- **断网环境**：客机不通 host / 不通网时唯一可用的重对齐手段。

---

## 总览：每阶段用到的脚本

| 阶段 | 在哪跑 | 命令 | 干啥 |
|---|---|---|---|
| 0 | host | `bash deploy/guest-stealth/package.sh` | 构建内嵌驱动与脚本的统一离线 EXE |
| A.1 | host | `deploy/scripts/start-vm.sh 1 --iso=...` | 启动装机 |
| A.3 | guest | `D:\工具\respawn-stealth.exe` | 离线安装 VioGpuDod + GPU/显示器初始化 + 重启 |
| A.5 | guest | 查询 `DEVPKEY_Device_Service` | 验证真实 Service，而不是只看 GTX 名称 |
| A.6 | host | `sudo .../host-fix-gpu-devpkey.sh 1` | 改 DEVPKEY 让"驱动程序提供商"显示 NVIDIA |
| A.7 | guest | 手动装 wegame / DNF / 实际游戏环境 | — |
| A 末 | guest | 最新 EXE 保留在 `D:\工具\` | 必需：clone FirstLogon 固定从这里执行 |
| B.1 | guest | `sysprep /generalize /oobe /shutdown` | 清 SID/MachineGUID 让 clone 独立 |
| B.2 | host | `deploy/scripts/seal-base.sh 1 <name>` | 密封 base |
| C.1 | host | `sudo .../clone-from-base.sh <name> 2` | clone qcow2 增量 + 复用/生成 profile + 注 unattend.xml |
| C.2 | host | `.../start-vm.sh 2` | 启动新 VM；**guest 内 0 手动操作**；Order 10 优先执行 `D:\工具\respawn-stealth.exe --firstlogon` |
| C.3 | host | `.../finalize-clone-gpu.sh 2` | 首启后修正 DriverProvider |
| C 兜底 | guest | `D:\工具\respawn-stealth.exe --firstlogon` | **离线**本地重对齐 GPU（=不连 host 的 respawn-stealth）|
| D | host + guest | 滚版本（见上） | 升级 base |

## 不会再跑的脚本（不用问、不用纠结）

| 脚本 | 何时**不**用跑 |
|---|---|
| `apply-gpu-spoof.ps1` | 永远不直接跑——它由 respawn-stealth 自动调用 |
| `shallow-stealth.ps1` / `respawn-stealth.ps1` | 已退役；只返回无副作用迁移诊断，不能执行安装 |
| `vm-bootstrap.ps1` | 历史 OpenSSH + autologin 初始化入口，默认流程不用 |
| `install-stealth.sh` / `install-stealth-guest.ps1` | 历史深层自签流程；当前浅层模式禁止运行 |
| `destealth-revert.ps1` | 已退役且只会 fail-fast；历史版本会误删当前浅层模式依赖的 stock VioGpuDod，禁止在健康客机运行 |
| `diag-gpu-props.ps1` | 排查 GPU 改名失败时用 |
| `fix-ms-gamingoverlay.ps1` | autounattend.xml 已经把这套逻辑内置了，不用单跑 |
| **`host-inject-runonce.sh`** | **已 deprecated** —— 离线写 SOFTWARE hive 会让 Win10 22H2 启动 `0xc0000001`。等价命令搬进 autounattend FirstLogonCommands Order=10 |

## 常见踩坑

| 症状 | 原因 | 修法 |
|---|---|---|
| `irm apply-gpu-spoof.ps1 \| iex` 报"赋值表达式无效" | 该脚本有 `param()`，`iex` 不支持参数化 | 不要直接跑；重新构建并运行统一 EXE |
| host offline 改 hive 时报 "Windows is hibernated" | Fast Startup 没关 | guest 内 `powercfg -h off` + `shutdown /s /t 0`，**别**用 GUI "关机"或 `shutdown /r` |
| clone 完启动报 `Recovery 0xc0000001 / Your PC couldn't start properly` | sysprep 后、首次枚举前离线改了 boot-critical hive（SYSTEM/SOFTWARE/DEFAULT） | 重新 clone；首启前不要离线改这些 hive，guest 启动后要做的注册表改动写进 `autounattend.xml` 的 `<FirstLogonCommands>` |
| 设备管理器驱动程序提供商还是 `Red Hat, Inc.` | clone 阶段不预写 Provider；Windows 首次枚举按 `viogpudo.inf` 建立原始字段 | guest 完整关机，host 端运行 `deploy/scripts/finalize-clone-gpu.sh <N>`；这是首次枚举后的受控离线收尾，脚本会自动 sudo 提权 |
| 首启前 `ControlSet001\Enum\PCI` 不存在 | sysprep base 的预期状态（generalize 把 PCI enum 清了） | 不要在 clone 阶段运行 `host-fix-gpu-devpkey.sh`；首次登录后由 FirstLogonCommand Order=10 重对齐 GPU，再完整关机运行 finalizer |
| clone VM 进桌面后 GPU 名还是 base 老型号 | 首次登录那次 FirstLogonCommand Order=10 没自动跑，或 `D:\工具\respawn-stealth.exe` 不存在 | guest 管理员 PS：`Start-Process -FilePath 'D:\工具\respawn-stealth.exe' -ArgumentList '--firstlogon' -Wait` |
| 新 VM 显示 GTX 但分辨率锁在 1280×800、下拉灰色 | 运行的是旧 EXE，只把 Microsoft Basic Display Adapter 改了名 | 替换最新 EXE，在 SDL 控制台运行；确认 Service=`VioGpuDod` 后重启 |
| `display-driver-install.log` 报摘要/签名错误 | SYS/CAT/INF 混版或 EXE payload 损坏 | host 重新运行 `package.sh`，不要手工替换释放目录里的驱动 |
| RDP 中分辨率下拉灰色 | 远程会话分辨率由 RDP 客户端控制 | 退出 RDP，在本地 SDL 控制台验证 VioGpuDod 和 1920×1080 |
| guest 卡 "区域设置 / 让我们设置你的设备" 等 OOBE 画面 | unattend.xml 没写进 disk（host-inject-unattend.sh 跑失败 / autounattend.xml 缺组件）| host 端 `sudo deploy/scripts/host-inject-unattend.sh <N>` 离线补一份，再重启 guest |
| `Get-Tpm` 全 False | OVMF 没编 TPM2_ENABLE，或 swtpm permall 太小 | host 跑 `deploy/tools/build-ovmf.sh` + `sudo chown -R ubuntu /var/lib/swtpm-localca` |
| guest 数字键仍是 Home/方向键 | 使用旧 QEMU、传了 `--no-numlock`，或 Windows 尚未回报 HID LED | 用当前 `build/qemu-system-x86_64` 启动；QMP 查询 `kbd0` 的 `x-numlock-led-known/on` |

## 下一步

按 0 → A → B → C 顺序做。每步**确认上一步生效**再进下一步。

任何一步卡了在 issue 里贴：
- 当前阶段
- 跑的命令
- 完整输出（截图或文本）




$ErrorActionPreference = 'Stop'
  $dir = "$env:WINDIR\System32\Sysprep\Panther"
  $logs = @("$dir\setupact.log", "$dir\setuperr.log") |
      Where-Object { Test-Path $_ }

  $bad = Select-String -LiteralPath $logs `
      -Pattern 'SYSPRP Package\s+(.+?)\s+was installed for a user' |
      ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
      Sort-Object -Unique

  $bad

  if (-not $bad) {
      Get-Content "$dir\setuperr.log" -Tail 60
      throw '不是 AppX 包冲突，请保留上面的日志输出'
  }

  foreach ($fullName in $bad) {
      $displayName = ($fullName -split '_', 2)[0]

      Get-AppxPackage -AllUsers |
          Where-Object PackageFullName -eq $fullName |
          ForEach-Object {
              Remove-AppxPackage -Package $_.PackageFullName -AllUsers
          }

      Get-AppxProvisionedPackage -Online |
          Where-Object DisplayName -eq $displayName |
          ForEach-Object {
              Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName
          }
  }

  & "$env:WINDIR\System32\Sysprep\Sysprep.exe" /generalize /oobe /shutdown
