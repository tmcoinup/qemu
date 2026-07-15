#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>

#include "nvapi_gpu_details.h"
#include "nvapi_gpu_specs.h"
#include "nvapi_identity.h"
#include "nvapi_shim_internal.h"

static const uintptr_t logical_gpu_token = UINT32_C(0xB007C0DF);

static const struct nvapi_gpu_identity *validated_identity(
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

NvAPI_Status __cdecl nvapi_gpu_get_vbios_revision(
    NvPhysicalGpuHandle handle, NvU32 *revision)
{
    NvAPI_Status status;
    const struct nvapi_gpu_identity *identity;

    if (revision == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    identity = validated_identity(handle, &status);
    if (identity == NULL) {
        return status;
    }
    *revision = identity->vbios_revision;
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_gpu_get_vbios_oem_revision(
    NvPhysicalGpuHandle handle, NvU32 *revision)
{
    NvAPI_Status status;
    const struct nvapi_gpu_identity *identity;

    if (revision == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    identity = validated_identity(handle, &status);
    if (identity == NULL) {
        return status;
    }
    *revision = identity->vbios_oem_revision;
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_gpu_get_vbios_version_string(
    NvPhysicalGpuHandle handle, char *output)
{
    NvAPI_Status status;
    const struct nvapi_gpu_identity *identity;

    if (output == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    identity = validated_identity(handle, &status);
    if (identity == NULL) {
        return status;
    }
    lstrcpynA(output, identity->bios, NVAPI_SHORT_STRING_MAX);
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_gpu_get_ram_type(
    NvPhysicalGpuHandle handle, NvU32 *ram_type)
{
    NvAPI_Status status;
    const struct nvapi_gpu_identity *identity;

    if (ram_type == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    identity = validated_identity(handle, &status);
    if (identity == NULL) {
        return status;
    }
    *ram_type = identity->ram_type;
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_gpu_get_ram_bus_width(
    NvPhysicalGpuHandle handle, NvU32 *width_bits)
{
    NvAPI_Status status;
    const struct nvapi_gpu_identity *identity;

    if (width_bits == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    identity = validated_identity(handle, &status);
    if (identity == NULL) {
        return status;
    }
    *width_bits = identity->ram_bus_width_bits;
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_gpu_get_fb_width_and_location(
    NvPhysicalGpuHandle handle, NvU32 *width_bits, NvU32 *location)
{
    NvAPI_Status status;

    if (width_bits == NULL || location == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_gpu_get_ram_bus_width(handle, width_bits);
    if (status != NVAPI_OK) {
        return status;
    }
    /* 单卡离散显存位于本 GPU；旧私有 NVAPI 对该字段用 0 表示本地 framebuffer。 */
    *location = 0u;
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_gpu_get_all_clock_frequencies(
    NvPhysicalGpuHandle handle, struct nvapi_clock_frequencies *frequencies)
{
    NvAPI_Status status;
    const struct nvapi_gpu_identity *identity;

    if (frequencies == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    identity = validated_identity(handle, &status);
    if (identity == NULL) {
        return status;
    }
    return nvapi_fill_clock_frequencies(frequencies, identity->base_clock_khz,
                                        identity->boost_clock_khz,
                                        identity->memory_clock_khz);
}

NvAPI_Status __cdecl nvapi_enum_logical_gpus(
    NvLogicalGpuHandle handles[NVAPI_MAX_LOGICAL_GPUS], NvU32 *count)
{
    NvAPI_Status status;

    if (handles == NULL || count == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    *count = 0u;
    status = nvapi_require_initialized();
    if (status != NVAPI_OK) {
        return status;
    }
    handles[0] = (NvLogicalGpuHandle)(uintptr_t)logical_gpu_token;
    *count = 1u;
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_get_logical_gpu_from_physical_gpu(
    NvPhysicalGpuHandle physical, NvLogicalGpuHandle *logical)
{
    NvAPI_Status status;

    if (logical == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(physical);
    if (status != NVAPI_OK) {
        return status;
    }
    *logical = (NvLogicalGpuHandle)(uintptr_t)logical_gpu_token;
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_get_physical_gpus_from_logical_gpu(
    NvLogicalGpuHandle logical,
    NvPhysicalGpuHandle physical[NVAPI_MAX_PHYSICAL_GPUS], NvU32 *count)
{
    NvAPI_Status status;

    if (physical == NULL || count == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    *count = 0u;
    status = nvapi_require_initialized();
    if (status != NVAPI_OK) {
        return status;
    }
    if (logical != (NvLogicalGpuHandle)(uintptr_t)logical_gpu_token) {
        return NVAPI_EXPECTED_LOGICAL_GPU_HANDLE;
    }
    physical[0] = nvapi_physical_gpu_handle();
    *count = 1u;
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_gpu_get_connected_outputs(
    NvPhysicalGpuHandle handle, NvU32 *outputs_mask)
{
    NvAPI_Status status;

    if (outputs_mask == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    /* 单显示器占用 output bit 0；无有效 SLI 组时 SLI 版本 API 也应返回同一 mask。 */
    *outputs_mask = 1u;
    return NVAPI_OK;
}
