// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Add fw_cfg device in DSDT
 *
 */

#include "qemu/osdep.h"
#include "hw/nvram/fw_cfg_acpi.h"
#include "hw/acpi/aml-build.h"

void fw_cfg_acpi_dsdt_add(Aml *scope, const MemMapEntry *fw_cfg_memmap)
{
    Aml *dev = aml_device("FWCF");
    /* Stealth: PNP0C02 (Motherboard Resources) instead of "QEMU0002" tell.
     * See hw/i386/fw_cfg.c for the rationale — same applies on the
     * MMIO path used by ARM virt and other non-x86 boards. */
    aml_append(dev, aml_name_decl("_HID", aml_string("PNP0C02")));
    /* device present, functioning, decoding, not shown in UI */
    aml_append(dev, aml_name_decl("_STA", aml_int(0xB)));
    aml_append(dev, aml_name_decl("_CCA", aml_int(1)));

    Aml *crs = aml_resource_template();
    aml_append(crs, aml_memory32_fixed(fw_cfg_memmap->base,
                                       fw_cfg_memmap->size, AML_READ_WRITE));
    aml_append(dev, aml_name_decl("_CRS", crs));
    aml_append(scope, dev);
}
