#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=deploy/lib/cpu-realization.sh
source "$repo_root/deploy/lib/cpu-realization.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
reset_probe() {
    G11_KVM_CAPABILITIES_INJECTED=1
    G11_KVM_AVAILABLE=1
    G11_KVM_GET_TSC_KHZ=1
    G11_KVM_TSC_KHZ=2194916
    G11_KVM_ERROR=
}

reset_probe
G11_KVM_TSC_CONTROL=1
g11_tsc_policy_resolve /unused 3400000000 auto || fail 'scaled auto policy failed'
[[ "$G11_TSC_QEMU_OPTION" == tsc-freq=3400000000 &&
   "$G11_TSC_RUNTIME_SOURCE" == profile-stable ]] ||
    fail 'scaled host did not retain profile TSC'

reset_probe
G11_KVM_TSC_CONTROL=0
g11_tsc_policy_resolve /unused 3400000000 auto || fail 'native fallback failed'
[[ "$G11_TSC_QEMU_OPTION" == tsc-freq=2194916000 &&
   "$G11_TSC_RUNTIME_SOURCE" == host-fallback-no-scaling ]] ||
    fail 'unscaled host did not use explicit invariant host TSC'

reset_probe
G11_KVM_TSC_CONTROL=0
if g11_tsc_policy_resolve /unused 3400000000 profile; then
    fail 'strict profile policy accepted an impossible TSC ratio'
fi

reset_probe
G11_KVM_TSC_CONTROL=0
g11_tsc_policy_resolve /unused 3400000000 omit || fail 'omit policy failed'
[[ -z "$G11_TSC_QEMU_OPTION" && "$G11_TSC_RUNTIME_SOURCE" == host-implicit ]] ||
    fail 'omit policy still emitted tsc-freq'

g11_tsc_frequency_within_250ppm 3400000 3400800 ||
    fail '250ppm boundary helper rejected an in-range value'
if g11_tsc_frequency_within_250ppm 3400000 3401000; then
    fail '250ppm boundary helper accepted an out-of-range value'
fi

echo 'PASS: G-11 KVM-aware stable TSC policy'
