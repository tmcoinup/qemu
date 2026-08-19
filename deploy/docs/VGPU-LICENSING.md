# Windows vGPU 授权、统一收尾、FRL 与 legacy 严格身份

本文说明 token/DLS、统一私有 `VgpuPortable.exe`、legacy
`finish-vgpu-install.sh` 和 frame-rate limiter（FRL）之间的关系。最重要的边界是：

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

全部 25 条 profile 当前都使用 B，并继续按原生 DLS `Licensed` 合同验收。不要把 VM3
历史 strict-A 的结果扩展成当前或未来生产结论。

## 当前统一一键收尾

### “管理许可证”到底由哪个脚本安装

底层 guest 安装器是 `deploy/guest/install-vgpu-license.ps1`，但当前成品流程不让用户
单独复制或手工调用它。`package-vgpu-one-click.sh --with-license-token` 会把该脚本、
token、身份合同和校验值一起嵌入私有 `VgpuPortable.exe`；双击 EXE 后由它在 guest
本地事务调用安装器。独立的 host `deploy/install-vgpu-license.sh` 是需要 WinRM/guest
凭据的兼容入口，不是当前 VM9 的推荐步骤。

因此控制面板显示“管理许可证”时，当前动作仍是从普通 B/native 启动重新运行同一个
私有 `VgpuPortable.exe`，不是填写旧式主/次服务器字段，也不是运行型号专用 finish。

GT 730、GT 740、GTX 750、GTX 750 Ti、GT 1030、GTX 1050 当前都保持 B/native，并使用同一个私有
`VgpuPortable.exe`。先在宿主构建：

```bash
cd /home/ubuntu/projects/qemu
chmod 600 /home/ubuntu/images/staging/client_configuration_token.tok
./deploy/package-vgpu-one-click.sh --with-license-token
```

默认输出：

```text
/home/ubuntu/images/staging/VgpuPortableLicensed/VgpuPortable.exe
```

也可使用仓库外的显式 token：

```bash
./deploy/package-vgpu-one-click.sh \
  --token-file /实际安全路径/client_configuration_token.tok
```

在目标 VM 中先安装未经修改、生产签名的 GRID 538.33，并确认 Code 0。必须从普通
B/native 启动进入 Windows，因为 EXE 要核对 `start-vm.sh` 发布的只读 firmware
claim；driver 安装专用的 `--no-spoof` 启动没有该 claim，不能在同一次启动里运行
portable 收尾。

把私有 EXE 安全复制进目标 Windows，双击并接受 UAC。它按如下顺序 fail-closed：

1. 核对 VM UUID、25 行 catalog、目标 profile、原生 `DEV_1E30`、538.33、Code 0、
   生产签名链、BCD 正常完整性策略和单 Display；
2. 安装型号/板卡/显存身份与权威查询器；
3. 使用已有的事务安装器原子安装 token；失败时恢复旧 token；
4. 重启 NVIDIA 服务，等待 `nvidia-smi -q` 明确出现
   `License Status : Licensed`；
5. 执行 `powercfg /hibernate off` 并写 `HiberbootEnabled=0`，复核
   `hiberfil.sys` 已不存在；
6. 应用推荐的 guest 登录启动/native-display 性能优化，并保存可回滚原状态；
7. 写 schema-4 回执，不记录 token 内容。

窗口必须同时显示性能优化 `APPLY PASS`、身份 `INSTALL PASS`、
`License: Licensed` 与 `Power: hibernation/Fast Startup disabled`。随后让 Windows 完整关机，等 QEMU
窗口自然退出，再普通冷启动验收。六个芯片型号没有不同命令，也没有每 VM 打包。

## 私有 EXE 的信任边界

默认无参数构建的 `VgpuPortable/VgpuPortable.exe` 不含 token，负责身份/查询和
推荐 guest 性能优化，可放进通用 base。`VgpuPortableLicensed/VgpuPortable.exe`
包含 DLS 凭据，只用于
受信任实际 VM：宿主固定权限 `0600`，token 必须位于仓库外、不是链接、大小为
`1024..1048576` 字节且不是 HTML。不要把私有 EXE 写入通用 base、提交仓库或公开
分发。

私有包把 token、授权安装器和 25 个 profile 全部写入同一 manifest，并在 PE 构建
前复核大小/哈希。token 文件存在或仍在有效期内，都不能替代正式生产签名驱动。
不得关闭 Secure Boot/HVCI、导入私有 Root/TrustedPublisher、修改 BCD 或重签
catalog。

同一 DLS 的受信任 VM 可共用同一私有 EXE；每个 B/off vGPU 实例仍独立申请、续期
并占用 lease，建议逐台执行和验收。完成后可从 guest 删除传入的私有 EXE；已安装的
NVIDIA token 位于其标准 `ClientConfigToken` 目录。

## `finish-vgpu-install.sh` 为什么仍存在

它现在只是统一前兼容入口：处理旧 GTX750Ti/GT1030 B VM 的历史 token 回执，以及
明确 `RTC_CONTRACT=utc` 实例在完整关机后的宿主离线 RTC 迁移。当前新建的全部
B/native VM 都不运行它。它对历史 GTX1050 strict-A 修改 INF/自签 catalog 的路径
继续在生成 guest 包、启动或写 marker 之前硬拒绝。

因此“750Ti/1030 要 finish、1050 不要”的差异只描述旧资产，不再是当前安装规则。

## 远端 DLS 和地址变化

`.tok` 不是只有一个“是否授权”开关；它还携带客户端实际要访问的 DLS
地址。因此 DLS 从旧 IP/域名迁移后，仅对新域名执行
`Test-NetConnection` 成功不足以证明当前 token 正确；旧 token 仍可能让 NVIDIA
客户端访问已废弃的地址。

当前现场 DLS 为 `dls.gvmates.com:443`。在受信任宿主上更新时，使用
正常 TLS 证书验证，不要加 `-k/--insecure`：

```bash
install -d -m 700 /home/ubuntu/images/staging
token_tmp=$(mktemp /home/ubuntu/images/staging/.client-token.XXXXXX)
curl --fail --silent --show-error \
  --proto '=https' --proto-redir '=https' \
  https://dls.gvmates.com/-/client-token -o "$token_tmp"
test "$(stat -c %s "$token_tmp")" -ge 1024
chmod 600 "$token_tmp"
mv -T "$token_tmp" \
  /home/ubuntu/images/staging/client_configuration_token.tok
```

token 是仓库外凭据。不要打印、解码或提交它；需要审计时只记录
大小和 SHA-256。若已有不同 token 绑定的私有包，打包器会拒绝静默
覆盖。确认是 DLS/token 轮换时，改用显式替换入口：

```bash
./deploy/package-vgpu-one-click.sh \
  --with-license-token --replace-licensed
```

封装会先验证旧 EXE 的受信回执，再把旧 EXE/内嵌 token 目录保留到
`/home/ubuntu/images/staging/package-backups/VgpuPortableLicensed.old.*`，该树固定为
`0700/0600`，不会覆盖以前的备份。旧输出没有受信回执或路径不安全时，
`--replace-licensed` 也会拒绝继续。
新 token 不会追溯改写旧 `VgpuPortable.exe`；必须把新建的私有 EXE
重新传入 guest 并运行。无授权的通用
`VgpuPortable/VgpuPortable.exe` 也不会安装 token。

故障时同时看“当前网络”和“NVIDIA 实际访问的地址”。Guest
管理员 PowerShell 可先验证新端点：

```powershell
Test-NetConnection dls.gvmates.com -Port 443
```

若返回 `TcpTestSucceeded : True` 但仍是 `Unlicensed`，查看
`C:\Program Files\NVIDIA Corporation\vGPU Licensing\Log` 下最新客户端日志。
日志若显示 `Failed to acquire license from <旧地址>`，就是旧 token/旧私有
EXE，不是新 DLS 的 443 网络故障。

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
`fix-rtc-utc.ps1`。当前新 VM 已是 `RTC_CONTRACT=localtime`，私有 portable 只验证
Windows 时区/RTC 合同，不需要宿主 RTC 提交。明确标记 `RTC_CONTRACT=utc` 的统一前
旧 VM 才走兼容入口；Windows 完整关机后，由宿主备份 SYSTEM hive、离线删除旧
DWORD，并写回 `RTC_CONTRACT=localtime`。

若出现 `Clock windback has been detected`，先核对 host localtime 合同、Windows
`China Standard Time` 和真实 UTC，再处理明确的旧 RTC 标记；不要反复更换 token，
也不要为迁移 RTC 绕过签名 guard。时间正确仍是 Windows、证书和 token 的必要条件。

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
