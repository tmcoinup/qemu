#ifndef EDID_H
#define EDID_H

#define EDID_NAME_MAX_LENGTH 12

typedef struct qemu_edid_info {
    const char *vendor; /* http://www.uefi.org/pnp_id_list */
    const char *name;
    const char *serial;
    uint16_t    product_id;
    uint8_t     week;
    uint16_t    year;
    uint8_t     video_input;
    uint8_t     range_min_v;
    uint8_t     range_max_v;
    uint8_t     range_min_h;
    uint8_t     range_max_h;
    uint16_t    max_clock;
    uint16_t    width_mm;
    uint16_t    height_mm;
    uint32_t    prefx;
    uint32_t    prefy;
    uint32_t    maxx;
    uint32_t    maxy;
    uint32_t    refresh_rate;
} qemu_edid_info;

void qemu_edid_generate(uint8_t *edid, size_t size,
                        qemu_edid_info *info);
size_t qemu_edid_size(uint8_t *edid);
void qemu_edid_region_io(MemoryRegion *region, Object *owner,
                         uint8_t *edid, size_t size);

uint32_t qemu_edid_dpi_to_mm(uint32_t dpi, uint32_t res);

#define DEFINE_EDID_PROPERTIES(_state, _edid_info)                         \
    DEFINE_PROP_UINT32("xres", _state, _edid_info.prefx, 0),               \
    DEFINE_PROP_UINT32("yres", _state, _edid_info.prefy, 0),               \
    DEFINE_PROP_UINT32("xmax", _state, _edid_info.maxx, 0),                \
    DEFINE_PROP_UINT32("ymax", _state, _edid_info.maxy, 0),                \
    DEFINE_PROP_UINT32("refresh_rate", _state, _edid_info.refresh_rate, 0), \
    DEFINE_PROP_UINT16("product-id", _state, _edid_info.product_id, 0),     \
    DEFINE_PROP_UINT8("week", _state, _edid_info.week, 0),                 \
    DEFINE_PROP_UINT16("year", _state, _edid_info.year, 0),                \
    DEFINE_PROP_UINT8("video-input", _state, _edid_info.video_input, 0),   \
    DEFINE_PROP_UINT8("range-min-v", _state, _edid_info.range_min_v, 0),   \
    DEFINE_PROP_UINT8("range-max-v", _state, _edid_info.range_max_v, 0),   \
    DEFINE_PROP_UINT8("range-min-h", _state, _edid_info.range_min_h, 0),   \
    DEFINE_PROP_UINT8("range-max-h", _state, _edid_info.range_max_h, 0),   \
    DEFINE_PROP_UINT16("max-clock", _state, _edid_info.max_clock, 0)

#endif /* EDID_H */
