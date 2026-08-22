# NVIDIA vGPU 身份模式：off / B / legacy GTX 1050 A（禁用）

本分支只有一条 NVIDIA mdev/vGPU VM 链路：

```bash
./deploy/scripts/start-vm.sh <vm_id> [options]
./deploy/scripts/stop-vm.sh  <vm_id> [--force]
```

`off`、`B` 和 `A` 只改变 guest 身份策略，不会更换 host mdev resource、物理 GPU、
framebuffer 配额或 QEMU REGION 显示路径。当前完整消费卡身份只审计了 GTX 1050；
GTX 750 Ti 和 GT 1030 保持 name-only B。

## 新配置的安全状态机

所有新配置都先写 `SPOOF_MODE=B`，避免 Windows Driver Store 尚未准备时直接面对消费
PCI ID。最终目标由另一个字段记录：

| `GPU_PROFILE` | 初始模式 | `VGPU_IDENTITY_TARGET` | 收尾后的模式 |
|---|---|---|---|
| `gtx1050_2gb` | B | `name-only` | B |
| `gtx750ti_2gb` | B | `name-only` | B |
| `gt1030_2gb` | B | `name-only` | B |

strict-A 不再是交付目标。启动器拒绝新的 CLI/持久化 A；legacy A 实例使用生产迁移
包回到 B/native，marker 不能绕过 gate。不要手工修改只读 `vm.conf`。

## 共同的 host backing resource

启动器先选择 host 资源，再应用 guest identity：

- 当前 RTX 2080 基线分配 `nvidia-257 / 2048 MB`；
- `VGPU_RESOURCE_PROFILE`、`VGPU_RESOURCE_FB_MB` 描述实际资源；
- `GPU_PROFILE`、`GPU_NAME`、`VGPU_IDENTITY_TARGET` 和 `SPOOF_MODE` 描述 guest
  身份策略；
- host `nvidia-smi vgpu` 的 `vGPU Name` 仍可能显示 GT 1030/type 标签；
- 消费卡名称、PCI tuple 和 NVIDIA internal tuple 都不会改变实际 CUDA 核心数、频率、
  总线宽度、显存调度份额或物理 GPU。

因此严格 A 的目标是让 guest PnP、GPU-Z 和普通身份查询得到一致的 GTX 1050 tuple，
不能将其描述成 backing 硬件已经变成真实 GP107。GPU-Z 的部分底层规格仍可能来自
真实 vGPU/物理路径。

## off：原生安装与恢复身份

```bash
./deploy/scripts/start-vm.sh 2 --no-spoof --no-monitor-sync
```

off 使用原生 GRID PCI 身份：

```text
1GB/1Q: 10DE:1E30 / SUBSYS_132510DE
2GB/2Q: 10DE:1E30 / SUBSYS_132610DE
```

它适合安装原版 GRID 538.33、排查 Code 28/43，以及从严格身份安全恢复。off 启动会
移除该 UUID 的 per-mdev marketing/internal identity；即使配置持久化了
`VGPU_MDEV_FRL_ENABLED=0`，本次 off 启动也不会应用该 FRL override。

## B：通用 name-only 身份

```bash
./deploy/scripts/start-vm.sh 2 --spoof-name-only
```

B 保留原生 `10DE:1E30` 和原版 GRID driver；1GB/1Q 使用
`SUBSYS_132510DE`，2GB/2Q 使用 `SUBSYS_132610DE`。host 在创建 mdev
时按稳定 VM UUID 提供 `vm.conf` 的 `GPU_NAME`。它是所有 profile 的 driver-safe
路径，也是 GTX 750 Ti、GT 1030 的最终模式。

B 的明确边界是：

- Device Manager/WMI/控制面板可显示配置中的 marketing name；
- PCI config space 仍是 `DEV_1E30`，GPU-Z 等 PCI 查询不会得到消费卡 device ID；
- 原版 driver 签名链保持不变；
- 核心数、时钟、显存类型与总线宽度仍来自 backing vGPU；
- B/off 按原生 vGPU 授权合同验收，token/DLS 正常时 host 应为 `Licensed`。

## legacy GTX 1050 严格 A（禁用）

严格 GTX 1050 同时对齐四层信息：

| 层 | 已审计值 | 验收位置 |
|---|---|---|
| host resource | `nvidia-257 / 2048 MB` | sysfs、host 启动摘要 |
| QEMU 外部 PCI | `10DE:1C81`，subvendor `1028`，subdevice `11C0` | Windows PnP/GPU-Z |
| NVIDIA internal | `pci_id=0x1C8111C0`、`pci_device_id=0x1C81` | vGPU manager `Virtual Device Id` |
| guest driver | 修改 INF/自签 538.33，不符合当前生产签名要求 | legacy 记录 |

Windows PnP 的精确目标为：

```text
PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028
```

这里 `SUBSYS_11C01028` 由 subdevice `11C0` 与 subvendor `1028` 按 Windows 顺序
拼接。不能写成 `1028:11C0` 以外的厂商 tuple，也不能只改外部 PCI 而遗漏 NVIDIA
internal identity。

历史实验曾写入：

```text
VGPU_IDENTITY_TARGET=full-consumer
SPOOF_MODE=A
VGPU_MDEV_INTERNAL_PCI_IDENTITY=1
VGPU_MDEV_FRL_ENABLED=0
VGPU_PATCHED_DRIVER_VERSION=31.0.15.3833
```

这些字段当前不会由收尾脚本写入。不要从 VM3 或历史 `oemN.inf` 复制。

## strict-A 当前禁用

GTX1050 历史推进路径会修改 INF、重建 catalog 并使用 VM 本地自签证书，现已在
生成 guest 包、启动 VM 或写 marker 前硬拒绝。不要恢复旧 ZIP、导入私有根或手工
持久化 A/internal/FRL。当前 25 条 profile 的受支持策略均为 B。VM3 的 legacy A 已通过
生产迁移回执提交为 B/native，并完成 Code 0、WHCP signer 和 GPU-Z 验收；尚未
迁移的其他旧 A 实例仍由启动和封装门禁隔离。

未来只有同时取得以下证据，才能设计只做验证、不改 INF/不重签的 strict-A
transition：驱动精确匹配 `DEV_1C81&SUBSYS_11C01028`、INF/CAT/SYS 保持原字节并
通过 NVIDIA/Microsoft 生产信任链，以及该安装 Section 已在当前 R535 mdev 上实测
Code 0、冷重启、显示输出与 vGPU 协议/授权均正常。只有“INF 中存在目标 ID”不够。

### 原版 desktop 537.58 候选（仅隔离实验，不得用于正式 VM）

host 缓存中审计到的原版 NVIDIA desktop 537.58 WHQL 包确实包含 Dell GTX 1050 的
精确 PnP 项：

```text
nvddig.inf: PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028 -> Section029
DriverVersion: 31.0.15.3758
Catalog: nv_disp.cat / Microsoft Windows Hardware Compatibility Publisher
```

但这个 `Section029` 是消费卡安装 Section，不是已验证 GRID 538.33 的 vGPU Section。
它没有 GRID Section 使用的 `nv_vgpu_sw_licensing_addreg`、`AdapterType=1`、
`GridLicensedFeatures=7` 和 `GridSupportQuadro=1` 契约。desktop SYS 中出现 VGX/vGPU
字符串、INF 复制部分 vGPU 文件，也不能证明 NVIDIA RM 会在当前 mdev 上 Code 0。
NVIDIA 的兼容矩阵保证的是正式 vGPU guest driver release 与 vGPU Manager 的组合，
不是同一 R535 分支中的任意 desktop driver。

因此 537.58 当前只属于“生产签名和 PnP 匹配通过、mdev 运行兼容性未证明”的实验
候选。不得直接安装到 VM3/VM9，不得据此解除启动器 strict-A gate。若继续研究，必须
使用独立磁盘的可丢弃克隆，依次证明原生 `1E30` 基线、外部/内部身份一致切换、Code 0、
1920x1080、guest/host 状态、生产签名和多次冷启动；任一步失败都只丢弃克隆。

### 为什么 V-11 不能补上这个缺口

V-11 当前物理显示设备是 `1AF4:1050` virtio-gpu，绑定 stock Microsoft-WHQL
`VioGpuDod`；NVIDIA/AMD 型号和 HardwareID 首项属于用户态投影，PCI config、BDF、
Service 与 MatchingDeviceId 仍是 virtio。V-11 历史上把主 PCI 改成 NVIDIA 的路径
同样需要修改/自签 VioGpu 驱动，现已 fail-closed。

G-11 的 VFIO `x-pci-vendor-id/device-id/sub-*` 和 per-mdev internal identity 已经是
底层实现，缺的不是 QEMU 属性。缺口是一个同时满足目标消费卡 PnP、当前 NVIDIA mdev
初始化和生产签名的 guest 驱动契约。V-11 的 virtio EDID 通过
`VIRTIO_GPU_CMD_GET_EDID` 返回；NVIDIA R535 mdev 不提供 VFIO EDID region，所以这条
live EDID 通道也不能移植给 G-11 的 NVIDIA devnode。

## License 与 FRL 是两个状态

| 路径 | License 验收 | FRL 验收 |
|---|---|---|
| off/B | token/DLS 正常时应为 `Licensed` | 按原生 vGPU profile/license 合同 |
| legacy GTX1050 严格 A（禁用） | 历史记录为 `Unlicensed` | 历史记录为 `N/A` |

严格消费身份下 NVIDIA 控制面板授权页会消失；这不等于“已经激活”。同样，
`frl_enabled=0` 只关闭该 UUID 的 frame-rate limiter，不会把 `Unlicensed` 改成
`Licensed`，也不会授予 license。状态页必须分别显示 license 与 FRL。

VM3 动态画面已经证明不再固定于 3 FPS，但这不等于保证 60 FPS。默认 fixed 模式下
静止 REGION 桌面常见 `Content 0/s | Present 60/s (fixed)`；RDP 编码帧率也不能
用于 FRL 验收。

## 验收

Guest 管理员 PowerShell：

```powershell
$gpu = Get-CimInstance Win32_VideoController |
  Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' } |
  Select-Object -First 1
$gpu | Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,AdapterRAM
```

Host：

```bash
nvidia-smi vgpu -q
journalctl -b -u nvidia-vgpu-mgr -u nvidia-vgpud --no-pager | \
  rg 'Virtual Device Id|Patching|frl_enabled|1c81'
```

模式化预期：

- off：PnP 为原生 `DEV_1E30`，用于安装/恢复；
- B：PnP 仍为 `DEV_1E30`，marketing name 等于配置，driver 538.33/Code 0，并按
  原生合同验收 Licensed；
- legacy GTX1050 A（禁用）：历史名称为 `NVIDIA GeForce GTX 1050`，PnP 精确为
  `DEV_1C81&SUBSYS_11C01028`，driver `31.0.15.3833`、Code 0、约 2 GB；host
  backing label 可仍为 GT 1030，license/FRL 如实为 `Unlicensed / N/A`。

最终 GPU、分辨率和动态画面必须在 native SDL/GTK 会话验收。RDP 会创建 Microsoft
Remote Display Adapter，其设备数量、动态分辨率与编码 FPS 不能作为硬件身份证据。

## 回退

严格身份出现 Basic Display Adapter、Code 28/43、黑屏或分辨率减少时，完整关机后
执行：

```bash
./deploy/scripts/start-vm.sh <vm_id> --no-spoof --no-monitor-sync
```

不要自动卸载设备或删除现有 `oemN.inf`，避免让 VM 失去显示。先在原生
`DEV_1E30` 路径安装并确认未经修改、具有 NVIDIA/Microsoft 生产签名的
538.33/Code 0，再保持 B；不要重跑 strict 收尾。

完整驱动流程见 [DRIVER-INSTALL.md](DRIVER-INSTALL.md)，一键操作与恢复见
[VGPU-RECOVERY-RUNBOOK.md](VGPU-RECOVERY-RUNBOOK.md)，授权/FRL 语义见
[VGPU-LICENSING.md](VGPU-LICENSING.md)。
