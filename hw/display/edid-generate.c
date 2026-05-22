/*
 * QEMU EDID generator.
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */
#include "qemu/osdep.h"
#include "qemu/bswap.h"
#include "hw/display/edid.h"

static const struct edid_mode {
    uint32_t xres;
    uint32_t yres;
    uint32_t byte;
    uint32_t xtra3;
    uint32_t bit;
    uint32_t dta;
} modes[] = {
    /*
     * Stealth: 我们的 stealth profile 模拟 24" 1080p 16:9 显示器
     * (Samsung S24F350F / AOC 24G2E5 / BenQ GW2480 等)。EDID 只暴露一个
     * 真实 1080p 显示器在 Windows 分辨率下拉里该有的【正常 1080p 列表】：
     * 16:9 主档 + 4:3 兼容档，不带任何 16:10 / 5:4 这类"非 1080p 面板"特征，
     * 更不带 > native 的 1920×1200。
     *
     * Win10 现代"显示设置"分辨率下拉【实测最终呈现】：
     *   1920×1080 / 1280×720 / 1024×768 / 800×600
     *   (640×480 在 established 里但现代下拉默认不列出)
     *
     * 注：另有一条 1600×900 第二 DTD（见 qemu_edid_generate 的 DTD2），仿真实
     * 显示器常见的次级 detailed timing 以增强 EDID 真实性。但 Windows/viogpudo
     * 的下拉只采纳【首条 DTD + CEA VIC + established】三类，不采纳第二条 DTD、
     * 也不采纳 generic standard timings（16:9 会被 Windows 误读成 16:10 冒出
     * 1920×1200 等幻影），所以 1600×900 不会出现在下拉里。要让它出现就得改
     * viogpudo 驱动 → 丢 WHQL → 关 DSE（testsigning/EfiGuard），与"全浅层 +
     * testsigning 关闭"的 ACE-安全约束冲突，故【不做】。
     *
     * 原 generic 表里被砍掉的：
     *  - 4K / 5K (3840×2160 / 5120×2160) → 1080p panel 不可能支持
     *  - 1920×1200 / 1680×1050 / 1280×800 → 16:10 工作站/笔记本特征
     *  - 1280×1024 / 1280×960 → 5:4 传统 LCD（非 16:9 面板特征）
     *
     * 保留（下拉可见）：
     *  - 1920×1080 16:9 (native, CEA-861 VIC 16)
     *  - 1280×720  16:9 (720p, CEA-861 VIC 4)
     *  - 1024×768 / 800×600 / 640×480 (4:3 established，真实显示器普遍带，
     *    且现代下拉只露到 800×600，不会把列表搞脏)
     */

    /*
     * dta/CEA-861 extension timings (@ 60 Hz) — 16:9 主档。
     * 16:9 模式【只】走 DTD + CEA-861 VIC，绝不进 generic standard-timing 槽：
     * Windows/viogpudo 会把 standard-timing 里 16:9 (aspect bits=11) 的模式
     * 误读成 16:10，于是 1920→1920×1200 / 1600→1600×1000 / 1280→1280×800
     * 全冒成幻影档（这正是"1920×1200 又出现"的根因）。
     */
    { .xres = 1920,   .yres = 1080,   .dta =  16 },   /* VIC 16, native 16:9 (= DTD1) */
    { .xres = 1280,   .yres =  720,   .dta =   4 },   /* VIC 4,  720p  16:9 */

    /* 1600×900 (16:9) 没有 CEA VIC、也不在 Est-Timings-III 位图里；作为次级
     * detailed timing 走第二条 DTD（见 qemu_edid_generate），仅增强 EDID 真实性，
     * Windows 下拉不会列出它（详见本表顶部注释），故不进本表。 */

    /* established timings (4:3 兼容档，@ 60Hz) */
    { .xres = 1024,   .yres =  768,   .byte  = 36,   .bit = 3 },
    { .xres =  800,   .yres =  600,   .byte  = 35,   .bit = 0 },
    { .xres =  640,   .yres =  480,   .byte  = 35,   .bit = 5 },
};

typedef struct Timings {
    uint32_t xfront;
    uint32_t xsync;
    uint32_t xblank;

    uint32_t yfront;
    uint32_t ysync;
    uint32_t yblank;

    uint64_t clock;
} Timings;

/*
 * Stealth: real CEA-861 / VESA DMT timings for common modes. The "thin
 * air" formula below produces blanking values that don't line up with
 * any hardware monitor (e.g. ~173 MHz dot clock for 1080p instead of
 * the standard 148.5 MHz), which is detectable when an EDID parser
 * cross-checks DTD math against expected VIC entries.
 */
struct std_timing {
    uint32_t xres, yres, refresh;
    uint32_t xfront, xsync, xblank;
    uint32_t yfront, ysync, yblank;
};

static const struct std_timing known_timings[] = {
    /* 1920x1080@60   CEA-861 VIC 16,  148.500 MHz */
    { 1920, 1080, 60000,  88,  44, 280,  4,  5, 45 },
    /* 1280x720@60    CEA-861 VIC 4,    74.250 MHz */
    { 1280,  720, 60000, 110,  40, 370,  5,  5, 30 },
    /* 1600x900@60    VESA CVT-RB,      97.750 MHz (DTD2) */
    { 1600,  900, 60000,  48,  32, 160,  3,  5, 26 },
    /* 1024x768@60    VESA DMT,         65.000 MHz */
    { 1024,  768, 60000,  24, 136, 320,  3,  6, 38 },
    /*  800x600@60    VESA DMT,         40.000 MHz */
    {  800,  600, 60000,  40, 128, 256,  1,  4, 28 },
    /*  640x480@60    VESA DMT,         25.175 MHz */
    {  640,  480, 60000,  16,  96, 160, 10,  2, 45 },
};

static void generate_timings(Timings *timings, uint32_t refresh_rate,
                             uint32_t xres, uint32_t yres)
{
    int i;

    for (i = 0; i < ARRAY_SIZE(known_timings); i++) {
        const struct std_timing *k = &known_timings[i];
        if (k->xres == xres && k->yres == yres && k->refresh == refresh_rate) {
            timings->xfront = k->xfront;
            timings->xsync  = k->xsync;
            timings->xblank = k->xblank;
            timings->yfront = k->yfront;
            timings->ysync  = k->ysync;
            timings->yblank = k->yblank;
            timings->clock  = ((uint64_t)refresh_rate *
                               (xres + timings->xblank) *
                               (yres + timings->yblank)) / 10000000;
            return;
        }
    }

    /* fall back: pull some realistic looking timings out of thin air */
    timings->xfront = xres * 25 / 100;
    timings->xsync  = xres *  3 / 100;
    timings->xblank = xres * 35 / 100;

    timings->yfront = yres *  5 / 1000;
    timings->ysync  = yres *  5 / 1000;
    timings->yblank = yres * 35 / 1000;

    timings->clock  = ((uint64_t)refresh_rate *
                       (xres + timings->xblank) *
                       (yres + timings->yblank)) / 10000000;
}

static void edid_ext_dta(uint8_t *dta)
{
    dta[0] = 0x02;
    dta[1] = 0x03;
    dta[2] = 0x05;
    dta[3] = 0x00;

    /* video data block */
    dta[4] = 0x40;
}

static void edid_ext_dta_mode(uint8_t *dta, uint8_t nr)
{
    dta[dta[2]] = nr;
    dta[2]++;
    dta[4]++;
}

static int edid_std_mode(uint8_t *mode, uint32_t xres, uint32_t yres)
{
    uint32_t aspect;

    if (xres == 0 || yres == 0) {
        mode[0] = 0x01;
        mode[1] = 0x01;
        return 0;

    } else if (xres * 10 == yres * 16) {
        aspect = 0;
    } else if (xres * 3 == yres * 4) {
        aspect = 1;
    } else if (xres * 4 == yres * 5) {
        aspect = 2;
    } else if (xres * 9 == yres * 16) {
        aspect = 3;
    } else {
        return -1;
    }

    if ((xres / 8) - 31 > 255) {
        return -1;
    }

    mode[0] = (xres / 8) - 31;
    mode[1] = ((aspect << 6) | (60 - 60));
    return 0;
}

static void edid_fill_modes(uint8_t *edid, uint8_t *xtra3, uint8_t *dta,
                            uint32_t maxx, uint32_t maxy)
{
    const struct edid_mode *mode;
    int i;

    /*
     * Stealth: 不再发 generic standard timings。Windows/viogpudo 会把
     * standard-timing 里 16:9 (aspect bits=11) 的模式误读成 16:10，于是
     * 1920→1920×1200 / 1600→1600×1000 / 1280→1280×800 全冒成幻影档。
     * 16:9 模式改走 DTD (native + 1600×900) 与 CEA-861 VIC，4:3 兼容档走
     * established bitmap —— 这里只处理 established / xtra3 / dta(CEA)。
     */
    for (i = 0; i < ARRAY_SIZE(modes); i++) {
        mode = modes + i;

        if ((maxx && mode->xres > maxx) ||
            (maxy && mode->yres > maxy)) {
            continue;
        }

        if (mode->byte) {
            edid[mode->byte] |= (1 << mode->bit);
        } else if (mode->xtra3 && xtra3) {
            xtra3[mode->xtra3] |= (1 << mode->bit);
        }

        if (dta && mode->dta) {
            edid_ext_dta_mode(dta, mode->dta);
        }
    }

    /* 8 个 standard-timing 槽 (byte 38..53) 全部标记为未用 (0x01 0x01)。 */
    for (i = 38; i < 54; i += 2) {
        edid_std_mode(edid + i, 0, 0);
    }
}

static void edid_checksum(uint8_t *edid, size_t len)
{
    uint32_t sum = 0;
    int i;

    for (i = 0; i < len; i++) {
        sum += edid[i];
    }
    sum &= 0xff;
    if (sum) {
        edid[len] = 0x100 - sum;
    }
}

static uint8_t *edid_desc_next(uint8_t *edid, uint8_t *dta, uint8_t *desc)
{
    if (desc == NULL) {
        return NULL;
    }
    if (desc + 18 + 18 < edid + 127) {
        return desc + 18;
    }
    if (dta) {
        if (desc < edid + 127) {
            return dta + dta[2];
        }
        if (desc + 18 + 18 < dta + 127) {
            return desc + 18;
        }
    }
    return NULL;
}

static void edid_desc_type(uint8_t *desc, uint8_t type)
{
    desc[0] = 0;
    desc[1] = 0;
    desc[2] = 0;
    desc[3] = type;
    desc[4] = 0;
}

static void edid_desc_text(uint8_t *desc, uint8_t type,
                           const char *text)
{
    size_t len;

    edid_desc_type(desc, type);
    memset(desc + 5, ' ', 13);

    len = strlen(text);
    if (len > 12) {
        len = 12;
    }
    memcpy(desc + 5, text, len);
    desc[5 + len] = '\n';
}

static void edid_desc_ranges(uint8_t *desc)
{
    edid_desc_type(desc, 0xfd);

    /*
     * Stealth: Samsung S24F350F datasheet limits.
     *   vfreq        50 -> 75  Hz
     *   hfreq        30 -> 83  kHz
     *   max dot clock         170 MHz
     *
     * The previous wide-open 50-125 / 30-160 / 2550 MHz range is itself
     * a virtual-display fingerprint — physical monitors have narrow,
     * spec-bounded scan limits.
     */
    desc[5] =  50;
    desc[6] =  75;

    desc[7] =  30;
    desc[8] =  83;

    desc[9] = 170 / 10;

    /* no extended timing information */
    desc[10] = 0x01;

    /* padding */
    desc[11] = '\n';
    memset(desc + 12, ' ', 6);
}

static void edid_desc_dummy(uint8_t *desc)
{
    edid_desc_type(desc, 0x10);
}

static void edid_desc_timing(uint8_t *desc, const Timings *timings,
                             uint32_t xres, uint32_t yres,
                             uint32_t xmm, uint32_t ymm)
{
    stw_le_p(desc, timings->clock);

    desc[2] = xres   & 0xff;
    desc[3] = timings->xblank & 0xff;
    desc[4] = (((xres   & 0xf00) >> 4) |
               ((timings->xblank & 0xf00) >> 8));

    desc[5] = yres   & 0xff;
    desc[6] = timings->yblank & 0xff;
    desc[7] = (((yres   & 0xf00) >> 4) |
               ((timings->yblank & 0xf00) >> 8));

    desc[8] = timings->xfront & 0xff;
    desc[9] = timings->xsync  & 0xff;

    desc[10] = (((timings->yfront & 0x00f) << 4) |
                ((timings->ysync  & 0x00f) << 0));
    desc[11] = (((timings->xfront & 0x300) >> 2) |
                ((timings->xsync  & 0x300) >> 4) |
                ((timings->yfront & 0x030) >> 2) |
                ((timings->ysync  & 0x030) >> 4));

    desc[12] = xmm & 0xff;
    desc[13] = ymm & 0xff;
    desc[14] = (((xmm & 0xf00) >> 4) |
                ((ymm & 0xf00) >> 8));

    desc[17] = 0x18;
}

static uint32_t edid_to_10bit(float value)
{
    return (uint32_t)(value * 1024 + 0.5);
}

static void edid_colorspace(uint8_t *edid,
                            float rx, float ry,
                            float gx, float gy,
                            float bx, float by,
                            float wx, float wy)
{
    uint32_t red_x   = edid_to_10bit(rx);
    uint32_t red_y   = edid_to_10bit(ry);
    uint32_t green_x = edid_to_10bit(gx);
    uint32_t green_y = edid_to_10bit(gy);
    uint32_t blue_x  = edid_to_10bit(bx);
    uint32_t blue_y  = edid_to_10bit(by);
    uint32_t white_x = edid_to_10bit(wx);
    uint32_t white_y = edid_to_10bit(wy);

    edid[25] = (((red_x   & 0x03) << 6) |
                ((red_y   & 0x03) << 4) |
                ((green_x & 0x03) << 2) |
                ((green_y & 0x03) << 0));
    edid[26] = (((blue_x  & 0x03) << 6) |
                ((blue_y  & 0x03) << 4) |
                ((white_x & 0x03) << 2) |
                ((white_y & 0x03) << 0));
    edid[27] = red_x   >> 2;
    edid[28] = red_y   >> 2;
    edid[29] = green_x >> 2;
    edid[30] = green_y >> 2;
    edid[31] = blue_x  >> 2;
    edid[32] = blue_y  >> 2;
    edid[33] = white_x >> 2;
    edid[34] = white_y >> 2;
}

static uint32_t qemu_edid_dpi_from_mm(uint32_t mm, uint32_t res)
{
    return res * 254 / 10 / mm;
}

uint32_t qemu_edid_dpi_to_mm(uint32_t dpi, uint32_t res)
{
    return res * 254 / 10 / dpi;
}

static void init_displayid(uint8_t *did)
{
    did[0] = 0x70; /* display id extension */
    did[1] = 0x13; /* version 1.3 */
    did[2] = 4;    /* length */
    did[3] = 0x03; /* product type (0x03 == standalone display device) */
    edid_checksum(did + 1, did[2] + 4);
}

static void qemu_displayid_generate(uint8_t *did, const Timings *timings,
                                    uint32_t xres, uint32_t yres,
                                    uint32_t xmm, uint32_t ymm)
{
    did[0] = 0x70; /* display id extension */
    did[1] = 0x13; /* version 1.3 */
    did[2] = 23;   /* length */
    did[3] = 0x03; /* product type (0x03 == standalone display device) */

    did[5] = 0x03; /* Detailed Timings Data Block */
    did[6] = 0x00; /* revision */
    did[7] = 0x14; /* block length */

    did[8]  = timings->clock  & 0xff;
    did[9]  = (timings->clock & 0xff00) >> 8;
    did[10] = (timings->clock & 0xff0000) >> 16;

    did[11] = 0x88; /* leave aspect ratio undefined */

    stw_le_p(did + 12, 0xffff & (xres - 1));
    stw_le_p(did + 14, 0xffff & (timings->xblank - 1));
    stw_le_p(did + 16, 0xffff & (timings->xfront - 1));
    stw_le_p(did + 18, 0xffff & (timings->xsync - 1));

    stw_le_p(did + 20, 0xffff & (yres - 1));
    stw_le_p(did + 22, 0xffff & (timings->yblank - 1));
    stw_le_p(did + 24, 0xffff & (timings->yfront - 1));
    stw_le_p(did + 26, 0xffff & (timings->ysync - 1));

    edid_checksum(did + 1, did[2] + 4);
}

void qemu_edid_generate(uint8_t *edid, size_t size,
                        qemu_edid_info *info)
{
    Timings timings;
    Timings timings2;
    uint8_t *desc = edid + 54;
    uint8_t *xtra3 = NULL;
    uint8_t *dta = NULL;
    uint8_t *did = NULL;
    uint32_t width_mm, height_mm;
    /*
     * Stealth: 60 Hz preferred timing, not 75. Real Samsung S24F350F's
     * preferred mode in the EDID is 1920x1080@60 — 75 Hz at 1080p is
     * uncommon enough to be a tell on its own.
     */
    uint32_t refresh_rate = info->refresh_rate ? info->refresh_rate : 60000;
    uint32_t dpi = 100; /* if no width_mm/height_mm */
    uint32_t large_screen = 0;

    /* =============== set defaults  =============== */

    if (!info->vendor || strlen(info->vendor) != 3) {
        info->vendor = "SAM";
    }
    if (!info->name) {
        info->name = "S24F350";
    }
    if (!info->serial) {
        /*
         * Real monitors always carry a 0xff serial-number descriptor;
         * a missing one is itself a fingerprint. Default to a 12-char
         * Samsung-format serial. (atoi() of this is also non-zero, so
         * the binary serial slot at edid[12..15] gets a non-default
         * value too.)
         */
        info->serial = "H4ZK500001VL";
    }
    if (!info->prefx) {
        info->prefx = 1920;
    }
    if (!info->prefy) {
        info->prefy = 1080;
    }
    if (info->width_mm && info->height_mm) {
        width_mm = info->width_mm;
        height_mm = info->height_mm;
        dpi = qemu_edid_dpi_from_mm(width_mm, info->prefx);
    } else if (info->prefx == 1920 && info->prefy == 1080) {
        /* Stealth: 24" 16:9 ≈ 530 × 300 mm — matches Samsung S24F350F.
         * The earlier 100 dpi default produced ~488 × 274 mm, closer
         * to a 22" panel and inconsistent with the spoofed model. */
        width_mm = 530;
        height_mm = 300;
        dpi = qemu_edid_dpi_from_mm(width_mm, info->prefx);
    } else {
        width_mm = qemu_edid_dpi_to_mm(dpi, info->prefx);
        height_mm = qemu_edid_dpi_to_mm(dpi, info->prefy);
    }

    generate_timings(&timings, refresh_rate, info->prefx, info->prefy);
    if (info->prefx >= 4096 || info->prefy >= 4096 || timings.clock >= 65536) {
        large_screen = 1;
    }

    /* =============== extensions  =============== */

    if (size >= 256) {
        dta = edid + 128;
        edid[126]++;
        edid_ext_dta(dta);
    }

    if (size >= 384 && large_screen) {
        did = edid + 256;
        edid[126]++;
        init_displayid(did);
    }

    /* =============== header information =============== */

    /* fixed */
    edid[0] = 0x00;
    edid[1] = 0xff;
    edid[2] = 0xff;
    edid[3] = 0xff;
    edid[4] = 0xff;
    edid[5] = 0xff;
    edid[6] = 0xff;
    edid[7] = 0x00;

    /* manufacturer id, product code, serial number */
    uint16_t vendor_id = ((((info->vendor[0] - '@') & 0x1f) << 10) |
                          (((info->vendor[1] - '@') & 0x1f) <<  5) |
                          (((info->vendor[2] - '@') & 0x1f) <<  0));
    /*
     * deploy stealth: avoid the recognizable 0x1234 "QEMU Monitor"
     * product code. SAM:0x0F65 is the real product code Samsung's
     * S24F350F panel reports — confirmed against multiple Linux EDID
     * dumps in the wild — so MONITOR\SAM0F65 is a plausible HardwareID
     * for the spoofed name "Samsung S24F350F".
     */
    uint16_t model_nr = 0x0F65;
    /*
     * EDID byte 12-15 is a 32-bit binary serial. atoi() on a Samsung-style
     * alphanumeric serial like "H4ZK500001VL" returns 0 because parsing
     * stops at the first non-digit. A zero binary serial paired with a
     * non-zero string serial is a self-inconsistent EDID — strict parsers
     * (read-edid, edid-decode --check) flag it. Hash the alphanumeric
     * serial via djb2 so the binary slot is deterministic, non-zero, and
     * cannot collide with the obviously-default 0x01A5C3D2 either.
     */
    uint32_t serial_nr;
    if (info->serial) {
        serial_nr = atoi(info->serial);
        if (serial_nr == 0) {
            /* djb2 hash for stable non-zero serial from alphanumeric input */
            uint32_t h = 5381;
            for (const char *p = info->serial; *p; p++) {
                h = ((h << 5) + h) + (uint8_t)*p;
            }
            serial_nr = h ? h : 0xC0DECAFE;
        }
    } else {
        serial_nr = 0x01A5C3D2;
    }
    stw_be_p(edid +  8, vendor_id);
    stw_le_p(edid + 10, model_nr);
    stl_le_p(edid + 12, serial_nr);

    /* manufacture week 32, year 2018 — within S24F350F production span */
    edid[16] = 32;
    edid[17] = 2018 - 1990;

    /* edid version */
    edid[18] = 1;
    edid[19] = 4;


    /* =============== basic display parameters =============== */

    /*
     * video input: digital, 8 bpc, HDMI-a.
     * S24F350F's only digital input is HDMI; reporting DisplayPort on
     * a budget Samsung 1080p panel is implausible.
     */
    edid[20] = 0xa3;

    /* screen size: undefined */
    edid[21] = width_mm / 10;
    edid[22] = height_mm / 10;

    /* display gamma: 2.2 */
    edid[23] = 220 - 100;

    /* supported features bitmap: std sRGB, preferred timing */
    edid[24] = 0x06;


    /* =============== chromaticity coordinates =============== */

    /* standard sRGB colorspace */
    edid_colorspace(edid,
                    0.6400, 0.3300,   /* red   */
                    0.3000, 0.6000,   /* green */
                    0.1500, 0.0600,   /* blue  */
                    0.3127, 0.3290);  /* white point  */

    /* =============== established timing bitmap =============== */
    /* =============== standard timing information =============== */

    /* both filled by edid_fill_modes() */


    /* =============== descriptor blocks =============== */

    if (!large_screen) {
        /* DTD1: native (preferred) timing。The DTD section has only 12 bits
         * to store the resolution。 */
        edid_desc_timing(desc, &timings, info->prefx, info->prefy,
                         width_mm, height_mm);
        desc = edid_desc_next(edid, dta, desc);

        /*
         * DTD2: 1600×900 (16:9)。这一描述符槽原本放 Established-Timings-III
         * (0xF7)，但我们已不发 generic standard timings（见 edid_fill_modes：
         * 16:9 的 std timing 会被 Windows 误读成 16:10）。这里放一条 1600×900
         * 精确 DTD，仿真实显示器常见的次级 detailed timing 增强 EDID 真实性。
         * 注意：Windows/viogpudo 的分辨率下拉只采纳【首条 DTD + CEA VIC +
         * established】，不采纳第二条 DTD，所以 1600×900 不会出现在下拉里
         * （这是已知的 Windows EDID 行为，非本代码缺陷）。仅当 maxx/maxy 放得下
         * 1600×900 时发。
         */
        if ((!info->maxx || info->maxx >= 1600) &&
            (!info->maxy || info->maxy >= 900)) {
            generate_timings(&timings2, refresh_rate, 1600, 900);
            edid_desc_timing(desc, &timings2, 1600, 900, width_mm, height_mm);
            desc = edid_desc_next(edid, dta, desc);
        }
    }

    /* xtra3 保持 NULL：不再发 Established-Timings-III / generic std timings。 */
    edid_fill_modes(edid, xtra3, dta, info->maxx, info->maxy);
    /*
     * dta video data block is finished at thus point,
     * so dta descriptor offsets don't move any more.
     */

    edid_desc_ranges(desc);
    desc = edid_desc_next(edid, dta, desc);

    if (desc && info->name) {
        edid_desc_text(desc, 0xfc, info->name);
        desc = edid_desc_next(edid, dta, desc);
    }

    if (desc && info->serial) {
        edid_desc_text(desc, 0xff, info->serial);
        desc = edid_desc_next(edid, dta, desc);
    }

    while (desc) {
        edid_desc_dummy(desc);
        desc = edid_desc_next(edid, dta, desc);
    }

    /* =============== display id extensions =============== */

    if (did && large_screen) {
        qemu_displayid_generate(did, &timings, info->prefx, info->prefy,
                                width_mm, height_mm);
    }

    /* =============== finish up =============== */

    edid_checksum(edid, 127);
    if (dta) {
        edid_checksum(dta, 127);
    }
    if (did) {
        edid_checksum(did, 127);
    }
}

size_t qemu_edid_size(uint8_t *edid)
{
    uint32_t exts;

    if (edid[0] != 0x00 ||
        edid[1] != 0xff) {
        /* doesn't look like a valid edid block */
        return 0;
    }

    exts = edid[126];
    return 128 * (exts + 1);
}
