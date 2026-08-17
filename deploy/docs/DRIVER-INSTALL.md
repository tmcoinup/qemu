# G-11 NVIDIA guest 驱动：正式基线与身份层

本文只适用于 **G-11/vGPU**。新建和现有 VM 的正式驱动基线都是原生
`B/name-only` transport；消费卡板卡与显存信息由独立的系统用户态身份层合并，
不再通过 consumer Device ID 强绑 desktop 驱动。

## 已验证组合

| 组件 | 当前值 |
|---|---|
| host vGPU driver | `535.161.05` |
| guest GRID package | `538.33` |
| Windows DriverVersion | `31.0.15.3833` |
| present Display PnP | `PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE...` |
| host resource | profile 决定；当前 2 GB 档通常为 `nvidia-257 / 2048 MB` |
| guest 模式 | `SPOOF_MODE=B` / `VGPU_IDENTITY_TARGET=name-only` |
| 身份扩展 | VM-bound system NVAPI one-adapter merge |

staging 中个别源资产仍沿用历史文件名 `553.24.exe` /
`553.24-display-driver.zip`，但构建器锁定内容是 538.33，并复验 ZIP、原始 INF、
`DriverVer` 和精确哈希。不要按文件名猜版本，也不要用真正的 553.24 覆盖。

## 首次安装驱动

使用原生 vGPU 身份启动，避免在驱动安装阶段叠加任何身份层：

```bash
cd /home/ubuntu/projects/qemu
VM_ID=9
./deploy/scripts/start-vm.sh "$VM_ID" --no-spoof --no-monitor-sync
```

在 Windows 安装仓库审核过、未经修改且由 NVIDIA/Microsoft 生产链签名的 GRID
538.33。安装完成后执行 Windows“关机”，不要休眠或只断开 RDP。之后用正常入口
冷启动：

```bash
./deploy/scripts/start-vm.sh "$VM_ID"
```

管理员 PowerShell 只读验收：

```powershell
$display = @(Get-PnpDevice -Class Display -PresentOnly)
$display | Format-List FriendlyName,InstanceId,Status

Get-CimInstance Win32_VideoController |
  Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,
    AdapterRAM,CurrentHorizontalResolution,CurrentVerticalResolution

Get-CimInstance Win32_PnPSignedDriver |
  Where-Object DeviceClass -eq DISPLAY |
  Format-List DeviceName,InfName,DriverVersion,DriverProviderName,Signer,IsSigned
```

必须只有一个 present Display、Code 0、版本 `31.0.15.3833`，Provider 为 NVIDIA，
签名为正常生产链。published INF 是动态 `oemN.inf`，不能把某台 VM 的编号写死。

## 为什么设备仍是 DEV_1E30

`DEV_1E30` 是当前签名 GRID 驱动实际绑定并提供 WDDM/D3D 的 vGPU transport。
GTX 750 Ti、GT 1030、GTX 1050 profile 是 guest-visible 的静态消费卡身份，不会把
物理 GPU 或 mdev 资源变成另一颗芯片，也不会改变 scheduler、CUDA 执行资源或
实时 P-state。

正式系统身份模式保留 NVAPI 查询中 real vendor/device/external-device，并只合并
profile 的板卡 Subsystem、VBIOS、时钟、GDDR5、位宽、带宽和显存厂家。于是 PnP、
DXGI、D3D 与 NVAPI 仍对应同一个 adapter，同时普通 32/64 位硬件程序可以显示
ASUS/MSI/Gigabyte 和 Samsung/SK hynix/Micron 等目录值。

安装命令与回滚见
[`G11-BOTTOM-GPU-IDENTITY.md`](G11-BOTTOM-GPU-IDENTITY.md)。

## 537.58 为什么不能用

原版 desktop 537.58 / `31.0.15.3758` 的 INF/CAT/SYS 和 WHQL 事实仍有审计记录，
并曾达到 Code 0；但当前 host stack 的真实运行对照出现 host `Xid 43`、guest TDR、
驱动卸载和黑屏。它现在是 `quarantined-runtime-instability`，不能用于生产。

生产门会在读取旧 qualification 之前拒绝该条目；显式 `--driver-key`、旧 validated
回执或 root proof 都不能绕过。只允许在明确可删除克隆上复现实验，细节见
[`SIGNED-CONSUMER-PRODUCTION.md`](SIGNED-CONSUMER-PRODUCTION.md)。

## 显示器与驱动重枚举

驱动安装、版本变化或 Display instance 重建会让旧 monitor cache 失效。正常
`start-vm.sh` 会按 VM 的 `MONITOR_PROFILE` 同步基础 EDID；系统身份包还注册一个
SYSTEM 持久任务，在启动和登录后对新实例重新发布 FriendlyName 与
`EDID_OVERRIDE`。例如配置为 `aoc-2470w` 时，设备管理器应恢复为 `AOC 2470W`。

活动 RDP 会创建 Remote Display Adapter，不能用于严格的单 Display、分辨率或
3D 验收。最终必须断开 RDP，在本地 SDL/GTK/fb-shm 画面冷启动复核。

## 故障处理

| 现象 | 处理 |
|---|---|
| Microsoft 基本显示适配器、Code 28/43 | 回到 `--no-spoof --no-monitor-sync`，先修原版 GRID 538.33 绑定 |
| 设备管理器出现两个 Display | 断开 RDP；检查是否有 Remote Display Adapter，不要把 PCI bridge 算成显卡 |
| 显示器变成通用监视器 | 正常启动后等持久任务收敛；再运行系统包的 Verify |
| 偶发/持续黑屏 | 查 host Xid 与 guest TDR；确认没有 537.58 consumer 合同 |
| 休眠/Fast Startup 阻止离线同步 | 使用 `recover-hibernated-vm.sh VM_ID`，在标准 VGA 中关闭后完整关机 |
| 身份包拒绝未知 NVAPI DLL | 不手工覆盖；保留日志，使用原包 Rollback 恢复已验证的 NVIDIA 原件 |

不要卸载 DriverStore 中仍正常工作的 538.33，也不要靠反复睡眠唤醒掩盖 TDR。
系统身份层异常时使用包内 `Rollback-As-Administrator.cmd`；普通 vGPU 修复可完整
关机后再次从 `--no-spoof --no-monitor-sync` 启动。

## 永久安全边界

- 不开启 `testsigning`、`nointegritychecks`，不改 BCD；
- 不修改 INF/CAT/SYS，不重签 catalog，不导入私有根；
- 不安装测试签名/自签名内核驱动；
- 不启用 legacy A、internal PCI identity 或 per-mdev FRL；
- 不把宿主凭据写进仓库、脚本、包或日志。

历史 patched driver、strict-A finish 脚本和旧 GTX 1050 ZIP 仅保留 provenance，
不是当前安装入口。
