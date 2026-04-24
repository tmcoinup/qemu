/*
 * nvapi_shim.c — DLL shim sitting between apps (鲁大师 / GPU-Z / HWiNFO /
 * game engine NVAPI user) and the real NVIDIA nvapi64.dll. Intercepts a
 * small whitelist of NVAPI function IDs whose real return values leak the
 * physical RTX 2080 hardware (core 1515 / boost 1710 / memory 1750 /
 * 256-bit / 448 GB/s / GDDR6 / UNKNOWN memory vendor) and rewrites them
 * to match the spoofed identity (GeForce GT 1030: 1227 / 1468 / 1502 /
 * 64-bit / 48.1 GB/s / GDDR5 / Samsung).
 *
 * How NVAPI dispatch works:
 *   - DLL exports ONE entry point: nvapi_QueryInterface(uint32_t id)
 *   - It returns a function pointer for the requested function id
 *   - All further NVAPI calls go through that pointer
 *
 * So we only need to intercept QueryInterface: if the id is in our
 * override table, return our replacement; otherwise forward to the real
 * nvapi64.dll's QueryInterface.
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
#include <stdint.h>

typedef int32_t NvAPI_Status;          /* NVAPI_OK = 0 */
typedef uint32_t NvU32;
typedef void*   (*QueryInterface_t)(NvU32 id);
typedef NvAPI_Status (*generic_fn_t)(void*, void*);

static HMODULE            g_real_nvapi = NULL;
static QueryInterface_t   g_real_QI    = NULL;

/* -------- GT 1030 spec constants (fake values) -------- */
#define FAKE_CORE_CLOCK_KHZ     1227000   /* GT 1030 base 1227 MHz */
#define FAKE_BOOST_CLOCK_KHZ    1468000   /* GT 1030 boost 1468 MHz */
#define FAKE_MEM_CLOCK_KHZ      1502000   /* GT 1030 GDDR5 @ 6 Gbps */
#define FAKE_MEM_BUS_WIDTH_BITS 64
#define FAKE_MEM_BANDWIDTH_MBS  48100     /* MB/s, = 48.1 GB/s */
#define FAKE_RAM_TYPE_GDDR5     8         /* NV_RAM_TYPE_GDDR5 enum */
#define FAKE_RAM_MAKER_SAMSUNG  1         /* NV_RAM_MAKER_SAMSUNG enum */

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
    /* Try to forward to real first — populates GPU-specific domain flags
     * (which ones are actually present) and video clock etc. */
    generic_fn_t real = (generic_fn_t) g_real_QI(0xDCB616C3);
    NvAPI_Status real_rc = real ? real((void*)hPhysicalGpu, pClk) : -1;

    /* Force-populate the two domains every tool cares about, independent
     * of whether real() accepted our struct version. Mark both PRESENT so
     * caller doesn't skip them, and set the spoofed frequencies. */
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].present_and_reserved = 1;
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].frequency_kHz = FAKE_CORE_CLOCK_KHZ;
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].present_and_reserved   = 1;
    pClk->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].frequency_kHz   = FAKE_MEM_CLOCK_KHZ;
    (void)real_rc;
    return 0;
}

static NvAPI_Status __cdecl
hook_GetRamMaker(void *hPhysicalGpu, NvU32 *pMaker)
{
    if (!pMaker) return -5;
    *pMaker = FAKE_RAM_MAKER_SAMSUNG;
    return 0;
}

static NvAPI_Status __cdecl
hook_GetRamType(void *hPhysicalGpu, NvU32 *pType)
{
    if (!pType) return -5;
    *pType = FAKE_RAM_TYPE_GDDR5;
    return 0;
}

static NvAPI_Status __cdecl
hook_GetRamBusWidth(void *hPhysicalGpu, NvU32 *pWidth)
{
    if (!pWidth) return -5;
    *pWidth = FAKE_MEM_BUS_WIDTH_BITS;
    return 0;
}

static NvAPI_Status __cdecl
hook_GetRamBandwidth(void *hPhysicalGpu, NvU32 *pMBps)
{
    if (!pMBps) return -5;
    *pMBps = FAKE_MEM_BANDWIDTH_MBS;
    return 0;
}

/* ------- dispatch table ------- */
struct override {
    NvU32 id;
    void *fn;
    const char *name;
};

static const struct override g_overrides[] = {
    { 0xDCB616C3, hook_GetAllClockFrequencies, "NvAPI_GPU_GetAllClockFrequencies" },
    { 0x42AEA16A, hook_GetRamMaker,            "NvAPI_GPU_GetRamMaker" },
    { 0x57F7CAAC, hook_GetRamType,             "NvAPI_GPU_GetRamType" },
    /* These IDs are best-effort — different NVAPI minor versions have
     * drifted function ids. Extend after verifying against a real 538.33
     * nvapi64.dll symbol dump. */
    { 0x7A5E9C9F, hook_GetRamBusWidth,         "NvAPI_GPU_GetRamBusWidth?" },
    { 0x1DCECC0E, hook_GetRamBandwidth,        "NvAPI_GPU_GetRamBandwidth?" },
    { 0, 0, 0 }
};

/* ------- the only export: nvapi_QueryInterface ------- */

__declspec(dllexport) void* __cdecl
nvapi_QueryInterface(NvU32 id)
{
    if (!g_real_QI) return NULL;
    for (int i = 0; g_overrides[i].id; i++) {
        if (g_overrides[i].id == id) {
            return g_overrides[i].fn;
        }
    }
    return g_real_QI(id);
}

/* Arch-specific backup name + system dir:
 *   x64 shim:  System32\nvapi64_orig.dll
 *   x86 shim:  SysWOW64\nvapi_orig.dll    (32-bit apps on x64 Windows)
 */
#ifdef _WIN64
  #define BACKUP_NAME     "nvapi64_orig.dll"
  #define BACKUP_FULLPATH "C:\\Windows\\System32\\nvapi64_orig.dll"
#else
  #define BACKUP_NAME     "nvapi_orig.dll"
  #define BACKUP_FULLPATH "C:\\Windows\\SysWOW64\\nvapi_orig.dll"
#endif

BOOL APIENTRY
DllMain(HINSTANCE hInst, DWORD reason, LPVOID reserved)
{
    (void)hInst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        /* Load the original DLL we renamed aside */
        g_real_nvapi = LoadLibraryA(BACKUP_NAME);
        if (!g_real_nvapi) {
            g_real_nvapi = LoadLibraryA(BACKUP_FULLPATH);
        }
        if (g_real_nvapi) {
            g_real_QI = (QueryInterface_t)GetProcAddress(g_real_nvapi, "nvapi_QueryInterface");
        }
    }
    return TRUE;
}
