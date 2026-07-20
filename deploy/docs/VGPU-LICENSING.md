# Windows vGPU 授权、FRL 与 GTX 1050 严格身份

本文说明 token/DLS、`finish-vgpu-install.sh`、严格 GTX 1050 身份和 frame-rate
limiter（FRL）之间的关系。最重要的边界是：

> **当前状态：** 历史 GTX1050 strict-A driver 会修改 INF 并自签 catalog，相关
> finish transition 已运行时禁用。本文 strict-A/ZIP 内容仅作 legacy 解释；当前
> VM 必须保持 B，不能靠私有根、自签或测试模式恢复。

> NVIDIA 控制面板中的授权页消失，不等于“已经激活”；host 显示
> `Unlicensed` 也不能写成 `Licensed`。`Frame Rate Limit: N/A` 只说明当前
> per-mdev FRL 未启用，不会凭空授予 license。

驱动安装和 `DEV_1C81` 细节见
[`DRIVER-INSTALL.md`](DRIVER-INSTALL.md)，面向操作的短流程见
[`VGPU-RECOVERY-RUNBOOK.md`](VGPU-RECOVERY-RUNBOOK.md)。

## 两种验收合同

| 路径 | Guest PCI 身份 | Driver | 控制面板授权页 | host license 验收 | FRL |
|---|---|---|---|---|---|
| 通用 off/B | 原生 `DEV_1E30` | 原版 GRID 538.33 | 通常存在 | token/DLS 正常时应为 `Licensed` | 按 vGPU profile/license 合同 |
| legacy GTX1050 严格 A（禁用） | `DEV_1C81 / SUBSYS_11C01028` | 修改 INF/自签 538.33，不合规 | 历史记录 | 历史为 `Unlicensed` | 历史为 `N/A` |

三款 profile 当前都使用 B，并继续按原生 DLS `Licensed` 合同验收。不要把 VM3
历史 strict-A 的结果扩展成当前或未来生产结论。

## 一键收尾输出

Windows 已完整关机后，在宿主执行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/finish-vgpu-install.sh <vm_id>
```

### GTX 1050

脚本会在生成 guest 包、启动 VM 或写 `A/internal/FRL` marker 前拒绝。不要查找、
恢复或运行历史 GTX1050 ZIP；它修改 INF 并使用 VM 本地自签 catalog。GTX1050
保持 B，直到存在与目标 PnP tuple/版本匹配且未经修改的 NVIDIA/Microsoft 正式
生产签名驱动。

### 其他 GPU profile

其他 profile 继续使用通用收尾包和 B 模式。EXE 安装 token、关闭休眠并写完成 marker；
宿主不会为它们写 `A/internal=1/FRL=0`。启动后必须按原生 vGPU 合同验证
`License Status: Licensed`。

## 通用 B 模式 EXE 的信任边界

收尾包只用于当前项目中受信任的 VM。它包含或携带 DLS token，不能公开分发。宿主在
全局锁内按构建输入、token SHA-256 和输出 SHA-256 验证缓存；输入变化、包缺失或损坏
时才原子重建。

历史 GTX1050 ZIP、patched payload 和自签脚本已从 current staging 归档，不属于
通用 B 模式 EXE。不得关闭 Secure Boot/HVCI、导入私有 Root/TrustedPublisher、
修改 BCD 或重签 catalog 来恢复它。

完成 marker 是防止拿错 VM、profile、driver 或 token 的流程边界，不是对 guest
管理员的数字签名安全边界；guest 管理员本来就有能力修改系统和 token。

## token 选择与多 VM

默认 token 路径为：

```text
/home/ubuntu/images/staging/client_configuration_token.tok
```

文件不存在时，脚本可尝试从宿主本地 DLS 的
`https://127.0.0.1/-/client-token` 导出。也可显式指定：

```bash
./deploy/finish-vgpu-install.sh 3 \
  --token-file /实际路径/client_configuration_token.tok
```

同一 DLS 的受信任 VM 可共用同一 token；每个 B/off vGPU 实例仍会独立申请、续期并
占用 lease。多台 VM 应逐台运行收尾命令，不要并行处理同一个 staging bundle。

GTX 1050 当前不经过该 legacy 收尾入口；在 B/off 下单独按原生 vGPU 流程配置和
验收 token/license。token 文件存在或仍在有效期内，都不能替代正式签名驱动。

## 远端 DLS 和地址变化

远端 DLS 应在 DLS 服务器本地导出 token：

```bash
cd /path/to/fastapi-dls
./dlsctl.sh token /tmp/client_configuration_token.tok
```

没有该工具时，只在 DLS 服务器本机访问环回地址：

```bash
curl -kfsS https://127.0.0.1/-/client-token \
  -o /tmp/client_configuration_token.tok
chmod 600 /tmp/client_configuration_token.tok
```

再把文件安全传到 QEMU 宿主的默认 token 路径。不要手工编辑 `.tok`，也不要填写
NVIDIA 控制面板中的旧式“主服务器/次服务器”字段。B/off 模式运行时，NVIDIA 服务
仍必须能解析并通过 HTTPS 访问 token 内的 DLS 地址；建议使用稳定 DNS 名。

## 为什么授权页消失但仍是 Unlicensed

严格路径同时把 guest PCI tuple 和 NVIDIA 内部 vdev/pdev 对齐到消费卡
`DEV_1C81`。NVIDIA 控制面板据此把设备呈现为消费卡，不再显示 vGPU 授权页面。这是
界面/设备分类结果，不是 DLS 激活结果。

VM3 在 strict-A 历史实验中曾记录以下组合（已禁用，不是当前状态）：

```text
Guest: NVIDIA GeForce GTX 1050 / DEV_1C81 / 538.33 / Code 0
Host License Status: Unlicensed
Host Frame Rate Limit: N/A
```

因此文档、傻瓜软件和状态页必须分别显示 license 与 FRL，不能合并成“已激活”一个
绿色状态。当前 VM3 已迁移为 B/native、原生 `DEV_1E30` 和生产签名 538.33；
license 与 FRL 仍必须在宿主单独核验，不能从设备名称、GPU-Z WHQL 或历史结果推断。
需要正式 `Licensed` 状态时，应检查当前 token/DLS；历史严格消费卡路径不能同时
声称 host 已 Licensed。

## FRL 与帧率怎么验收

`VGPU_MDEV_FRL_ENABLED=0` 由启动器按稳定 VM UUID 写成 per-mdev
`frl_enabled=0`。它只改变该实例的 NVIDIA frame-rate limiter，不会修改共享
`[profile.nvidia-257]`，也不会改变物理 GPU 或 QEMU REGION 数据通路。

宿主检查：

```bash
nvidia-smi vgpu -q
```

legacy 严格 GTX 1050 实验曾同时记录：

```text
License Status: Unlicensed
Frame Rate Limit: N/A
```

历史 VM3 动态 `winsat d3d -time 10` 曾观测到多个高于 3 FPS 的区间，说明当时的 3 FPS
限制不再是当前瓶颈；这不是完整 GPU 跑分，也不保证 60 FPS。SDL 标题在静止桌面显示
`Present 0.0 FPS` 是 REGION 像素去重的正常结果，必须用持续变化的 native workload
判断。RDP 自己的编码帧率、RDPIDD 分辨率和动态缩放均不能作为 vGPU/FRL 验收数据。

## RTC 仍由宿主负责

启动器使用：

```text
TZ=Asia/Shanghai
-rtc base=localtime,clock=host,driftfix=slew
```

新装 Windows 不要写 `RealTimeIsUniversal=1`，也不要运行旧
`fix-rtc-utc.ps1`。明确标记 `RTC_CONTRACT=utc` 的旧 VM 会先用兼容契约进入救援；
EXE 关闭休眠后，宿主备份 SYSTEM hive、离线删除旧 DWORD，并写回
`RTC_CONTRACT=localtime`。

GTX750Ti/GT1030 的 B/off 若出现 `Clock windback has been detected`，应完整关机后
重跑 B 收尾完成 RTC 迁移，不要反复更换 token。GTX1050 strict finish 已禁用，
不要为迁移 RTC 绕过签名 guard；时间正确仍是 Windows、证书和 token 的必要条件。

## 模式化验收

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
```

- B/off：driver `31.0.15.3833`、Code 0、约 2 GB，并要求 `Licensed`；
- legacy GTX1050 严格 A（禁用）：历史名称为 GTX 1050、PnP 为
  `DEV_1C81&SUBSYS_11C01028`，host 记录为 `Unlicensed / FRL N/A`；不得作为当前
  验收合同；
- host 的 GT 1030/`nvidia-257` backing label 不作为 guest 身份失败条件；
- 任何模式都不能只根据控制面板是否出现授权菜单判断 license。
