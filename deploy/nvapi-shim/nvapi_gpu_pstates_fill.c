#include <stddef.h>
#include <string.h>

#include "nvapi_gpu_pstates.h"

/*
 * 这些断言锁住 GPU-Z 2.70 实际传入的 0x00011C94 结构及其范围字段偏移。
 * 任一平台若产生额外 padding，构建必须直接失败，不能把错误布局交给来宾。
 */
_Static_assert(sizeof(struct nvapi_pstate20_delta) == 12u,
               "P-States delta ABI size mismatch");
_Static_assert(sizeof(struct nvapi_pstate20_clock_entry) == 44u,
               "P-States clock ABI size mismatch");
_Static_assert(sizeof(struct nvapi_pstate20_pstate) == 456u,
               "P-States entry ABI size mismatch");
_Static_assert(sizeof(struct nvapi_pstate20_info_v1) == 0x1c94u,
               "P-States V1 ABI size mismatch");
_Static_assert(sizeof(struct nvapi_pstate20_info_v2) == 0x1cf8u,
               "P-States V2 ABI size mismatch");
_Static_assert(offsetof(struct nvapi_pstate20_info_v1, pstates) == 20u,
               "P-States array ABI offset mismatch");
_Static_assert(offsetof(struct nvapi_pstate20_pstate, clocks) == 8u,
               "P-States clock array ABI offset mismatch");
_Static_assert(offsetof(struct nvapi_pstate20_clock_entry,
                        data.range.minimum_frequency_khz) == 24u,
               "P-States range ABI offset mismatch");

static int supported_version(NvU32 version, size_t *structure_size)
{
    NvU32 revision = version >> 16;
    NvU32 encoded_size = version & UINT32_C(0xffff);

    if (revision == 1u &&
        encoded_size == sizeof(struct nvapi_pstate20_info_v1)) {
        *structure_size = sizeof(struct nvapi_pstate20_info_v1);
        return 1;
    }
    if ((revision == 2u || revision == 3u) &&
        encoded_size == sizeof(struct nvapi_pstate20_info_v2)) {
        *structure_size = sizeof(struct nvapi_pstate20_info_v2);
        return 1;
    }
    return 0;
}

NvAPI_Status nvapi_fill_pstates20(void *information, NvU32 base_clock_khz,
                                  NvU32 boost_clock_khz,
                                  NvU32 memory_clock_khz)
{
    struct nvapi_pstate20_info_v1 *output;
    struct nvapi_pstate20_clock_entry *graphics;
    struct nvapi_pstate20_clock_entry *memory;
    NvU32 version;
    size_t structure_size;

    if (information == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    version = *(const NvU32 *)information;
    if (!supported_version(version, &structure_size)) {
        return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
    }
    if (base_clock_khz == 0u || boost_clock_khz < base_clock_khz ||
        memory_clock_khz == 0u) {
        return NVAPI_INVALID_ARGUMENT;
    }

    /*
     * 先清空调用方给定版本的完整缓冲区，再恢复 version。这样 V2/V3 的超压
     * 区域也始终为“无数据”，不会泄漏调用方栈上的旧内容。
     */
    memset(information, 0, structure_size);
    output = (struct nvapi_pstate20_info_v1 *)information;
    output->version = version;
    output->pstate_count = 1u;
    output->clock_count = 2u;
    output->base_voltage_count = 0u;
    output->pstates[0].pstate_id = NVAPI_GPU_PERF_PSTATE_P0;

    /* Pascal 核心在 P0 内是 base..boost 范围；这也是读者选择公开时钟 API 的依据。 */
    graphics = &output->pstates[0].clocks[0];
    graphics->domain_id = NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS;
    graphics->clock_type = NVAPI_GPU_PSTATE20_CLOCK_TYPE_RANGE;
    graphics->data.range.minimum_frequency_khz = base_clock_khz;
    graphics->data.range.maximum_frequency_khz = boost_clock_khz;
    graphics->data.range.voltage_domain_id = NVAPI_GPU_VOLTAGE_DOMAIN_CORE;

    /* GDDR5 在给定 P0 下使用固定 NVAPI memory-domain 频率。 */
    memory = &output->pstates[0].clocks[1];
    memory->domain_id = NVAPI_GPU_PUBLIC_CLOCK_MEMORY;
    memory->clock_type = NVAPI_GPU_PSTATE20_CLOCK_TYPE_SINGLE;
    memory->data.single.frequency_khz = memory_clock_khz;
    return NVAPI_OK;
}
