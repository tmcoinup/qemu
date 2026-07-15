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
| 已验证严格身份 | `gtx1050_2gb` |
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

严格身份需要三个条件同时满足：

1. QEMU PCI config 使用配置生成的消费卡 VID/DID/subsystem；
2. Windows Driver Store 已预暂存能匹配
   `PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028` 的 audited 538.33 包；
3. host per-mdev override 使用同一份配置生成内部 NVIDIA identity。

最终由启动器按当前 VM UUID 生成的核心配置是：

```text
SPOOF_MODE=A
VGPU_MDEV_INTERNAL_PCI_IDENTITY=1
VGPU_MDEV_FRL_ENABLED=0
```

对 GTX 1050，这会生成内部 `pci_id=0x1C8111C0` 与
`pci_device_id=0x1C81`。不要手工把这两个值复制给其他 GPU profile。

## 推荐：一条宿主命令完成 GTX 1050 收尾

前提是 `vm.conf` 的 `GPU_PROFILE=gtx1050_2gb`，Windows 已完整关机。在宿主执行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/finish-vgpu-install.sh <vm_id>
```

GTX 1050 会得到专用离线 bundle：

```text
/home/ubuntu/images/staging/VgpuGuestFinish-GTX1050.zip
```

保持宿主命令运行，将 ZIP 传入脚本打开的本地救援 Windows：

1. 先把 ZIP 完整解压到本地目录，不要直接从压缩包内运行；
2. 以管理员身份运行解压目录中唯一的 EXE；
3. 等待它完成 audited 538.33 patched driver 的验证、catalog 签名和 add-only
   预暂存；
4. 成功提示后让 Windows 完整关机，不要选择重启。

EXE 预暂存驱动时不会把当前显示设备强制重绑到新 INF。它把 Windows 实际分配的
`oemN.inf` 与版本写入完成 marker；这里的 `N` 是每个 Windows 实例动态分配的，
文档和配置绝不能固定任何 `oem<number>.inf` 编号。

Windows 关机后，宿主会核对 VM UUID、目标 profile、patched driver、token 和 marker。
只有全部一致时才原子更新该 VM 配置为 `A/internal=1/FRL=0`，完成 RTC/EDID 收尾并
冷启动。marker 不匹配时脚本停止，不会把一个未准备好的 VM 强行切到 `DEV_1C81`。

GTX 750 Ti 与 GT 1030 当前没有等价的锁定 patched driver。它们运行同一收尾入口时
仍保持通用 B 模式，不会自动写入严格 A/internal identity。

## 高级：只构建或检查 patched artifact

一键路径内部使用的 host 构建器也可单独运行：

```bash
./deploy/host/build-vgpu-driver-patch.py --profile gtx1050_2gb

# 只检查源资产和 patch 前提，不写输出
./deploy/host/build-vgpu-driver-patch.py \
  --profile gtx1050_2gb --check-only

# 验证已有产物，不修改它
./deploy/host/build-vgpu-driver-patch.py \
  --profile gtx1050_2gb --verify-only
```

默认输出为：

```text
/home/ubuntu/images/staging/538.33-gtx1050_2gb-patched
```

`stage-patched-vgpu-driver.ps1` 会重新生成并用 VM 本地测试证书签 catalog，再执行
`pnputil /add-driver`。因此当前严格路径要求 Secure Boot 关闭，且 HVCI/强制 Code
Integrity policy 未启用；脚本检测到不兼容策略会拒绝继续。测试证书受到 Windows
信任不等于 Microsoft WHQL/attestation 签名，文档与验收中不能这样声称。

日常操作优先使用 `finish-vgpu-install.sh` 生成的 ZIP；不要再运行历史的
`guest/install-patched-driver.ps1` 或 `guest/spoof-inf/inf-patch.ps1`，它们的目录、
安装 section 和版本契约不属于当前 audited 路径。

## 验收 GTX 1050 严格身份

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

当前 GTX 1050 严格路径应满足：

- `Name` 为 `NVIDIA GeForce GTX 1050`；
- PnP 含 `VEN_10DE&DEV_1C81&SUBSYS_11C01028`；
- `DriverVersion` 为 `31.0.15.3833`；
- `ConfigManagerErrorCode` 为 `0`；
- NVIDIA 显存约为 2048 MB；
- `pnputil` 指向 EXE 实际预暂存的 `oemN.inf`，而非文档中的固定编号。

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
骤减，首先说明 patched driver 没有绑定，不应先归因于 EDID。回到 off 模式检查
Driver Store：

```bash
./deploy/start-vm.sh <vm_id> --no-spoof --no-monitor-sync
```

确认驱动已预暂存、Code 0 后再完整关机重跑收尾。身份和 driver marker 变化会使
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
身份修复驱动。修复后重新运行一键收尾，或让傻瓜软件把该 VM 明确切回 B。

## 临时 RDP 边界

RDP 只用于传文件和短时调试，不是驱动、显示或分辨率验收通道。RDP 会创建 Microsoft
Remote Display Adapter，连接期间 WMI、设备数量和模式列表都可能与 native console
不同。调试完成后应恢复 NLA、移除临时自动登录和固定密码、关闭 3389/5985 防火墙与
监听，并在宿主确认端口已关闭；最终必须断开 RDP 后从 native SDL/GTK 冷启动验收。
