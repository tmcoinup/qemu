#ifndef UNICODE
#define UNICODE
#endif

#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#include "payload-security.h"

#define PAYLOAD_PATH_CAP 4096

/*
 * Owner 固定为 Builtin Administrators。受保护 DACL 不继承 ProgramData 可能过宽
 * 的写权限：SYSTEM/Administrators 完全控制，Builtin Users 只读执行。
 * 这样普通用户可以读取发布内容，但不能替换管理员随后执行的脚本。
 */
static const wchar_t payload_sddl[] =
    L"O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)";

typedef struct PayloadSecurity {
    PSECURITY_DESCRIPTOR descriptor;
    PSID owner;
    PACL dacl;
} PayloadSecurity;

static int get_payload_security(PayloadSecurity *security)
{
    BOOL owner_defaulted = FALSE;
    BOOL dacl_present = FALSE;
    BOOL dacl_defaulted = FALSE;

    ZeroMemory(security, sizeof(*security));
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            payload_sddl, SDDL_REVISION_1, &security->descriptor, NULL)) {
        fwprintf(stderr, L"生成 payload 安全描述符失败，错误=%lu\n",
                 GetLastError());
        return 0;
    }
    if (!GetSecurityDescriptorOwner(security->descriptor, &security->owner,
                                    &owner_defaulted) ||
        security->owner == NULL ||
        !GetSecurityDescriptorDacl(security->descriptor, &dacl_present,
                                   &security->dacl, &dacl_defaulted) ||
        !dacl_present || security->dacl == NULL) {
        fwprintf(stderr, L"读取 payload Owner/DACL 模板失败，错误=%lu\n",
                 GetLastError());
        LocalFree(security->descriptor);
        ZeroMemory(security, sizeof(*security));
        return 0;
    }
    return 1;
}

static void free_payload_security(PayloadSecurity *security)
{
    if (security->descriptor != NULL) {
        LocalFree(security->descriptor);
    }
    ZeroMemory(security, sizeof(*security));
}

static int is_plain_directory(const wchar_t *path, int allow_missing)
{
    DWORD attributes = GetFileAttributesW(path);

    if (attributes == INVALID_FILE_ATTRIBUTES) {
        DWORD error = GetLastError();
        if (allow_missing && (error == ERROR_FILE_NOT_FOUND ||
                              error == ERROR_PATH_NOT_FOUND)) {
            return 1;
        }
        fwprintf(stderr, L"无法读取 payload 目录属性: %ls，错误=%lu\n",
                 path, error);
        return 0;
    }
    if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        fwprintf(stderr, L"payload 路径不是目录: %ls\n", path);
        return 0;
    }
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        fwprintf(stderr, L"拒绝 payload 目录重解析点: %ls\n", path);
        return 0;
    }
    return 1;
}

static int check_directory_owner(const wchar_t *path, PSID expected_owner,
                                 int require_expected)
{
    PSECURITY_DESCRIPTOR descriptor = NULL;
    PSID actual_owner = NULL;
    DWORD status = GetNamedSecurityInfoW((LPWSTR)path, SE_FILE_OBJECT,
                                         OWNER_SECURITY_INFORMATION,
                                         &actual_owner, NULL, NULL, NULL,
                                         &descriptor);
    int ok = 0;

    if (status == ERROR_SUCCESS && actual_owner != NULL) {
        if (EqualSid(actual_owner, expected_owner) ||
            (!require_expected &&
             IsWellKnownSid(actual_owner, WinLocalSystemSid))) {
            ok = 1;
        }
    }
    if (!ok) {
        fwprintf(stderr,
                 L"payload 目录 Owner 不受信；拒绝事后接管可能已被预开的目录: "
                 L"%ls，错误=%lu\n", path, status);
    }
    if (descriptor != NULL) {
        LocalFree(descriptor);
    }
    return ok;
}

static int apply_payload_security(const wchar_t *path,
                                  const PayloadSecurity *security)
{
    DWORD status = SetNamedSecurityInfoW(
        (LPWSTR)path, SE_FILE_OBJECT,
        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION |
            PROTECTED_DACL_SECURITY_INFORMATION,
        security->owner, NULL, security->dacl, NULL);

    if (status != ERROR_SUCCESS) {
        fwprintf(stderr, L"设置 payload Owner/DACL 失败: %ls，错误=%lu\n",
                 path, status);
        return 0;
    }
    return is_plain_directory(path, 0) &&
           check_directory_owner(path, security->owner, 1);
}

int payload_secure_directory(const wchar_t *path)
{
    PayloadSecurity security;
    SECURITY_ATTRIBUTES attributes;
    DWORD error;
    int created = 0;
    int ok = 0;

    if (!get_payload_security(&security)) {
        return 0;
    }
    ZeroMemory(&attributes, sizeof(attributes));
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = security.descriptor;

    if (CreateDirectoryW(path, &attributes)) {
        created = 1;
    } else {
        error = GetLastError();
        if (error != ERROR_ALREADY_EXISTS) {
            fwprintf(stderr, L"创建 payload 目录失败: %ls，错误=%lu\n",
                     path, error);
            goto out;
        }
    }
    /*
     * 既有目录先验 Owner 只能是 Administrators/SYSTEM。普通用户 Owner 即使能被
     * 管理员事后改掉，也可能仍持有改 ACL/删除子项的旧句柄；这种情况必须 fail-closed。
     */
    if (is_plain_directory(path, 0) &&
        (created || check_directory_owner(path, security.owner, 0))) {
        ok = apply_payload_security(path, &security);
    }

out:
    free_payload_security(&security);
    return ok;
}

static int join_path(wchar_t *out, size_t cap, const wchar_t *dir,
                     const wchar_t *name)
{
    size_t dir_len = wcslen(dir);
    const wchar_t *separator =
        (dir_len > 0 && dir[dir_len - 1] == L'\\') ? L"" : L"\\";
    int written = swprintf(out, cap, L"%ls%ls%ls", dir, separator, name);

    return written >= 0 && (size_t)written < cap;
}

static int safe_leaf_name(const wchar_t *name)
{
    if (name == NULL || *name == L'\0' || wcscmp(name, L".") == 0 ||
        wcscmp(name, L"..") == 0) {
        return 0;
    }
    return wcspbrk(name, L"\\/:*?\"<>|") == NULL;
}

HANDLE payload_acquire_lock(const wchar_t *root_dir)
{
    wchar_t path[PAYLOAD_PATH_CAP];
    HANDLE lock;
    DWORD attributes;

    if (!is_plain_directory(root_dir, 0) ||
        !join_path(path, PAYLOAD_PATH_CAP, root_dir, L".payload.lock")) {
        fwprintf(stderr, L"生成 payload 锁路径失败: %ls\n", root_dir);
        return INVALID_HANDLE_VALUE;
    }
    attributes = GetFileAttributesW(path);
    if (attributes != INVALID_FILE_ATTRIBUTES &&
        ((attributes & FILE_ATTRIBUTE_DIRECTORY) ||
         (attributes & FILE_ATTRIBUTE_REPARSE_POINT))) {
        fwprintf(stderr, L"拒绝 payload 锁目录或重解析点: %ls\n", path);
        return INVALID_HANDLE_VALUE;
    }

    lock = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                       OPEN_ALWAYS,
                       FILE_ATTRIBUTE_HIDDEN | FILE_FLAG_OPEN_REPARSE_POINT,
                       NULL);
    if (lock == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();

        fwprintf(stderr,
                 L"获取 payload 独占锁失败；可能已有初始化正在运行，错误=%lu\n",
                 error);
        SetLastError(error);
    }
    return lock;
}

static int build_unique_child(wchar_t *out, size_t cap,
                              const wchar_t *root, const wchar_t *kind,
                              unsigned int attempt)
{
    wchar_t name[128];
    int written = swprintf(name, sizeof(name) / sizeof(name[0]),
                           L"%ls-%08lX-%08lX-%03u", kind,
                           GetCurrentProcessId(), GetTickCount(), attempt);

    return written >= 0 && (size_t)written < sizeof(name) / sizeof(name[0]) &&
           join_path(out, cap, root, name);
}

static int create_unique_staging(wchar_t *out, size_t cap,
                                 const wchar_t *root)
{
    PayloadSecurity security;
    SECURITY_ATTRIBUTES attributes;
    unsigned int attempt;
    int ok = 0;

    if (!get_payload_security(&security)) {
        return 0;
    }
    ZeroMemory(&attributes, sizeof(attributes));
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = security.descriptor;

    for (attempt = 0; attempt < 1000; attempt++) {
        if (!build_unique_child(out, cap, root, L"payload-stage", attempt)) {
            break;
        }
        if (CreateDirectoryW(out, &attributes)) {
            ok = apply_payload_security(out, &security);
            break;
        }
        if (GetLastError() != ERROR_ALREADY_EXISTS) {
            fwprintf(stderr, L"创建 payload staging 目录失败，错误=%lu\n",
                     GetLastError());
            break;
        }
    }
    free_payload_security(&security);
    return ok;
}

static int write_all(HANDLE file, const unsigned char *data, DWORD size)
{
    DWORD offset = 0;

    while (offset < size) {
        DWORD written = 0;
        if (!WriteFile(file, data + offset, size - offset, &written, NULL) ||
            written == 0) {
            return 0;
        }
        offset += written;
    }
    return 1;
}

static int verify_open_file(HANDLE file, const unsigned char *data, DWORD size)
{
    unsigned char buffer[64 * 1024];
    LARGE_INTEGER expected;
    LARGE_INTEGER actual;
    DWORD offset = 0;

    expected.QuadPart = size;
    if (!GetFileSizeEx(file, &actual) || actual.QuadPart != expected.QuadPart ||
        !SetFilePointerEx(file, (LARGE_INTEGER){ .QuadPart = 0 }, NULL,
                          FILE_BEGIN)) {
        return 0;
    }
    while (offset < size) {
        DWORD wanted = size - offset;
        DWORD received = 0;
        if (wanted > sizeof(buffer)) {
            wanted = (DWORD)sizeof(buffer);
        }
        if (!ReadFile(file, buffer, wanted, &received, NULL) ||
            received != wanted || memcmp(buffer, data + offset, wanted) != 0) {
            return 0;
        }
        offset += received;
    }
    return 1;
}

static int write_staging_file(const wchar_t *directory,
                              const EmbeddedPayload *payload)
{
    wchar_t path[PAYLOAD_PATH_CAP];
    HANDLE file;
    int ok;

    if (!safe_leaf_name(payload->file_name) || payload->data == NULL ||
        payload->size == 0 ||
        !join_path(path, PAYLOAD_PATH_CAP, directory, payload->file_name)) {
        fwprintf(stderr, L"非法 payload 文件名或内容。\n");
        return 0;
    }
    file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_NEW,
                       FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        fwprintf(stderr, L"创建 staging payload 失败: %ls，错误=%lu\n",
                 path, GetLastError());
        return 0;
    }
    ok = write_all(file, payload->data, payload->size) &&
         FlushFileBuffers(file) &&
         verify_open_file(file, payload->data, payload->size);
    if (!ok) {
        fwprintf(stderr, L"写入或复核 staging payload 失败: %ls，错误=%lu\n",
                 path, GetLastError());
    }
    CloseHandle(file);
    return ok;
}

static int remove_tree(const wchar_t *path)
{
    wchar_t pattern[PAYLOAD_PATH_CAP];
    wchar_t child[PAYLOAD_PATH_CAP];
    WIN32_FIND_DATAW entry;
    HANDLE search;
    DWORD attributes = GetFileAttributesW(path);
    int ok = 1;

    if (attributes == INVALID_FILE_ATTRIBUTES) {
        DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
    }
    if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        return DeleteFileW(path) != FALSE;
    }
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        return RemoveDirectoryW(path) != FALSE;
    }
    if (!join_path(pattern, PAYLOAD_PATH_CAP, path, L"*")) {
        return 0;
    }
    search = FindFirstFileW(pattern, &entry);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(entry.cFileName, L".") == 0 ||
                wcscmp(entry.cFileName, L"..") == 0) {
                continue;
            }
            if (!join_path(child, PAYLOAD_PATH_CAP, path, entry.cFileName) ||
                !remove_tree(child)) {
                ok = 0;
            }
        } while (FindNextFileW(search, &entry));
        FindClose(search);
    } else if (GetLastError() != ERROR_FILE_NOT_FOUND) {
        ok = 0;
    }
    return ok && RemoveDirectoryW(path) != FALSE;
}

static int move_old_directory(const wchar_t *work_dir,
                              const wchar_t *root_dir,
                              wchar_t *backup, size_t backup_cap,
                              int *moved)
{
    unsigned int attempt;
    DWORD attributes = GetFileAttributesW(work_dir);

    *moved = 0;
    backup[0] = L'\0';
    if (attributes == INVALID_FILE_ATTRIBUTES &&
        (GetLastError() == ERROR_FILE_NOT_FOUND ||
         GetLastError() == ERROR_PATH_NOT_FOUND)) {
        return 1;
    }
    if (!is_plain_directory(work_dir, 0) ||
        !payload_secure_directory(work_dir)) {
        return 0;
    }
    for (attempt = 0; attempt < 1000; attempt++) {
        if (!build_unique_child(backup, backup_cap, root_dir,
                                L"payload-old", attempt)) {
            return 0;
        }
        if (MoveFileExW(work_dir, backup, MOVEFILE_WRITE_THROUGH)) {
            *moved = 1;
            return 1;
        }
        if (GetLastError() != ERROR_ALREADY_EXISTS &&
            GetLastError() != ERROR_FILE_EXISTS) {
            fwprintf(stderr, L"暂存旧 payload 目录失败，错误=%lu\n",
                     GetLastError());
            return 0;
        }
    }
    return 0;
}

int payload_publish_bundle(const wchar_t *root_dir,
                           const wchar_t *work_dir,
                           const EmbeddedPayload *payloads,
                           size_t payload_count)
{
    wchar_t staging[PAYLOAD_PATH_CAP];
    wchar_t backup[PAYLOAD_PATH_CAP];
    int old_moved = 0;
    int published = 0;
    size_t index;

    if (payloads == NULL || payload_count == 0 ||
        !is_plain_directory(root_dir, 0) ||
        !create_unique_staging(staging, PAYLOAD_PATH_CAP, root_dir)) {
        return 0;
    }
    for (index = 0; index < payload_count; index++) {
        if (!write_staging_file(staging, &payloads[index])) {
            goto out;
        }
    }
    if (!move_old_directory(work_dir, root_dir, backup, PAYLOAD_PATH_CAP,
                            &old_moved)) {
        goto out;
    }
    if (!MoveFileExW(staging, work_dir, MOVEFILE_WRITE_THROUGH)) {
        fwprintf(stderr, L"发布完整 payload 目录失败，错误=%lu\n", GetLastError());
        if (old_moved &&
            !MoveFileExW(backup, work_dir, MOVEFILE_WRITE_THROUGH)) {
            fwprintf(stderr, L"恢复旧 payload 目录失败，错误=%lu\n", GetLastError());
        }
        goto out;
    }
    staging[0] = L'\0';
    published = 1;

out:
    if (staging[0] != L'\0') {
        (void)remove_tree(staging);
    }
    if (published && old_moved && !remove_tree(backup)) {
        fwprintf(stderr, L"旧 payload 目录仍被占用，保留待下次清理: %ls\n",
                 backup);
    }
    return published;
}
