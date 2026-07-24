#ifndef STEALTH_NVAPI_MEMORY_H
#define STEALTH_NVAPI_MEMORY_H

#include "nvapi_types.h"

/*
 * NVIDIA 的 legacy MemoryInfo 使用 KiB；520+ MemoryInfoEx 使用 bytes。
 * 两套结构必须并存，不能把旧 framebuffer 接口的 KiB 数值直接当成 MiB。
 */
struct nvapi_display_driver_memory_info_v1 {
    NvU32 version;
    NvU32 dedicated_video_memory_kib;
    NvU32 available_dedicated_video_memory_kib;
    NvU32 system_video_memory_kib;
    NvU32 shared_system_memory_kib;
};

struct nvapi_display_driver_memory_info_v2 {
    struct nvapi_display_driver_memory_info_v1 v1;
    NvU32 current_available_dedicated_video_memory_kib;
};

struct nvapi_display_driver_memory_info_v3 {
    struct nvapi_display_driver_memory_info_v2 v2;
    NvU32 dedicated_video_memory_evictions_size_kib;
    NvU32 dedicated_video_memory_eviction_count;
};

#pragma pack(push, 8)
struct nvapi_gpu_memory_info_ex_v1 {
    NvU32 version;
    NvU32 alignment_padding;
    uint64_t dedicated_video_memory_bytes;
    uint64_t available_dedicated_video_memory_bytes;
    uint64_t system_video_memory_bytes;
    uint64_t shared_system_memory_bytes;
    uint64_t current_available_dedicated_video_memory_bytes;
    uint64_t dedicated_video_memory_evictions_size_bytes;
    uint64_t dedicated_video_memory_eviction_count;
    uint64_t dedicated_video_memory_promotions_size_bytes;
    uint64_t dedicated_video_memory_promotion_count;
};
#pragma pack(pop)

#define NVAPI_MEMORY_INFO_VERSION_1 \
    ((NvU32)sizeof(struct nvapi_display_driver_memory_info_v1) | \
     (UINT32_C(1) << 16))
#define NVAPI_MEMORY_INFO_VERSION_2 \
    ((NvU32)sizeof(struct nvapi_display_driver_memory_info_v2) | \
     (UINT32_C(2) << 16))
#define NVAPI_MEMORY_INFO_VERSION_3 \
    ((NvU32)sizeof(struct nvapi_display_driver_memory_info_v3) | \
     (UINT32_C(3) << 16))
#define NVAPI_MEMORY_INFO_EX_VERSION_1 \
    ((NvU32)sizeof(struct nvapi_gpu_memory_info_ex_v1) | \
     (UINT32_C(1) << 16))

NvAPI_Status __cdecl nvapi_gpu_get_memory_info(
    NvPhysicalGpuHandle handle, void *memory_info);
NvAPI_Status __cdecl nvapi_gpu_get_memory_info_ex(
    NvPhysicalGpuHandle handle, struct nvapi_gpu_memory_info_ex_v1 *memory_info);

#endif
