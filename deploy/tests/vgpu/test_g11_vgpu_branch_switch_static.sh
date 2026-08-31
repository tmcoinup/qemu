#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
switcher="$repo_root/deploy/host/switch-g11-vgpu-branch.sh"
verifier="$repo_root/deploy/host/verify-g11-vgpu-branch-postboot.sh"
unit="$repo_root/deploy/host/vmate-g11-vgpu-branch-verify.service"
guide="$repo_root/deploy/docs/G11-RTX2080-R535-R580-SWITCH.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 misses: $2"; }

for file in "$switcher" "$verifier"; do
    [[ -x "$file" ]] || fail "not executable: $file"
    bash -n "$file"
done
[[ -f "$unit" && -f "$guide" ]] || fail 'unit or guide missing'

contains "$switcher" 'readonly R535_VERSION=535.161.05'
contains "$switcher" 'readonly R580_VERSION=580.159.01'
contains "$switcher" 'readonly RTX2080_VENDOR_DEVICE=10de:1e82'
contains "$switcher" 'readonly R535_DEB_SHA256=2786430d32b6894f360ce0c249b29f849ae963c186840547151ed00d0feaebb9'
contains "$switcher" 'readonly R580_DEB_SHA256=033d2aec703ea366f35cade25207ab30a279b8076eb7382daa31e9649bf3f246'
contains "$switcher" "sign_file=\"\$DKMS_NO_SIGN_FILE\""
contains "$switcher" 'assert_nvidia_modules_unsigned'
contains "$switcher" 'assert_module_index_readable'
contains "$switcher" 'queue_postboot_validation'
contains "$switcher" 'r580_unlock_policy=consumer-lab'
contains "$switcher" 'r535_unlock_policy=consumer'
contains "$switcher" 'readonly QEMU_GATE_DIR=/etc/systemd/system/qemu-vm-server.service.d'
contains "$switcher" 'ExecStartPre=/usr/local/libexec/vmate-g11-vgpu-branch-verify'
contains "$switcher" 'qemu-system-x86_64.g11.real'
! grep -Eq '(^|[[:space:]])(kmodsign|bcdedit)([[:space:]]|$)' "$switcher" || \
    fail 'switcher invokes a forbidden signer or BCD tool'

contains "$verifier" 'assert_no_qemu'
contains "$verifier" 'qemu-system-x86_64.g11.real'
contains "$verifier" "die '模块带签名，拒绝验收'"
contains "$verifier" "grep -Eiq 'NVRM:.*Xid'"
contains "$verifier" "write_branch_state \"\$branch\" ready"
contains "$verifier" "rm -f -- \"\$PENDING_STATE\""

contains "$unit" 'ConditionPathExists=/var/lib/vmate/g11-vgpu-branch-switch/pending-reboot.state'
contains "$unit" 'Before=qemu-vm-server.service'
contains "$unit" 'ExecStart=/usr/local/libexec/vmate-g11-vgpu-branch-verify'
contains "$repo_root/deploy/scripts/start-vm.sh" \
    'readonly G11_VGPU_BRANCH_PENDING_STATE='
contains "$repo_root/deploy/scripts/start-vm.sh" \
    'vGPU 驱动分支仍待冷启动验收'
contains "$repo_root/deploy/scripts/stop-vm.sh" 'qemu-system-x86_64.g11.real'
contains "$guide" 'r535/ready'
contains "$guide" 'r580-lab/ready'
contains "$guide" 'modinfo -F signer nvidia'

echo 'PASS: G-11 RTX 2080 R535/R580 switch safety and post-boot gates'
