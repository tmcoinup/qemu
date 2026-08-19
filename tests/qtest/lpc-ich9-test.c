/*
 * QTest testcases for ich9 case
 *
 * Copyright (c) 2020 Li Qiang <liq3ea@gmail.com>
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"

#include "libqtest.h"

typedef struct G11LPCIdentityTest {
    const char *chipset;
    uint16_t device_id;
    uint8_t revision;
} G11LPCIdentityTest;

static const G11LPCIdentityTest g11_lpc_identity_tests[] = {
    { "H81",  0x8c5c, 0x04 },
    { "H97",  0x8cc6, 0x00 },
    { "B150", 0xa148, 0x31 },
    { "B360", 0xa308, 0x10 },
};

static void test_g11_lpc_identity(gconstpointer opaque)
{
    const G11LPCIdentityTest *identity = opaque;
    g_autofree char *args = g_strdup_printf(
        "-M q35 -global ICH9-LPC.x-g11-chipset=%s "
        "-nographic -monitor none -serial none", identity->chipset);
    QTestState *s = qtest_init(args);
    uint32_t id;

    qtest_outl(s, 0xcf8, 0x8000f800); /* D31:F0 vendor/device */
    id = qtest_inl(s, 0xcfc);
    g_assert_cmphex(id & 0xffff, ==, 0x8086);
    g_assert_cmphex(id >> 16, ==, identity->device_id);

    qtest_outl(s, 0xcf8, 0x8000f808); /* D31:F0 revision */
    g_assert_cmphex(qtest_inb(s, 0xcfc), ==, identity->revision);
    qtest_quit(s);
}

static void test_g11_lpc_identity_default(void)
{
    QTestState *s = qtest_init(
        "-M q35 -nographic -monitor none -serial none");
    uint32_t id;

    qtest_outl(s, 0xcf8, 0x8000f800);
    id = qtest_inl(s, 0xcfc);
    g_assert_cmphex(id & 0xffff, ==, 0x8086);
    g_assert_cmphex(id >> 16, ==, 0x2918);
    qtest_outl(s, 0xcf8, 0x8000f808);
    g_assert_cmphex(qtest_inb(s, 0xcfc), ==, 0x02);
    qtest_quit(s);
}

static void test_lp1878642_pci_bus_get_irq_level_assert(void)
{
    QTestState *s;

    s = qtest_init("-M q35 "
                   "-nographic -monitor none -serial none");

    qtest_outl(s, 0xcf8, 0x8000f840); /* PMBASE */
    qtest_outl(s, 0xcfc, 0x5d00);
    qtest_outl(s, 0xcf8, 0x8000f844); /* ACPI_CTRL */
    qtest_outl(s, 0xcfc, 0xeb);
    qtest_outw(s, 0x5d02, 0x205d);
    qtest_quit(s);
}

int main(int argc, char **argv)
{
    const char *arch = qtest_get_arch();
    size_t index;

    g_test_init(&argc, &argv, NULL);

    if (strcmp(arch, "i386") == 0 || strcmp(arch, "x86_64") == 0) {
        qtest_add_func("ich9/test_lp1878642_pci_bus_get_irq_level_assert",
                       test_lp1878642_pci_bus_get_irq_level_assert);
        qtest_add_func("ich9/g11-chipset/default",
                       test_g11_lpc_identity_default);
        for (index = 0; index < ARRAY_SIZE(g11_lpc_identity_tests); index++) {
            const G11LPCIdentityTest *identity = &g11_lpc_identity_tests[index];
            g_autofree char *path = g_strdup_printf(
                "/ich9/g11-chipset/%s", identity->chipset);

            g_test_add_data_func(path, identity, test_g11_lpc_identity);
        }
    }

    return g_test_run();
}
