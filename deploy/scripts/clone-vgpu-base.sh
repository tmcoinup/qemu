#!/usr/bin/env bash
# Compatibility alias.  The V-11/G-11 canonical clone filename is
# clone-from-base.sh; G-11 portable-attested clone semantics remain there.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[clone-vgpu-base] 已更名为 clone-from-base.sh；本兼容入口将继续转发。" >&2
exec "$script_dir/clone-from-base.sh" win10-base "$@"
