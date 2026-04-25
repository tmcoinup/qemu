/*
 * AMD Data Fabric configuration stub devices.
 *
 * Real Zen 1/1+/2/3 CPUs expose 8 PCI config-space functions at bus 0
 * slot 0x18: (1022:1460) DF Function 0 through (1022:1467) DF Function 7.
 * Tools like HWiNFO/CPU-Z read these IDs to identify the processor codename
 * and to derive information like channel count.
 *
 * This device provides config-space-only stubs: no BARs, no MMIO, no
 * functionality. Their only purpose is to appear in `lspci` / Windows PCI
 * enumeration with the correct Vendor+Device IDs so that CPU identification
 * heuristics succeed.
 */

#include "qemu/osdep.h"
#include "qemu/module.h"
#include "hw/pci/pci_device.h"
#include "hw/qdev-properties.h"
#include "migration/vmstate.h"
#include "qom/object.h"

#define TYPE_AMD_DF_STUB "amd-df-stub"
OBJECT_DECLARE_SIMPLE_TYPE(AMDDataFabricStub, AMD_DF_STUB)

struct AMDDataFabricStub {
    PCIDevice dev;
    uint16_t func_device_id;
    uint16_t sub_vendor_id;
    uint16_t sub_device_id;
};

static const VMStateDescription vmstate_amd_df_stub = {
    .name = "amd-df-stub",
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_PCI_DEVICE(dev, AMDDataFabricStub),
        VMSTATE_END_OF_LIST()
    }
};

static void amd_df_stub_realize(PCIDevice *dev, Error **errp)
{
    AMDDataFabricStub *s = AMD_DF_STUB(dev);

    /* Override the class-level device ID per-instance; we reuse one QEMU
     * type for all 8 DF functions. */
    if (s->func_device_id) {
        pci_config_set_device_id(dev->config, s->func_device_id);
    }
    /* Real Zen silicon reports 0000:0000 subsystem on the DF functions,
     * not the motherboard vendor. Let the caller override if they want to
     * mimic a specific sample but default to zeros rather than QEMU's
     * Red Hat / 1AF4:1100 leak. */
    pci_set_word(dev->config + PCI_SUBSYSTEM_VENDOR_ID, s->sub_vendor_id);
    pci_set_word(dev->config + PCI_SUBSYSTEM_ID,        s->sub_device_id);
}

static Property amd_df_stub_properties[] = {
    DEFINE_PROP_UINT16("device-id",     AMDDataFabricStub, func_device_id, 0x1460),
    DEFINE_PROP_UINT16("sub-vendor-id", AMDDataFabricStub, sub_vendor_id,  0x0000),
    DEFINE_PROP_UINT16("sub-device-id", AMDDataFabricStub, sub_device_id,  0x0000),
    DEFINE_PROP_END_OF_LIST(),
};

static void amd_df_stub_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *pc = PCI_DEVICE_CLASS(klass);

    device_class_set_props(dc, amd_df_stub_properties);
    pc->realize   = amd_df_stub_realize;
    pc->vendor_id = 0x1022;               /* AMD */
    pc->device_id = 0x1460;               /* DF Function 0 default */
    pc->revision  = 0x00;
    pc->class_id  = PCI_CLASS_BRIDGE_HOST; /* 0x0600 */
    dc->vmsd = &vmstate_amd_df_stub;
    dc->desc = "AMD Zen Data Fabric configuration function";
    /* Instantiated explicitly by machine code; not user-creatable. */
    dc->user_creatable = true;
    set_bit(DEVICE_CATEGORY_MISC, dc->categories);
}

static const TypeInfo amd_df_stub_info = {
    .name          = TYPE_AMD_DF_STUB,
    .parent        = TYPE_PCI_DEVICE,
    .instance_size = sizeof(AMDDataFabricStub),
    .class_init    = amd_df_stub_class_init,
    .interfaces = (InterfaceInfo[]) {
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { }
    }
};

static void amd_df_stub_register_types(void)
{
    type_register_static(&amd_df_stub_info);
}

type_init(amd_df_stub_register_types)
