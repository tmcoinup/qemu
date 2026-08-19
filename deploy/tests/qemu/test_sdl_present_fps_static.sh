#!/usr/bin/env bash
# Guard the visible SDL 60 Hz pacing and Present FPS title counter.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL2_C="$REPO_ROOT/ui/sdl2.c"
SDL2_GL="$REPO_ROOT/ui/sdl2-gl.c"
SDL2_2D="$REPO_ROOT/ui/sdl2-2d.c"
FB_SHM_C="$REPO_ROOT/ui/fb-shm.c"

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
grep -Fq 'fb_shm_rate_interval_ns' "$FB_SHM_C" \
    || fail "fb-shm preview lost its exact nanosecond rate helper"
grep -Fq 'DIV_ROUND_UP((uint64_t)NANOSECONDS_PER_SECOND, rate)' "$FB_SHM_C" \
    || fail "fb-shm preview rate is no longer rounded at nanosecond precision"
grep -Fq 'update_displaychangelistener_ns(&d->dcl' "$FB_SHM_C" \
    || fail "fb-shm preview no longer selects precise display pacing"
grep -Fq 'd->dcl.update_interval_ns = fb_shm_rate_interval_ns' "$FB_SHM_C" \
    || fail "fb-shm listener does not start with precise display pacing"
if grep -Fq 'fb_shm_rate_interval_ms' "$FB_SHM_C"; then
    fail "fb-shm preview regressed to millisecond-quantized pacing"
fi
grep -Fq 'graphic_hw_invalidate(d->con);' "$FB_SHM_C" \
    || fail "fb-shm SET_RATE no longer revalidates an idle display pipeline"
grep -Fq 'fb_shm_publish_frame(d, cur_idx, rw, rh);' "$FB_SHM_C" \
    || fail "fb-shm SHM path no longer repeats its cached frame at fixed rate"
grep -Fq 'Every due tick publishes; damage only controls cache refresh.' "$FB_SHM_C" \
    || fail "fb-shm GPU path no longer guarantees fixed-rate publication"
if grep -Fq 'd->shm && !d->cpu_surface_dirty' "$FB_SHM_C"; then
    fail "fb-shm SHM publication regressed to damage-driven cadence"
fi
if grep -Fq '!d->cpu_surface_gpu_dirty || !fb_shm_has_gpu_clients' "$FB_SHM_C"; then
    fail "fb-shm GPU publication regressed to damage-driven cadence"
fi
grep -Fq 'SDL Present %.1f FPS' "$SDL2_C" \
    || fail "window title lost its Present FPS indicator"
grep -Fq '"%s | SDL Present %.1f FPS%s%s", title_name' "$SDL2_C" \
    || fail "primary explicit SDL title no longer stays free of an invented console suffix"
grep -Fq 'snprintf(win_title, sizeof(win_title), "%s%s%s"' "$SDL2_C" \
    || fail "primary explicit SDL base title is no longer used verbatim"
grep -Fq 'title_is_explicit && scon->idx == 0' "$SDL2_C" \
    || fail "explicit title is not restricted to the primary console"
grep -Fq '"%s-console-%d | SDL Present %.1f FPS%s%s", title_name' "$SDL2_C" \
    || fail "secondary SDL consoles can collide with the primary instance title"
grep -Fq 'o->u.sdl.has_single_console && o->u.sdl.single_console' "$SDL2_C" \
    || fail "SDL single-console launcher policy is not implemented"
grep -Fq 'SDL_SetWindowMaximumSize(scon->real_window' "$SDL2_C" \
    || fail "SDL window no longer caps its client area to guest resolution"
grep -Fq 'sdl2_window_resize(scon);' "$SDL2_C" \
    || fail "SDL show/resume no longer restores the current guest resolution"
grep -Fq 'sdl2_present_rate_tick(scon);' "$SDL2_C" \
    || fail "Present FPS no longer falls to zero when frame dedup skips swaps"
grep -Fq 'scon->fps_low_warmup_windows = SDL2_FPS_LOW_WARMUP_WINDOWS;' "$SDL2_C" \
    || fail "SDL restore can publish a misleading minimized-cadence FPS sample"
grep -Fq 'sdl2_note_present(scon);' "$SDL2_GL" \
    || fail "OpenGL swap path is not counted"
grep -Fq 'sdl2_note_present(scon);' "$SDL2_2D" \
    || fail "2D SDL_RenderPresent path is not counted"
grep -Fq 'SDL_GL_SetSwapInterval(0);' "$SDL2_C" \
    || fail "QEMU main-loop-safe nonblocking swap policy changed"
grep -Fq 'QEMU_SDL_PRESENT_MODE' "$REPO_ROOT/deploy/scripts/start-vm.sh" \
    || fail "launcher no longer exposes fixed/dynamic SDL Present modes"
grep -Fq 'QEMU_SDL_PRESENT_MODE="${QEMU_SDL_PRESENT_MODE:-fixed}"' \
    "$REPO_ROOT/deploy/scripts/start-vm.sh" \
    || fail "launcher must default SDL Present mode to fixed"
grep -Fq 'scon->fixed_present && !scon->presented_since_refresh' "$SDL2_GL" \
    || fail "OpenGL SDL fixed 60 Hz redraw path is missing"
grep -Fq 'scon->fixed_present && !scon->presented_since_refresh' "$SDL2_2D" \
    || fail "2D SDL fixed 60 Hz redraw path is missing"
grep -Fq 'cannot release context after window init' "$SDL2_C" \
    || fail "native EGL window initialization can leak context ownership"
grep -Fq 'sdl2_gl_release_window_current(scon);' "$SDL2_GL" \
    || fail "native EGL rendering does not release bounded window ownership"
grep -Fq 'warned_native_egl_make_current' "$SDL2_GL" \
    || fail "native EGL make-current failures can flood the operator log"

echo "OK: SDL 60 Hz pacing and Present FPS static checks passed"
