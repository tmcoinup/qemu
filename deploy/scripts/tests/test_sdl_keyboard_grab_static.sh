#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 验证 SDL 键盘独占、宿主输入法隔离、鼠标自由出入与 XWayland 授权。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
SDL2_INPUT_C="$REPO_ROOT/ui/sdl2-input.c"
SDL2_X11_C="$REPO_ROOT/ui/sdl2-x11.c"
SDL2_X11_H="$REPO_ROOT/include/ui/sdl2-x11.h"
UI_MESON="$REPO_ROOT/ui/meson.build"

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

require_case_call() {
    local case_label="$1"
    local call="$2"

    awk -v case_label="$case_label" -v call="$call" '
        index($0, case_label) {
            in_case = 1
            found_case = 1
            next
        }
        in_case && index($0, call) {
            found_call = 1
            exit 0
        }
        in_case && /^[[:space:]]*case SDL_WINDOWEVENT_/ {
            exit 1
        }
        END {
            if (!found_case || !found_call) {
                exit 1
            }
        }
    ' "$SDL2_C" \
        || fail "$case_label must call $call before the next window event"
}

test_xwayland_helper_is_small_and_built() {
    [[ -f "$SDL2_INPUT_C" && -f "$SDL2_X11_C" && -f "$SDL2_X11_H" ]] \
        || fail "SDL input helper is missing"
    (( $(wc -l < "$SDL2_INPUT_C") <= 500 )) \
        || fail "ui/sdl2-input.c exceeds 500 lines"
    (( $(wc -l < "$SDL2_X11_C") <= 500 )) \
        || fail "ui/sdl2-x11.c exceeds 500 lines"
    (( $(wc -l < "$SDL2_X11_H") <= 500 )) \
        || fail "include/ui/sdl2-x11.h exceeds 500 lines"
    require_text "'sdl2-input.c'," "$UI_MESON"
    require_text "'sdl2-x11.c'," "$UI_MESON"
    require_text \
        "void sdl2_sync_text_input(struct sdl2_console *consoles," \
        "$REPO_ROOT/include/ui/sdl2.h"
    require_text "sdl_ss.add(when: x11" "$UI_MESON"
    awk '
        /sdl_ss\.add\(sdl, sdl_image, pixman, glib, files\(/ {
            in_common = 1
        }
        in_common && /'\''sdl2-x11\.c'\''/ {
            found = 1
        }
        in_common && /^[[:space:]]*\)\)$/ {
            exit !found
        }
        END {
            if (!in_common || !found) {
                exit 1
            }
        }
    ' "$UI_MESON" \
        || fail "sdl2-x11.c must provide its no-op stub on non-X11 builds"
}

test_mouse_and_keyboard_grabs_are_independent() {
    require_text "SDL_SetWindowMouseGrab(scon->real_window, grabbed);" "$SDL2_C"
    require_text "SDL_SetWindowKeyboardGrab(scon->real_window," "$SDL2_C"
    require_text \
        "needs_regrab = SDL_GetWindowKeyboardGrab(scon->real_window) != SDL_TRUE;" \
        "$SDL2_C"

    # SDL_SetWindowGrab 受 SDL_HINT_GRAB_KEYBOARD 影响，
    # 只允许作为旧 SDL 的编译期 fallback。
    # 实际 start/end 必须通过 mouse-only wrapper。
    (( $(grep -cF -- "SDL_SetWindowGrab(" "$SDL2_C") == 1 )) \
        || fail "legacy SDL_SetWindowGrab escaped its compatibility fallback"
    require_text "sdl_set_mouse_grab(scon, SDL_TRUE);" "$SDL2_C"
    require_text "sdl_set_mouse_grab(scon, SDL_FALSE);" "$SDL2_C"
}

test_keyboard_grab_follows_window_ownership() {
    require_text "bool should_grab = sdl2_input_allowed(scon) &&" "$SDL2_C"
    require_text "scon->has_input_focus && scon->has_mouse_focus" \
        "$SDL2_INPUT_C"
    require_text "sdl_sync_keyboard_grab(scon);" "$SDL2_C"

    # 激活事件通过 refresh helper 获取 SDL 的真实 flags。
    # 失活事件通过 deactivate helper 统一抬键并释放 grab；
    # LEAVE 则直接同步。
    require_case_call "case SDL_WINDOWEVENT_FOCUS_GAINED:" \
        "sdl_refresh_window_focus(scon);"
    require_case_call "case SDL_WINDOWEVENT_RESTORED:" \
        "sdl_refresh_window_focus(scon);"
    require_case_call "case SDL_WINDOWEVENT_SHOWN:" \
        "sdl_refresh_window_focus(scon);"
    awk '
        /static void sdl_refresh_window_focus/ { in_func = 1 }
        in_func && /sdl_sync_keyboard_grab\(scon\)/ { found = 1 }
        in_func && /^}/ { exit found ? 0 : 1 }
        END { if (!in_func || !found) { exit 1 } }
    ' "$SDL2_C" \
        || fail "focus refresh must synchronize the keyboard grab"
    awk '
        /static void sdl_refresh_window_focus/ { in_func = 1 }
        in_func && /scon->fullscreen.*scon->has_input_focus/ {
            saw_fullscreen_request = 1
        }
        in_func && saw_fullscreen_request && /sdl_grab_start\(scon\)/ {
            restored = 1
        }
        in_func && /^}/ { exit restored ? 0 : 1 }
        END {
            if (!in_func || !restored) {
                exit 1
            }
        }
    ' "$SDL2_C" \
        || fail "focused fullscreen windows must restore their mouse grab"
    require_case_call "case SDL_WINDOWEVENT_ENTER:" \
        "sdl_sync_keyboard_grab(scon);"
    require_case_call "case SDL_WINDOWEVENT_FOCUS_LOST:" \
        "sdl_deactivate_window(scon,"
    require_case_call "case SDL_WINDOWEVENT_LEAVE:" \
        "sdl_sync_keyboard_grab(scon);"
    require_case_call "case SDL_WINDOWEVENT_MINIMIZED:" \
        "sdl_deactivate_window(scon,"
    require_case_call "case SDL_WINDOWEVENT_HIDDEN:" \
        "sdl_deactivate_window(scon,"
    awk '
        /^static void sdl_deactivate_window/ {
            saw_signature = 1
            next
        }
        saw_signature && /;/ {
            saw_signature = 0
            next
        }
        saw_signature && /^[[:space:]]*\{/ {
            in_func = 1
            saw_signature = 0
        }
        in_func && /sdl_sync_keyboard_grab\(scon\)/ { found = 1 }
        in_func && /^}/ { exit found ? 0 : 1 }
        END { if (!in_func || !found) { exit 1 } }
    ' "$SDL2_C" \
        || fail "window deactivation must release the keyboard grab"
    awk '
        /void sdl2_window_destroy/ { in_func = 1 }
        in_func && /sdl_deactivate_window\(scon, true, false\)/ { found = 1 }
        in_func && /^}/ { exit found ? 0 : 1 }
        END { if (!in_func || !found) { exit 1 } }
    ' "$SDL2_C" \
        || fail "window destruction must deactivate input before destroy"
    awk '
        /static void sdl2_set_paused/ { in_func = 1 }
        in_func && /sdl_deactivate_window\(scon, true, true\)/ { found = 1 }
        in_func && /SDL_ShowWindow\(scon->real_window\)/ { shown = 1 }
        in_func && shown && /sdl_refresh_window_focus\(scon\)/ { exit 1 }
        in_func && /^}/ { exit found ? 0 : 1 }
        END { if (!in_func || !found) { exit 1 } }
    ' "$SDL2_C" \
        || fail "display resume must wait for SDL focus events before grabbing"
    if grep -A2 -F "SDL_ShowWindow(" "$SDL2_C" |
            grep -F "sdl_refresh_window_focus(" >/dev/null; then
        fail "SDL_ShowWindow must not synchronously reuse stale focus flags"
    fi
}

test_xwayland_permission_precedes_keyboard_grab() {
    require_text "_XWAYLAND_MAY_GRAB_KEYBOARD" "$SDL2_X11_C"
    require_text "message.window = info.info.x11.window;" "$SDL2_X11_C"
    require_text "message.message_type = permission_atom;" "$SDL2_X11_C"
    require_text "message.format = 32;" "$SDL2_X11_C"
    require_text "message.data.l[0] = 1;" "$SDL2_X11_C"
    require_text "DefaultRootWindow(info.info.x11.display)" "$SDL2_X11_C"
    require_text "SubstructureNotifyMask | SubstructureRedirectMask" \
        "$SDL2_X11_C"

    awk '
        /static void sdl_sync_keyboard_grab/ && $0 !~ /;[[:space:]]*$/ {
            in_func = 1
        }
        in_func &&
            /needs_regrab = SDL_GetWindowKeyboardGrab\(scon->real_window\)/ {
            getter_assignment = NR
        }
        in_func && /for \(i = 0; i < sdl2_num_outputs; i\+\+\)/ {
            saw_all_windows = 1
        }
        in_func && saw_all_windows &&
            /other_flags & SDL_WINDOW_KEYBOARD_GRABBED/ {
            keyboard_flag = NR
            in_keyboard_branch = 1
        }
        in_keyboard_branch &&
            /SDL_SetWindowKeyboardGrab\(other->real_window, SDL_FALSE\)/ {
            clear_other_keyboard = NR
        }
        in_keyboard_branch && /needs_regrab = true/ {
            keyboard_forces_regrab = NR
            in_keyboard_branch = 0
        }
        in_func && saw_all_windows &&
            /other_flags & SDL_WINDOW_MOUSE_GRABBED/ {
            mouse_flag = NR
            in_mouse_branch = 1
        }
        in_mouse_branch && /sdl_grab_end\(other\)/ {
            clear_owned_mouse = NR
        }
        in_mouse_branch && /sdl_set_mouse_grab\(other, SDL_FALSE\)/ {
            clear_stale_mouse = NR
        }
        in_mouse_branch && /needs_regrab = true/ {
            mouse_forces_regrab = NR
            in_mouse_branch = 0
        }
        in_func &&
            /SDL_SetWindowKeyboardGrab\(scon->real_window, SDL_FALSE\)/ {
            clear_current = NR
        }
        in_func && /sdl2_x11_request_keyboard_grab_permission/ {
            permission = NR
        }
        in_func &&
            /SDL_SetWindowKeyboardGrab\(scon->real_window, SDL_TRUE\)/ {
            grab = NR
        }
        in_func && /^}/ {
            exit !(getter_assignment && keyboard_flag &&
                   clear_other_keyboard && keyboard_forces_regrab &&
                   mouse_flag && clear_owned_mouse && clear_stale_mouse &&
                   mouse_forces_regrab && clear_current && permission && grab &&
                   getter_assignment < keyboard_flag &&
                   keyboard_flag < clear_other_keyboard &&
                   clear_other_keyboard < keyboard_forces_regrab &&
                   keyboard_forces_regrab < mouse_flag &&
                   mouse_flag < clear_owned_mouse &&
                   clear_owned_mouse < clear_stale_mouse &&
                   clear_stale_mouse < mouse_forces_regrab &&
                   mouse_forces_regrab < clear_current &&
                   clear_current < permission && permission < grab)
        }
        END {
            if (!in_func) {
                exit 1
            }
        }
    ' "$SDL2_C" \
        || fail \
            "stale keyboard/mouse requests must clear before permission"

    # getter 不暴露 SDL 在失焦后保留的请求 flag。
    # 释放分支必须无条件调用 Set(false)，
    # 避免下次得焦时 SDL 在 QEMU 状态机之前自动重抓。
    awk '
        /static void sdl_sync_keyboard_grab/ && $0 !~ /;[[:space:]]*$/ {
            in_func = 1
        }
        in_func && /if \(!should_grab\)/ { in_release = 1 }
        in_release &&
            /SDL_SetWindowKeyboardGrab\(scon->real_window, SDL_FALSE\)/ {
            cleared = 1
        }
        in_release && /return;/ {
            exit cleared ? 0 : 1
        }
        in_func && /^}/ { exit 1 }
        END {
            if (!in_func || !in_release || !cleared) {
                exit 1
            }
        }
    ' "$SDL2_C" \
        || fail "keyboard release must clear SDL's requested-grab flag"
}

test_host_ime_is_limited_to_text_consoles() {
    # SDL video 初始化会自动启动文本输入；QEMU 必须在创建窗口前先关闭，
    # 否则 IBus/Fcitx 可以吞掉图形 guest 的 KEYDOWN/KEYUP。
    awk '
        /if \(SDL_Init\(SDL_INIT_VIDEO\)\)/ { init_line = NR }
        init_line && /SDL_StopTextInput\(\)/ && !stop_line {
            stop_line = NR
        }
        /register_displaychangelistener/ && !register_line {
            register_line = NR
        }
        END {
            exit !(init_line && stop_line && register_line &&
                   init_line < stop_line && stop_line < register_line)
        }
    ' "$SDL2_C" \
        || fail "SDL text input must stop before any display listener"

    # SDL 文本输入是进程级状态。同步 helper 必须以实际键盘焦点窗口为 owner，
    # 且只允许处于 QEMU 输入门控内的 text console 开启宿主 IME。
    awk '
        /void sdl2_sync_text_input/ && $0 !~ /;/ {
            in_func = 1
        }
        in_func && /SDL_GetKeyboardFocus\(\)/ { focus = 1 }
        in_func && /consoles\[i\]\.real_window == focused_window/ {
            owner = 1
        }
        in_func && /sdl2_input_allowed\(owner\)/ { gate = 1 }
        in_func && /QEMU_IS_TEXT_CONSOLE\(owner->dcl.con\)/ { text = 1 }
        in_func && /SDL_IsTextInputActive\(\)/ { state = 1 }
        in_func && /SDL_StartTextInput\(\)/ { start = 1 }
        in_func && /SDL_StopTextInput\(\)/ { stop = 1 }
        in_func && /^}/ {
            exit !(focus && owner && gate && text && state && start && stop)
        }
        END {
            if (!in_func) {
                exit 1
            }
        }
    ' "$SDL2_INPUT_C" \
        || fail "text-input owner policy is incomplete"
    (( $(grep -cF -- "SDL_StartTextInput();" "$SDL2_INPUT_C") == 1 )) \
        || fail "SDL text input may only start inside its owner-sync helper"

    # 创建、激活和失活路径都必须同步进程级状态，避免多窗口切换留下旧 IME。
    awk '
        /static bool sdl2_window_create_once/ { in_func = 1 }
        in_func &&
            /sdl2_sync_text_input\(sdl2_console, sdl2_num_outputs\)/ {
            found = 1
        }
        in_func && /^}/ { exit found ? 0 : 1 }
        END { if (!in_func || !found) { exit 1 } }
    ' "$SDL2_C" \
        || fail "window creation must synchronize SDL text input"
    awk '
        /static void sdl_refresh_window_focus/ { in_func = 1 }
        in_func &&
            /sdl2_sync_text_input\(sdl2_console, sdl2_num_outputs\)/ {
            found = 1
        }
        in_func && /^}/ { exit found ? 0 : 1 }
        END { if (!in_func || !found) { exit 1 } }
    ' "$SDL2_C" \
        || fail "focus refresh must synchronize SDL text input"
    awk '
        /^static void sdl_deactivate_window/ {
            saw_signature = 1
            next
        }
        saw_signature && /;/ {
            saw_signature = 0
            next
        }
        saw_signature && /^[[:space:]]*\{/ {
            in_func = 1
            saw_signature = 0
        }
        in_func &&
            /sdl2_sync_text_input\(sdl2_console, sdl2_num_outputs\)/ {
            found = 1
        }
        in_func && /^}/ { exit found ? 0 : 1 }
        END { if (!in_func || !found) { exit 1 } }
    ' "$SDL2_C" \
        || fail "window deactivation must synchronize SDL text input"
    require_case_call "case SDL_WINDOWEVENT_ENTER:" \
        "sdl2_sync_text_input(sdl2_console, sdl2_num_outputs);"
    require_case_call "case SDL_WINDOWEVENT_LEAVE:" \
        "sdl2_sync_text_input(sdl2_console, sdl2_num_outputs);"

    # SDL_TEXTINPUT 仍只下发到 QEMU text console，图形 guest 始终走 scancode。
    awk '
        /static void handle_textinput/ { in_func = 1 }
        in_func && /QEMU_IS_TEXT_CONSOLE\(con\)/ { guarded = 1 }
        in_func && /qemu_text_console_put_string/ { sent = 1 }
        in_func && /^}/ { exit !(guarded && sent) }
        END { if (!in_func || !guarded || !sent) { exit 1 } }
    ' "$SDL2_C" \
        || fail "SDL text events must remain limited to QEMU text consoles"
}

test_xwayland_helper_is_small_and_built
test_mouse_and_keyboard_grabs_are_independent
test_keyboard_grab_follows_window_ownership
test_xwayland_permission_precedes_keyboard_grab
test_host_ime_is_limited_to_text_consoles

echo "OK: SDL keyboard grab and host IME static checks passed"
