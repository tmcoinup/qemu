#ifndef STEALTH_GPU_MODEL_CATALOG_H
#define STEALTH_GPU_MODEL_CATALOG_H

#include <stdint.h>

/*
 * 跨厂商共享的最小型号记录。
 *
 * gpu_core_count 与 shader_subpipe_count 目前只用于 NVIDIA 公开 NVAPI
 * GetGpuCoreCount/GetShaderSubPipeCount 语义。值为 0 表示共享目录没有发布该
 * 厂商/型号的对应能力，调用方必须 fail closed，不能从名称或近似型号猜测。
 */
struct stealth_gpu_model_info {
    const char *standard_name;
    uint32_t gpu_core_count;
    uint32_t shader_subpipe_count;
};

/*
 * 按完整 vendor/device 主键返回不可变型号记录。未知组合返回 NULL。
 * 返回对象具有进程生命周期，调用方不得修改或释放。
 */
const struct stealth_gpu_model_info *stealth_gpu_model_find(
    uint32_t pci_vendor_id, uint32_t pci_device_id);

/*
 * 根据已经通过身份合同校验的逻辑 PCI 主 ID 返回标准芯片型号名。
 * 未知组合返回 NULL；调用方不得从 AIB 标签裁剪或猜测型号名。
 */
const char *stealth_gpu_standard_model_name(uint32_t pci_vendor_id,
                                            uint32_t pci_device_id);

#endif
