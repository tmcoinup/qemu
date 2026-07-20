/*
 * QEMU SPD 数据生成辅助接口
 *
 * Copyright (c) 2026 VMate contributors
 * SPDX-License-Identifier: MIT
 */

#ifndef HW_SMBUS_EEPROM_SPD_H
#define HW_SMBUS_EEPROM_SPD_H

#define SMBUS_EEPROM_PAGE_SIZE 256
#define SMBUS_EE1004_SIZE 512

/*
 * 中文注释：SPD 身份必须与 SMBIOS Type 17 使用同一份输入。
 * manufacturer 只接受硬件目录中已有 JEP106 厂商码的品牌。
 * part_number 写入标准料号区，serial_number 写入唯一序列号区。
 */
typedef struct SmbusEepromSpdConfig {
    const char *manufacturer;
    const char *part_number;
    const char *serial_number;
    uint32_t size_mb;
    uint32_t speed_mts;
    uint16_t voltage_mv;
    uint8_t ranks;
    uint8_t device_width_bits;
    bool ee1004;
} SmbusEepromSpdConfig;

/*
 * 中文注释：这些字段都是 DDR4 SPD page 0 的客观颗粒参数。把映射独立出来，
 * 便于对 2/4/8Gb 颗粒逐项单测，也避免容量、地址几何和刷新时序各自硬编码。
 */
typedef struct SmbusEepromDdr4Density {
    uint8_t density_banks;
    uint8_t addressing;
    uint16_t trfc1_mtb;
    uint16_t trfc2_mtb;
    uint16_t trfc4_mtb;
} SmbusEepromDdr4Density;

uint8_t smbus_eeprom_ddr4_size_descriptor(bool ee1004);
bool smbus_eeprom_ddr4_density(uint8_t density_code,
                               uint8_t device_width_bits,
                               SmbusEepromDdr4Density *result);
bool smbus_eeprom_spd_set_identity(uint8_t *spd, size_t spd_size,
                                   bool is_ddr4,
                                   const SmbusEepromSpdConfig *config);

#endif
