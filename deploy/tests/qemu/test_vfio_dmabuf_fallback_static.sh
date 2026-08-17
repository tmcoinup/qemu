#!/usr/bin/env bash
# Keep the upstream mdev dma-buf fallback diagnostic backport intact.  This is
# a source-level gate; the normal G-11 build verifies the compiled C path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE="$REPO_ROOT/hw/vfio/region.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$SOURCE" ]] || fail "missing hw/vfio/region.c"
! grep -Fq 'PCI BAR IOMMU mappings may fail' "$SOURCE" \
    || fail "misleading PCI BAR/IOMMU dma-buf diagnostic returned"
grep -Fq 'using mmap fallback, P2P DMA will not work' "$SOURCE" \
    || fail "mmap fallback and P2P scope are not reported"
grep -Fq 'warn_report_err_once(local_err);' "$SOURCE" \
    || fail "per-BAR mdev dma-buf diagnostics are not deduplicated"
! grep -Fq 'error_report_err(local_err);' "$SOURCE" \
    || fail "dma-buf fallback is still reported as a generic error"

echo "PASS: VFIO dma-buf fallback is scoped to P2P and reported once"
