/*
 * QEMU SDL display driver -- opengl support
 *
 * Copyright (c) 2014 Red Hat
 *
 * Authors:
 *     Gerd Hoffmann <kraxel@redhat.com>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "ui/console.h"
#include "ui/egl-context.h"
#include "ui/input.h"
#include "ui/sdl2.h"

static void sdl2_set_scanout_mode(struct sdl2_console *scon, bool scanout)
{
    if (scon->scanout_mode == scanout) {
        return;
    }

    scon->scanout_mode = scanout;
    if (!scon->scanout_mode) {
        egl_fb_destroy(&scon->guest_fb);
        if (scon->surface && scon->gls) {
            surface_gl_destroy_texture(scon->gls, scon->surface);
            surface_gl_create_texture(scon->gls, scon->surface);
        }
    }
}

static bool sdl2_gl_window_ready(struct sdl2_console *scon)
{
    if (!scon->real_window) {
        return false;
    }
    if (scon->native_egl) {
        return scon->ectx != EGL_NO_CONTEXT &&
               scon->esurface != EGL_NO_SURFACE;
    }
    return scon->winctx != NULL;
}

static int sdl2_gl_make_window_current(struct sdl2_console *scon)
{
    if (!sdl2_gl_window_ready(scon)) {
        return -1;
    }
    if (scon->native_egl) {
        if (!eglMakeCurrent(qemu_egl_display, scon->esurface,
                            scon->esurface, scon->ectx)) {
            error_report("sdl2-egl: eglMakeCurrent failed: %s",
                         qemu_egl_get_error_string());
            return -1;
        }
        return 0;
    }
    return SDL_GL_MakeCurrent(scon->real_window, scon->winctx);
}

static void sdl2_gl_swap_window(struct sdl2_console *scon)
{
    if (scon->native_egl) {
        if (!eglSwapBuffers(qemu_egl_display, scon->esurface)) {
            error_report("sdl2-egl: eglSwapBuffers failed: %s",
                         qemu_egl_get_error_string());
        }
    } else {
        SDL_GL_SwapWindow(scon->real_window);
    }
}

static int sdl2_gl_make_guest_context_current(struct sdl2_console *scon,
                                              QEMUGLContext ctx)
{
    if (scon->native_egl) {
        /*
         * 中文注释：virgl 和 fb-shm 的共享 context 只渲染/读取 FBO，不需要
         * 绑定窗口 surface。若多个 context 轮流把同一个 window surface
         * 设为 current，部分 EGL 驱动会返回 EGL_BAD_ACCESS，甚至出现 swap
         * 成功但 SDL 窗口全黑。窗口 surface 只留给 scon->ectx。
         */
        if (!eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                            EGL_NO_SURFACE, (EGLContext)ctx)) {
            error_report("sdl2-egl: guest eglMakeCurrent failed: %s",
                         qemu_egl_get_error_string());
            return -1;
        }
        return 0;
    }
    return SDL_GL_MakeCurrent(scon->real_window, (SDL_GLContext)ctx);
}

static bool sdl2_gl_ensure_window_context(struct sdl2_console *scon)
{
    if (!scon->surface) {
        scon->surface = qemu_console_surface(scon->dcl.con);
        if (!scon->surface) {
            return false;
        }
    }

    if (!scon->real_window) {
        sdl2_window_create(scon);
    }
    if (sdl2_gl_make_window_current(scon) != 0) {
        return false;
    }

    if (!scon->gls) {
        /*
         * SDL 的窗口 context 必须先 current，后续 virgl 共享 context 与
         * 普通 surface texture 都以它为根。否则 fb-shm/virgl 早刷新时会让
         * libepoxy 在没有当前 GL/EGL context 的线程上解析入口并 abort。
         */
        scon->gls = qemu_gl_init_shader();
        /*
         * 中文注释：native EGL 路径下窗口创建和 GL shader 初始化可能发生在
         * 首次 refresh/update，而不是 dpy_gfx_switch 的固定时机。shader 建好
         * 后必须立刻为当前 surface 创建 GL texture；否则第一阶段固件/主板
         * 画面仍在走普通 surface update，但渲染端没有可采样纹理，SDL 子窗口
         * 就只会显示清屏后的黑色。
         */
        if (scon->gls && scon->surface) {
            surface_gl_destroy_texture(scon->gls, scon->surface);
            surface_gl_create_texture(scon->gls, scon->surface);
        }
    }
    return scon->gls != NULL;
}

static void sdl2_gl_render_surface(struct sdl2_console *scon)
{
    int ww, wh, dx, dy, dw, dh;

    if (sdl2_gl_make_window_current(scon) != 0) {
        return;
    }
    sdl2_set_scanout_mode(scon, false);

    SDL_GetWindowSize(scon->real_window, &ww, &wh);
    /*
     * Show the guest at its native resolution (1:1) centred in the window and
     * letterbox the surplus instead of upscaling it (sdl2_gfx_dst_rect()).
     * surface_gl_render_texture() clears the whole framebuffer first, so the
     * area outside the viewport is left as the (black) border.
     */
    sdl2_gfx_dst_rect(ww, wh,
                      surface_width(scon->surface),
                      surface_height(scon->surface),
                      &dx, &dy, &dw, &dh);
    glViewport(dx, dy, dw, dh);

    surface_gl_render_texture(scon->gls, scon->surface);
    sdl2_gl_swap_window(scon);
}

void sdl2_gl_update(DisplayChangeListener *dcl,
                    int x, int y, int w, int h)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    assert(scon->opengl);

    if (!sdl2_gl_ensure_window_context(scon)) {
        return;
    }

    surface_gl_update_texture(scon->gls, scon->surface, x, y, w, h);
    scon->updates++;
}

void sdl2_gl_switch(DisplayChangeListener *dcl,
                    DisplaySurface *new_surface)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    DisplaySurface *old_surface = scon->surface;

    assert(scon->opengl);

    if (sdl2_gl_window_ready(scon) &&
        sdl2_gl_make_window_current(scon) == 0) {
        surface_gl_destroy_texture(scon->gls, old_surface);
    }

    scon->surface = new_surface;

    if (surface_is_placeholder(new_surface) && qemu_console_get_index(dcl->con)) {
        if (scon->gls) {
            qemu_gl_fini_shader(scon->gls);
        }
        scon->gls = NULL;
        sdl2_window_destroy(scon);
        return;
    }

    if (!sdl2_gl_ensure_window_context(scon)) {
        return;
    }

    if (old_surface &&
        ((surface_width(old_surface)  != surface_width(new_surface)) ||
         (surface_height(old_surface) != surface_height(new_surface)))) {
        sdl2_window_resize(scon);
    }

    surface_gl_create_texture(scon->gls, scon->surface);
}

void sdl2_gl_refresh(DisplayChangeListener *dcl)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    assert(scon->opengl);

    if (!sdl2_gl_ensure_window_context(scon)) {
        sdl2_poll_events(scon);
        return;
    }
    graphic_hw_update(dcl->con);
    if (scon->updates && scon->real_window) {
        scon->updates = 0;
        sdl2_gl_render_surface(scon);
    }
    sdl2_poll_events(scon);
}

void sdl2_gl_redraw(struct sdl2_console *scon)
{
    assert(scon->opengl);

    if (scon->scanout_mode) {
        /* sdl2_gl_scanout_flush actually only care about
         * the first argument. */
        return sdl2_gl_scanout_flush(&scon->dcl, 0, 0, 0, 0);
    }
    if (scon->surface) {
        sdl2_gl_render_surface(scon);
    }
}

QEMUGLContext sdl2_gl_create_context(DisplayGLCtx *dgc,
                                     QEMUGLParams *params)
{
    struct sdl2_console *scon = container_of(dgc, struct sdl2_console, dgc);
    SDL_GLContext ctx;

    assert(scon->opengl);

    if (!sdl2_gl_ensure_window_context(scon)) {
        return NULL;
    }

    if (scon->native_egl) {
        return qemu_egl_create_context(dgc, params);
    }

    SDL_GL_SetAttribute(SDL_GL_SHARE_WITH_CURRENT_CONTEXT, 1);
    if (scon->opts->gl == DISPLAY_GL_MODE_ON ||
        scon->opts->gl == DISPLAY_GL_MODE_CORE) {
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                            SDL_GL_CONTEXT_PROFILE_CORE);
    } else if (scon->opts->gl == DISPLAY_GL_MODE_ES) {
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                            SDL_GL_CONTEXT_PROFILE_ES);
    }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, params->major_ver);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, params->minor_ver);

    ctx = SDL_GL_CreateContext(scon->real_window);

    /* If SDL fail to create a GL context and we use the "on" flag,
     * then try to fallback to GLES.
     */
    if (!ctx && scon->opts->gl == DISPLAY_GL_MODE_ON) {
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                            SDL_GL_CONTEXT_PROFILE_ES);
        ctx = SDL_GL_CreateContext(scon->real_window);
    }
    return (QEMUGLContext)ctx;
}

void sdl2_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
    struct sdl2_console *scon = container_of(dgc, struct sdl2_console, dgc);
    SDL_GLContext sdlctx = (SDL_GLContext)ctx;

    if (scon->native_egl) {
        qemu_egl_destroy_context(dgc, ctx);
    } else {
        SDL_GL_DeleteContext(sdlctx);
    }
}

int sdl2_gl_make_context_current(DisplayGLCtx *dgc,
                                 QEMUGLContext ctx)
{
    struct sdl2_console *scon = container_of(dgc, struct sdl2_console, dgc);

    assert(scon->opengl);

    return sdl2_gl_make_guest_context_current(scon, ctx);
}

void sdl2_gl_scanout_disable(DisplayChangeListener *dcl)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    assert(scon->opengl);
    if (scon->scanout_mode && sdl2_gl_make_window_current(scon) != 0) {
        return;
    }
    scon->w = 0;
    scon->h = 0;
    sdl2_set_scanout_mode(scon, false);
}

void sdl2_gl_scanout_texture(DisplayChangeListener *dcl,
                             uint32_t backing_id,
                             bool backing_y_0_top,
                             uint32_t backing_width,
                             uint32_t backing_height,
                             uint32_t x, uint32_t y,
                             uint32_t w, uint32_t h,
                             void *d3d_tex2d)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    assert(scon->opengl);
    if (!sdl2_gl_ensure_window_context(scon)) {
        return;
    }
    scon->x = x;
    scon->y = y;
    scon->w = w;
    scon->h = h;
    scon->y0_top = backing_y_0_top;

    if (sdl2_gl_make_window_current(scon) != 0) {
        return;
    }

    sdl2_set_scanout_mode(scon, true);
    egl_fb_setup_for_tex(&scon->guest_fb, backing_width, backing_height,
                         backing_id, false);
    scon->guest_fb.dmabuf = NULL;
    if (!scon->logged_scanout_texture) {
        info_report("sdl2-gl: scanout texture active "
                    "(texture=%u %ux%u roi=%ux%u@%u,%u y0_top=%d native_egl=%d)",
                    backing_id, backing_width, backing_height, w, h, x, y,
                    backing_y_0_top, scon->native_egl);
        scon->logged_scanout_texture = true;
    }
}

#ifdef CONFIG_GBM
void sdl2_gl_scanout_dmabuf(DisplayChangeListener *dcl,
                            QemuDmaBuf *dmabuf)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    uint32_t backing_width;
    uint32_t backing_height;
    uint32_t height;
    uint32_t texture;
    uint32_t width;
    uint32_t x;
    uint32_t y;
    bool y0_top;

    assert(scon->opengl);

    if (!dmabuf) {
        sdl2_gl_scanout_disable(dcl);
        return;
    }
    if (!scon->native_egl) {
        return;
    }
    if (!sdl2_gl_ensure_window_context(scon)) {
        return;
    }
    if (sdl2_gl_make_window_current(scon) != 0) {
        return;
    }

    /*
     * 中文注释：dma-buf import 只能在 EGL current context 下执行。SDL/GLX
     * 默认路径不进入这里；native EGL 路径下导入得到本地 texture 后，复用
     * 现有 texture scanout 绘制逻辑，避免新增另一套窗口绘制代码。
     */
    egl_dmabuf_import_texture(dmabuf);
    texture = qemu_dmabuf_get_texture(dmabuf);
    if (!texture) {
        return;
    }

    x = qemu_dmabuf_get_x(dmabuf);
    y = qemu_dmabuf_get_y(dmabuf);
    width = qemu_dmabuf_get_width(dmabuf);
    height = qemu_dmabuf_get_height(dmabuf);
    backing_width = qemu_dmabuf_get_backing_width(dmabuf);
    backing_height = qemu_dmabuf_get_backing_height(dmabuf);
    y0_top = qemu_dmabuf_get_y0_top(dmabuf);

    sdl2_gl_scanout_texture(dcl, texture, y0_top, backing_width,
                            backing_height, x, y, width, height, NULL);
    if (qemu_dmabuf_get_allow_fences(dmabuf)) {
        scon->guest_fb.dmabuf = dmabuf;
    }
}

void sdl2_gl_release_dmabuf(DisplayChangeListener *dcl,
                            QemuDmaBuf *dmabuf)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    if (scon->guest_fb.dmabuf == dmabuf) {
        scon->guest_fb.dmabuf = NULL;
    }
    if (!scon->native_egl || !dmabuf) {
        return;
    }
    if (sdl2_gl_make_window_current(scon) != 0) {
        return;
    }
    egl_dmabuf_release_texture(dmabuf);
}
#endif

void sdl2_gl_scanout_flush(DisplayChangeListener *dcl,
                           uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    int ww, wh, dx, dy, dw, dh;
    GLint sy1, sy2;

    assert(scon->opengl);
    if (!scon->scanout_mode) {
        return;
    }
    if (!scon->guest_fb.framebuffer) {
        if (!scon->warned_missing_scanout_fb) {
            warn_report("sdl2-gl: scanout flush skipped: missing guest framebuffer");
            scon->warned_missing_scanout_fb = true;
        }
        return;
    }

    if (sdl2_gl_make_window_current(scon) != 0) {
        return;
    }

    SDL_GetWindowSize(scon->real_window, &ww, &wh);
    /*
     * virtio-gpu-gl (virgl) routes the scanout through this GL-texture path
     * even for a plain 2D guest, so this — not sdl2_gl_render_surface() — is
     * what draws the picture here.  Keep them consistent: show the guest at
     * its native resolution (1:1) centred in the window, letterboxed with
     * black borders instead of stretched to fill, shrinking only when the
     * window is too small (sdl2_gfx_dst_rect()).  Blit straight to the default
     * framebuffer after clearing it to black for the borders.
     */
    sdl2_gfx_dst_rect(ww, wh,
                      scon->guest_fb.width, scon->guest_fb.height,
                      &dx, &dy, &dw, &dh);
    if (!scon->logged_scanout_flush) {
        GLenum status;

        glBindFramebuffer(GL_READ_FRAMEBUFFER, scon->guest_fb.framebuffer);
        status = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER);
        info_report("sdl2-gl: scanout flush active "
                    "(window=%dx%d guest_fb=%dx%d framebuffer=%u status=0x%x "
                    "dst=%dx%d@%d,%d native_egl=%d)",
                    ww, wh, scon->guest_fb.width, scon->guest_fb.height,
                    scon->guest_fb.framebuffer, status, dw, dh, dx, dy,
                    scon->native_egl);
        scon->logged_scanout_flush = true;
    }

    if (scon->native_egl) {
        GLint sy1_native;
        GLint sy2_native;
        GLenum err;

        /*
         * 中文注释：native EGL 直接画 X11 window surface。这里不用通用
         * egl_fb_blit()，而是像稳定 SDL/GLX 路径一样显式绑定读写 FBO 与
         * buffer，避免不同 EGL 驱动对默认 draw/read buffer 初值处理不一致
         * 导致 swap 成功但窗口仍是黑屏。
         */
        sy1_native = scon->y0_top ? 0 : scon->guest_fb.height;
        sy2_native = scon->y0_top ? scon->guest_fb.height : 0;

        glBindFramebuffer(GL_READ_FRAMEBUFFER, scon->guest_fb.framebuffer);
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glDrawBuffer(GL_BACK);
        glViewport(0, 0, ww, wh);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glBlitFramebuffer(0, sy1_native, scon->guest_fb.width, sy2_native,
                          dx, dy, dx + dw, dy + dh,
                          GL_COLOR_BUFFER_BIT, GL_LINEAR);
        err = glGetError();
        if (err != GL_NO_ERROR && !scon->warned_native_egl_blit) {
            warn_report("sdl2-egl: scanout blit GL error 0x%x", err);
            scon->warned_native_egl_blit = true;
        }
    } else {
        /* guest texture is bottom-up unless y0_top: flip the source Y span */
        sy1 = scon->y0_top ? 0 : scon->guest_fb.height;
        sy2 = scon->y0_top ? scon->guest_fb.height : 0;

        glBindFramebuffer(GL_READ_FRAMEBUFFER, scon->guest_fb.framebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glViewport(0, 0, ww, wh);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glBlitFramebuffer(0, sy1, scon->guest_fb.width, sy2,
                          dx, dy, dx + dw, dy + dh,
                          GL_COLOR_BUFFER_BIT, GL_LINEAR);
    }

    sdl2_gl_swap_window(scon);
}
