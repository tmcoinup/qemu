#!/usr/bin/env bash
# shellcheck disable=SC2034  # Public path/argv variables are consumed by callers.
# TPM 1.2/2.0 lifecycle helpers for the root deploy/*.sh vGPU workflow.
#
# Callers normally do:
#
#   source "$here/lib/vm-tpm.sh"
#   vm_tpm_start "$VM_ID" "$QEMU_BIN" "${DRY_RUN:-0}"
#   QEMU_ARGS+=( "${VM_TPM_QEMU_ARGS[@]}" )
#   # After QEMU has stopped (or when its launch fails):
#   vm_tpm_cleanup "$VM_ID"
#
# A real vm_tpm_start performs dependency/capability probes before making
# changes.  In dry-run mode it is a pure planning operation: it does not even
# require swtpm to be installed, and creates no directory, state, socket, PID
# file, log, lock, or daemon.

if ! declare -F vm_storage_init >/dev/null 2>&1; then
    _vm_tpm_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=deploy/lib/vm-storage.sh
    source "$_vm_tpm_lib_dir/vm-storage.sh"
    unset _vm_tpm_lib_dir
fi

declare -ag VM_TPM_QEMU_ARGS=()
declare -ag VM_TPM_MATCHED_PIDS=()

_vm_tpm_error() {
    echo "[vm-tpm] $*" >&2
}

_vm_tpm_validate_bool() {
    local value=${1:-} label=${2:-value}

    [[ "$value" == 0 || "$value" == 1 ]] || {
        _vm_tpm_error "$label must be 0 or 1 (got: ${value:-<empty>})"
        return 2
    }
}

_vm_tpm_resolve_version() {
    local version=${VM_TPM_VERSION:-2.0}

    case "$version" in
        1.2|2.0)
            VM_TPM_VERSION=$version
            ;;
        *)
            _vm_tpm_error "VM_TPM_VERSION must be 1.2 or 2.0 (got: ${version:-<empty>})"
            return 2
            ;;
    esac
    if [[ "$version" == 1.2 ]]; then
        VM_TPM_STATE_BASENAME=tpm-00.permall
        VM_TPM_QEMU_DEVICE=tpm-tis
    else
        VM_TPM_STATE_BASENAME=tpm2-00.permall
        VM_TPM_QEMU_DEVICE=tpm-crb
    fi
    export VM_TPM_VERSION VM_TPM_STATE_BASENAME VM_TPM_QEMU_DEVICE
}

_vm_tpm_validate_tuning() {
    local attempts=${VM_TPM_START_ATTEMPTS:-30}
    local stop_attempts=${VM_TPM_STOP_ATTEMPTS:-10}
    local interval=${VM_TPM_POLL_INTERVAL:-0.1}
    local lock_wait=${VM_TPM_LOCK_WAIT_SECONDS:-5}
    local log_level=${VM_TPM_LOG_LEVEL:-20}
    local min_state_bytes=${VM_TPM_MIN_STATE_BYTES:-3000}

    _vm_tpm_resolve_version || return
    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || {
        _vm_tpm_error "VM_TPM_START_ATTEMPTS must be a positive integer"
        return 2
    }
    [[ "$stop_attempts" =~ ^[1-9][0-9]*$ ]] || {
        _vm_tpm_error "VM_TPM_STOP_ATTEMPTS must be a positive integer"
        return 2
    }
    [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        _vm_tpm_error "VM_TPM_POLL_INTERVAL must be a non-negative number"
        return 2
    }
    [[ "$lock_wait" =~ ^[0-9]+$ ]] || {
        _vm_tpm_error "VM_TPM_LOCK_WAIT_SECONDS must be a non-negative integer"
        return 2
    }
    [[ "$log_level" =~ ^[0-9]+$ ]] || {
        _vm_tpm_error "VM_TPM_LOG_LEVEL must be a non-negative integer"
        return 2
    }
    [[ "$min_state_bytes" =~ ^[1-9][0-9]*$ ]] || {
        _vm_tpm_error "VM_TPM_MIN_STATE_BYTES must be a positive integer"
        return 2
    }
}

_vm_tpm_validate_id_name() {
    local value=$1 label=$2

    [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]] || {
        _vm_tpm_error "$label is not a valid QEMU id: $value"
        return 2
    }
}

_vm_tpm_validate_path_text() {
    local path=$1 label=$2

    case "$path" in
        *$'\n'*|*','*|*'#'*)
            _vm_tpm_error "$label contains ',', '#', or newline unsupported by QEMU/swtpm config: $path"
            return 2
            ;;
    esac
}

# Resolve and export all canonical per-instance paths without touching disk.
vm_tpm_paths() {
    local id=${1:-} instance_dir run_dir log_dir socket_bytes

    vm_storage_init
    vm_storage_validate_id "$id" || return

    instance_dir=$(vm_storage_instance_dir "$id") || return
    run_dir=$(vm_storage_instance_run_dir "$id") || return
    log_dir=$(vm_storage_instance_log_dir "$id") || return

    VM_TPM_INSTANCE_ID=$id
    VM_TPM_INSTANCE_DIR=$instance_dir
    VM_TPM_ROOT_DIR=$instance_dir/tpm
    VM_TPM_STATE_DIR=$VM_TPM_ROOT_DIR/state
    VM_TPM_CONFIG_DIR=$VM_TPM_ROOT_DIR/config
    VM_TPM_SETUP_CONFIG=$VM_TPM_CONFIG_DIR/swtpm_setup.conf
    VM_TPM_LOCALCA_CONFIG=$VM_TPM_CONFIG_DIR/swtpm-localca.conf
    VM_TPM_LOCALCA_OPTIONS=$VM_TPM_CONFIG_DIR/swtpm-localca.options
    VM_TPM_SOCKET=$run_dir/swtpm.sock
    VM_TPM_PID_FILE=$run_dir/swtpm.pid
    VM_TPM_LOG=$log_dir/swtpm.log
    VM_TPM_LOCK_FILE=$VM_RUN_DIR/vm${id}.tpm.lock

    _vm_tpm_validate_path_text "$VM_TPM_STATE_DIR" "TPM state path" || return
    _vm_tpm_validate_path_text "$VM_TPM_CONFIG_DIR" "TPM config path" || return
    _vm_tpm_validate_path_text "$VM_TPM_SOCKET" "TPM socket path" || return
    _vm_tpm_validate_path_text "$VM_TPM_PID_FILE" "TPM PID path" || return
    _vm_tpm_validate_path_text "$VM_TPM_LOG" "TPM log path" || return

    # Linux sockaddr_un.sun_path is 108 bytes including the trailing NUL.
    # Bash's ${#var} counts characters in a UTF-8 locale, while the kernel
    # limit is bytes.  Count under the C locale so non-ASCII VM_ROOT paths do
    # not slip past the guard.
    socket_bytes=$(LC_ALL=C printf '%s' "$VM_TPM_SOCKET" | wc -c)
    if (( socket_bytes > 107 )); then
        _vm_tpm_error "TPM socket path exceeds the 107-byte Unix-socket limit: $VM_TPM_SOCKET"
        return 2
    fi

    export VM_TPM_INSTANCE_ID VM_TPM_INSTANCE_DIR VM_TPM_ROOT_DIR
    export VM_TPM_STATE_DIR VM_TPM_CONFIG_DIR VM_TPM_SETUP_CONFIG
    export VM_TPM_LOCALCA_CONFIG VM_TPM_LOCALCA_OPTIONS
    export VM_TPM_SOCKET VM_TPM_PID_FILE VM_TPM_LOG
    export VM_TPM_LOCK_FILE
}

# Build the QEMU arguments for the configured TPM generation.  TPM 1.2 uses
# the legacy TIS device; TPM 2.0 uses CRB.  This is a pure planning operation
# and is safe to call even when swtpm is not installed.
vm_tpm_plan() {
    local id=${1:-}

    _vm_tpm_resolve_version || return
    vm_tpm_paths "$id" || return
    : "${VM_TPM_CHARDEV_ID:=chrtpm}"
    : "${VM_TPM_DEVICE_ID:=tpm0}"
    _vm_tpm_validate_id_name "$VM_TPM_CHARDEV_ID" VM_TPM_CHARDEV_ID || return
    _vm_tpm_validate_id_name "$VM_TPM_DEVICE_ID" VM_TPM_DEVICE_ID || return

    VM_TPM_QEMU_ARGS=(
        -chardev "socket,id=$VM_TPM_CHARDEV_ID,path=$VM_TPM_SOCKET"
        -tpmdev "emulator,id=$VM_TPM_DEVICE_ID,chardev=$VM_TPM_CHARDEV_ID"
        -device "$VM_TPM_QEMU_DEVICE,tpmdev=$VM_TPM_DEVICE_ID"
    )
}

_vm_tpm_resolve_executable() {
    local requested=$1 fallback=$2 resolved

    [[ -n "$requested" ]] || requested=$fallback
    if [[ "$requested" == */* ]]; then
        [[ -x "$requested" && ! -d "$requested" ]] || return 1
        readlink -f -- "$requested"
    else
        resolved=$(command -v -- "$requested" 2>/dev/null) || return 1
        [[ -x "$resolved" && ! -d "$resolved" ]] || return 1
        readlink -f -- "$resolved"
    fi
}

_vm_tpm_require_output_token() {
    local output=$1 token=$2 label=$3

    [[ "$output" == *"$token"* ]] || {
        _vm_tpm_error "$label does not advertise required capability: $token"
        return 1
    }
}

# Verify host tools, support for the selected TPM generation, all command-line
# options used below, and (when supplied) QEMU's matching TPM device.
vm_tpm_check_dependencies() {
    local qemu_requested=${1:-${VM_TPM_QEMU_BIN:-}}
    local swtpm_requested=${VM_TPM_SWTPM_BIN:-}
    local setup_requested=${VM_TPM_SETUP_BIN:-}
    local localca_requested=${VM_TPM_LOCALCA_BIN:-}
    local swtpm_bin setup_bin localca_bin qemu_bin swtpm_caps setup_caps
    local swtpm_help setup_help qemu_tpm_help qemu_device_help token tool
    local capability

    _vm_tpm_resolve_version || return
    capability=tpm-$VM_TPM_VERSION

    if (( BASH_VERSINFO[0] < 4 )); then
        _vm_tpm_error "Bash 4 or newer is required"
        return 1
    fi
    for tool in flock mktemp pgrep readlink stat; do
        command -v -- "$tool" >/dev/null 2>&1 || {
            _vm_tpm_error "required host tool is missing: $tool"
            return 1
        }
    done

    swtpm_bin=$(_vm_tpm_resolve_executable "$swtpm_requested" swtpm) || {
        _vm_tpm_error "swtpm is missing (install packages: swtpm swtpm-tools)"
        return 1
    }
    setup_bin=$(_vm_tpm_resolve_executable "$setup_requested" swtpm_setup) || {
        _vm_tpm_error "swtpm_setup is missing (install package: swtpm-tools)"
        return 1
    }
    localca_bin=$(_vm_tpm_resolve_executable "$localca_requested" swtpm_localca) || {
        _vm_tpm_error "swtpm_localca is missing (install package: swtpm-tools)"
        return 1
    }

    if ! swtpm_caps=$(LC_ALL=C "$swtpm_bin" socket --print-capabilities 2>&1); then
        _vm_tpm_error "swtpm capability probe failed: $swtpm_bin"
        return 1
    fi
    if ! setup_caps=$(LC_ALL=C "$setup_bin" --print-capabilities 2>&1); then
        _vm_tpm_error "swtpm_setup capability probe failed: $setup_bin"
        return 1
    fi
    _vm_tpm_require_output_token "$swtpm_caps" "$capability" swtpm || return
    _vm_tpm_require_output_token "$setup_caps" "$capability" swtpm_setup || return

    swtpm_help=$(LC_ALL=C "$swtpm_bin" socket --help 2>&1 || true)
    for token in --tpmstate --ctrl terminate --pid --log --daemon; do
        _vm_tpm_require_output_token "$swtpm_help" "$token" swtpm || return
    done
    if [[ "$VM_TPM_VERSION" == 2.0 ]]; then
        _vm_tpm_require_output_token "$swtpm_help" --tpm2 swtpm || return
    fi
    setup_help=$(LC_ALL=C "$setup_bin" --help 2>&1 || true)
    for token in --tpmstate --tpm --create-ek-cert \
            --create-platform-cert --lock-nvram --overwrite \
            --create-config-files --config; do
        _vm_tpm_require_output_token "$setup_help" "$token" swtpm_setup || return
    done
    if [[ "$VM_TPM_VERSION" == 2.0 ]]; then
        _vm_tpm_require_output_token "$setup_help" --tpm2 swtpm_setup || return
    fi

    if [[ -n "$qemu_requested" ]]; then
        qemu_bin=$(_vm_tpm_resolve_executable "$qemu_requested" "$qemu_requested") || {
            _vm_tpm_error "QEMU binary is missing or not executable: $qemu_requested"
            return 1
        }
        qemu_tpm_help=$(LC_ALL=C "$qemu_bin" -tpmdev help 2>&1 || true)
        _vm_tpm_require_output_token "$qemu_tpm_help" emulator QEMU || return
        qemu_device_help=$(LC_ALL=C "$qemu_bin" -device help 2>&1 || true)
        _vm_tpm_require_output_token "$qemu_device_help" "$VM_TPM_QEMU_DEVICE" QEMU || return
        VM_TPM_QEMU_BIN=$qemu_bin
        export VM_TPM_QEMU_BIN
    fi

    VM_TPM_SWTPM_BIN=$swtpm_bin
    VM_TPM_SETUP_BIN=$setup_bin
    VM_TPM_LOCALCA_BIN=$localca_bin
    export VM_TPM_SWTPM_BIN VM_TPM_SETUP_BIN VM_TPM_LOCALCA_BIN
}

_vm_tpm_validate_existing_paths() {
    local candidate label bad_link

    for candidate in "$VM_TPM_INSTANCE_DIR" "$VM_TPM_ROOT_DIR" \
            "$VM_TPM_STATE_DIR" "$VM_TPM_CONFIG_DIR"; do
        if [[ -L "$candidate" || ( -e "$candidate" && ! -d "$candidate" ) ]]; then
            _vm_tpm_error "managed TPM directory is unsafe: $candidate"
            return 1
        fi
    done

    for candidate in "$VM_TPM_PID_FILE" "$VM_TPM_LOG"; do
        if [[ -L "$candidate" || ( -e "$candidate" && ! -f "$candidate" ) ]]; then
            _vm_tpm_error "managed TPM file is unsafe: $candidate"
            return 1
        fi
    done
    for candidate in "$VM_TPM_SETUP_CONFIG" "$VM_TPM_LOCALCA_CONFIG" \
            "$VM_TPM_LOCALCA_OPTIONS"; do
        if [[ -L "$candidate" || ( -e "$candidate" && ! -f "$candidate" ) ]]; then
            _vm_tpm_error "managed TPM config file is unsafe: $candidate"
            return 1
        fi
    done
    if [[ -L "$VM_TPM_SOCKET" || ( -e "$VM_TPM_SOCKET" && ! -S "$VM_TPM_SOCKET" ) ]]; then
        _vm_tpm_error "managed TPM socket path is unsafe: $VM_TPM_SOCKET"
        return 1
    fi

    if [[ -d "$VM_TPM_STATE_DIR" ]]; then
        bad_link=$(find "$VM_TPM_STATE_DIR" -mindepth 1 -maxdepth 1 \
            -type l -print -quit 2>/dev/null || true)
        if [[ -n "$bad_link" ]]; then
            _vm_tpm_error "TPM state contains a symbolic link: $bad_link"
            return 1
        fi
    fi

    label=${VM_TPM_LOCK_FILE:-}
    if [[ -n "$label" && -L "$label" ]]; then
        _vm_tpm_error "TPM lifecycle lock must not be a symbolic link: $label"
        return 1
    fi
}

_vm_tpm_ensure_lock_root() {
    if [[ -L "$VM_RUN_DIR" || ( -e "$VM_RUN_DIR" && ! -d "$VM_RUN_DIR" ) ]]; then
        _vm_tpm_error "VM runtime root must be a real directory: $VM_RUN_DIR"
        return 1
    fi
    mkdir -p -- "$VM_RUN_DIR"
}

_vm_tpm_prepare_filesystem() {
    vm_storage_validate_instance_tree "$VM_TPM_INSTANCE_ID" || return
    vm_storage_prepare_instance "$VM_TPM_INSTANCE_ID" || return
    _vm_tpm_validate_existing_paths || return
    mkdir -p -- "$VM_TPM_ROOT_DIR"
    chmod 0700 -- "$VM_TPM_ROOT_DIR"
}

_vm_tpm_acquire_lock() {
    local wait_seconds=${VM_TPM_LOCK_WAIT_SECONDS:-5}

    _vm_tpm_validate_tuning || return
    _vm_tpm_ensure_lock_root || return
    _vm_tpm_validate_existing_paths || return
    unset VM_TPM_LOCK_FD
    exec {VM_TPM_LOCK_FD}>"$VM_TPM_LOCK_FILE" || {
        _vm_tpm_error "cannot open TPM lifecycle lock: $VM_TPM_LOCK_FILE"
        return 1
    }
    if ! flock -w "$wait_seconds" "$VM_TPM_LOCK_FD"; then
        _vm_tpm_error "timed out waiting for TPM lifecycle lock: $VM_TPM_LOCK_FILE"
        exec {VM_TPM_LOCK_FD}>&-
        unset VM_TPM_LOCK_FD
        return 1
    fi
}

_vm_tpm_release_lock() {
    if [[ -n "${VM_TPM_LOCK_FD:-}" ]]; then
        flock -u "$VM_TPM_LOCK_FD" 2>/dev/null || true
        exec {VM_TPM_LOCK_FD}>&-
        unset VM_TPM_LOCK_FD
    fi
}

_vm_tpm_process_matches() {
    local pid=$1 proc_root=${VM_TPM_PROC_ROOT:-/proc}
    local proc=$proc_root/$pid exe state_arg ctrl_arg pid_arg
    local -a argv=()
    local i have_state=0 have_ctrl=0 have_pid=0 have_tpm2=0 have_terminate=0

    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "$proc/cmdline" ]] || return 1
    exe=$(readlink -f -- "$proc/exe" 2>/dev/null) || return 1
    exe=${exe% (deleted)}
    [[ "${exe##*/}" == swtpm ]] || return 1
    mapfile -d '' -t argv <"$proc/cmdline" 2>/dev/null || return 1
    [[ "${argv[1]:-}" == socket ]] || return 1

    state_arg="dir=$VM_TPM_STATE_DIR,mode=0600"
    ctrl_arg="type=unixio,path=$VM_TPM_SOCKET,mode=0600"
    pid_arg="file=$VM_TPM_PID_FILE"
    for ((i = 0; i < ${#argv[@]}; i++)); do
        case "${argv[$i]}" in
            --tpmstate)
                [[ "${argv[$((i + 1))]:-}" == "$state_arg" ]] && have_state=1
                ;;
            --ctrl)
                [[ "${argv[$((i + 1))]:-}" == "$ctrl_arg" ]] && have_ctrl=1
                ;;
            --pid)
                [[ "${argv[$((i + 1))]:-}" == "$pid_arg" ]] && have_pid=1
                ;;
            --tpm2) have_tpm2=1 ;;
            --terminate) have_terminate=1 ;;
        esac
    done
    (( have_state && have_ctrl && have_pid && have_terminate )) || return 1
    # Cleanup/inspection may be invoked independently of start-vm.sh.  In that
    # case accept either generation, while still requiring the exact canonical
    # state/socket/PID tuple above.  Startup readiness remains generation-exact.
    if [[ "${VM_TPM_MATCH_ANY_VERSION:-0}" == 1 ]]; then
        return 0
    elif [[ "$VM_TPM_VERSION" == 2.0 ]]; then
        (( have_tpm2 ))
    else
        (( ! have_tpm2 ))
    fi
}

_vm_tpm_collect_matching_pids() {
    local proc_root=${VM_TPM_PROC_ROOT:-/proc} proc pid pid_file_value=""
    local -a candidates=()
    local -A seen=()

    VM_TPM_MATCHED_PIDS=()
    if [[ -f "$VM_TPM_PID_FILE" && ! -L "$VM_TPM_PID_FILE" ]]; then
        pid_file_value=$(<"$VM_TPM_PID_FILE")
        if [[ "$pid_file_value" =~ ^[1-9][0-9]*$ ]] \
                && _vm_tpm_process_matches "$pid_file_value"; then
            seen[$pid_file_value]=1
            VM_TPM_MATCHED_PIDS+=("$pid_file_value")
        fi
    fi

    if [[ "$proc_root" == /proc ]] && command -v pgrep >/dev/null 2>&1; then
        mapfile -t candidates < <(pgrep -x swtpm 2>/dev/null || true)
    else
        for proc in "$proc_root"/[0-9]*; do
            [[ -d "$proc" ]] || continue
            candidates+=("${proc##*/}")
        done
    fi

    for pid in "${candidates[@]}"; do
        [[ -z "${seen[$pid]:-}" ]] || continue
        if _vm_tpm_process_matches "$pid"; then
            seen[$pid]=1
            VM_TPM_MATCHED_PIDS+=("$pid")
        fi
    done
}

_vm_tpm_qemu_uses_socket() {
    local proc_root=${VM_TPM_PROC_ROOT:-/proc} proc pid exe base argv0_base arg expected
    local -a argv=() candidates=()

    expected="socket,id=$VM_TPM_CHARDEV_ID,path=$VM_TPM_SOCKET"
    if [[ "$proc_root" == /proc ]] && command -v pgrep >/dev/null 2>&1; then
        mapfile -t candidates < <(
            pgrep -f '(^|/)qemu-system-' 2>/dev/null || true
        )
    else
        for proc in "$proc_root"/[0-9]*; do
            [[ -d "$proc" ]] || continue
            candidates+=("${proc##*/}")
        done
    fi

    for pid in "${candidates[@]}"; do
        proc=$proc_root/$pid
        [[ -r "$proc/cmdline" ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        exe=${exe% (deleted)}
        base=${exe##*/}
        mapfile -d '' -t argv <"$proc/cmdline" 2>/dev/null || continue
        argv0_base=${argv[0]:-}
        argv0_base=${argv0_base##*/}
        if [[ "$base" != qemu-system-* && "$argv0_base" != qemu-system-* ]]; then
            continue
        fi
        for arg in "${argv[@]}"; do
            [[ "$arg" == "$expected" ]] && return 0
        done
    done
    return 1
}

_vm_tpm_remove_runtime_files() {
    if [[ -L "$VM_TPM_PID_FILE" || ( -e "$VM_TPM_PID_FILE" && ! -f "$VM_TPM_PID_FILE" ) ]]; then
        _vm_tpm_error "refusing to remove unsafe TPM PID path: $VM_TPM_PID_FILE"
        return 1
    fi
    if [[ -L "$VM_TPM_SOCKET" || ( -e "$VM_TPM_SOCKET" && ! -S "$VM_TPM_SOCKET" ) ]]; then
        _vm_tpm_error "refusing to remove unsafe TPM socket path: $VM_TPM_SOCKET"
        return 1
    fi
    rm -f -- "$VM_TPM_PID_FILE" "$VM_TPM_SOCKET"
}

_vm_tpm_cleanup_locked() {
    local attempt stop_attempts=${VM_TPM_STOP_ATTEMPTS:-10}
    local interval=${VM_TPM_POLL_INTERVAL:-0.1}
    local VM_TPM_MATCH_ANY_VERSION=1

    _vm_tpm_validate_existing_paths || return
    if _vm_tpm_qemu_uses_socket; then
        _vm_tpm_error "QEMU still owns the TPM socket; cleanup refused: $VM_TPM_SOCKET"
        return 1
    fi

    _vm_tpm_collect_matching_pids
    if (( ${#VM_TPM_MATCHED_PIDS[@]} == 0 )); then
        _vm_tpm_remove_runtime_files
        return
    fi
    echo "[vm-tpm] stopping swtpm for vm${VM_TPM_INSTANCE_ID}: ${VM_TPM_MATCHED_PIDS[*]}"
    kill -TERM -- "${VM_TPM_MATCHED_PIDS[@]}" 2>/dev/null || true

    for ((attempt = 0; attempt < stop_attempts; attempt++)); do
        _vm_tpm_collect_matching_pids
        (( ${#VM_TPM_MATCHED_PIDS[@]} == 0 )) && break
        sleep "$interval"
    done

    if (( ${#VM_TPM_MATCHED_PIDS[@]} )); then
        # Revalidation immediately before SIGKILL protects against PID reuse.
        kill -KILL -- "${VM_TPM_MATCHED_PIDS[@]}" 2>/dev/null || true
        sleep "$interval"
        _vm_tpm_collect_matching_pids
    fi
    if (( ${#VM_TPM_MATCHED_PIDS[@]} )); then
        _vm_tpm_error "swtpm did not stop: ${VM_TPM_MATCHED_PIDS[*]}"
        return 1
    fi

    _vm_tpm_remove_runtime_files
}

_vm_tpm_remove_init_stage() {
    local stage=$1

    case "$stage" in
        "$VM_TPM_ROOT_DIR"/.state.init.*)
            if [[ -d "$stage" && ! -L "$stage" ]]; then
                rm -rf -- "$stage"
            fi
            ;;
    esac
}

_vm_tpm_quote_option_value() {
    local value=$1

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

_vm_tpm_validate_platform_value() {
    local value=$1 label=$2

    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
        _vm_tpm_error "$label must be non-empty and contain no newline"
        return 2
    }
}

_vm_tpm_rewrite_platform_options() {
    local manufacturer=${VM_TPM_PLATFORM_MANUFACTURER:-${BOARD_BRAND:-${BOARD_MFR:-QEMU}}}
    local model=${VM_TPM_PLATFORM_MODEL:-${BOARD_MODEL:-Q35}}
    local version=${VM_TPM_PLATFORM_VERSION:-${BIOS_VER:-1.0}}
    local temp=$VM_TPM_CONFIG_DIR/.swtpm-localca.options.tmp.$$
    local line seen_manufacturer=0 seen_model=0 seen_version=0
    local quoted_manufacturer quoted_model quoted_version

    _vm_tpm_validate_platform_value "$manufacturer" VM_TPM_PLATFORM_MANUFACTURER || return
    _vm_tpm_validate_platform_value "$model" VM_TPM_PLATFORM_MODEL || return
    _vm_tpm_validate_platform_value "$version" VM_TPM_PLATFORM_VERSION || return
    quoted_manufacturer=$(_vm_tpm_quote_option_value "$manufacturer")
    quoted_model=$(_vm_tpm_quote_option_value "$model")
    quoted_version=$(_vm_tpm_quote_option_value "$version")

    : >"$temp" || return
    chmod 0600 -- "$temp"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            --platform-manufacturer*)
                printf '%s %s\n' --platform-manufacturer "$quoted_manufacturer" >>"$temp"
                seen_manufacturer=1
                ;;
            --platform-model*)
                printf '%s %s\n' --platform-model "$quoted_model" >>"$temp"
                seen_model=1
                ;;
            --platform-version*)
                printf '%s %s\n' --platform-version "$quoted_version" >>"$temp"
                seen_version=1
                ;;
            *) printf '%s\n' "$line" >>"$temp" ;;
        esac
    done <"$VM_TPM_LOCALCA_OPTIONS"
    (( seen_manufacturer )) \
        || printf '%s %s\n' --platform-manufacturer "$quoted_manufacturer" >>"$temp"
    (( seen_model )) \
        || printf '%s %s\n' --platform-model "$quoted_model" >>"$temp"
    (( seen_version )) \
        || printf '%s %s\n' --platform-version "$quoted_version" >>"$temp"
    mv -- "$temp" "$VM_TPM_LOCALCA_OPTIONS"
}

_vm_tpm_rewrite_setup_config() {
    local temp=$VM_TPM_CONFIG_DIR/.swtpm_setup.conf.tmp.$$
    local line seen_tool=0

    case "$VM_TPM_LOCALCA_BIN" in
        *$'\n'*|*'#'*)
            _vm_tpm_error "swtpm_localca path cannot be represented safely in swtpm_setup.conf"
            return 2
            ;;
    esac

    : >"$temp" || return
    chmod 0600 -- "$temp"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*create_certs_tool[[:space:]]*= ]]; then
            printf 'create_certs_tool = %s\n' "$VM_TPM_LOCALCA_BIN" >>"$temp"
            seen_tool=1
        else
            printf '%s\n' "$line" >>"$temp"
        fi
    done <"$VM_TPM_SETUP_CONFIG"
    (( seen_tool )) \
        || printf 'create_certs_tool = %s\n' "$VM_TPM_LOCALCA_BIN" >>"$temp"
    mv -- "$temp" "$VM_TPM_SETUP_CONFIG"
}

_vm_tpm_prepare_instance_config() {
    local candidate missing=0

    mkdir -p -- "$VM_TPM_CONFIG_DIR"
    chmod 0700 -- "$VM_TPM_CONFIG_DIR"
    for candidate in "$VM_TPM_SETUP_CONFIG" "$VM_TPM_LOCALCA_CONFIG" \
            "$VM_TPM_LOCALCA_OPTIONS"; do
        [[ -f "$candidate" && ! -L "$candidate" ]] || missing=1
    done

    if (( missing )); then
        echo "[vm-tpm] creating private swtpm CA configuration for vm${VM_TPM_INSTANCE_ID}"
        if ! (umask 077; HOME="$VM_TPM_ROOT_DIR" \
                XDG_CONFIG_HOME="$VM_TPM_CONFIG_DIR" \
                "$VM_TPM_SETUP_BIN" --create-config-files overwrite) \
                >>"$VM_TPM_LOG" 2>&1; then
            _vm_tpm_error "cannot create per-instance swtpm configuration; see $VM_TPM_LOG"
            return 1
        fi
    fi

    for candidate in "$VM_TPM_SETUP_CONFIG" "$VM_TPM_LOCALCA_CONFIG" \
            "$VM_TPM_LOCALCA_OPTIONS"; do
        if [[ ! -f "$candidate" || -L "$candidate" ]]; then
            _vm_tpm_error "swtpm did not create a safe per-instance config: $candidate"
            return 1
        fi
        chmod 0600 -- "$candidate"
    done
    _vm_tpm_rewrite_setup_config || return
    _vm_tpm_rewrite_platform_options
}

_vm_tpm_initialize_state() {
    local permall=$VM_TPM_STATE_DIR/$VM_TPM_STATE_BASENAME
    local alternate_basename alternate_version
    local min_state_bytes=${VM_TPM_MIN_STATE_BYTES:-3000}
    local existing stage state_bytes=0 rc=0
    local -a setup_args=()

    if [[ "$VM_TPM_VERSION" == 2.0 ]]; then
        alternate_basename=tpm-00.permall
        alternate_version=1.2
    else
        alternate_basename=tpm2-00.permall
        alternate_version=2.0
    fi

    if [[ -d "$VM_TPM_STATE_DIR" ]]; then
        if [[ -f "$permall" && ! -L "$permall" ]]; then
            state_bytes=$(stat -c %s -- "$permall" 2>/dev/null || echo 0)
            if (( state_bytes >= min_state_bytes )); then
                return 0
            fi
        fi
        if [[ -f "$VM_TPM_STATE_DIR/$alternate_basename" &&
              ! -L "$VM_TPM_STATE_DIR/$alternate_basename" ]]; then
            _vm_tpm_error "persistent TPM $alternate_version state cannot be opened as TPM $VM_TPM_VERSION"
            _vm_tpm_error "back up guest recovery keys, then explicitly migrate/reset TPM state or use a new VM_ID"
            return 1
        fi
        existing=$(find "$VM_TPM_STATE_DIR" -mindepth 1 -maxdepth 1 \
            -print -quit 2>/dev/null || true)
        if [[ -n "$existing" ]]; then
            _vm_tpm_error "TPM state is incomplete; refusing to overwrite it: $VM_TPM_STATE_DIR"
            return 1
        fi
        rmdir -- "$VM_TPM_STATE_DIR" || return
    fi

    _vm_tpm_prepare_instance_config || return
    stage=$(mktemp -d "$VM_TPM_ROOT_DIR/.state.init.XXXXXXXX") || {
        _vm_tpm_error "cannot create temporary TPM state directory"
        return 1
    }
    chmod 0700 -- "$stage"
    if [[ "$VM_TPM_VERSION" == 2.0 ]]; then
        setup_args+=(--tpm2)
    fi
    setup_args+=(
        --tpmstate "$stage"
        --config "$VM_TPM_SETUP_CONFIG"
        --tpm "$VM_TPM_SWTPM_BIN socket"
        --create-ek-cert
        --create-platform-cert
        --lock-nvram
        --overwrite
    )
    echo "[vm-tpm] initializing TPM $VM_TPM_VERSION state for vm${VM_TPM_INSTANCE_ID}"
    if ! (umask 077; HOME="$VM_TPM_ROOT_DIR" \
            XDG_CONFIG_HOME="$VM_TPM_CONFIG_DIR" \
            "$VM_TPM_SETUP_BIN" "${setup_args[@]}") >>"$VM_TPM_LOG" 2>&1; then
        _vm_tpm_error "swtpm_setup failed; see $VM_TPM_LOG"
        rc=1
    elif [[ ! -f "$stage/$VM_TPM_STATE_BASENAME" \
            || -L "$stage/$VM_TPM_STATE_BASENAME" ]]; then
        _vm_tpm_error "swtpm_setup did not create TPM $VM_TPM_VERSION permanent state"
        rc=1
    else
        state_bytes=$(stat -c %s -- "$stage/$VM_TPM_STATE_BASENAME" 2>/dev/null || echo 0)
        if (( state_bytes < min_state_bytes )); then
            _vm_tpm_error "swtpm_setup state is only ${state_bytes} bytes (minimum: ${min_state_bytes})"
            rc=1
        elif [[ -e "$VM_TPM_STATE_DIR" || -L "$VM_TPM_STATE_DIR" ]]; then
            _vm_tpm_error "TPM state appeared concurrently; refusing to replace it"
            rc=1
        elif ! mv -- "$stage" "$VM_TPM_STATE_DIR"; then
            _vm_tpm_error "cannot publish initialized TPM state"
            rc=1
        else
            stage=""
        fi
    fi

    [[ -z "$stage" ]] || _vm_tpm_remove_init_stage "$stage"
    return "$rc"
}

_vm_tpm_launch() {
    local attempts=${VM_TPM_START_ATTEMPTS:-30}
    local interval=${VM_TPM_POLL_INTERVAL:-0.1}
    local log_level=${VM_TPM_LOG_LEVEL:-20}
    local state_arg ctrl_arg pid_arg log_arg attempt pid=""
    local -a swtpm_args=()

    state_arg="dir=$VM_TPM_STATE_DIR,mode=0600"
    ctrl_arg="type=unixio,path=$VM_TPM_SOCKET,mode=0600"
    pid_arg="file=$VM_TPM_PID_FILE"
    log_arg="file=$VM_TPM_LOG,level=$log_level"

    swtpm_args=(
        socket
        --tpmstate "$state_arg"
        --ctrl "$ctrl_arg"
        --terminate
    )
    if [[ "$VM_TPM_VERSION" == 2.0 ]]; then
        swtpm_args+=(--tpm2)
    fi
    swtpm_args+=(
        --pid "$pid_arg"
        --log "$log_arg"
        --daemon
    )
    if ! (umask 077; "$VM_TPM_SWTPM_BIN" "${swtpm_args[@]}"); then
        _vm_tpm_error "swtpm daemon launch failed; see $VM_TPM_LOG"
        _vm_tpm_cleanup_locked || true
        return 1
    fi

    for ((attempt = 0; attempt < attempts; attempt++)); do
        if [[ -S "$VM_TPM_SOCKET" && -f "$VM_TPM_PID_FILE" ]]; then
            pid=$(<"$VM_TPM_PID_FILE")
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && _vm_tpm_process_matches "$pid"; then
                echo "[vm-tpm] TPM $VM_TPM_VERSION ready for vm${VM_TPM_INSTANCE_ID} (socket=$VM_TPM_SOCKET)"
                return 0
            fi
        fi
        sleep "$interval"
    done

    _vm_tpm_error "swtpm did not create a live socket/PID within the startup timeout"
    _vm_tpm_cleanup_locked || true
    return 1
}

_vm_tpm_start_locked() {
    _vm_tpm_prepare_filesystem || return
    _vm_tpm_cleanup_locked || return
    _vm_tpm_initialize_state || return
    _vm_tpm_launch
}

# High-level start/plan entry point.
#   $1: positive VM id
#   $2: QEMU binary (required for a real start, ignored by dry-run)
#   $3: dry-run boolean, default ${DRY_RUN:-0}
# VM_TPM_ENABLED (or compatibility variable TPM) defaults to 1.
vm_tpm_start() {
    local id=${1:-} qemu_bin=${2:-${VM_TPM_QEMU_BIN:-}}
    local dry_run=${3:-${DRY_RUN:-0}}
    local enabled=${VM_TPM_ENABLED:-${TPM:-1}} rc=0

    _vm_tpm_validate_bool "$enabled" VM_TPM_ENABLED || return
    _vm_tpm_validate_bool "$dry_run" DRY_RUN || return
    if [[ "$enabled" == 0 ]]; then
        VM_TPM_QEMU_ARGS=()
        return 0
    fi
    vm_tpm_plan "$id" || return
    _vm_tpm_validate_tuning || return
    if [[ "$dry_run" == 1 ]]; then
        echo "[vm-tpm] DRY_RUN: TPM $VM_TPM_VERSION args planned; host tools, state and daemon untouched"
        return 0
    fi
    [[ -n "$qemu_bin" ]] || {
        _vm_tpm_error "QEMU binary is required for a real TPM start"
        return 2
    }
    vm_tpm_check_dependencies "$qemu_bin" || return

    _vm_tpm_acquire_lock || return
    _vm_tpm_start_locked || rc=$?
    _vm_tpm_release_lock
    return "$rc"
}

# Stop only the daemon that exactly matches this instance's canonical state,
# socket and PID arguments.  A QEMU process using the socket makes cleanup fail
# closed.  Persistent TPM state and the log are never removed.
vm_tpm_cleanup() {
    local id=${1:-} rc=0

    vm_tpm_plan "$id" || return
    _vm_tpm_validate_tuning || return
    _vm_tpm_acquire_lock || return
    _vm_tpm_cleanup_locked || rc=$?
    _vm_tpm_release_lock
    return "$rc"
}

# Return success only when an exact swtpm process for this instance is alive.
vm_tpm_is_running() {
    local id=${1:-}
    local VM_TPM_MATCH_ANY_VERSION=1

    vm_tpm_plan "$id" || return
    _vm_tpm_collect_matching_pids
    (( ${#VM_TPM_MATCHED_PIDS[@]} > 0 ))
}
