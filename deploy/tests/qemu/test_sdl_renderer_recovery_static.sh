#!/usr/bin/env bash
# Source/build contract for SDL 2D renderer reset recovery. No display is used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL_SOURCE="$REPO_ROOT/ui/sdl2.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -Fq 'case SDL_RENDER_TARGETS_RESET:' "$SDL_SOURCE" \
    || fail "SDL target reset is not handled"
grep -Fq 'case SDL_RENDER_DEVICE_RESET:' "$SDL_SOURCE" \
    || fail "SDL device reset is not handled"
grep -Fq 'sdl2_2d_redraw(target);' "$SDL_SOURCE" \
    || fail "target reset does not republish the current surface"
grep -Fq 'sdl2_2d_switch(&target->dcl, target->surface);' "$SDL_SOURCE" \
    || fail "device reset does not recreate the streaming texture"
grep -Fq 'if (target->opengl || !target->real_renderer || !target->surface)' \
    "$SDL_SOURCE" || fail "renderer recovery is not isolated from GL/native EGL"
grep -Fq 'SDL_SetHint(SDL_HINT_WINDOWS_DPI_AWARENESS, "permonitorv2")' \
    "$SDL_SOURCE" || fail "Windows DPI policy is missing before video init"

echo "PASS: SDL 2D renderer reset recovery contract"
