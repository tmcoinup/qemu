/*
 * QTest testcase for vga cards
 *
 * Copyright (c) 2014 Red Hat, Inc
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"
#include "libqtest.h"

#define VMWARE_SVGA_IO_BASE 0x4560
#define VMWARE_SVGA_INDEX_PORT (VMWARE_SVGA_IO_BASE + 0)
#define VMWARE_SVGA_VALUE_PORT (VMWARE_SVGA_IO_BASE + 1)
#define VMWARE_SVGA_REG_CURSOR_X 25
#define VMWARE_SVGA_REG_CURSOR_Y 26
#define VMWARE_SVGA_REG_CURSOR_ON 27
#define VMWARE_SVGA_CURSOR_ON_HIDE 0
#define VMWARE_SVGA_CURSOR_ON_SHOW 1
#define VMWARE_PCI_VENDOR_ID 0x15ad
#define VMWARE_SVGA_PCI_DEVICE_ID 0x0405
#define PCI_CONFIG_ADDR 0xcf8
#define PCI_CONFIG_DATA 0xcfc
#define PCI_CONFIG_ENABLE 0x80000000U
#define PCI_COMMAND 0x04
#define PCI_COMMAND_IO 0x0001
#define PCI_BASE_ADDRESS_0 0x10

static void pci_multihead(void)
{
    QTestState *qts;

    qts = qtest_init("-vga none -device VGA -device secondary-vga");
    qtest_quit(qts);
}

static void test_vga(gconstpointer data)
{
    QTestState *qts;

    qts = qtest_initf("-vga none -device %s", (const char *)data);
    qtest_quit(qts);
}

static uint32_t pci_config_addr(uint8_t devfn, uint8_t offset)
{
    return PCI_CONFIG_ENABLE | ((uint32_t)devfn << 8) | (offset & ~3U);
}

static uint32_t pci_config_readl(QTestState *qts, uint8_t devfn,
                                 uint8_t offset)
{
    qtest_outl(qts, PCI_CONFIG_ADDR, pci_config_addr(devfn, offset));
    return qtest_inl(qts, PCI_CONFIG_DATA);
}

static uint16_t pci_config_readw(QTestState *qts, uint8_t devfn,
                                 uint8_t offset)
{
    qtest_outl(qts, PCI_CONFIG_ADDR, pci_config_addr(devfn, offset));
    return qtest_inw(qts, PCI_CONFIG_DATA + (offset & 2U));
}

static void pci_config_writel(QTestState *qts, uint8_t devfn,
                              uint8_t offset, uint32_t value)
{
    qtest_outl(qts, PCI_CONFIG_ADDR, pci_config_addr(devfn, offset));
    qtest_outl(qts, PCI_CONFIG_DATA, value);
}

static void pci_config_writew(QTestState *qts, uint8_t devfn,
                              uint8_t offset, uint16_t value)
{
    qtest_outl(qts, PCI_CONFIG_ADDR, pci_config_addr(devfn, offset));
    qtest_outw(qts, PCI_CONFIG_DATA + (offset & 2U), value);
}

static uint8_t find_vmware_svga_devfn(QTestState *qts)
{
    uint32_t expected_id;

    expected_id = ((uint32_t)VMWARE_SVGA_PCI_DEVICE_ID << 16) |
                  VMWARE_PCI_VENDOR_ID;
    for (uint16_t devfn = 0; devfn < 256; devfn++) {
        if (pci_config_readl(qts, devfn, 0) == expected_id) {
            return devfn;
        }
    }

    g_assert_not_reached();
}

static void vmware_svga_enable_io(QTestState *qts)
{
    uint8_t devfn;
    uint16_t command;

    /*
     * qtest 不运行固件，PCI BAR 可能还没有被分配。
     * 这里手动给 BAR0 指定稳定 I/O 基址，
     * 并打开 PCI_COMMAND_IO，
     * 让后续 outl 真正命中既有寄存器窗口。
     */
    devfn = find_vmware_svga_devfn(qts);
    pci_config_writel(qts, devfn, PCI_BASE_ADDRESS_0,
                      VMWARE_SVGA_IO_BASE | 1);
    command = pci_config_readw(qts, devfn, PCI_COMMAND);
    pci_config_writew(qts, devfn, PCI_COMMAND, command | PCI_COMMAND_IO);
}

static void vmware_svga_write_reg(QTestState *qts,
                                  uint32_t reg, uint32_t value)
{
    /*
     * 这里模拟 guest 驱动访问已有的
     * vmware-svga I/O 寄存器。
     * 测试只验证 QEMU 能在 host 侧读到
     * 既有硬件光标路径产生的状态。
     * 不新增任何 guest 可见的查询接口。
     */
    qtest_outl(qts, VMWARE_SVGA_INDEX_PORT, reg);
    qtest_outl(qts, VMWARE_SVGA_VALUE_PORT, value);
}

static void assert_guest_mouse_position(QTestState *qts, bool valid,
                                        int64_t x, int64_t y, bool visible)
{
    QDict *resp;
    QDict *ret;

    resp = qtest_qmp(qts, "{ 'execute': 'query-guest-mouse-position' }");
    g_assert(qdict_haskey(resp, "return"));
    ret = qdict_get_qdict(resp, "return");

    /*
     * valid=false 表示客户机还没有上报硬件光标坐标。
     * 此时 x/y 只是占位值。
     * 测试仍检查它们保持稳定，
     * 避免未来改动产生未初始化数据。
     */
    g_assert_cmpint(qdict_get_bool(ret, "valid"), ==, valid);
    g_assert_cmpint(qdict_get_int(ret, "x"), ==, x);
    g_assert_cmpint(qdict_get_int(ret, "y"), ==, y);
    g_assert_cmpint(qdict_get_bool(ret, "visible"), ==, visible);

    qobject_unref(resp);
}

static void send_absolute_mouse_input(QTestState *qts, int64_t x, int64_t y)
{
    QDict *resp;

    /*
     * 这里走已有 host QMP input-send-event 注入路径，guest 只看到普通
     * usb-tablet 绝对鼠标事件；坐标缓存完全停留在 QEMU 进程内，
     * 不新增 guest 可探测的查询接口。
     */
    resp = qtest_qmp(qts,
                     "{ 'execute': 'input-send-event',"
                     "  'arguments': { 'events': ["
                     "    { 'type': 'abs',"
                     "      'data': { 'axis': 'x', 'value': %ld } },"
                     "    { 'type': 'abs',"
                     "      'data': { 'axis': 'y', 'value': %ld } } ] } }",
                     x, y);
    g_assert(qdict_haskey(resp, "return"));
    qobject_unref(resp);
}

static void vmware_guest_mouse_position(void)
{
    QTestState *qts;

    qts = qtest_init("-vga none -device vmware-svga");
    vmware_svga_enable_io(qts);
    assert_guest_mouse_position(qts, false, 0, 0, false);

    vmware_svga_write_reg(qts, VMWARE_SVGA_REG_CURSOR_X, 123);
    vmware_svga_write_reg(qts, VMWARE_SVGA_REG_CURSOR_Y, 45);
    vmware_svga_write_reg(qts, VMWARE_SVGA_REG_CURSOR_ON,
                          VMWARE_SVGA_CURSOR_ON_SHOW);
    assert_guest_mouse_position(qts, true, 123, 45, true);

    vmware_svga_write_reg(qts, VMWARE_SVGA_REG_CURSOR_ON,
                          VMWARE_SVGA_CURSOR_ON_HIDE);
    assert_guest_mouse_position(qts, true, 123, 45, false);

    qtest_quit(qts);
}

static void host_absolute_input_mouse_position(void)
{
    QTestState *qts;

    qts = qtest_init("-vga none -device VGA -device qemu-xhci "
                     "-device usb-tablet");
    assert_guest_mouse_position(qts, false, 0, 0, false);

    send_absolute_mouse_input(qts, 0, 0);
    assert_guest_mouse_position(qts, true, 0, 0, true);

    qtest_quit(qts);
}

int main(int argc, char **argv)
{
    const char *arch;
    static const char *devices[] = {
        "cirrus-vga",
        "VGA",
        "secondary-vga",
        "virtio-gpu-pci",
        "virtio-vga"
    };

    g_test_init(&argc, &argv, NULL);
    arch = qtest_get_arch();

    for (int i = 0; i < ARRAY_SIZE(devices); i++) {
        if (qtest_has_device(devices[i])) {
            char *testpath = g_strdup_printf("/display/pci/%s", devices[i]);
            qtest_add_data_func(testpath, devices[i], test_vga);
            g_free(testpath);
        }
    }

    if (qtest_has_device("secondary-vga")) {
        qtest_add_func("/display/pci/multihead", pci_multihead);
    }
    if ((g_str_equal(arch, "i386") || g_str_equal(arch, "x86_64")) &&
        qtest_has_device("vmware-svga")) {
        qtest_add_func("/display/pci/vmware-svga/guest-mouse-position",
                       vmware_guest_mouse_position);
    }
    if ((g_str_equal(arch, "i386") || g_str_equal(arch, "x86_64")) &&
        qtest_has_device("VGA") && qtest_has_device("qemu-xhci") &&
        qtest_has_device("usb-tablet")) {
        qtest_add_func("/display/pci/vga/host-absolute-input-mouse-position",
                       host_absolute_input_mouse_position);
    }

    return g_test_run();
}
