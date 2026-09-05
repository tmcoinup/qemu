/*
 * QEMU SDL display sizing policy
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/sdl2-display-policy.h"

static bool sdl2_size_is_valid(SDL2Size size)
{
    return size.width > 0 && size.height > 0;
}

static int sdl2_window_max_extent(int window_extent,
                                  int render_extent, int guest_extent)
{
    int64_t extent = (int64_t)window_extent * guest_extent / render_extent;

    return MIN(MAX(extent, 1), INT_MAX);
}

bool sdl2_window_max_size(SDL2Size window, SDL2Size render,
                          SDL2Size guest, bool embedded_render_child,
                          SDL2Size *maximum)
{
    if (!maximum) {
        return false;
    }

    *maximum = (SDL2Size) { 0 };
    if (embedded_render_child) {
        /* The child is resized to its SDL parent after event processing. */
        render = window;
    }
    if (!sdl2_size_is_valid(window) || !sdl2_size_is_valid(render) ||
        !sdl2_size_is_valid(guest)) {
        return false;
    }

    maximum->width = sdl2_window_max_extent(
        window.width, render.width, guest.width);
    maximum->height = sdl2_window_max_extent(
        window.height, render.height, guest.height);
    return true;
}

bool sdl2_surface_damage_add(SDL2Rect *damage, SDL2Size surface,
                              SDL2Rect update)
{
    int64_t x0, y0, x1, y1;

    if (!damage || !sdl2_size_is_valid(surface) ||
        update.width <= 0 || update.height <= 0) {
        return false;
    }

    x0 = MAX((int64_t)update.x, 0);
    y0 = MAX((int64_t)update.y, 0);
    x1 = MIN((int64_t)update.x + update.width, surface.width);
    y1 = MIN((int64_t)update.y + update.height, surface.height);
    if (x1 <= x0 || y1 <= y0) {
        return false;
    }

    if (damage->width > 0 && damage->height > 0) {
        x0 = MIN(x0, damage->x);
        y0 = MIN(y0, damage->y);
        x1 = MAX(x1, (int64_t)damage->x + damage->width);
        y1 = MAX(y1, (int64_t)damage->y + damage->height);
    }
    *damage = (SDL2Rect) { x0, y0, x1 - x0, y1 - y0 };
    return true;
}
