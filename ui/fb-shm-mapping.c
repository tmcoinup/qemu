/*
 * fb-shm 共享内存映射与几何管理。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 本模块只管理 producer 私有布局、跨平台 mapping 和 ROI view。
 * 共享 header 始终视为不可信输入，宿主指针均由私有容量重新推导。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "fb-shm-internal.h"

/* 线协议布局必须在编译期保持在固定 header 内。 */
QEMU_BUILD_BUG_ON(sizeof(FbShmHeader) > FB_SHM_HEADER_SIZE);
QEMU_BUILD_BUG_ON(FB_SHM_BUF_COUNT < 2);

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC       0x0001U
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif
#ifndef F_ADD_SEALS
#define F_ADD_SEALS       1033
#define F_SEAL_SHRINK     0x0002
#define F_SEAL_GROW       0x0004
#endif

size_t fb_shm_frame_bytes(uint32_t w, uint32_t h)
{
    return (size_t)w * h * 4;
}

uint64_t fb_shm_now_ns(void)
{
    struct timespec ts;

    /*
     * 帧率节流只关心相邻帧间隔，必须使用单调时钟。CLOCK_REALTIME 被 NTP、
     * 手工改时或宿主休眠恢复扰动时，会让 deadline 判断突然提前/落后，从而
     * 造成推流端一段时间快进或停顿。
     */
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

void fb_shm_resolve_roi(FbShmDisplay *d, uint32_t sw, uint32_t sh,
                               uint32_t *out_w, uint32_t *out_h,
                               int32_t *out_x, int32_t *out_y)
{
    uint32_t rx = d->cfg_x;
    uint32_t ry = d->cfg_y;
    uint32_t rw = d->cfg_w ? d->cfg_w : sw;
    uint32_t rh = d->cfg_h ? d->cfg_h : sh;

    if (rx >= sw) rx = sw ? sw - 1 : 0;
    if (ry >= sh) ry = sh ? sh - 1 : 0;
    if (rx + rw > sw) rw = sw - rx;
    if (ry + rh > sh) rh = sh - ry;
    if (!rw) rw = 1;
    if (!rh) rh = 1;

    *out_x = (int32_t)rx;
    *out_y = (int32_t)ry;
    *out_w = rw;
    *out_h = rh;
}

void fb_shm_release_slot_images(FbShmDisplay *d)
{
    for (uint32_t i = 0; i < FB_SHM_BUF_COUNT; i++) {
        if (d->slot_img[i]) {
            pixman_image_unref(d->slot_img[i]);
            d->slot_img[i] = NULL;
        }
#ifdef CONFIG_OPENGL
        g_clear_pointer(&d->gl_slot_surface[i], qemu_free_displaysurface);
#endif
    }
}
void fb_shm_release_mapping(FbShmDisplay *d)
{
    fb_shm_release_slot_images(d);
    for (uint32_t i = 0; i < FB_SHM_BUF_COUNT; i++) {
        d->slot[i] = NULL;
    }
#ifndef _WIN32
    if (d->shm && d->shm != MAP_FAILED) {
        munmap(d->shm, d->map_size);
    }
#else
    if (d->shm) {
        UnmapViewOfFile(d->shm);
    }
#endif
    d->shm = NULL;
    d->hdr = NULL;
    d->map_size = 0;
    d->cap_w = 0;
    d->cap_h = 0;
    d->cap_buf_size = 0;
    d->active_idx = 0;
#ifndef _WIN32
    if (d->memfd >= 0) {
        close(d->memfd);
        d->memfd = -1;
    }
#else
    if (d->map_handle) {
        CloseHandle(d->map_handle);
        d->map_handle = NULL;
    }
    g_clear_pointer(&d->map_name, g_free);
#endif
}

static int fb_shm_restore_private_layout(FbShmDisplay *d, Error **errp)
{
    FbShmHeader *hdr = d->hdr;

    /*
     * 中文注释：consumer 必须能读取帧，所以共享 mapping 无法视为可信输入。
     * producer 的写指针只能由私有 map_size/cap_buf_size 推导，绝不能读取
     * consumer 可改写的 hdr->buf_offset[]。同时逐槽做减法式边界检查，避免
     * 加法溢出后得到一个看似落在 mapping 内的宿主指针。
     */
    if (!d->shm || !hdr || d->cap_buf_size == 0 ||
        d->cap_buf_size > (SIZE_MAX - FB_SHM_HEADER_SIZE) /
                          FB_SHM_BUF_COUNT) {
        error_setg(errp, "fb-shm: invalid private backing layout");
        return -1;
    }

    for (uint32_t i = 0; i < FB_SHM_BUF_COUNT; i++) {
        size_t offset = FB_SHM_HEADER_SIZE + (size_t)i * d->cap_buf_size;

        if (offset > d->map_size || d->cap_buf_size > d->map_size - offset) {
            error_setg(errp, "fb-shm: private slot %u exceeds mapping", i);
            return -1;
        }
        d->slot[i] = (uint8_t *)d->shm + offset;
        hdr->buf_offset[i] = offset;
    }

    /* consumer 即使损坏静态 ABI 字段，下一次几何更新也会恢复生产端真值。 */
    hdr->magic = FB_SHM_MAGIC;
    hdr->version = FB_SHM_VERSION;
    hdr->header_size = FB_SHM_HEADER_SIZE;
    hdr->buf_count = FB_SHM_BUF_COUNT;
    hdr->map_size = d->map_size;
    hdr->fourcc = FB_SHM_FOURCC_BGR0;
    hdr->bpp = 32;
    return 0;
}

static int fb_shm_apply_geometry(FbShmDisplay *d, uint32_t w, uint32_t h,
                                 uint32_t sw, uint32_t sh,
                                 int32_t roi_x, int32_t roi_y, Error **errp)
{
    uint32_t old_w = d->cur_w;
    uint32_t old_h = d->cur_h;
    uint32_t old_sw = d->cur_src_w;
    uint32_t old_sh = d->cur_src_h;
    int32_t old_roi_x = d->cur_roi_x;
    int32_t old_roi_y = d->cur_roi_y;

    if (w == 0 || h == 0 || w > FB_SHM_MAX_DIM || h > FB_SHM_MAX_DIM) {
        error_setg(errp, "fb-shm: invalid ROI %ux%u", w, h);
        return -1;
    }
    if (!d->shm || !d->hdr || fb_shm_frame_bytes(w, h) > d->cap_buf_size) {
        error_setg(errp, "fb-shm: ROI %ux%u exceeds backing capacity %ux%u",
                   w, h, d->cap_w, d->cap_h);
        return -1;
    }

    if (fb_shm_restore_private_layout(d, errp) < 0) {
        return -1;
    }

    fb_shm_release_slot_images(d);
    for (uint32_t i = 0; i < FB_SHM_BUF_COUNT; i++) {
        d->slot_img[i] = pixman_image_create_bits_no_clear(
            PIXMAN_x8r8g8b8, w, h, (uint32_t *)d->slot[i], (int)(w * 4));
        if (!d->slot_img[i]) {
            error_setg(errp, "fb-shm: pixman dest image alloc failed");
            fb_shm_release_slot_images(d);
            return -1;
        }
#ifdef CONFIG_OPENGL
        /*
         * GL 读回直接写入同一个 SHM slot。为每个 slot 建一个不拥有内存的
         * DisplaySurface 包装层，这样可以复用 QEMU 已有的 egl_fb_read()
         * BGR0 读回逻辑，而不会额外分配帧缓冲。
         */
        d->gl_slot_surface[i] = qemu_create_displaysurface_from(
            w, h, PIXMAN_x8r8g8b8, (int)(w * 4), d->slot[i]);
#endif
    }

    size_t buf_size = (size_t)w * h * 4;
    d->cur_w = w;
    d->cur_h = h;
    d->cur_src_w = sw;
    d->cur_src_h = sh;
    d->cur_roi_x = roi_x;
    d->cur_roi_y = roi_y;

    FbShmHeader *hdr = d->hdr;
    hdr->buf_size = buf_size;
    hdr->width = w;
    hdr->height = h;
    hdr->stride = w * 4;
    hdr->target_fps = d->shm_target_fps;
    hdr->src_width = sw;
    hdr->src_height = sh;
    hdr->roi_x = roi_x;
    hdr->roi_y = roi_y;
    hdr->damage_x = 0;
    hdr->damage_y = 0;
    hdr->damage_w = (int32_t)w;
    hdr->damage_h = (int32_t)h;
    hdr->flags = FB_SHM_FLAG_RUNNING | FB_SHM_FLAG_RESIZED;
    hdr->ts_ns = fb_shm_now_ns();

    /*
     * 这里记录实际推流几何，而不是只记录 memfd 重建。
     * 现在 ROI 变小/变大且仍落在既有 backing capacity 内时只会更新
     * header 和 pixman view，不会触发 NOTIFY_RESIZED 广播；这条日志用于
     * 恢复“推流尺寸发生调整时一定可见”的诊断信号。
     */
    if (old_w != 0 || old_h != 0) {
        info_report("fb-shm: geometry updated %ux%u@%d,%d/%ux%u -> "
                    "%ux%u@%d,%d/%ux%u (cap=%ux%u, shm_size=%zu)",
                    old_w, old_h, old_roi_x, old_roi_y, old_sw, old_sh,
                    w, h, roi_x, roi_y, sw, sh,
                    d->cap_w, d->cap_h, d->map_size);
    }
    return 0;
}

/* Allocate a backing store sized for the full source surface, not the ROI.
 * ROI changes can then update only the header and local pixman views. */
#ifdef _WIN32
char *fb_shm_win32_safe_id(const char *id)
{
    GString *s = g_string_new(NULL);

    /*
     * Win32 内核对象名把反斜杠当命名空间分隔符。这里把 id 收窄到
     * ASCII 安全集合，保证 profile/实例名来自外部输入时也不会越过
     * Local\qemu-fb-shm-* 这个命名空间。
     */
    for (const char *p = id && *id ? id : "default"; *p; p++) {
        if (g_ascii_isalnum(*p) || *p == '-' || *p == '_') {
            g_string_append_c(s, *p);
        } else {
            g_string_append_c(s, '_');
        }
    }
    return g_string_free(s, FALSE);
}

static char *fb_shm_win32_mapping_name(FbShmDisplay *d)
{
    g_autofree char *safe_id = fb_shm_win32_safe_id(d->id);

    d->map_generation++;
    return g_strdup_printf("Local\\qemu-fb-shm-%s-map-%u",
                           safe_id, d->map_generation);
}
#endif

static int fb_shm_allocate_mapping(FbShmDisplay *d, uint32_t cap_w,
                                   uint32_t cap_h, Error **errp)
{
    if (cap_w == 0 || cap_h == 0 ||
        cap_w > FB_SHM_MAX_DIM || cap_h > FB_SHM_MAX_DIM) {
        error_setg(errp, "fb-shm: invalid backing capacity %ux%u",
                   cap_w, cap_h);
        return -1;
    }

    size_t buf_size = fb_shm_frame_bytes(cap_w, cap_h);
    if (buf_size > (SIZE_MAX - FB_SHM_HEADER_SIZE) / FB_SHM_BUF_COUNT) {
        error_setg(errp, "fb-shm: backing capacity %ux%u is too large",
                   cap_w, cap_h);
        return -1;
    }
    size_t map_size = FB_SHM_HEADER_SIZE + (size_t)FB_SHM_BUF_COUNT * buf_size;

    fb_shm_release_mapping(d);

#ifndef _WIN32
    int fd = memfd_create("qemu-fb-shm", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        error_setg_errno(errp, errno, "fb-shm: memfd_create failed");
        return -1;
    }
    if (ftruncate(fd, map_size) < 0) {
        error_setg_errno(errp, errno, "fb-shm: ftruncate failed");
        close(fd);
        return -1;
    }
    /* Lock the size: external consumer can mmap() with confidence. */
    (void)fcntl(fd, F_ADD_SEALS, F_SEAL_GROW | F_SEAL_SHRINK);

    void *p = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        error_setg_errno(errp, errno, "fb-shm: mmap failed");
        close(fd);
        return -1;
    }
#else
    g_autofree char *map_name = fb_shm_win32_mapping_name(d);
    HANDLE map_handle = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL,
                                           PAGE_READWRITE,
                                           (DWORD)(map_size >> 32),
                                           (DWORD)(map_size & 0xffffffffu),
                                           map_name);
    if (!map_handle) {
        error_setg_win32(errp, GetLastError(),
                         "fb-shm: CreateFileMappingA failed");
        return -1;
    }
    void *p = MapViewOfFile(map_handle, FILE_MAP_ALL_ACCESS, 0, 0, map_size);
    if (!p) {
        error_setg_win32(errp, GetLastError(),
                         "fb-shm: MapViewOfFile failed");
        CloseHandle(map_handle);
        return -1;
    }
#endif
    memset(p, 0, FB_SHM_HEADER_SIZE);

#ifndef _WIN32
    d->memfd = fd;
#else
    d->map_handle = map_handle;
    d->map_name = g_steal_pointer(&map_name);
#endif
    d->shm = p;
    d->map_size = map_size;
    d->hdr = (FbShmHeader *)p;
    d->cap_w = cap_w;
    d->cap_h = cap_h;
    d->cap_buf_size = buf_size;

    /* Header init.  Geometry fields are filled by fb_shm_apply_geometry(). */
    FbShmHeader *hdr = d->hdr;
    hdr->buf_size = buf_size;
    if (fb_shm_restore_private_layout(d, errp) < 0) {
        fb_shm_release_mapping(d);
        return -1;
    }
    hdr->target_fps = d->shm_target_fps;
    d->active_idx = 0;
    hdr->active_idx = 0;
    hdr->flags = FB_SHM_FLAG_RUNNING | FB_SHM_FLAG_RESIZED;
    hdr->frame_seq = 0;
    hdr->ts_ns = fb_shm_now_ns();
    return 0;
}

int fb_shm_ensure_geometry(FbShmDisplay *d, uint32_t w, uint32_t h,
                                  uint32_t sw, uint32_t sh,
                                  int32_t roi_x, int32_t roi_y, Error **errp)
{
    bool needs_mapping = !d->shm || w > d->cap_w || h > d->cap_h;
    uint32_t cap_w = d->cap_w;
    uint32_t cap_h = d->cap_h;

    if (needs_mapping) {
        cap_w = sw > cap_w ? sw : cap_w;
        cap_h = sh > cap_h ? sh : cap_h;
        cap_w = w > cap_w ? w : cap_w;
        cap_h = h > cap_h ? h : cap_h;
        if (fb_shm_allocate_mapping(d, cap_w, cap_h, errp) < 0) {
            return -1;
        }
    }

    if (w != d->cur_w || h != d->cur_h ||
        sw != d->cur_src_w || sh != d->cur_src_h ||
        roi_x != d->cur_roi_x || roi_y != d->cur_roi_y) {
        if (fb_shm_apply_geometry(d, w, h, sw, sh, roi_x, roi_y, errp) < 0) {
            return -1;
        }
    }

    if (needs_mapping) {
        /* Only a real memfd replacement needs an out-of-band fd update. */
        fb_shm_broadcast_resize(d);
        /*
         * 中文注释：启动时为了让首个普通 SHM 客户端能拿到 memfd/eventfd，
         * fb-shm 会先按配置帧率驱动一次 DCL。mapping 建好后如果没有消费者，
         * 必须立刻重算有效帧率，把旁路监听器降到 1Hz；否则即使没人推流，
         * GL/SDL 主显示路径也会被每秒 60 次 graphic_hw_update() 拖慢。
         */
        fb_shm_update_effective_rate(d);
    }
    return 0;
}
