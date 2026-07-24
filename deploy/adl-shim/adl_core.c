#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "adl_core_internal.h"
#include "adl_init_policy.h"
#include "adl_profile.h"
#include "adl_public.h"
#include "adl_runtime.h"
#include "gpu_model_catalog.h"

static int copy_string(char *output, size_t capacity, const char *source)
{
    size_t length;

    if (output == NULL || source == NULL || capacity == 0u) {
        return 0;
    }
    length = strlen(source);
    if (length >= capacity) {
        return 0;
    }
    memcpy(output, source, length + 1u);
    return 1;
}

int adl_core_build_adapter_info(const struct adl_gpu_identity *identity,
                                AdapterInfo *info)
{
    const char *standard_name;

    if (info == NULL) {
        return 0;
    }
    memset(info, 0, sizeof(*info));
    if (identity == NULL) {
        return 0;
    }
    /*
     * identity->name 保留完整 AIB 标签参与缓存和合同校验；AdapterInfo 对外只
     * 返回由已验证逻辑主 ID 决定的标准芯片名。
     */
    standard_name = stealth_gpu_standard_model_name(
        identity->pci_vendor_id, identity->pci_device_id);
    if (standard_name == NULL) {
        return 0;
    }
    info->iSize = (int)sizeof(*info);
    info->iAdapterIndex = 0;
    /* BDF 来自已由 CM 返回并与 snapshot 逐项比对的唯一 virtio devnode。 */
    info->iBusNumber = (int)identity->carrier.bus_id;
    info->iDeviceNumber = (int)identity->carrier.slot_id;
    info->iFunctionNumber = (int)identity->carrier.function_id;
    /*
     * AdapterInfo.iVendorID 是 AMD 历史 ABI 的十进制厂商常量 1002。PNP、
     * UDID 和 Driver 字段则必须保留 Windows 已枚举的承载设备，避免检测器
     * 把 ADL 逻辑型号和同一块 virtio Display 设备拆成两张卡。
     */
    info->iVendorID = ADL_VENDOR_ID_AMD;
    info->iPresent = 1;
    info->iExist = 1;
    info->iOSDisplayIndex = 0;

    return copy_string(info->strUDID, sizeof(info->strUDID),
                       identity->carrier.instance_id) &&
        copy_string(info->strPNPString, sizeof(info->strPNPString),
                    identity->carrier.hardware_id) &&
        copy_string(info->strDriverPath, sizeof(info->strDriverPath),
                    identity->carrier.driver_registry_path) &&
        copy_string(info->strDriverPathExt, sizeof(info->strDriverPathExt),
                    identity->carrier.driver_key) &&
        copy_string(info->strAdapterName, sizeof(info->strAdapterName),
                    standard_name) &&
        copy_string(info->strDisplayName, sizeof(info->strDisplayName),
                    "\\\\.\\DISPLAY1");
}

static int adapter_info_get(ADL_CONTEXT_HANDLE context, int require_context,
                            AdapterInfo *info, int input_size)
{
    struct adl_gpu_identity identity;
    int count = 0;
    int status;

    if (info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = adl_runtime_adapter_count(context, require_context, &count);
    if (status != ADL_OK || count == 0) {
        return status;
    }
    if (input_size < (int)sizeof(*info)) {
        return ADL_ERR_INVALID_PARAM_SIZE;
    }
    status = adl_runtime_adapter(context, require_context, 0, &identity);
    if (status != ADL_OK) {
        return status;
    }
    return adl_core_build_adapter_info(&identity, info) ? ADL_OK : ADL_ERR;
}

int ADL_Main_Control_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                            int enum_connected_adapters)
{
    (void)enum_connected_adapters;
    return adl_runtime_main_create(callback);
}

int ADL_Main_Control_Destroy(void)
{
    return adl_runtime_main_destroy();
}

int ADL2_Main_Control_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                             int enum_connected_adapters,
                             ADL_CONTEXT_HANDLE *context)
{
    (void)enum_connected_adapters;
    return adl_runtime_context_create(callback, context);
}

int ADL2_Main_ControlX2_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                               int enum_connected_adapters,
                               ADL_CONTEXT_HANDLE *context,
                               ADLThreadingModel threading_model)
{
    int status;

    (void)enum_connected_adapters;
    status = adl_init_threading_model_status(threading_model);
    if (status != ADL_OK) {
        return status;
    }
    return adl_runtime_context_create(callback, context);
}

int ADL2_Main_Control_Destroy(ADL_CONTEXT_HANDLE context)
{
    return adl_runtime_context_destroy(context);
}

int ADL_Adapter_NumberOfAdapters_Get(int *number_of_adapters)
{
    return adl_runtime_adapter_count(NULL, 0, number_of_adapters);
}

int ADL2_Adapter_NumberOfAdapters_Get(ADL_CONTEXT_HANDLE context,
                                      int *number_of_adapters)
{
    return adl_runtime_adapter_count(context, 1, number_of_adapters);
}

int ADL_Adapter_AdapterInfo_Get(AdapterInfo *info, int input_size)
{
    return adapter_info_get(NULL, 0, info, input_size);
}

int ADL2_Adapter_AdapterInfo_Get(ADL_CONTEXT_HANDLE context,
                                 AdapterInfo *info, int input_size)
{
    return adapter_info_get(context, 1, info, input_size);
}

static int adapter_flag_get(ADL_CONTEXT_HANDLE context, int require_context,
                            int adapter_index, int *flag)
{
    struct adl_gpu_identity identity;
    int status;

    if (flag == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *flag = 0;
    status = adl_runtime_adapter(context, require_context, adapter_index,
                                 &identity);
    if (status == ADL_OK) {
        (void)identity;
        *flag = 1;
    }
    return status;
}

int ADL_Adapter_Active_Get(int adapter_index, int *status)
{
    return adapter_flag_get(NULL, 0, adapter_index, status);
}

int ADL2_Adapter_Active_Get(ADL_CONTEXT_HANDLE context, int adapter_index,
                            int *status)
{
    return adapter_flag_get(context, 1, adapter_index, status);
}

int ADL_Adapter_Accessibility_Get(int adapter_index, int *accessible)
{
    return adapter_flag_get(NULL, 0, adapter_index, accessible);
}

int ADL2_Adapter_Accessibility_Get(ADL_CONTEXT_HANDLE context,
                                   int adapter_index, int *accessible)
{
    return adapter_flag_get(context, 1, adapter_index, accessible);
}

static int memory_info_get(ADL_CONTEXT_HANDLE context, int require_context,
                           int adapter_index, ADLMemoryInfo *info)
{
    struct adl_gpu_identity identity;
    int status;

    if (info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = adl_runtime_adapter(context, require_context, adapter_index,
                                 &identity);
    if (status != ADL_OK) {
        return status;
    }
    memset(info, 0, sizeof(*info));
    info->iMemorySize = (int64_t)identity.ram_mb * 1024 * 1024;
    info->iMemoryBandwidth = adl_profile_memory_bandwidth_mb(&identity);
    return copy_string(info->strMemoryType, sizeof(info->strMemoryType),
                       "GDDR5") ? ADL_OK : ADL_ERR;
}

static int memory_info2_get(ADL_CONTEXT_HANDLE context, int require_context,
                            int adapter_index, ADLMemoryInfo2 *info)
{
    ADLMemoryInfo base;
    int status;

    if (info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = memory_info_get(context, require_context, adapter_index, &base);
    if (status != ADL_OK) {
        return status;
    }
    memset(info, 0, sizeof(*info));
    info->iMemorySize = base.iMemorySize;
    info->iMemoryBandwidth = base.iMemoryBandwidth;
    info->iVisibleMemorySize = base.iMemorySize;
    return copy_string(info->strMemoryType, sizeof(info->strMemoryType),
                       base.strMemoryType) ? ADL_OK : ADL_ERR;
}

static int memory_info3_get(ADL_CONTEXT_HANDLE context, int require_context,
                            int adapter_index, ADLMemoryInfo3 *info)
{
    ADLMemoryInfo2 base;
    int status;

    if (info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = memory_info2_get(context, require_context, adapter_index, &base);
    if (status != ADL_OK) {
        return status;
    }
    memset(info, 0, sizeof(*info));
    info->iMemorySize = base.iMemorySize;
    info->iMemoryBandwidth = base.iMemoryBandwidth;
    info->iVisibleMemorySize = base.iVisibleMemorySize;
    return copy_string(info->strMemoryType, sizeof(info->strMemoryType),
                       base.strMemoryType) ? ADL_OK : ADL_ERR;
}

int ADL_Adapter_MemoryInfo_Get(int adapter_index, ADLMemoryInfo *info)
{
    return memory_info_get(NULL, 0, adapter_index, info);
}

int ADL_Adapter_MemoryInfo2_Get(int adapter_index, ADLMemoryInfo2 *info)
{
    return memory_info2_get(NULL, 0, adapter_index, info);
}

int ADL_Adapter_MemoryInfo3_Get(int adapter_index, ADLMemoryInfo3 *info)
{
    return memory_info3_get(NULL, 0, adapter_index, info);
}

int ADL2_Adapter_MemoryInfo2_Get(ADL_CONTEXT_HANDLE context,
                                 int adapter_index, ADLMemoryInfo2 *info)
{
    return memory_info2_get(context, 1, adapter_index, info);
}

int ADL2_Adapter_MemoryInfo3_Get(ADL_CONTEXT_HANDLE context,
                                 int adapter_index, ADLMemoryInfo3 *info)
{
    return memory_info3_get(context, 1, adapter_index, info);
}

int ADL2_Adapter_Graphic_Core_Info_Get(ADL_CONTEXT_HANDLE context,
                                       int adapter_index,
                                       ADLGraphicCoreInfo *info)
{
    struct adl_gpu_identity identity;
    int status;

    if (info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = adl_runtime_adapter(context, 1, adapter_index, &identity);
    if (status != ADL_OK) {
        return status;
    }
    memset(info, 0, sizeof(*info));
    info->iGCGen = ADL_GRAPHIC_CORE_GENERATION_GCN;
    info->core_count.iNumCUs = (int)identity.compute_units;
    info->pe_count.iNumPEsPerCU =
        (int)identity.processing_elements_per_cu;
    info->iNumROPs = (int)identity.rops;
    return ADL_OK;
}

static int video_bios_get(ADL_CONTEXT_HANDLE context, int require_context,
                          int adapter_index, ADLBiosInfo *info)
{
    struct adl_gpu_identity identity;
    int status;

    if (info == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    status = adl_runtime_adapter(context, require_context, adapter_index,
                                 &identity);
    if (status != ADL_OK) {
        return status;
    }
    memset(info, 0, sizeof(*info));
    return copy_string(info->strVersion, sizeof(info->strVersion),
                       identity.bios) ? ADL_OK : ADL_ERR;
}

int ADL_Adapter_VideoBiosInfo_Get(int adapter_index, ADLBiosInfo *info)
{
    return video_bios_get(NULL, 0, adapter_index, info);
}

int ADL2_Adapter_VideoBiosInfo_Get(ADL_CONTEXT_HANDLE context,
                                   int adapter_index, ADLBiosInfo *info)
{
    return video_bios_get(context, 1, adapter_index, info);
}

static int adapter_id_get(ADL_CONTEXT_HANDLE context, int require_context,
                          int adapter_index, int *adapter_id)
{
    struct adl_gpu_identity identity;
    int status;

    if (adapter_id == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *adapter_id = 0;
    status = adl_runtime_adapter(context, require_context, adapter_index,
                                 &identity);
    if (status == ADL_OK) {
        *adapter_id = (int)((identity.pci_device_id << 16) |
                            identity.pci_vendor_id);
    }
    return status;
}

int ADL_Adapter_ID_Get(int adapter_index, int *adapter_id)
{
    return adapter_id_get(NULL, 0, adapter_index, adapter_id);
}

int ADL2_Adapter_ID_Get(ADL_CONTEXT_HANDLE context, int adapter_index,
                        int *adapter_id)
{
    return adapter_id_get(context, 1, adapter_index, adapter_id);
}

static int primary_get(ADL_CONTEXT_HANDLE context, int require_context,
                       int *primary_index)
{
    struct adl_gpu_identity identity;
    int status;

    if (primary_index == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *primary_index = -1;
    status = adl_runtime_adapter(context, require_context, 0, &identity);
    if (status == ADL_OK) {
        (void)identity;
        *primary_index = 0;
    }
    return status;
}

int ADL_Adapter_Primary_Get(int *primary_index)
{
    return primary_get(NULL, 0, primary_index);
}

int ADL2_Adapter_Primary_Get(ADL_CONTEXT_HANDLE context, int *primary_index)
{
    return primary_get(context, 1, primary_index);
}

static int asic_family_get(ADL_CONTEXT_HANDLE context, int require_context,
                           int adapter_index, int *asic_types, int *valids)
{
    struct adl_gpu_identity identity;
    int status;

    if (asic_types == NULL || valids == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *asic_types = 0;
    *valids = 0;
    status = adl_runtime_adapter(context, require_context, adapter_index,
                                 &identity);
    if (status == ADL_OK) {
        (void)identity;
        *asic_types = ADL_ASIC_DISCRETE;
        *valids = ADL_ASIC_DISCRETE;
    }
    return status;
}

int ADL_Adapter_ASICFamilyType_Get(int adapter_index, int *asic_types,
                                   int *valids)
{
    return asic_family_get(NULL, 0, adapter_index, asic_types, valids);
}

int ADL2_Adapter_ASICFamilyType_Get(ADL_CONTEXT_HANDLE context,
                                    int adapter_index, int *asic_types,
                                    int *valids)
{
    return asic_family_get(context, 1, adapter_index, asic_types, valids);
}
