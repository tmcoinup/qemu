#ifndef UNICODE
#define UNICODE
#endif

#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdint.h>
#include <wchar.h>

#include "payload_respawn_ps1.h"
#include "payload_apply_gpu_spoof_ps1.h"

#ifndef ARRAY_LEN
#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))
#endif

#define PATH_BUF_LEN 4096
#define CMD_BUF_LEN 32760

static int append_char(wchar_t *buf, size_t cap, size_t *len, wchar_t ch)
{
    if (*len + 1 >= cap) {
        return 0;
    }
    buf[*len] = ch;
    (*len)++;
    buf[*len] = L'\0';
    return 1;
}

static int append_text(wchar_t *buf, size_t cap, size_t *len, const wchar_t *text)
{
    while (*text) {
        if (!append_char(buf, cap, len, *text)) {
            return 0;
        }
        text++;
    }
    return 1;
}

static int append_backslashes(wchar_t *buf, size_t cap, size_t *len, size_t count)
{
    while (count > 0) {
        if (!append_char(buf, cap, len, L'\\')) {
            return 0;
        }
        count--;
    }
    return 1;
}

static int append_quoted_arg(wchar_t *buf, size_t cap, size_t *len, const wchar_t *arg)
{
    int need_quote = (*arg == L'\0') || (wcspbrk(arg, L" \t\r\n\v\"") != NULL);
    size_t slashes = 0;

    if (*len > 0 && !append_char(buf, cap, len, L' ')) {
        return 0;
    }

    if (!need_quote) {
        return append_text(buf, cap, len, arg);
    }

    if (!append_char(buf, cap, len, L'"')) {
        return 0;
    }

    /*
     * Windows 命令行没有 argv 数组，CreateProcess 只接收一整串命令行。
     * 这里按 CommandLineToArgvW 兼容规则转义：引号前的反斜杠翻倍，
     * 末尾闭合引号前的反斜杠也翻倍，避免路径以反斜杠结尾时吃掉引号。
     */
    while (*arg) {
        if (*arg == L'\\') {
            slashes++;
            arg++;
            continue;
        }
        if (*arg == L'"') {
            if (!append_backslashes(buf, cap, len, slashes * 2 + 1) ||
                !append_char(buf, cap, len, L'"')) {
                return 0;
            }
            slashes = 0;
            arg++;
            continue;
        }
        if (!append_backslashes(buf, cap, len, slashes) ||
            !append_char(buf, cap, len, *arg)) {
            return 0;
        }
        slashes = 0;
        arg++;
    }

    if (!append_backslashes(buf, cap, len, slashes * 2) ||
        !append_char(buf, cap, len, L'"')) {
        return 0;
    }
    return 1;
}

static int is_admin(void)
{
    BOOL ok = FALSE;
    PSID group = NULL;
    SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;

    if (!AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                  DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                  &group)) {
        return 0;
    }

    if (!CheckTokenMembership(NULL, group, &ok)) {
        ok = FALSE;
    }
    FreeSid(group);
    return ok ? 1 : 0;
}

static int confirm_admin_run(void)
{
    int answer;

    /*
     * 中文注释：Win10 guest 常用内置 Administrator 自动登录。该账号默认直接
     * 拿完整管理员 token，Windows 不会再弹 UAC consent prompt。这里额外
     * 做应用层确认，保证用户双击时一定看到“即将修改系统”的确认弹窗。
     */
    answer = MessageBoxW(
        NULL,
        L"respawn-stealth 将以管理员权限修改 HKLM 注册表、PnP 显卡信息和计划任务，"
        L"完成后默认会重启。\n\n是否继续？",
        L"respawn-stealth 管理员确认",
        MB_ICONWARNING | MB_YESNO | MB_DEFBUTTON2 | MB_SETFOREGROUND);

    return answer == IDYES;
}

static wchar_t ascii_lower(wchar_t ch)
{
    if (ch >= L'A' && ch <= L'Z') {
        return ch + (L'a' - L'A');
    }
    return ch;
}

static int arg_equals_ci(const wchar_t *arg, const wchar_t *expected)
{
    while (*arg && *expected) {
        if (ascii_lower(*arg) != ascii_lower(*expected)) {
            return 0;
        }
        arg++;
        expected++;
    }
    return *arg == L'\0' && *expected == L'\0';
}

static int is_launcher_arg(const wchar_t *arg)
{
    return arg_equals_ci(arg, L"--firstlogon") ||
           arg_equals_ci(arg, L"-firstlogon") ||
           arg_equals_ci(arg, L"/firstlogon") ||
           arg_equals_ci(arg, L"--no-confirm") ||
           arg_equals_ci(arg, L"-no-confirm") ||
           arg_equals_ci(arg, L"/no-confirm") ||
           arg_equals_ci(arg, L"--auto") ||
           arg_equals_ci(arg, L"-auto") ||
           arg_equals_ci(arg, L"/auto");
}

static int has_launcher_autorun_arg(int argc, wchar_t **argv)
{
    for (int i = 1; i < argc; i++) {
        if (is_launcher_arg(argv[i])) {
            return 1;
        }
    }
    return 0;
}

static int elevate_self(int argc, wchar_t **argv)
{
    wchar_t exe[PATH_BUF_LEN];
    wchar_t params[CMD_BUF_LEN];
    size_t len = 0;
    SHELLEXECUTEINFOW sei;
    DWORD code = 1;

    if (!GetModuleFileNameW(NULL, exe, (DWORD)ARRAY_LEN(exe))) {
        fwprintf(stderr, L"无法定位当前 EXE，错误=%lu\n", GetLastError());
        return 1;
    }

    params[0] = L'\0';
    for (int i = 1; i < argc; i++) {
        if (!append_quoted_arg(params, ARRAY_LEN(params), &len, argv[i])) {
            fwprintf(stderr, L"参数过长，无法提权重启。\n");
            return 1;
        }
    }

    /*
     * manifest 已要求 requireAdministrator。这个分支是防御兜底：
     * 如果 manifest 被剥离或测试环境绕过，仍用 runas 主动弹 UAC。
     */
    ZeroMemory(&sei, sizeof(sei));
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = exe;
    sei.lpParameters = params;
    sei.nShow = SW_SHOWNORMAL;

    if (!ShellExecuteExW(&sei)) {
        fwprintf(stderr, L"UAC 提权启动失败，错误=%lu\n", GetLastError());
        return 1;
    }

    WaitForSingleObject(sei.hProcess, INFINITE);
    if (!GetExitCodeProcess(sei.hProcess, &code)) {
        code = 1;
    }
    CloseHandle(sei.hProcess);
    return (int)code;
}

static int ensure_dir(const wchar_t *path)
{
    if (CreateDirectoryW(path, NULL)) {
        return 1;
    }
    return GetLastError() == ERROR_ALREADY_EXISTS;
}

static int build_work_dir(wchar_t *out, size_t cap)
{
    wchar_t program_data[PATH_BUF_LEN];
    DWORD n = GetEnvironmentVariableW(L"ProgramData", program_data,
                                      (DWORD)ARRAY_LEN(program_data));
    size_t len = 0;

    if (n == 0 || n >= ARRAY_LEN(program_data)) {
        wcscpy(program_data, L"C:\\ProgramData");
    }

    out[0] = L'\0';
    if (!append_text(out, cap, &len, program_data)) {
        return 0;
    }
    if (len > 0 && out[len - 1] != L'\\' && !append_char(out, cap, &len, L'\\')) {
        return 0;
    }
    return append_text(out, cap, &len, L"StealthGPU\\respawn-exe");
}

static int join_path(wchar_t *out, size_t cap, const wchar_t *dir, const wchar_t *name)
{
    size_t len = 0;

    out[0] = L'\0';
    if (!append_text(out, cap, &len, dir)) {
        return 0;
    }
    if (len > 0 && out[len - 1] != L'\\' && !append_char(out, cap, &len, L'\\')) {
        return 0;
    }
    return append_text(out, cap, &len, name);
}

static int write_payload(const wchar_t *path, const unsigned char *data, unsigned int len)
{
    HANDLE file;
    DWORD written = 0;

    file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        fwprintf(stderr, L"写入 payload 失败: %ls，错误=%lu\n", path, GetLastError());
        return 0;
    }

    if (!WriteFile(file, data, (DWORD)len, &written, NULL) || written != len) {
        fwprintf(stderr, L"payload 写入不完整: %ls，错误=%lu\n", path, GetLastError());
        CloseHandle(file);
        return 0;
    }

    CloseHandle(file);
    return 1;
}

static void find_powershell(wchar_t *out, size_t cap)
{
    wchar_t sysdir[PATH_BUF_LEN];
    size_t len = 0;

    out[0] = L'\0';
    if (GetSystemDirectoryW(sysdir, (UINT)ARRAY_LEN(sysdir)) > 0) {
        append_text(out, cap, &len, sysdir);
        if (len > 0 && out[len - 1] != L'\\') {
            append_char(out, cap, &len, L'\\');
        }
        append_text(out, cap, &len, L"WindowsPowerShell\\v1.0\\powershell.exe");
        if (GetFileAttributesW(out) != INVALID_FILE_ATTRIBUTES) {
            return;
        }
    }

    wcscpy(out, L"powershell.exe");
}

static int run_payload(int argc, wchar_t **argv, const wchar_t *work_dir,
                       const wchar_t *script_path, int firstlogon)
{
    wchar_t powershell[PATH_BUF_LEN];
    wchar_t cmd[CMD_BUF_LEN];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    size_t len = 0;

    find_powershell(powershell, ARRAY_LEN(powershell));

    cmd[0] = L'\0';
    if (!append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, powershell) ||
        !append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, L"-NoProfile") ||
        !append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, L"-ExecutionPolicy") ||
        !append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, L"Bypass") ||
        !append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, L"-File") ||
        !append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, script_path)) {
        fwprintf(stderr, L"PowerShell 命令行过长。\n");
        return 1;
    }

    if (firstlogon &&
        !append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, L"-FirstLogon")) {
        fwprintf(stderr, L"PowerShell FirstLogon 参数过长。\n");
        return 1;
    }

    for (int i = 1; i < argc; i++) {
        if (is_launcher_arg(argv[i])) {
            continue;
        }
        if (!append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, argv[i])) {
            fwprintf(stderr, L"PowerShell 参数过长。\n");
            return 1;
        }
    }

    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);

    /*
     * 不隐藏窗口：脚本会打印进度、失败原因和日志路径。等待子进程结束，
     * 这样调用者能拿到真实退出码，bat/调试终端也不会提前返回。
     */
    if (!CreateProcessW(powershell, cmd, NULL, NULL, FALSE, 0, NULL, work_dir,
                        &si, &pi)) {
        fwprintf(stderr, L"启动 PowerShell 失败，错误=%lu\n", GetLastError());
        return 1;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    if (!GetExitCodeProcess(pi.hProcess, &code)) {
        code = 1;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}

int wmain(int argc, wchar_t **argv)
{
    wchar_t work_dir[PATH_BUF_LEN];
    wchar_t root_dir[PATH_BUF_LEN];
    wchar_t respawn_path[PATH_BUF_LEN];
    wchar_t spoof_path[PATH_BUF_LEN];
    int autorun = 0;

    SetConsoleOutputCP(CP_UTF8);
    autorun = has_launcher_autorun_arg(argc, argv);

    if (!is_admin()) {
        return elevate_self(argc, argv);
    }

    /*
     * 中文注释：FirstLogonCommands 需要无人值守执行，不能被确认弹窗卡住；
     * 但普通用户手动双击仍保留确认框，避免误改 HKLM / PnP / 计划任务。
     */
    if (!autorun && !confirm_admin_run()) {
        fwprintf(stderr, L"用户取消，未执行任何修改。\n");
        return 1223; /* ERROR_CANCELLED */
    }

    if (!build_work_dir(work_dir, ARRAY_LEN(work_dir)) ||
        !build_work_dir(root_dir, ARRAY_LEN(root_dir))) {
        fwprintf(stderr, L"生成工作目录路径失败。\n");
        return 1;
    }

    /*
     * EXE 是唯一需要拷进 guest 的文件。运行时把内嵌脚本释放到 ProgramData，
     * 并始终覆盖旧副本，确保重新打包后的硬件池映射立即生效。
     */
    {
        wchar_t *last_slash = wcsrchr(root_dir, L'\\');
        if (last_slash) {
            *last_slash = L'\0';
        }
    }

    if (!ensure_dir(root_dir) || !ensure_dir(work_dir)) {
        fwprintf(stderr, L"创建工作目录失败: %ls，错误=%lu\n", work_dir, GetLastError());
        return 1;
    }

    if (!join_path(respawn_path, ARRAY_LEN(respawn_path), work_dir,
                   L"respawn-stealth-local.ps1") ||
        !join_path(spoof_path, ARRAY_LEN(spoof_path), work_dir,
                   L"apply-gpu-spoof.ps1")) {
        fwprintf(stderr, L"生成 payload 文件路径失败。\n");
        return 1;
    }

    if (!write_payload(respawn_path, payload_respawn_ps1, payload_respawn_ps1_len) ||
        !write_payload(spoof_path, payload_apply_gpu_spoof_ps1,
                       payload_apply_gpu_spoof_ps1_len)) {
        return 1;
    }

    SetCurrentDirectoryW(work_dir);
    return run_payload(argc, argv, work_dir, respawn_path, autorun);
}
