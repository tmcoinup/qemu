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
#include "qemu/main-loop.h"
#include "qemu/error-report.h"
#include "ui/console.h"
#include "ui/egl-context.h"
#include "ui/input.h"
#include "ui/sdl2.h"

#define SDL2_GL_RECOVERY_RETRY_US 100000
#define SDL2_EGL_RECOVERY_RETRY_US 100000
#define SDL2_EGL_RECOVERY_SLOW_US 1000000
#define SDL2_EGL_RECOVERY_FAST_ATTEMPTS 5

static bool sdl2_gl_create_surface_texture(struct sdl2_console *scon);
static int sdl2_native_egl_async_terminal_error = EGL_SUCCESS;

static bool sdl2_gl_egl_context_error(EGLint error)
{
    return error == EGL_CONTEXT_LOST || error == EGL_BAD_CONTEXT;
}

static bool sdl2_gl_egl_provider_error(EGLint error)
{
    return error == EGL_CONTEXT_LOST || error == EGL_BAD_DISPLAY ||
           error == EGL_NOT_INITIALIZED;
}

static bool sdl2_gl_egl_terminal_error(EGLint error)
{
    return sdl2_gl_egl_context_error(error) ||
           error == EGL_BAD_DISPLAY || error == EGL_NOT_INITIALIZED ||
           error == EGL_BAD_MATCH || error == EGL_BAD_CONFIG;
}

static void sdl2_gl_note_egl_failure(struct sdl2_console *scon,
                                     const char *operation,
                                     EGLint error)
{
    if (sdl2_gl_egl_terminal_error(error)) {
        if (sdl2_gl_egl_provider_error(error)) {
            qatomic_cmpxchg(&sdl2_native_egl_async_terminal_error,
                            EGL_SUCCESS, error);
        }
        if (!scon->native_egl_context_lost) {
            error_report("sdl2-egl: %s reported a terminal EGL failure "
                         "(EGL 0x%x); "
                         "local EGL rendering is stopped until QEMU is "
                         "normally restarted", operation, error);
        }
        scon->native_egl_context_lost = true;
        scon->native_egl_recovery_pending = false;
        scon->native_egl_recovery_after_us = 0;
        scon->scanout_replay_pending = false;
        scon->scanout_replay_after_us = 0;
        scon->window_redraw_pending = false;
        return;
    }

    /* Every other EGL error uses one bounded retry path. */
    scon->native_egl_last_error = error;
    scon->native_egl_recovery_pending = true;
    if (scon->native_egl_recovery_attempts != UINT8_MAX) {
        scon->native_egl_recovery_attempts++;
    }
    if (!scon->native_egl_recovery_after_us) {
        scon->native_egl_recovery_after_us =
            g_get_monotonic_time() +
            (scon->native_egl_recovery_attempts <=
             SDL2_EGL_RECOVERY_FAST_ATTEMPTS ?
             SDL2_EGL_RECOVERY_RETRY_US : SDL2_EGL_RECOVERY_SLOW_US);
    }
    scon->window_redraw_pending = true;
}

void sdl2_gl_native_egl_init_failed(struct sdl2_console *scon,
                                    EGLint error)
{
    sdl2_gl_note_egl_failure(scon, "window initialization", error);
}

bool sdl2_gl_native_egl_provider_failed(void)
{
    return qatomic_read(&sdl2_native_egl_async_terminal_error) != EGL_SUCCESS;
}

static void sdl2_set_scanout_mode(struct sdl2_console *scon, bool scanout)
{
    if (scon->scanout_mode == scanout) {
        return;
    }

    scon->scanout_mode = scanout;
    sdl2_pointer_geometry_changed(scon);
    if (!scon->scanout_mode) {
        egl_fb_destroy(&scon->guest_fb);
        if (scon->surface && scon->gls) {
            surface_gl_destroy_texture(scon->gls, scon->surface);
            scon->texture_recreate_pending = true;
            scon->texture_recreate_after_us = 0;
            if (sdl2_window_is_renderable(scon)) {
                sdl2_gl_create_surface_texture(scon);
            } else {
                scon->surface_upload_pending = true;
            }
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
    EGLint error;
    int current_tid;

    if (!sdl2_gl_window_ready(scon)) {
        return -1;
    }
    if (scon->native_egl) {
        current_tid = qemu_get_thread_id();
        if (scon->native_egl_context_lost ||
            scon->native_egl_recovery_pending) {
            return -1;
        }
        if (scon->native_egl_ui_tid != current_tid) {
            sdl2_gl_note_egl_failure(scon, "window context ownership",
                                     EGL_BAD_ACCESS);
            return -1;
        }
        if (!eglMakeCurrent(qemu_egl_display, scon->esurface,
                            scon->esurface, scon->ectx)) {
            error = eglGetError();
            if (!scon->warned_native_egl_make_current) {
                error_report("sdl2-egl: eglMakeCurrent failed for console %d "
                             "(thread=%d last-owner=%d EGL=0x%x); suppressing "
                             "repeated reports",
                             scon->idx, current_tid,
                             scon->native_egl_owner_tid,
                             error);
                scon->warned_native_egl_make_current = true;
            }
            sdl2_gl_note_egl_failure(scon, "eglMakeCurrent", error);
            return -1;
        }
        scon->warned_native_egl_make_current = false;
        scon->native_egl_owner_tid = current_tid;
        return 0;
    }
    return SDL_GL_MakeCurrent(scon->real_window, scon->winctx);
}

static void sdl2_gl_release_window_current(struct sdl2_console *scon)
{
    EGLint error;

    if (!scon->native_egl || eglGetCurrentContext() != scon->ectx) {
        return;
    }
    if (!eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                        EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
        error = eglGetError();
        if (!scon->warned_native_egl_release) {
            warn_report("sdl2-egl: cannot release window context for console "
                        "%d (thread=%d EGL=0x%x)",
                        scon->idx, qemu_get_thread_id(),
                        error);
            scon->warned_native_egl_release = true;
        }
        sdl2_gl_note_egl_failure(scon, "window context release", error);
        return;
    }
    scon->warned_native_egl_release = false;
    scon->native_egl_owner_tid = 0;
}

static void sdl2_gl_clear_errors(void)
{
    unsigned int i;

    for (i = 0; i < 32 && glGetError() != GL_NO_ERROR; i++) {
        /* Drain errors belonging to an earlier frontend operation. */
    }
}

static void sdl2_gl_defer_scanout_replay(struct sdl2_console *scon)
{
    if (scon->native_egl_context_lost) {
        return;
    }
    scon->scanout_replay_pending = true;
    if (!scon->scanout_replay_after_us) {
        scon->scanout_replay_after_us =
            g_get_monotonic_time() + SDL2_GL_RECOVERY_RETRY_US;
    }
    scon->window_redraw_pending = true;
}

static bool sdl2_gl_defer_hidden_scanout(struct sdl2_console *scon)
{
    if (sdl2_window_is_renderable(scon)) {
        return false;
    }

    /* Keep the producer-owned scanout authoritative without importing it. */
    sdl2_gl_defer_scanout_replay(scon);
    return true;
}

static void sdl2_gl_begin_scanout_update(struct sdl2_console *scon)
{
    if (scon->native_egl_context_lost) {
        return;
    }
    if (!scon->scanout_replay_pending) {
        scon->scanout_replay_after_us = 0;
    }
    scon->scanout_replay_pending = true;
    scon->window_redraw_pending = true;
}

static bool sdl2_gl_recover_native_egl_surface(struct sdl2_console *scon)
{
    EGLint error;

    if (!scon->native_egl_context_api &&
        !scon->native_egl_recovery_pending) {
        return true;
    }
    if (scon->native_egl_context_lost) {
        return false;
    }
    if (!scon->native_egl_recovery_pending) {
        return true;
    }
    if (g_get_monotonic_time() < scon->native_egl_recovery_after_us) {
        return false;
    }
    if (!scon->real_window) {
        /* The retry creates a new SDL parent and EGL window surface. */
        scon->native_egl_recovery_pending = false;
        scon->native_egl_recovery_after_us = 0;
        return true;
    }
    if (!sdl2_window_is_renderable(scon)) {
        return false;
    }

    if (scon->native_egl_last_error == EGL_BAD_ACCESS) {
        /* Ownership contention is retryable without replacing the surface. */
        scon->native_egl_recovery_pending = false;
        scon->native_egl_recovery_after_us = 0;
        scon->native_egl_recovery_attempts = 0;
        return true;
    }

    scon->native_egl_recovery_pending = false;
    scon->native_egl_recovery_after_us = 0;
    if (!sdl2_window_recreate_native_egl_surface(scon, &error)) {
        sdl2_gl_note_egl_failure(scon, "window surface recovery", error);
        return false;
    }

    info_report("sdl2-egl: window surface recovered for console %d",
                scon->idx);
    scon->native_egl_last_error = EGL_SUCCESS;
    scon->native_egl_recovery_attempts = 0;
    scon->warned_native_egl_make_current = false;
    scon->warned_native_egl_release = false;
    scon->warned_native_egl_swap = false;
    scon->updates = 1;
    scon->window_redraw_pending = true;
    return true;
}

static void sdl2_gl_surface_texture_failed(struct sdl2_console *scon,
                                           const char *operation,
                                           GLenum error)
{
    if (!scon->warned_gl_surface_texture) {
        warn_report("sdl2-gl: %s failed (GL 0x%x); retrying surface "
                    "texture recovery", operation, error);
        scon->warned_gl_surface_texture = true;
    }
    scon->texture_recreate_pending = true;
    scon->texture_recreate_after_us =
        g_get_monotonic_time() + SDL2_GL_RECOVERY_RETRY_US;
    scon->window_redraw_pending = true;
}

static bool sdl2_gl_create_surface_texture(struct sdl2_console *scon)
{
    GLenum error;

    if (!scon->gls || !scon->surface) {
        return false;
    }
    if (!sdl2_window_is_renderable(scon)) {
        scon->surface_upload_pending = true;
        return false;
    }
    if (scon->surface->texture && !scon->texture_recreate_pending) {
        return true;
    }
    if (scon->texture_recreate_after_us &&
        g_get_monotonic_time() < scon->texture_recreate_after_us) {
        return false;
    }

    surface_gl_destroy_texture(scon->gls, scon->surface);
    sdl2_gl_clear_errors();
    surface_gl_create_texture(scon->gls, scon->surface);
    error = glGetError();
    if (!scon->surface->texture || error != GL_NO_ERROR) {
        surface_gl_destroy_texture(scon->gls, scon->surface);
        sdl2_gl_surface_texture_failed(scon, "surface texture creation",
                                       error);
        return false;
    }

    if (scon->warned_gl_surface_texture) {
        info_report("sdl2-gl: surface texture recovered");
    }
    scon->warned_gl_surface_texture = false;
    scon->texture_recreate_pending = false;
    scon->texture_recreate_after_us = 0;
    /* glTexImage2D uploaded the complete, current DisplaySurface. */
    scon->surface_upload_pending = false;
    scon->updates = 1;
    return true;
}

static bool sdl2_gl_swap_window(struct sdl2_console *scon)
{
    EGLint error;
    bool presented = true;

    if (!sdl2_window_is_renderable(scon)) {
        return false;
    }

    if (scon->native_egl) {
        if (!eglSwapBuffers(qemu_egl_display, scon->esurface)) {
            error = eglGetError();
            if (!scon->warned_native_egl_swap) {
                error_report("sdl2-egl: eglSwapBuffers failed "
                             "(EGL=0x%x); "
                             "retaining the pending frame",
                             error);
                scon->warned_native_egl_swap = true;
            }
            sdl2_gl_note_egl_failure(scon, "eglSwapBuffers", error);
            presented = false;
            scon->window_redraw_pending = true;
        } else {
            scon->warned_native_egl_swap = false;
        }
    } else {
        SDL_GL_SwapWindow(scon->real_window);
    }
    if (presented) {
        sdl2_note_present(scon);
    }
    return presented;
}

static int sdl2_gl_make_guest_context_current(struct sdl2_console *scon,
                                              QEMUGLContext ctx)
{
    if (scon->native_egl_context_api) {
        EGLint error;
        EGLenum api = qemu_egl_mode == DISPLAY_GL_MODE_ES ?
                      EGL_OPENGL_ES_API : EGL_OPENGL_API;

        /*
         * 中文注释：virgl 和 fb-shm 的共享 context 只渲染/读取 FBO，不需要
         * 绑定窗口 surface。若多个 context 轮流把同一个 window surface
         * 设为 current，部分 EGL 驱动会返回 EGL_BAD_ACCESS，甚至出现 swap
         * 成功但 SDL 窗口全黑。窗口 surface 只留给 scon->ectx。
         */
        if (!eglBindAPI(api) ||
            !eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                            EGL_NO_SURFACE, (EGLContext)ctx)) {
            error = eglGetError();
            if (!qatomic_xchg(&scon->warned_native_egl_guest_current, true)) {
                error_report("sdl2-egl: guest eglMakeCurrent failed "
                             "(EGL=0x%x); suppressing repeated reports",
                             error);
            }
            if (sdl2_gl_egl_provider_error(error)) {
                qatomic_cmpxchg(&sdl2_native_egl_async_terminal_error,
                                EGL_SUCCESS, error);
            }
            return -1;
        }
        qatomic_set(&scon->warned_native_egl_guest_current, false);
        return 0;
    }
    return SDL_GL_MakeCurrent(scon->real_window, (SDL_GLContext)ctx);
}

static QEMUGLContext sdl2_gl_create_native_context(
    DisplayGLCtx *dgc, struct sdl2_console *scon, QEMUGLParams *params)
{
    QEMUGLContext ctx = qemu_egl_create_context(dgc, params, scon->ectx);

    if (!ctx) {
        EGLint error = eglGetError();

        error_report("sdl2-egl: shared context creation failed (EGL=0x%x)",
                     error);
        if (sdl2_gl_egl_provider_error(error)) {
            qatomic_cmpxchg(&sdl2_native_egl_async_terminal_error,
                            EGL_SUCCESS, error);
        }
    }
    return ctx;
}

static bool sdl2_gl_ensure_window_context(struct sdl2_console *scon)
{
    bool shader_created = false;

    if (scon->native_egl_context_lost) {
        return false;
    }
    if (!sdl2_gl_recover_native_egl_surface(scon)) {
        return false;
    }
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
        scon->window_redraw_pending = true;
        return false;
    }

    /*
     * A hidden console may still need its provider/root context initialized,
     * but shader setup and glTexImage2D can wait until a frame is visible.
     */
    if (!sdl2_window_is_renderable(scon)) {
        if (!scon->scanout_mode && scon->guest_fb.framebuffer) {
            egl_fb_destroy(&scon->guest_fb);
        }
        if (!scon->scanout_mode) {
            scon->surface_upload_pending = true;
        }
        return true;
    }

    if (!scon->gls) {
        /*
         * SDL 的窗口 context 必须先 current，后续 virgl 共享 context 与
         * 普通 surface texture 都以它为根。否则 fb-shm/virgl 早刷新时会让
         * libepoxy 在没有当前 GL/EGL context 的线程上解析入口并 abort。
         */
        scon->gls = qemu_gl_init_shader();
        shader_created = scon->gls != NULL;
    }
    if (!scon->gls) {
        scon->window_redraw_pending = true;
        sdl2_gl_release_window_current(scon);
        return false;
    }
    if (!scon->scanout_mode && scon->guest_fb.framebuffer) {
        /*
         * A failed scanout-disable can defer GL deletion until a context is
         * current again.  Do it before returning to surface rendering.
         */
        egl_fb_destroy(&scon->guest_fb);
    }
    /*
     * Window/shader initialization may happen during refresh instead of the
     * gfx-switch callback.  Always make ordinary surface texture creation a
     * retryable invariant; otherwise one transient make-current failure can
     * leave REGION updates targeting texture zero forever.
     */
    if (shader_created && scon->surface) {
        surface_gl_destroy_texture(scon->gls, scon->surface);
        scon->texture_recreate_pending = true;
        scon->texture_recreate_after_us = 0;
    }
    if (!scon->scanout_mode && !scon->scanout_replay_pending &&
        (!scon->surface->texture || scon->texture_recreate_pending)) {
        if (!sdl2_window_is_renderable(scon)) {
            scon->surface_upload_pending = true;
        } else if (!sdl2_gl_create_surface_texture(scon)) {
            sdl2_gl_release_window_current(scon);
            return false;
        }
    }
    return true;
}

static bool sdl2_gl_render_surface(struct sdl2_console *scon)
{
    SDL2Size output;
    SDL2Size guest;
    SDL2Rect dst;
    SDL2Rect viewport;
    GLenum error;
    bool presented;

    if (!sdl2_window_is_renderable(scon) ||
        sdl2_gl_make_window_current(scon) != 0) {
        scon->window_redraw_pending = true;
        return false;
    }
    sdl2_set_scanout_mode(scon, false);
    if (!sdl2_gl_create_surface_texture(scon)) {
        sdl2_gl_release_window_current(scon);
        return false;
    }

    if (!sdl2_current_render_size(scon, &output)) {
        scon->window_redraw_pending = true;
        sdl2_gl_release_window_current(scon);
        return false;
    }
    guest = (SDL2Size) {
        surface_width(scon->surface), surface_height(scon->surface),
    };
    /*
     * Show the guest at its native resolution (1:1) centred in the window and
     * letterbox the surplus instead of upscaling it (sdl2_guest_dst_rect()).
     * surface_gl_render_texture() clears the whole framebuffer first, so the
     * area outside the viewport is left as the (black) border.
     */
    dst = sdl2_guest_dst_rect(output, guest);
    viewport = sdl2_gl_viewport(output, dst);
    sdl2_gl_clear_errors();
    if (scon->native_egl) {
        /*
         * 中文注释：native EGL 子窗口使用带 alpha 的 X11 visual。普通
         * DisplaySurface 通过 shader 绘制到默认 framebuffer 时，部分驱动/
         * compositor 会保留透明 alpha，导致 GL 读回已有固件画面但窗口合成仍
         * 是黑的。显式选择默认 back buffer，并在 RGB 绘制后把 alpha 置为
         * 不透明，保持和 scanout blit 路径一致。
         */
        glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glDrawBuffer(GL_BACK);
        glReadBuffer(GL_BACK);
    }
    glViewport(viewport.x, viewport.y, viewport.width, viewport.height);

    surface_gl_render_texture(scon->gls, scon->surface);
    if (scon->native_egl) {
        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_TRUE);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    }
    error = glGetError();
    if (error != GL_NO_ERROR) {
        surface_gl_destroy_texture(scon->gls, scon->surface);
        sdl2_gl_surface_texture_failed(scon, "surface render", error);
        sdl2_gl_release_window_current(scon);
        return false;
    }
    presented = sdl2_gl_swap_window(scon);
    sdl2_gl_release_window_current(scon);
    return presented;
}

void sdl2_gl_update(DisplayChangeListener *dcl,
                    int x, int y, int w, int h)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    GLenum error;

    assert(scon->opengl);

    if (!sdl2_window_is_renderable(scon)) {
        /* Upload the latest complete surface once the window is visible. */
        scon->surface_upload_pending = true;
        scon->updates = 1;
        return;
    }

    if (!sdl2_gl_ensure_window_context(scon)) {
        if (!scon->texture_recreate_pending) {
            scon->texture_recreate_pending = true;
            scon->texture_recreate_after_us = 0;
        }
        scon->updates = 1;
        scon->window_redraw_pending = true;
        return;
    }
    sdl2_framebuffer_cursor_update(scon);

    sdl2_gl_clear_errors();
    surface_gl_update_texture(scon->gls, scon->surface, x, y, w, h);
    error = glGetError();
    if (error != GL_NO_ERROR) {
        surface_gl_destroy_texture(scon->gls, scon->surface);
        sdl2_gl_surface_texture_failed(scon, "surface upload", error);
        sdl2_gl_release_window_current(scon);
        return;
    }
    /* Pending latch: do not accumulate indefinitely while minimized. */
    scon->updates = 1;
    if (w && h) {
        sdl2_note_content_update(scon);
    }
    sdl2_gl_release_window_current(scon);
}

void sdl2_gl_switch(DisplayChangeListener *dcl,
                    DisplaySurface *new_surface)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    DisplaySurface *old_surface = scon->surface;
    bool old_context_current = false;

    assert(scon->opengl);

    sdl2_framebuffer_cursor_reset(scon);
    scon->scanout_replay_pending = false;
    scon->scanout_replay_after_us = 0;
    scon->texture_recreate_pending = true;
    scon->texture_recreate_after_us = 0;

    if (sdl2_gl_window_ready(scon) &&
        sdl2_gl_make_window_current(scon) == 0) {
        old_context_current = true;
        surface_gl_destroy_texture(scon->gls, old_surface);
    }
    if (scon->scanout_mode) {
        if (old_context_current) {
            egl_fb_destroy(&scon->guest_fb);
        }
        scon->scanout_mode = false;
        sdl2_pointer_geometry_changed(scon);
    }

    scon->surface = new_surface;
    sdl2_pointer_geometry_changed(scon);

    if (surface_is_placeholder(new_surface) && qemu_console_get_index(dcl->con)) {
        scon->texture_recreate_pending = false;
        sdl2_window_destroy(scon);
        return;
    }

    if (!sdl2_gl_ensure_window_context(scon)) {
        return;
    }
    if (!old_context_current) {
        surface_gl_destroy_texture(scon->gls, old_surface);
    }

    if (old_surface &&
        ((surface_width(old_surface)  != surface_width(new_surface)) ||
         (surface_height(old_surface) != surface_height(new_surface)))) {
        sdl2_window_resize(scon);
    }

    scon->updates = 1;
    sdl2_note_content_update(scon);
    sdl2_gl_release_window_current(scon);
}

void sdl2_gl_refresh(DisplayChangeListener *dcl)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    bool hw_pulled = false;

    assert(scon->opengl);
    sdl2_poll_events(scon);
    if (scon->native_egl_context_api) {
        EGLint async_error = qatomic_read(
            &sdl2_native_egl_async_terminal_error);

        if (async_error != EGL_SUCCESS &&
            !scon->native_egl_context_lost) {
            sdl2_gl_note_egl_failure(scon, "shared guest context",
                                     async_error);
        }
    }
    if (scon->scanout_replay_pending) {
        if (g_get_monotonic_time() >= scon->scanout_replay_after_us) {
            /* A failed replay gets a fresh bounded deadline. */
            scon->scanout_replay_after_us = 0;
            scon->scanout_replay_in_progress = true;
            dpy_gl_replay_current_scanout(dcl);
            scon->scanout_replay_in_progress = false;
        }
        if (scon->scanout_replay_pending) {
            /*
             * A replay may contain an obsolete texture/dma-buf.  Keep
             * pulling the producer so a newer scanout can replace it.
             */
            graphic_hw_update(dcl->con);
            hw_pulled = true;
        }
    }
    sdl2_flush_window_updates();

    if (!sdl2_gl_ensure_window_context(scon)) {
        return;
    }
    if (!hw_pulled) {
        graphic_hw_update(dcl->con);
    }
    if (scon->surface_upload_pending && !scon->scanout_mode &&
        sdl2_window_is_renderable(scon)) {
        scon->surface_upload_pending = false;
        sdl2_gl_update(dcl, 0, 0, surface_width(scon->surface),
                       surface_height(scon->surface));
    }
    if (!scon->scanout_mode && scon->updates &&
        sdl2_window_is_renderable(scon)) {
        if (sdl2_gl_render_surface(scon)) {
            scon->updates = 0;
        }
    }
    if (scon->fixed_present && !scon->presented_since_refresh &&
        sdl2_window_is_renderable(scon)) {
        sdl2_gl_redraw(scon);
    }
    scon->presented_since_refresh = false;
    scon->content_update_pending = false;
    sdl2_gl_release_window_current(scon);
}

void sdl2_gl_redraw(struct sdl2_console *scon)
{
    assert(scon->opengl);

    if (!sdl2_window_is_renderable(scon)) {
        return;
    }
    if (!sdl2_gl_ensure_window_context(scon)) {
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
    sdl2_gl_release_window_current(scon);
}

QEMUGLContext sdl2_gl_create_context(DisplayGLCtx *dgc,
                                     QEMUGLParams *params)
{
    struct sdl2_console *scon = container_of(dgc, struct sdl2_console, dgc);
    SDL_GLContext ctx, current_ctx;

    assert(scon->opengl);

    if (scon->native_egl_context_api) {
        if (scon->ectx == EGL_NO_CONTEXT ||
            qatomic_read(&sdl2_native_egl_async_terminal_error) !=
            EGL_SUCCESS) {
            return NULL;
        }
        return sdl2_gl_create_native_context(dgc, scon, params);
    }

    if (!sdl2_gl_ensure_window_context(scon)) {
        return NULL;
    }
    if (scon->native_egl_context_api) {
        QEMUGLContext egl_ctx = sdl2_gl_create_native_context(
            dgc, scon, params);

        sdl2_gl_release_window_current(scon);
        return egl_ctx;
    }

    current_ctx = SDL_GL_GetCurrentContext();
    if (SDL_GL_MakeCurrent(scon->real_window, scon->winctx) != 0) {
        return NULL;
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

    SDL_GL_MakeCurrent(scon->real_window, current_ctx);

    return (QEMUGLContext)ctx;
}

void sdl2_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
    struct sdl2_console *scon = container_of(dgc, struct sdl2_console, dgc);
    SDL_GLContext sdlctx = (SDL_GLContext)ctx;

    if (scon->native_egl_context_api) {
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
    bool was_scanout = scon->scanout_mode;

    assert(scon->opengl);
    scon->scanout_replay_pending = false;
    scon->scanout_replay_after_us = 0;
    scon->window_redraw_pending = true;
    scon->w = 0;
    scon->h = 0;
    if (scon->scanout_mode && sdl2_gl_make_window_current(scon) != 0) {
        /*
         * Keep the old FBO IDs for deferred deletion in ensure(), but switch
         * logical rendering back to the stable DisplaySurface immediately.
         */
        scon->scanout_mode = false;
        sdl2_pointer_geometry_changed(scon);
        scon->texture_recreate_pending = true;
        scon->texture_recreate_after_us = 0;
        scon->updates = 1;
        scon->window_resize_pending = true;
        return;
    }
    sdl2_set_scanout_mode(scon, false);
    scon->updates = 1;
    sdl2_gl_release_window_current(scon);
    if (was_scanout) {
        sdl2_window_resize(scon);
    }
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
    egl_fb candidate = EGL_FB_INIT;
    egl_fb old;
    GLenum error;
    GLenum status;
    bool guest_size_changed;

    assert(scon->opengl);
    sdl2_framebuffer_cursor_reset(scon);
    sdl2_gl_begin_scanout_update(scon);
    if (sdl2_gl_defer_hidden_scanout(scon)) {
        return;
    }
    if (!sdl2_gl_ensure_window_context(scon)) {
        sdl2_gl_defer_scanout_replay(scon);
        return;
    }
    if (sdl2_gl_make_window_current(scon) != 0) {
        sdl2_gl_release_window_current(scon);
        sdl2_gl_defer_scanout_replay(scon);
        return;
    }

    guest_size_changed = !scon->scanout_mode ||
                         scon->guest_fb.width != backing_width ||
                         scon->guest_fb.height != backing_height;
    sdl2_gl_clear_errors();
    egl_fb_setup_for_tex(&candidate, backing_width, backing_height,
                         backing_id, false);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, candidate.framebuffer);
    status = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER);
    error = glGetError();
    if (!candidate.framebuffer || status != GL_FRAMEBUFFER_COMPLETE ||
        error != GL_NO_ERROR) {
        if (!scon->warned_missing_scanout_fb) {
            warn_report("sdl2-gl: scanout setup incomplete "
                        "(framebuffer=%u status=0x%x GL=0x%x); retrying",
                        candidate.framebuffer, status, error);
            scon->warned_missing_scanout_fb = true;
        }
        egl_fb_destroy(&candidate);
        sdl2_gl_defer_scanout_replay(scon);
        sdl2_gl_release_window_current(scon);
        return;
    }
    /* Commit only a complete candidate, preserving the last safe scanout. */
    old = scon->guest_fb;
    scon->guest_fb = candidate;
    candidate = (egl_fb)EGL_FB_INIT;
    scon->guest_fb.dmabuf = NULL;
    scon->x = x;
    scon->y = y;
    scon->w = w;
    scon->h = h;
    scon->y0_top = backing_y_0_top;
    sdl2_set_scanout_mode(scon, true);
    egl_fb_destroy(&old);
    scon->updates = 0;
    scon->warned_missing_scanout_fb = false;
    scon->scanout_replay_pending = false;
    scon->scanout_replay_after_us = 0;
    if (!scon->scanout_replay_in_progress) {
        sdl2_note_content_update(scon);
    }
    if (!scon->logged_scanout_texture) {
        info_report("sdl2-gl: scanout texture active "
                    "(texture=%u %ux%u roi=%ux%u@%u,%u y0_top=%d native_egl=%d)",
                    backing_id, backing_width, backing_height, w, h, x, y,
                    backing_y_0_top, scon->native_egl);
        scon->logged_scanout_texture = true;
    }
    sdl2_gl_release_window_current(scon);
    if (guest_size_changed) {
        sdl2_pointer_geometry_changed(scon);
        sdl2_window_resize(scon);
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
    bool imported_here;
    bool y0_top;

    assert(scon->opengl);
    sdl2_framebuffer_cursor_reset(scon);

    if (!dmabuf) {
        sdl2_gl_scanout_disable(dcl);
        return;
    }
    sdl2_gl_begin_scanout_update(scon);
    if (!scon->native_egl_context_api) {
        scon->scanout_replay_pending = false;
        scon->scanout_replay_after_us = 0;
        return;
    }
    if (sdl2_gl_defer_hidden_scanout(scon)) {
        return;
    }
    if (!sdl2_gl_ensure_window_context(scon)) {
        sdl2_gl_defer_scanout_replay(scon);
        return;
    }
    if (sdl2_gl_make_window_current(scon) != 0) {
        sdl2_gl_release_window_current(scon);
        sdl2_gl_defer_scanout_replay(scon);
        return;
    }

    /*
     * 中文注释：dma-buf import 只能在 EGL current context 下执行。SDL/GLX
     * 默认路径不进入这里；native EGL 路径下导入得到本地 texture 后，复用
     * 现有 texture scanout 绘制逻辑，避免新增另一套窗口绘制代码。
     */
    imported_here = qemu_dmabuf_get_texture(dmabuf) == 0;
    sdl2_gl_clear_errors();
    if (!egl_dmabuf_import_texture(dmabuf)) {
        sdl2_gl_defer_scanout_replay(scon);
        sdl2_gl_release_window_current(scon);
        return;
    }
    texture = qemu_dmabuf_get_texture(dmabuf);
    if (!texture) {
        sdl2_gl_defer_scanout_replay(scon);
        sdl2_gl_release_window_current(scon);
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
    if (!scon->scanout_replay_pending &&
        qemu_dmabuf_get_allow_fences(dmabuf)) {
        scon->guest_fb.dmabuf = dmabuf;
    } else if (scon->scanout_replay_pending && texture && imported_here) {
        if (sdl2_gl_make_window_current(scon) == 0) {
            egl_dmabuf_release_texture(dmabuf);
        } else {
            /* Do not carry an ID from a context we can no longer enter. */
            qemu_dmabuf_set_texture(dmabuf, 0);
        }
    }
    sdl2_gl_release_window_current(scon);
}

void sdl2_gl_release_dmabuf(DisplayChangeListener *dcl,
                            QemuDmaBuf *dmabuf)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    bool anchor_current = false;
    EGLint error;
    int current_tid = qemu_get_thread_id();

    if (scon->guest_fb.dmabuf == dmabuf) {
        scon->guest_fb.dmabuf = NULL;
    }
    if (!dmabuf || !scon->native_egl_context_api) {
        return;
    }
    if (scon->native_egl) {
        if (sdl2_gl_make_window_current(scon) != 0) {
            qemu_dmabuf_set_texture(dmabuf, 0);
            return;
        }
    } else {
        EGLenum api = qemu_egl_mode == DISPLAY_GL_MODE_ES ?
                      EGL_OPENGL_ES_API : EGL_OPENGL_API;

        if (scon->native_egl_context_lost ||
            scon->ectx == EGL_NO_CONTEXT ||
            scon->native_egl_ui_tid != current_tid ||
            (scon->native_egl_owner_tid &&
             scon->native_egl_owner_tid != current_tid)) {
            qemu_dmabuf_set_texture(dmabuf, 0);
            return;
        }
        if (!eglBindAPI(api)) {
            error = eglGetError();
            if (!scon->warned_native_egl_make_current) {
                warn_report("sdl2-egl: cannot bind the anchor API while "
                            "releasing dma-buf (EGL=0x%x)", error);
                scon->warned_native_egl_make_current = true;
            }
            sdl2_gl_note_egl_failure(scon, "dma-buf anchor API bind", error);
            qemu_dmabuf_set_texture(dmabuf, 0);
            return;
        }
        if (!eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                            EGL_NO_SURFACE, scon->ectx)) {
            error = eglGetError();
            if (!scon->warned_native_egl_make_current) {
                warn_report("sdl2-egl: cannot make the anchor current while "
                            "releasing dma-buf (EGL=0x%x)", error);
                scon->warned_native_egl_make_current = true;
            }
            sdl2_gl_note_egl_failure(scon, "dma-buf anchor make-current",
                                     error);
            qemu_dmabuf_set_texture(dmabuf, 0);
            return;
        }
        scon->warned_native_egl_make_current = false;
        scon->native_egl_owner_tid = current_tid;
        anchor_current = true;
    }
    egl_dmabuf_release_texture(dmabuf);
    if (anchor_current) {
        if (!eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                            EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            error = eglGetError();
            if (!scon->warned_native_egl_release) {
                warn_report("sdl2-egl: cannot release the anchor after "
                            "dma-buf cleanup (thread=%d EGL=0x%x)",
                            current_tid, error);
                scon->warned_native_egl_release = true;
            }
            sdl2_gl_note_egl_failure(scon, "dma-buf anchor release", error);
        } else {
            scon->warned_native_egl_release = false;
            scon->native_egl_owner_tid = 0;
        }
    } else {
        sdl2_gl_release_window_current(scon);
    }
}
#endif

void sdl2_gl_window_context_destroying(struct sdl2_console *scon)
{
    bool current = false;

    if (!scon->opengl) {
        return;
    }

    if (scon->native_egl) {
        if (!scon->native_egl_context_lost &&
            scon->ectx != EGL_NO_CONTEXT &&
            scon->native_egl_ui_tid == qemu_get_thread_id()) {
            current = eglGetCurrentContext() == scon->ectx ||
                      eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                                     EGL_NO_SURFACE, scon->ectx);
            if (current) {
                scon->native_egl_owner_tid = qemu_get_thread_id();
            }
        }
    } else if (scon->real_window && scon->winctx) {
        current = SDL_GL_MakeCurrent(scon->real_window, scon->winctx) == 0;
    }

#ifdef CONFIG_GBM
    if (scon->guest_fb.dmabuf) {
        /* The texture number is meaningful only in the dying share group. */
        qemu_dmabuf_set_texture(scon->guest_fb.dmabuf, 0);
    }
#endif
    if (current) {
        if (scon->gls && scon->surface) {
            surface_gl_destroy_texture(scon->gls, scon->surface);
        }
        egl_fb_destroy(&scon->guest_fb);
        egl_fb_destroy(&scon->win_fb);
        qemu_gl_fini_shader(scon->gls);
    } else {
        if (scon->surface) {
            scon->surface->texture = 0;
        }
        qemu_gl_forget_shader(scon->gls);
    }
    scon->gls = NULL;
    scon->guest_fb = (egl_fb)EGL_FB_INIT;
    scon->win_fb = (egl_fb)EGL_FB_INIT;
    scon->scanout_mode = false;
    scon->scanout_replay_pending = false;
    scon->scanout_replay_in_progress = false;
    scon->scanout_replay_after_us = 0;
    scon->texture_recreate_pending = false;
    scon->surface_upload_pending = false;

    if (current && scon->native_egl) {
        if (eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                           EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            scon->native_egl_owner_tid = 0;
        }
    } else if (current) {
        SDL_GL_MakeCurrent(scon->real_window, NULL);
    }
}

void sdl2_gl_scanout_flush(DisplayChangeListener *dcl,
                           uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    SDL2Size output;
    SDL2Size guest;
    SDL2Rect dst;
    SDL2Rect viewport;
    GLenum error;
    bool presented;
    int ww, wh, dx, dy, dw, dh;
    GLint sy1, sy2;

    assert(scon->opengl);
    if (!sdl2_window_is_renderable(scon)) {
        scon->window_redraw_pending = true;
        return;
    }
    if (!scon->scanout_mode) {
        if (scon->scanout_replay_pending) {
            scon->window_redraw_pending = true;
        }
        return;
    }
    if (!scon->guest_fb.framebuffer) {
        if (!scon->warned_missing_scanout_fb) {
            warn_report("sdl2-gl: scanout flush skipped: missing guest framebuffer");
            scon->warned_missing_scanout_fb = true;
        }
        sdl2_gl_defer_scanout_replay(scon);
        return;
    }

    if (sdl2_gl_make_window_current(scon) != 0) {
        scon->window_redraw_pending = true;
        return;
    }

    if (!sdl2_current_render_size(scon, &output)) {
        scon->window_redraw_pending = true;
        sdl2_gl_release_window_current(scon);
        return;
    }
    ww = output.width;
    wh = output.height;
    /*
     * virtio-gpu-gl (virgl) routes the scanout through this GL-texture path
     * even for a plain 2D guest, so this — not sdl2_gl_render_surface() — is
     * what draws the picture here.  Keep them consistent: show the guest at
     * its native resolution (1:1) centred in the window, letterboxed with
     * black borders instead of stretched to fill, shrinking only when the
     * window is too small (sdl2_guest_dst_rect()).  Blit straight to the
     * default framebuffer after clearing it to black for the borders.
     */
    guest = (SDL2Size) { scon->guest_fb.width, scon->guest_fb.height };
    dst = sdl2_guest_dst_rect(output, guest);
    viewport = sdl2_gl_viewport(output, dst);
    dx = viewport.x;
    dy = viewport.y;
    dw = viewport.width;
    dh = viewport.height;
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

    sdl2_gl_clear_errors();
    if (scon->native_egl) {
        GLint sy1_native;
        GLint sy2_native;

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

    error = glGetError();
    if (error != GL_NO_ERROR) {
        if (!scon->warned_native_egl_blit) {
            warn_report("sdl2-gl: scanout blit GL error 0x%x; retrying",
                        error);
            scon->warned_native_egl_blit = true;
        }
        sdl2_gl_defer_scanout_replay(scon);
        sdl2_gl_release_window_current(scon);
        return;
    }
    scon->warned_native_egl_blit = false;

    if (w && h) {
        sdl2_note_content_update(scon);
    }
    presented = sdl2_gl_swap_window(scon);
    if (presented) {
        scon->window_redraw_pending = false;
    }
    sdl2_gl_release_window_current(scon);
}

void sdl2_gl_console_init(struct sdl2_console *scon)
{
    bool hidden = scon->hidden;

    scon->hidden = true;
    scon->surface = qemu_create_displaysurface(1, 1);
    sdl2_window_create(scon);

    /*
     * QEMU checks whether console supports dma-buf before switching
     * to the console.  To break this chicken-egg problem we pre-check
     * dma-buf availability beforehand using a dummy SDL window.
     */
    scon->has_dmabuf = qemu_egl_has_dmabuf();

    sdl2_window_destroy(scon);
    qemu_free_displaysurface(scon->surface);

    scon->surface = NULL;
    scon->hidden = hidden;
}
