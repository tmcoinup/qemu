#!/usr/bin/env bash
# 宿主感知的整机 bundle 选择器。
#
# 顺序固定为：E5 v3/v4 宿主正常家用池 → 默认 supported →
# 既有 compatibility → 家用 compatibility → 受限 household host。
# 每一个候选都必须通过当前 KVM 的真实 vCPU realize；粗略的厂商/频率/TSC
# 匹配不能再把 E5 v4 错判为可实现 Skylake。

_stealth_shuffle_platform_ids() {
    local array_name="$1"
    local -n values="$array_name"
    local index swap_index temporary
    for (( index=${#values[@]} - 1; index > 0; index-- )); do
        swap_index="$(_rand 0 "$index")" || return
        temporary="${values[$index]}"
        values[index]="${values[swap_index]}"
        values[swap_index]="$temporary"
    done
}

_stealth_platform_runtime_preflight() {
    stealth_validate_platform_host_constraints || return 1
    # CPU 目录只描述“目标是什么”，宿主能力模块才证明“当前物理机能否实现”。
    # 创建入口若忘记加载能力模块，绝不能把函数缺失误当作预检成功，否则会先
    # 持久化一个无法启动的 profile，再到 start-vm 阶段才暴露错误。
    if ! declare -F sv_validate_cpu_phys_bits >/dev/null 2>&1 ||
       ! declare -F sv_validate_cpu_realize >/dev/null 2>&1; then
        echo "ERROR: CPU/KVM 实现预检模块未加载，拒绝选择或持久化平台。" >&2
        return 1
    fi
    sv_validate_cpu_phys_bits || return 1
    sv_validate_cpu_realize || return 1
}

_stealth_try_platform_ids() {
    local array_name="$1"
    local -n candidate_ids="$array_name"
    local platform_id rejection_file

    (( ${#candidate_ids[@]} > 0 )) || return 1
    _stealth_shuffle_platform_ids "$array_name" || return 1
    for platform_id in "${candidate_ids[@]}"; do
        # 候选失败是正常的探测分支，例如 E5 v4 会拒绝 Skylake 的 xsavec。
        # 暂存第一份详细拒绝原因；全部失败时再输出，既保留准确诊断又不刷屏。
        rejection_file="$(mktemp "${TMPDIR:-/tmp}/vmate-platform-reject.XXXXXX")" \
            || return 1
        if {
            stealth_platform_registry_load "$platform_id" "${CPUS:-4}" &&
                _stealth_platform_runtime_preflight
        } 2>"$rejection_file"; then
            sed -n '1,40p' "$rejection_file" >&2
            rm -f -- "$rejection_file"
            return 0
        fi
        if [[ -z "${_STEALTH_PLATFORM_FIRST_REJECTION:-}" ]]; then
            _STEALTH_PLATFORM_FIRST_REJECTION="$(sed -n '1,40p' "$rejection_file")"
        fi
        rm -f -- "$rejection_file"
    done
    return 1
}

_stealth_static_candidate_lists() {
    local supported_name="$1" compatibility_name="$2"
    local -n supported_ref="$supported_name"
    local -n compatibility_ref="$compatibility_name"
    local entry platform_id enabled vendor max_mhz threads tsc_mhz status
    local host_vendor
    host_vendor="$(_host_cpu_vendor)"
    local host_max required_tsc requested_cpus="${CPUS:-4}"
    host_max="$(_host_cpu_max_mhz)"
    required_tsc="$(_host_required_tsc_mhz)" || return 1

    for entry in "${PLATFORM_POOL[@]}"; do
        IFS='|' read -r platform_id enabled vendor max_mhz threads tsc_mhz <<<"$entry"
        [[ "$vendor" == "$host_vendor" ]] || continue
        (( threads == requested_cpus && max_mhz <= host_max )) || continue
        if [[ -n "$required_tsc" ]] && (( tsc_mhz != required_tsc )); then
            continue
        fi
        if [[ "$enabled" == true ]]; then
            supported_ref+=("$platform_id")
            continue
        fi
        status="$(stealth_platform_manifest_status "$platform_id")" || return 1
        [[ "$status" == compatibility ]] && compatibility_ref+=("$platform_id")
    done
}

_stealth_household_candidate_ids() {
    local output_name="$1"
    local wanted_status="$2"
    local -n output="$output_name"
    local platform_id host_classes threads _cpu_name
    local requested_cpus="${CPUS:-4}"
    local host_vendor host_class=""

    declare -F stealth_household_compat_index >/dev/null 2>&1 || return 0
    host_vendor="$(_host_cpu_vendor)"
    host_class="$(
        stealth_household_compat_current_host_class 2>/dev/null || true
    )"
    # 默认正常池必须有精确 CPUID 宿主分类；只有显式 compatibility 才允许未知
    # 家用宿主按同厂商逐个尝试，防止普通 Intel CPU 误领 E5 v3/v4 默认池。
    if [[ "$wanted_status" == supported && -z "$host_class" ]]; then
        return 0
    fi

    # 已知 E5 v1-v4/K10/Zen 必须锁到对应代际。未知家用宿主仍可在显式
    # compatibility 下尝试同厂商的较老家用基型，但每个候选仍需真实 KVM
    # realize；这既给未来物理机留兜底，也不会把 AMD 型号放进 Intel Guest。
    while IFS='|' read -r platform_id host_classes threads _cpu_name; do
        [[ -n "$platform_id" && "$threads" =~ ^[0-9]+$ ]] || continue
        (( threads == requested_cpus )) || continue
        if [[ -z "$host_class" ]]; then
            case "$host_vendor" in
                GenuineIntel) [[ ",$host_classes," == *,e5-* ]] || continue ;;
                AuthenticAMD) [[ ",$host_classes," == *,amd-* ]] || continue ;;
                *) continue ;;
            esac
        fi
        output+=("$platform_id")
    done < <(
        stealth_household_compat_index \
            "$host_class" "$requested_cpus" "$wanted_status"
    )
}

_stealth_cross_generation_household_candidate_ids() {
    local output_name="$1"
    local -n output_ref="$output_name"
    local platform_id host_classes threads _cpu_name
    local requested_cpus="${CPUS:-4}" host_vendor host_class

    declare -F stealth_household_compat_index >/dev/null 2>&1 || return 0
    host_class="$(
        stealth_household_compat_current_host_class 2>/dev/null
    )" || return 0
    host_vendor="$(_host_cpu_vendor)"

    # 这是显式 allow 下的最后一级兜底：只看同厂商、完整线程数、不同代际且
    # status=compatibility 的家用 SKU。随后仍逐项执行全部约束与真实 KVM smoke。
    while IFS='|' read -r platform_id host_classes threads _cpu_name; do
        [[ -n "$platform_id" && "$threads" =~ ^[0-9]+$ ]] || continue
        (( threads == requested_cpus )) || continue
        [[ ",$host_classes," != *",$host_class,"* ]] || continue
        case "$host_vendor" in
            GenuineIntel) [[ ",$host_classes," == *,e5-* ]] || continue ;;
            AuthenticAMD) [[ ",$host_classes," == *,amd-* ]] || continue ;;
            *) continue ;;
        esac
        output_ref+=("$platform_id")
    done < <(
        stealth_household_compat_index "" "$requested_cpus" compatibility
    )
}

_stealth_exact_host_candidate_ids() {
    local output_name="$1"
    # ShellCheck 无法跟踪调用方传入的数组名；这里是 Bash nameref，不是把数组改成字符串。
    # shellcheck disable=SC2178
    local -n output_ref="$output_name"
    local host_vendor platform_id
    host_vendor="$(_host_cpu_vendor)"
    if platform_id="$(stealth_host_platform_id_for_vendor "$host_vendor" 2>/dev/null)"; then
        output_ref+=("$platform_id")
    fi
}

stealth_select_platform_bundle() {
    local requested="${STEALTH_PLATFORM_ID:-}"
    local allow="${ALLOW_PLATFORM_COMPATIBILITY:-0}"
    local status
    local -a supported=() household_supported=() static_compatibility=()
    local -a household_compatibility=() cross_generation_compatibility=()
    local -a exact_host=()
    _STEALTH_PLATFORM_FIRST_REJECTION=

    if [[ -n "$requested" ]]; then
        stealth_platform_registry_is_id "$requested" || {
            echo "ERROR: 指定整机平台不存在: $requested" >&2
            return 1
        }
        status="$(stealth_platform_registry_status "$requested")" || return 1
        if [[ "$status" == compatibility && "$allow" != 1 ]]; then
            echo "ERROR: 指定平台需要 --allow-platform-compatibility: $requested" >&2
            return 1
        fi
        if ! stealth_platform_registry_load "$requested" "${CPUS:-4}" ||
           ! _stealth_platform_runtime_preflight; then
            echo "ERROR: 指定平台无法由当前宿主完整实现: $requested" >&2
            return 1
        fi
        return 0
    fi

    # G3220/i3-4130/i5-4570 在 E5-2696 v4 上已有实测，E5 v3 则仍由每次
    # KVM realize 收口；它们属于宿主默认正常 CPU 池。H81/PCH 继续由独立
    # identity scope 标记为 Q35 兼容边界。
    _stealth_household_candidate_ids household_supported supported
    if _stealth_try_platform_ids household_supported; then
        return 0
    fi
    _stealth_static_candidate_lists supported static_compatibility || return 1
    if _stealth_try_platform_ids supported; then
        return 0
    fi

    if [[ "$allow" == 1 ]]; then
        if _stealth_try_platform_ids static_compatibility; then
            return 0
        fi
        _stealth_household_candidate_ids \
            household_compatibility compatibility
        if _stealth_try_platform_ids household_compatibility; then
            return 0
        fi
        _stealth_cross_generation_household_candidate_ids \
            cross_generation_compatibility
        if _stealth_try_platform_ids cross_generation_compatibility; then
            # PLATFORM_ID 由通过预检的注册表加载器动态 export，静态分析无法追踪。
            # shellcheck disable=SC2153
            echo ">> WARN: 正常/同代 CPU 池不可用，已使用显式授权的同厂商跨代家用兜底: $PLATFORM_ID" >&2
            return 0
        fi
        _stealth_exact_host_candidate_ids exact_host
        if _stealth_try_platform_ids exact_host; then
            return 0
        fi
    fi

    # supported 候选也可能因为 CPU 预检缺失或当前 KVM 无法 realize 而全部失败；
    # 无论是否启用 compatibility，都先呈现第一条真实拒绝原因。
    [[ -z "$_STEALTH_PLATFORM_FIRST_REJECTION" ]] ||
        printf '%s\n' "$_STEALTH_PLATFORM_FIRST_REJECTION" >&2
    if [[ "$allow" == 1 ]] &&
       (( ${#supported[@]} + ${#household_supported[@]} +
          ${#static_compatibility[@]} + ${#household_compatibility[@]} +
          ${#cross_generation_compatibility[@]} + ${#exact_host[@]} > 0 )); then
        echo "ERROR: 选定 CPU 无法由当前 KVM 宿主无警告实现，或候选整机约束不成立。" >&2
    fi
    echo "ERROR: 无可用整机平台（Guest 仅允许家用 CPU）：vendor=$(_host_cpu_vendor) CPUS=${CPUS:-4} host_max=$(_host_cpu_max_mhz)MHz" >&2
    if [[ "$allow" != 1 ]] && {
        (( ${#static_compatibility[@]} > 0 )) ||
            declare -F stealth_household_compat_index >/dev/null 2>&1
    }; then
        echo "       若接受经 KVM 预检的家用 compatibility bundle，请追加 --allow-platform-compatibility。" >&2
    fi
    return 1
}
