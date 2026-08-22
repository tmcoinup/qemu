#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Guard the G-11 SDL pointer mapping and XWayland grab contract.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
sdl_c="$repo_root/ui/sdl2.c"
sdl_h="$repo_root/include/ui/sdl2.h"
input_c="$repo_root/ui/input.c"
pointer_c="$repo_root/ui/sdl2-pointer.c"
ui_meson="$repo_root/ui/meson.build"
unit_meson="$repo_root/tests/unit/meson.build"
runner="$repo_root/deploy/tests/run-g11.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$repo_root/include/ui/sdl2-pointer.h" ]] \
    || fail "SDL pointer helper header is missing"
[[ -f "$repo_root/ui/sdl2-pointer.c" ]] \
    || fail "SDL pointer helper implementation is missing"
[[ -f "$repo_root/tests/unit/test-sdl2-pointer.c" ]] \
    || fail "SDL pointer unit test is missing"

if grep -Fq 'absolute_mouse_grab' "$sdl_c"; then
    fail "windowed absolute pointers must never auto-grab at an edge"
fi

motion_handler="$(sed -n '/^static void handle_mousemotion/,/^}/p' "$sdl_c")"
if grep -Eq 'sdl_grab_(start|end)' <<<"$motion_handler"; then
    fail "mouse motion must not toggle SDL pointer constraints"
fi
for raw_field in \
    'ev->motion.xrel' 'ev->motion.yrel' \
    'ev->motion.x' 'ev->motion.y'; do
    grep -Fq "$raw_field" <<<"$motion_handler" \
        || fail "motion handler no longer forwards raw $raw_field"
done

if grep -Eq 'ev->motion\.(x|y|xrel|yrel)[[:space:]]*\*' "$sdl_c"; then
    fail "motion handler performs a coordinate conversion before the mapper"
fi
if grep -Eq 'bev->(x|y)[[:space:]]*\*' "$sdl_c"; then
    fail "button handler performs a coordinate conversion before the mapper"
fi

grep -Fq 'sdl2_map_point(window, render' "$sdl_c" \
    || fail "logical-window to render mapping is not centralized"
grep -Fq 'sdl2_window_to_guest(dst, guest' "$sdl_c" \
    || fail "render to guest mapping is not centralized"
grep -Fq 'sdl2_scale_relative_motion' "$sdl_c" \
    || fail "relative movement no longer retains fractional remainders"
grep -Fq 'bool pointer_geometry_valid;' "$sdl_h" \
    || fail "per-motion pointer geometry cache is missing"
grep -Fq 'sdl2_pointer_geometry_changed(scon);' "$sdl_c" \
    || fail "window/DPI changes do not invalidate cached pointer geometry"
grep -Fq 'qemu_input_has_absolute' "$input_c" \
    || fail "tablet capability query is missing"
grep -Fq 'sdl2_pointer_policy' "$sdl_c" \
    || fail "tablet capability policy is not applied by SDL"
grep -Fq '.relative_mode = grabbed && !current_absolute,' "$pointer_c" \
    || fail "an explicit REL grab no longer enables SDL relative mode"
grep -Fq 'SDL_SetRelativeMouseMode(SDL_FALSE)' "$sdl_c" \
    || fail "SDL relative mode is not explicitly cleared"
grep -Fq 'static struct sdl2_console *grabbed_scon;' "$sdl_c" \
    || fail "SDL grab ownership is not tracked per console"
grep -Fq 'bool absolute_available;' "$sdl_h" \
    || fail "absolute capability cache is not per console"
grep -Fq 'sdl_cursor_is_active(scon)' "$sdl_c" \
    || fail "background guest cursor events can still alter the host cursor"

grep -Fq "'sdl2-pointer.c'" "$ui_meson" \
    || fail "SDL module does not compile the pointer helper"
grep -Fq "'test-sdl2-pointer'" "$unit_meson" \
    || fail "pointer unit test is not registered with Meson"
grep -Fq 'test-sdl2-pointer' "$runner" \
    || fail "G-11 one-command validation omits the pointer unit test"

# G-11-specific rendering must survive the independent V-11 algorithm port.
grep -Fq 'fixed_present' "$sdl_h" \
    || fail "G-11 fixed Present state was lost"
grep -Fq 'eglQuerySurface' "$sdl_h" \
    || fail "native EGL render dimensions are not used for pointer mapping"

echo "OK: SDL pointer mapping/grab static checks passed"
