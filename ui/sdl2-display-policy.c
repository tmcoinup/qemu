/*
 * QEMU SDL display sizing and refresh policy
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/sdl2-display-policy.h"

static bool sdl2_display_size_is_valid(SDL2Size size)
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
                          SDL2Size guest, SDL2Size *maximum)
{
    if (!maximum) {
        return false;
    }

    *maximum = (SDL2Size) { 0 };
    if (!sdl2_display_size_is_valid(window) ||
        !sdl2_display_size_is_valid(render) ||
        !sdl2_display_size_is_valid(guest)) {
        return false;
    }

    maximum->width = sdl2_window_max_extent(
        window.width, render.width, guest.width);
    maximum->height = sdl2_window_max_extent(
        window.height, render.height, guest.height);
    return true;
}

SDL2WindowMode sdl2_select_window_mode(SDL2Size guest, SDL2Size desktop)
{
    if (!sdl2_display_size_is_valid(guest) ||
        !sdl2_display_size_is_valid(desktop)) {
        return SDL2_WINDOW_MODE_INVALID;
    }

    /*
     * 任一轴相等时也必须使用 desktop fullscreen。
     * 窗口标题栏、边框或桌面保留区
     * 会让真实客户区小于 desktop；
     * 继续创建有边框窗口必然触发缩放。
     */
    if (guest.width >= desktop.width || guest.height >= desktop.height) {
        return SDL2_WINDOW_MODE_DESKTOP_FULLSCREEN;
    }

    return SDL2_WINDOW_MODE_WINDOWED;
}
