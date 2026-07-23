#ifndef STEALTH_NVAPI_IDENTITY_H
#define STEALTH_NVAPI_IDENTITY_H

#include "nvapi_types.h"

/*
 * HKLM\SOFTWARE\StealthGPU\Identities\<CurrentIdentity> 的不可变身份快照。
 * 所有查询只读同一份经 pointer/schema 双重复核的版本，避免 GPU-Z 在并发提交
 * 时观察到名称已更新而 PCI ID 仍是旧值。
 */
struct nvapi_gpu_identity {
    char name[NVAPI_SHORT_STRING_MAX];
    char vendor[32];
    char bios[NVAPI_SHORT_STRING_MAX];
    NvU32 pci_vendor_id;
    NvU32 pci_device_id;
    NvU32 subsystem_vendor_id;
    NvU32 subsystem_device_id;
    NvU32 revision_id;
    NvU32 vram_kib;
    NvU32 vbios_revision;
    NvU32 vbios_oem_revision;
    NvU32 ram_type;
    NvU32 ram_bus_width_bits;
    NvU32 base_clock_khz;
    NvU32 boost_clock_khz;
    NvU32 memory_clock_khz;
    NvU32 bus_id;
    NvU32 slot_id;
    int has_bus_id;
    int has_slot_id;
};

/* 首次一致读取由 InitOnce 发布；瞬态失败不完成 InitOnce，后续可安全重试。 */
int nvapi_identity_initialize(void);

/* 只有 initialize 成功后才可读取，返回对象在 DLL 生命周期内保持不变。 */
const struct nvapi_gpu_identity *nvapi_identity_get(void);

/* NVAPI 使用“设备号高 16 位、厂商号低 16 位”的 PCI 组合格式。 */
NvU32 nvapi_pack_pci_identifier(NvU32 device_id, NvU32 vendor_id);

/*
 * GetPCIIdentifiers 的主 PCI 键必须对应 Windows 中实际承载画面的同一设备。
 * 否则同时使用 SetupAPI 与 NVAPI 的硬件工具会把一个 virtio 显示适配器拆成两张卡。
 * subsystem/revision 是经 carrier 映射验证后的逻辑 AIB 身份，不宣称等同于物理
 * virtio 配置空间；external_device_id 保留逻辑 NVIDIA 型号，供只关心产品型号的
 * NVAPI 消费者使用。
 */
void nvapi_build_carrier_pci_identifiers(
    const struct nvapi_gpu_identity *identity, NvU32 *device_id,
    NvU32 *subsystem_id, NvU32 *revision_id, NvU32 *external_device_id);

#endif
