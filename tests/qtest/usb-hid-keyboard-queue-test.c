/*
 * USB HID 键盘队列回归测试
 *
 * 通过 UHCI guest DMA 暂停 interrupt IN 消费，
 * 再从 QMP 注入事件，覆盖 duplicate make 和 KEYUP 溢出。
 */

#include "qemu/osdep.h"
#include "hw/usb/uhci-regs.h"
#include "hw/usb/usb.h"
#include "libqos/libqos.h"
#include "libqos/libqos-pc.h"
#include "libqos/usb.h"
#include "libqtest.h"

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
#define TEST_HID_USAGE_A       0x04
#define TEST_HID_QUEUE_LENGTH  16

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

    qtest_memread(uhci->qs->qts, address + offsetof(TestUHCITD, ctrl),
                  &ctrl, sizeof(ctrl));
    return le32_to_cpu(ctrl);
}

static void test_schedule_td(TestUHCI *uhci, uint32_t td_address)
{
    uint32_t frames[TEST_FRAME_COUNT];
    uint32_t link = cpu_to_le32(td_address);
    size_t i;

    for (i = 0; i < G_N_ELEMENTS(frames); i++) {
        frames[i] = link;
    }
    qtest_memwrite(uhci->qs->qts, uhci->frame_list,
                   frames, sizeof(frames));
    qtest_clock_step(uhci->qs->qts, TEST_FRAME_TIME_NS);
}

static void test_control_no_data(TestUHCI *uhci, uint8_t address,
                                 const uint8_t setup[8])
{
    const uint32_t td_setup = uhci->workspace;
    const uint32_t td_status = uhci->workspace + 0x10;
    const uint32_t setup_buffer = uhci->workspace + 0x100;
    const uint32_t active = TD_CTRL_ACTIVE | TEST_TD_ERROR_COUNT |
                            TEST_TD_ACTLEN_MASK;
    uint32_t ctrl;

    qtest_memwrite(uhci->qs->qts, setup_buffer, setup, 8);
    test_write_td(uhci, td_setup, td_status, active,
                  test_td_token(USB_TOKEN_SETUP, address, 0, false, 8),
                  setup_buffer);
    test_write_td(uhci, td_status, TEST_LINK_TERMINATE,
                  active | TD_CTRL_IOC,
                  test_td_token(USB_TOKEN_IN, address, 0, true, 0), 0);
    test_schedule_td(uhci, td_setup);

    ctrl = test_read_td_ctrl(uhci, td_setup);
    g_assert_cmphex(ctrl & (TD_CTRL_ACTIVE | TEST_TD_ERROR_MASK), ==, 0);
    ctrl = test_read_td_ctrl(uhci, td_status);
    g_assert_cmphex(ctrl & (TD_CTRL_ACTIVE | TEST_TD_ERROR_MASK), ==, 0);
}

static bool test_interrupt_in(TestUHCI *uhci,
                              uint8_t report[TEST_HID_REPORT_SIZE])
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

static TestUHCI test_uhci_start(void)
{
    const char *command =
        "-device piix3-usb-uhci,id=uhci,addr=1d.0 "
        "-device usb-kbd,id=kbd0,bus=uhci.0,port=1";
    TestUHCI uhci = { .qs = qtest_pc_boot("%s", command) };
    uint32_t frames[TEST_FRAME_COUNT];
    const uint8_t set_address[8] = {
        0x00, USB_REQ_SET_ADDRESS, TEST_USB_ADDR, 0, 0, 0, 0, 0,
    };
    const uint8_t set_configuration[8] = {
        0x00, USB_REQ_SET_CONFIGURATION, 1, 0, 0, 0, 0, 0,
    };
    uint16_t port;
    size_t i;

    qusb_pci_init_one(uhci.qs->pcibus, &uhci.hc, TEST_UHCI_DEVFN, 4);
    uhci.frame_list = qmalloc(uhci.qs, 4096);
    uhci.workspace = qmalloc(uhci.qs, 4096);
    g_assert_cmphex(uhci.frame_list, <=, UINT32_MAX);
    g_assert_cmphex(uhci.workspace, <=, UINT32_MAX);
    for (i = 0; i < G_N_ELEMENTS(frames); i++) {
        frames[i] = cpu_to_le32(TEST_LINK_TERMINATE);
    }
    qtest_memwrite(uhci.qs->qts, uhci.frame_list, frames, sizeof(frames));

    port = qpci_io_readw(uhci.hc.dev, uhci.hc.bar, TEST_UHCI_PORT);
    g_assert_cmphex(port & UHCI_PORT_CCS, ==, UHCI_PORT_CCS);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, TEST_UHCI_PORT,
                   UHCI_PORT_RESET);
    qtest_clock_step(uhci.qs->qts, 10 * TEST_FRAME_TIME_NS);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, TEST_UHCI_PORT, 0);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, TEST_UHCI_PORT, UHCI_PORT_EN);

    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, UHCI_USBFLBASEADD,
                   uhci.frame_list & 0xffff);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, UHCI_USBFLBASEADD + 2,
                   uhci.frame_list >> 16);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, UHCI_USBFRNUM, 0);
    qpci_io_writew(uhci.hc.dev, uhci.hc.bar, UHCI_USBCMD, UHCI_CMD_RS);

    test_control_no_data(&uhci, 0, set_address);
    test_control_no_data(&uhci, TEST_USB_ADDR, set_configuration);
    return uhci;
}

static void test_uhci_stop(TestUHCI *uhci)
{
    qpci_io_writew(uhci->hc.dev, uhci->hc.bar, UHCI_USBCMD, 0);
    qfree(uhci->qs, uhci->workspace);
    qfree(uhci->qs, uhci->frame_list);
    uhci_deinit(&uhci->hc);
    qtest_shutdown(uhci->qs);
}

static void test_send_key(TestUHCI *uhci, const char *qcode, bool down)
{
    const char *command = down ?
        "{ 'execute': 'input-send-event', 'arguments': { 'events': ["
        "  { 'type': 'key', 'data': { 'down': true,"
        "    'key': { 'type': 'qcode', 'data': %s } } } ] } }" :
        "{ 'execute': 'input-send-event', 'arguments': { 'events': ["
        "  { 'type': 'key', 'data': { 'down': false,"
        "    'key': { 'type': 'qcode', 'data': %s } } } ] } }";

    qtest_qmp_assert_success(
        uhci->qs->qts, command, qcode);
}

static void test_assert_all_up(const uint8_t report[TEST_HID_REPORT_SIZE])
{
    size_t i;

    for (i = 0; i < TEST_HID_REPORT_SIZE; i++) {
        g_assert_cmphex(report[i], ==, 0);
    }
}

static void test_duplicate_make_does_not_hide_release(void)
{
    TestUHCI uhci = test_uhci_start();
    uint8_t report[TEST_HID_REPORT_SIZE];
    size_t i;

    for (i = 0; i < 64; i++) {
        test_send_key(&uhci, "a", true);
    }
    test_send_key(&uhci, "a", false);

    g_assert_true(test_interrupt_in(&uhci, report));
    g_assert_cmphex(report[2], ==, TEST_HID_USAGE_A);
    g_assert_true(test_interrupt_in(&uhci, report));
    test_assert_all_up(report);
    g_assert_false(test_interrupt_in(&uhci, report));
    test_uhci_stop(&uhci);
}

static void test_full_queue_release_fails_closed(void)
{
    static const char *const keys[TEST_HID_QUEUE_LENGTH] = {
        "a", "b", "c", "d", "e", "f", "g", "h",
        "i", "j", "k", "l", "m", "n", "o", "p",
    };
    TestUHCI uhci = test_uhci_start();
    uint8_t report[TEST_HID_REPORT_SIZE];
    size_t i;

    for (i = 0; i < G_N_ELEMENTS(keys); i++) {
        test_send_key(&uhci, keys[i], true);
    }
    test_send_key(&uhci, "a", false);

    g_assert_true(test_interrupt_in(&uhci, report));
    test_assert_all_up(report);
    g_assert_false(test_interrupt_in(&uhci, report));

    /* all-up 消费后，advisory 状态必须允许新 click。 */
    test_send_key(&uhci, "a", true);
    test_send_key(&uhci, "a", false);
    g_assert_true(test_interrupt_in(&uhci, report));
    g_assert_cmphex(report[2], ==, TEST_HID_USAGE_A);
    g_assert_true(test_interrupt_in(&uhci, report));
    test_assert_all_up(report);
    test_uhci_stop(&uhci);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/usb-hid-keyboard-queue/repeat-release",
                    test_duplicate_make_does_not_hide_release);
    g_test_add_func("/usb-hid-keyboard-queue/full-release",
                    test_full_queue_release_fails_closed);
    return g_test_run();
}
