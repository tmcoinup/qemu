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
#include <stdint.h>
#include <wchar.h>
#include "payload-environment.h"
#include "payload-security.h"
#include "launcher-arguments.h"
#include "respawn-stealth-payloads.h"
#ifdef RESPAWN_PROGRESS_ONLY
#include "progress-only-ui.h"
#endif
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

#ifndef RESPAWN_PROGRESS_ONLY
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
        L"respawn-stealth 将以管理员权限把屏幕/睡眠设为“从不”、安装或检查"
        L"芯片组识别 INF 与显示驱动，并修改 HKLM 注册表、PnP 显卡信息和计划任务，"
        L"完成后默认会重启。\n\n是否继续？",
        L"respawn-stealth 管理员确认",
        MB_ICONWARNING | MB_YESNO | MB_DEFBUTTON2 | MB_SETFOREGROUND);

    return answer == IDYES;
}
#endif

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

static int build_work_dir(wchar_t *out, size_t cap)
{
    wchar_t program_data[PATH_BUF_LEN];
    size_t len = 0;

    /*
     * 中文注释：提权进程不能信任调用用户继承的 ProgramData 环境变量，否则用户可在
     * UAC 前把管理员 payload 引向自选目录。CSIDL_COMMON_APPDATA 由 Windows shell
     * 解析真实公共数据目录；查询失败时直接停止，不使用字符串默认值掩盖异常。
     */
    if (SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL,
                         SHGFP_TYPE_CURRENT, program_data) != S_OK) {
        fwprintf(stderr, L"无法查询 Windows 公共应用数据目录。\n");
        return 0;
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

static int find_powershell(wchar_t *out, size_t cap)
{
    wchar_t sysdir[PATH_BUF_LEN];
    DWORD attributes;
    UINT count;
    size_t len = 0;

    out[0] = L'\0';
    count = GetSystemDirectoryW(sysdir, (UINT)ARRAY_LEN(sysdir));
    if (count == 0 || count >= ARRAY_LEN(sysdir) ||
        !append_text(out, cap, &len, sysdir) ||
        (len > 0 && out[len - 1] != L'\\' &&
         !append_char(out, cap, &len, L'\\')) ||
        !append_text(out, cap, &len,
                     L"WindowsPowerShell\\v1.0\\powershell.exe")) {
        fwprintf(stderr, L"无法生成 System32 Windows PowerShell 路径。\n");
        return 0;
    }
    attributes = GetFileAttributesW(out);
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        /* 不能回退到裸 powershell.exe，否则当前目录或继承 PATH 可劫持提权执行。 */
        fwprintf(stderr, L"System32 Windows PowerShell 不存在或路径不安全: %ls\n",
                 out);
        return 0;
    }
    return 1;
}

static int run_payload(int argc, wchar_t **argv, const wchar_t *work_dir,
                       const wchar_t *root_dir, const wchar_t *script_path,
                       int autorun, int firstlogon)
{
    wchar_t powershell[PATH_BUF_LEN];
    wchar_t cmd[CMD_BUF_LEN];
#ifndef RESPAWN_PROGRESS_ONLY
    STARTUPINFOW si;
#endif
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    size_t len = 0;
    wchar_t *environment = NULL;

#ifdef RESPAWN_PROGRESS_ONLY
    (void)autorun;
#endif

    if (!find_powershell(powershell, ARRAY_LEN(powershell))) {
        return 1;
    }

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

#ifdef RESPAWN_PROGRESS_ONLY
    if (!append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, L"-Unattended")) {
        fwprintf(stderr, L"PowerShell Unattended 参数过长。\n");
        return 1;
    }
#else
    if (autorun &&
        !append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, L"-Unattended")) {
        fwprintf(stderr, L"PowerShell Unattended 参数过长。\n");
        return 1;
    }
#endif
    if (firstlogon &&
        !append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, L"-FirstLogon")) {
        fwprintf(stderr, L"PowerShell FirstLogon 参数过长。\n");
        return 1;
    }

    for (int i = 1; i < argc; i++) {
        if (launcher_arg_is_control(argv[i])) {
            continue;
        }
        if (!append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, argv[i])) {
            fwprintf(stderr, L"PowerShell 参数过长。\n");
            return 1;
        }
    }

#ifndef RESPAWN_PROGRESS_ONLY
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
#endif
    ZeroMemory(&pi, sizeof(pi));

    environment = payload_build_environment(root_dir, work_dir);
    if (environment == NULL) {
        return 1;
    }

#ifdef RESPAWN_PROGRESS_ONLY
    /*
     * 仅进度版由独立 GUI 展示运行状态；PowerShell 的标准句柄固定到 NUL，
     * 同时禁止创建控制台。脚本自己的受保护日志仍会保留，便于事后诊断。
     */
    progress_only_ui_set_running();
    if (!progress_only_create_process(
            powershell, cmd, environment, work_dir, &pi)) {
#else
    /*
     * 原版不隐藏窗口：脚本会打印进度、失败原因和日志路径。等待子进程结束，
     * 这样调用者能拿到真实退出码，bat/调试终端也不会提前返回。
     */
    if (!CreateProcessW(powershell, cmd, NULL, NULL, FALSE,
                        CREATE_UNICODE_ENVIRONMENT, environment, work_dir,
                        &si, &pi)) {
#endif
        fwprintf(stderr, L"启动 PowerShell 失败，错误=%lu\n", GetLastError());
        payload_free_environment(environment);
        return 1;
    }
    payload_free_environment(environment);

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
    HANDLE payload_lock = INVALID_HANDLE_VALUE;
    int code = 1;
    int autorun = 0;
    int firstlogon = 0;

    SetConsoleOutputCP(CP_UTF8);
    autorun = launcher_args_request_autorun(argc, argv);
    firstlogon = launcher_args_request_firstlogon(argc, argv);

    if (!is_admin()) {
        return elevate_self(argc, argv);
    }

#ifdef RESPAWN_PROGRESS_ONLY
    if (!progress_only_ui_start()) {
        return 1;
    }
#endif

    /*
     * 中文注释：FirstLogonCommands 需要无人值守执行，不能被确认弹窗卡住；
     * 但普通用户手动双击仍保留确认框，避免误改 HKLM / PnP / 计划任务。
     */
#ifndef RESPAWN_PROGRESS_ONLY
    if (!autorun && !confirm_admin_run()) {
        fwprintf(stderr, L"用户取消，未执行任何修改。\n");
        return 1223; /* ERROR_CANCELLED */
    }
#endif

    if (!build_work_dir(work_dir, ARRAY_LEN(work_dir)) ||
        !build_work_dir(root_dir, ARRAY_LEN(root_dir))) {
        fwprintf(stderr, L"生成工作目录路径失败。\n");
#ifdef RESPAWN_PROGRESS_ONLY
        progress_only_ui_finish(0);
#endif
        return 1;
    }

    /*
     * 用户选中的 EXE 是唯一需要拷进 guest 的文件。运行时把内嵌脚本释放到 ProgramData，
     * 并始终覆盖旧副本，确保重新打包后的硬件池映射立即生效。
     */
    {
        wchar_t *last_slash = wcsrchr(root_dir, L'\\');
        if (last_slash) {
            *last_slash = L'\0';
        }
    }

    if (!payload_secure_directory(root_dir)) {
        fwprintf(stderr, L"创建或保护 payload 根目录失败: %ls\n", root_dir);
#ifdef RESPAWN_PROGRESS_ONLY
        progress_only_ui_finish(0);
#endif
        return 1;
    }

    payload_lock = payload_acquire_lock(root_dir);
    if (payload_lock == INVALID_HANDLE_VALUE) {
        DWORD lock_error = GetLastError();
#ifndef RESPAWN_PROGRESS_ONLY
        if (!autorun) {
            MessageBoxW(NULL, lock_error == ERROR_SHARING_VIOLATION || lock_error == ERROR_LOCK_VIOLATION ? L"已有一次自动或手动初始化正在运行，请等待其完成。" : L"无法锁定初始化目录；请检查权限、重解析点与日志。",
                        L"respawn-stealth 启动失败", MB_ICONINFORMATION | MB_OK);
        }
#endif
#ifdef RESPAWN_PROGRESS_ONLY
        progress_only_ui_finish(0);
#endif
        return lock_error == ERROR_SHARING_VIOLATION || lock_error == ERROR_LOCK_VIOLATION ? ERROR_INSTALL_ALREADY_RUNNING : 1;
    }

    if (!join_path(respawn_path, ARRAY_LEN(respawn_path), work_dir,
                   L"respawn-stealth-local.ps1")) {
        fwprintf(stderr, L"生成 payload 文件路径失败。\n");
        goto out;
    }

    if (!payload_publish_bundle(root_dir, work_dir, embedded_payloads,
                                ARRAY_LEN(embedded_payloads))) {
        goto out;
    }

    if (!SetCurrentDirectoryW(work_dir)) {
        fwprintf(stderr, L"设置 payload 工作目录失败，错误=%lu\n", GetLastError());
        goto out;
    }
    code = run_payload(argc, argv, work_dir, root_dir, respawn_path,
                       autorun, firstlogon);

out:
#ifndef RESPAWN_PROGRESS_ONLY
    if (code != 0 && !autorun) {
        swprintf(respawn_path, ARRAY_LEN(respawn_path), L"初始化未完成，退出码=%d。请查看 %ls 日志。", code, root_dir);
        MessageBoxW(NULL, respawn_path, L"respawn-stealth 执行失败", MB_ICONERROR | MB_OK);
    }
#endif
    CloseHandle(payload_lock);
#ifdef RESPAWN_PROGRESS_ONLY
    progress_only_ui_finish(code == 0);
#endif
    return code;
}
