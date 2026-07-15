#include <stddef.h>
#include <string.h>

#include "nvapi_gpu_legacy_clocks.h"

/* 这些断言将逆向确认过的 GPU-Z 私有 ABI 固定在编译期。 */
_Static_assert(sizeof(struct nvapi_perf_clock_entry) == 28u,
               "GetPerfClocks entry ABI size mismatch");
_Static_assert(sizeof(struct nvapi_perf_clock_profile) == 0x388u,
               "GetPerfClocks profile ABI size mismatch");
_Static_assert(sizeof(struct nvapi_perf_clocks_info_v1) == 0x2a74u,
               "GetPerfClocks V1 ABI size mismatch");
_Static_assert(offsetof(struct nvapi_perf_clocks_info_v1, profiles) == 20u,
               "GetPerfClocks profile ABI offset mismatch");
_Static_assert(offsetof(struct nvapi_perf_clock_profile, clocks) == 8u,
               "GetPerfClocks clock-array ABI offset mismatch");
_Static_assert(offsetof(struct nvapi_perf_clocks_info_v1,
                        profiles[0].clocks[0].frequency_khz) == 40u,
               "GetPerfClocks frequency ABI offset mismatch");
_Static_assert(sizeof(struct nvapi_legacy_clocks_gpu_z_v1) == 0x104u,
               "GPU-Z GetAllClocks ABI size mismatch");
_Static_assert(sizeof(struct nvapi_legacy_clocks_extended_v1) == 0x484u,
               "extended GetAllClocks ABI size mismatch");

static void set_perf_clock(struct nvapi_perf_clock_entry *entry,
                           NvU32 domain_id, NvU32 frequency_khz)
{
    entry->domain_id = domain_id;
    entry->present = 1u;
    entry->frequency_khz = frequency_khz;
}

NvAPI_Status nvapi_fill_perf_clocks(void *information, int32_t selector,
                                    NvU32 base_clock_khz,
                                    NvU32 boost_clock_khz,
                                    NvU32 memory_clock_khz)
{
    struct nvapi_perf_clocks_info_v1 *output;
    NvU32 version;
    NvU32 graphics_clock_khz;
    size_t index;

    if (information == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    version = *(const NvU32 *)information;
    if (version != NVAPI_PERF_CLOCKS_VERSION_1) {
        return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
    }
    /* -1 表示枚举全部 profile；0/1/2 分别兼容 current/base/boost。 */
    if (selector < -1 || selector > (int32_t)NVAPI_CLOCK_TYPE_BOOST ||
        base_clock_khz == 0u || boost_clock_khz < base_clock_khz ||
        memory_clock_khz == 0u) {
        return NVAPI_INVALID_ARGUMENT;
    }
    graphics_clock_khz = selector == (int32_t)NVAPI_CLOCK_TYPE_BOOST ?
        boost_clock_khz : base_clock_khz;

    memset(information, 0, sizeof(*output));
    output = (struct nvapi_perf_clocks_info_v1 *)information;
    output->version = version;
    output->profile_count = 1u;
    output->clock_count = 3u;
    output->profiles[0].pstate_id = NVAPI_GPU_PERF_PSTATE_P0;

    /*
     * GPU-Z 固定遍历 32 项，并把 domain=0 的后续空项也视为核心时钟。
     * 因而未使用项必须写成 UNDEFINED，不能依赖 memset 后的零值。
     */
    for (index = 0; index < NVAPI_PERF_CLOCK_ENTRY_COUNT; index++) {
        output->profiles[0].clocks[index].domain_id =
            NVAPI_GPU_PUBLIC_CLOCK_UNDEFINED;
    }
    set_perf_clock(&output->profiles[0].clocks[0],
                   NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS, graphics_clock_khz);
    set_perf_clock(&output->profiles[0].clocks[1],
                   NVAPI_GPU_PUBLIC_CLOCK_MEMORY, memory_clock_khz);
    set_perf_clock(&output->profiles[0].clocks[2],
                   NVAPI_GPU_PUBLIC_CLOCK_PROCESSOR, graphics_clock_khz);
    return NVAPI_OK;
}

NvAPI_Status nvapi_fill_legacy_clocks(void *information,
                                      NvU32 base_clock_khz,
                                      NvU32 memory_clock_khz)
{
    NvU32 *clocks;
    NvU32 version;
    size_t structure_size;

    if (information == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    version = *(const NvU32 *)information;
    if (version == NVAPI_LEGACY_CLOCKS_GPU_Z_VERSION_1) {
        structure_size = sizeof(struct nvapi_legacy_clocks_gpu_z_v1);
    } else if (version == NVAPI_LEGACY_CLOCKS_EXTENDED_VERSION_1) {
        structure_size = sizeof(struct nvapi_legacy_clocks_extended_v1);
    } else {
        return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
    }
    if (base_clock_khz == 0u || memory_clock_khz == 0u) {
        return NVAPI_INVALID_ARGUMENT;
    }

    memset(information, 0, structure_size);
    *(NvU32 *)information = version;
    clocks = (NvU32 *)information + 1;
    clocks[0] = base_clock_khz;
    /* GDDR5 保留 NVAPI 原始时钟；GPU-Z 再乘其 0.5 RAM-type 系数。 */
    clocks[8] = memory_clock_khz;
    return NVAPI_OK;
}
