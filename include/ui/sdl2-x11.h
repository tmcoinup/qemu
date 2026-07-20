/* SPDX-License-Identifier: GPL-2.0-or-later */

#ifndef QEMU_UI_SDL2_X11_H
#define QEMU_UI_SDL2_X11_H

#include <SDL.h>

/*
 * 请求 XWayland compositor 允许当前 SDL 窗口申请键盘独占。
 * 非 X11 backend 和未链接 X11 的构建会安全退化为空操作。
 * ClientMessage 只提交请求；
 * 最终是否授权由 compositor 策略决定。
 */
void sdl2_x11_request_keyboard_grab_permission(SDL_Window *window);

#endif /* QEMU_UI_SDL2_X11_H */
