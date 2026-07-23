/*
 * VMate Windows QEMU launch authorization guard.
 * VMate Windows QEMU 启动授权门禁。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "system/vmate-launch-guard.h"

#ifdef _WIN32
#include "system/vmate-launch-guard-internal.h"
#endif

#define VMATE_LAUNCH_GUARD_MARKER "VMATE_QEMU_LAUNCH_GUARD_V1"
#define VMATE_LAUNCH_DENIED 126

static const char vmate_launch_guard_marker[] QEMU_USED =
    VMATE_LAUNCH_GUARD_MARKER;

static bool vmate_is_exact_arg(int argc, char **argv, const char *argument)
{
    return argc == 2 && argv && argv[1] && !strcmp(argv[1], argument);
}

static bool vmate_is_help_pair(int argc, char **argv,
                               const char *option, const char *value)
{
    return argc == 3 && argv && argv[1] && argv[2] &&
           !strcmp(argv[1], option) && !strcmp(argv[2], value);
}

static bool vmate_is_fixed_device_help(int argc, char **argv)
{
    static const char *const devices[] = {
        "ICH9-LPC,help",
        "ICH9-SMB,help",
        "ich9-ahci,help",
        "pcie-root-port,help",
        "intel-hda,help",
        "hda-duplex,help",
        "e1000e,help",
        "nvme,help",
        "usb-kbd,help",
        "usb-mouse,help",
        "virtio-vga,help",
        "virtio-vga-gl,help",
    };
    size_t index;

    if (argc != 3 || !argv || !argv[1] || !argv[2] ||
        strcmp(argv[1], "-device")) {
        return false;
    }
    for (index = 0; index < G_N_ELEMENTS(devices); index++) {
        if (!strcmp(argv[2], devices[index])) {
            return true;
        }
    }
    return false;
}

VMateLaunchGuardDecision vmate_launch_guard_classify(int argc, char **argv)
{
    if (vmate_is_exact_arg(argc, argv, "--vmate-launch-guard-status")) {
        return VMATE_LAUNCH_GUARD_REPORT_STATUS;
    }
    if (vmate_is_exact_arg(argc, argv, "-version") ||
        vmate_is_exact_arg(argc, argv, "--version")) {
        return VMATE_LAUNCH_GUARD_ALLOW_PROBE;
    }
    if (vmate_is_help_pair(argc, argv, "-accel", "help") ||
        vmate_is_help_pair(argc, argv, "-netdev", "help") ||
        vmate_is_help_pair(argc, argv, "-display", "help") ||
        vmate_is_help_pair(argc, argv, "-vnc", "help") ||
        vmate_is_help_pair(argc, argv, "-object", "fb-shm,help") ||
        vmate_is_fixed_device_help(argc, argv)) {
        return VMATE_LAUNCH_GUARD_ALLOW_PROBE;
    }
    return VMATE_LAUNCH_GUARD_AUTHORIZE;
}

static int vmate_launch_denied(const char *reason)
{
    fprintf(stderr, "%s: VMate launch authorization denied: %s\n",
            vmate_launch_guard_marker, reason);
    return VMATE_LAUNCH_DENIED;
}

int vmate_launch_guard_check(int argc, char **argv)
{
    switch (vmate_launch_guard_classify(argc, argv)) {
    case VMATE_LAUNCH_GUARD_REPORT_STATUS:
#ifdef _WIN32
        if (!vmate_launch_guard_windows_integrity_valid()) {
            return vmate_launch_denied("installation integrity check failed");
        }
#endif
        fputs("required\n", stdout);
        return 0;
    case VMATE_LAUNCH_GUARD_ALLOW_PROBE:
        return VMATE_LAUNCH_GUARD_CONTINUE;
    case VMATE_LAUNCH_GUARD_AUTHORIZE:
#ifdef _WIN32
        if (vmate_launch_guard_windows_authorized()) {
            return VMATE_LAUNCH_GUARD_CONTINUE;
        }
        return vmate_launch_denied("integrity or authorization check failed");
#else
        return vmate_launch_denied("guard is unavailable on this host");
#endif
    default:
        return vmate_launch_denied("invalid guard decision");
    }
}
