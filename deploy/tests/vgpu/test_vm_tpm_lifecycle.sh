#!/usr/bin/env bash
# Exercise the root vGPU workflow's TPM library without a real swtpm, QEMU, or
# host /proc process.  Fake tools still create a real Unix socket so the startup
# readiness path is covered rather than mocked out.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TPM_LIB="$REPO_ROOT/deploy/lib/vm-tpm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_contains() {
    local file=$1 needle=$2 label=$3

    grep -F -- "$needle" "$file" >/dev/null || fail "$label: missing '$needle'"
}

assert_not_exists() {
    local path=$1 label=$2

    [[ ! -e "$path" && ! -L "$path" ]] || fail "$label exists: $path"
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

FAKE_BIN=$TMP_DIR/bin
FAKE_PROC=$TMP_DIR/proc
FAKE_TRACE=$TMP_DIR/fake.trace
KILL_TRACE=$TMP_DIR/kill.trace
mkdir -p "$FAKE_BIN" "$FAKE_PROC"
: >"$FAKE_TRACE"
: >"$KILL_TRACE"

cat >"$FAKE_BIN/swtpm" <<'FAKE_SWTPM'
#!/usr/bin/env bash
set -euo pipefail

original=("$@")
if [[ "${1:-}" == socket && "${2:-}" == --print-capabilities ]]; then
    printf '%s\n' '{"type":"swtpm","features":["tpm-1.2","tpm-2.0"]}'
    exit 0
fi
if [[ "${1:-}" == socket && "${2:-}" == --help ]]; then
    printf '%s\n' '--tpmstate --ctrl --terminate --tpm2 --pid --log --daemon'
    exit 0
fi

printf 'swtpm-launch' >>"$FAKE_TRACE"
printf ' %q' "${original[@]}" >>"$FAKE_TRACE"
printf '\n' >>"$FAKE_TRACE"

state_arg= ctrl_arg= pid_arg= log_arg= is_tpm2=0
while (($#)); do
    case "$1" in
        --tpmstate) state_arg=$2; shift 2 ;;
        --ctrl) ctrl_arg=$2; shift 2 ;;
        --pid) pid_arg=$2; shift 2 ;;
        --log) log_arg=$2; shift 2 ;;
        --tpm2) is_tpm2=1; shift ;;
        --terminate|--daemon) shift ;;
        socket) shift ;;
        *) echo "unexpected fake swtpm option: $1" >&2; exit 91 ;;
    esac
done

[[ "$state_arg" == dir=*,mode=0600 ]] || exit 92
[[ "$ctrl_arg" == type=unixio,path=*,mode=0600 ]] || exit 93
[[ "$ctrl_arg" != *,terminate* ]] || exit 94
state=${state_arg#dir=}
state=${state%,mode=0600}
socket=${ctrl_arg#type=unixio,path=}
socket=${socket%,mode=0600}
pid_file=${pid_arg#file=}
log_file=${log_arg#file=}
log_file=${log_file%,level=*}
if ((is_tpm2)); then
    [[ -s "$state/tpm2-00.permall" ]] || exit 95
else
    [[ -s "$state/tpm-00.permall" ]] || exit 95
fi

pid=$(<"$FAKE_SWTPM_ROOT/next-pid")
printf '%s\n' "$((pid + 1))" >"$FAKE_SWTPM_ROOT/next-pid"
mkdir -p "$FAKE_PROC_ROOT/$pid" "$(dirname "$pid_file")" "$(dirname "$log_file")"
ln -s "$0" "$FAKE_PROC_ROOT/$pid/exe"
{
    printf '%s\0' "$0"
    printf '%s\0' "${original[@]}"
} >"$FAKE_PROC_ROOT/$pid/cmdline"
printf '%s\n' "$pid" >"$pid_file"
printf 'fake swtpm pid=%s\n' "$pid" >>"$log_file"

if [[ "${FAKE_SWTPM_NO_SOCKET:-0}" != 1 ]]; then
    python3 - "$socket" <<'PY'
import socket
import sys

s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.close()
PY
fi
FAKE_SWTPM
chmod +x "$FAKE_BIN/swtpm"

cat >"$FAKE_BIN/swtpm_setup" <<'FAKE_SETUP'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --print-capabilities ]]; then
    printf '%s\n' '{"type":"swtpm_setup","features":["tpm-1.2","tpm-2.0"]}'
    exit 0
fi
if [[ "${1:-}" == --help ]]; then
    printf '%s\n' '--tpmstate --tpm2 --tpm --create-ek-cert --create-platform-cert'
    printf '%s\n' '--lock-nvram --overwrite --create-config-files --config'
    exit 0
fi
if [[ "${1:-}" == --create-config-files ]]; then
    [[ "${2:-}" == overwrite ]]
    printf 'create-config xdg=%s home=%s\n' "$XDG_CONFIG_HOME" "$HOME" >>"$FAKE_TRACE"
    mkdir -p "$XDG_CONFIG_HOME/var/lib/swtpm-localca"
    cat >"$XDG_CONFIG_HOME/swtpm_setup.conf" <<EOF
create_certs_tool = /usr/bin/swtpm_localca
create_certs_tool_config = $XDG_CONFIG_HOME/swtpm-localca.conf
create_certs_tool_options = $XDG_CONFIG_HOME/swtpm-localca.options
EOF
    cat >"$XDG_CONFIG_HOME/swtpm-localca.conf" <<EOF
statedir = $XDG_CONFIG_HOME/var/lib/swtpm-localca
signingkey = $XDG_CONFIG_HOME/var/lib/swtpm-localca/signkey.pem
issuercert = $XDG_CONFIG_HOME/var/lib/swtpm-localca/issuercert.pem
certserial = $XDG_CONFIG_HOME/var/lib/swtpm-localca/certserial
EOF
    cat >"$XDG_CONFIG_HOME/swtpm-localca.options" <<'EOF'
--tpm-manufacturer IBM
--tpm-model swtpm-libtpms
--tpm-version 2
--platform-manufacturer Linux
--platform-version 1.0
--platform-model QEMU
EOF
    exit 0
fi

state= config= tpm_command= is_tpm2=0
while (($#)); do
    case "$1" in
        --tpmstate) state=$2; shift 2 ;;
        --config) config=$2; shift 2 ;;
        --tpm) tpm_command=$2; shift 2 ;;
        --tpm2) is_tpm2=1; shift ;;
        --create-ek-cert|--create-platform-cert|--lock-nvram|--overwrite)
            shift ;;
        *) echo "unexpected fake swtpm_setup option: $1" >&2; exit 81 ;;
    esac
done
[[ "$tpm_command" == "$FAKE_SWTPM socket" ]] || exit 82
[[ "$config" == "$XDG_CONFIG_HOME/swtpm_setup.conf" ]] || exit 83
printf 'setup-state state=%s config=%s tpm=%s xdg=%s\n' \
    "$state" "$config" "$tpm_command" "$XDG_CONFIG_HOME" >>"$FAKE_TRACE"
if ((is_tpm2)); then
    truncate -s 4096 "$state/tpm2-00.permall"
else
    truncate -s 4096 "$state/tpm-00.permall"
fi
FAKE_SETUP
chmod +x "$FAKE_BIN/swtpm_setup"

cat >"$FAKE_BIN/swtpm_localca" <<'FAKE_LOCALCA'
#!/bin/sh
exit 0
FAKE_LOCALCA
chmod +x "$FAKE_BIN/swtpm_localca"

cat >"$FAKE_BIN/qemu-system-x86_64" <<'FAKE_QEMU'
#!/bin/sh
if [ "${1:-}" = -tpmdev ] && [ "${2:-}" = help ]; then
    echo 'name "emulator"'
    exit 1
fi
if [ "${1:-}" = -device ] && [ "${2:-}" = help ]; then
    echo 'name "tpm-crb"'
    echo 'name "tpm-tis"'
    exit 0
fi
exit 97
FAKE_QEMU
chmod +x "$FAKE_BIN/qemu-system-x86_64"

cat >"$FAKE_BIN/bad-swtpm" <<'FAKE_BAD'
#!/bin/sh
if [ "${2:-}" = --print-capabilities ]; then
    echo '{"features":["tpm-1.2","tpm-2.0"]}'
else
    echo '--tpmstate --ctrl --tpm2 --pid --log --daemon'
fi
FAKE_BAD
chmod +x "$FAKE_BIN/bad-swtpm"

export FAKE_PROC_ROOT=$FAKE_PROC
export FAKE_SWTPM_ROOT=$TMP_DIR
export FAKE_TRACE
export FAKE_SWTPM=$FAKE_BIN/swtpm
export FAKE_LOCALCA=$FAKE_BIN/swtpm_localca
printf '%s\n' 4100 >"$TMP_DIR/next-pid"

VM_ROOT="$TMP_DIR/images with spaces/vms"
VM_TPM_PROC_ROOT=$FAKE_PROC
VM_TPM_START_ATTEMPTS=3
VM_TPM_STOP_ATTEMPTS=2
VM_TPM_POLL_INTERVAL=0
VM_TPM_PLATFORM_MANUFACTURER=ASRock
VM_TPM_PLATFORM_MODEL='B360M Pro4'
VM_TPM_PLATFORM_VERSION=4.40
export VM_ROOT VM_TPM_PROC_ROOT VM_TPM_START_ATTEMPTS
export VM_TPM_STOP_ATTEMPTS VM_TPM_POLL_INTERVAL
export VM_TPM_PLATFORM_MANUFACTURER VM_TPM_PLATFORM_MODEL
export VM_TPM_PLATFORM_VERSION

# shellcheck source=deploy/lib/vm-tpm.sh
source "$TPM_LIB"

# Replace the shell builtin only inside this test.  The fake /proc entry is
# removed on TERM/KILL, which models a process exiting without touching a real
# host PID.
kill() {
    local signal=${1:-}
    shift || true
    [[ "${1:-}" == -- ]] && shift
    local pid

    for pid in "$@"; do
        printf '%s %s\n' "$signal" "$pid" >>"$KILL_TRACE"
        rm -rf -- "${FAKE_PROC:?}/$pid"
    done
}

make_socket() {
    local path=$1

    rm -f -- "$path"
    python3 - "$path" <<'PY'
import socket
import sys

s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.close()
PY
}

make_swtpm_proc() {
    local pid=$1 state=$2 socket=$3 pid_file=$4 version=${5:-2.0}
    local ctrl="type=unixio,path=$socket,mode=0600"
    local -a argv=(
        "$FAKE_SWTPM" socket
        --tpmstate "dir=$state,mode=0600"
        --ctrl "$ctrl"
        --terminate
    )
    [[ "$version" == 2.0 ]] && argv+=(--tpm2)
    argv+=(
        --pid "file=$pid_file"
        --log "file=${pid_file%/*}/manual.log,level=20"
        --daemon
    )

    mkdir -p "$FAKE_PROC/$pid" "$(dirname "$pid_file")"
    ln -s "$FAKE_SWTPM" "$FAKE_PROC/$pid/exe"
    printf '%s\0' "${argv[@]}" >"$FAKE_PROC/$pid/cmdline"
}

make_qemu_proc() {
    local pid=$1 socket=$2
    local -a argv=(
        "$FAKE_BIN/qemu-system-x86_64"
        -chardev "socket,id=chrtpm,path=$socket"
    )

    mkdir -p "$FAKE_PROC/$pid"
    ln -s "$FAKE_BIN/qemu-system-x86_64" "$FAKE_PROC/$pid/exe"
    printf '%s\0' "${argv[@]}" >"$FAKE_PROC/$pid/cmdline"
}

# Dry-run must remain useful on a host that has neither swtpm nor QEMU.  It
# builds the complete argv without even creating VM_ROOT.
VM_TPM_SWTPM_BIN=$TMP_DIR/missing/swtpm
VM_TPM_SETUP_BIN=$TMP_DIR/missing/swtpm_setup
VM_TPM_LOCALCA_BIN=$TMP_DIR/missing/swtpm_localca
VM_TPM_VERSION=2.0
vm_tpm_start 41 "$TMP_DIR/missing/qemu" 1 >/dev/null
[[ ${#VM_TPM_QEMU_ARGS[@]} -eq 6 ]] || fail 'dry-run TPM argv length'
[[ "${VM_TPM_QEMU_ARGS[0]}" == -chardev ]] || fail 'dry-run chardev option'
[[ "${VM_TPM_QEMU_ARGS[1]}" == \
    "socket,id=chrtpm,path=$VM_ROOT/vm41/run/swtpm.sock" ]] \
    || fail 'dry-run socket argument'
[[ "${VM_TPM_QEMU_ARGS[3]}" == emulator,id=tpm0,chardev=chrtpm ]] \
    || fail 'dry-run tpmdev argument'
[[ "${VM_TPM_QEMU_ARGS[5]}" == tpm-crb,tpmdev=tpm0 ]] \
    || fail 'dry-run CRB argument'
assert_not_exists "$VM_ROOT" 'dry-run VM root'

VM_TPM_VERSION=1.2
vm_tpm_start 40 "$TMP_DIR/missing/qemu" 1 >/dev/null
[[ ${#VM_TPM_QEMU_ARGS[@]} -eq 6 ]] || fail 'TPM 1.2 dry-run argv length'
[[ "${VM_TPM_QEMU_ARGS[1]}" == \
    "socket,id=chrtpm,path=$VM_ROOT/vm40/run/swtpm.sock" ]] \
    || fail 'TPM 1.2 dry-run socket argument'
[[ "${VM_TPM_QEMU_ARGS[5]}" == tpm-tis,tpmdev=tpm0 ]] \
    || fail 'TPM 1.2 dry-run TIS argument'
assert_not_exists "$VM_ROOT" 'TPM 1.2 dry-run VM root'
VM_TPM_VERSION=2.0

# sockaddr_un is byte-limited.  A UTF-8 path can be under 107 characters but
# over 107 bytes, so the guard must not use the locale's character count.
printf -v UTF8_SEGMENT '测%.0s' {1..30}
if (
    VM_ROOT="$TMP_DIR/$UTF8_SEGMENT/vms"
    unset IMAGE_ROOT ISO_DIR STAGE_DIR VM_INSTANCES_DIR VM_CONFIG_DIR
    unset VM_DISK_DIR VM_BASE_DIR VM_NVRAM_DIR VM_RUN_DIR VM_LOG_DIR
    unset VM_ASSET_DIR VM_SHARED_DIR VM_CONTROL_DIR VM_INSTANCE_DIR
    unset VM_INSTANCE_ID VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR
    unset VM_NVRAM_BACKUP_DIR VM_STORAGE_COMPAT_FALLBACK
    vm_storage_init
    vm_tpm_plan 45
) >"$TMP_DIR/utf8-path.out" 2>"$TMP_DIR/utf8-path.err"; then
    fail 'UTF-8 TPM socket path over 107 bytes was accepted'
fi
assert_file_contains "$TMP_DIR/utf8-path.err" '107-byte Unix-socket limit' \
    'UTF-8 socket byte-length diagnostic'
unset UTF8_SEGMENT

VM_TPM_SWTPM_BIN=$FAKE_SWTPM
VM_TPM_SETUP_BIN=$FAKE_BIN/swtpm_setup
VM_TPM_LOCALCA_BIN=$FAKE_LOCALCA
QEMU_BIN=$FAKE_BIN/qemu-system-x86_64
export VM_TPM_SWTPM_BIN VM_TPM_SETUP_BIN VM_TPM_LOCALCA_BIN QEMU_BIN

# The capability gate must reject a swtpm that cannot terminate with its QEMU
# control connection, before any instance state is created.
VM_TPM_SWTPM_BIN=$FAKE_BIN/bad-swtpm
if vm_tpm_start 42 "$QEMU_BIN" 0 >"$TMP_DIR/bad.out" 2>"$TMP_DIR/bad.err"; then
    fail 'swtpm without --terminate was accepted'
fi
assert_not_exists "$VM_ROOT/vm42" 'failed capability instance'
VM_TPM_SWTPM_BIN=$FAKE_SWTPM

VM_TPM_LOCALCA_BIN=$TMP_DIR/missing/swtpm_localca
if vm_tpm_start 43 "$QEMU_BIN" 0 >"$TMP_DIR/localca.out" 2>"$TMP_DIR/localca.err"; then
    fail 'real start accepted a missing swtpm_localca dependency'
fi
assert_not_exists "$VM_ROOT/vm43" 'missing localca instance'
assert_file_contains "$TMP_DIR/localca.err" 'swtpm_localca is missing' \
    'missing localca diagnostic'
VM_TPM_LOCALCA_BIN=$FAKE_LOCALCA

# First real start: private XDG CA config, transactional TPM2 state, daemon,
# socket wait, PID tracking and QEMU args are all produced.
vm_tpm_start 41 "$QEMU_BIN" 0 >/dev/null
STATE_DIR=$VM_TPM_STATE_DIR
SOCKET=$VM_TPM_SOCKET
PID_FILE=$VM_TPM_PID_FILE
LOG=$VM_TPM_LOG
CONFIG_DIR=$VM_TPM_CONFIG_DIR
[[ -s "$STATE_DIR/tpm2-00.permall" ]] || fail 'TPM2 permanent state missing'
[[ -S "$SOCKET" ]] || fail 'swtpm socket missing after start'
[[ -s "$PID_FILE" ]] || fail 'swtpm PID file missing after start'
[[ -s "$LOG" ]] || fail 'swtpm log missing after start'
[[ -f "$VM_TPM_SETUP_CONFIG" && -f "$VM_TPM_LOCALCA_CONFIG" \
    && -f "$VM_TPM_LOCALCA_OPTIONS" ]] || fail 'private XDG config incomplete'
assert_file_contains "$VM_TPM_LOCALCA_CONFIG" "$CONFIG_DIR/var/lib/swtpm-localca" \
    'private local CA state'
assert_file_contains "$VM_TPM_SETUP_CONFIG" "create_certs_tool = $FAKE_LOCALCA" \
    'resolved local CA executable override'
assert_file_contains "$VM_TPM_LOCALCA_OPTIONS" '--platform-manufacturer "ASRock"' \
    'platform manufacturer identity'
assert_file_contains "$VM_TPM_LOCALCA_OPTIONS" '--platform-model "B360M Pro4"' \
    'platform model identity'
assert_file_contains "$VM_TPM_LOCALCA_OPTIONS" '--platform-version "4.40"' \
    'platform version identity'
assert_file_contains "$FAKE_TRACE" "create-config xdg=$CONFIG_DIR" \
    'per-instance XDG config environment'
assert_file_contains "$FAKE_TRACE" "config=$VM_TPM_SETUP_CONFIG" \
    'explicit setup config'
assert_file_contains "$FAKE_TRACE" '--ctrl type=unixio\,path=' \
    'swtpm control channel'
assert_file_contains "$FAKE_TRACE" '--terminate' 'independent swtpm terminate flag'
if grep -F -- '--ctrl type=unixio' "$FAKE_TRACE" | grep -F -- ',terminate' >/dev/null; then
    fail 'Ubuntu 0.7.3-incompatible ctrl terminate parameter was emitted'
fi
vm_tpm_is_running 41 || fail 'exact swtpm process not detected'

FIRST_PID=$(<"$PID_FILE")
FIRST_SETUP_COUNT=$(grep -c '^setup-state ' "$FAKE_TRACE")
FIRST_CONFIG_COUNT=$(grep -c '^create-config ' "$FAKE_TRACE")
vm_tpm_cleanup 41 >/dev/null
assert_not_exists "$FAKE_PROC/$FIRST_PID" 'cleaned swtpm fake proc'
assert_not_exists "$SOCKET" 'cleaned TPM socket'
assert_not_exists "$PID_FILE" 'cleaned TPM PID file'
[[ -s "$STATE_DIR/tpm2-00.permall" ]] || fail 'cleanup removed persistent state'
[[ -s "$LOG" ]] || fail 'cleanup removed persistent log'
[[ -d "$CONFIG_DIR" ]] || fail 'cleanup removed private CA config'
assert_file_contains "$KILL_TRACE" "-TERM $FIRST_PID" 'graceful exact cleanup'

KILLS_AFTER_FIRST=$(wc -l <"$KILL_TRACE")
vm_tpm_cleanup 41 >/dev/null
[[ $(wc -l <"$KILL_TRACE") -eq "$KILLS_AFTER_FIRST" ]] \
    || fail 'idempotent cleanup signalled another process'

# Restart reuses both the state and private CA; manufacturing runs only once.
vm_tpm_start 41 "$QEMU_BIN" 0 >/dev/null
[[ $(grep -c '^setup-state ' "$FAKE_TRACE") -eq "$FIRST_SETUP_COUNT" ]] \
    || fail 'persistent TPM state was manufactured again'
[[ $(grep -c '^create-config ' "$FAKE_TRACE") -eq "$FIRST_CONFIG_COUNT" ]] \
    || fail 'private CA config was recreated'
SECOND_PID=$(<"$VM_TPM_PID_FILE")

# Cleanup fails closed while the exact chardev is present in a QEMU argv.
make_qemu_proc 9001 "$VM_TPM_SOCKET"
if vm_tpm_cleanup 41 >"$TMP_DIR/in-use.out" 2>"$TMP_DIR/in-use.err"; then
    fail 'cleanup killed swtpm while QEMU owned its socket'
fi
[[ -d "$FAKE_PROC/$SECOND_PID" ]] || fail 'in-use cleanup removed swtpm'
[[ -S "$VM_TPM_SOCKET" ]] || fail 'in-use cleanup removed socket'
rm -rf -- "$FAKE_PROC/9001"
vm_tpm_cleanup 41 >/dev/null

# A stale PID file pointing at another instance must never cause a kill.  The
# full state/socket/PID argv tuple is required, not a substring or VM-id regex.
vm_tpm_plan 99
FOREIGN_STATE=$VM_TPM_STATE_DIR
FOREIGN_SOCKET=$VM_TPM_SOCKET
FOREIGN_PID_FILE=$VM_TPM_PID_FILE
make_swtpm_proc 9900 "$FOREIGN_STATE" "$FOREIGN_SOCKET" "$FOREIGN_PID_FILE"
vm_tpm_plan 41
mkdir -p "$(dirname "$VM_TPM_PID_FILE")"
printf '%s\n' 9900 >"$VM_TPM_PID_FILE"
make_socket "$VM_TPM_SOCKET"
KILLS_BEFORE_FOREIGN=$(wc -l <"$KILL_TRACE")
vm_tpm_cleanup 41 >/dev/null
[[ -d "$FAKE_PROC/9900" ]] || fail 'foreign swtpm was killed'
[[ $(wc -l <"$KILL_TRACE") -eq "$KILLS_BEFORE_FOREIGN" ]] \
    || fail 'foreign PID caused a signal'
rm -rf -- "$FAKE_PROC/9900"

# An exact orphan is reaped before a replacement daemon starts.
vm_tpm_plan 41
make_swtpm_proc 7001 "$VM_TPM_STATE_DIR" "$VM_TPM_SOCKET" "$VM_TPM_PID_FILE"
printf '%s\n' 7001 >"$VM_TPM_PID_FILE"
make_socket "$VM_TPM_SOCKET"
vm_tpm_start 41 "$QEMU_BIN" 0 >/dev/null
assert_file_contains "$KILL_TRACE" '-TERM 7001' 'startup orphan reaper'
[[ "$(<"$VM_TPM_PID_FILE")" != 7001 ]] || fail 'orphan daemon was reused'
vm_tpm_cleanup 41 >/dev/null

# A daemon that never publishes its socket times out and is cleaned precisely;
# state remains intact for a later retry.
export FAKE_SWTPM_NO_SOCKET=1
if vm_tpm_start 41 "$QEMU_BIN" 0 >"$TMP_DIR/timeout.out" 2>"$TMP_DIR/timeout.err"; then
    fail 'socket startup timeout was accepted'
fi
unset FAKE_SWTPM_NO_SOCKET
assert_not_exists "$VM_TPM_SOCKET" 'timeout TPM socket'
assert_not_exists "$VM_TPM_PID_FILE" 'timeout TPM PID file'
[[ -s "$VM_TPM_STATE_DIR/tpm2-00.permall" ]] \
    || fail 'timeout cleanup removed persistent state'
if vm_tpm_is_running 41; then
    fail 'timeout left an exact swtpm orphan'
fi

# A tiny/partial permall is the known failed-certificate shape.  Preserve it
# for diagnosis and fail closed instead of silently accepting or overwriting
# persistent TPM identity.
truncate -s 1500 "$VM_TPM_STATE_DIR/tpm2-00.permall"
SETUPS_BEFORE_PARTIAL=$(grep -c '^setup-state ' "$FAKE_TRACE")
if vm_tpm_start 41 "$QEMU_BIN" 0 >"$TMP_DIR/partial.out" 2>"$TMP_DIR/partial.err"; then
    fail 'undersized TPM permanent state was accepted'
fi
[[ $(stat -c %s "$VM_TPM_STATE_DIR/tpm2-00.permall") -eq 1500 ]] \
    || fail 'undersized persistent state was overwritten'
[[ $(grep -c '^setup-state ' "$FAKE_TRACE") -eq "$SETUPS_BEFORE_PARTIAL" ]] \
    || fail 'undersized state triggered destructive remanufacturing'
assert_file_contains "$TMP_DIR/partial.err" 'TPM state is incomplete' \
    'undersized state diagnostic'

# TPM 1.2 has a separate persistent-state filename, omits --tpm2 from both
# manufacturing and daemon launch, and exposes the legacy TIS device.  Cleanup
# is intentionally generation-agnostic so stop-vm can reap an exact daemon even
# when it has only the instance id and no vm.conf version context.
VM_TPM_VERSION=1.2
TPM12_SETUPS_BEFORE=$(grep -c '^setup-state ' "$FAKE_TRACE")
vm_tpm_start 44 "$QEMU_BIN" 0 >/dev/null
TPM12_STATE_DIR=$VM_TPM_STATE_DIR
TPM12_SOCKET=$VM_TPM_SOCKET
TPM12_PID_FILE=$VM_TPM_PID_FILE
[[ "${VM_TPM_QEMU_ARGS[5]}" == tpm-tis,tpmdev=tpm0 ]] \
    || fail 'TPM 1.2 real start did not plan TIS'
[[ -s "$TPM12_STATE_DIR/tpm-00.permall" ]] \
    || fail 'TPM 1.2 permanent state missing'
assert_not_exists "$TPM12_STATE_DIR/tpm2-00.permall" \
    'TPM 1.2 false TPM2 state'
[[ -S "$TPM12_SOCKET" && -s "$TPM12_PID_FILE" ]] \
    || fail 'TPM 1.2 runtime socket/PID missing'
TPM12_LAUNCH=$(grep '^swtpm-launch ' "$FAKE_TRACE" | tail -1)
[[ "$TPM12_LAUNCH" != *--tpm2* ]] \
    || fail 'TPM 1.2 daemon launch incorrectly used --tpm2'
[[ $(grep -c '^setup-state ' "$FAKE_TRACE") \
    -eq $((TPM12_SETUPS_BEFORE + 1)) ]] \
    || fail 'TPM 1.2 state was not manufactured exactly once'
TPM12_PID=$(<"$TPM12_PID_FILE")

# Simulate cleanup from a generic stop path that defaults to TPM 2.0.  Exact
# state/socket/PID matching still finds the 1.2 daemon and leaves its state.
VM_TPM_VERSION=2.0
vm_tpm_cleanup 44 >/dev/null
assert_not_exists "$FAKE_PROC/$TPM12_PID" 'cleaned TPM 1.2 fake proc'
assert_not_exists "$TPM12_SOCKET" 'cleaned TPM 1.2 socket'
assert_not_exists "$TPM12_PID_FILE" 'cleaned TPM 1.2 PID file'
[[ -s "$TPM12_STATE_DIR/tpm-00.permall" ]] \
    || fail 'cross-version cleanup removed TPM 1.2 persistent state'
assert_file_contains "$KILL_TRACE" "-TERM $TPM12_PID" \
    'generation-agnostic TPM 1.2 cleanup'

# Persistent generations are not interchangeable.  Fail with a migration/
# reset explanation instead of reducing the alternate permall to "incomplete".
VM_TPM_VERSION=2.0
if vm_tpm_start 44 "$QEMU_BIN" 0 \
        >"$TMP_DIR/tpm-version-switch.out" \
        2>"$TMP_DIR/tpm-version-switch.err"; then
    fail 'TPM 1.2 state was silently reopened as TPM 2.0'
fi
assert_file_contains "$TMP_DIR/tpm-version-switch.err" \
    'persistent TPM 1.2 state cannot be opened as TPM 2.0' \
    'TPM generation migration diagnostic'
[[ -s "$TPM12_STATE_DIR/tpm-00.permall" ]] \
    || fail 'failed TPM generation switch mutated persistent state'

# Restart in 1.2 mode reuses the same manufactured identity.
VM_TPM_VERSION=1.2
TPM12_SETUP_COUNT=$(grep -c '^setup-state ' "$FAKE_TRACE")
vm_tpm_start 44 "$QEMU_BIN" 0 >/dev/null
[[ $(grep -c '^setup-state ' "$FAKE_TRACE") -eq "$TPM12_SETUP_COUNT" ]] \
    || fail 'persistent TPM 1.2 state was manufactured again'
vm_tpm_cleanup 44 >/dev/null

echo 'PASS: root TPM 1.2/2.0 lifecycle, dry-run, private CA, exact cleanup and timeout safety'
