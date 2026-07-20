#ifndef STEALTH_ADL_PUBLIC_H
#define STEALTH_ADL_PUBLIC_H

/*
 * AMD 官方 display-library 的最小 bootstrap/core 声明集。
 *
 * 这里只声明已由 AMD 公开头文件/随 SDK 发布的 API 文档确认的入口。导出符号
 * 使用默认 C ABI（x86 为 __cdecl）；唯一的 __stdcall 参数是 SDK 定义的内存
 * 回调 ADL_MAIN_MALLOC_CALLBACK，定义位于 adl_types.h。
 */
#include "adl_types.h"

int ADL_Main_Control_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                            int enum_connected_adapters);
int ADL_Main_ControlX2_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                              int enum_connected_adapters,
                              ADLThreadingModel threading_model);
int ADL_Main_Control_Refresh(void);
int ADL_Main_Control_Destroy(void);
void *ADL_Main_Control_GetProcAddress(void *module, char *procedure_name);

int ADL2_Main_Control_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                             int enum_connected_adapters,
                             ADL_CONTEXT_HANDLE *context);
int ADL2_Main_ControlX2_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                               int enum_connected_adapters,
                               ADL_CONTEXT_HANDLE *context,
                               ADLThreadingModel threading_model);
int ADL2_Main_ControlX3_Create(ADL_MAIN_MALLOC_CALLBACK callback,
                               int enum_connected_adapters,
                               ADL_CONTEXT_HANDLE *context,
                               ADLThreadingModel threading_model,
                               int create_options);
int ADL2_Main_Control_Refresh(ADL_CONTEXT_HANDLE context);
int ADL2_Main_Control_Destroy(ADL_CONTEXT_HANDLE context);
void *ADL2_Main_Control_GetProcAddress(ADL_CONTEXT_HANDLE context,
                                       void *module,
                                       char *procedure_name);

int ADL_Adapter_NumberOfAdapters_Get(int *number_of_adapters);
int ADL2_Adapter_NumberOfAdapters_Get(ADL_CONTEXT_HANDLE context,
                                      int *number_of_adapters);
int ADL_Adapter_AdapterInfo_Get(AdapterInfo *info, int input_size);
int ADL2_Adapter_AdapterInfo_Get(ADL_CONTEXT_HANDLE context,
                                 AdapterInfo *info, int input_size);
int ADL_Adapter_AdapterInfoX2_Get(AdapterInfo **adapter_info);
int ADL2_Adapter_AdapterInfoX2_Get(ADL_CONTEXT_HANDLE context,
                                   AdapterInfo **adapter_info);
int ADL2_Adapter_AdapterInfoX3_Get(ADL_CONTEXT_HANDLE context,
                                   int adapter_index, int *number_of_adapters,
                                   AdapterInfo **adapter_info);
int ADL2_Adapter_AdapterInfoX4_Get(ADL_CONTEXT_HANDLE context,
                                   int adapter_index, int *number_of_adapters,
                                   AdapterInfoX2 **adapter_info);

int ADL_Graphics_Versions_Get(ADLVersionsInfo *versions_info);
int ADL2_Graphics_Versions_Get(ADL_CONTEXT_HANDLE context,
                               ADLVersionsInfo *versions_info);
int ADL2_Graphics_VersionsX2_Get(ADL_CONTEXT_HANDLE context,
                                 ADLVersionsInfoX2 *versions_info);
int ADL2_Graphics_VersionsX3_Get(ADL_CONTEXT_HANDLE context,
                                 int adapter_index,
                                 ADLVersionsInfoX2 *versions_info);

#endif
