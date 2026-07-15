/*
 * nvapi_shim.c — DLL shim sitting between apps (鲁大师 / GPU-Z / HWiNFO /
 * game engine NVAPI user) and the real NVIDIA nvapi64.dll. Intercepts a
 * small whitelist of NVAPI function IDs whose real return values leak the
 * physical RTX 2080 hardware (core 1515 / boost 1710 / memory 1750 /
 * 256-bit / 448 GB/s / GDDR6 / UNKNOWN memory vendor) and rewrites them
 * to match the per-VM identity stored under NVIDIA's registry tree.  Old
 * guests without that data retain GT 1030-compatible fallback values.
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
 *   1. Stop nvidia display driver service (or just log off)
 *   2. takeown + icacls on C:\Windows\System32\nvapi64.dll
 *   3. mv nvapi64.dll → nvapi64_orig.dll
 *   4. Drop our nvapi64.dll in place
 *   5. Reboot
 *
 * Scope: this scaffolds the 5 most visible functions. Each override
 * returns FAKE_ values. Extend the table below for more coverage.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef int32_t NvAPI_Status;          /* NVAPI_OK = 0 */
typedef uint32_t NvU32;
typedef void*   (*QueryInterface_t)(NvU32 id);
typedef void*   (__cdecl *DirectGetMethod_t)(int32_t method);
typedef NvAPI_Status (*generic_fn_t)(void*, void*);

static HMODULE            g_self_module = NULL;
static HMODULE            g_real_nvapi = NULL;
static QueryInterface_t   g_real_QI    = NULL;
static DirectGetMethod_t  g_real_direct = NULL;
static INIT_ONCE          g_real_init_once = INIT_ONCE_STATIC_INIT;

/* -------- GT 1030 spec constants (fake values) --------
 *
 * Clock values are in kHz, expressed as "data rate" because 鲁大师 and
 * similar tools divide by 2 for DDR displays ("command clock" = half of
 * data clock). Set to 2× the chip clock we want shown:
 *   Display target     Shim value
 *   Core   1227 MHz    1,227,000   (鲁大师 shows the raw)
 *   Boost  1468 MHz    1,468,000
 *   Memory 1502 MHz    3,004,000   (displayed as 1502 after /2)
 */
#define FAKE_CORE_CLOCK_KHZ     1227000
#define FAKE_BOOST_CLOCK_KHZ    1468000
#define FAKE_MEM_CLOCK_KHZ      3004000
#define FAKE_MEM_BUS_WIDTH_BITS 64
#define FAKE_MEM_BANDWIDTH_MBS  48100     /* MB/s, = 48.1 GB/s */
#define FAKE_RAM_TYPE_GDDR5     8         /* NV_RAM_TYPE_GDDR5 enum */
#define FAKE_RAM_MAKER_SAMSUNG  1         /* NV_RAM_MAKER_SAMSUNG enum */

/* Per-VM values written by patch-grid-strings.ps1.  Keep the historical
 * GT 1030 numbers as fallbacks so an upgraded DLL remains compatible with
 * guests that have not run the new identity sync yet. */
static NvU32 g_core_clock_kHz     = FAKE_CORE_CLOCK_KHZ;
static NvU32 g_boost_clock_kHz    = FAKE_BOOST_CLOCK_KHZ;
static NvU32 g_mem_clock_kHz      = FAKE_MEM_CLOCK_KHZ;
static NvU32 g_mem_bus_width_bits = FAKE_MEM_BUS_WIDTH_BITS;
static NvU32 g_mem_bandwidth_mbps = FAKE_MEM_BANDWIDTH_MBS;
#define NVAPI_SHORT_STRING_MAX 64
static char  g_identity_gpu_name[NVAPI_SHORT_STRING_MAX];
static BOOL  g_identity_gpu_name_valid;
static INIT_ONCE g_identity_init_once = INIT_ONCE_STATIC_INIT;

static void read_identity_dword(HKEY key, const char *name, NvU32 *value)
{
    DWORD type = 0, size = sizeof(*value), candidate = 0;
    if (RegQueryValueExA(key, name, NULL, &type, (BYTE *)&candidate, &size)
            == ERROR_SUCCESS && type == REG_DWORD && size == sizeof(candidate)
            && candidate > 0) {
        *value = candidate;
    }
}

static void read_identity_name(HKEY key)
{
    char candidate[NVAPI_SHORT_STRING_MAX] = { 0 };
    DWORD type = 0, size = sizeof(candidate);
    size_t i;

    if (RegQueryValueExA(key, "IdentityGpuName", NULL, &type,
            (BYTE *)candidate, &size) != ERROR_SUCCESS || type != REG_SZ ||
            size < 2 || size > sizeof(candidate) || candidate[size - 1] != '\0') {
        return;
    }
    /* Reject embedded NULs and non-printable/non-ASCII bytes.  This makes an
     * oversized or malformed registry value fall back to the real name rather
     * than silently truncating it in NvAPI_ShortString (char[64]). */
    for (i = 0; i + 1 < size; i++) {
        unsigned char ch = (unsigned char)candidate[i];
        if (ch < 0x20 || ch > 0x7e) {
            return;
        }
    }
    memcpy(g_identity_gpu_name, candidate, size);
    g_identity_gpu_name_valid = TRUE;
}

static BOOL CALLBACK load_identity_once(PINIT_ONCE once, PVOID parameter,
                                         PVOID *context)
{
    HKEY key;

    (void)once;
    (void)parameter;
    (void)context;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE,
            "SOFTWARE\\NVIDIA Corporation\\Global\\NvAPI", 0,
            KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key) != ERROR_SUCCESS) {
        return TRUE;
    }
    read_identity_name(key);
    read_identity_dword(key, "IdentityCoreClockKHz", &g_core_clock_kHz);
    read_identity_dword(key, "IdentityBoostClockKHz", &g_boost_clock_kHz);
    read_identity_dword(key, "IdentityMemoryClockKHz", &g_mem_clock_kHz);
    read_identity_dword(key, "IdentityMemoryBusBits", &g_mem_bus_width_bits);
    read_identity_dword(key, "IdentityMemoryBandwidthMBps", &g_mem_bandwidth_mbps);
    RegCloseKey(key);
    return TRUE;
}

static void load_identity_spec(void)
{
    InitOnceExecuteOnce(&g_identity_init_once, load_identity_once, NULL, NULL);
}

/* -------- NVAPI struct shapes we need to know about -------- */

/* NvGpuClockFrequencies v1 (id = 0xDCB616C3):
 *   uint32 version               // top byte = version = 2, rest = size
 *   uint32 ClockType             // 0 = current, 1 = base, 2 = boost
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
#define NVAPI_GPU_PUBLIC_CLOCK_VIDEO    6

/* ------- override functions that the app will call ------- */

static NvAPI_Status __cdecl
hook_GetAllClockFrequencies(void *hPhysicalGpu, NV_GPU_CLOCK_FREQUENCIES_V2 *pClk)
{
    if (!pClk) return -5;  /* NVAPI_INVALID_ARGUMENT */
    generic_fn_t real = (generic_fn_t) g_real_QI(0xDCB616C3);
    NvAPI_Status real_rc = real ? real((void*)hPhysicalGpu, pClk) : -3;
    size_t minimum_size = offsetof(NV_GPU_CLOCK_FREQUENCIES_V2, domain[4]) +
                          sizeof(pClk->domain[4]);

    if (real_rc != 0 || (pClk->version & 0xffffu) < minimum_size) {
        return real_rc;
    }
    load_identity_spec();

    /* ClockType: 0 = current, 1 = base, 2 = boost.
     * 鲁大师 queries with type 1 for "核心频率" and type 2 for "Boost频率",
     * so we return FAKE_CORE for 0/1 and FAKE_BOOST for 2. */
    NvU32 core_kHz = (pClk->ClockType == 2) ? g_boost_clock_kHz : g_core_clock_kHz;

    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].present_and_reserved = 1;
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].frequency_kHz = core_kHz;
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].present_and_reserved   = 1;
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].frequency_kHz   = g_mem_clock_kHz;
    return real_rc;
}

/* NvAPI_GPU_GetFullName (0xCEEE8E9F) is the marketing/product name used by
 * NVIDIA Control Panel's System Information page.  Preserve the real call's
 * argument/handle validation and status; only replace a successful result. */
typedef NvAPI_Status (__cdecl *GetFullName_t)(void *, char *);

static NvAPI_Status __cdecl
hook_GetFullName(void *hPhysicalGpu, char *name)
{
    GetFullName_t real = (GetFullName_t)g_real_QI(0xCEEE8E9F);
    NvAPI_Status rc = real ? real(hPhysicalGpu, name) : -3;

    if (rc != 0) {
        return rc;
    }
    load_identity_spec();
    if (name && g_identity_gpu_name_valid) {
        memcpy(name, g_identity_gpu_name, NVAPI_SHORT_STRING_MAX);
    }
    return rc;
}

/*
 * NvAPI_GPU_GetFBWidthAndLocation (0x11104158) — returns FB bit width
 * and physical location (video memory location enum). 鲁大师 reads bus
 * width via this, not via GetRamBusWidth.
 * Signature: NvAPI_Status (__cdecl *)(void* gpu, uint32_t *width, uint32_t *loc)
 */
static NvAPI_Status __cdecl
hook_GetFBWidthAndLocation(void *hPhysicalGpu, NvU32 *pWidth, NvU32 *pLoc)
{
    typedef NvAPI_Status (__cdecl *GetFBWidth_t)(void *, NvU32 *, NvU32 *);
    GetFBWidth_t real = (GetFBWidth_t)g_real_QI(0x11104158);
    NvAPI_Status rc = real ? real(hPhysicalGpu, pWidth, pLoc) : -3;
    if (rc != 0) return rc;
    load_identity_spec();
    if (pWidth) *pWidth = g_mem_bus_width_bits;
    if (pLoc)   *pLoc   = 1;                          /* NV_GPU_MEMORY_LOCATION_VIDMEM */
    return rc;
}

static NvAPI_Status __cdecl
hook_GetRamMaker(void *hPhysicalGpu, NvU32 *pMaker)
{
    if (!pMaker) return -5;
    generic_fn_t real = (generic_fn_t)g_real_QI(0x42AEA16A);
    NvAPI_Status rc = real ? real(hPhysicalGpu, pMaker) : -3;
    if (rc != 0) return rc;
    *pMaker = FAKE_RAM_MAKER_SAMSUNG;
    return rc;
}

static NvAPI_Status __cdecl
hook_GetRamType(void *hPhysicalGpu, NvU32 *pType)
{
    if (!pType) return -5;
    generic_fn_t real = (generic_fn_t)g_real_QI(0x57F7CAAC);
    NvAPI_Status rc = real ? real(hPhysicalGpu, pType) : -3;
    if (rc != 0) return rc;
    *pType = FAKE_RAM_TYPE_GDDR5;
    return rc;
}

/* ------- dispatch table ------- */
struct override {
    NvU32 id;
    void *fn;
    const char *name;
};

static const struct override g_overrides[] = {
    { 0xCEEE8E9F, hook_GetFullName,           "NvAPI_GPU_GetFullName" },
    { 0xDCB616C3, hook_GetAllClockFrequencies, "NvAPI_GPU_GetAllClockFrequencies" },
    { 0x42AEA16A, hook_GetRamMaker,            "NvAPI_GPU_GetRamMaker" },
    { 0x57F7CAAC, hook_GetRamType,             "NvAPI_GPU_GetRamType" },
    /* This one IS the public bus width NVAPI — verified as what 鲁大师
     * actually calls (setting it changes the 显存位宽 row). */
    { 0x11104158, hook_GetFBWidthAndLocation,  "NvAPI_GPU_GetFBWidthAndLocation" },
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

/* Keep both original NVIDIA exports. nvapi_shim.def fixes their ordinals. */

__declspec(dllexport) void* __cdecl
nvapi_QueryInterface(NvU32 id)
{
    if (!ensure_real_nvapi() || !g_real_QI) return NULL;
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
