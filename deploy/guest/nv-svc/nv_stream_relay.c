/*
 * nv_stream_relay.c — guest-side bridge between ffmpeg and the
 * ivshmem video/input rings.
 *
 * Replaces the old NvSvcStream worker that streamed H.264 directly
 * over a TCP listener. Now:
 *
 *   1. Open the Looking-Glass-style ivshmem PCI device (the only
 *      Windows ivshmem driver with stable IOCTLs we can rely on),
 *      DeviceIoControl REQUEST_MMAP to get a userspace pointer to
 *      the shared region.
 *   2. Initialize / validate NvShmemHdr at offset 0; advertise the
 *      guest's desktop dimensions so the host can scale input
 *      coordinates correctly.
 *   3. Spawn ffmpeg as a child process with stdout = anonymous pipe
 *      (renamed NvSvcEncoder.exe so task manager doesn't show
 *      "ffmpeg"), arguments tuned identically to the TCP path
 *      (DDA → NVENC → raw H.264 Annex-B), only difference is
 *      `-` instead of `tcp://0.0.0.0:56790?listen=1` on the output.
 *   4. Pump thread: read from ffmpeg's stdout pipe, push frames into
 *      the video ring as records (each NAL unit ≤ slot size).
 *   5. Input thread: drain the input ring, forward each RFB-shaped
 *      record (4-byte key event or 6-byte pointer event) to
 *      AudioSvcHost via local TCP 127.0.0.1:56789. AudioSvcHost
 *      doesn't need to change; from its POV input still arrives over
 *      RFB, just from localhost not from the network.
 *   6. Heartbeat tick + ffmpeg watchdog (restart on crash with backoff).
 *
 * Build: x86_64-w64-mingw32-gcc cross-compile (see build.sh).
 *        Static link, no runtime DLL footprint beyond Windows core.
 */

#define _WIN32_WINNT 0x0600
#define WIN32_LEAN_AND_MEAN
#define INITGUID    /* needed for DEFINE_GUID() to actually emit storage */
#include <windows.h>
#include <initguid.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <setupapi.h>
#include <winioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>

/* nv_shmem_proto.h is shared between host and guest source trees.
 * For mingw we copy the header into this directory's build area. */
#include "nv_shmem_proto.h"

/* ──────────────────────── identity / config ─────────────────────── */
#define LOG_PATH                "C:\\nv\\nv-stream-relay.log"
#define INPUT_FORWARD_HOST      "127.0.0.1"
#define INPUT_FORWARD_PORT      56789
/* Reuses the same ffmpeg binary the TCP-mode service spawns; only the
 * args differ (`-f h264 -` vs `-f h264 tcp:listen=1`). One file on
 * disk, two callers. */
#define ENCODER_EXE             "C:\\Windows\\System32\\NvSvcStream.exe"

/* Tuning is read from the same registry key the TCP-mode service
 * uses, for parity. */
#define CFG_REG_PATH            "SOFTWARE\\NVIDIA\\DisplayContainer\\Stream"
#define CFG_DEF_BITRATE         "10M"
#define CFG_DEF_FRAMERATE       60

/* Looking Glass ivshmem driver IOCTLs (public protocol — values are
 * stable since LG 0.7+). We don't need their .lib, just these constants
 * and the device interface GUID. */
DEFINE_GUID(GUID_DEVINTERFACE_IVSHMEM,
    0xdf576976, 0x569d, 0x4672, 0x95, 0xa0, 0xf5, 0x7e, 0x4e, 0xa0, 0xb2, 0x10);

#define IOCTL_IVSHMEM_REQUEST_PEERID   CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_IVSHMEM_REQUEST_SIZE     CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_IVSHMEM_REQUEST_MMAP     CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_IVSHMEM_RELEASE_MMAP     CTL_CODE(FILE_DEVICE_UNKNOWN, 0x804, METHOD_BUFFERED, FILE_ANY_ACCESS)

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

    /* request size first so we know what's there */
    UINT64 region_size = 0;
    DWORD ret = 0;
    if (!DeviceIoControl(h, IOCTL_IVSHMEM_REQUEST_SIZE, NULL, 0,
                         &region_size, sizeof(region_size), &ret, NULL)) {
        vlog("REQUEST_SIZE failed: %lu", GetLastError());
        CloseHandle(h); return -1;
    }
    vlog("ivshmem region size = %llu bytes", (unsigned long long)region_size);
    if (region_size < NV_SHMEM_TOTAL_BYTES) {
        vlog("ivshmem region too small (need %u)", NV_SHMEM_TOTAL_BYTES);
        CloseHandle(h); return -1;
    }

    /* mmap into our address space (write-combined for streaming write
     * performance — kernel will use WC PTEs, NUMA-friendly) */
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

/* ──────────────────────── ffmpeg child + pump ───────────────────── */
static volatile LONG g_stop = 0;

typedef struct {
    HANDLE  h_proc;
    HANDLE  h_stdout_r;
    DWORD   pid;
    DWORD   start_tick;
    DWORD   fail_count;
} EncoderChild;

static int spawn_encoder(EncoderChild *ec, int framerate, const char *bitrate) {
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    HANDLE r = NULL, w = NULL;
    if (!CreatePipe(&r, &w, &sa, 4 * 1024 * 1024)) {
        vlog("CreatePipe failed: %lu", GetLastError());
        return -1;
    }
    SetHandleInformation(r, HANDLE_FLAG_INHERIT, 0);

    char cmdline[2048];
    snprintf(cmdline, sizeof(cmdline),
        "\"%s\" -y -hide_banner -loglevel warning "
        "-filter_complex ddagrab=output_idx=0:framerate=%d,hwdownload,format=bgra "
        "-c:v h264_nvenc -preset p1 -tune ull -zerolatency 1 "
        "-rc cbr -b:v %s -maxrate %s -bufsize 500K "
        "-g %d -bf 0 -flags low_delay -fflags nobuffer -flush_packets 1 "
        "-strict experimental -f h264 -",
        ENCODER_EXE, framerate, bitrate, bitrate, framerate);

    STARTUPINFOA si = { sizeof(si) };
    si.dwFlags    = STARTF_USESTDHANDLES;
    si.hStdOutput = w;
    si.hStdError  = w;
    si.hStdInput  = NULL;
    PROCESS_INFORMATION pi = {0};

    BOOL ok = CreateProcessA(NULL, cmdline, NULL, NULL, TRUE,
                             CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    DWORD err = ok ? 0 : GetLastError();
    CloseHandle(w);  /* keep only the read end */
    if (!ok) {
        CloseHandle(r);
        vlog("CreateProcess encoder failed: %lu", err);
        return -1;
    }
    CloseHandle(pi.hThread);

    ec->h_proc     = pi.hProcess;
    ec->h_stdout_r = r;
    ec->pid        = pi.dwProcessId;
    ec->start_tick = GetTickCount();
    vlog("encoder spawned pid=%lu (fr=%d br=%s)", ec->pid, framerate, bitrate);
    return 0;
}

static void kill_encoder(EncoderChild *ec) {
    if (ec->h_proc) {
        TerminateProcess(ec->h_proc, 0);
        WaitForSingleObject(ec->h_proc, 2000);
        CloseHandle(ec->h_proc);
        ec->h_proc = NULL;
    }
    if (ec->h_stdout_r) {
        CloseHandle(ec->h_stdout_r);
        ec->h_stdout_r = NULL;
    }
}

/* Write one chunk into the video ring. If full, drop oldest by
 * spinning until reader catches up — for video, dropping is better
 * than blocking the encoder. */
static void video_push(NvShmemHdr *hdr, uint8_t *ring, const void *data, uint32_t size) {
    int rc;
    int retries = 0;
    while ((rc = nv_shmem_write(ring, NV_SHMEM_VIDEO_BYTES, &hdr->video, data, size)) != 0) {
        retries++;
        if (retries > 50) {  /* ~50 ms blocked */
            /* hard drop: advance reader_seq enough to make room. We
             * lose frames but never block the encoder thread. */
            uint32_t free = nv_shmem_ring_free(hdr->video.writer_seq,
                                               hdr->video.reader_seq,
                                               NV_SHMEM_VIDEO_BYTES);
            if (free < size + 4) {
                uint32_t need = (size + 4) - free + 16;
                NV_SHMEM_STORE_REL(&hdr->video.reader_seq, hdr->video.reader_seq + need);
                vlog("video ring overflow, dropped %u bytes", need);
            }
            retries = 0;
            continue;
        }
        Sleep(1);
    }
}

static DWORD WINAPI video_pump(LPVOID arg) {
    EncoderChild *ec = (EncoderChild*)arg;
    NvShmemHdr *hdr = (NvShmemHdr*)g_ivs_base;
    uint8_t    *ring = (uint8_t*)g_ivs_base + hdr->video_off;

    /* Read ffmpeg stdout in chunks. Each read may contain several
     * NAL units glued together (raw Annex-B); we forward them as a
     * single record per ReadFile to minimize overhead. The decoder
     * on the other side splits NALs by the 00 00 00 01 start code. */
    uint8_t buf[256 * 1024];
    while (!g_stop) {
        DWORD nread = 0;
        BOOL ok = ReadFile(ec->h_stdout_r, buf, sizeof(buf), &nread, NULL);
        if (!ok || nread == 0) {
            DWORD ec_code = GetLastError();
            vlog("ffmpeg pipe ended (err=%lu)", ec_code);
            break;
        }
        video_push(hdr, ring, buf, nread);
    }
    return 0;
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

    /* tuning from registry, defaults match TCP-mode service */
    char  bitrate[32]   = CFG_DEF_BITRATE;
    DWORD framerate     = CFG_DEF_FRAMERATE;
    reg_get_sz   (CFG_REG_PATH, "Bitrate",   bitrate, sizeof(bitrate));
    reg_get_dword(CFG_REG_PATH, "FrameRate", &framerate);
    if (framerate < 5 || framerate > 240) framerate = CFG_DEF_FRAMERATE;
    vlog("config: bitrate=%s framerate=%lu", bitrate, framerate);

    /* AudioSvcHost VncAuth password — same default as install-custom-vnc.ps1
     * uses (registry HKLM\SOFTWARE\Microsoft\Audio\GraphHost\Password). */
    char password[64] = "123456";
    reg_get_sz("SOFTWARE\\Microsoft\\Audio\\GraphHost", "Password", password, sizeof(password));

    /* spawn helpers + watchdog loop */
    HANDLE h_input = CreateThread(NULL, 0, input_pump, password, 0, NULL);
    HANDLE h_beat  = CreateThread(NULL, 0, heartbeat, NULL, 0, NULL);
    (void)h_input; (void)h_beat;

    EncoderChild ec = {0};
    while (!g_stop) {
        if (spawn_encoder(&ec, framerate, bitrate) != 0) {
            ec.fail_count++;
            DWORD backoff = (ec.fail_count >= 3) ? 15000 : 1000;
            vlog("encoder spawn failed, backoff %lu ms", backoff);
            Sleep(backoff);
            continue;
        }
        ec.fail_count = 0;
        HANDLE h_pump = CreateThread(NULL, 0, video_pump, &ec, 0, NULL);
        WaitForSingleObject(ec.h_proc, INFINITE);
        DWORD code = 0; GetExitCodeProcess(ec.h_proc, &code);
        vlog("encoder exited code=%lu, restarting", code);
        kill_encoder(&ec);
        WaitForSingleObject(h_pump, 2000);
        CloseHandle(h_pump);
        Sleep(500);
    }

    vlog("=== nv_stream_relay stopping ===");
    InterlockedExchange(&g_stop, 1);
    kill_encoder(&ec);
    ivshmem_close();
    WSACleanup();
    return 0;
}
