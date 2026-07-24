/*
 * 直接执行交付 DLL 共用的 GPU 类型 helper，锁住空指针语义和官方 DGPU 枚举值。
 */

#include <stdio.h>

#include "nvapi_gpu_type.h"

int main(void)
{
    NvU32 gpu_type = UINT32_C(0xdeadbeef);

    if (NVAPI_ID_GPU_GET_GPU_TYPE != UINT32_C(0xC33BAEB1) ||
        NV_SYSTEM_TYPE_DGPU != 2u) {
        fprintf(stderr, "GetGPUType 官方 ABI 常量错误\n");
        return 1;
    }
    if (nvapi_fill_gpu_type(NULL) != NVAPI_INVALID_ARGUMENT) {
        fprintf(stderr, "GetGPUType 未拒绝空输出指针\n");
        return 1;
    }
    if (nvapi_fill_gpu_type(&gpu_type) != NVAPI_OK ||
        gpu_type != NV_SYSTEM_TYPE_DGPU) {
        fprintf(stderr, "验证后的独立显卡没有返回 DGPU\n");
        return 1;
    }
    return 0;
}
