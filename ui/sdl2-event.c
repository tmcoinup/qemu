/*
 * SDL event queue helpers
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/sdl2-event.h"

void sdl2_disable_host_text_input(void)
{
    SDL_StopTextInput();
}

bool sdl2_window_updates_allowed(Uint32 flags, bool hidden)
{
    return !hidden &&
           !(flags & (SDL_WINDOW_HIDDEN | SDL_WINDOW_MINIMIZED));
}

unsigned int sdl2_coalesce_mouse_motion(SDL_Event *event,
                                        unsigned int max_events,
                                        int64_t deadline_us)
{
    SDL_Event next;
    int64_t xrel = event->motion.xrel;
    int64_t yrel = event->motion.yrel;
    unsigned int consumed = 0;

    /*
     * 只合并队首连续、同窗口/设备/按钮状态的 motion。
     * 不跨过按键、按钮或窗口事件，因而保留输入顺序。
     * 主线程短暂停顿后只向 Guest 同步一次。
     */
    while (consumed < max_events) {
        if ((consumed & 31) == 0 &&
            g_get_monotonic_time() >= deadline_us) {
            break;
        }
        if (SDL_PeepEvents(&next, 1, SDL_PEEKEVENT,
                           SDL_FIRSTEVENT, SDL_LASTEVENT) != 1 ||
            next.type != SDL_MOUSEMOTION ||
            next.motion.windowID != event->motion.windowID ||
            next.motion.which != event->motion.which ||
            next.motion.state != event->motion.state) {
            break;
        }
        if (SDL_PollEvent(&next) != 1) {
            break;
        }
        consumed++;
        xrel += next.motion.xrel;
        yrel += next.motion.yrel;
        event->motion.timestamp = next.motion.timestamp;
        event->motion.x = next.motion.x;
        event->motion.y = next.motion.y;
    }

    event->motion.xrel = xrel > INT32_MAX ? INT32_MAX :
                         xrel < INT32_MIN ? INT32_MIN : xrel;
    event->motion.yrel = yrel > INT32_MAX ? INT32_MAX :
                         yrel < INT32_MIN ? INT32_MIN : yrel;
    return consumed;
}
