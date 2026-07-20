/*
 * Test-only x86/x64 console probe for live guest validation.  Each image loads
 * its architecture's NVAPI DLL by absolute path from the probe executable's
 * own directory, so it exercises the same app-local shim as the application.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "nvapi_profile_clocks.h"
#include "nvapi_profile_math.h"

typedef int32_t NvAPI_Status;
typedef uint32_t NvU32;
typedef void *(__cdecl *QueryInterface_t)(NvU32);
typedef NvAPI_Status (__cdecl *Initialize_t)(void);
typedef NvAPI_Status (__cdecl *EnumPhysicalGPUs_t)(void **, NvU32 *);
typedef NvAPI_Status (__cdecl *QueryU32_t)(void *, NvU32 *);
typedef NvAPI_Status (__cdecl *QueryString_t)(void *, char *);
typedef NvAPI_Status (__cdecl *QueryPCIIdentifiers_t)(
    void *, NvU32 *, NvU32 *, NvU32 *, NvU32 *);

#define NVAPI_MAX_PHYSICAL_GPUS 64u
#define NVAPI_SHORT_STRING_MAX 64u
#define NVAPI_NO_IMPLEMENTATION (-3)
#define MAKE_VERSION(type, version) \
    ((NvU32)sizeof(type) | ((NvU32)(version) << 16))

#ifdef _WIN64
# define NVAPI_DLL_NAME_A "nvapi64.dll"
# define NVAPI_DLL_NAME_W L"nvapi64.dll"
# define PROBE_ARCHITECTURE "x64"
#else
# define NVAPI_DLL_NAME_A "nvapi.dll"
# define NVAPI_DLL_NAME_W L"nvapi.dll"
# define PROBE_ARCHITECTURE "x86"
#endif

typedef struct {
    NvU32 version;
    NvU32 ClockType;
    struct {
        NvU32 present_and_reserved;
        NvU32 frequency_kHz;
    } domain[32];
} NV_GPU_CLOCK_FREQUENCIES;

typedef struct {
    NvU32 version;
    NvU32 architecture;
    NvU32 implementation;
    NvU32 revision;
} NV_GPU_ARCH_INFO;

typedef struct {
    NvU32 version;
    NvU32 external_and_reserved;
    uint64_t reserved1;
    NvU32 ray_tracing_cores;
    NvU32 tensor_cores;
    NvU32 reserved2[14];
} NV_GPU_INFO;

typedef char nvapi_clock_layout_must_be_264_bytes[
    sizeof(NV_GPU_CLOCK_FREQUENCIES) == 264u ? 1 : -1];
typedef char nvapi_arch_layout_must_be_16_bytes[
    sizeof(NV_GPU_ARCH_INFO) == 16u ? 1 : -1];
typedef char nvapi_gpu_info_layout_must_be_80_bytes[
    sizeof(NV_GPU_INFO) == 80u ? 1 : -1];

static NvAPI_Status query_u32(QueryInterface_t qi, NvU32 id, void *gpu,
                              NvU32 *value)
{
    QueryU32_t function = (QueryU32_t)qi(id);

    return function ? function(gpu, value) : NVAPI_NO_IMPLEMENTATION;
}

static NvAPI_Status query_string(QueryInterface_t qi, NvU32 id, void *gpu,
                                 char value[NVAPI_SHORT_STRING_MAX])
{
    QueryString_t function = (QueryString_t)qi(id);

    memset(value, 0, NVAPI_SHORT_STRING_MAX);
    return function ? function(gpu, value) : NVAPI_NO_IMPLEMENTATION;
}

static NvAPI_Status query_clocks(QueryInterface_t qi, void *gpu, NvU32 type,
                                 NvU32 *graphics_khz, NvU32 *memory_raw_khz)
{
    typedef NvAPI_Status (__cdecl *Function_t)(
        void *, NV_GPU_CLOCK_FREQUENCIES *);
    Function_t function = (Function_t)qi(0xDCB616C3);
    NV_GPU_CLOCK_FREQUENCIES clocks;
    NvAPI_Status rc;

    if (!function) {
        return NVAPI_NO_IMPLEMENTATION;
    }
    memset(&clocks, 0, sizeof(clocks));
    clocks.version = MAKE_VERSION(NV_GPU_CLOCK_FREQUENCIES, 3);
    clocks.ClockType = type;
    rc = function(gpu, &clocks);
    if (rc == 0) {
        *graphics_khz = clocks.domain[0].frequency_kHz;
        *memory_raw_khz = clocks.domain[4].frequency_kHz;
    }
    return rc;
}

static void print_compatibility_clocks(QueryInterface_t qi, void *gpu)
{
    typedef NvAPI_Status (__cdecl *PerfFunction_t)(void *, int32_t, void *);
    typedef NvAPI_Status (__cdecl *BufferFunction_t)(void *, void *);
    PerfFunction_t perf = (PerfFunction_t)qi(0x1EA54A3B);
    BufferFunction_t pstates20 = (BufferFunction_t)qi(0x6FF81213);
    struct nvapi_profile_perf_clocks_v1 perf_clocks;
    struct nvapi_profile_pstate20_info_v1 pstates;
    NvAPI_Status rc;

    memset(&perf_clocks, 0, sizeof(perf_clocks));
    perf_clocks.version = NVAPI_PROFILE_PERF_CLOCKS_VER1;
    rc = perf
        ? perf(gpu, -1, &perf_clocks) : NVAPI_NO_IMPLEMENTATION;
    printf("%-22s status=%d version=0x%08X levels=%u selected=%u"
           " core_cur=%u core_def=%u memory_cur=%u memory_def=%u\n",
           "GetPerfClocks", (int)rc, (unsigned int)perf_clocks.version,
           (unsigned int)perf_clocks.level_count,
           (unsigned int)perf_clocks.level,
           (unsigned int)
               perf_clocks.levels[0].clocks[0].current_frequency_khz,
           (unsigned int)
               perf_clocks.levels[0].clocks[0].default_frequency_khz,
           (unsigned int)
               perf_clocks.levels[0].clocks[1].current_frequency_khz,
           (unsigned int)
               perf_clocks.levels[0].clocks[1].default_frequency_khz);

    memset(&pstates, 0, sizeof(pstates));
    pstates.version = NVAPI_PROFILE_PSTATE20_INFO_VER1;
    rc = pstates20
        ? pstates20(gpu, &pstates) : NVAPI_NO_IMPLEMENTATION;
    printf("%-22s status=%d version=0x%08X base=%u boost=%u"
           " memory_raw=%u\n",
           "GetPstates20", (int)rc, (unsigned int)pstates.version,
           (unsigned int)
               pstates.pstates[0].clocks[0].data.range.minimum_frequency_khz,
           (unsigned int)
               pstates.pstates[0].clocks[0].data.range.maximum_frequency_khz,
           (unsigned int)
               pstates.pstates[0].clocks[1].data.single.frequency_khz);
}

static void print_u32(QueryInterface_t qi, void *gpu, const char *label,
                      NvU32 id)
{
    NvU32 value = 0;
    NvAPI_Status rc = query_u32(qi, id, gpu, &value);

    printf("%-22s status=%d value=%u (0x%08X)\n",
           label, (int)rc, (unsigned int)value, (unsigned int)value);
}

int main(void)
{
    WCHAR dll_path[MAX_PATH];
    DWORD path_length;
    WCHAR *filename = NULL;
    size_t i;
    HMODULE library;
    FARPROC proc;
    QueryInterface_t qi = NULL;
    Initialize_t initialize;
    EnumPhysicalGPUs_t enumerate;
    void *gpus[NVAPI_MAX_PHYSICAL_GPUS] = { 0 };
    NvU32 gpu_count = 0;
    NvAPI_Status rc;
    char text[NVAPI_SHORT_STRING_MAX];
    NvU32 graphics_khz = 0, memory_raw_khz = 0;
    NvU32 memory_rendered_khz, boost_khz = 0, ignored_khz = 0;
    NvU32 memory_type = 0, bus_width = 0;
    NvU32 pci_device = 0, pci_subsystem = 0, pci_revision = 0;
    NvU32 pci_external_device = 0;

    path_length = GetModuleFileNameW(NULL, dll_path, MAX_PATH);
    if (!path_length || path_length >= MAX_PATH) {
        fprintf(stderr, "cannot read probe executable path\n");
        return 2;
    }
    for (i = path_length; i > 0; --i) {
        if (dll_path[i - 1] == L'\\' || dll_path[i - 1] == L'/') {
            filename = dll_path + i;
            break;
        }
    }
    if (!filename ||
        (size_t)(filename - dll_path) +
            sizeof(NVAPI_DLL_NAME_W) / sizeof(WCHAR) > MAX_PATH) {
        fprintf(stderr, "cannot construct sibling " NVAPI_DLL_NAME_A
                " path\n");
        return 2;
    }
    memcpy(filename, NVAPI_DLL_NAME_W, sizeof(NVAPI_DLL_NAME_W));
    library = LoadLibraryW(dll_path);
    if (!library) {
        fprintf(stderr, "LoadLibraryW failed: %lu\n",
                (unsigned long)GetLastError());
        return 2;
    }
    printf("Probe                  architecture=%s app-local=%s\n",
           PROBE_ARCHITECTURE, NVAPI_DLL_NAME_A);
    proc = GetProcAddress(library, "nvapi_QueryInterface");
    memcpy(&qi, &proc, sizeof(qi));
    if (!qi) {
        fprintf(stderr, "nvapi_QueryInterface export is unavailable\n");
        FreeLibrary(library);
        return 2;
    }

    initialize = (Initialize_t)qi(0x0150E828);
    rc = initialize ? initialize() : NVAPI_NO_IMPLEMENTATION;
    printf("Initialize             status=%d\n", (int)rc);
    if (rc != 0) {
        FreeLibrary(library);
        return 1;
    }

    enumerate = (EnumPhysicalGPUs_t)qi(0xE5AC921F);
    rc = enumerate
        ? enumerate(gpus, &gpu_count) : NVAPI_NO_IMPLEMENTATION;
    printf("EnumPhysicalGPUs       status=%d count=%u\n",
           (int)rc, (unsigned int)gpu_count);
    if (rc != 0 || gpu_count != 1u) {
        FreeLibrary(library);
        return 1;
    }

    rc = query_string(qi, 0xCEEE8E9F, gpus[0], text);
    printf("%-22s status=%d value=%s\n", "Full name", (int)rc,
           rc == 0 ? text : "<unavailable>");
    rc = query_string(qi, 0xA561FD7D, gpus[0], text);
    printf("%-22s status=%d value=%s\n", "VBIOS", (int)rc,
           rc == 0 ? text : "<unavailable>");
    {
        QueryPCIIdentifiers_t identifiers =
            (QueryPCIIdentifiers_t)qi(0x2DDFB66E);

        rc = identifiers
            ? identifiers(gpus[0], &pci_device, &pci_subsystem,
                          &pci_revision, &pci_external_device)
            : NVAPI_NO_IMPLEMENTATION;
        printf("%-22s status=%d device=0x%08X subsystem=0x%08X"
               " revision=0x%02X external=0x%04X\n",
               "PCI identifiers", (int)rc, (unsigned int)pci_device,
               (unsigned int)pci_subsystem, (unsigned int)pci_revision,
               (unsigned int)pci_external_device);
    }

    print_u32(qi, gpus[0], "CUDA cores", 0xC7026A87);
    print_u32(qi, gpus[0], "Shader subpipes", 0x0BE17923);
    print_u32(qi, gpus[0], "TMU count", 0x86F05D7A);
    print_u32(qi, gpus[0], "ROP count", 0xFDC129FA);
    print_u32(qi, gpus[0], "RAM maker", 0x42AEA16A);
    rc = query_u32(qi, 0x57F7CAAC, gpus[0], &memory_type);
    printf("%-22s status=%d value=%u\n", "RAM type", (int)rc,
           (unsigned int)memory_type);
    rc = query_u32(qi, 0x7975C581, gpus[0], &bus_width);
    printf("%-22s status=%d value=%u bits\n", "RAM bus width", (int)rc,
           (unsigned int)bus_width);
    print_u32(qi, gpus[0], "NVAPI bus type", 0x1BB18724);
    print_u32(qi, gpus[0], "PCIe width", 0xD048C3B1);
    print_compatibility_clocks(qi, gpus[0]);

    rc = query_clocks(qi, gpus[0], 1u, &graphics_khz, &memory_raw_khz);
    memory_rendered_khz =
        nvapi_rendered_memory_clock_khz(memory_raw_khz);
    printf("%-22s status=%d graphics=%u.%03u MHz"
           " memory_raw=%u.%03u MHz rendered=%u.%03u MHz\n",
           "Base clocks", (int)rc,
           (unsigned int)(graphics_khz / 1000u),
           (unsigned int)(graphics_khz % 1000u),
           (unsigned int)(memory_raw_khz / 1000u),
           (unsigned int)(memory_raw_khz % 1000u),
           (unsigned int)(memory_rendered_khz / 1000u),
           (unsigned int)(memory_rendered_khz % 1000u));
    rc = query_clocks(qi, gpus[0], 2u, &boost_khz, &ignored_khz);
    printf("%-22s status=%d graphics=%u.%03u MHz\n",
           "Boost clock", (int)rc,
           (unsigned int)(boost_khz / 1000u),
           (unsigned int)(boost_khz % 1000u));
    if (memory_raw_khz && bus_width) {
        NvU32 bandwidth = nvapi_memory_bandwidth_from_raw_clock_mbps(
            memory_raw_khz, bus_width, memory_type);

        printf("%-22s raw_xfers=%u derived=%u MB/s (%u.%03u GB/s)\n",
               "Memory bandwidth",
               (unsigned int)nvapi_memory_transfers_per_raw_clock(memory_type),
               (unsigned int)bandwidth,
               (unsigned int)(bandwidth / 1000u),
               (unsigned int)(bandwidth % 1000u));
    }

    {
        typedef NvAPI_Status (__cdecl *Function_t)(
            void *, NV_GPU_ARCH_INFO *);
        Function_t function = (Function_t)qi(0xD8265D24);
        NV_GPU_ARCH_INFO info = { MAKE_VERSION(NV_GPU_ARCH_INFO, 2), 0, 0, 0 };

        rc = function ? function(gpus[0], &info) : NVAPI_NO_IMPLEMENTATION;
        printf("%-22s status=%d arch=0x%08X impl=0x%08X rev=0x%08X\n",
               "Architecture", (int)rc, (unsigned int)info.architecture,
               (unsigned int)info.implementation, (unsigned int)info.revision);
    }
    {
        typedef NvAPI_Status (__cdecl *Function_t)(void *, NV_GPU_INFO *);
        Function_t function = (Function_t)qi(0xAFD1B02C);
        NV_GPU_INFO info;

        memset(&info, 0, sizeof(info));
        info.version = MAKE_VERSION(NV_GPU_INFO, 2);
        rc = function ? function(gpus[0], &info) : NVAPI_NO_IMPLEMENTATION;
        printf("%-22s status=%d RT=%u Tensor=%u\n", "GPU info",
               (int)rc, (unsigned int)info.ray_tracing_cores,
               (unsigned int)info.tensor_cores);
    }

    FreeLibrary(library);
    return 0;
}
