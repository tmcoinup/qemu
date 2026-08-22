#!/usr/bin/env bash
# Guard the SDL/Wayland live-title fallback that prevents libdecor-gtk storms.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
SDL2_H="$REPO_ROOT/include/ui/sdl2.h"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
INSTALLER="$REPO_ROOT/deploy/host/install-g11-sdl-wayland-decor.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$START_VM" "$INSTALLER" \
    || fail "Wayland title launcher/installer syntax is invalid"

grep -Fq 'g_strcmp0(video_driver, "wayland") == 0' "$SDL2_C" \
    || fail "title policy no longer uses SDL's actual initialized video driver"
grep -Fq 'sdl2_live_title_fps = !wayland;' "$SDL2_C" \
    || fail "automatic Wayland static-title fallback is missing"
grep -Fq 'scon->present_fps_valid && sdl2_live_title_fps' "$SDL2_C" \
    || fail "Wayland fallback can still put once-per-second FPS in the title"
grep -Fq 'if (sdl2_live_title_fps) {' "$SDL2_C" \
    || fail "FPS tick still calls SDL_SetWindowTitle in static-title mode"
grep -Fq 'g_strcmp0(scon->last_window_title, win_title) != 0' "$SDL2_C" \
    || fail "unchanged SDL titles are not deduplicated"
grep -Fq 'char *last_window_title;' "$SDL2_H" \
    || fail "per-window title cache is missing"
grep -Fq 'g_clear_pointer(&scon->last_window_title, g_free);' "$SDL2_C" \
    || fail "title cache is not reset across SDL window recreation"

grep -Fq 'QEMU_SDL_TITLE_FPS="${QEMU_SDL_TITLE_FPS:-auto}"' "$START_VM" \
    || fail "launcher does not default live title policy to auto"
grep -Fq 'find_libdecor_cairo_plugin' "$START_VM" \
    || fail "launcher no longer discovers the safe Cairo libdecor plugin"
grep -Fq 'LIBDECOR_PLUGIN_DIR="$plugin_dir"' "$START_VM" \
    || fail "Cairo plugin is not isolated to the current QEMU process"
grep -Fq '! -name libdecor-cairo.so' "$START_VM" \
    || fail "private libdecor directory accepts unexpected plugins"
grep -Fq 'libdecor-gtk/GDK 日志风暴' "$START_VM" \
    || fail "operator fallback message no longer explains the safe static title"

installer_info=$($INSTALLER --print)
grep -Fxq 'package=libdecor-0-plugin-1-cairo' <<<"$installer_info" \
    || fail "one-click installer package contract changed"
grep -Fxq 'effect=userspace SDL/Wayland window decoration only' \
    <<<"$installer_info" \
    || fail "installer no longer declares its userspace-only scope"
if grep -Eq '(^|[[:space:]])(modprobe|insmod|mokutil)([[:space:]]|$)' \
        "$INSTALLER"; then
    fail "userspace decoration installer gained a kernel/module action"
fi

echo "OK: SDL Wayland title updates avoid libdecor-gtk monitor log storms"
