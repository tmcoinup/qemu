/*
 * USB HID NumLock forced-on convergence state machine.
 *
 * An unknown zero-valued LED state is never guessed to mean OFF.  Each new
 * explicit OFF report creates one convergence epoch; duplicate OFF reports
 * cannot enqueue duplicate key clicks while that epoch waits for ON.
 */

#include "qemu/osdep.h"
#include "hw/usb/hid-numlock.h"

USBHIDNumLockAction usb_hid_numlock_report(USBHIDNumLockState *state,
                                            bool led_on)
{
    state->led_known = true;
    state->led_on = led_on;

    if (led_on) {
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

    /* Firmware, the logon UI, and a user session may each report LED state. */
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
    return state->force_on && state->led_known && !state->led_on &&
           state->force_pending && !state->injection_attempted &&
           !state->startup_completed;
}

void usb_hid_numlock_reset(USBHIDNumLockState *state)
{
    /* force_on is device configuration; USB reset clears runtime state only. */
    state->led_known = false;
    state->led_on = false;
    state->force_pending = false;
    state->injection_attempted = false;
    state->startup_completed = false;
}
