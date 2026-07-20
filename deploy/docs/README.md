# NVIDIA mdev/vGPU 部署文档

本分支只提供一套 NVIDIA mdev/vGPU VM 生命周期：

```bash
./deploy/start-vm.sh <vm_id> [--vm-dir ABS|--instances-dir ABS] [options]
./deploy/stop-vm.sh  <vm_id> [--vm-dir ABS|--instances-dir ABS] [--force]
```

`off`、`B` 和 `A` 是同一 VM 链路上的 guest 身份模式，不是不同的显示后端。
host mdev resource、guest marketing identity、driver binding、license 和 FRL 必须分别
验收，不能只看一个名称或控制面板页面下结论。

## 从哪里开始

| 目标 | 文档 |
|---|---|
| 默认/指定 VM 路径、独立 bundle 和旧 G-11 目录迁移 | [STORAGE-PATHS-QUICKSTART.md](STORAGE-PATHS-QUICKSTART.md) |
| 第一次操作 G-11：portable EXE、base 注入、任意 VM 克隆与验收 | [G11-QUICKSTART.md](G11-QUICKSTART.md) |
| 无 VM 绑定离线包、基础镜像安全边界和 HWiNFO 边界 | [GPUZ-ONE-CLICK.md](GPUZ-ONE-CLICK.md) |
| HWiNFO64 x64 app-local 实验和不能承诺的字段 | [HWINFO-APP-LOCAL-EXPERIMENT.md](HWINFO-APP-LOCAL-EXPERIMENT.md) |
| 新装 Windows、制作 base、从 base 创建实例 | [VGPU-VM-CREATION.md](VGPU-VM-CREATION.md) |
| GTX1050 strict-A 为何禁用、生产签名边界与 driver 回退 | [DRIVER-INSTALL.md](DRIVER-INSTALL.md) |
| 旧 A VM 迁移到原始生产签名驱动，同时保留设备/GPU-Z 型号 | [VGPU-PRODUCTION-MIGRATION.md](VGPU-PRODUCTION-MIGRATION.md) |
| B 模式 token/RTC 收尾和常见恢复；strict-A ZIP 为 legacy 禁用 | [VGPU-RECOVERY-RUNBOOK.md](VGPU-RECOVERY-RUNBOOK.md) |
| token/DLS、Unlicensed、FRL 与控制面板授权页 | [VGPU-LICENSING.md](VGPU-LICENSING.md) |
| 理解 off/B/A 身份模式 | [STEALTH-APPROACHES.md](STEALTH-APPROACHES.md) |
| 备份、迁移和恢复每 VM bundle | [STORAGE-LAYOUT.md](STORAGE-LAYOUT.md) |
| 适配 Tesla V100 宿主资源 | [V100-ADAPTATION.md](V100-ADAPTATION.md) |
| 排查 QEMU、mdev、TPM 和 guest | [DEBUG.md](DEBUG.md) |

仓库级概览和完整命令表见 [`../README.md`](../README.md) 与
[`../USAGE.md`](../USAGE.md)。

## 傻瓜入口

新建与克隆使用同一个不绑定 VM 的离线包：

```bash
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh
./deploy/clone-vgpu-base.sh 456 --gpu-profile gtx1050_2gb --start
```

`VgpuPortable.exe` 内嵌全部已审计 profile，不含 VM ID/UUID。B/native 每次启动时
由 `start-vm.sh` 自动注入只读 SMBIOS profile/UUID/catalog 声明，guest 安装后
无需人工 host commit。base 注入要求所有 VM 停止、standalone qcow2 以及干净、
未休眠的 NTFS，并只修改临时副本后原子发布。

历史 `SPOOF_MODE=A` 仍运行
`package-vgpu-one-click.sh <vm_id>`，Windows 只双击绑定的
`VgpuProductionMigration.exe`；自动关机后宿主核验回执并提交 B/native。不要把
这个 legacy commit 步骤套到正常 portable clone。`finish-vgpu-install.sh` 只保留
给 legacy B 的 token/RTC 收尾；GTX1050 strict-A 自签路径已经禁用。

Windows 分配的 published driver 是 `oemN.inf`，编号按每个 Driver Store 动态变化。
任何软件和文档都不能固定一个具体的 `oemN.inf` 编号。

## 身份与资源矩阵

| 模式 | Guest PCI 身份 | Driver | host 内部 identity | 当前用途 |
|---|---|---|---|---|
| `off` / `--no-spoof` | 原生 `DEV_1E30 / SUBSYS_132610DE` | 原版 GRID | 清理该 UUID 的覆盖 | 安装、恢复、诊断 |
| `B` / `--spoof-name-only` | 保持 `DEV_1E30` | 原版 GRID | 每 VM marketing name | 所有 profile 的通用安全路径 |
| GTX1050 legacy `A`（禁用） | `DEV_1C81 / SUBSYS_11C01028` | 修改 INF/自签 538.33，不合规 | `pci_id=0x1C8111C0`、`pci_device_id=0x1C81` | 仅历史记录，不是当前入口 |

legacy GTX 1050 严格实验的持久配置曾为（禁用，不得手工写入）：

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

基础 driver Code 0 后再次完整关机。GTX750Ti/GT1030 只有在需要 legacy B 的
token/RTC 处理时才运行统一收尾入口；GTX1050 保持 B，不运行 strict 收尾。不要在
Driver Store 尚未准备目标 consumer ID 时手工传 `--spoof`。

有合格 base 时，普通实例仍可直接生成配置和克隆系统盘：

```bash
./deploy/start-vm.sh 2
```

若该实例配置为 GTX 1050，当前也保持 B，只使用未经修改且具有 NVIDIA/Microsoft
生产签名的 GRID driver。历史 patched ZIP/自签 catalog 已禁用；不能把 Basic
Display Adapter 当作 EDID 问题，也不能靠测试签名或私有根绕过。

## License 与 FRL 必须分开显示

当前支持的三款 profile 都按 B/off 合同验收：token/DLS 正常时，host 应显示
`License Status: Licensed`。历史 GTX1050 严格 A 曾出现控制面板授权页消失、
`Unlicensed / FRL N/A`；那是已禁用的自签实验记录，不是当前验收合同，也不等于
“已激活”。

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

当前三款 profile 都要求 B/off 原生 PnP、driver `31.0.15.3833`、Code 0、约 2 GB
和 Licensed；marketing name 由每 VM host profile 提供。只有未来取得匹配目标 tuple
且未经修改的 NVIDIA/Microsoft 生产签名驱动后，才能另行定义 GTX1050 strict-A
验收。

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
FRL override。不要自动卸载设备或删除现有 `oemN.inf`；先安装并验证未经修改、具有
NVIDIA/Microsoft 生产签名的 GRID driver，再保持 B。不要重跑 strict 收尾。

## 临时 RDP

RDP 仅允许短时传文件/调试。完成后应恢复 NLA、删除临时 AutoLogon 凭据、关闭
3389/5985 firewall/listener、确认端口不可连接，并从 native SDL/GTK 冷启动验收。
`setup-winrm.ps1` 会启用固定实验密码、Basic HTTP WinRM 和 `TrustedHosts=*`，不能
留在完成后的生产 VM。

## 启动前检查

- IOMMU、VFIO 和 `nvidia-vgpu-mgr` 已就绪；
- 所选 mdev resource profile 有可用实例；
- host `535.161.05` 与 guest `538.33 / 31.0.15.3833` 基线未被替换；
- GTX1050 使用未经修改且具有 NVIDIA/Microsoft 生产签名的 driver；current staging
  中不得出现历史 strict ZIP、driver stager 或测试 catalog；
- Windows 已关闭休眠/Fast Startup，才能安全处理 marker、RTC 和 EDID；
- VM bundle、磁盘、NVRAM 和 TPM 状态在运行时没有被移动或手工改写。
