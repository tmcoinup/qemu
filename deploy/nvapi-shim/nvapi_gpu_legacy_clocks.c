#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "nvapi_gpu_legacy_clocks.h"
#include "nvapi_identity.h"
#include "nvapi_shim_internal.h"

static const struct nvapi_gpu_identity *clock_identity(
    NvPhysicalGpuHandle handle, NvAPI_Status *status)
{
    const struct nvapi_gpu_identity *identity;

    *status = nvapi_validate_gpu_handle(handle);
    if (*status != NVAPI_OK) {
        return NULL;
    }
    identity = nvapi_identity_get();
    if (identity == NULL) {
        *status = NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }
    return identity;
}

NvAPI_Status __cdecl nvapi_gpu_get_perf_clocks(
    NvPhysicalGpuHandle handle, int32_t selector, void *information)
{
    NvAPI_Status status;
    const struct nvapi_gpu_identity *identity = clock_identity(handle, &status);

    if (identity == NULL) {
        return status;
    }
    return nvapi_fill_perf_clocks(information, selector,
                                  identity->base_clock_khz,
                                  identity->boost_clock_khz,
                                  identity->memory_clock_khz);
}

NvAPI_Status __cdecl nvapi_gpu_get_legacy_all_clocks(
    NvPhysicalGpuHandle handle, void *information)
{
    NvAPI_Status status;
    const struct nvapi_gpu_identity *identity = clock_identity(handle, &status);

    if (identity == NULL) {
        return status;
    }
    return nvapi_fill_legacy_clocks(information, identity->base_clock_khz,
                                    identity->memory_clock_khz);
}
