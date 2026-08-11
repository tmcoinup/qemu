#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 验证 SDL 绝对指针无抓取模式与坐标转换契约。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
SDL2_2D_C="$REPO_ROOT/ui/sdl2-2d.c"
SDL2_GL_C="$REPO_ROOT/ui/sdl2-gl.c"
SDL2_INPUT_C="$REPO_ROOT/ui/sdl2-input.c"
SDL2_EVENT_C="$REPO_ROOT/ui/sdl2-event.c"
SDL2_H="$REPO_ROOT/include/ui/sdl2.h"
INPUT_C="$REPO_ROOT/ui/input.c"
INPUT_H="$REPO_ROOT/include/ui/input.h"
POINTER_C="$REPO_ROOT/ui/sdl2-pointer.c"
POINTER_H="$REPO_ROOT/include/ui/sdl2-pointer.h"
POINTER_TEST="$REPO_ROOT/tests/unit/test-sdl2-pointer.c"
DISPLAY_POLICY_C="$REPO_ROOT/ui/sdl2-display-policy.c"
DISPLAY_POLICY_H="$REPO_ROOT/include/ui/sdl2-display-policy.h"
DISPLAY_POLICY_TEST="$REPO_ROOT/tests/unit/test-sdl2-display-policy.c"
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

test_native_display_policy_is_integrated() {
    local file

    for file in "$DISPLAY_POLICY_C" "$DISPLAY_POLICY_H" \
                "$DISPLAY_POLICY_TEST"; do
        [[ -f "$file" ]] || fail "SDL display policy file is missing: $file"
        (( $(wc -l < "$file") <= 500 )) \
            || fail "$file exceeds 500 lines"
    done

    require_text "'sdl2-display-policy.c'," "$UI_MESON"
    require_text "'test-sdl2-display-policy': [" "$UNIT_MESON"
    require_text "sdl2_select_window_mode(" "$SDL2_C"
    require_text "if (scon->idx == 0 &&" "$SDL2_C"
    require_text "SDL_WINDOW_ALLOW_HIGHDPI" "$SDL2_C"
    require_text "SDL_WINDOW_FULLSCREEN_DESKTOP" "$SDL2_C"
    require_text "SDL_HINT_WINDOWS_DPI_AWARENESS" "$SDL2_C"
    require_text "SDL2_ACTIVE_REFRESH_INTERVAL_MS" "$SDL2_C"

    (( $(grep -cF -- "scon->idx == 0 &&" "$SDL2_C") >= 2 )) \
        || fail "automatic fullscreen must stay on the primary console"
    awk '
        /flags \|= SDL_WINDOW_FULLSCREEN_DESKTOP/ { in_fullscreen_flags = 1 }
        in_fullscreen_flags && /if \(scon->auto_fullscreen\)/ {
            saw_auto_guard = 1
        }
        in_fullscreen_flags && saw_auto_guard &&
            /flags \|= SDL_WINDOW_RESIZABLE/ {
            found = 1
            exit
        }
        END { exit found ? 0 : 1 }
    ' "$SDL2_C" \
        || fail "automatic fullscreen must remain resizable after exit"

    awk '
        /void sdl2_window_destroy/ { in_func = 1 }
        in_func && /if \(reset_auto_fullscreen\)/ { saw_auto_guard = 1 }
        in_func && saw_auto_guard && /scon->fullscreen = false/ {
            cleared_fullscreen = 1
        }
        in_func && saw_auto_guard && /scon->auto_fullscreen = false/ {
            cleared_auto = 1
        }
        in_func && /^}/ {
            exit saw_auto_guard && cleared_fullscreen && cleared_auto ? 0 : 1
        }
        END {
            if (!in_func || !saw_auto_guard ||
                !cleared_fullscreen || !cleared_auto) {
                exit 1
            }
        }
    ' "$SDL2_C" \
        || fail "destroyed automatic fullscreen windows must recompute policy"

    # Windows DPI awareness 必须在 video subsystem 初始化前声明，
    # 否则第一扇 SDL 窗口仍可能被系统做整窗 bitmap scaling。
    awk '
        /SDL_SetHint\(SDL_HINT_WINDOWS_DPI_AWARENESS/ {
            saw_dpi_hint = 1
        }
        /SDL_Init\(SDL_INIT_VIDEO\)/ {
            exit saw_dpi_hint ? 0 : 1
        }
        END { if (!saw_dpi_hint) { exit 1 } }
    ' "$SDL2_C" || fail "SDL DPI awareness must be set before SDL_Init"
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

test_refresh_prioritizes_input_and_batches_2d_present() {
    # 两条 renderer 都必须在可能阻塞的显卡更新前泵取输入。
    for file in "$SDL2_2D_C" "$SDL2_GL_C"; do
        awk '
            /void sdl2_(2d|gl)_refresh/ { in_func = 1 }
            in_func && /sdl2_poll_events\(scon\)/ { saw_poll = 1 }
            in_func && /graphic_hw_update/ {
                exit saw_poll ? 0 : 1
            }
            in_func && /^}/ { exit 1 }
        ' "$file" || fail "SDL refresh must poll input before graphic update: $file"
    done

    # 一轮 graphic_hw_update 可产生多个 damage，software renderer 只能
    # 上传各 dirty rect 后统一做一次整窗 RenderCopy/Present。
    awk '
        /void sdl2_2d_update/ { in_func = 1 }
        in_func && /scon->updates\+\+/ { saw_batch = 1 }
        in_func && /sdl2_2d_present_texture/ { exit 1 }
        in_func && /^}/ { exit saw_batch ? 0 : 1 }
    ' "$SDL2_2D_C" || fail "2D damage callback must defer Present"
    awk '
        /void sdl2_2d_refresh/ { in_func = 1 }
        in_func && /sdl2_2d_present_texture/ { presents++ }
        in_func && /^}/ { exit presents == 1 ? 0 : 1 }
    ' "$SDL2_2D_C" || fail "2D refresh must batch damage into one Present"
}

test_input_pump_is_independent_from_display_refresh() {
    require_text "#define SDL2_INPUT_POLL_INTERVAL_ACTIVE 8" "$SDL2_C"
    require_text "#define SDL2_INPUT_POLL_INTERVAL_BACKGROUND 32" "$SDL2_C"
    require_text "#define SDL2_REFRESH_INTERVAL_MINIMIZED 100" "$SDL2_C"
    require_text "timer_new_ms(QEMU_CLOCK_REALTIME" "$SDL2_C"

    awk '
        /static void sdl2_input_timer_cb/ { in_func = 1 }
        in_func && /sdl2_poll_events/ { saw_poll = 1 }
        in_func && /graphic_hw_update|sdl2_flush_window_updates/ { exit 1 }
        in_func && /^}/ { exit saw_poll ? 0 : 1 }
    ' "$SDL2_C" || fail "independent SDL input timer must never render"
}

test_window_events_are_coalesced_and_keep_dpi_units() {
    require_text "bool window_redraw_pending;" "$SDL2_H"
    require_text "bool ui_info_pending;" "$SDL2_H"
    require_text "SDL_GetWindowSize(target->real_window, &width, &height)" \
        "$SDL2_C"
    require_text "scon->window_redraw_pending = true;" "$SDL2_C"
    require_text "sdl2_flush_window_updates();" "$SDL2_2D_C"
    require_text "sdl2_flush_window_updates();" "$SDL2_GL_C"
    require_text "sdl2_coalesce_mouse_motion(ev);" "$SDL2_C"
    require_text "SDL_PeepEvents(&next, 1, SDL_PEEKEVENT" "$SDL2_EVENT_C"
    require_text "'sdl2-event.c'," "$UI_MESON"
    require_text "'test-sdl2-event': [" "$UNIT_MESON"
    (( $(wc -l < "$SDL2_EVENT_C") <= 500 )) \
        || fail "ui/sdl2-event.c exceeds 500 lines"

    # 同步 close message box 前必须先释放 Guest held-key 状态。
    awk '
        /static bool sdl2_confirm_close/ { in_func = 1 }
        in_func && /sdl_deactivate_window/ { released = 1 }
        in_func && /SDL_ShowMessageBox/ { exit released ? 0 : 1 }
        in_func && /^}/ { exit 1 }
    ' "$SDL2_C" || fail "close confirmation must release guest input first"
}

test_geometry_helper_is_small_and_built
test_native_display_policy_is_integrated
test_windowed_absolute_pointer_never_auto_grabs
test_absolute_capability_survives_guest_handler_switches
test_relative_mode_is_explicitly_released
test_coordinates_are_mapped_exactly_once
test_button_state_is_per_console_and_released
test_console_state_is_not_global
test_hidden_window_closes_input_state
test_scanout_uses_visible_subrectangle
test_refresh_prioritizes_input_and_batches_2d_present
test_input_pump_is_independent_from_display_refresh
test_window_events_are_coalesced_and_keep_dpi_units

echo "OK: SDL pointer mapping static checks passed"
