/*
 * Paused VM input-release routing tests.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qapi/qapi-commands-ui.h"
#include "system/replay.h"
#include "system/runstate.h"
#include "ui/console.h"
#include "ui/input.h"

typedef struct InputRecorder {
    unsigned int events;
    unsigned int syncs;
    InputEventKind last_kind;
    bool last_down;
} InputRecorder;

static RunState test_runstate;

bool runstate_is_running(void)
{
    return test_runstate == RUN_STATE_RUNNING;
}

bool runstate_check(RunState state)
{
    return test_runstate == state;
}

void replay_input_event(QemuConsole *src, InputEvent *evt)
{
    qemu_input_event_send_impl(src, evt);
}

void replay_input_sync_event(void)
{
    qemu_input_event_sync_impl();
}

QemuConsole *qemu_console_lookup_by_device_name(const char *device_id,
                                                 uint32_t head, Error **errp)
{
    g_assert_not_reached();
}

void qemu_console_record_absolute_input(QemuConsole *con,
                                        InputAxis axis, int value)
{
    g_assert_not_reached();
}

int qemu_console_get_index(QemuConsole *con)
{
    return 0;
}

int qemu_input_key_number_to_qcode(unsigned int nr)
{
    return Q_KEY_CODE_UNMAPPED;
}

static void record_event(DeviceState *dev, QemuConsole *src, InputEvent *evt)
{
    InputRecorder *recorder = (InputRecorder *)dev;

    recorder->events++;
    recorder->last_kind = evt->type;
    if (evt->type == INPUT_EVENT_KIND_KEY) {
        recorder->last_down = evt->u.key.data->down;
    } else if (evt->type == INPUT_EVENT_KIND_BTN) {
        recorder->last_down = evt->u.btn.data->down;
    }
}

static void record_sync(DeviceState *dev)
{
    InputRecorder *recorder = (InputRecorder *)dev;

    recorder->syncs++;
}

static const QemuInputHandler test_handler = {
    .name = "paused-release-test",
    .mask = INPUT_EVENT_MASK_KEY | INPUT_EVENT_MASK_BTN |
            INPUT_EVENT_MASK_REL,
    .event = record_event,
    .sync = record_sync,
};

static InputEvent key_event(bool down)
{
    static KeyValue key = {
        .type = KEY_VALUE_KIND_QCODE,
        .u.qcode.data = Q_KEY_CODE_A,
    };
    static InputKeyEvent data;
    InputEvent event = {
        .type = INPUT_EVENT_KIND_KEY,
        .u.key.data = &data,
    };

    data.key = &key;
    data.down = down;
    return event;
}

static InputEvent button_event(bool down)
{
    static InputBtnEvent data;
    InputEvent event = {
        .type = INPUT_EVENT_KIND_BTN,
        .u.btn.data = &data,
    };

    data.button = INPUT_BUTTON_LEFT;
    data.down = down;
    return event;
}

static InputEvent motion_event(void)
{
    static InputMoveEvent data = {
        .axis = INPUT_AXIS_X,
        .value = 1,
    };
    InputEvent event = {
        .type = INPUT_EVENT_KIND_REL,
        .u.rel.data = &data,
    };

    return event;
}

static void test_paused_release_and_sync(void)
{
    InputRecorder recorder = { 0 };
    QemuInputHandlerState *state;
    InputEvent event;

    state = qemu_input_handler_register((DeviceState *)&recorder,
                                        &test_handler);

    test_runstate = RUN_STATE_RUNNING;
    event = key_event(true);
    qemu_input_event_send(NULL, &event);
    qemu_input_event_sync();
    g_assert_cmpuint(recorder.events, ==, 1);
    g_assert_cmpuint(recorder.syncs, ==, 1);

    test_runstate = RUN_STATE_PAUSED;
    event = key_event(false);
    qemu_input_event_send(NULL, &event);
    g_assert_cmpuint(recorder.events, ==, 2);
    g_assert_false(recorder.last_down);

    /* 状态改变后仍必须完成这次 release sync。 */
    test_runstate = RUN_STATE_SAVE_VM;
    qemu_input_event_sync();
    qemu_input_event_sync();
    g_assert_cmpuint(recorder.syncs, ==, 2);

    test_runstate = RUN_STATE_PAUSED;
    event = button_event(false);
    qemu_input_event_send(NULL, &event);
    qemu_input_event_sync();
    g_assert_cmpuint(recorder.events, ==, 3);
    g_assert_cmpuint(recorder.syncs, ==, 3);
    g_assert_cmpint(recorder.last_kind, ==, INPUT_EVENT_KIND_BTN);
    g_assert_false(recorder.last_down);

    qemu_input_handler_unregister(state);
}

static void test_paused_nonrelease_stays_blocked(void)
{
    InputRecorder recorder = { 0 };
    QemuInputHandlerState *state;
    InputEvent event;

    state = qemu_input_handler_register((DeviceState *)&recorder,
                                        &test_handler);
    test_runstate = RUN_STATE_PAUSED;

    event = key_event(true);
    qemu_input_event_send(NULL, &event);
    event = button_event(true);
    qemu_input_event_send(NULL, &event);
    event = motion_event();
    qemu_input_event_send(NULL, &event);
    qemu_input_event_sync();
    g_assert_cmpuint(recorder.events, ==, 0);
    g_assert_cmpuint(recorder.syncs, ==, 0);

    test_runstate = RUN_STATE_SAVE_VM;
    event = key_event(false);
    qemu_input_event_send(NULL, &event);
    qemu_input_event_sync();
    g_assert_cmpuint(recorder.events, ==, 0);
    g_assert_cmpuint(recorder.syncs, ==, 0);

    test_runstate = RUN_STATE_SUSPENDED;
    event = key_event(true);
    qemu_input_event_send(NULL, &event);
    qemu_input_event_sync();
    g_assert_cmpuint(recorder.events, ==, 1);
    g_assert_cmpuint(recorder.syncs, ==, 1);

    qemu_input_handler_unregister(state);
}

static void test_qmp_remains_blocked_while_paused(void)
{
    InputEvent event = key_event(false);
    InputEventList events = {
        .value = &event,
    };
    Error *err = NULL;

    test_runstate = RUN_STATE_PAUSED;
    qmp_input_send_event(NULL, false, 0, &events, &err);
    g_assert_nonnull(err);
    g_assert_nonnull(strstr(error_get_pretty(err), "VM not running"));
    error_free(err);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/input/paused/release-sync",
                    test_paused_release_and_sync);
    g_test_add_func("/input/paused/nonrelease-blocked",
                    test_paused_nonrelease_stays_blocked);
    g_test_add_func("/input/paused/qmp-blocked",
                    test_qmp_remains_blocked_while_paused);
    return g_test_run();
}
