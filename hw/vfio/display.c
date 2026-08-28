/*
 * display support for mdev based vgpu devices
 *
 * Copyright Red Hat, Inc. 2017
 *
 * Authors:
 *    Gerd Hoffmann
 *
 * This work is licensed under the terms of the GNU GPL, version 2.  See
 * the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"
#include <linux/vfio.h>
#include <sys/ioctl.h>

#include "qemu/error-report.h"
#include "hw/display/edid.h"
#include "qapi/error.h"
#include "pci.h"
#include "vfio-display.h"
#include "trace.h"

#ifndef DRM_PLANE_TYPE_PRIMARY
# define DRM_PLANE_TYPE_PRIMARY 1
# define DRM_PLANE_TYPE_CURSOR  2
#endif

#define pread_field(_fd, _reg, _ptr, _fld)                              \
    (sizeof(_ptr->_fld) !=                                              \
     pread(_fd, &(_ptr->_fld), sizeof(_ptr->_fld),                      \
           _reg->offset + offsetof(typeof(*_ptr), _fld)))

#define pwrite_field(_fd, _reg, _ptr, _fld)                             \
    (sizeof(_ptr->_fld) !=                                              \
     pwrite(_fd, &(_ptr->_fld), sizeof(_ptr->_fld),                     \
           _reg->offset + offsetof(typeof(*_ptr), _fld)))

#define VFIO_REGION_MAX_DIRTY_RUNS       32
#define VFIO_REGION_FULL_UPDATE_PERCENT  50
#define VFIO_REGION_FULL_MOTION_PERCENT  75
#define VFIO_REGION_FULL_MOTION_STREAK    8
#define VFIO_REGION_COMPARE_BYPASS_FRAMES 60
#define VFIO_REGION_FAILURE_RETRY_US      100000

typedef struct VFIORegionDirtyRun {
    uint32_t y;
    uint32_t height;
} VFIORegionDirtyRun;

/*
 * The console owns region.surface after dpy_gfx_replace_surface().  Its pixman
 * image only borrows region.staging, so staging may be freed only after the
 * console has switched to another surface (or graphic_console_close() has
 * detached it).
 */
static void vfio_display_region_drop_staging(VFIODisplay *dpy)
{
    dpy->region.surface = NULL;
    g_clear_pointer(&dpy->region.staging, g_free);
    dpy->region.staging_size = 0;
    dpy->region.staging_row_bytes = 0;
    dpy->region.full_motion_streak = 0;
    dpy->region.compare_bypass_frames = 0;
}

static void vfio_display_region_buffer_reset(VFIODisplay *dpy)
{
    if (dpy->region.buffer.mem) {
        vfio_region_exit(&dpy->region.buffer);
        vfio_region_finalize(&dpy->region.buffer);
    }
    memset(&dpy->region.buffer, 0, sizeof(dpy->region.buffer));
}

static bool vfio_display_region_mark_failure(VFIODisplay *dpy)
{
    bool first = dpy->region.failure_streak == 0;

    if (dpy->region.failure_streak != UINT32_MAX) {
        dpy->region.failure_streak++;
    }
    dpy->region.force_full_update = true;
    dpy->region.full_motion_streak = 0;
    dpy->region.compare_bypass_frames = 0;
    dpy->region.failure_retry_after_us =
        g_get_monotonic_time() + VFIO_REGION_FAILURE_RETRY_US;
    return first;
}

static void vfio_display_region_mark_recovered(VFIODisplay *dpy)
{
    if (dpy->region.failure_streak) {
        info_report("vfio-display-region: source recovered after %u failed "
                    "refreshes; queued a full staging update",
                    dpy->region.failure_streak);
        dpy->region.failure_streak = 0;
    }
    dpy->region.failure_retry_after_us = 0;
}

static bool vfio_display_region_layout(
    const struct vfio_device_gfx_plane_info *plane,
    pixman_format_code_t format, size_t *row_bytes, size_t *staging_size)
{
    uint32_t bytes_per_pixel = DIV_ROUND_UP(PIXMAN_FORMAT_BPP(format), 8);

    if (!bytes_per_pixel || !plane->width || !plane->height ||
        plane->width > INT_MAX || plane->height > INT_MAX ||
        plane->stride > INT_MAX || plane->stride % sizeof(uint32_t) ||
        plane->region_index > UINT8_MAX ||
        plane->width > SIZE_MAX / bytes_per_pixel) {
        return false;
    }
    *row_bytes = plane->width * bytes_per_pixel;
    if (*row_bytes > plane->stride ||
        plane->stride > SIZE_MAX / plane->height) {
        return false;
    }
    *staging_size = (size_t)plane->stride * plane->height;
    return *staging_size <= plane->size;
}

static bool vfio_display_region_staging_matches(
    VFIODisplay *dpy, const struct vfio_device_gfx_plane_info *plane,
    pixman_format_code_t format, size_t row_bytes, size_t staging_size)
{
    return dpy->region.surface && dpy->region.staging &&
           dpy->region.staging_size == staging_size &&
           dpy->region.staging_row_bytes == row_bytes &&
           surface_width(dpy->region.surface) == plane->width &&
           surface_height(dpy->region.surface) == plane->height &&
           surface_format(dpy->region.surface) == format &&
           surface_stride(dpy->region.surface) == plane->stride;
}

static bool vfio_display_region_install_staging(
    VFIODisplay *dpy, const struct vfio_device_gfx_plane_info *plane,
    pixman_format_code_t format, size_t row_bytes, size_t staging_size,
    const uint8_t *source)
{
    DisplaySurface *surface;
    uint8_t *old_staging = dpy->region.staging;
    uint8_t *staging = g_try_malloc(staging_size);

    if (!staging) {
        return false;
    }

    /* Populate the complete stable backing before any listener can see it. */
    memcpy(staging, source, staging_size);
    surface = qemu_create_displaysurface_from(plane->width, plane->height,
                                              format, plane->stride, staging);
    dpy_gfx_replace_surface(dpy->con, surface);

    dpy->region.surface = surface;
    dpy->region.staging = staging;
    dpy->region.staging_size = staging_size;
    dpy->region.staging_row_bytes = row_bytes;
    dpy->region.full_motion_streak = 0;
    dpy->region.compare_bypass_frames = 0;
    dpy->region.force_full_update = false;

    /* dpy_gfx_replace_surface() has synchronously detached old_staging. */
    g_free(old_staging);
    return true;
}

static void vfio_display_region_staging_copy(VFIODisplay *dpy,
                                             const uint8_t *source)
{
    memcpy(dpy->region.staging, source, dpy->region.staging_size);
}

/*
 * NVIDIA 535 exposes a pull-only system-memory console REGION without a frame
 * sequence or damage metadata.  Exact row comparisons let us keep polling at
 * low latency while avoiding redundant GL uploads and compositor presents for
 * an unchanged desktop.  High-motion content temporarily bypasses comparison
 * so games do not pay the extra scan/copy cost on every frame.
 */
static bool vfio_display_region_find_updates(
    VFIODisplay *dpy, const uint8_t *source,
    VFIORegionDirtyRun runs[VFIO_REGION_MAX_DIRTY_RUNS],
    uint32_t *run_count, uint32_t *dirty_rows, bool *too_many_runs)
{
    uint32_t height = surface_height(dpy->region.surface);
    uint32_t stride = surface_stride(dpy->region.surface);
    uint32_t y;
    uint32_t run_start = 0;
    bool in_run = false;

    *run_count = 0;
    *dirty_rows = 0;
    *too_many_runs = false;

    for (y = 0; y < height; y++) {
        const uint8_t *src = source + y * stride;
        uint8_t *staging = dpy->region.staging + y * stride;
        bool changed = memcmp(src, staging,
                              dpy->region.staging_row_bytes) != 0;

        if (changed) {
            memcpy(staging, src, dpy->region.staging_row_bytes);
            (*dirty_rows)++;
            if (!in_run) {
                run_start = y;
                in_run = true;
            }
        } else if (in_run) {
            if (*run_count < VFIO_REGION_MAX_DIRTY_RUNS) {
                runs[*run_count].y = run_start;
                runs[*run_count].height = y - run_start;
                (*run_count)++;
            } else {
                *too_many_runs = true;
            }
            in_run = false;
        }
    }
    if (in_run) {
        if (*run_count < VFIO_REGION_MAX_DIRTY_RUNS) {
            runs[*run_count].y = run_start;
            runs[*run_count].height = y - run_start;
            (*run_count)++;
        } else {
            *too_many_runs = true;
        }
    }
    return *dirty_rows != 0;
}

static const uint8_t *vfio_display_region_source(VFIODisplay *dpy,
                                                 size_t staging_size)
{
    VFIORegion *region = &dpy->region.buffer;

    if (!region->mem || !region->nr_mmaps || !region->mmaps ||
        region->mmaps[0].offset != 0 || !region->mmaps[0].mmap ||
        region->mmaps[0].size < staging_size) {
        return NULL;
    }
    return region->mmaps[0].mmap;
}

static void vfio_display_region_no_plane(VFIODisplay *dpy)
{
    DisplaySurface *surface = dpy->region.surface;

    dpy->region.force_full_update = true;
    dpy->region.full_motion_streak = 0;
    dpy->region.compare_bypass_frames = 0;

    if (!dpy->ramfb) {
        return;
    }

    ramfb_display_update(dpy->con, dpy->ramfb);
    if (surface && qemu_console_surface(dpy->con) != surface) {
        /* ramfb detached and freed surface; staging is now safe to release. */
        vfio_display_region_drop_staging(dpy);
        dpy->region.force_full_update = true;
    }
}


static void vfio_display_edid_link_up(void *opaque)
{
    VFIOPCIDevice *vdev = opaque;
    VFIODisplay *dpy = vdev->dpy;
    int fd = vdev->vbasedev.fd;

    dpy->edid_regs->link_state = VFIO_DEVICE_GFX_LINK_STATE_UP;
    if (pwrite_field(fd, dpy->edid_info, dpy->edid_regs, link_state)) {
        goto err;
    }
    trace_vfio_display_edid_link_up();
    return;

err:
    trace_vfio_display_edid_write_error();
}

static void vfio_display_edid_update(VFIOPCIDevice *vdev, bool enabled,
                                     int prefx, int prefy)
{
    VFIODisplay *dpy = vdev->dpy;
    int fd = vdev->vbasedev.fd;
    qemu_edid_info edid = {
        .maxx  = dpy->edid_regs->max_xres,
        .maxy  = dpy->edid_regs->max_yres,
        .prefx = prefx ?: vdev->display_xres,
        .prefy = prefy ?: vdev->display_yres,
    };

    timer_del(dpy->edid_link_timer);
    dpy->edid_regs->link_state = VFIO_DEVICE_GFX_LINK_STATE_DOWN;
    if (pwrite_field(fd, dpy->edid_info, dpy->edid_regs, link_state)) {
        goto err;
    }
    trace_vfio_display_edid_link_down();

    if (!enabled) {
        return;
    }

    if (edid.maxx && edid.prefx > edid.maxx) {
        edid.prefx = edid.maxx;
    }
    if (edid.maxy && edid.prefy > edid.maxy) {
        edid.prefy = edid.maxy;
    }
    qemu_edid_generate(dpy->edid_blob,
                       dpy->edid_regs->edid_max_size,
                       &edid);
    trace_vfio_display_edid_update(edid.prefx, edid.prefy);

    dpy->edid_regs->edid_size = qemu_edid_size(dpy->edid_blob);
    if (pwrite_field(fd, dpy->edid_info, dpy->edid_regs, edid_size)) {
        goto err;
    }
    if (pwrite(fd, dpy->edid_blob, dpy->edid_regs->edid_size,
               dpy->edid_info->offset + dpy->edid_regs->edid_offset)
        != dpy->edid_regs->edid_size) {
        goto err;
    }

    timer_mod(dpy->edid_link_timer,
              qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + 100);
    return;

err:
    trace_vfio_display_edid_write_error();
}

static void vfio_display_edid_ui_info(void *opaque, uint32_t idx,
                                      QemuUIInfo *info)
{
    VFIOPCIDevice *vdev = opaque;
    VFIODisplay *dpy = vdev->dpy;

    if (!dpy->edid_regs) {
        return;
    }

    if (info->width && info->height) {
        vfio_display_edid_update(vdev, true, info->width, info->height);
    } else {
        vfio_display_edid_update(vdev, false, 0, 0);
    }
}

static bool vfio_display_edid_init(VFIOPCIDevice *vdev, Error **errp)
{
    VFIODisplay *dpy = vdev->dpy;
    int fd = vdev->vbasedev.fd;
    int ret;

    ret = vfio_device_get_region_info_type(&vdev->vbasedev,
                                           VFIO_REGION_TYPE_GFX,
                                           VFIO_REGION_SUBTYPE_GFX_EDID,
                                           &dpy->edid_info);
    if (ret) {
        /* Failed to get GFX edid info, allow to go through without edid. */
        return true;
    }

    trace_vfio_display_edid_available();
    dpy->edid_regs = g_new0(struct vfio_region_gfx_edid, 1);
    if (pread_field(fd, dpy->edid_info, dpy->edid_regs, edid_offset)) {
        goto err;
    }
    if (pread_field(fd, dpy->edid_info, dpy->edid_regs, edid_max_size)) {
        goto err;
    }
    if (pread_field(fd, dpy->edid_info, dpy->edid_regs, max_xres)) {
        goto err;
    }
    if (pread_field(fd, dpy->edid_info, dpy->edid_regs, max_yres)) {
        goto err;
    }

    dpy->edid_blob = g_malloc0(dpy->edid_regs->edid_max_size);

    /* if xres + yres properties are unset use the maximum resolution */
    if (!vdev->display_xres) {
        vdev->display_xres = dpy->edid_regs->max_xres;
    }
    if (!vdev->display_yres) {
        vdev->display_yres = dpy->edid_regs->max_yres;
    }

    dpy->edid_link_timer = timer_new_ms(QEMU_CLOCK_REALTIME,
                                        vfio_display_edid_link_up, vdev);

    vfio_display_edid_update(vdev, true, 0, 0);
    return true;

err:
    error_setg(errp, "vfio: failed to read GFX edid field");
    trace_vfio_display_edid_write_error();
    g_free(dpy->edid_info);
    g_free(dpy->edid_regs);
    dpy->edid_info = NULL;
    dpy->edid_regs = NULL;
    return false;
}

static void vfio_display_edid_exit(VFIODisplay *dpy)
{
    if (!dpy->edid_regs) {
        return;
    }

    g_free(dpy->edid_info);
    g_free(dpy->edid_regs);
    g_free(dpy->edid_blob);
    timer_free(dpy->edid_link_timer);
}

static void vfio_display_update_cursor(VFIODMABuf *dmabuf,
                                       struct vfio_device_gfx_plane_info *plane)
{
    if (dmabuf->pos_x != plane->x_pos || dmabuf->pos_y != plane->y_pos) {
        dmabuf->pos_x      = plane->x_pos;
        dmabuf->pos_y      = plane->y_pos;
        dmabuf->pos_updates++;
    }
    if (dmabuf->hot_x != plane->x_hot || dmabuf->hot_y != plane->y_hot) {
        dmabuf->hot_x      = plane->x_hot;
        dmabuf->hot_y      = plane->y_hot;
        dmabuf->hot_updates++;
    }
}

static VFIODMABuf *vfio_display_get_dmabuf(VFIOPCIDevice *vdev,
                                           uint32_t plane_type)
{
    VFIODisplay *dpy = vdev->dpy;
    struct vfio_device_gfx_plane_info plane;
    VFIODMABuf *dmabuf;
    int fd, ret;
    uint32_t offset = 0;

    memset(&plane, 0, sizeof(plane));
    plane.argsz = sizeof(plane);
    plane.flags = VFIO_GFX_PLANE_TYPE_DMABUF;
    plane.drm_plane_type = plane_type;
    ret = ioctl(vdev->vbasedev.fd, VFIO_DEVICE_QUERY_GFX_PLANE, &plane);
    if (ret < 0) {
        return NULL;
    }
    if (!plane.drm_format || !plane.size) {
        return NULL;
    }

    QTAILQ_FOREACH(dmabuf, &dpy->dmabuf.bufs, next) {
        if (dmabuf->dmabuf_id == plane.dmabuf_id) {
            /* found in list, move to head, return it */
            QTAILQ_REMOVE(&dpy->dmabuf.bufs, dmabuf, next);
            QTAILQ_INSERT_HEAD(&dpy->dmabuf.bufs, dmabuf, next);
            if (plane_type == DRM_PLANE_TYPE_CURSOR) {
                vfio_display_update_cursor(dmabuf, &plane);
            }
            return dmabuf;
        }
    }

    fd = ioctl(vdev->vbasedev.fd, VFIO_DEVICE_GET_GFX_DMABUF, &plane.dmabuf_id);
    if (fd < 0) {
        return NULL;
    }

    dmabuf = g_new0(VFIODMABuf, 1);
    dmabuf->dmabuf_id  = plane.dmabuf_id;
    dmabuf->buf = qemu_dmabuf_new(plane.width, plane.height, &offset,
                                  &plane.stride, 0, 0, plane.width,
                                  plane.height, plane.drm_format,
                                  plane.drm_format_mod, &fd, 1, false, false);

    if (plane_type == DRM_PLANE_TYPE_CURSOR) {
        vfio_display_update_cursor(dmabuf, &plane);
    }

    QTAILQ_INSERT_HEAD(&dpy->dmabuf.bufs, dmabuf, next);
    return dmabuf;
}

static void vfio_display_free_one_dmabuf(VFIODisplay *dpy, VFIODMABuf *dmabuf)
{
    QTAILQ_REMOVE(&dpy->dmabuf.bufs, dmabuf, next);

    qemu_dmabuf_close(dmabuf->buf);
    dpy_gl_release_dmabuf(dpy->con, dmabuf->buf);
    g_clear_pointer(&dmabuf->buf, qemu_dmabuf_free);
    g_free(dmabuf);
}

static void vfio_display_free_dmabufs(VFIOPCIDevice *vdev)
{
    VFIODisplay *dpy = vdev->dpy;
    VFIODMABuf *dmabuf, *tmp;
    uint32_t keep = 5;

    QTAILQ_FOREACH_SAFE(dmabuf, &dpy->dmabuf.bufs, next, tmp) {
        if (keep > 0) {
            keep--;
            continue;
        }
        assert(dmabuf != dpy->dmabuf.primary);
        vfio_display_free_one_dmabuf(dpy, dmabuf);
    }
}

static void vfio_display_dmabuf_update(void *opaque)
{
    VFIOPCIDevice *vdev = opaque;
    VFIODisplay *dpy = vdev->dpy;
    VFIODMABuf *primary, *cursor;
    uint32_t width, height;
    bool free_bufs = false, new_cursor = false;

    primary = vfio_display_get_dmabuf(vdev, DRM_PLANE_TYPE_PRIMARY);
    if (primary == NULL) {
        if (dpy->ramfb) {
            ramfb_display_update(dpy->con, dpy->ramfb);
            /* A resumed plane at the same address must still be resubmitted. */
            dpy->dmabuf.primary = NULL;
            dpy->dmabuf.cursor = NULL;
        }
        return;
    }

    width = qemu_dmabuf_get_width(primary->buf);
    height = qemu_dmabuf_get_height(primary->buf);

    if (dpy->dmabuf.primary != primary) {
        dpy->dmabuf.primary = primary;
        qemu_console_resize(dpy->con, width, height);
        dpy_gl_scanout_dmabuf(dpy->con, primary->buf);
        free_bufs = true;
    }

    cursor = vfio_display_get_dmabuf(vdev, DRM_PLANE_TYPE_CURSOR);
    if (dpy->dmabuf.cursor != cursor) {
        dpy->dmabuf.cursor = cursor;
        new_cursor = true;
        free_bufs = true;
    }

    if (cursor && (new_cursor || cursor->hot_updates)) {
        bool have_hot = (cursor->hot_x != 0xffffffff &&
                         cursor->hot_y != 0xffffffff);
        dpy_gl_cursor_dmabuf(dpy->con, cursor->buf, have_hot,
                             cursor->hot_x, cursor->hot_y);
        cursor->hot_updates = 0;
    } else if (!cursor && new_cursor) {
        dpy_gl_cursor_dmabuf(dpy->con, NULL, false, 0, 0);
    }

    if (cursor && cursor->pos_updates) {
        dpy_gl_cursor_position(dpy->con,
                               cursor->pos_x,
                               cursor->pos_y);
        cursor->pos_updates = 0;
    }

    dpy_gl_update(dpy->con, 0, 0, width, height);

    if (free_bufs) {
        vfio_display_free_dmabufs(vdev);
    }
}

static int vfio_display_get_flags(void *opaque)
{
    return GRAPHIC_FLAGS_GL | GRAPHIC_FLAGS_DMABUF;
}

static const GraphicHwOps vfio_display_dmabuf_ops = {
    .get_flags  = vfio_display_get_flags,
    .gfx_update = vfio_display_dmabuf_update,
    .ui_info    = vfio_display_edid_ui_info,
};

static bool vfio_display_dmabuf_init(VFIOPCIDevice *vdev, Error **errp)
{
    if (!display_opengl) {
        error_setg(errp, "vfio-display-dmabuf: opengl not available");
        return false;
    }

    vdev->dpy = g_new0(VFIODisplay, 1);
    vdev->dpy->con = graphic_console_init(DEVICE(vdev), 0,
                                          &vfio_display_dmabuf_ops,
                                          vdev);
    if (vdev->enable_ramfb) {
        vdev->dpy->ramfb = ramfb_setup(vdev->use_legacy_x86_rom, errp);
        if (!vdev->dpy->ramfb) {
            return false;
        }
    }
    return vfio_display_edid_init(vdev, errp);
}

static void vfio_display_dmabuf_exit(VFIODisplay *dpy)
{
    VFIODMABuf *dmabuf;

    dpy->dmabuf.primary = NULL;
    dpy->dmabuf.cursor = NULL;
    if (QTAILQ_EMPTY(&dpy->dmabuf.bufs)) {
        return;
    }

    while ((dmabuf = QTAILQ_FIRST(&dpy->dmabuf.bufs)) != NULL) {
        vfio_display_free_one_dmabuf(dpy, dmabuf);
    }
}

/* ---------------------------------------------------------------------- */
void vfio_display_reset(VFIOPCIDevice *vdev)
{
    if (!vdev || !vdev->dpy || !vdev->dpy->con) {
        return;
    }
    if (!vdev->dpy->dmabuf.primary &&
        QTAILQ_EMPTY(&vdev->dpy->dmabuf.bufs)) {
        return;
    }

    dpy_gl_scanout_disable(vdev->dpy->con);
    vfio_display_dmabuf_exit(vdev->dpy);
    dpy_gfx_update_full(vdev->dpy->con);
}

static void vfio_display_region_update(void *opaque)
{
    VFIOPCIDevice *vdev = opaque;
    VFIODisplay *dpy = vdev->dpy;
    struct vfio_device_gfx_plane_info plane = {
        .argsz = sizeof(plane),
        .flags = VFIO_GFX_PLANE_TYPE_REGION
    };
    pixman_format_code_t format;
    VFIORegionDirtyRun runs[VFIO_REGION_MAX_DIRTY_RUNS];
    const uint8_t *source;
    size_t row_bytes;
    size_t staging_size;
    uint32_t run_count;
    uint32_t dirty_rows;
    bool too_many_runs;
    int ret;

    if (dpy->region.failure_retry_after_us &&
        g_get_monotonic_time() < dpy->region.failure_retry_after_us) {
        return;
    }
    dpy->region.failure_retry_after_us = 0;

    ret = ioctl(vdev->vbasedev.fd, VFIO_DEVICE_QUERY_GFX_PLANE, &plane);
    if (ret < 0) {
        int saved_errno = errno;

        if (vfio_display_region_mark_failure(dpy)) {
            error_report("ioctl VFIO_DEVICE_QUERY_GFX_PLANE: %s; "
                         "keeping the last staged frame",
                         strerror(saved_errno));
        }
        return;
    }
    if (!plane.drm_format || !plane.size) {
        vfio_display_region_no_plane(dpy);
        return;
    }
    format = qemu_drm_format_to_pixman(plane.drm_format);
    if (!format) {
        if (vfio_display_region_mark_failure(dpy)) {
            error_report("vfio-display-region: unsupported DRM format 0x%x; "
                         "keeping the last staged frame", plane.drm_format);
        }
        return;
    }
    if (!vfio_display_region_layout(&plane, format, &row_bytes,
                                    &staging_size)) {
        if (vfio_display_region_mark_failure(dpy)) {
            error_report("vfio-display-region: invalid plane layout "
                         "%ux%u stride=%u size=%u; keeping the last staged "
                         "frame", plane.width, plane.height, plane.stride,
                         plane.size);
        }
        return;
    }

    /*
     * NVIDIA R535's vmiop-presentation path page-aligns the message buffer,
     * then compares that padded length with stride * height.  For a scanout
     * whose frame length is not host-page aligned it logs, for example,
     *
     *   mismatch on pixel length (expected 0x6cb100 received 0x6cc000)
     *
     * and publishes an all-zero console REGION.  QEMU cannot repair the
     * guest mode after that proprietary hand-off.  Refuse to replace ramfb or
     * the last good staging surface, and report the exact mode/length so the
     * management layer can select a reviewed page-safe mode (1920x1080).
     */
    if (vfio_pci_is(vdev, PCI_VENDOR_ID_NVIDIA, PCI_ANY_ID) &&
        !QEMU_IS_ALIGNED(staging_size, qemu_real_host_page_size())) {
        size_t rounded_size = ROUND_UP(staging_size,
                                      qemu_real_host_page_size());

        if (vfio_display_region_mark_failure(dpy)) {
            error_report("vfio-display-region: NVIDIA scanout %ux%u "
                         "stride=%u has page-unsafe frame length 0x%zx "
                         "(R535 presentation rounds it to 0x%zx and rejects "
                         "head delivery); keeping ramfb/last staged frame; "
                         "select a page-safe guest mode such as 1920x1080",
                         plane.width, plane.height, plane.stride,
                         staging_size, rounded_size);
        }
        if (!dpy->region.surface && dpy->ramfb) {
            ramfb_display_update(dpy->con, dpy->ramfb);
        }
        return;
    }

    if (dpy->region.buffer.mem &&
        dpy->region.buffer.nr != plane.region_index) {
        /* The installed surface uses staging, so unmapping cannot dangle it. */
        vfio_display_region_buffer_reset(dpy);
        dpy->region.force_full_update = true;
    }

    if (!dpy->region.buffer.mem) {
        /* mmap region */
        Error *error = NULL;

        ret = vfio_region_setup(OBJECT(vdev), &vdev->vbasedev,
                                &dpy->region.buffer,
                                plane.region_index,
                                "display", &error);
        if (ret != 0) {
            bool first = vfio_display_region_mark_failure(dpy);

            if (first && error) {
                error_reportf_err(error, "vfio-display-region: ");
            } else if (first) {
                error_report("vfio-display-region: cannot set up region %u; "
                             "keeping the last staged frame",
                             plane.region_index);
            } else {
                error_free(error);
            }
            vfio_display_region_buffer_reset(dpy);
            return;
        }
        ret = vfio_region_mmap(&dpy->region.buffer);
        if (ret != 0) {
            if (vfio_display_region_mark_failure(dpy)) {
                error_report("%s: vfio_region_mmap(%d): %s; keeping the "
                             "last staged frame", __func__,
                             plane.region_index, strerror(-ret));
            }
            vfio_display_region_buffer_reset(dpy);
            return;
        }
    }

    source = vfio_display_region_source(dpy, staging_size);
    if (!source) {
        if (vfio_display_region_mark_failure(dpy)) {
            error_report("vfio-display-region: region %u has no contiguous "
                         "mapping for %zu bytes; keeping the last staged frame",
                         plane.region_index, staging_size);
        }
        return;
    }

    if (!vfio_display_region_staging_matches(dpy, &plane, format, row_bytes,
                                             staging_size)) {
        if (!vfio_display_region_install_staging(dpy, &plane, format,
                                                 row_bytes, staging_size,
                                                 source)) {
            if (vfio_display_region_mark_failure(dpy)) {
                error_report("vfio-display-region: cannot allocate %zu-byte "
                             "staging frame; keeping the last staged frame",
                             staging_size);
            }
            return;
        }
        vfio_display_region_mark_recovered(dpy);
        dpy_gfx_update(dpy->con, 0, 0, plane.width, plane.height);
        return;
    }

    if (dpy->region.force_full_update) {
        vfio_display_region_staging_copy(dpy, source);
        dpy->region.force_full_update = false;
        dpy->region.full_motion_streak = 0;
        dpy->region.compare_bypass_frames = 0;
        vfio_display_region_mark_recovered(dpy);
        dpy_gfx_update(dpy->con, 0, 0, plane.width, plane.height);
        return;
    }

    if (dpy->region.compare_bypass_frames) {
        /* Consumers only ever see the stable copy, never the live mmap. */
        vfio_display_region_staging_copy(dpy, source);
        dpy->region.compare_bypass_frames--;
        dpy_gfx_update(dpy->con, 0, 0, plane.width, plane.height);
        return;
    }

    if (!vfio_display_region_find_updates(dpy, source, runs, &run_count,
                                          &dirty_rows, &too_many_runs)) {
        dpy->region.full_motion_streak = 0;
        return;
    }

    if ((uint64_t)dirty_rows * 100 >=
        (uint64_t)plane.height * VFIO_REGION_FULL_MOTION_PERCENT) {
        dpy->region.full_motion_streak++;
        if (dpy->region.full_motion_streak >=
            VFIO_REGION_FULL_MOTION_STREAK) {
            dpy->region.full_motion_streak = 0;
            dpy->region.compare_bypass_frames =
                VFIO_REGION_COMPARE_BYPASS_FRAMES;
        }
    } else {
        dpy->region.full_motion_streak = 0;
    }

    if (too_many_runs ||
        (uint64_t)dirty_rows * 100 >=
        (uint64_t)plane.height * VFIO_REGION_FULL_UPDATE_PERCENT) {
        dpy_gfx_update(dpy->con, 0, 0, plane.width, plane.height);
        return;
    }
    /*
     * Keep a single display update per refresh.  The GL listener can batch
     * several texture uploads before its final swap, but SDL's 2D listener
     * presents immediately on every update and would otherwise present once
     * per dirty run.  A vertical bounding box preserves most of the upload
     * saving without creating an avoidable present storm.
     */
    dpy_gfx_update(dpy->con, 0, runs[0].y, plane.width,
                   runs[run_count - 1].y + runs[run_count - 1].height -
                   runs[0].y);
}

static const GraphicHwOps vfio_display_region_ops = {
    .gfx_update = vfio_display_region_update,
};

static bool vfio_display_region_init(VFIOPCIDevice *vdev, Error **errp)
{
    vdev->dpy = g_new0(VFIODisplay, 1);
    vdev->dpy->con = graphic_console_init(DEVICE(vdev), 0,
                                          &vfio_display_region_ops,
                                          vdev);
    if (vdev->enable_ramfb) {
        vdev->dpy->ramfb = ramfb_setup(vdev->use_legacy_x86_rom, errp);
        if (!vdev->dpy->ramfb) {
            return false;
        }
    }
    return true;
}

static void vfio_display_region_exit(VFIODisplay *dpy)
{
    /* graphic_console_close() has already detached and freed region.surface. */
    vfio_display_region_drop_staging(dpy);
    vfio_display_region_buffer_reset(dpy);
}

/* ---------------------------------------------------------------------- */

bool vfio_display_probe(VFIOPCIDevice *vdev, Error **errp)
{
    struct vfio_device_gfx_plane_info probe;
    int ret;

    memset(&probe, 0, sizeof(probe));
    probe.argsz = sizeof(probe);
    probe.flags = VFIO_GFX_PLANE_TYPE_PROBE | VFIO_GFX_PLANE_TYPE_DMABUF;
    ret = ioctl(vdev->vbasedev.fd, VFIO_DEVICE_QUERY_GFX_PLANE, &probe);
    if (ret == 0) {
        return vfio_display_dmabuf_init(vdev, errp);
    }

    memset(&probe, 0, sizeof(probe));
    probe.argsz = sizeof(probe);
    probe.flags = VFIO_GFX_PLANE_TYPE_PROBE | VFIO_GFX_PLANE_TYPE_REGION;
    ret = ioctl(vdev->vbasedev.fd, VFIO_DEVICE_QUERY_GFX_PLANE, &probe);
    if (ret == 0) {
        return vfio_display_region_init(vdev, errp);
    }

    if (vdev->display == ON_OFF_AUTO_AUTO) {
        /* not an error in automatic mode */
        return true;
    }

    error_setg(errp, "vfio: device doesn't support any (known) display method");
    return false;
}

void vfio_display_finalize(VFIOPCIDevice *vdev)
{
    if (!vdev->dpy) {
        return;
    }

    graphic_console_close(vdev->dpy->con);
    vfio_display_dmabuf_exit(vdev->dpy);
    vfio_display_region_exit(vdev->dpy);
    vfio_display_edid_exit(vdev->dpy);
    g_free(vdev->dpy);
}

static bool migrate_needed(void *opaque)
{
    VFIODisplay *dpy = opaque;
    bool ramfb_exists = dpy->ramfb != NULL;

    /* see vfio_display_migration_needed() */
    assert(ramfb_exists);
    return ramfb_exists;
}

const VMStateDescription vfio_display_vmstate = {
    .name = "VFIODisplay",
    .version_id = 1,
    .minimum_version_id = 1,
    .needed = migrate_needed,
    .fields = (const VMStateField[]) {
        VMSTATE_STRUCT_POINTER(ramfb, VFIODisplay, ramfb_vmstate, RAMFBState),
        VMSTATE_END_OF_LIST(),
    }
};
