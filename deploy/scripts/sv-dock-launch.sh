#!/bin/bash
# ---------------------------------------------------------------------------
# sv-dock-launch.sh — dash-to-dock 图标的点击入口（每个 win10-<N>.desktop 的 Exec）
#
# 为什么需要它（根因）：
#   GNOME 在 dash-to-dock 里「取消固定 → 拖动 → 重新固定」等收藏抖动后，会丢掉
#   「正在运行的 SDL 窗口 ↔ win10-<N>.desktop」的关联。一旦关联丢失，左键点图标
#   就被 GNOME 当成「该应用没有窗口 → 启动它」，于是直接跑 .desktop 的 Exec。
#   若 Exec 直接是 `gnome-terminal -- start-vm.sh N`，后果是：弹出终端刷一堆命令、
#   start-vm 再起一个 qemu 撞 qcow2 写锁失败，而真正的窗口被晾在一边，只能 Alt+Tab。
#   （start-vm.sh 本身没有「已运行就拒绝」的护栏，所以盲目 Exec 必然踩坑。）
#
# 解决：把 Exec 指到本脚本。本脚本「先找窗口、能前置就前置，绝不盲目重启」：
#   1) 实例已在运行：
#        - 找得到 win10-<N> 窗口 → 激活 + 置顶（顺手重设 WM_CLASS 触发 mutter 重新
#          关联，修复收藏抖动后丢失的 dock 运行点/分组），退出。
#        - 找不到窗口（还在 OVMF/启动中，或无 xdotool）→ 通知「已在运行」，退出，
#          绝不二次启动。
#   2) 实例没在运行 → 才真正启动（沿用 gnome-terminal 让用户看启动日志）。
#
# 稳定铁律：纯尽力而为，任何外部命令失败都不致命；即便没有 xdotool，靠进程检测
# 这一层护栏也能挡住「已运行还二次启动」的灾难。
# ---------------------------------------------------------------------------
set -u

n="${1:-}"
case "$n" in
    ''|*[!0-9]*) echo "用法: $0 <实例号 1..N> [start-vm 透传参数...]" >&2; exit 2;;
esac
shift || true
passthru=("$@"); [[ ${#passthru[@]} -eq 0 ]] && passthru=(--proxy)

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
START="$HERE/start-vm.sh"

# GNOME 会话里 DISPLAY/XAUTHORITY 通常已就绪；防御性兜底到 :1。
export DISPLAY="${DISPLAY:-:1}"
if [[ -z "${XAUTHORITY:-}" ]]; then
    _uid="$(id -u)"
    export XAUTHORITY="/run/user/${_uid}/gdm/Xauthority"
fi

_notify() {
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a "Win10-${n}" -i "win10-${n}" -- "$1" "${2:-}" 2>/dev/null || true
}

# 返回 win10-<N> 的窗口 id（锚定，避免 win10-3 命中 win10-30）；无 xdotool 返回非 0。
_find_win() {
    command -v xdotool >/dev/null 2>&1 || return 1
    local id
    id="$(xdotool search --class "^win10-${n}$" 2>/dev/null | head -1)"
    [[ -n "$id" ]] && { printf '%s\n' "$id"; return 0; }
    return 1
}

# 实例 N 的 qemu 是否在跑（cmdline 里 -name win10-<N>,…；逗号锚定，3 不误命中 30）。
_running() {
    pgrep -f -- "-name win10-${n}," >/dev/null 2>&1 \
        || pgrep -f -- "name win10-${n}," >/dev/null 2>&1
}

# ---- 1) 已运行：前置窗口，绝不重启 ----
if _running; then
    if wid="$(_find_win)"; then
        # 重设 WM_CLASS → 触发 mutter 重做「窗口↔.desktop」关联，修复收藏抖动后
        # 丢失的运行点/分组（同值幂等；SDL 创建后不再改 WM_CLASS，覆盖安全持久）。
        xdotool set_window --classname "win10-${n}" --class "win10-${n}" "$wid" 2>/dev/null || true
        timeout 3 xdotool windowactivate --sync "$wid" 2>/dev/null
        xdotool windowraise "$wid" 2>/dev/null || true
        exit 0
    fi
    # 进程在、窗口还没映射（启动中）或无 xdotool → 别二次启动
    _notify "win10-${n} 正在启动…" "窗口即将出现，或用 Alt+Tab 切换"
    exit 0
fi

# ---- 2) 没运行：真正启动（保留终端日志 UX）----
if command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal --working-directory="$REPO_ROOT" -- "$START" "$n" "${passthru[@]}"
fi
# 无图形终端：脱离父进程后台启动 + 落日志 + 通知
log="/tmp/qemu-stealth-${n}.start.log"
_notify "正在启动 win10-${n}…" "日志: $log"
if command -v setsid >/dev/null 2>&1; then
    setsid "$START" "$n" "${passthru[@]}" >"$log" 2>&1 &
else
    nohup "$START" "$n" "${passthru[@]}" >"$log" 2>&1 &
fi
exit 0
