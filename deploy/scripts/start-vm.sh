#!/bin/bash
# shellcheck disable=SC1091
# 所有启动模块都按运行时计算出的绝对 HERE 路径加载，静态分析器无法解析该路径。
# ---------------------------------------------------------------------------
# start-vm.sh ——— 基于版本化硬件清单启动 QEMU/KVM 客机
#
# 新 VM 默认只从 platforms.json 中 enabled 的完整 CPU/主板/PCH bundle 选型；
# 显式允许 compatibility 时仍先选 supported，无匹配才按宿主能力回退受审计模板。
# 随后绑定 components.json 中核验过的 SSD、EDID 与 HID 模板。生产默认会检查
# KVM/TSC 真能力并实际 realize 目标 vCPU；任一跨字段矛盾都会 fail closed。
# GPU 仍是 virtio 显示路径，本分支不做显卡直通/vGPU，也不承诺等价于真实独显。
#
# 2026-07-22 DGame 区域定位修复：真实启动会把 QEMU 进程级 Yama 例外自动放在最终
# QEMU 叶节点，再由显示守护包到 GNOME/systemd inhibit 外层。不得把 wrapper
# 套在 start-vm.sh 或 inhibit 外面；已运行的旧 QEMU 需重启一次。完整记录见
# deploy/docs/DGAME_QEMU_MEMORY_AUTH.md。该机制逐实例生效，不依赖 libvmi 或全局
# kernel.yama.ptrace_scope=0。
#
# 用法（最简）：
#     ./start-vm.sh 1                       # 启动 instance 1，桥接 br0
#                                           # 默认 SDL 窗口 + fb-shm 推流并存
#                                           # 推流 socket: /tmp/qemu-stealth-1.fb
#     ./start-vm.sh 2 --iso=/path/x.iso     # instance 2 从 ISO 装系统
#     ./start-vm.sh 2 --platform-id=<id>     # 显式固定一个已启用整机 bundle
#     ./start-vm.sh 2 --memory-id=<module-id> --storage-id=<component-id> \
#         --gpu-id=<component-id> --monitor-id=<component-id>
#                                           # 首次 profile 固定过滤后的合法部件；
#                                           # 空值保持原权重随机，已有 profile 仅断言
#     ./start-vm.sh 2 --allow-platform-compatibility
#                                           # 自动匹配宿主并接受 Q35 行为边界；
#                                           # KVM/TSC/CPU/TPM 等严格门禁仍会执行
#     ./start-vm.sh 2 --platform-id=<id> --allow-platform-compatibility
#                                           # 高级用法：固定/断言具体兼容平台
#     STRICT_HARDWARE=0 ./start-vm.sh 1 --allow-legacy-profile
#                                           # 仅显式诊断无 manifest 绑定的旧 profile
#     ./start-vm.sh 1 --migrate-storage-profile
#                                           # 显式允许旧 schema-1 启动盘字段内存迁移
#     ./start-vm.sh 1 --no-sdl              # 后台 daemon：关 SDL，仅推流
#     ./start-vm.sh 1 --gpu-sdl-egl         # SDL/GL-safe：无 hostmem BAR，GL feature 可见
#     ./start-vm.sh 1 --gpu-headless        # EGL rendernode + fb-shm，默认仍为 GL-safe
#     ./start-vm.sh 1 --gpu-sdl-egl --gpu-zerocopy
#                                           # 显式启用 blob/hostmem，重排 PCI BAR
#     ./start-vm.sh 1 --no-gpu-zerocopy     # GL-safe 兼容开关（当前也是默认值）
#     ./start-vm.sh 1 --headless            # VNC 远程 + fb-shm（无本地窗口）
#     ./start-vm.sh 1 --no-fb-shm           # 关推流，仅 SDL（回历史行为）
#     ./start-vm.sh 1 --no-bridge           # 用 user-mode NAT 而不是 br0
#     ./start-vm.sh 1 --vlan-id=11          # 在单一 br0 上动态接入 access VLAN 11
#                                          # 不传 VLAN 参数时完全保持原有 br0 默认网络
#     ./start-vm.sh 1 --reroll              # 原子重抽身份；已有 TPM state 时拒绝
#     ./start-vm.sh 1 --fb-shm-roi=0,0,1920,1080 --fb-shm-rate=60
#     ./start-vm.sh 1 --proxy               # 启用 QEMU 原生 QMP multi-client
#                                           # 兼容别名: /tmp/qemu-stealth-1.qmp.proxy
#     ./start-vm.sh 1 --no-host-tune        # 跳过起前的 host 调优(默认会自动跑)
#     ./start-vm.sh 1 --no-cpu-isolate      # 不给 vCPU 划专属核(默认会绑核隔离)
#
# 边玩边拉流到 ffmpeg / NVENC：
#     ./start-vm.sh 1                       # SDL 窗口照常出现，可直接玩
#     qemu-fb-shm-stream --sock /tmp/qemu-stealth-1.fb \\
#         --output 'rtmp://ingest/live/vm1' --encoder h264_nvenc --bitrate 6M --mode auto
#
# 默认值（90% 情况都不用改）：
#     BRIDGE=br0           桥接 br0（不存在自动回退到 user-mode NAT）
#     STABLE_DISPLAY=1     SDL 默认 virtio-vga，不启用宿主 virgl/blob/hostmem；
#                          优先保证 Windows 游戏长时间运行稳定。VioGpuDod 在两条
#                          路径都只是 Display-Only，都不会提供客体 Direct3D 加速
#     STRICT_HARDWARE=1    KVM/TSC 能力、完整平台与 CPU realize 默认严格门禁
#
# 平台 bundle 与每机唯一身份只在首次启动时选择/生成一次，写到
#     /home/ubuntu/images/vms/<N>/profile
# 之后所有启动复用，避免 Windows 激活与客体硬件枚举在重启间漂移。
# 想换身份应先完整备份实例；TPM state 已与平台绑定，随机到不同平台时会拒绝复用
# 旧密钥，建议新建 instance 或按明确的密钥迁移流程处理，不能只删除 profile。
#
# 显示后端 — 两条独立通道，默认全开：
#     SDL 窗口（默认开）   本地交互窗口；DNF 等需要直接玩游戏的场景用。
#                          --no-sdl 关；--headless 自动关并启 VNC 替代。
#     fb-shm 推流（默认开）共享内存推流 + 可选 GPU frame metadata，guest 完全不可见。
#                          外部进程连 unix socket 拿 memfd/eventfd；GL/dma-buf
#                          路径还能订阅 NOTIFY_GPU_FRAME 做零拷贝 GPU handoff。
#                          qemu-fb-shm-stream → ffmpeg/NVENC 推 RTMP / UDP / SRT /
#                          本地 mp4。--no-fb-shm 关。
#     --headless           关 SDL，开 VNC（fb-shm 仍照常）。
#     --gpu-sdl-egl        保留 SDL 本地窗口的兼容模式名；实际仍使用 QEMU 11
#                          官方 `-display sdl,gl=on`，由 SDL 后端自行探测 EGL。
#                          默认不添加 blob/hostmem；renderer 若能从普通 texture
#                          导出，fb-shm 仍可发布 GPU dma-buf。
#     --gpu-headless       关 SDL，使用 egl-headless/rendernode 保留 virtio-gpu GL，
#                          默认同样不添加 blob/hostmem。
#
# 环境变量（不常用，默认就好）：
#     RAM=8192             客机内存 MiB（默认取 profile，当前 bundle 为 8192）
#     CPUS=4               必须等于所选 SKU 完整线程数（当前候选为 2 或 4）
#     TPM=auto             跟随 profile 的主板 TPM 能力/版本/前端；1=强制要求，
#                          0=显式关闭。平台事实仍固定在 profile，不会独立随机。
#     SDL=1                SDL 窗口开关（默认 1） (flag: --sdl / --no-sdl)
#     HEADLESS=1           关 SDL 启 VNC                          (flag: --headless)
#     BRIDGE=br0           桥接网卡名字                          (flag: --bridge=br0)
#     VLAN_ID=11           access VLAN ID，合法范围 1..4094      (flag: --vlan-id=11)
#                          首次会检测单 br0/helper；缺配置且有本地 TTY 时，显示
#                          自动识别的 UPLINK，输入 `SETUP <网卡>` 后 sudo 初始化一次。
#                          无 TTY/取消/无法唯一识别时 fail closed，并提示手动命令；
#                          SSH 默认不自动执行（显式 VLAN_SETUP_ALLOW_SSH=1 才询问）。
#                          成功后任意 VID 动态创建 TAP，无需新 bridge 或再次初始化。
#                          交换机 native LAN untagged、业务 VLAN tagged；Windows/Linux
#                          guest 收无标签帧；不传 VLAN 时原行为完全不变。
#     ISO=<path>           安装 ISO 路径                         (flag: --iso=<path>)
#     DISK=<path>          qcow2 磁盘路径                        (flag: --disk=<path>)
#     QEMU=<path>          qemu-system-x86_64 二进制路径         (flag: --qemu=<path>)
#                          实际启动会自动在最终 QEMU 叶节点设置进程级 Yama 例外；
#                          多 VM 无需额外操作，也不会修改全局 ptrace_scope。
#     DGAME_QEMU_PTRACER=  可选的 dgame_qemu_ptracer 路径；默认自动寻找包内/PATH
#                          wrapper，再用内置 Python wrapper；util-linux 2.41+
#                          setpriv 仅为末级回退。正常使用无需手动设置。
#     EXTRA_ISO=<path>     副 CDROM（autounattend.xml / 驱动盘 等）
#     STABLE_DISPLAY=1     默认稳定路径；设 0 才显式启用 virtio-vga-gl。
#                          --gpu-sdl-egl/--gpu-headless 在未显式设置本变量时会自动
#                          opt-in GL；显式 STABLE_DISPLAY=1 仍保持稳定模式优先。
#     STRICT_HARDWARE=1    设 0 仅供诊断/兼容 dry-run，不计入真机化支持
#     STEALTH_PLATFORM_ID= 显式平台 ID（flag: --platform-id=<id>）；已有
#                          profile 上只做一致性断言；可选，换平台须另加 --reroll
#     STEALTH_MEMORY_ID=   memory.json module ID（flag: --memory-id=<id>）
#     STEALTH_STORAGE_ID=  components.json 存储 ID（flag: --storage-id=<id>）；
#                          当前合法候选精确限定为 512110190592 bytes
#     STEALTH_GPU_ID=      components.json GPU 稳定 ID（flag: --gpu-id=<id>）
#     STEALTH_MONITOR_ID=  components.json 显示器 ID（flag: --monitor-id=<id>）
#                          四项为空时权重随机；非空须在当前平台合法候选中唯一命中
#     ALLOW_PLATFORM_COMPATIBILITY=0
#                          设 1 或使用同名 flag 后，按厂商、线程、频率、TSC 自动
#                          匹配；优先 supported，无匹配才回退 compatibility。
#                          不会关闭 KVM/CPU/TPM/profile/磁盘等其它严格门禁
#     ALLOW_LEGACY_PROFILE=0
#                          旧 schema 即使 STRICT_HARDWARE=0 也默认拒绝；设 1 或
#                          --allow-legacy-profile 才做不计入支持范围的显式诊断加载
#     ALLOW_STORAGE_PROFILE_MIGRATION=0
#                          设 1 或使用 --migrate-storage-profile，才允许已知旧
#                          schema-1 profile 在内存补齐启动盘字段；不会改写 profile
#     FB_SHM_SOCK=<path>   fb-shm 控制 socket 路径
#                          默认 /tmp/qemu-stealth-<N>.fb
#                          (flag: --fb-shm-sock=<path>)
#     FB_SHM_RATE=60       fb-shm 目标帧率 Hz，clamp [1,240]
#                          (flag: --fb-shm-rate=<hz>)
#     FB_SHM_ROI=x,y,w,h   只截 ROI 推流（省 CPU/带宽）。空 = 全屏
#                          (flag: --fb-shm-roi=x,y,w,h)
#     GPU_ZEROCOPY=0       所有路径默认 0；只有显式设 1 或 --gpu-zerocopy 才给
#                          virtio-vga-gl 添加 blob/hostmem。该操作改变 guest 可见
#                          PCI BAR 布局，且只允许与显式 GL、fb-shm 组合；导出失败仍
#                          回退 SHM。--no-gpu-zerocopy 是保留的兼容关闭开关。
#     GPU_HOSTMEM=256M     显式 zero-copy 的 host-visible PCI BAR 大小；必须为
#                          256M..8G 内 2 的幂，并与 GPU_ZEROCOPY=1 同时使用。
#                          (flag: --gpu-hostmem=SIZE)
#     GPU_DISPLAY=sdl      GPU 显示模式；sdl=默认普通 SDL 稳定路径，
#                          sdl-egl=显式生成 `-display sdl,gl=on`，由 QEMU 11
#                          探测 EGL，默认保持 gl-safe（不带 blob/hostmem），
#                          egl-headless=无窗口 EGL。
#                          (flag: --gpu-display=sdl|sdl-egl|egl-headless /
#                          --gpu-sdl-egl / --gpu-headless)
#     GPU_RENDERNODE=      egl-headless render node 路径；空值让 QEMU 自动选择。
#                          常用 /dev/dri/renderD128 (flag: --gpu-rendernode=PATH)
#     PROXY=1              启用 QEMU 原生 QMP multi-client（默认 0）
#                          (flag: --proxy / --no-proxy)
#                          ${QMP_SOCK} 可多客户端并发；同时创建
#                          ${QMP_SOCK}.proxy 兼容旧工具配置
#     HOST_TUNE=1          起 VM 前自动跑 host-performance.sh 压计时抖动（默认 1）
#                          (flag: --host-tune / --no-host-tune)
#                          governor=performance + KVM_HALT_POLL_NS(默认 0) + THP
#                          defrag=never + split-lock 限速策略。防编译抢 vCPU 主要靠
#                          CPU_ISOLATE/cpuset；
#                          需要旧低延迟 busy-poll 可显式 KVM_HALT_POLL_NS=500000。
#     SPLIT_LOCK_MITIGATE=0
#                          默认取消内核对 split-lock 触发者的故意降速；
#                          多租户宿主如需保留 DoS 防护可设 1。需 HOST_TUNE=1。
#     GUEST_NUMLOCK=1      QEMU 从 usb-kbd 的 guest LED 回报确认状态；每次明确
#                          OFF 只送一个原子 click 并等待 ON，连续 OFF 不重复送键。
#                          默认持续强制 ON；不修改 Windows 注册表或 host XKB。
#                          (flag: --numlock / --no-numlock)
#     CPU_FREQ_CAP=0       默认不改宿主全局频率；设 1 才按本实例 CPU 上限封顶
#                          (CPU_MAX_MHZ=SMBIOS Type4 max-speed，需 HOST_TUNE=1）
#                          (flag: --freq-cap / --no-freq-cap)
#                          防 guest 实测吞吐超出该型号规格(超规格=变速器/计时异常 tell)。
#                          只降不升：多 VM 并发收敛到运行中最小，绝不让任一 VM 超自身规格。
#     CPU_ISOLATE=1        严格模式先 -S 暂停来宾，再把 QEMU 钉进 cpuset（默认 1）
#                          (flag: --cpu-isolate / --no-cpu-isolate)
#                          exact 严格为 2C2T=2T、2C4T=4T、4C4T=4T；不额外圈 sibling。
#                          每个 vCPU 对应唯一 host logical CPU；完成后才执行 QMP cont。
#                          Guest 的 -smp/CPUID/SMBIOS 身份不变，默认至少为宿主留 2 核。
#                          频率封顶只管「跑多快」，这个管「vCPU 抢不抢得到核」——
#                          宿主机满载(cargo/rust 编译塞满全核)时治 VM 卡顿/掉帧/ACE 计时
#                          异常的真正旋钮：vCPU 独占自己的线程、永不被宿主机抢占。多 VM
#                          父分区保存资源并集，每台 VM 进入 exact CPU/NUMA child；并发
#                          自动错开逻辑 CPU，停机时按实例精确归还。
#                          纯运行态(cgroup v2 partition，不重启)；需 host-cpu-isolate.sh
#                          的 sudo NOPASSWD(同 host-tune)。
#     HOST_RESERVE_CORES=auto 按完整 SMT2 核池给宿主机预留物理核；仅本次容量不足时缩小，
#                          每台 VM 分配 2/4/4 条逻辑 CPU；显式 N 仍表示硬预留物理核。
#                          不按已运行 VM 数量改变边界；设 0 时 helper 仍至少留 2 核。
#     QEMU_SERVICE_CPUS=0  给 QEMU 辅助线程额外预留逻辑 CPU 数（默认 0，保持旧行为）。
#                          启用后 root helper 会把 main/IO/SDL/fb-shm worker 等非 vCPU 线程
#                          收窄到这组 CPU，避免它们和满载 vCPU 抢同一条调度队列。
#                          短 flag: --svc-cpu(=1) / --svc-cpus=N / --no-svc-cpus；
#                          长兼容: --qemu-service-cpu / --qemu-service-cpus=N。
#                          短环境变量: QEMU_SVC_CPUS=1。
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# 后续动态 source 的 sv-*.sh 片段会消费 REPO_ROOT；ShellCheck 无法跨这种
# 运行时 source 边界建立变量引用关系，因此仅抑制这一处误报。
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/stealth-lib.sh"
source "$HERE/lib/vlan-network.sh"
source "$HERE/lib/sv-vlan-preflight.sh"
source "$HERE/lib/sv-instance-watchdog.sh"
source "$HERE/lib/sv-instance-lock.sh"

_usage() {
    # 跳过 shebang/shellcheck 和首个分隔线，从真正的启动器说明打印到尾部分隔线。
    sed -n '5,/^# --*$/p' "$0" | sed -e 's/^# *//' -e 's/^#$//' >&2
    exit "${1:-2}"
}

# ------------------------------------------------------------------
# 重构 P1#5：主体按职责拆入 lib/sv-*.sh，按原执行顺序 source（同一 shell、
# 共享 $@ 与全局变量，与单文件版逐字节等价；DRY_RUN argv harness 校验）。
# ------------------------------------------------------------------
source "$HERE/lib/sv-cli.sh"        # CLI 解析 + 默认值 + 目录 / RANDOM 种子
source "$HERE/lib/sv-qemu-ptracer.sh" # 每实例自动授权最终 QEMU 叶进程供 DGame 毫秒级读内存
# 非 DRY_RUN 在任何 profile/磁盘/TPM/host tune 副作用前验证 Yama 与 wrapper。
sv_qemu_ptracer_preflight || exit 1
source "$HERE/lib/sv-host-helpers.sh" # 拒绝工作区 sudoers，仅信任 root-owned helper
source "$HERE/lib/sv-portability.sh" # 迁移 host 预检：路径/QEMU 能力，不做隐身降级
source "$HERE/lib/sv-cpupin.sh"     # 在其它宿主预检后校验 helper；稍后异步等待 vCPU
source "$HERE/lib/sv-host-capabilities.sh" # KVM/TSC 真能力；供 profile 做硬约束
source "$HERE/lib/base-image.sh"   # root-owned base/backing 的运行期快速完整性门禁
source "$HERE/lib/sv-disk.sh"      # qcow2 创建 + guest 可见容量与组件清单严格核对
source "$HERE/lib/sv-identity.sh"   # 启动源 + 硬件身份 profile + OVMF + ACPI 表
source "$HERE/lib/sv-hosttune.sh"   # (可选,默认开) host 压抖动 + 按伪装 CPU 封顶频率
                                    #   ↑ 必须在 identity 之后: 频率封顶要用 CPU_MAX_MHZ
source "$HERE/lib/sv-tpm-mem.sh"    # TPM(swtpm) + DIMM 拓扑 / 内存 / SMBIOS / AMD DF
source "$HERE/lib/sv-devices.sh"    # 平台 PCI ID + 显示/EDID + 启动序 + CDROM + 网络 + USB + 音频
source "$HERE/lib/sv-dock.sh"       # GNOME dash-to-dock 集成：每实例独立可固定/可排序图标(SDL 窗口)
source "$HERE/lib/sv-display-guard.sh" # SDL 生命周期：inhibit + 退出时可靠恢复宿主 DPMS/屏保
source "$HERE/lib/sv-assemble.sh"   # 组装 argv + DRY_RUN + 守护进程 + 显示生命周期启动
