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
         * 首次 ON 表示 guest 已经处于目标状态，启动初始化立即完成。
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
     * 每个 USB reset 周期只允许启动一次。
     * completed 后的 OFF 是用户手动关闭，不能再次干预。
     * Windows 可能连续发送 OFF，
     * pending 可避免多个翻转互相抵消。
     */
    if (state->force_on && !state->startup_completed &&
        !state->force_pending) {
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
