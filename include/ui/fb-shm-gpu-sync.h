/*
 * fb-shm synchronized GPU-frame protocol helpers.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef QEMU_UI_FB_SHM_GPU_SYNC_H
#define QEMU_UI_FB_SHM_GPU_SYNC_H

#include "ui/fb-shm-abi.h"

typedef struct FbShmGpuPendingFrame {
    const void *owner;
    uint64_t pending_sequence;
    uint64_t last_sequence;
} FbShmGpuPendingFrame;

bool fb_shm_gpu_hello_flags_valid(uint32_t flags);
bool fb_shm_gpu_pending_begin(FbShmGpuPendingFrame *state,
                              const void *owner, uint64_t sequence);
bool fb_shm_gpu_pending_complete(FbShmGpuPendingFrame *state,
                                 const void *owner, uint64_t sequence);
bool fb_shm_gpu_pending_retire(FbShmGpuPendingFrame *state,
                               const void *owner);
bool fb_shm_gpu_pending_active(const FbShmGpuPendingFrame *state,
                               const void **owner, uint64_t *sequence);
void fb_shm_gpu_done_req_init(FbShmCtlReq *req, uint64_t sequence);
bool fb_shm_gpu_done_req_sequence(const FbShmCtlReq *req,
                                  uint64_t *sequence);

#endif /* QEMU_UI_FB_SHM_GPU_SYNC_H */
