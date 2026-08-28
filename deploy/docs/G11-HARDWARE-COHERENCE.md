# G-11 全配置现实一致性：公共层修复与傻瓜验收

本页只适用于 **G-11/vGPU**。V-11 是独立分支，不要互拷脚本、QEMU 二进制或
guest 包。

> 2026-08-21：正常新建已切到两款 4C/8T Core i7 + 三品牌 X79 +
> 4/8/12/16G。本文保留的 H81/i3 截图与逐项分析只用于解释 archived 旧 VM；当前
> 数量、选择与 NVMe 规则以 [G11-HARDWARE-POOL.md](G11-HARDWARE-POOL.md) 为准。
> 2026-08-27：i7-4930K 6C/12T 已进入普通创建池，覆盖三品牌 X79、每容量
> 4–5 个内存品牌；普通新建 102 条，活跃 X79 合计 102 条。

## 结论

本轮没有针对鲁大师的进程名、安装目录或 exe 做适配。鲁大师、GPU-Z、HWiNFO、
设备管理器等都只是验收工具；仓库中不存在鲁大师专用 DLL、安装器或打包器。

公共层现在同时约束 CPU、主板和显卡读取路径，并保留一项如实审计：

| 层 | 处理 | 覆盖 |
|---|---|---:|
| QEMU 00:00.0 CPU DMI2 inventory | 按 CPU 目录在 UEFI 退出后呈现 Sandy/Ivy Bridge-E DMI2 | 102/102 个 X79 平台 |
| QEMU 00:1f.0 LPC inventory | 主板目录选择 X79/H81/H97/B150/B360 身份 | 366/366 个平台 |
| G-11 系统 NVAPI | 同一 VM 合同供所有 32/64 位 NVAPI 调用者使用 | 25/25 个 GPU profile |
| GPU 能力目录 | 六个消费卡 device ID 都显式要求目标 DXR tier 0、NVAPI RT core 0、Tensor core 0 | 6/6 个 device ID |
| 原生 D3D12 审计 | 安装写入前和最终验收均直接查 OPTIONS5；查询失败阻断，签名 transport 能力差异警告 | x86 + x64 |

截图中的 `Gigabyte GA-H81M-S1 + i3-4130 + GTX 750` 现在属于 archived 旧配置，
仍适用同一条公共读取路径，但不能用于新建。

## 主板 PCH 为什么以前都显示 ICH9

G-11 使用 QEMU q35；上游 q35 的 LPC 设备固定为 ICH9 `8086:2918`。此前主板
SMBIOS 虽然会变化，00:1f.0 的 PCI identity 没有变化，所以检测软件换多少款
主板都会把同一个 ICH9 拼在型号后面。

现在 `start-vm.sh` 从主板目录取得一个受审核的 `x-g11-chipset` 值，由 QEMU
设备模型在 realize 阶段选择：

| 主板目录芯片组 | 来宾 00:1f.0 LPC | revision | 平台数量 |
|---|---|---:|---:|
| X79 | `8086:1D41` | `06` | 102 |
| H81 | `8086:8C5C` | `04` | 261 |
| H97 | `8086:8CC6` | `00` | 1 |
| B150 | `8086:A148` | `31` | 1 |
| B360 | `8086:A308` | `10` | 1 |

目录外的字符串会被 QEMU 拒绝，不能从 `vm.conf` 或环境变量注入任意 PCI ID。
只改变 LPC inventory；q35/ICH9 的 ACPI、IRQ 和 machine 行为不变，SATA 仍是
ICH9-AHCI，USB 仍是 `qemu-xhci`。这避免 Windows 为虚拟 SATA/USB 控制器加载
实体 PCH 专用 quirks。

## X79 的 CPU 侧 DMI2 怎样通用呈现

X79 平台不只需要 00:1f.0 的 Patsburg/X79 LPC，还需要与 CPU 代际一致的
00:00.0 DMI2 host bridge。当前 102 个正常 X79 组合全部从 CPU 目录取得固定映射，
不读取 VM ID，也不检测验收软件：

| CPU 目录 | Windows 看到的 00:00.0 | revision | subsystem |
|---|---|---:|---|
| Core i7-3820 / Sandy Bridge-E | `8086:3C00` | `07` | `8086:3C00` |
| Core i7-4820K / Ivy Bridge-E | `8086:0E00` | `04` | `8086:0E00` |
| Core i7-4930K / Ivy Bridge-E | `8086:0E00` | `04` | `8086:0E00` |

QEMU 的功能模型仍然是 q35。OVMF 在 PEI/DXE 阶段必须看到原生 P35 MCH
`8086:29C0`，否则固件不能按现有 q35 路径可靠建立 PCI host bridge。随仓库封装的
OVMF 在 `ExitBootServices` 发出私有且固定的 APM `0x47` 通知；只有启用了已审核
`x-g11-host-bridge` 白名单的同一个 00:00.0 才在此时切换到对应 DMI2 identity。
此时固件已结束 PCI 初始化，Windows 还没有开始枚举。系统复位会先恢复
`8086:29C0` 与主板 subsystem，下一次退出固件时再切换，因而冷启动和重启走同一
状态机。

该处理只改 guest 可见的 PCI vendor/device/revision/subsystem，不声称 q35 的内部
实现变成了实体 X79，也不为 archived 的非 X79 CPU 猜测 host bridge ID。目录外的
CPU 代际会失败关闭。OVMF 构建器会同时生成 hash 绑定的 `.features` 清单；启动器在
分配 VM 资源前核对固件确实包含同版本交接能力，旧固件或被替换的自定义固件不会
静默退回 `29C0`。

## 鲁大师末尾横杠的深度复扫结论

VM3 只是验收机。使用鲁大师 `6.1026.4785.824` 明确点击“重新扫描”后，主板页仍会
显示 `X79 PCH -`；但同一次扫描的 `ComputerZ_HardwareDll.log` 已给出决定性链路：

```text
Northbridge name:Intel Ivytown DMI2
Name(DB)=X79 PCH - LPC Interface Controller
Southbridge name:X79 PCH -
```

Windows 同时枚举到 `VEN_8086&DEV_0E00&SUBSYS_0E008086&REV_04`，说明 CPU 侧 DMI2
已被检测器命中；00:1f.0 则是目录要求的真实 `8086:1D41 rev 06`。末尾横杠不是
QEMU 缺少北桥，也不是鲁大师缓存未刷新，而是鲁大师把自身数据库名称
`X79 PCH - LPC Interface Controller` 删除控制器后缀时，没有继续清理分隔符。

PCI 配置空间只提供数值身份，不提供鲁大师最终显示的中文名称，因此宿主公共层没有
一个可用于“删掉横杠”的标准字段。为了视觉效果改成另一枚 LPC ID、修改鲁大师
数据库/DLL、注入进程或增加假设备，都会把应用特例或错误硬件引入所有 VM；本分支
明确不这样做。验收时应把 `X79 PCH -` 记为该版本鲁大师的已知显示缺陷，并以
00:00.0、00:1f.0 的 PnP ID 和交叉工具结果判断底层身份。

## 旧显卡能力怎样统一处理

当前目录只有 GT 730、GT 740、GTX 750、GTX 750 Ti、GT 1030 和 GTX 1050。
六个型号、全部 25 条板卡/显存组合都绑定同一类能力合同：

```text
expected D3D12 raytracing tier = 0
NVAPI ray tracing cores        = 0
NVAPI tensor cores             = 0
```

新增显卡若没有唯一能力行，目录校验、打包和启动前检查会失败关闭。系统包 schema 4
把能力值与型号、Subsystem、显存、时钟及 VM UUID 一起签入内容摘要。安装后，系统
搜索路径中的 x86/x64 NVAPI 转发层都从这份原子合同返回 RT/Tensor `0/0`，不按
调用进程选择结果。`SystemNvapiProbe32.exe` 与 `SystemNvapiProbe64.exe` 会从
Windows 系统目录绝对加载 DLL，并把这两个值纳入 PASS 条件。包内另有
`D3D12CapabilityProbe32.exe` 与 `D3D12CapabilityProbe64.exe`，两者都必须能对
实际 NVIDIA adapter 查询 OPTIONS5；无法枚举/查询时在任何系统投影写入前拒绝
安装，签名 transport 返回非零 tier 时则如实警告并继续。

### 必须如实保留的 D3D12 边界

`ID3D12Device::CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5)` 的结果来自来宾
正在使用的 NVIDIA D3D12 用户态驱动和 vGPU transport。G-11 的生产路径为了保持
GRID 538.33 正式签名、Code 0 和稳定画面，仍保留原生 `10DE:1E30` transport。
系统 NVAPI 合同不会、也不应谎称它改写了 `ID3D12Device`。

因此：

- 不把 `d3d12.dll` 放进鲁大师或任何应用目录；
- 不替换 Windows 的系统 `d3d12.dll`，不注入未知进程；
- 不为伪造 PCI ID 修改/重签 GRID INF，不安装测试签名或自签名内核驱动；
- 跨代 M60 transport 的隔离实机候选已验证不合格，不进入生产目录。

若某工具重新扫描后仍因原生 D3D12 OPTIONS5 显示“光线追踪”，该 VM 的
**严格 D3D12 现实一致性审计失败**，但授权、唯一 Code-0 Display 和 x86/x64
NVAPI 合同仍可分别验收通过。此时应保留工具结果、`dxdiag`、设备 PnP 和系统包
验证日志；不能再用应用专用代理把它伪装成通过。

### 2026-08-18 实机资格结果

| 隔离对象 | 来宾 PCI 身份 | x86 OPTIONS5 | x64 OPTIONS5 | 结果 |
|---|---|---:|---:|---|
| VM8 生产 transport | `10DE:1E30` | tier 0 | tier 11（DXR 1.1） | 拒绝 |
| VM10 M60-1Q 候选 | `10DE:13F2 / SUBDEV_114D` | tier 0 | tier 11（DXR 1.1） | 拒绝 |

M60-1Q 候选在运行期没有 Code 43、Xid、黑屏，但 64 位 D3D12 仍暴露物理
Turing 能力，而且 guest 正常关机后 QEMU 退出码为 139。因此该候选已否决，
VM10 已停止、mdev 已移除，宿主 `profile_override.toml` 已恢复原摘要
`06b490be8fa1a8b08b2769ddc8fd132011826c62c5c2f71119525f4396ca9942`。
这证明仅更换 vGPU 市场名、PCI tuple 或 profile 代际不能修复本宿主的
64 位 DXR 能力不一致。

## 傻瓜操作

### 1. 更新并验证宿主 QEMU 与 OVMF

先让目标 VM 完整关机。下面以 VM3 为验收示例；换成任何合法 VM ID 都走相同目录
映射，没有 VM3 特判：

```bash
cd /home/ubuntu/projects/qemu
VM_ID=3
./deploy/scripts/vmctl.sh stop "$VM_ID"
./deploy/host/build-qemu.sh
./deploy/host/build-stealth-ovmf.sh
./deploy/scripts/check-hardware-pool.sh --machine-readable | \
  rg 'chipset_presentations|architecture_boundaries'
./deploy/tests/vgpu/test_chipset_presentation.sh
```

预期包含：

```text
chipset_presentations H81=8086:8C5C:04 H97=8086:8CC6:00 B150=8086:A148:31 B360=8086:A308:10 X79=8086:1D41:06 coverage=all-366-platforms
PASS: 366 G-11 platforms map LPC identities; all 102 X79 rows map UEFI-handoff CPU DMI2 identities
```

正常启动目标 VM：

```bash
VM_ID=3
./deploy/scripts/vmctl.sh start "$VM_ID"
```

启动摘要必须同时打印主板的 LPC identity 和 CPU DMI2 inventory。Windows 第一次
看到新的 PnP ID 时可能重新枚举设备；进入桌面后让 Windows 完整重启一次，再打开
检测工具。无需安装 guest 驱动，不改 BCD，也不需要测试签名。

### 2. 生成唯一的系统能力包

```bash
cd /home/ubuntu/projects/qemu
./deploy/guest/d3d12-capability-probe/build.sh
./deploy/guest/nvapi-shim/build.sh
./deploy/package-system-nvapi-projection.sh "$VM_ID"
```

默认输出位于：

```text
/home/ubuntu/images/vms/<VM_ID>/packages/SystemNvapiProjection/
```

将命令打印的 ISO 只读挂入它绑定的 VM：

```bash
./deploy/scripts/vmctl.sh cdrom "$VM_ID" mount /absolute/path/from-packager.iso --replace
```

Windows 一般在 2～5 秒内收到换盘事件；在“此电脑”按 `F5` 即可，不需要为看到 ISO
重启 Windows 或 VM。`Run-As-Administrator.cmd` 只是系统投影的安装入口，
不是挂载 ISO 必需步骤。它先运行原生 x86/x64 D3D12 审计：

- 两者都能枚举 NVIDIA adapter 并查询 OPTIONS5 时，会安装并自动重启；
- 任一路径无法查询时立即失败，不写入、不重启；非零 tier 会明确警告并继续。
  日志在 `C:\Windows\Temp\G11-System-NVAPI-Install.log`。

当前签名 transport 的 x64 实测 tier 11；自动流程会明确显示 WARNING 后继续，
不是 ISO 挂载故障。只有 `Run` 成功安装并重启后，才运行
`Verify-As-Administrator.cmd` 做手动复核。`Verify` 不是挂盘所必需，也不用于
安装 `VgpuPortable.exe`。

必须同时看到类似（`native_raytracing_nonzero` 可为 `yes`，此时另有 WARNING）：

```text
SYSTEM_NVAPI_VERIFY PASS architecture=x86 ... RT=0 Tensor=0 ...
SYSTEM_NVAPI_VERIFY PASS architecture=x64 ... RT=0 Tensor=0 ...
D3D12_NATIVE_VERIFY PASS ... native_raytracing_nonzero=no|yes   # x86
D3D12_NATIVE_VERIFY PASS ... native_raytracing_nonzero=no|yes   # x64
```

包不接收应用路径，不检测鲁大师进程，也不会向任何应用目录复制 DLL。
`VgpuPortable.exe` 是新装/base 阶段的独立兼容入口；挂载新 ISO、换光盘型号或
运行本系统包都不需要重新执行它。

### 3. 多工具交叉验收

先在设备管理器确认只有一个 present NVIDIA Display、Code 0、驱动
`31.0.15.3833` 且为 NVIDIA/Microsoft 正式签名。然后让每个检测工具执行
“重新扫描”，至少交叉检查两种不同来源：

- 鲁大师进入“硬件参数”后点击“重新扫描”，扫描完成再打开“主板”；仅切换页签不会
  刷新旧缓存；
- 主板型号应来自目录；X79 的底层应为 CPU DMI2 `3C00/0E00` 加 LPC `1D41`；
  鲁大师 `6.1026.4785.824` 可能仍显示 `X79 PCH -`，按上文已知显示缺陷处理；
- H81/H97/B150/B360 等 archived 旧配置仍应显示各自目录 LPC，不套用 X79 DMI2；
- 显卡型号、板卡厂商、1/2 GB、GDDR5、厂家、位宽、时钟必须来自同一个 profile；
- NVAPI RT core 与 Tensor core 都必须为 0；
- 不得出现第二块显卡、Code 43、Xid、TDR 或持续黑屏；
- 若任何工具仍显示光追，按上文 D3D12 边界记为“严格现实一致性未通过”，不能把
  NVAPI 的 PASS 描述成已经改变原生 D3D12。

X79 可在管理员 PowerShell 直接做数值验收，不依赖任何检测器的名称数据库：

```powershell
Get-PnpDevice -PresentOnly |
  Where-Object InstanceId -Match 'VEN_8086&DEV_(0E00|3C00|1D41)' |
  Select-Object Status, Class, FriendlyName, InstanceId
```

i7-4820K/i7-4930K 应同时出现 `DEV_0E00` 与 `DEV_1D41`；i7-3820 应同时出现 `DEV_3C00`
与 `DEV_1D41`，且状态为 `OK`。

硬件工具的缓存可能保留旧结果，所以“重新扫描”只是验收动作，不是实现依赖。

## 临时回退与完整回滚

旧 Windows 镜像若因新的 LPC PnP 枚举出现问题，可只对一次启动回退：

```bash
G11_CHIPSET_PRESENTATION=off ./deploy/scripts/start-vm.sh "$VM_ID"
```

这只恢复上游 ICH9 `8086:2918`，不改写 `vm.conf`，不要作为日常配置。

若只需回退 CPU 侧 DMI2，同样只影响本次启动：

```bash
G11_HOST_BRIDGE_PRESENTATION=off ./deploy/scripts/start-vm.sh "$VM_ID"
```

这会让 00:00.0 始终保持 q35/P35 MCH `8086:29C0`。两个开关都只接受
`catalog` 或 `off`，不能从环境变量注入任意 PCI ID。

系统 NVAPI 包需要回滚时，在原包中双击 `Rollback-As-Administrator.cmd`。它按
validated 收据恢复保存的 NVIDIA 正式签名原件，不删除未知文件。不要手工覆盖
System32/SysWOW64 文件。

## 开发者一次性全量回归

```bash
cd /home/ubuntu/projects/qemu
./deploy/tests/vgpu/test_chipset_presentation.sh
./deploy/tests/vgpu/test_vgpu_profile_catalog.sh
./deploy/tests/vgpu/test_d3d12_capability_probe.sh
./deploy/tests/vgpu/test_nvapi_identity_shim_static.sh
./deploy/tests/vgpu/test_system_nvapi_projection_package.sh
./deploy/tests/vgpu/test_hardware_pool_audit.sh
./deploy/tests/vgpu/test_root_hardware_semantics.sh
./deploy/tests/vgpu/test_root_start_vm_bootstrap.sh
```

这些检查覆盖全部 366 个平台、25 个 GPU profile、六个 GPU device ID、x86/x64
NVAPI 与原生 D3D12 探针，以及“LPC 不连带改 AHCI/xHCI、CPU DMI2 只能在
ExitBootServices 后交接且复位恢复”的架构边界。

整个流程不修改 BCD，不开启 `testsigning`/`nointegritychecks`，不安装或修改
INF/CAT/SYS，不导入证书，也不把宿主凭据写入仓库或包。

## 官方接口依据

- Intel 8 Series PCH datasheet：
  <https://www.intel.com/content/dam/www/public/us/en/documents/datasheets/8-series-chipset-pch-datasheet.pdf>
- Intel 9 Series PCH datasheet：
  <https://www.intel.com/content/dam/www/public/us/en/documents/datasheets/9-series-chipset-pch-datasheet.pdf>
- Intel 100 Series PCH datasheet, volume 1：
  <https://www.intel.com/content/www/us/en/content-details/332690/intel-100-series-chipset-family-platform-controller-hub-pch-datasheet-volume-1.html>
- Intel 300/C240 Series PCH datasheet, volume 1：
  <https://www.intel.com/content/www/us/en/content-details/337347/intel-300-series-and-intel-c240-series-family-pch-datasheet-vol-1.html>
- Microsoft `ID3D12Device::CheckFeatureSupport`：
  <https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-checkfeaturesupport>
- NVIDIA GTX DXR 支持范围说明：
  <https://www.nvidia.com/en-us/geforce/news/geforce-gtx-ray-tracing-coming-soon/>
- NVIDIA vGPU 16 产品支持矩阵：
  <https://docs.nvidia.com/vgpu/16.0/product-support-matrix/index.html>
