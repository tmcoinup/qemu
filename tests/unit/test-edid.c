/*
 * QEMU EDID generator tests
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/bswap.h"
#include "hw/display/edid.h"

#define EDID_BLOCK_SIZE 128

static uint16_t vendor_id(const char *vendor)
{
    return (((vendor[0] - '@') & 0x1f) << 10) |
           (((vendor[1] - '@') & 0x1f) << 5) |
           (((vendor[2] - '@') & 0x1f) << 0);
}

static void assert_checksums(const uint8_t *edid)
{
    size_t size = qemu_edid_size((uint8_t *)edid);
    size_t offset;

    g_assert_cmpuint(size, >, 0);
    for (offset = 0; offset < size; offset += EDID_BLOCK_SIZE) {
        unsigned int sum = 0;
        int i;

        for (i = 0; i < EDID_BLOCK_SIZE; i++) {
            sum += edid[offset + i];
        }
        g_assert_cmpuint(sum & 0xff, ==, 0);
    }
}

static const uint8_t *find_descriptor(const uint8_t *edid, uint8_t type)
{
    unsigned int offset;

    for (offset = 54; offset <= 108; offset += 18) {
        const uint8_t *desc = edid + offset;

        if (desc[0] == 0 && desc[1] == 0 && desc[2] == 0 &&
            desc[3] == type) {
            return desc;
        }
    }

    if (edid[126] && edid[128] == 0x02) {
        for (offset = 128 + edid[130]; offset + 18 <= 255; offset += 18) {
            const uint8_t *desc = edid + offset;

            if (desc[0] == 0 && desc[1] == 0 && desc[2] == 0 &&
                desc[3] == type) {
                return desc;
            }
        }
    }

    return NULL;
}

static unsigned int dtd_xres(const uint8_t *dtd)
{
    return dtd[2] | ((dtd[4] & 0xf0) << 4);
}

static unsigned int dtd_yres(const uint8_t *dtd)
{
    return dtd[5] | ((dtd[7] & 0xf0) << 4);
}

static unsigned int dtd_width_mm(const uint8_t *dtd)
{
    return dtd[12] | ((dtd[14] & 0xf0) << 4);
}

static unsigned int dtd_height_mm(const uint8_t *dtd)
{
    return dtd[13] | ((dtd[14] & 0x0f) << 8);
}

static void test_metadata(void)
{
    uint8_t edid[1024] = { 0 };
    qemu_edid_info info = {
        .vendor = "AOC",
        .name = "24G2E5",
        .serial = "CNV123456789",
        .product_id = 0x2401,
        .week = 18,
        .year = 2022,
        .video_input = 0xa3,
        .range_min_v = 48,
        .range_max_v = 76,
        .range_min_h = 30,
        .range_max_h = 85,
        .max_clock = 180,
        .width_mm = 527,
        .height_mm = 296,
        .prefx = 1920,
        .prefy = 1080,
        .maxx = 1920,
        .maxy = 1080,
        .refresh_rate = 60000,
    };
    const uint8_t *dtd;
    const uint8_t *range;
    const uint8_t *name;
    const uint8_t *serial;

    qemu_edid_generate(edid, sizeof(edid), &info);

    g_assert_cmpuint(qemu_edid_size(edid), ==, 256);
    g_assert_cmpuint(lduw_be_p(edid + 8), ==, vendor_id("AOC"));
    g_assert_cmpuint(lduw_le_p(edid + 10), ==, 0x2401);
    g_assert_cmpuint(ldl_le_p(edid + 12), !=, 0);
    g_assert_cmpuint(edid[16], ==, 18);
    g_assert_cmpuint(edid[17] + 1990, ==, 2022);
    g_assert_cmphex(edid[20], ==, 0xa3);
    g_assert_cmpuint(edid[21], ==, 53);
    g_assert_cmpuint(edid[22], ==, 30);

    dtd = edid + 54;
    g_assert_cmpuint(lduw_le_p(dtd), ==, 14850);
    g_assert_cmpuint(dtd_xres(dtd), ==, 1920);
    g_assert_cmpuint(dtd_yres(dtd), ==, 1080);
    g_assert_cmpuint(dtd_width_mm(dtd), ==, 527);
    g_assert_cmpuint(dtd_height_mm(dtd), ==, 296);

    range = find_descriptor(edid, 0xfd);
    g_assert_nonnull(range);
    g_assert_cmpuint(range[5], ==, 48);
    g_assert_cmpuint(range[6], ==, 76);
    g_assert_cmpuint(range[7], ==, 30);
    g_assert_cmpuint(range[8], ==, 85);
    g_assert_cmpuint(range[9], ==, 18);

    name = find_descriptor(edid, 0xfc);
    g_assert_nonnull(name);
    g_assert_cmpmem(name + 5, 6, "24G2E5", 6);
    serial = find_descriptor(edid, 0xff);
    g_assert_nonnull(serial);
    g_assert_cmpmem(serial + 5, 12, "CNV123456789", 12);

    assert_checksums(edid);
}

static void test_legacy_windows_modes(void)
{
    uint8_t edid[1024] = { 0 };
    qemu_edid_info info = {
        .vendor = "DEL",
        .name = "SE2419HR",
        .serial = "CN0123456789",
        .product_id = 0xa0e2,
        .width_mm = 527,
        .height_mm = 296,
        .prefx = 1920,
        .prefy = 1080,
        .maxx = 1920,
        .maxy = 1080,
        .refresh_rate = 60000,
    };
    const uint8_t *xtra3;
    unsigned int dtd_count = 0;
    unsigned int offset;
    int i;

    qemu_edid_generate(edid, sizeof(edid), &info);

    /* The buggy driver must never see EDID 1.3 standard aspect codes. */
    for (i = 38; i < 54; i += 2) {
        g_assert_cmphex(edid[i], ==, 0x01);
        g_assert_cmphex(edid[i + 1], ==, 0x01);
    }

    g_assert_cmphex(edid[35], ==, 0x21); /* 800x600, 640x480 */
    g_assert_cmphex(edid[36], ==, 0x08); /* 1024x768 */
    g_assert_cmphex(edid[37], ==, 0x00);

    xtra3 = find_descriptor(edid, 0xf7);
    g_assert_nonnull(xtra3);
    g_assert_cmphex(xtra3[5], ==, 0x0a);
    g_assert_cmphex(xtra3[6], ==, 0x00); /* no 75 Hz mode outside some ranges */
    g_assert_cmphex(xtra3[7], ==, 0x4a); /* three 1280-wide modes */
    g_assert_cmphex(xtra3[8], ==, 0xa0); /* 1360x768, 1440x900 */
    g_assert_cmphex(xtra3[9], ==, 0x20); /* 1680x1050 */
    g_assert_cmphex(xtra3[10], ==, 0x00); /* no 1920x1200 */
    g_assert_cmphex(xtra3[11], ==, 0x00); /* no modes above 1080p */

    /* CTA video data block: 1080p60 and 720p60 only. */
    g_assert_cmphex(edid[128], ==, 0x02);
    g_assert_cmphex(edid[129], ==, 0x03);
    g_assert_cmphex(edid[130], ==, 0x07);
    g_assert_cmphex(edid[132], ==, 0x42);
    g_assert_cmphex(edid[133], ==, 16);
    g_assert_cmphex(edid[134], ==, 4);

    /* 1600x900 is not advertised as a secondary DTD. */
    for (offset = 54; offset <= 108; offset += 18) {
        const uint8_t *desc = edid + offset;

        if (desc[0] || desc[1]) {
            dtd_count++;
            g_assert_cmpuint(dtd_xres(desc), ==, 1920);
            g_assert_cmpuint(dtd_yres(desc), ==, 1080);
        }
    }
    g_assert_cmpuint(dtd_count, ==, 1);

    assert_checksums(edid);
}

static void test_generic_defaults(void)
{
    uint8_t edid[1024] = { 0 };
    qemu_edid_info info = {
        .prefx = 1920,
        .prefy = 1080,
        .maxx = 1920,
        .maxy = 1080,
        .refresh_rate = 60000,
    };
    const uint8_t *name;
    const uint8_t *range;

    qemu_edid_generate(edid, sizeof(edid), &info);

    g_assert_cmpuint(lduw_be_p(edid + 8), ==, vendor_id("RHT"));
    g_assert_cmphex(lduw_le_p(edid + 10), ==, 0x1234);
    g_assert_cmpuint(ldl_le_p(edid + 12), ==, 0);
    g_assert_cmpuint(edid[16], ==, 42);
    g_assert_cmpuint(edid[17] + 1990, ==, 2014);
    g_assert_cmphex(edid[20], ==, 0xa5);

    name = find_descriptor(edid, 0xfc);
    g_assert_nonnull(name);
    g_assert_cmpmem(name + 5, 12, "QEMU Monitor", 12);

    range = find_descriptor(edid, 0xfd);
    g_assert_nonnull(range);
    g_assert_cmpuint(range[5], ==, 50);
    g_assert_cmpuint(range[6], ==, 125);
    g_assert_cmpuint(range[7], ==, 30);
    g_assert_cmpuint(range[8], ==, 160);
    g_assert_cmpuint(range[9], ==, 255);

    assert_checksums(edid);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);

    g_test_add_func("/edid/metadata", test_metadata);
    g_test_add_func("/edid/legacy-windows-modes", test_legacy_windows_modes);
    g_test_add_func("/edid/generic-defaults", test_generic_defaults);

    return g_test_run();
}
