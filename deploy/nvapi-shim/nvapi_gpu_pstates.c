#include "nvapi_gpu_pstates.h"
#include "nvapi_identity.h"
#include "nvapi_shim_internal.h"

NvAPI_Status __cdecl nvapi_gpu_get_pstates20(NvPhysicalGpuHandle handle,
                                             void *information)
{
    const struct nvapi_gpu_identity *identity;
    NvAPI_Status status;

    if (information == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    identity = nvapi_identity_get();
    if (identity == NULL) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }
    return nvapi_fill_pstates20(information, identity->base_clock_khz,
                                identity->boost_clock_khz,
                                identity->memory_clock_khz);
}
