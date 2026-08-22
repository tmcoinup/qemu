#!/usr/bin/env bash
# Guard the host-only REGION composited-cursor suppression contract.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
sdl2_c="$repo_root/ui/sdl2.c"
sdl2_2d="$repo_root/ui/sdl2-2d.c"
sdl2_gl="$repo_root/ui/sdl2-gl.c"
matcher="$repo_root/ui/sdl2-cursor.c"
header="$repo_root/include/ui/sdl2-cursor.h"
launcher="$repo_root/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$sdl2_c" "$sdl2_2d" "$sdl2_gl" "$matcher" "$header"; do
    [[ -f "$path" ]] || fail "missing cursor auto source: $path"
done

grep -Fq 'SDL2_CURSOR_MODE_AUTO' "$sdl2_c" \
    || fail "SDL auto cursor mode is missing"
grep -Fq 'sdl2_cursor_template_init_rgba' "$sdl2_c" \
    || fail "configured Windows cursor is not converted into a matcher template"
grep -Fq 'scon->mouse_button_state & SDL_BUTTON_LMASK' "$sdl2_c" \
    || fail "framebuffer matching is not gated by a held left button"
grep -Fq 'sdl2_cursor_history_record' "$sdl2_c" \
    || fail "mapped guest pointer positions are not timestamped"
grep -Fq 'surface_format(surface) != PIXMAN_x8r8g8b8' "$sdl2_c" \
    || fail "matcher is not restricted to its supported REGION pixel format"
grep -Fq 'SDL2_CURSOR_FRAME_MISS_LIMIT' "$sdl2_c" \
    || fail "auto cursor visibility has no bounded miss recovery"
grep -Fq 'sdl2_framebuffer_cursor_update(scon);' "$sdl2_2d" \
    || fail "2D surface updates do not run cursor confirmation"
grep -Fq 'sdl2_framebuffer_cursor_update(scon);' "$sdl2_gl" \
    || fail "GL surface updates do not run cursor confirmation"
grep -Fq 'sdl2_framebuffer_cursor_reset(scon);' "$sdl2_gl" \
    || fail "GL surface/scanout transitions can leave the host cursor hidden"
grep -Fq 'QEMU_SDL_CURSOR_MODE="${QEMU_SDL_CURSOR_MODE:-host}"' "$launcher" \
    || fail "G-11 launcher does not default to the responsive host cursor"
grep -Fq -- '--auto-cursor) QEMU_SDL_CURSOR_MODE=auto' "$launcher" \
    || fail "G-11 launcher no longer packages opt-in auto mode"

# This feature must remain entirely host-side: no bridge payload, startup
# entry, service or driver is installed into Windows.
if find "$repo_root/deploy/guest" -maxdepth 2 \
        \( -iname '*cursor-bridge*' -o -iname '*cursor-guard*' \) \
        -print -quit | grep -q .; then
    fail "guest cursor bridge/guard artifact violates the host-only design"
fi

echo "OK: SDL cursor auto mode remains opt-in, framebuffer-confirmed and host-only"
