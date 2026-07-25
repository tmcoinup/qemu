/*
 * QEMU SDL display sizing and refresh policy
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef QEMU_UI_SDL2_DISPLAY_POLICY_H
#define QEMU_UI_SDL2_DISPLAY_POLICY_H

#include "ui/sdl2-pointer.h"

/*
 * 可见 SDL 窗口至少按 60 Hz 轮询。
 *
 * DisplayChangeListener 目前使用整数毫秒。
 * 向下取整为 16 ms，避免 17 ms 把理论上限压到 58.8 FPS。
 * 最小化窗口仍由调用者选择较慢的周期。
 */
#define SDL2_ACTIVE_REFRESH_HZ 60U
#define SDL2_ACTIVE_REFRESH_INTERVAL_MS \
    (1000U / SDL2_ACTIVE_REFRESH_HZ)

typedef enum SDL2WindowMode {
    SDL2_WINDOW_MODE_INVALID = 0,
    SDL2_WINDOW_MODE_WINDOWED,
    SDL2_WINDOW_MODE_DESKTOP_FULLSCREEN,
} SDL2WindowMode;

/*
 * 选择能保留最多原生像素的初始窗口模式。
 *
 * desktop 使用 SDL 为目标显示器报告的 desktop mode 尺寸。
 * Windows/X11 下它对应像素；
 * native Wayland 可能返回缩放后的坐标。
 * guest 在任一轴触及或超过该边界时，
 * 有边框窗口已经不适合承载同尺寸客户区。
 * 使用 desktop fullscreen 可避免窗口管理器先缩小客户区，
 * 再由 SDL 对 guest 做一次非整数缩放。
 * 两轴都更小时保留普通窗口。
 */
SDL2WindowMode sdl2_select_window_mode(SDL2Size guest, SDL2Size desktop);

#endif /* QEMU_UI_SDL2_DISPLAY_POLICY_H */
