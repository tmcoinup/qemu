#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Guard G-11's SDL minimize/restore and one-way display sizing contract.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
sdl_c="$repo_root/ui/sdl2.c"
sdl_2d="$repo_root/ui/sdl2-2d.c"
sdl_gl="$repo_root/ui/sdl2-gl.c"
sdl_h="$repo_root/include/ui/sdl2.h"
event_c="$repo_root/ui/sdl2-event.c"
event_test="$repo_root/tests/unit/test-sdl2-event.c"
guide="$repo_root/deploy/docs/G11-SDL-MINIMIZE.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

native_sync="$(sed -n \
    '/^static void sdl2_window_sync_native_egl_child/,/^}/p' "$sdl_c")"
window_resize="$(sed -n '/^void sdl2_window_resize/,/^}/p' "$sdl_c")"
window_flush="$(sed -n '/^void sdl2_flush_window_updates/,/^}/p' "$sdl_c")"
minimized_case="$(sed -n \
    '/case SDL_WINDOWEVENT_MINIMIZED:/,/^[[:space:]]*break;/p' "$sdl_c")"
maximized_case="$(sed -n \
    '/case SDL_WINDOWEVENT_MAXIMIZED:/,/^[[:space:]]*break;/p' "$sdl_c")"
hidden_case="$(sed -n \
    '/case SDL_WINDOWEVENT_HIDDEN:/,/^[[:space:]]*break;/p' "$sdl_c")"
present_2d="$(sed -n \
    '/^static bool sdl2_2d_present_texture/,/^}/p' "$sdl_2d")"
scanout_flush="$(sed -n \
    '/^void sdl2_gl_scanout_flush/,/^}/p' "$sdl_gl")"
surface_texture="$(sed -n \
    '/^static bool sdl2_gl_create_surface_texture/,/^}/p' "$sdl_gl")"
ensure_context="$(sed -n \
    '/^static bool sdl2_gl_ensure_window_context/,/^}/p' "$sdl_gl")"
scanout_texture="$(sed -n \
    '/^void sdl2_gl_scanout_texture/,/^}/p' "$sdl_gl")"
scanout_dmabuf="$(sed -n \
    '/^void sdl2_gl_scanout_dmabuf/,/^}/p' "$sdl_gl")"

grep -Fq 'bool window_resize_pending;' "$sdl_h" \
    || fail "deferred guest resize state is missing"
grep -Fq 'sdl2_window_updates_allowed' "$event_c" \
    || fail "shared minimized/hidden window policy is missing"
grep -Fq '/sdl2-event/window-update-visibility' "$event_test" \
    || fail "window visibility policy unit test is missing"

grep -Fq 'sdl2_window_is_renderable(scon)' <<<"$native_sync" \
    || fail "native EGL child can still be resized/remapped while minimized"
grep -Fq 'scon->window_resize_pending = true;' <<<"$window_resize" \
    || fail "guest mode changes are not deferred while minimized"
grep -Fq 'sdl2_window_is_renderable(target)' <<<"$window_flush" \
    || fail "queued window updates are not gated after draining SDL events"
grep -Fq 'target->window_resize_pending' <<<"$window_flush" \
    || fail "deferred resize is not applied after restore"
not_renderable="$(sed -n \
    '/if (!sdl2_window_is_renderable(target))/,/continue;/p' <<<"$window_flush")"
if grep -Fq 'window_redraw_pending = false' <<<"$not_renderable"; then
    fail "SHOWN/RESTORED flag races can still discard the pending redraw"
fi
grep -Fq 'scon->window_redraw_pending = false;' <<<"$minimized_case" \
    || fail "minimize does not discard the queued animation redraw"
grep -Fq 'scon->window_redraw_pending = true;' <<<"$maximized_case" \
    || fail "maximize does not request a complete compositor-buffer redraw"
grep -Fq 'scon->window_redraw_pending = false;' <<<"$hidden_case" \
    || fail "hide does not discard queued redraws"

grep -Fq 'sdl2_window_is_renderable(scon)' <<<"$present_2d" \
    || fail "SDL 2D can still Present while minimized"
grep -Fq 'sdl2_window_is_renderable(scon)' <<<"$scanout_flush" \
    || fail "SDL GL scanout can still swap while minimized"
grep -Fq 'sdl2_window_is_renderable(scon)' "$sdl_gl" \
    || fail "SDL GL paths do not share the minimized guard"
if grep -Fq 'scon->updates++' "$sdl_2d" "$sdl_gl"; then
    fail "pending frames can overflow while the window stays minimized"
fi
grep -Fq 'scon->surface_upload_pending = true;' "$sdl_2d" \
    || fail "2D still uploads every invisible frame while minimized"
grep -Fq 'scon->surface_upload_pending = true;' "$sdl_gl" \
    || fail "GL still uploads every invisible frame while minimized"
grep -Fq '!sdl2_window_is_renderable(scon)' <<<"$surface_texture" \
    || fail "GL texture allocation can upload a full hidden surface"
grep -Fq 'scon->surface_upload_pending = true;' <<<"$ensure_context" \
    || fail "hidden GL context setup does not latch a visible full upload"
grep -Fq 'sdl2_gl_defer_hidden_scanout(scon)' <<<"$scanout_texture" \
    || fail "hidden texture scanout can still allocate an FBO"
grep -Fq 'sdl2_gl_defer_hidden_scanout(scon)' <<<"$scanout_dmabuf" \
    || fail "hidden dma-buf scanout can still import a texture"
grep -Fq '!scon->native_egl_context_api' <<<"$scanout_dmabuf" \
    || fail "a detached native EGL window can discard its pending dma-buf"

if grep -Fq 'dpy_set_ui_info' "$sdl_c"; then
    fail "host SDL resize must not feed animation geometry back to the Guest"
fi
if grep -Fq 'ui_info_pending' "$sdl_c" "$sdl_h"; then
    fail "obsolete host-to-Guest resize queue remains"
fi
grep -Fq 'g_setenv("SDL_VIDEO_X11_WMCLASS", "qemu", false);' "$sdl_c" \
    || fail "SDL window no longer has a stable GNOME/Dock application class"

[[ -f "$guide" ]] || fail "foolproof minimize/restore guide is missing"

echo "OK: SDL minimize/restore static checks passed"
