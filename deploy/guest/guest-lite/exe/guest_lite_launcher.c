#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shlobj.h>
#include <stdio.h>
#include <wchar.h>

#define PAYLOAD_COUNT 5u
#define MAX_SCRIPT_BYTES (2u * 1024u * 1024u)
#define MAX_TEXT_BYTES (512u * 1024u)

typedef struct Payload {
    WORD resource_id;
    const wchar_t *name;
    DWORD maximum_bytes;
} Payload;

static const Payload payloads[PAYLOAD_COUNT] = {
    {101, L"G11-Guest-Lite.ps1", MAX_SCRIPT_BYTES},
    {102, L"01-OneClick-Apply.cmd", MAX_TEXT_BYTES},
    {103, L"02-Audit.cmd", MAX_TEXT_BYTES},
    {104, L"03-Rollback.cmd", MAX_TEXT_BYTES},
    {105, L"README.txt", MAX_TEXT_BYTES},
};

static void show_error(const wchar_t *message)
{
    fwprintf(stderr, L"%ls\n", message);
    MessageBoxW(NULL, message, L"G-11 Guest Lite",
                MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST);
}

static void show_result(const wchar_t *mode, DWORD exit_code)
{
    wchar_t message[768];
    UINT icon = MB_ICONINFORMATION;

    if (exit_code == 0) {
        if (_wcsicmp(mode, L"Apply") == 0) {
            _snwprintf(
                message, sizeof(message) / sizeof(message[0]),
                L"Apply completed.\n\nRestart Windows, then run "
                L"C:\\ProgramData\\G11GuestLite\\tools\\02-Audit.cmd.");
        } else if (_wcsicmp(mode, L"Rollback") == 0) {
            _snwprintf(message, sizeof(message) / sizeof(message[0]),
                       L"Rollback completed.\n\nRestart Windows now.");
        } else {
            _snwprintf(
                message, sizeof(message) / sizeof(message[0]),
                L"Audit/Verify completed successfully.\n\nReports: "
                L"C:\\ProgramData\\G11GuestLite\\reports");
        }
    } else if (exit_code == 3) {
        icon = MB_ICONWARNING;
        _snwprintf(
            message, sizeof(message) / sizeof(message[0]),
            L"%ls completed partially.\n\nReview the console output and reports. "
            L"The rollback baseline was retained.", mode);
    } else {
        icon = MB_ICONERROR;
        _snwprintf(
            message, sizeof(message) / sizeof(message[0]),
            L"%ls failed or was cancelled (exit code %lu).\n\nNo BCD, "
            L"driver-signing, or kernel-driver change was attempted.",
            mode, exit_code);
    }
    message[(sizeof(message) / sizeof(message[0])) - 1u] = L'\0';
    MessageBoxW(NULL, message, L"G-11 Guest Lite",
                MB_OK | icon | MB_SETFOREGROUND | MB_TOPMOST);
}

static BOOL join_path(wchar_t *output, size_t output_count,
                      const wchar_t *left, const wchar_t *right)
{
    size_t left_length = wcslen(left);
    size_t right_length = wcslen(right);
    BOOL separator = left_length != 0 && left[left_length - 1] != L'\\';

    if (left_length + (separator ? 1u : 0u) + right_length + 1u >
        output_count) {
        return FALSE;
    }
    memcpy(output, left, left_length * sizeof(wchar_t));
    if (separator) {
        output[left_length++] = L'\\';
    }
    memcpy(output + left_length, right,
           (right_length + 1u) * sizeof(wchar_t));
    return TRUE;
}

static BOOL local_non_reparse(const wchar_t *path, BOOL directory,
                              BOOL allow_package_media)
{
    wchar_t volume[MAX_PATH];
    HANDLE handle;
    FILE_ATTRIBUTE_TAG_INFO tag;
    DWORD attributes;
    DWORD flags = FILE_FLAG_OPEN_REPARSE_POINT;
    UINT drive_type;
    BOOL ok = FALSE;

    if (directory) {
        flags |= FILE_FLAG_BACKUP_SEMANTICS;
    }
    if (!GetVolumePathNameW(path, volume, MAX_PATH)) {
        return FALSE;
    }
    drive_type = GetDriveTypeW(volume);
    if (allow_package_media &&
        (drive_type == DRIVE_CDROM || drive_type == DRIVE_REMOVABLE)) {
        /* The managed package is a read-only FAT/ISO volume.  Some Windows
         * FAT stacks do not return FileAttributeTagInfo even though ordinary
         * reads and CopyFileW work.  FAT package media cannot contain NTFS
         * reparse points, but still reject any provider that advertises one. */
        attributes = GetFileAttributesW(path);
        return attributes != INVALID_FILE_ATTRIBUTES &&
               (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0 &&
               (!!(attributes & FILE_ATTRIBUTE_DIRECTORY) == !!directory);
    }
    if (drive_type != DRIVE_FIXED) {
        return FALSE;
    }
    handle = CreateFileW(path, FILE_READ_ATTRIBUTES,
                         FILE_SHARE_READ | FILE_SHARE_WRITE |
                             FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, flags, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        return FALSE;
    }
    if (GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag,
                                     sizeof(tag)) &&
        (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0 &&
        (!!(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == !!directory)) {
        ok = TRUE;
    }
    CloseHandle(handle);
    return ok;
}

static BOOL fixed_local_non_reparse(const wchar_t *path, BOOL directory)
{
    return local_non_reparse(path, directory, FALSE);
}

static BOOL make_security_attributes(SECURITY_ATTRIBUTES *attributes,
                                     PSECURITY_DESCRIPTOR *descriptor)
{
    static const wchar_t sddl[] =
        L"O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

    ZeroMemory(attributes, sizeof(*attributes));
    *descriptor = NULL;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl, SDDL_REVISION_1, descriptor, NULL)) {
        return FALSE;
    }
    attributes->nLength = sizeof(*attributes);
    attributes->lpSecurityDescriptor = *descriptor;
    attributes->bInheritHandle = FALSE;
    return TRUE;
}

static BOOL get_program_data(wchar_t output[MAX_PATH])
{
    return SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL,
                            SHGFP_TYPE_CURRENT, output) == S_OK &&
           fixed_local_non_reparse(output, TRUE);
}

static BOOL create_run_directory(const wchar_t *program_data,
                                 wchar_t output[MAX_PATH])
{
    wchar_t leaf[112];
    SECURITY_ATTRIBUTES attributes;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    DWORD attempt;
    BOOL result = FALSE;

    if (!make_security_attributes(&attributes, &descriptor)) {
        return FALSE;
    }
    for (attempt = 0; attempt < 64; ++attempt) {
        ULONG random_value = 0;
        if (BCryptGenRandom(NULL, (PUCHAR)&random_value,
                            sizeof(random_value),
                            BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
            break;
        }
        if (_snwprintf(leaf, sizeof(leaf) / sizeof(leaf[0]),
                       L"G11GuestLite-Run-%08lX-%08lX-%08lX",
                       GetCurrentProcessId(), GetTickCount(),
                       random_value) < 0 ||
            !join_path(output, MAX_PATH, program_data, leaf)) {
            break;
        }
        if (CreateDirectoryW(output, &attributes)) {
            result = fixed_local_non_reparse(output, TRUE);
            break;
        }
        if (GetLastError() != ERROR_ALREADY_EXISTS) {
            break;
        }
    }
    LocalFree(descriptor);
    return result;
}

static BOOL write_exact(HANDLE file, const BYTE *data, DWORD bytes)
{
    DWORD total = 0;

    while (total < bytes) {
        DWORD written = 0;
        if (!WriteFile(file, data + total, bytes - total,
                       &written, NULL) || written == 0) {
            return FALSE;
        }
        total += written;
    }
    return TRUE;
}

static BOOL extract_payload(const wchar_t *directory, const Payload *payload)
{
    wchar_t path[MAX_PATH];
    HRSRC resource;
    HGLOBAL loaded;
    const BYTE *data;
    DWORD bytes;
    HANDLE file;
    BOOL ok;

    resource = FindResourceW(NULL, MAKEINTRESOURCEW(payload->resource_id),
                             RT_RCDATA);
    if (resource == NULL) {
        return FALSE;
    }
    bytes = SizeofResource(NULL, resource);
    if (bytes == 0 || bytes > payload->maximum_bytes) {
        return FALSE;
    }
    loaded = LoadResource(NULL, resource);
    if (loaded == NULL) {
        return FALSE;
    }
    data = (const BYTE *)LockResource(loaded);
    if (data == NULL || !join_path(path, MAX_PATH, directory, payload->name)) {
        return FALSE;
    }
    file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                       FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_WRITE_THROUGH,
                       NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return FALSE;
    }
    ok = write_exact(file, data, bytes) && FlushFileBuffers(file);
    if (!CloseHandle(file)) {
        ok = FALSE;
    }
    if (!ok) {
        DeleteFileW(path);
    }
    return ok && fixed_local_non_reparse(path, FALSE);
}

static BOOL extract_all(const wchar_t *directory)
{
    size_t index;

    for (index = 0; index < PAYLOAD_COUNT; ++index) {
        if (!extract_payload(directory, &payloads[index])) {
            return FALSE;
        }
    }
    return TRUE;
}

static BOOL run_powershell(const wchar_t *directory, const wchar_t *mode,
                           DWORD *exit_code)
{
    wchar_t system_directory[MAX_PATH];
    wchar_t powershell[MAX_PATH];
    wchar_t script[MAX_PATH];
    wchar_t command[4 * MAX_PATH];
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD system_length;
    BOOL ok = FALSE;

    system_length = GetSystemDirectoryW(system_directory, MAX_PATH);
    if (system_length == 0 || system_length >= MAX_PATH ||
        !join_path(powershell, MAX_PATH, system_directory,
                   L"WindowsPowerShell\\v1.0\\powershell.exe") ||
        !fixed_local_non_reparse(powershell, FALSE) ||
        !join_path(script, MAX_PATH, directory, L"G11-Guest-Lite.ps1") ||
        !fixed_local_non_reparse(script, FALSE)) {
        return FALSE;
    }
    if (_snwprintf(
            command, sizeof(command) / sizeof(command[0]),
            L"\"%ls\" -NoLogo -NoProfile -ExecutionPolicy Bypass "
            L"-File \"%ls\" -Mode %ls",
            powershell, script, mode) < 0) {
        return FALSE;
    }
    command[(sizeof(command) / sizeof(command[0])) - 1u] = L'\0';
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    if (!CreateProcessW(powershell, command, NULL, NULL, FALSE,
                        CREATE_UNICODE_ENVIRONMENT, NULL, directory,
                        &startup, &process)) {
        return FALSE;
    }
    CloseHandle(process.hThread);
    if (WaitForSingleObject(process.hProcess, INFINITE) == WAIT_OBJECT_0 &&
        GetExitCodeProcess(process.hProcess, exit_code)) {
        ok = TRUE;
    }
    CloseHandle(process.hProcess);
    return ok;
}

static BOOL install_self(const wchar_t *program_data)
{
    wchar_t state_root[MAX_PATH];
    wchar_t tools[MAX_PATH];
    wchar_t destination[MAX_PATH];
    wchar_t source[MAX_PATH];
    DWORD source_length;
    DWORD attributes;

    if (!join_path(state_root, MAX_PATH, program_data, L"G11GuestLite") ||
        !join_path(tools, MAX_PATH, state_root, L"tools") ||
        !join_path(destination, MAX_PATH, tools, L"G11GuestLite.exe") ||
        !fixed_local_non_reparse(state_root, TRUE) ||
        !fixed_local_non_reparse(tools, TRUE)) {
        return FALSE;
    }
    source_length = GetModuleFileNameW(NULL, source, MAX_PATH);
    /* The reviewed package normally starts from a read-only ISO or the
     * managed read-only USB disk.  The user has already approved and launched
     * this exact image, so permit fixed, CD-ROM, and removable local media;
     * network and unknown sources remain rejected. */
    if (source_length == 0 || source_length >= MAX_PATH ||
        !local_non_reparse(source, FALSE, TRUE)) {
        return FALSE;
    }
    if (_wcsicmp(source, destination) == 0) {
        return TRUE;
    }
    attributes = GetFileAttributesW(destination);
    if (attributes != INVALID_FILE_ATTRIBUTES &&
        ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
         (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)) {
        return FALSE;
    }
    return CopyFileW(source, destination, FALSE) &&
           fixed_local_non_reparse(destination, FALSE);
}

static BOOL cleanup_run_directory(const wchar_t *directory)
{
    wchar_t path[MAX_PATH];
    size_t index;
    BOOL ok = TRUE;

    for (index = 0; index < PAYLOAD_COUNT; ++index) {
        if (!join_path(path, MAX_PATH, directory, payloads[index].name) ||
            !DeleteFileW(path)) {
            if (GetLastError() != ERROR_FILE_NOT_FOUND) {
                ok = FALSE;
            }
        }
    }
    if (!RemoveDirectoryW(directory)) {
        ok = FALSE;
    }
    return ok;
}

static void show_usage(void)
{
    MessageBoxW(
        NULL,
        L"G11GuestLite.exe             Apply full profile\n"
        L"G11GuestLite.exe /apply      Apply full profile\n"
        L"G11GuestLite.exe /audit      Audit or verify\n"
        L"G11GuestLite.exe /rollback   Restore saved baseline\n\n"
        L"The embedded PowerShell source is also included in the package for "
        L"review.",
        L"G-11 Guest Lite", MB_OK | MB_ICONINFORMATION | MB_TOPMOST);
}

int wmain(int argc, wchar_t **argv)
{
    const wchar_t *mode = L"Apply";
    wchar_t program_data[MAX_PATH];
    wchar_t run_directory[MAX_PATH];
    DWORD exit_code = 1;
    BOOL cleanup_ok;

    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    if (argc > 2) {
        show_usage();
        return 2;
    }
    if (argc == 2) {
        if (_wcsicmp(argv[1], L"/apply") == 0 ||
            _wcsicmp(argv[1], L"-apply") == 0) {
            mode = L"Apply";
        } else if (_wcsicmp(argv[1], L"/audit") == 0 ||
                   _wcsicmp(argv[1], L"-audit") == 0) {
            mode = L"Audit";
        } else if (_wcsicmp(argv[1], L"/rollback") == 0 ||
                   _wcsicmp(argv[1], L"-rollback") == 0) {
            mode = L"Rollback";
        } else if (_wcsicmp(argv[1], L"/?") == 0 ||
                   _wcsicmp(argv[1], L"/help") == 0 ||
                   _wcsicmp(argv[1], L"-help") == 0) {
            show_usage();
            return 0;
        } else {
            show_usage();
            return 2;
        }
    }

    wprintf(L"G-11 Windows 10 Guest Lite 2.5.2 - %ls\n\n", mode);
    if (!get_program_data(program_data) ||
        !create_run_directory(program_data, run_directory)) {
        show_error(L"Could not create a protected extraction directory.");
        return 1;
    }
    if (!extract_all(run_directory)) {
        cleanup_run_directory(run_directory);
        show_error(L"The embedded guest-lite payload could not be extracted.");
        return 1;
    }
    if (!run_powershell(run_directory, mode, &exit_code)) {
        cleanup_run_directory(run_directory);
        show_error(L"Windows PowerShell could not be started or monitored.");
        return 1;
    }
    if (_wcsicmp(mode, L"Apply") == 0 &&
        (exit_code == 0 || exit_code == 3) &&
        !install_self(program_data)) {
        fwprintf(stderr,
                 L"Warning: the EXE could not be copied to the maintenance "
                 L"tools directory. Script rollback remains available.\n");
    }
    cleanup_ok = cleanup_run_directory(run_directory);
    if (!cleanup_ok) {
        fwprintf(stderr,
                 L"Warning: the protected temporary extraction directory "
                 L"could not be removed completely: %ls\n",
                 run_directory);
    }
    show_result(mode, exit_code);
    return (int)exit_code;
}
