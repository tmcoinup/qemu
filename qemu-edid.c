/*
 * QEMU EDID test tool.
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */
#include "qemu/osdep.h"
#include <getopt.h>
#include "qemu/bswap.h"
#include "qemu/cutils.h"
#include "hw/display/edid.h"

enum {
    OPTION_WIDTH_MM = 256,
    OPTION_HEIGHT_MM,
    OPTION_PRODUCT_ID,
    OPTION_WEEK,
    OPTION_YEAR,
    OPTION_VIDEO_INPUT,
    OPTION_RANGE_MIN_V,
    OPTION_RANGE_MAX_V,
    OPTION_RANGE_MIN_H,
    OPTION_RANGE_MAX_H,
    OPTION_MAX_CLOCK,
};

static const struct option long_options[] = {
    { "width-mm", required_argument, NULL, OPTION_WIDTH_MM },
    { "height-mm", required_argument, NULL, OPTION_HEIGHT_MM },
    { "product-id", required_argument, NULL, OPTION_PRODUCT_ID },
    { "week", required_argument, NULL, OPTION_WEEK },
    { "year", required_argument, NULL, OPTION_YEAR },
    { "video-input", required_argument, NULL, OPTION_VIDEO_INPUT },
    { "range-min-v", required_argument, NULL, OPTION_RANGE_MIN_V },
    { "range-max-v", required_argument, NULL, OPTION_RANGE_MAX_V },
    { "range-min-h", required_argument, NULL, OPTION_RANGE_MIN_H },
    { "range-max-h", required_argument, NULL, OPTION_RANGE_MAX_H },
    { "max-clock", required_argument, NULL, OPTION_MAX_CLOCK },
    { NULL, 0, NULL, 0 },
};

static qemu_edid_info info = {
    .prefx = 1280,
    .prefy = 800,
};

static void usage(FILE *out)
{
    fprintf(out,
            "\n"
            "This is a test tool for the qemu edid generator.\n"
            "\n"
            "Typically you'll pipe the output into edid-decode\n"
            "to check if the generator works correctly.\n"
            "\n"
            "usage: qemu-edid <options>\n"
            "options:\n"
            "    -h             print this text\n"
            "    -o <file>      set output file (stdout by default)\n"
            "    -v <vendor>    set monitor vendor (three letters)\n"
            "    -n <name>      set monitor name\n"
            "    -s <serial>    set monitor serial\n"
            "    -d <dpi>       set display density\n"
            "    -x <prefx>     set preferred width\n"
            "    -y <prefy>     set preferred height\n"
            "    -X <maxx>      set maximum width\n"
            "    -Y <maxy>      set maximum height\n"
            "    --width-mm <mm>       set physical width\n"
            "    --height-mm <mm>      set physical height\n"
            "    --product-id <id>     set 16-bit product ID\n"
            "    --week <week>         set manufacture week (1-54)\n"
            "    --year <year>         set manufacture year (1990-2245)\n"
            "    --video-input <byte>  set EDID video input byte\n"
            "    --range-min-v <hz>    set minimum vertical frequency\n"
            "    --range-max-v <hz>    set maximum vertical frequency\n"
            "    --range-min-h <khz>   set minimum horizontal frequency\n"
            "    --range-max-h <khz>   set maximum horizontal frequency\n"
            "    --max-clock <mhz>     set maximum pixel clock\n"
            "\n");
}

static uint32_t parse_option_uint(const char *option, const char *value,
                                  unsigned int base, uint32_t min,
                                  uint32_t max)
{
    uint32_t result;

    if (qemu_strtoui(value, NULL, base, &result) < 0 ||
        result < min || result > max) {
        fprintf(stderr, "%s must be in the range %u..%u: %s\n",
                option, min, max, value);
        exit(1);
    }
    return result;
}

int main(int argc, char *argv[])
{
    FILE *outfile = NULL;
    uint8_t blob[512];
    size_t size;
    uint32_t dpi = 100;
    bool width_mm_set = false;
    bool height_mm_set = false;
    int rc;

    for (;;) {
        rc = getopt_long(argc, argv, "ho:x:y:X:Y:d:v:n:s:",
                         long_options, NULL);
        if (rc == -1) {
            break;
        }
        switch (rc) {
        case 'o':
            if (outfile) {
                fprintf(stderr, "outfile specified twice\n");
                exit(1);
            }
            outfile = fopen(optarg, "wb");
            if (outfile == NULL) {
                fprintf(stderr, "open %s: %s\n", optarg, strerror(errno));
                exit(1);
            }
            break;
        case 'x':
            if (qemu_strtoui(optarg, NULL, 10, &info.prefx) < 0) {
                fprintf(stderr, "not a number: %s\n", optarg);
                exit(1);
            }
            break;
        case 'y':
            if (qemu_strtoui(optarg, NULL, 10, &info.prefy) < 0) {
                fprintf(stderr, "not a number: %s\n", optarg);
                exit(1);
            }
            break;
        case 'X':
            if (qemu_strtoui(optarg, NULL, 10, &info.maxx) < 0) {
                fprintf(stderr, "not a number: %s\n", optarg);
                exit(1);
            }
            break;
        case 'Y':
            if (qemu_strtoui(optarg, NULL, 10, &info.maxy) < 0) {
                fprintf(stderr, "not a number: %s\n", optarg);
                exit(1);
            }
            break;
        case 'd':
            if (qemu_strtoui(optarg, NULL, 10, &dpi) < 0) {
                fprintf(stderr, "not a number: %s\n", optarg);
                exit(1);
            }
            if (dpi == 0) {
                fprintf(stderr, "cannot be zero: %s\n", optarg);
                exit(1);
            }
            break;
        case 'v':
            info.vendor = optarg;
            break;
        case 'n':
            info.name = optarg;
            break;
        case 's':
            info.serial = optarg;
            break;
        case OPTION_WIDTH_MM:
            info.width_mm = parse_option_uint("width-mm", optarg, 10,
                                              1, 2550);
            width_mm_set = true;
            break;
        case OPTION_HEIGHT_MM:
            info.height_mm = parse_option_uint("height-mm", optarg, 10,
                                               1, 2550);
            height_mm_set = true;
            break;
        case OPTION_PRODUCT_ID:
            info.product_id = parse_option_uint("product-id", optarg, 0,
                                                1, UINT16_MAX);
            break;
        case OPTION_WEEK:
            info.week = parse_option_uint("week", optarg, 10, 1, 54);
            break;
        case OPTION_YEAR:
            info.year = parse_option_uint("year", optarg, 10, 1990, 2245);
            break;
        case OPTION_VIDEO_INPUT:
            info.video_input = parse_option_uint("video-input", optarg, 0,
                                                 1, UINT8_MAX);
            break;
        case OPTION_RANGE_MIN_V:
            info.range_min_v = parse_option_uint("range-min-v", optarg, 10,
                                                 1, UINT8_MAX);
            break;
        case OPTION_RANGE_MAX_V:
            info.range_max_v = parse_option_uint("range-max-v", optarg, 10,
                                                 1, UINT8_MAX);
            break;
        case OPTION_RANGE_MIN_H:
            info.range_min_h = parse_option_uint("range-min-h", optarg, 10,
                                                 1, UINT8_MAX);
            break;
        case OPTION_RANGE_MAX_H:
            info.range_max_h = parse_option_uint("range-max-h", optarg, 10,
                                                 1, UINT8_MAX);
            break;
        case OPTION_MAX_CLOCK:
            info.max_clock = parse_option_uint("max-clock", optarg, 10,
                                               10, 2550);
            break;
        case 'h':
            usage(stdout);
            exit(0);
        default:
            usage(stderr);
            exit(1);
        }
    }

    if (outfile == NULL) {
        outfile = stdout;
    }

    if (width_mm_set != height_mm_set) {
        fprintf(stderr, "width-mm and height-mm must be specified together\n");
        exit(1);
    }
    if (info.range_min_v && info.range_max_v &&
        info.range_min_v > info.range_max_v) {
        fprintf(stderr, "range-min-v must not exceed range-max-v\n");
        exit(1);
    }
    if (info.range_min_h && info.range_max_h &&
        info.range_min_h > info.range_max_h) {
        fprintf(stderr, "range-min-h must not exceed range-max-h\n");
        exit(1);
    }
    if (!width_mm_set) {
        info.width_mm = qemu_edid_dpi_to_mm(dpi, info.prefx);
        info.height_mm = qemu_edid_dpi_to_mm(dpi, info.prefy);
    }

    memset(blob, 0, sizeof(blob));
    qemu_edid_generate(blob, sizeof(blob), &info);
    size = qemu_edid_size(blob);
    fwrite(blob, size, 1, outfile);
    fflush(outfile);

    exit(0);
}
