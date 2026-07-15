#ifndef STEALTH_LAUNCHER_ARGUMENTS_H
#define STEALTH_LAUNCHER_ARGUMENTS_H

#include <wchar.h>

/*
 * 启动器私有参数不会转发给 PowerShell。无人值守与 FirstLogon 是两个正交状态：
 * --no-confirm/--auto 只跳过确认框，只有 --firstlogon 才启用脚本的 FirstLogon 清理。
 */
int launcher_arg_is_control(const wchar_t *argument);
int launcher_args_request_autorun(int count, wchar_t **arguments);
int launcher_args_request_firstlogon(int count, wchar_t **arguments);

#endif
