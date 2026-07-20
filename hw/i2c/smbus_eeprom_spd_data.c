/*
 * QEMU DDR3/DDR4 SPD 数据生成器
 *
 * Copyright (c) 2026 VMate contributors
 * SPDX-License-Identifier: MIT
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "hw/i2c/smbus_eeprom.h"

#define SPD_MTB_PS 125

/*
 * QEMU 公共头没有提供“最接近整数”的无符号除法宏。
 * SPD 时序换算需要就近选择 MTB，再把误差写进 FTB。
 * 用商和余数计算可避免 dividend 加半个 divisor 时溢出。
 */
static uint32_t spd_div_round_closest_u32(uint32_t dividend,
                                          uint32_t divisor)
{
    return dividend / divisor +
           (dividend % divisor >= (divisor + 1) / 2);
}

static uint16_t spd_crc16(const uint8_t *buf, size_t len)
{
    uint32_t crc = 0;
    size_t i;
    int j;

    for (i = 0; i < len; i++) {
        crc ^= (uint32_t)buf[i] << 8;
        for (j = 0; j < 8; j++) {
            if (crc & 0x8000) {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc <<= 1;
            }
        }
    }
    return crc & 0xffff;
}

/*
 * 将单条容量、rank 和颗粒宽度反推到每颗 DRAM 的密度编码。
 * 当前消费级画像固定 64-bit 总线，
 * 因此 module_MB = chip_Mbit * 8 / width * rank。
 * 不支持的奇数容量返回 -1，避免发布物理上不存在的 SPD。
 */
static int spd_density_code(uint32_t size_mb, uint8_t ranks,
                            uint8_t device_width_bits)
{
    uint64_t density_numerator;
    uint32_t density_mbit;

    if (ranks < 1 || ranks > 4 ||
        (device_width_bits != 4 && device_width_bits != 8 &&
         device_width_bits != 16 && device_width_bits != 32)) {
        return -1;
    }
    density_numerator = (uint64_t)size_mb * device_width_bits;
    if (density_numerator % (8 * ranks) != 0) {
        return -1;
    }
    density_mbit = density_numerator / (8 * ranks);

    switch (density_mbit) {
    case 256:   return 0;
    case 512:   return 1;
    case 1024:  return 2;
    case 2048:  return 3;
    case 4096:  return 4;
    case 8192:  return 5;
    case 16384: return 6;
    default:    return -1;
    }
}

static int spd_device_width_code(uint8_t device_width_bits)
{
    switch (device_width_bits) {
    case 4:  return 0;
    case 8:  return 1;
    case 16: return 2;
    case 32: return 3;
    default: return -1;
    }
}

static bool spd_ddr3_geometry(int density_code, uint8_t device_width_bits,
                              uint8_t *addressing, uint16_t *trfc_mtb)
{
    int width_log2;
    int row_bits;
    uint16_t trfc_ns;

    switch (device_width_bits) {
    case 4:
        width_log2 = 2;
        break;
    case 8:
        width_log2 = 3;
        break;
    case 16:
        width_log2 = 4;
        break;
    case 32:
        width_log2 = 5;
        break;
    default:
        return false;
    }
    switch (density_code) {
    case 2: /* 1Gb */
        trfc_ns = 110;
        break;
    case 3: /* 2Gb */
        trfc_ns = 160;
        break;
    case 4: /* 4Gb */
        trfc_ns = 260;
        break;
    case 5: /* 8Gb */
        trfc_ns = 350;
        break;
    default:
        return false;
    }

    /*
     * DDR3 普通 UDIMM 使用 8 banks 和 10 个 column bits。
     * 颗粒密度与位宽共同决定 row bits；例如 2Gb x8 和 4Gb x16
     * 都是 15 row bits，不能把所有料号固定写成 16 row bits。
     */
    row_bits = 15 + density_code - width_log2;
    if (row_bits < 12 || row_bits > 16) {
        return false;
    }
    *addressing = ((row_bits - 12) << 3) | 0x01;
    *trfc_mtb = (uint32_t)trfc_ns * 1000 / SPD_MTB_PS;
    return true;
}

static bool spd_ddr4_timings(uint32_t speed_mts, uint16_t *taa_ps,
                             uint16_t *trcd_ps, uint16_t *trp_ps,
                             uint16_t *tras_ps, uint16_t *trc_ps)
{
    switch (speed_mts) {
    case 1866:
        *taa_ps = 13920;
        *trcd_ps = 13920;
        *trp_ps = 13920;
        *tras_ps = 34000;
        *trc_ps = 47920;
        return true;
    case 2133:
        *taa_ps = 13130;
        *trcd_ps = 13130;
        *trp_ps = 13130;
        *tras_ps = 33000;
        *trc_ps = 46130;
        return true;
    case 2400:
        *taa_ps = 13750;
        *trcd_ps = 13750;
        *trp_ps = 13750;
        *tras_ps = 32000;
        *trc_ps = 45750;
        return true;
    case 2666:
        *taa_ps = 13500;
        *trcd_ps = 13500;
        *trp_ps = 13500;
        *tras_ps = 28500;
        *trc_ps = 42000;
        return true;
    case 3200:
        *taa_ps = 13750;
        *trcd_ps = 13750;
        *trp_ps = 13750;
        *tras_ps = 32000;
        *trc_ps = 45750;
        return true;
    default:
        return false;
    }
}

static bool spd_ddr3_timings(uint32_t speed_mts, uint16_t *taa_ps,
                             uint16_t *trcd_ps, uint16_t *trp_ps,
                             uint16_t *tras_ps, uint16_t *trc_ps,
                             uint8_t *cas_low, uint8_t *cas_high)
{
    switch (speed_mts) {
    case 1333:
        *taa_ps = 13125;
        *trcd_ps = 13125;
        *trp_ps = 13125;
        *tras_ps = 36000;
        *trc_ps = 49125;
        *cas_low = 0x3c;  /* CL6..CL9 */
        *cas_high = 0x00;
        return true;
    case 1600:
        *taa_ps = 13125;
        *trcd_ps = 13125;
        *trp_ps = 13125;
        *tras_ps = 35000;
        *trc_ps = 48125;
        *cas_low = 0xfc;  /* CL6..CL11 */
        *cas_high = 0x00;
        return true;
    default:
        return false;
    }
}

static bool spd_has_verified_ddr4_raw_card(const SmbusEepromSpdConfig *config)
{
    if (!config->manufacturer || !config->part_number ||
        g_ascii_strcasecmp(config->manufacturer, "Samsung")) {
        return false;
    }
    return !strcmp(config->part_number, "M378A5644EB0-CRC") ||
           !strcmp(config->part_number, "M378A5244CB0-CRC");
}

uint8_t *spd_data_generate_ddr4(const SmbusEepromSpdConfig *config)
{
    g_autofree uint8_t *spd = NULL;
    SmbusEepromDdr4Density density;
    uint16_t crc;
    uint32_t tck_ps;
    uint8_t tck_mtb;
    int8_t tck_ftb;
    uint16_t taa_ps, trcd_ps, trp_ps, tras_ps, trc_ps;
    uint16_t taa_mtb, trcd_mtb, trp_mtb, tras_mtb, trc_mtb;
    uint16_t tfaw_ps, trrd_s_ps, trrd_l_ps;
    uint16_t tfaw_mtb, trrd_s_mtb, trrd_l_mtb, tccd_l_mtb;
    size_t spd_size;
    int density_code;
    int device_width_code;

    if (!config || config->voltage_mv != 1200 || !config->speed_mts) {
        return NULL;
    }
    density_code = spd_density_code(config->size_mb, config->ranks,
                                    config->device_width_bits);
    device_width_code = spd_device_width_code(config->device_width_bits);
    if (density_code < 0 ||
        device_width_code < 0 ||
        !smbus_eeprom_ddr4_density(density_code,
                                   config->device_width_bits, &density) ||
        !spd_ddr4_timings(config->speed_mts, &taa_ps, &trcd_ps, &trp_ps,
                          &tras_ps, &trc_ps)) {
        return NULL;
    }

    spd_size = config->ee1004 ? SMBUS_EE1004_SIZE :
                                SMBUS_EEPROM_PAGE_SIZE;
    spd = g_malloc0(spd_size);
    tck_ps = 2000000U / config->speed_mts;
    tck_mtb = spd_div_round_closest_u32(tck_ps, SPD_MTB_PS);
    tck_ftb = tck_ps - tck_mtb * SPD_MTB_PS;
    taa_mtb = taa_ps / SPD_MTB_PS;
    trcd_mtb = trcd_ps / SPD_MTB_PS;
    trp_mtb = trp_ps / SPD_MTB_PS;
    tras_mtb = tras_ps / SPD_MTB_PS;
    trc_mtb = trc_ps / SPD_MTB_PS;
    if (config->device_width_bits == 16) {
        tfaw_ps = 30000;
        trrd_s_ps = 5300;
        trrd_l_ps = 6400;
    } else {
        tfaw_ps = 21000;
        trrd_s_ps = 3300;
        trrd_l_ps = 4900;
    }
    tfaw_mtb = DIV_ROUND_UP(tfaw_ps, SPD_MTB_PS);
    trrd_s_mtb = DIV_ROUND_UP(trrd_s_ps, SPD_MTB_PS);
    trrd_l_mtb = DIV_ROUND_UP(trrd_l_ps, SPD_MTB_PS);
    tccd_l_mtb = DIV_ROUND_UP(5000U, SPD_MTB_PS);

    /* Block 0：基础配置和 DRAM 参数。 */
    spd[0] = smbus_eeprom_ddr4_size_descriptor(config->ee1004);
    spd[1] = 0x11;   /* SPD revision 1.1 */
    spd[2] = DDR4;
    spd[3] = 0x02;   /* UDIMM */
    spd[4] = density.density_banks;
    spd[5] = density.addressing;
    spd[6] = 0x00;   /* 单片封装 */
    spd[7] = 0x08;   /* Unlimited MAC */
    spd[11] = 0x03;  /* 1.2V 可工作且可耐受 */
    spd[12] = ((config->ranks - 1) << 3) | device_width_code;
    spd[13] = 0x03;  /* 64-bit、无 ECC */
    spd[17] = 0x00;  /* MTB=125ps、FTB=1ps */
    spd[18] = tck_mtb;
    spd[19] = DIV_ROUND_UP(1600U, SPD_MTB_PS);
    spd[20] = 0xf8;  /* CL10..CL14 */
    spd[21] = 0x0f;  /* CL15..CL18 */
    spd[24] = taa_mtb;
    spd[25] = trcd_mtb;
    spd[26] = trp_mtb;
    spd[27] = ((trc_mtb >> 8) & 0x0f) << 4 |
              ((tras_mtb >> 8) & 0x0f);
    spd[28] = tras_mtb & 0xff;
    spd[29] = trc_mtb & 0xff;
    spd[30] = density.trfc1_mtb & 0xff;
    spd[31] = density.trfc1_mtb >> 8;
    spd[32] = density.trfc2_mtb & 0xff;
    spd[33] = density.trfc2_mtb >> 8;
    spd[34] = density.trfc4_mtb & 0xff;
    spd[35] = density.trfc4_mtb >> 8;
    spd[36] = (tfaw_mtb >> 8) & 0x0f;
    spd[37] = tfaw_mtb & 0xff;
    spd[38] = trrd_s_mtb;
    spd[39] = trrd_l_mtb;
    spd[40] = tccd_l_mtb;
    spd[42] = DIV_ROUND_UP(15000U, SPD_MTB_PS);
    spd[44] = DIV_ROUND_UP(2500U, SPD_MTB_PS);
    spd[45] = DIV_ROUND_UP(7500U, SPD_MTB_PS);
    spd[117] = (int8_t)(5000 - tccd_l_mtb * SPD_MTB_PS);
    spd[118] = (int8_t)(trrd_l_ps - trrd_l_mtb * SPD_MTB_PS);
    spd[119] = (int8_t)(trrd_s_ps - trrd_s_mtb * SPD_MTB_PS);
    spd[124] = (int8_t)(1600 - spd[19] * SPD_MTB_PS);
    spd[125] = tck_ftb;
    crc = spd_crc16(spd, 126);
    spd[126] = crc & 0xff;
    spd[127] = crc >> 8;

    /* Block 1：消费级 UDIMM 原始卡参数。 */
    spd[128] = 0x11;
    spd[129] = 0x11;
    spd[130] = 0x1f;  /* ZZ：目录没有精确 raw-card/revision 证据 */
    if (spd_has_verified_ddr4_raw_card(config)) {
        spd[130] = 0x02;
    }
    spd[131] = 0x00;
    crc = spd_crc16(spd + 128, 126);
    spd[254] = crc & 0xff;
    spd[255] = crc >> 8;

    /*
     * EE1004 page 1 的 320+ 字节保存厂商、序列号和料号。
     * 身份无法精确编码时返回 NULL，
     * 让主板层整组放弃 SPD，而不是发布错误品牌。
     */
    if (config->ee1004 &&
        !smbus_eeprom_spd_set_identity(spd, spd_size, true, config)) {
        return NULL;
    }
    return g_steal_pointer(&spd);
}

uint8_t *spd_data_generate_ddr3(const SmbusEepromSpdConfig *config)
{
    g_autofree uint8_t *spd = NULL;
    uint16_t crc;
    uint16_t tras_mtb;
    uint16_t trc_mtb;
    uint16_t taa_ps, trcd_ps, trp_ps, tras_ps, trc_ps;
    uint8_t tck_mtb;
    int8_t tck_ftb;
    uint8_t addressing;
    uint8_t cas_low, cas_high;
    uint16_t trfc_mtb;
    uint16_t tfaw_mtb;
    int density_code;
    int device_width_code;

    if (!config || !config->speed_mts ||
        (config->voltage_mv != 1350 && config->voltage_mv != 1500)) {
        return NULL;
    }
    density_code = spd_density_code(config->size_mb, config->ranks,
                                    config->device_width_bits);
    device_width_code = spd_device_width_code(config->device_width_bits);
    if (density_code < 0 || device_width_code < 0 ||
        !spd_ddr3_geometry(density_code, config->device_width_bits,
                           &addressing, &trfc_mtb) ||
        !spd_ddr3_timings(config->speed_mts, &taa_ps, &trcd_ps, &trp_ps,
                          &tras_ps, &trc_ps, &cas_low, &cas_high)) {
        return NULL;
    }

    spd = g_malloc0(SMBUS_EEPROM_PAGE_SIZE);
    tck_mtb = spd_div_round_closest_u32(2000000U,
                                        config->speed_mts * SPD_MTB_PS);
    tck_ftb = spd_div_round_closest_u32(2000000U, config->speed_mts) -
               tck_mtb * SPD_MTB_PS;
    tras_mtb = DIV_ROUND_UP(tras_ps, SPD_MTB_PS);
    trc_mtb = DIV_ROUND_UP(trc_ps, SPD_MTB_PS);
    if (config->device_width_bits == 16) {
        tfaw_mtb = DIV_ROUND_UP(config->speed_mts == 1333 ?
                                45000U : 40000U, SPD_MTB_PS);
    } else {
        tfaw_mtb = DIV_ROUND_UP(30000U, SPD_MTB_PS);
    }

    spd[0] = 0x92;  /* 176B used、256B total、CRC 覆盖 0..116 */
    spd[1] = 0x11;
    spd[2] = DDR3;
    spd[3] = 0x02;  /* UDIMM */
    spd[4] = density_code;
    spd[5] = addressing;
    spd[6] = config->voltage_mv == 1350 ? 0x02 : 0x00;
    spd[7] = ((config->ranks - 1) << 3) | device_width_code;
    spd[8] = 0x03;  /* 64-bit、无 ECC */
    spd[9] = 0x11;  /* FTB 1ps */
    spd[10] = 1;
    spd[11] = 8;    /* MTB 125ps */
    spd[12] = tck_mtb;
    spd[14] = cas_low;
    spd[15] = cas_high;
    spd[16] = DIV_ROUND_UP(taa_ps, SPD_MTB_PS);
    spd[17] = 0x78;
    spd[18] = DIV_ROUND_UP(trcd_ps, SPD_MTB_PS);
    spd[19] = DIV_ROUND_UP(6000U, SPD_MTB_PS);
    if (config->device_width_bits == 16) {
        spd[19] = DIV_ROUND_UP(7500U, SPD_MTB_PS);
    }
    spd[20] = DIV_ROUND_UP(trp_ps, SPD_MTB_PS);
    spd[21] = ((trc_mtb >> 8) << 4) | (tras_mtb >> 8);
    spd[22] = tras_mtb & 0xff;
    spd[23] = trc_mtb & 0xff;
    spd[24] = trfc_mtb & 0xff;
    spd[25] = trfc_mtb >> 8;
    spd[26] = DIV_ROUND_UP(7500U, SPD_MTB_PS);
    spd[27] = 0x3c;
    spd[28] = (tfaw_mtb >> 8) & 0x0f;
    spd[29] = tfaw_mtb & 0xff;
    spd[34] = tck_ftb;
    spd[60] = 0x0f;  /* 标准桌面 UDIMM：模块高度 29～30 mm */
    spd[61] = 0x11;  /* 正反面最大厚度均为 1～2 mm */
    spd[62] = 0x1f;  /* ZZ：短料号不能唯一确定 raw-card/revision */
    crc = spd_crc16(spd, 117);
    spd[126] = crc & 0xff;
    spd[127] = crc >> 8;

    if (!smbus_eeprom_spd_set_identity(spd, SMBUS_EEPROM_PAGE_SIZE, false,
                                       config)) {
        return NULL;
    }
    return g_steal_pointer(&spd);
}
