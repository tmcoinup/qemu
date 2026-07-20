#!/usr/bin/env bash
# 老式家用平台消费级 SATA SSD 目录的安全加载器。
#
# 新建 profile 时只随机选择稳定条目 ID；型号、固件、料号、容量和接口随后作为
# 一个整体持久化。重载必须把保存的 ID 交回本目录并逐字段校验，不能再次抽签。

if [[ "${_STEALTH_STORAGE_COMPAT_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 兼容直接执行诊断。
    return 0 2>/dev/null || exit 0
fi
_STEALTH_STORAGE_COMPAT_LOADED=1

_STEALTH_STORAGE_COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${STEALTH_STORAGE_COMPAT_MANIFEST:=$_STEALTH_STORAGE_COMPAT_DIR/../../hardware/storage-compatibility.json}"
: "${STEALTH_STORAGE_COMPAT_HELPER:=$_STEALTH_STORAGE_COMPAT_DIR/../storage-compat.py}"

_stealth_storage_compat_python() {
    command -v python3 >/dev/null 2>&1 || {
        echo "ERROR: storage compatibility 需要 python3" >&2
        return 1
    }
    [[ -r "$STEALTH_STORAGE_COMPAT_MANIFEST" ]] || {
        echo "ERROR: storage compatibility 清单不可读: $STEALTH_STORAGE_COMPAT_MANIFEST" >&2
        return 1
    }
    [[ -r "$STEALTH_STORAGE_COMPAT_HELPER" ]] || {
        echo "ERROR: storage compatibility 加载器不可读: $STEALTH_STORAGE_COMPAT_HELPER" >&2
        return 1
    }
    python3 "$STEALTH_STORAGE_COMPAT_HELPER" \
        "$STEALTH_STORAGE_COMPAT_MANIFEST" "$@"
}

stealth_storage_compat_validate() {
    _stealth_storage_compat_python validate
}

stealth_storage_compat_ids() {
    _stealth_storage_compat_python list
}

stealth_storage_compat_pick_id() {
    local -a ids=()
    local selected_index
    declare -F _rand >/dev/null 2>&1 || {
        echo "ERROR: storage compatibility 均匀抽样需要 stealth-rng.sh" >&2
        return 1
    }
    mapfile -t ids < <(stealth_storage_compat_ids) || return 1
    (( ${#ids[@]} >= 3 )) || {
        echo "ERROR: storage compatibility 可用 SATA SSD 少于 3 个" >&2
        return 1
    }
    selected_index="$(_rand 0 "$((${#ids[@]} - 1))")" || return 1
    printf '%s\n' "${ids[$selected_index]}"
}

stealth_storage_compat_load() {
    local profile_id="$1" output key encoded value
    [[ -n "$profile_id" ]] || {
        echo "ERROR: 缺少 storage compatibility 条目 ID" >&2
        return 1
    }
    output="$(_stealth_storage_compat_python export "$profile_id")" || return 1
    while IFS=$'\t' read -r key encoded; do
        case "$key" in
            BOOT_STORAGE_CATALOG_REVISION|BOOT_STORAGE_COMPONENT_ID|\
            BOOT_STORAGE_MANUFACTURER|BOOT_STORAGE_MODEL|\
            BOOT_STORAGE_PART_NUMBER|BOOT_STORAGE_FIRMWARE|\
            BOOT_STORAGE_SIZE_BYTES|BOOT_STORAGE_INTERFACE)
                ;;
            *)
                echo "ERROR: storage compatibility 含非法变量名: $key" >&2
                return 1
                ;;
        esac
        value="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)" || {
            echo "ERROR: storage compatibility 字段 $key 编码损坏" >&2
            return 1
        }
        printf -v "$key" '%s' "$value"
        export "${key?}"
    done <<<"$output"
}

stealth_storage_compat_binding_is_current() (
    local profile_id="${BOOT_STORAGE_COMPONENT_ID:-}" field
    local -A saved=()
    local fields=(
        BOOT_STORAGE_COMPONENT_ID
        BOOT_STORAGE_MANUFACTURER BOOT_STORAGE_MODEL
        BOOT_STORAGE_PART_NUMBER BOOT_STORAGE_FIRMWARE
        BOOT_STORAGE_SIZE_BYTES BOOT_STORAGE_INTERFACE
    )
    for field in "${fields[@]}"; do
        saved["$field"]="${!field:-}"
    done
    stealth_storage_compat_load "$profile_id" >/dev/null || return 1
    for field in "${fields[@]}"; do
        [[ "${saved[$field]}" == "${!field}" ]] || return 1
    done
)
