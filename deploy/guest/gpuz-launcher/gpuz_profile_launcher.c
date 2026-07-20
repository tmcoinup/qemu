#define _WIN32_WINNT 0x0601
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shlobj.h>
#include <stdio.h>
#include <wchar.h>

#define LAUNCHER_MARKER "QEMU_GPUZ_SINGLE_EXE_V1"
#define RUN_DIRECTORY_ATTEMPTS 32u
#define SHA256_BYTES 32u
#define CHILD_ENVIRONMENT_CHARS 16384u

typedef struct PayloadEntry {
    WORD resource_id;
    const wchar_t *name;
    DWORD bytes;
    BYTE sha256[SHA256_BYTES];
} PayloadEntry;

#include "payload_metadata.h"

static void show_message(BOOL no_launch, UINT flags, const wchar_t *title,
                         const wchar_t *message)
{
    FILE *stream = (flags & MB_ICONERROR) ? stderr : stdout;

    fwprintf(stream, L"%ls\n", message);
    fflush(stream);
    if (!no_launch) {
        MessageBoxW(NULL, message, title,
                    MB_OK | flags | MB_SETFOREGROUND | MB_TOPMOST);
    }
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

static BOOL get_fixed_local_path(const wchar_t *path)
{
    wchar_t volume[MAX_PATH];
    HANDLE handle;
    FILE_ATTRIBUTE_TAG_INFO tag;
    BOOL ok = FALSE;

    if (!GetVolumePathNameW(path, volume, MAX_PATH) ||
        GetDriveTypeW(volume) != DRIVE_FIXED) {
        return FALSE;
    }
    handle = CreateFileW(path, FILE_READ_ATTRIBUTES,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS |
                         FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        return FALSE;
    }
    if (GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag,
                                     sizeof(tag)) &&
        (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0) {
        ok = TRUE;
    }
    CloseHandle(handle);
    return ok;
}

static BOOL make_security_attributes(SECURITY_ATTRIBUTES *attributes,
                                     PSECURITY_DESCRIPTOR *descriptor)
{
    static const wchar_t directory_sddl[] =
        L"O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

    ZeroMemory(attributes, sizeof(*attributes));
    *descriptor = NULL;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            directory_sddl, SDDL_REVISION_1, descriptor, NULL)) {
        return FALSE;
    }
    attributes->nLength = sizeof(*attributes);
    attributes->lpSecurityDescriptor = *descriptor;
    attributes->bInheritHandle = FALSE;
    return TRUE;
}

static BOOL make_mutex_security_attributes(SECURITY_ATTRIBUTES *attributes,
                                           PSECURITY_DESCRIPTOR *descriptor)
{
    static const wchar_t mutex_sddl[] =
        L"O:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)";

    ZeroMemory(attributes, sizeof(*attributes));
    *descriptor = NULL;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            mutex_sddl, SDDL_REVISION_1, descriptor, NULL)) {
        return FALSE;
    }
    attributes->nLength = sizeof(*attributes);
    attributes->lpSecurityDescriptor = *descriptor;
    attributes->bInheritHandle = FALSE;
    return TRUE;
}

static BOOL verify_protected_handle(HANDLE handle)
{
    SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
    PSID administrators = NULL;
    PSID system = NULL;
    PSID owner = NULL;
    PACL dacl = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    ACL_SIZE_INFORMATION information;
    DWORD index;
    BOOL saw_administrators = FALSE;
    BOOL saw_system = FALSE;
    BOOL ok = FALSE;

    if (!AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                  DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                  &administrators) ||
        !AllocateAndInitializeSid(&nt, 1, SECURITY_LOCAL_SYSTEM_RID,
                                  0, 0, 0, 0, 0, 0, 0, &system) ||
        GetSecurityInfo(handle, SE_FILE_OBJECT,
                        OWNER_SECURITY_INFORMATION |
                        DACL_SECURITY_INFORMATION,
                        &owner, NULL, &dacl, NULL, &descriptor) !=
            ERROR_SUCCESS ||
        !owner || !EqualSid(owner, administrators) || !dacl ||
        !GetSecurityDescriptorControl(descriptor, &control, &revision) ||
        (control & SE_DACL_PROTECTED) == 0 ||
        !GetAclInformation(dacl, &information, sizeof(information),
                           AclSizeInformation) ||
        information.AceCount != 2) {
        goto done;
    }
    for (index = 0; index < information.AceCount; ++index) {
        ACCESS_ALLOWED_ACE *ace;
        PSID sid;

        if (!GetAce(dacl, index, (LPVOID *)&ace) ||
            ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE ||
            (ace->Mask & FILE_ALL_ACCESS) != FILE_ALL_ACCESS) {
            goto done;
        }
        sid = (PSID)&ace->SidStart;
        if (EqualSid(sid, administrators)) {
            if (saw_administrators) {
                goto done;
            }
            saw_administrators = TRUE;
        } else if (EqualSid(sid, system)) {
            if (saw_system) {
                goto done;
            }
            saw_system = TRUE;
        } else {
            goto done;
        }
    }
    ok = saw_administrators && saw_system;

done:
    if (descriptor) {
        LocalFree(descriptor);
    }
    if (administrators) {
        FreeSid(administrators);
    }
    if (system) {
        FreeSid(system);
    }
    return ok;
}

static BOOL open_protected_directory(const wchar_t *path, HANDLE *result)
{
    HANDLE handle;
    FILE_ATTRIBUTE_TAG_INFO tag;

    *result = INVALID_HANDLE_VALUE;
    handle = CreateFileW(path, FILE_READ_ATTRIBUTES | READ_CONTROL,
                         FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                         OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS |
                         FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (handle == INVALID_HANDLE_VALUE ||
        !GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag,
                                      sizeof(tag)) ||
        (tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
        (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
        !verify_protected_handle(handle)) {
        if (handle != INVALID_HANDLE_VALUE) {
            CloseHandle(handle);
        }
        return FALSE;
    }
    *result = handle;
    return TRUE;
}

static BOOL random_hex(wchar_t output[33])
{
    BYTE random[16];
    static const wchar_t hex[] = L"0123456789abcdef";
    size_t index;

    if (BCryptGenRandom(NULL, random, sizeof(random),
                        BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
        return FALSE;
    }
    for (index = 0; index < sizeof(random); ++index) {
        output[index * 2] = hex[random[index] >> 4];
        output[index * 2 + 1] = hex[random[index] & 0x0f];
    }
    output[32] = L'\0';
    SecureZeroMemory(random, sizeof(random));
    return TRUE;
}

static BOOL create_run_directories(const wchar_t *program_data,
                                   wchar_t run_root[MAX_PATH],
                                   wchar_t bundle_root[MAX_PATH],
                                   HANDLE *run_handle,
                                   HANDLE *bundle_handle)
{
    SECURITY_ATTRIBUTES attributes;
    PSECURITY_DESCRIPTOR descriptor;
    wchar_t random[33];
    wchar_t leaf[80];
    DWORD attempt;
    BOOL created = FALSE;

    if (!make_security_attributes(&attributes, &descriptor)) {
        return FALSE;
    }
    for (attempt = 0; attempt < RUN_DIRECTORY_ATTEMPTS; ++attempt) {
        if (!random_hex(random) ||
            _snwprintf(leaf, sizeof(leaf) / sizeof(leaf[0]),
                       L"QemuGpuZProfile-Run-%ls", random) < 0 ||
            !join_path(run_root, MAX_PATH, program_data, leaf)) {
            break;
        }
        if (CreateDirectoryW(run_root, &attributes)) {
            created = TRUE;
            break;
        }
        if (GetLastError() != ERROR_ALREADY_EXISTS) {
            break;
        }
    }
    *run_handle = INVALID_HANDLE_VALUE;
    *bundle_handle = INVALID_HANDLE_VALUE;
    if (!created || !get_fixed_local_path(run_root) ||
        !join_path(bundle_root, MAX_PATH, run_root, L"bundle") ||
        !CreateDirectoryW(bundle_root, &attributes) ||
        !get_fixed_local_path(bundle_root) ||
        !open_protected_directory(run_root, run_handle) ||
        !open_protected_directory(bundle_root, bundle_handle)) {
        if (*bundle_handle != INVALID_HANDLE_VALUE) {
            CloseHandle(*bundle_handle);
            *bundle_handle = INVALID_HANDLE_VALUE;
        }
        if (*run_handle != INVALID_HANDLE_VALUE) {
            CloseHandle(*run_handle);
            *run_handle = INVALID_HANDLE_VALUE;
        }
        if (created) {
            RemoveDirectoryW(bundle_root);
            RemoveDirectoryW(run_root);
        }
        run_root[0] = L'\0';
        bundle_root[0] = L'\0';
        LocalFree(descriptor);
        return FALSE;
    }
    LocalFree(descriptor);
    return TRUE;
}

static BOOL create_or_open_runtime_temp(const wchar_t *program_data,
                                        wchar_t runtime_temp[MAX_PATH],
                                        HANDLE *runtime_handle)
{
    SECURITY_ATTRIBUTES attributes;
    PSECURITY_DESCRIPTOR descriptor;
    BOOL created;
    DWORD error;

    *runtime_handle = INVALID_HANDLE_VALUE;
    if (!join_path(runtime_temp, MAX_PATH, program_data,
                   L"QemuGpuZProfile-RuntimeTemp") ||
        !make_security_attributes(&attributes, &descriptor)) {
        return FALSE;
    }
    created = CreateDirectoryW(runtime_temp, &attributes);
    error = GetLastError();
    LocalFree(descriptor);
    if (!created && error != ERROR_ALREADY_EXISTS) {
        return FALSE;
    }
    if (!get_fixed_local_path(runtime_temp) ||
        !open_protected_directory(runtime_temp, runtime_handle)) {
        if (created) {
            RemoveDirectoryW(runtime_temp);
        }
        return FALSE;
    }
    return TRUE;
}

static BOOL sha256_memory(const BYTE *data, DWORD bytes,
                          BYTE digest[SHA256_BYTES])
{
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    PUCHAR object = NULL;
    DWORD object_bytes = 0;
    DWORD result_bytes = 0;
    NTSTATUS status;
    BOOL ok = FALSE;

    status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                         NULL, 0);
    if (status < 0 ||
        BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                          (PUCHAR)&object_bytes, sizeof(object_bytes),
                          &result_bytes, 0) < 0 ||
        object_bytes == 0) {
        goto done;
    }
    object = (PUCHAR)HeapAlloc(GetProcessHeap(), 0, object_bytes);
    if (!object ||
        BCryptCreateHash(algorithm, &hash, object, object_bytes,
                         NULL, 0, 0) < 0 ||
        BCryptHashData(hash, (PUCHAR)data, bytes, 0) < 0 ||
        BCryptFinishHash(hash, digest, SHA256_BYTES, 0) < 0) {
        goto done;
    }
    ok = TRUE;

done:
    if (hash) {
        BCryptDestroyHash(hash);
    }
    if (object) {
        SecureZeroMemory(object, object_bytes);
        HeapFree(GetProcessHeap(), 0, object);
    }
    if (algorithm) {
        BCryptCloseAlgorithmProvider(algorithm, 0);
    }
    return ok;
}

static BOOL sha256_handle(HANDLE file, BYTE digest[SHA256_BYTES])
{
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    PUCHAR object = NULL;
    BYTE buffer[65536];
    DWORD object_bytes = 0;
    DWORD result_bytes = 0;
    DWORD read_bytes;
    LARGE_INTEGER zero;
    BOOL ok = FALSE;

    zero.QuadPart = 0;
    if (!SetFilePointerEx(file, zero, NULL, FILE_BEGIN) ||
        BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                    NULL, 0) < 0 ||
        BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                          (PUCHAR)&object_bytes, sizeof(object_bytes),
                          &result_bytes, 0) < 0 ||
        object_bytes == 0) {
        goto done;
    }
    object = (PUCHAR)HeapAlloc(GetProcessHeap(), 0, object_bytes);
    if (!object ||
        BCryptCreateHash(algorithm, &hash, object, object_bytes,
                         NULL, 0, 0) < 0) {
        goto done;
    }
    do {
        if (!ReadFile(file, buffer, sizeof(buffer), &read_bytes, NULL) ||
            (read_bytes != 0 &&
             BCryptHashData(hash, buffer, read_bytes, 0) < 0)) {
            goto done;
        }
    } while (read_bytes != 0);
    if (BCryptFinishHash(hash, digest, SHA256_BYTES, 0) < 0 ||
        !SetFilePointerEx(file, zero, NULL, FILE_BEGIN)) {
        goto done;
    }
    ok = TRUE;

done:
    SecureZeroMemory(buffer, sizeof(buffer));
    if (hash) {
        BCryptDestroyHash(hash);
    }
    if (object) {
        SecureZeroMemory(object, object_bytes);
        HeapFree(GetProcessHeap(), 0, object);
    }
    if (algorithm) {
        BCryptCloseAlgorithmProvider(algorithm, 0);
    }
    return ok;
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

static BOOL write_all(HANDLE file, const BYTE *data, DWORD bytes)
{
    DWORD offset = 0;

    while (offset < bytes) {
        DWORD written = 0;
        if (!WriteFile(file, data + offset, bytes - offset, &written, NULL) ||
            written == 0) {
            return FALSE;
        }
        offset += written;
    }
    return TRUE;
}

static BOOL safe_payload_name(const wchar_t *name)
{
    size_t length = wcslen(name);
    size_t index;

    if (length == 0 || length > 128 || name[0] == L'.' ||
        wcsstr(name, L"..") != NULL) {
        return FALSE;
    }
    for (index = 0; index < length; ++index) {
        wchar_t value = name[index];
        if (!((value >= L'A' && value <= L'Z') ||
              (value >= L'a' && value <= L'z') ||
              (value >= L'0' && value <= L'9') ||
              value == L'.' || value == L'_' || value == L'-')) {
            return FALSE;
        }
    }
    return TRUE;
}

static BOOL extract_payload(const wchar_t *bundle_root, HANDLE *locks)
{
    SECURITY_ATTRIBUTES attributes;
    PSECURITY_DESCRIPTOR descriptor;
    size_t index;

    if (!make_security_attributes(&attributes, &descriptor)) {
        return FALSE;
    }
    for (index = 0; index < PAYLOAD_COUNT; ++index) {
        const PayloadEntry *entry = &PAYLOAD_ENTRIES[index];
        HRSRC resource;
        HGLOBAL loaded;
        const BYTE *data;
        DWORD resource_bytes;
        BYTE digest[SHA256_BYTES];
        wchar_t path[MAX_PATH];
        HANDLE output = INVALID_HANDLE_VALUE;
        HANDLE locked = INVALID_HANDLE_VALUE;
        BY_HANDLE_FILE_INFORMATION information;

        if (!safe_payload_name(entry->name) ||
            !join_path(path, MAX_PATH, bundle_root, entry->name)) {
            LocalFree(descriptor);
            return FALSE;
        }
        resource = FindResourceW(NULL, MAKEINTRESOURCEW(entry->resource_id),
                                 RT_RCDATA);
        if (!resource ||
            (resource_bytes = SizeofResource(NULL, resource)) != entry->bytes ||
            !(loaded = LoadResource(NULL, resource)) ||
            !(data = (const BYTE *)LockResource(loaded)) ||
            !sha256_memory(data, resource_bytes, digest) ||
            !digest_equal(digest, entry->sha256)) {
            SecureZeroMemory(digest, sizeof(digest));
            LocalFree(descriptor);
            return FALSE;
        }
        output = CreateFileW(path, GENERIC_WRITE, 0, &attributes, CREATE_NEW,
                             FILE_ATTRIBUTE_READONLY |
                             FILE_FLAG_WRITE_THROUGH, NULL);
        if (output == INVALID_HANDLE_VALUE ||
            !write_all(output, data, resource_bytes) ||
            !FlushFileBuffers(output)) {
            if (output != INVALID_HANDLE_VALUE) {
                CloseHandle(output);
            }
            SecureZeroMemory(digest, sizeof(digest));
            LocalFree(descriptor);
            return FALSE;
        }
        CloseHandle(output);
        output = INVALID_HANDLE_VALUE;

        locked = CreateFileW(path, GENERIC_READ | READ_CONTROL,
                             FILE_SHARE_READ, NULL,
                             OPEN_EXISTING,
                             FILE_ATTRIBUTE_READONLY |
                             FILE_FLAG_OPEN_REPARSE_POINT |
                             FILE_FLAG_SEQUENTIAL_SCAN, NULL);
        if (locked == INVALID_HANDLE_VALUE ||
            !GetFileInformationByHandle(locked, &information) ||
            (information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
            information.nFileSizeHigh != 0 ||
            information.nFileSizeLow != entry->bytes ||
            !verify_protected_handle(locked) ||
            !sha256_handle(locked, digest) ||
            !digest_equal(digest, entry->sha256)) {
            if (locked != INVALID_HANDLE_VALUE) {
                CloseHandle(locked);
            }
            SecureZeroMemory(digest, sizeof(digest));
            LocalFree(descriptor);
            return FALSE;
        }
        locks[index] = locked;
        SecureZeroMemory(digest, sizeof(digest));
    }
    LocalFree(descriptor);
    return TRUE;
}

static void close_payload_locks(HANDLE *locks)
{
    size_t index;

    for (index = 0; index < PAYLOAD_COUNT; ++index) {
        if (locks[index] && locks[index] != INVALID_HANDLE_VALUE) {
            CloseHandle(locks[index]);
            locks[index] = INVALID_HANDLE_VALUE;
        }
    }
}

static BOOL delete_tree_without_following_reparse(const wchar_t *root)
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
            SetFileAttributesW(child, FILE_ATTRIBUTE_NORMAL);
            if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                if ((data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0) {
                    if (!delete_tree_without_following_reparse(child)) {
                        ok = FALSE;
                    }
                } else if (!RemoveDirectoryW(child)) {
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
    } else if (GetLastError() != ERROR_FILE_NOT_FOUND) {
        ok = FALSE;
    }
    SetFileAttributesW(root, FILE_ATTRIBUTE_NORMAL);
    if (!RemoveDirectoryW(root)) {
        ok = FALSE;
    }
    return ok;
}

static BOOL append_environment(wchar_t *environment, size_t capacity,
                               size_t *used, const wchar_t *name,
                               const wchar_t *value)
{
    size_t name_length = wcslen(name);
    size_t value_length = wcslen(value);

    if (name_length == 0 || wcschr(name, L'=') != NULL ||
        *used + name_length + 1u + value_length + 1u >= capacity) {
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

static BOOL build_clean_environment(const wchar_t *program_data,
                                    const wchar_t *runtime_temp,
                                    const wchar_t *windows_root,
                                    const wchar_t *system_root,
                                    wchar_t *environment,
                                    size_t environment_count)
{
    wchar_t program_files[MAX_PATH];
    wchar_t program_files_x86[MAX_PATH];
    wchar_t common_program_files[MAX_PATH];
    wchar_t common_program_files_x86[MAX_PATH];
    wchar_t module_path[MAX_PATH * 3];
    wchar_t path_value[MAX_PATH * 4];
    wchar_t command_shell[MAX_PATH];
    wchar_t volume_root[MAX_PATH];
    wchar_t system_drive[3];
    size_t used = 0;
    int result;

    if (SHGetFolderPathW(NULL, CSIDL_PROGRAM_FILES, NULL,
                         SHGFP_TYPE_CURRENT, program_files) != S_OK ||
        SHGetFolderPathW(NULL, CSIDL_PROGRAM_FILESX86, NULL,
                         SHGFP_TYPE_CURRENT, program_files_x86) != S_OK ||
        SHGetFolderPathW(NULL, CSIDL_PROGRAM_FILES_COMMON, NULL,
                         SHGFP_TYPE_CURRENT, common_program_files) != S_OK ||
        SHGetFolderPathW(NULL, CSIDL_PROGRAM_FILES_COMMONX86, NULL,
                         SHGFP_TYPE_CURRENT,
                         common_program_files_x86) != S_OK ||
        !get_fixed_local_path(program_files) ||
        !get_fixed_local_path(program_files_x86) ||
        !get_fixed_local_path(common_program_files) ||
        !get_fixed_local_path(common_program_files_x86) ||
        !join_path(command_shell, MAX_PATH, system_root, L"cmd.exe") ||
        !GetVolumePathNameW(windows_root, volume_root, MAX_PATH) ||
        wcslen(volume_root) < 2 || volume_root[1] != L':') {
        return FALSE;
    }
    system_drive[0] = volume_root[0];
    system_drive[1] = L':';
    system_drive[2] = L'\0';
    result = _snwprintf(
        module_path, sizeof(module_path) / sizeof(module_path[0]),
        L"%ls\\System32\\WindowsPowerShell\\v1.0\\Modules;"
        L"%ls\\WindowsPowerShell\\Modules",
        windows_root, program_files);
    if (result < 0 ||
        (size_t)result >= sizeof(module_path) / sizeof(module_path[0])) {
        return FALSE;
    }
    result = _snwprintf(
        path_value, sizeof(path_value) / sizeof(path_value[0]),
        L"%ls;%ls\\Wbem;%ls\\WindowsPowerShell\\v1.0;%ls",
        system_root, system_root, system_root, windows_root);
    if (result < 0 ||
        (size_t)result >= sizeof(path_value) / sizeof(path_value[0])) {
        return FALSE;
    }
    /*
     * This sorted whitelist becomes the complete child environment. No
     * inherited COR_*, COMPLUS_* or DOTNET_* variable can load a profiler
     * before the PowerShell integrity gates execute.
     */
    if (!append_environment(environment, environment_count, &used,
                            L"ALLUSERSPROFILE", program_data) ||
        !append_environment(environment, environment_count, &used,
                            L"CommonProgramFiles", common_program_files) ||
        !append_environment(environment, environment_count, &used,
                            L"CommonProgramFiles(x86)",
                            common_program_files_x86) ||
        !append_environment(environment, environment_count, &used,
                            L"CommonProgramW6432", common_program_files) ||
        !append_environment(environment, environment_count, &used,
                            L"ComSpec", command_shell) ||
        !append_environment(environment, environment_count, &used,
                            L"OS", L"Windows_NT") ||
        !append_environment(environment, environment_count, &used,
                            L"Path", path_value) ||
        !append_environment(environment, environment_count, &used,
                            L"PATHEXT", L".COM;.EXE;.BAT;.CMD") ||
        !append_environment(environment, environment_count, &used,
                            L"PROCESSOR_ARCHITECTURE", L"AMD64") ||
        !append_environment(environment, environment_count, &used,
                            L"ProgramData", program_data) ||
        !append_environment(environment, environment_count, &used,
                            L"ProgramFiles", program_files) ||
        !append_environment(environment, environment_count, &used,
                            L"ProgramFiles(x86)", program_files_x86) ||
        !append_environment(environment, environment_count, &used,
                            L"ProgramW6432", program_files) ||
        !append_environment(environment, environment_count, &used,
                            L"PSModulePath", module_path) ||
        !append_environment(environment, environment_count, &used,
                            L"SystemDrive", system_drive) ||
        !append_environment(environment, environment_count, &used,
                            L"SystemRoot", windows_root) ||
        !append_environment(environment, environment_count, &used,
                            L"TEMP", runtime_temp) ||
        !append_environment(environment, environment_count, &used,
                            L"TMP", runtime_temp) ||
        !append_environment(environment, environment_count, &used,
                            L"windir", windows_root) ||
        used >= environment_count) {
        return FALSE;
    }
    environment[used] = L'\0';
    return TRUE;
}

static BOOL duplicate_standard_handle(DWORD identifier, DWORD null_access,
                                      HANDLE *result)
{
    SECURITY_ATTRIBUTES attributes;
    HANDLE source;

    *result = INVALID_HANDLE_VALUE;
    source = GetStdHandle(identifier);
    if (source != NULL && source != INVALID_HANDLE_VALUE &&
        DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(),
                        result, 0, TRUE, DUPLICATE_SAME_ACCESS)) {
        return TRUE;
    }

    ZeroMemory(&attributes, sizeof(attributes));
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;
    *result = CreateFileW(L"NUL", null_access,
                          FILE_SHARE_READ | FILE_SHARE_WRITE,
                          &attributes, OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL, NULL);
    return *result != INVALID_HANDLE_VALUE;
}

static void close_child_standard_handles(HANDLE handles[3])
{
    size_t index;

    for (index = 0; index < 3; ++index) {
        if (handles[index] != NULL &&
            handles[index] != INVALID_HANDLE_VALUE) {
            CloseHandle(handles[index]);
            handles[index] = INVALID_HANDLE_VALUE;
        }
    }
}

static BOOL run_profile(const wchar_t *program_data,
                        const wchar_t *bundle_root,
                        const wchar_t *runtime_temp,
                        BOOL verify_only, BOOL no_launch,
                        DWORD *exit_code, BOOL *process_created,
                        BOOL *process_completed)
{
    wchar_t windows_root[MAX_PATH];
    wchar_t system_root[MAX_PATH];
    wchar_t powershell[MAX_PATH];
    wchar_t script[MAX_PATH];
    wchar_t command_line[2048];
    wchar_t environment[CHILD_ENVIRONMENT_CHARS];
    STARTUPINFOEXW startup;
    PROCESS_INFORMATION process;
    HANDLE child_standard_handles[3] = {
        INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE
    };
    LPPROC_THREAD_ATTRIBUTE_LIST attribute_list = NULL;
    SIZE_T attribute_bytes = 0;
    DWORD wait_result;
    DWORD creation_flags =
        CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT;
    BOOL created;
    int result;

    *process_created = FALSE;
    *process_completed = FALSE;
    *exit_code = ERROR_GEN_FAILURE;
    if (!GetWindowsDirectoryW(windows_root, MAX_PATH) ||
        !GetSystemDirectoryW(system_root, MAX_PATH) ||
        !get_fixed_local_path(windows_root) ||
        !get_fixed_local_path(system_root) ||
        !join_path(powershell, MAX_PATH, system_root,
                   L"WindowsPowerShell\\v1.0\\powershell.exe") ||
        !get_fixed_local_path(powershell) ||
        !join_path(script, MAX_PATH, bundle_root,
                   L"apply-gpuz-profile.ps1") ||
        !build_clean_environment(
            program_data, runtime_temp, windows_root, system_root,
            environment, CHILD_ENVIRONMENT_CHARS)) {
        return FALSE;
    }
    result = _snwprintf(
        command_line, sizeof(command_line) / sizeof(command_line[0]),
        L"\"%ls\" -NoLogo -NoProfile -NonInteractive "
        L"-ExecutionPolicy Bypass -File \"%ls\"%ls%ls",
        powershell, script,
        verify_only ? L" -VerifyOnly" : L"",
        no_launch ? L" -NoLaunch" : L"");
    if (result < 0 ||
        (size_t)result >= sizeof(command_line) / sizeof(command_line[0])) {
        SecureZeroMemory(environment, sizeof(environment));
        return FALSE;
    }

    ZeroMemory(&startup, sizeof(startup));
    startup.StartupInfo.cb = sizeof(startup);
    ZeroMemory(&process, sizeof(process));
    if (!duplicate_standard_handle(
            STD_INPUT_HANDLE, GENERIC_READ,
            &child_standard_handles[0]) ||
        !duplicate_standard_handle(
            STD_OUTPUT_HANDLE, GENERIC_WRITE,
            &child_standard_handles[1]) ||
        !duplicate_standard_handle(
            STD_ERROR_HANDLE, GENERIC_WRITE,
            &child_standard_handles[2])) {
        close_child_standard_handles(child_standard_handles);
        SecureZeroMemory(command_line, sizeof(command_line));
        SecureZeroMemory(environment, sizeof(environment));
        return FALSE;
    }
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = child_standard_handles[0];
    startup.StartupInfo.hStdOutput = child_standard_handles[1];
    startup.StartupInfo.hStdError = child_standard_handles[2];
    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_bytes);
    if (attribute_bytes == 0 ||
        !(attribute_list = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(
            GetProcessHeap(), 0, attribute_bytes))) {
        close_child_standard_handles(child_standard_handles);
        SecureZeroMemory(command_line, sizeof(command_line));
        SecureZeroMemory(environment, sizeof(environment));
        return FALSE;
    }
    if (!InitializeProcThreadAttributeList(
            attribute_list, 1, 0, &attribute_bytes)) {
        HeapFree(GetProcessHeap(), 0, attribute_list);
        close_child_standard_handles(child_standard_handles);
        SecureZeroMemory(command_line, sizeof(command_line));
        SecureZeroMemory(environment, sizeof(environment));
        return FALSE;
    }
    if (!UpdateProcThreadAttribute(
            attribute_list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            child_standard_handles, sizeof(child_standard_handles),
            NULL, NULL)) {
        DeleteProcThreadAttributeList(attribute_list);
        HeapFree(GetProcessHeap(), 0, attribute_list);
        close_child_standard_handles(child_standard_handles);
        SecureZeroMemory(command_line, sizeof(command_line));
        SecureZeroMemory(environment, sizeof(environment));
        return FALSE;
    }
    startup.lpAttributeList = attribute_list;
    created = CreateProcessW(powershell, command_line, NULL, NULL, TRUE,
        creation_flags,
        environment, bundle_root, &startup.StartupInfo, &process);
    DeleteProcThreadAttributeList(attribute_list);
    HeapFree(GetProcessHeap(), 0, attribute_list);
    close_child_standard_handles(child_standard_handles);
    if (!created) {
        SecureZeroMemory(command_line, sizeof(command_line));
        SecureZeroMemory(environment, sizeof(environment));
        return FALSE;
    }
    *process_created = TRUE;
    SecureZeroMemory(command_line, sizeof(command_line));
    SecureZeroMemory(environment, sizeof(environment));
    CloseHandle(process.hThread);
    wait_result = WaitForSingleObject(process.hProcess, INFINITE);
    if (wait_result != WAIT_OBJECT_0) {
        if (!TerminateProcess(process.hProcess, ERROR_OPERATION_ABORTED) ||
            WaitForSingleObject(process.hProcess, 30000) != WAIT_OBJECT_0) {
            CloseHandle(process.hProcess);
            return FALSE;
        }
        *process_completed = TRUE;
        *exit_code = ERROR_OPERATION_ABORTED;
        CloseHandle(process.hProcess);
        return FALSE;
    }
    *process_completed = TRUE;
    if (!GetExitCodeProcess(process.hProcess, exit_code)) {
        CloseHandle(process.hProcess);
        return FALSE;
    }
    CloseHandle(process.hProcess);
    return TRUE;
}

static int parse_arguments(int argc, wchar_t **argv,
                           BOOL *verify_only, BOOL *no_launch)
{
    int index;
    int valid = 1;

    *verify_only = FALSE;
    *no_launch = FALSE;
    for (index = 1; index < argc; ++index) {
        if (_wcsicmp(argv[index], L"/verify-only") == 0 ||
            _wcsicmp(argv[index], L"--verify-only") == 0) {
            *verify_only = TRUE;
        } else if (_wcsicmp(argv[index], L"/no-launch") == 0 ||
                   _wcsicmp(argv[index], L"--no-launch") == 0) {
            *no_launch = TRUE;
        } else {
            valid = 0;
        }
    }
    return valid;
}

int wmain(int argc, wchar_t **argv)
{
    wchar_t program_data[MAX_PATH];
    wchar_t run_root[MAX_PATH] = L"";
    wchar_t bundle_root[MAX_PATH] = L"";
    wchar_t runtime_temp[MAX_PATH] = L"";
    HANDLE locks[PAYLOAD_COUNT];
    SECURITY_ATTRIBUTES mutex_attributes;
    PSECURITY_DESCRIPTOR mutex_descriptor = NULL;
    HANDLE mutex = NULL;
    HANDLE run_handle = INVALID_HANDLE_VALUE;
    HANDLE bundle_handle = INVALID_HANDLE_VALUE;
    HANDLE runtime_handle = INVALID_HANDLE_VALUE;
    DWORD child_exit = ERROR_GEN_FAILURE;
    BOOL verify_only;
    BOOL no_launch;
    BOOL process_created = FALSE;
    BOOL process_completed = FALSE;
    BOOL profile_observed = FALSE;
    BOOL cleanup_ok = TRUE;
    wchar_t result_message[512];
    int return_code = 1;
    size_t index;

    (void)LAUNCHER_MARKER;
    SetConsoleTitleW(L"QEMU GPU-Z profile installer");
    for (index = 0; index < PAYLOAD_COUNT; ++index) {
        locks[index] = INVALID_HANDLE_VALUE;
    }
    if (!parse_arguments(argc, argv, &verify_only, &no_launch)) {
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"Only /verify-only and /no-launch are accepted.");
        return 2;
    }
    if (!is_administrator()) {
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"Administrator elevation is required.");
        return 1;
    }
    if (!make_mutex_security_attributes(&mutex_attributes,
                                        &mutex_descriptor)) {
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"Could not create the protected execution lock.");
        return 1;
    }
    mutex = CreateMutexW(&mutex_attributes, FALSE,
                         L"Global\\QemuGpuZProfileSingleExeV1");
    LocalFree(mutex_descriptor);
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) {
        if (mutex) {
            CloseHandle(mutex);
        }
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"Another GPU-Z profile installer is already running.");
        return 1;
    }
    if (SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL,
                         SHGFP_TYPE_CURRENT, program_data) != S_OK ||
        !get_fixed_local_path(program_data)) {
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"ProgramData is not a fixed, non-reparse directory.");
        goto done;
    }
    if (!create_or_open_runtime_temp(program_data, runtime_temp,
                                     &runtime_handle)) {
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"The protected persistent runtime TEMP is unavailable.");
        goto done;
    }
    if (!create_run_directories(program_data, run_root, bundle_root,
                                &run_handle, &bundle_handle)) {
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"Could not create the protected extraction directory.");
        goto done;
    }
    wprintf(L"[GPU-Z profile] Verifying and extracting %u embedded assets...\n",
            (unsigned int)PAYLOAD_COUNT);
    if (!extract_payload(bundle_root, locks)) {
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"An embedded asset failed its size or SHA-256 check.");
        goto done;
    }
    wprintf(L"[GPU-Z profile] Running the signed-driver, BCD and topology gates...\n");
    profile_observed = run_profile(
        program_data, bundle_root, runtime_temp, verify_only, no_launch,
        &child_exit, &process_created, &process_completed);
    if (!profile_observed) {
        if (!process_created) {
            show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                         L"Could not start the fixed system PowerShell process.");
        } else if (process_completed) {
            show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                         L"The system PowerShell process was stopped after a wait/exit-code failure.");
        } else {
            show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                         L"The system PowerShell process could not be safely observed or stopped; protected files were retained.");
        }
        goto done;
    }
    return_code = (int)child_exit;

done:
    close_payload_locks(locks);
    if (bundle_handle != INVALID_HANDLE_VALUE) {
        CloseHandle(bundle_handle);
        bundle_handle = INVALID_HANDLE_VALUE;
    }
    if (run_handle != INVALID_HANDLE_VALUE) {
        CloseHandle(run_handle);
        run_handle = INVALID_HANDLE_VALUE;
    }
    if (runtime_handle != INVALID_HANDLE_VALUE) {
        CloseHandle(runtime_handle);
        runtime_handle = INVALID_HANDLE_VALUE;
    }
    if (run_root[0] != L'\0' &&
        (!process_created || process_completed)) {
        cleanup_ok = delete_tree_without_following_reparse(run_root);
    } else if (run_root[0] != L'\0') {
        cleanup_ok = FALSE;
    }
    if (mutex) {
        CloseHandle(mutex);
    }
    if (profile_observed && child_exit == 0 && cleanup_ok) {
        _snwprintf(result_message,
                   sizeof(result_message) / sizeof(result_message[0]),
                   L"The embedded installer returned %ls PASS.",
                   verify_only ? L"VERIFY" : L"INSTALL");
        show_message(no_launch, MB_ICONINFORMATION, L"GPU-Z profile",
                     result_message);
    } else if (profile_observed && child_exit == 0) {
        return_code = 1;
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"The inner gates passed, but protected extraction cleanup failed; overall result is failure.");
    } else if (profile_observed) {
        _snwprintf(result_message,
                   sizeof(result_message) / sizeof(result_message[0]),
                   L"The embedded installer failed with exit code %lu.%ls",
                   (unsigned long)child_exit,
                   cleanup_ok ? L"" :
                       L"\nThe protected temporary directory could not be fully removed.");
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     result_message);
    } else if (!cleanup_ok && (!process_created || process_completed)) {
        show_message(no_launch, MB_ICONERROR, L"GPU-Z profile",
                     L"Launcher failure cleanup did not fully remove the protected extraction directory.");
    }
    return return_code;
}
