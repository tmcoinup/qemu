/*
 * 明确拒绝没有可信底层来源的接口。
 *
 * 本分支不做 GPU 直通，注册表 profile 只证明静态身份与标称时钟；温度、功耗、
 * 风扇、VRAM 实时占用、PMLog、I2C 和任何写操作都不能从这些字段推导。返回
 * ADL_ERR_NOT_SUPPORTED 比伪造“看似正常”的遥测值更安全，也让其他检测工具
 * 能按官方 ADL 约定回退到 SetupAPI/DXGI。
 */
#include "adl_runtime.h"

static int unsupported_adapter(int adapter_index)
{
    struct adl_gpu_identity identity;
    int status = adl_runtime_adapter(NULL, 0, adapter_index, &identity);

    if (status == ADL_OK) {
        (void)identity;
        return ADL_ERR_NOT_SUPPORTED;
    }
    return status;
}

static int unsupported_context_adapter(ADL_CONTEXT_HANDLE context,
                                       int adapter_index)
{
    struct adl_gpu_identity identity;
    int status = adl_runtime_adapter(context, 1, adapter_index, &identity);

    if (status == ADL_OK) {
        (void)identity;
        return ADL_ERR_NOT_SUPPORTED;
    }
    return status;
}

int ADL_Display_WriteAndReadI2C(int adapter_index, void *i2c)
{
    (void)i2c;
    return unsupported_adapter(adapter_index);
}

int ADL_Overdrive5_FanSpeed_Get(int adapter_index,
                                int thermal_controller_index,
                                void *fan_speed)
{
    (void)thermal_controller_index;
    (void)fan_speed;
    return unsupported_adapter(adapter_index);
}

int ADL2_OverdriveN_FanControl_Get(ADL_CONTEXT_HANDLE context,
                                   int adapter_index, void *fan_control)
{
    (void)fan_control;
    return unsupported_context_adapter(context, adapter_index);
}

int ADL_Overdrive5_ODPerformanceLevels_Set(
    int adapter_index, ADLODPerformanceLevels *levels)
{
    if (levels == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    return unsupported_adapter(adapter_index);
}

int ADL_Overdrive5_PowerControlInfo_Get(int adapter_index,
                                        void *power_control_info)
{
    (void)power_control_info;
    return unsupported_adapter(adapter_index);
}

int ADL_Overdrive5_PowerControl_Get(int adapter_index, int *current_value,
                                    int *default_value)
{
    (void)current_value;
    (void)default_value;
    return unsupported_adapter(adapter_index);
}

int ADL_Overdrive5_Temperature_Get(int adapter_index,
                                   int thermal_controller_index,
                                   void *temperature)
{
    (void)thermal_controller_index;
    (void)temperature;
    return unsupported_adapter(adapter_index);
}

int ADL2_Adapter_VRAMUsage_Get(ADL_CONTEXT_HANDLE context,
                               int adapter_index, int *usage_mb)
{
    (void)usage_mb;
    return unsupported_context_adapter(context, adapter_index);
}

int ADL_PowerXpress_Config_Caps(int adapter_index, void *caps)
{
    (void)caps;
    return unsupported_adapter(adapter_index);
}

int ADL2_OverdriveN_Temperature_Get(ADL_CONTEXT_HANDLE context,
                                    int adapter_index,
                                    int temperature_type,
                                    int *temperature)
{
    (void)temperature_type;
    (void)temperature;
    return unsupported_context_adapter(context, adapter_index);
}

int ADL2_Adapter_PMLog_Support_Get(ADL_CONTEXT_HANDLE context,
                                   int adapter_index, void *support_info)
{
    (void)support_info;
    return unsupported_context_adapter(context, adapter_index);
}

int ADL2_New_QueryPMLogData_Get(ADL_CONTEXT_HANDLE context,
                                int adapter_index, void *data_output)
{
    (void)data_output;
    return unsupported_context_adapter(context, adapter_index);
}

/*
 * Desktop_Device_* 是 GPU-Z 还会探测的私有配套入口。不同驱动代际的附加参数
 * 不稳定；C 调用约定由调用方回收参数，因此这里不读取任何参数，只明确拒绝。
 */
int ADL2_Desktop_Device_Create(ADL_CONTEXT_HANDLE context, int adapter_index,
                               uint32_t *device_handle)
{
    if (device_handle == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *device_handle = 0u;
    return unsupported_context_adapter(context, adapter_index);
}

int ADL2_Desktop_Device_Destroy(ADL_CONTEXT_HANDLE context,
                                uint32_t device_handle)
{
    int count = 0;
    int status;

    (void)device_handle;
    status = adl_runtime_adapter_count(context, 1, &count);
    return status == ADL_OK ? ADL_ERR_NOT_SUPPORTED : status;
}

int ADL2_Adapter_PMLog_Start(ADL_CONTEXT_HANDLE context, int adapter_index,
                             void *start_input, void *start_output,
                             uint32_t device_handle)
{
    (void)start_input;
    (void)start_output;
    (void)device_handle;
    return unsupported_context_adapter(context, adapter_index);
}

int ADL2_Adapter_PMLog_Stop(ADL_CONTEXT_HANDLE context, int adapter_index,
                            uint32_t device_handle)
{
    (void)device_handle;
    return unsupported_context_adapter(context, adapter_index);
}

int ADL2_Overdrive8_Init_SettingX2_Get(
    ADL_CONTEXT_HANDLE context, int adapter_index, int *capabilities,
    int *number_of_features, void **setting_list)
{
    (void)capabilities;
    (void)number_of_features;
    (void)setting_list;
    return unsupported_context_adapter(context, adapter_index);
}

int ADL2_Overdrive8_Current_SettingX2_Get(
    ADL_CONTEXT_HANDLE context, int adapter_index, int *number_of_features,
    int **setting_list)
{
    (void)number_of_features;
    (void)setting_list;
    return unsupported_context_adapter(context, adapter_index);
}
