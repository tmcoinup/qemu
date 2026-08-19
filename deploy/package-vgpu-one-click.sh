#!/usr/bin/env bash
# Default to the reusable, VM-unbound profile installer.  GPU-Z itself remains
# an external, hash-pinned sibling.  A positional VM_ID remains available only
# for the legacy per-VM migration/compatibility flows.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"

usage() {
    cat >&2 <<'EOF'
usage: ./deploy/package-vgpu-one-click.sh
       ./deploy/package-vgpu-one-click.sh --replace-public
       ./deploy/package-vgpu-one-click.sh --with-license-token
       ./deploy/package-vgpu-one-click.sh --token-file FILE.tok
       ./deploy/package-vgpu-one-click.sh --with-license-token --replace-licensed
       ./deploy/package-vgpu-one-click.sh --portable [portable options]
       ./deploy/package-vgpu-one-click.sh VM_ID   # legacy only

No argument (recommended):
  Build one VgpuPortable.exe with every audited B/native profile, the
  recommended guest performance optimizer, and no VM ID/UUID.  It does not
  embed or require GPU-Z or a DLS token.
  --with-license-token builds a separate private VgpuPortable.exe using
  $STAGE_DIR/client_configuration_token.tok.  --token-file selects another
  repository-external token.  The private EXE works for every B/native GPU
  profile and replaces the legacy model-specific finish step for new VMs.
  When the DLS token changes, add --replace-licensed.  The old authenticated
  private EXE/bundle is retained under a mode-0700 repository-external backup.
  When the public catalog/format changes, add --replace-public; its old
  authenticated EXE/bundle is retained the same way.
  --portable forwards its remaining options to package-vgpu-portable.sh.

VM_ID (legacy compatibility):
The VM config must contain exactly one simple literal:
  SPOOF_MODE=A    Build the complete production-driver migration EXE
  SPOOF_MODE=B    Build the VM-bound GPU-Z profile EXE

SPOOF_MODE=off, missing/duplicate assignments and dynamic shell expressions
are refused.  This entry accepts no pass-through options.
EOF
}

die() {
    echo "[vgpu-one-click] ERROR: $*" >&2
    exit 1
}

if (($# == 1)) && [[ "$1" == -h || "$1" == --help ]]; then
    usage
    exit 0
fi
if (($# == 0)); then
    echo "[vgpu-one-click] building the VM-unbound identity/performance installer (GPU-Z is an external sibling)"
    exec "$here/package-vgpu-portable.sh"
fi
if [[ "$1" == --portable ]]; then
    shift
    echo "[vgpu-one-click] building the VM-unbound identity/performance installer (GPU-Z is an external sibling)"
    exec "$here/package-vgpu-portable.sh" "$@"
fi
if [[ "$1" == --replace-public ]]; then
    echo "[vgpu-one-click] replacing an older public identity/performance generation with backup"
    exec "$here/package-vgpu-portable.sh" "$@"
fi
if [[ "$1" == --with-license-token || "$1" == --token-file ]]; then
    echo "[vgpu-one-click] building the private all-profile identity/license/performance finalizer"
    exec "$here/package-vgpu-portable.sh" "$@"
fi
(($# == 1)) || {
    usage
    exit 2
}

VM_ID=$1
vm_storage_id_is_supported "$VM_ID" \
    || die "unsupported VM_ID (expected 1..2147483647): $VM_ID"
for dependency in awk sha256sum python3; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing dependency: $dependency"
done

vm_storage_init
vm_storage_require_namespace_ready "$VM_ID" \
    || die "VM storage still uses an old/conflicting layout"
CONF=$(vm_storage_config_path "$VM_ID") \
    || die "could not select a unique vm${VM_ID} configuration"
[[ -f "$CONF" && ! -L "$CONF" && -r "$CONF" ]] \
    || die "VM config is not a readable regular file: $CONF"

# Hash before and after parsing so the selected route and the constraint
# inherited by the real packager describe one immutable config generation.
CONFIG_SHA_BEFORE=$(
    sha256sum -- "$CONF" | awk '{print toupper($1)}'
)
if ! SPOOF_MODE_VALUE=$(
    python3 -I -S - "$CONF" <<'PY'
import pathlib
import re
import sys

identity_token = re.compile(r"(?<![A-Za-z0-9_])SPOOF_MODE(?![A-Za-z0-9_])")
assignment = re.compile(
    r"""^\s*SPOOF_MODE\s*=\s*
        (?:
            (?P<plain>A|B|off) |
            "(?P<double>A|B|off)" |
            '(?P<single>A|B|off)'
        )
        (?:\s+\#.*)?\s*$
    """,
    re.VERBOSE,
)
values = []
try:
    lines = pathlib.Path(sys.argv[1]).read_text(
        encoding="utf-8", errors="strict"
    ).splitlines()
except (OSError, UnicodeError):
    raise SystemExit(2)
for line in lines:
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if not identity_token.search(line):
        continue
    match = assignment.fullmatch(line)
    if match is None:
        raise SystemExit(2)
    values.append(next(value for value in match.groups() if value is not None))
if len(values) != 1:
    raise SystemExit(2)
print(values[0])
PY
); then
    die "vm${VM_ID} must contain exactly one simple literal SPOOF_MODE=A, B or off"
fi
CONFIG_SHA_AFTER=$(
    sha256sum -- "$CONF" | awk '{print toupper($1)}'
)
[[ "$CONFIG_SHA_BEFORE" == "$CONFIG_SHA_AFTER" ]] \
    || die "VM config changed while SPOOF_MODE was being selected; rerun"

export VGPU_PACKAGE_DISPATCH_CONFIG_SHA256=$CONFIG_SHA_AFTER
export VGPU_PACKAGE_DISPATCH_SPOOF_MODE=$SPOOF_MODE_VALUE
case "$SPOOF_MODE_VALUE" in
    A)
        echo "[vgpu-one-click] vm${VM_ID}: SPOOF_MODE=A; building the complete A-to-B production migration EXE"
        exec "$here/package-vgpu-production-migration.sh" "$VM_ID"
        ;;
    B)
        echo "[vgpu-one-click] vm${VM_ID}: SPOOF_MODE=B; building the VM-bound GPU-Z profile EXE"
        exec "$here/package-gpuz-profile.sh" "$VM_ID"
        ;;
    off)
        die "SPOOF_MODE=off has no consumer GPU identity to package; select A or B in vm.conf first"
        ;;
    *)
        die "internal SPOOF_MODE parser result is invalid"
        ;;
esac
