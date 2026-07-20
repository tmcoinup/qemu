#ifndef STEALTH_ADL_RUNTIME_H
#define STEALTH_ADL_RUNTIME_H

#include "adl_identity.h"
#include "adl_types.h"

int adl_runtime_main_create(ADL_MAIN_MALLOC_CALLBACK callback);
int adl_runtime_main_destroy(void);
int adl_runtime_context_create(ADL_MAIN_MALLOC_CALLBACK callback,
                               ADL_CONTEXT_HANDLE *context);
int adl_runtime_context_destroy(ADL_CONTEXT_HANDLE context);
int adl_runtime_query_validate(ADL_CONTEXT_HANDLE context, int require_context);
int adl_runtime_refresh(ADL_CONTEXT_HANDLE context, int require_context);
int adl_runtime_allocate(ADL_CONTEXT_HANDLE context, int require_context,
                         int size, void **allocation);
int adl_runtime_adapter_count(ADL_CONTEXT_HANDLE context,
                              int require_context, int *count);
int adl_runtime_adapter(ADL_CONTEXT_HANDLE context, int require_context,
                        int adapter_index,
                        struct adl_gpu_identity *identity);

#endif
