#!/usr/bin/env bash
# Read-only host CPU realization probe for the G-11 launcher.
#
# Public API:
#   g11_cpu_capability_probe QEMU_BIN CPU_MODEL
#       Returns 0 when the model is either "supported" or "compatibility".
#       The result is exported through the G11_CPU_CAPABILITY_* variables below.
#
#   g11_cpu_realization_gate QEMU_BIN CPU_MODEL new|legacy
#       Returns 0 when the selected lifecycle may start the VM.  New VMs must
#       pass an enforce=on KVM realization.  Existing/legacy VMs retain the
#       historical QEMU masked-feature fallback when enforce=off realizes.
#
#   g11_cpu_capability_report
#       Prints one machine-readable line containing only stable values.
#
# Result classes:
#   supported      enforce=on realized the CPU on this host
#   compatibility enforce=on found a host feature gap, while enforce=off
#                 realized the CPU (legacy policy only)
#   unsupported    the requested model cannot be realized
#   unavailable    the probe itself cannot make a reliable determination
#
# Stable reason-code values are part of the integration contract.  Callers
# should branch on the codes, not on QEMU's human-readable diagnostics.

G11_CPU_CAPABILITY_CLASS=
G11_CPU_CAPABILITY_REASON=
G11_CPU_CAPABILITY_MODEL=
G11_CPU_CAPABILITY_DETAIL=
G11_CPU_CAPABILITY_ENFORCE_RC=
G11_CPU_CAPABILITY_COMPAT_RC=
G11_CPU_GATE_DECISION=
G11_CPU_GATE_REASON=
G11_KVM_CAPABILITIES_INJECTED=0
if [[ -v G11_KVM_AVAILABLE && -v G11_KVM_TSC_CONTROL &&
      -v G11_KVM_GET_TSC_KHZ && -v G11_KVM_TSC_KHZ ]]; then
    G11_KVM_CAPABILITIES_INJECTED=1
fi
: "${G11_KVM_AVAILABLE:=}"
: "${G11_KVM_TSC_CONTROL:=}"
: "${G11_KVM_GET_TSC_KHZ:=}"
: "${G11_KVM_TSC_KHZ:=}"
: "${G11_KVM_ERROR:=}"
G11_TSC_QEMU_OPTION=
G11_TSC_EFFECTIVE_HZ=
G11_TSC_RUNTIME_SOURCE=

_G11_CPU_PROBE_OUTPUT=
_G11_CPU_PROBE_RC=

_g11_cpu_set_capability_result() {
    G11_CPU_CAPABILITY_CLASS=$1
    G11_CPU_CAPABILITY_REASON=$2
    G11_CPU_CAPABILITY_DETAIL=$3
}

_g11_cpu_reset_result() {
    G11_CPU_CAPABILITY_CLASS=unavailable
    G11_CPU_CAPABILITY_REASON=G11_CPU_CAP_PROBE_NOT_RUN
    G11_CPU_CAPABILITY_MODEL=${1:-}
    G11_CPU_CAPABILITY_DETAIL='CPU realization probe did not run'
    G11_CPU_CAPABILITY_ENFORCE_RC=
    G11_CPU_CAPABILITY_COMPAT_RC=
    G11_CPU_GATE_DECISION=deny
    G11_CPU_GATE_REASON=G11_CPU_GATE_NOT_RUN
    _G11_CPU_PROBE_OUTPUT=
    _G11_CPU_PROBE_RC=
}

_g11_cpu_resolve_executable() {
    local candidate=$1 resolved

    if [[ "$candidate" == */* ]]; then
        [[ -f "$candidate" && -x "$candidate" ]] || return 1
        printf '%s\n' "$candidate"
        return 0
    fi

    resolved=$(command -v -- "$candidate" 2>/dev/null) || return 1
    [[ -f "$resolved" && -x "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
}

_g11_cpu_resolve_data_dir() {
    local qemu_bin=$1 candidate=${G11_QEMU_DATA_DIR:-}

    if [[ -z "$candidate" && "$qemu_bin" == */* ]]; then
        candidate="$(cd "$(dirname "$qemu_bin")" && pwd)/../pc-bios"
    fi
    if [[ -z "$candidate" ]]; then
        # A distro QEMU can use its compiled-in /usr/share/qemu path.
        return 0
    fi
    [[ -d "$candidate" && ! -L "$candidate" \
        && -r "$candidate/bios-256k.bin" ]] || return 1
    readlink -f -- "$candidate"
}

_g11_cpu_output_is_model_missing() {
    local output=${1,,}

    [[ "$output" == *'unable to find cpu model'* ||
       "$output" == *'cpu model'*'not found'* ||
       "$output" == *'unknown cpu model'* ]]
}

_g11_cpu_output_is_kvm_unavailable() {
    local output=${1,,}

    [[ "$output" == *'could not access kvm kernel module'* ||
       "$output" == *'failed to initialize kvm'* ||
       "$output" == *'kvm is not supported'* ||
       "$output" == *'kvm acceleration not available'* ||
       "$output" == *'/dev/kvm'*'permission denied'* ]]
}

_g11_cpu_output_is_host_feature_gap() {
    local output=${1,,}

    [[ "$output" == *"host doesn't support requested feature"* ||
       "$output" == *"host doesn't support requested features"* ]]
}

_g11_cpu_probe_once() {
    local qemu_bin=$1 cpu_model=$2 enforce_value=$3 timeout_bin=$4 timeout_seconds=$5
    local qemu_data_dir=${6:-}
    local output rc qmp_input
    local -a qemu_data_args=()

    [[ -z "$qemu_data_dir" ]] || qemu_data_args=( -L "$qemu_data_dir" )

    qmp_input=$'{"execute":"qmp_capabilities"}\n{"execute":"quit"}'
    if output=$(
        # SPD knobs are an internal full-VM contract.  A caller environment
        # must not turn this tiny 64 MiB CPU-only probe into a false memory
        # topology failure.
        unset QEMU_SPD_TYPE QEMU_SPD_MODULE_MB QEMU_SPD_MODULE_MB_LIST \
            QEMU_SPD_SPEED_MT QEMU_SPD_SLOTS QEMU_SPD_RANK_LIST \
            QEMU_SPD_DEVICE_WIDTH_LIST QEMU_SPD_MODULE_MFR_JEP106_LIST \
            QEMU_SPD_DRAM_MFR_JEP106_LIST QEMU_SPD_SERIAL_LIST \
            QEMU_SPD_PART_LIST
        LC_ALL=C "$timeout_bin" --foreground --kill-after=1 \
            "$timeout_seconds" \
            "$qemu_bin" \
            "${qemu_data_args[@]}" \
            -nodefaults \
            -no-user-config \
            -machine q35,accel=kvm \
            -cpu "${cpu_model},enforce=${enforce_value}" \
            -smp 1,maxcpus=1 \
            -m 64M \
            -display none \
            -serial none \
            -parallel none \
            -monitor none \
            -qmp stdio \
            -S \
            <<<"$qmp_input" 2>&1
    ); then
        rc=0
    else
        rc=$?
    fi

    _G11_CPU_PROBE_OUTPUT=$output
    _G11_CPU_PROBE_RC=$rc

    if (( rc != 0 )); then
        return 1
    fi

    # A successful exit from an unrelated executable is not a capability
    # result.  Requiring the QMP greeting proves that machine initialization
    # reached QEMU's control plane before the read-only quit command.
    if [[ "$output" != *'"QMP"'* ]]; then
        _G11_CPU_PROBE_RC=125
        return 1
    fi

    return 0
}

g11_cpu_capability_probe() {
    local requested_qemu=${1:-} cpu_model=${2:-}
    local qemu_bin qemu_data_dir timeout_bin timeout_seconds version_output enforce_output

    _g11_cpu_reset_result "$cpu_model"

    if [[ ! "$cpu_model" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]]; then
        _g11_cpu_set_capability_result unsupported \
            G11_CPU_CAP_INVALID_MODEL \
            'CPU model name is empty or contains unsafe syntax'
        return 1
    fi

    if ! qemu_bin=$(_g11_cpu_resolve_executable "$requested_qemu"); then
        _g11_cpu_set_capability_result unavailable \
            G11_CPU_CAP_QEMU_UNAVAILABLE \
            'QEMU executable is missing or is not executable'
        return 1
    fi

    if ! version_output=$(LC_ALL=C "$qemu_bin" --version 2>&1) ||
            [[ "$version_output" != *'QEMU emulator version'* ]]; then
        _g11_cpu_set_capability_result unavailable \
            G11_CPU_CAP_QEMU_INVALID \
            'Executable did not identify itself as QEMU'
        return 1
    fi
    if ! qemu_data_dir=$(_g11_cpu_resolve_data_dir "$qemu_bin"); then
        _g11_cpu_set_capability_result unavailable \
            G11_CPU_CAP_QEMU_DATA_UNAVAILABLE \
            'QEMU x86 firmware data directory is missing or incomplete'
        return 1
    fi

    timeout_seconds=${G11_CPU_PROBE_TIMEOUT_SECONDS:-5}
    if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] ||
            (( timeout_seconds > 30 )); then
        _g11_cpu_set_capability_result unavailable \
            G11_CPU_CAP_INVALID_TIMEOUT \
            'Probe timeout must be an integer from 1 through 30 seconds'
        return 1
    fi

    if [[ -n ${G11_CPU_PROBE_TIMEOUT_BIN:-} ]]; then
        if ! timeout_bin=$(_g11_cpu_resolve_executable "$G11_CPU_PROBE_TIMEOUT_BIN"); then
            _g11_cpu_set_capability_result unavailable \
                G11_CPU_CAP_TIMEOUT_UNAVAILABLE \
                'Configured timeout executable is unavailable'
            return 1
        fi
    elif ! timeout_bin=$(_g11_cpu_resolve_executable timeout); then
        _g11_cpu_set_capability_result unavailable \
            G11_CPU_CAP_TIMEOUT_UNAVAILABLE \
            'The timeout command required for a bounded probe is unavailable'
        return 1
    fi

    if _g11_cpu_probe_once "$qemu_bin" "$cpu_model" on \
            "$timeout_bin" "$timeout_seconds" "$qemu_data_dir"; then
        G11_CPU_CAPABILITY_ENFORCE_RC=0
        _g11_cpu_set_capability_result supported \
            G11_CPU_CAP_OK_ENFORCED \
            'CPU model realized with KVM enforce=on'
        return 0
    fi

    G11_CPU_CAPABILITY_ENFORCE_RC=$_G11_CPU_PROBE_RC
    enforce_output=$_G11_CPU_PROBE_OUTPUT

    case "$_G11_CPU_PROBE_RC" in
        124|137)
            _g11_cpu_set_capability_result unavailable \
                G11_CPU_CAP_PROBE_TIMEOUT \
                'Enforced CPU realization probe timed out'
            return 1
            ;;
        125)
            _g11_cpu_set_capability_result unavailable \
                G11_CPU_CAP_PROBE_PROTOCOL \
                'QEMU exited without a QMP greeting'
            return 1
            ;;
    esac

    if _g11_cpu_output_is_model_missing "$enforce_output"; then
        _g11_cpu_set_capability_result unsupported \
            G11_CPU_CAP_MODEL_UNAVAILABLE \
            'QEMU does not provide the requested CPU model'
        return 1
    fi

    if _g11_cpu_output_is_kvm_unavailable "$enforce_output"; then
        _g11_cpu_set_capability_result unavailable \
            G11_CPU_CAP_KVM_UNAVAILABLE \
            'KVM is unavailable or inaccessible on this host'
        return 1
    fi

    # Only an explicit QEMU host-feature diagnostic may enter compatibility
    # mode.  A generic enforced-probe failure must fail closed instead of being
    # mistaken for a safe feature downgrade.
    if ! _g11_cpu_output_is_host_feature_gap "$enforce_output"; then
        _g11_cpu_set_capability_result unsupported \
            G11_CPU_CAP_ENFORCED_FAILED \
            'Enforced CPU realization failed for a non-feature-gap reason'
        return 1
    fi

    if _g11_cpu_probe_once "$qemu_bin" "$cpu_model" off \
            "$timeout_bin" "$timeout_seconds" "$qemu_data_dir"; then
        G11_CPU_CAPABILITY_COMPAT_RC=0
        _g11_cpu_set_capability_result compatibility \
            G11_CPU_CAP_HOST_FEATURE_GAP \
            'Host lacks model features; QEMU enforce=off realization succeeded'
        return 0
    fi

    G11_CPU_CAPABILITY_COMPAT_RC=$_G11_CPU_PROBE_RC
    case "$_G11_CPU_PROBE_RC" in
        124|137)
            _g11_cpu_set_capability_result unavailable \
                G11_CPU_CAP_PROBE_TIMEOUT \
                'Compatibility CPU realization probe timed out'
            ;;
        125)
            _g11_cpu_set_capability_result unavailable \
                G11_CPU_CAP_PROBE_PROTOCOL \
                'Compatibility probe exited without a QMP greeting'
            ;;
        *)
            if _g11_cpu_output_is_kvm_unavailable "$_G11_CPU_PROBE_OUTPUT"; then
                _g11_cpu_set_capability_result unavailable \
                    G11_CPU_CAP_KVM_UNAVAILABLE \
                    'KVM became unavailable during compatibility probing'
            elif _g11_cpu_output_is_model_missing "$_G11_CPU_PROBE_OUTPUT"; then
                _g11_cpu_set_capability_result unsupported \
                    G11_CPU_CAP_MODEL_UNAVAILABLE \
                    'QEMU does not provide the requested CPU model'
            else
                _g11_cpu_set_capability_result unsupported \
                    G11_CPU_CAP_COMPAT_FAILED \
                    'CPU model failed even with enforce=off'
            fi
            ;;
    esac
    return 1
}

g11_cpu_realization_gate() {
    local qemu_bin=${1:-} cpu_model=${2:-} lifecycle=${3:-}
    local probe_rc

    G11_CPU_GATE_DECISION=deny
    G11_CPU_GATE_REASON=G11_CPU_GATE_NOT_RUN

    case "$lifecycle" in
        new|legacy) ;;
        *)
            _g11_cpu_reset_result "$cpu_model"
            G11_CPU_GATE_REASON=G11_CPU_GATE_INVALID_LIFECYCLE
            return 1
            ;;
    esac

    if g11_cpu_capability_probe "$qemu_bin" "$cpu_model"; then
        probe_rc=0
    else
        probe_rc=$?
    fi

    if (( probe_rc != 0 )); then
        G11_CPU_GATE_REASON=G11_CPU_GATE_CAPABILITY_DENIED
        return 1
    fi

    case "$G11_CPU_CAPABILITY_CLASS:$lifecycle" in
        supported:new|supported:legacy)
            G11_CPU_GATE_DECISION=allow
            G11_CPU_GATE_REASON=G11_CPU_GATE_ALLOW_ENFORCED
            return 0
            ;;
        compatibility:legacy)
            G11_CPU_GATE_DECISION=allow
            G11_CPU_GATE_REASON=G11_CPU_GATE_ALLOW_LEGACY_COMPATIBILITY
            return 0
            ;;
        compatibility:new)
            G11_CPU_GATE_REASON=G11_CPU_GATE_NEW_REQUIRES_ENFORCED
            return 1
            ;;
    esac

    G11_CPU_GATE_REASON=G11_CPU_GATE_CAPABILITY_DENIED
    return 1
}

g11_cpu_capability_report() {
    printf 'class=%s reason=%s model=%s decision=%s gate_reason=%s\n' \
        "${G11_CPU_CAPABILITY_CLASS:-unavailable}" \
        "${G11_CPU_CAPABILITY_REASON:-G11_CPU_CAP_PROBE_NOT_RUN}" \
        "${G11_CPU_CAPABILITY_MODEL:-unknown}" \
        "${G11_CPU_GATE_DECISION:-deny}" \
        "${G11_CPU_GATE_REASON:-G11_CPU_GATE_NOT_RUN}"
}

g11_tsc_frequency_within_250ppm() {
    local current_khz=${1:-0} requested_khz=${2:-0} delta

    [[ "$current_khz" =~ ^[1-9][0-9]*$ &&
       "$requested_khz" =~ ^[1-9][0-9]*$ ]] || return 1
    if ((current_khz >= requested_khz)); then
        delta=$((current_khz - requested_khz))
    else
        delta=$((requested_khz - current_khz))
    fi
    ((delta * 1000000 <= current_khz * 250))
}

g11_kvm_tsc_probe() {
    local helper=${1:-} output rc=0

    # Tests and controlled deployments may inject the complete fixed tuple.
    if [[ "$G11_KVM_CAPABILITIES_INJECTED" == 1 &&
          "$G11_KVM_TSC_CONTROL" =~ ^[01]$ &&
          "$G11_KVM_AVAILABLE" =~ ^[01]$ &&
          "${G11_KVM_GET_TSC_KHZ:-0}" =~ ^[01]$ &&
          "${G11_KVM_TSC_KHZ:-0}" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    [[ -f "$helper" && ! -L "$helper" && -r "$helper" ]] || {
        G11_KVM_ERROR='KVM TSC capability helper is unavailable'
        return 1
    }
    command -v python3 >/dev/null 2>&1 || {
        G11_KVM_ERROR='python3 is unavailable'
        return 1
    }
    if output=$(python3 "$helper" --format shell 2>/dev/null); then
        rc=0
    else
        rc=$?
    fi
    # The helper emits only five fixed assignments and single-quotes its sole
    # string.  Reject any unexpected line before evaluating that closed ABI.
    if grep -Evq "^(G11_KVM_(AVAILABLE|TSC_CONTROL|GET_TSC_KHZ|TSC_KHZ)=[0-9]+|G11_KVM_ERROR='([^']|'\"'\"')*')$" <<<"$output"; then
        G11_KVM_ERROR='KVM TSC helper returned an invalid protocol'
        return 1
    fi
    eval "$output"
    [[ "$G11_KVM_AVAILABLE" =~ ^[01]$ &&
       "$G11_KVM_TSC_CONTROL" =~ ^[01]$ &&
       "$G11_KVM_GET_TSC_KHZ" =~ ^[01]$ &&
       "$G11_KVM_TSC_KHZ" =~ ^[0-9]+$ ]] || return 1
    ((rc == 0 && G11_KVM_AVAILABLE == 1))
}

g11_tsc_policy_resolve() {
    local helper=${1:-} profile_hz=${2:-} policy=${3:-auto}
    local profile_khz

    G11_TSC_QEMU_OPTION=
    G11_TSC_EFFECTIVE_HZ=
    G11_TSC_RUNTIME_SOURCE=
    [[ "$profile_hz" =~ ^[1-9][0-9]*$ &&
       "$profile_hz" -ge 100000000 && "$profile_hz" -le 10000000000 ]] || {
        G11_KVM_ERROR='profile TSC frequency is outside 100MHz..10GHz'
        return 2
    }
    case "$policy" in auto|profile|host|omit) ;; *) return 2 ;; esac
    profile_khz=$((profile_hz / 1000))

    if [[ "${DRY_RUN:-0}" == 1 && "$G11_KVM_CAPABILITIES_INJECTED" == 0 ]]; then
        if [[ "$policy" == omit ]]; then
            G11_TSC_RUNTIME_SOURCE=omitted-dry-run
        else
            G11_TSC_QEMU_OPTION="tsc-freq=${profile_hz}"
            G11_TSC_EFFECTIVE_HZ=$profile_hz
            G11_TSC_RUNTIME_SOURCE=profile-dry-run
        fi
        return 0
    fi
    g11_kvm_tsc_probe "$helper" || return 1

    case "$policy" in
        omit)
            G11_TSC_RUNTIME_SOURCE=host-implicit
            return 0
            ;;
        host)
            ((G11_KVM_GET_TSC_KHZ == 1 && G11_KVM_TSC_KHZ > 0)) || return 1
            G11_TSC_EFFECTIVE_HZ=$((G11_KVM_TSC_KHZ * 1000))
            G11_TSC_QEMU_OPTION="tsc-freq=${G11_TSC_EFFECTIVE_HZ}"
            G11_TSC_RUNTIME_SOURCE=host-explicit
            return 0
            ;;
        auto|profile)
            if ((G11_KVM_TSC_CONTROL == 1)) ||
                    g11_tsc_frequency_within_250ppm \
                        "$G11_KVM_TSC_KHZ" "$profile_khz"; then
                G11_TSC_EFFECTIVE_HZ=$profile_hz
                G11_TSC_QEMU_OPTION="tsc-freq=${profile_hz}"
                G11_TSC_RUNTIME_SOURCE=profile-stable
                return 0
            fi
            ;;
    esac

    [[ "$policy" == auto ]] || return 1
    ((G11_KVM_GET_TSC_KHZ == 1 && G11_KVM_TSC_KHZ > 0)) || return 1
    # No scaling: use the invariant host TSC explicitly instead of asking KVM
    # for an impossible ratio.  Execution frequency remains independently
    # dynamic and may turbo above or idle below this reference clock.
    G11_TSC_EFFECTIVE_HZ=$((G11_KVM_TSC_KHZ * 1000))
    G11_TSC_QEMU_OPTION="tsc-freq=${G11_TSC_EFFECTIVE_HZ}"
    G11_TSC_RUNTIME_SOURCE=host-fallback-no-scaling
}
