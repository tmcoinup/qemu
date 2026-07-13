/*
 * fb-shm GPU sideband 平台无关元数据单元测试。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/fb-shm-gpu.h"

static FbShmGpuFrameLayout test_layout(void)
{
    return (FbShmGpuFrameLayout) {
        .width = 640,
        .height = 360,
        .x = 32,
        .y = 24,
        .backing_width = 1920,
        .backing_height = 1080,
        .y0_top = true,
    };
}

static void test_dma_buf_frame(void)
{
    FbShmGpuFrameLayout layout = test_layout();
    FbShmGpuFrame frame;

    g_assert_true(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
        7680, FB_SHM_FOURCC_BGR0, 0x1234, 7, NULL));

    g_assert_cmpuint(frame.magic, ==, FB_SHM_MAGIC);
    g_assert_cmpuint(frame.version, ==, FB_SHM_VERSION);
    g_assert_cmpuint(frame.size, ==, sizeof(frame));
    g_assert_cmpuint(frame.handle_type, ==, FB_SHM_GPU_HANDLE_DMA_BUF);
    g_assert_cmpuint(frame.flags, ==, FB_SHM_GPU_FRAME_F_Y0_TOP);
    g_assert_cmpuint(frame.width, ==, layout.width);
    g_assert_cmpuint(frame.height, ==, layout.height);
    g_assert_cmpuint(frame.x, ==, layout.x);
    g_assert_cmpuint(frame.y, ==, layout.y);
    g_assert_cmpuint(frame.backing_width, ==, layout.backing_width);
    g_assert_cmpuint(frame.backing_height, ==, layout.backing_height);
    g_assert_cmpuint(frame.stride, ==, 7680);
    g_assert_cmpuint(frame.fourcc, ==, FB_SHM_FOURCC_BGR0);
    g_assert_cmpuint(frame.modifier, ==, 0x1234);
    g_assert_cmpuint(frame.frame_seq, ==, 7);
    g_assert_cmpstr(frame.handle_name, ==, "");
}

static void test_d3d11_frame(void)
{
    static const char name[] = "Local\\qemu-fb-shm-test-d3d-1";
    FbShmGpuFrameLayout layout = test_layout();
    FbShmGpuFrame frame;

    layout.y0_top = false;
    g_assert_true(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_D3D11_TEXTURE,
        FB_SHM_GPU_FRAME_F_KEYED_MUTEX, 7680, FB_SHM_FOURCC_BGRA,
        0, 11, name));

    g_assert_cmpuint(frame.handle_type, ==,
                     FB_SHM_GPU_HANDLE_D3D11_TEXTURE);
    g_assert_cmpuint(frame.flags, ==, FB_SHM_GPU_FRAME_F_KEYED_MUTEX);
    g_assert_cmpstr(frame.handle_name, ==, name);
}

static void test_rejects_invalid_layout(void)
{
    FbShmGpuFrameLayout layout = test_layout();
    FbShmGpuFrame frame;

    layout.width = 0;
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
        7680, FB_SHM_FOURCC_BGR0, 0, 1, NULL));

    /*
     * x 接近 UINT32_MAX 时，x + width 会回绕；构造器必须先
     * 验证原点，再用 backing_width - x 的形式拒绝该输入。
     */
    layout = test_layout();
    layout.x = UINT32_MAX - 3;
    layout.width = 8;
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
        7680, FB_SHM_FOURCC_BGR0, 0, 1, NULL));

    layout = test_layout();
    layout.x = layout.backing_width - layout.width + 1;
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
        7680, FB_SHM_FOURCC_BGR0, 0, 1, NULL));

    layout = test_layout();
    layout.y = layout.backing_height;
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
        7680, FB_SHM_FOURCC_BGR0, 0, 1, NULL));
}

static void test_rejects_invalid_metadata(void)
{
    FbShmGpuFrameLayout layout = test_layout();
    FbShmGpuFrame frame;
    char long_name[FB_SHM_GPU_NAME_MAX + 1];

    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_NONE, 0,
        7680, FB_SHM_FOURCC_BGR0, 0, 1, NULL));
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
        0, FB_SHM_FOURCC_BGR0, 0, 1, NULL));
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
        7680, 0, 0, 1, NULL));
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
        7680, FB_SHM_FOURCC_BGR0, 0, 0, NULL));
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF,
        1u << 31, 7680, FB_SHM_FOURCC_BGR0, 0, 1, NULL));
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF,
        FB_SHM_GPU_FRAME_F_KEYED_MUTEX,
        7680, FB_SHM_FOURCC_BGR0, 0, 1, NULL));

    /* dma-buf 只通过 SCM_RIGHTS 传 fd，不得携带 Windows 名称。 */
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
        7680, FB_SHM_FOURCC_BGR0, 0, 1, "unexpected"));
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_D3D11_TEXTURE, 0,
        7680, FB_SHM_FOURCC_BGRA, 0, 1, NULL));
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_D3D11_TEXTURE, 0,
        7680, FB_SHM_FOURCC_BGRA, 0, 1,
        "Local\\qemu-fb-shm-missing-keyed-mutex"));

    memset(long_name, 'x', sizeof(long_name));
    long_name[sizeof(long_name) - 1] = '\0';
    g_assert_false(fb_shm_gpu_frame_build(
        &frame, &layout, FB_SHM_GPU_HANDLE_D3D11_TEXTURE, 0,
        7680, FB_SHM_FOURCC_BGRA, 0, 1, long_name));
}

static void test_pending_complete_sequence(void)
{
    FbShmGpuPendingFrame state = { 0 };
    uint64_t pending = 0;

    g_assert_false(fb_shm_gpu_pending_active(&state, &pending));
    g_assert_false(fb_shm_gpu_pending_begin(&state, 0));
    g_assert_true(fb_shm_gpu_pending_begin(&state, 10));
    g_assert_true(fb_shm_gpu_pending_active(&state, &pending));
    g_assert_cmpuint(pending, ==, 10);

    /* ACK 前禁止同序列重发，也不能用新帧覆盖在途帧。 */
    g_assert_false(fb_shm_gpu_pending_begin(&state, 10));
    g_assert_false(fb_shm_gpu_pending_begin(&state, 11));

    /* 错误、过期和未来 ACK 都不能改变当前 pending sequence。 */
    g_assert_false(fb_shm_gpu_pending_complete(&state, 0));
    g_assert_false(fb_shm_gpu_pending_complete(&state, 9));
    g_assert_false(fb_shm_gpu_pending_complete(&state, 11));
    g_assert_true(fb_shm_gpu_pending_active(&state, &pending));
    g_assert_cmpuint(pending, ==, 10);

    g_assert_true(fb_shm_gpu_pending_complete(&state, 10));
    g_assert_false(fb_shm_gpu_pending_active(&state, NULL));
    g_assert_false(fb_shm_gpu_pending_complete(&state, 10));

    /* 完成后仍保留上界，旧帧不能再次 pending。 */
    g_assert_false(fb_shm_gpu_pending_begin(&state, 9));
    g_assert_false(fb_shm_gpu_pending_begin(&state, 10));
    g_assert_true(fb_shm_gpu_pending_begin(&state, 11));
}

static void test_pending_cancel_sequence(void)
{
    FbShmGpuPendingFrame state = { 0 };
    uint64_t pending = 0;

    g_assert_true(fb_shm_gpu_pending_begin(&state, 42));
    g_assert_false(fb_shm_gpu_pending_cancel(&state, 41));
    g_assert_true(fb_shm_gpu_pending_active(&state, &pending));
    g_assert_cmpuint(pending, ==, 42);

    g_assert_true(fb_shm_gpu_pending_cancel(&state, 42));
    g_assert_false(fb_shm_gpu_pending_active(&state, NULL));
    g_assert_false(fb_shm_gpu_pending_cancel(&state, 42));
    g_assert_false(fb_shm_gpu_pending_begin(&state, 42));
    g_assert_true(fb_shm_gpu_pending_begin(&state, 43));
}

#ifndef _WIN32
static void test_export_cleanup_owns_fd(void)
{
    FbShmGpuExport exported = { .fd = -1 };
    int pipefd[2];

    g_assert_cmpint(pipe(pipefd), ==, 0);
    exported.fd = pipefd[0];
    close(pipefd[1]);

    /*
     * cleanup 必须只关闭自己拥有的导出 fd，
     * 并恢复可重入初值。
     */
    fb_shm_gpu_export_cleanup(&exported);
    g_assert_cmpint(exported.fd, ==, -1);
    errno = 0;
    g_assert_cmpint(fcntl(pipefd[0], F_GETFD), ==, -1);
    g_assert_cmpint(errno, ==, EBADF);

    /* 重复 cleanup 不能关闭其他 fd 或崩溃。 */
    fb_shm_gpu_export_cleanup(&exported);
}
#endif

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/fb-shm-gpu/frame/dma-buf", test_dma_buf_frame);
    g_test_add_func("/fb-shm-gpu/frame/d3d11", test_d3d11_frame);
    g_test_add_func("/fb-shm-gpu/frame/invalid-layout",
                    test_rejects_invalid_layout);
    g_test_add_func("/fb-shm-gpu/frame/invalid-metadata",
                    test_rejects_invalid_metadata);
    g_test_add_func("/fb-shm-gpu/pending/complete-sequence",
                    test_pending_complete_sequence);
    g_test_add_func("/fb-shm-gpu/pending/cancel-sequence",
                    test_pending_cancel_sequence);
#ifndef _WIN32
    g_test_add_func("/fb-shm-gpu/export/cleanup-fd",
                    test_export_cleanup_owns_fd);
#endif
    return g_test_run();
}
