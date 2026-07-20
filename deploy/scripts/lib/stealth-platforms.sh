#!/usr/bin/env bash
# 版本化整机平台清单加载器。
#
# 本文件只负责稳定的 shell API 和 base64 安全投影；JSON 严格校验、平台事实
# 与导出逻辑分别位于 platform_manifest*.py，避免在 shell 中嵌入大型解释器程序。

_STEALTH_PLATFORMS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${STEALTH_PLATFORM_MANIFEST:=$_STEALTH_PLATFORMS_LIB_DIR/../../hardware/platforms.json}"
: "${STEALTH_PLATFORM_HELPER:=$_STEALTH_PLATFORMS_LIB_DIR/../platform_manifest_cli.py}"

_stealth_platform_python() {
    local action="$1"
    local platform_id="${2:-}"
    local strict_hardware="${STRICT_HARDWARE:-1}"
    local allow_compatibility="${ALLOW_PLATFORM_COMPATIBILITY:-0}"

    command -v python3 >/dev/null 2>&1 || {
        echo "ERROR: 读取整机平台清单需要 python3" >&2
        return 1
    }
    [[ -r "$STEALTH_PLATFORM_MANIFEST" ]] || {
        echo "ERROR: 整机平台清单不可读: $STEALTH_PLATFORM_MANIFEST" >&2
        return 1
    }
    [[ -r "$STEALTH_PLATFORM_HELPER" ]] || {
        echo "ERROR: 整机平台加载器不可读: $STEALTH_PLATFORM_HELPER" >&2
        return 1
    }

    # 显式传入授权门禁，确保临时函数赋值与生产环境变量具有相同语义。
    python3 "$STEALTH_PLATFORM_HELPER" \
        "$STEALTH_PLATFORM_MANIFEST" "$action" "$platform_id" \
        "$strict_hardware" "$allow_compatibility"
}

stealth_platform_validate() {
    _stealth_platform_python validate
}

stealth_platform_index() {
    _stealth_platform_python index
}

# 返回已校验 manifest 的真实状态，不信任 profile 中可编辑的 PLATFORM_STATUS。
stealth_platform_manifest_status() {
    local platform_id="$1"
    _stealth_platform_python status "$platform_id"
}

stealth_platform_legacy_cpu_rows() {
    _stealth_platform_python legacy_cpu
}

stealth_platform_legacy_board_rows() {
    _stealth_platform_python legacy_board
}

stealth_platform_load() {
    local platform_id="$1"
    local output key encoded value

    if ! output="$(_stealth_platform_python export "$platform_id")"; then
        return 1
    fi
    while IFS=$'\t' read -r key encoded; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
            echo "ERROR: 平台导出包含非法变量名: $key" >&2
            return 1
        }
        if ! value="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)"; then
            echo "ERROR: 平台字段 $key 的编码损坏" >&2
            return 1
        fi
        printf -v "$key" '%s' "$value"
        export "${key?}"
    done <<<"$output"
}
