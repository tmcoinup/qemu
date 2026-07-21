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
#include "ui/sdl2.h"
#include "ui/sdl2-egl.h"

static bool sdl2_gl_make_window_current(struct sdl2_console *scon)
{
    return scon->real_window && scon->winctx &&
           SDL_GL_MakeCurrent(scon->real_window, scon->winctx) == 0;
}

static void sdl2_set_scanout_mode(struct sdl2_console *scon, bool scanout)
{
    if (scon->scanout_mode == scanout) {
        return;
    }

    scon->scanout_mode = scanout;
    if (!scon->scanout_mode) {
        scon->guest_fb.dmabuf = NULL;
        egl_fb_destroy(&scon->guest_fb);
        if (scon->surface) {
            surface_gl_destroy_texture(scon->gls, scon->surface);
            surface_gl_create_texture(scon->gls, scon->surface);
        }
    }
}

static void sdl2_gl_render_surface(struct sdl2_console *scon)
{
    SDL2Rect dst;
    SDL2Rect viewport;
    SDL2Size output;

    if (!sdl2_gl_make_window_current(scon)) {
        return;
    }

    if (!sdl2_current_render_size(scon, &output)) {
        return;
    }
    /* 原生分辨率居中，剩余区域清为深色边框。 */
    dst = sdl2_guest_dst_rect(
        output,
        (SDL2Size) {
            surface_width(scon->surface),
            surface_height(scon->surface),
        });
    /* 转换 GL 左下原点，确保渲染和指针映射对齐。 */
    viewport = sdl2_gl_viewport(output, dst);
    glViewport(viewport.x, viewport.y, viewport.width, viewport.height);

    surface_gl_render_texture(scon->gls, scon->surface);
    SDL_GL_SwapWindow(scon->real_window);
}

void sdl2_gl_update(DisplayChangeListener *dcl,
                    int x, int y, int w, int h)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    assert(scon->opengl);

    if (!sdl2_gl_make_window_current(scon)) {
        return;
    }
    if (!scon->surface->texture) {
        surface_gl_create_texture(scon->gls, scon->surface);
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

    if (scon->real_window && !sdl2_gl_make_window_current(scon)) {
        /* 先更新指针以防 UAF；旧 GL name 由 context 回收。 */
        scon->surface = new_surface;
        return;
    }
    surface_gl_destroy_texture(scon->gls, scon->surface);

    scon->surface = new_surface;

    if (surface_is_placeholder(new_surface) && qemu_console_get_index(dcl->con)) {
        qemu_gl_fini_shader(scon->gls);
        scon->gls = NULL;
        sdl2_window_destroy(scon);
        return;
    }

    if (!scon->real_window) {
        sdl2_window_create(scon);
        scon->gls = qemu_gl_init_shader();
    } else if (old_surface &&
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

    graphic_hw_update(dcl->con);
    if (scon->updates && scon->real_window) {
        scon->updates = 0;
        sdl2_gl_render_surface(scon);
    }
    if (scon->scanout_redraw_pending &&
        !qemu_console_is_gl_blocked(dcl->con)) {
        /* mutex 归还后重放积压的窗口 redraw。 */
        scon->scanout_redraw_pending = false;
        sdl2_gl_redraw(scon);
    }
    sdl2_poll_events(scon);
}

void sdl2_gl_redraw(struct sdl2_console *scon)
{
    assert(scon->opengl);

    /*
     * 中文注释：Windows fb-shm 临时交出 D3D11 scanout 时，
     * SDL 仍轮询窗口和输入事件。
     * 但 EXPOSE、焦点恢复和 resize 不能重读该 texture。
     * 正常 dpy_gl_update() 不经过本 redraw 入口，
     * 因此它自带的瞬时 block 不会导致误跳帧。
     */
    if (qemu_console_is_gl_blocked(scon->dcl.con)) {
        scon->scanout_redraw_pending = true;
        return;
    }

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
    SDL_GLContext ctx, current_ctx;
    SDL_Window *current_window;

    assert(scon->opengl);

    current_ctx = SDL_GL_GetCurrentContext();
    current_window = SDL_GL_GetCurrentWindow();

    if (!sdl2_gl_make_window_current(scon)) {
        return NULL;
    }

    SDL_GL_SetAttribute(SDL_GL_SHARE_WITH_CURRENT_CONTEXT, 1);
    if (sdl2_gl_provider_uses_gles() ||
        scon->opts->gl == DISPLAY_GL_MODE_ES) {
        /*
         * Windows gl=on 可能已由 provider 转成 ANGLE/GLES，
         * 必须继续同一 API。
         */
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                            SDL_GL_CONTEXT_PROFILE_ES);
    } else if (scon->opts->gl == DISPLAY_GL_MODE_ON ||
               scon->opts->gl == DISPLAY_GL_MODE_CORE) {
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                            SDL_GL_CONTEXT_PROFILE_CORE);
    }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, params->major_ver);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, params->minor_ver);

    ctx = SDL_GL_CreateContext(scon->real_window);

    /* gl=on 创建失败时允许 SDL 回退到 GLES。 */
    if (!ctx && scon->opts->gl == DISPLAY_GL_MODE_ON &&
        !sdl2_gl_provider_egl_committed()) {
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                            SDL_GL_CONTEXT_PROFILE_ES);
        ctx = SDL_GL_CreateContext(scon->real_window);
    }

    /*
     * 中文注释：多 console 时 current_ctx 可能属于另一个 SDL_Window。
     * context 创建无论成功或失败都必须恢复原窗口/context 对，不能把原
     * context 错绑到当前 scon 的窗口。
     */
    SDL_GL_MakeCurrent(current_window ? current_window : scon->real_window,
                       current_ctx);

    return (QEMUGLContext)ctx;
}

void sdl2_gl_save_current_context(DisplayGLCtx *dgc,
                                  QEMUGLContextState *state)
{
    /*
     * SDL 可能使用 EGL，也可能使用 GLX。
     * context 与窗口必须一起通过 SDL 查询。
     * 不能猜测底层窗口系统。
     */
    (void)dgc;
    state->ctx = (QEMUGLContext)SDL_GL_GetCurrentContext();
    state->draw = SDL_GL_GetCurrentWindow();
    state->read = state->draw;
}

int sdl2_gl_restore_current_context(DisplayGLCtx *dgc,
                                    const QEMUGLContextState *state)
{
    struct sdl2_console *scon = container_of(dgc, struct sdl2_console, dgc);
    SDL_Window *window = (SDL_Window *)state->draw;

    /*
     * 不能使用 dgc 对应的窗口代替原窗口。
     * 多输出时，原 current context 可能属于另一个 SDL 窗口。
     */
    /* 无 current context 时用本窗口执行解除绑定，兼容不接受 NULL window 的后端。 */
    if (!window) {
        window = scon->real_window;
    }
    return SDL_GL_MakeCurrent(window,
                              (SDL_GLContext)state->ctx);
}

void sdl2_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
    SDL_GLContext sdlctx = (SDL_GLContext)ctx;

    SDL_GL_DeleteContext(sdlctx);
}

int sdl2_gl_make_context_current(DisplayGLCtx *dgc,
                                 QEMUGLContext ctx)
{
    struct sdl2_console *scon = container_of(dgc, struct sdl2_console, dgc);
    SDL_GLContext sdlctx = (SDL_GLContext)ctx;

    assert(scon->opengl);

    /* ctx == NULL 会解除当前窗口的 context 绑定。 */
    return SDL_GL_MakeCurrent(scon->real_window, sdlctx);
}

void sdl2_gl_scanout_disable(DisplayChangeListener *dcl)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    assert(scon->opengl);
    scon->w = 0;
    scon->h = 0;
    if (!sdl2_gl_make_window_current(scon)) {
        /*
         * 不能把裸 FBO name 延后到可能重建的 context。
         * 最多遗失当前一个 FBO，由窗口 context 回收，避免误删 virgl FBO。
         */
        scon->scanout_mode = false;
        memset(&scon->guest_fb, 0, sizeof(scon->guest_fb));
        return;
    }
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
    if (!backing_id || !backing_width || !backing_height ||
        x >= backing_width || y >= backing_height || !w || !h ||
        backing_width > INT_MAX || backing_height > INT_MAX ||
        x > INT_MAX || y > INT_MAX || w > INT_MAX || h > INT_MAX) {
        sdl2_gl_scanout_disable(dcl);
        return;
    }

    w = MIN(w, backing_width - x);
    h = MIN(h, backing_height - y);
    scon->x = x;
    scon->y = y;
    scon->w = w;
    scon->h = h;
    scon->y0_top = backing_y_0_top;

    if (!sdl2_gl_make_window_current(scon)) {
        sdl2_gl_scanout_disable(dcl);
        return;
    }

    sdl2_set_scanout_mode(scon, true);
    egl_fb_setup_for_tex(&scon->guest_fb, backing_width, backing_height,
                         backing_id, false);
    scon->guest_fb.dmabuf = NULL;
}

/*
 * Draw only the scanout's visible sub-rectangle.  egl_fb_blit() deliberately
 * handles a whole texture (or metadata carried by a dma-buf), while the SDL
 * listener also receives plain texture scanouts whose backing allocation is
 * larger than the visible guest region.
 */
static void sdl2_gl_blit_scanout(struct sdl2_console *scon,
                                 SDL2Size output, SDL2Rect dst)
{
    SDL2Rect source = sdl2_gl_scanout_source_rect(
        (SDL2Size) {
            scon->guest_fb.width,
            scon->guest_fb.height,
        },
        (SDL2Rect) {
            scon->x,
            scon->y,
            scon->w,
            scon->h,
        },
        scon->y0_top);
    SDL2Rect viewport = sdl2_gl_viewport(output, dst);

    if (!source.width || !source.height) {
        return;
    }

    glBindFramebuffer(GL_READ_FRAMEBUFFER, scon->guest_fb.framebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    glViewport(0, 0, output.width, output.height);
    glClear(GL_COLOR_BUFFER_BIT);
    glBlitFramebuffer(source.x, source.y,
                      source.x + source.width,
                      source.y + source.height,
                      viewport.x, viewport.y,
                      viewport.x + viewport.width,
                      viewport.y + viewport.height,
                      GL_COLOR_BUFFER_BIT, GL_LINEAR);
}

void sdl2_gl_scanout_flush(DisplayChangeListener *dcl,
                           uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    SDL2Size guest;
    SDL2Size output;
    SDL2Rect dst;

    assert(scon->opengl);
    if (!scon->scanout_mode) {
        return;
    }
    if (!scon->guest_fb.framebuffer) {
        return;
    }
    if (!sdl2_current_guest_size(scon, &guest) ||
        !sdl2_current_render_size(scon, &output)) {
        return;
    }

    if (!sdl2_gl_make_window_current(scon)) {
        scon->scanout_redraw_pending = true;
        return;
    }

    /*
     * 中文注释：
     * virgl 的纹理扫描输出按可见子区域原生分辨率居中，
     * drawable 空间不足时才等比缩小。
     * 渲染和输入使用同一个目标矩形；
     * backing texture 更大时也不会显示或映射隐藏区域。
     */
    dst = sdl2_guest_dst_rect(output, guest);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    sdl2_gl_blit_scanout(scon, output, dst);

    SDL_GL_SwapWindow(scon->real_window);
    scon->scanout_redraw_pending = false;
}

#ifdef CONFIG_GBM
void sdl2_gl_scanout_dmabuf(DisplayChangeListener *dcl,
                            QemuDmaBuf *dmabuf)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    const int *fds;

    assert(scon->opengl);
    if (!sdl2_gl_make_window_current(scon)) {
        return;
    }

    egl_dmabuf_import_texture(dmabuf);
    if (!qemu_dmabuf_get_texture(dmabuf)) {
        fds = qemu_dmabuf_get_fds(dmabuf, NULL);
        error_report("%s: failed fd=%d", __func__, fds ? fds[0] : -1);
        return;
    }

    sdl2_gl_scanout_texture(dcl, qemu_dmabuf_get_texture(dmabuf),
                            qemu_dmabuf_get_y0_top(dmabuf),
                            qemu_dmabuf_get_backing_width(dmabuf),
                            qemu_dmabuf_get_backing_height(dmabuf),
                            qemu_dmabuf_get_x(dmabuf),
                            qemu_dmabuf_get_y(dmabuf),
                            qemu_dmabuf_get_width(dmabuf),
                            qemu_dmabuf_get_height(dmabuf),
                            NULL);

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
    if (!sdl2_gl_make_window_current(scon)) {
        /* 不能跨 context 删除；本次导入由 share group 回收。 */
        return;
    }
    egl_dmabuf_release_texture(dmabuf);
}

bool sdl2_gl_has_dmabuf(DisplayChangeListener *dcl)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    return scon->has_dmabuf;
}
#endif

void sdl2_gl_console_init(struct sdl2_console *scon)
{
    bool hidden = scon->hidden;

    scon->hidden = true;
    scon->surface = qemu_create_displaysurface(1, 1);
    sdl2_window_create(scon);

    /* 用隐藏 SDL 窗口打破 console 与 dma-buf 能力探测的循环依赖。 */
    scon->has_dmabuf = qemu_egl_has_dmabuf();

    sdl2_window_destroy(scon);
    qemu_free_displaysurface(scon->surface);

    scon->surface = NULL;
    scon->hidden = hidden;
}
