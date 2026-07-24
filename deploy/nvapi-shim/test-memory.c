#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "nvapi_identity.h"
#include "nvapi_memory.h"

static struct nvapi_gpu_identity g_identity;
static NvPhysicalGpuHandle g_handle =
    (NvPhysicalGpuHandle)(uintptr_t)UINT32_C(0x1234);

NvAPI_Status nvapi_validate_gpu_handle(NvPhysicalGpuHandle handle)
{
    return handle == g_handle ? NVAPI_OK :
        NVAPI_EXPECTED_PHYSICAL_GPU_HANDLE;
}

const struct nvapi_gpu_identity *nvapi_identity_get(void)
{
    return &g_identity;
}

static int expect_legacy_version(NvU32 version)
{
    struct nvapi_display_driver_memory_info_v3 info;
    NvAPI_Status status;

    memset(&info, 0xa5, sizeof(info));
    info.v2.v1.version = version;
    status = nvapi_gpu_get_memory_info(g_handle, &info);
    if (status != NVAPI_OK ||
        info.v2.v1.dedicated_video_memory_kib != UINT32_C(4194304) ||
        info.v2.v1.available_dedicated_video_memory_kib !=
            UINT32_C(4194304)) {
        return 0;
    }
    if (version != NVAPI_MEMORY_INFO_VERSION_1 &&
        info.v2.current_available_dedicated_video_memory_kib !=
            UINT32_C(4194304)) {
        return 0;
    }
    return 1;
}

int main(void)
{
    struct nvapi_display_driver_memory_info_v1 bad;
    struct nvapi_gpu_memory_info_ex_v1 extended;

    if (NVAPI_ID_GPU_GET_MEMORY_INFO != UINT32_C(0x07F9B368) ||
        NVAPI_ID_GPU_GET_MEMORY_INFO_EX != UINT32_C(0xC0599498)) {
        fputs("MemoryInfo QueryInterface ID 契约失败\n", stderr);
        return 1;
    }
    memset(&g_identity, 0, sizeof(g_identity));
    g_identity.vram_kib = UINT32_C(4194304);
    if (!expect_legacy_version(NVAPI_MEMORY_INFO_VERSION_1) ||
        !expect_legacy_version(NVAPI_MEMORY_INFO_VERSION_2) ||
        !expect_legacy_version(NVAPI_MEMORY_INFO_VERSION_3)) {
        fputs("legacy MemoryInfo KiB 契约失败\n", stderr);
        return 1;
    }
    memset(&extended, 0, sizeof(extended));
    extended.version = NVAPI_MEMORY_INFO_EX_VERSION_1;
    if (nvapi_gpu_get_memory_info_ex(g_handle, &extended) != NVAPI_OK ||
        extended.dedicated_video_memory_bytes != UINT64_C(4294967296) ||
        extended.available_dedicated_video_memory_bytes !=
            UINT64_C(4294967296) ||
        extended.current_available_dedicated_video_memory_bytes !=
            UINT64_C(4294967296)) {
        fputs("MemoryInfoEx bytes 契约失败\n", stderr);
        return 1;
    }
    memset(&bad, 0, sizeof(bad));
    bad.version = UINT32_C(0x00010018);
    if (nvapi_gpu_get_memory_info(g_handle, &bad) !=
            NVAPI_INCOMPATIBLE_STRUCT_VERSION ||
        nvapi_gpu_get_memory_info(NULL, &bad) !=
            NVAPI_INCOMPATIBLE_STRUCT_VERSION ||
        nvapi_gpu_get_memory_info(g_handle, NULL) != NVAPI_INVALID_ARGUMENT) {
        fputs("MemoryInfo 错误路径契约失败\n", stderr);
        return 1;
    }
    extended.version = UINT32_C(0x00010048);
    if (nvapi_gpu_get_memory_info_ex(g_handle, &extended) !=
            NVAPI_INCOMPATIBLE_STRUCT_VERSION ||
        nvapi_gpu_get_memory_info_ex(g_handle, NULL) != NVAPI_INVALID_ARGUMENT) {
        fputs("MemoryInfoEx 错误路径契约失败\n", stderr);
        return 1;
    }
    puts("PASS: NVAPI legacy KiB / modern bytes memory ABI");
    return 0;
}
