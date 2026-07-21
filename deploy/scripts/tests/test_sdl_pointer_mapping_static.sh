#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 验证 SDL 绝对指针无抓取模式与坐标转换契约。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
SDL2_INPUT_C="$REPO_ROOT/ui/sdl2-input.c"
SDL2_H="$REPO_ROOT/include/ui/sdl2.h"
INPUT_C="$REPO_ROOT/ui/input.c"
INPUT_H="$REPO_ROOT/include/ui/input.h"
POINTER_C="$REPO_ROOT/ui/sdl2-pointer.c"
POINTER_H="$REPO_ROOT/include/ui/sdl2-pointer.h"
POINTER_TEST="$REPO_ROOT/tests/unit/test-sdl2-pointer.c"
UI_MESON="$REPO_ROOT/ui/meson.build"
UNIT_MESON="$REPO_ROOT/tests/unit/meson.build"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1"
    local file="$2"

    grep -F -- "$needle" "$file" >/dev/null \
        || fail "missing '$needle' in $file"
}

reject_text() {
    local needle="$1"
    local file="$2"

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $file"
    fi
}

test_geometry_helper_is_small_and_built() {
    [[ -f "$POINTER_C" && -f "$POINTER_H" && -f "$POINTER_TEST" ]] \
        || fail "SDL pointer helper or unit test is missing"
    (( $(wc -l < "$POINTER_C") <= 500 )) \
        || fail "ui/sdl2-pointer.c exceeds 500 lines"
    (( $(wc -l < "$POINTER_H") <= 500 )) \
        || fail "include/ui/sdl2-pointer.h exceeds 500 lines"
    (( $(wc -l < "$POINTER_TEST") <= 500 )) \
        || fail "tests/unit/test-sdl2-pointer.c exceeds 500 lines"
    require_text "'sdl2-pointer.c'," "$UI_MESON"
    require_text "'test-sdl2-pointer': [" "$UNIT_MESON"
}

test_windowed_absolute_pointer_never_auto_grabs() {
    # USB Tablet 已经提供绝对坐标。
    # 窗口边缘自动解除、内侧自动重抓，
    # 会在 XWayland pointer constraint
    # 切换时制造错误 warp，必须彻底移除。
    reject_text "absolute_mouse_grab" "$SDL2_C"
    awk '
        /static void handle_mousemotion/ { in_func = 1 }
        in_func && /sdl_grab_start|sdl_grab_end/ { exit 1 }
        in_func && /^}/ { exit 0 }
        END { if (!in_func) { exit 1 } }
    ' "$SDL2_C" || fail "mouse motion must not toggle SDL grab at window edges"
    require_text "sdl_active_cursor_owner" "$SDL2_C"
    require_text "!grabbed_scon->hidden && grabbed_scon->has_input_focus" \
        "$SDL2_C"
}

test_absolute_capability_survives_guest_handler_switches() {
    # Windows 冷启动或 OOBE 首次启用 USB HID 前，PS/2 可能仍是 current；
    # usb-tablet 已存在时，handler 的轮询顺序不能触发自动 mouse grab。
    require_text "bool qemu_input_has_absolute(QemuConsole *con);" "$INPUT_H"
    require_text "bool qemu_input_has_absolute(QemuConsole *con)" "$INPUT_C"
    require_text "qemu_input_has_absolute(scon->dcl.con)" "$SDL2_C"
    require_text "bool absolute_available;" "$SDL2_H"
    require_text "sdl2_pointer_policy(" "$POINTER_C"
    require_text "test_pointer_policy_before_tablet_activation" "$POINTER_TEST"

    awk '
        /static void handle_mousemotion/ { in_func = 1 }
        in_func && /sdl2_pointer_policy\(/ { found = 1 }
        in_func && /^}/ { exit found ? 0 : 1 }
        END { if (!in_func || !found) { exit 1 } }
    ' "$SDL2_C" \
        || fail "tablet-capable consoles must forward transient relative motion"

    awk '
        /static void handle_mousebutton/ { in_func = 1 }
        in_func && /policy.auto_grab_on_click/ { found = 1 }
        in_func && /^}/ { exit found ? 0 : 1 }
        END { if (!in_func || !found) { exit 1 } }
    ' "$SDL2_C" \
        || fail "tablet-capable consoles must not auto-grab on click"
}

test_relative_mode_is_explicitly_released() {
    # SDL relative mode 是进程级约束；只清 WindowMouseGrab 无法保证释放。
    require_text \
        "SDL_SetRelativeMouseMode(policy.relative_mode ? SDL_TRUE : SDL_FALSE);" \
        "$SDL2_C"
}

test_coordinates_are_mapped_exactly_once() {
    # SDL handler 只转交原始 logical-window pixels。
    # 统一链路先转换到 renderer/drawable，
    # 再按同一目标矩形映射到 guest。
    require_text "ev->motion.xrel, ev->motion.yrel" "$SDL2_C"
    require_text "ev->motion.x, ev->motion.y" "$SDL2_C"
    require_text "sdl2_map_point(window, render" "$SDL2_C"
    require_text "sdl2_window_to_guest(dst, guest" "$SDL2_C"
    require_text "sdl2_guest_to_window(" "$SDL2_C"
    require_text "sdl2_guest_dst_rect(*render, *guest)" "$SDL2_C"
    require_text "sdl2_current_render_size(scon, render)" "$SDL2_C"
    require_text "SDL_GL_GetDrawableSize" "$SDL2_H"
    require_text "sdl2_guest_dst_rect(" "$REPO_ROOT/ui/sdl2-2d.c"
    require_text "sdl2_guest_dst_rect(" "$REPO_ROOT/ui/sdl2-gl.c"
    require_text "sdl2_current_guest_size(scon, &guest)" \
        "$REPO_ROOT/ui/sdl2-gl.c"
    reject_text "ev->motion.x * surf_w" "$SDL2_C"
    reject_text "bev->x * surface_width" "$SDL2_C"
    reject_text "SDL_WarpMouseInWindow(scon->real_window, guest_x" "$SDL2_C"
}

test_button_state_is_per_console_and_released() {
    require_text "uint32_t mouse_button_state;" "$SDL2_H"
    require_text "scon->mouse_button_state" "$SDL2_C"
    require_text "sdl_release_mouse_buttons(scon);" "$SDL2_C"
    reject_text "static uint32_t prev_state" "$SDL2_C"
    reject_text "SDL_GetMouseState(NULL, NULL)" "$SDL2_C"
    reject_text "ev->motion.state" "$SDL2_C"
}

test_console_state_is_not_global() {
    require_text "bool absolute_enabled;" "$SDL2_H"
    require_text "bool guest_cursor;" "$SDL2_H"
    require_text "struct sdl2_console *grabbed_scon;" "$SDL2_C"
    require_text "grabbed_scon == scon" "$SDL2_C"
    require_text "SDL_Window *window = SDL_GetWindowFromID(window_id);" \
        "$SDL2_C"
    require_text "return scon && scon->real_window &&" "$SDL2_INPUT_C"
    reject_text "static int absolute_enabled" "$SDL2_C"
    reject_text "static bool guest_cursor" "$SDL2_C"
}

test_hidden_window_closes_input_state() {
    require_text "sdl_deactivate_window(scon, true, true);" "$SDL2_C"
    require_text "sdl_deactivate_window(target, true, true);" "$SDL2_C"
    require_text "sdl_refresh_window_focus(scon);" "$SDL2_C"
}

test_scanout_uses_visible_subrectangle() {
    require_text "scanout.width = scon->w;" "$SDL2_H"
    require_text "scanout.height = scon->h;" "$SDL2_H"
    require_text "sdl2_gl_blit_scanout" "$REPO_ROOT/ui/sdl2-gl.c"
    require_text "sdl2_gl_scanout_source_rect" "$REPO_ROOT/ui/sdl2-gl.c"
    require_text "glBlitFramebuffer" "$REPO_ROOT/ui/sdl2-gl.c"
}

test_geometry_helper_is_small_and_built
test_windowed_absolute_pointer_never_auto_grabs
test_absolute_capability_survives_guest_handler_switches
test_relative_mode_is_explicitly_released
test_coordinates_are_mapped_exactly_once
test_button_state_is_per_console_and_released
test_console_state_is_not_global
test_hidden_window_closes_input_state
test_scanout_uses_visible_subrectangle

echo "OK: SDL pointer mapping static checks passed"
