# NVIDIA vGPU guest 驱动与 GTX 1050 严格身份

本文记录当前已验证的驱动组合、`finish-vgpu-install.sh` 一键收尾语义，以及
GTX 1050 严格身份与通用 B 模式的边界。完整的新建 VM 顺序见
[`VGPU-VM-CREATION.md`](VGPU-VM-CREATION.md)，故障恢复见
[`VGPU-RECOVERY-RUNBOOK.md`](VGPU-RECOVERY-RUNBOOK.md)。

## 已验证基线

| 组件 | 当前值 |
|---|---|
| host vGPU driver | `535.161.05` |
| guest GRID driver | `538.33` |
| Windows DriverVersion | `31.0.15.3833` |
| host resource | `nvidia-257 / 2048 MB` |
| legacy 严格身份实验 | `gtx1050_2gb`（自签路径已禁用） |
| Guest PCI tuple | `10DE:1C81 / SUBSYS_11C01028` |

staging 中的源资产仍沿用历史文件名 `553.24.exe` 和
`553.24-display-driver.zip`，但锁定内容是 538.33。构建器会检查 ZIP、原始 INF、
`DriverVer` 和生成结果的精确哈希；不要用真正的 553.24 替换这些文件。

## 先区分资源与身份

GTX 1050 严格模式不会把宿主 mdev 变成真实 GP107，也不会改变 CUDA 核心数、频率、
总线宽度或调度份额：

- host 仍分配 `nvidia-257 / 2048 MB`；
- host `nvidia-smi vgpu` 的 `vGPU Name` 仍可能显示底层 GT 1030/type 标签；
- guest 的目标是让 PnP、GPU-Z 和一般身份查询得到
  `NVIDIA GeForce GTX 1050` 与 `DEV_1C81`；
- GPU-Z 的部分底层规格可能继续来自真实 vGPU/物理路径，不能把这些结果描述成
  完整的 GTX 1050 硬件仿真。

未来重新启用严格身份至少需要三个条件同时满足：

1. QEMU PCI config 使用配置生成的消费卡 VID/DID/subsystem；
2. Windows Driver Store 已有能匹配
   `PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028`、且未经修改并由
   NVIDIA/Microsoft 正式生产签名的驱动包；
3. host per-mdev override 使用同一份配置生成内部 NVIDIA identity。

最终由启动器按当前 VM UUID 生成的核心配置是：

```text
SPOOF_MODE=A
VGPU_MDEV_INTERNAL_PCI_IDENTITY=1
VGPU_MDEV_FRL_ENABLED=0
```

对 GTX 1050，这会生成内部 `pci_id=0x1C8111C0` 与
`pci_device_id=0x1C81`。不要手工把这两个值复制给其他 GPU profile。

## 当前策略：strict-A 自签收尾已禁用

现有 538.33 实验路径修改 NVIDIA INF，随后用 VM 本地证书重签 catalog 并导入
Root/TrustedPublisher。它不是 NVIDIA/Microsoft 生产签名，因此不满足本项目当前
要求。`finish-vgpu-install.sh` 遇到 `gtx1050_2gb` 会在生成 guest 包、启动 VM 或
写入 `A/internal/FRL` marker 之前 fail-closed；`stage-patched-vgpu-driver.ps1`
与 `install-patched-driver.ps1` 也在任何证书/Driver Store 动作前永久拒绝。

GTX 1050 以及新建 VM 继续保持 B 模式。不要手工补
`VGPU_IDENTITY_TARGET=full-consumer`、`VGPU_MDEV_INTERNAL_PCI_IDENTITY=1`、
`VGPU_MDEV_FRL_ENABLED=0` 或 driver completion marker。只有取得未经修改、能匹配
目标 PnP tuple/版本、并由 NVIDIA/Microsoft 正式生产签名的驱动后，才能另行设计
verification-only 的 strict-A transition；不得改 INF、重签 catalog、导入私有根或
修改 BCD 完整性选项。

`build-vgpu-driver-patch.py`、历史 patched artifact 与旧 GTX 1050 ZIP 只保留为
legacy provenance，不是安装入口。不要运行或重新分发。

## 未来正式签名 strict-A 的验收条件

进入 native SDL/GTK 桌面后，在管理员 PowerShell 检查：

```powershell
$gpu = Get-CimInstance Win32_VideoController |
  Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' } |
  Select-Object -First 1
$gpu | Format-List Name,PNPDeviceID,DriverVersion,Status,
  ConfigManagerErrorCode,AdapterRAM,CurrentHorizontalResolution,
  CurrentVerticalResolution,CurrentRefreshRate

pnputil /enum-devices /class Display /drivers
```

未来恢复 GTX 1050 严格路径时必须满足：

- `Name` 为 `NVIDIA GeForce GTX 1050`；
- PnP 含 `VEN_10DE&DEV_1C81&SUBSYS_11C01028`；
- `DriverVersion` 为 `31.0.15.3833`；
- `ConfigManagerErrorCode` 为 `0`；
- NVIDIA 显存约为 2048 MB；
- `pnputil` 指向正式签名包实际发布的动态 `oemN.inf`，而非固定编号；
- DriverStore catalog 与已加载 `nvlddmkm.sys` 都通过生产信任链验收。

宿主检查：

```bash
nvidia-smi vgpu -q
journalctl -b -u nvidia-vgpu-mgr -u nvidia-vgpud --no-pager | \
  rg 'Virtual Device Id|Patching|frl_enabled|1c81'
```

严格路径下，host backing label 继续显示 GT 1030 或 `nvidia-257` 是正常的；guest
PnP/driver Code 0 才是身份绑定验收依据。授权和 FRL 的特殊含义见
[`VGPU-LICENSING.md`](VGPU-LICENSING.md)。

## 分辨率与驱动绑定

切到 `DEV_1C81` 后若 Windows 只显示 Microsoft 基本显示适配器、0 MB 或分辨率列表
骤减，首先说明正式签名 driver 没有绑定，不应先归因于 EDID。回到 off 模式检查
Driver Store：

```bash
./deploy/start-vm.sh <vm_id> --no-spoof --no-monitor-sync
```

确认正式签名原版驱动、Code 0 后保持 B。不要重跑已禁用 strict 收尾。身份变化会使
显示器同步 marker 失效，下一次正常冷启动会重新同步 EDID。最终分辨率必须在 native
SDL/GTK 会话验收；RDP 的 Remote Display Adapter 和动态分辨率不能代表 NVIDIA
输出的真实模式列表。

## 安全回退

严格身份异常时不要卸载设备或删除 Driver Store。完整关机后执行：

```bash
./deploy/start-vm.sh <vm_id> --no-spoof --no-monitor-sync
```

`--no-spoof` 会恢复原生 `DEV_1E30` 启动，并清理该 UUID 的 per-mdev 内部 identity；
持久化的 `VGPU_MDEV_FRL_ENABLED=0` 在 off 模式也不会应用。这样可以用原生 GRID
身份修复驱动。修复后保持 B；不要运行历史 strict 一键收尾。

## 临时 RDP 边界

RDP 只用于传文件和短时调试，不是驱动、显示或分辨率验收通道。RDP 会创建 Microsoft
Remote Display Adapter，连接期间 WMI、设备数量和模式列表都可能与 native console
不同。调试完成后应恢复 NLA、移除临时自动登录和固定密码、关闭 3389/5985 防火墙与
监听，并在宿主确认端口已关闭；最终必须断开 RDP 后从 native SDL/GTK 冷启动验收。
