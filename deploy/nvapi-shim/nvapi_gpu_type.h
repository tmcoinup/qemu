#ifndef STEALTH_NVAPI_GPU_TYPE_H
#define STEALTH_NVAPI_GPU_TYPE_H

#include "nvapi_types.h"

/*
 * 为已经完成 NVIDIA identity 与真实载体双重校验的句柄填写公开 GPU 类型。
 * 单独保留纯 C helper，便于 Linux 宿主测试与 Windows DLL 共用同一实现。
 */
NvAPI_Status nvapi_fill_gpu_type(NvU32 *gpu_type);

#endif
