/* 仅编译的 ABI 探针：函数指针赋值可在 x86/x64 上锁定官方 C 原型。 */
#include "adl_public.h"

static int (*const g_main_x2)(ADL_MAIN_MALLOC_CALLBACK, int,
                              ADLThreadingModel) = ADL_Main_ControlX2_Create;
static int (*const g_context_x3)(ADL_MAIN_MALLOC_CALLBACK, int,
                                 ADL_CONTEXT_HANDLE *, ADLThreadingModel,
                                 int) = ADL2_Main_ControlX3_Create;
static int (*const g_main_refresh)(void) = ADL_Main_Control_Refresh;
static int (*const g_context_refresh)(ADL_CONTEXT_HANDLE) =
    ADL2_Main_Control_Refresh;
static void *(*const g_main_get_proc)(void *, char *) =
    ADL_Main_Control_GetProcAddress;
static void *(*const g_context_get_proc)(ADL_CONTEXT_HANDLE, void *, char *) =
    ADL2_Main_Control_GetProcAddress;

static int (*const g_adapter_info_x2)(AdapterInfo **) =
    ADL_Adapter_AdapterInfoX2_Get;
static int (*const g_context_adapter_info_x2)(ADL_CONTEXT_HANDLE,
                                              AdapterInfo **) =
    ADL2_Adapter_AdapterInfoX2_Get;
static int (*const g_context_adapter_info_x3)(ADL_CONTEXT_HANDLE, int, int *,
                                              AdapterInfo **) =
    ADL2_Adapter_AdapterInfoX3_Get;
static int (*const g_context_adapter_info_x4)(ADL_CONTEXT_HANDLE, int, int *,
                                              AdapterInfoX2 **) =
    ADL2_Adapter_AdapterInfoX4_Get;

static int (*const g_versions)(ADLVersionsInfo *) = ADL_Graphics_Versions_Get;
static int (*const g_context_versions)(ADL_CONTEXT_HANDLE, ADLVersionsInfo *) =
    ADL2_Graphics_Versions_Get;
static int (*const g_context_versions_x2)(ADL_CONTEXT_HANDLE,
                                          ADLVersionsInfoX2 *) =
    ADL2_Graphics_VersionsX2_Get;
static int (*const g_context_versions_x3)(ADL_CONTEXT_HANDLE, int,
                                          ADLVersionsInfoX2 *) =
    ADL2_Graphics_VersionsX3_Get;

int adl_core_abi_compile_probe(void)
{
    return g_main_x2 == 0 || g_context_x3 == 0 || g_main_refresh == 0 ||
        g_context_refresh == 0 || g_main_get_proc == 0 ||
        g_context_get_proc == 0 || g_adapter_info_x2 == 0 ||
        g_context_adapter_info_x2 == 0 || g_context_adapter_info_x3 == 0 ||
        g_context_adapter_info_x4 == 0 || g_versions == 0 ||
        g_context_versions == 0 || g_context_versions_x2 == 0 ||
        g_context_versions_x3 == 0;
}
