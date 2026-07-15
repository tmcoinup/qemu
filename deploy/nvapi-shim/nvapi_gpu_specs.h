#ifndef STEALTH_NVAPI_GPU_SPECS_H
#define STEALTH_NVAPI_GPU_SPECS_H

#include "nvapi_types.h"

/* 解析 profile 中的 `Version xx.xx.xx.xx.yy`，并生成 NVAPI 标准短字符串。 */
int nvapi_parse_vbios(const char *source, char output[NVAPI_SHORT_STRING_MAX],
                      NvU32 *revision, NvU32 *oem_revision);

/* 根据调用方请求的 current/base/boost 类型填充公开 32-domain 时钟结构。 */
NvAPI_Status nvapi_fill_clock_frequencies(
    struct nvapi_clock_frequencies *frequencies, NvU32 base_clock_khz,
    NvU32 boost_clock_khz, NvU32 memory_clock_khz);

#endif
