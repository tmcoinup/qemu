#!/usr/bin/env bash
# Guard the NVIDIA VFIO REGION unchanged-frame and high-motion fast paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VFIO_DISPLAY="$REPO_ROOT/hw/vfio/display.c"
VFIO_HEADER="$REPO_ROOT/hw/vfio/vfio-display.h"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -Fq 'uint8_t *shadow;' "$VFIO_HEADER" \
    || fail "VFIO REGION lost its previous-frame shadow"
grep -Fq 'vfio_display_region_find_updates' "$VFIO_DISPLAY" \
    || fail "VFIO REGION no longer performs exact unchanged-frame detection"
grep -Fq 'memcmp(src, shadow' "$VFIO_DISPLAY" \
    || fail "VFIO REGION dedup must compare actual visible pixels"
grep -Fq 'VFIO_REGION_MAX_DIRTY_RUNS' "$VFIO_DISPLAY" \
    || fail "VFIO REGION lost row-run damage coalescing"
grep -Fq 'VFIO_REGION_COMPARE_BYPASS_FRAMES' "$VFIO_DISPLAY" \
    || fail "full-motion content no longer bypasses comparison overhead"
grep -Fq 'surface_stride(dpy->region.surface) != plane.stride' "$VFIO_DISPLAY" \
    || fail "REGION surface layout changes no longer invalidate the cache"
grep -Fq 'vfio_display_region_shadow_reset(dpy);' "$VFIO_DISPLAY" \
    || fail "REGION shadow lifecycle cleanup is missing"

echo "OK: VFIO REGION frame dedup and motion bypass static checks passed"
