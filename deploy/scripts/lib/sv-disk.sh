# shellcheck shell=bash
# 实例磁盘创建与 profile 容量一致性校验。
#
# 单独拆分的原因：磁盘虚拟容量是硬件身份的一部分，既要在 Linux 启动器中复用，
# 也要能由无 KVM、无宿主网络权限的单元测试独立验证。
# ---------------------------------------------------------------------------

_vmate_qcow2_library="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qcow2-performance.sh"
# shellcheck source=qcow2-performance.sh
source "$_vmate_qcow2_library"
unset _vmate_qcow2_library

sv_disk_required_free_bytes() {
    # 同时保留固定余量与文件系统比例：小盘不能低于固定值，大盘不能只剩少量
    # 绝对空间。先除后乘，避免对超大文件系统做百分比计算时溢出 shell 整数。
    local total_bytes="$1"
    local minimum_gib="$2"
    local minimum_percent="$3"
    local gib=$(( 1024 * 1024 * 1024 ))
    local fixed_bytes=$(( minimum_gib * gib ))
    local percentage_bytes
    percentage_bytes=$((
        (total_bytes / 100) * minimum_percent
        + ((total_bytes % 100) * minimum_percent + 99) / 100
    ))

    if (( percentage_bytes > fixed_bytes )); then
        printf '%s\n' "$percentage_bytes"
    else
        printf '%s\n' "$fixed_bytes"
    fi
}

sv_disk_host_headroom_guard() {
    # qcow2 是稀疏文件；guest 写盘时仍会继续向宿主文件系统分配数据和元数据。
    # 宿主空间见底会同时放大 ext4 分配、qcow2 碎片与 SSD 垃圾回收延迟，严重时
    # 还会因 ENOSPC 损坏客体文件系统，因此在 QEMU 启动前做硬门禁。
    local guard="${DISK_GUARD:-1}"
    local force="${DISK_FORCE:-0}"
    local minimum_gib_raw="${DISK_MIN_FREE_GIB:-16}"
    local minimum_percent_raw="${DISK_MIN_FREE_PERCENT:-5}"
    local warning_percent_raw="${DISK_WARN_FREE_PERCENT:-10}"

    case "$guard:$force" in
        0:0|0:1|1:0|1:1) ;;
        *)
            echo "ERROR: DISK_GUARD 与 DISK_FORCE 必须是 0 或 1" >&2
            return 2
            ;;
    esac
    if ! [[ "$minimum_gib_raw" =~ ^[1-9][0-9]*$ \
        && "$minimum_percent_raw" =~ ^[1-9][0-9]*$ \
        && "$warning_percent_raw" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: 磁盘余量阈值必须是正整数" >&2
        return 2
    fi

    local minimum_gib=$(( 10#$minimum_gib_raw ))
    local minimum_percent=$(( 10#$minimum_percent_raw ))
    local warning_percent=$(( 10#$warning_percent_raw ))
    if (( minimum_gib > 1048576 || minimum_percent > 100 \
        || warning_percent > 100 || warning_percent < minimum_percent )); then
        echo "ERROR: 磁盘余量阈值越界，且告警百分比不得低于硬门禁百分比" >&2
        return 2
    fi
    if [[ "$guard" == 0 || "${DRY_RUN:-0}" == 1 ]]; then
        return 0
    fi

    local target="$DISK"
    if [[ ! -e "$target" ]]; then
        target="$(dirname -- "$target")"
    fi
    if [[ ! -e "$target" ]]; then
        echo "ERROR: 无法定位实例盘所在文件系统: $DISK" >&2
        return 1
    fi

    local stat_fields block_size total_blocks available_blocks
    if ! stat_fields=$(stat -f -c '%S %b %a' -- "$target") \
        || ! read -r block_size total_blocks available_blocks <<<"$stat_fields" \
        || ! [[ "$block_size" =~ ^[1-9][0-9]*$ \
            && "$total_blocks" =~ ^[1-9][0-9]*$ \
            && "$available_blocks" =~ ^[0-9]+$ ]]; then
        echo "ERROR: 无法读取实例盘所在文件系统的可用容量: $target" >&2
        return 1
    fi

    local total_bytes=$(( block_size * total_blocks ))
    local available_bytes=$(( block_size * available_blocks ))
    local required_bytes warning_bytes percent_tenths
    required_bytes="$(
        sv_disk_required_free_bytes \
            "$total_bytes" "$minimum_gib" "$minimum_percent"
    )"
    warning_bytes=$((
        (total_bytes / 100) * warning_percent
        + ((total_bytes % 100) * warning_percent + 99) / 100
    ))
    percent_tenths=$(( available_bytes * 1000 / total_bytes ))

    local gib=$(( 1024 * 1024 * 1024 ))
    local available_gib=$(( available_bytes / gib ))
    local required_gib=$(( (required_bytes + gib - 1) / gib ))
    DISK_HOST_FREE_BYTES="$available_bytes"
    DISK_HOST_REQUIRED_FREE_BYTES="$required_bytes"
    export DISK_HOST_FREE_BYTES DISK_HOST_REQUIRED_FREE_BYTES

    if (( available_bytes < required_bytes )); then
        echo ">> 磁盘余量:    ${available_gib} GiB（$((percent_tenths / 10)).$((percent_tenths % 10))%），最低 ${required_gib} GiB" >&2
        if [[ "$force" == 1 ]]; then
            echo ">>   WARN: DISK_FORCE=1，显式越过满盘/ENOSPC 风险" >&2
            return 0
        fi
        echo "ERROR: qcow2 所在文件系统空间不足，拒绝启动 VM" >&2
        echo "       请释放或迁移数据；建议至少保留 ${warning_percent}% 空闲。" >&2
        echo "       仅紧急恢复可用 DISK_FORCE=1 显式越过本次门禁。" >&2
        return 1
    fi

    if (( available_bytes < warning_bytes )); then
        echo ">> WARN: qcow2 文件系统仅余 ${available_gib} GiB（$((percent_tenths / 10)).$((percent_tenths % 10))%）；建议至少保留 ${warning_percent}%" >&2
    fi
}

sv_prepare_disk() {
    # 组件清单已经把型号、固件、PCI ID 和容量绑成一个原子 bundle；这里不允许
    # 用型号字符串猜容量，更不能对历史镜像静默 resize。
    : "${DISK:?缺少 DISK}"
    : "${QEMU_IMG:?缺少 QEMU_IMG}"
    : "${BOOT_STORAGE_SIZE_BYTES:?profile 缺 BOOT_STORAGE_SIZE_BYTES}"
    : "${BOOT_STORAGE_MODEL:?profile 缺 BOOT_STORAGE_MODEL}"

    sv_disk_host_headroom_guard || return $?

    if [[ ! -f "$DISK" ]]; then
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            echo ">> disk:        [DRY_RUN] 跳过创建 $DISK"
        elif [[ -n "${BASE_IMAGE:-}" ]]; then
            if [[ ! -f "$BASE_IMAGE" ]]; then
                echo "ERROR: BASE_IMAGE='$BASE_IMAGE' 不存在" >&2
                return 1
            fi
            echo ">> 从 base 镜像克隆: $BASE_IMAGE"
            echo ">>   -> $DISK (qcow2 增量层)"
            "$QEMU_IMG" create -f qcow2 -F qcow2 -b "$BASE_IMAGE" \
                -o "$VMATE_QCOW2_CREATE_OPTIONS" "$DISK" >/dev/null
        else
            local size_gib
            size_gib=$(( BOOT_STORAGE_SIZE_BYTES / 1024 / 1024 / 1024 ))
            echo ">> creating fresh qcow2 at $DISK"
            echo ">>   model     : $BOOT_STORAGE_MODEL"
            echo ">>   raw bytes : $BOOT_STORAGE_SIZE_BYTES  (~${size_gib} GiB Windows-side)"
            # Extended L2 将 128 KiB cluster 分为 4 KiB subcluster；元数据预分配
            # 则避免运行期首次扩展 L1/L2 带来延迟和文件尾碎片。
            "$QEMU_IMG" create -f qcow2 -o "$VMATE_QCOW2_CREATE_OPTIONS" \
                "$DISK" "$BOOT_STORAGE_SIZE_BYTES"
        fi
    fi

    # qemu-img 的 virtual-size 才是 Windows/Linux guest 看到的块设备容量。每次
    # 启动都校验，覆盖历史磁盘、外部 base image 和 profile 被手工修改的情况。
    if [[ -f "$DISK" ]]; then
        local disk_info_json disk_fields backing_file backing_format
        local disk_format has_external_data allow_legacy_backing expected_pin
        local -a disk_field_array=()
        if ! disk_info_json=$("$QEMU_IMG" info --output=json "$DISK"); then
            echo "ERROR: 无法读取磁盘元数据: $DISK" >&2
            return 1
        fi
        if ! disk_fields=$(python3 -c '
import json
import os
import sys

disk = sys.argv[1]
info = json.load(sys.stdin)
size = info.get("virtual-size")
disk_format = info.get("format")
backing = info.get("full-backing-filename") or info.get("backing-filename") or ""
backing_format = info.get("backing-filename-format") or ""
external = info.get("format-specific", {}).get("data", {}).get("data-file") or ""
if not isinstance(size, int):
    raise ValueError("invalid virtual size")
if not isinstance(backing, str) or "\n" in backing:
    raise ValueError("invalid backing path")
if backing and not os.path.isabs(backing):
    backing = os.path.realpath(os.path.join(os.path.dirname(disk), backing))
print(size)
print(disk_format)
print(backing)
print(backing_format)
print(int(bool(external)))
' "$DISK" <<<"$disk_info_json"); then
            echo "ERROR: qemu-img 返回了无法解析的 JSON: $DISK" >&2
            return 1
        fi
        mapfile -t disk_field_array <<<"$disk_fields"
        DISK_VIRTUAL_SIZE="${disk_field_array[0]:-}"
        disk_format="${disk_field_array[1]:-}"
        backing_file="${disk_field_array[2]:-}"
        backing_format="${disk_field_array[3]:-}"
        has_external_data="${disk_field_array[4]:-}"
        if [[ ! "$DISK_VIRTUAL_SIZE" =~ ^[0-9]+$ ]]; then
            echo "ERROR: qemu-img 未返回有效 virtual-size: $DISK" >&2
            return 1
        fi
        if [[ "$disk_format" != qcow2 ]]; then
            echo "ERROR: 实例 disk 必须是 qcow2，实际格式为 $disk_format: $DISK" >&2
            return 1
        fi
        if [[ "$has_external_data" != 0 ]]; then
            echo "ERROR: 实例 disk 不得依赖 external data file: $DISK" >&2
            return 1
        fi
        if [[ -n "$backing_file" ]]; then
            if [[ "$backing_format" != qcow2 ]]; then
                echo "ERROR: 实例 disk 的 backing 声明格式必须是 qcow2: $DISK" >&2
                return 1
            fi
            allow_legacy_backing=1
            expected_pin="$(realpath -m -- "$(dirname "$DISK")/.base.qcow2")"
            [[ "$backing_file" == "$expected_pin" ]] && allow_legacy_backing=0
            base_image_require_trusted_backing_qcow2_fast \
                "$QEMU_IMG" "$backing_file" "$DISK_VIRTUAL_SIZE" \
                "$allow_legacy_backing" || return 1
        fi
        if [[ "$DISK_VIRTUAL_SIZE" != "$BOOT_STORAGE_SIZE_BYTES" ]]; then
            echo "ERROR: 磁盘虚拟容量与硬件 profile 不一致" >&2
            echo "       disk=$DISK virtual-size=$DISK_VIRTUAL_SIZE" >&2
            echo "       profile.BOOT_STORAGE_SIZE_BYTES=$BOOT_STORAGE_SIZE_BYTES model=$BOOT_STORAGE_MODEL" >&2
            echo "       请换用匹配容量的 base image，或显式重建该实例磁盘。" >&2
            return 1
        fi
        # du 报告宿主真实分配量，只用于运维；不能把它当成 guest 可见容量。
        DISK_HOST_ALLOCATED_BYTES=$(du -B1 "$DISK" | awk 'NR == 1 { print $1 }')
    else
        # DRY_RUN 首次生成不会落盘；实际启动一定会进入上面的严格校验。
        DISK_VIRTUAL_SIZE="DRY_RUN-not-created"
        DISK_HOST_ALLOCATED_BYTES="DRY_RUN-not-created"
    fi
    export DISK_VIRTUAL_SIZE DISK_HOST_ALLOCATED_BYTES
}
