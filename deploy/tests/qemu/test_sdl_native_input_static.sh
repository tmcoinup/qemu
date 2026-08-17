#!/usr/bin/env bash
# Guard the SDL/XWayland keyboard, compositor-shortcut and cursor fixes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
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
grep -Fq 'sdl2_create_windows_cursor' "$SDL2_C" \
    || fail "REGION display lost its Windows-style fallback cursor"
grep -Fq 'case SDL_SCANCODE_C:' "$SDL2_C" \
    || fail "SDL lost the Ctrl-Alt-C framebuffer cursor toggle"
grep -Fq 'Cursor: framebuffer (host hidden)' "$SDL2_C" \
    || fail "SDL title no longer identifies framebuffer cursor mode"
grep -Fq 'static void sdl_apply_active_cursor' "$SDL2_C" \
    || fail "SDL cursor policies are no longer centralized"
grep -Fq 'if (sdl2_framebuffer_cursor)' "$SDL2_C" \
    || fail "framebuffer cursor mode no longer hides the fixed host arrow"
grep -Fq 'SDL_ShowCursor(SDL_DISABLE);' "$SDL2_C" \
    || fail "framebuffer cursor mode no longer disables the host cursor"
grep -Fq 'sdl_apply_active_cursor(scon);' "$SDL2_C" \
    || fail "SDL active cursor policy is not applied by cursor event paths"
grep -Fq 'export QEMU_SDL_TAME_GNOME=1' "$START_VM" \
    || fail "native SDL launcher no longer enables the shortcut guard"
if grep -Fq 'sdl,gl=on,show-cursor=on' "$START_VM"; then
    fail "native SDL still forces the Ubuntu host cursor"
fi

echo "OK: SDL native keyboard/shortcut/cursor static checks passed"
