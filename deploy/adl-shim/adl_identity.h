#ifndef STEALTH_ADL_IDENTITY_H
#define STEALTH_ADL_IDENTITY_H

#include <stdint.h>

#include "carrier_validation.h"

#define ADL_IDENTITY_NAME_CAPACITY 256u
#define ADL_IDENTITY_VENDOR_CAPACITY 32u
#define ADL_IDENTITY_BIOS_CAPACITY 64u

enum adl_identity_state {
    ADL_IDENTITY_INVALID = -1,
    ADL_IDENTITY_ABSENT = 0,
    ADL_IDENTITY_PRESENT = 1
};

/*
 * HKLM\SOFTWARE\StealthGPU 中一次不可变提交的 AMD 身份。字段全部来自同一
 * pointer/schema 复核后的 snapshot，查询函数不得再拼接其他注册表来源。
 */
struct adl_gpu_identity {
    char name[ADL_IDENTITY_NAME_CAPACITY];
    char vendor[ADL_IDENTITY_VENDOR_CAPACITY];
    char bios[ADL_IDENTITY_BIOS_CAPACITY];
    uint32_t pci_vendor_id;
    uint32_t pci_device_id;
    uint32_t subsystem_vendor_id;
    uint32_t subsystem_device_id;
    uint32_t revision_id;
    uint32_t ram_mb;
    uint32_t memory_bus_width_bits;
    uint32_t base_clock_khz;
    uint32_t boost_clock_khz;
    uint32_t memory_clock_khz;
    uint32_t bus_id;
    uint32_t slot_id;
    uint32_t function_id;
    uint32_t compute_units;
    uint32_t processing_elements_per_cu;
    uint32_t rops;
    /* 只由 SetupAPI/CM 成功读取后填充的真实 virtio 承载设备信息。 */
    struct stealth_gpu_carrier carrier;
};

/* INVALID 可重试；Refresh 可在同一 DLL 生命周期内原子替换已验证快照。 */
enum adl_identity_state adl_identity_initialize(void);
enum adl_identity_state adl_identity_refresh(void);
enum adl_identity_state adl_identity_copy(struct adl_gpu_identity *identity);

#endif
