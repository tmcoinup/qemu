#!/usr/bin/env bash
# 验证已是目标厂商的 base 重跑 coordinator 后仍只保留该厂商的 x86/x64 API。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/guest_vendor_api_same_vendor_fixture.ps1"
COORDINATOR="$REPO_ROOT/deploy/guest-stealth/install-gpu-api-system.ps1"
IDENTITY_BINDING="$REPO_ROOT/deploy/guest-stealth/gpu-api-identity-binding.ps1"
NVAPI_INSTALL="$REPO_ROOT/deploy/guest-stealth/install-nvapi-system.ps1"
NVAPI_VALIDATION="$REPO_ROOT/deploy/guest-stealth/nvapi-system-validation.ps1"
NVAPI_TRANSACTION="$REPO_ROOT/deploy/guest-stealth/nvapi-system-transaction.ps1"
ADL_INSTALL="$REPO_ROOT/deploy/guest-stealth/install-adl-system.ps1"
ADL_TRANSACTION="$REPO_ROOT/deploy/guest-stealth/adl-system-transaction.ps1"
NVAPI_DIR="$REPO_ROOT/deploy/nvapi-shim"
ADL_DIR="$REPO_ROOT/deploy/adl-shim"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$FIXTURE" "$COORDINATOR" "$IDENTITY_BINDING" \
        "$NVAPI_INSTALL" "$NVAPI_VALIDATION" \
        "$NVAPI_TRANSACTION" "$ADL_INSTALL" "$ADL_TRANSACTION" \
        "$NVAPI_DIR/nvapi.dll" "$NVAPI_DIR/nvapi64.dll" \
        "$ADL_DIR/atiadlxy.dll" "$ADL_DIR/atiadlxx.dll"; do
    [[ -f "$path" ]] || fail "缺少同厂商幂等测试输入: $path"
done

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

COORDINATOR_PATH="$COORDINATOR" NVAPI_INSTALL_PATH="$NVAPI_INSTALL" \
NVAPI_VALIDATION_PATH="$NVAPI_VALIDATION" \
NVAPI_TRANSACTION_PATH="$NVAPI_TRANSACTION" ADL_INSTALL_PATH="$ADL_INSTALL" \
ADL_TRANSACTION_PATH="$ADL_TRANSACTION" NVAPI_X86="$NVAPI_DIR/nvapi.dll" \
NVAPI_X64="$NVAPI_DIR/nvapi64.dll" ADL_X86="$ADL_DIR/atiadlxy.dll" \
ADL_X64="$ADL_DIR/atiadlxx.dll" TEST_ROOT="$TEST_ROOT" \
pwsh -NoLogo -NoProfile -NonInteractive -File "$FIXTURE" \
    || fail "NVIDIA→NVIDIA / AMD→AMD coordinator 幂等测试失败"

[[ "$(wc -l < "$FIXTURE")" -le 500 && "$(wc -l < "$0")" -le 500 ]] \
    || fail "同厂商幂等测试单文件超过 500 行"

echo "OK: NVIDIA→NVIDIA and AMD→AMD coordinator reruns are idempotent"
