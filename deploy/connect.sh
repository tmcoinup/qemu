#!/usr/bin/env bash
#
# connect.sh — connect host viewer to guest.
#
# Transport: native DXGI Desktop Duplication → 32x32 dirty-tile raw
# BGRA → ivshmem ring → host SDL2 viewer (stream-client/stream_client_dda).
# Input flows back through ivshmem input ring → relay → loopback
# AudioSvcHost → Win32 SendInput.
#
# 启动后 viewer 是普通窗口；鼠标移出 / 最小化时自动显回宿主光标。
# GNOME/Wayland 下鼠标在 viewer 窗口内时会临时关闭宿主 Super/Alt+Tab 绑定，
# 鼠标离开、最小化、隐藏或退出立即恢复。
# viewer 聚焦时不保留本地键盘热键；SDL 收到的键盘输入全部转发 guest。
#
# Prereqs in guest (one-time):
#   ./deploy/setup-guest.sh <vm_id>
#
# Usage:
#   ./connect.sh                       # vm1 default
#   ./connect.sh <vm_id>
#   ./connect.sh --shmem-path /dev/shm/nv-shmem-vm2
#   ./connect.sh 1 --fullscreen        # 显式全屏 (X11 session 推荐)
#   ./connect.sh 1 --no-tame-gnome     # 禁用 GNOME host-shortcut 动态保护
#
set -euo pipefail
here="$(dirname "$(readlink -f "$0")")"
cd "$here"

# shellcheck source=lib/gnome-shortcuts.sh
source "$here/lib/gnome-shortcuts.sh"

VM_ID=${VM_ID:-1}
SHMEM_PATH=""
EXTRA_ARGS=()
TAME_GNOME=${TAME_GNOME:-auto}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shmem-path) SHMEM_PATH="$2"; shift 2 ;;
        --fullscreen) EXTRA_ARGS+=("$1"); shift ;;
        --windowed)   EXTRA_ARGS+=("$1"); shift ;;
        --width|--height) EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
        --tame-gnome) TAME_GNOME=1; shift ;;
        --no-tame-gnome) TAME_GNOME=0; shift ;;
        -h|--help)    sed -n '3,30p' "$0"; exit 0 ;;
        [0-9]*)       VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$SHMEM_PATH" ]] || SHMEM_PATH="/dev/shm/nv-shmem-vm${VM_ID}"
[[ -e "$SHMEM_PATH" ]] || {
    echo "[connect] $SHMEM_PATH missing — start the VM (./start-vm.sh $VM_ID) first"
    exit 1
}

BIN=stream-client/stream_client_dda
SRC=stream-client/stream_client_dda.c
if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
    echo "[connect] building $BIN..."
    make -C stream-client all || { echo "build failed"; exit 1; }
fi

echo "[connect] vm${VM_ID}  shmem=$SHMEM_PATH"

# ─────────────────── GNOME host-shortcut tame (dynamic) ─────────────
# Windowed + XWayland 下抓 Super/Alt+Tab 注定失败 (mutter wayland 协议层
# 拦截，X grab 是 no-op；keyboard-shortcuts-inhibit 协议要求
# fullscreen)。viewer 只在鼠标位于窗口内时临时关掉 GNOME/IBus
# Super/Alt+Tab 快捷键，鼠标离开、最小化、隐藏或退出马上恢复。
should_tame_gnome_super() {
    local mode=${TAME_GNOME,,}
    case "$mode" in
        1|yes|true|on) return 0 ;;
        0|no|false|off) return 1 ;;
    esac
    gnome_super_shortcuts_is_gnome && gnome_super_shortcuts_available
}

if should_tame_gnome_super; then
    export GNOME_SUPER_GUARD="$here/gnome-super-guard.sh"
    "$GNOME_SUPER_GUARD" restore-stale 2>/dev/null || true
    EXTRA_ARGS+=(--tame-gnome)
    echo "[connect] GNOME/IBus host-shortcut guard: active only while the mouse is inside the viewer window"
fi
trap '"$here/gnome-super-guard.sh" restore-stale 2>/dev/null || true' EXIT

"$BIN" --vm "$VM_ID" --shmem "$SHMEM_PATH" "${EXTRA_ARGS[@]}"
rc=$?
exit "$rc"
