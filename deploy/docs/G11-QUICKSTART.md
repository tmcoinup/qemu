# G-11 vGPU 傻瓜教程：基础镜像一次封装，任意 VM 克隆

本页只适用于 **G-11/vGPU 分支**。V-11 是独立分支，不要混用脚本或验收结论。

## 先记住

1. guest 不开启 `testsigning`、`nointegritychecks`，软件也不会修改 BCD。
2. 不安装测试签名/自签名内核驱动。显示驱动必须是未修改的 NVIDIA GRID
   538.33，并由正常 NVIDIA/Microsoft 生产链验证；使用这种驱动不需要自行买驱动
   签名证书。
3. 新的主流程只生成一个无 VM 绑定、无 HTTP 依赖的
   `VgpuPortable.exe`。同一个文件放入基础镜像后，可供 VM4、VM5、VM6、VM456
   等克隆使用。
4. 新 VM 保持 B/native。宿主每次正常启动时自动发布只读 SMBIOS profile/UUID
   声明；Windows 双击 EXE 后不需要人工 host commit。
5. 只有历史 A → B 生产驱动迁移仍按 VM/UUID 绑定，并需要 guest 自动关机后的
   一次宿主 commit。

> UAC 可能把本地构建的 portable 外层 EXE 显示为“未知发布者”。它是用户态
> 封装器，不是显示驱动或自签名内核文件。设备属性中实际驱动的数字签名者应为
> `Microsoft Windows Hardware Compatibility Publisher`。

## 新主流程：只需三条宿主命令

先让所有 VM 完整关机，然后在宿主执行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh
./deploy/clone-vgpu-base.sh 456 --gpu-profile gtx1050_2gb --start
```

三条命令分别完成：

1. 构建
   `/home/ubuntu/images/staging/VgpuPortable/VgpuPortable.exe`。包内有全部已审计
   profile，但没有 VM ID/UUID。
2. 把 EXE 安全放入公共 Windows base 的
   `C:\Users\Public\Desktop\VgpuPortable.exe`。这一步只需为每个 base 做一次。
3. 创建 VM456 的独立 B/native 配置和 UUID，从 base 克隆系统盘并启动。

进入 Windows 后只双击公共桌面的 `VgpuPortable.exe`，UAC 点“是”，等待：

```text
[GPU-Z profile] INSTALL PASS
```

不需要再复制 ZIP、PowerShell、DLL 或 GPU-Z；不依赖 HTTP、映射盘、WinRM 或
guest 下载。正常 portable clone 安装后也不需要关机回宿主提交。

## 为什么不再绑定 VM

portable EXE 内嵌的是 profile catalog，而不是某台 VM 的选择结果。每次
`start-vm.sh` 以 B/native 启动时，会自动把下面信息作为只读 SMBIOS Type 11
声明提供给 guest：

- 当前 `GPU_PROFILE`；
- 当前 SMBIOS `VM_UUID`；
- portable profile catalog 哈希；
- 原生 `10DE:1E30` PnP tuple；
- 允许的驱动版本 `31.0.15.3833`。

EXE 必须同时核对恰好一条声明、当前 UUID、单 Display、Code 0、驱动版本、
DriverStore catalog、已加载 `nvlddmkm.sys` 的生产签名和 BCD 安全状态。这样同一
EXE 可跨 VM 使用，但不能在 guest 内任意选择/伪造另一个型号。A/off 启动没有该
声明，旧启动进程也不会凭空获得它。

这里“宿主自动注入”属于正常 `start-vm.sh` 启动流程，不是用户每克隆一台 VM
还要运行一次的提交命令。

## 支持的显卡 profile

| `GPU_PROFILE` | 设备管理器 / GPU-Z 目标名称 | 当前合同 |
|---|---|---|
| `gtx750ti_2gb` | NVIDIA GeForce GTX 750 Ti | 2 GB / GDDR5 / Samsung |
| `gt1030_2gb` | NVIDIA GeForce GT 1030 | 2 GB / GDDR5 / Samsung |
| `gtx1050_2gb` | NVIDIA GeForce GTX 1050 | 2 GB / GDDR5 / Samsung |

换型号只需在 clone 时选择 profile，例如：

```bash
./deploy/clone-vgpu-base.sh 457 --gpu-profile gt1030_2gb
./deploy/start-vm.sh 457
```

`VM_ID` 支持 launcher 允许范围内的正整数，不区分 1、2、3、4、5、6、456。
新增显卡型号必须先进入唯一 catalog 并完成实际驱动/GPU-Z/NVAPI 审计；不要按 VM
编号创建文件或只改显卡名称。

## 制作 base 前的安全条件

base 必须是 standalone qcow2，Windows 已完整关机，NTFS 干净且未休眠。基础
Windows 中应已经有：

- B/native `DEV_1E30` 上正常绑定的原始 GRID 538.33；
- Code 0 和可用的正常分辨率；
- NVIDIA/Microsoft 生产签名 catalog 与加载中的内核驱动；
- `testsigning=No`、`nointegritychecks=No` 或未设置；
- 不含 patched driver、自签 catalog、私有测试根证书。

运行 base 注入脚本前必须停止**所有** VM，而不只是模板 VM。脚本获取独占存储
锁，拒绝正在使用、带 backing/data-file、被其他 qcow2 依赖或校验失败的 base。
它只挂载私有临时副本；遇到 dirty/hibernated NTFS 会停止，不会强制删除休眠文件。
临时副本完成写入、哈希复核、卸载和 `qemu-img check` 后，旧 base 才归档并原子
替换。

因此不要在 VM 运行时手工 NBD 挂载 base，也不要为了通过门禁使用
`remove_hiberfile`、强制 NTFS 写挂载或手改 portable attestation。

## 常用变体

只准备 package，不更新 base：

```bash
./deploy/package-vgpu-one-click.sh
```

自定义 portable 输出或 base：

```bash
./deploy/package-vgpu-one-click.sh --portable \
  --output-exe /srv/private/VgpuPortable.exe

sudo ./deploy/install-vgpu-portable-to-base.sh \
  --base /srv/images/win10-base.qcow2 \
  --exe /srv/private/VgpuPortable.exe
```

克隆但暂不启动：

```bash
./deploy/clone-vgpu-base.sh 458 --gpu-profile gtx750ti_2gb
```

之后正常启动即可：

```bash
./deploy/start-vm.sh 458
```

`clone-vgpu-base.sh` 还可传递 `--platform`、`--ssd-profile` 和
`--monitor-profile`。目标 VM 配置或磁盘已经存在时会拒绝，不会覆盖。

## 最终验收

请使用本地 QEMU SDL/GTK 或 fb-shm 画面。活动 RDP 可能创建 Remote Display
Adapter，导致严格的单 Display 检查拒绝。

### 设备管理器

- “显示适配器”下只有一张目标 NVIDIA 显卡；
- 设备状态 Code 0，没有 Code 43；
- 驱动版本为 `31.0.15.3833`；
- 数字签名者为
  `Microsoft Windows Hardware Compatibility Publisher`，不是
  `VM3 vGPU Test Driver Signing`；
- 分辨率已恢复到显示器正常模式。

PCI bridge 是显卡父设备，不是第二张显卡。底层系统 PnP 仍是 vGPU 原生
`DEV_1E30`，以便加载未经修改的正式签名 GRID 驱动；设备管理器 marketing name
和 GPU-Z app-local profile 显示配置的消费卡型号。

### GPU-Z 2.70

- 标题、Name 和底部下拉框是目标型号；
- 下拉框只有一个 GPU；
- 2 GB、显存类型、位宽、带宽和时钟符合该 profile catalog；
- Digital Signature 显示 WHQL。

GPU-Z 的 WHQL 文本不是签名链本身。实际签名结论来自 DriverStore catalog、
当前加载的 `nvlddmkm.sys` 以及 Windows Authenticode/WHCP 验证。

管理员 PowerShell 只读复核：

```powershell
Get-CimInstance Win32_VideoController |
  Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,
    CurrentHorizontalResolution,CurrentVerticalResolution

Get-CimInstance Win32_PnPSignedDriver |
  Where-Object DeviceClass -eq DISPLAY |
  Format-List DeviceName,InfName,DriverVersion,Signer,IsSigned

bcdedit /enum all | Select-String 'testsigning|nointegritychecks'
```

Windows 的 published INF 是动态分配的 `oemN.inf`，每个 clone 可能不同。软件会
自动反查，教程不会固定 VM3 当时的编号。

## HWiNFO 怎么看

当前 portable 包端到端锁定的是包内 **GPU-Z 2.70 x86**。HWiNFO64 还会通过
x64 NVAPI、内核 PCI/vGPU 拓扑等接口交叉查询，可能显示
`[FAKE] NVIDIA GRID Quadro RTX6000-2Q`、底层 Quadro 型号或 `TU104`。这不等于
设备管理器多出第二张显卡，但也说明 HWiNFO 不是当前已适配的验收面。

不要为消除 `[FAKE]` 全局替换 System32/SysWOW64 的 `nvapi64.dll`，也不要简单
改字符串。仓库提供独立的
[HWiNFO64 app-local 实验适配](HWINFO-APP-LOCAL-EXPERIMENT.md)，只针对用户明确
指定、正常签名且版本可审计的 HWiNFO64 可执行文件；它不随 portable 自动安装，
也不能承诺 `[FAKE]`、TU104 或全部字段消失。当前正式验收仍以设备管理器、实际
驱动签名链和包内 GPU-Z 2.70 为准。

## 历史 A VM：仍然是按 VM 迁移

历史 `SPOOF_MODE=A` 使用过修改 INF/自签 catalog，不能靠 portable 身份层直接
变成合规驱动。它继续使用 VM/UUID 绑定的兼容流程：

```bash
cd /home/ubuntu/projects/qemu
VM_ID=3
./deploy/package-vgpu-one-click.sh "$VM_ID"
```

只把输出的 `VgpuProductionMigration.exe` 复制到对应 Windows 本地磁盘并运行。
它暂存原始生产驱动、写一次性回执并自动完整关机。确认 QEMU 已退出后：

```bash
sudo ./deploy/commit-vgpu-production-migration.sh "$VM_ID"
./deploy/start-vm.sh "$VM_ID"
```

commit 只读核验停止磁盘中的 staged 回执，成功后才把该 VM 配置原子提交为
B/native；失败不会修改 host 配置。后续受保护任务完成 538.33 绑定、Code 0、
生产签名和 GPU-Z 验收。

带 `VM_ID` 的 `package-vgpu-one-click.sh` 仅为 legacy 兼容。它对 A 选择完整
迁移包，对旧 B 选择原来的 VM 绑定 GPU-Z 包。新建/克隆 B VM 应使用**不带参数**
的 portable 主入口；不要给 portable clone 运行 legacy commit。

VM3 已完成这条历史 A → B/native 迁移，可作为 Code 0、生产签名和 GPU-Z 结果
参考。它不是测试签名目标，也不应再次运行旧迁移包。

## 常见错误

| 现象 | 原因与处理 |
|---|---|
| portable 报 firmware claim 缺失 | 用正常 B 配置重新冷启动；确认不是 A/off、旧 QEMU 进程或手工绕过 `start-vm.sh` |
| Code 43，分辨率变小 | host/guest vGPU branch 或原始驱动绑定有问题；先修 538.33/Code 0，GPU-Z 包不能掩盖 |
| 检出两张 Display | 退出 RDP并从本地画面复核；PCI bridge 不算显卡，Remote Display Adapter 才算 Display |
| base 注入报存储锁 | 停止所有 VM 和存储操作后重试 |
| base 注入报 dirty/hibernated | 正常启动 Windows、关闭 Fast Startup、执行完整关机后重试 |
| clone 报 base changed/no attestation | base 在注入后被改动；重新执行安全注入，不要手改 sidecar |
| UAC“未知发布者” | portable 外层是未签名用户态文件；驱动本身仍必须为正常 WHCP 签名 |
| HWiNFO 仍显示 `[FAKE]`/TU104 | 当前不在 portable 的正式适配范围；不要全局替换 NVAPI |
| legacy commit 报 mismatch | EXE、回执、VM UUID 或配置不属于同一次迁移；停止并保留原件，不要改 JSON/marker |

出现失败时记录第一条 `FAIL:`。不要安装自签驱动、导入私有根、手改 BCD、回执或
firmware claim。

详细边界：

- [离线 portable、基础镜像和 GPU-Z 身份层](GPUZ-ONE-CLICK.md)
- [HWiNFO64 app-local 实验适配与不能保证的字段](HWINFO-APP-LOCAL-EXPERIMENT.md)
- [旧 A → B 原始生产签名驱动迁移](VGPU-PRODUCTION-MIGRATION.md)
- [Code 43、黑屏与分辨率排障](DEBUG.md)
- [Windows/base/VM 新建完整流程](VGPU-VM-CREATION.md)
