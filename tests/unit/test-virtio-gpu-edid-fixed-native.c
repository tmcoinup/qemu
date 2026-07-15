/*
 * virtio-gpu 固定首选 EDID 时序单元测试
 *
 * Copyright (c) 2026 VMate contributors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"

#include "hw/virtio/virtio-gpu.h"

#define EDID_FIRST_DTD_OFFSET 54

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
 * EDID 1.4 的详细时序描述符用低 8 位和独立的高 4 位保存 active pixels。
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

    /*
     * 模拟 SDL 已把动态请求状态改成 1280x800，而设备命令行仍声明主输出
     * 1920x1080。显式开启固定模式后，首选 DTD 必须继续使用配置值。
     */
    gpu.conf.edid_fixed_native = true;
    gpu.conf.xres = 1920;
    gpu.conf.yres = 1080;
    gpu.req_state[0].width = 1280;
    gpu.req_state[0].height = 800;

    virtio_gpu_base_generate_edid(&gpu, 0, &edid);

    assert_preferred_resolution(&edid, 1920, 1080);
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
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/virtio-gpu/edid/fixed-native-primary",
                    test_fixed_native_uses_configured_primary_mode);
    g_test_add_func("/virtio-gpu/edid/default-dynamic-request",
                    test_default_mode_keeps_dynamic_request);

    return g_test_run();
}
