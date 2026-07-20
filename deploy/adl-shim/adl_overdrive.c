#include <stddef.h>
#include <string.h>

#include "adl_profile.h"
#include "adl_runtime.h"

#define ADL_OD_VERSION_POLARIS 7
#define ADL_OD_LEVEL_COUNT 2

static int overdrive_caps_get(ADL_CONTEXT_HANDLE context, int require_context,
                              int adapter_index, int *supported,
                              int *enabled, int *version)
{
    struct adl_gpu_identity identity;
    int status;

    if (supported == NULL || enabled == NULL || version == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *supported = 0;
    *enabled = 0;
    *version = 0;
    status = adl_runtime_adapter(context, require_context, adapter_index,
                                 &identity);
    if (status == ADL_OK) {
        (void)identity;
        *supported = 1;
        *enabled = 1;
        *version = ADL_OD_VERSION_POLARIS;
    }
    return status;
}

int ADL_Overdrive_Caps(int adapter_index, int *supported, int *enabled,
                       int *version)
{
    return overdrive_caps_get(NULL, 0, adapter_index, supported, enabled,
                              version);
}

int ADL2_Overdrive_Caps(ADL_CONTEXT_HANDLE context, int adapter_index,
                        int *supported, int *enabled, int *version)
{
    return overdrive_caps_get(context, 1, adapter_index, supported, enabled,
                              version);
}

int ADL_Overdrive5_CurrentActivity_Get(int adapter_index,
                                       ADLPMActivity *activity)
{
    struct adl_gpu_identity identity;
    int status;

    if (activity == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    if (activity->iSize != (int)sizeof(*activity)) {
        return ADL_ERR_INVALID_PARAM_SIZE;
    }
    status = adl_runtime_adapter(NULL, 0, adapter_index, &identity);
    if (status != ADL_OK) {
        return status;
    }
    (void)identity;
    return ADL_ERR_NOT_SUPPORTED;
}

int ADL_Overdrive5_ODParameters_Get(int adapter_index,
                                    ADLODParameters *parameters)
{
    struct adl_gpu_identity identity;
    int status;

    if (parameters == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    if (parameters->iSize != (int)sizeof(*parameters)) {
        return ADL_ERR_INVALID_PARAM_SIZE;
    }
    status = adl_runtime_adapter(NULL, 0, adapter_index, &identity);
    if (status != ADL_OK) {
        return status;
    }
    memset(parameters, 0, sizeof(*parameters));
    parameters->iSize = (int)sizeof(*parameters);
    parameters->iNumberOfPerformanceLevels = ADL_OD_LEVEL_COUNT;
    parameters->iActivityReportingSupported = 0;
    parameters->iDiscretePerformanceLevels = 1;
    parameters->sEngineClock.iMin = adl_profile_core_10khz(&identity);
    parameters->sEngineClock.iMax = adl_profile_boost_10khz(&identity);
    parameters->sEngineClock.iStep = 100;
    parameters->sMemoryClock.iMin = adl_profile_memory_10khz(&identity);
    parameters->sMemoryClock.iMax = adl_profile_memory_10khz(&identity);
    parameters->sMemoryClock.iStep = 0;
    return ADL_OK;
}

int ADL_Overdrive5_ODPerformanceLevels_Get(
    int adapter_index, int use_default, ADLODPerformanceLevels *levels)
{
    struct adl_gpu_identity identity;
    const size_t required = offsetof(ADLODPerformanceLevels, aLevels) +
        ADL_OD_LEVEL_COUNT * sizeof(ADLODPerformanceLevel);
    int supplied_size;
    int status;

    (void)use_default;
    if (levels == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    supplied_size = levels->iSize;
    if (supplied_size < 0 || (size_t)supplied_size < required) {
        return ADL_ERR_INVALID_PARAM_SIZE;
    }
    status = adl_runtime_adapter(NULL, 0, adapter_index, &identity);
    if (status != ADL_OK) {
        return status;
    }
    memset(levels, 0, required);
    levels->iSize = (int)required;
    levels->aLevels[0].iEngineClock = adl_profile_core_10khz(&identity);
    levels->aLevels[0].iMemoryClock = adl_profile_memory_10khz(&identity);
    levels->aLevels[1].iEngineClock = adl_profile_boost_10khz(&identity);
    levels->aLevels[1].iMemoryClock = adl_profile_memory_10khz(&identity);
    return ADL_OK;
}

static void fill_odn_range(ADLODNParameterRange *range, int minimum,
                           int maximum, int default_value)
{
    memset(range, 0, sizeof(*range));
    range->iMode = 0;
    range->iMin = minimum;
    range->iMax = maximum;
    range->iStep = minimum == maximum ? 0 : 100;
    range->iDefault = default_value;
}

int ADL2_OverdriveN_Capabilities_Get(ADL_CONTEXT_HANDLE context,
                                     int adapter_index,
                                     ADLODNCapabilities *capabilities)
{
    struct adl_gpu_identity identity;
    int status;

    if (capabilities == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = adl_runtime_adapter(context, 1, adapter_index, &identity);
    if (status != ADL_OK) {
        return status;
    }
    memset(capabilities, 0, sizeof(*capabilities));
    capabilities->iMaximumNumberOfPerformanceLevels = ADL_OD_LEVEL_COUNT;
    fill_odn_range(&capabilities->sEngineClockRange,
                   adl_profile_core_mhz(&identity),
                   adl_profile_boost_mhz(&identity),
                   adl_profile_core_mhz(&identity));
    fill_odn_range(&capabilities->sMemoryClockRange,
                   adl_profile_memory_mhz(&identity),
                   adl_profile_memory_mhz(&identity),
                   adl_profile_memory_mhz(&identity));
    return ADL_OK;
}

int ADL2_OverdriveN_CapabilitiesX2_Get(
    ADL_CONTEXT_HANDLE context, int adapter_index,
    ADLODNCapabilitiesX2 *capabilities)
{
    struct adl_gpu_identity identity;
    int status;

    if (capabilities == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = adl_runtime_adapter(context, 1, adapter_index, &identity);
    if (status != ADL_OK) {
        return status;
    }
    memset(capabilities, 0, sizeof(*capabilities));
    capabilities->iMaximumNumberOfPerformanceLevels = ADL_OD_LEVEL_COUNT;
    /*
     * iFlags 为可写 WattMan 功能位；本兼容层只提供静态读取，故保持为 0，
     * 不能把 profile 时钟误宣称成真实可调硬件范围。
     */
    capabilities->iFlags = 0;
    fill_odn_range(&capabilities->sEngineClockRange,
                   adl_profile_core_mhz(&identity),
                   adl_profile_boost_mhz(&identity),
                   adl_profile_core_mhz(&identity));
    fill_odn_range(&capabilities->sMemoryClockRange,
                   adl_profile_memory_mhz(&identity),
                   adl_profile_memory_mhz(&identity),
                   adl_profile_memory_mhz(&identity));
    return ADL_OK;
}

static int fill_odn_levels(const struct adl_gpu_identity *identity,
                           int memory_domain,
                           ADLODNPerformanceLevels *levels)
{
    const size_t required = offsetof(ADLODNPerformanceLevels, aLevels) +
        ADL_OD_LEVEL_COUNT * sizeof(ADLODNPerformanceLevel);
    int supplied_size = levels->iSize;
    int requested_mode = levels->iMode;

    if (supplied_size < 0 || (size_t)supplied_size < required ||
        requested_mode < 0 || requested_mode > 3) {
        return ADL_ERR_INVALID_PARAM_SIZE;
    }
    memset(levels, 0, required);
    levels->iSize = (int)required;
    levels->iMode = requested_mode;
    levels->iNumberOfPerformanceLevels = ADL_OD_LEVEL_COUNT;
    levels->aLevels[0].iClock = memory_domain ?
        adl_profile_memory_mhz(identity) : adl_profile_core_mhz(identity);
    levels->aLevels[1].iClock = memory_domain ?
        adl_profile_memory_mhz(identity) : adl_profile_boost_mhz(identity);
    levels->aLevels[0].iEnabled = 1;
    levels->aLevels[1].iEnabled = 1;
    return ADL_OK;
}

static int odn_levels_get(ADL_CONTEXT_HANDLE context, int adapter_index,
                          int memory_domain,
                          ADLODNPerformanceLevels *levels)
{
    struct adl_gpu_identity identity;
    int status;

    if (levels == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = adl_runtime_adapter(context, 1, adapter_index, &identity);
    return status == ADL_OK ?
        fill_odn_levels(&identity, memory_domain, levels) : status;
}

int ADL2_OverdriveN_SystemClocks_Get(ADL_CONTEXT_HANDLE context,
                                     int adapter_index,
                                     ADLODNPerformanceLevels *levels)
{
    return odn_levels_get(context, adapter_index, 0, levels);
}

int ADL2_OverdriveN_MemoryClocks_Get(ADL_CONTEXT_HANDLE context,
                                     int adapter_index,
                                     ADLODNPerformanceLevels *levels)
{
    return odn_levels_get(context, adapter_index, 1, levels);
}

static int fill_odn_levels_x2(const struct adl_gpu_identity *identity,
                              int memory_domain,
                              ADLODNPerformanceLevelsX2 *levels)
{
    const size_t required = offsetof(ADLODNPerformanceLevelsX2, aLevels) +
        ADL_OD_LEVEL_COUNT * sizeof(ADLODNPerformanceLevelX2);
    int supplied_size = levels->iSize;
    int requested_mode = levels->iMode;

    if (supplied_size < 0 || (size_t)supplied_size < required ||
        requested_mode < 0 || requested_mode > 3) {
        return ADL_ERR_INVALID_PARAM_SIZE;
    }
    memset(levels, 0, required);
    levels->iSize = (int)required;
    levels->iMode = requested_mode;
    levels->iNumberOfPerformanceLevels = ADL_OD_LEVEL_COUNT;
    levels->aLevels[0].iClock = memory_domain ?
        adl_profile_memory_mhz(identity) : adl_profile_core_mhz(identity);
    levels->aLevels[1].iClock = memory_domain ?
        adl_profile_memory_mhz(identity) : adl_profile_boost_mhz(identity);
    levels->aLevels[0].iEnabled = 1;
    levels->aLevels[1].iEnabled = 1;
    return ADL_OK;
}

static int odn_levels_x2_get(ADL_CONTEXT_HANDLE context, int adapter_index,
                             int memory_domain,
                             ADLODNPerformanceLevelsX2 *levels)
{
    struct adl_gpu_identity identity;
    int status;

    if (levels == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = adl_runtime_adapter(context, 1, adapter_index, &identity);
    return status == ADL_OK ?
        fill_odn_levels_x2(&identity, memory_domain, levels) : status;
}

int ADL2_OverdriveN_SystemClocksX2_Get(ADL_CONTEXT_HANDLE context,
                                       int adapter_index,
                                       ADLODNPerformanceLevelsX2 *levels)
{
    return odn_levels_x2_get(context, adapter_index, 0, levels);
}

int ADL2_OverdriveN_MemoryClocksX2_Get(ADL_CONTEXT_HANDLE context,
                                       int adapter_index,
                                       ADLODNPerformanceLevelsX2 *levels)
{
    return odn_levels_x2_get(context, adapter_index, 1, levels);
}

int ADL2_OverdriveN_PerformanceStatus_Get(
    ADL_CONTEXT_HANDLE context, int adapter_index,
    ADLODNPerformanceStatus *performance)
{
    struct adl_gpu_identity identity;
    int status;

    if (performance == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = adl_runtime_adapter(context, 1, adapter_index, &identity);
    if (status != ADL_OK) {
        return status;
    }
    (void)identity;
    return ADL_ERR_NOT_SUPPORTED;
}

static int observed_clock_get(ADL_CONTEXT_HANDLE context, int require_context,
                              int adapter_index, int *core_clock,
                              int *memory_clock)
{
    struct adl_gpu_identity identity;
    int status;

    if (core_clock == NULL || memory_clock == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *core_clock = 0;
    *memory_clock = 0;
    status = adl_runtime_adapter(context, require_context, adapter_index,
                                 &identity);
    if (status == ADL_OK) {
        /* ObservedClockInfo 的官方单位是 MHz，不是 OD 的 10 kHz。 */
        *core_clock = adl_profile_core_mhz(&identity);
        *memory_clock = adl_profile_memory_mhz(&identity);
    }
    return status;
}

int ADL_Adapter_ObservedClockInfo_Get(int adapter_index, int *core_clock,
                                     int *memory_clock)
{
    return observed_clock_get(NULL, 0, adapter_index, core_clock,
                              memory_clock);
}

int ADL2_Adapter_ObservedClockInfo_Get(ADL_CONTEXT_HANDLE context,
                                      int adapter_index, int *core_clock,
                                      int *memory_clock)
{
    return observed_clock_get(context, 1, adapter_index, core_clock,
                              memory_clock);
}

int ADL_Adapter_ObservedGameClockInfo_Get(
    ADL_CONTEXT_HANDLE context, int adapter_index, int *base_clock,
    int *game_clock, int *boost_clock, int *memory_clock)
{
    struct adl_gpu_identity identity;
    int status;

    if (base_clock == NULL || game_clock == NULL || boost_clock == NULL ||
        memory_clock == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *base_clock = 0;
    *game_clock = 0;
    *boost_clock = 0;
    *memory_clock = 0;
    status = adl_runtime_adapter(context, 1, adapter_index, &identity);
    if (status == ADL_OK) {
        *base_clock = adl_profile_core_mhz(&identity);
        *game_clock = *base_clock;
        *boost_clock = adl_profile_boost_mhz(&identity);
        *memory_clock = adl_profile_memory_mhz(&identity);
    }
    return status;
}
