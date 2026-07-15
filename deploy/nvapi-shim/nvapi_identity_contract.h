#ifndef STEALTH_NVAPI_IDENTITY_CONTRACT_H
#define STEALTH_NVAPI_IDENTITY_CONTRACT_H

#include "nvapi_identity.h"

/*
 * 注册表 I/O 与身份语义校验分离：Windows reader 只负责取得严格类型的原始值，
 * 本结构负责跨字段契约。这样 Linux host test 也能真实执行 SUBSYS/REV、时钟和
 * schema 的拒绝路径，而不是只用 grep 猜测 Windows 代码是否正确。
 */
#define STEALTH_GPU_SCHEMA_VERSION 2u
#define STEALTH_GPU_LEGACY_SCHEMA_VERSION 1u
#define STEALTH_GPU_IDENTITY_TOKEN_LENGTH 32u

/*
 * schema-1 没有型号细节六字段。升级窗口和 durable rollback 仍可能短暂读到一份
 * 完整 schema-1，因此 reader 按仓库受控 NVIDIA PCI 型号池补入编译期常量。
 * 这些值只填缺失扩展字段；名称、PCI、显存容量、VBIOS 和物理来源仍必须从
 * schema-1 的全部 16 个公共字段严格读取并交叉校验，未知设备一律 fail-closed。
 */
struct nvapi_legacy_extension_defaults {
    NvU32 memory_bus_width_bits;
    NvU32 base_clock_khz;
    NvU32 boost_clock_khz;
    NvU32 memory_clock_khz;
};

struct nvapi_identity_contract_input {
    const char *expected_token;
    const char *identity_id;
    const char *name;
    const char *vendor;
    const char *bios;
    const char *memory_type;
    const char *source_instance_id;
    const char *identity_mode;
    NvU32 schema;
    NvU32 pci_vendor_id;
    NvU32 pci_device_id;
    NvU32 subsystem_vendor_id;
    NvU32 subsystem_device_id;
    NvU32 revision_id;
    NvU32 ram_mb;
    NvU32 memory_bus_width_bits;
    NvU32 base_clock_khz;
    NvU32 boost_clock_khz;
    NvU32 memory_clock_khz;
    NvU32 sli_supported;
    NvU32 bus_id;
    NvU32 slot_id;
    NvU32 function_id;
};

int nvapi_validate_identity_token(const char *token);
int nvapi_get_legacy_extension_defaults(
    NvU32 pci_vendor_id, NvU32 pci_device_id,
    struct nvapi_legacy_extension_defaults *defaults);
int nvapi_build_validated_identity(
    const struct nvapi_identity_contract_input *input,
    struct nvapi_gpu_identity *identity);

#endif
