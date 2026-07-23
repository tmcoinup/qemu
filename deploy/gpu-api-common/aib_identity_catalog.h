#ifndef STEALTH_AIB_IDENTITY_CATALOG_H
#define STEALTH_AIB_IDENTITY_CATALOG_H

#include <stddef.h>
#include <stdint.h>

/*
 * schema-2 的板卡身份是一个不可拆分的 bundle。carrier_device_id 仅用于把
 * 物理 1AF4:1050 实例路由到已审计板卡，绝不能作为逻辑 subsystem 暴露。
 */
struct stealth_aib_identity {
    const char *name;
    const char *vendor;
    const char *bios;
    const char *memory_type;
    uint32_t carrier_device_id;
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
    uint32_t sli_supported;
};

/*
 * 两个 shim 的输入结构不同，因此用一份中立快照执行公共的逐字段等式。
 * 调用方先按 carrier 找板卡，再把注册表字段完整投影到本结构。
 */
struct stealth_aib_identity_snapshot {
    const char *name;
    const char *vendor;
    const char *bios;
    const char *memory_type;
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
    uint32_t sli_supported;
};

size_t stealth_aib_identity_count(void);
const struct stealth_aib_identity *stealth_aib_identity_at(size_t index);
const struct stealth_aib_identity *stealth_aib_identity_find_by_carrier(
    uint32_t carrier_device_id);
int stealth_aib_identity_snapshot_matches(
    const struct stealth_aib_identity *identity,
    const struct stealth_aib_identity_snapshot *snapshot);

#endif
