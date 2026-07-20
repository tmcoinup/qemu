#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdint.h>
#include <string.h>

#include "adl_core_internal.h"
#include "adl_init_policy.h"
#include "adl_public.h"
#include "adl_runtime.h"

static void *control_get_proc_address(ADL_CONTEXT_HANDLE context,
                                      int require_context, void *module,
                                      char *procedure_name)
{
    if (module == NULL || procedure_name == NULL || procedure_name[0] == '\0' ||
        adl_runtime_query_validate(context, require_context) != ADL_OK) {
        return NULL;
    }
    return (void *)(uintptr_t)GetProcAddress((HMODULE)module, procedure_name);
}

int ADL_Main_ControlX2_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                              int enum_connected_adapters,
                              ADLThreadingModel threading_model)
{
    int status;

    (void)enum_connected_adapters;
    status = adl_init_threading_model_status(threading_model);
    if (status != ADL_OK) {
        return status;
    }
    return adl_runtime_main_create(callback);
}

int ADL2_Main_ControlX3_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                               int enum_connected_adapters,
                               ADL_CONTEXT_HANDLE *context,
                               ADLThreadingModel threading_model,
                               int create_options)
{
    int status;

    (void)enum_connected_adapters;
    status = adl_init_threading_model_status(threading_model);
    if (status != ADL_OK) {
        return status;
    }
    status = adl_init_create_options_status(create_options);
    if (status != ADL_OK) {
        return status;
    }
    return adl_runtime_context_create(callback, context);
}

int ADL_Main_Control_Refresh(void)
{
    return adl_runtime_refresh(NULL, 0);
}

int ADL2_Main_Control_Refresh(ADL_CONTEXT_HANDLE context)
{
    return adl_runtime_refresh(context, 1);
}

void *ADL_Main_Control_GetProcAddress(void *module, char *procedure_name)
{
    return control_get_proc_address(NULL, 0, module, procedure_name);
}

void *ADL2_Main_Control_GetProcAddress(ADL_CONTEXT_HANDLE context,
                                       void *module, char *procedure_name)
{
    return control_get_proc_address(context, 1, module, procedure_name);
}

static int adapter_info_list_get(ADL_CONTEXT_HANDLE context,
                                 int require_context, int adapter_index,
                                 int *number_of_adapters,
                                 AdapterInfo **adapter_info)
{
    AdapterInfo prepared_info;
    struct adl_gpu_identity identity;
    void *allocation = NULL;
    int count = 0;
    int status;

    if (adapter_info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *adapter_info = NULL;
    if (number_of_adapters != NULL) {
        *number_of_adapters = 0;
    }
    if (adapter_index < -1 || (adapter_index == -1 &&
                               number_of_adapters == NULL)) {
        return ADL_ERR_INVALID_PARAM;
    }
    status = adl_runtime_adapter_count(context, require_context, &count);
    if (status != ADL_OK) {
        return status;
    }
    if (adapter_index != -1 && (adapter_index != 0 || count != 1)) {
        return ADL_ERR_INVALID_ADL_IDX;
    }
    if (adapter_index == -1 && number_of_adapters != NULL) {
        *number_of_adapters = count;
    }
    if (count == 0) {
        return ADL_OK;
    }
    status = adl_runtime_adapter(context, require_context, 0, &identity);
    if (status != ADL_OK ||
        !adl_core_build_adapter_info(&identity, &prepared_info)) {
        return status == ADL_OK ? ADL_ERR : status;
    }
    status = adl_runtime_allocate(context, require_context,
                                  (int)sizeof(**adapter_info), &allocation);
    if (status != ADL_OK) {
        return status;
    }
    memcpy(allocation, &prepared_info, sizeof(prepared_info));
    *adapter_info = (AdapterInfo *)allocation;
    return ADL_OK;
}

static int adapter_info_x2_list_get(ADL_CONTEXT_HANDLE context,
                                    int adapter_index,
                                    int *number_of_adapters,
                                    AdapterInfoX2 **adapter_info)
{
    AdapterInfo base_info;
    struct adl_gpu_identity identity;
    void *allocation = NULL;
    int count = 0;
    int status;

    if (adapter_info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *adapter_info = NULL;
    if (number_of_adapters != NULL) {
        *number_of_adapters = 0;
    }
    if (adapter_index < -1 || (adapter_index == -1 &&
                               number_of_adapters == NULL)) {
        return ADL_ERR_INVALID_PARAM;
    }
    status = adl_runtime_adapter_count(context, 1, &count);
    if (status != ADL_OK) {
        return status;
    }
    if (adapter_index != -1 && (adapter_index != 0 || count != 1)) {
        return ADL_ERR_INVALID_ADL_IDX;
    }
    if (adapter_index == -1 && number_of_adapters != NULL) {
        *number_of_adapters = count;
    }
    if (count == 0) {
        return ADL_OK;
    }
    status = adl_runtime_adapter(context, 1, 0, &identity);
    if (status != ADL_OK ||
        !adl_core_build_adapter_info(&identity, &base_info)) {
        return status == ADL_OK ? ADL_ERR : status;
    }
    status = adl_runtime_allocate(context, 1, (int)sizeof(**adapter_info),
                                  &allocation);
    if (status != ADL_OK) {
        return status;
    }
    memset(allocation, 0, sizeof(AdapterInfoX2));
    memcpy(allocation, &base_info, sizeof(base_info));
    ((AdapterInfoX2 *)allocation)->iSize = (int)sizeof(AdapterInfoX2);
    *adapter_info = (AdapterInfoX2 *)allocation;
    return ADL_OK;
}

int ADL_Adapter_AdapterInfoX2_Get(AdapterInfo **adapter_info)
{
    int count = 0;

    return adapter_info_list_get(NULL, 0, -1, &count, adapter_info);
}

int ADL2_Adapter_AdapterInfoX2_Get(ADL_CONTEXT_HANDLE context,
                                   AdapterInfo **adapter_info)
{
    int count = 0;

    return adapter_info_list_get(context, 1, -1, &count, adapter_info);
}

int ADL2_Adapter_AdapterInfoX3_Get(ADL_CONTEXT_HANDLE context,
                                   int adapter_index, int *number_of_adapters,
                                   AdapterInfo **adapter_info)
{
    return adapter_info_list_get(context, 1, adapter_index,
                                 number_of_adapters, adapter_info) == ADL_OK;
}

int ADL2_Adapter_AdapterInfoX4_Get(ADL_CONTEXT_HANDLE context,
                                   int adapter_index, int *number_of_adapters,
                                   AdapterInfoX2 **adapter_info)
{
    return adapter_info_x2_list_get(context, adapter_index,
                                    number_of_adapters, adapter_info) == ADL_OK;
}

static int versions_get(ADL_CONTEXT_HANDLE context, int require_context,
                        void *versions_info, size_t size)
{
    int count = 0;
    int status;

    if (versions_info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    memset(versions_info, 0, size);
    status = adl_runtime_adapter_count(context, require_context, &count);
    if (status != ADL_OK) {
        return status;
    }
    /* 身份快照没有可信 AMD 驱动版本字段，绝不伪造 driver/catalyst 字符串。 */
    return ADL_ERR_NOT_SUPPORTED;
}

int ADL_Graphics_Versions_Get(ADLVersionsInfo *versions_info)
{
    return versions_get(NULL, 0, versions_info, sizeof(*versions_info));
}

int ADL2_Graphics_Versions_Get(ADL_CONTEXT_HANDLE context,
                               ADLVersionsInfo *versions_info)
{
    return versions_get(context, 1, versions_info, sizeof(*versions_info));
}

int ADL2_Graphics_VersionsX2_Get(ADL_CONTEXT_HANDLE context,
                                 ADLVersionsInfoX2 *versions_info)
{
    return versions_get(context, 1, versions_info, sizeof(*versions_info));
}

int ADL2_Graphics_VersionsX3_Get(ADL_CONTEXT_HANDLE context,
                                 int adapter_index,
                                 ADLVersionsInfoX2 *versions_info)
{
    struct adl_gpu_identity identity;
    int status;

    if (versions_info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    memset(versions_info, 0, sizeof(*versions_info));
    status = adl_runtime_adapter(context, 1, adapter_index, &identity);
    if (status != ADL_OK) {
        return status;
    }
    (void)identity;
    return ADL_ERR_NOT_SUPPORTED;
}
