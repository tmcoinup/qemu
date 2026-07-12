#!/usr/bin/env bash
# 静态验证 SDL/GL scanout 的恢复重绘路径，避免窗口隐藏/恢复后只剩黑色 back buffer。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

test_focus_gain_replays_scanout() {
    # 中文注释：窗口从 minimized/hidden 回到前台时，不一定收到 RESTORED/SHOWN。
    # FOCUS_GAINED 是实际更稳定的恢复信号，必须主动 sdl2_redraw()。
    awk '
        /case SDL_WINDOWEVENT_FOCUS_GAINED:/ { in_case = 1 }
        in_case && /sdl2_redraw\(scon\)/ { saw_redraw = 1 }
        in_case && /break;/ { exit saw_redraw ? 0 : 1 }
    ' "$SDL2_C" || fail "SDL focus gained must replay current GL scanout"
}

test_display_resume_replays_scanout() {
    # 中文注释：QMP display-resume 会 show SDL 窗口；guest idle 时可能没有新
    # dpy_gl_update()，所以 resume hook 本身必须同步重绘当前 scanout。
    awk '
        /static void sdl2_set_paused/ { in_func = 1 }
        in_func && /SDL_ShowWindow\(scon->real_window\)/ { saw_show = 1 }
        in_func && saw_show && /graphic_hw_invalidate\(dcl->con\)/ {
            saw_invalidate = 1
        }
        in_func && saw_show && /sdl2_redraw\(scon\)/ { saw_redraw = 1 }
        in_func && /^}/ {
            exit saw_show && saw_invalidate && saw_redraw ? 0 : 1
        }
    ' "$SDL2_C" || fail "SDL display-resume must redraw the current GL scanout"
}

test_focus_gain_replays_scanout
test_display_resume_replays_scanout

echo "OK: SDL GL black-screen static checks passed"
