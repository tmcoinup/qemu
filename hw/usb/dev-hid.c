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
#include "hw/usb.h"
#include "migration/vmstate.h"
#include "desc.h"
#include "qapi/error.h"
#include "qemu/module.h"
#include "qemu/timer.h"
#include "hw/input/hid.h"
#include "hw/usb/hid.h"
#include "hw/qdev-properties.h"
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
    STR_MANUFACTURER_TABLET,   /* HUION (绘王) — tablet 用 256C VID, 字符串得跟 VID 对得上 */
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
    [STR_PRODUCT_TABLET]       = "HUION PenTablet",
    [STR_PRODUCT_KEYBOARD]     = "Microsoft Wired Keyboard 600",
    [STR_SERIAL_COMPAT]        = "42",
    [STR_CONFIG_MOUSE]         = "HID Mouse",
    [STR_CONFIG_TABLET]        = "HID Tablet",
    [STR_CONFIG_KEYBOARD]      = "HID Keyboard",
    [STR_SERIAL_MOUSE]         = "89126",
    [STR_SERIAL_TABLET]        = "28754",
    [STR_SERIAL_KEYBOARD]      = "68284",
    [STR_MANUFACTURER_TABLET]  = "HUION",
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
 * Tablet 用 HUION (绘王) 256C:006D — 国内深圳厂, 淘宝入门款 H420 数位板,
 * 比 Wacom 草根, 不会引来"为什么家用机插 Wacom 专业板"这类二级怀疑.
 * 绝对坐标 USB pointer 报为 graphics tablet 而非 virtual mouse.
 */
/*
 * bcdDevice: 真硬件设备版本号在 USB ID 数据库里都不为 0。bcdDevice=0 是
 * QEMU 默认值，对 anti-cheat 而言是一个 telltale（"无版本号的 USB HID =
 * 必然虚拟"）。改为公开报告的真实硬件 firmware revision：
 *   - Microsoft USB Optical Mouse 045E:00CB → bcdDevice 0x0163
 *   - Microsoft Wired Keyboard 600 045E:0750 → bcdDevice 0x0163
 *   - HUION H420 256C:006D → bcdDevice 0x0100
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
        .idVendor          = 0x256C,
        .idProduct         = 0x006D,
        .bcdDevice         = 0x0100,
        .iManufacturer     = STR_MANUFACTURER_TABLET,
        .iProduct          = STR_PRODUCT_TABLET,
        .iSerialNumber     = 0,
    },
    .full = &desc_device_tablet,
    .str  = desc_strings,
    .msos = &desc_msos_suspend,
};

static const USBDesc desc_tablet2 = {
    .id = {
        .idVendor          = 0x256C,
        .idProduct         = 0x006D,
        .bcdDevice         = 0x0100,
        .iManufacturer     = STR_MANUFACTURER_TABLET,
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
    0x29, 0x03,		/*     Usage Maximum (3) */
    0x15, 0x00,		/*     Logical Minimum (0) */
    0x25, 0x01,		/*     Logical Maximum (1) */
    0x95, 0x03,		/*     Report Count (3) */
    0x75, 0x01,		/*     Report Size (1) */
    0x81, 0x02,		/*     Input (Data, Variable, Absolute) */
    0x95, 0x01,		/*     Report Count (1) */
    0x75, 0x05,		/*     Report Size (5) */
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

static void usb_hid_handle_reset(USBDevice *dev)
{
    USBHIDState *us = USB_HID(dev);

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
    usb_hid_initfn(dev, HID_KEYBOARD, &desc_keyboard, &desc_keyboard2, errp);
}

static int usb_ptr_post_load(void *opaque, int version_id)
{
    USBHIDState *s = opaque;

    if (s->dev.remote_wakeup) {
        hid_pointer_activate(&s->hid);
    }
    return 0;
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
    .fields = (const VMStateField[]) {
        VMSTATE_USB_DEVICE(dev, USBHIDState),
        VMSTATE_HID_KEYBOARD_DEVICE(hid, USBHIDState),
        VMSTATE_END_OF_LIST()
    }
};

static void usb_hid_class_initfn(ObjectClass *klass, void *data)
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

static Property usb_tablet_properties[] = {
        DEFINE_PROP_UINT32("usb_version", USBHIDState, usb_version, 2),
        DEFINE_PROP_STRING("display", USBHIDState, display),
        DEFINE_PROP_UINT32("head", USBHIDState, head, 0),
        /* stealth (patch 0010): VID/PID/manufacturer/product 覆盖 */
        DEFINE_PROP_UINT16("vendorid", USBHIDState, vendorid, 0),
        DEFINE_PROP_UINT16("productid", USBHIDState, productid, 0),
        DEFINE_PROP_STRING("manufacturer", USBHIDState, manufacturer),
        DEFINE_PROP_STRING("product", USBHIDState, product),
        DEFINE_PROP_END_OF_LIST(),
};

static void usb_tablet_class_initfn(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->realize        = usb_tablet_realize;
    uc->product_desc   = "HUION PenTablet";
    dc->vmsd = &vmstate_usb_ptr;
    device_class_set_props(dc, usb_tablet_properties);
    set_bit(DEVICE_CATEGORY_INPUT, dc->categories);
}

static const TypeInfo usb_tablet_info = {
    .name          = "usb-tablet",
    .parent        = TYPE_USB_HID,
    .class_init    = usb_tablet_class_initfn,
};

static Property usb_mouse_properties[] = {
        DEFINE_PROP_UINT32("usb_version", USBHIDState, usb_version, 2),
        /* stealth (patch 0010): VID/PID/manufacturer/product 覆盖 */
        DEFINE_PROP_UINT16("vendorid", USBHIDState, vendorid, 0),
        DEFINE_PROP_UINT16("productid", USBHIDState, productid, 0),
        DEFINE_PROP_STRING("manufacturer", USBHIDState, manufacturer),
        DEFINE_PROP_STRING("product", USBHIDState, product),
        DEFINE_PROP_END_OF_LIST(),
};

static void usb_mouse_class_initfn(ObjectClass *klass, void *data)
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

static Property usb_keyboard_properties[] = {
        DEFINE_PROP_UINT32("usb_version", USBHIDState, usb_version, 2),
        DEFINE_PROP_STRING("display", USBHIDState, display),
        /* stealth (patch 0010): VID/PID/manufacturer/product 覆盖 */
        DEFINE_PROP_UINT16("vendorid", USBHIDState, vendorid, 0),
        DEFINE_PROP_UINT16("productid", USBHIDState, productid, 0),
        DEFINE_PROP_STRING("manufacturer", USBHIDState, manufacturer),
        DEFINE_PROP_STRING("product", USBHIDState, product),
        DEFINE_PROP_END_OF_LIST(),
};

static void usb_keyboard_class_initfn(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->realize        = usb_keyboard_realize;
    uc->product_desc   = "Microsoft Wired Keyboard 600";
    dc->vmsd = &vmstate_usb_kbd;
    device_class_set_props(dc, usb_keyboard_properties);
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
