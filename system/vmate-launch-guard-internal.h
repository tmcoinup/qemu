/*
 * VMate launch guard private interfaces.
 * VMate 启动门禁私有接口。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef SYSTEM_VMATE_LAUNCH_GUARD_INTERNAL_H
#define SYSTEM_VMATE_LAUNCH_GUARD_INTERNAL_H

#include <stdbool.h>
#include <wchar.h>

#define VMATE_MAX_WINDOWS_PATH 32768

typedef struct VMateLaunchGuardLayout {
    wchar_t *root;
    wchar_t *libexec;
    wchar_t *qemu;
    wchar_t *client;
} VMateLaunchGuardLayout;

/* Derive only the exact private-runtime layout from a canonical DOS path. */
/* 仅从规范 DOS 路径推导固定私有运行时布局。 */
bool vmate_launch_guard_derive_layout(const wchar_t *module_path,
                                      VMateLaunchGuardLayout *layout);
void vmate_launch_guard_clear_layout(VMateLaunchGuardLayout *layout);

#ifdef _WIN32
bool vmate_launch_guard_windows_integrity_valid(void);
bool vmate_launch_guard_windows_authorized(void);
#endif

#endif /* SYSTEM_VMATE_LAUNCH_GUARD_INTERNAL_H */
