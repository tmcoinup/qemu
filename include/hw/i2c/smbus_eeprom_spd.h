/*
 * QEMU DDR4 SPD 几何参数辅助接口
 *
 * Copyright (c) 2026 VMate contributors
 * SPDX-License-Identifier: MIT
 */

#ifndef HW_SMBUS_EEPROM_SPD_H
#define HW_SMBUS_EEPROM_SPD_H

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

uint8_t smbus_eeprom_ddr4_size_descriptor(void);
bool smbus_eeprom_ddr4_density(uint8_t density_code,
                               SmbusEepromDdr4Density *result);

#endif
