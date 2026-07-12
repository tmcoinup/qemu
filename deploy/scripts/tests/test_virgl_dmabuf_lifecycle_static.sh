#!/usr/bin/env bash
# 静态验证 virgl scanout dma-buf 的释放顺序，防止 borrowed fd 失效和 owned fd 泄漏。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VIRGL_C="$REPO_ROOT/hw/display/virtio-gpu-virgl.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

test_resource_unref_releases_matching_scanouts_first() {
    # 中文注释：resource-unref 可能因异步 hostmem unmap 暂停；只有真正进入
    # 销毁阶段后才清理 sideband，并且 clear 必须早于 renderer resource-unref。
    awk '
        /virtio_gpu_virgl_resource_unref\(VirtIOGPU \*g,/ { in_func = 1 }
        in_func && /if \(\*suspended\)/ { saw_suspend_guard = 1 }
        in_func && /scanout\[i\]\.resource_id == res->base\.resource_id/ {
            saw_resource_match = 1
        }
        in_func && saw_resource_match && /virtio_gpu_virgl_disable_scanout\(g, i\)/ {
            saw_disable = 1
        }
        in_func && /virgl_renderer_resource_unref/ {
            exit saw_suspend_guard && saw_resource_match && saw_disable ? 0 : 1
        }
        in_func && /^}/ { exit 1 }
    ' "$VIRGL_C" \
        || fail "resource-unref must disable every matching scanout before virgl unref"
}

test_disable_helper_releases_every_host_reference() {
    # 中文注释：RESOURCE_UNREF 可以直接销毁仍在扫描输出的资源；统一 helper
    # 必须先释放 sideband，再清 surface/FBO，最后清零 resource_id，不能让
    # display listener 在 renderer resource 销毁后继续挂着旧 texture。
    awk '
        /static void virtio_gpu_virgl_disable_scanout/ { in_func = 1 }
        in_func && /virtio_gpu_clear_dmabuf/ { stage = 1 }
        in_func && /dpy_gfx_replace_surface/ && stage == 1 { stage = 2 }
        in_func && /dpy_gl_scanout_disable/ && stage == 2 { stage = 3 }
        in_func && /scanout->resource_id = 0/ && stage == 3 {
            exit 0
        }
        in_func && /^}/ { exit 1 }
    ' "$VIRGL_C" \
        || fail "virgl disable helper must release dma-buf, surface, FBO and id in order"
}

test_reset_and_set_scanout_share_disable_helper() {
    local calls

    # resource-unref、SET_SCANOUT(0) 与 reset 必须走同一完整释放顺序。
    calls="$(grep -c 'virtio_gpu_virgl_disable_scanout(g,' "$VIRGL_C")"
    [[ "$calls" -ge 3 ]] \
        || fail "resource-unref, set-scanout and reset must share disable helper"
}

test_resource_export_tracks_fd_ownership() {
    # 中文注释：info.fd 是 virglrenderer 的借用句柄，export_fd 是新导出的
    # owned 句柄；把两个布尔值写反会导致 double-close 或永久泄漏。
    grep -Eq 'g, ss\.scanout_id, info\.fd,[[:space:]]*$' "$VIRGL_C" \
        || fail "missing borrowed virgl info.fd sideband path"
    grep -Eq 'info\.flags & VIRTIO_GPU_RESOURCE_FLAG_Y_0_TOP,[[:space:]]*$' "$VIRGL_C" \
        || fail "missing virgl sideband ownership argument"
    grep -Eq '^[[:space:]]+false\)\) \{' "$VIRGL_C" \
        || fail "borrowed info.fd path must set owns_fd=false"
    grep -Eq 'g, ss\.scanout_id, export_fd,[[:space:]]*$' "$VIRGL_C" \
        || fail "missing owned export_blob fd sideband path"
    grep -Eq '^[[:space:]]+true\)\) \{' "$VIRGL_C" \
        || fail "export_blob fd path must set owns_fd=true"
}

test_resource_unref_releases_matching_scanouts_first
test_disable_helper_releases_every_host_reference
test_reset_and_set_scanout_share_disable_helper
test_resource_export_tracks_fd_ownership

echo "OK: virgl dma-buf lifecycle static checks passed"
