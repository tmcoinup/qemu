/*
 * USB HID NumLock 强制开启状态机
 *
 * Copyright (c) 2026
 *
 * 本文件不依赖 QEMUBH 或 USB 控制器实现。
 * 它只把 guest LED 报告转换为调度动作，
 * 严格区分尚未报告与明确关闭，
 * 并允许单元测试验证去重语义。
 */

#include "qemu/osdep.h"
#include "hw/usb/hid-numlock.h"

USBHIDNumLockAction usb_hid_numlock_report(USBHIDNumLockState *state,
                                            bool led_on)
{
    state->led_known = true;
    state->led_on = led_on;

    if (led_on) {
        /*
         * ON 表示当前收敛轮次已经达到目标状态。
         * 若 BH 尚未执行，调用方会取消它；
         * 执行后取消为空操作。
         */
        if (state->force_on) {
            state->startup_completed = true;
        }
        if (state->force_pending) {
            state->force_pending = false;
            state->injection_attempted = false;
            return USB_HID_NUMLOCK_ACTION_CANCEL;
        }
        state->injection_attempted = false;
        return USB_HID_NUMLOCK_ACTION_NONE;
    }

    /*
     * 固件、Windows 欢迎界面和用户会话
     * 都可能先后写 LED。
     * 因此较早的 ON 不能永久锁死策略。
     * 每次新的明确 OFF 都开始一个收敛轮次。
     * pending 会保留到 guest 回报 ON；
     * 同一轮内连续 OFF 不会排入多个翻转键。
     */
    if (state->force_on && !state->force_pending) {
        state->startup_completed = false;
        state->force_pending = true;
        state->injection_attempted = false;
        return USB_HID_NUMLOCK_ACTION_SCHEDULE;
    }

    return USB_HID_NUMLOCK_ACTION_NONE;
}

bool usb_hid_numlock_should_inject(const USBHIDNumLockState *state)
{
    /* 未收到 SET_REPORT 时，led_on 零值不是明确选择。 */
    return state->force_on && state->led_known && !state->led_on &&
           state->force_pending && !state->injection_attempted &&
           !state->startup_completed;
}

void usb_hid_numlock_reset(USBHIDNumLockState *state)
{
    /* force_on 是设备配置，USB reset 仅清理运行态。 */
    state->led_known = false;
    state->led_on = false;
    state->force_pending = false;
    state->injection_attempted = false;
    state->startup_completed = false;
}
