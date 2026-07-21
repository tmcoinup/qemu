#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <stdio.h>
#include <wchar.h>

#include "launcher-arguments.h"
#include "payload-environment.h"
#include "payload-security.h"
#include "payload_dnf_fix_directx_ps1.h"
#include "payload_dnf_fix_deps_ps1.h"
#include "payload_dnf_fix_installers_ps1.h"

#define ARRAY_LEN(value) (sizeof(value) / sizeof((value)[0]))
#define PATH_CAP 4096
#define COMMAND_CAP 32760

static const EmbeddedPayload embedded_payloads[] = {
    {
        L"dnf-fix-deps.ps1",
        payload_dnf_fix_deps_ps1,
        (DWORD)sizeof(payload_dnf_fix_deps_ps1),
    },
    {
        L"dnf-fix-installers.ps1",
        payload_dnf_fix_installers_ps1,
        (DWORD)sizeof(payload_dnf_fix_installers_ps1),
    },
    {
        L"dnf-fix-directx.ps1",
        payload_dnf_fix_directx_ps1,
        (DWORD)sizeof(payload_dnf_fix_directx_ps1),
    },
};

static int append_char(wchar_t *buffer, size_t capacity, size_t *length,
                       wchar_t value)
{
    if (*length + 1 >= capacity) {
        return 0;
    }
    buffer[*length] = value;
    (*length)++;
    buffer[*length] = L'\0';
    return 1;
}

static int append_text(wchar_t *buffer, size_t capacity, size_t *length,
                       const wchar_t *text)
{
    while (*text != L'\0') {
        if (!append_char(buffer, capacity, length, *text)) {
            return 0;
        }
        text++;
    }
    return 1;
}

static int append_backslashes(wchar_t *buffer, size_t capacity,
                              size_t *length, size_t count)
{
    while (count > 0) {
        if (!append_char(buffer, capacity, length, L'\\')) {
            return 0;
        }
        count--;
    }
    return 1;
}

static int append_quoted_arg(wchar_t *buffer, size_t capacity,
                             size_t *length, const wchar_t *argument)
{
    int quote = *argument == L'\0' ||
                wcspbrk(argument, L" \t\r\n\v\"") != NULL;
    size_t slashes = 0;

    if (*length > 0 && !append_char(buffer, capacity, length, L' ')) {
        return 0;
    }
    if (!quote) {
        return append_text(buffer, capacity, length, argument);
    }
    if (!append_char(buffer, capacity, length, L'"')) {
        return 0;
    }

    while (*argument != L'\0') {
        if (*argument == L'\\') {
            slashes++;
            argument++;
            continue;
        }
        if (*argument == L'"') {
            if (!append_backslashes(buffer, capacity, length,
                                    slashes * 2 + 1) ||
                !append_char(buffer, capacity, length, L'"')) {
                return 0;
            }
            slashes = 0;
            argument++;
            continue;
        }
        if (!append_backslashes(buffer, capacity, length, slashes) ||
            !append_char(buffer, capacity, length, *argument)) {
            return 0;
        }
        slashes = 0;
        argument++;
    }
    return append_backslashes(buffer, capacity, length, slashes * 2) &&
           append_char(buffer, capacity, length, L'"');
}

static int join_path(wchar_t *output, size_t capacity,
                     const wchar_t *directory, const wchar_t *leaf)
{
    size_t length = 0;

    output[0] = L'\0';
    if (!append_text(output, capacity, &length, directory)) {
        return 0;
    }
    if (length > 0 && output[length - 1] != L'\\' &&
        !append_char(output, capacity, &length, L'\\')) {
        return 0;
    }
    return append_text(output, capacity, &length, leaf);
}

static int build_runtime_paths(wchar_t *root, wchar_t *work,
                               wchar_t *cache, wchar_t *log,
                               wchar_t *script)
{
    wchar_t program_data[PATH_CAP];

    if (SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL,
                         SHGFP_TYPE_CURRENT, program_data) != S_OK ||
        !join_path(root, PATH_CAP, program_data, L"VMateDnfDeps") ||
        !join_path(work, PATH_CAP, root, L"payload") ||
        !join_path(cache, PATH_CAP, root, L"cache") ||
        !join_path(log, PATH_CAP, root, L"install.log") ||
        !join_path(script, PATH_CAP, work, L"dnf-fix-deps.ps1")) {
        fwprintf(stderr, L"无法生成受保护的运行目录。\n");
        return 0;
    }
    return 1;
}

static int find_powershell(wchar_t *output, size_t capacity)
{
    wchar_t system_directory[PATH_CAP];
    DWORD attributes;
    UINT count;

    count = GetSystemDirectoryW(system_directory,
                                (UINT)ARRAY_LEN(system_directory));
    if (count == 0 || count >= ARRAY_LEN(system_directory) ||
        !join_path(output, capacity, system_directory,
                   L"WindowsPowerShell\\v1.0\\powershell.exe")) {
        fwprintf(stderr, L"无法生成 System32 PowerShell 路径。\n");
        return 0;
    }
    attributes = GetFileAttributesW(output);
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        fwprintf(stderr, L"System32 PowerShell 不存在或路径不安全。\n");
        return 0;
    }
    return 1;
}

static int is_admin(void)
{
    BOOL member = FALSE;
    PSID group = NULL;
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;

    if (!AllocateAndInitializeSid(
            &authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
            DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0, &group)) {
        return 0;
    }
    if (!CheckTokenMembership(NULL, group, &member)) {
        member = FALSE;
    }
    FreeSid(group);
    return member ? 1 : 0;
}

static int elevate_self(int count, wchar_t **arguments)
{
    wchar_t executable[PATH_CAP];
    wchar_t parameters[COMMAND_CAP];
    SHELLEXECUTEINFOW execute_info;
    DWORD executable_length;
    DWORD code = 1;
    size_t length = 0;
    int index;

    executable_length = GetModuleFileNameW(
        NULL, executable, (DWORD)ARRAY_LEN(executable));
    if (executable_length == 0 ||
        executable_length >= ARRAY_LEN(executable)) {
        fwprintf(stderr, L"无法定位当前 EXE，错误=%lu。\n", GetLastError());
        return 1;
    }
    parameters[0] = L'\0';
    for (index = 1; index < count; index++) {
        if (!append_quoted_arg(parameters, ARRAY_LEN(parameters), &length,
                               arguments[index])) {
            fwprintf(stderr, L"参数过长，无法提权重启。\n");
            return 1;
        }
    }

    ZeroMemory(&execute_info, sizeof(execute_info));
    execute_info.cbSize = sizeof(execute_info);
    execute_info.fMask = SEE_MASK_NOCLOSEPROCESS;
    execute_info.lpVerb = L"runas";
    execute_info.lpFile = executable;
    execute_info.lpParameters = parameters;
    execute_info.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&execute_info)) {
        return GetLastError() == ERROR_CANCELLED ? ERROR_CANCELLED : 1;
    }
    WaitForSingleObject(execute_info.hProcess, INFINITE);
    if (!GetExitCodeProcess(execute_info.hProcess, &code)) {
        code = 1;
    }
    CloseHandle(execute_info.hProcess);
    return (int)code;
}

static int confirm_install(void)
{
    int answer = MessageBoxW(
        NULL,
        L"dnf-fix-deps 将检测 Microsoft VC++ 2010、2013、"
        L"2015-2022（x86/x64）和 DirectX 9 运行库。非 DryRun 模式会"
        L"联网下载并静默安装缺失项。\n\n安装器不会自动重启 Windows。"
        L"是否继续？",
        L"DNF Microsoft 运行库安装确认",
        MB_ICONWARNING | MB_YESNO | MB_DEFBUTTON2 | MB_SETFOREGROUND);

    return answer == IDYES;
}

static int run_powershell(int count, wchar_t **arguments,
                          const wchar_t *root, const wchar_t *work,
                          const wchar_t *cache, const wchar_t *log,
                          const wchar_t *script)
{
    wchar_t powershell[PATH_CAP];
    wchar_t command[COMMAND_CAP];
    wchar_t *environment = NULL;
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD code = 1;
    size_t length = 0;
    int index;

    if (!find_powershell(powershell, ARRAY_LEN(powershell))) {
        return 1;
    }
    command[0] = L'\0';
    if (!append_quoted_arg(command, ARRAY_LEN(command), &length, powershell) ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length, L"-NoLogo") ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length,
                           L"-NoProfile") ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length,
                           L"-NonInteractive") ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length,
                           L"-ExecutionPolicy") ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length, L"Bypass") ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length, L"-File") ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length, script) ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length,
                           L"-LauncherMode") ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length,
                           L"-CacheDir") ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length, cache) ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length,
                           L"-LogPath") ||
        !append_quoted_arg(command, ARRAY_LEN(command), &length, log)) {
        fwprintf(stderr, L"PowerShell 命令行过长。\n");
        return 1;
    }
    for (index = 1; index < count; index++) {
        const wchar_t *forward = dnf_arg_forward_value(arguments[index]);

        if (forward != NULL &&
            !append_quoted_arg(command, ARRAY_LEN(command), &length,
                               forward)) {
            fwprintf(stderr, L"PowerShell 参数过长。\n");
            return 1;
        }
    }

    environment = payload_build_environment(root, work);
    if (environment == NULL) {
        return 1;
    }
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    if (!CreateProcessW(powershell, command, NULL, NULL, FALSE,
                        CREATE_UNICODE_ENVIRONMENT, environment, work,
                        &startup, &process)) {
        fwprintf(stderr, L"启动 PowerShell 失败，错误=%lu。\n",
                 GetLastError());
        payload_free_environment(environment);
        return 1;
    }
    payload_free_environment(environment);
    WaitForSingleObject(process.hProcess, INFINITE);
    if (!GetExitCodeProcess(process.hProcess, &code)) {
        code = 1;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return (int)code;
}

static void show_result(int code, const wchar_t *log_path)
{
    wchar_t message[PATH_CAP + 128];

    if (code == 0 || code == ERROR_SUCCESS_REBOOT_REQUIRED) {
        const wchar_t *result = code == ERROR_SUCCESS_REBOOT_REQUIRED ?
            L"Microsoft 运行库安装完成；请重启 Windows 后再启动 DNF。" :
            L"Microsoft 运行库检测/安装完成。";

        swprintf(message, ARRAY_LEN(message),
                 L"%ls\n\n日志：%ls", result, log_path);
        MessageBoxW(NULL, message, L"dnf-fix-deps 完成",
                    MB_ICONINFORMATION | MB_OK);
        return;
    }
    swprintf(message, ARRAY_LEN(message),
             L"运行库安装未完成，退出码=%d。\n\n请查看日志：%ls",
             code, log_path);
    MessageBoxW(NULL, message, L"dnf-fix-deps 失败",
                MB_ICONERROR | MB_OK);
}

int wmain(int count, wchar_t **arguments)
{
    wchar_t root[PATH_CAP];
    wchar_t work[PATH_CAP];
    wchar_t cache[PATH_CAP];
    wchar_t log[PATH_CAP];
    wchar_t script[PATH_CAP];
    HANDLE lock = INVALID_HANDLE_VALUE;
    int skip_confirmation;
    int code = 1;

    SetConsoleOutputCP(CP_UTF8);
    if (!dnf_args_valid(count, arguments)) {
        fwprintf(stderr,
                 L"用法：dnf-fix-deps.exe [--dry-run] [--no-confirm]\n");
        return ERROR_INVALID_PARAMETER;
    }
    skip_confirmation = dnf_args_skip_confirmation(count, arguments);
    if (!is_admin()) {
        return elevate_self(count, arguments);
    }
    if (!skip_confirmation && !confirm_install()) {
        return ERROR_CANCELLED;
    }
    if (!build_runtime_paths(root, work, cache, log, script)) {
        if (!skip_confirmation) {
            MessageBoxW(NULL, L"无法定位 Windows ProgramData 运行目录。",
                        L"dnf-fix-deps 启动失败", MB_ICONERROR | MB_OK);
        }
        return 1;
    }
    if (!payload_secure_directory(root) ||
        !payload_secure_directory(cache)) {
        if (!skip_confirmation) {
            show_result(1, log);
        }
        return 1;
    }
    lock = payload_acquire_lock(root);
    if (lock == INVALID_HANDLE_VALUE) {
        DWORD lock_error = GetLastError();

        code = lock_error == ERROR_SHARING_VIOLATION ||
               lock_error == ERROR_LOCK_VIOLATION ?
               ERROR_INSTALL_ALREADY_RUNNING : 1;
        if (!skip_confirmation) {
            show_result(code, log);
        }
        return code;
    }
    if (!payload_publish_bundle(root, work, embedded_payloads,
                                ARRAY_LEN(embedded_payloads)) ||
        !SetCurrentDirectoryW(work)) {
        goto cleanup;
    }
    code = run_powershell(count, arguments, root, work, cache, log, script);

cleanup:
    /*
     * PowerShell 运行时 cwd 指向即将被下一实例替换的 work。先切回稳定根目录，
     * 并让结果框也处于独占锁保护期，避免第二实例在本进程结束前发布新 payload。
     */
    (void)SetCurrentDirectoryW(root);
    if (!skip_confirmation) {
        show_result(code, log);
    }
    CloseHandle(lock);
    return code;
}
