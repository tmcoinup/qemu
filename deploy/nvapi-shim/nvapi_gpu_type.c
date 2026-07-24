/*
 * NvAPI_GPU_GetGPUType 的无平台依赖输出逻辑。
 *
 * 调用方必须先校验初始化状态、物理句柄以及 NVIDIA identity；通过这些门禁后，
 * 当前目录中的桌面 AIB profile 均属于独立 GPU，不能让工具回退成 UNKNOWN/IGPU。
 */

#include <stddef.h>

#include "nvapi_gpu_type.h"

NvAPI_Status nvapi_fill_gpu_type(NvU32 *gpu_type)
{
    if (gpu_type == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    *gpu_type = NV_SYSTEM_TYPE_DGPU;
    return NVAPI_OK;
}
