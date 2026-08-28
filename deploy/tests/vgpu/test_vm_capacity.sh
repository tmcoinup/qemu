#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
start_vm="$repo_root/deploy/scripts/start-vm.sh"
cpu_isolation="$repo_root/deploy/lib/cpu-isolation.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Shared scheduling must not inspect other QEMU processes or turn a vCPU count
# into either a warning or a launch gate. Actual host pressure is intentionally
# left to the Linux scheduler; isolated mode retains its cpuset capacity checks.
[[ ! -e "$repo_root/deploy/lib/vm-capacity.sh" ]] || \
    fail 'obsolete shared-mode capacity warning library is still installed'

if grep -Eq 'vm-capacity|g11_capacity|G11_CAPACITY|CPU capacity:' "$start_vm"; then
    fail 'start-vm still contains a shared-mode capacity scan or warning'
fi

grep -Fq -- 'false) CPU_ISOLATION=off ;;' "$start_vm" || \
    fail 'start-vm no longer maps --cpu-isolate=false to shared scheduling'
grep -Fq '[[ "${CPU_ISOLATION:-required}" != off ]] || return 0' "$cpu_isolation" || \
    fail 'shared scheduling no longer bypasses CPU isolation setup'

echo 'PASS: shared CPU mode has no host-wide vCPU count warning or launch gate'
