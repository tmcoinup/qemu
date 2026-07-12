/*
 * nvapi64.dll shim for GPU-Z / HWiNFO inside a Ryzen3 stealth guest.
 *
 * NVIDIA's real nvapi64.dll exports a single public entry point:
 *
 *   void *nvapi_QueryInterface(unsigned int id);
 *
 * Every other NVAPI function is dispatched through that lookup. Clients
 * bind to symbolic IDs (e.g. NvAPI_Initialize = 0x0150E828) and receive a
 * function pointer they then call. A real driver's nvapi builds its table
 * at load time.
 *
 * Real NVIDIA driver is not installed here. Our goal: make GPU-Z /
 * HWiNFO / CPU-Z populate a few headline fields (GPU name, PCI IDs, VRAM
 * size) instead of showing "Unknown" so the guest looks like a real
 * GTX 1050 Ti machine. Every other query returns NVAPI_NOT_SUPPORTED so
 * the caller falls back to the public D3D/WDDM probing path, which is
 * already driven by viogpudo's FriendlyName rewrite + EDID stealth.
 *
 * We deliberately do NOT touch power/thermal/fan queries. Returning fake
 * 0 values there makes GPU-Z paint wrong graphs; NOT_SUPPORTED is safer.
 *
 * The DLL should be dropped next to the client exe (GPU-Z.exe folder or
 * HWiNFO install dir) — NEVER System32, where it would shadow a future
 * real driver install.
 */

#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

typedef int32_t  NvAPI_Status;
typedef uint32_t NvU32;
typedef uint8_t  NvU8;
typedef void    *NvPhysicalGpuHandle;
typedef void    *NvDisplayHandle;

/* Status codes (stable across driver versions) */
#define NVAPI_OK                            0
#define NVAPI_ERROR                        -1
#define NVAPI_API_NOT_INITIALIZED          -2
#define NVAPI_INVALID_ARGUMENT             -5
#define NVAPI_NOT_SUPPORTED              -107
#define NVAPI_HANDLE_INVALIDATED            -8
#define NVAPI_NVIDIA_DEVICE_NOT_FOUND       -9

#define SHIM_MAX_GPUS  64

/* ------------------------------------------------------------------
 * Configurable GPU identity. Values are compile-time defaults but the
 * environment variable NVSHIM_FORCE_NAME can be used to override the
 * reported board name at runtime (Windows supports env-var reads even
 * from DLLs loaded into GPU-Z).
 * ----------------------------------------------------------------- */
#ifndef SHIM_GPU_NAME
#define SHIM_GPU_NAME  "NVIDIA GeForce GTX 1050"
#endif
#ifndef SHIM_GPU_PCIID_VEN
#define SHIM_GPU_PCIID_VEN 0x10DE
#endif
#ifndef SHIM_GPU_PCIID_DEV
#define SHIM_GPU_PCIID_DEV 0x1C81
#endif
#ifndef SHIM_GPU_SUB_VEN
#define SHIM_GPU_SUB_VEN 0x10DE
#endif
#ifndef SHIM_GPU_SUB_DEV
#define SHIM_GPU_SUB_DEV 0x1C81
#endif
#ifndef SHIM_GPU_REV
#define SHIM_GPU_REV 0xA1
#endif
/* GTX 1050: 2 GiB GDDR5 → reported in KiB */
#ifndef SHIM_GPU_VRAM_KIB
#define SHIM_GPU_VRAM_KIB (2u * 1024u * 1024u)
#endif

static char g_gpu_name[128] = SHIM_GPU_NAME;
static int  g_initialized;

/* Fake GPU handle — any non-NULL token; GPU-Z only compares for equality */
static const uintptr_t g_gpu_handle_token = 0xB007C0DE;

/* ------------------------------------------------------------------
 * Core lifecycle
 * ----------------------------------------------------------------- */

static NvAPI_Status __cdecl NvAPI_Initialize(void)
{
    const char *env;

    if (g_initialized) {
        return NVAPI_OK;
    }
    env = getenv("NVSHIM_FORCE_NAME");
    if (env && *env) {
        lstrcpynA(g_gpu_name, env, sizeof(g_gpu_name) - 1);
    }
    g_initialized = 1;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_Unload(void)
{
    g_initialized = 0;
    return NVAPI_OK;
}

/* GetErrorMessage: callers pass (status, char out[256]). */
static NvAPI_Status __cdecl NvAPI_GetErrorMessage(NvAPI_Status code, char *out)
{
    if (!out) {
        return NVAPI_INVALID_ARGUMENT;
    }
    if (code == NVAPI_OK) {
        lstrcpynA(out, "Success", 256);
    } else if (code == NVAPI_NOT_SUPPORTED) {
        lstrcpynA(out, "Not supported (shim)", 256);
    } else {
        lstrcpynA(out, "Unknown shim error", 256);
    }
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GetInterfaceVersionString(char *out)
{
    if (!out) {
        return NVAPI_INVALID_ARGUMENT;
    }
    /* Pretend we are a recent-ish Game Ready driver. Value is purely
     * cosmetic — GPU-Z does not validate format. */
    lstrcpynA(out, "Release 546.33 (shim)", 64);
    return NVAPI_OK;
}

/* ------------------------------------------------------------------
 * Physical GPU enumeration
 * ----------------------------------------------------------------- */

static NvAPI_Status __cdecl NvAPI_EnumPhysicalGPUs(
    NvPhysicalGpuHandle handles[SHIM_MAX_GPUS], NvU32 *count)
{
    if (!handles || !count) {
        return NVAPI_INVALID_ARGUMENT;
    }
    if (!g_initialized) {
        return NVAPI_API_NOT_INITIALIZED;
    }
    handles[0] = (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token;
    *count = 1;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_EnumTCCPhysicalGPUs(
    NvPhysicalGpuHandle handles[SHIM_MAX_GPUS], NvU32 *count)
{
    if (count) {
        *count = 0;
    }
    /* No TCC (Tesla compute-cluster) GPU present. */
    return NVAPI_OK;
}

/* ------------------------------------------------------------------
 * Per-GPU scalar queries GPU-Z reads on the main panel
 * ----------------------------------------------------------------- */

static NvAPI_Status __cdecl NvAPI_GPU_GetFullName(
    NvPhysicalGpuHandle h, char *out)
{
    if (!out) {
        return NVAPI_INVALID_ARGUMENT;
    }
    if (h != (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token) {
        return NVAPI_HANDLE_INVALIDATED;
    }
    lstrcpynA(out, g_gpu_name, 64);
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GPU_GetBusId(
    NvPhysicalGpuHandle h, NvU32 *bus)
{
    if (!bus) return NVAPI_INVALID_ARGUMENT;
    if (h != (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token) {
        return NVAPI_HANDLE_INVALIDATED;
    }
    /* PCI bus 6 matches our pcie.0 slot=6 VGA placement by default. Use
     * a sentinel of 1 otherwise — any non-zero value stops GPU-Z from
     * complaining about "PCI: Disabled". */
    *bus = 1;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GPU_GetBusSlotId(
    NvPhysicalGpuHandle h, NvU32 *slot)
{
    if (!slot) return NVAPI_INVALID_ARGUMENT;
    if (h != (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token) {
        return NVAPI_HANDLE_INVALIDATED;
    }
    *slot = 0;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GPU_GetBusType(
    NvPhysicalGpuHandle h, NvU32 *type)
{
    /* 4 == NVAPI_GPU_BUS_TYPE_PCI_EXPRESS */
    if (!type) return NVAPI_INVALID_ARGUMENT;
    *type = 4;
    return NVAPI_OK;
}

/* Returns a NV_GPU_PCI_IDENTIFIERS struct:
 *   NvU32 deviceId;    (vendor<<16 | device)
 *   NvU32 subSystemId; (subvendor<<16 | subdevice) — NVIDIA layout: high
 *                       word = subdevice, low word = subvendor
 *   NvU32 revisionId;
 *   NvU32 extDeviceId; (0 for consumer parts)
 */
static NvAPI_Status __cdecl NvAPI_GPU_GetPCIIdentifiers(
    NvPhysicalGpuHandle h, NvU32 *devId, NvU32 *subSys,
    NvU32 *rev,   NvU32 *extDev)
{
    if (!devId || !subSys || !rev || !extDev) {
        return NVAPI_INVALID_ARGUMENT;
    }
    if (h != (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token) {
        return NVAPI_HANDLE_INVALIDATED;
    }
    *devId  = (SHIM_GPU_PCIID_VEN << 16) | SHIM_GPU_PCIID_DEV;
    /* NVIDIA layout: bits 31..16 = subdevice, bits 15..0 = subvendor */
    *subSys = (SHIM_GPU_SUB_DEV << 16) | SHIM_GPU_SUB_VEN;
    *rev    = SHIM_GPU_REV;
    *extDev = 0;
    return NVAPI_OK;
}

/* Framebuffer (VRAM) size in KiB. Older API variant. */
static NvAPI_Status __cdecl NvAPI_GPU_GetPhysicalFrameBufferSize(
    NvPhysicalGpuHandle h, NvU32 *size_kib)
{
    if (!size_kib) return NVAPI_INVALID_ARGUMENT;
    if (h != (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token) {
        return NVAPI_HANDLE_INVALIDATED;
    }
    *size_kib = SHIM_GPU_VRAM_KIB;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_GPU_GetVirtualFrameBufferSize(
    NvPhysicalGpuHandle h, NvU32 *size_kib)
{
    if (!size_kib) return NVAPI_INVALID_ARGUMENT;
    if (h != (NvPhysicalGpuHandle)(uintptr_t)g_gpu_handle_token) {
        return NVAPI_HANDLE_INVALIDATED;
    }
    *size_kib = SHIM_GPU_VRAM_KIB;
    return NVAPI_OK;
}

static NvAPI_Status __cdecl NvAPI_SYS_GetDriverAndBranchVersion(
    NvU32 *version, char *branch)
{
    if (!version || !branch) {
        return NVAPI_INVALID_ARGUMENT;
    }
    *version = 54633; /* DWORD form of 546.33 */
    lstrcpynA(branch, "r545_99", 64);
    return NVAPI_OK;
}

/* ------------------------------------------------------------------
 * NOT_SUPPORTED default — returned whenever GPU-Z asks for a feature we
 * do not want to fake (thermal/fan/power/boost/ECC/etc.). Signature is
 * compatible with any pointer-argument API; we simply ignore arguments.
 * ----------------------------------------------------------------- */

static NvAPI_Status __cdecl NvAPI_NotSupportedStub(void)
{
    return NVAPI_NOT_SUPPORTED;
}

/* ------------------------------------------------------------------
 * Interface ID → function pointer table.
 *
 * IDs are FourCC-like 32-bit constants the official NVAPI headers define
 * as: #define NvAPI_X_HASH 0xXXXXXXXX. The subset below is what GPU-Z
 * 2.55 and HWiNFO 8.x are observed to look up on startup.
 * ----------------------------------------------------------------- */

struct shim_entry {
    NvU32 id;
    void *fn;
};

static const struct shim_entry g_shim_table[] = {
    { 0x0150E828, NvAPI_Initialize                      },
    { 0xD22BDD7E, NvAPI_Unload                          },
    { 0x6C2D048C, NvAPI_GetErrorMessage                 },
    { 0x01053FA5, NvAPI_GetInterfaceVersionString       },
    { 0xE5AC921F, NvAPI_EnumPhysicalGPUs                },
    { 0xD9930B07, NvAPI_EnumTCCPhysicalGPUs             },
    { 0xCEEE8E9F, NvAPI_GPU_GetFullName                 },
    { 0x1BE0B8E5, NvAPI_GPU_GetBusType                  },
    { 0x1BB18724, NvAPI_GPU_GetBusId                    },
    { 0x2A0A350F, NvAPI_GPU_GetBusSlotId                },
    { 0x2DDFB66E, NvAPI_GPU_GetPCIIdentifiers           },
    { 0x46FBEB03, NvAPI_GPU_GetPhysicalFrameBufferSize  },
    { 0x5A04B644, NvAPI_GPU_GetVirtualFrameBufferSize   },
    { 0x2926AAAD, NvAPI_SYS_GetDriverAndBranchVersion   },
};

__declspec(dllexport)
void * __cdecl nvapi_QueryInterface(NvU32 id)
{
    size_t i;
    for (i = 0; i < sizeof(g_shim_table) / sizeof(g_shim_table[0]); i++) {
        if (g_shim_table[i].id == id) {
            return g_shim_table[i].fn;
        }
    }
    /* Everything else: caller gets a function that simply says
     * NVAPI_NOT_SUPPORTED, which is the behavior GPU-Z already handles
     * gracefully (it falls back to D3D path). */
    return (void *)NvAPI_NotSupportedStub;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID rsvd)
{
    (void)h; (void)rsvd;
    if (reason == DLL_PROCESS_DETACH) {
        g_initialized = 0;
    }
    return TRUE;
}
