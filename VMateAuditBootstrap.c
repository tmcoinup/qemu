#define UNICODE
#define _UNICODE

#include <windows.h>
#include <stdio.h>

static const wchar_t service_name[] = L"VMateDisplayAuditOnce";
static SERVICE_STATUS_HANDLE status_handle;
static SERVICE_STATUS service_status;

static void write_result(const wchar_t *stage, DWORD code)
{
    FILE *file = _wfopen(L"C:\\VMateAudit\\bootstrap-result.txt", L"a");

    if (file == NULL) {
        return;
    }
    fwprintf(file, L"%ls=%lu powershell_attr=%lu script_attr=%lu cwd_attr=%lu\n",
             stage, (unsigned long)code,
             (unsigned long)GetFileAttributesW(
                 L"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
             (unsigned long)GetFileAttributesW(
                 L"C:\\VMateAudit\\Audit-VMateGuestDisplayStack.ps1"),
             (unsigned long)GetFileAttributesW(L"C:\\VMateAudit"));
    fclose(file);
}

static void set_status(DWORD state, DWORD win32_exit_code, DWORD wait_hint)
{
    service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    service_status.dwCurrentState = state;
    service_status.dwControlsAccepted = state == SERVICE_START_PENDING ? 0 :
        SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    service_status.dwWin32ExitCode = win32_exit_code;
    service_status.dwServiceSpecificExitCode = 0;
    service_status.dwCheckPoint = state == SERVICE_START_PENDING ? 1 : 0;
    service_status.dwWaitHint = wait_hint;
    if (status_handle != NULL) {
        SetServiceStatus(status_handle, &service_status);
    }
}

static void delete_service_registration(void)
{
    SC_HANDLE manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    SC_HANDLE service;

    if (manager == NULL) {
        return;
    }
    service = OpenServiceW(manager, service_name, DELETE);
    if (service != NULL) {
        DeleteService(service);
        CloseServiceHandle(service);
    }
    CloseServiceHandle(manager);
}

static DWORD run_audit(void)
{
    const wchar_t application[] =
        L"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
    wchar_t command[] =
        L"\"powershell.exe\" "
        L"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass "
        L"-File C:\\VMateAudit\\Audit-VMateGuestDisplayStack.ps1 "
        L"-OutputPath C:\\VMateAudit\\display-stack.json "
        L"-Endpoint http://192.168.160.1:8766/pc01";
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD exit_code = ERROR_PROCESS_ABORTED;

    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    if (!CreateProcessW(application, command, NULL, NULL, FALSE,
                        CREATE_NO_WINDOW, NULL, L"C:\\VMateAudit",
                        &startup, &process)) {
        exit_code = GetLastError();
        write_result(L"CreateProcess", exit_code);
        return exit_code;
    }
    WaitForSingleObject(process.hProcess, 10 * 60 * 1000);
    if (!GetExitCodeProcess(process.hProcess, &exit_code) ||
        exit_code == STILL_ACTIVE) {
        TerminateProcess(process.hProcess, ERROR_TIMEOUT);
        exit_code = ERROR_TIMEOUT;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    write_result(L"PowerShellExit", exit_code);
    return exit_code;
}

static DWORD WINAPI service_control(DWORD control, DWORD event_type,
                                    void *event_data, void *context)
{
    (void)event_type;
    (void)event_data;
    (void)context;
    if (control == SERVICE_CONTROL_STOP ||
        control == SERVICE_CONTROL_SHUTDOWN) {
        set_status(SERVICE_STOP_PENDING, NO_ERROR, 5000);
    }
    return NO_ERROR;
}

static void WINAPI service_main(DWORD argc, wchar_t **argv)
{
    DWORD result;

    (void)argc;
    (void)argv;
    status_handle = RegisterServiceCtrlHandlerExW(service_name,
                                                   service_control, NULL);
    if (status_handle == NULL) {
        return;
    }
    set_status(SERVICE_START_PENDING, NO_ERROR, 10 * 60 * 1000);
    set_status(SERVICE_RUNNING, NO_ERROR, 0);
    result = run_audit();
    delete_service_registration();
    write_result(L"ServiceComplete", result);
    set_status(SERVICE_STOPPED, NO_ERROR, 0);
}

int wmain(void)
{
    SERVICE_TABLE_ENTRYW table[] = {
        { (wchar_t *)service_name, service_main },
        { NULL, NULL }
    };

    if (!StartServiceCtrlDispatcherW(table)) {
        return (int)GetLastError();
    }
    return 0;
}
