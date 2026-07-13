/*
 * QEMU DDR4 SPD 密度与地址几何映射
 *
 * Copyright (c) 2026 VMate contributors
 * SPDX-License-Identifier: MIT
 */

#include "qemu/osdep.h"
#include "hw/i2c/smbus_eeprom_spd.h"

#define DDR4_MTB_PS 125

/*
 * 中文注释：当前 SMBus EEPROM 模型只有 256 字节地址空间，也没有 EE1004
 * 页选择协议，因此必须诚实声明“已使用 256B、总计 256B”。0x23 会声明
 * 已使用 384B、总计 512B，与客体实际可读范围自相矛盾。
 */
uint8_t smbus_eeprom_ddr4_size_descriptor(void)
{
    return 0x12;
}

static uint16_t nanoseconds_to_mtb(uint16_t nanoseconds)
{
    return (uint32_t)nanoseconds * 1000 / DDR4_MTB_PS;
}

bool smbus_eeprom_ddr4_density(uint8_t density_code,
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

    result->density_banks = 0x80 | density_code;
    result->addressing = ((density_code - 1) << 3) | 0x01;
    result->trfc1_mtb = nanoseconds_to_mtb(trfc1_ns);
    result->trfc2_mtb = nanoseconds_to_mtb(trfc2_ns);
    result->trfc4_mtb = nanoseconds_to_mtb(trfc4_ns);
    return true;
}
