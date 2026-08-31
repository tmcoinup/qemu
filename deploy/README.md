# gmate（QEMU v11.0.2）反虚拟化 + vGPU 拆分工程

`gmate` 的默认生产路径是 NVIDIA mdev/vGPU 直显：`deploy/scripts/start-vm.sh`
分配 vGPU，以 `vfio-pci-nohotplug,display=on,ramfb=on` 挂入 guest，并由
QEMU SDL 直接显示。`ramfb` 提供 OVMF 和 NVIDIA 驱动接管前的早期画面；
驱动就绪后窗口切到 vGPU framebuffer。`--gtk` 可把窗口后端换成 GTK。
默认入口按主板 profile 启动每 VM 独立的 `swtpm`：TPM 1.2 使用 `tpm-tis`，
TPM 2.0 使用 `tpm-crb`，不支持 TPM 的 profile 自动关闭；显式 `--no-tpm`
（或 `TPM=0`）仍可覆盖。

## 生命周期入口与显示模式

本分支只有 NVIDIA mdev/vGPU 一套 VM 生命周期，启动和停止入口固定为：

```bash
./deploy/scripts/create-vm.sh <vm_id> [hardware/profile options]       # 可选：预选身份
./deploy/scripts/start-vm.sh <vm_id> [--vms-dir ABS|--vm-dir ABS|--instances-dir ABS] [options]
./deploy/scripts/stop-vm.sh <vm_id> [--vms-dir ABS|--vm-dir ABS|--instances-dir ABS] [--force]
```

`deploy/scripts/` 是当前 G-11 的规范用户入口。已退役分支不作为运行时回退，
也不参与 DGame 的窗口、socket 或显示后端探测。统一路径映射和 G-11 专用命令说明见
[`scripts/README.md`](scripts/README.md)。
`deploy/scripts/` 是唯一的 VM 生命周期脚本位置，不再保留 `deploy/*.sh` 同名旧入口。
启动流程负责 vGPU
配置、磁盘、mdev、TPM、QEMU 和显示生命周期；停止流程负责同一 VM 的优雅关机、
强制停止和资源回收。以下显示方式均属于这一生命周期内部的运行模式：

默认 G-11 bundle 是 `/home/ubuntu/images/vms/<ID>`。先用
`./deploy/scripts/start-vm.sh ID --print-paths` 无副作用核对；完整默认/指定路径和停机
迁移教程见
[`docs/STORAGE-PATHS-QUICKSTART.md`](docs/STORAGE-PATHS-QUICKSTART.md)。

| 显示模式 | 启动方式 | 说明 |
|---|---|---|
| native SDL | `./deploy/scripts/start-vm.sh N` | 默认；QEMU 直接显示 NVIDIA vGPU framebuffer |
| native GTK | `./deploy/scripts/start-vm.sh N --gtk` | 与默认模式使用同一 vGPU 数据通路 |
| native + ROI 推流 | `./deploy/scripts/start-vm.sh N --stream URL [--stream-roi X,Y,W,H]` | 保留 SDL/GTK 窗口，并行输出显式网络目标或本地文件 |
| stream/relay | `./deploy/scripts/start-vm.sh N --legacy-shmem` | vGPU 桌面经 guest relay 和共享内存送到外部 SDL viewer |
| RDP 别名 | `./deploy/scripts/start-vm.sh N --rdp` | 与 `--legacy-shmem` 相同，保留现有调用方式 |

默认路径不挂 ivshmem，不启动 guest 抓屏 relay，不使用 RDP，也不需要
`ivshmem.sys`、`NvStreamSvc`（旧 relay）或 `AudioSvcHost`。它仍然需要 guest 内安装
与 host/profile 匹配的 NVIDIA GRID vGPU 驱动并完成授权；这是 vGPU 本身的
驱动要求，不是画面转发软件。

当前 host NVIDIA 535 驱动暴露的是 VFIO display **REGION**，没有 DMA-BUF，
所以这条直显路径不是 GPU framebuffer 零拷贝。画面由 QEMU 读取 REGION 后交给
SDL/GTK，但键鼠直接走 QEMU 原生输入设备，不经过共享内存 input ring 或 relay。
native 默认同时创建一个与网络编码分离的 DGame preview：SDL/GTK 把 REGION
画面上传到活动亮机卡后，QEMU 在 GPU 内裁 ROI 并向 DGame 导出 dma-buf。当前亮机卡
是 RX570；以后换 RX550 时按活动 `amdgpu/Mesa EGL` provider 自动选择，不写死
型号或 PCI 地址。该局部链路避免 DGame 再复制 CPU 预览帧，但不把原始 NVIDIA
vGPU REGION 冒充成端到端零拷贝；任一 GPU 导入失败会逐 VM 回退 SHM。
fb-shm 用纳秒绝对 deadline 按设置值固定发布；无 damage 时重发最后
一帧的 GPU texture/SHM slot，传输真正静默时 DGame 才探测并自动重连。

Tesla V100 的 1GB 或 2GB **单 framebuffer 档**软件预适配已把宿主 BDF、mdev type
和显存容量从 guest 身份中拆开；同一物理 GPU 只发布 `V100-1Q` 或 `V100-2Q`
其中一档。配置方法与实卡到位后的必验项见
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
历史分支对比材料仅供考古，不属于当前操作员工作流。
组件化硬件普通新建池恢复了 G3220、Core i3/i5/i7 + H81，并保留五款 Core i7 +
X79 扩展，共 11 款 CPU、13 块主板和 434 套可见原子整机，覆盖 2C2T、2C4T、
4C4T、4C8T、6C12T。完整目录为 13 CPU、16 主板、45 内存、524 整机：87 条
旧 6G 组合 archived，另有 3 条 legacy compatibility。
新建内存只用 4/8/12/16 GiB，其中 4/8 双通道、12 三通道、
16 四通道；Kingston、Samsung、Elpida、Micron、SK hynix、Crucial 按真实
CPU/板/模组上限运行 DDR3-1333/1600/1866。12/16G 只出现在至少四槽主板上。
10 款 SSD 覆盖 Samsung、Crucial、Kingston、Intel、WD 五品牌且均精确为
`512110190592` 字节；自动选择会先尝试 3 款 PCIe 3.0 x4 NVMe，再按平台合理性
回退 7 款 SATA；3 个 1GB +
3 个 2GB GPU 芯片型号共有 25 条原子 profile，生命周期为 2GB 默认 12 条、
1GB Maxwell 新建 4 条、显式 1 条、Kepler legacy 8 条。系统用户态板卡 metadata
覆盖 NVIDIA、ASUS、Dell、MSI、Gigabyte、
GALAX、Colorful（七彩虹）、ZOTAC、EVGA，显存厂家覆盖 Samsung、SK hynix、
Micron、Elpida。显示器新建池为 8 品牌/28 款，完整目录为
11 品牌/35 款，preferred
timing 均为 FHD 1920×1080@60。active 键盘和可选相对鼠标各覆盖 Microsoft、
Logitech、Dell；默认绝对指针诚实使用唯一的 QEMU 通用 profile。完整新旧门禁见
[`docs/G11-HARDWARE-POOL.md`](docs/G11-HARDWARE-POOL.md)。
固定实现/兼容边界另包括 `q35`/ICH9/ICH9-AHCI、`qemu-xhci`、QEMU `nvme`
controller、安装/救援 `std-vga` 与 legacy `ivshmem`；这些都不参加品牌扩展或随机。
新建配置使用硬件合同 v3：system/baseboard/chassis 三个标签延续所选主板品牌语法
且互不重复，但只有 baseboard serial 天然归主板厂，system/chassis 是现有合同中的
整机/资产标签。DIMM 使用非保留 JEDEC 4-byte 基准序列并为每个后续槽稳定派生不同值；
新建配置把完整 `MEM_SERIAL_LIST` 固化，并在统一 `MEMORY_SERIAL` 命名空间逐槽跨 VM
查重。SSD 使用型号专属严格格式；显示器只有 Samsung S24F350 与 Redmi RMMNT238NF 使用
已审核的型号专属格式，其余 33 款明确为 `generic-prefix-hash`。GPU 和 USB 输入
都不虚构序列号。创建时在 fleet 锁下查重并在撞号时重抽，启动时再次复核；缺少
逐槽列表的 v1/v2/v3 旧合同按 `MEM_SN + slot` 稳定派生，但不会被静默改写。
显示器实际广告集、所有 16:10 清理和已有 VM 的一键离线强刷见
[`docs/G11-MONITOR-POOL.md`](docs/G11-MONITOR-POOL.md)。
已审计但因 Xid 43/TDR 被生产隔离的 537.58 outer-only consumer PCI 路径见
[`docs/SIGNED-CONSUMER-PRODUCTION.md`](docs/SIGNED-CONSUMER-PRODUCTION.md)：
审计实验仍可在可删除克隆复现，但所有生产入口失败关闭。当前正式板卡/显存/
显示器方案见
[`docs/G11-BOTTOM-GPU-IDENTITY.md`](docs/G11-BOTTOM-GPU-IDENTITY.md)。

第一次处理现有 vGPU VM，直接按
[`docs/G11-QUICKSTART.md`](docs/G11-QUICKSTART.md) 的中文傻瓜教程操作。当前
主流程是一个无 VM 绑定、不内嵌 GPU-Z 的 `VgpuPortable.exe`。默认只把这个
文件安全注入 Windows base，再从 base 克隆任意 B/native VM；显卡型号、板卡品牌
和显存厂家由内置权威查询器验收，同一次双击还会应用推荐的 guest 登录启动和
native-display 性能优化。GPU-Z 是以后从官网取得并通过
`VgpuPortable.exe /with-gpuz` 显式选装的附加消费者；历史 A → B 才保留按 VM
迁移和关机提交。实际 VM 需要完成授权时，显式构建独立的私有授权版；同一个
`VgpuPortable.exe` 对 GT 730、GT 740、GTX 750、GTX 750 Ti、GT 1030、GTX 1050
统一安装身份和 token、验证 `Licensed`，关闭休眠/Fast Startup，并应用相同性能
优化。默认基础盘版仍不含 token。
需要交付给 VMate、并要求每台 clone 经 Sysprep 获得独立 Windows OS 身份时，使用
[`docs/G11-SYSPREP-PRIVATE-BASE.md`](docs/G11-SYSPREP-PRIVATE-BASE.md) 的私有流程：
模板不运行 portable；关机后宿主只运行一个总命令，把授权 V7 EXE 固定注入
`C:\ProgramData\VMate\G11`，并给同一个本机可克隆 qcow2 生成 `.g11base` 交付清单，
不会再复制第二份 base 或保留 archive。每台克隆成功路径只运行
授权版一次，OOBE 无交互；克隆时自动生成每 VM 的系统 NVAPI 只读 ISO，首启安装后
内部重启验证并最终关机，用户只在 VMate 点一次“初始”。私有 qcow2 含共享 token，
只能私下交付；公共基础盘仍继续使用上面的无凭据通用流程。
私有 Sysprep/VMate 流程不需要用户再运行打包脚本。只有公共/高级成品 VM 要让普通
32/64 位 NVAPI 程序读取同一行身份并持久恢复显示器名称时，才手工运行
`./deploy/package-system-nvapi-projection.sh VM_ID` 的 VM-bound 一键包；它
保留唯一原生 `DEV_1E30` 3D transport，不创建第二块显卡。默认目录是该 VM 的
`packages/SystemNvapiProjection/`，删除完整 VM bundle 时不会在 staging 留下包。

## 入口脚本（host）

| 命令 | 干什么 |
|---|---|
| `./deploy/scripts/vmctl.sh {path\|start\|stop\|status\|delete} <vm_id> [...]` | 路径感知的傻瓜封装；默认数字目录及 `--vms-dir`/`--vm-dir` 都透传到唯一生命周期入口 |
| `./deploy/scripts/vmctl.sh display <vm_id> {status\|preview-on\|preview-off\|window-hide\|window-show\|stream-only\|window-only}` | 运行中热插独立 DGame preview，或安全切换 SDL 与 fb-shm；QMP 会核对 VM 身份 |
| `./deploy/scripts/vmctl.sh wake <vm_id>` | 唤醒用户主动进入 ACPI S3 的 G-11 VM；先核对 QMP 身份和 `suspended` 状态，不影响已运行 VM |
| `./deploy/scripts/vmctl.sh preview-capacity --instances 16 --rate 60` | 只读检查亮机卡 DRM provider，并核算 1080p 源上传、800×600 / 1067×600 ROI 与 16 窗口纹理常驻量 |
| `./deploy/scripts/vmctl.sh cdrom <vm_id> {status\|mount ABS.iso [--replace]\|eject}` | 普通启动零光驱；`mount` 热插只读 USB-BOT/SCSI 光驱，`eject` 删除整台设备，无需重启 Windows |
| `./deploy/scripts/shared-usb.sh <vm_id> {mount\|status\|eject}` | 把 `shared/usb/` 热插为逻辑 128 GiB、宿主不预分配镜像的只读 FAT32 U 盘；真实卷标固定为 `U盘` |
| `./deploy/scripts/usb-directory.sh <vm_id> mount ABS_DIR [--replace]` | 把明确指定的 host 目录免驱热插为只读 VVFAT/USB Mass Storage |
| `./deploy/scripts/guest-lite.sh <vm_id> usb-mount` | 封装 Guest Lite 2.6.7（保留 MpsSvc 兼容 NVIDIA 控制面板，退役 CDPSvc 禁用并按旧基线恢复 Settings 兼容性；含克隆快速路径、Defender/防火墙 profile/更新/云盘/通知/输入法/游戏模式/Game DVR/高性能电源、所有计划屏幕与自动睡眠“从不”、NVIDIA 最高性能/DNF High/安全清理旧 Temp/后台进程）到固定目录并刷新只读公共工具 U 盘 |
| `./deploy/scripts/vmctl.sh seal <source_id> <base_name> [--no-clean]` | 将停机 VM 封装为具名 standalone base；默认先离线清理 WeGame/Tencent 跨克隆身份，失败不发布；`--no-clean` 仅用于明确保留状态 |
| `./deploy/scripts/vmctl.sh clone <base_name> <new_id> [--gpu-profile PROFILE] [--start]` | 精确选择具名 portable base，默认创建 V-11 式 hard-link pin + 小型增量盘；不指定 GPU 时按宿主 framebuffer 单档、显示器按新建池各随机一次并写死到 `vm.conf`，`--full-copy` 才复制独立整盘 |
| `./deploy/scripts/vmctl.sh refresh-base <base_name> [--check]` | 仓库首启合同升级后，一键检查/原子刷新私有 Sysprep 母盘；已有克隆 pin 不变，后续克隆使用当前 finalizer + Guest Lite |
| `./deploy/scripts/vmctl.sh repair-init <vm_id>` | 停机失败克隆的一键升级：刷新用户态 finalizer/Guest Lite 与 VM 绑定 ISO，保留 Licensed 结果、正式驱动和母盘 |
| `./deploy/scripts/vmctl.sh driver-install <vm_id> [--start]` | 新 Windows/新母盘/同版本修复的通用 GRID 入口：临时标准 VGA + mdev `display=off` 安装，完整关机后离线认证并写 page-safe `NV_Modes`；默认停机 |
| `./deploy/scripts/vmctl.sh repair-display <vm_id> [--no-start]` | R535 SDL/QMP 纯黑一键恢复：只允许 ACPI 关机，离线清旧模式并写 8 项 page-safe EDID/`NV_Modes`，默认冷启动 |
| `./deploy/scripts/vmctl.sh monitor <vm_id> [--monitor-profile PROFILE] --force` | 仅关机态切换显示器或强制清旧缓存；普通 start 已自动按 `vm.conf` 同步 |
| `./deploy/scripts/vmctl.sh migrate [--check\|--apply] [--vms-dir ABS]` | 两代旧 G-11 bundle 到 `VMS_DIR/N` 的只读检查/安全迁移 |
| `./deploy/host/build-qemu.sh` | 增量构建 `qemu-system-x86_64` 与离线同步依赖的 `qemu-edid` |
| `./deploy/host/build-stealth-ovmf.sh` | 构建随 G-11 封装的 OVMF；在 UEFI 退出后通用交接 X79 CPU DMI2 identity，不含 VM/验收软件特判 |
| `./deploy/scripts/recover-hibernated-vm.sh <vm_id> [--rescue-gtk] [--proxy]` | 休眠/Fast Startup 一键恢复：只开本地标准 VGA，Windows 完整关机后自动强制同步显示器；不挂 vGPU、不走远程桌面、不装 guest 包，任一步失败即停止 |
| `./deploy/scripts/sync-monitor-profile.sh <vm_id> --force` | `vmctl monitor` 的底层入口；普通启动和克隆已自动调用，强制修复时核对生产 538.33/INF 收据并重写 FHD/1K EDID 与 8 项 R535 page-safe `NV_Modes`；guest 内零常驻 |
| `sudo ./deploy/host/recover-vgpu-gpu.sh --check --resume`（确认后去掉 `--check`） | 所有 VM/mdev 已停后的 host GPU 一键恢复；共享锁与 fd 门禁后仅尝试 NVIDIA reset、干净模块重载和精确 FLR，绝不 bus reset、强卸模块或自动重启宿主 |
| `./deploy/host/switch-g11-vgpu-branch.sh {status\|doctor}` / `sudo ... {init-r535\|r535\|r580-lab}` | 本机 RTX 2080 的 R535 稳定生产档与 R580 母盘暂存实验档一键切换；精确 DEB/RM/内核/空 signer 门禁、失败自动回滚，重启后先于 VM 自动验收并写 `ready`，教程见 [`docs/G11-RTX2080-R535-R580-SWITCH.md`](docs/G11-RTX2080-R535-R580-SWITCH.md) |
| `./deploy/scripts/check-hardware-pool.sh` | 无 sudo、无写入地验证硬件目录及本机 KVM CPU realization；区分新 VM 与旧 VM 兼容池 |
| `./deploy/scripts/create-home-vm.sh <vm_id> --spec 2c2t\|2c4t\|4c4t\|4c8t\|6c12t [--memory-size 4G\|8G\|12G\|16G]` | 家用池傻瓜封装；默认 8G、同规格内按宿主兼容性选择，教程见 [`docs/G11-HOME-CPU-POOL-QUICKSTART.md`](docs/G11-HOME-CPU-POOL-QUICKSTART.md) |
| `./deploy/scripts/create-vm.sh <vm_id> --cpu-profile i7-4930k --board-profile BOARD --memory-profile MEMORY --ssd-profile SSD` | 底层精确组件入口；五种 CPU 规格都只从审核白名单选择 |
| `./deploy/scripts/create-vm.sh --list-cpu-profiles`（另有 `--list-board-profiles`、`--list-memory-profiles`） | 默认显示 11 款 CPU、13 块 H81/X79 主板与 4/8/12/16G DDR3；前置 `--include-fallback` 才读取完整 13/16/45 目录，archived 仍不可新建 |
| `./deploy/scripts/create-vm.sh --list-platforms` | 默认显示 434 套可见新建审核白名单；前置 `--include-fallback` 才显示完整 524 套生命周期目录 |
| `./deploy/scripts/start-vm.sh <vm_id> --install [iso]` | 缺配置时自动生成身份，缺盘时固定建空盘；默认以安装期 UEFI helper 自动引导 xHCI USB Windows 光盘（约 64 KiB 合并读取）并挂最小应答 ISO；helper/两张 ISO 在普通启动全部消失；默认跳过 OOBE，以空密码 `Administrator` 首次登录，设置中国时区/NumLock，并预先关闭 Fast Startup |
| `./deploy/scripts/start-vm.sh <vm_id> --install [iso] --install-media ide` | 仅异常固件/ISO 的慢速 ATAPI 兼容回退；不挂 helper，也不会把选择写入 `vm.conf`。完整说明见 [`docs/G11-INSTALL-MEDIA.md`](docs/G11-INSTALL-MEDIA.md) |
| `./deploy/scripts/start-vm.sh <vm_id> --install [iso] --manual-oobe` | 同一安全建盘语义，但不挂应答 ISO，完整手动完成 OOBE |
| `./deploy/scripts/start-vm.sh <vm_id> --spoof-name-only` | 通用安全 B：保留 PCI 真身，host 按 mdev UUID 提供每 VM 产品名，前台打开 QEMU SDL 原生窗口 |
| `./deploy/scripts/start-vm.sh <vm_id> --gtk --spoof-name-only` | 同一条 B 路径，改用 QEMU GTK 窗口 |
| `./deploy/scripts/start-vm.sh <vm_id>` | 缺配置时自动生成身份，缺盘时严格从公共 base clone；默认 required CPU 隔离和宿主内存全量预分配，成功后才放行 guest；新配置及当前 25 条 GPU 原子 profile 均保持 B，legacy GTX1050 strict-A transition 已禁用 |
| `./deploy/scripts/start-vm.sh <vm_id> --proxy` | 仅为旧工具创建 `.proxy` 兼容别名；默认 DGame preview 已让主 `qmp.sock` 使用原生 multi-client，正常启动和 DGame 不需要此参数 |
| `./deploy/scripts/start-vm.sh <vm_id> --no-tpm` | 明确关闭该主板 profile 的 TPM；只用于兼容/诊断 |
| `./deploy/scripts/start-vm.sh <vm_id> --vlan-id VID` | 把该 VM 接入已授权的业务 VLAN；不带参数就是默认原生 LAN |
| `./deploy/scripts/start-vm.sh <vm_id> --cpu-isolate=true\|false` | CPU 隔离布尔开关；省略即 `true`，`false` 改用宿主共享调度，Guest core/SMT 身份不变 |
| `./deploy/scripts/start-vm.sh <vm_id> --memory-prealloc=true\|false` | 宿主内存预分配布尔开关；省略即 `true`，`false` 让 memfd 按实际触页占用，Guest 固定容量、DIMM/SMBIOS 不变。见 [`docs/G11-MEMORY-ON-DEMAND.md`](docs/G11-MEMORY-ON-DEMAND.md) |
| `./deploy/scripts/g11-performance.sh {audit\|apply\|restore}` | 一键审核、应用或回滚宿主动态全频段/睿频、稳定 TSC 配套、THP 与 NVMe 低抖动策略；见 [`docs/G11-PERFORMANCE-QUICKSTART.md`](docs/G11-PERFORMANCE-QUICKSTART.md) |
| `./deploy/host/g11-host-display.sh {audit\|check}` / `sudo ... {apply\|rollback}` | 修复 NVIDIA vGPU-only 卡被固件/GDM 误选为宿主主屏导致的开机花屏与 Xorg 重试；只固定 GDM 走 AMD Wayland，不碰 guest/驱动，见 [`docs/G11-HOST-DISPLAY-BOOT-FIX.md`](docs/G11-HOST-DISPLAY-BOOT-FIX.md) |
| `./deploy/scripts/g11-sdl-performance.sh {audit\|profile\|start\|verify}` | SDL fixed 提交、安全 Guest-cursor/Host fallback、1ms 键鼠与 service CPU 的傻瓜封装；120Hz 仅显式单窗口实验，见 [`docs/G11-SDL-PERFORMANCE.md`](docs/G11-SDL-PERFORMANCE.md) |
| `./deploy/host/install-g11-sdl-wayland-decor.sh [--check]` | 安装/检查纯 userspace Cairo libdecor；保留 Wayland 实时 FPS 标题并绕开 GTK monitor 日志风暴，见 [`docs/G11-SDL-WAYLAND-TITLE.md`](docs/G11-SDL-WAYLAND-TITLE.md) |
| `HOST_OOM_PROTECT=0 ./deploy/scripts/start-vm.sh <vm_id>` | 仅诊断：关闭默认的每 VM 进程树临时 `oom_score_adj=-500`；普通启动不需要设置 |
| `QEMU_DISK_AIO=threads ./deploy/scripts/start-vm.sh <vm_id>` | 仅诊断：跳过默认 `io_uring` → `native` → `threads` active-read 自动选择，固定可靠线程池；不改变 guest 磁盘身份 |
| `./deploy/scripts/start-vm.sh <vm_id> --stream URL --stream-roi X,Y,W,H` | native SDL/GTK 加固定 ROI 网络推流；默认 `libx264` + `auto`（当前 sidecar 选 SHM），不创建监听端口 |
| `./deploy/fb-shm-stream.sh {status\|health\|stop} <vm_id>` | 查看或单独停止该 VM 的编码 sidecar；正常关 VM 会自动回收 |
| `./deploy/scripts/start-vm.sh <vm_id> --legacy-shmem` | 旧 ivshmem + guest relay + 外部 SDL viewer 路径；`--rdp` 是兼容别名 |
| `./deploy/package-vgpu-one-click.sh` | 推荐主入口：生成包含全部已审计 profile 和推荐 guest 性能优化、无 VM ID/UUID、不内嵌 GPU-Z 的单一 `VgpuPortable.exe` |
| `./deploy/package-vgpu-one-click.sh --replace-public` | 已有公共产物的 catalog/格式换代：显式构建新版，并把旧 EXE/展开包保留到仓库外 mode-0700 backup |
| `./deploy/package-vgpu-one-click.sh --with-license-token` | 显式生成私有统一收尾版：从 staging 的仓库外 token 构建独立 `VgpuPortableLicensed/VgpuPortable.exe`；六个芯片型号/25 条 profile 共用，成功必须为 `Licensed`、关闭休眠/Fast Startup 且性能优化 PASS |
| `./deploy/package-vgpu-portable.sh --list-gpu-profiles` | 查看 25 条不可拆分的板卡/subsystem/VBIOS/时钟/显存厂家合同（12×1GB + 13×2GB） |
| `./deploy/scripts/seal-base.sh <source_id> <base_name> [--no-clean]` | G-11 基础镜像封装入口；每个名称独立发布，默认清理 WeGame/Tencent 身份后再 compact + standalone 发布 |
| `sudo ./deploy/install-vgpu-portable-to-base.sh --base-name <base_name>` | 停止所有 VM 后，把 portable EXE 写入所选 base 私有临时副本并生成该镜像独立证明；只有显式 `--with-gpuz` 才预置审计的 GPU-Z |
| `./deploy/scripts/clone-from-base.sh <base_name> <new_id> [--gpu-profile PROFILE] [--start]` | `vmctl clone` 的底层入口；精确校验所选 base/证明，默认 V-11 式增量盘，`--full-copy` 才占用一份完整母盘空间；GPU 可省略并按宿主 framebuffer 单档随机，显示器自动生成/同步 |
| `./deploy/package-vgpu-one-click.sh <vm_id>` | legacy 兼容入口：A 生成按 VM 绑定的完整生产驱动迁移 EXE；B 生成旧的按 VM 绑定 GPU-Z 包 |
| `./deploy/package-gpuz-profile.sh <vm_id> [...]` | legacy B 的 VM/UUID 绑定 GPU-Z 打包器；新 base/clone 不使用 |
| `./deploy/package-vgpu-production-migration.sh <vm_id>` | 为 legacy A 实例生成一个 VM/UUID/型号绑定的 guest EXE，内嵌未修改 GRID 538.33 与 GPU-Z 子包 |
| `sudo ./deploy/commit-vgpu-production-migration.sh <vm_id>` | guest EXE 完整关机后，从一次性 NBD snapshot 只读核验 staged 回执，再原子提交 B/native 配置；不写 Windows 磁盘或 BCD |
| `./deploy/signed-consumer-production.sh {stage\|status} <vm_id>` | 通用正式签名 outer-only 傻瓜入口；按 canonical profile、driver row 和当前宿主 qualification 选择，不按 VM 编号特判 |
| `sudo ./deploy/signed-consumer-production.sh {record-proof\|commit\|finalize\|rollback} <vm_id> [...]` | 停机证明/提交/验收/精确回滚；root qualification + VM UUID 回执，Windows 盘始终 snapshot 只读核验 |
| `./deploy/finish-vgpu-install.sh <vm_id>` | 仅保留给统一前 GTX750Ti/GT1030 的旧 token 回执/UTC→localtime 兼容迁移；当前 25 条 B/native 新流程均不运行；GTX1050 strict-A 自签路径继续硬拒绝 |
| `./deploy/scripts/stop-vm.sh <vm_id>` | 关 VM（另一终端使用；并回收该 VM 的 VLAN TAP/状态） |
| `./deploy/scripts/report-vm-boot-timing.sh <vm_id>` | 只读汇总本次 host boot 里的 vGPU start、display init、guest driver 和 license 时间；不依赖 guest IP |
| `./deploy/scripts/guest-performance.sh <vm_id> mount` | 仅旧版 EXE/诊断兼容：热挂独立性能维护包；新 VM 日常只双击 `VgpuPortable.exe`，见 [`docs/G11-GUEST-PERFORMANCE.md`](docs/G11-GUEST-PERFORMANCE.md) |
| `./deploy/scripts/host-nvme-apst.sh {check\|persist\|apply\|verify\|rollback}` | 可选 Linux 宿主 NVMe APST 策略；默认只读，写操作必须由管理员显式执行 |
| `./deploy/service.sh <vm_id> {stop\|start\|status\|restart}` | 仅旧 relay 路径使用的 guest 服务控制 |

`setup-guest.sh` / `connect.sh` 仍然在，供旧共享内存路径调试；默认直显不调用它们。
普通新实例优先只使用 `./deploy/scripts/start-vm.sh N`；第一次制作 base 才使用
`./deploy/scripts/start-vm.sh N --install [ISO]`。完整自动创建规则和 guest 最小化边界见
[`docs/VGPU-VM-CREATION.md`](docs/VGPU-VM-CREATION.md)。

只允许正式生产签名、明确禁止自签名/测试签名的 guest，应使用
[`docs/GPUZ-ONE-CLICK.md`](docs/GPUZ-ONE-CLICK.md) 的 portable B/native 流程。
默认产物为
`$STAGE_DIR/VgpuPortable/VgpuPortable.exe`，同时内嵌 6 个芯片型号的 25 条
已审计原子 profile（12×1GB + 12×2GB），但不内嵌 GPU-Z 程序字节。默认安装不读取、
不要求也不安装同目录 `GPU-Z.exe`；即使同目录恰好有文件，也只有显式执行
`VgpuPortable.exe /with-gpuz` 才会按大小、哈希、版本、签名和已审计 ABI 导入。
base 注入器默认也只放一个 EXE，只有显式 `--with-gpuz` 才预置 GPU-Z，运行时均
不依赖 HTTP。每次
`start-vm.sh` 会按新 clone 的配置自动发布只读 SMBIOS profile/UUID/catalog
声明；guest 严格核对声明、原生 `DEV_1E30`、Code 0、538.33、生产签名链、BCD 和
单 Display 后才应用对应型号。因此同一个 EXE 可放进 base 供任意 VM 克隆使用，
但不能在 guest 内任意选型号。正常 B/native portable 安装后没有人工 host
commit。

需要为一台实际 VM 同时完成 DLS 授权时执行：

```bash
chmod 600 /home/ubuntu/images/staging/client_configuration_token.tok
./deploy/package-vgpu-one-click.sh --with-license-token
```

产物是
`$STAGE_DIR/VgpuPortableLicensed/VgpuPortable.exe`。`create-vm.sh` 按
`VGPU_HOST_FB_TIER_MB` 从对应单档新建层选择（2GB 档 12 行、1GB 档 4 行
Maxwell），EXE 再按每次启动发布的只读 firmware claim 加载已固化行；它完整携带
25 行可查询目录，
额外哈希绑定 token 和原子授权安装器；成功必须看到 NVIDIA `Licensed`，随后关闭
休眠/Fast Startup。这个 EXE 含凭据、权限为 `0600`，不得提交仓库、公开分发或写入
通用 base。六个芯片型号的当前 B/native profile 都使用它，不再按型号
调用 legacy finish。

板卡与显存厂家使用安装器创建的 `vGPU Identity Query` 快捷方式权威验收，必须
以 `VERIFY PASS` 结束。以后显式选装 GPU-Z 时，再使用新建的
`GPU-Z (vGPU profile)` 快捷方式查看它的兼容显示。桌面原有的
TechPowerUp GPU-Z 从另一目录启动，不会继承 app-local shim，因此可显示原生
TU102/核心字段。即使使用 profile 快捷方式，未被 shim 覆盖的
`GPU`/Technology/Die Size 字段也可能仍显示 TU102/12 nm/754 mm²，详见
[`docs/GPUZ-ONE-CLICK.md`](docs/GPUZ-ONE-CLICK.md)。

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
资产必须先按新建教程核对 hash 和 INF DriverVersion。驱动装好、Code 0 后，当前
GTX 750 Ti / GT 1030 / GTX 1050 都用同一私有 portable 收尾：

```bash
# token 位于仓库外且 chmod 600
./deploy/package-vgpu-one-click.sh --with-license-token
# 安全复制 VgpuPortableLicensed/VgpuPortable.exe 到目标 VM，正常 B 启动后双击
```

EXE 自动读取固件 claim 选 profile，安装 token、等待 `License Status: Licensed`，
并执行 `powercfg /hibernate off` 与 `HiberbootEnabled=0`；之后让 Windows 完整关机并
正常冷启动。`finish-vgpu-install.sh` 只保留给统一前 GTX750Ti/GT1030 的旧回执和
UTC RTC 迁移，不是当前安装步骤。

GTX1050 strict-A 旧流程会修改 INF 并自签 catalog，现已硬拒绝。旧 A 实例改用
`package-vgpu-production-migration.sh`：Windows 用户只运行一个 EXE 一次，首次
关机后宿主核验回执并提交 B；开机任务自动绑定锁定的原始 538.33、验证 Code 0/
生产签名并应用 GPU-Z profile。不能用私有根、自签 catalog 或 BCD 测试选项替代。

**休眠/Fast Startup 恢复**：若正常启动或显示器同步报告休眠，不要把 GTX1050
引到上面的 legacy finish，也不要强挂载 NTFS。宿主只运行：

```bash
sudo -v
./deploy/scripts/recover-hibernated-vm.sh 3 --proxy
```

封装只打开本地标准 VGA，不挂 vGPU，也不使用 VNC/RDP/WinRM。进入 Windows 后，
在管理员命令提示符或 PowerShell 逐行执行：

```bat
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
shutdown.exe /s /f /t 0
```

等窗口自然退出；封装会自动运行 `sync-monitor-profile.sh 3 --force`，成功后打印带
`--proxy` 的普通启动命令。`--rescue-gtk` 可把默认本地 SDL 换成 GTK。任何 dirty/
hibernated、挂载或同步验证失败都会停止，不删除 `hiberfil.sys`、不运行 `ntfsfix`，
也不碰 BCD、签名或驱动。完整傻瓜步骤见
[`docs/VGPU-RECOVERY-RUNBOOK.md`](docs/VGPU-RECOVERY-RUNBOOK.md)。

**日常使用**：
```bash
./deploy/scripts/start-vm.sh 1                    # 使用 vm.conf 已验收的持久模式
./deploy/scripts/start-vm.sh 1 --no-numlock       # 仅本次允许 NumLock 保持关闭
# 新镜像装/修 GRID：./deploy/scripts/vmctl.sh driver-install 1
# 新 clone 无需 WinRM/guest 名称同步
# ramfb 先显示固件/启动画面，随后 NVIDIA vGPU framebuffer 接管
# Ctrl+C / 关 QEMU 窗口 / 另一终端 ./deploy/scripts/stop-vm.sh 1 都能优雅关
```

本地 SDL/GTK 窗口（包括 `--install`）使用 QEMU 原生输入。GNOME/Wayland 下，
窗口聚焦且鼠标位于窗口内时会临时把 `Ctrl+Alt+Del`、`Super`、`Alt+Tab` 等
宿主快捷键交给 guest；鼠标离开或窗口失焦立即恢复，可用
`--no-tame-gnome` 禁用。GTK/XWayland 还会先按 VM/RDP 客户端协议请求键盘独占，
不会只设置一个实际无效的本地 grab 标志。由于 NVIDIA 535 REGION 接口没有
独立 cursor plane，窗口内从 `$VM_ROOT/shared/assets/aero_arrow.cur` 选择 32×32 帧，
显示该 guest 自带的 Windows 默认箭头；资源缺失时才使用内置 fallback。
这个 REGION 不包含 guest 的 shape/hotspot/visible 元数据，因此桌面硬件
光标无法自动跟随 I-beam/缩放箭头变化。G-11 SDL 默认 `host`，始终保留由宿主
合成器即时绘制的 Windows 箭头，以跟手为优先；拖动标题栏时 primary framebuffer
里的延迟 Guest 箭头可能形成重影。显式 `--auto-cursor` 才会在左键按住、最近
Guest 坐标附近严格确认 `aero_arrow.cur` 已被 Windows 合成进 primary framebuffer
时临时隐藏 Host 箭头。`--guest-cursor` 仍只接受权威 Guest cursor sprite，
`Ctrl-Alt-C` 按 auto/host/guest 循环。检测与切换全部在 Host QEMU/SDL 内完成，
不会在 Guest 安装进程、hook、启动项、设备或驱动；详见
[`docs/G11-SDL-MOUSE.md`](docs/G11-SDL-MOUSE.md)。

R535 的 vGPU Manager 默认每 `100000 us` 才把 guest scanout 复制到 console
REGION 一次，所以仅提高 QEMU 的轮询率仍只有约 10 个新画面/秒。native 启动器会在
mdev 创建后、QEMU 打开前同时设置
`intervaltime=16667,vgaintervaltime=16667`，把这两个 console-copy 周期提高到约
60 Hz。它们是本机 R535 已验证的 NVIDIA 内部参数；非 R535 默认跳过，驱动升级后
需要重新验证。该参数只能在 mdev 未打开时设置，不能随窗口最小化动态切换；可用
`VGPU_CONSOLE_INTERVAL_US=0` 禁用并回到驱动默认值。

G-11 的 SDL 启动参数固定为 `title=win10-N,single-console=on`：每台 VM 只创建
一个操作窗口，不显示固件/文本辅助 console。隐藏或最小化期间发生 guest 模式
切换时只记录待恢复状态；显回后按最新完整 guest 分辨率重建客户区和 EGL 子窗口，
并以该分辨率作为可拖拽的最大客户区。

可见 SDL 窗口使用 `16,666,667 ns` 绝对 deadline 刷新，不再把
REGION/GL 处理耗时叠加到下一帧，目标匹配本机/vGPU 的 60 FPS 上限；最小化或
隐藏后降到 500 ms 以节省 host 开销。窗口标题中的
`Content xx.x/s | Present xx.x/s (fixed)` 分别表示内容更新和 QEMU 窗口提交频率；
两者都不是 guest 独立帧序号（REGION 没有该元数据）。GNOME Wayland 会自动选择
Cairo libdecor 后实时显示；未安装 Cairo 时安全回退静态标题，避免
`gdk_monitor_get_scale_factor` 日志风暴。傻瓜修复见
[`docs/G11-SDL-WAYLAND-TITLE.md`](docs/G11-SDL-WAYLAND-TITLE.md)。

`--gtk` 使用同一条 vGPU REGION 数据通路，但 GTK 标题目前没有 FPS 计数器；看不到
`SDL Present` 不表示帧率为 0。Wayland 下 GTK 由 GDK frame clock/合成器调度，体感
可能比 SDL 均匀。当前 25 条 GPU 原子 profile 都保持 B/off，并检查 DLS、`Licensed`、Code 0
和正式签名 driver。历史 strict GTX1050 A 曾报告 `Unlicensed / FRL N/A`，但该
自签 transition 已禁用，不是当前验收路径。默认 fixed 模式下，静止桌面标题常见
`Content 0/s | Present 60/s (fixed)`；动态测试只能判断内容更新是否异常锁在约 3/s，
不能替代性能跑分。

NVIDIA REGION 还会逐行精确对比可见像素：静止桌面不再重复上传
纹理，但仍以 fixed 节拍 Present 已缓存纹理；小范围变化只上传连续脏行；连续全屏动态会
暂时进入 fast path，避免游戏每帧额外比较。标题在静止时正常显示
`Content 0/s | Present 60/s (fixed)`，画面一变即在下一个 60Hz poll 内上传。
这仍是 REGION 系统内存复制加宿主 GL 上传，不是 DMA-BUF 零拷贝；一个持续变化的
1080p60 画面原始数据率约 `475 MiB/s`。

**spoof 切换**：
```bash
./deploy/scripts/start-vm.sh 1 --no-spoof          # off：只用于无 guest 写入的身份诊断
./deploy/scripts/start-vm.sh 1 --spoof-name-only   # B：PCI 真身 + name spoof，driver 最稳
./deploy/scripts/start-vm.sh 1 --spoof              # legacy A 诊断：当前无可用生产签名 transition，会拒绝
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
| `target/i386/cpu.c` | 新属性 `x-hv-stealth`；gate `FEAT_1_ECX` 的 HYPERVISOR bit；实现五款消费级 X79：`Core-i7-3820`/`Core-i7-4820K` 4C/8T、`Core-i7-3930K`/`Core-i7-4930K`/`Core-i7-4960X` 6C/12T，并按 10/12/15 MiB L3 投影 |
| `hw/smbios/smbios.c` | type 17 新增 `memtype` / `typedetail` / `width` / `totalwidth` / `rank` / `rank-list` / `voltage` 及逐槽 part/serial 语义，把 DDR 类型、位宽、每槽 Rank、料号、序列、同步属性和电压显式填进 SMBIOS；未指定时保持 QEMU 11 默认语义 |
| `hw/nvme/nvme.h` + `hw/nvme/ctrl.c` | NVMe 新增 `model=` 属性（默认 `QEMU NVMe Ctrl` 覆盖为 SSD 真实型号） |
| `hw/ide/atapi.c` | ATAPI INQUIRY 在显式给出 `model=` 时按 `vendor(8)+product(16)` 投影；仅显式 IDE 安装回退使用审核的 `HL-DT-ST DVDRAM GH24NS50 / XP02`。普通启动不创建光驱，手动 ISO 走可热插 USB-BOT/SCSI |
| `target/i386/cpu.c` | 新增 CPUID leaf `0x16` (Processor Frequency Info) 处理：从 tsc-freq 派生 base/max MHz + 100 MHz bus clock，让 Windows `Win32_Processor.CurrentClockSpeed` 与 brand string 一致（原 fallback=0 / OVMF 显示 2.00 GHz）|
| `include/hw/firmware/smbios.h` + `hw/smbios/smbios.c` | 新增 SMBIOS type 7 (Cache Information) 完整实现：struct、opts schema、parse、build + main build path 调用。`-smbios type=7,socket_designation=...,level=N,installed_size=KB,...` 生效。Windows `Win32_CacheMemory` 从空 → L1/L2/L3 三条记录 |
| `hw/smbios/smbios.c` | **type 4 → type 7 cache handle 链接**：以前 `l1/l2/l3_cache_handle` 硬编 `0xFFFF`，导致 Windows `Win32_Processor.L2CacheSize` 为空 / `L3CacheSize=0`。现在先 build type 7、按 level (1/2/3) 记录 handle，再 build type 4 把 handle 填进去。顺序不能反，否则 level→handle 表仍是 0xFFFF |
| `hw/smbios/smbios.c` | type 4 新增 `external-clock` / `voltage` / `processor-upgrade`；默认 socket enum 保持 Other，启动器按 LGA1150/LGA1151/LGA2011 显式传值。type 3 新增 `chassis_type`，启动器显式传 Desktop |
| `hw/smbios/smbios.c` | type 1/2/3 `version=` 参数必须显式传。**为空时**会落到 `smbios_set_defaults()` 从 `mc->name` 继承成 `"pc-q35-11.0"` — `Win32_BaseBoard.Version = "pc-q35-11.0"` 是 QEMU 指纹。`start-vm.sh` 已显式填 `version=1.0` 等 |
| `target/i386/cpu.c` | 十三个 CPU 模型都有与目录一致的 cache info；i7-3820/i7-4820K 为 10 MiB L3，i7-3930K/i7-4930K 为 12 MiB，i7-4960X 为 15 MiB。启动器按拓扑生成对应 L1/L2/L3 SMBIOS，避免 `legacy_cache` 回退到错误缓存 |
| `hw/pci/pci.c` | `pci_default_sub_vendor_id/device_id` 可通过 env vars `QEMU_PCI_SUBVENDOR_ID/SUBDEVICE_ID` 覆盖（默认 `0x1AF4/0x1100` = Red Hat/QEMU 是典型虚拟化指纹）。start-vm.sh 按 `BOARD_BRAND` 查表设成 MSI/ASUS/Gigabyte/ASRock 真实 OEM subsystem ID，guest 里 `lspci` 再也看不到 Red Hat/QEMU |
| `hw/audio/hda-codec.c` | `QEMU_HDA_ID_VENDOR` 从 `0x1AF4` (Red Hat) 改为 `0x10EC` (Realtek)。Windows 里 HD Audio Device 不再显示 "Red Hat High Definition Audio"，codec InstanceId 是 `HDAUDIO\FUNC_01&VEN_10EC&...` |
| `hw/nvme/ctrl.c` | 保留兼容性优先的 Red Hat 默认 PCI ID，并支持 Samsung/Intel/WD 显式 ID；Samsung Identify 使用 NVMe 1.3，WD Black 使用实机 `15b7:5001`、subsystem `1b4b:1093`、NVMe 1.2 与 Gen3 x4 链路 |
| `hw/usb/hcd-xhci-pci.c` | `qemu-xhci` 固定与虚拟寄存器模型匹配的上游完整身份 `1B36:000D rev01 / SUBSYS 1AF4:1100`；主板 Intel xHCI 字段只作 profile 事实，不投影到 Windows PnP |
| `hw/smbios/smbios.c` | type 16 按 X79 主板如实报告 4/8 槽及 32/64 GiB 上限。type 17 支持逐槽 locator/bank/serial/容量/料号，表达 2×2、2×4、3×4、4×4 GiB 与双/三/四通道 |
| `hw/i386/pc_q35.c` + `hw/i2c/smbus_eeprom.c` | DDR3 SPD 支持 1600/1866 及 2–4 槽原子列表，把 module/DRAM JEP106、独立 4-byte serial、18-byte part 写入标准字段；旧 DDR4 仍限 256-byte page 0，不伪造 EE1004 page 1 身份 |
| `deploy/host/OVMF_CODE_4M_stealth.fd` | 默认使用的本地 OVMF：修改 firmware vendor，并 backport edk2 early-MTRR 修复。旧 2024.02 在挂 mdev 时会用不可缓存内存解压主 FV，实测约慢 80 秒；修复后 ramfb 约 2.9 秒、vGPU Windows 桌面约 16.5 秒出现。源码补丁及重建脚本位于 `deploy/host/` |

看到 TianoCore 标志下方已经出现 Windows 转圈时，Windows Boot Manager 已经接管，
只是 NVIDIA 驱动尚未替换 ramfb，不能把整段可见时间都算成固件耗时。先运行
`./deploy/scripts/report-vm-boot-timing.sh ID` 查看 guest driver 握手，再检查私有
NVRAM 是否为 Windows Boot Manager 第一项且 `Timeout=0`；满足这两项时，删除后备
启动项或修改 Windows BCD 不会带来有效提速，并会降低恢复能力。

编译后可用
`build/qemu-system-x86_64 -cpu help | grep -E 'Core-i7-(3820|4820K)|Core-i'`
查看目录依赖的 CPU 模型。

## 目录速查

```
deploy/
├── README.md                 # 本文件
├── scripts/
│   ├── create-vm.sh          # 唯一配置创建/硬件目录入口
│   ├── create-disk.sh        # 唯一系统盘创建入口
│   ├── seal-base.sh          # 清理 WeGame/Tencent 身份并封装 standalone base
│   ├── clone-from-base.sh    # portable-attested base 克隆入口
│   ├── host-clean-tencent.sh # seal 默认调用的离线跨克隆身份清理器
│   ├── delete-vm.sh          # VM 生命周期删除入口
│   ├── migrate-g11-layout.sh # 旧 G-11/vmN、instances/vmN → vms/N
│   ├── recover-hibernated-vm.sh # host-only 标准 VGA 休眠恢复
│   ├── sync-monitor-profile.sh # 离线显示器配置同步
│   ├── vmctl.sh              # 不保存凭据的日常封装
│   ├── check-hardware-pool.sh # 一键只读审计组件目录、组合和 KVM CPU
│   ├── ctl-vm.sh             # 运行中 SDL/fb-shm 显示控制（vmctl display 底层）
│   ├── host-nvme-apst.sh     # 可选宿主 NVMe APST 检查/持久化/回滚
│   ├── setup-bridge.sh       # Netplan 事务/回滚宿主 bridge 入口
│   ├── start-vm.sh           # 唯一 VM 启动入口及实现
│   └── stop-vm.sh            # 唯一 VM 停止入口及实现
├── lib/
│   ├── storage-aio.sh        # 系统盘 host file AIO active-read 自动选择
│   └── qemu-aio-probe.py     # 只读 QEMU 自身 4 KiB，不接触 VM 磁盘
├── fb-shm-stream.sh           # 每 VM ROI/编码推流 sidecar 生命周期
├── finish-vgpu-install.sh     # 仅统一前旧回执/UTC RTC 兼容；当前新 VM 不使用
├── connect.sh                # vGPU stream/relay 模式的外部 SDL viewer 入口
├── service.sh                # vGPU stream/relay 模式的 guest 服务控制
├── tests/
│   ├── vgpu/                 # 本分支部署与生命周期测试
│   └── qemu/                 # 本分支依赖的 QEMU 源码静态测试
├── lib/
│   ├── bridge-network.sh     # QEMU 创建 TAP 前的物理 bridge fail-closed 门禁
│   ├── cpu-isolation.sh      # QMP vCPU TID 获取与 CPU 隔离启动/回滚
│   ├── nvidia_modes.py       # 锁定 GRID 538.33/旧策略 → 8 项 R535 page-safe 模式
│   ├── windows_hive.py       # 按 REGF Length 只读校验活动 hbin，保留物理 slack
│   ├── vm-storage.sh         # VM/ISO/config/base/NVRAM 统一路径解析
│   ├── vm-tpm.sh             # swtpm TPM 1.2/2.0 生命周期与精确清理
│   └── vgpu-mdev.sh          # mdev 动态分配/回收（带 16 GB 上限检查）
├── host/
│   ├── cpu-isolate.sh        # 固定 cgroup v2 产品分区的 root helper
│   ├── install-cpu-isolation.sh # 安装 root-owned helper 与受限 sudoers
│   ├── netplan-br0.yaml      # 旧手工模板（新部署不用再手改）
│   ├── setup-vgpu-unlock.sh  # 编译 vgpu_unlock-rs + LD_PRELOAD 注入 systemd
│   ├── profile_override.toml # nvidia-256/257 单头 FHD/1GB/2GB；每 VM 名称+显示合同按 mdev UUID 生成
│   ├── sync-monitor-cache.sh # 关机态写 FHD/1K EDID + NVIDIA NV_Modes 并清缓存
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
配置、运行态和每 VM 锁集中在 `vms/N/`，公共 base 与 V-11 一样位于
`vms/_base/`。完整目录树见
[`docs/STORAGE-LAYOUT.md`](docs/STORAGE-LAYOUT.md)。

## 一次完整部署顺序

### 0. 宿主前置

1. 内核加 `intel_iommu=on iommu=pt`，重启后 `dmesg | grep -i iommu` 确认 DMAR 启用。
2. 加载 `vfio-pci` + `vfio-mdev` 模块。
3. NVIDIA vGPU host driver 已装，`nvidia-smi vgpu` 能列出支持的 type。当前 535
   栈提供 VFIO REGION display，不提供 DMA-BUF；guest GRID 驱动必须与该 host
   branch 和所选 profile 兼容。
4. 物理显示靠 AMD RX 570/580，不要让 Ubuntu desktop 动 NVIDIA 卡。若宿主进入桌面前
   花屏、桌面与 guest 正常，运行 `./deploy/host/g11-host-display.sh audit` 并按
   [`docs/G11-HOST-DISPLAY-BOOT-FIX.md`](docs/G11-HOST-DISPLAY-BOOT-FIX.md) 修复。
5. 安装 TPM/应答 ISO/推流运行时：
   `sudo apt install swtpm swtpm-tools xorriso ffmpeg`。默认 TPM 启动会 fail-closed；
   不会因缺包而悄悄启动成一台无 TPM 的 VM。
6. CPU 隔离依赖 `sudo`、`python3`、`util-linux`（`taskset`/`flock`）、
   `diffutils` 以及 cgroup v2 `cpuset` controller。`sudo` 是提权入口，必须预先
   可用。默认 `required`；建议先交互执行 `sudo -v`，再提前执行
   `sudo ./deploy/host/install-cpu-isolation.sh`。无人值守确需凭据时，只能通过
   批准的安全渠道或运行时环境变量提供，不得写入仓库、配置或命令历史。
   不传资源策略参数等价于 `--cpu-isolate=true --memory-prealloc=true`；只有显式
   `--cpu-isolate=false` 才会关闭隔离。

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
# 在宿主本地控制台只执行这一条；自动识别网卡、正常关闭 G-11 VM、
# 自行调用 sudo、配置 VLAN-aware br0，并在确认前保持自动回滚。
cd /home/ubuntu/projects/qemu
./deploy/scripts/setup-bridge.sh
```

封装不会改写已有用户 Netplan 文件；它安装一前一后两个 G-11 受管 override，
保留物理口 MAC，并用独立 systemd watchdog 在未确认/失败时回滚。默认启动走
原生 LAN，`--vlan-id VID` 动态创建 access TAP；两条路径都会在创建 QEMU 网络前
做完整门禁。交换机 trunk、DHCP、白名单及故障恢复见
[`docs/G11-NETWORK-BRIDGE-VLAN.md`](docs/G11-NETWORK-BRIDGE-VLAN.md)。

### 4. 可选：预选 VM 身份

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/check-hardware-pool.sh
./deploy/scripts/create-vm.sh --list-cpu-profiles
./deploy/scripts/create-vm.sh --list-board-profiles
./deploy/scripts/create-vm.sh --list-memory-profiles
./deploy/scripts/create-vm.sh --list-platforms
./deploy/scripts/create-vm.sh --list-ssd-profiles
./deploy/scripts/create-vm.sh --list-gpu-profiles
./deploy/scripts/create-vm.sh --list-monitor-profiles
./deploy/scripts/create-vm.sh --list-input-profiles
# 只有排障或明确要用旧平台时才查看兜底行：
./deploy/scripts/create-vm.sh --include-fallback --list-platforms
# 日常可跳过；start-vm 会在配置不存在时自动随机生成
# 未给 --gpu-profile/GPU_PROFILE 时，只从宿主固定显存档的生产池抽取并永久写入 vm.conf。
./deploy/scripts/create-vm.sh 2 \
  --memory-size 8G \
  --ssd-profile samsung-850-pro-512gb \
  --gpu-vram 2048 \
  --monitor-profile dell-p2419h
# 上面只锁 8G 内存和 2048 MB 显存；脚本仍会各自抽取并保存一条完整审核 profile。
# 若必须新建兜底平台，先在完整目录中确认，再同时显式授权：
# ./deploy/scripts/create-vm.sh 3 --platform i5-6500 --allow-fallback-platform
# 每个 VM 的组件选择及可持久化身份写入 vms/N/vm.conf；GPU/USB 不虚构序列号。
# 普通可见池为 11 CPU/13 块 H81+X79/434 套，覆盖 2C2T 到 6C12T 五种规格。
# 傻瓜入口：./deploy/scripts/create-home-vm.sh 3 --spec 4c4t --memory-size 8G
# 精确入口：./deploy/scripts/create-vm.sh 3 --cpu-profile i7-4930k --board-profile asus-p9x79 --memory-size 4G
# 4/8 GiB 为两根真双通道，12 GiB=3×4 GiB 三通道，16 GiB=4×4 GiB 四通道。
# 旧 6 GiB 组合均 archived；H81 的 4G/8G 已恢复，12/16G 仍只允许至少四槽主板。
# 硬件合同 v3 把每槽 Rank/device-width/JEP106/part/独立 serial 同步到 SMBIOS/SPD；
# Micron 的 18-byte SPD 字段使用对应 -1G6/-1G4 基础 part；legacy DDR4 仍 page0-only。
# 默认 8G，优先 i7-4960X + DDR3-1866，再按宿主 realization、同规格和共同频率上限回落。
# SSD 为七款 SATA + 三款 Gen3 x4 NVMe，十款均精确 512110190592 字节；自动先 NVMe，
# i7-3820/不兼容链路会合理回退 SATA；
# GPU 池为三款 1GB + 三款 2GB NVIDIA、共 25 条多品牌原子行；2GB 默认层 12 条、1GB R535 安全层 4 条、显式层 1 条、Kepler 旧配置层 8 条；显示器完整目录 35 款且全部 FHD 1920×1080@60，
# 其中新建池 28 款。
# 键盘 active 为 Microsoft/Logitech/Dell；可选相对鼠标也是这三品牌。
# 默认绝对指针只有 QEMU 通用 profile；三类 USB 都是 iSerialNumber=0。
# 输入选择会写入配置并显示；默认 PS/2 输入会关闭，避免重复枚举。
# q35/ICH9-AHCI、qemu-xhci、QEMU nvme、救援 std-vga 和 legacy ivshmem
# 是实现/兼容边界，不计作可替换品牌。
# 显示器先等概率抽品牌、再抽具体型号；品牌/型号也以
# MONITOR_BRAND_NAME / MONITOR_MODEL_NAME 明确写入配置。
# RTX 2080 宿主整池只选 nvidia-256/1024MB 或 nvidia-257/2048MB 其中一档；
# V100 同样固定为 V100-1Q 或 V100-2Q 其中一档，不能在同一物理 GPU 混用。
# mdev 显示器 EDID 在关机状态由 host 离线同步；guest 内不装常驻脚本/任务。
# 当前 25 条 B/native 统一使用私有 VgpuPortable.exe；不再按型号运行 finish。
# 只有统一前 GTX750Ti/GT1030 的旧 UTC/回执兼容才保留 finish-vgpu-install.sh。
# 任何型号磁盘已休眠时都先走 recover-hibernated-vm.sh。
```

### 5. 一条命令建空盘 + 初次装 Windows (NO_VFIO install 模式)

以下生命周期命令都从仓库根目录执行；不要依赖前面宿主准备步骤留下的当前目录。

```bash
# 缺 vm.conf 自动创建；缺盘固定 --blank，即使公共 base 存在也不会复制
# ISO 省略时使用 /home/ubuntu/images/iso/win10.iso
./deploy/scripts/start-vm.sh 1 --install
# 安装模式不挂 vGPU，直接弹出 std-vga + QEMU GTK 窗口
# 鼠标移入并聚焦窗口后自动抓键；Ctrl+Alt+Del 发给 guest，移出后还给宿主
```

低级调试时仍可显式拆成 `./deploy/scripts/create-vm.sh`、
`./deploy/scripts/create-disk.sh 1 --blank`、
`./deploy/scripts/start-vm.sh 1 --install`；正常操作不需要拆分。

装好 Windows 后去掉 CD，先按下一节用统一安全入口安装 GRID driver；不要
使用旧 `--no-gpu` + VNC 救援。driver 装好并完整关机后，当前全部 profile 都按第 8 节使用
私有 `VgpuPortable.exe`。若磁盘已经处于休眠/Fast Startup，任何型号都先运行
`recover-hibernated-vm.sh` 的本地标准 VGA 恢复。

RTC 统一由宿主负责：QEMU 进程使用 `TZ=Asia/Shanghai`，并传入
`-rtc base=localtime,clock=vm,driftfix=slew`。新装 Windows 不写
`RealTimeIsUniversal`。当前 `RTC_CONTRACT=localtime` VM 不需要额外 RTC 收尾。
只有统一前、明确标记 `base=utc` 的 GTX750Ti/GT1030 legacy B VM，才在完整关机后
使用 `finish-vgpu-install.sh` 兼容迁移；不要在 guest 内运行旧 RTC 修复脚本。

### 6. 装 vGPU guest 驱动（vGPU 真 PCI ID）

运行 `./deploy/scripts/vmctl.sh driver-install 1`。封装让匹配的 GRID INF 看见真实
vGPU PCI ID，但由临时标准 VGA 承担窗口、mdev 固定 `display=off`；安装成功后自动
完整关机并离线认证/写入安全模式表。默认保持关机，license 留到第 8 节统一收尾。

### 7. 消费卡身份策略

所有新配置及当前支持的 25 条 GPU 原子 profile 都使用 B：`--spoof-name-only` 保留
`DEV_1E30`，并按稳定 mdev UUID 注入消费卡名称。GTX1050 也不会由脚本自动切 A，
日常只需：

```bash
./deploy/scripts/start-vm.sh 1
```

新 base 不应包含旧 GPU 名称任务。历史 base 若仍有
`RefreshGridNames`/WMI 残留，系统身份安装器会在枚举后重新发布完整当前合同；
不要手工删除任务或拼注册表字段。per-mdev 覆写只改产品名，不会改变物理 GPU 的
核心数、频率、总线位宽、调度份额或真实性能。

严格 A 的历史实验只覆盖 GTX1050，但其修改 INF/自签 catalog 的 transition 已禁用；
受支持状态保持 B。VM3 已迁移并验收为 B/native 成品；底层资源仍是
`nvidia-257`，因此原始 PnP 身份是 vGPU 的 `DEV_1E30`，而不是消费卡
`DEV_1C81`。设备管理器名称与系统 NVAPI profile 可以显示 GTX 1050，但不会伪造
底层资源为真实 GP107。生产签名边界见
[`docs/DRIVER-INSTALL.md`](docs/DRIVER-INSTALL.md)。

这里不需要 RDP、ivshmem driver 或抓屏 relay。vGPU stream/relay 模式才使用
`./deploy/scripts/start-vm.sh 1 --legacy-shmem`（`--rdp` 同义）。

### 8. License & 验证

当前 GT730、GT740、GTX750、GTX750Ti、GT1030、GTX1050 的 B/native 流程统一执行：

```bash
chmod 600 /home/ubuntu/images/staging/client_configuration_token.tok
./deploy/package-vgpu-one-click.sh --with-license-token
```

把 `VgpuPortableLicensed/VgpuPortable.exe` 安全复制到正常 B 启动的目标 VM，双击
后必须同时看到身份 INSTALL PASS、Code 0、`License: Licensed`、休眠/Fast Startup
已关闭和性能优化 APPLY PASS。完整关机后再普通冷启动。默认无 token 版负责
身份/查询和相同性能优化，但不能据此声称授权完成。

GTX1050 strict-A 旧自签 ZIP 已禁用并归档。`finish-vgpu-install.sh` 只服务统一前
GTX750Ti/GT1030 的旧 UTC/回执兼容，不用于当前新 VM。B/off 继续按 DLS
`Licensed` 验收。完整矩阵见
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
  `-rtc base=localtime,clock=vm,driftfix=slew`；新装不写
  `RealTimeIsUniversal`。统一前 GTX750Ti/GT1030 的旧 UTC legacy B VM 完整关机后
  才按需用 `finish-vgpu-install.sh` 离线迁移；当前新 VM 不运行。休眠实例先用
  `recover-hibernated-vm.sh` 取得干净关机。

- GRID 驱动"只装了半截"(缺 `nvlddmkm.sys`, `nvwgf2umx.dll`) 是历史最频繁故障 — 永远先 Express Install 再改 INF。
