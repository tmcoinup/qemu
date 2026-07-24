#include <stddef.h>
#include <string.h>

#include "gpu_model_catalog.h"
#include "nvapi_gpu_name.h"

NvAPI_Status nvapi_copy_standard_gpu_name(
    const struct nvapi_gpu_identity *identity,
    char output[NVAPI_SHORT_STRING_MAX])
{
    const char *standard_name;
    size_t length;

    if (output == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    output[0] = '\0';
    if (identity == NULL) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }
    standard_name = stealth_gpu_standard_model_name(
        identity->pci_vendor_id, identity->pci_device_id);
    if (standard_name == NULL) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }
    length = strlen(standard_name);
    if (length >= NVAPI_SHORT_STRING_MAX) {
        return NVAPI_ERROR;
    }
    memcpy(output, standard_name, length + 1u);
    return NVAPI_OK;
}
