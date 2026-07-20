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
#define TYPE_EE1004_PAGE_SELECTOR "ee1004-page-selector"

OBJECT_DECLARE_SIMPLE_TYPE(SMBusEEPROMDevice, SMBUS_EEPROM)
OBJECT_DECLARE_SIMPLE_TYPE(EE1004PageSelector, EE1004_PAGE_SELECTOR)

struct SMBusEEPROMDevice {
    SMBusDevice smbusdev;
    uint8_t data[SMBUS_EE1004_SIZE];
    uint8_t *init_data;
    uint16_t init_size;
    uint8_t offset;
    uint8_t page;
    bool accessed;
    bool ee1004_state_loaded;
};

struct EE1004PageSelector {
    I2CSlave i2cdev;
    uint8_t page;
};

static size_t smbus_eeprom_data_offset(const SMBusEEPROMDevice *eeprom)
{
    return eeprom->page * SMBUS_EEPROM_PAGE_SIZE + eeprom->offset;
}

static uint8_t eeprom_receive_byte(SMBusDevice *dev)
{
    SMBusEEPROMDevice *eeprom = SMBUS_EEPROM(dev);
    uint8_t val = eeprom->data[smbus_eeprom_data_offset(eeprom)];

    eeprom->offset++;
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

    eeprom->accessed = true;
#ifdef DEBUG
    printf("eeprom_write_data: addr=0x%02x cmd=0x%02x len=%u\n",
           dev->i2c.address, buf[0], len);
#endif
    /* len is guaranteed to be > 0 */
    eeprom->offset = buf[0];
    buf++;
    len--;

    for (; len > 0; len--) {
        eeprom->data[smbus_eeprom_data_offset(eeprom)] = *buf++;
        eeprom->offset++;
    }

    return 0;
}

static bool smbus_eeprom_vmstate_needed(void *opaque)
{
    SMBusEEPROMDevice *eeprom = opaque;

    return eeprom->accessed || smbus_vmstate_needed(&eeprom->smbusdev);
}

static bool smbus_ee1004_vmstate_needed(void *opaque)
{
    SMBusEEPROMDevice *eeprom = opaque;

    return eeprom->init_size == SMBUS_EE1004_SIZE;
}

static int smbus_ee1004_post_load(void *opaque, int version_id)
{
    SMBusEEPROMDevice *eeprom = opaque;

    /* init_size 由 EQUAL 校验；page 必须限制到两个合法页。 */
    eeprom->ee1004_state_loaded = true;
    return eeprom->init_size == SMBUS_EE1004_SIZE && eeprom->page < 2 ?
           0 : -EINVAL;
}

static int smbus_eeprom_pre_load(void *opaque)
{
    SMBusEEPROMDevice *eeprom = opaque;

    eeprom->ee1004_state_loaded = false;
    return 0;
}

static int smbus_eeprom_post_load(void *opaque, int version_id)
{
    SMBusEEPROMDevice *eeprom = opaque;

    return eeprom->init_size == SMBUS_EE1004_SIZE &&
           !eeprom->ee1004_state_loaded ? -EINVAL : 0;
}

static const VMStateDescription vmstate_smbus_ee1004 = {
    .name = "smbus-eeprom/ee1004",
    .version_id = 1,
    .minimum_version_id = 1,
    .needed = smbus_ee1004_vmstate_needed,
    .post_load = smbus_ee1004_post_load,
    .fields = (const VMStateField[]) {
        VMSTATE_SUB_ARRAY(data, SMBusEEPROMDevice, SMBUS_EEPROM_PAGE_SIZE,
                          SMBUS_EEPROM_PAGE_SIZE, 0,
                          vmstate_info_uint8, uint8_t),
        VMSTATE_UINT16_EQUAL(init_size, SMBusEEPROMDevice, NULL),
        VMSTATE_UINT8(page, SMBusEEPROMDevice),
        VMSTATE_END_OF_LIST()
    }
};

static const VMStateDescription *vmstate_smbus_eeprom_subsections[] = {
    &vmstate_smbus_ee1004,
    NULL,
};

static const VMStateDescription vmstate_smbus_eeprom = {
    .name = "smbus-eeprom",
    .version_id = 1,
    .minimum_version_id = 1,
    .needed = smbus_eeprom_vmstate_needed,
    .pre_load = smbus_eeprom_pre_load,
    .post_load = smbus_eeprom_post_load,
    .fields = (const VMStateField[]) {
        VMSTATE_SMBUS_DEVICE(smbusdev, SMBusEEPROMDevice),
        VMSTATE_UINT8_SUB_ARRAY(data, SMBusEEPROMDevice, 0,
                                SMBUS_EEPROM_PAGE_SIZE),
        VMSTATE_UINT8(offset, SMBusEEPROMDevice),
        VMSTATE_BOOL(accessed, SMBusEEPROMDevice),
        VMSTATE_END_OF_LIST()
    },
    .subsections = vmstate_smbus_eeprom_subsections,
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

    memset(eeprom->data, 0, sizeof(eeprom->data));
    memcpy(eeprom->data, eeprom->init_data, eeprom->init_size);
    eeprom->offset = 0;
    eeprom->page = 0;
}

static void smbus_eeprom_realize(DeviceState *dev, Error **errp)
{
    SMBusEEPROMDevice *eeprom = SMBUS_EEPROM(dev);

    if (eeprom->init_data == NULL) {
        error_setg(errp, "init_data cannot be NULL");
        return;
    }
    if (eeprom->init_size != SMBUS_EEPROM_PAGE_SIZE &&
        eeprom->init_size != SMBUS_EE1004_SIZE) {
        error_setg(errp, "unsupported EEPROM size: %u", eeprom->init_size);
        return;
    }
    smbus_eeprom_reset(dev);
}

static void ee1004_select_page(EE1004PageSelector *selector)
{
    BusState *bus = qdev_get_parent_bus(DEVICE(selector));
    BusChild *kid;

    /* 同步 512B SPD 页；256B EEPROM 不受影响。 */
    QTAILQ_FOREACH(kid, &bus->children, sibling) {
        DeviceState *child = kid->child;
        SMBusEEPROMDevice *eeprom;

        if (!object_dynamic_cast(OBJECT(child), TYPE_SMBUS_EEPROM)) {
            continue;
        }
        eeprom = SMBUS_EEPROM(child);
        if (eeprom->init_size == SMBUS_EE1004_SIZE) {
            eeprom->page = selector->page;
            eeprom->accessed = true;
        }
    }
}

static bool ee1004_page_is_selected(EE1004PageSelector *selector)
{
    BusState *bus = qdev_get_parent_bus(DEVICE(selector));
    BusChild *kid;

    QTAILQ_FOREACH(kid, &bus->children, sibling) {
        DeviceState *child = kid->child;
        SMBusEEPROMDevice *eeprom;

        if (!object_dynamic_cast(OBJECT(child), TYPE_SMBUS_EEPROM)) {
            continue;
        }
        eeprom = SMBUS_EEPROM(child);
        if (eeprom->init_size == SMBUS_EE1004_SIZE) {
            return eeprom->page == selector->page;
        }
    }
    return selector->page == 0;
}

static int ee1004_page_event(I2CSlave *dev, enum i2c_event event)
{
    EE1004PageSelector *selector = EE1004_PAGE_SELECTOR(dev);

    if (event == I2C_START_SEND || event == I2C_START_SEND_ASYNC) {
        /*
         * SPA0/SPA1 在从地址被接受时生效。
         * 因此带数据的 SMBus Send Byte 和 Quick Write 都能选页。
         * 选页不改变 EEPROM 内部地址指针。
         */
        ee1004_select_page(selector);
        return 0;
    }
    if (event == I2C_START_RECV &&
        (selector->page != 0 || !ee1004_page_is_selected(selector))) {
        /*
         * 只有 0x36/RPA 可读：page 0 时 ACK，page 1 时 NACK。
         * 0x37 是 SPA1 写地址，读操作始终 NACK。
         */
        return 1;
    }
    return 0;
}

static int ee1004_page_send(I2CSlave *dev, uint8_t data)
{
    /* SPA 命令的地址字节和数据字节均为无关值。 */
    return 0;
}

static uint8_t ee1004_page_recv(I2CSlave *dev)
{
    return 0;
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

static void ee1004_page_selector_class_init(ObjectClass *klass,
                                            const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    I2CSlaveClass *sc = I2C_SLAVE_CLASS(klass);

    sc->event = ee1004_page_event;
    sc->send = ee1004_page_send;
    sc->recv = ee1004_page_recv;
    dc->user_creatable = false;
}

static const TypeInfo smbus_eeprom_types[] = {
    {
        .name          = TYPE_SMBUS_EEPROM,
        .parent        = TYPE_SMBUS_DEVICE,
        .instance_size = sizeof(SMBusEEPROMDevice),
        .class_init    = smbus_eeprom_class_initfn,
    },
    {
        .name          = TYPE_EE1004_PAGE_SELECTOR,
        .parent        = TYPE_I2C_SLAVE,
        .instance_size = sizeof(EE1004PageSelector),
        .class_init    = ee1004_page_selector_class_init,
    },
};

DEFINE_TYPES(smbus_eeprom_types)

static void smbus_eeprom_init_one_with_size(I2CBus *smbus, uint8_t address,
                                            uint8_t *eeprom_buf,
                                            uint16_t eeprom_size)
{
    DeviceState *dev;

    dev = qdev_new(TYPE_SMBUS_EEPROM);
    qdev_prop_set_uint8(dev, "address", address);
    /* FIXME: use an array of byte or block backend property? */
    SMBUS_EEPROM(dev)->init_data = eeprom_buf;
    SMBUS_EEPROM(dev)->init_size = eeprom_size;
    qdev_realize_and_unref(dev, (BusState *)smbus, &error_fatal);
}

void smbus_eeprom_init_one(I2CBus *smbus, uint8_t address, uint8_t *eeprom_buf)
{
    smbus_eeprom_init_one_with_size(smbus, address, eeprom_buf,
                                    SMBUS_EEPROM_PAGE_SIZE);
}

void smbus_eeprom_init(I2CBus *smbus, int nb_eeprom,
                       const uint8_t *eeprom_spd, int eeprom_spd_size)
{
    int i;
    size_t buffer_size = 8 * SMBUS_EEPROM_PAGE_SIZE;
    uint8_t *eeprom_buf;
     /* XXX: make this persistent */

    assert(nb_eeprom >= 0 && nb_eeprom <= 8);
    assert(eeprom_spd_size >= 0 && eeprom_spd_size <= buffer_size);
    eeprom_buf = g_malloc0(buffer_size);
    if (eeprom_spd_size > 0) {
        memcpy(eeprom_buf, eeprom_spd, eeprom_spd_size);
    }

    for (i = 0; i < nb_eeprom; i++) {
        smbus_eeprom_init_one(smbus, 0x50 + i,
                              eeprom_buf + (i * SMBUS_EEPROM_PAGE_SIZE));
    }
}

void smbus_ee1004_init(I2CBus *smbus, int nb_eeprom, uint8_t **eeprom_spd)
{
    int i;

    assert(nb_eeprom > 0 && nb_eeprom <= 8);
    for (i = 0; i < 2; i++) {
        DeviceState *dev = qdev_new(TYPE_EE1004_PAGE_SELECTOR);

        qdev_prop_set_uint8(dev, "address", 0x36 + i);
        EE1004_PAGE_SELECTOR(dev)->page = i;
        qdev_realize_and_unref(dev, (BusState *)smbus, &error_fatal);
    }
    for (i = 0; i < nb_eeprom; i++) {
        smbus_eeprom_init_one_with_size(smbus, 0x50 + i, eeprom_spd[i],
                                        SMBUS_EE1004_SIZE);
    }
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
