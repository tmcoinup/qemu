#include "adl_init_policy.h"

int adl_init_threading_model_status(ADLThreadingModel threading_model)
{
    if (threading_model == ADL_THREADING_UNLOCKED) {
        return ADL_OK;
    }
    if (threading_model == ADL_THREADING_LOCKED) {
        return ADL_ERR_NOT_SUPPORTED;
    }
    return ADL_ERR_INVALID_PARAM;
}

int adl_init_create_options_status(int create_options)
{
    return (create_options & ~ADL_CREATE_OPTIONS_SUPPORTED_MASK) == 0 ?
        ADL_OK : ADL_ERR_NOT_SUPPORTED;
}
