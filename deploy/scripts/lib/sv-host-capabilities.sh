# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 宿主 KVM/TSC 能力预检。
#
# 该片段在硬件 profile 生成前加载，使选择器可以排除宿主无法实现的 TSC 频率。
# 测试可预先设置 STEALTH_KVM_* 变量；生产环境默认调用只读探测工具。
# ---------------------------------------------------------------------------

: "${STRICT_HARDWARE:=1}"
: "${STEALTH_TSC_POLICY:=auto}"

case "$STRICT_HARDWARE" in
    0|1) ;;
    *) echo "ERROR: STRICT_HARDWARE 必须是 0 或 1" >&2; exit 2 ;;
esac

case "$STEALTH_TSC_POLICY" in
    auto|profile|host|omit) ;;
    *)
        echo "ERROR: STEALTH_TSC_POLICY 只支持 auto/profile/host/omit" >&2
        exit 2
        ;;
esac

_sv_probe_kvm_capabilities() {
    # 只要调用方显式注入了主能力字段，就视为测试/受控部署覆盖，避免访问 /dev/kvm。
    if [[ -n "${STEALTH_KVM_TSC_CONTROL+x}" ]]; then
        : "${STEALTH_KVM_AVAILABLE:=1}"
        : "${STEALTH_KVM_GET_TSC_KHZ:=1}"
        : "${STEALTH_KVM_TSC_KHZ:=0}"
        : "${STEALTH_KVM_ERROR:=}"
        return
    fi

    local helper="$HERE/kvm-capabilities.py"
    local output
    if output="$(python3 "$helper" --format shell 2>/dev/null)"; then
        eval "$output"
    else
        # helper 在失败时仍输出经过单引号转义的固定赋值；保留错误用于诊断。
        eval "$output"
        : "${STEALTH_KVM_AVAILABLE:=0}"
        : "${STEALTH_KVM_TSC_CONTROL:=0}"
        : "${STEALTH_KVM_GET_TSC_KHZ:=0}"
        : "${STEALTH_KVM_TSC_KHZ:=0}"
        : "${STEALTH_KVM_ERROR:=KVM 能力探测失败}"
    fi
}

_sv_probe_kvm_capabilities
export STRICT_HARDWARE STEALTH_TSC_POLICY
export STEALTH_KVM_AVAILABLE STEALTH_KVM_TSC_CONTROL
export STEALTH_KVM_GET_TSC_KHZ STEALTH_KVM_TSC_KHZ STEALTH_KVM_ERROR

# 真正启动 KVM 时能力不可读必须提前失败。DRY_RUN 仍执行同样检查，以便部署前发现
# E5/X99 固件未开启 VT-x/EPT、权限错误或嵌套虚拟化缺失。
if [[ "$STEALTH_KVM_AVAILABLE" != "1" && "$STRICT_HARDWARE" == "1" ]]; then
    echo "ERROR: /dev/kvm 不可用或无法创建临时 vCPU: ${STEALTH_KVM_ERROR:-unknown}" >&2
    echo "       请检查 BIOS VT-x/AMD-V、EPT/NPT、kvm 模块与设备权限。" >&2
    exit 1
fi

# 供 profile 选择器使用；单位 MHz，四舍五入比直接截断更适合 250ppm 边界判断。
if [[ "${STEALTH_KVM_TSC_KHZ:-0}" =~ ^[0-9]+$ ]] && (( STEALTH_KVM_TSC_KHZ > 0 )); then
    STEALTH_HOST_TSC_MHZ=$(( (STEALTH_KVM_TSC_KHZ + 500) / 1000 ))
else
    STEALTH_HOST_TSC_MHZ=0
fi
export STEALTH_HOST_TSC_MHZ

# 无 scaling 时，platform 选择器必须只保留与宿主 invariant TSC 相同的 bundle。
# 支持 scaling 的宿主不设置硬过滤值，可按其它能力选择任意受支持 profile。
if [[ "${STEALTH_KVM_TSC_CONTROL:-0}" != "1" && "$STEALTH_HOST_TSC_MHZ" -gt 0 ]]; then
    STEALTH_REQUIRED_TSC_MHZ="$STEALTH_HOST_TSC_MHZ"
else
    STEALTH_REQUIRED_TSC_MHZ=""
fi
export STEALTH_REQUIRED_TSC_MHZ

# KVM 的 named CPU 在 realize 时仍会读取物理宿主的地址位宽。直接传
# `phys-bits=<目标值>` 会在 48-bit Ryzen 宿主模拟 43-bit Ryzen 3 时产生 warning；
# 更安全的 QEMU 形式是 host-phys-bits + limit，但前提是宿主位宽不能小于目标。
# `/proc/cpuinfo` 的 address sizes 来自宿主 CPUID；测试可用同名变量显式覆盖。
_sv_detect_host_cpu_phys_bits() {
    local detected="${STEALTH_HOST_CPU_PHYS_BITS:-}"
    if [[ -z "$detected" ]]; then
        detected="$(awk -F': ' '
            /^address sizes[[:space:]]*:/ {
                if (match($2, /^[0-9]+/)) {
                    print substr($2, RSTART, RLENGTH)
                }
                exit
            }
        ' /proc/cpuinfo 2>/dev/null)"
    fi
    [[ -n "$detected" ]] || detected=0
    if ! [[ "$detected" =~ ^[0-9]+$ ]] || (( detected != 0 && (detected < 32 || detected > 64) )); then
        echo "ERROR: STEALTH_HOST_CPU_PHYS_BITS 必须为 0 或 [32,64] 整数" >&2
        return 1
    fi
    printf '%s\n' "$detected"
}

if ! STEALTH_HOST_CPU_PHYS_BITS="$(_sv_detect_host_cpu_phys_bits)"; then
    exit 2
fi
export STEALTH_HOST_CPU_PHYS_BITS

# profile 的 CPU_PHYS_BITS 是客体应枚举到的固定事实。宿主不足时，QEMU 的
# host-phys-bits-limit 只能悄悄降到宿主值，造成 profile/CPUID 矛盾，因此必须在
# 持久化 profile、创建磁盘或 TPM state 之前独立拒绝。
sv_validate_cpu_phys_bits() {
    local target_bits="${CPU_PHYS_BITS:-40}"
    local host_bits="${STEALTH_HOST_CPU_PHYS_BITS:-0}"

    if ! [[ "$target_bits" =~ ^[0-9]+$ ]] || (( target_bits < 32 || target_bits > 52 )); then
        echo "ERROR: profile CPU_PHYS_BITS 超出 [32,52]: $target_bits" >&2
        return 1
    fi
    if (( host_bits == 0 )); then
        if [[ "${STRICT_HARDWARE:-1}" == "1" ]]; then
            echo "ERROR: 无法读取宿主 CPU 物理地址位宽，严格模式不能证明目标 ${target_bits} 位可实现" >&2
            return 1
        fi
        echo ">> WARN: 无法读取宿主 CPU 物理地址位宽；兼容模式继续，CPUID 一致性未验证" >&2
        return 0
    fi
    if (( host_bits < target_bits )); then
        echo "ERROR: 宿主 CPU 物理地址仅 ${host_bits} 位，无法实现 profile 要求的 ${target_bits} 位" >&2
        return 1
    fi
}

# 在 profile 已选定后，以实际 QEMU/KVM 创建一次最小 vCPU。manifest 的厂商、TSC
# 和线程数只说明“候选关系成立”，不能证明 Broadwell 宿主拥有 Skylake model 所需的
# 全部 CPUID。enforce=on 会把缺失特性转成硬失败，本烟测同时拒绝 warning，防止正式
# 启动到一半才发现 E5/X99 无法承载所选 CPU。
sv_validate_cpu_realize() {
    [[ "${STRICT_HARDWARE:-1}" == "1" ]] || return 0

    local cpu_arg output="" status=0
    cpu_arg="$(stealth_qemu_cpu_arg)"
    if output="$({
        printf '%s\n' \
            '{"execute":"qmp_capabilities","id":"vmate-cap"}' \
            '{"execute":"quit","id":"vmate-quit"}'
    } | timeout 10 "$QEMU" \
        -machine q35,accel=kvm,vmport=off \
        -cpu "$cpu_arg" \
        -smp "cpus=$CPUS,cores=${CPU_CORES},threads=$(( CPU_THREADS / CPU_CORES )),sockets=1" \
        -m 128M -display none -nodefaults -S -qmp stdio -monitor none 2>&1)"; then
        status=0
    else
        status=$?
    fi

    # 同时验证退出码、QMP quit 响应与 stderr；即使测试替身错误地 exit 0 但未创建
    # vCPU，也不能仅凭进程状态被放行。
    if (( status != 0 )) ||
       ! grep -Eq '"id"[[:space:]]*:[[:space:]]*"vmate-quit"' <<<"$output" ||
       grep -Eiq '(^|[[:space:]])(warning|error|failed|unsupported)(:|[[:space:]])' <<<"$output"; then
        echo "ERROR: 选定 CPU 无法由当前 KVM 宿主无警告实现。" >&2
        echo "       platform=${PLATFORM_ID:-unknown}" >&2
        echo "       cpu=${CPU_NAME:-unknown}" >&2
        echo "       这通常表示 E5/Broadwell 缺少所选 Skylake CPUID，或 TSC 频率不可设置。" >&2
        sed -n '1,40p' <<<"$output" >&2
        return 1
    fi
}
