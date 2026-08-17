# NVIDIA mdev/vGPU 部署文档

本分支只提供一套 NVIDIA mdev/vGPU VM 生命周期：

```bash
./deploy/scripts/create-vm.sh <vm_id> [hardware/profile options]       # 可选：预选身份
./deploy/scripts/start-vm.sh <vm_id> [--vms-dir ABS|--vm-dir ABS|--instances-dir ABS] [options]
./deploy/scripts/stop-vm.sh  <vm_id> [--vms-dir ABS|--vm-dir ABS|--instances-dir ABS] [--force]
```

以上命令从仓库根目录执行。`deploy/scripts/` 是公开入口和唯一实现位置；教程、
`vmctl.sh` 与其他封装也只调用这里，不保留 `deploy/*.sh` 同名旧入口。

`off`、`B` 和 `A` 是同一 VM 链路上的 guest 身份模式，不是不同的显示后端。
host mdev resource、guest marketing identity、driver binding、license 和 FRL 必须分别
验收，不能只看一个名称或控制面板页面下结论。

> **只想修授权或“通用即插即用监视器”：** 直接照抄
> [`VGPU-RECOVERY-RUNBOOK.md`](VGPU-RECOVERY-RUNBOOK.md)。日常步骤只保留在这一页；
> token/DLS 和 EDID 原理分别归档在技术文档中。

## 从哪里开始

| 目标 | 文档 |
|---|---|
| 统一 V-11/G-11 的 `deploy/scripts/` 命令路径并查看完整入口 | [统一脚本入口](../scripts/README.md) |
| 对比最新 V-11 的 VM 操作、已补齐功能和不可混用边界 | [G11-V11-OPERATION-PARITY.md](G11-V11-OPERATION-PARITY.md) |
| 默认/指定 VM 路径、独立 bundle 和旧 G-11 目录迁移 | [STORAGE-PATHS-QUICKSTART.md](STORAGE-PATHS-QUICKSTART.md) |
| 第一次操作 G-11：portable EXE、base 注入、任意 VM 克隆与验收 | [G11-QUICKSTART.md](G11-QUICKSTART.md) |
| 普通 32/64 位程序统一板卡/显存身份、单 3D adapter、显示器持久化与一键回滚 | [G11-BOTTOM-GPU-IDENTITY.md](G11-BOTTOM-GPU-IDENTITY.md) |
| vGPU 硬件池、整机搭配合法性与宿主 CPU realization | [G11-HARDWARE-POOL.md](G11-HARDWARE-POOL.md) |
| 35 款显示器目录、正常 FHD/1K 分辨率白名单及已有 VM 一键刷新 | [G11-MONITOR-POOL.md](G11-MONITOR-POOL.md) |
| 无 VM 绑定显卡身份、GPU-Z 选装、新建/克隆通用性和 HWiNFO 边界 | [GPUZ-ONE-CLICK.md](GPUZ-ONE-CLICK.md) |
| HWiNFO64 x64 app-local 实验和不能承诺的字段 | [HWINFO-APP-LOCAL-EXPERIMENT.md](HWINFO-APP-LOCAL-EXPERIMENT.md) |
| 新装 Windows、制作 base、从 base 创建实例 | [VGPU-VM-CREATION.md](VGPU-VM-CREATION.md) |
| Windows ISO 高速 USB 安装、安装期 helper、IDE 回退与正式启动零光驱 | [G11-INSTALL-MEDIA.md](G11-INSTALL-MEDIA.md) |
| Windows 安装出现 `USBXHCI.SYS` / `PAGE_FAULT_IN_NONPAGED_AREA` | [USBXHCI-INSTALL-RECOVERY.md](USBXHCI-INSTALL-RECOVERY.md) |
| Windows 网卡有链路但没有 IPv4、宿主一键建桥、默认 LAN 与 VLAN 生命周期 | [G11-NETWORK-BRIDGE-VLAN.md](G11-NETWORK-BRIDGE-VLAN.md) |
| GRID 538.33 正式基线、三款显卡身份边界与 driver 回退 | [DRIVER-INSTALL.md](DRIVER-INSTALL.md) |
| 旧 A VM 迁移到原始生产签名驱动，同时保留设备/GPU-Z 型号 | [VGPU-PRODUCTION-MIGRATION.md](VGPU-PRODUCTION-MIGRATION.md) |
| 537.58 Xid/TDR 隔离、旧合同回滚与仅限可删除克隆的审计复现 | [SIGNED-CONSUMER-PRODUCTION.md](SIGNED-CONSUMER-PRODUCTION.md) |
| 授权 + 显示器最短照抄流程 | [VGPU-RECOVERY-RUNBOOK.md](VGPU-RECOVERY-RUNBOOK.md) |
| 私有通用收尾、token/DLS、Unlicensed、FRL 与控制面板授权页 | [VGPU-LICENSING.md](VGPU-LICENSING.md) |
| 开机 NumLock、`--no-numlock` 与首次桌面右键卡顿排查 | [G11-NUMLOCK-FIRST-BOOT.md](G11-NUMLOCK-FIRST-BOOT.md) |
| 理解 off/B/A 身份模式 | [STEALTH-APPROACHES.md](STEALTH-APPROACHES.md) |
| 备份、迁移和恢复每 VM bundle | [STORAGE-LAYOUT.md](STORAGE-LAYOUT.md) |
| 可选的 Linux 宿主 NVMe APST 检查、持久化与回滚 | [NVME-APST.md](NVME-APST.md) |
| 适配 Tesla V100 宿主资源 | [V100-ADAPTATION.md](V100-ADAPTATION.md) |
| 排查 QEMU、mdev、TPM 和 guest | [DEBUG.md](DEBUG.md) |

仓库级概览和完整命令表见 [`../README.md`](../README.md) 与
[`../USAGE.md`](../USAGE.md)。

## 傻瓜入口

新建与克隆使用同一个不绑定 VM 的显卡身份安装器；默认不需要 GPU-Z：

```bash
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh
./deploy/scripts/vmctl.sh clone 456 --start
# 进入 Windows 完成基础安装/授权后，为成品 VM 生成系统身份包：
./deploy/package-system-nvapi-projection.sh 456
```

`VgpuPortable.exe` 内嵌全部已审计 profile，不含 VM ID/UUID，也不内嵌、下载或
默认安装 GPU-Z。base 注入器默认只预置这一个文件；以后只有显式执行
`VgpuPortable.exe /with-gpuz` 才导入同目录官方、哈希锁定的 GPU-Z。B/native
每次启动时由 `start-vm.sh` 自动注入
只读 SMBIOS profile/UUID/catalog 声明，guest 安装后无需人工 host commit。克隆
未指定显卡或显示器时分别从审核池随机一次并持久化，克隆后立即同步显示器，普通
启动继续自动复核；无需单独执行 `vmctl monitor`。

portable 阶段使用 `vGPU Identity Query` 初验；成品系统包重启后以 x86/x64
`SYSTEM_NVAPI_VERIFY PASS`、唯一 present Display、DXGI/D3D 和 validated 收据
作为最终验收。系统包让普通程序共享同一板卡/显存合同，同时保留唯一原生
`DEV_1E30` 3D transport。base 注入要求
所有 VM 停止、standalone qcow2 以及干净、
未休眠的 NTFS，并只修改临时副本后原子发布。旧内嵌版 portable 必须重建并
替换，不会自动升级。

历史 `SPOOF_MODE=A` 仍运行
`package-vgpu-one-click.sh <vm_id>`，Windows 只双击绑定的
`VgpuProductionMigration.exe`；自动关机后宿主核验回执并提交 B/native。不要把
这个 legacy commit 步骤套到正常 portable clone。当前三款 B/native 实际 VM 都用
`package-vgpu-one-click.sh --with-license-token` 构建的私有 portable 收尾；
`finish-vgpu-install.sh` 只保留给统一前 GTX750Ti/GT1030 的旧回执/UTC 迁移，
GTX1050 strict-A 自签路径已经禁用。

显示器同步报告休眠/Fast Startup 时，不运行 GTX1050 finish，也不强挂载磁盘；统一
使用 `./deploy/scripts/recover-hibernated-vm.sh <vm_id>`。它只开本地标准 VGA，等 Windows
用内置命令完整关机后自动强制同步，失败即保持关闭。照抄命令与窗口内两步见
[`VGPU-RECOVERY-RUNBOOK.md`](VGPU-RECOVERY-RUNBOOK.md)。

Windows 分配的 published driver 是 `oemN.inf`，编号按每个 Driver Store 动态变化。
任何软件和文档都不能固定一个具体的 `oemN.inf` 编号。

## 身份与资源矩阵

| 模式 | Guest PCI 身份 | Driver | host 内部 identity | 当前用途 |
|---|---|---|---|---|
| `off` / `--no-spoof` | 原生 `DEV_1E30 / SUBSYS_132610DE` | 原版 GRID | 清理该 UUID 的覆盖 | 安装、恢复、诊断 |
| `B` / `--spoof-name-only` | 保持 `DEV_1E30` | 原版 GRID | 每 VM marketing name | 所有 profile 的通用安全路径 |
| `B` + `signed-consumer-v2` qualification | 已证明 profile 的 consumer tuple；当前为 `DEV_1C81 / SUBSYS_11C01028` | 对应 catalog 中未修改的原版 WHQL driver | native；禁止 internal override | 任意匹配 VM ID 的持久 outer-only 生产路径 |
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
./deploy/scripts/start-vm.sh 2 --install /home/ubuntu/images/iso/win10-ltsc.iso
```

Windows 装好并完整关机后，以原生 PCI 身份启动并安装基础 GRID 538.33：

```bash
./deploy/scripts/start-vm.sh 2 --no-spoof --no-monitor-sync
```

基础 driver Code 0 后再次完整关机，从普通 B 启动进入 Windows。三款型号统一构建
私有 `VgpuPortable.exe`，在 guest 双击后要求 `Licensed` 并关闭休眠/Fast Startup：

```bash
chmod 600 /home/ubuntu/images/staging/client_configuration_token.tok
./deploy/package-vgpu-one-click.sh --with-license-token
```

不要在 Driver Store 尚未准备目标 consumer ID 时手工传 `--spoof`，也不要把含 token
的私有 EXE 放进通用 base。

有合格 base 时，普通实例仍可直接生成配置和克隆系统盘：

```bash
./deploy/scripts/start-vm.sh 2
```

实例无论配置 GTX 750 Ti、GT 1030 还是 GTX 1050，正式驱动都保持 B/GRID
538.33。原版 537.58 outer-only 路径因 Xid 43/TDR 已生产隔离，详见
[`SIGNED-CONSUMER-PRODUCTION.md`](SIGNED-CONSUMER-PRODUCTION.md)。板卡、显存厂家
和 monitor 的普通程序一致性由
[`G11-BOTTOM-GPU-IDENTITY.md`](G11-BOTTOM-GPU-IDENTITY.md) 的 VM-bound 系统包
完成；不能把 Basic Display Adapter 当作 EDID 问题，也不能靠测试签名或私有根
绕过。

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

默认三款 profile 都要求 B/off 原生 PnP、driver `31.0.15.3833`、Code 0、约 2 GB
和 Licensed；marketing name 由每 VM host profile 提供。12 条原子 profile 的
板卡/显存静态字段可由同一系统用户态投影发布，但 PnP、DXGI/D3D 和调度仍是唯一
原生 vGPU。537.58 即使有历史 Code-0 qualification 也不会被生产使用。

最终分辨率必须在 native SDL/GTK 会话验收。RDP 会创建 Remote Display Adapter，
其动态分辨率、WMI 设备数量和编码帧率都不能代表 NVIDIA 输出或 FRL。静止桌面时
`SDL Present 0.0 FPS` 是像素去重的正常结果。

## 安全回退

旧 signed-consumer outer-only 合同会被当前启动门拒绝。先完整关机，再用合同
自己的精确备份回滚：

```bash
sudo ./deploy/signed-consumer-production.sh rollback <vm_id>
```

只有没有 `signed-consumer-v2` 合同的 legacy strict-A 历史实例，才使用明确的
`--no-spoof --no-monitor-sync` 救援恢复原生 `DEV_1E30`。不要自动卸载设备或删除
现有 `oemN.inf`；先验证未经修改、具有 NVIDIA/Microsoft 生产签名的 GRID driver，
再保持 B。不要重跑 strict 收尾。

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
