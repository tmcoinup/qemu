# vGPU 一键收尾与恢复：傻瓜版

> **先停：** GTX1050 专用 ZIP 使用自签 driver catalog，现已禁用并从 current
> staging 归档。本文不再提供 GTX1050 ZIP/切 strict-A 的执行步骤。GTX1050 的
> 受支持状态是 B；VM3 的 legacy A 已按
> `VGPU-PRODUCTION-MIGRATION.md` 完成迁移并验收。
> `finish-vgpu-install.sh` 会在产生 guest 包或 marker 前拒绝。其他 B profile 的
> token/RTC 恢复边界不变。

日常只记住两条规则：

1. GTX 1050 的新/合规实例保持 B；VM3 已是 B/native FINAL PASS，不再运行任何
   历史 strict-A ZIP、driver stager 或旧迁移 EXE；
2. GTX 750 Ti、GT 1030 的 legacy token/RTC 收尾也必须在 Windows 完整关机后执行。

不要卸载显示设备，不要删除 Driver Store，也不要强删 `hiberfil.sys`。GTX1050
运行 `finish-vgpu-install.sh` 会直接显示 production-signature guard 并退出，不会
生成 ZIP、打开救援窗口或写配置。取得匹配目标 PnP/版本的 NVIDIA/Microsoft 正式
生产签名驱动前，没有可执行的 strict-A 推进步骤。

GTX 750 Ti 或 GT 1030 仍需 legacy B 收尾时，宿主执行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/finish-vgpu-install.sh <vm_id>
```

只复制脚本打印的小 `VgpuGuestFinish.exe`，以管理员身份运行一次；它处理 token、
关闭休眠/Fast Startup 并完整关机，宿主核对 UUID/GPU/token 后完成 RTC/EDID。
这些 profile 始终保持 B，不会写 `A/internal/FRL` marker。

## 验收当前 GTX 1050 B 模式

必须断开 RDP，在 native SDL/GTK 窗口进入桌面后检查。管理员 PowerShell：

```powershell
$gpu = Get-CimInstance Win32_VideoController |
  Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' } |
  Select-Object -First 1
$gpu | Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,
  AdapterRAM,CurrentHorizontalResolution,CurrentVerticalResolution,
  CurrentRefreshRate
```

当前安全路径应保持原生 PCI endpoint：

```text
Name: NVIDIA GeForce GTX 1050（marketing overlay）
PNP:  VEN_10DE&DEV_1E30
DriverVersion: 31.0.15.3833
ConfigManagerErrorCode: 0
AdapterRAM: 约 2048 MB
```

宿主检查：

```bash
nvidia-smi vgpu -q
```

当前 B/off 按原生 vGPU 合同验收；token/DLS 正常时 license 应为 `Licensed`，
FRL 由实际 vGPU profile/license 决定。不要套用历史 strict-A 的
`Unlicensed / N/A` 结果。

宿主输出中的 `vGPU Name` 仍可能是 GT 1030，mdev type 仍是 `nvidia-257`。这是
2048 MB backing resource 标签，不是 guest 身份失败，也不能据此声称底层已变成真实
GP107。GPU-Z 的核心数、总线宽度等底层字段仍可能来自 host/vGPU 路径。

## 第五步：验收分辨率和帧率

必须先满足 NVIDIA Code 0，再检查 EDID 和分辨率。VM3 的目标是回到显示器配置中的
native 1920×1080、约 59/60 Hz，并保留正常的向下兼容模式。

如果只看到 Microsoft 基本显示适配器、0 MB 或分辨率列表明显减少，说明原版 GRID
driver 没有正常绑定；这通常不是显示器 profile 本身的问题。不要在这种状态强制
同步 EDID，先按下一节回退到原生 endpoint 检查正式签名驱动。

动态 workload 已验证 VM3 不再固定为 3 FPS，但这不等于保证 60 FPS。静止桌面时
SDL 标题显示 `Present 0.0 FPS` 是像素去重的正常行为；拖动窗口、播放动画或运行
`winsat d3d -time 10` 才能观察动态提交。RDP 的编码帧率和动态分辨率都不算验收。

## 一键安全回退

只要历史严格身份出现 Basic Display Adapter、Code 28/43、黑屏或错误分辨率，先让
Windows 完整关机，再执行：

```bash
./deploy/start-vm.sh 3 --no-spoof --no-monitor-sync
```

这个 off 启动会：

- 恢复原生 `DEV_1E30` PCI 身份；
- 移除该 UUID 的 per-mdev 内部 identity；
- 忽略持久的 `VGPU_MDEV_FRL_ENABLED=0`，让 FRL 回到 profile 继承行为；
- 跳过本次 EDID 离线写入，便于先修复驱动。

不要自动删除现有 patched `oemN.inf` 或私有根，避免让当前 VM 无法启动；先在原生
endpoint 安装并验证匹配的 NVIDIA/Microsoft 正式签名 GRID driver，再由管理员单独
审计清理。不要重跑 strict finish，也不要手工向只读 `vm.conf` 追加 marker。

## 临时 RDP 只用于调试

可以临时启用 RDP 来查看日志或执行管理员 PowerShell，但不能用 RDP 会话
验收 GPU 数量、NVIDIA 输出分辨率或 FRL。每次连接都可能创建 Microsoft Remote
Display Adapter，RDP 的 `/dynamic-resolution` 也会改变会话模式列表。

调试结束后必须：

1. 断开所有 RDP 会话；
2. 恢复 NLA 和正常账号密码；
3. 删除临时 AutoLogon 明文密码；
4. 关闭临时 3389/5985 firewall rule 与 listener；
5. 在宿主确认 3389、5985 均不可连接；
6. 完整关机，再从 native SDL/GTK 冷启动做最终验收。

`setup-winrm.ps1` 会启用 Basic-over-HTTP WinRM、`TrustedHosts=*`、固定实验密码和
持久 AutoLogon，只能在隔离可信网段短时使用，不能留在完成后的 VM 中。

## token 与 RTC

默认 token 为：

```text
/home/ubuntu/images/staging/client_configuration_token.tok
```

同一受信任 DLS 的 VM 可以共用 token，但每台 VM 仍需逐台运行宿主收尾命令，不要
并行。GTX 1050 当前 B 模式按原生 vGPU license 合同验收。

RTC 始终由宿主提供：

```text
TZ=Asia/Shanghai
-rtc base=localtime,clock=host,driftfix=slew
```

不要在 guest 写 `RealTimeIsUniversal=1`，不要运行旧 `fix-rtc-utc.ps1`，也不要
强删 `hiberfil.sys` 或对休眠 NTFS 使用 `ntfsfix --clear-dirty`。旧 UTC VM 也运行
同一条收尾命令，由宿主在 guest 完整关机后安全迁移。

## 出错时只看这里

| 现象 | 处理 |
|---|---|
| GTX1050 finish 提示 strict-A disabled | 不运行旧 finish；旧 A 改用 production migration，新的 B 实例直接用 GPU-Z profile |
| staging 中发现旧 strict ZIP/driver stager | 不要执行；移入受限 legacy 归档并核对 current staging |
| Secure Boot/HVCI 检查失败 | 不要绕过或导入私有根；使用正式签名驱动并保持 B |
| marker 的 UUID/profile/driver/token 不匹配 | 确认 VM 编号与文件无误，为当前 VM 重新运行宿主收尾命令 |
| 出现 Basic Display Adapter 或 Code 28 | 完整关机，用 `--no-spoof --no-monitor-sync` 回退，再检查原版正式签名 GRID driver |
| Code 43 + 低分辨率 | 先查 host/guest driver 配对；host 535.161.05 必须回到 guest 538.33，不能使用 582.42 等更新分支；不要卸载设备 |
| 分辨率列表减少 | 先看 NVIDIA 是否 Code 0；驱动未绑定时不要先修 EDID |
| 控制面板没有授权页 | 不代表激活；当前 B 路径应继续核对正式驱动及 DLS/license |
| host 显示 GT 1030 | 正常 backing type 标签；当前以 guest 原生 `DEV_1E30`、名称和 Code 0 验收 |
| host 是 `Unlicensed / N/A` | 不要伪报成功；排查 B 模式 DLS/license，`N/A` 也不等于 Licensed |
| 只有 dma-buf/error-recovery warning | REGION 画面、驱动和动态更新正常时可记录后继续；它本身不是失败判据 |
| 宿主提示 sudo | 先运行 `sudo -v`，再重跑同一条命令 |

驱动构建、签名与模式边界见 [`DRIVER-INSTALL.md`](DRIVER-INSTALL.md)；授权/FRL
技术语义见 [`VGPU-LICENSING.md`](VGPU-LICENSING.md)。
