#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
create_vm="$repo_root/deploy/scripts/create-vm.sh"
create_home_vm="$repo_root/deploy/scripts/create-home-vm.sh"
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

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] ||
        fail "$label: expected '$expected', got '$actual'"
}

[[ -x "$create_home_vm" ]] || fail 'foolproof home-pool wrapper is missing'
hardware_profile_validate_catalog || fail 'hardware catalog validation failed'

for cpu in i7-3820 i7-3930k i7-4820k i7-4930k i7-4960x; do
    case "$cpu" in
        i7-3820|i7-4820k) expected_cores=4; expected_vcpus=8 ;;
        *) expected_cores=6; expected_vcpus=12 ;;
    esac
    for board in asus-p9x79 gigabyte-x79-up4 asrock-x79-extreme4; do
        for capacity in 4096 8192 12288 16384; do
            mapfile -t candidates < <(
                hardware_profile_component_candidates \
                    "$cpu" "$board" '' "$capacity" 0
            )
            declare -A brands=()
            saw_preferred_speed=0
            for platform in "${candidates[@]}"; do
                assert_eq new "$(hardware_profile_lifecycle_class "$platform")" \
                    "$platform lifecycle"
                hardware_profile_load "$platform"
                brands["$MEM_BRAND"]=1
                assert_eq "$expected_cores" "$CPU_CORES" "$platform core count"
                assert_eq "$expected_vcpus" "$CPU_VCPUS" "$platform thread count"
                assert_eq "$capacity" "$MEM_TOTAL_MB" "$platform capacity"
                if [[ "$cpu" == i7-3820 || "$cpu" == i7-3930k ||
                      "$board" == asrock-x79-extreme4 ]]; then
                    assert_eq 1600 "$MEM_SPEED" "$platform official speed ceiling"
                    saw_preferred_speed=1
                elif [[ "$MEM_SPEED" == 1866 ]]; then
                    saw_preferred_speed=1
                fi
            done
            expected_brand_count=4
            if [[ "$cpu" != i7-3820 && "$cpu" != i7-3930k &&
                  "$board" != asrock-x79-extreme4 && "$capacity" != 4096 ]]; then
                expected_brand_count=5
            fi
            assert_eq "$expected_brand_count" "${#brands[@]}" \
                "$cpu/$board/${capacity}MiB memory brand count"
            assert_eq 1 "$saw_preferred_speed" \
                "$cpu/$board/${capacity}MiB preferred memory speed"
            for required_brand in Samsung Micron Kingston 'SK hynix'; do
                [[ -v "brands[$required_brand]" ]] ||
                    fail "$board/${capacity}MiB lacks $required_brand"
            done
            if [[ "$expected_brand_count" == 5 ]]; then
                [[ -v 'brands[Elpida]' ]] ||
                    fail "$board/${capacity}MiB lacks Elpida"
            fi
            unset brands
        done
    done
done

declare -A ssd_brands=()
for row in "${SSD_PROFILES[@]}"; do
    IFS='|' read -r _ brand _ <<<"$row"
    ssd_brands["$brand"]=1
done
assert_eq 5 "${#ssd_brands[@]}" 'unified SSD brand count'
for required_brand in Samsung Crucial Kingston Intel 'Western Digital'; do
    [[ -v "ssd_brands[$required_brand]" ]] ||
        fail "SSD pool lacks $required_brand"
done

create_exact() {
    local id=$1 cpu=$2 board=$3 memory=$4 ssd=$5 expected_board=$6
    local expected_memory_brand=$7 expected_speed=$8 expected_ssd_brand=$9
    local expected_cores=${10} expected_vcpus=${11}
    local image_root="$tmp_dir/images-$id" vm_root="$tmp_dir/vms-$id"

    mkdir -p "$image_root" "$vm_root"
    env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$image_root" VM_ROOT="$vm_root" \
        VGPU_HOST_CONFIG="$host_config" \
        "$create_vm" "$id" \
        --cpu-profile "$cpu" \
        --board-profile "$board" \
        --memory-profile "$memory" \
        --ssd-profile "$ssd" \
        --gpu-profile gtx1050_2gb \
        --monitor-profile dell-p2419h >/dev/null

    # shellcheck source=/dev/null
    source "$vm_root/$id/vm.conf"
    assert_eq "$cpu" "$CPU_PROFILE" "VM $id CPU profile"
    assert_eq "$expected_cores" "$CPU_CORES" "VM $id core count"
    assert_eq "$expected_vcpus" "$CPU_VCPUS" "VM $id thread count"
    assert_eq "$expected_board" "$BOARD_MODEL" "VM $id board"
    assert_eq "$expected_memory_brand" "$MEM_BRAND" "VM $id memory brand"
    assert_eq "$expected_speed" "$MEM_SPEED" "VM $id memory speed"
    assert_eq "$expected_ssd_brand" "$SSD_BRAND" "VM $id SSD brand"
    assert_eq new "$(hardware_profile_lifecycle_class "$PLATFORM")" \
        "VM $id lifecycle"
}

create_exact 101 i7-3820 asus-p9x79 samsung-m378b5273dh0-2x4 \
    samsung-840-pro-512gb P9X79 Samsung 1600 Samsung 4 8
create_exact 102 i7-3930k gigabyte-x79-up4 micron-mt8jtf51264az-2x4 \
    crucial-mx100-512gb GA-X79-UP4 Micron 1600 Crucial 6 12
create_exact 103 i7-4820k asrock-x79-extreme4 hynix-hmt351u6cfr8c-4x4 \
    wd-pc-sa530-512gb 'X79 Extreme4' 'SK hynix' 1600 'Western Digital' 4 8
create_exact 104 i7-4930k asus-p9x79 samsung-m378b5773dh0-1866-2x2 \
    samsung-840-pro-512gb P9X79 Samsung 1866 Samsung 6 12
create_exact 105 i7-4960x gigabyte-x79-up4 elpida-ebj40ug8bfw0-3x4 \
    crucial-mx100-512gb GA-X79-UP4 Elpida 1866 Crucial 6 12

wrapper_image_root="$tmp_dir/images-wrapper"
wrapper_vm_root="$tmp_dir/vms-wrapper"
mkdir -p "$wrapper_image_root" "$wrapper_vm_root"
env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
    IMAGE_ROOT="$wrapper_image_root" VM_ROOT="$wrapper_vm_root" \
    VGPU_HOST_CONFIG="$host_config" QEMU_BIN=/bin/false \
    "$create_home_vm" 106 --spec 6c12t \
    --ssd-profile samsung-840-pro-512gb \
    --gpu-profile gtx1050_2gb --monitor-profile dell-p2419h \
    >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"
# shellcheck source=/dev/null
source "$wrapper_vm_root/106/vm.conf"
assert_eq i7-4960x "$CPU_PROFILE" 'wrapper preferred 6C/12T CPU'
assert_eq 6 "$CPU_CORES" 'wrapper core count'
assert_eq 12 "$CPU_VCPUS" 'wrapper thread count'
assert_eq 8192 "$MEM_TOTAL_MB" 'wrapper default memory capacity'
assert_eq 1866 "$MEM_SPEED" 'wrapper preferred memory speed'

if "$create_home_vm" 107 --spec 4c8t --cpu-profile i7-4960x \
        >"$tmp_dir/wrapper-mismatch.out" 2>"$tmp_dir/wrapper-mismatch.err"; then
    fail 'wrapper accepted a CPU outside the requested topology'
fi
grep -Fq '不属于 4c8t 家用池' "$tmp_dir/wrapper-mismatch.err" ||
    fail 'wrapper topology mismatch did not explain the refusal'

echo 'PASS: unified home pool exposes five 4C/8T or 6C/12T CPUs, three board brands, four-to-five memory brands, and five SSD brands'
