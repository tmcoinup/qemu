/*
 * fb-shm GPU sideband 发布与 Windows D3D11 仲裁。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Linux 复制 dma-buf fd；Windows 在 BH 中延后 keyed-mutex handoff。
 * 零拷贝失败时继续保留 SHM 兼容路径。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "fb-shm-internal.h"

#ifdef CONFIG_OPENGL

#if defined(_WIN32) && defined(CONFIG_OPENGL)
/*
 * keyed mutex 属于底层 QemuConsole scanout，
 * 不属于某个 fb-shm 对象。
 * console 可热添加多个 sidecar，必须跨实例仲裁；
 * 否则两个 backend 会同时误判自己持有 key=0。
 * 所有访问都发生在 QEMU 主线程，不需要额外锁。
 */
static GHashTable *fb_shm_d3d_console_owners;

static FbShmDisplay *fb_shm_d3d_console_owner(FbShmDisplay *d)
{
    return fb_shm_d3d_console_owners ?
           g_hash_table_lookup(fb_shm_d3d_console_owners, d->con) : NULL;
}

bool fb_shm_d3d_console_available(FbShmDisplay *d)
{
    FbShmDisplay *owner = fb_shm_d3d_console_owner(d);

    return !owner || owner == d;
}

bool fb_shm_d3d_console_reserve(FbShmDisplay *d)
{
    if (!fb_shm_d3d_console_available(d)) {
        return false;
    }
    if (!fb_shm_d3d_console_owners) {
        fb_shm_d3d_console_owners =
            g_hash_table_new(g_direct_hash, g_direct_equal);
    }
    g_hash_table_insert(fb_shm_d3d_console_owners, d->con, d);
    return true;
}

void fb_shm_d3d_console_release(FbShmDisplay *d)
{
    if (!fb_shm_d3d_console_owners ||
        fb_shm_d3d_console_owner(d) != d) {
        return;
    }
    g_hash_table_remove(fb_shm_d3d_console_owners, d->con);
    if (!g_hash_table_size(fb_shm_d3d_console_owners)) {
        g_clear_pointer(&fb_shm_d3d_console_owners, g_hash_table_destroy);
    }
}
#endif
#ifdef _WIN32
void fb_shm_d3d_set_gl_blocked(FbShmDisplay *d, bool blocked)
{
    if (d->d3d_gl_blocked == blocked) {
        return;
    }

    /*
     * graphic_hw_gl_block() 自带引用计数。
     * 这里只记录 fb-shm 持有的一份，
     * 避免断连或析构时重复 unblock。
     */
    graphic_hw_gl_block(d->con, blocked);
    d->d3d_gl_blocked = blocked;
}

#define FB_SHM_D3D_RECLAIM_RETRY_MS 10

bool fb_shm_d3d_cancel_pending(FbShmDisplay *d)
{
    uint64_t sequence;

    if (d->d3d_handoff_scheduled) {
        qemu_bh_cancel(d->d3d_handoff_bh);
        d->d3d_handoff_scheduled = false;
    }
    if (fb_shm_gpu_pending_active(&d->d3d_pending, &sequence)) {
        /*
         * 断连或 scanout 切换时只做非阻塞收回。
         * WAIT_TIMEOUT 表示 consumer 仍可能读取纹理。
         * 此时不能丢 COM 引用后立即放开 renderer，
         * 否则 producer 写与 consumer 读会竞态。
         * 保留 block 并由 timer 重试；主循环不会同步等待。
         */
        if (!fb_shm_gpu_backend_d3d_acquire0(d->gl_gpu_backend) &&
            fb_shm_gpu_backend_has_d3d_texture(d->gl_gpu_backend)) {
            if (!d->d3d_destroying) {
                d->d3d_retiring = true;
                timer_mod(d->d3d_reclaim_timer,
                          qemu_clock_get_ms(QEMU_CLOCK_REALTIME) +
                          FB_SHM_D3D_RECLAIM_RETRY_MS);
                return false;
            }
            /* 最终析构不再提交命令，可退役引用。 */
            fb_shm_gpu_backend_reset(d->gl_gpu_backend);
        }
        (void)fb_shm_gpu_pending_cancel(&d->d3d_pending, sequence);
    }

    d->d3d_retiring = false;
    timer_del(d->d3d_reclaim_timer);
    fb_shm_d3d_set_gl_blocked(d, false);
    if (!d->d3d_sync_client) {
        fb_shm_d3d_console_release(d);
    }
    return true;
}

void fb_shm_d3d_reclaim_timer_cb(void *opaque)
{
    FbShmDisplay *d = opaque;

    (void)fb_shm_d3d_cancel_pending(d);
}
#endif
static bool fb_shm_gpu_layout_init(FbShmDisplay *d,
                                   FbShmGpuFrameLayout *layout,
                                   uint32_t w, uint32_t h,
                                   int32_t roi_x, int32_t roi_y)
{
    /*
     * resolve_roi() 当前只会给出非负坐标，
     * 但 GPU sideband 是独立的安全边界，不能依赖调用顺序。
     * 先验证符号和加法空间，最终 backing 范围由
     * fb-shm-gpu-common.c 再做一次减法式校验。
     */
    if (roi_x < 0 || roi_y < 0 ||
        (uint32_t)roi_x > UINT32_MAX - d->gl_x ||
        (uint32_t)roi_y > UINT32_MAX - d->gl_y) {
        return false;
    }

    *layout = (FbShmGpuFrameLayout) {
        .width = w,
        .height = h,
        .x = d->gl_x + (uint32_t)roi_x,
        .y = d->gl_y + (uint32_t)roi_y,
        .backing_width = d->gl_backing_w,
        .backing_height = d->gl_backing_h,
        .y0_top = d->gl_y0_top,
    };
    return true;
}

static bool fb_shm_broadcast_dmabuf_frame(FbShmDisplay *d,
                                          QemuDmaBuf *dmabuf,
                                          uint32_t w, uint32_t h,
                                          int32_t roi_x, int32_t roi_y)
{
    FbShmGpuFrameLayout layout;
    FbShmGpuExport exported = { .fd = -1 };
    bool published = false;

    if (!dmabuf || !fb_shm_has_gpu_clients(d) ||
        !fb_shm_gpu_layout_init(d, &layout, w, h, roi_x, roi_y)) {
        return false;
    }

    /*
     * 平台模块负责验证单平面、zero offset、fourcc、stride
     * 和 fd 所有权。任一条件不满足都安静返回，
     * 普通 consumer 随后继续使用 SHM 帧。
     */
    if (fb_shm_gpu_export_dmabuf(d->gl_gpu_backend, dmabuf,
                                 &layout, &exported)) {
        fb_shm_broadcast_gpu_frame(d, &exported.frame, exported.fd);
        published = true;
    }
    fb_shm_gpu_export_cleanup(&exported);
    return published;
}

static bool fb_shm_broadcast_texture_dmabuf_frame(FbShmDisplay *d,
                                                  uint32_t w, uint32_t h,
                                                  int32_t roi_x,
                                                  int32_t roi_y)
{
    FbShmGpuFrameLayout layout;
#ifndef _WIN32
    FbShmGpuExport exported = { .fd = -1 };
    bool published = false;

    if (!fb_shm_has_gpu_clients(d) || !d->gl_backing_id ||
        !fb_shm_gpu_layout_init(d, &layout, w, h, roi_x, roi_y)) {
        return false;
    }

    /*
     * Linux 从当前 SDL/EGL context 导出 dma-buf。
     * 能力或 metadata 不满足时，安静继续 SHM。
     */
    if (fb_shm_gpu_export_texture(d->gl_gpu_backend, d->gl_backing_id,
                                  &layout, &exported)) {
        fb_shm_broadcast_gpu_frame(d, &exported.frame, exported.fd);
        published = true;
    }
    fb_shm_gpu_export_cleanup(&exported);
    return published;
#else
    uint64_t pending_sequence;

    if (!fb_shm_has_gpu_clients(d) || d->d3d_handoff_scheduled ||
        fb_shm_gpu_pending_active(&d->d3d_pending, &pending_sequence) ||
        !fb_shm_gpu_layout_init(d, &layout, w, h, roi_x, roi_y)) {
        return false;
    }

    /*
     * 此函数可能位于 dpy_gl_update() 遍历中。
     * 这里只记录 metadata，并用 BH 延后 ReleaseSync。
     * 整轮 DCL 返回后，SDL 与其它 listener 已读完本帧，
     * 因而窗口与零拷贝可以安全共存。
     */
    d->d3d_handoff_layout = layout;
    d->d3d_handoff_scheduled = true;
    qemu_bh_schedule(d->d3d_handoff_bh);
    return true;
#endif
}

#ifdef _WIN32
static bool fb_shm_d3d_handoff_layout_current(FbShmDisplay *d)
{
    FbShmGpuFrameLayout current;
    uint32_t rw, rh;
    int32_t rx, ry;

    if (!d->gl_scanout || !d->gl_w || !d->gl_h) {
        return false;
    }
    fb_shm_resolve_roi(d, d->gl_w, d->gl_h, &rw, &rh, &rx, &ry);
    if (!fb_shm_gpu_layout_init(d, &current, rw, rh, rx, ry)) {
        return false;
    }

    return current.width == d->d3d_handoff_layout.width &&
           current.height == d->d3d_handoff_layout.height &&
           current.x == d->d3d_handoff_layout.x &&
           current.y == d->d3d_handoff_layout.y &&
           current.backing_width == d->d3d_handoff_layout.backing_width &&
           current.backing_height == d->d3d_handoff_layout.backing_height &&
           current.y0_top == d->d3d_handoff_layout.y0_top;
}

static void fb_shm_d3d_reclaim_failed_handoff(FbShmDisplay *d)
{
    if (!fb_shm_gpu_backend_d3d_acquire0(d->gl_gpu_backend)) {
        fb_shm_gpu_backend_reset(d->gl_gpu_backend);
    }
    fb_shm_d3d_set_gl_blocked(d, false);
}

void fb_shm_d3d_handoff_bh(void *opaque)
{
    FbShmDisplay *d = opaque;
    FbShmClient *c = d->d3d_sync_client;
    FbShmGpuExport exported = { .fd = -1 };
    uint64_t pending_sequence;

    d->d3d_handoff_scheduled = false;
    if (!c || !fb_shm_client_accepts_gpu(c) ||
        fb_shm_d3d_console_owner(d) != d ||
        fb_shm_gpu_pending_active(&d->d3d_pending, &pending_sequence) ||
        !fb_shm_gpu_backend_has_d3d_texture(d->gl_gpu_backend) ||
        !fb_shm_d3d_handoff_layout_current(d)) {
        return;
    }

    /*
     * renderer block 先于 ReleaseSync，
     * 后续 guest 更新不会碰共享 texture。
     * SDL 暂缓重绘，但窗口事件仍持续轮询。
     */
    fb_shm_d3d_set_gl_blocked(d, true);
    if (!fb_shm_gpu_backend_d3d_release0(d->gl_gpu_backend)) {
        fb_shm_d3d_set_gl_blocked(d, false);
        return;
    }
    if (!fb_shm_gpu_export_texture(d->gl_gpu_backend, d->gl_backing_id,
                                   &d->d3d_handoff_layout, &exported)) {
        fb_shm_d3d_reclaim_failed_handoff(d);
        return;
    }
    if (!fb_shm_gpu_pending_begin(&d->d3d_pending,
                                  exported.frame.frame_seq)) {
        fb_shm_gpu_export_cleanup(&exported);
        fb_shm_d3d_reclaim_failed_handoff(d);
        return;
    }

    if (fb_shm_send_gpu_frame(c, &exported.frame, exported.fd) < 0) {
        if (!fb_shm_client_disconnect_errno(errno)) {
            warn_report("fb-shm: D3D11 GPU frame send failed "
                        "(errno=%d %s); dropping client fd=%d",
                        errno, strerror(errno), c->fd);
        }
        fb_shm_gpu_export_cleanup(&exported);
        fb_shm_client_drop(c);
        return;
    }
    fb_shm_gpu_export_cleanup(&exported);
}
#endif

/*
 * direct backing 不依赖 fb-shm 私有 GL context。
 * Linux QemuDmaBuf fd 可立即广播。
 * Windows 这里只安排 handoff BH；ReleaseSync 要等待
 * SDL 绘制和可选 SHM/PBO 读回完成。
 * 两者都不受 GL texture import 失败牵连。
 */
bool fb_shm_broadcast_direct_gpu_frame(FbShmDisplay *d,
                                              uint32_t w, uint32_t h,
                                              int32_t roi_x, int32_t roi_y)
{
    if (!fb_shm_has_gpu_clients(d)) {
        return false;
    }

    if (d->gl_dmabuf) {
        return fb_shm_broadcast_dmabuf_frame(
            d, d->gl_dmabuf, w, h, roi_x, roi_y);
    }

#ifdef _WIN32
    /*
     * 查询只读平台缓存，不接触 EGL/GL。
     * 确有 named D3D11 texture 时才调用导出，
     * 避免把普通 texture scanout 当成 direct。
     */
    if (fb_shm_gpu_backend_has_d3d_texture(d->gl_gpu_backend)) {
        return fb_shm_broadcast_texture_dmabuf_frame(
            d, w, h, roi_x, roi_y);
    }
#endif
    return false;
}

/*
 * Linux 普通 GL texture 仅在共享 context current 后，
 * 才能通过 EGLImage 导出 dma-buf。
 * direct dma-buf / Windows D3D11 不经过这里，
 * 确保每个 tick 只发布一种 backing。
 */
bool fb_shm_broadcast_context_texture_frame(FbShmDisplay *d,
                                                   uint32_t w, uint32_t h,
                                                   int32_t roi_x,
                                                   int32_t roi_y)
{
#ifndef _WIN32
    return fb_shm_broadcast_texture_dmabuf_frame(d, w, h, roi_x, roi_y);
#else
    (void)d;
    (void)w;
    (void)h;
    (void)roi_x;
    (void)roi_y;
    return false;
#endif
}

#endif /* CONFIG_OPENGL */
