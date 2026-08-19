#!/usr/bin/env bash
# Static contract for the default WeGame/Tencent cleanup performed by
# seal-base.sh.  No image is mounted or modified by this test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SEAL="$REPO_ROOT/deploy/scripts/seal-base.sh"
CLEANER="$REPO_ROOT/deploy/scripts/host-clean-tencent.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local pattern=$1 file=$2 label=$3
    grep -Fq -- "$pattern" "$file" || fail "$label"
}

[[ -x "$SEAL" ]] || fail "seal-base.sh is missing or not executable"
[[ -x "$CLEANER" ]] || fail "host-clean-tencent.sh is missing or not executable"
bash -n "$SEAL"
bash -n "$CLEANER"

require_text 'CLEAN_WEGAME=1' "$SEAL" \
    'seal does not clean WeGame/Tencent state by default'
require_text '--no-clean) CLEAN_WEGAME=0' "$SEAL" \
    'seal has no explicit cleanup opt-out'
require_text '"$CLEANER" "$VM_ID" --disk "$VM_DISK"' "$SEAL" \
    'seal does not bind cleanup to its exact source disk'
require_text '清理失败则拒绝产出 base' "$SEAL" \
    'seal help omits the fail-closed cleanup contract'

clean_line=$(grep -nF '"$CLEANER" "$VM_ID" --disk "$VM_DISK"' "$SEAL" |
    head -n1 | cut -d: -f1)
convert_line=$(grep -nF '"$QEMU_IMG" convert' "$SEAL" |
    head -n1 | cut -d: -f1)
[[ -n "$clean_line" && -n "$convert_line" && "$clean_line" -lt "$convert_line" ]] ||
    fail "source cleanup is not ordered before base conversion"

for target in \
        'AppData/Roaming/Tencent' \
        'AppData/Local/WeGame' \
        'AppData/Local/rail' \
        'AppData/Local/ConnectedDevicesPlatform' \
        'AppData/Local/D3DSCache' \
        'ProgramData/Tencent' \
        'ProgramData/WeGame' \
        'WOW6432Node\Tencent' \
        'Software\Tencent'; do
    require_text "$target" "$CLEANER" "cleanup omits $target"
done

require_text 'ntfs-3g.probe --readwrite "$WINDOWS_PARTITION"' "$CLEANER" \
    'cleanup omits the dirty/hibernation preflight'
require_text 'mount -t ntfs-3g -o rw,norecover' "$CLEANER" \
    'cleanup does not use the safe no-recovery write mount'
require_text 'preflight' "$CLEANER" 'cleanup omits hive preflight validation'
require_text 'post-commit' "$CLEANER" 'cleanup omits hive post-commit validation'
require_text 'hive.node_delete_child(target)' "$CLEANER" \
    'cleanup does not remove the selected Tencent registry subtree'
require_text 'truncate_hive_logs "${HIVE_PATHS[$index]}"' "$CLEANER" \
    'cleanup does not neutralize stale transaction logs after a validated commit'

if grep -Eq '^[[:space:]]*ntfsfix([[:space:]]|$)' "$CLEANER"; then
    fail 'cleanup executes destructive ntfsfix'
fi
if grep -E '^[[:space:]]*mount .*remove_hiberfile' "$CLEANER" >/dev/null; then
    fail 'cleanup requests destructive remove_hiberfile'
fi
if grep -Eiq '^[[:space:]]*(bcdedit|pnputil|sc[.]exe)[[:space:]]' "$CLEANER"; then
    fail 'cleanup crosses the BCD/driver/service boundary'
fi

"$CLEANER" --help >"$TMP_DIR/help.out"
grep -Fq -- '--dry-run' "$TMP_DIR/help.out" ||
    fail 'cleanup help omits dry-run'

echo "PASS: seal defaults to fail-closed WeGame/Tencent cleanup without unsafe NTFS/BCD/driver actions"
