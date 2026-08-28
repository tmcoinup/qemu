# G-11 显示器池：傻瓜教程与安全边界

本页只适用于 G-11/vGPU。显示器目录不会改 BCD，不会开启测试模式，也不会安装
任何 guest 内核驱动。正常路径只在 VM 关机且 NTFS 干净时，把所选 profile 生成的
EDID 离线同步到 Windows 已有的显示器实例：除了兼容用的 raw
`Device Parameters\EDID`，还会把 256-byte EDID 拆成两个 128-byte
block，写入 Microsoft 标准 `Device Parameters\EDID_OVERRIDE\0` 和 `\1`。
Windows 显示栈和普通应用会优先使用这份 override，所以不需要 R535 mdev
提供 QEMU live EDID region：
[Microsoft: Overriding Monitor EDIDs](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/overriding-monitor-edids)。

## 当前池包含什么

- 完整兼容目录：35 个真实型号；35 个 profile 的首选输出都强制为
  FHD 1920×1080@60，旧 VM 可继续加载其中任何 profile。
- 新建 VM 严格池：28 个中国大陆常见 FHD 型号、8 个品牌。
- 尺寸覆盖：21.5 英寸、23.8/24 英寸、27 英寸。
- 分辨率：完整目录和新建池全部为 FHD 1920×1080；1366×768、2560×1440 等
  不能作为目录 profile 的首选/原生分辨率。
- 首选刷新率：全部为 60 Hz。

35 个型号各有一条
[linuxhw/EDID](https://github.com/linuxhw/EDID) 真实解码样本作为来源；PNP
vendor/product、物理尺寸、生产周/年、输入类型和范围描述符都取自对应样本。
逐项复核结果为：32 个样本的首选 DTD 是 1920×1080@60，另外 3 个样本以
CTA VIC 16 把 1920×1080@60 标成 native；没有 1366×768 或 2560×1440 的
profile。本轮扩容的 12 个型号如下：

| 尺寸 | 型号 | PNP | DTD 尺寸 | 样本最大垂直范围 |
|---|---|---|---|---|
| 21.5 | Samsung S22F350 | `SAM:0x0D1A` | 477×268 mm | 75 Hz |
| 27 | Samsung S27F350 | `SAM:0x0D22` | 598×336 mm | 75 Hz |
| 21.5 | Dell P2219H | `DEL:0xA113` | 476×267 mm | 76 Hz |
| 27 | Dell P2719H | `DEL:0x4183` | 598×336 mm | 76 Hz |
| 21.5 | BenQ GW2280 | `BNQ:0x78E8` | 476×268 mm | 76 Hz |
| 27 | BenQ GW2780 | `BNQ:0x78E6` | 598×336 mm | 76 Hz |
| 21.5 | Philips 223V7 | `PHL:0xC154` | 476×268 mm | 76 Hz |
| 27 | Philips 273V7 | `PHL:0xC156` | 598×336 mm | 76 Hz |
| 21.5 | Lenovo D22-20 | `LEN:0x66AD` | 477×268 mm | 75 Hz |
| 27 | Lenovo D27-30 | `LEN:0x66B8` | 597×336 mm | 75 Hz |
| 21.5 | ASUS VA229 | `AUS:0x22F1` | 476×268 mm | 76 Hz |
| 27 | ASUS VA27EHE | `AUS:0x27D2` | 598×336 mm | 75 Hz |

每一行的精确样本路径和哈希写在
[`monitor-profiles.tsv`](../config/monitor-profiles.tsv) 的相邻 `source` 注释中，方便
以后逐项复核，不能只凭零售网页的营销名称补一行，也不能为了凑数量修改来源
样本的分辨率。

## 正常 1K/FHD 分辨率合同

所有 35 个 profile 共用同一份严格模式合同。EDID 只主动发布：

| 来源 | 分辨率 |
|---|---|
| 首选 DTD | 1920×1080@60 |
| CTA 视频模式 | 1920×1080@60、1280×720@60 |
| Standard Timings | 1920×1080、1280×1024、1280×720（均为 60 Hz） |
| Established Timings III | 1360×768、1280×1024、1280×960、1280×768（均为 60 Hz） |
| Base Established | 1024×768、640×480（均为 60 Hz） |

去重后的 EDID 主动广告集合是
`1920×1080 / 1360×768 / 1280×1024 / 1280×960 / 1280×768 /
1280×720 / 1024×768 / 640×480`。这 8 项同时是显示器 target modes
和 NVIDIA source modes；Windows“设置”通常隐藏兼容档 `640×480`，所以下拉里
一般看到其余 7 项。

生产签名 GRID 538.33 的 `nvgridsw.inf` 会在 NVIDIA 显示适配器 software key 的
`NV_Modes` 中补充 GPU scaling/source modes。G-11 对其使用单独的精确策略，并将
它收敛为与 EDID 完全相同的 8 项：

`1920×1080 / 1360×768 / 1280×1024 / 1280×960 / 1280×768 /
1280×720 / 1024×768 / 640×480`。

R535 会把 32-bpp pitch 对齐到 128 字节、消息补到 4 KiB；两者长度不等时会拒绝
display-head 投递。策略因此删除会复现该缺陷的 `1600×900` 和 `800×600`，并删除
上一版兼容策略额外加入的 `1600×1200`、
`1600×1024`、`1440×1080`、`1366×768`、`1152×864`。INF 原值中的
`1920×1200`、`1680×1050`、`1280×800`、`2560×1600` 等 16:10，所有高于
FHD 和电视专用模式也不会进入这份“正常 1K/FHD PC 列表”。未来若驱动值出现
`1440×900`、`1600×1000` 等未知模式，离线同步会失败关闭，不会默默接受或覆盖。
故障证据、精确计算和一键恢复见
[`G11-R535-BLACK-SCREEN.md`](G11-R535-BLACK-SCREEN.md)。

G-11 与 V-11 的显示驱动不同：V-11 的 virtio 驱动从 EDID 建 source list，G-11
的 NVIDIA 驱动还消费私有 `NV_Modes`，所以只照搬 V-11 的 EDID/清缓存流程不够。
Microsoft 对显示驱动 INF 的说明确认 `DDInstall` 中的 `HKR` 落在设备 software key；
`NV_Modes` 的压缩分组、分辨率 token 与 refresh mask 语法见 NVIDIA 的官方指南：
[Microsoft display software settings](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/adding-software-registry-settings)、
[NVIDIA Compressed Modes User's Guide](https://download.nvidia.com/Windows/43.45/NV_Compress_Modes_Users_Guide_2.1.pdf)。
同步器只处理 SYSTEM `Select` 明确指向的 `Current` / `Default` /
`LastKnownGood`，并只从 profile 对应的固定 B/native 路径验证：1GB/`nvidia-256`
使用 `Enum\PCI\VEN_10DE&DEV_1E30&SUBSYS_132510DE...`，2GB/`nvidia-257`
使用 `Enum\PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE...`。随后验证
`Service=nvlddmkm`，再沿 `Driver={4d36e968-...}\NNNN` 关系定位当前 software
key。A → B 迁移后残留的 consumer-ID `DEV_1C81&SUBSYS_11C01028` Enum/Class
历史不会被当成当前设备，也不会被改写；当前 native PnP 若缺失或认证失败则仍然
失败关闭。同步器不全扫孤立旧 ControlSet、`Control\Class`/`Control\Video`，也不碰
`NV_R&T`。`Current` 必须同时命中 EDID 与当前 NVIDIA 设备，不允许从不同
ControlSet 拼出“成功”。写入前还要求当前 Class key 的 `ProviderName` 为 NVIDIA、
`DriverVersion=31.0.15.3833`、`InfPath` 是规范 `oemN.inf`，且该已发布
INF 的 SHA-256 精确匹配生产 `nvgridsw.inf` 收据。即使其他 NVIDIA 版本
恰好使用相同 `NV_Modes` 文本也会被拒绝。只有值精确等于锁定 INF 原值、上一版
已审核的 15 项策略、上一版 10 项策略或已经等于当前 8 项策略时才继续；旧 15/10
项仅作为迁移来源，绝不会再被写入。写后还会重新检查类型、双 NUL、8 项精确集合、
零 16:10 和每个模式的 R535 page-safe 帧长。

这是 EDID/Windows 缓存策略，不需要修改、重编或重签 NVIDIA guest 驱动；流程
不会开启 `testsigning`、`nointegritychecks`，不会修改 BCD，也不会安装测试签名或
自签名内核驱动。

### 能保证什么，原始 NVIDIA 父节点又代表什么

启动器会在每个 `[mdev."UUID"]` 下原子写入 `num_displays=1`、
`display_width=1920`、`display_height=1080`、`max_pixels=2073600`。per-mdev
值晚于共享的 `nvidia-257` profile 应用，因此会覆盖旧宿主残留的
`4 heads/1920×1200` 资源合同；这解决的是实时 vGPU 的显示头数和最大分辨率上限。

关机态同步会验证并写入 BenQ/Dell 等目标 raw EDID、标准
`EDID_OVERRIDE`、8 项 `NV_Modes`、缓存 `FriendlyName` 和 Windows
GraphicsDrivers 缓存。它不能在 Windows 关机时修改 live PnP 对象；私有 Sysprep
克隆的系统身份包会在启动/登录后用 SetupAPI 再发布实时 FriendlyName，并回读验证。
启动后 Windows 可能仍保留 NVIDIA 发布的原始父 key
`DISPLAY\NVD0000`；这个内部路径不是 Windows 有效 EDID 的验收结果，也不要为了
改 key 名而换驱动。验收看的是有效 WMI EDID、设备管理器友好名和第三方工具结果：

- Windows 本地输出必须是所选 profile 的 1920×1080、16:9、物理尺寸、厂商/型号和
  8 项目标/source modes；
- 设备管理器“监视器”应显示 `MONITOR_DISPLAY_NAME`，而不是“通用即插即用监视器”；
- 鲁大师应显示 profile 对应的 PNP/品牌型号、尺寸、16:9 和 1920×1080。若仍是
  `NVIDIA VGX / 641×400 mm / 16:10`，就是旧 marker 或未写入
  `EDID_OVERRIDE`，不是“正常的 live EDID 局限”；
- `VgpuPortable.exe` 处理 GPU 身份和推荐 guest 性能（GPU-Z 为显式选装消费者），
  但不会选择或写入显示器。即使已运行它，显示器仍必须由本页的 host 同步链处理。

## 已有 VM：最短入口

日常只运行：

```bash
sudo -v
./deploy/scripts/vmctl.sh start N
```

只有名称或分辨率确实错误，才在 Windows 完整关机后执行：

```bash
sudo -v
./deploy/scripts/vmctl.sh monitor N --force
./deploy/scripts/vmctl.sh start N
```

授权也有问题时，不要继续拼接本页的技术步骤，直接照抄
[`VGPU-RECOVERY-RUNBOOK.md`](VGPU-RECOVERY-RUNBOOK.md)。以下内容是显示器实现与
排障参考。

先分清两个独立产物：

| 现象 | 负责边界 | 标准入口 |
|---|---|---|
| NVIDIA 控制面板“管理许可证” / host `Unlicensed` | Guest token 与 DLS | 私有 `VgpuPortableLicensed/VgpuPortable.exe` |
| “通用即插即用监视器” / 旧 16:10 缓存 | Host 关机态 EDID/`NV_Modes` + guest live FriendlyName | `vmctl.sh monitor N --force` 后正常启动，等待 SYSTEM 身份任务 |

授权 EXE 成功不会把显示器名改成 AOC/BenQ/Dell；显示器同步成功也
不会为 NVIDIA 申请 license。两者都需要时，固定顺序是：Guest 运行私有
EXE 并看到 `Licensed` → Windows 完整关机 → host 强制 monitor sync →
普通冷启动复验。组合照抄流程见
[`VGPU-RECOVERY-RUNBOOK.md`](VGPU-RECOVERY-RUNBOOK.md)。

第一次拉取本改动后先增量构建一次。封装会同时生成 QEMU 主程序和离线缓存同步
所需的 `qemu-edid`；以后日常启动只需最后一条：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
./deploy/scripts/start-vm.sh N
```

从其他分支切回 G-11 时，未纳入 Git 的 `build/` 可能仍保留另一版
`qemu-edid`。当前显示器封装会在生成前识别新版
`--manufacture-week/--min-vfreq-hz` 与 G-11 旧版
`--week/--range-min-v` 的差异。两版生成的描述符布局也不同，所以封装不会只翻译
参数名后冒充兼容，而会在写出 EDID 前失败关闭并直接提示重建 G-11；不会再出现
难以定位的 `unrecognized option '--week'`。最短照抄流程是：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
./deploy/scripts/clone-from-base.sh win10-base 1 --gpu-vram 1024 \
  --platform i7-4820k-p9x79-elpida-8g \
  --ssd-profile samsung-970-pro-512gb --start
```

若旧版本已在这个错误处退出，`clone-from-base.sh` 会像日志所示回滚新建配置；
确认 `./deploy/scripts/vmctl.sh status 1` 没有在运行后，直接重跑上面两条即可，
不需要手工删除镜像，也不需要修改 Windows、BCD 或驱动签名策略。

把 `N` 换成实例号。`start-vm.sh` 缺省启用 monitor sync，读取该 VM 已生成的
`MONITOR_PROFILE`，按 marker 判断是否需要离线更新；不需要单独执行
`vmctl monitor`。需要离线挂载且当前没有 sudo 票据时，交互终端会自动显示标准
sudo 密码提示，凭据不会写入仓库或命令参数。非交互启动必须事先通过批准的运行时
渠道提供 sudo 票据或 `SUDO_PASSWORD`，不能把宿主凭据写进配置。

若 base 从未枚举过显示器，普通 vGPU 启动会拒绝让 NVIDIA console 承担首次枚举，
并提示运行 `./deploy/scripts/vmctl.sh driver-install N`。该封装在标准 VGA 隔离窗口中
完成枚举、驱动安装和完整关机，随后离线补齐缓存，无需插入一条人工 monitor 命令。
私有 Sysprep 克隆则由首启系统身份任务完成 live 名称；如果首启窗口红字退出，应先看
`C:\ProgramData\VMate\G11\clone-initialization-error.txt` 并以管理员运行同目录的
`Retry-Clone-Initialization.cmd`，不要反复点击设备管理器更新。

`vmctl monitor` 是关机态强制修复/切换型号入口：它离线更新 `Select` 选中
ControlSet 中已有的 `Enum\DISPLAY`
raw EDID 和标准 `EDID_OVERRIDE`，约束已绑定 NVIDIA
适配器的 `NV_Modes`，并清理 Windows `GraphicsDrivers` 的 Configuration、
Connectivity、ScaleFactors 和 MonitorDataStore 模式缓存；guest 内不会留下脚本、
服务或计划任务。只有旧 marker/旧 16:10 缓存、手工重装显示驱动，或明确要求
无条件重写时，才照抄：

```bash
./deploy/scripts/stop-vm.sh N
./deploy/scripts/vmctl.sh monitor N --force
./deploy/scripts/start-vm.sh N
```

需要切换不同显示器时，也只用同一个封装：

```bash
./deploy/scripts/stop-vm.sh N
./deploy/scripts/vmctl.sh monitor N --monitor-profile benq-gw2280 --force
./deploy/scripts/start-vm.sh N
```

将 `benq-gw2280` 换成目录中任意 profile。新建和克隆也使用同一套目录和同一个
v8 marker，没有为 vm9/vm10 或 BenQ 写死任何特例。

普通启动还会自动原子刷新该 VM 的单头 FHD per-mdev 合同；日志应出现
`host per-mdev 显示合同：1 head / 1920x1080 / max_pixels=2073600`。无需手改
`/etc/vgpu_unlock/profile_override.toml`，也不要因全局旧值仍可见就删除其他 VM 的
`[mdev."UUID"]` 段。

离线写入前后都由同一个只读 SYSTEM hive 校验器把 REGF header 的 `Length` 当作
活动 hbin 链边界。Windows/hivex 可在该逻辑末尾与物理 EOF 之间保留旧 hbin 或零
填充 slack；封装会保留并报告它，不截断、不清零、不重放旧 LOG。只有逻辑 Length
范围内链断裂、越界、sequence 不一致或 checksum 错误才会拒绝。因此看到
`logical_end=... physical=... slack=...` 是正常结构报告，不是磁盘损坏。

Windows 必须先完成真正关机，不能处于休眠或 Fast Startup 状态。封装遇到运行中
VM、dirty NTFS 或休眠卷会停止；不要强制挂载、删除 `hiberfil.sys` 或绕过门禁。

若这里报告 `Windows is hibernated` / `Fast Startup`，不要继续普通 vGPU 启动，也
不要运行 GTX1050 已禁用的 `finish-vgpu-install.sh`。直接执行 host-only 恢复封装：

```bash
sudo -v
./deploy/scripts/recover-hibernated-vm.sh N
```

不要把第二行写成 `sudo ./deploy/scripts/recover-hibernated-vm.sh N`；封装会拒绝以 root
运行整台 QEMU。它必须由拥有 VM 和本地图形会话的普通用户执行，只让离线同步使用
前一行缓存的 sudo 票据。

它只打开本地标准 VGA（默认 SDL，宿主需要时加 `--rescue-gtk`），不挂 NVIDIA
vGPU、不走 VNC/RDP/WinRM，也不向 guest 安装包。在 Windows 窗口内以管理员身份
逐行运行：

```bat
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
shutdown.exe /s /f /t 0
```

等窗口自然退出；封装才会自动运行 `sync-monitor-profile.sh N --force`。成功后它打印
普通启动命令；需要该命令保留 `--proxy` 时，在恢复入口也加 `--proxy`，但 rescue
QEMU 本身固定不用 proxy。若 Windows 未完整关机、卷仍 dirty/hibernated 或同步
验证失败，封装返回非零并保持 VM 关闭；它不会强挂载、删除 `hiberfil.sys`、运行
`ntfsfix`，也不会修改 BCD、签名或驱动。GTX750Ti/GT1030 的 legacy token/RTC
finish 是另一条流程，边界见
[`VGPU-RECOVERY-RUNBOOK.md`](VGPU-RECOVERY-RUNBOOK.md)。

同步日志必须同时出现 EDID 列表、`GRID 31.0.15.3833 / oemN.inf
生产 INF 哈希验证通过` 和类似
`NV_Modes 写入 8 个 R535 page-safe、EDID 对齐的 FHD/1K PC 模式`
（重复运行会显示“已符合”）。验收时
使用本地 SDL/GTK 或 fb-shm 原生画面，冷启动后打开“设置 → 系统 → 显示 → 显示
分辨率”。先退出 RDP；RDP 的 Remote Display Adapter 和动态分辨率不代表 NVIDIA
本地输出。仓库测试能证明注册表策略精确，但 NVIDIA 私有值的最终运行时效果仍以这次
冷启动验收为准。

若 helper 报“拒绝覆盖未知 NV_Modes”、版本或 INF 哈希不符，停止并保留日志；
这表示已安装包或现场自定义与锁定基线不同，不能强删。任何 GRID 安装、
修复或同版本重装都会由 INF 恢复默认 `NV_Modes`。仓库支持的
`vmctl.sh driver-install N` 会先以标准 VGA + mdev `display=off` 隔离 R535 console；
其内部 `install-vgpu-driver.sh` / `install-vgpu-driver-gui.sh` 还会在首次 guest 写入前
从实际 QEMU argv 验证该拓扑并安全使 monitor marker 失效。即使显式传 `--ip`，也必须与指定 `VM_ID` 配置的
`VM_MAC` 在 `br0` 邻居表中匹配，避免改了一台 guest 却使另一台的 marker 失效。
安装收据通过后封装会自动完整关机并立即离线重刷；若绕过入口在 Device Manager
手工修复/重装，完整关机后明确执行 `./deploy/scripts/vmctl.sh monitor N --force`。不能靠
修改/自签 INF/SYS/CAT、安装
测试驱动、改 BCD、开启 `testsigning`/`nointegritychecks` 或锁死注册表 ACL 绕过。

## 为什么表里暂时没有“1080p@75/144” profile

范围描述符里的 `max_v=75/76` 只表示显示器接受的垂直频率范围，不等于 EDID 已经
发布了 1920×1080@75 的详细时序。来源样本的首选 DTD 或 native CTA 时序都是
1920×1080@60；生成后的 G-11 EDID 再强校验第一条 preferred DTD 必须是同一
1920×1080@60 模式。当前 NVIDIA vGPU、Windows 缓存同步和在线救援链也只完成了
60 Hz 一致性验证，所以目录不把范围上限冒充高刷模式。

这条限制是故意的：不能把 `max_v` 直接抄到 `refresh_hz`，否则 Windows 会看到一个
没有真实 DTD 支撑的模式。以后只有同时具备真实高刷 EDID 样本、准确 DTD/CTA
时序、宿主 mdev 输出能力和 Windows 回归结果时，才能新增 75/100/120/144 Hz 档。

## 新建 VM：只需这样做

先查看允许用于新 VM 的型号：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/create-vm.sh --list-monitor-profiles
```

不指定型号时，创建器先等概率选择品牌，再在该品牌内随机型号，避免某个品牌因为
条目多而被过度选中：

```bash
./deploy/scripts/start-vm.sh 9 --install /home/ubuntu/images/iso/win10.iso
```

需要固定 21.5 或 27 英寸时，显式选择一个 profile：

```bash
# 21.5 英寸
./deploy/scripts/create-vm.sh 9 --monitor-profile samsung-s22f350

# 或 27 英寸
./deploy/scripts/create-vm.sh 9 --monitor-profile lenovo-d27-30

./deploy/scripts/start-vm.sh 9 --install /home/ubuntu/images/iso/win10.iso
```

已有 `vm.conf` 时创建器会拒绝覆盖，因此上述两条尺寸选择命令只能二选一。启动后
也不会每次随机换显示器；profile 与生成的序列号会固定在该 VM。

检查最终配置：

```bash
rg '^(MONITOR_PROFILE|MONITOR_DISPLAY_NAME|MONITOR_WIDTH_MM|MONITOR_HEIGHT_MM|MONITOR_NATIVE_[XY]|MONITOR_REFRESH_HZ|MONITOR_SERIAL)=' \
  /home/ubuntu/images/vms/9/vm.conf
```

预期 `MONITOR_NATIVE_X=1920`、`MONITOR_NATIVE_Y=1080`、
`MONITOR_REFRESH_HZ=60`，尺寸与所选型号一致。

## 从 portable base 克隆：缺省自动选择并同步显示器

最短命令无需显示器参数：创建器会先按“品牌等概率、品牌内随机型号”的规则生成
profile 并固定到新 VM 的 `vm.conf`，克隆器随后立即自动同步。`--start` 只决定是否
马上开机，不再决定是否配置显示器：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh clone win10-ltsc-v1 N --gpu-profile gtx1050_2gb --start
```

需要固定型号时才显式传入。`VgpuPortable.exe` 仍不负责显示器身份，GPU-Z 仍为
显式选装项：

```bash
./deploy/scripts/vmctl.sh clone win10-ltsc-v1 N \
  --gpu-profile gtx1050_2gb \
  --monitor-profile benq-gw2280 \
  --start
```

`vmctl clone` 是 `clone-from-base.sh` 的傻瓜封装，两种入口行为相同。若 portable
base 已经枚举过显示器，克隆完成时就会按新 profile 重刷现有缓存。若 base 从未
枚举过显示器，克隆会明确报告 `first-enumeration-deferred`；第一次启动只让
Windows 建立 `Enum\DISPLAY` 实例，完整关机后下一次普通启动自动完成，不需要手工
插入 `vmctl monitor`。

切换克隆后的显示器仍使用“已有 VM”章节的 `vmctl monitor N
--monitor-profile PROFILE --force`，无需重克隆磁盘，也无需再次运行
`VgpuPortable.exe`。`--no-monitor-sync` 仅保留给明确的救援/调试场景，日常不要加。

## 目录维护门禁

修改显示器目录后必须执行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/tests/vgpu/test_nvidia_modes.sh
./deploy/tests/vgpu/test_monitor_sync_marker_static.sh
./deploy/tests/vgpu/test_driver_installer_monitor_marker_static.sh
./deploy/tests/vgpu/test_monitor_profiles.sh
```

测试会逐个检查完整 35 条目录和 28 条新建池，再为全部 profile 生成 EDID，检查
长度、双块 checksum、PNP、物理尺寸、preferred-timing 标志及第一条 DTD 必须为
1920×1080@60，并要求 Standard Timings 与 `0xf7` 位图精确等于本页白名单、广告
集合精确等于上述 8 项、不存在任意 16:10，并要求每项按 128 字节 pitch 计算后的
帧长是 4 KiB 整数倍。NVIDIA 策略测试使用 GRID 538.33 的真实双元素
`NV_Modes`，验证原始值、旧 15 项和上一版 10 项都只能迁移到新策略，同时拒绝
未知值、错误 mask、畸形 REG_MULTI_SZ、非
538.33 版本/已发布 INF 身份与
host/PowerShell 策略漂移；安装封装的静态门禁还要求同版本重装前使 marker
失效。EDID 测试还会向
EDID 注入额外 CTA VIC、CTA DTD、Established/`0xf7` 模式和 CTA flags，要求写 guest
前失败；目录侧另注入
1366×768、2560×1440 和未审核 75 Hz 首选模式负例。最后实际创建临时 VM，验证
随机和显式选择都只来自严格池。
