#!/usr/bin/env bash
# Guard the SDL/XWayland keyboard, compositor-shortcut and cursor fixes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
SDL2_EVENT_C="$REPO_ROOT/ui/sdl2-event.c"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Keyboard input follows keyboard focus only.  Requiring mouse-enter here
# breaks focused XWayland windows when Mutter omits the ENTER event.
awk '
    /static bool sdl2_keyboard_input_allowed/ { in_func = 1 }
    in_func && /has_input_focus/ { saw_focus = 1 }
    in_func && /has_mouse_focus/ { saw_mouse = 1 }
    in_func && /^}/ { exit saw_focus && !saw_mouse ? 0 : 1 }
' "$SDL2_C" || fail "keyboard gate must not depend on mouse focus"

grep -Fq 'sdl2_pointer_input_allowed(scon)' "$SDL2_C" \
    || fail "pointer handlers lost their separate focus gate"
grep -Fq 'sdl2_gnome_guard_update(scon)' "$SDL2_C" \
    || fail "SDL window events no longer update the GNOME shortcut guard"
grep -Fq 'g_spawn_async(NULL, argv' "$SDL2_C" \
    || fail "GNOME shortcut helper is not dispatched asynchronously"
if grep -Fq 'g_spawn_sync' "$SDL2_C"; then
    fail "focus/input events can still block on the GNOME shortcut helper"
fi
grep -Fq 'sdl2_gnome_guard_timeout' "$SDL2_C" \
    || fail "a hung GNOME shortcut helper is not bounded"
grep -Fq '#define SDL2_EVENT_POLL_MAX 1024' "$SDL2_C" \
    || fail "SDL event storms are not bounded by a batch limit"
grep -Fq '#define SDL2_EVENT_POLL_BUDGET_US 2000' "$SDL2_C" \
    || fail "SDL event storms are not bounded by a time budget"
grep -Fq 'consumed < max_events' "$SDL2_EVENT_C" \
    || fail "mouse coalescing can bypass the SDL event count budget"
grep -Fq 'g_get_monotonic_time() >= deadline_us' "$SDL2_EVENT_C" \
    || fail "mouse coalescing can bypass the SDL event time budget"
grep -Fq 'SDL_Window *window = SDL_GetWindowFromID(window_id);' "$SDL2_C" \
    || fail "stale SDL window IDs are not resolved safely"
grep -Fq 'if (!window)' "$SDL2_C" \
    || fail "destroyed SDL windows can still receive stale events"

# Losing visibility or pausing the display must release guest key state even
# when a window manager drops the corresponding KEYUP event.
awk '
    /^static void sdl2_deactivate_input\(struct sdl2_console \*scon\)$/ {
        getline
        if ($0 == "{") { in_func = 1 }
        next
    }
    in_func && /sdl2_release_modifiers\(scon\)/ { found = 1 }
    in_func && /^}/ { exit found ? 0 : 1 }
' "$SDL2_C" || fail "SDL input deactivation no longer releases held keys"
for event in MINIMIZED HIDDEN; do
    awk -v marker="case SDL_WINDOWEVENT_${event}:" '
        index($0, marker) { in_case = 1; next }
        in_case && /sdl2_deactivate_input\(scon\)/ { found = 1 }
        in_case && /break;/ { exit found ? 0 : 1 }
        END { if (!in_case) exit 1 }
    ' "$SDL2_C" || fail "${event} no longer releases held guest keys"
done
awk '
    /case SDL_WINDOWEVENT_LEAVE:/ { in_case = 1; next }
    in_case && /sdl2_release_modifiers\(scon\)/ { bad = 1 }
    in_case && /break;/ { exit bad ? 1 : 0 }
' "$SDL2_C" || fail "pointer LEAVE incorrectly releases focused guest keys"
grep -Fq 'sdl2_create_windows_cursor' "$SDL2_C" \
    || fail "REGION display lost its Windows-style fallback cursor"
grep -Fq 'case SDL_SCANCODE_C:' "$SDL2_C" \
    || fail "SDL lost the Ctrl-Alt-C cursor-policy toggle"
grep -Fq 'QEMU_SDL_CURSOR_MODE' "$SDL2_C" \
    || fail "SDL lost its explicit auto/host/guest cursor policy"
grep -Fq 'expected host, guest or auto); using host' "$SDL2_C" \
    || fail "invalid SDL cursor policy no longer fails safe to host"
grep -Fq 'Cursor: auto' "$SDL2_C" \
    || fail "SDL title no longer identifies framebuffer-confirmed auto mode"
grep -Fq 'Cursor: guest-only (guest sprite)' "$SDL2_C" \
    || fail "SDL title no longer identifies authoritative guest sprites"
grep -Fq 'Cursor: guest unavailable (host fallback)' "$SDL2_C" \
    || fail "SDL title no longer identifies the safe host fallback"
grep -Fq 'static void sdl_apply_active_cursor' "$SDL2_C" \
    || fail "SDL cursor policies are no longer centralized"
grep -Fq 'if (scon->guest_cursor && scon->guest_sprite)' "$SDL2_C" \
    || fail "authoritative guest cursor sprite lost priority"
if grep -Fq 'if (sdl2_guest_cursor_mode && absolute)' "$SDL2_C"; then
    fail "guest mode still assumes a framebuffer cursor"
fi
awk '
    /static void sdl_apply_active_cursor/ { in_func = 1 }
    in_func && /if \(scon->guest_cursor && scon->guest_sprite\)/ {
        guest_sprite = NR
    }
    in_func && /if \(absolute\)/ {
        host_fallback = NR
    }
    in_func && /^}/ {
        exit guest_sprite && host_fallback &&
             guest_sprite < host_fallback ? 0 : 1
    }
' "$SDL2_C" || fail "authoritative guest cursor lacks priority"
for cursor_failure in \
        'Failed to make rgb surface' \
        'Failed to make color cursor'; do
    failure_reason="cursor creation lacks host fallback: $cursor_failure"
    awk -v marker="$cursor_failure" '
        index($0, marker) { in_path = 1; next }
        in_path && /sdl_apply_active_cursor\(scon\)/ { fallback = 1 }
        in_path && /return;/ { exit fallback ? 0 : 1 }
        END { if (!in_path) exit 1 }
    ' "$SDL2_C" || fail "$failure_reason"
done
grep -Fq 'SDL_ShowCursor(SDL_DISABLE);' "$SDL2_C" \
    || fail "relative grab no longer hides the unconstrained host cursor"
grep -Fq 'sdl_apply_active_cursor(scon);' "$SDL2_C" \
    || fail "SDL active cursor policy is not applied by cursor event paths"
grep -Fq 'QEMU_SDL_CURSOR_MODE="${QEMU_SDL_CURSOR_MODE:-host}"' "$START_VM" \
    || fail "G-11 launcher no longer defaults cursor policy to responsive host"
grep -Fq -- '--guest-cursor) QEMU_SDL_CURSOR_MODE=guest' "$START_VM" \
    || fail "native launcher lost --guest-cursor"
grep -Fq -- '--auto-cursor) QEMU_SDL_CURSOR_MODE=auto' "$START_VM" \
    || fail "native launcher lost --auto-cursor"
grep -Fq -- '--host-cursor) QEMU_SDL_CURSOR_MODE=host' "$START_VM" \
    || fail "native launcher lost --host-cursor"
grep -Fq 'export QEMU_SDL_CURSOR_MODE' "$START_VM" \
    || fail "native launcher no longer exports cursor policy to SDL"
grep -Fq \
    'guest sprite 优先；不可用时自动保留 host fallback' "$START_VM" \
    || fail "native launcher no longer documents the safe guest fallback"
grep -Fq \
    '仅确认 REGION 已合成拖窗箭头时隐藏 host fallback' "$START_VM" \
    || fail "native launcher no longer documents confirmed auto hiding"
grep -Fq \
    '始终使用 host fallback（默认，跟手优先）' "$START_VM" \
    || fail "native launcher no longer documents the responsive host default"
if grep -Fq 'guest-only（已确认 guest 光标可用' "$START_VM"; then
    fail "native launcher still claims an unverified framebuffer cursor"
fi
for event in FOCUS_LOST LEAVE MINIMIZED HIDDEN; do
    awk -v marker="case SDL_WINDOWEVENT_${event}:" '
        index($0, marker) { in_case = 1; next }
        in_case && /sdl_show_cursor\(scon\)/ { found = 1 }
        in_case && /break;/ { exit found ? 0 : 1 }
        END { if (!in_case) exit 1 }
    ' "$SDL2_C" || fail "${event} no longer restores the host cursor"
done
awk '
    /static void sdl2_set_paused/ { in_func = 1 }
    in_func && /if \(paused\)/ { in_pause = 1 }
    in_pause && /sdl_show_cursor\(scon\)/ { found = 1 }
    in_func && /^}/ { exit found ? 0 : 1 }
' "$SDL2_C" || fail "display pause no longer restores the host cursor"
grep -Fq 'export QEMU_SDL_TAME_GNOME=1' "$START_VM" \
    || fail "native SDL launcher no longer enables the shortcut guard"
if grep -Fq 'sdl,gl=on,show-cursor=on' "$START_VM"; then
    fail "native SDL still forces the Ubuntu host cursor"
fi

echo "OK: SDL native keyboard/shortcut/cursor static checks passed"
