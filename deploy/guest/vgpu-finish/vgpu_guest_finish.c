#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <bcrypt.h>
#include <cfgmgr32.h>
#include <initguid.h>
#include <devguid.h>
#include <setupapi.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#include "build_metadata.h"

#define TOKEN_RESOURCE_ID 101
#define TOKEN_MIN_BYTES 1024u
#define TOKEN_MAX_BYTES (1024u * 1024u)
#define GTX1050_NAME "NVIDIA GeForce GTX 1050"
#define GTX1050_PROFILE "gtx1050_2gb"
#define GTX1050_DRIVER_VERSION "31.0.15.3833"
#define GTX1050_PATCHED_INF_SHA256 \
    "c7e38910c800fc9f5e72ec4d3613594a64b3e7b0465114e81a167ead43d42e4f"

typedef enum GpuNameResult {
    GPU_NAME_OK = 0,
    GPU_NAME_ENUMERATION_FAILED,
    GPU_NAME_NOT_FOUND,
    GPU_NAME_AMBIGUOUS,
    GPU_NAME_WRITE_FAILED,
    GPU_NAME_VERIFY_FAILED
} GpuNameResult;

typedef enum TargetHintResult {
    TARGET_HINT_OK = 0,
    TARGET_HINT_FIRMWARE_FAILED,
    TARGET_HINT_NOT_FOUND,
    TARGET_HINT_AMBIGUOUS,
    TARGET_HINT_INVALID
} TargetHintResult;

#pragma pack(push, 1)
typedef struct RawSmbiosData {
    BYTE used_20_calling_method;
    BYTE major_version;
    BYTE minor_version;
    BYTE dmi_revision;
    DWORD length;
    BYTE table_data[1];
} RawSmbiosData;

typedef struct SmbiosHeader {
    BYTE type;
    BYTE length;
    WORD handle;
} SmbiosHeader;
#pragma pack(pop)

static void show_error(const wchar_t *message)
{
    fwprintf(stderr, L"[ERROR] %ls\n", message);
    MessageBoxW(NULL, message, L"vGPU preparation failed",
                MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
}

static BOOL is_administrator(void)
{
    SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
    PSID administrators = NULL;
    BOOL member = FALSE;

    if (!AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                  DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                  &administrators)) {
        return FALSE;
    }
    if (!CheckTokenMembership(NULL, administrators, &member)) {
        member = FALSE;
    }
    FreeSid(administrators);
    return member;
}

static BOOL read_system_uuid(wchar_t uuid_text[37])
{
    const DWORD provider = ((DWORD)'R' << 24) | ((DWORD)'S' << 16) |
                           ((DWORD)'M' << 8) | (DWORD)'B';
    DWORD bytes = GetSystemFirmwareTable(provider, 0, NULL, 0);
    RawSmbiosData *raw = NULL;
    BYTE *cursor;
    BYTE *end;
    BOOL found = FALSE;

    if (bytes < sizeof(RawSmbiosData)) {
        return FALSE;
    }
    raw = (RawSmbiosData *)HeapAlloc(GetProcessHeap(), 0, bytes);
    if (!raw || GetSystemFirmwareTable(provider, 0, raw, bytes) != bytes ||
        raw->length > bytes - 8) {
        if (raw) HeapFree(GetProcessHeap(), 0, raw);
        return FALSE;
    }

    cursor = raw->table_data;
    end = cursor + raw->length;
    while (cursor + sizeof(SmbiosHeader) <= end) {
        SmbiosHeader *header = (SmbiosHeader *)cursor;
        BYTE *next;
        const BYTE *uuid;

        if (header->length < sizeof(SmbiosHeader) || cursor + header->length > end) {
            break;
        }
        if (header->type == 1 && header->length >= 0x19) {
            uuid = cursor + 8;
            _snwprintf(uuid_text, 37,
                L"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-"
                L"%02x%02x%02x%02x%02x%02x",
                uuid[3], uuid[2], uuid[1], uuid[0],
                uuid[5], uuid[4], uuid[7], uuid[6],
                uuid[8], uuid[9], uuid[10], uuid[11], uuid[12],
                uuid[13], uuid[14], uuid[15]);
            uuid_text[36] = L'\0';
            found = TRUE;
            break;
        }

        next = cursor + header->length;
        while (next + 1 < end && !(next[0] == 0 && next[1] == 0)) {
            ++next;
        }
        if (next + 1 >= end) {
            break;
        }
        cursor = next + 2;
    }
    HeapFree(GetProcessHeap(), 0, raw);
    return found;
}

static char ascii_lower(char value)
{
    if (value >= 'A' && value <= 'Z') {
        return (char)(value + ('a' - 'A'));
    }
    return value;
}

static BOOL ascii_contains_icase(const char *text, size_t text_length,
                                 const char *needle)
{
    size_t needle_length = strlen(needle);
    size_t offset;
    size_t index;

    if (needle_length == 0 || needle_length > text_length) {
        return FALSE;
    }
    for (offset = 0; offset + needle_length <= text_length; ++offset) {
        for (index = 0; index < needle_length; ++index) {
            if (ascii_lower(text[offset + index]) !=
                ascii_lower(needle[index])) {
                break;
            }
        }
        if (index == needle_length) {
            return TRUE;
        }
    }
    return FALSE;
}

static BOOL is_safe_gpu_name_ascii(const char *name, size_t length)
{
    size_t index;

    if (length < 8 || length > 31 || memcmp(name, "NVIDIA ", 7) != 0 ||
        name[7] == ' ' || name[length - 1] == ' ' ||
        ascii_contains_icase(name, length, "GRID") ||
        ascii_contains_icase(name, length, "RTX6000")) {
        return FALSE;
    }
    for (index = 0; index < length; ++index) {
        char value = name[index];
        if (!((value >= 'A' && value <= 'Z') ||
              (value >= 'a' && value <= 'z') ||
              (value >= '0' && value <= '9') ||
              value == ' ' || value == '.' || value == '_' ||
              value == '+' || value == '(' || value == ')' ||
              value == '-')) {
            return FALSE;
        }
    }
    return TRUE;
}

/* The host injects exactly one Type 11 OEM string only for the finish-rescue
 * boot.  A saved NVIDIA AdapterString is not authoritative on a fresh driver
 * install, so the signed-off host intent must come from this transient hint. */
static TargetHintResult read_target_gpu_hint(wchar_t target_wide[32],
                                             char target_ascii[32])
{
    static const char prefix[] = "QEMU_VGPU_TARGET=";
    const size_t prefix_length = sizeof(prefix) - 1;
    const DWORD provider = ((DWORD)'R' << 24) | ((DWORD)'S' << 16) |
                           ((DWORD)'M' << 8) | (DWORD)'B';
    DWORD bytes = GetSystemFirmwareTable(provider, 0, NULL, 0);
    RawSmbiosData *raw = NULL;
    BYTE *cursor;
    BYTE *end;
    DWORD matches = 0;
    TargetHintResult result = TARGET_HINT_FIRMWARE_FAILED;

    target_wide[0] = L'\0';
    target_ascii[0] = '\0';
    if (bytes < sizeof(RawSmbiosData)) {
        return TARGET_HINT_FIRMWARE_FAILED;
    }
    raw = (RawSmbiosData *)HeapAlloc(GetProcessHeap(), 0, bytes);
    if (!raw || GetSystemFirmwareTable(provider, 0, raw, bytes) != bytes ||
        raw->length > bytes - 8) {
        if (raw) HeapFree(GetProcessHeap(), 0, raw);
        return TARGET_HINT_FIRMWARE_FAILED;
    }

    cursor = raw->table_data;
    end = cursor + raw->length;
    while (cursor + sizeof(SmbiosHeader) <= end) {
        SmbiosHeader *header = (SmbiosHeader *)cursor;
        BYTE *strings;
        BYTE *terminator;
        BYTE *next;

        if (header->length < sizeof(SmbiosHeader) ||
            cursor + header->length > end) {
            goto done;
        }
        strings = cursor + header->length;
        terminator = strings;
        while (terminator + 1 < end &&
               !(terminator[0] == 0 && terminator[1] == 0)) {
            ++terminator;
        }
        if (terminator + 1 >= end) {
            goto done;
        }
        next = terminator + 2;

        if (header->type == 11) {
            BYTE count;
            BYTE string_index;
            BYTE *value;

            if (header->length < 5) {
                goto done;
            }
            count = cursor[4];
            value = strings;
            for (string_index = 0; string_index < count; ++string_index) {
                BYTE *nul = value;
                size_t value_length;

                if (value >= terminator || *value == 0) {
                    goto done;
                }
                while (nul < terminator && *nul != 0) {
                    ++nul;
                }
                value_length = (size_t)(nul - value);
                if (value_length >= prefix_length &&
                    memcmp(value, prefix, prefix_length) == 0) {
                    const char *name = (const char *)value + prefix_length;
                    size_t name_length = value_length - prefix_length;
                    size_t index;

                    if (!is_safe_gpu_name_ascii(name, name_length)) {
                        result = TARGET_HINT_INVALID;
                        goto done;
                    }
                    ++matches;
                    if (matches != 1) {
                        result = TARGET_HINT_AMBIGUOUS;
                        goto done;
                    }
                    memcpy(target_ascii, name, name_length);
                    target_ascii[name_length] = '\0';
                    for (index = 0; index < name_length; ++index) {
                        target_wide[index] = (wchar_t)(unsigned char)name[index];
                    }
                    target_wide[name_length] = L'\0';
                }
                value = nul + 1;
            }
        }
        if (header->type == 127) {
            break;
        }
        cursor = next;
    }

    result = matches == 1 ? TARGET_HINT_OK : TARGET_HINT_NOT_FOUND;

done:
    HeapFree(GetProcessHeap(), 0, raw);
    return result;
}

static BOOL join_path(wchar_t *out, size_t count,
                      const wchar_t *left, const wchar_t *right)
{
    int written = _snwprintf(out, count, L"%ls\\%ls", left, right);
    return written > 0 && (size_t)written < count;
}

static BOOL run_system_command_with_flags(const wchar_t *exe_name,
                                          const wchar_t *arguments,
                                          DWORD creation_flags,
                                          DWORD *exit_code)
{
    wchar_t system_dir[MAX_PATH];
    wchar_t exe_path[MAX_PATH];
    wchar_t command_line[1024];
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};

    if (!GetSystemDirectoryW(system_dir, MAX_PATH) ||
        !join_path(exe_path, MAX_PATH, system_dir, exe_name)) {
        return FALSE;
    }
    {
        int written = _snwprintf(command_line, 1024, L"\"%ls\" %ls",
                                 exe_path, arguments ? arguments : L"");
        if (written < 0 || written >= 1024) {
            return FALSE;
        }
    }

    startup.cb = sizeof(startup);
    if (!CreateProcessW(exe_path, command_line, NULL, NULL, FALSE,
                        creation_flags, NULL, NULL, &startup, &process)) {
        return FALSE;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    if (!GetExitCodeProcess(process.hProcess, exit_code)) {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return FALSE;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return TRUE;
}

static BOOL run_system_command(const wchar_t *exe_name,
                               const wchar_t *arguments,
                               DWORD *exit_code)
{
    return run_system_command_with_flags(exe_name, arguments,
                                         CREATE_NO_WINDOW, exit_code);
}

static BOOL is_safe_oem_inf(const char *value)
{
    size_t length;
    size_t index;

    if (!value || strncmp(value, "oem", 3) != 0) {
        return FALSE;
    }
    length = strlen(value);
    if (length < 8 || length > 31 || strcmp(value + length - 4, ".inf") != 0) {
        return FALSE;
    }
    for (index = 3; index < length - 4; ++index) {
        if (value[index] < '0' || value[index] > '9') {
            return FALSE;
        }
    }
    return TRUE;
}

static BOOL get_driver_stage_receipt_path(wchar_t path[MAX_PATH])
{
    wchar_t program_data[MAX_PATH];
    wchar_t qemu_dir[MAX_PATH];
    wchar_t stage_dir[MAX_PATH];

    return GetEnvironmentVariableW(L"ProgramData", program_data, MAX_PATH) &&
           join_path(qemu_dir, MAX_PATH, program_data, L"QEMU") &&
           join_path(stage_dir, MAX_PATH, qemu_dir, L"vgpu-driver-stage") &&
           join_path(path, MAX_PATH, stage_dir,
                     L"538.33-gtx1050_2gb.receipt");
}

static BOOL read_gtx1050_driver_receipt(char published_inf[32])
{
    wchar_t path[MAX_PATH];
    HANDLE file = INVALID_HANDLE_VALUE;
    LARGE_INTEGER size;
    DWORD bytes_read = 0;
    char raw[1024];
    char normalized[1024];
    char expected[1024];
    const char *prefix =
        "QEMU_VGPU_DRIVER_STAGE_V1\n"
        "PROFILE=" GTX1050_PROFILE "\n"
        "PCI_ID=10DE:1C81\n"
        "SUBSYSTEM_ID=1028:11C0\n"
        "DRIVER_VERSION=" GTX1050_DRIVER_VERSION "\n"
        "DRIVER_INF=";
    const char *inf_start;
    const char *inf_end;
    size_t raw_index;
    size_t normalized_size = 0;
    size_t inf_length;
    int expected_size;
    BOOL ok = FALSE;

    published_inf[0] = '\0';
    if (!get_driver_stage_receipt_path(path)) {
        return FALSE;
    }
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE || !GetFileSizeEx(file, &size) ||
        size.QuadPart <= 0 || size.QuadPart >= (LONGLONG)sizeof(raw) ||
        !ReadFile(file, raw, (DWORD)size.QuadPart, &bytes_read, NULL) ||
        bytes_read != (DWORD)size.QuadPart) {
        goto done;
    }
    for (raw_index = 0; raw_index < bytes_read; ++raw_index) {
        unsigned char value = (unsigned char)raw[raw_index];
        if (value == '\r') {
            continue;
        }
        if ((value < 0x20 && value != '\n') || value > 0x7e ||
            normalized_size + 1 >= sizeof(normalized)) {
            goto done;
        }
        normalized[normalized_size++] = (char)value;
    }
    normalized[normalized_size] = '\0';
    if (strncmp(normalized, prefix, strlen(prefix)) != 0) {
        goto done;
    }
    inf_start = normalized + strlen(prefix);
    inf_end = strchr(inf_start, '\n');
    if (!inf_end) {
        goto done;
    }
    inf_length = (size_t)(inf_end - inf_start);
    if (inf_length == 0 || inf_length >= 32) {
        goto done;
    }
    memcpy(published_inf, inf_start, inf_length);
    published_inf[inf_length] = '\0';
    if (!is_safe_oem_inf(published_inf)) {
        goto done;
    }
    expected_size = snprintf(expected, sizeof(expected),
        "%s%s\nPATCHED_INF_SHA256=%s\n", prefix, published_inf,
        GTX1050_PATCHED_INF_SHA256);
    if (expected_size <= 0 || (size_t)expected_size >= sizeof(expected) ||
        strcmp(normalized, expected) != 0) {
        published_inf[0] = '\0';
        goto done;
    }
    ok = TRUE;

done:
    if (file != INVALID_HANDLE_VALUE) {
        CloseHandle(file);
    }
    return ok;
}

static BOOL ensure_gtx1050_driver_staged(char published_inf[32],
                                         DWORD *stage_exit)
{
    wchar_t module_path[MAX_PATH];
    wchar_t *separator;
    wchar_t script_path[MAX_PATH];
    wchar_t artifact_path[MAX_PATH];
    wchar_t arguments[3 * MAX_PATH];
    DWORD script_attributes;
    DWORD artifact_attributes;

    published_inf[0] = '\0';
    *stage_exit = 1;
    if (!GetModuleFileNameW(NULL, module_path, MAX_PATH)) {
        return FALSE;
    }
    separator = wcsrchr(module_path, L'\\');
    if (!separator) {
        return FALSE;
    }
    *separator = L'\0';
    if (!join_path(script_path, MAX_PATH, module_path,
                   L"stage-patched-vgpu-driver.ps1") ||
        !join_path(artifact_path, MAX_PATH, module_path,
                   L"538.33-gtx1050_2gb-patched")) {
        return FALSE;
    }
    script_attributes = GetFileAttributesW(script_path);
    artifact_attributes = GetFileAttributesW(artifact_path);

    if (script_attributes != INVALID_FILE_ATTRIBUTES &&
        !(script_attributes & FILE_ATTRIBUTE_DIRECTORY) &&
        artifact_attributes != INVALID_FILE_ATTRIBUTES &&
        (artifact_attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        int written = _snwprintf(arguments, 3 * MAX_PATH,
            L"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass "
            L"-File \"%ls\" -ArtifactRoot \"%ls\"",
            script_path, artifact_path);
        if (written <= 0 || written >= 3 * MAX_PATH ||
            !run_system_command_with_flags(
                L"WindowsPowerShell\\v1.0\\powershell.exe", arguments, 0,
                stage_exit) || *stage_exit != 0) {
            return FALSE;
        }
    } else {
        /* Missing or partial bundle contents must never fall back to a stale
         * receipt.  The host always supplies the complete GTX 1050 ZIP. */
        return FALSE;
    }

    /* The complete bundle always reruns the fail-closed verifier first. */
    return read_gtx1050_driver_receipt(published_inf);
}

static BOOL set_fast_startup_disabled(void)
{
    static const wchar_t key_path[] =
        L"SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power";
    HKEY key = NULL;
    DWORD zero = 0;
    DWORD type = 0;
    DWORD value = 1;
    DWORD bytes = sizeof(value);
    LONG status;

    status = RegCreateKeyExW(HKEY_LOCAL_MACHINE, key_path, 0, NULL, 0,
                             KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, NULL);
    if (status != ERROR_SUCCESS) {
        return FALSE;
    }
    status = RegSetValueExW(key, L"HiberbootEnabled", 0, REG_DWORD,
                            (const BYTE *)&zero, sizeof(zero));
    if (status == ERROR_SUCCESS) {
        status = RegQueryValueExW(key, L"HiberbootEnabled", NULL, &type,
                                  (BYTE *)&value, &bytes);
    }
    RegCloseKey(key);
    return status == ERROR_SUCCESS && type == REG_DWORD && value == 0;
}

static BOOL get_device_string_property(HDEVINFO devices,
                                       SP_DEVINFO_DATA *device,
                                       DWORD property,
                                       wchar_t *value,
                                       DWORD value_bytes,
                                       DWORD *property_type)
{
    DWORD required = 0;

    if (!value || value_bytes < sizeof(wchar_t)) {
        return FALSE;
    }
    ZeroMemory(value, value_bytes);
    if (!SetupDiGetDeviceRegistryPropertyW(devices, device, property,
                                            property_type, (PBYTE)value,
                                            value_bytes, &required)) {
        return FALSE;
    }
    value[(value_bytes / sizeof(wchar_t)) - 1] = L'\0';
    return required <= value_bytes;
}

static BOOL multi_sz_has_nvidia_pci_id(const wchar_t *ids,
                                       size_t capacity_chars)
{
    static const wchar_t prefix[] = L"PCI\\VEN_10DE";
    const size_t prefix_chars = (sizeof(prefix) / sizeof(prefix[0])) - 1;
    const wchar_t *id = ids;
    const wchar_t *end = ids + capacity_chars;

    while (id < end && *id) {
        size_t remaining = (size_t)(end - id);
        size_t id_chars = wcsnlen(id, remaining);

        if (id_chars == remaining) {
            return FALSE;
        }
        if (id_chars > prefix_chars &&
            _wcsnicmp(id, prefix, prefix_chars) == 0 &&
            id[prefix_chars] == L'&') {
            return TRUE;
        }
        id += id_chars + 1;
    }
    return FALSE;
}

static BOOL multi_sz_has_gtx1050_pci_id(const wchar_t *ids,
                                        size_t capacity_chars)
{
    static const wchar_t target[] =
        L"PCI\\VEN_10DE&DEV_1C81&SUBSYS_11C01028";
    const size_t target_chars = (sizeof(target) / sizeof(target[0])) - 1;
    const wchar_t *id = ids;
    const wchar_t *end = ids + capacity_chars;

    while (id < end && *id) {
        size_t remaining = (size_t)(end - id);
        size_t id_chars = wcsnlen(id, remaining);

        if (id_chars == remaining) {
            return FALSE;
        }
        if (id_chars >= target_chars &&
            _wcsnicmp(id, target, target_chars) == 0 &&
            (id[target_chars] == L'\0' || id[target_chars] == L'&')) {
            return TRUE;
        }
        id += id_chars + 1;
    }
    return FALSE;
}

static BOOL is_exact_gtx1050_display(HDEVINFO devices,
                                     SP_DEVINFO_DATA *device)
{
    wchar_t hardware_ids[4096];
    DWORD type = 0;

    return get_device_string_property(devices, device, SPDRP_HARDWAREID,
                                      hardware_ids, sizeof(hardware_ids),
                                      &type) &&
           type == REG_MULTI_SZ &&
           multi_sz_has_gtx1050_pci_id(
               hardware_ids, sizeof(hardware_ids) / sizeof(wchar_t));
}

static BOOL is_target_nvidia_display(HDEVINFO devices,
                                     SP_DEVINFO_DATA *device)
{
    wchar_t hardware_ids[4096];
    wchar_t service[256];
    wchar_t enumerator[64];
    DWORD type = 0;

    if (!get_device_string_property(devices, device, SPDRP_HARDWAREID,
                                    hardware_ids, sizeof(hardware_ids), &type) ||
        type != REG_MULTI_SZ ||
        !multi_sz_has_nvidia_pci_id(hardware_ids,
                                    sizeof(hardware_ids) / sizeof(wchar_t))) {
        return FALSE;
    }
    if (!get_device_string_property(devices, device, SPDRP_SERVICE,
                                    service, sizeof(service), &type) ||
        type != REG_SZ || _wcsicmp(service, L"nvlddmkm") != 0) {
        return FALSE;
    }
    if (!get_device_string_property(devices, device, SPDRP_ENUMERATOR_NAME,
                                    enumerator, sizeof(enumerator), &type) ||
        type != REG_SZ || _wcsicmp(enumerator, L"PCI") != 0) {
        return FALSE;
    }
    return TRUE;
}

static BOOL read_saved_adapter_string(HDEVINFO devices,
                                      SP_DEVINFO_DATA *device,
                                      const wchar_t *target_name,
                                      BOOL *matches_target,
                                      DWORD *win32_error)
{
    HKEY driver_key;
    wchar_t adapter_string[128];
    DWORD type = 0;
    DWORD bytes = sizeof(adapter_string);
    LONG status;

    *matches_target = FALSE;
    ZeroMemory(adapter_string, sizeof(adapter_string));
    driver_key = SetupDiOpenDevRegKey(devices, device, DICS_FLAG_GLOBAL, 0,
                                     DIREG_DRV, KEY_QUERY_VALUE);
    if (driver_key == INVALID_HANDLE_VALUE) {
        *win32_error = GetLastError();
        return FALSE;
    }
    status = RegQueryValueExW(driver_key,
                              L"HardwareInformation.AdapterString", NULL,
                              &type, (BYTE *)adapter_string, &bytes);
    RegCloseKey(driver_key);
    if (status != ERROR_SUCCESS) {
        *win32_error = (DWORD)status;
        return FALSE;
    }
    if (type != REG_SZ || bytes < sizeof(wchar_t) ||
        bytes > sizeof(adapter_string) || bytes % sizeof(wchar_t) != 0 ||
        adapter_string[(bytes / sizeof(wchar_t)) - 1] != L'\0') {
        *win32_error = ERROR_INVALID_DATA;
        return FALSE;
    }
    *matches_target = wcscmp(adapter_string, target_name) == 0;
    return TRUE;
}

static GpuNameResult set_gpu_friendly_name(const wchar_t *target_name,
                                           BOOL prefer_gtx1050,
                                           wchar_t *instance_id,
                                           DWORD instance_id_chars,
                                           BOOL *adapter_string_read,
                                           BOOL *adapter_string_matches,
                                           DWORD *adapter_string_error,
                                           DWORD *win32_error)
{
    HDEVINFO devices;
    SP_DEVINFO_DATA device;
    SP_DEVINFO_DATA selected;
    SP_DEVINFO_DATA exact_selected;
    DWORD index;
    DWORD matches = 0;
    DWORD exact_matches = 0;
    DWORD type = 0;
    wchar_t verified_name[128];

    if (instance_id && instance_id_chars) {
        instance_id[0] = L'\0';
    }
    if (win32_error) {
        *win32_error = ERROR_SUCCESS;
    }
    *adapter_string_read = FALSE;
    *adapter_string_matches = FALSE;
    *adapter_string_error = ERROR_SUCCESS;

    /* Rescue mode hides the vGPU, so enumerate installed display devnodes,
     * including the saved non-present NVIDIA device. */
    devices = SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, NULL, NULL, 0);
    if (devices == INVALID_HANDLE_VALUE) {
        if (win32_error) *win32_error = GetLastError();
        return GPU_NAME_ENUMERATION_FAILED;
    }

    ZeroMemory(&selected, sizeof(selected));
    selected.cbSize = sizeof(selected);
    ZeroMemory(&exact_selected, sizeof(exact_selected));
    exact_selected.cbSize = sizeof(exact_selected);
    for (index = 0; ; ++index) {
        ZeroMemory(&device, sizeof(device));
        device.cbSize = sizeof(device);
        if (!SetupDiEnumDeviceInfo(devices, index, &device)) {
            DWORD error = GetLastError();
            if (error != ERROR_NO_MORE_ITEMS) {
                if (win32_error) *win32_error = error;
                SetupDiDestroyDeviceInfoList(devices);
                return GPU_NAME_ENUMERATION_FAILED;
            }
            break;
        }
        if (is_target_nvidia_display(devices, &device)) {
            ++matches;
            selected = device;
            if (is_exact_gtx1050_display(devices, &device)) {
                ++exact_matches;
                exact_selected = device;
            }
        }
    }

    /* A completed B -> strict-A transition leaves the original DEV_1E30
     * devnode in Driver Store while DEV_1C81 becomes the active identity.
     * On a later token refresh/recovery, prefer the one exact audited GTX 1050
     * devnode.  During the first B rescue there is no DEV_1C81 yet, so the one
     * NVIDIA/nvlddmkm fallback remains valid. */
    if (prefer_gtx1050 && exact_matches == 1) {
        selected = exact_selected;
    } else if (prefer_gtx1050 && exact_matches > 1) {
        SetupDiDestroyDeviceInfoList(devices);
        return GPU_NAME_AMBIGUOUS;
    } else if (matches == 0) {
        SetupDiDestroyDeviceInfoList(devices);
        return GPU_NAME_NOT_FOUND;
    } else if (matches != 1) {
        SetupDiDestroyDeviceInfoList(devices);
        return GPU_NAME_AMBIGUOUS;
    }
    if (!SetupDiGetDeviceInstanceIdW(devices, &selected, instance_id,
                                     instance_id_chars, NULL)) {
        if (win32_error) *win32_error = GetLastError();
        SetupDiDestroyDeviceInfoList(devices);
        return GPU_NAME_ENUMERATION_FAILED;
    }

    /* Read the driver-owned value for diagnostics only.  It can legitimately
     * contain the physical/old profile name on a fresh driver install, so it
     * must never override the transient host SMBIOS target hint. */
    *adapter_string_read = read_saved_adapter_string(
        devices, &selected, target_name, adapter_string_matches,
        adapter_string_error);

    /* SPDRP_DEVICEDESC is owned by the INF.  FriendlyName is the safe
     * per-device override that Device Manager displays, so do not rewrite the
     * INF description or its class-driver metadata. */
    if (!SetupDiSetDeviceRegistryPropertyW(
            devices, &selected, SPDRP_FRIENDLYNAME,
            (const BYTE *)target_name,
            (DWORD)((wcslen(target_name) + 1) * sizeof(wchar_t)))) {
        if (win32_error) *win32_error = GetLastError();
        SetupDiDestroyDeviceInfoList(devices);
        return GPU_NAME_WRITE_FAILED;
    }
    if (!get_device_string_property(devices, &selected, SPDRP_FRIENDLYNAME,
                                    verified_name, sizeof(verified_name), &type)) {
        if (win32_error) *win32_error = GetLastError();
        SetupDiDestroyDeviceInfoList(devices);
        return GPU_NAME_VERIFY_FAILED;
    }
    if (type != REG_SZ || wcscmp(verified_name, target_name) != 0) {
        if (win32_error) *win32_error = ERROR_INVALID_DATA;
        SetupDiDestroyDeviceInfoList(devices);
        return GPU_NAME_VERIFY_FAILED;
    }

    SetupDiDestroyDeviceInfoList(devices);
    return GPU_NAME_OK;
}

static BOOL sha256(const BYTE *data, DWORD size, BYTE digest[32])
{
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    PUCHAR object = NULL;
    DWORD object_size = 0;
    DWORD result_size = 0;
    NTSTATUS status;
    BOOL ok = FALSE;

    status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                         NULL, 0);
    if (status < 0) {
        goto done;
    }
    status = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                               (PUCHAR)&object_size, sizeof(object_size),
                               &result_size, 0);
    if (status < 0 || object_size == 0) {
        goto done;
    }
    object = (PUCHAR)HeapAlloc(GetProcessHeap(), 0, object_size);
    if (!object) {
        goto done;
    }
    status = BCryptCreateHash(algorithm, &hash, object, object_size,
                              NULL, 0, 0);
    if (status < 0 || BCryptHashData(hash, (PUCHAR)data, size, 0) < 0 ||
        BCryptFinishHash(hash, digest, 32, 0) < 0) {
        goto done;
    }
    ok = TRUE;

done:
    if (hash) {
        BCryptDestroyHash(hash);
    }
    if (object) {
        SecureZeroMemory(object, object_size);
        HeapFree(GetProcessHeap(), 0, object);
    }
    if (algorithm) {
        BCryptCloseAlgorithmProvider(algorithm, 0);
    }
    return ok;
}

static int hex_value(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static BOOL digest_matches(const BYTE digest[32])
{
    size_t i;
    for (i = 0; i < 32; ++i) {
        int high = hex_value(VGPU_TOKEN_SHA256[i * 2]);
        int low = hex_value(VGPU_TOKEN_SHA256[i * 2 + 1]);
        if (high < 0 || low < 0 || digest[i] != (BYTE)((high << 4) | low)) {
            return FALSE;
        }
    }
    return VGPU_TOKEN_SHA256[64] == '\0';
}

static BOOL looks_like_html(const BYTE *data, DWORD size)
{
    DWORD i;
    DWORD limit = size < 256 ? size : 256;
    for (i = 0; i + 5 < limit; ++i) {
        if (data[i] != '<') continue;
        if ((data[i + 1] == 'h' || data[i + 1] == 'H') &&
            (data[i + 2] == 't' || data[i + 2] == 'T') &&
            (data[i + 3] == 'm' || data[i + 3] == 'M') &&
            (data[i + 4] == 'l' || data[i + 4] == 'L')) {
            return TRUE;
        }
        if (i + 9 < limit && data[i + 1] == '!' &&
            (data[i + 2] == 'd' || data[i + 2] == 'D') &&
            (data[i + 3] == 'o' || data[i + 3] == 'O') &&
            (data[i + 4] == 'c' || data[i + 4] == 'C')) {
            return TRUE;
        }
    }
    return FALSE;
}

static BOOL create_directory_if_needed(const wchar_t *path)
{
    if (CreateDirectoryW(path, NULL)) {
        return TRUE;
    }
    return GetLastError() == ERROR_ALREADY_EXISTS &&
           (GetFileAttributesW(path) & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

static BOOL write_all(HANDLE file, const BYTE *data, DWORD size)
{
    DWORD offset = 0;
    while (offset < size) {
        DWORD written = 0;
        if (!WriteFile(file, data + offset, size - offset, &written, NULL) ||
            written == 0) {
            return FALSE;
        }
        offset += written;
    }
    return TRUE;
}

static BOOL get_prepared_marker_path(const wchar_t *uuid,
                                     wchar_t marker_dir[MAX_PATH],
                                     wchar_t marker_path[MAX_PATH])
{
    wchar_t program_data[MAX_PATH];
    wchar_t marker_name[96];

    return GetEnvironmentVariableW(L"ProgramData", program_data, MAX_PATH) &&
           join_path(marker_dir, MAX_PATH, program_data, L"QemuVgpu") &&
           _snwprintf(marker_name, 96, L"prepared-%ls.txt", uuid) > 0 &&
           join_path(marker_path, MAX_PATH, marker_dir, marker_name);
}

static BOOL clear_prepared_marker(const wchar_t *uuid)
{
    wchar_t marker_dir[MAX_PATH];
    wchar_t marker_path[MAX_PATH];
    DWORD error;

    if (!get_prepared_marker_path(uuid, marker_dir, marker_path)) {
        return FALSE;
    }
    if (DeleteFileW(marker_path)) {
        return TRUE;
    }
    error = GetLastError();
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

static BOOL write_prepared_marker(const wchar_t *uuid,
                                  const char *gpu_name,
                                  const char *published_inf)
{
    wchar_t marker_dir[MAX_PATH];
    wchar_t marker_path[MAX_PATH];
    wchar_t temporary_name[96];
    wchar_t temporary[MAX_PATH];
    char payload[512];
    char uuid_ascii[37];
    int payload_size;
    size_t index;
    HANDLE file = INVALID_HANDLE_VALUE;
    BOOL ok = FALSE;

    for (index = 0; index < 36; ++index) {
        if (!((uuid[index] >= L'0' && uuid[index] <= L'9') ||
              (uuid[index] >= L'a' && uuid[index] <= L'f') ||
              uuid[index] == L'-')) {
            return FALSE;
        }
        uuid_ascii[index] = (char)uuid[index];
    }
    if (uuid[36] != L'\0') {
        return FALSE;
    }
    uuid_ascii[36] = '\0';

    if (!get_prepared_marker_path(uuid, marker_dir, marker_path) ||
        !create_directory_if_needed(marker_dir) ||
        _snwprintf(temporary_name, 96, L".prepared-%ls.qemu.tmp", uuid) <= 0 ||
        !join_path(temporary, MAX_PATH, marker_dir, temporary_name)) {
        return FALSE;
    }

    if (published_inf && published_inf[0]) {
        if (!is_safe_oem_inf(published_inf)) {
            return FALSE;
        }
        payload_size = snprintf(payload, sizeof(payload),
            "QEMU_VGPU_PREPARED_V3\r\n"
            "VM_UUID=%s\r\n"
            "GPU_NAME=%s\r\n"
            "TOKEN_SHA256=%s\r\n"
            "DRIVER_PROFILE=" GTX1050_PROFILE "\r\n"
            "DRIVER_VERSION=" GTX1050_DRIVER_VERSION "\r\n"
            "DRIVER_INF=%s\r\n"
            "PATCHED_INF_SHA256=" GTX1050_PATCHED_INF_SHA256 "\r\n",
            uuid_ascii, gpu_name, VGPU_TOKEN_SHA256, published_inf);
    } else {
        payload_size = snprintf(payload, sizeof(payload),
            "QEMU_VGPU_PREPARED_V2\r\n"
            "VM_UUID=%s\r\n"
            "GPU_NAME=%s\r\n"
            "TOKEN_SHA256=%s\r\n",
            uuid_ascii, gpu_name, VGPU_TOKEN_SHA256);
    }
    if (payload_size <= 0 || (size_t)payload_size >= sizeof(payload)) {
        return FALSE;
    }

    DeleteFileW(temporary);
    file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                       FILE_ATTRIBUTE_HIDDEN | FILE_FLAG_WRITE_THROUGH, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return FALSE;
    }
    if (write_all(file, (const BYTE *)payload, (DWORD)payload_size) &&
        FlushFileBuffers(file)) {
        CloseHandle(file);
        file = INVALID_HANDLE_VALUE;
        ok = MoveFileExW(temporary, marker_path,
                         MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    }
    if (file != INVALID_HANDLE_VALUE) {
        CloseHandle(file);
    }
    if (!ok) {
        DeleteFileW(temporary);
    }
    return ok;
}

static BOOL install_token(const BYTE *token, DWORD token_size,
                          wchar_t *destination, size_t destination_count)
{
    wchar_t program_files[MAX_PATH];
    wchar_t nvidia_dir[MAX_PATH];
    wchar_t licensing_dir[MAX_PATH];
    wchar_t token_dir[MAX_PATH];
    wchar_t temporary[MAX_PATH];
    wchar_t backup[MAX_PATH];
    HANDLE file = INVALID_HANDLE_VALUE;
    BOOL destination_exists;
    BOOL ok = FALSE;

    if (!GetEnvironmentVariableW(L"ProgramFiles", program_files, MAX_PATH) ||
        !join_path(nvidia_dir, MAX_PATH, program_files, L"NVIDIA Corporation") ||
        !join_path(licensing_dir, MAX_PATH, nvidia_dir, L"vGPU Licensing") ||
        !join_path(token_dir, MAX_PATH, licensing_dir, L"ClientConfigToken") ||
        !join_path(destination, destination_count, token_dir,
                   L"client_configuration_token.tok") ||
        !join_path(temporary, MAX_PATH, token_dir,
                   L".client_configuration_token.qemu.tmp") ||
        !join_path(backup, MAX_PATH, token_dir,
                   L"client_configuration_token.previous")) {
        return FALSE;
    }
    if (!create_directory_if_needed(nvidia_dir) ||
        !create_directory_if_needed(licensing_dir) ||
        !create_directory_if_needed(token_dir)) {
        return FALSE;
    }

    DeleteFileW(temporary);
    file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                       FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return FALSE;
    }
    if (!write_all(file, token, token_size) || !FlushFileBuffers(file)) {
        goto done;
    }
    CloseHandle(file);
    file = INVALID_HANDLE_VALUE;

    destination_exists = GetFileAttributesW(destination) != INVALID_FILE_ATTRIBUTES;
    if (destination_exists) {
        DeleteFileW(backup);
        ok = ReplaceFileW(destination, temporary, backup,
                          REPLACEFILE_WRITE_THROUGH, NULL, NULL);
    } else {
        ok = MoveFileExW(temporary, destination,
                         MOVEFILE_WRITE_THROUGH | MOVEFILE_REPLACE_EXISTING);
    }

done:
    if (file != INVALID_HANDLE_VALUE) {
        CloseHandle(file);
    }
    if (!ok) {
        DeleteFileW(temporary);
    }
    return ok;
}

int wmain(void)
{
    HRSRC resource;
    HGLOBAL loaded;
    const BYTE *token;
    DWORD token_size;
    BYTE digest[32];
    DWORD command_exit = 1;
    DWORD driver_stage_exit = 1;
    wchar_t token_path[MAX_PATH];
    wchar_t message[1024];
    wchar_t actual_uuid[37];
    wchar_t target_gpu_name[32];
    char target_gpu_name_ascii[32];
    char published_inf[32] = "";
    wchar_t gpu_instance_id[MAX_DEVICE_ID_LEN];
    BOOL adapter_string_read = FALSE;
    BOOL adapter_string_matches = FALSE;
    DWORD adapter_string_error = ERROR_SUCCESS;
    DWORD gpu_name_error = ERROR_SUCCESS;
    TargetHintResult target_hint_result;
    GpuNameResult gpu_name_result;
    BOOL target_is_gtx1050;

    SetConsoleOutputCP(CP_UTF8);
    wprintf(L"Universal vGPU guest preparation\n\n");

    if (!is_administrator()) {
        show_error(L"Administrator privileges are required. Relaunch the EXE and accept the UAC prompt.");
        return 1;
    }
    if (!read_system_uuid(actual_uuid)) {
        show_error(L"Could not read the SMBIOS system UUID. Nothing was changed.");
        return 2;
    }
    wprintf(L"Guest SMBIOS UUID: %ls\n", actual_uuid);

    target_hint_result = read_target_gpu_hint(target_gpu_name,
                                               target_gpu_name_ascii);
    if (target_hint_result != TARGET_HINT_OK) {
        _snwprintf(message, 1024,
            L"The temporary host vGPU target hint is missing, ambiguous, "
            L"or unsafe (result=%u).\n\nStart this VM with the host finish "
            L"script and run this EXE during its rescue boot. No completion "
            L"marker was written and no shutdown was requested.",
            (unsigned)target_hint_result);
        show_error(message);
        return 2;
    }
    wprintf(L"Host vGPU target: %ls\n\n", target_gpu_name);
    target_is_gtx1050 = strcmp(target_gpu_name_ascii, GTX1050_NAME) == 0;

    resource = FindResourceW(NULL, MAKEINTRESOURCEW(TOKEN_RESOURCE_ID), RT_RCDATA);
    if (!resource || !(loaded = LoadResource(NULL, resource)) ||
        !(token = (const BYTE *)LockResource(loaded))) {
        show_error(L"The embedded license token is missing.");
        return 3;
    }
    token_size = SizeofResource(NULL, resource);
    if (token_size < TOKEN_MIN_BYTES || token_size > TOKEN_MAX_BYTES ||
        token_size != VGPU_TOKEN_BYTES || looks_like_html(token, token_size) ||
        !sha256(token, token_size, digest) || !digest_matches(digest)) {
        show_error(L"The embedded license token failed its size, content, or SHA-256 check.");
        return 4;
    }

    /* All immutable inputs are valid.  Remove only this UUID's old hand-off
     * now, immediately before the first Windows configuration change. */
    if (!clear_prepared_marker(actual_uuid)) {
        _snwprintf(message, 1024,
            L"Could not clear the previous completion marker for UUID %ls. "
            L"Nothing was changed and no shutdown was requested.", actual_uuid);
        show_error(message);
        return 4;
    }

    if (target_is_gtx1050) {
        wprintf(L"[1/5] Verifying and pre-staging the audited GTX 1050 "
                L"538.33 driver...\n");
        if (!ensure_gtx1050_driver_staged(published_inf,
                                          &driver_stage_exit)) {
            _snwprintf(message, 1024,
                L"The audited GTX 1050 driver could not be staged "
                L"(PowerShell exit=%lu).\n\nExtract the complete host-generated "
                L"VgpuGuestFinish-GTX1050.zip, then run the EXE from that "
                L"extracted directory. No completion marker was written and "
                L"no shutdown was requested.",
                (unsigned long)driver_stage_exit);
            show_error(message);
            return 5;
        }
        wprintf(L"      Published driver: %hs (%hs)\n", published_inf,
                GTX1050_DRIVER_VERSION);
    } else {
        wprintf(L"[1/5] Audited consumer-ID driver staging is not required "
                L"for this name-only target.\n");
    }

    wprintf(L"[2/5] Setting Device Manager GPU name to %ls...\n",
            target_gpu_name);
    gpu_name_result = set_gpu_friendly_name(target_gpu_name,
                                             target_is_gtx1050,
                                             gpu_instance_id,
                                             MAX_DEVICE_ID_LEN,
                                             &adapter_string_read,
                                             &adapter_string_matches,
                                             &adapter_string_error,
                                             &gpu_name_error);
    if (gpu_name_result != GPU_NAME_OK) {
        _snwprintf(message, 1024,
            L"Could not set the Device Manager GPU name to '%ls' "
            L"(result=%u, Win32=%lu).\n\n"
            L"Expected exactly one saved display device with NVIDIA PCI "
            L"hardware ID, PCI enumerator, and nvlddmkm service. "
            L"No completion marker was written and no shutdown was requested.",
            target_gpu_name, (unsigned)gpu_name_result,
            (unsigned long)gpu_name_error);
        show_error(message);
        return 6;
    }
    wprintf(L"      Updated: %ls\n", gpu_instance_id);
    if (!adapter_string_read) {
        wprintf(L"      Saved driver AdapterString was unavailable (Win32=%lu); "
                L"the transient host target was used.\n",
                (unsigned long)adapter_string_error);
    } else if (!adapter_string_matches) {
        wprintf(L"      Saved driver AdapterString was stale/different and was "
                L"ignored.\n");
    } else {
        wprintf(L"      Saved driver AdapterString also matched the host target.\n");
    }

    wprintf(L"[3/5] Disabling hibernation and Fast Startup...\n");
    if (!run_system_command(L"powercfg.exe", L"/hibernate off", &command_exit) ||
        command_exit != 0 || !set_fast_startup_disabled()) {
        show_error(L"Could not disable hibernation/Fast Startup. No shutdown was requested.");
        return 7;
    }

    wprintf(L"[4/5] Installing the embedded vGPU license token...\n");
    if (!install_token(token, token_size, token_path, MAX_PATH)) {
        show_error(L"Could not install the vGPU license token. No shutdown was requested.");
        return 8;
    }

    if (!write_prepared_marker(actual_uuid, target_gpu_name_ascii,
                               published_inf)) {
        show_error(L"The token was installed, but the host hand-off marker could not be written. No shutdown was requested.");
        return 9;
    }

    wprintf(L"[5/5] Preparation complete.\n");
    if (published_inf[0]) {
        _snwprintf(message, 1024,
            L"Guest %ls is prepared.\n\n"
            L"- Device Manager GPU name is %ls.\n"
            L"- Audited GTX 1050 538.33 driver package %hs is staged.\n"
            L"- Hibernation and Fast Startup are disabled.\n"
            L"- The local vGPU license token is installed.\n"
            L"- RTC was not changed inside Windows; the host launcher owns RTC.\n\n"
            L"Click OK to fully shut down Windows. Keep the host one-click script running.",
            actual_uuid, target_gpu_name, published_inf);
    } else {
        _snwprintf(message, 1024,
            L"Guest %ls is prepared.\n\n"
            L"- Device Manager GPU name is %ls.\n"
            L"- Consumer-ID driver staging was not required for this name-only target.\n"
            L"- Hibernation and Fast Startup are disabled.\n"
            L"- The local vGPU license token is installed.\n"
            L"- RTC was not changed inside Windows; the host launcher owns RTC.\n\n"
            L"Click OK to fully shut down Windows. Keep the host one-click script running.",
            actual_uuid, target_gpu_name);
    }
    MessageBoxW(NULL, message, L"vGPU preparation complete",
                MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND);

    if (!run_system_command(L"shutdown.exe", L"/s /t 0", &command_exit) ||
        command_exit != 0) {
        clear_prepared_marker(actual_uuid);
        show_error(L"Preparation succeeded, but automatic shutdown failed. The completion marker was removed; rerun this EXE from a host-script rescue boot.");
        return 10;
    }
    return 0;
}
