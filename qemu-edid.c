/*
 * QEMU EDID test tool.
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */
#include "qemu/osdep.h"
#include "qemu/bswap.h"
#include "qemu/cutils.h"
#include "hw/display/edid.h"

enum {
    OPTION_WIDTH_MM = 256,
    OPTION_HEIGHT_MM,
    OPTION_PRODUCT_ID,
    OPTION_MANUFACTURE_WEEK,
    OPTION_MANUFACTURE_YEAR,
    OPTION_VIDEO_INPUT,
    OPTION_MIN_VFREQ,
    OPTION_MAX_VFREQ,
    OPTION_MIN_HFREQ,
    OPTION_MAX_HFREQ,
    OPTION_MAX_PIXEL_CLOCK,
    OPTION_SECONDARY_X,
    OPTION_SECONDARY_Y,
    OPTION_SECONDARY_REFRESH,
    OPTION_BINARY_SERIAL,
    OPTION_REVISION,
};

static const struct option long_options[] = {
    { "width-mm", required_argument, NULL, OPTION_WIDTH_MM },
    { "height-mm", required_argument, NULL, OPTION_HEIGHT_MM },
    { "product-id", required_argument, NULL, OPTION_PRODUCT_ID },
    { "manufacture-week", required_argument, NULL, OPTION_MANUFACTURE_WEEK },
    { "manufacture-year", required_argument, NULL, OPTION_MANUFACTURE_YEAR },
    { "video-input", required_argument, NULL, OPTION_VIDEO_INPUT },
    { "min-vfreq-hz", required_argument, NULL, OPTION_MIN_VFREQ },
    { "max-vfreq-hz", required_argument, NULL, OPTION_MAX_VFREQ },
    { "min-hfreq-khz", required_argument, NULL, OPTION_MIN_HFREQ },
    { "max-hfreq-khz", required_argument, NULL, OPTION_MAX_HFREQ },
    { "max-pixel-clock-mhz", required_argument, NULL,
      OPTION_MAX_PIXEL_CLOCK },
    { "secondary-xres", required_argument, NULL, OPTION_SECONDARY_X },
    { "secondary-yres", required_argument, NULL, OPTION_SECONDARY_Y },
    { "secondary-refresh-rate", required_argument, NULL,
      OPTION_SECONDARY_REFRESH },
    { "binary-serial", required_argument, NULL, OPTION_BINARY_SERIAL },
    { "revision", required_argument, NULL, OPTION_REVISION },
    { NULL, 0, NULL, 0 },
};

static qemu_edid_info info = {
    .prefx = 1280,
    .prefy = 800,
};

static uint32_t parse_uint_option(const char *name, const char *value,
                                  uint32_t minimum, uint32_t maximum)
{
    uint32_t result;

    if (qemu_strtoui(value, NULL, 0, &result) < 0 ||
        result < minimum || result > maximum) {
        fprintf(stderr, "%s must be in [%" PRIu32 ",%" PRIu32 "]: %s\n",
                name, minimum, maximum, value);
        exit(1);
    }
    return result;
}

static uint8_t parse_revision_option(const char *value)
{
    uint32_t revision = parse_uint_option("revision", value, 0, 4);

    if (revision != 0 && revision != 3 && revision != 4) {
        fprintf(stderr, "revision must be 0, 3, or 4: %s\n", value);
        exit(1);
    }
    return (uint8_t)revision;
}

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
            "    -d <dpi>       set display resolution\n"
            "    -x <prefx>     set preferred width\n"
            "    -y <prefy>     set preferred height\n"
            "    -X <maxx>      set maximum width\n"
            "    -Y <maxy>      set maximum height\n"
            "    --width-mm <n> set physical width in millimeters\n"
            "    --height-mm <n> set physical height in millimeters\n"
            "    --product-id <n> set 16-bit EDID product ID\n"
            "    --binary-serial <n> set 32-bit EDID binary serial\n"
            "    --revision <0|3|4> set EDID revision (0 defaults to 4)\n"
            "    --manufacture-week <n> set manufacture week (1..54)\n"
            "    --manufacture-year <n> set manufacture year\n"
            "    --video-input <n> set EDID video input byte\n"
            "    --min-vfreq-hz <n> set minimum vertical frequency\n"
            "    --max-vfreq-hz <n> set maximum vertical frequency\n"
            "    --min-hfreq-khz <n> set minimum horizontal frequency\n"
            "    --max-hfreq-khz <n> set maximum horizontal frequency\n"
            "    --max-pixel-clock-mhz <n> set maximum pixel clock\n"
            "    --secondary-xres <n> set secondary timing width\n"
            "    --secondary-yres <n> set secondary timing height\n"
            "    --secondary-refresh-rate <n> set secondary timing mHz\n"
            "\n");
}

int main(int argc, char *argv[])
{
    FILE *outfile = NULL;
    uint8_t blob[512];
    size_t size;
    uint32_t dpi = 100;
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
            outfile = fopen(optarg, "w");
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
            info.width_mm = parse_uint_option("width-mm", optarg, 1, 2550);
            break;
        case OPTION_HEIGHT_MM:
            info.height_mm = parse_uint_option("height-mm", optarg, 1, 2550);
            break;
        case OPTION_PRODUCT_ID:
            info.product_id = parse_uint_option("product-id", optarg, 1,
                                                UINT16_MAX);
            break;
        case OPTION_MANUFACTURE_WEEK:
            info.manufacture_week =
                parse_uint_option("manufacture-week", optarg, 1, 54);
            break;
        case OPTION_MANUFACTURE_YEAR:
            info.manufacture_year =
                parse_uint_option("manufacture-year", optarg, 1990, 2245);
            break;
        case OPTION_VIDEO_INPUT:
            info.video_input =
                parse_uint_option("video-input", optarg, 1, UINT8_MAX);
            break;
        case OPTION_MIN_VFREQ:
            info.min_vfreq_hz =
                parse_uint_option("min-vfreq-hz", optarg, 1, UINT8_MAX);
            break;
        case OPTION_MAX_VFREQ:
            info.max_vfreq_hz =
                parse_uint_option("max-vfreq-hz", optarg, 1, UINT8_MAX);
            break;
        case OPTION_MIN_HFREQ:
            info.min_hfreq_khz =
                parse_uint_option("min-hfreq-khz", optarg, 1, UINT8_MAX);
            break;
        case OPTION_MAX_HFREQ:
            info.max_hfreq_khz =
                parse_uint_option("max-hfreq-khz", optarg, 1, UINT8_MAX);
            break;
        case OPTION_MAX_PIXEL_CLOCK:
            info.max_pixel_clock_mhz =
                parse_uint_option("max-pixel-clock-mhz", optarg, 1, 2550);
            break;
        case OPTION_SECONDARY_X:
            info.secondary_x =
                parse_uint_option("secondary-xres", optarg, 1, 4095);
            break;
        case OPTION_SECONDARY_Y:
            info.secondary_y =
                parse_uint_option("secondary-yres", optarg, 1, 4095);
            break;
        case OPTION_SECONDARY_REFRESH:
            info.secondary_refresh_rate =
                parse_uint_option("secondary-refresh-rate", optarg, 1,
                                  1000000);
            break;
        case OPTION_BINARY_SERIAL:
            info.binary_serial =
                parse_uint_option("binary-serial", optarg, 0, UINT32_MAX);
            break;
        case OPTION_REVISION:
            info.revision = parse_revision_option(optarg);
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

    if (!!info.width_mm != !!info.height_mm) {
        fprintf(stderr, "width-mm and height-mm must be specified together\n");
        exit(1);
    }
    if (!!info.secondary_x != !!info.secondary_y) {
        fprintf(stderr,
                "secondary-xres and secondary-yres must be specified together\n");
        exit(1);
    }
    if (info.min_vfreq_hz && info.max_vfreq_hz &&
        info.min_vfreq_hz > info.max_vfreq_hz) {
        fprintf(stderr, "minimum vertical frequency exceeds maximum\n");
        exit(1);
    }
    if (info.min_hfreq_khz && info.max_hfreq_khz &&
        info.min_hfreq_khz > info.max_hfreq_khz) {
        fprintf(stderr, "minimum horizontal frequency exceeds maximum\n");
        exit(1);
    }
    if (!info.width_mm) {
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
