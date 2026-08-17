#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
audit="$repo_root/deploy/scripts/check-hardware-pool.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat >"$tmp_dir/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
    echo 'QEMU emulator version 11.0.2 (G-11 pool fake)'
    exit 0
fi
cpu_spec=
previous=
for argument in "$@"; do
    if [[ "$previous" == -cpu ]]; then cpu_spec=$argument; break; fi
    previous=$argument
done
model=${cpu_spec%%,*}
case "${G11_FAKE_MODE:-mixed}" in
    mixed)
        if [[ "$cpu_spec" == *,enforce=on &&
              ( "$model" == Core-i5-6500 || "$model" == Core-i3-8100 ) ]]; then
            echo "qemu-system-x86_64: Host doesn't support requested features" >&2
            exit 1
        fi
        ;;
    fallback)
        if [[ "$cpu_spec" == *,enforce=on ]]; then
            echo "qemu-system-x86_64: Host doesn't support requested features" >&2
            exit 1
        fi
        ;;
    i7-only)
        if [[ "$cpu_spec" == *,enforce=on && "$model" != Core-i7-4790 ]]; then
            echo "qemu-system-x86_64: Host doesn't support requested features" >&2
            exit 1
        fi
        ;;
    blocked)
        echo "qemu-system-x86_64: unknown CPU model '$model'" >&2
        exit 1
        ;;
    *) exit 99 ;;
esac
echo '{"QMP":{"version":{"qemu":{"major":11,"minor":0,"micro":2}}}}'
echo '{"return":{}}'
EOF
chmod +x "$tmp_dir/qemu-system-x86_64"

output=$(
    "$audit" --qemu "$tmp_dir/qemu-system-x86_64" --machine-readable
)

grep -Fx -- \
    'summary cpu=8 board=7 memory=17 combination=28 new_default=24 explicit_new=1 legacy=3 ssd_512gb=9 gpu_2gb=3 monitor_catalog=35 monitor_new=28' \
    <<<"$output" >/dev/null || fail 'hardware-pool summary/count contract changed'
grep -Fx -- \
    'brands board=3 memory=4 ssd=5 gpu_board=3 keyboard=3 relative_mouse=3 monitor_catalog=11 monitor_new=8' \
    <<<"$output" >/dev/null || fail 'hardware brand-diversity contract changed'
grep -Fx -- \
    'serial_policy board=vendor-format memory=jedec-4byte ssd=model-strict monitor=profile-aware gpu=not-exposed keyboard=none relative_mouse=none absolute_pointer=none nic=mac install_odd=none' \
    <<<"$output" >/dev/null || fail 'hardware serial-exposure contract changed'
grep -Fx -- \
    'fixed_exceptions cpu=Intel-H81-platform nic=Intel-e1000e audio=Intel-HDA absolute_pointer=QEMU-generic tpm=swtpm install_odd=generic-transient monitor=35-model-catalog' \
    <<<"$output" >/dev/null || fail 'fixed-architecture exception contract changed'
grep -Fx -- \
    'architecture_boundaries platform=q35-ICH9-AHCI xhci=qemu-xhci nvme=QEMU-nvme rescue_display=std-vga legacy_transport=ivshmem' \
    <<<"$output" >/dev/null || fail 'implementation/compatibility boundary contract changed'
grep -Fx -- 'selection new_ready=24 explicit_ready=1 fallback_ready=3 result=new-ready' \
    <<<"$output" >/dev/null || fail 'normal host selection audit changed'

assert_row_count() {
    local prefix=$1 expected=$2 actual
    actual=$(grep -c "^${prefix}" <<<"$output")
    [[ "$actual" == "$expected" ]] || \
        fail "$prefix row count: expected $expected, got $actual"
}

assert_row_count cpu_profile= 8
assert_row_count profile= 28
grep -E '^profile=g3220-h81m-c-6g .*memory_modules=4096,2048 memory_channel=flex$' \
    <<<"$output" >/dev/null || fail 'audit flattened the 4+2 GiB Flex layout'
grep -E '^profile=g3220-h81m-k-4g .*memory_modules=2048,2048 memory_channel=dual-channel$' \
    <<<"$output" >/dev/null || fail 'audit lost the 2x2 GiB dual-channel layout'

for expected in \
    'cpu_profile=g3220 qemu_model=Intel-Pentium-G3220 topology=2C/2T host_class=supported create_scope=new result=ready' \
    'cpu_profile=i3-4130 qemu_model=Core-i3-4130 topology=2C/4T host_class=supported create_scope=new result=ready' \
    'cpu_profile=i5-4460 qemu_model=Core-i5-4460 topology=4C/4T host_class=supported create_scope=new result=ready' \
    'cpu_profile=i5-4570 qemu_model=Core-i5-4570 topology=4C/4T host_class=supported create_scope=new result=ready' \
    'cpu_profile=i5-4590 qemu_model=Core-i5-4590 topology=4C/4T host_class=supported create_scope=new result=ready' \
    'cpu_profile=i7-4790 qemu_model=Core-i7-4790 topology=4C/8T host_class=supported create_scope=new result=ready' \
    'cpu_profile=i5-6500 qemu_model=Core-i5-6500 topology=4C/4T host_class=compatibility create_scope=legacy-only result=not-default' \
    'cpu_profile=i3-8100 qemu_model=Core-i3-8100 topology=4C/4T host_class=compatibility create_scope=legacy-only result=not-default' \
    'profile=g3220-h81m-k-4g cpu_profile=g3220 board_profile=asus-h81m-k memory_profile=kvr13n9s6-2x2 cpu=Intel-Pentium-G3220 topology=2C/2T memory_mib=4096 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=g3220-h81m-c-6g cpu_profile=g3220 board_profile=asus-h81m-c memory_profile=kvr13n9-flex-4plus2 cpu=Intel-Pentium-G3220 topology=2C/2T memory_mib=6144 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=g3220-h81m-s1-8g cpu_profile=g3220 board_profile=gigabyte-h81m-s1 memory_profile=kvr13n9s8-2x4 cpu=Intel-Pentium-G3220 topology=2C/2T memory_mib=8192 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i3-4130-h81m-c-4g cpu_profile=i3-4130 board_profile=asus-h81m-c memory_profile=kvr16n11s6-2x2 cpu=Core-i3-4130 topology=2C/4T memory_mib=4096 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i3-4130-h81m-s1-6g cpu_profile=i3-4130 board_profile=gigabyte-h81m-s1 memory_profile=kvr16n11-flex-4plus2 cpu=Core-i3-4130 topology=2C/4T memory_mib=6144 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i3-4130-h81m-p33-8g cpu_profile=i3-4130 board_profile=msi-h81m-p33 memory_profile=kvr16n11s8-2x4 cpu=Core-i3-4130 topology=2C/4T memory_mib=8192 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i5-4460-h81m-s1-4g cpu_profile=i5-4460 board_profile=gigabyte-h81m-s1 memory_profile=kvr16n11s6-2x2 cpu=Core-i5-4460 topology=4C/4T memory_mib=4096 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i5-4460-h81m-p33-6g cpu_profile=i5-4460 board_profile=msi-h81m-p33 memory_profile=kvr16n11-flex-4plus2 cpu=Core-i5-4460 topology=4C/4T memory_mib=6144 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i5-4460-h81m-k-8g cpu_profile=i5-4460 board_profile=asus-h81m-k memory_profile=kvr16n11s8-2x4 cpu=Core-i5-4460 topology=4C/4T memory_mib=8192 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i5-4570-h81m-p33-4g cpu_profile=i5-4570 board_profile=msi-h81m-p33 memory_profile=kvr16n11s6-2x2 cpu=Core-i5-4570 topology=4C/4T memory_mib=4096 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i5-4570-h81m-k-6g cpu_profile=i5-4570 board_profile=asus-h81m-k memory_profile=kvr16n11-flex-4plus2 cpu=Core-i5-4570 topology=4C/4T memory_mib=6144 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i5-4570-h81m-c-8g cpu_profile=i5-4570 board_profile=asus-h81m-c memory_profile=kvr16n11s8-2x4 cpu=Core-i5-4570 topology=4C/4T memory_mib=8192 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i5-4590-h81m-k-4g cpu_profile=i5-4590 board_profile=asus-h81m-k memory_profile=kvr16n11s6-2x2 cpu=Core-i5-4590 topology=4C/4T memory_mib=4096 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i5-4590-h81m-c-6g cpu_profile=i5-4590 board_profile=asus-h81m-c memory_profile=kvr16n11-flex-4plus2 cpu=Core-i5-4590 topology=4C/4T memory_mib=6144 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i5-4590-h81m-s1-8g cpu_profile=i5-4590 board_profile=gigabyte-h81m-s1 memory_profile=kvr16n11s8-2x4 cpu=Core-i5-4590 topology=4C/4T memory_mib=8192 create_policy=new host_class=supported result=new-vm-allowed' \
    'profile=i7-4790-h81m-p33-8g cpu_profile=i7-4790 board_profile=msi-h81m-p33 memory_profile=kvr16n11s8-2x4 cpu=Core-i7-4790 topology=4C/8T memory_mib=8192 create_policy=explicit-new host_class=supported result=explicit-vm-allowed' \
    'profile=i5-4590 cpu_profile=i5-4590 board_profile=gigabyte-h97-d3h memory_profile=kvr16n11s8-2x4 cpu=Core-i5-4590 topology=4C/4T memory_mib=8192 create_policy=legacy-compatibility host_class=supported result=legacy-only' \
    'profile=i5-6500 cpu_profile=i5-6500 board_profile=gigabyte-b150m-d3h memory_profile=kvr21n15s8-2x4 cpu=Core-i5-6500 topology=4C/4T memory_mib=8192 create_policy=legacy-compatibility host_class=compatibility result=legacy-only' \
    'profile=i3-8100 cpu_profile=i3-8100 board_profile=asus-prime-b360m-a memory_profile=kvr24n17s8-2x4 cpu=Core-i3-8100 topology=4C/4T memory_mib=8192 create_policy=legacy-compatibility host_class=compatibility result=legacy-only'; do
    grep -F -- "$expected" <<<"$output" >/dev/null || \
        fail "missing audit row: $expected"
done

# When every default CPU has only enforce=off compatibility, creation may
# fall back to a reviewed legacy combination instead of the audit failing.
fallback_output=$(
    G11_FAKE_MODE=fallback \
        "$audit" --qemu "$tmp_dir/qemu-system-x86_64" --machine-readable
)
grep -Fx -- 'selection new_ready=0 explicit_ready=0 fallback_ready=3 result=fallback-ready' \
    <<<"$fallback_output" >/dev/null || \
    fail 'legacy fallback readiness was not reported'

# The reviewed two-slot i7 active platform is tried before any old platform.
i7_output=$(
    G11_FAKE_MODE=i7-only \
        "$audit" --qemu "$tmp_dir/qemu-system-x86_64" --machine-readable
)
grep -Fx -- \
    'selection new_ready=0 explicit_ready=1 fallback_ready=3 result=explicit-new-fallback-ready' \
    <<<"$i7_output" >/dev/null || \
    fail 'explicit i7 active fallback was not preferred over legacy'

# Fail closed only when neither default-new nor legacy fallback can realize.
if blocked_output=$(
    G11_FAKE_MODE=blocked \
        "$audit" --qemu "$tmp_dir/qemu-system-x86_64" --machine-readable \
        2>&1
); then
    fail 'audit accepted a host with neither new nor fallback CPU support'
fi
grep -F -- 'selection new_ready=0 explicit_ready=0 fallback_ready=0 result=blocked' \
    <<<"$blocked_output" >/dev/null || fail 'blocked selection was not reported'

echo 'PASS: G-11 component hardware pool audit exposes exact lifecycle/count/topology contracts'
