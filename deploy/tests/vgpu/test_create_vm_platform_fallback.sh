#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
create_vm="$repo_root/deploy/scripts/create-vm.sh"
# shellcheck source=../../lib/hardware-profiles.sh
source "$repo_root/deploy/lib/hardware-profiles.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

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
    no-new|i7-only|default-unavailable-i7-supported)
        case "$model" in
            Core-i7-4790)
                if [[ "${FAKE_CPU_MODE}" == i7-only ||
                      "${FAKE_CPU_MODE}" == default-unavailable-i7-supported ]]; then
                    :
                elif [[ "$enforce" == on ]]; then
                    echo "qemu-system-x86_64: Host doesn't support requested features" >&2
                    exit 1
                fi
                ;;
            Intel-Pentium-G3220|Core-i3-4130|Core-i5-4460|Core-i5-4570|Core-i5-4590)
                if [[ "${FAKE_CPU_MODE}" == default-unavailable-i7-supported ]]; then
                    echo 'qemu-system-x86_64: failed to initialize kvm: Permission denied' >&2
                    exit 1
                elif [[ "$enforce" == on ]]; then
                    echo "qemu-system-x86_64: Host doesn't support requested features" >&2
                    exit 1
                fi
                ;;
            Core-i5-6500|Core-i3-8100)
                ;;
            *)
                echo "qemu-system-x86_64: unable to find CPU model '$model'" >&2
                exit 1
                ;;
        esac
        ;;
    *) exit 99 ;;
esac

echo '{"QMP":{"version":{"qemu":{"major":11,"minor":0,"micro":2}}}}'
echo '{"return":{}}'
EOF
chmod +x "$fake_qemu"

create_one() {
    local mode=$1 id=$2 root
    root="$tmp_dir/$mode"
    mkdir -p "$root/images" "$root/vms"
    FAKE_CPU_MODE=$mode QEMU_BIN="$fake_qemu" \
        IMAGE_ROOT="$root/images" VM_ROOT="$root/vms" \
        "$create_vm" "$id" \
        --ssd-profile samsung-850-pro-512gb \
        --gpu-profile gtx1050_2gb \
        --monitor-profile dell-p2419h >/dev/null
    printf '%s\n' "$root/vms/$id/vm.conf"
}

supported_conf=$(create_one supported 1)
# shellcheck source=/dev/null
source "$supported_conf"
[[ "$PLATFORM_SELECTION_POLICY" == host-supported-new ]] ||
    fail "supported host selection reason: $PLATFORM_SELECTION_POLICY"
[[ "$(hardware_profile_lifecycle_class "$PLATFORM")" == new ]] ||
    fail "supported host selected non-new platform: $PLATFORM"
[[ "$MEM_BOARD_SLOTS" == 2 ]] ||
    fail "supported host selected a four-slot default board"

unavailable_conf=$(create_one unavailable 2)
# shellcheck source=/dev/null
source "$unavailable_conf"
[[ "$PLATFORM_SELECTION_POLICY" == probe-unavailable-new-fail-closed ]] ||
    fail "unavailable probe silently changed policy: $PLATFORM_SELECTION_POLICY"
[[ "$(hardware_profile_lifecycle_class "$PLATFORM")" == new ]] ||
    fail "unavailable probe silently selected legacy: $PLATFORM"

i7_conf=$(create_one i7-only 4)
# shellcheck source=/dev/null
source "$i7_conf"
[[ "$PLATFORM_SELECTION_POLICY" == no-supported-default-explicit-new-fallback ]] ||
    fail "i7 was not tried before legacy: $PLATFORM_SELECTION_POLICY"
[[ "$(hardware_profile_lifecycle_class "$PLATFORM")" == explicit-new ]] ||
    fail "i7 last-new fallback selected wrong lifecycle: $PLATFORM"
[[ "$CPU_PROFILE" == i7-4790 && "$MEM_BOARD_SLOTS" == 2 ]] ||
    fail "i7 fallback is not the reviewed two-slot platform"

mixed_probe_conf=$(create_one default-unavailable-i7-supported 5)
# shellcheck source=/dev/null
source "$mixed_probe_conf"
[[ "$PLATFORM_SELECTION_POLICY" == no-supported-default-explicit-new-fallback ]] ||
    fail "default probe uncertainty prevented a conclusive i7 result: $PLATFORM_SELECTION_POLICY"
[[ "$CPU_PROFILE" == i7-4790 ]] ||
    fail "default probe uncertainty selected $CPU_PROFILE instead of the supported i7"

fallback_conf=$(create_one no-new 3)
# shellcheck source=/dev/null
source "$fallback_conf"
[[ "$PLATFORM_SELECTION_POLICY" == no-supported-new-legacy-fallback ]] ||
    fail "conclusive no-new result did not record fallback: $PLATFORM_SELECTION_POLICY"
[[ "$(hardware_profile_lifecycle_class "$PLATFORM")" == legacy-compatibility ]] ||
    fail "conclusive no-new result did not select legacy: $PLATFORM"
[[ "$CPU_REALIZATION_POLICY" == legacy-compatibility ]] ||
    fail "fallback did not retain legacy CPU gate: $CPU_REALIZATION_POLICY"

echo 'PASS: default creation uses old platforms only after every new CPU conclusively fails enforce=on'
