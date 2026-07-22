/*
 * VMate launch guard argument classification tests.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "system/vmate-launch-guard.h"

static VMateLaunchGuardDecision classify(size_t argc, const char **arguments)
{
    return vmate_launch_guard_classify(argc, (char **)arguments);
}

static void test_exact_status(void)
{
    const char *valid[] = { "qemu", "--vmate-launch-guard-status" };
    const char *extra[] = {
        "qemu", "--vmate-launch-guard-status", "--version"
    };

    g_assert_cmpint(classify(G_N_ELEMENTS(valid), valid), ==,
                    VMATE_LAUNCH_GUARD_REPORT_STATUS);
    g_assert_cmpint(classify(G_N_ELEMENTS(extra), extra), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
}

static void test_exact_version_probes(void)
{
    const char *short_version[] = { "qemu", "-version" };
    const char *long_version[] = { "qemu", "--version" };
    const char *extra[] = { "qemu", "--version", "-machine", "q35" };

    g_assert_cmpint(classify(G_N_ELEMENTS(short_version), short_version), ==,
                    VMATE_LAUNCH_GUARD_ALLOW_PROBE);
    g_assert_cmpint(classify(G_N_ELEMENTS(long_version), long_version), ==,
                    VMATE_LAUNCH_GUARD_ALLOW_PROBE);
    g_assert_cmpint(classify(G_N_ELEMENTS(extra), extra), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
}

static void test_exact_help_probes(void)
{
    static const char *const fixed_devices[] = {
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
    const char *accel[] = { "qemu", "-accel", "help" };
    const char *unknown_device[] = { "qemu", "-device", "scsi-hd,help" };
    const char *device_options[] = {
        "qemu", "-device", "virtio-vga,help,id=probe"
    };
    const char *object[] = { "qemu", "-object", "fb-shm,help" };
    const char *unknown_object[] = {
        "qemu", "-object", "memory-backend-ram,help"
    };
    const char *netdev[] = { "qemu", "-netdev", "help" };
    const char *display[] = { "qemu", "-display", "help" };
    const char *vnc[] = { "qemu", "-vnc", "help" };
    const char *extra[] = { "qemu", "-accel", "help", "-S" };
    const char *similar[] = { "qemu", "-accel=help" };
    size_t index;

    g_assert_cmpint(classify(G_N_ELEMENTS(accel), accel), ==,
                    VMATE_LAUNCH_GUARD_ALLOW_PROBE);
    for (index = 0; index < G_N_ELEMENTS(fixed_devices); index++) {
        const char *device[] = { "qemu", "-device", fixed_devices[index] };

        g_assert_cmpint(classify(G_N_ELEMENTS(device), device), ==,
                        VMATE_LAUNCH_GUARD_ALLOW_PROBE);
    }
    g_assert_cmpint(classify(G_N_ELEMENTS(unknown_device), unknown_device), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
    g_assert_cmpint(classify(G_N_ELEMENTS(device_options), device_options), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
    g_assert_cmpint(classify(G_N_ELEMENTS(object), object), ==,
                    VMATE_LAUNCH_GUARD_ALLOW_PROBE);
    g_assert_cmpint(classify(G_N_ELEMENTS(unknown_object), unknown_object), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
    g_assert_cmpint(classify(G_N_ELEMENTS(netdev), netdev), ==,
                    VMATE_LAUNCH_GUARD_ALLOW_PROBE);
    g_assert_cmpint(classify(G_N_ELEMENTS(display), display), ==,
                    VMATE_LAUNCH_GUARD_ALLOW_PROBE);
    g_assert_cmpint(classify(G_N_ELEMENTS(vnc), vnc), ==,
                    VMATE_LAUNCH_GUARD_ALLOW_PROBE);
    g_assert_cmpint(classify(G_N_ELEMENTS(extra), extra), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
    g_assert_cmpint(classify(G_N_ELEMENTS(similar), similar), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
}

static void test_boot_requires_authorization(void)
{
    const char *boot[] = { "qemu", "-machine", "q35", "-m", "4096" };
    const char *no_arguments[] = { "qemu" };

    g_assert_cmpint(classify(G_N_ELEMENTS(boot), boot), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
    g_assert_cmpint(classify(G_N_ELEMENTS(no_arguments), no_arguments), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
    g_assert_cmpint(vmate_launch_guard_classify(0, NULL), ==,
                    VMATE_LAUNCH_GUARD_AUTHORIZE);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/vmate-launch-guard/status", test_exact_status);
    g_test_add_func("/vmate-launch-guard/version", test_exact_version_probes);
    g_test_add_func("/vmate-launch-guard/help", test_exact_help_probes);
    g_test_add_func("/vmate-launch-guard/boot", test_boot_requires_authorization);
    return g_test_run();
}
