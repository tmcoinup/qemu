#!/usr/bin/env bash
# 家用 CPU 正常池与 compatibility 完整组合的共享加载器。
# shellcheck disable=SC2119,SC2120 # index 的三个筛选参数均为可选参数。
#
# 本模块不自行决定优先级：E5 v3/v4 与精确 Ryzen 7 5800 的 supported 可直接
# 选择，其余 compatibility 必须由调用方先确认显式授权，再按宿主类和 CPUS 筛选。

if [[ "${_STEALTH_HOUSEHOLD_COMPAT_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 兼容直接执行诊断。
    return 0 2>/dev/null || exit 0
fi
_STEALTH_HOUSEHOLD_COMPAT_LOADED=1

_STEALTH_HOUSEHOLD_COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${STEALTH_HOUSEHOLD_COMPAT_MANIFEST:=$_STEALTH_HOUSEHOLD_COMPAT_DIR/../../hardware/household-compatibility.json}"
: "${STEALTH_HOUSEHOLD_COMPAT_HELPER:=$_STEALTH_HOUSEHOLD_COMPAT_DIR/../household-compat.py}"

_stealth_household_compat_python() {
    local action="$1"
    shift
    command -v python3 >/dev/null 2>&1 || {
        echo "ERROR: household compatibility 需要 python3" >&2
        return 1
    }
    [[ -r "$STEALTH_HOUSEHOLD_COMPAT_MANIFEST" ]] || {
        echo "ERROR: household compatibility 清单不可读: $STEALTH_HOUSEHOLD_COMPAT_MANIFEST" >&2
        return 1
    }
    [[ -r "$STEALTH_HOUSEHOLD_COMPAT_HELPER" ]] || {
        echo "ERROR: household compatibility 加载器不可读: $STEALTH_HOUSEHOLD_COMPAT_HELPER" >&2
        return 1
    }
    python3 "$STEALTH_HOUSEHOLD_COMPAT_HELPER" \
        "$STEALTH_HOUSEHOLD_COMPAT_MANIFEST" "$action" "$@"
}

stealth_household_compat_validate() {
    _stealth_household_compat_python validate
}

stealth_household_compat_index() {
    local host_class="${1:-}"
    local threads="${2:-}"
    local status="${3:-}"
    local args=(index)
    [[ -z "$host_class" ]] || args+=(--host-class "$host_class")
    [[ -z "$threads" ]] || args+=(--threads "$threads")
    [[ -z "$status" ]] || args+=(--status "$status")
    _stealth_household_compat_python "${args[@]}"
}

stealth_household_compat_status() {
    _stealth_household_compat_python status "$1"
}

stealth_household_compat_is_id() {
    local wanted="$1" candidate_id _classes _threads _name
    while IFS='|' read -r candidate_id _classes _threads _name; do
        [[ "$candidate_id" == "$wanted" ]] && return 0
    done < <(stealth_household_compat_index)
    return 1
}

stealth_household_compat_load() {
    local candidate_id="$1"
    local output key encoded value
    output="$(_stealth_household_compat_python export "$candidate_id")" || return 1
    while IFS=$'\t' read -r key encoded; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
            echo "ERROR: household compatibility 含非法变量名: $key" >&2
            return 1
        }
        value="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)" || {
            echo "ERROR: household compatibility 字段 $key 编码损坏" >&2
            return 1
        }
        printf -v "$key" '%s' "$value"
        export "${key?}"
    done <<<"$output"
}

stealth_household_compat_classify() {
    _stealth_household_compat_python classify "$1" "$2" "$3" "${4:-}"
}

# 只读首颗逻辑 CPU 的内核字段。独立函数便于测试替换内核视图，但生产调用
# 不接受路径或字段名注入。
_stealth_household_kernel_cpu_field() {
    local wanted="$1"
    case "$wanted" in
        vendor_id|cpu\ family|model|model\ name) ;;
        *) return 1 ;;
    esac
    awk -F':' -v wanted="$wanted" '
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == wanted) {
                value=$2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        }
    ' /proc/cpuinfo 2>/dev/null
}

# 返回当前物理宿主的受控分类。只有显式测试模式可通过 STEALTH_HOST_CPU_*
# 注入；生产环境始终读取内核真实视图，无法精确分类时不猜测正常宿主型号。
stealth_household_compat_current_host_class() {
    local vendor family model brand_name
    if [[ "${STEALTH_HOST_PROBE_TEST_MODE:-0}" == 1 ]]; then
        vendor="${STEALTH_HOST_CPU_VENDOR:-}"
        family="${STEALTH_HOST_CPU_FAMILY:-}"
        model="${STEALTH_HOST_CPU_MODEL:-}"
        brand_name="${STEALTH_HOST_CPU_MODEL_NAME:-}"
    else
        vendor=
        family=
        model=
        brand_name=
    fi
    [[ -n "$vendor" ]] ||
        vendor="$(_stealth_household_kernel_cpu_field vendor_id)"
    [[ -n "$family" ]] ||
        family="$(_stealth_household_kernel_cpu_field "cpu family")"
    [[ -n "$model" ]] ||
        model="$(_stealth_household_kernel_cpu_field model)"
    [[ -n "$brand_name" ]] ||
        brand_name="$(_stealth_household_kernel_cpu_field "model name")"
    [[ "$family" =~ ^[0-9]+$ && "$model" =~ ^[0-9]+$ ]] || return 1
    stealth_household_compat_classify "$vendor" "$family" "$model" "$brand_name"
}

# 已加载 household 条目必须与当前宿主类精确相交。该检查同时用于首次选择、
# profile 重载和 supported 运行时例外，不能只依赖同厂商判断。
stealth_household_compat_host_class_allowed() {
    local host_class classes=",${PLATFORM_HOST_CLASSES:-},"
    host_class="$(stealth_household_compat_current_host_class 2>/dev/null)" ||
        return 1
    [[ "$classes" == *",$host_class,"* ]]
}

# compatibility 允许尚未收录的新家用宿主依靠真实 KVM realize 逐项尝试。
# 已知宿主默认仍先走精确代际；只有显式 allow 的 compatibility profile 才能
# 跨同厂商代际重载，并继续接受频率、TSC、物理位宽与真实 KVM realize 门禁。
# supported 永远要求精确命中，未知宿主不能领取 E5 或 Ryzen 7 5800 正常池。
stealth_household_compat_host_class_consistent() {
    local host_class
    if ! host_class="$(
        stealth_household_compat_current_host_class 2>/dev/null
    )"; then
        [[ "${PLATFORM_STATUS:-}" == compatibility ]]
        return
    fi
    if [[ ",${PLATFORM_HOST_CLASSES:-}," == *",$host_class,"* ]]; then
        return 0
    fi
    [[ "${PLATFORM_STATUS:-}" == compatibility &&
       "${ALLOW_PLATFORM_COMPATIBILITY:-0}" == 1 ]] || return 1
    case "$host_class:${CPU_VENDOR:-}" in
        e5-*:GenuineIntel|amd-*:AuthenticAMD) return 0 ;;
        *) return 1 ;;
    esac
}

# 2026-07-19.5 将三个稳定 Haswell ID 从 compatibility 单向提升为 E5 v3/v4
# 正常池。旧 profile 只在字段完整、revision 确实更早且 ID 命中窄白名单时
# 做内存迁移；后续统一 registry 仍会逐字段重建整套 CPU/主板/DDR3/SATA 事实。
stealth_household_compat_promote_profile_status() {
    local present_name="$1" field
    local -n present_keys="$present_name"
    [[ "${PLATFORM_SCHEMA_VERSION:-}" == 1 &&
       "${PLATFORM_STATUS:-}" == compatibility &&
       "${PLATFORM_CPU_SOURCE:-}" == named-household-compatibility ]] ||
        return 0
    case "${PLATFORM_ID:-}" in
        compat-haswell-g3220-h81|\
        compat-haswell-i3-4130-h81|\
        compat-haswell-i5-4570-h81)
            ;;
        *)
            return 0
            ;;
    esac
    for field in \
        PLATFORM_ID PLATFORM_STATUS PLATFORM_CATALOG_REVISION \
        PLATFORM_CPU_SOURCE PLATFORM_HOST_CLASSES; do
        [[ -n "${present_keys[$field]:-}" && -n "${!field:-}" ]] || return 0
    done
    _stealth_platform_registry_revision_predates_cutoff \
        "$PLATFORM_CATALOG_REVISION" 2026-07-19.5 || return 0
    [[ "$(stealth_household_compat_status "$PLATFORM_ID" 2>/dev/null)" == supported ]] ||
        return 0
    PLATFORM_STATUS=supported
}

stealth_household_compat_server_brand_forbidden() {
    local brand="${1,,}"
    [[ "$brand" =~ (^|[^[:alnum:]])(xeon|epyc|opteron|threadripper)([^[:alnum:]]|$) ]] ||
        [[ "$brand" =~ (^|[^[:alnum:]])e(3|5|7)[-\ ]*[0-9]{3,5}[[:alnum:]]*([^[:alnum:]]|$) ]] ||
        [[ "$brand" =~ (^|[^[:alnum:]])e-[0-9]{4,5}[[:alnum:]]*([^[:alnum:]]|$) ]]
}

stealth_household_compat_host_passthrough_allowed() {
    ! stealth_household_compat_server_brand_forbidden "$1"
}
