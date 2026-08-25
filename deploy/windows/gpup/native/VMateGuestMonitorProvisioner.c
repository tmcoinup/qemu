#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <cfgmgr32.h>
#include <setupapi.h>
#include <stdio.h>
#include <wchar.h>

#define VMATE_SERVICE_NAME L"VMateP11GuestProvisioner"
#define VMATE_MONITOR_INSTANCE_PREFIX L"ROOT\\VMATEP11MONITOR\\"
#define VMATE_MONITOR_DESCRIPTION L"VMate P-11 Virtual Console Monitor"
#define VMATE_STATUS_CAPACITY 4096

static const GUID vmate_monitor_class = {
    0x4d36e96e, 0xe325, 0x11ce,
    {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};
static SERVICE_STATUS_HANDLE vmate_service_handle;
static SERVICE_STATUS vmate_service_status;

typedef struct VMATE_MONITOR_RESULT {
    BOOL created;
    BOOL reboot_required;
    DWORD error;
    WCHAR instance_id[MAX_DEVICE_ID_LEN];
} VMATE_MONITOR_RESULT;

static BOOL vmate_is_owned_monitor(const WCHAR *instance_id)
{
    const size_t prefix_length = wcslen(VMATE_MONITOR_INSTANCE_PREFIX);
    return _wcsnicmp(instance_id, VMATE_MONITOR_INSTANCE_PREFIX,
                     prefix_length) == 0;
}

static BOOL vmate_is_healthy_monitor(SP_DEVINFO_DATA *device)
{
    ULONG status = 0;
    ULONG problem = 0;

    if (CM_Get_DevNode_Status(&status, &problem, device->DevInst, 0) !=
        CR_SUCCESS) {
        return FALSE;
    }
    return problem == 0;
}

static DWORD vmate_scan_owned_monitors(WCHAR *instance_id,
                                       DWORD instance_capacity,
                                       DWORD *count, DWORD *healthy_count)
{
    HDEVINFO devices;
    SP_DEVINFO_DATA device;
    DWORD index;
    DWORD enumeration_error;

    *count = 0;
    *healthy_count = 0;
    instance_id[0] = L'\0';
    /* Include non-present VMate nodes so repeated guest boots do not leave
     * hidden historical Monitor instances behind. */
    devices = SetupDiGetClassDevsW(&vmate_monitor_class, NULL, NULL, 0);
    if (devices == INVALID_HANDLE_VALUE) {
        return GetLastError();
    }
    ZeroMemory(&device, sizeof(device));
    device.cbSize = sizeof(device);
    for (index = 0; SetupDiEnumDeviceInfo(devices, index, &device); ++index) {
        WCHAR current_id[MAX_DEVICE_ID_LEN];

        if (!SetupDiGetDeviceInstanceIdW(devices, &device, current_id,
                                         MAX_DEVICE_ID_LEN, NULL) ||
            !vmate_is_owned_monitor(current_id)) {
            device.cbSize = sizeof(device);
            continue;
        }
        ++*count;
        if (vmate_is_healthy_monitor(&device)) {
            ++*healthy_count;
            if (instance_id[0] == L'\0') {
                wcsncpy(instance_id, current_id, instance_capacity - 1);
                instance_id[instance_capacity - 1] = L'\0';
            }
        }
        device.cbSize = sizeof(device);
    }
    enumeration_error = GetLastError();
    SetupDiDestroyDeviceInfoList(devices);
    return enumeration_error == ERROR_NO_MORE_ITEMS ? ERROR_SUCCESS
                                                     : enumeration_error;
}

static DWORD vmate_remove_owned_monitors(void)
{
    HDEVINFO devices;
    SP_DEVINFO_DATA device;
    DWORD index;

    devices = SetupDiGetClassDevsW(&vmate_monitor_class, NULL, NULL, 0);
    if (devices == INVALID_HANDLE_VALUE) {
        return GetLastError();
    }
    ZeroMemory(&device, sizeof(device));
    device.cbSize = sizeof(device);
    for (index = 0; SetupDiEnumDeviceInfo(devices, index, &device); ++index) {
        WCHAR current_id[MAX_DEVICE_ID_LEN];
        SP_REMOVEDEVICE_PARAMS remove;

        if (!SetupDiGetDeviceInstanceIdW(devices, &device, current_id,
                                         MAX_DEVICE_ID_LEN, NULL) ||
            !vmate_is_owned_monitor(current_id)) {
            device.cbSize = sizeof(device);
            continue;
        }
        ZeroMemory(&remove, sizeof(remove));
        remove.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
        remove.ClassInstallHeader.InstallFunction = DIF_REMOVE;
        remove.Scope = DI_REMOVEDEVICE_GLOBAL;
        if (!SetupDiSetClassInstallParamsW(
                devices, &device, &remove.ClassInstallHeader,
                sizeof(remove)) ||
            !SetupDiCallClassInstaller(DIF_REMOVE, devices, &device)) {
            DWORD error = GetLastError();
            SetupDiDestroyDeviceInfoList(devices);
            return error;
        }
        device.cbSize = sizeof(device);
    }
    SetupDiDestroyDeviceInfoList(devices);
    return ERROR_SUCCESS;
}

static DWORD vmate_create_root_monitor(WCHAR *instance_id,
                                       DWORD instance_capacity)
{
    HDEVINFO devices;
    SP_DEVINFO_DATA device;
    devices = SetupDiCreateDeviceInfoList(&vmate_monitor_class, NULL);
    if (devices == INVALID_HANDLE_VALUE) {
        return GetLastError();
    }
    ZeroMemory(&device, sizeof(device));
    device.cbSize = sizeof(device);
    if (!SetupDiCreateDeviceInfoW(
            devices, L"VMateP11Monitor", &vmate_monitor_class,
            VMATE_MONITOR_DESCRIPTION, NULL, DICD_GENERATE_ID, &device) ||
        !SetupDiCallClassInstaller(DIF_REGISTERDEVICE, devices, &device)) {
        DWORD error = GetLastError();
        SetupDiDestroyDeviceInfoList(devices);
        return error;
    }
    if (!SetupDiGetDeviceInstanceIdW(devices, &device, instance_id,
                                     instance_capacity, NULL)) {
        DWORD error = GetLastError();
        SetupDiDestroyDeviceInfoList(devices);
        return error;
    }
    SetupDiDestroyDeviceInfoList(devices);
    return ERROR_SUCCESS;
}

static VMATE_MONITOR_RESULT vmate_ensure_monitor(void)
{
    VMATE_MONITOR_RESULT result;
    DWORD count = 0;
    DWORD healthy_count = 0;

    ZeroMemory(&result, sizeof(result));
    result.error = vmate_scan_owned_monitors(
        result.instance_id, MAX_DEVICE_ID_LEN, &count, &healthy_count);
    if (result.error != ERROR_SUCCESS) {
        return result;
    }
    if (count == 1 && healthy_count == 1) {
        return result;
    }
    if (count != 0) {
        result.error = vmate_remove_owned_monitors();
        if (result.error != ERROR_SUCCESS) {
            return result;
        }
        Sleep(250);
    }
    result.error = vmate_create_root_monitor(
        result.instance_id, MAX_DEVICE_ID_LEN);
    result.created = result.error == ERROR_SUCCESS;
    if (result.error == ERROR_SUCCESS) {
        result.error = vmate_scan_owned_monitors(
            result.instance_id, MAX_DEVICE_ID_LEN, &count, &healthy_count);
    }
    if (result.error == ERROR_SUCCESS &&
        (count != 1 || healthy_count != 1)) {
        result.error = ERROR_DEVICE_NOT_AVAILABLE;
    }
    return result;
}

static void vmate_json_escape(const WCHAR *source, WCHAR *target,
                              size_t capacity)
{
    size_t used = 0;

    while (*source && used + 2 < capacity) {
        if (*source == L'\\' || *source == L'\"') {
            target[used++] = L'\\';
        }
        target[used++] = *source++;
    }
    target[used] = L'\0';
}

static void vmate_write_status(const VMATE_MONITOR_RESULT *result,
                               WCHAR *json, size_t json_capacity)
{
    WCHAR program_data[MAX_PATH];
    WCHAR directory[MAX_PATH];
    WCHAR path[MAX_PATH];
    WCHAR temporary[MAX_PATH];
    WCHAR escaped_id[MAX_DEVICE_ID_LEN * 2];
    HANDLE file;
    DWORD bytes_written = 0;
    int utf8_size;
    char *utf8;

    vmate_json_escape(result->instance_id, escaped_id,
                      sizeof(escaped_id) / sizeof(escaped_id[0]));
    _snwprintf(json, json_capacity - 1,
               L"{\"schemaVersion\":1,\"contractId\":\"vmate-p11-guest-monitor-v1\"," 
               L"\"ready\":%s,\"created\":%s,\"rebootRequired\":%s," 
               L"\"error\":%lu,\"instanceId\":\"%s\"}\r\n",
               result->error == ERROR_SUCCESS ? L"true" : L"false",
               result->created ? L"true" : L"false",
               result->reboot_required ? L"true" : L"false",
               result->error, escaped_id);
    json[json_capacity - 1] = L'\0';
    if (!GetEnvironmentVariableW(L"ProgramData", program_data, MAX_PATH)) {
        return;
    }
    _snwprintf(directory, MAX_PATH - 1, L"%s\\VMate", program_data);
    directory[MAX_PATH - 1] = L'\0';
    CreateDirectoryW(directory, NULL);
    _snwprintf(directory, MAX_PATH - 1, L"%s\\VMate\\GuestProvisioner",
               program_data);
    directory[MAX_PATH - 1] = L'\0';
    CreateDirectoryW(directory, NULL);
    _snwprintf(path, MAX_PATH - 1, L"%s\\monitor-status.json", directory);
    _snwprintf(temporary, MAX_PATH - 1, L"%s\\.monitor-status.tmp",
               directory);
    path[MAX_PATH - 1] = L'\0';
    temporary[MAX_PATH - 1] = L'\0';
    utf8_size = WideCharToMultiByte(CP_UTF8, 0, json, -1, NULL, 0,
                                    NULL, NULL);
    if (utf8_size <= 1) {
        return;
    }
    utf8 = (char *)HeapAlloc(GetProcessHeap(), 0, (SIZE_T)utf8_size);
    if (!utf8) {
        return;
    }
    WideCharToMultiByte(CP_UTF8, 0, json, -1, utf8, utf8_size, NULL, NULL);
    file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE) {
        WriteFile(file, utf8, (DWORD)(utf8_size - 1), &bytes_written, NULL);
        FlushFileBuffers(file);
        CloseHandle(file);
        MoveFileExW(temporary, path,
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    }
    HeapFree(GetProcessHeap(), 0, utf8);
}

static void vmate_report_service(DWORD state, DWORD win32_exit,
                                 DWORD wait_hint)
{
    vmate_service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    vmate_service_status.dwCurrentState = state;
    vmate_service_status.dwControlsAccepted =
        state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
                                 : 0;
    vmate_service_status.dwWin32ExitCode = win32_exit;
    vmate_service_status.dwServiceSpecificExitCode = 0;
    vmate_service_status.dwCheckPoint =
        state == SERVICE_START_PENDING ? 1 : 0;
    vmate_service_status.dwWaitHint = wait_hint;
    if (vmate_service_handle) {
        SetServiceStatus(vmate_service_handle, &vmate_service_status);
    }
}

static DWORD WINAPI vmate_service_control(DWORD control, DWORD event_type,
                                          void *event_data, void *context)
{
    (void)event_type;
    (void)event_data;
    (void)context;
    if (control == SERVICE_CONTROL_STOP ||
        control == SERVICE_CONTROL_SHUTDOWN) {
        vmate_report_service(SERVICE_STOPPED, ERROR_CANCELLED, 0);
    }
    return NO_ERROR;
}

static void WINAPI vmate_service_main(DWORD argc, WCHAR **argv)
{
    VMATE_MONITOR_RESULT result;
    WCHAR json[VMATE_STATUS_CAPACITY];

    (void)argc;
    (void)argv;
    vmate_service_handle = RegisterServiceCtrlHandlerExW(
        VMATE_SERVICE_NAME, vmate_service_control, NULL);
    if (!vmate_service_handle) {
        return;
    }
    ZeroMemory(&vmate_service_status, sizeof(vmate_service_status));
    vmate_report_service(SERVICE_START_PENDING, NO_ERROR, 30000);
    vmate_report_service(SERVICE_RUNNING, NO_ERROR, 0);
    result = vmate_ensure_monitor();
    vmate_write_status(&result, json, VMATE_STATUS_CAPACITY);
    vmate_report_service(SERVICE_STOPPED, result.error, 0);
}

int wmain(int argc, WCHAR **argv)
{
    VMATE_MONITOR_RESULT result;
    WCHAR json[VMATE_STATUS_CAPACITY];
    SERVICE_TABLE_ENTRYW table[] = {
        {VMATE_SERVICE_NAME, vmate_service_main}, {NULL, NULL}};

    if (argc > 1 && _wcsicmp(argv[1], L"--ensure-monitor") == 0) {
        result = vmate_ensure_monitor();
        vmate_write_status(&result, json, VMATE_STATUS_CAPACITY);
        fputws(json, stdout);
        return result.error == ERROR_SUCCESS ? 0 : (int)result.error;
    }
    if (!StartServiceCtrlDispatcherW(table)) {
        return (int)GetLastError();
    }
    return 0;
}
