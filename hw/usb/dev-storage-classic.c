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
#include "qapi/visitor.h"
#include "hw/usb/usb.h"
#include "hw/usb/desc.h"
#include "hw/usb/msd.h"
#include "hw/core/qdev-properties.h"
#include "system/system.h"
#include "system/block-backend.h"

static const struct SCSIBusInfo usb_msd_scsi_info_storage = {
    .tcq = false,
    .max_target = 0,
    .max_lun = 0,

    .transfer_data = usb_msd_transfer_data,
    .complete = usb_msd_command_complete,
    .cancel = usb_msd_request_cancelled,
    .load_request = usb_msd_load_request,
};

static void usb_msd_storage_realize(USBDevice *dev, Error **errp)
{
    MSDState *s = USB_STORAGE_DEV(dev);
    BlockBackend *blk = s->conf.blk;
    SCSIDevice *scsi_dev;
    const USBDesc *selected = usb_device_get_usb_desc(dev);
    bool suppress_serial;

    if (!blk) {
        error_setg(errp, "drive property not set");
        return;
    }
    if (s->no_serial && dev->serial && dev->serial[0] != '\0') {
        error_setg(errp, "x-no-serial cannot be combined with a non-empty serial");
        return;
    }
    if (s->bcd_device != UINT32_MAX && s->bcd_device > UINT16_MAX) {
        error_setg(errp, "bcd-device must be a 16-bit BCD value");
        return;
    }

    /*
     * Hack alert: this pretends to be a block device, but it's really
     * a SCSI bus that can serve only a single device, which it
     * creates automatically.  But first it needs to detach from its
     * blockdev, or else scsi_bus_legacy_add_drive() dies when it
     * attaches again. We also need to take another reference so that
     * blk_detach_dev() doesn't free blk while we still need it.
     *
     * The hack is probably a bad idea.
     */
    blk_ref(blk);
    blk_detach_dev(blk, DEVICE(s));
    s->conf.blk = NULL;

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
    scsi_bus_init(&s->bus, sizeof(s->bus), DEVICE(dev),
                 &usb_msd_scsi_info_storage);
    scsi_dev = scsi_bus_legacy_add_drive(
        &s->bus, blk, 0, !!s->removable, &s->conf, dev->serial,
        s->scsi_vendor, s->scsi_product, s->scsi_version, errp);
    blk_unref(blk);
    if (!scsi_dev) {
        return;
    }
    usb_msd_handle_reset(dev);
    s->scsi_dev = scsi_dev;
}

static void usb_msd_storage_unrealize(USBDevice *dev)
{
    MSDState *s = USB_STORAGE_DEV(dev);

    g_clear_pointer(&s->patched_desc, g_free);
    dev->usb_desc = NULL;
}

static const Property msd_properties[] = {
    DEFINE_BLOCK_PROPERTIES(MSDState, conf),
    DEFINE_BLOCK_ERROR_PROPERTIES(MSDState, conf),
    DEFINE_PROP_BOOL("removable", MSDState, removable, false),
    DEFINE_PROP_BOOL("commandlog", MSDState, commandlog, false),
    DEFINE_PROP_BOOL("x-no-serial", MSDState, no_serial, false),
    DEFINE_PROP_UINT16("vendorid", MSDState, vendorid, 0),
    DEFINE_PROP_UINT16("productid", MSDState, productid, 0),
    DEFINE_PROP_UINT32("bcd-device", MSDState, bcd_device, UINT32_MAX),
    DEFINE_PROP_STRING("manufacturer", MSDState, manufacturer),
    DEFINE_PROP_STRING("product", MSDState, product),
    DEFINE_PROP_STRING("scsi-vendor", MSDState, scsi_vendor),
    DEFINE_PROP_STRING("scsi-product", MSDState, scsi_product),
    DEFINE_PROP_STRING("scsi-version", MSDState, scsi_version),
};

static void usb_msd_class_storage_initfn(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->realize = usb_msd_storage_realize;
    uc->unrealize = usb_msd_storage_unrealize;
    device_class_set_props(dc, msd_properties);
}

static void usb_msd_get_bootindex(Object *obj, Visitor *v, const char *name,
                                  void *opaque, Error **errp)
{
    USBDevice *dev = USB_DEVICE(obj);
    MSDState *s = USB_STORAGE_DEV(dev);

    visit_type_int32(v, name, &s->conf.bootindex, errp);
}

static void usb_msd_set_bootindex(Object *obj, Visitor *v, const char *name,
                                  void *opaque, Error **errp)
{
    USBDevice *dev = USB_DEVICE(obj);
    MSDState *s = USB_STORAGE_DEV(dev);
    int32_t boot_index;
    Error *local_err = NULL;

    if (!visit_type_int32(v, name, &boot_index, errp)) {
        return;
    }
    /* check whether bootindex is present in fw_boot_order list  */
    check_boot_index(boot_index, &local_err);
    if (local_err) {
        goto out;
    }
    /* change bootindex to a new one */
    s->conf.bootindex = boot_index;

    if (s->scsi_dev) {
        object_property_set_int(OBJECT(s->scsi_dev), "bootindex", boot_index,
                                &error_abort);
    }

out:
    error_propagate(errp, local_err);
}

static void usb_msd_instance_init(Object *obj)
{
    object_property_add(obj, "bootindex", "int32",
                        usb_msd_get_bootindex,
                        usb_msd_set_bootindex, NULL, NULL);
    object_property_set_int(obj, "bootindex", -1, NULL);
}

static const TypeInfo msd_info = {
    .name          = "usb-storage",
    .parent        = TYPE_USB_STORAGE,
    .class_init    = usb_msd_class_storage_initfn,
    .instance_init = usb_msd_instance_init,
};

static void register_types(void)
{
    type_register_static(&msd_info);
}

type_init(register_types)
