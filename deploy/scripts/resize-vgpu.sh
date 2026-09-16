#!/usr/bin/env bash
# GPU-only, offline resizing; never regenerate the rest of a VM's identity.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/resize-vgpu.py" "$@"
