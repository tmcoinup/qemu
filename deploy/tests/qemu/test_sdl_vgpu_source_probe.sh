#!/usr/bin/env bash
# Keep the host-only source capability fixtures in both G-11 test runners.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/test_vgpu_dmabuf_probe.py"
