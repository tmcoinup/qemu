#include <stddef.h>
#include <stdint.h>

#include "gpu_model_catalog.h"

struct stealth_gpu_model {
    uint32_t pci_vendor_id;
    uint32_t pci_device_id;
    struct stealth_gpu_model_info info;
};

/*
 * 标准芯片名是 AIB 板卡身份的多对一展示投影。这里不保存 subsystem、VBIOS
 * 或时钟，避免调用方误把主 ID 映射当成完整板卡合同。NVIDIA 核心数与
 * shader subpipe 数是同一芯片主 ID 的稳定能力；AMD 暂不通过 NVAPI 查询，
 * 对应字段保持 0，禁止调用方跨厂商套用。
 */
static const struct stealth_gpu_model g_gpu_models[] = {
    { UINT32_C(0x10de), UINT32_C(0x1380),
      { "NVIDIA GeForce GTX 750 Ti", 640u, 5u } },
    { UINT32_C(0x10de), UINT32_C(0x1d01),
      { "NVIDIA GeForce GT 1030", 384u, 3u } },
    { UINT32_C(0x10de), UINT32_C(0x1c81),
      { "NVIDIA GeForce GTX 1050", 640u, 5u } },
    { UINT32_C(0x10de), UINT32_C(0x1c82),
      { "NVIDIA GeForce GTX 1050 Ti", 768u, 6u } },
    { UINT32_C(0x1002), UINT32_C(0x699f),
      { "AMD Radeon RX 550", 0u, 0u } },
    { UINT32_C(0x1002), UINT32_C(0x67ff),
      { "AMD Radeon RX 560", 0u, 0u } },
};

const struct stealth_gpu_model_info *stealth_gpu_model_find(
    uint32_t pci_vendor_id, uint32_t pci_device_id)
{
    size_t index;

    for (index = 0u; index < sizeof(g_gpu_models) /
             sizeof(g_gpu_models[0]); ++index) {
        if (g_gpu_models[index].pci_vendor_id == pci_vendor_id &&
            g_gpu_models[index].pci_device_id == pci_device_id) {
            return &g_gpu_models[index].info;
        }
    }
    return NULL;
}

const char *stealth_gpu_standard_model_name(uint32_t pci_vendor_id,
                                            uint32_t pci_device_id)
{
    const struct stealth_gpu_model_info *model = stealth_gpu_model_find(
        pci_vendor_id, pci_device_id);

    return model == NULL ? NULL : model->standard_name;
}
