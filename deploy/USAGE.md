# 使用手册

新建 VM 请直接按
[`docs/VGPU-VM-CREATION.md`](docs/VGPU-VM-CREATION.md) 操作。它包含空盘安装、
真实 RTX6000-2Q PCI 身份安装 538.33、GTX1050 严格身份一键 ZIP 收尾、host
per-mdev 名称和 base 克隆的完整顺序。

## 入口脚本

本分支只有 NVIDIA mdev/vGPU 一套 VM 生命周期。`deploy/start-vm.sh` 是唯一
启动入口和实现，`deploy/stop-vm.sh` 是唯一停止与资源回收入口。native、
stream/relay 和 `--rdp` 只是同一 vGPU VM 的显示模式。

```
./deploy/start-vm.sh <vm_id> --install [iso]          # 缺盘自动空盘；默认跳 OOBE
./deploy/start-vm.sh <vm_id> --install [iso] --manual-oobe # 完整手动 OOBE
./deploy/start-vm.sh <vm_id> --spoof-name-only       # 通用安全 B + QEMU SDL 直显
./deploy/start-vm.sh <vm_id> --gtk --spoof-name-only # 相同 B 路径，改用 GTK
./deploy/start-vm.sh <vm_id>                         # 使用 vm.conf 已验收的持久模式
./deploy/start-vm.sh <vm_id> --legacy-shmem   # 旧 ivshmem + guest relay + SDL viewer
./deploy/start-vm.sh <vm_id> --rdp            # --legacy-shmem 的兼容别名
./deploy/start-vm.sh <vm_id> --no-tpm         # 仅诊断：关闭主板 profile 对应的 TPM
./deploy/finish-vgpu-install.sh <vm_id>              # 自动使用 staging token，一次性收尾
./deploy/stop-vm.sh  <vm_id>                  # 关 VM（Ctrl+C/关原生窗口也行）
./deploy/report-vm-boot-timing.sh <vm_id>      # 只读分段时间，不需 guest IP
```

## 镜像和配置放在哪里

生产 vGPU 路径采用每 VM 一个 bundle：

```text
/home/ubuntu/images/
├── iso/                 # Windows ISO
├── staging/             # 驱动和 guest 安装脚本
└── vms/
    ├── bases/           # win10-base.qcow2 + archive/
    ├── assets/          # host UI 共享资源
    ├── run/             # 全局 storage/start/disk 锁和迁移清单
    └── instances/vmN/
        ├── vm.conf
        ├── disk.qcow2
        ├── nvram.fd
        ├── tpm/state/   # 持久 TPM 1.2/2.0 NVRAM/EK 状态
        ├── log/{qemu,swtpm}.log
        ├── run/         # pid/qmp/monitor/mdev + swtpm socket/pid + 安装应答 ISO
        └── backups/{disks,nvram}/
```

旧平铺和上一版分类文件仍可读取，但新文件写入实例目录。全部 VM 停机后执行：

```bash
./deploy/migrate-vm-storage.sh --check
./deploy/migrate-vm-storage.sh --apply
```

迁移只接受可验证的 standalone qcow2；若任一待移动镜像带 backing、被其它
overlay 依赖或 metadata 无法解析，`--check` 会 fail-closed，必须先人工处理链。
依赖扫描也覆盖显式放在 `IMAGE_ROOT` 外的托管 disk/base 目录；`delete-vm.sh` 与
`promote-base.sh` 采用相同的 fail-closed 规则。

详细的停机保护、备份范围及历史平铺布局迁移规则见
[`docs/STORAGE-LAYOUT.md`](docs/STORAGE-LAYOUT.md)。

`start-vm.sh 1` 干的事（默认 native/SDL 模式）：

1. 校验 `swtpm`/QEMU/OVMF TPM 能力，按主板 profile 启动该 VM 独立的 TPM 1.2/TIS
   或 TPM 2.0/CRB daemon；缺依赖
   默认拒绝启动，不静默降级。安装命令：`sudo apt install swtpm swtpm-tools xorriso`。
2. 为该 VM 分配 NVIDIA mdev；R535 下先把默认 100 ms 的 console-copy 周期
   调为约 16.667 ms，再以 `display=on,ramfb=on` 挂入 QEMU。
3. QEMU 前台打开 SDL 窗口；ramfb 先显示 OVMF/驱动加载前画面，之后切到
   NVIDIA vGPU framebuffer。
4. 默认不挂 ivshmem，不启动 guest 抓屏 relay，不使用 RDP。
5. 键鼠直接走 QEMU 原生输入；`Ctrl+C`、关窗口或另一终端
   `./deploy/stop-vm.sh 1` 都会关闭 QEMU 并释放该 VM 的 mdev。
6. 可见窗口以 `16,666,667 ns` 绝对 deadline 提交（目标 60 FPS），
   标题实时显示 `SDL Present xx.x FPS`；隐藏或
   最小化时自动降频。这里显示的是 host Present 频率，不是 guest 独立帧数。
   静止 REGION 帧会被精确去重，因此桌面不变时显示 `0.0 FPS`；
   像素变化后自动恢复提交。

`--gtk` 仍走同一条 vGPU REGION 路径，但 GTK 标题没有 SDL 专用的 Present 计数器。
Wayland 下它由 GDK/合成器调度；是否更流畅应结合授权前后的 FRL 比较，不能只看标题。

默认直显不需要 `ivshmem.sys`、`NvStreamSvc`（旧 relay）或
`AudioSvcHost`。guest 仍必须安装与 host/profile 匹配的 NVIDIA GRID vGPU
驱动并完成授权；它们是 vGPU 工作所必需，并非抓屏/远程桌面组件。

宿主 NVIDIA 535 REGION 不提供 guest 硬件光标的 shape/visible 元数据，
所以桌面默认显示 Windows 箭头 fallback。若游戏自己把光标画入
framebuffer，用 `Ctrl-Alt-C` 切换到 `Cursor: framebuffer (host hidden)` 模式，
宿主固定箭头会被隐藏；再按一次恢复。该模式不会修改 guest。

当前 host NVIDIA 535 驱动只提供 VFIO display REGION，不提供 DMA-BUF，
因此这里不是零拷贝显示：QEMU 读取 REGION 后交给 SDL/GTK。它省掉的是 guest
抓屏、tile diff、共享内存 ring 和输入 relay。

R535 默认的 `intervaltime` 和 `vgaintervaltime` 都是 `100000 us`，会让
console REGION 只有约 10 个独立画面/秒，即使 QEMU 已按 60 Hz 查询。启动器在
QEMU 打开 mdev 前将两者设为 `16667 us`。这是 R535 内部、非正式接口：
`VGPU_CONSOLE_INTERVAL_US=0 ./deploy/start-vm.sh 1` 可关闭；换 host driver 后应
重新做动态帧率验证。mdev 打开后 R535 会拒绝运行期改值，所以最小化只能减少
QEMU/SDL Present，不能把 manager 的 copy 周期动态降回 10 Hz。请勿设置
`disable_vnc=1`，它会一并关闭 SDL 依赖的 console REGION。

## 新建 VM：固定 2GB 的 NVIDIA 显卡池

日常入口会自动生成持久配置和磁盘；完整规则见
[`docs/VGPU-VM-CREATION.md`](docs/VGPU-VM-CREATION.md)：

```bash
# 有合格 base：自动生成配置、clone 系统盘并启动
./deploy/start-vm.sh 1

# 从 ISO：自动生成配置、创建空盘；默认跳 OOBE，使用空密码 Administrator，
# 中国大陆简体中文/China Standard Time，并默认开启 guest NumLock；RTC 由宿主处理
./deploy/start-vm.sh 2 --install /home/ubuntu/images/iso/win10.iso

# 需要人工选择区域和账号时才关闭自动 OOBE
./deploy/start-vm.sh 2 --install /home/ubuntu/images/iso/win10.iso --manual-oobe

# 只有需要预选身份时才先显式 create-vm
./deploy/create-vm.sh --list-gpu-profiles
./deploy/create-vm.sh --list-monitor-profiles
./deploy/create-vm.sh --list-ssd-profiles
./deploy/create-vm.sh 3 --gpu-profile gtx1050_2gb
```

平台、主板/BIOS、DIMM 料号/插槽、TPM 版本是绑定 profile，不再独立乱数
拼装。存储选择先比较主板 M.2 与 SSD 的 PCIe 代际/通道：B150/B360 默认
优先从 Samsung 970 PRO 与 WD Black 的 Gen3 x4 NVMe 层选择；DDR3 的 H97 板载 M.2 只有
10 Gb/s，不能与该 Gen3 x4 endpoint 混搭，因此从 Samsung 840/850/860 PRO、
Crucial MX100、Kingston KC400、Intel 545s、Western Digital PC SA530 的
512GB SATA 6Gb/s 池中选择。根流程已移除全部 500GB 可选 profile；当前九个
型号（七个 SATA、两个 NVMe）
均为精确 `512110190592` 字节；已持久化的旧 500GB 配置仍可启动，但不会再被
新建 VM 抽中。新配置也会持久化并传递逻辑/物理扇区：MX100 为
`512/4096`，当前其余型号为 `512/512`。显式 `--ssd-profile` 仍可在兼容层内
选择 SATA。qcow2
virtual-size 必须与 `SSD_SIZE_BYTES` 完全一致；
`--force` 不会跨容量/接口重绑旧盘，也不会把已生成的 TPM 状态换到
另一块主板。这类迁移应备份 BitLocker 恢复密钥后用新 VM_ID 或显式
的磁盘/TPM 迁移流程。

新配置还会持久化一组已审核的 USB 键盘和绝对坐标指针身份；创建与启动摘要
都打印“键盘/鼠标”两行。QEMU 实际挂载一个 `usb-kbd` 和一个
`usb-tablet`，并关闭默认 i8042/PS/2 键鼠，避免 guest 重复枚举输入设备；
后者保留无需相对鼠标 grab 的窗口行为。旧配置稳定回退为
Microsoft Wired Keyboard 600（045E:0750）与 HUION PenTablet（256C:006D），
不会在每次启动时重新抽取。

> 边界：上述主板是 SMBIOS/SPD/设备身份 profile；当前 QEMU machine
> 功能模型仍是 `q35`/ICH9，并非完整仿真 H97/B150/B360 PCH。不应把
> `BOARD_CHIPSET` 理解为已实现所有对应 PCH 寄存器/驱动行为。

新建 VM 的显示器池固定为 16 个在中国大陆常见的 23.8/24 英寸
1920×1080 型号（Samsung、Dell、BenQ、AOC、Philips、Lenovo、ASUS、
Redmi）。默认先等概率抽品牌，再在该品牌内抽具体型号，避免型号较多的品牌天然
占更高概率。`--monitor-profile` 也只能指定这个池中的型号。

池中只有 NVIDIA GTX 750 Ti、GT 1030、GTX 1050，且每项都是 2048MB；普通
GTX 750 参考版标准显存是 1GB，因此严格 2GB 池使用 GTX 750 Ti。AMD 不能加入
这条池，因为底层是 NVIDIA GRID driver、NVIDIA mdev 和 NVAPI。

`instances/vmN/vm.conf` 中的 `GPU_*` 是每 VM 的客户机身份，`VGPU_MDEV_PROFILE`
是 RTX 宿主的 `nvidia-257` fallback。实际资源可由宿主配置的
`VGPU_RESOURCE_PROFILE` 覆盖（例如 V100-2Q），但必须与当前 guest 身份同为
2048MB。

启动器默认在宿主机完成产品名同步：它复用持久化的 `VM_UUID` 作为 mdev UUID，
并在创建 mdev 前原子维护 `/etc/vgpu_unlock/profile_override.toml` 中对应的
`[mdev."UUID"]`，写入 `card_name` 和 `adapter_name`。因此不同 VM 即使共用
`nvidia-257`，NVIDIA 控制面板“系统信息”仍可得到各自的 `GPU_NAME`；guest 里
无需安装名称代理 DLL、服务或常驻程序。`SPOOF_MODE=off` 会移除该 VM 的名称项。

这个 host-only 覆写只改变产品名称，不会改 CUDA 核心数、核心频率、显存类型或
总线位宽；这些字段仍可能暴露宿主物理卡特征。`sync-vgpu-profile.sh` 只用于修复旧
模板残留的 guest 注册表/启动任务。只有 host/driver 组合不接受 per-mdev 名称时，
才显式加 `--with-nvapi-shim` 使用会替换 Windows NVAPI DLL 的兼容回退。

旧文档所说的“加入三个”不是挂三张卡。当前 audited 工具链只加入 GTX1050 的
`DEV_1C81/SUBSYS_11C01028`；GTX750Ti/GT1030 没有等价严格包，继续 B。不要运行旧
`guest/spoof-inf` 实验脚本；以 [`docs/DRIVER-INSTALL.md`](docs/DRIVER-INSTALL.md)
的锁定构建器与一键 ZIP 为准。

### 旧 relay 模式的自动 setup

下面的 setup-task 和 guest service 只在显式传入 `--legacy-shmem` / `--rdp`
时运行；它们不是默认直显的依赖。GNOME 快捷键 guard 同时支持默认原生 SDL：
仅在窗口聚焦且鼠标位于窗口内时临时放行 `Super`/`Alt+Tab`，失焦立即恢复。

#### setup-task 决策矩阵（仅旧模式）

| 检测到的 guest 状态 | 动作 |
|---|---|
| driver 版本 ≠ `31.0.15.3833` | SPOOF_MODE=A: 警告“用 --no-spoof 重启装 driver”；B/off: 跑 `setup-guest` 装 |
| driver 完整但 `Win32_VideoController` Error 43 + 未 Licensed | 跑 `install-vgpu-license.sh` 装 token + 重启 license daemon |
| service 装着但 stopped | `Start-Service NvDisplayContainer` |
| service 没装 | 跑 `setup-guest --skip-vgpu --skip-ivshmem --skip-stealth --skip-monitor` |
| 全 OK (sys+ver+lic+svc) | 跳过 |

## SPOOF_MODE：方案 A / B / off

```bash
./deploy/start-vm.sh 1                       # 新配置/脚本 fallback 均为 B
./deploy/start-vm.sh 1 --spoof-name-only     # B
./deploy/start-vm.sh 1 --no-spoof            # off
./deploy/start-vm.sh 1 --spoof-mode A         # 仅调试；未完成 V3 receipt 会拒绝
```

| 方案 | PCI vendor/device/subsys | 名称来源 | driver 工作？ | 反虚拟化效果 |
|---|---|---|---|---|
| **A** | 外部 PCI + 可选 NVIDIA internal tuple | vm.conf 选定型号 | 当前仅 GTX1050 + patched 538.33 audited | GTX1050 严格路径 |
| **B** | 真 RTX 6000 (`DEV_1E30`) | host 按 mdev UUID 提供 vm.conf 选定型号 | 最稳；guest 无名称代理 | GPU-Z 等查 PCI ID 会暴露 |
| **off** | 真 RTX 6000 | 驱动/mdev 原生名称（全局 type 配置仍会影响它） | 最稳 | 完全不隐身（装 driver 阶段必用） |

原版 driver 安装阶段使用 `--no-spoof`。GTX1050 随后由
`finish-vgpu-install.sh` 的 ZIP add-only 预暂存消费 ID 包，V3 回执验证后才切 A；
不要手工写只读配置。当前稳定组合是 host 535.161.05 + guest 538.33。

## setup-guest 7 步详情（旧 relay 模式）

```bash
./deploy/setup-guest.sh <vm_id>
```

| 步 | 干啥 | 控制 flag |
|---|---|---|
| 1 | 当前基线 GRID 538.33 driver（卸 NVIDIA INF + 拷文件 + 装 + 写注册表 block WU 替换） | `--skip-vgpu` |
| 2 | License token (从 host fastapi-dls 拉 + 推到 guest token 路径 + Restart NVDisplay daemon) | `--skip-license` |
| 3 | ivshmem.sys driver（默认直显不需要） | `--skip-ivshmem` |
| 4 | NvDisplayContainer 服务 + nv_stream_relay + AudioSvcHost（默认直显不需要）；注册表 `DesktopWidth/Height=1920/1080` + `FrameRate=60` | `--skip-service` |
| 5 | 可选旧 guest 修复：同步注册表名称/规格并创建 RefreshGridNames；默认不装 NVAPI shim | `--with-guest-identity` 启用 |
| 6 | 默认跳过；仅 `--online-monitor-rescue` 时一次性运行救援脚本 | `--skip-monitor` |
| 7 | 输入设备名称 cosmetic spoof | `--skip-input` |

可选自定义：
```bash
./deploy/setup-guest.sh 1 --with-guest-identity --gpu-name "GeForce GTX 1050"
./deploy/setup-guest.sh 1 --online-monitor-rescue --monitor dell-p2419h
./deploy/setup-guest.sh 1 --skip-vgpu --skip-ivshmem      # 重跑只刷 service + spoof
```

单独传 `--monitor` 只选择救援型号，不会进入 guest；必须同时显式传
`--online-monitor-rescue` 才会临时下载并执行脚本，执行结束（含失败路径）会删除临时文件。

> **注意**：默认直显只需要第 1、2 步对应的 NVIDIA GRID 驱动和授权；可以分别
> 用 `install-vgpu-driver.sh` / `install-vgpu-license.sh` 完成，不必安装第 3、4 步。

## 显示器型号与 Windows 分辨率

`config/monitor-profiles.tsv` 收录 23 个可回查的真实 EDID 样本；其中
`config/monitor-create-cn-fhd.txt` 严格列出 16 个新建 VM 候选。每项包含真实 PNP
vendor/product ID、EDID 名称、物理尺寸、生产周/年、video-input、扫描范围和像素
时钟，不再用“只换品牌字符串”的合成 EDID。完整目录继续用于旧 VM 兼容，
不会因默认池收紧而让已有配置失效。

`create-vm.sh` 把 `MONITOR_BRAND_NAME`、`MONITOR_MODEL_NAME`、
`MONITOR_DISPLAY_NAME`、PNP、尺寸、扫描范围、生产日期和序列号整组写入
`instances/vmN/vm.conf`，同一 VM 重启不会重新随机。

NVIDIA R535 mdev 没有 `VFIO_GFX_EDID_REGION`，`start-vm.sh` 会在 QEMU
启动前按需离线刷新 Windows
SYSTEM hive 中已有的 EDID/模式缓存；这一步不向 guest 复制脚本、不安装服务、
不创建计划任务。已有 VM 可在关机后显式执行：

```bash
./deploy/sync-monitor-profile.sh 1
./deploy/sync-monitor-profile.sh 1 --monitor dell-p2419h --force
```

“关机”必须是禁用休眠/Fast Startup 后的完整关机。新装统一用宿主收尾脚本处理：

```bash
./deploy/finish-vgpu-install.sh N
```

宿主会弹出本地 SDL 救援窗口，并按 profile 生成或复用私有收尾包。GTX1050 使用
`/home/ubuntu/images/staging/VgpuGuestFinish-GTX1050.zip`：传入 Windows 后必须完整
解压，只以管理员运行其中唯一的 EXE；其他 profile 使用小
`/home/ubuntu/images/staging/VgpuGuestFinish.exe`。工具会动态适配当前 VM、处理
driver/token、关闭休眠/Fast Startup 并完整关机，宿主严格校验 UUID/GPU/token；
GTX1050 还必须通过 V3 driver 回执才会继续。同一 DLS 的受信任 VM 可复用缓存产物，
但宿主命令仍需逐 VM 运行。不使用 VNC、RDP、WinRM 或 guest HTTP。需要 GTK 救援
窗口时加 `--rescue-gtk`。

NVIDIA 路径得到正常的 60 Hz FHD 向下兼容列表：1920×1080、1680×1050、
1600×900、1440×900、1360×768、1280×1024/960/800/768/720、1024×768、
800×600、640×480。最高分辨率固定为 1920×1080，不声明 1920×1200、2K
或 4K；较低兼容分辨率仍保留给 Windows 和老应用。

## 日常工作流

```bash
./deploy/start-vm.sh 1                    # 使用 vm.conf：严格 GTX1050 或通用 B
# 或：./deploy/start-vm.sh 1 --gtk
# 产品名由 host per-mdev override 自动提供；新 clone 不需要 WinRM 同步
# ... 用 ...
# Ctrl+C / 关 QEMU 窗口 / 另一终端 ./deploy/stop-vm.sh 1
```

第一次装 GRID 驱动时应保留真实 vGPU PCI ID：

```bash
# 先用真实 PCI 身份安装匹配的 GRID driver
./deploy/start-vm.sh 1 --no-spoof --no-monitor-sync

# driver 装好并完整关机后，只运行这一条宿主命令
./deploy/finish-vgpu-install.sh 1
```

GTX1050 会生成 `/home/ubuntu/images/staging/VgpuGuestFinish-GTX1050.zip` 并打开
本地 SDL 救援。传入后必须“全部解压”，只运行其中 EXE；它先预暂存 locked 538.33，
再完成原有收尾。其他 profile 仍使用小 EXE 并保持 B。包内含 token，不能由 staging
HTTP server 下载或公开分发。
详见 [`docs/VGPU-LICENSING.md`](docs/VGPU-LICENSING.md)。

RTC 由宿主统一提供：QEMU 进程使用 `TZ=Asia/Shanghai` 和
`-rtc base=localtime,clock=host,driftfix=slew`。新装不写
`RealTimeIsUniversal`。旧 UTC VM/base 也运行 `finish-vgpu-install.sh`：它会先按旧
契约兼容启动，guest 完整关机后由宿主备份 SYSTEM、离线删除旧 DWORD，并写入
`RTC_CONTRACT=localtime`。不要在 guest 内运行旧 `fix-rtc-utc.ps1`。

新 GTX1050 先写 B + `full-consumer` 目标；一键收尾的 V3 回执通过后才自动持久化
A/internal=1/FRL=0。GTX750Ti/GT1030 保持 B。完整边界见
[`docs/DRIVER-INSTALL.md`](docs/DRIVER-INSTALL.md)。

默认 native 路径没有 stream service 可停。只有使用旧 `--legacy-shmem` 时，
才用 `./deploy/service.sh 1 stop`、`start`、`status` 或 `restart` 控制 relay。

## 调试

| 现象 | 看哪 / 怎么 |
|---|---|
| OVMF/Windows 前期无画面 | 确认启动参数含 `vfio-pci-nohotplug,...,display=on,ramfb=on`，并使用仓库默认 OVMF |
| ramfb 有画面、进系统后黑屏 | guest 检查 NVIDIA GRID 驱动版本、设备 Error 43 和 license 状态 |
| 普通按键无响应 | 检查 QEMU 窗口焦点；键盘只依赖 input focus，不经过 guest relay |
| `Super`/`Alt+Tab` 被宿主吃掉 | 确认启动时打印“SDL 宿主快捷键保护已启用”，且没有传 `--no-tame-gnome` |
| 动态拖动稳定只有约 10 FPS | 检查启动日志是否有 `R535 console REGION 周期=16667us`；确认未将 `VGPU_CONSOLE_INTERVAL_US` 设为 0 |
| GTK 标题没有 FPS | 正常；`SDL Present` 只在 SDL 后端实现。用 host license/FRL 和实际 frame-time 判断 |
| 动态画面卡在 3/15 FPS | B/off 检查 DLS/Licensed；严格 GTX1050 检查 `Frame Rate Limit: N/A`、Code 0 和精确 PCI tuple，不把 Unlicensed 写成已激活 |
| 重启后先报无法获取 license，且一直不恢复 | 查 guest NVIDIA 日志是否反复出现 `Clock windback has been detected`；完整关机后运行 `finish-vgpu-install.sh`，由宿主离线迁移 RTC，再重新授权 |
| SDL 动态帧率低于约 55 FPS | 确认窗口未最小化；看 host `nvidia-smi vgpu -q` 的 license/FRL 和 CPU/GPU 负载 |
| 旧 relay 黑屏 | `./deploy/service.sh 1 status` 看服务；再检查 `/dev/shm/nv-shmem-vm1` |
| 旧 relay 输入问题 | `STREAM_DEBUG=1 ./deploy/connect.sh 1` 查看 SDL/RFB trace |

## 数据通路

默认 native 路径：

```
NVIDIA mdev/vGPU ─VFIO display REGION→ QEMU ─→ SDL（默认）/ GTK（--gtk）
                                              │
host keyboard/mouse ─QEMU native input────────┘→ guest
```

无 guest 抓屏、无 ivshmem、无 relay、无 RDP。host 535 的 REGION 路径不是
DMA-BUF/零拷贝。

旧 `--legacy-shmem` / `--rdp` 路径：

```
guest:
  vGPU desktop ─DDA→ D3D11 staging ─Map→ BGRA bytes
                                          │
                                          ▼ FNV-1a tile hash 与上一帧对比
                                          │
                                          ▼ dirty 32×32 tiles → ivshmem video ring
                                          │
host:                                     │ (KVM 直接 page mapping，纯 RAM-to-RAM)
                                          │
  /dev/shm/nv-shmem-vmN ◄─────────────────┘
       │
       └─ stream_client_dda (SDL2): SDL_UpdateTexture per dirty tile + present
       └─ X11 input events (key + mouse) ─→ ivshmem input ring
                                                    │
                                                    ▼ guest
                                                AudioSvcHost (local 127.0.0.1)
                                                    │
                                                    ▼ Win32 SendInput
                                                guest desktop
```

旧路径仍是零 mpv / ffmpeg / NVENC / 编解码库 / TCP listener（除 service 内部
127.0.0.1 短连），但它需要额外的 guest driver/service；默认路径完全绕过它。

## 其它工具

| 命令 | 用途 |
|---|---|
| `./deploy/install-vgpu-driver.sh 1` | 单独重装 vGPU 驱动 |
| `./deploy/install-ivshmem-driver.sh 1` | 旧 relay 路径：单独装 ivshmem driver |
| `./deploy/install-nv-service.sh 1` | 旧 relay 路径：单独刷 service binary |
| `./deploy/create-vm.sh <vm_id>` | 生成 `$VM_ROOT/instances/vmN/vm.conf`（一次性） |
| `./deploy/create-disk.sh <vm_id> --from-base` | 严格克隆公共 base；不存在则失败，不退回空盘 |
| `./deploy/finish-vgpu-install.sh <vm_id>` | 自动使用 staging token，生成单 EXE并本地救援；完成休眠、RTC/EDID 收尾 |
| `./deploy/sync-monitor-profile.sh 1` | 关机状态从 host 离线同步显示器 EDID；guest 无常驻组件 |
| `./deploy/sync-vgpu-profile.sh 1` | 可选：清理/同步旧 guest 的注册表身份；默认不安装 NVAPI shim |

## 常见坑

- **vGPU 显示 Error 43**：8/14/2024 之后的 GeForce DCH driver 在 vGPU passthrough 上拒绝工作。`./deploy/install-vgpu-driver.sh 1` 能完成 wipe + 重装当前基线 GRID 538.33（staging 仍沿用历史文件名 `553.24`）。
- **显示器同步报 `Windows is hibernated` / vGPU 恢复报 0x10E**：不要用 host 强删 `hiberfil.sys`。运行 `finish-vgpu-install.sh N`，在本地救援窗口中手动传入并以管理员运行生成的 EXE；它完整关机后，宿主会自动重试。详见 [`docs/VGPU-RECOVERY-RUNBOOK.md`](docs/VGPU-RECOVERY-RUNBOOK.md)。
- **重启后 NVIDIA 授权长时间不恢复**：若 guest 日志持续报告
  `Clock windback has been detected`，让 Windows 完整关机，再运行
  `finish-vgpu-install.sh` 由宿主离线迁移 RTC；不要写
  `RealTimeIsUniversal` 或运行旧 RTC guest 脚本。详见
  [`docs/VGPU-LICENSING.md`](docs/VGPU-LICENSING.md)。
- **vGPU mdev 分配失败** (`mdev_allocate failed`)：多半 sudo 没暖。`SUDO_PASSWORD=123456 ./deploy/start-vm.sh 1`。
- **磁盘满** (`/dev/nvme0n1p3 100%`)：guest qcow2 写阻塞 → boot 卡。检查 `vms/instances/vmN/backups/` 和 `vms/bases/archive/`；前两代布局尚未迁移时再检查 `vms/disks/`、`vms/nvram/` 与 `vms/` 根目录。
- **ivshmem 已被占** (relay 反复 `REQUEST_MMAP failed: 548`)：旧 relay 孤儿没退。NvDisplayContainer 启动会自动 kill 同名孤儿；手动可 `./deploy/service.sh 1 restart`。
