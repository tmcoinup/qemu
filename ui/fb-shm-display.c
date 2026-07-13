/*
 * fb-shm DisplayChangeListener 与 CPU surface 帧发布。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * DCL 在刷新 tick 抓取最新完整 ROI；共享 header 使用 release-store
 * 发布 active slot 与序列号，consumer 不会观察到未写完的帧。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "fb-shm-internal.h"

static void fb_shm_gfx_switch(DisplayChangeListener *dcl,
                              DisplaySurface *new_surface)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);
#ifdef CONFIG_OPENGL
    /*
     * 中文注释：设备从 texture/dma-buf scanout 切回真实 CPU surface 时，
     * console 不一定先广播 dpy_gl_scanout_disable。主动释放旧 FBO/dma-buf
     * 并清 gl_scanout，避免 refresh 继续读取已删除纹理且跳过 CPU 帧路径。
     * GL provider 使用的 placeholder 不代表切换，不能在这里误清理。
     */
    if (d->gl_scanout &&
        (!new_surface || !surface_is_placeholder(new_surface))) {
        fb_shm_gl_scanout_disable(dcl);
    }
#endif
    if (!new_surface) {
        d->surface_present = false;
        return;
    }
    d->surface_present = !surface_is_placeholder(new_surface);
    /* Defer real allocation until next refresh tick where we have the
     * source dimensions stable.  We just remember them here. */
    uint32_t sw = surface_width(new_surface);
    uint32_t sh = surface_height(new_surface);
    if (sw == 0 || sh == 0) {
        return;
    }
    uint32_t rw, rh;
    int32_t rx, ry;
    fb_shm_resolve_roi(d, sw, sh, &rw, &rh, &rx, &ry);
    if (rw != d->cur_w || rh != d->cur_h ||
        sw != d->cur_src_w || sh != d->cur_src_h ||
        rx != d->cur_roi_x || ry != d->cur_roi_y) {
        Error *err = NULL;
        if (fb_shm_ensure_geometry(d, rw, rh, sw, sh, rx, ry, &err) < 0) {
            warn_report_err(err);
            return;
        }
    }
}

static void fb_shm_gfx_update(DisplayChangeListener *dcl,
                              int x, int y, int w, int h)
{
    /* No-op: we are refresh-driven and re-grab the whole ROI on tick.
     * Tracking dirty rects would only matter for partial-frame encoders,
     * and the consumer reads the damage_* fields directly. */
    (void)dcl; (void)x; (void)y; (void)w; (void)h;
}

static void fb_shm_commit_frame(FbShmDisplay *d, DisplaySurface *surface)
{
    uint32_t sw = surface_width(surface);
    uint32_t sh = surface_height(surface);
    uint64_t now_ns = fb_shm_now_ns();

    uint32_t rw, rh;
    int32_t rx, ry;
    fb_shm_resolve_roi(d, sw, sh, &rw, &rh, &rx, &ry);

    if (d->shm && !fb_shm_has_shm_consumers(d)) {
        return;
    }
    if (!fb_shm_rate_due(d->shm_target_fps, &d->shm_last_frame_ns, now_ns)) {
        return;
    }

    if (!d->shm || rw != d->cur_w || rh != d->cur_h ||
        sw != d->cur_src_w || sh != d->cur_src_h ||
        rx != d->cur_roi_x || ry != d->cur_roi_y) {
        Error *err = NULL;
        if (fb_shm_ensure_geometry(d, rw, rh, sw, sh, rx, ry, &err) < 0) {
            warn_report_err(err);
            return;
        }
    }

    uint32_t cur_idx = d->active_idx;
    uint32_t next_idx = (cur_idx + 1) % FB_SHM_BUF_COUNT;

    /*
     * pixman_image_composite32 covers every pixel format QEMU can hand us
     * (x8r8g8b8, r5g6b5, ...) and clips to ROI in one call.  The destination
     * is always BGR0 (= pixman_x8r8g8b8 on little-endian).
     */
    pixman_image_composite32(PIXMAN_OP_SRC,
                             surface->image, NULL, d->slot_img[next_idx],
                             rx, ry,        /* src offset (= ROI origin) */
                             0, 0,          /* mask (unused)             */
                             0, 0,          /* dst offset                */
                             (int)rw, (int)rh);

    fb_shm_publish_frame(d, next_idx, rw, rh);
}

void fb_shm_publish_frame(FbShmDisplay *d, uint32_t next_idx,
                                 uint32_t w, uint32_t h)
{
    FbShmHeader *hdr = d->hdr;

    hdr->damage_x = 0;
    hdr->damage_y = 0;
    hdr->damage_w = (int32_t)w;
    hdr->damage_h = (int32_t)h;
    hdr->ts_ns = fb_shm_now_ns();
    d->active_idx = next_idx;
    qatomic_store_release(&hdr->active_idx, next_idx);

    d->frame_seq++;
    qatomic_store_release(&hdr->frame_seq, d->frame_seq);

#ifndef _WIN32
    /*
     * Linux doorbell：每个 SHM consumer 都有独立 eventfd。SCM_RIGHTS 复制
     * 同一个 eventfd 只会复制描述符，counter 仍共享，一个 reader 会吞掉
     * 其他 reader 的唤醒；逐客户端写入才能保证多路推流互不抢事件。
     */
    FbShmClient *c;
    QLIST_FOREACH(c, &d->clients, next) {
        if (!c->dropping && c->hello_done && !c->gpu_required &&
            c->wake_eventfd >= 0) {
            uint64_t v = 1;
            ssize_t r;

            do {
                r = write(c->wake_eventfd, &v, sizeof(v));
            } while (r < 0 && errno == EINTR);
            /* counter 满只表示该 consumer 尚未 drain，不得反压 QEMU。 */
            (void)r;
        }
    }
#else
    /*
     * Win32 doorbell：每个客户端独立 auto-reset event。共享内存仍是同一块，
     * 但唤醒不共享，保证多路 RTMP/本地归档同时挂载时互不抢信号。
     */
    FbShmClient *c;
    QLIST_FOREACH(c, &d->clients, next) {
        if (!c->dropping && c->hello_done && !c->gpu_required &&
            c->wake_event) {
            SetEvent(c->wake_event);
        }
    }
#endif
}
bool fb_shm_rate_due(uint32_t rate_hz, uint64_t *last_ns,
                            uint64_t now_ns)
{
    const uint64_t slack_ns = 1000000ull;
    uint64_t interval_ns;

    rate_hz = fb_shm_clamp_rate(rate_hz);
    /*
     * DisplayChangeListener 的 update_interval 只能表达整数毫秒。这里使用同一
     * 个量化周期来做节流，避免 60Hz 被 16ms tick 驱动时又按 16.666ms 判断，
     * 周期性跳成 16/32ms；真实目标 fps 由外部 streamer 的稳定节拍保证。
     */
    interval_ns = (uint64_t)fb_shm_rate_interval_ms(rate_hz) * 1000000ull;
    if (!*last_ns) {
        *last_ns = now_ns;
        return true;
    }

    /*
     * QEMU 只发布“当前 tick 的最新帧”。如果宿主被调度走或 GL 读回慢了，
     * 不在这里补多个 deadline；消费端会重复上一帧或丢帧，避免视觉快进。
     */
    if (now_ns + slack_ns < *last_ns + interval_ns) {
        return false;
    }

    *last_ns = now_ns;
    return true;
}

static void fb_shm_refresh(DisplayChangeListener *dcl)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);

#ifdef CONFIG_OPENGL
    /*
     * fb-shm 对 GL console 是旁路 consumer，不能在 SDL/GTK 等主显示还没安装
     * GL provider 时先调用 graphic_hw_update()。否则 virtio-gpu/virgl 会在无
     * current context 的线程上进入 epoxy。普通 CPU surface 设备 flags=0，不走
     * 这个等待分支。
     */
    if ((qemu_console_get_graphic_flags(dcl->con) & GRAPHIC_FLAGS_GL) &&
        !console_has_gl(dcl->con)) {
        return;
    }
#endif

    graphic_hw_update(dcl->con);
#ifdef CONFIG_OPENGL
    if (d->gl_scanout) {
        fb_shm_commit_gl_frame(d);
        return;
    }
#endif
    if (!d->surface_present) {
        return;
    }
    DisplaySurface *surface = qemu_console_surface(dcl->con);
    if (!surface || surface_is_placeholder(surface)) {
        return;
    }
    fb_shm_commit_frame(d, surface);
}

const DisplayChangeListenerOps fb_shm_ops = {
    .dpy_name        = "fb-shm",
    .dpy_gl_sidecar  = true,
    .dpy_refresh     = fb_shm_refresh,
    .dpy_gfx_update  = fb_shm_gfx_update,
    .dpy_gfx_switch  = fb_shm_gfx_switch,
#ifdef CONFIG_OPENGL
    .dpy_gl_scanout_disable = fb_shm_gl_scanout_disable,
    .dpy_gl_scanout_texture = fb_shm_gl_scanout_texture,
    .dpy_gl_update          = fb_shm_gl_update,
#ifdef CONFIG_GBM
    .dpy_gl_scanout_dmabuf  = fb_shm_gl_scanout_dmabuf,
    .dpy_gl_scanout_dmabuf_update =
        fb_shm_gl_scanout_dmabuf,
    .dpy_gl_release_dmabuf  = fb_shm_gl_release_dmabuf,
#endif
#endif
};
