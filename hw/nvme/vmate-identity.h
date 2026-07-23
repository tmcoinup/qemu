/*
 * VMate 消费级 NVMe 身份画像。
 *
 * 这里保存的是会被 Guest 同时观察到、因此必须原子变化的一组字段。调用方不能
 * 单独覆盖型号、固件或 PCI ID，否则会构造出现实中不存在的混合设备。
 */
#ifndef HW_NVME_VMATE_IDENTITY_H
#define HW_NVME_VMATE_IDENTITY_H

#include "qapi/error.h"

typedef struct VmateNvmeIdentity {
    const char *id;
    const char *manufacturer;
    const char *model;
    const char *firmware;
    uint16_t pci_vendor;
    uint16_t pci_device;
    uint16_t subsystem_vendor;
    uint16_t subsystem_device;
    uint8_t ieee_oui[3];
    uint8_t pcie_generation;
    uint8_t lanes;
} VmateNvmeIdentity;

const VmateNvmeIdentity *vmate_nvme_identity_lookup(const char *id);

bool vmate_nvme_identity_validate(const VmateNvmeIdentity *identity,
                                  const char *model,
                                  const char *firmware,
                                  const char *serial,
                                  uint16_t subsystem_vendor,
                                  uint16_t subsystem_device,
                                  Error **errp);

#endif
