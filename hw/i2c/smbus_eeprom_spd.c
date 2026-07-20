/*
 * QEMU DDR4 SPD 密度与地址几何映射
 *
 * Copyright (c) 2026 VMate contributors
 * SPDX-License-Identifier: MIT
 */

#include "qemu/osdep.h"
#include "hw/i2c/smbus_eeprom_spd.h"

#define DDR4_MTB_PS 125

typedef struct SpdManufacturer {
    const char *name;
    uint8_t module_id[2];
    uint8_t dram_id[2];
    bool has_dram_id;
} SpdManufacturer;

/*
 * 中文注释：表中覆盖 stealth-pools.sh 的全部内存品牌。
 * module_id 是模组厂商。
 * 不能把 Crucial 错写成 DRAM 供应商 Micron。
 * Kingston ValueRAM 的 DRAM 供应商可能随批次变化，
 * 所以只发布模组厂商码。
 */
static const SpdManufacturer spd_manufacturers[] = {
    { "Crucial",  { 0x85, 0x9b }, { 0x80, 0x2c }, true },
    { "Samsung",  { 0x80, 0xce }, { 0x80, 0xce }, true },
    { "Kingston", { 0x01, 0x98 }, { 0x00, 0x00 }, false },
    { "SK hynix", { 0x80, 0xad }, { 0x80, 0xad }, true },
};

uint8_t smbus_eeprom_ddr4_size_descriptor(bool ee1004)
{
    /*
     * EE1004 声明 384B used/512B total；
     * 旧 machine/config 保持 256B used/total 的 ABI。
     */
    return ee1004 ? 0x23 : 0x12;
}

static uint16_t nanoseconds_to_mtb(uint16_t nanoseconds)
{
    return (uint32_t)nanoseconds * 1000 / DDR4_MTB_PS;
}

bool smbus_eeprom_ddr4_density(uint8_t density_code,
                               uint8_t device_width_bits,
                               SmbusEepromDdr4Density *result)
{
    uint16_t trfc1_ns;
    uint16_t trfc2_ns;
    uint16_t trfc4_ns;

    g_return_val_if_fail(result != NULL, false);

    /*
     * 中文注释：DDR4 x8 的 2/4/8Gb 颗粒分别使用 14/15/16 个 row bit，
     * column 固定 10 bit；16Gb 顺延为 17 row bit。tRFC1/2/4 也随颗粒
     * 密度增长，不能把 4Gb 的 260/160/110ns 套在所有容量上。
     */
    switch (density_code) {
    case 3: /* 2Gb */
        trfc1_ns = 160;
        trfc2_ns = 110;
        trfc4_ns = 90;
        break;
    case 4: /* 4Gb */
        trfc1_ns = 260;
        trfc2_ns = 160;
        trfc4_ns = 110;
        break;
    case 5: /* 8Gb */
        trfc1_ns = 350;
        trfc2_ns = 260;
        trfc4_ns = 160;
        break;
    case 6: /* 16Gb */
        trfc1_ns = 550;
        trfc2_ns = 350;
        trfc4_ns = 260;
        break;
    default:
        return false;
    }

    if (device_width_bits != 4 && device_width_bits != 8 &&
        device_width_bits != 16) {
        return false;
    }

    /*
     * x4/x8 颗粒有 4 个 bank group，x16 颗粒有 2 个。
     * 该字段必须随颗粒宽度变化；例如 Samsung 8Gb x16 是 0x45，
     * 不能沿用 8Gb x8 的 0x85。
     */
    result->density_banks =
        (device_width_bits == 16 ? 0x40 : 0x80) | density_code;
    result->addressing = ((density_code - 1) << 3) | 0x01;
    result->trfc1_mtb = nanoseconds_to_mtb(trfc1_ns);
    result->trfc2_mtb = nanoseconds_to_mtb(trfc2_ns);
    result->trfc4_mtb = nanoseconds_to_mtb(trfc4_ns);
    return true;
}

static const SpdManufacturer *spd_find_manufacturer(const char *name)
{
    size_t i;

    for (i = 0; i < ARRAY_SIZE(spd_manufacturers); i++) {
        if (!g_ascii_strcasecmp(name, spd_manufacturers[i].name)) {
            return &spd_manufacturers[i];
        }
    }

    /*
     * 兼容工具常见的完整厂商名，
     * 同时保持 profile 的短名称为唯一权威写法。
     */
    if (!g_ascii_strcasecmp(name, "Crucial Technology")) {
        return &spd_manufacturers[0];
    }
    if (!g_ascii_strcasecmp(name, "Samsung Electronics")) {
        return &spd_manufacturers[1];
    }
    if (!g_ascii_strcasecmp(name, "Kingston Technology")) {
        return &spd_manufacturers[2];
    }
    if (!g_ascii_strcasecmp(name, "SK Hynix") ||
        !g_ascii_strcasecmp(name, "Hynix")) {
        return &spd_manufacturers[3];
    }
    return NULL;
}

static bool spd_parse_serial(const char *serial, uint8_t result[4])
{
    size_t i;

    if (!serial || !serial[0]) {
        memset(result, 0, 4);
        return true;
    }
    if (strlen(serial) != 8) {
        return false;
    }
    for (i = 0; i < 4; i++) {
        int high = g_ascii_xdigit_value(serial[i * 2]);
        int low = g_ascii_xdigit_value(serial[i * 2 + 1]);

        if (high < 0 || low < 0) {
            return false;
        }
        result[i] = high << 4 | low;
    }
    return true;
}

static bool spd_copy_part_number(uint8_t *destination, size_t field_size,
                                 const char *part_number)
{
    size_t length = part_number ? strlen(part_number) : 0;
    size_t i;

    if (length > field_size) {
        return false;
    }
    for (i = 0; i < length; i++) {
        if ((uint8_t)part_number[i] < 0x20 ||
            (uint8_t)part_number[i] > 0x7e) {
            return false;
        }
    }
    memset(destination, ' ', field_size);
    if (length) {
        memcpy(destination, part_number, length);
    }
    return true;
}

bool smbus_eeprom_spd_set_identity(uint8_t *spd, size_t spd_size,
                                   bool is_ddr4,
                                   const SmbusEepromSpdConfig *config)
{
    const SpdManufacturer *manufacturer;
    uint8_t serial[4];
    size_t manufacturer_offset = is_ddr4 ? 320 : 117;
    size_t serial_offset = is_ddr4 ? 325 : 122;
    size_t part_offset = is_ddr4 ? 329 : 128;
    size_t part_size = is_ddr4 ? 20 : 18;
    size_t dram_offset = is_ddr4 ? 350 : 148;

    g_return_val_if_fail(spd != NULL, false);
    g_return_val_if_fail(config != NULL, false);
    if (spd_size != (is_ddr4 ? SMBUS_EE1004_SIZE :
                                  SMBUS_EEPROM_PAGE_SIZE)) {
        return false;
    }

    /*
     * 未指定任何身份的通用 QEMU 调用保持兼容。
     * 一旦提供其中任一字段，就必须有可核验的品牌映射，
     * 防止部分身份悄悄退化成全零厂商码。
     */
    if ((!config->manufacturer || !config->manufacturer[0]) &&
        (!config->part_number || !config->part_number[0]) &&
        (!config->serial_number || !config->serial_number[0])) {
        return true;
    }
    if (!config->manufacturer || !config->manufacturer[0]) {
        return false;
    }
    manufacturer = spd_find_manufacturer(config->manufacturer);
    if (!manufacturer || !spd_parse_serial(config->serial_number, serial) ||
        !spd_copy_part_number(spd + part_offset, part_size,
                              config->part_number)) {
        return false;
    }

    memcpy(spd + manufacturer_offset, manufacturer->module_id, 2);
    memcpy(spd + serial_offset, serial, sizeof(serial));
    if (manufacturer->has_dram_id) {
        memcpy(spd + dram_offset, manufacturer->dram_id, 2);
    }
    return true;
}
