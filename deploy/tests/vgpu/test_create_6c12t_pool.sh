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

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] ||
        fail "$label: expected '$expected', got '$actual'"
}

[[ ! -e "$repo_root/deploy/scripts/create-6c12t-vm.sh" ]] ||
    fail 'standalone 6C/12T wrapper returned; use the unified creation pool'
hardware_profile_validate_catalog || fail 'hardware catalog validation failed'

declare -A expected_brand_counts=(
    [asus-p9x79:4096]=4
    [asus-p9x79:8192]=5
    [asus-p9x79:12288]=5
    [asus-p9x79:16384]=5
    [gigabyte-x79-up4:4096]=4
    [gigabyte-x79-up4:8192]=5
    [gigabyte-x79-up4:12288]=5
    [gigabyte-x79-up4:16384]=5
    [asrock-x79-extreme4:4096]=4
    [asrock-x79-extreme4:8192]=4
    [asrock-x79-extreme4:12288]=4
    [asrock-x79-extreme4:16384]=4
)

for board in asus-p9x79 gigabyte-x79-up4 asrock-x79-extreme4; do
    for capacity in 4096 8192 12288 16384; do
        mapfile -t candidates < <(
            hardware_profile_component_candidates \
                i7-4930k "$board" '' "$capacity" 0
        )
        declare -A brands=()
        for platform in "${candidates[@]}"; do
            assert_eq new "$(hardware_profile_lifecycle_class "$platform")" \
                "$platform lifecycle"
            hardware_profile_load "$platform"
            brands["$MEM_BRAND"]=1
            assert_eq 6 "$CPU_CORES" "$platform core count"
            assert_eq 12 "$CPU_VCPUS" "$platform thread count"
            assert_eq "$capacity" "$MEM_TOTAL_MB" "$platform capacity"
            if [[ "$board" == asrock-x79-extreme4 ]]; then
                assert_eq 1600 "$MEM_SPEED" "$platform honest ASRock speed"
            fi
        done
        assert_eq "${expected_brand_counts[$board:$capacity]}" \
            "${#brands[@]}" "$board/${capacity}MiB memory brand count"
        for required_brand in Samsung Micron Kingston 'SK hynix'; do
            [[ -v "brands[$required_brand]" ]] ||
                fail "$board/${capacity}MiB lacks $required_brand"
        done
        if [[ "$board" != asrock-x79-extreme4 && "$capacity" != 4096 ]]; then
            [[ -v 'brands[Elpida]' ]] ||
                fail "$board/${capacity}MiB lacks Elpida"
        fi
        unset brands
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
    local id=$1 board=$2 memory=$3 ssd=$4 expected_board=$5
    local expected_memory_brand=$6 expected_speed=$7 expected_ssd_brand=$8
    local image_root="$tmp_dir/images-$id" vm_root="$tmp_dir/vms-$id"

    mkdir -p "$image_root" "$vm_root"
    env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$image_root" VM_ROOT="$vm_root" \
        VGPU_HOST_CONFIG="$host_config" \
        "$create_vm" "$id" \
        --cpu-profile i7-4930k \
        --board-profile "$board" \
        --memory-profile "$memory" \
        --ssd-profile "$ssd" \
        --gpu-profile gtx1050_2gb \
        --monitor-profile dell-p2419h >/dev/null

    # shellcheck source=/dev/null
    source "$vm_root/$id/vm.conf"
    assert_eq i7-4930k "$CPU_PROFILE" "VM $id CPU profile"
    assert_eq 6 "$CPU_CORES" "VM $id core count"
    assert_eq 12 "$CPU_VCPUS" "VM $id thread count"
    assert_eq "$expected_board" "$BOARD_MODEL" "VM $id board"
    assert_eq "$expected_memory_brand" "$MEM_BRAND" "VM $id memory brand"
    assert_eq "$expected_speed" "$MEM_SPEED" "VM $id memory speed"
    assert_eq "$expected_ssd_brand" "$SSD_BRAND" "VM $id SSD brand"
    assert_eq new "$(hardware_profile_lifecycle_class "$PLATFORM")" \
        "VM $id lifecycle"
}

create_exact 101 asus-p9x79 samsung-m378b5773dh0-1866-2x2 \
    samsung-840-pro-512gb P9X79 Samsung 1866 Samsung
create_exact 102 gigabyte-x79-up4 elpida-ebj40ug8bfw0-3x4 \
    crucial-mx100-512gb GA-X79-UP4 Elpida 1866 Crucial
create_exact 103 asrock-x79-extreme4 hynix-hmt351u6cfr8c-4x4 \
    wd-pc-sa530-512gb 'X79 Extreme4' 'SK hynix' 1600 'Western Digital'

echo 'PASS: unified create-vm pool exposes i7-4930K with 3 board brands, 4-5 memory brands per capacity, and 5 SSD brands'
