/*
 * 面向 GPU-Z/HWiNFO 的最小独立 NVAPI 投影层。
 *
 * 客体仍由 VioGpuDod 驱动真实的 1AF4:1050 virtio 显示设备；本 DLL 只把
 * HKLM\SOFTWARE\StealthGPU 中经过验证的 NVIDIA 用户态身份投影给主动查询
 * NVAPI 的程序。它不伪造温度、风扇、功耗或 CUDA，也不转发到不存在的 NVIDIA
 * 驱动 DLL。未知接口返回 NULL，让调用方明确走 WDDM/DXGI 回退路径。
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>

#include "nvapi_driver_version.h"
#include "nvapi_gpu_name.h"
#include "nvapi_gpu_type.h"
#include "nvapi_memory.h"
#include "nvapi_identity.h"
#include "nvapi_gpu_details.h"
#include "nvapi_gpu_legacy_clocks.h"
#include "nvapi_gpu_pstates.h"
#include "nvapi_shim_internal.h"
#include "nvapi_types.h"

static volatile LONG g_initialize_references;
static const uintptr_t g_gpu_handle_token = UINT32_C(0xB007C0DE);

/* 读取 LONG 的原子快照，不用普通读与 Interlocked 写形成数据竞争。 */
static LONG read_initialize_references(void)
{
    return InterlockedCompareExchange(&g_initialize_references, 0, 0);
}

/*
 * 官方 NvAPI_Initialize 是引用计数语义。CAS 循环同时避免并发丢增量和 LONG
 * 溢出；身份无效时绝不增加引用计数，从源头阻止 AMD/未知 profile 被枚举成 N 卡。
 */
static NvAPI_Status __cdecl NvAPI_Initialize(void)
{
    LONG current;

    if (!nvapi_identity_initialize()) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }

    for (;;) {
        current = read_initialize_references();
        if (current == LONG_MAX) {
            return NVAPI_ERROR;
        }
        if (InterlockedCompareExchange(&g_initialize_references,
                                       current + 1, current) == current) {
            return NVAPI_OK;
        }
    }
}

/* 每次 Unload 只释放一次引用，仍有引用时其他调用继续有效。 */
static NvAPI_Status __cdecl NvAPI_Unload(void)
{
    LONG current;

    for (;;) {
        current = read_initialize_references();
        if (current <= 0) {
            return NVAPI_API_NOT_INITIALIZED;
        }
        if (InterlockedCompareExchange(&g_initialize_references,
                                       current - 1, current) == current) {
            return NVAPI_OK;
        }
    }
}

/* NVAPI 所有短字符串的容量固定为 64 字节，不能按 256 字节错误写入。 */
static void copy_short_string(char *output, const char *text)
{
    lstrcpynA(output, text, NVAPI_SHORT_STRING_MAX);
}

static NvAPI_Status __cdecl NvAPI_GetErrorMessage(NvAPI_Status code,
                                                   char *output)
{
    const char *message;

    if (output == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }

    switch (code) {
    case NVAPI_OK:
        message = "Success";
        break;
    case NVAPI_API_NOT_INITIALIZED:
        message = "NVAPI is not initialized";
        break;
    case NVAPI_INVALID_ARGUMENT:
        message = "Invalid argument";
        break;
    case NVAPI_NVIDIA_DEVICE_NOT_FOUND:
        message = "NVIDIA device not found";
        break;
    case NVAPI_INCOMPATIBLE_STRUCT_VERSION:
        message = "Incompatible structure version";
        break;
    case NVAPI_EXPECTED_LOGICAL_GPU_HANDLE:
        message = "Expected logical GPU handle";
        break;
    case NVAPI_EXPECTED_PHYSICAL_GPU_HANDLE:
        message = "Expected physical GPU handle";
        break;
    case NVAPI_NOT_SUPPORTED:
        message = "Not supported";
        break;
    default:
        message = "Unknown NVAPI shim error";
        break;
    }
    copy_short_string(output, message);
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GetInterfaceVersionString(char *output)
{
    if (output == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    copy_short_string(output, "Stealth NVAPI registry projection 2");
    return NVAPI_OK;
}

/* 单独校验初始化状态和句柄，所有逐卡查询保持一致的失败语义。 */
NvAPI_Status nvapi_require_initialized(void)
{
    return read_initialize_references() > 0 ? NVAPI_OK :
        NVAPI_API_NOT_INITIALIZED;
}

NvPhysicalGpuHandle nvapi_physical_gpu_handle(void)
{
    return (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token;
}

NvAPI_Status nvapi_validate_gpu_handle(NvPhysicalGpuHandle handle)
{
    if (read_initialize_references() <= 0) {
        return NVAPI_API_NOT_INITIALIZED;
    }
    if (handle == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    if (handle != (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token) {
        return NVAPI_EXPECTED_PHYSICAL_GPU_HANDLE;
    }
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_EnumPhysicalGPUs(
    NvPhysicalGpuHandle handles[NVAPI_MAX_PHYSICAL_GPUS], NvU32 *count)
{
    if (handles == NULL || count == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }

    *count = 0;
    if (!nvapi_identity_initialize()) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }
    if (read_initialize_references() <= 0) {
        return NVAPI_API_NOT_INITIALIZED;
    }

    handles[0] = (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token;
    *count = 1;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_EnumTCCPhysicalGPUs(
    NvPhysicalGpuHandle handles[NVAPI_MAX_PHYSICAL_GPUS], NvU32 *count)
{
    if (handles == NULL || count == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }

    *count = 0;
    if (!nvapi_identity_initialize()) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }
    if (read_initialize_references() <= 0) {
        return NVAPI_API_NOT_INITIALIZED;
    }

    /* 消费级 GeForce 不存在 TCC 物理 GPU；数组内容在 count=0 时无效。 */
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GPU_GetFullName(NvPhysicalGpuHandle handle,
                                                   char *output)
{
    const struct nvapi_gpu_identity *identity;
    NvAPI_Status status;

    if (output == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    identity = nvapi_identity_get();
    /*
     * identity->name 继续保存并证明完整 AIB 标签。公开 NVAPI 名称只按已经
     * 验证的逻辑主 ID 投影标准芯片名，使它与 Windows 展示层保持一致。
     */
    return nvapi_copy_standard_gpu_name(identity, output);
}

static NvAPI_Status __cdecl NvAPI_GPU_GetBusId(NvPhysicalGpuHandle handle,
                                                NvU32 *bus_id)
{
    const struct nvapi_gpu_identity *identity;
    NvAPI_Status status;

    if (bus_id == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    identity = nvapi_identity_get();
    if (identity == NULL) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }
    if (!identity->has_bus_id) {
        return NVAPI_NOT_SUPPORTED;
    }
    *bus_id = identity->bus_id;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GPU_GetBusSlotId(
    NvPhysicalGpuHandle handle, NvU32 *slot_id)
{
    const struct nvapi_gpu_identity *identity;
    NvAPI_Status status;

    if (slot_id == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    identity = nvapi_identity_get();
    if (identity == NULL) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }
    if (!identity->has_slot_id) {
        return NVAPI_NOT_SUPPORTED;
    }
    *slot_id = identity->slot_id;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GPU_GetBusType(NvPhysicalGpuHandle handle,
                                                  NvU32 *bus_type)
{
    NvAPI_Status status;

    if (bus_type == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    *bus_type = NVAPI_GPU_BUS_TYPE_PCI_EXPRESS;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GPU_GetGPUType(NvPhysicalGpuHandle handle,
                                                  NvU32 *gpu_type)
{
    NvAPI_Status status;

    if (gpu_type == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    return nvapi_fill_gpu_type(gpu_type);
}

static NvAPI_Status __cdecl NvAPI_GPU_GetPCIIdentifiers(
    NvPhysicalGpuHandle handle, NvU32 *device_id, NvU32 *subsystem_id,
    NvU32 *revision_id, NvU32 *external_device_id)
{
    const struct nvapi_gpu_identity *identity;
    NvAPI_Status status;

    if (device_id == NULL || subsystem_id == NULL || revision_id == NULL ||
        external_device_id == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    identity = nvapi_identity_get();
    if (identity == NULL) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }

    /*
     * 主键保持实际 carrier 关联键，避免 WMI/PnP 与 NVAPI 被工具拆成两块卡；
     * external device、subsystem 和其它接口仍返回完整 NVIDIA 逻辑型号。
     */
    nvapi_build_carrier_pci_identifiers(identity, device_id, subsystem_id,
                                        revision_id, external_device_id);
    return NVAPI_OK;
}

static NvAPI_Status get_framebuffer_size(NvPhysicalGpuHandle handle,
                                          NvU32 *size_kib)
{
    const struct nvapi_gpu_identity *identity;
    NvAPI_Status status;

    if (size_kib == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    status = nvapi_validate_gpu_handle(handle);
    if (status != NVAPI_OK) {
        return status;
    }
    identity = nvapi_identity_get();
    if (identity == NULL) {
        return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
    }
    *size_kib = identity->vram_kib;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GPU_GetPhysicalFrameBufferSize(
    NvPhysicalGpuHandle handle, NvU32 *size_kib)
{
    return get_framebuffer_size(handle, size_kib);
}

static NvAPI_Status __cdecl NvAPI_GPU_GetVirtualFrameBufferSize(
    NvPhysicalGpuHandle handle, NvU32 *size_kib)
{
    return get_framebuffer_size(handle, size_kib);
}

static NvAPI_Status __cdecl NvAPI_SYS_GetDriverAndBranchVersion(
    NvU32 *version, char *branch)
{
    if (version == NULL || branch == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    if (read_initialize_references() <= 0) {
        return NVAPI_API_NOT_INITIALIZED;
    }
    /*
     * GPU-Z 2.70 会把查询失败误判成旧驱动并调用空的 display-handle 回退入口。
     * 生命周期验证后统一交给可宿主测试的兼容 helper，避免两个位数实现漂移。
     */
    return nvapi_fill_driver_and_branch_version(version, branch);
}

/*
 * NVAPI 公开 ABI 把函数地址作为 void* 从 QueryInterface 返回。MinGW 在 PE/COFF
 * 平台支持函数地址与该返回类型之间的转换；不使用通用变参 stub，避免 x86 栈损坏。
 */
struct shim_entry {
    NvU32 id;
    void *function;
};

static const struct shim_entry g_shim_table[] = {
    { UINT32_C(0x0150E828), NvAPI_Initialize },
    { UINT32_C(0xD22BDD7E), NvAPI_Unload },
    { UINT32_C(0x6C2D048C), NvAPI_GetErrorMessage },
    { UINT32_C(0x01053FA5), NvAPI_GetInterfaceVersionString },
    { UINT32_C(0xE5AC921F), NvAPI_EnumPhysicalGPUs },
    { UINT32_C(0xD9930B07), NvAPI_EnumTCCPhysicalGPUs },
    { UINT32_C(0xCEEE8E9F), NvAPI_GPU_GetFullName },
    { NVAPI_ID_GPU_GET_BUS_TYPE, NvAPI_GPU_GetBusType },
    { NVAPI_ID_GPU_GET_BUS_ID, NvAPI_GPU_GetBusId },
    { UINT32_C(0x2A0A350F), NvAPI_GPU_GetBusSlotId },
    { NVAPI_ID_GPU_GET_GPU_TYPE, NvAPI_GPU_GetGPUType },
    { NVAPI_ID_GPU_GET_MEMORY_INFO, nvapi_gpu_get_memory_info },
    { NVAPI_ID_GPU_GET_MEMORY_INFO_EX, nvapi_gpu_get_memory_info_ex },
    { UINT32_C(0x2DDFB66E), NvAPI_GPU_GetPCIIdentifiers },
    { UINT32_C(0x46FBEB03), NvAPI_GPU_GetPhysicalFrameBufferSize },
    { UINT32_C(0x5A04B644), NvAPI_GPU_GetVirtualFrameBufferSize },
    { UINT32_C(0x2926AAAD), NvAPI_SYS_GetDriverAndBranchVersion },
    { NVAPI_ID_GPU_GET_VBIOS_REVISION, nvapi_gpu_get_vbios_revision },
    { NVAPI_ID_GPU_GET_VBIOS_OEM_REVISION, nvapi_gpu_get_vbios_oem_revision },
    { NVAPI_ID_GPU_GET_VBIOS_VERSION_STRING,
      nvapi_gpu_get_vbios_version_string },
    { NVAPI_ID_GPU_GET_RAM_TYPE, nvapi_gpu_get_ram_type },
    { NVAPI_ID_GPU_GET_RAM_BUS_WIDTH, nvapi_gpu_get_ram_bus_width },
    { NVAPI_ID_GPU_GET_FB_WIDTH_LOCATION,
      nvapi_gpu_get_fb_width_and_location },
    { NVAPI_ID_GPU_GET_PERF_CLOCKS, nvapi_gpu_get_perf_clocks },
    { NVAPI_ID_GPU_GET_LEGACY_ALL_CLOCKS,
      nvapi_gpu_get_legacy_all_clocks },
    { NVAPI_ID_GPU_GET_PSTATES20, nvapi_gpu_get_pstates20 },
    { NVAPI_ID_GPU_GET_ALL_CLOCKS, nvapi_gpu_get_all_clock_frequencies },
    { NVAPI_ID_ENUM_LOGICAL_GPUS, nvapi_enum_logical_gpus },
    { NVAPI_ID_LOGICAL_FROM_PHYSICAL,
      nvapi_get_logical_gpu_from_physical_gpu },
    { NVAPI_ID_PHYSICAL_FROM_LOGICAL,
      nvapi_get_physical_gpus_from_logical_gpu },
    { NVAPI_ID_GPU_GET_CONNECTED_OUTPUTS, nvapi_gpu_get_connected_outputs },
    { NVAPI_ID_GPU_GET_CONNECTED_SLI_OUTPUTS,
      nvapi_gpu_get_connected_outputs },
};

__declspec(dllexport)
void *__cdecl nvapi_QueryInterface(NvU32 id)
{
    size_t index;

    for (index = 0; index < sizeof(g_shim_table) / sizeof(g_shim_table[0]);
         ++index) {
        if (g_shim_table[index].id == id) {
            return g_shim_table[index].function;
        }
    }
    return NULL;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        /* 不需要线程 attach/detach 回调，减少加载器持锁期间的工作。 */
        (void)DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}
