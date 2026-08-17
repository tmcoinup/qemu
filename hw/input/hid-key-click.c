/*
 * Directed key-click injection for a QEMU HID keyboard.
 *
 * The complete press/release sequence is committed atomically to one HID
 * queue so a full queue can never leave a modifier or key stuck down.
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

    hs->event(hs);
    return true;
}
