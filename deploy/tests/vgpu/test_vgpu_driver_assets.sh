#!/usr/bin/env bash
# Unit-test the fail-closed driver asset helper without using the 1.3 GB real
# staging files. sha256sum/unzip are isolated fakes in a temporary PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ASSET_LIB="$REPO_ROOT/deploy/lib/vgpu-driver-assets.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STAGE_DIR="$TMP_DIR/staging"
mkdir -p "$STAGE_DIR" "$TMP_DIR/bin"
touch "$STAGE_DIR/553.24.exe" "$STAGE_DIR/553.24-display-driver.zip"
export STAGE_DIR

cat >"$TMP_DIR/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
case "${1##*/}" in
    553.24.exe)
        hash=aaa3080c0b7e3a6fbe825a05725f4171c75072faa8b667d97556c1605a219ddd ;;
    553.24-display-driver.zip)
        hash=a3d7ad8b8082d6ac6214565b4766b5190a819bc9b7574765b14897e0db809690 ;;
    *)
        hash=bad ;;
esac
printf '%s  %s\n' "$hash" "$1"
EOF
cat >"$TMP_DIR/bin/unzip" <<'EOF'
#!/usr/bin/env bash
printf 'DriverVer = 01/25/2024, 31.0.15.3833\r\n'
EOF
chmod +x "$TMP_DIR/bin/sha256sum" "$TMP_DIR/bin/unzip"
PATH="$TMP_DIR/bin:/usr/bin:/bin"
export PATH

# shellcheck source=../../../lib/vgpu-driver-assets.sh
source "$ASSET_LIB"
vgpu_verify_driver_assets exe >"$TMP_DIR/exe.out"
vgpu_verify_driver_assets all >"$TMP_DIR/all.out"

cat >"$TMP_DIR/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
printf '0000000000000000000000000000000000000000000000000000000000000000  %s\n' "$1"
EOF
chmod +x "$TMP_DIR/bin/sha256sum"
if vgpu_verify_driver_assets exe >"$TMP_DIR/bad.out" 2>"$TMP_DIR/bad.err"; then
    fail "unexpected driver asset hash was accepted"
fi
grep -Fq 'REFUSE: unexpected SHA256' "$TMP_DIR/bad.err" \
    || fail "hash mismatch did not produce a clear refusal"

echo "PASS: vGPU 538.33 driver asset verification"
