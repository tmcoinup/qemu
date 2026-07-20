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
#include "trace.h"

/*
 * 输入门控：键鼠事件只在窗口同时拥有输入焦点和鼠标焦点（指针在窗内）
 * 时才允许下发给 guest。焦点状态由 sdl2.c 的窗口事件状态机维护；
 * 任一条件失守时，调用方会抬起已按键并丢弃后续输入，避免窗外误输入和卡键。
 */
bool sdl2_input_allowed(const struct sdl2_console *scon)
{
    return scon && scon->real_window &&
        scon->has_input_focus && scon->has_mouse_focus;
}

/*
 * SDL 在 video 初始化时会自动开启桌面文本输入。X11 backend 随后会把每个
 * 按键先交给 IBus/Fcitx；输入法若返回“已处理”，SDL 就不再产生 guest 所需
 * 的原始 KEYDOWN/KEYUP。图形 console 只使用物理 scancode，必须关闭这条
 * 宿主文本输入通道。
 *
 * 文本输入是 SDL 进程级状态，多窗口下不能只依据刚收到事件的旧窗口决定。
 * 先读取 SDL 当前真正拥有键盘焦点的窗口，再从全部 console 中寻找唯一 owner：
 * 只有通过输入门控的 QEMU text console 才开启 IME；图形窗口、窗口外部以及
 * 隐藏窗口全部关闭。这样既避免宿主输入法吞掉 VM 按键，也保留 monitor/串口
 * 文本 console 的 Unicode 输入能力。
 */
void sdl2_sync_text_input(struct sdl2_console *consoles, int num_outputs)
{
    SDL_Window *focused_window = SDL_GetKeyboardFocus();
    const struct sdl2_console *owner = NULL;
    bool should_enable = false;
    bool is_active = SDL_IsTextInputActive() == SDL_TRUE;
    int i;

    if (focused_window && consoles) {
        for (i = 0; i < num_outputs; i++) {
            if (consoles[i].real_window == focused_window) {
                owner = &consoles[i];
                break;
            }
        }
    }
    if (owner && !owner->hidden && owner->dcl.con &&
        sdl2_input_allowed(owner) &&
        QEMU_IS_TEXT_CONSOLE(owner->dcl.con)) {
        should_enable = true;
    }

    if (should_enable == is_active) {
        return;
    }
    if (should_enable) {
        SDL_StartTextInput();
    } else {
        SDL_StopTextInput();
    }
}

void sdl2_process_key(struct sdl2_console *scon,
                      SDL_KeyboardEvent *ev)
{
    int qcode;
    QemuConsole *con = scon->dcl.con;

    if (ev->keysym.scancode >= qemu_input_map_usb_to_qcode_len) {
        return;
    }
    qcode = qemu_input_map_usb_to_qcode[ev->keysym.scancode];
    trace_sdl2_process_key(ev->keysym.scancode, qcode,
                           ev->type == SDL_KEYDOWN ? "down" : "up");
    qkbd_state_key_event(scon->kbd, qcode, ev->type == SDL_KEYDOWN);

    if (QEMU_IS_TEXT_CONSOLE(con)) {
        QemuTextConsole *s = QEMU_TEXT_CONSOLE(con);
        bool ctrl = qkbd_state_modifier_get(scon->kbd, QKBD_MOD_CTRL);
        if (ev->type == SDL_KEYDOWN) {
            switch (qcode) {
            case Q_KEY_CODE_RET:
                qemu_text_console_put_keysym(s, '\n');
                break;
            default:
                qemu_text_console_put_qcode(s, qcode, ctrl);
                break;
            }
        }
    }
}

void sdl2_release_modifiers(struct sdl2_console *scon)
{
    qkbd_state_lift_all_keys(scon->kbd);
}
