#!/usr/bin/env bash
# 验证 GPU Manufacturer 只走 Config Manager UI 属性，且签名绑定前后不变。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/deploy/scripts/gpu-manufacturer-projection.ps1"
PROJECTOR="$REPO_ROOT/deploy/guest-stealth/launcher/gpu-manufacturer-projector.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v pwsh >/dev/null || fail "缺少 pwsh"
command -v x86_64-w64-mingw32-gcc >/dev/null || fail "缺少 MinGW"
[[ -f "$HELPER" && -f "$PROJECTOR" ]] || fail "制造商投影源码不完整"
[[ "$(wc -l < "$HELPER")" -le 500 ]] || fail "PowerShell helper 超过 500 行"
[[ "$(wc -l < "$PROJECTOR")" -le 500 ]] || fail "C projector 超过 500 行"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FIXTURE="$TMP_DIR/manufacturer-fixture.ps1"

cat > "$FIXTURE" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$global:manufacturerCaseName = $env:MANUFACTURER_TEST_CASE
$global:manufacturerCimReads = 0

function Get-PnpDevice {
    param($Class, [switch]$PresentOnly, $ErrorAction)
    return [pscustomobject]@{
        InstanceId = 'PCI\VEN_1AF4&DEV_1050&SUBSYS_138010DE&REV_A2\3&1&0&30'
        Status = 'OK'
    }
}

function Get-CimInstance {
    param($ClassName, $ErrorAction)
    $global:manufacturerCimReads++
    $signed = $global:manufacturerCaseName -ne 'unsigned'
    return [pscustomobject]@{
        DeviceID = 'PCI\VEN_1AF4&DEV_1050&SUBSYS_138010DE&REV_A2\3&1&0&30'
        InfName = 'oem3.inf'
        DriverProviderName = 'Red Hat, Inc.'
        IsSigned = $signed
        Signer = 'Microsoft Windows Hardware Compatibility Publisher'
    }
}

function Get-PnpDeviceProperty {
    param($InstanceId, $KeyName, $ErrorAction)
    $value = if ($global:manufacturerCaseName -eq 'bad-property') { 'Red Hat, Inc.' } else { 'NVIDIA' }
    return [pscustomobject]@{ Type = 'String'; Data = $value }
}

$projector = if ($global:manufacturerCaseName -eq 'projector-failure') {
    '/usr/bin/gnufalse'
} else {
    '/usr/bin/gnutrue'
}
$failed = $false
$failureMessage = ''
try {
    & $env:MANUFACTURER_HELPER -Vendor NVIDIA `
        -InstanceId 'PCI\VEN_1AF4&DEV_1050&SUBSYS_138010DE&REV_A2\3&1&0&30' `
        -ProjectorPath $projector
} catch {
    $failed = $true
    $failureMessage = $_.Exception.Message
}

if ($global:manufacturerCaseName -eq 'success') {
    if ($failed -or $global:manufacturerCimReads -ne 2) {
        throw ('成功路径没有在投影前后各验证一次签名绑定：failed=' +
            $failed + '; reads=' + $global:manufacturerCimReads +
            '; error=' + $failureMessage)
    }
} elseif (-not $failed) {
    throw ('失败用例被错误接受：' + $global:manufacturerCaseName)
}
POWERSHELL

for case_name in success unsigned projector-failure bad-property; do
    MANUFACTURER_HELPER="$HELPER" \
    MANUFACTURER_TEST_CASE="$case_name" \
        pwsh -NoProfile -NonInteractive -File "$FIXTURE" >/dev/null
done

x86_64-w64-mingw32-gcc \
    -std=c11 -Wall -Wextra -Werror -municode -mconsole \
    -static -static-libgcc -Wl,--no-insert-timestamp \
    "$PROJECTOR" -lsetupapi -lcfgmgr32 \
    -o "$TMP_DIR/gpu-manufacturer-projector.exe"
file "$TMP_DIR/gpu-manufacturer-projector.exe" | grep -F 'PE32+ executable' >/dev/null \
    || fail "projector 不是 Windows PE64 EXE"

grep -F 'CM_Set_DevNode_PropertyW' "$PROJECTOR" >/dev/null \
    || fail "projector 没有使用 Config Manager 属性 API"
grep -F '0xa45c254e' "$PROJECTOR" >/dev/null \
    || fail "projector 缺少 DEVPKEY_Device_Manufacturer FMTID"
grep -F '    13' "$PROJECTOR" >/dev/null \
    || fail "projector 缺少 DEVPKEY_Device_Manufacturer PID 13"
if grep -E 'RegSetValue|SetupDiSetDeviceRegistryProperty' "$PROJECTOR" >&2; then
    fail "projector 不得修改 Enum Mfg 或 Class 安装字段"
fi

grep -F "'gpu-manufacturer-projection.ps1', 'gpu-manufacturer-projector.exe'" \
    "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1" >/dev/null \
    || fail "respawn 没有持久化 manufacturer helper 与 projector"
grep -F "gpu-manufacturer-projection.ps1') -Vendor \$cfg.SpoofVendor" \
    "$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1" >/dev/null \
    || fail "名称刷新任务没有按 profile Vendor 调用 manufacturer helper"

echo "OK: GPU manufacturer projection preserves the signed binding"
