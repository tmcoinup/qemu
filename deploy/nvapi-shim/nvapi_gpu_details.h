#ifndef STEALTH_NVAPI_GPU_DETAILS_H
#define STEALTH_NVAPI_GPU_DETAILS_H

#include "nvapi_types.h"

NvAPI_Status __cdecl nvapi_gpu_get_vbios_revision(
    NvPhysicalGpuHandle handle, NvU32 *revision);
NvAPI_Status __cdecl nvapi_gpu_get_vbios_oem_revision(
    NvPhysicalGpuHandle handle, NvU32 *revision);
NvAPI_Status __cdecl nvapi_gpu_get_vbios_version_string(
    NvPhysicalGpuHandle handle, char *output);
NvAPI_Status __cdecl nvapi_gpu_get_ram_type(
    NvPhysicalGpuHandle handle, NvU32 *ram_type);
NvAPI_Status __cdecl nvapi_gpu_get_ram_bus_width(
    NvPhysicalGpuHandle handle, NvU32 *width_bits);
NvAPI_Status __cdecl nvapi_gpu_get_fb_width_and_location(
    NvPhysicalGpuHandle handle, NvU32 *width_bits, NvU32 *location);
NvAPI_Status __cdecl nvapi_gpu_get_all_clock_frequencies(
    NvPhysicalGpuHandle handle, struct nvapi_clock_frequencies *frequencies);
NvAPI_Status __cdecl nvapi_enum_logical_gpus(
    NvLogicalGpuHandle handles[NVAPI_MAX_LOGICAL_GPUS], NvU32 *count);
NvAPI_Status __cdecl nvapi_get_logical_gpu_from_physical_gpu(
    NvPhysicalGpuHandle physical, NvLogicalGpuHandle *logical);
NvAPI_Status __cdecl nvapi_get_physical_gpus_from_logical_gpu(
    NvLogicalGpuHandle logical,
    NvPhysicalGpuHandle physical[NVAPI_MAX_PHYSICAL_GPUS], NvU32 *count);
NvAPI_Status __cdecl nvapi_gpu_get_connected_outputs(
    NvPhysicalGpuHandle handle, NvU32 *outputs_mask);
NvAPI_Status __cdecl nvapi_gpu_get_output_type(
    NvPhysicalGpuHandle handle, NvU32 output_id, NvU32 *output_type);

#endif
