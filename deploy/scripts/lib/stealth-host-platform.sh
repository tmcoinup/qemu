#!/usr/bin/env bash
# Linux host-passthrough compatibility 模板加载器。
#
# 物理 platforms.json 只保存有 CPU/主板证据的整机组合；本模块读取独立共享清单，
# 导出明确标记为 generic Q35 的兜底平台。它不自行决定何时降级：调用方必须先
# 确认 --allow-platform-compatibility，且静态候选均未通过真实 KVM realize。

if [[ "${_STEALTH_HOST_PLATFORM_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 的 exit 仅服务直接执行诊断路径。
    return 0 2>/dev/null || exit 0
fi
_STEALTH_HOST_PLATFORM_LOADED=1

_STEALTH_HOST_PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${STEALTH_HOST_PLATFORM_MANIFEST:=$_STEALTH_HOST_PLATFORM_DIR/../../hardware/host-compatibility.json}"
: "${STEALTH_HOST_PLATFORM_HELPER:=$_STEALTH_HOST_PLATFORM_DIR/../host-platform.py}"

_stealth_host_platform_python() {
    local action="$1"
    shift
    command -v python3 >/dev/null 2>&1 || {
        echo "ERROR: host compatibility 平台需要 python3" >&2
        return 1
    }
    [[ -r "$STEALTH_HOST_PLATFORM_MANIFEST" ]] || {
        echo "ERROR: host compatibility 清单不可读: $STEALTH_HOST_PLATFORM_MANIFEST" >&2
        return 1
    }
    [[ -r "$STEALTH_HOST_PLATFORM_HELPER" ]] || {
        echo "ERROR: host compatibility 导出器不可读: $STEALTH_HOST_PLATFORM_HELPER" >&2
        return 1
    }
    python3 "$STEALTH_HOST_PLATFORM_HELPER" \
        "$STEALTH_HOST_PLATFORM_MANIFEST" "$action" "$@"
}

stealth_host_platform_validate() {
    _stealth_host_platform_python validate
}

stealth_host_platform_index() {
    _stealth_host_platform_python index
}

stealth_host_platform_is_id() {
    local wanted="$1" template_id _vendor
    while IFS='|' read -r template_id _vendor; do
        [[ "$template_id" == "$wanted" ]] && return 0
    done < <(stealth_host_platform_index)
    return 1
}

stealth_host_platform_status() {
    local template_id="$1"
    _stealth_host_platform_python status "$template_id"
}

stealth_host_platform_id_for_vendor() {
    local wanted_vendor="$1" template_id vendor
    while IFS='|' read -r template_id vendor; do
        if [[ "$vendor" == "$wanted_vendor" ]]; then
            printf '%s\n' "$template_id"
            return 0
        fi
    done < <(stealth_host_platform_index)
    echo "ERROR: 没有与宿主厂商 $wanted_vendor 对应的 host compatibility 模板" >&2
    return 1
}

stealth_host_platform_load() {
    local template_id="$1"
    local guest_cpus="${2:-${CPUS:-4}}"
    local output key encoded value

    if ! output="$(
        _stealth_host_platform_python export "$template_id" "$guest_cpus"
    )"; then
        return 1
    fi
    while IFS=$'\t' read -r key encoded; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
            echo "ERROR: host compatibility 导出包含非法变量名: $key" >&2
            return 1
        }
        if ! value="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)"; then
            echo "ERROR: host compatibility 字段 $key 的编码损坏" >&2
            return 1
        fi
        printf -v "$key" '%s' "$value"
        export "${key?}"
    done <<<"$output"
}

stealth_host_platform_binding_is_current() {
    # `-cpu host` 只能来自 schema-1 registry 导出的完整 host 模板。legacy
    # profile 即使自填相同变量，也没有真实宿主品牌/CPUID 指纹重建，必须拒绝。
    [[ "${PLATFORM_SCHEMA_VERSION:-0}" == 1 &&
       "${PLATFORM_STATUS:-}" == compatibility &&
       "${ALLOW_PLATFORM_COMPATIBILITY:-0}" == 1 &&
       "${PLATFORM_CPU_SOURCE:-}" == host-passthrough &&
       "${PLATFORM_IDENTITY_SCOPE:-}" == generic_q35_host_passthrough_compatibility &&
       "${CPU_QEMU_ARG:-}" == host &&
       "${CPU_MODEL:-}" == host &&
       "${PLATFORM_TEMPLATE_DIGEST:-}" =~ ^[0-9a-f]{64}$ &&
       "${CPU_HOST_FINGERPRINT:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
    stealth_host_platform_is_id "${PLATFORM_ID:-}"
}

stealth_host_platform_qemu_cpu_arg() {
    # host passthrough 必须保留 KVM 的原生 TSC；尤其 E5 v1-v4 没有 TSC scaling
    # 时，追加消费级 profile 的 tsc-freq 会让 vCPU realize 失败。该构造器仍
    # 强制 enforce=on，并固定当前 profile 已绑定的厂商和物理地址位宽。
    if ! stealth_host_platform_binding_is_current; then
        echo "ERROR: 当前 profile 不是受控 host-passthrough CPU" >&2
        return 1
    fi
    case "${CPU_VENDOR:-}" in
        GenuineIntel|AuthenticAMD) ;;
        *)
            echo "ERROR: host-passthrough CPU_VENDOR 非法: ${CPU_VENDOR:-empty}" >&2
            return 1
            ;;
    esac
    if ! [[ "${CPU_PHYS_BITS:-}" =~ ^[0-9]+$ ]] ||
       (( CPU_PHYS_BITS < 32 || CPU_PHYS_BITS > 52 )); then
        echo "ERROR: host-passthrough CPU_PHYS_BITS 超出 [32,52]" >&2
        return 1
    fi
    printf 'host,kvm=off,hypervisor=off,enforce=on,host-phys-bits=on,host-phys-bits-limit=%s,vendor=%s\n' \
        "$CPU_PHYS_BITS" "$CPU_VENDOR"
}

# QEMU generic 平台序号只保证每实例唯一和跨重启稳定，不借用任何物理板厂格式。
_serial_qemu() {
    local value
    value="$(_rand 1 999999999999)" || return 1
    printf 'MB%012d\n' "$value"
}
