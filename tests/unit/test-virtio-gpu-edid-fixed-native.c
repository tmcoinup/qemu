/*
 * virtio-gpu 固定首选 EDID 时序单元测试
 *
 * Copyright (c) 2026 VMate contributors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"

#include "hw/virtio/virtio-gpu.h"

#define EDID_BINARY_SERIAL_OFFSET 12
#define EDID_REVISION_OFFSET 19
#define EDID_FIRST_DTD_OFFSET 54
#define EDID_SECOND_DTD_OFFSET 72

/*
 * 本测试直接链接 virtio-gpu-base.c，以便覆盖生产函数而不是复制选择逻辑。
 * 下列桩函数仅满足同一编译单元内、但本测试不会进入的设备生命周期路径；
 * 若测试意外走到这些路径，立即失败，避免桩函数掩盖真实行为。
 */
QemuConsole *graphic_console_init(DeviceState *dev, uint32_t head,
                                  const GraphicHwOps *ops, void *opaque)
{
    g_assert_not_reached();
}

void virtio_init(VirtIODevice *vdev, uint16_t device_id, size_t config_size)
{
    g_assert_not_reached();
}

void virtio_cleanup(VirtIODevice *vdev)
{
    g_assert_not_reached();
}

VirtQueue *virtio_add_queue(VirtIODevice *vdev, int queue_size,
                            VirtIOHandleOutput handle_output)
{
    g_assert_not_reached();
}

void virtio_del_queue(VirtIODevice *vdev, int n)
{
    g_assert_not_reached();
}

void virtio_notify_config(VirtIODevice *vdev)
{
    g_assert_not_reached();
}

/*
 * EDID 1.x 的详细时序描述符用低 8 位和独立的高 4 位保存 active pixels。
 * 这里直接解析第一条 DTD；该位置同时由基础块的 preferred-timing 标志指定
 * 为首选模式，因此比搜索任意一个 1920x1080 mode 更严格。
 */
static uint16_t dtd_horizontal_active(const uint8_t *dtd)
{
    return dtd[2] | ((dtd[4] & 0xf0) << 4);
}

static uint16_t dtd_vertical_active(const uint8_t *dtd)
{
    return dtd[5] | ((dtd[7] & 0xf0) << 4);
}

static uint16_t dtd_pixel_clock_10khz(const uint8_t *dtd)
{
    return dtd[0] | (dtd[1] << 8);
}

static uint16_t dtd_horizontal_blank(const uint8_t *dtd)
{
    return dtd[3] | ((dtd[4] & 0x0f) << 8);
}

static uint16_t dtd_vertical_blank(const uint8_t *dtd)
{
    return dtd[6] | ((dtd[7] & 0x0f) << 8);
}

static uint16_t dtd_horizontal_front(const uint8_t *dtd)
{
    return dtd[8] | ((dtd[11] & 0xc0) << 2);
}

static uint16_t dtd_horizontal_sync(const uint8_t *dtd)
{
    return dtd[9] | ((dtd[11] & 0x30) << 4);
}

static uint16_t dtd_vertical_front(const uint8_t *dtd)
{
    return (dtd[10] >> 4) | ((dtd[11] & 0x0c) << 2);
}

static uint16_t dtd_vertical_sync(const uint8_t *dtd)
{
    return (dtd[10] & 0x0f) | ((dtd[11] & 0x03) << 4);
}

static uint16_t dtd_image_width_mm(const uint8_t *dtd)
{
    return dtd[12] | ((dtd[14] & 0xf0) << 4);
}

static uint16_t dtd_image_height_mm(const uint8_t *dtd)
{
    return dtd[13] | ((dtd[14] & 0x0f) << 8);
}

static void assert_preferred_resolution(const struct virtio_gpu_resp_edid *edid,
                                        uint16_t expected_width,
                                        uint16_t expected_height)
{
    const uint8_t *dtd = edid->edid + EDID_FIRST_DTD_OFFSET;

    /* 响应长度是小端字段，必须按 guest 实际读取方式校验。 */
    g_assert_cmpuint(le32_to_cpu(edid->size), ==, sizeof(edid->edid));
    g_assert_cmpuint(dtd_horizontal_active(dtd), ==, expected_width);
    g_assert_cmpuint(dtd_vertical_active(dtd), ==, expected_height);
}

static void test_fixed_native_uses_configured_primary_mode(void)
{
    VirtIOGPUBase gpu = { 0 };
    struct virtio_gpu_resp_edid edid = { 0 };
    const uint8_t *dtd;

    /*
     * 模拟 UI 已把动态请求状态改成 1280x800@75.002，而设备命令行仍声明
     * 1920x1080。显式开启固定模式后，首选 DTD 必须继续使用配置值和
     * 60 Hz CEA 时序；否则 75002 mHz 会误命中 Xiaomi 的次要 DTD，并把
     * DTD1 物理尺寸错误改成 160x90 mm。
     */
    gpu.conf.edid_fixed_native = true;
    gpu.conf.xres = 1920;
    gpu.conf.yres = 1080;
    gpu.conf.edid_width_mm = 527;
    gpu.conf.edid_height_mm = 293;
    gpu.req_state[0].width = 1280;
    gpu.req_state[0].height = 800;
    gpu.req_state[0].refresh_rate = 75002;

    virtio_gpu_base_generate_edid(&gpu, 0, &edid);
    dtd = edid.edid + EDID_FIRST_DTD_OFFSET;

    assert_preferred_resolution(&edid, 1920, 1080);
    g_assert_cmpuint(dtd_pixel_clock_10khz(dtd), ==, 14850);
    g_assert_cmphex(dtd[17], ==, 0x1e);
    g_assert_cmpuint(dtd_image_width_mm(dtd), ==, 527);
    g_assert_cmpuint(dtd_image_height_mm(dtd), ==, 293);
}

static void test_default_mode_keeps_dynamic_request(void)
{
    VirtIOGPUBase gpu = { 0 };
    struct virtio_gpu_resp_edid edid = { 0 };

    /*
     * edid_fixed_native 依赖零初始化保持默认关闭。即使命令行配置为
     * 1920x1080，默认路径也必须继续反映 UI 更新后的 1280x800。
     */
    gpu.conf.xres = 1920;
    gpu.conf.yres = 1080;
    gpu.req_state[0].width = 1280;
    gpu.req_state[0].height = 800;

    virtio_gpu_base_generate_edid(&gpu, 0, &edid);

    assert_preferred_resolution(&edid, 1280, 800);
    g_assert_cmphex(edid.edid[EDID_REVISION_OFFSET], ==, 4);
}

static void test_dynamic_mode_keeps_requested_refresh(void)
{
    VirtIOGPUBase gpu = { 0 };
    struct virtio_gpu_resp_edid edid = { 0 };
    const uint8_t *dtd;

    /*
     * 固定模式关闭时保持上游语义：UI 请求的 75002 mHz 仍进入 EDID
     * 生成器。该三元组对应已核验的 185.630 MHz 时序，可直接证明生产
     * 修复没有把所有 virtio-gpu 调用方一律强制成 60 Hz。
     */
    gpu.req_state[0].width = 1920;
    gpu.req_state[0].height = 1080;
    gpu.req_state[0].refresh_rate = 75002;

    virtio_gpu_base_generate_edid(&gpu, 0, &edid);
    dtd = edid.edid + EDID_FIRST_DTD_OFFSET;

    assert_preferred_resolution(&edid, 1920, 1080);
    g_assert_cmpuint(dtd_pixel_clock_10khz(dtd), ==, 18563);
}

static void test_explicit_binary_serial_and_revision(void)
{
    VirtIOGPUBase gpu = { 0 };
    struct virtio_gpu_resp_edid edid = { 0 };
    char text_serial[] = "12345678";

    /*
     * Samsung S24F350 的实机 EDID 二进制序列是 0x5a5a5055。即使同时
     * 存在文本序列号，也必须优先写显式二进制值；逐字节校验能同时覆盖
     * virtio-gpu 属性透传以及 EDID 12..15 的小端布局。
     */
    gpu.conf.edid_serial = text_serial;
    gpu.conf.edid_binary_serial = 0x5a5a5055;
    gpu.conf.edid_revision = 3;
    gpu.req_state[0].width = 1920;
    gpu.req_state[0].height = 1080;

    virtio_gpu_base_generate_edid(&gpu, 0, &edid);

    g_assert_cmphex(edid.edid[EDID_BINARY_SERIAL_OFFSET], ==, 0x55);
    g_assert_cmphex(edid.edid[EDID_BINARY_SERIAL_OFFSET + 1], ==, 0x50);
    g_assert_cmphex(edid.edid[EDID_BINARY_SERIAL_OFFSET + 2], ==, 0x5a);
    g_assert_cmphex(edid.edid[EDID_BINARY_SERIAL_OFFSET + 3], ==, 0x5a);
    g_assert_cmphex(edid.edid[EDID_REVISION_OFFSET], ==, 3);
}

typedef struct ExpectedSecondaryTiming {
    uint32_t width;
    uint32_t height;
    uint32_t refresh_millihz;
    uint16_t panel_width_mm;
    uint16_t panel_height_mm;
    uint16_t timing_width_mm;
    uint16_t timing_height_mm;
    uint16_t pixel_clock_10khz;
    uint16_t horizontal_front;
    uint16_t horizontal_sync;
    uint16_t horizontal_blank;
    uint16_t vertical_front;
    uint16_t vertical_sync;
    uint16_t vertical_blank;
    uint8_t flags;
} ExpectedSecondaryTiming;

static void test_exact_managed_secondary_timings(void)
{
    static const ExpectedSecondaryTiming cases[] = {
        { 1280, 720, 50000, 521, 293, 521, 293,
          7425, 440, 40, 700, 5, 5, 30, 0x1e },
        { 1920, 1080, 74973, 527, 296, 527, 296,
          17450, 48, 32, 160, 3, 5, 39, 0x1a },
        { 1920, 1080, 75002, 527, 293, 160, 90,
          18563, 48, 40, 280, 5, 5, 45, 0x1e },
    };
    size_t i;

    for (i = 0; i < ARRAY_SIZE(cases); i++) {
        const ExpectedSecondaryTiming *expected = &cases[i];
        VirtIOGPUBase gpu = { 0 };
        struct virtio_gpu_resp_edid edid = { 0 };
        const uint8_t *primary_dtd;
        const uint8_t *dtd;

        gpu.conf.edid_width_mm = expected->panel_width_mm;
        gpu.conf.edid_height_mm = expected->panel_height_mm;
        gpu.conf.edid_secondary_x = expected->width;
        gpu.conf.edid_secondary_y = expected->height;
        gpu.conf.edid_secondary_refresh_rate = expected->refresh_millihz;
        gpu.req_state[0].width = 1920;
        gpu.req_state[0].height = 1080;

        virtio_gpu_base_generate_edid(&gpu, 0, &edid);
        primary_dtd = edid.edid + EDID_FIRST_DTD_OFFSET;
        dtd = edid.edid + EDID_SECOND_DTD_OFFSET;

        g_assert_cmphex(primary_dtd[17], ==, 0x1e);
        g_assert_cmpuint(dtd_image_width_mm(primary_dtd), ==,
                         expected->panel_width_mm);
        g_assert_cmpuint(dtd_image_height_mm(primary_dtd), ==,
                         expected->panel_height_mm);
        g_assert_cmpuint(dtd_horizontal_active(dtd), ==, expected->width);
        g_assert_cmpuint(dtd_vertical_active(dtd), ==, expected->height);
        g_assert_cmpuint(dtd_pixel_clock_10khz(dtd), ==,
                         expected->pixel_clock_10khz);
        g_assert_cmpuint(dtd_horizontal_front(dtd), ==,
                         expected->horizontal_front);
        g_assert_cmpuint(dtd_horizontal_sync(dtd), ==,
                         expected->horizontal_sync);
        g_assert_cmpuint(dtd_horizontal_blank(dtd), ==,
                         expected->horizontal_blank);
        g_assert_cmpuint(dtd_vertical_front(dtd), ==,
                         expected->vertical_front);
        g_assert_cmpuint(dtd_vertical_sync(dtd), ==,
                         expected->vertical_sync);
        g_assert_cmpuint(dtd_vertical_blank(dtd), ==,
                         expected->vertical_blank);
        g_assert_cmpuint(dtd_image_width_mm(dtd), ==,
                         expected->timing_width_mm);
        g_assert_cmpuint(dtd_image_height_mm(dtd), ==,
                         expected->timing_height_mm);
        g_assert_cmphex(dtd[17], ==, expected->flags);
    }
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/virtio-gpu/edid/fixed-native-primary",
                    test_fixed_native_uses_configured_primary_mode);
    g_test_add_func("/virtio-gpu/edid/default-dynamic-request",
                    test_default_mode_keeps_dynamic_request);
    g_test_add_func("/virtio-gpu/edid/dynamic-requested-refresh",
                    test_dynamic_mode_keeps_requested_refresh);
    g_test_add_func("/virtio-gpu/edid/explicit-binary-serial-revision",
                    test_explicit_binary_serial_and_revision);
    g_test_add_func("/virtio-gpu/edid/exact-managed-secondary-timings",
                    test_exact_managed_secondary_timings);

    return g_test_run();
}
