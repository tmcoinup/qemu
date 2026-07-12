/*
 * fb-shm native streamer pacing tests.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "tools/fb-shm-stream/common.h"

static void test_pacer_interval_60hz(void)
{
    StreamPacer p;

    fb_shm_stream_pacer_reset(&p, 60);

    /* 60fps 的真实间隔约为 16.666667ms，不能退化成 16ms 追帧节拍。 */
    g_assert_cmpuint(p.interval_ns, >=, 16666666ull);
    g_assert_cmpuint(p.interval_ns, <=, 16666667ull);
}

static void test_pacer_wait_timeout_rounds_up(void)
{
    StreamPacer p;
    uint64_t start_ns = 1000000000ull;

    fb_shm_stream_pacer_reset(&p, 60);
    fb_shm_stream_pacer_start(&p, start_ns);
    fb_shm_stream_pacer_finish_frame(&p, start_ns);

    /*
     * 剩余不足 1ms 时仍返回 1ms，避免 poll/select 传 0 后变成忙轮询。
     */
    g_assert_cmpint(fb_shm_stream_pacer_wait_ms(
                    &p, p.next_frame_ns - 500000ull), ==, 1);
    g_assert_cmpint(fb_shm_stream_pacer_wait_ms(
                    &p, p.next_frame_ns), ==, 0);
}

static void test_pacer_drops_missed_ticks(void)
{
    StreamPacer p;
    uint64_t start_ns = 2000000000ull;
    uint64_t blocked_ns;

    fb_shm_stream_pacer_reset(&p, 60);
    fb_shm_stream_pacer_start(&p, start_ns);
    fb_shm_stream_pacer_finish_frame(&p, start_ns);

    blocked_ns = start_ns + p.interval_ns * 5;
    fb_shm_stream_pacer_finish_frame(&p, blocked_ns);

    /*
     * 编码器或网络阻塞后，下一帧从当前时间继续排，不把中间 4 个节拍补发。
     */
    g_assert_cmpuint(p.next_frame_ns, ==, blocked_ns + p.interval_ns);
}

static void test_pacer_clamps_invalid_fps(void)
{
    StreamPacer p;

    fb_shm_stream_pacer_reset(&p, 0);
    g_assert_cmpuint(p.interval_ns, ==, 1000000000ull);

    fb_shm_stream_pacer_reset(&p, 1000);
    g_assert_cmpuint(p.interval_ns, >=, 4166666ull);
    g_assert_cmpuint(p.interval_ns, <=, 4166667ull);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/fb-shm-stream/pace/interval-60hz",
                    test_pacer_interval_60hz);
    g_test_add_func("/fb-shm-stream/pace/wait-timeout-rounds-up",
                    test_pacer_wait_timeout_rounds_up);
    g_test_add_func("/fb-shm-stream/pace/drops-missed-ticks",
                    test_pacer_drops_missed_ticks);
    g_test_add_func("/fb-shm-stream/pace/clamps-invalid-fps",
                    test_pacer_clamps_invalid_fps);
    return g_test_run();
}
