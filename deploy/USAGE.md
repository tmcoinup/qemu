# 使用手册

现场第一次操作优先看
[`docs/G11-QUICKSTART.md`](docs/G11-QUICKSTART.md)：它以无 VM 绑定、不内嵌 GPU-Z 的
`VgpuPortable.exe`、默认单文件 base 注入和任意 B/native VM 克隆为主流程；
GPU-Z 只在以后显式选择时从官网取得并受审计导入；实际 VM 的 token/授权/电源
收尾使用显式私有版，同一 EXE 覆盖三款型号；旧 A
迁移的按 VM 关机提交单独保留。

新建 VM 请直接按
[`docs/VGPU-VM-CREATION.md`](docs/VGPU-VM-CREATION.md) 操作。它包含空盘安装、
真实 RTX6000-2Q PCI 身份安装 538.33、host per-mdev 名称和 base 克隆的完整顺序。
其中历史 GTX1050 自签 ZIP 收尾已禁用；新 VM 保持 B，等待正式生产签名驱动。
已有原版 WHQL + Code 0 qualification 时，任意匹配 VM ID 的 outer-only 流程与
完整关机步骤见 [`docs/SIGNED-CONSUMER-PRODUCTION.md`](docs/SIGNED-CONSUMER-PRODUCTION.md)。
如果是从 V-11 切换操作习惯，先看
[`docs/G11-V11-OPERATION-PARITY.md`](docs/G11-V11-OPERATION-PARITY.md)：它列出已对齐项、
vGPU 有意保留的差异和可直接照抄的运行中显示切换命令。

## 入口脚本

本分支只有 NVIDIA mdev/vGPU 一套 VM 生命周期。规范用户入口统一为
`deploy/scripts/create-vm.sh`、`deploy/scripts/start-vm.sh` 与
`deploy/scripts/stop-vm.sh`；这里也是唯一实现位置，不保留 `deploy/` 下的同名旧入口。native、
stream/relay 和 `--rdp` 只是同一 vGPU VM 的显示模式。
G-11 与 V-11 是独立分支；脚本位置统一不等于 GPU、显示驱动或验收策略可以混用。

```
./deploy/scripts/start-vm.sh <vm_id> --install [iso]          # 缺盘自动空盘；默认跳 OOBE
./deploy/scripts/start-vm.sh <vm_id> --install [iso] --install-media ide # 慢速兼容回退
./deploy/scripts/start-vm.sh <vm_id> --install [iso] --manual-oobe # 完整手动 OOBE
./deploy/scripts/start-vm.sh <vm_id> --spoof-name-only       # 通用安全 B + QEMU SDL 直显
./deploy/scripts/start-vm.sh <vm_id> --gtk --spoof-name-only # 相同 B 路径，改用 GTK
./deploy/scripts/start-vm.sh <vm_id>                         # 使用 vm.conf 已验收的持久模式
./deploy/scripts/start-vm.sh <vm_id> --no-numlock            # 仅本次允许 NumLock 保持关闭
./deploy/scripts/start-vm.sh <vm_id> --legacy-shmem   # 旧 ivshmem + guest relay + SDL viewer
./deploy/scripts/start-vm.sh <vm_id> --rdp            # --legacy-shmem 的兼容别名
./deploy/scripts/start-vm.sh <vm_id> --proxy          # host QMP 多客户端（不是网络代理）
./deploy/scripts/start-vm.sh <vm_id> --no-tpm         # 仅诊断：关闭主板 profile 对应的 TPM
./deploy/scripts/start-vm.sh <vm_id> --vlan-id 11     # 接入 VLAN 11；不带参数为默认 LAN
./deploy/scripts/start-vm.sh <vm_id> --print-paths    # 只读显示默认 G-11 bundle
./deploy/scripts/start-vm.sh <vm_id> --vms-dir /abs/vms --print-paths
                                                # 指定完整根，自动选择 /abs/vms/N
./deploy/scripts/start-vm.sh <vm_id> --vm-dir /abs/path/N --print-paths
                                                # 精确选择单 VM bundle
./deploy/scripts/start-vm.sh <vm_id> --instances-dir /abs/pool --print-paths
                                                # 选择父目录，自动追加 N
./deploy/scripts/stop-vm.sh <vm_id> --vms-dir /abs/vms
./deploy/scripts/stop-vm.sh <vm_id> --vm-dir /abs/path/N
./deploy/scripts/stop-vm.sh <vm_id> --instances-dir /abs/pool
                                                # 停机必须重复启动时的路径选择器
./deploy/scripts/vmctl.sh {path|start|stop|status|delete} <vm_id> [...]
                                                # 不保存凭据的日常封装
./deploy/scripts/vmctl.sh display <vm_id> status         # 核对 QMP 身份并查看窗口/推流状态
./deploy/scripts/vmctl.sh display <vm_id> window-hide    # 运行中隐藏默认 SDL 窗口
./deploy/scripts/vmctl.sh display <vm_id> window-show    # 恢复 SDL 并强制重画静止桌面
./deploy/scripts/vmctl.sh migrate --check              # 旧 G-11 布局只读检查
./deploy/scripts/vmctl.sh migrate --apply              # 全部 G-11 VM 停机后显式迁移
./deploy/scripts/check-hardware-pool.sh        # 只读审计目录和本机 KVM CPU 能力
./deploy/scripts/create-vm.sh --list-cpu-profiles
./deploy/scripts/create-vm.sh --list-board-profiles
./deploy/scripts/create-vm.sh --list-memory-profiles
./deploy/scripts/create-vm.sh --list-platforms # 查看 28 套审核整机及 new/explicit/legacy 策略
./deploy/scripts/create-vm.sh --list-ssd-profiles
./deploy/scripts/create-vm.sh --list-gpu-profiles
./deploy/scripts/create-vm.sh --list-monitor-profiles
./deploy/scripts/create-vm.sh --list-input-profiles
./deploy/scripts/create-vm.sh --list-input-compat # 只查旧 VM 的兼容/隔离记录
./deploy/package-vgpu-one-click.sh             # 推荐：生成无 VM 绑定、不内嵌 GPU-Z 的 VgpuPortable.exe
./deploy/package-vgpu-one-click.sh --with-license-token # 私有：三款统一身份+token+Licensed+关闭休眠
./deploy/package-vgpu-portable.sh --list-gpu-profiles # 查看 12 条原子板卡/显存合同
sudo ./deploy/install-vgpu-portable-to-base.sh # 默认只将 portable EXE 一次性安全注入 base
./deploy/scripts/vmctl.sh clone <vm_id> [--gpu-profile PROFILE] [--start] # GPU 可省略随机；自动生成/同步显示器
./deploy/package-vgpu-one-click.sh <vm_id>     # legacy：A 迁移或旧 B 的 VM 绑定包
./deploy/package-gpuz-profile.sh <vm_id> [...] # legacy B 的 VM/UUID 绑定 GPU-Z 包
./deploy/package-vgpu-production-migration.sh <vm_id>         # legacy A → 原始签名 538.33 + B 的 guest 单 EXE
sudo ./deploy/commit-vgpu-production-migration.sh <vm_id>     # guest 关机后只读核验回执并原子提交 B
./deploy/signed-consumer-production.sh stage <vm_id>          # 匹配全局 qualification，生成 UUID 绑定的只读 ISO
./deploy/signed-consumer-production.sh status <vm_id>         # 查看该 VM 的通用 outer-only 合同状态
sudo ./deploy/signed-consumer-production.sh record-proof <proof_vm_id> --experiment-id ID --confirm-source-proof
sudo ./deploy/signed-consumer-production.sh commit <vm_id> --experiment-id ID
sudo ./deploy/signed-consumer-production.sh finalize <vm_id>  # SYSTEM 验收关机后固化 validated
sudo ./deploy/signed-consumer-production.sh rollback <vm_id>  # 精确恢复原 B/name-only vm.conf
./deploy/scripts/recover-hibernated-vm.sh <vm_id> [--rescue-gtk] [--proxy] # host-only 标准 VGA 休眠恢复 + 离线同步
./deploy/finish-vgpu-install.sh <vm_id>              # 仅统一前 GTX750Ti/GT1030 旧回执/UTC 兼容；当前新 VM 不用
./deploy/scripts/stop-vm.sh  <vm_id>                  # 关 VM（Ctrl+C/关原生窗口也行）
./deploy/scripts/report-vm-boot-timing.sh <vm_id>      # 只读分段时间，不需 guest IP
./deploy/scripts/setup-bridge.sh                   # 一键识别上联并建立 VLAN-aware br0
./deploy/scripts/setup-bridge.sh inspect           # 可选：只读检查 br0/上联/活动 VM
./deploy/scripts/setup-bridge.sh verify            # 可选：验证 L2、DHCP、默认路由与 VLAN runtime
```

普通启动默认执行物理 bridge 健康门禁：`br0` 为空、无 carrier 或物理上联未加入时
会在 QEMU TAP 创建前失败，并指向上述封装。一键命令先完成依赖预检，再只对可
识别的 G-11 VM 请求正常关机，通过系统 sudo 迁移 DHCP 上联；未在时限内输入屏幕
给出的精确确认会由独立 watchdog 回滚。教程见
[`docs/G11-NETWORK-BRIDGE-VLAN.md`](docs/G11-NETWORK-BRIDGE-VLAN.md)。

G-11 已开放完整的 `--vlan-id VID` 生命周期：root-owned helper 逐 VM 创建
`g11t<VM_ID>`，做白名单门禁和 access/PVID 配置；启动失败、QEMU 退出及停止脚本
均会幂等回收。未携带 VLAN 参数时使用默认原生 LAN，不会继承 `vm.conf` 中的 VID，
VLAN 失败也不会静默回退。

active 池包含 6 款 CPU、4 块双槽 H81 主板和 15 套双条 DDR3 内存，内存覆盖
Kingston、Samsung、Micron、SK hynix 四品牌。创建器只从审核整机白名单筛选，
不能任意笛卡尔组合。默认低端池为 24 套 4/6/8 GiB 组合；
i7-4790 的 8 GiB 组合不参加正常随机，通常只能显式创建；5 款默认 CPU 均未
得到 `enforce=on supported`、且 i7 自身明确 supported 时，无参数创建会先把
i7 作为 active 能力兜底。
完整目录另保留 i5-4590/H97、i5-6500/B150、i3-8100/B360 三套 legacy，正常随机
不使用；只有连 i7 在内的 6 款 active CPU 都明确不可用时才自动 legacy 兜底。
另有 9 款精确 `512110190592` 字节 SSD（Samsung、Crucial、Kingston、Intel、WD）、
3 个 2 GB GPU 目标型号、12 条系统用户态原子 profile（板卡 metadata 覆盖
NVIDIA、ASUS、Dell、MSI、Gigabyte、GALAX、Colorful（七彩虹）；显存厂家覆盖 Samsung、
SK hynix、Micron），以及 35 款全部为
1920×1080@60 的显示器（新建 8 品牌/28 款，完整 11 品牌）。active 键盘和可选
相对鼠标各为 Microsoft、Logitech、Dell 三品牌；默认绝对指针是唯一的 QEMU 通用
profile。`q35`/ICH9/ICH9-AHCI、`qemu-xhci`、QEMU `nvme` controller、安装/救援
`std-vga` 和 legacy `ivshmem` 是实现/兼容边界，不进入品牌扩展。4 GiB=2×2 GiB、
8 GiB=2×4 GiB，均为真双通道；6 GiB=4+2 GiB
Intel Flex，只是匹配的 4 GiB 区双通道，额外 2 GiB 区单通道。创建和每次启动
都会联合检查 CPU/主板、逐槽内存、SSD 链路、2 GB mdev、GPU PCIe 宽度及 TPM，
详见 [`docs/G11-HARDWARE-POOL.md`](docs/G11-HARDWARE-POOL.md)。

新建 VM 的硬件合同 v3 延续了 system/baseboard/chassis 三个标签共用所选主板品牌
语法的旧关系；三个值互不重复，但只有 baseboard serial 天然归主板厂，system/
chassis 是整机集成商或资产所有者语义。SSD 使用型号专属严格序列，从非保留
`MEM_SN` 为每个 DIMM 稳定生成不同的 JEDEC 4-byte 序列，并把完整
`MEM_SERIAL_LIST` 持久化；所有最终槽值在统一 `MEMORY_SERIAL` 命名空间跨 VM
查重。DDR3 启动时
逐槽容量、Rank、device width、module/DRAM JEP106、serial、part 必须原子一致，
同时进入 SMBIOS 和 SPD。Micron E1 目录 SKU 在 18-byte SPD part 字段使用
`MT4JTF25664AZ-1G6` / `MT8JTF51264AZ-1G6` 基础 part。两套 legacy DDR4 仍为
256-byte page 0-only，身份留在 SMBIOS Type 17。GPU 与 USB 输入的序列策略分别为
`not-exposed` 和 `none`，不会拿 mdev UUID 或虚构 USB `serial=` 充数。显示器只有
Samsung S24F350/Redmi RMMNT238NF 是已审核的型号专属格式，其余 33 款明确使用
`generic-prefix-hash`。创建器全局查重、撞号重抽，启动器再次复核；旧配置不会被
静默重写成 v3；缺列表的 v1/v2/v3 配置只会稳定派生，不会落盘改写。

若 guest 禁止测试签名和自签名，按
[`docs/GPUZ-ONE-CLICK.md`](docs/GPUZ-ONE-CLICK.md) 使用
portable 主流程。默认产物为
`$STAGE_DIR/VgpuPortable/VgpuPortable.exe`，内嵌 GTX 750 Ti、GT 1030、
GTX 1050 的 12 条锁定原子 profile，但不内嵌 GPU-Z 程序，也没有 VM ID/UUID。
板卡、subsystem、VBIOS、时钟、显存厂家和 NVAPI enum 必须整行匹配，不能单独
覆盖。首次及普通安装默认不读取、不要求也不安装 GPU-Z；它会安装受保护的身份
组件和 `vGPU Identity Query`。以后需要 GPU-Z 时，把官方审计的 2.70 x86 精确
命名为 `GPU-Z.exe` 放在同目录，再显式运行 `VgpuPortable.exe /with-gpuz`；锁定的
SHA-256 为
`6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29`。错误或被篡改的
sidecar 只会让显式选装失败，并且失败发生在 profile 写入前。base 注入器默认只
写入一个 EXE；显式 `--with-gpuz` 才预置两文件。两种方式均不需要为每台 VM
重新封装。

每次正常 `start-vm.sh` 启动会自动发布只读 SMBIOS profile/UUID/catalog 声明。
guest 只在声明、当前 UUID、原生 `DEV_1E30`、538.33、Code 0、DriverStore/
`nvlddmkm.sys` 正式签名、BCD 和单 Display 全部一致时应用 profile。包不会安装或
重签显示驱动，不修改 BCD、Driver Store、系统 NVAPI DLL、网络服务或设备节点。
这允许 EXE 跨 VM 使用，但不允许 guest 任意选择身份；安装完成后无需人工 host
commit。

上述 portable 是基础盘/授权和 app-local 兼容层。成品 VM 需要让普通 32/64 位
NVAPI 程序都显示同一板卡/显存身份并持久恢复 monitor 时，再生成 VM-bound 系统包：

```bash
./deploy/package-system-nvapi-projection.sh 456
```

它只替换系统用户态 NVAPI 转发 DLL，保存并验证相邻的 NVIDIA 正式签名原件，
不触碰 INF/CAT/SYS 或 BCD。系统模式保留 real `10DE:1E30` vendor/device，只合并
profile Subsystem 与静态字段，所以 PnP、DXGI/D3D 和 NVAPI 仍是一块逻辑显卡。
完整步骤见 [`docs/G11-BOTTOM-GPU-IDENTITY.md`](docs/G11-BOTTOM-GPU-IDENTITY.md)。

实际 VM 还需要 DLS 授权时，token 权限设为 `0600` 后运行
`./deploy/package-vgpu-one-click.sh --with-license-token`。独立输出
`$STAGE_DIR/VgpuPortableLicensed/VgpuPortable.exe` 含 token，双击后必须看到
`Licensed`，并会关闭休眠/Fast Startup。它不得写入通用 base、提交仓库或公开分发；
默认 `VgpuPortable/` 产物仍不含 token。

portable 阶段可使用安装器创建的 `vGPU Identity Query` 快捷方式初验板卡和显存厂家；必须
同时看到原生 `DEV_1E30`、所选投影行和最后的 `VERIFY PASS`。只有显式选装
GPU-Z 后，才使用 `GPU-Z (vGPU profile)` 快捷方式查看兼容显示。桌面原有的
TechPowerUp GPU-Z 从另一目录启动，不会继承 app-local shim，所以可继续显示原生
TU102 或核心字段。profile 快捷方式本身也可能在 `GPU`/Technology/Die Size 等未覆盖
字段中显示 TU102/12 nm/754 mm²。完成系统包后，应以包内 x86/x64 probe、单
Display 和 validated 收据作为最终验收；不要手工替换 DLL。

最短流程：

```bash
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh
./deploy/scripts/vmctl.sh clone 456 --start
```

第二条必须在所有 VM 完整停止、base 无 backing/data-file、Windows NTFS 干净且
未休眠时执行。脚本只写私有临时副本，验证、卸载和 `qemu-img check` 完成后才
归档旧 base 并原子替换；不要强制挂载 dirty/hibernated NTFS。第三条不指定
`--gpu-profile` 和 `--monitor-profile`，会分别从审核池随机一次并写入 `vm.conf`，
随后同步显示器；`--start` 只决定是否马上开机。以后每次正常启动仍会自动校验，
不需要另跑 `vmctl monitor`。

VM3 已按
[`docs/VGPU-PRODUCTION-MIGRATION.md`](docs/VGPU-PRODUCTION-MIGRATION.md)
完成原始 GRID 538.33 + B/native 迁移；当前实测为 Code 0、1920×1080、
Microsoft WHCP signer、BCD 安全选项关闭及 GPU-Z 2.70 GTX 1050/WHQL。只有其他
旧 A 实例继续使用带 VM_ID 的绑定迁移 EXE，并在停止磁盘回执通过后提交配置。

新增 GPU 型号必须先审计 identity catalog、精确 PnP/NVAPI 字段和允许模式，并
验证对应的正式生产签名驱动。封装器不会猜测未知型号，也不会开启 `testsigning`、
`nointegritychecks`、修改任何 BCD 项或安装测试签名/自签名内核驱动。

HWiNFO64 等交叉查询工具在完成系统包后也使用同一 x64 NVAPI 投影，无需按程序名
适配；但它们从 PCI config、WMI、DXGI 或驱动私有执行接口读取的非合同字段仍保留
原生值。以 present Display、NVAPI physical GPU count 和 DXGI adapter count 判断
是否一块卡，不要把多个数据源误算为多个设备，也不要手工覆盖系统 DLL。

## QMP 多客户端

需要让调试器、管理脚本和临时 `socat` 同时连接 QMP 时，用一条命令启动：

```bash
./deploy/scripts/start-vm.sh 1 --proxy
```

它启用本分支 QEMU 的原生 `multi=on`，不启动 Python 中转进程，也不改变
HTTP/SOCKS、VM 网卡或 guest 流量。客户端可连接主路径
`/home/ubuntu/images/vms/1/run/qmp.sock`；同时会创建
`qmp.sock.proxy` 软链接兼容旧工具配置。默认不开启，环境变量 `PROXY=1` 等价；
命令行 `--no-proxy` 可显式覆盖环境或 VM 配置。`--dry-run --proxy` 只显示最终
QEMU 参数，不创建或删除任何 socket/软链接。

## CPU 隔离

CPU 隔离默认是 `required`：启动器从 QMP `query-cpus-fast` 取得真实 vCPU TID，
为每个 vCPU 分配一个逻辑 CPU。`service CPU` 默认是 `auto`：可用容量足够时为
QEMU 主循环、显示和 IO 线程留 1 个专用逻辑 CPU；不足时自动回退为 0，
但每个 vCPU 的 1:1 绑核不变。只有显式传 `--svc-cpus N` 时才严格要求该数量、
容量不足也不自动降级。普通启动会给 QEMU 加 `-S`，隔离完成后才放行
guest；失败则终止本次 VM。

首次普通启动若发现 root helper、sudoers 或
`python3`/`taskset`/`flock`/`cmp` 缺失，会自动调用安装器；`sudo` 本身必须
预先可用。优先提前运行 `sudo -v`；无人值守场景需要凭据时只通过批准的安全渠道
或运行时环境变量提供，仓库没有默认密码。也可提前手工安装：

```bash
sudo ./deploy/host/install-cpu-isolation.sh

./deploy/scripts/start-vm.sh 1                     # 默认 required；失败即终止
./deploy/scripts/start-vm.sh 1 --cpu-isolate       # 同默认行为，保留为显式兼容参数
./deploy/scripts/start-vm.sh 1 --cpu-isolate-auto  # 显式允许不可用时降级继续
./deploy/scripts/start-vm.sh 1 --no-cpu-isolate    # 明确关闭
./deploy/scripts/start-vm.sh 1 --svc-cpus 1        # 可选：为非 vCPU 线程另留一个逻辑 CPU
```

启动摘要默认应显示 `service CPUs=auto`；隔离完成行会按当时容量显示
`1 service CPU` 或 `0 service CPU`。用
`env -u QEMU_SERVICE_CPUS ./deploy/scripts/start-vm.sh N` 可排除环境覆盖；要固定策略则
显式传 `--svc-cpus 0` 或 `--svc-cpus 1`。

默认 `HOST_OOM_PROTECT=1` 会在启动 QEMU/swtpm/sidecar 前，通过同一个
root-owned helper 将当前 VM 进程树临时设为 `oom_score_adj=-500`。调用会
校验 VM ID、调用 UID 和 PID starttime；不写全局 sysctl，进程退出即失效。
该策略不代替 `MEM_GUARD` 容量门禁；明确接受运行期 OOM 风险时才可对单次启动
设 `HOST_OOM_PROTECT=0`。

系统盘的宿主文件 AIO 默认使用 `QEMU_DISK_AIO=auto`。每次真实启动会先用 QEMU
自身文件完成 4 KiB O_DIRECT active-read，按 `io_uring`、`native`、`threads`
顺序选择；不创建临时盘、不读取 VM 磁盘，也不改变 Windows 可见的存储身份。
启动摘要会打印最终后端。只有诊断时才固定
`QEMU_DISK_AIO=native|io_uring|threads`；显式内核后端探测失败会拒绝启动，
不会静默回退。完整傻瓜说明见
[`docs/G11-V11-OPERATION-PARITY.md`](docs/G11-V11-OPERATION-PARITY.md)。

当前 Linux 6.8 + NVIDIA vGPU 535 不提供较新的 PCI BAR dma-buf/P2P 导出接口。
这不影响普通 vGPU 显示，QEMU 会继续使用 mmap fallback。拉取本修复后先增量重编：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
./deploy/scripts/start-vm.sh 9
```

旧版连续三次打印的 `PCI BAR IOMMU mappings may fail: Invalid argument` 应消失；
新版本最多提示一次 `dma-buf unavailable, using mmap fallback, P2P DMA will not work`。
它只表示 PCI BAR 的 P2P DMA 不可用，不表示普通 BAR、IOMMU、REGION 画面或 VM
启动失败。

helper 只操作 cgroup v2 的
`/sys/fs/cgroup/qemu-vm-isolation/vmN`，并校验 QEMU PID、`-name vmN`、TID/Tgid
后才移动任务。`required` 会给 QEMU 加 `-S`，隔离成功后才发送 QMP `cont`；
任一步失败都会回滚 affinity/cgroup 并结束本次 VM。当前范围不含
`isolcpus`、`nohz_full`、IRQ affinity，也不等同于 NUMA 内存硬绑定。
如需禁止自动安装，显式设置 `CPU_ISOLATION_AUTO_INSTALL=0`；在默认 required
模式下，这会让缺依赖的启动直接失败，而不是静默关闭隔离。

## 固定区域网络推流

native SDL/GTK 可以保留本地窗口，同时通过 `fb-shm` sidecar 推一个固定 ROI：

```bash
# 默认 libx264、30 Hz、6M、SHM 完整帧
./deploy/scripts/start-vm.sh 1 \
  --stream 'rtmps://ingest.example/live/vm1' \
  --stream-roi 100,50,1280,720 \
  --stream-rate 60

# 显式用 NVENC；输入仍是 SHM rawvideo，随后发生 GPU upload，不是零拷贝
./deploy/scripts/start-vm.sh 1 \
  --stream 'srt://edge.example:9000' \
  --stream-encoder h264_nvenc --stream-bitrate 8M \
  --stream-preset p2 --stream-gop 120 --stream-mode shm

./deploy/fb-shm-stream.sh status 1
./deploy/fb-shm-stream.sh health 1
./deploy/fb-shm-stream.sh stop 1
```

启动时已显式配置 `--stream URL` 后，可在另一终端安全切换：

```bash
./deploy/scripts/vmctl.sh display 1 status
./deploy/scripts/vmctl.sh display 1 stream-only  # 先确认推流恢复，成功后才隐藏 SDL
./deploy/scripts/vmctl.sh display 1 window-only  # 先恢复 SDL，然后暂停 fb-shm listener
```

未启动 fb-shm 或连接了错误 VM 的 QMP 时会 fail-closed，不会先隐藏唯一窗口。
该控制仅支持默认 SDL；GTK 运行中隐藏/恢复仍是明确边界。

启动器会在分配 mdev 前做一次 128×128 单帧编码自检；编码器虽然出现在
`ffmpeg -encoders`、但驱动或运行库不可用时会直接拒绝。当前这台宿主的
`h264_nvenc` 仍因缺少可加载的 `libcuda.so.1` 失败，因此应先使用默认
`libx264`，或修复宿主 CUDA/NVIDIA 用户态运行库后再验收 NVENC。

输出必须是显式 `rtmp(s)`、SRT、UDP、RTP 目标或绝对本地文件；wildcard 和
listener 模式会在 QEMU 启动前被拒绝，已有本地文件也不会被覆盖。
`stop-vm.sh`、关闭本地窗口和启动失败都会精确回收 consumer 与 ffmpeg
进程组。当前只传视频，不包含音频、远程输入、ABR/CDN 调度或多区域边缘编排。

R535 vGPU 生产端只有 system-memory VFIO display REGION，没有 DMA-BUF。
因此 G-11 启动器会拒绝 `--stream-mode gpu`；`auto/shm` 都走 SHM/rawvideo。
`qemu-fb-shm-stream --print-capabilities` 会如实报告
`gpu.zero-copy=no`/`GPU_E_BACKEND_NOT_BUILT`，严格 `--mode gpu` 在连接前以
状态码 3 退出，不会静默回退并冒充零拷贝。

## 镜像和配置放在哪里

生产 vGPU 路径采用每 VM 一个 bundle：

```text
/home/ubuntu/images/
├── iso/                 # Windows ISO
├── staging/             # 驱动和 guest 安装脚本
└── vms/
    ├── N/               # 一台 G-11 VM 的完整数字 bundle
    │   ├── vm.conf
    │   ├── disk.qcow2
    │   ├── nvram.fd
    │   ├── tpm/state/   # 持久 TPM 1.2/2.0 NVRAM/EK 状态
    │   ├── log/{qemu,swtpm}.log
    │   ├── run/         # pid/socket/mdev + start/disk/tpm locks
    │   └── backups/{disks,nvram}/
    ├── shared/
    │   ├── bases/       # win10-base.qcow2 + archive/
    │   └── assets/      # host UI 共享资源
    └── control/         # 仅全局 .storage.lock 和迁移历史
```

旧 G-11 bundle 不会在正常启动时静默回退读取。全部 G-11 VM 停机后执行：

```bash
./deploy/scripts/vmctl.sh migrate --check
./deploy/scripts/vmctl.sh migrate --apply
```

迁移只接受可验证的 standalone qcow2；若任一待移动镜像带 backing、被其它
overlay 依赖或 metadata 无法解析，`--check` 会 fail-closed，必须先人工处理链。
依赖扫描也覆盖显式放在 `IMAGE_ROOT` 外的托管 disk/base 目录；`delete-vm.sh` 与
`promote-base.sh` 采用相同的 fail-closed 规则。

详细的停机保护、备份范围及旧 G-11 命名空间迁移规则见
[`docs/STORAGE-LAYOUT.md`](docs/STORAGE-LAYOUT.md)。

建盘和普通启动会先检查目标文件系统余量：默认硬门禁是
`max(16 GiB, 总容量的 5%)`，低于 10% 会告警。优先释放/迁移数据；仅紧急救援时对
单次命令使用 `DISK_FORCE=1`，并自行承担 qcow2/guest ENOSPC 风险。

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
   `./deploy/scripts/stop-vm.sh 1` 都会关闭 QEMU 并释放该 VM 的 mdev。
6. 可见窗口以 `16,666,667 ns` 绝对 deadline 提交（目标 60 FPS），
   标题实时显示 `SDL Present xx.x FPS`；隐藏或
   最小化时自动降频。这里显示的是 host Present 频率，不是 guest 独立帧数。
   静止 REGION 帧会被精确去重，因此桌面不变时显示 `0.0 FPS`；
   像素变化后自动恢复提交。

所有会挂载 vGPU 的模式都先在 `pcie.0` 的 `00:10.0` 创建专用 PCIe root
port，再把 VFIO endpoint 放到其下游（通常由固件枚举为 `01:00.0`）。端点不再
被 QEMU 当成 Root Complex Integrated Endpoint，PCIe Link Capability/Status
也不会因直挂根总线而被清零。root port 按目标卡声明 PCIe 3.0：
GTX 750 Ti/GTX 1050 为 x16，GT 1030 为 x4；Intel controller ID 和 revision
随 CPU profile 选择。启动器会在分配 mdev 前检查本分支 QEMU 的 link/identity
属性，缺失时 fail-closed。首次应用新拓扑时 Windows 会在新 BDF 重新枚举显卡，
但现有 vendor/device/subsystem identity policy 不变。

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
`VGPU_CONSOLE_INTERVAL_US=0 ./deploy/scripts/start-vm.sh 1` 可关闭；换 host driver 后应
重新做动态帧率验证。mdev 打开后 R535 会拒绝运行期改值，所以最小化只能减少
QEMU/SDL Present，不能把 manager 的 copy 周期动态降回 10 Hz。请勿设置
`disable_vnc=1`，它会一并关闭 SDL 依赖的 console REGION。

## 新建 VM：固定 2GB 的 NVIDIA 显卡池

日常入口会自动生成持久配置和磁盘；完整规则见
[`docs/VGPU-VM-CREATION.md`](docs/VGPU-VM-CREATION.md)：

```bash
# 有合格 base：自动生成配置、clone 系统盘并启动
./deploy/scripts/start-vm.sh 1

# 从 ISO：自动生成配置、创建空盘；默认跳 OOBE，使用空密码 Administrator，
# 中国大陆简体中文/China Standard Time，并默认开启 guest NumLock；RTC 由宿主处理。
# Windows ISO 默认经安装期 helper 自动引导到 xHCI USB 高速读取。
./deploy/scripts/start-vm.sh 2 --install /home/ubuntu/images/iso/win10.iso

# 需要人工选择区域和账号时才关闭自动 OOBE
./deploy/scripts/start-vm.sh 2 --install /home/ubuntu/images/iso/win10.iso --manual-oobe

# 仅默认 USB 路径异常时临时回退；该选择不会写入 vm.conf
./deploy/scripts/start-vm.sh 2 --install /home/ubuntu/images/iso/win10.iso --install-media ide

# 只有需要预选身份时才先显式 create-vm
./deploy/scripts/create-vm.sh --list-platforms
./deploy/scripts/create-vm.sh --list-ssd-profiles
./deploy/scripts/create-vm.sh --list-gpu-profiles
./deploy/scripts/create-vm.sh --list-monitor-profiles
./deploy/scripts/create-vm.sh 3 \
  --cpu-profile i3-4130 \
  --board-profile msi-h81m-p33 \
  --memory-profile kvr16n11s8-2x4 \
  --ssd-profile samsung-850-pro-512gb \
  --gpu-profile gtx1050_2gb
```

完整目录可查询 8 款 CPU、7 块主板和 17 套内存；其中 active 是 6 款 CPU、4 块
双槽 H81 和 15 套四品牌双条 DDR3。它们只能筛选 28 套审核整机白名单，不会做
任意笛卡尔组合。默认随机池为 24 套 4/6/8 GiB 低端组合；i7-4790 通常必须显式
指定，只在 5 款默认 CPU 均未 supported、且自身明确 supported 时作为 active
能力兜底。另 3 套整机为 legacy，且只有 6 款 active 都得到明确非 supported
结果才会自动选用。旧 i5-4590/H97 也属于
legacy，不要与新的
`i5-4590-h81m-*` 混淆。组件 key、合法组合及
`--cpu-profile`/`--board-profile`/`--memory-profile` 完整示例见
[`docs/G11-HARDWARE-POOL.md`](docs/G11-HARDWARE-POOL.md)。

存储选择还会比较主板与 SSD 的接口、PCIe 代际和通道。新 Haswell 白名单从
Samsung 840/850/860 PRO、Crucial MX100、Kingston KC400、Intel 545s、
Western Digital PC SA530 七款 SATA 盘中选择；Samsung 970 PRO 与 WD Black
两款 Gen3 x4 NVMe 保留给链路匹配的兼容平台。active catalog 与 default key
集合只有这九款，且每款均精确为 `512110190592` 字节；其他容量不能进入新建
目录。新配置也会持久化并传递逻辑/物理扇区：MX100 为
`512/4096`，当前其余型号为 `512/512`。显式 `--ssd-profile` 仍可在兼容层内
选择 SATA。qcow2
virtual-size 必须与 `SSD_SIZE_BYTES` 完全一致；
`--force` 不会跨容量/接口重绑旧盘，也不会把已生成的 TPM 状态换到
另一块主板。这类迁移应备份 BitLocker 恢复密钥后用新 VM_ID 或显式
的磁盘/TPM 迁移流程。

新配置会从 Microsoft、Logitech、Dell 三款 active 键盘中选一款，并默认持久化
唯一的 QEMU 通用绝对指针；创建与启动摘要都打印“键盘/鼠标”两行。QEMU 实际挂载
一个 `usb-kbd` 和一个 `usb-tablet`，并关闭默认 i8042/PS/2 键鼠，避免 guest 重复
枚举输入设备；后者保留无需相对鼠标 grab 的窗口行为。显式传入
`--relative-mouse` 或 `--mouse-profile` 时，才从 Microsoft、Logitech、Dell 三款
相对鼠标中选择并改为需要 grab 的 `usb-mouse`。这些 active USB profile 都使用
通用 HID report 且 `iSerialNumber=0`，不宣称完整复刻真机协议。

旧无输入合同配置仍可稳定加载 Microsoft 键盘与 HUION PenTablet 历史 tuple；HUION
行只在 compatibility/quarantine 目录，不进入新建或随机池，也不代表 QEMU 已实现
其压力、倾角或复合接口协议。

> 边界：上述主板是 SMBIOS/SPD/设备身份 profile；当前 QEMU machine/板载 SATA
> 仍是 `q35`/ICH9/ICH9-AHCI，并非完整仿真 H81/H97/B150/B360 PCH。USB 控制器
> 仍是 `qemu-xhci`；NVMe 即使带审核过的型号、序列和 PCI metadata，控制器行为仍由
> QEMU `nvme` 实现。安装/救援 `std-vga` 是临时显示，legacy `ivshmem` 只是旧 relay
> 传输通道。以上均不能按可替换消费品牌理解。

显示器完整目录为 35 款，新建池为其中 28 款 21.5、23.8/24、27 英寸
FHD 1920×1080@60 型号（Samsung、Dell、BenQ、AOC、Philips、Lenovo、ASUS、
Redmi）。完整目录与新建池都强校验 preferred timing；1366×768、2560×1440 等
不能作为 profile 的首选/原生分辨率。
默认先等概率抽品牌，再在该品牌内抽具体型号，避免型号较多的品牌天然占更高
概率。`--monitor-profile` 只能指定 28 款新建候选；其余样本用于兼容已有 VM。
只有 Samsung S24F350 与 Redmi RMMNT238NF 有已审核的型号专属序列格式；其他
33 款使用目录前缀加稳定哈希，不把通用值冒充成厂商标签格式。

池中只有 NVIDIA GTX 750 Ti、GT 1030、GTX 1050 三个目标型号，但包含 12 条
不可拆分的板卡/显存 profile，且每条都是 2048MB；普通
GTX 750 参考版标准显存是 1GB，因此严格 2GB 池使用 GTX 750 Ti。AMD 不能加入
这条池，因为底层是 NVIDIA GRID driver、NVIDIA mdev 和 NVAPI。
系统用户态板卡 metadata 覆盖 NVIDIA、ASUS、Dell、MSI、Gigabyte、GALAX、Colorful（七彩虹），
显存厂家为 Samsung、SK hynix、Micron，序列策略均为 `not-exposed`；B 模式系统
PCI device 仍是宿主 mdev；正式 merge 只投影 profile 的原子 Subsystem/静态字段。

`vms/N/vm.conf` 中的 `GPU_*` 是每 VM 的客户机身份，`VGPU_MDEV_PROFILE`
是 RTX 宿主的 `nvidia-257` fallback。实际资源可由宿主配置的
`VGPU_RESOURCE_PROFILE` 覆盖（例如 V100-2Q），但必须与当前 guest 身份同为
2048MB。

启动器默认在宿主机完成产品名同步：它复用持久化的 `VM_UUID` 作为 mdev UUID，
并在创建 mdev 前原子维护 `/etc/vgpu_unlock/profile_override.toml` 中对应的
`[mdev."UUID"]`，写入 `card_name`、`adapter_name` 和单头
`1920×1080/max_pixels=2073600` 显示合同。后者优先于旧宿主可能保留的全局
`4 heads/1920×1200` 值。因此不同 VM 即使共用
`nvidia-257`，NVIDIA 控制面板“系统信息”仍可得到各自的 `GPU_NAME`；guest 里
无需安装名称代理 DLL、服务或常驻程序。`SPOOF_MODE=off` 会移除该 VM 的名称项。

这个 host-only 覆写改变产品名称和 vGPU 显示能力上限，不会改物理 GPU、调度份额
或真实性能。板卡/显存静态字段由 VM-bound 系统 NVAPI 包从同一目录发布；普通
32/64 位查询程序自动继承，而 DXGI/D3D 继续使用原生 transport。旧
`sync-vgpu-profile.sh` 只用于历史模板兼容，不是新系统投影入口。

旧文档所说的“加入三个”不是挂三张卡。当前 audited 工具链只加入 GTX1050 的
`DEV_1C81/SUBSYS_11C01028`；GTX750Ti/GT1030 没有等价严格包，继续 B。不要运行旧
`guest/spoof-inf` 实验脚本；以 [`docs/DRIVER-INSTALL.md`](docs/DRIVER-INSTALL.md)
的锁定构建器与一键 ZIP 为准。

### 旧 relay 模式的自动 setup

下面的 setup-task 和 guest service 只在显式传入 `--legacy-shmem` / `--rdp`
时运行；它们不是默认直显的依赖。GNOME 快捷键 guard 支持所有本地 SDL/GTK
窗口（包括 `--install`）：仅在窗口聚焦且鼠标位于窗口内时临时把
`Ctrl+Alt+Del`、`Super`、`Alt+Tab` 交给 guest，失焦立即恢复。

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
./deploy/scripts/start-vm.sh 1                       # 新配置/脚本 fallback 均为 B
./deploy/scripts/start-vm.sh 1 --spoof-name-only     # B
./deploy/scripts/start-vm.sh 1 --no-spoof            # off
./deploy/scripts/start-vm.sh 1 --spoof-mode A         # legacy A：当前无生产签名 attestation，始终拒绝
```

| 方案 | PCI vendor/device/subsys | 名称来源 | driver 工作？ | 反虚拟化效果 |
|---|---|---|---|---|
| **A** | 外部 PCI + 可选 NVIDIA internal tuple | vm.conf 选定型号 | 当前无可用生产签名驱动，transition 已禁用 | 仅保留历史配置兼容 |
| **B** | 真 RTX 6000 (`DEV_1E30`) | host 按 mdev UUID 提供 vm.conf 选定型号 | 最稳；guest 无名称代理 | GPU-Z 等查 PCI ID 会暴露 |
| **off** | 真 RTX 6000 | 驱动/mdev 原生名称（全局 type 配置仍会影响它） | 最稳 | 完全不隐身（装 driver 阶段必用） |

原版 driver 安装阶段使用 `--no-spoof`。历史 GTX1050 ZIP 会修改 INF 并自签
catalog，现已在 `finish-vgpu-install.sh` 中硬禁用，不会切 A 或写完成 marker；
不要手工写只读配置。受支持的新实例保持 B；VM3 的 legacy A marker 已通过迁移
回执提交为 B/native，并已绑定 NVIDIA/Microsoft 正式生产签名驱动。尚未迁移的旧
A 实例仍会被默认启动门禁拒绝，只能按生产迁移流程处理。

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
./deploy/setup-guest.sh 1 --online-monitor-rescue --monitor dell-p2419h \
  --skip-vgpu --skip-license --skip-ivshmem --skip-service --skip-input
./deploy/setup-guest.sh 1 --skip-vgpu --skip-ivshmem      # 重跑只刷 service + spoof
```

单独传 `--monitor` 只选择救援型号，不会进入 guest；必须同时显式传
`--online-monitor-rescue` 才会临时下载并执行脚本，执行结束（含失败路径）会删除临时文件。
这条在线 fallback 只适用于已经配置旧 WinRM/relay 登录凭据的 guest；当前空密码新装
默认不能用它。它要求当前已有一张 `VEN_10DE` 且绑定 `nvlddmkm` 的显示设备，并与
离线封装一样只接受锁定的 GRID 538.33 `NV_Modes`；找不到设备、生产版本/
已发布 INF SHA-256 不符或遇到未知值都会停止，不会盲改 Class 注册表。
新旧 VM 的推荐傻瓜入口都是普通的 `./deploy/scripts/start-vm.sh N`：启动器缺省从
`vm.conf` 自动校验/同步显示器，不需要任何 guest 凭据。`vmctl monitor --force`
只用于关机态强制修复或切换型号。

> **注意**：默认直显只需要第 1、2 步对应的 NVIDIA GRID 驱动和授权；可以分别
> 用 `install-vgpu-driver.sh` / `install-vgpu-license.sh` 完成，不必安装第 3、4 步。

## 显示器型号与 Windows 分辨率

`config/monitor-profiles.tsv` 收录 35 个可回查的真实 EDID 样本；其中
`config/monitor-create-cn-fhd.txt` 严格列出 28 个新建 VM 候选。35 条完整目录与
28 条新建池都要求 preferred timing 为 FHD 1920×1080@60。每项包含真实 PNP
vendor/product ID、EDID 名称、物理尺寸、生产周/年、video-input、扫描范围和像素
时钟，不再用“只换品牌字符串”的合成 EDID。完整目录继续用于旧 VM 兼容，
不会因默认池收紧而让已有配置失效。

`create-vm.sh` 把 `MONITOR_BRAND_NAME`、`MONITOR_MODEL_NAME`、
`MONITOR_DISPLAY_NAME`、PNP、尺寸、扫描范围、生产日期和序列号整组写入
`vms/N/vm.conf`，同一 VM 重启不会重新随机。

NVIDIA R535 mdev 没有 `VFIO_GFX_EDID_REGION`，`start-vm.sh` 会在 QEMU
启动前按需离线刷新 Windows
SYSTEM hive 中已有的 raw EDID、模式缓存和 Microsoft 标准
`Device Parameters\EDID_OVERRIDE\0..N`（每个值一个 128-byte block）；这一步不向 guest 复制脚本、不安装服务、
不创建计划任务。同步器还会从 `Select\Current/Default/LastKnownGood` 沿固定
B/native `DEV_1E30&SUBSYS_132610DE` 的 `Driver` 关系精确约束 `NV_Modes`，不会
全扫孤立 ControlSet/Class key 或修改驱动文件。迁移后遗留的 A/consumer
`DEV_1C81&SUBSYS_11C01028` Enum 历史会跳过；它不能代替当前 native 设备通过门禁。
`Current` 必须同时命中 EDID 和经 Provider/版本/已发布 INF 哈希认证的 GRID
538.33 native 设备。普通启动已缺省执行这条同步链：

```bash
./deploy/scripts/start-vm.sh 1

# 仅旧缓存/手工重装驱动后的强制修复
./deploy/scripts/vmctl.sh monitor 1 --force

# 仅需要切换显示器型号时
./deploy/scripts/vmctl.sh monitor 1 --monitor-profile dell-p2419h --force
```

交互终端缺少 sudo 票据时会自动安全提示；密码不会写入仓库或参数。新建/克隆不传
显示器参数时由创建器自动选择 profile 并持久化，克隆器立即尝试同步。全新 base
尚无 `Enum\DISPLAY` 时，首次启动枚举、完整关机后的下一次普通启动自动补齐。

这里的 v8 marker 会绑定 EDID override helper 哈希。Windows 会优先消费
`EDID_OVERRIDE`，因此 WMI/鲁大师的厂商、型号、尺寸、16:9 和 1920×1080
都必须与 profile 一致。NVIDIA 的原始父 key 仍可以叫 `DISPLAY\\NVD0000`，但它不再是
有效 EDID 的验收结果。如果鲁大师仍显示 `NVIDIA VGX / 641×400 / 16:10`，
就应重跑 `vmctl monitor ... --force`，不再将它当作无法修复的 R535 局限。
`VgpuPortable.exe` 只处理 GPU 身份（GPU-Z 为显式选装消费者），不代替这条
显示器同步链。

日志中的 SYSTEM hive `logical_end` 按 REGF header `Length` 计算；其后直到
`physical` EOF 的旧 hbin/零填充是 Windows 允许的 slack，封装原样保留。只有
逻辑链内部断裂、越界、dirty sequence 或 checksum 错误才停止，不会“修头”、
截断 hive 或重放旧 LOG。

“关机”必须是禁用休眠/Fast Startup 后的完整关机。若同步器已经报告休眠，照抄：

```bash
sudo -v
./deploy/scripts/recover-hibernated-vm.sh N
```

封装打开本地标准 VGA，不挂 vGPU，不走 VNC/RDP/WinRM，也不安装 guest 包。登录
Windows 后，在管理员命令提示符或 PowerShell 逐行执行：

```bat
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
shutdown.exe /s /f /t 0
```

等待窗口自然退出。封装自动重试 `sync-monitor-profile.sh N --force`；失败时保持关闭并
返回非零，不强挂载、不删除 `hiberfil.sys`、不运行 `ntfsfix`，也不修改 BCD、签名或
驱动。默认 SDL，可用 `--rescue-gtk`；`--proxy` 只让成功后打印的普通启动命令保留
该参数，救援本身固定不用 proxy。

当前 GTX750Ti、GT1030、GTX1050 的 B/native VM 都使用私有 portable：

```bash
chmod 600 /home/ubuntu/images/staging/client_configuration_token.tok
./deploy/package-vgpu-one-click.sh --with-license-token
```

只有统一前 GTX750Ti/GT1030 需要旧 token 回执/UTC RTC 迁移，且 Windows 已经完整
关机后，才运行兼容入口：

```bash
./deploy/finish-vgpu-install.sh N
```

这些统一前 legacy profile 可生成/复用旧私有小包
`/home/ubuntu/images/staging/VgpuGuestFinish.exe`，用于 token、关闭休眠/Fast
Startup 与 RTC 收尾；宿主严格校验 UUID/GPU/token。同一 DLS 的受信任 VM 可复用
缓存产物，但宿主命令仍需逐 VM 运行。不使用 VNC、RDP、WinRM 或 guest HTTP。

NVIDIA vGPU 路径让 EDID 与受控 `NV_Modes` 使用同一份 10 项：1920×1080、
1600×900、1360×768、1280×1024/960/768/720、1024×768、800×600、
640×480；Windows“设置”通常隐藏 640×480，所以一般显示 9 项。它精确清除
1920×1200、1680×1050、1280×800、2560×1600 等 16:10，也删除上一版额外的
1600×1200、1600×1024、1440×1080、1366×768、1152×864，不会误删
1600×900；不能把 V-11 的 virtio 显示驱动规则原样套到 G-11。正常
`start-vm.sh N` 会自动按 marker 约束 NVIDIA source modes；只有要无条件清除旧
EDID/GraphicsDrivers 缓存时才执行 `./deploy/scripts/vmctl.sh monitor N --force`。受支持的 GRID 安装封装会在同版本重装前主动使
monitor marker 失效；手工 Device Manager 重装后则必须再显式使用 `--force`。
完整傻瓜步骤和 native SDL/GTK 验收见
[`docs/G11-MONITOR-POOL.md`](docs/G11-MONITOR-POOL.md)。

## 日常工作流

```bash
./deploy/scripts/start-vm.sh 1                    # 使用 vm.conf：当前支持路径统一为 B
# 或：./deploy/scripts/start-vm.sh 1 --gtk
# NumLock 默认由 guest USB LED 状态幂等保持开启；不要再写用户注册表。
# 仅本次确需关闭：./deploy/scripts/start-vm.sh 1 --no-numlock
# 产品名由 host per-mdev override 自动提供；新 clone 不需要 WinRM 同步
# ... 用 ...
# Ctrl+C / 关 QEMU 窗口 / 另一终端 ./deploy/scripts/stop-vm.sh 1
```

第一次装 GRID 驱动时应保留真实 vGPU PCI ID：

```bash
# 先用真实 PCI 身份安装匹配的 GRID driver
./deploy/scripts/start-vm.sh 1 --no-spoof --no-monitor-sync

# 正常 B 重启后，三款型号统一运行私有 VgpuPortable.exe：
./deploy/package-vgpu-one-click.sh --with-license-token
```

GTX1050 strict-A 会因旧路径修改 INF/自签 catalog 而提前拒绝，不再生成 ZIP；当前
三款都保持 B。私有 portable 含 token，不能由 staging HTTP server 下载、写入通用
base 或公开分发。
详见 [`docs/VGPU-LICENSING.md`](docs/VGPU-LICENSING.md)。

RTC 由宿主统一提供：QEMU 进程使用 `TZ=Asia/Shanghai` 和
`-rtc base=localtime,clock=host,driftfix=slew`。新装不写
`RealTimeIsUniversal`。只有统一前 GTX750Ti/GT1030 的旧 UTC legacy B VM/base 在
完整关机后才运行兼容 finish，由宿主备份 SYSTEM、离线删除旧 DWORD 并写入
`RTC_CONTRACT=localtime`。当前新 VM 不运行；休眠时先走
`recover-hibernated-vm.sh`。不要在 guest 内运行旧 `fix-rtc-utc.ps1`。

新 GTX1050、GTX750Ti、GT1030 都写 B + `name-only`，不再自动切
A/internal/FRL。完整生产签名边界见
[`docs/DRIVER-INSTALL.md`](docs/DRIVER-INSTALL.md)。

默认 native 路径没有 stream service 可停。只有使用旧 `--legacy-shmem` 时，
才用 `./deploy/service.sh 1 stop`、`start`、`status` 或 `restart` 控制 relay。

## 调试

| 现象 | 看哪 / 怎么 |
|---|---|
| OVMF/Windows 前期无画面 | 确认启动参数含 `vfio-pci-nohotplug,...,display=on,ramfb=on`，并使用仓库默认 OVMF |
| ramfb 有画面、进系统后黑屏 | guest 检查 NVIDIA GRID 驱动版本、设备 Error 43 和 license 状态 |
| 普通按键无响应 | 检查 QEMU 窗口焦点；键盘只依赖 input focus，不经过 guest relay |
| 小键盘开机仍为关 | 完整关机后增量运行 `./deploy/host/build-qemu.sh`，再普通启动；摘要应显示 guest LED NumLock。不要给已有运行进程热替换，也不要写 `InitialKeyboardIndicators`；详见 [`docs/G11-NUMLOCK-FIRST-BOOT.md`](docs/G11-NUMLOCK-FIRST-BOOT.md) |
| 刚进桌面右键很慢/不响应 | 先完成私有 portable 的 `Licensed` 验收并冷启动；再区分 Explorer/shell 扩展与全局画面延迟，按 [`docs/G11-NUMLOCK-FIRST-BOOT.md`](docs/G11-NUMLOCK-FIRST-BOOT.md) 收集 guest 进程和 host license/FRL 证据 |
| `Ctrl+Alt+Del`/`Super`/`Alt+Tab` 被宿主吃掉 | 确认启动时打印“GTK/SDL 宿主快捷键保护已启用”，鼠标在窗口内且窗口已聚焦，并确认没有传 `--no-tame-gnome` |
| 安装蓝屏 `USBXHCI.SYS` / `PAGE_FAULT_IN_NONPAGED_AREA` | 不删盘；按 [`docs/USBXHCI-INSTALL-RECOVERY.md`](docs/USBXHCI-INSTALL-RECOVERY.md) 增量重编并续装，确认启动摘要为固定上游 xHCI 行为身份 |
| 动态拖动稳定只有约 10 FPS | 检查启动日志是否有 `R535 console REGION 周期=16667us`；确认未将 `VGPU_CONSOLE_INTERVAL_US` 设为 0 |
| GTK 标题没有 FPS | 正常；`SDL Present` 只在 SDL 后端实现。用 host license/FRL 和实际 frame-time 判断 |
| 动态画面卡在 3/15 FPS | 当前 B/off 检查 DLS、Licensed、Code 0 和实际 vGPU profile；不要用历史 strict-A 的 `Unlicensed / FRL N/A` 作为当前验收 |
| 重启后先报无法获取 license，且一直不恢复 | 查 guest NVIDIA 日志是否反复出现 `Clock windback has been detected`；先用 `recover-hibernated-vm.sh` 排除休眠。只有统一前明确 UTC 的 GTX750Ti/GT1030 legacy B 才运行兼容 finish 迁移 RTC；当前新 VM 核对 localtime/时区/DLS |
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
| `./deploy/scripts/create-vm.sh <vm_id>` | 生成 `$VM_ROOT/N/vm.conf`（一次性） |
| `./deploy/scripts/create-disk.sh <vm_id> --from-base` | 严格克隆公共 base；不存在则失败，不退回空盘 |
| `./deploy/scripts/recover-hibernated-vm.sh <vm_id> [--rescue-gtk] [--proxy]` | host-only 本地标准 VGA 恢复休眠；完整关机后自动强刷 EDID/NV_Modes，失败闭锁 |
| `./deploy/finish-vgpu-install.sh <vm_id>` | 仅统一前 GTX750Ti/GT1030 的旧 token 回执/UTC 迁移；当前三款新 VM 不使用，GTX1050 strict-A 仍拒绝 |
| `./deploy/scripts/vmctl.sh monitor 1 [--monitor-profile PROFILE] [--force]` | 关机状态从 host 离线同步 EDID_OVERRIDE/raw EDID/NVIDIA 10 项模式策略；guest 无常驻组件 |
| `./deploy/scripts/host-nvme-apst.sh check` | 只读检查 Linux 宿主 NVMe APST；`persist/apply/rollback` 只在管理员显式执行时写入，见 [`docs/NVME-APST.md`](docs/NVME-APST.md) |
| `./deploy/sync-vgpu-profile.sh 1` | 可选：清理/同步旧 guest 的注册表身份；默认不安装 NVAPI shim |

## 常见坑

- **vGPU 显示 Error 43**：8/14/2024 之后的 GeForce DCH driver 在 vGPU passthrough 上拒绝工作。`./deploy/install-vgpu-driver.sh 1` 能完成 wipe + 重装当前基线 GRID 538.33（staging 仍沿用历史文件名 `553.24`）。
- **显示器同步报 `Windows is hibernated` / vGPU 恢复可能报 0x10E**：不要启动 vGPU，也不要用 host 强挂载、强删 `hiberfil.sys` 或运行 `ntfsfix`。任何型号都执行 `./deploy/scripts/recover-hibernated-vm.sh N`，在本地标准 VGA 窗口用管理员权限关闭 Fast Startup 并完整关机；封装会自动强制同步。详见 [`docs/VGPU-RECOVERY-RUNBOOK.md`](docs/VGPU-RECOVERY-RUNBOOK.md)。
- **重启后 NVIDIA 授权长时间不恢复**：若 guest 日志持续报告
  `Clock windback has been detected`，先按上一条取得完整关机；只有统一前、明确为
  UTC 的 GTX750Ti/GT1030 legacy B 才运行兼容 finish 由宿主离线迁移 RTC。当前新
  VM 不运行。不要写
  `RealTimeIsUniversal` 或运行旧 RTC guest 脚本。详见
  [`docs/VGPU-LICENSING.md`](docs/VGPU-LICENSING.md)。
- **vGPU mdev 分配失败** (`mdev_allocate failed`)：先运行 `sudo -v`；无人值守时只通过批准的安全渠道提供 `SUDO_PASSWORD`，不要写入仓库或命令历史。
- **磁盘满** (`/dev/nvme0n1p3 100%`)：guest qcow2 写阻塞 → boot 卡。检查 `vms/N/backups/` 和 `vms/shared/bases/archive/`；旧 G-11 尚未迁移时再只读检查 `vms/G-11/` 与 `vms/instances/`。
- **ivshmem 已被占** (relay 反复 `REQUEST_MMAP failed: 548`)：旧 relay 孤儿没退。NvDisplayContainer 启动会自动 kill 同名孤儿；手动可 `./deploy/service.sh 1 restart`。
