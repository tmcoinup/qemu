# NVIDIA mdev/vGPU 部署文档

本分支只提供一套 NVIDIA mdev/vGPU VM 生命周期：

```bash
./deploy/start-vm.sh <vm_id> [options]
./deploy/stop-vm.sh  <vm_id> [--force]
```

`off`、`B` 和 `A` 是同一 VM 链路上的 guest 身份模式，不是不同的显示后端。
host mdev resource、guest marketing identity、driver binding、license 和 FRL 必须分别
验收，不能只看一个名称或控制面板页面下结论。

## 从哪里开始

| 目标 | 文档 |
|---|---|
| 新装 Windows、制作 base、从 base 创建实例 | [VGPU-VM-CREATION.md](VGPU-VM-CREATION.md) |
| GTX1050 严格身份、patched 538.33 与 driver 回退 | [DRIVER-INSTALL.md](DRIVER-INSTALL.md) |
| 一条命令收尾、ZIP/EXE 操作和常见恢复 | [VGPU-RECOVERY-RUNBOOK.md](VGPU-RECOVERY-RUNBOOK.md) |
| token/DLS、Unlicensed、FRL 与控制面板授权页 | [VGPU-LICENSING.md](VGPU-LICENSING.md) |
| 理解 off/B/A 身份模式 | [STEALTH-APPROACHES.md](STEALTH-APPROACHES.md) |
| 备份、迁移和恢复每 VM bundle | [STORAGE-LAYOUT.md](STORAGE-LAYOUT.md) |
| 适配 Tesla V100 宿主资源 | [V100-ADAPTATION.md](V100-ADAPTATION.md) |
| 排查 QEMU、mdev、TPM 和 guest | [DEBUG.md](DEBUG.md) |

仓库级概览和完整命令表见 [`../README.md`](../README.md) 与
[`../USAGE.md`](../USAGE.md)。

## 傻瓜入口

Windows 和匹配的基础 GRID driver 已准备好、且 guest 已完整关机时，只运行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/finish-vgpu-install.sh <vm_id>
```

脚本根据持久 `GPU_PROFILE` 选择流程：

- `gtx1050_2gb`：生成/复用
  `/home/ubuntu/images/staging/VgpuGuestFinish-GTX1050.zip`。把 ZIP 传入救援
  Windows，完整解压，只运行其中唯一的 EXE；它先预暂存 audited patched 538.33。
  宿主验证完成 marker 后才持久写入 `A/internal=1/FRL=0` 并冷启动。
- GTX 750 Ti、GT 1030：继续使用普通收尾包并保持 B，不会自动切消费卡 PCI ID。

Windows 分配的 published driver 是 `oemN.inf`，编号按每个 Driver Store 动态变化。
任何软件和文档都不能固定一个具体的 `oemN.inf` 编号。

## 身份与资源矩阵

| 模式 | Guest PCI 身份 | Driver | host 内部 identity | 当前用途 |
|---|---|---|---|---|
| `off` / `--no-spoof` | 原生 `DEV_1E30 / SUBSYS_132610DE` | 原版 GRID | 清理该 UUID 的覆盖 | 安装、恢复、诊断 |
| `B` / `--spoof-name-only` | 保持 `DEV_1E30` | 原版 GRID | 每 VM marketing name | 所有 profile 的通用安全路径 |
| GTX1050 严格 `A` | `DEV_1C81 / SUBSYS_11C01028` | audited patched 538.33 | `pci_id=0x1C8111C0`、`pci_device_id=0x1C81` | 当前只在 GTX1050 验证 |

严格 GTX 1050 的持久配置为：

```text
SPOOF_MODE=A
VGPU_MDEV_INTERNAL_PCI_IDENTITY=1
VGPU_MDEV_FRL_ENABLED=0
```

这不会改变 host backing resource。它仍是 `nvidia-257 / 2048 MB`，因此 host
`nvidia-smi vgpu` 可能继续显示 GT 1030/type 标签；这不是 guest 身份失败。反过来，
guest 显示 GTX 1050 也不能被描述成底层已变成真实 GP107，核心数、频率、总线宽度和
性能仍来自实际 vGPU/物理路径。

## 最短新装路径

从 ISO 安装：

```bash
./deploy/start-vm.sh 2 --install /home/ubuntu/images/iso/win10-ltsc.iso
```

Windows 装好并完整关机后，以原生 PCI 身份启动并安装基础 GRID 538.33：

```bash
./deploy/start-vm.sh 2 --no-spoof --no-monitor-sync
```

基础 driver Code 0 后再次完整关机，再运行统一收尾入口。不要在 Driver Store 尚未
准备目标 consumer ID 时手工传 `--spoof`。

有合格 base 时，普通实例仍可直接生成配置和克隆系统盘：

```bash
./deploy/start-vm.sh 2
```

若该实例配置为 GTX 1050，但 base 尚未预暂存 audited patched 包，应先回到 off，
运行收尾 ZIP，再由宿主自动切严格身份；不能把 Basic Display Adapter 当作 EDID 问题。

## License 与 FRL 必须分开显示

当前有两种不同验收合同：

- B/off：token/DLS 正常时，host 应显示 `License Status: Licensed`；
- GTX1050 严格 A：控制面板授权页消失，但这不等于“已激活”。当前 host 如实显示
  `License Status: Unlicensed`，同时 per-mdev `frl_enabled=0` 使
  `Frame Rate Limit: N/A`。

`N/A` 只表示该实例的 frame-rate limiter 未启用，不授予 license。傻瓜软件不能把
“授权页消失”“Unlicensed”或“FRL N/A”中的任何一个翻译成“已激活”。若业务要求
正式 `Licensed` 状态，应完整关机后回到 B/off，再检查 token/DLS。

## 日常验收

Guest 管理员 PowerShell：

```powershell
$gpu = Get-CimInstance Win32_VideoController |
  Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' } |
  Select-Object -First 1
$gpu | Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,
  AdapterRAM,CurrentHorizontalResolution,CurrentVerticalResolution,
  CurrentRefreshRate
```

Host：

```bash
nvidia-smi vgpu -q
```

GTX1050 严格路径要求 guest 名称为 `NVIDIA GeForce GTX 1050`、PnP 含
`DEV_1C81&SUBSYS_11C01028`、driver 为 `31.0.15.3833`、Code 0、约 2 GB；host
license/FRL 则按上一节如实报告。B/off 仍要求原生 ID、Code 0 和 Licensed。

最终分辨率必须在 native SDL/GTK 会话验收。RDP 会创建 Remote Display Adapter，
其动态分辨率、WMI 设备数量和编码帧率都不能代表 NVIDIA 输出或 FRL。静止桌面时
`SDL Present 0.0 FPS` 是像素去重的正常结果。

## 安全回退

GTX1050 严格身份出现 Basic Display Adapter、Code 28/43、黑屏或分辨率减少时，
完整关机后执行：

```bash
./deploy/start-vm.sh <vm_id> --no-spoof --no-monitor-sync
```

这会恢复原生 `DEV_1E30`、清理该 UUID 的内部 identity，并在 off 启动中忽略持久
FRL override。不要卸载设备或删除 `oemN.inf`；先修复原生 GRID 路径，再重跑
`finish-vgpu-install.sh`。

## 临时 RDP

RDP 仅允许短时传文件/调试。完成后应恢复 NLA、删除临时 AutoLogon 凭据、关闭
3389/5985 firewall/listener、确认端口不可连接，并从 native SDL/GTK 冷启动验收。
`setup-winrm.ps1` 会启用固定实验密码、Basic HTTP WinRM 和 `TrustedHosts=*`，不能
留在完成后的生产 VM。

## 启动前检查

- IOMMU、VFIO 和 `nvidia-vgpu-mgr` 已就绪；
- 所选 mdev resource profile 有可用实例；
- host `535.161.05` 与 guest `538.33 / 31.0.15.3833` 基线未被替换；
- GTX1050 ZIP 使用完整 audited bundle，Secure Boot/HVCI 不阻止测试 catalog；
- Windows 已关闭休眠/Fast Startup，才能安全处理 marker、RTC 和 EDID；
- VM bundle、磁盘、NVRAM 和 TPM 状态在运行时没有被移动或手工改写。
