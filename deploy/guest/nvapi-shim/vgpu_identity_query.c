/*
 * Authoritative user-mode identity query for the G-11 protected projection.
 *
 * This console image must be installed beside the x86 app-local nvapi.dll and
 * nvapi_orig.dll pair.  It reports the native Windows display transport and
 * the catalog-projected board/VRAM identity as two deliberately separate
 * layers, then verifies the registry, compiled catalog, and live NVAPI view.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <initguid.h>
#include <devguid.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "vgpu_profile_catalog.h"

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
#define IDENTITY_REGISTRY_KEY \
    "SOFTWARE\\NVIDIA Corporation\\Global\\NvAPI"
#define NATIVE_TRANSPORT_PREFIX "PCI\\VEN_10DE&DEV_1E30"

typedef struct {
    const char *name;
    uint32_t expected;
} ExpectedDword;

typedef struct {
    const char *name;
    const char *expected;
} ExpectedString;

static int read_registry_dword(HKEY key, const char *name, uint32_t *value)
{
    DWORD type = 0;
    DWORD size = sizeof(*value);
    LONG rc = RegQueryValueExA(key, name, NULL, &type, (BYTE *)value, &size);

    return rc == ERROR_SUCCESS && type == REG_DWORD &&
           size == sizeof(*value);
}

static int read_registry_ascii(HKEY key, const char *name,
                               char *value, DWORD capacity)
{
    DWORD type = 0;
    DWORD size = capacity;
    DWORD i;
    LONG rc;

    if (!value || capacity < 2u) {
        return 0;
    }
    memset(value, 0, capacity);
    rc = RegQueryValueExA(key, name, NULL, &type, (BYTE *)value, &size);
    if (rc != ERROR_SUCCESS || type != REG_SZ || size < 2u ||
        size > capacity || value[size - 1u] != '\0') {
        return 0;
    }
    for (i = 0; i + 1u < size; ++i) {
        if ((unsigned char)value[i] < 0x20u ||
            (unsigned char)value[i] > 0x7eu) {
            return 0;
        }
    }
    return 1;
}

static const QemuVgpuProfileContract *find_profile(const char *key)
{
    size_t i;

    for (i = 0; i < QEMU_VGPU_PROFILE_CONTRACT_COUNT; ++i) {
        if (strcmp(qemu_vgpu_profile_contracts[i].key, key) == 0) {
            return &qemu_vgpu_profile_contracts[i];
        }
    }
    return NULL;
}

static int verify_registry(HKEY key, const QemuVgpuProfileContract *profile)
{
    char board_identity[64];
    char value[128];
    uint32_t actual;
    size_t i;
    ExpectedString strings[] = {
        { "IdentityProfileKey", profile->key },
        { "IdentityCatalogSha256", QEMU_VGPU_PROFILE_CATALOG_SHA256 },
        { "IdentityGpuName", profile->name },
        { "IdentityVbiosVersion", profile->vbios_version },
        { "IdentityBoardBrand", profile->board_brand },
        { "IdentityBoardModel", profile->board_model },
        { "IdentityMemoryTypeName", profile->memory_type_name },
        { "IdentityMemoryMakerName", profile->memory_maker_name },
        { "IdentityMemoryMakerNvapiName",
          profile->memory_maker_nvapi_name },
        { "IdentityProjectionScope", profile->identity_scope }
    };
    ExpectedDword dwords[] = {
        { "IdentityContractVersion", 2u },
        { "IdentityVramMB", profile->vram_mb },
        { "IdentityPciVendorId", profile->pci_vendor_id },
        { "IdentityPciDeviceId", profile->pci_device_id },
        { "IdentityPciSubVendorId", profile->pci_subvendor_id },
        { "IdentityPciSubDeviceId", profile->pci_subdevice_id },
        { "IdentityPciRevisionId", profile->pci_revision_id },
        { "IdentityCoreClockKHz", profile->core_clock_khz },
        { "IdentityBoostClockKHz", profile->boost_clock_khz },
        { "IdentityMemoryClockNVAPIKHz", profile->memory_raw_clock_khz },
        { "IdentityMemoryClockKHz", profile->memory_raw_clock_khz },
        { "IdentityMemoryBusBits", profile->memory_bus_bits },
        { "IdentityMemoryBandwidthMBps", profile->memory_bandwidth_mbps },
        { "IdentityMemoryType", profile->memory_type },
        { "IdentityMemoryMaker", profile->memory_maker },
        { "IdentityCudaCores", profile->cuda_cores },
        { "IdentityShaderSubPipes", profile->shader_subpipes },
        { "IdentityRopCount", profile->rop_count },
        { "IdentityTmuCount", profile->tmu_count },
        { "IdentityRayTracingCores", 0u },
        { "IdentityTensorCores", 0u },
        { "IdentityArchitecture", profile->architecture },
        { "IdentityImplementation", profile->implementation },
        { "IdentityChipRevision", profile->chip_revision },
        { "IdentityPcieWidth", profile->pcie_width }
    };

    snprintf(board_identity, sizeof(board_identity),
             "subsystem=0x%04X:0x%04X",
             (unsigned int)profile->pci_subvendor_id,
             (unsigned int)profile->pci_subdevice_id);
    for (i = 0; i < sizeof(strings) / sizeof(strings[0]); ++i) {
        if (!read_registry_ascii(key, strings[i].name, value,
                                 (DWORD)sizeof(value)) ||
            strcmp(value, strings[i].expected) != 0) {
            fprintf(stderr, "Registry mismatch: %s\n", strings[i].name);
            return 0;
        }
    }
    for (i = 0; i < sizeof(dwords) / sizeof(dwords[0]); ++i) {
        if (!read_registry_dword(key, dwords[i].name, &actual) ||
            actual != dwords[i].expected) {
            fprintf(stderr, "Registry mismatch: %s\n", dwords[i].name);
            return 0;
        }
    }
    printf("Projected profile       %s\n", profile->key);
    printf("Projected GPU           %s\n", profile->name);
    printf("Board identity          %s %s / %s\n",
           profile->board_brand, profile->board_model, board_identity);
    printf("VRAM identity           %u MB %s / %s (NVAPI %s=%u)\n",
           (unsigned int)profile->vram_mb, profile->memory_type_name,
           profile->memory_maker_name, profile->memory_maker_nvapi_name,
           (unsigned int)profile->memory_maker);
    printf("Projection scope        %s\n", profile->identity_scope);
    printf("Board serial policy     not-exposed\n");
    return 1;
}

static int query_native_transport(void)
{
    HDEVINFO devices;
    SP_DEVINFO_DATA info;
    DWORD index = 0;
    unsigned int display_count = 0;
    unsigned int native_count = 0;
    char instance_id[512];

    devices = SetupDiGetClassDevsA(&GUID_DEVCLASS_DISPLAY, NULL, NULL,
                                   DIGCF_PRESENT);
    if (devices == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "SetupDiGetClassDevsA failed: %lu\n",
                (unsigned long)GetLastError());
        return 0;
    }
    memset(&info, 0, sizeof(info));
    info.cbSize = sizeof(info);
    while (SetupDiEnumDeviceInfo(devices, index++, &info)) {
        if (SetupDiGetDeviceInstanceIdA(devices, &info, instance_id,
                                        (DWORD)sizeof(instance_id), NULL)) {
            ++display_count;
            printf("Native display PnP      %s\n", instance_id);
            if (_strnicmp(instance_id, NATIVE_TRANSPORT_PREFIX,
                         strlen(NATIVE_TRANSPORT_PREFIX)) == 0) {
                ++native_count;
            }
        }
        memset(&info, 0, sizeof(info));
        info.cbSize = sizeof(info);
    }
    if (GetLastError() != ERROR_NO_MORE_ITEMS) {
        fprintf(stderr, "SetupDiEnumDeviceInfo failed: %lu\n",
                (unsigned long)GetLastError());
        SetupDiDestroyDeviceInfoList(devices);
        return 0;
    }
    SetupDiDestroyDeviceInfoList(devices);
    printf("Native transport        displays=%u DEV_1E30=%u\n",
           display_count, native_count);
    return display_count == 1u && native_count == 1u;
}

static NvAPI_Status query_u32(QueryInterface_t qi, NvU32 id, void *gpu,
                              NvU32 *value)
{
    QueryU32_t function = (QueryU32_t)qi(id);

    return function ? function(gpu, value) : NVAPI_NO_IMPLEMENTATION;
}

static int query_nvapi(const QemuVgpuProfileContract *profile)
{
    char dll_path[MAX_PATH];
    char *filename;
    DWORD length;
    HMODULE library;
    FARPROC proc;
    QueryInterface_t qi = NULL;
    Initialize_t initialize;
    EnumPhysicalGPUs_t enumerate;
    void *gpus[NVAPI_MAX_PHYSICAL_GPUS] = { 0 };
    NvU32 count = 0;
    NvU32 value = 0;
    NvU32 device = 0, subsystem = 0, revision = 0, external = 0;
    char name[NVAPI_SHORT_STRING_MAX] = { 0 };
    NvAPI_Status rc;
    QueryString_t get_name;
    QueryPCIIdentifiers_t get_pci;
    struct {
        NvU32 id;
        NvU32 expected;
        const char *label;
    } checks[] = {
        { 0x42AEA16Au, profile->memory_maker, "RAM maker" },
        { 0x57F7CAACu, profile->memory_type, "RAM type" },
        { 0x7975C581u, profile->memory_bus_bits, "RAM bus width" },
        { 0xC7026A87u, profile->cuda_cores, "CUDA cores" },
        { 0x0BE17923u, profile->shader_subpipes, "Shader subpipes" },
        { 0xFDC129FAu, profile->rop_count, "ROP count" },
        { 0x86F05D7Au, profile->tmu_count, "TMU count" },
        { 0xD048C3B1u, profile->pcie_width, "PCIe width" }
    };
    size_t i;

    length = GetModuleFileNameA(NULL, dll_path, (DWORD)sizeof(dll_path));
    if (!length || length >= sizeof(dll_path)) {
        fprintf(stderr, "Cannot read query executable path.\n");
        return 0;
    }
    filename = strrchr(dll_path, '\\');
    if (!filename || (size_t)(filename + 1 - dll_path) +
        sizeof("nvapi.dll") > sizeof(dll_path)) {
        fprintf(stderr, "Cannot construct sibling nvapi.dll path.\n");
        return 0;
    }
    strcpy(filename + 1, "nvapi.dll");
    library = LoadLibraryA(dll_path);
    if (!library) {
        fprintf(stderr, "Cannot load protected sibling nvapi.dll: %lu\n",
                (unsigned long)GetLastError());
        return 0;
    }
    proc = GetProcAddress(library, "nvapi_QueryInterface");
    memcpy(&qi, &proc, sizeof(qi));
    initialize = qi ? (Initialize_t)qi(0x0150E828u) : NULL;
    enumerate = qi ? (EnumPhysicalGPUs_t)qi(0xE5AC921Fu) : NULL;
    rc = initialize ? initialize() : NVAPI_NO_IMPLEMENTATION;
    if (rc != 0 || !enumerate || enumerate(gpus, &count) != 0 || count != 1u) {
        fprintf(stderr, "Protected NVAPI initialization/enumeration failed.\n");
        FreeLibrary(library);
        return 0;
    }
    get_name = (QueryString_t)qi(0xCEEE8E9Fu);
    if (!get_name || get_name(gpus[0], name) != 0 ||
        strcmp(name, profile->name) != 0) {
        fprintf(stderr, "Projected NVAPI GPU name mismatch.\n");
        FreeLibrary(library);
        return 0;
    }
    get_pci = (QueryPCIIdentifiers_t)qi(0x2DDFB66Eu);
    if (!get_pci || get_pci(gpus[0], &device, &subsystem, &revision,
                            &external) != 0 ||
        device != ((profile->pci_device_id << 16) | profile->pci_vendor_id) ||
        subsystem != ((profile->pci_subdevice_id << 16) |
                      profile->pci_subvendor_id) ||
        revision != profile->pci_revision_id ||
        external != profile->pci_device_id) {
        fprintf(stderr, "Projected NVAPI PCI tuple mismatch.\n");
        FreeLibrary(library);
        return 0;
    }
    for (i = 0; i < sizeof(checks) / sizeof(checks[0]); ++i) {
        value = 0;
        rc = query_u32(qi, checks[i].id, gpus[0], &value);
        if (rc != 0 || value != checks[i].expected) {
            fprintf(stderr, "Projected NVAPI %s mismatch.\n", checks[i].label);
            FreeLibrary(library);
            return 0;
        }
    }
    printf("Projected NVAPI        name/PCI/board/VRAM fields match catalog\n");
    FreeLibrary(library);
    return 1;
}

int main(int argc, char **argv)
{
    HKEY key = NULL;
    char profile_key[128];
    const QemuVgpuProfileContract *profile;
    int native_ok;
    int registry_ok;
    int nvapi_ok;
    int pause = argc == 2 && strcmp(argv[1], "--pause") == 0;
    LONG rc;

    printf("VgpuIdentityQuery      schema=%u catalog=%s\n",
           (unsigned int)QEMU_VGPU_PROFILE_CATALOG_SCHEMA,
           QEMU_VGPU_PROFILE_CATALOG_SHA256);
    native_ok = query_native_transport();
    rc = RegOpenKeyExA(HKEY_LOCAL_MACHINE, IDENTITY_REGISTRY_KEY, 0,
                       KEY_READ | KEY_WOW64_64KEY, &key);
    if (rc != ERROR_SUCCESS ||
        !read_registry_ascii(key, "IdentityProfileKey", profile_key,
                             (DWORD)sizeof(profile_key))) {
        fprintf(stderr, "Cannot read the committed identity profile key.\n");
        if (key) {
            RegCloseKey(key);
        }
        if (pause) {
            puts("Press Enter to close...");
            (void)getchar();
        }
        return 2;
    }
    profile = find_profile(profile_key);
    if (!profile) {
        fprintf(stderr, "Registry profile is absent from compiled catalog.\n");
        RegCloseKey(key);
        if (pause) {
            puts("Press Enter to close...");
            (void)getchar();
        }
        return 1;
    }
    registry_ok = verify_registry(key, profile);
    RegCloseKey(key);
    nvapi_ok = registry_ok ? query_nvapi(profile) : 0;
    printf("\nVERIFY %s\n", native_ok && registry_ok && nvapi_ok
           ? "PASS" : "FAIL");
    if (pause) {
        puts("Press Enter to close...");
        (void)getchar();
    }
    return native_ok && registry_ok && nvapi_ok ? 0 : 1;
}
