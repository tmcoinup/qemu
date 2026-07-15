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

wchar_t *payload_build_environment(const wchar_t *root_dir,
                                   const wchar_t *work_dir)
{
    wchar_t windows_dir[ENV_PATH_CAP];
    wchar_t system_dir[ENV_PATH_CAP];
    wchar_t program_data[ENV_PATH_CAP];
    wchar_t command_processor[ENV_PATH_CAP];
    wchar_t module_path[ENV_PATH_CAP];
    wchar_t safe_path[ENV_PATH_CAP];
    wchar_t system_drive[3] = L"C:";
    wchar_t *environment;
    size_t length = 0;
    UINT windows_count;
    UINT system_count;

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
