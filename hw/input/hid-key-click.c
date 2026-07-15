/*
 * QEMU HID 键盘设备定向按键注入
 *
 * 该逻辑独立于通用 HID 事件接收路径，
 * 供需要把按键准确送到某个 HIDState 的设备功能使用。
 * 当前 usb-kbd NumLock 强制开启依赖该接口。
 */

#include "qemu/osdep.h"
#include "hw/input/hid.h"
#include "trace.h"

bool hid_keyboard_send_key_click(HIDState *hs, QKeyCode qcode)
{
    KeyValue key = {
        .type = KEY_VALUE_KIND_QCODE,
        .u.qcode.data = qcode,
    };
    int scancodes[6];
    int down_count;
    int up_count;
    int count;
    int i;

    g_assert(hs->kind == HID_KEYBOARD);

    /*
     * 先同时计算按下与释放的扫描码，
     * 再检查环形队列容量。
     * 若分两次调用普通输入路径，
     * 队列只剩一个槽时可能仅接收按下，
     * 从而在 guest 内留下永久按住的按键。
     * 这里要么完整入队，要么完全不修改队列。
     */
    down_count = qemu_input_key_value_to_scancode(&key, true, scancodes);
    up_count = qemu_input_key_value_to_scancode(&key, false,
                                                 scancodes + down_count);
    count = down_count + up_count;
    if (count == 0 || hs->n + count > QUEUE_LENGTH) {
        trace_hid_kbd_queue_full();
        return false;
    }

    for (i = 0; i < count; i++) {
        int slot = (hs->head + hs->n) & QUEUE_MASK;

        hs->n++;
        hs->kbd.keycodes[slot] = scancodes[i];
    }

    /* 一次唤醒已足够；interrupt IN 会逐个消费扫描码。 */
    hs->event(hs);
    return true;
}
