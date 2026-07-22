/*
 * VMate Windows QEMU launch authorization guard.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "system/vmate-launch-guard.h"

#ifdef _WIN32
#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>
#endif

#define VMATE_LAUNCH_GUARD_MARKER "VMATE_QEMU_LAUNCH_GUARD_V1"
#define VMATE_LAUNCH_DENIED 126
#define VMATE_AUTHORIZATION_TIMEOUT_MS 30000

static const char vmate_launch_guard_marker[] QEMU_USED =
    VMATE_LAUNCH_GUARD_MARKER;

static bool vmate_is_exact_arg(int argc, char **argv, const char *argument)
{
    return argc == 2 && argv && argv[1] && !strcmp(argv[1], argument);
}

static bool vmate_is_help_pair(int argc, char **argv,
                               const char *option, const char *value)
{
    return argc == 3 && argv && argv[1] && argv[2] &&
           !strcmp(argv[1], option) && !strcmp(argv[2], value);
}

static bool vmate_is_fixed_device_help(int argc, char **argv)
{
    static const char *const devices[] = {
        "ICH9-LPC,help",
        "ICH9-SMB,help",
        "ich9-ahci,help",
        "pcie-root-port,help",
        "intel-hda,help",
        "hda-duplex,help",
        "e1000e,help",
        "nvme,help",
        "usb-kbd,help",
        "usb-mouse,help",
        "virtio-vga,help",
        "virtio-vga-gl,help",
    };
    size_t index;

    if (argc != 3 || !argv || !argv[1] || !argv[2] ||
        strcmp(argv[1], "-device")) {
        return false;
    }
    for (index = 0; index < G_N_ELEMENTS(devices); index++) {
        if (!strcmp(argv[2], devices[index])) {
            return true;
        }
    }
    return false;
}

VMateLaunchGuardDecision vmate_launch_guard_classify(int argc, char **argv)
{
    if (vmate_is_exact_arg(argc, argv, "--vmate-launch-guard-status")) {
        return VMATE_LAUNCH_GUARD_REPORT_STATUS;
    }
    if (vmate_is_exact_arg(argc, argv, "-version") ||
        vmate_is_exact_arg(argc, argv, "--version")) {
        return VMATE_LAUNCH_GUARD_ALLOW_PROBE;
    }
    if (vmate_is_help_pair(argc, argv, "-accel", "help") ||
        vmate_is_help_pair(argc, argv, "-netdev", "help") ||
        vmate_is_help_pair(argc, argv, "-display", "help") ||
        vmate_is_help_pair(argc, argv, "-vnc", "help") ||
        vmate_is_help_pair(argc, argv, "-object", "fb-shm,help") ||
        vmate_is_fixed_device_help(argc, argv)) {
        return VMATE_LAUNCH_GUARD_ALLOW_PROBE;
    }
    return VMATE_LAUNCH_GUARD_AUTHORIZE;
}

static int vmate_launch_denied(const char *reason)
{
    fprintf(stderr, "%s: VMate launch authorization denied: %s\n",
            vmate_launch_guard_marker, reason);
    return VMATE_LAUNCH_DENIED;
}

#ifdef _WIN32

#define VMATE_MAX_WINDOWS_PATH 32768
#define VMATE_TRUSTED_INSTALLER_SID \
    L"S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"

typedef struct VMatePrivilegedSids {
    BYTE local_system[SECURITY_MAX_SID_SIZE];
    BYTE administrators[SECURITY_MAX_SID_SIZE];
    PSID trusted_installer;
} VMatePrivilegedSids;

static wchar_t *vmate_join_path(const wchar_t *left, const wchar_t *right)
{
    size_t left_length = wcslen(left);
    size_t right_length = wcslen(right);
    bool add_separator = left_length > 0 && left[left_length - 1] != L'\\';
    size_t total = left_length + right_length + add_separator + 1;
    wchar_t *path;

    if (total > VMATE_MAX_WINDOWS_PATH) {
        return NULL;
    }
    path = g_try_new(wchar_t, total);
    if (!path) {
        return NULL;
    }
    wcscpy(path, left);
    if (add_separator) {
        wcscat(path, L"\\");
    }
    wcscat(path, right);
    return path;
}

static bool vmate_path_equal(const wchar_t *actual, const wchar_t *expected)
{
    if (!wcsncmp(actual, L"\\\\?\\", 4)) {
        actual += 4;
    }
    if (!wcsncmp(expected, L"\\\\?\\", 4)) {
        expected += 4;
    }
    return _wcsicmp(actual, expected) == 0;
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
                              const VMatePrivilegedSids *privileged)
{
    static const ACCESS_MASK dangerous =
        GENERIC_ALL | GENERIC_WRITE | WRITE_DAC | WRITE_OWNER | DELETE |
        FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA |
        FILE_WRITE_ATTRIBUTES | FILE_DELETE_CHILD;
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

static bool vmate_verify_path(const wchar_t *path, bool expect_directory,
                              bool check_acl,
                              const VMatePrivilegedSids *privileged)
{
    wchar_t final_path[VMATE_MAX_WINDOWS_PATH];
    BY_HANDLE_FILE_INFORMATION information;
    DWORD final_length;
    HANDLE handle;
    bool valid = false;

    handle = CreateFileW(path, FILE_READ_ATTRIBUTES | READ_CONTROL,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
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
    valid = !check_acl || vmate_acl_is_safe(handle, privileged);

cleanup:
    CloseHandle(handle);
    return valid;
}

static bool vmate_current_module_is_expected(const wchar_t *expected)
{
    wchar_t module_path[VMATE_MAX_WINDOWS_PATH];
    DWORD length = GetModuleFileNameW(NULL, module_path,
                                      G_N_ELEMENTS(module_path));

    return length > 0 && length < G_N_ELEMENTS(module_path) &&
           vmate_path_equal(module_path, expected);
}

static bool vmate_run_authorization(const wchar_t *client,
                                    const wchar_t *working_directory)
{
    static const wchar_t argument[] = L" --vmate-qemu-authorization-check";
    size_t command_length = wcslen(client) + G_N_ELEMENTS(argument) + 2;
    g_autofree wchar_t *command_line = g_try_new(wchar_t, command_length);
    STARTUPINFOW startup = { 0 };
    PROCESS_INFORMATION process = { 0 };
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
                        CREATE_NO_WINDOW, NULL, working_directory,
                        &startup, &process)) {
        return false;
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
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return authorized;
}

static bool vmate_windows_authorized(void)
{
    PWSTR program_files = NULL;
    g_autofree wchar_t *root = NULL;
    g_autofree wchar_t *libexec = NULL;
    g_autofree wchar_t *qemu = NULL;
    g_autofree wchar_t *client = NULL;
    VMatePrivilegedSids privileged;
    bool sids_ready = false;
    bool authorized = false;

    if (FAILED(SHGetKnownFolderPath(&FOLDERID_ProgramFiles, KF_FLAG_DEFAULT,
                                    NULL, &program_files))) {
        goto cleanup;
    }
    root = vmate_join_path(program_files, L"VMate");
    libexec = root ? vmate_join_path(root, L"libexec") : NULL;
    qemu = libexec ? vmate_join_path(
        libexec, L"qemu-system-x86_64.real.exe") : NULL;
    client = root ? vmate_join_path(root, L"vmate-client.exe") : NULL;
    if (!root || !libexec || !qemu || !client ||
        !vmate_current_module_is_expected(qemu) ||
        !vmate_init_privileged_sids(&privileged)) {
        goto cleanup;
    }
    sids_ready = true;
    if (!vmate_verify_path(program_files, true, true, &privileged) ||
        !vmate_verify_path(root, true, true, &privileged) ||
        !vmate_verify_path(libexec, true, true, &privileged) ||
        !vmate_verify_path(qemu, false, true, &privileged) ||
        !vmate_verify_path(client, false, true, &privileged)) {
        goto cleanup;
    }
    authorized = vmate_run_authorization(client, root);

cleanup:
    if (sids_ready) {
        vmate_clear_privileged_sids(&privileged);
    }
    CoTaskMemFree(program_files);
    return authorized;
}

#endif /* _WIN32 */

int vmate_launch_guard_check(int argc, char **argv)
{
    switch (vmate_launch_guard_classify(argc, argv)) {
    case VMATE_LAUNCH_GUARD_REPORT_STATUS:
        fputs("required\n", stdout);
        return 0;
    case VMATE_LAUNCH_GUARD_ALLOW_PROBE:
        return VMATE_LAUNCH_GUARD_CONTINUE;
    case VMATE_LAUNCH_GUARD_AUTHORIZE:
#ifdef _WIN32
        if (vmate_windows_authorized()) {
            return VMATE_LAUNCH_GUARD_CONTINUE;
        }
        return vmate_launch_denied("integrity or authorization check failed");
#else
        return vmate_launch_denied("guard is unavailable on this host");
#endif
    default:
        return vmate_launch_denied("invalid guard decision");
    }
}
