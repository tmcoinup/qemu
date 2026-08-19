/*
 * USB Mass Storage Device emulation
 *
 * Copyright (c) 2006 CodeSourcery.
 * Written by Paul Brook
 *
 * This code is licensed under the LGPL.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "hw/core/qdev-properties.h"
#include "hw/usb/usb.h"
#include "hw/usb/desc.h"
#include "hw/usb/msd.h"

static const struct SCSIBusInfo usb_msd_scsi_info_bot = {
    .tcq = false,
    .max_target = 0,
    .max_lun = 15,

    .transfer_data = usb_msd_transfer_data,
    .complete = usb_msd_command_complete,
    .cancel = usb_msd_request_cancelled,
    .load_request = usb_msd_load_request,
};

static void usb_msd_bot_realize(USBDevice *dev, Error **errp)
{
    MSDState *s = USB_STORAGE_DEV(dev);
    DeviceState *d = DEVICE(dev);
    const USBDesc *selected = usb_device_get_usb_desc(dev);
    bool suppress_serial;

    /* An explicit empty serial means that the device has no serial number.
     * Advertising a nonzero iSerialNumber and returning an empty two-byte
     * string descriptor makes Windows reject the USB device during
     * enumeration.  USB specifies iSerialNumber=0 for the no-serial case. */
    if (s->no_serial && dev->serial && dev->serial[0] != '\0') {
        error_setg(errp, "x-no-serial cannot be combined with a non-empty serial");
        return;
    }
    if (s->bcd_device != UINT32_MAX && s->bcd_device > UINT16_MAX) {
        error_setg(errp, "bcd-device must be a 16-bit BCD value");
        return;
    }

    suppress_serial = s->no_serial || (dev->serial && dev->serial[0] == '\0');
    if (suppress_serial || s->vendorid || s->productid ||
        s->bcd_device != UINT32_MAX) {
        s->patched_desc = g_memdup2(selected, sizeof(*selected));
        if (s->vendorid) {
            s->patched_desc->id.idVendor = s->vendorid;
        }
        if (s->productid) {
            s->patched_desc->id.idProduct = s->productid;
        }
        if (s->bcd_device != UINT32_MAX) {
            s->patched_desc->id.bcdDevice = s->bcd_device;
        }
        if (suppress_serial) {
            s->patched_desc->id.iSerialNumber = 0;
        }
        dev->usb_desc = s->patched_desc;
    } else {
        dev->usb_desc = selected;
    }
    if (!suppress_serial) {
        usb_desc_create_serial(dev);
    }
    usb_desc_init(dev);
    if (s->manufacturer && dev->usb_desc->id.iManufacturer) {
        usb_desc_set_string(dev, dev->usb_desc->id.iManufacturer,
                            s->manufacturer);
    }
    if (s->product && dev->usb_desc->id.iProduct) {
        usb_desc_set_string(dev, dev->usb_desc->id.iProduct, s->product);
    }
    dev->flags |= (1 << USB_DEV_FLAG_IS_SCSI_STORAGE);
    if (d->hotplugged) {
        s->dev.auto_attach = 0;
    }

    scsi_bus_init(&s->bus, sizeof(s->bus), DEVICE(dev), &usb_msd_scsi_info_bot);
    usb_msd_handle_reset(dev);
}

static void usb_msd_bot_unrealize(USBDevice *dev)
{
    MSDState *s = USB_STORAGE_DEV(dev);

    g_clear_pointer(&s->patched_desc, g_free);
    dev->usb_desc = NULL;
}

static const Property usb_msd_bot_properties[] = {
    DEFINE_PROP_BOOL("x-no-serial", MSDState, no_serial, false),
    DEFINE_PROP_UINT16("vendorid", MSDState, vendorid, 0),
    DEFINE_PROP_UINT16("productid", MSDState, productid, 0),
    DEFINE_PROP_UINT32("bcd-device", MSDState, bcd_device, UINT32_MAX),
    DEFINE_PROP_STRING("manufacturer", MSDState, manufacturer),
    DEFINE_PROP_STRING("product", MSDState, product),
};

static void usb_msd_class_bot_initfn(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->realize = usb_msd_bot_realize;
    uc->unrealize = usb_msd_bot_unrealize;
    uc->attached_settable = true;
    device_class_set_props(dc, usb_msd_bot_properties);
}

static const TypeInfo bot_info = {
    .name          = "usb-bot",
    .parent        = TYPE_USB_STORAGE,
    .class_init    = usb_msd_class_bot_initfn,
};

static void register_types(void)
{
    type_register_static(&bot_info);
}

type_init(register_types)
