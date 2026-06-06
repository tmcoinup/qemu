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
        --proxy)         PROXY=1 ;;
        --no-proxy)      PROXY=0 ;;
        --host-tune)     HOST_TUNE=1 ;;
        --no-host-tune)  HOST_TUNE=0 ;;
        --freq-cap)      CPU_FREQ_CAP=1 ;;
        --no-freq-cap)   CPU_FREQ_CAP=0 ;;
        --hotkey-capture)     HOTKEY_CAPTURE=1 ;;
        --hotkey-capture=*)   HOTKEY_CAPTURE=1; HOTKEY_KEY="${1#*=}" ;;
        --no-hotkey-capture)  HOTKEY_CAPTURE=0 ;;
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
: "${FB_SHM_RATE:=60}"
: "${FB_SHM_ROI:=}"
: "${FB_SHM_SOCK:=/tmp/qemu-stealth-${INSTANCE}.fb}"
# QMP fanout proxy: QEMU 的 -qmp 单 slot, 谁先连占着. PROXY=1 就在 QEMU 旁边
# 起一个 qmp-proxy.py 后台进程, listen 在 ${QMP_SOCK}.proxy, 让 dgame /
# image-search / 临时 socat 都连代理 socket → 互不竞争. proxy 在 QEMU 退出
# (upstream EOF) 时自动 exit, 不需要手动清理.
: "${PROXY:=0}"
# 热键截图: HOTKEY_CAPTURE=1 时, 后台起 hotkey-capture.py, 同时给 QEMU 导出
# QEMU_HOTKEY_TRIGGER. 用户在 SDL 窗口里按 HOTKEY_KEY(默认 F4), 守护进程从
# fb-shm 零拷贝帧抓一张 PNG 存到 $VM_DIR/captures. guest 完全无感知.
# host 侧调度/时钟抖动调优: 起 VM 前自动跑 host-performance.sh(governor=performance
# + halt_poll=500000 + THP defrag=never), 压低 vCPU 服务延迟方差——ACE「游戏计时
# 异常」(13-131130-8) 这类反作弊时钟检测对抖动敏感. 只动 host 侧, 零反检测影响.
# 已调优则自动跳过(免每次 sudo); DRY_RUN 下严格 no-op. (flag: --host-tune/--no-host-tune)
: "${HOST_TUNE:=1}"
# CPU 频率封顶: 把 host scaling_max_freq 压到本实例伪装 CPU 的 CPU_MAX_MHZ(SMBIOS
# Type4 自报上限), 防止 guest 实测吞吐超出该型号规格(超规格=变速器/计时异常 tell).
# 只降不升(多 VM 取运行中最小, 绝不让任一 VM 超自身规格). HOST_TUNE=1 时才生效.
# (flag: --freq-cap / --no-freq-cap)
: "${CPU_FREQ_CAP:=1}"
: "${HOTKEY_CAPTURE:=0}"
: "${HOTKEY_KEY:=F4}"
: "${HOTKEY_SOCK:=/tmp/qemu-stealth-${INSTANCE}.hotkey}"
: "${HOTKEY_LOG:=/tmp/qemu-stealth-${INSTANCE}.hotkey.log}"
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
#   --no-fb-shm          -> 关推流，仅 SDL/VNC（回历史行为）
#   --sdl --headless     -> 冲突，按 --headless 走
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
: "${HOTKEY_OUT:=$VM_DIR/captures}"
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
