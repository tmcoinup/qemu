#!/usr/bin/env bash
# Apply only the per-VM registry identity to a running Windows guest.
# The default remains guest-minimal: NVIDIA Control Panel gets its product
# name from the host-side per-mdev override.  --with-nvapi-shim is an explicit
# compatibility fallback that replaces the x64/x86 NVIDIA NVAPI DLLs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -lt 1 ]]; then
    echo "usage: $0 <vm_id> [--ip A.B.C.D]" >&2
    exit 2
fi

exec "$here/setup-guest.sh" "$@" \
    --skip-vgpu --skip-license --skip-ivshmem --skip-service \
    --skip-monitor --skip-input --with-guest-identity
