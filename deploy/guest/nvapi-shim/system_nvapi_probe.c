/*
 * Runtime probe for the process-agnostic G-11 system NVAPI projection.
 *
 * Unlike nvapi_profile_probe.c, this image deliberately loads the matching
 * Windows system-search DLL by an absolute Known Folder path.  Keeping the
 * probe beside the installation payload therefore cannot accidentally test
 * the app-local copy.  Both x86 and x64 builds exercise the same public/private
 * query IDs used by ordinary NVAPI clients and fail unless the projected RAM
 * maker, type, bus width and GPU capability counts match the atomic profile
 * contract.  No process name or application path participates in selection.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t NvAPI_Status;
typedef uint32_t NvU32;
typedef void *(__cdecl *QueryInterface_t)(NvU32);
typedef NvAPI_Status (__cdecl *Initialize_t)(void);
typedef NvAPI_Status (__cdecl *EnumPhysicalGPUs_t)(void **, NvU32 *);
typedef NvAPI_Status (__cdecl *QueryU32_t)(void *, NvU32 *);
typedef NvAPI_Status (__cdecl *QueryString_t)(void *, char *);
typedef struct {
    NvU32 version;
    NvU32 external_and_reserved;
    uint64_t reserved1;
    NvU32 ray_tracing_cores;
    NvU32 tensor_cores;
    NvU32 reserved2[14];
} NV_GPU_INFO_V2;
typedef NvAPI_Status (__cdecl *QueryGPUInfo_t)(void *, NV_GPU_INFO_V2 *);
typedef NvAPI_Status (__cdecl *QueryPCIIdentifiers_t)(
    void *, NvU32 *, NvU32 *, NvU32 *, NvU32 *);

typedef char nvapi_gpu_info_layout_must_be_80_bytes[
    sizeof(NV_GPU_INFO_V2) == 80u ? 1 : -1];

#define NVAPI_MAKE_VERSION(type, version) \
    ((NvU32)(sizeof(type) | ((NvU32)(version) << 16)))

#define NVAPI_MAX_PHYSICAL_GPUS 64u
#define NVAPI_SHORT_STRING_MAX 64u

#ifdef _WIN64
#define PROBE_ARCH "x64"
#define NVAPI_FILE L"nvapi64.dll"
#else
#define PROBE_ARCH "x86"
#define NVAPI_FILE L"nvapi.dll"
#endif

static int parse_u32(const char *text, NvU32 *value)
{
    char *end = NULL;
    unsigned long parsed;

    if (!text || !*text || !value) {
        return 0;
    }
    parsed = strtoul(text, &end, 0);
    if (!end || *end != '\0' || parsed > UINT32_MAX) {
        return 0;
    }
    *value = (NvU32)parsed;
    return 1;
}

static int build_system_nvapi_path(WCHAR *path, DWORD capacity)
{
    UINT length;
    size_t file_chars = sizeof(NVAPI_FILE) / sizeof(NVAPI_FILE[0]);

    /*
     * Use the process-visible system directory for both builds.  A WOW64
     * process intentionally sees C:\Windows\System32 as its logical system
     * path and the WOW64 redirector resolves that to the physical SysWOW64
     * image.  GetModuleFileNameW reports the same logical System32 spelling;
     * constructing a physical SysWOW64 spelling here would therefore create
     * a false path-mismatch even though the correct x86 system DLL loaded.
     */
    length = GetSystemDirectoryW(path, capacity);
    if (!length || length >= capacity ||
        (size_t)length + 1u + file_chars > (size_t)capacity) {
        return 0;
    }
    path[length++] = L'\\';
    memcpy(path + length, NVAPI_FILE, file_chars * sizeof(WCHAR));
    return 1;
}

int main(int argc, char **argv)
{
    WCHAR dll_path[MAX_PATH];
    WCHAR loaded_path[MAX_PATH];
    HMODULE library;
    FARPROC proc;
    QueryInterface_t query_interface = NULL;
    Initialize_t initialize;
    EnumPhysicalGPUs_t enumerate;
    QueryU32_t get_maker;
    QueryU32_t get_type;
    QueryU32_t get_width;
    QueryString_t get_name;
    QueryGPUInfo_t get_gpu_info;
    QueryPCIIdentifiers_t get_pci;
    void *gpus[NVAPI_MAX_PHYSICAL_GPUS] = { 0 };
    NvU32 gpu_count = 0;
    NvU32 maker = 0, type = 0, width = 0;
    NvU32 expected_maker = 0, expected_type = 0, expected_width = 0;
    NvU32 expected_device = 0, expected_subsystem = 0;
    NvU32 expected_rt_cores = 0, expected_tensor_cores = 0;
    NvU32 device = 0, subsystem = 0, revision = 0, external = 0;
    NV_GPU_INFO_V2 gpu_info = { 0 };
    NvAPI_Status status;
    char name[NVAPI_SHORT_STRING_MAX] = { 0 };

    if (argc != 8 || !parse_u32(argv[1], &expected_maker) ||
        !parse_u32(argv[2], &expected_type) ||
        !parse_u32(argv[3], &expected_width) ||
        !parse_u32(argv[4], &expected_device) ||
        !parse_u32(argv[5], &expected_subsystem) ||
        !parse_u32(argv[6], &expected_rt_cores) ||
        !parse_u32(argv[7], &expected_tensor_cores)) {
        fprintf(stderr,
                "usage: system_nvapi_probe <maker> <type> <width>"
                " <transport-device> <profile-subsystem>"
                " <rt-cores> <tensor-cores>\n");
        return 2;
    }
    if (!build_system_nvapi_path(dll_path, MAX_PATH)) {
        fprintf(stderr, "cannot resolve the Windows system NVAPI path\n");
        return 2;
    }
    library = LoadLibraryExW(dll_path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!library) {
        fprintf(stderr, "LoadLibraryExW failed: %lu\n",
                (unsigned long)GetLastError());
        return 2;
    }
    if (!GetModuleFileNameW(library, loaded_path, MAX_PATH) ||
        _wcsicmp(dll_path, loaded_path) != 0) {
        fwprintf(stderr,
                 L"loaded NVAPI image is not the requested system path: requested=%ls loaded=%ls\n",
                 dll_path, loaded_path);
        FreeLibrary(library);
        return 2;
    }
    proc = GetProcAddress(library, "nvapi_QueryInterface");
    memcpy(&query_interface, &proc, sizeof(query_interface));
    if (!query_interface) {
        fprintf(stderr, "nvapi_QueryInterface is unavailable\n");
        FreeLibrary(library);
        return 2;
    }
    initialize = (Initialize_t)query_interface(0x0150E828u);
    enumerate = (EnumPhysicalGPUs_t)query_interface(0xE5AC921Fu);
    get_maker = (QueryU32_t)query_interface(0x42AEA16Au);
    get_type = (QueryU32_t)query_interface(0x57F7CAACu);
    get_width = (QueryU32_t)query_interface(0x7975C581u);
    get_name = (QueryString_t)query_interface(0xCEEE8E9Fu);
    get_gpu_info = (QueryGPUInfo_t)query_interface(0xAFD1B02Cu);
    get_pci = (QueryPCIIdentifiers_t)query_interface(0x2DDFB66Eu);
    if (!initialize || !enumerate || !get_maker || !get_type ||
        !get_width || !get_name || !get_gpu_info || !get_pci) {
        fprintf(stderr, "required NVAPI query interface is unavailable\n");
        FreeLibrary(library);
        return 1;
    }
    status = initialize();
    if (status != 0) {
        fprintf(stderr, "NvAPI_Initialize failed: %d\n", (int)status);
        FreeLibrary(library);
        return 1;
    }
    status = enumerate(gpus, &gpu_count);
    if (status != 0 || gpu_count != 1u) {
        fprintf(stderr, "EnumPhysicalGPUs failed: status=%d count=%u\n",
                (int)status, (unsigned int)gpu_count);
        FreeLibrary(library);
        return 1;
    }
    gpu_info.version = NVAPI_MAKE_VERSION(NV_GPU_INFO_V2, 2);
    if (get_maker(gpus[0], &maker) != 0 ||
        get_type(gpus[0], &type) != 0 ||
        get_width(gpus[0], &width) != 0 ||
        get_name(gpus[0], name) != 0 ||
        get_gpu_info(gpus[0], &gpu_info) != 0 ||
        get_pci(gpus[0], &device, &subsystem, &revision, &external) != 0) {
        fprintf(stderr, "projected NVAPI identity query failed\n");
        FreeLibrary(library);
        return 1;
    }
    if (maker != expected_maker || type != expected_type ||
        width != expected_width || device != expected_device ||
        subsystem != expected_subsystem || external != (device >> 16) ||
        gpu_info.ray_tracing_cores != expected_rt_cores ||
        gpu_info.tensor_cores != expected_tensor_cores) {
        fprintf(stderr,
                "system NVAPI mismatch: maker=%u/%u type=%u/%u width=%u/%u"
                " device=0x%08X/0x%08X subsystem=0x%08X/0x%08X"
                " external=0x%04X RT=%u/%u Tensor=%u/%u\n",
                (unsigned int)maker, (unsigned int)expected_maker,
                (unsigned int)type, (unsigned int)expected_type,
                (unsigned int)width, (unsigned int)expected_width,
                (unsigned int)device, (unsigned int)expected_device,
                (unsigned int)subsystem, (unsigned int)expected_subsystem,
                (unsigned int)external,
                (unsigned int)gpu_info.ray_tracing_cores,
                (unsigned int)expected_rt_cores,
                (unsigned int)gpu_info.tensor_cores,
                (unsigned int)expected_tensor_cores);
        FreeLibrary(library);
        return 1;
    }
    printf("SYSTEM_NVAPI_VERIFY PASS architecture=%s count=1 maker=%u type=%u"
           " width=%u device=0x%08X subsystem=0x%08X revision=0x%02X"
           " RT=%u Tensor=%u name=%s\n",
           PROBE_ARCH, (unsigned int)maker, (unsigned int)type,
           (unsigned int)width, (unsigned int)device,
           (unsigned int)subsystem, (unsigned int)revision,
           (unsigned int)gpu_info.ray_tracing_cores,
           (unsigned int)gpu_info.tensor_cores, name);
    FreeLibrary(library);
    return 0;
}
