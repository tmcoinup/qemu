#!/usr/bin/env bash
# Verify the one-command wrapper's V-11-style paths without touching a VM,
# licensed payload, NBD device, or Windows filesystem.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE="$ROOT/deploy/build-g11-private-base.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
TMP_DIR=$(mktemp -d /tmp/g11-single-builder-test.XXXXXXXX)
trap 'rm -rf -- "$TMP_DIR"' EXIT
HARNESS="$TMP_DIR/repo"
TRACE="$TMP_DIR/trace"
mkdir -p "$HARNESS/deploy/scripts"
cp -- "$SOURCE" "$HARNESS/deploy/build-g11-private-base.sh"
chmod +x "$HARNESS/deploy/build-g11-private-base.sh"

cat >"$HARNESS/deploy/scripts/seal-base.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'seal|root=%s|base=%s|archive=%s' "$VM_ROOT" "$VM_BASE_DIR" "$VM_BASE_ARCHIVE_DIR" >>"$TRACE"
printf '|%s' "$@" >>"$TRACE"
printf '\n' >>"$TRACE"
mkdir -p "$VM_BASE_DIR"
printf 'fixture\n' >"$VM_BASE_DIR/$2.qcow2"
EOF

cat >"$HARNESS/deploy/package-vgpu-one-click.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'package' >>"$TRACE"
printf '|%s' "$@" >>"$TRACE"
printf '\n' >>"$TRACE"
EOF

cat >"$HARNESS/deploy/install-vgpu-portable-to-base.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install' >>"$TRACE"
printf '|%s' "$@" >>"$TRACE"
printf '\n' >>"$TRACE"
EOF

cat >"$HARNESS/deploy/scripts/export-vgpu-base.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'export' >>"$TRACE"
printf '|%s' "$@" >>"$TRACE"
printf '\n' >>"$TRACE"
[[ "$1" == --in-place ]]
printf '{}\n' >"$3/$2.g11base"
mkdir -p "$VM_BASE_ARCHIVE_DIR"
EOF
chmod +x "$HARNESS/deploy/scripts/"*.sh \
    "$HARNESS/deploy/package-vgpu-one-click.sh" \
    "$HARNESS/deploy/install-vgpu-portable-to-base.sh"

VMS_DIR="$TMP_DIR/vms"
BASE_DIR="$VMS_DIR/_base"
mkdir -p "$VMS_DIR/8"
TRACE="$TRACE" "$HARNESS/deploy/build-g11-private-base.sh" 8 win10-base \
    --vms-dir="$VMS_DIR" --no-progress \
    >"$TMP_DIR/out"

grep -Fq "seal|root=$VMS_DIR|base=$BASE_DIR|archive=$BASE_DIR/archive|8|win10-base|--yes|--single-image" "$TRACE" ||
    fail "builder did not pass the selected V-11-style storage and seal mode"
grep -Fq 'install|--base-name|win10-base|--site-private|--sysprep-generalized|--single-image|--yes' "$TRACE" ||
    fail "builder did not request ephemeral installer rollback"
grep -Fq "export|--in-place|win10-base|$BASE_DIR" "$TRACE" ||
    fail "builder did not create an in-place transfer manifest"
[[ -f "$BASE_DIR/win10-base.qcow2" && -f "$BASE_DIR/win10-base.g11base" ]] ||
    fail "builder did not retain the direct V-11-style filenames"
[[ ! -d "$BASE_DIR/archive" ]] ||
    fail "builder retained an empty archive directory"
grep -Fq -- "--vms-dir=$VMS_DIR --start" "$TMP_DIR/out" ||
    fail "builder did not print a directly usable local clone command"
if grep -Fq -- '--base-dir=' "$TMP_DIR/out"; then
    fail "default builder command unnecessarily printed a base-dir override"
fi

DEFAULT_IMAGE_ROOT="$TMP_DIR/default-images"
DEFAULT_VMS_DIR="$DEFAULT_IMAGE_ROOT/vms"
mkdir -p "$DEFAULT_VMS_DIR/9"
IMAGE_ROOT="$DEFAULT_IMAGE_ROOT" TRACE="$TRACE" \
    "$HARNESS/deploy/build-g11-private-base.sh" 9 default-base --no-progress \
    >"$TMP_DIR/default.out"
[[ -f "$DEFAULT_VMS_DIR/_base/default-base.qcow2" ]] ||
    fail "builder did not use IMAGE_ROOT/vms/_base by default"
grep -Fq -- \
    './deploy/scripts/clone-from-base.sh default-base NEW_VM_ID --start' \
    "$TMP_DIR/default.out" ||
    fail "default builder did not print the flag-free V-11-style clone command"
if grep -Fq -- '--vms-dir=' "$TMP_DIR/default.out" ||
        grep -Fq -- '--base-dir=' "$TMP_DIR/default.out"; then
    fail "default builder printed redundant storage overrides"
fi

echo "PASS: G-11 builder publishes one local/delivery qcow2 with V-11-style paths"
