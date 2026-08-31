#!/usr/bin/env bash
# Generate one gitignored, host-local G-11 vGPU resource policy.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"

PRESET=rtx2080-16gb
TIER_MB=2048
TIER_EXPLICIT=0
FB_MODE=auto
GPU_BDF=auto
OUTPUT="$here/host/vgpu-host.conf"
FORCE=0
: "${MDEV_DEVICES_DIR:=/sys/bus/mdev/devices}"
: "${NVIDIA_MODULE_VERSION_FILE:=/sys/module/nvidia/version}"
: "${VGPU_HOST_LOCK_FILE:=/opt/nvidia-modes/state/current}"
: "${VGPU_HOST_LOCK_WAIT_SECONDS:=30}"

usage() {
    cat <<'EOF'
用法：./deploy/configure-g11-vgpu-host.sh [选项]

  --preset NAME       rtx2080-16gb（默认）
                      v100-pcie-16gb | v100-pcie-32gb
                      v100-sxm2-16gb | v100-sxm2-32gb
                      v100s-pcie-32gb | v100-fhhl-16gb
  --fb-mode MODE     auto（默认）| equal | mixed
                     V100/R570/R580 默认 mixed；RTX 2080 固定 equal
  --tier 1024|2048   equal 模式的 framebuffer 档（默认 2048）
  --gpu auto|BDF     NVIDIA GPU；多卡宿主建议写完整 0000:BB:DD.F
  --output FILE      输出路径（默认 deploy/host/vgpu-host.conf，已 gitignore）
  --force            原子替换已有的本机策略

脚本只生成宿主资源策略，不安装/修改驱动，不改 BCD，也不会写任何凭据。
切换 equal/mixed 或 1GB/2GB 档之前必须先关闭该 NVIDIA GPU 上的全部 VM/mdev。
EOF
}

while (($#)); do
    case "$1" in
        --preset)
            (($# >= 2)) || { echo '--preset 缺少参数' >&2; exit 2; }
            PRESET=$2
            shift 2
            ;;
        --tier)
            (($# >= 2)) || { echo '--tier 缺少参数' >&2; exit 2; }
            TIER_MB=$2
            TIER_EXPLICIT=1
            shift 2
            ;;
        --fb-mode)
            (($# >= 2)) || { echo '--fb-mode 缺少参数' >&2; exit 2; }
            FB_MODE=${2,,}
            shift 2
            ;;
        --gpu)
            (($# >= 2)) || { echo '--gpu 缺少参数' >&2; exit 2; }
            GPU_BDF=$2
            shift 2
            ;;
        --output)
            (($# >= 2)) || { echo '--output 缺少参数' >&2; exit 2; }
            OUTPUT=$2
            shift 2
            ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
done

TIER_MB=$(vgpu_profile_normalize_vram_mb "$TIER_MB") || exit $?
case "$FB_MODE" in
    auto|equal|mixed) ;;
    *) echo "--fb-mode 必须是 auto、equal 或 mixed: $FB_MODE" >&2; exit 2 ;;
esac
[[ "$GPU_BDF" == auto ||
   "$GPU_BDF" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]] || {
    echo "--gpu 必须是 auto 或完整 PCI BDF: $GPU_BDF" >&2
    exit 2
}

# G-11 always uses the production-signed B/name-only path.  RTX/R535 may
# tolerate a missing per-mdev backend during legacy migration; V100 is a
# fresh-host contract and requires the reviewed Hook for the per-mdev name and
# display contract. R570/R535 use the guarded framebuffer identity path;
# R580.159.01 remains name-only because its full tuple caused repeatable guest
# PTE failures/TDR/XID 43 on the physical V100 validation host.
IDENTITY_MODE=required
RM_FB_IDENTITY_MODE=required
SPOOF_MODE_VALUE=B
CONSOLE_INTERVAL=0
IS_V100=1
case "$PRESET" in
    rtx2080-16gb)
        IS_V100=0
        TOTAL_FB_MB=16384
        PROFILE_PREFIX=nvidia
        IDENTITY_MODE=auto
        RM_FB_IDENTITY_MODE=required
        SPOOF_MODE_VALUE=B
        CONSOLE_INTERVAL=16667
        ;;
    v100-pcie-16gb)  TOTAL_FB_MB=16384; PROFILE_PREFIX=V100 ;;
    v100-pcie-32gb)  TOTAL_FB_MB=32768; PROFILE_PREFIX=V100D ;;
    v100-sxm2-16gb)  TOTAL_FB_MB=16384; PROFILE_PREFIX=V100X ;;
    v100-sxm2-32gb)  TOTAL_FB_MB=32768; PROFILE_PREFIX=V100DX ;;
    v100s-pcie-32gb) TOTAL_FB_MB=32768; PROFILE_PREFIX=V100S ;;
    v100-fhhl-16gb)  TOTAL_FB_MB=16384; PROFILE_PREFIX=V100L ;;
    *)
        echo "未知 preset: $PRESET" >&2
        usage >&2
        exit 2
        ;;
esac

HOST_DRIVER_VERSION=$(cat "$NVIDIA_MODULE_VERSION_FILE" 2>/dev/null || true)
if (( IS_V100 == 1 )); then
    case "$HOST_DRIVER_VERSION" in
        535.161.05|570.172.07)
            RM_FB_IDENTITY_MODE=required
            ;;
        580.159.01)
            RM_FB_IDENTITY_MODE=off
            ;;
        *)
            echo "V100 策略只接受已审核 host driver 535.161.05、570.172.07 或 580.159.01；当前 ${HOST_DRIVER_VERSION:-未加载}" >&2
            exit 1
            ;;
    esac
fi

if [[ "$FB_MODE" == auto ]]; then
    if (( IS_V100 == 1 && TIER_EXPLICIT == 0 )) &&
            [[ "$HOST_DRIVER_VERSION" != 535.161.05 ]]; then
        FB_MODE=mixed
    else
        FB_MODE=equal
    fi
fi
if [[ "$FB_MODE" == mixed && "$IS_V100" != 1 ]]; then
    echo 'RTX 2080/2080 Ti unlock 路径未验证 mixed-size；只能使用 equal' >&2
    exit 2
fi
if [[ "$FB_MODE" == mixed && "$TIER_EXPLICIT" == 1 ]]; then
    echo '--fb-mode mixed 同时发布 1024/2048MB 映射，不能再指定 --tier' >&2
    exit 2
fi

if (( IS_V100 == 0 )); then
    case "$TIER_MB" in
        1024) RESOURCE_PROFILE=nvidia-256 ;;
        2048) RESOURCE_PROFILE=nvidia-257 ;;
    esac
else
    RESOURCE_PROFILE_1024=${PROFILE_PREFIX}-1Q
    RESOURCE_PROFILE_2048=${PROFILE_PREFIX}-2Q
    case "$TIER_MB" in
        1024) RESOURCE_PROFILE=$RESOURCE_PROFILE_1024 ;;
        2048) RESOURCE_PROFILE=$RESOURCE_PROFILE_2048 ;;
    esac
fi

OUTPUT_DIR=$(dirname -- "$OUTPUT")
[[ -n "$OUTPUT_DIR" ]] || { echo '输出目录为空' >&2; exit 2; }
mkdir -p -- "$OUTPUT_DIR"
[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || {
    echo "输出目录不是安全的普通目录: $OUTPUT_DIR" >&2
    exit 1
}
[[ ! -L "$OUTPUT" ]] || { echo "拒绝覆盖符号链接: $OUTPUT" >&2; exit 1; }

TEMP=$(mktemp "$OUTPUT_DIR/.vgpu-host.conf.XXXXXXXX")
cleanup() { rm -f -- "$TEMP"; }
trap cleanup EXIT
{
    cat <<EOF
# Generated by deploy/configure-g11-vgpu-host.sh; host-local, no credentials.
# preset=$PRESET
VGPU_MGPU=$GPU_BDF
VGPU_HOST_FB_MODE=$FB_MODE
EOF
    if [[ "$FB_MODE" == equal ]]; then
        cat <<EOF
VGPU_HOST_FB_TIER_MB=$TIER_MB
VGPU_RESOURCE_PROFILE=$RESOURCE_PROFILE
VGPU_RESOURCE_FB_MB=$TIER_MB
EOF
    else
        cat <<EOF
VGPU_RESOURCE_PROFILE_1024=$RESOURCE_PROFILE_1024
VGPU_RESOURCE_PROFILE_2048=$RESOURCE_PROFILE_2048
EOF
    fi
    cat <<EOF
VGPU_TOTAL_FB_MB=$TOTAL_FB_MB
VGPU_CAPACITY_CHECK=both
VGPU_CONSOLE_INTERVAL_US=$CONSOLE_INTERVAL
VGPU_MDEV_IDENTITY_MODE=$IDENTITY_MODE
VGPU_RM_FB_IDENTITY_MODE=$RM_FB_IDENTITY_MODE
SPOOF_MODE=$SPOOF_MODE_VALUE
EOF
} >"$TEMP"
bash -n "$TEMP"

assert_no_active_mdev() {
    local active_mdev=""

    if [[ -e "$MDEV_DEVICES_DIR" || -L "$MDEV_DEVICES_DIR" ]]; then
        [[ -d "$MDEV_DEVICES_DIR" && ! -L "$MDEV_DEVICES_DIR" &&
           -r "$MDEV_DEVICES_DIR" && -x "$MDEV_DEVICES_DIR" ]] || {
            echo "mdev 目录缺失遍历权限或不安全: $MDEV_DEVICES_DIR" >&2
            return 1
        }
        if ! active_mdev=$(find "$MDEV_DEVICES_DIR" -mindepth 1 -maxdepth 1 \
                -print -quit); then
            echo "无法枚举 mdev 目录: $MDEV_DEVICES_DIR" >&2
            return 1
        fi
        if [[ -n "$active_mdev" ]]; then
            echo "检测到活动 mdev $(basename -- "$active_mdev")，拒绝发布宿主档位" >&2
            echo "先正常关闭目标 NVIDIA GPU 上全部 VM，并确认 mdev 已回收。" >&2
            return 1
        fi
    fi
}

if [[ -e "$OUTPUT" ]]; then
    [[ -f "$OUTPUT" ]] || { echo "输出目标不是普通文件: $OUTPUT" >&2; exit 1; }
    if cmp -s -- "$TEMP" "$OUTPUT"; then
        echo "宿主策略已是目标状态: $OUTPUT"
        exit 0
    fi
    (( FORCE )) || {
        echo "宿主策略已存在且内容不同: $OUTPUT" >&2
        echo "确认该 GPU 上所有 VM 已关闭后，加 --force 原子替换。" >&2
        exit 1
    }
fi

# Publishing a new tier while an mdev is active makes the policy disagree with
# the running allocation.  On an initialized host, hold the exact persistent
# flock inode used by mdev create/remove from the active scan through rename.
# Before the driver/mode state is installed the lock may truly be absent; that
# narrow bootstrap case gets two active scans and a final lock-absence check.
HOST_LOCK_HELD=0
if [[ -e "$VGPU_HOST_LOCK_FILE" || -L "$VGPU_HOST_LOCK_FILE" ]]; then
    [[ -f "$VGPU_HOST_LOCK_FILE" && ! -L "$VGPU_HOST_LOCK_FILE" &&
       -r "$VGPU_HOST_LOCK_FILE" ]] || {
        echo "vGPU host 全局锁缺失/不安全: $VGPU_HOST_LOCK_FILE" >&2
        exit 1
    }
    [[ "$VGPU_HOST_LOCK_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
        echo "VGPU_HOST_LOCK_WAIT_SECONDS 必须是正整数" >&2
        exit 2
    }
    command -v flock >/dev/null 2>&1 || {
        echo "缺少 flock，不能安全发布宿主档位" >&2
        exit 1
    }
    exec {HOST_LOCK_FD}<"$VGPU_HOST_LOCK_FILE" || {
        echo "无法打开 vGPU host 全局锁: $VGPU_HOST_LOCK_FILE" >&2
        exit 1
    }
    flock -x -w "$VGPU_HOST_LOCK_WAIT_SECONDS" "$HOST_LOCK_FD" || {
        echo "等待 vGPU host 全局锁超时: $VGPU_HOST_LOCK_FILE" >&2
        exit 1
    }
    HOST_LOCK_HELD=1
    assert_no_active_mdev || exit $?
else
    assert_no_active_mdev || exit $?
fi

chmod 0644 "$TEMP"
if ((HOST_LOCK_HELD == 0)); then
    # Recheck immediately before publish.  Once the shared lock appears, only
    # a locked retry can safely decide whether an allocator is active.
    assert_no_active_mdev || exit $?
    if [[ -e "$VGPU_HOST_LOCK_FILE" || -L "$VGPU_HOST_LOCK_FILE" ]]; then
        echo "vGPU host 全局锁在 pre-driver 发布期间出现；拒绝无锁发布，请重试" >&2
        exit 1
    fi
fi
mv -fT -- "$TEMP" "$OUTPUT"
TEMP=
trap - EXIT

if [[ "$FB_MODE" == equal ]]; then
    mode_summary="单一档位:  ${TIER_MB}MB"
    resource_summary=$RESOURCE_PROFILE
    probe_args="--profile $RESOURCE_PROFILE"
else
    mode_summary='显存模式:  mixed（1GB/2GB 可混搭）'
    resource_summary="$RESOURCE_PROFILE_1024 + $RESOURCE_PROFILE_2048"
    probe_args=''
fi

cat <<EOF
已生成 G-11 宿主策略：$OUTPUT
  preset:     $PRESET
  GPU:        $GPU_BDF
  $mode_summary
  resource:   $resource_summary
  总显存:     ${TOTAL_FB_MB}MB（不扣固定余量）

下一步（只读检查）：
  ./deploy/host/probe-vgpu-host.sh --config "$OUTPUT" $probe_args
EOF
