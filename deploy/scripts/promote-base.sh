#!/usr/bin/env bash
# Compatibility alias.  The V-11/G-11 canonical base-image filename is
# seal-base.sh; G-11 sealing semantics remain implemented there.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[promote-base] 已更名为 seal-base.sh；本兼容入口将继续转发。" >&2

# Historical promote accepted zero/one positional VM id and always targeted
# win10-base.qcow2.  Keep precisely that behavior while the canonical seal
# command requires an explicit name.
positional_count=0
for arg in "$@"; do
    [[ "$arg" == -* ]] || positional_count=$((positional_count + 1))
done
case "$positional_count" in
    0) exec "$script_dir/seal-base.sh" "$@" 1 win10-base ;;
    1) exec "$script_dir/seal-base.sh" "$@" win10-base ;;
    *) exec "$script_dir/seal-base.sh" "$@" ;;
esac
