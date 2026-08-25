/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Read-only Hyper-V VID partition-handle probe.
 *
 * The tool duplicates handles only from the explicitly selected vmwp.exe
 * process and asks the inbox vid.dll for each handle's Hyper-V partition ID.
 * It never registers intercepts and never changes VM state.
 */

#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0602

#include <windows.h>
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

typedef LONG NTSTATUS;

typedef NTSTATUS (NTAPI *VMATE_NT_QUERY_SYSTEM_INFORMATION)(
    ULONG information_class,
    PVOID information,
    ULONG information_length,
    PULONG return_length);

typedef NTSTATUS (NTAPI *VMATE_NT_QUERY_OBJECT)(
    HANDLE handle,
    ULONG information_class,
    PVOID information,
    ULONG information_length,
    PULONG return_length);

typedef NTSTATUS (NTAPI *VMATE_NT_SET_INFORMATION_PROCESS)(
    HANDLE process,
    ULONG information_class,
    PVOID information,
    ULONG information_length);

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

typedef struct VMATE_UNICODE_STRING {
    USHORT length;
    USHORT maximum_length;
    PWSTR buffer;
} VMATE_UNICODE_STRING;

typedef struct VMATE_PROCESS_ACCESS_TOKEN {
    HANDLE token;
    HANDLE thread;
} VMATE_PROCESS_ACCESS_TOKEN;

#define VMATE_PROCESS_ACCESS_TOKEN_INFORMATION_CLASS 9u
#define VMATE_MAX_ACCESS_DENIED_CANDIDATES 64u

static void
vmate_print_json_wide_string(const wchar_t *value, size_t length)
{
    size_t index;

    putchar('"');
    for (index = 0; index < length; index++) {
        unsigned int character = (unsigned int)value[index];

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

static PVOID
vmate_query_object_information(VMATE_NT_QUERY_OBJECT query_object,
                               HANDLE handle,
                               ULONG information_class)
{
    ULONG required_size = 0;
    ULONG buffer_size;
    PVOID information;
    NTSTATUS status;

    if (query_object == NULL) {
        return NULL;
    }
    status = query_object(handle, information_class, NULL, 0, &required_size);
    if (status >= 0 || required_size < sizeof(VMATE_UNICODE_STRING) ||
        required_size > 64u * 1024u) {
        return NULL;
    }
    buffer_size = required_size + 512u;
    information = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, buffer_size);
    if (information == NULL) {
        return NULL;
    }
    status = query_object(handle, information_class, information,
                          buffer_size, &required_size);
    if (status < 0) {
        HeapFree(GetProcessHeap(), 0, information);
        return NULL;
    }
    return information;
}

static BOOL
vmate_enable_privilege(const wchar_t *privilege_name)
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
    if (!LookupPrivilegeValueW(NULL, privilege_name, &luid)) {
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

static BOOL
vmate_enable_debug_privilege(void)
{
    return vmate_enable_privilege(SE_DEBUG_NAME);
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

static BOOL
vmate_parse_handle(const wchar_t *text, ULONG_PTR *handle_value)
{
    wchar_t *end = NULL;
    unsigned long long value;

    if (text == NULL || text[0] == L'\0') {
        return FALSE;
    }
    value = wcstoull(text, &end, 0);
    if (end == text || *end != L'\0' || value == 0 ||
        value > (unsigned long long)(ULONG_PTR)-1) {
        return FALSE;
    }
    *handle_value = (ULONG_PTR)value;
    return TRUE;
}

static int
vmate_probe_inherited_handle(ULONG_PTR handle_value)
{
    HMODULE vid;
    VMATE_VID_GET_HV_PARTITION_ID get_partition_id = NULL;
    ULONGLONG partition_id = 0;
    DWORD vid_error;
    BOOL succeeded;

    vid = LoadLibraryExW(L"vid.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (vid != NULL) {
        FARPROC procedure = GetProcAddress(vid, "VidGetHvPartitionId");

        if (sizeof(procedure) == sizeof(get_partition_id)) {
            memcpy(&get_partition_id, &procedure, sizeof(get_partition_id));
        }
    }
    if (get_partition_id == NULL) {
        DWORD loader_error = GetLastError();

        printf("{\"schemaVersion\":1,"
               "\"operation\":\"read-only-inherited-handle-probe\","
               "\"processId\":%lu,\"sourceHandle\":\"0x%llX\","
               "\"error\":\"required-api-unavailable\","
               "\"win32Error\":%lu}\n",
               (unsigned long)GetCurrentProcessId(),
               (unsigned long long)handle_value,
               (unsigned long)loader_error);
        if (vid != NULL) {
            FreeLibrary(vid);
        }
        return 69;
    }

    SetLastError(ERROR_SUCCESS);
    succeeded = get_partition_id((HANDLE)handle_value, &partition_id);
    vid_error = GetLastError();
    printf("{\"schemaVersion\":1,"
           "\"operation\":\"read-only-inherited-handle-probe\","
           "\"processId\":%lu,\"sourceHandle\":\"0x%llX\","
           "\"vidQuerySucceeded\":%s,\"vidError\":%lu,"
           "\"partitionId\":\"0x%016llX\"}\n",
           (unsigned long)GetCurrentProcessId(),
           (unsigned long long)handle_value,
           succeeded ? "true" : "false",
           (unsigned long)vid_error,
           (unsigned long long)partition_id);
    FreeLibrary(vid);
    return succeeded && partition_id != 0 ? 0 : 2;
}

static int
vmate_probe_after_token_transition(ULONG_PTR handle_value,
                                   ULONG_PTR ready_event_value,
                                   ULONG_PTR go_event_value)
{
    HMODULE vid;
    VMATE_VID_GET_HV_PARTITION_ID get_partition_id = NULL;
    ULONGLONG partition_id = 0;
    DWORD vid_error;
    DWORD wait_result;
    BOOL succeeded;

    vid = LoadLibraryExW(L"vid.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (vid != NULL) {
        FARPROC procedure = GetProcAddress(vid, "VidGetHvPartitionId");

        if (sizeof(procedure) == sizeof(get_partition_id)) {
            memcpy(&get_partition_id, &procedure, sizeof(get_partition_id));
        }
    }
    if (get_partition_id == NULL) {
        return 69;
    }
    if (!SetEvent((HANDLE)ready_event_value)) {
        FreeLibrary(vid);
        return 70;
    }
    wait_result = WaitForSingleObject((HANDLE)go_event_value, 10000);
    if (wait_result != WAIT_OBJECT_0) {
        FreeLibrary(vid);
        return 71;
    }

    SetLastError(ERROR_SUCCESS);
    succeeded = get_partition_id((HANDLE)handle_value, &partition_id);
    vid_error = GetLastError();
    printf("{\"schemaVersion\":1,"
           "\"operation\":\"read-only-transitioned-token-probe\","
           "\"processId\":%lu,\"sourceHandle\":\"0x%llX\","
           "\"vidQuerySucceeded\":%s,\"vidError\":%lu,"
           "\"partitionId\":\"0x%016llX\"}\n",
           (unsigned long)GetCurrentProcessId(),
           (unsigned long long)handle_value,
           succeeded ? "true" : "false",
           (unsigned long)vid_error,
           (unsigned long long)partition_id);
    FreeLibrary(vid);
    return succeeded && partition_id != 0 ? 0 : 2;
}

static BOOL
vmate_spawn_target_token_probe(HANDLE source_process,
                               HANDLE inherited_partition_handle,
                               DWORD *token_open_error,
                               DWORD *token_duplicate_error,
                               DWORD *direct_create_error,
                               DWORD *fallback_create_error,
                               LONG *token_assignment_status,
                               DWORD *wait_error,
                               DWORD *child_exit_code)
{
    HMODULE ntdll = NULL;
    VMATE_NT_SET_INFORMATION_PROCESS set_information_process = NULL;
    HANDLE source_token = NULL;
    HANDLE primary_token = NULL;
    HANDLE ready_event = NULL;
    HANDLE go_event = NULL;
    PROCESS_INFORMATION process_information;
    STARTUPINFOW startup_information;
    SECURITY_ATTRIBUTES event_attributes;
    wchar_t image_path[MAX_PATH];
    wchar_t command_line[(MAX_PATH * 2) + 96];
    DWORD wait_result;
    BOOL created = FALSE;

    *token_open_error = ERROR_SUCCESS;
    *token_duplicate_error = ERROR_SUCCESS;
    *direct_create_error = ERROR_SUCCESS;
    *fallback_create_error = ERROR_SUCCESS;
    *token_assignment_status = 0;
    *wait_error = ERROR_SUCCESS;
    *child_exit_code = (DWORD)-1;
    ZeroMemory(&startup_information, sizeof(startup_information));
    ZeroMemory(&process_information, sizeof(process_information));
    ZeroMemory(&event_attributes, sizeof(event_attributes));

    if (!OpenProcessToken(source_process,
                          TOKEN_QUERY | TOKEN_DUPLICATE |
                          TOKEN_ASSIGN_PRIMARY,
                          &source_token)) {
        *token_open_error = GetLastError();
        goto cleanup;
    }
    if (!DuplicateTokenEx(source_token,
                          MAXIMUM_ALLOWED,
                          NULL,
                          SecurityImpersonation,
                          TokenPrimary,
                          &primary_token)) {
        *token_duplicate_error = GetLastError();
        goto cleanup;
    }
    vmate_enable_privilege(SE_ASSIGNPRIMARYTOKEN_NAME);
    vmate_enable_privilege(SE_INCREASE_QUOTA_NAME);
    if (!SetHandleInformation(inherited_partition_handle,
                              HANDLE_FLAG_INHERIT,
                              HANDLE_FLAG_INHERIT)) {
        *direct_create_error = GetLastError();
        goto cleanup;
    }
    if (GetModuleFileNameW(NULL, image_path, MAX_PATH) == 0) {
        *direct_create_error = GetLastError();
        goto cleanup;
    }
    if (_snwprintf(command_line,
                   sizeof(command_line) / sizeof(command_line[0]),
                   L"\"%ls\" --local-handle 0x%llX",
                   image_path,
                   (unsigned long long)(ULONG_PTR)
                       inherited_partition_handle) < 0) {
        *direct_create_error = ERROR_INSUFFICIENT_BUFFER;
        goto cleanup;
    }

    startup_information.cb = sizeof(startup_information);
    created = CreateProcessAsUserW(primary_token,
                                   image_path,
                                   command_line,
                                   NULL,
                                   NULL,
                                   TRUE,
                                   CREATE_NO_WINDOW,
                                   NULL,
                                   NULL,
                                   &startup_information,
                                   &process_information);
    if (!created) {
        VMATE_PROCESS_ACCESS_TOKEN access_token;
        FARPROC procedure;

        *direct_create_error = GetLastError();
        event_attributes.nLength = sizeof(event_attributes);
        event_attributes.bInheritHandle = TRUE;
        ready_event = CreateEventW(&event_attributes, TRUE, FALSE, NULL);
        go_event = CreateEventW(&event_attributes, TRUE, FALSE, NULL);
        if (ready_event == NULL || go_event == NULL) {
            *fallback_create_error = GetLastError();
            goto cleanup;
        }
        if (_snwprintf(command_line,
                       sizeof(command_line) / sizeof(command_line[0]),
                       L"\"%ls\" --token-transition-worker "
                       L"0x%llX 0x%llX 0x%llX",
                       image_path,
                       (unsigned long long)(ULONG_PTR)
                           inherited_partition_handle,
                       (unsigned long long)(ULONG_PTR)ready_event,
                       (unsigned long long)(ULONG_PTR)go_event) < 0) {
            *fallback_create_error = ERROR_INSUFFICIENT_BUFFER;
            goto cleanup;
        }
        created = CreateProcessW(image_path,
                                 command_line,
                                 NULL,
                                 NULL,
                                 TRUE,
                                 CREATE_NO_WINDOW,
                                 NULL,
                                 NULL,
                                 &startup_information,
                                 &process_information);
        if (!created) {
            *fallback_create_error = GetLastError();
            goto cleanup;
        }

        wait_result = WaitForSingleObject(ready_event, 5000);
        if (wait_result != WAIT_OBJECT_0) {
            *fallback_create_error = wait_result == WAIT_FAILED ?
                GetLastError() : WAIT_TIMEOUT;
            TerminateProcess(process_information.hProcess, 124);
            WaitForSingleObject(process_information.hProcess, 1000);
            goto cleanup;
        }

        ntdll = GetModuleHandleW(L"ntdll.dll");
        procedure = ntdll != NULL ?
            GetProcAddress(ntdll, "NtSetInformationProcess") : NULL;
        if (sizeof(procedure) == sizeof(set_information_process)) {
            memcpy(&set_information_process, &procedure,
                   sizeof(set_information_process));
        }
        if (set_information_process == NULL) {
            *fallback_create_error = ERROR_PROC_NOT_FOUND;
            TerminateProcess(process_information.hProcess, 127);
            WaitForSingleObject(process_information.hProcess, 1000);
            goto cleanup;
        }

        access_token.token = primary_token;
        access_token.thread = NULL;
        *token_assignment_status = set_information_process(
            process_information.hProcess,
            VMATE_PROCESS_ACCESS_TOKEN_INFORMATION_CLASS,
            &access_token,
            (ULONG)sizeof(access_token));
        if (*token_assignment_status < 0) {
            TerminateProcess(process_information.hProcess, 126);
            WaitForSingleObject(process_information.hProcess, 1000);
            goto cleanup;
        }
        if (!SetEvent(go_event)) {
            *fallback_create_error = GetLastError();
            TerminateProcess(process_information.hProcess, 125);
            WaitForSingleObject(process_information.hProcess, 1000);
            goto cleanup;
        }
    }

    wait_result = WaitForSingleObject(process_information.hProcess, 10000);
    if (wait_result != WAIT_OBJECT_0) {
        *wait_error = wait_result == WAIT_FAILED ? GetLastError() : WAIT_TIMEOUT;
        TerminateProcess(process_information.hProcess, 124);
        WaitForSingleObject(process_information.hProcess, 1000);
    }
    GetExitCodeProcess(process_information.hProcess, child_exit_code);

cleanup:
    SetHandleInformation(inherited_partition_handle, HANDLE_FLAG_INHERIT, 0);
    if (process_information.hThread != NULL) {
        CloseHandle(process_information.hThread);
    }
    if (process_information.hProcess != NULL) {
        CloseHandle(process_information.hProcess);
    }
    if (primary_token != NULL) {
        CloseHandle(primary_token);
    }
    if (go_event != NULL) {
        CloseHandle(go_event);
    }
    if (ready_event != NULL) {
        CloseHandle(ready_event);
    }
    if (source_token != NULL) {
        CloseHandle(source_token);
    }
    return created && *wait_error == ERROR_SUCCESS && *child_exit_code == 0;
}

int
wmain(int argc, wchar_t **argv)
{
    HMODULE ntdll = NULL;
    HMODULE vid = NULL;
    VMATE_NT_QUERY_SYSTEM_INFORMATION query_system_information = NULL;
    VMATE_NT_QUERY_OBJECT query_object = NULL;
    VMATE_VID_GET_HV_PARTITION_ID get_partition_id = NULL;
    VMATE_SYSTEM_HANDLE_INFORMATION_EX *handle_information = NULL;
    HANDLE source_process = NULL;
    HANDLE source_token = NULL;
    HANDLE impersonation_token = NULL;
    DWORD target_pid = 0;
    ULONG_PTR requested_handle = 0;
    DWORD query_error = ERROR_SUCCESS;
    DWORD open_error = ERROR_SUCCESS;
    DWORD token_open_error = ERROR_SUCCESS;
    DWORD token_duplicate_error = ERROR_SUCCESS;
    BOOL impersonate_target = FALSE;
    BOOL spawn_target_token = FALSE;
    BOOL list_access_denied = FALSE;
    BOOL debug_privilege_enabled;
    ULONG_PTR index;
    unsigned long long matching_handles = 0;
    unsigned long long duplicated_handles = 0;
    unsigned long long duplicate_failures = 0;
    unsigned long long partition_handles = 0;
    unsigned long long zero_id_queries = 0;
    unsigned long long access_denied_queries = 0;
    ULONG_PTR access_denied_candidates[
        VMATE_MAX_ACCESS_DENIED_CANDIDATES];
    ULONG access_denied_candidate_count = 0;
    BOOL first_partition = TRUE;

    if (argc == 3 && wcscmp(argv[1], L"--local-handle") == 0 &&
        vmate_parse_handle(argv[2], &requested_handle)) {
        return vmate_probe_inherited_handle(requested_handle);
    }
    if (argc == 5 &&
        wcscmp(argv[1], L"--token-transition-worker") == 0) {
        ULONG_PTR ready_event_value;
        ULONG_PTR go_event_value;

        if (vmate_parse_handle(argv[2], &requested_handle) &&
            vmate_parse_handle(argv[3], &ready_event_value) &&
            vmate_parse_handle(argv[4], &go_event_value)) {
            return vmate_probe_after_token_transition(
                requested_handle, ready_event_value, go_event_value);
        }
    }
    requested_handle = 0;
    if (argc < 3 || wcscmp(argv[1], L"--pid") != 0 ||
        !vmate_parse_pid(argv[2], &target_pid)) {
        fputs("usage: VMateVidPartitionProbe.exe --pid <vmwp-pid> "
              "[--handle <source-handle>] [--impersonate-target | "
              "--spawn-target-token] [--list-access-denied]\n",
              stderr);
        return 64;
    }
    for (index = 3; index < (ULONG_PTR)argc; index++) {
        if (wcscmp(argv[index], L"--handle") == 0 &&
            index + 1 < (ULONG_PTR)argc && requested_handle == 0 &&
            vmate_parse_handle(argv[index + 1], &requested_handle)) {
            index++;
        } else if (wcscmp(argv[index], L"--impersonate-target") == 0 &&
                   !impersonate_target && !spawn_target_token) {
            impersonate_target = TRUE;
        } else if (wcscmp(argv[index], L"--spawn-target-token") == 0 &&
                   !spawn_target_token && !impersonate_target) {
            spawn_target_token = TRUE;
        } else if (wcscmp(argv[index], L"--list-access-denied") == 0 &&
                   !list_access_denied) {
            list_access_denied = TRUE;
        } else {
            requested_handle = 0;
            impersonate_target = FALSE;
            break;
        }
    }
    if (index != (ULONG_PTR)argc) {
        fputs("usage: VMateVidPartitionProbe.exe --pid <vmwp-pid> "
              "[--handle <source-handle>] [--impersonate-target | "
              "--spawn-target-token] [--list-access-denied]\n",
              stderr);
        return 64;
    }
    if (spawn_target_token && requested_handle == 0) {
        fputs("--spawn-target-token requires --handle.\n", stderr);
        return 64;
    }

    debug_privilege_enabled = vmate_enable_debug_privilege();

    ntdll = GetModuleHandleW(L"ntdll.dll");
    if (ntdll != NULL) {
        FARPROC procedure = GetProcAddress(ntdll, "NtQuerySystemInformation");

        if (sizeof(procedure) == sizeof(query_system_information)) {
            memcpy(&query_system_information, &procedure,
                   sizeof(query_system_information));
        }
        procedure = GetProcAddress(ntdll, "NtQueryObject");
        if (sizeof(procedure) == sizeof(query_object)) {
            memcpy(&query_object, &procedure, sizeof(query_object));
        }
    }
    vid = LoadLibraryExW(L"vid.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (vid != NULL) {
        FARPROC procedure = GetProcAddress(vid, "VidGetHvPartitionId");

        if (sizeof(procedure) == sizeof(get_partition_id)) {
            memcpy(&get_partition_id, &procedure, sizeof(get_partition_id));
        }
    }
    if (query_system_information == NULL || get_partition_id == NULL) {
        DWORD loader_error = GetLastError();

        printf("{\"schemaVersion\":1,\"operation\":\"read-only-probe\","
               "\"targetPid\":%lu,\"error\":\"required-api-unavailable\","
               "\"win32Error\":%lu}\n",
               (unsigned long)target_pid, (unsigned long)loader_error);
        if (vid != NULL) {
            FreeLibrary(vid);
        }
        return 69;
    }

    source_process = OpenProcess(PROCESS_DUP_HANDLE |
                                 PROCESS_QUERY_LIMITED_INFORMATION,
                                 FALSE, target_pid);
    if (source_process == NULL) {
        open_error = GetLastError();
        source_process = OpenProcess(PROCESS_DUP_HANDLE, FALSE, target_pid);
    }
    if (source_process == NULL) {
        if (open_error == ERROR_SUCCESS) {
            open_error = GetLastError();
        }
        printf("{\"schemaVersion\":1,\"operation\":\"read-only-probe\","
               "\"targetPid\":%lu,\"debugPrivilegeEnabled\":%s,"
               "\"error\":\"open-process-failed\",\"win32Error\":%lu}\n",
               (unsigned long)target_pid,
               debug_privilege_enabled ? "true" : "false",
               (unsigned long)open_error);
        FreeLibrary(vid);
        return 77;
    }

    if (impersonate_target) {
        if (!OpenProcessToken(source_process,
                              TOKEN_QUERY | TOKEN_DUPLICATE,
                              &source_token)) {
            token_open_error = GetLastError();
        } else if (!DuplicateTokenEx(source_token,
                                     TOKEN_QUERY | TOKEN_IMPERSONATE,
                                     NULL,
                                     SecurityImpersonation,
                                     TokenImpersonation,
                                     &impersonation_token)) {
            token_duplicate_error = GetLastError();
        }
    }

    if (requested_handle != 0) {
        HANDLE duplicate = NULL;
        DWORD duplicate_error = ERROR_SUCCESS;
        DWORD impersonation_error = ERROR_SUCCESS;
        DWORD vid_error = ERROR_SUCCESS;
        ULONGLONG partition_id = 0;
        BOOL vid_succeeded = FALSE;
        BOOL impersonation_succeeded = FALSE;
        PVOID name_information = NULL;
        PVOID type_information = NULL;
        VMATE_UNICODE_STRING *name = NULL;
        VMATE_UNICODE_STRING *type = NULL;

        if (!DuplicateHandle(source_process, (HANDLE)requested_handle,
                             GetCurrentProcess(), &duplicate, 0, FALSE,
                             DUPLICATE_SAME_ACCESS)) {
            duplicate_error = GetLastError();
        } else {
            name_information = vmate_query_object_information(
                query_object, duplicate, 1);
            type_information = vmate_query_object_information(
                query_object, duplicate, 2);
            name = (VMATE_UNICODE_STRING *)name_information;
            type = (VMATE_UNICODE_STRING *)type_information;
            if (spawn_target_token) {
                DWORD spawn_token_open_error;
                DWORD spawn_token_duplicate_error;
                DWORD spawn_direct_create_error;
                DWORD spawn_fallback_create_error;
                LONG spawn_token_assignment_status;
                DWORD spawn_wait_error;
                DWORD child_exit_code;
                BOOL spawn_succeeded = vmate_spawn_target_token_probe(
                    source_process,
                    duplicate,
                    &spawn_token_open_error,
                    &spawn_token_duplicate_error,
                    &spawn_direct_create_error,
                    &spawn_fallback_create_error,
                    &spawn_token_assignment_status,
                    &spawn_wait_error,
                    &child_exit_code);

                printf("{\"schemaVersion\":1,"
                       "\"operation\":"
                       "\"read-only-target-process-token-probe\","
                       "\"targetPid\":%lu,"
                       "\"sourceHandle\":\"0x%llX\","
                       "\"duplicateSucceeded\":true,"
                       "\"targetTokenOpenError\":%lu,"
                       "\"targetTokenDuplicateError\":%lu,"
                       "\"directCreateProcessError\":%lu,"
                       "\"fallbackCreateProcessError\":%lu,"
                       "\"tokenAssignmentStatus\":\"0x%08lX\","
                       "\"waitError\":%lu,"
                       "\"childExitCode\":%lu,"
                       "\"childSucceeded\":%s}\n",
                       (unsigned long)target_pid,
                       (unsigned long long)requested_handle,
                       (unsigned long)spawn_token_open_error,
                       (unsigned long)spawn_token_duplicate_error,
                       (unsigned long)spawn_direct_create_error,
                       (unsigned long)spawn_fallback_create_error,
                       (unsigned long)spawn_token_assignment_status,
                       (unsigned long)spawn_wait_error,
                       (unsigned long)child_exit_code,
                       spawn_succeeded ? "true" : "false");
                if (name_information != NULL) {
                    HeapFree(GetProcessHeap(), 0, name_information);
                }
                if (type_information != NULL) {
                    HeapFree(GetProcessHeap(), 0, type_information);
                }
                CloseHandle(duplicate);
                CloseHandle(source_process);
                FreeLibrary(vid);
                return spawn_succeeded ? 0 : 2;
            } else if (!impersonate_target) {
                SetLastError(ERROR_SUCCESS);
                vid_succeeded = get_partition_id(duplicate, &partition_id);
                vid_error = GetLastError();
            } else if (impersonation_token != NULL) {
                SetLastError(ERROR_SUCCESS);
                impersonation_succeeded = SetThreadToken(
                    NULL, impersonation_token);
                impersonation_error = GetLastError();
                if (impersonation_succeeded) {
                    SetLastError(ERROR_SUCCESS);
                    vid_succeeded = get_partition_id(duplicate,
                                                     &partition_id);
                    vid_error = GetLastError();
                    RevertToSelf();
                }
            }
        }

        printf("{\"schemaVersion\":1,"
               "\"operation\":\"read-only-handle-probe\","
               "\"targetPid\":%lu,\"debugPrivilegeEnabled\":%s,"
               "\"targetImpersonationRequested\":%s,"
               "\"targetTokenOpenSucceeded\":%s,"
               "\"targetTokenOpenError\":%lu,"
               "\"targetTokenDuplicateSucceeded\":%s,"
               "\"targetTokenDuplicateError\":%lu,"
               "\"targetImpersonationSucceeded\":%s,"
               "\"targetImpersonationError\":%lu,"
               "\"sourceHandle\":\"0x%llX\","
               "\"duplicateSucceeded\":%s,\"duplicateError\":%lu,"
               "\"vidQuerySucceeded\":%s,\"vidError\":%lu,"
               "\"partitionId\":\"0x%016llX\",\"objectType\":",
               (unsigned long)target_pid,
               debug_privilege_enabled ? "true" : "false",
               impersonate_target ? "true" : "false",
               source_token != NULL ? "true" : "false",
               (unsigned long)token_open_error,
               impersonation_token != NULL ? "true" : "false",
               (unsigned long)token_duplicate_error,
               impersonation_succeeded ? "true" : "false",
               (unsigned long)impersonation_error,
               (unsigned long long)requested_handle,
               duplicate != NULL ? "true" : "false",
               (unsigned long)duplicate_error,
               vid_succeeded ? "true" : "false",
               (unsigned long)vid_error,
               (unsigned long long)partition_id);
        if (type != NULL && type->buffer != NULL) {
            vmate_print_json_wide_string(type->buffer,
                                          type->length / sizeof(wchar_t));
        } else {
            fputs("null", stdout);
        }
        fputs(",\"objectName\":", stdout);
        if (name != NULL && name->buffer != NULL) {
            vmate_print_json_wide_string(name->buffer,
                                          name->length / sizeof(wchar_t));
        } else {
            fputs("null", stdout);
        }
        fputs("}\n", stdout);

        if (name_information != NULL) {
            HeapFree(GetProcessHeap(), 0, name_information);
        }
        if (type_information != NULL) {
            HeapFree(GetProcessHeap(), 0, type_information);
        }
        if (duplicate != NULL) {
            CloseHandle(duplicate);
        }
        if (impersonation_token != NULL) {
            CloseHandle(impersonation_token);
        }
        if (source_token != NULL) {
            CloseHandle(source_token);
        }
        CloseHandle(source_process);
        FreeLibrary(vid);
        return vid_succeeded && partition_id != 0 ? 0 : 2;
    }

    handle_information = vmate_query_system_handles(
        query_system_information, &query_error);
    if (handle_information == NULL) {
        printf("{\"schemaVersion\":1,\"operation\":\"read-only-probe\","
               "\"targetPid\":%lu,\"debugPrivilegeEnabled\":%s,"
               "\"error\":\"handle-query-failed\",\"nativeStatus\":%lu}\n",
               (unsigned long)target_pid,
               debug_privilege_enabled ? "true" : "false",
               (unsigned long)query_error);
        CloseHandle(source_process);
        FreeLibrary(vid);
        return 70;
    }

    printf("{\"schemaVersion\":1,\"operation\":\"read-only-probe\","
           "\"targetPid\":%lu,\"debugPrivilegeEnabled\":%s,"
           "\"partitions\":[",
           (unsigned long)target_pid,
           debug_privilege_enabled ? "true" : "false");

    for (index = 0; index < handle_information->number_of_handles; index++) {
        VMATE_SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX *entry =
            &handle_information->handles[index];
        HANDLE duplicate = NULL;
        ULONGLONG partition_id = 0;
        DWORD vid_error = ERROR_SUCCESS;

        if (entry->unique_process_id != (ULONG_PTR)target_pid) {
            continue;
        }
        matching_handles++;
        if (!DuplicateHandle(source_process, (HANDLE)entry->handle_value,
                             GetCurrentProcess(), &duplicate, 0, FALSE,
                             DUPLICATE_SAME_ACCESS)) {
            duplicate_failures++;
            continue;
        }
        duplicated_handles++;
        if (impersonate_target && impersonation_token != NULL) {
            if (SetThreadToken(NULL, impersonation_token)) {
                SetLastError(ERROR_SUCCESS);
                if (!get_partition_id(duplicate, &partition_id)) {
                    vid_error = GetLastError();
                    partition_id = 0;
                }
                RevertToSelf();
            }
        } else if (!impersonate_target) {
            SetLastError(ERROR_SUCCESS);
            if (!get_partition_id(duplicate, &partition_id)) {
                vid_error = GetLastError();
                partition_id = 0;
            }
        }
        if (partition_id != 0) {
            PVOID name_information = vmate_query_object_information(
                query_object, duplicate, 1);
            PVOID type_information = vmate_query_object_information(
                query_object, duplicate, 2);
            VMATE_UNICODE_STRING *name =
                (VMATE_UNICODE_STRING *)name_information;
            VMATE_UNICODE_STRING *type =
                (VMATE_UNICODE_STRING *)type_information;

            if (!first_partition) {
                putchar(',');
            }
            printf("{\"sourceHandle\":\"0x%llX\","
                   "\"partitionId\":\"0x%016llX\","
                   "\"objectTypeIndex\":%u,\"grantedAccess\":\"0x%08lX\","
                   "\"objectType\":",
                   (unsigned long long)entry->handle_value,
                   (unsigned long long)partition_id,
                   (unsigned int)entry->object_type_index,
                   (unsigned long)entry->granted_access);
            if (type != NULL && type->buffer != NULL) {
                vmate_print_json_wide_string(type->buffer,
                                              type->length / sizeof(wchar_t));
            } else {
                fputs("null", stdout);
            }
            fputs(",\"objectName\":", stdout);
            if (name != NULL && name->buffer != NULL) {
                vmate_print_json_wide_string(name->buffer,
                                              name->length / sizeof(wchar_t));
            } else {
                fputs("null", stdout);
            }
            putchar('}');
            if (name_information != NULL) {
                HeapFree(GetProcessHeap(), 0, name_information);
            }
            if (type_information != NULL) {
                HeapFree(GetProcessHeap(), 0, type_information);
            }
            first_partition = FALSE;
            partition_handles++;
        } else if (vid_error == ERROR_SUCCESS) {
            zero_id_queries++;
        }
        else if (vid_error == ERROR_ACCESS_DENIED) {
            access_denied_queries++;
            if (list_access_denied &&
                access_denied_candidate_count <
                    VMATE_MAX_ACCESS_DENIED_CANDIDATES) {
                access_denied_candidates[access_denied_candidate_count] =
                    entry->handle_value;
                access_denied_candidate_count++;
            }
        }
        CloseHandle(duplicate);
    }

    printf("],\"matchingHandles\":%llu,\"duplicatedHandles\":%llu,"
           "\"duplicateFailures\":%llu,"
           "\"partitionHandleCount\":%llu,\"zeroIdQueryCount\":%llu,"
           "\"accessDeniedQueryCount\":%llu,"
           "\"accessDeniedEnumerationRequested\":%s,"
           "\"accessDeniedCandidateHandles\":[",
           matching_handles, duplicated_handles, duplicate_failures,
           partition_handles, zero_id_queries, access_denied_queries,
           list_access_denied ? "true" : "false");
    for (index = 0; index < access_denied_candidate_count; ++index) {
        if (index != 0) {
            putchar(',');
        }
        printf("\"0x%llX\"",
               (unsigned long long)access_denied_candidates[index]);
    }
    printf("],\"accessDeniedCandidateCount\":%lu,"
           "\"accessDeniedCandidateListTruncated\":%s}\n",
           (unsigned long)access_denied_candidate_count,
           access_denied_queries > access_denied_candidate_count ?
               "true" : "false");

    HeapFree(GetProcessHeap(), 0, handle_information);
    if (impersonation_token != NULL) {
        CloseHandle(impersonation_token);
    }
    if (source_token != NULL) {
        CloseHandle(source_token);
    }
    CloseHandle(source_process);
    FreeLibrary(vid);
    return partition_handles > 0 ? 0 : 2;
}
