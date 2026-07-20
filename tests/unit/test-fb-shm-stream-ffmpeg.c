/*
 * fb-shm ffmpeg argument safety tests.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "tools/fb-shm-stream/common.h"

#ifndef _WIN32
#include <glib/gstdio.h>
#include <sys/stat.h>
#endif

static Options valid_options(void)
{
    return (Options) {
        .output = "rtmp://example.invalid/live/token?x=$(touch nope)",
        .encoder = "h264_nvenc",
        .preset = "p1",
        .bitrate = "6M",
        .container = "flv",
        .gop = 60,
    };
}

static void test_valid_argv_data(void)
{
    Options o = valid_options();

    /*
     * Shell metacharacters are valid URL data because ffmpeg is exec'd
     * directly.  They must never be interpolated into a shell command.
     */
    g_assert_true(fb_shm_stream_ffmpeg_options_valid(&o));
    g_assert_cmpstr(fb_shm_stream_ffmpeg_output_kind(o.output), ==, "rtmp");
}

static void test_rejects_option_injection(void)
{
    Options o = valid_options();

    o.encoder = "h264_nvenc -y";
    g_assert_false(fb_shm_stream_ffmpeg_options_valid(&o));

    o = valid_options();
    o.preset = "p1;touch";
    g_assert_false(fb_shm_stream_ffmpeg_options_valid(&o));

    o = valid_options();
    o.bitrate = "6M -y";
    g_assert_false(fb_shm_stream_ffmpeg_options_valid(&o));

    o = valid_options();
    o.container = "-f";
    g_assert_false(fb_shm_stream_ffmpeg_options_valid(&o));

    o = valid_options();
    o.output = "-y";
    g_assert_false(fb_shm_stream_ffmpeg_options_valid(&o));
}

static void test_redacts_output_target(void)
{
    g_assert_cmpstr(fb_shm_stream_ffmpeg_output_kind(
                    "rtmps://user:secret@example.invalid/live/token"),
                    ==, "rtmps");
    g_assert_cmpstr(fb_shm_stream_ffmpeg_output_kind(
                    "/srv/private/customer-token.mp4"), ==, "file");
}

#ifndef _WIN32
static void test_direct_exec_keeps_url_literal(void)
{
    static const char script_body[] =
        "#!/bin/sh\n"
        "printf '%s\\n' \"$@\" > \"$FB_SHM_TEST_CAPTURE\"\n"
        "while IFS= read -r line; do :; done\n";
    g_autofree char *tmp = g_dir_make_tmp("fb-shm-ffmpeg-test-XXXXXX", NULL);
    g_autofree char *fake_ffmpeg = g_build_filename(tmp, "ffmpeg", NULL);
    g_autofree char *capture = g_build_filename(tmp, "argv", NULL);
    g_autofree char *marker = g_build_filename(tmp, "injected", NULL);
    g_autofree char *output =
        g_strdup_printf("rtmp://example.invalid/live/$(touch %s)", marker);
    g_autofree char *old_path = g_strdup(g_getenv("PATH"));
    g_autofree char *captured = NULL;
    Options o = valid_options();
    FbShmHeader hdr = {
        .width = 16,
        .height = 16,
        .fourcc = FB_SHM_FOURCC_BGR0,
        .target_fps = 30,
    };
    FfmpegProcess *ffmpeg;

    g_assert_nonnull(tmp);
    g_assert_true(g_file_set_contents(fake_ffmpeg, script_body, -1, NULL));
    g_assert_cmpint(g_chmod(fake_ffmpeg, 0700), ==, 0);
    g_assert_true(g_setenv("PATH", tmp, TRUE));
    g_assert_true(g_setenv("FB_SHM_TEST_CAPTURE", capture, TRUE));

    o.output = output;
    ffmpeg = fb_shm_stream_open_ffmpeg(&o, &hdr);
    g_assert_nonnull(ffmpeg);
    fb_shm_stream_close_ffmpeg(ffmpeg);

    g_assert_false(g_file_test(marker, G_FILE_TEST_EXISTS));
    g_assert_true(g_file_get_contents(capture, &captured, NULL, NULL));
    g_assert_nonnull(strstr(captured, output));

    if (old_path) {
        g_assert_true(g_setenv("PATH", old_path, TRUE));
    } else {
        g_unsetenv("PATH");
    }
    g_unsetenv("FB_SHM_TEST_CAPTURE");
    g_assert_cmpint(g_remove(capture), ==, 0);
    g_assert_cmpint(g_remove(fake_ffmpeg), ==, 0);
    g_assert_cmpint(g_rmdir(tmp), ==, 0);
}
#endif

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/fb-shm-stream/ffmpeg/argv-data",
                    test_valid_argv_data);
    g_test_add_func("/fb-shm-stream/ffmpeg/reject-option-injection",
                    test_rejects_option_injection);
    g_test_add_func("/fb-shm-stream/ffmpeg/redact-output",
                    test_redacts_output_target);
#ifndef _WIN32
    g_test_add_func("/fb-shm-stream/ffmpeg/direct-exec",
                    test_direct_exec_keeps_url_literal);
#endif
    return g_test_run();
}
