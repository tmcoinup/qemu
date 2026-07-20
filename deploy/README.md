# gmate（QEMU v11.0.2）反虚拟化 + vGPU 拆分工程

`gmate` 的默认生产路径是 NVIDIA mdev/vGPU 直显：`deploy/start-vm.sh`
分配 vGPU，以 `vfio-pci-nohotplug,display=on,ramfb=on` 挂入 guest，并由
QEMU SDL 直接显示。`ramfb` 提供 OVMF 和 NVIDIA 驱动接管前的早期画面；
驱动就绪后窗口切到 vGPU framebuffer。`--gtk` 可把窗口后端换成 GTK。
默认入口按主板 profile 启动每 VM 独立的 `swtpm`：TPM 1.2 使用 `tpm-tis`，
TPM 2.0 使用 `tpm-crb`，不支持 TPM 的 profile 自动关闭；显式 `--no-tpm`
（或 `TPM=0`）仍可覆盖。

## 生命周期入口与显示模式

本分支只有 NVIDIA mdev/vGPU 一套 VM 生命周期，启动和停止入口固定为：

```bash
./deploy/start-vm.sh <vm_id> [--vm-dir ABS|--instances-dir ABS] [options]
./deploy/stop-vm.sh <vm_id> [--vm-dir ABS|--instances-dir ABS] [--force]
```

`start-vm.sh` 直接实现 vGPU 的配置、磁盘、mdev、TPM、QEMU 和显示生命周期；
`stop-vm.sh` 负责同一 VM 的优雅关机、强制停止和资源回收。以下显示方式均属于
这一生命周期内部的运行模式：

默认 G-11 bundle 是 `/home/ubuntu/images/vms/G-11/vm<ID>`。先用
`./deploy/start-vm.sh ID --print-paths` 无副作用核对；完整默认/指定路径和停机
迁移教程见
[`docs/STORAGE-PATHS-QUICKSTART.md`](docs/STORAGE-PATHS-QUICKSTART.md)。

| 显示模式 | 启动方式 | 说明 |
|---|---|---|
| native SDL | `./deploy/start-vm.sh N` | 默认；QEMU 直接显示 NVIDIA vGPU framebuffer |
| native GTK | `./deploy/start-vm.sh N --gtk` | 与默认模式使用同一 vGPU 数据通路 |
| native + ROI 推流 | `./deploy/start-vm.sh N --stream URL [--stream-roi X,Y,W,H]` | 保留 SDL/GTK 窗口，并行输出显式网络目标或本地文件 |
| stream/relay | `./deploy/start-vm.sh N --legacy-shmem` | vGPU 桌面经 guest relay 和共享内存送到外部 SDL viewer |
| RDP 别名 | `./deploy/start-vm.sh N --rdp` | 与 `--legacy-shmem` 相同，保留现有调用方式 |

默认路径不挂 ivshmem，不启动 guest 抓屏 relay，不使用 RDP，也不需要
`ivshmem.sys`、`NvStreamSvc`（旧 relay）或 `AudioSvcHost`。它仍然需要 guest 内安装
与 host/profile 匹配的 NVIDIA GRID vGPU 驱动并完成授权；这是 vGPU 本身的
驱动要求，不是画面转发软件。

当前 host NVIDIA 535 驱动暴露的是 VFIO display **REGION**，没有 DMA-BUF，
所以这条直显路径不是 GPU framebuffer 零拷贝。画面由 QEMU 读取 REGION 后交给
SDL/GTK，但键鼠直接走 QEMU 原生输入设备，不经过共享内存 input ring 或 relay。

Tesla V100 的无卡预适配已把宿主 BDF、mdev type 和显存容量从 guest
身份中拆开；配置方法与实卡到位后的必验项见
[`docs/V100-ADAPTATION.md`](docs/V100-ADAPTATION.md)。

新建 VM 的单线教程见
[`docs/VGPU-VM-CREATION.md`](docs/VGPU-VM-CREATION.md)：它明确区分空盘安装和
base 克隆，并覆盖“真实 RTX6000-2Q PCI 身份装驱动 → 对齐消费卡身份”的完整顺序。
客户端 token、授权地址迁移和严格验收见
[`docs/VGPU-LICENSING.md`](docs/VGPU-LICENSING.md)。
已有 VM 的休眠恢复、离线 EDID 与设备管理器名称持久化见
[`docs/VGPU-RECOVERY-RUNBOOK.md`](docs/VGPU-RECOVERY-RUNBOOK.md)。
G-11 的 host/guest、驱动、推流和零拷贝支持边界统一记录在
[`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md)；其中明确区分 upstream QEMU
源码能力和本分支已经验收的产品能力。

第一次处理现有 vGPU VM，直接按
[`docs/G11-QUICKSTART.md`](docs/G11-QUICKSTART.md) 的中文傻瓜教程操作。当前
主流程是一个无 VM 绑定的离线 `VgpuPortable.exe`、一次性安全注入 Windows base，
再从 base 克隆任意 B/native VM；历史 A → B 才保留按 VM 迁移和关机提交。

## 入口脚本（host）

| 命令 | 干什么 |
|---|---|
| `./deploy/vmctl.sh {path\|start\|stop\|status} <vm_id> [...]` | 路径感知的傻瓜封装；默认路径与 `--vm-dir`/`--instances-dir` 都透传到唯一生命周期入口 |
| `./deploy/vmctl.sh migrate [--check\|--apply]` | 旧 G-11 `instances/vmN` 到新命名空间的一键检查/迁移 |
| `./deploy/start-vm.sh <vm_id> --install [iso]` | 缺配置时自动生成身份，缺盘时固定建空盘；挂 Windows ISO + 最小应答 ISO，默认跳过 OOBE，以空密码 `Administrator` 首次登录并设置中国时区和 NumLock；RTC 由宿主处理 |
| `./deploy/start-vm.sh <vm_id> --install [iso] --manual-oobe` | 同一安全建盘语义，但不挂应答 ISO，完整手动完成 OOBE |
| `./deploy/start-vm.sh <vm_id> --spoof-name-only` | 通用安全 B：保留 PCI 真身，host 按 mdev UUID 提供每 VM 产品名，前台打开 QEMU SDL 原生窗口 |
| `./deploy/start-vm.sh <vm_id> --gtk --spoof-name-only` | 同一条 B 路径，改用 QEMU GTK 窗口 |
| `./deploy/start-vm.sh <vm_id>` | 缺配置时自动生成身份，缺盘时严格从公共 base clone；默认 required CPU 隔离，成功后才放行 guest；新配置及当前支持的三款 profile 均保持 B，legacy GTX1050 strict-A transition 已禁用 |
| `./deploy/start-vm.sh <vm_id> --proxy` | 启用 QEMU 原生 QMP 多客户端；主 `qmp.sock` 与 `.proxy` 兼容别名均可供多个 host 工具并发连接，不是 HTTP/SOCKS 或 guest 网络代理 |
| `./deploy/start-vm.sh <vm_id> --no-tpm` | 明确关闭该主板 profile 的 TPM；只用于兼容/诊断 |
| `./deploy/start-vm.sh <vm_id> --cpu-isolate` | 与默认行为相同：CPU 隔离 required，vCPU 1:1 绑核完成前 guest 保持暂停，失败即终止 |
| `./deploy/start-vm.sh <vm_id> --stream URL --stream-roi X,Y,W,H` | native SDL/GTK 加固定 ROI 网络推流；默认 `libx264` + SHM，不创建监听端口 |
| `./deploy/fb-shm-stream.sh {status\|health\|stop} <vm_id>` | 查看或单独停止该 VM 的编码 sidecar；正常关 VM 会自动回收 |
| `./deploy/start-vm.sh <vm_id> --legacy-shmem` | 旧 ivshmem + guest relay + 外部 SDL viewer 路径；`--rdp` 是兼容别名 |
| `./deploy/package-vgpu-one-click.sh` | 推荐主入口：生成同时包含全部已审计 profile、无 VM ID/UUID、完全离线的 `VgpuPortable.exe` |
| `sudo ./deploy/install-vgpu-portable-to-base.sh` | 停止所有 VM 后，把 portable EXE 写入 base 的私有临时副本，验证 NTFS/qcow2 后归档旧 base 并原子替换 |
| `./deploy/clone-vgpu-base.sh <vm_id> --gpu-profile PROFILE [--start]` | 创建新的 B/native 配置和 UUID，从已验签的 portable base 克隆独立系统盘；guest 安装后无需 host commit |
| `./deploy/package-vgpu-one-click.sh <vm_id>` | legacy 兼容入口：A 生成按 VM 绑定的完整生产驱动迁移 EXE；B 生成旧的按 VM 绑定 GPU-Z 包 |
| `./deploy/package-gpuz-profile.sh <vm_id> [...]` | legacy B 的 VM/UUID 绑定 GPU-Z 打包器；新 base/clone 不使用 |
| `./deploy/package-vgpu-production-migration.sh <vm_id>` | 为 legacy A 实例生成一个 VM/UUID/型号绑定的 guest EXE，内嵌未修改 GRID 538.33 与 GPU-Z 子包 |
| `sudo ./deploy/commit-vgpu-production-migration.sh <vm_id>` | guest EXE 完整关机后，从一次性 NBD snapshot 只读核验 staged 回执，再原子提交 B/native 配置；不写 Windows 磁盘或 BCD |
| `./deploy/finish-vgpu-install.sh <vm_id>` | legacy B 模式 token/RTC 收尾；GTX1050 strict-A 自签路径已硬禁用，会在生成 guest 包或写 marker 前拒绝 |
| `./deploy/stop-vm.sh <vm_id>` | 关 VM (另一终端用 / start-vm.sh 退出后兜底) |
| `./deploy/report-vm-boot-timing.sh <vm_id>` | 只读汇总本次 host boot 里的 vGPU start、display init、guest driver 和 license 时间；不依赖 guest IP |
| `./deploy/service.sh <vm_id> {stop\|start\|status\|restart}` | 仅旧 relay 路径使用的 guest 服务控制 |

`setup-guest.sh` / `connect.sh` 仍然在，供旧共享内存路径调试；默认直显不调用它们。
普通新实例优先只使用 `start-vm.sh N`；第一次制作 base 才使用
`start-vm.sh N --install [ISO]`。完整自动创建规则和 guest 最小化边界见
[`docs/VGPU-VM-CREATION.md`](docs/VGPU-VM-CREATION.md)。

只允许正式生产签名、明确禁止自签名/测试签名的 guest，应使用
[`docs/GPUZ-ONE-CLICK.md`](docs/GPUZ-ONE-CLICK.md) 的 portable B/native 流程。
默认产物为
`$STAGE_DIR/VgpuPortable/VgpuPortable.exe`，同时内嵌 GTX 750 Ti、GT 1030、
GTX 1050 三套已审计 profile，不含 VM ID/UUID，也不依赖 HTTP。每次
`start-vm.sh` 会按新 clone 的配置自动发布只读 SMBIOS profile/UUID/catalog
声明；guest 严格核对声明、原生 `DEV_1E30`、Code 0、538.33、生产签名链、BCD 和
单 Display 后才应用对应型号。因此同一个 EXE 可放进 base 供任意 VM 克隆使用，
但不能在 guest 内任意选型号。正常 B/native portable 安装后没有人工 host
commit。

base 注入必须在全部 VM 停止、Windows 完整关机且 NTFS 非 dirty/hibernated 时
执行。脚本不直接挂载 live base，只修改临时副本并在完整验证后原子替换。历史
GTX1050 严格收尾会修改 INF/使用本地自签 catalog，不属于生产路径，不能用开启
`testsigning` 或安装私有根证书来绕过；旧 A 实例继续按 VM/UUID 绑定迁移。

VM3 已按
[`docs/VGPU-PRODUCTION-MIGRATION.md`](docs/VGPU-PRODUCTION-MIGRATION.md)
完成 B/native 迁移：未修改 GRID 538.33 提供真实 NVIDIA/Microsoft 签名链，
设备管理器为 GTX 1050、Code 0，GPU-Z 2.70 为同一型号且显示 WHQL。旧自签 driver
package 和私有测试证书已在生产驱动验收后移除。新增 GPU 型号先审计唯一 identity
catalog，不按 VM 编号写分支，也不能靠猜测字段、BCD 测试选项或自签内核驱动适配。

## 工作流

**首次部署 / driver 未装**：用 vGPU 真 PCI ID 启动，安装与 host vGPU
branch/profile 兼容的 GRID guest 驱动。驱动接管前仍可从 `ramfb` 窗口操作。当前
稳定基线是 host 535.161.05 + guest 538.33；staging 中历史误名为 `553.24` 的
资产必须先按新建教程核对 hash 和 INF DriverVersion。驱动装好后，非 GTX1050
strict-A 的 legacy B 模式可用一个宿主命令完成 token/RTC 收尾：

```bash
# Windows 已装好 GRID driver 并完整关机后，在宿主执行一次
./deploy/finish-vgpu-install.sh 1
```

GTX1050 strict-A 旧流程会修改 INF 并自签 catalog，现已硬拒绝。旧 A 实例改用
`package-vgpu-production-migration.sh`：Windows 用户只运行一个 EXE 一次，首次
关机后宿主核验回执并提交 B；开机任务自动绑定锁定的原始 538.33、验证 Code 0/
生产签名并应用 GPU-Z profile。不能用私有根、自签 catalog 或 BCD 测试选项替代。

**日常使用**：
```bash
./deploy/start-vm.sh 1                    # 使用 vm.conf 已验收的持久模式
# 临时安全回退：./deploy/start-vm.sh 1 --no-spoof --no-monitor-sync
# 新 clone 无需 WinRM/guest 名称同步
# ramfb 先显示固件/启动画面，随后 NVIDIA vGPU framebuffer 接管
# Ctrl+C / 关 QEMU 窗口 / 另一终端 ./deploy/stop-vm.sh 1 都能优雅关
```

默认 SDL 窗口使用 QEMU 原生输入。GNOME/Wayland 下，窗口聚焦且鼠标位于
窗口内时会临时把 `Super`、`Alt+Tab` 等宿主快捷键交给 guest；离开或失焦
立即恢复，可用 `--no-tame-gnome` 禁用。由于 NVIDIA 535 REGION 接口没有
独立 cursor plane，窗口内从 `$VM_ROOT/shared/assets/aero_arrow.cur` 选择 32×32 帧，
显示该 guest 自带的 Windows 默认箭头；资源缺失时才使用内置 fallback。
这个 REGION 不包含 guest 的 shape/hotspot/visible 元数据，因此桌面硬件
光标无法自动跟随 I-beam/缩放箭头变化。游戏把自定义光标画入主
framebuffer 时，按 `Ctrl-Alt-C` 可即时隐藏固定箭头；标题会显示
`Cursor: framebuffer (host hidden)`，再按一次恢复桌面箭头。该切换只改 host SDL，
不会在 guest 安装或写入任何内容。

R535 的 vGPU Manager 默认每 `100000 us` 才把 guest scanout 复制到 console
REGION 一次，所以仅提高 QEMU 的轮询率仍只有约 10 个新画面/秒。native 启动器会在
mdev 创建后、QEMU 打开前同时设置
`intervaltime=16667,vgaintervaltime=16667`，把这两个 console-copy 周期提高到约
60 Hz。它们是本机 R535 已验证的 NVIDIA 内部参数；非 R535 默认跳过，驱动升级后
需要重新验证。该参数只能在 mdev 未打开时设置，不能随窗口最小化动态切换；可用
`VGPU_CONSOLE_INTERVAL_US=0` 禁用并回到驱动默认值。

可见 SDL 窗口使用 `16,666,667 ns` 绝对 deadline 刷新，不再把
REGION/GL 处理耗时叠加到下一帧，目标匹配本机/vGPU 的 60 FPS 上限；最小化或
隐藏后降到 500 ms 以节省 host 开销。窗口标题中的 `SDL Present xx.x FPS`
是 QEMU 实际提交频率，不代表 guest 产生了同样数量的独立新帧（REGION 没有
damage/帧序号）。

`--gtk` 使用同一条 vGPU REGION 数据通路，但 GTK 标题目前没有 FPS 计数器；看不到
`SDL Present` 不表示帧率为 0。Wayland 下 GTK 由 GDK frame clock/合成器调度，体感
可能比 SDL 均匀。当前三款 profile 都保持 B/off，并检查 DLS、`Licensed`、Code 0
和正式签名 driver。历史 strict GTX1050 A 曾报告 `Unlicensed / FRL N/A`，但该
自签 transition 已禁用，不是当前验收路径。静止桌面标题为 0 FPS 是去重，不是
限帧；动态测试只能证明是否仍被 3 FPS 锁住，不能替代性能跑分。

NVIDIA REGION 还会逐行精确对比可见像素：静止桌面不再重复上传
纹理或 Present，小范围变化只上传连续脏行；连续全屏动态会
暂时进入 fast path，避免游戏每帧额外比较。标题在静止时正常显示
`SDL Present 0.0 FPS`，画面一变即在下一个 60 Hz poll 内恢复提交。
这仍是 REGION 系统内存复制加宿主 GL 上传，不是 DMA-BUF 零拷贝；一个持续变化的
1080p60 画面原始数据率约 `475 MiB/s`。

**spoof 切换**：
```bash
./deploy/start-vm.sh 1 --no-spoof          # off：装 driver / 调试用
./deploy/start-vm.sh 1 --spoof-name-only   # B：PCI 真身 + name spoof，driver 最稳
./deploy/start-vm.sh 1 --spoof              # legacy A 诊断：当前无可用生产签名 transition，会拒绝
```

新 GTX1050、GTX750Ti、GT1030 配置统一写
`SPOOF_MODE=B` 与 `VGPU_IDENTITY_TARGET=name-only`。不要直接向只读配置
`echo`。

默认数据通路：
```
NVIDIA mdev/vGPU ─VFIO display REGION→ QEMU ─→ SDL（默认）/ GTK（可选）
                                              │
host keyboard/mouse ─QEMU native input────────┘→ guest
```

无 guest 抓屏、无 ivshmem ring、无 relay、无 RDP。旧数据通路仍可用
`--legacy-shmem`（或 `--rdp`）显式启动。

## 本仓库的源码级改动

| 位置 | 改动 |
|------|------|
| `target/i386/cpu.h` | 新字段 `stealth_hypervisor` (X86CPU) |
| `target/i386/cpu.c` | 新属性 `x-hv-stealth`；gate `FEAT_1_ECX` 里的 HYPERVISOR bit；新增三个 CPU 模型 `Core-i5-4590` / `Core-i5-6500` / `Core-i3-8100` |
| `hw/smbios/smbios.c` | type 17 新增 `memtype` / `typedetail` / `width` / `totalwidth` / `rank` / `voltage` 选项，把 DDR 类型、位宽、Rank、同步属性和电压显式填进 SMBIOS；未指定时保持 QEMU 11 默认语义 |
| `hw/nvme/nvme.h` + `hw/nvme/ctrl.c` | NVMe 新增 `model=` 属性（默认 `QEMU NVMe Ctrl` 覆盖为 SSD 真实型号） |
| `hw/ide/atapi.c` | ATAPI INQUIRY 不再硬编码 `QEMU`/`QEMU DVD-ROM`。`-device ide-cd,model=...` 给出值时按空格拆分成 `vendor(8)+product(16)` 填入 SCSI INQUIRY 响应，Windows 里光驱显示真实型号如 `TSSTcorp CDDVDW SH-224DB` |
| `target/i386/cpu.c` | 新增 CPUID leaf `0x16` (Processor Frequency Info) 处理：从 tsc-freq 派生 base/max MHz + 100 MHz bus clock，让 Windows `Win32_Processor.CurrentClockSpeed` 与 brand string 一致（原 fallback=0 / OVMF 显示 2.00 GHz）|
| `include/hw/firmware/smbios.h` + `hw/smbios/smbios.c` | 新增 SMBIOS type 7 (Cache Information) 完整实现：struct、opts schema、parse、build + main build path 调用。`-smbios type=7,socket_designation=...,level=N,installed_size=KB,...` 生效。Windows `Win32_CacheMemory` 从空 → L1/L2/L3 三条记录 |
| `hw/smbios/smbios.c` | **type 4 → type 7 cache handle 链接**：以前 `l1/l2/l3_cache_handle` 硬编 `0xFFFF`，导致 Windows `Win32_Processor.L2CacheSize` 为空 / `L3CacheSize=0`。现在先 build type 7、按 level (1/2/3) 记录 handle，再 build type 4 把 handle 填进去。顺序不能反，否则 level→handle 表仍是 0xFFFF |
| `hw/smbios/smbios.c` | type 4 新增 `external-clock` / `voltage` / `processor-upgrade`；默认 socket enum 保持 Other，启动器按 LGA1150/LGA1151 显式传值。type 3 新增 `chassis_type`，启动器显式传 Desktop |
| `hw/smbios/smbios.c` | type 1/2/3 `version=` 参数必须显式传。**为空时**会落到 `smbios_set_defaults()` 从 `mc->name` 继承成 `"pc-q35-11.0"` — `Win32_BaseBoard.Version = "pc-q35-11.0"` 是 QEMU 指纹。`start-vm.sh` 已显式填 `version=1.0` 等 |
| `target/i386/cpu.c` | 三个 CPU 模型都有真实 cache info：i5-4590/Haswell 的 L2 是 256K 8-way/core，i5-6500/i3-8100 是 256K 4-way/core；三者 L3 都是 6M 12-way shared。避免 `legacy_cache` 回退到错误的 4M L2 / 16M L3 |
| `hw/pci/pci.c` | `pci_default_sub_vendor_id/device_id` 可通过 env vars `QEMU_PCI_SUBVENDOR_ID/SUBDEVICE_ID` 覆盖（默认 `0x1AF4/0x1100` = Red Hat/QEMU 是典型虚拟化指纹）。start-vm.sh 按 `BOARD_BRAND` 查表设成 MSI/ASUS/Gigabyte/ASRock 真实 OEM subsystem ID，guest 里 `lspci` 再也看不到 Red Hat/QEMU |
| `hw/audio/hda-codec.c` | `QEMU_HDA_ID_VENDOR` 从 `0x1AF4` (Red Hat) 改为 `0x10EC` (Realtek)。Windows 里 HD Audio Device 不再显示 "Red Hat High Definition Audio"，codec InstanceId 是 `HDAUDIO\FUNC_01&VEN_10EC&...` |
| `hw/nvme/ctrl.c` | 保留兼容性优先的 Red Hat 默认 PCI ID，并支持 Samsung/Intel/WD 显式 ID；Samsung Identify 使用 NVMe 1.3，WD Black 使用实机 `15b7:5001`、subsystem `1b4b:1093`、NVMe 1.2 与 Gen3 x4 链路 |
| `hw/usb/hcd-xhci-pci.c` | 裸 `qemu-xhci` 保持上游 Red Hat 默认以免旧 guest 驱动回退；启动器按主板平台显式覆盖成 Intel 9/100/300 Series xHCI |
| `hw/smbios/smbios.c` | type 16 报告主板 4 槽及 32/64GiB 上限；type 17 支持 `|` 分隔的逐槽 locator/bank/serial，以 `A2/B2` 安装两条 4GiB，并显式列出空的 `A1/B1` |
| `hw/i386/pc_q35.c` + `hw/i2c/smbus_eeprom.c` | 8GiB guest 拆成 2×4GiB；SPD 按 profile 动态生成 DDR3-1600 或 DDR4-2133/2400，容量、时序和 CRC 与 SMBIOS 一致，不再固定成 DDR4-2666 |
| `deploy/host/OVMF_CODE_4M_stealth.fd` | 默认使用的本地 OVMF：修改 firmware vendor，并 backport edk2 early-MTRR 修复。旧 2024.02 在挂 mdev 时会用不可缓存内存解压主 FV，实测约慢 80 秒；修复后 ramfb 约 2.9 秒、vGPU Windows 桌面约 16.5 秒出现。源码补丁及重建脚本位于 `deploy/host/` |

编译后通过 `build/qemu-system-x86_64 -cpu help | grep Core-i` 可以看到三个新 CPU 模型。

## 目录速查

```
deploy/
├── README.md                 # 本文件
├── create-vm.sh              # 一次性生成 G-11/vmN/vm.conf
├── migrate-g11-layout.sh     # 旧 instances/vmN → G-11/vmN（默认只检查）
├── start-vm.sh               # NVIDIA mdev/vGPU 唯一启动入口和实现
├── fb-shm-stream.sh           # 每 VM ROI/编码推流 sidecar 生命周期
├── finish-vgpu-install.sh     # 新装一次性收尾：单 EXE、token、休眠、RTC/EDID
├── stop-vm.sh                # NVIDIA mdev/vGPU 唯一停止入口和实现
├── connect.sh                # vGPU stream/relay 模式的外部 SDL viewer 入口
├── service.sh                # vGPU stream/relay 模式的 guest 服务控制
├── tests/
│   ├── vgpu/                 # 本分支部署与生命周期测试
│   └── qemu/                 # 本分支依赖的 QEMU 源码静态测试
├── lib/
│   ├── cpu-isolation.sh      # QMP vCPU TID 获取与 CPU 隔离启动/回滚
│   ├── vm-storage.sh         # VM/ISO/config/base/NVRAM 统一路径解析
│   ├── vm-tpm.sh             # swtpm TPM 1.2/2.0 生命周期与精确清理
│   └── vgpu-mdev.sh          # mdev 动态分配/回收（带 16 GB 上限检查）
├── host/
│   ├── cpu-isolate.sh        # 固定 cgroup v2 产品分区的 root helper
│   ├── install-cpu-isolation.sh # 安装 root-owned helper 与受限 sudoers
│   ├── netplan-br0.yaml      # 宿主网桥配置示例
│   ├── setup-bridge.sh       # qemu-bridge-helper setuid + /etc/qemu/bridge.conf
│   ├── setup-vgpu-unlock.sh  # 编译 vgpu_unlock-rs + LD_PRELOAD 注入 systemd
│   ├── profile_override.toml # nvidia-257 显示/2GB 资源；每 VM 名称运行时按 mdev UUID 生成
│   ├── sync-monitor-cache.sh # 关机状态离线刷新 Windows EDID/模式缓存
│   ├── setup-fastapi-dls.sh  # 旧 /opt/fastapi-dls 本机部署入口
│   └── fastapi-dls/          # 可迁移 Compose、dlsctl、地址切换与独立文档
├── guest/
│   ├── install-vgpu-license.ps1 # guest 内原子授权、回滚与严格验收
│   └── spoof-inf/
│       ├── README.md         # GRID → GeForce INF 伪装流程
│       └── inf-patch.ps1     # 自动改 INF 并 pnputil 重装
└── docs/
    ├── VGPU-VM-CREATION.md   # 新建 VM：RTX6000-2Q 装驱动 → 消费卡身份
    ├── VGPU-RECOVERY-RUNBOOK.md # 休眠恢复、EDID 与设备管理器名称持久化
    ├── DRIVER-INSTALL.md     # 当前 535/538.33 驱动基线与 A/B 边界
    ├── STORAGE-LAYOUT.md     # 每 VM bundle、迁移与备份边界
    ├── DETECTION.md          # 反虚拟化检测面清单（按层组织）
    └── DEBUG.md              # 调试手段 (perf / GDB / trace / 日志)
```

运行数据位于 `/home/ubuntu/images/{iso,staging,vms}`；每台 VM 的系统盘、NVRAM、
配置、运行态和日志集中在 `vms/G-11/vmN/`，公共 base 位于
`vms/G-11/shared/bases/`。完整目录树见
[`docs/STORAGE-LAYOUT.md`](docs/STORAGE-LAYOUT.md)。

## 一次完整部署顺序

### 0. 宿主前置

1. 内核加 `intel_iommu=on iommu=pt`，重启后 `dmesg | grep -i iommu` 确认 DMAR 启用。
2. 加载 `vfio-pci` + `vfio-mdev` 模块。
3. NVIDIA vGPU host driver 已装，`nvidia-smi vgpu` 能列出支持的 type。当前 535
   栈提供 VFIO REGION display，不提供 DMA-BUF；guest GRID 驱动必须与该 host
   branch 和所选 profile 兼容。
4. 物理显示靠 AMD RX 570，不要让 Ubuntu desktop 动 NVIDIA 卡。
5. 安装 TPM/应答 ISO/推流运行时：
   `sudo apt install swtpm swtpm-tools xorriso ffmpeg`。默认 TPM 启动会 fail-closed；
   不会因缺包而悄悄启动成一台无 TPM 的 VM。
6. CPU 隔离依赖 `sudo`、`python3`、`util-linux`（`taskset`/`flock`）、
   `diffutils` 以及 cgroup v2 `cpuset` controller。`sudo` 是提权入口，必须预先
   可用。默认 `required`；建议先交互执行 `sudo -v`，再提前执行
   `sudo ./deploy/host/install-cpu-isolation.sh`。无人值守确需凭据时，只能通过
   批准的安全渠道或运行时环境变量提供，不得写入仓库、配置或命令历史。
   `--cpu-isolate-auto` 是显式允许降级，`--no-cpu-isolate` 才是明确关闭。

### 1. vgpu_unlock-rs + profile_override

下面是**首次准备宿主**的 bootstrap，不是每次新建 VM 都要执行。当前已经跑通
535.161.05 的宿主应直接从
[`docs/VGPU-VM-CREATION.md`](docs/VGPU-VM-CREATION.md) 的宿主预检开始；不要为了
新建 VM 重跑 setup、拉取新版 unlock 或在有 VM/mdev 时重启 manager。

```bash
cd deploy
./host/setup-vgpu-unlock.sh
sudo systemctl restart nvidia-vgpu-mgr
```

### 2. fastapi-dls vGPU 授权服务器

```bash
cd host/fastapi-dls
./dlsctl.sh deploy <授权服务器IP或DNS名>
# 后续换地址：./dlsctl.sh set-address <新IP或DNS名>
```

Compose、持久数据、证书、备份和地址迁移见
[`host/fastapi-dls/README.md`](host/fastapi-dls/README.md)。旧
`host/setup-fastapi-dls.sh` 只保留给已有 `/opt/fastapi-dls` 部署，不用于新服务器。

### 3. 宿主网桥

```bash
# 先改 host/netplan-br0.yaml 里的网卡名
./host/setup-bridge.sh          # 这一步只装 helper 和 bridge.conf
# 自行 cp YAML + netplan try + netplan apply
```

### 4. 可选：预选 VM 身份

```bash
./create-vm.sh --list-gpu-profiles
./create-vm.sh --list-monitor-profiles
# 日常可跳过；start-vm 会在配置不存在时自动随机生成
./create-vm.sh 2 --gpu-profile gtx1050_2gb --monitor-profile dell-p2419h
# 每个 VM 的平台/主板/内存/GPU/显示器身份/序列号/MAC 全部写入 G-11/vmN/vm.conf
# B150/B360 从 Samsung 970 PRO、WD Black 两款 512GB PCIe 3.0 x4 NVMe 中选择；DDR3/H97 从 Samsung、Crucial、Kingston、Intel、Western Digital 的七款 512GB SATA 池选择。
# 键盘与绝对坐标鼠标指针也会写入配置并显示；默认 PS/2 输入会关闭，避免重复枚举。
# 显示器先等概率抽品牌、再抽具体型号；品牌/型号也以
# MONITOR_BRAND_NAME / MONITOR_MODEL_NAME 明确写入配置。
# RTX 2080 宿主 fallback 是 nvidia-257 / 2048MB；V100 可由
# host/vgpu-host.conf 覆盖为 V100-2Q/V100D-2Q 等同容量资源。
# mdev 显示器 EDID 在关机状态由 host 离线同步；guest 内不装常驻脚本/任务。
# 新装收尾统一运行：
# ./finish-vgpu-install.sh 1
```

### 5. 一条命令建空盘 + 初次装 Windows (NO_VFIO install 模式)

```bash
# 缺 vm.conf 自动创建；缺盘固定 --blank，即使公共 base 存在也不会复制
# ISO 省略时使用 /home/ubuntu/images/iso/win10.iso
./start-vm.sh 1 --install
# 安装模式不挂 vGPU，直接弹出 std-vga + QEMU GTK 窗口
```

低级调试时仍可显式拆成 `create-vm.sh`、`create-disk.sh 1 --blank`、
`start-vm.sh 1 --install`；正常操作不需要拆分。

装好 Windows 后去掉 CD，先按下一节用 `--no-monitor-sync` 安装 GRID driver；不要
使用旧 `--no-gpu` + VNC 救援。driver 装好并完整关机后，再在第 8 节运行
`finish-vgpu-install.sh`，它使用 std-vga + 本地 SDL 救援。

RTC 统一由宿主负责：QEMU 进程使用 `TZ=Asia/Shanghai`，并传入
`-rtc base=localtime,clock=host,driftfix=slew`。新装 Windows 不写
`RealTimeIsUniversal`。旧 `base=utc` VM 在完整关机后运行
`finish-vgpu-install.sh`，脚本会先兼容启动，再由宿主离线备份 SYSTEM、删除旧 DWORD
并写入 `RTC_CONTRACT=localtime`；不要在 guest 内运行旧 RTC 修复脚本。

### 6. 装 vGPU guest 驱动（vGPU 真 PCI ID）

用 `./start-vm.sh 1 --no-spoof --no-monitor-sync` 启动，使匹配的 GRID INF 能看到
真实 vGPU PCI ID，同时避免在关闭休眠前离线写 NTFS。安装与 host branch/profile
兼容的 GRID guest 驱动；驱动接管前由 ramfb 显示。装完让 Windows 完整关机，
license 留到第 8 节统一收尾。

### 7. 消费卡身份策略

所有新配置及当前支持的三款 profile 都使用 B：`--spoof-name-only` 保留
`DEV_1E30`，并按稳定 mdev UUID 注入消费卡名称。GTX1050 也不会由脚本自动切 A，
日常只需：

```bash
./start-vm.sh 1
```

新 base 不应包含旧 GPU 名称任务或 NVAPI shim。历史 base 若仍有
`RefreshGridNames`/WMI 残留，可选运行 `./sync-vgpu-profile.sh 1` 修复注册表；
正常 host-only 路径不需要它。per-mdev 覆写只改产品名，不会改变物理 GPU 的
核心数、频率、总线位宽、调度份额或真实性能。

严格 A 的历史实验只覆盖 GTX1050，但其修改 INF/自签 catalog 的 transition 已禁用；
受支持状态保持 B。VM3 已迁移并验收为 B/native 成品；底层资源仍是
`nvidia-257`，因此原始 PnP 身份是 vGPU 的 `DEV_1E30`，而不是消费卡
`DEV_1C81`。设备管理器名称和 GPU-Z app-local profile 显示 GTX 1050，但不会伪造
底层资源为真实 GP107。生产签名边界见
[`docs/DRIVER-INSTALL.md`](docs/DRIVER-INSTALL.md)。

这里不需要 RDP、ivshmem driver 或抓屏 relay。vGPU stream/relay 模式才使用
`./start-vm.sh 1 --legacy-shmem`（`--rdp` 同义）。

### 8. License & 验证

```bash
./finish-vgpu-install.sh 1
```

GTX1050 strict-A 旧自签 ZIP 已禁用并归档；受支持状态保持 B。VM3 已完成迁移，
启动时不再走被隔离的 strict-A 路径。其他 B profile 可使用小 EXE 做 legacy
token/RTC 收尾。
B/off 继续按 DLS `Licensed` 验收。完整矩阵见
[`docs/VGPU-LICENSING.md`](docs/VGPU-LICENSING.md)。

### 9. 装 DNF 实测

把 DNF 客户端装进 guest，启动 `dnf.exe`，期望:

- 不触发 TP "检测到虚拟机" 弹窗
- 正常进登录
- 进角色选择 → TP 过检
- 游戏可以跑（性能看 vGPU 实际带宽）

## 其它重要提醒 (memory 里的硬约束)

- 永远不做整卡 passthrough。
- 默认 SDL 路径（可选 `--gtk`）只有 vGPU 显示设备；ramfb 是该 VFIO 设备上的早期固件显示，
  不会额外挂一张 std-vga。
- 生产通道禁用 Sunshine / Moonlight / Parsec / Looking-Glass；默认使用 QEMU 本地
  SDL 窗口，GTK 可用 `--gtk` 选择。stream/RDP 共享内存 relay 是同一 vGPU
  生命周期内的显式可选显示模式。
- RTC 契约由宿主固定为 `TZ=Asia/Shanghai` +
  `-rtc base=localtime,clock=host,driftfix=slew`；新装不写
  `RealTimeIsUniversal`。旧 UTC VM 完整关机后运行 `finish-vgpu-install.sh`，由宿主
  离线迁移，避免 NVIDIA 因 `Clock windback has been detected` 停止授权。

- GRID 驱动"只装了半截"(缺 `nvlddmkm.sys`, `nvwgf2umx.dll`) 是历史最频繁故障 — 永远先 Express Install 再改 INF。
