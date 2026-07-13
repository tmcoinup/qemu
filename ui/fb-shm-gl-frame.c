/*
 * fb-shm GL 帧节流、读回与 DCL scanout 回调。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 本模块只决定每个 refresh tick 的发布路径；context/FBO 和
 * GPU 句柄由各自模块管理，析构边界保持独立。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "fb-shm-internal.h"

#ifdef CONFIG_OPENGL

void fb_shm_commit_gl_frame(FbShmDisplay *d)
{
    g_auto(FbShmGlContextGuard) guard = { 0 };
    uint32_t sw = d->gl_w;
    uint32_t sh = d->gl_h;
    uint32_t rw, rh;
    int32_t rx, ry;
    uint64_t now_ns;
    bool geometry_changed;
    bool has_gpu_clients;
    bool has_shm_consumers;
    bool need_shm_frame;
    bool gpu_due;
    bool gpu_published = false;
    bool need_context_gpu_export = false;
    Error *err = NULL;

    if (!d->gl_scanout || !sw || !sh) {
        return;
    }

#ifdef _WIN32
    /*
     * ReleaseSync 到 DONE 之间由 consumer 独占 texture。
     * 刷新 tick 仍轮询 socket/SDL 事件，
     * 但 fb-shm 不能再做 FBO/PBO readback。
     */
    if (d->d3d_handoff_scheduled ||
        fb_shm_gpu_pending_active(&d->d3d_pending, NULL)) {
        return;
    }
#endif

    has_gpu_clients = fb_shm_has_gpu_clients(d);
    has_shm_consumers = fb_shm_has_shm_consumers(d);
    need_shm_frame = has_shm_consumers || !d->shm;
    /*
     * 中文注释：没有任何消费者时不要进入 GL current / PBO drain 热路径。
     * 这是零拷贝实验后保留的优化；但一旦普通 SHM consumer 存在，下面必须
     * 恢复旧版顺序，先及时 drain 已完成 PBO，再按目标帧率发起下一次采样。
     */
    if (!has_gpu_clients && !need_shm_frame) {
        return;
    }

    /*
     * ROI 只依赖 scanout metadata 与配置，
     * 不依赖 GL context 或 SHM mapping。
     * 先解析 ROI；随后 GL import/context 即使失败，
     * direct backing 仍可发布相同裁剪 metadata。
     */
    fb_shm_resolve_roi(d, sw, sh, &rw, &rh, &rx, &ry);
    now_ns = fb_shm_now_ns();
    gpu_due = has_gpu_clients &&
              fb_shm_rate_due(d->gpu_target_fps,
                              &d->gl_last_frame_ns, now_ns);
#ifndef _WIN32
    if (gpu_due) {
        gpu_published = fb_shm_broadcast_direct_gpu_frame(
            d, rw, rh, rx, ry);
    }
    /*
     * direct dma-buf 不可表达或为普通 texture 时，
     * 再进入 current context 尝试 texture->dma-buf。
     */
    need_context_gpu_export = gpu_due && !gpu_published;
#endif

    /*
     * 仅 SHM/PBO 或 Linux texture 导出需要私有 context。
     * direct frame 已发布，下面的失败不会撤销通知。
     */
    if (gpu_published && !need_shm_frame) {
        goto out;
    }
    if (!need_shm_frame && !need_context_gpu_export) {
        goto out;
    }
    if (!d->gl_guest_fb.texture) {
        goto out;
    }
    if (!fb_shm_gl_context_enter(d, &guard)) {
        goto out;
    }

    geometry_changed = !d->shm || rw != d->cur_w || rh != d->cur_h ||
                       sw != d->cur_src_w || sh != d->cur_src_h ||
                       rx != d->cur_roi_x || ry != d->cur_roi_y;
    if (geometry_changed) {
        /*
         * 旧 PBO 的尺寸对应旧 memfd/ROI。几何变化时直接丢掉未发布帧，
         * 避免异步完成后写进已经替换过的 SHM view。
         */
        fb_shm_gl_pbo_discard(d, false);
        if (fb_shm_ensure_geometry(d, rw, rh, sw, sh, rx, ry, &err) < 0) {
            warn_report_err(err);
            goto out;
        }
    } else {
        fb_shm_gl_pbo_drain(d);
    }

    if (need_context_gpu_export) {
        (void)fb_shm_broadcast_context_texture_frame(d, rw, rh, rx, ry);
    }
    now_ns = fb_shm_now_ns();
    if (!need_shm_frame ||
        !fb_shm_rate_due(d->shm_target_fps, &d->shm_last_frame_ns, now_ns)) {
        goto out;
    }

    if (d->gl_blit_fb.width != rw || d->gl_blit_fb.height != rh) {
        egl_fb_destroy(&d->gl_blit_fb);
        egl_fb_setup_new_tex(&d->gl_blit_fb, rw, rh);
    }

    /*
     * virgl 给出的 texture 可能是 y0_top，也可能是传统 GL bottom-up。
     * fb-shm 对外固定输出 BGR0、top-left 语义；这里先用 blit 把 ROI
     * 归一化到 fb-shm 私有 FBO，再通过 PBO 异步读回。驱动不支持 PBO
     * 时回落到同步 glReadPixels，保证功能可用优先。
     */
    int sx1 = (int)d->gl_x + rx;
    int sx2 = sx1 + (int)rw;
    int sy1 = (int)d->gl_y + ry;
    int sy2 = sy1 + (int)rh;
    if (d->gl_y0_top) {
        /*
         * 上原点纹理：源 Y 必须绕 backing 高度做镜像，而不能只交换 sy1/sy2。
         * 简单交换仅在“整高 ROI（gl_y+ry==0 且 rh==backing_h）”时恰好成立；
         * 对任意带 y 偏移的裁剪 ROI，交换会读到偏移 2*(gl_y+ry) 的错误条带，
         * 使裁剪结果底部残留 (backing_h - 2*(gl_y+ry) - rh) 像素的过期桌面。
         * 反射后 dst 顶行对应 ROI 顶行、dst 底行对应 ROI 底行；对整高 ROI 与旧
         * 交换逐字节等价（(BH,0)），因此不改变既有正确路径的画面朝向。
         */
        int bh = (int)d->gl_backing_h;
        sy1 = bh - ((int)d->gl_y + ry);
        sy2 = bh - ((int)d->gl_y + ry + (int)rh);
    }

    int pbo_status = fb_shm_gl_pbo_issue(d, rw, rh, sx1, sy1, sx2, sy2);
    if (pbo_status >= 0) {
        goto out;
    }

    uint32_t cur_idx = d->active_idx;
    uint32_t next_idx = (cur_idx + 1) % FB_SHM_BUF_COUNT;

    glBindFramebuffer(GL_READ_FRAMEBUFFER, d->gl_guest_fb.framebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, d->gl_blit_fb.framebuffer);
    glViewport(0, 0, rw, rh);
    glBlitFramebuffer(sx1, sy1, sx2, sy2,
                      0, 0, rw, rh,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);

    egl_fb_read(d->gl_slot_surface[next_idx], &d->gl_blit_fb);
    fb_shm_publish_frame(d, next_idx, rw, rh);

out:
#ifdef _WIN32
    /*
     * D3D handoff 排在本轮 SHM/PBO 与 DCL 绘制之后。
     * 此处只安排 BH；block、Flush、Release 与通知异步执行。
     */
    if (gpu_due) {
        (void)fb_shm_broadcast_direct_gpu_frame(d, rw, rh, rx, ry);
    }
#endif
    return;
}

void fb_shm_gl_scanout_disable(DisplayChangeListener *dcl)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);

    d->gl_scanout = false;
    d->gl_last_frame_ns = 0;
    d->gl_dmabuf = NULL;
    fb_shm_gl_release_fbos(d);
}

void fb_shm_gl_scanout_texture(DisplayChangeListener *dcl,
                                      uint32_t backing_id,
                                      bool backing_y_0_top,
                                      uint32_t backing_width,
                                      uint32_t backing_height,
                                      uint32_t x, uint32_t y,
                                      uint32_t w, uint32_t h,
                                      void *d3d_tex2d)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);
    g_auto(FbShmGlContextGuard) guard = { 0 };

    if (!backing_id || !backing_width || !backing_height ||
        x >= backing_width || y >= backing_height) {
        d->gl_scanout = false;
        /*
         * 中文注释：provider 用空/越界参数表达无效 scanout 时，也必须释放
         * 上一个 texture 的 FBO/PBO；只清标志会把旧附着保留到对象析构。
         */
        fb_shm_gl_release_fbos(d);
        return;
    }

#ifdef _WIN32
    /* 新 scanout 不继承旧纹理的 pending/mutex 状态。 */
    if (!fb_shm_d3d_cancel_pending(d)) {
        return;
    }
#endif

    d->gl_scanout = true;
    d->gl_dmabuf = NULL;
    d->gl_y0_top = backing_y_0_top;
    d->gl_backing_id = backing_id;
    d->gl_backing_w = backing_width;
    d->gl_backing_h = backing_height;
    d->gl_x = x;
    d->gl_y = y;
    d->gl_w = MIN(w, backing_width - x);
    d->gl_h = MIN(h, backing_height - y);

    if (!d->gl_logged_texture_scanout) {
        info_report("fb-shm: GL texture scanout active "
                    "(%ux%u@%u,%u backing=%ux%u y0_top=%d)",
                    d->gl_w, d->gl_h, d->gl_x, d->gl_y,
                    d->gl_backing_w, d->gl_backing_h,
                    d->gl_y0_top);
        d->gl_logged_texture_scanout = true;
    }

    /*
     * Windows/ANGLE 会在平台后端保留 texture COM 引用，
     * 并创建命名 shared handle；Linux 返回 false。
     * 这是可选能力，失败不记日志，
     * 后续 GL texture -> PBO/SHM 兼容路径继续正常工作。
     */
    (void)fb_shm_gpu_backend_set_d3d_texture(
        d->gl_gpu_backend, d3d_tex2d, backing_width, backing_height);

    if (!fb_shm_gl_context_enter(d, &guard)) {
        return;
    }

    egl_fb_setup_for_tex(&d->gl_guest_fb,
                         backing_width, backing_height, backing_id, false);
}

#ifdef CONFIG_GBM
void fb_shm_gl_scanout_dmabuf(DisplayChangeListener *dcl,
                                     QemuDmaBuf *dmabuf)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);
    g_auto(FbShmGlContextGuard) guard = { 0 };
    const uint32_t *strides;
    const int *fds;
    uint32_t texture;

    if (!dmabuf) {
        d->gl_scanout = false;
        /* NULL dma-buf 与显式 disable 等价，不能保留上一帧的私有 FBO。 */
        fb_shm_gl_release_fbos(d);
        return;
    }

    d->gl_scanout = true;
    d->gl_dmabuf = dmabuf;
    d->gl_y0_top = qemu_dmabuf_get_y0_top(dmabuf);
    d->gl_backing_w = qemu_dmabuf_get_backing_width(dmabuf);
    d->gl_backing_h = qemu_dmabuf_get_backing_height(dmabuf);
    d->gl_x = qemu_dmabuf_get_x(dmabuf);
    d->gl_y = qemu_dmabuf_get_y(dmabuf);
    d->gl_w = qemu_dmabuf_get_width(dmabuf);
    d->gl_h = qemu_dmabuf_get_height(dmabuf);
    strides = qemu_dmabuf_get_strides(dmabuf, NULL);
    fds = qemu_dmabuf_get_fds(dmabuf, NULL);

    if (!d->gl_logged_dmabuf_scanout) {
        info_report("fb-shm: dma-buf scanout active "
                    "(%ux%u backing=%ux%u stride=%u fd=%d)",
                    d->gl_w, d->gl_h,
                    d->gl_backing_w, d->gl_backing_h,
                    strides[0], fds[0]);
        d->gl_logged_dmabuf_scanout = true;
    }

    /*
     * Linux dma-buf 是真正的 GPU 零拷贝来源：GPU consumer 可以直接使用
     * fd，不需要 QEMU 先导入 GL texture。只有 SHM 兼容读回才需要导入；
     * SDL_GL/GLX 路径下 EGL 导入可能不可用，此时仍然保留 GPU metadata。
     */
    if (!fb_shm_gl_context_enter(d, &guard)) {
        return;
    }
    egl_dmabuf_import_texture(dmabuf);
    texture = qemu_dmabuf_get_texture(dmabuf);
    if (!texture) {
        egl_fb_destroy(&d->gl_guest_fb);
        d->gl_backing_id = 0;
        return;
    }

    d->gl_backing_id = texture;
    egl_fb_setup_for_tex(&d->gl_guest_fb, d->gl_backing_w,
                         d->gl_backing_h, texture, false);
}

void fb_shm_gl_release_dmabuf(DisplayChangeListener *dcl,
                                     QemuDmaBuf *dmabuf)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);
    g_auto(FbShmGlContextGuard) guard = { 0 };

    if (d->gl_dmabuf == dmabuf) {
        d->gl_dmabuf = NULL;
    }
    if (!fb_shm_gl_context_enter(d, &guard)) {
        return;
    }
    egl_dmabuf_release_texture(dmabuf);
}
#endif

void fb_shm_gl_update(DisplayChangeListener *dcl,
                             uint32_t x, uint32_t y,
                             uint32_t w, uint32_t h)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);

    (void)x; (void)y; (void)w; (void)h;
    fb_shm_commit_gl_frame(d);
}

#endif /* CONFIG_OPENGL */
