/*
 * usb-kbd NumLock opt-in qtest
 *
 * 测试通过 UHCI guest DMA 描述符发送 HID SET_REPORT，
 * 随后从 interrupt IN 端点读取 NumLock 按下和释放报告。
 * 这样同时覆盖 USB 控制传输、异步 BH、HID 队列和 QOM 属性。
 */

#include "qemu/osdep.h"
#include "hw/usb/hid.h"
#include "hw/usb/uhci-regs.h"
#include "hw/usb/usb.h"
#include "libqos/libqos.h"
#include "libqos/libqos-pc.h"
#include "libqos/usb.h"
#include "libqtest.h"
#include <glib/gstdio.h>

#define USB_KBD_PATH "/machine/peripheral/kbd0"

#define TEST_UHCI_DEVFN QPCI_DEVFN(0x1d, 0)
#define TEST_UHCI_PORT  UHCI_USBPORTSC1
#define TEST_USB_ADDR   1

#define TEST_FRAME_COUNT       1024
#define TEST_FRAME_TIME_NS     1000000
#define TEST_LINK_TERMINATE    1
#define TEST_TD_ACTLEN_MASK    0x7ff
#define TEST_TD_ERROR_COUNT    (3U << TD_CTRL_ERROR_SHIFT)
#define TEST_TD_DATA_TOGGLE    (1U << 19)
#define TEST_TD_ERROR_MASK     (TD_CTRL_STALL | TD_CTRL_BABBLE | \
                                TD_CTRL_TIMEOUT)
#define TEST_HID_REPORT_SIZE   8
#define TEST_HID_NUMLOCK_USAGE 0x53

typedef struct TestUHCITD {
    uint32_t link;
    uint32_t ctrl;
    uint32_t token;
    uint32_t buffer;
} TestUHCITD;

typedef struct TestUHCI {
    QOSState *qs;
    struct qhc hc;
    uint64_t frame_list;
    uint64_t workspace;
} TestUHCI;

static uint32_t test_td_token(uint8_t pid, uint8_t device, uint8_t endpoint,
                              bool data_toggle, uint16_t length)
{
    uint32_t encoded_length = length ? length - 1 : TEST_TD_ACTLEN_MASK;

    return pid | (device << 8) | (endpoint << 15) |
           (data_toggle ? TEST_TD_DATA_TOGGLE : 0) |
           (encoded_length << 21);
}

static void test_write_td(TestUHCI *uhci, uint64_t address,
                          uint32_t link, uint32_t ctrl, uint32_t token,
                          uint32_t buffer)
{
    TestUHCITD td = {
        .link = cpu_to_le32(link),
        .ctrl = cpu_to_le32(ctrl),
        .token = cpu_to_le32(token),
        .buffer = cpu_to_le32(buffer),
    };

    qtest_memwrite(uhci->qs->qts, address, &td, sizeof(td));
}

static uint32_t test_read_td_ctrl(TestUHCI *uhci, uint64_t address)
{
    uint32_t ctrl;

    qtest_memread(uhci->qs->qts,
                  address + offsetof(TestUHCITD, ctrl),
                  &ctrl, sizeof(ctrl));
    return le32_to_cpu(ctrl);
}

static void test_schedule_td(TestUHCI *uhci, uint32_t td_address)
{
    uint32_t frames[TEST_FRAME_COUNT];
    uint32_t link = cpu_to_le32(td_address);
    size_t i;

    /*
     * 当前帧号由控制器自行递增。
     * 把全部 frame entry 指向同一 TD，测试无需读取 FRNUM，
     * 也不会依赖主机调度速度。
     */
    for (i = 0; i < G_N_ELEMENTS(frames); i++) {
        frames[i] = link;
    }
    qtest_memwrite(uhci->qs->qts, uhci->frame_list,
                   frames, sizeof(frames));
    qtest_clock_step(uhci->qs->qts, TEST_FRAME_TIME_NS);
}

static void test_assert_td_complete(TestUHCI *uhci, uint64_t address)
{
    uint32_t ctrl = test_read_td_ctrl(uhci, address);

    g_assert_cmphex(ctrl & TD_CTRL_ACTIVE, ==, 0);
    g_assert_cmphex(ctrl & TEST_TD_ERROR_MASK, ==, 0);
}

static void test_uhci_control_out(TestUHCI *uhci, uint8_t address,
                                  const uint8_t setup[8],
                                  const uint8_t *data, uint16_t length)
{
    const uint32_t td_setup = uhci->workspace;
    const uint32_t td_data = uhci->workspace + 0x10;
    const uint32_t td_status = uhci->workspace + 0x20;
    const uint32_t setup_buffer = uhci->workspace + 0x100;
    const uint32_t data_buffer = uhci->workspace + 0x110;
    const uint32_t active = TD_CTRL_ACTIVE | TEST_TD_ERROR_COUNT |
                            TEST_TD_ACTLEN_MASK;

    qtest_memwrite(uhci->qs->qts, setup_buffer, setup, 8);
    if (length) {
        qtest_memwrite(uhci->qs->qts, data_buffer, data, length);
    }

    test_write_td(uhci, td_setup, length ? td_data : td_status,
                  active,
                  test_td_token(USB_TOKEN_SETUP, address, 0, false, 8),
                  setup_buffer);
    if (length) {
        test_write_td(uhci, td_data, td_status, active,
                      test_td_token(USB_TOKEN_OUT, address, 0, true,
                                    length),
                      data_buffer);
    }
    test_write_td(uhci, td_status, TEST_LINK_TERMINATE,
                  active | TD_CTRL_IOC,
                  test_td_token(USB_TOKEN_IN, address, 0, true, 0), 0);

    test_schedule_td(uhci, td_setup);
    test_assert_td_complete(uhci, td_setup);
    if (length) {
        test_assert_td_complete(uhci, td_data);
    }
    test_assert_td_complete(uhci, td_status);
}

static bool test_uhci_interrupt_in(TestUHCI *uhci, uint8_t report[8])
{
    const uint32_t td = uhci->workspace + 0x200;
    const uint32_t buffer = uhci->workspace + 0x300;
    const uint32_t active = TD_CTRL_ACTIVE | TEST_TD_ERROR_COUNT |
                            TEST_TD_ACTLEN_MASK;
    uint32_t ctrl;

    memset(report, 0xa5, TEST_HID_REPORT_SIZE);
    qtest_memwrite(uhci->qs->qts, buffer, report, TEST_HID_REPORT_SIZE);
    test_write_td(uhci, td, TEST_LINK_TERMINATE,
                  active | TD_CTRL_IOC,
                  test_td_token(USB_TOKEN_IN, TEST_USB_ADDR, 1, false,
                                TEST_HID_REPORT_SIZE),
                  buffer);
    test_schedule_td(uhci, td);

    ctrl = test_read_td_ctrl(uhci, td);
    if (ctrl & TD_CTRL_ACTIVE) {
        g_assert_cmphex(ctrl & TD_CTRL_NAK, ==, TD_CTRL_NAK);
        return false;
    }

    g_assert_cmphex(ctrl & TEST_TD_ERROR_MASK, ==, 0);
    qtest_memread(uhci->qs->qts, buffer, report, TEST_HID_REPORT_SIZE);
    return true;
}

static TestUHCI test_uhci_start_with_extra(const char *extra)
{
    const char *command =
        "-device piix3-usb-uhci,id=uhci,addr=1d.0 "
        "-device usb-kbd,id=kbd0,bus=uhci.0,port=1,"
        "x-force-numlock-on=on";
    TestUHCI uhci = {
        .qs = qtest_pc_boot("%s %s", command, extra ? extra : ""),
    };
    uint32_t frames[TEST_FRAME_COUNT];
    uint16_t port;
    size_t i;

    qusb_pci_init_one(uhci.qs->pcibus, &uhci.hc,
                      TEST_UHCI_DEVFN, 4);
    uhci.frame_list = qmalloc(uhci.qs, 4096);
    uhci.workspace = qmalloc(uhci.qs, 4096);
    g_assert_cmphex(uhci.frame_list, <=, UINT32_MAX);
    g_assert_cmphex(uhci.workspace, <=, UINT32_MAX);

    for (i = 0; i < G_N_ELEMENTS(frames); i++) {
        frames[i] = cpu_to_le32(TEST_LINK_TERMINATE);
    }
    qtest_memwrite(uhci.qs->qts, uhci.frame_list,
                   frames, sizeof(frames));

    /* 模拟 guest HCD 的端口复位和启用顺序。 */
    port = qpci_io_readw(uhci.hc.dev, uhci.hc.bar, TEST_UHCI_PORT);
    g_assert_cmphex(port & UHCI_PORT_CCS, ==, UHCI_PORT_CCS);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, TEST_UHCI_PORT,
                   UHCI_PORT_RESET);
    qtest_clock_step(uhci.qs->qts, 10 * TEST_FRAME_TIME_NS);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, TEST_UHCI_PORT, 0);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, TEST_UHCI_PORT,
                   UHCI_PORT_EN);
    port = qpci_io_readw(uhci.hc.dev, uhci.hc.bar, TEST_UHCI_PORT);
    g_assert_cmphex(port & UHCI_PORT_EN, ==, UHCI_PORT_EN);

    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, UHCI_USBFLBASEADD,
                   uhci.frame_list & 0xffff);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, UHCI_USBFLBASEADD + 2,
                   uhci.frame_list >> 16);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, UHCI_USBFRNUM, 0);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, UHCI_USBCMD, UHCI_CMD_RS);
    return uhci;
}

static TestUHCI test_uhci_start(void)
{
    return test_uhci_start_with_extra(NULL);
}

static void test_uhci_stop(TestUHCI *uhci)
{
    qpci_io_writew(uhci->hc.dev, uhci->hc.bar, UHCI_USBCMD, 0);
    qfree(uhci->qs, uhci->workspace);
    qfree(uhci->qs, uhci->frame_list);
    uhci_deinit(&uhci->hc);
    qtest_shutdown(uhci->qs);
}

static void test_uhci_stop_migrated_source(TestUHCI *uhci)
{
    /*
     * libqos migrate() 已把源 allocator 的分配记录交给目的端。
     * 源端 guest 地址因此不能再次 qfree，只清理本地 PCI/QEMU 句柄。
     */
    qpci_io_writew(uhci->hc.dev, uhci->hc.bar, UHCI_USBCMD, 0);
    uhci_deinit(&uhci->hc);
    qtest_shutdown(uhci->qs);
}

static void test_set_address_and_configuration(TestUHCI *uhci)
{
    const uint8_t set_address[8] = {
        0x00, USB_REQ_SET_ADDRESS, TEST_USB_ADDR, 0, 0, 0, 0, 0,
    };
    const uint8_t set_configuration[8] = {
        0x00, USB_REQ_SET_CONFIGURATION, 1, 0, 0, 0, 0, 0,
    };

    test_uhci_control_out(uhci, 0, set_address, NULL, 0);
    test_uhci_control_out(uhci, TEST_USB_ADDR,
                          set_configuration, NULL, 0);
}

static void test_set_numlock_led(TestUHCI *uhci, bool enabled)
{
    const uint8_t setup[8] = {
        HID_SET_REPORT >> 8, HID_SET_REPORT & 0xff,
        0, 2, 0, 0, 1, 0,
    };
    uint8_t leds = enabled ? 1 : 0;

    test_uhci_control_out(uhci, TEST_USB_ADDR, setup, &leds, 1);
}

static QTestState *usb_keyboard_start(bool force_numlock)
{
    return qtest_initf(
        "-machine pc -nodefaults "
        "-device piix3-usb-uhci,id=uhci,addr=1d.0 "
        "-device usb-kbd,id=kbd0,bus=uhci.0%s",
        force_numlock ? ",x-force-numlock-on=on" : "");
}

static void test_numlock_force_defaults_off(void)
{
    QTestState *qts = usb_keyboard_start(false);

    g_assert_false(qtest_qom_get_bool(qts, USB_KBD_PATH,
                                      "x-force-numlock-on"));
    g_assert_false(qtest_qom_get_bool(qts, USB_KBD_PATH,
                                      "x-numlock-led-known"));
    g_assert_false(qtest_qom_get_bool(qts, USB_KBD_PATH,
                                      "x-numlock-led-on"));
    g_assert_false(qtest_qom_get_bool(qts, USB_KBD_PATH,
                                      "x-numlock-force-pending"));
    g_assert_false(qtest_qom_get_bool(
        qts, USB_KBD_PATH, "x-numlock-startup-completed"));
    qtest_quit(qts);
}

static void test_numlock_force_can_be_enabled(void)
{
    QTestState *qts = usb_keyboard_start(true);

    g_assert_true(qtest_qom_get_bool(qts, USB_KBD_PATH,
                                     "x-force-numlock-on"));
    /* 启用属性不能制造 guest LED 状态，必须等待 SET_REPORT。 */
    g_assert_false(qtest_qom_get_bool(qts, USB_KBD_PATH,
                                      "x-numlock-led-known"));
    g_assert_false(qtest_qom_get_bool(qts, USB_KBD_PATH,
                                      "x-numlock-force-pending"));
    g_assert_false(qtest_qom_get_bool(
        qts, USB_KBD_PATH, "x-numlock-startup-completed"));
    qtest_quit(qts);
}

static void test_numlock_set_report_end_to_end(void)
{
    TestUHCI uhci = test_uhci_start();
    uint8_t report[TEST_HID_REPORT_SIZE];

    test_set_address_and_configuration(&uhci);
    test_set_numlock_led(&uhci, false);

    g_assert_true(qtest_qom_get_bool(uhci.qs->qts, USB_KBD_PATH,
                                     "x-numlock-led-known"));
    g_assert_false(qtest_qom_get_bool(uhci.qs->qts, USB_KBD_PATH,
                                      "x-numlock-led-on"));
    g_assert_true(qtest_qom_get_bool(uhci.qs->qts, USB_KBD_PATH,
                                     "x-numlock-force-pending"));
    g_assert_false(qtest_qom_get_bool(
        uhci.qs->qts, USB_KBD_PATH, "x-numlock-startup-completed"));

    /* 重复 OFF 必须被 pending 去重，不能排入第二次 click。 */
    test_set_numlock_led(&uhci, false);
    g_assert_true(test_uhci_interrupt_in(&uhci, report));
    g_assert_cmphex(report[2], ==, TEST_HID_NUMLOCK_USAGE);
    g_assert_true(test_uhci_interrupt_in(&uhci, report));
    g_assert_cmphex(report[2], ==, 0);
    g_assert_false(test_uhci_interrupt_in(&uhci, report));

    test_set_numlock_led(&uhci, true);
    g_assert_true(qtest_qom_get_bool(uhci.qs->qts, USB_KBD_PATH,
                                     "x-numlock-led-on"));
    g_assert_false(qtest_qom_get_bool(uhci.qs->qts, USB_KBD_PATH,
                                      "x-numlock-force-pending"));
    g_assert_true(qtest_qom_get_bool(
        uhci.qs->qts, USB_KBD_PATH, "x-numlock-startup-completed"));

    /* 初始化完成后再次 OFF 属于用户操作，不能再生成 NumLock click。 */
    test_set_numlock_led(&uhci, false);
    g_assert_false(qtest_qom_get_bool(uhci.qs->qts, USB_KBD_PATH,
                                      "x-numlock-led-on"));
    g_assert_false(qtest_qom_get_bool(uhci.qs->qts, USB_KBD_PATH,
                                      "x-numlock-force-pending"));
    g_assert_true(qtest_qom_get_bool(
        uhci.qs->qts, USB_KBD_PATH, "x-numlock-startup-completed"));
    g_assert_false(test_uhci_interrupt_in(&uhci, report));
    test_uhci_stop(&uhci);
}

static void test_numlock_migration_preserves_manual_off(void)
{
    g_autofree char *socket_path = g_strdup_printf(
        "%s/qemu-usb-hid-numlock-%u-%u.sock", g_get_tmp_dir(),
        (unsigned)getpid(), g_random_int());
    g_autofree char *uri = g_strdup_printf("unix:%s", socket_path);
    g_autofree char *incoming = g_strdup_printf("-incoming %s", uri);
    TestUHCI source = test_uhci_start();
    TestUHCI destination;
    uint8_t report[TEST_HID_REPORT_SIZE];

    test_set_address_and_configuration(&source);

    /*
     * 首次 ON 直接完成启动初始化，随后的 OFF 模拟用户手动关闭。
     * 该 completed+OFF 组合必须跨迁移保存，不能在克隆目的端再次翻转。
     */
    test_set_numlock_led(&source, true);
    test_set_numlock_led(&source, false);
    g_assert_true(qtest_qom_get_bool(
        source.qs->qts, USB_KBD_PATH, "x-numlock-startup-completed"));
    g_assert_false(qtest_qom_get_bool(
        source.qs->qts, USB_KBD_PATH, "x-numlock-led-on"));

    destination = test_uhci_start_with_extra(incoming);
    migrate(source.qs, destination.qs, uri);

    /*
     * qtest 的两个进程不共享虚拟时钟基准，重启 frame scheduler 后再发 TD。
     * 这里只停启主控制器，不产生 USB reset，也不会清除被测一次性锁存。
     */
    qpci_io_writew(destination.hc.dev, destination.hc.bar,
                   UHCI_USBCMD, 0);
    qpci_io_writew(destination.hc.dev, destination.hc.bar,
                   UHCI_USBCMD, UHCI_CMD_RS);

    g_assert_true(qtest_qom_get_bool(
        destination.qs->qts, USB_KBD_PATH, "x-numlock-led-known"));
    g_assert_false(qtest_qom_get_bool(
        destination.qs->qts, USB_KBD_PATH, "x-numlock-led-on"));
    g_assert_false(qtest_qom_get_bool(
        destination.qs->qts, USB_KBD_PATH, "x-numlock-force-pending"));
    g_assert_true(qtest_qom_get_bool(
        destination.qs->qts, USB_KBD_PATH,
        "x-numlock-startup-completed"));

    /* 迁移完成后 guest 再报告 OFF，也不能产生第二个 NumLock click。 */
    test_set_numlock_led(&destination, false);
    g_assert_false(test_uhci_interrupt_in(&destination, report));

    test_uhci_stop(&destination);
    test_uhci_stop_migrated_source(&source);
    /* QEMU 通常会自行删除 Unix socket；残留时再做幂等清理。 */
    if (g_file_test(socket_path, G_FILE_TEST_EXISTS)) {
        g_assert_cmpint(g_unlink(socket_path), ==, 0);
    }
}

static void test_numlock_migration_preserves_unknown(void)
{
    g_autofree char *socket_path = g_strdup_printf(
        "%s/qemu-usb-hid-numlock-unknown-%u-%u.sock", g_get_tmp_dir(),
        (unsigned)getpid(), g_random_int());
    g_autofree char *uri = g_strdup_printf("unix:%s", socket_path);
    g_autofree char *incoming = g_strdup_printf("-incoming %s", uri);
    TestUHCI source = test_uhci_start();
    TestUHCI destination;

    /* 尚未收到 SET_REPORT 是有效状态，不能被旧流兼容分支误标为完成。 */
    g_assert_false(qtest_qom_get_bool(
        source.qs->qts, USB_KBD_PATH, "x-numlock-led-known"));
    destination = test_uhci_start_with_extra(incoming);
    migrate(source.qs, destination.qs, uri);

    g_assert_false(qtest_qom_get_bool(
        destination.qs->qts, USB_KBD_PATH, "x-numlock-led-known"));
    g_assert_false(qtest_qom_get_bool(
        destination.qs->qts, USB_KBD_PATH, "x-numlock-force-pending"));
    g_assert_false(qtest_qom_get_bool(
        destination.qs->qts, USB_KBD_PATH,
        "x-numlock-startup-completed"));

    test_uhci_stop(&destination);
    test_uhci_stop_migrated_source(&source);
    if (g_file_test(socket_path, G_FILE_TEST_EXISTS)) {
        g_assert_cmpint(g_unlink(socket_path), ==, 0);
    }
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/usb-hid-numlock/default-off",
                    test_numlock_force_defaults_off);
    g_test_add_func("/usb-hid-numlock/explicit-on",
                    test_numlock_force_can_be_enabled);
    g_test_add_func("/usb-hid-numlock/set-report-end-to-end",
                    test_numlock_set_report_end_to_end);
    g_test_add_func("/usb-hid-numlock/migration-manual-off",
                    test_numlock_migration_preserves_manual_off);
    g_test_add_func("/usb-hid-numlock/migration-unknown",
                    test_numlock_migration_preserves_unknown);
    return g_test_run();
}
