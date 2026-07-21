/*
 * QEMU USB HID devices
 *
 * Copyright (c) 2005 Fabrice Bellard
 * Copyright (c) 2007 OpenMoko, Inc.  (andrew@openedhand.com)
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

#include "qemu/osdep.h"
#include "ui/console.h"
#include "hw/usb/usb.h"
#include "migration/vmstate.h"
#include "desc.h"
#include "qapi/error.h"
#include "qemu/main-loop.h"
#include "qemu/module.h"
#include "qemu/timer.h"
#include "hw/input/hid.h"
#include "hw/usb/hid.h"
#include "hw/usb/hid-numlock.h"
#include "hw/core/qdev-properties.h"
#include "qom/object.h"

struct USBHIDState {
    USBDevice dev;
    USBEndpoint *intr;
    HIDState hid;
    uint32_t usb_version;
    char *display;
    uint32_t head;
    /* stealth (patch 0010): per-instance USB descriptor 覆盖。
     * cmdline -device usb-kbd,vendorid=0x046D,productid=0xC31C,
     *                  manufacturer=Logitech,product='Logitech USB Keyboard K120'
     * 让每台 VM 的 USB 键鼠 VID/PID/字符串都不同——配合 stealth-lib.sh 的
     * KBD_POOL / MOUSE_POOL / TABLET_POOL，多账号同主机反指纹不再同样。
     * 0 / NULL 表示不覆盖，保持 desc_* 静态默认 (Microsoft / HUION)。 */
    uint16_t vendorid;
    uint16_t productid;
    char *manufacturer;
    char *product;
    /* 内部：若 vendorid/productid 任一非 0，分配一份 USBDesc 副本写回 .id；
     * unrealize 时 g_free。dev->usb_desc 指向这份副本而不是 const 静态。 */
    USBDesc *patched_desc;

    /*
     * opt-in NumLock 强制开启状态。
     * 状态机仅接受 guest 的 SET_REPORT。
     * 每次明确 OFF 只建立一个等待 ON 的收敛轮次。
     * BH 用于避免 USB 设备重入。
     */
    USBHIDNumLockState numlock;
    QEMUBH *numlock_bh;

    /* 仅用于区分迁移流是否携带了可选 NumLock 子段。 */
    bool numlock_migration_loaded;
};

#define TYPE_USB_HID "usb-hid"
OBJECT_DECLARE_SIMPLE_TYPE(USBHIDState, USB_HID)

enum {
    STR_MANUFACTURER = 1,
    STR_PRODUCT_MOUSE,
    STR_PRODUCT_TABLET,
    STR_PRODUCT_KEYBOARD,
    STR_SERIAL_COMPAT,
    STR_CONFIG_MOUSE,
    STR_CONFIG_TABLET,
    STR_CONFIG_KEYBOARD,
    STR_SERIAL_MOUSE,
    STR_SERIAL_TABLET,
    STR_SERIAL_KEYBOARD,
};

static const USBDescStrings desc_strings = {
    /*
     * Stealth: real USB HID peripherals always identify as a vendor brand.
     * "QEMU"-prefixed strings are a one-line VM tell visible to anything
     * that walks SetupAPI / WMI Win32_PnPEntity. Microsoft Wired Keyboard 600
     * and Microsoft USB Optical Mouse are the most common bundled-with-PC
     * peripherals — generic enough not to invite product-specific HID quirks.
     */
    [STR_MANUFACTURER]         = "Microsoft",
    [STR_PRODUCT_MOUSE]        = "Microsoft USB Optical Mouse",
    [STR_PRODUCT_TABLET]       = "QEMU USB Tablet",
    [STR_PRODUCT_KEYBOARD]     = "Microsoft Wired Keyboard 600",
    [STR_SERIAL_COMPAT]        = "42",
    [STR_CONFIG_MOUSE]         = "HID Mouse",
    [STR_CONFIG_TABLET]        = "HID Tablet",
    [STR_CONFIG_KEYBOARD]      = "HID Keyboard",
    [STR_SERIAL_MOUSE]         = "89126",
    [STR_SERIAL_TABLET]        = "28754",
    [STR_SERIAL_KEYBOARD]      = "68284",
};

static const USBDescIface desc_iface_mouse = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 1,
    .bInterfaceClass               = USB_CLASS_HID,
    .bInterfaceSubClass            = 0x01, /* boot */
    .bInterfaceProtocol            = 0x02,
    .ndesc                         = 1,
    .descs = (USBDescOther[]) {
        {
            /* HID descriptor */
            .data = (uint8_t[]) {
                0x09,          /*  u8  bLength */
                USB_DT_HID,    /*  u8  bDescriptorType */
                0x01, 0x00,    /*  u16 HID_class */
                0x00,          /*  u8  country_code */
                0x01,          /*  u8  num_descriptors */
                USB_DT_REPORT, /*  u8  type: Report */
                52, 0,         /*  u16 len */
            },
        },
    },
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_INT,
            .wMaxPacketSize        = 4,
            .bInterval             = 0x0a,
        },
    },
};

static const USBDescIface desc_iface_mouse2 = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 1,
    .bInterfaceClass               = USB_CLASS_HID,
    .bInterfaceSubClass            = 0x01, /* boot */
    .bInterfaceProtocol            = 0x02,
    .ndesc                         = 1,
    .descs = (USBDescOther[]) {
        {
            /* HID descriptor */
            .data = (uint8_t[]) {
                0x09,          /*  u8  bLength */
                USB_DT_HID,    /*  u8  bDescriptorType */
                0x01, 0x00,    /*  u16 HID_class */
                0x00,          /*  u8  country_code */
                0x01,          /*  u8  num_descriptors */
                USB_DT_REPORT, /*  u8  type: Report */
                52, 0,         /*  u16 len */
            },
        },
    },
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_INT,
            .wMaxPacketSize        = 4,
            .bInterval             = 7, /* 2 ^ (8-1) * 125 usecs = 8 ms */
        },
    },
};

static const USBDescIface desc_iface_tablet = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 1,
    .bInterfaceClass               = USB_CLASS_HID,
    .bInterfaceProtocol            = 0x00,
    .ndesc                         = 1,
    .descs = (USBDescOther[]) {
        {
            /* HID descriptor */
            .data = (uint8_t[]) {
                0x09,          /*  u8  bLength */
                USB_DT_HID,    /*  u8  bDescriptorType */
                0x01, 0x00,    /*  u16 HID_class */
                0x00,          /*  u8  country_code */
                0x01,          /*  u8  num_descriptors */
                USB_DT_REPORT, /*  u8  type: Report */
                74, 0,         /*  u16 len */
            },
        },
    },
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_INT,
            .wMaxPacketSize        = 8,
            .bInterval             = 0x0a,
        },
    },
};

static const USBDescIface desc_iface_tablet2 = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 1,
    .bInterfaceClass               = USB_CLASS_HID,
    .bInterfaceProtocol            = 0x00,
    .ndesc                         = 1,
    .descs = (USBDescOther[]) {
        {
            /* HID descriptor */
            .data = (uint8_t[]) {
                0x09,          /*  u8  bLength */
                USB_DT_HID,    /*  u8  bDescriptorType */
                0x01, 0x00,    /*  u16 HID_class */
                0x00,          /*  u8  country_code */
                0x01,          /*  u8  num_descriptors */
                USB_DT_REPORT, /*  u8  type: Report */
                74, 0,         /*  u16 len */
            },
        },
    },
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_INT,
            .wMaxPacketSize        = 8,
            .bInterval             = 4, /* 2 ^ (4-1) * 125 usecs = 1 ms */
        },
    },
};

static const USBDescIface desc_iface_keyboard = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 1,
    .bInterfaceClass               = USB_CLASS_HID,
    .bInterfaceSubClass            = 0x01, /* boot */
    .bInterfaceProtocol            = 0x01, /* keyboard */
    .ndesc                         = 1,
    .descs = (USBDescOther[]) {
        {
            /* HID descriptor */
            .data = (uint8_t[]) {
                0x09,          /*  u8  bLength */
                USB_DT_HID,    /*  u8  bDescriptorType */
                0x11, 0x01,    /*  u16 HID_class */
                0x00,          /*  u8  country_code */
                0x01,          /*  u8  num_descriptors */
                USB_DT_REPORT, /*  u8  type: Report */
                0x3f, 0,       /*  u16 len */
            },
        },
    },
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_INT,
            .wMaxPacketSize        = 8,
            .bInterval             = 0x0a,
        },
    },
};

static const USBDescIface desc_iface_keyboard2 = {
    .bInterfaceNumber              = 0,
    .bNumEndpoints                 = 1,
    .bInterfaceClass               = USB_CLASS_HID,
    .bInterfaceSubClass            = 0x01, /* boot */
    .bInterfaceProtocol            = 0x01, /* keyboard */
    .ndesc                         = 1,
    .descs = (USBDescOther[]) {
        {
            /* HID descriptor */
            .data = (uint8_t[]) {
                0x09,          /*  u8  bLength */
                USB_DT_HID,    /*  u8  bDescriptorType */
                0x11, 0x01,    /*  u16 HID_class */
                0x00,          /*  u8  country_code */
                0x01,          /*  u8  num_descriptors */
                USB_DT_REPORT, /*  u8  type: Report */
                0x3f, 0,       /*  u16 len */
            },
        },
    },
    .eps = (USBDescEndpoint[]) {
        {
            .bEndpointAddress      = USB_DIR_IN | 0x01,
            .bmAttributes          = USB_ENDPOINT_XFER_INT,
            .wMaxPacketSize        = 8,
            .bInterval             = 7, /* 2 ^ (8-1) * 125 usecs = 8 ms */
        },
    },
};

static const USBDescDevice desc_device_mouse = {
    .bcdUSB                        = 0x0100,
    .bMaxPacketSize0               = 8,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_CONFIG_MOUSE,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_WAKEUP,
            .bMaxPower             = 50,
            .nif = 1,
            .ifs = &desc_iface_mouse,
        },
    },
};

static const USBDescDevice desc_device_mouse2 = {
    .bcdUSB                        = 0x0200,
    .bMaxPacketSize0               = 64,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_CONFIG_MOUSE,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_WAKEUP,
            .bMaxPower             = 50,
            .nif = 1,
            .ifs = &desc_iface_mouse2,
        },
    },
};

static const USBDescDevice desc_device_tablet = {
    .bcdUSB                        = 0x0100,
    .bMaxPacketSize0               = 8,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_CONFIG_TABLET,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_WAKEUP,
            .bMaxPower             = 50,
            .nif = 1,
            .ifs = &desc_iface_tablet,
        },
    },
};

static const USBDescDevice desc_device_tablet2 = {
    .bcdUSB                        = 0x0200,
    .bMaxPacketSize0               = 64,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_CONFIG_TABLET,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_WAKEUP,
            .bMaxPower             = 50,
            .nif = 1,
            .ifs = &desc_iface_tablet2,
        },
    },
};

static const USBDescDevice desc_device_keyboard = {
    .bcdUSB                        = 0x0100,
    .bMaxPacketSize0               = 8,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_CONFIG_KEYBOARD,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_WAKEUP,
            .bMaxPower             = 50,
            .nif = 1,
            .ifs = &desc_iface_keyboard,
        },
    },
};

static const USBDescDevice desc_device_keyboard2 = {
    .bcdUSB                        = 0x0200,
    .bMaxPacketSize0               = 64,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 1,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_CONFIG_KEYBOARD,
            .bmAttributes          = USB_CFG_ATT_ONE | USB_CFG_ATT_WAKEUP,
            .bMaxPower             = 50,
            .nif = 1,
            .ifs = &desc_iface_keyboard2,
        },
    },
};

static const USBDescMSOS desc_msos_suspend = {
    .SelectiveSuspendEnabled = true,
};

/*
 * Stealth: 0x0627 ("Adomax Technology Co., Ltd") is the QEMU-default USB
 * HID VID — anything that cross-references USB IDs (lsusb -v, USB.org
 * online lookup, or anti-cheat databases of well-known peripheral pairs)
 * sees Adomax+0x0001 and concludes "QEMU virtual HID". Switch to real
 * Microsoft VID 0x045E with retail PIDs that match the iProduct strings:
 *   - Mouse:    045E:00CB (Microsoft USB Optical Mouse)
 *   - Keyboard: 045E:0750 (Microsoft Wired Keyboard 600)
 * Tablet 例外：当前 report descriptor 只是绝对坐标指针，并不实现任何
 * 品牌数位笔协议，所以保留 0627:0001 与 QEMU USB Tablet 名称。
 */
/*
 * bcdDevice: 真硬件设备版本号在 USB ID 数据库里都不为 0。bcdDevice=0 是
 * QEMU 默认值，对 anti-cheat 而言是一个 telltale（"无版本号的 USB HID =
 * 必然虚拟"）。改为公开报告的真实硬件 firmware revision：
 *   - Microsoft USB Optical Mouse 045E:00CB → bcdDevice 0x0163
 *   - Microsoft Wired Keyboard 600 045E:0750 → bcdDevice 0x0163
 *   - 通用 usb-tablet 保留 bcdDevice 0，明确表示没有厂商固件版本
 *
 * iSerialNumber: 真实 OEM mouse/keyboard 都不暴露 serial 字符串（iSerialNumber=0）。
 * 之前给的 "68284" / "89126" / "28754" 这类 4-5 位 random 数 string 在 lsusb -v
 * / WMI Win32_PnPEntity.PNPDeviceID 里会被 anti-cheat 拿来 fingerprint。
 * 设 0 让 OS 不查询 serial（descriptor 里 iSerial=0 即"无 serial"，
 * USB spec 合法）。
 */
static const USBDesc desc_mouse = {
    .id = {
        .idVendor          = 0x045E,
        .idProduct         = 0x00CB,
        .bcdDevice         = 0x0163,
        .iManufacturer     = STR_MANUFACTURER,
        .iProduct          = STR_PRODUCT_MOUSE,
        .iSerialNumber     = 0,
    },
    .full = &desc_device_mouse,
    .str  = desc_strings,
    .msos = &desc_msos_suspend,
};

static const USBDesc desc_mouse2 = {
    .id = {
        .idVendor          = 0x045E,
        .idProduct         = 0x00CB,
        .bcdDevice         = 0x0163,
        .iManufacturer     = STR_MANUFACTURER,
        .iProduct          = STR_PRODUCT_MOUSE,
        .iSerialNumber     = 0,
    },
    .full = &desc_device_mouse,
    .high = &desc_device_mouse2,
    .str  = desc_strings,
    .msos = &desc_msos_suspend,
};

static const USBDesc desc_tablet = {
    .id = {
        /*
         * usb-tablet 只实现通用绝对坐标指针，没有数位笔压力、倾角和厂商
         * report protocol，因此必须保留 QEMU 公共 VID/PID，不能冒充 HUION。
         */
        .idVendor          = 0x0627,
        .idProduct         = 0x0001,
        .bcdDevice         = 0x0000,
        .iManufacturer     = 0,
        .iProduct          = STR_PRODUCT_TABLET,
        .iSerialNumber     = 0,
    },
    .full = &desc_device_tablet,
    .str  = desc_strings,
    .msos = &desc_msos_suspend,
};

static const USBDesc desc_tablet2 = {
    .id = {
        .idVendor          = 0x0627,
        .idProduct         = 0x0001,
        .bcdDevice         = 0x0000,
        .iManufacturer     = 0,
        .iProduct          = STR_PRODUCT_TABLET,
        .iSerialNumber     = 0,
    },
    .full = &desc_device_tablet,
    .high = &desc_device_tablet2,
    .str  = desc_strings,
    .msos = &desc_msos_suspend,
};

static const USBDesc desc_keyboard = {
    .id = {
        .idVendor          = 0x045E,
        .idProduct         = 0x0750,
        .bcdDevice         = 0x0163,
        .iManufacturer     = STR_MANUFACTURER,
        .iProduct          = STR_PRODUCT_KEYBOARD,
        .iSerialNumber     = 0,
    },
    .full = &desc_device_keyboard,
    .str  = desc_strings,
    .msos = &desc_msos_suspend,
};

static const USBDesc desc_keyboard2 = {
    .id = {
        .idVendor          = 0x045E,
        .idProduct         = 0x0750,
        .bcdDevice         = 0x0163,
        .iManufacturer     = STR_MANUFACTURER,
        .iProduct          = STR_PRODUCT_KEYBOARD,
        .iSerialNumber     = 0,
    },
    .full = &desc_device_keyboard,
    .high = &desc_device_keyboard2,
    .str  = desc_strings,
    .msos = &desc_msos_suspend,
};

static const uint8_t qemu_mouse_hid_report_descriptor[] = {
    0x05, 0x01,		/* Usage Page (Generic Desktop) */
    0x09, 0x02,		/* Usage (Mouse) */
    0xa1, 0x01,		/* Collection (Application) */
    0x09, 0x01,		/*   Usage (Pointer) */
    0xa1, 0x00,		/*   Collection (Physical) */
    0x05, 0x09,		/*     Usage Page (Button) */
    0x19, 0x01,		/*     Usage Minimum (1) */
    0x29, 0x05,		/*     Usage Maximum (5) */
    0x15, 0x00,		/*     Logical Minimum (0) */
    0x25, 0x01,		/*     Logical Maximum (1) */
    0x95, 0x05,		/*     Report Count (5) */
    0x75, 0x01,		/*     Report Size (1) */
    0x81, 0x02,		/*     Input (Data, Variable, Absolute) */
    0x95, 0x01,		/*     Report Count (1) */
    0x75, 0x03,		/*     Report Size (3) */
    0x81, 0x01,		/*     Input (Constant) */
    0x05, 0x01,		/*     Usage Page (Generic Desktop) */
    0x09, 0x30,		/*     Usage (X) */
    0x09, 0x31,		/*     Usage (Y) */
    0x09, 0x38,		/*     Usage (Wheel) */
    0x15, 0x81,		/*     Logical Minimum (-0x7f) */
    0x25, 0x7f,		/*     Logical Maximum (0x7f) */
    0x75, 0x08,		/*     Report Size (8) */
    0x95, 0x03,		/*     Report Count (3) */
    0x81, 0x06,		/*     Input (Data, Variable, Relative) */
    0xc0,		/*   End Collection */
    0xc0,		/* End Collection */
};

static const uint8_t qemu_tablet_hid_report_descriptor[] = {
    0x05, 0x01,		/* Usage Page (Generic Desktop) */
    0x09, 0x02,		/* Usage (Mouse) */
    0xa1, 0x01,		/* Collection (Application) */
    0x09, 0x01,		/*   Usage (Pointer) */
    0xa1, 0x00,		/*   Collection (Physical) */
    0x05, 0x09,		/*     Usage Page (Button) */
    0x19, 0x01,		/*     Usage Minimum (1) */
    0x29, 0x05,		/*     Usage Maximum (5) */
    0x15, 0x00,		/*     Logical Minimum (0) */
    0x25, 0x01,		/*     Logical Maximum (1) */
    0x95, 0x05,		/*     Report Count (5) */
    0x75, 0x01,		/*     Report Size (1) */
    0x81, 0x02,		/*     Input (Data, Variable, Absolute) */
    0x95, 0x01,		/*     Report Count (1) */
    0x75, 0x03,		/*     Report Size (3) */
    0x81, 0x01,		/*     Input (Constant) */
    0x05, 0x01,		/*     Usage Page (Generic Desktop) */
    0x09, 0x30,		/*     Usage (X) */
    0x09, 0x31,		/*     Usage (Y) */
    0x15, 0x00,		/*     Logical Minimum (0) */
    0x26, 0xff, 0x7f,	/*     Logical Maximum (0x7fff) */
    0x35, 0x00,		/*     Physical Minimum (0) */
    0x46, 0xff, 0x7f,	/*     Physical Maximum (0x7fff) */
    0x75, 0x10,		/*     Report Size (16) */
    0x95, 0x02,		/*     Report Count (2) */
    0x81, 0x02,		/*     Input (Data, Variable, Absolute) */
    0x05, 0x01,		/*     Usage Page (Generic Desktop) */
    0x09, 0x38,		/*     Usage (Wheel) */
    0x15, 0x81,		/*     Logical Minimum (-0x7f) */
    0x25, 0x7f,		/*     Logical Maximum (0x7f) */
    0x35, 0x00,		/*     Physical Minimum (same as logical) */
    0x45, 0x00,		/*     Physical Maximum (same as logical) */
    0x75, 0x08,		/*     Report Size (8) */
    0x95, 0x01,		/*     Report Count (1) */
    0x81, 0x06,		/*     Input (Data, Variable, Relative) */
    0xc0,		/*   End Collection */
    0xc0,		/* End Collection */
};

static const uint8_t qemu_keyboard_hid_report_descriptor[] = {
    0x05, 0x01,		/* Usage Page (Generic Desktop) */
    0x09, 0x06,		/* Usage (Keyboard) */
    0xa1, 0x01,		/* Collection (Application) */
    0x75, 0x01,		/*   Report Size (1) */
    0x95, 0x08,		/*   Report Count (8) */
    0x05, 0x07,		/*   Usage Page (Key Codes) */
    0x19, 0xe0,		/*   Usage Minimum (224) */
    0x29, 0xe7,		/*   Usage Maximum (231) */
    0x15, 0x00,		/*   Logical Minimum (0) */
    0x25, 0x01,		/*   Logical Maximum (1) */
    0x81, 0x02,		/*   Input (Data, Variable, Absolute) */
    0x95, 0x01,		/*   Report Count (1) */
    0x75, 0x08,		/*   Report Size (8) */
    0x81, 0x01,		/*   Input (Constant) */
    0x95, 0x05,		/*   Report Count (5) */
    0x75, 0x01,		/*   Report Size (1) */
    0x05, 0x08,		/*   Usage Page (LEDs) */
    0x19, 0x01,		/*   Usage Minimum (1) */
    0x29, 0x05,		/*   Usage Maximum (5) */
    0x91, 0x02,		/*   Output (Data, Variable, Absolute) */
    0x95, 0x01,		/*   Report Count (1) */
    0x75, 0x03,		/*   Report Size (3) */
    0x91, 0x01,		/*   Output (Constant) */
    0x95, 0x06,		/*   Report Count (6) */
    0x75, 0x08,		/*   Report Size (8) */
    0x15, 0x00,		/*   Logical Minimum (0) */
    0x25, 0xff,		/*   Logical Maximum (255) */
    0x05, 0x07,		/*   Usage Page (Key Codes) */
    0x19, 0x00,		/*   Usage Minimum (0) */
    0x29, 0xff,		/*   Usage Maximum (255) */
    0x81, 0x00,		/*   Input (Data, Array) */
    0xc0,		/* End Collection */
};

static void usb_hid_changed(HIDState *hs)
{
    USBHIDState *us = container_of(hs, USBHIDState, hid);

    usb_wakeup(us->intr, 0);
}

static void usb_keyboard_force_numlock_bh(void *opaque)
{
    USBHIDState *us = opaque;

    /*
     * LED 可能在 BH 执行前已变为 ON，或设备已 reset。
     * 再次检查完整状态，避免注入过期的翻转键。
     */
    if (!usb_hid_numlock_should_inject(&us->numlock)) {
        return;
    }

    if (hid_keyboard_send_key_click(&us->hid, Q_KEY_CODE_NUM_LOCK)) {
        /*
         * click 已原子进入 HID 队列；pending 继续等待 guest 的 ON 确认。
         * 迁移时保存该位，目的端不能再加入第二个 click。
         */
        us->numlock.injection_attempted = true;
    } else {
        /*
         * 队列满时不能只加入按下事件。
         * 放弃本次 pending，允许后续 OFF 报告再触发；
         * 这里不自旋重调度，以免卡住主循环。
         */
        us->numlock.force_pending = false;
        us->numlock.injection_attempted = false;
    }
}

static void usb_keyboard_numlock_report(USBHIDState *us, bool led_on)
{
    USBHIDNumLockAction action =
        usb_hid_numlock_report(&us->numlock, led_on);

    if (!us->numlock_bh) {
        return;
    }

    switch (action) {
    case USB_HID_NUMLOCK_ACTION_SCHEDULE:
        qemu_bh_schedule(us->numlock_bh);
        break;
    case USB_HID_NUMLOCK_ACTION_CANCEL:
        qemu_bh_cancel(us->numlock_bh);
        break;
    case USB_HID_NUMLOCK_ACTION_NONE:
        break;
    }
}

static void usb_keyboard_numlock_reset(USBHIDState *us)
{
    if (us->numlock_bh) {
        qemu_bh_cancel(us->numlock_bh);
    }
    usb_hid_numlock_reset(&us->numlock);
}

static void usb_hid_handle_reset(USBDevice *dev)
{
    USBHIDState *us = USB_HID(dev);

    usb_keyboard_numlock_reset(us);
    hid_reset(&us->hid);
}

static void usb_hid_handle_control(USBDevice *dev, USBPacket *p,
               int request, int value, int index, int length, uint8_t *data)
{
    USBHIDState *us = USB_HID(dev);
    HIDState *hs = &us->hid;
    int ret;

    ret = usb_desc_handle_control(dev, p, request, value, index, length, data);
    if (ret >= 0) {
        return;
    }

    switch (request) {
        /* hid specific requests */
    case InterfaceRequest | USB_REQ_GET_DESCRIPTOR:
        switch (value >> 8) {
        case 0x22:
            if (hs->kind == HID_MOUSE) {
                memcpy(data, qemu_mouse_hid_report_descriptor,
                       sizeof(qemu_mouse_hid_report_descriptor));
                p->actual_length = sizeof(qemu_mouse_hid_report_descriptor);
            } else if (hs->kind == HID_TABLET) {
                memcpy(data, qemu_tablet_hid_report_descriptor,
                       sizeof(qemu_tablet_hid_report_descriptor));
                p->actual_length = sizeof(qemu_tablet_hid_report_descriptor);
            } else if (hs->kind == HID_KEYBOARD) {
                memcpy(data, qemu_keyboard_hid_report_descriptor,
                       sizeof(qemu_keyboard_hid_report_descriptor));
                p->actual_length = sizeof(qemu_keyboard_hid_report_descriptor);
            }
            break;
        default:
            goto fail;
        }
        break;
    case HID_GET_REPORT:
        if (hs->kind == HID_MOUSE || hs->kind == HID_TABLET) {
            p->actual_length = hid_pointer_poll(hs, data, length);
        } else if (hs->kind == HID_KEYBOARD) {
            p->actual_length = hid_keyboard_poll(hs, data, length);
        }
        break;
    case HID_SET_REPORT:
        if (hs->kind == HID_KEYBOARD) {
            p->actual_length = hid_keyboard_write(hs, data, length);
            if (p->actual_length > 0) {
                /* 只信任 guest 报告，不猜测初始状态。 */
                usb_keyboard_numlock_report(
                    us, (data[0] & HID_KBD_LED_NUM_LOCK) != 0);
            }
        } else {
            goto fail;
        }
        break;
    case HID_GET_PROTOCOL:
        if (hs->kind != HID_KEYBOARD && hs->kind != HID_MOUSE) {
            goto fail;
        }
        data[0] = hs->protocol;
        p->actual_length = 1;
        break;
    case HID_SET_PROTOCOL:
        if (hs->kind != HID_KEYBOARD && hs->kind != HID_MOUSE) {
            goto fail;
        }
        hs->protocol = value;
        break;
    case HID_GET_IDLE:
        data[0] = hs->idle;
        p->actual_length = 1;
        break;
    case HID_SET_IDLE:
        hs->idle = (uint8_t) (value >> 8);
        hid_set_next_idle(hs);
        if (hs->kind == HID_MOUSE || hs->kind == HID_TABLET) {
            hid_pointer_activate(hs);
        }
        break;
    default:
    fail:
        p->status = USB_RET_STALL;
        break;
    }
}

static void usb_hid_handle_data(USBDevice *dev, USBPacket *p)
{
    USBHIDState *us = USB_HID(dev);
    HIDState *hs = &us->hid;
    g_autofree uint8_t *buf = g_malloc(p->iov.size);
    int len = 0;

    switch (p->pid) {
    case USB_TOKEN_IN:
        if (p->ep->nr == 1) {
            if (hs->kind == HID_MOUSE || hs->kind == HID_TABLET) {
                hid_pointer_activate(hs);
            }
            if (!hid_has_events(hs)) {
                p->status = USB_RET_NAK;
                return;
            }
            hid_set_next_idle(hs);
            if (hs->kind == HID_MOUSE || hs->kind == HID_TABLET) {
                len = hid_pointer_poll(hs, buf, p->iov.size);
            } else if (hs->kind == HID_KEYBOARD) {
                len = hid_keyboard_poll(hs, buf, p->iov.size);
            }
            usb_packet_copy(p, buf, len);
        } else {
            goto fail;
        }
        break;
    case USB_TOKEN_OUT:
    default:
    fail:
        p->status = USB_RET_STALL;
        break;
    }
}

static void usb_hid_unrealize(USBDevice *dev)
{
    USBHIDState *us = USB_HID(dev);

    usb_keyboard_numlock_reset(us);
    if (us->numlock_bh) {
        qemu_bh_delete(us->numlock_bh);
        us->numlock_bh = NULL;
    }
    hid_free(&us->hid);
    /* stealth (patch 0010): 释放 VID/PID 覆盖时分配的 USBDesc 副本 */
    if (us->patched_desc) {
        g_free(us->patched_desc);
        us->patched_desc = NULL;
    }
}

static void usb_hid_initfn(USBDevice *dev, int kind,
                           const USBDesc *usb1, const USBDesc *usb2,
                           Error **errp)
{
    USBHIDState *us = USB_HID(dev);
    const USBDesc *selected;
    switch (us->usb_version) {
    case 1:
        selected = usb1;
        break;
    case 2:
        selected = usb2;
        break;
    default:
        selected = NULL;
    }
    if (!selected) {
        error_setg(errp, "Invalid usb version %d for usb hid device",
                   us->usb_version);
        return;
    }

    if (kind == HID_TABLET &&
        (us->vendorid || us->productid || us->manufacturer || us->product)) {
        error_setg(errp, "usb-tablet emulates only a generic absolute "
                         "pointer; branded tablet descriptors are unsupported");
        return;
    }

    /* stealth (patch 0010): VID/PID 覆盖。
     * 任一非零就 g_memdup() 出一份可写副本，patch .id 后挂到 dev->usb_desc。
     * 字符串覆盖在 usb_desc_init() 之后用 usb_desc_set_string() 写入设备的
     * per-instance strings list（不动 const desc_strings 静态表）。 */
    if (us->vendorid || us->productid) {
        us->patched_desc = g_memdup2(selected, sizeof(*selected));
        if (us->vendorid) {
            us->patched_desc->id.idVendor = us->vendorid;
        }
        if (us->productid) {
            us->patched_desc->id.idProduct = us->productid;
        }
        dev->usb_desc = us->patched_desc;
    } else {
        dev->usb_desc = selected;
    }

    /* stealth: 真实 OEM 鼠/键/平板的 USB descriptor 不暴露 serial 字符串
     * (iSerialNumber=0，见上文 desc_mouse / desc_keyboard / desc_tablet)。
     * usb_desc_create_serial() 在没有 dev->serial 时 assert(index != 0)，
     * 因此裸 usb-kbd/usb-mouse/usb-tablet（无 serial= 属性）会直接崩溃。
     * 仅当 descriptor 真正声明了 serial 索引时才生成 serial 字符串；
     * iSerialNumber==0 时无可写入的 descriptor 槽，dev->serial 也无意义。 */
    if (dev->usb_desc->id.iSerialNumber != 0) {
        usb_desc_create_serial(dev);
    }
    usb_desc_init(dev);

    /* 字符串覆盖：iManufacturer / iProduct 索引从 desc.id 读出，向 device
     * 的 per-instance strings 写入；usb_desc_set_string 内部 g_free 旧值。 */
    if (us->manufacturer && dev->usb_desc->id.iManufacturer) {
        usb_desc_set_string(dev, dev->usb_desc->id.iManufacturer,
                            us->manufacturer);
    }
    if (us->product && dev->usb_desc->id.iProduct) {
        usb_desc_set_string(dev, dev->usb_desc->id.iProduct, us->product);
    }

    us->intr = usb_ep_get(dev, USB_TOKEN_IN, 1);
    hid_init(&us->hid, kind, usb_hid_changed);
    if (us->display && us->hid.s) {
        qemu_input_handler_bind(us->hid.s, us->display, us->head, NULL);
    }
}

static void usb_tablet_realize(USBDevice *dev, Error **errp)
{

    usb_hid_initfn(dev, HID_TABLET, &desc_tablet, &desc_tablet2, errp);
}

static void usb_mouse_realize(USBDevice *dev, Error **errp)
{
    usb_hid_initfn(dev, HID_MOUSE, &desc_mouse, &desc_mouse2, errp);
}

static void usb_keyboard_realize(USBDevice *dev, Error **errp)
{
    USBHIDState *us = USB_HID(dev);

    usb_hid_initfn(dev, HID_KEYBOARD, &desc_keyboard, &desc_keyboard2, errp);
    if (us->numlock.force_on && us->hid.s) {
        /*
         * SET_REPORT 位于 USB 控制器调用栈内。
         * guarded BH 将注入推迟到主循环安全点，
         * 并启用设备重入保护。
         */
        us->numlock_bh = qemu_bh_new_guarded(
            usb_keyboard_force_numlock_bh, us,
            &DEVICE(dev)->mem_reentrancy_guard);
    }
}

static int usb_ptr_post_load(void *opaque, int version_id)
{
    USBHIDState *s = opaque;

    if (s->dev.remote_wakeup) {
        hid_pointer_activate(&s->hid);
    }
    return 0;
}

static int usb_keyboard_pre_load(void *opaque)
{
    USBHIDState *us = opaque;

    /*
     * loadvm 可能复用当前设备实例，不能让旧运行态混入迁移流。
     * 子段若存在，会在主 post_load 之前重新填充这些字段。
     */
    usb_keyboard_numlock_reset(us);
    us->numlock_migration_loaded = false;
    return 0;
}

static bool usb_keyboard_numlock_migration_needed(void *opaque)
{
    USBHIDState *us = opaque;

    /*
     * 属性默认关闭时不发送新子段，保持既有 usb-kbd v1 迁移流。
     * 显式启用后即使运行态全为零也要发送：led_known=false 是有意义的
     * “尚未收到 guest 报告”，不能在新版本之间被误判成旧迁移流。
     */
    return us->numlock.force_on;
}

static int usb_keyboard_numlock_subsection_post_load(void *opaque,
                                                      int version_id)
{
    USBHIDState *us = opaque;

    us->numlock_migration_loaded = true;
    return 0;
}

static const VMStateDescription vmstate_usb_kbd_numlock = {
    .name = "usb-kbd/numlock-startup",
    .version_id = 1,
    .minimum_version_id = 1,
    .post_load = usb_keyboard_numlock_subsection_post_load,
    .needed = usb_keyboard_numlock_migration_needed,
    .fields = (const VMStateField[]) {
        VMSTATE_BOOL(numlock.led_known, USBHIDState),
        VMSTATE_BOOL(numlock.led_on, USBHIDState),
        VMSTATE_BOOL(numlock.force_pending, USBHIDState),
        VMSTATE_BOOL(numlock.injection_attempted, USBHIDState),
        VMSTATE_BOOL(numlock.startup_completed, USBHIDState),
        VMSTATE_END_OF_LIST()
    }
};

static bool usb_keyboard_post_load(void *opaque, int version_id, Error **errp)
{
    USBHIDState *us = opaque;
    bool hid_led_on = (us->hid.kbd.leds & HID_KBD_LED_NUM_LOCK) != 0;
    bool subsection_loaded = us->numlock_migration_loaded;

    /* marker 只服务本次 load，确保后续 loadvm 能正确识别旧流。 */
    us->numlock_migration_loaded = false;

    if (!subsection_loaded) {
        if (us->numlock.force_on) {
            /*
             * 旧迁移流没有一次性锁存，无法判断 OFF 是启动状态还是用户操作。
             * 采用保守兼容策略：以已迁移的 HID LED 为准，并视为本周期已完成，
             * 避免目的端迁移完成后擅自翻转用户状态。
             */
            us->numlock.led_known = true;
            us->numlock.led_on = hid_led_on;
            us->numlock.startup_completed = true;
        }
        return true;
    }

    /* 子段只应出现在源端和目的端都显式启用功能时。 */
    if (!us->numlock.force_on) {
        error_setg(errp, "usb-kbd NumLock migration state requires "
                   "x-force-numlock-on=on on the destination");
        return false;
    }

    /*
     * hid.kbd.leds 已由主 usb-kbd 状态恢复；收到报告后两份事实必须一致。
     * led_known=false 本身是合法状态，但不能同时携带任何派生运行态。
     */
    if ((!us->numlock.led_known &&
         (us->numlock.led_on || us->numlock.force_pending ||
          us->numlock.injection_attempted ||
          us->numlock.startup_completed)) ||
        (us->numlock.led_known && us->numlock.led_on != hid_led_on)) {
        error_setg(errp, "usb-kbd NumLock migration state disagrees with "
                   "the migrated HID LED report");
        return false;
    }

    /*
     * v1 子段的旧实现允许 completed=true
     * 与明确 OFF 同时存在，用它表示“用户手动关闭”。
     * 持续强制语义下，这正是一个尚未收敛的轮次。
     * 在目的端归一化为 pending，
     * 并且仍只会排入一个原子 click。
     *
     * 没有 NumLock 子段的旧迁移流已在上方保守返回。
     * 不能把 HID leds 的零值猜成 guest 明确回报 OFF。
     */
    if (us->numlock.led_known && !us->numlock.led_on &&
        !us->numlock.force_pending &&
        !us->numlock.injection_attempted) {
        us->numlock.startup_completed = false;
        us->numlock.force_pending = true;
        us->numlock.injection_attempted = false;
    }

    if ((us->numlock.injection_attempted &&
         !us->numlock.force_pending) ||
        (us->numlock.force_pending &&
         (us->numlock.led_on || us->numlock.startup_completed)) ||
        (us->numlock.led_on && !us->numlock.startup_completed)) {
        error_setg(errp, "usb-kbd NumLock migration state has an invalid "
                   "pending/completed combination");
        return false;
    }

    /* 仅恢复源端尚未执行的 BH；已入队的 click 会随 HID 队列迁移。 */
    if (usb_hid_numlock_should_inject(&us->numlock) && us->numlock_bh) {
        qemu_bh_schedule(us->numlock_bh);
    }
    return true;
}

static const VMStateDescription vmstate_usb_ptr = {
    .name = "usb-ptr",
    .version_id = 1,
    .minimum_version_id = 1,
    .post_load = usb_ptr_post_load,
    .fields = (const VMStateField[]) {
        VMSTATE_USB_DEVICE(dev, USBHIDState),
        VMSTATE_HID_POINTER_DEVICE(hid, USBHIDState),
        VMSTATE_END_OF_LIST()
    }
};

static const VMStateDescription vmstate_usb_kbd = {
    .name = "usb-kbd",
    .version_id = 1,
    .minimum_version_id = 1,
    .pre_load = usb_keyboard_pre_load,
    .post_load_errp = usb_keyboard_post_load,
    .fields = (const VMStateField[]) {
        VMSTATE_USB_DEVICE(dev, USBHIDState),
        VMSTATE_HID_KEYBOARD_DEVICE(hid, USBHIDState),
        VMSTATE_END_OF_LIST()
    },
    .subsections = (const VMStateDescription * const []) {
        &vmstate_usb_kbd_numlock,
        NULL
    }
};

static void usb_hid_class_initfn(ObjectClass *klass, const void *data)
{
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->handle_reset   = usb_hid_handle_reset;
    uc->handle_control = usb_hid_handle_control;
    uc->handle_data    = usb_hid_handle_data;
    uc->unrealize      = usb_hid_unrealize;
    uc->handle_attach  = usb_desc_attach;
}

static const TypeInfo usb_hid_type_info = {
    .name = TYPE_USB_HID,
    .parent = TYPE_USB_DEVICE,
    .instance_size = sizeof(USBHIDState),
    .abstract = true,
    .class_init = usb_hid_class_initfn,
};

static const Property usb_tablet_properties[] = {
        DEFINE_PROP_UINT32("usb_version", USBHIDState, usb_version, 2),
        DEFINE_PROP_STRING("display", USBHIDState, display),
        DEFINE_PROP_UINT32("head", USBHIDState, head, 0),
        /* stealth (patch 0010): VID/PID/manufacturer/product 覆盖 */
        DEFINE_PROP_UINT16("vendorid", USBHIDState, vendorid, 0),
        DEFINE_PROP_UINT16("productid", USBHIDState, productid, 0),
        DEFINE_PROP_STRING("manufacturer", USBHIDState, manufacturer),
        DEFINE_PROP_STRING("product", USBHIDState, product),
};

static void usb_tablet_class_initfn(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->realize        = usb_tablet_realize;
    uc->product_desc   = "QEMU USB Tablet";
    dc->vmsd = &vmstate_usb_ptr;
    device_class_set_props(dc, usb_tablet_properties);
    set_bit(DEVICE_CATEGORY_INPUT, dc->categories);
}

static const TypeInfo usb_tablet_info = {
    .name          = "usb-tablet",
    .parent        = TYPE_USB_HID,
    .class_init    = usb_tablet_class_initfn,
};

static const Property usb_mouse_properties[] = {
        DEFINE_PROP_UINT32("usb_version", USBHIDState, usb_version, 2),
        /* stealth (patch 0010): VID/PID/manufacturer/product 覆盖 */
        DEFINE_PROP_UINT16("vendorid", USBHIDState, vendorid, 0),
        DEFINE_PROP_UINT16("productid", USBHIDState, productid, 0),
        DEFINE_PROP_STRING("manufacturer", USBHIDState, manufacturer),
        DEFINE_PROP_STRING("product", USBHIDState, product),
};

static void usb_mouse_class_initfn(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->realize        = usb_mouse_realize;
    uc->product_desc   = "Microsoft USB Optical Mouse";
    dc->vmsd = &vmstate_usb_ptr;
    device_class_set_props(dc, usb_mouse_properties);
    set_bit(DEVICE_CATEGORY_INPUT, dc->categories);
}

static const TypeInfo usb_mouse_info = {
    .name          = "usb-mouse",
    .parent        = TYPE_USB_HID,
    .class_init    = usb_mouse_class_initfn,
};

static const Property usb_keyboard_properties[] = {
        DEFINE_PROP_UINT32("usb_version", USBHIDState, usb_version, 2),
        DEFINE_PROP_STRING("display", USBHIDState, display),
        DEFINE_PROP_BOOL("x-force-numlock-on", USBHIDState,
                         numlock.force_on, false),
        /* stealth (patch 0010): VID/PID/manufacturer/product 覆盖 */
        DEFINE_PROP_UINT16("vendorid", USBHIDState, vendorid, 0),
        DEFINE_PROP_UINT16("productid", USBHIDState, productid, 0),
        DEFINE_PROP_STRING("manufacturer", USBHIDState, manufacturer),
        DEFINE_PROP_STRING("product", USBHIDState, product),
};

static bool usb_keyboard_get_numlock_led_known(Object *obj, Error **errp)
{
    USBHIDState *us = USB_HID(obj);

    return us->numlock.led_known;
}

static bool usb_keyboard_get_numlock_led_on(Object *obj, Error **errp)
{
    USBHIDState *us = USB_HID(obj);

    return us->numlock.led_on;
}

static bool usb_keyboard_get_numlock_force_pending(Object *obj, Error **errp)
{
    USBHIDState *us = USB_HID(obj);

    return us->numlock.force_pending;
}

static bool usb_keyboard_get_numlock_startup_completed(Object *obj,
                                                        Error **errp)
{
    USBHIDState *us = USB_HID(obj);

    return us->numlock.startup_completed;
}

static void usb_keyboard_class_initfn(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->realize        = usb_keyboard_realize;
    uc->product_desc   = "Microsoft Wired Keyboard 600";
    dc->vmsd = &vmstate_usb_kbd;
    device_class_set_props(dc, usb_keyboard_properties);
    /* 只读运行态用于判断 LED 报告及待确认注入。 */
    object_class_property_add_bool(klass, "x-numlock-led-known",
                                   usb_keyboard_get_numlock_led_known, NULL);
    object_class_property_add_bool(klass, "x-numlock-led-on",
                                   usb_keyboard_get_numlock_led_on, NULL);
    object_class_property_add_bool(klass, "x-numlock-force-pending",
                                   usb_keyboard_get_numlock_force_pending,
                                   NULL);
    /*
     * 新名称准确表达持续收敛语义。
     * 旧名称作为迁移期诊断接口别名保留。
     * 两者都只表示最近一轮已经收到 ON 确认。
     */
    object_class_property_add_bool(klass, "x-numlock-on-confirmed",
                                   usb_keyboard_get_numlock_startup_completed,
                                   NULL);
    object_class_property_add_bool(klass, "x-numlock-startup-completed",
                                   usb_keyboard_get_numlock_startup_completed,
                                   NULL);
    set_bit(DEVICE_CATEGORY_INPUT, dc->categories);
}

static const TypeInfo usb_keyboard_info = {
    .name          = "usb-kbd",
    .parent        = TYPE_USB_HID,
    .class_init    = usb_keyboard_class_initfn,
};

static void usb_hid_register_types(void)
{
    type_register_static(&usb_hid_type_info);
    type_register_static(&usb_tablet_info);
    usb_legacy_register("usb-tablet", "tablet", NULL);
    type_register_static(&usb_mouse_info);
    usb_legacy_register("usb-mouse", "mouse", NULL);
    type_register_static(&usb_keyboard_info);
    usb_legacy_register("usb-kbd", "keyboard", NULL);
}

type_init(usb_hid_register_types)
