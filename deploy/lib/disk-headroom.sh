#!/usr/bin/env bash
# Host filesystem headroom guard shared by the G-11 launcher and disk creator.
# A sparse qcow2 can keep growing after creation, so its current file size is
# not a safe indication that the host filesystem has enough working space.

disk_headroom_required_free_bytes() {
    local total_bytes=$1 minimum_gib=$2 minimum_percent=$3
    local gib=$((1024 * 1024 * 1024))
    local fixed_bytes=$((minimum_gib * gib))
    local percentage_bytes

    percentage_bytes=$((
        (total_bytes / 100) * minimum_percent
        + ((total_bytes % 100) * minimum_percent + 99) / 100
    ))
    if ((percentage_bytes > fixed_bytes)); then
        printf '%s\n' "$percentage_bytes"
    else
        printf '%s\n' "$fixed_bytes"
    fi
}

disk_headroom_guard() {
    local disk_path=${1:-}
    local guard=${DISK_GUARD:-1}
    local force=${DISK_FORCE:-0}
    local minimum_gib_raw=${DISK_MIN_FREE_GIB:-16}
    local minimum_percent_raw=${DISK_MIN_FREE_PERCENT:-5}
    local warning_percent_raw=${DISK_WARN_FREE_PERCENT:-10}
    local target stat_fields block_size total_blocks available_blocks
    local total_bytes available_bytes required_bytes warning_bytes
    local percent_tenths gib available_gib required_gib

    [[ -n "$disk_path" && "$disk_path" == /* ]] || {
        echo "[disk-guard] 磁盘路径必须是绝对路径: ${disk_path:-<empty>}" >&2
        return 2
    }
    case "$guard:$force" in
        0:0|0:1|1:0|1:1) ;;
        *)
            echo "[disk-guard] DISK_GUARD 与 DISK_FORCE 必须是 0 或 1" >&2
            return 2
            ;;
    esac
    if ! [[ "$minimum_gib_raw" =~ ^[1-9][0-9]*$ &&
            "$minimum_percent_raw" =~ ^[1-9][0-9]*$ &&
            "$warning_percent_raw" =~ ^[1-9][0-9]*$ ]]; then
        echo "[disk-guard] 磁盘余量阈值必须是正整数" >&2
        return 2
    fi

    local minimum_gib=$((10#$minimum_gib_raw))
    local minimum_percent=$((10#$minimum_percent_raw))
    local warning_percent=$((10#$warning_percent_raw))
    if ((minimum_gib > 1048576 || minimum_percent > 100 ||
         warning_percent > 100 || warning_percent < minimum_percent)); then
        echo "[disk-guard] 阈值越界，且告警百分比不得低于硬门禁百分比" >&2
        return 2
    fi
    if [[ "$guard" == 0 || "${DRY_RUN:-0}" == 1 ]]; then
        return 0
    fi

    target=$disk_path
    [[ -e "$target" ]] || target=$(dirname -- "$target")
    if [[ ! -e "$target" ]]; then
        echo "[disk-guard] 无法定位实例盘所在文件系统: $disk_path" >&2
        return 1
    fi
    if ! stat_fields=$(stat -f -c '%S %b %a' -- "$target") ||
            ! read -r block_size total_blocks available_blocks <<<"$stat_fields" ||
            ! [[ "$block_size" =~ ^[1-9][0-9]*$ &&
                 "$total_blocks" =~ ^[1-9][0-9]*$ &&
                 "$available_blocks" =~ ^[0-9]+$ ]]; then
        echo "[disk-guard] 无法读取实例盘所在文件系统容量: $target" >&2
        return 1
    fi

    total_bytes=$((block_size * total_blocks))
    available_bytes=$((block_size * available_blocks))
    required_bytes=$(disk_headroom_required_free_bytes \
        "$total_bytes" "$minimum_gib" "$minimum_percent")
    warning_bytes=$((
        (total_bytes / 100) * warning_percent
        + ((total_bytes % 100) * warning_percent + 99) / 100
    ))
    percent_tenths=$((available_bytes * 1000 / total_bytes))
    gib=$((1024 * 1024 * 1024))
    available_gib=$((available_bytes / gib))
    required_gib=$(((required_bytes + gib - 1) / gib))
    DISK_HOST_FREE_BYTES=$available_bytes
    DISK_HOST_REQUIRED_FREE_BYTES=$required_bytes
    export DISK_HOST_FREE_BYTES DISK_HOST_REQUIRED_FREE_BYTES

    if ((available_bytes < required_bytes)); then
        echo "[disk-guard] 余量 ${available_gib} GiB（$((percent_tenths / 10)).$((percent_tenths % 10))%），最低 ${required_gib} GiB" >&2
        if [[ "$force" == 1 ]]; then
            echo "[disk-guard] WARN: DISK_FORCE=1，显式越过满盘/ENOSPC 风险" >&2
            return 0
        fi
        echo "[disk-guard] qcow2 所在文件系统空间不足，拒绝继续" >&2
        echo "[disk-guard] 请释放/迁移数据；仅紧急恢复可用 DISK_FORCE=1 越过" >&2
        return 1
    fi
    if ((available_bytes < warning_bytes)); then
        echo "[disk-guard] WARN: 文件系统仅余 ${available_gib} GiB（$((percent_tenths / 10)).$((percent_tenths % 10))%）；建议至少保留 ${warning_percent}%" >&2
    fi
}
