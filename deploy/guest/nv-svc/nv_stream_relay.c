/*
 * nv_stream_relay.c — guest-side native screen capture + dirty-tile
 * raw BGRA streamer that writes directly into the ivshmem ring.
 *
 * No ffmpeg, no NVENC, no JPEG codec. The encode hardware is
 * deliberately untouched — anti-cheat in a guest will flag suspicious
 * GPU-HAL traffic before it flags raw pixel-pushing.
 *
 *   * Capture:    Desktop Duplication API (DXGI), same call as OBS /
 *                 Microsoft RDP / TeamViewer.
 *   * Download:   D3D11 STAGING texture + Map() — CPU readback.
 *   * "Encode":   None. Hash each 32×32 tile, compare to previous
 *                 frame, ship only the dirty tiles' raw BGRA bytes
 *                 into the video ring as a single FRAM record.
 *                 Static desktop → 12-byte empty frame. Full screen
 *                 change → ~8 MB at 1080p. Office workload averages
 *                 a few MB/s.
 *
 * Single Windows binary; IAT references only kernel32/user32/d3d11/
 * dxgi/setupapi/ws2_32 — no NVIDIA codec strings, no third-party
 * codec libraries linked.
 */

#define _WIN32_WINNT 0x0600
#define WIN32_LEAN_AND_MEAN
#define INITGUID    /* needed for DEFINE_GUID() to actually emit storage */
#define COBJMACROS  /* C-style COM dispatch (lpVtbl->Method) for D3D11/DXGI */
#define CINTERFACE
#include <windows.h>
#include <initguid.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <setupapi.h>
#include <winioctl.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>

/* No third-party codec includes. Pure platform headers + our own
 * shared memory protocol header. */

/* nv_shmem_proto.h is shared between host and guest source trees.
 * For mingw we copy the header into this directory's build area. */
#include "nv_shmem_proto.h"

/* ──────────────────────── identity / config ─────────────────────── */
#define LOG_PATH                "C:\\nv\\nv-stream-relay.log"
#define INPUT_FORWARD_HOST      "127.0.0.1"
#define INPUT_FORWARD_PORT      56789

#define CFG_REG_PATH            "SOFTWARE\\NVIDIA\\DisplayContainer\\Stream"
#define CFG_DEF_FRAMERATE       60

/* forward decls (helpers defined further down) */
static void vlog(const char *fmt, ...);
static int  reg_get_dword(const char *path, const char *name, DWORD *out);
static int  reg_get_sz   (const char *path, const char *name, char *out, DWORD outsz);

/* Looking Glass ivshmem driver IOCTLs (public protocol — values are
 * stable since LG 0.7+). We don't need their .lib, just these constants
 * and the device interface GUID. */
DEFINE_GUID(GUID_DEVINTERFACE_IVSHMEM,
    0xdf576976, 0x569d, 0x4672, 0x95, 0xa0, 0xf5, 0x7e, 0x4e, 0xa0, 0xb2, 0x10);

/* IOCTL function codes per Looking Glass vendor/ivshmem/ivshmem.h —
 * note these start at 0x800, NOT 0x801. Earlier this file had the
 * codes off by +1 across the board, so REQUEST_MMAP was actually
 * calling RELEASE_MMAP and getting STATUS_INVALID_FUNCTION. */
#define IOCTL_IVSHMEM_REQUEST_PEERID   CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_IVSHMEM_REQUEST_SIZE     CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_IVSHMEM_REQUEST_MMAP     CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_IVSHMEM_RELEASE_MMAP     CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define IVSHMEM_CACHE_NONCACHED        0
#define IVSHMEM_CACHE_CACHED           1
#define IVSHMEM_CACHE_WRITECOMBINED    2

typedef struct {
    UINT16  peerID;        /* host runs as peer 0xFFFF */
    UINT64  size;
    PVOID   ptr;
    UINT16  vectors;
} IVSHMEM_MMAP;

typedef struct {
    UINT8 cacheMode;
} IVSHMEM_MMAP_CONFIG;

/* ──────────────────────── DES (mirror of vnc_server.c) ─────────── */
static const uint8_t DES_S[8][64] = {
    {14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,
     4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13},
    {15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,
     0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9},
    {10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,
     13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12},
    {7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,
     10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14},
    {2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,
     4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3},
    {12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,
     9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13},
    {4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,
     1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12},
    {13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,
     7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11}
};
static const uint8_t DES_P[32]={16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25};
static const uint8_t DES_IP[64]={58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7};
static const uint8_t DES_FP[64]={40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25};
static const uint8_t DES_E[48]={32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1};
static const uint8_t DES_PC1[56]={57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4};
static const uint8_t DES_PC2[48]={14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32};
static const uint8_t DES_ROT[16]={1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1};
static uint64_t bitperm(uint64_t s, const uint8_t *p, int n, int sz) {
    uint64_t r = 0;
    for (int i = 0; i < n; i++) { uint64_t b = (s >> (sz - p[i])) & 1; r |= b << (n-1-i); }
    return r;
}
static void des_crypt(const uint8_t key[8], const uint8_t in[8], uint8_t out[8]) {
    uint64_t k=0,m=0;
    for (int i=0;i<8;i++){k=(k<<8)|key[i];m=(m<<8)|in[i];}
    uint64_t kp = bitperm(k, DES_PC1, 56, 64);
    uint32_t c = (kp>>28)&0xFFFFFFF, d = kp&0xFFFFFFF;
    uint64_t sub[16];
    for (int i=0;i<16;i++) {
        c=((c<<DES_ROT[i])|(c>>(28-DES_ROT[i])))&0xFFFFFFF;
        d=((d<<DES_ROT[i])|(d>>(28-DES_ROT[i])))&0xFFFFFFF;
        sub[i]=bitperm(((uint64_t)c<<28)|d, DES_PC2, 48, 56);
    }
    uint64_t ip = bitperm(m, DES_IP, 64, 64);
    uint32_t L=(uint32_t)(ip>>32), R=(uint32_t)(ip&0xFFFFFFFF);
    for (int rd=0;rd<16;rd++) {
        uint64_t e=bitperm(R,DES_E,48,32)^sub[rd];
        uint32_t so=0;
        for (int i=0;i<8;i++) {
            uint8_t six=(e>>(42-6*i))&0x3F;
            so=(so<<4)|DES_S[i][((six&0x20)>>4|(six&1))*16+((six>>1)&0xF)];
        }
        uint32_t f=(uint32_t)bitperm(so,DES_P,32,32);
        uint32_t nl=R; R=L^f; L=nl;
    }
    uint64_t fp = bitperm(((uint64_t)R<<32)|L, DES_FP, 64, 64);
    for (int i=0;i<8;i++) out[i]=(fp>>(56-8*i))&0xFF;
}
static void vnc_flip_bits(uint8_t k[8]) {
    for (int i=0;i<8;i++) {
        uint8_t v=k[i],r=0;
        for (int b=0;b<8;b++) if (v&(1<<b)) r|=1<<(7-b);
        k[i]=r;
    }
}

/* ──────────────────────── tiny log ──────────────────────────────── */
static CRITICAL_SECTION g_log_cs;
static int g_log_inited = 0;
static void log_init(void) {
    if (g_log_inited) return;
    InitializeCriticalSection(&g_log_cs);
    CreateDirectoryA("C:\\nv", NULL);
    g_log_inited = 1;
}
static void vlog(const char *fmt, ...) {
    if (!g_log_inited) return;
    EnterCriticalSection(&g_log_cs);
    FILE *f = fopen(LOG_PATH, "a");
    if (f) {
        SYSTEMTIME t; GetLocalTime(&t);
        fprintf(f, "%02d:%02d:%02d.%03d ",
                t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
        va_list ap; va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fputc('\n', f);
        fclose(f);
    }
    LeaveCriticalSection(&g_log_cs);
}

/* ──────────────────────── ivshmem open ──────────────────────────── */
static HANDLE g_ivs_handle = INVALID_HANDLE_VALUE;
static void *g_ivs_base    = NULL;
static UINT64 g_ivs_size   = 0;

static int ivshmem_open(void) {
    HDEVINFO hdi = SetupDiGetClassDevs(&GUID_DEVINTERFACE_IVSHMEM, NULL, NULL,
        DIGCF_DEVICEINTERFACE | DIGCF_PRESENT);
    if (hdi == INVALID_HANDLE_VALUE) {
        vlog("SetupDiGetClassDevs failed: %lu", GetLastError());
        return -1;
    }

    SP_DEVICE_INTERFACE_DATA did = { .cbSize = sizeof(did) };
    if (!SetupDiEnumDeviceInterfaces(hdi, NULL, &GUID_DEVINTERFACE_IVSHMEM, 0, &did)) {
        vlog("no ivshmem device present (driver installed?): %lu", GetLastError());
        SetupDiDestroyDeviceInfoList(hdi);
        return -1;
    }
    DWORD detail_sz = 0;
    SetupDiGetDeviceInterfaceDetail(hdi, &did, NULL, 0, &detail_sz, NULL);
    SP_DEVICE_INTERFACE_DETAIL_DATA *detail = malloc(detail_sz);
    detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA);
    if (!SetupDiGetDeviceInterfaceDetail(hdi, &did, detail, detail_sz, NULL, NULL)) {
        vlog("GetDeviceInterfaceDetail failed: %lu", GetLastError());
        free(detail); SetupDiDestroyDeviceInfoList(hdi);
        return -1;
    }

    HANDLE h = CreateFileA(detail->DevicePath,
                           GENERIC_READ | GENERIC_WRITE, 0, NULL,
                           OPEN_EXISTING, 0, NULL);
    DWORD err = GetLastError();
    free(detail);
    SetupDiDestroyDeviceInfoList(hdi);
    if (h == INVALID_HANDLE_VALUE) {
        vlog("CreateFile ivshmem failed: %lu", err);
        return -1;
    }

    /* The 2022-vintage Looking-Glass driver ships in the B7 host package
     * is fussy about REQUEST_SIZE buffers — it returns
     * STATUS_INVALID_USER_BUFFER on a plain `&UINT64`. Skip that probe
     * and go straight to REQUEST_MMAP; the IVSHMEM_MMAP struct it
     * returns already contains the size, and we'll bail if that's
     * smaller than NV_SHMEM_TOTAL_BYTES. */
    DWORD ret = 0;
    IVSHMEM_MMAP_CONFIG cfg = { .cacheMode = IVSHMEM_CACHE_WRITECOMBINED };
    IVSHMEM_MMAP map = {0};
    if (!DeviceIoControl(h, IOCTL_IVSHMEM_REQUEST_MMAP,
                         &cfg, sizeof(cfg),
                         &map, sizeof(map),
                         &ret, NULL)) {
        vlog("REQUEST_MMAP failed: %lu", GetLastError());
        CloseHandle(h); return -1;
    }
    vlog("mapped %llu bytes at %p (peerID=%u)",
         (unsigned long long)map.size, map.ptr, map.peerID);
    if (map.size < NV_SHMEM_TOTAL_BYTES) {
        vlog("ivshmem region too small (have %llu need %u)",
             (unsigned long long)map.size, NV_SHMEM_TOTAL_BYTES);
        CloseHandle(h); return -1;
    }

    g_ivs_handle = h;
    g_ivs_base   = map.ptr;
    g_ivs_size   = map.size;
    return 0;
}

static void ivshmem_close(void) {
    if (g_ivs_base && g_ivs_handle != INVALID_HANDLE_VALUE) {
        DWORD ret;
        DeviceIoControl(g_ivs_handle, IOCTL_IVSHMEM_RELEASE_MMAP,
                        NULL, 0, NULL, 0, &ret, NULL);
    }
    if (g_ivs_handle != INVALID_HANDLE_VALUE) CloseHandle(g_ivs_handle);
    g_ivs_handle = INVALID_HANDLE_VALUE;
    g_ivs_base = NULL;
}

/* ──────────────────────── header init ───────────────────────────── */
static void shmem_header_init(NvShmemHdr *hdr) {
    /* If magic is already set, leave the rings untouched (likely the
     * service got restarted; host may already be reading). Otherwise
     * lay down a fresh header. */
    if (hdr->magic == NV_SHMEM_MAGIC) {
        vlog("header already initialized (writer_seq video=%u input=%u)",
             hdr->video.writer_seq, hdr->video.reader_seq);
        return;
    }
    memset(hdr, 0, sizeof(*hdr));
    hdr->magic       = NV_SHMEM_MAGIC;
    hdr->version     = NV_SHMEM_VERSION;
    hdr->total_bytes = NV_SHMEM_TOTAL_BYTES;
    hdr->hdr_bytes   = NV_SHMEM_HDR_BYTES;
    hdr->video_off   = NV_SHMEM_VIDEO_OFF;
    hdr->video_bytes = NV_SHMEM_VIDEO_BYTES;
    hdr->input_off   = NV_SHMEM_INPUT_OFF;
    hdr->input_bytes = NV_SHMEM_INPUT_BYTES;
    vlog("header initialized (magic NVHM)");
}

/* ──────────────────────── stop flag ─────────────────────────────── */
static volatile LONG g_stop = 0;

/* Windows console-app shutdown handler. The service launcher
 * (NvDisplayContainer) spawns us as a CONSOLE subsystem child via
 * CreateProcessAsUser, so we get CTRL_SHUTDOWN_EVENT on system
 * shutdown / logoff and CTRL_CLOSE_EVENT when the parent service
 * orderly stops us. Set g_stop=1; the main loop will see it within
 * the next ~50ms (capture cadence) and exit, which lets our final
 * `guest_alive_tick = 0` write reach the host viewer **before** the
 * 4-second timeout kicks in.
 *
 * Returning TRUE tells Windows we handled it. The parent process
 * gives us a few seconds (SCM default 5s) to actually exit before
 * TerminateProcess. */
static BOOL WINAPI on_ctrl_signal(DWORD dwCtrlType) {
    switch (dwCtrlType) {
    case CTRL_C_EVENT:
    case CTRL_BREAK_EVENT:
    case CTRL_CLOSE_EVENT:
    case CTRL_LOGOFF_EVENT:
    case CTRL_SHUTDOWN_EVENT:
        InterlockedExchange(&g_stop, 1);
        /* Write the proactive shutdown marker INLINE — by the time
         * main() reaches its cleanup we may already have been
         * TerminateProcess'd by NvDisplayContainer. The mmap stays
         * alive on the QEMU side after we die, so this single
         * release-store is enough to wake the host viewer. */
        if (g_ivs_base) {
            NvShmemHdr *hdr = (NvShmemHdr*)g_ivs_base;
            NV_SHMEM_STORE_REL(&hdr->guest_alive_tick, 0);
        }
        vlog("ctrl signal %lu — stopping (alive_tick=0 published)", dwCtrlType);
        return TRUE;
    default:
        return FALSE;
    }
}

static volatile LONG g_force_keyframe_after_overflow = 0;

/* Write one chunk into the video ring. If full, drop the whole old
 * backlog by moving reader_seq to the current writer_seq. Do not advance
 * reader_seq by arbitrary byte counts: that can land the host reader in
 * the middle of a record and poison the stream until the next reset. */
static void video_push(NvShmemHdr *hdr, uint8_t *ring, const void *data, uint32_t size) {
    int rc;
    int retries = 0;
    while ((rc = nv_shmem_write(ring, NV_SHMEM_VIDEO_BYTES, &hdr->video, data, size)) != 0) {
        retries++;
        if (retries > 5) {
            uint32_t w = NV_SHMEM_LOAD_ACQ(&hdr->video.writer_seq);
            uint32_t r = NV_SHMEM_LOAD_ACQ(&hdr->video.reader_seq);
            NV_SHMEM_STORE_REL(&hdr->video.reader_seq, w);
            InterlockedExchange(&g_force_keyframe_after_overflow, 1);
            vlog("video ring overflow, dropped backlog bytes=%u", w - r);
            retries = 0;
            continue;
        }
        Sleep(1);
    }
}

/* ──────────────────────── desktop resolution ────────────────────── */
/* Force the primary display to a specific mode before initializing
 * DDA. vGPU's default 1280×720 is too small once the host SDL2 viewer
 * sizes its window to the guest fb; 1920×1080 is the sweet spot.
 *
 * Reads HKLM\SOFTWARE\NVIDIA\DisplayContainer\Stream registry for
 * DesktopWidth + DesktopHeight (DWORDs). Skips if either is 0. */
static void apply_desktop_mode(void) {
    DWORD want_w = 0, want_h = 0;
    reg_get_dword(CFG_REG_PATH, "DesktopWidth",  &want_w);
    reg_get_dword(CFG_REG_PATH, "DesktopHeight", &want_h);
    if (want_w == 0 || want_h == 0) {
        want_w = 1920; want_h = 1080;  /* sensible default */
    }

    DEVMODEA dm = {0};
    dm.dmSize = sizeof(dm);
    if (!EnumDisplaySettingsA(NULL, ENUM_CURRENT_SETTINGS, &dm)) {
        vlog("EnumDisplaySettings failed: %lu", GetLastError());
        return;
    }
    if (dm.dmPelsWidth == want_w && dm.dmPelsHeight == want_h) {
        vlog("desktop already %lux%lu", want_w, want_h);
        return;
    }
    DWORD cur_w = dm.dmPelsWidth, cur_h = dm.dmPelsHeight;
    dm.dmPelsWidth  = want_w;
    dm.dmPelsHeight = want_h;
    dm.dmFields     = DM_PELSWIDTH | DM_PELSHEIGHT;
    LONG rc = ChangeDisplaySettingsExA(NULL, &dm, NULL, 0, NULL);
    vlog("ChangeDisplaySettings %lux%lu -> %lux%lu rc=%ld",
         cur_w, cur_h, want_w, want_h, rc);
}

/* ──────────────────────── DDA + dirty-tile capture ──────────────── */

typedef struct {
    /* DXGI / D3D11 */
    IDXGIFactory1            *factory;
    IDXGIAdapter1            *adapter;
    IDXGIOutput1             *output1;
    ID3D11Device             *d3d_dev;
    ID3D11DeviceContext      *d3d_ctx;
    IDXGIOutputDuplication   *dup;
    ID3D11Texture2D          *staging;       /* CPU-readable BGRA copy */

    UINT                      width;
    UINT                      height;

    /* DDA reports its own dirty-rect list per frame. We allocate a
     * scratch buffer sized to TotalMetadataBufferSize on demand; saves
     * us from running a per-tile hash in software. */
    BYTE                     *meta_buf;
    UINT                      meta_cap;

    /* Frame assembly buffer. Worst case is one full-screen rect, which
     * fits in width*height*4 + sizeof(NvFrameTile) + sizeof(NvFrameHdr).
     * We reserve a bit more so multi-rect bursts don't blow the cap.
     */
    uint8_t                  *frame_buf;
    uint32_t                  frame_buf_cap;
    uint32_t                  frame_seq;
    int                       force_keyframe;
    int                       staging_valid;   /* CopyResource was issued at least once */
} CaptureCtx;

#define HRSAY(call, label) do { \
    HRESULT _hr = (call); \
    if (FAILED(_hr)) { vlog("%s failed hr=0x%08lx", (label), (unsigned long)_hr); return -1; } \
} while(0)

static int dda_init(CaptureCtx *cc) {
    HRSAY(CreateDXGIFactory1(&IID_IDXGIFactory1, (void**)&cc->factory),
          "CreateDXGIFactory1");
    HRSAY(IDXGIFactory1_EnumAdapters1(cc->factory, 0, &cc->adapter),
          "EnumAdapters1");

    DXGI_ADAPTER_DESC1 ad;
    IDXGIAdapter1_GetDesc1(cc->adapter, &ad);
    vlog("DXGI adapter[0]: VendorID=0x%04x DeviceID=0x%04x", ad.VendorId, ad.DeviceId);

    IDXGIOutput *out0 = NULL;
    HRSAY(IDXGIAdapter1_EnumOutputs(cc->adapter, 0, &out0), "EnumOutputs");
    HRSAY(IDXGIOutput_QueryInterface(out0, &IID_IDXGIOutput1, (void**)&cc->output1),
          "QI IDXGIOutput1");
    IDXGIOutput_Release(out0);

    DXGI_OUTPUT_DESC od;
    IDXGIOutput1_GetDesc(cc->output1, &od);
    cc->width  = od.DesktopCoordinates.right  - od.DesktopCoordinates.left;
    cc->height = od.DesktopCoordinates.bottom - od.DesktopCoordinates.top;
    vlog("desktop: %ux%u rotation=%d", cc->width, cc->height, od.Rotation);

    D3D_FEATURE_LEVEL fls[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
    };
    D3D_FEATURE_LEVEL got;
    HRSAY(D3D11CreateDevice((IDXGIAdapter*)cc->adapter,
                            D3D_DRIVER_TYPE_UNKNOWN,
                            NULL, 0,
                            fls, sizeof(fls)/sizeof(fls[0]),
                            D3D11_SDK_VERSION,
                            &cc->d3d_dev, &got, &cc->d3d_ctx),
          "D3D11CreateDevice");
    vlog("D3D11 device feature level 0x%x", (int)got);

    HRSAY(IDXGIOutput1_DuplicateOutput(cc->output1,
                                       (IUnknown*)cc->d3d_dev,
                                       &cc->dup),
          "DuplicateOutput");

    /* Staging texture: same size + format as the DDA frame, but
     * USAGE_STAGING + CPU_ACCESS_READ so we can Map() it. */
    D3D11_TEXTURE2D_DESC td = {0};
    td.Width              = cc->width;
    td.Height             = cc->height;
    td.MipLevels          = 1;
    td.ArraySize          = 1;
    td.Format             = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count   = 1;
    td.Usage              = D3D11_USAGE_STAGING;
    td.CPUAccessFlags     = D3D11_CPU_ACCESS_READ;
    HRSAY(ID3D11Device_CreateTexture2D(cc->d3d_dev, &td, NULL, &cc->staging),
          "CreateTexture2D(staging)");

    /* Worst case is one full-screen rect: NvFrameHdr + NvFrameTile +
     * width*height*4. Add a generous slack for multi-rect bursts. */
    cc->frame_buf_cap = (uint32_t)(sizeof(NvFrameHdr)
        + 256 * sizeof(NvFrameTile)
        + (size_t)cc->width * cc->height * 4);
    cc->frame_buf = malloc(cc->frame_buf_cap);
    if (!cc->frame_buf) {
        vlog("malloc frame_buf failed"); return -1;
    }
    /* meta_buf is grown lazily on first AcquireNextFrame seeing a
     * non-zero TotalMetadataBufferSize. */
    cc->meta_buf = NULL;
    cc->meta_cap = 0;
    cc->force_keyframe = 1;  /* first frame ships everything */
    vlog("DDA dirty-rect: fb=%ux%u, frame_buf_cap=%u KB",
         cc->width, cc->height, cc->frame_buf_cap / 1024);

    /* Prime the duplication so a fresh viewer never sees black.
     * AcquireNextFrame returns WAIT_TIMEOUT forever on a perfectly
     * static desktop; without an initial frame we never CopyResource,
     * staging_valid stays 0, and the timeout-path keyframe branch
     * can't fire — so the viewer's texture stays blank until the
     * user wiggles the cursor. We try ~2s for the system's natural
     * "first frame after DuplicateOutput" push, and halfway through
     * inject a zero-motion mouse event to force a desktop redraw. */
    for (int i = 0; i < 10; i++) {
        DXGI_OUTDUPL_FRAME_INFO info;
        IDXGIResource *res = NULL;
        HRESULT hr = IDXGIOutputDuplication_AcquireNextFrame(cc->dup, 200, &info, &res);
        if (SUCCEEDED(hr)) {
            ID3D11Texture2D *src = NULL;
            HRESULT qhr = IDXGIResource_QueryInterface(res,
                &IID_ID3D11Texture2D, (void**)&src);
            if (SUCCEEDED(qhr) && src) {
                ID3D11DeviceContext_CopyResource(cc->d3d_ctx,
                    (ID3D11Resource*)cc->staging, (ID3D11Resource*)src);
                ID3D11Texture2D_Release(src);
                cc->staging_valid = 1;
                vlog("dda: primed initial frame (try=%d)", i);
            }
            IDXGIResource_Release(res);
            IDXGIOutputDuplication_ReleaseFrame(cc->dup);
            break;
        }
        if (hr != DXGI_ERROR_WAIT_TIMEOUT) {
            vlog("dda prime: AcquireNextFrame hr=0x%08lx", (unsigned long)hr);
            break;
        }
        if (i == 4) {
            INPUT in = {0};
            in.type = INPUT_MOUSE;
            in.mi.dwFlags = MOUSEEVENTF_MOVE;  /* dx=dy=0 → no visual change */
            SendInput(1, &in, sizeof(in));
            vlog("dda prime: nudged mouse (no visual move) to break static-desktop stall");
        }
    }
    return 0;
}

/* Build a FRAM message in cc->frame_buf by emitting one NvFrameTile
 * per dirty rect. No per-pixel hashing — DDA already tells us what
 * changed. */
static uint32_t build_frame(CaptureCtx *cc,
                            const D3D11_MAPPED_SUBRESOURCE *m,
                            const RECT *rects, UINT n_rects) {
    NvFrameHdr *hdr = (NvFrameHdr*)cc->frame_buf;
    hdr->magic      = NV_FRAME_MAGIC;
    hdr->frame_seq  = ++cc->frame_seq;
    hdr->fb_width   = (uint16_t)cc->width;
    hdr->fb_height  = (uint16_t)cc->height;
    hdr->tile_count = 0;
    hdr->flags      = cc->force_keyframe ? NV_FRAME_FLAG_KEYFRAME : 0;

    uint8_t *cursor = cc->frame_buf + sizeof(NvFrameHdr);
    uint8_t *cap    = cc->frame_buf + cc->frame_buf_cap;
    UINT emitted = 0;

    for (UINT i = 0; i < n_rects; i++) {
        LONG l = rects[i].left, t_ = rects[i].top;
        LONG r = rects[i].right, b = rects[i].bottom;
        if (l < 0) l = 0;
        if (t_ < 0) t_ = 0;
        if (r > (LONG)cc->width)  r = (LONG)cc->width;
        if (b > (LONG)cc->height) b = (LONG)cc->height;
        if (r <= l || b <= t_) continue;

        UINT x0 = (UINT)l, y0 = (UINT)t_;
        UINT rw = (UINT)(r - l);
        UINT rh = (UINT)(b - t_);
        if (rw > 0xFFFFu) rw = 0xFFFFu;
        if (rh > 0xFFFFu) rh = 0xFFFFu;

        /* Defensive overflow check; with DDA's non-overlapping rects
         * total area ≤ desktop area, so this should never fire. */
        size_t need = sizeof(NvFrameTile) + (size_t)rw * rh * 4;
        if ((size_t)(cap - cursor) < need) {
            vlog("frame_buf would overflow (rects=%u emitted=%u)", n_rects, emitted);
            break;
        }

        NvFrameTile *tile = (NvFrameTile*)cursor;
        tile->x = (uint16_t)x0;
        tile->y = (uint16_t)y0;
        tile->w = (uint16_t)rw;
        tile->h = (uint16_t)rh;
        cursor += sizeof(*tile);
        for (UINT j = 0; j < rh; j++) {
            memcpy(cursor,
                   (const uint8_t*)m->pData + (y0 + j) * m->RowPitch + x0 * 4,
                   (size_t)rw * 4);
            cursor += rw * 4;
        }
        emitted++;
    }
    hdr->tile_count = (uint16_t)emitted;
    cc->force_keyframe = 0;
    return (uint32_t)(cursor - cc->frame_buf);
}

/* Acquire one frame from DDA, diff into tiles, push into ring.
 *
 * Two implicit timers control "force a keyframe" behaviour:
 *   - 5 second periodic keyframe (recovers a fresh viewer that joins
 *     mid-stream when the desktop hasn't changed for a while).
 *   - host_alive_tick rising edge: when the host side starts
 *     incrementing its heartbeat after being silent, we know a new
 *     viewer just attached and immediately force a keyframe so they
 *     don't have to wait the 5 second period. */
static int capture_one(CaptureCtx *cc, NvShmemHdr *hdr, uint8_t *ring) {
    static DWORD     last_keyframe_tick = 0;
    static uint32_t  last_host_alive    = 0;

    DWORD now = GetTickCount();
    uint32_t host_alive = NV_SHMEM_LOAD_ACQ(&hdr->host_alive_tick);
    /* Rising edge or large jump (host disconnected, reconnected) */
    if ((last_host_alive == 0 && host_alive != 0) ||
        (host_alive > last_host_alive + 200)) {
        cc->force_keyframe = 1;
    }
    if (InterlockedExchange(&g_force_keyframe_after_overflow, 0)) {
        cc->force_keyframe = 1;
    }
    last_host_alive = host_alive;
    if (now - last_keyframe_tick > 5000) {
        cc->force_keyframe = 1;
    }

    DXGI_OUTDUPL_FRAME_INFO info;
    IDXGIResource *res = NULL;
    HRESULT hr = IDXGIOutputDuplication_AcquireNextFrame(cc->dup, 50, &info, &res);
    /* Debug heartbeat: every 5 s log what's happening so we don't have
     * to guess which path the loop is going down. */
    static DWORD last_diag_tick = 0;
    static DWORD diag_total = 0, diag_timeout = 0, diag_ok = 0, diag_err = 0;
    diag_total++;
    if      (hr == DXGI_ERROR_WAIT_TIMEOUT) diag_timeout++;
    else if (SUCCEEDED(hr))                 diag_ok++;
    else                                    diag_err++;
    if (now - last_diag_tick > 5000) {
        vlog("capture diag: total=%lu timeout=%lu ok=%lu err=%lu  hr=0x%08lx  staging_valid=%d  force_kf=%d  host_alive=%lu",
             diag_total, diag_timeout, diag_ok, diag_err,
             (unsigned long)hr, cc->staging_valid, cc->force_keyframe,
             (unsigned long)host_alive);
        last_diag_tick = now;
    }

    if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
        /* Idle path. If a keyframe was requested AND we have a
         * captured staging texture from a previous frame, we can
         * remap it and ship the whole frame as a single full-screen
         * rect — viewers attaching during a static-desktop pause
         * don't have to wait for the next mouse jiggle to see the
         * screen. */
        if (cc->force_keyframe && cc->staging_valid) {
            D3D11_MAPPED_SUBRESOURCE m;
            HRESULT mhr = ID3D11DeviceContext_Map(cc->d3d_ctx,
                (ID3D11Resource*)cc->staging, 0, D3D11_MAP_READ, 0, &m);
            if (SUCCEEDED(mhr)) {
                RECT full = { 0, 0, (LONG)cc->width, (LONG)cc->height };
                uint32_t msg_size = build_frame(cc, &m, &full, 1);
                ID3D11DeviceContext_Unmap(cc->d3d_ctx, (ID3D11Resource*)cc->staging, 0);
                video_push(hdr, ring, cc->frame_buf, msg_size);
                last_keyframe_tick = now;
                return 0;
            }
        }
        static DWORD last_idle_tick = 0;
        if (now - last_idle_tick > 1000) {
            last_idle_tick = now;
            NvFrameHdr h = { NV_FRAME_MAGIC, ++cc->frame_seq,
                             (uint16_t)cc->width, (uint16_t)cc->height,
                             0, 0 };
            video_push(hdr, ring, &h, sizeof(h));
        }
        return 0;
    }
    if (FAILED(hr)) { vlog("AcquireNextFrame hr=0x%08lx", (unsigned long)hr); return -1; }
    if (cc->force_keyframe) last_keyframe_tick = now;

    ID3D11Texture2D *src = NULL;
    HRESULT qhr = IDXGIResource_QueryInterface(res, &IID_ID3D11Texture2D, (void**)&src);
    IDXGIResource_Release(res);
    if (FAILED(qhr) || !src) {
        IDXGIOutputDuplication_ReleaseFrame(cc->dup);
        return -1;
    }

    /* Decide rect list. Keyframe → one full-screen rect. Else ask
     * DDA which rectangles changed; mouse-only updates surface as
     * TotalMetadataBufferSize==0 and we ship a 12-byte empty frame
     * (heartbeat). */
    RECT  full_rect = { 0, 0, (LONG)cc->width, (LONG)cc->height };
    RECT *rects     = NULL;
    UINT  n_rects   = 0;

    if (cc->force_keyframe) {
        rects   = &full_rect;
        n_rects = 1;
    } else if (info.TotalMetadataBufferSize > 0) {
        if (info.TotalMetadataBufferSize > cc->meta_cap) {
            BYTE *nb = realloc(cc->meta_buf, info.TotalMetadataBufferSize);
            if (nb) {
                cc->meta_buf = nb;
                cc->meta_cap = info.TotalMetadataBufferSize;
            }
        }
        if (cc->meta_buf && cc->meta_cap >= info.TotalMetadataBufferSize) {
            UINT used = 0;
            HRESULT dhr = IDXGIOutputDuplication_GetFrameDirtyRects(
                cc->dup, cc->meta_cap, (RECT*)cc->meta_buf, &used);
            if (SUCCEEDED(dhr) && used >= sizeof(RECT)) {
                rects   = (RECT*)cc->meta_buf;
                n_rects = used / sizeof(RECT);
            }
        }
    }

    /* No dirty area (cursor moved / no visual change) → skip the
     * GPU readback entirely and just ship a heartbeat. This is the
     * common static-desktop path and what makes CPU usage drop. */
    if (n_rects == 0) {
        ID3D11Texture2D_Release(src);
        IDXGIOutputDuplication_ReleaseFrame(cc->dup);
        NvFrameHdr h = { NV_FRAME_MAGIC, ++cc->frame_seq,
                         (uint16_t)cc->width, (uint16_t)cc->height,
                         0, 0 };
        video_push(hdr, ring, &h, sizeof(h));
        return 0;
    }

    /* GPU-side copy into staging (CPU-readable) */
    ID3D11DeviceContext_CopyResource(cc->d3d_ctx,
        (ID3D11Resource*)cc->staging, (ID3D11Resource*)src);
    ID3D11Texture2D_Release(src);
    cc->staging_valid = 1;

    D3D11_MAPPED_SUBRESOURCE m;
    HRESULT mhr = ID3D11DeviceContext_Map(cc->d3d_ctx,
        (ID3D11Resource*)cc->staging, 0, D3D11_MAP_READ, 0, &m);
    if (FAILED(mhr)) {
        IDXGIOutputDuplication_ReleaseFrame(cc->dup);
        vlog("Map staging hr=0x%08lx", (unsigned long)mhr);
        return -1;
    }

    uint32_t msg_size = build_frame(cc, &m, rects, n_rects);

    ID3D11DeviceContext_Unmap(cc->d3d_ctx, (ID3D11Resource*)cc->staging, 0);
    IDXGIOutputDuplication_ReleaseFrame(cc->dup);

    video_push(hdr, ring, cc->frame_buf, msg_size);
    return 0;
}

static void capture_cleanup(CaptureCtx *cc) {
    if (cc->staging)  ID3D11Texture2D_Release(cc->staging);
    if (cc->dup)      IDXGIOutputDuplication_Release(cc->dup);
    if (cc->d3d_ctx)  ID3D11DeviceContext_Release(cc->d3d_ctx);
    if (cc->d3d_dev)  ID3D11Device_Release(cc->d3d_dev);
    if (cc->output1)  IDXGIOutput1_Release(cc->output1);
    if (cc->adapter)  IDXGIAdapter1_Release(cc->adapter);
    if (cc->factory)  IDXGIFactory1_Release(cc->factory);
    free(cc->meta_buf);
    free(cc->frame_buf);
    memset(cc, 0, sizeof(*cc));
}

/* ──────────────────────── input forward thread ─────────────────── */
/* Drains the input ring and ships each record to AudioSvcHost over a
 * persistent local TCP socket. Reconnects on disconnect. */
static int recv_n(SOCKET s, void *buf, int n) {
    char *p = (char*)buf;
    while (n > 0) {
        int r = recv(s, p, n, 0);
        if (r <= 0) return -1;
        p += r; n -= r;
    }
    return 0;
}
static int send_n(SOCKET s, const void *buf, int n) {
    const char *p = (const char*)buf;
    while (n > 0) {
        int r = send(s, p, n, 0);
        if (r <= 0) return -1;
        p += r; n -= r;
    }
    return 0;
}

static int input_connect(SOCKET *out_s, const char *password) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
    if (s == INVALID_SOCKET) return -1;
    int on = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char*)&on, sizeof(on));
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port   = htons(INPUT_FORWARD_PORT);
    inet_pton(AF_INET, INPUT_FORWARD_HOST, &a.sin_addr);
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) < 0) {
        closesocket(s); return -1;
    }
    /* AudioSvcHost expects RFB 3.8 handshake. */
    char ver[12];
    if (recv_n(s, ver, 12) < 0) { closesocket(s); return -1; }
    if (send_n(s, "RFB 003.008\n", 12) < 0) { closesocket(s); return -1; }
    uint8_t n;
    if (recv_n(s, &n, 1) < 0 || n == 0) { closesocket(s); return -1; }
    uint8_t types[256];
    if (recv_n(s, types, n) < 0) { closesocket(s); return -1; }
    int has = 0;
    for (int i = 0; i < n; i++) if (types[i] == 2) { has = 1; break; }
    if (!has) { closesocket(s); return -1; }
    uint8_t two = 2;
    if (send_n(s, &two, 1) < 0) { closesocket(s); return -1; }
    /* DES challenge */
    uint8_t challenge[16];
    if (recv_n(s, challenge, 16) < 0) { closesocket(s); return -1; }
    uint8_t key[8] = {0};
    strncpy((char*)key, password, 8);
    vnc_flip_bits(key);
    uint8_t resp[16];
    des_crypt(key, challenge,     resp);
    des_crypt(key, challenge + 8, resp + 8);
    if (send_n(s, resp, 16) < 0) { closesocket(s); return -1; }
    uint8_t result[4];
    if (recv_n(s, result, 4) < 0) { closesocket(s); return -1; }
    if (result[3] != 0) { vlog("VncAuth fail %u", result[3]); closesocket(s); return -1; }
    /* ClientInit shared=1 */
    uint8_t shared = 1;
    if (send_n(s, &shared, 1) < 0) { closesocket(s); return -1; }
    /* read + discard ServerInit */
    uint8_t init[24];
    if (recv_n(s, init, 24) < 0) { closesocket(s); return -1; }
    uint32_t namelen = ((uint32_t)init[20]<<24)|((uint32_t)init[21]<<16)|((uint32_t)init[22]<<8)|init[23];
    char tmp[256];
    while (namelen > 0) {
        int chunk = namelen > sizeof(tmp) ? sizeof(tmp) : (int)namelen;
        if (recv_n(s, tmp, chunk) < 0) { closesocket(s); return -1; }
        namelen -= chunk;
    }
    /* SetEncodings empty (avoid AudioSvcHost waiting) */
    uint8_t setenc[4] = { 2, 0, 0, 0 };
    send_n(s, setenc, 4);
    *out_s = s;
    vlog("input forward connected to %s:%d", INPUT_FORWARD_HOST, INPUT_FORWARD_PORT);
    return 0;
}

static DWORD WINAPI input_pump(LPVOID arg) {
    const char *password = (const char *)arg;
    NvShmemHdr *hdr = (NvShmemHdr*)g_ivs_base;
    uint8_t    *ring = (uint8_t*)g_ivs_base + hdr->input_off;
    SOCKET s = INVALID_SOCKET;

    while (!g_stop) {
        if (s == INVALID_SOCKET && input_connect(&s, password) != 0) {
            Sleep(500);
            continue;
        }
        uint8_t rec[64];
        uint32_t rec_size = 0;
        int rc = nv_shmem_read(ring, NV_SHMEM_INPUT_BYTES, &hdr->input,
                               rec, sizeof(rec), &rec_size);
        if (rc == 0) { Sleep(2); continue; }   /* empty ring */
        if (rc < 0)  { Sleep(2); continue; }   /* oversize — shouldn't happen */
        if (send_n(s, rec, rec_size) < 0) {
            closesocket(s);
            s = INVALID_SOCKET;
        }
    }
    if (s != INVALID_SOCKET) closesocket(s);
    return 0;
}

/* ──────────────────────── heartbeat thread ─────────────────────── */
static DWORD WINAPI heartbeat(LPVOID arg) {
    (void)arg;
    NvShmemHdr *hdr = (NvShmemHdr*)g_ivs_base;
    while (!g_stop) {
        InterlockedIncrement((volatile LONG*)&hdr->guest_alive_tick);
        Sleep(100);
    }
    return 0;
}

/* ──────────────────────── reg helpers ──────────────────────────── */
static int reg_get_dword(const char *path, const char *name, DWORD *out) {
    HKEY h;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, path, 0, KEY_READ, &h) != ERROR_SUCCESS) return -1;
    DWORD t = 0, sz = sizeof(*out);
    LONG rc = RegQueryValueExA(h, name, NULL, &t, (BYTE*)out, &sz);
    RegCloseKey(h);
    return rc == ERROR_SUCCESS ? 0 : -1;
}
static int reg_get_sz(const char *path, const char *name, char *out, DWORD outsz) {
    HKEY h;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, path, 0, KEY_READ, &h) != ERROR_SUCCESS) return -1;
    DWORD t = 0, sz = outsz;
    LONG rc = RegQueryValueExA(h, name, NULL, &t, (BYTE*)out, &sz);
    RegCloseKey(h);
    return rc == ERROR_SUCCESS ? 0 : -1;
}

/* ──────────────────────── entry ────────────────────────────────── */
int main(int argc, char **argv) {
    (void)argc; (void)argv;
    log_init();
    vlog("=== nv_stream_relay starting (pid=%lu) ===", (unsigned long)GetCurrentProcessId());

    /* 主动关机通知 — 见 on_ctrl_signal 注释。注册必须在 ivshmem
     * mmap 之前，确保最早一次 shutdown 信号也能被接收。 */
    SetConsoleCtrlHandler(on_ctrl_signal, TRUE);

    WSADATA w; WSAStartup(MAKEWORD(2,2), &w);

    if (ivshmem_open() != 0) {
        vlog("ivshmem unavailable — exiting");
        return 1;
    }

    NvShmemHdr *hdr = (NvShmemHdr*)g_ivs_base;
    shmem_header_init(hdr);
    hdr->guest_width  = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    hdr->guest_height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    vlog("guest desktop %ux%u", hdr->guest_width, hdr->guest_height);

    /* Frame pacing from registry (set by install-nv-service.ps1).
     * Dirty-tile mode is bandwidth-adaptive — there's no bitrate
     * knob, only how often we sample the desktop. */
    DWORD framerate = CFG_DEF_FRAMERATE;
    reg_get_dword(CFG_REG_PATH, "FrameRate", &framerate);
    if (framerate < 5 || framerate > 240) framerate = CFG_DEF_FRAMERATE;
    vlog("config: framerate=%lu", framerate);

    /* AudioSvcHost VncAuth password — same default as install-custom-vnc.ps1
     * uses (registry HKLM\SOFTWARE\Microsoft\Audio\GraphHost\Password). */
    char password[64] = "123456";
    reg_get_sz("SOFTWARE\\Microsoft\\Audio\\GraphHost", "Password", password, sizeof(password));

    /* spawn helpers */
    HANDLE h_input = CreateThread(NULL, 0, input_pump, password, 0, NULL);
    HANDLE h_beat  = CreateThread(NULL, 0, heartbeat, NULL, 0, NULL);
    (void)h_input; (void)h_beat;

    uint8_t *ring = (uint8_t*)g_ivs_base + hdr->video_off;
    DWORD fail_count = 0;
    DWORD frame_us = 1000000u / framerate;

    /* Force desktop to configured resolution (default 1920x1080)
     * BEFORE the first DDA init so capture grabs the right size. */
    apply_desktop_mode();

    while (!g_stop) {
        CaptureCtx cc = {0};
        if (dda_init(&cc) != 0) {
            capture_cleanup(&cc);
            fail_count++;
            DWORD backoff = (fail_count >= 3) ? 15000 : 1000;
            vlog("capture init failed, backoff %lu ms", backoff);
            Sleep(backoff);
            continue;
        }
        fail_count = 0;
        /* Re-publish actual capture dimensions (DDA may differ from
         * SM_C{X,Y}VIRTUALSCREEN under some DPI/rotation states). */
        hdr->guest_width  = cc.width;
        hdr->guest_height = cc.height;

        /* Per-frame loop. AcquireNextFrame internally rate-limits to
         * the desktop's update cadence; we additionally Sleep to cap
         * the requested framerate when the desktop changes faster. */
        LARGE_INTEGER qf, t0, t1;
        QueryPerformanceFrequency(&qf);
        QueryPerformanceCounter(&t0);

        while (!g_stop) {
            int rc = capture_one(&cc, hdr, ring);
            if (rc < 0) { vlog("capture_one fatal — re-init"); break; }

            QueryPerformanceCounter(&t1);
            DWORD elapsed_us = (DWORD)((t1.QuadPart - t0.QuadPart) * 1000000ull / qf.QuadPart);
            if (elapsed_us < frame_us) Sleep((frame_us - elapsed_us) / 1000);
            t0 = t1;
        }
        capture_cleanup(&cc);
        Sleep(500);
    }

    vlog("=== nv_stream_relay stopping ===");
    InterlockedExchange(&g_stop, 1);

    /* 主动通告 host：写 guest_alive_tick = 0，host viewer 看到从
     * 非零跳 0 立刻 want_quit，不用等 4 秒心跳超时。这是用户在 OS
     * 关机 / "stop service" 时能立即收回 SDL 窗口的关键路径。 */
    if (g_ivs_base) {
        NvShmemHdr *hdr = (NvShmemHdr*)g_ivs_base;
        NV_SHMEM_STORE_REL(&hdr->guest_alive_tick, 0);
        vlog("guest_alive_tick = 0 (proactive shutdown notify)");
    }
    ivshmem_close();
    WSACleanup();
    return 0;
}
