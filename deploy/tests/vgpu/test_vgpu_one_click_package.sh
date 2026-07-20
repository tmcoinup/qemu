#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
dispatcher="$root/deploy/package-vgpu-one-click.sh"
production_packager="$root/deploy/package-vgpu-production-migration.sh"
gpuz_packager="$root/deploy/package-gpuz-profile.sh"
storage_lib="$root/deploy/lib/vm-storage.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for file in "$dispatcher" "$production_packager" "$gpuz_packager" \
        "$storage_lib"; do
    [[ -s "$file" ]] || fail "missing one-click asset: $file"
done
bash -n "$dispatcher"
rg -Fq 'exec "$here/package-vgpu-production-migration.sh" "$VM_ID"' \
    "$dispatcher" || fail "A mode does not delegate to the complete migrator"
rg -Fq 'exec "$here/package-gpuz-profile.sh" "$VM_ID"' \
    "$dispatcher" || fail "B mode does not delegate to the GPU-Z packager"
if rg -q 'source[[:space:]]+"\$CONF"|eval[[:space:]]' "$dispatcher"; then
    fail "one-click dispatcher can execute vm.conf"
fi
rg -Fq 'VGPU_PACKAGE_DISPATCH_CONFIG_SHA256' "$production_packager" ||
    fail "production packager does not bind the one-click config generation"
rg -Fq 'VGPU_PACKAGE_DISPATCH_CONFIG_SHA256' "$gpuz_packager" ||
    fail "GPU-Z packager does not bind the one-click config generation"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/fixture"
mkdir -p "$fixture/deploy/lib" "$fixture/image/vms/G-11/vm456"
install -m 0700 "$dispatcher" "$fixture/deploy/package-vgpu-one-click.sh"
install -m 0600 "$storage_lib" "$fixture/deploy/lib/vm-storage.sh"

make_stub() {
    local path=$1 label=$2
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'printf %s\\\\n "%s|$*|${VGPU_PACKAGE_DISPATCH_SPOOF_MODE:-}|${VGPU_PACKAGE_DISPATCH_CONFIG_SHA256:-}" >"$RESULT"\n' \
            '%s' "$label"
    } >"$path"
    chmod 0700 "$path"
}
make_stub "$fixture/deploy/package-vgpu-production-migration.sh" production
make_stub "$fixture/deploy/package-gpuz-profile.sh" gpuz

conf="$fixture/image/vms/G-11/vm456/vm.conf"
result="$tmp/result"
run_dispatcher() {
    env -u VM_ROOT -u VM_INSTANCES_DIR -u VM_INSTANCE_DIR -u VM_INSTANCE_ID \
        -u VM_SHARED_DIR -u VM_CONFIG_DIR -u VM_DISK_DIR -u VM_BASE_DIR \
        -u VM_NVRAM_DIR -u VM_CONTROL_DIR -u VM_RUN_DIR -u VM_LOG_DIR \
        -u VM_ASSET_DIR -u VM_STORAGE_COMPAT_FALLBACK \
        -u VM_DISK_ARCHIVE_DIR -u VM_BASE_ARCHIVE_DIR \
        -u VM_NVRAM_BACKUP_DIR -u ISO_DIR -u STAGE_DIR \
        IMAGE_ROOT="$fixture/image" RESULT="$result" \
        bash "$fixture/deploy/package-vgpu-one-click.sh" "$@"
}

printf 'VM_ID=456\nSPOOF_MODE=A\n' >"$conf"
run_dispatcher 456 >/dev/null
expected_sha=$(sha256sum "$conf" | awk '{print toupper($1)}')
[[ "$(<"$result")" == "production|456|A|$expected_sha" ]] \
    || fail "A mode dispatch or immutable-config constraint is wrong"

printf 'VM_ID=456\nSPOOF_MODE=B # static profile route\n' >"$conf"
run_dispatcher 456 >/dev/null
expected_sha=$(sha256sum "$conf" | awk '{print toupper($1)}')
[[ "$(<"$result")" == "gpuz|456|B|$expected_sha" ]] \
    || fail "B mode dispatch or immutable-config constraint is wrong"

max_conf="$fixture/image/vms/G-11/vm2147483647/vm.conf"
mkdir -p "$(dirname "$max_conf")"
printf 'VM_ID=2147483647\nSPOOF_MODE=B\n' >"$max_conf"
run_dispatcher 2147483647 >/dev/null
expected_sha=$(sha256sum "$max_conf" | awk '{print toupper($1)}')
[[ "$(<"$result")" == "gpuz|2147483647|B|$expected_sha" ]] \
    || fail "the supported VM ID range is not dispatched generically"

expect_rejected() {
    local label=$1
    rm -f -- "$result"
    if run_dispatcher 456 >"$tmp/stdout" 2>"$tmp/stderr"; then
        fail "$label was accepted"
    fi
    [[ ! -e "$result" ]] || fail "$label reached a real packager"
}

printf 'VM_ID=456\nSPOOF_MODE=off\n' >"$conf"
expect_rejected "off mode"
rg -Fq 'SPOOF_MODE=off has no consumer GPU identity to package' \
    "$tmp/stderr" || fail "off mode rejection is not understandable"

printf 'VM_ID=456\n' >"$conf"
expect_rejected "missing mode"
printf 'SPOOF_MODE=A\nSPOOF_MODE=B\n' >"$conf"
expect_rejected "duplicate mode"
printf 'SPOOF_MODE=${MODE:-B}\n' >"$conf"
expect_rejected "dynamic mode"
printf 'SPOOF_MODE=B\necho "$SPOOF_MODE"\n' >"$conf"
expect_rejected "secondary dynamic mode reference"
printf 'SPOOF_MODE="B"\n' >"$conf"
run_dispatcher 456 >/dev/null
expected_sha=$(sha256sum "$conf" | awk '{print toupper($1)}')
[[ "$(<"$result")" == "gpuz|456|B|$expected_sha" ]] \
    || fail "double-quoted literal B mode did not dispatch"
printf "SPOOF_MODE='A'\n" >"$conf"
run_dispatcher 456 >/dev/null
expected_sha=$(sha256sum "$conf" | awk '{print toupper($1)}')
[[ "$(<"$result")" == "production|456|A|$expected_sha" ]] \
    || fail "single-quoted literal A mode did not dispatch"

if run_dispatcher 456 unexpected >"$tmp/stdout" 2>"$tmp/stderr"; then
    fail "one-click dispatcher accepts pass-through options"
fi
if run_dispatcher 0 >"$tmp/stdout" 2>"$tmp/stderr"; then
    fail "one-click dispatcher accepts an unsupported VM ID"
fi

echo "PASS: strict one-click vGPU packager dispatch"
