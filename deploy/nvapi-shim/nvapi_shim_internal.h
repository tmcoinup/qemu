#ifndef STEALTH_NVAPI_SHIM_INTERNAL_H
#define STEALTH_NVAPI_SHIM_INTERNAL_H

#include "nvapi_types.h"

NvAPI_Status nvapi_validate_gpu_handle(NvPhysicalGpuHandle handle);
NvAPI_Status nvapi_require_initialized(void);
NvPhysicalGpuHandle nvapi_physical_gpu_handle(void);

#endif
