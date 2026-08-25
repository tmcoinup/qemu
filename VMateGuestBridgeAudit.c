#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define VMATE_SERVICE_NAME L"VMateBridgeAudit"
#define VMATE_OUTPUT_DIR L"C:\\VMateAudit"
#define VMATE_OUTPUT_PATH L"C:\\VMateAudit\\bridge-audit.json"
#define VMATE_BUFFER_SIZE 36

static SERVICE_STATUS_HANDLE service_handle;
static SERVICE_STATUS service_status;

typedef struct {
    uint64_t rax;
    uint64_t rcx;
    uint64_t rdx;
    uint64_t r8;
    uint64_t r9;
    uint64_t r10;
    uint64_t r11;
    uint64_t r12;
} vmate_bridge_request;

static uint32_t invoke_bridge(vmate_bridge_request *request,
                              uint32_t *out_ebx,
                              uint32_t *out_ecx,
                              uint32_t *out_edx)
{
    uint64_t rax = request->rax;
    uint64_t rcx = request->rcx;
    uint64_t rdx = request->rdx;
    uint32_t rbx;
    register uint64_t r8_value __asm__("r8") = request->r8;
    register uint64_t r9_value __asm__("r9") = request->r9;
    register uint64_t r10_value __asm__("r10") = request->r10;
    register uint64_t r11_value __asm__("r11") = request->r11;
    register uint64_t r12_value __asm__("r12") = request->r12;

    __asm__ volatile(
        "cpuid"
        : "+a"(rax), "=b"(rbx), "+c"(rcx), "+d"(rdx),
          "+r"(r8_value), "+r"(r9_value), "+r"(r10_value),
          "+r"(r11_value), "+r"(r12_value)
        :
        : "memory");
    *out_ebx = rbx;
    *out_ecx = (uint32_t)rcx;
    *out_edx = (uint32_t)rdx;
    return (uint32_t)rax;
}

static void invoke_cpuid(uint32_t leaf, uint32_t subleaf,
                         uint32_t *eax, uint32_t *ebx,
                         uint32_t *ecx, uint32_t *edx)
{
    uint32_t a = leaf;
    uint32_t b;
    uint32_t c = subleaf;
    uint32_t d;

    __asm__ volatile(
        "cpuid"
        : "+a"(a), "=b"(b), "+c"(c), "=d"(d)
        :
        : "memory");
    *eax = a;
    *ebx = b;
    *ecx = c;
    *edx = d;
}

static int write_audit(void)
{
    unsigned char buffer[VMATE_BUFFER_SIZE];
    vmate_bridge_request request;
    uint32_t eax;
    uint32_t ebx;
    uint32_t ecx;
    uint32_t edx;
    uint32_t cpuid_words[12];
    char cpu_brand[49];
    FILE *output;
    size_t index;

    ZeroMemory(buffer, sizeof(buffer));
    ZeroMemory(&request, sizeof(request));
    request.rax = UINT64_C(0x0051530d);
    request.rcx = UINT64_C(6);
    request.rdx = (uintptr_t)buffer;
    eax = invoke_bridge(&request, &ebx, &ecx, &edx);

    ZeroMemory(cpuid_words, sizeof(cpuid_words));
    for (index = 0; index < 3; ++index) {
        invoke_cpuid(0x80000002U + (uint32_t)index, 0,
                     &cpuid_words[index * 4],
                     &cpuid_words[index * 4 + 1],
                     &cpuid_words[index * 4 + 2],
                     &cpuid_words[index * 4 + 3]);
    }
    CopyMemory(cpu_brand, cpuid_words, sizeof(cpuid_words));
    cpu_brand[48] = '\0';
    for (index = 0; index < 48; ++index) {
        unsigned char character = (unsigned char)cpu_brand[index];
        if (character < 0x20 || character > 0x7e ||
            character == '"' || character == '\\') {
            cpu_brand[index] = character == 0 ? ' ' : '?';
        }
    }

    if (!CreateDirectoryW(VMATE_OUTPUT_DIR, NULL) &&
        GetLastError() != ERROR_ALREADY_EXISTS) {
        return 2;
    }
    output = _wfopen(VMATE_OUTPUT_PATH, L"wb");
    if (output == NULL) {
        return 3;
    }
    fprintf(output,
            "{\"SchemaVersion\":1,\"RequestEax\":\"0x%08X\","
            "\"Operation\":6,\"Result\":{\"Eax\":\"0x%08X\","
            "\"Ebx\":\"0x%08X\",\"Ecx\":\"0x%08X\","
            "\"Edx\":\"0x%08X\"},\"CpuBrand\":\"%.*s\","
            "\"CpuBrandHex\":\"",
            0x0051530dU, eax, ebx, ecx, edx, 48, cpu_brand);
    for (index = 0; index < sizeof(cpuid_words); ++index) {
        fprintf(output, "%02X", ((unsigned char *)cpuid_words)[index]);
    }
    fprintf(output, "\",\"Buffer\":\"");
    for (index = 0; index < sizeof(buffer); ++index) {
        fprintf(output, "%02X", buffer[index]);
    }
    fprintf(output, "\"}\r\n");
    if (fflush(output) != 0 || fclose(output) != 0) {
        return 4;
    }
    return 0;
}

static int request_shutdown(void)
{
    HANDLE token = NULL;
    TOKEN_PRIVILEGES privileges;
    LUID luid;
    BOOL initiated;

    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES |
                          TOKEN_QUERY, &token)) {
        return 10;
    }
    if (!LookupPrivilegeValueW(NULL, SE_SHUTDOWN_NAME, &luid)) {
        CloseHandle(token);
        return 11;
    }
    ZeroMemory(&privileges, sizeof(privileges));
    privileges.PrivilegeCount = 1;
    privileges.Privileges[0].Luid = luid;
    privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (!AdjustTokenPrivileges(token, FALSE, &privileges, 0, NULL, NULL) ||
        GetLastError() == ERROR_NOT_ALL_ASSIGNED) {
        CloseHandle(token);
        return 12;
    }
    CloseHandle(token);
    initiated = InitiateSystemShutdownExW(
        NULL, L"VMate one-time bridge audit completed.", 5, TRUE, FALSE,
        SHTDN_REASON_MAJOR_OPERATINGSYSTEM |
        SHTDN_REASON_MINOR_RECONFIG |
        SHTDN_REASON_FLAG_PLANNED);
    return initiated ? 0 : 13;
}

static void report_service_state(DWORD state, DWORD exit_code,
                                 DWORD wait_hint)
{
    service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    service_status.dwCurrentState = state;
    service_status.dwControlsAccepted =
        state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP |
            SERVICE_ACCEPT_SHUTDOWN : 0;
    service_status.dwWin32ExitCode = exit_code;
    service_status.dwServiceSpecificExitCode = 0;
    service_status.dwCheckPoint = 0;
    service_status.dwWaitHint = wait_hint;
    SetServiceStatus(service_handle, &service_status);
}

static void WINAPI service_control(DWORD control)
{
    if (control == SERVICE_CONTROL_STOP ||
        control == SERVICE_CONTROL_SHUTDOWN) {
        report_service_state(SERVICE_STOPPED, NO_ERROR, 0);
    }
}

static void WINAPI service_main(DWORD argc, wchar_t **argv)
{
    int audit_result;
    int shutdown_result;

    (void)argc;
    (void)argv;
    service_handle = RegisterServiceCtrlHandlerW(VMATE_SERVICE_NAME,
                                                  service_control);
    if (service_handle == NULL) {
        return;
    }
    report_service_state(SERVICE_RUNNING, NO_ERROR, 0);
    audit_result = write_audit();
    shutdown_result = audit_result == 0 ? request_shutdown() : 0;
    if (audit_result == 0 && shutdown_result == 0) {
        report_service_state(SERVICE_STOP_PENDING, NO_ERROR, 10000);
        Sleep(10000);
        report_service_state(SERVICE_STOPPED, NO_ERROR, 0);
        return;
    }
    report_service_state(SERVICE_STOPPED,
                         audit_result != 0 ? ERROR_WRITE_FAULT :
                         ERROR_SHUTDOWN_IN_PROGRESS, 0);
}

int wmain(int argc, wchar_t **argv)
{
    SERVICE_TABLE_ENTRYW service_table[] = {
        { (LPWSTR)VMATE_SERVICE_NAME, service_main },
        { NULL, NULL }
    };

    if (argc == 2 && lstrcmpiW(argv[1], L"--console") == 0) {
        return write_audit();
    }
    if (!StartServiceCtrlDispatcherW(service_table)) {
        return (int)GetLastError();
    }
    return 0;
}
