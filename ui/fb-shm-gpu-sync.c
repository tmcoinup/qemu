/*
 * fb-shm synchronized GPU-frame protocol helpers.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/fb-shm-gpu-sync.h"

bool fb_shm_gpu_hello_flags_valid(uint32_t flags)
{
    bool gpu_frames = (flags & FB_SHM_HELLO_F_GPU_FRAMES) != 0;

    return (gpu_frames || !(flags & FB_SHM_HELLO_F_GPU_REQUIRED)) &&
           (gpu_frames || !(flags & FB_SHM_HELLO_F_GPU_SYNC));
}

bool fb_shm_gpu_pending_begin(FbShmGpuPendingFrame *state,
                              const void *owner, uint64_t sequence)
{
    if (!state || !owner || !sequence || state->pending_sequence ||
        sequence <= state->last_sequence) {
        return false;
    }

    state->owner = owner;
    state->pending_sequence = sequence;
    state->last_sequence = sequence;
    return true;
}

bool fb_shm_gpu_pending_complete(FbShmGpuPendingFrame *state,
                                 const void *owner, uint64_t sequence)
{
    if (!state || !owner || state->owner != owner ||
        !sequence || state->pending_sequence != sequence) {
        return false;
    }

    state->owner = NULL;
    state->pending_sequence = 0;
    return true;
}

bool fb_shm_gpu_pending_retire(FbShmGpuPendingFrame *state,
                               const void *owner)
{
    if (!state || !owner || state->owner != owner ||
        !state->pending_sequence) {
        return false;
    }

    state->owner = NULL;
    state->pending_sequence = 0;
    return true;
}

bool fb_shm_gpu_pending_active(const FbShmGpuPendingFrame *state,
                               const void **owner, uint64_t *sequence)
{
    if (!state || !state->owner || !state->pending_sequence) {
        return false;
    }
    if (owner) {
        *owner = state->owner;
    }
    if (sequence) {
        *sequence = state->pending_sequence;
    }
    return true;
}

void fb_shm_gpu_done_req_init(FbShmCtlReq *req, uint64_t sequence)
{
    memset(req, 0, sizeof(*req));
    req->magic = FB_SHM_MAGIC;
    req->op = FB_SHM_CTL_GPU_FRAME_DONE;
    req->w = (uint32_t)sequence;
    req->h = (uint32_t)(sequence >> 32);
}

bool fb_shm_gpu_done_req_sequence(const FbShmCtlReq *req,
                                  uint64_t *sequence)
{
    uint64_t value;

    if (!req || req->magic != FB_SHM_MAGIC ||
        req->op != FB_SHM_CTL_GPU_FRAME_DONE || req->x || req->y ||
        req->rate_hz || req->flags) {
        return false;
    }

    value = ((uint64_t)req->h << 32) | req->w;
    if (!value) {
        return false;
    }
    if (sequence) {
        *sequence = value;
    }
    return true;
}
