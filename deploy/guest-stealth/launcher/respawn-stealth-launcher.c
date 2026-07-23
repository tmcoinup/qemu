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
#include "payload_respawn_ps1.h"
#include "payload_respawn_restart_state_ps1.h"
#include "payload_configure_power_policy_ps1.h"
#include "payload_apply_gpu_spoof_ps1.h"
#include "payload_gpu_spoof_apply_support_ps1.h"
#include "payload_gpu_board_identity_contract_ps1.h"
#include "payload_persist_gpu_profile_ps1.h"
#include "payload_gpu_profile_transaction_ps1.h"
#include "payload_gpu_profile_registry_core_ps1.h"
#include "payload_refresh_gpu_name_ps1.h"
#include "payload_gpu_manufacturer_projection_ps1.h"
#include "payload_gpu_manufacturer_projector_exe.h"
#include "payload_gpu_hardware_id_plan_ps1.h"
#include "payload_project_gpu_hardware_id_ps1.h"
#include "payload_force_displayfreq_ps1.h"
#include "payload_install_display_driver_ps1.h"
#include "payload_display_driver_trust_ps1.h"
#include "payload_install_chipset_device_ps1.h"
#include "payload_install_nvapi_system_ps1.h"
#include "payload_nvapi_system_validation_ps1.h"
#include "payload_nvapi_system_transaction_ps1.h"
#include "payload_install_adl_system_ps1.h"
#include "payload_adl_system_transaction_ps1.h"
#include "payload_install_gpu_api_system_ps1.h"
#include "payload_gpu_api_identity_binding_ps1.h"
#include "payload_viogpudo_sys.h"
#include "payload_viogpudo_cat.h"
#include "payload_viogpudo_inf.h"
#include "payload_cannonlake_hsystem_inf.h"
#include "payload_cannonlake_h_cat.h"
#include "payload_sunrisepoint_hsystem_inf.h"
#include "payload_sunrisepoint_h_cat.h"
#include "payload_nvapi_x86_dll.h"
#include "payload_nvapi_x64_dll.h"
#include "payload_adl_x86_dll.h"
#include "payload_adl_x64_dll.h"
#ifndef ARRAY_LEN
#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))
#endif
#define PATH_BUF_LEN 4096
#define CMD_BUF_LEN 32760
/*
 * 中文注释：所有运行依赖都从一个 EXE 释放，来宾不再访问 host HTTP。驱动三件套
 * 必须保持原始字节，才能保留 Microsoft WHCP 的 PE/CAT 签名与文件关联；两份
 * NVAPI DLL 则由构建器和来宾系统发布 helper 用固定摘要、PE 架构做双重验收。
 */
static const EmbeddedPayload embedded_payloads[] = {
    { L"respawn-stealth-local.ps1", payload_respawn_ps1, (DWORD)sizeof(payload_respawn_ps1) },
    { L"respawn-restart-state.ps1", payload_respawn_restart_state_ps1, (DWORD)sizeof(payload_respawn_restart_state_ps1) },
    { L"configure-power-policy.ps1", payload_configure_power_policy_ps1, (DWORD)sizeof(payload_configure_power_policy_ps1) },
    { L"apply-gpu-spoof.ps1", payload_apply_gpu_spoof_ps1, (DWORD)sizeof(payload_apply_gpu_spoof_ps1) },
    { L"gpu-spoof-apply-support.ps1", payload_gpu_spoof_apply_support_ps1, (DWORD)sizeof(payload_gpu_spoof_apply_support_ps1) },
    { L"gpu-board-identity-contract.ps1", payload_gpu_board_identity_contract_ps1, (DWORD)sizeof(payload_gpu_board_identity_contract_ps1) },
    { L"persist-gpu-profile.ps1", payload_persist_gpu_profile_ps1, (DWORD)sizeof(payload_persist_gpu_profile_ps1) },
    { L"gpu-profile-transaction.ps1", payload_gpu_profile_transaction_ps1, (DWORD)sizeof(payload_gpu_profile_transaction_ps1) },
    { L"gpu-profile-registry-core.ps1", payload_gpu_profile_registry_core_ps1, (DWORD)sizeof(payload_gpu_profile_registry_core_ps1) },
    { L"refresh-gpu-name.ps1", payload_refresh_gpu_name_ps1, (DWORD)sizeof(payload_refresh_gpu_name_ps1) },
    { L"gpu-manufacturer-projection.ps1", payload_gpu_manufacturer_projection_ps1, (DWORD)sizeof(payload_gpu_manufacturer_projection_ps1) },
    { L"gpu-manufacturer-projector.exe", payload_gpu_manufacturer_projector_exe, (DWORD)sizeof(payload_gpu_manufacturer_projector_exe) },
    { L"gpu-hardware-id-plan.ps1", payload_gpu_hardware_id_plan_ps1, (DWORD)sizeof(payload_gpu_hardware_id_plan_ps1) },
    { L"project-gpu-hardware-id.ps1", payload_project_gpu_hardware_id_ps1, (DWORD)sizeof(payload_project_gpu_hardware_id_ps1) },
    { L"force-displayfreq.ps1", payload_force_displayfreq_ps1, (DWORD)sizeof(payload_force_displayfreq_ps1) },
    { L"install-display-driver.ps1", payload_install_display_driver_ps1, (DWORD)sizeof(payload_install_display_driver_ps1) },
    { L"display-driver-trust.ps1", payload_display_driver_trust_ps1, (DWORD)sizeof(payload_display_driver_trust_ps1) },
    { L"install-chipset-device.ps1", payload_install_chipset_device_ps1, (DWORD)sizeof(payload_install_chipset_device_ps1) },
    { L"install-nvapi-system.ps1", payload_install_nvapi_system_ps1, (DWORD)sizeof(payload_install_nvapi_system_ps1) },
    { L"nvapi-system-validation.ps1", payload_nvapi_system_validation_ps1, (DWORD)sizeof(payload_nvapi_system_validation_ps1) },
    { L"nvapi-system-transaction.ps1", payload_nvapi_system_transaction_ps1, (DWORD)sizeof(payload_nvapi_system_transaction_ps1) },
    { L"install-adl-system.ps1", payload_install_adl_system_ps1, (DWORD)sizeof(payload_install_adl_system_ps1) },
    { L"adl-system-transaction.ps1", payload_adl_system_transaction_ps1, (DWORD)sizeof(payload_adl_system_transaction_ps1) },
    { L"install-gpu-api-system.ps1", payload_install_gpu_api_system_ps1, (DWORD)sizeof(payload_install_gpu_api_system_ps1) },
    { L"gpu-api-identity-binding.ps1", payload_gpu_api_identity_binding_ps1, (DWORD)sizeof(payload_gpu_api_identity_binding_ps1) },
    { L"viogpudo.sys", payload_viogpudo_sys, (DWORD)sizeof(payload_viogpudo_sys) },
    { L"viogpudo.cat", payload_viogpudo_cat, (DWORD)sizeof(payload_viogpudo_cat) },
    { L"viogpudo.inf", payload_viogpudo_inf, (DWORD)sizeof(payload_viogpudo_inf) },
    { L"CannonLake-HSystem.inf", payload_cannonlake_hsystem_inf, (DWORD)sizeof(payload_cannonlake_hsystem_inf) },
    { L"cannonlake-h.cat", payload_cannonlake_h_cat, (DWORD)sizeof(payload_cannonlake_h_cat) },
    { L"SunrisePoint-HSystem.inf", payload_sunrisepoint_hsystem_inf, (DWORD)sizeof(payload_sunrisepoint_hsystem_inf) },
    { L"sunrisepoint-h.cat", payload_sunrisepoint_h_cat, (DWORD)sizeof(payload_sunrisepoint_h_cat) },
    { L"nvapi.dll", payload_nvapi_x86_dll, (DWORD)sizeof(payload_nvapi_x86_dll) },
    { L"nvapi64.dll", payload_nvapi_x64_dll, (DWORD)sizeof(payload_nvapi_x64_dll) },
    { L"atiadlxy.dll", payload_adl_x86_dll, (DWORD)sizeof(payload_adl_x86_dll) },
    { L"atiadlxx32.dll", payload_adl_x86_dll, (DWORD)sizeof(payload_adl_x86_dll) },
    { L"atiadlxx.dll", payload_adl_x64_dll, (DWORD)sizeof(payload_adl_x64_dll) },
};
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
        L"respawn-stealth 将以管理员权限把屏幕/睡眠设为“从不”、安装或检查"
        L"芯片组识别 INF 与显示驱动，并修改 HKLM 注册表、PnP 显卡信息和计划任务，"
        L"完成后默认会重启。\n\n是否继续？",
        L"respawn-stealth 管理员确认",
        MB_ICONWARNING | MB_YESNO | MB_DEFBUTTON2 | MB_SETFOREGROUND);

    return answer == IDYES;
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
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    size_t len = 0;
    wchar_t *environment = NULL;

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

    if (autorun &&
        !append_quoted_arg(cmd, ARRAY_LEN(cmd), &len, L"-Unattended")) {
        fwprintf(stderr, L"PowerShell Unattended 参数过长。\n");
        return 1;
    }
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

    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);

    environment = payload_build_environment(root_dir, work_dir);
    if (environment == NULL) {
        return 1;
    }

    /*
     * 不隐藏窗口：脚本会打印进度、失败原因和日志路径。等待子进程结束，
     * 这样调用者能拿到真实退出码，bat/调试终端也不会提前返回。
     */
    if (!CreateProcessW(powershell, cmd, NULL, NULL, FALSE,
                        CREATE_UNICODE_ENVIRONMENT, environment, work_dir,
                        &si, &pi)) {
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

    if (!payload_secure_directory(root_dir)) {
        fwprintf(stderr, L"创建或保护 payload 根目录失败: %ls\n", root_dir);
        return 1;
    }

    payload_lock = payload_acquire_lock(root_dir);
    if (payload_lock == INVALID_HANDLE_VALUE) {
        DWORD lock_error = GetLastError();
        if (!autorun) {
            MessageBoxW(NULL, lock_error == ERROR_SHARING_VIOLATION || lock_error == ERROR_LOCK_VIOLATION ? L"已有一次自动或手动初始化正在运行，请等待其完成。" : L"无法锁定初始化目录；请检查权限、重解析点与日志。",
                        L"respawn-stealth 启动失败", MB_ICONINFORMATION | MB_OK);
        }
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
    if (code != 0 && !autorun) {
        swprintf(respawn_path, ARRAY_LEN(respawn_path), L"初始化未完成，退出码=%d。请查看 %ls 日志。", code, root_dir);
        MessageBoxW(NULL, respawn_path, L"respawn-stealth 执行失败", MB_ICONERROR | MB_OK);
    }
    CloseHandle(payload_lock);
    return code;
}
