#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
create_vm="$repo_root/deploy/scripts/create-vm.sh"
# shellcheck source=../../lib/hardware-profiles.sh
source "$repo_root/deploy/lib/hardware-profiles.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
host_config="$tmp_dir/vgpu-host.conf"
printf 'VGPU_HOST_FB_TIER_MB=2048\n' >"$host_config"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

fake_qemu="$tmp_dir/qemu-system-x86_64"
cat >"$fake_qemu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
    echo 'QEMU emulator version 11.0.2 (G-11 fallback test)'
    exit 0
fi

cpu_spec=
previous=
for argument in "$@"; do
    if [[ "$previous" == -cpu ]]; then
        cpu_spec=$argument
        break
    fi
    previous=$argument
done
model=${cpu_spec%%,*}
enforce=${cpu_spec#*,enforce=}
enforce=${enforce%%,*}

case "${FAKE_CPU_MODE:-supported}" in
    supported)
        ;;
    unavailable)
        echo 'qemu-system-x86_64: failed to initialize kvm: Permission denied' >&2
        exit 1
        ;;
    no-new|only-3820|default-unavailable-3820-supported)
        case "$model" in
            Core-i7-4820K)
                if [[ "${FAKE_CPU_MODE}" == default-unavailable-3820-supported ]]; then
                    echo 'qemu-system-x86_64: failed to initialize kvm: Permission denied' >&2
                    exit 1
                elif [[ "$enforce" == on ]]; then
                    echo "qemu-system-x86_64: Host doesn't support requested features" >&2
                    exit 1
                fi
                ;;
            Core-i7-3820)
                if [[ "${FAKE_CPU_MODE}" == no-new && "$enforce" == on ]]; then
                    echo "qemu-system-x86_64: Host doesn't support requested features" >&2
                    exit 1
                fi
                ;;
            *)
                echo "qemu-system-x86_64: unable to find CPU model '$model'" >&2
                exit 1
                ;;
        esac
        ;;
    only-4930)
        if [[ "$enforce" == on && "$model" != Core-i7-4930K ]]; then
            echo "qemu-system-x86_64: Host doesn't support requested features" >&2
            exit 1
        fi
        ;;
    *) exit 99 ;;
esac

echo '{"QMP":{"version":{"qemu":{"major":11,"minor":0,"micro":2}}}}'
echo '{"return":{}}'
EOF
chmod +x "$fake_qemu"

create_one() {
    local mode=$1 id=$2 root
    shift 2
    root="$tmp_dir/$mode"
    mkdir -p "$root/images" "$root/vms"
    FAKE_CPU_MODE=$mode QEMU_BIN="$fake_qemu" \
        IMAGE_ROOT="$root/images" VM_ROOT="$root/vms" \
        VGPU_HOST_CONFIG="$host_config" \
        "$create_vm" "$id" "$@" \
        --ssd-profile samsung-850-pro-512gb \
        --gpu-profile gtx1050_2gb \
        --monitor-profile dell-p2419h >/dev/null
    printf '%s\n' "$root/vms/$id/vm.conf"
}

supported_conf=$(create_one supported 1)
# shellcheck source=/dev/null
source "$supported_conf"
[[ "$PLATFORM_SELECTION_POLICY" == host-supported-performance-first ]] ||
    fail "supported host selection reason: $PLATFORM_SELECTION_POLICY"
[[ "$(hardware_profile_lifecycle_class "$PLATFORM")" == new ]] ||
    fail "supported host selected non-new platform: $PLATFORM"
[[ "$CPU_PROFILE" == i7-4960x && "$CPU_VCPUS" == 12 &&
   "$MEM_SPEED" == 1866 && "$MEM_TOTAL_MB" == 8192 ]] ||
    fail "supported host did not select the fastest reviewed tier: $PLATFORM"
[[ "$BOARD_CHIPSET" == X79 && "$MEM_BOARD_SLOTS" == 8 ]] ||
    fail "supported host did not select an 1866-capable X79 board"

unavailable_conf=$(create_one unavailable 2)
# shellcheck source=/dev/null
source "$unavailable_conf"
[[ "$PLATFORM_SELECTION_POLICY" == probe-unavailable-new-fail-closed ]] ||
    fail "unavailable probe silently changed policy: $PLATFORM_SELECTION_POLICY"
[[ "$(hardware_profile_lifecycle_class "$PLATFORM")" == new ]] ||
    fail "unavailable probe silently selected legacy: $PLATFORM"

fallback_cpu_conf=$(create_one only-3820 4)
# shellcheck source=/dev/null
source "$fallback_cpu_conf"
[[ "$PLATFORM_SELECTION_POLICY" == host-supported-performance-first ]] ||
    fail "second active CPU selection reason: $PLATFORM_SELECTION_POLICY"
[[ "$(hardware_profile_lifecycle_class "$PLATFORM")" == new ]] ||
    fail "second active CPU selected wrong lifecycle: $PLATFORM"
[[ "$CPU_PROFILE" == i7-3820 && "$BOARD_CHIPSET" == X79 &&
   "$MEM_TOTAL_MB" == 8192 ]] ||
    fail "failed to select the reviewed i7-3820 X79 tier"

mixed_probe_conf=$(create_one default-unavailable-3820-supported 5)
# shellcheck source=/dev/null
source "$mixed_probe_conf"
[[ "$PLATFORM_SELECTION_POLICY" == host-supported-performance-first ]] ||
    fail "probe uncertainty prevented a conclusive second CPU result: $PLATFORM_SELECTION_POLICY"
[[ "$CPU_PROFILE" == i7-3820 ]] ||
    fail "probe uncertainty selected $CPU_PROFILE instead of the supported i7-3820"

six_core_conf=$(create_one only-4930 6)
# shellcheck source=/dev/null
source "$six_core_conf"
[[ "$PLATFORM_SELECTION_POLICY" == host-supported-performance-first ]] ||
    fail "6C/12T pool selection reason: $PLATFORM_SELECTION_POLICY"
[[ "$(hardware_profile_lifecycle_class "$PLATFORM")" == new ]] ||
    fail "6C/12T fallback selected wrong lifecycle: $PLATFORM"
[[ "$CPU_PROFILE" == i7-4930k && "$CPU_VCPUS" == 12 &&
   "$MEM_SPEED" == 1866 && "$MEM_TOTAL_MB" == 8192 ]] ||
    fail "failed to select the reviewed i7-4930K/Samsung 1866 tier"

four_spec_conf=$(create_one supported 7 --cpu-spec 4c8t --memory-size 8G)
# shellcheck source=/dev/null
source "$four_spec_conf"
[[ "$PLATFORM_SELECTION_POLICY" == host-supported-performance-first ]] ||
    fail "4C/8T selector did not use the host gate: $PLATFORM_SELECTION_POLICY"
[[ "$CPU_PROFILE" == i7-4820k && "$CPU_CORES" == 4 &&
   "$CPU_VCPUS" == 8 && "$MEM_SPEED" == 1866 &&
   "$MEM_TOTAL_MB" == 8192 ]] ||
    fail "4C/8T selector escaped its preferred reviewed tier: $PLATFORM"

six_spec_conf=$(create_one only-4930 8 --cpu-spec 6c12t --memory-size 8G)
# shellcheck source=/dev/null
source "$six_spec_conf"
[[ "$PLATFORM_SELECTION_POLICY" == host-supported-performance-first ]] ||
    fail "6C/12T selector did not use the host gate: $PLATFORM_SELECTION_POLICY"
[[ "$CPU_PROFILE" == i7-4930k && "$CPU_CORES" == 6 &&
   "$CPU_VCPUS" == 12 && "$MEM_SPEED" == 1866 &&
   "$MEM_TOTAL_MB" == 8192 ]] ||
    fail "6C/12T selector failed to stay inside its topology: $PLATFORM"

no_new_root="$tmp_dir/no-new"
mkdir -p "$no_new_root/images" "$no_new_root/vms"
if FAKE_CPU_MODE=no-new QEMU_BIN="$fake_qemu" \
        IMAGE_ROOT="$no_new_root/images" VM_ROOT="$no_new_root/vms" \
        VGPU_HOST_CONFIG="$host_config" \
        "$create_vm" 3 --ssd-profile samsung-850-pro-512gb \
        --gpu-profile gtx1050_2gb --monitor-profile dell-p2419h \
        >"$tmp_dir/no-new.out" 2>"$tmp_dir/no-new.err"; then
    fail 'creation unexpectedly fell back after all active CPUs failed'
fi
[[ ! -f "$no_new_root/vms/3/vm.conf" ]] ||
    fail 'failed active-CPU probe published a legacy vm.conf'
grep -Fq '拒绝降级到旧慢平台' "$tmp_dir/no-new.err" ||
    fail 'conclusive active-CPU failure did not explain the fail-closed policy'

echo 'PASS: default creation is performance-first and never silently falls back from the active X79 pool'
