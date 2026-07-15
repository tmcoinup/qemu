#ifndef STEALTH_NVAPI_GPU_LEGACY_CLOCKS_H
#define STEALTH_NVAPI_GPU_LEGACY_CLOCKS_H

#include "nvapi_types.h"

/*
 * GetPerfClocks 是 NVIDIA 私有但被 GPU-Z 2.70 使用的固定 ABI。V1 由
 * 20 字节头、12 个 profile 组成；每个 profile 又包含 8 字节头和
 * 32 个 28 字节 clock entry，总大小必须为 0x2A74。
 */
#define NVAPI_PERF_CLOCK_PROFILE_COUNT 12
#define NVAPI_PERF_CLOCK_ENTRY_COUNT 32

struct nvapi_perf_clock_entry {
    NvU32 domain_id;
    NvU32 flags;
    NvU32 present;
    NvU32 frequency_khz;
    NvU32 reserved_10;
    NvU32 reserved_14;
    NvU32 reserved_18;
};

struct nvapi_perf_clock_profile {
    NvU32 pstate_id;
    NvU32 flags;
    struct nvapi_perf_clock_entry clocks[NVAPI_PERF_CLOCK_ENTRY_COUNT];
};

struct nvapi_perf_clocks_info_v1 {
    NvU32 version;
    NvU32 flags;
    NvU32 profile_count;
    NvU32 clock_count;
    NvU32 reserved;
    struct nvapi_perf_clock_profile profiles[NVAPI_PERF_CLOCK_PROFILE_COUNT];
};

#define NVAPI_PERF_CLOCKS_VERSION_1 \
    ((NvU32)sizeof(struct nvapi_perf_clocks_info_v1) | \
     (UINT32_C(1) << 16))

/*
 * GetAllClocks 的 V1 曾有 64 槽和 288 槽两个大小。GPU-Z 2.70 请求
 * 0x00010104（64 槽）；部分新读者使用 0x00010484（288 槽）。
 */
#define NVAPI_LEGACY_CLOCK_COUNT_GPU_Z 64
#define NVAPI_LEGACY_CLOCK_COUNT_EXTENDED 288

struct nvapi_legacy_clocks_gpu_z_v1 {
    NvU32 version;
    NvU32 clocks[NVAPI_LEGACY_CLOCK_COUNT_GPU_Z];
};

struct nvapi_legacy_clocks_extended_v1 {
    NvU32 version;
    NvU32 clocks[NVAPI_LEGACY_CLOCK_COUNT_EXTENDED];
};

#define NVAPI_LEGACY_CLOCKS_GPU_Z_VERSION_1 \
    ((NvU32)sizeof(struct nvapi_legacy_clocks_gpu_z_v1) | \
     (UINT32_C(1) << 16))
#define NVAPI_LEGACY_CLOCKS_EXTENDED_VERSION_1 \
    ((NvU32)sizeof(struct nvapi_legacy_clocks_extended_v1) | \
     (UINT32_C(1) << 16))

/* 纯填充函数供 Windows DLL 与 Linux 合同测试共同使用。 */
NvAPI_Status nvapi_fill_perf_clocks(void *information, int32_t selector,
                                    NvU32 base_clock_khz,
                                    NvU32 boost_clock_khz,
                                    NvU32 memory_clock_khz);
NvAPI_Status nvapi_fill_legacy_clocks(void *information,
                                      NvU32 base_clock_khz,
                                      NvU32 memory_clock_khz);

#ifdef _WIN32
NvAPI_Status __cdecl nvapi_gpu_get_perf_clocks(
    NvPhysicalGpuHandle handle, int32_t selector, void *information);
NvAPI_Status __cdecl nvapi_gpu_get_legacy_all_clocks(
    NvPhysicalGpuHandle handle, void *information);
#endif

#endif
