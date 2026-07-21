/*
 * USB HID NumLock 强制开启状态机
 *
 * 该头文件只描述与事件循环无关的决策状态。
 * 单元测试覆盖首次 OFF、重复 OFF、收到 ON、复位等边界。
 * 真正的 BH 调度和按键注入仍由 usb-kbd 设备负责。
 */

#ifndef HW_USB_HID_NUMLOCK_H
#define HW_USB_HID_NUMLOCK_H

typedef enum USBHIDNumLockAction {
    USB_HID_NUMLOCK_ACTION_NONE,
    USB_HID_NUMLOCK_ACTION_SCHEDULE,
    USB_HID_NUMLOCK_ACTION_CANCEL,
} USBHIDNumLockAction;

typedef struct USBHIDNumLockState {
    /* 命令行属性；默认关闭，不改变既有虚拟机行为。 */
    bool force_on;

    /* 以下运行态仅由 guest 的 HID SET_REPORT 更新。 */
    bool led_known;
    bool led_on;
    bool force_pending;

    /*
     * NumLock click 已经完整写入 HID 队列。
     * force_pending 会继续保持到 guest 回报 ON，
     * 该位用于避免迁移后再次注入同一个 click。
     */
    bool injection_attempted;

    /*
     * 该字段名为兼容既有迁移流和 QOM 诊断接口而保留。
     * true 表示最近一次 guest 报告已确认 ON；
     * 后续明确 OFF 会先清除此位，
     * 再建立新的单次注入轮次。
     */
    bool startup_completed;
} USBHIDNumLockState;

USBHIDNumLockAction usb_hid_numlock_report(USBHIDNumLockState *state,
                                            bool led_on);
bool usb_hid_numlock_should_inject(const USBHIDNumLockState *state);
void usb_hid_numlock_reset(USBHIDNumLockState *state);

#endif /* HW_USB_HID_NUMLOCK_H */
