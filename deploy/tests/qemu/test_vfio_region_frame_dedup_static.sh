#!/usr/bin/env bash
# Guard the NVIDIA VFIO REGION stable staging and frame-dedup paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VFIO_DISPLAY="$REPO_ROOT/hw/vfio/display.c"
VFIO_HEADER="$REPO_ROOT/hw/vfio/vfio-display.h"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -Fq 'uint8_t *staging;' "$VFIO_HEADER" \
    || fail "VFIO REGION lost its stable staging frame"
grep -Fq 'size_t staging_size;' "$VFIO_HEADER" \
    || fail "VFIO REGION staging allocation is not layout-sized"
grep -Fq '*staging_size = (size_t)plane->stride * plane->height;' \
    "$VFIO_DISPLAY" \
    || fail "VFIO REGION staging does not preserve the source stride"
grep -Fq 'vfio_display_region_find_updates' "$VFIO_DISPLAY" \
    || fail "VFIO REGION no longer performs exact unchanged-frame detection"
grep -Fq 'memcmp(src, staging' "$VFIO_DISPLAY" \
    || fail "VFIO REGION dedup must compare actual visible pixels"
grep -Fq 'VFIO_REGION_MAX_DIRTY_RUNS' "$VFIO_DISPLAY" \
    || fail "VFIO REGION lost row-run damage coalescing"
grep -Fq 'VFIO_REGION_COMPARE_BYPASS_FRAMES' "$VFIO_DISPLAY" \
    || fail "full-motion content no longer bypasses comparison overhead"
grep -Fq 'memcpy(staging, source, staging_size);' "$VFIO_DISPLAY" \
    || fail "a replacement REGION surface is visible before staging is filled"
grep -Fq 'plane->stride, staging);' "$VFIO_DISPLAY" \
    || fail "REGION DisplaySurface is not backed by stable staging"
grep -Fq 'vfio_display_region_staging_copy(dpy, source);' "$VFIO_DISPLAY" \
    || fail "full-motion bypass no longer refreshes staging before update"
grep -Fq 'keeping the last staged frame' "$VFIO_DISPLAY" \
    || fail "REGION failure paths no longer document safe-frame retention"
grep -Fq 'failure_streak' "$VFIO_HEADER" \
    || fail "REGION source errors are no longer rate-limited"
grep -Fq 'failure_retry_after_us' "$VFIO_HEADER" \
    || fail "REGION source failures can retry at the full display rate"
grep -Fq 'VFIO_REGION_FAILURE_RETRY_US' "$VFIO_DISPLAY" \
    || fail "REGION retry work no longer has a bounded backoff"
grep -Fq 'vfio_pci_is(vdev, PCI_VENDOR_ID_NVIDIA, PCI_ANY_ID)' \
    "$VFIO_DISPLAY" \
    || fail "NVIDIA REGION no longer has a vendor-scoped page-safety gate"
grep -Fq '!QEMU_IS_ALIGNED(staging_size, qemu_real_host_page_size())' \
    "$VFIO_DISPLAY" \
    || fail "R535 page-unsafe scanouts can replace the last good surface"
grep -Fq 'R535 presentation rounds it' "$VFIO_DISPLAY" \
    || fail "R535 pixel-length failure no longer has an actionable diagnostic"
grep -Fq 'select a page-safe guest mode such as 1920x1080' "$VFIO_DISPLAY" \
    || fail "R535 diagnostic does not identify a safe recovery mode"
grep -Fq 'vfio_display_region_mark_recovered(dpy);' "$VFIO_DISPLAY" \
    || fail "REGION recovery no longer forces and reports a full staged frame"
grep -Fq 'qemu_console_surface(dpy->con) != surface' "$VFIO_DISPLAY" \
    || fail "REGION no-plane handling may free staging before ramfb switches"
if grep -Fq 'plane.stride, dpy->region.buffer.mmaps[0].mmap' "$VFIO_DISPLAY"; then
    fail "REGION DisplaySurface regressed to the live VFIO mmap"
fi
dmabuf_exit="$(sed -n \
    '/^static void vfio_display_dmabuf_exit/,/^}/p' "$VFIO_DISPLAY")"
grep -Fq 'dpy->dmabuf.primary = NULL;' <<<"$dmabuf_exit" \
    || fail "dma-buf exit leaves a dangling primary pointer"
grep -Fq 'dpy->dmabuf.cursor = NULL;' <<<"$dmabuf_exit" \
    || fail "dma-buf exit leaves a dangling cursor pointer"
dmabuf_reset="$(sed -n \
    '/^void vfio_display_reset/,/^}/p' "$VFIO_DISPLAY")"
dmabuf_reset_compact="$(tr -d '[:space:]' <<<"$dmabuf_reset")"
grep -Fq \
    'if(!vdev->dpy->dmabuf.primary&&QTAILQ_EMPTY(&vdev->dpy->dmabuf.bufs)){return;}' \
    <<<"$dmabuf_reset_compact" \
    || fail "VFIO reset may skip a cache when primary is already inactive"
grep -Fq 'vfio_display_dmabuf_exit(vdev->dpy);' <<<"$dmabuf_reset" \
    || fail "VFIO reset no longer releases the dma-buf cache"

echo "OK: VFIO REGION stable staging, frame dedup and recovery checks passed"
