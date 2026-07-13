#!/usr/bin/env bash
# 静态验证 SDL OpenGL provider 的跨平台选择、
# 状态提交和原生回退路径。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
SDL2_GL_C="$REPO_ROOT/ui/sdl2-gl.c"
SDL2_EGL_C="$REPO_ROOT/ui/sdl2-egl.c"
SDL2_EGL_H="$REPO_ROOT/ui/sdl2-egl.h"
UI_MESON="$REPO_ROOT/ui/meson.build"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local pattern="$1"
    local file="$2"
    local message="$3"

    grep -F -- "$pattern" "$file" >/dev/null || fail "$message"
}

test_provider_is_split_and_built() {
    # 中文注释：provider 状态机必须独立于既有超长 sdl2.c，
    # 并由 OpenGL 条件构建。独立实现也遵守项目新增单文件
    # 不超过 500 行的约束。
    [[ -f "$SDL2_EGL_C" && -f "$SDL2_EGL_H" ]] \
        || fail "SDL EGL provider source/header is missing"
    require_text "'sdl2-egl.c'," "$UI_MESON" \
        "SDL EGL provider is not registered in ui/meson.build"
    (( $(wc -l < "$SDL2_EGL_C") <= 500 )) \
        || fail "ui/sdl2-egl.c exceeds 500 lines"
}

test_window_attributes_are_configured_early() {
    local configure_line
    local create_line

    # 中文注释：SDL 在 SDL_CreateWindow 内选择
    # EGLConfig/GLXFBConfig，所以 profile/version 必须在窗口
    # 创建之前配置，而不是等到 CreateContext。
    configure_line="$(grep -n -m1 'sdl2_gl_provider_configure_window' \
        "$SDL2_C" | cut -d: -f1)"
    create_line="$(grep -n -m1 'scon->real_window = SDL_CreateWindow' \
        "$SDL2_C" | cut -d: -f1)"
    [[ -n "$configure_line" && -n "$create_line" ]] \
        || fail "cannot locate SDL provider/window initialization"
    (( configure_line < create_line )) \
        || fail "SDL GL attributes must be set before SDL_CreateWindow"
}

test_x11_egl_probe_and_nvidia_workaround() {
    # 中文注释：X11 EGL 候选必须经过完整初始化、
    # API 绑定和 WINDOW config 探测。NVIDIA 仅在发布有问题的
    # present_opaque 扩展时才按 SDL 机制屏蔽。
    require_text "eglInitialize(egl_display" "$SDL2_EGL_C" \
        "X11 EGL probe must initialize the display"
    require_text "eglBindAPI(api)" "$SDL2_EGL_C" \
        "X11 EGL probe must bind the requested GL API"
    require_text "EGL_SURFACE_TYPE, EGL_WINDOW_BIT" "$SDL2_EGL_C" \
        "X11 EGL probe must require a window config"
    require_text 'g_str_has_prefix(vendor, "NVIDIA")' "$SDL2_EGL_C" \
        "NVIDIA workaround must be vendor-scoped"
    require_text 'SDL2_EGL_PRESENT_OPAQUE_EXT' "$SDL2_EGL_C" \
        "NVIDIA present_opaque workaround is missing"
    require_text 'g_setenv(SDL2_EGL_PRESENT_OPAQUE_EXT, "1", false)' \
        "$SDL2_EGL_C" "SDL extension mask must preserve user overrides"
}

test_provider_commit_and_native_fallback() {
    # 中文注释：首个成功 context 后，
    # provider 成为进程级已提交状态；
    # 首次 EGL 失败则用高优先级 hint 撤销，
    # 并只重试一次平台原生 GL provider。
    require_text "SDL2_GL_PROVIDER_EGL_COMMITTED" "$SDL2_EGL_C" \
        "EGL committed state is missing"
    require_text "SDL2_GL_PROVIDER_NATIVE_COMMITTED" "$SDL2_EGL_C" \
        "native committed state is missing"
    require_text "SDL_HINT_OVERRIDE" "$SDL2_EGL_C" \
        "native fallback must override environment hints"
    require_text "sdl2_gl_provider_egl_committed()" "$SDL2_C" \
        "window lifecycle must enforce the committed provider"
    require_text "sdl2_gl_provider_native_name()" "$SDL2_C" \
        "fallback diagnostics must name GLX/WGL"
    require_text 'info_report("SDL: EGL provider active' "$SDL2_EGL_C" \
        "successful EGL commit must produce a one-time diagnostic"
}

test_windows_angle_and_wgl_paths() {
    # 中文注释：Windows gl=on/es 先要求 SDL 的
    # EGL/ANGLE GLES provider；
    # 成功后读取当前 EGLDisplay 与 ANGLE D3D11 device，
    # 失败则撤销 hint 回退 WGL。
    require_text "SDL_HINT_OPENGL_ES_DRIVER" "$SDL2_EGL_C" \
        "Windows ANGLE preference hint is missing"
    require_text "EGL_D3D11_DEVICE_ANGLE" "$SDL2_EGL_C" \
        "Windows ANGLE D3D11 device query is missing"
    require_text "qemu_egl_angle_d3d" "$SDL2_EGL_C" \
        "Windows ANGLE capability state is not updated"
    require_text "qemu_egl_mode = sdl2_windows_angle_preferred" "$SDL2_EGL_C" \
        "Windows gl=on must remain GLES after ANGLE selection"
    require_text 'ANGLE D3D11=%s' "$SDL2_EGL_C" \
        "Windows EGL diagnostic must report ANGLE D3D11 availability"
    require_text "sdl2_gl_provider_uses_gles()" "$SDL2_GL_C" \
        "shared virgl contexts must keep the committed GLES API"
    require_text 'return "WGL";' "$SDL2_EGL_C" \
        "Windows native fallback must identify WGL"
}

test_provider_is_split_and_built
test_window_attributes_are_configured_early
test_x11_egl_probe_and_nvidia_workaround
test_provider_commit_and_native_fallback
test_windows_angle_and_wgl_paths

echo "OK: SDL EGL provider static checks passed"
