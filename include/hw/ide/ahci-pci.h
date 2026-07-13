/*
 * QEMU AHCI Emulation (PCI devices)
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef HW_IDE_AHCI_PCI_H
#define HW_IDE_AHCI_PCI_H

#include "qom/object.h"
#include "hw/ide/ahci.h"
#include "hw/pci/pci_device.h"
#include "hw/core/irq.h"

#define TYPE_ICH9_AHCI "ich9-ahci"
OBJECT_DECLARE_SIMPLE_TYPE(AHCIPCIState, ICH9_AHCI)

struct AHCIPCIState {
    PCIDevice parent_obj;

    AHCIState ahci;
    IRQState irq;
    /* 仅覆盖 PCI 身份；端口与寄存器行为仍是 ICH9 AHCI。 */
    uint32_t x_pci_vendor_id;
    uint32_t x_pci_device_id;
    uint32_t x_pci_revision;
    uint32_t x_pci_sub_vendor_id;
    uint32_t x_pci_sub_device_id;
};

#endif
