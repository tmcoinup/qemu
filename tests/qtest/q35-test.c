/*
 * QTest testcase for Q35 northbridge
 *
 * Copyright (c) 2015 Red Hat, Inc.
 *
 * Author: Gerd Hoffmann <kraxel@redhat.com>
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"
#include "libqtest.h"
#include "libqos/pci.h"
#include "libqos/pci-pc.h"
#include "hw/i2c/smbus_eeprom.h"
#include "hw/pci-host/q35.h"
#include "hw/southbridge/ich9.h"
#include "qobject/qdict.h"

#define TSEG_SIZE_TEST_GUEST_RAM_MBYTES 128

#define SMBUS_STS_INTR      (1U << 1)
#define SMBUS_STS_ERROR     ((1U << 2) | (1U << 3) | (1U << 4))
#define SMBUS_CTL_INTREN    (1U << 0)
#define SMBUS_CTL_START     (1U << 6)
#define SMBUS_PROT_BYTE_DATA 2

typedef struct SpdTestArgs {
    uint32_t module_mb;
    uint32_t speed_mts;
} SpdTestArgs;

static const SpdTestArgs spd_ddr3_2g_1333 = {
    .module_mb = 2048,
    .speed_mts = 1333,
};

static const SpdTestArgs spd_ddr3_2g_1600 = {
    .module_mb = 2048,
    .speed_mts = 1600,
};

static const SpdTestArgs spd_ddr3_4g_1333 = {
    .module_mb = 4096,
    .speed_mts = 1333,
};

static const SpdTestArgs spd_ddr3_4g_1600 = {
    .module_mb = 4096,
    .speed_mts = 1600,
};

/* @esmramc_tseg_sz: ESMRAMC.TSEG_SZ bitmask for selecting the requested TSEG
 *                   size. Must be a subset of
 *                   MCH_HOST_BRIDGE_ESMRAMC_TSEG_SZ_MASK.
 *
 * @extended_tseg_mbytes: Size of the extended TSEG. Only consulted if
 *                        @esmramc_tseg_sz equals
 *                        MCH_HOST_BRIDGE_ESMRAMC_TSEG_SZ_MASK precisely.
 *
 * @expected_tseg_mbytes: Expected guest-visible TSEG size in megabytes,
 *                        matching @esmramc_tseg_sz and @extended_tseg_mbytes
 *                        above.
 */
struct TsegSizeArgs {
    uint8_t esmramc_tseg_sz;
    uint16_t extended_tseg_mbytes;
    uint16_t expected_tseg_mbytes;
};
typedef struct TsegSizeArgs TsegSizeArgs;

static const TsegSizeArgs tseg_1mb = {
    .esmramc_tseg_sz      = MCH_HOST_BRIDGE_ESMRAMC_TSEG_SZ_1MB,
    .extended_tseg_mbytes = 0,
    .expected_tseg_mbytes = 1,
};
static const TsegSizeArgs tseg_2mb = {
    .esmramc_tseg_sz      = MCH_HOST_BRIDGE_ESMRAMC_TSEG_SZ_2MB,
    .extended_tseg_mbytes = 0,
    .expected_tseg_mbytes = 2,
};
static const TsegSizeArgs tseg_8mb = {
    .esmramc_tseg_sz      = MCH_HOST_BRIDGE_ESMRAMC_TSEG_SZ_8MB,
    .extended_tseg_mbytes = 0,
    .expected_tseg_mbytes = 8,
};
static const TsegSizeArgs tseg_ext_16mb = {
    .esmramc_tseg_sz      = MCH_HOST_BRIDGE_ESMRAMC_TSEG_SZ_MASK,
    .extended_tseg_mbytes = 16,
    .expected_tseg_mbytes = 16,
};

static void smram_set_bit(QPCIDevice *pcidev, uint8_t mask, bool enabled)
{
    uint8_t smram;

    smram = qpci_config_readb(pcidev, MCH_HOST_BRIDGE_SMRAM);
    if (enabled) {
        smram |= mask;
    } else {
        smram &= ~mask;
    }
    qpci_config_writeb(pcidev, MCH_HOST_BRIDGE_SMRAM, smram);
}

static bool smram_test_bit(QPCIDevice *pcidev, uint8_t mask)
{
    uint8_t smram;

    smram = qpci_config_readb(pcidev, MCH_HOST_BRIDGE_SMRAM);
    return smram & mask;
}

static void test_smram_lock(void)
{
    QPCIBus *pcibus;
    QPCIDevice *pcidev;
    QTestState *qts;

    qts = qtest_init("-M q35");

    pcibus = qpci_new_pc(qts, NULL);
    g_assert(pcibus != NULL);

    pcidev = qpci_device_find(pcibus, 0);
    g_assert(pcidev != NULL);

    /* check open is settable */
    smram_set_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN, false);
    g_assert(smram_test_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN) == false);
    smram_set_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN, true);
    g_assert(smram_test_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN) == true);

    /* lock, check open is cleared & not settable */
    smram_set_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_LCK, true);
    g_assert(smram_test_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN) == false);
    smram_set_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN, true);
    g_assert(smram_test_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN) == false);

    /* reset */
    qtest_system_reset(qts);

    /* check open is settable again */
    smram_set_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN, false);
    g_assert(smram_test_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN) == false);
    smram_set_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN, true);
    g_assert(smram_test_bit(pcidev, MCH_HOST_BRIDGE_SMRAM_D_OPEN) == true);

    g_free(pcidev);
    qpci_free_pc(pcibus);

    qtest_quit(qts);
}

static void test_tseg_size(const void *data)
{
    const TsegSizeArgs *args = data;
    QPCIBus *pcibus;
    QPCIDevice *pcidev;
    uint8_t smram_val;
    uint8_t esmramc_val;
    uint32_t ram_offs;
    QTestState *qts;

    if (args->esmramc_tseg_sz == MCH_HOST_BRIDGE_ESMRAMC_TSEG_SZ_MASK) {
        qts = qtest_initf("-M q35 -m %uM -global mch.extended-tseg-mbytes=%u",
                          TSEG_SIZE_TEST_GUEST_RAM_MBYTES,
                          args->extended_tseg_mbytes);
    } else {
        qts = qtest_initf("-M q35 -m %uM", TSEG_SIZE_TEST_GUEST_RAM_MBYTES);
    }

    /* locate the DRAM controller */
    pcibus = qpci_new_pc(qts, NULL);
    g_assert(pcibus != NULL);
    pcidev = qpci_device_find(pcibus, 0);
    g_assert(pcidev != NULL);

    /* Set TSEG size. Restrict TSEG visibility to SMM by setting T_EN. */
    esmramc_val = qpci_config_readb(pcidev, MCH_HOST_BRIDGE_ESMRAMC);
    esmramc_val &= ~MCH_HOST_BRIDGE_ESMRAMC_TSEG_SZ_MASK;
    esmramc_val |= args->esmramc_tseg_sz;
    esmramc_val |= MCH_HOST_BRIDGE_ESMRAMC_T_EN;
    qpci_config_writeb(pcidev, MCH_HOST_BRIDGE_ESMRAMC, esmramc_val);

    /* Enable TSEG by setting G_SMRAME. Close TSEG by setting D_CLS. */
    smram_val = qpci_config_readb(pcidev, MCH_HOST_BRIDGE_SMRAM);
    smram_val &= ~(MCH_HOST_BRIDGE_SMRAM_D_OPEN |
                   MCH_HOST_BRIDGE_SMRAM_D_LCK);
    smram_val |= (MCH_HOST_BRIDGE_SMRAM_D_CLS |
                  MCH_HOST_BRIDGE_SMRAM_G_SMRAME);
    qpci_config_writeb(pcidev, MCH_HOST_BRIDGE_SMRAM, smram_val);

    /* lock TSEG */
    smram_val |= MCH_HOST_BRIDGE_SMRAM_D_LCK;
    qpci_config_writeb(pcidev, MCH_HOST_BRIDGE_SMRAM, smram_val);

    /* Now check that the byte right before the TSEG is r/w, and that the first
     * byte in the TSEG always reads as 0xff.
     */
    ram_offs = (TSEG_SIZE_TEST_GUEST_RAM_MBYTES - args->expected_tseg_mbytes) *
               1024 * 1024 - 1;
    g_assert_cmpint(qtest_readb(qts, ram_offs), ==, 0);
    qtest_writeb(qts, ram_offs, 1);
    g_assert_cmpint(qtest_readb(qts, ram_offs), ==, 1);

    ram_offs++;
    g_assert_cmpint(qtest_readb(qts, ram_offs), ==, 0xff);
    qtest_writeb(qts, ram_offs, 1);
    g_assert_cmpint(qtest_readb(qts, ram_offs), ==, 0xff);

    g_free(pcidev);
    qpci_free_pc(pcibus);
    qtest_quit(qts);
}

#define SMBASE 0x30000
#define SMRAM_TEST_PATTERN 0x32
#define SMRAM_TEST_RESET_PATTERN 0x23

static void test_smram_smbase_lock(void)
{
    QPCIBus *pcibus;
    QPCIDevice *pcidev;
    QTestState *qts;
    int i;

    qts = qtest_init("-M q35");

    pcibus = qpci_new_pc(qts, NULL);
    g_assert(pcibus != NULL);

    pcidev = qpci_device_find(pcibus, 0);
    g_assert(pcidev != NULL);

    /* check that SMRAM is not enabled by default */
    g_assert(qpci_config_readb(pcidev, MCH_HOST_BRIDGE_F_SMBASE) == 0);
    qtest_writeb(qts, SMBASE, SMRAM_TEST_PATTERN);
    g_assert_cmpint(qtest_readb(qts, SMBASE), ==, SMRAM_TEST_PATTERN);

    /* enable SMRAM at SMBASE */
    qpci_config_writeb(pcidev, MCH_HOST_BRIDGE_F_SMBASE, 0xff);
    g_assert(qpci_config_readb(pcidev, MCH_HOST_BRIDGE_F_SMBASE) == 0x01);
    /* lock SMRAM at SMBASE */
    qpci_config_writeb(pcidev, MCH_HOST_BRIDGE_F_SMBASE, 0x02);
    g_assert(qpci_config_readb(pcidev, MCH_HOST_BRIDGE_F_SMBASE) == 0x02);

    /* check that SMRAM at SMBASE is locked and can't be unlocked */
    g_assert_cmpint(qtest_readb(qts, SMBASE), ==, 0xff);
    for (i = 0; i <= 0xff; i++) {
        /* make sure register is immutable */
        qpci_config_writeb(pcidev, MCH_HOST_BRIDGE_F_SMBASE, i);
        g_assert(qpci_config_readb(pcidev, MCH_HOST_BRIDGE_F_SMBASE) == 0x02);

        /* RAM access should go into black hole */
        qtest_writeb(qts, SMBASE, SMRAM_TEST_PATTERN);
        g_assert_cmpint(qtest_readb(qts, SMBASE), ==, 0xff);
    }

    /* reset */
    qtest_system_reset(qts);

    /* check RAM at SMBASE is available after reset */
    g_assert_cmpint(qtest_readb(qts, SMBASE), ==, SMRAM_TEST_PATTERN);
    g_assert(qpci_config_readb(pcidev, MCH_HOST_BRIDGE_F_SMBASE) == 0);
    qtest_writeb(qts, SMBASE, SMRAM_TEST_RESET_PATTERN);
    g_assert_cmpint(qtest_readb(qts, SMBASE), ==, SMRAM_TEST_RESET_PATTERN);

    g_free(pcidev);
    qpci_free_pc(pcibus);

    qtest_quit(qts);
}

static uint16_t spd_test_crc16(const uint8_t *buf, size_t len)
{
    uint32_t crc = 0;
    size_t i;
    int bit;

    for (i = 0; i < len; i++) {
        crc ^= (uint32_t)buf[i] << 8;
        for (bit = 0; bit < 8; bit++) {
            crc = crc & 0x8000 ? (crc << 1) ^ 0x1021 : crc << 1;
        }
    }

    return crc & 0xffff;
}

static uint8_t q35_smbus_read_byte(QPCIDevice *smb, QPCIBar bar,
                                   uint8_t device, uint8_t command)
{
    uint8_t status;

    /* Status bits are write-one-to-clear. */
    qpci_io_writeb(smb, bar, ICH9_SMB_HST_STS, 0xff);
    qpci_io_writeb(smb, bar, ICH9_SMB_HST_CMD, command);
    qpci_io_writeb(smb, bar, ICH9_SMB_XMIT_SLVA, (device << 1) | 1);
    qpci_io_writeb(smb, bar, ICH9_SMB_HST_CNT,
                   (SMBUS_PROT_BYTE_DATA << 2) |
                   SMBUS_CTL_INTREN | SMBUS_CTL_START);

    status = qpci_io_readb(smb, bar, ICH9_SMB_HST_STS);
    g_assert_cmphex(status & SMBUS_STS_ERROR, ==, 0);
    g_assert_cmphex(status & SMBUS_STS_INTR, ==, SMBUS_STS_INTR);

    return qpci_io_readb(smb, bar, ICH9_SMB_HST_D0);
}

static char *q35_test_setenv(const char *name, const char *value)
{
    char *saved = g_strdup(g_getenv(name));

    g_assert_true(g_setenv(name, value, true));
    return saved;
}

static void q35_test_restore_env(const char *name, const char *saved)
{
    if (saved) {
        g_assert_true(g_setenv(name, saved, true));
    } else {
        g_unsetenv(name);
    }
}

static char *q35_test_unsetenv(const char *name)
{
    char *saved = g_strdup(g_getenv(name));

    g_unsetenv(name);
    return saved;
}

static const char * const q35_spd_ddr3_detail_env_names[] = {
    "QEMU_SPD_RANK_LIST",
    "QEMU_SPD_DEVICE_WIDTH_LIST",
    "QEMU_SPD_MODULE_MFR_JEP106_LIST",
    "QEMU_SPD_DRAM_MFR_JEP106_LIST",
    "QEMU_SPD_SERIAL_LIST",
    "QEMU_SPD_PART_LIST",
};

typedef struct Q35SpdDetailEnvSave {
    char *value[G_N_ELEMENTS(q35_spd_ddr3_detail_env_names)];
} Q35SpdDetailEnvSave;

static void q35_test_unset_spd_detail_env(Q35SpdDetailEnvSave *saved)
{
    size_t i;

    for (i = 0; i < G_N_ELEMENTS(q35_spd_ddr3_detail_env_names); i++) {
        saved->value[i] =
            q35_test_unsetenv(q35_spd_ddr3_detail_env_names[i]);
    }
}

static void q35_test_restore_spd_detail_env(Q35SpdDetailEnvSave *saved)
{
    size_t i;

    for (i = 0; i < G_N_ELEMENTS(q35_spd_ddr3_detail_env_names); i++) {
        q35_test_restore_env(q35_spd_ddr3_detail_env_names[i],
                             saved->value[i]);
        g_free(saved->value[i]);
    }
}

static char **q35_test_unset_spd_details_from_environ(char **env)
{
    size_t i;

    for (i = 0; i < G_N_ELEMENTS(q35_spd_ddr3_detail_env_names); i++) {
        env = g_environ_unsetenv(
            env, q35_spd_ddr3_detail_env_names[i]);
    }
    return env;
}

static void q35_read_spd(QPCIDevice *smb, QPCIBar bar, uint8_t address,
                         uint8_t *spd, size_t len)
{
    size_t i;

    for (i = 0; i < len; i++) {
        spd[i] = q35_smbus_read_byte(smb, bar, address, i);
    }
}

static uint32_t spd_ddr3_decode_mb(const uint8_t *spd)
{
    uint32_t density_mbits = 256U << (spd[4] & 0x0f);
    uint32_t device_width = 4U << (spd[7] & 0x07);
    uint32_t ranks = ((spd[7] >> 3) & 0x07) + 1;
    uint32_t primary_bus_width = 8U << (spd[8] & 0x07);

    return density_mbits / 8 * primary_bus_width / device_width * ranks;
}

static void test_spd_ddr3(const void *opaque)
{
    const SpdTestArgs *args = opaque;
    Q35SpdDetailEnvSave saved_details = { 0 };
    g_autofree char *module_mb = g_strdup_printf("%u", args->module_mb);
    g_autofree char *speed_mts = g_strdup_printf("%u", args->speed_mts);
    g_autofree char *saved_type = q35_test_setenv("QEMU_SPD_TYPE", "DDR3");
    g_autofree char *saved_module = q35_test_setenv("QEMU_SPD_MODULE_MB",
                                                    module_mb);
    g_autofree char *saved_module_list =
        q35_test_unsetenv("QEMU_SPD_MODULE_MB_LIST");
    g_autofree char *saved_speed = q35_test_setenv("QEMU_SPD_SPEED_MT",
                                                   speed_mts);
    g_autofree char *saved_slots = q35_test_setenv("QEMU_SPD_SLOTS", "2");
    g_autofree char *machine_args =
        g_strdup_printf("-M q35 -m %uM", args->module_mb * 2);
    uint8_t spd[256];
    uint8_t spd_second[256];
    uint16_t crc;
    QPCIBus *pcibus;
    QPCIDevice *smb;
    QPCIBar bar;
    QTestState *qts;

    q35_test_unset_spd_detail_env(&saved_details);
    qts = qtest_init(machine_args);
    pcibus = qpci_new_pc(qts, NULL);
    g_assert_nonnull(pcibus);

    smb = qpci_device_find(pcibus,
                           QPCI_DEVFN(ICH9_SMB_DEV, ICH9_SMB_FUNC));
    g_assert_nonnull(smb);
    qpci_device_enable(smb);
    bar = qpci_iomap(smb, ICH9_SMB_SMB_BASE_BAR, NULL);
    qpci_config_writeb(smb, ICH9_SMB_HOSTC,
                       qpci_config_readb(smb, ICH9_SMB_HOSTC) |
                       ICH9_SMB_HOSTC_HST_EN);

    q35_read_spd(smb, bar, 0x50, spd, sizeof(spd));
    q35_read_spd(smb, bar, 0x51, spd_second, sizeof(spd_second));

    g_assert_cmphex(spd[0], ==, 0x92);
    g_assert_cmphex(spd[2], ==, 0x0b);
    g_assert_cmphex(spd[3], ==, 0x02);
    g_assert_cmphex(spd[4], ==, 0x04);
    g_assert_cmphex(spd[5], ==, args->module_mb == 2048 ? 0x19 : 0x21);
    g_assert_cmphex(spd[7], ==, args->module_mb == 2048 ? 0x02 : 0x01);
    g_assert_cmphex(spd[8], ==, 0x03);

    g_assert_cmpuint(spd_ddr3_decode_mb(spd), ==, args->module_mb);

    if (args->speed_mts == 1333) {
        g_assert_cmphex(spd[12], ==, 0x0c);
        g_assert_cmphex(spd[14], ==, 0x3c);
        g_assert_cmphex(spd[16], ==, 0x6c);
        g_assert_cmphex(spd[18], ==, 0x6c);
        g_assert_cmphex(spd[20], ==, 0x6c);
        g_assert_cmphex(spd[22], ==, 0x20);
        g_assert_cmphex(spd[23], ==, 0x89);
    } else {
        g_assert_cmphex(spd[12], ==, 0x0a);
        g_assert_cmphex(spd[14], ==, 0xfc);
        g_assert_cmphex(spd[16], ==, 0x6e);
        g_assert_cmphex(spd[18], ==, 0x6e);
        g_assert_cmphex(spd[20], ==, 0x6e);
        g_assert_cmphex(spd[22], ==, 0x18);
        g_assert_cmphex(spd[23], ==, 0x81);
    }

    if (args->module_mb == 2048) {
        g_assert_cmphex(spd[19], ==, 0x3c);
        g_assert_cmphex(spd[28], ==, 0x01);
        g_assert_cmphex(spd[29], ==,
                        args->speed_mts == 1333 ? 0x68 : 0x40);
    } else {
        g_assert_cmphex(spd[19], ==, 0x30);
        g_assert_cmphex(spd[28], ==, 0x00);
        g_assert_cmphex(spd[29], ==, 0xf0);
    }

    crc = spd_test_crc16(spd, 117);
    g_assert_cmphex(spd[126] | (spd[127] << 8), ==, crc);
    g_assert_cmpmem(spd_second, sizeof(spd_second), spd, sizeof(spd));
    g_assert_cmphex(spd[117], ==, 0x00);
    g_assert_cmphex(spd[122], ==, 0x00);
    g_assert_cmphex(spd[128], ==, 0x00);
    g_assert_cmphex(spd[148], ==, 0x00);

    qpci_iounmap(smb, bar);
    g_free(smb);
    qpci_free_pc(pcibus);
    qtest_quit(qts);

    q35_test_restore_env("QEMU_SPD_SLOTS", saved_slots);
    q35_test_restore_env("QEMU_SPD_SPEED_MT", saved_speed);
    q35_test_restore_env("QEMU_SPD_MODULE_MB_LIST", saved_module_list);
    q35_test_restore_env("QEMU_SPD_MODULE_MB", saved_module);
    q35_test_restore_env("QEMU_SPD_TYPE", saved_type);
    q35_test_restore_spd_detail_env(&saved_details);
}

static void test_spd_ddr3_mixed_modules(void)
{
    Q35SpdDetailEnvSave saved_details = { 0 };
    g_autofree char *saved_type = q35_test_setenv("QEMU_SPD_TYPE", "DDR3");
    g_autofree char *saved_module = q35_test_unsetenv("QEMU_SPD_MODULE_MB");
    g_autofree char *saved_module_list =
        q35_test_setenv("QEMU_SPD_MODULE_MB_LIST", "4096,2048");
    g_autofree char *saved_speed =
        q35_test_setenv("QEMU_SPD_SPEED_MT", "1600");
    g_autofree char *saved_slots = q35_test_setenv("QEMU_SPD_SLOTS", "2");
    uint8_t spd[2][128];
    QPCIBus *pcibus;
    QPCIDevice *smb;
    QPCIBar bar;
    QTestState *qts;
    int i;

    q35_test_unset_spd_detail_env(&saved_details);
    qts = qtest_init("-M q35 -m 6G");
    pcibus = qpci_new_pc(qts, NULL);
    g_assert_nonnull(pcibus);

    smb = qpci_device_find(pcibus,
                           QPCI_DEVFN(ICH9_SMB_DEV, ICH9_SMB_FUNC));
    g_assert_nonnull(smb);
    qpci_device_enable(smb);
    bar = qpci_iomap(smb, ICH9_SMB_SMB_BASE_BAR, NULL);
    qpci_config_writeb(smb, ICH9_SMB_HOSTC,
                       qpci_config_readb(smb, ICH9_SMB_HOSTC) |
                       ICH9_SMB_HOSTC_HST_EN);

    q35_read_spd(smb, bar, 0x50, spd[0], sizeof(spd[0]));
    q35_read_spd(smb, bar, 0x51, spd[1], sizeof(spd[1]));

    g_assert_cmpuint(spd_ddr3_decode_mb(spd[0]), ==, 4096);
    g_assert_cmpuint(spd_ddr3_decode_mb(spd[1]), ==, 2048);
    g_assert_cmphex(spd[0][7], ==, 0x01); /* 4 GiB: x8 */
    g_assert_cmphex(spd[1][7], ==, 0x02); /* 2 GiB: x16 */
    for (i = 0; i < 2; i++) {
        uint16_t crc = spd_test_crc16(spd[i], 117);

        g_assert_cmphex(spd[i][126] | (spd[i][127] << 8), ==, crc);
    }

    qpci_iounmap(smb, bar);
    g_free(smb);
    qpci_free_pc(pcibus);
    qtest_quit(qts);

    q35_test_restore_env("QEMU_SPD_SLOTS", saved_slots);
    q35_test_restore_env("QEMU_SPD_SPEED_MT", saved_speed);
    q35_test_restore_env("QEMU_SPD_MODULE_MB_LIST", saved_module_list);
    q35_test_restore_env("QEMU_SPD_MODULE_MB", saved_module);
    q35_test_restore_env("QEMU_SPD_TYPE", saved_type);
    q35_test_restore_spd_detail_env(&saved_details);
}

static void test_spd_ddr3_per_slot_geometry_and_identity(void)
{
    static const uint8_t expected_density[] = { 0x04, 0x03, 0x04, 0x03 };
    static const uint8_t expected_addressing[] = { 0x19, 0x19, 0x21, 0x19 };
    static const uint8_t expected_organization[] = { 0x02, 0x01, 0x01,
                                                     0x09 };
    static const uint16_t expected_trfc[] = { 0x0820, 0x0500, 0x0820,
                                              0x0500 };
    static const uint8_t expected_module_mfr[][2] = {
        { 0x01, 0x98 }, { 0x80, 0xad }, { 0x80, 0xce }, { 0x80, 0xad },
    };
    static const uint8_t expected_dram_mfr[][2] = {
        { 0x00, 0x00 }, { 0x80, 0xad }, { 0x80, 0xce }, { 0x80, 0xad },
    };
    static const uint8_t expected_serial[][4] = {
        { 0x12, 0x34, 0x56, 0x78 },
        { 0x12, 0x34, 0x56, 0x79 },
        { 0xa1, 0xb2, 0xc3, 0xd4 },
        { 0xa1, 0xb2, 0xc3, 0xd5 },
    };
    static const char * const expected_part[] = {
        "KVR13N9S6/2",
        "HMT325U6CFR8C-H9",
        "M378B5173QH0-CK0",
        "HMT351U6CFR8C-PB",
    };
    g_autofree char *saved_type = q35_test_setenv("QEMU_SPD_TYPE", "DDR3");
    g_autofree char *saved_module = q35_test_unsetenv("QEMU_SPD_MODULE_MB");
    g_autofree char *saved_module_list = q35_test_setenv(
        "QEMU_SPD_MODULE_MB_LIST", "2048,2048,4096,4096");
    g_autofree char *saved_speed = q35_test_setenv("QEMU_SPD_SPEED_MT",
                                                   "1600");
    g_autofree char *saved_slots = q35_test_setenv("QEMU_SPD_SLOTS", "4");
    g_autofree char *saved_ranks = q35_test_setenv("QEMU_SPD_RANK_LIST",
                                                   "1,1,1,2");
    g_autofree char *saved_widths = q35_test_setenv(
        "QEMU_SPD_DEVICE_WIDTH_LIST", "16,8,8,8");
    g_autofree char *saved_module_mfr = q35_test_setenv(
        "QEMU_SPD_MODULE_MFR_JEP106_LIST", "0198,80AD,80CE,80AD");
    g_autofree char *saved_dram_mfr = q35_test_setenv(
        "QEMU_SPD_DRAM_MFR_JEP106_LIST", "0000,80AD,80CE,80AD");
    g_autofree char *saved_serial = q35_test_setenv(
        "QEMU_SPD_SERIAL_LIST",
        "12345678,12345679,A1B2C3D4,A1B2C3D5");
    g_autofree char *saved_part = q35_test_setenv(
        "QEMU_SPD_PART_LIST",
        "KVR13N9S6/2,HMT325U6CFR8C-H9,M378B5173QH0-CK0,"
        "HMT351U6CFR8C-PB");
    uint8_t spd[4][256];
    QPCIBus *pcibus;
    QPCIDevice *smb;
    QPCIBar bar;
    QTestState *qts;
    size_t slot;

    qts = qtest_init("-M q35 -m 12G");
    pcibus = qpci_new_pc(qts, NULL);
    g_assert_nonnull(pcibus);

    smb = qpci_device_find(pcibus,
                           QPCI_DEVFN(ICH9_SMB_DEV, ICH9_SMB_FUNC));
    g_assert_nonnull(smb);
    qpci_device_enable(smb);
    bar = qpci_iomap(smb, ICH9_SMB_SMB_BASE_BAR, NULL);
    qpci_config_writeb(smb, ICH9_SMB_HOSTC,
                       qpci_config_readb(smb, ICH9_SMB_HOSTC) |
                       ICH9_SMB_HOSTC_HST_EN);

    for (slot = 0; slot < G_N_ELEMENTS(spd); slot++) {
        uint8_t padded_part[SMBUS_EEPROM_DDR3_PART_NUMBER_LEN];
        uint16_t crc;

        q35_read_spd(smb, bar, 0x50 + slot, spd[slot], sizeof(spd[slot]));
        g_assert_cmphex(spd[slot][4], ==, expected_density[slot]);
        g_assert_cmphex(spd[slot][5], ==, expected_addressing[slot]);
        g_assert_cmphex(spd[slot][7], ==, expected_organization[slot]);
        g_assert_cmphex(spd[slot][24] | (spd[slot][25] << 8), ==,
                        expected_trfc[slot]);
        g_assert_cmpuint(spd_ddr3_decode_mb(spd[slot]), ==,
                         slot < 2 ? 2048 : 4096);

        g_assert_cmpmem(&spd[slot][117], 2, expected_module_mfr[slot], 2);
        g_assert_cmpmem(&spd[slot][122], 4, expected_serial[slot], 4);
        memset(padded_part, ' ', sizeof(padded_part));
        memcpy(padded_part, expected_part[slot], strlen(expected_part[slot]));
        g_assert_cmpmem(&spd[slot][128], sizeof(padded_part), padded_part,
                        sizeof(padded_part));
        g_assert_cmpmem(&spd[slot][148], 2, expected_dram_mfr[slot], 2);

        crc = spd_test_crc16(spd[slot], 117);
        g_assert_cmphex(spd[slot][126] | (spd[slot][127] << 8), ==, crc);
    }

    qpci_iounmap(smb, bar);
    g_free(smb);
    qpci_free_pc(pcibus);
    qtest_quit(qts);

    q35_test_restore_env("QEMU_SPD_PART_LIST", saved_part);
    q35_test_restore_env("QEMU_SPD_SERIAL_LIST", saved_serial);
    q35_test_restore_env("QEMU_SPD_DRAM_MFR_JEP106_LIST", saved_dram_mfr);
    q35_test_restore_env("QEMU_SPD_MODULE_MFR_JEP106_LIST",
                         saved_module_mfr);
    q35_test_restore_env("QEMU_SPD_DEVICE_WIDTH_LIST", saved_widths);
    q35_test_restore_env("QEMU_SPD_RANK_LIST", saved_ranks);
    q35_test_restore_env("QEMU_SPD_SLOTS", saved_slots);
    q35_test_restore_env("QEMU_SPD_SPEED_MT", saved_speed);
    q35_test_restore_env("QEMU_SPD_MODULE_MB_LIST", saved_module_list);
    q35_test_restore_env("QEMU_SPD_MODULE_MB", saved_module);
    q35_test_restore_env("QEMU_SPD_TYPE", saved_type);
}

static void test_spd_invalid_module_size(void)
{
    g_auto(GStrv) env = g_get_environ();
    g_autofree char *stdout_data = NULL;
    g_autofree char *stderr_data = NULL;
    g_autoptr(GError) error = NULL;
    char *argv[] = {
        (char *)qtest_qemu_binary(NULL),
        (char *)"-M", (char *)"q35,help",
        NULL,
    };
    int wait_status;

    env = q35_test_unset_spd_details_from_environ(env);
    env = g_environ_unsetenv(env, "QEMU_SPD_MODULE_MB_LIST");
    env = g_environ_setenv(env, "QEMU_SPD_MODULE_MB", "3072", true);
    g_assert_true(g_spawn_sync(NULL, argv, env, 0, NULL, NULL,
                               &stdout_data, &stderr_data, &wait_status,
                               &error));
    g_assert_no_error(error);
    g_assert_false(g_spawn_check_exit_status(wait_status, &error));
    g_assert_nonnull(error);
    g_clear_error(&error);
    g_assert_nonnull(strstr(stderr_data,
                           "QEMU_SPD_MODULE_MB must be exactly 2048 or 4096"));
}

static void test_spd_invalid_module_list(void)
{
    const struct {
        const char *list;
        const char *slots;
        const char *legacy;
        const char *error_text;
    } cases[] = {
        { "4096,3072", "2", NULL,
          "entry 1 must be exactly 2048 or 4096" },
        { "4096", "2", NULL,
          "must contain exactly 2 entries" },
        { "4096,2048", "2", "4096",
          "cannot be used together" },
    };
    size_t i;

    for (i = 0; i < ARRAY_SIZE(cases); i++) {
        g_auto(GStrv) env = g_get_environ();
        g_autofree char *stdout_data = NULL;
        g_autofree char *stderr_data = NULL;
        g_autoptr(GError) error = NULL;
        char *argv[] = {
            (char *)qtest_qemu_binary(NULL),
            (char *)"-M", (char *)"q35,help",
            NULL,
        };
        int wait_status;

        env = g_environ_setenv(env, "QEMU_SPD_MODULE_MB_LIST",
                               cases[i].list, true);
        env = g_environ_setenv(env, "QEMU_SPD_SLOTS",
                               cases[i].slots, true);
        if (cases[i].legacy) {
            env = g_environ_setenv(env, "QEMU_SPD_MODULE_MB",
                                   cases[i].legacy, true);
        } else {
            env = g_environ_unsetenv(env, "QEMU_SPD_MODULE_MB");
        }
        env = q35_test_unset_spd_details_from_environ(env);
        g_assert_true(g_spawn_sync(NULL, argv, env, 0, NULL, NULL,
                                   &stdout_data, &stderr_data, &wait_status,
                                   &error));
        g_assert_no_error(error);
        g_assert_false(g_spawn_check_exit_status(wait_status, &error));
        g_assert_nonnull(error);
        g_clear_error(&error);
        g_assert_nonnull(strstr(stderr_data, cases[i].error_text));
    }
}

static void test_spd_invalid_ddr3_details(void)
{
    const struct {
        const char *name;
        const char *value;
        const char *error_text;
    } cases[] = {
        { "QEMU_SPD_PART_LIST", NULL,
          "QEMU DDR3 SPD details are atomic" },
        { "QEMU_SPD_DEVICE_WIDTH_LIST", "16,32",
          "must be exactly 8 or 16" },
        { "QEMU_SPD_SERIAL_LIST", "12345678,12345678",
          "must be unique" },
        { "QEMU_SPD_SERIAL_LIST", "00000000,12345679",
          "uses reserved serial" },
        { "QEMU_SPD_MODULE_MFR_JEP106_LIST", "0000,80AD",
          "cannot be 0000" },
        { "QEMU_SPD_RANK_LIST", "2,1",
          "unsupported DDR3 SPD geometry at slot 0" },
        { "QEMU_SPD_TYPE", "DDR4",
          "detail lists require QEMU_SPD_TYPE=DDR3" },
        { "QEMU_SPD_DRAM_MFR_JEP106_LIST", "80AD",
          "must contain exactly 2 entries" },
        { "QEMU_SPD_PART_LIST", "PART-NUMBER-TOO-LONG,HMT351U6CFR8C-PB",
          "must contain 1 to 18 characters" },
    };
    size_t i;

    for (i = 0; i < G_N_ELEMENTS(cases); i++) {
        g_auto(GStrv) env = g_get_environ();
        g_autofree char *stdout_data = NULL;
        g_autofree char *stderr_data = NULL;
        g_autoptr(GError) error = NULL;
        char *argv[] = {
            (char *)qtest_qemu_binary(NULL),
            (char *)"-M", (char *)"q35,help",
            NULL,
        };
        int wait_status;

        env = q35_test_unset_spd_details_from_environ(env);
        env = g_environ_setenv(env, "QEMU_SPD_TYPE", "DDR3", true);
        env = g_environ_unsetenv(env, "QEMU_SPD_MODULE_MB");
        env = g_environ_setenv(env, "QEMU_SPD_MODULE_MB_LIST",
                               "2048,4096", true);
        env = g_environ_setenv(env, "QEMU_SPD_SLOTS", "2", true);
        env = g_environ_setenv(env, "QEMU_SPD_RANK_LIST", "1,1", true);
        env = g_environ_setenv(env, "QEMU_SPD_DEVICE_WIDTH_LIST", "16,8",
                               true);
        env = g_environ_setenv(env, "QEMU_SPD_MODULE_MFR_JEP106_LIST",
                               "0198,80AD", true);
        env = g_environ_setenv(env, "QEMU_SPD_SERIAL_LIST",
                               "12345678,12345679", true);
        env = g_environ_setenv(env, "QEMU_SPD_PART_LIST",
                               "KVR13N9S6/2,HMT351U6CFR8C-PB", true);
        if (cases[i].value) {
            env = g_environ_setenv(env, cases[i].name, cases[i].value, true);
        } else {
            env = g_environ_unsetenv(env, cases[i].name);
        }

        g_assert_true(g_spawn_sync(NULL, argv, env, 0, NULL, NULL,
                                   &stdout_data, &stderr_data, &wait_status,
                                   &error));
        g_assert_no_error(error);
        g_assert_false(g_spawn_check_exit_status(wait_status, &error));
        g_assert_nonnull(error);
        g_clear_error(&error);
        g_assert_nonnull(strstr(stderr_data, cases[i].error_text));
    }
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);

    qtest_add_func("/q35/smram/lock", test_smram_lock);

    qtest_add_data_func("/q35/tseg-size/1mb", &tseg_1mb, test_tseg_size);
    qtest_add_data_func("/q35/tseg-size/2mb", &tseg_2mb, test_tseg_size);
    qtest_add_data_func("/q35/tseg-size/8mb", &tseg_8mb, test_tseg_size);
    qtest_add_data_func("/q35/tseg-size/ext/16mb", &tseg_ext_16mb,
                        test_tseg_size);
    qtest_add_func("/q35/smram/smbase_lock", test_smram_smbase_lock);
    qtest_add_data_func("/q35/spd/ddr3/2g-1333", &spd_ddr3_2g_1333,
                        test_spd_ddr3);
    qtest_add_data_func("/q35/spd/ddr3/2g-1600", &spd_ddr3_2g_1600,
                        test_spd_ddr3);
    qtest_add_data_func("/q35/spd/ddr3/4g-1333", &spd_ddr3_4g_1333,
                        test_spd_ddr3);
    qtest_add_data_func("/q35/spd/ddr3/4g-1600", &spd_ddr3_4g_1600,
                        test_spd_ddr3);
    qtest_add_func("/q35/spd/ddr3/mixed-4g-2g",
                   test_spd_ddr3_mixed_modules);
    qtest_add_func("/q35/spd/ddr3/per-slot-geometry-and-identity",
                   test_spd_ddr3_per_slot_geometry_and_identity);
    qtest_add_func("/q35/spd/invalid-module-size",
                   test_spd_invalid_module_size);
    qtest_add_func("/q35/spd/invalid-module-list",
                   test_spd_invalid_module_list);
    qtest_add_func("/q35/spd/invalid-ddr3-details",
                   test_spd_invalid_ddr3_details);

    return g_test_run();
}
