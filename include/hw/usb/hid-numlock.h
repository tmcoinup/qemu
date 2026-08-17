/*
 * USB HID NumLock forced-on convergence state machine.
 *
 * This header contains only event-loop-independent decision state.  The
 * usb-kbd device owns BH scheduling and key injection.
 */

#ifndef HW_USB_HID_NUMLOCK_H
#define HW_USB_HID_NUMLOCK_H

typedef enum USBHIDNumLockAction {
    USB_HID_NUMLOCK_ACTION_NONE,
    USB_HID_NUMLOCK_ACTION_SCHEDULE,
    USB_HID_NUMLOCK_ACTION_CANCEL,
} USBHIDNumLockAction;

typedef struct USBHIDNumLockState {
    /* Opt-in device property; disabled by default for upstream compatibility. */
    bool force_on;

    /* Runtime state is updated only from guest HID SET_REPORT requests. */
    bool led_known;
    bool led_on;
    bool force_pending;

    /* The complete press/release click has already entered the HID queue. */
    bool injection_attempted;

    /* The latest convergence epoch has received an explicit ON report. */
    bool startup_completed;
} USBHIDNumLockState;

USBHIDNumLockAction usb_hid_numlock_report(USBHIDNumLockState *state,
                                            bool led_on);
bool usb_hid_numlock_should_inject(const USBHIDNumLockState *state);
void usb_hid_numlock_reset(USBHIDNumLockState *state);

#endif /* HW_USB_HID_NUMLOCK_H */
