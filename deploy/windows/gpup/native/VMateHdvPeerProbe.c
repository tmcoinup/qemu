/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Hyper-V HCS/HDV peer-authorization probe.
 *
 * The default operation only opens and closes an existing compute system.
 * The explicitly requested --initialize-hdv operation temporarily associates
 * this process as an external device host, performs read-only VID partition-ID
 * queries against handles duplicated from one selected vmwp.exe, and then
 * tears the device host down. It never registers CPUID results or changes a
 * persistent VM configuration.
 */

#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00

#include <windows.h>
#include <objbase.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#ifndef LOAD_LIBRARY_SEARCH_SYSTEM32
#define LOAD_LIBRARY_SEARCH_SYSTEM32 0x00000800
#endif

#define VMATE_SYSTEM_EXTENDED_HANDLE_INFORMATION 64
#define VMATE_STATUS_INFO_LENGTH_MISMATCH ((LONG)0xC0000004L)
#define VMATE_MAX_HANDLE_BUFFER (128u * 1024u * 1024u)
#define VMATE_MAX_PARTITION_HITS 64u

typedef LONG NTSTATUS;
typedef HANDLE VMATE_HCS_SYSTEM;
typedef HANDLE VMATE_HCS_OPERATION;
typedef HANDLE VMATE_HDV_HOST;

typedef HRESULT (WINAPI *VMATE_HCS_OPEN_COMPUTE_SYSTEM)(
    PCWSTR id,
    DWORD requested_access,
    VMATE_HCS_SYSTEM *compute_system);

typedef void (WINAPI *VMATE_HCS_CLOSE_COMPUTE_SYSTEM)(
    VMATE_HCS_SYSTEM compute_system);

typedef VMATE_HCS_OPERATION (WINAPI *VMATE_HCS_CREATE_OPERATION)(
    const void *context,
    void *callback);

typedef void (WINAPI *VMATE_HCS_CLOSE_OPERATION)(
    VMATE_HCS_OPERATION operation);

typedef HRESULT (WINAPI *VMATE_HCS_MODIFY_COMPUTE_SYSTEM)(
    VMATE_HCS_SYSTEM compute_system,
    VMATE_HCS_OPERATION operation,
    PCWSTR configuration,
    HANDLE identity);

typedef HRESULT (WINAPI *VMATE_HCS_WAIT_FOR_OPERATION_RESULT)(
    VMATE_HCS_OPERATION operation,
    DWORD timeout_ms,
    PWSTR *result_document);

typedef HRESULT (WINAPI *VMATE_HDV_INITIALIZE_DEVICE_HOST)(
    VMATE_HCS_SYSTEM compute_system,
    VMATE_HDV_HOST *device_host);

typedef HRESULT (WINAPI *VMATE_HDV_TEARDOWN_DEVICE_HOST)(
    VMATE_HDV_HOST device_host);

typedef HRESULT (WINAPI *VMATE_HDV_CREATE_DEVICE_INSTANCE)(
    VMATE_HDV_HOST device_host,
    int device_type,
    const GUID *device_class_id,
    const GUID *device_instance_id,
    const void *device_interface,
    const void *device_context,
    void **device_handle);

typedef HRESULT (CALLBACK *VMATE_HDV_PCI_DEVICE_INITIALIZE)(
    const void *device_context);
typedef void (CALLBACK *VMATE_HDV_PCI_DEVICE_TEARDOWN)(
    const void *device_context);
typedef HRESULT (CALLBACK *VMATE_HDV_PCI_DEVICE_SET_CONFIGURATION)(
    const void *device_context,
    uint32_t configuration_value_count,
    PCWSTR const *configuration_values);

typedef struct VMATE_HDV_PCI_PNP_ID {
    uint16_t vendor_id;
    uint16_t device_id;
    uint8_t revision_id;
    uint8_t programming_interface;
    uint8_t subclass;
    uint8_t base_class;
    uint16_t sub_vendor_id;
    uint16_t subsystem_id;
} VMATE_HDV_PCI_PNP_ID;

typedef HRESULT (CALLBACK *VMATE_HDV_PCI_DEVICE_GET_DETAILS)(
    const void *device_context,
    VMATE_HDV_PCI_PNP_ID *pnp_id,
    uint32_t probed_bars_count,
    uint32_t *probed_bars);
typedef HRESULT (CALLBACK *VMATE_HDV_PCI_DEVICE_START)(
    const void *device_context);
typedef void (CALLBACK *VMATE_HDV_PCI_DEVICE_STOP)(
    const void *device_context);
typedef HRESULT (CALLBACK *VMATE_HDV_PCI_READ_CONFIG_SPACE)(
    const void *device_context,
    uint32_t offset,
    uint32_t *value);
typedef HRESULT (CALLBACK *VMATE_HDV_PCI_WRITE_CONFIG_SPACE)(
    const void *device_context,
    uint32_t offset,
    uint32_t value);
typedef HRESULT (CALLBACK *VMATE_HDV_PCI_READ_INTERCEPTED_MEMORY)(
    const void *device_context,
    int bar_index,
    uint64_t offset,
    uint64_t length,
    uint8_t *value);
typedef HRESULT (CALLBACK *VMATE_HDV_PCI_WRITE_INTERCEPTED_MEMORY)(
    const void *device_context,
    int bar_index,
    uint64_t offset,
    uint64_t length,
    const uint8_t *value);

typedef struct VMATE_HDV_PCI_DEVICE_INTERFACE {
    int version;
    VMATE_HDV_PCI_DEVICE_INITIALIZE initialize;
    VMATE_HDV_PCI_DEVICE_TEARDOWN teardown;
    VMATE_HDV_PCI_DEVICE_SET_CONFIGURATION set_configuration;
    VMATE_HDV_PCI_DEVICE_GET_DETAILS get_details;
    VMATE_HDV_PCI_DEVICE_START start;
    VMATE_HDV_PCI_DEVICE_STOP stop;
    VMATE_HDV_PCI_READ_CONFIG_SPACE read_config_space;
    VMATE_HDV_PCI_WRITE_CONFIG_SPACE write_config_space;
    VMATE_HDV_PCI_READ_INTERCEPTED_MEMORY read_intercepted_memory;
    VMATE_HDV_PCI_WRITE_INTERCEPTED_MEMORY write_intercepted_memory;
} VMATE_HDV_PCI_DEVICE_INTERFACE;

typedef NTSTATUS (NTAPI *VMATE_NT_QUERY_SYSTEM_INFORMATION)(
    ULONG information_class,
    PVOID information,
    ULONG information_length,
    PULONG return_length);

typedef BOOL (WINAPI *VMATE_VID_GET_HV_PARTITION_ID)(
    HANDLE partition_handle,
    ULONGLONG *partition_id);

typedef struct VMATE_SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX {
    PVOID object;
    ULONG_PTR unique_process_id;
    ULONG_PTR handle_value;
    ULONG granted_access;
    USHORT creator_back_trace_index;
    USHORT object_type_index;
    ULONG handle_attributes;
    ULONG reserved;
} VMATE_SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX;

typedef struct VMATE_SYSTEM_HANDLE_INFORMATION_EX {
    ULONG_PTR number_of_handles;
    ULONG_PTR reserved;
    VMATE_SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX handles[1];
} VMATE_SYSTEM_HANDLE_INFORMATION_EX;

typedef struct VMATE_PARTITION_HIT {
    DWORD source_pid;
    ULONG_PTR source_handle;
    ULONGLONG partition_id;
    ULONG granted_access;
    USHORT object_type_index;
} VMATE_PARTITION_HIT;

static const GUID vmate_device_class_id = {
    0x4f3e3a1b, 0x0a7c, 0x4d12,
    {0x9b, 0x55, 0x9d, 0x1f, 0x44, 0x72, 0xc6, 0x01}
};

static const GUID vmate_device_instance_id = {
    0x8d7b1e24, 0x6c31, 0x4f98,
    {0xa2, 0xe4, 0x1a, 0x5b, 0x7c, 0x9d, 0x11, 0x01}
};

static volatile LONG vmate_initialize_callback_count;
static volatile LONG vmate_teardown_callback_count;
static volatile LONG vmate_set_configuration_callback_count;
static volatile LONG vmate_get_details_callback_count;
static volatile LONG vmate_start_callback_count;
static volatile LONG vmate_stop_callback_count;

static HRESULT CALLBACK
vmate_pci_initialize(const void *device_context)
{
    (void)device_context;
    InterlockedIncrement(&vmate_initialize_callback_count);
    return S_OK;
}

static void CALLBACK
vmate_pci_teardown(const void *device_context)
{
    (void)device_context;
    InterlockedIncrement(&vmate_teardown_callback_count);
}

static HRESULT CALLBACK
vmate_pci_set_configuration(const void *device_context,
                            uint32_t configuration_value_count,
                            PCWSTR const *configuration_values)
{
    (void)device_context;
    (void)configuration_value_count;
    (void)configuration_values;
    InterlockedIncrement(&vmate_set_configuration_callback_count);
    return S_OK;
}

static HRESULT CALLBACK
vmate_pci_get_details(const void *device_context,
                      VMATE_HDV_PCI_PNP_ID *pnp_id,
                      uint32_t probed_bars_count,
                      uint32_t *probed_bars)
{
    uint32_t index;

    (void)device_context;
    InterlockedIncrement(&vmate_get_details_callback_count);
    if (pnp_id == NULL || probed_bars == NULL || probed_bars_count < 6u) {
        return E_INVALIDARG;
    }
    ZeroMemory(pnp_id, sizeof(*pnp_id));
    pnp_id->vendor_id = 0x1414u;
    pnp_id->device_id = 0x0011u;
    pnp_id->revision_id = 1u;
    pnp_id->base_class = 0xffu;
    pnp_id->sub_vendor_id = 0x1414u;
    pnp_id->subsystem_id = 0x0011u;
    for (index = 0; index < probed_bars_count; index++) {
        probed_bars[index] = 0;
    }
    return S_OK;
}

static HRESULT CALLBACK
vmate_pci_start(const void *device_context)
{
    (void)device_context;
    InterlockedIncrement(&vmate_start_callback_count);
    return S_OK;
}

static void CALLBACK
vmate_pci_stop(const void *device_context)
{
    (void)device_context;
    InterlockedIncrement(&vmate_stop_callback_count);
}

static HRESULT CALLBACK
vmate_pci_read_config_space(const void *device_context,
                            uint32_t offset,
                            uint32_t *value)
{
    (void)device_context;
    (void)offset;
    if (value == NULL) {
        return E_POINTER;
    }
    *value = 0xffffffffu;
    return S_OK;
}

static HRESULT CALLBACK
vmate_pci_write_config_space(const void *device_context,
                             uint32_t offset,
                             uint32_t value)
{
    (void)device_context;
    (void)offset;
    (void)value;
    return S_OK;
}

static HRESULT CALLBACK
vmate_pci_read_intercepted_memory(const void *device_context,
                                  int bar_index,
                                  uint64_t offset,
                                  uint64_t length,
                                  uint8_t *value)
{
    (void)device_context;
    (void)bar_index;
    (void)offset;
    if (value == NULL || length > (uint64_t)SIZE_MAX) {
        return E_INVALIDARG;
    }
    memset(value, 0xff, (size_t)length);
    return S_OK;
}

static HRESULT CALLBACK
vmate_pci_write_intercepted_memory(const void *device_context,
                                   int bar_index,
                                   uint64_t offset,
                                   uint64_t length,
                                   const uint8_t *value)
{
    (void)device_context;
    (void)bar_index;
    (void)offset;
    (void)length;
    (void)value;
    return S_OK;
}

static const VMATE_HDV_PCI_DEVICE_INTERFACE vmate_pci_interface = {
    1,
    vmate_pci_initialize,
    vmate_pci_teardown,
    vmate_pci_set_configuration,
    vmate_pci_get_details,
    vmate_pci_start,
    vmate_pci_stop,
    vmate_pci_read_config_space,
    vmate_pci_write_config_space,
    vmate_pci_read_intercepted_memory,
    vmate_pci_write_intercepted_memory
};

static BOOL
vmate_parse_pid(const wchar_t *text, DWORD *pid)
{
    wchar_t *end = NULL;
    unsigned long value;

    if (text == NULL || text[0] == L'\0') {
        return FALSE;
    }
    value = wcstoul(text, &end, 10);
    if (end == text || *end != L'\0' || value == 0 ||
        value > 0xffffffffUL) {
        return FALSE;
    }
    *pid = (DWORD)value;
    return TRUE;
}

static void
vmate_print_json_wide_string(const wchar_t *value)
{
    const wchar_t *cursor;

    putchar('"');
    for (cursor = value; cursor != NULL && *cursor != L'\0'; cursor++) {
        unsigned int character = (unsigned int)*cursor;

        switch (character) {
        case '"':
            fputs("\\\"", stdout);
            break;
        case '\\':
            fputs("\\\\", stdout);
            break;
        case '\b':
            fputs("\\b", stdout);
            break;
        case '\f':
            fputs("\\f", stdout);
            break;
        case '\n':
            fputs("\\n", stdout);
            break;
        case '\r':
            fputs("\\r", stdout);
            break;
        case '\t':
            fputs("\\t", stdout);
            break;
        default:
            if (character >= 0x20u && character <= 0x7eu) {
                putchar((int)character);
            } else {
                printf("\\u%04X", character & 0xffffu);
            }
            break;
        }
    }
    putchar('"');
}

static BOOL
vmate_enable_debug_privilege(void)
{
    HANDLE token = NULL;
    TOKEN_PRIVILEGES privileges;
    LUID luid;
    BOOL enabled = FALSE;

    if (!OpenProcessToken(GetCurrentProcess(),
                          TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
                          &token)) {
        return FALSE;
    }
    if (!LookupPrivilegeValueW(NULL, SE_DEBUG_NAME, &luid)) {
        CloseHandle(token);
        return FALSE;
    }

    ZeroMemory(&privileges, sizeof(privileges));
    privileges.PrivilegeCount = 1;
    privileges.Privileges[0].Luid = luid;
    privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    SetLastError(ERROR_SUCCESS);
    if (AdjustTokenPrivileges(token, FALSE, &privileges,
                              sizeof(privileges), NULL, NULL) &&
        GetLastError() == ERROR_SUCCESS) {
        enabled = TRUE;
    }
    CloseHandle(token);
    return enabled;
}

static VMATE_SYSTEM_HANDLE_INFORMATION_EX *
vmate_query_system_handles(VMATE_NT_QUERY_SYSTEM_INFORMATION query,
                           DWORD *error_code)
{
    ULONG buffer_size = 1024u * 1024u;

    while (buffer_size <= VMATE_MAX_HANDLE_BUFFER) {
        VMATE_SYSTEM_HANDLE_INFORMATION_EX *information;
        ULONG required_size = 0;
        NTSTATUS status;

        information = (VMATE_SYSTEM_HANDLE_INFORMATION_EX *)
            HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, buffer_size);
        if (information == NULL) {
            *error_code = ERROR_NOT_ENOUGH_MEMORY;
            return NULL;
        }
        status = query(VMATE_SYSTEM_EXTENDED_HANDLE_INFORMATION,
                       information, buffer_size, &required_size);
        if (status >= 0) {
            return information;
        }
        HeapFree(GetProcessHeap(), 0, information);
        if (status != VMATE_STATUS_INFO_LENGTH_MISMATCH) {
            *error_code = (DWORD)status;
            return NULL;
        }
        if (required_size > buffer_size &&
            required_size <= VMATE_MAX_HANDLE_BUFFER) {
            buffer_size = required_size + (required_size / 8u);
        } else if (buffer_size <= VMATE_MAX_HANDLE_BUFFER / 2u) {
            buffer_size *= 2u;
        } else {
            break;
        }
    }

    *error_code = ERROR_INSUFFICIENT_BUFFER;
    return NULL;
}

static FARPROC
vmate_get_procedure(HMODULE module, const char *name)
{
    if (module == NULL) {
        return NULL;
    }
    return GetProcAddress(module, name);
}

int
wmain(int argc, wchar_t **argv)
{
    const wchar_t *compute_system_id = NULL;
    DWORD target_pid = 0;
    BOOL initialize_hdv = FALSE;
    BOOL create_device = FALSE;
    BOOL add_flexible_iov = FALSE;
    BOOL debug_privilege_enabled = FALSE;
    HMODULE computecore = NULL;
    HMODULE vmdevicehost = NULL;
    HMODULE vid = NULL;
    HMODULE ntdll = NULL;
    VMATE_HCS_OPEN_COMPUTE_SYSTEM hcs_open = NULL;
    VMATE_HCS_CLOSE_COMPUTE_SYSTEM hcs_close = NULL;
    VMATE_HCS_CREATE_OPERATION hcs_create_operation = NULL;
    VMATE_HCS_CLOSE_OPERATION hcs_close_operation = NULL;
    VMATE_HCS_MODIFY_COMPUTE_SYSTEM hcs_modify = NULL;
    VMATE_HCS_WAIT_FOR_OPERATION_RESULT hcs_wait = NULL;
    VMATE_HDV_INITIALIZE_DEVICE_HOST hdv_initialize = NULL;
    VMATE_HDV_TEARDOWN_DEVICE_HOST hdv_teardown = NULL;
    VMATE_HDV_CREATE_DEVICE_INSTANCE hdv_create_device = NULL;
    VMATE_NT_QUERY_SYSTEM_INFORMATION query_system_information = NULL;
    VMATE_VID_GET_HV_PARTITION_ID get_partition_id = NULL;
    VMATE_HCS_SYSTEM compute_system = NULL;
    VMATE_HCS_OPERATION modify_operation = NULL;
    VMATE_HDV_HOST device_host = NULL;
    HRESULT open_result;
    HRESULT initialize_result = E_NOTIMPL;
    HRESULT teardown_result = E_NOTIMPL;
    HRESULT create_device_result = E_NOTIMPL;
    HRESULT modify_submit_result = E_NOTIMPL;
    HRESULT modify_wait_result = E_NOTIMPL;
    HRESULT modify_effective_result = E_NOTIMPL;
    DWORD requested_access;
    HANDLE source_process = NULL;
    VMATE_SYSTEM_HANDLE_INFORMATION_EX *handle_information = NULL;
    VMATE_PARTITION_HIT hits[VMATE_MAX_PARTITION_HITS];
    size_t stored_hit_count = 0;
    unsigned long long matching_handles = 0;
    unsigned long long duplicated_handles = 0;
    unsigned long long duplicate_failures = 0;
    unsigned long long nonzero_partition_handles = 0;
    unsigned long long zero_id_queries = 0;
    unsigned long long vid_access_denied = 0;
    unsigned long long other_vid_failures = 0;
    unsigned long long self_matching_handles = 0;
    unsigned long long self_duplicated_handles = 0;
    unsigned long long self_duplicate_failures = 0;
    unsigned long long self_nonzero_partition_handles = 0;
    unsigned long long self_zero_id_queries = 0;
    unsigned long long self_vid_access_denied = 0;
    unsigned long long self_other_vid_failures = 0;
    DWORD handle_query_error = ERROR_SUCCESS;
    int index;
    int exit_code = 0;
    void *device_handle = NULL;
    PWSTR modify_result_document = NULL;
    static const wchar_t flexible_iov_request[] =
        L"{\"RequestType\":\"Add\","
        L"\"ResourcePath\":\"VirtualMachine/Devices/FlexibleIov/"
        L"8d7b1e24-6c31-4f98-a2e4-1a5b7c9d1101\","
        L"\"Settings\":{"
        L"\"EmulatorId\":\"4f3e3a1b-0a7c-4d12-9b55-9d1f4472c601\","
        L"\"HostingModel\":\"External\","
        L"\"Configuration\":[\"VMateIdentityPeerProbe\"]}}";

    for (index = 1; index < argc; index++) {
        if (wcscmp(argv[index], L"--id") == 0 && index + 1 < argc) {
            compute_system_id = argv[++index];
        } else if (wcscmp(argv[index], L"--initialize-hdv") == 0) {
            initialize_hdv = TRUE;
        } else if (wcscmp(argv[index], L"--create-device") == 0) {
            create_device = TRUE;
        } else if (wcscmp(argv[index], L"--add-flexible-iov") == 0) {
            add_flexible_iov = TRUE;
        } else if (wcscmp(argv[index], L"--vmwp-pid") == 0 &&
                   index + 1 < argc &&
                   vmate_parse_pid(argv[index + 1], &target_pid)) {
            index++;
        } else {
            fputs("usage: VMateHdvPeerProbe.exe --id <compute-system-id> "
                  "[--initialize-hdv --vmwp-pid <pid> "
                  "[--create-device [--add-flexible-iov]]]\n", stderr);
            return 64;
        }
    }
    if (compute_system_id == NULL ||
        (initialize_hdv && target_pid == 0) ||
        (!initialize_hdv &&
         (target_pid != 0 || create_device || add_flexible_iov)) ||
        (add_flexible_iov && !create_device)) {
        fputs("usage: VMateHdvPeerProbe.exe --id <compute-system-id> "
              "[--initialize-hdv --vmwp-pid <pid> "
              "[--create-device [--add-flexible-iov]]]\n", stderr);
        return 64;
    }

    computecore = LoadLibraryExW(L"computecore.dll", NULL,
                                 LOAD_LIBRARY_SEARCH_SYSTEM32);
    vmdevicehost = LoadLibraryExW(L"vmdevicehost.dll", NULL,
                                  LOAD_LIBRARY_SEARCH_SYSTEM32);
    ntdll = GetModuleHandleW(L"ntdll.dll");
    vid = LoadLibraryExW(L"vid.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);

    {
        FARPROC procedure = vmate_get_procedure(
            computecore, "HcsOpenComputeSystem");
        if (sizeof(procedure) == sizeof(hcs_open)) {
            memcpy(&hcs_open, &procedure, sizeof(hcs_open));
        }
        procedure = vmate_get_procedure(
            computecore, "HcsCloseComputeSystem");
        if (sizeof(procedure) == sizeof(hcs_close)) {
            memcpy(&hcs_close, &procedure, sizeof(hcs_close));
        }
        procedure = vmate_get_procedure(
            computecore, "HcsCreateOperation");
        if (sizeof(procedure) == sizeof(hcs_create_operation)) {
            memcpy(&hcs_create_operation, &procedure,
                   sizeof(hcs_create_operation));
        }
        procedure = vmate_get_procedure(
            computecore, "HcsCloseOperation");
        if (sizeof(procedure) == sizeof(hcs_close_operation)) {
            memcpy(&hcs_close_operation, &procedure,
                   sizeof(hcs_close_operation));
        }
        procedure = vmate_get_procedure(
            computecore, "HcsModifyComputeSystem");
        if (sizeof(procedure) == sizeof(hcs_modify)) {
            memcpy(&hcs_modify, &procedure, sizeof(hcs_modify));
        }
        procedure = vmate_get_procedure(
            computecore, "HcsWaitForOperationResult");
        if (sizeof(procedure) == sizeof(hcs_wait)) {
            memcpy(&hcs_wait, &procedure, sizeof(hcs_wait));
        }
        procedure = vmate_get_procedure(
            vmdevicehost, "HdvInitializeDeviceHost");
        if (procedure == NULL) {
            procedure = vmate_get_procedure(
                computecore, "HdvInitializeDeviceHost");
        }
        if (sizeof(procedure) == sizeof(hdv_initialize)) {
            memcpy(&hdv_initialize, &procedure, sizeof(hdv_initialize));
        }
        procedure = vmate_get_procedure(
            vmdevicehost, "HdvTeardownDeviceHost");
        if (procedure == NULL) {
            procedure = vmate_get_procedure(
                computecore, "HdvTeardownDeviceHost");
        }
        if (sizeof(procedure) == sizeof(hdv_teardown)) {
            memcpy(&hdv_teardown, &procedure, sizeof(hdv_teardown));
        }
        procedure = vmate_get_procedure(
            vmdevicehost, "HdvCreateDeviceInstance");
        if (procedure == NULL) {
            procedure = vmate_get_procedure(
                computecore, "HdvCreateDeviceInstance");
        }
        if (sizeof(procedure) == sizeof(hdv_create_device)) {
            memcpy(&hdv_create_device, &procedure,
                   sizeof(hdv_create_device));
        }
        procedure = vmate_get_procedure(
            ntdll, "NtQuerySystemInformation");
        if (sizeof(procedure) == sizeof(query_system_information)) {
            memcpy(&query_system_information, &procedure,
                   sizeof(query_system_information));
        }
        procedure = vmate_get_procedure(vid, "VidGetHvPartitionId");
        if (sizeof(procedure) == sizeof(get_partition_id)) {
            memcpy(&get_partition_id, &procedure,
                   sizeof(get_partition_id));
        }
    }

    if (hcs_open == NULL || hcs_close == NULL ||
        (initialize_hdv &&
         (hdv_initialize == NULL || hdv_teardown == NULL ||
          query_system_information == NULL || get_partition_id == NULL))) {
        printf("{\"schemaVersion\":1,\"operation\":\"%s\","
               "\"error\":\"required-api-unavailable\","
               "\"win32Error\":%lu}\n",
               initialize_hdv ? "hdv-peer-probe" : "read-only-hcs-open",
               (unsigned long)GetLastError());
        exit_code = 69;
        goto cleanup;
    }

    /* HcsOpenComputeSystem reserves this parameter and requires GENERIC_ALL. */
    requested_access = GENERIC_ALL;
    open_result = hcs_open(compute_system_id, requested_access,
                           &compute_system);
    if (FAILED(open_result)) {
        printf("{\"schemaVersion\":1,\"operation\":\"%s\","
               "\"computeSystemId\":",
               initialize_hdv ? "hdv-peer-probe" : "read-only-hcs-open");
        vmate_print_json_wide_string(compute_system_id);
        printf(",\"requestedAccess\":\"%s\","
               "\"hcsOpenSucceeded\":false,"
               "\"hcsOpenHresult\":\"0x%08lX\"}\n",
               "GENERIC_ALL",
               (unsigned long)open_result);
        exit_code = 2;
        goto cleanup;
    }

    if (!initialize_hdv) {
        printf("{\"schemaVersion\":1,"
               "\"operation\":\"read-only-hcs-open\","
               "\"computeSystemId\":");
        vmate_print_json_wide_string(compute_system_id);
        printf(",\"requestedAccess\":\"GENERIC_ALL\","
               "\"mutatingCalls\":false,"
               "\"hcsOpenSucceeded\":true,"
               "\"hcsOpenHresult\":\"0x%08lX\"}\n",
               (unsigned long)open_result);
        goto cleanup;
    }

    debug_privilege_enabled = vmate_enable_debug_privilege();
    source_process = OpenProcess(PROCESS_DUP_HANDLE |
                                 PROCESS_QUERY_LIMITED_INFORMATION,
                                 FALSE, target_pid);
    if (source_process == NULL) {
        source_process = OpenProcess(PROCESS_DUP_HANDLE, FALSE, target_pid);
    }
    if (source_process == NULL) {
        printf("{\"schemaVersion\":1,\"operation\":\"hdv-peer-probe\","
               "\"computeSystemId\":");
        vmate_print_json_wide_string(compute_system_id);
        printf(",\"targetPid\":%lu,\"hcsOpenSucceeded\":true,"
               "\"error\":\"open-vmwp-failed\",\"win32Error\":%lu}\n",
               (unsigned long)target_pid, (unsigned long)GetLastError());
        exit_code = 77;
        goto cleanup;
    }

    initialize_result = hdv_initialize(compute_system, &device_host);
    if (SUCCEEDED(initialize_result)) {
        ULONG_PTR handle_index;

        if (create_device) {
            if (hdv_create_device == NULL) {
                create_device_result = HRESULT_FROM_WIN32(
                    ERROR_PROC_NOT_FOUND);
            } else {
                create_device_result = hdv_create_device(
                    device_host, 1, &vmate_device_class_id,
                    &vmate_device_instance_id, &vmate_pci_interface,
                    NULL, &device_handle);
            }
        }

        if (add_flexible_iov && SUCCEEDED(create_device_result)) {
            if (hcs_create_operation == NULL ||
                hcs_close_operation == NULL || hcs_modify == NULL ||
                hcs_wait == NULL) {
                modify_effective_result = HRESULT_FROM_WIN32(
                    ERROR_PROC_NOT_FOUND);
            } else {
                modify_operation = hcs_create_operation(NULL, NULL);
                if (modify_operation == NULL) {
                    modify_effective_result = E_OUTOFMEMORY;
                } else {
                    modify_submit_result = hcs_modify(
                        compute_system, modify_operation,
                        flexible_iov_request, NULL);
                    if (SUCCEEDED(modify_submit_result)) {
                        modify_wait_result = hcs_wait(
                            modify_operation, 15000u,
                            &modify_result_document);
                        modify_effective_result = modify_wait_result;
                    } else {
                        modify_effective_result = modify_submit_result;
                    }
                }
            }
            if (SUCCEEDED(modify_effective_result)) {
                Sleep(750u);
            }
        }

        handle_information = vmate_query_system_handles(
            query_system_information, &handle_query_error);
        if (handle_information == NULL) {
            exit_code = 70;
        } else {
            for (handle_index = 0;
                 handle_index < handle_information->number_of_handles;
                 handle_index++) {
                VMATE_SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX *entry =
                    &handle_information->handles[handle_index];
                HANDLE duplicate = NULL;
                ULONGLONG partition_id = 0;
                DWORD vid_error;

                if (entry->unique_process_id != (ULONG_PTR)target_pid) {
                    continue;
                }
                matching_handles++;
                if (!DuplicateHandle(source_process,
                                     (HANDLE)entry->handle_value,
                                     GetCurrentProcess(), &duplicate,
                                     0, FALSE, DUPLICATE_SAME_ACCESS)) {
                    duplicate_failures++;
                    continue;
                }
                duplicated_handles++;
                SetLastError(ERROR_SUCCESS);
                if (get_partition_id(duplicate, &partition_id)) {
                    if (partition_id == 0) {
                        zero_id_queries++;
                    } else {
                        nonzero_partition_handles++;
                        if (stored_hit_count < VMATE_MAX_PARTITION_HITS) {
                            hits[stored_hit_count].source_pid = target_pid;
                            hits[stored_hit_count].source_handle =
                                entry->handle_value;
                            hits[stored_hit_count].partition_id = partition_id;
                            hits[stored_hit_count].granted_access =
                                entry->granted_access;
                            hits[stored_hit_count].object_type_index =
                                entry->object_type_index;
                            stored_hit_count++;
                        }
                    }
                } else {
                    vid_error = GetLastError();
                    if (vid_error == ERROR_ACCESS_DENIED) {
                        vid_access_denied++;
                    } else {
                        other_vid_failures++;
                    }
                }
                CloseHandle(duplicate);
            }

            for (handle_index = 0;
                 handle_index < handle_information->number_of_handles;
                 handle_index++) {
                VMATE_SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX *entry =
                    &handle_information->handles[handle_index];
                HANDLE duplicate = NULL;
                ULONGLONG partition_id = 0;
                DWORD vid_error;

                if (entry->unique_process_id !=
                    (ULONG_PTR)GetCurrentProcessId()) {
                    continue;
                }
                self_matching_handles++;
                if (!DuplicateHandle(GetCurrentProcess(),
                                     (HANDLE)entry->handle_value,
                                     GetCurrentProcess(), &duplicate,
                                     0, FALSE, DUPLICATE_SAME_ACCESS)) {
                    self_duplicate_failures++;
                    continue;
                }
                self_duplicated_handles++;
                SetLastError(ERROR_SUCCESS);
                if (get_partition_id(duplicate, &partition_id)) {
                    if (partition_id == 0) {
                        self_zero_id_queries++;
                    } else {
                        self_nonzero_partition_handles++;
                        if (stored_hit_count < VMATE_MAX_PARTITION_HITS) {
                            hits[stored_hit_count].source_pid =
                                GetCurrentProcessId();
                            hits[stored_hit_count].source_handle =
                                entry->handle_value;
                            hits[stored_hit_count].partition_id = partition_id;
                            hits[stored_hit_count].granted_access =
                                entry->granted_access;
                            hits[stored_hit_count].object_type_index =
                                entry->object_type_index;
                            stored_hit_count++;
                        }
                    }
                } else {
                    vid_error = GetLastError();
                    if (vid_error == ERROR_ACCESS_DENIED) {
                        self_vid_access_denied++;
                    } else {
                        self_other_vid_failures++;
                    }
                }
                CloseHandle(duplicate);
            }
        }
        teardown_result = hdv_teardown(device_host);
    }

    printf("{\"schemaVersion\":1,\"operation\":\"hdv-peer-probe\","
           "\"computeSystemId\":");
    vmate_print_json_wide_string(compute_system_id);
    printf(",\"targetPid\":%lu,\"requestedAccess\":\"GENERIC_ALL\","
           "\"debugPrivilegeEnabled\":%s,"
           "\"hcsOpenSucceeded\":true,"
           "\"hcsOpenHresult\":\"0x%08lX\","
           "\"hdvInitializeSucceeded\":%s,"
           "\"hdvInitializeHresult\":\"0x%08lX\","
           "\"hdvHost\":\"0x%llX\","
           "\"createDeviceRequested\":%s,"
           "\"createDeviceSucceeded\":%s,"
           "\"createDeviceHresult\":\"0x%08lX\","
           "\"deviceHandle\":\"0x%llX\",\"partitions\":[",
           (unsigned long)target_pid,
           debug_privilege_enabled ? "true" : "false",
           (unsigned long)open_result,
           SUCCEEDED(initialize_result) ? "true" : "false",
           (unsigned long)initialize_result,
           (unsigned long long)(ULONG_PTR)device_host,
           create_device ? "true" : "false",
           create_device && SUCCEEDED(create_device_result) ?
               "true" : "false",
           (unsigned long)create_device_result,
           (unsigned long long)(ULONG_PTR)device_handle);
    {
        size_t hit_index;

        for (hit_index = 0; hit_index < stored_hit_count; hit_index++) {
            if (hit_index != 0) {
                putchar(',');
            }
            printf("{\"sourcePid\":%lu,"
                   "\"sourceHandle\":\"0x%llX\","
                   "\"partitionId\":\"0x%016llX\","
                   "\"objectTypeIndex\":%u,"
                   "\"grantedAccess\":\"0x%08lX\"}",
                   (unsigned long)hits[hit_index].source_pid,
                   (unsigned long long)hits[hit_index].source_handle,
                   (unsigned long long)hits[hit_index].partition_id,
                   (unsigned int)hits[hit_index].object_type_index,
                   (unsigned long)hits[hit_index].granted_access);
        }
    }
    printf("],\"addFlexibleIovRequested\":%s,"
           "\"modifySubmitHresult\":\"0x%08lX\","
           "\"modifyWaitHresult\":\"0x%08lX\","
           "\"modifyEffectiveHresult\":\"0x%08lX\","
           "\"modifyResultDocument\":",
           add_flexible_iov ? "true" : "false",
           (unsigned long)modify_submit_result,
           (unsigned long)modify_wait_result,
           (unsigned long)modify_effective_result);
    if (modify_result_document != NULL) {
        vmate_print_json_wide_string(modify_result_document);
    } else {
        fputs("null", stdout);
    }
    printf(",\"initializeCallbackCount\":%ld,"
           "\"setConfigurationCallbackCount\":%ld,"
           "\"getDetailsCallbackCount\":%ld,"
           "\"startCallbackCount\":%ld,\"stopCallbackCount\":%ld,"
           "\"teardownCallbackCount\":%ld,"
           "\"matchingHandles\":%llu,\"duplicatedHandles\":%llu,"
           "\"duplicateFailures\":%llu,"
           "\"nonzeroPartitionHandleCount\":%llu,"
           "\"zeroIdQueryCount\":%llu,\"vidAccessDeniedCount\":%llu,"
           "\"otherVidFailureCount\":%llu,"
           "\"selfMatchingHandles\":%llu,"
           "\"selfDuplicatedHandles\":%llu,"
           "\"selfDuplicateFailures\":%llu,"
           "\"selfNonzeroPartitionHandleCount\":%llu,"
           "\"selfZeroIdQueryCount\":%llu,"
           "\"selfVidAccessDeniedCount\":%llu,"
           "\"selfOtherVidFailureCount\":%llu,"
           "\"handleQueryError\":%lu,"
           "\"hdvTeardownHresult\":\"0x%08lX\"}\n",
           (long)vmate_initialize_callback_count,
           (long)vmate_set_configuration_callback_count,
           (long)vmate_get_details_callback_count,
           (long)vmate_start_callback_count,
           (long)vmate_stop_callback_count,
           (long)vmate_teardown_callback_count,
           matching_handles, duplicated_handles, duplicate_failures,
           nonzero_partition_handles, zero_id_queries, vid_access_denied,
           other_vid_failures, self_matching_handles,
           self_duplicated_handles, self_duplicate_failures,
           self_nonzero_partition_handles, self_zero_id_queries,
           self_vid_access_denied, self_other_vid_failures,
           (unsigned long)handle_query_error,
           (unsigned long)teardown_result);

    if (FAILED(initialize_result)) {
        exit_code = 3;
    } else if (create_device && FAILED(create_device_result)) {
        exit_code = 4;
    } else if (add_flexible_iov && FAILED(modify_effective_result)) {
        exit_code = 5;
    } else if (FAILED(teardown_result) ||
               nonzero_partition_handles +
                   self_nonzero_partition_handles == 0) {
        exit_code = 2;
    }

cleanup:
    if (modify_result_document != NULL) {
        CoTaskMemFree(modify_result_document);
    }
    if (modify_operation != NULL && hcs_close_operation != NULL) {
        hcs_close_operation(modify_operation);
    }
    if (handle_information != NULL) {
        HeapFree(GetProcessHeap(), 0, handle_information);
    }
    if (source_process != NULL) {
        CloseHandle(source_process);
    }
    if (compute_system != NULL && hcs_close != NULL) {
        hcs_close(compute_system);
    }
    if (vid != NULL) {
        FreeLibrary(vid);
    }
    if (vmdevicehost != NULL) {
        FreeLibrary(vmdevicehost);
    }
    if (computecore != NULL) {
        FreeLibrary(computecore);
    }
    return exit_code;
}
