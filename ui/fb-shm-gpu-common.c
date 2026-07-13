/*
 * fb-shm GPU sideband 平台无关辅助函数。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/fb-shm-gpu.h"

static bool fb_shm_gpu_layout_valid(const FbShmGpuFrameLayout *layout)
{
    if (!layout || !layout->width || !layout->height ||
        !layout->backing_width || !layout->backing_height) {
        return false;
    }

    /*
     * 先检查原点，再用减法检查尺寸。
     * 不能写成 x + width > backing_width，
     * 否则恶意或损坏的元数据可通过 uint32_t 回绕
     * 伪造合法区域。
     */
    if (layout->x >= layout->backing_width ||
        layout->y >= layout->backing_height ||
        layout->width > layout->backing_width - layout->x ||
        layout->height > layout->backing_height - layout->y) {
        return false;
    }

    return true;
}

bool fb_shm_gpu_frame_build(FbShmGpuFrame *frame,
                            const FbShmGpuFrameLayout *layout,
                            uint32_t handle_type,
                            uint32_t extra_flags,
                            uint32_t stride,
                            uint32_t fourcc,
                            uint64_t modifier,
                            uint64_t frame_seq,
                            const char *handle_name)
{
    uint32_t flags = extra_flags;

    if (!frame || !fb_shm_gpu_layout_valid(layout) ||
        !stride || !fourcc || !frame_seq) {
        return false;
    }
    if (extra_flags & ~(FB_SHM_GPU_FRAME_F_Y0_TOP |
                        FB_SHM_GPU_FRAME_F_KEYED_MUTEX)) {
        return false;
    }

    switch (handle_type) {
    case FB_SHM_GPU_HANDLE_DMA_BUF:
        if ((handle_name && *handle_name) ||
            (extra_flags & FB_SHM_GPU_FRAME_F_KEYED_MUTEX)) {
            return false;
        }
        break;
    case FB_SHM_GPU_HANDLE_D3D11_TEXTURE:
        if (!handle_name || !*handle_name ||
            !(extra_flags & FB_SHM_GPU_FRAME_F_KEYED_MUTEX) ||
            strlen(handle_name) >= FB_SHM_GPU_NAME_MAX) {
            return false;
        }
        break;
    default:
        return false;
    }

    if (layout->y0_top) {
        flags |= FB_SHM_GPU_FRAME_F_Y0_TOP;
    }

    memset(frame, 0, sizeof(*frame));
    frame->magic = FB_SHM_MAGIC;
    frame->version = FB_SHM_VERSION;
    frame->size = sizeof(*frame);
    frame->handle_type = handle_type;
    frame->flags = flags;
    frame->width = layout->width;
    frame->height = layout->height;
    frame->stride = stride;
    frame->fourcc = fourcc;
    frame->x = layout->x;
    frame->y = layout->y;
    frame->backing_width = layout->backing_width;
    frame->backing_height = layout->backing_height;
    frame->modifier = modifier;
    frame->frame_seq = frame_seq;

    if (handle_name) {
        memcpy(frame->handle_name, handle_name, strlen(handle_name) + 1);
    }
    return true;
}

void fb_shm_gpu_export_cleanup(FbShmGpuExport *exported)
{
    if (!exported) {
        return;
    }

#ifndef _WIN32
    if (exported->fd >= 0) {
        close(exported->fd);
    }
#endif
    memset(exported, 0, sizeof(*exported));
    exported->fd = -1;
}

bool fb_shm_gpu_pending_begin(FbShmGpuPendingFrame *state,
                              uint64_t frame_sequence)
{
    if (!state || !frame_sequence || state->pending_sequence ||
        frame_sequence <= state->last_sequence) {
        return false;
    }

    /*
     * 先更新 high-water mark，再暴露 pending sequence。
     * 调用均在主线程，无需原子操作；cancel 后也拒绝重放。
     */
    state->last_sequence = frame_sequence;
    state->pending_sequence = frame_sequence;
    return true;
}

static bool fb_shm_gpu_pending_finish(FbShmGpuPendingFrame *state,
                                      uint64_t frame_sequence)
{
    if (!state || !frame_sequence ||
        state->pending_sequence != frame_sequence) {
        return false;
    }

    state->pending_sequence = 0;
    return true;
}

bool fb_shm_gpu_pending_complete(FbShmGpuPendingFrame *state,
                                 uint64_t frame_sequence)
{
    return fb_shm_gpu_pending_finish(state, frame_sequence);
}

bool fb_shm_gpu_pending_cancel(FbShmGpuPendingFrame *state,
                               uint64_t frame_sequence)
{
    return fb_shm_gpu_pending_finish(state, frame_sequence);
}

bool fb_shm_gpu_pending_active(const FbShmGpuPendingFrame *state,
                               uint64_t *frame_sequence)
{
    if (!state || !state->pending_sequence) {
        return false;
    }

    if (frame_sequence) {
        *frame_sequence = state->pending_sequence;
    }
    return true;
}
