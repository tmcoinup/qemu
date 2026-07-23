# shellcheck shell=bash
# 版本化可更换部件目录的薄加载层。各类严格事实校验拆到独立 Python 模块，
# 避免显示器、SSD 与 AIB 显卡的契约继续挤在一个超长内嵌脚本中。

if [[ "${_STEALTH_COMPONENTS_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
_STEALTH_COMPONENTS_LOADED=1

_STEALTH_COMPONENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_STEALTH_COMPONENT_REPO_ROOT="$(cd "$_STEALTH_COMPONENT_LIB_DIR/../../.." && pwd)"
: "${STEALTH_COMPONENT_MANIFEST:=$_STEALTH_COMPONENT_REPO_ROOT/deploy/hardware/components.json}"
_STEALTH_COMPONENT_MANIFEST_DIR="$(cd "$(dirname "$STEALTH_COMPONENT_MANIFEST")" && pwd)"
: "${STEALTH_GPU_BOARD_MANIFEST:=$_STEALTH_COMPONENT_MANIFEST_DIR/gpu-boards.json}"
: "${STEALTH_STORAGE_MANIFEST:=$_STEALTH_COMPONENT_MANIFEST_DIR/storage.json}"

readonly _STEALTH_PERIPHERAL_CATALOG_TOOL="$_STEALTH_COMPONENT_REPO_ROOT/deploy/scripts/component_peripheral_catalog.py"
readonly _STEALTH_GPU_BOARD_CATALOG_TOOL="$_STEALTH_COMPONENT_REPO_ROOT/deploy/scripts/gpu_board_catalog.py"
readonly _STEALTH_STORAGE_CATALOG_TOOL="$_STEALTH_COMPONENT_REPO_ROOT/deploy/scripts/storage_catalog.py"

_stealth_component_python() {
    python3 "$_STEALTH_PERIPHERAL_CATALOG_TOOL" \
        "$STEALTH_COMPONENT_MANIFEST" "$@"
}

_stealth_gpu_board_python() {
    python3 "$_STEALTH_GPU_BOARD_CATALOG_TOOL" \
        "$STEALTH_COMPONENT_MANIFEST" "$STEALTH_GPU_BOARD_MANIFEST" "$@"
}

_stealth_storage_python() {
    python3 "$_STEALTH_STORAGE_CATALOG_TOOL" \
        "$STEALTH_COMPONENT_MANIFEST" "$STEALTH_STORAGE_MANIFEST" "$@"
}

stealth_component_validate() {
    local component_revision gpu_revision storage_revision
    component_revision="$(_stealth_component_python validate)" || return 1
    gpu_revision="$(_stealth_gpu_board_python validate)" || return 1
    storage_revision="$(_stealth_storage_python validate)" || return 1
    if [[ "$component_revision" != "$gpu_revision" ||
          "$component_revision" != "$storage_revision" ]]; then
        printf 'ERROR: component/GPU/SSD 目录 revision 不一致: %s/%s/%s\n' \
            "$component_revision" "$gpu_revision" "$storage_revision" >&2
        return 1
    fi
    printf '%s\n' "$component_revision"
}

stealth_component_rows() {
    case "$1" in
        gpu) _stealth_gpu_board_python rows ;;
        storage) _stealth_storage_python rows ;;
        monitor|keyboards|mice|tablets) _stealth_component_python "$1" ;;
        *) echo "ERROR: 未知 component kind: $1" >&2; return 2 ;;
    esac
}

stealth_component_gpu_row() {
    _stealth_gpu_board_python id "$1"
}

stealth_component_legacy_gpu_rows() {
    _stealth_gpu_board_python legacy-rows
}

stealth_component_legacy_gpu_index() {
    _stealth_gpu_board_python legacy-index
}

stealth_component_legacy_gpu_row() {
    _stealth_gpu_board_python legacy-id "$1"
}

stealth_component_storage_row() {
    _stealth_storage_python id "$1"
}

stealth_component_storage_serial_spec() {
    _stealth_storage_python serial-spec "$1"
}

stealth_component_storage_serial_is_valid() {
    _stealth_storage_python serial-valid "$1" "$2"
}

stealth_component_weight_rows() {
    case "$1" in
        gpu) _stealth_gpu_board_python weights ;;
        storage) _stealth_storage_python weights ;;
        monitor) _stealth_component_python monitor-weights ;;
        *) echo "ERROR: 未知 component weight kind: $1" >&2; return 2 ;;
    esac
}

stealth_component_monitor_row() {
    _stealth_component_python monitor-id "$1"
}

stealth_component_monitor_serial_spec() {
    _stealth_component_python monitor-serial-spec "$1"
}

stealth_component_monitor_serial_is_valid() {
    _stealth_component_python monitor-serial-valid "$1" "$2"
}

stealth_component_monitor_binary_serial() {
    _stealth_component_python monitor-binary-serial "$1" "$2"
}

stealth_component_monitor_revision() {
    _stealth_component_python monitor-revision "$1"
}

stealth_component_monitor_secondary_detail() {
    _stealth_component_python monitor-secondary-detail "$1"
}
