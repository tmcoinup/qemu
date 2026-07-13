/*
 * DDR4 SPD 密度映射单元测试
 *
 * Copyright (c) 2026 VMate contributors
 * SPDX-License-Identifier: MIT
 */

#include "qemu/osdep.h"
#include "hw/i2c/smbus_eeprom_spd.h"

static void assert_density(uint8_t code, uint8_t density_banks,
                           uint8_t addressing, uint16_t trfc1,
                           uint16_t trfc2, uint16_t trfc4)
{
    SmbusEepromDdr4Density actual;

    g_assert_true(smbus_eeprom_ddr4_density(code, &actual));
    g_assert_cmphex(actual.density_banks, ==, density_banks);
    g_assert_cmphex(actual.addressing, ==, addressing);
    g_assert_cmpuint(actual.trfc1_mtb, ==, trfc1);
    g_assert_cmpuint(actual.trfc2_mtb, ==, trfc2);
    g_assert_cmpuint(actual.trfc4_mtb, ==, trfc4);
}

static void test_size_descriptor(void)
{
    /* 已使用/总容量均为 256B；不能回退成声明 512B 的 0x23。 */
    g_assert_cmphex(smbus_eeprom_ddr4_size_descriptor(), ==, 0x12);
}

static void test_density_geometry_and_refresh(void)
{
    /* tRFC 单位为 125ps MTB：160ns=1280、260ns=2080、350ns=2800。 */
    assert_density(3, 0x83, 0x11, 1280, 880, 720);
    assert_density(4, 0x84, 0x19, 2080, 1280, 880);
    assert_density(5, 0x85, 0x21, 2800, 2080, 1280);
    assert_density(6, 0x86, 0x29, 4400, 2800, 2080);
}

static void test_invalid_legacy_density(void)
{
    SmbusEepromDdr4Density actual;

    /* DDR4 画像不为 1Gb 及更小颗粒编造未核验的地址几何。 */
    g_assert_false(smbus_eeprom_ddr4_density(2, &actual));
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/smbus-eeprom-spd/size-descriptor",
                    test_size_descriptor);
    g_test_add_func("/smbus-eeprom-spd/density-geometry-refresh",
                    test_density_geometry_and_refresh);
    g_test_add_func("/smbus-eeprom-spd/invalid-legacy-density",
                    test_invalid_legacy_density);
    return g_test_run();
}
