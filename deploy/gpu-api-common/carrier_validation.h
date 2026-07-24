#ifndef STEALTH_GPU_CARRIER_VALIDATION_H
#define STEALTH_GPU_CARRIER_VALIDATION_H

#include <stddef.h>
#include <stdint.h>

/*
 * 两个厂商读取 DLL 共用的“实际显示承载设备”证明。它不创建 PnP 设备，也不
 * 修改驱动；唯一职责是把不可变 profile 与 Windows 已枚举的 virtio 设备绑定。
 */
#define STEALTH_GPU_CARRIER_INSTANCE_CAPACITY 256u
#define STEALTH_GPU_CARRIER_HARDWARE_ID_CAPACITY 256u
#define STEALTH_GPU_CARRIER_DRIVER_KEY_CAPACITY 64u
#define STEALTH_GPU_CARRIER_DRIVER_PATH_CAPACITY 256u

struct stealth_gpu_carrier_observation {
    const char *instance_id;
    const char *hardware_ids;
    size_t hardware_ids_bytes;
    const char *service;
    const char *driver_key;
    uint32_t bus_id;
    uint32_t slot_id;
    uint32_t function_id;
    uint32_t matching_source_count;
    uint32_t virtio_display_count;
};

struct stealth_gpu_carrier {
    char instance_id[STEALTH_GPU_CARRIER_INSTANCE_CAPACITY];
    char hardware_id[STEALTH_GPU_CARRIER_HARDWARE_ID_CAPACITY];
    char driver_key[STEALTH_GPU_CARRIER_DRIVER_KEY_CAPACITY];
    char driver_registry_path[STEALTH_GPU_CARRIER_DRIVER_PATH_CAPACITY];
    uint32_t pci_vendor_id;
    uint32_t pci_device_id;
    uint32_t bus_id;
    uint32_t slot_id;
    uint32_t function_id;
};

/*
 * HardwareID 投影只允许出现与不可变 identity 完全一致的逻辑首项。使用结构体
 * 传递字段，避免 NVAPI/ADL 各自拼接字符串后产生 SUBSYS 字节序差异。
 */
struct stealth_gpu_logical_pci_identity {
    uint32_t vendor_id;
    uint32_t device_id;
    uint32_t subsystem_vendor_id;
    uint32_t subsystem_device_id;
    uint32_t revision_id;
};

/* 可在 Linux 单元测试中执行的纯契约；Windows 枚举层只负责提供 observation。 */
int stealth_validate_virtio_gpu_carrier_observation(
    const char *expected_source_instance_id, uint32_t expected_bus_id,
    uint32_t expected_slot_id, uint32_t expected_function_id,
    const struct stealth_gpu_logical_pci_identity *logical_identity,
    const struct stealth_gpu_carrier_observation *observation,
    struct stealth_gpu_carrier *carrier);

/*
 * 使用 SetupAPI + Configuration Manager 读取当前 PRESENT Display 设备。成功时
 * carrier 全部来自实际实例，profile 中的 SourceInstanceId/BDF 只作为待验证输入。
 */
int stealth_validate_virtio_gpu_carrier_windows(
    const char *expected_source_instance_id, uint32_t expected_bus_id,
    uint32_t expected_slot_id, uint32_t expected_function_id,
    const struct stealth_gpu_logical_pci_identity *logical_identity,
    struct stealth_gpu_carrier *carrier);

#endif
