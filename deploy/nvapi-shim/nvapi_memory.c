#include <string.h>

#include "nvapi_identity.h"
#include "nvapi_memory.h"
#include "nvapi_shim_internal.h"

_Static_assert(sizeof(struct nvapi_display_driver_memory_info_v1) == 20u,
               "NV_DISPLAY_DRIVER_MEMORY_INFO_V1 ABI size");
_Static_assert(sizeof(struct nvapi_display_driver_memory_info_v2) == 24u,
               "NV_DISPLAY_DRIVER_MEMORY_INFO_V2 ABI size");
_Static_assert(sizeof(struct nvapi_display_driver_memory_info_v3) == 32u,
               "NV_DISPLAY_DRIVER_MEMORY_INFO_V3 ABI size");
_Static_assert(sizeof(struct nvapi_gpu_memory_info_ex_v1) == 80u,
               "NV_GPU_MEMORY_INFO_EX_V1 ABI size");

static NvAPI_Status get_validated_identity(
    NvPhysicalGpuHandle handle, const struct nvapi_gpu_identity **identity)
{
    NvAPI_Status status;

    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    *identity = nvapi_identity_get();
    return *identity == NULL ? NVAPI_NVIDIA_DEVICE_NOT_FOUND : NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_gpu_get_memory_info(
    NvPhysicalGpuHandle handle, void *memory_info)
{
    const struct nvapi_gpu_identity *identity;
    NvAPI_Status status;
    NvU32 version;

    if (memory_info == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    version = *(const NvU32 *)memory_info;
    if (version != NVAPI_MEMORY_INFO_VERSION_1 &&
        version != NVAPI_MEMORY_INFO_VERSION_2 &&
        version != NVAPI_MEMORY_INFO_VERSION_3) {
        return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
    }
    status = get_validated_identity(handle, &identity);
    if (status != NVAPI_OK) {
        return status;
    }
    if (version == NVAPI_MEMORY_INFO_VERSION_1) {
        struct nvapi_display_driver_memory_info_v1 *info = memory_info;

        memset(info, 0, sizeof(*info));
        info->version = version;
        info->dedicated_video_memory_kib = identity->vram_kib;
        info->available_dedicated_video_memory_kib = identity->vram_kib;
    } else if (version == NVAPI_MEMORY_INFO_VERSION_2) {
        struct nvapi_display_driver_memory_info_v2 *info = memory_info;

        memset(info, 0, sizeof(*info));
        info->v1.version = version;
        info->v1.dedicated_video_memory_kib = identity->vram_kib;
        info->v1.available_dedicated_video_memory_kib = identity->vram_kib;
        info->current_available_dedicated_video_memory_kib =
            identity->vram_kib;
    } else {
        struct nvapi_display_driver_memory_info_v3 *info = memory_info;

        memset(info, 0, sizeof(*info));
        info->v2.v1.version = version;
        info->v2.v1.dedicated_video_memory_kib = identity->vram_kib;
        info->v2.v1.available_dedicated_video_memory_kib =
            identity->vram_kib;
        info->v2.current_available_dedicated_video_memory_kib =
            identity->vram_kib;
    }
    return NVAPI_OK;
}

NvAPI_Status __cdecl nvapi_gpu_get_memory_info_ex(
    NvPhysicalGpuHandle handle, struct nvapi_gpu_memory_info_ex_v1 *memory_info)
{
    const struct nvapi_gpu_identity *identity;
    NvAPI_Status status;
    uint64_t vram_bytes;

    if (memory_info == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    if (memory_info->version != NVAPI_MEMORY_INFO_EX_VERSION_1) {
        return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
    }
    status = get_validated_identity(handle, &identity);
    if (status != NVAPI_OK) {
        return status;
    }
    vram_bytes = (uint64_t)identity->vram_kib * UINT64_C(1024);
    memset(memory_info, 0, sizeof(*memory_info));
    memory_info->version = NVAPI_MEMORY_INFO_EX_VERSION_1;
    memory_info->dedicated_video_memory_bytes = vram_bytes;
    memory_info->available_dedicated_video_memory_bytes = vram_bytes;
    memory_info->current_available_dedicated_video_memory_bytes = vram_bytes;
    return NVAPI_OK;
}
