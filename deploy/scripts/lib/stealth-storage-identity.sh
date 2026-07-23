#!/usr/bin/env bash
# 依据稳定实例键为已选 NVMe 画像补全同厂商格式序列号。

if [[ "${_STEALTH_STORAGE_IDENTITY_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
_STEALTH_STORAGE_IDENTITY_LOADED=1

stealth_stable_nvme_serial() {
    local component_id="$1" identity_key="$2"
    local attempt key serial

    for ((attempt = 0; attempt < 32; attempt++)); do
        key="${identity_key}-${component_id}-${attempt}"
        case "$component_id" in
            samsung-970-pro-512gb)
                serial="S$(_stealth_stable_hex "$key-prefix" 3)N"
                serial+="$(_stealth_stable_hex "$key-suffix" 10)"
                ;;
            intel-760p-512gb)
                serial="BTHH$(_stealth_stable_hex "$key-suffix" 8)512D"
                ;;
            wd-pc-sn730-512gb|kioxia-xg6-512gb)
                # 两家公开样本都接受十二位大写字母数字；十六进制是该集合的
                # 保守子集，并保持同一实例键生成稳定但不复制实机的合成值。
                serial="$(_stealth_stable_hex "$key-serial" 12)"
                ;;
            *)
                echo "ERROR: 未知 NVMe 稳定序列号策略: $component_id" >&2
                return 2
                ;;
        esac
        if stealth_component_storage_serial_is_valid \
                "$component_id" "$serial" >/dev/null 2>&1; then
            printf '%s\n' "$serial"
            return 0
        fi
    done
    echo "ERROR: 无法生成合法 NVMe 稳定序列号: $component_id" >&2
    return 2
}
