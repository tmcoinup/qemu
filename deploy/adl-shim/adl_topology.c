#include <stddef.h>

#include "adl_runtime.h"

int ADL_Adapter_Crossfire_Caps(int adapter_index, int *preferred,
                               int *number_of_combinations,
                               ADLCrossfireComb **combinations)
{
    struct adl_gpu_identity identity;
    int status;

    if (preferred == NULL || number_of_combinations == NULL ||
        combinations == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *preferred = 0;
    *number_of_combinations = 0;
    *combinations = NULL;
    status = adl_runtime_adapter(NULL, 0, adapter_index, &identity);
    if (status == ADL_OK) {
        (void)identity;
    }
    return status;
}

int ADL_Adapter_Crossfire_Get(int adapter_index,
                              ADLCrossfireComb *combination,
                              ADLCrossfireInfo *info)
{
    struct adl_gpu_identity identity;
    int status = adl_runtime_adapter(NULL, 0, adapter_index, &identity);

    if (status != ADL_OK) {
        return status;
    }
    (void)identity;
    (void)combination;
    (void)info;
    return ADL_ERR_NOT_SUPPORTED;
}
