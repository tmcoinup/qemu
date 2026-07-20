/*
 * Native fb-shm GPU capability and frame validation.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * This file deliberately does not treat an installed ffmpeg executable or a
 * hardware encoder name as a native GPU backend.  The existing ffmpeg pipe
 * accepts CPU rawvideo only.  A backend is available only after the consumer
 * can import the received dma-buf / D3D11 texture and retain the GPU resource
 * until an asynchronous encoder has finished with it.
 */

#include "common.h"
#include "fb-shm-stream-gpu-config.h"

FbShmStreamGpuStatus fb_shm_stream_gpu_backend_probe(void)
{
    /*
     * No native handle-import encoder is linked in this build.  In
     * particular, libdrm/GBM/EGL alone can describe or display a dma-buf but
     * cannot encode it.  Do not change this to OK merely because ffmpeg's CLI
     * advertises NVENC/VAAPI: its rawvideo stdin path is a CPU copy.
     */
    return FB_SHM_STREAM_GPU_E_BACKEND_NOT_BUILT;
}

bool fb_shm_stream_gpu_backend_available(void)
{
    return fb_shm_stream_gpu_backend_probe() == FB_SHM_STREAM_GPU_OK;
}

static bool fb_shm_stream_gpu_name_terminated(const char *name)
{
    return memchr(name, '\0', FB_SHM_GPU_NAME_MAX) != NULL;
}

FbShmStreamGpuStatus
fb_shm_stream_gpu_validate_frame(const FbShmGpuFrame *frame,
                                 bool has_native_handle)
{
    const uint32_t known_flags = FB_SHM_GPU_FRAME_F_Y0_TOP |
                                 FB_SHM_GPU_FRAME_F_KEYED_MUTEX;

#ifdef _WIN32
    (void)has_native_handle;
#endif
    if (!frame || frame->magic != FB_SHM_MAGIC ||
        frame->version != FB_SHM_VERSION ||
        frame->size != sizeof(*frame) || frame->frame_seq == 0) {
        return FB_SHM_STREAM_GPU_E_WIRE;
    }
    if (frame->flags & ~known_flags) {
        return FB_SHM_STREAM_GPU_E_FLAGS;
    }
    if (!frame->width || !frame->height ||
        !frame->backing_width || !frame->backing_height ||
        frame->x >= frame->backing_width ||
        frame->y >= frame->backing_height ||
        frame->width > frame->backing_width - frame->x ||
        frame->height > frame->backing_height - frame->y) {
        return FB_SHM_STREAM_GPU_E_GEOMETRY;
    }
    if (!frame->stride || !frame->fourcc) {
        return FB_SHM_STREAM_GPU_E_LAYOUT;
    }
    if ((frame->fourcc == FB_SHM_FOURCC_BGR0 ||
         frame->fourcc == FB_SHM_FOURCC_BGRA) &&
        (frame->backing_width > UINT32_MAX / 4 ||
         frame->stride < frame->backing_width * 4)) {
        return FB_SHM_STREAM_GPU_E_LAYOUT;
    }
    if (!fb_shm_stream_gpu_name_terminated(frame->handle_name)) {
        return FB_SHM_STREAM_GPU_E_HANDLE_NAME;
    }

    switch (frame->handle_type) {
    case FB_SHM_GPU_HANDLE_DMA_BUF:
#ifdef _WIN32
        return FB_SHM_STREAM_GPU_E_PLATFORM_HANDLE;
#else
        if (!has_native_handle) {
            return FB_SHM_STREAM_GPU_E_HANDLE_MISSING;
        }
        if (frame->handle_name[0]) {
            return FB_SHM_STREAM_GPU_E_HANDLE_NAME;
        }
        if (frame->flags & FB_SHM_GPU_FRAME_F_KEYED_MUTEX) {
            return FB_SHM_STREAM_GPU_E_FLAGS;
        }
        return FB_SHM_STREAM_GPU_OK;
#endif

    case FB_SHM_GPU_HANDLE_D3D11_TEXTURE:
#ifndef _WIN32
        return FB_SHM_STREAM_GPU_E_PLATFORM_HANDLE;
#else
        if (!frame->handle_name[0]) {
            return FB_SHM_STREAM_GPU_E_HANDLE_MISSING;
        }
        if (frame->modifier != 0) {
            return FB_SHM_STREAM_GPU_E_LAYOUT;
        }
        /*
         * Opening a named texture is not sufficient synchronization.  QEMU
         * and an asynchronous encoder must use a keyed mutex (or a future
         * fence protocol) before this can be called zero-copy safely.
         */
        if (!(frame->flags & FB_SHM_GPU_FRAME_F_KEYED_MUTEX)) {
            return FB_SHM_STREAM_GPU_E_SYNC_UNSAFE;
        }
        return FB_SHM_STREAM_GPU_OK;
#endif

    default:
        return FB_SHM_STREAM_GPU_E_HANDLE_TYPE;
    }
}

const char *fb_shm_stream_gpu_status_code(FbShmStreamGpuStatus status)
{
    switch (status) {
    case FB_SHM_STREAM_GPU_OK:
        return "GPU_OK";
    case FB_SHM_STREAM_GPU_E_BACKEND_NOT_BUILT:
        return "GPU_E_BACKEND_NOT_BUILT";
    case FB_SHM_STREAM_GPU_E_WIRE:
        return "GPU_E_WIRE";
    case FB_SHM_STREAM_GPU_E_GEOMETRY:
        return "GPU_E_GEOMETRY";
    case FB_SHM_STREAM_GPU_E_LAYOUT:
        return "GPU_E_LAYOUT";
    case FB_SHM_STREAM_GPU_E_FLAGS:
        return "GPU_E_FLAGS";
    case FB_SHM_STREAM_GPU_E_HANDLE_TYPE:
        return "GPU_E_HANDLE_TYPE";
    case FB_SHM_STREAM_GPU_E_HANDLE_MISSING:
        return "GPU_E_HANDLE_MISSING";
    case FB_SHM_STREAM_GPU_E_PLATFORM_HANDLE:
        return "GPU_E_PLATFORM_HANDLE";
    case FB_SHM_STREAM_GPU_E_HANDLE_NAME:
        return "GPU_E_HANDLE_NAME";
    case FB_SHM_STREAM_GPU_E_SYNC_UNSAFE:
        return "GPU_E_SYNC_UNSAFE";
    default:
        return "GPU_E_UNKNOWN";
    }
}

const char *fb_shm_stream_gpu_status_message(FbShmStreamGpuStatus status)
{
    switch (status) {
    case FB_SHM_STREAM_GPU_OK:
        return "native GPU import and encoding are available";
    case FB_SHM_STREAM_GPU_E_BACKEND_NOT_BUILT:
        return "no native dma-buf/D3D11 import encoder is built; the ffmpeg "
               "rawvideo pipe is CPU-backed and is not a zero-copy fallback";
    case FB_SHM_STREAM_GPU_E_WIRE:
        return "invalid GPU frame wire header or sequence";
    case FB_SHM_STREAM_GPU_E_GEOMETRY:
        return "GPU frame ROI lies outside its backing resource";
    case FB_SHM_STREAM_GPU_E_LAYOUT:
        return "invalid GPU frame stride, format or modifier layout";
    case FB_SHM_STREAM_GPU_E_FLAGS:
        return "unsupported GPU frame flags";
    case FB_SHM_STREAM_GPU_E_HANDLE_TYPE:
        return "unsupported GPU handle type";
    case FB_SHM_STREAM_GPU_E_HANDLE_MISSING:
        return "GPU frame is missing its native handle";
    case FB_SHM_STREAM_GPU_E_PLATFORM_HANDLE:
        return "GPU handle type does not match this host platform";
    case FB_SHM_STREAM_GPU_E_HANDLE_NAME:
        return "invalid GPU shared-resource name";
    case FB_SHM_STREAM_GPU_E_SYNC_UNSAFE:
        return "shared GPU resource has no safe producer/consumer "
               "synchronization";
    default:
        return "unknown GPU capability error";
    }
}

void fb_shm_stream_gpu_print_capabilities(FILE *stream)
{
    FbShmStreamGpuStatus status = fb_shm_stream_gpu_backend_probe();

    fprintf(stream,
            "gpu.zero-copy=%s\n"
            "gpu.backend=%s\n"
            "gpu.native-handle-import=%s\n"
            "gpu.strict-shm-fallback=no\n"
            "gpu.transport=%s\n"
            "build.libavcodec=%s\n"
            "build.libavutil=%s\n"
            "build.libavformat=%s\n"
            "build.libdrm=%s\n"
            "build.libva=%s\n"
            "build.cuda=%s\n"
            "build.ffnvcodec=%s\n"
            "gpu.status=%s\n"
            "gpu.reason=%s\n",
            status == FB_SHM_STREAM_GPU_OK ? "yes" : "no",
            status == FB_SHM_STREAM_GPU_OK ? "native" : "none",
            status == FB_SHM_STREAM_GPU_OK ? "yes" : "no",
#ifdef _WIN32
            "d3d11-named-texture",
#else
            "dma-buf-scm-rights",
#endif
            FB_SHM_STREAM_HAVE_LIBAVCODEC ? "yes" : "no",
            FB_SHM_STREAM_HAVE_LIBAVUTIL ? "yes" : "no",
            FB_SHM_STREAM_HAVE_LIBAVFORMAT ? "yes" : "no",
            FB_SHM_STREAM_HAVE_LIBDRM ? "yes" : "no",
            FB_SHM_STREAM_HAVE_LIBVA ? "yes" : "no",
            FB_SHM_STREAM_HAVE_CUDA ? "yes" : "no",
            FB_SHM_STREAM_HAVE_FFNVCODEC ? "yes" : "no",
            fb_shm_stream_gpu_status_code(status),
            fb_shm_stream_gpu_status_message(status));
}
