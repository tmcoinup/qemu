#!/usr/bin/env bash
# Read-only G-11 hardware-pool and host CPU realization audit.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_dir="$(cd "$here/.." && pwd)"

# shellcheck source=../lib/hardware-profiles.sh
source "$deploy_dir/lib/hardware-profiles.sh"
# shellcheck source=../lib/vgpu-profiles.sh
source "$deploy_dir/lib/vgpu-profiles.sh"
# shellcheck source=../lib/monitor-profiles.sh
source "$deploy_dir/lib/monitor-profiles.sh"
# shellcheck source=../lib/input-profiles.sh
source "$deploy_dir/lib/input-profiles.sh"
# shellcheck source=../lib/cpu-realization.sh
source "$deploy_dir/lib/cpu-realization.sh"

qemu_bin=${QEMU_BIN:-"$deploy_dir/../build/qemu-system-x86_64"}
machine_readable=0

usage() {
    cat <<'EOF'
usage: ./deploy/scripts/check-hardware-pool.sh [--qemu PATH] [--machine-readable]

Read-only checks the complete G-11 catalogs, then asks QEMU/KVM whether each
catalog CPU can be realized on this host.  It never creates a VM, disk, TAP,
mdev or TPM state and does not require sudo.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --qemu)
            (( $# >= 2 )) || { echo "--qemu 缺少路径" >&2; exit 2; }
            qemu_bin=$2
            shift 2
            ;;
        --qemu=*)
            qemu_bin=${1#*=}
            [[ -n "$qemu_bin" ]] || { echo "--qemu 不能是空值" >&2; exit 2; }
            shift
            ;;
        --machine-readable)
            machine_readable=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

hardware_profile_validate_catalog
vgpu_profile_validate_catalog
monitor_profiles_validate
monitor_create_pool_validate
input_profile_validate_catalog

mapfile -t monitor_catalog_keys < <(monitor_profile_keys)
mapfile -t monitor_create_keys < <(monitor_create_pool_keys)

# Brand diversity is meaningful only for replaceable consumer components.
# Controller/transport implementations are reported as explicit exceptions
# below instead of being relabelled with incompatible vendor identities.
declare -A board_brand_seen=() memory_brand_seen=() ssd_brand_seen=()
declare -A gpu_board_brand_seen=() keyboard_brand_seen=() mouse_brand_seen=()
for row in "${BOARD_PROFILES[@]}"; do
    IFS='|' read -r _ brand _ <<<"$row"
    case "$brand" in
        ASUS|'ASUSTeK COMPUTER INC.') brand=ASUS ;;
        Gigabyte|'Gigabyte Technology Co., Ltd.') brand=Gigabyte ;;
        MSI|'Micro-Star International Co., Ltd.') brand=MSI ;;
    esac
    board_brand_seen["$brand"]=1
done
for row in "${MEMORY_PROFILES[@]}"; do
    IFS='|' read -r _ brand _ <<<"$row"
    memory_brand_seen["$brand"]=1
done
for row in "${SSD_PROFILES[@]}"; do
    IFS='|' read -r _ brand _ <<<"$row"
    ssd_brand_seen["$brand"]=1
done
for row in "${VGPU_PROFILE_BOARD_METADATA[@]}"; do
    IFS='|' read -r _ brand _ <<<"$row"
    gpu_board_brand_seen["$brand"]=1
done
for row in "${INPUT_KEYBOARD_ACTIVE_PROFILES[@]}"; do
    IFS='|' read -r _ brand _ <<<"$row"
    keyboard_brand_seen["$brand"]=1
done
for row in "${INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES[@]}"; do
    IFS='|' read -r _ brand _ <<<"$row"
    mouse_brand_seen["$brand"]=1
done
mapfile -t monitor_catalog_brands < <(
    awk -F '|' '!/^#/ && NF {print $6}' "$MONITOR_PROFILE_CATALOG" |
        LC_ALL=C sort -u
)
mapfile -t monitor_create_brands < <(
    awk -F '|' '
        FNR == NR { if ($0 !~ /^#/ && $0 != "") wanted[$1] = 1; next }
        !/^#/ && NF && ($1 in wanted) { print $6 }
    ' "$MONITOR_CREATE_PROFILE_POOL" "$MONITOR_PROFILE_CATALOG" |
        LC_ALL=C sort -u
)

brand_list() {
    local array_name=$1
    local -n values=$array_name
    printf '%s\n' "${!values[@]}" | LC_ALL=C sort | paste -sd, -
}

board_brand_count=${#board_brand_seen[@]}
memory_brand_count=${#memory_brand_seen[@]}
ssd_brand_count=${#ssd_brand_seen[@]}
gpu_board_brand_count=${#gpu_board_brand_seen[@]}
keyboard_brand_count=${#keyboard_brand_seen[@]}
mouse_brand_count=${#mouse_brand_seen[@]}
monitor_catalog_brand_count=${#monitor_catalog_brands[@]}
monitor_create_brand_count=${#monitor_create_brands[@]}

for audited_count in "$board_brand_count" "$memory_brand_count" \
        "$ssd_brand_count" "$gpu_board_brand_count" \
        "$keyboard_brand_count" "$mouse_brand_count"; do
    ((audited_count >= 3 && audited_count <= 5)) || {
        echo "可替换硬件品牌覆盖必须在 3..5，实际为 $audited_count" >&2
        exit 1
    }
done
((monitor_create_brand_count >= 5)) || {
    echo "35 款显示器目录的新建池品牌数不足" >&2
    exit 1
}

new_cpu_profile_count=0
for cpu_row in "${CPU_PROFILES[@]}"; do
    IFS='|' read -r cpu_key _ <<<"$cpu_row"
    mapfile -t cpu_candidates < <(
        hardware_profile_component_candidates "$cpu_key" '' ''
    )
    ((${#cpu_candidates[@]} == 0)) || \
        new_cpu_profile_count=$((new_cpu_profile_count + 1))
done
legacy_only_cpu_profile_count=$((${#CPU_PROFILES[@]} - new_cpu_profile_count))

if (( machine_readable )); then
    printf 'summary cpu=%s board=%s memory=%s combination=%s new_default=%s explicit_new=%s legacy=%s ssd_512gb=%s gpu_2gb=%s monitor_catalog=%s monitor_new=%s\n' \
        "${#CPU_PROFILES[@]}" "${#BOARD_PROFILES[@]}" \
        "${#MEMORY_PROFILES[@]}" "${#HARDWARE_COMBINATIONS[@]}" \
        "${#HARDWARE_NEW_PROFILE_KEYS[@]}" \
        "${#HARDWARE_EXPLICIT_NEW_PROFILE_KEYS[@]}" \
        "${#HARDWARE_LEGACY_COMPAT_PROFILE_KEYS[@]}" \
        "${#SSD_PROFILES[@]}" "${#VGPU_PROFILE_CATALOG[@]}" \
        "${#monitor_catalog_keys[@]}" "${#monitor_create_keys[@]}"
    printf 'brands board=%s memory=%s ssd=%s gpu_board=%s keyboard=%s relative_mouse=%s monitor_catalog=%s monitor_new=%s\n' \
        "$board_brand_count" "$memory_brand_count" "$ssd_brand_count" \
        "$gpu_board_brand_count" "$keyboard_brand_count" \
        "$mouse_brand_count" "$monitor_catalog_brand_count" \
        "$monitor_create_brand_count"
    printf 'serial_policy board=vendor-format memory=jedec-4byte ssd=model-strict monitor=profile-aware gpu=not-exposed keyboard=none relative_mouse=none absolute_pointer=none nic=mac install_odd=none\n'
    printf 'fixed_exceptions cpu=Intel-H81-platform nic=Intel-e1000e audio=Intel-HDA absolute_pointer=QEMU-generic tpm=swtpm install_odd=generic-transient monitor=35-model-catalog\n'
    printf 'architecture_boundaries platform=q35-ICH9-AHCI xhci=qemu-xhci nvme=QEMU-nvme rescue_display=std-vga legacy_transport=ivshmem\n'
else
    printf 'G-11 硬件池（QEMU=%s）\n' "$qemu_bin"
    printf '  CPU: %s（新建可用 %s 款；旧代兼容 %s 款）\n' \
        "${#CPU_PROFILES[@]}" "$new_cpu_profile_count" \
        "$legacy_only_cpu_profile_count"
    printf '  主板: %s；内存套装: %s；合法整机组合: %s（默认 %s / 显式新建 %s / 旧兼容 %s）\n' \
        "${#BOARD_PROFILES[@]}" "${#MEMORY_PROFILES[@]}" \
        "${#HARDWARE_COMBINATIONS[@]}" "${#HARDWARE_NEW_PROFILE_KEYS[@]}" \
        "${#HARDWARE_EXPLICIT_NEW_PROFILE_KEYS[@]}" \
        "${#HARDWARE_LEGACY_COMPAT_PROFILE_KEYS[@]}"
    printf '  SSD: %s 款精确 512GB；GPU: %s 款 2GB；显示器: %s catalog / %s 新建池\n\n' \
        "${#SSD_PROFILES[@]}" "${#VGPU_PROFILE_CATALOG[@]}" \
        "${#monitor_catalog_keys[@]}" "${#monitor_create_keys[@]}"
    printf '  品牌（可替换件）: 主板 %s [%s]；内存 %s [%s]；SSD %s [%s]\n' \
        "$board_brand_count" "$(brand_list board_brand_seen)" \
        "$memory_brand_count" "$(brand_list memory_brand_seen)" \
        "$ssd_brand_count" "$(brand_list ssd_brand_seen)"
    printf '                       GPU 板卡 %s [%s]；键盘 %s [%s]；可选相对鼠标 %s [%s]\n' \
        "$gpu_board_brand_count" "$(brand_list gpu_board_brand_seen)" \
        "$keyboard_brand_count" "$(brand_list keyboard_brand_seen)" \
        "$mouse_brand_count" "$(brand_list mouse_brand_seen)"
    printf '  显示器例外: 新建 %s 品牌 / 完整 %s 品牌，保留用户要求的 35 款 FHD 目录。\n' \
        "$monitor_create_brand_count" "$monitor_catalog_brand_count"
    printf '  架构绑定例外: Intel CPU/H81、Intel e1000e、Intel HDA、swtpm、QEMU 通用绝对指针、QEMU 通用临时安装光驱。\n'
    printf '  实现/兼容边界: q35/ICH9/ICH9-AHCI、qemu-xhci、QEMU nvme controller、救援 std-vga、legacy ivshmem。\n'
    printf '  序列策略: 主板/内存/SSD/显示器按各自合同；GPU/HID/临时光驱不暴露；NIC 用唯一 MAC。\n\n'
    printf '%-14s %-24s %-10s %-13s %-13s %s\n' \
        CPU_PROFILE QEMU_MODEL TOPOLOGY HOST_CLASS CREATE_SCOPE RESULT
fi

new_supported=0
explicit_supported=0
legacy_fallback_ready=0
probe_failed=0
declare -A cpu_host_class=() cpu_host_reason=()
for row in "${CPU_PROFILES[@]}"; do
    IFS='|' read -r cpu_key cpu _brand _tsc _part _base _max _family \
        _upgrade _chars cores threads _rest <<<"$row"
    if g11_cpu_capability_probe "$qemu_bin" "$cpu"; then
        host_class=$G11_CPU_CAPABILITY_CLASS
        reason=$G11_CPU_CAPABILITY_REASON
    else
        host_class=$G11_CPU_CAPABILITY_CLASS
        reason=$G11_CPU_CAPABILITY_REASON
        probe_failed=1
    fi
    cpu_host_class[$cpu_key]=$host_class
    cpu_host_reason[$cpu_key]=$reason

    create_scope=legacy-only
    mapfile -t cpu_candidates < <(
        hardware_profile_component_candidates "$cpu_key" '' ''
    )
    if ((${#cpu_candidates[@]})); then
        create_scope=new
    fi
    result=not-default
    [[ "$create_scope" != new ]] || result=$([[ "$host_class" == supported ]] && printf ready || printf blocked)

    if (( machine_readable )); then
        printf 'cpu_profile=%s qemu_model=%s topology=%sC/%sT host_class=%s create_scope=%s result=%s reason=%s\n' \
            "$cpu_key" "$cpu" "$cores" "$((cores * threads))" \
            "$host_class" "$create_scope" "$result" "$reason"
    else
        printf '%-14s %-24s %-10s %-13s %-13s %s\n' \
            "$cpu_key" "$cpu" "${cores}C/$((cores * threads))T" \
            "$host_class" "$create_scope" "$result"
    fi
done

if (( ! machine_readable )); then
    printf '\n%-29s %-24s %-34s %-30s %-20s %s\n' \
        PROFILE CPU BOARD MEMORY CREATE_POLICY RESULT
fi

for row in "${HARDWARE_COMBINATIONS[@]}"; do
    IFS='|' read -r profile cpu_key board_key memory_key lifecycle <<<"$row"
    hardware_profile_load "$profile"
    cpu=$CPU_MODEL
    brand=$BOARD_BRAND
    board=$BOARD_MODEL
    host_class=${cpu_host_class[$cpu_key]}
    reason=${cpu_host_reason[$cpu_key]}
    memory_layout="${MEM_MODULE_MB_LIST//,/+}MiB/${MEM_CHANNEL_MODE}"

    result=legacy-only
    if [[ "$lifecycle" == new && "$host_class" == supported ]]; then
        result=new-vm-allowed
        new_supported=$((new_supported + 1))
    elif [[ "$lifecycle" == new ]]; then
        result=new-vm-blocked
    elif [[ "$lifecycle" == explicit-new && "$host_class" == supported ]]; then
        result=explicit-vm-allowed
        explicit_supported=$((explicit_supported + 1))
    elif [[ "$lifecycle" == explicit-new ]]; then
        result=explicit-vm-blocked
    fi
    if [[ "$lifecycle" == legacy-compatibility &&
          ( "$host_class" == supported || "$host_class" == compatibility ) ]]; then
        legacy_fallback_ready=$((legacy_fallback_ready + 1))
    fi

    if (( machine_readable )); then
        printf 'profile=%s cpu_profile=%s board_profile=%s memory_profile=%s cpu=%s topology=%sC/%sT memory_mib=%s create_policy=%s host_class=%s result=%s reason=%s memory_modules=%s memory_channel=%s\n' \
            "$profile" "$cpu_key" "$board_key" "$memory_key" "$cpu" \
            "$CPU_CORES" "$CPU_VCPUS" "$MEM_TOTAL_MB" "$lifecycle" \
            "$host_class" "$result" "$reason" "$MEM_MODULE_MB_LIST" \
            "$MEM_CHANNEL_MODE"
    else
        printf '%-29s %-24s %-34s %-30s %-20s %s\n' \
            "$profile" "${cpu} ${CPU_CORES}C/${CPU_VCPUS}T" \
            "$brand $board" "$memory_layout" \
            "$lifecycle" "$result"
    fi
done

if (( new_supported > 0 )); then
    selection_result=new-ready
elif (( explicit_supported > 0 )); then
    selection_result=explicit-new-fallback-ready
elif (( legacy_fallback_ready > 0 )); then
    selection_result=fallback-ready
else
    selection_result=blocked
fi

if (( machine_readable )); then
    printf 'selection new_ready=%s explicit_ready=%s fallback_ready=%s result=%s\n' \
        "$new_supported" "$explicit_supported" "$legacy_fallback_ready" \
        "$selection_result"
else
    printf '\n创建选择: new_ready=%s / explicit_ready=%s / fallback_ready=%s / result=%s\n' \
        "$new_supported" "$explicit_supported" "$legacy_fallback_ready" \
        "$selection_result"
fi

if [[ "$selection_result" == blocked ]]; then
    echo "默认新建池和旧平台回退池在本宿主均不可用。" >&2
    exit 1
fi
if [[ "$selection_result" == fallback-ready ]]; then
    echo "六款 active CPU 均未通过 enforce=on；宿主仍有经审核的 legacy fallback。" >&2
elif [[ "$selection_result" == explicit-new-fallback-ready ]]; then
    echo "五款低端默认 CPU 均不可用；两槽 i7 active 平台可先于 legacy 兜底。" >&2
fi
if (( probe_failed )); then
    echo "提示：部分 catalog 平台在本宿主不可用；已有 legacy VM 仍由启动器逐台门禁。" >&2
fi
