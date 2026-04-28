#!/usr/bin/env bash
#
# connect.sh — connect host viewer to guest.
#
# Transport: native DXGI Desktop Duplication → 32x32 dirty-tile raw
# BGRA → ivshmem ring → host SDL2 viewer (stream-client/stream_client_dda).
# Input flows back through ivshmem input ring → relay → loopback
# AudioSvcHost → Win32 SendInput.
#
# 启动后 viewer 是普通窗口；**鼠标悬停 + 焦点在 viewer 内**才抓键盘，
# 鼠标移出 / 切到别的窗口 / 最小化 → 自动放掉键盘还宿主。Super 键
# 在 Wayland windowed 模式下永远到不了 viewer (mutter 协议硬限)，
# 用 Right Alt 当 Super 替代：RAlt+X = Win+X，RAlt 单按 = 按 Win。
#
# Hotkeys (focus 在 viewer 时):
#   RAlt          Win key (RAlt + X = Win + X，RAlt + R = Win + R...)
#   RAlt + Q      Quit viewer
#   RAlt + F11    Toggle fullscreen (Wayland 慎用)
#
# Prereqs in guest (one-time):
#   ./deploy/setup-guest.sh <vm_id>
#
# Usage:
#   ./connect.sh                       # vm1 default
#   ./connect.sh <vm_id>
#   ./connect.sh --shmem-path /dev/shm/nv-shmem-vm2
#   ./connect.sh 1 --fullscreen        # 显式全屏 (X11 session 推荐)
#   ./connect.sh 1 --tame-gnome        # 临时关 GNOME super-shortcut + 退出恢复
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
SHMEM_PATH=""
EXTRA_ARGS=()
TAME_GNOME=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shmem-path) SHMEM_PATH="$2"; shift 2 ;;
        --fullscreen) EXTRA_ARGS+=("$1"); shift ;;
        --windowed)   EXTRA_ARGS+=("$1"); shift ;;
        --width|--height) EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
        --tame-gnome) TAME_GNOME=1; shift ;;
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

# ────────────────────── GNOME super tame (opt-in) ──────────────────
# Windowed + XWayland 下抓 Super 注定失败 (mutter wayland 协议层
# 拦截，X grab 是 no-op；keyboard-shortcuts-inhibit 协议要求
# fullscreen)。所以默认**不动 GNOME 设置** — 留给用户自己决定。
# 用户加 --tame-gnome 时才临时 reset 几个 super-shortcut，并保证
# trap 恢复（包括 viewer 卡死被 KILL 时也通过 EXIT trap 触发）。
declare -A SAVED_BINDINGS=()
have_gsettings=0
if [[ $TAME_GNOME -eq 1 ]] \
    && command -v gsettings >/dev/null 2>&1 \
    && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}${XDG_RUNTIME_DIR:-}" ]]; then
    have_gsettings=1
    echo "[connect] tame GNOME super-shortcuts (will restore on exit)"
    for entry in \
        'org.gnome.mutter overlay-key' \
        'org.gnome.shell.keybindings toggle-overview' \
        'org.gnome.shell.keybindings toggle-application-view' \
        'org.gnome.shell.keybindings toggle-quick-settings' \
        'org.gnome.desktop.wm.keybindings panel-main-menu' \
    ; do
        schema="${entry% *}"
        key="${entry##* }"
        cur=$(gsettings get "$schema" "$key" 2>/dev/null) || continue
        SAVED_BINDINGS["$schema $key"]="$cur"
        if [[ "$cur" == \'*\' ]]; then
            gsettings set "$schema" "$key" "''" 2>/dev/null || true
        else
            gsettings set "$schema" "$key" "[]" 2>/dev/null || true
        fi
    done
fi

restore_gnome() {
    [[ $have_gsettings -eq 1 ]] || return 0
    for entry in "${!SAVED_BINDINGS[@]}"; do
        schema="${entry% *}"
        key="${entry##* }"
        gsettings set "$schema" "$key" "${SAVED_BINDINGS[$entry]}" 2>/dev/null || true
    done
}
trap 'restore_gnome' EXIT

"$BIN" --shmem "$SHMEM_PATH" "${EXTRA_ARGS[@]}"
rc=$?
exit "$rc"
