/*
 * fb-shm synchronized GPU-frame protocol tests.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/fb-shm-gpu-sync.h"

static void test_hello_flags(void)
{
    g_assert_true(fb_shm_gpu_hello_flags_valid(0));
    g_assert_true(fb_shm_gpu_hello_flags_valid(
        FB_SHM_HELLO_F_GPU_FRAMES | FB_SHM_HELLO_F_GPU_REQUIRED |
        FB_SHM_HELLO_F_GPU_SYNC));
    g_assert_false(fb_shm_gpu_hello_flags_valid(
        FB_SHM_HELLO_F_GPU_REQUIRED));
    g_assert_false(fb_shm_gpu_hello_flags_valid(
        FB_SHM_HELLO_F_GPU_SYNC));
}

static void test_pending_owner_and_sequence(void)
{
    FbShmGpuPendingFrame state = { 0 };
    int first_owner = 1;
    int second_owner = 2;
    const void *owner = NULL;
    uint64_t sequence = 0;

    g_assert_false(fb_shm_gpu_pending_begin(&state, NULL, 1));
    g_assert_false(fb_shm_gpu_pending_begin(&state, &first_owner, 0));
    g_assert_true(fb_shm_gpu_pending_begin(&state, &first_owner, 9));
    g_assert_true(fb_shm_gpu_pending_active(&state, &owner, &sequence));
    g_assert_true(owner == &first_owner);
    g_assert_cmpuint(sequence, ==, 9);

    g_assert_false(fb_shm_gpu_pending_begin(&state, &first_owner, 10));
    g_assert_false(fb_shm_gpu_pending_complete(&state, &second_owner, 9));
    g_assert_false(fb_shm_gpu_pending_complete(&state, &first_owner, 8));
    g_assert_true(fb_shm_gpu_pending_complete(&state, &first_owner, 9));
    g_assert_false(fb_shm_gpu_pending_complete(&state, &first_owner, 9));
    g_assert_false(fb_shm_gpu_pending_begin(&state, &first_owner, 9));
    g_assert_true(fb_shm_gpu_pending_begin(&state, &second_owner, 10));
}

static void test_pending_retire(void)
{
    FbShmGpuPendingFrame state = { 0 };
    int owner = 1;
    int stranger = 2;

    g_assert_true(fb_shm_gpu_pending_begin(&state, &owner, 42));
    g_assert_false(fb_shm_gpu_pending_retire(&state, &stranger));
    g_assert_true(fb_shm_gpu_pending_retire(&state, &owner));
    g_assert_false(fb_shm_gpu_pending_active(&state, NULL, NULL));
    g_assert_false(fb_shm_gpu_pending_begin(&state, &owner, 42));
    g_assert_true(fb_shm_gpu_pending_begin(&state, &owner, 43));
}

static void test_done_request(void)
{
    const uint64_t expected = 0xfedcba9876543210ULL;
    FbShmCtlReq req;
    uint64_t sequence = 0;

    fb_shm_gpu_done_req_init(&req, expected);
    g_assert_true(fb_shm_gpu_done_req_sequence(&req, &sequence));
    g_assert_cmpuint(sequence, ==, expected);

    req.flags = 1;
    g_assert_false(fb_shm_gpu_done_req_sequence(&req, NULL));
    fb_shm_gpu_done_req_init(&req, 0);
    g_assert_false(fb_shm_gpu_done_req_sequence(&req, NULL));
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/fb-shm-gpu-sync/hello-flags", test_hello_flags);
    g_test_add_func("/fb-shm-gpu-sync/pending-owner-sequence",
                    test_pending_owner_and_sequence);
    g_test_add_func("/fb-shm-gpu-sync/pending-retire",
                    test_pending_retire);
    g_test_add_func("/fb-shm-gpu-sync/done-request", test_done_request);
    return g_test_run();
}
