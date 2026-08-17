# vGPU 原始签名驱动迁移（A → B）

本页仅适用于历史配置中 `SPOOF_MODE` 值为 `A` 的实例，因此迁移 EXE 和回执必须绑定 VM/UUID，
并在 guest 自动关机后做一次 host commit。新建 B/native VM、基础镜像与克隆不走
本页；它们使用无 VM 绑定的离线 `VgpuPortable.exe`，guest 安装后无需 host
commit，见 [GPUZ-ONE-CLICK.md](GPUZ-ONE-CLICK.md)。

这条流程同时满足：

- 设备管理器显示配置的消费卡名称，例如 `NVIDIA GeForce GTX 1050`；
- 当前加载的驱动来自未经修改的 NVIDIA GRID 538.33 包；
- active INF/catalog 是锁定的原始字节，驱动与 catalog 通过
  NVIDIA/Microsoft 公开生产签名链；
- `testsigning=No`、`nointegritychecks=No`，全程不写 BCD；
- GPU-Z 2.70 通过仅放在 GPU-Z 目录旁的 app-local profile 显示同一型号；
- Windows 最终只有一个 present Display，驱动 `31.0.15.3833`、Code 0。

VM3 已完成本流程并作为当前参考结果：设备管理器为 GTX 1050、Code 0、分辨率
1920×1080，active package 为 `oem2.inf`/`31.0.15.3833`，属性页数字签名者为
`Microsoft Windows Hardware Compatibility Publisher`；GPU-Z 2.70 显示 GTX 1050
和 WHQL；`testsigning`、`nointegritychecks` 均为关闭。生产驱动验收通过后，旧
自签 package、私有测试证书和一次性续跑任务均已移除。

## 为什么最终必须是 B/native

原始 GRID 538.33 的 `nvgridsw.inf` 包含 vGPU 原生 `DEV_1E30`，但不包含
GTX 1050 的 `DEV_1C81/SUBSYS_11C01028`。修改 INF 加入 `DEV_1C81` 会破坏
NVIDIA 原 catalog 的成员校验，只能重签，因此不可能继续保留原始生产签名链。

本方案保留 `DEV_1E30` 供官方驱动匹配。设备管理器名称由 Windows 设备名称缓存和
启动刷新设置为配置型号；GPU-Z 的名称与缺失规格由 app-local NVAPI profile 提供。
它们都不修改 INF、catalog、`nvlddmkm.sys` 或系统 NVAPI DLL。设备属性页的
“数字签名者”来自实际 active driver package，不是修改出来的文字。

## 迁移前准备

1. Windows guest 不需要预装 GPU-Z。宿主默认从
   `$IMAGE_ROOT/candidates/gpuz-2.70-audit/GPU-Z.2.70.0.exe` 读取并嵌入标准
   TechPowerUp 2.70.0；其大小必须为 `11642144`，SHA-256 必须为
   `6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29`。
   Windows 系统盘需至少 `4 GiB` 可用空间，用于校验后临时展开原始驱动包，并会
   在受保护的 ProgramData application 目录保留约 12 MiB 的 GPU-Z/app-local
   文件。
2. 宿主存在锁定的原始 archive：
   `/home/ubuntu/images/staging/553.24-display-driver.zip`。文件名是历史兼容名，
   内容必须是 GRID 538.33，大小 `860703853`，SHA-256：

   ```text
   A3D7AD8B8082D6AC6214565B4766B5190A819BC9B7574765B14897E0DB809690
   ```

3. 不要在 RDP 会话中做最终验收。Remote Display Adapter 会使“一张显示卡”检查
   按设计失败。
4. 不需要购买证书。这里使用 NVIDIA 包中已经存在的生产签名。
   本地生成的迁移 EXE 只是未签名的用户态封装，UAC 可能显示“未知发布者”；
   它不进入内核信任链，也不改变设备属性中的 driver signer。最终设备签名信息只取自
   active 的 NVIDIA/Microsoft 原始包。

## Code 43 和低分辨率

这两个现象同时出现时，先看宿主 `nvidia-vgpu-mgr`，不要继续安装“最新版”驱动。
VM3 在 2026-07-19 的现场记录为 guest `582.42`、host `535.161.05`，管理器明确报：

```text
Incompatible Guest/Host drivers: Guest VGX version is newer than the
maximum version supported by the Host. Disabling vGPU.
```

这会让 Windows 退回 Basic Display，因此产生 Code 43 和低分辨率。NVIDIA 的配套表
将当前 host 分支对应到 Windows guest 538.33；本迁移包正是固定并恢复这个原始版本。
A 阶段允许从这一 Code 43 状态做 add-only 暂存，但必须仍只有一张 present Display
且保留 legacy PnP identity。不要先卸载设备、删除旧包或再次升级 driver。

## 傻瓜式步骤

以下以 VM3 为例。`VM_ID` 支持 `1..2147483647`，型号来自各 VM 的
`GPU_PROFILE`，不固定为 VM3 或 GTX 1050。

### 1. 宿主生成单文件

```bash
cd /home/ubuntu/projects/qemu
./deploy/package-vgpu-one-click.sh 3
```

通用入口只读选择唯一静态 `SPOOF_MODE`；这里为 A，所以会调用
`package-vgpu-production-migration.sh 3`。需要传高级选项时仍可直接调用底层
打包器。

输出：

```text
/home/ubuntu/images/staging/VgpuProductionMigration/
  vm3-<VM_UUID>/VgpuProductionMigration.exe
```

EXE 约为 `821 MiB + GPU-Z 子包`。体积大是因为它完整内嵌锁定的原始 NVIDIA
archive，没有下载或重新压缩驱动。构建器会先核对 ZIP、原始 INF 和 catalog 的固定
哈希，不会把任意大文件直接封装。构建过程只读配置和资产，不启动/停止 VM，也不挂载
guest 磁盘。

同一 VM/UUID 已有包时，构建器默认拒绝换掉随机 migration ID。只有能够确认旧 EXE
**从未在 guest 运行**时，才可显式重建：

```bash
./deploy/package-vgpu-production-migration.sh 3 --replace
```

guest 一旦产生 staged 回执就绝不能 `--replace`；否则宿主保留的 ID 与磁盘回执会
失配。输出根还必须归当前打包用户所有，且其 ancestry 不得有低权限可写组、非 sticky
other-write 或扩展 ACL，避免他人整体替换无 CA 签名的本地 host-state/EXE。

### 2. Windows 只运行一个文件一次

把 `VgpuProductionMigration.exe` 复制到对应 VM 的本地磁盘，双击，UAC 点“是”。
不要从共享目录直接运行。

首次运行仍处于旧 A 身份时，EXE 会：

1. 只读检查所有 BCD entry，发现 `testsigning` 或
   `nointegritychecks` 开启就停止；
2. 核对完整 ZIP、INF、CAT 的固定大小/哈希，并验证 CAT 是固定 thumbprint 的
   Microsoft WHCP 生产签名；
3. 只执行 `pnputil /add-driver <原始INF>`，不带 `/install`，不会替换当前
   A 设备的驱动；Windows 在 DriverStore staging 时权威验证 catalog 是否包含
   INF 及全部引用文件、签名链是否受信；
4. 从 DriverStore 反查动态 `oemN.inf`，要求精确原始包恰好一份，并再次核对
   INF/CAT 哈希与 WHCP signer；
5. 安装受保护的 SYSTEM 启动续跑任务；
6. 写入 `staged` 回执，并通过 Windows 原生 `InitiateShutdownW` 申请完整关机
   （不依赖调用者的 `USERDOMAIN` 环境，也不使用混合关机）。

这里刻意不使用 `Test-FileCatalog`。该 PowerShell cmdlet 依赖
`New-FileCatalog` 生成的 `FilePath` 成员属性，不能解析 NVIDIA Inf2Cat/WHQL
驱动 catalog，会误报“无法打开目录文件”。完整 archive 的固定 SHA-256 已锁定
源包的每个字节；CAT 自身的固定 SHA-256、有效 Authenticode 状态和固定 WHCP
叶证书锁定公开生产签名；随后 `pnputil`/DriverStore 的系统校验负责证明 INF 与
全部引用文件属于该受信 catalog。任一环节失败都不会写 staged 回执。

用户只双击这一次。后续 B 启动、必要的一次驱动重启和 GPU-Z profile 应用由续跑
任务完成。

### 3. 宿主验证回执后切 B

Windows 完全关机后运行：

```bash
sudo ./deploy/commit-vgpu-production-migration.sh 3
```

该命令通过 `qemu-nbd --snapshot` 的一次性 COW 层连接停止的 qcow2，再以
`ro,norecover` 挂载并读取：

```text
C:\ProgramData\QemuVgpuProductionMigration\receipts\
  vm3-<MIGRATION_ID>-staged.json
```

因此即使 clean-shutdown probe 尝试写入，也只会落入随后丢弃的临时层，不会写
Windows qcow2。脚本先卸载并断开 NBD，之后才允许原子修改 vm.conf。以下任一条件
不满足，配置保持原样：

- VM、UUID、型号、本次随机 migration ID 完全匹配；
- archive、源 INF/CAT、DriverStore INF/CAT 哈希完全匹配；
- published INF 是该 guest 动态分配的 `oemN.inf`；
- add-only 前后的 active `InfName` 完全相同；
- signer 是锁定的 Microsoft WHCP 叶证书，thumbprint 为
  `1935420A805A0CEFEBECDBE59A391A69DB32EAB3`；
- `testsigning=false`、`nointegritychecks=false`；
- `activeDriverChanged=false`、`bcdChanged=false`；
- A 阶段入口/退出的规范化 `bcdedit /enum all` SHA-256 完全相同；
- vm.conf 自构建 EXE 后没有变化；
- VM 已停止，NTFS 是完整关机后的 clean 状态。

成功后宿主策略变为：

```text
SPOOF_MODE=B
VGPU_IDENTITY_TARGET=name-only
```

旧 A/internal/FRL/patched-driver marker 会被清除。Windows 磁盘与 BCD 不会由
commit 脚本写入；旧 vm.conf 和 staged receipt 均保存到 instance backup。

### 4. 正常启动

```bash
./deploy/scripts/start-vm.sh 3
```

旧自签 INF 也可能包含 `DEV_1E30`，所以本流程不依赖 Windows driver rank。续跑任务
先用动态 `oemN.inf` 执行 `pnputil /export-driver`，在受保护临时发布介质目录再次
核对导出 INF/CAT 固定哈希，再使用 `UpdateDriverForPlugAndPlayDevices` FORCE
模式，把唯一 `DEV_1E30` display 精确绑定到该原始 INF。Windows 若要求重启，任务
会自动重启一次并续验。

迁移任务先确认：

- 一张 present Display、native `DEV_1E30`；
- active `InfName` 等于 staged 的官方 `oemN.inf`；
- active INF/CAT 等于固定原始哈希；
- 驱动 `31.0.15.3833`、Code 0；
- BCD 两个完整性开关仍为 off。

随后调用内嵌的 `GpuZProfile.exe /no-launch`。`/no-launch` 会把所有结果写入
控制台和回执，不会在 Session 0 弹出阻塞对话框。该子包在做任何 name/profile
mutation **之前**，先验证 active catalog、`nvlddmkm.sys` 和系统 NVAPI 均通过
NVIDIA/Microsoft 公开生产根链；不通过就退出且不应用 profile。GPU-Z profile
会把内嵌标准 GPU-Z 原子安装到
`C:\ProgramData\QemuGpuZProfile\applications\<版本-哈希>\`，为普通用户保留
ReadAndExecute，并在 Public Desktop 创建 `GPU-Z (vGPU profile).lnk`。完成后，
迁移任务会读取新鲜的受保护子回执，重新核对实际 GPU-Z 文件的哈希、版本、签名、
VM/型号/PnP/Code 0/单 Display/BCD 和系统 NVAPI 不变，再检查设备名称、
active INF/CAT 和 Code 0。最后才删除未被
任何设备使用、且 signer 明确为 `VM3 vGPU Test Driver Signing` 或
`QEMU vGPU Guest Driver Signing` 的旧自签包/证书，不会先删除恢复包。

最终回执位于：

```text
C:\ProgramData\QemuVgpuProductionMigration\receipts\
  vm3-<MIGRATION_ID>-final.json
```

它包含 `gpuName`、`pnpDeviceId`、`displayCount=1`、
`configManagerErrorCode=0`、`activeInf`、active INF/CAT SHA-256、
catalog signer/thumbprint、GPU-Z profile SHA-256，以及嵌套 GPU-Z 回执与实际
持久文件的路径/大小/SHA-256/ProductVersion/TechPowerUp Authenticode 证据；另有
`testsigning=false`、`nointegritychecks=false`、`bcdBeforeSha256`、
`bcdAfterSha256` 与 `bcdChanged=false`。binding/final 每次续跑也要求本次入口/退出
的规范化 BCD 哈希完全相同。

## 验收

设备管理器应显示配置型号（VM3 为 GTX 1050）；设备属性的“数字签名者”应来自实际
NVIDIA/Microsoft 包，不再是 `VM3 vGPU Test Driver Signing`。GPU-Z 应显示同一
型号与目录规格。

管理员 PowerShell 可额外查看：

```powershell
Get-CimInstance Win32_VideoController |
  Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode

Get-CimInstance Win32_PnPSignedDriver |
  Where-Object DeviceClass -eq DISPLAY |
  Format-List DeviceName,InfName,DriverVersion,Signer,IsSigned

bcdedit /enum all | Select-String 'testsigning|nointegritychecks'
```

最后一条没有输出，或只显示 `No`，表示未开启。迁移脚本只使用
`bcdedit /enum all`，不存在 BCD 写操作。

## 失败与回退边界

- **staged 以前**：宿主配置和 active driver 都不变，修正后重跑同一 EXE。
- **staged 后、host commit 前**：官方包只是 DriverStore add-only。宿主必须消费
  回执；若需修复，使用显式 B/off 救援，不能伪造回执或重新启用 strict-A。
- **host commit 后、官方绑定证明以前**：vm.conf 已备份，旧驱动包仍保留。保持
  B/native，修复官方绑定后让任务续跑，不要退回 A。
- **FINAL PASS 后**：官方包已经证明 active，旧自签包才可能清理。稳定配置是
  B/native + name/profile overlay，不再支持 A 回退。

任何失败都不会开启完整性旁路、安装新的自签内核驱动或伪造签名者名称。
