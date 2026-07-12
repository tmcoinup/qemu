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
#include "ui/console.h"
#include "ui/input.h"
#include "ui/sdl2.h"

void sdl2_2d_update(DisplayChangeListener *dcl,
                    int x, int y, int w, int h)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    DisplaySurface *surf = scon->surface;
    SDL_Rect rect, dst;
    size_t surface_data_offset;
    int ow, oh, dx, dy, dw, dh;
    assert(!scon->opengl);

    if (!scon->texture) {
        return;
    }

    surface_data_offset = surface_bytes_per_pixel(surf) * x +
                          surface_stride(surf) * y;
    rect.x = x;
    rect.y = y;
    rect.w = w;
    rect.h = h;

    SDL_UpdateTexture(scon->texture, &rect,
                      surface_data(surf) + surface_data_offset,
                      surface_stride(surf));

    /*
     * Show the guest at its native resolution (1:1) centred in the window and
     * letterbox the surplus with black borders instead of upscaling it.  The
     * destination rectangle is placed by sdl2_gfx_dst_rect() rather than via
     * SDL_RenderSetLogicalSize(), which would scale the guest up to fill the
     * window.
     */
    SDL_GetRendererOutputSize(scon->real_renderer, &ow, &oh);
    sdl2_gfx_dst_rect(ow, oh, surface_width(surf), surface_height(surf),
                      &dx, &dy, &dw, &dh);
    dst.x = dx;
    dst.y = dy;
    dst.w = dw;
    dst.h = dh;
    SDL_SetRenderDrawColor(scon->real_renderer, 0, 0, 0, 255);
    SDL_RenderClear(scon->real_renderer);
    SDL_RenderCopy(scon->real_renderer, scon->texture, NULL, &dst);
    SDL_RenderPresent(scon->real_renderer);
}

void sdl2_2d_switch(DisplayChangeListener *dcl,
                    DisplaySurface *new_surface)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    DisplaySurface *old_surface = scon->surface;
    int format = 0;

    assert(!scon->opengl);

    scon->surface = new_surface;

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
    sdl2_2d_redraw(scon);
}

void sdl2_2d_refresh(DisplayChangeListener *dcl)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    assert(!scon->opengl);
    graphic_hw_update(dcl->con);
    sdl2_poll_events(scon);
}

void sdl2_2d_redraw(struct sdl2_console *scon)
{
    assert(!scon->opengl);

    if (!scon->surface) {
        return;
    }
    sdl2_2d_update(&scon->dcl, 0, 0,
                   surface_width(scon->surface),
                   surface_height(scon->surface));
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
