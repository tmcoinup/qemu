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
