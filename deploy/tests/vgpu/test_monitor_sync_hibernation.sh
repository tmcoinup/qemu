#!/usr/bin/env bash
# Rootless regression for the host-side EDID sync hibernation recovery path.
# The temporary helper copy changes only privilege/device predicates; all NBD,
# NTFS and mount commands are shims, so no real image or block device is used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/deploy/host/sync-monitor-cache.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 file=$2
    grep -F -- "$needle" "$file" >/dev/null || \
        fail "missing '$needle' in $(basename "$file")"
}

reject_text() {
    local needle=$1 file=$2
    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $(basename "$file")"
    fi
}

TMP_DIR="$(mktemp -d)"
INSTANCE="hibernation-test-$$"
SAFE_INSTANCE=${INSTANCE//[^A-Za-z0-9_.-]/_}
HOST_MOUNT="/tmp/winmnt-disp-${SAFE_INSTANCE}"
HOST_EDID="/tmp/vgpu-edid-${SAFE_INSTANCE}.bin"

cleanup() {
    rm -rf -- "$TMP_DIR" "$HOST_MOUNT"
    rm -f -- "$HOST_EDID"
}
trap cleanup EXIT

[[ -x "$HELPER" ]] || fail "display-cache helper is missing"
[[ -x "$START_VM" ]] || fail "start-vm.sh is missing"
[[ ! -e "$HOST_MOUNT" && ! -e "$HOST_EDID" ]] || \
    fail "test instance collides with stale helper state"

# Automatic startup must classify the NTFS state without repairing metadata or
# discarding a saved Windows session.
if grep -Eq '^[[:space:]]*ntfsfix([[:space:]]|$)' "$HELPER"; then
    fail "display-cache helper still runs ntfsfix"
fi
if grep -E 'mount .*remove_hiberfile' "$HELPER" >/dev/null; then
    fail "display-cache helper still requests destructive remove_hiberfile"
fi
require_text 'ntfs-3g.probe --readwrite "$SYSPART"' "$HELPER"

mkdir -p "$TMP_DIR/tree/deploy/host" "$TMP_DIR/fake-bin"
cp -- "$HELPER" "$TMP_DIR/tree/deploy/host/sync-monitor-cache.sh"
ln -s -- "$REPO_ROOT/deploy/lib" "$TMP_DIR/tree/deploy/lib"

# The behavior below remains the production helper. These two substitutions
# only make its environmental guards representable without root or /dev nodes.
HELPER_COPY="$TMP_DIR/tree/deploy/host/sync-monitor-cache.sh"
require_text '[[ $EUID -eq 0 ]] || die' "$HELPER_COPY"
require_text '[[ -b "$p" ]] || continue' "$HELPER_COPY"
sed -i \
    -e 's/^    \[\[ $EUID -eq 0 \]\] || die .*/    : # test: simulated root/' \
    -e 's/^    \[\[ -b "$p" \]\] || continue$/    [[ "$p" == "${NBD}p3" ]] || continue/' \
    "$HELPER_COPY"
chmod +x "$HELPER_COPY"
if grep -F '[[ $EUID -eq 0 ]] || die' "$HELPER_COPY" >/dev/null ||
        grep -F '[[ -b "$p" ]] || continue' "$HELPER_COPY" >/dev/null; then
    fail "failed to instrument helper environmental guards"
fi

TRACE="$TMP_DIR/commands.trace"
: >"$TRACE"

# Minimal valid 256-byte FHD EDID for the selected Dell profile. The helper's
# own Python validation and standard-timing rewrite still run unchanged.
cat >"$TMP_DIR/fake-bin/qemu-edid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -h ]]; then
    printf '%s\n' \
        '--week' '--year' '--range-min-v' '--range-max-v' \
        '--range-min-h' '--range-max-h' '--max-clock'
    exit 0
fi
out=""
while (( $# > 0 )); do
    case "$1" in
        -o) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$out" ]]
python3 - "$out" <<'PY'
import sys

path = sys.argv[1]
e = bytearray(256)
e[:8] = bytes.fromhex('00ffffffffffff00')
vendor = 'DEL'
encoded = ((ord(vendor[0]) - 64) << 10 |
           (ord(vendor[1]) - 64) << 5 |
           (ord(vendor[2]) - 64))
e[8:10] = encoded.to_bytes(2, 'big')
e[10:12] = (0xD0D8).to_bytes(2, 'little')
e[21], e[22] = 53, 30
e[35], e[36], e[37] = 0x21, 0x08, 0x00
e[38:54] = b'\x01\x01' * 8
# One 1920x1080 DTD; only the fields checked by the helper are material here.
e[54:56] = b'\x01\x01'
e[56], e[58] = 0x80, 0x70
e[59], e[61] = 0x38, 0x40
# Match the generator's xtra3/range/name base layout and CTA serial descriptor.
e[72:90] = (bytes.fromhex('000000f7000a004a80') + b'\x00' * 9)
e[93], e[111], e[138] = 0xFD, 0xFC, 0xFF
e[126] = 1
e[127] = (-sum(e[:127])) & 0xff
# CTA video block: VIC 16 (1080p60) and VIC 4 (720p60).
e[128:135] = bytes.fromhex('02030700421004')
e[255] = (-sum(e[128:255])) & 0xff
open(path, 'wb').write(e)
PY
EOF

cat >"$TMP_DIR/fake-bin/pgrep" <<'EOF'
#!/bin/sh
exit 1
EOF

cat >"$TMP_DIR/fake-bin/modprobe" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$TMP_DIR/fake-bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$TMP_DIR/fake-bin/qemu-nbd" <<'EOF'
#!/bin/sh
printf 'qemu-nbd %s\n' "$*" >>"$FAKE_COMMAND_TRACE"
exit 0
EOF

cat >"$TMP_DIR/fake-bin/blkid" <<'EOF'
#!/bin/sh
printf 'blkid %s\n' "$*" >>"$FAKE_COMMAND_TRACE"
case "${*}" in
    *'/dev/nbd0p3'*) printf 'ntfs\n'; exit 0 ;;
    *) exit 2 ;;
esac
EOF

cat >"$TMP_DIR/fake-bin/mount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'mount %s\n' "$*" >>"$FAKE_COMMAND_TRACE"
options=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == -o && $((i + 1)) -lt ${#args[@]} ]]; then
        options=${args[$((i + 1))]}
    fi
done
if [[ ",$options," == *,rw,* || ",$options," == *,remove_hiberfile,* ]]; then
    printf 'DESTRUCTIVE mount %s\n' "$*" >>"$FAKE_COMMAND_TRACE"
    exit 99
fi
target=${args[$((${#args[@]} - 1))]}
mkdir -p "$target/Windows/System32/config"
: >"$target/Windows/System32/config/SYSTEM"
EOF

cat >"$TMP_DIR/fake-bin/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >>"$FAKE_COMMAND_TRACE"
rm -rf -- "$1/Windows"
exit 0
EOF

cat >"$TMP_DIR/fake-bin/ntfs-3g.probe" <<'EOF'
#!/bin/sh
printf 'ntfs-3g.probe %s\n' "$*" >>"$FAKE_COMMAND_TRACE"
exit 14
EOF

# These sentinels make any regression to the old destructive path unmistakable.
cat >"$TMP_DIR/fake-bin/ntfsfix" <<'EOF'
#!/bin/sh
printf 'DESTRUCTIVE ntfsfix %s\n' "$*" >>"$FAKE_COMMAND_TRACE"
exit 99
EOF

chmod +x "$TMP_DIR/fake-bin/"*
touch "$TMP_DIR/disk.qcow2"
MARKER="$TMP_DIR/monitor-edid.sha256"

set +e
env \
    PATH="$TMP_DIR/fake-bin:/usr/bin:/bin" \
    FAKE_COMMAND_TRACE="$TRACE" \
    NBD=/dev/nbd0 \
    QEMU_EDID="$TMP_DIR/fake-bin/qemu-edid" \
    "$HELPER_COPY" \
        --disk "$TMP_DIR/disk.qcow2" \
        --catalog "$REPO_ROOT/deploy/config/monitor-profiles.tsv" \
        --monitor-profile dell-p2419h \
        --serial CC3P12345678 \
        --instance "$INSTANCE" \
        --marker "$MARKER" \
        --marker-value test-hash \
        >"$TMP_DIR/helper.out" 2>"$TMP_DIR/helper.err"
helper_rc=$?
set -e

[[ $helper_rc -eq 11 ]] || {
    sed -n '1,160p' "$TMP_DIR/helper.out" >&2
    sed -n '1,160p' "$TMP_DIR/helper.err" >&2
    fail "hibernated NTFS returned $helper_rc instead of deferred rc 11"
}
require_text 'ntfs-3g.probe --readwrite /dev/nbd0p3' "$TRACE"
require_text 'mount -t ntfs-3g -o ro,norecover /dev/nbd0p3' "$TRACE"
require_text 'umount' "$TRACE"
require_text 'qemu-nbd --connect=/dev/nbd0' "$TRACE"
require_text 'qemu-nbd --disconnect /dev/nbd0' "$TRACE"
[[ $(grep -Fc 'qemu-nbd --disconnect /dev/nbd0' "$TRACE") -eq 1 ]] || \
    fail "owned NBD was not disconnected exactly once"
reject_text 'DESTRUCTIVE' "$TRACE"
reject_text 'rw,' "$TRACE"
reject_text 'remove_hiberfile' "$TRACE"
[[ ! -e "$MARKER" ]] || fail "deferred helper wrote a completion marker"
[[ ! -e "$HOST_EDID" ]] || fail "deferred helper leaked its EDID blob"
[[ ! -e "$HOST_MOUNT" ]] || fail "deferred helper leaked its mount point"

# Exercise the exact start-vm return-code dispatch without running the rest of
# the launcher. A hibernated NVIDIA vGPU resume can bugcheck, so rc 11 must
# block a normal launch and point at the one-command local recovery flow.
DISPATCH="$TMP_DIR/monitor-dispatch.sh"
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -u' 'VM_ID=2' \
        'monitor_sync_rc=$1' 'PROXY=${2:-0}' \
        'VMS_DIR_CLI=${3:-}' 'VM_DIR_CLI=${4:-}' \
        'INSTANCES_DIR_CLI=${5:-}'
    awk '
        /case "\$monitor_sync_rc" in/ { copy = 1 }
        copy { print }
        copy && $0 == "            esac" { exit }
    ' "$START_VM"
    printf '%s\n' 'echo QEMU_PROCEEDS'
} >"$DISPATCH"
chmod +x "$DISPATCH"
require_text 'case "$monitor_sync_rc" in' "$DISPATCH"
require_text '11)' "$DISPATCH"

set +e
"$DISPATCH" 11 >"$TMP_DIR/dispatch-11.out" \
    2>"$TMP_DIR/dispatch-11.err"
hibernated_rc=$?
set -e
[[ $hibernated_rc -eq 11 ]] || \
    fail "hibernated sync rc 11 became $hibernated_rc"
reject_text 'QEMU_PROCEEDS' "$TMP_DIR/dispatch-11.out"
require_text './deploy/scripts/recover-hibernated-vm.sh 2' "$TMP_DIR/dispatch-11.err"
reject_text 'finish-vgpu-install.sh' "$TMP_DIR/dispatch-11.err"
require_text '本地标准 VGA 窗口' "$TMP_DIR/dispatch-11.err"
reject_text 'powercfg /h off' "$TMP_DIR/dispatch-11.err"
reject_text 'RealTimeIsUniversal' "$TMP_DIR/dispatch-11.err"

set +e
"$DISPATCH" 11 1 >"$TMP_DIR/dispatch-11-proxy.out" \
    2>"$TMP_DIR/dispatch-11-proxy.err"
hibernated_proxy_rc=$?
set -e
[[ $hibernated_proxy_rc -eq 11 ]] || \
    fail "proxied hibernated sync rc 11 became $hibernated_proxy_rc"
reject_text 'QEMU_PROCEEDS' "$TMP_DIR/dispatch-11-proxy.out"
require_text './deploy/scripts/recover-hibernated-vm.sh 2 --proxy' \
    "$TMP_DIR/dispatch-11-proxy.err"
reject_text 'finish-vgpu-install.sh' "$TMP_DIR/dispatch-11-proxy.err"

set +e
"$DISPATCH" 11 1 "$TMP_DIR/custom vms" >"$TMP_DIR/dispatch-11-root.out" \
    2>"$TMP_DIR/dispatch-11-root.err"
hibernated_root_rc=$?
set -e
[[ $hibernated_root_rc -eq 11 ]] || \
    fail "custom-root hibernated sync rc 11 became $hibernated_root_rc"
reject_text 'QEMU_PROCEEDS' "$TMP_DIR/dispatch-11-root.out"
require_text "./deploy/scripts/recover-hibernated-vm.sh 2 --vms-dir $TMP_DIR/custom\\ vms --proxy" \
    "$TMP_DIR/dispatch-11-root.err"
reject_text 'finish-vgpu-install.sh' "$TMP_DIR/dispatch-11-root.err"

set +e
"$DISPATCH" 15 >"$TMP_DIR/dispatch-15.out" \
    2>"$TMP_DIR/dispatch-15.err"
fatal_rc=$?
set -e
[[ $fatal_rc -eq 15 ]] || \
    fail "fatal sync rc 15 became $fatal_rc"
reject_text 'QEMU_PROCEEDS' "$TMP_DIR/dispatch-15.out"
require_text '拒绝在未知挂载状态下启动' "$TMP_DIR/dispatch-15.err"

echo "PASS: hibernated NTFS blocks vGPU resume without destructive writes"
