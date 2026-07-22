/*
 * VMate Windows QEMU launch authorization guard.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef SYSTEM_VMATE_LAUNCH_GUARD_H
#define SYSTEM_VMATE_LAUNCH_GUARD_H

typedef enum VMateLaunchGuardDecision {
    VMATE_LAUNCH_GUARD_AUTHORIZE,
    VMATE_LAUNCH_GUARD_ALLOW_PROBE,
    VMATE_LAUNCH_GUARD_REPORT_STATUS,
} VMateLaunchGuardDecision;

#define VMATE_LAUNCH_GUARD_CONTINUE (-1)

VMateLaunchGuardDecision vmate_launch_guard_classify(int argc, char **argv);
int vmate_launch_guard_check(int argc, char **argv);

#endif /* SYSTEM_VMATE_LAUNCH_GUARD_H */
