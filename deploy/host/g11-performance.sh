#!/usr/bin/env bash
# G-11 host runtime performance policy (latency-first).
#
# G-11 guests are interactive desktops driven through an SDL window, so the
# policy optimises wake-up latency rather than throughput-per-watt:
#
#   * governor=performance.  A vCPU thread looks like one long-running task to
#     the host scheduler, so its utilisation never reflects the guest's bursty
#     interactive load.  schedutil/powersave therefore ramp far too slowly --
#     measured 1750 MHz average on a 3700 MHz part.
#   * halt_poll_ns=200000.  Guests idle in very short bursts between input
#     events; polling briefly before scheduling out removes a full IPI plus
#     CFS wake-up round trip from every wake.
#   * nx_huge_pages=N.  The iTLB-multihit mitigation runs a recovery thread
#     that periodically zaps EPT huge pages, which shows up as regular micro
#     stutter.  Local trusted guests can take that trade.
#   * vm.swappiness=1.  memory-backend-memfd is shmem and stays swappable even
#     with prealloc=on; a swapped-out guest page costs hundreds of ms.
#
# It also restores every cpufreq policy to the hardware min/max range, enables
# turbo/boost, and keeps THP defrag synchronous-free.  Guest CPUID, TSC
# frequency, SMBIOS and Windows state are never modified.
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly INSTALLED_SELF=/usr/local/libexec/qemu-g11-performance
TEST_MODE=0
if [[ "${G11_PERFORMANCE_TEST_MODE:-0}" == 1 &&
      "$(realpath -m -- "$0")" != "$INSTALLED_SELF" ]]; then
    TEST_MODE=1
fi

if ((TEST_MODE)); then
    CPUFREQ_ROOT=${G11_PERFORMANCE_CPUFREQ_ROOT:?test cpufreq root is required}
    INTEL_PSTATE_ROOT=${G11_PERFORMANCE_INTEL_PSTATE_ROOT:?test intel_pstate root is required}
    THP_ROOT=${G11_PERFORMANCE_THP_ROOT:?test THP root is required}
    KVM_ROOT=${G11_PERFORMANCE_KVM_ROOT:?test KVM root is required}
    BLOCK_ROOT=${G11_PERFORMANCE_BLOCK_ROOT:?test block root is required}
    VM_ROOT=${G11_PERFORMANCE_VM_ROOT:?test vm sysctl root is required}
    STATE_DIR=${G11_PERFORMANCE_STATE_DIR:?test state dir is required}
    LOCK_FILE=${G11_PERFORMANCE_LOCK_FILE:?test lock file is required}
else
    CPUFREQ_ROOT=/sys/devices/system/cpu/cpufreq
    INTEL_PSTATE_ROOT=/sys/devices/system/cpu/intel_pstate
    THP_ROOT=/sys/kernel/mm/transparent_hugepage
    KVM_ROOT=/sys/module/kvm/parameters
    BLOCK_ROOT=/sys/block
    VM_ROOT=/proc/sys/vm
    STATE_DIR=/run/qemu-g11-performance
    LOCK_FILE=/run/lock/qemu-g11-performance.lock
fi
STATE_FILE="$STATE_DIR/original-state.tsv"

# Latency-first targets.  200 us of halt polling covers the common short idle
# between input events without burning a meaningful slice of a vCPU.
readonly HALT_POLL_NS_TARGET=200000
readonly SWAPPINESS_TARGET=1

log() { printf '[g11-performance] %s\n' "$*"; }
warn() { printf '[g11-performance] WARN: %s\n' "$*" >&2; }
die() { printf '[g11-performance] ERROR: %s\n' "$*" >&2; exit 1; }

selected_value() {
    local value=$1
    if [[ "$value" =~ \[([^][]+)\] ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$value"
    fi
}

read_one_line() {
    local path=$1 value
    [[ -r "$path" && ! -L "$path" ]] || return 1
    IFS= read -r value <"$path" || return 1
    [[ "$value" != *$'\t'* && "$value" != *$'\n'* && "$value" != *$'\r'* ]] ||
        return 1
    printf '%s\n' "$value"
}

latency_governor_for_policy() {
    local policy=$1 available
    available=" $(read_one_line "$policy/scaling_available_governors" 2>/dev/null || true) "

    # Interactive guests need the frequency already high when the input event
    # arrives, so a fixed high governor beats every load-following one here.
    # The remaining branches are ordered by how quickly they ramp, and only
    # matter on hosts that do not expose "performance" at all.
    if [[ "$available" == *' performance '* ]]; then
        printf 'performance\n'
    elif [[ "$available" == *' schedutil '* ]]; then
        printf 'schedutil\n'
    elif [[ "$available" == *' ondemand '* ]]; then
        printf 'ondemand\n'
    elif [[ "$available" == *' powersave '* ]]; then
        printf 'powersave\n'
    else
        return 1
    fi
}

write_exact() {
    local path=$1 target=$2 actual
    [[ -e "$path" && ! -L "$path" && -w "$path" ]] || return 1
    printf '%s\n' "$target" >"$path" || return 1
    actual=$(read_one_line "$path" 2>/dev/null || true)
    [[ "$(selected_value "$actual")" == "$target" ]]
}

state_append() {
    local output=$1 key=$2 value=$3
    [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    [[ "$value" != *$'\t'* && "$value" != *$'\n'* && "$value" != *$'\r'* ]] ||
        return 1
    printf '%s\t%s\n' "$key" "$value" >>"$output"
}

snapshot_original_state() {
    local tmp policy name field value disk scheduler

    [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] && return 0
    mkdir -p -- "$STATE_DIR"
    chmod 0700 -- "$STATE_DIR"
    tmp="$STATE_DIR/.original-state.$$.tmp"
    : >"$tmp"
    chmod 0600 -- "$tmp"

    for policy in "$CPUFREQ_ROOT"/policy[0-9]*; do
        [[ -d "$policy" && ! -L "$policy" ]] || continue
        name=${policy##*/}
        [[ "$name" =~ ^policy[0-9]+$ ]] || continue
        for field in scaling_governor scaling_min_freq scaling_max_freq \
                energy_performance_preference; do
            value=$(read_one_line "$policy/$field" 2>/dev/null || true)
            [[ -n "$value" ]] || continue
            state_append "$tmp" "cpu.${name}.${field}" \
                "$(selected_value "$value")"
        done
    done
    for field in no_turbo; do
        value=$(read_one_line "$INTEL_PSTATE_ROOT/$field" 2>/dev/null || true)
        [[ -z "$value" ]] || state_append "$tmp" "intel_pstate.${field}" "$value"
    done
    value=$(read_one_line "$CPUFREQ_ROOT/boost" 2>/dev/null || true)
    [[ -z "$value" ]] || state_append "$tmp" cpufreq.boost "$value"
    for field in enabled defrag; do
        value=$(read_one_line "$THP_ROOT/$field" 2>/dev/null || true)
        [[ -z "$value" ]] || state_append "$tmp" "thp.${field}" \
            "$(selected_value "$value")"
    done
    value=$(read_one_line "$KVM_ROOT/halt_poll_ns" 2>/dev/null || true)
    [[ -z "$value" ]] || state_append "$tmp" kvm.halt_poll_ns "$value"
    value=$(read_one_line "$KVM_ROOT/nx_huge_pages" 2>/dev/null || true)
    [[ -z "$value" ]] || state_append "$tmp" kvm.nx_huge_pages "$value"
    value=$(read_one_line "$VM_ROOT/swappiness" 2>/dev/null || true)
    [[ -z "$value" ]] || state_append "$tmp" vm.swappiness "$value"
    for scheduler in "$BLOCK_ROOT"/nvme*n*/queue/scheduler; do
        [[ -e "$scheduler" && ! -L "$scheduler" ]] || continue
        disk=${scheduler#"$BLOCK_ROOT"/}
        disk=${disk%%/*}
        [[ "$disk" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        value=$(read_one_line "$scheduler" 2>/dev/null || true)
        [[ -z "$value" ]] || state_append "$tmp" "nvme.${disk}.scheduler" \
            "$(selected_value "$value")"
    done
    mv -fT -- "$tmp" "$STATE_FILE"
}

performance_check() {
    local policy governor expected min max hw_min hw_max epp available
    local scheduler value count=0

    for policy in "$CPUFREQ_ROOT"/policy[0-9]*; do
        [[ -d "$policy" && ! -L "$policy" ]] || continue
        count=$((count + 1))
        expected=$(latency_governor_for_policy "$policy") || return 1
        governor=$(read_one_line "$policy/scaling_governor" 2>/dev/null || true)
        [[ "$governor" == "$expected" ]] || return 1
        min=$(read_one_line "$policy/scaling_min_freq" 2>/dev/null || true)
        max=$(read_one_line "$policy/scaling_max_freq" 2>/dev/null || true)
        hw_min=$(read_one_line "$policy/cpuinfo_min_freq" 2>/dev/null || true)
        hw_max=$(read_one_line "$policy/cpuinfo_max_freq" 2>/dev/null || true)
        [[ "$min" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ &&
           "$hw_min" =~ ^[0-9]+$ && "$hw_max" =~ ^[0-9]+$ &&
           "$min" == "$hw_min" && "$max" == "$hw_max" ]] || return 1
        if [[ -e "$policy/energy_performance_preference" ]]; then
            epp=$(read_one_line "$policy/energy_performance_preference" 2>/dev/null || true)
            available=" $(read_one_line "$policy/energy_performance_available_preferences" 2>/dev/null || true) "
            if [[ "$available" == *' performance '* ]]; then
                [[ "$epp" == performance ]] || return 1
            fi
        fi
    done

    value=$(read_one_line "$INTEL_PSTATE_ROOT/no_turbo" 2>/dev/null || true)
    [[ -z "$value" || "$value" == 0 ]] || return 1
    value=$(read_one_line "$CPUFREQ_ROOT/boost" 2>/dev/null || true)
    [[ -z "$value" || "$value" == 1 ]] || return 1
    value=$(read_one_line "$THP_ROOT/enabled" 2>/dev/null || true)
    [[ -z "$value" || "$(selected_value "$value")" == madvise ]] || return 1
    value=$(read_one_line "$THP_ROOT/defrag" 2>/dev/null || true)
    [[ -z "$value" || "$(selected_value "$value")" == never ]] || return 1
    value=$(read_one_line "$KVM_ROOT/halt_poll_ns" 2>/dev/null || true)
    [[ -z "$value" || "$value" == "$HALT_POLL_NS_TARGET" ]] || return 1
    value=$(read_one_line "$KVM_ROOT/nx_huge_pages" 2>/dev/null || true)
    [[ -z "$value" || "$value" == N ]] || return 1
    value=$(read_one_line "$VM_ROOT/swappiness" 2>/dev/null || true)
    [[ -z "$value" || "$value" == "$SWAPPINESS_TARGET" ]] || return 1
    for scheduler in "$BLOCK_ROOT"/nvme*n*/queue/scheduler; do
        [[ -e "$scheduler" && ! -L "$scheduler" ]] || continue
        value=$(read_one_line "$scheduler" 2>/dev/null || true)
        available=" $value "
        [[ "$available" != *' none '* || "$(selected_value "$value")" == none ]] ||
            return 1
    done
    # A host with no cpufreq policies is a fixed-frequency platform, not a
    # failure.  The remaining latency policies still apply.
    return 0
}

performance_audit() {
    local first=1 policy governor min max hw_min hw_max count=0 summary='fixed-frequency'
    local turbo='n/a' thp_enabled='n/a' thp_defrag='n/a' halt_poll='n/a'
    local nx_huge='n/a' swappiness='n/a'
    local ready=no

    for policy in "$CPUFREQ_ROOT"/policy[0-9]*; do
        [[ -d "$policy" && ! -L "$policy" ]] || continue
        count=$((count + 1))
        if ((first)); then
            governor=$(read_one_line "$policy/scaling_governor" 2>/dev/null || echo unknown)
            min=$(read_one_line "$policy/scaling_min_freq" 2>/dev/null || echo unknown)
            max=$(read_one_line "$policy/scaling_max_freq" 2>/dev/null || echo unknown)
            hw_min=$(read_one_line "$policy/cpuinfo_min_freq" 2>/dev/null || echo unknown)
            hw_max=$(read_one_line "$policy/cpuinfo_max_freq" 2>/dev/null || echo unknown)
            summary="latency-first governor=${governor} range=${min}-${max} hardware=${hw_min}-${hw_max}kHz"
            first=0
        fi
    done
    [[ -e "$INTEL_PSTATE_ROOT/no_turbo" ]] &&
        turbo=$([[ "$(read_one_line "$INTEL_PSTATE_ROOT/no_turbo" 2>/dev/null || echo 1)" == 0 ]] && echo on || echo off)
    if [[ "$turbo" == n/a && -e "$CPUFREQ_ROOT/boost" ]]; then
        turbo=$([[ "$(read_one_line "$CPUFREQ_ROOT/boost" 2>/dev/null || echo 0)" == 1 ]] && echo on || echo off)
    fi
    [[ -e "$THP_ROOT/enabled" ]] && thp_enabled=$(selected_value \
        "$(read_one_line "$THP_ROOT/enabled" 2>/dev/null || echo unknown)")
    [[ -e "$THP_ROOT/defrag" ]] && thp_defrag=$(selected_value \
        "$(read_one_line "$THP_ROOT/defrag" 2>/dev/null || echo unknown)")
    [[ -e "$KVM_ROOT/halt_poll_ns" ]] &&
        halt_poll=$(read_one_line "$KVM_ROOT/halt_poll_ns" 2>/dev/null || echo unknown)
    [[ -e "$KVM_ROOT/nx_huge_pages" ]] &&
        nx_huge=$(read_one_line "$KVM_ROOT/nx_huge_pages" 2>/dev/null || echo unknown)
    [[ -e "$VM_ROOT/swappiness" ]] &&
        swappiness=$(read_one_line "$VM_ROOT/swappiness" 2>/dev/null || echo unknown)
    performance_check && ready=yes
    printf 'g11-host-performance: ready=%s cpu="%s" policies=%s turbo=%s thp=%s/%s halt_poll_ns=%s nx_huge_pages=%s swappiness=%s memory=host-native-unthrottled\n' \
        "$ready" "$summary" "$count" "$turbo" "$thp_enabled" "$thp_defrag" \
        "$halt_poll" "$nx_huge" "$swappiness"
}

performance_apply() {
    local policy governor hw_min hw_max epp_available scheduler failures=0 count=0

    ((EUID == 0 || TEST_MODE == 1)) || die 'apply 必须通过已安装的 sudo helper 运行'
    mkdir -p -- "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -w 15 9 || die '性能策略锁超时'
    snapshot_original_state

    for policy in "$CPUFREQ_ROOT"/policy[0-9]*; do
        [[ -d "$policy" && ! -L "$policy" ]] || continue
        count=$((count + 1))
        governor=$(latency_governor_for_policy "$policy") || {
            warn "${policy##*/} 没有可用 governor"
            failures=$((failures + 1))
            continue
        }
        hw_min=$(read_one_line "$policy/cpuinfo_min_freq" 2>/dev/null || true)
        hw_max=$(read_one_line "$policy/cpuinfo_max_freq" 2>/dev/null || true)
        if [[ ! "$hw_min" =~ ^[0-9]+$ || ! "$hw_max" =~ ^[0-9]+$ ||
              "$hw_min" -gt "$hw_max" ]]; then
            warn "${policy##*/} 硬件频率范围无效"
            failures=$((failures + 1))
            continue
        fi
        # Lower min first, then release max.  This preserves a valid min<=max
        # transition even when an older policy pinned both ends.
        write_exact "$policy/scaling_min_freq" "$hw_min" || failures=$((failures + 1))
        write_exact "$policy/scaling_max_freq" "$hw_max" || failures=$((failures + 1))
        write_exact "$policy/scaling_governor" "$governor" || failures=$((failures + 1))
        if [[ -e "$policy/energy_performance_preference" ]]; then
            epp_available=" $(read_one_line "$policy/energy_performance_available_preferences" 2>/dev/null || true) "
            if [[ "$epp_available" == *' performance '* ]]; then
                write_exact "$policy/energy_performance_preference" performance ||
                    failures=$((failures + 1))
            fi
        fi
    done

    if [[ -e "$INTEL_PSTATE_ROOT/no_turbo" ]]; then
        write_exact "$INTEL_PSTATE_ROOT/no_turbo" 0 || failures=$((failures + 1))
    fi
    if [[ -e "$CPUFREQ_ROOT/boost" ]]; then
        write_exact "$CPUFREQ_ROOT/boost" 1 || failures=$((failures + 1))
    fi
    if [[ -e "$THP_ROOT/enabled" ]]; then
        write_exact "$THP_ROOT/enabled" madvise || failures=$((failures + 1))
    fi
    if [[ -e "$THP_ROOT/defrag" ]]; then
        write_exact "$THP_ROOT/defrag" never || failures=$((failures + 1))
    fi
    if [[ -e "$KVM_ROOT/halt_poll_ns" ]]; then
        write_exact "$KVM_ROOT/halt_poll_ns" "$HALT_POLL_NS_TARGET" ||
            failures=$((failures + 1))
    fi
    # The bool parameter reads back as Y/N, so write the same spelling that
    # write_exact will compare against.
    if [[ -e "$KVM_ROOT/nx_huge_pages" ]]; then
        write_exact "$KVM_ROOT/nx_huge_pages" N || failures=$((failures + 1))
    fi
    if [[ -e "$VM_ROOT/swappiness" ]]; then
        write_exact "$VM_ROOT/swappiness" "$SWAPPINESS_TARGET" ||
            failures=$((failures + 1))
    fi
    for scheduler in "$BLOCK_ROOT"/nvme*n*/queue/scheduler; do
        [[ -e "$scheduler" && ! -L "$scheduler" ]] || continue
        if [[ " $(read_one_line "$scheduler" 2>/dev/null || true) " == *' none '* ]]; then
            write_exact "$scheduler" none || failures=$((failures + 1))
        fi
    done

    performance_audit
    ((failures == 0)) || die "有 ${failures} 个宿主性能旋钮未能应用"
    performance_check || die '应用后复核未通过'
    log "已应用 latency-first-v1（${count} 个 CPU policy；不按来宾型号封顶）"
}

restore_one() {
    local key=$1 value=$2 policy field disk path
    case "$key" in
        cpu.policy[0-9]*.*)
            [[ "$key" =~ ^cpu\.(policy[0-9]+)\.(scaling_governor|scaling_min_freq|scaling_max_freq|energy_performance_preference)$ ]] || return 1
            policy=${BASH_REMATCH[1]}
            field=${BASH_REMATCH[2]}
            path="$CPUFREQ_ROOT/$policy/$field"
            ;;
        intel_pstate.no_turbo) path="$INTEL_PSTATE_ROOT/no_turbo" ;;
        cpufreq.boost) path="$CPUFREQ_ROOT/boost" ;;
        thp.enabled) path="$THP_ROOT/enabled" ;;
        thp.defrag) path="$THP_ROOT/defrag" ;;
        kvm.halt_poll_ns) path="$KVM_ROOT/halt_poll_ns" ;;
        kvm.nx_huge_pages) path="$KVM_ROOT/nx_huge_pages" ;;
        vm.swappiness) path="$VM_ROOT/swappiness" ;;
        nvme.nvme[0-9]*n[0-9]*.scheduler)
            [[ "$key" =~ ^nvme\.(nvme[0-9]+n[0-9]+)\.scheduler$ ]] || return 1
            disk=${BASH_REMATCH[1]}
            path="$BLOCK_ROOT/$disk/queue/scheduler"
            ;;
        *) return 1 ;;
    esac
    [[ -e "$path" ]] || return 0
    write_exact "$path" "$value"
}

performance_restore() {
    local key value failures=0

    ((EUID == 0 || TEST_MODE == 1)) || die 'restore 必须通过已安装的 sudo helper 运行'
    mkdir -p -- "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -w 15 9 || die '性能策略锁超时'
    [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || die '没有可恢复的原始状态'
    while IFS=$'\t' read -r key value extra; do
        [[ -n "$key" && -n "$value" && -z "${extra:-}" ]] || {
            failures=$((failures + 1))
            continue
        }
        restore_one "$key" "$value" || failures=$((failures + 1))
    done <"$STATE_FILE"
    ((failures == 0)) || die "有 ${failures} 个原始状态未能恢复；状态文件已保留"
    rm -f -- "$STATE_FILE"
    log '已恢复首次 apply 前的宿主设置'
    performance_audit
}

command_name=${1:-audit}
shift || true
[[ $# == 0 ]] || die '不接受额外参数'
case "$command_name" in
    audit|status) performance_audit ;;
    check) performance_check ;;
    apply) performance_apply ;;
    restore) performance_restore ;;
    *) die '用法: g11-performance.sh audit|check|apply|restore' ;;
esac
