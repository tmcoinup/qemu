/*
 * DDR4 SPD 密度映射单元测试
 *
 * Copyright (c) 2026 VMate contributors
 * SPDX-License-Identifier: MIT
 */

#include "qemu/osdep.h"
#include "hw/i2c/smbus_eeprom.h"

static void assert_density(uint8_t code, uint8_t density_banks,
                           uint8_t addressing, uint16_t trfc1,
                           uint16_t trfc2, uint16_t trfc4)
{
    SmbusEepromDdr4Density actual;

    g_assert_true(smbus_eeprom_ddr4_density(code, 8, &actual));
    g_assert_cmphex(actual.density_banks, ==, density_banks);
    g_assert_cmphex(actual.addressing, ==, addressing);
    g_assert_cmpuint(actual.trfc1_mtb, ==, trfc1);
    g_assert_cmpuint(actual.trfc2_mtb, ==, trfc2);
    g_assert_cmpuint(actual.trfc4_mtb, ==, trfc4);
}

static void test_size_descriptor(void)
{
    /* 完整 EE1004：384B used、512B total、CRC 覆盖 bytes 0..125。 */
    g_assert_cmphex(smbus_eeprom_ddr4_size_descriptor(true), ==, 0x23);
    g_assert_cmphex(smbus_eeprom_ddr4_size_descriptor(false), ==, 0x12);
}

static void test_density_geometry_and_refresh(void)
{
    SmbusEepromDdr4Density actual;

    /* tRFC 单位为 125ps MTB：160ns=1280、260ns=2080、350ns=2800。 */
    assert_density(3, 0x83, 0x11, 1280, 880, 720);
    assert_density(4, 0x84, 0x19, 2080, 1280, 880);
    assert_density(5, 0x85, 0x21, 2800, 2080, 1280);
    assert_density(6, 0x86, 0x29, 4400, 2800, 2080);
    g_assert_true(smbus_eeprom_ddr4_density(5, 16, &actual));
    g_assert_cmphex(actual.density_banks, ==, 0x45);
    g_assert_cmphex(actual.addressing, ==, 0x21);
}

static void test_invalid_legacy_density(void)
{
    SmbusEepromDdr4Density actual;

    /* DDR4 画像不为 1Gb 及更小颗粒编造未核验的地址几何。 */
    g_assert_false(smbus_eeprom_ddr4_density(2, 8, &actual));
    g_assert_false(smbus_eeprom_ddr4_density(4, 32, &actual));
}

typedef struct SpdBrandCase {
    const char *manufacturer;
    const char *part_number;
    uint32_t size_mb;
    uint32_t speed_mts;
    uint8_t ranks;
    uint8_t device_width_bits;
    uint8_t density_banks;
    uint8_t raw_card;
    uint8_t module_id[2];
    uint8_t dram_id[2];
} SpdBrandCase;

static void assert_part_number(const uint8_t *actual, size_t field_size,
                               const char *expected)
{
    size_t length = strlen(expected);
    size_t i;

    g_assert_cmpmem(actual, length, expected, length);
    for (i = length; i < field_size; i++) {
        g_assert_cmphex(actual[i], ==, ' ');
    }
}

static void test_ddr4_hardware_pool_identities(void)
{
    static const SpdBrandCase cases[] = {
        {
            "Crucial", "CT2G4DFS624A", 2048, 2400, 1, 16, 0x44, 0x1f,
            { 0x85, 0x9b }, { 0x80, 0x2c }
        }, {
            "Crucial", "CT4G4DFS824A", 4096, 2400, 1, 8, 0x84, 0x1f,
            { 0x85, 0x9b }, { 0x80, 0x2c }
        }, {
            "Samsung", "M378A5644EB0-CRC", 2048, 2400, 1, 16, 0x44, 0x02,
            { 0x80, 0xce }, { 0x80, 0xce }
        }, {
            "Samsung", "M378A5244CB0-CRC", 4096, 2400, 1, 16, 0x45, 0x02,
            { 0x80, 0xce }, { 0x80, 0xce }
        }, {
            "Kingston", "KVR24N17S6/2", 2048, 2400, 1, 16, 0x44, 0x1f,
            { 0x01, 0x98 }, { 0x00, 0x00 }
        }, {
            "Kingston", "KVR24N17S8/4", 4096, 2400, 1, 8, 0x84, 0x1f,
            { 0x01, 0x98 }, { 0x00, 0x00 }
        }, {
            "SK hynix", "HMA425U6AFR6N-UH", 2048, 2400, 1, 16,
            0x44, 0x1f,
            { 0x80, 0xad }, { 0x80, 0xad }
        }, {
            "SK hynix", "HMA851U6AFR6N-UH", 4096, 2400, 1, 16,
            0x45, 0x1f,
            { 0x80, 0xad }, { 0x80, 0xad }
        },
    };
    size_t i;

    for (i = 0; i < ARRAY_SIZE(cases); i++) {
        uint8_t expected_width_code = 1;
        uint8_t expected_tfaw_lsb = 0xa8;
        uint8_t expected_trrd_s = 0x1b;
        uint8_t expected_trrd_l = 0x28;
        SmbusEepromSpdConfig config = {
            .manufacturer = cases[i].manufacturer,
            .part_number = cases[i].part_number,
            .serial_number = "0A3A2A57",
            .size_mb = cases[i].size_mb,
            .speed_mts = cases[i].speed_mts,
            .voltage_mv = 1200,
            .ranks = cases[i].ranks,
            .device_width_bits = cases[i].device_width_bits,
            .ee1004 = true,
        };
        g_autofree uint8_t *spd = spd_data_generate_ddr4(&config);

        if (cases[i].device_width_bits == 16) {
            expected_width_code = 2;
            expected_tfaw_lsb = 0xf0;
            expected_trrd_s = 0x2b;
            expected_trrd_l = 0x34;
        }
        g_assert_nonnull(spd);
        g_assert_cmphex(spd[0], ==, 0x23);
        g_assert_cmphex(spd[4], ==, cases[i].density_banks);
        g_assert_cmphex(spd[12] & 0x07, ==,
                        expected_width_code);
        g_assert_cmphex(spd[18], ==, 0x07);
        g_assert_cmphex(spd[19], ==, 0x0d);
        g_assert_cmphex(spd[20], ==, 0xf8);
        g_assert_cmphex(spd[21], ==, 0x0f);
        g_assert_cmphex(spd[24], ==, 0x6e);
        g_assert_cmphex(spd[25], ==, 0x6e);
        g_assert_cmphex(spd[26], ==, 0x6e);
        g_assert_cmphex(spd[27], ==, 0x11);
        g_assert_cmphex(spd[28], ==, 0x00);
        g_assert_cmphex(spd[29], ==, 0x6e);
        g_assert_cmphex(spd[37], ==, expected_tfaw_lsb);
        g_assert_cmphex(spd[38], ==, expected_trrd_s);
        g_assert_cmphex(spd[39], ==, expected_trrd_l);
        g_assert_cmphex(spd[40], ==, 0x28);
        g_assert_cmphex(spd[42], ==, 0x78);
        g_assert_cmphex(spd[44], ==, 0x14);
        g_assert_cmphex(spd[45], ==, 0x3c);
        g_assert_cmphex(spd[117], ==, 0x00);
        g_assert_cmphex(spd[118], ==, 0x9c);
        g_assert_cmphex(spd[119], ==, 0xb5);
        g_assert_cmphex(spd[124], ==, 0xe7);
        g_assert_cmphex(spd[125], ==, 0xd6);
        g_assert_cmphex(spd[130], ==, cases[i].raw_card);
        g_assert_cmpmem(spd + 320, 2, cases[i].module_id, 2);
        g_assert_cmphex(spd[325], ==, 0x0a);
        g_assert_cmphex(spd[326], ==, 0x3a);
        g_assert_cmphex(spd[327], ==, 0x2a);
        g_assert_cmphex(spd[328], ==, 0x57);
        assert_part_number(spd + 329, 20, cases[i].part_number);
        g_assert_cmpmem(spd + 350, 2, cases[i].dram_id, 2);
    }
}

typedef struct Ddr3PartCase {
    const char *manufacturer;
    const char *part_number;
    uint32_t size_mb;
    uint32_t speed_mts;
    uint8_t ranks;
    uint8_t device_width_bits;
    uint8_t density;
    uint8_t addressing;
    uint16_t trfc_mtb;
    uint16_t tras_mtb;
    uint16_t trc_mtb;
    uint16_t tfaw_mtb;
    uint8_t cas_low;
    uint8_t module_id[2];
} Ddr3PartCase;

static void test_ddr3_hardware_pool_identities(void)
{
    static const Ddr3PartCase cases[] = {
        {
            "Kingston", "KVR16N11S6/2", 2048, 1600, 1, 16,
            4, 0x19, 2080, 280, 385, 320, 0xfc, { 0x01, 0x98 }
        }, {
            "Kingston", "KVR16N11S8/4", 4096, 1600, 1, 8,
            4, 0x21, 2080, 280, 385, 240, 0xfc, { 0x01, 0x98 }
        }, {
            "Crucial", "CT25664BA160B", 2048, 1600, 1, 8,
            3, 0x19, 1280, 280, 385, 240, 0xfc, { 0x85, 0x9b }
        }, {
            "Crucial", "CT51264BA160B", 4096, 1600, 2, 8,
            3, 0x19, 1280, 280, 385, 240, 0xfc, { 0x85, 0x9b }
        }, {
            "SK hynix", "HMT325U6CFR8C-PB", 2048, 1600, 1, 8,
            3, 0x19, 1280, 280, 385, 240, 0xfc, { 0x80, 0xad }
        }, {
            "SK hynix", "HMT351U6CFR8C-PB", 4096, 1600, 2, 8,
            3, 0x19, 1280, 280, 385, 240, 0xfc, { 0x80, 0xad }
        }, {
            "Kingston", "KVR13N9S6/2", 2048, 1333, 1, 16,
            4, 0x19, 2080, 288, 393, 360, 0x3c, { 0x01, 0x98 }
        }, {
            "Kingston", "KVR13N9S8/4", 4096, 1333, 1, 8,
            4, 0x21, 2080, 288, 393, 240, 0x3c, { 0x01, 0x98 }
        },
    };
    size_t i;

    for (i = 0; i < ARRAY_SIZE(cases); i++) {
        uint8_t expected_trrd = 0x30;
        SmbusEepromSpdConfig config = {
            .manufacturer = cases[i].manufacturer,
            .part_number = cases[i].part_number,
            .serial_number = "C9D6DBD9",
            .size_mb = cases[i].size_mb,
            .speed_mts = cases[i].speed_mts,
            .voltage_mv = 1500,
            .ranks = cases[i].ranks,
            .device_width_bits = cases[i].device_width_bits,
        };
        g_autofree uint8_t *spd = spd_data_generate_ddr3(&config);

        if (cases[i].device_width_bits == 16) {
            expected_trrd = 0x3c;
        }
        g_assert_nonnull(spd);
        g_assert_cmphex(spd[4], ==, cases[i].density);
        g_assert_cmphex(spd[5], ==, cases[i].addressing);
        g_assert_cmphex(spd[7] >> 3, ==, cases[i].ranks - 1);
        g_assert_cmphex(spd[14], ==, cases[i].cas_low);
        g_assert_cmphex(spd[16], ==, 0x69);
        g_assert_cmphex(spd[18], ==, 0x69);
        g_assert_cmphex(spd[19], ==, expected_trrd);
        g_assert_cmphex(spd[20], ==, 0x69);
        g_assert_cmpuint(((spd[21] & 0x0f) << 8) | spd[22], ==,
                         cases[i].tras_mtb);
        g_assert_cmpuint(((spd[21] & 0xf0) << 4) | spd[23], ==,
                         cases[i].trc_mtb);
        g_assert_cmpuint(spd[24] | spd[25] << 8, ==,
                         cases[i].trfc_mtb);
        g_assert_cmpuint(((spd[28] & 0x0f) << 8) | spd[29], ==,
                         cases[i].tfaw_mtb);
        g_assert_cmphex(spd[28] & 0xf0, ==, 0x00);
        g_assert_cmphex(spd[60], ==, 0x0f);
        g_assert_cmphex(spd[61], ==, 0x11);
        g_assert_cmphex(spd[62], ==, 0x1f);
        g_assert_cmpmem(spd + 117, 2, cases[i].module_id, 2);
        g_assert_cmphex(spd[122], ==, 0xc9);
        g_assert_cmphex(spd[123], ==, 0xd6);
        g_assert_cmphex(spd[124], ==, 0xdb);
        g_assert_cmphex(spd[125], ==, 0xd9);
        assert_part_number(spd + 128, 18, config.part_number);
    }
}

static void test_unknown_brand_rejected(void)
{
    SmbusEepromSpdConfig config = {
        .manufacturer = "Unverified Memory Vendor",
        .part_number = "UNKNOWN",
        .serial_number = "12345678",
        .size_mb = 4096,
        .speed_mts = 2400,
        .voltage_mv = 1200,
        .ranks = 1,
        .device_width_bits = 8,
        .ee1004 = true,
    };

    g_assert_null(spd_data_generate_ddr4(&config));
}

static void test_legacy_ddr4_without_identity(void)
{
    SmbusEepromSpdConfig config = {
        .size_mb = 4096,
        .speed_mts = 2400,
        .voltage_mv = 1200,
        .ranks = 1,
        .device_width_bits = 8,
        .ee1004 = false,
    };
    g_autofree uint8_t *spd = spd_data_generate_ddr4(&config);

    /*
     * 未显式启用 EE1004 的旧 machine/config 继续生成单页 SPD。
     * 这条边界测试防止身份页支持意外改变历史客体 ABI。
     */
    g_assert_nonnull(spd);
    g_assert_cmphex(spd[0], ==, 0x12);
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
    g_test_add_func("/smbus-eeprom-spd/ddr4-hardware-pool-identities",
                    test_ddr4_hardware_pool_identities);
    g_test_add_func("/smbus-eeprom-spd/ddr3-hardware-pool-identities",
                    test_ddr3_hardware_pool_identities);
    g_test_add_func("/smbus-eeprom-spd/unknown-brand-rejected",
                    test_unknown_brand_rejected);
    g_test_add_func("/smbus-eeprom-spd/legacy-ddr4-without-identity",
                    test_legacy_ddr4_without_identity);
    return g_test_run();
}
