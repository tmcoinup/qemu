/*
 * VMate launch guard Windows path layout validation.
 * VMate 启动门禁的 Windows 路径布局校验。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "system/vmate-launch-guard-internal.h"

static wchar_t vmate_ascii_lower(wchar_t value)
{
    if (value >= L'A' && value <= L'Z') {
        return value + (L'a' - L'A');
    }
    return value;
}

static bool vmate_wide_suffix_equal(const wchar_t *path, size_t path_length,
                                    const wchar_t *suffix,
                                    size_t suffix_length)
{
    size_t index;

    if (path_length < suffix_length) {
        return false;
    }
    path += path_length - suffix_length;
    for (index = 0; index < suffix_length; index++) {
        if (vmate_ascii_lower(path[index]) !=
            vmate_ascii_lower(suffix[index])) {
            return false;
        }
    }
    return true;
}

static bool vmate_component_is_canonical(const wchar_t *path,
                                          size_t begin, size_t end)
{
    size_t index;

    if (begin == end || path[end - 1] == L'.' || path[end - 1] == L' ' ||
        (end - begin == 1 && path[begin] == L'.') ||
        (end - begin == 2 && path[begin] == L'.' && path[begin + 1] == L'.')) {
        return false;
    }
    for (index = begin; index < end; index++) {
        wchar_t value = path[index];

        if (value < 0x20 || value == L':' || value == L'"' ||
            value == L'<' || value == L'>' || value == L'|' ||
            value == L'?' || value == L'*' || value == L'/') {
            return false;
        }
    }
    return true;
}

static bool vmate_path_is_canonical_local(const wchar_t *path,
                                           size_t path_length)
{
    size_t component_begin = 3;
    size_t index;

    /*
     * Accept X:\... only. This deliberately rejects UNC, NT device, extended,
     * drive-relative and slash-separated paths before any Win32 path lookup.
     * 仅接受 X:\...。在 Win32 查找前，拒绝 UNC、设备、扩展和
     * 相对路径。
     */
    if (path_length < 4 ||
        !((path[0] >= L'A' && path[0] <= L'Z') ||
          (path[0] >= L'a' && path[0] <= L'z')) ||
        path[1] != L':' || path[2] != L'\\') {
        return false;
    }
    for (index = component_begin; index <= path_length; index++) {
        if (index < path_length && path[index] != L'\\') {
            continue;
        }
        if (!vmate_component_is_canonical(path, component_begin, index)) {
            return false;
        }
        component_begin = index + 1;
    }
    return true;
}

static wchar_t *vmate_copy_wide(const wchar_t *source, size_t length)
{
    wchar_t *copy = g_try_new(wchar_t, length + 1);

    if (!copy) {
        return NULL;
    }
    memcpy(copy, source, length * sizeof(*copy));
    copy[length] = L'\0';
    return copy;
}

static wchar_t *vmate_join_path(const wchar_t *left, const wchar_t *right)
{
    size_t left_length = wcslen(left);
    size_t right_length = wcslen(right);
    size_t total = left_length + 1 + right_length;
    wchar_t *path;

    if (total >= VMATE_MAX_WINDOWS_PATH) {
        return NULL;
    }
    path = g_try_new(wchar_t, total + 1);
    if (!path) {
        return NULL;
    }
    memcpy(path, left, left_length * sizeof(*path));
    path[left_length] = L'\\';
    memcpy(path + left_length + 1, right,
           (right_length + 1) * sizeof(*path));
    return path;
}

void vmate_launch_guard_clear_layout(VMateLaunchGuardLayout *layout)
{
    if (!layout) {
        return;
    }
    g_free(layout->root);
    g_free(layout->libexec);
    g_free(layout->qemu);
    g_free(layout->client);
    memset(layout, 0, sizeof(*layout));
}

bool vmate_launch_guard_derive_layout(const wchar_t *module_path,
                                      VMateLaunchGuardLayout *layout)
{
    static const wchar_t suffix[] =
        L"\\libexec\\qemu-system-x86_64.real.exe";
    size_t suffix_length = G_N_ELEMENTS(suffix) - 1;
    size_t module_length;
    size_t root_length;

    if (!module_path || !layout) {
        return false;
    }
    memset(layout, 0, sizeof(*layout));
    module_length = wcslen(module_path);
    if (module_length >= VMATE_MAX_WINDOWS_PATH ||
        !vmate_path_is_canonical_local(module_path, module_length) ||
        !vmate_wide_suffix_equal(module_path, module_length,
                                 suffix, suffix_length)) {
        return false;
    }
    root_length = module_length - suffix_length;
    if (root_length <= 3) {
        return false;
    }
    layout->root = vmate_copy_wide(module_path, root_length);
    layout->libexec = layout->root ?
        vmate_join_path(layout->root, L"libexec") : NULL;
    layout->qemu = vmate_copy_wide(module_path, module_length);
    layout->client = layout->root ?
        vmate_join_path(layout->root, L"vmate-client.exe") : NULL;
    if (!layout->root || !layout->libexec ||
        !layout->qemu || !layout->client) {
        vmate_launch_guard_clear_layout(layout);
        return false;
    }
    return true;
}
