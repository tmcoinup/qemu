#!/usr/bin/env bash
# Source/build contract for SDL 2D renderer reset recovery. No display is used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL_SOURCE="$REPO_ROOT/ui/sdl2.c"
SDL_2D="$REPO_ROOT/ui/sdl2-2d.c"
SDL_GL="$REPO_ROOT/ui/sdl2-gl.c"
CONSOLE_C="$REPO_ROOT/ui/console.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_x11_wminfo_guard() {
    local function_name=$1 body guard_line union_line

    body="$(sed -n "/^[a-zA-Z_].*${function_name}(/,/^}/p" "$SDL_SOURCE")"
    [[ -n "$body" ]] || fail "cannot find $function_name"
    guard_line="$(grep -n -m1 'info.subsystem != SDL_SYSWM_X11' \
        <<<"$body" | cut -d: -f1)"
    union_line="$(grep -n -m1 'info.info.x11' <<<"$body" | cut -d: -f1)"
    [[ -n "$guard_line" && -n "$union_line" &&
       "$guard_line" -lt "$union_line" ]] \
        || fail "$function_name reads the SDL WMInfo union before" \
            "validating X11"
}

guest_current_body="$(sed -n \
    '/^static int sdl2_gl_make_guest_context_current/,/^}/p' "$SDL_GL")"
dmabuf_release_body="$(sed -n \
    '/^void sdl2_gl_release_dmabuf/,/^}/p' "$SDL_GL")"
window_create_body="$(sed -n \
    '/^void sdl2_window_create/,/^}/p' "$SDL_SOURCE")"
has_dmabuf_body="$(sed -n \
    '/^static bool sdl2_gl_has_dmabuf/,/^}/p' "$SDL_SOURCE")"

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
for native_egl_function in \
        sdl2_window_destroy_native_egl \
        sdl2_window_init_native_egl \
        sdl2_window_recreate_native_egl_surface \
        sdl2_window_sync_native_egl_child; do
    require_x11_wminfo_guard "$native_egl_function"
done
grep -Fq 'video_driver = SDL_GetCurrentVideoDriver();' "$SDL_SOURCE" \
    || fail "SDL does not resolve its selected video driver after init"
grep -Fq 'info_report("sdl2: SDL video driver=%s"' "$SDL_SOURCE" \
    || fail "SDL selected video driver is not logged"
SDL_INIT_LINE="$(grep -n -m1 'if (SDL_Init(SDL_INIT_VIDEO))' "$SDL_SOURCE" |
    cut -d: -f1)"
SDL_DRIVER_LINE="$(grep -n -m1 'video_driver = SDL_GetCurrentVideoDriver();' \
    "$SDL_SOURCE" | cut -d: -f1)"
[[ -n "$SDL_INIT_LINE" && -n "$SDL_DRIVER_LINE" &&
   "$SDL_INIT_LINE" -lt "$SDL_DRIVER_LINE" ]] \
    || fail "SDL video driver is queried before SDL_Init"
grep -Fq 'sdl2_current_render_size(scon, &output)' "$SDL_2D" \
    || fail "2D recovery can render with an invalid output size"
grep -Fq 'scon->texture_recreate_pending = false;' "$SDL_2D" \
    || fail "2D texture recovery retry can starve on an expired latch"
grep -Fq 'g_get_monotonic_time() + G_USEC_PER_SEC' "$SDL_2D" \
    || fail "2D texture recovery lost its bounded retry backoff"
grep -Fq 'scon->scanout_replay_pending' "$SDL_GL" \
    || fail "GL scanout failures are not retained for replay"
grep -Fq 'dpy_gl_replay_current_scanout(dcl);' "$SDL_GL" \
    || fail "GL refresh does not replay the authoritative scanout"
grep -Fq 'if (!scon->scanout_replay_after_us)' "$SDL_GL" \
    || fail "GL scanout retry deadline can be postponed by every producer pull"
grep -Fq 'void dpy_gl_replay_current_scanout' "$CONSOLE_C" \
    || fail "display core cannot replay a failed listener scanout"
grep -Fq 'sdl2_gl_ensure_window_context(scon)' "$SDL_GL" \
    || fail "GL redraw does not recover a missing window context"
grep -Fq '!scon->scanout_mode && scon->updates' "$SDL_GL" \
    || fail "surface updates can overwrite an active scanout"
grep -Fq 'egl_fb candidate = EGL_FB_INIT;' "$SDL_GL" \
    || fail "GL scanout setup can overwrite the last safe framebuffer"
grep -Fq 'if (!egl_dmabuf_import_texture(dmabuf))' "$SDL_GL" \
    || fail "failed dma-buf imports can leave a poisoned nonzero texture"
grep -Fq 'candidate = (egl_fb)EGL_FB_INIT;' "$SDL_GL" \
    || fail "committed scanout candidates can be destroyed with old state"
grep -Fq 'qemu_dmabuf_set_texture(dmabuf, 0);' "$SDL_GL" \
    || fail "failed context entry can carry a stale dma-buf texture ID"
grep -Fq 'sdl2_gl_window_context_destroying(scon);' "$SDL_SOURCE" \
    || fail "SDL GL objects are not forgotten before their context dies"
grep -Fq 'scon->native_egl_context_api' "$SDL_SOURCE" \
    || fail "native EGL provider type is not stable across window recreation"
grep -Fq 'scon->native_egl_context_api && scon->has_dmabuf' \
    <<<"$has_dmabuf_body" \
    || fail "detaching the native EGL probe window loses dma-buf capability"
grep -Fq '!sdl2_gl_native_egl_provider_failed()' <<<"$has_dmabuf_body" \
    || fail "terminal native EGL provider loss still advertises dma-buf"
grep -Fq 'sdl2_native_egl_committed' "$SDL_SOURCE" \
    || fail "multiple consoles can still mix process-global EGL and GLX"
grep -Fq 'sdl2_native_egl_poisoned' "$SDL_SOURCE" \
    || fail "an uncleared initial EGL provider can still fall back to GLX"
grep -Fq 'bool keep_context' "$SDL_SOURCE" \
    || fail "native EGL surface detach cannot preserve the root context"
grep -Fq 'provider-lifetime share-group' "$SDL_SOURCE" \
    || fail "native EGL root context is no longer a share-group anchor"
grep -Fq 'return released && *error == EGL_SUCCESS;' "$SDL_SOURCE" \
    || fail "native EGL recovery can report success after unbind failure"
grep -Fq 'sdl2_native_egl_async_terminal_error' "$SDL_GL" \
    || fail "guest-context EGL loss is not propagated safely to the UI thread"
grep -Fq 'sdl2_gl_egl_provider_error(error)' <<<"$guest_current_body" \
    || fail "guest context failure does not isolate local errors from" \
        "provider loss"
if grep -Fq 'sdl2_gl_egl_terminal_error(error)' <<<"$guest_current_body"; then
    fail "a local guest context error can stop every native EGL console"
fi
grep -Fq 'scon->native_egl_owner_tid = current_tid;' \
    <<<"$dmabuf_release_body" \
    || fail "detached dma-buf cleanup does not record anchor ownership"
grep -Fq 'sdl2_gl_note_egl_failure(scon, "dma-buf anchor release", error);' \
    <<<"$dmabuf_release_body" \
    || fail "detached dma-buf cleanup ignores anchor release failure"
grep -Fq 'scon->native_egl_owner_tid = 0;' <<<"$dmabuf_release_body" \
    || fail "detached dma-buf cleanup does not clear released ownership"
grep -Fq 'sdl2_gl_native_egl_init_failed(scon, native_egl_error);' \
    "$SDL_SOURCE" || fail "native EGL reinitialization errors lose backoff"
grep -Fq 'if (!scon->real_window)' "$SDL_GL" \
    || fail "native EGL window retries can bypass their recovery deadline"
grep -Fq 'bool window_create_retry_pending;' "$REPO_ROOT/include/ui/sdl2.h" \
    || fail "SDL parent/context creation has no generic retry latch"
grep -Fq 'SDL2_WINDOW_RETRY_SLOW_US' "$SDL_SOURCE" \
    || fail "SDL parent/context creation has no slow failure backoff"
grep -Fq 'sdl2_window_create_failed(scon, "SDL window creation");' \
    <<<"$window_create_body" \
    || fail "SDL parent creation can retry every refresh"
grep -Fq '"SDL GL context creation"' <<<"$window_create_body" \
    || fail "SDL GL context failures bypass the generic retry path"
grep -Fq '"SDL 2D renderer creation"' <<<"$window_create_body" \
    || fail "SDL renderer failures bypass the generic retry path"
grep -Fq 'g_get_monotonic_time() < scon->window_create_after_us' \
    <<<"$window_create_body" \
    || fail "SDL creation retry deadline is not enforced"

echo "PASS: SDL 2D renderer reset recovery contract"
