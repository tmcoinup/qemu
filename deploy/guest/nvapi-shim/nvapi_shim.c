/*
 * nvapi_shim.c — process-agnostic NVAPI forwarding layer between any NVAPI
 * caller and the real NVIDIA nvapi64.dll. Intercepts a small whitelist of
 * ABI-verified NVAPI function IDs whose real return values
 * leak the physical RTX 2080 hardware and rewrites successful results to match
 * the per-VM identity stored under NVIDIA's registry tree.  Overrides remain
 * disabled unless that tree contains one complete, committed and internally
 * coherent identity contract; incomplete/legacy state is forwarded unchanged.
 *
 * How NVAPI dispatch works:
 *   - nvapi_QueryInterface(uint32_t id) returns a function pointer for the
 *     requested function id
 *   - nvapi_Direct_GetMethod(int32_t method) is forwarded unchanged
 *   - All further NVAPI calls go through that pointer
 *
 * We intercept QueryInterface for a small whitelist and forward everything
 * else to the original DLL.  Both public exports and their original ordinals
 * are retained for compatibility with NVIDIA Control Panel and other clients.
 *
 * Build (from host, cross-compiler):
 *   x86_64-w64-mingw32-gcc -shared -O2 -o nvapi64.dll nvapi_shim.c \
 *       -Wl,--out-implib,libnvapi64.a -static -lkernel32 \
 *       -Wl,--subsystem,windows
 *
 * Install in guest:
 *   The G-11 system projection coordinator installs both architectures from
 *   one VM-bound, hash-verified package and retains the original NVIDIA DLLs
 *   as forwarding targets.  Selection is based only on the atomic profile
 *   contract, never on a caller executable name.
 *
 * See README.md beside this source for the registry contract, ABI evidence,
 * query-interface tracing, and the remaining GPU-Z limitations.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "nvapi_profile_clocks.h"
#include "nvapi_profile_math.h"
#include "vgpu_profile_catalog.h"

typedef int32_t NvAPI_Status;          /* NVAPI_OK = 0 */
typedef uint32_t NvU32;
typedef void*   (*QueryInterface_t)(NvU32 id);
typedef void*   (__cdecl *DirectGetMethod_t)(int32_t method);

#define NVAPI_OK                         0
#define NVAPI_NO_IMPLEMENTATION         -3
#define NVAPI_INVALID_ARGUMENT          -5
#define NVAPI_NOT_SUPPORTED           -104

static HMODULE            g_self_module = NULL;
static HMODULE            g_real_nvapi = NULL;
static QueryInterface_t   g_real_QI    = NULL;
static DirectGetMethod_t  g_real_direct = NULL;
static INIT_ONCE          g_real_init_once = INIT_ONCE_STATIC_INIT;

#define NVAPI_GPU_BUS_TYPE_PCI_EXPRESS 3u
#define IDENTITY_CONTRACT_VERSION      2u

/*
 * Per-VM values written beneath NVIDIA's 64-bit NvAPI registry key.  These
 * zero-initialized values are never exposed until g_identity_contract_valid
 * is committed at the end of the one-time reader.
 */
static NvU32 g_core_clock_kHz;
static NvU32 g_boost_clock_kHz;
static NvU32 g_mem_raw_clock_kHz;
static NvU32 g_mem_bus_width_bits;
static NvU32 g_mem_bandwidth_mbps;
static NvU32 g_memory_type;
static NvU32 g_memory_maker;
static NvU32 g_cuda_cores;
static NvU32 g_shader_subpipes;
static NvU32 g_rop_count;
static NvU32 g_tmu_count;
static NvU32 g_architecture;
static NvU32 g_implementation;
static NvU32 g_chip_revision;
static NvU32 g_pcie_width;
static NvU32 g_pci_vendor_id;
static NvU32 g_pci_device_id;
static NvU32 g_pci_subvendor_id;
static NvU32 g_pci_subdevice_id;
static NvU32 g_pci_revision_id;
static NvU32 g_vram_mb;
static BOOL  g_identity_pci_valid;
static BOOL  g_identity_contract_valid;
static NvU32 g_ray_tracing_cores;
static NvU32 g_tensor_cores;
static NvU32 g_trace_query_interface;

#define NVAPI_SHORT_STRING_MAX 64
static char  g_identity_gpu_name[NVAPI_SHORT_STRING_MAX];
static BOOL  g_identity_gpu_name_valid;
static char  g_identity_vbios_version[NVAPI_SHORT_STRING_MAX];
static BOOL  g_identity_vbios_version_valid;
static char  g_identity_profile_key[NVAPI_SHORT_STRING_MAX];
static char  g_identity_catalog_sha256[65];
static char  g_identity_board_brand[NVAPI_SHORT_STRING_MAX];
static char  g_identity_board_model[NVAPI_SHORT_STRING_MAX];
static char  g_identity_memory_type_name[NVAPI_SHORT_STRING_MAX];
static char  g_identity_memory_maker_name[NVAPI_SHORT_STRING_MAX];
static char  g_identity_memory_maker_nvapi_name[NVAPI_SHORT_STRING_MAX];
static char  g_identity_scope[NVAPI_SHORT_STRING_MAX];
static char  g_identity_pci_projection_mode[NVAPI_SHORT_STRING_MAX];
static BOOL  g_identity_preserve_transport_device;
static INIT_ONCE g_identity_init_once = INIT_ONCE_STATIC_INIT;

static BOOL read_identity_dword(HKEY key, const char *name, NvU32 *value,
                                NvU32 minimum, NvU32 maximum)
{
    DWORD type = 0, size = sizeof(*value), candidate = 0;

    if (RegQueryValueExA(key, name, NULL, &type, (BYTE *)&candidate, &size)
            == ERROR_SUCCESS && type == REG_DWORD && size == sizeof(candidate)
            && candidate >= minimum && candidate <= maximum) {
        *value = candidate;
        return TRUE;
    }
    return FALSE;
}

static BOOL read_identity_ascii(HKEY key, const char *name, char *destination,
                                DWORD destination_size)
{
    char candidate[128] = { 0 };
    DWORD type = 0, size = sizeof(candidate);
    size_t i;

    if (RegQueryValueExA(key, name, NULL, &type,
            (BYTE *)candidate, &size) != ERROR_SUCCESS || type != REG_SZ ||
            size < 2 || size > sizeof(candidate) || size > destination_size ||
            candidate[size - 1] != '\0') {
        return FALSE;
    }
    /* Reject embedded NULs and non-printable/non-ASCII bytes.  This makes an
     * oversized or malformed registry value fall back to the real name rather
     * than silently truncating it in NvAPI_ShortString (char[64]). */
    for (i = 0; i + 1 < size; i++) {
        unsigned char ch = (unsigned char)candidate[i];
        if (ch < 0x20 || ch > 0x7e) {
            return FALSE;
        }
    }
    memcpy(destination, candidate, size);
    return TRUE;
}

static BOOL is_hex_ascii(char value)
{
    return (value >= '0' && value <= '9') ||
           (value >= 'A' && value <= 'F') ||
           (value >= 'a' && value <= 'f');
}

static BOOL is_valid_vbios_version(const char *value)
{
    size_t index;

    if (!value || strlen(value) != 14u) {
        return FALSE;
    }
    for (index = 0; index < 14u; ++index) {
        if (index == 2u || index == 5u || index == 8u || index == 11u) {
            if (value[index] != '.') {
                return FALSE;
            }
        } else if (!is_hex_ascii(value[index])) {
            return FALSE;
        }
    }
    return TRUE;
}

static BOOL is_valid_catalog_sha256(const char *value)
{
    size_t index;

    if (!value || strlen(value) != 64u) {
        return FALSE;
    }
    for (index = 0; index < 64u; ++index) {
        if (!((value[index] >= '0' && value[index] <= '9') ||
              (value[index] >= 'A' && value[index] <= 'F'))) {
            return FALSE;
        }
    }
    return TRUE;
}

static BOOL is_valid_pcie_width(NvU32 width)
{
    return width == 1u || width == 2u || width == 4u || width == 8u ||
           width == 16u || width == 32u;
}

static BOOL is_valid_vram_mb(NvU32 vram_mb)
{
    return vram_mb == 1024u || vram_mb == 2048u;
}

static BOOL profile_contract_matches_registry(const char *profile_key)
{
    size_t index;

    if (!profile_key ||
        strcmp(g_identity_catalog_sha256,
               QEMU_VGPU_PROFILE_CATALOG_SHA256) != 0) {
        return FALSE;
    }
    for (index = 0; index < QEMU_VGPU_PROFILE_CONTRACT_COUNT; ++index) {
        const QemuVgpuProfileContract *contract =
            &qemu_vgpu_profile_contracts[index];

        if (strcmp(profile_key, contract->key) == 0 &&
            strcmp(g_identity_gpu_name, contract->name) == 0 &&
            strcmp(g_identity_board_brand, contract->board_brand) == 0 &&
            strcmp(g_identity_board_model, contract->board_model) == 0 &&
            strcmp(g_identity_memory_type_name,
                   contract->memory_type_name) == 0 &&
            strcmp(g_identity_memory_maker_name,
                   contract->memory_maker_name) == 0 &&
            strcmp(g_identity_memory_maker_nvapi_name,
                   contract->memory_maker_nvapi_name) == 0 &&
            strcmp(g_identity_scope, contract->identity_scope) == 0 &&
            strcmp(g_identity_vbios_version, contract->vbios_version) == 0 &&
            g_pci_vendor_id == contract->pci_vendor_id &&
            g_pci_device_id == contract->pci_device_id &&
            g_pci_subvendor_id == contract->pci_subvendor_id &&
            g_pci_subdevice_id == contract->pci_subdevice_id &&
            g_pci_revision_id == contract->pci_revision_id &&
            g_vram_mb == contract->vram_mb &&
            g_core_clock_kHz == contract->core_clock_khz &&
            g_boost_clock_kHz == contract->boost_clock_khz &&
            g_mem_raw_clock_kHz == contract->memory_raw_clock_khz &&
            g_mem_bus_width_bits == contract->memory_bus_bits &&
            g_mem_bandwidth_mbps == contract->memory_bandwidth_mbps &&
            g_memory_type == contract->memory_type &&
            g_memory_maker == contract->memory_maker &&
            g_cuda_cores == contract->cuda_cores &&
            g_shader_subpipes == contract->shader_subpipes &&
            g_rop_count == contract->rop_count &&
            g_tmu_count == contract->tmu_count &&
            g_architecture == contract->architecture &&
            g_implementation == contract->implementation &&
            g_chip_revision == contract->chip_revision &&
            g_pcie_width == contract->pcie_width &&
            g_ray_tracing_cores == contract->ray_tracing_cores &&
            g_tensor_cores == contract->tensor_cores) {
            return TRUE;
        }
    }
    return FALSE;
}

static BOOL identity_values_are_coherent(NvU32 legacy_mem_raw_clock_kHz,
                                         NvU32 vram_mb)
{
    NvU32 derived_bandwidth;
    uint64_t difference;

    if (!is_valid_vram_mb(vram_mb) || g_vram_mb != vram_mb ||
        g_boost_clock_kHz < g_core_clock_kHz ||
        legacy_mem_raw_clock_kHz != g_mem_raw_clock_kHz ||
        g_memory_type != NVAPI_RAM_TYPE_GDDR5 ||
        g_tmu_count != g_shader_subpipes * 8u ||
        !is_valid_pcie_width(g_pcie_width) ||
        g_ray_tracing_cores != 0u || g_tensor_cores != 0u ||
        !g_identity_gpu_name_valid ||
        strncmp(g_identity_gpu_name, "NVIDIA GeForce ", 15u) != 0 ||
        !g_identity_vbios_version_valid ||
        !is_valid_vbios_version(g_identity_vbios_version)) {
        return FALSE;
    }
    derived_bandwidth = nvapi_memory_bandwidth_from_raw_clock_mbps(
        g_mem_raw_clock_kHz, g_mem_bus_width_bits, g_memory_type);
    if (!derived_bandwidth) {
        return FALSE;
    }
    difference = derived_bandwidth > g_mem_bandwidth_mbps
        ? (uint64_t)derived_bandwidth - g_mem_bandwidth_mbps
        : (uint64_t)g_mem_bandwidth_mbps - derived_bandwidth;
    return difference * 100u <= g_mem_bandwidth_mbps;
}

static BOOL CALLBACK load_identity_once(PINIT_ONCE once, PVOID parameter,
                                         PVOID *context)
{
    HKEY key;
    NvU32 contract_version = 0;
    NvU32 final_contract_version = 0;
    NvU32 legacy_mem_raw_clock_kHz = 0;
    NvU32 vram_mb = 0;
    char final_profile_key[NVAPI_SHORT_STRING_MAX] = { 0 };
    char final_catalog_sha256[65] = { 0 };
    BOOL complete = TRUE;

    (void)once;
    (void)parameter;
    (void)context;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE,
            "SOFTWARE\\NVIDIA Corporation\\Global\\NvAPI", 0,
            KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key) != ERROR_SUCCESS) {
        return TRUE;
    }

#define REQUIRE_DWORD(name, destination, minimum, maximum)                 \
    do {                                                                   \
        if (!read_identity_dword(key, name, destination, minimum, maximum)) \
            complete = FALSE;                                              \
    } while (0)
#define REQUIRE_ASCII(name, destination, valid_flag)                       \
    do {                                                                  \
        valid_flag = read_identity_ascii(                                 \
            key, name, destination, (DWORD)sizeof(destination));           \
        if (!valid_flag)                                                   \
            complete = FALSE;                                              \
    } while (0)
#define REQUIRE_ASCII_VALUE(name, destination)                             \
    do {                                                                  \
        if (!read_identity_ascii(                                         \
                key, name, destination, (DWORD)sizeof(destination)))       \
            complete = FALSE;                                              \
    } while (0)

    REQUIRE_DWORD("IdentityContractVersion", &contract_version,
                  IDENTITY_CONTRACT_VERSION, IDENTITY_CONTRACT_VERSION);
    if (!read_identity_ascii(key, "IdentityProfileKey",
            g_identity_profile_key, sizeof(g_identity_profile_key))) {
        complete = FALSE;
    }
    REQUIRE_ASCII_VALUE("IdentityCatalogSha256", g_identity_catalog_sha256);
    REQUIRE_ASCII_VALUE("IdentityBoardBrand", g_identity_board_brand);
    REQUIRE_ASCII_VALUE("IdentityBoardModel", g_identity_board_model);
    REQUIRE_ASCII_VALUE("IdentityMemoryTypeName", g_identity_memory_type_name);
    REQUIRE_ASCII_VALUE("IdentityMemoryMakerName", g_identity_memory_maker_name);
    REQUIRE_ASCII_VALUE("IdentityMemoryMakerNvapiName",
                        g_identity_memory_maker_nvapi_name);
    REQUIRE_ASCII_VALUE("IdentityProjectionScope", g_identity_scope);
    REQUIRE_ASCII_VALUE("IdentityPciProjectionMode",
                        g_identity_pci_projection_mode);
    REQUIRE_ASCII("IdentityGpuName", g_identity_gpu_name,
                  g_identity_gpu_name_valid);
    REQUIRE_ASCII("IdentityVbiosVersion", g_identity_vbios_version,
                  g_identity_vbios_version_valid);
    REQUIRE_DWORD("IdentityVramMB", &g_vram_mb, 1024u, 2048u);
    if (!is_valid_vram_mb(g_vram_mb)) {
        complete = FALSE;
    }
    vram_mb = g_vram_mb;
    REQUIRE_DWORD("IdentityPciVendorId", &g_pci_vendor_id, 1u, 0xffffu);
    REQUIRE_DWORD("IdentityPciDeviceId", &g_pci_device_id, 1u, 0xffffu);
    REQUIRE_DWORD("IdentityPciSubVendorId", &g_pci_subvendor_id,
                  1u, 0xffffu);
    REQUIRE_DWORD("IdentityPciSubDeviceId", &g_pci_subdevice_id,
                  1u, 0xffffu);
    REQUIRE_DWORD("IdentityPciRevisionId", &g_pci_revision_id, 0u, 0xffu);
    REQUIRE_DWORD("IdentityCoreClockKHz", &g_core_clock_kHz,
                  1000u, 100000000u);
    REQUIRE_DWORD("IdentityBoostClockKHz", &g_boost_clock_kHz,
                  1000u, 100000000u);
    REQUIRE_DWORD("IdentityMemoryClockNVAPIKHz", &g_mem_raw_clock_kHz,
                  1000u, 200000000u);
    REQUIRE_DWORD("IdentityMemoryClockKHz", &legacy_mem_raw_clock_kHz,
                  1000u, 200000000u);
    REQUIRE_DWORD("IdentityMemoryBusBits", &g_mem_bus_width_bits,
                  1u, 8192u);
    REQUIRE_DWORD("IdentityMemoryBandwidthMBps", &g_mem_bandwidth_mbps,
                  1u, 10000000u);
    REQUIRE_DWORD("IdentityMemoryType", &g_memory_type,
                  NVAPI_RAM_TYPE_GDDR5, NVAPI_RAM_TYPE_GDDR5);
    REQUIRE_DWORD("IdentityMemoryMaker", &g_memory_maker, 1u, 10u);
    REQUIRE_DWORD("IdentityCudaCores", &g_cuda_cores, 1u, 1000000u);
    REQUIRE_DWORD("IdentityShaderSubPipes", &g_shader_subpipes,
                  1u, 100000u);
    REQUIRE_DWORD("IdentityRopCount", &g_rop_count, 1u, 100000u);
    REQUIRE_DWORD("IdentityTmuCount", &g_tmu_count, 1u, 1000000u);
    REQUIRE_DWORD("IdentityArchitecture", &g_architecture, 1u, UINT32_MAX);
    REQUIRE_DWORD("IdentityImplementation", &g_implementation,
                  1u, UINT32_MAX);
    REQUIRE_DWORD("IdentityChipRevision", &g_chip_revision, 0u, UINT32_MAX);
    REQUIRE_DWORD("IdentityPcieWidth", &g_pcie_width, 1u, 32u);
    REQUIRE_DWORD("IdentityRayTracingCores", &g_ray_tracing_cores, 0u, 0u);
    REQUIRE_DWORD("IdentityTensorCores", &g_tensor_cores, 0u, 0u);

    /* The writer removes the marker before changing any field and commits it
     * last.  Re-read the marker and key after the data snapshot so a
     * concurrent incomplete writer cannot enable a partial contract. */
    REQUIRE_DWORD("IdentityContractVersion", &final_contract_version,
                  IDENTITY_CONTRACT_VERSION, IDENTITY_CONTRACT_VERSION);
    if (!read_identity_ascii(key, "IdentityProfileKey", final_profile_key,
            sizeof(final_profile_key))) {
        complete = FALSE;
    }
    if (!read_identity_ascii(key, "IdentityCatalogSha256",
            final_catalog_sha256, sizeof(final_catalog_sha256))) {
        complete = FALSE;
    }
    (void)read_identity_dword(
        key, "IdentityTraceQueryInterface", &g_trace_query_interface, 0u, 1u);

#undef REQUIRE_ASCII
#undef REQUIRE_ASCII_VALUE
#undef REQUIRE_DWORD

    RegCloseKey(key);
    g_identity_pci_valid =
        profile_contract_matches_registry(g_identity_profile_key);
    if (strcmp(g_identity_pci_projection_mode, "profile-tuple") == 0) {
        g_identity_preserve_transport_device = FALSE;
    } else if (strcmp(g_identity_pci_projection_mode,
                      "transport-device-profile-subsystem") == 0) {
        g_identity_preserve_transport_device = TRUE;
    } else {
        complete = FALSE;
    }
    if (complete &&
        contract_version == IDENTITY_CONTRACT_VERSION &&
        final_contract_version == IDENTITY_CONTRACT_VERSION &&
        strcmp(g_identity_profile_key, final_profile_key) == 0 &&
        strcmp(g_identity_catalog_sha256, final_catalog_sha256) == 0 &&
        is_valid_catalog_sha256(g_identity_catalog_sha256) &&
        g_identity_pci_valid &&
        identity_values_are_coherent(legacy_mem_raw_clock_kHz, vram_mb)) {
        g_identity_contract_valid = TRUE;
    }
    return TRUE;
}

static void load_identity_spec(void)
{
    InitOnceExecuteOnce(&g_identity_init_once, load_identity_once, NULL, NULL);
}

/* -------- NVAPI struct shapes we need to know about -------- */

/* NV_GPU_CLOCK_FREQUENCIES v2/v3 (id = 0xDCB616C3):
 *   uint32 version               // high 16 bits = version, low 16 = size
 *   uint32 ClockType             // low 4 bits: current/base/boost
 *   struct {
 *     uint32 bIsPresent : 1;
 *     uint32 reserved  : 31;
 *     uint32 frequency_kHz;
 *   } domain[NVAPI_MAX_GPU_PUBLIC_CLOCKS = 32];
 */
#define NVAPI_MAX_GPU_PUBLIC_CLOCKS 32
typedef struct {
    NvU32 version;
    NvU32 ClockType;
    struct {
        NvU32 present_and_reserved;   /* bit0 = present */
        NvU32 frequency_kHz;
    } domain[NVAPI_MAX_GPU_PUBLIC_CLOCKS];
} NV_GPU_CLOCK_FREQUENCIES_V2;

/* Clock domain enum (partial) */
#define NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS 0
#define NVAPI_GPU_PUBLIC_CLOCK_MEMORY   4

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
} NV_GPU_INFO_V2;

typedef char nvapi_clock_layout_must_be_264_bytes[
    sizeof(NV_GPU_CLOCK_FREQUENCIES_V2) == 264u ? 1 : -1];
typedef char nvapi_arch_layout_must_be_16_bytes[
    sizeof(NV_GPU_ARCH_INFO) == 16u ? 1 : -1];
typedef char nvapi_gpu_info_layout_must_be_80_bytes[
    sizeof(NV_GPU_INFO_V2) == 80u ? 1 : -1];

/* ------- override functions that the app will call ------- */

typedef NvAPI_Status (__cdecl *QueryU32_t)(void *, NvU32 *);
typedef NvAPI_Status (__cdecl *QueryString_t)(void *, char *);
typedef NvAPI_Status (__cdecl *QueryClocks_t)(
    void *, NV_GPU_CLOCK_FREQUENCIES_V2 *);
typedef NvAPI_Status (__cdecl *QueryBuffer_t)(void *, void *);
#ifndef _WIN64
typedef NvAPI_Status (__cdecl *QueryPerfClocks_t)(
    void *, int32_t, void *);
#endif
typedef NvAPI_Status (__cdecl *QueryFBWidth_t)(
    void *, NvU32 *, NvU32 *);
typedef NvAPI_Status (__cdecl *QueryArchInfo_t)(
    void *, NV_GPU_ARCH_INFO *);
typedef NvAPI_Status (__cdecl *QueryGPUInfo_t)(
    void *, NV_GPU_INFO_V2 *);
typedef NvAPI_Status (__cdecl *QueryPCIIdentifiers_t)(
    void *, NvU32 *, NvU32 *, NvU32 *, NvU32 *);

/*
 * A valid vGPU handle can report NVAPI_NOT_SUPPORTED for static attributes
 * which are nevertheless present in the synchronized identity profile.  It is
 * safe to synthesize those simple outputs after the real DLL has performed its
 * argument/handle checks.  All other failures remain untouched.
 */
static BOOL status_allows_profile_override(NvAPI_Status rc)
{
    if (rc != NVAPI_OK && rc != NVAPI_NOT_SUPPORTED) {
        return FALSE;
    }
    load_identity_spec();
    return g_identity_contract_valid;
}

static NvAPI_Status call_real_u32(NvU32 id, void *hPhysicalGpu, NvU32 *value)
{
    QueryU32_t real = g_real_QI ? (QueryU32_t)g_real_QI(id) : NULL;

    return real ? real(hPhysicalGpu, value) : NVAPI_NO_IMPLEMENTATION;
}

static NvAPI_Status override_u32_result(NvAPI_Status rc, NvU32 *destination,
                                        const NvU32 *profile_value)
{
    if (!status_allows_profile_override(rc) || !destination) {
        return rc;
    }
    *destination = *profile_value;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl
hook_GetAllClockFrequencies(void *hPhysicalGpu, NV_GPU_CLOCK_FREQUENCIES_V2 *pClk)
{
    QueryClocks_t real = g_real_QI
        ? (QueryClocks_t)g_real_QI(0xDCB616C3) : NULL;
    NvAPI_Status rc = real
        ? real(hPhysicalGpu, pClk) : NVAPI_NO_IMPLEMENTATION;
    size_t minimum_size;
    NvU32 core_kHz;

    if (!status_allows_profile_override(rc) || !pClk) {
        return rc;
    }
    minimum_size = offsetof(NV_GPU_CLOCK_FREQUENCIES_V2, domain[4]) +
                   sizeof(pClk->domain[4]);
    if ((pClk->version & 0xffffu) < minimum_size) {
        return rc;
    }
    /* ClockType: 0 = current, 1 = base, 2 = boost. */
    core_kHz = ((pClk->ClockType & 0xfu) == 2u)
        ? g_boost_clock_kHz : g_core_clock_kHz;

    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].present_and_reserved |= 1u;
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].frequency_kHz = core_kHz;
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].present_and_reserved |= 1u;
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].frequency_kHz =
        g_mem_raw_clock_kHz;
    return NVAPI_OK;
}

/*
 * GPU-Z 2.70 uses private GetPerfClocks in addition to the current public
 * clock API above.  Its helper accepts only the V1 layout proven against the
 * complete local NVIDIA 538.33 x86 handler.  GetPstates20 uses NVIDIA's public
 * layouts.
 *
 * Always enter the original function first so it performs its own handle and
 * argument validation.  A valid vGPU may return NOT_SUPPORTED for the static
 * clock table; only that result (or OK) is eligible for a profile override.
 */
#ifndef _WIN64
static BOOL process_uses_gpuz_clock_contract(void)
{
    WCHAR path[MAX_PATH];
    WCHAR *filename = path;
    DWORD length;
    WCHAR *cursor;

    length = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (!length || length >= MAX_PATH) {
        return FALSE;
    }
    for (cursor = path; *cursor; cursor++) {
        if (*cursor == L'\\' || *cursor == L'/') {
            filename = cursor + 1;
        }
    }
    return CompareStringOrdinal(
               filename, -1, L"GPU-Z.exe", -1, TRUE) == CSTR_EQUAL ||
           CompareStringOrdinal(
               filename, -1, L"nvapi_profile_probe32.exe", -1, TRUE)
               == CSTR_EQUAL ||
           CompareStringOrdinal(
               filename, -1, L"nvapi_profile_probe64.exe", -1, TRUE)
               == CSTR_EQUAL;
}

static NvAPI_Status __cdecl
hook_GetPerfClocks(void *hPhysicalGpu, int32_t selector, void *information)
{
    QueryPerfClocks_t real = g_real_QI
        ? (QueryPerfClocks_t)g_real_QI(0x1EA54A3B) : NULL;
    NvAPI_Status rc = real
        ? real(hPhysicalGpu, selector, information) : NVAPI_NO_IMPLEMENTATION;

    if (!status_allows_profile_override(rc) || !information ||
        !process_uses_gpuz_clock_contract()) {
        return rc;
    }
    if (!nvapi_profile_fill_perf_clocks(
            information, selector, g_core_clock_kHz, g_boost_clock_kHz,
            g_mem_raw_clock_kHz)) {
        return rc;
    }
    return NVAPI_OK;
}
#endif

static NvAPI_Status __cdecl
hook_GetPstates20(void *hPhysicalGpu, void *information)
{
    QueryBuffer_t real = g_real_QI
        ? (QueryBuffer_t)g_real_QI(0x6FF81213) : NULL;
    NvAPI_Status rc = real
        ? real(hPhysicalGpu, information) : NVAPI_NO_IMPLEMENTATION;

    if (!status_allows_profile_override(rc) || !information) {
        return rc;
    }
    if (!nvapi_profile_fill_pstates20(
            information, g_core_clock_kHz, g_boost_clock_kHz,
            g_mem_raw_clock_kHz)) {
        return rc;
    }
    return NVAPI_OK;
}

/* NvAPI_GPU_GetFullName (0xCEEE8E9F) is the marketing/product name used by
 * NVIDIA Control Panel's System Information page. */
static NvAPI_Status __cdecl
hook_GetFullName(void *hPhysicalGpu, char *name)
{
    QueryString_t real = g_real_QI
        ? (QueryString_t)g_real_QI(0xCEEE8E9F) : NULL;
    NvAPI_Status rc = real
        ? real(hPhysicalGpu, name) : NVAPI_NO_IMPLEMENTATION;

    if (!status_allows_profile_override(rc) || !name) {
        return rc;
    }
    if (g_identity_gpu_name_valid) {
        memcpy(name, g_identity_gpu_name, NVAPI_SHORT_STRING_MAX);
        return NVAPI_OK;
    }
    return rc;
}

/*
 * Public NvAPI_GPU_GetPCIIdentifiers (0x2DDFB66E).  NVIDIA returns the
 * internal DeviceId as
 * (device << 16) | vendor, the SubSystemId as
 * (subdevice << 16) | subvendor, and ExtDeviceId as the bare device ID.
 *
 * System projection uses transport-device-profile-subsystem: the real
 * vendor/device/external-device values remain exactly aligned with the one
 * Windows PnP adapter and its production-signed driver, while the atomic
 * board subsystem and target revision come from the profile.  Hardware tools
 * can therefore merge PnP and NVAPI as one logical adapter without losing the
 * AIB brand.  Legacy app-local packages explicitly select profile-tuple.
 */
static NvAPI_Status __cdecl
hook_GetPCIIdentifiers(void *hPhysicalGpu, NvU32 *pDeviceId,
                       NvU32 *pSubSystemId, NvU32 *pRevisionId,
                       NvU32 *pExtDeviceId)
{
    QueryPCIIdentifiers_t real = g_real_QI
        ? (QueryPCIIdentifiers_t)g_real_QI(0x2DDFB66E) : NULL;
    NvAPI_Status rc = real
        ? real(hPhysicalGpu, pDeviceId, pSubSystemId, pRevisionId,
               pExtDeviceId)
        : NVAPI_NO_IMPLEMENTATION;

    if (!status_allows_profile_override(rc) || !pDeviceId || !pSubSystemId ||
        !pRevisionId || !pExtDeviceId) {
        return rc;
    }
    if (!g_identity_pci_valid) {
        return rc;
    }
    if (g_identity_preserve_transport_device) {
        NvU32 real_vendor_id;
        NvU32 real_device_id;

        /* This mode cannot synthesize a transport identity after
         * NVAPI_NOT_SUPPORTED: a successful real query is its provenance. */
        if (rc != NVAPI_OK) {
            return rc;
        }
        real_vendor_id = *pDeviceId & 0xffffu;
        real_device_id = *pDeviceId >> 16;
        if (!real_vendor_id || !real_device_id ||
            *pExtDeviceId != real_device_id) {
            return rc;
        }
    } else {
        *pDeviceId = (g_pci_device_id << 16) | g_pci_vendor_id;
        *pExtDeviceId = g_pci_device_id;
    }
    *pSubSystemId = (g_pci_subdevice_id << 16) | g_pci_subvendor_id;
    *pRevisionId = g_pci_revision_id;
    return NVAPI_OK;
}

/*
 * NvAPI_GPU_GetFBWidthAndLocation (0x11104158) — returns FB bit width
 * and physical location (video memory location enum). Some inventory clients
 * use this private query instead of the public GetRamBusWidth entry point.
 * Signature: NvAPI_Status (__cdecl *)(void* gpu, uint32_t *width, uint32_t *loc)
 */
static NvAPI_Status __cdecl
hook_GetFBWidthAndLocation(void *hPhysicalGpu, NvU32 *pWidth, NvU32 *pLoc)
{
    QueryFBWidth_t real = g_real_QI
        ? (QueryFBWidth_t)g_real_QI(0x11104158) : NULL;
    NvAPI_Status rc = real
        ? real(hPhysicalGpu, pWidth, pLoc) : NVAPI_NO_IMPLEMENTATION;

    if (!status_allows_profile_override(rc) || (!pWidth && !pLoc)) {
        return rc;
    }
    if (pWidth) *pWidth = g_mem_bus_width_bits;
    if (pLoc)   *pLoc   = 1;                          /* NV_GPU_MEMORY_LOCATION_VIDMEM */
    return NVAPI_OK;
}

static NvAPI_Status __cdecl
hook_GetRamMaker(void *hPhysicalGpu, NvU32 *pMaker)
{
    NvAPI_Status rc = call_real_u32(0x42AEA16A, hPhysicalGpu, pMaker);

    return override_u32_result(rc, pMaker, &g_memory_maker);
}

static NvAPI_Status __cdecl
hook_GetRamType(void *hPhysicalGpu, NvU32 *pType)
{
    NvAPI_Status rc = call_real_u32(0x57F7CAAC, hPhysicalGpu, pType);

    return override_u32_result(rc, pType, &g_memory_type);
}

/* Public NVIDIA SDK ID; some clients use this instead of FBWidthAndLocation. */
static NvAPI_Status __cdecl
hook_GetRamBusWidth(void *hPhysicalGpu, NvU32 *pWidth)
{
    NvAPI_Status rc = call_real_u32(0x7975C581, hPhysicalGpu, pWidth);

    return override_u32_result(rc, pWidth, &g_mem_bus_width_bits);
}

static NvAPI_Status __cdecl
hook_GetGpuCoreCount(void *hPhysicalGpu, NvU32 *pCount)
{
    NvAPI_Status rc = call_real_u32(0xC7026A87, hPhysicalGpu, pCount);

    return override_u32_result(rc, pCount, &g_cuda_cores);
}

static NvAPI_Status __cdecl
hook_GetShaderSubPipeCount(void *hPhysicalGpu, NvU32 *pCount)
{
    NvAPI_Status rc = call_real_u32(0x0BE17923, hPhysicalGpu, pCount);

    return override_u32_result(rc, pCount, &g_shader_subpipes);
}

/*
 * Private but ABI-verified against the local 538.33 x86/x64 dispatch tables
 * and wrapper disassembly: (physical GPU, NvU32 *count).
 */
static NvAPI_Status __cdecl
hook_GetROPCount(void *hPhysicalGpu, NvU32 *pCount)
{
    NvAPI_Status rc = call_real_u32(0xFDC129FA, hPhysicalGpu, pCount);

    return override_u32_result(rc, pCount, &g_rop_count);
}

/*
 * Private NvAPI_GPU_GetPartitionCount used by GPU-Z 2.70 as its TMU count.
 * The (physical GPU, NvU32 *count) ABI is verified against both 538.33
 * dispatch wrappers and GPU-Z's x86 call/read path.  Do not reuse this hook
 * for another driver or GPU-Z version without repeating that verification.
 */
static NvAPI_Status __cdecl
hook_GetPartitionCount(void *hPhysicalGpu, NvU32 *pCount)
{
    NvAPI_Status rc = call_real_u32(0x86F05D7A, hPhysicalGpu, pCount);

    return override_u32_result(rc, pCount, &g_tmu_count);
}

static NvAPI_Status __cdecl
hook_GetArchInfo(void *hPhysicalGpu, NV_GPU_ARCH_INFO *pInfo)
{
    QueryArchInfo_t real = g_real_QI
        ? (QueryArchInfo_t)g_real_QI(0xD8265D24) : NULL;
    NvAPI_Status rc = real
        ? real(hPhysicalGpu, pInfo) : NVAPI_NO_IMPLEMENTATION;

    if (!status_allows_profile_override(rc) || !pInfo ||
        (pInfo->version & 0xffffu) < sizeof(*pInfo)) {
        return rc;
    }
    pInfo->architecture = g_architecture;
    pInfo->implementation = g_implementation;
    pInfo->revision = g_chip_revision;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl
hook_GetBusType(void *hPhysicalGpu, NvU32 *pBusType)
{
    NvAPI_Status rc = call_real_u32(0x1BB18724, hPhysicalGpu, pBusType);
    static const NvU32 pcie = NVAPI_GPU_BUS_TYPE_PCI_EXPRESS;

    return override_u32_result(rc, pBusType, &pcie);
}

static NvAPI_Status __cdecl
hook_GetCurrentPCIEDownstreamWidth(void *hPhysicalGpu, NvU32 *pWidth)
{
    NvAPI_Status rc = call_real_u32(0xD048C3B1, hPhysicalGpu, pWidth);

    return override_u32_result(rc, pWidth, &g_pcie_width);
}

static NvAPI_Status __cdecl
hook_GetVbiosVersionString(void *hPhysicalGpu, char *version)
{
    QueryString_t real = g_real_QI
        ? (QueryString_t)g_real_QI(0xA561FD7D) : NULL;
    NvAPI_Status rc = real
        ? real(hPhysicalGpu, version) : NVAPI_NO_IMPLEMENTATION;

    if (!status_allows_profile_override(rc) || !version) {
        return rc;
    }
    if (g_identity_vbios_version_valid) {
        memcpy(version, g_identity_vbios_version, NVAPI_SHORT_STRING_MAX);
        return NVAPI_OK;
    }
    return rc;
}

static NvAPI_Status __cdecl
hook_GetGPUInfo(void *hPhysicalGpu, NV_GPU_INFO_V2 *pInfo)
{
    QueryGPUInfo_t real = g_real_QI
        ? (QueryGPUInfo_t)g_real_QI(0xAFD1B02C) : NULL;
    NvAPI_Status rc = real
        ? real(hPhysicalGpu, pInfo) : NVAPI_NO_IMPLEMENTATION;
    size_t minimum_size = offsetof(NV_GPU_INFO_V2, tensor_cores) +
                          sizeof(pInfo->tensor_cores);

    if (!status_allows_profile_override(rc) || !pInfo ||
        (pInfo->version & 0xffffu) < minimum_size) {
        return rc;
    }
    pInfo->ray_tracing_cores = g_ray_tracing_cores;
    pInfo->tensor_cores = g_tensor_cores;
    return NVAPI_OK;
}

/* ------- dispatch table ------- */
struct override {
    NvU32 id;
    void *fn;
    const char *name;
};

static const struct override g_overrides[] = {
    { 0xCEEE8E9F, hook_GetFullName,            "NvAPI_GPU_GetFullName" },
    { 0x2DDFB66E, hook_GetPCIIdentifiers,      "NvAPI_GPU_GetPCIIdentifiers" },
    { 0xDCB616C3, hook_GetAllClockFrequencies, "NvAPI_GPU_GetAllClockFrequencies" },
#ifndef _WIN64
    { 0x1EA54A3B, hook_GetPerfClocks,           "NvAPI_GPU_GetPerfClocks" },
#endif
    { 0x6FF81213, hook_GetPstates20,            "NvAPI_GPU_GetPstates20" },
    { 0x42AEA16A, hook_GetRamMaker,             "NvAPI_GPU_GetRamMaker" },
    { 0x57F7CAAC, hook_GetRamType,              "NvAPI_GPU_GetRamType" },
    { 0x11104158, hook_GetFBWidthAndLocation,   "NvAPI_GPU_GetFBWidthAndLocation" },
    { 0x7975C581, hook_GetRamBusWidth,          "NvAPI_GPU_GetRamBusWidth" },
    { 0xC7026A87, hook_GetGpuCoreCount,         "NvAPI_GPU_GetGpuCoreCount" },
    { 0x0BE17923, hook_GetShaderSubPipeCount,   "NvAPI_GPU_GetShaderSubPipeCount" },
    { 0xFDC129FA, hook_GetROPCount,             "NvAPI_GPU_GetROPCount" },
    { 0x86F05D7A, hook_GetPartitionCount,       "NvAPI_GPU_GetPartitionCount" },
    { 0xD8265D24, hook_GetArchInfo,             "NvAPI_GPU_GetArchInfo" },
    { 0x1BB18724, hook_GetBusType,              "NvAPI_GPU_GetBusType" },
    { 0xD048C3B1, hook_GetCurrentPCIEDownstreamWidth,
                                               "NvAPI_GPU_GetCurrentPCIEDownstreamWidth" },
    { 0xA561FD7D, hook_GetVbiosVersionString,   "NvAPI_GPU_GetVbiosVersionString" },
    { 0xAFD1B02C, hook_GetGPUInfo,              "NvAPI_GPU_GetGPUInfo" },
    { 0, 0, 0 }
};

/* Arch-specific original name.  The original is loaded lazily from the
 * shim's own directory by absolute path, outside DllMain's loader lock. */
#ifdef _WIN64
  #define BACKUP_NAME_W L"nvapi64_orig.dll"
#else
  #define BACKUP_NAME_W L"nvapi_orig.dll"
#endif

static BOOL CALLBACK load_real_nvapi_once(PINIT_ONCE once, PVOID parameter,
                                           PVOID *context)
{
    WCHAR path[MAX_PATH];
    WCHAR *filename = NULL;
    DWORD length;
    size_t prefix_chars, backup_chars;
    FARPROC proc;

    (void)once;
    (void)parameter;
    (void)context;
    if (!g_self_module) {
        return TRUE;
    }
    length = GetModuleFileNameW(g_self_module, path, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) {
        return TRUE;
    }
    for (WCHAR *cursor = path; *cursor; cursor++) {
        if (*cursor == L'\\' || *cursor == L'/') {
            filename = cursor + 1;
        }
    }
    if (!filename) {
        return TRUE;
    }
    prefix_chars = (size_t)(filename - path);
    backup_chars = (sizeof(BACKUP_NAME_W) / sizeof(WCHAR)) - 1;
    if (prefix_chars + backup_chars >= MAX_PATH) {
        return TRUE;
    }
    memcpy(filename, BACKUP_NAME_W, (backup_chars + 1) * sizeof(WCHAR));
    g_real_nvapi = LoadLibraryW(path);
    if (g_real_nvapi) {
        /* FARPROC has an intentionally untyped ABI.  Copy its representation
         * instead of triggering incompatible-function-cast diagnostics. */
        proc = GetProcAddress(g_real_nvapi, "nvapi_QueryInterface");
        memcpy(&g_real_QI, &proc, sizeof(g_real_QI));
        proc = GetProcAddress(g_real_nvapi, "nvapi_Direct_GetMethod");
        memcpy(&g_real_direct, &proc, sizeof(g_real_direct));
    }
    return TRUE;
}

static BOOL ensure_real_nvapi(void)
{
    InitOnceExecuteOnce(&g_real_init_once, load_real_nvapi_once, NULL, NULL);
    return g_real_nvapi != NULL;
}

/*
 * Optional, low-risk discovery aid for GPU-Z updates.  Set
 * IdentityTraceQueryInterface=1 and capture OutputDebugString messages with a
 * debugger/DebugView.  This logs IDs only; unknown calls are still forwarded.
 */
static void trace_query_interface(NvU32 id)
{
    static const char hex[] = "0123456789ABCDEF";
    char message[] = "nvapi-shim: QI 0x00000000";
    size_t digit_offset = sizeof("nvapi-shim: QI 0x") - 1u;
    unsigned int i;

    load_identity_spec();
    if (!g_trace_query_interface) {
        return;
    }
    for (i = 0; i < 8u; i++) {
        unsigned int shift = (7u - i) * 4u;
        message[digit_offset + i] = hex[(id >> shift) & 0xfu];
    }
    OutputDebugStringA(message);
}

/* Keep both original NVIDIA exports. nvapi_shim.def fixes their ordinals. */

__declspec(dllexport) void* __cdecl
nvapi_QueryInterface(NvU32 id)
{
    if (!ensure_real_nvapi() || !g_real_QI) return NULL;
    trace_query_interface(id);
    for (int i = 0; g_overrides[i].id; i++) {
        if (g_overrides[i].id == id) {
            return g_overrides[i].fn;
        }
    }
    return g_real_QI(id);
}

__declspec(dllexport) void* __cdecl
nvapi_Direct_GetMethod(int32_t method)
{
    if (!ensure_real_nvapi() || !g_real_direct) return NULL;
    return g_real_direct(method);
}

BOOL APIENTRY
DllMain(HINSTANCE hInst, DWORD reason, LPVOID reserved)
{
    (void)hInst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self_module = hInst;
        DisableThreadLibraryCalls(hInst);
    }
    return TRUE;
}
