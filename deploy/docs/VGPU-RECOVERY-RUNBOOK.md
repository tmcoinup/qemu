# vGPU 一键收尾与恢复：傻瓜版

日常只记住两条规则：

1. Windows 必须完整关机后再运行宿主收尾命令；
2. GTX 1050 使用专用 ZIP，必须先解压，只运行里面唯一的 EXE。

不要卸载显示设备，不要删除 Driver Store，也不要强删 `hiberfil.sys`。下面以 `vm3`
为例，其他 VM 只替换编号。

## 第一步：宿主运行一条命令

```bash
cd /home/ubuntu/projects/qemu
./deploy/finish-vgpu-install.sh 3
```

不要关闭这个终端。脚本会读取 `vm3` 的持久配置并打开本地 SDL 救援窗口。

### 如果配置是 GTX 1050

终端会显示专用文件：

```text
/home/ubuntu/images/staging/VgpuGuestFinish-GTX1050.zip
```

这个 bundle 同时携带 audited 538.33 GTX 1050 driver 收尾材料和 token。不要改名、
拆包替换文件或只取其中一部分。

### 如果是 GTX 750 Ti 或 GT 1030

脚本继续生成/复用普通收尾包。这两个 profile 当前没有 audited 严格 PCI driver，
收尾后仍使用 B 模式；不要期待它们自动切换 `DEV_1380` 或 `DEV_1D01`。

## 第二步：Windows 只运行一次 EXE

在脚本打开的救援 Windows 中：

1. 用自己的安全文件传输方式把终端显示的文件传入当前 VM；
2. GTX 1050 必须先把 ZIP 完整解压到一个本地目录；
3. 以管理员身份运行解压目录中唯一的 EXE，UAC 选择“是”；
4. 等待绿色成功提示，点“确定”；
5. 等待 Windows 自动完整关机，不要点“重启”，不要关闭 QEMU 窗口或宿主终端。

GTX 1050 EXE 会先验证并 add-only 预暂存 patched 538.33 driver。它不会当场强制重绑
当前显示设备；Windows 实际分配的驱动名可能是任意 `oemN.inf`。脚本会把这个实际值
写入完成 marker，不能照抄另一台 VM 的 `oemN.inf` 编号。

EXE 还会关闭休眠/Fast Startup、处理 token 并写入当前 VM UUID 对应的 marker。任一
检查失败时它不会伪造成功，也不会要求宿主继续切身份。

## 第三步：等待宿主自动完成

Windows 关机后，宿主会校验：

- VM UUID 和目标 GPU profile；
- GTX 1050 patched driver 的版本与实际 `oemN.inf`；
- token 哈希和完成状态；
- Windows 确实完整关机，可安全执行 RTC/EDID 离线处理。

GTX 1050 只有校验全部通过，宿主才把该 VM 持久配置原子切为：

```text
SPOOF_MODE=A
VGPU_MDEV_INTERNAL_PCI_IDENTITY=1
VGPU_MDEV_FRL_ENABLED=0
```

然后冷启动。其他 GPU profile 保持 B。若宿主报 marker 不匹配，它会停止，不会让
Windows 在没有匹配驱动时直接面对消费卡 PCI ID。

## 第四步：验收 GTX 1050

必须断开 RDP，在 native SDL/GTK 窗口进入桌面后检查。管理员 PowerShell：

```powershell
$gpu = Get-CimInstance Win32_VideoController |
  Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' } |
  Select-Object -First 1
$gpu | Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,
  AdapterRAM,CurrentHorizontalResolution,CurrentVerticalResolution,
  CurrentRefreshRate
```

GTX 1050 严格路径应得到：

```text
Name: NVIDIA GeForce GTX 1050
PNP:  VEN_10DE&DEV_1C81&SUBSYS_11C01028
DriverVersion: 31.0.15.3833
ConfigManagerErrorCode: 0
AdapterRAM: 约 2048 MB
```

宿主检查：

```bash
nvidia-smi vgpu -q
```

当前严格路径应如实显示：

```text
License Status: Unlicensed
Frame Rate Limit: N/A
```

NVIDIA 控制面板的授权页会因为设备按消费卡呈现而消失；这不代表“已经激活”。
`Unlicensed` 也不能写成 `Licensed`。`Frame Rate Limit: N/A` 表示该 UUID 的
`frl_enabled=0` 生效，不等于获得 license。

宿主输出中的 `vGPU Name` 仍可能是 GT 1030，mdev type 仍是 `nvidia-257`。这是
2048 MB backing resource 标签，不是 guest 身份失败，也不能据此声称底层已变成真实
GP107。GPU-Z 的核心数、总线宽度等底层字段仍可能来自 host/vGPU 路径。

## 第五步：验收分辨率和帧率

必须先满足 NVIDIA Code 0，再检查 EDID 和分辨率。VM3 的目标是回到显示器配置中的
native 1920×1080、约 59/60 Hz，并保留正常的向下兼容模式。

如果只看到 Microsoft 基本显示适配器、0 MB 或分辨率列表明显减少，说明 patched
driver 没有绑定；这通常不是显示器 profile 本身的问题。不要在这种状态强制同步
EDID，先按下一节回退并重跑收尾。

动态 workload 已验证 VM3 不再固定为 3 FPS，但这不等于保证 60 FPS。静止桌面时
SDL 标题显示 `Present 0.0 FPS` 是像素去重的正常行为；拖动窗口、播放动画或运行
`winsat d3d -time 10` 才能观察动态提交。RDP 的编码帧率和动态分辨率都不算验收。

## 一键安全回退

只要严格身份出现 Basic Display Adapter、Code 28/43、黑屏或错误分辨率，先让
Windows 完整关机，再执行：

```bash
./deploy/start-vm.sh 3 --no-spoof --no-monitor-sync
```

这个 off 启动会：

- 恢复原生 `DEV_1E30` PCI 身份；
- 移除该 UUID 的 per-mdev 内部 identity；
- 忽略持久的 `VGPU_MDEV_FRL_ENABLED=0`，让 FRL 回到 profile 继承行为；
- 跳过本次 EDID 离线写入，便于先修复驱动。

不要删除 patched `oemN.inf`；off 模式下它不会匹配原生 `DEV_1E30`。在原生 GRID
路径确认 538.33/Code 0 后完整关机，再重跑：

```bash
./deploy/finish-vgpu-install.sh 3
```

若不再需要严格 GTX 1050，让傻瓜软件明确把 VM 切回 B；不要通过手工向只读
`vm.conf` 追加互相冲突的字段来回退。

## 临时 RDP 只用于调试

可以临时启用 RDP 来传 ZIP、查看日志或执行管理员 PowerShell，但不能用 RDP 会话
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
并行。GTX 1050 严格模式仍保存 token，方便回退 B/off；token 存在不等于严格模式
已经 Licensed。

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
| GTX1050 bundle 不是 `VgpuGuestFinish-GTX1050.zip` | 停止，核对当前 VM 的 `GPU_PROFILE` 和宿主输出，不要拿普通包强切 A |
| EXE 提示必须先解压 | 把整个 ZIP 解压到本地目录，再运行其中唯一的 EXE |
| Secure Boot/HVCI 检查失败 | 不要绕过；当前测试 catalog 与该安全策略不兼容，回退 B/off |
| marker 的 UUID/profile/driver/token 不匹配 | 确认 VM 编号与文件无误，为当前 VM 重新运行宿主收尾命令 |
| 出现 Basic Display Adapter 或 Code 28 | 完整关机，用 `--no-spoof --no-monitor-sync` 回退，再检查 patched driver 预暂存 |
| Code 43 | 回退 off，确认 538.33、时间和原生 GRID 路径；不要卸载设备 |
| 分辨率列表减少 | 先看 NVIDIA 是否 Code 0；驱动未绑定时不要先修 EDID |
| 控制面板没有授权页 | GTX1050 严格身份的当前表现；不代表激活，以 host license/FRL 两个字段为准 |
| host 显示 GT 1030 | 正常 backing type 标签；以 guest `DEV_1C81`、名称和 Code 0 验收 |
| host 是 `Unlicensed / N/A` | 当前严格路径的真实状态；`N/A` 只表示 FRL 关闭，不能写成 Licensed |
| 只有 dma-buf/error-recovery warning | REGION 画面、驱动和动态更新正常时可记录后继续；它本身不是失败判据 |
| 宿主提示 sudo | 先运行 `sudo -v`，再重跑同一条命令 |

驱动构建、签名与模式边界见 [`DRIVER-INSTALL.md`](DRIVER-INSTALL.md)；授权/FRL
技术语义见 [`VGPU-LICENSING.md`](VGPU-LICENSING.md)。
