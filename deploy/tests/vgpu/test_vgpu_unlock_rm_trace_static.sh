#!/usr/bin/env bash
# G-11 host RM trace must stay opt-in, bounded, metadata-only, and reproducible.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
SETUP="$REPO_ROOT/deploy/host/setup-vgpu-unlock.sh"
PATCH="$REPO_ROOT/deploy/host/patches/vgpu-unlock-rs-g11.patch"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$SETUP"
[[ -s "$PATCH" && ! -L "$PATCH" ]] || fail 'G-11 vgpu_unlock patch is missing or unsafe'

grep -Fq '71ec870d4b456c9a8013c114a57372b1a60d36ca' "$SETUP" ||
    fail 'vgpu_unlock build is not pinned to the audited upstream commit'
grep -Fq 'cargo fmt -- --check && cargo test && cargo build --release' "$SETUP" ||
    fail 'installer does not test the patched library before installation'
grep -Fq 'apply --reverse --check' "$SETUP" ||
    fail 'installer cannot recognize an already-applied patch safely'
grep -Fq 'diff -- src/lib.rs | sha256sum' "$SETUP" ||
    fail 'installer does not reject extra source-tree modifications'
grep -Fq 'active_mdev_pids' "$SETUP" ||
    fail 'manager restart lacks an active-mdev guard'
grep -Fq 'BACKUP_DIR=' "$SETUP" ||
    fail 'installer does not create a rollback backup'
grep -Fq '"$BACKUP_DIR/libvgpu_unlock_rs.so" "$LIB_DST"' "$SETUP" ||
    fail 'manager-start failure does not restore the prior library'
grep -Fq '"$BACKUP_DIR/vgpu_unlock.conf" "$SYSTEMD_DROPIN"' "$SETUP" ||
    fail 'failed installation does not restore the prior systemd drop-in'
grep -Fq 'trap setup_exit EXIT' "$SETUP" ||
    fail 'post-backup failures are not covered by the runtime rollback trap'

grep -Fq 'rm_control_trace: Option<bool>' "$PATCH" ||
    fail 'per-profile/per-mdev trace opt-in is missing'
grep -Fq 'rm_control_trace_commands: Option<Vec<U32>>' "$PATCH" ||
    fail 'RM command allow-list is missing'
grep -Fq 'MAX_RM_CONTROL_TRACE_LIMIT: u32 = 100_000' "$PATCH" ||
    fail 'trace event limit is not bounded'
grep -Fq 'G11_RM_TRACE mdev={}' "$PATCH" ||
    fail 'stable journal marker is missing'
grep -Fq 'configure_rm_control_trace_for_mdev(config.mdev_uuid)' "$PATCH" ||
    fail 'trace is not enabled immediately after the start-data UUID is known'
grep -Fq '"mdev-start"' "$PATCH" ||
    fail 'early and profile trace phases cannot be distinguished'
grep -Fq 'Parameter payloads' "$PATCH" ||
    fail 'metadata-only trace invariant is undocumented in code'
if grep -Eq '^\+.*(dump\(|from_raw_parts|params\.cast::<u8>|params_size as usize.*slice)' "$PATCH"; then
    fail 'trace patch appears to log raw RM parameter payloads'
fi

grep -Fq 'NV2080_CTRL_CMD_FB_GET_INFO_V2: u32 = 0x2080_1303' "$PATCH" ||
    fail 'R535 fixed-layout FB response gate is missing'
grep -Fq 'mem::size_of::<Nv2080CtrlFbGetInfoV2Params>()' "$PATCH" ||
    fail 'FB response patch is not guarded by the exact structure size'
grep -Fq 'if io_data.status == NV_OK' "$PATCH" ||
    fail 'RM identity can run before the signed driver returns success'
grep -Fq 'manager_did_not_query=true' "$PATCH" ||
    fail 'unsupported memory-vendor transport is not reported fail-closed'
grep -Fq 'NVIDIA_MODULE_VERSION_PATH' "$PATCH" ||
    fail 'RM identity is not gated by the host NVIDIA driver version'
grep -Fq 'rm_identity_is_gated_to_r535' "$PATCH" ||
    fail 'R535 version gate has no regression test'
grep -Fq 'rm_info_patch_honors_caller_list_size' "$PATCH" ||
    fail 'RM response bounds regression test is missing'
if grep -Eq '^\+.*(prepare_rm_identity_query|query_appended|CLK_GET_EXTENDED_INFO|G11_CLOCK_LAYOUT)' "$PATCH"; then
    fail 'final patch contains request expansion or operational clock probing'
fi

echo 'PASS: G-11 RM trace/FB identity is pinned, bounded, response-only and restart-safe'
