/*
 * QEMU SDL X11 integration
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/sdl2-x11.h"

#if defined(CONFIG_X11) && defined(SDL_VIDEO_DRIVER_X11)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wredundant-decls"
#include <SDL_syswm.h>
#pragma GCC diagnostic pop

#include <X11/Xlib.h>
#endif

void sdl2_x11_request_keyboard_grab_permission(SDL_Window *window)
{
#if defined(CONFIG_X11) && defined(SDL_VIDEO_DRIVER_X11)
    SDL_SysWMinfo info;
    XClientMessageEvent message = { 0 };
    Atom permission_atom;

    if (!window) {
        return;
    }

    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) ||
        info.subsystem != SDL_SYSWM_X11) {
        return;
    }

    /*
     * GNOME/Mutter 在 Wayland 会话中
     * 不会仅凭 XGrabKeyboard 抑制 compositor 快捷键。
     * 普通 XWayland 窗口必须先向 root
     * 发送此 ClientMessage，
     * 声明自己是 VM/远程桌面一类
     * 确实需要 Super、Alt+Tab 的客户端。
     *
     * 原生 Xorg 没有该消息的接收者，
     * 发送未知 ClientMessage 是无害的；
     * 无需通过环境变量猜测 X server 是否为 XWayland。
     */
    permission_atom = XInternAtom(info.info.x11.display,
                                  "_XWAYLAND_MAY_GRAB_KEYBOARD", False);
    if (permission_atom == None) {
        return;
    }

    message.type = ClientMessage;
    message.window = info.info.x11.window;
    message.message_type = permission_atom;
    message.format = 32;
    message.data.l[0] = 1;
    message.data.l[1] = CurrentTime;

    (void)XSendEvent(info.info.x11.display,
                     DefaultRootWindow(info.info.x11.display),
                     False,
                     SubstructureNotifyMask | SubstructureRedirectMask,
                     (XEvent *)&message);
    XFlush(info.info.x11.display);
#else
    (void)window;
#endif
}
