# shellcheck shell=bash
# 本文件由 start-vm.sh source；这里赋值的 RAM/VLAN/profile 等变量在后续模块使用。
# shellcheck disable=SC2034
# ---------------------- CLI parsing ----------------------
# 历史 GPU_SELFSIGNED 会把 virtio-gpu 的物理主 ID 改成 10DE/1002，并要求已删除的
# 自签驱动链。必须在解析任何实例目录、检查 helper 或执行 host 调优之前拒绝它，
# 防止旧 systemd unit 虽然最终启动失败，却先修改 governor/halt_poll 等宿主状态。
if [[ "${GPU_SELFSIGNED:-0}" != "0" ]]; then
    echo "ERROR: GPU_SELFSIGNED 深层/自签路径已移除；请保持物理 PCI 1AF4:1050" >&2
    exit 2
fi

# First positional arg = INSTANCE. Everything else is --flag=value or --flag.
_cli_instance=""
_cli_iso=""
_cli_reroll=0
_cli_bridge_seen=0
_cli_vlan_id_seen=0
_cli_platform_id_seen=0
# 中文注释：默认改为稳定显示后，显式选择 GL 后端仍必须保持原有语义。
# 这里在 CLI 覆盖前记住环境变量是否存在；解析具体 GPU flag 时也会置位，
# 从而区分“用户明确要 GL”和“GPU_DISPLAY=sdl 的普通默认值”。
_stable_display_explicit=0
_gpu_display_explicit=0
_gpu_hostmem_explicit=0
[[ -n "${STABLE_DISPLAY+x}" ]] && _stable_display_explicit=1
[[ -n "${GPU_DISPLAY+x}" ]] && _gpu_display_explicit=1
[[ -n "${GPU_HOSTMEM+x}" ]] && _gpu_hostmem_explicit=1
while (( $# > 0 )); do
    case "$1" in
        -h|--help) _usage 0 ;;
        --iso=*)      _cli_iso="${1#*=}" ;;
        --disk=*)     DISK="${1#*=}" ;;
        --bridge=*)   BRIDGE="${1#*=}"; _cli_bridge_seen=1 ;;
        --no-bridge)  NO_BRIDGE=1 ;;
        --vlan-id=*)  VLAN_ID="${1#*=}"; _cli_vlan_id_seen=1 ;;
        --qemu=*)     QEMU="${1#*=}" ;;
        --ram=*)      RAM="${1#*=}" ;;
        --cpus=*)     CPUS="${1#*=}" ;;
        --platform-id=*)
            STEALTH_PLATFORM_ID="${1#*=}"
            _cli_platform_id_seen=1
            ;;
        --memory-id=*)  STEALTH_MEMORY_ID="${1#*=}" ;;
        --storage-id=*) STEALTH_STORAGE_ID="${1#*=}" ;;
        --gpu-id=*)     STEALTH_GPU_ID="${1#*=}" ;;
        --monitor-id=*) STEALTH_MONITOR_ID="${1#*=}" ;;
        --allow-platform-compatibility) ALLOW_PLATFORM_COMPATIBILITY=1 ;;
        --allow-legacy-profile) ALLOW_LEGACY_PROFILE=1 ;;
        --migrate-storage-profile) ALLOW_STORAGE_PROFILE_MIGRATION=1 ;;
        --headless)   HEADLESS=1 ;;
        --reroll)     _cli_reroll=1 ;;
        --sdl)        SDL=1 ;;
        --no-sdl)        SDL=0 ;;
        --no-fb-shm)     FB_SHM=0 ;;
        --fb-shm)        FB_SHM=1 ;;  # explicit on (already default)
        --fb-shm-sock=*) FB_SHM=1; FB_SHM_SOCK="${1#*=}" ;;
        --fb-shm-rate=*) FB_SHM=1; FB_SHM_RATE="${1#*=}" ;;
        --fb-shm-roi=*)  FB_SHM=1; FB_SHM_ROI="${1#*=}" ;;
        --gpu-zerocopy)     GPU_ZEROCOPY=1 ;;
        --no-gpu-zerocopy)  GPU_ZEROCOPY=0 ;;
        --gpu-hostmem=*)    GPU_HOSTMEM="${1#*=}"; _gpu_hostmem_explicit=1 ;;
        --gpu-headless)     GPU_DISPLAY=egl-headless; SDL=0; _gpu_display_explicit=1 ;;
        --gpu-sdl-egl)      GPU_DISPLAY=sdl-egl; SDL=1; _gpu_display_explicit=1 ;;
        --gpu-display=*)    GPU_DISPLAY="${1#*=}"; _gpu_display_explicit=1 ;;
        --gpu-rendernode=*) GPU_RENDERNODE="${1#*=}" ;;
        --proxy)         PROXY=1 ;;
        --no-proxy)      PROXY=0 ;;
        --host-tune)     HOST_TUNE=1 ;;
        --no-host-tune)  HOST_TUNE=0 ;;
        --numlock)      GUEST_NUMLOCK=1 ;;
        --no-numlock)   GUEST_NUMLOCK=0 ;;
        --freq-cap)      CPU_FREQ_CAP=1 ;;
        --no-freq-cap)   CPU_FREQ_CAP=0 ;;
        --cpu-isolate)    CPU_ISOLATE=1 ;;
        --no-cpu-isolate) CPU_ISOLATE=0 ;;
        --svc-cpu|--qemu-service-cpu)      QEMU_SERVICE_CPUS=1 ;;
        --svc-cpus=*|--qemu-service-cpus=*) QEMU_SERVICE_CPUS="${1#*=}" ;;
        --no-svc-cpu|--no-svc-cpus|--no-qemu-service-cpu|--no-qemu-service-cpus) QEMU_SERVICE_CPUS=0 ;;
        --)           shift; break ;;
        -*)
            echo "ERROR: unknown flag '$1'" >&2
            _usage ;;
        *)
            if [[ -z "$_cli_instance" ]]; then
                _cli_instance="$1"
            else
                echo "ERROR: unexpected positional argument '$1'" >&2
                _usage
            fi ;;
    esac
    shift
done

# ---------------- defaults ----------------
# INSTANCE 来源优先级:
#   1. 命令行位置参数  ./start-vm.sh 2
#   2. 环境变量 INSTANCE=2 ./start-vm.sh
#   3. 默认 1
# 如果同时给了位置参数和环境变量但不一致，警告并用位置参数（命令行更显式）。
if [[ -n "$_cli_instance" ]]; then
    if [[ -n "${INSTANCE:-}" && "$INSTANCE" != "$_cli_instance" ]]; then
        echo ">> WARN: INSTANCE env=$INSTANCE 与位置参数 $_cli_instance 不一致，用位置参数" >&2
    fi
    INSTANCE="$_cli_instance"
fi
: "${INSTANCE:=1}"
if ! [[ "$INSTANCE" =~ ^[1-9][0-9]{0,9}$ ]]; then
    echo "ERROR: INSTANCE 必须是 1–10 位正整数且不能有前导零 (实际: '$INSTANCE')" >&2
    exit 2
fi

# `--allow-platform-compatibility` 允许选择 status=compatibility 的受审计平台；
# 未给 `--platform-id` 时按宿主约束自动选择，给出 ID 时则固定/断言具体平台。
# 它只放宽 machine fidelity，不会把 STRICT_HARDWARE 改成 0，因此 KVM、TSC、
# CPU realize、所请求 TPM、profile 和磁盘容量门禁仍会全部执行。
: "${STEALTH_PLATFORM_ID:=}"
: "${ALLOW_PLATFORM_COMPATIBILITY:=0}"
: "${ALLOW_LEGACY_PROFILE:=0}"
: "${ALLOW_STORAGE_PROFILE_MIGRATION:=0}"
stealth_component_selection_init_requests
if [[ "$_cli_platform_id_seen" == "1" && -z "$STEALTH_PLATFORM_ID" ]]; then
    echo "ERROR: --platform-id 不能为空" >&2
    exit 2
fi
if [[ -n "$STEALTH_PLATFORM_ID" ]] &&
   ! [[ "$STEALTH_PLATFORM_ID" =~ ^[a-z0-9][a-z0-9-]{7,95}$ ]]; then
    echo "ERROR: --platform-id 格式非法: '$STEALTH_PLATFORM_ID'" >&2
    exit 2
fi
if [[ -n "$STEALTH_PLATFORM_ID" ]] &&
   ! stealth_platform_id_known "$STEALTH_PLATFORM_ID"; then
    echo "ERROR: --platform-id 指向不存在的平台: '$STEALTH_PLATFORM_ID'" >&2
    exit 2
fi
case "$ALLOW_PLATFORM_COMPATIBILITY" in
    0|1) ;;
    *)
        echo "ERROR: ALLOW_PLATFORM_COMPATIBILITY 必须是 0 或 1" >&2
        exit 2
        ;;
esac
case "$ALLOW_LEGACY_PROFILE" in
    0|1) ;;
    *)
        echo "ERROR: ALLOW_LEGACY_PROFILE 必须是 0 或 1" >&2
        exit 2
        ;;
esac
case "$ALLOW_STORAGE_PROFILE_MIGRATION" in
    0|1) ;;
    *)
        echo "ERROR: ALLOW_STORAGE_PROFILE_MIGRATION 必须是 0 或 1" >&2
        exit 2
        ;;
esac
if [[ "$ALLOW_LEGACY_PROFILE" == "1" && "${STRICT_HARDWARE:-1}" != "0" ]]; then
    echo "ERROR: --allow-legacy-profile 仅能与显式 STRICT_HARDWARE=0 诊断模式同时使用" >&2
    exit 2
fi
export STEALTH_PLATFORM_ID ALLOW_PLATFORM_COMPATIBILITY ALLOW_LEGACY_PROFILE
export ALLOW_STORAGE_PROFILE_MIGRATION

# VLAN 是运行时网络选择，不写入硬件身份 profile。CLI 值会覆盖同名环境变量，
# 但显式空参数必须报错，避免 `--vlan-id=` 被误当成“未启用 VLAN”后接入普通 LAN。
: "${VLAN_ID:=}"
if [[ "$_cli_vlan_id_seen" == "1" && -z "$VLAN_ID" ]]; then
    echo "ERROR: --vlan-id 不能为空；合法范围为 1..4094" >&2
    exit 2
fi
if [[ -n "$VLAN_ID" ]]; then
    _vlan_id_raw="$VLAN_ID"
    if ! _vlan_id_normalized="$(vlan_validate_id "$VLAN_ID")"; then
        echo "ERROR: VLAN_ID 必须是 [1,4094] 的整数 (实际: '$_vlan_id_raw')" >&2
        exit 2
    fi
    VLAN_ID="$_vlan_id_normalized"
    if [[ "${NO_BRIDGE:-0}" == "1" ]]; then
        echo "ERROR: --vlan-id 依赖宿主 bridge，不能和 --no-bridge 同时使用" >&2
        exit 2
    fi
    if [[ "$_cli_bridge_seen" == "1" && "${BRIDGE:-}" != "br0" ]]; then
        echo "ERROR: --vlan-id 只支持单一 br0；可省略 --bridge 或显式写 --bridge=br0" >&2
        exit 2
    fi
fi
if [[ -n "$VLAN_ID" ]]; then
    # 显式 VLAN 固定复用唯一的 VLAN-aware br0。QEMU bridge backend 本身没有
    # IEEE 802.1Q 参数，后续会切到预创建的 persistent TAP；这里禁止环境变量
    # 偷换其它 bridge，避免把 access TAP 接进错误广播域。
    BRIDGE="${BRIDGE:-br0}"
    if [[ "$BRIDGE" != "br0" ]]; then
        echo "ERROR: VLAN 模式固定使用 br0（实际 BRIDGE='$BRIDGE'）" >&2
        exit 2
    fi
    if ! VLAN_TAP_IF="$(vlan_tap_name "$INSTANCE")"; then
        echo "ERROR: VLAN 模式实例号必须为 1..10 位正整数，才能生成安全 TAP 名" >&2
        exit 2
    fi

fi

# 所有网络模式共用实例生命周期锁。stop-vm 会在清 socket/TPM/TAP 前取得同一
# 把锁，因此旧 VM 的迟到收尾不会误删同实例新 VM 的资源。DRY_RUN 仍严格不创建
# 锁文件；正常启动稍后把 fd 交给异步 guard，由 guard 跨整个 inhibit/QEMU
# 或显示守护父 shell 生命周期持有。
if [[ "${DRY_RUN:-0}" != "1" ]]; then
    command -v flock >/dev/null 2>&1 || {
        echo "ERROR: 启动 VM 需要 util-linux 的 flock" >&2
        exit 1
    }
    if ! SV_INSTANCE_LOCK="$(sv_instance_lock_path "$INSTANCE")"; then
        echo "ERROR: 无法创建当前用户的私有实例锁目录" >&2
        exit 1
    fi
    exec 8>"$SV_INSTANCE_LOCK"
    if ! flock -n 8; then
        echo "ERROR: 实例 $INSTANCE 已在启动或运行" >&2
        exit 1
    fi
    SV_INSTANCE_LOCKED=1
fi

# VLAN 宿主预检仍早于 VM_DIR/profile/TPM；先持有实例锁可确保同实例第二个
# 启动器不会在第一个启动器的 prepare 前并发通过这段检查。
if [[ -n "$VLAN_ID" ]] && ! sv_vlan_preflight; then
    exit 1
fi

# RAM 默认值故意不在这里钉死：profile.MEM_TOTAL_MB 可能提供持久化值，
# 所以推迟到 profile 加载之后再解析（见下方 "RAM 解析" 块）。
# 显式 --ram= / 环境 RAM= 在 CLI 解析阶段已赋值，会被那里当最高优先级保留。
: "${CPUS:=4}"
: "${HEADLESS:=0}"
: "${SDL:=1}"      # 默认：SDL 窗口仍然弹出（与历史行为一致）
: "${FB_SHM:=1}"   # 默认：再额外挂一条 -object fb-shm 推流通道
: "${STABLE_DISPLAY:=1}"
: "${FB_SHM_RATE:=60}"
: "${FB_SHM_ROI:=}"
: "${FB_SHM_SOCK:=/tmp/qemu-stealth-${INSTANCE}.fb}"
: "${GPU_ZEROCOPY=0}"
: "${GPU_HOSTMEM:=256M}"
: "${GPU_DISPLAY:=sdl}"
: "${GPU_RENDERNODE:=}"
# 默认使用无 virgl 的长期稳定路径；显式选择 GL/EGL 后端仍是可靠的 opt-in。
# 显式 STABLE_DISPLAY 的优先级更高，后续冲突门禁会降级或 fail closed。
if [[ "$_stable_display_explicit" == "0" &&
      "$_gpu_display_explicit" == "1" &&
      ( "$GPU_DISPLAY" == "sdl-egl" || "$GPU_DISPLAY" == "egl-headless" ) ]]; then
    STABLE_DISPLAY=0
fi
case "$STABLE_DISPLAY" in
    0|1) ;;
    *)
        echo "ERROR: STABLE_DISPLAY 必须是 0 或 1 (实际: '$STABLE_DISPLAY')" >&2
        exit 2
        ;;
esac
# blob/hostmem 会改变 guest 可见的 PCI BAR 布局，因此即使显式选择
# GL 也默认使用 gl-safe；只有 --gpu-zerocopy/GPU_ZEROCOPY=1 才开启。
# 导出失败时 fb-shm 仍可以回退到 CPU/SHM，不需要重启 VM。
# QMP 多客户端：PROXY=1 时启用 QEMU 原生 multi=on QMP listener，同一路径可被
# dgame / image-search / 临时 socat 同时连接。为了兼容旧工具配置，启动脚本还会
# 建一个 ${QMP_SOCK}.proxy -> ${QMP_SOCK} 的 symlink，但不再起 Python 中转进程。
: "${PROXY:=0}"
# host 侧调度/时钟抖动调优: 起 VM 前自动跑 host-performance.sh(PPD performance，
# 无 PPD 时回退 performance governor；另含 halt_poll/THP/split-lock)。多开时主要
# 靠 cpuset 隔离防止宿主编译抢 vCPU；如需旧低延迟 busy-poll 策略，可显式
# KVM_HALT_POLL_NS=500000。
# 只动 host 侧, 零反检测硬件身份影响.
# 已调优则自动跳过(免每次 sudo); DRY_RUN 下严格 no-op. (flag: --host-tune/--no-host-tune)
: "${HOST_TUNE:=1}"
# Linux 的默认 split-lock mitigation 会故意让触发者等待并单核串行；KVM
# 中的 Windows 驱动/解压路径偶发时会表现成整机卡顿。专用本地 VM 宿主默认
# 取消该故意降速；多租户宿主如需防止恶意 split-lock DoS，显式设为 1。
# HOST_TUNE=0 时不会修改宿主当前值。
: "${SPLIT_LOCK_MITIGATE:=0}"
case "$SPLIT_LOCK_MITIGATE" in
    0|1) ;;
    *)
        echo "ERROR: SPLIT_LOCK_MITIGATE 必须是 0 或 1" >&2
        exit 2
        ;;
esac
# QEMU 的 usb-kbd 直接读取 guest HID LED 报告。每次明确 OFF 只异步注入一组
# 原子 NumLock click，并等待 ON 后才允许下一轮，连续 OFF 不会造成按键连发。
# 默认持续强制开启；设 0 允许 guest/用户自行切换，不改变物理 host 键盘状态。
: "${GUEST_NUMLOCK:=1}"
case "$GUEST_NUMLOCK" in
    0|1) ;;
    *)
        echo "ERROR: GUEST_NUMLOCK 必须是 0 或 1" >&2
        exit 2
        ;;
esac
# CPU 频率封顶: 把 host scaling_max_freq 压到本实例伪装 CPU 的 CPU_MAX_MHZ(SMBIOS
# Type4 自报上限), 防止 guest 实测吞吐超出该型号规格(超规格=变速器/计时异常 tell).
# 只降不升(多 VM 取运行中最小, 绝不让任一 VM 超自身规格). HOST_TUNE=1 时才生效.
# (flag: --freq-cap / --no-freq-cap)
# 全局 scaling_max_freq 会同时影响管理核和其它 VM。默认关闭，只有明确评估过宿主
# 调度策略后才用 --freq-cap 开启；vCPU 性能隔离优先依靠 cpuset/NUMA 放置。
: "${CPU_FREQ_CAP:=0}"
# CPU 亲和按 vCPU:host logical CPU=1:1 分配：2C2T/2C4T/4C4T 的 exact 分别
# 为 2/4/4 条线程；2C2T/4C4T 在单台 VM 内跨不同物理核，2C4T 使用两颗 SMT2 核。
# 同一逻辑 CPU 绝不跨 VM 重复；未选 sibling 可供宿主/其它 VM 使用并共享执行资源。
# exact 分区随 VM 起停伸缩并精确还核；纯运行态(cgroup v2)，默认开。
# HOST_RESERVE_CORES=auto 固定为 max(2, ceil(完整 SMT2 核数×12.5%))；这里的 1/8
# 是宿主管理核保留比例，不是 VM 数量。只在本次实例本身容量不足时缩小，不随已运行
# VM 数量改变；显式 N 表示硬预留。
# 设 0 只取消前缀预留，root helper 仍保证宿主至少剩 2 颗完整核。
# (flag: --cpu-isolate / --no-cpu-isolate)
: "${CPU_ISOLATE:=1}"
# QEMU 辅助线程专用逻辑 CPU 数：默认 auto；容量允许时为 QEMU main / IO /
# SDL / fb-shm 等非 vCPU 线程分配 1 个独立逻辑 CPU，低核或多 VM 容量不足时回退 0，
# 避免辅助线程和满载 vCPU 抢同一条调度队列。显式数值保持严格、不自动降级。
# 常用：--svc-cpu（等价 1）或 --svc-cpus=2；长别名
# --qemu-service-cpu / --qemu-service-cpus=N 保留兼容。环境变量也可用短名
# QEMU_SVC_CPUS=1，显式 QEMU_SERVICE_CPUS 优先级更高。
: "${QEMU_SERVICE_CPUS:=${QEMU_SVC_CPUS:-auto}}"
# IMAGE_ROOT/VMS_DIR 让整套 VM 数据可迁移到任意挂载点；默认保持历史路径不变。
: "${IMAGE_ROOT:=/home/ubuntu/images}"
IMAGE_ROOT="${IMAGE_ROOT%/}"
[[ -n "$IMAGE_ROOT" ]] || IMAGE_ROOT="/"
: "${VMS_DIR:=$IMAGE_ROOT/vms}"
VMS_DIR="${VMS_DIR%/}"
[[ -n "$VMS_DIR" ]] || VMS_DIR="/"
: "${ISO:=${_cli_iso:-$IMAGE_ROOT/win10.iso}}"
[[ -n "$_cli_iso" ]] && ISO="$_cli_iso"

# 显示模式：SDL 窗口 + fb-shm 推流默认全开（互不影响）。
#   (无 flag)            -> SDL 窗口 + fb-shm        ← 默认
#   --headless           -> VNC 远程  + fb-shm（去窗口、加远程）
#   --no-sdl             -> 关窗口，仅 fb-shm（适合后台 daemon / nohup）
#   --gpu-sdl-egl        -> SDL 本地窗口兼容名（QEMU 11 自动探测 EGL）
#   --gpu-headless       -> EGL rendernode + fb-shm（GPU 零拷贝推流验证）
#   --no-fb-shm          -> 关推流，仅 SDL/VNC（回历史行为）
#   --sdl --headless     -> 冲突，按 --headless 走
case "$GPU_DISPLAY" in
    sdl|sdl-egl|egl-headless) ;;
    *)
        echo "ERROR: GPU_DISPLAY 只支持 sdl、sdl-egl 或 egl-headless (实际: '$GPU_DISPLAY')" >&2
        exit 2 ;;
esac
if [[ "$STABLE_DISPLAY" == "1" && "$GPU_DISPLAY" == "sdl-egl" ]]; then
    # 中文注释：stable 模式故意关闭 virtio-gpu GL；兼容名 sdl-egl 此时没有
    # 可供官方 SDL/EGL 后端绑定的 GL scanout，退回普通 SDL 稳定路径。
    GPU_DISPLAY=sdl
fi
if [[ "$GPU_DISPLAY" == "egl-headless" && "$HEADLESS" == "1" ]]; then
    echo "ERROR: --gpu-headless/GPU_DISPLAY=egl-headless 不能和 --headless/VNC 同时使用" >&2
    exit 2
fi
if [[ "$GPU_DISPLAY" == "egl-headless" && "$STABLE_DISPLAY" == "1" ]]; then
    echo "ERROR: GPU EGL headless 需要 virtio-vga-gl；请取消 STABLE_DISPLAY=1" >&2
    exit 2
fi
if [[ "$GPU_DISPLAY" == "egl-headless" ]]; then
    SDL=0
fi
if [[ "$HEADLESS" == "1" ]]; then
    SDL=0   # headless 强制无窗口（VNC 替代）
fi
if [[ "$FB_SHM" != "1" && "$SDL" != "1" && "$HEADLESS" != "1" ]]; then
    echo ">> WARN: --no-fb-shm + --no-sdl + 无 --headless，guest 无任何显示输出"
fi
# 后台 daemon 情况自动降级：DISPLAY 没设 + 不在 tty + 没显式 --headless => 关 SDL
if [[ "$SDL" == "1" && -z "${DISPLAY:-}" && ! -t 1 && "$HEADLESS" != "1" ]]; then
    echo ">> 自动降级: 无 DISPLAY 且非交互式终端 -> 关 SDL，仅 fb-shm 推流"
    SDL=0
fi

# fb-shm 校验：rate 必须在 [1,240]
if [[ "$FB_SHM" == "1" ]]; then
    if ! [[ "$FB_SHM_RATE" =~ ^[0-9]+$ ]] || (( FB_SHM_RATE < 1 || FB_SHM_RATE > 240 )); then
        echo "ERROR: FB_SHM_RATE 必须是 [1,240] 的整数 (实际: '$FB_SHM_RATE')" >&2
        exit 2
    fi
    if [[ -n "$FB_SHM_ROI" ]] && ! [[ "$FB_SHM_ROI" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]]; then
        echo "ERROR: FB_SHM_ROI 必须是 x,y,w,h 整数四元组 (实际: '$FB_SHM_ROI')" >&2
        exit 2
    fi
fi

if [[ "$GPU_ZEROCOPY" != "0" && "$GPU_ZEROCOPY" != "1" ]]; then
    echo "ERROR: GPU_ZEROCOPY 必须是 0 或 1 (实际: '$GPU_ZEROCOPY')" >&2
    exit 2
fi
# hostmem 是 PCI BAR，QEMU 要求大小为 2 的幂；限定在
# 256 MiB..8 GiB，避免 300M 等值进入 PCI 层后触发 assertion。
_gpu_hostmem_ok=0
if [[ "$GPU_ZEROCOPY" == "0" && "$_gpu_hostmem_explicit" == "0" ]]; then
    _gpu_hostmem_ok=1
elif [[ "$GPU_HOSTMEM" =~ ^([0-9]+)([KkMmGg]?)$ && ${#BASH_REMATCH[1]} -le 10 ]]; then
    _gpu_hostmem_n=$((10#${BASH_REMATCH[1]}))
    case "${BASH_REMATCH[2],,}" in
        "") _gpu_hostmem_min=268435456; _gpu_hostmem_max=8589934592 ;;
        k)  _gpu_hostmem_min=262144;    _gpu_hostmem_max=8388608 ;;
        m)  _gpu_hostmem_min=256;       _gpu_hostmem_max=8192 ;;
        g)  _gpu_hostmem_min=1;         _gpu_hostmem_max=8 ;;
    esac
    (( _gpu_hostmem_n >= _gpu_hostmem_min && _gpu_hostmem_n <= _gpu_hostmem_max &&
       (_gpu_hostmem_n & (_gpu_hostmem_n - 1)) == 0 )) && _gpu_hostmem_ok=1
fi
if [[ "$_gpu_hostmem_ok" != "1" ]]; then
    echo "ERROR: GPU_HOSTMEM 必须是 256M..8G 内 2 的幂（如 256M/1G/8G）(实际: '$GPU_HOSTMEM')" >&2
    exit 2
fi
if [[ "$_gpu_hostmem_explicit" == "1" && "$GPU_ZEROCOPY" != "1" ]]; then
    echo "ERROR: 显式 GPU_HOSTMEM/--gpu-hostmem 需要同时启用 GPU_ZEROCOPY=1/--gpu-zerocopy" >&2
    exit 2
fi
# 零拷贝不得在 stable/VNC/纯无窗口模式下被静默忽略；这些路径
# 没有 virgl GL provider，无法消费 blob/hostmem 能力。
if [[ "$GPU_ZEROCOPY" == "1" && ( "$STABLE_DISPLAY" == "1" ||
      ( "$SDL" != "1" && "$GPU_DISPLAY" != "egl-headless" ) ) ]]; then
    echo "ERROR: GPU_ZEROCOPY=1 需要显式 GL 显示（STABLE_DISPLAY=0 + SDL/EGL headless）" >&2
    exit 2
fi
if [[ "$GPU_ZEROCOPY" == "1" && "$FB_SHM" != "1" ]]; then
    echo "ERROR: GPU_ZEROCOPY=1 仅服务 fb-shm GPU handle，不能与 --no-fb-shm/FB_SHM=0 同时使用" >&2
    exit 2
fi
if [[ "$GPU_ZEROCOPY" == "1" ]]; then
    echo ">> WARN: GPU zero-copy 已显式启用；guest PCI BAR 将重排（MSI-X BAR4→BAR1，BAR4/5 host-visible=${GPU_HOSTMEM}）" >&2
fi
if [[ -n "$GPU_RENDERNODE" && ! -e "$GPU_RENDERNODE" ]]; then
    echo "ERROR: GPU_RENDERNODE 不存在: $GPU_RENDERNODE" >&2
    exit 2
fi

# QEMU_SERVICE_CPUS 是隔离层参数，不影响 QEMU argv；DRY_RUN 也需要校验，防止错误配置
# 在真正启动时才暴露。auto 会按本次宿主剩余容量选择 1 或兼容回退 0。
if ! [[ "$QEMU_SERVICE_CPUS" =~ ^(auto|[0-8])$ ]]; then
    echo "ERROR: QEMU_SERVICE_CPUS 必须是非负整数 [0,8] 或 auto (实际: '$QEMU_SERVICE_CPUS')" >&2
    exit 2
fi

# DISPLAY 默认 :0（典型本地 X11 会话）；从 SSH 终端运行时若未 export DISPLAY，
# 这里自动补上让 SDL 能找到 X server。只有 --sdl 才会真创窗口；
# 纯 fb-shm（默认）和 --headless 都不需要 DISPLAY。
if [[ "${SDL:-0}" == "1" && "${HEADLESS:-0}" != "1" ]]; then
    : "${DISPLAY:=:0}"
    export DISPLAY
fi

# 新版目录结构：所有 per-instance 文件都归在 $VMS_DIR/<N>/。
# VM_DIR 可显式覆盖，便于把单个实例放到独立磁盘；老版 flat 布局会按
# IMAGE_ROOT 自动迁移到新位置。
VM_DIR="${VM_DIR:-${VMS_DIR}/${INSTANCE}}"
# DRY_RUN 时不建目录。真实实例目录包含磁盘、TPM 私钥/状态、NVRAM 和 profile，
# 必须归当前用户且为 0700；符号链接会扩大权限收紧/证书写入的作用域，直接拒绝。
if [[ "${DRY_RUN:-0}" != "1" ]]; then
    if [[ -L "$VM_DIR" ]]; then
        echo "ERROR: VM_DIR 不能是符号链接: $VM_DIR" >&2
        exit 1
    fi
    mkdir -p "$VM_DIR"
    if [[ "$(stat -c '%u' "$VM_DIR" 2>/dev/null)" != "$(id -u)" ]]; then
        echo "ERROR: VM_DIR 必须归当前用户所有: $VM_DIR" >&2
        exit 1
    fi
    chmod 0700 "$VM_DIR"
fi
: "${DISK:=$VM_DIR/disk.qcow2}"
: "${QEMU:=$REPO_ROOT/build/qemu-system-x86_64}"
: "${QEMU_IMG:=$REPO_ROOT/build/qemu-img}"
# Bridge is the default network backend. Pass BRIDGE= (empty) or NO_BRIDGE=1
# to opt out and fall back to user-mode NAT. Reason: a real LAN IP is the
# whole point of the stealth bundle for DNF — user mode's 10.0.2.x subnet
# is itself a VM signal.
: "${BRIDGE:=br0}"
[[ "${NO_BRIDGE:-0}" == "1" ]] && BRIDGE=""
PROFILE_FILE="$VM_DIR/profile"

# 兼容老布局：把旧路径文件迁到新目录
for _legacy_pair in \
    "$IMAGE_ROOT/win10-inst${INSTANCE}.qcow2|$VM_DIR/disk.qcow2" \
    "$IMAGE_ROOT/stealth-inst${INSTANCE}.profile|$VM_DIR/profile" \
    "$IMAGE_ROOT/ovmf-vars-${INSTANCE}.fd|$VM_DIR/ovmf-vars.fd"
do
    _src="${_legacy_pair%|*}"
    _dst="${_legacy_pair##*|}"
    if [[ -f "$_src" && ! -f "$_dst" ]]; then
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            echo ">> [DRY_RUN] 跳过 legacy 迁移（只打印不执行）: $_src -> $_dst"
        else
            mv "$_src" "$_dst"
            echo ">> migrated legacy: $_src -> $_dst"
        fi
    fi
done

# Low-entropy bash RANDOM seed only used when we re-roll identity; the saved
# profile pins the final values, so reseed quality doesn't matter for steady
# state.
RANDOM=$((INSTANCE * 13 + $(date +%s) % 32768))
