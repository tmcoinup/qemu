#ifndef RESPAWN_PAYLOAD_ENVIRONMENT_H
#define RESPAWN_PAYLOAD_ENVIRONMENT_H

#include <windows.h>

/*
 * 为管理员 PowerShell 构造最小 Unicode 环境块。调用者用 HeapFree 语义封装的
 * payload_free_environment 释放，不能把返回值交给 LocalFree。
 */
wchar_t *payload_build_environment(const wchar_t *root_dir,
                                   const wchar_t *work_dir);
void payload_free_environment(wchar_t *environment);

#endif
