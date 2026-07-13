/*
 * fb-shm 控制请求解析与状态变更。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 请求层只接受定长 ABI；能力协商成功后才写入连接状态，
 * 失败 HELLO 不会占用 Windows 唯一 GPU-sync 名额。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "fb-shm-internal.h"

static void fb_shm_handle_hello(FbShmDisplay *d, FbShmClient *c,
                                const FbShmCtlReq *req)
{
    bool wants_resize;
    bool wants_names;
    bool wants_gpu;
    bool gpu_required;
    bool wants_gpu_sync;
    bool gpu_only;
    uint32_t status;

    if (c->dropping || c->fd < 0) {
        return;
    }

    wants_resize = (req->flags & FB_SHM_HELLO_F_RESIZE_NOTIFY) != 0;
    wants_names = (req->flags & FB_SHM_HELLO_F_WIN32_NAMES) != 0;
    wants_gpu = (req->flags & FB_SHM_HELLO_F_GPU_FRAMES) != 0;
    gpu_required = (req->flags & FB_SHM_HELLO_F_GPU_REQUIRED) != 0;
    wants_gpu_sync = (req->flags & FB_SHM_HELLO_F_GPU_SYNC) != 0;
    gpu_only = wants_gpu && gpu_required;
    status = (d->shm || gpu_only) ? FB_SHM_CTL_OK : FB_SHM_CTL_EBUSY;

    /*
     * 每条连接只允许一次成功 HELLO。
     * 禁止用第二个 HELLO 在帧在途时切换能力，
     * 也不能借此释放唯一 consumer 配额。
     */
    if (c->hello_done) {
        status = FB_SHM_CTL_EBUSY;
    } else if ((wants_gpu_sync || gpu_required) && !wants_gpu) {
        status = FB_SHM_CTL_EINVAL;
    }

#ifdef _WIN32
#ifndef CONFIG_OPENGL
    if (status == FB_SHM_CTL_OK && (wants_gpu_sync || gpu_only)) {
        status = FB_SHM_CTL_EUNSUPPORTED;
    }
#else
    if (status == FB_SHM_CTL_OK && gpu_only && !wants_gpu_sync) {
        /* strict 模式没有同步 ACK 就不能交付纹理。 */
        status = FB_SHM_CTL_EUNSUPPORTED;
    } else if (status == FB_SHM_CTL_OK && wants_gpu_sync &&
               (d->d3d_sync_client || d->d3d_retiring ||
                !fb_shm_d3d_console_available(d))) {
        status = FB_SHM_CTL_EBUSY;
    }
#endif
#endif

    FbShmCtlAck ack = {
        .magic  = FB_SHM_MAGIC,
        .op     = FB_SHM_CTL_HELLO,
        .status = status,
        .shm_size = (uint32_t)d->map_size,
        .width  = d->cur_w,
        .height = d->cur_h,
        .fourcc = FB_SHM_FOURCC_BGR0,
        .bpp    = 32,
    };
#ifdef _WIN32
    if (ack.status == FB_SHM_CTL_OK && d->shm) {
        Error *err = NULL;

        if (!fb_shm_win32_ensure_client_event(d, c, &err)) {
            warn_report_err(err);
            ack.status = FB_SHM_CTL_EBUSY;
        }
    }
#endif

#if defined(_WIN32) && defined(CONFIG_OPENGL)
    if (ack.status == FB_SHM_CTL_OK && wants_gpu_sync &&
        !fb_shm_d3d_console_reserve(d)) {
        ack.status = FB_SHM_CTL_EBUSY;
    }
#endif

    if (ack.status == FB_SHM_CTL_OK) {
        /*
         * 能力与平台资源均成功后才发布状态。
         * 失败 HELLO 可修正 flags 后重试，
         * 也不会占住唯一 GPU-sync 名额。
         */
        c->hello_done = true;
        c->wants_resize_notify = wants_resize;
        c->wants_win32_names = wants_names;
        c->wants_gpu_frames = wants_gpu;
        c->gpu_required = gpu_required;
        c->wants_gpu_sync = wants_gpu_sync;
#if defined(_WIN32) && defined(CONFIG_OPENGL)
        if (wants_gpu_sync) {
            d->d3d_sync_client = c;
        }
#endif
        fb_shm_update_effective_rate(d);
    }

    if (fb_shm_send_ack(d, c, &ack, true) < 0) {
        fb_shm_client_drop(c);
    }
}
/* Push the current backing-store descriptor/name to every HELLO-completed
 * client that opted into resize notifications.  Called from fb_shm_allocate
 * after the new mapping is fully published.  Failed sends drop the client. */
static void fb_shm_handle_set_roi(FbShmDisplay *d, FbShmClient *c,
                                  const FbShmCtlReq *req)
{
    if (c->dropping || c->fd < 0) {
        return;
    }

    if (req->w > FB_SHM_MAX_DIM || req->h > FB_SHM_MAX_DIM) {
        FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req->op,
                            .status = FB_SHM_CTL_EINVAL };
        if (fb_shm_send_ack(d, c, &ack, false) < 0) {
            fb_shm_client_drop(c);
        }
        return;
    }
    d->cfg_x = (uint32_t)(req->x < 0 ? 0 : req->x);
    d->cfg_y = (uint32_t)(req->y < 0 ? 0 : req->y);
    d->cfg_w = req->w;
    d->cfg_h = req->h;

    FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req->op,
                        .status = FB_SHM_CTL_OK,
                        .shm_size = (uint32_t)d->map_size,
                        .width = d->cur_w, .height = d->cur_h,
                        .fourcc = FB_SHM_FOURCC_BGR0, .bpp = 32 };
    if (fb_shm_send_ack(d, c, &ack, false) < 0) {
        fb_shm_client_drop(c);
    }
}

static void fb_shm_handle_set_rate(FbShmDisplay *d, FbShmClient *c,
                                   const FbShmCtlReq *req)
{
    if (c->dropping || c->fd < 0) {
        return;
    }

    uint32_t r = fb_shm_clamp_rate(req->rate_hz);
    if (c->wants_gpu_frames && c->gpu_required) {
        d->gpu_target_fps = r;
    } else {
        d->shm_target_fps = r;
    }
    fb_shm_update_effective_rate(d);

    FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req->op,
                        .status = FB_SHM_CTL_OK };
    if (fb_shm_send_ack(d, c, &ack, false) < 0) {
        fb_shm_client_drop(c);
    }
}

static void fb_shm_handle_gpu_frame_done(FbShmDisplay *d, FbShmClient *c,
                                         const FbShmCtlReq *req)
{
    uint64_t sequence = ((uint64_t)req->h << 32) | req->w;
    uint32_t status = FB_SHM_CTL_EUNSUPPORTED;

#if defined(_WIN32) && defined(CONFIG_OPENGL)
    uint64_t pending_sequence = 0;

    if (!sequence || !c->hello_done || !c->wants_gpu_sync ||
        d->d3d_sync_client != c ||
        !fb_shm_gpu_pending_active(&d->d3d_pending, &pending_sequence) ||
        sequence != pending_sequence) {
        status = FB_SHM_CTL_EINVAL;
    } else if (!fb_shm_gpu_backend_d3d_acquire0(d->gl_gpu_backend)) {
        if (fb_shm_gpu_backend_has_d3d_texture(d->gl_gpu_backend)) {
            /* ReleaseSync 尚不可见，可用原序列重试。 */
            status = FB_SHM_CTL_EBUSY;
        } else {
            /* abandoned/驱动错误已撤销 backing，解除 block。 */
            (void)fb_shm_gpu_pending_cancel(&d->d3d_pending, sequence);
            d->d3d_retiring = false;
            timer_del(d->d3d_reclaim_timer);
            fb_shm_d3d_set_gl_blocked(d, false);
            status = FB_SHM_CTL_EUNSUPPORTED;
        }
    } else if (fb_shm_gpu_pending_complete(&d->d3d_pending, sequence)) {
        d->d3d_retiring = false;
        timer_del(d->d3d_reclaim_timer);
        fb_shm_d3d_set_gl_blocked(d, false);
        status = FB_SHM_CTL_OK;
    } else {
        /* 状态不一致时也要平衡 mutex 与 GL block。 */
        (void)fb_shm_gpu_pending_cancel(&d->d3d_pending, sequence);
        d->d3d_retiring = false;
        timer_del(d->d3d_reclaim_timer);
        fb_shm_d3d_set_gl_blocked(d, false);
        status = FB_SHM_CTL_EINVAL;
    }
#else
    (void)sequence;
#endif

    FbShmCtlAck ack = {
        .magic = FB_SHM_MAGIC,
        .op = req->op,
        .status = status,
    };

    if (fb_shm_send_ack(d, c, &ack, false) < 0) {
        fb_shm_client_drop(c);
    }
}

void fb_shm_dispatch_request(FbShmDisplay *d, FbShmClient *c,
                                    const FbShmCtlReq *req)
{
    if (req->magic != FB_SHM_MAGIC) {
        FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = 0,
                            .status = FB_SHM_CTL_EINVAL };
        if (fb_shm_send_ack(d, c, &ack, false) < 0) {
            fb_shm_client_drop(c);
        }
        return;
    }

    switch (req->op) {
    case FB_SHM_CTL_HELLO:
        fb_shm_handle_hello(d, c, req);
        break;
    case FB_SHM_CTL_SET_ROI:
        fb_shm_handle_set_roi(d, c, req);
        break;
    case FB_SHM_CTL_SET_RATE:
        fb_shm_handle_set_rate(d, c, req);
        break;
    case FB_SHM_CTL_GPU_FRAME_DONE:
        fb_shm_handle_gpu_frame_done(d, c, req);
        break;
    case FB_SHM_CTL_BYE:
        fb_shm_client_drop(c);
        break;
    default: {
        FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req->op,
                            .status = FB_SHM_CTL_EUNSUPPORTED };
        if (fb_shm_send_ack(d, c, &ack, false) < 0) {
            fb_shm_client_drop(c);
        }
        break;
    }
    }
}
