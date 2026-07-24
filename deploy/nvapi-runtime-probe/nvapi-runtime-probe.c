/*
 * Windows NVAPI 发布后运行时探针。
 *
 * 这个程序不链接 NVAPI import library，而是从当前进程对应的 Windows 系统
 * 目录加载 DLL，再通过 nvapi_QueryInterface 获取最小枚举和 DGPU 类型链。这样可验证
 * 第三方硬件工具实际会走到的系统搜索路径、位数和 ABI，而不仅是检查文件摘要。
 *
 * x86 进程对 System32 的正常 WOW64 重定向会落到 SysWOW64；x64 进程则直接
 * 使用原生 System32。因此两份构建产物必须分别运行，不能用一份程序推断另一
 * 位数。程序只读 NVAPI 状态，不修改设备、注册表或系统文件。
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#if defined(NVAPI_PROBE_X86)
#define PROBE_ARCHITECTURE "x86"
#define PROBE_DLL_NAME L"nvapi.dll"
#elif defined(NVAPI_PROBE_X64)
#define PROBE_ARCHITECTURE "x64"
#define PROBE_DLL_NAME L"nvapi64.dll"
#else
#error "必须定义 NVAPI_PROBE_X86 或 NVAPI_PROBE_X64"
#endif

#define NVAPI_MAX_PHYSICAL_GPUS 64u
#define NVAPI_SHORT_STRING_MAX 64u

#define NVAPI_ID_INITIALIZE UINT32_C(0x0150E828)
#define NVAPI_ID_UNLOAD UINT32_C(0xD22BDD7E)
#define NVAPI_ID_ENUM_PHYSICAL_GPUS UINT32_C(0xE5AC921F)
#define NVAPI_ID_GPU_GET_FULL_NAME UINT32_C(0xCEEE8E9F)
#define NVAPI_ID_GPU_GET_PCI_IDENTIFIERS UINT32_C(0x2DDFB66E)
#define NVAPI_ID_GPU_GET_GPU_TYPE UINT32_C(0xC33BAEB1)
#define NVAPI_ID_GPU_GET_FRAMEBUFFER_SIZE UINT32_C(0x46FBEB03)
#define NVAPI_ID_GPU_GET_MEMORY_INFO UINT32_C(0x07F9B368)
#define NVAPI_ID_GPU_GET_MEMORY_INFO_EX UINT32_C(0xC0599498)
#define NVAPI_ID_SYS_GET_DRIVER_VERSION UINT32_C(0x2926AAAD)
#define NVAPI_ID_ENUM_DISPLAY_HANDLE UINT32_C(0x9ABDD40D)
#define NVAPI_ID_PHYSICAL_GPUS_FROM_DISPLAY UINT32_C(0x34EF9506)
#define NVAPI_ID_GET_DISPLAY_DRIVER_VERSION UINT32_C(0xF951A4D1)
#define NVAPI_GPU_TYPE_DGPU UINT32_C(2)
#define VIRTIO_CARRIER_PCI_ID UINT32_C(0x10501af4)
#define EXPECTED_DRIVER_VERSION UINT32_C(54633)
#define EXPECTED_DRIVER_BRANCH "r545_99"

enum probe_exit_code {
    PROBE_EXIT_OK = 0,
    PROBE_EXIT_SYSTEM_PATH = 10,
    PROBE_EXIT_LOAD_LIBRARY = 11,
    PROBE_EXIT_QUERY_EXPORT = 12,
    PROBE_EXIT_REQUIRED_INTERFACE = 13,
    PROBE_EXIT_INITIALIZE = 20,
    PROBE_EXIT_ENUMERATE = 21,
    PROBE_EXIT_GPU_COUNT = 22,
    PROBE_EXIT_PCI_IDENTIFIERS = 23,
    PROBE_EXIT_FULL_NAME = 24,
    PROBE_EXIT_GPU_TYPE = 25,
    PROBE_EXIT_DRIVER_VERSION = 26,
    PROBE_EXIT_UNLOAD = 27,
    PROBE_EXIT_FRAMEBUFFER_SIZE = 28,
    PROBE_EXIT_MEMORY_INFO = 29,
    PROBE_EXIT_MEMORY_INFO_EX = 30
};

typedef int32_t NvAPI_Status;
typedef uint32_t NvU32;
typedef void *NvPhysicalGpuHandle;

struct nvapi_memory_info_v3 {
    NvU32 version;
    NvU32 dedicated_video_memory_kib;
    NvU32 available_dedicated_video_memory_kib;
    NvU32 system_video_memory_kib;
    NvU32 shared_system_memory_kib;
    NvU32 current_available_dedicated_video_memory_kib;
    NvU32 dedicated_video_memory_evictions_size_kib;
    NvU32 dedicated_video_memory_eviction_count;
};

#pragma pack(push, 8)
struct nvapi_memory_info_ex_v1 {
    NvU32 version;
    NvU32 alignment_padding;
    uint64_t dedicated_video_memory_bytes;
    uint64_t available_dedicated_video_memory_bytes;
    uint64_t system_video_memory_bytes;
    uint64_t shared_system_memory_bytes;
    uint64_t current_available_dedicated_video_memory_bytes;
    uint64_t dedicated_video_memory_evictions_size_bytes;
    uint64_t dedicated_video_memory_eviction_count;
    uint64_t dedicated_video_memory_promotions_size_bytes;
    uint64_t dedicated_video_memory_promotion_count;
};
#pragma pack(pop)

#define NVAPI_MEMORY_INFO_V3_VERSION \
    ((NvU32)sizeof(struct nvapi_memory_info_v3) | (UINT32_C(3) << 16))
#define NVAPI_MEMORY_INFO_EX_V1_VERSION \
    ((NvU32)sizeof(struct nvapi_memory_info_ex_v1) | (UINT32_C(1) << 16))

typedef void *(__cdecl *nvapi_query_interface_fn)(NvU32 id);
typedef NvAPI_Status (__cdecl *nvapi_initialize_fn)(void);
typedef NvAPI_Status (__cdecl *nvapi_unload_fn)(void);
typedef NvAPI_Status (__cdecl *nvapi_enum_physical_gpus_fn)(
    NvPhysicalGpuHandle handles[NVAPI_MAX_PHYSICAL_GPUS], NvU32 *count);
typedef NvAPI_Status (__cdecl *nvapi_get_pci_identifiers_fn)(
    NvPhysicalGpuHandle handle, NvU32 *device_id, NvU32 *subsystem_id,
    NvU32 *revision_id, NvU32 *external_device_id);
typedef NvAPI_Status (__cdecl *nvapi_get_full_name_fn)(
    NvPhysicalGpuHandle handle, char name[NVAPI_SHORT_STRING_MAX]);
typedef NvAPI_Status (__cdecl *nvapi_get_gpu_type_fn)(
    NvPhysicalGpuHandle handle, NvU32 *gpu_type);
typedef NvAPI_Status (__cdecl *nvapi_get_driver_version_fn)(
    NvU32 *version, char branch[NVAPI_SHORT_STRING_MAX]);
typedef NvAPI_Status (__cdecl *nvapi_get_framebuffer_size_fn)(
    NvPhysicalGpuHandle handle, NvU32 *size_kib);
typedef NvAPI_Status (__cdecl *nvapi_get_memory_info_fn)(
    NvPhysicalGpuHandle handle, struct nvapi_memory_info_v3 *memory_info);
typedef NvAPI_Status (__cdecl *nvapi_get_memory_info_ex_fn)(
    NvPhysicalGpuHandle handle, struct nvapi_memory_info_ex_v1 *memory_info);

struct probe_api {
    nvapi_initialize_fn initialize;
    nvapi_unload_fn unload;
    nvapi_enum_physical_gpus_fn enumerate;
    nvapi_get_pci_identifiers_fn get_pci_identifiers;
    nvapi_get_full_name_fn get_full_name;
    nvapi_get_gpu_type_fn get_gpu_type;
    nvapi_get_driver_version_fn get_driver_version;
    nvapi_get_framebuffer_size_fn get_framebuffer_size;
    nvapi_get_memory_info_fn get_memory_info;
    nvapi_get_memory_info_ex_fn get_memory_info_ex;
};

/*
 * Win32 把 GetProcAddress 声明为 WINAPI FARPROC，而 NVAPI 的唯一导出使用
 * __cdecl。用联合保存相同代码地址，避免在 x86 上通过不兼容函数类型强转，
 * 也让 -Wcast-function-type 保持为错误。
 */
union query_export_address {
    FARPROC generic;
    nvapi_query_interface_fn query;
};

/*
 * 日志最终会被 PowerShell 重定向到 UTF-8 文本文件。先把 Windows 宽字符路径
 * 转为 UTF-8，避免 printf/wprintf 混用造成流方向不确定。
 */
static void print_wide_path(const char *key, const wchar_t *path)
{
    char utf8[MAX_PATH * 4];
    int length;

    length = WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8,
                                 (int)sizeof(utf8), NULL, NULL);
    if (length <= 0) {
        printf("%s=<wide-path-conversion-failed> win32_error=%lu\n",
               key, (unsigned long)GetLastError());
        return;
    }
    printf("%s=%s\n", key, utf8);
}

static int build_system_dll_path(wchar_t path[MAX_PATH])
{
    static const wchar_t separator[] = L"\\";
    const size_t separator_length = 1u;
    const size_t dll_name_length = wcslen(PROBE_DLL_NAME);
    UINT directory_length;

    directory_length = GetSystemDirectoryW(path, MAX_PATH);
    if (directory_length == 0u || directory_length >= MAX_PATH) {
        return 0;
    }
    if ((size_t)directory_length + separator_length + dll_name_length + 1u >
        MAX_PATH) {
        SetLastError(ERROR_INSUFFICIENT_BUFFER);
        return 0;
    }
    if (path[directory_length - 1u] != L'\\') {
        lstrcatW(path, separator);
    }
    lstrcatW(path, PROBE_DLL_NAME);
    return 1;
}

/* QueryInterface 的返回值是无类型地址；每个入口只按其公开固定 ABI 调用。 */
static int resolve_required_apis(nvapi_query_interface_fn query,
                                 struct probe_api *api)
{
    int forbidden_display_topology_present;

    api->initialize =
        (nvapi_initialize_fn)query(NVAPI_ID_INITIALIZE);
    api->unload =
        (nvapi_unload_fn)query(NVAPI_ID_UNLOAD);
    api->enumerate =
        (nvapi_enum_physical_gpus_fn)query(NVAPI_ID_ENUM_PHYSICAL_GPUS);
    api->get_pci_identifiers =
        (nvapi_get_pci_identifiers_fn)query(
            NVAPI_ID_GPU_GET_PCI_IDENTIFIERS);
    api->get_full_name =
        (nvapi_get_full_name_fn)query(NVAPI_ID_GPU_GET_FULL_NAME);
    api->get_gpu_type =
        (nvapi_get_gpu_type_fn)query(NVAPI_ID_GPU_GET_GPU_TYPE);
    api->get_driver_version =
        (nvapi_get_driver_version_fn)query(
            NVAPI_ID_SYS_GET_DRIVER_VERSION);
    api->get_framebuffer_size =
        (nvapi_get_framebuffer_size_fn)query(
            NVAPI_ID_GPU_GET_FRAMEBUFFER_SIZE);
    api->get_memory_info =
        (nvapi_get_memory_info_fn)query(NVAPI_ID_GPU_GET_MEMORY_INFO);
    api->get_memory_info_ex =
        (nvapi_get_memory_info_ex_fn)query(NVAPI_ID_GPU_GET_MEMORY_INFO_EX);
    forbidden_display_topology_present =
        query(NVAPI_ID_ENUM_DISPLAY_HANDLE) != NULL ||
        query(NVAPI_ID_PHYSICAL_GPUS_FROM_DISPLAY) != NULL ||
        query(NVAPI_ID_GET_DISPLAY_DRIVER_VERSION) != NULL;

    printf("query.initialize.present=%u\n", api->initialize != NULL);
    printf("query.enumerate.present=%u\n", api->enumerate != NULL);
    printf("query.pci_identifiers.present=%u\n",
           api->get_pci_identifiers != NULL);
    printf("query.full_name.present=%u\n", api->get_full_name != NULL);
    printf("query.gpu_type.present=%u\n", api->get_gpu_type != NULL);
    printf("query.driver_version.present=%u\n",
           api->get_driver_version != NULL);
    printf("query.framebuffer_size.present=%u\n",
           api->get_framebuffer_size != NULL);
    printf("query.memory_info.present=%u\n", api->get_memory_info != NULL);
    printf("query.memory_info_ex.present=%u\n",
           api->get_memory_info_ex != NULL);
    printf("query.forbidden_display_topology.present=%u\n",
           forbidden_display_topology_present);
    printf("query.unload.present=%u\n", api->unload != NULL);

    return api->initialize != NULL && api->enumerate != NULL &&
        api->get_pci_identifiers != NULL && api->get_full_name != NULL &&
        api->get_gpu_type != NULL && api->get_driver_version != NULL &&
        api->get_framebuffer_size != NULL && api->get_memory_info != NULL &&
        api->get_memory_info_ex != NULL &&
        api->unload != NULL && !forbidden_display_topology_present;
}

static int finish_probe(HMODULE module, const struct probe_api *api,
                        int initialized, int result)
{
    if (initialized && api->unload != NULL) {
        NvAPI_Status status = api->unload();

        printf("nvapi.unload.status=%" PRId32 "\n", status);
        if (status != 0 && result == PROBE_EXIT_OK) {
            result = PROBE_EXIT_UNLOAD;
        }
    } else {
        printf("nvapi.unload.status=not-called\n");
    }
    if (module != NULL) {
        FreeLibrary(module);
    }
    printf("probe.result=%s\n", result == PROBE_EXIT_OK ? "ok" : "failed");
    printf("probe.exit_code=%d\n", result);
    fflush(stdout);
    return result;
}

int main(void)
{
    wchar_t requested_path[MAX_PATH];
    wchar_t loaded_path[MAX_PATH];
    NvPhysicalGpuHandle handles[NVAPI_MAX_PHYSICAL_GPUS] = { 0 };
    struct probe_api api = { 0 };
    nvapi_query_interface_fn query;
    union query_export_address export_address;
    HMODULE module;
    FARPROC query_export;
    NvAPI_Status status;
    char driver_branch[NVAPI_SHORT_STRING_MAX] = { 0 };
    NvU32 driver_version = 0;
    NvU32 count = 0;
    NvU32 index;
    int result = PROBE_EXIT_OK;

    /*
     * 即使系统 DLL 损坏也只返回可解析状态，不让 Windows 弹出关键错误对话框
     * 阻塞无人值守的安装/Finalize 流程。
     */
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
    printf("probe.version=2\n");
    printf("probe.architecture=" PROBE_ARCHITECTURE "\n");

    if (!build_system_dll_path(requested_path)) {
        printf("load.win32_error=%lu\n", (unsigned long)GetLastError());
        return finish_probe(NULL, &api, 0, PROBE_EXIT_SYSTEM_PATH);
    }
    print_wide_path("load.requested_path", requested_path);

    module = LoadLibraryExW(requested_path, NULL,
                            LOAD_WITH_ALTERED_SEARCH_PATH);
    if (module == NULL) {
        printf("load.win32_error=%lu\n", (unsigned long)GetLastError());
        return finish_probe(NULL, &api, 0, PROBE_EXIT_LOAD_LIBRARY);
    }
    printf("load.win32_error=0\n");
    if (GetModuleFileNameW(module, loaded_path, MAX_PATH) != 0u) {
        loaded_path[MAX_PATH - 1u] = L'\0';
        print_wide_path("load.actual_path", loaded_path);
    } else {
        printf("load.actual_path=<unavailable> win32_error=%lu\n",
               (unsigned long)GetLastError());
    }

    query_export = GetProcAddress(module, "nvapi_QueryInterface");
    printf("query.export.present=%u\n", query_export != NULL);
    if (query_export == NULL) {
        return finish_probe(module, &api, 0, PROBE_EXIT_QUERY_EXPORT);
    }
    export_address.generic = query_export;
    query = export_address.query;
    if (!resolve_required_apis(query, &api)) {
        return finish_probe(module, &api, 0,
                            PROBE_EXIT_REQUIRED_INTERFACE);
    }

    status = api.initialize();
    printf("nvapi.initialize.status=%" PRId32 "\n", status);
    if (status != 0) {
        return finish_probe(module, &api, 0, PROBE_EXIT_INITIALIZE);
    }

    status = api.get_driver_version(&driver_version, driver_branch);
    driver_branch[NVAPI_SHORT_STRING_MAX - 1u] = '\0';
    printf("nvapi.driver_version.status=%" PRId32 "\n", status);
    printf("nvapi.driver_version.value=%" PRIu32 "\n", driver_version);
    printf("nvapi.driver_version.branch=%s\n", driver_branch);
    if (status != 0 || driver_version != EXPECTED_DRIVER_VERSION ||
        strcmp(driver_branch, EXPECTED_DRIVER_BRANCH) != 0) {
        return finish_probe(module, &api, 1,
                            PROBE_EXIT_DRIVER_VERSION);
    }

    status = api.enumerate(handles, &count);
    printf("nvapi.enumerate.status=%" PRId32 "\n", status);
    printf("nvapi.enumerate.count=%" PRIu32 "\n", count);
    if (status != 0) {
        return finish_probe(module, &api, 1, PROBE_EXIT_ENUMERATE);
    }
    if (count != 1u) {
        return finish_probe(module, &api, 1, PROBE_EXIT_GPU_COUNT);
    }

    for (index = 0; index < count; ++index) {
        NvU32 device_id = 0;
        NvU32 subsystem_id = 0;
        NvU32 revision_id = 0;
        NvU32 external_device_id = 0;
        NvU32 gpu_type = 0;
        NvU32 framebuffer_size_kib = 0;
        struct nvapi_memory_info_v3 memory_info = { 0 };
        struct nvapi_memory_info_ex_v1 memory_info_ex = { 0 };
        char name[NVAPI_SHORT_STRING_MAX] = { 0 };

        memory_info.version = NVAPI_MEMORY_INFO_V3_VERSION;
        memory_info_ex.version = NVAPI_MEMORY_INFO_EX_V1_VERSION;
        status = api.get_pci_identifiers(
            handles[index], &device_id, &subsystem_id, &revision_id,
            &external_device_id);
        printf("gpu.%" PRIu32 ".pci.status=%" PRId32 "\n", index, status);
        printf("gpu.%" PRIu32 ".pci.device_id=0x%08" PRIx32 "\n",
               index, device_id);
        printf("gpu.%" PRIu32 ".pci.subsystem_id=0x%08" PRIx32 "\n",
               index, subsystem_id);
        printf("gpu.%" PRIu32 ".pci.revision_id=0x%08" PRIx32 "\n",
               index, revision_id);
        printf("gpu.%" PRIu32 ".pci.external_device_id=0x%08" PRIx32 "\n",
               index, external_device_id);
        if ((status != 0 || device_id != VIRTIO_CARRIER_PCI_ID ||
             external_device_id == 0u) &&
            result == PROBE_EXIT_OK) {
            result = PROBE_EXIT_PCI_IDENTIFIERS;
        }

        status = api.get_full_name(handles[index], name);
        name[NVAPI_SHORT_STRING_MAX - 1u] = '\0';
        printf("gpu.%" PRIu32 ".name.status=%" PRId32 "\n", index, status);
        printf("gpu.%" PRIu32 ".name=%s\n", index, name);
        if ((status != 0 || name[0] == '\0') &&
            result == PROBE_EXIT_OK) {
            result = PROBE_EXIT_FULL_NAME;
        }

        status = api.get_gpu_type(handles[index], &gpu_type);
        printf("gpu.%" PRIu32 ".type.status=%" PRId32 "\n", index, status);
        printf("gpu.%" PRIu32 ".type.value=%" PRIu32 "\n",
               index, gpu_type);
        if ((status != 0 || gpu_type != NVAPI_GPU_TYPE_DGPU) &&
            result == PROBE_EXIT_OK) {
            result = PROBE_EXIT_GPU_TYPE;
        }

        status = api.get_framebuffer_size(
            handles[index], &framebuffer_size_kib);
        printf("gpu.%" PRIu32 ".framebuffer.status=%" PRId32 "\n",
               index, status);
        printf("gpu.%" PRIu32 ".framebuffer.kib=%" PRIu32 "\n",
               index, framebuffer_size_kib);
        if ((status != 0 || framebuffer_size_kib == 0u) &&
            result == PROBE_EXIT_OK) {
            result = PROBE_EXIT_FRAMEBUFFER_SIZE;
        }

        status = api.get_memory_info(handles[index], &memory_info);
        printf("gpu.%" PRIu32 ".memory_info.status=%" PRId32 "\n",
               index, status);
        printf("gpu.%" PRIu32 ".memory_info.dedicated_kib=%" PRIu32 "\n",
               index, memory_info.dedicated_video_memory_kib);
        if ((status != 0 ||
             memory_info.dedicated_video_memory_kib !=
                 framebuffer_size_kib ||
             memory_info.available_dedicated_video_memory_kib !=
                 framebuffer_size_kib ||
             memory_info.current_available_dedicated_video_memory_kib !=
                 framebuffer_size_kib) &&
            result == PROBE_EXIT_OK) {
            result = PROBE_EXIT_MEMORY_INFO;
        }

        status = api.get_memory_info_ex(handles[index], &memory_info_ex);
        printf("gpu.%" PRIu32 ".memory_info_ex.status=%" PRId32 "\n",
               index, status);
        printf("gpu.%" PRIu32 ".memory_info_ex.dedicated_bytes=%" PRIu64 "\n",
               index, memory_info_ex.dedicated_video_memory_bytes);
        if ((status != 0 ||
             memory_info_ex.dedicated_video_memory_bytes !=
                 (uint64_t)framebuffer_size_kib * UINT64_C(1024) ||
             memory_info_ex.available_dedicated_video_memory_bytes !=
                 memory_info_ex.dedicated_video_memory_bytes ||
             memory_info_ex.current_available_dedicated_video_memory_bytes !=
                 memory_info_ex.dedicated_video_memory_bytes) &&
            result == PROBE_EXIT_OK) {
            result = PROBE_EXIT_MEMORY_INFO_EX;
        }
    }

    return finish_probe(module, &api, 1, result);
}
