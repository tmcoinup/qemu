/*
 * fb-shm OpenGL context、FBO 与异步 PBO 生命周期。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * GL 入口借助 guard 恢复主显示 context；PBO 满队列时丢采样，
 * 不阻塞 QEMU 主事件循环。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "fb-shm-internal.h"

#ifdef CONFIG_OPENGL

void fb_shm_gl_context_leave(FbShmGlContextGuard *guard)
{
    FbShmDisplay *d;

    if (!guard->active) {
        return;
    }

    d = guard->display;
    guard->active = false;
    /*
     * 中文注释：virglrenderer 会缓存“当前 context”状态。fb-shm 若把自己的
     * 共享 context 留在当前线程，即使下一次 provider 回调重新绑定了窗口，
     * virgl 的异步 fence/资源命令仍可能基于错误缓存运行。因此所有出口（包括
     * 下方函数中的提前 return）都通过 g_auto cleanup 恢复进入前的完整
     * context + drawable/surface 绑定。
     */
    if (dpy_gl_ctx_restore_current(d->con, &guard->previous) != 0) {
        if (!d->gl_warned_context) {
            warn_report("fb-shm: cannot restore display GL context; "
                        "GL frames will not be exported");
            d->gl_warned_context = true;
        }
        d->gl_ctx_unusable = true;
    }
}

bool fb_shm_gl_context_enter(FbShmDisplay *d,
                              FbShmGlContextGuard *guard)
{
    QEMUGLContextState previous = { 0 };

    if (d->gl_ctx_unusable) {
        return false;
    }

    if (!console_has_gl(d->con)) {
        if (!d->gl_warned_context) {
            warn_report("fb-shm: GL scanout has no display GL context; "
                        "GL frames will not be exported");
            d->gl_warned_context = true;
        }
        return false;
    }

    /*
     * 中文注释：必须在创建共享 context 之前保存 provider 的完整 current
     * binding。SDL 与 GtkGLArea 的 create 回调会临时切换 context 后再恢复，
     * EGL create 本身不切换；统一在这里取值，才能覆盖三类 provider，且在
     * 多窗口场景恢复原 drawable，而不是误绑到本 console 的窗口。
     */
    dpy_gl_ctx_save_current(d->con, &previous);
    if (!d->gl_ctx) {
        /*
         * SDL/EGL 已经给 console 安装了主 GL provider。这里再创建一个
         * 共享 context，避免依赖其它 DCL 的当前 context 顺序；否则 fb-shm
         * 在 listener 链表中排在 SDL 前面时会读不到 virgl texture。
         */
        QEMUGLParams params = {
            .major_ver = 3,
            .minor_ver = 0,
        };

        d->gl_ctx = dpy_gl_ctx_create(d->con, &params);
        if (!d->gl_ctx) {
            /*
             * provider 的 create 回调按契约不应改变 current binding，但失败
             * 路径最容易受底层 SDL/GLX 驱动扰动；仍用外层快照强制恢复。
             */
            (void)dpy_gl_ctx_restore_current(d->con, &previous);
            if (!d->gl_warned_context) {
                warn_report("fb-shm: cannot create shared GL context; "
                            "GL frames will not be exported");
                d->gl_warned_context = true;
            }
            d->gl_ctx_unusable = true;
            return false;
        }
    }

    if (dpy_gl_ctx_make_current(d->con, d->gl_ctx) != 0) {
        if (!d->gl_warned_context) {
            warn_report("fb-shm: cannot make shared GL context current; "
                        "GL frames will not be exported");
            d->gl_warned_context = true;
        }
        /*
         * 中文注释：某些 SDL/GLX 宿主驱动会在 make-current 失败后留下一个
         * 非 NULL 但 GLX 侧无效的 context。若退出时继续 SDL_GL_DeleteContext，
         * Xlib 默认错误处理器会因 GLXBadContext 直接终止 QEMU。fb-shm 只是
         * 旁路推流通道，这里选择永久禁用本 DCL 的 GL 读回并泄漏这个坏 context
         * 到进程退出，避免辅助通道失败带崩整台 VM。
         */
        d->gl_ctx_unusable = true;
        d->gl_ctx = NULL;
        /*
         * make-current 失败也可能扰动驱动状态；尽力恢复 provider，不能把
         * 辅助推流失败扩散成主窗口或 virglrenderer 的上下文错误。
         */
        (void)dpy_gl_ctx_restore_current(d->con, &previous);
        return false;
    }

    guard->display = d;
    guard->previous = previous;
    guard->active = true;
    return true;
}

static bool fb_shm_gl_pbo_can_use(FbShmDisplay *d)
{
    int gl_version;
    bool is_desktop;
    bool has_pbo;
    bool has_sync;

    if (d->gl_pbo_checked) {
        return d->gl_pbo_supported;
    }

    /*
     * PBO 把 glReadPixels 变成“先排队、后取结果”，但没有 fence 就无法
     * 非阻塞判断结果是否已经完成。这里要求 PBO + sync 同时可用，否则
     * 回落到同步读回，保证 SDL 窗口和推流链路仍然可用。
     */
    gl_version = epoxy_gl_version();
    is_desktop = epoxy_is_desktop_gl();
    has_pbo = gl_version >= 30 ||
              (is_desktop && epoxy_has_gl_extension("GL_ARB_pixel_buffer_object"));
    has_sync = (!is_desktop && gl_version >= 30) ||
               (is_desktop && (gl_version >= 32 ||
                               epoxy_has_gl_extension("GL_ARB_sync")));

    d->gl_pbo_supported = has_pbo && has_sync;
    d->gl_pbo_checked = true;
    return d->gl_pbo_supported;
}

static void fb_shm_gl_pbo_forget(FbShmGlPbo *pbo, bool delete_buffer)
{
    if (pbo->fence) {
        glDeleteSync(pbo->fence);
        pbo->fence = NULL;
    }

    if (delete_buffer && pbo->id) {
        glDeleteBuffers(1, &pbo->id);
        pbo->id = 0;
    }

    pbo->pending = false;
    if (delete_buffer) {
        pbo->bytes = 0;
    }
    pbo->w = 0;
    pbo->h = 0;
}

void fb_shm_gl_pbo_discard(FbShmDisplay *d, bool delete_buffers)
{
    for (uint32_t i = 0; i < FB_SHM_GL_PBO_COUNT; i++) {
        fb_shm_gl_pbo_forget(&d->gl_pbo[i], delete_buffers);
    }
    d->gl_pbo_head = 0;
    d->gl_pbo_tail = 0;
}

static bool fb_shm_gl_pbo_finish_one(FbShmDisplay *d, FbShmGlPbo *pbo)
{
    GLenum wait_status;
    void *pixels;
    uint32_t cur_idx;
    uint32_t next_idx;
    size_t frame_bytes;

    if (!pbo->pending) {
        return true;
    }

    wait_status = glClientWaitSync(pbo->fence, 0, 0);
    if (wait_status == GL_TIMEOUT_EXPIRED) {
        return false;
    }

    if (wait_status == GL_WAIT_FAILED) {
        if (!d->gl_warned_pbo) {
            warn_report("fb-shm: async GL PBO fence wait failed; "
                        "dropping one readback frame");
            d->gl_warned_pbo = true;
        }
        fb_shm_gl_pbo_forget(pbo, false);
        return true;
    }

    if (!d->hdr || !d->slot[0]) {
        fb_shm_gl_pbo_forget(pbo, false);
        return true;
    }

    frame_bytes = fb_shm_frame_bytes(d->cur_w, d->cur_h);
    if (pbo->bytes != frame_bytes || pbo->w != d->cur_w || pbo->h != d->cur_h) {
        fb_shm_gl_pbo_forget(pbo, false);
        return true;
    }

    glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo->id);
    pixels = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, pbo->bytes,
                              GL_MAP_READ_BIT);
    if (!pixels) {
        if (!d->gl_warned_pbo) {
            warn_report("fb-shm: async GL PBO map failed; "
                        "dropping one readback frame");
            d->gl_warned_pbo = true;
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        fb_shm_gl_pbo_forget(pbo, false);
        return true;
    }

    cur_idx = d->active_idx;
    next_idx = (cur_idx + 1) % FB_SHM_BUF_COUNT;
    memcpy(d->slot[next_idx], pixels, pbo->bytes);
    glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

    fb_shm_publish_frame(d, next_idx, pbo->w, pbo->h);
    fb_shm_gl_pbo_forget(pbo, false);
    return true;
}

void fb_shm_gl_pbo_drain(FbShmDisplay *d)
{
    FbShmGlPbo *pbo;

    while (true) {
        pbo = &d->gl_pbo[d->gl_pbo_tail];
        if (!pbo->pending) {
            return;
        }
        if (!fb_shm_gl_pbo_finish_one(d, pbo)) {
            return;
        }
        d->gl_pbo_tail = (d->gl_pbo_tail + 1) % FB_SHM_GL_PBO_COUNT;
    }
}

int fb_shm_gl_pbo_issue(FbShmDisplay *d, uint32_t rw, uint32_t rh,
                               int sx1, int sy1, int sx2, int sy2)
{
    FbShmGlPbo *pbo;
    size_t bytes = fb_shm_frame_bytes(rw, rh);

    if (!fb_shm_gl_pbo_can_use(d)) {
        return -1;
    }

    fb_shm_gl_pbo_drain(d);
    pbo = &d->gl_pbo[d->gl_pbo_head];
    if (pbo->pending) {
        /*
         * 三个 PBO 都还没完成时直接丢本次采样。这里选择稳帧而不是
         * fallback 到同步 glReadPixels，否则最慢帧会再次卡住 SDL/main loop。
         */
        return 0;
    }

    if (!pbo->id) {
        glGenBuffers(1, &pbo->id);
        if (!pbo->id) {
            if (!d->gl_warned_pbo) {
                warn_report("fb-shm: cannot allocate GL PBO; "
                            "using sync readback");
                d->gl_warned_pbo = true;
            }
            return -1;
        }
    }

    glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo->id);
    if (pbo->bytes != bytes) {
        glBufferData(GL_PIXEL_PACK_BUFFER, bytes, NULL, GL_STREAM_READ);
    }

    glBindFramebuffer(GL_READ_FRAMEBUFFER, d->gl_guest_fb.framebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, d->gl_blit_fb.framebuffer);
    glViewport(0, 0, rw, rh);
    glBlitFramebuffer(sx1, sy1, sx2, sy2,
                      0, 0, rw, rh,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindFramebuffer(GL_READ_FRAMEBUFFER, d->gl_blit_fb.framebuffer);
    glReadBuffer(GL_COLOR_ATTACHMENT0_EXT);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(0, 0, rw, rh, GL_BGRA, GL_UNSIGNED_BYTE, 0);

    pbo->fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    pbo->bytes = bytes;
    pbo->w = rw;
    pbo->h = rh;
    pbo->pending = true;
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    glFlush();

    d->gl_pbo_head = (d->gl_pbo_head + 1) % FB_SHM_GL_PBO_COUNT;
    return 1;
}

void fb_shm_gl_release_fbos(FbShmDisplay *d)
{
    g_auto(FbShmGlContextGuard) guard = { 0 };

    d->gl_dmabuf = NULL;
#ifdef _WIN32
    /* reset 前先平衡本 listener 的 GL block 引用。 */
    if (!fb_shm_d3d_cancel_pending(d)) {
        return;
    }
#endif
    fb_shm_gpu_backend_reset(d->gl_gpu_backend);

    if (!d->gl_ctx || !fb_shm_gl_context_enter(d, &guard)) {
        return;
    }

    fb_shm_gl_pbo_discard(d, true);
    egl_fb_destroy(&d->gl_guest_fb);
    egl_fb_destroy(&d->gl_blit_fb);
}

void fb_shm_gl_release(FbShmDisplay *d)
{
    fb_shm_gl_release_fbos(d);

    if (d->gl_ctx && !d->gl_ctx_unusable) {
        dpy_gl_ctx_destroy(d->con, d->gl_ctx);
        d->gl_ctx = NULL;
    }
}

#endif /* CONFIG_OPENGL */
