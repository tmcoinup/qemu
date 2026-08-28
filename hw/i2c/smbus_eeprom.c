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
#include "qom/object.h"

//#define DEBUG

#define TYPE_SMBUS_EEPROM "smbus-eeprom"

OBJECT_DECLARE_SIMPLE_TYPE(SMBusEEPROMDevice, SMBUS_EEPROM)

#define SMBUS_EEPROM_SIZE 256

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

    assert(nb_eeprom <= SMBUS_EEPROM_MAX_SLOTS);
    uint8_t *eeprom_buf = g_malloc0(SMBUS_EEPROM_MAX_SLOTS *
                                    SMBUS_EEPROM_SIZE);
    if (eeprom_spd_size > 0) {
        memcpy(eeprom_buf, eeprom_spd, eeprom_spd_size);
    }

    for (i = 0; i < nb_eeprom; i++) {
        smbus_eeprom_init_one(smbus, 0x50 + i,
                              eeprom_buf + (i * SMBUS_EEPROM_SIZE));
    }
}

#define MODERN_SPD_SIZE 256
#define SPD_MTB_PS       125   /* Medium Time Base in picoseconds */
#define SPD_FTB_PS       1     /* Fine Time Base in picoseconds */

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
 * Split a timing into the unsigned MTB field and signed FTB correction used
 * by DDR3/DDR4 SPD. All values passed here are generator constants, so an
 * out-of-range result indicates a programming error rather than bad input.
 */
static void spd_encode_timing(uint32_t timing_ps, uint16_t *mtb,
                              int8_t *ftb)
{
    uint32_t rounded_mtb = (timing_ps + SPD_MTB_PS / 2) / SPD_MTB_PS;
    int32_t remainder = (int32_t)timing_ps -
                        (int32_t)(rounded_mtb * SPD_MTB_PS);

    g_assert(rounded_mtb <= UINT16_MAX);
    g_assert(remainder >= INT8_MIN && remainder <= INT8_MAX);
    *mtb = rounded_mtb;
    *ftb = remainder / SPD_FTB_PS;
}

static bool spd_ddr3_geometry(const SmbusEepromDdr3Config *config,
                              uint8_t *density_code, uint8_t *addressing,
                              uint8_t *organization, uint16_t *trfc_mtb,
                              Error **errp)
{
    /*
     * Keep this table deliberately narrow.  Every entry describes a common
     * non-ECC 64-bit desktop UDIMM geometry and has a self-consistent DRAM
     * density, row/column layout and refresh time.
     */
    if (config->size_mb == 2048 && config->ranks == 1 &&
        config->device_width_bits == 16) {
        *density_code = 0x04; /* 4 Gbit */
        *addressing = 0x19;   /* 15 row bits, 10 column bits */
        *organization = 0x02; /* One rank, x16 */
        *trfc_mtb = 0x0820;   /* 260 ns */
        return true;
    }
    if (config->size_mb == 2048 && config->ranks == 1 &&
        config->device_width_bits == 8) {
        *density_code = 0x03; /* 2 Gbit */
        *addressing = 0x19;   /* 15 row bits, 10 column bits */
        *organization = 0x01; /* One rank, x8 */
        *trfc_mtb = 0x0500;   /* 160 ns */
        return true;
    }
    if (config->size_mb == 4096 && config->ranks == 1 &&
        config->device_width_bits == 8) {
        *density_code = 0x04; /* 4 Gbit */
        *addressing = 0x21;   /* 16 row bits, 10 column bits */
        *organization = 0x01; /* One rank, x8 */
        *trfc_mtb = 0x0820;   /* 260 ns */
        return true;
    }
    if (config->size_mb == 4096 && config->ranks == 2 &&
        config->device_width_bits == 8) {
        *density_code = 0x03; /* 2 Gbit */
        *addressing = 0x19;   /* 15 row bits, 10 column bits */
        *organization = 0x09; /* Two ranks, x8 */
        *trfc_mtb = 0x0500;   /* 160 ns */
        return true;
    }

    error_setg(errp, "unsupported DDR3 SPD geometry: %u MB, %u rank(s), "
               "x%u devices", config->size_mb, config->ranks,
               config->device_width_bits);
    return false;
}

static bool spd_ddr3_identity_is_valid(
    const SmbusEepromDdr3Config *config, Error **errp)
{
    static const uint8_t serial_zero[4];
    static const uint8_t serial_one[4] = { 0, 0, 0, 1 };
    static const uint8_t serial_ff[4] = { 0xff, 0xff, 0xff, 0xff };
    size_t length;
    size_t i;

    if (!config->identity_configured) {
        return true;
    }
    if (config->module_mfr_jep106[0] == 0 &&
        config->module_mfr_jep106[1] == 0) {
        error_setg(errp, "DDR3 SPD module manufacturer JEP106 cannot be "
                   "0000");
        return false;
    }
    if (!memcmp(config->serial, serial_zero, sizeof(serial_zero)) ||
        !memcmp(config->serial, serial_one, sizeof(serial_one)) ||
        !memcmp(config->serial, serial_ff, sizeof(serial_ff))) {
        error_setg(errp, "DDR3 SPD serial cannot be reserved value %02X%02X"
                   "%02X%02X", config->serial[0], config->serial[1],
                   config->serial[2], config->serial[3]);
        return false;
    }

    length = strnlen(config->part_number, sizeof(config->part_number));
    if (!length || length > SMBUS_EEPROM_DDR3_PART_NUMBER_LEN) {
        error_setg(errp, "DDR3 SPD part number must contain 1 to %u "
                   "printable ASCII characters",
                   SMBUS_EEPROM_DDR3_PART_NUMBER_LEN);
        return false;
    }
    for (i = 0; i < length; i++) {
        uint8_t ch = config->part_number[i];

        if (ch < 0x20 || ch > 0x7e) {
            error_setg(errp, "DDR3 SPD part number contains a non-printable "
                       "ASCII character at offset %zu", i);
            return false;
        }
    }
    return true;
}

/*
 * Generate a DDR3 desktop UDIMM using explicit per-slot geometry.  The
 * identity area follows DDR3 SPD bytes 117 onward and is optional so legacy
 * callers retain their byte-for-byte anonymous SPD data.
 */
uint8_t *spd_data_generate_ddr3_config(
    const SmbusEepromDdr3Config *config, Error **errp)
{
    uint8_t density_code;
    uint8_t addressing;
    uint8_t organization;
    uint16_t trfc_mtb;
    uint8_t *spd;
    uint16_t crc;
    size_t part_length;

    if (!config) {
        error_setg(errp, "DDR3 SPD configuration cannot be NULL");
        return NULL;
    }
    if (config->size_mb != 2048 && config->size_mb != 4096) {
        error_setg(errp, "DDR3 SPD module size must be 2048 or 4096 MB "
                   "(requested %u MB)", config->size_mb);
        return NULL;
    }
    if (config->speed_mts != 1333 && config->speed_mts != 1600 &&
        config->speed_mts != 1866) {
        error_setg(errp, "DDR3 SPD speed must be 1333, 1600 or 1866 MT/s "
                   "(requested %u MT/s)", config->speed_mts);
        return NULL;
    }
    if (config->speed_mts == 1866 &&
        ((config->size_mb != 2048 && config->size_mb != 4096) ||
         config->ranks != 1 || config->device_width_bits != 8)) {
        error_setg(errp, "DDR3-1866 SPD is reviewed only for a 2048 or "
                   "4096 MB, single-rank x8 UDIMM");
        return NULL;
    }
    if (!spd_ddr3_geometry(config, &density_code, &addressing,
                           &organization, &trfc_mtb, errp) ||
        !spd_ddr3_identity_is_valid(config, errp)) {
        return NULL;
    }

    spd = g_malloc0(MODERN_SPD_SIZE);

    spd[0] = 0x92;    /* 176 bytes used, 256 total, CRC over 0-116 */
    spd[1] = 0x11;    /* SPD revision 1.1 */
    spd[2] = 0x0B;    /* DDR3 SDRAM */
    spd[3] = 0x02;    /* UDIMM */
    spd[4] = density_code;
    spd[5] = addressing;
    spd[6] = 0x00;    /* 1.5 V operable */
    spd[7] = organization;
    spd[8] = 0x03;    /* 64-bit primary bus, no ECC extension */
    spd[9] = 0x11;    /* FTB dividend/divisor: 1 ps */
    spd[10] = 0x01;   /* MTB dividend */
    spd[11] = 0x08;   /* MTB divisor: 125 ps */

    if (config->speed_mts == 1333) {
        spd[12] = 0x0C; /* tCKmin: 1.5 ns = DDR3-1333 */
        spd[14] = 0x3C; /* Supported CAS latencies: CL6 through CL9 */
        spd[16] = 0x6C; /* tAAmin: 13.5 ns (CL9 at DDR3-1333) */
        spd[18] = 0x6C; /* tRCDmin: 13.5 ns */
        spd[20] = 0x6C; /* tRPmin: 13.5 ns */
        spd[21] = 0x11; /* Upper nibbles for tRASmin and tRCmin */
        spd[22] = 0x20; /* tRASmin: 36 ns */
        spd[23] = 0x89; /* tRCmin: 49.125 ns */
    } else if (config->speed_mts == 1600) {
        spd[12] = 0x0A; /* tCKmin: 1.25 ns = DDR3-1600 */
        spd[14] = 0xFC; /* Supported CAS latencies: CL6 through CL11 */
        spd[16] = 0x6E; /* tAAmin: 13.75 ns (CL11 at DDR3-1600) */
        spd[18] = 0x6E; /* tRCDmin: 13.75 ns */
        spd[20] = 0x6E; /* tRPmin: 13.75 ns */
        spd[21] = 0x11; /* Upper nibbles for tRASmin and tRCmin */
        spd[22] = 0x18; /* tRASmin: 35 ns */
        spd[23] = 0x81; /* tRCmin: 48.125 ns */
    } else {
        /*
         * JEDEC DDR3-1866M bin used by reviewed Samsung CMA and Micron -1G9
         * single-rank x8 UDIMMs:
         * 1.071 ns tCK (9 MTB - 54 FTB), CL13, 13.125 ns
         * tAA/tRCD/tRP, 34 ns tRAS and 47.125 ns tRC.
         */
        spd[12] = 0x09; /* tCKmin MTB: 1.125 ns */
        spd[14] = 0xFE; /* Supported CL5 through CL11 */
        spd[15] = 0x02; /* Supported CL13 */
        spd[16] = 0x69; /* tAAmin: 13.125 ns */
        spd[18] = 0x69; /* tRCDmin: 13.125 ns */
        spd[20] = 0x69; /* tRPmin: 13.125 ns */
        spd[21] = 0x11; /* Upper nibbles for tRASmin and tRCmin */
        spd[22] = 0x10; /* tRASmin: 34 ns */
        spd[23] = 0x79; /* tRCmin: 47.125 ns */
        spd[34] = 0xCA; /* tCKmin fine offset: -54 ps => 1.071 ns */
    }

    spd[17] = 0x78;   /* tWRmin: 15 ns */
    spd[24] = trfc_mtb & 0xff;
    spd[25] = trfc_mtb >> 8;
    spd[26] = 0x3C;   /* tWTRmin: 7.5 ns */
    spd[27] = 0x3C;   /* tRTPmin: 7.5 ns */
    if (config->device_width_bits == 16) {
        /* x16 devices have a 2 KiB page and use the wider timing window. */
        spd[19] = 0x3C; /* tRRDmin: 7.5 ns */
        spd[28] = 0x01; /* tFAWmin upper nibble */
        spd[29] = config->speed_mts == 1333 ? 0x68 : 0x40;
    } else {
        /* x8 devices have a 1 KiB page. */
        spd[19] = 0x30; /* tRRDmin: 6 ns */
        spd[28] = 0x00; /* tFAWmin upper nibble */
        spd[29] = 0xF0; /* tFAWmin: 30 ns */
    }
    spd[33] = 0x00;   /* Standard monolithic SDRAM devices */

    /* Unbuffered desktop DIMM mechanical information. */
    spd[60] = 0x0F;   /* 30 mm nominal height */
    spd[61] = 0x11;   /* 2 mm maximum thickness, front and back */
    spd[62] = 0x00;   /* Reference raw card A, revision 0 */
    spd[63] = 0x00;   /* Standard rank address mapping */

    crc = spd_crc16(spd, 117);
    spd[126] = crc & 0xFF;
    spd[127] = crc >> 8;

    if (config->identity_configured) {
        memcpy(&spd[117], config->module_mfr_jep106,
               sizeof(config->module_mfr_jep106));
        memcpy(&spd[122], config->serial, sizeof(config->serial));
        memset(&spd[128], ' ', SMBUS_EEPROM_DDR3_PART_NUMBER_LEN);
        part_length = strlen(config->part_number);
        memcpy(&spd[128], config->part_number, part_length);
        memcpy(&spd[148], config->dram_mfr_jep106,
               sizeof(config->dram_mfr_jep106));
    }

    return spd;
}

uint8_t *spd_data_generate_ddr3(uint32_t size_mb, uint32_t speed_mts,
                                Error **errp)
{
    SmbusEepromDdr3Config config = {
        .size_mb = size_mb,
        .speed_mts = speed_mts,
        .ranks = 1,
        .device_width_bits = size_mb == 2048 ? 16 : 8,
    };

    return spd_data_generate_ddr3_config(&config, errp);
}

/*
 * Generate page 0 of a DDR4 UDIMM SPD. A 4 Gbit x8, single-rank, 64-bit
 * organization encodes a 4 GiB module. Page 1 carries identity fields and is
 * intentionally absent from the 256-byte SMBus EEPROM model.
 */
uint8_t *spd_data_generate_ddr4(uint32_t size_mb, uint32_t speed_mts,
                                Error **errp)
{
    uint8_t *spd;
    uint16_t crc;
    uint16_t tck_mtb, tck_max_mtb;
    uint16_t taa_mtb, trcd_mtb, trp_mtb, tras_mtb, trc_mtb;
    uint16_t trrd_s_mtb, trrd_l_mtb, tccd_l_mtb;
    int8_t tck_ftb, tck_max_ftb;
    int8_t taa_ftb, trcd_ftb, trp_ftb, trc_ftb;
    int8_t trrd_s_ftb, trrd_l_ftb, tccd_l_ftb;
    uint32_t tck_ps;
    uint32_t taa_ps, trcd_ps, trp_ps, tras_ps, trc_ps;

    if (size_mb != 4096) {
        error_setg(errp, "DDR4 SPD supports only 4096 MB modules "
                   "(requested %u MB)", size_mb);
        return NULL;
    }

    /*
     * Derive CL/tRCD/tRP/tRAS/tRC from the JEDEC table for the requested
     * speed. Values are in picoseconds.
     */
    switch (speed_mts) {
    case 1866:
        tck_ps = 1071;
        taa_ps = 13920; trcd_ps = 13920; trp_ps = 13920;
        tras_ps = 34000; trc_ps = 47920;
        break;
    case 2133:
        tck_ps = 938;
        taa_ps = 13130; trcd_ps = 13130; trp_ps = 13130;
        tras_ps = 33000; trc_ps = 46130;
        break;
    case 2400:
        tck_ps = 833;
        taa_ps = 13320; trcd_ps = 13320; trp_ps = 13320;
        tras_ps = 32000; trc_ps = 45320;
        break;
    case 2666:
        tck_ps = 750;
        taa_ps = 13500; trcd_ps = 13500; trp_ps = 13500;
        tras_ps = 28500; trc_ps = 42000;
        break;
    case 3200:
        tck_ps = 625;
        taa_ps = 13750; trcd_ps = 13750; trp_ps = 13750;
        tras_ps = 32000; trc_ps = 45750;
        break;
    default:
        error_setg(errp, "DDR4 SPD speed must be one of "
                   "1866, 2133, 2400, 2666 or 3200 MT/s "
                   "(requested %u MT/s)", speed_mts);
        return NULL;
    }

    spd_encode_timing(tck_ps, &tck_mtb, &tck_ftb);
    spd_encode_timing(1600, &tck_max_mtb, &tck_max_ftb);
    spd_encode_timing(taa_ps, &taa_mtb, &taa_ftb);
    spd_encode_timing(trcd_ps, &trcd_mtb, &trcd_ftb);
    spd_encode_timing(trp_ps, &trp_mtb, &trp_ftb);
    g_assert(tras_ps % SPD_MTB_PS == 0);
    tras_mtb = tras_ps / SPD_MTB_PS;
    spd_encode_timing(trc_ps, &trc_mtb, &trc_ftb);
    spd_encode_timing(5300, &trrd_s_mtb, &trrd_s_ftb);
    spd_encode_timing(6400, &trrd_l_mtb, &trrd_l_ftb);
    spd_encode_timing(6400, &tccd_l_mtb, &tccd_l_ftb);

    g_assert(tck_mtb <= UINT8_MAX && tck_max_mtb <= UINT8_MAX);
    g_assert(taa_mtb <= UINT8_MAX && trcd_mtb <= UINT8_MAX);
    g_assert(trp_mtb <= UINT8_MAX && tras_mtb <= 0xFFF);
    g_assert(trc_mtb <= 0xFFF);
    g_assert(trrd_s_mtb <= UINT8_MAX && trrd_l_mtb <= UINT8_MAX);
    g_assert(tccd_l_mtb <= UINT8_MAX);

    spd = g_malloc0(MODERN_SPD_SIZE);

    /* Block 0: Base Configuration & DRAM Parameters ----------------- */
    spd[0]  = 0x22;   /* 256 bytes used, 512B device, CRC over bytes 0-125 */
    spd[1]  = 0x10;   /* SPD revision 1.0 */
    spd[2]  = 0x0C;   /* DDR4 SDRAM */
    spd[3]  = 0x02;   /* UDIMM module type */
    /* Four bank groups, four banks/group and 4 Gbit SDRAM density. */
    spd[4]  = 0x84;
    /* 15 row bits (field value 3) + 10 column bits (field value 1). */
    spd[5]  = (3 << 3) | 1;
    spd[6]  = 0x00;   /* Monolithic DRAM package */
    spd[11] = 0x03;   /* VDD 1.2V operable and endurant */
    /* Module organization: 1 rank, x8 SDRAM device. */
    spd[12] = (0 << 3) | 0x01;
    /* Module bus width: 64-bit primary, no ECC extension. */
    spd[13] = (0 << 3) | 0x03;
    spd[14] = 0x00;   /* MTB = 125ps, FTB = 1ps */
    spd[17] = 0x00;
    spd[18] = (uint8_t)tck_mtb;
    spd[19] = (uint8_t)tck_max_mtb;
    /* CAS latencies supported: CL10..CL22. */
    spd[20] = 0xF8;   /* CL10..CL14 */
    spd[21] = 0xFF;   /* CL15..CL22 */
    spd[22] = 0x00;
    spd[23] = 0x00;
    spd[24] = (uint8_t)taa_mtb;
    spd[25] = (uint8_t)trcd_mtb;
    spd[26] = (uint8_t)trp_mtb;
    /* Byte 27: tRAS high nibble (bits [3:0]) + tRC high nibble (bits [7:4]) */
    spd[27] = ((trc_mtb >> 8) & 0x0F) << 4 | ((tras_mtb >> 8) & 0x0F);
    spd[28] = (uint8_t)(tras_mtb & 0xFF);
    spd[29] = (uint8_t)(trc_mtb  & 0xFF);
    /* tRFC1 = 260ns @ 4 Gbit (little-endian MTB) */
    spd[30] = 0x20;
    spd[31] = 0x08;
    /* tRFC2 = 160ns */
    spd[32] = 0x00;
    spd[33] = 0x05;
    /* tRFC4 = 110ns */
    spd[34] = 0x70;
    spd[35] = 0x03;
    spd[36] = 0x00;          /* tFAW hi nibble */
    spd[37] = (uint8_t)(21000 / SPD_MTB_PS);   /* 21ns */
    spd[38] = (uint8_t)trrd_s_mtb;              /* tRRD_S 5.3ns */
    spd[39] = (uint8_t)trrd_l_mtb;              /* tRRD_L 6.4ns */
    spd[40] = (uint8_t)tccd_l_mtb;              /* tCCD_L 6.4ns */

    /* Signed fine offsets, in picoseconds. */
    spd[117] = (uint8_t)tccd_l_ftb;
    spd[118] = (uint8_t)trrd_l_ftb;
    spd[119] = (uint8_t)trrd_s_ftb;
    spd[120] = (uint8_t)trc_ftb;
    spd[121] = (uint8_t)trp_ftb;
    spd[122] = (uint8_t)trcd_ftb;
    spd[123] = (uint8_t)taa_ftb;
    spd[124] = (uint8_t)tck_max_ftb;
    spd[125] = (uint8_t)tck_ftb;

    /* Block 0 CRC over bytes 0-125 placed at 126-127 (little-endian). */
    crc = spd_crc16(spd, 126);
    spd[126] = (uint8_t)(crc & 0xFF);
    spd[127] = (uint8_t)(crc >> 8);

    /* Block 1: Module-specific (UDIMM) ------------------------------ */
    spd[128] = 0x11;   /* 32 mm nominal height */
    spd[129] = 0x11;   /* Module max thickness 2mm front/back */
    spd[130] = 0x00;   /* Reference Raw Card A, rev 0 */
    spd[131] = 0x00;
    /* Block 1 CRC over bytes 128-253 placed at 254-255. */
    crc = spd_crc16(spd + 128, 126);
    spd[254] = (uint8_t)(crc & 0xFF);
    spd[255] = (uint8_t)(crc >> 8);

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
