/*
 * VMate launch guard argument classification tests.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "system/vmate-launch-guard.h"
#include "system/vmate-launch-guard-internal.h"

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

static void assert_layout(const wchar_t *module_path,
                          const wchar_t *expected_root)
{
    VMateLaunchGuardLayout layout;

    g_assert_true(vmate_launch_guard_derive_layout(module_path, &layout));
    g_assert_cmpint(wcscmp(layout.root, expected_root), ==, 0);
    g_assert_cmpint(wcscmp(layout.libexec,
                          L"C:\\Program Files\\VMate\\libexec"), ==, 0);
    g_assert_cmpint(wcscmp(layout.qemu, module_path), ==, 0);
    g_assert_cmpint(wcscmp(layout.client,
                          L"C:\\Program Files\\VMate\\vmate-client.exe"),
                    ==, 0);
    vmate_launch_guard_clear_layout(&layout);
}

static void test_layout_valid(void)
{
    VMateLaunchGuardLayout layout;
    const wchar_t *mixed_case =
        L"D:\\Secure Apps\\VMate\\LiBeXeC\\QEMU-System-X86_64.Real.Exe";

    assert_layout(
        L"C:\\Program Files\\VMate\\libexec\\"
        L"qemu-system-x86_64.real.exe",
        L"C:\\Program Files\\VMate");
    g_assert_true(vmate_launch_guard_derive_layout(mixed_case, &layout));
    g_assert_cmpint(wcscmp(layout.root, L"D:\\Secure Apps\\VMate"), ==, 0);
    g_assert_cmpint(wcscmp(layout.libexec,
                          L"D:\\Secure Apps\\VMate\\libexec"), ==, 0);
    g_assert_cmpint(wcscmp(layout.client,
                          L"D:\\Secure Apps\\VMate\\vmate-client.exe"),
                    ==, 0);
    vmate_launch_guard_clear_layout(&layout);
}

static void test_layout_rejects_nonlocal_paths(void)
{
    static const wchar_t *const invalid[] = {
        L"VMate\\libexec\\qemu-system-x86_64.real.exe",
        L"C:VMate\\libexec\\qemu-system-x86_64.real.exe",
        L"\\\\server\\share\\VMate\\libexec\\"
        L"qemu-system-x86_64.real.exe",
        L"\\\\?\\C:\\VMate\\libexec\\qemu-system-x86_64.real.exe",
        L"\\\\.\\C:\\VMate\\libexec\\qemu-system-x86_64.real.exe",
        L"C:/VMate/libexec/qemu-system-x86_64.real.exe",
    };
    size_t index;

    for (index = 0; index < G_N_ELEMENTS(invalid); index++) {
        VMateLaunchGuardLayout layout;

        g_assert_false(vmate_launch_guard_derive_layout(invalid[index],
                                                        &layout));
    }
}

static void test_layout_rejects_noncanonical_paths(void)
{
    static const wchar_t *const invalid[] = {
        L"C:\\VMate\\.\\libexec\\qemu-system-x86_64.real.exe",
        L"C:\\Apps\\..\\VMate\\libexec\\"
        L"qemu-system-x86_64.real.exe",
        L"C:\\Apps\\\\VMate\\libexec\\qemu-system-x86_64.real.exe",
        L"C:\\VMate.\\libexec\\qemu-system-x86_64.real.exe",
        L"C:\\VMate \\libexec\\qemu-system-x86_64.real.exe",
        L"C:\\VMate:alternate\\libexec\\"
        L"qemu-system-x86_64.real.exe",
    };
    size_t index;

    for (index = 0; index < G_N_ELEMENTS(invalid); index++) {
        VMateLaunchGuardLayout layout;

        g_assert_false(vmate_launch_guard_derive_layout(invalid[index],
                                                        &layout));
    }
}

static void test_layout_rejects_wrong_layout(void)
{
    static const wchar_t *const invalid[] = {
        L"C:\\libexec\\qemu-system-x86_64.real.exe",
        L"C:\\VMate\\bin\\qemu-system-x86_64.real.exe",
        L"C:\\VMate\\libexec\\qemu-system-x86_64.exe",
        L"C:\\VMate\\libexec\\qemu-system-aarch64.real.exe",
        L"C:\\VMate\\libexec\\qemu-system-x86_64.real.exe.bak",
    };
    size_t index;

    for (index = 0; index < G_N_ELEMENTS(invalid); index++) {
        VMateLaunchGuardLayout layout;

        g_assert_false(vmate_launch_guard_derive_layout(invalid[index],
                                                        &layout));
    }
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/vmate-launch-guard/status", test_exact_status);
    g_test_add_func("/vmate-launch-guard/version", test_exact_version_probes);
    g_test_add_func("/vmate-launch-guard/help", test_exact_help_probes);
    g_test_add_func("/vmate-launch-guard/boot",
                    test_boot_requires_authorization);
    g_test_add_func("/vmate-launch-guard/layout/valid", test_layout_valid);
    g_test_add_func("/vmate-launch-guard/layout/nonlocal",
                    test_layout_rejects_nonlocal_paths);
    g_test_add_func("/vmate-launch-guard/layout/noncanonical",
                    test_layout_rejects_noncanonical_paths);
    g_test_add_func("/vmate-launch-guard/layout/wrong",
                    test_layout_rejects_wrong_layout);
    return g_test_run();
}
