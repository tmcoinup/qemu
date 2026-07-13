#!/usr/bin/env bash
# 静态验证 SDL/GL scanout 的恢复重绘路径，避免窗口隐藏/恢复后只剩黑色 back buffer。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
SDL2_EGL_C="$REPO_ROOT/ui/sdl2-egl.c"
SV_DEVICES="$REPO_ROOT/deploy/scripts/lib/sv-devices.sh"
SV_ASSEMBLE="$REPO_ROOT/deploy/scripts/lib/sv-assemble.sh"

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

test_qemu11_sdl_egl_replaces_private_hook() {
    # 中文注释：QEMU 11 已在 SDL backend 内探测 X11 EGL 并设置官方 SDL hint；
    # 启动器只应传标准 display 参数，不能再维护环境变量控制的私有子窗口。
    grep -F -- "sdl2_gl_provider_prepare(o->gl);" "$SDL2_C" >/dev/null \
        || fail "QEMU 11 SDL backend must run its EGL capability probe"
    grep -F -- 'DISP_ARGS+=(-display sdl,gl=on,show-cursor=off)' "$SV_DEVICES" >/dev/null \
        || fail "launcher must use the official SDL/GL display option"
    if grep -F -- "SDL_NATIVE_EGL" "$SV_DEVICES" "$SV_ASSEMBLE" >/dev/null; then
        fail "launcher still contains the private SDL native-EGL hook"
    fi
}

test_x11_egl_failure_falls_back_before_shader() {
    # 中文注释：provider 探测已经拆到独立文件，并覆盖 eglInitialize、API 绑定
    # 与 window config。窗口/context 真正创建失败后仍须 override 环境 hint、
    # 重试 GLX；两次都失败则在 shader 初始化前明确退出。
    grep -F -- "bool sdl2_gl_provider_retry_native(void)" "$SDL2_EGL_C" \
        >/dev/null || fail "SDL must provide an EGL fallback gate"
    grep -F -- "SDL_HINT_OVERRIDE" "$SDL2_EGL_C" >/dev/null \
        || fail "SDL EGL fallback must override an explicit environment hint"
    grep -F -- "falling back to %s" "$SDL2_C" >/dev/null \
        || fail "SDL EGL fallback must report the selected native provider"
    grep -F -- "SDL2_GL_PROVIDER_EGL_COMMITTED" "$SDL2_EGL_C" >/dev/null \
        || fail "SDL must not mix EGL and GLX providers across consoles"
    grep -F -- "if (sdl2_window_create_once(scon, flags, &first_error))" \
        "$SDL2_C" >/dev/null \
        || fail "SDL must validate window/context creation before returning"
    grep -F -- "exit(1);" "$SDL2_C" >/dev/null \
        || fail "SDL must stop before shader initialization when all providers fail"
}

test_focus_gain_replays_scanout
test_display_resume_replays_scanout
test_qemu11_sdl_egl_replaces_private_hook
test_x11_egl_failure_falls_back_before_shader

echo "OK: SDL GL black-screen static checks passed"
