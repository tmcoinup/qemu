#!/bin/bash
# ---------------------------------------------------------------------------
# sv-dock.sh — GNOME dash-to-dock 集成（start-vm.sh 在 sv-assemble.sh 前 source）
#
# 目的：让每台 SDL 客机窗口在 dock 里成为「独立、可固定、可拖动排序、有编号图标」
# 的条目，而不是匿名的「运行中齿轮」。
#   根因：QEMU 自带 qemu.desktop 是 NoDisplay 且无 StartupWMClass；且三窗口默认
#   同 WM_CLASS=qemu-system-x86_64（SDL 取二进制名）→ dock 无法区分/固定/排序。
#
# 机制（任意实例号 N=1..9.. 全自动适配）：
#   1) export SDL_VIDEO_X11_WMCLASS=win10-<N>  → 每窗口唯一身份（SDL 读此环境变量）。
#   2) 落 StartupWMClass=win10-<N> 的 per-instance .desktop + 编号 PNG 图标到
#      ~/.local/share/{applications,icons/qemu-vm}/（幂等；图标缺失才重画）。
#   3) 首次启动该实例时把 win10-<N>.desktop 自动加进 GNOME favorite-apps（固定）。
#
# 软依赖（缺了就降级而非报错）：
#   convert(ImageMagick) 画编号图标；缺则 .desktop 回退 stock 图标 virt-manager。
#   gsettings+python3+flock+session bus 才自动固定；缺则只建图标（用户可手动固定）。
#
# 开关：DOCK_PIN=0 关闭"首启自动固定"（图标/窗口匹配仍生效）。
#
# 稳定性铁律：任何一步失败都不得拖垮 VM 启动 —— 入口以 `sv_dock_integrate || true`
# 调用（set -e 在函数内自动挂起），内部对每个外部命令再加 `|| true` / 2>/dev/null。
# ---------------------------------------------------------------------------

# 画一枚 256×256 编号图标（Windows 蓝圆角砖 + 大号数字 + WIN10 字样）。
# 仅当目标 PNG 不存在/为空时绘制；无 convert 时返回 1（由调用方回退 stock 图标）。
_sv_dock_make_icon() {
    local icon="$1" n="$2"
    [[ -s "$icon" ]] && return 0
    command -v convert >/dev/null 2>&1 || return 1
    local font=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
    [[ -f "$font" ]] || font=helvetica
    local ps=150; [[ "${#n}" -ge 2 ]] && ps=110   # 两位数字缩小字号防溢出
    convert -size 256x256 xc:none \
        -fill '#0A6CD4' -draw 'roundrectangle 16,16 240,240 38,38' \
        -fill '#1E83F0' -draw 'roundrectangle 16,16 240,128 38,38' \
        -font "$font" -fill white    -gravity center -pointsize "$ps" -annotate +0-6 "$n" \
        -font "$font" -fill '#CFE6FF' -gravity south  -pointsize 36   -annotate +0+22 'WIN10' \
        "$icon" 2>/dev/null || return 1
}

# 写 ~/.local/share/applications/win10-<N>.desktop（每次刷新，保证内容最新）。
_sv_dock_write_desktop() {
    local n="$1"
    local appdir="$HOME/.local/share/applications"
    local icodir="$HOME/.local/share/icons/qemu-vm"
    local icon="$icodir/win10-${n}.png"
    local desktop="$appdir/win10-${n}.desktop"
    mkdir -p "$appdir" "$icodir"
    _sv_dock_make_icon "$icon" "$n" || true
    local iconref="$icon"; [[ -s "$icon" ]] || iconref=virt-manager
    cat > "$desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Win10-${n}
Name[zh_CN]=Win10-${n} 虚拟机
GenericName=QEMU Virtual Machine
Comment=QEMU 隐身虚拟机 win10-${n}（DNF 多开）— 由 start-vm.sh 启动/匹配
Icon=${iconref}
Exec=gnome-terminal --working-directory=${REPO_ROOT} -- ${HERE}/start-vm.sh ${n} --proxy
Path=${REPO_ROOT}
Terminal=false
Categories=System;Emulator;
Keywords=QEMU;VM;DNF;win10;虚拟机;
StartupWMClass=win10-${n}
StartupNotify=false
NoDisplay=false
EOF
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database "$appdir" 2>/dev/null || true
}

# 首启把 win10-<N>.desktop 加进 GNOME 收藏（固定）。
#   - pin-once：标记文件存在就跳过 → 用户后来手动取消固定不会被强行加回。
#   - 并发安全：flock 串行化 favorite-apps 的读改写（多 VM 同时起不丢项）。
_sv_dock_pin_favorite() {
    local n="$1"
    [[ "${DOCK_PIN:-1}" == "1" ]] || return 0
    command -v gsettings >/dev/null 2>&1 || return 0
    command -v python3   >/dev/null 2>&1 || return 0
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || return 0
    local statedir="$HOME/.local/share/qemu-vm"; mkdir -p "$statedir"
    local marker="$statedir/.pinned-${n}"
    [[ -e "$marker" ]] && return 0
    local lock="$statedir/.fav.lock"
    _pin_do() {
        [[ -e "$marker" ]] && return 0
        python3 - "win10-${n}.desktop" <<'PY' || return 0
import sys, ast, subprocess
app = sys.argv[1]
cur = ast.literal_eval(subprocess.check_output(
    ['gsettings', 'get', 'org.gnome.shell', 'favorite-apps']).decode())
if app not in cur:
    cur.append(app)
    subprocess.run(['gsettings', 'set', 'org.gnome.shell', 'favorite-apps', str(cur)],
                   check=False)
PY
        : > "$marker"
    }
    if command -v flock >/dev/null 2>&1; then
        ( flock -w 5 9 || exit 0; _pin_do ) 9>"$lock"
    else
        _pin_do
    fi
}

# 入口：sv-assemble.sh 在确认 SDL 窗口模式后调用 `sv_dock_integrate || true`。
# 在当前 shell（非子 shell）执行，确保 export 的 WM_CLASS 对随后的 exec qemu 生效。
sv_dock_integrate() {
    local n="${INSTANCE:-}"
    [[ -n "$n" ]] || return 0
    export SDL_VIDEO_X11_WMCLASS="win10-${n}"
    _sv_dock_write_desktop "$n" || true
    echo ">> dash-to-dock:  WM_CLASS=win10-${n} + 桌面图标已就绪（可固定/拖动排序）"
    _sv_dock_pin_favorite "$n" || true
}
