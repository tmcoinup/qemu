# VM 装机 + 克隆完整操作手册

按顺序跟着做，每一步用了什么脚本说清楚。**前提**：host 已经 setup-bridge 过、QEMU 已编、stealth OVMF 已 build 过（这些是一次性工作，正常无需重做）。

---

## 阶段 0：host 端启动一次性 HTTP 服务

guest 内通过 HTTP 拉 ps1 / 驱动文件。**`clone-from-base.sh` 已经会自动检测 8765 没监听就启一个，正常情况不需要手动起**。仅当装机阶段（A）需要 guest 拉 vm-prep.ps1 / shallow-stealth.ps1 时手动跑一次：

```bash
# 先看是否已经在跑（避免重复起 / 端口冲突）
ss -tlnp | grep 8765 || nohup python3 /home/ubuntu/projects/qemu/deploy/scripts/serve-stealth-http.py 8765 \
    &> /tmp/serve-http.log &
# 验证
curl -sI http://192.168.30.33:8765/vm-prep.ps1            # HTTP 200
curl -sI http://192.168.30.33:8765/respawn-stealth.ps1    # HTTP 200（clone 流程必需）
```

服务监听 `192.168.30.33:8765`（host 在 br0 上的 IP）。clone 流程会自动起，但**装机阶段 A 仍需手动起**（那时还没跑 clone-from-base.sh）。如果 guest 端跑 `irm` 报 404，**99% 是这里漏起了** 或 **URL 打错**（典型 typo：`respawn-stealth..ps1` 两个点）。

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

启动日志会显示 `=== stealth profile ===`，记下里面的 GPU 型号（比如 `NVIDIA GeForce GTX 750 Ti`）—— **不用记**，shallow-stealth.ps1 后面自动按 PCI subsys 查表。

### A.2 装机选项

- 选 **Windows 10 专业版**（install.wim index=4）
- OOBE 阶段：选"中国 / 简体中文 / 微软拼音"，账号选**离线账号**（Shift+F10 → `oobe\BypassNRO` 跳过强制微软账号）
- 进系统后**不要急着干别的**，先跑 Windows Update 直到 build = 19045.5856 或更新（让系统稳定）

### A.3 跑 vm-prep.ps1（系统级 setup）

进 guest 后**右键开始 → Windows PowerShell (管理员)**，跑：

```powershell
irm http://192.168.30.33:8765/vm-prep.ps1 | iex
```

这一步做的事：
- 关 Fast Startup + 删 hiberfil.sys
- NumLock 永久 ON
- 关 Defender 实时扫 + 切 small minidump
- 永不息屏 / 不睡眠
- 抑制 ms-gamingoverlay 弹窗（DNF 启动友好）
- **不装 OpenSSH**（你不需要）
- **不改 Administrator 密码**（你不需要）

### A.4 重启一次（让 Fast Startup 关、NumLock 设置完整落地）

```powershell
shutdown /r /t 0
```

### A.5 跑 shallow-stealth.ps1（GPU spoof）

重启进系统后，再次开管理员 PowerShell：

```powershell
irm http://192.168.30.33:8765/shallow-stealth.ps1 | iex
```

它会自动：
1. 下载 stock virtio-win viogpudo（MS-WHQL 签）
2. `pnputil` 安装
3. 探测当前 PCI subsys → 查 GPU 池映射表 → 选对应型号
4. 下载 apply-gpu-spoof.ps1 → 改注册表 → 替换 nvapi64.dll
5. 提示回车自动重启

回车，重启。

### A.6 host 端跑 host-fix-gpu-devpkey.sh（修"驱动程序提供商"显示）

shallow-stealth 跑完重启后，guest 关机一次（Win10 → 开始 → 关机），然后 **host 端**：

```bash
# 等 guest 真关机（看不见 QEMU 进程）
ps -ef | grep "win10-1" | grep -v grep

# 修 DEVPKEY
echo 123456 | sudo -S /home/ubuntu/projects/qemu/deploy/scripts/host-fix-gpu-devpkey.sh 1
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

# 反作弊红线（必须全 False / 否）
(Get-CimInstance Win32_BIOS).Manufacturer -eq 'American Megatrends Inc.'   # True
(Get-CimInstance Win32_Processor).HypervisorPresent                         # False
[Regex]::Match((Get-CimInstance Win32_ComputerSystem | Out-String), 'BOCHS|BXPC').Success  # False
```

任何一条不对，回到对应步骤排查。

---

## 阶段 B：密封 base

> 💡 封 base 前可选（**推荐**）：把**离线一键重对齐脚本**打包进 base，让每个 clone 自带、host 连不上也能本地重对齐 GPU。两条 `iwr` 命令搞定，见文末「客机本地一键重对齐 GPU」。

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

> **不 sysprep 也能 clone**，但多 VM 的 MachineGUID/SID 全相同，反作弊跨账号容易关联。生产 VM 建议 sysprep；只跑 1 个号自玩可以不做。

### B.2 host 端密封成只读 base

```bash
/home/ubuntu/projects/qemu/deploy/scripts/seal-base.sh 1 win10-shallow-dnf-v1
```

`seal-base.sh` 会把 `vms/1/disk.qcow2` 复制（不是移动）到 `_base/win10-shallow-dnf-v1.qcow2`。

### B.3 物理锁 base（防意外写）

```bash
chmod -w /home/ubuntu/images/vms/_base/win10-shallow-dnf-v1.qcow2
ls -la /home/ubuntu/images/vms/_base/
```

### B.4 关于 VM1 本身

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

> ⚠️ **一定要带 sudo**。脚本要挂 NTFS 写 unattend.xml + 改 per-user NTUSER NumLock 状态，没 root 会跳过部分步骤；并且 clone 完目录权限会变 `root:root` 让普通用户的 `start-vm.sh` 写不了 OVMF NVRAM（脚本最后会 `chown` 回去）。
>
> **重要原则**：除 per-user `NTUSER.DAT` 外，**绝不离线改 boot-critical hive**（SYSTEM / SOFTWARE / DEFAULT）—— Win10 22H2 incremental log 协议下，离线改 hive 即使 `.LOG1/.LOG2` 一起处理，启动也几乎必然 `0xc0000001`。所以所有 guest 启动后才要的注册表改动统一走 `deploy/autounattend/autounattend.xml` 的 `<FirstLogonCommands>`。
>
> **注意**：clone 阶段调 `host-fix-gpu-devpkey.sh` 会打印 `ControlSet001\Enum\PCI 不存在 — sysprep base 未首启的预期状态 / 跳过离线 DEVPKEY 覆盖`。这是**正确**行为：sysprep generalize 清掉了 PCI enum，新 clone 必须开机一次让 Windows 重新枚举才会有这些键。GPU 名最终由 guest 首次登录后 FirstLogonCommands Order=10 跑 `respawn-stealth.ps1` 重对齐。

自动做完：
1. 起 HTTP server (8765) 如果还没跑
2. 创建 qcow2 增量层 `vms/2/disk.qcow2` backed by base
3. `stealth_pick_profile` reroll 硬件身份（新 CPU / 主板 / GPU / MAC / UUID / NVMe SN），NVMe 容量强制等于 base 容量避免 NTFS 错位
4. `host-fix-gpu-devpkey.sh` 在 sysprep base 上自动 skip（无 PCI enum）；首启枚举后再跑 `finalize-clone-gpu.sh`
5. `host-fix-numlock.sh` 改 per-user `NTUSER.DAT` 的 `InitialKeyboardIndicators=0x80000002`
6. **`host-inject-unattend.sh`** 把 `deploy/autounattend/autounattend.xml` 写到 guest 三处：
   - `%WINDIR%\Panther\Unattend\unattend.xml`（OOBE 主搜索路径）
   - `C:\unattend.xml`（备用）

### C.2 首启后 GPU Provider 一键收尾

clone 首启后 Windows 会重新枚举显示设备，并按 stock `viogpudo.inf` 把设备管理器 → GPU → 驱动程序 → 驱动程序提供商写回 `Red Hat, Inc.`。等 guest 第一次进桌面、`respawn-stealth.ps1` 完成 GPU 名重对齐并重启/关机后，在 host 跑：

```bash
deploy/scripts/finalize-clone-gpu.sh 2
```

普通用户直接跑即可；脚本会自动 `sudo -E` 提权，因为底层需要 qemu-nbd + ntfs-3g 离线挂载 Windows 盘。若希望修完后自动启动：

```bash
STABLE_DISPLAY=0 HOST_RESERVE_CORES=0 deploy/scripts/finalize-clone-gpu.sh 2 --restart -- --proxy
```
   - `%WINDIR%\System32\Sysprep\unattend.xml`（备用）
   - per-instance 把 `<ComputerName>` 替换成 `DESKTOP-<7位随机[A-Z0-9]>`（仿全新消费级
     Win10 默认主机名）。**不用 `*`** —— `*` 会让 OOBE 拿 `RegisteredOwner`(Administrator)
     当前缀生成 `ADMINIS-XXXXXXX`，暴露 sysprep 模板身份。随机后缀天然唯一，多机不撞名
7. chown vms/<N>/ 回原用户

### C.2 启动新 VM

```bash
/home/ubuntu/projects/qemu/deploy/scripts/start-vm.sh 2
```

**guest 内 0 手动操作** ——OOBE 自动跑完 unattend.xml：

1. **OOBE specialize 阶段**（首启）：处理 `<settings pass="specialize">`，应用 `ComputerName=DESKTOP-XXXXXXX`（host-inject 注入的随机名）+ 时区 + 输入法等，重启
2. **OOBE oobeSystem 阶段**（第二启）：自动跳 `SkipMachineOOBE / SkipUserOOBE / HideEULAPage / HideLocalAccountScreen / ...` 全套画面，建/激活 Administrator/123456 账号
3. **AutoLogon Administrator**：`<AutoLogon Enabled=true LogonCount=999>` 自动登录到桌面
4. **`<FirstLogonCommands>` Order 1→10 顺序跑**：
   - Order 1-3: Enable RDP + 防火墙放行 + 关 NLA
   - Order 4-5: 关 IE wizard / 关 Windows Update 自动重启
   - Order 6-9: 注册 ms-gamingoverlay no-op handler + 关 GameDVR
   - **Order 10: `irm http://192.168.30.33:8765/respawn-stealth.ps1 | iex`**
5. `respawn-stealth.ps1` 拉 `apply-gpu-spoof.ps1 -AutoDetect`（按 PCI subsys 查表）→ 改注册表 + 替换 nvapi64.dll → 5 秒后自动重启
6. 重启后桌面就绪，Device Manager 显示 profile.GPU_NAME（可能跟 base 的 VM1 不同）

整个过程从 `start-vm.sh` 到稳定桌面 **~5-8 分钟**，全程不需要鼠标键盘。

#### C.2.1 兜底：FirstLogonCommands Order=10 没拉到 respawn-stealth.ps1 怎么办

少数情况首启那次 Order 10 网络抖了 / HTTP server 没起，表现 = guest 进桌面后 Device Manager GPU 名还是 base 里的老型号。两种补救，任选其一：

**① 离线一键（推荐，host 连不上也能用）** —— 前提是 base 已按文末「客机本地一键重对齐 GPU」打包过。客机内进 `C:\stealth\` **双击 `respawn-stealth.bat`** 即可（全程不连 host），跑完自动重启。

**② HTTP irm（host server 在线时）** —— guest 内开**管理员 PowerShell** 手敲一次（URL **只一个点** —— `respawn-stealth.ps1` 不是 `respawn-stealth..ps1`）：

```powershell
irm http://192.168.30.33:8765/respawn-stealth.ps1 | iex
```

效果跟 FirstLogonCommand 自动触发完全一致（下载 apply-gpu-spoof.ps1 + `-AutoDetect` + 改注册表 + 5 秒后自动重启）。

诊断 FirstLogonCommands 是否真没跑：
```powershell
# 有 log → 跑成功；没 log → 没跑（或网络拉取失败）
Test-Path C:\stealth\respawn.log
# 看 Order 1-10 日志
Get-WinEvent -LogName 'Microsoft-Windows-Shell-Core/Operational' -MaxEvents 20 | Where-Object Message -Match 'FirstLogon'
```

### C.3 sysprep 与 OOBE

- 阶段 B.1 sysprep **已做**：clone 的 VM 第一次开机自动走 OOBE，**unattend.xml 自动跳过所有画面**直接 AutoLogon 进桌面。每个 VM 走完后有**独立 SID/MachineGUID**（stealth 友好）。
- 阶段 B.1 sysprep **没做**：clone 的 VM 直接登录到 base 的 Administrator，**多 VM 的 MachineGUID 相同**，stealth 弱一点。两种都通，但生产 VM 建议 sysprep。

### C.4 验证

跟阶段 A.8 一样的命令在 VM2 内跑一遍。GPU 应该是**不同于 VM1 的型号**（因为 profile reroll 了）。

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
chmod -w /home/ubuntu/images/vms/_base/win10-shallow-dnf-v2.qcow2

# 5. 清临时 VM
rm -rf /home/ubuntu/images/vms/99

# 6. 之后新 clone 用 v2
sudo /home/ubuntu/projects/qemu/deploy/scripts/clone-from-base.sh win10-shallow-dnf-v2 5
```

老 VM（v1 来的）继续跑没问题。想跟上 v2 让它们各自跑 wegame 自动更新即可。

---

## 客机本地一键重对齐 GPU（`deploy/guest-stealth/`，离线、无需 host HTTP）

阶段 C 的 GPU 重对齐（首启 `FirstLogonCommands` Order=10 / C.2.1 兜底）都要从 host `8765` 拉 `respawn-stealth.ps1`，**host 关机 / 网络抖 / server 漏起就拉不到**。`deploy/guest-stealth/` 是它的**纯本地等价物**：预先打包进 base，客机内**双击即跑**，全程不连 host。

### 文件

| 文件 | 作用 |
|---|---|
| `respawn-stealth.bat` | **一键入口**：双击 → 自动 UAC 提权 → 跑下面的 `.ps1` |
| `respawn-stealth-local.ps1` | 本地主逻辑：磁盘上定位 `apply-gpu-spoof.ps1` → `-AutoDetect` → 清 RunOnce → 重启 |
| `README.md` | 该目录自带的简要说明 |
| `package.sh` | host 上打一个**自带依赖**的 `dist/`（连 `apply-gpu-spoof.ps1` 一起拷进去；已 gitignore）|

行为跟 HTTP 版 `respawn-stealth.ps1` 完全一致：按当前显卡 PCI SUBSYS 自动查 GPU 池表选型号 → 改 `Class\{4d36e968}` + `Enum\PCI` + `Enum\DISPLAY` 注册表覆盖 → 装开机自刷计划任务 → 完成后重启。**唯一区别是"脚本从哪来"**：

| | HTTP 版 `respawn-stealth.ps1` | 本地版 `deploy/guest-stealth/` |
|---|---|---|
| `apply-gpu-spoof.ps1` 来源 | host `irm http://…:8765/…` | 本机磁盘（同目录 → `C:\stealth\` → `C:\ProgramData\StealthGPU`）|
| 依赖 host server | 是 | **否** |
| 触发 | clone 首启 FirstLogonCommands Order=10 | 客机内双击 `.bat` / 手动 |
| 额外 | — | UAC 自提权 + 管理员自检 + 退出码判断（失败不盲目重启）+ `-NoReboot` |

### 打包进 base（封 base 前做一次）

`respawn-stealth-local.ps1` 默认找 `C:\stealth\apply-gpu-spoof.ps1`，而阶段 A.5 的 `shallow-stealth.ps1` 已经把它落在那儿了，所以**只需把两个入口文件拷进客机**。封 base 前（阶段 A 末、B.1 sysprep 之前，此时 host HTTP server 还开着），客机内开管理员 PowerShell：

```powershell
# 这两个文件已 symlink 进 HTTP 根（同 nvapi64.dll 套路），iwr 直接拉、字节级保真（保留 .ps1 的 BOM）
iwr http://192.168.30.33:8765/respawn-stealth.bat       -OutFile C:\stealth\respawn-stealth.bat
iwr http://192.168.30.33:8765/respawn-stealth-local.ps1 -OutFile C:\stealth\respawn-stealth-local.ps1
```

> 想做成"放哪都能跑、不依赖 `C:\stealth`"的独立文件夹：host 上先 `bash deploy/guest-stealth/package.sh`，把生成的 `dist/`（含 `apply-gpu-spoof.ps1`）整个拷进客机即可（`respawn-stealth-local.ps1` 会优先用同目录那份）。

拷完照常 sysprep + `seal-base.sh` 封 base，之后**每个 clone 都自带这份一键脚本**，无需再单独处理。

### 客机内怎么用

资源管理器进 `C:\stealth\`，**双击 `respawn-stealth.bat`** → UAC 点"是" → 跑完自动重启。等价手动命令（管理员 PowerShell）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\stealth\respawn-stealth-local.ps1
# 不想跑完自动重启（先看输出）：
powershell -NoProfile -ExecutionPolicy Bypass -File C:\stealth\respawn-stealth-local.ps1 -NoReboot
```

### 什么时候用它

- **C.2.1 的离线兜底**：clone 进桌面后 GPU 名还是 base 老型号、且 host server 连不上 → 双击 `.bat` 即可（不用 `irm`）。
- **随时重抽身份后重跑**：任何时候想按当前 PCI subsys 重新对齐 GPU 注册表覆盖，客机内双击一下就行（可反复跑，幂等）。
- **断网环境**：客机不通 host / 不通网时唯一可用的重对齐手段。

---

## 总览：每阶段用到的脚本

| 阶段 | 在哪跑 | 命令 | 干啥 |
|---|---|---|---|
| 0 | host | `nohup python3 deploy/scripts/serve-stealth-http.py 8765 &` | 起 HTTP 服务（装机阶段需要；clone 阶段 clone-from-base.sh 会自动起，无需手跑）|
| A.1 | host | `deploy/scripts/start-vm.sh 1 --iso=...` | 启动装机 |
| A.3 | guest | `irm .../vm-prep.ps1 \| iex` | 系统级 setup（NumLock / Fast Startup / Defender / minidump）|
| A.5 | guest | `irm .../shallow-stealth.ps1 \| iex` | GPU spoof（viogpudo 装 + 注册表改名 + nvapi shim）|
| A.6 | host | `sudo .../host-fix-gpu-devpkey.sh 1` | 改 DEVPKEY 让"驱动程序提供商"显示 NVIDIA |
| A.7 | guest | 手动装 wegame / DNF / 实际游戏环境 | — |
| A 末 | guest | `iwr .../respawn-stealth.bat` + `.../respawn-stealth-local.ps1 -OutFile C:\stealth\` | （可选/推荐）把离线一键脚本打包进 base，clone 自带 |
| B.1 | guest | `sysprep /generalize /oobe /shutdown` | 清 SID/MachineGUID 让 clone 独立 |
| B.2 | host | `deploy/scripts/seal-base.sh 1 <name>` | 密封 base |
| B.3 | host | `chmod -w _base/<name>.qcow2` | 物理锁 base |
| C.1 | host | `sudo .../clone-from-base.sh <name> 2` | clone qcow2 增量 + reroll profile + 注 unattend.xml（OOBE 自动跳 + AutoLogon + FirstLogonCommands Order 10 拉 respawn-stealth.ps1）|
| C.2 | host | `.../start-vm.sh 2` | 启动新 VM；**guest 内 0 手动操作**；如果 Order 10 网络抖手敲 `irm .../respawn-stealth.ps1 \| iex` 兜底 |
| C 兜底 | guest | 双击 `C:\stealth\respawn-stealth.bat` | **离线**本地重对齐 GPU（=不连 host 的 respawn-stealth）|
| D | host + guest | 滚版本（见上） | 升级 base |

## 不会再跑的脚本（不用问、不用纠结）

| 脚本 | 何时**不**用跑 |
|---|---|
| `apply-gpu-spoof.ps1` | 永远不直接跑——它被 shallow-stealth / respawn-stealth 自动调 |
| `vm-bootstrap.ps1` | 我们改用 vm-prep.ps1 了；vm-bootstrap 那套 OpenSSH + autologin 你不需要 |
| `install-stealth-guest.ps1` | 深层方案 A 用，浅层（我们走的）用不上 |
| `destealth-revert.ps1` | 想撤 stealth 时跑（一般不需要） |
| `diag-gpu-props.ps1` | 排查 GPU 改名失败时用 |
| `fix-ms-gamingoverlay.ps1` | autounattend.xml 已经把这套逻辑内置了，不用单跑 |
| **`host-inject-runonce.sh`** | **已 deprecated** —— 离线写 SOFTWARE hive 会让 Win10 22H2 启动 `0xc0000001`。等价命令搬进 autounattend FirstLogonCommands Order=10 |

## 常见踩坑

| 症状 | 原因 | 修法 |
|---|---|---|
| `irm apply-gpu-spoof.ps1 \| iex` 报"赋值表达式无效" | 该脚本有 `param()`，`iex` 不支持参数化 | 不要直接跑——它会被 shallow-stealth / respawn-stealth 自动调 |
| host offline 改 hive 时报 "Windows is hibernated" | Fast Startup 没关 | guest 内 `powercfg -h off` + `shutdown /s /t 0`，**别**用 GUI "关机"或 `shutdown /r` |
| clone 完启动报 `Recovery 0xc0000001 / Your PC couldn't start properly` | 离线改了 boot-critical hive（SYSTEM/SOFTWARE/DEFAULT）—— Win10 22H2 incremental log 协议下，无论 LOG 保留 / truncate / restore 都崩 | 唯一解：boot-critical hive 一概不离线动；guest 启动后要的注册表改动写进 `autounattend.xml` 的 `<FirstLogonCommands>` |
| 设备管理器驱动程序提供商还是 `Red Hat, Inc.` | clone 首启后 Windows 按 `viogpudo.inf` 重新写回 Provider，覆盖了 clone 阶段预写 | guest 关机，host 端 `deploy/scripts/finalize-clone-gpu.sh <N>`；脚本会自动 sudo 提权 |
| clone 完 host 端报 `ControlSet001\Enum\PCI 不存在` | sysprep base 的预期状态（generalize 把 PCI enum 清了） | 不是 bug —— 脚本自动 skip；guest 首次登录后 FirstLogonCommand Order=10 会重对齐 GPU |
| clone VM 进桌面后 GPU 名还是 base 老型号 | 首次登录那次 FirstLogonCommand Order=10 没自动跑或拉取失败 | **离线**（base 已打包时）：双击 `C:\stealth\respawn-stealth.bat`；**或** guest 管理员 PS：`irm http://192.168.30.33:8765/respawn-stealth.ps1 \| iex`（**URL 一个点**） |
| `irm` 报 404 或 connection refused | URL typo（常见：`respawn-stealth..ps1` 两个点）/ HTTP server 没起 | 检查 URL 单点；host `ss -tlnp \| grep 8765` 看 server 在不（clone-from-base.sh 已会自动起，但若 clone 前手动 start-vm 启了新机的话需要补 `nohup python3 deploy/scripts/serve-stealth-http.py 8765 &`）；**或干脆走离线一键** `respawn-stealth.bat`（不连 host）|
| guest 卡 "区域设置 / 让我们设置你的设备" 等 OOBE 画面 | unattend.xml 没写进 disk（host-inject-unattend.sh 跑失败 / autounattend.xml 缺组件）| host 端 `sudo deploy/scripts/host-inject-unattend.sh <N>` 离线补一份，再重启 guest |
| `Get-Tpm` 全 False | OVMF 没编 TPM2_ENABLE，或 swtpm permall 太小 | host 跑 `deploy/tools/build-ovmf.sh` + `sudo chown -R ubuntu /var/lib/swtpm-localca` |
| 小键盘灯不亮、数字键失灵 | NumLock 默认 OFF | guest 内跑 vm-prep.ps1 / 或 host 端跑 `host-fix-numlock.sh <N>`（VM 关机） |

## 下一步

按 0 → A → B → C 顺序做。每步**确认上一步生效**再进下一步。

任何一步卡了在 issue 里贴：
- 当前阶段
- 跑的命令
- 完整输出（截图或文本）
