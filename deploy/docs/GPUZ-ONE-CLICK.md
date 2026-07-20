# G-11 离线显卡身份包：基础镜像与任意 VM 克隆

当前推荐产物是一个真正不绑定 VM 的离线文件：

```text
/home/ubuntu/images/staging/VgpuPortable/VgpuPortable.exe
```

它同时内嵌已经审计的 GTX 750 Ti、GT 1030、GTX 1050 三套 profile，不包含
VM ID、VM UUID，也不依赖 HTTP、网络共享、WinRM 或 guest 下载。可把同一个
`VgpuPortable.exe` 放入 Windows 基础镜像，之后克隆 VM4、VM5、VM6、VM456 或
其他支持范围内的任意编号，不再为每台 VM 重新生成 EXE。

这仍不是让用户任意选择显卡型号的改名器。每次 B/native 启动时，
`start-vm.sh` 会根据该 VM 的只读配置自动发布一条 SMBIOS Type 11 声明，包含
profile、该次 VM UUID、catalog 哈希、原生 PnP tuple 和驱动版本。EXE 在 guest
内只接受恰好一条完整声明，核对当前 SMBIOS UUID、`DEV_1E30`、538.33、Code 0、
生产签名链、BCD 和单 Display 拓扑后才选择对应 profile。缺少、重复、篡改或互相
不一致都会 fail-closed。A/off 启动不发布该声明。

## 最短三条宿主命令

```bash
cd /home/ubuntu/projects/qemu
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh
./deploy/clone-vgpu-base.sh 456 --gpu-profile gtx1050_2gb --start
```

第一条生成无 VM 绑定的离线 EXE；第二条只需在制作基础镜像时执行一次；第三条
创建 B/native 配置、从已准备的基础镜像克隆独立系统盘，并可立即启动。进入
Windows 后双击公共桌面的 `VgpuPortable.exe`，等待：

```text
[GPU-Z profile] INSTALL PASS
```

对于这个正常的 B/native 基础镜像/克隆流程，guest 成功安装后**不需要关机，也
不需要再运行任何人工 host commit**。宿主每次正常运行 `start-vm.sh` 时自动注入
只读声明；它不是额外的现场步骤。

## 一次性准备基础镜像

基础镜像必须已经满足：

- standalone qcow2，无 backing file 或外部 data file；
- Windows 已完整关机，NTFS 干净，未休眠、未启用会留下休眠状态的 Fast Startup；
- 原始 NVIDIA GRID 538.33 已正常绑定到 B/native `DEV_1E30`，设备 Code 0；
- DriverStore catalog 与当前加载的 `nvlddmkm.sys` 使用正常
  NVIDIA/Microsoft 生产签名链；
- 没有测试签名/自签名内核驱动，整个 BCD 中 `testsigning` 和
  `nointegritychecks` 均为 No 或未设置。

注入前必须停止所有 VM。`install-vgpu-portable-to-base.sh` 获取独占存储锁，并
拒绝被进程打开、被其他 qcow2 依赖或无法验证的 base。它不会直接挂载、修改正在
使用的 base，而是：

1. 把 base 复制/克隆到同目录私有临时 qcow2；
2. 先只读检查 Windows 分区，再以安全的 NTFS 读写方式挂载临时副本；
3. 写入并复验
   `C:\Users\Public\Desktop\VgpuPortable.exe`；
4. 卸载、断开 NBD、执行 `qemu-img check`；
5. 归档旧 base 后原子替换，并写入 portable attestation sidecar。

检测到 dirty/hibernated NTFS、活动持有者、存储依赖或哈希不一致时会在发布前
退出。不要用 `remove_hiberfile`、强制挂载或手工 NBD 写盘绕过门禁。

使用非默认路径时：

```bash
./deploy/package-vgpu-one-click.sh --portable \
  --output-exe /srv/private/VgpuPortable.exe

sudo ./deploy/install-vgpu-portable-to-base.sh \
  --base /srv/images/win10-base.qcow2 \
  --exe /srv/private/VgpuPortable.exe
```

`--yes` 只跳过最后一次替换确认，不会跳过停机、NTFS、qcow2、哈希或回执检查。

## 从基础镜像克隆

```bash
./deploy/clone-vgpu-base.sh 456 \
  --gpu-profile gtx1050_2gb \
  --start
```

支持的 profile：

| profile | Windows / GPU-Z 目标名称 | 当前合同 |
|---|---|---|
| `gtx750ti_2gb` | NVIDIA GeForce GTX 750 Ti | 2 GB / GDDR5 / Samsung |
| `gt1030_2gb` | NVIDIA GeForce GT 1030 | 2 GB / GDDR5 / Samsung |
| `gtx1050_2gb` | NVIDIA GeForce GTX 1050 | 2 GB / GDDR5 / Samsung |

`clone-vgpu-base.sh` 会拒绝已存在的 VM ID，验证 base 自 portable 注入后未发生
变化，调用 `create-vm.sh` 生成新的 UUID/B 配置，再以 `--from-base` 创建独立
qcow2。可同时传递 `--platform`、`--ssd-profile`、`--monitor-profile`。不带
`--start` 时只创建，之后正常运行：

```bash
./deploy/start-vm.sh 456
```

新增显卡型号不能靠改显示名称或复制现有 profile。应先在统一
`deploy/lib/vgpu-profiles.sh` catalog 中锁定并审计 PCI、显存、时钟和 NVAPI
字段，重新构建 portable EXE和基础镜像，再用锁定的 538.33 + GPU-Z 2.70 组合
实机验证；不为 VM 编号增加专用文件或代码分支。

## Guest 内做了什么

portable 包只做用户态 GPU-Z/application-local 身份层安装和验收：

- 内嵌并锁定 TechPowerUp GPU-Z 2.70；
- 在受保护的
  `C:\ProgramData\QemuGpuZProfile\applications\<版本-哈希>\`
  发布 GPU-Z、app-local NVAPI shim 和原始 NVIDIA NVAPI；
- 创建 `GPU-Z (vGPU profile)` 公共桌面快捷方式和受保护的启动刷新任务；
- 通过 DriverStore 的实际 `oemN.inf` 反查 catalog，不固定任何 `oemN.inf`
  编号；
- 安装前后复核单 Display、PCI 父节点、Code 0、驱动版本、生产签名链和 BCD；
- 不写 BCD，不安装、替换、重签或清理显示驱动，不替换 System32/SysWOW64
  NVAPI DLL，不安装测试签名/自签名内核驱动。

GPU-Z 2.70 只在自身进程内看到 catalog 对应的 consumer PCI tuple 和规格；系统
PnP 仍是原生 vGPU `10DE:1E30 / SUBSYS_132610DE`，这样才能继续使用未经修改的
NVIDIA/Microsoft 生产签名驱动。设备树中的 PCI bridge 是父设备，不是第二张
显卡；验收只允许一个 present Display adapter。

锁定的 GPU-Z 文件 SHA-256 为：

```text
6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29
```

TMU/Texture Fillrate 等私有查询只对当前锁定的 GRID 538.33 + GPU-Z 2.70 调用
布局通过测试。更换 GPU-Z 或驱动版本必须重新审计。

## 签名边界

需要“真实 NVIDIA/Microsoft 签名”的对象是实际显示驱动：DriverStore catalog、
加载中的 `nvlddmkm.sys` 及其链。软件会拒绝私有 Root、self-issued catalog、
`IsSigned=false`、测试模式和完整性旁路；不会只修改设备属性中的“签名者”文字。

外层 `VgpuPortable.exe` 和 app-local shim 当前是仓库构建的未签名**用户态**
产物，不是内核驱动。UAC 因此可能显示“未知发布者”，这不改变设备属性中驱动应为
Microsoft WHCP signer 的要求。若目标 WDAC/AppLocker/UMCI 禁止未签名用户态
EXE、脚本或 DLL，应建立正常受信的用户态代码签名/允许规则；不能用
`testsigning`、`nointegritychecks` 或自签内核证书绕过。

## HWiNFO 当前边界

portable 主流程当前只对内嵌的 **GPU-Z 2.70 x86** 做了端到端锁定和验收。
HWiNFO 64 会从 x64 NVAPI、内核 PCI/vGPU 拓扑及其他接口交叉读取，所以可能继续
显示 `[FAKE] NVIDIA GRID Quadro RTX6000-2Q`、`TU104` 或底层 Quadro 信息。这个
结果不表示系统出现了第二张显卡，也不能用简单改字符串解决。

本包不会扫描或修改任意 HWiNFO 安装目录，不会全局替换 `nvapi64.dll`，也不把
HWiNFO 当作 portable 的已支持验收工具。仓库另有
[HWiNFO64 app-local 实验适配](HWINFO-APP-LOCAL-EXPERIMENT.md)，只允许用户明确
指定正常签名、版本可审计的 `HWiNFO64.exe`，并离线放置 x64 app-local shim；
它不随 portable 自动安装，且不能承诺 `[FAKE]`、TU104 或所有字段消失。正式主线
仍以设备管理器、实际驱动签名链和包内 GPU-Z 2.70 为当前验收范围。

## 旧 A → B 迁移兼容流程

历史 `SPOOF_MODE=A` 实例不是 portable 主流程。A 使用过修改 INF/自签 catalog，
必须按 VM/UUID 绑定，避免把一次迁移回执应用到另一块磁盘或配置：

```bash
./deploy/package-vgpu-one-click.sh 3
# Windows 只运行生成的 VgpuProductionMigration.exe，等待完整关机
sudo ./deploy/commit-vgpu-production-migration.sh 3
./deploy/start-vm.sh 3
```

这个带 `VM_ID` 的调用仅为 legacy 兼容：A 生成按 VM 绑定的完整生产驱动迁移
EXE；B 会生成旧的按 VM 绑定 GPU-Z 包。新建 B/native VM、基础镜像和克隆一律
使用不带参数的 portable 入口。不要把 legacy 的关机/host commit 套到正常
portable clone 上。

## 验收与排错

管理员 PowerShell：

```powershell
Get-CimInstance Win32_VideoController |
  Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,
    CurrentHorizontalResolution,CurrentVerticalResolution

Get-CimInstance Win32_PnPSignedDriver |
  Where-Object DeviceClass -eq DISPLAY |
  Format-List DeviceName,InfName,DriverVersion,Signer,IsSigned

bcdedit /enum all | Select-String 'testsigning|nointegritychecks'
```

预期只有一张目标 NVIDIA Display，Code 0，驱动 `31.0.15.3833`，签名者为
`Microsoft Windows Hardware Compatibility Publisher`；BCD 查询应无启用项。
GPU-Z 2.70 应显示配置型号、2 GB、对应显存/位宽/时钟和 WHQL，下拉框只有一项。

| 现象 | 正确处理 |
|---|---|
| portable 报 claim missing/duplicate/mismatch | 确认以持久 B 配置正常运行 `start-vm.sh`；A/off、旧启动进程或手工启动 QEMU 不会有合格声明 |
| Code 43 且分辨率变小 | 先修复 host/guest vGPU branch 与原始 538.33 驱动绑定；身份包不能掩盖驱动故障 |
| 检出两个 Display | 退出会创建 Remote Display Adapter 的 RDP 会话，从本地 QEMU/fb-shm 画面冷启动复核 |
| base 注入拒绝 storage lock | 停止全部 VM 和其他存储操作，不要强制绕过 |
| base 注入拒绝 dirty/hibernated NTFS | 正常启动 Windows、关闭 Fast Startup、执行完整关机后重试 |
| clone 报 base changed/no attestation | 重新运行安全注入脚本；不要手改 sidecar |
| GPU-Z 出现 Unknown | 使用包内锁定的 2.70，核对 B claim、Code 0、538.33 和 catalog 是否已有该型号 |

失败时保留第一条 `FAIL:` 和
`C:\ProgramData\QemuGpuZProfile\backups` 下的只读记录。不要反复复制 DLL、手改
claim/JSON/marker、导入私有证书或执行任何 `bcdedit /set`。
