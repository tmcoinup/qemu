/*
 * Version-checked clock structures used by GPU-Z 2.70 and NVAPI readers.
 *
 * The P-States 2.0 layouts and clock-domain IDs are from NVIDIA's public
 * NVAPI R535 header. GPU-Z 2.70 also queries private GetPerfClocks. Its V1
 * layout and selector behavior below are pinned to the GPU-Z 2.70 executable
 * and the complete 538.33 x86 handler, not inferred from a dispatch wrapper.
 *
 * Keep this header independent of windows.h so the exact layouts and fill
 * behavior can be tested natively on the build host.
 */
#ifndef NVAPI_PROFILE_CLOCKS_H
#define NVAPI_PROFILE_CLOCKS_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define NVAPI_PROFILE_CLOCK_GRAPHICS 0u
#define NVAPI_PROFILE_CLOCK_MEMORY 4u
#define NVAPI_PROFILE_CLOCK_PROCESSOR 7u
#define NVAPI_PROFILE_CLOCK_UNDEFINED 32u
#define NVAPI_PROFILE_PSTATE_P0 0u

#define NVAPI_PROFILE_PERF_CLOCK_COUNT 32u
#define NVAPI_PROFILE_PERF_LEVEL_COUNT 12u

struct nvapi_profile_perf_clock_entry {
    uint32_t domain_id;
    uint32_t reserved;
    uint32_t current_frequency_khz;
    uint32_t default_frequency_khz;
    uint32_t minimum_frequency_khz;
    uint32_t maximum_frequency_khz;
    uint32_t flags;
};

struct nvapi_profile_perf_clock_level {
    uint32_t level_id;
    uint32_t flags;
    struct nvapi_profile_perf_clock_entry
        clocks[NVAPI_PROFILE_PERF_CLOCK_COUNT];
};

struct nvapi_profile_perf_clocks_v1 {
    uint32_t version;
    uint32_t level_count;
    uint32_t level;
    uint32_t clock_count;
    uint32_t flags;
    struct nvapi_profile_perf_clock_level
        levels[NVAPI_PROFILE_PERF_LEVEL_COUNT];
};

#define NVAPI_PROFILE_PERF_CLOCKS_VER1 \
    ((uint32_t)sizeof(struct nvapi_profile_perf_clocks_v1) | \
     (UINT32_C(1) << 16))

#define NVAPI_PROFILE_PSTATE20_MAX_PSTATES 16u
#define NVAPI_PROFILE_PSTATE20_MAX_CLOCKS 8u
#define NVAPI_PROFILE_PSTATE20_MAX_BASE_VOLTAGES 4u

struct nvapi_profile_pstate20_delta {
    int32_t value;
    int32_t minimum;
    int32_t maximum;
};

struct nvapi_profile_pstate20_clock {
    uint32_t domain_id;
    uint32_t clock_type;
    uint32_t editable_and_reserved;
    struct nvapi_profile_pstate20_delta frequency_delta_khz;
    union {
        struct {
            uint32_t frequency_khz;
        } single;
        struct {
            uint32_t minimum_frequency_khz;
            uint32_t maximum_frequency_khz;
            uint32_t voltage_domain_id;
            uint32_t minimum_voltage_uv;
            uint32_t maximum_voltage_uv;
        } range;
    } data;
};

struct nvapi_profile_pstate20_base_voltage {
    uint32_t domain_id;
    uint32_t editable_and_reserved;
    uint32_t voltage_uv;
    struct nvapi_profile_pstate20_delta voltage_delta_uv;
};

struct nvapi_profile_pstate20_pstate {
    uint32_t pstate_id;
    uint32_t editable_and_reserved;
    struct nvapi_profile_pstate20_clock
        clocks[NVAPI_PROFILE_PSTATE20_MAX_CLOCKS];
    struct nvapi_profile_pstate20_base_voltage
        base_voltages[NVAPI_PROFILE_PSTATE20_MAX_BASE_VOLTAGES];
};

struct nvapi_profile_pstate20_info_v1 {
    uint32_t version;
    uint32_t editable_and_reserved;
    uint32_t pstate_count;
    uint32_t clock_count;
    uint32_t base_voltage_count;
    struct nvapi_profile_pstate20_pstate
        pstates[NVAPI_PROFILE_PSTATE20_MAX_PSTATES];
};

struct nvapi_profile_pstate20_info_v2 {
    struct nvapi_profile_pstate20_info_v1 base;
    struct {
        uint32_t voltage_count;
        struct nvapi_profile_pstate20_base_voltage
            voltages[NVAPI_PROFILE_PSTATE20_MAX_BASE_VOLTAGES];
    } overvoltage;
};

#define NVAPI_PROFILE_PSTATE20_INFO_VER1 \
    ((uint32_t)sizeof(struct nvapi_profile_pstate20_info_v1) | \
     (UINT32_C(1) << 16))
#define NVAPI_PROFILE_PSTATE20_INFO_VER2 \
    ((uint32_t)sizeof(struct nvapi_profile_pstate20_info_v2) | \
     (UINT32_C(2) << 16))
#define NVAPI_PROFILE_PSTATE20_INFO_VER3 \
    ((uint32_t)sizeof(struct nvapi_profile_pstate20_info_v2) | \
     (UINT32_C(3) << 16))

typedef char nvapi_profile_perf_clock_entry_size[
    sizeof(struct nvapi_profile_perf_clock_entry) == 28u ? 1 : -1];
typedef char nvapi_profile_perf_clock_level_size[
    sizeof(struct nvapi_profile_perf_clock_level) == 0x388u ? 1 : -1];
typedef char nvapi_profile_perf_clocks_v1_size[
    sizeof(struct nvapi_profile_perf_clocks_v1) == 0x2a74u ? 1 : -1];
typedef char nvapi_profile_pstate20_clock_size[
    sizeof(struct nvapi_profile_pstate20_clock) == 44u ? 1 : -1];
typedef char nvapi_profile_pstate20_pstate_size[
    sizeof(struct nvapi_profile_pstate20_pstate) == 456u ? 1 : -1];
typedef char nvapi_profile_pstate20_v1_size[
    sizeof(struct nvapi_profile_pstate20_info_v1) == 0x1c94u ? 1 : -1];
typedef char nvapi_profile_pstate20_v2_size[
    sizeof(struct nvapi_profile_pstate20_info_v2) == 0x1cf8u ? 1 : -1];

static inline int nvapi_profile_fill_perf_clocks(
    void *information,
    int32_t selector,
    uint32_t core_clock_khz,
    uint32_t boost_clock_khz,
    uint32_t memory_clock_khz)
{
    struct nvapi_profile_perf_clocks_v1 *output;
    uint32_t version;
    size_t index;

    /*
     * The 538.33 handler accepts -1 (enumerate) and level IDs 0..11.  This
     * profile deliberately publishes one level, so only -1 and 0 can be
     * synthesized; any other selector remains the original DLL's result.
     */
    if (!information || (selector != -1 && selector != 0) ||
        !core_clock_khz || boost_clock_khz < core_clock_khz ||
        !memory_clock_khz) {
        return 0;
    }
    version = *(const uint32_t *)information;
    if (version != NVAPI_PROFILE_PERF_CLOCKS_VER1) {
        return 0;
    }
    memset(information, 0, sizeof(*output));
    output = (struct nvapi_profile_perf_clocks_v1 *)information;
    output->version = version;
    output->level_count = 1u;
    output->level = 0u;
    output->clock_count = 3u;
    output->levels[0].level_id = 0u;
    for (index = 0; index < NVAPI_PROFILE_PERF_CLOCK_COUNT; index++) {
        output->levels[0].clocks[index].domain_id =
            NVAPI_PROFILE_CLOCK_UNDEFINED;
    }
    output->levels[0].clocks[0].domain_id =
        NVAPI_PROFILE_CLOCK_GRAPHICS;
    output->levels[0].clocks[0].current_frequency_khz = core_clock_khz;
    output->levels[0].clocks[0].default_frequency_khz = core_clock_khz;
    output->levels[0].clocks[0].minimum_frequency_khz = core_clock_khz;
    output->levels[0].clocks[0].maximum_frequency_khz = boost_clock_khz;

    output->levels[0].clocks[1].domain_id = NVAPI_PROFILE_CLOCK_MEMORY;
    output->levels[0].clocks[1].current_frequency_khz = memory_clock_khz;
    output->levels[0].clocks[1].default_frequency_khz = memory_clock_khz;
    output->levels[0].clocks[1].minimum_frequency_khz = memory_clock_khz;
    output->levels[0].clocks[1].maximum_frequency_khz = memory_clock_khz;

    output->levels[0].clocks[2].domain_id =
        NVAPI_PROFILE_CLOCK_PROCESSOR;
    output->levels[0].clocks[2].current_frequency_khz = core_clock_khz;
    output->levels[0].clocks[2].default_frequency_khz = core_clock_khz;
    output->levels[0].clocks[2].minimum_frequency_khz = core_clock_khz;
    output->levels[0].clocks[2].maximum_frequency_khz = boost_clock_khz;
    return 1;
}

static inline int nvapi_profile_fill_pstates20(
    void *information,
    uint32_t core_clock_khz,
    uint32_t boost_clock_khz,
    uint32_t memory_clock_khz)
{
    struct nvapi_profile_pstate20_info_v1 *output;
    struct nvapi_profile_pstate20_clock *graphics;
    struct nvapi_profile_pstate20_clock *memory;
    uint32_t version;
    size_t structure_size;

    if (!information || !core_clock_khz ||
        boost_clock_khz < core_clock_khz || !memory_clock_khz) {
        return 0;
    }
    version = *(const uint32_t *)information;
    if (version == NVAPI_PROFILE_PSTATE20_INFO_VER1) {
        structure_size = sizeof(struct nvapi_profile_pstate20_info_v1);
    } else if (version == NVAPI_PROFILE_PSTATE20_INFO_VER2 ||
               version == NVAPI_PROFILE_PSTATE20_INFO_VER3) {
        structure_size = sizeof(struct nvapi_profile_pstate20_info_v2);
    } else {
        return 0;
    }
    memset(information, 0, structure_size);
    output = (struct nvapi_profile_pstate20_info_v1 *)information;
    output->version = version;
    output->pstate_count = 1u;
    output->clock_count = 2u;
    output->pstates[0].pstate_id = NVAPI_PROFILE_PSTATE_P0;

    graphics = &output->pstates[0].clocks[0];
    graphics->domain_id = NVAPI_PROFILE_CLOCK_GRAPHICS;
    graphics->clock_type = 1u; /* RANGE */
    graphics->data.range.minimum_frequency_khz = core_clock_khz;
    graphics->data.range.maximum_frequency_khz = boost_clock_khz;

    memory = &output->pstates[0].clocks[1];
    memory->domain_id = NVAPI_PROFILE_CLOCK_MEMORY;
    memory->clock_type = 0u; /* SINGLE */
    memory->data.single.frequency_khz = memory_clock_khz;
    return 1;
}

#endif /* NVAPI_PROFILE_CLOCKS_H */
