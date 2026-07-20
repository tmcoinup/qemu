/*
 * fb-shm native streamer GPU capability tests.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "tools/fb-shm-stream/common.h"

static FbShmGpuFrame valid_dma_buf_frame(void)
{
    return (FbShmGpuFrame) {
        .magic = FB_SHM_MAGIC,
        .version = FB_SHM_VERSION,
        .size = sizeof(FbShmGpuFrame),
        .handle_type = FB_SHM_GPU_HANDLE_DMA_BUF,
        .flags = FB_SHM_GPU_FRAME_F_Y0_TOP,
        .width = 640,
        .height = 360,
        .stride = 7680,
        .fourcc = FB_SHM_FOURCC_BGR0,
        .x = 32,
        .y = 24,
        .backing_width = 1920,
        .backing_height = 1080,
        .modifier = 0,
        .frame_seq = 7,
    };
}

static void test_build_capability_is_explicit(void)
{
    FbShmStreamGpuStatus status = fb_shm_stream_gpu_backend_probe();

    g_assert_cmpint(status, ==, FB_SHM_STREAM_GPU_E_BACKEND_NOT_BUILT);
    g_assert_false(fb_shm_stream_gpu_backend_available());
    g_assert_cmpstr(fb_shm_stream_gpu_status_code(status), ==,
                    "GPU_E_BACKEND_NOT_BUILT");
    g_assert_nonnull(strstr(fb_shm_stream_gpu_status_message(status),
                           "not a zero-copy fallback"));
}

static void test_valid_dma_buf_transport(void)
{
    FbShmGpuFrame frame = valid_dma_buf_frame();

#ifdef _WIN32
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, true), ==,
                    FB_SHM_STREAM_GPU_E_PLATFORM_HANDLE);
#else
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, true), ==,
                    FB_SHM_STREAM_GPU_OK);
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, false), ==,
                    FB_SHM_STREAM_GPU_E_HANDLE_MISSING);
#endif
}

static void test_rejects_bad_wire_and_geometry(void)
{
    FbShmGpuFrame frame = valid_dma_buf_frame();

    frame.version++;
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, true), ==,
                    FB_SHM_STREAM_GPU_E_WIRE);

    frame = valid_dma_buf_frame();
    frame.x = frame.backing_width - frame.width + 1;
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, true), ==,
                    FB_SHM_STREAM_GPU_E_GEOMETRY);

    frame = valid_dma_buf_frame();
    frame.stride = frame.backing_width * 4 - 1;
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, true), ==,
                    FB_SHM_STREAM_GPU_E_LAYOUT);
}

static void test_rejects_bad_handle_metadata(void)
{
    FbShmGpuFrame frame = valid_dma_buf_frame();

    frame.handle_type = 99;
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, true), ==,
                    FB_SHM_STREAM_GPU_E_HANDLE_TYPE);

    frame = valid_dma_buf_frame();
    frame.flags |= 1u << 31;
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, true), ==,
                    FB_SHM_STREAM_GPU_E_FLAGS);

    frame = valid_dma_buf_frame();
    memset(frame.handle_name, 'x', sizeof(frame.handle_name));
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, true), ==,
                    FB_SHM_STREAM_GPU_E_HANDLE_NAME);
}

static void test_d3d_requires_platform_and_sync(void)
{
    FbShmGpuFrame frame = valid_dma_buf_frame();

    frame.handle_type = FB_SHM_GPU_HANDLE_D3D11_TEXTURE;
    frame.flags = FB_SHM_GPU_FRAME_F_Y0_TOP;
    g_strlcpy(frame.handle_name, "Local\\qemu-fb-shm-test",
              sizeof(frame.handle_name));

#ifdef _WIN32
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, false), ==,
                    FB_SHM_STREAM_GPU_E_SYNC_UNSAFE);
    frame.flags |= FB_SHM_GPU_FRAME_F_KEYED_MUTEX;
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, false), ==,
                    FB_SHM_STREAM_GPU_OK);
#else
    g_assert_cmpint(fb_shm_stream_gpu_validate_frame(&frame, false), ==,
                    FB_SHM_STREAM_GPU_E_PLATFORM_HANDLE);
#endif
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/fb-shm-stream/gpu/build-capability",
                    test_build_capability_is_explicit);
    g_test_add_func("/fb-shm-stream/gpu/dma-buf-transport",
                    test_valid_dma_buf_transport);
    g_test_add_func("/fb-shm-stream/gpu/wire-and-geometry",
                    test_rejects_bad_wire_and_geometry);
    g_test_add_func("/fb-shm-stream/gpu/handle-metadata",
                    test_rejects_bad_handle_metadata);
    g_test_add_func("/fb-shm-stream/gpu/d3d-sync",
                    test_d3d_requires_platform_and_sync);
    return g_test_run();
}
