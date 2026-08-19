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
