#ifndef STEALTH_NVAPI_GPU_PSTATES_H
#define STEALTH_NVAPI_GPU_PSTATES_H

#include "nvapi_types.h"

/*
 * 以下结构逐字段对应 NVIDIA 官方 NV_GPU_PERF_PSTATES20_INFO V1/V2 ABI。
 * 不使用编译器位域：所有 editable/reserved 位均以一个 NvU32 表示，既保持
 * x86/x64 相同布局，也避免不同编译器对位域分配顺序的实现差异。
 */
struct nvapi_pstate20_delta {
    int32_t value;
    int32_t minimum;
    int32_t maximum;
};

struct nvapi_pstate20_clock_entry {
    NvU32 domain_id;
    NvU32 clock_type;
    NvU32 editable_and_reserved;
    struct nvapi_pstate20_delta frequency_delta_khz;
    union {
        struct {
            NvU32 frequency_khz;
        } single;
        struct {
            NvU32 minimum_frequency_khz;
            NvU32 maximum_frequency_khz;
            NvU32 voltage_domain_id;
            NvU32 minimum_voltage_uv;
            NvU32 maximum_voltage_uv;
        } range;
    } data;
};

struct nvapi_pstate20_base_voltage {
    NvU32 domain_id;
    NvU32 editable_and_reserved;
    NvU32 voltage_uv;
    struct nvapi_pstate20_delta voltage_delta_uv;
};

struct nvapi_pstate20_pstate {
    NvU32 pstate_id;
    NvU32 editable_and_reserved;
    struct nvapi_pstate20_clock_entry
        clocks[NVAPI_MAX_GPU_PSTATE20_CLOCKS];
    struct nvapi_pstate20_base_voltage
        base_voltages[NVAPI_MAX_GPU_PSTATE20_BASE_VOLTAGES];
};

struct nvapi_pstate20_info_v1 {
    NvU32 version;
    NvU32 editable_and_reserved;
    NvU32 pstate_count;
    NvU32 clock_count;
    NvU32 base_voltage_count;
    struct nvapi_pstate20_pstate
        pstates[NVAPI_MAX_GPU_PSTATE20_PSTATES];
};

/* V2/V3 复用完全相同的 V1 前缀，末尾只增加独立超压区域。 */
struct nvapi_pstate20_info_v2 {
    struct nvapi_pstate20_info_v1 base;
    struct {
        NvU32 voltage_count;
        struct nvapi_pstate20_base_voltage
            voltages[NVAPI_MAX_GPU_PSTATE20_BASE_VOLTAGES];
    } overvoltage;
};

#define NVAPI_PSTATE20_INFO_VERSION_1 \
    ((NvU32)sizeof(struct nvapi_pstate20_info_v1) | (UINT32_C(1) << 16))
#define NVAPI_PSTATE20_INFO_VERSION_2 \
    ((NvU32)sizeof(struct nvapi_pstate20_info_v2) | (UINT32_C(2) << 16))
#define NVAPI_PSTATE20_INFO_VERSION_3 \
    ((NvU32)sizeof(struct nvapi_pstate20_info_v2) | (UINT32_C(3) << 16))

/* 根据已验证 profile 生成单卡 P0 核心范围和固定 GDDR5 时钟。 */
NvAPI_Status nvapi_fill_pstates20(void *information, NvU32 base_clock_khz,
                                  NvU32 boost_clock_khz,
                                  NvU32 memory_clock_khz);

/* QueryInterface 暴露的逐物理 GPU 入口只参与 Windows DLL 构建。 */
#ifdef _WIN32
NvAPI_Status __cdecl nvapi_gpu_get_pstates20(NvPhysicalGpuHandle handle,
                                             void *information);
#endif

#endif
