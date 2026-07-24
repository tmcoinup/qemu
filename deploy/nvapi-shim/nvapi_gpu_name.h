#ifndef STEALTH_NVAPI_GPU_NAME_H
#define STEALTH_NVAPI_GPU_NAME_H

#include "nvapi_identity.h"
#include "nvapi_types.h"

/*
 * 把已验证 identity 的逻辑 PCI 主 ID 投影为 NVAPI 标准型号名。
 * 本 helper 不依赖 Windows API，便于对失败输出清空语义做宿主机测试。
 */
NvAPI_Status nvapi_copy_standard_gpu_name(
    const struct nvapi_gpu_identity *identity,
    char output[NVAPI_SHORT_STRING_MAX]);

#endif
