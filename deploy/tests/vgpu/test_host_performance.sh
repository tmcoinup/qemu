#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
helper="$repo_root/deploy/host/g11-performance.sh"
installer="$repo_root/deploy/host/install-g11-performance.sh"
launcher="$repo_root/deploy/scripts/start-vm.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
write_value() { printf '%s\n' "$2" >"$1"; }

cpufreq="$tmp/sys/cpufreq"
intel="$tmp/sys/intel_pstate"
thp="$tmp/sys/thp"
kvm="$tmp/sys/kvm"
block="$tmp/sys/block"
vmsysctl="$tmp/proc/sys/vm"
state="$tmp/run/state"
lock="$tmp/run/performance.lock"
mkdir -p "$cpufreq/policy0" "$cpufreq/policy1" "$intel" "$thp" "$kvm" \
    "$block/nvme0n1/queue" "$vmsysctl" "$tmp/run"

write_value "$cpufreq/policy0/scaling_driver" intel_cpufreq
write_value "$cpufreq/policy0/scaling_available_governors" \
    'performance powersave ondemand schedutil'
write_value "$cpufreq/policy0/scaling_governor" powersave
write_value "$cpufreq/policy0/cpuinfo_min_freq" 1200000
write_value "$cpufreq/policy0/cpuinfo_max_freq" 3700000
write_value "$cpufreq/policy0/scaling_min_freq" 2400000
write_value "$cpufreq/policy0/scaling_max_freq" 3000000

write_value "$cpufreq/policy1/scaling_driver" intel_pstate
write_value "$cpufreq/policy1/scaling_available_governors" 'performance powersave'
write_value "$cpufreq/policy1/scaling_governor" performance
write_value "$cpufreq/policy1/cpuinfo_min_freq" 800000
write_value "$cpufreq/policy1/cpuinfo_max_freq" 4600000
write_value "$cpufreq/policy1/scaling_min_freq" 4600000
write_value "$cpufreq/policy1/scaling_max_freq" 4600000
write_value "$cpufreq/policy1/energy_performance_preference" balance_performance
write_value "$cpufreq/policy1/energy_performance_available_preferences" \
    'default performance balance_performance balance_power power'

write_value "$intel/no_turbo" 1
write_value "$thp/enabled" 'always [never] madvise'
write_value "$thp/defrag" 'always [madvise] never'
write_value "$kvm/halt_poll_ns" 0
write_value "$kvm/nx_huge_pages" Y
write_value "$vmsysctl/swappiness" 60
write_value "$block/nvme0n1/queue/scheduler" '[mq-deadline] none'

perf_env=(
    G11_PERFORMANCE_TEST_MODE=1
    G11_PERFORMANCE_CPUFREQ_ROOT="$cpufreq"
    G11_PERFORMANCE_INTEL_PSTATE_ROOT="$intel"
    G11_PERFORMANCE_THP_ROOT="$thp"
    G11_PERFORMANCE_KVM_ROOT="$kvm"
    G11_PERFORMANCE_BLOCK_ROOT="$block"
    G11_PERFORMANCE_VM_ROOT="$vmsysctl"
    G11_PERFORMANCE_STATE_DIR="$state"
    G11_PERFORMANCE_LOCK_FILE="$lock"
)

apply_out=$(env "${perf_env[@]}" "$helper" apply)
grep -Fq 'ready=yes' <<<"$apply_out" || fail 'apply audit is not ready'
grep -Fq 'latency-first-v1' <<<"$apply_out" || fail 'policy name missing'
[[ "$(<"$cpufreq/policy0/scaling_governor")" == performance ]] ||
    fail 'passive driver did not select the latency-first governor'
[[ "$(<"$cpufreq/policy0/scaling_min_freq")" == 1200000 &&
   "$(<"$cpufreq/policy0/scaling_max_freq")" == 3700000 ]] ||
    fail 'policy0 was not released to the hardware frequency range'
[[ "$(<"$cpufreq/policy1/scaling_governor")" == performance ]] ||
    fail 'active intel_pstate did not select the latency-first governor'
[[ "$(<"$cpufreq/policy1/energy_performance_preference")" == performance ]] ||
    fail 'performance EPP was not selected'
[[ "$(<"$intel/no_turbo")" == 0 ]] || fail 'turbo was not enabled'
[[ "$(<"$thp/enabled")" == madvise && "$(<"$thp/defrag")" == never ]] ||
    fail 'THP runtime policy is wrong'
[[ "$(<"$kvm/halt_poll_ns")" == 200000 ]] || fail 'halt polling was not enabled'
[[ "$(<"$kvm/nx_huge_pages")" == N ]] || fail 'nx huge page recovery was not disabled'
[[ "$(<"$vmsysctl/swappiness")" == 1 ]] || fail 'swappiness was not lowered'
[[ "$(<"$block/nvme0n1/queue/scheduler")" == none ]] ||
    fail 'NVMe scheduler was not changed to none'
[[ -s "$state/original-state.tsv" ]] || fail 'rollback state was not saved'

audit_out=$(env "${perf_env[@]}" "$helper" audit)
grep -Fq 'memory=host-native-unthrottled' <<<"$audit_out" ||
    fail 'audit does not state the memory runtime policy'
grep -Fq 'nx_huge_pages=N' <<<"$audit_out" ||
    fail 'audit does not report nx_huge_pages'
grep -Fq 'swappiness=1' <<<"$audit_out" ||
    fail 'audit does not report swappiness'

env "${perf_env[@]}" "$helper" restore >/dev/null
[[ "$(<"$cpufreq/policy0/scaling_governor")" == powersave ]] ||
    fail 'governor rollback failed'
[[ "$(<"$cpufreq/policy1/scaling_governor")" == performance ]] ||
    fail 'policy1 governor rollback failed'
[[ "$(<"$cpufreq/policy0/scaling_min_freq")" == 2400000 &&
   "$(<"$cpufreq/policy0/scaling_max_freq")" == 3000000 ]] ||
    fail 'frequency rollback failed'
[[ "$(<"$intel/no_turbo")" == 1 ]] || fail 'turbo rollback failed'
[[ "$(<"$kvm/halt_poll_ns")" == 0 ]] || fail 'halt poll rollback failed'
[[ "$(<"$kvm/nx_huge_pages")" == Y ]] || fail 'nx huge page rollback failed'
[[ "$(<"$vmsysctl/swappiness")" == 60 ]] || fail 'swappiness rollback failed'
[[ "$(<"$block/nvme0n1/queue/scheduler")" == mq-deadline ]] ||
    fail 'NVMe scheduler rollback failed'
[[ ! -e "$state/original-state.tsv" ]] || fail 'completed rollback kept stale state'

install_plan=$("$installer" --print)
grep -Fq 'NOPASSWD:NOSETENV' <<<"$install_plan" || fail 'sudo rule permits environment injection'
grep -Fq '/usr/local/libexec/qemu-g11-performance apply' <<<"$install_plan" ||
    fail 'installer omits fixed apply command'
grep -Fq 'clock=${G11_RTC_CLOCK}' "$launcher" || fail 'launcher omits selectable RTC clock'
grep -Fq 'prealloc=on,merge=off' "$launcher" || fail 'guest RAM still permits KSM merging'

echo 'PASS: G-11 latency-first host performance policy, rollback and launcher integration'

