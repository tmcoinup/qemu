# G-11 开机 NumLock 与首次进入桌面卡顿

本文只适用于 G-11/vGPU。V-11 与 G-11 仍是独立分支；G-11 只参考并移植了 V-11
已经验证的 USB HID LED 状态机，没有调用 V-11 的 VM 生命周期、显卡或 guest 脚本。

## 日常只用一个启动命令

先确保 VM 已完整关机。第一次部署新源码时在宿主增量编译一次：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
```

以后正常启动不需要额外参数：

```bash
./deploy/scripts/start-vm.sh 9
```

启动器默认给 `usb-kbd` 加入稳定设备 ID `kbd0` 和
`x-force-numlock-on=on`。Windows 明确报告 NumLock 为 OFF 时，QEMU 才向这一个
键盘原子加入一组按下/释放，并等待 Windows 回报 ON；未知初始状态不会被猜成 OFF，
同一轮重复 OFF 也不会重复翻转。

该策略会在固件、登录界面或用户会话以后再次明确报告 OFF 时重新收敛为 ON。如果
本次确实要允许用户关闭 NumLock，使用：

```bash
./deploy/scripts/start-vm.sh 9 --no-numlock
```

恢复默认可用 `--numlock`，也可直接省略参数。启动摘要应显示：

```text
NumLock: guest LED 驱动，明确 OFF 时单次开启（QOM: kbd0）
```

这条路径不修改 `InitialKeyboardIndicators`，不安装 guest 服务/任务，不改 BCD，
也不发送无法判断方向的盲目切换键。新安装应答文件只保留关闭 Fast Startup 的
`HiberbootEnabled=0`；已有 Windows VM 无需重装，完整关机后用新 QEMU 冷启动即可。

若启动器提示本地 QEMU 缺少状态机，照抄它给出的增量构建命令，不要用
`--extra` 绕过能力门禁。已经运行的旧 QEMU 进程不会因宿主二进制重编而热更新，
必须让 Windows 完整关机并重新启动。

## 首次开机右键很慢怎么判断

先不要根据桌面体感把 license、FRL 和 Explorer 合并成一个原因。按下面顺序：

1. 在普通 B/native 启动中运行私有 `VgpuPortable.exe`。窗口必须同时出现身份
   `INSTALL PASS`、`License: Licensed` 和关闭休眠/Fast Startup 的成功行。
2. Windows 完整关机，等 QEMU 窗口自然退出，再普通冷启动一次。不要在
   `--no-spoof` 的驱动安装启动中运行 portable；那次启动没有只读 profile claim。
3. 冷启动进入桌面后等待 Windows 首次设备/搜索/Defender/NVIDIA Container 初始化
   收敛，再测试桌面右键。只在刚进入桌面的几分钟内慢，通常属于首次后台初始化；
   每次都慢才继续下一步。
4. 在 guest 管理员 PowerShell 收集证据：

```powershell
Get-CimInstance Win32_VideoController |
  Where-Object PNPDeviceID -like 'PCI\VEN_10DE*' |
  Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,Status

nvidia-smi -q | Select-String 'Product Name|Driver Version|License Status'

Get-Process explorer,nvcontainer,MsMpEng,SearchIndexer,TiWorker `
  -ErrorAction SilentlyContinue |
  Sort-Object CPU -Descending |
  Select-Object Name,CPU,WorkingSet,Responding
```

driver 必须是 `31.0.15.3833`、Code 0，license 必须明确为 `Licensed`。如果只有桌面
右键挂住而窗口拖动、键盘和持续动画都流畅，优先记录 `explorer.exe` 与右键 shell
扩展问题；可以在任务管理器中“重新启动 Windows 资源管理器”做一次可逆诊断。也可
在 NVIDIA 控制面板的“桌面”菜单暂时取消“添加桌面上下文菜单”：若右键立即恢复，
问题在 NVIDIA 的 Explorer 扩展初始化，而不是 vGPU 帧率。测试后可随时恢复该选项。
如果所有画面和输入都慢，再检查宿主 `nvidia-smi vgpu -q`、QEMU CPU 隔离和显示日志。

宿主检查：

```bash
nvidia-smi vgpu -q
./deploy/scripts/report-vm-boot-timing.sh 9
```

`License Status` 与 `Frame Rate Limit` 必须分别记录。`Unlicensed` 不能算完成；即使
当时仍显示 unrestricted 或 FRL 为 60，也只能说明采样当刻没有证据支持“正在被
3 FPS 限速”，不能替代最终的 `Licensed` 验收。NVIDIA 当前官方说明的软件授权
时序是：未取到 license 的 VM 启动后前 20 分钟仍为完整能力，20 分钟后限制到
15 FPS，24 小时后进一步到 3 FPS；成功取到 license 后恢复完整能力。参见
[NVIDIA vGPU Licensing FAQ](https://docs.nvidia.com/vgpu/faq/latest/nls.html)。

## VM9 当前正确顺序

VM9 已装原版 GRID 538.33 后，下一步不是 `finish-vgpu-install.sh`，也不是独立的
host WinRM 安装器。照抄：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/start-vm.sh 9
```

进入 Windows 后重新双击私有文件：

```text
/home/ubuntu/images/staging/VgpuPortableLicensed/VgpuPortable.exe
```

它内部调用 `deploy/guest/install-vgpu-license.ps1` 的打包副本，把 token 事务写到
NVIDIA 标准 `ClientConfigToken` 目录，重启 NVIDIA Container，并等待
`License Status: Licensed`。成功后完整关机，再运行一次相同的普通启动命令；新的
NumLock 状态机也从这次冷启动开始生效。
