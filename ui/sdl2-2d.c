/*
 * QEMU SDL display driver
 *
 * Copyright (c) 2003 Fabrice Bellard
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
/* Ported SDL 1.2 code to 2.0 by Dave Airlie. */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "ui/console.h"
#include "ui/input.h"
#include "ui/sdl2.h"

static void sdl2_2d_schedule_texture_recovery(struct sdl2_console *scon,
                                              const char *operation)
{
    if (!scon->warned_texture_recovery) {
        warn_report("sdl2: %s failed; scheduling texture recovery: %s",
                    operation, SDL_GetError());
        scon->warned_texture_recovery = true;
    }
    if (!scon->texture_recreate_pending) {
        scon->texture_recreate_pending = true;
        scon->texture_recreate_after_us =
            g_get_monotonic_time() + G_USEC_PER_SEC;
    }
}

static void sdl2_2d_texture_recovered(struct sdl2_console *scon)
{
    if (scon->texture_upload_failed) {
        return;
    }
    scon->texture_recreate_pending = false;
    scon->texture_recreate_after_us = 0;
    scon->warned_texture_recovery = false;
}

static bool sdl2_2d_present_texture(struct sdl2_console *scon)
{
    DisplaySurface *surf = scon->surface;
    SDL2Size output;
    SDL_Rect dst;
    int dx, dy, dw, dh;

    if (!surf || !scon->texture || !scon->real_renderer ||
        !sdl2_window_is_renderable(scon)) {
        return false;
    }

    /*
     * Show the guest at its native resolution (1:1) centred in the window and
     * letterbox the surplus with black borders instead of upscaling it.  The
     * destination rectangle is placed by sdl2_gfx_dst_rect() rather than via
     * SDL_RenderSetLogicalSize(), which would scale the guest up to fill the
     * window.
     */
    if (!sdl2_current_render_size(scon, &output)) {
        scon->window_redraw_pending = true;
        return false;
    }
    sdl2_gfx_dst_rect(output.width, output.height,
                      surface_width(surf), surface_height(surf),
                      &dx, &dy, &dw, &dh);
    dst.x = dx;
    dst.y = dy;
    dst.w = dw;
    dst.h = dh;
    if (SDL_SetRenderDrawColor(scon->real_renderer, 0, 0, 0, 255) != 0 ||
        SDL_RenderClear(scon->real_renderer) != 0 ||
        SDL_RenderCopy(scon->real_renderer, scon->texture, NULL, &dst) != 0) {
        sdl2_2d_schedule_texture_recovery(scon, "2D render");
        return false;
    }
    SDL_RenderPresent(scon->real_renderer);
    sdl2_note_present(scon);
    sdl2_2d_texture_recovered(scon);
    return true;
}

void sdl2_2d_update(DisplayChangeListener *dcl,
                    int x, int y, int w, int h)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    DisplaySurface *surf = scon->surface;
    SDL_Rect rect;
    size_t surface_data_offset;

    assert(!scon->opengl);
    if (!scon->texture) {
        return;
    }
    if (!sdl2_window_is_renderable(scon)) {
        /* Avoid CPU-to-GPU uploads that cannot be shown while minimized. */
        scon->surface_upload_pending = true;
        scon->updates = 1;
        return;
    }
    sdl2_framebuffer_cursor_update(scon);

    surface_data_offset = surface_bytes_per_pixel(surf) * x +
                          surface_stride(surf) * y;
    rect.x = x;
    rect.y = y;
    rect.w = w;
    rect.h = h;
    if (SDL_UpdateTexture(scon->texture, &rect,
                          surface_data(surf) + surface_data_offset,
                          surface_stride(surf)) == 0) {
        /*
         * One graphic update may contain many dirty rectangles.  This is a
         * pending latch, not a frame counter: keep it saturated while the
         * window is minimized, then present the latest complete texture once.
        */
        scon->updates = 1;
        if (scon->manual_redraw) {
            scon->texture_upload_failed = false;
            sdl2_2d_texture_recovered(scon);
        }
        sdl2_note_content_update(scon);
    } else {
        scon->texture_upload_failed = true;
        sdl2_2d_schedule_texture_recovery(scon, "texture upload");
    }
}

void sdl2_2d_switch(DisplayChangeListener *dcl,
                    DisplaySurface *new_surface)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    DisplaySurface *old_surface = scon->surface;
    int format = 0;

    assert(!scon->opengl);

    sdl2_framebuffer_cursor_reset(scon);
    scon->surface = new_surface;
    sdl2_pointer_geometry_changed(scon);

    if (scon->texture) {
        SDL_DestroyTexture(scon->texture);
        scon->texture = NULL;
    }

    if (surface_is_placeholder(new_surface) && qemu_console_get_index(dcl->con)) {
        sdl2_window_destroy(scon);
        return;
    }

    if (!scon->real_window) {
        sdl2_window_create(scon);
    } else if (old_surface &&
               ((surface_width(old_surface)  != surface_width(new_surface)) ||
                (surface_height(old_surface) != surface_height(new_surface)))) {
        sdl2_window_resize(scon);
    }
    if (!scon->real_window || !scon->real_renderer) {
        scon->texture_upload_failed = true;
        scon->texture_recreate_pending = true;
        scon->texture_recreate_after_us =
            g_get_monotonic_time() + G_USEC_PER_SEC;
        return;
    }

    /*
     * No SDL_RenderSetLogicalSize() here: it would letterbox *and* upscale the
     * guest to fill the window.  sdl2_2d_update() instead blits to a centred
     * 1:1 destination rectangle, and the absolute-pointer mapping in
     * sdl_send_mouse_event() works in window pixels to match.
     */
    switch (surface_format(scon->surface)) {
    case PIXMAN_x1r5g5b5:
        format = SDL_PIXELFORMAT_ARGB1555;
        break;
    case PIXMAN_r5g6b5:
        format = SDL_PIXELFORMAT_RGB565;
        break;
    case PIXMAN_a8r8g8b8:
    case PIXMAN_x8r8g8b8:
        format = SDL_PIXELFORMAT_ARGB8888;
        break;
    case PIXMAN_a8b8g8r8:
    case PIXMAN_x8b8g8r8:
        format = SDL_PIXELFORMAT_ABGR8888;
        break;
    case PIXMAN_r8g8b8a8:
    case PIXMAN_r8g8b8x8:
        format = SDL_PIXELFORMAT_RGBA8888;
        break;
    case PIXMAN_b8g8r8x8:
        format = SDL_PIXELFORMAT_BGRX8888;
        break;
    case PIXMAN_b8g8r8a8:
        format = SDL_PIXELFORMAT_BGRA8888;
        break;
    default:
        g_assert_not_reached();
    }
    scon->texture = SDL_CreateTexture(scon->real_renderer, format,
                                      SDL_TEXTUREACCESS_STREAMING,
                                      surface_width(new_surface),
                                      surface_height(new_surface));
    if (!scon->texture) {
        if (!scon->warned_texture_recovery) {
            warn_report("sdl2: cannot create display texture: %s",
                        SDL_GetError());
            scon->warned_texture_recovery = true;
        }
        scon->texture_upload_failed = true;
        scon->texture_recreate_pending = true;
        scon->texture_recreate_after_us =
            g_get_monotonic_time() + G_USEC_PER_SEC;
        return;
    }
    scon->texture_upload_failed = true;
    sdl2_2d_redraw(scon);
}

void sdl2_2d_refresh(DisplayChangeListener *dcl)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    assert(!scon->opengl);
    sdl2_poll_events(scon);
    sdl2_flush_window_updates();
    graphic_hw_update(dcl->con);
    if (scon->surface_upload_pending &&
        sdl2_window_is_renderable(scon)) {
        scon->surface_upload_pending = false;
        sdl2_2d_redraw(scon);
    }
    if (scon->texture_recreate_pending &&
        (!scon->real_window || sdl2_window_is_renderable(scon)) &&
        g_get_monotonic_time() >= scon->texture_recreate_after_us) {
        /*
         * Start one bounded retry.  A repeated failure schedules the next
         * attempt one second out instead of rebuilding every refresh.
         */
        scon->texture_recreate_pending = false;
        scon->texture_recreate_after_us = 0;
        sdl2_2d_switch(dcl, scon->surface);
    }
    if (scon->updates && sdl2_window_is_renderable(scon)) {
        if (sdl2_2d_present_texture(scon)) {
            scon->updates = 0;
        }
    }
    if (scon->fixed_present && !scon->presented_since_refresh &&
        sdl2_window_is_renderable(scon)) {
        sdl2_2d_present_texture(scon);
    }
    scon->presented_since_refresh = false;
    scon->content_update_pending = false;
}

void sdl2_2d_redraw(struct sdl2_console *scon)
{
    bool was_manual_redraw;

    assert(!scon->opengl);

    if (!scon->surface) {
        return;
    }
    scon->updates = 0;
    was_manual_redraw = scon->manual_redraw;
    scon->manual_redraw = true;
    sdl2_2d_update(&scon->dcl, 0, 0,
                   surface_width(scon->surface),
                   surface_height(scon->surface));
    scon->manual_redraw = was_manual_redraw;
    if (scon->updates && sdl2_window_is_renderable(scon)) {
        if (sdl2_2d_present_texture(scon)) {
            scon->updates = 0;
        }
    }
}

bool sdl2_2d_check_format(DisplayChangeListener *dcl,
                          pixman_format_code_t format)
{
    /*
     * We let SDL convert for us a few more formats than,
     * the native ones. These are the ones I have tested.
     */
    return (format == PIXMAN_x8r8g8b8 ||
            format == PIXMAN_a8r8g8b8 ||
            format == PIXMAN_a8b8g8r8 ||
            format == PIXMAN_x8b8g8r8 ||
            format == PIXMAN_b8g8r8x8 ||
            format == PIXMAN_b8g8r8a8 ||
            format == PIXMAN_r8g8b8x8 ||
            format == PIXMAN_r8g8b8a8 ||
            format == PIXMAN_x1r5g5b5 ||
            format == PIXMAN_r5g6b5);
}
