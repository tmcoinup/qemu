/*
 * USB HID NumLock 强制开启状态机单元测试
 *
 * 重点验证明确 OFF 才触发、pending 去重和每次 reset 只初始化一次。
 * 事件循环及 USB 设备属性由 qtest 另行覆盖。
 */

#include "qemu/osdep.h"
#include "hw/usb/hid-numlock.h"

static void test_disabled_ignores_off_report(void)
{
    USBHIDNumLockState state = { 0 };

    g_assert_cmpint(usb_hid_numlock_report(&state, false), ==,
                    USB_HID_NUMLOCK_ACTION_NONE);
    g_assert_true(state.led_known);
    g_assert_false(state.led_on);
    g_assert_false(state.force_pending);
    g_assert_false(state.injection_attempted);
    g_assert_false(state.startup_completed);
    g_assert_false(usb_hid_numlock_should_inject(&state));

    g_assert_cmpint(usb_hid_numlock_report(&state, true), ==,
                    USB_HID_NUMLOCK_ACTION_NONE);
    g_assert_false(state.startup_completed);
}

static void test_enabled_only_forces_once_per_reset(void)
{
    USBHIDNumLockState state = {
        .force_on = true,
    };

    /* 未收到 guest 报告时，零值不能被误判为明确 OFF。 */
    g_assert_false(usb_hid_numlock_should_inject(&state));

    g_assert_cmpint(usb_hid_numlock_report(&state, false), ==,
                    USB_HID_NUMLOCK_ACTION_SCHEDULE);
    g_assert_true(state.force_pending);
    g_assert_true(usb_hid_numlock_should_inject(&state));

    /* BH 成功后仍等待 ON，但不能再次注入。 */
    state.injection_attempted = true;
    g_assert_true(state.force_pending);
    g_assert_false(usb_hid_numlock_should_inject(&state));

    /* Windows 重复发送 OFF 时不能再排入第二次翻转。 */
    g_assert_cmpint(usb_hid_numlock_report(&state, false), ==,
                    USB_HID_NUMLOCK_ACTION_NONE);
    g_assert_true(state.force_pending);

    /* ON 确认启动初始化完成。 */
    g_assert_cmpint(usb_hid_numlock_report(&state, true), ==,
                    USB_HID_NUMLOCK_ACTION_CANCEL);
    g_assert_false(state.force_pending);
    g_assert_false(state.injection_attempted);
    g_assert_true(state.startup_completed);
    g_assert_false(usb_hid_numlock_should_inject(&state));

    /* 完成后的 OFF 是用户手动关闭，不得再注入翻转键。 */
    g_assert_cmpint(usb_hid_numlock_report(&state, false), ==,
                    USB_HID_NUMLOCK_ACTION_NONE);
    g_assert_false(state.force_pending);
    g_assert_false(state.injection_attempted);
    g_assert_true(state.startup_completed);
}

static void test_on_without_pending_needs_no_cancel(void)
{
    USBHIDNumLockState state = {
        .force_on = true,
    };

    g_assert_cmpint(usb_hid_numlock_report(&state, true), ==,
                    USB_HID_NUMLOCK_ACTION_NONE);
    g_assert_true(state.led_known);
    g_assert_true(state.led_on);
    g_assert_false(state.force_pending);
    g_assert_true(state.startup_completed);

    g_assert_cmpint(usb_hid_numlock_report(&state, false), ==,
                    USB_HID_NUMLOCK_ACTION_NONE);
}

static void test_reset_clears_runtime_only(void)
{
    USBHIDNumLockState state = {
        .force_on = true,
    };

    g_assert_cmpint(usb_hid_numlock_report(&state, false), ==,
                    USB_HID_NUMLOCK_ACTION_SCHEDULE);
    g_assert_cmpint(usb_hid_numlock_report(&state, true), ==,
                    USB_HID_NUMLOCK_ACTION_CANCEL);
    g_assert_true(state.startup_completed);
    usb_hid_numlock_reset(&state);

    g_assert_true(state.force_on);
    g_assert_false(state.led_known);
    g_assert_false(state.led_on);
    g_assert_false(state.force_pending);
    g_assert_false(state.injection_attempted);
    g_assert_false(state.startup_completed);
    g_assert_false(usb_hid_numlock_should_inject(&state));

    g_assert_cmpint(usb_hid_numlock_report(&state, false), ==,
                    USB_HID_NUMLOCK_ACTION_SCHEDULE);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/usb-hid-numlock/disabled-off",
                    test_disabled_ignores_off_report);
    g_test_add_func("/usb-hid-numlock/enabled-once-per-reset",
                    test_enabled_only_forces_once_per_reset);
    g_test_add_func("/usb-hid-numlock/on-without-pending",
                    test_on_without_pending_needs_no_cancel);
    g_test_add_func("/usb-hid-numlock/reset",
                    test_reset_clears_runtime_only);
    return g_test_run();
}
