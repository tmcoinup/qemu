#ifndef UNICODE
#define UNICODE
#endif

#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#include "payload-environment.h"

#define ENV_CAP 32767
#define ENV_PATH_CAP 4096

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

static int append_entry(wchar_t *buffer, size_t capacity, size_t *length,
                        const wchar_t *name, const wchar_t *value)
{
    return append_text(buffer, capacity, length, name) &&
           append_char(buffer, capacity, length, L'=') &&
           append_text(buffer, capacity, length, value) &&
           append_char(buffer, capacity, length, L'\0');
}

static int get_program_data(const wchar_t *root_dir, wchar_t *output,
                            size_t capacity)
{
    size_t length = wcslen(root_dir);
    wchar_t *separator;

    if (length == 0 || length >= capacity) {
        return 0;
    }
    memcpy(output, root_dir, (length + 1) * sizeof(wchar_t));
    separator = wcsrchr(output, L'\\');
    if (separator == NULL || separator == output) {
        return 0;
    }
    *separator = L'\0';
    return 1;
}

static int format_paths(const wchar_t *windows_dir,
                        const wchar_t *system_dir,
                        wchar_t *command_processor,
                        wchar_t *module_path,
                        wchar_t *safe_path)
{
    int command_count = swprintf(command_processor, ENV_PATH_CAP,
                                 L"%ls\\cmd.exe", system_dir);
    int module_count = swprintf(
        module_path, ENV_PATH_CAP,
        L"%ls\\WindowsPowerShell\\v1.0\\Modules", system_dir);
    int path_count = swprintf(
        safe_path, ENV_PATH_CAP,
        L"%ls;%ls;%ls\\Wbem;%ls\\WindowsPowerShell\\v1.0",
        system_dir, windows_dir, system_dir, system_dir);

    return command_count > 0 && command_count < ENV_PATH_CAP &&
           module_count > 0 && module_count < ENV_PATH_CAP &&
           path_count > 0 && path_count < ENV_PATH_CAP;
}

static int get_token_identity(wchar_t *user_name, DWORD user_capacity,
                              wchar_t *user_domain, DWORD domain_capacity)
{
    HANDLE token = NULL;
    TOKEN_USER *token_user = NULL;
    DWORD token_user_size = 0;
    DWORD user_length = user_capacity;
    DWORD domain_length = domain_capacity;
    SID_NAME_USE sid_type;
    int success = 0;

    /*
     * 不能从提权前的环境继承 USERNAME/USERDOMAIN。直接解析当前进程 token，
     * 保证传给 PowerShell 和 shutdown.exe 的身份字段与实际管理员主体一致。
     */
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        goto cleanup;
    }
    if (GetTokenInformation(token, TokenUser, NULL, 0, &token_user_size) ||
        GetLastError() != ERROR_INSUFFICIENT_BUFFER ||
        token_user_size == 0) {
        goto cleanup;
    }
    token_user = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
                           token_user_size);
    if (token_user == NULL ||
        !GetTokenInformation(token, TokenUser, token_user, token_user_size,
                             &token_user_size) ||
        !LookupAccountSidW(NULL, token_user->User.Sid, user_name,
                           &user_length, user_domain, &domain_length,
                           &sid_type) ||
        user_name[0] == L'\0' || user_domain[0] == L'\0') {
        goto cleanup;
    }
    success = 1;

cleanup:
    if (token_user != NULL) {
        HeapFree(GetProcessHeap(), 0, token_user);
    }
    if (token != NULL) {
        CloseHandle(token);
    }
    return success;
}

wchar_t *payload_build_environment(const wchar_t *root_dir,
                                   const wchar_t *work_dir)
{
    wchar_t windows_dir[ENV_PATH_CAP];
    wchar_t system_dir[ENV_PATH_CAP];
    wchar_t computer_name[ENV_PATH_CAP];
    wchar_t user_name[ENV_PATH_CAP];
    wchar_t user_domain[ENV_PATH_CAP];
    wchar_t program_data[ENV_PATH_CAP];
    wchar_t command_processor[ENV_PATH_CAP];
    wchar_t module_path[ENV_PATH_CAP];
    wchar_t safe_path[ENV_PATH_CAP];
    wchar_t system_drive[3] = L"C:";
    wchar_t *environment;
    size_t length = 0;
    UINT windows_count;
    UINT system_count;
    DWORD computer_count = ENV_PATH_CAP;

    windows_count = GetWindowsDirectoryW(windows_dir, ENV_PATH_CAP);
    system_count = GetSystemDirectoryW(system_dir, ENV_PATH_CAP);
    if (windows_count == 0 || windows_count >= ENV_PATH_CAP ||
        system_count == 0 || system_count >= ENV_PATH_CAP ||
        !get_program_data(root_dir, program_data, ENV_PATH_CAP) ||
        !format_paths(windows_dir, system_dir, command_processor,
                      module_path, safe_path)) {
        fwprintf(stderr, L"无法构造管理员 PowerShell 的可信系统路径。\n");
        return NULL;
    }
    if (!GetComputerNameW(computer_name, &computer_count) ||
        computer_count == 0 ||
        !get_token_identity(user_name, ENV_PATH_CAP,
                            user_domain, ENV_PATH_CAP)) {
        fwprintf(stderr, L"无法构造管理员 PowerShell 的可信系统身份。\n");
        return NULL;
    }
    if (windows_dir[1] == L':') {
        system_drive[0] = windows_dir[0];
    }

    environment = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
                            ENV_CAP * sizeof(wchar_t));
    if (environment == NULL) {
        fwprintf(stderr, L"分配管理员 PowerShell 环境块失败。\n");
        return NULL;
    }

    /*
     * 环境项按名称排序，并以额外 NUL 结束。刻意不继承调用用户的 APPDATA、
     * PATH、PSModulePath、COMPLUS_*、COR_* 等变量，避免 UAC 后的原生命令、
     * PowerShell 自动模块或 .NET profiler 从用户可写目录进入管理员进程。
     */
    if (!append_entry(environment, ENV_CAP, &length,
                      L"ALLUSERSPROFILE", program_data) ||
        !append_entry(environment, ENV_CAP, &length,
                      L"COMPUTERNAME", computer_name) ||
        !append_entry(environment, ENV_CAP, &length,
                      L"COMSPEC", command_processor) ||
        !append_entry(environment, ENV_CAP, &length, L"OS", L"Windows_NT") ||
        !append_entry(environment, ENV_CAP, &length, L"PATH", safe_path) ||
        !append_entry(environment, ENV_CAP, &length, L"PATHEXT",
                      L".COM;.EXE;.BAT;.CMD") ||
        !append_entry(environment, ENV_CAP, &length,
                      L"PROCESSOR_ARCHITECTURE", L"AMD64") ||
        !append_entry(environment, ENV_CAP, &length,
                      L"PROGRAMDATA", program_data) ||
        !append_entry(environment, ENV_CAP, &length,
                      L"PSModulePath", module_path) ||
        !append_entry(environment, ENV_CAP, &length,
                      L"SystemDrive", system_drive) ||
        !append_entry(environment, ENV_CAP, &length,
                      L"SystemRoot", windows_dir) ||
        !append_entry(environment, ENV_CAP, &length, L"TEMP", work_dir) ||
        !append_entry(environment, ENV_CAP, &length, L"TMP", work_dir) ||
        !append_entry(environment, ENV_CAP, &length,
                      L"USERDOMAIN", user_domain) ||
        !append_entry(environment, ENV_CAP, &length,
                      L"USERNAME", user_name) ||
        !append_entry(environment, ENV_CAP, &length, L"WINDIR", windows_dir) ||
        !append_char(environment, ENV_CAP, &length, L'\0')) {
        fwprintf(stderr, L"管理员 PowerShell 环境块超过 Windows 上限。\n");
        payload_free_environment(environment);
        return NULL;
    }
    return environment;
}

void payload_free_environment(wchar_t *environment)
{
    if (environment != NULL) {
        HeapFree(GetProcessHeap(), 0, environment);
    }
}
