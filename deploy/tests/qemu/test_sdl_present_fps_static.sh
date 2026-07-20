#!/usr/bin/env bash
# Guard the visible SDL 60 Hz pacing and Present FPS title counter.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
SDL2_GL="$REPO_ROOT/ui/sdl2-gl.c"
SDL2_2D="$REPO_ROOT/ui/sdl2-2d.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -Eq '^#define SDL2_REFRESH_INTERVAL_ACTIVE_NS +16666667ULL$' "$SDL2_C" \
    || fail "visible SDL refresh must stay at an exact 60 Hz nanosecond period"
grep -Fq 'update_displaychangelistener_ns(' "$SDL2_C" \
    || fail "SDL restore paths no longer select precise frame pacing"
grep -Fq 'dcl.update_interval_ns =' "$SDL2_C" \
    || fail "SDL listeners do not start with precise frame pacing"
grep -Fq 'timer_new_ns(QEMU_CLOCK_REALTIME' "$REPO_ROOT/ui/console.c" \
    || fail "console GUI refresh timer lost nanosecond precision"
grep -Fq 'next_ns = deadline_ns + interval_ns' "$REPO_ROOT/ui/console.c" \
    || fail "precise GUI refresh no longer advances from absolute deadlines"
grep -Fq 'SDL Present %.1f FPS' "$SDL2_C" \
    || fail "window title lost its Present FPS indicator"
grep -Fq 'sdl2_present_rate_tick(scon);' "$SDL2_C" \
    || fail "Present FPS no longer falls to zero when frame dedup skips swaps"
grep -Fq 'sdl2_note_present(scon);' "$SDL2_GL" \
    || fail "OpenGL swap path is not counted"
grep -Fq 'sdl2_note_present(scon);' "$SDL2_2D" \
    || fail "2D SDL_RenderPresent path is not counted"
grep -Fq 'SDL_GL_SetSwapInterval(0);' "$SDL2_C" \
    || fail "QEMU main-loop-safe nonblocking swap policy changed"
grep -Fq 'QEMU_SDL_PRESENT_MODE' "$REPO_ROOT/deploy/start-vm.sh" \
    || fail "launcher no longer exposes fixed/dynamic SDL Present modes"
grep -Fq 'QEMU_SDL_PRESENT_MODE="${QEMU_SDL_PRESENT_MODE:-fixed}"' \
    "$REPO_ROOT/deploy/start-vm.sh" \
    || fail "launcher must default SDL Present mode to fixed"
grep -Fq 'scon->fixed_present && !scon->presented_since_refresh' "$SDL2_GL" \
    || fail "OpenGL SDL fixed 60 Hz redraw path is missing"
grep -Fq 'scon->fixed_present && !scon->presented_since_refresh' "$SDL2_2D" \
    || fail "2D SDL fixed 60 Hz redraw path is missing"

echo "OK: SDL 60 Hz pacing and Present FPS static checks passed"
