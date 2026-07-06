/*
 * Native fb-shm stream pacing helpers.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 推流端必须按稳定节拍喂给 ffmpeg，而不能在 QEMU 发出 doorbell 后立刻
 * 补写所有积压帧。这里集中处理单调时钟、帧间隔和“落后后丢节拍不追帧”
 * 的规则，主循环只需要维护最新一帧即可。
 */

#include "common.h"

#ifndef _WIN32
#include <time.h>
#endif

#define FB_SHM_STREAM_NS_PER_SEC 1000000000ull
#define FB_SHM_STREAM_NS_PER_MS  1000000ull
#define FB_SHM_STREAM_MIN_FPS    1u
#define FB_SHM_STREAM_MAX_FPS    240u

static uint32_t fb_shm_stream_clamp_fps(uint32_t fps)
{
    if (fps < FB_SHM_STREAM_MIN_FPS) {
        return FB_SHM_STREAM_MIN_FPS;
    }
    if (fps > FB_SHM_STREAM_MAX_FPS) {
        return FB_SHM_STREAM_MAX_FPS;
    }
    return fps;
}

uint64_t fb_shm_stream_monotonic_ns(void)
{
#ifdef _WIN32
    return (uint64_t)GetTickCount64() * FB_SHM_STREAM_NS_PER_MS;
#else
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * FB_SHM_STREAM_NS_PER_SEC +
           (uint64_t)ts.tv_nsec;
#endif
}

void fb_shm_stream_pacer_reset(StreamPacer *p, uint32_t fps)
{
    uint32_t clamped_fps = fb_shm_stream_clamp_fps(fps);

    memset(p, 0, sizeof(*p));
    p->interval_ns = (FB_SHM_STREAM_NS_PER_SEC + clamped_fps / 2) /
                     clamped_fps;
}

void fb_shm_stream_pacer_start(StreamPacer *p, uint64_t now_ns)
{
    p->next_frame_ns = now_ns;
    p->started = true;
}

int fb_shm_stream_pacer_wait_ms(const StreamPacer *p, uint64_t now_ns)
{
    uint64_t delta_ns;
    uint64_t timeout_ms;

    if (!p->started || now_ns >= p->next_frame_ns) {
        return 0;
    }

    delta_ns = p->next_frame_ns - now_ns;
    timeout_ms = (delta_ns + FB_SHM_STREAM_NS_PER_MS - 1) /
                 FB_SHM_STREAM_NS_PER_MS;
    return (int)(timeout_ms > 1000 ? 1000 : timeout_ms);
}

void fb_shm_stream_pacer_finish_frame(StreamPacer *p, uint64_t now_ns)
{
    uint64_t next_ns;

    if (!p->started) {
        fb_shm_stream_pacer_start(p, now_ns);
    }

    next_ns = p->next_frame_ns + p->interval_ns;
    /*
     * fwrite()/编码器/网络偶发阻塞后，不循环补发已经错过的节拍。直接从当前
     * 时间重新排下一帧，视觉上表现为丢帧或短暂停顿，而不是快进追帧。
     */
    if (now_ns > next_ns + p->interval_ns) {
        p->next_frame_ns = now_ns + p->interval_ns;
    } else {
        p->next_frame_ns = next_ns;
    }
}
