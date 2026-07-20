#!/usr/bin/env bash
# Manage one qemu-fb-shm-stream sidecar for a G-11 VM instance.
#
# The VM launcher owns QEMU and the fb-shm display socket.  This helper owns
# only the encoder sidecar and its exact PID/process group.

set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

usage() {
    cat >&2 <<'EOF'
usage:
  fb-shm-stream.sh start VM_ID --output URL [options]
  fb-shm-stream.sh stop VM_ID
  fb-shm-stream.sh status VM_ID
  fb-shm-stream.sh health VM_ID

start options:
  --sock PATH           fb-shm control socket (default: VM run/fb-shm.sock)
  --roi X,Y,W,H         fixed capture region; X/Y >= 0, W/H > 0
  --rate HZ             1..240 (default: 30)
  --encoder NAME        ffmpeg video encoder (default: libx264)
  --bitrate RATE        integer plus optional K/M/G suffix (default: 6M)
  --preset NAME         encoder preset (default: veryfast)
  --gop FRAMES          1..1000 (default: 60)
  --container NAME      explicit ffmpeg muxer
  --mode auto|gpu|shm   frame transport mode (default: auto)
  --start-timeout SEC   socket/connect readiness timeout, 1..60 (default: 15)
  --stream-bin PATH     qemu-fb-shm-stream binary

URL must be an explicit rtmp(s), srt, udp or rtp destination, or an absolute
local output path.  Listener/wildcard destinations are rejected.
EOF
    exit 2
}

die() {
    echo "[fb-shm-stream] ERROR: $*" >&2
    exit 1
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_uint_range() {
    local label=$1 value=$2 min=$3 max=$4

    is_uint "$value" ||
        die "$label 必须是 ${min}..${max} 的整数: $value"
    (( 10#$value >= min && 10#$value <= max )) ||
        die "$label 超出范围 ${min}..${max}: $value"
}

validate_token() {
    local label=$1 value=$2

    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] ||
        die "$label 只能包含字母、数字、点、下划线和连字符"
}

validate_bitrate() {
    [[ "$1" =~ ^[1-9][0-9]{0,8}[KkMmGg]?$ ]] ||
        die "bitrate 格式非法: $1"
}

validate_roi() {
    local value=$1 x y w h extra

    IFS=, read -r x y w h extra <<<"$value"
    [[ -z "${extra:-}" && -n "${h:-}" ]] ||
        die "ROI 必须是 X,Y,W,H"
    validate_uint_range "ROI X" "$x" 0 16383
    validate_uint_range "ROI Y" "$y" 0 16383
    validate_uint_range "ROI W" "$w" 1 16384
    validate_uint_range "ROI H" "$h" 1 16384
    (( 10#$x + 10#$w <= 16384 && 10#$y + 10#$h <= 16384 )) ||
        die "ROI 坐标和尺寸不能超过 16384x16384"
}

validate_output() {
    local output=$1 lower authority hostport host ch i

    (( ${#output} > 0 && ${#output} <= 1024 )) ||
        die "output 不能为空或超过 1024 字节"
    for ((i = 0; i < ${#output}; i++)); do
        ch=${output:i:1}
        case "$ch" in
            [A-Za-z0-9]|.|_|-|~|:|/|'?'|'#'|@|'!'|+|,|%|=|'&'|'['|']')
                ;;
            *) die "output 含空白、控制字符或不安全的 shell 字符" ;;
        esac
    done

    lower=${output,,}
    if [[ "$output" == /* ]]; then
        [[ "$output" != "/" ]] || die "本地 output 不能是根目录"
        [[ ! -e "$output" && ! -L "$output" ]] ||
            die "本地 output 已存在；拒绝覆盖: $output"
        return
    fi

    case "$lower" in
        rtmp://*|rtmps://*|srt://*|udp://*|rtp://*) ;;
        *) die "output 必须是显式网络 URL 或绝对本地路径" ;;
    esac

    if [[ "$lower" =~ (^|[\?\&])(listen(=(1|true))?|mode=listener)($|[\&\#]) ]]; then
        die "禁止 listener 模式；推流只能主动连接显式目标"
    fi

    authority=${output#*://}
    authority=${authority%%/*}
    authority=${authority%%\?*}
    [[ -n "$authority" ]] || die "output URL 缺少目标主机"
    hostport=${authority##*@}
    if [[ "$hostport" == \[*\]* ]]; then
        host=${hostport#\[}
        host=${host%%\]*}
    else
        host=${hostport%%:*}
    fi
    case "${host,,}" in
        ""|"*"|"0.0.0.0"|"::"|"[::]")
            die "禁止 wildcard/listener 目标主机: ${host:-<empty>}"
            ;;
    esac
}

validate_socket_path() {
    local path=$1

    [[ "$path" == /* ]] || die "fb-shm socket 必须是绝对路径: $path"
    [[ ${#path} -lt 104 && "$path" != *$'\n'* && "$path" != *$'\r'* ]] ||
        die "fb-shm socket 路径过长或含控制字符"
}

ACTION=${1:-}
VM_ID=${2:-}
case "$ACTION" in
    start|stop|status|health) ;;
    -h|--help) usage ;;
    *) usage ;;
esac
[[ "$VM_ID" =~ ^[1-9][0-9]*$ ]] || usage
shift 2

# shellcheck source=lib/vm-storage.sh
source "$HERE/lib/vm-storage.sh"
vm_storage_init

if [[ "$ACTION" == start ]]; then
    vm_storage_prepare_instance "$VM_ID"
else
    vm_storage_validate_instance_tree "$VM_ID"
fi

RUN_DIR=$(vm_storage_instance_run_dir "$VM_ID")
LOG_DIR=$(vm_storage_instance_log_dir "$VM_ID")
PID_FILE="$RUN_DIR/fb-shm-stream.pid"
START_FILE="$RUN_DIR/fb-shm-stream.starttime"
SOCKET_FILE="$RUN_DIR/fb-shm-stream.socket"
READY_FILE="$RUN_DIR/fb-shm-stream.ready"
LOCK_FILE="$RUN_DIR/fb-shm-stream.lock"
LOG_FILE="$LOG_DIR/fb-shm-stream.log"

for state_file in \
    "$PID_FILE" "$START_FILE" "$SOCKET_FILE" "$READY_FILE" "$LOCK_FILE" \
    "$LOG_FILE"; do
    [[ ! -L "$state_file" ]] ||
        die "拒绝符号链接状态文件: $state_file"
done

exec {STREAM_LOCK_FD}>"$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
flock "$STREAM_LOCK_FD"

write_state_file() {
    local path=$1 value=$2 tmp="${1}.tmp.$$"

    printf '%s\n' "$value" >"$tmp"
    chmod 0600 "$tmp"
    mv -Tf -- "$tmp" "$path"
}

clear_state() {
    rm -f -- "$PID_FILE" "$START_FILE" "$SOCKET_FILE" "$READY_FILE"
}

proc_identity() {
    local pid=$1 stat tail
    local -a fields

    [[ -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat 2>/dev/null <"/proc/$pid/stat" || return 1
    tail=${stat##*) }
    read -r -a fields <<<"$tail"
    (( ${#fields[@]} >= 20 )) || return 1
    [[ "${fields[0]}" != Z ]] || return 1
    printf '%s\n' "${fields[19]}"
}

stream_identity_valid() {
    local pid expected actual pgid

    [[ -f "$PID_FILE" && -f "$START_FILE" ]] || return 1
    IFS= read -r pid <"$PID_FILE" || return 1
    IFS= read -r expected <"$START_FILE" || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$expected" =~ ^[0-9]+$ ]] || return 1
    actual=$(proc_identity "$pid") || return 1
    [[ "$actual" == "$expected" ]] || return 1
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null)
    pgid=${pgid//[[:space:]]/}
    [[ "$pgid" == "$pid" ]] || return 1
}

stream_pid() {
    local pid

    IFS= read -r pid <"$PID_FILE"
    printf '%s\n' "$pid"
}

terminate_stream() {
    local pid i

    stream_identity_valid || return 0
    pid=$(stream_pid)
    kill -TERM -- "-$pid" 2>/dev/null || true
    for ((i = 0; i < 50; i++)); do
        stream_identity_valid || return 0
        sleep 0.1
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
    for ((i = 0; i < 20; i++)); do
        stream_identity_valid || return 0
        sleep 0.1
    done
    return 1
}

case "$ACTION" in
    status)
        (( $# == 0 )) || usage
        if stream_identity_valid; then
            echo "[fb-shm-stream] vm${VM_ID} running pid=$(stream_pid)"
            exit 0
        fi
        echo "[fb-shm-stream] vm${VM_ID} stopped"
        exit 3
        ;;
    health)
        (( $# == 0 )) || usage
        if ! stream_identity_valid; then
            echo "[fb-shm-stream] vm${VM_ID} unhealthy: process not running" >&2
            exit 3
        fi
        [[ -f "$READY_FILE" && -f "$SOCKET_FILE" ]] ||
            die "vm${VM_ID} streamer 尚未 ready"
        IFS= read -r STREAM_SOCKET <"$SOCKET_FILE"
        [[ -S "$STREAM_SOCKET" ]] ||
            die "vm${VM_ID} fb-shm socket 已消失: $STREAM_SOCKET"
        grep -Fq '[fb-shm] connected:' "$LOG_FILE" ||
            die "vm${VM_ID} streamer 缺少连接确认"
        echo "[fb-shm-stream] vm${VM_ID} healthy pid=$(stream_pid)"
        exit 0
        ;;
    stop)
        (( $# == 0 )) || usage
        if stream_identity_valid; then
            PID=$(stream_pid)
            echo "[fb-shm-stream] stopping vm${VM_ID} pid=$PID"
            terminate_stream ||
                die "vm${VM_ID} streamer 在 SIGKILL 后仍未退出"
        else
            echo "[fb-shm-stream] vm${VM_ID} streamer already stopped"
        fi
        clear_state
        exit 0
        ;;
esac

OUTPUT=""
STREAM_SOCKET="$RUN_DIR/fb-shm.sock"
ROI=""
RATE=30
ENCODER=libx264
BITRATE=6M
PRESET=veryfast
GOP=60
CONTAINER=""
MODE=auto
START_TIMEOUT=15
STREAM_BIN=${QEMU_FB_SHM_STREAM_BIN:-"$REPO_ROOT/build/qemu-fb-shm-stream"}

while (( $# > 0 )); do
    case "$1" in
        --output|--sock|--roi|--rate|--encoder|--bitrate|--preset|--gop|\
        --container|--mode|--start-timeout|--stream-bin)
            (( $# >= 2 )) || usage
            case "$1" in
                --output) OUTPUT=$2 ;;
                --sock) STREAM_SOCKET=$2 ;;
                --roi) ROI=$2 ;;
                --rate) RATE=$2 ;;
                --encoder) ENCODER=$2 ;;
                --bitrate) BITRATE=$2 ;;
                --preset) PRESET=$2 ;;
                --gop) GOP=$2 ;;
                --container) CONTAINER=$2 ;;
                --mode) MODE=$2 ;;
                --start-timeout) START_TIMEOUT=$2 ;;
                --stream-bin) STREAM_BIN=$2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

[[ -n "$OUTPUT" ]] || die "--output 是必需参数；不会创建隐式监听端点"
validate_output "$OUTPUT"
validate_socket_path "$STREAM_SOCKET"
[[ -z "$ROI" ]] || validate_roi "$ROI"
validate_uint_range rate "$RATE" 1 240
validate_token encoder "$ENCODER"
validate_bitrate "$BITRATE"
validate_token preset "$PRESET"
validate_uint_range gop "$GOP" 1 1000
[[ -z "$CONTAINER" ]] || validate_token container "$CONTAINER"
case "$MODE" in
    auto|gpu|shm) ;;
    *) die "mode 必须是 auto、gpu 或 shm" ;;
esac
validate_uint_range start-timeout "$START_TIMEOUT" 1 60

[[ "$STREAM_BIN" == /* ]] ||
    STREAM_BIN="$PWD/$STREAM_BIN"
STREAM_BIN=$(readlink -f -- "$STREAM_BIN") ||
    die "无法解析 streamer 路径: $STREAM_BIN"
[[ -x "$STREAM_BIN" && -f "$STREAM_BIN" ]] ||
    die "streamer 不可执行: $STREAM_BIN"
command -v setsid >/dev/null 2>&1 || die "缺少 setsid"

if stream_identity_valid; then
    die "vm${VM_ID} streamer 已运行，先 stop 再 start"
fi
clear_state

for ((i = 0; i < 10#$START_TIMEOUT * 20; i++)); do
    [[ -S "$STREAM_SOCKET" ]] && break
    sleep 0.05
done
[[ -S "$STREAM_SOCKET" ]] ||
    die "等待 fb-shm socket 超时: $STREAM_SOCKET"

: >"$LOG_FILE"
chmod 0600 "$LOG_FILE"

STREAM_ARGS=(
    --sock "$STREAM_SOCKET"
    --output "$OUTPUT"
    --encoder "$ENCODER"
    --preset "$PRESET"
    --bitrate "$BITRATE"
    --gop "$GOP"
    --rate "$RATE"
    --mode "$MODE"
)
[[ -z "$ROI" ]] || STREAM_ARGS+=(--roi "$ROI")
[[ -z "$CONTAINER" ]] || STREAM_ARGS+=(--container "$CONTAINER")

(
    # The sidecar must not inherit the lifecycle lock; otherwise every later
    # health/stop invocation would block until the sidecar exits by itself.
    exec {STREAM_LOCK_FD}>&-
    exec setsid -- "$STREAM_BIN" "${STREAM_ARGS[@]}"
) </dev/null >>"$LOG_FILE" 2>&1 &
PID=$!

for ((i = 0; i < 20; i++)); do
    STARTTIME=$(proc_identity "$PID" 2>/dev/null || true)
    PGID=$(ps -o pgid= -p "$PID" 2>/dev/null || true)
    PGID=${PGID//[[:space:]]/}
    [[ -n "$STARTTIME" && "$PGID" == "$PID" ]] && break
    sleep 0.01
done
if [[ -z "${STARTTIME:-}" || "${PGID:-}" != "$PID" ]]; then
    wait "$PID" 2>/dev/null || true
    die "streamer 未能建立独立进程组；日志: $LOG_FILE"
fi

write_state_file "$PID_FILE" "$PID"
write_state_file "$START_FILE" "$STARTTIME"
write_state_file "$SOCKET_FILE" "$STREAM_SOCKET"

for ((i = 0; i < 10#$START_TIMEOUT * 20; i++)); do
    if ! stream_identity_valid; then
        wait "$PID" 2>/dev/null || RC=$?
        clear_state
        die "streamer 启动失败 rc=${RC:-unknown}；日志: $LOG_FILE"
    fi
    if grep -Fq '[fb-shm] connected:' "$LOG_FILE"; then
        write_state_file "$READY_FILE" ready
        echo "[fb-shm-stream] vm${VM_ID} ready pid=$PID log=$LOG_FILE"
        exit 0
    fi
    sleep 0.05
done

terminate_stream || true
wait "$PID" 2>/dev/null || true
clear_state
die "streamer 连接超时；日志: $LOG_FILE"
