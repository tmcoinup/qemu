/*
 * VMate launch guard Windows integrity and authorization checks.
 * VMate 启动门禁的 Windows 完整性与授权校验。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "system/vmate-launch-guard-internal.h"

#ifdef _WIN32

#include <aclapi.h>
#include <sddl.h>

#define VMATE_LAUNCH_DENIED 126
#define VMATE_AUTHORIZATION_TIMEOUT_MS 30000
#define VMATE_TRUSTED_INSTALLER_SID \
    L"S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"

typedef struct VMatePrivilegedSids {
    BYTE local_system[SECURITY_MAX_SID_SIZE];
    BYTE administrators[SECURITY_MAX_SID_SIZE];
    PSID trusted_installer;
} VMatePrivilegedSids;

static void vmate_close_verified_handle(gpointer opaque)
{
    HANDLE handle = opaque;

    if (handle && handle != INVALID_HANDLE_VALUE) {
        CloseHandle(handle);
    }
}

static bool vmate_path_equal(const wchar_t *actual, const wchar_t *expected)
{
    if (!wcsncmp(actual, L"\\\\?\\", 4)) {
        actual += 4;
    }
    return _wcsicmp(actual, expected) == 0;
}

static bool vmate_volume_is_supported(const wchar_t *install_root)
{
    static const wchar_t local_device_prefix[] = L"\\Device\\HarddiskVolume";
    wchar_t volume_root[] = { install_root[0], L':', L'\\', L'\0' };
    wchar_t drive_name[] = { install_root[0], L':', L'\0' };
    wchar_t volume_path[VMATE_MAX_WINDOWS_PATH];
    wchar_t device_path[1024];
    DWORD filesystem_flags = 0;

    /*
     * Mapped, substituted, remote and removable drives do not provide a
     * stable local trust root. Persistent ACL support is mandatory as well.
     * 拒绝不可信盘，且卷必须支持持久 ACL。
     */
    if (GetDriveTypeW(volume_root) != DRIVE_FIXED ||
        !QueryDosDeviceW(drive_name, device_path,
                         G_N_ELEMENTS(device_path)) ||
        _wcsnicmp(device_path, local_device_prefix,
                  G_N_ELEMENTS(local_device_prefix) - 1) != 0 ||
        !GetVolumePathNameW(install_root, volume_path,
                            G_N_ELEMENTS(volume_path)) ||
        !vmate_path_equal(volume_path, volume_root) ||
        !GetVolumeInformationW(volume_root, NULL, 0, NULL, NULL,
                               &filesystem_flags, NULL, 0) ||
        !(filesystem_flags & FILE_PERSISTENT_ACLS)) {
        return false;
    }
    return true;
}

static bool vmate_init_privileged_sids(VMatePrivilegedSids *sids)
{
    DWORD local_system_size = sizeof(sids->local_system);
    DWORD administrators_size = sizeof(sids->administrators);

    memset(sids, 0, sizeof(*sids));
    if (!CreateWellKnownSid(WinLocalSystemSid, NULL, sids->local_system,
                            &local_system_size) ||
        !CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL,
                            sids->administrators, &administrators_size)) {
        return false;
    }
    return ConvertStringSidToSidW(VMATE_TRUSTED_INSTALLER_SID,
                                  &sids->trusted_installer) != FALSE;
}

static void vmate_clear_privileged_sids(VMatePrivilegedSids *sids)
{
    LocalFree(sids->trusted_installer);
    sids->trusted_installer = NULL;
}

static bool vmate_sid_is_privileged(PSID sid,
                                    const VMatePrivilegedSids *privileged)
{
    return EqualSid(sid, (PSID)privileged->local_system) ||
           EqualSid(sid, (PSID)privileged->administrators) ||
           EqualSid(sid, privileged->trusted_installer);
}

static bool vmate_allowed_ace(const ACE_HEADER *header, ACCESS_MASK *mask,
                              PSID *sid, bool *is_allow)
{
    const BYTE *begin = (const BYTE *)header;
    const BYTE *end = begin + header->AceSize;
    const BYTE *sid_bytes;
    size_t sid_offset = sizeof(ACE_HEADER) + sizeof(ACCESS_MASK);
    DWORD object_flags = 0;
    DWORD sid_length;

    *is_allow = false;
    switch (header->AceType) {
    case ACCESS_ALLOWED_ACE_TYPE:
    case ACCESS_ALLOWED_OBJECT_ACE_TYPE:
    case 0x09: /* ACCESS_ALLOWED_CALLBACK_ACE_TYPE */
    case 0x0b: /* ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE */
        *is_allow = true;
        break;
    case ACCESS_DENIED_ACE_TYPE:
    case SYSTEM_AUDIT_ACE_TYPE:
    case 0x03: /* SYSTEM_ALARM_ACE_TYPE */
    case 0x06: /* ACCESS_DENIED_OBJECT_ACE_TYPE */
    case 0x07: /* SYSTEM_AUDIT_OBJECT_ACE_TYPE */
    case 0x08: /* SYSTEM_ALARM_OBJECT_ACE_TYPE */
    case 0x0a: /* ACCESS_DENIED_CALLBACK_ACE_TYPE */
    case 0x0c: /* ACCESS_DENIED_CALLBACK_OBJECT_ACE_TYPE */
    case 0x0d: /* SYSTEM_AUDIT_CALLBACK_ACE_TYPE */
    case 0x0e: /* SYSTEM_ALARM_CALLBACK_ACE_TYPE */
    case 0x0f: /* SYSTEM_AUDIT_CALLBACK_OBJECT_ACE_TYPE */
    case 0x10: /* SYSTEM_ALARM_CALLBACK_OBJECT_ACE_TYPE */
        return true;
    default:
        return false;
    }
    if (header->AceSize < sid_offset + sizeof(SID) - sizeof(DWORD)) {
        return false;
    }
    memcpy(mask, begin + sizeof(ACE_HEADER), sizeof(*mask));
    if (header->AceType == ACCESS_ALLOWED_OBJECT_ACE_TYPE ||
        header->AceType == 0x0b) {
        if (header->AceSize < sid_offset + sizeof(object_flags)) {
            return false;
        }
        memcpy(&object_flags, begin + sid_offset, sizeof(object_flags));
        if (object_flags & ~(ACE_OBJECT_TYPE_PRESENT |
                             ACE_INHERITED_OBJECT_TYPE_PRESENT)) {
            return false;
        }
        sid_offset += sizeof(object_flags);
        if (object_flags & ACE_OBJECT_TYPE_PRESENT) {
            sid_offset += sizeof(GUID);
        }
        if (object_flags & ACE_INHERITED_OBJECT_TYPE_PRESENT) {
            sid_offset += sizeof(GUID);
        }
    }
    if (sid_offset + sizeof(SID) - sizeof(DWORD) > header->AceSize) {
        return false;
    }
    sid_bytes = begin + sid_offset;
    if (!IsValidSid((PSID)sid_bytes)) {
        return false;
    }
    sid_length = GetLengthSid((PSID)sid_bytes);
    if (sid_length > (DWORD)(end - sid_bytes)) {
        return false;
    }
    *sid = (PSID)sid_bytes;
    return true;
}

static bool vmate_acl_is_safe(HANDLE handle,
                              const VMatePrivilegedSids *privileged,
                              ACCESS_MASK dangerous)
{
    PSECURITY_DESCRIPTOR security = NULL;
    PSID owner = NULL;
    PACL dacl = NULL;
    DWORD result;
    DWORD index;
    bool safe = false;

    result = GetSecurityInfo(handle, SE_FILE_OBJECT,
                             OWNER_SECURITY_INFORMATION |
                             DACL_SECURITY_INFORMATION,
                             &owner, NULL, &dacl, NULL, &security);
    if (result != ERROR_SUCCESS || !security || !owner || !dacl ||
        !IsValidSid(owner) || !IsValidAcl(dacl) ||
        !vmate_sid_is_privileged(owner, privileged)) {
        goto cleanup;
    }
    for (index = 0; index < dacl->AceCount; index++) {
        ACE_HEADER *header;
        ACCESS_MASK mask = 0;
        PSID sid = NULL;
        bool is_allow;

        if (!GetAce(dacl, index, (void **)&header) ||
            !vmate_allowed_ace(header, &mask, &sid, &is_allow)) {
            goto cleanup;
        }
        if (!is_allow || (header->AceFlags & INHERIT_ONLY_ACE) ||
            !(mask & dangerous)) {
            continue;
        }
        if (!vmate_sid_is_privileged(sid, privileged)) {
            goto cleanup;
        }
    }
    safe = true;

cleanup:
    LocalFree(security);
    return safe;
}

static bool vmate_hold_verified_path(const wchar_t *path,
                                     bool expect_directory,
                                     ACCESS_MASK dangerous,
                                     const VMatePrivilegedSids *privileged,
                                     GPtrArray *held_handles)
{
    wchar_t final_path[VMATE_MAX_WINDOWS_PATH];
    BY_HANDLE_FILE_INFORMATION information;
    DWORD final_length;
    HANDLE handle;

    handle = CreateFileW(path, FILE_READ_ATTRIBUTES | READ_CONTROL,
                         FILE_SHARE_READ,
                         NULL, OPEN_EXISTING,
                         FILE_FLAG_OPEN_REPARSE_POINT |
                         FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        return false;
    }
    if (!GetFileInformationByHandle(handle, &information) ||
        (information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        !!(information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) !=
            expect_directory) {
        goto cleanup;
    }
    final_length = GetFinalPathNameByHandleW(handle, final_path,
                                              G_N_ELEMENTS(final_path),
                                              FILE_NAME_NORMALIZED |
                                              VOLUME_NAME_DOS);
    if (!final_length || final_length >= G_N_ELEMENTS(final_path) ||
        !vmate_path_equal(final_path, path)) {
        goto cleanup;
    }
    if (!vmate_acl_is_safe(handle, privileged, dangerous)) {
        goto cleanup;
    }
    g_ptr_array_add(held_handles, handle);
    return true;

cleanup:
    CloseHandle(handle);
    return false;
}

static bool vmate_verify_ancestor_chain(
    const wchar_t *root, const VMatePrivilegedSids *privileged,
    ACCESS_MASK volume_dangerous, ACCESS_MASK ancestor_dangerous,
    GPtrArray *held_handles)
{
    size_t length = wcslen(root);
    g_autofree wchar_t *ancestor = g_try_new(wchar_t, length + 1);
    size_t index;

    if (!ancestor) {
        return false;
    }
    memcpy(ancestor, root, (length + 1) * sizeof(*ancestor));
    ancestor[3] = L'\0';
    if (!vmate_hold_verified_path(ancestor, true, volume_dangerous,
                                  privileged, held_handles)) {
        return false;
    }
    ancestor[3] = root[3];
    for (index = 3; index < length; index++) {
        wchar_t saved;

        if (root[index] != L'\\') {
            continue;
        }
        saved = ancestor[index];
        ancestor[index] = L'\0';
        if (!vmate_hold_verified_path(ancestor, true, ancestor_dangerous,
                                      privileged, held_handles)) {
            return false;
        }
        ancestor[index] = saved;
    }
    return true;
}

static bool vmate_run_authorization(const wchar_t *client,
                                    const wchar_t *working_directory)
{
    static const wchar_t argument[] = L" --vmate-qemu-authorization-check";
    size_t command_length = wcslen(client) + G_N_ELEMENTS(argument) + 2;
    g_autofree wchar_t *command_line = g_try_new(wchar_t, command_length);
    STARTUPINFOW startup = { 0 };
    PROCESS_INFORMATION process = { 0 };
    wchar_t image_path[VMATE_MAX_WINDOWS_PATH];
    DWORD image_length = G_N_ELEMENTS(image_path);
    DWORD wait_result;
    DWORD exit_code = VMATE_LAUNCH_DENIED;
    bool authorized = false;

    if (!command_line) {
        return false;
    }
    swprintf(command_line, command_length, L"\"%ls\"%ls", client, argument);
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    if (!CreateProcessW(client, command_line, NULL, NULL, FALSE,
                        CREATE_NO_WINDOW | CREATE_SUSPENDED, NULL,
                        working_directory,
                        &startup, &process)) {
        return false;
    }
    /*
     * Resolve the actual process image before any client code executes. The
     * already-held no-delete-share handles keep the verified tree immovable.
     * 启动前核对进程映像，并锁定目录树。
     */
    if (!QueryFullProcessImageNameW(process.hProcess, 0, image_path,
                                    &image_length) ||
        !image_length || image_length >= G_N_ELEMENTS(image_path) ||
        !vmate_path_equal(image_path, client) ||
        ResumeThread(process.hThread) == (DWORD)-1) {
        TerminateProcess(process.hProcess, VMATE_LAUNCH_DENIED);
        WaitForSingleObject(process.hProcess, 1000);
        goto cleanup;
    }
    wait_result = WaitForSingleObject(process.hProcess,
                                      VMATE_AUTHORIZATION_TIMEOUT_MS);
    if (wait_result == WAIT_OBJECT_0 &&
        GetExitCodeProcess(process.hProcess, &exit_code)) {
        authorized = exit_code == 0;
    } else {
        TerminateProcess(process.hProcess, VMATE_LAUNCH_DENIED);
        WaitForSingleObject(process.hProcess, 1000);
    }

cleanup:
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return authorized;
}

static bool vmate_windows_check(bool require_authorization)
{
    static const ACCESS_MASK protected_dangerous =
        GENERIC_ALL | GENERIC_WRITE | WRITE_DAC | WRITE_OWNER | DELETE |
        FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA |
        FILE_WRITE_ATTRIBUTES | FILE_DELETE_CHILD;
    static const ACCESS_MASK volume_dangerous =
        GENERIC_ALL | GENERIC_WRITE | WRITE_DAC | WRITE_OWNER | DELETE |
        FILE_DELETE_CHILD;
    static const ACCESS_MASK ancestor_dangerous =
        GENERIC_ALL | GENERIC_WRITE | WRITE_DAC | WRITE_OWNER | DELETE |
        FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_DELETE_CHILD;
    wchar_t module_path[VMATE_MAX_WINDOWS_PATH];
    VMateLaunchGuardLayout layout = { 0 };
    VMatePrivilegedSids privileged = { 0 };
    g_autoptr(GPtrArray) held_handles =
        g_ptr_array_new_with_free_func(vmate_close_verified_handle);
    DWORD length;
    bool sids_ready = false;
    bool result = false;

    SetLastError(ERROR_SUCCESS);
    length = GetModuleFileNameW(NULL, module_path,
                                G_N_ELEMENTS(module_path));
    if (!length || length >= G_N_ELEMENTS(module_path) ||
        GetLastError() == ERROR_INSUFFICIENT_BUFFER ||
        !vmate_launch_guard_derive_layout(module_path, &layout) ||
        !vmate_volume_is_supported(layout.root) ||
        !vmate_init_privileged_sids(&privileged)) {
        goto cleanup;
    }
    sids_ready = true;

    /*
     * A protected install root is insufficient when an unprivileged user can
     * rename one of its parents. Validate the volume root and every ancestor
     * before resolving any executable below the selected installation root.
     * 同时逐级校验卷根和全部祖先。
     */
    if (!vmate_verify_ancestor_chain(layout.root, &privileged,
                                     volume_dangerous,
                                     ancestor_dangerous, held_handles) ||
        !vmate_hold_verified_path(layout.root, true, protected_dangerous,
                                  &privileged, held_handles) ||
        !vmate_hold_verified_path(layout.libexec, true, protected_dangerous,
                                  &privileged, held_handles) ||
        !vmate_hold_verified_path(layout.qemu, false, protected_dangerous,
                                  &privileged, held_handles) ||
        !vmate_hold_verified_path(layout.client, false, protected_dangerous,
                                  &privileged, held_handles)) {
        goto cleanup;
    }

    /* The client is resolved only below the same verified installation root. */
    /* 授权客户端只能从同一个已验证安装根目录启动。 */
    result = !require_authorization ||
             vmate_run_authorization(layout.client, layout.root);

cleanup:
    if (sids_ready) {
        vmate_clear_privileged_sids(&privileged);
    }
    vmate_launch_guard_clear_layout(&layout);
    return result;
}

bool vmate_launch_guard_windows_integrity_valid(void)
{
    return vmate_windows_check(false);
}

bool vmate_launch_guard_windows_authorized(void)
{
    return vmate_windows_check(true);
}

#endif /* _WIN32 */
