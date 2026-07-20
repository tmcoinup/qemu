#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shlobj.h>
#include <stdio.h>
#include <wchar.h>

#define PAYLOAD_COUNT 4u
#define SHA256_BYTES 32u
#define COPY_BUFFER_BYTES (4u * 1024u * 1024u)
#define CHILD_ENVIRONMENT_CHARS 16384u
#define MINIMUM_FREE_BYTES (4ull * 1024ull * 1024ull * 1024ull)

static const wchar_t *payload_names[PAYLOAD_COUNT] = {
    L"migration-contract.json",
    L"migrate-vgpu-production-driver.ps1",
    L"538.33-display-driver.zip",
    L"GpuZProfile.exe"
};

#pragma pack(push, 1)
typedef struct PayloadFooterEntry {
    ULONGLONG bytes;
    BYTE sha256[SHA256_BYTES];
} PayloadFooterEntry;

typedef struct PayloadFooter {
    BYTE magic[40];
    DWORD version;
    DWORD count;
    ULONGLONG base_bytes;
    PayloadFooterEntry entries[PAYLOAD_COUNT];
} PayloadFooter;
#pragma pack(pop)

static const BYTE footer_magic[40] =
    "QEMU_VGPU_PRODUCTION_MIGRATION_V1";

static void show_error(const wchar_t *message)
{
    fwprintf(stderr, L"%ls\n", message);
    MessageBoxW(NULL, message, L"vGPU production migration",
                MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST);
}

static void show_child_error(DWORD exit_code)
{
    wchar_t message[640];
    int result;

    result = _snwprintf(
        message, sizeof(message) / sizeof(message[0]),
        L"Migration failed closed (child exit code %lu).\n"
        L"The host configuration was not changed.\n\n"
        L"Details: %%ProgramData%%\\QemuVgpuProductionMigration\\last-error.txt",
        exit_code);
    if (result < 0 ||
        (size_t)result >= sizeof(message) / sizeof(message[0])) {
        show_error(
            L"Migration failed closed. The host configuration was not changed.");
        return;
    }
    show_error(message);
}

static BOOL is_administrator(void)
{
    SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
    PSID administrators = NULL;
    BOOL member = FALSE;

    if (!AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                  DOMAIN_ALIAS_RID_ADMINS,
                                  0, 0, 0, 0, 0, 0, &administrators)) {
        return FALSE;
    }
    if (!CheckTokenMembership(NULL, administrators, &member)) {
        member = FALSE;
    }
    FreeSid(administrators);
    return member;
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

static BOOL fixed_local_non_reparse(const wchar_t *path, BOOL directory)
{
    wchar_t volume[MAX_PATH];
    HANDLE handle;
    FILE_ATTRIBUTE_TAG_INFO tag;
    DWORD flags = FILE_FLAG_OPEN_REPARSE_POINT;
    BOOL ok = FALSE;

    if (directory) {
        flags |= FILE_FLAG_BACKUP_SEMANTICS;
    }
    if (!GetVolumePathNameW(path, volume, MAX_PATH) ||
        GetDriveTypeW(volume) != DRIVE_FIXED) {
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

static BOOL create_run_directory(wchar_t output[MAX_PATH])
{
    wchar_t program_data[MAX_PATH];
    wchar_t leaf[96];
    SECURITY_ATTRIBUTES attributes;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    DWORD attempt;
    BOOL result = FALSE;

    if (SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL,
                         SHGFP_TYPE_CURRENT, program_data) != S_OK ||
        !fixed_local_non_reparse(program_data, TRUE) ||
        !make_security_attributes(&attributes, &descriptor)) {
        return FALSE;
    }
    for (attempt = 0; attempt < 64; ++attempt) {
        if (_snwprintf(leaf, sizeof(leaf) / sizeof(leaf[0]),
                       L"QemuVgpuMigration-Run-%08lX-%08lX-%02lX",
                       GetCurrentProcessId(), GetTickCount(), attempt) < 0 ||
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

static BOOL read_exact_at(HANDLE file, ULONGLONG offset,
                          BYTE *buffer, DWORD bytes)
{
    LARGE_INTEGER position;
    DWORD total = 0;

    position.QuadPart = (LONGLONG)offset;
    if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN)) {
        return FALSE;
    }
    while (total < bytes) {
        DWORD received = 0;
        if (!ReadFile(file, buffer + total, bytes - total,
                      &received, NULL) || received == 0) {
            return FALSE;
        }
        total += received;
    }
    return TRUE;
}

static BOOL digest_equal(const BYTE left[SHA256_BYTES],
                         const BYTE right[SHA256_BYTES])
{
    BYTE difference = 0;
    size_t index;

    for (index = 0; index < SHA256_BYTES; ++index) {
        difference |= (BYTE)(left[index] ^ right[index]);
    }
    return difference == 0;
}

static BOOL copy_and_hash_payload(HANDLE source, ULONGLONG offset,
                                  ULONGLONG bytes,
                                  const BYTE expected[SHA256_BYTES],
                                  const wchar_t *destination,
                                  SECURITY_ATTRIBUTES *attributes)
{
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    PUCHAR hash_object = NULL;
    BYTE *buffer = NULL;
    BYTE digest[SHA256_BYTES];
    DWORD object_bytes = 0;
    DWORD result_bytes = 0;
    ULONGLONG remaining = bytes;
    LARGE_INTEGER position;
    HANDLE output = INVALID_HANDLE_VALUE;
    BOOL ok = FALSE;

    position.QuadPart = (LONGLONG)offset;
    if (!SetFilePointerEx(source, position, NULL, FILE_BEGIN) ||
        BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                    NULL, 0) < 0 ||
        BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                          (PUCHAR)&object_bytes, sizeof(object_bytes),
                          &result_bytes, 0) < 0 ||
        object_bytes == 0) {
        goto done;
    }
    hash_object = (PUCHAR)HeapAlloc(GetProcessHeap(), 0, object_bytes);
    buffer = (BYTE *)HeapAlloc(GetProcessHeap(), 0, COPY_BUFFER_BYTES);
    if (!hash_object || !buffer ||
        BCryptCreateHash(algorithm, &hash, hash_object, object_bytes,
                         NULL, 0, 0) < 0) {
        goto done;
    }
    output = CreateFileW(destination, GENERIC_WRITE, 0, attributes,
                         CREATE_NEW, FILE_ATTRIBUTE_READONLY |
                         FILE_FLAG_WRITE_THROUGH, NULL);
    if (output == INVALID_HANDLE_VALUE) {
        goto done;
    }
    while (remaining != 0) {
        DWORD wanted = remaining > COPY_BUFFER_BYTES
            ? COPY_BUFFER_BYTES : (DWORD)remaining;
        DWORD received = 0;
        DWORD written_total = 0;
        if (!ReadFile(source, buffer, wanted, &received, NULL) ||
            received != wanted ||
            BCryptHashData(hash, buffer, received, 0) < 0) {
            goto done;
        }
        while (written_total < received) {
            DWORD written = 0;
            if (!WriteFile(output, buffer + written_total,
                           received - written_total, &written, NULL) ||
                written == 0) {
                goto done;
            }
            written_total += written;
        }
        remaining -= received;
    }
    if (!FlushFileBuffers(output) ||
        BCryptFinishHash(hash, digest, sizeof(digest), 0) < 0 ||
        !digest_equal(digest, expected)) {
        goto done;
    }
    ok = TRUE;

done:
    SecureZeroMemory(digest, sizeof(digest));
    if (output != INVALID_HANDLE_VALUE) {
        CloseHandle(output);
        if (!ok) {
            SetFileAttributesW(destination, FILE_ATTRIBUTE_NORMAL);
            DeleteFileW(destination);
        }
    }
    if (hash) {
        BCryptDestroyHash(hash);
    }
    if (hash_object) {
        SecureZeroMemory(hash_object, object_bytes);
        HeapFree(GetProcessHeap(), 0, hash_object);
    }
    if (buffer) {
        SecureZeroMemory(buffer, COPY_BUFFER_BYTES);
        HeapFree(GetProcessHeap(), 0, buffer);
    }
    if (algorithm) {
        BCryptCloseAlgorithmProvider(algorithm, 0);
    }
    return ok;
}

static BOOL extract_payloads(const wchar_t *run_directory)
{
    wchar_t module[MAX_PATH];
    wchar_t destination[MAX_PATH];
    HANDLE executable = INVALID_HANDLE_VALUE;
    LARGE_INTEGER file_size;
    PayloadFooter footer;
    SECURITY_ATTRIBUTES attributes;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    ULONGLONG expected_size;
    ULONGLONG offset;
    DWORD index;
    BOOL ok = FALSE;

    if (!GetModuleFileNameW(NULL, module, MAX_PATH) ||
        !fixed_local_non_reparse(module, FALSE)) {
        return FALSE;
    }
    executable = CreateFileW(module, GENERIC_READ, FILE_SHARE_READ,
                             NULL, OPEN_EXISTING,
                             FILE_FLAG_OPEN_REPARSE_POINT |
                             FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (executable == INVALID_HANDLE_VALUE ||
        !GetFileSizeEx(executable, &file_size) ||
        file_size.QuadPart <= (LONGLONG)sizeof(footer) ||
        !read_exact_at(executable,
                       (ULONGLONG)file_size.QuadPart - sizeof(footer),
                       (BYTE *)&footer, sizeof(footer)) ||
        memcmp(footer.magic, footer_magic, sizeof(footer_magic)) != 0 ||
        footer.version != 1 || footer.count != PAYLOAD_COUNT ||
        footer.base_bytes < 4096) {
        goto done;
    }
    expected_size = footer.base_bytes + sizeof(footer);
    for (index = 0; index < PAYLOAD_COUNT; ++index) {
        ULONGLONG bytes = footer.entries[index].bytes;
        if (bytes == 0 ||
            (index == 0 && bytes > 1024u * 1024u) ||
            (index == 1 && bytes > 8u * 1024u * 1024u) ||
            (index == 2 &&
             (bytes < 256ull * 1024ull * 1024ull ||
              bytes > 1536ull * 1024ull * 1024ull)) ||
            (index == 3 && bytes > 256ull * 1024ull * 1024ull) ||
            expected_size > ~bytes) {
            goto done;
        }
        expected_size += bytes;
    }
    if (expected_size != (ULONGLONG)file_size.QuadPart ||
        !make_security_attributes(&attributes, &descriptor)) {
        goto done;
    }
    offset = footer.base_bytes;
    for (index = 0; index < PAYLOAD_COUNT; ++index) {
        if (!join_path(destination, MAX_PATH, run_directory,
                       payload_names[index]) ||
            !copy_and_hash_payload(
                executable, offset, footer.entries[index].bytes,
                footer.entries[index].sha256, destination, &attributes)) {
            goto done;
        }
        offset += footer.entries[index].bytes;
    }
    ok = TRUE;

done:
    if (descriptor) {
        LocalFree(descriptor);
    }
    if (executable != INVALID_HANDLE_VALUE) {
        CloseHandle(executable);
    }
    SecureZeroMemory(&footer, sizeof(footer));
    return ok;
}

static BOOL append_environment(wchar_t *environment, size_t capacity,
                               size_t *used, const wchar_t *name,
                               const wchar_t *value)
{
    size_t name_length = wcslen(name);
    size_t value_length = wcslen(value);

    if (*used + name_length + value_length + 3u >= capacity) {
        return FALSE;
    }
    memcpy(environment + *used, name, name_length * sizeof(wchar_t));
    *used += name_length;
    environment[(*used)++] = L'=';
    memcpy(environment + *used, value, value_length * sizeof(wchar_t));
    *used += value_length;
    environment[(*used)++] = L'\0';
    return TRUE;
}

static BOOL build_environment(const wchar_t *runtime,
                              const wchar_t *windows_root,
                              const wchar_t *system_root,
                              wchar_t environment[CHILD_ENVIRONMENT_CHARS])
{
    wchar_t powershell_modules[MAX_PATH * 2];
    wchar_t path[MAX_PATH * 2];
    wchar_t command_shell[MAX_PATH];
    wchar_t program_data[MAX_PATH];
    wchar_t volume_root[MAX_PATH];
    wchar_t system_drive[3];
    size_t used = 0;

    if (SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL,
                         SHGFP_TYPE_CURRENT, program_data) != S_OK ||
        !GetVolumePathNameW(windows_root, volume_root, MAX_PATH) ||
        wcslen(volume_root) < 3 || volume_root[1] != L':' ||
        volume_root[2] != L'\\' ||
        !((volume_root[0] >= L'A' && volume_root[0] <= L'Z') ||
          (volume_root[0] >= L'a' && volume_root[0] <= L'z'))) {
        return FALSE;
    }
    system_drive[0] = volume_root[0];
    system_drive[1] = L':';
    system_drive[2] = L'\0';
    if (_snwprintf(powershell_modules,
                   sizeof(powershell_modules) /
                       sizeof(powershell_modules[0]),
                   L"%ls\\System32\\WindowsPowerShell\\v1.0\\Modules",
                   windows_root) < 0 ||
        _snwprintf(path, sizeof(path) / sizeof(path[0]),
                   L"%ls;%ls\\WindowsPowerShell\\v1.0",
                   system_root, system_root) < 0 ||
        !join_path(command_shell, MAX_PATH, system_root, L"cmd.exe") ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"ALLUSERSPROFILE", program_data) ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"ComSpec", command_shell) ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"OS", L"Windows_NT") ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"Path", path) ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"PATHEXT", L".COM;.EXE;.BAT;.CMD") ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"PROCESSOR_ARCHITECTURE", L"AMD64") ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"ProgramData", program_data) ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"PSModulePath", powershell_modules) ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"SystemDrive", system_drive) ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"SystemRoot", windows_root) ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"TEMP", runtime) ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"TMP", runtime) ||
        !append_environment(environment, CHILD_ENVIRONMENT_CHARS, &used,
                            L"windir", windows_root) ||
        used >= CHILD_ENVIRONMENT_CHARS) {
        return FALSE;
    }
    environment[used] = L'\0';
    return TRUE;
}

static BOOL run_migration(const wchar_t *run_directory, DWORD *exit_code)
{
    wchar_t windows_root[MAX_PATH];
    wchar_t system_root[MAX_PATH];
    wchar_t powershell[MAX_PATH];
    wchar_t script[MAX_PATH];
    wchar_t contract[MAX_PATH];
    wchar_t driver_zip[MAX_PATH];
    wchar_t gpuz[MAX_PATH];
    wchar_t command_line[4096];
    wchar_t environment[CHILD_ENVIRONMENT_CHARS];
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD wait_result;
    int result;

    *exit_code = ERROR_GEN_FAILURE;
    if (!GetWindowsDirectoryW(windows_root, MAX_PATH) ||
        !GetSystemDirectoryW(system_root, MAX_PATH) ||
        !fixed_local_non_reparse(windows_root, TRUE) ||
        !fixed_local_non_reparse(system_root, TRUE) ||
        !join_path(powershell, MAX_PATH, system_root,
                   L"WindowsPowerShell\\v1.0\\powershell.exe") ||
        !join_path(script, MAX_PATH, run_directory, payload_names[1]) ||
        !join_path(contract, MAX_PATH, run_directory, payload_names[0]) ||
        !join_path(driver_zip, MAX_PATH, run_directory, payload_names[2]) ||
        !join_path(gpuz, MAX_PATH, run_directory, payload_names[3]) ||
        !build_environment(run_directory, windows_root, system_root,
                           environment)) {
        return FALSE;
    }
    result = _snwprintf(
        command_line, sizeof(command_line) / sizeof(command_line[0]),
        L"\"%ls\" -NoLogo -NoProfile -NonInteractive "
        L"-ExecutionPolicy Bypass -File \"%ls\" "
        L"-ContractPath \"%ls\" -DriverZip \"%ls\" "
        L"-GpuZProfileExe \"%ls\" -ShutdownWhenStaged",
        powershell, script, contract, driver_zip, gpuz);
    if (result < 0 ||
        (size_t)result >= sizeof(command_line) / sizeof(command_line[0])) {
        SecureZeroMemory(environment, sizeof(environment));
        return FALSE;
    }
    ZeroMemory(&startup, sizeof(startup));
    startup.cb = sizeof(startup);
    ZeroMemory(&process, sizeof(process));
    if (!CreateProcessW(powershell, command_line, NULL, NULL, FALSE,
                        CREATE_UNICODE_ENVIRONMENT, environment,
                        run_directory, &startup, &process)) {
        SecureZeroMemory(command_line, sizeof(command_line));
        SecureZeroMemory(environment, sizeof(environment));
        return FALSE;
    }
    SecureZeroMemory(command_line, sizeof(command_line));
    SecureZeroMemory(environment, sizeof(environment));
    CloseHandle(process.hThread);
    wait_result = WaitForSingleObject(process.hProcess, INFINITE);
    if (wait_result != WAIT_OBJECT_0 ||
        !GetExitCodeProcess(process.hProcess, exit_code)) {
        CloseHandle(process.hProcess);
        return FALSE;
    }
    CloseHandle(process.hProcess);
    return TRUE;
}

static BOOL delete_tree(const wchar_t *root)
{
    wchar_t pattern[MAX_PATH];
    wchar_t child[MAX_PATH];
    WIN32_FIND_DATAW data;
    HANDLE search;
    BOOL ok = TRUE;

    if (!join_path(pattern, MAX_PATH, root, L"*")) {
        return FALSE;
    }
    search = FindFirstFileW(pattern, &data);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(data.cFileName, L".") == 0 ||
                wcscmp(data.cFileName, L"..") == 0) {
                continue;
            }
            if (!join_path(child, MAX_PATH, root, data.cFileName)) {
                ok = FALSE;
                continue;
            }
            if ((data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                ok = FALSE;
                continue;
            }
            SetFileAttributesW(child, FILE_ATTRIBUTE_NORMAL);
            if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                if (!delete_tree(child)) {
                    ok = FALSE;
                }
            } else if (!DeleteFileW(child)) {
                ok = FALSE;
            }
        } while (FindNextFileW(search, &data));
        if (GetLastError() != ERROR_NO_MORE_FILES) {
            ok = FALSE;
        }
        FindClose(search);
    }
    SetFileAttributesW(root, FILE_ATTRIBUTE_NORMAL);
    if (!RemoveDirectoryW(root)) {
        ok = FALSE;
    }
    return ok;
}

int wmain(int argc, wchar_t **argv)
{
    wchar_t run_directory[MAX_PATH] = L"";
    ULARGE_INTEGER free_bytes;
    DWORD child_exit = ERROR_GEN_FAILURE;
    BOOL ran = FALSE;
    BOOL cleaned;

    if (argc != 1) {
        show_error(L"This migration EXE accepts no command-line arguments.");
        return 2;
    }
    (void)argv;
    SetConsoleTitleW(L"vGPU production-driver migration");
    if (!is_administrator()) {
        show_error(L"Administrator elevation is required.");
        return 1;
    }
    if (!create_run_directory(run_directory)) {
        show_error(L"Could not create a protected local extraction directory.");
        return 1;
    }
    if (!GetDiskFreeSpaceExW(run_directory, &free_bytes, NULL, NULL) ||
        free_bytes.QuadPart < MINIMUM_FREE_BYTES) {
        show_error(L"At least 4 GiB of free local disk space is required.");
        delete_tree(run_directory);
        return 1;
    }
    fwprintf(stdout,
             L"[vGPU migration] Verifying and extracting the embedded "
             L"payloads; this can take several minutes.\n");
    fflush(stdout);
    if (!extract_payloads(run_directory)) {
        show_error(L"The embedded migration payload failed size/SHA-256 validation.");
        delete_tree(run_directory);
        return 1;
    }
    fwprintf(stdout,
             L"[vGPU migration] Payload verification passed; starting the "
             L"protected migration checks.\n");
    fflush(stdout);
    ran = run_migration(run_directory, &child_exit);
    cleaned = delete_tree(run_directory);
    if (!ran) {
        show_error(
            L"Could not start the protected migration process. "
            L"The host configuration was not changed.");
        return 1;
    }
    if (child_exit != 0) {
        show_child_error(child_exit);
        return (int)child_exit;
    }
    if (!cleaned) {
        show_error(L"Migration succeeded, but temporary payload cleanup was incomplete.");
        return 1;
    }
    return 0;
}
