# ---------------------- CLI parsing ----------------------
# First positional arg = INSTANCE. Everything else is --flag=value or --flag.
_cli_instance=""
_cli_iso=""
_cli_reroll=0
while (( $# > 0 )); do
    case "$1" in
        -h|--help) _usage 0 ;;
        --iso=*)      _cli_iso="${1#*=}" ;;
        --disk=*)     DISK="${1#*=}" ;;
        --bridge=*)   BRIDGE="${1#*=}" ;;
        --no-bridge)  NO_BRIDGE=1 ;;
        --qemu=*)     QEMU="${1#*=}" ;;
        --ram=*)      RAM="${1#*=}" ;;
        --cpus=*)     CPUS="${1#*=}" ;;
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
        --gpu-hostmem=*)    GPU_HOSTMEM="${1#*=}" ;;
        --gpu-headless)     GPU_DISPLAY=egl-headless; SDL=0 ;;
        --gpu-sdl-egl)      GPU_DISPLAY=sdl-egl; SDL=1 ;;
        --gpu-display=*)    GPU_DISPLAY="${1#*=}" ;;
        --gpu-rendernode=*) GPU_RENDERNODE="${1#*=}" ;;
        --proxy)         PROXY=1 ;;
        --no-proxy)      PROXY=0 ;;
        --host-tune)     HOST_TUNE=1 ;;
        --no-host-tune)  HOST_TUNE=0 ;;
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
if ! [[ "$INSTANCE" =~ ^[0-9]+$ ]] || (( INSTANCE < 1 )); then
    echo "ERROR: INSTANCE 必须是正整数 (实际: '$INSTANCE')" >&2
    exit 2
fi

# RAM 默认值故意不在这里钉死：profile.MEM_TOTAL_MB 可能提供持久化值，
# 所以推迟到 profile 加载之后再解析（见下方 "RAM 解析" 块）。
# 显式 --ram= / 环境 RAM= 在 CLI 解析阶段已赋值，会被那里当最高优先级保留。
: "${CPUS:=4}"
: "${HEADLESS:=0}"
: "${SDL:=1}"      # 默认：SDL 窗口仍然弹出（与历史行为一致）
: "${FB_SHM:=1}"   # 默认：再额外挂一条 -object fb-shm 推流通道
: "${STABLE_DISPLAY:=0}"
: "${FB_SHM_RATE:=60}"
: "${FB_SHM_ROI:=}"
: "${FB_SHM_SOCK:=/tmp/qemu-stealth-${INSTANCE}.fb}"
# GPU 零拷贝元数据依赖 virtio-gpu blob resource + host-visible memory。
# 默认打开，让 fb-shm 的 GPU consumer 能收到 dma-buf scanout；遇到旧 guest/旧
# virglrenderer 可用 --no-gpu-zerocopy 显式回退到历史 GL texture + SHM readback。
: "${GPU_ZEROCOPY:=1}"
: "${GPU_HOSTMEM:=256M}"
: "${GPU_DISPLAY:=sdl-egl}"
: "${GPU_RENDERNODE:=}"
# QMP 多客户端：PROXY=1 时启用 QEMU 原生 multi=on QMP listener，同一路径可被
# dgame / image-search / 临时 socat 同时连接。为了兼容旧工具配置，启动脚本还会
# 建一个 ${QMP_SOCK}.proxy -> ${QMP_SOCK} 的 symlink，但不再起 Python 中转进程。
: "${PROXY:=0}"
# host 侧调度/时钟抖动调优: 起 VM 前自动跑 host-performance.sh(governor=performance
# + KVM_HALT_POLL_NS(默认 0) + THP defrag=never)。多开时主要靠 cpuset 隔离
# 防止宿主编译抢 vCPU；如需旧低延迟 busy-poll 策略，可显式 KVM_HALT_POLL_NS=500000。
# 只动 host 侧, 零反检测硬件身份影响.
# 已调优则自动跳过(免每次 sudo); DRY_RUN 下严格 no-op. (flag: --host-tune/--no-host-tune)
: "${HOST_TUNE:=1}"
# CPU 频率封顶: 把 host scaling_max_freq 压到本实例伪装 CPU 的 CPU_MAX_MHZ(SMBIOS
# Type4 自报上限), 防止 guest 实测吞吐超出该型号规格(超规格=变速器/计时异常 tell).
# 只降不升(多 VM 取运行中最小, 绝不让任一 VM 超自身规格). HOST_TUNE=1 时才生效.
# (flag: --freq-cap / --no-freq-cap)
: "${CPU_FREQ_CAP:=1}"
# CPU 亲和隔离(线程级): 起 VM 后把 QEMU 钉进 cgroup cpuset 独占分区, 每个 vCPU 独占
# 1 个逻辑线程(非整核)——4vCPU 的 VM 只吃 4 个逻辑线程。分配器自动读取 host 拓扑，
# 先把不同 VM 横向铺到不同物理核心，物理核心主线程用尽后才使用 SMT 兄弟线程。
# 与宿主机负载(尤其 cargo/rust 编译)在调度层隔离: vCPU 永不被宿主机抢占。
# 多 VM 自动错开线程、分区随起停伸缩、停机自动还线程。纯运行态(cgroup v2
# partition, 不重启), 默认开。HOST_RESERVE_CORES=auto 默认自动预留
# max(2, ceil(物理核心数/8))，并会在多开需求过高时弹性缩小；显式 N 表示硬预留。
# 设 0 表示使用整机逻辑 CPU 池。
# (flag: --cpu-isolate / --no-cpu-isolate)
: "${CPU_ISOLATE:=1}"
# QEMU 辅助线程专用逻辑 CPU 数：默认 0，保持旧行为；显式启用后，root helper 会额外
# 给本 VM 分配 N 个逻辑 CPU，并把 QEMU main loop / IO / SDL / fb-shm worker 等非 vCPU
# 线程收窄到这些 CPU 上。这样 vCPU 仍独占自己的单核，显示/IO 线程也不再和满载 vCPU
# 抢同一条调度队列。常用：--svc-cpu（等价 1）或 --svc-cpus=2；长别名
# --qemu-service-cpu / --qemu-service-cpus=N 保留兼容。环境变量也可用短名
# QEMU_SVC_CPUS=1，显式 QEMU_SERVICE_CPUS 优先级更高。
: "${QEMU_SERVICE_CPUS:=${QEMU_SVC_CPUS:-0}}"
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
#   --gpu-sdl-egl        -> SDL 本地窗口 + native EGL（fb-shm GPU 零拷贝）
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
    # 中文注释：stable 模式故意关闭 virtio-gpu GL；native EGL 没有可绑定的 GL
    # scanout，自动退回普通 SDL 窗口，保持旧的稳定显示路径。
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
if [[ "$GPU_ZEROCOPY" == "1" ]]; then
    if ! [[ "$GPU_HOSTMEM" =~ ^[0-9]+([KkMmGgTt])?$ ]]; then
        echo "ERROR: GPU_HOSTMEM 必须是 QEMU size 值，如 256M/1G (实际: '$GPU_HOSTMEM')" >&2
        exit 2
    fi
fi
if [[ -n "$GPU_RENDERNODE" && ! -e "$GPU_RENDERNODE" ]]; then
    echo "ERROR: GPU_RENDERNODE 不存在: $GPU_RENDERNODE" >&2
    exit 2
fi

# QEMU_SERVICE_CPUS 是隔离层参数，不影响 QEMU argv；DRY_RUN 也需要校验，防止错误配置
# 在真正启动时才暴露。0 表示关闭辅助线程专用 CPU，保持历史行为。
if ! [[ "$QEMU_SERVICE_CPUS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: QEMU_SERVICE_CPUS 必须是非负整数 (实际: '$QEMU_SERVICE_CPUS')" >&2
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
# DRY_RUN 时不建目录（P1#1：真正无副作用 dry-run，误用新实例号也不留痕）。
[[ "${DRY_RUN:-0}" == "1" ]] || mkdir -p "$VM_DIR"
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
