#!/usr/bin/env bash
# Guard the SDL-independent, single-in-flight fb-shm GPU preview contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FB_SHM_C="$REPO_ROOT/ui/fb-shm.c"
FB_SHM_ABI="$REPO_ROOT/include/ui/fb-shm-abi.h"
SDL_GL="$REPO_ROOT/ui/sdl2-gl.c"
WRAPPER="$REPO_ROOT/deploy/scripts/check-fb-shm-gpu-sync.sh"
RUNBOOK="$REPO_ROOT/deploy/docs/G11-FB-SHM-GPU-SYNC.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    local source=$1 symbol=$2

    awk -v symbol="$symbol" '
        !started && $1 != "return" &&
            $0 ~ ("^[[:space:]]*(static[[:space:]]+)?" \
                           "[[:alnum:]_]+[[:space:]*]+" symbol "\\(") {
            started = 1
        }
        started {
            print
            open_line = $0
            close_line = $0
            opens = gsub(/{/, "{", open_line)
            closes = gsub(/}/, "}", close_line)
            if (opens) {
                saw_body = 1
            }
            depth += opens - closes
            if (saw_body && depth == 0) {
                exit
            }
        }
    ' "$source"
}

[[ -r "$FB_SHM_C" && -r "$FB_SHM_ABI" && -r "$SDL_GL" ]] \
    || fail "required QEMU UI sources are missing"
[[ -r "$WRAPPER" && -r "$RUNBOOK" ]] \
    || fail "operator wrapper or runbook is missing"
bash -n "$WRAPPER" || fail "read-only wrapper syntax is invalid"

sdl_surface_update=$(extract_function "$SDL_GL" sdl2_gl_update)
sdl_surface_before_upload=${sdl_surface_update%%surface_gl_update_texture*}
grep -Fq 'if (!sdl2_window_is_renderable(scon))' \
    <<<"$sdl_surface_before_upload" \
    || fail "SDL surface upload lost its hidden-window guard"
grep -Fq 'scon->surface_upload_pending = true;' \
    <<<"$sdl_surface_before_upload" \
    || fail "SDL hidden surface no longer latches a later visible upload"
grep -Fq 'return;' <<<"$sdl_surface_before_upload" \
    || fail "SDL hidden surface guard no longer returns before upload"

sdl_scanout_flush=$(extract_function "$SDL_GL" sdl2_gl_scanout_flush)
sdl_scanout_before_draw=${sdl_scanout_flush%%glBindFramebuffer*}
grep -Fq 'if (!sdl2_window_is_renderable(scon))' \
    <<<"$sdl_scanout_before_draw" \
    || fail "SDL GL scanout lost its hidden-window guard"
grep -Fq 'return;' <<<"$sdl_scanout_before_draw" \
    || fail "SDL hidden scanout no longer returns before window drawing"

surface_gpu=$(extract_function "$FB_SHM_C" fb_shm_commit_surface_gpu_frame)
grep -Fq 'surface_gl_upload_texture(surface,' <<<"$surface_gpu" \
    || fail "fb-shm surface sync no longer uploads from CPU surface data"
grep -Fq 'd->gl_cpu_upload_fb.texture' <<<"$surface_gpu" \
    || fail "fb-shm surface sync lost its private CPU-upload texture"
surface_sync=$(sed -n \
    '/if (sync_due && fb_shm_prepare_sync_fb/,/^#endif/p' <<<"$surface_gpu")
grep -Fq 'd->gl_cpu_upload_fb.framebuffer' <<<"$surface_sync" \
    || fail "surface sync does not read the fb-shm-owned upload FBO"
grep -Fq 'd->gl_sync_fb.framebuffer' <<<"$surface_sync" \
    || fail "surface sync does not draw into the leased private FBO"
if grep -Fq 'surface->texture' <<<"$surface_sync"; then
    fail "surface sync regressed to SDL-owned surface->texture"
fi

grep -Fq 'egl_fb gl_blit_fb;' "$FB_SHM_C" \
    || fail "SHM/PBO readback FBO is missing"
grep -Fq 'egl_fb gl_sync_fb;' "$FB_SHM_C" \
    || fail "synchronized GPU preview lost its private FBO"
gl_sync=$(extract_function "$FB_SHM_C" fb_shm_publish_gl_sync_frame)
grep -Fq 'GL_DRAW_FRAMEBUFFER, d->gl_sync_fb.framebuffer' <<<"$gl_sync" \
    || fail "GL scanout is not copied into the private sync FBO"
grep -Fq 'd, d->gl_sync_fb.texture, rw, rh, 0, 0, rw, rh' <<<"$gl_sync" \
    || fail "sync wire layout is no longer a baked 0,0 ROI texture"
grep -Fq '0, rh, rw, 0,' <<<"$gl_sync" \
    || fail "GL sync texture lost its normalized top-down target flip"
if grep -Fq 'd->gl_blit_fb' <<<"$gl_sync"; then
    fail "sync handoff incorrectly reuses the SHM/PBO readback FBO"
fi
grep -Fq 'sy1 = backing_height - ((int)d->gl_y + ry);' <<<"$gl_sync" \
    || fail "y0-top GL scanout lost backing-height ROI reflection"
grep -Fq 'sy2 = backing_height - ((int)d->gl_y + ry + (int)rh);' \
    <<<"$gl_sync" \
    || fail "y0-top GL scanout bottom coordinate is incorrect"

grep -Fq '#define FB_SHM_CTL_GPU_FRAME_DONE' "$FB_SHM_ABI" \
    || fail "GPU_FRAME_DONE opcode is missing from the ABI"
grep -Fq '#define FB_SHM_GPU_FRAME_F_SYNC_FILE' "$FB_SHM_ABI" \
    || fail "acquire sync-file flag is missing from the ABI"

sync_available=$(extract_function "$FB_SHM_C" fb_shm_gpu_sync_available)
grep -Fq '!fb_shm_gpu_pending_active' <<<"$sync_available" \
    || fail "sync publisher no longer enforces one frame in flight"
grep -Fq 'fb_shm_gpu_pending_begin' "$FB_SHM_C" \
    || fail "sync send no longer records the pending owner/sequence"
grep -Fq 'fb_shm_gpu_pending_complete' "$FB_SHM_C" \
    || fail "matching GPU_FRAME_DONE no longer completes the lease"
grep -Fq 'lease expired; dropping stalled consumer' "$FB_SHM_C" \
    || fail "stalled sync clients are no longer dropped before BO retirement"
grep -Fq 'd->gl_sync_retired = true;' "$FB_SHM_C" \
    || fail "disconnect/send failure can reuse an externally held sync BO"
prepare_sync=$(extract_function "$FB_SHM_C" fb_shm_prepare_sync_fb)
prepare_before_failure=${prepare_sync%%if (!ready)*}
if grep -Fq 'd->gl_sync_retired = false;' <<<"$prepare_before_failure"; then
    fail "failed replacement can clear the retired sync-BO guard"
fi
grep -Fq 'd->gl_sync_retired = false;' <<<"$prepare_sync" \
    || fail "complete replacement no longer clears the retired sync-BO guard"

legacy_accept=$(extract_function "$FB_SHM_C" fb_shm_client_accepts_legacy_gpu)
grep -Fq '!c->wants_gpu_sync' <<<"$legacy_accept" \
    || fail "legacy direct frames are still routed to synchronized clients"
grep -Fq 'egl_create_native_fence_fd()' "$FB_SHM_C" \
    || fail "producer does not create an acquire fence after private blit"
grep -Fq 'flags |= FB_SHM_GPU_FRAME_F_SYNC_FILE;' "$FB_SHM_C" \
    || fail "synchronized frame does not advertise its second fd"
grep -Fq 'int descriptors[2];' "$FB_SHM_C" \
    || fail "GPU notification cannot carry dma-buf plus acquire fence"
grep -Fq 'fb_shm_gl_setup_private_fb' "$FB_SHM_C" \
    || fail "private GPU framebuffers are not completeness-checked"

grep -Fq 'never connects to QMP/fb-shm' "$WRAPPER" \
    || fail "wrapper lost its explicit read-only contract"
if grep -Eq '(^|[[:space:]])(sudo|kill|pkill|systemctl|virsh|qemu-img|rm|mv|cp|tee)([[:space:]]|$)' \
        "$WRAPPER"; then
    fail "read-only wrapper contains a mutating command"
fi
grep -Fq '不会修改 BCD/安全设置' "$WRAPPER" \
    || fail "wrapper help lost the security boundary"

grep -Fq './deploy/scripts/check-fb-shm-gpu-sync.sh source' "$RUNBOOK" \
    || fail "runbook lacks the source preflight command"
grep -Fq './deploy/scripts/check-fb-shm-gpu-sync.sh runtime 9' "$RUNBOOK" \
    || fail "runbook lacks the post-start read-only verification command"
grep -Fq 'FPS 数字不是新帧证明' "$RUNBOOK" \
    || fail "runbook may misdiagnose a repeated frozen texture as live video"
grep -Fq '不会开启 testsigning 或 nointegritychecks' "$RUNBOOK" \
    || fail "runbook lost the repository security prohibition"

echo "OK: fb-shm private GPU-sync, SDL-hidden and read-only operator contracts passed"
