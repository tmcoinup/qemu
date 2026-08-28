#!/usr/bin/env bash
# Static contract for the one-command, force-free R535 display recovery flow.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
recovery="$repo_root/deploy/scripts/recover-vgpu-black-screen.sh"
vmctl="$repo_root/deploy/scripts/vmctl.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$recovery" "$vmctl" || fail "recovery wrapper has invalid Bash syntax"

for required in \
        "grep -Eq '^VGPU_MDEV_PROFILE=nvidia-[0-9]+\$'" \
        'pgrep -af qemu-system-x86_64' \
        '"$here/scripts/stop-vm.sh" "$VM_ID" "${storage_args[@]}" --graceful-only' \
        '"$here/scripts/sync-monitor-profile.sh" "$VM_ID" --force' \
        '"$here/scripts/start-vm.sh" "$VM_ID" "${storage_args[@]}"' \
        'R535 page-alignment recovery' \
        'old 1680x1050'; do
    grep -Fq -- "$required" "$recovery" || fail "recovery omits: $required"
done

python3 - "$recovery" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
stop = text.index('"$here/scripts/stop-vm.sh"')
sync = text.index('"$here/scripts/sync-monitor-profile.sh"')
start = text.index('"$here/scripts/start-vm.sh"')
if not stop < sync < start:
    raise SystemExit("FAIL: recovery is not ordered graceful-stop -> offline-sync -> cold-start")
if 'stop-vm.sh" "$VM_ID" "${storage_args[@]}" --force' in text:
    raise SystemExit("FAIL: recovery contains a force-stop fallback")
PY

grep -Fq 'repair-display|recover-display)' "$vmctl" ||
    fail "vmctl does not package the display recovery entry"

if rg -n -i 'testsigning|nointegritychecks|bcdedit|self[- ]signed|自签' \
        "$recovery" >/dev/null; then
    fail "display recovery mentions a forbidden BCD/signing bypass"
fi

"$recovery" --help | grep -Fq 'ACPI shutdown' ||
    fail "foolproof help omits the non-force shutdown guarantee"

echo "PASS: R535 black-screen recovery is G-11-scoped, force-free, offline-authenticated, and packaged in vmctl"
