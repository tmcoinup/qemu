/*
 * QEMU SMBus EEPROM device
 *
 * Copyright (c) 2007 Arastra, Inc.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qapi/error.h"
#include "hw/core/boards.h"
#include "hw/i2c/i2c.h"
#include "hw/i2c/smbus_slave.h"
#include "hw/core/qdev-properties.h"
#include "migration/vmstate.h"
#include "hw/i2c/smbus_eeprom.h"
#include "hw/i2c/smbus_eeprom_spd.h"
#include "qom/object.h"

//#define DEBUG

#define TYPE_SMBUS_EEPROM "smbus-eeprom"

OBJECT_DECLARE_SIMPLE_TYPE(SMBusEEPROMDevice, SMBUS_EEPROM)

#define SMBUS_EEPROM_SIZE 256

/*
 * QEMU 公共头没有提供“最接近整数”的无符号除法宏。SPD 时序换算需要
 * 就近选择 MTB，再把误差写进 FTB；用商和余数计算可避免 dividend
 * 加半个 divisor 时发生溢出。
 */
static uint32_t spd_div_round_closest_u32(uint32_t dividend,
                                          uint32_t divisor)
{
    return dividend / divisor +
           (dividend % divisor >= (divisor + 1) / 2);
}

struct SMBusEEPROMDevice {
    SMBusDevice smbusdev;
    uint8_t data[SMBUS_EEPROM_SIZE];
    uint8_t *init_data;
    uint8_t offset;
    bool accessed;
};

static uint8_t eeprom_receive_byte(SMBusDevice *dev)
{
    SMBusEEPROMDevice *eeprom = SMBUS_EEPROM(dev);
    uint8_t *data = eeprom->data;
    uint8_t val = data[eeprom->offset++];

    eeprom->accessed = true;
#ifdef DEBUG
    printf("eeprom_receive_byte: addr=0x%02x val=0x%02x\n",
           dev->i2c.address, val);
#endif
    return val;
}

static int eeprom_write_data(SMBusDevice *dev, uint8_t *buf, uint8_t len)
{
    SMBusEEPROMDevice *eeprom = SMBUS_EEPROM(dev);
    uint8_t *data = eeprom->data;

    eeprom->accessed = true;
#ifdef DEBUG
    printf("eeprom_write_byte: addr=0x%02x cmd=0x%02x val=0x%02x\n",
           dev->i2c.address, buf[0], buf[1]);
#endif
    /* len is guaranteed to be > 0 */
    eeprom->offset = buf[0];
    buf++;
    len--;

    for (; len > 0; len--) {
        data[eeprom->offset] = *buf++;
        eeprom->offset = (eeprom->offset + 1) % SMBUS_EEPROM_SIZE;
    }

    return 0;
}

static bool smbus_eeprom_vmstate_needed(void *opaque)
{
    SMBusEEPROMDevice *eeprom = opaque;

    return eeprom->accessed || smbus_vmstate_needed(&eeprom->smbusdev);
}

static const VMStateDescription vmstate_smbus_eeprom = {
    .name = "smbus-eeprom",
    .version_id = 1,
    .minimum_version_id = 1,
    .needed = smbus_eeprom_vmstate_needed,
    .fields = (const VMStateField[]) {
        VMSTATE_SMBUS_DEVICE(smbusdev, SMBusEEPROMDevice),
        VMSTATE_UINT8_ARRAY(data, SMBusEEPROMDevice, SMBUS_EEPROM_SIZE),
        VMSTATE_UINT8(offset, SMBusEEPROMDevice),
        VMSTATE_BOOL(accessed, SMBusEEPROMDevice),
        VMSTATE_END_OF_LIST()
    }
};

/*
 * Reset the EEPROM contents to the initial state on a reset.  This
 * isn't really how an EEPROM works, of course, but the general
 * principle of QEMU is to restore function on reset to what it would
 * be if QEMU was stopped and started.
 *
 * The proper thing to do would be to have a backing blockdev to hold
 * the contents and restore that on startup, and not do this on reset.
 * But until that time, act as if we had been stopped and restarted.
 */
static void smbus_eeprom_reset(DeviceState *dev)
{
    SMBusEEPROMDevice *eeprom = SMBUS_EEPROM(dev);

    memcpy(eeprom->data, eeprom->init_data, SMBUS_EEPROM_SIZE);
    eeprom->offset = 0;
}

static void smbus_eeprom_realize(DeviceState *dev, Error **errp)
{
    SMBusEEPROMDevice *eeprom = SMBUS_EEPROM(dev);

    smbus_eeprom_reset(dev);
    if (eeprom->init_data == NULL) {
        error_setg(errp, "init_data cannot be NULL");
    }
}

static void smbus_eeprom_class_initfn(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    SMBusDeviceClass *sc = SMBUS_DEVICE_CLASS(klass);

    dc->realize = smbus_eeprom_realize;
    device_class_set_legacy_reset(dc, smbus_eeprom_reset);
    sc->receive_byte = eeprom_receive_byte;
    sc->write_data = eeprom_write_data;
    dc->vmsd = &vmstate_smbus_eeprom;
    /* Reason: init_data */
    dc->user_creatable = false;
}

static const TypeInfo smbus_eeprom_types[] = {
    {
        .name          = TYPE_SMBUS_EEPROM,
        .parent        = TYPE_SMBUS_DEVICE,
        .instance_size = sizeof(SMBusEEPROMDevice),
        .class_init    = smbus_eeprom_class_initfn,
    },
};

DEFINE_TYPES(smbus_eeprom_types)

void smbus_eeprom_init_one(I2CBus *smbus, uint8_t address, uint8_t *eeprom_buf)
{
    DeviceState *dev;

    dev = qdev_new(TYPE_SMBUS_EEPROM);
    qdev_prop_set_uint8(dev, "address", address);
    /* FIXME: use an array of byte or block backend property? */
    SMBUS_EEPROM(dev)->init_data = eeprom_buf;
    qdev_realize_and_unref(dev, (BusState *)smbus, &error_fatal);
}

void smbus_eeprom_init(I2CBus *smbus, int nb_eeprom,
                       const uint8_t *eeprom_spd, int eeprom_spd_size)
{
    int i;
     /* XXX: make this persistent */

    assert(nb_eeprom <= 8);
    uint8_t *eeprom_buf = g_malloc0(8 * SMBUS_EEPROM_SIZE);
    if (eeprom_spd_size > 0) {
        memcpy(eeprom_buf, eeprom_spd, eeprom_spd_size);
    }

    for (i = 0; i < nb_eeprom; i++) {
        smbus_eeprom_init_one(smbus, 0x50 + i,
                              eeprom_buf + (i * SMBUS_EEPROM_SIZE));
    }
}

/*
 * Generate a DDR4 SPD (Serial Presence Detect) EEPROM image describing a
 * single DDR4 UDIMM. Only page 0 (bytes 0-255) is produced — the timing
 * fields HWiNFO/CPU-Z need to decode a module are all on page 0; module
 * manufacturer/serial/part live on page 1 (bytes 320+) and are separately
 * exposed via SMBIOS Type 17.
 *
 * Values target DDR4-2666 CL18-18-18-38-56 (JEDEC base profile for the
 * Kingston HyperX Fury HX426C16FB3A/4 at its default JEDEC speed). Kingston
 * ships the module with a CL16 XMP profile, but base SPD always carries
 * JEDEC-safe numbers.
 */
#define DDR4_SPD_SIZE 256
#define DDR4_MTB_PS   125   /* Medium Time Base in picoseconds */

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
    return crc & 0xFFFF;
}

/*
 * 将单条容量和 rank 数反推到每颗 DRAM 的密度编码。当前消费级画像固定
 * 64-bit、x8 颗粒，因此 module_MB = chip_Mbit * rank；不支持的奇数容量
 * 返回 -1，让上层不发布一份物理上不存在的 SPD。
 */
static int spd_density_code(uint32_t size_mb, uint8_t ranks)
{
    uint32_t density_mbit;

    if (ranks < 1 || ranks > 4 || size_mb % ranks != 0) {
        return -1;
    }
    density_mbit = size_mb / ranks;

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

uint8_t *spd_data_generate_ddr4_ex(uint32_t size_mb, uint32_t speed_mts,
                                    uint8_t ranks, uint16_t voltage_mv)
{
    uint8_t *spd = g_malloc0(DDR4_SPD_SIZE);
    SmbusEepromDdr4Density density;
    uint16_t crc;
    uint32_t tck_ps;
    uint8_t tck_mtb, tck_max_mtb;
    int8_t tck_ftb;
    uint16_t taa_ps, trcd_ps, trp_ps, tras_ps, trc_ps;
    uint16_t taa_mtb, trcd_mtb, trp_mtb, tras_mtb, trc_mtb;
    int density_code = spd_density_code(size_mb, ranks);

    if (density_code < 0 ||
        !smbus_eeprom_ddr4_density(density_code, &density)) {
        g_free(spd);
        return NULL;
    }
    if (!speed_mts) {
        speed_mts = 2400;
    }
    if (!voltage_mv) {
        voltage_mv = 1200;
    }

    /* Derive CL/tRCD/tRP/tRAS/tRC from JEDEC table for the requested speed.
     * Values quoted in picoseconds. 未核验速率必须拒绝，既不能套 2666 时序，
     * 也不能让 speed=1 在除法中触发进程崩溃。 */
    switch (speed_mts) {
    case 1866:
        taa_ps = 13920; trcd_ps = 13920; trp_ps = 13920;
        tras_ps = 34000; trc_ps = 47920;
        break;
    case 2133:
        taa_ps = 13130; trcd_ps = 13130; trp_ps = 13130;
        tras_ps = 33000; trc_ps = 46130;
        break;
    case 2400:
        taa_ps = 13320; trcd_ps = 13320; trp_ps = 13320;
        tras_ps = 32000; trc_ps = 45320;
        break;
    case 3200:
        taa_ps = 13750; trcd_ps = 13750; trp_ps = 13750;
        tras_ps = 32000; trc_ps = 45750;
        break;
    case 2666:
        /* DDR4-2666 CL18-18-18-38-56 JEDEC */
        taa_ps = 13500; trcd_ps = 13500; trp_ps = 13500;
        tras_ps = 28500; trc_ps = 42000;
        break;
    default:
        g_free(spd);
        return NULL;
    }
    tck_ps = 1000000U / (speed_mts / 2); /* speed_mts is double data rate */
    tck_mtb      = spd_div_round_closest_u32(tck_ps, DDR4_MTB_PS);
    tck_ftb      = tck_ps - tck_mtb * DDR4_MTB_PS;
    tck_max_mtb  = tck_mtb + 1;
    taa_mtb      = taa_ps  / DDR4_MTB_PS;
    trcd_mtb     = trcd_ps / DDR4_MTB_PS;
    trp_mtb      = trp_ps  / DDR4_MTB_PS;
    tras_mtb     = tras_ps / DDR4_MTB_PS;
    trc_mtb      = trc_ps  / DDR4_MTB_PS;

    /* Block 0: Base Configuration & DRAM Parameters ----------------- */
    /* 当前设备仅实现 256B，不得声称存在不可访问的 EE1004 第二页。 */
    spd[0]  = smbus_eeprom_ddr4_size_descriptor();
    spd[1]  = 0x10;   /* SPD revision 1.0 */
    spd[2]  = 0x0C;   /* DDR4 SDRAM */
    spd[3]  = 0x02;   /* UDIMM module type */
    /* 密度/bank 与 row/column 必须来自同一映射，防止容量几何互相冲突。 */
    spd[4]  = density.density_banks;
    spd[5]  = density.addressing;
    spd[6]  = 0x00;   /* Monolithic DRAM package */
    /* DDR4 标准工作电压是 1.2V；不一致的 manifest 不应生成 SPD。 */
    spd[11] = voltage_mv == 1200 ? 0x01 : 0x00;
    /* Module organization: rank 数来自 Type 17，颗粒宽度为 x8。 */
    spd[12] = ((ranks - 1) << 3) | 0x01;
    /* Module bus width: 64-bit primary, no ECC extension. */
    spd[13] = (0 << 3) | 0x03;
    spd[14] = 0x00;   /* MTB = 125ps, FTB = 1ps */
    spd[17] = 0x00;
    spd[18] = tck_mtb;
    spd[19] = tck_max_mtb;
    /* CAS latencies supported: CL10..CL19 (covers 2133/2400/2666 JEDEC). */
    spd[20] = 0xF8;   /* CL10..CL14 */
    spd[21] = 0x1F;   /* CL15..CL19 */
    spd[22] = 0x00;
    spd[23] = 0x00;
    spd[24] = (uint8_t)taa_mtb;
    spd[25] = (uint8_t)trcd_mtb;
    spd[26] = (uint8_t)trp_mtb;
    /* Byte 27: tRAS high nibble (bits [3:0]) + tRC high nibble (bits [7:4]) */
    spd[27] = ((trc_mtb >> 8) & 0x0F) << 4 | ((tras_mtb >> 8) & 0x0F);
    spd[28] = (uint8_t)(tras_mtb & 0xFF);
    spd[29] = (uint8_t)(trc_mtb  & 0xFF);
    /* tRFC1/2/4 采用 125ps MTB、小端编码，并按颗粒密度分别计算。 */
    spd[30] = density.trfc1_mtb & 0xff;
    spd[31] = density.trfc1_mtb >> 8;
    spd[32] = density.trfc2_mtb & 0xff;
    spd[33] = density.trfc2_mtb >> 8;
    spd[34] = density.trfc4_mtb & 0xff;
    spd[35] = density.trfc4_mtb >> 8;
    spd[36] = 0x00;          /* tFAW hi nibble */
    spd[37] = (uint8_t)(21000 / DDR4_MTB_PS);   /* 21ns */
    spd[38] = (uint8_t)(5300  / DDR4_MTB_PS);   /* tRRD_S ~5.3ns */
    spd[39] = (uint8_t)(6400  / DDR4_MTB_PS);   /* tRRD_L 6.4ns */
    spd[40] = (uint8_t)(6400  / DDR4_MTB_PS);   /* tCCD_L 6.4ns */
    /* Byte 125 是 tCKAVGmin 的 1ps fine offset，可精确表达 2400/2133。 */
    spd[125] = tck_ftb;

    /* Block 0 CRC over bytes 0-125 placed at 126-127 (little-endian). */
    crc = spd_crc16(spd, 126);
    spd[126] = (uint8_t)(crc & 0xFF);
    spd[127] = (uint8_t)(crc >> 8);

    /* Block 1: Module-specific (UDIMM) ------------------------------ */
    spd[128] = 0x11;   /* Raw card ext 0 + nominal height 1 (≤32mm) */
    spd[129] = 0x11;   /* Module max thickness 1mm front/back */
    spd[130] = 0x00;   /* Reference Raw Card A, rev 0 */
    spd[131] = 0x00;
    /* Block 1 CRC over bytes 128-253 placed at 254-255. */
    crc = spd_crc16(spd + 128, 126);
    spd[254] = (uint8_t)(crc & 0xFF);
    spd[255] = (uint8_t)(crc >> 8);

    return spd;
}

uint8_t *spd_data_generate_ddr4(uint32_t size_mb, uint32_t speed_mts)
{
    return spd_data_generate_ddr4_ex(size_mb, speed_mts, 1, 1200);
}

uint8_t *spd_data_generate_ddr3(uint32_t size_mb, uint32_t speed_mts,
                                uint8_t ranks, uint16_t voltage_mv)
{
    uint8_t *spd;
    uint16_t crc;
    uint16_t tras_mtb;
    uint16_t trc_mtb;
    uint8_t tck_mtb;
    int8_t tck_ftb;
    int density_code = spd_density_code(size_mb, ranks);

    if (density_code < 0) {
        return NULL;
    }
    if (!speed_mts) {
        speed_mts = 1600;
    }
    if (!voltage_mv) {
        voltage_mv = 1500;
    }

    spd = g_malloc0(256);
    tck_mtb = spd_div_round_closest_u32(2000000U,
                                        speed_mts * DDR4_MTB_PS);
    tck_ftb = spd_div_round_closest_u32(2000000U, speed_mts) -
               tck_mtb * DDR4_MTB_PS;
    tras_mtb = DIV_ROUND_UP(35000U, DDR4_MTB_PS);
    trc_mtb = DIV_ROUND_UP(48750U, DDR4_MTB_PS);

    /* DDR3 SPD 1.1、256-byte EEPROM、UDIMM。 */
    spd[0] = 0x92;
    spd[1] = 0x11;
    spd[2] = DDR3;
    spd[3] = 0x02;
    spd[4] = density_code;
    spd[5] = 0x21; /* 16 row / 10 column address bits */
    /* bit0=不支持1.5V、bit1=支持1.35V；默认 1.5V 时两位均为 0。 */
    spd[6] = voltage_mv == 1350 ? 0x02 : 0x00;
    spd[7] = ((ranks - 1) << 3) | 0x01; /* rank + x8 */
    spd[8] = 0x03; /* 64-bit、无 ECC */
    spd[9] = 0x11; /* FTB 1ps */
    spd[10] = 1;
    spd[11] = 8;   /* MTB 125ps */
    spd[12] = tck_mtb;
    spd[14] = 0xfe; /* CL 5..11 */
    spd[15] = 0x01; /* CL 12 */
    spd[16] = DIV_ROUND_UP(13750U, DDR4_MTB_PS); /* tAA */
    spd[17] = 0x78; /* write recovery */
    spd[18] = spd[16]; /* tRCD */
    spd[20] = spd[16]; /* tRP */
    spd[21] = ((trc_mtb >> 8) << 4) | (tras_mtb >> 8);
    spd[22] = tras_mtb & 0xff;
    spd[23] = trc_mtb & 0xff;
    spd[24] = 0x20; /* tRFC low */
    spd[25] = 0x08; /* tRFC high */
    spd[27] = 0x3c;
    spd[28] = 0x3c;
    spd[29] = 0x1e;
    spd[30] = 0x1e;
    spd[31] = 0x00;
    spd[32] = 0x00;
    spd[34] = tck_ftb; /* DDR3 tCKmin fine offset，单位 1ps */
    crc = spd_crc16(spd, 126);
    spd[126] = crc & 0xff;
    spd[127] = crc >> 8;
    return spd;
}

/* Generate SDRAM SPD EEPROM data describing a module of type and size */
uint8_t *spd_data_generate(enum sdram_type type, ram_addr_t ram_size)
{
    uint8_t *spd;
    uint8_t nbanks;
    uint16_t density;
    uint32_t size;
    int min_log2, max_log2, sz_log2;
    int i;

    switch (type) {
    case SDR:
        min_log2 = 2;
        max_log2 = 9;
        break;
    case DDR:
        min_log2 = 5;
        max_log2 = 12;
        break;
    case DDR2:
        min_log2 = 7;
        max_log2 = 14;
        break;
    default:
        g_assert_not_reached();
    }
    size = ram_size >> 20; /* work in terms of megabytes */
    sz_log2 = 31 - clz32(size);
    size = 1U << sz_log2;
    assert(ram_size == size * MiB);
    assert(sz_log2 >= min_log2);

    nbanks = 1;
    while (sz_log2 > max_log2 && nbanks < 8) {
        sz_log2--;
        nbanks *= 2;
    }

    assert(size == (1ULL << sz_log2) * nbanks);

    /* split to 2 banks if possible to avoid a bug in MIPS Malta firmware */
    if (nbanks == 1 && sz_log2 > min_log2) {
        sz_log2--;
        nbanks++;
    }

    density = 1ULL << (sz_log2 - 2);
    switch (type) {
    case DDR2:
        density = (density & 0xe0) | (density >> 8 & 0x1f);
        break;
    case DDR:
        density = (density & 0xf8) | (density >> 8 & 0x07);
        break;
    case SDR:
    default:
        density &= 0xff;
        break;
    }

    spd = g_malloc0(256);
    spd[0] = 128;   /* data bytes in EEPROM */
    spd[1] = 8;     /* log2 size of EEPROM */
    spd[2] = type;
    spd[3] = 13;    /* row address bits */
    spd[4] = 10;    /* column address bits */
    spd[5] = (type == DDR2 ? nbanks - 1 : nbanks);
    spd[6] = 64;    /* module data width */
                    /* reserved / data width high */
    spd[8] = 4;     /* interface voltage level */
    spd[9] = 0x25;  /* highest CAS latency */
    spd[10] = 1;    /* access time */
                    /* DIMM configuration 0 = non-ECC */
    spd[12] = 0x82; /* refresh requirements */
    spd[13] = 8;    /* primary SDRAM width */
                    /* ECC SDRAM width */
    spd[15] = (type == DDR2 ? 0 : 1); /* reserved / delay for random col rd */
    spd[16] = 12;   /* burst lengths supported */
    spd[17] = 4;    /* banks per SDRAM device */
    spd[18] = 12;   /* ~CAS latencies supported */
    spd[19] = (type == DDR2 ? 0 : 1); /* reserved / ~CS latencies supported */
    spd[20] = 2;    /* DIMM type / ~WE latencies */
    spd[21] = (type < DDR2 ? 0x20 : 0); /* module features */
                    /* memory chip features */
    spd[23] = 0x12; /* clock cycle time @ medium CAS latency */
                    /* data access time */
                    /* clock cycle time @ short CAS latency */
                    /* data access time */
    spd[27] = 20;   /* min. row precharge time */
    spd[28] = 15;   /* min. row active row delay */
    spd[29] = 20;   /* min. ~RAS to ~CAS delay */
    spd[30] = 45;   /* min. active to precharge time */
    spd[31] = density;
    spd[32] = 20;   /* addr/cmd setup time */
    spd[33] = 8;    /* addr/cmd hold time */
    spd[34] = 20;   /* data input setup time */
    spd[35] = 8;    /* data input hold time */
    spd[36] = (type == DDR2 ? 13 << 2 : 0); /* min. write recovery time */

    /* checksum */
    for (i = 0; i < 63; i++) {
        spd[63] += spd[i];
    }
    return spd;
}
