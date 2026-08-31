#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
audit="$repo_root/deploy/scripts/check-hardware-pool.sh"
export G11_QEMU_DATA_DIR="$repo_root/pc-bios"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Preserve the real probe's two-stage enforce=on/off behavior so the audit can
# distinguish an active CPU from a model that runs only after feature masking.
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
    active-incompatible)
        if [[ "$cpu_spec" == *,enforce=on &&
              ( "$model" == Core-i7-3820 || "$model" == Core-i7-3930K ||
                "$model" == Core-i7-4820K || "$model" == Core-i7-4930K ||
                "$model" == Core-i7-4960X ) ]]; then
            echo "qemu-system-x86_64: Host doesn't support requested features" >&2
            exit 1
        fi
        ;;
    fastest-only)
        if [[ "$cpu_spec" == *,enforce=on && "$model" != Core-i7-4820K ]]; then
            echo "qemu-system-x86_64: Host doesn't support requested features" >&2
            exit 1
        fi
        ;;
    six-core-only)
        if [[ "$cpu_spec" == *,enforce=on && "$model" != Core-i7-4930K ]]; then
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

output=$("$audit" --qemu "$tmp_dir/qemu-system-x86_64" --machine-readable)

grep -Fx -- \
    'summary cpu=13 board=16 chipset_presentation=5 memory=45 combination=524 new_default=276 explicit_new=158 archived=87 legacy=3 ssd_512gb=10 optical=1 gpu_catalog=25 gpu_1gb=12 gpu_2gb=13 monitor_catalog=35 monitor_new=28' \
    <<<"$output" >/dev/null || fail 'hardware-pool summary/count contract changed'
grep -Fx -- \
    'brands board=5 memory=6 ssd=5 gpu_board=9 keyboard=3 relative_mouse=3 monitor_catalog=11 monitor_new=8' \
    <<<"$output" >/dev/null || fail 'active hardware brand-diversity contract changed'
grep -Fx -- \
    'fixed_exceptions cpu=Intel-household-mainstream-plus-X79 nic=Intel-e1000e audio=Intel-HDA absolute_pointer=QEMU-generic tpm=swtpm install_media=generic-transient monitor=35-model-catalog' \
    <<<"$output" >/dev/null || fail 'fixed-architecture exception contract changed'
grep -Fx -- \
    'chipset_presentations H81=8086:8C5C:04 H97=8086:8CC6:00 B150=8086:A148:31 B360=8086:A308:10 X79=8086:1D41:06 coverage=all-524-platforms' \
    <<<"$output" >/dev/null || fail 'chipset presentation contract changed'
grep -Fx -- \
    'cpu_host_bridge_presentations SandyBridge-E=8086:3C00:07 IvyBridge-E=8086:0E00:04 coverage=all-260-active-X79-platforms fallback=mainstream-P35' \
    <<<"$output" >/dev/null || fail 'CPU host bridge presentation contract changed'
grep -Fx -- \
    'selection new_ready=276 explicit_ready=158 archived_existing=87 legacy_existing_ready=3 result=new-ready' \
    <<<"$output" >/dev/null || fail 'normal host selection audit changed'

[[ $(grep -c '^cpu_profile=' <<<"$output") == 13 ]] || \
    fail 'CPU audit row count changed'
[[ $(grep -c '^profile=' <<<"$output") == 524 ]] || \
    fail 'platform audit row count changed'

for expected in \
    '^cpu_profile=i7-3820 qemu_model=Core-i7-3820 topology=4C/8T host_class=supported create_scope=new result=ready ' \
    '^cpu_profile=i7-3930k qemu_model=Core-i7-3930K topology=6C/12T host_class=supported create_scope=new result=ready ' \
    '^cpu_profile=i7-4820k qemu_model=Core-i7-4820K topology=4C/8T host_class=supported create_scope=new result=ready ' \
    '^cpu_profile=i7-4930k qemu_model=Core-i7-4930K topology=6C/12T host_class=supported create_scope=new result=ready ' \
    '^cpu_profile=i7-4960x qemu_model=Core-i7-4960X topology=6C/12T host_class=supported create_scope=new result=ready ' \
    '^profile=i7-4820k-p9x79-elpida-12g .*memory_mib=12288 create_policy=new host_class=supported result=new-vm-allowed .*memory_modules=4096,4096,4096 memory_channel=triple-channel$' \
    '^profile=i7-4820k-p9x79-micron-16g .*memory_mib=16384 create_policy=new host_class=supported result=new-vm-allowed .*memory_modules=4096,4096,4096,4096 memory_channel=quad-channel$' \
    '^profile=i7-3820-p9x79-kingston-8g .*memory_mib=8192 create_policy=new host_class=supported result=new-vm-allowed .*memory_modules=4096,4096 memory_channel=dual-channel$' \
    '^profile=i7-4930k-p9x79-samsung-4g .*memory_mib=4096 create_policy=new host_class=supported result=new-vm-allowed .*memory_modules=2048,2048 memory_channel=dual-channel$' \
    '^profile=i7-4930k-x79-up4-elpida-12g .*memory_mib=12288 create_policy=new host_class=supported result=new-vm-allowed .*memory_modules=4096,4096,4096 memory_channel=triple-channel$' \
    '^profile=i7-4930k-x79-extreme4-hynix-16g .*memory_mib=16384 create_policy=new host_class=supported result=new-vm-allowed .*memory_modules=4096,4096,4096,4096 memory_channel=quad-channel$' \
    '^profile=g3220-h81m-k-4g .*create_policy=new .*result=new-vm-allowed ' \
    '^profile=i5-4590 .*create_policy=legacy-compatibility .*result=legacy-only '; do
    grep -E -- "$expected" <<<"$output" >/dev/null || \
        fail "missing audit row: $expected"
done

# One supported high-frequency CPU exposes its complete 56-row X79 matrix.
fastest_output=$(G11_FAKE_MODE=fastest-only \
    "$audit" --qemu "$tmp_dir/qemu-system-x86_64" --machine-readable)
grep -Fx -- \
    'selection new_ready=56 explicit_ready=0 archived_existing=87 legacy_existing_ready=3 result=new-ready' \
    <<<"$fastest_output" >/dev/null || \
    fail 'i7-4820K-only host did not keep the performance tier available'

# A host that can realize only the 6C/12T model still sees its entire normal
# multi-board/multi-memory pool.
six_core_output=$(G11_FAKE_MODE=six-core-only \
    "$audit" --qemu "$tmp_dir/qemu-system-x86_64" --machine-readable)
grep -Fx -- \
    'selection new_ready=54 explicit_ready=0 archived_existing=87 legacy_existing_ready=3 result=new-ready' \
    <<<"$six_core_output" >/dev/null || \
    fail 'i7-4930K-only host did not expose the normal 6C/12T pool'

# If every X79 model is incompatible, the restored mainstream pool remains a
# valid normal new-VM fallback instead of disappearing with the extension.
incompatible_output=$(G11_FAKE_MODE=active-incompatible \
    "$audit" --qemu "$tmp_dir/qemu-system-x86_64" --machine-readable)
grep -Fx -- \
    'selection new_ready=16 explicit_ready=158 archived_existing=87 legacy_existing_ready=3 result=new-ready' \
    <<<"$incompatible_output" >/dev/null || \
    fail 'restored mainstream fallback result was not reported'

if blocked_output=$(G11_FAKE_MODE=blocked \
        "$audit" --qemu "$tmp_dir/qemu-system-x86_64" \
        --machine-readable 2>&1); then
    fail 'audit accepted a host with no realizable CPU model'
fi
grep -F -- \
    'selection new_ready=0 explicit_ready=0 archived_existing=87 legacy_existing_ready=0 result=blocked' \
    <<<"$blocked_output" >/dev/null || fail 'blocked selection was not reported'

echo 'PASS: G-11 audit exposes the restored mainstream pool and X79 extension'
