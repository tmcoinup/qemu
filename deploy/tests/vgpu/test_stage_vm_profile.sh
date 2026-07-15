#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
stage_script="$root/deploy/stage-vm-profile.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

image_root="$tmp/images"
conf_dir="$image_root/vms/instances/vm2"
stage_dir="$image_root/staging"
conf="$conf_dir/vm.conf"
mkdir -p "$conf_dir"

write_base_conf() {
    cat >"$conf" <<'EOF'
VM_UUID=a94177e0-3318-4e5c-abd3-ce68b502822e
SPOOF_MODE=B
GPU_PROFILE=gtx750ti_2gb
MONITOR_PROFILE=asus-va24e
MONITOR_SERIAL=KCLMC045CE2A
UNRELATED_SECRET=must-not-be-staged
EOF
}

run_stage() {
    IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        "$stage_script" 2 --host-ip 192.168.30.127 "$@"
}

file_sha256() {
    sha256sum "$1" | awk '{print toupper($1)}'
}

assert_no_publish_temps() {
    local directory=$1 leftover
    leftover=$(find "$directory" -mindepth 1 -maxdepth 1 \
        -name '.stage-vm[0-9]*.*' -print -quit 2>/dev/null || true)
    [[ -z "$leftover" ]] || {
        echo "FAIL: staging temporary artifact leaked: $leftover" >&2
        exit 1
    }
}

assert_manifest_entry() {
    local manifest=$1 field=$2 directory=$3 name hash actual
    name=$(jq -er ".$field.name" "$manifest")
    hash=$(jq -er ".$field.sha256" "$manifest")
    [[ "$name" != */* && "$name" != *\\* &&
       "$hash" =~ ^[A-F0-9]{64}$ ]] || {
        echo "FAIL: invalid $field manifest entry" >&2
        exit 1
    }
    [[ -s "$directory/$name" ]] || {
        echo "FAIL: manifest asset is missing: $name" >&2
        exit 1
    }
    actual=$(file_sha256 "$directory/$name")
    [[ "$actual" == "$hash" ]] || {
        echo "FAIL: $field hash mismatch: $actual != $hash" >&2
        exit 1
    }
}

assert_manifest() {
    local directory=$1 vm_id=$2 online=$3
    local manifest="$directory/vm${vm_id}-manifest.json"
    [[ -s "$manifest" ]]
    jq -e --argjson vmId "$vm_id" --argjson online "$online" '
        (keys | sort) == [
            "monitorCatalog", "monitorScript", "patch", "profile",
            "schemaVersion", "vmId"
        ] and
        .schemaVersion == 1 and .vmId == $vmId and
        (.profile | keys | sort) == ["name", "sha256"] and
        (.patch | keys | sort) == ["name", "sha256"] and
        (if $online then
            (.monitorScript | keys | sort) == ["name", "sha256"] and
            (.monitorCatalog | keys | sort) == ["name", "sha256"]
        else
            .monitorScript == null and .monitorCatalog == null
        end)
    ' "$manifest" >/dev/null
    assert_manifest_entry "$manifest" profile "$directory"
    assert_manifest_entry "$manifest" patch "$directory"
    if [[ "$online" == true ]]; then
        assert_manifest_entry "$manifest" monitorScript "$directory"
        assert_manifest_entry "$manifest" monitorCatalog "$directory"
    fi
}

expect_failure_preserves_publication() {
    local description=$1
    shift
    local old_profile old_manifest
    old_profile=$(file_sha256 "$stage_dir/vm2-profile.json")
    old_manifest=$(file_sha256 "$stage_dir/vm2-manifest.json")
    if run_stage "$@" >/dev/null 2>&1; then
        echo "FAIL: $description was accepted" >&2
        exit 1
    fi
    [[ "$(file_sha256 "$stage_dir/vm2-profile.json")" == "$old_profile" ]]
    [[ "$(file_sha256 "$stage_dir/vm2-manifest.json")" == "$old_manifest" ]]
    assert_no_publish_temps "$stage_dir"
}

write_base_conf
output=$(run_stage)

profile="$stage_dir/vm2-profile.json"
manifest="$stage_dir/vm2-manifest.json"
[[ -s "$profile" ]]
[[ -s "$stage_dir/apply-vm-profile.ps1" ]]
[[ -s "$stage_dir/patch-grid-strings.ps1" ]]

jq -e '
    (keys | sort) == ["gpu", "monitor", "schemaVersion", "spoofMode", "vmId", "vmUuid"] and
    .schemaVersion == 1 and
    .vmId == 2 and
    .vmUuid == "a94177e0-3318-4e5c-abd3-ce68b502822e" and
    .spoofMode == "B" and
    .gpu.profile == "gtx750ti_2gb" and
    .gpu.name == "NVIDIA GeForce GTX 750 Ti" and
    .gpu.expectedPnpId == "PCI\\VEN_10DE&DEV_1E30" and
    .gpu.coreClockMHz == 1020 and
    .gpu.boostClockMHz == 1085 and
    .gpu.memoryClockMHz == 1350 and
    .gpu.memoryBusBits == 128 and
    .gpu.memoryBandwidthMBps == 86400 and
    .gpu.vramMB == 2048 and
    .monitor.profile == "asus-va24e" and
    .monitor.serial == "KCLMC045CE2A"
' "$profile" >/dev/null

if rg -q 'must-not-be-staged|UNRELATED_SECRET' "$profile"; then
    echo "FAIL: complete vm.conf data leaked into staged JSON" >&2
    exit 1
fi
assert_manifest "$stage_dir" 2 false
assert_no_publish_temps "$stage_dir"

apply_hash=$(file_sha256 "$stage_dir/apply-vm-profile.ps1")
manifest_hash=$(file_sha256 "$manifest")
rg -Fq 'apply-vm-profile.ps1' <<<"$output"
rg -Fq 'vm2-manifest.json' <<<"$output"
rg -Fq "$apply_hash" <<<"$output"
rg -Fq "$manifest_hash" <<<"$output"
rg -Fq -- "-ManifestUrl 'http://192.168.30.127:8080/vm2-manifest.json'" <<<"$output"
rg -Fq -- "-ManifestSha256 '$manifest_hash'" <<<"$output"
if rg -q -- '-ConfigUrl|-OnlineMonitorRescue' <<<"$output"; then
    echo "FAIL: normal staging printed a legacy config URL or enabled monitor rescue" >&2
    exit 1
fi

# HTTP-free transfer mode must not require or print a host address.  It emits
# the three files consumed by local -ConfigPath and publishes READY last.
transfer_root="$tmp/transfer"
transfer_output=$(IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
    "$stage_script" 2 --transfer-dir "$transfer_root")
transfer_bundle="$transfer_root/vm2"
[[ -s "$transfer_bundle/READY" ]]
cmp -s "$transfer_bundle/apply-vm-profile.ps1" \
    "$root/deploy/guest/apply-vm-profile.ps1"
cmp -s "$transfer_bundle/patch-grid-strings.ps1" \
    "$root/deploy/guest/patch-grid-strings.ps1"
cmp -s "$transfer_bundle/vm2-profile.json" "$profile"
rg -Fq -- "-ConfigPath '\\\\tsclient\\nv\\vm2\\vm2-profile.json'" \
    <<<"$transfer_output"
if rg -q 'https?://|ManifestUrl' <<<"$transfer_output"; then
    echo "FAIL: transfer mode printed an HTTP dependency" >&2
    exit 1
fi
grep -Fxq "profile_sha256=$(file_sha256 "$profile")" \
    "$transfer_bundle/READY"

online_transfer=$(IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
    "$stage_script" 2 --transfer-dir "$transfer_root" \
    --online-monitor-rescue)
[[ -s "$transfer_bundle/spoof-monitor.ps1" ]]
[[ -s "$transfer_bundle/monitor-profiles.tsv" ]]
rg -Fq -- '-OnlineMonitorRescue' <<<"$online_transfer"

if IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
    "$stage_script" 2 --transfer-dir relative/path >/dev/null 2>&1; then
    echo 'FAIL: transfer mode accepted a relative directory' >&2
    exit 1
fi
if IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
    "$stage_script" 2 --transfer-dir "$transfer_root" --serve \
    >/dev/null 2>&1; then
    echo 'FAIL: transfer mode accepted --serve' >&2
    exit 1
fi

# Explicit persisted values win over catalog defaults.  This also exercises
# every upper bound that is accepted by the guest validator.
cat >>"$conf" <<'EOF'
VGPU_MDEV_PROFILE=nvidia-257
GPU_NAME="  VM2 ASCII override  "
GPU_CORE_MHZ=10000
GPU_BOOST_MHZ=10000
GPU_MEMORY_MHZ=10000
GPU_MEMORY_BUS_BITS=1024
GPU_MEMORY_BANDWIDTH_MBPS=1000000
GPU_VRAM_MB=2048
EOF

override_output=$(IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
    "$stage_script" 2 --host-ip 10.20.30.40 --port 18080)
jq -e '
    .spoofMode == "B" and
    .gpu.name == "VM2 ASCII override" and
    .gpu.expectedPnpId == "PCI\\VEN_10DE&DEV_1E30" and
    .gpu.coreClockMHz == 10000 and
    .gpu.boostClockMHz == 10000 and
    .gpu.memoryClockMHz == 10000 and
    .gpu.memoryBusBits == 1024 and
    .gpu.memoryBandwidthMBps == 1000000 and
    .gpu.vramMB == 2048
' "$profile" >/dev/null
rg -Fq "http://10.20.30.40:18080/vm2-manifest.json" <<<"$override_output"
assert_manifest "$stage_dir" 2 false

# Missing and non-B modes must fail before touching the existing publication.
cp "$conf" "$tmp/good.conf"
sed '/^SPOOF_MODE=/d' "$tmp/good.conf" >"$conf"
expect_failure_preserves_publication 'missing SPOOF_MODE'
sed 's/^SPOOF_MODE=.*/SPOOF_MODE=A/' "$tmp/good.conf" >"$conf"
expect_failure_preserves_publication 'non-B SPOOF_MODE'
sed 's/^VGPU_MDEV_PROFILE=.*/VGPU_MDEV_PROFILE=nvidia-999/' \
    "$tmp/good.conf" >"$conf"
expect_failure_preserves_publication 'non-257 VGPU_MDEV_PROFILE'

# GPU validation mirrors the guest limits.  Test every exclusive upper bound,
# the fixed VRAM contract, ASCII-only names, and maximum name length.
declare -a bad_overrides=(
    'GPU_CORE_MHZ=10001'
    'GPU_BOOST_MHZ=10001'
    'GPU_MEMORY_MHZ=10001'
    'GPU_MEMORY_BUS_BITS=1025'
    'GPU_MEMORY_BANDWIDTH_MBPS=1000001'
    'GPU_VRAM_MB=2049'
)
for override in "${bad_overrides[@]}"; do
    cp "$tmp/good.conf" "$conf"
    printf '%s\n' "$override" >>"$conf"
    expect_failure_preserves_publication "out-of-range $override"
done

cp "$tmp/good.conf" "$conf"
printf 'GPU_NAME="NVIDIA GeForce 测试"\n' >>"$conf"
expect_failure_preserves_publication 'non-ASCII GPU_NAME'

cp "$tmp/good.conf" "$conf"
printf 'GPU_NAME="%32s"\n' '' | tr ' ' X >>"$conf"
expect_failure_preserves_publication '32-character GPU_NAME'

cp "$tmp/good.conf" "$conf"
printf 'GPU_NAME="%31s"\n' '' | tr ' ' X >>"$conf"
run_stage >/dev/null
[[ "$(jq -r '.gpu.name | length' "$profile")" == 31 ]]
assert_manifest "$stage_dir" 2 false

# IPv4 validation rejects out-of-range, incomplete, and ambiguous octets.
cp "$tmp/good.conf" "$conf"
for bad_ip in 256.1.2.3 1.2.3.999 1.2.3 01.2.3.4 1.2.3.4.5; do
    old_profile=$(file_sha256 "$profile")
    old_manifest=$(file_sha256 "$manifest")
    if IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        "$stage_script" 2 --host-ip "$bad_ip" >/dev/null 2>&1; then
        echo "FAIL: invalid IPv4 was accepted: $bad_ip" >&2
        exit 1
    fi
    [[ "$(file_sha256 "$profile")" == "$old_profile" ]]
    [[ "$(file_sha256 "$manifest")" == "$old_manifest" ]]
done

# Online rescue is explicit in both the manifest and printed guest command.
online_output=$(run_stage --online-monitor-rescue)
assert_manifest "$stage_dir" 2 true
rg -Fq -- '-OnlineMonitorRescue' <<<"$online_output"

# --serve must bind only the advertised address and must not let server.py
# resync source files after their hashes have been committed to the manifest.
fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$SERVE_ARGS_LOG"
EOF
chmod +x "$fake_bin/python3"
serve_args="$tmp/serve.args"
SERVE_ARGS_LOG="$serve_args" PATH="$fake_bin:$PATH" \
    IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
    "$stage_script" 2 --host-ip 10.20.30.40 --port 18080 --serve >/dev/null
rg -Fxq -- '--bind' "$serve_args"
rg -Fxq -- '10.20.30.40' "$serve_args"
rg -Fxq -- '--no-sync' "$serve_args"
rg -Fxq -- '18080' "$serve_args"

# A process interrupted during publication may expose complete new files, but
# the old manifest must remain as the commit point and reject their hashes.
atomic_root="$tmp/atomic-images"
atomic_conf_dir="$atomic_root/vms/instances/vm2"
atomic_stage="$atomic_root/staging"
mkdir -p "$atomic_conf_dir"
cp "$tmp/good.conf" "$atomic_conf_dir/vm.conf"
IMAGE_ROOT="$atomic_root" STAGE_DIR="$atomic_stage" \
    "$stage_script" 2 --host-ip 192.168.30.127 >/dev/null
old_manifest_hash=$(file_sha256 "$atomic_stage/vm2-manifest.json")
printf 'GPU_NAME="Atomic replacement"\n' >>"$atomic_conf_dir/vm.conf"

real_mv=$(command -v mv)
mv_count="$tmp/mv.count"
cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -f "$MV_COUNT_FILE" ]] || read -r count <"$MV_COUNT_FILE"
count=$((count + 1))
printf '%s\n' "$count" >"$MV_COUNT_FILE"
if [[ "$count" == "$MV_FAIL_AT" ]]; then
    exit 73
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$fake_bin/mv"
if MV_COUNT_FILE="$mv_count" MV_FAIL_AT=4 REAL_MV="$real_mv" \
    PATH="$fake_bin:$PATH" IMAGE_ROOT="$atomic_root" STAGE_DIR="$atomic_stage" \
    "$stage_script" 2 --host-ip 192.168.30.127 >/dev/null 2>&1; then
    echo 'FAIL: injected manifest-publication failure was ignored' >&2
    exit 1
fi
[[ "$(file_sha256 "$atomic_stage/vm2-manifest.json")" == "$old_manifest_hash" ]]
jq -e '.gpu.name == "Atomic replacement"' \
    "$atomic_stage/vm2-profile.json" >/dev/null
recorded_profile_hash=$(jq -r '.profile.sha256' \
    "$atomic_stage/vm2-manifest.json")
[[ "$(file_sha256 "$atomic_stage/vm2-profile.json")" != \
   "$recorded_profile_hash" ]]
cmp -s "$atomic_stage/apply-vm-profile.ps1" \
    "$root/deploy/guest/apply-vm-profile.ps1"
cmp -s "$atomic_stage/patch-grid-strings.ps1" \
    "$root/deploy/guest/patch-grid-strings.ps1"
assert_no_publish_temps "$atomic_stage"

# A clean retry repairs the coherent set and updates the manifest last.
IMAGE_ROOT="$atomic_root" STAGE_DIR="$atomic_stage" \
    "$stage_script" 2 --host-ip 192.168.30.127 >/dev/null
assert_manifest "$atomic_stage" 2 false

# The global staging lock must delay a second publisher until it is released.
lock_root="$tmp/lock-images"
lock_conf_dir="$lock_root/vms/instances/vm2"
lock_stage="$lock_root/staging"
mkdir -p "$lock_conf_dir" "$lock_stage"
cp "$tmp/good.conf" "$lock_conf_dir/vm.conf"
exec {held_lock_fd}>"$lock_stage/.stage-vm-profile.lock"
flock -x "$held_lock_fd"
IMAGE_ROOT="$lock_root" STAGE_DIR="$lock_stage" \
    "$stage_script" 2 --host-ip 192.168.30.127 >/dev/null &
blocked_pid=$!
sleep 0.1
kill -0 "$blocked_pid"
[[ ! -e "$lock_stage/vm2-manifest.json" ]]
flock -u "$held_lock_fd"
exec {held_lock_fd}>&-
wait "$blocked_pid"
assert_manifest "$lock_stage" 2 false

echo 'PASS: VM profile staging enforces B mode, validates inputs, and atomically publishes hashed assets'
