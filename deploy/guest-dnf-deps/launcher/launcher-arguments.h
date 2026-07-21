#ifndef DNF_FIX_DEPS_LAUNCHER_ARGUMENTS_H
#define DNF_FIX_DEPS_LAUNCHER_ARGUMENTS_H

#include <wchar.h>

/* 仅允许固定开关；控制参数不转发，DryRun 映射为 PowerShell 开关。 */
int dnf_args_valid(int count, wchar_t **arguments);
int dnf_arg_is_control(const wchar_t *argument);
int dnf_args_skip_confirmation(int count, wchar_t **arguments);
const wchar_t *dnf_arg_forward_value(const wchar_t *argument);

#endif
